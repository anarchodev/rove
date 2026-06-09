//! V2 raft-log envelope codec — the typed byte blob that travels through
//! a tenant's raft group and is decoded at apply time (`node.zig`).
//!
//! This is the V2 spine's own copy of the wire format V1 owns in
//! `src/kv/cluster.zig` + `src/js/apply.zig`. The format is held
//! byte-identical on purpose (`[1B type][2B id_len BE][id][payload]`,
//! type numbering matching V1's `EnvelopeType`) so the apply payload is
//! unchanged across the rewrite — but the V2 spine owns its codec
//! outright because V1's `cluster.zig` is deleted at cutover
//! (docs/v2-build-order.md "clean-slate the spine, reuse the limbs").
//!
//! The type-0 payload is the **readset-framed** `WriteSetPayload`
//! (`[u32 ws_len][ws][u32 rs_len][rs]`), byte-identical to the worker's
//! `src/js/apply.zig` so a worker propose applies unchanged on a V2
//! follower (`decodeWriteSetPayload` strips the frame; apply uses
//! `ws_bytes`, the readset rides for the tape). The header codec
//! (`[1B type][2B id_len BE][id][payload]`) is unchanged. (Earlier Phase-1
//! slices carried a raw-writeset payload; that only ever flowed on a
//! single-node leader, which skips apply, so the mismatch was latent until
//! a real follower applied a worker entry in Phase 5 multi-node.)

const std = @import("std");

/// Max length of an envelope `id` (the tenant store id string). Mirrors
/// V1's `MAX_ID_LEN`; the 2-byte big-endian length field caps it at
/// 65535 regardless, this is the tighter sanity bound.
pub const MAX_ID_LEN: usize = 512;

pub const Error = error{
    Truncated,
    IdTooLong,
    UnknownEnvelopeType,
    NestedMulti,
    /// A raft entry did not start with the `ENTRY_FRAME_MAGIC` byte —
    /// every V2 entry is origin-framed at propose; a bare envelope in
    /// the log is a producer bug (or a stale pre-frame entry, which a
    /// pre-launch data-dir wipe removes).
    BadEntryFrame,
    OutOfMemory,
};

// ── Entry frame (origin identity) ─────────────────────────────────────
//
// Every proposed raft entry is wrapped in a fixed 17-byte frame BEFORE
// the envelope:
//
//     [1B ENTRY_FRAME_MAGIC][8B origin LE][8B seq LE][envelope bytes]
//
// `origin` is the proposing bridge's per-boot random id and `seq` its
// per-tenant propose ticket — together the entry's IDENTITY. The apply
// path uses them to (a) bind a committed entry to the exact local
// propose awaiting it (the bridge advances `committed_seq` only for
// `origin == its own id`, never by FIFO position — a resurrected
// old-term entry committing after re-election can no longer mis-credit
// a different propose's waiter), and (b) key the worker-overlay store
// skip on true provenance ("THIS node's worker wrote this entry and its
// txn is still live"), not on currently-being-leader — a freshly-elected
// leader catching up on another proposer's entries must WRITE them.
// A random per-boot origin (not the node id) also fences a restarted
// node's WAL replay from colliding with the new incarnation's seqs.
// `origin = 0, seq = 0` marks a hookless propose (tests, bare nodes):
// it matches no bridge, so it is never skipped and never advances a
// watermark.

/// First byte of every framed entry. Deliberately outside the envelope
/// `Type` range (0..=2) so a missing frame fails loud (`BadEntryFrame`)
/// instead of mis-decoding.
pub const ENTRY_FRAME_MAGIC: u8 = 0xF7;

/// Bytes of the frame header preceding the envelope.
pub const ENTRY_FRAME_LEN: usize = 1 + 8 + 8;

pub const EntryFrame = struct {
    /// Proposing bridge's per-boot random id (0 = hookless propose).
    origin: u64,
    /// Proposer's per-tenant seq ticket (0 = hookless propose).
    seq: u64,
    /// The framed envelope bytes; borrows the input.
    env_bytes: []const u8,
};

/// Wrap an encoded envelope in the entry frame. Caller owns the result.
pub fn encodeEntryFrame(
    allocator: std.mem.Allocator,
    origin: u64,
    seq: u64,
    env_bytes: []const u8,
) Error![]u8 {
    const out = allocator.alloc(u8, ENTRY_FRAME_LEN + env_bytes.len) catch return Error.OutOfMemory;
    out[0] = ENTRY_FRAME_MAGIC;
    std.mem.writeInt(u64, out[1..9], origin, .little);
    std.mem.writeInt(u64, out[9..17], seq, .little);
    @memcpy(out[ENTRY_FRAME_LEN..], env_bytes);
    return out;
}

/// Decode the entry frame. `env_bytes` aliases `bytes`. The magic
/// check precedes the length check so an unframed envelope of any
/// length reports `BadEntryFrame`, not `Truncated`.
pub fn decodeEntryFrame(bytes: []const u8) Error!EntryFrame {
    if (bytes.len == 0) return Error.Truncated;
    if (bytes[0] != ENTRY_FRAME_MAGIC) return Error.BadEntryFrame;
    if (bytes.len < ENTRY_FRAME_LEN) return Error.Truncated;
    return .{
        .origin = std.mem.readInt(u64, bytes[1..9], .little),
        .seq = std.mem.readInt(u64, bytes[9..17], .little),
        .env_bytes = bytes[ENTRY_FRAME_LEN..],
    };
}

/// Envelope type byte. Numbering matches V1's `apply.EnvelopeType` so
/// the wire format is stable across the cutover. Retired V1 slots
/// (3..=11) are intentionally absent — `decode` rejects any byte that
/// isn't a live variant as `UnknownEnvelopeType`, so a stale entry
/// surfaces loudly instead of mis-applying.
pub const Type = enum(u8) {
    /// Per-tenant writeset. `id` = tenant store id; payload = the raw
    /// `writeset.WriteSet.encode` bytes (Phase 1: no readset section).
    writeset = 0,
    /// Multi-envelope wrapper. `id` empty; payload =
    /// `[u8 count]([u32 len LE][inner_envelope]){count}`. Inner
    /// envelopes apply in order; nesting panics (`NestedMulti`).
    multi = 1,
    /// Root writeset — applied to the node-wide `__root__` store.
    /// Producer is the control plane (provisionInstance / admin), which
    /// arrives in Phase 2+; decode is supported here so the type round-
    /// trips, but `node.zig`'s apply path does not route it in Phase 1.
    root_writeset = 2,
};

pub const Envelope = struct {
    type: Type,
    /// Tenant store id for `writeset`; empty for `multi` / `root_writeset`.
    /// Borrowed slice into the decoded buffer.
    id: []const u8,
    /// Borrowed slice into the decoded buffer.
    payload: []const u8,
};

/// Decode the `[1B type][2B id_len BE][id][payload]` header. Returned
/// slices alias `bytes`; valid only while `bytes` lives.
pub fn decode(bytes: []const u8) Error!Envelope {
    if (bytes.len < 3) return Error.Truncated;
    const raw_type = bytes[0];
    const id_len = std.mem.readInt(u16, bytes[1..3], .big);
    if (bytes.len < 3 + @as(usize, id_len)) return Error.Truncated;
    const t = std.meta.intToEnum(Type, raw_type) catch return Error.UnknownEnvelopeType;
    return .{
        .type = t,
        .id = bytes[3 .. 3 + id_len],
        .payload = bytes[3 + id_len ..],
    };
}

fn encodeTyped(
    allocator: std.mem.Allocator,
    t: Type,
    id: []const u8,
    payload: []const u8,
) Error![]u8 {
    if (id.len > MAX_ID_LEN) return Error.IdTooLong;
    const total = 1 + 2 + id.len + payload.len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    out[0] = @intFromEnum(t);
    std.mem.writeInt(u16, out[1..3], @intCast(id.len), .big);
    @memcpy(out[3 .. 3 + id.len], id);
    @memcpy(out[3 + id.len ..], payload);
    return out;
}

/// Type-0 payload layout (`docs/readset-replication-plan.md` Phase 3),
/// byte-identical to the worker's `src/js/apply.zig` `WriteSetPayload`:
///
///   `[u32 LE ws_len][ws_bytes][u32 LE rs_len][rs_bytes]`
///
/// The type-0 envelope payload is NOT raw writeset bytes — it interleaves
/// the writeset with the request's serialized readset so the tape can be
/// reconstructed on any follower that applies the entry. `rs_len == 0` is
/// valid + frequent (non-handler producers — ACME, the move surface's
/// `v2-kv`, the secondary inners of a batch — carry an empty readset). The
/// V2 spine owns this codec because V1's `apply.zig` is deleted at cutover;
/// it is held identical so the bytes the worker proposes apply unchanged.
/// Apply only needs `ws_bytes`; the readset rides for the tape (Phase 5+).
pub const WriteSetPayload = struct {
    ws_bytes: []const u8,
    rs_bytes: []const u8,
};

pub fn decodeWriteSetPayload(payload: []const u8) Error!WriteSetPayload {
    if (payload.len < 4) return Error.Truncated;
    const ws_len = std.mem.readInt(u32, payload[0..4], .little);
    if (payload.len < 4 + @as(usize, ws_len) + 4) return Error.Truncated;
    const ws_bytes = payload[4 .. 4 + ws_len];
    const rs_len = std.mem.readInt(u32, payload[4 + ws_len ..][0..4], .little);
    const rs_start: usize = 4 + ws_len + 4;
    if (payload.len != rs_start + rs_len) return Error.Truncated;
    return .{ .ws_bytes = ws_bytes, .rs_bytes = payload[rs_start .. rs_start + rs_len] };
}

pub fn encodeWriteSetPayload(
    allocator: std.mem.Allocator,
    ws_bytes: []const u8,
    rs_bytes: []const u8,
) Error![]u8 {
    const total = 4 + ws_bytes.len + 4 + rs_bytes.len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    std.mem.writeInt(u32, out[0..4], @intCast(ws_bytes.len), .little);
    @memcpy(out[4..][0..ws_bytes.len], ws_bytes);
    std.mem.writeInt(u32, out[4 + ws_bytes.len ..][0..4], @intCast(rs_bytes.len), .little);
    @memcpy(out[4 + ws_bytes.len + 4 ..][0..rs_bytes.len], rs_bytes);
    return out;
}

/// Build a type-0 writeset envelope. `ws_bytes` is the output of
/// `writeset.WriteSet.encode`; it is wrapped in the readset-framed payload
/// (empty readset) so the bytes are wire-identical to a worker propose.
/// Caller owns the returned slice.
pub fn encodeWriteSet(
    allocator: std.mem.Allocator,
    id: []const u8,
    ws_bytes: []const u8,
) Error![]u8 {
    const payload = try encodeWriteSetPayload(allocator, ws_bytes, "");
    defer allocator.free(payload);
    return encodeTyped(allocator, .writeset, id, payload);
}

/// Build a type-2 root writeset envelope (no per-tenant id).
pub fn encodeRootWriteSet(
    allocator: std.mem.Allocator,
    ws_bytes: []const u8,
) Error![]u8 {
    return encodeTyped(allocator, .root_writeset, "", ws_bytes);
}

/// Build a type-1 multi wrapper carrying `inner` already-encoded
/// envelopes. Inner envelopes must not themselves be type-1
/// (`NestedMulti`). Caller owns the returned slice.
pub fn encodeMulti(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) Error![]u8 {
    if (inner.len > 0xff) return Error.OutOfMemory;
    var inner_total: usize = 0;
    for (inner) |b| inner_total += 4 + b.len;
    const payload = allocator.alloc(u8, 1 + inner_total) catch return Error.OutOfMemory;
    defer allocator.free(payload);
    payload[0] = @intCast(inner.len);
    var pos: usize = 1;
    for (inner) |b| {
        std.mem.writeInt(u32, payload[pos..][0..4], @intCast(b.len), .little);
        pos += 4;
        @memcpy(payload[pos..][0..b.len], b);
        pos += b.len;
    }
    return encodeTyped(allocator, .multi, "", payload);
}

/// Decode the inner-envelope byte slices from a `multi` payload (i.e.
/// `Envelope.payload` where `type == .multi`). Returned slices alias
/// `payload`; caller frees only the outer `[][]const u8` with
/// `allocator.free`.
pub fn decodeMultiInner(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error![][]const u8 {
    if (payload.len < 1) return Error.Truncated;
    const count = payload[0];
    const out = allocator.alloc([]const u8, count) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    var pos: usize = 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (payload.len < pos + 4) return Error.Truncated;
        const len = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        if (payload.len < pos + len) return Error.Truncated;
        out[i] = payload[pos .. pos + len];
        pos += len;
    }
    return out;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "entry frame round-trips and rejects unframed/truncated bytes" {
    const a = testing.allocator;
    const env = try encodeWriteSet(a, "t", "WS");
    defer a.free(env);

    const framed = try encodeEntryFrame(a, 0xDEAD_BEEF, 42, env);
    defer a.free(framed);
    const f = try decodeEntryFrame(framed);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), f.origin);
    try testing.expectEqual(@as(u64, 42), f.seq);
    try testing.expectEqualSlices(u8, env, f.env_bytes);
    // The framed envelope still decodes.
    const dec = try decode(f.env_bytes);
    try testing.expectEqual(Type.writeset, dec.type);

    // A bare (unframed) envelope fails loud — type byte 0 is not the magic.
    try testing.expectError(Error.BadEntryFrame, decodeEntryFrame(env));
    try testing.expectError(Error.Truncated, decodeEntryFrame(framed[0..10]));
}

test "writeset envelope round-trips (readset-framed payload)" {
    const a = testing.allocator;
    const env = try encodeWriteSet(a, "tenant-42", "WSBYTES");
    defer a.free(env);

    const dec = try decode(env);
    try testing.expectEqual(Type.writeset, dec.type);
    try testing.expectEqualStrings("tenant-42", dec.id);
    // The payload is the readset frame; the writeset bytes ride inside it
    // (empty readset) — wire-identical to a worker propose.
    const wp = try decodeWriteSetPayload(dec.payload);
    try testing.expectEqualStrings("WSBYTES", wp.ws_bytes);
    try testing.expectEqual(@as(usize, 0), wp.rs_bytes.len);
}

test "writeset payload carries a non-empty readset" {
    const a = testing.allocator;
    const payload = try encodeWriteSetPayload(a, "WS", "READSET");
    defer a.free(payload);
    const wp = try decodeWriteSetPayload(payload);
    try testing.expectEqualStrings("WS", wp.ws_bytes);
    try testing.expectEqualStrings("READSET", wp.rs_bytes);
}

test "root writeset envelope round-trips with empty id" {
    const a = testing.allocator;
    const env = try encodeRootWriteSet(a, "ROOT");
    defer a.free(env);

    const dec = try decode(env);
    try testing.expectEqual(Type.root_writeset, dec.type);
    try testing.expectEqualStrings("", dec.id);
    try testing.expectEqualStrings("ROOT", dec.payload);
}

test "multi wrapper round-trips and unwraps inner envelopes in order" {
    const a = testing.allocator;
    const e0 = try encodeWriteSet(a, "t0", "first");
    defer a.free(e0);
    const e1 = try encodeWriteSet(a, "t1", "second");
    defer a.free(e1);

    const multi = try encodeMulti(a, &.{ e0, e1 });
    defer a.free(multi);

    const outer = try decode(multi);
    try testing.expectEqual(Type.multi, outer.type);

    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 2), inner.len);

    const d0 = try decode(inner[0]);
    try testing.expectEqualStrings("t0", d0.id);
    try testing.expectEqualStrings("first", (try decodeWriteSetPayload(d0.payload)).ws_bytes);
    const d1 = try decode(inner[1]);
    try testing.expectEqualStrings("t1", d1.id);
    try testing.expectEqualStrings("second", (try decodeWriteSetPayload(d1.payload)).ws_bytes);
}

test "decode rejects a retired/unknown type byte" {
    // Type 8 was a retired V1 schedule envelope; must surface loudly.
    var buf = [_]u8{ 8, 0, 0 };
    try testing.expectError(Error.UnknownEnvelopeType, decode(&buf));
}

test "decode rejects truncated headers" {
    try testing.expectError(Error.Truncated, decode(&[_]u8{ 0, 0 }));
    // id_len says 5 but no id bytes follow.
    try testing.expectError(Error.Truncated, decode(&[_]u8{ 0, 0, 5 }));
}

test "encode rejects an over-long id" {
    const a = testing.allocator;
    const big = [_]u8{'x'} ** (MAX_ID_LEN + 1);
    try testing.expectError(Error.IdTooLong, encodeWriteSet(a, &big, "x"));
}
