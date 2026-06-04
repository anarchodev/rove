//! Envelope wire-format codec — the stable, library-defined header that
//! wraps every replicated payload:
//!
//!   [1B type][2B id_len BE][id bytes][payload]
//!
//! Type 0 = writeset against the store named by `id`; type 1 = the
//! multi-envelope wrapper; types 2+ are application-defined.
//!
//! Extracted out of `cluster.zig` (the V1 willemt-raft spine) into this
//! standalone, dependency-free file (docs/v2-build-order.md §Phase 2) so
//! the codec has a **spine-free home** that both V1 and the V2 facade can
//! share: `cluster.zig` re-exports it (V1 unchanged), and `kvlimbs.zig`
//! re-exports it so the rove-js worker (`apply.zig`) and `files-server`
//! get the codec without dragging in willemt-raft + io_uring. Its only
//! dependency is `std`.
//!
//! Byte-identical to `src-v2/kv/envelope.zig` (the V2 spine's own copy):
//! the two stay in sync until the V1 cutover merges `src-v2/ → src/` and
//! collapses them. Keeping the format here means the worker can encode an
//! envelope through this codec and the V2 bridge can decode it through
//! `src-v2/kv/envelope.zig` with no interpretation drift.

const std = @import("std");

pub const MAX_ID_LEN: usize = 256;

pub const ENVELOPE_TYPE_WRITESET: u8 = 0;
pub const ENVELOPE_TYPE_MULTI: u8 = 1;

/// Codec error set. A subset of `cluster.Error`, so `cluster.zig`'s
/// re-exported functions coerce cleanly into its wider set.
pub const Error = error{
    Truncated,
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
    if (id.len > MAX_ID_LEN) return error.OutOfMemory;
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

test "envelope header round-trips" {
    const a = std.testing.allocator;
    const env = try encodeEnvelope(a, ENVELOPE_TYPE_WRITESET, "tenant-1", "PAYLOAD");
    defer a.free(env);
    const dec = try decodeEnvelope(env);
    try std.testing.expectEqual(ENVELOPE_TYPE_WRITESET, dec.type);
    try std.testing.expectEqualStrings("tenant-1", dec.id);
    try std.testing.expectEqualStrings("PAYLOAD", dec.payload);
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
