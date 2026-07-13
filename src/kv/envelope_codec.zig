//! Envelope wire-format codec — the stable, library-defined header that
//! wraps every replicated payload:
//!
//!   [1B type][2B id_len BE][id bytes][payload]
//!
//! Type 0 = writeset against the store named by `id`; type 1 = the
//! multi-envelope wrapper; types 2+ are application-defined.
//!
//! This std-only file is **the** single copy of the wire format —
//! `kvlimbs.zig` re-exports it so the rove-js worker (`apply.zig`) gets
//! the codec without dragging in the consensus spine, and
//! `src/consensus/envelope.zig` delegates its header / multi / writeset-
//! payload primitives here, layering only the consensus-spine additions
//! (`EntryFrame`, the typed `Type` enum) on top. There is no second
//! implementation to keep in sync: a producer encoding through either
//! surface and a follower decoding through the other read the same bytes
//! under the same caps by construction.

const std = @import("std");

/// Max length of an envelope `id` (the tenant store id string). The
/// 2-byte big-endian length field caps it at 65535 regardless; this is
/// the tighter sanity bound. Enforced on ENCODE only (`IdTooLong`) —
/// `decodeEnvelope` accepts whatever the length field says, so the cap
/// can tighten without stranding old log entries. One value for every
/// encoder (worker and consensus spine alike) — a divergence would make
/// ids in the gap encodable on one path only.
pub const MAX_ID_LEN: usize = 256;

pub const ENVELOPE_TYPE_WRITESET: u8 = 0;
pub const ENVELOPE_TYPE_MULTI: u8 = 1;

/// Codec error set. A subset of the callers' wider error sets (consensus
/// / worker), so the re-exported functions coerce cleanly into them.
pub const Error = error{
    Truncated,
    IdTooLong,
    UnknownEnvelopeType,
    NestedMulti,
    OutOfMemory,
};

pub const Envelope = struct {
    type: u8,
    /// Store id when `type == ENVELOPE_TYPE_WRITESET`. For other types,
    /// application-defined (often empty for cluster-wide stores).
    id: []const u8,
    payload: []const u8,
};

pub fn decodeEnvelope(bytes: []const u8) Error!Envelope {
    if (bytes.len < 3) return Error.Truncated;
    const t = bytes[0];
    const id_len = std.mem.readInt(u16, bytes[1..3], .big);
    if (bytes.len < 3 + @as(usize, id_len)) return Error.Truncated;
    return .{
        .type = t,
        .id = bytes[3 .. 3 + id_len],
        .payload = bytes[3 + id_len ..],
    };
}

pub fn encodeEnvelope(
    allocator: std.mem.Allocator,
    t: u8,
    id: []const u8,
    payload: []const u8,
) ![]u8 {
    if (id.len > MAX_ID_LEN) return Error.IdTooLong;
    const total = 1 + 2 + id.len + payload.len;
    const out = try allocator.alloc(u8, total);
    out[0] = t;
    std.mem.writeInt(u16, out[1..3], @intCast(id.len), .big);
    @memcpy(out[3 .. 3 + id.len], id);
    @memcpy(out[3 + id.len ..], payload);
    return out;
}

/// Multi-envelope wrapper payload format:
///   `[u8 count][u32 inner_len LE][inner_envelope_bytes]{count}`
/// Each inner envelope is a complete `[type][id_len][id][payload]`
/// blob. Inner envelopes apply in order; nesting (a `multi` inside a
/// `multi`) panics. The outer envelope's `id` is empty.
pub fn encodeMulti(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) ![]u8 {
    if (inner.len > 0xff) return error.OutOfMemory;
    var inner_total: usize = 0;
    for (inner) |b| inner_total += 4 + b.len;
    const payload_len = 1 + inner_total;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    payload[0] = @intCast(inner.len);
    var pos: usize = 1;
    for (inner) |b| {
        std.mem.writeInt(u32, payload[pos..][0..4], @intCast(b.len), .little);
        pos += 4;
        @memcpy(payload[pos..][0..b.len], b);
        pos += b.len;
    }
    // encodeEnvelope copies `payload` into the returned buffer.
    return encodeEnvelope(allocator, ENVELOPE_TYPE_MULTI, "", payload);
}

/// Decode the inner-envelope byte slices from a multi-envelope's
/// payload. Slices alias the input buffer; do not free individually.
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

/// Type-0 envelope payload layout (`docs/readset-replication-plan.md`
/// Phase 3):
///
///   `[u32 LE ws_len][ws_bytes][u32 LE rs_len][rs_bytes]`
///
/// The type-0 payload is NOT raw writeset bytes — it interleaves the
/// writeset with the request's serialized readset so the tape can be
/// reconstructed on any follower that applies the entry. Apply only
/// needs `ws_bytes`; the readset rides for the tape. `rs_len == 0` is
/// valid + frequent: non-handler producers (ACME, the move surface's
/// `v2-kv`, the secondary inners of a batched propose) carry an empty
/// readset — the readset is per-dispatch, not per-envelope, and lives
/// on the batch's anchor envelope.
pub const WriteSetPayload = struct {
    /// Borrowed slice into the input payload — the writeset bytes.
    ws_bytes: []const u8,
    /// Borrowed slice into the input payload — the readset list bytes.
    /// When non-empty: a `tape_mod.encodeReadsetList` blob (one
    /// `Readset.serialize` entry per successful request in the batched
    /// dispatch that produced this envelope).
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

test "envelope header round-trips" {
    const a = std.testing.allocator;
    const env = try encodeEnvelope(a, ENVELOPE_TYPE_WRITESET, "tenant-1", "PAYLOAD");
    defer a.free(env);
    const dec = try decodeEnvelope(env);
    try std.testing.expectEqual(ENVELOPE_TYPE_WRITESET, dec.type);
    try std.testing.expectEqualStrings("tenant-1", dec.id);
    try std.testing.expectEqualStrings("PAYLOAD", dec.payload);
}

test "writeset payload round-trips, empty and non-empty readset" {
    const a = std.testing.allocator;
    const p0 = try encodeWriteSetPayload(a, "WS", "");
    defer a.free(p0);
    const d0 = try decodeWriteSetPayload(p0);
    try std.testing.expectEqualStrings("WS", d0.ws_bytes);
    try std.testing.expectEqual(@as(usize, 0), d0.rs_bytes.len);

    const p1 = try encodeWriteSetPayload(a, "WS", "READSET");
    defer a.free(p1);
    const d1 = try decodeWriteSetPayload(p1);
    try std.testing.expectEqualStrings("WS", d1.ws_bytes);
    try std.testing.expectEqualStrings("READSET", d1.rs_bytes);

    try std.testing.expectError(Error.Truncated, decodeWriteSetPayload("abc"));
}

test "encode rejects an over-long id" {
    const a = std.testing.allocator;
    const big = [_]u8{'x'} ** (MAX_ID_LEN + 1);
    try std.testing.expectError(Error.IdTooLong, encodeEnvelope(a, 0, &big, "x"));
}

test "multi wrapper round-trips inner envelopes in order" {
    const a = std.testing.allocator;
    const e0 = try encodeEnvelope(a, 0, "t0", "first");
    defer a.free(e0);
    const e1 = try encodeEnvelope(a, 0, "t1", "second");
    defer a.free(e1);
    const multi = try encodeMulti(a, &.{ e0, e1 });
    defer a.free(multi);

    const outer = try decodeEnvelope(multi);
    try std.testing.expectEqual(ENVELOPE_TYPE_MULTI, outer.type);
    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try std.testing.expectEqual(@as(usize, 2), inner.len);
    const d0 = try decodeEnvelope(inner[0]);
    try std.testing.expectEqualStrings("t0", d0.id);
    try std.testing.expectEqualStrings("first", d0.payload);
}
