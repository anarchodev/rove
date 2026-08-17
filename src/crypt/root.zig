// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-crypt — the one sealed-envelope primitive for crypto shredding.
//!
//! Erasure here is key destruction: bytes stay where they are and stop
//! being readable. That works only if every ciphertext says which key
//! opens it, so a reader can find the key without holding the plaintext
//! identifier, and a *missing* key is an ordinary not-found rather than
//! a parse failure.
//!
//! ## Wire format
//!
//!   [1B alg_id][4B key_version LE][8B key_ref][12B nonce][ciphertext][16B tag]
//!   \___________________ header, authenticated as AAD _____________/
//!
//! Self-describing from the first byte persisted, so the algorithm and
//! the key generation can both roll without stranding stored bytes.
//! Bare ciphertext — or a version byte with no algorithm id — is not
//! acceptable at rest; see the crypto algorithm-agility gate in
//! `docs/architecture/format-versioning.md`.
//!
//! The whole header is passed to the AEAD as additional data, so
//! swapping a `key_ref` or downgrading a `key_version` on a stored
//! blob fails authentication instead of silently redirecting a read.
//!
//! ## Two levels
//!
//! A `key_ref` of all zeroes (`TENANT_REF`) means "the tenant's own
//! key" — the outer, C1 level, destroyed when the tenant is
//! deprovisioned. Any other `key_ref` names an identity *inside* that
//! tenant — the inner, C2 level, destroyed when the tenant asks. The
//! two nest by sealing twice; nothing here knows or cares which level
//! a caller is at.
//!
//! ## What a key_ref is
//!
//! A truncated HMAC of the identity name under a subkey derived for
//! that purpose, never the name itself. The name is chosen by the
//! customer and routinely identifies a person; the ref is what lands in
//! the log sidecar and the SQLite index, so those stay free of plaintext
//! identifiers while "every record for identity X" is still answerable
//! by recomputing the ref.
//!
//! ## Overhead
//!
//! 41 bytes per sealed blob. That is small against a log frame or a
//! pooled body and proportionally large against a short kv value —
//! sealing is per-value, so callers with many tiny values should expect
//! it.
//!
//! ## Nonce budget
//!
//! Nonces are random. AES-GCM's 96-bit nonce gives roughly a 2^-32
//! collision probability at 2^32 seals under ONE key, and a repeated
//! (key, nonce) pair forfeits confidentiality for both messages. Per-
//! identity keys never approach that. A tenant key sealing every record
//! for the life of a busy tenant can, which is what `key_version` is
//! for: rotating the key resets the budget. `alg_id` reserves room for
//! an extended-nonce AEAD if that bound ever becomes awkward to manage.

const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

/// AES-256-GCM. Algorithm id 0 is deliberately unused so an all-zero
/// buffer never decodes as a valid envelope.
pub const ALG_AES_256_GCM: u8 = 1;

pub const KEY_LEN: usize = Aes256Gcm.key_length;
pub const NONCE_LEN: usize = Aes256Gcm.nonce_length;
pub const TAG_LEN: usize = Aes256Gcm.tag_length;
pub const KEY_REF_LEN: usize = 8;

pub const HEADER_LEN: usize = 1 + 4 + KEY_REF_LEN + NONCE_LEN;
/// Bytes a seal adds to its plaintext.
pub const OVERHEAD: usize = HEADER_LEN + TAG_LEN;

pub const Key = [KEY_LEN]u8;
pub const KeyRef = [KEY_REF_LEN]u8;

/// The tenant's own key — the outer (C1) level. Reserved so it can
/// never collide with a real identity ref: `keyRef` rejects any input
/// that would hash to it rather than letting one identity silently
/// address the tenant key.
pub const TENANT_REF: KeyRef = [_]u8{0} ** KEY_REF_LEN;

pub const Error = error{
    /// Fewer bytes than a header plus tag.
    Truncated,
    /// An `alg_id` this build does not implement — a forward-rolled
    /// envelope, or not an envelope at all.
    UnknownAlg,
    /// Authentication failed: wrong key, or the bytes were altered.
    /// Deliberately indistinguishable between those two cases.
    AuthFailed,
    /// The output buffer is too small for the result.
    BufferTooSmall,
    OutOfMemory,
};

/// What a reader can learn from a sealed blob WITHOUT holding any key.
/// The point of the type: fetch the key named here, then `open`.
pub const Header = struct {
    alg_id: u8,
    key_version: u32,
    key_ref: KeyRef,
};

/// Sealed size for a plaintext of `n` bytes.
pub fn sealedLen(n: usize) usize {
    return n + OVERHEAD;
}

/// Plaintext size for a sealed blob of `n` bytes. Errors rather than
/// underflowing on a runt input.
pub fn openedLen(n: usize) Error!usize {
    if (n < OVERHEAD) return Error.Truncated;
    return n - OVERHEAD;
}

/// Read the header of a sealed blob. Cheap, allocation-free, and
/// key-free — this is how a reader discovers which key to fetch.
pub fn peek(sealed: []const u8) Error!Header {
    if (sealed.len < OVERHEAD) return Error.Truncated;
    const alg = sealed[0];
    if (alg != ALG_AES_256_GCM) return Error.UnknownAlg;
    var ref: KeyRef = undefined;
    @memcpy(&ref, sealed[5 .. 5 + KEY_REF_LEN]);
    return .{
        .alg_id = alg,
        .key_version = std.mem.readInt(u32, sealed[1..5], .little),
        .key_ref = ref,
    };
}

/// Seal `plaintext` into `out`, which must be exactly
/// `sealedLen(plaintext.len)`. The nonce is drawn fresh per call — see
/// the nonce-budget note in the file header before reusing one key
/// across an unbounded number of seals.
pub fn seal(
    out: []u8,
    plaintext: []const u8,
    key: Key,
    key_ref: KeyRef,
    key_version: u32,
) Error!void {
    if (out.len != sealedLen(plaintext.len)) return Error.BufferTooSmall;

    out[0] = ALG_AES_256_GCM;
    std.mem.writeInt(u32, out[1..5], key_version, .little);
    @memcpy(out[5 .. 5 + KEY_REF_LEN], &key_ref);

    var nonce: [NONCE_LEN]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    @memcpy(out[5 + KEY_REF_LEN .. HEADER_LEN], &nonce);

    // The header is authenticated but not encrypted: a reader must be
    // able to route on `key_ref` before it can decrypt anything, and
    // binding it as AAD is what stops that routing being forgeable.
    const header = out[0..HEADER_LEN];
    const ct = out[HEADER_LEN .. HEADER_LEN + plaintext.len];
    var tag: [TAG_LEN]u8 = undefined;
    Aes256Gcm.encrypt(ct, &tag, plaintext, header, nonce, key);
    @memcpy(out[HEADER_LEN + plaintext.len ..], &tag);
}

/// `seal` into a fresh allocation. Caller frees.
pub fn sealAlloc(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    key: Key,
    key_ref: KeyRef,
    key_version: u32,
) Error![]u8 {
    const out = allocator.alloc(u8, sealedLen(plaintext.len)) catch
        return Error.OutOfMemory;
    errdefer allocator.free(out);
    try seal(out, plaintext, key, key_ref, key_version);
    return out;
}

/// Open `sealed` into `out`, which must be exactly
/// `openedLen(sealed.len)`. Returns `AuthFailed` for a wrong key and
/// for tampered bytes alike.
pub fn open(out: []u8, sealed: []const u8, key: Key) Error!void {
    const want = try openedLen(sealed.len);
    if (out.len != want) return Error.BufferTooSmall;
    if (sealed[0] != ALG_AES_256_GCM) return Error.UnknownAlg;

    const header = sealed[0..HEADER_LEN];
    var nonce: [NONCE_LEN]u8 = undefined;
    @memcpy(&nonce, sealed[5 + KEY_REF_LEN .. HEADER_LEN]);
    const ct = sealed[HEADER_LEN .. HEADER_LEN + want];
    var tag: [TAG_LEN]u8 = undefined;
    @memcpy(&tag, sealed[HEADER_LEN + want ..]);

    Aes256Gcm.decrypt(out, ct, tag, header, nonce, key) catch
        return Error.AuthFailed;
}

/// `open` into a fresh allocation. Caller frees. The allocation is
/// released on an authentication failure, so a caller cannot leak a
/// buffer of undecrypted bytes by ignoring the error.
pub fn openAlloc(
    allocator: std.mem.Allocator,
    sealed: []const u8,
    key: Key,
) Error![]u8 {
    const want = try openedLen(sealed.len);
    const out = allocator.alloc(u8, want) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    try open(out, sealed, key);
    return out;
}

// ── key derivation ───────────────────────────────────────────────────

/// Derive a subsystem key from a root secret.
///
/// The root MUST be a *stored* secret that a delete can remove. A key
/// derived from a long-lived global master is unshreddable: while the
/// master exists the key is re-derivable, so destroying it erases
/// nothing. Subkeys derived from a shreddable root inherit the
/// property, which is what lets one destruction cover every subsystem
/// at once.
///
/// `label` separates subsystems so a key compromise in one does not
/// hand over the others. It rides HKDF's `info`, with a fixed domain
/// string as the salt, so a root shared with any other protocol still
/// yields unrelated keys here.
///
/// The root is the caller's to compose. Where shredding is the point,
/// that is the node-local master concatenated with the tenant's stored
/// secret: the master keeps a stolen keyring useless, and the stored
/// secret is what destruction actually removes.
pub fn deriveSubkey(root: []const u8, label: []const u8) Key {
    const prk = HkdfSha256.extract(DOMAIN, root);
    var out: Key = undefined;
    HkdfSha256.expand(&out, label, prk);
    return out;
}

/// HKDF salt — domain separation against any other use of the same
/// root secret.
pub const DOMAIN = "rove-crypt/v1";

/// The ref-key label. Refs are derived under their own label so a
/// stolen ref key cannot decrypt anything.
pub const REF_LABEL = "rove-crypt/key-ref/v1";

/// Compute the `key_ref` naming `identity`.
///
/// A truncated HMAC, never the identity itself, because the identity is
/// customer-chosen and routinely identifies a person while the ref is
/// what persists in the log sidecar and the SQLite index. Equality is
/// preserved, so "every record for identity X" stays answerable by
/// recomputing the ref; nothing else about X is recoverable from it.
///
/// A collision with `TENANT_REF` is remapped rather than returned: two
/// levels addressing one key would let an identity shred read as a
/// tenant shred.
pub fn keyRef(ref_key: Key, identity: []const u8) KeyRef {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, identity, &ref_key);
    var ref: KeyRef = undefined;
    @memcpy(&ref, mac[0..KEY_REF_LEN]);
    if (std.mem.eql(u8, &ref, &TENANT_REF)) ref[KEY_REF_LEN - 1] = 1;
    return ref;
}

/// Wipe key material a caller is done with. Not a substitute for
/// destroying the stored key — this only clears one process's copy.
pub fn wipe(key: *Key) void {
    std.crypto.secureZero(u8, key);
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const test_key: Key = [_]u8{0xA5} ** KEY_LEN;
const test_ref: KeyRef = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

test "seal/open round-trips" {
    const a = testing.allocator;
    const msg = "the quick brown fox";
    const sealed = try sealAlloc(a, msg, test_key, test_ref, 7);
    defer a.free(sealed);

    try testing.expectEqual(sealedLen(msg.len), sealed.len);
    const opened = try openAlloc(a, sealed, test_key);
    defer a.free(opened);
    try testing.expectEqualStrings(msg, opened);
}

test "an empty plaintext still seals and opens" {
    const a = testing.allocator;
    const sealed = try sealAlloc(a, "", test_key, test_ref, 0);
    defer a.free(sealed);
    try testing.expectEqual(OVERHEAD, sealed.len);
    const opened = try openAlloc(a, sealed, test_key);
    defer a.free(opened);
    try testing.expectEqual(@as(usize, 0), opened.len);
}

test "peek reads the header without the key" {
    const a = testing.allocator;
    const sealed = try sealAlloc(a, "payload", test_key, test_ref, 42);
    defer a.free(sealed);

    const h = try peek(sealed);
    try testing.expectEqual(ALG_AES_256_GCM, h.alg_id);
    try testing.expectEqual(@as(u32, 42), h.key_version);
    try testing.expectEqualSlices(u8, &test_ref, &h.key_ref);
}

test "the wrong key fails to open" {
    const a = testing.allocator;
    const sealed = try sealAlloc(a, "secret", test_key, test_ref, 1);
    defer a.free(sealed);

    var other: Key = test_key;
    other[0] ^= 0xFF;
    try testing.expectError(Error.AuthFailed, openAlloc(a, sealed, other));
}

test "tampering with any header field fails authentication" {
    const a = testing.allocator;
    const msg = "authenticated header";

    // Every header byte is covered as AAD, so flipping any of them —
    // version, ref, or nonce — must fail rather than mis-route a read.
    var i: usize = 1;
    while (i < HEADER_LEN) : (i += 1) {
        const sealed = try sealAlloc(a, msg, test_key, test_ref, 3);
        defer a.free(sealed);
        sealed[i] ^= 0x01;
        try testing.expectError(Error.AuthFailed, openAlloc(a, sealed, test_key));
    }
}

test "tampering with ciphertext or tag fails authentication" {
    const a = testing.allocator;
    const msg = "body bytes";

    const ct_tampered = try sealAlloc(a, msg, test_key, test_ref, 1);
    defer a.free(ct_tampered);
    ct_tampered[HEADER_LEN] ^= 0x80;
    try testing.expectError(Error.AuthFailed, openAlloc(a, ct_tampered, test_key));

    const tag_tampered = try sealAlloc(a, msg, test_key, test_ref, 1);
    defer a.free(tag_tampered);
    tag_tampered[tag_tampered.len - 1] ^= 0x01;
    try testing.expectError(Error.AuthFailed, openAlloc(a, tag_tampered, test_key));
}

test "truncated and unknown-algorithm inputs are rejected, not misread" {
    const a = testing.allocator;
    try testing.expectError(Error.Truncated, peek("short"));
    try testing.expectError(Error.Truncated, openedLen(OVERHEAD - 1));

    // An all-zero buffer must not decode as a valid envelope — alg 0 is
    // reserved precisely so zeroed storage never looks sealed.
    const zeros = [_]u8{0} ** (OVERHEAD + 4);
    try testing.expectError(Error.UnknownAlg, peek(&zeros));

    const sealed = try sealAlloc(a, "x", test_key, test_ref, 1);
    defer a.free(sealed);
    sealed[0] = 0xFE;
    try testing.expectError(Error.UnknownAlg, peek(sealed));
}

test "two seals of the same plaintext differ (fresh nonce per seal)" {
    const a = testing.allocator;
    const one = try sealAlloc(a, "same", test_key, test_ref, 1);
    defer a.free(one);
    const two = try sealAlloc(a, "same", test_key, test_ref, 1);
    defer a.free(two);
    try testing.expect(!std.mem.eql(u8, one, two));
}

test "seal rejects a mis-sized output buffer" {
    var small: [8]u8 = undefined;
    try testing.expectError(
        Error.BufferTooSmall,
        seal(&small, "much longer than eight", test_key, test_ref, 1),
    );
}

test "deriveSubkey separates labels and is deterministic" {
    const root = "a stored, shreddable per-tenant secret";
    const logs_a = deriveSubkey(root, "logs");
    const logs_b = deriveSubkey(root, "logs");
    const wal = deriveSubkey(root, "wal");

    try testing.expectEqualSlices(u8, &logs_a, &logs_b);
    try testing.expect(!std.mem.eql(u8, &logs_a, &wal));
}

test "deriveSubkey separates roots — the shred property" {
    // Two tenants' subkeys must be unrelated, so destroying one root
    // cannot leave the other's data readable and vice versa.
    const one = deriveSubkey("tenant-one-secret", "kv");
    const two = deriveSubkey("tenant-two-secret", "kv");
    try testing.expect(!std.mem.eql(u8, &one, &two));
}

test "keyRef is stable, distinguishing, and never the tenant ref" {
    const ref_key = deriveSubkey("root", REF_LABEL);
    const a1 = keyRef(ref_key, "u_7f3a9c");
    const a2 = keyRef(ref_key, "u_7f3a9c");
    const b = keyRef(ref_key, "u_0e11bd");

    try testing.expectEqualSlices(u8, &a1, &a2);
    try testing.expect(!std.mem.eql(u8, &a1, &b));
    try testing.expect(!std.mem.eql(u8, &a1, &TENANT_REF));

    // A different ref key yields a different ref for the same identity,
    // so refs cannot be correlated across tenants.
    const other_key = deriveSubkey("other-root", REF_LABEL);
    try testing.expect(!std.mem.eql(u8, &a1, &keyRef(other_key, "u_7f3a9c")));
}

test "a tenant-ref envelope round-trips like any other" {
    const a = testing.allocator;
    const sealed = try sealAlloc(a, "tenant-level", test_key, TENANT_REF, 1);
    defer a.free(sealed);
    const h = try peek(sealed);
    try testing.expectEqualSlices(u8, &TENANT_REF, &h.key_ref);
    const opened = try openAlloc(a, sealed, test_key);
    defer a.free(opened);
    try testing.expectEqualStrings("tenant-level", opened);
}

test "golden vector — the wire format cannot drift silently" {
    // Nonce is the only non-deterministic input, so a hand-built
    // envelope with a fixed nonce pins the exact byte layout. If this
    // fails, stored ciphertext from an earlier build has been stranded.
    //
    // The expected bytes are NOT this implementation's own output
    // echoed back — a self-referential vector proves nothing. They are
    // cross-checked against an independent AES-GCM (Python
    // `cryptography`, OpenSSL-backed) over the same key, nonce, AAD and
    // plaintext, the way `blob/sigv4.zig` pins its SigV4 vector:
    //
    //   key   = 32 zero bytes        nonce = 12 zero bytes
    //   aad   = 01 01000000 0102030405060708 000000000000000000000000
    //   plain = "rove"
    const key: Key = [_]u8{0} ** KEY_LEN;
    const nonce = [_]u8{0} ** NONCE_LEN;
    const msg = "rove";

    var buf: [OVERHEAD + msg.len]u8 = undefined;
    buf[0] = ALG_AES_256_GCM;
    std.mem.writeInt(u32, buf[1..5], 1, .little);
    @memcpy(buf[5 .. 5 + KEY_REF_LEN], &test_ref);
    @memcpy(buf[5 + KEY_REF_LEN .. HEADER_LEN], &nonce);
    var tag: [TAG_LEN]u8 = undefined;
    Aes256Gcm.encrypt(
        buf[HEADER_LEN .. HEADER_LEN + msg.len],
        &tag,
        msg,
        buf[0..HEADER_LEN],
        nonce,
        key,
    );
    @memcpy(buf[HEADER_LEN + msg.len ..], &tag);

    var hex: [(OVERHEAD + msg.len) * 2]u8 = undefined;
    const got = try std.fmt.bufPrint(&hex, "{x}", .{buf});
    try testing.expectEqualStrings(
        "01010000000102030405060708000000000000000000000000" ++ // header
            "bcc83658" ++ // ciphertext of "rove"
            "e798dc3a3b3eeb824834fd39b2b7f7ae", // tag
        got,
    );

    // Whatever the exact bytes, the envelope must open with the key.
    const opened = try openAlloc(testing.allocator, &buf, key);
    defer testing.allocator.free(opened);
    try testing.expectEqualStrings(msg, opened);
}
