// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Focused decoder for the RTAP per-`Tape` wire format.
//!
//! `rewind pull` writes the recorded request's tape channels as base64 blobs
//! (`record.tapes.{kv,module,request_reads}_tape_b64`); `rewind replay` decodes
//! the three channels it needs to drive the native replay host + rebuild the
//! request. This is a deliberately small, version-guarded reader rather than a
//! link against `rove-tape` (which would drag rove-log + rove-blob + libcurl
//! into the otherwise-lean CLI). It mirrors `src/tape/root.zig`'s
//! `encodeEntry` / per-`Tape` `serialize` exactly — and that mirroring is
//! ENFORCED, not hand-synced: `tape/root.zig` imports this file (as the
//! std-only `tape-decode` module), comptime-asserts MAGIC/VERSION/Channel
//! equality, and round-trips its serializer through these decoders in its
//! tests. Bumping the format there without moving this file is a
//! compile/test failure. The VERSION guard below additionally fails loud
//! at runtime on any tape recorded under a different format.

const std = @import("std");

pub const MAGIC: u32 = 0x52544150; // 'R' 'T' 'A' 'P'
pub const VERSION: u16 = 9; // lockstep-asserted against src/tape/root.zig
/// The oldest layout this reader still understands.
///
/// A range is only sound while every version in it can be told apart by
/// branching on `Reader.version` — which held for v5→v7, where each bump
/// APPENDED a field at the end of an entry and left the fixed prefix in place.
/// v8 moved the `BodyRef` itself: the pool is content-addressed, so the ref
/// grew from a 20-byte `{batch_id, offset, len}` to a 32-byte
/// `{written_unix_ms, digest, offset, len}` in the middle of both the
/// `fetch_responses` and `trigger_payload` layouts. Everything after it shifts,
/// so an older tape read at the new width mis-slices into a plausible-looking
/// wrong answer rather than failing.
///
/// Hence equality, not a range: a tape written before the bump is rejected at
/// `Reader.init` instead of decoded into fiction. Pre-customer, so there is no
/// corpus to keep readable (`docs/decisions.md` — no pre-launch back-compat).
pub const MIN_VERSION: u16 = VERSION;

pub const Channel = enum(u16) {
    kv = 0,
    module = 1,
    fetch_responses = 2,
    trigger_payload = 3,
    request_reads = 4,
    /// The `wake_batch` / `ws_message` activation Msg. Carried here for
    /// the wire-id lockstep only — that channel rides the raft entry so
    /// the promotion walker can rebuild a record, and never reaches a
    /// pulled bundle: the flushed record carries the same Msg as
    /// `activation_bytes`, which is what `rewind replay` reads. Hence
    /// no `decodeActivation` below; a decoder no caller reaches would
    /// rot unnoticed.
    activation = 5,
};

pub const KvOp = enum(u8) { get = 0, set = 1, delete = 2, prefix = 3 };
/// `elided` (4) is a read the capture RESOLVED but did not keep: the
/// activation's kv budget was spent, so `value` carries the lost byte count
/// instead of the bytes (`src/tape/root.zig` `KvOutcome`). A reader must
/// refuse such a read — resolving it as absent or empty hands the handler a
/// plausible value where the live run saw real data.
pub const KvOutcome = enum(u8) { ok = 0, not_found = 1, err = 2, refused = 3, elided = 4 };

/// One kv tape entry. For `prefix`, `value` is empty and `results` holds the
/// returned pairs; otherwise `results` is empty and `value` is the read/written
/// bytes. All slices borrow the input `bytes` (no copy).
pub const KvEntry = struct {
    op: KvOp,
    outcome: KvOutcome,
    key: []const u8,
    value: []const u8 = "",
    results: []const KvPair = &.{},
};
pub const KvPair = struct { key: []const u8, value: []const u8 };

pub const ModuleEntry = struct { specifier: []const u8, source_hash_hex: []const u8 };

pub const RequestReadKind = enum(u8) {
    header_names = 0,
    header_value = 1,
    body_read = 2,
    ip_masked = 3,
    ip_raw = 4,
    /// `request.rewind.isRoot` — the operator-root verdict. `value` is
    /// `"1"` for true, empty for false. Never the bearer that produced
    /// it (`src/tape/root.zig` RequestReadKind).
    root_verdict = 5,
};
pub const RequestReadEntry = struct {
    kind: RequestReadKind,
    name: []const u8,
    value: []const u8,
};

/// One `http.fetch` chunk activation's recorded event (`src/tape/root.zig`
/// `FetchResponseEntry`). The fields a replay needs to rebuild the flattened
/// `request` surface for a `fetch_chunk`: the bytes (`inline_bytes` for the
/// inline path; a non-`none` `pool_ref` means the bytes live in a readset blob,
/// which the offline replay can't fetch), the terminal status/ok, and the
/// shape discriminators (`final`/`seq`) that resolve onFetchResult vs Chunk vs
/// Done. `headers` is the upstream response headers JSON (seq=0 only).
pub const FetchResponseEntry = struct {
    fetch_id: []const u8,
    seq: u32,
    byte_offset: u64,
    /// Pool pointer. Non-`none` means the bytes live in a readset blob.
    pool_ref: PoolRef = .none,
    final: bool,
    terminal_status: u16,
    terminal_ok: bool,
    body_truncated: bool,
    headers: []const u8,
    inline_bytes: []const u8,
    /// The recorded payload length — `body_ref.len`. Set on EVERY shape,
    /// including the two that carry no bytes here, so a reader can tell a
    /// terminal-only event (0 — a transport error, a stream FIN) from an
    /// entry that claims a payload it kept nowhere. Without it those two
    /// are indistinguishable and the second reads as an empty body.
    body_ref_len: u32 = 0,
    /// sha256 hex of the OBJECT this chunk is a slice of, when the bytes were
    /// LEFT in content-addressed storage rather than copied onto the tape — a
    /// `blob.get` (`app-blobs/`) or a static serve (`file-blobs/`). Identical
    /// across the fetch's chunks; resolve a chunk as
    /// `(content_hash, byte_offset, len)`
    /// and is immutable (`blob.*` has no delete) and hash-verified on the
    /// way in (#367). Empty when the bytes rode inline or spilled to the
    /// body pool, and always empty on a v5 tape.
    content_hash: []const u8 = "",
};

/// One trigger-payload entry (`src/tape/root.zig` `TriggerPayloadEntry`). For an
/// inbound activation `inline_bytes` is the request body; for a continuation
/// resume it is the synthesized `{"ctx": …}` envelope. A non-`none` `pool_ref`
/// means the bytes live in a readset blob (not fetchable offline).
pub const TriggerPayloadEntry = struct {
    pool_ref: PoolRef = .none,
    inline_bytes: []const u8,
};

/// Where one entry's payload actually lives. The three pointer shapes a tape
/// entry can carry, plus the two fates that carry nothing — the same
/// classification the log-server's body door resolves against
/// (`src/log_server/body_ref.zig` `locate` is the authority; this is the
/// offline reader's std-only twin, and the two must agree or a payload the
/// door serves reads as absent here).
///
/// A payload over the inline cap is NOT copied onto the entry: the entry keeps
/// a pointer and the bytes stay in object storage. Nothing offline can follow
/// either pointer, so a transcode that ignores the distinction turns a missing
/// input into a plausible empty one.
pub const PayloadFate = union(enum) {
    /// The bytes ride on the entry itself.
    carried: []const u8,
    /// A slice of the cross-tenant body-pool object this ref names.
    pool: PoolRef,
    /// A slice of one of the tenant's content-addressed objects, named by
    /// its 64-hex sha256. The slice is `(byte_offset, body_ref_len)`.
    content: []const u8,
    /// The event genuinely had no payload (a terminal-only fetch chunk).
    empty,
    /// The entry claims a payload and kept neither bytes nor a usable
    /// pointer — the payload was recorded as nothing.
    not_recorded,
};

/// Classify a `fetch_responses` entry's payload. Order matters: carried bytes
/// win over any pointer, and the content reference is checked before the pool
/// because a content-addressed chunk deliberately carries a `none` pool ref —
/// there is no pool object to name.
pub fn fetchPayloadFate(e: FetchResponseEntry) PayloadFate {
    if (e.inline_bytes.len > 0) return .{ .carried = e.inline_bytes };
    if (e.content_hash.len > 0) {
        if (e.content_hash.len != 64 or !isHex(e.content_hash)) return .not_recorded;
        if (e.body_ref_len == 0) return .not_recorded;
        return .{ .content = e.content_hash };
    }
    if (!e.pool_ref.isNone()) return .{ .pool = e.pool_ref };
    if (e.body_ref_len == 0) return .empty;
    return .not_recorded;
}

/// Classify a `trigger_payload` entry's payload. A trigger entry always had a
/// payload — an inbound body or a `{"ctx":…}` envelope — so unlike a fetch
/// chunk there is no legitimate empty case: no bytes and no pool reference is
/// the metadata-only fate an over-cap envelope records.
pub fn triggerPayloadFate(e: TriggerPayloadEntry) PayloadFate {
    if (e.inline_bytes.len > 0) return .{ .carried = e.inline_bytes };
    if (!e.pool_ref.isNone()) return .{ .pool = e.pool_ref };
    return .not_recorded;
}

fn isHex(s: []const u8) bool {
    for (s) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// Digest bytes in a pool reference (`src/blob/pool_object.zig` `DIGEST_LEN`).
pub const POOL_DIGEST_LEN: usize = 16;
/// Wire width of a `PoolRef`: stamp(8) + digest(16) + offset(4) + len(4).
/// Lockstep-asserted against `src/tape/root.zig`.
pub const POOL_REF_WIRE_LEN: usize = 8 + POOL_DIGEST_LEN + 4 + 4;

/// The offline twin of `rove-bodies`' `BodyRef` — a pointer into the
/// cross-tenant body pool. Duplicated rather than imported because this file is
/// deliberately std-only (linking `rove-bodies` would drag rove-blob + libcurl
/// into the lean CLI); `src/tape/root.zig` comptime-asserts the wire width and
/// round-trips its serializer through this decoder, so the copy cannot drift
/// silently.
///
/// The object is CONTENT-ADDRESSED: `written_unix_ms` and `digest` are the two
/// halves of its key, so a holder rebuilds the key without a lookup. A ref with
/// a zero stamp and an all-zero digest names no object at all — the bytes rode
/// inline, or live in content-addressed storage, or were never kept.
pub const PoolRef = struct {
    written_unix_ms: u64 = 0,
    digest: [POOL_DIGEST_LEN]u8 = [_]u8{0} ** POOL_DIGEST_LEN,
    offset: u32 = 0,
    len: u32 = 0,

    pub const none: PoolRef = .{};

    pub fn isNone(self: PoolRef) bool {
        return self.written_unix_ms == 0 and std.mem.allEqual(u8, &self.digest, 0);
    }

    /// `_pool/{written_unix_ms:0>13}-{digest_hex}` — mirrors
    /// `pool_object.formatKey`. `buf` must be at least `POOL_KEY_LEN`.
    pub fn key(self: PoolRef, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "_pool/{d:0>13}-{x}", .{ self.written_unix_ms, self.digest }) catch
            unreachable;
    }
};

/// Buffer size `PoolRef.key` needs.
pub const POOL_KEY_LEN: usize = "_pool/".len + 13 + 1 + POOL_DIGEST_LEN * 2;

/// Read a `PoolRef` at `cur.*`, advancing it. Big-endian throughout, matching
/// every other scalar on this wire.
fn readPoolRef(bytes: []const u8, cur: *usize) Error!PoolRef {
    if (cur.* + POOL_REF_WIRE_LEN > bytes.len) return Error.Truncated;
    var out: PoolRef = .{
        .written_unix_ms = std.mem.readInt(u64, bytes[cur.*..][0..8], .big),
    };
    cur.* += 8;
    @memcpy(&out.digest, bytes[cur.*..][0..POOL_DIGEST_LEN]);
    cur.* += POOL_DIGEST_LEN;
    out.offset = std.mem.readInt(u32, bytes[cur.*..][0..4], .big);
    cur.* += 4;
    out.len = std.mem.readInt(u32, bytes[cur.*..][0..4], .big);
    cur.* += 4;
    return out;
}

pub const Error = error{ BadMagic, BadVersion, ChannelMismatch, Truncated, BadEnum, OutOfMemory };

/// A cursor over one channel's entries, in recorded order. The replay host
/// advances it as the handler reads; `next()` yields the entry bytes to verify
/// + serve. Generic over the per-channel decode fn.
const Reader = struct {
    bytes: []const u8,
    cur: usize,
    remaining: u32,
    channel: Channel,
    /// The layout version THIS tape was written at — not the current one.
    /// Decoders branch on it for version-gated fields.
    version: u16,

    fn init(bytes: []const u8, want: Channel) Error!Reader {
        if (bytes.len < 12) return Error.Truncated;
        if (std.mem.readInt(u32, bytes[0..4], .big) != MAGIC) return Error.BadMagic;
        const ver = std.mem.readInt(u16, bytes[4..6], .big);
        if (ver < MIN_VERSION or ver > VERSION) return Error.BadVersion;
        const ch = std.meta.intToEnum(Channel, std.mem.readInt(u16, bytes[6..8], .big)) catch
            return Error.BadEnum;
        if (ch != want) return Error.ChannelMismatch;
        return .{
            .bytes = bytes,
            .cur = 12,
            .remaining = std.mem.readInt(u32, bytes[8..12], .big),
            .channel = want,
            .version = ver,
        };
    }

    /// The next entry's raw bytes (the `[len][entry]` framing stripped), or null
    /// when the channel is exhausted.
    fn nextRaw(self: *Reader) Error!?[]const u8 {
        if (self.remaining == 0) return null;
        if (self.cur + 4 > self.bytes.len) return Error.Truncated;
        const len = std.mem.readInt(u32, self.bytes[self.cur..][0..4], .big);
        self.cur += 4;
        if (self.cur + len > self.bytes.len) return Error.Truncated;
        const entry = self.bytes[self.cur .. self.cur + len];
        self.cur += len;
        self.remaining -= 1;
        return entry;
    }
};

fn readLenPrefixed(bytes: []const u8, cur: *usize) Error![]const u8 {
    if (cur.* + 4 > bytes.len) return Error.Truncated;
    const len = std.mem.readInt(u32, bytes[cur.*..][0..4], .big);
    cur.* += 4;
    if (cur.* + len > bytes.len) return Error.Truncated;
    const out = bytes[cur.* .. cur.* + len];
    cur.* += len;
    return out;
}

// ── public decoders: one slice of entries per channel ──────────────────────

/// Decode the kv channel into an ordered slice. Slices borrow `bytes`; the
/// returned slice + any `results` slabs are owned by `a`.
pub fn decodeKv(a: std.mem.Allocator, bytes: []const u8) Error![]KvEntry {
    var r = try Reader.init(bytes, .kv);
    var out = std.ArrayList(KvEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        if (e.len < 2) return Error.Truncated;
        const op = std.meta.intToEnum(KvOp, e[0]) catch return Error.BadEnum;
        const outcome = std.meta.intToEnum(KvOutcome, e[1]) catch return Error.BadEnum;
        var cur: usize = 2;
        const key = try readLenPrefixed(e, &cur);
        if (op == .prefix) {
            _ = try readLenPrefixed(e, &cur); // cursor
            if (cur + 8 > e.len) return Error.Truncated;
            cur += 4; // limit
            const count = std.mem.readInt(u32, e[cur..][0..4], .big);
            cur += 4;
            const slab = try a.alloc(KvPair, count);
            for (slab) |*p| {
                p.key = try readLenPrefixed(e, &cur);
                p.value = try readLenPrefixed(e, &cur);
            }
            // v9 trailing field: the lost row bytes of an ELIDED page (the
            // budget dropped it whole), empty on an ordinary page.
            const page_value: []const u8 = if (cur < e.len)
                try readLenPrefixed(e, &cur)
            else
                "";
            try out.append(a, .{
                .op = .prefix,
                .outcome = outcome,
                .key = key,
                .value = page_value,
                .results = slab,
            });
        } else {
            const value = try readLenPrefixed(e, &cur);
            try out.append(a, .{ .op = op, .outcome = outcome, .key = key, .value = value });
        }
    }
    return out.toOwnedSlice(a);
}

pub fn decodeModule(a: std.mem.Allocator, bytes: []const u8) Error![]ModuleEntry {
    var r = try Reader.init(bytes, .module);
    var out = std.ArrayList(ModuleEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        var cur: usize = 0;
        const spec = try readLenPrefixed(e, &cur);
        const hash = try readLenPrefixed(e, &cur);
        try out.append(a, .{ .specifier = spec, .source_hash_hex = hash });
    }
    return out.toOwnedSlice(a);
}

pub fn decodeRequestReads(a: std.mem.Allocator, bytes: []const u8) Error![]RequestReadEntry {
    var r = try Reader.init(bytes, .request_reads);
    var out = std.ArrayList(RequestReadEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        if (e.len < 1) return Error.Truncated;
        const kind = std.meta.intToEnum(RequestReadKind, e[0]) catch return Error.BadEnum;
        var cur: usize = 1;
        const name = try readLenPrefixed(e, &cur);
        const value = try readLenPrefixed(e, &cur);
        try out.append(a, .{ .kind = kind, .name = name, .value = value });
    }
    return out.toOwnedSlice(a);
}

/// Decode the fetch_responses channel (`src/tape/root.zig` `encodeEntry`
/// `.fetch_responses` arm). Slices borrow `bytes`.
pub fn decodeFetchResponses(a: std.mem.Allocator, bytes: []const u8) Error![]FetchResponseEntry {
    var r = try Reader.init(bytes, .fetch_responses);
    var out = std.ArrayList(FetchResponseEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        var cur: usize = 0;
        const fid = try readLenPrefixed(e, &cur);
        // seq(4) + byte_offset(8) + PoolRef(32) + final(1) + status(2) +
        // ok(1) + trunc(1)
        if (cur + 4 + 8 + POOL_REF_WIRE_LEN + 1 + 2 + 1 + 1 > e.len) return Error.Truncated;
        const seq = std.mem.readInt(u32, e[cur..][0..4], .big);
        cur += 4;
        const byte_offset = std.mem.readInt(u64, e[cur..][0..8], .big);
        cur += 8;
        const pool_ref = try readPoolRef(e, &cur);
        const final = e[cur] != 0;
        cur += 1;
        const status = std.mem.readInt(u16, e[cur..][0..2], .big);
        cur += 2;
        const ok = e[cur] != 0;
        cur += 1;
        const trunc = e[cur] != 0;
        cur += 1;
        const headers = try readLenPrefixed(e, &cur);
        const inline_bytes = try readLenPrefixed(e, &cur);
        // The content hash: set when the chunk's bytes were left in
        // content-addressed storage instead of copied here (a `blob.get`
        // result). Empty on an entry that carried its bytes the other way.
        const content_hash: []const u8 = if (cur < e.len)
            try readLenPrefixed(e, &cur)
        else
            "";
        try out.append(a, .{
            .fetch_id = fid,
            .seq = seq,
            .byte_offset = byte_offset,
            .pool_ref = pool_ref,
            .final = final,
            .terminal_status = status,
            .terminal_ok = ok,
            .body_truncated = trunc,
            .headers = headers,
            .inline_bytes = inline_bytes,
            .body_ref_len = pool_ref.len,
            .content_hash = content_hash,
        });
    }
    return out.toOwnedSlice(a);
}

/// Decode the trigger_payload channel (`src/tape/root.zig` `encodeEntry`
/// `.trigger_payload` arm). Slices borrow `bytes`.
pub fn decodeTriggerPayload(a: std.mem.Allocator, bytes: []const u8) Error![]TriggerPayloadEntry {
    var r = try Reader.init(bytes, .trigger_payload);
    var out = std.ArrayList(TriggerPayloadEntry){};
    errdefer out.deinit(a);
    while (try r.nextRaw()) |e| {
        var cur: usize = 0;
        const pool_ref = try readPoolRef(e, &cur);
        const inline_bytes = try readLenPrefixed(e, &cur);
        try out.append(a, .{ .pool_ref = pool_ref, .inline_bytes = inline_bytes });
    }
    return out.toOwnedSlice(a);
}

// ── tests: build bytes per the encodeEntry format, decode, assert ──────────

const testing = std.testing;

fn putHeader(buf: *std.ArrayList(u8), a: std.mem.Allocator, ch: Channel, count: u32) !void {
    var h: [12]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], MAGIC, .big);
    std.mem.writeInt(u16, h[4..6], VERSION, .big);
    std.mem.writeInt(u16, h[6..8], @intFromEnum(ch), .big);
    std.mem.writeInt(u32, h[8..12], count, .big);
    try buf.appendSlice(a, &h);
}
fn putPoolRef(l: *std.ArrayList(u8), a: std.mem.Allocator, ref: PoolRef) !void {
    try putU64(l, a, ref.written_unix_ms);
    try l.appendSlice(a, &ref.digest);
    try putU32(l, a, ref.offset);
    try putU32(l, a, ref.len);
}

/// A distinguishable pool ref for tests, seeded so two seeds differ.
fn tPoolRef(seed: u8, offset: u32, len: u32) PoolRef {
    return .{
        .written_unix_ms = 1_700_000_000_000 + @as(u64, seed),
        .digest = [_]u8{seed} ** POOL_DIGEST_LEN,
        .offset = offset,
        .len = len,
    };
}

fn putLen(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(s.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, s);
}
/// frame one entry payload as [len][payload]
fn putEntry(buf: *std.ArrayList(u8), a: std.mem.Allocator, payload: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(payload.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, payload);
}

test "decodeKv: get + set in order" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .kv, 2);
    // entry 0: get "user" ok -> "ada"
    var e0 = std.ArrayList(u8){};
    defer e0.deinit(a);
    try e0.append(a, @intFromEnum(KvOp.get));
    try e0.append(a, @intFromEnum(KvOutcome.ok));
    try putLen(&e0, a, "user");
    try putLen(&e0, a, "ada");
    try putEntry(&buf, a, e0.items);
    // entry 1: set "seen" ok -> "ada"
    var e1 = std.ArrayList(u8){};
    defer e1.deinit(a);
    try e1.append(a, @intFromEnum(KvOp.set));
    try e1.append(a, @intFromEnum(KvOutcome.ok));
    try putLen(&e1, a, "seen");
    try putLen(&e1, a, "ada");
    try putEntry(&buf, a, e1.items);

    const entries = try decodeKv(a, buf.items);
    defer a.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(KvOp.get, entries[0].op);
    try testing.expectEqualStrings("user", entries[0].key);
    try testing.expectEqualStrings("ada", entries[0].value);
    try testing.expectEqual(KvOp.set, entries[1].op);
    try testing.expectEqualStrings("seen", entries[1].key);
}

test "decodeRequestReads: header_value entry" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .request_reads, 1);
    var e0 = std.ArrayList(u8){};
    defer e0.deinit(a);
    try e0.append(a, @intFromEnum(RequestReadKind.header_value));
    try putLen(&e0, a, "content-type");
    try putLen(&e0, a, "application/json");
    try putEntry(&buf, a, e0.items);

    const entries = try decodeRequestReads(a, buf.items);
    defer a.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(RequestReadKind.header_value, entries[0].kind);
    try testing.expectEqualStrings("content-type", entries[0].name);
    try testing.expectEqualStrings("application/json", entries[0].value);
}

fn putU32(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .big);
    try buf.appendSlice(a, &b);
}
fn putU64(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n, .big);
    try buf.appendSlice(a, &b);
}
fn putU16(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, n, .big);
    try buf.appendSlice(a, &b);
}

test "decodeFetchResponses: terminal entry with inline body" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .fetch_responses, 1);
    var e = std.ArrayList(u8){};
    defer e.deinit(a);
    try putLen(&e, a, "ftch_1"); // fetch_id
    try putU32(&e, a, 0); // seq
    try putU64(&e, a, 0); // byte_offset
    try putPoolRef(&e, a, PoolRef{ .len = 4 }); // names no object: inline
    try e.append(a, 1); // final
    try putU16(&e, a, 502); // status
    try e.append(a, 1); // ok
    try e.append(a, 0); // trunc
    try putLen(&e, a, "{}"); // headers
    try putLen(&e, a, "boom"); // inline_bytes
    try putEntry(&buf, a, e.items);

    const out = try decodeFetchResponses(a, buf.items);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("ftch_1", out[0].fetch_id);
    try testing.expect(out[0].final);
    try testing.expectEqual(@as(u16, 502), out[0].terminal_status);
    try testing.expect(out[0].terminal_ok);
    try testing.expect(out[0].pool_ref.isNone());
    try testing.expectEqualStrings("boom", out[0].inline_bytes);
}

test "decodeTriggerPayload: ctx envelope inline" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .trigger_payload, 1);
    var e = std.ArrayList(u8){};
    defer e.deinit(a);
    try putPoolRef(&e, a, PoolRef.none); // names no object
    try putLen(&e, a, "{\"ctx\":{\"x\":1}}"); // inline_bytes (the synthesized envelope)
    try putEntry(&buf, a, e.items);

    const out = try decodeTriggerPayload(a, buf.items);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(out[0].pool_ref.isNone());
    try testing.expectEqualStrings("{\"ctx\":{\"x\":1}}", out[0].inline_bytes);
}

test "a tape written before the ref changed shape is refused, not mis-sliced" {
    // The `MIN_VERSION` floor. v5-v7 could share a reader because each bump
    // APPENDED a field; v8 moved the `BodyRef` mid-entry, so an older tape
    // read at the new width would slice a plausible wrong answer out of the
    // bytes that follow it. Refusing is the only honest outcome.
    const a = testing.allocator;
    for ([_]u16{ 5, 6, 7 }) |old_version| {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(a);
        var h: [12]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], MAGIC, .big);
        std.mem.writeInt(u16, h[4..6], old_version, .big);
        std.mem.writeInt(u16, h[6..8], @intFromEnum(Channel.fetch_responses), .big);
        std.mem.writeInt(u32, h[8..12], 1, .big);
        try buf.appendSlice(a, &h);
        try testing.expectError(Error.BadVersion, decodeFetchResponses(a, buf.items));
    }
}

test "decodeFetchResponses: a referenced chunk names its bytes instead of carrying them" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .fetch_responses, 1);
    const hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    var e = std.ArrayList(u8){};
    defer e.deinit(a);
    try putLen(&e, a, "f-ref");
    try putU32(&e, a, 0);
    try putU64(&e, a, 0);
    // Names no pool object — the bytes are in content-addressed storage —
    // but keeps the chunk's real size, so the record stays complete.
    try putPoolRef(&e, a, PoolRef{ .len = 4096 });
    try e.append(a, 1);
    try putU16(&e, a, 200);
    try e.append(a, 1);
    try e.append(a, 0);
    try putLen(&e, a, "");
    try putLen(&e, a, ""); // no inline bytes: this is the point
    try putLen(&e, a, hash);
    try putEntry(&buf, a, e.items);

    const out = try decodeFetchResponses(a, buf.items);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(hash, out[0].content_hash);
    // Referenced, never both — a copy alongside the reference would be the
    // duplication the reference exists to remove.
    try testing.expectEqualStrings("", out[0].inline_bytes);
    // The slice length survives the decode: it is half the reconstruction
    // key `(content_hash, byte_offset, len)`, and without it a referenced
    // chunk is indistinguishable from a terminal-only event.
    try testing.expectEqual(@as(u32, 4096), out[0].body_ref_len);
    try testing.expectEqualStrings(hash, fetchPayloadFate(out[0]).content);
}

test "payload fate: the three pointer shapes, and the two that carry nothing" {
    // carried — bytes on the entry win over any pointer.
    try testing.expectEqualStrings("hi", fetchPayloadFate(.{
        .fetch_id = "f",
        .seq = 0,
        .byte_offset = 0,
        .pool_ref = tPoolRef(7, 32, 2),
        .final = true,
        .terminal_status = 200,
        .terminal_ok = true,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "hi",
        .body_ref_len = 2,
    }).carried);
    // pool — a spilled chunk names the cross-tenant pool object.
    const spilled = tPoolRef(7, 32, 65536);
    try testing.expect(std.meta.eql(spilled, fetchPayloadFate(.{
        .fetch_id = "f",
        .seq = 0,
        .byte_offset = 0,
        .pool_ref = spilled,
        .final = false,
        .terminal_status = 0,
        .terminal_ok = false,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .body_ref_len = 65536,
    }).pool));
    // empty vs not_recorded — the discriminator is the recorded LENGTH. A
    // terminal-only event legitimately has no bytes; a non-zero length with
    // no home is a payload the record claims and kept nowhere.
    const terminal_only = decodeFate(0);
    try testing.expect(terminal_only == .empty);
    const claimed = decodeFate(1024);
    try testing.expect(claimed == .not_recorded);
    // A content hash that is not 64 hex names no object — the reference is
    // unusable, so it is the metadata-only fate, never a resolvable one.
    try testing.expect(fetchPayloadFate(.{
        .fetch_id = "f",
        .seq = 0,
        .byte_offset = 0,
        .final = true,
        .terminal_status = 200,
        .terminal_ok = true,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .body_ref_len = 8,
        .content_hash = "zzz",
    }) == .not_recorded);
    // A trigger entry always had a payload, so no-bytes-no-pool is the
    // metadata-only fate rather than an empty one.
    try testing.expect(triggerPayloadFate(.{ .inline_bytes = "" }) == .not_recorded);
    const parked = tPoolRef(9, 32, 4);
    try testing.expect(std.meta.eql(parked, triggerPayloadFate(.{ .pool_ref = parked, .inline_bytes = "" }).pool));
    try testing.expectEqualStrings("{}", triggerPayloadFate(.{ .inline_bytes = "{}" }).carried);
}

fn decodeFate(len: u32) PayloadFate {
    return fetchPayloadFate(.{
        .fetch_id = "f",
        .seq = 0,
        .byte_offset = 0,
        .final = true,
        .terminal_status = 0,
        .terminal_ok = false,
        .body_truncated = false,
        .headers = "",
        .inline_bytes = "",
        .body_ref_len = len,
    });
}

test "version + channel guards fail loud" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try putHeader(&buf, a, .kv, 0);
    // corrupt the version
    std.mem.writeInt(u16, buf.items[4..6], VERSION + 1, .big);
    try testing.expectError(Error.BadVersion, decodeKv(a, buf.items));
    // fix version, ask for the wrong channel
    std.mem.writeInt(u16, buf.items[4..6], VERSION, .big);
    try testing.expectError(Error.ChannelMismatch, decodeModule(a, buf.items));
}
