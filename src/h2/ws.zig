//! RFC 6455 WebSocket frame codec for the rove-h2 edge listener
//! (docs/websocket-plan.md §4.6 piece B).
//!
//! The pure, I/O-free half of inbound WebSocket support: handshake-accept
//! derivation + frame parse/serialize. No sockets, no entities — `root.zig`
//! wires this into the connection / held-stream plumbing (pieces A/C/D/E), the
//! same split `http1.zig` has against its `Http1Conn` driver.
//!
//! Scope (single-tenant / single-node baseline): server-side framing only.
//! - parse: client→server frames (MUST be masked per §5.1); unmask in place.
//! - serialize: server→client frames (MUST NOT be masked per §5.1).
//! - fragmentation is surfaced (opcode + fin) but reassembled by the caller
//!   (the connection layer accumulates continuation frames until FIN), mirroring
//!   how `http1.zig` leaves body assembly to its driver.
//! - permessage-deflate / extensions are out of scope (RSV bits must be 0) per
//!   websocket-plan.md §7.

const std = @import("std");

/// RFC 6455 §1.3: the GUID concatenated with the client key before hashing.
pub const ACCEPT_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// `Sec-WebSocket-Accept` is exactly base64(SHA1(...)) = 28 bytes.
pub const ACCEPT_LEN: usize = 28;

/// Control frames (opcode ≥ 0x8) cap their payload at 125 bytes and must not
/// fragment (RFC 6455 §5.5).
pub const MAX_CONTROL_PAYLOAD: usize = 125;

/// Derive the `Sec-WebSocket-Accept` header value from the client's
/// `Sec-WebSocket-Key`: base64(SHA1(key ++ ACCEPT_MAGIC)) (RFC 6455 §4.2.2).
/// Writes exactly `ACCEPT_LEN` bytes into `out` (caller provides ≥ 28) and
/// returns the written slice. No allocation.
pub fn acceptKey(key: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= ACCEPT_LEN);
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(ACCEPT_MAGIC);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out[0..ACCEPT_LEN], &digest);
}

/// RFC 6455 §5.2 opcodes. The `_` arm catches the reserved opcodes (0x3–0x7,
/// 0xB–0xF); a frame carrying one is a protocol error the caller closes on.
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    /// Control frames (0x8–0xF) carry connection-management semantics, cap their
    /// payload at 125 bytes, and must not be fragmented (§5.5).
    pub fn isControl(self: Opcode) bool {
        return (@intFromEnum(self) & 0x8) != 0;
    }
};

/// One decoded inbound frame. `payload` borrows from the buffer passed to
/// `parseFrame` — which is unmasked **in place**, so that buffer is mutated and
/// the slice is valid only while it lives.
pub const Frame = struct {
    opcode: Opcode,
    /// FIN bit — last fragment of a message (§5.4). A data message spans one or
    /// more frames: a non-continuation opener, zero+ `continuation` frames, the
    /// last with `fin = true`.
    fin: bool,
    /// The unmasked application payload.
    payload: []const u8,
    /// Total bytes this frame occupied in the input (header + payload); the next
    /// frame begins at `buf[consumed..]`.
    consumed: usize,
};

pub const ParseError = error{
    /// Reserved bits set, a server-bound unmasked frame, a fragmented or
    /// oversized control frame, or a reserved opcode (§5.2/§5.5) — fail the
    /// connection with close code 1002.
    ProtocolError,
    /// Payload length exceeds the caller's cap — fail with close code 1009.
    TooLarge,
};

pub const ParseResult = union(enum) {
    /// The buffer doesn't yet hold a full frame (header or payload incomplete) —
    /// read more and retry from the same offset.
    need_more,
    frame: Frame,
};

/// Parse one client→server frame from the front of `buf`, unmasking its payload
/// **in place**. Returns `.need_more` until both the header and the full
/// payload have arrived. `max_payload` bounds a single frame's payload (caller's
/// per-frame cap); a larger frame is `TooLarge`. Does not allocate.
///
/// Per §5.1 every client→server frame MUST be masked; an unmasked one is a
/// `ProtocolError`. Reserved (RSV1-3) bits MUST be 0 (no extensions negotiated).
pub fn parseFrame(buf: []u8, max_payload: usize) ParseError!ParseResult {
    if (buf.len < 2) return .need_more;

    const b0 = buf[0];
    const fin = (b0 & 0x80) != 0;
    if ((b0 & 0x70) != 0) return ParseError.ProtocolError; // RSV1-3 must be 0
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));

    // Reserved opcodes (0x3-0x7 non-control, 0xB-0xF control) are protocol errors.
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return ParseError.ProtocolError,
    }

    const b1 = buf[1];
    const masked = (b1 & 0x80) != 0;
    if (!masked) return ParseError.ProtocolError; // client frames MUST be masked
    const len7: u64 = b1 & 0x7F;

    var off: usize = 2;
    var payload_len: u64 = len7;
    if (len7 == 126) {
        if (buf.len < off + 2) return .need_more;
        payload_len = std.mem.readInt(u16, buf[off..][0..2], .big);
        off += 2;
    } else if (len7 == 127) {
        if (buf.len < off + 8) return .need_more;
        payload_len = std.mem.readInt(u64, buf[off..][0..8], .big);
        if ((payload_len & (1 << 63)) != 0) return ParseError.ProtocolError; // MSB must be 0 (§5.2)
        off += 8;
    }

    // Control frames: ≤125 bytes, never fragmented (§5.5).
    if (opcode.isControl() and (payload_len > MAX_CONTROL_PAYLOAD or !fin))
        return ParseError.ProtocolError;
    if (payload_len > max_payload) return ParseError.TooLarge;

    const mask_off = off;
    if (buf.len < mask_off + 4) return .need_more;
    off += 4; // 4-byte masking key

    const plen: usize = @intCast(payload_len);
    if (buf.len < off + plen) return .need_more;

    // Unmask in place: payload[i] ^= maskkey[i % 4] (§5.3).
    const mask = buf[mask_off..][0..4];
    const payload = buf[off .. off + plen];
    for (payload, 0..) |*byte, i| byte.* ^= mask[i & 3];

    return .{ .frame = .{
        .opcode = opcode,
        .fin = fin,
        .payload = payload,
        .consumed = off + plen,
    } };
}

/// Serialize a server→client frame (unmasked, per §5.1) into `out`: the 2-byte
/// header, the extended length (16- or 64-bit when needed), then the payload.
/// Caller owns `out`. Control-frame callers must keep `payload` ≤ 125 bytes
/// (asserted) and pass a single FIN frame.
pub fn writeFrame(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    opcode: Opcode,
    payload: []const u8,
) !void {
    if (opcode.isControl()) std.debug.assert(payload.len <= MAX_CONTROL_PAYLOAD);
    // Single-frame messages only (FIN set); the connection layer doesn't
    // fragment outbound writes — it sends each piece as one complete message.
    try out.append(a, 0x80 | @as(u8, @intFromEnum(opcode)));

    const len = payload.len;
    if (len <= 125) {
        try out.append(a, @intCast(len));
    } else if (len <= 0xFFFF) {
        try out.append(a, 126);
        var lb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lb, @intCast(len), .big);
        try out.appendSlice(a, &lb);
    } else {
        try out.append(a, 127);
        var lb: [8]u8 = undefined;
        std.mem.writeInt(u64, &lb, @intCast(len), .big);
        try out.appendSlice(a, &lb);
    }
    try out.appendSlice(a, payload);
}

/// Serialize a Close frame (§5.5.1): a 2-byte big-endian status code followed by
/// an optional UTF-8 reason. A code of 0 emits an empty Close (no body), the
/// "no status" form clients accept.
pub fn writeClose(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    code: u16,
    reason: []const u8,
) !void {
    if (code == 0) {
        try writeFrame(out, a, .close, "");
        return;
    }
    var body: [MAX_CONTROL_PAYLOAD]u8 = undefined;
    std.mem.writeInt(u16, body[0..2], code, .big);
    // Reason is truncated to fit the 125-byte control-frame cap (2 code bytes).
    const rlen = @min(reason.len, MAX_CONTROL_PAYLOAD - 2);
    @memcpy(body[2 .. 2 + rlen], reason[0..rlen]);
    try writeFrame(out, a, .close, body[0 .. 2 + rlen]);
}

/// Common close codes (§7.4.1) the connection layer emits.
pub const CloseCode = struct {
    pub const normal: u16 = 1000;
    pub const going_away: u16 = 1001;
    pub const protocol_error: u16 = 1002;
    pub const unsupported_data: u16 = 1003;
    pub const policy_violation: u16 = 1008;
    pub const message_too_big: u16 = 1009;
    pub const internal_error: u16 = 1011;
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "ws: Sec-WebSocket-Accept matches the RFC 6455 §1.3 example" {
    var out: [ACCEPT_LEN]u8 = undefined;
    const got = acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

fn maskedFrame(
    a: std.mem.Allocator,
    fin: bool,
    opcode: Opcode,
    mask: [4]u8,
    payload: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode));
    const len = payload.len;
    if (len <= 125) {
        try buf.append(a, 0x80 | @as(u8, @intCast(len)));
    } else if (len <= 0xFFFF) {
        try buf.append(a, 0x80 | 126);
        var lb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lb, @intCast(len), .big);
        try buf.appendSlice(a, &lb);
    } else {
        try buf.append(a, 0x80 | 127);
        var lb: [8]u8 = undefined;
        std.mem.writeInt(u64, &lb, @intCast(len), .big);
        try buf.appendSlice(a, &lb);
    }
    try buf.appendSlice(a, &mask);
    const start = buf.items.len;
    try buf.appendSlice(a, payload);
    for (buf.items[start..], 0..) |*byte, i| byte.* ^= mask[i & 3];
    return buf.toOwnedSlice(a);
}

test "ws: parse a masked text frame, unmasked in place" {
    const a = testing.allocator;
    const frame = try maskedFrame(a, true, .text, .{ 0x37, 0xfa, 0x21, 0x3d }, "Hello");
    defer a.free(frame);
    const r = try parseFrame(frame, 1 << 20);
    try testing.expectEqual(Opcode.text, r.frame.opcode);
    try testing.expect(r.frame.fin);
    try testing.expectEqualStrings("Hello", r.frame.payload);
    try testing.expectEqual(frame.len, r.frame.consumed);
}

test "ws: unmasked client frame is a protocol error" {
    var buf = [_]u8{ 0x81, 0x00 }; // FIN+text, mask bit clear, len 0
    try testing.expectError(ParseError.ProtocolError, parseFrame(&buf, 1 << 20));
}

test "ws: RSV bits set is a protocol error" {
    var buf = [_]u8{ 0xC1, 0x80, 0, 0, 0, 0 }; // FIN+RSV1+text, masked
    try testing.expectError(ParseError.ProtocolError, parseFrame(&buf, 1 << 20));
}

test "ws: reserved opcode is a protocol error" {
    var buf = [_]u8{ 0x83, 0x80, 0, 0, 0, 0 }; // FIN+opcode 0x3 (reserved), masked
    try testing.expectError(ParseError.ProtocolError, parseFrame(&buf, 1 << 20));
}

test "ws: fragmented control frame is a protocol error" {
    var buf = [_]u8{ 0x09, 0x80, 0, 0, 0, 0 }; // ping (0x9) with FIN clear
    try testing.expectError(ParseError.ProtocolError, parseFrame(&buf, 1 << 20));
}

test "ws: oversized control frame is a protocol error" {
    var buf: [200]u8 = undefined;
    buf[0] = 0x88; // FIN+close
    buf[1] = 0x80 | 126; // masked, 126 (would be a 16-bit len > 125)
    std.mem.writeInt(u16, buf[2..4], 130, .big);
    try testing.expectError(ParseError.ProtocolError, parseFrame(&buf, 1 << 20));
}

test "ws: payload over the cap is TooLarge" {
    const a = testing.allocator;
    const frame = try maskedFrame(a, true, .binary, .{ 1, 2, 3, 4 }, "0123456789");
    defer a.free(frame);
    try testing.expectError(ParseError.TooLarge, parseFrame(frame, 4));
}

test "ws: partial header / payload → need_more" {
    var one = [_]u8{0x81};
    try testing.expect((try parseFrame(&one, 1 << 20)) == .need_more);
    // header for a 5-byte masked payload, but only 2 payload bytes present.
    var partial = [_]u8{ 0x81, 0x85, 1, 2, 3, 4, 0xAA, 0xBB };
    try testing.expect((try parseFrame(&partial, 1 << 20)) == .need_more);
}

test "ws: 16-bit extended length round-trips through parse" {
    const a = testing.allocator;
    const payload = try a.alloc(u8, 300);
    defer a.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);
    const frame = try maskedFrame(a, true, .binary, .{ 9, 8, 7, 6 }, payload);
    defer a.free(frame);
    const r = try parseFrame(frame, 1 << 20);
    try testing.expectEqual(Opcode.binary, r.frame.opcode);
    try testing.expectEqualSlices(u8, payload, r.frame.payload);
}

test "ws: two frames back-to-back parse via consumed offset" {
    const a = testing.allocator;
    const f1 = try maskedFrame(a, true, .text, .{ 1, 1, 1, 1 }, "ab");
    defer a.free(f1);
    const f2 = try maskedFrame(a, true, .text, .{ 2, 2, 2, 2 }, "cde");
    defer a.free(f2);
    const both = try std.mem.concat(a, u8, &.{ f1, f2 });
    defer a.free(both);
    const r1 = try parseFrame(both, 1 << 20);
    try testing.expectEqualStrings("ab", r1.frame.payload);
    const r2 = try parseFrame(both[r1.frame.consumed..], 1 << 20);
    try testing.expectEqualStrings("cde", r2.frame.payload);
    try testing.expectEqual(both.len, r1.frame.consumed + r2.frame.consumed);
}

test "ws: fragmented message surfaces opcode + fin per frame" {
    const a = testing.allocator;
    const part1 = try maskedFrame(a, false, .text, .{ 1, 2, 3, 4 }, "Hel"); // FIN=0
    defer a.free(part1);
    const part2 = try maskedFrame(a, true, .continuation, .{ 5, 6, 7, 8 }, "lo"); // FIN=1
    defer a.free(part2);
    const r1 = try parseFrame(part1, 1 << 20);
    try testing.expectEqual(Opcode.text, r1.frame.opcode);
    try testing.expect(!r1.frame.fin);
    try testing.expectEqualStrings("Hel", r1.frame.payload);
    const r2 = try parseFrame(part2, 1 << 20);
    try testing.expectEqual(Opcode.continuation, r2.frame.opcode);
    try testing.expect(r2.frame.fin);
    try testing.expectEqualStrings("lo", r2.frame.payload);
}

test "ws: writeFrame serializes an unmasked server frame" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeFrame(&out, a, .text, "Hello");
    try testing.expectEqual(@as(u8, 0x81), out.items[0]); // FIN+text
    try testing.expectEqual(@as(u8, 0x05), out.items[1]); // unmasked, len 5
    try testing.expectEqualStrings("Hello", out.items[2..]);
}

test "ws: writeFrame 16-bit length header" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const payload = try a.alloc(u8, 1000);
    defer a.free(payload);
    @memset(payload, 'x');
    try writeFrame(&out, a, .binary, payload);
    try testing.expectEqual(@as(u8, 0x82), out.items[0]); // FIN+binary
    try testing.expectEqual(@as(u8, 126), out.items[1]);
    try testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, out.items[2..4], .big));
    try testing.expectEqual(@as(usize, 4 + 1000), out.items.len);
}

test "ws: writeClose carries code + reason, empty when code 0" {
    const a = testing.allocator;
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try writeClose(&out, a, CloseCode.normal, "bye");
        try testing.expectEqual(@as(u8, 0x88), out.items[0]); // FIN+close
        try testing.expectEqual(@as(u8, 5), out.items[1]); // 2 + "bye"
        try testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, out.items[2..4], .big));
        try testing.expectEqualStrings("bye", out.items[4..]);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try writeClose(&out, a, 0, "ignored");
        try testing.expectEqual(@as(u8, 0x88), out.items[0]);
        try testing.expectEqual(@as(u8, 0), out.items[1]); // empty body
        try testing.expectEqual(@as(usize, 2), out.items.len);
    }
}

test "ws: writeFrame then parseFrame is a round-trip (after masking)" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeFrame(&out, a, .binary, "round-trip");
    // The server frame is unmasked; re-mask it to feed the client-frame parser.
    const masked = try maskedFrame(a, true, .binary, .{ 0xDE, 0xAD, 0xBE, 0xEF }, out.items[2..]);
    defer a.free(masked);
    const r = try parseFrame(masked, 1 << 20);
    try testing.expectEqualStrings("round-trip", r.frame.payload);
}
