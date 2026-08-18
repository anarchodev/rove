// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The content-addressed `_pool/` object — its key, its header, and the
//! reference that points into it.
//!
//! ## Why content-addressed
//!
//! The pool is one cross-tenant namespace that every node writes into,
//! so a batch's name has to be unique across nodes. Naming it from a
//! counter makes that a coordination problem, and a counter that is not
//! actually coordinated is silent corruption: two nodes allocate the
//! same id, the second PUT overwrites the first, and the loser's
//! reference resolves to another tenant's bytes with both writes having
//! succeeded.
//!
//! Deriving the name from the content removes the problem rather than
//! solving it. Different content cannot collide; identical content
//! collides harmlessly, because the object that survives is the one the
//! reference describes. No allocator, no reservation, no counter to
//! replay after a restart, and nothing to get wrong at genesis.
//!
//! Note that **dedup is not the goal** and mostly will not happen: a
//! batch packs several submissions, and once bodies are sealed under
//! per-identity keys, identical plaintext yields different ciphertext.
//! The digest is here for collision-freedom, not for sharing.
//!
//! ## The key carries time, on purpose
//!
//! ```
//!   _pool/{written_unix_ms:0>13}-{digest_hex}
//! ```
//!
//! Time first, so a lexical LIST walks the pool in write order and a
//! sweep can `start-after` its cursor and stop at its horizon — O(what
//! it deletes) rather than O(everything ever written). This is the same
//! reason `_logs/{node}/{flush_ns}-…` leads with flush time.
//!
//! A pure content hash would carry no time, leaving a sweep to either
//! GET every object's header or trust S3's `LastModified` — which a
//! copy or a restore silently resets.
//!
//! The stamp is taken once, when the batch is sealed, NOT at PUT time.
//! A retried upload therefore lands on the same key, so a timed-out PUT
//! that actually succeeded is idempotent rather than duplicated.
//!
//! ## What the header is for
//!
//! Pool objects have no framing today — submissions are concatenated
//! and the reference's `(offset, len)` is the only index, so a
//! truncated or mis-resolved object is undetectable. The header fixes
//! that and carries what a future GC needs:
//!
//! ```
//!   [4B magic][2B version][8B written_unix_ms][4B count]
//!   ([8B tenant][4B offset][4B len]){count}
//!   [payload …]
//! ```
//!
//! A sweep range-GETs the head — the same move `log_server/indexer.zig`
//! makes on a log batch's embedded sidecar — and learns, without
//! reading the bytes:
//!
//!  - **when** it was written, from the object itself rather than from
//!    object-store metadata;
//!  - **which tenants** have bytes in it. A batch is cross-tenant, so
//!    per-tenant eviction needs a rewrite; but knowing the membership is
//!    what lets a sweep say "every tenant in here is deprovisioned, drop
//!    the whole object" — which is the case worth catching cheaply;
//!  - **the extents**, so a reference can be checked against a real
//!    entry instead of reading whatever bytes lie at an offset.
//!
//! Tenants appear as a hash, not a name: the header is metadata a sweep
//! reads, and a plaintext tenant list would put customer identity in an
//! object whose whole point is being cross-tenant.
//!
//! The digest covers the WHOLE serialized object, header included, so a
//! reader can confirm it fetched what its reference names — the check
//! that a counter-keyed pool could never make.

const std = @import("std");

pub const MAGIC: u32 = 0x52504C31; // 'RPL1'
pub const VERSION: u16 = 1;

/// Digest bytes kept in a reference and in the key. 16 bytes is a
/// birthday bound around 2^64 objects — unreachable — while keeping a
/// reference small enough to ride every readset that spilled a body.
pub const DIGEST_LEN: usize = 16;

pub const Digest = [DIGEST_LEN]u8;

/// `[4B magic][2B version][8B written_unix_ms][4B count]`
pub const HEADER_LEN: usize = 4 + 2 + 8 + 4;
/// `[8B tenant][4B offset][4B len]`
pub const ENTRY_LEN: usize = 8 + 4 + 4;

/// Cap on entries in one batch. A bound the decoder can trust before it
/// allocates, and far above what a drain cycle collects.
pub const MAX_ENTRIES: usize = 1 << 16;

/// `_pool/` + 13-digit ms + `-` + hex digest.
pub const KEY_LEN: usize = "_pool/".len + 13 + 1 + DIGEST_LEN * 2;

pub const Error = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    TooManyEntries,
    /// The entry table does not describe the payload that follows it.
    Inconsistent,
    OutOfMemory,
};

/// Points at one submission's bytes inside a pool object.
///
/// Carries what the key needs — the stamp and the digest — so a holder
/// can rebuild the key without a lookup, the same way the counter-keyed
/// reference it replaces could.
pub const Ref = struct {
    written_unix_ms: u64,
    digest: Digest,
    offset: u32,
    len: u32,

    /// The "no body" sentinel: inline path, or a body that was never
    /// parked. A zero stamp is never minted, because a real batch is
    /// always sealed at a real wall-clock time.
    pub const none: Ref = .{
        .written_unix_ms = 0,
        .digest = [_]u8{0} ** DIGEST_LEN,
        .offset = 0,
        .len = 0,
    };

    pub fn isNone(self: Ref) bool {
        return self.written_unix_ms == 0 and std.mem.allEqual(u8, &self.digest, 0);
    }

    /// Format this ref's object key into `buf`, which must be at least
    /// `KEY_LEN`. Returns a slice of `buf`.
    pub fn key(self: Ref, buf: []u8) []u8 {
        return formatKey(self.written_unix_ms, self.digest, buf);
    }
};

/// `_pool/{written_unix_ms:0>13}-{digest_hex}`.
///
/// 13 digits holds milliseconds past the year 2286 and, being fixed
/// width, keeps lexical order equal to time order — which is what makes
/// a cursored sweep possible.
pub fn formatKey(written_unix_ms: u64, digest: Digest, buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "_pool/{d:0>13}-{x}", .{ written_unix_ms, digest }) catch
        unreachable;
}

/// The write time a key encodes, for a sweep that only has the listing.
/// Null when the key is not one of ours — a foreign object under the
/// prefix is skipped rather than aged.
pub fn keyWrittenMs(key_str: []const u8) ?u64 {
    const prefix = "_pool/";
    if (!std.mem.startsWith(u8, key_str, prefix)) return null;
    const rest = key_str[prefix.len..];
    if (rest.len != 13 + 1 + DIGEST_LEN * 2) return null;
    if (rest[13] != '-') return null;
    return std.fmt.parseInt(u64, rest[0..13], 10) catch null;
}

/// One submission as the header describes it.
pub const Entry = struct {
    /// `hashStoreId`-shaped tenant hash. A hash, not a name: this is
    /// sweep metadata living in a cross-tenant object.
    tenant: u64,
    offset: u32,
    len: u32,
};

/// What a sweep learns from range-GETting the head of an object.
pub const Header = struct {
    written_unix_ms: u64,
    count: u32,

    /// Bytes to fetch to be sure of covering the header and its entry
    /// table. A sweep reads this much and no more.
    pub fn tableEnd(self: Header) usize {
        return HEADER_LEN + @as(usize, self.count) * ENTRY_LEN;
    }
};

/// Decode just the fixed header. Enough to age an object; `decodeEntry`
/// walks the table for tenant membership.
pub fn decodeHeader(bytes: []const u8) Error!Header {
    if (bytes.len < HEADER_LEN) return Error.Truncated;
    if (std.mem.readInt(u32, bytes[0..4], .big) != MAGIC) return Error.BadMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != VERSION) return Error.UnsupportedVersion;
    const count = std.mem.readInt(u32, bytes[14..18], .little);
    if (count > MAX_ENTRIES) return Error.TooManyEntries;
    return .{
        .written_unix_ms = std.mem.readInt(u64, bytes[6..14], .little),
        .count = count,
    };
}

/// Read entry `i` from a buffer holding at least the header and table.
pub fn decodeEntry(bytes: []const u8, i: u32) Error!Entry {
    const at = HEADER_LEN + @as(usize, i) * ENTRY_LEN;
    if (bytes.len < at + ENTRY_LEN) return Error.Truncated;
    return .{
        .tenant = std.mem.readInt(u64, bytes[at..][0..8], .little),
        .offset = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little),
        .len = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little),
    };
}

/// One submission handed to `seal`.
pub const Submission = struct {
    tenant: u64,
    bytes: []const u8,
};

/// A sealed object plus the refs its submissions resolve to.
pub const Sealed = struct {
    /// The object to PUT. Caller frees.
    bytes: []u8,
    /// One ref per input submission, in order. Caller frees.
    refs: []Ref,
    digest: Digest,
    written_unix_ms: u64,

    pub fn deinit(self: *Sealed, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.refs);
    }

    pub fn key(self: Sealed, buf: []u8) []u8 {
        return formatKey(self.written_unix_ms, self.digest, buf);
    }
};

/// Build a pool object from `subs`, stamped `written_unix_ms`.
///
/// The stamp is a parameter rather than read here so a retry seals to
/// the same bytes, and therefore the same key: a PUT that timed out
/// after succeeding is then a no-op rather than a second object.
pub fn seal(
    allocator: std.mem.Allocator,
    subs: []const Submission,
    written_unix_ms: u64,
) Error![]u8 {
    if (subs.len > MAX_ENTRIES) return Error.TooManyEntries;

    var payload_len: usize = 0;
    for (subs) |s| {
        if (s.bytes.len > std.math.maxInt(u32)) return Error.Inconsistent;
        payload_len += s.bytes.len;
    }
    const table_end = HEADER_LEN + subs.len * ENTRY_LEN;
    const total = table_end + payload_len;
    if (total > std.math.maxInt(u32)) return Error.Inconsistent;

    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    errdefer allocator.free(out);

    std.mem.writeInt(u32, out[0..4], MAGIC, .big);
    std.mem.writeInt(u16, out[4..6], VERSION, .little);
    std.mem.writeInt(u64, out[6..14], written_unix_ms, .little);
    std.mem.writeInt(u32, out[14..18], @intCast(subs.len), .little);

    var pos = table_end;
    for (subs, 0..) |s, i| {
        const at = HEADER_LEN + i * ENTRY_LEN;
        std.mem.writeInt(u64, out[at..][0..8], s.tenant, .little);
        std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(pos), .little);
        std.mem.writeInt(u32, out[at + 12 ..][0..4], @intCast(s.bytes.len), .little);
        @memcpy(out[pos..][0..s.bytes.len], s.bytes);
        pos += s.bytes.len;
    }
    std.debug.assert(pos == total);
    return out;
}

/// `seal`, plus the digest and the per-submission refs.
pub fn sealWithRefs(
    allocator: std.mem.Allocator,
    subs: []const Submission,
    written_unix_ms: u64,
) Error!Sealed {
    const bytes = try seal(allocator, subs, written_unix_ms);
    errdefer allocator.free(bytes);

    const digest = digestOf(bytes);

    const refs = allocator.alloc(Ref, subs.len) catch return Error.OutOfMemory;
    errdefer allocator.free(refs);
    for (subs, 0..) |_, i| {
        const e = try decodeEntry(bytes, @intCast(i));
        refs[i] = .{
            .written_unix_ms = written_unix_ms,
            .digest = digest,
            .offset = e.offset,
            .len = e.len,
        };
    }
    return .{
        .bytes = bytes,
        .refs = refs,
        .digest = digest,
        .written_unix_ms = written_unix_ms,
    };
}

/// The digest naming an object: SHA-256 over the whole serialized form,
/// truncated to `DIGEST_LEN`. Covering the header too means a reader can
/// verify it fetched the object its ref names, header and all.
pub fn digestOf(bytes: []const u8) Digest {
    var full: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &full, .{});
    var out: Digest = undefined;
    @memcpy(&out, full[0..DIGEST_LEN]);
    return out;
}

/// Structural check over a whole object: the table must describe
/// exactly the payload that follows, with entries contiguous and in
/// order. Refuses rather than trusting an offset into bytes that may
/// not be an entry at all.
pub fn validate(bytes: []const u8) Error!Header {
    const h = try decodeHeader(bytes);
    const table_end = h.tableEnd();
    if (bytes.len < table_end) return Error.Truncated;

    var expect: usize = table_end;
    var i: u32 = 0;
    while (i < h.count) : (i += 1) {
        const e = try decodeEntry(bytes, i);
        // Contiguous and ascending: `seal` lays entries end to end, so
        // a gap or an overlap means these bytes were not written by this
        // codec — and an overlap would let one ref read another's body.
        if (e.offset != expect) return Error.Inconsistent;
        expect = std.math.add(usize, expect, e.len) catch return Error.Inconsistent;
    }
    if (expect != bytes.len) return Error.Inconsistent;
    return h;
}

/// The bytes `ref` names, checked against the object's own table rather
/// than sliced at face value. `null` when the object does not contain
/// that extent.
pub fn resolve(bytes: []const u8, ref: Ref) Error!?[]const u8 {
    const h = try validate(bytes);
    var i: u32 = 0;
    while (i < h.count) : (i += 1) {
        const e = try decodeEntry(bytes, i);
        if (e.offset == ref.offset and e.len == ref.len) {
            return bytes[e.offset..][0..e.len];
        }
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn subs3() [3]Submission {
    return .{
        .{ .tenant = 0x1111, .bytes = "alpha" },
        .{ .tenant = 0x2222, .bytes = "bravobravo" },
        .{ .tenant = 0x1111, .bytes = "c" },
    };
}

test "seal round-trips every submission through its ref" {
    const a = testing.allocator;
    const subs = subs3();
    var sealed = try sealWithRefs(a, &subs, 1_700_000_000_000);
    defer sealed.deinit(a);

    for (subs, sealed.refs) |s, ref| {
        const got = (try resolve(sealed.bytes, ref)).?;
        try testing.expectEqualStrings(s.bytes, got);
    }
}

test "the key is content-derived, so different content cannot collide" {
    const a = testing.allocator;
    const stamp: u64 = 1_700_000_000_000;

    const one = try sealWithRefs(a, &.{.{ .tenant = 1, .bytes = "aaa" }}, stamp);
    var m_one = one;
    defer m_one.deinit(a);
    const two = try sealWithRefs(a, &.{.{ .tenant = 1, .bytes = "bbb" }}, stamp);
    var m_two = two;
    defer m_two.deinit(a);

    // Same stamp, different bytes — the whole failure this replaces was
    // two writers naming different content identically.
    try testing.expect(!std.mem.eql(u8, &one.digest, &two.digest));

    var k1: [KEY_LEN]u8 = undefined;
    var k2: [KEY_LEN]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, one.key(&k1), two.key(&k2)));
}

test "identical content and stamp collide harmlessly — a retried PUT is idempotent" {
    const a = testing.allocator;
    const subs = subs3();
    var s1 = try sealWithRefs(a, &subs, 1_700_000_000_000);
    defer s1.deinit(a);
    var s2 = try sealWithRefs(a, &subs, 1_700_000_000_000);
    defer s2.deinit(a);

    // Byte-identical object, identical key: a PUT that timed out after
    // landing is a no-op on retry rather than a second object.
    try testing.expectEqualSlices(u8, s1.bytes, s2.bytes);
    try testing.expectEqualSlices(u8, &s1.digest, &s2.digest);
}

test "the key sorts lexically in time order, which is what a sweep walks" {
    var early: [KEY_LEN]u8 = undefined;
    var late: [KEY_LEN]u8 = undefined;
    const d: Digest = [_]u8{0xFF} ** DIGEST_LEN;
    const d2: Digest = [_]u8{0x00} ** DIGEST_LEN;

    // Later time sorts later even when its digest sorts first, so a
    // cursored LIST cannot skip an object it has not seen.
    const k_early = formatKey(1_700_000_000_000, d, &early);
    const k_late = formatKey(1_700_000_000_001, d2, &late);
    try testing.expect(std.mem.order(u8, k_early, k_late) == .lt);
}

test "a sweep can age an object from the key alone" {
    var buf: [KEY_LEN]u8 = undefined;
    const stamp: u64 = 1_700_000_000_123;
    const k = formatKey(stamp, [_]u8{0xAB} ** DIGEST_LEN, &buf);
    try testing.expectEqual(stamp, keyWrittenMs(k).?);

    // A foreign object under the prefix is skipped, not aged.
    try testing.expect(keyWrittenMs("_pool/not-ours") == null);
    try testing.expect(keyWrittenMs("_logs/00000001/x.ndjson") == null);
}

test "the header gives a sweep tenant membership without reading bodies" {
    const a = testing.allocator;
    const subs = subs3();
    var sealed = try sealWithRefs(a, &subs, 42);
    defer sealed.deinit(a);

    // Range-GET the head only — the move the log indexer already makes
    // on an embedded sidecar.
    const h = try decodeHeader(sealed.bytes);
    try testing.expectEqual(@as(u64, 42), h.written_unix_ms);
    try testing.expectEqual(@as(u32, 3), h.count);
    const head = sealed.bytes[0..h.tableEnd()];

    var saw_a = false;
    var saw_b = false;
    var i: u32 = 0;
    while (i < h.count) : (i += 1) {
        const e = try decodeEntry(head, i);
        if (e.tenant == 0x1111) saw_a = true;
        if (e.tenant == 0x2222) saw_b = true;
    }
    try testing.expect(saw_a and saw_b);
}

test "validate rejects truncation, bad magic, and a future version" {
    const a = testing.allocator;
    const subs = subs3();
    const bytes = try seal(a, &subs, 1);
    defer a.free(bytes);

    _ = try validate(bytes);

    // Below the header there is nothing to interpret; above it, a short
    // object is an object whose table promises bytes it does not have.
    // Both are refused, and the distinction says which.
    try testing.expectError(Error.Truncated, validate(""));
    try testing.expectError(Error.Truncated, validate(bytes[0 .. HEADER_LEN - 1]));
    try testing.expectError(Error.Inconsistent, validate(bytes[0 .. bytes.len - 1]));

    const bad = try a.dupe(u8, bytes);
    defer a.free(bad);
    bad[0] ^= 0xFF;
    try testing.expectError(Error.BadMagic, validate(bad));

    const future = try a.dupe(u8, bytes);
    defer a.free(future);
    std.mem.writeInt(u16, future[4..6], VERSION + 1, .little);
    try testing.expectError(Error.UnsupportedVersion, validate(future));
}

test "an overlapping or gapped entry table is refused" {
    const a = testing.allocator;
    const subs = subs3();
    const bytes = try seal(a, &subs, 1);
    defer a.free(bytes);

    // Overlap would let one ref read into another submission's bytes —
    // the same cross-tenant read the counter collision produced, just
    // from inside one object.
    const overlap = try a.dupe(u8, bytes);
    defer a.free(overlap);
    const at = HEADER_LEN + ENTRY_LEN; // second entry
    std.mem.writeInt(u32, overlap[at + 8 ..][0..4], @intCast(HEADER_LEN + 3 * ENTRY_LEN), .little);
    try testing.expectError(Error.Inconsistent, validate(overlap));

    const gap = try a.dupe(u8, bytes);
    defer a.free(gap);
    std.mem.writeInt(u32, gap[at + 12 ..][0..4], 1, .little); // shrink → trailing gap
    try testing.expectError(Error.Inconsistent, validate(gap));
}

test "resolve refuses an extent the object does not describe" {
    const a = testing.allocator;
    const subs = subs3();
    var sealed = try sealWithRefs(a, &subs, 1);
    defer sealed.deinit(a);

    // An offset that lands inside a real entry but is not one: sliced at
    // face value this would return another submission's tail.
    var bogus = sealed.refs[0];
    bogus.offset += 1;
    try testing.expect((try resolve(sealed.bytes, bogus)) == null);

    bogus = sealed.refs[0];
    bogus.len += 1;
    try testing.expect((try resolve(sealed.bytes, bogus)) == null);
}

test "the none sentinel is distinguishable and never minted" {
    try testing.expect(Ref.none.isNone());
    const real: Ref = .{
        .written_unix_ms = 1,
        .digest = [_]u8{0} ** DIGEST_LEN,
        .offset = 0,
        .len = 0,
    };
    // A real batch always carries a real wall-clock stamp, so a zero
    // stamp is what makes the sentinel unmintable.
    try testing.expect(!real.isNone());
}

test "an empty batch seals and validates" {
    const a = testing.allocator;
    const bytes = try seal(a, &.{}, 7);
    defer a.free(bytes);
    const h = try validate(bytes);
    try testing.expectEqual(@as(u32, 0), h.count);
    try testing.expectEqual(@as(usize, HEADER_LEN), bytes.len);
}
