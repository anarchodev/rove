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
//! Phase-1 scope (docs/v2-build-order.md §Phase 1): only the type-0
//! writeset and the type-1 multi wrapper are live. Unlike V1's type-0,
//! the Phase-1 payload is the **raw writeset bytes** — no readset
//! section. Readset replication is explicitly off the milestone path
//! ("a V1 feature V2 will want eventually, but not for the first
//! slices"); when it lands it extends the type-0 payload exactly as V1
//! did, without touching this header codec.

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
    OutOfMemory,
};

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

/// Build a type-0 writeset envelope. `ws_bytes` is the output of
/// `writeset.WriteSet.encode`. Caller owns the returned slice.
pub fn encodeWriteSet(
    allocator: std.mem.Allocator,
    id: []const u8,
    ws_bytes: []const u8,
) Error![]u8 {
    return encodeTyped(allocator, .writeset, id, ws_bytes);
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

test "writeset envelope round-trips" {
    const a = testing.allocator;
    const env = try encodeWriteSet(a, "tenant-42", "WSBYTES");
    defer a.free(env);

    const dec = try decode(env);
    try testing.expectEqual(Type.writeset, dec.type);
    try testing.expectEqualStrings("tenant-42", dec.id);
    try testing.expectEqualStrings("WSBYTES", dec.payload);
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
    try testing.expectEqualStrings("first", d0.payload);
    const d1 = try decode(inner[1]);
    try testing.expectEqualStrings("t1", d1.id);
    try testing.expectEqualStrings("second", d1.payload);
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
