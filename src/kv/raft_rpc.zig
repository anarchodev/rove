//! Raft transport frame codec.
//!
//! Frame layout: `[4B payload length][4B CRC32][payload]`
//!   - Length is the payload byte count (does not include the 8-byte header).
//!   - CRC32 is the IsoHdlc (Ethernet/ZIP) polynomial computed over the
//!     payload bytes only, NOT over the length field. A mismatch on decode
//!     indicates transit corruption or a malicious sender; callers should
//!     drop the connection on mismatch.
//!
//! The V2 transport (`src/consensus/transport.zig`) moves OPAQUE per-recipient
//! envelope bytes over this frame format and parses them itself. The only
//! typed frame is `ident` — the one-shot handshake a node sends on connect so
//! the accepting peer can identify it (`raft_net.zig`). Everything else is an
//! opaque application payload delivered straight to the transport's `on_recv`.

const std = @import("std");

/// Total on-wire header length: 4B payload-length + 4B CRC32.
pub const HEADER_SIZE: usize = 8;

/// Compute the checksum rove uses for frame integrity. IsoHdlc CRC32
/// (`std.hash.crc.Crc32IsoHdlc`) — not cryptographic, but good enough to
/// detect single-bit and most burst errors introduced in transit.
pub fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32IsoHdlc.hash(bytes);
}

/// Frame payload type tag (`payload[0]`). The transport only distinguishes the
/// `ident` handshake from opaque application frames, so this carries the one
/// reserved value. (The byte stays `5` to preserve the on-wire handshake tag.)
pub const MsgType = enum(u8) {
    ident = 5,
};

pub const Error = error{OutOfMemory};

/// Read the payload length from a frame header (first 4 bytes).
pub fn frameLen(header: []const u8) u32 {
    std.debug.assert(header.len >= HEADER_SIZE);
    return std.mem.readInt(u32, header[0..4], .big);
}

/// Read the payload CRC32 from a frame header (bytes 4..8).
pub fn frameCrc(header: []const u8) u32 {
    std.debug.assert(header.len >= HEADER_SIZE);
    return std.mem.readInt(u32, header[4..8], .big);
}

/// Encode the `ident` handshake frame: `[len][crc][type=ident][4B node_id]`.
/// A node sends this immediately on connect so the accepting peer can map the
/// inbound connection to a node id.
pub fn encodeIdent(allocator: std.mem.Allocator, node_id: u32) Error![]u8 {
    const payload_len: u32 = 1 + 4; // type byte + node_id
    const buf = try allocator.alloc(u8, HEADER_SIZE + payload_len);
    std.mem.writeInt(u32, buf[0..4], payload_len, .big);
    buf[HEADER_SIZE] = @intFromEnum(MsgType.ident);
    std.mem.writeInt(u32, buf[HEADER_SIZE + 1 ..][0..4], node_id, .big);
    // CRC over the payload (everything after the 8-byte header).
    std.mem.writeInt(u32, buf[4..8], checksum(buf[HEADER_SIZE..]), .big);
    return buf;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn payloadOf(frame: []const u8) []const u8 {
    return frame[HEADER_SIZE .. HEADER_SIZE + frameLen(frame)];
}

test "frameLen reads big-endian length" {
    // frameLen only reads the first 4 bytes; the rest is don't-care padding.
    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x23, 0xff, 0xff, 0xff, 0xff, 0x00 };
    try testing.expectEqual(@as(u32, 0x123), frameLen(&buf));
}

test "ident frame round trip" {
    const frame = try encodeIdent(testing.allocator, 0xdeadbeef);
    defer testing.allocator.free(frame);

    try testing.expectEqual(@as(u32, 1 + 4), frameLen(frame));
    const payload = payloadOf(frame);
    try testing.expectEqual(@intFromEnum(MsgType.ident), payload[0]);
    try testing.expectEqual(
        @as(u32, 0xdeadbeef),
        std.mem.readInt(u32, payload[1..][0..4], .big),
    );
}

test "frame header carries the payload CRC" {
    const frame = try encodeIdent(testing.allocator, 0x01020304);
    defer testing.allocator.free(frame);

    const embedded = frameCrc(frame[0..HEADER_SIZE]);
    const recomputed = checksum(payloadOf(frame));
    try testing.expectEqual(embedded, recomputed);
    try testing.expect(recomputed != 0); // real payloads produce non-zero CRCs
}

test "tampered payload yields a different CRC than the header" {
    const frame = try encodeIdent(testing.allocator, 0x11223344);
    defer testing.allocator.free(frame);

    frame[HEADER_SIZE + 1] ^= 0x01; // flip a bit in the node_id payload
    const stored = frameCrc(frame[0..HEADER_SIZE]);
    const recomputed = checksum(frame[HEADER_SIZE..]);
    try testing.expect(stored != recomputed);
}
