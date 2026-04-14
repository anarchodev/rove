//! Raft RPC wire format.
//!
//! Frame layout: `[4B payload length][4B CRC32][payload]`
//!   - Length is the payload byte count (does not include the 8-byte header).
//!   - CRC32 is the IsoHdlc (Ethernet/ZIP) polynomial computed over the
//!     payload bytes only, NOT over the length field. A mismatch on decode
//!     indicates transit corruption or a malicious sender; callers should
//!     drop the connection on mismatch.
//!
//! Payload layout: `[1 byte: type][type-specific fields]`
//!
//! Pure-Zig types — no willemt/raft dependency. The conversion between these
//! and `msg_*_t` from willemt/raft happens in raft_node.zig.

const std = @import("std");

/// Total on-wire header length: 4B payload-length + 4B CRC32.
pub const HEADER_SIZE: usize = 8;
/// Offset of the CRC32 field within the header.
pub const CRC_OFFSET: usize = 4;

/// Compute the checksum rove-kv uses for frame integrity. IsoHdlc CRC32
/// (`std.hash.crc.Crc32IsoHdlc`) — not cryptographic, but good enough to
/// detect single-bit and most burst errors introduced in transit.
pub fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32IsoHdlc.hash(bytes);
}

pub const MsgType = enum(u8) {
    vote_req = 1,
    vote_resp = 2,
    append_req = 3,
    append_resp = 4,
    ident = 5,
    snap_offer = 6,
    snap_req = 7,
    snap_data = 8,
};

pub const VoteReq = struct {
    term: u64,
    candidate_id: u32,
    last_log_idx: u64,
    last_log_term: u64,
};

pub const VoteResp = struct {
    term: u64,
    vote_granted: i32,
};

pub const Entry = struct {
    term: u64,
    id: u32,
    type: i32,
    data: []u8, // owned slice; freed by `WireMsg.deinit`
};

pub const AppendReq = struct {
    term: u64,
    prev_log_idx: u64,
    prev_log_term: u64,
    leader_commit: u64,
    entries: []Entry, // owned slice; freed by `WireMsg.deinit`
};

pub const AppendResp = struct {
    term: u64,
    success: i32,
    current_idx: u64,
    first_idx: u64,
};

/// Tagged union of decoded messages. The `append_req` variant owns its
/// `entries` slice and each entry's `data`; call `deinit` to free them.
pub const WireMsg = union(MsgType) {
    vote_req: VoteReq,
    vote_resp: VoteResp,
    append_req: AppendReq,
    append_resp: AppendResp,
    ident: u32, // node_id
    snap_offer: void,
    snap_req: void,
    snap_data: void,

    pub fn deinit(self: *WireMsg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .append_req => |*ar| {
                for (ar.entries) |e| allocator.free(e.data);
                allocator.free(ar.entries);
                ar.entries = &.{};
            },
            else => {},
        }
    }
};

pub const Error = error{
    Truncated,
    UnknownType,
    Checksum,
    OutOfMemory,
};

// ── frame helpers ─────────────────────────────────────────────────────

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

// ── encode ────────────────────────────────────────────────────────────
//
// Each `encode*` function returns an owned `[]u8` containing the full
// frame (header + type + payload). Caller frees with the allocator.

fn frameAlloc(
    allocator: std.mem.Allocator,
    msg_type: MsgType,
    payload_size: u32,
) Error![]u8 {
    const frame_payload: u32 = 1 + payload_size;
    const total: usize = HEADER_SIZE + frame_payload;
    const buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], frame_payload, .big);
    // Placeholder CRC — filled in by `finalizeFrame` after the payload is
    // fully written.
    std.mem.writeInt(u32, buf[4..8], 0, .big);
    buf[HEADER_SIZE] = @intFromEnum(msg_type);
    return buf;
}

/// Compute and fill in the CRC32 for an encoded frame. Must be called by
/// every encoder after the payload bytes have been written. No-op on
/// malformed input (frame shorter than header). Public so out-of-module
/// encoders (e.g. rove-kv's snapshot wire helpers) can call it too.
pub fn finalizeFrame(buf: []u8) void {
    if (buf.len < HEADER_SIZE) return;
    const crc = checksum(buf[HEADER_SIZE..]);
    std.mem.writeInt(u32, buf[4..8], crc, .big);
}

const Writer = struct {
    buf: []u8,
    pos: usize,

    fn w8(self: *Writer, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    fn w32(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }

    fn w64(self: *Writer, v: u64) void {
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .big);
        self.pos += 8;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) void {
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }
};

pub fn encodeVoteReq(allocator: std.mem.Allocator, req: VoteReq) Error![]u8 {
    const buf = try frameAlloc(allocator, .vote_req, 28);
    var w = Writer{ .buf = buf, .pos = HEADER_SIZE + 1 };
    w.w64(req.term);
    w.w32(req.candidate_id);
    w.w64(req.last_log_idx);
    w.w64(req.last_log_term);
    finalizeFrame(buf);
    return buf;
}

pub fn encodeVoteResp(allocator: std.mem.Allocator, resp: VoteResp) Error![]u8 {
    const buf = try frameAlloc(allocator, .vote_resp, 12);
    var w = Writer{ .buf = buf, .pos = HEADER_SIZE + 1 };
    w.w64(resp.term);
    w.w32(@bitCast(resp.vote_granted));
    finalizeFrame(buf);
    return buf;
}

pub fn encodeAppendReq(allocator: std.mem.Allocator, req: AppendReq) Error![]u8 {
    var entries_size: u32 = 0;
    for (req.entries) |e| {
        entries_size += 8 + 4 + 4 + 4 + @as(u32, @intCast(e.data.len));
    }

    const buf = try frameAlloc(allocator, .append_req, 36 + entries_size);
    var w = Writer{ .buf = buf, .pos = HEADER_SIZE + 1 };
    w.w64(req.term);
    w.w64(req.prev_log_idx);
    w.w64(req.prev_log_term);
    w.w64(req.leader_commit);
    w.w32(@intCast(req.entries.len));

    for (req.entries) |e| {
        w.w64(e.term);
        w.w32(e.id);
        w.w32(@bitCast(e.type));
        w.w32(@intCast(e.data.len));
        if (e.data.len > 0) w.writeBytes(e.data);
    }

    finalizeFrame(buf);
    return buf;
}

pub fn encodeAppendResp(allocator: std.mem.Allocator, resp: AppendResp) Error![]u8 {
    const buf = try frameAlloc(allocator, .append_resp, 28);
    var w = Writer{ .buf = buf, .pos = HEADER_SIZE + 1 };
    w.w64(resp.term);
    w.w32(@bitCast(resp.success));
    w.w64(resp.current_idx);
    w.w64(resp.first_idx);
    finalizeFrame(buf);
    return buf;
}

pub fn encodeIdent(allocator: std.mem.Allocator, node_id: u32) Error![]u8 {
    const buf = try frameAlloc(allocator, .ident, 4);
    var w = Writer{ .buf = buf, .pos = HEADER_SIZE + 1 };
    w.w32(node_id);
    finalizeFrame(buf);
    return buf;
}

// ── decode ────────────────────────────────────────────────────────────

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn rem(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    fn r8(self: *Reader) Error!u8 {
        if (self.rem() < 1) return Error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn r32(self: *Reader) Error!u32 {
        if (self.rem() < 4) return Error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn r64(self: *Reader) Error!u64 {
        if (self.rem() < 8) return Error.Truncated;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn readBytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.rem() < n) return Error.Truncated;
        const slice = self.data[self.pos..][0..n];
        self.pos += n;
        return slice;
    }
};

/// Decode a payload (the bytes after the 4-byte length header). For
/// `append_req`, allocates an entries slice and per-entry data via
/// `allocator`; the caller must call `WireMsg.deinit(allocator)` to free.
pub fn decode(allocator: std.mem.Allocator, payload: []const u8) Error!WireMsg {
    var r = Reader{ .data = payload, .pos = 0 };
    const type_byte = try r.r8();
    const msg_type = std.meta.intToEnum(MsgType, type_byte) catch return Error.UnknownType;

    switch (msg_type) {
        .vote_req => {
            const term = try r.r64();
            const candidate_id = try r.r32();
            const last_log_idx = try r.r64();
            const last_log_term = try r.r64();
            return .{ .vote_req = .{
                .term = term,
                .candidate_id = candidate_id,
                .last_log_idx = last_log_idx,
                .last_log_term = last_log_term,
            } };
        },
        .vote_resp => {
            const term = try r.r64();
            const granted: i32 = @bitCast(try r.r32());
            return .{ .vote_resp = .{ .term = term, .vote_granted = granted } };
        },
        .append_req => {
            const term = try r.r64();
            const prev_log_idx = try r.r64();
            const prev_log_term = try r.r64();
            const leader_commit = try r.r64();
            const n_entries = try r.r32();

            const entries = try allocator.alloc(Entry, n_entries);
            errdefer allocator.free(entries);

            // Track how many entries we've successfully decoded so error
            // cleanup only frees those.
            var decoded: usize = 0;
            errdefer for (entries[0..decoded]) |e| allocator.free(e.data);

            for (0..n_entries) |i| {
                const e_term = try r.r64();
                const e_id = try r.r32();
                const e_type: i32 = @bitCast(try r.r32());
                const dlen = try r.r32();

                const data_buf = try allocator.alloc(u8, dlen);
                errdefer allocator.free(data_buf);

                if (dlen > 0) {
                    const src = try r.readBytes(dlen);
                    @memcpy(data_buf, src);
                }

                entries[i] = .{
                    .term = e_term,
                    .id = e_id,
                    .type = e_type,
                    .data = data_buf,
                };
                decoded += 1;
            }

            return .{ .append_req = .{
                .term = term,
                .prev_log_idx = prev_log_idx,
                .prev_log_term = prev_log_term,
                .leader_commit = leader_commit,
                .entries = entries,
            } };
        },
        .append_resp => {
            const term = try r.r64();
            const success: i32 = @bitCast(try r.r32());
            const current_idx = try r.r64();
            const first_idx = try r.r64();
            return .{ .append_resp = .{
                .term = term,
                .success = success,
                .current_idx = current_idx,
                .first_idx = first_idx,
            } };
        },
        .ident => {
            const node_id = try r.r32();
            return .{ .ident = node_id };
        },
        .snap_offer, .snap_req, .snap_data => return Error.UnknownType,
    }
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn payloadOf(frame: []const u8) []const u8 {
    const len = frameLen(frame);
    return frame[HEADER_SIZE .. HEADER_SIZE + len];
}

test "frameLen reads big-endian length" {
    // HEADER_SIZE is 8 (4B length + 4B crc). Pad with a crc that we
    // don't care about — frameLen only reads the first 4 bytes.
    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x23, 0xff, 0xff, 0xff, 0xff, 0x00 };
    try testing.expectEqual(@as(u32, 0x123), frameLen(&buf));
}

test "vote_req round trip" {
    const req = VoteReq{
        .term = 7,
        .candidate_id = 42,
        .last_log_idx = 100,
        .last_log_term = 6,
    };
    const frame = try encodeVoteReq(testing.allocator, req);
    defer testing.allocator.free(frame);

    try testing.expectEqual(@as(u32, 1 + 28), frameLen(frame));

    var msg = try decode(testing.allocator, payloadOf(frame));
    defer msg.deinit(testing.allocator);
    try testing.expect(msg == .vote_req);
    try testing.expectEqual(req, msg.vote_req);
}

test "vote_resp round trip" {
    const resp = VoteResp{ .term = 9, .vote_granted = 1 };
    const frame = try encodeVoteResp(testing.allocator, resp);
    defer testing.allocator.free(frame);

    var msg = try decode(testing.allocator, payloadOf(frame));
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(resp, msg.vote_resp);
}

test "append_req with entries round trip" {
    var e1_data = [_]u8{ 1, 2, 3 };
    var e2_data = [_]u8{ 0xff, 0xee };
    const entries = [_]Entry{
        .{ .term = 5, .id = 100, .type = 0, .data = &e1_data },
        .{ .term = 5, .id = 101, .type = 1, .data = &e2_data },
    };
    const req = AppendReq{
        .term = 5,
        .prev_log_idx = 10,
        .prev_log_term = 4,
        .leader_commit = 8,
        .entries = @constCast(&entries),
    };
    const frame = try encodeAppendReq(testing.allocator, req);
    defer testing.allocator.free(frame);

    var msg = try decode(testing.allocator, payloadOf(frame));
    defer msg.deinit(testing.allocator);
    try testing.expect(msg == .append_req);
    const ar = msg.append_req;
    try testing.expectEqual(@as(u64, 5), ar.term);
    try testing.expectEqual(@as(u64, 10), ar.prev_log_idx);
    try testing.expectEqual(@as(u64, 4), ar.prev_log_term);
    try testing.expectEqual(@as(u64, 8), ar.leader_commit);
    try testing.expectEqual(@as(usize, 2), ar.entries.len);
    try testing.expectEqual(@as(u32, 100), ar.entries[0].id);
    try testing.expectEqualSlices(u8, &e1_data, ar.entries[0].data);
    try testing.expectEqual(@as(i32, 1), ar.entries[1].type);
    try testing.expectEqualSlices(u8, &e2_data, ar.entries[1].data);
}

test "append_req with zero entries round trip" {
    const req = AppendReq{
        .term = 1,
        .prev_log_idx = 0,
        .prev_log_term = 0,
        .leader_commit = 0,
        .entries = &.{},
    };
    const frame = try encodeAppendReq(testing.allocator, req);
    defer testing.allocator.free(frame);

    var msg = try decode(testing.allocator, payloadOf(frame));
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), msg.append_req.entries.len);
}

test "append_resp round trip" {
    const resp = AppendResp{
        .term = 5,
        .success = 1,
        .current_idx = 12,
        .first_idx = 10,
    };
    const frame = try encodeAppendResp(testing.allocator, resp);
    defer testing.allocator.free(frame);

    var msg = try decode(testing.allocator, payloadOf(frame));
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(resp, msg.append_resp);
}

test "ident round trip" {
    const frame = try encodeIdent(testing.allocator, 0xdeadbeef);
    defer testing.allocator.free(frame);

    var msg = try decode(testing.allocator, payloadOf(frame));
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0xdeadbeef), msg.ident);
}

test "decode rejects truncated payload" {
    const frame = try encodeVoteReq(testing.allocator, .{
        .term = 1,
        .candidate_id = 1,
        .last_log_idx = 1,
        .last_log_term = 1,
    });
    defer testing.allocator.free(frame);

    const payload = payloadOf(frame);
    try testing.expectError(Error.Truncated, decode(testing.allocator, payload[0 .. payload.len - 1]));
}

test "decode rejects unknown type byte" {
    const bad = [_]u8{0x42};
    try testing.expectError(Error.UnknownType, decode(testing.allocator, &bad));
}

test "decode rejects empty payload" {
    try testing.expectError(Error.Truncated, decode(testing.allocator, &.{}));
}

test "frame header carries a non-zero CRC over the payload" {
    const frame = try encodeVoteReq(testing.allocator, .{
        .term = 7,
        .candidate_id = 3,
        .last_log_idx = 100,
        .last_log_term = 6,
    });
    defer testing.allocator.free(frame);

    const payload = payloadOf(frame);
    const embedded_crc = frameCrc(frame[0..HEADER_SIZE]);
    const recomputed = checksum(payload);
    try testing.expectEqual(embedded_crc, recomputed);
    // Sanity: real payloads produce non-zero CRCs.
    try testing.expect(recomputed != 0);
}

test "tampered payload yields a different CRC than the header" {
    const frame = try encodeVoteResp(testing.allocator, .{ .term = 9, .vote_granted = 1 });
    defer testing.allocator.free(frame);

    // Flip one bit in the payload, leaving the header intact.
    frame[HEADER_SIZE + 3] ^= 0x01;

    const stored = frameCrc(frame[0..HEADER_SIZE]);
    const recomputed = checksum(frame[HEADER_SIZE..]);
    try testing.expect(stored != recomputed);
}
