// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Sealing a request or response body that spilled to the cross-tenant
//! body pool.
//!
//! ## Why a body cannot seal the way a kv value does
//!
//! Everything else seals at the WRITE BOUNDARY, where the handler has
//! already named an identity (`seal.zig`). A body cannot reach that
//! moment. It arrives before any handler code runs, and the blob
//! coordinator batches it into a **content-addressed** `_pool/` object
//! that may reach object storage before the handler returns. By the time
//! an identity exists the bytes are immutable, shared with other
//! tenants, and named by their own hash — so there is nothing left to
//! seal in place.
//!
//! ## Envelope: seal the body once, seal its key again
//!
//! The body is sealed under a **data key minted for it alone**, and that
//! small key — not the body — is what gets sealed under the key material
//! a destroy can reach. Destroying that key destroys the only copy of
//! the data key, so the pool bytes become unreadable everywhere at once,
//! backups included, without rewriting an object that cannot be
//! rewritten.
//!
//! The wrap is what a destroy reaches, so the wrap is what has to travel
//! with the reference rather than with the bytes: a pool object is
//! shared, and per-reference key material in a shared object could not
//! be removed for one holder without removing it for all of them.
//!
//! One seal per data key also disposes of the nonce budget this layer
//! would otherwise have to reason about: a key that seals exactly one
//! body cannot reuse a nonce (see the budget note in `rove-crypt`).
//!
//! ## What the naming key is
//!
//! Whatever key material a destroy can reach: the tenant key
//! (`crypt.TENANT_REF`), which a deprovision removes, or an identity's
//! slot key, which `shredKey.destroy` removes. The wrap records which
//! one it used, so the granularity a body actually got is readable from
//! the wrap rather than inferred — the silent fallback from per-identity
//! to per-tenant is the failure this epic explicitly forbids, and
//! recording it is the opposite of silent.

const std = @import("std");
const crypt = @import("rove-crypt");

/// Bytes a wrapped data key occupies. Fixed — a key is fixed-length, so
/// its seal is too, which lets a carrier reserve the field rather than
/// length-prefix it.
pub const WRAPPED_LEN: usize = crypt.HEADER_LEN + crypt.KEY_LEN + crypt.TAG_LEN;

/// The `key_ref` stamped into the BODY's own envelope.
///
/// Not a slot and not the tenant: a data key lives in the wrap and never
/// in any keyring, so there is nothing for a reader to route to and this
/// field exists to be authenticated rather than to locate anything. The
/// maximal value is chosen so it can never be mistaken for a real slot —
/// slots are dense and ascending from `crypt.FIRST_SLOT`, and reaching
/// `u64` exhaustion is not a thing that happens.
pub const DATA_KEY_REF: crypt.KeyRef = [_]u8{0xFF} ** crypt.KEY_REF_LEN;

/// Label separating the tenant-level body key from every other subkey
/// derived from the same per-tenant secret.
///
/// Derived rather than minted into a slot, and that is sound HERE for the
/// reason PLAN §2.7's amendment gives for why it is NOT sound in general:
/// a derived key is unshreddable only while its ROOT survives, and this
/// root is the tenant's own stored secret, which a deprovision unlinks.
/// So destroying it destroys this key with it — tenant granularity,
/// exactly what `crypt.TENANT_REF` names.
pub const TENANT_LABEL = "rove-crypt/pool-body/v1";

/// The tenant-level key a `crypt.TENANT_REF` wrap is sealed under.
pub fn tenantKey(secret: *const crypt.keyring.Secret) crypt.Key {
    return crypt.deriveSubkey(secret, TENANT_LABEL);
}

pub const Error = error{
    OutOfMemory,
    /// The wrapped key is not `WRAPPED_LEN` bytes, or its envelope is
    /// malformed. A carrier that lost the field reads as this rather
    /// than as a body with no seal.
    MalformedWrap,
} || crypt.Error;

/// A sealed body and the key material a reader needs to open it.
pub const Sealed = struct {
    /// What goes into the pool object. Opaque to every container below.
    body: []u8,
    /// The data key, sealed under the naming key. Travels with the
    /// REFERENCE, not with the body.
    wrapped_key: [WRAPPED_LEN]u8,

    pub fn deinit(self: *Sealed, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.body = &.{};
    }
};

/// Seal `plaintext` under a fresh data key, and seal that data key under
/// `key` naming `ref`.
///
/// `ref` is `crypt.TENANT_REF` for tenant-reachable erasure, or
/// `crypt.refForSlot(slot)` for one identity. Caller frees `.body`.
pub fn seal(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    key: crypt.Key,
    ref: crypt.KeyRef,
    key_version: u32,
) Error!Sealed {
    var data_key: crypt.Key = undefined;
    std.crypto.random.bytes(&data_key);
    // Wiped on every path out, including the error ones: a data key left
    // in a stack frame is a copy of the thing whose single-copy-ness is
    // the whole property being built here.
    defer crypt.wipe(&data_key);

    const body = try crypt.sealAlloc(allocator, plaintext, data_key, DATA_KEY_REF, key_version);
    errdefer allocator.free(body);

    var wrapped: [WRAPPED_LEN]u8 = undefined;
    try crypt.seal(&wrapped, &data_key, key, ref, key_version);

    return .{ .body = body, .wrapped_key = wrapped };
}

/// Open a sealed body: unwrap the data key with `key`, then open the
/// body with it. Caller frees.
///
/// A wrong `key` fails at the unwrap with `AuthFailed` — the body is
/// never attempted, so a caller holding the wrong key material learns it
/// without the cost of a body-sized decrypt.
pub fn open(
    allocator: std.mem.Allocator,
    sealed_body: []const u8,
    wrapped_key: []const u8,
    key: crypt.Key,
) Error![]u8 {
    if (wrapped_key.len != WRAPPED_LEN) return Error.MalformedWrap;
    var data_key: crypt.Key = undefined;
    defer crypt.wipe(&data_key);
    try crypt.open(&data_key, wrapped_key, key);
    return crypt.openAlloc(allocator, sealed_body, data_key);
}

/// Move a wrap from one key to another, without touching the body.
///
/// This is the late-binding upgrade: a body is submitted before any
/// handler has named an identity, so its data key is first wrapped under
/// the tenant key; if the activation then names one, the wrap moves to
/// that identity's slot key while the pool object stays exactly as
/// written.
///
/// **It REPLACES, and that is not an implementation choice.** Two wraps
/// of one data key would mean two keys open the same body, so destroying
/// the identity would leave the tenant key still able to read what the
/// customer was told was erased. Exactly one wrap, naming exactly one
/// key, is what makes the promise true.
pub fn rewrap(
    wrapped_key: []const u8,
    from: crypt.Key,
    to: crypt.Key,
    to_ref: crypt.KeyRef,
    key_version: u32,
) Error![WRAPPED_LEN]u8 {
    if (wrapped_key.len != WRAPPED_LEN) return Error.MalformedWrap;
    var data_key: crypt.Key = undefined;
    defer crypt.wipe(&data_key);
    try crypt.open(&data_key, wrapped_key, from);

    var out: [WRAPPED_LEN]u8 = undefined;
    try crypt.seal(&out, &data_key, to, to_ref, key_version);
    return out;
}

/// Which key material opens this wrapped key — `crypt.TENANT_REF` for
/// the tenant key, otherwise the identity slot via
/// `crypt.slotForRef`.
///
/// Readable without holding any key, so a caller can decide whether it
/// is even the right node to ask before it tries.
pub fn wrapRef(wrapped_key: []const u8) Error!crypt.KeyRef {
    if (wrapped_key.len != WRAPPED_LEN) return Error.MalformedWrap;
    const hdr = crypt.peek(wrapped_key) catch return Error.MalformedWrap;
    return hdr.key_ref;
}

/// Is this wrap reachable only by a deprovision (tenant key), rather
/// than by a `shredKey.destroy` (identity slot)?
pub fn isTenantWrapped(wrapped_key: []const u8) Error!bool {
    const ref = try wrapRef(wrapped_key);
    return std.mem.eql(u8, &ref, &crypt.TENANT_REF);
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const TENANT_KEY: crypt.Key = [_]u8{0x11} ** crypt.KEY_LEN;
const IDENTITY_KEY: crypt.Key = [_]u8{0x22} ** crypt.KEY_LEN;

test "a body round-trips through the wrap" {
    var s = try seal(testing.allocator, "the request body", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);

    const plain = try open(testing.allocator, s.body, &s.wrapped_key, TENANT_KEY);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("the request body", plain);
}

test "an empty body is a body, not an absence" {
    // `BodyRef.none` is how "no object" is said. A zero-length body that
    // WAS recorded must still seal and open, or an empty POST would read
    // back as never-captured.
    var s = try seal(testing.allocator, "", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    const plain = try open(testing.allocator, s.body, &s.wrapped_key, TENANT_KEY);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("", plain);
}

test "destroying the naming key is what makes the body unreadable" {
    // The property the whole epic rests on: the bytes are untouched and
    // still in the pool, and they are unreadable because the only copy
    // of their data key was sealed under a key that is gone. Simulated
    // by opening with key material that does not match the wrap.
    var s = try seal(testing.allocator, "secret", IDENTITY_KEY, crypt.refForSlot(9), 1);
    defer s.deinit(testing.allocator);
    try testing.expectError(
        crypt.Error.AuthFailed,
        open(testing.allocator, s.body, &s.wrapped_key, TENANT_KEY),
    );
}

test "the wrap says which granularity the body actually got" {
    // Readable WITHOUT any key, because the silent downgrade from
    // per-identity to per-tenant is the failure mode this epic names,
    // and it can only be caught if the granularity is recorded rather
    // than assumed.
    var t = try seal(testing.allocator, "x", TENANT_KEY, crypt.TENANT_REF, 1);
    defer t.deinit(testing.allocator);
    try testing.expect(try isTenantWrapped(&t.wrapped_key));

    var i = try seal(testing.allocator, "x", IDENTITY_KEY, crypt.refForSlot(4097), 1);
    defer i.deinit(testing.allocator);
    try testing.expect(!try isTenantWrapped(&i.wrapped_key));
    try testing.expectEqual(@as(u64, 4097), crypt.slotForRef(try wrapRef(&i.wrapped_key)));
}

test "identical bodies do not produce identical objects" {
    // The documented consequence, asserted so nobody restores dedup by
    // accident: a fresh data key per body means the pool's content
    // addressing sees two different objects. `pool_object.zig` already
    // states dedup is not the goal.
    var a = try seal(testing.allocator, "same bytes", TENANT_KEY, crypt.TENANT_REF, 1);
    defer a.deinit(testing.allocator);
    var b = try seal(testing.allocator, "same bytes", TENANT_KEY, crypt.TENANT_REF, 1);
    defer b.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, a.body, b.body));
}

test "the body's own envelope ref is never mistaken for a slot" {
    var s = try seal(testing.allocator, "x", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    const hdr = try crypt.peek(s.body);
    try testing.expect(std.mem.eql(u8, &hdr.key_ref, &DATA_KEY_REF));
    // And it is distinguishable from the tenant, which is the ref that
    // WOULD mislead: a reader must never conclude from a body envelope
    // that the tenant key opens it.
    try testing.expect(!std.mem.eql(u8, &hdr.key_ref, &crypt.TENANT_REF));
}

test "a lost or truncated wrap is refused, not read as an unsealed body" {
    var s = try seal(testing.allocator, "x", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    try testing.expectError(Error.MalformedWrap, wrapRef(&.{}));
    try testing.expectError(
        Error.MalformedWrap,
        open(testing.allocator, s.body, s.wrapped_key[0 .. WRAPPED_LEN - 1], TENANT_KEY),
    );
}

test "a wrap moves to an identity without the body changing" {
    var s = try seal(testing.allocator, "the request body", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    const body_before = try testing.allocator.dupe(u8, s.body);
    defer testing.allocator.free(body_before);

    const moved = try rewrap(&s.wrapped_key, TENANT_KEY, IDENTITY_KEY, crypt.refForSlot(77), 1);

    // The pool object is content-addressed and immutable: if the body
    // moved, its key moved, and every reference to it would dangle.
    try testing.expectEqualSlices(u8, body_before, s.body);

    const plain = try open(testing.allocator, s.body, &moved, IDENTITY_KEY);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("the request body", plain);
    try testing.expectEqual(@as(u64, 77), crypt.slotForRef(try wrapRef(&moved)));
}

test "the moved-from key can no longer open the body" {
    // THE property. A wrap that was added alongside the old one instead
    // of replacing it would leave the tenant key able to read a body the
    // customer was told only their identity key could reach — so
    // destroying the identity would erase nothing.
    var s = try seal(testing.allocator, "secret", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    const moved = try rewrap(&s.wrapped_key, TENANT_KEY, IDENTITY_KEY, crypt.refForSlot(5), 1);
    try testing.expectError(
        crypt.Error.AuthFailed,
        open(testing.allocator, s.body, &moved, TENANT_KEY),
    );
}

test "rewrap refuses the wrong source key rather than minting a new body key" {
    var s = try seal(testing.allocator, "x", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    try testing.expectError(
        crypt.Error.AuthFailed,
        rewrap(&s.wrapped_key, IDENTITY_KEY, IDENTITY_KEY, crypt.refForSlot(1), 1),
    );
}

test "the tenant body key is separated from every other subkey" {
    const secret: crypt.keyring.Secret = [_]u8{0x7E} ** crypt.keyring.SECRET_LEN;
    const body = tenantKey(&secret);
    // Same root, different label ⇒ different key. Without separation a
    // body key and (say) a log key would be the same bytes, so a reader
    // entitled to one would be entitled to the other.
    try testing.expect(!std.mem.eql(u8, &body, &crypt.deriveSubkey(&secret, "rove-crypt/other/v1")));
    // And it is a function of the root, so a different tenant's secret
    // yields a different key — the shred property.
    const other: crypt.keyring.Secret = [_]u8{0x7F} ** crypt.keyring.SECRET_LEN;
    try testing.expect(!std.mem.eql(u8, &body, &tenantKey(&other)));
    // Deterministic, or a body sealed before a restart could not be read
    // after one.
    try testing.expectEqualSlices(u8, &body, &tenantKey(&secret));
}

test "a tampered body fails to open even with the right wrap" {
    var s = try seal(testing.allocator, "the request body", TENANT_KEY, crypt.TENANT_REF, 1);
    defer s.deinit(testing.allocator);
    s.body[s.body.len - 1] ^= 0xFF;
    try testing.expectError(
        crypt.Error.AuthFailed,
        open(testing.allocator, s.body, &s.wrapped_key, TENANT_KEY),
    );
}
