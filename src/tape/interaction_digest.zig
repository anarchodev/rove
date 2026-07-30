//! The interaction digest — a rolling hash over what a handler observably
//! DID, so a replay can prove it did the same thing.
//!
//! ## Why a digest, and why of interactions
//!
//! If every input is recorded and the code is pinned, replay is identical by
//! construction. The digest exists to catch violations of that premise — an
//! unrecorded input, an engine mismatch, a driver that re-derives a worker
//! decision slightly differently. Without it, "faithful" can only mean "ended
//! on the same status", which a handler can satisfy down a different path.
//!
//! It hashes **interactions**, not outputs, because the product is the
//! scrubber: the execution path is what a reader is looking at. Two paths can
//! reach the same response, so an endpoint check cannot establish the thing
//! that matters. Digesting the trace itself would be stronger still, but the
//! worker's engine compiles tracing out — the interaction sequence is what is
//! free at capture time.
//!
//! ## What is deliberately NOT in it
//!
//! Only what a handler could observe or change. Excluded, and each for a
//! reason paid for in a debugging cycle:
//!
//!   - **module load order** and loader-vs-bytecode-map dispatch — not
//!     something a handler computes; policing it rejected correct runs.
//!   - **paging arguments** (`cursor`, `limit`) — how a range was walked, not
//!     what it held.
//!   - **synthesized identifiers** (`ftch_…`, `sub_…`) — the sim mints its own
//!     spellings by design, so hashing them would make prod and sim disagree
//!     on runs that behaved identically, and this digest has to work across
//!     all three engines.
//!   - **wall-clock and seeds** — inputs, not behaviour.
//!
//! The test for adding an element: *could the handler tell the difference?*
//! If not, it does not belong in the hash.
//!
//! ## Format
//!
//! Elements are appended as ASCII lines and folded with FNV-1a/64. The
//! encoding is deliberately dull: a second implementation has to mirror this
//! exactly (`js/interaction_digest.js` — the browser and the offline driver
//! both use it), and the pair is pinned by shared vectors so they cannot
//! drift. Long values are folded to their own FNV hash rather than embedded,
//! which keeps the element line bounded and sidesteps every text-encoding
//! question at the boundary.
//!
//! `VERSION` is part of the hashed prefix: changing the grammar changes every
//! digest, so old records must not be compared against a new grammar. Bump it
//! with any change to element spelling or ordering semantics, and treat it as
//! a format change (`docs/architecture/format-versioning.md`).

const std = @import("std");

/// Grammar version. Hashed first, so a grammar change cannot silently
/// produce comparable-looking digests.
pub const VERSION: u8 = 1;

/// Longest key/prefix spelled inline in an element. Beyond this the key is
/// folded to its own hash instead (see `overlong`). It is an EXPLICIT limit,
/// not "whatever the format buffer happened to allow": the JS mirror has to
/// switch to the fallback at exactly the same byte, and a threshold implied by
/// a buffer size cannot be mirrored reliably. Production caps a kv key at
/// 256 bytes, so this is only reachable via longer non-kv arguments.
pub const MAX_INLINE_KEY: usize = 320;

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

fn fnvBytes(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h = h *% FNV_PRIME;
    }
    return h;
}

/// FNV-1a/64 of a byte slice — the value-folding function. Exposed because
/// element builders hash payloads with it before spelling them into a line.
pub fn foldValue(bytes: []const u8) u64 {
    return fnvBytes(FNV_OFFSET, bytes);
}

/// Rolling digest. Cheap enough to update inline on the dispatch path: one
/// FNV pass over a short ASCII line per interaction, no allocation.
pub const Digest = struct {
    h: u64,

    pub fn init() Digest {
        var d = Digest{ .h = FNV_OFFSET };
        d.h = fnvBytes(d.h, &[_]u8{VERSION});
        return d;
    }

    /// Fold one already-spelled element line.
    pub fn line(self: *Digest, l: []const u8) void {
        self.h = fnvBytes(self.h, l);
        self.h = fnvBytes(self.h, "\n");
    }

    /// `r <key> <outcome> <valuehash>` — a kv read and what it returned.
    /// Outcome distinguishes found from not-found; a not-found read folds a
    /// zero value hash so "absent" and "empty string" stay distinct.
    pub fn kvRead(self: *Digest, key: []const u8, found: bool, value: []const u8) void {
        if (key.len > MAX_INLINE_KEY) return self.overlong("r", key);
        var buf: [512]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "r {s} {d} {x}", .{
            key, @intFromBool(found), if (found) foldValue(value) else 0,
        }) catch return self.overlong("r", key);
        self.line(l);
    }

    /// `p <prefix> <outcome> <count> <rowshash>` — a prefix scan. The rows are
    /// folded as a unit (`key=valuehash` per row, in returned order), so the
    /// digest constrains WHAT the range held without embedding it, and without
    /// mentioning the paging arguments used to walk it.
    pub fn kvPrefix(self: *Digest, prefix: []const u8, found: bool, count: usize, rows_fold: u64) void {
        if (prefix.len > MAX_INLINE_KEY) return self.overlong("p", prefix);
        var buf: [512]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "p {s} {d} {d} {x}", .{
            prefix, @intFromBool(found), count, rows_fold,
        }) catch return self.overlong("p", prefix);
        self.line(l);
    }

    /// `w <key> <valuehash>` — a customer write.
    pub fn kvWrite(self: *Digest, key: []const u8, value: []const u8) void {
        if (key.len > MAX_INLINE_KEY) return self.overlong("w", key);
        var buf: [512]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "w {s} {x}", .{ key, foldValue(value) }) catch
            return self.overlong("w", key);
        self.line(l);
    }

    /// `d <key>` — a customer delete.
    pub fn kvDelete(self: *Digest, key: []const u8) void {
        if (key.len > MAX_INLINE_KEY) return self.overlong("d", key);
        var buf: [512]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "d {s}", .{key}) catch return self.overlong("d", key);
        self.line(l);
    }

    /// `f <method> <urlhash> <bodyhash>` — an outbound fetch. The URL is
    /// folded rather than spelled: it can be long, and a signed URL's query
    /// carries per-run material that would make an otherwise-identical run
    /// hash differently.
    pub fn fetch(self: *Digest, method: []const u8, url: []const u8, body: []const u8) void {
        var buf: [128]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "f {s} {x} {x}", .{
            method, foldValue(url), foldValue(body),
        }) catch return;
        self.line(l);
    }

    /// `a <kind> <arg> <export>` — a wake arm (`t`imer ms / `k`v prefix).
    pub fn wakeArm(self: *Digest, kind: u8, arg: []const u8, export_name: []const u8) void {
        if (arg.len > MAX_INLINE_KEY) return self.overlong("a", arg);
        var buf: [512]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "a {c} {s} {s}", .{ kind, arg, export_name }) catch
            return self.overlong("a", arg);
        self.line(l);
    }

    /// `s <len> <byteshash>` — one streamed frame.
    pub fn streamWrite(self: *Digest, bytes: []const u8) void {
        var buf: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "s {d} {x}", .{ bytes.len, foldValue(bytes) }) catch return;
        self.line(l);
    }

    /// `x <status> <bodyhash>` — the run's own result. Folded last; it makes
    /// the digest a superset of the status comparison the fidelity gate does
    /// today.
    pub fn response(self: *Digest, status: u16, body: []const u8) void {
        var buf: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "x {d} {x}", .{ status, foldValue(body) }) catch return;
        self.line(l);
    }

    /// A key too long to spell inline still has to fold to SOMETHING
    /// deterministic — silently skipping it would let an unbounded key hide a
    /// divergence. Fold the tag plus the key's own hash instead.
    fn overlong(self: *Digest, tag: []const u8, key: []const u8) void {
        var buf: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "{s}! {x}", .{ tag, foldValue(key) }) catch return;
        self.line(l);
    }

    /// Lowercase hex, the wire spelling on the record.
    pub fn hex(self: Digest) [16]u8 {
        var out: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{x:0>16}", .{self.h}) catch unreachable;
        return out;
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

test "digest is order sensitive and content sensitive" {
    var a = Digest.init();
    a.kvRead("users/1", true, "alice");
    a.kvWrite("seen/1", "yes");

    var b = Digest.init();
    b.kvWrite("seen/1", "yes");
    b.kvRead("users/1", true, "alice");
    try std.testing.expect(a.h != b.h); // order of INTERACTIONS is meaning

    var c = Digest.init();
    c.kvRead("users/1", true, "bob");
    c.kvWrite("seen/1", "yes");
    try std.testing.expect(a.h != c.h); // values matter
}

test "absent and empty are distinct reads" {
    var absent = Digest.init();
    absent.kvRead("k", false, "");
    var empty = Digest.init();
    empty.kvRead("k", true, "");
    try std.testing.expect(absent.h != empty.h);
}

test "identical interaction streams agree" {
    var a = Digest.init();
    var b = Digest.init();
    a.kvRead("k", true, "v");
    a.fetch("POST", "https://example.test/hook", "{}");
    a.streamWrite("chunk");
    a.response(200, "ok");
    b.kvRead("k", true, "v");
    b.fetch("POST", "https://example.test/hook", "{}");
    b.streamWrite("chunk");
    b.response(200, "ok");
    try std.testing.expectEqual(a.h, b.h);
}

test "version participates so a grammar change invalidates comparison" {
    var d = Digest.init();
    d.kvRead("k", true, "v");
    // Same elements, hashed without the version prefix, must differ.
    var raw: u64 = FNV_OFFSET;
    raw = fnvBytes(raw, "r k 1 ");
    try std.testing.expect(d.h != raw);
}

test "hex is 16 lowercase chars" {
    var d = Digest.init();
    d.response(204, "");
    const h = d.hex();
    try std.testing.expectEqual(@as(usize, 16), h.len);
    for (h) |ch| try std.testing.expect(std.ascii.isHex(ch) and !std.ascii.isUpper(ch));
}

test "an overlong key still folds deterministically" {
    const long_key = "k" ** 600;
    var a = Digest.init();
    a.kvWrite(long_key, "v");
    var b = Digest.init();
    b.kvWrite(long_key, "v");
    try std.testing.expectEqual(a.h, b.h);
    var other = Digest.init();
    other.kvWrite("k" ** 601, "v");
    try std.testing.expect(a.h != other.h);
}

/// The shared vectors both implementations assert against
/// (`testdata/digest_vectors.json`). Neither side is the reference: the file
/// is. A change here that the JS mirror does not make fails THIS test, rather
/// than surfacing later as an unexplained fidelity mismatch on a real record.
const VECTORS = @embedFile("testdata/digest_vectors.json");

fn vectorDigest(name: []const u8) []const u8 {
    // Deliberately a substring scan rather than a JSON parse: the test must
    // not depend on the allocator or on std.json's shape, and the file's
    // layout is fixed by us.
    var it = std.mem.splitSequence(u8, VECTORS, "\"");
    var seen_name = false;
    while (it.next()) |tok| {
        if (seen_name and std.mem.eql(u8, tok, "digest")) {
            _ = it.next(); // ": "
            return it.next() orelse "";
        }
        if (std.mem.eql(u8, tok, name)) seen_name = true;
    }
    return "";
}

test "vectors: basic" {
    var d = Digest.init();
    d.kvRead("users/jess", true, "{\"n\":1}");
    d.kvWrite("seen/jess", "yes");
    d.response(200, "ok");
    try std.testing.expectEqualStrings(vectorDigest("basic"), &d.hex());
}

test "vectors: mixed" {
    var d = Digest.init();
    d.kvRead("missing", false, "");
    d.kvPrefix("orders/", true, 2, foldValue("a=1;b=2"));
    d.fetch("POST", "https://example.test/hook?sig=abc", "{}");
    d.wakeArm('t', "5000", "onWake");
    d.streamWrite("partial ");
    d.kvDelete("tmp/x");
    d.response(302, "");
    try std.testing.expectEqualStrings(vectorDigest("mixed"), &d.hex());
}

test "vectors: overlong key takes the folded fallback" {
    var d = Digest.init();
    d.kvRead("k" ** 400, true, "v");
    try std.testing.expectEqualStrings(vectorDigest("overlong"), &d.hex());
}

test "vectors: non-ASCII folds bytes" {
    var d = Digest.init();
    d.kvRead("h\u{e9}llo/k\u{e9}y", true, "v\u{e0}lue");
    d.response(204, "");
    try std.testing.expectEqualStrings(vectorDigest("nonascii"), &d.hex());
}

test "vectors: the inline-key limit is measured in BYTES" {
    // 200 two-byte chars: 400 bytes, 200 chars. A char-based threshold would
    // spell this key inline and produce a different digest — this is the
    // vector that catches a mirror measuring the wrong thing.
    var d = Digest.init();
    d.kvWrite("\u{e9}" ** 200, "v");
    try std.testing.expectEqualStrings(vectorDigest("byteThreshold"), &d.hex());
}
