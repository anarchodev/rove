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
//!     [version:u8]
//!     [count:u32 LE]
//!     count × [group_id:u64 LE][epoch:u64 LE][msg_len:u32 LE][msg bytes]
//!
//! The leading `version` byte is a single frame-level discriminant
//! (`docs/format-versioning-audit.md` §3.2 — "version without widening
//! the per-record header"): one byte amortized over a whole coalesced
//! frame, zero per-record growth, so the deliberately-shrunk 20-byte
//! record header (Phase 2f) is untouched. The decoder rejects an unknown
//! version loudly (rate-limited) rather than mis-stepping garbage into
//! the Manager.
//!
//! `msg bytes` is the opaque rust-protobuf `eraftpb::Message` from
//! `takeMessages`, fed verbatim to the peer's `stepBatch`/`stepFenced`.
//! (A per-record `floor` field — the leader's lockstep WAL-compaction floor —
//! was removed in Phase 2f: mechanism-A compaction is per-node, so no cross-node
//! floor is propagated and the WAL bounds via the catch-up buffer + snapshots.)
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
pub const PeerResolver = raftnet.PeerResolver;

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

/// Per-record header in the coalesced body: [group_id:u64][epoch:u64][len:u32].
/// (The WAL-compaction `floor` field was removed in Phase 2f — mechanism-A
/// compaction is per-node, so no cross-node floor is propagated.)
const RECORD_HDR_SIZE: usize = 20;
/// Coalesced-frame version byte (`docs/format-versioning-audit.md` §3.2).
/// Bump when the frame/record layout changes; the decoder rejects any
/// other value loudly. Frozen v1 at the pre-launch format freeze.
pub const FRAME_VERSION: u8 = 1;
/// Bytes the frame prepends to the body before the records: `version:u8`
/// + `count:u32`.
const FRAME_PREFIX_SIZE: usize = 1 + 4;
/// A coalesced frame is [HEADER_SIZE][version:u8][count:u32][body] and MUST fit
/// the receiver's fixed recv buffer (raft_net's RECV_BUF_SIZE) — an oversize
/// frame can't be reassembled and is torn down loudly on the recv side. Cap the
/// body accordingly; queueOut flushes early when the next record would blow it.
const MAX_FRAME_BODY: usize = @as(usize, raftnet.RECV_BUF_SIZE) - rpc.HEADER_SIZE - FRAME_PREFIX_SIZE;

/// Peer-slot capacity: the largest cluster this node will ever address. The
/// per-destination buffers (`outbufs`, `hb_sent_ns`) and `raft_net`'s peer
/// table are sized to this at init, so a node born in a small cluster can grow
/// (consensus-and-storage.md "Cluster genesis & membership", peer-address
/// resolution) up to this bound without re-allocating
/// the hot-path buffers. Matches the directory's `MAX_CLUSTER_NODES`.
pub const MAX_CLUSTER_NODES: usize = 16;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    /// This node's raft id (1-based).
    node_id: u64,
    /// Peer-slot capacity (raft_net peer ids 0..cap-1). The destination
    /// buffers are sized to this so the cluster can grow up to `cap` without
    /// re-allocating the hot path; a node id beyond it is dropped at `queueOut`.
    cap: usize,
    net: *RaftNet,
    /// Borrowed — the Node's `Manager`. Inbound messages step into it.
    manager: *raft.Manager,
    /// Resolves a raft node id → transport address the first time we address a
    /// peer we haven't dialed yet (the growth seam). Defaults to a static
    /// resolver over the init-time peer list (`static_peers`), so a cluster
    /// configured the old way behaves identically — every initial peer is
    /// already configured in `raft_net`, so the resolver is never consulted.
    /// `1c` injects a CP-registry-backed resolver here instead.
    resolver: PeerResolver,
    /// Owned copy of the init-time peer addresses (host strings duped), backing
    /// the default static resolver. Indexed by `node_id - 1`. Present even when
    /// a custom resolver is supplied (then unused), freed at deinit.
    static_peers: []PeerAddr,

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
    /// Total inbound messages `stepBatch` skipped (unknown group / epoch
    /// fence / decode failure) — rate-limited-logged in `onRecv` so a
    /// node silently dropping a group's traffic is operator-visible.
    step_skip_count: u64 = 0,
    /// Total inbound frames dropped for an unrecognized frame-version byte
    /// (a peer running an incompatible binary / a stale pre-freeze frame) —
    /// rate-limited-logged in `onRecv`. Should be 0 in a uniform cluster;
    /// nonzero means a deploy skew or a format that needed a data wipe.
    bad_frame_count: u64 = 0,

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

    /// Node-wide outbound-mesh health, published each `tick` (pump thread) and
    /// read lock-free by `/_system/metrics` (worker thread) — the same
    /// publish-an-atomic discipline as the per-group `is_leader` gauge.
    /// `configured - connected` is the dial-mesh wedge signal (zombie-connect /
    /// partition: peers raft must reach but can't). See `RaftNet.meshCounts`.
    mesh_configured: std.atomic.Value(u32) = .init(0),
    mesh_connected: std.atomic.Value(u32) = .init(0),

    pub const Config = struct {
        /// This node's raft id (1-based, must be ≤ peers.len).
        node_id: u64,
        listen_addr: std.net.Address,
        /// Peer addresses indexed by raft_net peer id: `peers[k]` is the
        /// address of raft node `k + 1`. These are the peers known at init —
        /// the cluster can later grow beyond them via the resolver. May be just
        /// `{self}` for a node born single-voter.
        peers: []const PeerAddr,
        /// Borrowed Manager to step inbound messages into.
        manager: *raft.Manager,
        /// Optional address resolver for nodes added after init (the growth
        /// seam). When null, a static resolver over `peers` is synthesized, so
        /// statically-configured clusters behave exactly as before.
        resolver: ?PeerResolver = null,
        /// Largest cluster this node will ever address; sizes the destination
        /// buffers + the `raft_net` peer table. Must be ≥ `peers.len`.
        max_nodes: usize = MAX_CLUSTER_NODES,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!*Transport {
        std.debug.assert(cfg.max_nodes >= cfg.peers.len);
        const self = allocator.create(Transport) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);

        // Size the destination buffers to capacity (not the init-time peer
        // count) so growth never re-allocates the hot path.
        const outbufs = allocator.alloc(OutBuf, cfg.max_nodes) catch return Error.OutOfMemory;
        errdefer allocator.free(outbufs);
        for (outbufs) |*ob| ob.* = .{};

        const hb_sent_ns = allocator.alloc(i64, cfg.max_nodes) catch return Error.OutOfMemory;
        errdefer allocator.free(hb_sent_ns);
        @memset(hb_sent_ns, 0);

        // Default static resolver: dupe the init-time peer addresses so it does
        // not depend on the caller's slice lifetime. Duped unconditionally
        // (≤ max_nodes entries, init-time only); when a custom resolver is
        // supplied these go unused but are freed at deinit.
        const static_peers = dupePeers(allocator, cfg.peers) catch return Error.OutOfMemory;
        errdefer freePeers(allocator, static_peers);

        self.* = .{
            .allocator = allocator,
            .node_id = cfg.node_id,
            .cap = cfg.max_nodes,
            .net = undefined,
            .manager = cfg.manager,
            .outbufs = outbufs,
            .hb_sent_ns = hb_sent_ns,
            .resolver = cfg.resolver orelse .{ .ctx = self, .resolveFn = staticResolve },
            .static_peers = static_peers,
        };

        // raft_net node/peer ids are 0-based; raft node ids are 1-based.
        const net = RaftNet.init(allocator, .{
            .node_id = @intCast(cfg.node_id - 1),
            .peers = cfg.peers,
            .listen_addr = cfg.listen_addr,
            .on_recv = onRecv,
            .user_ctx = self,
            .max_nodes = @intCast(cfg.max_nodes),
        }) catch return Error.TransportInit;
        self.net = net;
        return self;
    }

    /// Default resolver: index the duped init-time peer list by `node_id - 1`.
    /// Returns null for ids beyond the init set — a statically-configured
    /// cluster never grows, so those are genuinely-unknown nodes to drop.
    fn staticResolve(ctx: ?*anyopaque, node_id: u64) ?PeerAddr {
        const self: *Transport = @ptrCast(@alignCast(ctx.?));
        if (node_id == 0 or node_id > self.static_peers.len) return null;
        return self.static_peers[node_id - 1];
    }

    fn dupePeers(a: std.mem.Allocator, peers: []const PeerAddr) ![]PeerAddr {
        const out = try a.alloc(PeerAddr, peers.len);
        errdefer a.free(out);
        var done: usize = 0;
        errdefer for (out[0..done]) |p| a.free(p.host);
        for (peers, 0..) |p, i| {
            out[i] = .{ .host = try a.dupe(u8, p.host), .port = p.port, .mode = p.mode };
            done = i + 1;
        }
        return out;
    }

    fn freePeers(a: std.mem.Allocator, peers: []PeerAddr) void {
        for (peers) |p| a.free(p.host);
        a.free(peers);
    }

    pub fn deinit(self: *Transport) void {
        const a = self.allocator;
        self.net.deinit();
        for (self.outbufs) |*ob| ob.body.deinit(a);
        a.free(self.outbufs);
        a.free(self.hb_sent_ns);
        freePeers(a, self.static_peers);
        self.step_scratch.deinit(a);
        self.woke.deinit(a);
        a.destroy(self);
    }

    /// Append the gids that received a non-heartbeat message since the last
    /// call into `out`, then clear the internal buffer. Pump-thread only
    /// (runs right after `tick`, on the same thread `onRecv` filled it).
    pub fn drainWoke(self: *Transport, out: *std.ArrayListUnmanaged(u64), a: std.mem.Allocator) !void {
        try out.appendSlice(a, self.woke.items);
        self.woke.clearRetainingCapacity();
    }

    /// Swap in a peer-address resolver (e.g. a CP-fed `PeerRegistry`). MUST be
    /// called before the pump starts — `queueOut` (pump thread) reads
    /// `self.resolver` with no lock, so a post-pump swap would race. The default
    /// static resolver stays until this is called, so it's safe to skip.
    pub fn setResolver(self: *Transport, r: PeerResolver) void {
        self.resolver = r;
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
    pub fn queueOut(self: *Transport, to: u64, group_id: u64, epoch: u64, msg: []const u8) void {
        if (to == self.node_id or to == 0 or to > self.cap) return;
        // Growth seam: the first time we have a message for a node we haven't
        // dialed yet, resolve its address and register it so `raft_net`'s
        // reconnect loop starts dialing. A node still unknown to the resolver is
        // dropped (raft re-emits next tick). In the static path every initial
        // peer is already configured, so this is never taken — identical
        // behavior. `peer_id = node_id - 1`.
        const peer_id: u32 = @intCast(to - 1);
        if (!self.net.isPeerConfigured(peer_id)) {
            const pa = self.resolver.resolve(to) orelse return;
            self.net.addPeer(peer_id, pa) catch return;
        }
        // Broadcast-time probe: stamp the moment we send a heartbeat to this
        // peer so the matching response (in `onRecv`) yields the RTT. One
        // outstanding heartbeat per peer; a later send just overwrites the
        // stamp (a dropped response is harmless — it won't be matched).
        if (isHeartbeatReq(msg)) self.hb_sent_ns[to - 1] = nowNs();
        const ob = &self.outbufs[to - 1];
        const a = self.allocator;
        // Cap the coalesced frame so it never exceeds the receiver's fixed recv
        // buffer: if appending this record would blow MAX_FRAME_BODY, flush what's
        // buffered first and start a fresh frame (the recv side handles multiple
        // frames per read). A single record larger than the cap still goes out
        // alone — surfaced loudly on the recv side, not a silent wedge; keep
        // raft's max_size_per_msg under RECV_BUF_SIZE so that can't happen.
        if (ob.count > 0 and ob.body.items.len + RECORD_HDR_SIZE + msg.len > MAX_FRAME_BODY)
            self.flushPeer(to - 1, ob);
        // Roll back to this mark on a partial append: a header without
        // its message bytes would shift every later record's framing in
        // the coalesced envelope (the CRC covers the corrupt payload, so
        // the receiver would mis-parse the rest of the cycle's messages,
        // not reject them). Dropping the whole record is safe — raft
        // re-emits on the next tick.
        const mark = ob.body.items.len;
        var hdr: [RECORD_HDR_SIZE]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], group_id, .little);
        std.mem.writeInt(u64, hdr[8..16], epoch, .little);
        std.mem.writeInt(u32, hdr[16..20], @intCast(msg.len), .little);
        ob.body.appendSlice(a, &hdr) catch return;
        ob.body.appendSlice(a, msg) catch {
            ob.body.shrinkRetainingCapacity(mark);
            return;
        };
        ob.count += 1;
    }

    /// Emit one destination's coalesced envelope as a single framed send and
    /// reset its buffer. Send errors (peer not yet connected, queue full) are
    /// soft — raft re-emits on the next heartbeat/election tick.
    fn flushPeer(self: *Transport, peer_id: usize, ob: *OutBuf) void {
        if (ob.count == 0) return;
        const a = self.allocator;
        defer {
            ob.count = 0;
            ob.body.clearRetainingCapacity();
        }
        const payload_len = FRAME_PREFIX_SIZE + ob.body.items.len;
        const frame = a.alloc(u8, rpc.HEADER_SIZE + payload_len) catch return;
        defer a.free(frame);
        // payload = [version][count][body]; frame header = [len BE][crc BE].
        frame[rpc.HEADER_SIZE] = FRAME_VERSION;
        std.mem.writeInt(u32, frame[rpc.HEADER_SIZE + 1 ..][0..4], ob.count, .little);
        @memcpy(frame[rpc.HEADER_SIZE + FRAME_PREFIX_SIZE ..], ob.body.items);
        const payload = frame[rpc.HEADER_SIZE..];
        std.mem.writeInt(u32, frame[0..4], @intCast(payload_len), .big);
        std.mem.writeInt(u32, frame[4..8], rpc.checksum(payload), .big);
        self.net.send(@intCast(peer_id), frame) catch {};
    }

    /// Flush each destination's coalesced envelope (queueOut may already have
    /// flushed earlier frames mid-cycle when the cap was hit).
    pub fn flush(self: *Transport) void {
        for (self.outbufs, 0..) |*ob, peer_id| self.flushPeer(peer_id, ob);
    }

    /// Drive the io_uring transport once: flush queued sends, accept, and
    /// deliver inbound frames (each → `onRecv` → `stepBatch`). `wait_timeout_ns`
    /// is how long to block for I/O when idle (the pump's idle wait).
    pub fn tick(self: *Transport, now_ns: i64, wait_timeout_ns: u64) !void {
        try self.net.tick(now_ns, wait_timeout_ns);
        // Publish the outbound dial-mesh snapshot for `/_system/metrics`: pump
        // thread writes, worker thread reads (lock-free atomics). Done every
        // cycle so the gauge tracks connect/teardown as it happens.
        const m = self.net.meshCounts();
        self.mesh_configured.store(m.configured, .release);
        self.mesh_connected.store(m.connected, .release);
    }

    /// Lock-free snapshot of the outbound dial-mesh for `/_system/metrics`
    /// (worker thread) — reads the atomics published by `tick` on the pump
    /// thread. One pump cycle stale at worst, same as the `is_leader` gauge.
    pub const MeshSnapshot = struct { configured: u32, connected: u32 };

    pub fn meshSnapshot(self: *const Transport) MeshSnapshot {
        return .{
            .configured = self.mesh_configured.load(.acquire),
            .connected = self.mesh_connected.load(.acquire),
        };
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
        if (payload.len < FRAME_PREFIX_SIZE) return;
        const ver = payload[0];
        if (ver != FRAME_VERSION) {
            // A peer on an incompatible binary, or a stale pre-freeze frame.
            // Drop loudly (rate-limited) rather than mis-stepping garbage.
            self.bad_frame_count +%= 1;
            if (self.bad_frame_count == 1 or self.bad_frame_count % 1000 == 0) {
                std.log.warn(
                    "v2 transport node {d}: dropped inbound frame with unknown version {d} (expected {d}) — {d} total; check for deploy skew / un-wiped data",
                    .{ self.node_id, ver, FRAME_VERSION, self.bad_frame_count },
                );
            }
            return;
        }
        const count = std.mem.readInt(u32, payload[1..5], .little);
        var off: usize = FRAME_PREFIX_SIZE;
        self.step_scratch.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (off + RECORD_HDR_SIZE > payload.len) break;
            const group_id = std.mem.readInt(u64, payload[off..][0..8], .little);
            const epoch = std.mem.readInt(u64, payload[off + 8 ..][0..8], .little);
            const msg_len = std.mem.readInt(u32, payload[off + 16 ..][0..4], .little);
            off += RECORD_HDR_SIZE;
            if (off + msg_len > payload.len) break;
            const msg = payload[off .. off + msg_len];
            off += msg_len;
            self.step_scratch.append(self.allocator, .{
                .group_id = group_id,
                .epoch = epoch,
                .msg_ptr = msg.ptr,
                .msg_len = msg.len,
            }) catch return;
            // Real raft traffic wakes a hibernated group; heartbeats do not.
            if (!isHeartbeatLike(msg)) self.woke.append(self.allocator, group_id) catch {};

            // Close the broadcast-time probe: a heartbeat response from `from_id`
            // pairs with the last heartbeat we sent that peer. Observe the RTT
            // (µs) and clear the stamp so a duplicate/late response isn't
            // re-counted against a newer send.
            if (isHeartbeatResp(msg) and from_id < self.cap) {
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
                // RC-2 observability: name the gid + epoch mismatch + sender so a
                // silent quorum-degradation is diagnosable (which tenant, which
                // peer, fenced-vs-unknown). `stepBatch` returns only a count, so we
                // dump the whole (small) batch — the skipped entries are in here.
                // `local_epoch` vs `msg_epoch`: differ ⇒ epoch FENCE; local 0 with
                // msg>0 ⇒ likely UNKNOWN GROUP (group absent / not yet attached);
                // equal ⇒ UNDECODABLE. Bounded scan; pump-thread, only on a skip.
                var j: usize = 0;
                while (j < self.step_scratch.items.len and j < 16) : (j += 1) {
                    const e = self.step_scratch.items[j];
                    const local_epoch = self.manager.groupEpoch(e.group_id);
                    const reason = if (local_epoch == e.epoch) "undecodable" else if (local_epoch == 0) "unknown-group?" else "fenced(epoch)";
                    std.log.warn(
                        "v2 transport node {d}:   skip-detail gid={d} msg_epoch={d} local_epoch={d} from=node{d} reason={s}",
                        .{ self.node_id, e.group_id, e.epoch, local_epoch, from_id + 1, reason },
                    );
                }
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

    const msgs = [_]struct { gid: u64, epoch: u64, bytes: []const u8 }{
        .{ .gid = 7, .epoch = 0, .bytes = "vote-req-bytes" },
        .{ .gid = 7, .epoch = 3, .bytes = "append-entries" },
        .{ .gid = 42, .epoch = 1, .bytes = "x" },
    };
    for (msgs) |m| {
        var hdr: [RECORD_HDR_SIZE]u8 = undefined;
        std.mem.writeInt(u64, hdr[0..8], m.gid, .little);
        std.mem.writeInt(u64, hdr[8..16], m.epoch, .little);
        std.mem.writeInt(u32, hdr[16..20], @intCast(m.bytes.len), .little);
        try body.appendSlice(a, &hdr);
        try body.appendSlice(a, m.bytes);
    }
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(a);
    try payload.append(a, FRAME_VERSION);
    var cnt: [4]u8 = undefined;
    std.mem.writeInt(u32, &cnt, msgs.len, .little);
    try payload.appendSlice(a, &cnt);
    try payload.appendSlice(a, body.items);

    // Decode.
    const p = payload.items;
    try testing.expectEqual(FRAME_VERSION, p[0]);
    const count = std.mem.readInt(u32, p[1..5], .little);
    try testing.expectEqual(@as(u32, 3), count);
    var off: usize = FRAME_PREFIX_SIZE;
    var seen: usize = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const gid = std.mem.readInt(u64, p[off..][0..8], .little);
        const epoch = std.mem.readInt(u64, p[off + 8 ..][0..8], .little);
        const mlen = std.mem.readInt(u32, p[off + 16 ..][0..4], .little);
        off += RECORD_HDR_SIZE;
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

test "transport: queueOut resolves + registers a peer beyond the init set (growth seam)" {
    // The cluster-genesis growth seam (§3.3): a node born knowing only a subset
    // of the cluster can still address a node it learns later — the first
    // outbound message to an unknown id hits the resolver and registers the
    // peer in raft_net. No raft FFI stepping here (the manager is never
    // touched by queueOut); we assert purely on raft_net's peer table.
    const a = testing.allocator;

    const Res = struct {
        fn resolve(ctx: ?*anyopaque, node_id: u64) ?PeerAddr {
            _ = ctx;
            // Knows node 3 only; everything else is genuinely unknown.
            if (node_id == 3) return .{ .host = "127.0.0.1", .port = 19099 };
            return null;
        }
    };

    var mgr = raft.Manager.init() catch return error.SkipZigTest;
    defer mgr.deinit();

    // Bind an ephemeral port — this test never connects, accepts, or ticks.
    const listen = try std.net.Address.parseIp("127.0.0.1", 0);
    // Born knowing only {self = node 1, node 2}; node 3 is learned via the
    // resolver, mirroring a node that genesis'd small and grew.
    var peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = 18090 }, // node 1 (self slot)
        .{ .host = "127.0.0.1", .port = 18091 }, // node 2
    };
    const t = Transport.init(a, .{
        .node_id = 1,
        .listen_addr = listen,
        .peers = &peers,
        .manager = &mgr,
        .resolver = .{ .ctx = null, .resolveFn = Res.resolve },
    }) catch |e| {
        // No io_uring / socket in the sandbox → skip rather than fail.
        if (e == Error.TransportInit) return error.SkipZigTest;
        return e;
    };
    defer t.deinit();

    // Capacity is the max, not the init-time peer count.
    try testing.expectEqual(MAX_CLUSTER_NODES, t.cap);
    // Node 3 (raft_net peer_id 2) is unknown at birth.
    try testing.expect(!t.net.isPeerConfigured(2));

    // A message addressed to node 3 hits the resolver → registers the peer so
    // raft_net's reconnect loop will dial it.
    t.queueOut(3, 7, 0, "append-entries");
    try testing.expect(t.net.isPeerConfigured(2));

    // A node the resolver doesn't know (node 5, peer_id 4) is dropped — never
    // registered, never indexed past the configured slots.
    t.queueOut(5, 7, 0, "x");
    try testing.expect(!t.net.isPeerConfigured(4));

    // Beyond capacity is ignored at the guard (no out-of-bounds, no panic).
    t.queueOut(@as(u64, MAX_CLUSTER_NODES) + 1, 7, 0, "x");
}

test "transport: the default static resolver does not grow past the init set" {
    // With no custom resolver, a node addressed beyond its static peer list is
    // dropped — the old positional behavior, preserved. Proves the static path
    // never silently fabricates a peer.
    const a = testing.allocator;

    var mgr = raft.Manager.init() catch return error.SkipZigTest;
    defer mgr.deinit();

    const listen = try std.net.Address.parseIp("127.0.0.1", 0);
    var peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = 18092 }, // node 1 (self slot)
        .{ .host = "127.0.0.1", .port = 18093 }, // node 2
    };
    const t = Transport.init(a, .{
        .node_id = 1,
        .listen_addr = listen,
        .peers = &peers,
        .manager = &mgr,
    }) catch |e| {
        if (e == Error.TransportInit) return error.SkipZigTest;
        return e;
    };
    defer t.deinit();

    // Node 3 is outside the static set → the default resolver returns null → no
    // registration.
    try testing.expect(!t.net.isPeerConfigured(2));
    t.queueOut(3, 7, 0, "append-entries");
    try testing.expect(!t.net.isPeerConfigured(2));
}
