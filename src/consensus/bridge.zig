//! V2 data-plane bridge — the worker-facing seam over the per-tenant pump.
//!
//! v2-build-order §Phase 2: swap the V1 *cluster-wide* raft
//! propose/apply at the worker-dispatch seam for "propose to *this
//! tenant's* group → await commit → apply." The bridge is what the
//! reused rove-js worker talks to in place of V1's single global
//! `kv.RaftNode`. It owns the Phase-1 `Node` (one raft-rs `Manager` +
//! one `SharedWal`, per-tenant groups) and drives its pump.
//!
//! ## Threading split (the load-bearing invariant)
//!
//! raft-rs's `Manager` is **not** thread-safe, and the shared WAL wants
//! one fsync per pump cycle — so ALL `Node`/`Manager` access happens on a
//! single **pump thread**. Worker threads only ever touch the bridge's
//! own *signaling* state (the per-tenant seq counters + watermarks +
//! inbox), which is either mutex-guarded or atomic. Concretely:
//!
//!   - **Worker thread** → `propose(gid, env)`: assign a per-tenant seq,
//!     enqueue the envelope, return the seq. Never blocks on commit.
//!   - **Pump thread** → `pumpOnce` / `startPump`: drain the inbox,
//!     `ensureGroup` + `node.propose` each item, run `node.pump()`. The
//!     `Node` commit hook fires per committed entry and advances the
//!     tenant's `committed_seq`.
//!   - **Worker thread** → `committedSeq(gid)` each drain tick: a
//!     lock-free atomic load. When `>= my_seq`, the worker promotes its
//!     speculative `TrackedTxn` overlay (`txn.commit()`).
//!
//! ## Per-tenant watermark (locked 2026-06-04)
//!
//! Commit signaling is a **per-tenant watermark**, not rewind2's
//! per-propose `CompletionHandle`. Scalability lives in the pump layer
//! (hibernation / mailbox poll_ready / coalescing / shared WAL /
//! c_allocator — multiraft-scaling-learnings §2–§3), which the `Node`
//! carries regardless; the completion primitive only has to avoid a
//! *global* serialization point so tenant B's commit never waits on
//! tenant A's. A per-tenant `committed_seq` atomic gives exactly that,
//! lock-free and with zero per-request allocation — and since rove
//! serializes a tenant's proposes (the worker's `TrackedTxn` lease),
//! per-tenant commits are monotonic, so the watermark is as precise as a
//! per-propose handle would be here.
//!
//! ## Seq ↔ commit binding (entry IDENTITY — origin frame)
//!
//! `propose` assigns `seq = ++sig.next_seq`, pushes it onto the tenant's
//! `pending` set **in the same critical section** as the inbox append,
//! and the pump stamps every entry with the bridge's per-boot random
//! `origin_id` + that seq (`envelope.EntryFrame`). The commit hook
//! advances `committed_seq` to an entry's seq **iff the entry's origin is
//! this bridge's own id and its seq is still pending** — an identity
//! binding, never a positional one.
//!
//! Two earlier bindings were wrong in turn. Phase-2 *counting* (Nth
//! commit = seq N) broke under multi-node: a follower applies entries
//! with no local proposer, and a rejected propose never commits. The
//! Phase-5 *leader-gated FIFO pop* fixed those but still bound by
//! POSITION: an old-term entry resurrected by a re-election (committing
//! while a NEW propose sat at the FIFO front) popped the wrong seq — a
//! false durable ack for a write that had not committed. Identity makes
//! that impossible: a committed entry can only ever credit the exact
//! propose that produced it, and the per-boot random origin also fences
//! a restarted node's replayed entries from colliding with the new
//! incarnation's seqs.
//!
//! The same identity keys the worker-overlay store skip (`skipQuery`):
//! the pump skips the store write iff the entry is this bridge's own
//! STILL-PENDING propose (the local worker txn holds those writes and
//! commits them on watermark advance). Entries proposed elsewhere (a
//! promoted leader's catch-up), replayed at recovery (no live txns at
//! boot), or whose waiter gave up (fault/timeout → txn rolled back →
//! `abandon`) are written by the pump like any follower apply.
//!
//! A propose that can't commit here is FAULTED (`faulted_seq`) — at
//! submit (`node.propose` rejected on a non-leader) or by the per-cycle
//! leadership-loss sweep — so the parked worker fails fast (503) and the
//! client retries against the leader. 503 means **unknown outcome**: the
//! entry may still commit later (it then applies via the pump path, the
//! waiter being gone), so retries are at-least-once — consistent with
//! the platform's idempotent-replay posture.

const std = @import("std");
const node_mod = @import("node.zig");
const envelope = @import("envelope.zig");
const kvlimbs = @import("kvlimbs");

pub const Node = node_mod.Node;
pub const WriteSet = node_mod.WriteSet;
pub const PeerAddr = node_mod.PeerAddr;
pub const StoreResolver = node_mod.StoreResolver;
pub const ApplyObserver = node_mod.ApplyObserver;

pub const Error = error{
    /// `propose` / `committedSeq` named a gid with no registered tenant.
    UnknownTenant,
    /// The bridge is shutting down; no further proposes accepted.
    ShuttingDown,
    /// A control command (`createGroupEpoch` / `destroyGroup`) could not
    /// be serviced because the pump thread is not running.
    PumpNotRunning,
    /// This node has the tenant's group but is not its raft leader —
    /// the propose was refused BEFORE anything entered the log, so the
    /// caller can safely re-aim at the leader (the worker maps this to
    /// a 421; the front door / serve-or-forward retry on it).
    NotLeader,
    OutOfMemory,
} || node_mod.Error;

/// Per-tenant signaling state, owned by the bridge and reachable from
/// any thread. Deliberately SEPARATE from `Node.TenantSlot` (which owns
/// the kvexp store + raft group and is touched only on the pump thread):
/// this struct holds only the seq counter + watermarks the worker seam
/// reads/writes. Heap-allocated and pointer-stable for the bridge's
/// lifetime, so a cached `*GroupSig` is a safe lock-free read handle.
pub const GroupSig = struct {
    gid: u64,
    /// Owned dup of the tenant store id string the worker stamps on
    /// writeset envelopes. Borrowed by inbox items (stable).
    id_str: []u8,
    /// Per-tenant monotonic propose ticket. Guarded by `Bridge.mutex`
    /// (assigned in the same critical section as the inbox append).
    next_seq: u64 = 0,
    /// Highest seq whose entry has committed + applied. Advanced only by
    /// the pump commit hook (single writer); read lock-free by workers.
    committed_seq: std.atomic.Value(u64) = .init(0),
    /// Highest seq known to have faulted (leadership loss / shutdown).
    /// Multi-node: a propose submitted on a non-leader, or in flight when
    /// this node loses the group's leadership, faults so the worker fails
    /// fast (503) and the client retries against the new leader.
    faulted_seq: std.atomic.Value(u64) = .init(0),
    /// This node's leadership of the group, refreshed once per pump cycle by
    /// the pump thread (the only Manager toucher) and read lock-free by the
    /// worker thread via `isLeaderOf`. The worker MUST NOT call the
    /// non-thread-safe `Manager` directly, so leadership is published here as
    /// an atomic; one pump cycle stale at worst (fine for the rare move /
    /// leader-probe callers that read it).
    is_leader: std.atomic.Value(bool) = .init(false),
    /// Whether the group EXISTS on this node, published by the pump's
    /// leadership refresh (`refreshOneLocked` → `node.hasGroup`). Gates the
    /// fail-fast follower check in `propose`: a registered tenant whose
    /// group hasn't formed yet must still pass through (lazy first-propose
    /// formation), while a formed group on a non-leader rejects
    /// synchronously instead of letting raft-rs FORWARD the proposal (see
    /// `propose`). One refresh stale at worst, same as `is_leader`.
    formed: std.atomic.Value(bool) = .init(false),
    /// Pump-thread-only mirror of `is_leader` from the PREVIOUS refresh,
    /// used by `refreshLeadership` to detect the follower→leader (false→true)
    /// promotion edge. A freshly-promoted leader must run the on-promotion
    /// recovery hook (reload the tenant's deployment + reconstruct the
    /// volatile scheduler/owed-retry watermarks the old leader held in RAM) —
    /// V1's `loop46` drove this off a single node-wide `was_leader`, but V2
    /// leadership is per-group, so the edge lives here. Touched only in
    /// `refreshLeadership` under `Bridge.mutex`.
    was_leader: bool = false,
    /// FIFO of proposed-but-not-yet-committed seqs (front = oldest).
    /// Pushed by `propose`; the commit hook removes EXACTLY the
    /// committed entry's own seq (identity binding — see file header);
    /// cleared on fault. Guarded by `Bridge.mutex`.
    pending: std.ArrayListUnmanaged(u64) = .empty,
    /// FIFO of committed-but-not-yet-worker-acked entries (front =
    /// oldest), in `worker_overlay` mode only: a popped seq's store
    /// write was SKIPPED on the premise that the local worker txn will
    /// commit it — until the worker confirms (`noteWorkerCommitted`),
    /// the entry's raft index caps the durabilize floor
    /// (`durabilizeFloor`) so the pump can neither stamp the store's
    /// watermark past it nor compact its WAL records away. Guarded by
    /// `Bridge.mutex`.
    awaiting_worker: std.ArrayListUnmanaged(AwaitAck) = .empty,
    /// Highest seq whose store writes the worker has confirmed fold-
    /// visible (`noteWorkerCommitted` high-water). Immediate-commit
    /// producers (v2-kv, the config mirror) commit their txn BEFORE
    /// proposing and may ack before the entry commits — the hook checks
    /// this so an already-acked entry never enters `awaiting_worker`.
    /// Guarded by `Bridge.mutex`.
    worker_acked_seq: u64 = 0,
};

/// A pump-thread-only control operation, handed worker thread → pump
/// thread (the `Manager` is not thread-safe; group lifecycle must run on
/// the pump thread alongside `processReady`). The caller stack-allocates
/// one, enqueues a pointer, and blocks on `done` until the pump has
/// executed it and stamped `err` — so the struct outlives the wait.
const ControlCmd = struct {
    const Kind = enum { create_group_epoch, destroy_group, transfer_all_leadership, transfer_leadership, propose_conf_change, conf_state, voter_progress, apply_local_snapshot, log_term, last_index, baseline_index, applied_raw, durabilized_raw, log_entry, group_epoch };
    kind: Kind,
    gid: u64,
    /// Borrowed from the gid's `GroupSig.id_str` (pointer-stable); used by
    /// `create_group_epoch` to open the tenant's group store.
    id_str: []const u8 = &.{},
    epoch: u64 = 0,
    /// `create_group_epoch`: birth the group with THIS node as a learner
    /// (joining an existing group) rather than a voter — see node.createGroupCore.
    as_learner: bool = false,
    /// `propose_conf_change`: the raft node id to change + the op (0 add_voter /
    /// 1 remove / 2 add_learner — matches `raft.Manager.ConfChange`).
    node_id: u64 = 0,
    cc_type: u8 = 0,
    /// `apply_local_snapshot`: the baseline {index, term} to install.
    /// `log_term` / `log_entry`: `snap_index` is the query index, `snap_term` the
    /// result term.
    snap_index: u64 = 0,
    snap_term: u64 = 0,
    /// `log_entry` (diagnostic): caller buffer (in) for the entry's data + the
    /// bytes written (out). `lt_ok` flags a resolved entry.
    entry_buf: ?[]u8 = null,
    entry_len: usize = 0,
    /// `apply_local_snapshot` (Phase 2 — membership SSOT): the source leader's
    /// ConfState the baseline carries, so a joiner learns its membership from the
    /// snapshot. Null → keep the group's current membership (membership-neutral
    /// promote-back, unchanged). Borrowed from the caller stack for the call.
    snap_voters: ?[]const u64 = null,
    snap_learners: ?[]const u64 = null,
    /// `create_group_epoch` (Phase 2e — cluster node-set SSOT): the initial voter
    /// set a FRESH group is born with, supplied by the control plane (the cluster
    /// node set) instead of the node's static `REWIND_VOTERS`. Null → `self.voters`
    /// (unchanged). Borrowed from the caller stack for the blocking call.
    birth_voters: ?[]const u64 = null,
    /// `conf_state`: caller buffers to fill + the counts written back.
    cs_voters: []u64 = &.{},
    cs_learners: []u64 = &.{},
    cs_voters_len: usize = 0,
    cs_learners_len: usize = 0,
    cs_ok: bool = false,
    /// `voter_progress`: caller buffers (parallel: id/matched/active) filled by
    /// the pump from the leader's per-peer view; len + leader_last written back.
    vp_ids: []u64 = &.{},
    vp_matched: []u64 = &.{},
    vp_active: []u8 = &.{},
    vp_len: usize = 0,
    vp_leader_last: u64 = 0,
    vp_ok: bool = false,
    /// `log_term`: true iff a term was resolvable at the index (distinguishes a
    /// genuine term of 0 from "unknown group / compacted / beyond log").
    lt_ok: bool = false,
    /// Result, written by the pump before signaling `done`.
    err: ?Error = null,
    /// `transfer_all_leadership` writes the number of groups it handed off here.
    count: usize = 0,
    done: std.Thread.ResetEvent = .{},
};

/// One queued commit-wait-timeout fault request (see
/// `Bridge.requestFault`), handed worker thread → pump thread.
const FaultReq = struct {
    gid: u64,
    seq: u64,
};

/// One committed-but-not-worker-acked entry (see
/// `GroupSig.awaiting_worker`): the seq the worker will commit and the
/// raft index its commit unblocks for durabilize/compaction.
const AwaitAck = struct {
    seq: u64,
    idx: u64,
};

/// One out-of-band snapshot catch-up job, handed pump thread → worker thread
/// (the snapshot-trigger half of the raft-native alignment arc). The pump
/// detects a peer in `ProgressState::Snapshot` (fell below the leader's
/// compaction first_index) and enqueues the bundle's baseline {index, term}
/// it computed on-thread (baselineIndex + logTerm are pump-only). The worker's
/// `SnapshotCatchupThread` then dumps the leader's store + pushes
/// `v2-load-replace` + `v2-apply-snapshot {index, term}` to the peer, so the
/// peer's `match` advances past first_index and `StateSnapshot` clears. The
/// `(gid, peer)` pair is deduped in `catchup_inflight` while a job is live so
/// the same lagging peer isn't re-pushed every tick.
const CatchupJob = struct {
    gid: u64,
    peer: u64,
    /// Baseline the worker installs via `v2-apply-snapshot`, snapshotted on the
    /// pump at enqueue time. The store dump the worker takes later reflects a
    /// LATER applied instant (⊇ this index), so the leader's tail above `index`
    /// re-applies idempotently — the same ordering CP's `bootstrapMember` uses
    /// (read baseline, THEN dump the bundle).
    index: u64,
    term: u64,
};

/// Worker-facing resolved form of a `CatchupJob` (`drainSnapshotCatchup` adds
/// the gid's pointer-stable `id_str`). The `SnapshotCatchupThread` consumes it.
pub const SnapshotCatchup = struct {
    gid: u64,
    peer: u64,
    index: u64,
    term: u64,
    /// Pointer-stable `GroupSig.id_str` — the tenant string for the store dump +
    /// the `X-Rewind-Tenant` header. Borrowed; valid until the group is destroyed
    /// (the worker dups it into the job before any await).
    id_str: []const u8,
};

/// One queued propose, handed worker thread → pump thread.
const ProposeItem = struct {
    gid: u64,
    /// The per-tenant seq this propose was assigned (so the pump can fault
    /// exactly it if `node.propose` rejects on a non-leader).
    seq: u64,
    /// Borrowed from the gid's `GroupSig.id_str` (pointer-stable).
    id_str: []const u8,
    /// Owned envelope bytes; the pump frees after `node.propose`
    /// (raft-rs copies the payload into the log entry).
    payload: []u8,
};

pub const Bridge = struct {
    /// Mirrors the field shape of V1's `RaftNode.config` that the reused
    /// worker reads (`worker.raft.config.node_id`) — single-node default 1.
    pub const Config = struct { node_id: u32 = 1 };

    allocator: std.mem.Allocator,
    node: *Node,
    /// Compatibility surface for the reused worker's `.raft.config.*` reads.
    config: Config = .{},

    /// This bridge incarnation's random identity, stamped (with the seq)
    /// into every proposed entry's origin frame. The commit hook and the
    /// skip query match on it — see the file header. Random per boot
    /// (not the node id) so a restarted node's replayed WAL entries can
    /// never collide with the new incarnation's seq space.
    origin_id: u64,

    /// Guards `groups` + `by_id` + `next_gid` + `inbox` + every
    /// `GroupSig.next_seq`. NOT held across `node.*` calls.
    mutex: std.Thread.Mutex = .{},
    groups: std.AutoHashMapUnmanaged(u64, *GroupSig) = .empty,
    /// id_str → gid (a deterministic hash; see `registerTenant`). The
    /// cross-cluster tenant→cluster directory is the separate control-plane
    /// `Directory` (Phase 3); this is just the local id→raft-group map.
    by_id: std.StringHashMapUnmanaged(u64) = .empty,
    inbox: std.ArrayListUnmanaged(ProposeItem) = .empty,
    /// Gids with a non-empty `GroupSig.pending` (in-flight proposes). The
    /// pump sweeps only these each cycle for leadership-loss faulting, so
    /// the sweep is O(in-flight tenants), not O(all tenants). Guarded by
    /// `mutex`; deduped (a gid appears at most once).
    in_flight: std.ArrayListUnmanaged(u64) = .empty,
    /// Gids that transitioned follower→leader since the worker last called
    /// `drainPromotions`. Appended by `refreshLeadership` (pump thread) on
    /// the false→true edge; drained by the worker thread's on-promotion hook.
    /// Multi-node only — on a single node the sole voter leads every group it
    /// creates and never fails over, so nothing is ever queued here. Guarded
    /// by `mutex`.
    promoted: std.ArrayListUnmanaged(u64) = .empty,
    /// Out-of-band snapshot catch-up jobs the pump's `snapshotTriggerTick`
    /// detected (a peer in `StateSnapshot`), awaiting the worker's
    /// `SnapshotCatchupThread`. Appended by the pump, drained by the worker.
    /// Guarded by `mutex`. Multi-node only.
    snapshot_catchup: std.ArrayListUnmanaged(CatchupJob) = .empty,
    /// `(gid, peer)` pairs with a catch-up job in flight (enqueued but not yet
    /// completed), so a lagging peer isn't re-pushed every trigger tick while
    /// its transfer is running. The pump checks it before enqueuing; the worker
    /// clears the entry when the job finishes (success or failure → re-trigger
    /// next tick). Key = `gid ^ (peer << 1)` is ambiguous, so pack both: the
    /// set stores `(gid, peer)` via a 128-bit key. Guarded by `mutex`.
    catchup_inflight: std.AutoHashMapUnmanaged(u128, void) = .empty,
    /// Move-orchestration control ops awaiting the pump thread (group
    /// create-at-epoch / destroy). Pointers to caller-stack `ControlCmd`s;
    /// guarded by `mutex`. Drained + executed in `pumpOnce`.
    control_inbox: std.ArrayListUnmanaged(*ControlCmd) = .empty,
    /// Worker-thread commit-wait timeouts awaiting pump-side execution
    /// (`requestFault` → `drainFaultRequests`) — the fault must be
    /// serialized with the pump's skip/commit decisions. Guarded by
    /// `mutex`.
    fault_requests: std.ArrayListUnmanaged(FaultReq) = .empty,
    /// Pump-thread-only scratch for `sweepLostLeadership` (snapshot of
    /// `in_flight`, reused per cycle).
    sweep_scratch: std.ArrayListUnmanaged(u64) = .empty,
    /// Pump-thread-only: wall-clock of the last FULL leadership scan
    /// (see `refreshLeadership` / `LEADER_SCAN_INTERVAL_NS`).
    last_leader_scan_ns: i64 = 0,
    /// Pump-thread-only: wall-clock of the last `snapshotTriggerTick`
    /// (interval-gated by `SNAPSHOT_TRIGGER_INTERVAL_NS`).
    last_snapshot_trigger_ns: i64 = 0,
    /// Count of follower→leader promotion edges this node has observed across
    /// all groups (incremented in `refreshOneLocked`). With `pre_vote` on, a
    /// term is only bumped by a node that can win, so a promotion edge ≈ an
    /// election that changed the leader — the spurious-election signal a soak
    /// watches: after the initial one-per-group formation, the cluster-wide sum
    /// should stay flat under steady load. Surfaced as
    /// `raft_leadership_acquisitions_total` in `/_system/metrics`. Written on
    /// the pump thread, read lock-free by the worker.
    leadership_acquisitions: std.atomic.Value(u64) = .init(0),

    pump_thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),

    /// Stand up a single-node bridge over a fresh single-voter `Node`.
    /// Does NOT start the pump thread — call `startPump` (production) or
    /// drive `pumpOnce` directly (tests).
    pub fn initSingleNode(allocator: std.mem.Allocator, data_dir: []const u8) Error!*Bridge {
        const node = try Node.initSingleNode(allocator, data_dir);
        errdefer node.deinit();
        return Bridge.init(allocator, node);
    }

    /// Stand up a multi-node bridge (Phase 5) over a fresh multi-node
    /// `Node`: this node's `node_id` ∈ `voters`, the cross-node transport
    /// bound to `listen_addr` with `peers` (indexed by raft node id − 1).
    /// Like the single-node bridge it does NOT start the pump thread —
    /// call `startPump`.
    pub fn initMultiNode(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        node_id: u64,
        voters: []const u64,
        listen_addr: std.net.Address,
        peers: []const node_mod.PeerAddr,
    ) Error!*Bridge {
        const node = try Node.initMultiNode(allocator, data_dir, node_id, voters, listen_addr, peers);
        errdefer node.deinit();
        return Bridge.init(allocator, node);
    }

    pub fn init(allocator: std.mem.Allocator, node: *Node) Error!*Bridge {
        const self = allocator.create(Bridge) catch return Error.OutOfMemory;
        // origin 0 is the reserved "hookless" identity (bare proposes);
        // re-draw on the (2^-64) collision.
        var origin: u64 = 0;
        while (origin == 0) origin = std.crypto.random.int(u64);
        self.* = .{ .allocator = allocator, .node = node, .origin_id = origin };
        node.commit_hook = .{ .ctx = self, .func = onCommitted };
        node.skip_query = .{ .ctx = self, .func = skipQuery };
        node.durabilize_floor = .{ .ctx = self, .func = durabilizeFloor };
        return self;
    }

    /// Put the node in worker-overlay apply mode: a worker fronting this
    /// bridge owns the speculative overlay and commits it on watermark
    /// advance, so the pump skips the store write **on the leader** (the
    /// worker wrote it) but still writes it **on a follower** (no worker
    /// for that tenant here). Single-node is always the leader, so this is
    /// the old leader-skip behavior there. Call before serving (`rewind`).
    /// The 2a unit tests, which read the pump's own store, keep the
    /// default `apply_on_commit`.
    pub fn setWorkerOverlay(self: *Bridge) void {
        self.node.apply_mode = .worker_overlay;
    }

    /// Pin a group as always-active (never hibernated) on the node — see
    /// `node_mod.Node.pinActive`. The CP directory group uses this so it keeps
    /// ticking and re-elects on leader death. Pre-pump / pump-thread only.
    pub fn pinGroupActive(self: *Bridge, gid: u64) Error!void {
        return self.node.pinActive(gid);
    }

    /// Register a per-applied-put observer on the node (see
    /// `node_mod.ApplyObserver`). The control-plane directory uses this so a
    /// CP node's in-memory placement projection tracks replicated applies —
    /// the leader's own writes AND a follower's replicated entries (a follower
    /// has no local proposer, so the post-commit projection update can't fire
    /// there). Call before serving. Safe to leave unset (every non-CP bridge
    /// does).
    pub fn setApplyObserver(self: *Bridge, observer: node_mod.ApplyObserver) void {
        self.node.apply_observer = observer;
    }


    /// Point follower-apply at the worker's own per-tenant serving store
    /// (Phase 5 "Full HA"). In `worker_overlay` mode a follower has no local
    /// worker for the tenant, so its replicated writes must land in the
    /// store a worker WOULD serve from — the worker's `inst.kv`, provisioned
    /// on demand — so that a follower promoted to leader after a failover
    /// serves the data it replicated. The worker (`rewind`) wires this to
    /// its `Tenant`. Without it a follower writes the node's own (unserved)
    /// slot store. Call before serving; safe to leave unset (the bare-node
    /// tests do). See `node_mod.StoreResolver`.
    pub fn setStoreResolver(self: *Bridge, resolver: node_mod.StoreResolver) void {
        self.node.store_resolver = resolver;
    }

    /// Stop the pump (if running), then free the node + all bridge state.
    pub fn deinit(self: *Bridge) void {
        self.stopPump();

        const a = self.allocator;
        self.node.deinit();

        var it = self.groups.valueIterator();
        while (it.next()) |sig_ptr| {
            const sig = sig_ptr.*;
            sig.pending.deinit(a);
            sig.awaiting_worker.deinit(a);
            a.free(sig.id_str);
            a.destroy(sig);
        }
        self.groups.deinit(a);
        self.by_id.deinit(a);
        self.in_flight.deinit(a);
        self.promoted.deinit(a);
        self.snapshot_catchup.deinit(a);
        self.catchup_inflight.deinit(a);
        self.fault_requests.deinit(a);
        self.sweep_scratch.deinit(a);
        // Any items still queued at teardown own their payloads.
        for (self.inbox.items) |item| a.free(item.payload);
        self.inbox.deinit(a);
        // Control commands are caller-stack-owned; stopPump already
        // released every queued waiter (err = ShuttingDown + done.set),
        // so the list is empty — this just frees its capacity.
        self.control_inbox.deinit(a);
        a.destroy(self);
    }

    // ── Tenant registry (any thread) ─────────────────────────────────

    /// Map a tenant store id to its numeric raft group id, registering its
    /// `GroupSig` on first sight. Idempotent. Safe from any thread. Does
    /// NOT touch the `Node`/`Manager` — the raft group is created on the
    /// pump thread (lazily at first propose via `ensureGroup`, or eagerly
    /// via `createGroupEpoch` for a move/multi-node formation).
    ///
    /// The gid is a **deterministic hash of `id_str`**, not a local
    /// counter: a raft group spans all nodes, so every node must derive the
    /// SAME group id for a tenant or replication can't bind the incarnations
    /// together. (Phase-2/3 used a local monotonic counter — fine for one
    /// node, wrong the moment a second node joins.)
    pub fn registerTenant(self: *Bridge, id_str: []const u8) Error!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.by_id.get(id_str)) |gid| return gid;

        const gid = tenantGid(id_str);
        const sig = self.allocator.create(GroupSig) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(sig);
        const id_dup = self.allocator.dupe(u8, id_str) catch return Error.OutOfMemory;
        errdefer self.allocator.free(id_dup);
        sig.* = .{ .gid = gid, .id_str = id_dup };

        self.groups.put(self.allocator, gid, sig) catch return Error.OutOfMemory;
        errdefer _ = self.groups.remove(gid);
        // Key the by_id entry on the owned dup so it outlives the caller's
        // slice.
        self.by_id.put(self.allocator, id_dup, gid) catch return Error.OutOfMemory;

        return gid;
    }

    /// Deterministic tenant-id → raft group id (Wyhash, seed 0). Group id 0
    /// is avoided (raft reserves 0 as None for node ids; keep groups ≥ 1
    /// for symmetry + to never collide with a sentinel). Collisions across
    /// distinct tenants are a 64-bit-hash non-event, same stance as kvexp's
    /// `hashStoreId`.
    fn tenantGid(id_str: []const u8) u64 {
        const h = std.hash.Wyhash.hash(0, id_str);
        return if (h == 0) 1 else h;
    }

    /// Look up a registered tenant's gid by id, or null if unregistered.
    pub fn gidForTenant(self: *Bridge, id_str: []const u8) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.by_id.get(id_str);
    }

    fn sigFor(self: *Bridge, gid: u64) ?*GroupSig {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.groups.get(gid);
    }

    // ── Propose (worker thread) ──────────────────────────────────────

    /// Assign a per-tenant seq, enqueue a COPY of `payload` for the pump,
    /// and return the seq for the worker to park on. Copies (rather than
    /// takes ownership) to match V1 `RaftNode.propose` semantics, so the
    /// reused worker's existing "free the envelope after propose" logic is
    /// unchanged — the bridge owns the copy and frees it after
    /// `node.propose`. Never blocks on commit; the worker polls
    /// `committedSeq(gid)`.
    ///
    /// The seq assignment + inbox append happen under one lock so per-
    /// tenant seq order == enqueue order == commit order (see file
    /// header). Returns the assigned seq (≥ 1).
    pub fn propose(self: *Bridge, gid: u64, payload: []const u8) Error!u64 {
        if (self.stop.load(.acquire)) return Error.ShuttingDown;
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return Error.UnknownTenant;
        // Fail fast on a non-leader: raft-rs 0.7 unconditionally FORWARDS
        // a follower's proposal to the leader (`step_follower` MsgPropose),
        // so without this gate the entry would commit cluster-wide while
        // this node's leadership sweep faults the seq — the client is told
        // "write failed" with the write durable, and any proxy that blind-
        // retries the failure double-executes the handler (the
        // durable_wake Gate-A double-mint). Rejecting HERE — before the
        // payload enters the inbox — keeps the file-header invariant ("a
        // rejected propose never commits") actually true. `formed` gates
        // the check so lazy first-propose group formation still passes;
        // a formed-but-still-electing group rejects on every node until a
        // leader exists (proxies surface that as a retryable 503). The
        // raft-rs-zig propose leader-gate backstops the one-refresh-stale
        // race window.
        if (!self.node.isSingleNode() and
            sig.formed.load(.acquire) and !sig.is_leader.load(.acquire))
            return Error.NotLeader;
        const owned = self.allocator.dupe(u8, payload) catch return Error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const seq = sig.next_seq + 1;
        // Record the in-flight seq BEFORE enqueue so the commit hook (which
        // pops the front in FIFO/commit order) and the leadership-loss
        // fault path both see it.
        const was_empty = sig.pending.items.len == 0;
        sig.pending.append(self.allocator, seq) catch return Error.OutOfMemory;
        errdefer _ = sig.pending.pop();
        if (was_empty) self.in_flight.append(self.allocator, gid) catch {
            _ = sig.pending.pop();
            return Error.OutOfMemory;
        };
        self.inbox.append(self.allocator, .{
            .gid = gid,
            .seq = seq,
            .id_str = sig.id_str,
            .payload = owned,
        }) catch {
            _ = sig.pending.pop();
            if (was_empty) self.removeInFlightLocked(gid);
            return Error.OutOfMemory;
        };
        sig.next_seq = seq;
        return seq;
    }

    /// Convenience over `propose`: build a type-0 writeset envelope putting
    /// a single `key=value` for the gid's registered tenant id and propose
    /// it, returning the assigned seq. The control-plane directory (which has
    /// no rove-js worker to assemble writesets) uses this to replicate a
    /// `cluster/*` / `placement/*` directory write through its group. Awaits
    /// nothing — the caller polls `committedSeq(gid)` / `faultedSeq(gid)`.
    pub fn proposePut(self: *Bridge, gid: u64, key: []const u8, value: []const u8) Error!u64 {
        const id_str = blk: {
            const sig = self.sigFor(gid) orelse return Error.UnknownTenant;
            break :blk sig.id_str; // pointer-stable for the bridge's lifetime
        };
        var ws = WriteSet.init(self.allocator);
        defer ws.deinit();
        ws.addPut(key, value) catch return Error.OutOfMemory;
        const ws_bytes = ws.encode(self.allocator) catch return Error.OutOfMemory;
        defer self.allocator.free(ws_bytes);
        const env = envelope.encodeWriteSet(self.allocator, id_str, ws_bytes) catch return Error.OutOfMemory;
        defer self.allocator.free(env);
        return self.propose(gid, env);
    }

    /// Drop `gid` from `in_flight` (its pending FIFO emptied). Caller holds
    /// `mutex`. O(in-flight count) — small.
    fn removeInFlightLocked(self: *Bridge, gid: u64) void {
        for (self.in_flight.items, 0..) |g, i| {
            if (g == gid) {
                _ = self.in_flight.swapRemove(i);
                return;
            }
        }
    }

    /// Fault every in-flight seq for `gid` (a propose rejected on a
    /// non-leader, or this node lost the group's leadership mid-flight):
    /// raise `faulted_seq` to `next_seq` so parked workers fail fast, clear
    /// the pending FIFO, and drop it from `in_flight`. Takes `mutex`.
    fn faultTenant(self: *Bridge, gid: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return;
        if (sig.pending.items.len == 0) return;
        sig.faulted_seq.store(sig.next_seq, .release);
        sig.pending.clearRetainingCapacity();
        self.removeInFlightLocked(gid);
    }

    // ── Watermarks (worker thread, lock-free) ────────────────────────

    /// Highest seq for this tenant whose write is committed + applied.
    /// A worker considers its write durable once `committedSeq(gid) >=
    /// my_seq`. Lock-free atomic load on the hot drain path.
    pub fn committedSeq(self: *Bridge, gid: u64) u64 {
        const sig = self.sigFor(gid) orelse return 0;
        return sig.committed_seq.load(.acquire);
    }

    /// Highest seq for this tenant known to have faulted (leadership
    /// loss / shutdown). Phase 2: only moves on teardown.
    pub fn faultedSeq(self: *Bridge, gid: u64) u64 {
        const sig = self.sigFor(gid) orelse return 0;
        return sig.faulted_seq.load(.acquire);
    }

    /// Node-wide leadership for OBSERVABILITY ONLY: true iff this node is the
    /// raft leader of at least one group it carries. V2 leadership is
    /// per-GROUP — there is no single node-wide leader — so this must NEVER
    /// gate a per-tenant decision (use `isLeaderOf(gid)` for that; the old
    /// always-true `isLeader()` shim was deleted because it silently no-op'd
    /// such gates). Used by `/_system/leader` and the `raft_is_leader` metric
    /// as a "does this node serve any group as leader" signal. Single-node
    /// short-circuits true (the sole voter leads every group, and groups form
    /// lazily so the map may be empty), preserving the smoke readiness probe.
    pub fn leadsAnyGroup(self: *Bridge) bool {
        if (self.node.isSingleNode()) return true;
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.groups.valueIterator();
        while (it.next()) |sig| {
            if (sig.*.is_leader.load(.acquire)) return true;
        }
        return false;
    }

    /// Cluster-wide count of follower→leader promotion edges this node has
    /// observed (spurious-election signal — see `leadership_acquisitions`).
    /// Lock-free; worker-thread entry point for `/_system/metrics`.
    pub fn leadershipAcquisitions(self: *const Bridge) u64 {
        return self.leadership_acquisitions.load(.acquire);
    }

    /// Snapshot the heartbeat round-trip histogram (broadcast-time samples), or
    /// null on a single-node node. Worker-thread entry point for
    /// `/_system/metrics`; the histogram's atomic buckets make it lock-free.
    pub fn heartbeatRttSnapshot(self: *Bridge) ?kvlimbs.MicrosHistogram.Snapshot {
        return self.node.heartbeatRttSnapshot();
    }

    /// Per-group leadership (Phase 5 multi-node). True when this node is the
    /// raft leader of `gid`'s group — used to leader-gate the move surface
    /// (`v2-bundle` / `v2-kv` PUT reject fast on a follower so the front
    /// door retries the leader, avoiding a non-leader speculative write that
    /// never replicates) and to let the move orchestrator await a freshly
    /// formed destination group's election (`v2-leader`). On a SINGLE-node
    /// node the sole voter leads every group it creates, so this is
    /// unconditionally true; the per-group
    /// `mgr.isLeader` would otherwise read false for a tenant whose group
    /// has not yet been lazily created on the single node. Reads the
    /// pump-published `is_leader` atomic (never the Manager directly), so it
    /// is worker-thread-safe and one pump cycle stale at worst.
    pub fn isLeaderOf(self: *Bridge, gid: u64) bool {
        if (self.node.isSingleNode()) return true;
        const sig = self.sigFor(gid) orelse return false;
        return sig.is_leader.load(.acquire);
    }

    /// True when this node runs as the sole voter (no peers). The worker's
    /// dispatch-gate uses this to skip the per-tenant leader redirect on
    /// single-node / dev deployments: the sole node leads every group,
    /// there are no followers that could serve a stale read, and a group
    /// may not be lazily created at gate time (so `gidForTenant` can read
    /// null even though this node would lead it).
    pub fn isSingleNode(self: *Bridge) bool {
        return self.node.isSingleNode();
    }

    // ── Move control (any thread; executes on the pump thread) ───────


    /// Attach a freshly-loaded tenant's raft group at `epoch` on the pump
    /// thread (move destination). The tenant must already be
    /// `registerTenant`'d (so `gid` resolves and `id_str` is stable) and
    /// its kvexp state already loaded into the worker store. Blocks until
    /// the pump has created + led the group. (Phase 4 destination attach.)
    /// `birth_voters` (Phase 2e — cluster node-set SSOT): the initial voter set the
    /// fresh group is born with (the CP-supplied cluster node set). Null →
    /// `REWIND_VOTERS` (unchanged). The plain (no-baseline) formation path, e.g.
    /// provision's empty-attach.
    pub fn createGroupEpoch(self: *Bridge, gid: u64, epoch: u64, birth_voters: ?[]const u64) Error!void {
        const sig = self.sigFor(gid) orelse return Error.UnknownTenant;
        var cmd: ControlCmd = .{ .kind = .create_group_epoch, .gid = gid, .id_str = sig.id_str, .epoch = epoch, .birth_voters = birth_voters };
        return self.runControl(&cmd);
    }

    /// Create `gid`'s group at `epoch` AND install a data-free raft baseline at
    /// {index, term} in the SAME pump op — atomic, so the fresh group is never
    /// reachable at last_index 0 (where a leader heartbeat carrying commit > 0
    /// would trip raft's commit_to fatal!). The reconciler bootstrap path: the
    /// kvexp state for `index` must already be loaded into the store. `index` 0
    /// behaves exactly like `createGroupEpoch` (no baseline). `as_learner` births
    /// the group with this node as a non-voting learner (joining an existing
    /// group via the reconciler's learner-first path) — see node.createGroupCore.
    /// `voters`/`learners` (Phase 2d — membership SSOT): the source leader's
    /// ConfState the installed baseline carries, so the joining node learns its
    /// real membership from the snapshot rather than the static voter set. Null →
    /// membership-neutral (the born/current prs). The supplied membership MUST
    /// contain this node (`Error.SelfNotInConfState` otherwise — the leader must
    /// have conf-change-added it first).
    pub fn createGroupAtBaseline(self: *Bridge, gid: u64, epoch: u64, index: u64, term: u64, as_learner: bool, voters: ?[]const u64, learners: ?[]const u64) Error!void {
        const sig = self.sigFor(gid) orelse return Error.UnknownTenant;
        var cmd: ControlCmd = .{ .kind = .create_group_epoch, .gid = gid, .id_str = sig.id_str, .epoch = epoch, .snap_index = index, .snap_term = term, .as_learner = as_learner, .snap_voters = voters, .snap_learners = learners };
        return self.runControl(&cmd);
    }

    /// Destroy a tenant's raft group + reclaim its WAL on the pump thread
    /// (move source cleanup). Blocks until done. (Phase 4 source evict.)
    pub fn destroyGroup(self: *Bridge, gid: u64) Error!void {
        var cmd: ControlCmd = .{ .kind = .destroy_group, .gid = gid };
        return self.runControl(&cmd);
    }

    /// Graceful shutdown: hand off leadership of every group this node leads
    /// to a caught-up follower BEFORE stopping the pump, so a rolling restart
    /// (the `/deploy` path) costs ~one heartbeat per led group instead of a
    /// full election timeout. Runs on the pump thread (control cmd). Returns
    /// the number of groups handed off. No-op returning 0 on a single-node
    /// deployment (the sole voter leads everything with no follower to hand to)
    /// or if the pump is already stopped. The caller should then poll
    /// `leadsAnyGroup` for a bounded grace window so the `MsgTimeoutNow` →
    /// new-leader round-trips land while the pump is still running.
    pub fn transferAllLeadership(self: *Bridge) usize {
        if (self.node.isSingleNode()) return 0;
        var cmd: ControlCmd = .{ .kind = .transfer_all_leadership, .gid = 0 };
        self.runControl(&cmd) catch return 0;
        return cmd.count;
    }

    /// Diagnostic/test: force a leadership handoff of ONE group to its most
    /// caught-up follower (no-op if this node is not its leader). Returns 1 if a
    /// handoff was initiated, else 0. Drives the churn soak's leadership flips.
    pub fn transferLeadership(self: *Bridge, gid: u64) usize {
        if (self.node.isSingleNode()) return 0;
        var cmd: ControlCmd = .{ .kind = .transfer_leadership, .gid = gid };
        self.runControl(&cmd) catch return 0;
        return cmd.count;
    }

    /// Operator-triggered membership change on `gid`'s group (conf_change Phase 1):
    /// `cc_type` 0 = add voter / promote, 1 = remove, 2 = add learner / demote.
    /// Runs on the pump (the only Manager toucher); leader-gated + quorum-guarded
    /// in the FFI (`Error.NotLeader` / `Error.ConfChangeQuorumGuard`). The
    /// committed change applies + persists durably via the apply path.
    pub fn proposeConfChange(self: *Bridge, gid: u64, node_id: u64, cc_type: u8) Error!void {
        var cmd: ControlCmd = .{ .kind = .propose_conf_change, .gid = gid, .node_id = node_id, .cc_type = cc_type };
        return self.runControl(&cmd);
    }

    pub const ConfStateView = struct { voters: []const u64, learners: []const u64 };

    /// Read `gid`'s current membership into the caller's buffers (slices into
    /// them on success). Runs a pump-thread control cmd. Null for an unknown
    /// group or if the pump is down.
    pub fn confState(self: *Bridge, gid: u64, voters_buf: []u64, learners_buf: []u64) ?ConfStateView {
        var cmd: ControlCmd = .{ .kind = .conf_state, .gid = gid, .cs_voters = voters_buf, .cs_learners = learners_buf };
        self.runControl(&cmd) catch return null;
        if (!cmd.cs_ok) return null;
        return .{ .voters = voters_buf[0..cmd.cs_voters_len], .learners = learners_buf[0..cmd.cs_learners_len] };
    }

    pub const VoterProgressView = struct { len: usize, leader_last: u64 };

    /// Per-peer replication progress on `gid`'s group from the LEADER's view:
    /// fills the parallel `ids`/`matched`/`active` buffers (same length) and
    /// returns `{len, leader_last}`. Null on a follower / unknown group / pump
    /// down. The reconciler's "is node N a caught-up member" truth signal
    /// (conf_state alone lies — a phantom voter has `matched=0`). Control cmd.
    pub fn voterProgress(self: *Bridge, gid: u64, ids: []u64, matched: []u64, active: []u8) ?VoterProgressView {
        var cmd: ControlCmd = .{ .kind = .voter_progress, .gid = gid, .vp_ids = ids, .vp_matched = matched, .vp_active = active };
        self.runControl(&cmd) catch return null;
        if (!cmd.vp_ok) return null;
        return .{ .len = cmd.vp_len, .leader_last = cmd.vp_leader_last };
    }

    /// The term of the log entry at `index` on `gid`'s group, or `null` when no
    /// term is resolvable — compacted / beyond the log / unknown group / pump
    /// down. A leader reports `term(applied)` for a returning learner's
    /// promote-back baseline. `null` is DISTINCT from a genuine term of 0 (the
    /// genesis index), so a caller never stamps a fake 0 into a baseline.
    /// Pump-thread control cmd.
    pub fn logTerm(self: *Bridge, gid: u64, index: u64) ?u64 {
        var cmd: ControlCmd = .{ .kind = .log_term, .gid = gid, .snap_index = index };
        self.runControl(&cmd) catch return null;
        return if (cmd.lt_ok) cmd.snap_term else null;
    }

    pub const LogEntry = struct { term: u64, data: []const u8 };

    /// Diagnostic: read the raft LOG entry at `index` for `gid` into `buf` (the
    /// replicated log content). Null on unknown group / no entry / buf too small.
    /// `data` slices into `buf`. Pump op.
    pub fn logEntry(self: *Bridge, gid: u64, index: u64, buf: []u8) ?LogEntry {
        var cmd: ControlCmd = .{ .kind = .log_entry, .gid = gid, .snap_index = index, .entry_buf = buf };
        self.runControl(&cmd) catch return null;
        if (!cmd.lt_ok) return null;
        return .{ .term = cmd.snap_term, .data = buf[0..cmd.entry_len] };
    }

    /// This group's local raft last log index (any replica) — the reconciler's
    /// learner→promote catch-up signal. Pump op (the Manager is pump-only). 0 on
    /// unknown group / pump failure.
    pub fn lastIndex(self: *Bridge, gid: u64) u64 {
        var cmd: ControlCmd = .{ .kind = .last_index, .gid = gid };
        self.runControl(&cmd) catch return 0;
        return cmd.snap_index;
    }

    /// This group's LIVE applied index on the leader (`slot.applied_idx`) — the
    /// out-of-band baseline a new member is born at. Always >= the leader's first
    /// (compacted) log index, so the baseline points at an entry the leader still
    /// holds (unlike the durabilized store watermark, which lags under churn).
    /// Pump op. 0 on unknown group / pump failure.
    pub fn baselineIndex(self: *Bridge, gid: u64) u64 {
        var cmd: ControlCmd = .{ .kind = .baseline_index, .gid = gid };
        self.runControl(&cmd) catch return 0;
        return cmd.snap_index;
    }

    /// Diagnostic: this node's RAW apply watermark for `gid` (`slot.applied_idx`).
    pub fn appliedRaw(self: *Bridge, gid: u64) u64 {
        var cmd: ControlCmd = .{ .kind = .applied_raw, .gid = gid };
        self.runControl(&cmd) catch return 0;
        return cmd.snap_index;
    }

    /// Diagnostic: this node's durable folded watermark for `gid`.
    pub fn durabilizedRaw(self: *Bridge, gid: u64) u64 {
        var cmd: ControlCmd = .{ .kind = .durabilized_raw, .gid = gid };
        self.runControl(&cmd) catch return 0;
        return cmd.snap_index;
    }

    /// This group's migration epoch on the leader — a joining node must birth its
    /// local group at this exact epoch or the leader's messages are fenced out.
    /// Pump op. 0 on unknown group / pump failure (also the genuine genesis epoch,
    /// which is correct — a genesis group IS epoch 0).
    pub fn groupEpoch(self: *Bridge, gid: u64) u64 {
        var cmd: ControlCmd = .{ .kind = .group_epoch, .gid = gid };
        self.runControl(&cmd) catch return 0;
        return cmd.snap_index;
    }

    /// Install a DATA-FREE snapshot baseline at {index, term} into `gid`'s LOCAL
    /// group (conf_change promote-back). The node must be a below-floor learner;
    /// the KV state for `index` must already be loaded out-of-band (the move
    /// bundle). Fast-forwards the raft log baseline so the leader can replicate
    /// the tail and the node can be promoted back. Pump-thread control cmd.
    /// `Error.NotLeader` if this node leads the group; `Error.SnapshotStale` if
    /// `index` is not ahead of committed.
    pub fn applyLocalSnapshot(self: *Bridge, gid: u64, index: u64, term: u64, voters: ?[]const u64, learners: ?[]const u64) Error!void {
        var cmd: ControlCmd = .{ .kind = .apply_local_snapshot, .gid = gid, .snap_index = index, .snap_term = term, .snap_voters = voters, .snap_learners = learners };
        return self.runControl(&cmd);
    }

    /// Enqueue a control command for the pump thread and block until it
    /// runs. Requires the pump thread (the only `Manager` toucher) to be
    /// live; the move path always runs under `startPump`.
    fn runControl(self: *Bridge, cmd: *ControlCmd) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pump_thread == null) return Error.PumpNotRunning;
            self.control_inbox.append(self.allocator, cmd) catch return Error.OutOfMemory;
        }
        cmd.done.wait();
        if (cmd.err) |e| return e;
    }

    /// Drain + execute queued control commands on the pump thread. Run
    /// from `pumpOnce` with the bridge mutex NOT held (the node ops
    /// re-enter via the commit hook). Returns true if any ran.
    fn drainControl(self: *Bridge) bool {
        var batch: [16]*ControlCmd = undefined;
        var n: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (n < batch.len and self.control_inbox.items.len > 0) {
                batch[n] = self.control_inbox.orderedRemove(0);
                n += 1;
            }
        }
        for (batch[0..n]) |cmd| {
            cmd.err = switch (cmd.kind) {
                .create_group_epoch => blk: {
                    // INVARIANT (enforced both ends): a baseline at index>0 MUST
                    // carry a real term. A term-0 baseline makes raft-rs's restore
                    // fast-forward commit_to past an empty log → fatal!. The producer
                    // (v2-applied-baseline) refuses to emit one (409); refuse to
                    // install one too rather than silently birthing a crash-prone group.
                    if (cmd.snap_index > 0 and cmd.snap_term == 0) {
                        std.log.err("v2 bridge: refusing term-0 baseline for gid {d} at index {d}", .{ cmd.gid, cmd.snap_index });
                        break :blk Error.InvalidBaseline;
                    }
                    _ = self.node.createGroupAtEpoch(cmd.gid, cmd.id_str, cmd.epoch, cmd.as_learner, cmd.birth_voters) catch |e| break :blk e;
                    // Atomic baseline (createGroupAtBaseline): install the data-free
                    // snapshot in the SAME pump op as group creation so the fresh
                    // group is never observable at last_index 0 between creation and
                    // baseline. Without this, a leader heartbeat carrying commit > 0
                    // can reach the empty group first and trip raft's commit_to
                    // fatal! (to_commit out of range [last_index 0]). If the install
                    // fails, TEAR THE HALF-BORN GROUP DOWN — leaving it live at
                    // last_index 0 is the exact window this path exists to close
                    // (a labeled break is not an error return, so errdefer won't
                    // fire here; roll back explicitly).
                    if (cmd.snap_index > 0) {
                        self.node.applyLocalSnapshot(cmd.gid, cmd.snap_index, cmd.snap_term, cmd.snap_voters, cmd.snap_learners) catch |e| {
                            self.node.destroyGroupAndReclaim(cmd.gid) catch |de|
                                std.log.err("v2 bridge: rollback of half-born gid {d} failed: {s}", .{ cmd.gid, @errorName(de) });
                            break :blk e;
                        };
                    }
                    break :blk null;
                },
                .destroy_group => blk: {
                    self.node.destroyGroupAndReclaim(cmd.gid) catch |e| break :blk e;
                    break :blk null;
                },
                .propose_conf_change => blk: {
                    self.node.proposeConfChange(cmd.gid, cmd.node_id, @enumFromInt(cmd.cc_type)) catch |e| break :blk e;
                    break :blk null;
                },
                .conf_state => blk: {
                    if (self.node.confState(cmd.gid, cmd.cs_voters, cmd.cs_learners)) |cs| {
                        cmd.cs_voters_len = cs.voters.len;
                        cmd.cs_learners_len = cs.learners.len;
                        cmd.cs_ok = true;
                    }
                    break :blk null;
                },
                .voter_progress => blk: {
                    if (self.node.voterProgress(cmd.gid, cmd.vp_ids, cmd.vp_matched, cmd.vp_active)) |vp| {
                        cmd.vp_len = vp.len;
                        cmd.vp_leader_last = vp.leader_last;
                        cmd.vp_ok = true;
                    }
                    break :blk null;
                },
                .log_entry => blk: {
                    if (cmd.entry_buf) |buf| {
                        if (self.node.logEntry(cmd.gid, cmd.snap_index, buf)) |e| {
                            cmd.snap_term = e.term;
                            cmd.entry_len = e.data.len;
                            cmd.lt_ok = true;
                        }
                    }
                    break :blk null;
                },
                .log_term => blk: {
                    if (self.node.logTerm(cmd.gid, cmd.snap_index)) |t| {
                        cmd.snap_term = t;
                        cmd.lt_ok = true;
                    }
                    break :blk null;
                },
                .last_index => blk: {
                    cmd.snap_index = self.node.lastIndex(cmd.gid);
                    break :blk null;
                },
                .baseline_index => blk: {
                    cmd.snap_index = self.node.baselineIndex(cmd.gid);
                    break :blk null;
                },
                .applied_raw => blk: {
                    cmd.snap_index = self.node.appliedRaw(cmd.gid);
                    break :blk null;
                },
                .durabilized_raw => blk: {
                    cmd.snap_index = self.node.durabilizedRaw(cmd.gid);
                    break :blk null;
                },
                .group_epoch => blk: {
                    cmd.snap_index = self.node.groupEpoch(cmd.gid);
                    break :blk null;
                },
                .apply_local_snapshot => blk: {
                    self.node.applyLocalSnapshot(cmd.gid, cmd.snap_index, cmd.snap_term, cmd.snap_voters, cmd.snap_learners) catch |e| break :blk e;
                    break :blk null;
                },
                .transfer_all_leadership => blk: {
                    // Graceful shutdown: hand off leadership of every group
                    // this node currently leads. Snapshot the led gids under
                    // the lock (reading each `is_leader` atomic, like
                    // `leadsAnyGroup`), then release it before driving the
                    // Manager — `transferLeadershipAway` is pump-side and
                    // takes no bridge lock.
                    var gids: std.ArrayListUnmanaged(u64) = .empty;
                    defer gids.deinit(self.allocator);
                    {
                        self.mutex.lock();
                        defer self.mutex.unlock();
                        var it = self.groups.iterator();
                        while (it.next()) |entry| {
                            if (entry.value_ptr.*.is_leader.load(.acquire))
                                gids.append(self.allocator, entry.key_ptr.*) catch {};
                        }
                    }
                    cmd.count = 0;
                    for (gids.items) |gid| {
                        if (self.node.transferLeadershipAway(gid) != null) cmd.count += 1;
                    }
                    break :blk null;
                },
                .transfer_leadership => blk: {
                    // Diagnostic/test: force a leadership handoff of ONE group to
                    // its most caught-up follower (no-op if not the leader). Used by
                    // the churn soak to flip leadership under in-flight writes.
                    cmd.count = if (self.node.transferLeadershipAway(cmd.gid) != null) 1 else 0;
                    break :blk null;
                },
            };
            cmd.done.set();
        }
        return n > 0;
    }

    // ── Pump (pump thread only) ──────────────────────────────────────

    /// Spawn the dedicated pump thread. Production entry point. Idempotent
    /// guard: a second call is a no-op.
    pub fn startPump(self: *Bridge) Error!void {
        if (self.pump_thread != null) return;
        self.stop.store(false, .release);
        self.pump_thread = std.Thread.spawn(.{}, pumpLoop, .{self}) catch return Error.Io;
    }

    /// Signal the pump thread to stop and join it. Then fail any still-
    /// in-flight proposes (faulted_seq = next_seq) so a parked worker
    /// stops waiting. Safe to call when no pump thread is running.
    pub fn stopPump(self: *Bridge) void {
        self.stop.store(true, .release);
        if (self.pump_thread) |t| {
            t.join();
            self.pump_thread = null;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        // Release any control-command waiter whose cmd was enqueued after
        // the pump's last drain (the `runControl` pump-alive check races
        // `stopPump`): the pump is gone, so the cmd will never execute —
        // without this the caller blocks on `cmd.done` forever.
        while (self.control_inbox.items.len > 0) {
            const cmd = self.control_inbox.orderedRemove(0);
            cmd.err = Error.ShuttingDown;
            cmd.done.set();
        }
        // Fail anything proposed-but-not-committed.
        var it = self.groups.valueIterator();
        while (it.next()) |sig_ptr| {
            const sig = sig_ptr.*;
            sig.faulted_seq.store(sig.next_seq, .release);
        }
    }

    fn pumpLoop(self: *Bridge) void {
        while (!self.stop.load(.acquire)) {
            // A pump error is an INFALLIBILITY VIOLATION, not an operational
            // hiccup: a committed entry failed to decode/apply (raft has
            // already consumed it via advance_apply — it will never be
            // redelivered, so this replica is silently diverged from the
            // log), or the WAL fsync failed (nothing acked from here on
            // would be durable), or allocation failed on the commit path.
            // Warn-and-continue (the old behavior) served a diverged
            // replica that could later win an election; die loudly instead
            // — a restart replays the WAL from the last checkpoint and
            // converges. (Tests drive `pumpOnce` directly and still see
            // error returns; boot-time recovery has its own retry-from-
            // scratch semantics in `recoverGroups`.)
            const did = self.pumpOnce() catch |e| {
                std.debug.panic("v2 bridge pump: unrecoverable apply/flush failure: {s}", .{@errorName(e)});
            };
            // Idle backoff: nothing to drain and nothing committed this
            // cycle. Single-node has no election/heartbeat traffic to
            // service, so a short sleep is fine; Phase 6 wires the
            // hibernation deadline / mailbox-driven wake here.
            if (!did) std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// One drain + pump cycle. Returns true if it proposed or committed
    /// anything this cycle. Pump-thread-only (touches the `Node`). Public
    /// so tests can drive the bridge deterministically without the thread.
    pub fn pumpOnce(self: *Bridge) Error!bool {
        // 1. Drain the inbox under the lock, then release it before any
        //    `node.*` call (ensureGroup/propose/pump must not run with
        //    the bridge mutex held — the commit hook re-acquires it).
        var batch: std.ArrayListUnmanaged(ProposeItem) = .empty;
        defer batch.deinit(self.allocator);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.inbox.items.len > 0) {
                batch.appendSlice(self.allocator, self.inbox.items) catch return Error.OutOfMemory;
                self.inbox.clearRetainingCapacity();
            }
        }

        var did_work = batch.items.len > 0;

        // 1b. Service move-orchestration control ops (group create-at-
        //     epoch / destroy) on the pump thread before proposes, so an
        //     attach's group exists before any post-move write lands.
        if (self.drainControl()) did_work = true;

        // 2. Submit each drained propose to its tenant's group, creating
        //    the group on first sight. Single-node: this drives it to
        //    leader. Multi-node: an already-formed group is found; if this
        //    node is NOT the group's leader, `node.propose` rejects and we
        //    FAULT the tenant's in-flight so the worker fails fast (503) and
        //    the client retries against the leader node.
        for (batch.items) |item| {
            defer self.allocator.free(item.payload);
            _ = self.node.ensureGroup(item.gid, item.id_str) catch |e| {
                std.log.warn("v2 bridge ensureGroup gid={d}: {s}", .{ item.gid, @errorName(e) });
                self.faultTenant(item.gid);
                continue;
            };
            self.node.proposeFramed(item.gid, self.origin_id, item.seq, item.payload) catch |e| {
                std.log.warn("v2 bridge propose gid={d}: {s}", .{ item.gid, @errorName(e) });
                self.faultTenant(item.gid);
            };
        }

        // 3. Drive one ready cycle: commits + applies + fires the commit
        //    hook (which advances committed_seq via the pending FIFO).
        const committed = self.node.pump() catch |e| {
            return e;
        };
        if (committed) did_work = true;

        // 4. Leadership-loss sweep: fault in-flight tenants this node no
        //    longer leads (an entry proposed here that will never commit
        //    locally because leadership moved). O(in-flight), bounded per
        //    cycle; the rest are swept next cycle.
        self.sweepLostLeadership();

        // 4b. Worker commit-wait timeouts, executed HERE so the fault is
        //     serialized against this thread's skip/commit decisions
        //     (see `requestFault`).
        self.drainFaultRequests();

        // 5. Publish each group's leadership for the worker thread (which
        //    must not touch the Manager). O(groups) per cycle — the same
        //    order as the active-set tick; pre-hibernation that is fine.
        self.refreshLeadership();

        // 6. Snapshot-trigger tick: detect peers in `StateSnapshot` (fell below
        //    the leader's compaction first_index under mechanism-A compaction)
        //    and enqueue an out-of-band catch-up for the worker thread. The
        //    native trigger that replaces the lockstep WAL floor.
        self.snapshotTriggerTick();

        return did_work;
    }

    /// How often `snapshotTriggerTick` scans the active set for `StateSnapshot`
    /// peers. The in-flight dedup means a re-scan while a transfer runs is a
    /// no-op, so this only bounds detection latency for a freshly-stranded peer.
    const SNAPSHOT_TRIGGER_INTERVAL_NS: i64 = 100 * std.time.ns_per_ms;

    /// Pump thread: over the active groups this node leads, find peers raft holds
    /// in `ProgressState::Snapshot` (the snapshot-free `snapshotCb` parks a peer
    /// here once it falls below the leader's compacted first_index) and enqueue an
    /// out-of-band catch-up for each. The baseline {index, term} is computed HERE
    /// (pump-only `baselineIndex` + `logTerm`); the worker's `SnapshotCatchupThread`
    /// dumps the store + pushes it to the peer. Interval-gated; reads pump-owned
    /// `node.active` + node accessors with the bridge mutex NOT held (enqueue takes
    /// it internally). O(active peers).
    fn snapshotTriggerTick(self: *Bridge) void {
        if (self.node.isSingleNode()) return;
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (now_ns - self.last_snapshot_trigger_ns < SNAPSHOT_TRIGGER_INTERVAL_NS) return;
        self.last_snapshot_trigger_ns = now_ns;
        var ids_buf: [16]u64 = undefined;
        for (self.node.active.items) |gid| {
            const peers = self.node.snapshotPendingPeers(gid, &ids_buf) orelse continue; // not leader / unknown
            if (peers.len == 0) continue;
            // Baseline the peer will install: the leader's live applied index +
            // the term of its log entry there. `logTerm` is null when the leader's
            // own log can't resolve a term (watermark drifted ahead of the log) —
            // skip this tick and retry once the log covers it, exactly as
            // `v2-applied-baseline` refuses rather than hand out a bogus term.
            const index = self.node.baselineIndex(gid);
            if (index == 0) continue; // nothing applied yet — nothing to snapshot
            const term = self.node.logTerm(gid, index) orelse continue;
            for (peers) |peer| {
                if (self.enqueueSnapshotCatchup(gid, peer, index, term)) {
                    std.log.info(
                        "v2 snapshot-trigger gid={d}: peer {d} in StateSnapshot — queued out-of-band catch-up to baseline {d}/{d}",
                        .{ gid, peer, index, term },
                    );
                }
            }
        }
    }

    /// How often `refreshLeadership` falls back to a FULL all-groups scan.
    /// Leadership edges on a ticking group are caught same-cycle via the
    /// active set; the full scan only bounds staleness for the rare edge
    /// with no wake (e.g. a partition-heal where a hibernated old leader's
    /// first post-heal message is a plain heartbeat that steps it down).
    const LEADER_SCAN_INTERVAL_NS: i64 = 50 * std.time.ns_per_ms;

    /// Refresh groups' `is_leader` atomics from the Manager. Per cycle this
    /// covers only the node's ACTIVE set — leadership can only change when
    /// a group processes ticks or messages, which (almost always — see
    /// `LEADER_SCAN_INTERVAL_NS`) implies it was woken into the active set
    /// earlier in the same pump cycle. A full all-groups scan runs
    /// interval-gated as the staleness backstop. The old shape scanned
    /// every registered group every cycle under the bridge mutex — an
    /// O(N_tenants) per-cycle hot-path cost that nullified hibernation's
    /// O(active) win at K=thousands. Pump-thread only (reads the Manager
    /// + `node.active`). The worker reads the atomics lock-free via
    /// `isLeaderOf`.
    fn refreshLeadership(self: *Bridge) void {
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        const full = now_ns - self.last_leader_scan_ns >= LEADER_SCAN_INTERVAL_NS;
        if (full) self.last_leader_scan_ns = now_ns;
        self.mutex.lock();
        defer self.mutex.unlock();
        const single = self.node.isSingleNode();
        if (full) {
            var it = self.groups.iterator();
            while (it.next()) |e| {
                self.refreshOneLocked(e.value_ptr.*, e.key_ptr.*, single);
            }
        } else {
            for (self.node.active.items) |gid| {
                const sig = self.groups.get(gid) orelse continue;
                self.refreshOneLocked(sig, gid, single);
            }
        }
    }

    /// Refresh one group's published leadership + detect the
    /// follower→leader promotion edge. Caller holds `mutex`; pump thread.
    fn refreshOneLocked(self: *Bridge, sig: *GroupSig, gid: u64, single: bool) void {
        const now = self.node.isLeader(gid);
        const promoted_edge = now and !sig.was_leader;
        // Count every false→true promotion edge (incl. single-node formation)
        // for the spurious-election metric; the reader nets out the expected
        // one-per-group baseline.
        if (promoted_edge) _ = self.leadership_acquisitions.fetchAdd(1, .monotonic);
        // false→true promotion edge: queue for the worker's on-promotion
        // recovery hook. Skipped on a single node — the sole voter leads
        // every group from creation and never fails over, so there is no
        // old-leader RAM state to reconstruct (and the leader already
        // loaded the deployment + armed watermarks inline at release).
        if (!single and promoted_edge) {
            self.promoted.append(self.allocator, sig.gid) catch {};
        }
        sig.was_leader = now;
        sig.is_leader.store(now, .release);
        sig.formed.store(self.node.hasGroup(gid), .release);
    }

    /// Drain the gids promoted (follower→leader) since the last call into
    /// `out` (up to `out.len`), returning each tenant's stable `id_str`
    /// (borrowed from its `GroupSig`, valid for the bridge lifetime). Returns
    /// the count written. Worker-thread entry point for the on-promotion hook;
    /// mutex-guarded against the pump's `refreshLeadership` append. Order is
    /// irrelevant (each promotion is processed idempotently), so this pops
    /// from the back. A queued gid whose group was destroyed (move) between
    /// the edge and the drain is skipped.
    /// Resolve a gid to its tenant `id_str` (borrowed, stable for the bridge
    /// lifetime), or null if the group is unregistered. Mutex-guarded; safe
    /// from any thread. Used by the DP apply observer (pump thread) to map an
    /// applied group's id to the tenant id the deployment loader keys on.
    pub fn idStrForGid(self: *Bridge, gid: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return null;
        return sig.id_str;
    }

    pub fn drainPromotions(self: *Bridge, out: [][]const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        while (n < out.len) {
            const gid = self.promoted.pop() orelse break;
            const sig = self.groups.get(gid) orelse continue;
            out[n] = sig.id_str;
            n += 1;
        }
        return n;
    }

    fn catchupKey(gid: u64, peer: u64) u128 {
        return (@as(u128, gid) << 64) | @as(u128, peer);
    }

    /// Pump thread: enqueue an out-of-band snapshot catch-up for a `StateSnapshot`
    /// peer, unless one is already in flight for this `(gid, peer)`. Returns true
    /// iff a job was queued (so the caller can log only on a fresh trigger). The
    /// baseline {index, term} was computed by the caller on the pump thread.
    pub fn enqueueSnapshotCatchup(self: *Bridge, gid: u64, peer: u64, index: u64, term: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const key = catchupKey(gid, peer);
        if (self.catchup_inflight.contains(key)) return false;
        self.snapshot_catchup.append(self.allocator, .{ .gid = gid, .peer = peer, .index = index, .term = term }) catch return false;
        self.catchup_inflight.put(self.allocator, key, {}) catch {
            // Couldn't mark in-flight — drop the job we just queued rather than
            // leave it un-deduped (it would be re-pushed every tick).
            _ = self.snapshot_catchup.pop();
            return false;
        };
        return true;
    }

    /// Worker thread: drain up to `out.len` catch-up jobs, resolving each gid's
    /// `id_str` (pointer-stable, like `drainPromotions`). The `(gid, peer)` stays
    /// in `catchup_inflight` until the worker calls `clearSnapshotCatchup` when the
    /// transfer finishes. Returns the populated prefix count.
    pub fn drainSnapshotCatchup(self: *Bridge, out: []SnapshotCatchup) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        while (n < out.len) {
            if (self.snapshot_catchup.items.len == 0) break;
            const job = self.snapshot_catchup.orderedRemove(0);
            const sig = self.groups.get(job.gid) orelse {
                // Group vanished between enqueue and drain — drop the in-flight mark.
                _ = self.catchup_inflight.remove(catchupKey(job.gid, job.peer));
                continue;
            };
            out[n] = .{ .gid = job.gid, .peer = job.peer, .index = job.index, .term = job.term, .id_str = sig.id_str };
            n += 1;
        }
        return n;
    }

    /// Worker thread: a catch-up transfer finished (success or failure) — clear the
    /// `(gid, peer)` in-flight mark so the pump re-triggers next tick if the peer is
    /// still behind (a failed push retries; a successful one clears `StateSnapshot`
    /// so `snapshotPendingPeers` no longer lists it).
    pub fn clearSnapshotCatchup(self: *Bridge, gid: u64, peer: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.catchup_inflight.remove(catchupKey(gid, peer));
    }

    /// Boot-time recovery: re-stand-up every tenant group this node persisted
    /// (its node-local manifest) so a restarted node rejoins its raft groups
    /// and catches up to the live state. For each recorded (id_str, epoch):
    /// `registerTenant` (rebuild the `GroupSig` so the worker can serve /
    /// propose / leader-probe the tenant) + `node.recoverGroup` (re-create the
    /// raft group from its durable WAL state). MUST be called BEFORE
    /// `startPump` — like the CP directory's boot `ensureGroup`, group
    /// lifecycle is single-threaded until the pump owns the (non-thread-safe)
    /// Manager. A per-group failure is logged + skipped (one bad group must not
    /// block the rest). Returns the count recovered. No-op on a fresh data dir.
    pub fn recoverGroups(self: *Bridge) usize {
        const groups = self.node.persistedGroups(self.allocator) catch |err| {
            std.log.warn("v2 bridge: recoverGroups manifest read failed: {s}", .{@errorName(err)});
            return 0;
        };
        defer Node.freePersistedGroups(self.allocator, groups);
        var n: usize = 0;
        for (groups) |g| {
            const gid = self.registerTenant(g.id_str) catch |err| {
                std.log.warn("v2 bridge: recoverGroups register {s} failed: {s}", .{ g.id_str, @errorName(err) });
                continue;
            };
            _ = self.node.recoverGroup(gid, g.id_str, g.epoch) catch |err| {
                std.log.warn("v2 bridge: recoverGroups group {s} failed: {s}", .{ g.id_str, @errorName(err) });
                continue;
            };
            n += 1;
            std.log.info("v2 bridge: recovered tenant group {s} (epoch {d})", .{ g.id_str, g.epoch });
        }
        return n;
    }

    /// Fault the in-flight proposes of any tenant this node no longer leads.
    /// Snapshots ALL of `in_flight` under the lock (it is O(in-flight
    /// tenants) by design — a fixed 32-slot snapshot with no cursor
    /// silently never checked the tail, so a tenant beyond the first 32
    /// ate the full commit-wait timeout instead of a fast 503), then
    /// checks leadership + faults outside it (the Manager call +
    /// `faultTenant` each take their own short critical sections).
    /// `sweep_scratch` is reused across cycles to avoid per-cycle
    /// allocation. Pump-thread only.
    fn sweepLostLeadership(self: *Bridge) void {
        self.sweep_scratch.clearRetainingCapacity();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.sweep_scratch.appendSlice(self.allocator, self.in_flight.items) catch return;
        }
        for (self.sweep_scratch.items) |g| {
            if (!self.node.isLeader(g)) self.faultTenant(g);
        }
    }

    // ── Commit hook + skip query (pump thread, via node.applyCb) ─────

    /// Bound to `Node.commit_hook`, fired post-fsync per committed real
    /// entry with the entry's IDENTITY (origin frame). Advances the
    /// tenant's committed_seq iff the entry is THIS bridge's own pending
    /// propose — see the file-header binding rationale. `raft_index` is
    /// recorded for the durabilize floor (worker-overlay ack tracking).
    fn onCommitted(ctx: *anyopaque, group_id: u64, origin: u64, seq: u64, raft_index: u64) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        // Not ours: a follower apply, another node's propose (a promoted
        // leader's catch-up), a replayed entry from a previous incarnation
        // (different boot origin), or a hookless propose (origin 0).
        // Nothing to advance — there is no local waiter bound to it.
        if (origin != self.origin_id) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(group_id) orelse return;
        // Identity pop: remove exactly THIS seq if it is still pending.
        // Gone already ⇒ the waiter gave up (fault / timeout → abandoned)
        // — the pump wrote the store (skipQuery said no skip), so the
        // data is intact; the watermark must not move for a waiter that
        // already saw 503 ("unknown outcome", may materialize later).
        const found = for (sig.pending.items, 0..) |s, i| {
            if (s == seq) break i;
        } else null;
        if (found) |i| {
            _ = sig.pending.orderedRemove(i);
            // worker_overlay: this entry's store write was SKIPPED on the
            // premise that the local worker txn commits it. Until the
            // worker acks (`noteWorkerCommitted`), `raft_index` caps the
            // durabilize floor — the fold cannot see an open txn, so
            // stamping/compacting past it would claim durability for
            // data that is not yet foldable. Best-effort append: on OOM
            // the floor is simply NOT raised conservatively… it must be
            // the opposite — failing to record would let durabilize run
            // PAST the entry. Surface it as a pump apply error instead.
            if (self.node.apply_mode == .worker_overlay and seq > sig.worker_acked_seq) {
                sig.awaiting_worker.append(self.allocator, .{ .seq = seq, .idx = raft_index }) catch {
                    // OOM recording this entry's durabilize-floor cap. We must
                    // NOT fall through to advance `committed_seq`: the worker
                    // folds on that watermark, and with the floor entry missing
                    // durabilize/compaction can run PAST this entry → false
                    // durability / premature fold (the exact unrepairable state
                    // — a fold has no rollback by construction). Set the fatal
                    // apply_err and bail; the pump aborts loudly before any
                    // unsafe fold. (Triage RC-1: bridge-OOM fall-through.)
                    self.node.apply_err = node_mod.Error.OutOfMemory;
                    return;
                };
            }
            // Proposes are per-tenant FIFO so commits arrive in seq order;
            // the monotonic max guard is belt-and-braces (a stale store
            // would strand later waiters, never wake one early).
            if (seq > sig.committed_seq.load(.acquire))
                sig.committed_seq.store(seq, .release);
            if (sig.pending.items.len == 0) self.removeInFlightLocked(group_id);
        }
    }

    /// Worker-thread ack that the speculative txn carrying every write
    /// up to and including `seq` has COMMITTED into the store's main
    /// overlay (kvexp fold-visible). Releases the durabilize floor for
    /// those entries — the pump may now stamp the store watermark and
    /// compact the WAL past them. `≤ seq` (not `== seq`) because a
    /// chunked multi-propose parks one txn on its LAST seq while the
    /// intermediate seqs share it. Lock-held scan is O(in-flight).
    pub fn noteWorkerCommitted(self: *Bridge, gid: u64, seq: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return;
        if (seq > sig.worker_acked_seq) sig.worker_acked_seq = seq;
        while (sig.awaiting_worker.items.len > 0 and sig.awaiting_worker.items[0].seq <= seq) {
            _ = sig.awaiting_worker.orderedRemove(0);
        }
    }

    /// True iff every committed entry up to `seq` has had its worker txn
    /// promoted into the store (`noteWorkerCommitted` received) — i.e.
    /// the store's foldable state fully covers the watermark through
    /// `seq`. The move source's bundle dump gates on this: `committedSeq
    /// >= seq` alone only proves raft commit + skip; the skipped writes
    /// live in parked worker txns until the drain promotes them, and a
    /// dump taken before that silently misses raft-committed data. Safe
    /// from any thread (mutex).
    pub fn workerAckedThrough(self: *Bridge, gid: u64, seq: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return true;
        // FIFO front = oldest un-acked entry.
        return sig.awaiting_worker.items.len == 0 or sig.awaiting_worker.items[0].seq > seq;
    }

    /// Bound to `Node.durabilize_floor` (pump thread): the highest raft
    /// index fully covered by the store's foldable overlay for `gid` —
    /// one less than the first committed-but-not-worker-acked entry's
    /// index, or unconstrained when nothing is awaited.
    fn durabilizeFloor(ctx: *anyopaque, gid: u64) u64 {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return std.math.maxInt(u64);
        if (sig.awaiting_worker.items.len == 0) return std.math.maxInt(u64);
        return sig.awaiting_worker.items[0].idx - 1;
    }

    /// Bound to `Node.skip_query` (worker-overlay apply). True iff this
    /// committed entry is the bridge's OWN still-pending propose — the
    /// local worker txn holds its writes and commits them on watermark
    /// advance, so the pump must not double-apply. Anything else (foreign
    /// origin, abandoned seq) must be written by the pump. Pump-thread;
    /// takes the mutex briefly. Pending can only shrink on the pump
    /// thread itself (commit hook / fault sweep / drainControl), so a
    /// true answer here cannot be invalidated before this entry's own
    /// post-flush commit notification fires later in the same cycle.
    fn skipQuery(ctx: *anyopaque, group_id: u64, origin: u64, seq: u64) bool {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        if (origin != self.origin_id) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(group_id) orelse return false;
        for (sig.pending.items) |s| {
            if (s == seq) return true;
        }
        return false;
    }

    /// Worker-thread notice that a parked propose hit its commit-wait
    /// DEADLINE. The worker must NOT roll its speculative txn back
    /// unilaterally — the pump may concurrently be skipping this very
    /// entry's store write on the premise that the txn will commit it
    /// (`skipQuery`). Instead the request queues here and the pump
    /// executes it (`drainFaultRequests`), serialized against its own
    /// skip/commit decisions: if the seq is STILL pending there, the
    /// whole tenant faults (`faultTenant` raises `faulted_seq`; the
    /// worker's next sweep rolls back on the `.fault` arm); if the seq
    /// already committed in the meantime, the request is a no-op and the
    /// worker's next sweep classifies `.commit` (committed beats
    /// faulted). A queue-append failure (OOM) just means the worker
    /// re-requests next tick — the deadline already passed.
    pub fn requestFault(self: *Bridge, gid: u64, seq: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fault_requests.append(self.allocator, .{ .gid = gid, .seq = seq }) catch {};
    }

    /// Execute queued timeout-fault requests (pump thread, from
    /// `pumpOnce` after `node.pump`). Bounded batch; the rest run next
    /// cycle. See `requestFault` for the still-pending guard rationale.
    fn drainFaultRequests(self: *Bridge) void {
        var batch: [32]FaultReq = undefined;
        var n: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (n < batch.len and self.fault_requests.items.len > 0) {
                batch[n] = self.fault_requests.orderedRemove(0);
                n += 1;
            }
        }
        for (batch[0..n]) |req| {
            // Fault only if the seq is still pending: it may have
            // committed between the worker's timeout and this drain —
            // commit wins, and faulting the tenant then would 503 its
            // healthy LATER proposes for nothing.
            const still_pending = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const sig = self.groups.get(req.gid) orelse break :blk false;
                for (sig.pending.items) |s| {
                    if (s == req.seq) break :blk true;
                }
                break :blk false;
            };
            if (still_pending) self.faultTenant(req.gid);
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a type-0 writeset envelope for `id_str` carrying `ws`. Mirrors
/// what the worker seam will hand `propose`. Caller transfers ownership
/// of the returned bytes to `propose`.
fn encodeWs(a: std.mem.Allocator, id_str: []const u8, ws: *const WriteSet) ![]u8 {
    const ws_bytes = try ws.encode(a);
    defer a.free(ws_bytes);
    return envelope.encodeWriteSet(a, id_str, ws_bytes);
}

test "bridge: propose → pumpOnce commits → committedSeq advances, read sees write" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();

    const gid = try bridge.registerTenant("tenant-1");

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("greeting", "hello-bridge");

    const env = try encodeWs(a, "tenant-1", &ws);
    defer a.free(env); // propose copies, so the test still owns env
    const seq = try bridge.propose(gid, env);
    try testing.expectEqual(@as(u64, 1), seq);
    try testing.expectEqual(@as(u64, 0), bridge.committedSeq(gid));

    // Drive the pump deterministically (no thread): first cycle proposes
    // + creates the group; subsequent cycles commit + apply.
    var spins: u32 = 0;
    while (bridge.committedSeq(gid) < seq and spins < 200) : (spins += 1) {
        _ = try bridge.pumpOnce();
    }
    try testing.expectEqual(seq, bridge.committedSeq(gid));

    // Pump thread is not running, so reading the node's store on this
    // thread is race-free (2a; the cross-thread two-handle model is 2b).
    const got = try bridge.node.get(gid, "greeting");
    defer a.free(got);
    try testing.expectEqualStrings("hello-bridge", got);
}

test "bridge: two tenants' watermarks advance independently (no cross-tenant HOL)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();

    const ga = try bridge.registerTenant("alice");
    const gb = try bridge.registerTenant("bob");
    try testing.expect(ga != gb);

    // Interleave proposes across the two tenants: A, B, A.
    var wa1 = WriteSet.init(a);
    defer wa1.deinit();
    try wa1.addPut("k", "a1");
    const ea1 = try encodeWs(a, "alice", &wa1);
    defer a.free(ea1);
    const sa1 = try bridge.propose(ga, ea1);

    var wb1 = WriteSet.init(a);
    defer wb1.deinit();
    try wb1.addPut("k", "b1");
    const eb1 = try encodeWs(a, "bob", &wb1);
    defer a.free(eb1);
    const sb1 = try bridge.propose(gb, eb1);

    var wa2 = WriteSet.init(a);
    defer wa2.deinit();
    try wa2.addPut("k", "a2");
    const ea2 = try encodeWs(a, "alice", &wa2);
    defer a.free(ea2);
    const sa2 = try bridge.propose(ga, ea2);

    // Per-tenant monotonic seqs: alice {1,2}, bob {1}.
    try testing.expectEqual(@as(u64, 1), sa1);
    try testing.expectEqual(@as(u64, 1), sb1);
    try testing.expectEqual(@as(u64, 2), sa2);

    var spins: u32 = 0;
    while ((bridge.committedSeq(ga) < sa2 or bridge.committedSeq(gb) < sb1) and spins < 400) : (spins += 1) {
        _ = try bridge.pumpOnce();
    }

    // Each tenant's watermark reflects ONLY its own proposes — bob at 1,
    // alice at 2 — proving the two logs commit independently (no shared
    // contiguous seq that would stall one behind the other).
    try testing.expectEqual(@as(u64, 2), bridge.committedSeq(ga));
    try testing.expectEqual(@as(u64, 1), bridge.committedSeq(gb));

    const a_val = try bridge.node.get(ga, "k");
    defer a.free(a_val);
    try testing.expectEqualStrings("a2", a_val);
    const b_val = try bridge.node.get(gb, "k");
    defer a.free(b_val);
    try testing.expectEqualStrings("b1", b_val);
}

test "bridge: pump thread drives commits end to end" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();

    const gid = try bridge.registerTenant("threaded");
    try bridge.startPump();

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    const env = try encodeWs(a, "threaded", &ws);
    defer a.free(env);
    const seq = try bridge.propose(gid, env);

    // Poll the lock-free watermark while the pump thread commits.
    var spins: u32 = 0;
    while (bridge.committedSeq(gid) < seq and spins < 2000) : (spins += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(seq, bridge.committedSeq(gid));

    // Quiesce the pump before reading the node store on this thread.
    bridge.stopPump();
    const got = try bridge.node.get(gid, "k");
    defer a.free(got);
    try testing.expectEqualStrings("v", got);
}

test "bridge: move control — attach at epoch, destroy reclaims" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();
    try bridge.startPump();

    // Destination-attach shape: register the tenant, then stand up its
    // group at a migration epoch (epoch+1 over the source's birth epoch).
    const gid = try bridge.registerTenant("mover");
    try bridge.createGroupEpoch(gid, 1, null);

    // A post-attach write commits through the freshly-attached group.
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "after-move");
    const env = try encodeWs(a, "mover", &ws);
    defer a.free(env);
    const seq = try bridge.propose(gid, env);
    var spins: u32 = 0;
    while (bridge.committedSeq(gid) < seq and spins < 2000) : (spins += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(seq, bridge.committedSeq(gid));

    // Source cleanup: destroy the group + reclaim its WAL. The node slot
    // is gone afterward (a read on the node store errors UnknownGroup).
    try bridge.destroyGroup(gid);
    try testing.expectError(node_mod.Error.UnknownGroup, bridge.node.get(gid, "k"));

    bridge.stopPump();
}

test "bridge: gid is a deterministic hash of the tenant id" {
    // The cross-node agreement property multi-node replication needs: the
    // same tenant id maps to the same raft group id everywhere, distinct
    // ids (almost surely) differ, and the id is never the reserved 0.
    try testing.expectEqual(Bridge.tenantGid("alice"), Bridge.tenantGid("alice"));
    try testing.expect(Bridge.tenantGid("alice") != Bridge.tenantGid("bob"));
    try testing.expect(Bridge.tenantGid("anything") != 0);
}

test "Phase 5c: 3-bridge cluster replicates via the leader; a follower propose is refused" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const voters = [_]u64{ 1, 2, 3 };
    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/b1", .{root}),
        try std.fmt.allocPrint(a, "{s}/b2", .{root}),
        try std.fmt.allocPrint(a, "{s}/b3", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    // Same PID-strided, bind-retry port allocation as the node test (this
    // test also runs in parallel with sibling test binaries).
    var bridges: [3]*Bridge = undefined;
    var alive = [_]bool{ false, false, false };
    defer for (bridges, 0..) |b, i| if (alive[i]) b.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    var attempt: u32 = 0;
    while (attempt < 24) : (attempt += 1) {
        const bp: u16 = @intCast(24000 + ((pid +% attempt *% 619) % 4000) * 8);
        var ok = true;
        for (0..3) |i| {
            var peers: [3]node_mod.PeerAddr = undefined;
            for (&peers, 0..) |*p, k| p.* = .{ .host = "127.0.0.1", .port = bp + @as(u16, @intCast(k)) };
            const addr = std.net.Address.parseIp("127.0.0.1", bp + @as(u16, @intCast(i))) catch {
                ok = false;
                break;
            };
            bridges[i] = Bridge.initMultiNode(a, dirs[i], @intCast(i + 1), &voters, addr, &peers) catch {
                ok = false;
                break;
            };
            alive[i] = true;
        }
        if (ok) break;
        for (0..3) |i| if (alive[i]) {
            bridges[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1] and alive[2])) return error.SkipZigTest;

    // Every node derives the SAME gid for the tenant.
    const gid = try bridges[0].registerTenant("t");
    try testing.expectEqual(gid, try bridges[1].registerTenant("t"));
    try testing.expectEqual(gid, try bridges[2].registerTenant("t"));

    // Form the group on all three. This test drives `pumpOnce` itself (the
    // test thread IS the pump thread), so it touches the Node directly
    // rather than the pump-thread control queue.
    for (bridges) |b| _ = try b.node.ensureGroup(gid, "t");

    var warm: u32 = 0;
    while (warm < 150) : (warm += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try bridges[0].node.campaign(gid);

    var leader: ?usize = null;
    var spins: u32 = 0;
    while (spins < 2000 and leader == null) : (spins += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        for (bridges, 0..) |b, i| if (b.node.isLeader(gid)) {
            leader = i;
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(leader != null);

    // Propose via the leader bridge; drive until every node's store applies
    // it (apply_on_commit default — no real worker, so the pump writes).
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    const env = try encodeWs(a, "t", &ws);
    defer a.free(env);
    const seq = try bridges[leader.?].propose(gid, env);

    var done = false;
    var s2: u32 = 0;
    while (s2 < 2000 and !done) : (s2 += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        done = true;
        for (bridges) |b| {
            const v = b.node.get(gid, "k") catch {
                done = false;
                break;
            };
            a.free(v);
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(done);
    // The leader's watermark advanced to EXACTLY the proposed seq (the
    // pending-FIFO binding, not a count).
    try testing.expectEqual(seq, bridges[leader.?].committedSeq(gid));

    // A propose on a FOLLOWER is refused synchronously (NotLeader,
    // decisions.md §10.5c): nothing enters the inbox or the raft log, so
    // the worker maps it to a retry-safe 421 and the proxy re-aims at the
    // leader. (Pre-§10.5c this faulted asynchronously — and raft-rs 0.7's
    // proposal forwarding meant the entry could still commit cluster-wide
    // while the local seq faulted: "write failed" with the write durable.)
    const follower = (leader.? + 1) % 3;
    try testing.expectError(Error.NotLeader, bridges[follower].propose(gid, env));
    // ...and the refused propose never commits: pump everyone a while and
    // assert the follower's watermarks are unmoved and the leader's store
    // saw no second write.
    const f_committed = bridges[follower].committedSeq(gid);
    const f_faulted = bridges[follower].faultedSeq(gid);
    var s3: u32 = 0;
    while (s3 < 100) : (s3 += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(f_committed, bridges[follower].committedSeq(gid));
    try testing.expectEqual(f_faulted, bridges[follower].faultedSeq(gid));
}

test "bridge: identity binding — foreign + faulted entries write the store and never credit a waiter" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();
    // Worker-overlay mode with a resolver: the pump's skip decision is
    // provenance-keyed (skipQuery), and non-skipped writes land in the
    // "worker's" store — here a test store standing in for inst.kv.
    bridge.setWorkerOverlay();
    const store_path = try std.fmt.allocPrintSentinel(a, "{s}/worker.db", .{dir}, 0);
    defer a.free(store_path);
    const worker_store = try node_mod.KvStore.open(a, store_path);
    defer worker_store.close();
    const Res = struct {
        store: *node_mod.KvStore,
        fn resolve(ctx: *anyopaque, gid: u64, id_str: []const u8) ?*node_mod.KvStore {
            _ = gid;
            _ = id_str;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.store;
        }
    };
    var res: Res = .{ .store = worker_store };
    bridge.setStoreResolver(.{ .ctx = &res, .func = Res.resolve });

    const gid = try bridge.registerTenant("ten");

    // Baseline: a live bridge propose is SKIPPED by the pump (the
    // "worker txn" owns it) and advances the watermark to exactly its seq.
    var ws1 = WriteSet.init(a);
    defer ws1.deinit();
    try ws1.addPut("mine", "v1");
    const e1 = try encodeWs(a, "ten", &ws1);
    defer a.free(e1);
    const s1 = try bridge.propose(gid, e1);
    var spins: u32 = 0;
    while (bridge.committedSeq(gid) < s1 and spins < 400) : (spins += 1) {
        _ = try bridge.pumpOnce();
    }
    try testing.expectEqual(s1, bridge.committedSeq(gid));
    // Skipped: the pump did NOT write the worker store (no worker here
    // to commit the txn, so the key is simply absent).
    try testing.expectError(node_mod.Error.NotFound, worker_store.get("mine"));

    // FOREIGN entry (origin 0 ≠ bridge origin — stands in for another
    // node's propose arriving at a promoted leader): the pump must
    // WRITE it (no local txn exists) and must NOT advance the watermark.
    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addPut("foreign", "vf");
    const e2 = try encodeWs(a, "ten", &ws2);
    defer a.free(e2);
    try bridge.node.propose(gid, e2); // hookless: origin = seq = 0
    spins = 0;
    while (spins < 400) : (spins += 1) {
        _ = try bridge.pumpOnce();
        if (worker_store.get("foreign")) |v| {
            a.free(v);
            break;
        } else |_| {}
    }
    const fv = try worker_store.get("foreign");
    defer a.free(fv);
    try testing.expectEqualStrings("vf", fv);
    try testing.expectEqual(s1, bridge.committedSeq(gid)); // unchanged

    // FAULTED-then-committed: propose via the bridge, fault the tenant
    // BEFORE the pump submits it (the waiter gives up, txn rolled back),
    // then let it commit anyway. The pump must WRITE the store (skip
    // would assume a txn that no longer exists) and must NOT advance
    // the watermark for the gone waiter.
    var ws3 = WriteSet.init(a);
    defer ws3.deinit();
    try ws3.addPut("late", "vl");
    const e3 = try encodeWs(a, "ten", &ws3);
    defer a.free(e3);
    const s3 = try bridge.propose(gid, e3);
    bridge.faultTenant(gid);
    try testing.expect(bridge.faultedSeq(gid) >= s3);
    spins = 0;
    while (spins < 400) : (spins += 1) {
        _ = try bridge.pumpOnce();
        if (worker_store.get("late")) |v| {
            a.free(v);
            break;
        } else |_| {}
    }
    const lv = try worker_store.get("late");
    defer a.free(lv);
    try testing.expectEqualStrings("vl", lv);
    try testing.expectEqual(s1, bridge.committedSeq(gid)); // still s1
}

test "bridge: durabilize floor holds until the worker acks the skipped entry's txn" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();
    bridge.setWorkerOverlay();
    bridge.node.durabilize_interval_ns = 0; // fold every cycle

    const store_path = try std.fmt.allocPrintSentinel(a, "{s}/worker.db", .{dir}, 0);
    defer a.free(store_path);
    const worker_store = try node_mod.KvStore.open(a, store_path);
    defer worker_store.close();
    const Res = struct {
        store: *node_mod.KvStore,
        fn resolve(ctx: *anyopaque, gid: u64, id_str: []const u8) ?*node_mod.KvStore {
            _ = gid;
            _ = id_str;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.store;
        }
    };
    var res: Res = .{ .store = worker_store };
    bridge.setStoreResolver(.{ .ctx = &res, .func = Res.resolve });

    const gid = try bridge.registerTenant("flo");
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    const env = try encodeWs(a, "flo", &ws);
    defer a.free(env);
    const seq = try bridge.propose(gid, env);
    var spins: u32 = 0;
    while (bridge.committedSeq(gid) < seq and spins < 400) : (spins += 1) {
        _ = try bridge.pumpOnce();
    }
    try testing.expectEqual(seq, bridge.committedSeq(gid));

    // The entry was SKIPPED (live own propose) and the "worker" has not
    // committed its txn: many durabilize ticks may pass, but the fold
    // watermark must stay BELOW the entry's applied index — stamping it
    // (and compacting the WAL) would claim durability for data still in
    // the open txn.
    spins = 0;
    while (spins < 10) : (spins += 1) _ = try bridge.pumpOnce();
    const slot = bridge.node.groups.get(gid).?;
    try testing.expect(slot.durabilized_idx < slot.applied_idx);
    try testing.expect(slot.in_dirty); // retained for a later tick

    // Worker ack: the txn promoted. The next durabilize folds + stamps
    // through the entry and the slot drains from the dirty set.
    bridge.noteWorkerCommitted(gid, seq);
    spins = 0;
    while (slot.durabilized_idx < slot.applied_idx and spins < 10) : (spins += 1) {
        _ = try bridge.pumpOnce();
    }
    try testing.expectEqual(slot.applied_idx, slot.durabilized_idx);
    try testing.expect(!slot.in_dirty);
}

test "bridge: catch-up baseline index never exceeds the durable snapshot content watermark" {
    // RC-1 regression (the prod __auth__ store fork). The out-of-band catch-up /
    // move ships {baseline index, snapshot}. The snapshot (StreamDumper.openSnapshot)
    // reflects the COMMITTED/folded overlay, whose watermark is `durabilized_idx`.
    // The baseline index MUST be <= that, or the receiver's apply_local_snapshot
    // fast-forwards commit PAST writes the snapshot lacks -> permanent store fork at
    // an agreed log index. The dangerous window: a worker_overlay own-propose whose
    // entry is APPLIED (applied_idx bumped) but not yet FOLDED (worker txn open), so
    // applied_idx > durabilized_idx. Before the fix the baseline source returned
    // applied_idx (over-claim); it must return the folded watermark.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();
    bridge.setWorkerOverlay();
    bridge.node.durabilize_interval_ns = 0; // fold every cycle

    const store_path = try std.fmt.allocPrintSentinel(a, "{s}/worker.db", .{dir}, 0);
    defer a.free(store_path);
    const worker_store = try node_mod.KvStore.open(a, store_path);
    defer worker_store.close();
    const Res = struct {
        store: *node_mod.KvStore,
        fn resolve(ctx: *anyopaque, gid: u64, id_str: []const u8) ?*node_mod.KvStore {
            _ = gid;
            _ = id_str;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.store;
        }
    };
    var res: Res = .{ .store = worker_store };
    bridge.setStoreResolver(.{ .ctx = &res, .func = Res.resolve });

    const gid = try bridge.registerTenant("flo");

    // Write 1: propose, commit, ack the worker txn, and let durabilize FOLD it.
    // durabilized_idx now tracks a real folded entry (not 0).
    var ws1 = WriteSet.init(a);
    defer ws1.deinit();
    try ws1.addPut("k1", "v1");
    const env1 = try encodeWs(a, "flo", &ws1);
    defer a.free(env1);
    const seq1 = try bridge.propose(gid, env1);
    var spins: u32 = 0;
    while (bridge.committedSeq(gid) < seq1 and spins < 400) : (spins += 1) _ = try bridge.pumpOnce();
    try testing.expectEqual(seq1, bridge.committedSeq(gid));
    bridge.noteWorkerCommitted(gid, seq1);
    const slot = bridge.node.groups.get(gid).?;
    spins = 0;
    while (slot.durabilized_idx < slot.applied_idx and spins < 20) : (spins += 1) _ = try bridge.pumpOnce();
    try testing.expectEqual(slot.applied_idx, slot.durabilized_idx);
    const folded = slot.durabilized_idx;
    try testing.expect(folded > 0);

    // Write 2: propose + commit but do NOT ack the worker txn — durabilize cannot
    // fold past it, so applied_idx advances ABOVE durabilized_idx (the fold-lag
    // window). The folded snapshot still only contains write 1.
    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addPut("k2", "v2");
    const env2 = try encodeWs(a, "flo", &ws2);
    defer a.free(env2);
    const seq2 = try bridge.propose(gid, env2);
    spins = 0;
    while (bridge.committedSeq(gid) < seq2 and spins < 400) : (spins += 1) _ = try bridge.pumpOnce();
    spins = 0;
    while (spins < 10) : (spins += 1) _ = try bridge.pumpOnce();
    try testing.expect(slot.durabilized_idx < slot.applied_idx); // window exists
    try testing.expectEqual(folded, slot.durabilized_idx); // snapshot still = write 1

    // THE INVARIANT: the baseline index shipped with the (folded) snapshot must not
    // exceed what the snapshot contains. RED before the fix (returned applied_idx).
    try testing.expect(bridge.node.baselineIndex(gid) <= slot.durabilized_idx);
    try testing.expectEqual(slot.durabilized_idx, bridge.node.baselineIndex(gid));
}

test "bridge: createGroupEpoch requires a running pump thread" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const bridge = try Bridge.initSingleNode(a, dir);
    defer bridge.deinit();
    const gid = try bridge.registerTenant("x");
    // No startPump → control ops have no executor.
    try testing.expectError(Error.PumpNotRunning, bridge.createGroupEpoch(gid, 1, null));
}
