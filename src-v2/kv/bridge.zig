//! V2 data-plane bridge — the worker-facing seam over the per-tenant pump.
//!
//! docs/v2-build-order.md §Phase 2: swap the V1 *cluster-wide* raft
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
//! ## Seq ↔ commit binding (explicit per-entry FIFO — Phase 5)
//!
//! `propose` assigns `seq = ++sig.next_seq` and pushes it onto the
//! tenant's `pending` FIFO **in the same critical section** as the inbox
//! append, so per-tenant seq order == inbox order == (FIFO pump drain) ==
//! raft index order == commit order. The commit hook pops the FIFO front
//! and sets `committed_seq` to that seq — **but only when this node is the
//! group's leader**.
//!
//! Phase-2 used a simpler *counting* binding (Nth commit = seq N). That is
//! wrong under multi-node: (a) a propose can fail (this node isn't the
//! leader) so its seq never commits, and (b) a FOLLOWER applies entries
//! replicated from another leader — committed entries with no local
//! proposer — which counting would mis-attribute to a local waiter. The
//! leader-gated FIFO pop fixes both: followers never advance the watermark
//! (no local waiter), and a propose that can't commit here is FAULTED
//! (`faulted_seq`) by the pump — at submit (`node.propose` rejected) or by
//! the per-cycle leadership-loss sweep — so the parked worker fails fast
//! (503) and the client retries against the leader node. A write in flight
//! at the *instant* of a leader change is faulted + retried, not silently
//! lost; live re-fencing under continuous load is Phase 7.

const std = @import("std");
const node_mod = @import("node.zig");
const envelope = @import("envelope.zig");

pub const Node = node_mod.Node;
pub const WriteSet = node_mod.WriteSet;
pub const PeerAddr = node_mod.PeerAddr;
pub const StoreResolver = node_mod.StoreResolver;

pub const Error = error{
    /// `propose` / `committedSeq` named a gid with no registered tenant.
    UnknownTenant,
    /// The bridge is shutting down; no further proposes accepted.
    ShuttingDown,
    /// A `propose` arrived for a tenant the move orchestration has
    /// quiesced (`quiesce`) — its writes are held while its bundle ships
    /// to the destination cluster (docs/v2-build-order.md §Phase 4).
    Quiesced,
    /// A control command (`createGroupEpoch` / `destroyGroup`) could not
    /// be serviced because the pump thread is not running.
    PumpNotRunning,
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
    /// FIFO of proposed-but-not-yet-committed seqs (front = oldest), the
    /// explicit per-entry seq↔commit binding that replaces Phase-2's
    /// counting (multi-node breaks counting: a follower applies entries
    /// from another leader, which the commit hook must NOT attribute to a
    /// local proposer). Pushed by `propose`, popped by the commit hook
    /// **only when this node is the group's leader**, cleared on fault.
    /// Guarded by `Bridge.mutex`.
    pending: std.ArrayListUnmanaged(u64) = .empty,
    /// Set by `quiesce` while this tenant is being moved off the node:
    /// `propose` rejects (`Error.Quiesced`) so no new write is admitted
    /// once the bundle snapshot is being taken. Single writer at a time
    /// (the move orchestration); read lock-free on the propose path.
    quiescing: std.atomic.Value(bool) = .init(false),
};

/// A pump-thread-only control operation, handed worker thread → pump
/// thread (the `Manager` is not thread-safe; group lifecycle must run on
/// the pump thread alongside `processReady`). The caller stack-allocates
/// one, enqueues a pointer, and blocks on `done` until the pump has
/// executed it and stamped `err` — so the struct outlives the wait.
const ControlCmd = struct {
    const Kind = enum { create_group_epoch, destroy_group };
    kind: Kind,
    gid: u64,
    /// Borrowed from the gid's `GroupSig.id_str` (pointer-stable); used by
    /// `create_group_epoch` to open the tenant's group store.
    id_str: []const u8 = &.{},
    epoch: u64 = 0,
    /// Result, written by the pump before signaling `done`.
    err: ?Error = null,
    done: std.Thread.ResetEvent = .{},
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
    /// Move-orchestration control ops awaiting the pump thread (group
    /// create-at-epoch / destroy). Pointers to caller-stack `ControlCmd`s;
    /// guarded by `mutex`. Drained + executed in `pumpOnce`.
    control_inbox: std.ArrayListUnmanaged(*ControlCmd) = .empty,

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
        self.* = .{ .allocator = allocator, .node = node };
        node.commit_hook = .{ .ctx = self, .func = onCommitted };
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
            a.free(sig.id_str);
            a.destroy(sig);
        }
        self.groups.deinit(a);
        self.by_id.deinit(a);
        self.in_flight.deinit(a);
        // Any items still queued at teardown own their payloads.
        for (self.inbox.items) |item| a.free(item.payload);
        self.inbox.deinit(a);
        // Control commands are caller-stack-owned; just drop the pointers.
        // (stopPump joined the pump thread, so nothing is mid-execute, and
        // any waiter was released by stopPump's fault path / will time out
        // — the move path never tears the bridge down mid-control.)
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
        // Held while the tenant is mid-move: refuse new writes so the
        // source bundle snapshot is a quiescent point (Phase 4).
        if (sig.quiescing.load(.acquire)) return Error.Quiesced;
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

    /// Node-wide leader check the reused worker uses to gate proposes
    /// (config mirror, deploy markers). Single-node V2 is the only node,
    /// so it is the leader of EVERY tenant group — always true. Matches
    /// V1's no-arg `RaftNode.isLeader()` shape so the worker call sites
    /// need no edits. Phase 5 (multi-node) reintroduces per-group
    /// leadership (`isLeader(gid)`).
    pub fn isLeader(self: *Bridge) bool {
        _ = self;
        return true;
    }

    /// Per-group leadership (Phase 5 multi-node). True when this node is the
    /// raft leader of `gid`'s group — used to leader-gate the move surface
    /// (`v2-bundle` / `v2-kv` PUT reject fast on a follower so the front
    /// door retries the leader, avoiding a non-leader speculative write that
    /// never replicates) and to let the move orchestrator await a freshly
    /// formed destination group's election (`v2-leader`). On a SINGLE-node
    /// node the sole voter leads every group it creates, so this is
    /// unconditionally true (matching the no-arg `isLeader`); the per-group
    /// `mgr.isLeader` would otherwise read false for a tenant whose group
    /// has not yet been lazily created on the single node. Reads the
    /// pump-published `is_leader` atomic (never the Manager directly), so it
    /// is worker-thread-safe and one pump cycle stale at worst.
    pub fn isLeaderOf(self: *Bridge, gid: u64) bool {
        if (self.node.isSingleNode()) return true;
        const sig = self.sigFor(gid) orelse return false;
        return sig.is_leader.load(.acquire);
    }

    // ── Move control (any thread; executes on the pump thread) ───────

    /// Quiesce a tenant for a move: stop admitting new proposes
    /// (`Error.Quiesced`) and return the highest seq already accepted, so
    /// the caller can wait for `committedSeq(gid) >= that` to know the
    /// in-flight writes have drained to `applied == committed`. The bundle
    /// snapshot is then a consistent point. Idempotent. `Error.UnknownTenant`
    /// if the gid is unregistered. (docs/v2-build-order.md §Phase 4 quiesce.)
    pub fn quiesce(self: *Bridge, gid: u64) Error!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(gid) orelse return Error.UnknownTenant;
        sig.quiescing.store(true, .release);
        return sig.next_seq;
    }

    /// Lift a `quiesce` (move aborted / never completed). Re-admits
    /// proposes. On a *successful* move the source group is destroyed
    /// instead, so this is the abort/rollback seam. Idempotent.
    pub fn unquiesce(self: *Bridge, gid: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.groups.get(gid)) |sig| sig.quiescing.store(false, .release);
    }

    /// Attach a freshly-loaded tenant's raft group at `epoch` on the pump
    /// thread (move destination). The tenant must already be
    /// `registerTenant`'d (so `gid` resolves and `id_str` is stable) and
    /// its kvexp state already loaded into the worker store. Blocks until
    /// the pump has created + led the group. (Phase 4 destination attach.)
    pub fn createGroupEpoch(self: *Bridge, gid: u64, epoch: u64) Error!void {
        const sig = self.sigFor(gid) orelse return Error.UnknownTenant;
        var cmd: ControlCmd = .{ .kind = .create_group_epoch, .gid = gid, .id_str = sig.id_str, .epoch = epoch };
        return self.runControl(&cmd);
    }

    /// Destroy a tenant's raft group + reclaim its WAL on the pump thread
    /// (move source cleanup). Blocks until done. (Phase 4 source evict.)
    pub fn destroyGroup(self: *Bridge, gid: u64) Error!void {
        var cmd: ControlCmd = .{ .kind = .destroy_group, .gid = gid };
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
                    _ = self.node.createGroupAtEpoch(cmd.gid, cmd.id_str, cmd.epoch) catch |e| break :blk e;
                    break :blk null;
                },
                .destroy_group => blk: {
                    self.node.destroyGroupAndReclaim(cmd.gid) catch |e| break :blk e;
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
        // Fail anything proposed-but-not-committed.
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.groups.valueIterator();
        while (it.next()) |sig_ptr| {
            const sig = sig_ptr.*;
            sig.faulted_seq.store(sig.next_seq, .release);
        }
    }

    fn pumpLoop(self: *Bridge) void {
        while (!self.stop.load(.acquire)) {
            const did = self.pumpOnce() catch |e| blk: {
                std.log.warn("v2 bridge pump: {s}", .{@errorName(e)});
                break :blk false;
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
            self.node.propose(item.gid, item.payload) catch |e| {
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

        // 5. Publish each group's leadership for the worker thread (which
        //    must not touch the Manager). O(groups) per cycle — the same
        //    order as the active-set tick; pre-hibernation that is fine.
        self.refreshLeadership();

        return did_work;
    }

    /// Refresh every registered group's `is_leader` atomic from the Manager.
    /// Pump-thread only (reads the Manager). Held under the bridge mutex —
    /// brief; no commit hook re-enters here (we are past `node.pump`). The
    /// worker reads these atomics lock-free via `isLeaderOf`.
    fn refreshLeadership(self: *Bridge) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.groups.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.is_leader.store(self.node.isLeader(e.key_ptr.*), .release);
        }
    }

    /// Fault the in-flight proposes of any tenant this node no longer leads.
    /// Snapshots `in_flight` under the lock, then checks leadership +
    /// faults outside it (the Manager call + `faultTenant` each take their
    /// own short critical sections). Pump-thread only.
    fn sweepLostLeadership(self: *Bridge) void {
        var snapshot: [32]u64 = undefined;
        var n: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.in_flight.items) |g| {
                if (n >= snapshot.len) break;
                snapshot[n] = g;
                n += 1;
            }
        }
        for (snapshot[0..n]) |g| {
            if (!self.node.isLeader(g)) self.faultTenant(g);
        }
    }

    // ── Commit hook (pump thread, via node.applyCb) ──────────────────

    /// Bound to `Node.commit_hook`. Fires once per committed real entry,
    /// in per-tenant commit order. Advances the tenant's committed_seq by
    /// one (the counting binding — see file header). `raft_index` is
    /// unused under counting but kept in the signature for the Phase-5
    /// switch to explicit per-entry seqs.
    fn onCommitted(ctx: *anyopaque, group_id: u64, raft_index: u64) void {
        _ = raft_index;
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const sig = self.groups.get(group_id) orelse {
            // A follower may apply a committed entry for a tenant it never
            // had a local request for (so no GroupSig). That is normal
            // replication, not an error — nothing to advance here.
            return;
        };
        // Only the LEADER has local proposers parked on this watermark. A
        // follower applying an entry replicated from another leader must NOT
        // advance the watermark (there is no local waiter) nor pop the FIFO
        // (it never pushed). This is the binding that counting could not
        // express. On the leader, entries commit in propose (FIFO) order, so
        // the front of `pending` is exactly this entry's seq.
        if (!self.node.isLeader(group_id)) return;
        if (sig.pending.items.len == 0) return; // e.g. a non-proposer no-op
        const seq = sig.pending.orderedRemove(0);
        sig.committed_seq.store(seq, .release);
        if (sig.pending.items.len == 0) self.removeInFlightLocked(group_id);
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

test "bridge: move control — attach at epoch, quiesce holds writes, destroy reclaims" {
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
    try bridge.createGroupEpoch(gid, 1);

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

    // Quiesce: the watermark is at next_seq (nothing in flight) and new
    // proposes are now refused.
    const drained_to = try bridge.quiesce(gid);
    try testing.expectEqual(seq, drained_to);
    try testing.expectEqual(seq, bridge.committedSeq(gid));
    try testing.expectError(Error.Quiesced, bridge.propose(gid, env));

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

test "Phase 5c: 3-bridge cluster replicates via the leader; a follower propose faults" {
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

    // A propose on a FOLLOWER faults (not leader) so a parked worker would
    // fail fast and the client retry against the leader.
    const follower = (leader.? + 1) % 3;
    const fseq = try bridges[follower].propose(gid, env);
    var faulted = false;
    var s3: u32 = 0;
    while (s3 < 2000 and !faulted) : (s3 += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        if (bridges[follower].faultedSeq(gid) >= fseq) faulted = true;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(faulted);
    // The follower never advanced a local watermark for the faulted write.
    try testing.expect(bridges[follower].committedSeq(gid) < fseq);
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
    try testing.expectError(Error.PumpNotRunning, bridge.createGroupEpoch(gid, 1));
}
