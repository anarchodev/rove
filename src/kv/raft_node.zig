//! Thin façade over willemt/raft.
//!
//! Mirrors shift-js's raft_thread.c at MVP scope:
//!   - Opaque-bytes propose/apply (caller decides serialization).
//!   - Each proposal carries a caller-supplied `seq: u64`. The leader
//!     advances `committed_seq` when the entry is committed; on leader loss
//!     `faulted_seq` is set to `high_watermark` so workers whose proposals
//!     were in-flight know to roll back and return an error.
//!   - Optional persistent raft log + state (term/vote) via `raft_log_path`.
//!   - No snapshots or compaction (Phase 4+).
//!   - Single-node-per-thread; cross-thread propose() via lock-free MPSC.
//!
//! All willemt callbacks fire on the raft thread. The user-supplied apply_fn
//! is invoked from the raft thread inside `tick`.
//!
//! Wire format for raft log entries (the **batch envelope**):
//!
//!   [4B count BE]
//!   per write-set (count times):
//!     [8B seq BE]
//!     [4B body_len BE]
//!     [body_len bytes body]
//!
//! `body` is whatever the caller passed to `propose` — for the `.kv` apply
//! mode that's a `WriteSet` encoding; for `.opaque_bytes` it's arbitrary
//! user bytes. `cbApplyLog` walks the envelope and dispatches each
//! write-set through the configured apply mode, advancing `committed_seq`
//! monotonically as it goes.

const std = @import("std");
const raft_net_mod = @import("raft_net.zig");
const raft_rpc = @import("raft_rpc.zig");
const raft_log_mod = @import("raft_log.zig");
const kvstore_mod = @import("kvstore.zig");
const writeset = @import("writeset.zig");
const snapshot = @import("raft_snapshot.zig");
const callbacks = @import("raft_callbacks.zig");
const batcher = @import("proposal_batcher.zig");

pub const c = @cImport({
    @cInclude("stddef.h");
    @cInclude("raft.h");
});

pub const PeerAddr = raft_net_mod.PeerAddr;

// ── Transport interface ───────────────────────────────────────────────
//
// RaftNode is pluggable over its peer transport. The default impl is
// `RaftNet` (direct liburing TCP); alternate impls can be injected for
// tests or for non-TCP environments like Maelstrom (which provides its
// own simulated network via line-delimited JSON on stdin/stdout).
//
// A transport is a vtable + opaque ctx. RaftNode holds one and calls
// `send/tick/addPeer/removePeer/isPeerConfigured` through it. The
// transport in turn must call back into RaftNode's `onRecvFrame` when
// an inbound raft frame arrives; for RaftNet this happens via its
// existing `on_recv` callback, for Maelstrom it happens from the main
// stdin-reading loop.

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, peer_id: u32, frame: []const u8) anyerror!void,
        tick: *const fn (ptr: *anyopaque, now_ns: i64) anyerror!void,
        add_peer: *const fn (ptr: *anyopaque, peer_id: u32, addr: PeerAddr) anyerror!void,
        remove_peer: *const fn (ptr: *anyopaque, peer_id: u32) void,
        is_peer_configured: *const fn (ptr: *anyopaque, peer_id: u32) bool,
    };

    pub fn send(self: Transport, peer_id: u32, frame: []const u8) !void {
        return self.vtable.send(self.ptr, peer_id, frame);
    }
    pub fn tick(self: Transport, now_ns: i64) !void {
        return self.vtable.tick(self.ptr, now_ns);
    }
    pub fn addPeer(self: Transport, peer_id: u32, addr: PeerAddr) !void {
        return self.vtable.add_peer(self.ptr, peer_id, addr);
    }
    pub fn removePeer(self: Transport, peer_id: u32) void {
        return self.vtable.remove_peer(self.ptr, peer_id);
    }
    pub fn isPeerConfigured(self: Transport, peer_id: u32) bool {
        return self.vtable.is_peer_configured(self.ptr, peer_id);
    }
};

// Adapter that exposes a RaftNet as a Transport. Keeps RaftNet the
// default path used by every existing test.
fn raftNetVTable() *const Transport.VTable {
    const S = struct {
        fn send(ptr: *anyopaque, peer_id: u32, frame: []const u8) anyerror!void {
            const net: *raft_net_mod.RaftNet = @ptrCast(@alignCast(ptr));
            return net.send(peer_id, frame);
        }
        fn tick(ptr: *anyopaque, now_ns: i64) anyerror!void {
            const net: *raft_net_mod.RaftNet = @ptrCast(@alignCast(ptr));
            return net.tick(now_ns, false);
        }
        fn addPeer(ptr: *anyopaque, peer_id: u32, addr: PeerAddr) anyerror!void {
            const net: *raft_net_mod.RaftNet = @ptrCast(@alignCast(ptr));
            return net.addPeer(peer_id, addr);
        }
        fn removePeer(ptr: *anyopaque, peer_id: u32) void {
            const net: *raft_net_mod.RaftNet = @ptrCast(@alignCast(ptr));
            net.removePeer(peer_id);
        }
        fn isPeerConfigured(ptr: *anyopaque, peer_id: u32) bool {
            const net: *raft_net_mod.RaftNet = @ptrCast(@alignCast(ptr));
            return net.isPeerConfigured(peer_id);
        }
    };
    return &.{
        .send = S.send,
        .tick = S.tick,
        .add_peer = S.addPeer,
        .remove_peer = S.removePeer,
        .is_peer_configured = S.isPeerConfigured,
    };
}

pub fn transportFromRaftNet(net: *raft_net_mod.RaftNet) Transport {
    return .{ .ptr = net, .vtable = raftNetVTable() };
}

pub const ApplyFn = *const fn (index: u64, payload: []const u8, ctx: ?*anyopaque) void;

/// How `cbApplyLog` delivers committed entries.
pub const ApplyMode = union(enum) {
    /// Raw payload → user callback. Caller handles serialization and state.
    /// Good for opaque state machines or testing raft plumbing in isolation.
    opaque_bytes: struct {
        apply_fn: ApplyFn,
        ctx: ?*anyopaque = null,
    },

    /// Write-set payload → auto-apply to a KvStore on followers. Leader
    /// skips the apply (workers wrote locally before proposing). The
    /// write-set's seq is used as the row seq via `KvStore.putSeq`.
    kv: struct {
        store: *kvstore_mod.KvStore,
    },
};

/// Phase 5.5(c) step C — willemt fires `send_snapshot` when a
/// follower's `next_idx` falls below the leader's `snapshot_last_idx`
/// (i.e. willemt has compacted past entries the follower still
/// needs). Without a callback, willemt keeps trying to send log
/// entries it doesn't have and the follower never catches up.
///
/// The callback runs on the raft thread. Implementations should
/// stay fast — a typical impl sends a SNAP_OFFER RPC to the
/// follower and returns; the follower-side automation (download
/// + restore + raft_begin/end_load_snapshot) lands in a future
/// step. The current minimal callback just logs a clear,
/// operator-actionable warning naming the lagging peer + the
/// snap_id to restore from.
pub const NeedsSnapshotFn = *const fn (
    ctx: ?*anyopaque,
    raft: *RaftNode,
    peer_id: u32,
) void;

/// Follower-side handler for an incoming `snap_fetch_offer` RPC
/// (production.md #1.1 step 3). When a far-behind follower receives
/// this frame, the application layer is expected to GET the leader's
/// `fetch_path`, stage the response bytes into a tmp dir, atomic-
/// rename into `data_dir`, and call `raft_begin_load_snapshot` /
/// `raft_end_load_snapshot` at `(snap_last_term, snap_last_idx)`.
///
/// Runs on the raft thread — implementations should hand the work
/// off to a background task and return promptly. `fetch_path` is
/// borrowed for the duration of the call; copy if you need it
/// past the callback return.
pub const SnapFetchOfferFn = *const fn (
    ctx: ?*anyopaque,
    raft: *RaftNode,
    from_id: u32,
    snap_last_term: u64,
    snap_last_idx: u64,
    snap_id: u64,
    fetch_path: []const u8,
) void;

pub const Config = struct {
    node_id: u32,
    peers: []const PeerAddr,
    listen_addr: std.net.Address,
    apply: ApplyMode,
    /// Optional. When set, willemt's `send_snapshot` callback
    /// fires this fn instead of the no-op default. See
    /// `NeedsSnapshotFn` doc for the contract.
    needs_snapshot: ?NeedsSnapshotFn = null,
    needs_snapshot_ctx: ?*anyopaque = null,
    /// Optional. Receives `snap_fetch_offer` frames from peers
    /// (sent by leaders that compacted past this follower's
    /// `next_idx`). Wire it on the application layer (worker /
    /// files-server) to perform the out-of-band HTTP fetch + load
    /// flow. With no callback wired, frames are logged and dropped.
    on_snap_fetch_offer: ?SnapFetchOfferFn = null,
    on_snap_fetch_offer_ctx: ?*anyopaque = null,
    election_timeout_ms: u32 = 1000,
    request_timeout_ms: u32 = 200,
    /// If non-null, raft log + persistent state (term/vote) are backed by a
    /// SQLite database at this path. Restarts recover term/vote and replay
    /// log entries into willemt. Null = in-memory only (restarts lose all).
    raft_log_path: ?[:0]const u8 = null,
    /// Number of external workers that will call `workerBegin`/
    /// `workerCommitted`/`workerIdle`. Zero disables the watermark gate —
    /// every proposal flows straight through (appropriate when workers
    /// write to the local KvStore AFTER committedSeq advances, i.e. the
    /// non-optimistic path). Must be ≤ MAX_WORKERS.
    worker_count: u32 = 0,
    /// Maximum wall-clock time the raft thread will hold pending
    /// proposals before packing them into a raft entry + fsync'ing.
    /// Larger values amortize each fsync across more proposals, raising
    /// the write-throughput ceiling in exchange for up to this much
    /// added commit latency. 0 disables linger entirely (the default):
    /// every tick submits whatever it finds, ~1000 fsync/sec max.
    ///
    /// Under heavy write load at multi-worker scale, the raft thread's
    /// per-tick fsync becomes the hard ceiling — no amount of worker
    /// parallelism helps because every writeset funnels through one
    /// raft log. Setting this to a few hundred µs to a few ms trades
    /// a small amount of p99 commit latency for 3–5× higher write
    /// throughput. Suggested values: 500_000 (500 µs) for balanced,
    /// 2_000_000 (2 ms) for max throughput.
    propose_linger_ns: u64 = 0,
    /// Cap on how big a linger-accumulated batch is allowed to get.
    /// If the queue reaches this many items we submit immediately
    /// regardless of how much of `propose_linger_ns` has elapsed —
    /// preventing runaway queue growth under bursty load. Must be
    /// > 0 if `propose_linger_ns` is non-zero.
    propose_linger_max_batch: usize = 128,
};

/// Hard cap on worker_count. Matches shift-js's MAX_WORKERS.
pub const MAX_WORKERS: usize = 128;

/// Sentinel watermark: "this worker is idle, don't let it block safe_seq."
const WM_IDLE: u64 = std.math.maxInt(u64);

pub const ProposeError = error{
    NotLeader,
    /// Set when `requestStop` has been called but the caller hasn't yet
    /// joined the raft thread. Workers should treat this the same as a
    /// leadership change — back off and retry against a different node
    /// (or fail the client with 503).
    ShuttingDown,
    QueueFull,
    OutOfMemory,
};

// ── MPSC bounded queue of proposals ────────────────────────────────────
//
// Multiple producer threads (worker h2 threads in the shared-nothing
// model) can call `RaftNode.propose` concurrently; one consumer (the
// raft thread) drains via `pop`. The hot path needs to be correct
// under concurrent producers, not necessarily wait-free — proposes
// are rare relative to handler execution, and the queue reservation
// itself is a handful of instructions.
//
// The implementation is a classic "CAS-reserve a tail slot, write it,
// publish" MPSC ring. Producer semantics:
//
//   1. Load tail, load head. If the ring is full, return false.
//   2. CAS tail → tail+1 to reserve the slot. On failure, retry.
//   3. Write the slot's `len`, then its `framed` pointer.
//   4. Publish by storing `ready_to = tail+1` with release ordering.
//
// Consumer (raft thread) pops by checking `ready_to > head` — that's
// the only safe way to know whether the slot at `head` has been
// written fully. `head`/`tail` alone can't distinguish "slot reserved
// but not yet written" from "slot written and ready to read."
//
// This pattern wastes one index per push (head vs ready_to) but
// removes the single-producer race the earlier "MPSC" comment lied
// about. A mutex-protected push would also be correct; the CAS
// version matches what the comment always claimed.

const QUEUE_CAP: usize = 4096; // power of two

const Slot = struct {
    /// [8 byte seq BE][user payload], heap-allocated. Consumer takes
    /// ownership on pop. Size is encoded in `len` (below).
    framed: [*]u8,
    len: usize,
};

const ProposalQueue = struct {
    slots: [QUEUE_CAP]Slot,
    /// Next index the consumer will read from. Advanced only by the
    /// single consumer thread.
    head: std.atomic.Value(u64),
    /// Next index to reserve for writing. Producers CAS this to claim
    /// a slot, then publish by advancing `ready_to`.
    tail: std.atomic.Value(u64),
    /// Every index < `ready_to` has been fully written by its producer
    /// and is safe for the consumer to read. Producers advance this
    /// one index at a time, but only in order — a producer with slot
    /// `N` must spin until `ready_to == N` before publishing `N+1`.
    /// This enforces that slots become visible in reservation order,
    /// which is what the consumer's simple `head < ready_to` check
    /// depends on.
    ready_to: std.atomic.Value(u64),

    fn init(self: *ProposalQueue) void {
        for (&self.slots) |*s| s.* = .{ .framed = undefined, .len = 0 };
        self.head.store(0, .seq_cst);
        self.tail.store(0, .seq_cst);
        self.ready_to.store(0, .seq_cst);
    }

    fn push(self: *ProposalQueue, framed: []u8) bool {
        // Reserve a slot by CAS'ing tail forward. Multiple producers
        // race here; only one wins per iteration.
        var my_tail: u64 = undefined;
        while (true) {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t -% h >= QUEUE_CAP) return false;
            if (self.tail.cmpxchgWeak(t, t +% 1, .acq_rel, .monotonic)) |_| {
                // Lost the race; retry.
                continue;
            }
            my_tail = t;
            break;
        }

        // Write our slot. Only we own `my_tail` at this point.
        self.slots[my_tail & (QUEUE_CAP - 1)] = .{
            .framed = framed.ptr,
            .len = framed.len,
        };

        // Publish in reservation order. Another producer holding a
        // later slot must wait for us to advance `ready_to` first.
        // Spin on the CAS rather than blocking — the window is a few
        // instructions wide.
        while (self.ready_to.cmpxchgWeak(my_tail, my_tail +% 1, .release, .monotonic)) |_| {
            std.atomic.spinLoopHint();
        }
        return true;
    }

    pub fn pop(self: *ProposalQueue) ?[]u8 {
        const head = self.head.load(.monotonic);
        const ready = self.ready_to.load(.acquire);
        if (head == ready) return null;
        const slot = &self.slots[head & (QUEUE_CAP - 1)];
        const out = slot.framed[0..slot.len];
        slot.len = 0;
        self.head.store(head +% 1, .release);
        return out;
    }

    fn isEmpty(self: *const ProposalQueue) bool {
        return self.head.load(.acquire) == self.ready_to.load(.acquire);
    }
};

/// Length of the internal per-proposal prefix at position 0 of each queue
/// slot and drain_buf entry. The prefix holds the caller-supplied seq as
/// 8 BE bytes; the body follows. Flat-bytes layout (rather than a struct)
/// lets the queue pass around a single allocation per proposal.
pub const SEQ_PREFIX_LEN: usize = 8;

/// Max time `run()` will spend draining in-flight proposals during
/// graceful shutdown before force-faulting the remainder. Generous so
/// normal raft round-trips finish cleanly under healthy conditions.
const DRAIN_TIMEOUT_NS: i64 = 2 * std.time.ns_per_s;

// ── Membership change wire format ──────────────────────────────────────
//
// Membership entries are NOT wrapped in the batch envelope. willemt's
// `entry.type` field discriminates them from regular state-machine
// entries (RAFT_LOGTYPE_NORMAL). The payload is direct binary:
//
//   ADD_NODE: [4B node_id BE][4B IPv4 octets][2B port BE]   = 10 bytes
//   REMOVE_NODE: [4B node_id BE]                            =  4 bytes
//
// IPv4 only for the MVP; IPv6 is a future extension that would add an
// address-family discriminator. `log_get_node_id` parses the first 4
// bytes of either format to extract the affected node id, which is
// what willemt needs.

pub const MEMBERSHIP_ADD_PAYLOAD_LEN: usize = 10;
pub const MEMBERSHIP_REMOVE_PAYLOAD_LEN: usize = 4;

// ── Snapshot (delta catchup) protocol ──────────────────────────────────
//
// Message types (byte 0 of the payload):
//   6 = SNAP_OFFER  — leader → follower, "you need a snapshot; my meta is X"
//       Payload: [1B type][8B term][8B idx][8B snapshot_seq]
//   7 = SNAP_REQ    — follower → leader, "send me your delta from my_max_seq"
//       Payload: [1B type][8B my_max_seq]
//   8 = SNAP_DATA   — leader → follower, "here are the kv rows in (after, through]"
//       Payload: [1B type][8B term][8B idx][4B n_entries]
//                per row: [4B klen][key][4B vlen][value][8B seq]
//
// These messages share the same 4-byte length header as raft_rpc frames,
// but are handled inline in onPeerMessage before raft_rpc.decode is called.
// They are rove-kv's catchup protocol, not willemt RPCs.

const SNAP_OFFER_TYPE: u8 = @intFromEnum(raft_rpc.MsgType.snap_offer);
const SNAP_REQ_TYPE: u8 = @intFromEnum(raft_rpc.MsgType.snap_req);
const SNAP_DATA_TYPE: u8 = @intFromEnum(raft_rpc.MsgType.snap_data);

// ── RaftNode ───────────────────────────────────────────────────────────

pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    /// Peer transport. May be backed by a built-in RaftNet (default) or
    /// by a caller-supplied implementation via `initWithTransport`.
    transport: Transport,
    /// If non-null, the transport is a RaftNet we created in `init` and
    /// must destroy in `deinit`. Otherwise the caller owns the transport.
    owned_net: ?*raft_net_mod.RaftNet,
    config: Config,

    raft: *c.raft_server_t,

    /// Optional persistent backing. When non-null, log_offer writes every
    /// new entry here, log_pop/poll truncate, persist_{term,vote} save state.
    raft_log: ?*raft_log_mod.RaftLog,

    /// Set to true while replaying persisted entries into willemt during
    /// init(). While true, cbLogOffer skips the RaftLog.append call.
    replaying: bool,

    // ── Cross-thread shared atomics ──
    /// True when this node is currently leader.
    is_leader: std.atomic.Value(bool),
    /// Current leader node id, or -1 if unknown.
    leader_id: std.atomic.Value(i32),
    /// willemt's committed log index (raft-internal monotonic counter).
    committed_idx: std.atomic.Value(u64),
    /// Highest caller-supplied seq that has been committed to the raft log.
    /// Advances in cbApplyLog on both leader and followers.
    committed_seq: std.atomic.Value(u64),
    /// Highest caller-supplied seq ever submitted via propose(). Updated
    /// monotonically on each call.
    high_watermark: std.atomic.Value(u64),
    /// Non-zero when this node lost leadership with in-flight proposals.
    /// Set to high_watermark at the moment of the leader→follower
    /// transition. Workers whose seq is in (committed_seq, faulted_seq]
    /// must treat their proposal as lost and roll back.
    /// Cleared back to 0 when we become leader again.
    faulted_seq: std.atomic.Value(u64),

    /// Set by `requestStop`. The run-loop observes it each tick and exits
    /// the tick loop, then runs a bounded drain phase to flush in-flight
    /// proposals before returning. `propose` also observes it and returns
    /// `ShuttingDown`.
    stopping: std.atomic.Value(bool),

    /// Monotonic-ns timestamp of the most recent successful append_entries
    /// response from each peer. Used to compute leader lease validity in
    /// `isLeasedLeader`. Indexed by peer_id; entries for the self slot
    /// stay at 0 and are ignored. Initialized to 0; the lease is invalid
    /// until enough peers have acked at least one heartbeat.
    /// Heap-allocated; freed in `deinit`.
    peer_last_ack_ns: []std.atomic.Value(i64),

    queue: ProposalQueue,

    /// Per-worker watermarks published by `workerBegin/Committed/Idle`.
    /// Read by the raft thread (tick) via acquire; written by workers via
    /// release. A watermark of `WM_IDLE` means "don't gate on me."
    worker_watermark: [MAX_WORKERS]std.atomic.Value(u64),

    /// Proposals popped from the MPSC queue that haven't yet been submitted
    /// to willemt because their seq exceeds the current safe_seq. Owned
    /// `[8B seq][body]` allocations; freed on submit or on leadership loss.
    /// Raft-thread-only; no synchronization needed.
    drain_buf: std.ArrayList([]u8),

    /// `std.time.nanoTimestamp()` at the moment `drain_buf` first became
    /// non-empty in the current linger window. Used by
    /// `drainAndSubmitProposals` to decide whether `propose_linger_ns`
    /// has elapsed for the oldest pending proposal. 0 when `drain_buf`
    /// is empty; set on the tick that pulls the first item off the MPSC
    /// queue; cleared once the batch is fully submitted. Raft-thread-
    /// only; no synchronization needed.
    linger_start_ns: i128 = 0,

    /// Most recent WAL frame count reported by a passive checkpoint. Raft-
    /// thread-only; exposed via `walLogPages()` for observability. Zero
    /// until the first batch apply in kv-apply mode.
    last_wal_log_pages: u32,

    /// The committed_seq at the time of the last completed snapshot.
    /// Used as the `through_seq` upper bound when answering SNAP_REQ on
    /// the leader so deltas never mix pre- and post-snapshot rows.
    snapshot_seq: u64,

    /// Monotonic timestamp of the last periodic snapshot attempt. Used by
    /// `maybeSnapshot` to space attempts out.
    last_snapshot_attempt_ns: i64,

    /// Monotonic id minted for each `snap_fetch_offer` we send.
    /// Carried in the offer frame + the HTTP fetch path; primarily a
    /// debug/tracing correlator since the HTTP handler streams the
    /// current data_dir state regardless (getting newer state than the
    /// offer claimed is always safe for snapshot install). Not
    /// persisted — restarts reset to 0.
    next_snap_offer_id: std.atomic.Value(u64) = .{ .raw = 0 },

    last_tick_ns: i64,

    /// Default init: creates a built-in `RaftNet` transport bound to
    /// `cfg.listen_addr` with TCP peers from `cfg.peers`. RaftNode owns
    /// the RaftNet and tears it down in `deinit`.
    pub fn init(
        allocator: std.mem.Allocator,
        cfg: Config,
    ) !*RaftNode {
        if (cfg.worker_count > MAX_WORKERS) return error.OutOfMemory;

        const self = try allocator.create(RaftNode);
        errdefer allocator.destroy(self);

        const net = try raft_net_mod.RaftNet.init(allocator, .{
            .node_id = cfg.node_id,
            .peers = cfg.peers,
            .listen_addr = cfg.listen_addr,
            .on_recv = onPeerMessage,
            .user_ctx = self,
        });
        errdefer net.deinit();

        const transport = transportFromRaftNet(net);

        const raft_log: ?*raft_log_mod.RaftLog = if (cfg.raft_log_path) |path|
            try raft_log_mod.RaftLog.open(allocator, path)
        else
            null;
        errdefer if (raft_log) |rl| rl.close();

        const peer_last_ack = try allocator.alloc(std.atomic.Value(i64), cfg.peers.len);
        errdefer allocator.free(peer_last_ack);
        for (peer_last_ack) |*slot| slot.* = .init(0);

        const raft_ptr = c.raft_new() orelse return error.OutOfMemory;
        const raft = @as(*c.raft_server_t, @ptrCast(raft_ptr));
        errdefer c.raft_free(raft);

        self.* = .{
            .allocator = allocator,
            .transport = transport,
            .owned_net = net,
            .config = cfg,
            .raft = raft,
            .raft_log = raft_log,
            .replaying = false,
            .is_leader = .init(false),
            .leader_id = .init(-1),
            .committed_idx = .init(0),
            .committed_seq = .init(0),
            .high_watermark = .init(0),
            .faulted_seq = .init(0),
            .stopping = .init(false),
            .peer_last_ack_ns = peer_last_ack,
            .queue = undefined,
            .worker_watermark = undefined,
            .drain_buf = .empty,
            .last_wal_log_pages = 0,
            .snapshot_seq = 0,
            .last_snapshot_attempt_ns = 0,
            .last_tick_ns = 0,
        };
        self.queue.init();
        for (&self.worker_watermark) |*wm| wm.* = .init(WM_IDLE);

        // Wire willemt callbacks. udata = self.
        var cbs = std.mem.zeroes(c.raft_cbs_t);
        cbs.send_requestvote = callbacks.cbSendRequestVote;
        cbs.send_appendentries = callbacks.cbSendAppendEntries;
        cbs.send_snapshot = callbacks.cbSendSnapshot;
        cbs.applylog = callbacks.cbApplyLog;
        cbs.persist_vote = callbacks.cbPersistVote;
        cbs.persist_term = callbacks.cbPersistTerm;
        cbs.log_offer = callbacks.cbLogOffer;
        cbs.log_pop = callbacks.cbLogPop;
        cbs.log_poll = callbacks.cbLogPoll;
        cbs.log_clear = callbacks.cbLogClear;
        cbs.log_get_node_id = callbacks.cbLogGetNodeId;
        c.raft_set_callbacks(raft, &cbs, self);

        // Add nodes in id order. Index `node_id` is self.
        // Voters go through `raft_add_node`; learners (non-voting,
        // for read replicas + DR per docs/production.md #1.2) go
        // through `raft_add_non_voting_node`. willemt's quorum
        // math automatically excludes non-voting nodes from
        // election + commit thresholds.
        for (cfg.peers, 0..) |peer, i| {
            const is_self: c_int = if (i == cfg.node_id) 1 else 0;
            switch (peer.mode) {
                .voter => _ = c.raft_add_node(raft, null, @intCast(i), is_self),
                .learner => _ = c.raft_add_non_voting_node(raft, null, @intCast(i), is_self),
            }
        }

        c.raft_set_election_timeout(raft, @intCast(cfg.election_timeout_ms));
        c.raft_set_request_timeout(raft, @intCast(cfg.request_timeout_ms));

        // Restore persisted state, if any. Do this AFTER add_node + set
        // callbacks so willemt's internal structures are ready to accept
        // log_offer calls during replay.
        if (raft_log) |rl| try self.restoreFromLog(rl);
        // (No startup orphan sweep: kvexp has no kv_undo table. A
        // pre-quorum crash loses the speculative overlay entirely —
        // no on-disk divergence — and raft replay past
        // lastAppliedRaftIdx reconstructs the rest. The pre-kvexp
        // SQLite recoverOrphans path was removed.)

        return self;
    }

    fn restoreFromLog(self: *RaftNode, rl: *raft_log_mod.RaftLog) !void {
        // Restore term + vote.
        const state = try rl.loadState();
        if (state.term > 0) {
            _ = c.raft_set_current_term(self.raft, @intCast(state.term));
        }
        if (state.voted_for >= 0) {
            _ = c.raft_vote_for_nodeid(self.raft, state.voted_for);
        }

        // Replay log entries. cbLogOffer will be called for each one via
        // raft_append_entry; `replaying = true` suppresses the re-persist.
        const last = try rl.last();
        if (last.index == 0) return;

        self.replaying = true;
        defer self.replaying = false;

        var i: u64 = 1;
        while (i <= last.index) : (i += 1) {
            const e = rl.get(i) catch |err| switch (err) {
                error.NotFound => continue,
                else => return err,
            };
            // cbLogOffer will allocate and own its own copy; free the one
            // returned from RaftLog.get after raft_append_entry.
            defer self.allocator.free(e.data);

            var entry = std.mem.zeroes(c.raft_entry_t);
            entry.term = @intCast(e.term);
            entry.id = @intCast(i);
            entry.type = c.RAFT_LOGTYPE_NORMAL;
            entry.data.buf = @ptrCast(e.data.ptr);
            entry.data.len = @intCast(e.data.len);
            _ = c.raft_append_entry(self.raft, &entry);
        }
    }

    /// Transport-injected init: caller owns the transport and is
    /// responsible for calling `onRecvFrame(from_id, payload)` whenever
    /// an inbound raft frame arrives. Useful for non-TCP environments
    /// (Maelstrom, in-process test harnesses) where RaftNet's direct
    /// liburing model doesn't fit. `cfg.listen_addr` and `cfg.peers`
    /// are still used for bookkeeping (peer count for quorum math,
    /// node_id) but no sockets are opened.
    pub fn initWithTransport(
        allocator: std.mem.Allocator,
        cfg: Config,
        transport: Transport,
    ) !*RaftNode {
        if (cfg.worker_count > MAX_WORKERS) return error.OutOfMemory;

        const self = try allocator.create(RaftNode);
        errdefer allocator.destroy(self);

        const raft_log: ?*raft_log_mod.RaftLog = if (cfg.raft_log_path) |path|
            try raft_log_mod.RaftLog.open(allocator, path)
        else
            null;
        errdefer if (raft_log) |rl| rl.close();

        const peer_last_ack = try allocator.alloc(std.atomic.Value(i64), cfg.peers.len);
        errdefer allocator.free(peer_last_ack);
        for (peer_last_ack) |*slot| slot.* = .init(0);

        const raft_ptr = c.raft_new() orelse return error.OutOfMemory;
        const raft = @as(*c.raft_server_t, @ptrCast(raft_ptr));
        errdefer c.raft_free(raft);

        self.* = .{
            .allocator = allocator,
            .transport = transport,
            .owned_net = null,
            .config = cfg,
            .raft = raft,
            .raft_log = raft_log,
            .replaying = false,
            .is_leader = .init(false),
            .leader_id = .init(-1),
            .committed_idx = .init(0),
            .committed_seq = .init(0),
            .high_watermark = .init(0),
            .faulted_seq = .init(0),
            .stopping = .init(false),
            .peer_last_ack_ns = peer_last_ack,
            .queue = undefined,
            .worker_watermark = undefined,
            .drain_buf = .empty,
            .last_wal_log_pages = 0,
            .snapshot_seq = 0,
            .last_snapshot_attempt_ns = 0,
            .last_tick_ns = 0,
        };
        self.queue.init();
        for (&self.worker_watermark) |*wm| wm.* = .init(WM_IDLE);

        var cbs = std.mem.zeroes(c.raft_cbs_t);
        cbs.send_requestvote = callbacks.cbSendRequestVote;
        cbs.send_appendentries = callbacks.cbSendAppendEntries;
        cbs.send_snapshot = callbacks.cbSendSnapshot;
        cbs.applylog = callbacks.cbApplyLog;
        cbs.persist_vote = callbacks.cbPersistVote;
        cbs.persist_term = callbacks.cbPersistTerm;
        cbs.log_offer = callbacks.cbLogOffer;
        cbs.log_pop = callbacks.cbLogPop;
        cbs.log_poll = callbacks.cbLogPoll;
        cbs.log_clear = callbacks.cbLogClear;
        cbs.log_get_node_id = callbacks.cbLogGetNodeId;
        c.raft_set_callbacks(raft, &cbs, self);

        for (cfg.peers, 0..) |_, i| {
            const is_self: c_int = if (i == cfg.node_id) 1 else 0;
            _ = c.raft_add_node(raft, null, @intCast(i), is_self);
        }

        c.raft_set_election_timeout(raft, @intCast(cfg.election_timeout_ms));
        c.raft_set_request_timeout(raft, @intCast(cfg.request_timeout_ms));

        if (raft_log) |rl| try self.restoreFromLog(rl);

        return self;
    }

    /// Inject an inbound raft frame from a custom transport. The payload
    /// is the unframed bytes after any transport-level framing (type
    /// byte + fields, matching what `raft_rpc.decode` expects). Thread-
    /// affinity: must be called on the raft thread.
    pub fn onRecvFrame(self: *RaftNode, from_id: u32, payload: []const u8) void {
        onPeerMessage(from_id, payload, self);
    }

    pub fn deinit(self: *RaftNode) void {
        // Drain any unconsumed proposals.
        while (self.queue.pop()) |p| self.allocator.free(p);
        for (self.drain_buf.items) |p| self.allocator.free(p);
        self.drain_buf.deinit(self.allocator);
        // faulted_seq accounting isn't necessary on deinit — the process is
        // going away and there's nobody left to read it.

        // raft_free() calls log_free() which does NOT walk entries via the
        // log_clear callback — that only happens in raft_clear(). Call it
        // explicitly first so our cbLogClear fires and frees each copied
        // payload made in cbLogOffer.
        c.raft_clear(self.raft);
        c.raft_free(self.raft);
        if (self.raft_log) |rl| rl.close();
        if (self.owned_net) |net| net.deinit();
        const allocator = self.allocator;
        allocator.free(self.peer_last_ack_ns);
        allocator.destroy(self);
    }

    // ── Public API (cross-thread safe) ─────────────────────────────────

    pub fn isLeader(self: *RaftNode) bool {
        return self.is_leader.load(.acquire);
    }

    pub fn leaderId(self: *RaftNode) i32 {
        return self.leader_id.load(.acquire);
    }

    /// willemt's internal log index of the last committed entry.
    pub fn committedIndex(self: *RaftNode) u64 {
        return self.committed_idx.load(.acquire);
    }

    /// Highest caller-supplied seq that has been committed (visible on all
    /// nodes). Workers should consider their write durable when
    /// `committedSeq() >= my_seq`.
    pub fn committedSeq(self: *RaftNode) u64 {
        return self.committed_seq.load(.acquire);
    }

    /// Highest seq ever submitted via propose() on this node. Workers can
    /// read this at txn-start time to establish an "after seq" bound.
    pub fn highWatermark(self: *RaftNode) u64 {
        return self.high_watermark.load(.acquire);
    }

    /// willemt's current term. Caller-side snapshot orchestration
    /// records this in the manifest so a follower load can verify
    /// + reject term mismatches.
    pub fn currentTerm(self: *RaftNode) u64 {
        return @intCast(c.raft_get_current_term(self.raft));
    }

    /// Phase 5.5(c) — application-level snapshot lifecycle for
    /// `.opaque_bytes` apply mode. The caller is the orchestrator
    /// (loop46/snapshot.zig); these are thin wrappers over the
    /// willemt C API used to bracket the actual capture work so
    /// the on-disk raft log can be compacted past the snapshot's
    /// floor.
    ///
    /// Contract:
    ///   1. Caller calls `beginSnapshotOpaque()`. willemt records
    ///      `snapshot_last_idx = commit_idx_now`. Returns false if
    ///      a snapshot is already in progress or there's nothing
    ///      to snapshot.
    ///   2. Caller does the application-level capture work
    ///      (VACUUM INTO, upload, etc.) — must observe state ≤
    ///      `commit_idx_now`. On a single thread (the raft thread),
    ///      this is automatic: applies past now don't run while
    ///      this code is executing.
    ///   3. Caller calls `endSnapshotOpaque()`. willemt compacts
    ///      the on-disk log past `snapshot_last_idx`.
    ///
    /// Both calls MUST come from the same thread that owns the
    /// raft node (the willemt C API is not thread-safe).
    pub fn beginSnapshotOpaque(self: *RaftNode) bool {
        if (c.raft_snapshot_is_in_progress(self.raft) != 0) return false;
        const commit_idx = c.raft_get_commit_idx(self.raft);
        const snap_last = c.raft_get_snapshot_last_idx(self.raft);
        if (commit_idx <= snap_last) return false;
        return c.raft_begin_snapshot(self.raft, c.RAFT_SNAPSHOT_NONBLOCKING_APPLY) == 0;
    }

    pub fn endSnapshotOpaque(self: *RaftNode) void {
        _ = c.raft_end_snapshot(self.raft);
    }

    /// Release pages freed by the prior `endSnapshotOpaque` back to
    /// the filesystem. `endSnapshotOpaque` drives willemt's
    /// `raft_poll_entry` loop, which calls our `cbLogPoll` →
    /// `RaftLog.truncateBefore` → DELETE for each compacted entry.
    /// The DELETEs leave free pages on the freelist; this call runs
    /// `PRAGMA incremental_vacuum` to actually shrink `raft.log.db`.
    ///
    /// MUST be called from the raft thread (the only thread that owns
    /// the `RaftLog` connection). Returns silently when there's no
    /// raft log persistence (the in-memory test path).
    pub fn compactLogPages(self: *RaftNode) !void {
        const rl = self.raft_log orelse return;
        try rl.compactPages(0);
    }

    /// Live row count in `raft_log`. Used by smoke tests to verify
    /// compaction actually fired. Same threading rules as
    /// `compactLogPages`. Returns 0 when there's no raft-log
    /// persistence.
    pub fn raftLogRowCount(self: *RaftNode) !u64 {
        const rl = self.raft_log orelse return 0;
        return rl.rowCount();
    }

    /// willemt's view of the highest log index covered by the
    /// most recent snapshot. Useful for tests + the
    /// `send_snapshot` callback (step C) which compares against
    /// each follower's `next_idx`.
    pub fn snapshotLastIdx(self: *RaftNode) u64 {
        return @intCast(c.raft_get_snapshot_last_idx(self.raft));
    }

    /// willemt's view of the term of the most recent snapshot.
    /// Pairs with `snapshotLastIdx` when sending a `snap_fetch_offer`
    /// or calling `raft_load_snapshot` on the follower.
    pub fn snapshotLastTerm(self: *RaftNode) u64 {
        return @intCast(c.raft_get_snapshot_last_term(self.raft));
    }

    /// Mint a fresh `snap_id` for an outgoing snapshot fetch offer.
    /// Monotonic across this process lifetime; cheap atomic
    /// increment. Caller embeds this in the fetch_path it builds
    /// for `sendSnapshotFetchOffer` so the follower's GET correlates
    /// to a specific offer in the leader's logs.
    pub fn mintSnapId(self: *RaftNode) u64 {
        return self.next_snap_offer_id.fetchAdd(1, .monotonic) + 1;
    }

    /// Build and send a `snap_fetch_offer` frame to `peer_id`. The
    /// `snap_last_term` / `snap_last_idx` fields are pulled from
    /// willemt's current snapshot metadata at call time; the
    /// application supplies the `snap_id` (typically from
    /// `mintSnapId`) and the path component the peer should GET to
    /// stream the actual bytes. Fire-and-forget — transport.send
    /// errors are caught and logged.
    ///
    /// Runs on whatever thread the caller's `needs_snapshot`
    /// callback runs on (typically the raft thread, since
    /// `cbSendSnapshot` invokes that callback synchronously).
    pub fn sendSnapshotFetchOffer(
        self: *RaftNode,
        peer_id: u32,
        snap_id: u64,
        fetch_path: []const u8,
    ) !void {
        const frame = try raft_rpc.encodeSnapFetchOffer(self.allocator, .{
            .snap_last_term = self.snapshotLastTerm(),
            .snap_last_idx = self.snapshotLastIdx(),
            .snap_id = snap_id,
            .fetch_path = @constCast(fetch_path),
        });
        defer self.allocator.free(frame);
        try self.transport.send(peer_id, frame);
    }

    /// Tell willemt to treat the on-disk state as a snapshot at
    /// `(snap_last_term, snap_last_idx)`. Used at boot after the
    /// `installStagedSnapshotIfPresent` flow has atomic-renamed the
    /// fetched DBs into `data_dir` — willemt's log past `snap_last_idx`
    /// gets truncated; subsequent append_req frames from the leader
    /// land starting at `snap_last_idx + 1`.
    ///
    /// Skip when `snap_last_idx <= raft_get_snapshot_last_idx`: our
    /// state is already at or past the loaded snapshot, calling load
    /// would be a no-op or a downgrade.
    ///
    /// Wraps `raft_begin_load_snapshot` + `raft_end_load_snapshot`.
    pub fn loadSnapshot(self: *RaftNode, snap_last_idx: u64, snap_last_term: u64) !void {
        const current_idx: u64 = @intCast(c.raft_get_snapshot_last_idx(self.raft));
        if (snap_last_idx <= current_idx) {
            std.log.info(
                "raft: loadSnapshot skipped (snap_last_idx={d} <= current snapshot_last_idx={d}); on-disk state is already at or past the staged snapshot",
                .{ snap_last_idx, current_idx },
            );
            return;
        }
        if (c.raft_begin_load_snapshot(self.raft, @intCast(snap_last_term), @intCast(snap_last_idx)) != 0) {
            return error.RaftBeginLoadSnapshot;
        }
        if (c.raft_end_load_snapshot(self.raft) != 0) {
            return error.RaftEndLoadSnapshot;
        }
    }

    /// When non-zero, leadership was lost with in-flight proposals. Any
    /// worker whose seq is in (committedSeq, faultedSeq()] MUST treat its
    /// write as lost. Cleared back to 0 on the next successful election.
    pub fn faultedSeq(self: *RaftNode) u64 {
        return self.faulted_seq.load(.acquire);
    }

    /// Returns true if this node is currently the leader AND has received
    /// append_entries acknowledgements from a majority of peers within the
    /// lease window (`election_timeout_ms / 2`). When true, the caller can
    /// safely serve linearizable reads from this node's local state
    /// without a per-read RTT to confirm leadership.
    ///
    /// The lease window is half the election timeout, which gives a safety
    /// margin against clock skew and one-way network delay: if peers
    /// haven't heard from us in `election_timeout`, they'll start a new
    /// election; we step down if we haven't heard from a majority in
    /// `election_timeout/2`, so the windows can't overlap.
    ///
    /// Caller must pass a monotonic timestamp (e.g.
    /// `std.time.nanoTimestamp()`); thread-safe.
    pub fn isLeasedLeader(self: *const RaftNode, now_ns: i64) bool {
        if (!self.is_leader.load(.acquire)) return false;

        const lease_window_ns: i64 = @divTrunc(
            @as(i64, @intCast(self.config.election_timeout_ms)) * std.time.ns_per_ms,
            2,
        );
        const earliest_valid = now_ns - lease_window_ns;

        // Self always counts as one ack toward quorum.
        var ack_count: u32 = 1;
        for (self.peer_last_ack_ns, 0..) |*slot, i| {
            if (i == self.config.node_id) continue;
            const ts = slot.load(.acquire);
            if (ts > 0 and ts >= earliest_valid) ack_count += 1;
        }

        const quorum: u32 = @intCast((self.config.peers.len / 2) + 1);
        return ack_count >= quorum;
    }

    /// Frame count reported by the most recent passive WAL checkpoint (runs
    /// after each committed batch in kv-apply mode). Observability signal —
    /// if this number trends upward over time, a reader is blocking the
    /// WAL from fully draining. Raft-thread read only.
    pub fn walLogPages(self: *const RaftNode) u32 {
        return self.last_wal_log_pages;
    }

    // ── Graceful shutdown ──────────────────────────────────────────────
    //
    // Contract:
    //
    //   1. The CALLER is responsible for stopping new propose() calls
    //      before initiating shutdown. (Typically: flip a "draining" flag
    //      in the RPC layer so workers start returning "shutting down" to
    //      their clients.)
    //   2. Call `requestStop()` from any thread. This sets an atomic flag.
    //   3. If you're driving `run()` on its own thread, `run()` will
    //      observe the flag, exit its tick loop, and run a bounded drain
    //      phase that keeps ticking until in-flight proposals either
    //      commit or fault. `run()` then returns normally.
    //   4. Join the run thread.
    //   5. Call `deinit()` (frees raft, raft_log, net, etc.).

    /// Ask the node to stop. Thread-safe. Returns immediately; the actual
    /// shutdown happens in `run()` which the caller must be driving on a
    /// separate thread (or in a tight loop that observes `isStopping()`).
    pub fn requestStop(self: *RaftNode) void {
        self.stopping.store(true, .release);
    }

    pub fn isStopping(self: *const RaftNode) bool {
        return self.stopping.load(.acquire);
    }

    // ── Worker watermark API ───────────────────────────────────────────
    //
    // Workers call these from their own threads to signal their progress
    // to the raft thread. The raft thread computes `safe_seq = min(wm)`
    // each tick and only proposes entries with seq <= safe_seq. This
    // enforces the "writers publish in seq order" invariant shift-js
    // depends on for consistent follower state.

    /// Called at the start of a txn. Publishes the current high_watermark
    /// as the worker's conservative upper bound — nothing more than this
    /// can be safely proposed until the worker completes or goes idle.
    pub fn workerBegin(self: *RaftNode, worker_id: u32) void {
        if (worker_id >= MAX_WORKERS) return;
        const hw = self.high_watermark.load(.acquire);
        self.worker_watermark[worker_id].store(hw, .release);
    }

    /// Called after a worker's txn commits, with the seq it committed.
    /// The watermark shrinks to this exact seq, unblocking proposals with
    /// seq <= this value from being gated on this worker.
    pub fn workerCommitted(self: *RaftNode, worker_id: u32, seq: u64) void {
        if (worker_id >= MAX_WORKERS) return;
        self.worker_watermark[worker_id].store(seq, .release);
    }

    /// Called when a worker has no in-flight txn. Removes this worker from
    /// the safe_seq min entirely.
    pub fn workerIdle(self: *RaftNode, worker_id: u32) void {
        if (worker_id >= MAX_WORKERS) return;
        self.worker_watermark[worker_id].store(WM_IDLE, .release);
    }

    /// Current safe_seq (min over non-idle worker watermarks). `maxInt(u64)`
    /// if `worker_count == 0` or every worker is idle. Exposed mainly for
    /// tests.
    pub fn safeSeq(self: *const RaftNode) u64 {
        var min_wm: u64 = WM_IDLE;
        var i: u32 = 0;
        while (i < self.config.worker_count) : (i += 1) {
            const v = self.worker_watermark[i].load(.acquire);
            if (v < min_wm) min_wm = v;
        }
        return min_wm;
    }

    /// Propose a membership change adding a new VOTING node to the
    /// cluster. Leader-only. Builds a `RAFT_LOGTYPE_ADD_NODE` entry whose
    /// payload encodes the new node's id and IPv4 address.
    ///
    /// Bootstrap requirement (MVP): the new node MUST already be running
    /// with a config that includes itself + the existing cluster in its
    /// `peers` list. This function adds the node to the EXISTING cluster's
    /// view; the new node learns about the cluster via the normal raft
    /// catchup path (snapshot + log replay) once it appears as a peer.
    ///
    /// Only IPv4 addresses are supported in this format pass. Returns
    /// `error.InvalidPeerId` if the addr isn't IPv4.
    pub fn proposeAddNode(self: *RaftNode, node_id: u32, addr: PeerAddr) ProposeError!void {
        if (self.stopping.load(.acquire)) return ProposeError.ShuttingDown;
        if (!self.isLeader()) return ProposeError.NotLeader;

        var payload: [MEMBERSHIP_ADD_PAYLOAD_LEN]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], node_id, .big);

        // Parse host as IPv4 dotted-quad. We only support IPv4 in the
        // membership wire format right now.
        const parsed = std.net.Address.parseIp4(addr.host, addr.port) catch
            return ProposeError.OutOfMemory; // closest existing variant; TODO add InvalidAddress
        const native_in = parsed.in.sa.addr;
        const ip_bytes = std.mem.asBytes(&native_in);
        @memcpy(payload[4..8], ip_bytes);
        std.mem.writeInt(u16, payload[8..10], addr.port, .big);

        var entry = std.mem.zeroes(c.msg_entry_t);
        entry.type = c.RAFT_LOGTYPE_ADD_NODE;
        entry.id = @intCast(node_id); // willemt entry id; doesn't have to be unique but useful for tracing
        entry.data.buf = @ptrCast(&payload);
        entry.data.len = MEMBERSHIP_ADD_PAYLOAD_LEN;
        var resp = std.mem.zeroes(c.msg_entry_response_t);
        const rc = c.raft_recv_entry(self.raft, &entry, &resp);
        if (rc == c.RAFT_ERR_ONE_VOTING_CHANGE_ONLY) return ProposeError.QueueFull;
        if (rc != 0) return ProposeError.NotLeader;
    }

    /// Propose a membership change removing a voter from the cluster.
    /// Leader-only. The removed node is the operator's responsibility to
    /// shut down once the entry commits.
    pub fn proposeRemoveNode(self: *RaftNode, node_id: u32) ProposeError!void {
        if (self.stopping.load(.acquire)) return ProposeError.ShuttingDown;
        if (!self.isLeader()) return ProposeError.NotLeader;

        var payload: [MEMBERSHIP_REMOVE_PAYLOAD_LEN]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], node_id, .big);

        var entry = std.mem.zeroes(c.msg_entry_t);
        entry.type = c.RAFT_LOGTYPE_REMOVE_NODE;
        entry.id = @intCast(node_id);
        entry.data.buf = @ptrCast(&payload);
        entry.data.len = MEMBERSHIP_REMOVE_PAYLOAD_LEN;
        var resp = std.mem.zeroes(c.msg_entry_response_t);
        const rc = c.raft_recv_entry(self.raft, &entry, &resp);
        if (rc == c.RAFT_ERR_ONE_VOTING_CHANGE_ONLY) return ProposeError.QueueFull;
        if (rc != 0) return ProposeError.NotLeader;
    }

    /// Serialize `ws` and submit as a raft entry with `seq`. Convenience
    /// wrapper around `propose` for the kv-apply path. The write-set is
    /// encoded to a fresh owned buffer, then forwarded to propose; the
    /// caller retains `ws` and can deinit it as soon as this returns.
    pub fn proposeWriteSet(
        self: *RaftNode,
        seq: u64,
        ws: *const writeset.WriteSet,
    ) ProposeError!void {
        if (self.stopping.load(.acquire)) return ProposeError.ShuttingDown;
        if (!self.isLeader()) return ProposeError.NotLeader;
        const encoded = ws.encode(self.allocator) catch return ProposeError.OutOfMemory;
        defer self.allocator.free(encoded);
        return self.propose(seq, encoded);
    }

    /// Submit a payload to the raft log with caller-supplied `seq`. Safe to
    /// call from any thread. Fails immediately if this node isn't leader at
    /// submission time, or if the queue is full. Success means "queued"; the
    /// actual replication happens asynchronously. Poll `committedSeq()` to
    /// know when the proposal is durable, and `faultedSeq()` to detect
    /// leadership loss.
    pub fn propose(self: *RaftNode, seq: u64, payload: []const u8) ProposeError!void {
        if (self.stopping.load(.acquire)) return ProposeError.ShuttingDown;
        if (!self.isLeader()) return ProposeError.NotLeader;

        // Update high_watermark monotonically to max(old, seq).
        var old = self.high_watermark.load(.monotonic);
        while (seq > old) {
            if (self.high_watermark.cmpxchgWeak(old, seq, .release, .monotonic)) |actual| {
                old = actual;
            } else break;
        }

        // Frame as [8 byte seq BE][payload] so both leader and followers can
        // advance committed_seq in cbApplyLog without consulting any external
        // state.
        const framed = self.allocator.alloc(u8, SEQ_PREFIX_LEN + payload.len) catch return ProposeError.OutOfMemory;
        std.mem.writeInt(u64, framed[0..8], seq, .big);
        @memcpy(framed[SEQ_PREFIX_LEN..], payload);

        if (!self.queue.push(framed)) {
            self.allocator.free(framed);
            return ProposeError.QueueFull;
        }
    }

    // ── Tick loop (raft thread) ────────────────────────────────────────

    /// Drive one iteration. Call from the raft thread's main loop.
    pub fn tick(self: *RaftNode, now_ns: i64) !void {
        // Accumulate fractional milliseconds so sub-1ms ticks don't silently
        // stall willemt's election timer.
        if (self.last_tick_ns == 0) self.last_tick_ns = now_ns;
        const delta_ns = now_ns - self.last_tick_ns;
        const whole_ms: i64 = @divTrunc(delta_ns, std.time.ns_per_ms);
        self.last_tick_ns += whole_ms * std.time.ns_per_ms;
        const elapsed_ms: c_int = @intCast(whole_ms);

        // 1. raft_periodic: elections, heartbeats, applylog for newly
        //    committed entries.
        _ = c.raft_periodic(self.raft, elapsed_ms);
        self.refreshLeaderState();

        // 2. Drain proposal queue + submit eligible entries.
        if (self.isLeader()) {
            try batcher.drainAndSubmitProposals(self);
        } else {
            // We're not leader. Any proposals a racing caller pushed after
            // the transition are lost — free them so they don't leak. The
            // drain_buf was already cleared by refreshLeaderState on the
            // transition.
            while (self.queue.pop()) |framed| self.allocator.free(framed);
        }

        // 3. Pump networking. Inbound RPCs invoked synchronously by
        //    onPeerMessage update the willemt state machine.
        try self.transport.tick(now_ns);

        // 4. Periodic snapshot attempt (leader only, kv-apply mode only).
        if (self.isLeader() and self.config.apply == .kv) {
            snapshot.maybeSnapshot(self, now_ns);
        }
    }

    /// Loop until either `stop` becomes true OR `requestStop` has been
    /// called on this node. On exit, runs a bounded drain phase so any
    /// in-flight proposals get a chance to commit or fault before returning.
    ///
    /// Typical usage:
    ///     var t = try std.Thread.spawn(.{}, runInThread, .{node});
    ///     // ... application runs ...
    ///     node.requestStop();
    ///     t.join();
    ///     node.deinit();
    pub fn run(self: *RaftNode, stop: ?*std.atomic.Value(bool)) !void {
        while (true) {
            if (self.stopping.load(.acquire)) break;
            if (stop) |s| if (s.load(.acquire)) break;
            try self.tick(@intCast(std.time.nanoTimestamp()));
            // Yield briefly so an idle cluster doesn't peg a core.
            // Under load the 1ms floor is acceptable: proposals batch
            // across ticks, and the raft thread's per-tick fsync is
            // already amortized over the batch. For higher throughput,
            // use `propose_linger_ns` to accumulate larger batches.
            std.Thread.sleep(std.time.ns_per_ms);
        }

        // Drain phase: keep ticking so any proposals that were in-flight
        // when stop was requested get a last chance to commit. Stops when:
        //   - The proposal queue AND drain_buf are both empty, AND
        //   - committed_seq has caught up to high_watermark (everything
        //     submitted has been acknowledged by a majority), OR
        //   - The drain deadline has expired — in which case we force-fault
        //     the remainder so workers polling faulted_seq see the failure.
        try self.drainPending(DRAIN_TIMEOUT_NS);
    }

    /// Drain loop. Public so tests can drive it directly without a full
    /// run() thread.
    pub fn drainPending(self: *RaftNode, timeout_ns: i64) !void {
        const start = std.time.nanoTimestamp();
        while (true) {
            const elapsed = std.time.nanoTimestamp() - start;
            if (elapsed >= timeout_ns) break;

            const queue_empty = self.queue.isEmpty();
            const drain_empty = self.drain_buf.items.len == 0;
            const hw = self.high_watermark.load(.acquire);
            const cs = self.committed_seq.load(.acquire);
            if (queue_empty and drain_empty and hw == cs) return;

            try self.tick(@intCast(std.time.nanoTimestamp()));
            std.Thread.sleep(std.time.ns_per_ms);
        }

        // Timeout exceeded. Anything still unsubmitted won't commit;
        // fault it so workers see a clean failure.
        const hw = self.high_watermark.load(.acquire);
        if (hw > self.committed_seq.load(.acquire)) {
            self.faulted_seq.store(hw, .release);
        }
        while (self.queue.pop()) |framed| self.allocator.free(framed);
        for (self.drain_buf.items) |framed| self.allocator.free(framed);
        self.drain_buf.clearRetainingCapacity();
    }


    fn refreshLeaderState(self: *RaftNode) void {
        const was_leader = self.is_leader.load(.monotonic);
        const now_leader = c.raft_is_leader(self.raft) != 0;
        self.is_leader.store(now_leader, .release);
        const lid = c.raft_get_current_leader(self.raft);
        self.leader_id.store(@intCast(lid), .release);
        const cidx = c.raft_get_commit_idx(self.raft);
        self.committed_idx.store(@intCast(cidx), .release);

        // Leadership transitions.
        if (was_leader and !now_leader) {
            // Lost leadership. Fault every in-flight seq: anything workers
            // pushed past the current committed_seq is no longer guaranteed
            // to land. Setting faulted_seq to high_watermark is monotonically
            // safe — it only admits more proposals to the "faulted" range.
            const hw = self.high_watermark.load(.acquire);
            self.faulted_seq.store(hw, .release);
            // Drop any queued (unsubmitted) proposals: they never reached
            // raft_recv_entry so they have no chance of committing, even on
            // the next leader.
            while (self.queue.pop()) |framed| self.allocator.free(framed);
            for (self.drain_buf.items) |framed| self.allocator.free(framed);
            self.drain_buf.clearRetainingCapacity();
        } else if (!was_leader and now_leader) {
            // We're healthy again. Clear the fault.
            self.faulted_seq.store(0, .release);
        }
    }

    /// Force a snapshot attempt right now, regardless of the periodic
    /// timer. Public method preserved on the struct so existing
    /// `node.triggerSnapshot()` call sites keep working; the body
    /// lives in `raft_snapshot.zig`.
    pub fn triggerSnapshot(self: *RaftNode) void {
        snapshot.triggerSnapshot(self);
    }
};


// ── Network recv → willemt dispatch ────────────────────────────────────

fn onPeerMessage(from_id: u32, payload: []const u8, ctx: ?*anyopaque) void {
    const self: *RaftNode = @ptrCast(@alignCast(ctx.?));
    const r = self.raft;

    // Snapshot messages are rove-kv's own catchup protocol. Handle them
    // inline BEFORE invoking willemt or raft_rpc.decode.
    if (payload.len >= 1) {
        switch (payload[0]) {
            SNAP_OFFER_TYPE => {
                snapshot.handleSnapOffer(self, from_id, payload[1..]);
                return;
            },
            SNAP_REQ_TYPE => {
                snapshot.handleSnapReq(self, from_id, payload[1..]);
                return;
            },
            SNAP_DATA_TYPE => {
                snapshot.handleSnapData(self, payload[1..]);
                return;
            },
            else => {},
        }
    }

    const node = c.raft_get_node(r, @intCast(from_id)) orelse return;

    var msg = raft_rpc.decode(self.allocator, payload) catch return;
    defer msg.deinit(self.allocator);

    switch (msg) {
        .vote_req => |vr| {
            var resp = std.mem.zeroes(c.msg_requestvote_response_t);
            var msg_in = c.msg_requestvote_t{
                .term = @intCast(vr.term),
                .candidate_id = @intCast(vr.candidate_id),
                .last_log_idx = @intCast(vr.last_log_idx),
                .last_log_term = @intCast(vr.last_log_term),
            };
            _ = c.raft_recv_requestvote(r, node, &msg_in, &resp);
            const out = raft_rpc.encodeVoteResp(self.allocator, .{
                .term = @intCast(resp.term),
                .vote_granted = @intCast(resp.vote_granted),
            }) catch return;
            defer self.allocator.free(out);
            self.transport.send(from_id, out) catch {};
        },
        .vote_resp => |vr| {
            var resp = c.msg_requestvote_response_t{
                .term = @intCast(vr.term),
                .vote_granted = @intCast(vr.vote_granted),
            };
            _ = c.raft_recv_requestvote_response(r, node, &resp);
        },
        .append_req => |ar| {
            // Translate decoded entries → willemt msg_entry_t array on a
            // small stack buffer (most batches are tiny).
            var entries_buf: [16]c.msg_entry_t = undefined;
            const n = ar.entries.len;
            var entries_ptr: [*c]c.msg_entry_t = null;
            var entries_heap: ?[]c.msg_entry_t = null;
            defer if (entries_heap) |h| self.allocator.free(h);

            if (n > 0) {
                if (n <= entries_buf.len) {
                    entries_ptr = &entries_buf[0];
                } else {
                    const h = self.allocator.alloc(c.msg_entry_t, n) catch return;
                    entries_heap = h;
                    entries_ptr = h.ptr;
                }
                for (ar.entries, 0..) |e, i| {
                    var dst = std.mem.zeroes(c.msg_entry_t);
                    dst.term = @intCast(e.term);
                    dst.id = @intCast(e.id);
                    dst.type = @intCast(e.type);
                    dst.data.buf = @ptrCast(e.data.ptr);
                    dst.data.len = @intCast(e.data.len);
                    entries_ptr[i] = dst;
                }
            }

            var msg_in = std.mem.zeroes(c.msg_appendentries_t);
            msg_in.term = @intCast(ar.term);
            msg_in.prev_log_idx = @intCast(ar.prev_log_idx);
            msg_in.prev_log_term = @intCast(ar.prev_log_term);
            msg_in.leader_commit = @intCast(ar.leader_commit);
            msg_in.n_entries = @intCast(n);
            msg_in.entries = entries_ptr;

            var resp = std.mem.zeroes(c.msg_appendentries_response_t);
            _ = c.raft_recv_appendentries(r, node, &msg_in, &resp);

            const out = raft_rpc.encodeAppendResp(self.allocator, .{
                .term = @intCast(resp.term),
                .success = @intCast(resp.success),
                .current_idx = @intCast(resp.current_idx),
                .first_idx = @intCast(resp.first_idx),
            }) catch return;
            defer self.allocator.free(out);
            self.transport.send(from_id, out) catch {};
        },
        .append_resp => |ar| {
            var resp = std.mem.zeroes(c.msg_appendentries_response_t);
            resp.term = @intCast(ar.term);
            resp.success = @intCast(ar.success);
            resp.current_idx = @intCast(ar.current_idx);
            resp.first_idx = @intCast(ar.first_idx);
            _ = c.raft_recv_appendentries_response(r, node, &resp);

            // Record this peer's liveness for the leader lease. We treat
            // any append_entries response — successful or not — as proof
            // the peer is still talking to us, which is what the lease
            // cares about. (A failure response means our log is ahead of
            // theirs, but they're alive and reachable.)
            if (from_id < self.peer_last_ack_ns.len) {
                const now: i64 = @intCast(std.time.nanoTimestamp());
                self.peer_last_ack_ns[from_id].store(now, .release);
            }
        },
        .ident, .snap_offer, .snap_req, .snap_data => {},
        .snap_fetch_offer => |offer| {
            // Out-of-band snapshot fetch offer (production.md #1.1 step
            // 3). Hand off to the application layer's
            // `on_snap_fetch_offer` callback if wired; the application
            // is responsible for issuing the HTTP GET against the
            // leader's `fetch_path`, staging the bytes, and ultimately
            // calling `raft_load_snapshot`. With no callback wired we
            // log + drop — same lossy behavior as the .opaque_bytes
            // send-side default.
            if (self.config.on_snap_fetch_offer) |cb| {
                cb(
                    self.config.on_snap_fetch_offer_ctx,
                    self,
                    from_id,
                    offer.snap_last_term,
                    offer.snap_last_idx,
                    offer.snap_id,
                    offer.fetch_path,
                );
            } else {
                std.log.warn(
                    "raft: received snap_fetch_offer from peer {d} (snap_id={x} idx={d}) but no on_snap_fetch_offer callback wired",
                    .{ from_id, offer.snap_id, offer.snap_last_idx },
                );
            }
        },
    }

    self.refreshLeaderState();
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const ApplyCapture = struct {
    mu: std.Thread.Mutex = .{},
    entries: std.ArrayList(struct { idx: u64, payload: []u8 }) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *ApplyCapture) void {
        for (self.entries.items) |e| self.allocator.free(e.payload);
        self.entries.deinit(self.allocator);
    }
};

fn captureApply(idx: u64, payload: []const u8, ctx: ?*anyopaque) void {
    const cap: *ApplyCapture = @ptrCast(@alignCast(ctx.?));
    cap.mu.lock();
    defer cap.mu.unlock();
    const copy = cap.allocator.alloc(u8, payload.len) catch return;
    @memcpy(copy, payload);
    cap.entries.append(cap.allocator, .{ .idx = idx, .payload = copy }) catch {
        cap.allocator.free(copy);
    };
}

fn tmpPath(buf: *[96]u8, tag: []const u8) [:0]const u8 {
    const ts = std.time.nanoTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(ts)));
    return std.fmt.bufPrintZ(buf, "/tmp/rove-raftnode-{s}-{x}.db", .{ tag, seed }) catch unreachable;
}

fn cleanupDb(path: [:0]const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var wal_buf: [128]u8 = undefined;
    var shm_buf: [128]u8 = undefined;
    const wal = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path}) catch return;
    const shm = std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path}) catch return;
    std.fs.cwd().deleteFile(wal) catch {};
    std.fs.cwd().deleteFile(shm) catch {};
}

test "ProposalQueue: single-producer single-consumer round trip" {
    var q: ProposalQueue = undefined;
    q.init();

    var buf_a = [_]u8{'a'} ** 16;
    var buf_b = [_]u8{'b'} ** 16;

    try testing.expect(q.isEmpty());
    try testing.expect(q.push(&buf_a));
    try testing.expect(q.push(&buf_b));
    try testing.expect(!q.isEmpty());

    const p1 = q.pop().?;
    try testing.expectEqual(@as(usize, 16), p1.len);
    try testing.expectEqual(@as(u8, 'a'), p1[0]);

    const p2 = q.pop().?;
    try testing.expectEqual(@as(u8, 'b'), p2[0]);
    try testing.expect(q.pop() == null);
    try testing.expect(q.isEmpty());
}

test "ProposalQueue: capacity bound is enforced" {
    const allocator = testing.allocator;
    var q: ProposalQueue = undefined;
    q.init();

    // Allocate a distinct 1-byte buffer per slot so we can verify
    // every push wrote the correct pointer when we drain.
    const bufs = try allocator.alloc([]u8, QUEUE_CAP);
    defer {
        for (bufs) |b| allocator.free(b);
        allocator.free(bufs);
    }
    for (bufs, 0..) |*b, i| {
        b.* = try allocator.alloc(u8, 1);
        b.*[0] = @intCast(i & 0xff);
    }

    for (bufs) |b| try testing.expect(q.push(b));

    // Queue is full — one more push must fail, not corrupt.
    var overflow = [_]u8{0xff};
    try testing.expect(!q.push(&overflow));

    // Drain and verify every slot came back intact in order.
    var i: usize = 0;
    while (q.pop()) |out| : (i += 1) {
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectEqual(@as(u8, @intCast(i & 0xff)), out[0]);
    }
    try testing.expectEqual(QUEUE_CAP, i);
}

test "ProposalQueue: concurrent producers, single consumer" {
    // Stress-test the MPSC path. Without this, the old single-
    // producer-only push races silently under concurrent callers:
    // two producers could read the same tail, write the same slot,
    // and lose one writeset entirely. The test is precise — every
    // push that returns `true` must appear exactly once on the
    // consumer side, with its original byte pattern.

    const allocator = testing.allocator;
    const producer_count: usize = 4;
    const per_producer: usize = 256;
    const total: usize = producer_count * per_producer;

    const queue = try allocator.create(ProposalQueue);
    defer allocator.destroy(queue);
    queue.init();

    // Pre-allocate all buffers. Each slot carries its producer id in
    // the high byte and its per-producer index in the next 3 bytes,
    // so we can reconstruct who produced what.
    const bufs = try allocator.alloc([]u8, total);
    defer {
        for (bufs) |b| allocator.free(b);
        allocator.free(bufs);
    }
    for (bufs, 0..) |*b, i| {
        b.* = try allocator.alloc(u8, 4);
        b.*[0] = @intCast((i / per_producer) & 0xff); // producer id
        std.mem.writeInt(u32, b.*[0..4], @intCast(i), .big);
    }

    const ProducerCtx = struct {
        q: *ProposalQueue,
        bufs: [][]u8,
        start: usize,
        count: usize,
        pushed: std.atomic.Value(usize) = .{ .raw = 0 },

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < self.count) {
                if (self.q.push(self.bufs[self.start + i])) {
                    _ = self.pushed.fetchAdd(1, .monotonic);
                    i += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const producers = try allocator.alloc(ProducerCtx, producer_count);
    defer allocator.free(producers);
    for (producers, 0..) |*p, i| {
        p.* = .{
            .q = queue,
            .bufs = bufs,
            .start = i * per_producer,
            .count = per_producer,
        };
    }

    const threads = try allocator.alloc(std.Thread, producer_count);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ProducerCtx.run, .{&producers[i]});
    }

    // Drain on the main thread (the "consumer") while producers push.
    // Track every unique buffer ptr we see so we can verify each was
    // delivered exactly once with its original content.
    var seen = try allocator.alloc(bool, total);
    defer allocator.free(seen);
    @memset(seen, false);

    var drained: usize = 0;
    while (drained < total) {
        if (queue.pop()) |out| {
            try testing.expectEqual(@as(usize, 4), out.len);
            const id = std.mem.readInt(u32, out[0..4], .big);
            try testing.expect(id < total);
            try testing.expectEqual(false, seen[id]);
            seen[id] = true;
            drained += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }

    for (threads) |t| t.join();

    // Every buffer must have been delivered exactly once.
    for (seen) |s| try testing.expect(s);
    try testing.expect(queue.pop() == null);
}

test "raft_log replay across restart rehydrates log + state" {
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const raft_path = tmpPath(&path_buf, "replay");
    defer cleanupDb(raft_path);

    // Pre-populate a RaftLog with some state and entries, as if a previous
    // process had written them.
    {
        const rl = try raft_log_mod.RaftLog.open(allocator, raft_path);
        defer rl.close();

        try rl.saveState(5, 2);
        try rl.append(1, 5, "entry-one");
        try rl.append(2, 5, "entry-two");
        try rl.append(3, 5, "entry-three");
    }

    // Spin up a single-node cluster with persistence pointed at that log.
    // Single-node never elects (needs 2 of 2 voting nodes for quorum here —
    // it's actually a 1-node cluster which wins its own vote), but we don't
    // care: we just want to verify the log got loaded into willemt.
    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39320 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39320),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 200,
        .request_timeout_ms = 50,
        .raft_log_path = raft_path,
    });
    defer node.deinit();

    // willemt should know about all 3 entries now.
    try testing.expectEqual(@as(c.raft_index_t, 3), c.raft_get_current_idx(node.raft));
    try testing.expectEqual(@as(c.raft_term_t, 5), c.raft_get_current_term(node.raft));
}

test "persist_term through leadership change survives restart" {
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const raft_path = tmpPath(&path_buf, "persist");
    defer cleanupDb(raft_path);

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39321 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    // First run: bump the term and shut down.
    {
        const node = try RaftNode.init(allocator, .{
            .node_id = 0,
            .peers = &peers,
            .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39321),
            .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
            .raft_log_path = raft_path,
        });
        defer node.deinit();

        // raft_set_current_term fires persist_term synchronously.
        _ = c.raft_set_current_term(node.raft, 42);
    }

    // Second run should see term=42 and voted_for=-1.
    {
        const node = try RaftNode.init(allocator, .{
            .node_id = 0,
            .peers = &peers,
            .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39321),
            .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
            .raft_log_path = raft_path,
        });
        defer node.deinit();

        try testing.expectEqual(@as(c.raft_term_t, 42), c.raft_get_current_term(node.raft));
    }
}

test "3-node cluster elects leader and replicates one entry" {
    const allocator = testing.allocator;

    const port_base: u16 = 39310;
    const peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = port_base + 0 },
        .{ .host = "127.0.0.1", .port = port_base + 1 },
        .{ .host = "127.0.0.1", .port = port_base + 2 },
    };

    var caps: [3]ApplyCapture = undefined;
    for (&caps) |*cap| cap.* = .{ .allocator = allocator };
    defer for (&caps) |*cap| cap.deinit();

    var nodes: [3]*RaftNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = try RaftNode.init(allocator, .{
            .node_id = @intCast(i),
            .peers = &peers,
            .listen_addr = try std.net.Address.parseIp("127.0.0.1", port_base + @as(u16, @intCast(i))),
            .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &caps[i] } },
            .election_timeout_ms = 200,
            .request_timeout_ms = 50,
        });
    }
    defer for (nodes) |n| n.deinit();

    const deadline_ns: i128 = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    var proposed = false;
    while (std.time.nanoTimestamp() < deadline_ns) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        for (nodes) |n| try n.tick(now);

        // Once a leader exists, propose an entry through it.
        if (!proposed) {
            for (nodes) |n| {
                if (n.isLeader()) {
                    n.propose(1, "hello world") catch break;
                    proposed = true;
                    break;
                }
            }
        }

        if (proposed) {
            var all_have: bool = true;
            for (&caps) |*cap| {
                cap.mu.lock();
                const n_ent = cap.entries.items.len;
                cap.mu.unlock();
                if (n_ent < 1) {
                    all_have = false;
                    break;
                }
            }
            if (all_have) break;
        }
    }

    try testing.expect(proposed);

    for (&caps) |*cap| {
        cap.mu.lock();
        defer cap.mu.unlock();
        try testing.expect(cap.entries.items.len >= 1);
        try testing.expectEqualStrings("hello world", cap.entries.items[0].payload);
    }

    // committed_seq should have advanced to 1 on every node (leader +
    // followers alike). Also verify nothing is faulted.
    for (nodes) |n| {
        try testing.expectEqual(@as(u64, 1), n.committedSeq());
        try testing.expectEqual(@as(u64, 0), n.faultedSeq());
    }
}

test "3-node cluster replicates a WriteSet to every follower's KvStore" {
    const allocator = testing.allocator;

    const port_base: u16 = 39340;
    const peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = port_base + 0 },
        .{ .host = "127.0.0.1", .port = port_base + 1 },
        .{ .host = "127.0.0.1", .port = port_base + 2 },
    };

    // Each node owns its own KvStore at a unique temp path.
    var kv_paths: [3][:0]const u8 = undefined;
    var kv_path_bufs: [3][96]u8 = undefined;
    var kvs: [3]*kvstore_mod.KvStore = undefined;
    for (&kv_paths, 0..) |*p, i| {
        var tag_buf: [16]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "kv-apply-{d}", .{i}) catch unreachable;
        p.* = tmpPath(&kv_path_bufs[i], tag);
        kvs[i] = try kvstore_mod.KvStore.open(allocator, p.*);
    }
    defer for (kvs) |kv| kv.close();
    defer for (kv_paths) |p| cleanupDb(p);

    var nodes: [3]*RaftNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = try RaftNode.init(allocator, .{
            .node_id = @intCast(i),
            .peers = &peers,
            .listen_addr = try std.net.Address.parseIp("127.0.0.1", port_base + @as(u16, @intCast(i))),
            .apply = .{ .kv = .{ .store = kvs[i] } },
            .election_timeout_ms = 200,
            .request_timeout_ms = 50,
        });
    }
    defer for (nodes) |n| n.deinit();

    const deadline_ns: i128 = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;

    // Phase 1: wait for a leader to exist.
    var leader_idx: ?usize = null;
    while (std.time.nanoTimestamp() < deadline_ns) {
        for (nodes) |n| try n.tick(@intCast(std.time.nanoTimestamp()));
        for (nodes, 0..) |n, i| {
            if (n.isLeader()) {
                leader_idx = i;
                break;
            }
        }
        if (leader_idx != null) break;
    }
    try testing.expect(leader_idx != null);
    const leader = nodes[leader_idx.?];
    const leader_kv = kvs[leader_idx.?];

    // Phase 2: workers write to local KV first (this is the shift-js
    // contract), then submit the write-set via raft.
    try leader_kv.begin();
    const seq = leader_kv.nextSeq();
    try leader_kv.putSeq("alpha", "one", seq);
    try leader_kv.putSeq("bravo", "two", seq);
    try leader_kv.commit();

    var ws = writeset.WriteSet.init(allocator);
    defer ws.deinit();
    try ws.addPut("alpha", "one");
    try ws.addPut("bravo", "two");

    try leader.proposeWriteSet(seq, &ws);

    // Phase 3: tick until every node's committed_seq reaches our seq.
    while (std.time.nanoTimestamp() < deadline_ns) {
        for (nodes) |n| try n.tick(@intCast(std.time.nanoTimestamp()));
        var all: bool = true;
        for (nodes) |n| {
            if (n.committedSeq() < seq) {
                all = false;
                break;
            }
        }
        if (all) break;
    }
    for (nodes) |n| {
        try testing.expect(n.committedSeq() >= seq);
    }

    // Phase 4: every KvStore should have both keys. The leader's KV was
    // populated manually; followers should have been populated by
    // cbApplyLog via writeset.applyEncoded.
    for (kvs) |kv| {
        const a = try kv.get("alpha");
        defer allocator.free(a);
        try testing.expectEqualStrings("one", a);

        const b = try kv.get("bravo");
        defer allocator.free(b);
        try testing.expectEqualStrings("two", b);

        // Pre-cutover: also asserted `kv.maxSeq() == seq` to confirm
        // followers stamped the seq column. Under kvexp there's no
        // persistent per-row seq; behavioral key-state assertions
        // above carry the replication invariant.
    }
}

test "multiple proposals in one tick collapse into one raft entry" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39370 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39370),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Wait for leadership.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    const idx_before = c.raft_get_current_idx(node.raft);

    // Propose 5 entries in one burst — all queued before the next tick.
    try node.propose(1, "one");
    try node.propose(2, "two");
    try node.propose(3, "three");
    try node.propose(4, "four");
    try node.propose(5, "five");

    // One tick should drain all 5 into a single batch → one new raft entry.
    try node.tick(@intCast(std.time.nanoTimestamp()));

    // Let commit + apply happen.
    const commit_deadline: i128 = std.time.nanoTimestamp() + 500 * std.time.ns_per_ms;
    while (std.time.nanoTimestamp() < commit_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.committedSeq() >= 5) break;
    }

    const idx_after = c.raft_get_current_idx(node.raft);
    // Exactly ONE new raft entry should have been appended for all 5 proposals.
    try testing.expectEqual(@as(c.raft_index_t, idx_before + 1), idx_after);
    try testing.expectEqual(@as(u64, 5), node.committedSeq());

    // And apply_fn should have been called 5 times with the individual
    // payloads.
    cap.mu.lock();
    defer cap.mu.unlock();
    try testing.expectEqual(@as(usize, 5), cap.entries.items.len);
    try testing.expectEqualStrings("one", cap.entries.items[0].payload);
    try testing.expectEqualStrings("five", cap.entries.items[4].payload);
}

test "triggerSnapshot compacts the leader's raft log" {
    const allocator = testing.allocator;

    var kv_path_buf: [96]u8 = undefined;
    const kv_path = tmpPath(&kv_path_buf, "snap-leader");
    defer cleanupDb(kv_path);

    const kv = try kvstore_mod.KvStore.open(allocator, kv_path);
    defer kv.close();

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39360 }};
    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39360),
        .apply = .{ .kv = .{ .store = kv } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Wait for leadership.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Propose 5 write-sets, ticking between each so they land as separate
    // raft log entries instead of one batch. willemt's raft_begin_snapshot
    // refuses when log_count <= 1, so we need at least two entries.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try kv.begin();
        const seq = kv.nextSeq();
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch unreachable;
        var val_buf: [16]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "v{d}", .{i}) catch unreachable;
        try kv.putSeq(key, val, seq);
        try kv.commit();

        var ws = writeset.WriteSet.init(allocator);
        defer ws.deinit();
        try ws.addPut(key, val);
        try node.proposeWriteSet(seq, &ws);

        // Tick until THIS specific seq is committed before moving to the
        // next propose — guarantees one raft entry per write-set.
        const per_deadline: i128 = std.time.nanoTimestamp() + 500 * std.time.ns_per_ms;
        while (std.time.nanoTimestamp() < per_deadline) {
            try node.tick(@intCast(std.time.nanoTimestamp()));
            if (node.committedSeq() >= seq) break;
        }
    }

    try testing.expectEqual(@as(u64, 5), node.committedSeq());

    const pre_snap_last = c.raft_get_snapshot_last_idx(node.raft);
    const pre_log_count = c.raft_get_log_count(node.raft);
    // We ticked between each propose to force 5 separate raft entries so
    // willemt has something to compact (it refuses to snapshot when
    // log_count <= 1).
    try testing.expect(pre_log_count >= 2);

    // Force a snapshot.
    node.triggerSnapshot();

    // After the snapshot, last_snapshot_idx should have advanced to the
    // current commit idx, the internal log count should have shrunk, and
    // snapshot_seq should hold the committed seq we recorded.
    const post_snap_last = c.raft_get_snapshot_last_idx(node.raft);
    const post_log_count = c.raft_get_log_count(node.raft);
    try testing.expect(post_snap_last > pre_snap_last);
    try testing.expect(post_log_count < pre_log_count);
    try testing.expectEqual(@as(u64, 5), node.snapshot_seq);
}

test "safe_seq gates proposals until workers publish progress" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39350 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39350),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
        .worker_count = 2,
    });
    defer node.deinit();

    // Tick until leader.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Both workers idle → safe_seq is maxInt(u64), no gating.
    try testing.expectEqual(@as(u64, WM_IDLE), node.safeSeq());

    // Worker 0 begins a txn. workerBegin publishes the current high_watermark
    // (which is 0 — nothing has been proposed yet). That means safe_seq = 0,
    // so ANY proposal with seq >= 1 is gated behind worker 0.
    node.workerBegin(0);
    try testing.expectEqual(@as(u64, 0), node.safeSeq());

    // Now propose seq=5 — should go into drain_buf, NOT get submitted.
    try node.propose(5, "five");
    // Tick once to move it from MPSC → drain_buf. safe_seq is still 0 so
    // nothing should be submitted.
    try node.tick(@intCast(std.time.nanoTimestamp()));
    try testing.expectEqual(@as(usize, 1), node.drain_buf.items.len);
    try testing.expect(node.committedSeq() < 5);

    // Worker 0 commits at seq 5. safe_seq becomes 5.
    node.workerCommitted(0, 5);
    try testing.expectEqual(@as(u64, 5), node.safeSeq());

    // Next tick drains drain_buf and submits the entry. committed_seq
    // should advance.
    const commit_deadline: i128 = std.time.nanoTimestamp() + 1 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < commit_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.committedSeq() >= 5) break;
    }
    try testing.expectEqual(@as(u64, 5), node.committedSeq());
    try testing.expectEqual(@as(usize, 0), node.drain_buf.items.len);

    // Clean up: mark workers idle so teardown doesn't leak anything.
    node.workerIdle(0);
    node.workerIdle(1);
}

test "membership: proposeAddNode adds a peer to the local view" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39400 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39400),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Wait for leadership.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Initially, only ourselves (peer 0) is configured.
    try testing.expect(node.transport.isPeerConfigured(0));
    try testing.expect(!node.transport.isPeerConfigured(1));

    // Propose adding peer 1. willemt's offer-time handling adds the new
    // node to its internal table and our cbLogOffer mirrors it into
    // RaftNet — both immediately, before the entry commits. (The entry
    // CAN'T commit in a single-node cluster after we add a peer, because
    // quorum becomes 2 and the new peer doesn't actually exist yet. But
    // the local view is updated synchronously inside proposeAddNode.)
    try node.proposeAddNode(1, .{ .host = "127.0.0.1", .port = 39499 });

    try testing.expect(node.transport.isPeerConfigured(1));
    try testing.expectEqual(@as(c_int, 2), c.raft_get_num_nodes(node.raft));
}

test "membership: proposeRemoveNode drops a peer from the local view" {
    const allocator = testing.allocator;

    // Start with 2 peers in config so we have a peer to remove. Single
    // node will run as leader because peer 1 doesn't actually exist.
    const peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = 39401 },
        .{ .host = "127.0.0.1", .port = 39498 },
    };
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39401),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Force ourselves into leader state without an election (peer 1 will
    // never ack so a real election would never converge).
    c.raft_become_leader(node.raft);
    node.refreshLeaderState();
    try testing.expect(node.isLeader());

    try testing.expect(node.transport.isPeerConfigured(0));
    try testing.expect(node.transport.isPeerConfigured(1));

    // Propose removing peer 1. Mirrored into RaftNet at offer time.
    try node.proposeRemoveNode(1);

    try testing.expect(!node.transport.isPeerConfigured(1));
}

test "isLeasedLeader: single-node leader always holds lease" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39390 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39390),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Single-node cluster: quorum=1, self counts. Lease is always valid
    // while we're leader, regardless of peer ack history.
    try testing.expect(node.isLeasedLeader(@intCast(std.time.nanoTimestamp())));
}

test "isLeasedLeader: returns false when not leader" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39391 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39391),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Before any tick: not leader, lease invalid.
    try testing.expect(!node.isLeader());
    try testing.expect(!node.isLeasedLeader(@intCast(std.time.nanoTimestamp())));

    // Become leader.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Force step down. Lease invalid.
    c.raft_become_follower(node.raft);
    node.refreshLeaderState();
    try testing.expect(!node.isLeader());
    try testing.expect(!node.isLeasedLeader(@intCast(std.time.nanoTimestamp())));
}

test "isLeasedLeader: 3-node lease tracks peer acks within window" {
    const allocator = testing.allocator;

    // Build a 3-node config but only spin up node 0. peer_last_ack_ns is
    // poked manually below to simulate ack arrivals from peers 1 and 2
    // without actually running them.
    const peers = [_]PeerAddr{
        .{ .host = "127.0.0.1", .port = 39392 },
        .{ .host = "127.0.0.1", .port = 39393 },
        .{ .host = "127.0.0.1", .port = 39394 },
    };
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39392),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 200,
        .request_timeout_ms = 50,
    });
    defer node.deinit();

    // Force this node into leader state without running an election (peers
    // 1 and 2 don't exist, so a real election would never converge). This
    // is a unit test of the lease math, not the full raft state machine.
    c.raft_become_leader(node.raft);
    node.refreshLeaderState();
    try testing.expect(node.isLeader());

    const now: i64 = @intCast(std.time.nanoTimestamp());

    // No peer acks yet. Self is 1, quorum is 2 — lease is invalid.
    try testing.expect(!node.isLeasedLeader(now));

    // Simulate an ack from peer 1 right now. Self + peer 1 = 2 ≥ quorum.
    node.peer_last_ack_ns[1].store(now, .release);
    try testing.expect(node.isLeasedLeader(now));

    // Simulate the ack being old (older than election_timeout/2 = 100ms).
    const old_ts = now - 200 * std.time.ns_per_ms;
    node.peer_last_ack_ns[1].store(old_ts, .release);
    try testing.expect(!node.isLeasedLeader(now));

    // Add a fresh ack from peer 2 — quorum is restored.
    node.peer_last_ack_ns[2].store(now, .release);
    try testing.expect(node.isLeasedLeader(now));
}

test "requestStop transitions propose to ShuttingDown" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39380 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39380),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Wait for leadership.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Propose works.
    try node.propose(1, "before");

    // Commit it (single-node cluster commits on next tick).
    const commit_deadline: i128 = std.time.nanoTimestamp() + 500 * std.time.ns_per_ms;
    while (std.time.nanoTimestamp() < commit_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.committedSeq() >= 1) break;
    }
    try testing.expectEqual(@as(u64, 1), node.committedSeq());

    // Request stop. Further proposes must fail fast.
    node.requestStop();
    try testing.expect(node.isStopping());
    try testing.expectError(error.ShuttingDown, node.propose(2, "after"));
}

test "drainPending flushes in-flight proposals before returning" {
    const allocator = testing.allocator;

    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39381 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39381),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Wait for leadership.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());

    // Queue several proposals WITHOUT letting them commit first.
    try node.propose(10, "a");
    try node.propose(20, "b");
    try node.propose(30, "c");

    // Don't tick here — leave them in the queue. high_watermark = 30,
    // committed_seq likely still 0.
    try testing.expectEqual(@as(u64, 30), node.highWatermark());
    try testing.expect(node.committedSeq() < 30);

    // Drain. Since this is a single-node cluster, quorum is self, so a
    // few ticks should commit everything.
    try node.drainPending(2 * std.time.ns_per_s);

    try testing.expectEqual(@as(u64, 30), node.committedSeq());
    try testing.expectEqual(@as(u64, 0), node.faultedSeq());

    // All three apply callbacks fired.
    cap.mu.lock();
    defer cap.mu.unlock();
    try testing.expectEqual(@as(usize, 3), cap.entries.items.len);
}

test "leadership loss sets faulted_seq to high_watermark" {
    const allocator = testing.allocator;

    // Single-node cluster: it elects itself and becomes leader immediately.
    const peers = [_]PeerAddr{.{ .host = "127.0.0.1", .port = 39330 }};
    var cap = ApplyCapture{ .allocator = allocator };
    defer cap.deinit();

    const node = try RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39330),
        .apply = .{ .opaque_bytes = .{ .apply_fn = captureApply, .ctx = &cap } },
        .election_timeout_ms = 100,
        .request_timeout_ms = 25,
    });
    defer node.deinit();

    // Drive ticks until this node is leader.
    const lead_deadline: i128 = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < lead_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());
    try testing.expectEqual(@as(u64, 0), node.faultedSeq());

    // Propose a few seqs. On a single-node cluster these commit immediately
    // because quorum = 1, but high_watermark advances regardless of commit.
    try node.propose(10, "first");
    try node.propose(20, "second");
    try node.propose(30, "third");
    try testing.expectEqual(@as(u64, 30), node.highWatermark());

    // Drive a few more ticks so the proposals actually commit.
    const commit_deadline: i128 = std.time.nanoTimestamp() + 500 * std.time.ns_per_ms;
    while (std.time.nanoTimestamp() < commit_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.committedSeq() >= 30) break;
    }
    try testing.expectEqual(@as(u64, 30), node.committedSeq());

    // Force leadership loss. In a single-node cluster raft_periodic would
    // immediately re-elect us, so we call refreshLeaderState directly to
    // observe the transition without ticking through an election.
    c.raft_become_follower(node.raft);
    node.refreshLeaderState();
    try testing.expect(!node.isLeader());
    try testing.expectEqual(@as(u64, 30), node.faultedSeq());

    // Propose should fail immediately (not leader).
    try testing.expectError(error.NotLeader, node.propose(40, "after"));
    // high_watermark didn't advance (propose rejected).
    try testing.expectEqual(@as(u64, 30), node.highWatermark());

    // If we let the node keep ticking, the single-node cluster re-elects
    // itself. faulted_seq should clear back to 0 on the follower→leader
    // transition.
    const reelect_deadline: i128 = std.time.nanoTimestamp() + 1 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < reelect_deadline) {
        try node.tick(@intCast(std.time.nanoTimestamp()));
        if (node.isLeader()) break;
    }
    try testing.expect(node.isLeader());
    try testing.expectEqual(@as(u64, 0), node.faultedSeq());
}
