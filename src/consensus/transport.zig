//! V2 Phase 5 — cross-node raft transport (coalesced, per-recipient).
//!
//! v2-build-order §Phase 5: "reuse rove's `raft_net.zig` io_uring
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
//!     count × [group_id:u64 LE][epoch:u64 LE][floor:u64 LE][msg_len:u32 LE][msg bytes]
//!
//! `msg bytes` is the opaque rust-protobuf `eraftpb::Message` from
//! `takeMessages`, fed verbatim to the peer's `stepBatch`/`stepFenced`.
//! `floor` is the leader's cluster-wide min-match WAL-compaction floor for the
//! group (`maxInt` = none, from a non-leader sender); the follower compacts to
//! it in lockstep so the shared WAL bounds without a data-carrying snapshot.
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
const kvlimbs = @import("kvlimbs");

/// µs-bucketed latency histogram (atomic buckets — safe to snapshot from the
/// worker thread while the pump writes it). Reused for heartbeat RTT.
pub const MicrosHistogram = kvlimbs.MicrosHistogram;

fn nowNs() i64 {
    return @intCast(std.time.nanoTimestamp());
}

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
    /// Group ids that received a NON-heartbeat message since the last
    /// `drainWoke`. The pump drains this each cycle and `bumpActive`s each,
    /// so a hibernated group wakes on real raft traffic but NOT on its own
    /// keep-alive heartbeats (Phase 6 / §3.1). Appended in `onRecv` (pump
    /// thread); cleared by `drainWoke`. Dups are fine — `bumpActive` is
    /// idempotent — so no per-message dedup.
    woke: std.ArrayListUnmanaged(u64) = .empty,
    /// gid → highest WAL-compaction floor a LEADER stamped on inbound messages
    /// since the last `drainFloors`. The pump drains it each cycle and records
    /// it on each group's slot so a FOLLOWER compacts to the same floor as the
    /// leader (lockstep, snapshot-free). Pump-thread only.
    recv_floors: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Total inbound messages `stepBatch` skipped (unknown group / epoch
    /// fence / decode failure) — rate-limited-logged in `onRecv` so a
    /// node silently dropping a group's traffic is operator-visible.
    step_skip_count: u64 = 0,

    /// Broadcast-time observability (raft-best-practices §"how to size
    /// election/heartbeat"). `hb_sent_ns[peer]` is the wall-clock at which this
    /// node last sent a `MsgHeartbeat` to that peer (raft_net peer id =
    /// node_id-1; 0 = no outstanding heartbeat). On the matching inbound
    /// `MsgHeartbeatResponse`, the send→response delta is observed into
    /// `hb_rtt` — an empirical leader↔follower round-trip (incl. pump-loop
    /// latency on both ends), i.e. the `broadcastTime` the election timeout must
    /// sit well above. Pump-thread only (queueOut + onRecv); the histogram's
    /// atomic buckets let `/_system/metrics` snapshot it from the worker thread.
    hb_sent_ns: []i64,
    hb_rtt: MicrosHistogram = .{},

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

        const hb_sent_ns = allocator.alloc(i64, cfg.peers.len) catch return Error.OutOfMemory;
        errdefer allocator.free(hb_sent_ns);
        @memset(hb_sent_ns, 0);

        self.* = .{
            .allocator = allocator,
            .node_id = cfg.node_id,
            .cluster_size = cfg.peers.len,
            .net = undefined,
            .manager = cfg.manager,
            .outbufs = outbufs,
            .hb_sent_ns = hb_sent_ns,
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
        a.free(self.hb_sent_ns);
        self.step_scratch.deinit(a);
        self.woke.deinit(a);
        self.recv_floors.deinit(a);
        a.destroy(self);
    }

    /// Append the gids that received a non-heartbeat message since the last
    /// call into `out`, then clear the internal buffer. Pump-thread only
    /// (runs right after `tick`, on the same thread `onRecv` filled it).
    pub fn drainWoke(self: *Transport, out: *std.ArrayListUnmanaged(u64), a: std.mem.Allocator) !void {
        try out.appendSlice(a, self.woke.items);
        self.woke.clearRetainingCapacity();
    }

    /// Visit each (gid, leader-stamped floor) received since the last call,
    /// then clear. The pump uses it to advance each group's follower
    /// compaction floor. Pump-thread only (drains what `onRecv` filled).
    pub fn drainFloors(self: *Transport, ctx: anytype, comptime apply: fn (@TypeOf(ctx), u64, u64) void) void {
        var it = self.recv_floors.iterator();
        while (it.next()) |e| apply(ctx, e.key_ptr.*, e.value_ptr.*);
        self.recv_floors.clearRetainingCapacity();
    }

    /// Snapshot the heartbeat round-trip histogram (broadcast-time samples).
    /// Lock-free: the histogram's atomic buckets are written on the pump thread
    /// (queueOut/onRecv) and read here from the worker thread (`/_system/metrics`).
    pub fn heartbeatRttSnapshot(self: *const Transport) MicrosHistogram.Snapshot {
        return self.hb_rtt.snapshot();
    }

    /// Whether a raw eraftpb message is a heartbeat / heartbeat-response —
    /// the wire bytes for `MsgHeartbeat` (8) / `MsgHeartbeatResponse` (9).
    /// `msg_type` is eraftpb field 1, a varint, so the encoding is
    /// `[0x08][value]` (the value < 16, single byte). Codec-independent: the
    /// same bytes under protobuf-codec or prost-codec. A heartbeat means
    /// "don't elect me," not "I have work," so it must NOT wake a hibernated
    /// group (multiraft-scaling-learnings §3.1).
    inline fn isHeartbeatLike(bytes: []const u8) bool {
        if (bytes.len < 2) return false;
        if (bytes[0] != 0x08) return false; // field 1 (msg_type), varint tag
        return bytes[1] == 8 or bytes[1] == 9;
    }

    /// `MsgHeartbeat` (8) — leader→follower keep-alive (the RTT probe).
    inline fn isHeartbeatReq(bytes: []const u8) bool {
        return bytes.len >= 2 and bytes[0] == 0x08 and bytes[1] == 8;
    }

    /// `MsgHeartbeatResponse` (9) — follower→leader ack (closes the RTT).
    inline fn isHeartbeatResp(bytes: []const u8) bool {
        return bytes.len >= 2 and bytes[0] == 0x08 and bytes[1] == 9;
    }

    /// Buffer one outbound message (from `Manager.takeMessages`) for its
    /// destination node, to be coalesced + sent at `flush`. `to` is a raft
    /// node id; a message to self (shouldn't happen) is dropped.
    pub fn queueOut(self: *Transport, to: u64, group_id: u64, epoch: u64, floor: u64, msg: []const u8) void {
        if (to == self.node_id or to == 0 or to > self.cluster_size) return;
        // Broadcast-time probe: stamp the moment we send a heartbeat to this
        // peer so the matching response (in `onRecv`) yields the RTT. One
        // outstanding heartbeat per peer; a later send just overwrites the
        // stamp (a dropped response is harmless — it won't be matched).
        if (isHeartbeatReq(msg)) self.hb_sent_ns[to - 1] = nowNs();
        const ob = &self.outbufs[to - 1];
        const a = self.allocator;
        // Roll back to this mark on a partial append: a header without
        // its message bytes would shift every later record's framing in
        // the coalesced envelope (the CRC covers the corrupt payload, so
        // the receiver would mis-parse the rest of the cycle's messages,
        // not reject them). Dropping the whole record is safe — raft
        // re-emits on the next tick.
        // `floor` is the cluster-wide min match index the LEADER stamps so
        // followers learn the safe WAL-compaction floor (lockstep compaction);
        // `maxInt` from a non-leader sender means "no floor", ignored on recv.
        const mark = ob.body.items.len;
        var hdr: [28]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], group_id, .little);
        std.mem.writeInt(u64, hdr[8..16], epoch, .little);
        std.mem.writeInt(u64, hdr[16..24], floor, .little);
        std.mem.writeInt(u32, hdr[24..28], @intCast(msg.len), .little);
        ob.body.appendSlice(a, &hdr) catch return;
        ob.body.appendSlice(a, msg) catch {
            ob.body.shrinkRetainingCapacity(mark);
            return;
        };
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
        // `from_id` is the raft_net peer id of the SENDER (= its node_id-1) —
        // used below to close the heartbeat RTT. Stepping still reads each
        // message's own `from` field; `from_id` only attributes the round-trip.
        const self: *Transport = @ptrCast(@alignCast(ctx.?));
        if (payload.len < 4) return;
        const count = std.mem.readInt(u32, payload[0..4], .little);
        var off: usize = 4;
        self.step_scratch.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (off + 28 > payload.len) break;
            const group_id = std.mem.readInt(u64, payload[off..][0..8], .little);
            const epoch = std.mem.readInt(u64, payload[off + 8 ..][0..8], .little);
            const floor = std.mem.readInt(u64, payload[off + 16 ..][0..8], .little);
            const msg_len = std.mem.readInt(u32, payload[off + 24 ..][0..4], .little);
            off += 28;
            if (off + msg_len > payload.len) break;
            const msg = payload[off .. off + msg_len];
            off += msg_len;
            self.step_scratch.append(self.allocator, .{
                .group_id = group_id,
                .epoch = epoch,
                .msg_ptr = msg.ptr,
                .msg_len = msg.len,
            }) catch return;
            // The leader's WAL-compaction floor for this group (maxInt = none).
            // Keep the highest seen this batch; the pump drains it post-tick.
            if (floor != std.math.maxInt(u64)) {
                const gop = self.recv_floors.getOrPut(self.allocator, group_id) catch null;
                if (gop) |e| {
                    if (!e.found_existing or floor > e.value_ptr.*) e.value_ptr.* = floor;
                }
            }
            // Real raft traffic wakes a hibernated group; heartbeats do not.
            if (!isHeartbeatLike(msg)) self.woke.append(self.allocator, group_id) catch {};

            // Close the broadcast-time probe: a heartbeat response from `from_id`
            // pairs with the last heartbeat we sent that peer. Observe the RTT
            // (µs) and clear the stamp so a duplicate/late response isn't
            // re-counted against a newer send.
            if (isHeartbeatResp(msg) and from_id < self.cluster_size) {
                const sent = self.hb_sent_ns[from_id];
                if (sent != 0) {
                    const rtt_ns = nowNs() - sent;
                    if (rtt_ns > 0) self.hb_rtt.observe(@intCast(@divTrunc(rtt_ns, std.time.ns_per_us)));
                    self.hb_sent_ns[from_id] = 0;
                }
            }
        }
        const stepped = self.manager.stepBatch(self.step_scratch.items);
        // stepBatch skips bad entries silently (unknown group, stale
        // epoch fence, decode failure). An unknown group is the loud
        // case to watch: a node that missed a group's attach fan-out
        // drops that tenant's raft traffic forever — quorum silently
        // degrades to N-1 with zero signal. Count + rate-limit-log so
        // the degradation is operator-visible.
        if (stepped < self.step_scratch.items.len) {
            const skipped = self.step_scratch.items.len - stepped;
            self.step_skip_count +%= skipped;
            if (self.step_skip_count == skipped or self.step_skip_count / 1000 != (self.step_skip_count - skipped) / 1000) {
                std.log.warn(
                    "v2 transport node {d}: stepBatch skipped {d}/{d} inbound messages (unknown group / fenced / undecodable) — {d} total",
                    .{ self.node_id, skipped, self.step_scratch.items.len, self.step_skip_count },
                );
            }
        }
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

    const msgs = [_]struct { gid: u64, epoch: u64, floor: u64, bytes: []const u8 }{
        .{ .gid = 7, .epoch = 0, .floor = std.math.maxInt(u64), .bytes = "vote-req-bytes" },
        .{ .gid = 7, .epoch = 3, .floor = 1234, .bytes = "append-entries" },
        .{ .gid = 42, .epoch = 1, .floor = 0, .bytes = "x" },
    };
    for (msgs) |m| {
        var hdr: [28]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], m.gid, .little);
        std.mem.writeInt(u64, hdr[8..16], m.epoch, .little);
        std.mem.writeInt(u64, hdr[16..24], m.floor, .little);
        std.mem.writeInt(u32, hdr[24..28], @intCast(m.bytes.len), .little);
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
        const floor = std.mem.readInt(u64, p[off + 16 ..][0..8], .little);
        const mlen = std.mem.readInt(u32, p[off + 24 ..][0..4], .little);
        off += 28;
        const msg = p[off .. off + mlen];
        off += mlen;
        try testing.expectEqual(msgs[i].gid, gid);
        try testing.expectEqual(msgs[i].epoch, epoch);
        try testing.expectEqual(msgs[i].floor, floor);
        try testing.expectEqualStrings(msgs[i].bytes, msg);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqual(p.len, off);
}
