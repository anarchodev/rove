//! V2 Phase 5 — cross-node raft transport (coalesced, per-recipient).
//!
//! docs/v2-build-order.md §Phase 5: "reuse rove's `raft_net.zig` io_uring
//! transport as the wire layer, adapted to per-recipient **coalesced**
//! envelopes carrying many groups' messages plus epoch stamps"
//! (multiraft-scaling-learnings §3.3). This is the wire half of multi-node
//! V2: each node's raft groups produce outbound messages addressed to peer
//! nodes (`Manager.takeMessages` → `(to, bytes)`); the transport buffers
//! them per destination for the cycle and flushes **one envelope per
//! destination node** carrying every group's messages to that node, each
//! stamped with its group's migration epoch. The receiver decodes the
//! envelope and `stepBatch`es the lot into its `Manager` in one FFI call.
//!
//! ## Why coalesce
//!
//! At K groups a node can have messages for the same peer from many groups
//! in one cycle. Sending one frame per (group, peer) is O(K) syscalls +
//! O(K) FFI steps on the receiver; coalescing makes it O(peers) — the
//! TiKV `BatchRaftMessage` shape. The single-fsync-per-cycle pump
//! (node.zig) pairs with single-envelope-per-peer-per-cycle here.
//!
//! ## Wire format (the envelope payload `raft_net` frames for us)
//!
//! `raft_net` wraps our payload in its `[len:u32 BE][crc:u32 BE]` frame
//! and CRC-checks it on receive (and handles the IDENT handshake, so our
//! payload is never a connection's first frame). Our payload is:
//!
//!     [count:u32 LE]
//!     count × [group_id:u64 LE][epoch:u64 LE][msg_len:u32 LE][msg bytes]
//!
//! `msg bytes` is the opaque rust-protobuf `eraftpb::Message` from
//! `takeMessages`, fed verbatim to the peer's `stepBatch`/`stepFenced`.
//!
//! ## Node-id mapping
//!
//! raft-rs node ids are 1-based (etcd/raft reserves 0 = None); `raft_net`
//! peer ids are 0-based array indices. The transport owns the single
//! `peer_id = node_id - 1` conversion at the send boundary, so callers
//! speak raft node ids throughout.
//!
//! ## Threading
//!
//! All of `queueOut` / `flush` / `tick` and the `onRecv` callback run on
//! the **pump thread** — the only `Manager` toucher. `onRecv` fires
//! synchronously from inside `tick`, so stepping inbound messages into the
//! Manager from it is on-thread and safe.

const std = @import("std");
const raft = @import("raft_rs_zig");
const raftnet = @import("raft-net");

const RaftNet = raftnet.RaftNet;
const rpc = raftnet.rpc;
const StepBatchEntry = raft.manager.StepBatchEntry;

pub const PeerAddr = raftnet.PeerAddr;

pub const Error = error{
    OutOfMemory,
    TransportInit,
};

/// Per-destination outbound accumulator for one pump cycle.
const OutBuf = struct {
    count: u32 = 0,
    /// Concatenated `[group_id][epoch][len][msg]` records (no count prefix
    /// — that is written at flush). Cleared (retaining capacity) per flush.
    body: std.ArrayListUnmanaged(u8) = .empty,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    /// This node's raft id (1-based).
    node_id: u64,
    /// Cluster size == number of peer slots (raft_net peer ids 0..size-1).
    cluster_size: usize,
    net: *RaftNet,
    /// Borrowed — the Node's `Manager`. Inbound messages step into it.
    manager: *raft.Manager,

    /// Per-destination outbound buffers, indexed by raft_net peer id
    /// (`node_id - 1`). Self slot is present but never used.
    outbufs: []OutBuf,
    /// Reusable scratch for the receive path — rebuilt per `onRecv`.
    step_scratch: std.ArrayListUnmanaged(StepBatchEntry) = .empty,

    pub const Config = struct {
        /// This node's raft id (1-based, must be ≤ peers.len).
        node_id: u64,
        listen_addr: std.net.Address,
        /// Peer addresses indexed by raft_net peer id: `peers[k]` is the
        /// address of raft node `k + 1`. `len == cluster size`.
        peers: []const PeerAddr,
        /// Borrowed Manager to step inbound messages into.
        manager: *raft.Manager,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!*Transport {
        const self = allocator.create(Transport) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);

        const outbufs = allocator.alloc(OutBuf, cfg.peers.len) catch return Error.OutOfMemory;
        errdefer allocator.free(outbufs);
        for (outbufs) |*ob| ob.* = .{};

        self.* = .{
            .allocator = allocator,
            .node_id = cfg.node_id,
            .cluster_size = cfg.peers.len,
            .net = undefined,
            .manager = cfg.manager,
            .outbufs = outbufs,
        };

        // raft_net node/peer ids are 0-based; raft node ids are 1-based.
        const net = RaftNet.init(allocator, .{
            .node_id = @intCast(cfg.node_id - 1),
            .peers = cfg.peers,
            .listen_addr = cfg.listen_addr,
            .on_recv = onRecv,
            .user_ctx = self,
            .max_nodes = @intCast(cfg.peers.len),
        }) catch return Error.TransportInit;
        self.net = net;
        return self;
    }

    pub fn deinit(self: *Transport) void {
        const a = self.allocator;
        self.net.deinit();
        for (self.outbufs) |*ob| ob.body.deinit(a);
        a.free(self.outbufs);
        self.step_scratch.deinit(a);
        a.destroy(self);
    }

    /// Buffer one outbound message (from `Manager.takeMessages`) for its
    /// destination node, to be coalesced + sent at `flush`. `to` is a raft
    /// node id; a message to self (shouldn't happen) is dropped.
    pub fn queueOut(self: *Transport, to: u64, group_id: u64, epoch: u64, msg: []const u8) void {
        if (to == self.node_id or to == 0 or to > self.cluster_size) return;
        const ob = &self.outbufs[to - 1];
        const a = self.allocator;
        var hdr: [20]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], group_id, .little);
        std.mem.writeInt(u64, hdr[8..16], epoch, .little);
        std.mem.writeInt(u32, hdr[16..20], @intCast(msg.len), .little);
        ob.body.appendSlice(a, &hdr) catch return;
        ob.body.appendSlice(a, msg) catch return;
        ob.count += 1;
    }

    /// Flush each destination's coalesced envelope as one framed send.
    /// Send errors (peer not yet connected, queue full) are soft — raft
    /// re-emits on the next heartbeat/election tick.
    pub fn flush(self: *Transport) void {
        const a = self.allocator;
        for (self.outbufs, 0..) |*ob, peer_id| {
            if (ob.count == 0) continue;
            defer {
                ob.count = 0;
                ob.body.clearRetainingCapacity();
            }
            const payload_len = 4 + ob.body.items.len;
            const frame = a.alloc(u8, rpc.HEADER_SIZE + payload_len) catch continue;
            defer a.free(frame);
            // payload = [count][body]; frame header = [len BE][crc BE].
            std.mem.writeInt(u32, frame[rpc.HEADER_SIZE..][0..4], ob.count, .little);
            @memcpy(frame[rpc.HEADER_SIZE + 4 ..], ob.body.items);
            const payload = frame[rpc.HEADER_SIZE..];
            std.mem.writeInt(u32, frame[0..4], @intCast(payload_len), .big);
            std.mem.writeInt(u32, frame[4..8], rpc.checksum(payload), .big);
            self.net.send(@intCast(peer_id), frame) catch {};
        }
    }

    /// Drive the io_uring transport once: flush queued sends, accept, and
    /// deliver inbound frames (each → `onRecv` → `stepBatch`). `wait_timeout_ns`
    /// is how long to block for I/O when idle (the pump's idle wait).
    pub fn tick(self: *Transport, now_ns: i64, wait_timeout_ns: u64) !void {
        try self.net.tick(now_ns, wait_timeout_ns);
    }

    /// raft_net recv callback (pump thread). Decode the coalesced envelope
    /// and step every message into the Manager in one batched FFI call.
    /// `payload` is valid only for this call; `stepBatch` reads it before
    /// returning, so the entry pointers into it are safe.
    fn onRecv(from_id: u32, payload: []const u8, ctx: ?*anyopaque) void {
        _ = from_id; // the sender id is inside each eraftpb message
        const self: *Transport = @ptrCast(@alignCast(ctx.?));
        if (payload.len < 4) return;
        const count = std.mem.readInt(u32, payload[0..4], .little);
        var off: usize = 4;
        self.step_scratch.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (off + 20 > payload.len) break;
            const group_id = std.mem.readInt(u64, payload[off..][0..8], .little);
            const epoch = std.mem.readInt(u64, payload[off + 8 ..][0..8], .little);
            const msg_len = std.mem.readInt(u32, payload[off + 16 ..][0..4], .little);
            off += 20;
            if (off + msg_len > payload.len) break;
            const msg = payload[off .. off + msg_len];
            off += msg_len;
            self.step_scratch.append(self.allocator, .{
                .group_id = group_id,
                .epoch = epoch,
                .msg_ptr = msg.ptr,
                .msg_len = msg.len,
            }) catch return;
        }
        _ = self.manager.stepBatch(self.step_scratch.items);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "transport: coalesced envelope round-trips message bytes" {
    // Build a payload the way `flush` does, then decode it the way `onRecv`
    // does — proving the wire format is self-consistent without standing up
    // sockets. (The on-socket path is exercised by the 3-node node test.)
    const a = testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(a);

    const msgs = [_]struct { gid: u64, epoch: u64, bytes: []const u8 }{
        .{ .gid = 7, .epoch = 0, .bytes = "vote-req-bytes" },
        .{ .gid = 7, .epoch = 3, .bytes = "append-entries" },
        .{ .gid = 42, .epoch = 1, .bytes = "x" },
    };
    for (msgs) |m| {
        var hdr: [20]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], m.gid, .little);
        std.mem.writeInt(u64, hdr[8..16], m.epoch, .little);
        std.mem.writeInt(u32, hdr[16..20], @intCast(m.bytes.len), .little);
        try body.appendSlice(a, &hdr);
        try body.appendSlice(a, m.bytes);
    }
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(a);
    var cnt: [4]u8 = undefined;
    std.mem.writeInt(u32, &cnt, msgs.len, .little);
    try payload.appendSlice(a, &cnt);
    try payload.appendSlice(a, body.items);

    // Decode.
    const p = payload.items;
    const count = std.mem.readInt(u32, p[0..4], .little);
    try testing.expectEqual(@as(u32, 3), count);
    var off: usize = 4;
    var seen: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const gid = std.mem.readInt(u64, p[off..][0..8], .little);
        const epoch = std.mem.readInt(u64, p[off + 8 ..][0..8], .little);
        const mlen = std.mem.readInt(u32, p[off + 16 ..][0..4], .little);
        off += 20;
        const msg = p[off .. off + mlen];
        off += mlen;
        try testing.expectEqual(msgs[i].gid, gid);
        try testing.expectEqual(msgs[i].epoch, epoch);
        try testing.expectEqualStrings(msgs[i].bytes, msg);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqual(p.len, off);
}
