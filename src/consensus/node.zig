//! V2 data-plane core — the per-tenant pump (single node).
//!
//! v2-build-order §Phase 1: "the heart of the rewrite." A
//! `Node` owns one `SharedWal` + one raft-rs `Manager`, and a pump that
//! drives the active set of per-tenant raft groups:
//!
//!     tickGroups(active) → pollReady → processReady (decode a committed
//!     entry → apply it to the tenant's kvexp store) → flush the shared
//!     WAL once → takeMessages → release
//!
//! One raft group per tenant (`group_id == tenant_id`), each with its
//! own `GroupedFileStorage` over the shared per-node WAL — the
//! single-fsync-per-cycle constraint that makes multi-tenant raft viable
//! (multiraft-scaling-learnings §3.2). The committed-entry apply path
//! reuses the limbs unchanged: the `envelope` codec, `writeset.applyEncoded`,
//! and `kvexp` via `KvStore` as the per-tenant state engine.
//!
//! Scope boundaries for Phase 1, deliberately deferred to later phases:
//!   - **single node, single voter** — no cross-node transport, so
//!     `takeMessages` drains to nowhere. Multi-node is Phase 5.
//!   - **no HTTP / JS** — propose + read are called directly. The
//!     worker-dispatch seam swap is Phase 2.
//!   - hibernation (Phase 6, `multiraft-scaling-learnings §3.1`): the
//!     `active` set is a true HIBERNATING set — a group idle (no propose,
//!     no non-heartbeat inbound step) for `hibernate_ns` drops out and is
//!     no longer ticked, so an idle tenant stops heartbeating (leader) /
//!     running its election timer (follower) and costs the pump nothing.
//!     The activity bump deliberately SKIPS heartbeats (a heartbeat means
//!     "don't elect me," not "I have work"), so a quiet group's own
//!     keep-alive traffic can't keep it awake. Correctness across nodes:
//!     every node counts a group's idle deadline from the last REAL
//!     message (all see it ~simultaneously), so they hibernate within
//!     network-jitter of each other — well under the election timeout —
//!     and a hibernated group's frozen election timer never fires a
//!     spurious campaign. A propose or a non-heartbeat step wakes it
//!     cluster-wide.
//!   - **no migration / epoch fence** — `createGroup` (birth epoch 0);
//!     detach/attach is Phase 4.
//!   - **no speculative overlay** — entries apply on commit (both the
//!     proposer and any follower run the same apply). The `TrackedTxn`
//!     pre-write-then-propose latency optimization belongs to the
//!     Phase-2 request path.
//!
//! Structural reference: rewind2's `multi_dispatcher.zig` (the
//! multi-node, multi-pump-worker, migration-capable superset this is the
//! single-node kernel of).

const std = @import("std");
const raft = @import("raft_rs_zig");
const kvlimbs = @import("kvlimbs");
const kvstore = kvlimbs.kvstore;
const writeset = kvlimbs.writeset;
const envelope = @import("envelope.zig");
const transport_mod = @import("transport.zig");

pub const Transport = transport_mod.Transport;
pub const PeerAddr = transport_mod.PeerAddr;
pub const PeerResolver = transport_mod.PeerResolver;

/// An in-memory raft node id → transport address map, fed by the control plane
/// (attach / conf-change carry the joining node's address; the directory
/// node-address registry is the durable source) and consulted by the transport
/// to dial a peer it learned at runtime rather than from static config
/// (cluster-genesis-and-membership §3.3). One per worker / CP process, shared by
/// every raft group (all groups on a cluster ride the same physical nodes).
///
/// **Insert-only.** A node id's address is learned once and never freed/moved
/// (re-IP is out of scope for v1, §7), so a host slice handed out by `resolve`
/// stays valid after the brief lookup lock is dropped — the transport copies it
/// into a `std.net.Address` synchronously inside `queueOut`. Heap-allocated so
/// its address is stable for the `PeerResolver.ctx` it hands the transport.
pub const PeerRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,

    const Entry = struct { host: []u8, port: u16 };

    pub fn create(allocator: std.mem.Allocator) Error!*PeerRegistry {
        const self = allocator.create(PeerRegistry) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *PeerRegistry) void {
        const a = self.allocator;
        var it = self.map.valueIterator();
        while (it.next()) |e| a.free(e.host);
        self.map.deinit(a);
        a.destroy(self);
    }

    /// Learn `node_id → host:port` (insert-only — a repeat for a known id is
    /// ignored). Thread-safe; callable from the worker's h2 handler thread while
    /// the pump thread resolves.
    pub fn learn(self: *PeerRegistry, node_id: u64, host: []const u8, port: u16) Error!void {
        if (node_id == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.contains(node_id)) return;
        const h = self.allocator.dupe(u8, host) catch return Error.OutOfMemory;
        errdefer self.allocator.free(h);
        self.map.put(self.allocator, node_id, .{ .host = h, .port = port }) catch return Error.OutOfMemory;
    }

    /// Parse `host:port` and learn it (the wire form the CP carries).
    pub fn learnAddr(self: *PeerRegistry, node_id: u64, addr: []const u8) Error!void {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return Error.BadConfig;
        const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return Error.BadConfig;
        return self.learn(node_id, addr[0..colon], port);
    }

    /// The `PeerResolver` view to hand the transport. `ctx` is `self`, whose
    /// address is stable (heap-allocated).
    pub fn resolver(self: *PeerRegistry) PeerResolver {
        return .{ .ctx = self, .resolveFn = resolveImpl };
    }

    fn resolveImpl(ctx: ?*anyopaque, node_id: u64) ?PeerAddr {
        const self: *PeerRegistry = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(node_id) orelse return null;
        // host stays valid past the unlock (insert-only); the transport copies
        // it synchronously in queueOut.
        return .{ .host = e.host, .port = e.port };
    }
};

pub const KvStore = kvstore.KvStore;
pub const WriteSet = writeset.WriteSet;
pub const Envelope = envelope.Envelope;
pub const RangeResult = kvstore.RangeResult;

/// Per-group raft configuration handed to every `createGroupEpoch`.
///
/// `pre_vote`: a follower that was partitioned, or a hibernated group that
/// wakes, first probes whether an election is winnable before bumping its
/// term — so a node that cannot win cannot disrupt a healthy leader by
/// forcing a term change (and cannot ratchet terms during a mass-wake).
///
/// `check_quorum`: a leader that stops hearing from a quorum steps down
/// within ~one election timeout, instead of serving reads indefinitely as a
/// deposed-but-unaware leader after a partition. This bounds the only
/// remaining strict-serializable-read gap left by the dispatch-gate (the
/// gate routes reads to whoever *believes* it leads; check_quorum makes a
/// partitioned ex-leader stop believing). Safe under hibernation: a
/// hibernated leader isn't ticked, so it never evaluates check_quorum and
/// can't spuriously step down; an *active* leader's heartbeats are still
/// answered by hibernated followers (a stepped heartbeat notifies → ready →
/// the response is sent, independent of the active set), so the quorum check
/// is satisfied in normal operation. read_index (LeaseBased reads) would
/// close the gap fully but needs an FFI method (RawNode.read_index) that
/// isn't surfaced yet; check_quorum is the cheap, no-per-read-cost bound.
///
/// The remaining tunables (election-tick window, priority for leadership
/// transfer) stay at raft defaults pending their own need. All nodes run
/// the same binary so these are uniform cluster-wide; a rolling deploy has a
/// transient mixed-config window, acceptable pre-launch (dev clusters wiped).
const group_raft_config: raft.manager.GroupConfig = blk: {
    var cfg = raft.manager.defaultGroupConfig();
    cfg.pre_vote = true;
    cfg.check_quorum = true;
    break :blk cfg;
};

/// Default hibernation idle window (Phase 6, `multiraft-scaling-learnings
/// §3.1`): a group with no propose / non-heartbeat step for this long drops
/// out of the active set and is no longer ticked. Comfortably longer than
/// the raft election timeout in wall-clock terms — what must stay below the
/// election timeout is the *skew* between nodes hibernating the same group
/// (≈ network jitter), not this absolute value; a generous window just
/// avoids re-waking a barely-idle group. Tests override `Node.hibernate_ns`
/// with a short value so the hibernate/wake transitions are observable fast.
pub const DEFAULT_HIBERNATE_NS: i64 = 2 * std.time.ns_per_s;

/// Default leaderless-escalation window (see `Node.leaderless_escalate_ns`): a
/// group active + leaderless for this long gets a forced (lease-bypassing,
/// pre-vote-free) campaign. ~15× the ~10ms election timeout — long enough that a
/// normal election (cold start, or peers whose leases expire on their own)
/// completes first and never triggers it, short enough that a genuinely wedged
/// hard-failover recovers in a fraction of a second rather than waiting on luck.
pub const DEFAULT_LEADERLESS_ESCALATE_NS: i64 = 150 * std.time.ns_per_ms;

/// Default durabilize cadence (V2 port of V1's `Cluster.tickSnapshot`
/// interval): how often the pump folds each dirty tenant store's in-memory
/// overlay into LMDB + stamps its raft watermark + (single-node) compacts the
/// WAL. A committed write is already durable in the fsync'd raft WAL the
/// instant it commits; this checkpoint just bounds how much WAL a restart must
/// replay and lets the WAL be truncated. Tests override with a short value.
pub const DEFAULT_DURABILIZE_NS: i64 = 500 * std.time.ns_per_ms;

/// Mechanism-A compaction (raft-native-alignment §I4): the fixed catch-up
/// buffer. `durabilizeTick` compacts the WAL to `durable_apply_watermark −
/// grace`, PER NODE INDEPENDENTLY — no cross-node min-match floor, no propagated
/// floor, no lockstep. A peer within `grace` entries of the cap catches up from
/// the log; anyone further back trips raft's `StateSnapshot` and is recovered by
/// the out-of-band snapshot catch-up driver. The fixed buffer is the bound: a
/// dead/stuck peer falls out of it and snapshots rather than pinning the WAL.
/// ~etcd's `SnapshotCatchUpEntries` (5000). One knob (`REWIND_SNAPSHOT_GRACE`);
/// 0 means "compact to the durable watermark" (snapshot any peer not exactly
/// caught up — valid, just snapshot-heavy).
pub const DEFAULT_SNAPSHOT_GRACE: u64 = 5_000;

/// Auto-demote policy (conf_change Phase 2): on the leader, a peer voter that
/// is BOTH this many entries behind the leader's last index AND `!recent_active`
/// (no contact within ~an election timeout, under check_quorum) is demoted to a
/// learner. A permanently-dead voter pins the voters-only WAL-compaction floor
/// (`minMatchIndex`) → unbounded WAL growth; demoting it unpins the floor so the
/// log truncates again. No availability loss: a dead voter could never form
/// quorum anyway, so the live nodes were already load-bearing; demote just makes
/// the voter math honest (and lets the learner be promoted back out-of-band once
/// it returns and catches up). The lag threshold is the anti-flap: a node must
/// be gone long enough to fall this far behind, and `recent_active` recovers the
/// instant one heartbeat ack arrives. 0 disables auto-demote.
pub const DEFAULT_AUTO_DEMOTE_LAG: u64 = 10_000;

/// How often the pump evaluates the auto-demote policy over its led+dirty
/// groups. Coarse (the WAL-growth pressure it relieves is slow); well above the
/// election timeout so `recent_active` is meaningful. Tests override with a
/// short value.
pub const DEFAULT_AUTO_DEMOTE_NS: i64 = 5 * std.time.ns_per_s;

/// Raft logical-tick cadence. raft ticks are LOGICAL — `election_tick` /
/// `heartbeat_tick` (set in `group_raft_config`) are counts of these, so the
/// wall-clock election timeout is `election_tick × tick_interval`. The pump
/// loop runs as fast as it can (a 1ms idle backoff, faster under load), so
/// ticking once per *cycle* would couple the election timeout to load — slower
/// under a write burst, faster when idle — and make "what is our election
/// timeout?" unanswerable. Gating the tick on a fixed monotonic interval
/// decouples it: `tickGroups` fires at most once per `tick_interval_ns`
/// regardless of loop speed, so `election_tick × tick_interval_ns` is a stable,
/// justifiable number. The default preserves the historical ~1ms idle cadence
/// (so behavior is unchanged) while also CAPPING the rate under load; raise it
/// (env `REWIND_RAFT_TICK_MS`) once a soak has measured the broadcast-time +
/// pause-jitter tail this must clear (see docs/raft-best-practices.md).
pub const DEFAULT_TICK_NS: i64 = 1 * std.time.ns_per_ms;

/// Resolves the store a replicated entry applies to, keyed by the
/// envelope's tenant id string. Two callers need it:
///
///   - a FOLLOWER's apply in `worker_overlay` mode (Phase 5 "Full HA"):
///     without it, a follower writes the node's own `slot.store` — a file
///     the worker never reads, so a follower promoted to leader would
///     serve from an empty serving store. The bridge sets this (via
///     `setStoreResolver`) to point at the worker's own per-tenant
///     `inst.kv`, provisioned on demand.
///   - a `multi` envelope's CROSS-TENANT inners (the admin batch's
///     `platform.scope(id).kv.*` / `releases.publish` trampoline targets,
///     `raft_propose.zig proposeBatch`): each inner's `id` may name a
///     tenant OTHER than the anchor group's, so apply must route by that
///     id, not by the group's slot.
///
/// Contract: `id_str` is the envelope id the writeset targets; the EMPTY
/// id (`""`) resolves the node-wide ROOT store (`__root__`) — the target
/// of `root_writeset` envelopes/inners (`platform.root.*`). `group_id` is
/// the group the entry committed through (the anchor group for inners).
/// The resolver runs on the pump thread; the worker's `Tenant` is
/// internally locked, so on-demand provisioning is safe there. Returns
/// null only on a provisioning failure (an invariant violation surfaced
/// by the apply round as `UnroutedApply`).
pub const StoreResolver = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, id_str: []const u8) ?*KvStore,
};

/// Fired once per committed *real* entry (writeset / multi / root —
/// not the leader's empty election no-op), AFTER it has applied AND the
/// cycle's WAL fsync has completed, with the entry's IDENTITY (the
/// origin frame's `origin` + `seq`, see `envelope.EntryFrame`) and its
/// raft index. The bridge (`bridge.zig`) advances a tenant's
/// `committed_seq` watermark only for entries whose `origin` is its own
/// — an identity binding, not a positional one, so an old-term entry
/// resurrected by a re-election can never credit a different propose's
/// waiter. Because the watermark is the worker's durable-ack signal,
/// the hook is staged during `processReady` and fired only after
/// `wal.flush()` succeeds — never ahead of the fsync. `null` in the
/// Phase-1 unit tests, which drive the pump directly and read inline.
pub const CommitHook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, origin: u64, seq: u64, raft_index: u64) void,
};

/// Asks the bridge whether a committed entry's store write should be
/// SKIPPED in `worker_overlay` mode: true iff the entry is THIS node's
/// own live propose (`origin` matches the bridge and `seq` is still in
/// the tenant's pending set — i.e. a local worker txn holds these writes
/// and will commit them on watermark advance). Keying the skip on
/// provenance instead of on `isLeader` closes two holes: a
/// freshly-elected leader catching up on entries proposed elsewhere must
/// WRITE them (no local worker ever did), and an entry whose local
/// waiter gave up (fault / timeout → txn rolled back, seq abandoned)
/// must be written by the pump when it later commits. Pump-thread only.
pub const SkipQuery = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, origin: u64, seq: u64) bool,
};

/// One staged commit notification (see `Node.commit_notify`).
const CommitNotify = struct {
    gid: u64,
    origin: u64,
    seq: u64,
    idx: u64,
};

/// Asks the bridge for the highest raft index whose data is fully in
/// the store's foldable overlay for `gid` — the DURABILIZE FLOOR.
/// In `worker_overlay` mode a skipped entry's writes live in the
/// worker's open `TrackedTxn` until the worker observes the watermark
/// and commits; kvexp's fold (`setLastAppliedRaftIdx`) only covers the
/// committed main overlay, so durabilizing/compacting past an un-acked
/// entry would stamp a watermark (and truncate WAL) for data that is
/// not yet foldable — a crash then loses an acked write. The bridge
/// answers `first un-acked entry's index − 1` (or `maxInt` when nothing
/// is awaited). Pump-thread only.
pub const DurabilizeFloor = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, gid: u64) u64,
};

/// Fired once per PUT in a committed writeset, AFTER it has applied to the
/// store, on EVERY node (leader and follower). Unlike `CommitHook` (which
/// binds commit order to a local proposer's seq, so it only advances on the
/// leader), this fires wherever the entry applies — the seam a replicated
/// in-memory projection updates from. The control-plane `Directory`
/// (`cp/directory.zig`) uses it: a CP follower has no local proposer, so its
/// placement projection materializes from these replicated applies, not from
/// `propose`. The rewind worker uses it too (`onDeployApply`) to track
/// replicated `_deploy/current` flips on followers. `id_str` is the tenant
/// id the writeset TARGETED — for a `multi`'s cross-tenant inner that is
/// the inner's id, NOT the anchor group's tenant (`""` for a root inner)
/// — so observers must key tenant identity on it, never on `group_id`
/// (which is only the group the entry committed through; the CP keeps
/// using it to filter for the directory group). `key`/`value`/`id_str`
/// borrow the decoded entry bytes (valid only for the call). `null` for
/// every non-CP, non-worker node.
pub const ApplyObserver = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, id_str: []const u8, key: []const u8, value: []const u8) void,
};

/// How committed entries apply to the tenant store (v2-build-order
/// §Phase 2 leader-skip + the speculative overlay).
pub const ApplyMode = enum {
    /// Decode a committed writeset and write it to the tenant's kvexp
    /// store. The Phase-1 default and the bare-node multi-node test: there
    /// is no speculative overlay, so apply IS the write.
    apply_on_commit,
    /// Single-node LEADER (legacy): the worker already wrote the entry into
    /// its own `TrackedTxn` speculative overlay before proposing and
    /// commits that overlay when the watermark advances — so the pump must
    /// NOT re-write the store (it would double-apply on a second handle).
    /// Superseded by `worker_overlay` for the bridge (which is role-aware);
    /// kept for any caller that wants an unconditional skip.
    leader_skip,
    /// Worker-fronted multi-node (Phase 5): the apply behavior depends on
    /// this node's role in the group. On the **leader**, the worker owns
    /// the speculative overlay and commits it on watermark advance, so the
    /// pump skips the store write (as `leader_skip`). On a **follower**,
    /// there is no worker/overlay for this tenant here, so the pump must
    /// write the committed entry to the store itself (as `apply_on_commit`)
    /// — that is how followers stay in sync and how a tenant's data is
    /// present on the survivors after a leader failure.
    worker_overlay,
};

pub const Error = error{
    /// A malformed config value — e.g. a peer-registry `host:port` with no
    /// colon or an unparseable port (`PeerRegistry.learnAddr`).
    BadConfig,
    /// A committed entry named a group with no live tenant slot — an
    /// invariant violation (we only apply entries for groups we created).
    UnknownGroup,
    /// A committed entry (or a `multi` inner) targeted a store this node
    /// cannot resolve — a cross-tenant or root inner with no
    /// `StoreResolver` set, or a resolver provisioning failure. An
    /// invariant violation: the entry is committed in the log but its
    /// writes have nowhere to land, so applying the rest of it would
    /// silently diverge this replica.
    UnroutedApply,
    /// `createGroupAtEpoch` was asked to attach a group id that already
    /// has a live slot — a double-attach orchestration bug.
    GroupExists,
    /// A proposed write did not commit + apply within the pump budget.
    NotCommitted,
    /// A data-free baseline was supplied with index>0 but term==0. A term-0
    /// baseline makes raft-rs's restore fast-forward commit_to past an empty
    /// log → fatal!. The producer (v2-applied-baseline) refuses to emit one;
    /// the installer refuses to accept one. An invariant, enforced both ends.
    InvalidBaseline,
    OutOfMemory,
} || envelope.Error || raft.Error || kvstore.Error || writeset.DecodeError;

/// Per-tenant state: the kvexp store (the limb) plus bookkeeping. The
/// `GroupedFileStorage` for this tenant's group is owned by raft-rs once
/// `createGroup` is called (freed via the storage destroy-vtable when
/// the group is destroyed / on `Manager.deinit`), so it is not held here.
pub const TenantSlot = struct {
    tenant_id: u64,
    /// Borrowed slice into `Node`'s arena-free duped id string; the
    /// envelope `id` the worker stamps. Owned by the slot.
    id_str: []const u8,
    store: *KvStore,
    /// Highest raft index whose committed entry has been applied to
    /// `store`. 0 until the first apply.
    applied_idx: u64 = 0,
    /// Hibernation (Phase 6): wall-clock deadline past which this group is
    /// considered idle and swept out of the active tick set. Refreshed by
    /// `bumpActive` on every propose + non-heartbeat inbound step (NOT on
    /// heartbeats). 0 = never bumped (a fresh slot not yet active).
    active_until_ns: i64 = 0,
    /// Whether this group is currently in `Node.active` (ticked each pump
    /// cycle). Lets `bumpActive` add it at most once and the sweep drop it.
    in_active: bool = false,
    /// Pinned ALWAYS-active (never hibernated). The control-plane directory
    /// group sets this: it must keep ticking so a follower runs its election
    /// timer and re-elects on leader death — a directory read never proposes,
    /// so a hibernated directory group would never wake to re-elect. One
    /// always-ticking group is O(1), unlike the K-tenant data groups.
    pinned: bool = false,
    /// Highest raft index durabilized into the store's LMDB (folded out of the
    /// in-memory overlay + stamped as `lastAppliedRaftIdx`) by `durabilizeTick`.
    /// `applied_idx > durabilized_idx` ⇒ this group has committed-but-not-yet-
    /// durable writes (it is "dirty"). Single-node compacts the WAL up to here.
    durabilized_idx: u64 = 0,
    /// Whether this slot is in `Node.dirty` (committed since last durabilize),
    /// so `applyEntry` enqueues it at most once.
    in_dirty: bool = false,
    /// Whether this slot is in `Node.persist_ack` (a `processReady` ran
    /// whose buffered writes await the next fsync's `onPersist` ack), so
    /// the pump enqueues it at most once per ack round.
    in_persist_ack: bool = false,
    /// Wall-clock at which this group was first observed leaderless (this node
    /// not the leader AND `leaderId == 0`) while in the active set; 0 while a
    /// leader is known. `escalateLeaderless` arms it and, once the group has
    /// stayed leaderless past `Node.leaderless_escalate_ns`, FORCE-campaigns
    /// (`mgr.campaignForce`) — the TiKV wake-to-elect recovery for a hard
    /// (SIGKILL) leader loss, where a hibernated survivor's normal pre-vote is
    /// ignored by peers still inside their `check_quorum` lease. Reset to `now`
    /// after each force so the escalation re-arms (a cooldown), and to 0 the
    /// moment a leader appears.
    leaderless_since_ns: i64 = 0,
    /// Borrowed `GroupedFileStorage` for this group — the Manager owns it (via
    /// the storage vtable) and frees it on `destroyGroup`, but we keep the
    /// pointer to drive WAL compaction (`gfs.compact`) without a Manager API.
    /// Valid for the slot's lifetime (we control `destroyGroup`).
    gfs: *raft.GroupedFileStorage,
};

/// One V2 node: a `Manager` of per-tenant raft groups over one shared
/// WAL, plus the per-tenant kvexp stores the committed entries apply to.
pub const Node = struct {
    allocator: std.mem.Allocator,
    /// Owned dup. Per-tenant stores live at `{data_dir}/{tenant}/app.db`;
    /// the shared WAL at `{data_dir}/raft-wal`.
    data_dir: []const u8,
    /// This node's voter id within every group (single-node: 1).
    node_id: u64,
    /// Owned dup of the group voter set (single-node: `{node_id}`).
    voters: []const u64,

    mgr: raft.Manager,
    wal: *raft.SharedWal,

    /// Node-local group manifest: the set of tenant groups this node has
    /// (id_str → birth/migration epoch, decimal). NOT replicated — each node
    /// records only its own groups. The raft WAL persists every group's
    /// consensus state (hardstate/confstate/log), but `Manager.init` does not
    /// scan it to re-stand-up groups, and a group's `id_str` is not recoverable
    /// from its gid (a non-invertible hash). So this manifest is the durable
    /// list `Bridge.recoverGroups` reads at boot to call `recoverGroup` for
    /// each — the missing seam that lets a restarted node rejoin its groups and
    /// catch up (`snap_catchup_smoke_v2`). Written in `createGroupCore`, removed
    /// in `destroyGroupAndReclaim`. Lives at `{data_dir}/__groups__/app.db`.
    groups_manifest: *KvStore,

    /// Cross-node transport (Phase 5). `null` for a single-node node
    /// (`initSingleNode`): no peers, so groups campaign to leader at
    /// creation and `takeMessages` drains to nowhere. Non-null for a
    /// multi-node node: the pump drives it each cycle (flush coalesced
    /// sends + tick to deliver inbound → step) and groups elect via ticks.
    transport: ?*Transport = null,

    /// tenant_id → slot. Iterated on deinit; looked up in the apply
    /// callback by `group_id`.
    groups: std.AutoHashMapUnmanaged(u64, *TenantSlot) = .empty,
    /// Group ids ticked every pump cycle — the HIBERNATING active set
    /// (Phase 6). A group enters via `bumpActive` (propose / formation /
    /// non-heartbeat step) and leaves when its `active_until_ns` passes
    /// (`sweepHibernated`). NOT pre-seeded with every created group: an idle
    /// group is not ticked, so the pump cost is O(active), not O(all groups)
    /// — the multiraft-scaling-learnings §3.1 win at K = thousands.
    active: std.ArrayListUnmanaged(u64) = .empty,
    /// `pollReady` scratch, grown to `groups.count()` as groups are added.
    ready_buf: []u64 = &.{},
    /// Second `pollReady` scratch for the post-fsync apply pass (pass 2
    /// of `pump` — `ready_buf` still holds pass 1's ids at that point).
    ready_buf2: []u64 = &.{},

    /// Groups whose `processReady` buffered writes this (or a previous)
    /// cycle and now await the post-fsync `mgr.onPersist` ack — the
    /// async-append handshake (raft only counts this node's entries
    /// toward the commit quorum once acked, and the persistence-
    /// asserting messages stay stashed until then). Deduped via
    /// `TenantSlot.in_persist_ack`; retained across a failed flush so
    /// the ack retries after the next successful one. Pump-thread only.
    persist_ack: std.ArrayListUnmanaged(u64) = .empty,

    /// Gids with committed-but-not-yet-durabilized writes (`applied_idx >
    /// durabilized_idx`). Enqueued by `applyEntry`, drained by
    /// `durabilizeTick` — so durabilize cost is O(dirty), not O(all groups).
    /// All dirty groups are durabilized together each tick so the shared WAL
    /// can be compacted to a floor (their commits interleave in the one WAL).
    dirty: std.ArrayListUnmanaged(u64) = .empty,
    /// Wall-clock of the last `durabilizeTick`; the tick is interval-gated
    /// (`durabilize_interval_ns`) like V1's `Cluster.tickSnapshot` — folding
    /// the overlay into LMDB is an fsync, amortized over many commits.
    last_durabilize_ns: i64 = 0,
    durabilize_interval_ns: i64 = DEFAULT_DURABILIZE_NS,
    /// Auto-demote policy (see `DEFAULT_AUTO_DEMOTE_LAG`): lag threshold in
    /// entries (0 disables), evaluation cadence, and last-run wall-clock.
    auto_demote_lag: u64 = DEFAULT_AUTO_DEMOTE_LAG,
    auto_demote_interval_ns: i64 = DEFAULT_AUTO_DEMOTE_NS,
    last_auto_demote_ns: i64 = 0,
    /// Mechanism-A compaction catch-up buffer (see `DEFAULT_SNAPSHOT_GRACE`):
    /// `durabilizeTick` keeps this many entries below the durable apply watermark
    /// in the WAL so a peer within the buffer catches up from the log; a peer
    /// further back trips `StateSnapshot` and is recovered out-of-band.
    snapshot_grace: u64 = DEFAULT_SNAPSHOT_GRACE,
    /// Raft logical-tick cadence + last-tick wall-clock (see `DEFAULT_TICK_NS`).
    /// `pump` fires `mgr.tickGroups` at most once per `tick_interval_ns`, so the
    /// election timeout (`election_tick × tick_interval_ns`) is decoupled from
    /// the pump loop speed. Tests that want fast elections set this small.
    tick_interval_ns: i64 = DEFAULT_TICK_NS,
    last_tick_ns: i64 = 0,
    /// Whether `durabilizeTick` also COMPACTS the WAL (single-node only) after
    /// durabilizing — truncating the log up to the durabilized index so it stays
    /// bounded. ON. Safe because durabilize folds the overlay into LMDB (and
    /// stamps `lastAppliedRaftIdx`) BEFORE truncating, so data up to the
    /// compaction point is durable independent of the WAL; recovery reloads it
    /// from LMDB and replays only the post-compaction tail.
    ///
    /// Prereqs that are now met: the raft-rs-zig compact→recover hardstate bug
    /// (a recovered group loaded a stale `commit=0` → `hs.commit out of range`)
    /// is fixed upstream by persisting the `LightReady` commit index (pinned at
    /// raft-rs-zig 5092bc6).
    ///
    /// A prior note here claimed enabling this "crashes the real THREADED
    /// binaries" — that was a red herring. The crash was a rustc -O0
    /// `movaps`/`.rodata.cst16` alignment GPF triggered by the dependency bump
    /// (it reproduced with `compact_wal = false` too), fixed by building
    /// raft-sys at `opt-level = 1` (raft-rs-zig 5092bc6). With that fixed,
    /// compaction is verified: single-node compaction runs and survives
    /// compact→recover across restart (no `hs.commit` panic, no cross-thread
    /// abort), and the full V2 smoke suite (rewind / tenant_move / three_node /
    /// cp_move_recovery / zero_downtime_move) passes.
    ///
    /// Multi-node compaction is now on too (`durabilizeTick`): leader and
    /// follower both truncate to the cluster-wide min match index (the leader
    /// propagates it on its messages), so a lagging voter always catches up from
    /// the log — snapshot-free.
    compact_wal: bool = true,
    /// Set true while a group's recovery drain (`createGroupCore`) re-applies
    /// the replayed WAL tail: forces the store WRITE even in `worker_overlay`
    /// mode (where the leader normally skips it because the worker's txn wrote
    /// it) — at restart there is no worker, so the pump must write the store
    /// itself, exactly as a follower does.
    recovering: bool = false,

    /// First error raised by the apply callback during the current
    /// `processReady` round (the C-ABI callback can't return one).
    /// Checked + cleared by `pump` after the round.
    apply_err: ?Error = null,

    /// Commit notifications staged during the current `processReady`
    /// round, fired (in apply order) only AFTER the cycle's `wal.flush()`
    /// succeeds — the commit hook is the worker's durable-ack signal, so
    /// it must not run ahead of the fsync (see `pump`). Reused per cycle.
    commit_notify: std.ArrayListUnmanaged(CommitNotify) = .empty,

    /// Optional per-committed-entry notification (see `CommitHook`).
    /// Set by the bridge; left null by the Phase-1 inline tests.
    commit_hook: ?CommitHook = null,

    /// Optional worker-overlay skip oracle (see `SkipQuery`). Set by the
    /// bridge alongside `commit_hook`. When null, `worker_overlay` falls
    /// back to the role-keyed `isLeader` skip (bare-node tests only —
    /// every worker-fronted deployment sets it).
    skip_query: ?SkipQuery = null,

    /// Optional durabilize floor (see `DurabilizeFloor`). Set by the
    /// bridge alongside `commit_hook`; trivially unconstrained
    /// (`maxInt`) outside `worker_overlay` mode.
    durabilize_floor: ?DurabilizeFloor = null,

    /// Count of transport tick failures (rate-limited logging in `pump`
    /// — a persistently broken transport must be operator-visible, not a
    /// silently-swallowed partition).
    transport_err_count: u64 = 0,

    /// Optional per-applied-put notification (see `ApplyObserver`). Set by
    /// the bridge for the control-plane directory group so a CP node's
    /// in-memory projection tracks replicated applies (leader + follower).
    /// Null everywhere else — decoding the writeset twice is only worth it
    /// for the tiny directory writes.
    apply_observer: ?ApplyObserver = null,

    /// How committed entries apply (see `ApplyMode`): write the store
    /// (`apply_on_commit`, default) vs. role-aware skip-on-leader
    /// (`worker_overlay`, which the bridge sets when it fronts a worker
    /// owning the speculative overlay). The Phase-1 tests + the bridge
    /// unit tests keep the default so a read after commit sees the pump's
    /// write.
    apply_mode: ApplyMode = .apply_on_commit,

    /// Hibernation idle window (Phase 6). Overridable per node (tests use a
    /// short value); production keeps `DEFAULT_HIBERNATE_NS`.
    hibernate_ns: i64 = DEFAULT_HIBERNATE_NS,
    /// Leaderless-escalation window: how long an active group may stay
    /// leaderless (this node not the leader AND `leaderId == 0`) before the pump
    /// FORCE-campaigns it past peers' `check_quorum` leases (`escalateLeaderless`
    /// → `mgr.campaignForce`). Comfortably above the election timeout
    /// (`election_tick × tick_interval` ≈ 10ms) so the cheap normal pre-vote path
    /// gets a few rounds first — the force-campaign is the BACKSTOP that makes a
    /// hard (SIGKILL) failover deterministic instead of relying on the peers'
    /// leases happening to expire in time. Tests override with a short value.
    leaderless_escalate_ns: i64 = DEFAULT_LEADERLESS_ESCALATE_NS,
    /// Scratch for draining the transport's woke-group list each pump cycle
    /// (the gids that received a non-heartbeat message → `bumpActive`).
    /// Owned; reused to avoid per-cycle allocation.
    woke_scratch: std.ArrayListUnmanaged(u64) = .empty,

    /// Optional follower-apply store resolver (see `StoreResolver`). Set by
    /// the bridge in `worker_overlay` mode so a follower's replicated writes
    /// land in the worker's own serving store (Phase 5 "Full HA"). Null in
    /// the bare-node tests, which read the node's own `slot.store`.
    store_resolver: ?StoreResolver = null,

    /// Stand up a single-node node (voter id 1, voter set `{1}`).
    pub fn initSingleNode(allocator: std.mem.Allocator, data_dir: []const u8) Error!*Node {
        return Node.init(allocator, data_dir, 1, &.{1});
    }

    /// Stand up a multi-node node (Phase 5): `node_id` ∈ `voters`, the full
    /// voter set across the cluster, plus the cross-node transport bound to
    /// `listen_addr` with `peers` (indexed by raft_net peer id = raft node
    /// id − 1, `len == cluster size`). Groups created here do NOT campaign
    /// at birth — election fires via ticks (real failover) or an explicit
    /// `campaign`. The pump drives the transport each cycle.
    pub fn initMultiNode(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        node_id: u64,
        voters: []const u64,
        listen_addr: std.net.Address,
        peers: []const PeerAddr,
    ) Error!*Node {
        const self = try Node.init(allocator, data_dir, node_id, voters);
        errdefer self.deinit();
        self.transport = Transport.init(allocator, .{
            .node_id = node_id,
            .listen_addr = listen_addr,
            .peers = peers,
            .manager = &self.mgr,
        }) catch return Error.Io;
        return self;
    }

    /// Stand up a GENESIS node (cluster-genesis-and-membership §3.4): configured
    /// with only its own identity — `node_id` + its raft `listen_addr` — and NO
    /// static voter set or peer list. It HAS a transport (so it can grow), but
    /// births its groups as `{self}` and learns peer addresses at runtime via the
    /// resolver (the caller installs a `PeerRegistry` — see `Bridge.initGenesis`).
    /// `self.voters = {node_id}` is the born-`{self}` fallback for groups created
    /// without an explicit membership override; `isSingleNode` is still false
    /// (a transport is present), so leadership tracks the real atomics once a
    /// group grows.
    pub fn initGenesis(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        node_id: u64,
        listen_addr: std.net.Address,
    ) Error!*Node {
        const self = try Node.init(allocator, data_dir, node_id, &[_]u64{node_id});
        errdefer self.deinit();
        self.transport = Transport.init(allocator, .{
            .node_id = node_id,
            .listen_addr = listen_addr,
            .peers = &.{}, // self-only; peers learned via the resolver
            .manager = &self.mgr,
        }) catch return Error.Io;
        return self;
    }

    /// Install a runtime peer-address resolver on the transport (the CP-fed
    /// `PeerRegistry`). No-op on a single-node node (no transport). MUST be
    /// called before the pump starts (see `Transport.setResolver`).
    pub fn setPeerResolver(self: *Node, r: PeerResolver) void {
        if (self.transport) |t| t.setResolver(r);
    }

    /// True when this node has NO cross-node transport — it can never have a
    /// peer, so it leads every group it creates and there is nothing to elect or
    /// transfer. The bridge uses this to answer `isLeaderOf` true unconditionally
    /// and to skip the not-leader propose gate / leadership transfers.
    ///
    /// Defined on transport presence, NOT `voters.len`, because a GENESIS node
    /// (cluster-genesis-and-membership §3.4) has a transport but births its
    /// groups as a single voter `{self}` and grows them later — it must use the
    /// real leadership atomics so it's correctly seen as a FOLLOWER once a group
    /// it created moves leadership elsewhere. (Per-group "born sole self" auto-
    /// campaign is a separate, group-local decision in `createGroupCore`.)
    pub fn isSingleNode(self: *const Node) bool {
        return self.transport == null;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        node_id: u64,
        voters: []const u64,
    ) Error!*Node {
        std.fs.cwd().makePath(data_dir) catch return Error.Io;

        const self = allocator.create(Node) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);

        const dir_dup = allocator.dupe(u8, data_dir) catch return Error.OutOfMemory;
        errdefer allocator.free(dir_dup);
        const voters_dup = allocator.dupe(u64, voters) catch return Error.OutOfMemory;
        errdefer allocator.free(voters_dup);

        const wal_path = std.fmt.allocPrint(allocator, "{s}/raft-wal", .{data_dir}) catch
            return Error.OutOfMemory;
        defer allocator.free(wal_path);
        // CRASH RECOVERY: `open` (not `init`) replays the durable WAL — it
        // CRC-scans the existing segments, truncates only a torn tail, and
        // buckets the recovered records per group for `initRecover` to replay.
        // On a fresh data dir there is nothing to recover, so it behaves like
        // `init`. Using `init` here (truncate-fresh) was discarding every
        // committed entry on restart — the fsync'd log was thrown away, so a
        // hard crash lost all writes since the last graceful close.
        const wal = raft.SharedWal.open(allocator, wal_path) catch return Error.Io;
        errdefer wal.deinit();

        // Node-local group manifest store (see the `groups_manifest` field).
        const man_dir = std.fmt.allocPrint(allocator, "{s}/__groups__", .{data_dir}) catch
            return Error.OutOfMemory;
        defer allocator.free(man_dir);
        std.fs.cwd().makePath(man_dir) catch return Error.Io;
        const man_path = std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{man_dir}, 0) catch
            return Error.OutOfMemory;
        defer allocator.free(man_path);
        const groups_manifest = try KvStore.open(allocator, man_path);
        errdefer groups_manifest.close();

        var mgr = try raft.Manager.init();
        errdefer mgr.deinit();

        self.* = .{
            .allocator = allocator,
            .data_dir = dir_dup,
            .node_id = node_id,
            .voters = voters_dup,
            .mgr = mgr,
            .wal = wal,
            .groups_manifest = groups_manifest,
        };
        return self;
    }

    pub fn deinit(self: *Node) void {
        const a = self.allocator;
        // Stop the network first (it borrows the Manager via step).
        if (self.transport) |t| t.deinit();
        // Destroy groups first — `Manager.deinit` frees each group's
        // `GroupedFileStorage` via its destroy-vtable. The WAL is
        // borrowed by those storages, so it must outlive them: tear the
        // manager down before the WAL.
        self.mgr.deinit();
        self.wal.deinit();
        self.groups_manifest.close();

        var it = self.groups.valueIterator();
        while (it.next()) |slot_ptr| {
            const slot = slot_ptr.*;
            slot.store.close();
            a.free(slot.id_str);
            a.destroy(slot);
        }
        self.groups.deinit(a);
        self.active.deinit(a);
        self.dirty.deinit(a);
        self.woke_scratch.deinit(a);
        self.commit_notify.deinit(a);
        self.persist_ack.deinit(a);
        a.free(self.ready_buf);
        a.free(self.ready_buf2);
        a.free(self.voters);
        a.free(self.data_dir);
        a.destroy(self);
    }

    /// Look up a tenant slot, or create its kvexp store + raft group on
    /// demand and drive the group to leader (single-node: campaign +
    /// pump). `id_str` is the envelope id the worker will stamp on this
    /// tenant's writesets; `tenant_id` is the numeric raft group id. The
    /// never-migrated birth case: epoch 0 (`createGroup`).
    pub fn ensureGroup(self: *Node, tenant_id: u64, id_str: []const u8) Error!*TenantSlot {
        if (self.groups.get(tenant_id)) |slot| return slot;
        // Birth OR restart: recover any durable WAL records for this group
        // (a no-op on a never-seen group). On a restart this replays the
        // committed log back into the store.
        return self.createGroupCore(tenant_id, id_str, 0, true, false, null);
    }

    /// Attach a tenant group at an explicit migration fence `epoch` (the
    /// Phase-4 move-destination path; v2-build-order §Phase 4
    /// "createGroupEpoch(tenant, epoch+1) on destination"). The tenant's
    /// kvexp state must already have been loaded (the bundle landed in the
    /// worker's `cluster.kv` store); this just stands up the consensus
    /// half — a fresh group whose epoch fences out any straggler traffic
    /// from the source incarnation (moot single-node, load-bearing under
    /// Phase-7 live overlap). `clearTombstone` first so a tenant id reused
    /// after a prior `destroyGroupAndReclaim` on THIS node can re-attach.
    /// Errors if the group already exists (attach is not idempotent — a
    /// double attach is an orchestration bug worth surfacing).
    /// `as_learner` births the group with THIS node as a non-voting learner
    /// (voters = the rest), for joining an existing group safely — see
    /// `createGroupCore`. The default (false) births a voter from the static
    /// voter set (a move destination / a configured voter rejoining).
    pub fn createGroupAtEpoch(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64, as_learner: bool, voters_override: ?[]const u64) Error!*TenantSlot {
        if (self.groups.get(tenant_id) != null) return Error.GroupExists;
        self.mgr.clearTombstone(tenant_id) catch {};
        // A migration attach is a FRESH group — its state arrives via the
        // bundle, not the WAL — so do NOT replay any (stale) recovered records
        // for this gid.
        return self.createGroupCore(tenant_id, id_str, epoch, false, as_learner, voters_override);
    }

    /// A group recorded in the node-local manifest (see `groups_manifest`):
    /// the tenant id string + its birth/migration epoch.
    pub const PersistedGroup = struct {
        id_str: []u8,
        epoch: u64,
    };

    /// Re-stand-up a persisted group at boot from its durable WAL state
    /// (`createGroupCore(recover=true)`) at the recorded `epoch`. The rejoined
    /// node is already a voter in the group's persisted confstate, so once the
    /// pump starts the leader replicates the missing log tail (or ships a
    /// snapshot) and the node catches up — no conf-change needed. Pre-pump,
    /// single-threaded, like `ensureGroup`. Idempotent.
    pub fn recoverGroup(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64) Error!*TenantSlot {
        if (self.groups.get(tenant_id)) |slot| return slot;
        return self.createGroupCore(tenant_id, id_str, epoch, true, false, null);
    }

    /// Record (or update) a group in the node-local recovery manifest, then
    /// DURABILIZE it (fold the manifest's kvexp overlay into LMDB). Best-effort:
    /// a manifest failure is logged, never propagated — the live group already
    /// exists; recovery is a resilience feature, not a gate. Pump-thread (group
    /// lifecycle).
    ///
    /// The durabilize is load-bearing: `KvStore.put` commits only to the kvexp
    /// VOLATILE overlay (like a tenant write before `durabilizeTick` folds it).
    /// The manifest store is never on the `dirty` durabilize path, so without an
    /// explicit fold here a hard crash (SIGKILL) loses every non-genesis group's
    /// record — on restart `recoverGroups` reads an empty manifest and the node
    /// silently drops that tenant's raft messages ("unknown group") forever. The
    /// fold is an fsync, but group create/move is rare, so the cost is fine.
    fn recordGroup(self: *Node, id_str: []const u8, epoch: u64) void {
        var buf: [24]u8 = undefined;
        const ep = std.fmt.bufPrint(&buf, "{d}", .{epoch}) catch return;
        self.groups_manifest.put(id_str, ep) catch |err| {
            std.log.warn("v2 node: group manifest record {s} failed: {s}", .{ id_str, @errorName(err) });
            return;
        };
        self.groups_manifest.checkpoint() catch |err| std.log.warn(
            "v2 node: group manifest durabilize {s} failed: {s} (record may not survive a crash)",
            .{ id_str, @errorName(err) },
        );
    }

    /// Remove a group from the recovery manifest (move-out) + durabilize the
    /// delete (so a crash can't resurrect a moved-out group's record). Best-effort.
    fn forgetGroup(self: *Node, id_str: []const u8) void {
        self.groups_manifest.delete(id_str) catch |err| {
            std.log.warn("v2 node: group manifest forget {s} failed: {s}", .{ id_str, @errorName(err) });
            return;
        };
        self.groups_manifest.checkpoint() catch |err| std.log.warn(
            "v2 node: group manifest durabilize (forget {s}) failed: {s}",
            .{ id_str, @errorName(err) },
        );
    }

    /// Read the recovery manifest into a freshly-allocated slice (caller owns:
    /// free each `id_str`, then the slice via `freePersistedGroups`). Read once
    /// at boot by `Bridge.recoverGroups`. Empty on a fresh data dir.
    pub fn persistedGroups(self: *Node, allocator: std.mem.Allocator) Error![]PersistedGroup {
        var out: std.ArrayListUnmanaged(PersistedGroup) = .empty;
        errdefer {
            for (out.items) |g| allocator.free(g.id_str);
            out.deinit(allocator);
        }
        var cursor_buf: ?[]u8 = null;
        defer if (cursor_buf) |c| allocator.free(c);
        while (true) {
            const cursor: []const u8 = cursor_buf orelse "";
            var page = self.groups_manifest.prefix("", cursor, 256) catch return Error.Io;
            defer page.deinit();
            if (page.entries.len == 0) break;
            for (page.entries) |e| {
                const epoch = std.fmt.parseInt(u64, e.value, 10) catch 0;
                const id_dup = allocator.dupe(u8, e.key) catch return Error.OutOfMemory;
                out.append(allocator, .{ .id_str = id_dup, .epoch = epoch }) catch {
                    allocator.free(id_dup);
                    return Error.OutOfMemory;
                };
            }
            const last = page.entries[page.entries.len - 1].key;
            const new_cursor = allocator.dupe(u8, last) catch return Error.OutOfMemory;
            if (cursor_buf) |c| allocator.free(c);
            cursor_buf = new_cursor;
            if (page.entries.len < 256) break;
        }
        return out.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }

    /// Free a `persistedGroups` result.
    pub fn freePersistedGroups(allocator: std.mem.Allocator, groups: []PersistedGroup) void {
        for (groups) |g| allocator.free(g.id_str);
        allocator.free(groups);
    }

    /// Shared group-birth core for `ensureGroup` (epoch 0) and
    /// `createGroupAtEpoch` (migration epoch): open the tenant's kvexp
    /// store, stand up a `GroupedFileStorage` over the shared WAL, create
    /// the raft group at `epoch`, register the slot, and drive it to
    /// leader (single-node campaign). Caller has already verified the
    /// group does not exist.
    /// `voters_override` (Phase 2e — cluster node-set SSOT): the initial voter set
    /// a FRESH group is born with, supplied by the control plane (the cluster's
    /// node set, the single source of truth) instead of this node's static
    /// `REWIND_VOTERS` env. Null → fall back to `self.voters` (unchanged). Ignored
    /// on the `recover` path (a rejoining group restores its membership from the
    /// WAL) and immaterial under a baseline (the baseline's ConfState overwrites
    /// the born membership — Phase 2d).
    fn createGroupCore(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64, recover: bool, as_learner: bool, voters_override: ?[]const u64) Error!*TenantSlot {
        // {data_dir}/{tenant_id}/app.db
        const dir = std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ self.data_dir, tenant_id }) catch
            return Error.OutOfMemory;
        defer self.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch return Error.Io;
        const path = std.fmt.allocPrintSentinel(self.allocator, "{s}/app.db", .{dir}, 0) catch
            return Error.OutOfMemory;
        defer self.allocator.free(path);

        const store = try KvStore.open(self.allocator, path);
        errdefer store.close();
        // Whatever was already durabilized into LMDB (a prior incarnation's
        // checkpoint) is the starting watermark — don't re-durabilize or
        // re-compact below it.
        const durable_idx = store.lastAppliedRaftIdx() catch 0;

        // GroupedFileStorage over the shared WAL. raft-rs takes ownership
        // via the vtable userdata slot and frees it when the group is
        // destroyed — do NOT free it here. `initRecover` replays this group's
        // records that `SharedWal.open` recovered (a no-op when none were —
        // identical to `init`); `init` ignores any recovered records (the
        // migration-attach case wants a fresh group from the bundle).
        // Born-as-learner: a node being ADDED to an existing group must join as
        // a non-voting learner. A learner never campaigns, so it follows the
        // leader and catches up; a born-VOTER (the default, ConfState from the
        // static voter set) would campaign past a high-term leader's term and
        // deadlock — it rejects the leader's lower-term appends forever (the
        // __admin__ wall). Split self out of the voter set into a sole learner.
        // Fresh-group only: `recover` restores the persisted membership from the
        // WAL, so a rejoining node keeps whatever role it last held.
        // The born ConfState's voter set: the CP-supplied cluster node set when
        // given (Phase 2e SSOT), else this node's static `REWIND_VOTERS`.
        const base_voters = voters_override orelse self.voters;
        if (!recover) std.log.info(
            "v2 node: gid={d} born voters={any} source={s}",
            .{ tenant_id, base_voters, if (voters_override != null) "cp-ssot" else "rewind_voters" },
        );
        var voters_scratch: [64]u64 = undefined;
        const learner_self = [_]u64{self.node_id};
        var voters_slice: []const u64 = base_voters;
        var learners_slice: []const u64 = &.{};
        if (as_learner and !recover) {
            var n: usize = 0;
            for (base_voters) |v| {
                if (v != self.node_id and n < voters_scratch.len) {
                    voters_scratch[n] = v;
                    n += 1;
                }
            }
            voters_slice = voters_scratch[0..n];
            learners_slice = &learner_self;
        }
        const gfs = if (recover)
            raft.GroupedFileStorage.initRecover(self.allocator, self.voters, self.wal, tenant_id) catch return Error.Io
        else
            raft.GroupedFileStorage.initWithLearners(self.allocator, voters_slice, learners_slice, self.wal, tenant_id) catch return Error.Io;
        // Ownership of `gfs` once it is handed to `createGroupEpoch` below. A bare
        // `errdefer gfs.deinit()` here was a DOUBLE-FREE — the SIGABRT (GP fault in
        // raft-rs storage deinit iterating already-freed entries):
        //   • SUCCESS — the manager owns `gfs` and frees it on `destroyGroup`; a
        //     plain errdefer would free it AGAIN on any later failure here.
        //   • FAILURE — `createGroupEpoch` failing for THIS caller means raft-rs's
        //     `RawNode::new` REJECTED the config (the FFI returns -3). The Rust side
        //     has ALREADY taken `gfs` into an `FfiStorage` whose `Drop` calls the
        //     `destroy` vtable — so the FFI freed it; a Zig-side deinit double-frees.
        //     (The FFI's other failure returns, where it does NOT free — group
        //     exists / tombstoned / null args — are all pre-empted by the Zig
        //     guards above: the `self.groups`/`GroupExists` check, `clearTombstone`,
        //     and a non-zero `self.node_id`. So a failure HERE is only ever the
        //     RawNode rejection, which freed.)
        // Either way the manager owns `gfs` from the call onward, so arm the deinit
        // ONLY for failures BEFORE the handoff (the slot/id_dup allocs below).
        var gfs_owned_by_mgr = false;
        errdefer if (!gfs_owned_by_mgr) gfs.deinit();

        const slot = self.allocator.create(TenantSlot) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        const id_dup = self.allocator.dupe(u8, id_str) catch return Error.OutOfMemory;
        errdefer self.allocator.free(id_dup);
        slot.* = .{
            .tenant_id = tenant_id,
            .id_str = id_dup,
            .store = store,
            .gfs = gfs,
            .applied_idx = durable_idx,
            .durabilized_idx = durable_idx,
        };

        // Hand `gfs` to the manager. Disarm the local deinit FIRST: from this call
        // onward the FFI owns `gfs` on BOTH outcomes (success → freed on
        // `destroyGroup`; RawNode rejection → freed by `FfiStorage::drop`), so the
        // local errdefer must never free it again.
        gfs_owned_by_mgr = true;
        try self.mgr.createGroupEpoch(
            tenant_id,
            self.node_id,
            epoch,
            raft.manager.grouped_file_storage_vtable,
            gfs,
            &group_raft_config,
        );
        // Success: a later failure below rolls the group back through the manager
        // (which frees gfs) — a single free, no double-free.
        errdefer self.mgr.destroyGroup(tenant_id) catch {};

        self.groups.put(self.allocator, tenant_id, slot) catch return Error.OutOfMemory;
        errdefer _ = self.groups.remove(tenant_id);
        // Record in the node-local manifest so a restart can recover this
        // group (see `groups_manifest`). Best-effort + idempotent: re-recording
        // the same (id_str → epoch) on a recovery-path create is a no-op write;
        // a manifest failure must not abort a working group (recovery is a
        // resilience feature, not a correctness gate for the live group).
        self.recordGroup(id_str, epoch);
        // Formation is activity: a fresh group must tick to elect (multi-node)
        // or campaign-to-leader (single-node). It hibernates once idle.
        try self.bumpActive(tenant_id);
        errdefer self.dropActive(tenant_id);
        try self.growReadyBuf();

        // Campaign-to-leader at birth when this node is the group's SOLE voter —
        // either a single-node node (no transport) OR a multi-node node birthing
        // a group as `{self}` (cluster-genesis-and-membership §3.4: genesis
        // groups are born single-voter and grown by conf-change). A sole-voter
        // group has no peers to elect from and no race — no other node shares
        // this membership — so it leads immediately. A born-MULTI group still
        // elects via ticks; campaigning here would race the peers that have not
        // yet created the group. (`as_learner` splits self out of `voters_slice`,
        // so a learner is never sole-self and never campaigns.)
        const born_sole_self = !recover and voters_slice.len == 1 and voters_slice[0] == self.node_id;
        if (self.isSingleNode() or born_sole_self) {
            try self.mgr.campaign(tenant_id);
            var spins: u32 = 0;
            while (!self.mgr.isLeader(tenant_id) and spins < 100) : (spins += 1) {
                _ = try self.pump();
            }
            if (!self.mgr.isLeader(tenant_id)) return Error.NotCommitted;

            // Recovery: drain the replayed committed entries into the store
            // before returning, so a reader (e.g. the CP's pre-pump store
            // scan) sees the recovered state. The fresh leader commits a
            // no-op then re-delivers the recovered committed log. Drain until
            // the group's applied index stops advancing for a few consecutive
            // cycles — robust against `pump()` returning a non-empty Ready for
            // soft-state with nothing left to apply (which `!pump()` would
            // busy-loop on). Bounded so a pathological log can't spin forever.
            // (Multi-node recovers via ticks + the apply path after the pump
            // thread starts, so no inline drain there.)
            if (recover) {
                // Force the store write during replay (`worker_overlay` leaders
                // normally skip it because the worker's txn wrote it — but at
                // restart there is no worker, so the pump must write).
                self.recovering = true;
                defer self.recovering = false;
                const slot_ptr = self.groups.get(tenant_id) orelse return Error.UnknownGroup;
                var last_applied: u64 = slot_ptr.applied_idx;
                var stable: u32 = 0;
                var drain: u32 = 0;
                while (drain < 100_000 and stable < 3) : (drain += 1) {
                    _ = try self.pump();
                    if (slot_ptr.applied_idx == last_applied) {
                        stable += 1;
                    } else {
                        stable = 0;
                        last_applied = slot_ptr.applied_idx;
                    }
                }
            }
        }

        return slot;
    }

    /// Force this node to start an election for `tenant_id`'s group
    /// (multi-node bootstrap / test convenience). Production failover does
    /// not need this — a follower whose leader goes silent campaigns on its
    /// own election timeout via `tickGroups`.
    pub fn campaign(self: *Node, tenant_id: u64) Error!void {
        try self.mgr.campaign(tenant_id);
    }

    /// Graceful pre-shutdown leadership handoff for `tenant_id`'s group: if
    /// this node leads it, transfer leadership to the most caught-up follower
    /// so a rolling restart costs ~one heartbeat instead of a full election
    /// timeout. Returns the transferee node id, or null if this node does not
    /// lead the group / is the sole voter / the group is unknown. Pump-thread
    /// only (drives the Manager). No-op on a group this node has not created.
    pub fn transferLeadershipAway(self: *Node, tenant_id: u64) ?u64 {
        if (self.groups.get(tenant_id) == null) return null;
        return self.mgr.transferLeadershipAway(tenant_id);
    }

    /// Propose a membership change on `tenant_id`'s group (leader-gated +
    /// quorum-guarded in the FFI). The committed change applies + persists via
    /// the pump apply path. Pump-thread only.
    /// `context` rides the committed conf-change entry (the joining node's
    /// transport address) so every replica learns id→addr via the
    /// conf-change observer as the change applies. Empty = no context.
    pub fn proposeConfChange(self: *Node, tenant_id: u64, node_id: u64, change: raft.Manager.ConfChange, context: []const u8) Error!void {
        return self.mgr.proposeConfChange(tenant_id, node_id, change, context);
    }

    /// Install the committed-conf-change observer on this node's manager (see
    /// `raft.Manager.setConfChangeObserver`). `obs` is caller-owned + must
    /// outlive the node. Call before the pump starts.
    pub fn setConfChangeObserver(self: *Node, obs: *const raft.Manager.ConfChangeObserver) void {
        self.mgr.setConfChangeObserver(obs);
    }

    /// Read `tenant_id`'s current membership into the caller's buffers; null for
    /// an unknown group. Pump-thread only (reads the Manager).
    pub fn confState(self: *Node, tenant_id: u64, voters_buf: []u64, learners_buf: []u64) ?raft.Manager.ConfStateView {
        return self.mgr.confState(tenant_id, voters_buf, learners_buf);
    }

    /// Per-peer replication progress on `tenant_id`'s group from the LEADER's
    /// view: fills `ids`/`matched`/`active` (same length) with each peer voter's
    /// raft id, `matched` index, and `recent_active`, and returns `{len,
    /// leader_last}`. Null on a follower / unknown group (only the leader tracks
    /// peer progress) — the reconciler's "is node N a CAUGHT-UP member" signal,
    /// which conf_state alone can't give (a phantom voter shows in `voters` with
    /// `matched=0`). Pump-thread only (reads the Manager).
    pub const VoterProgressRaw = struct { len: usize, leader_last: u64 };
    pub fn voterProgress(self: *Node, tenant_id: u64, ids: []u64, matched: []u64, active: []u8) ?VoterProgressRaw {
        var out_scratch: [32]raft.Manager.VoterProgress = undefined;
        const cap = @min(@min(ids.len, matched.len), @min(active.len, out_scratch.len));
        const view = self.mgr.voterProgress(tenant_id, ids, matched, active, out_scratch[0..cap]) orelse return null;
        return .{ .len = view.peers.len, .leader_last = view.leader_last };
    }

    /// The term of the log entry at `index` on `tenant_id`'s group, or `null` when
    /// no term is resolvable (compacted / beyond the log / unknown group) — DISTINCT
    /// from a genuine term of 0 at the genesis index. The leader reports
    /// `term(applied)` so a returning learner's promote-back baseline matches its
    /// log. Pump-thread only.
    /// Diagnostic: read this node's raft LOG entry at `index` into `buf` (the
    /// replicated log content — distinct from the served store; settles an
    /// orphaned fold vs divergent logs). Null on unknown group / no entry / buf
    /// too small. Pump-thread only (the Manager + raft_log are pump-owned).
    pub fn logEntry(self: *Node, tenant_id: u64, index: u64, buf: []u8) ?raft.Manager.LogEntry {
        return self.mgr.logEntry(tenant_id, index, buf);
    }

    pub fn logTerm(self: *Node, tenant_id: u64, index: u64) ?u64 {
        return self.mgr.logTerm(tenant_id, index);
    }

    /// This group's local raft last log index (any replica, not leader-gated) —
    /// the reconciler's learner→promote catch-up signal. 0 on unknown group.
    pub fn lastIndex(self: *Node, tenant_id: u64) u64 {
        return self.mgr.lastIndex(tenant_id) orelse 0;
    }

    /// Peer ids in `StateSnapshot` on this (leader) node for `tenant_id` — peers
    /// that fell below the compaction floor and need an out-of-band catch-up
    /// (the snapshot-free `snapshotCb` parks them here). Writes into `ids`,
    /// returns the populated prefix, or null if not leader / unknown group. The
    /// snapshot-trigger tick polls this over led groups. Pump-thread only.
    pub fn snapshotPendingPeers(self: *Node, tenant_id: u64, ids: []u64) ?[]u64 {
        return self.mgr.snapshotPendingPeers(tenant_id, ids);
    }

    /// This group's out-of-band catch-up / move BASELINE index: the durable folded
    /// watermark (`slot.durabilized_idx`), NOT the live `applied_idx`.
    ///
    /// The baseline ships alongside a `StreamDumper.openSnapshot` dump whose content
    /// is the COMMITTED/folded overlay — everything up to `durabilized_idx`. The
    /// baseline index MUST NOT exceed that: the receiver's `apply_local_snapshot`
    /// fast-forwards `committed` to the baseline, and any write above what the
    /// snapshot actually contains is then ≤ its commit / below `first_index`, so it
    /// never replays → a PERMANENT store fork at an agreed log index (the 2026-06-20
    /// prod `__auth__` divergence; `docs/raft-consensus-storage-triage.md` RC-1).
    ///
    /// `applied_idx` is WRONG here: under `worker_overlay` a skipped own-propose
    /// bumps `applied_idx` while its store write still sits in the worker's open txn
    /// (folded only on `noteWorkerCommitted`), so `applied_idx > durabilized_idx` (the
    /// snapshot content). Shipping `applied_idx` over-claims past the snapshot.
    ///
    /// `durabilized_idx` is still a SAFE baseline for the tail to replicate:
    /// mechanism-A compaction truncates to `durabilized_idx − snapshot_grace`
    /// (`durabilizeTick`), so `durabilized_idx` sits `snapshot_grace` entries ABOVE
    /// the leader's first (compacted) index — the member born here starts at an entry
    /// the leader still holds. (The prior comment's claim that the durable watermark
    /// "sits below the compaction floor" was inverted; the floor is
    /// `durabilized − grace`.) 0 on unknown group, and 0 for a fresh group with
    /// nothing folded yet — the trigger skips index 0, correctly deferring catch-up
    /// until a consistent snapshot exists. Pump-thread only (reads pump-owned slot).
    pub fn baselineIndex(self: *Node, tenant_id: u64) u64 {
        const slot = self.groups.get(tenant_id) orelse return 0;
        return slot.durabilized_idx;
    }

    /// Diagnostic: this group's RAW live apply watermark (`slot.applied_idx`) on
    /// THIS node — the highest committed entry the pump has applied. The gap
    /// `applied_idx − durabilized_idx` is the worker-overlay fold lag (the RC-1
    /// window). 0 on unknown group. Pump-thread only.
    pub fn appliedRaw(self: *Node, tenant_id: u64) u64 {
        const slot = self.groups.get(tenant_id) orelse return 0;
        return slot.applied_idx;
    }

    /// Diagnostic: this group's durable folded watermark (`slot.durabilized_idx`)
    /// on THIS node — what `openSnapshot` content reflects. 0 on unknown group.
    /// Pump-thread only. (Same value `baselineIndex` ships; named for the readout.)
    pub fn durabilizedRaw(self: *Node, tenant_id: u64) u64 {
        const slot = self.groups.get(tenant_id) orelse return 0;
        return slot.durabilized_idx;
    }

    /// This group's migration epoch on this node — the value the transport
    /// stamps on every outbound raft message for the group (`mgr.groupEpoch`,
    /// see the SendCtx stamping in `flushOutbound`). A node joining an existing
    /// group MUST birth its local group at the SAME epoch, or the leader's
    /// messages (stamped with the leader's epoch) are FENCED at the receiver and
    /// silently dropped — the join never completes. Genesis groups born via
    /// `ensureGroup` are epoch 0 (e.g. the bootstrap `__admin__` root group);
    /// provisioned/attached groups are epoch 1; a moved group is higher. So the
    /// join must read this and pass it to `v2-attach` rather than assume 1.
    /// 0 on unknown group. Pump-thread only.
    pub fn groupEpoch(self: *Node, tenant_id: u64) u64 {
        return self.mgr.groupEpoch(tenant_id);
    }

    /// Install a DATA-FREE snapshot baseline at {index, term} into `tenant_id`'s
    /// LOCAL group (conf_change promote-back). The node must be a below-floor
    /// learner; the KV state for `index` must already be loaded out-of-band (the
    /// move bundle). Fast-forwards the raft log baseline so the leader can
    /// replicate the tail and the node can be promoted back. Pump-thread only.
    pub fn applyLocalSnapshot(self: *Node, tenant_id: u64, index: u64, term: u64, voters: ?[]const u64, learners: ?[]const u64) Error!void {
        try self.mgr.applyLocalSnapshot(tenant_id, index, term, voters, learners);
        // A2: the baseline fast-forwarded the raft LOG to `index` and the KV state
        // for `index` is already in the store (the out-of-band bundle). Stamp the
        // store's DURABLE applied watermark to `index` as well — otherwise a crash
        // in the rejoin window recovers a store BELOW the raft baseline while the
        // WAL no longer holds entries ≤ index (compacted below the baseline) → the
        // gap between the store watermark and the raft baseline is unrecoverable
        // (lost coverage / divergence). Synchronous, not deferred to
        // durabilizeTick, so the watermark is durable before this returns; stamping
        // the store at/ahead of the (not-yet-durable) raft snapshot errs safe — a
        // store AHEAD of raft only re-applies idempotently on recovery, a store
        // BEHIND raft loses data. For a data-free baseline the overlay is empty, so
        // durabilize() just writes the watermark.
        const slot = self.groups.get(tenant_id) orelse return; // just installed ⇒ present
        if (index > slot.durabilized_idx) {
            const store = self.storeFor(slot, slot.id_str) orelse return Error.UnroutedApply;
            try store.setLastAppliedRaftIdx(index);
            if (index > slot.applied_idx) slot.applied_idx = index;
            slot.durabilized_idx = index;
        }
    }

    /// Snapshot the cross-node heartbeat round-trip histogram (broadcast-time
    /// samples), or null on a single-node node (no transport). Lock-free read
    /// (atomic buckets) — safe off the pump thread.
    pub fn heartbeatRttSnapshot(self: *Node) ?kvlimbs.MicrosHistogram.Snapshot {
        const t = self.transport orelse return null;
        return t.heartbeatRttSnapshot();
    }

    /// Whether this node is the raft leader of `tenant_id`'s group. False
    /// for a group this node has not created yet (a tenant the bridge has
    /// `registerTenant`'d but whose `createGroupEpoch`/`ensureGroup` has not
    /// run here) — guarding the Manager read against an unknown group id.
    pub fn isLeader(self: *const Node, tenant_id: u64) bool {
        if (self.groups.get(tenant_id) == null) return false;
        return self.mgr.isLeader(tenant_id);
    }

    /// The raft id this node believes leads `tenant_id`'s group, or 0 when
    /// unknown (mid-election / no recent leader contact) or the group doesn't
    /// exist here yet. The bridge publishes it to workers as
    /// `GroupSig.leader_id` so a non-leader can redirect a write to the leader.
    pub fn leaderId(self: *const Node, tenant_id: u64) u64 {
        if (self.groups.get(tenant_id) == null) return 0;
        return self.mgr.leaderId(tenant_id);
    }

    /// True when `tenant_id`'s raft group exists on this node. Pump-thread
    /// only (same ownership as every `groups` reader); the bridge publishes
    /// it to workers as `GroupSig.formed` once per leadership refresh.
    pub fn hasGroup(self: *const Node, tenant_id: u64) bool {
        return self.groups.get(tenant_id) != null;
    }

    /// Tear down a tenant's raft group and reclaim its WAL segments (the
    /// Phase-4 move-source cleanup; v2-build-order §Phase 4
    /// "destroyGroup + noteGroupDestroyed on source"). `destroyGroup`
    /// frees the group's `GroupedFileStorage` (and tombstones the id so a
    /// stray later create is rejected); `noteGroupDestroyed` lets the
    /// shared WAL drop this group's segments. Then close + free the slot's
    /// (leader-skip, unwritten) kvexp store and drop it from the active
    /// set. No-op if the group is unknown (idempotent under retried
    /// orchestration). The tenant's durable state is NOT here — it lives
    /// in the worker's `cluster.kv` and is dropped separately by the move
    /// orchestration (`deleteInstance`).
    pub fn destroyGroupAndReclaim(self: *Node, tenant_id: u64) Error!void {
        const slot = self.groups.get(tenant_id) orelse return;
        self.mgr.destroyGroup(tenant_id) catch return Error.DestroyGroupFailed;
        self.wal.noteGroupDestroyed(tenant_id);
        self.dropActive(tenant_id);
        // Drop from the recovery manifest BEFORE freeing the slot (we need its
        // `id_str`): a tenant moved off this node must not be re-stood-up on the
        // next restart.
        self.forgetGroup(slot.id_str);
        _ = self.groups.remove(tenant_id);
        slot.store.close();
        self.allocator.free(slot.id_str);
        self.allocator.destroy(slot);
    }

    fn growReadyBuf(self: *Node) Error!void {
        const need = self.groups.count();
        if (self.ready_buf.len >= need) return;
        const grown = self.allocator.realloc(self.ready_buf, need) catch return Error.OutOfMemory;
        self.ready_buf = grown;
        const grown2 = self.allocator.realloc(self.ready_buf2, need) catch return Error.OutOfMemory;
        self.ready_buf2 = grown2;
    }

    /// Queue `gid` for the post-fsync `onPersist` ack (at most once per
    /// round — see `persist_ack`). Pump-thread only.
    fn notePersistAck(self: *Node, gid: u64) void {
        const slot = self.groups.get(gid) orelse return;
        if (slot.in_persist_ack) return;
        slot.in_persist_ack = true;
        self.persist_ack.append(self.allocator, gid) catch {
            // Dropping the ack would stall the group's commits forever
            // (raft never counts its entries); surface loudly instead.
            slot.in_persist_ack = false;
            self.apply_err = self.apply_err orelse Error.OutOfMemory;
        };
    }

    // ── Hibernation active set (Phase 6) ─────────────────────────────

    fn nowNs() i64 {
        return @intCast(std.time.nanoTimestamp());
    }

    /// Mark a group active: refresh its hibernate deadline and add it to the
    /// tick set if absent. Called on every propose, on formation, and on a
    /// non-heartbeat inbound step — the events that mean "this group has
    /// work," so the pump keeps ticking it. A no-op for an unknown gid.
    /// Pump-thread only (mutates `active` + the slot).
    pub fn bumpActive(self: *Node, gid: u64) Error!void {
        const slot = self.groups.get(gid) orelse return;
        slot.active_until_ns = nowNs() + self.hibernate_ns;
        if (!slot.in_active) {
            self.active.append(self.allocator, gid) catch return Error.OutOfMemory;
            slot.in_active = true;
        }
    }

    /// Pin a group as ALWAYS-active: never hibernated, so it keeps ticking
    /// (heartbeating as leader / running its election timer as follower)
    /// regardless of request activity. The control-plane directory group uses
    /// this — it is ONE group (so always-ticking is O(1)) and MUST stay
    /// available: a directory read never proposes, so a hibernated directory
    /// group whose leader died would never wake to re-elect. Pump-thread only
    /// (or pre-pump). A no-op for an unknown gid.
    pub fn pinActive(self: *Node, gid: u64) Error!void {
        const slot = self.groups.get(gid) orelse return;
        slot.pinned = true;
        slot.active_until_ns = nowNs() + self.hibernate_ns;
        if (!slot.in_active) {
            self.active.append(self.allocator, gid) catch return Error.OutOfMemory;
            slot.in_active = true;
        }
    }

    /// Remove a group from the active set (destroy / errdefer). Clears its
    /// `in_active` flag. O(active); the active set is small by design.
    fn dropActive(self: *Node, gid: u64) void {
        for (self.active.items, 0..) |g, i| {
            if (g == gid) {
                _ = self.active.swapRemove(i);
                break;
            }
        }
        if (self.groups.get(gid)) |slot| slot.in_active = false;
    }

    /// Drop every group whose hibernate deadline has passed from the active
    /// set — the pump stops ticking it, so it stops heartbeating (leader) /
    /// running its election timer (follower) until a propose or non-heartbeat
    /// step wakes it. Run once per pump cycle. Pump-thread only.
    fn sweepHibernated(self: *Node, now: i64) void {
        var i: usize = 0;
        while (i < self.active.items.len) {
            const gid = self.active.items[i];
            const slot = self.groups.get(gid) orelse {
                _ = self.active.swapRemove(i);
                continue;
            };
            // Keep ticking a LEADERLESS group even past its idle deadline: a
            // group with no known leader (this node not leading AND `leaderId`
            // == 0 — e.g. a woken survivor mid-recovery) must keep running its
            // election timer / escalation, else it would re-hibernate frozen
            // before electing. A group with a live leader (leaderId != 0,
            // including this node as leader) hibernates normally.
            const leaderless = !self.mgr.isLeader(gid) and self.mgr.leaderId(gid) == 0;
            if (!slot.pinned and !leaderless and now > slot.active_until_ns) {
                slot.in_active = false;
                _ = self.active.swapRemove(i);
            } else i += 1;
        }
    }

    /// TiKV-style wake-to-elect (the hard-failover recovery): force-campaign any
    /// ACTIVE group that has stayed leaderless past `leaderless_escalate_ns`.
    ///
    /// After a SIGKILL leader loss the surviving voters re-elect on their own
    /// ONLY if their `check_quorum` leases happen to expire in time — a frozen,
    /// just-woken survivor whose `election_elapsed` stalled below the timeout
    /// keeps `leader_id` pointing at the dead leader and IGNORES the normal
    /// (pre-)vote (raft's disruptive-server lease). A force-campaign
    /// (`mgr.campaignForce` → `campaign(CAMPAIGN_TRANSFER)`) sends votes that
    /// carry the transfer context, which receivers honour past their lease — so
    /// recovery is deterministic instead of timing-dependent.
    ///
    /// Trigger: this node is not the leader AND `leaderId == 0` (genuinely
    /// leaderless — a node mid-pre-vote is a `PreCandidate`, which raft sets to
    /// `leader_id == INVALID_ID`, so this also catches the wedged re-pre-voting
    /// case). A live leader (`leaderId != 0`) disarms it, so a healthy group is
    /// never disrupted. Gated on the escalation window so a normal election
    /// completes first; `campaignForce` itself is a safe no-op on a leader,
    /// learner, or pending-conf-change group. Pump-thread only; O(active).
    fn escalateLeaderless(self: *Node, now: i64) void {
        for (self.active.items) |gid| {
            const slot = self.groups.get(gid) orelse continue;
            const leaderless = !self.mgr.isLeader(gid) and self.mgr.leaderId(gid) == 0;
            if (!leaderless) {
                slot.leaderless_since_ns = 0;
                continue;
            }
            if (slot.leaderless_since_ns == 0) {
                slot.leaderless_since_ns = now;
            } else if (now - slot.leaderless_since_ns >= self.leaderless_escalate_ns) {
                self.mgr.campaignForce(gid);
                // Re-arm the window (cooldown) so the next escalation, if the
                // forced campaign also loses (split vote), waits another window
                // rather than force-campaigning every cycle.
                slot.leaderless_since_ns = now;
            }
        }
    }

    /// Propose an encoded envelope to `tenant_id`'s group with no origin
    /// identity (hookless: tests, bare nodes — `origin = seq = 0` matches
    /// no bridge, so the entry is never skipped and advances no
    /// watermark). See `proposeFramed`.
    pub fn propose(self: *Node, tenant_id: u64, env_bytes: []const u8) Error!void {
        return self.proposeFramed(tenant_id, 0, 0, env_bytes);
    }

    /// Propose an encoded envelope stamped with the proposer's identity
    /// (`envelope.EntryFrame`: the bridge's per-boot `origin` + the
    /// per-tenant `seq`). Returns once the entry is staged in raft-rs's
    /// pending list — NOT once applied. Drive `pump` to commit + apply
    /// it. A propose is activity, so it wakes the group (`bumpActive`) —
    /// a hibernated tenant ticks again and replicates the entry. Bump
    /// first so even a propose that raft-rs rejects (non-leader) still
    /// re-ticks the group toward an election.
    pub fn proposeFramed(self: *Node, tenant_id: u64, origin: u64, seq: u64, env_bytes: []const u8) Error!void {
        try self.bumpActive(tenant_id);
        const framed = try envelope.encodeEntryFrame(self.allocator, origin, seq, env_bytes);
        defer self.allocator.free(framed);
        try self.mgr.propose(tenant_id, framed);
    }

    /// Build a type-0 writeset envelope from `ws` and propose it, then
    /// pump until it commits + applies to the tenant's store (or the
    /// budget is exhausted → `NotCommitted`). Returns the applied index.
    pub fn proposeWriteSet(self: *Node, tenant_id: u64, id_str: []const u8, ws: *const WriteSet) Error!u64 {
        const slot = try self.ensureGroup(tenant_id, id_str);
        const before = slot.applied_idx;

        const ws_bytes = ws.encode(self.allocator) catch return Error.OutOfMemory;
        defer self.allocator.free(ws_bytes);
        const env = try envelope.encodeWriteSet(self.allocator, id_str, ws_bytes);
        defer self.allocator.free(env);

        try self.propose(tenant_id, env);

        var spins: u32 = 0;
        while (slot.applied_idx == before and spins < 200) : (spins += 1) {
            _ = try self.pump();
        }
        if (slot.applied_idx == before) return Error.NotCommitted;
        return slot.applied_idx;
    }

    /// Drive one ready cycle across the active set. Returns true if any
    /// group had committed entries to apply this cycle.
    ///
    /// The async-append pump (persist-before-quorum ordering): tick the
    /// active set, then
    ///
    ///   pass 1: processReady every ready group — appends are BUFFERED
    ///           into the shared WAL; committed entries handed out here
    ///           were already durable (raft gates them on its persist
    ///           watermark) and apply now
    ///   fsync:  ONE `wal.flush()` for the whole cycle (the load-bearing
    ///           single-fsync constraint)
    ///   ack:    `mgr.onPersist` per buffered group — only now do this
    ///           node's entries count toward the commit quorum, and only
    ///           now do the stashed persistence-asserting messages
    ///           (append acks / vote responses) reach the outboxes
    ///   pass 2: the acks unlock commit advances — poll + apply the
    ///           newly-committed entries in the same cycle
    ///   hooks:  fire the staged commit notifications (everything applied
    ///           this cycle is fsync-covered)
    ///   drain:  takeMessages + release for both passes' groups.
    ///
    /// Single-node has no peers, so `takeMessages` drains to a no-op
    /// sink — but the drain+release is still required to honour the
    /// pollReady/release pairing invariant.
    pub fn pump(self: *Node) Error!bool {
        // Raft logical tick — interval-gated so the wall-clock election timeout
        // is `election_tick × tick_interval_ns`, a fixed number, rather than
        // floating with the pump loop / fsync cadence (see `DEFAULT_TICK_NS`).
        // pollReady / processReady / transport I/O below still run EVERY cycle;
        // only the tick is gated. Single-tick-when-due (not catch-up bursts):
        // after a stall the timer just resumes, which is conservative — slower
        // elections, never a spurious burst.
        {
            const now = nowNs();
            if (now - self.last_tick_ns >= self.tick_interval_ns) {
                self.last_tick_ns = now;
                _ = self.mgr.tickGroups(self.active.items);
            }
        }
        const ready = self.mgr.pollReady(self.ready_buf);

        self.apply_err = null;
        var ready2: []u64 = self.ready_buf2[0..0];
        if (ready.len > 0 or self.persist_ack.items.len > 0) {
            self.commit_notify.clearRetainingCapacity();
            // Pass 1: append this round's writes (BUFFERED — the fsync is
            // below) and apply committed entries that were already durable
            // from earlier cycles (raft gates handed-out committed entries
            // on its persist watermark). Every processed ready is queued
            // for the post-fsync ack.
            for (ready) |g| {
                self.mgr.processReady(g, applyCb, self) catch |e| {
                    self.apply_err = self.apply_err orelse mapRaftErr(e);
                };
                self.notePersistAck(g);
            }

            // ONE fsync per cycle regardless of how many groups committed.
            const flushed = blk: {
                self.wal.flush() catch {
                    self.apply_err = self.apply_err orelse Error.Io;
                    break :blk false;
                };
                break :blk true;
            };

            if (flushed) {
                // Persist ack (the async-append handshake): the fsync now
                // covers every buffered append, so tell raft — this is the
                // point this node's entries start counting toward the
                // commit quorum, and it releases the stashed persistence-
                // asserting messages (append acks / vote responses) into
                // the outboxes. On a failed flush the list is RETAINED:
                // no ack, no acks on the wire, commits stay locked until
                // a later successful fsync — never durability claimed for
                // volatile bytes.
                for (self.persist_ack.items) |g| {
                    self.mgr.onPersist(g);
                    if (self.groups.get(g)) |slot| slot.in_persist_ack = false;
                }
                self.persist_ack.clearRetainingCapacity();

                // Pass 2: the acks commonly unlock a commit advance — the
                // newly-committed entries surface as fresh readies. Apply
                // them NOW so a single-node propose still commits within
                // one pump cycle. Anything pass 2 buffers (typically the
                // advanced commit index riding the next hard state) is
                // covered by the NEXT cycle's fsync+ack — pass-2 groups
                // re-enter `persist_ack`, and the `persist_ack.items.len`
                // arm of the enclosing `if` guarantees that next round
                // runs even if nothing else is ready.
                ready2 = self.mgr.pollReady(self.ready_buf2);
                for (ready2) |g| {
                    self.mgr.processReady(g, applyCb, self) catch |e| {
                        self.apply_err = self.apply_err orelse mapRaftErr(e);
                    };
                    self.notePersistAck(g);
                }

                // Fire the commit hook ONLY now: the hook advances the
                // per-tenant watermark the worker acks clients on. Pass-1
                // applies were durable before this cycle; pass-2 applies
                // are covered by this cycle's fsync. On flush failure the
                // notifications are DROPPED: parked workers time out →
                // 503, the correct "unknown outcome" signal (never a
                // false durable ack).
                if (self.commit_hook) |h| {
                    for (self.commit_notify.items) |n| h.func(h.ctx, n.gid, n.origin, n.seq, n.idx);
                }
            }
            self.commit_notify.clearRetainingCapacity();

            // Drain each ready group's outbox (both passes; `release` is
            // dup-tolerant and re-notifies if work landed mid-round).
            // Single-node: queued to a transport-less sink (a no-op).
            // Multi-node: buffered per destination node, stamped with the
            // group's migration epoch, for the coalesced flush below. (No
            // cross-node compaction floor is sent — mechanism-A compaction is
            // per-node; the floor wire field was removed in Phase 2f.)
            for (ready) |g| {
                var sctx: SendCtx = .{ .node = self, .group_id = g, .epoch = self.mgr.groupEpoch(g) };
                self.mgr.takeMessages(g, sendMsgCb, &sctx) catch {};
                self.mgr.release(g);
            }
            for (ready2) |g| {
                var sctx: SendCtx = .{ .node = self, .group_id = g, .epoch = self.mgr.groupEpoch(g) };
                self.mgr.takeMessages(g, sendMsgCb, &sctx) catch {};
                self.mgr.release(g);
            }
        }

        const now = nowNs();

        // Always drive the transport (multi-node): flush this cycle's
        // coalesced sends, then a non-blocking tick that submits them and
        // delivers any inbound envelopes (→ stepBatch). Done every cycle —
        // not just when a group committed — so heartbeats/elections flow
        // and inbound messages are stepped even on an otherwise idle node.
        if (self.transport) |t| {
            t.flush();
            t.tick(now, 0) catch |e| {
                // A transport tick failure is a silent partition in the
                // making (nothing sent or received this cycle) — log it
                // rate-limited so a persistently broken transport is
                // operator-visible instead of an unexplained quorum loss.
                self.transport_err_count +%= 1;
                if (self.transport_err_count == 1 or self.transport_err_count % 1000 == 0) {
                    std.log.warn(
                        "v2 node {d}: transport tick failed ({s}) — {d} failures so far",
                        .{ self.node_id, @errorName(e), self.transport_err_count },
                    );
                }
            };
            // Wake any group that received a NON-heartbeat message this cycle
            // (real raft traffic = work). Heartbeats are skipped on purpose
            // (§3.1) so a quiet group can't keep itself awake.
            self.woke_scratch.clearRetainingCapacity();
            t.drainWoke(&self.woke_scratch, self.allocator) catch {};
            for (self.woke_scratch.items) |gid| self.bumpActive(gid) catch {};
        }

        // Hibernate: stop ticking any group idle past its deadline (but keep a
        // leaderless group ticking so it can recover — see `sweepHibernated`).
        self.sweepHibernated(now);

        // Wake-to-elect: force-campaign any group wedged leaderless past the
        // escalation window, bypassing peers' check_quorum leases (TiKV-style
        // hard-failover recovery — see `escalateLeaderless`).
        self.escalateLeaderless(now);

        // Leader-side auto-demote: drop a far-behind, presumed-dead voter to a
        // learner so it stops pinning the WAL-compaction floor. Before the
        // durabilize so a demote's higher floor takes effect this same tick.
        self.autoDemoteTick(now);

        // Checkpoint: fold each dirty store's overlay into LMDB + stamp its
        // watermark + (single-node) compact the WAL. Interval-gated, O(dirty).
        self.durabilizeTick(now);

        if (self.apply_err) |e| {
            self.apply_err = null;
            return e;
        }
        return ready.len > 0 or ready2.len > 0;
    }

    /// Checkpoint dirty stores (V2 port of V1's `Cluster.tickSnapshot`).
    /// Interval-gated. For each group with committed-but-not-durable writes,
    /// fold its overlay into LMDB + stamp `lastAppliedRaftIdx` (one atomic
    /// durabilize), then compact the shared WAL so the log stays bounded.
    /// Compaction is mechanism A (raft-native-alignment §I4): truncate to a FIXED
    /// catch-up buffer (`snapshot_grace`) below the durable apply watermark, PER
    /// NODE INDEPENDENTLY — no cross-node min-match floor, no lockstep, no
    /// leader/follower asymmetry. A peer within the buffer catches up from the
    /// log; a peer further back trips raft's `StateSnapshot` and is recovered by
    /// the out-of-band snapshot catch-up driver. Pump-thread only. All dirty
    /// groups are flushed in one tick so the shared WAL's interleaved commits
    /// clear together.
    fn durabilizeTick(self: *Node, now: i64) void {
        if (self.dirty.items.len == 0) return;
        if (now - self.last_durabilize_ns < self.durabilize_interval_ns) return;
        self.last_durabilize_ns = now;
        // Under the async-append flow the durable HardState.commit lags
        // the live commit by one fsync (it rides the NEXT ready's hard
        // state). Compaction must never truncate past a commit index that
        // is not yet durable — a crash right after the truncate would
        // recover hs.commit < first_index-1 and panic `RawNode::new`. One
        // flush before the first compact of the tick closes the lag; lazy
        // so a tick that compacts nothing pays nothing.
        var compaction_flushed = false;
        // Iterate with a retain cursor: a slot whose fold could not reach
        // `applied_idx` this tick (durabilize floor below it, or a fold
        // error) STAYS dirty so a later tick finishes the job — without
        // this, a one-shot stamp left the un-foldable tail volatile
        // forever (an idle tenant's last write never re-folded).
        var keep: usize = 0;
        for (self.dirty.items) |gid| {
            const slot = self.groups.get(gid) orelse continue;
            // The fold target: how far the store's overlay actually covers.
            // In worker_overlay mode a skipped entry's writes sit in the
            // worker's OPEN txn until the worker acks (`noteWorkerCommitted`)
            // — folding/stamping/compacting past it would claim durability
            // for data the fold cannot see (crash ⇒ acked write lost, WAL
            // already truncated). The bridge's floor is `maxInt` when
            // nothing is awaited.
            var target = slot.applied_idx;
            if (self.durabilize_floor) |f| target = @min(target, f.func(f.ctx, gid));
            // Mechanism-A WAL compaction (raft-native-alignment §I4): truncate to
            // a FIXED catch-up buffer below the durable apply watermark, PER NODE
            // INDEPENDENTLY — no cross-node min-match floor, no propagated floor,
            // no leader/follower asymmetry. A peer within `snapshot_grace` of the
            // cap catches up from the log; a peer further back trips raft's
            // `StateSnapshot` and is recovered out-of-band by the snapshot
            // catch-up driver (the `snapshotTriggerTick` → `SnapshotCatchupThread`
            // path). The fixed buffer is the bound: a dead/stuck peer falls out of
            // it and snapshots rather than pinning the WAL. Constrains only
            // truncation; the LMDB fold of the full applied tail above is
            // unaffected.
            const compact_target = target -| self.snapshot_grace;
            if (target <= slot.durabilized_idx) {
                // Nothing foldable yet — keep the slot dirty and retry
                // next tick (the worker ack raises the floor).
                self.dirty.items[keep] = gid;
                keep += 1;
                continue;
            }
            const store = self.storeFor(slot, slot.id_str) orelse {
                // Resolver failure — retry next tick rather than
                // stranding an in_dirty=true slot outside the list.
                self.dirty.items[keep] = gid;
                keep += 1;
                continue;
            };
            store.setLastAppliedRaftIdx(target) catch |e| {
                std.log.warn("v2 durabilize gid={d}: {s}", .{ gid, @errorName(e) });
                self.dirty.items[keep] = gid;
                keep += 1;
                continue;
            };
            // Compact when enabled (single-, leader-, AND follower-side now —
            // everyone truncates to the same propagated floor). Skip when
            // `compact_target` is 0 (a follower that hasn't heard a floor yet)
            // so a floorless group doesn't trigger the pre-compact flush.
            if (self.compact_wal and compact_target > 0) {
                if (!compaction_flushed) {
                    self.wal.flush() catch |e| {
                        // Can't make the commit index durable — skip ALL
                        // compaction this tick (the stamp above already
                        // happened, which is fine: durabilize ≠ truncate).
                        std.log.warn("v2 wal pre-compact flush: {s}", .{@errorName(e)});
                        slot.durabilized_idx = target;
                        if (slot.applied_idx > target) {
                            self.dirty.items[keep] = gid;
                            keep += 1;
                        } else slot.in_dirty = false;
                        continue;
                    };
                    compaction_flushed = true;
                }
                // Truncate to `compact_target` (≤ `target`): the leader's
                // min-match floor keeps the log entries lagging followers still
                // need. No-op when `compact_target` is at/below the current
                // sentinel.
                slot.gfs.compact(compact_target) catch |e| {
                    std.log.warn("v2 wal compact gid={d}: {s}", .{ gid, @errorName(e) });
                };
            }
            slot.durabilized_idx = target;
            if (slot.applied_idx > target) {
                // Partially folded (floor held back the tail): stay dirty.
                self.dirty.items[keep] = gid;
                keep += 1;
            } else {
                slot.in_dirty = false;
            }
        }
        self.dirty.shrinkRetainingCapacity(keep);
    }

    /// Leader-side auto-demote policy (conf_change Phase 2). For each group this
    /// node leads with un-durabilized writes (so the log is actively advancing
    /// and a dead voter is pinning the WAL floor), demote the first voter that
    /// is BOTH far behind (`lag > auto_demote_lag`) AND `!recent_active` to a
    /// learner — it can no longer form quorum anyway, so this loses no real
    /// availability while unpinning `minMatchIndex` so the WAL truncates. At most
    /// one demote per group per pass (a raft conf-change must commit before the
    /// next is proposed). Interval-gated + warmup-skipped so a freshly-started or
    /// freshly-elected leader gives peers a window to check in first. Gated on
    /// `compact_wal` (the only benefit is unpinning compaction) and a non-zero
    /// `auto_demote_lag`. Pump-thread only.
    fn autoDemoteTick(self: *Node, now: i64) void {
        if (self.auto_demote_lag == 0 or !self.compact_wal) return;
        if (self.dirty.items.len == 0) return;
        // Warmup: the first pass after start/elect just stamps the clock and
        // returns, so peers get a full interval to report in before we judge
        // them dead (`last_auto_demote_ns` starts at 0 ⇒ would fire immediately).
        if (self.last_auto_demote_ns == 0) {
            self.last_auto_demote_ns = now;
            return;
        }
        if (now - self.last_auto_demote_ns < self.auto_demote_interval_ns) return;
        self.last_auto_demote_ns = now;

        var ids_buf: [16]u64 = undefined;
        var matched_buf: [16]u64 = undefined;
        var active_buf: [16]u8 = undefined;
        var prog_buf: [16]raft.Manager.VoterProgress = undefined;
        for (self.dirty.items) |gid| {
            if (!self.mgr.isLeader(gid)) continue;
            const view = self.mgr.voterProgress(gid, &ids_buf, &matched_buf, &active_buf, &prog_buf) orelse continue;
            for (view.peers) |p| {
                if (p.recent_active) continue; // still in contact — keep it
                const lag = view.leader_last -| p.matched;
                if (lag <= self.auto_demote_lag) continue;
                // Demote this dead, far-behind voter to a learner. One per group
                // per pass; the FFI quorum-guard refuses a demote that would drop
                // below 2 voters (swallowed — expected, not an error here).
                self.mgr.proposeConfChange(gid, p.id, .add_learner, "") catch |e| switch (e) {
                    raft.Error.ConfChangeQuorumGuard => {
                        std.log.debug("v2 auto-demote gid={d} node={d}: refused (would drop below 2 voters)", .{ gid, p.id });
                        break;
                    },
                    else => {
                        std.log.warn("v2 auto-demote gid={d} node={d}: propose failed: {s}", .{ gid, p.id, @errorName(e) });
                        break;
                    },
                };
                std.log.info(
                    "v2 auto-demote gid={d}: voter {d} demoted to learner (lag={d} > {d}, !recent_active) — unpinning WAL floor",
                    .{ gid, p.id, lag, self.auto_demote_lag },
                );
                break; // one conf-change per group per pass
            }
        }
    }

    /// Enqueue `slot` for the next `durabilizeTick` if not already (its
    /// `applied_idx` just advanced past `durabilized_idx`). Pump-thread only.
    fn markDirty(self: *Node, slot: *TenantSlot) void {
        if (slot.in_dirty) return;
        slot.in_dirty = true;
        self.dirty.append(self.allocator, slot.tenant_id) catch {
            slot.in_dirty = false; // best-effort; recovery still covers it
        };
    }

    /// Read a committed key from a tenant's store. Caller owns the
    /// returned bytes (`allocator.free`). `Error.NotFound` if absent.
    pub fn get(self: *Node, tenant_id: u64, key: []const u8) Error![]u8 {
        const slot = self.groups.get(tenant_id) orelse return Error.UnknownGroup;
        return slot.store.get(key);
    }

    /// Prefix-scan a group's store (one page; `cursor` resumes a prior page,
    /// `""` starts). The caller owns + frees the returned `RangeResult`. Like
    /// `get`, this reads the slot store directly, so it is only safe off the
    /// pump thread for a STABLE group whose slot is fixed (the CP directory
    /// group, scanned at boot before the pump thread starts). The CP uses it
    /// to materialize its in-memory placement projection from the replicated
    /// store on startup (a directory write survives a restart).
    pub fn prefix(
        self: *Node,
        tenant_id: u64,
        prefix_bytes: []const u8,
        cursor: []const u8,
        count: u32,
    ) Error!RangeResult {
        const slot = self.groups.get(tenant_id) orelse return Error.UnknownGroup;
        return slot.store.prefix(prefix_bytes, cursor, count);
    }

    // ── apply path ──────────────────────────────────────────────────

    /// C-ABI apply callback: fires once per committed entry during
    /// `processReady`. Decodes the envelope and routes it to the
    /// tenant's store. Errors are stashed in `self.apply_err` (the
    /// callback can't return one) and checked by `pump`.
    fn applyCb(
        ud: ?*anyopaque,
        group_id: u64,
        index: u64,
        term: u64,
        data: [*c]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = term;
        const self: *Node = @ptrCast(@alignCast(ud.?));
        if (self.apply_err != null) return; // already failed this round
        // raft-rs emits empty entries (e.g. the leader's no-op on
        // election). Nothing to apply.
        if (len == 0) return;
        const bytes = data[0..len];
        const frame = envelope.decodeEntryFrame(bytes) catch |e| {
            self.apply_err = e;
            return;
        };
        self.applyEntry(group_id, index, frame) catch |e| {
            self.apply_err = e;
            return;
        };
        // The entry committed + applied cleanly: STAGE the bridge
        // notification (advancing the tenant's committed_seq watermark).
        // `pump` fires it after the cycle's `wal.flush()` succeeds — the
        // watermark is the durable-ack signal, so it must not run ahead
        // of the fsync. Staged only on the success path, so the leader's
        // empty election no-op (len==0, returned above) and any
        // undecodable entry (apply_err, returned above) never advance a
        // tenant's watermark. A staging failure (OOM) is surfaced as an
        // apply error rather than silently losing the waiter's wakeup.
        if (self.commit_hook != null) {
            self.commit_notify.append(self.allocator, .{
                .gid = group_id,
                .origin = frame.origin,
                .seq = frame.seq,
                .idx = index,
            }) catch {
                self.apply_err = Error.OutOfMemory;
            };
        }
    }

    fn applyEntry(self: *Node, group_id: u64, index: u64, frame: envelope.EntryFrame) Error!void {
        const env = try envelope.decode(frame.env_bytes);
        // Decide whether the pump writes the store, or only advances the
        // watermark (the worker's TrackedTxn.commit is the durable write).
        // `worker_overlay` keys this on PROVENANCE via the bridge's
        // `skip_query`: skip iff the entry is this node's own live propose
        // (origin matches and the seq's worker txn is still pending —
        // that txn IS the store write). Everything else is written by the
        // pump: a follower's replicated entries, a freshly-elected
        // leader's catch-up entries proposed elsewhere, a replayed entry
        // at recovery (no live txns at boot), and an entry whose local
        // waiter already gave up (fault/timeout rolled the txn back and
        // abandoned the seq).
        const skip_store = if (self.recovering)
            // Replaying the WAL at restart: there is no worker to have written
            // the store, so the pump MUST write it (and durabilize the tail).
            false
        else switch (self.apply_mode) {
            .apply_on_commit => false,
            .leader_skip => true,
            .worker_overlay => blk: {
                if (self.skip_query) |q|
                    break :blk q.func(q.ctx, group_id, frame.origin, frame.seq);
                // No bridge (bare-node tests): the old role-keyed skip.
                break :blk self.mgr.isLeader(group_id);
            },
        };
        if (skip_store) {
            // We still decode (above) so a stale/unknown envelope type
            // surfaces loudly, and bump applied_idx — but we do NOT touch
            // the store. Root writesets (no per-tenant group) are a no-op
            // here too; their durable write also rode the worker's txn. The
            // worker DID write its own overlay (inst.kv), so the group is still
            // dirty: `durabilizeTick` folds that overlay + stamps the watermark.
            if (self.groups.get(group_id)) |slot| {
                slot.applied_idx = index;
                self.markDirty(slot);
            }
            return;
        }
        const slot = self.groups.get(group_id) orelse return Error.UnknownGroup;
        switch (env.type) {
            .writeset => {
                const store = self.storeFor(slot, env.id) orelse return Error.UnroutedApply;
                // Strip the readset frame; apply the writeset bytes (the
                // readset rides for the tape, not the store).
                const wp = try envelope.decodeWriteSetPayload(env.payload);
                try writeset.applyEncodedDirect(store, index, wp.ws_bytes);
                self.notifyApply(group_id, env.id, wp.ws_bytes);
            },
            .multi => {
                const inner = try envelope.decodeMultiInner(self.allocator, env.payload);
                defer self.allocator.free(inner);
                for (inner) |inner_bytes| {
                    const ie = try envelope.decode(inner_bytes);
                    switch (ie.type) {
                        .writeset => {
                            // Inner writesets route by THEIR OWN id — an
                            // admin batch's cross-tenant trampoline inner
                            // (`proposeBatch` targets) names a tenant
                            // other than the anchor group's, and writing
                            // it into the anchor's store would corrupt
                            // both tenants on a follower / at recovery
                            // replay.
                            const store = self.storeFor(slot, ie.id) orelse return Error.UnroutedApply;
                            const wp = try envelope.decodeWriteSetPayload(ie.payload);
                            try writeset.applyEncodedDirect(store, index, wp.ws_bytes);
                            self.notifyApply(group_id, ie.id, wp.ws_bytes);
                        },
                        .multi => return envelope.Error.NestedMulti,
                        // A root inner (`platform.root.*` riding the admin
                        // batch). Raw writeset payload — root envelopes
                        // are not readset-framed.
                        .root_writeset => {
                            const store = self.storeFor(slot, "") orelse return Error.UnroutedApply;
                            try writeset.applyEncodedDirect(store, index, ie.payload);
                            self.notifyApply(group_id, "", ie.payload);
                        },
                    }
                }
            },
            // A bare root writeset (rides the reserved root group, whose
            // slot id is `""` — so the no-resolver fallback in `storeFor`
            // routes it to that group's own slot store). Raw payload (no
            // readset frame).
            .root_writeset => {
                const store = self.storeFor(slot, "") orelse return Error.UnroutedApply;
                try writeset.applyEncodedDirect(store, index, env.payload);
                self.notifyApply(group_id, "", env.payload);
            },
        }
        // One entry applied (all inners included): advance the group's
        // applied index and queue it for the durabilize checkpoint.
        slot.applied_idx = index;
        self.markDirty(slot);
    }

    /// The store a committed writeset (or `multi` inner) targeting `id_str`
    /// applies to. With a `store_resolver` set (the bridge fronting a
    /// worker), the resolver routes by id — the worker's own per-tenant
    /// serving store for a tenant id, the node-wide root store for `""` —
    /// so a follower's replicated writes (including an admin batch's
    /// cross-tenant inners) land in the SAME stores the worker serves from
    /// (Phase 5 "Full HA"). Without a resolver (the bare-node multi-node +
    /// Phase-1 tests, the CP) only the group's OWN id routes — to the slot
    /// store; a cross-tenant or root target has nowhere to land and
    /// surfaces as null (→ `UnroutedApply`, an invariant violation: those
    /// producers only exist on worker-fronted nodes, which set a resolver).
    fn storeFor(self: *Node, slot: *TenantSlot, id_str: []const u8) ?*KvStore {
        if (self.store_resolver) |r| return r.func(r.ctx, slot.tenant_id, id_str);
        if (std.mem.eql(u8, id_str, slot.id_str)) return slot.store;
        return null;
    }

    /// Fire the `apply_observer` (if set) once per PUT in a just-applied
    /// writeset. `id_str` is the tenant id the writeset targeted (the
    /// inner's id for a multi inner, `""` for a root writeset). Re-decodes
    /// the writeset bytes — cheap for the single-op writes the observers
    /// care about. Best-effort: the bytes already applied cleanly via
    /// `applyEncoded`, so a decode error here is not propagated (it would
    /// only mean a stale projection, recovered on the next apply / restart
    /// scan).
    fn notifyApply(self: *Node, group_id: u64, id_str: []const u8, ws_bytes: []const u8) void {
        const obs = self.apply_observer orelse return;
        var ops: std.ArrayListUnmanaged(writeset.Op) = .empty;
        defer ops.deinit(self.allocator);
        writeset.decodeOps(ws_bytes, self.allocator, &ops) catch return;
        for (ops.items) |op| switch (op) {
            .put => |p| obs.func(obs.ctx, group_id, id_str, p.key, p.value),
            // The directory never deletes; ignore (a future deleting producer
            // would extend the observer with a delete arm).
            .delete => {},
        };
    }

    /// Context for `sendMsgCb`: which group's outbox is being drained (so
    /// each message carries its group id + migration epoch into the
    /// coalesced envelope). Lives on the pump's stack for the takeMessages
    /// call.
    const SendCtx = struct {
        node: *Node,
        group_id: u64,
        epoch: u64,
    };

    /// `takeMessages` callback: buffer one outbound raft message into the
    /// transport for its destination node. No-op when there is no transport
    /// (single-node), so the single-node pump's drain stays a sink.
    fn sendMsgCb(
        ud: ?*anyopaque,
        to: u64,
        msg_bytes: [*c]const u8,
        msg_len: usize,
    ) callconv(.c) void {
        const ctx: *SendCtx = @ptrCast(@alignCast(ud.?));
        const t = ctx.node.transport orelse return;
        const bytes = if (msg_len == 0) &[_]u8{} else msg_bytes[0..msg_len];
        t.queueOut(to, ctx.group_id, ctx.epoch, bytes);
    }

};

/// Narrow a raft-rs error to the node's `Error` set (they overlap, but
/// the union above already includes `raft.Error`, so this is identity —
/// kept as a seam for when the two sets diverge).
fn mapRaftErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.ProcessReadyFailed,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "PeerRegistry: learn / resolve / insert-only / learnAddr parsing" {
    const a = testing.allocator;
    const reg = try PeerRegistry.create(a);
    defer reg.destroy();

    const r = reg.resolver();

    // unknown id → null
    try testing.expect(r.resolve(7) == null);

    // learn + resolve
    try reg.learn(2, "10.0.0.2", 9001);
    {
        const pa = r.resolve(2).?;
        try testing.expectEqualStrings("10.0.0.2", pa.host);
        try testing.expectEqual(@as(u16, 9001), pa.port);
    }

    // insert-only: a repeat for a known id is ignored (re-IP is out of scope)
    try reg.learn(2, "10.9.9.9", 1);
    {
        const pa = r.resolve(2).?;
        try testing.expectEqualStrings("10.0.0.2", pa.host);
        try testing.expectEqual(@as(u16, 9001), pa.port);
    }

    // learnAddr parses host:port (the wire form the CP carries)
    try reg.learnAddr(3, "192.168.1.5:7000");
    {
        const pa = r.resolve(3).?;
        try testing.expectEqualStrings("192.168.1.5", pa.host);
        try testing.expectEqual(@as(u16, 7000), pa.port);
    }

    // malformed addr → BadConfig; id 0 ignored
    try testing.expectError(error.BadConfig, reg.learnAddr(4, "no-colon"));
    try testing.expectError(error.BadConfig, reg.learnAddr(4, "h:notaport"));
    try reg.learn(0, "x", 1); // no-op, no entry
    try testing.expect(r.resolve(0) == null);
}

test "Phase 1 exit: propose a writeset, it commits + applies, a read sees it" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    const tenant: u64 = 42;
    const id = "tenant-42";

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("greeting", "hello-v2");
    try ws.addPut("count", "1");

    const applied = try node.proposeWriteSet(tenant, id, &ws);
    try testing.expect(applied > 0);

    const got = try node.get(tenant, "greeting");
    defer a.free(got);
    try testing.expectEqualStrings("hello-v2", got);

    const got2 = try node.get(tenant, "count");
    defer a.free(got2);
    try testing.expectEqualStrings("1", got2);
}

test "createGroupAtEpoch: a RawNode-rejected config errors cleanly (no gfs double-free)" {
    // Regression for the genesis SIGABRT. A born-{self} group attached as a
    // LEARNER splits self out of the voter set → ConfState{voters:[], learners:
    // [self]}, which raft-rs's RawNode::new REJECTS (no voters → no quorum). The
    // FFI returns -3 AFTER taking the storage into an FfiStorage whose Drop frees
    // it via the destroy vtable (raft-rs-zig manager.zig documents + tests this).
    // createGroupCore must NOT also free gfs — a bare `errdefer gfs.deinit()`
    // double-freed it (the GP fault in raft-rs storage deinit). Assert a clean
    // error, and that the node survives to form a normal group afterwards.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    // voters_override={1} + as_learner=true → self(1) split out → voters=[], learners=[1].
    const voters = [_]u64{1};
    try testing.expectError(Error.CreateGroupFailed, node.createGroupAtEpoch(99, "x", 1, true, &voters));

    // No double-free crash, no leak, and the node is still usable: a normal
    // single-node group still forms + commits.
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    const applied = try node.proposeWriteSet(7, "ok", &ws);
    try testing.expect(applied > 0);
}

test "durabilize: the pump checkpoints the store + stamps the raft watermark" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();
    node.durabilize_interval_ns = 0; // durabilize on every cycle (no gating)

    const tenant: u64 = 7;
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    const applied = try node.proposeWriteSet(tenant, "t7", &ws);
    try testing.expect(applied > 0);

    // A few cycles so the durabilize tick definitely ran post-apply.
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = try node.pump();

    const slot = node.groups.get(tenant).?;
    // The overlay was folded into LMDB and the durable raft watermark was
    // stamped up to the applied index (so a restart replays only past here).
    try testing.expectEqual(applied, try slot.store.lastAppliedRaftIdx());
    try testing.expectEqual(applied, slot.durabilized_idx);
    try testing.expect(slot.in_dirty == false); // drained from the dirty set

    // Data is still readable after durabilize.
    const got = try node.get(tenant, "k");
    defer a.free(got);
    try testing.expectEqualStrings("v", got);
}

test "a delete in a later writeset removes the key" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    const tenant: u64 = 7;
    const id = "t7";

    var ws1 = WriteSet.init(a);
    defer ws1.deinit();
    try ws1.addPut("k", "v");
    _ = try node.proposeWriteSet(tenant, id, &ws1);

    const got = try node.get(tenant, "k");
    a.free(got);

    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addDelete("k");
    const idx2 = try node.proposeWriteSet(tenant, id, &ws2);
    try testing.expect(idx2 > 0);

    try testing.expectError(Error.NotFound, node.get(tenant, "k"));
}

test "Phase 5: 3-node cluster elects a leader + replicates a committed write" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const voters = [_]u64{ 1, 2, 3 };
    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/n1", .{root}),
        try std.fmt.allocPrint(a, "{s}/n2", .{root}),
        try std.fmt.allocPrint(a, "{s}/n3", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    // Peers must agree on fixed addresses (no ephemeral binding). This test
    // is compiled into BOTH the node and bridge test binaries (bridge
    // imports node.zig relatively) which zig runs in parallel, and reruns
    // leave listen ports in TIME_WAIT — so try several well-separated bases
    // (seeded by PID) until all three bind, and skip if the host has no
    // free window at all.
    var nodes: [3]*Node = undefined;
    // `alive` tracks which nodes are stood up, so the cleanup defer never
    // double-frees one the failover leg kills mid-test.
    var alive = [_]bool{ false, false, false };
    defer for (nodes, 0..) |n, i| if (alive[i]) n.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    var attempt: u32 = 0;
    while (attempt < 24) : (attempt += 1) {
        const base: u16 = @intCast(20000 + ((pid +% attempt *% 619) % 4000) * 8);
        var ok = true;
        for (0..3) |i| {
            var peers: [3]PeerAddr = undefined;
            for (&peers, 0..) |*p, k| p.* = .{ .host = "127.0.0.1", .port = base + @as(u16, @intCast(k)) };
            const addr = std.net.Address.parseIp("127.0.0.1", base + @as(u16, @intCast(i))) catch {
                ok = false;
                break;
            };
            nodes[i] = Node.initMultiNode(a, dirs[i], @intCast(i + 1), &voters, addr, &peers) catch {
                ok = false;
                break;
            };
            alive[i] = true;
        }
        if (ok) break;
        for (0..3) |i| if (alive[i]) {
            nodes[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1] and alive[2])) return error.SkipZigTest; // no free window

    const tenant: u64 = 100;
    const id = "tenant-100";
    // Create the group on all three nodes (multi-node: no campaign at birth).
    for (nodes) |n| _ = try n.ensureGroup(tenant, id);

    // Warm the mesh: drive every pump so the io_uring/TCP handshakes
    // complete before we campaign.
    var warm: u32 = 0;
    while (warm < 150) : (warm += 1) {
        for (nodes) |n| _ = try n.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // Elect node 1 (deterministic + fast; a dropped pre-connect vote is
    // retried by the election-timeout path as a backstop).
    try nodes[0].campaign(tenant);

    var leader_idx: ?usize = null;
    var spins: u32 = 0;
    while (spins < 2000 and leader_idx == null) : (spins += 1) {
        for (nodes) |n| _ = try n.pump();
        for (nodes, 0..) |n, i| if (n.isLeader(tenant)) {
            leader_idx = i;
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(leader_idx != null);

    // Propose a write on the leader; drive until all three stores apply it.
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "replicated");
    const ws_bytes = try ws.encode(a);
    defer a.free(ws_bytes);
    const env = try envelope.encodeWriteSet(a, id, ws_bytes);
    defer a.free(env);
    try nodes[leader_idx.?].propose(tenant, env);

    var replicated = false;
    var spins2: u32 = 0;
    while (spins2 < 2000 and !replicated) : (spins2 += 1) {
        for (nodes) |n| _ = try n.pump();
        replicated = true;
        for (nodes) |n| {
            const v = n.get(tenant, "k") catch {
                replicated = false;
                break;
            };
            a.free(v);
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(replicated);

    // The value is identical on every node.
    for (nodes) |n| {
        const v = try n.get(tenant, "k");
        defer a.free(v);
        try testing.expectEqualStrings("replicated", v);
    }

    // ── Failover: kill the leader; the two survivors must re-elect and
    //    keep committing (3-node quorum = 2). ─────────────────────────────
    const dead = leader_idx.?;
    nodes[dead].deinit();
    alive[dead] = false;

    var new_leader: ?usize = null;
    var spins3: u32 = 0;
    while (spins3 < 4000 and new_leader == null) : (spins3 += 1) {
        for (nodes, 0..) |n, i| if (alive[i]) {
            _ = try n.pump();
        };
        for (nodes, 0..) |n, i| if (alive[i] and n.isLeader(tenant)) {
            new_leader = i;
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(new_leader != null);

    // A fresh write commits on the surviving quorum.
    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addPut("k2", "after-failover");
    const ws2_bytes = try ws2.encode(a);
    defer a.free(ws2_bytes);
    const env2 = try envelope.encodeWriteSet(a, id, ws2_bytes);
    defer a.free(env2);
    try nodes[new_leader.?].propose(tenant, env2);

    var failover_ok = false;
    var spins4: u32 = 0;
    while (spins4 < 4000 and !failover_ok) : (spins4 += 1) {
        for (nodes, 0..) |n, i| if (alive[i]) {
            _ = try n.pump();
        };
        failover_ok = true;
        for (nodes, 0..) |n, i| if (alive[i]) {
            const v = n.get(tenant, "k2") catch {
                failover_ok = false;
                break;
            };
            a.free(v);
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(failover_ok);

    // The pre-failover write survived on both survivors (durability across
    // the leader change).
    for (nodes, 0..) |n, i| if (alive[i]) {
        const v = try n.get(tenant, "k");
        defer a.free(v);
        try testing.expectEqualStrings("replicated", v);
    };
}

test "Phase 1c: the leader replicates over a peer it knows ONLY via the resolver" {
    // The growth seam end to end: node 1 is born WITHOUT node 3 in its static
    // peer list — its only path to node 3 is a PeerRegistry resolver (the CP-fed
    // address map). If the write reaches node 3, the resolver carried real raft
    // traffic, not just the static positional array. (Nodes 2 + 3 keep full
    // static peers; only node 1 → node 3 exercises the resolver.)
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const voters = [_]u64{ 1, 2, 3 };
    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/n1", .{root}),
        try std.fmt.allocPrint(a, "{s}/n2", .{root}),
        try std.fmt.allocPrint(a, "{s}/n3", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    var nodes: [3]*Node = undefined;
    var alive = [_]bool{ false, false, false };
    defer for (nodes, 0..) |n, i| if (alive[i]) n.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    var won_base: u16 = 0;
    var attempt: u32 = 0;
    while (attempt < 24) : (attempt += 1) {
        const base: u16 = @intCast(20000 + ((pid +% (attempt +% 100) *% 619) % 4000) * 8);
        var ok = true;
        for (0..3) |i| {
            var peers: [3]PeerAddr = undefined;
            for (&peers, 0..) |*p, k| p.* = .{ .host = "127.0.0.1", .port = base + @as(u16, @intCast(k)) };
            // Node 1 (i==0) is born blind to node 3: only {node1, node2}.
            const peer_slice: []const PeerAddr = if (i == 0) peers[0..2] else peers[0..3];
            const addr = std.net.Address.parseIp("127.0.0.1", base + @as(u16, @intCast(i))) catch {
                ok = false;
                break;
            };
            nodes[i] = Node.initMultiNode(a, dirs[i], @intCast(i + 1), &voters, addr, peer_slice) catch {
                ok = false;
                break;
            };
            alive[i] = true;
        }
        if (ok) {
            won_base = base;
            break;
        }
        for (0..3) |i| if (alive[i]) {
            nodes[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1] and alive[2])) return error.SkipZigTest; // no free window

    // Feed node 1 the resolver with node 3's address — the address it does NOT
    // have statically. (Node 1 already knows node 2 statically.)
    const registry = try PeerRegistry.create(a);
    defer registry.destroy();
    try registry.learn(3, "127.0.0.1", won_base + 2);
    nodes[0].setPeerResolver(registry.resolver());

    const tenant: u64 = 100;
    const id = "tenant-100";
    for (nodes) |n| _ = try n.ensureGroup(tenant, id);

    // Node 1 MUST be the leader (so leader → node 3 rides the resolver, not a
    // peer's static config). The election timeout is ~election_tick (10) × 1ms
    // tick, and a log-disadvantaged node can't win a re-election after another
    // leads (raft safety rejects its stale-log vote) — so node 1 has to win
    // term 1. Pump until node 1's outbound link to node 2 is up (so its vote
    // request can actually land), then campaign once, immediately — before any
    // peer's election timer fires. On loopback all links come up together, so
    // node 1 leads cleanly.
    var linked = false;
    var w: u32 = 0;
    while (w < 400 and !linked) : (w += 1) {
        for (nodes) |n| _ = try n.pump();
        linked = nodes[0].transport.?.net.isPeerConnected(1); // node 2
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(linked);
    try nodes[0].campaign(tenant);
    var leader_ok = false;
    var s: u32 = 0;
    while (s < 600 and !leader_ok) : (s += 1) {
        for (nodes) |n| _ = try n.pump();
        leader_ok = nodes[0].isLeader(tenant);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (!leader_ok) std.debug.print("\n[1c-dbg] leader_ok=false n1={} n2={} n3={} p2cfg={} p3cfg={}\n", .{ nodes[0].isLeader(tenant), nodes[1].isLeader(tenant), nodes[2].isLeader(tenant), nodes[0].transport.?.net.isPeerConfigured(1), nodes[0].transport.?.net.isPeerConfigured(2) });
    try testing.expect(leader_ok);

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "via-resolver");
    const ws_bytes = try ws.encode(a);
    defer a.free(ws_bytes);
    const env = try envelope.encodeWriteSet(a, id, ws_bytes);
    defer a.free(env);
    try nodes[0].propose(tenant, env);

    // The proof: node 3 — reachable from the leader ONLY through the resolver —
    // applies the write.
    var on_n3 = false;
    var spins2: u32 = 0;
    while (spins2 < 4000 and !on_n3) : (spins2 += 1) {
        for (nodes) |n| _ = try n.pump();
        if (nodes[2].get(tenant, "k")) |v| {
            a.free(v);
            on_n3 = true;
        } else |_| {}
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (!on_n3) std.debug.print("\n[1c-dbg] on_n3=false n1leader={} n2leader={} p3cfg={}\n", .{ nodes[0].isLeader(tenant), nodes[1].isLeader(tenant), nodes[0].transport.?.net.isPeerConfigured(2) });
    try testing.expect(on_n3);
    const v3 = try nodes[2].get(tenant, "k");
    defer a.free(v3);
    try testing.expectEqualStrings("via-resolver", v3);

    // Node 1 stayed the leader throughout — so the value reached node 3 over
    // node 1's resolver-dialed link, not because node 2 (full static peers) took
    // over and replicated it. Plus node 1's resolver slot for node 3 is live.
    try testing.expect(nodes[0].isLeader(tenant));
    try testing.expect(nodes[0].transport.?.net.isPeerConfigured(2)); // node 3, learned via resolver
}

test "Phase 2: a group born {self} on a multi-node node auto-leads, then grows + replicates" {
    // The genesis primitive (cluster-genesis-and-membership §3.4): a node that
    // HAS a transport births a group as a single-voter {self} group — which
    // auto-campaigns and leads with NO election race (no other node shares the
    // membership) — then grows to a second node by conf-change. Both nodes know
    // each other statically here (this isolates born-{self}+grow, not the
    // resolver); voters={1,2} so neither is isSingleNode.
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const voters = [_]u64{ 1, 2 };
    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/n1", .{root}),
        try std.fmt.allocPrint(a, "{s}/n2", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    var nodes: [2]*Node = undefined;
    var alive = [_]bool{ false, false };
    defer for (nodes, 0..) |n, i| if (alive[i]) n.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    var attempt: u32 = 0;
    while (attempt < 24) : (attempt += 1) {
        const base: u16 = @intCast(20000 + ((pid +% (attempt +% 200) *% 619) % 4000) * 8);
        var ok = true;
        for (0..2) |i| {
            var peers: [2]PeerAddr = undefined;
            for (&peers, 0..) |*p, k| p.* = .{ .host = "127.0.0.1", .port = base + @as(u16, @intCast(k)) };
            const addr = std.net.Address.parseIp("127.0.0.1", base + @as(u16, @intCast(i))) catch {
                ok = false;
                break;
            };
            nodes[i] = Node.initMultiNode(a, dirs[i], @intCast(i + 1), &voters, addr, &peers) catch {
                ok = false;
                break;
            };
            alive[i] = true;
        }
        if (ok) break;
        for (0..2) |i| if (alive[i]) {
            nodes[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1])) return error.SkipZigTest; // no free window

    const tenant: u64 = 100;
    const id = "tenant-100";
    const epoch: u64 = 1;

    // Node 1 births the group as {self=1}: it must lead IMMEDIATELY, with no
    // explicit campaign and no warm-up — the born-{self} auto-campaign.
    _ = try nodes[0].createGroupAtEpoch(tenant, id, epoch, false, &[_]u64{1});
    try testing.expect(nodes[0].isLeader(tenant));

    // Node 2 joins as a learner of the {1}-led group (the reconciler bootstrap
    // shape): born voters={1}, learner={2}; it never campaigns.
    _ = try nodes[1].createGroupAtEpoch(tenant, id, epoch, true, &[_]u64{1});
    try testing.expect(!nodes[1].isLeader(tenant));

    // Warm the mesh so the leader can reach the learner.
    var warm: u32 = 0;
    while (warm < 400 and !nodes[0].transport.?.net.isPeerConnected(1)) : (warm += 1) {
        for (nodes) |n| _ = try n.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(nodes[0].transport.?.net.isPeerConnected(1));

    // Grow: the leader formally adds node 2 as a learner by conf-change.
    try nodes[0].proposeConfChange(tenant, 2, .add_learner, "");

    // A write on the leader must replicate to the grown-in node.
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "grown");
    const ws_bytes = try ws.encode(a);
    defer a.free(ws_bytes);
    const env = try envelope.encodeWriteSet(a, id, ws_bytes);
    defer a.free(env);
    try nodes[0].propose(tenant, env);

    var on_n2 = false;
    var spins: u32 = 0;
    while (spins < 4000 and !on_n2) : (spins += 1) {
        for (nodes) |n| _ = try n.pump();
        if (nodes[1].get(tenant, "k")) |v| {
            a.free(v);
            on_n2 = true;
        } else |_| {}
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(on_n2);
    const v2 = try nodes[1].get(tenant, "k");
    defer a.free(v2);
    try testing.expectEqualStrings("grown", v2);
    // Node 1 stayed leader; node 2 caught up as a follower/learner.
    try testing.expect(nodes[0].isLeader(tenant));
}

test "Phase 2: two genesis nodes (self-only, registry-only addressing) form + grow a group" {
    // The full genesis binary capability: BOTH nodes boot via `initGenesis` —
    // configured with only their own id + raft addr, NO static peer list — and
    // learn each other's address ONLY through the registry (as the CP would
    // teach them via attach / conf-change). Node 1 births the group {self},
    // auto-leads, and grows node 2 in. Exercises the raft_net self-only init
    // (self slot beyond the empty static `peers`) end to end.
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/n1", .{root}),
        try std.fmt.allocPrint(a, "{s}/n2", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    // Registries outlive the nodes' transports (declared first → freed last).
    const regs = [_]*PeerRegistry{ try PeerRegistry.create(a), try PeerRegistry.create(a) };
    defer for (regs) |r| r.destroy();

    var nodes: [2]*Node = undefined;
    var alive = [_]bool{ false, false };
    defer for (nodes, 0..) |n, i| if (alive[i]) n.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    var ports: [2]u16 = undefined;
    var attempt: u32 = 0;
    while (attempt < 24) : (attempt += 1) {
        const base: u16 = @intCast(20000 + ((pid +% (attempt +% 300) *% 619) % 4000) * 8);
        var ok = true;
        for (0..2) |i| {
            ports[i] = base + @as(u16, @intCast(i));
            const addr = std.net.Address.parseIp("127.0.0.1", ports[i]) catch {
                ok = false;
                break;
            };
            // Genesis: each node knows ONLY its own identity + addr.
            nodes[i] = Node.initGenesis(a, dirs[i], @intCast(i + 1), addr) catch {
                ok = false;
                break;
            };
            alive[i] = true;
        }
        if (ok) break;
        for (0..2) |i| if (alive[i]) {
            nodes[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1])) return error.SkipZigTest;

    // Wire each node's registry resolver, then teach addresses the way the CP
    // would: the leader learns the joiner (conf-change carry), the joiner learns
    // the leader (attach carry). Neither has any static peer.
    for (0..2) |i| nodes[i].setPeerResolver(regs[i].resolver());
    try regs[0].learn(2, "127.0.0.1", ports[1]); // node 1 learns node 2
    try regs[1].learn(1, "127.0.0.1", ports[0]); // node 2 learns node 1

    const tenant: u64 = 100;
    const id = "tenant-100";
    const epoch: u64 = 1;

    // Node 1 births the group {self} (a fresh creation — recover=false — as
    // provision does) and auto-leads: no static voter set, no campaign call.
    _ = try nodes[0].createGroupAtEpoch(tenant, id, epoch, false, &[_]u64{1});
    try testing.expect(nodes[0].isLeader(tenant));

    // Node 2 joins as a learner of the {1}-led group.
    _ = try nodes[1].createGroupAtEpoch(tenant, id, epoch, true, &[_]u64{1});
    try testing.expect(!nodes[1].isLeader(tenant));

    // Grow FIRST: until node 2 is a member, the leader's raft has no reason to
    // send to it, so (with no static peer) it would never dial. The add_learner
    // makes raft address node 2 → the leader dials it via the registry.
    try nodes[0].proposeConfChange(tenant, 2, .add_learner, "");

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "genesis-grown");
    const ws_bytes = try ws.encode(a);
    defer a.free(ws_bytes);
    const env = try envelope.encodeWriteSet(a, id, ws_bytes);
    defer a.free(env);
    try nodes[0].propose(tenant, env);

    var on_n2 = false;
    var spins: u32 = 0;
    while (spins < 4000 and !on_n2) : (spins += 1) {
        for (nodes) |n| _ = try n.pump();
        if (nodes[1].get(tenant, "k")) |v| {
            a.free(v);
            on_n2 = true;
        } else |_| {}
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(on_n2);
    const v2 = try nodes[1].get(tenant, "k");
    defer a.free(v2);
    try testing.expectEqualStrings("genesis-grown", v2);
    try testing.expect(nodes[0].isLeader(tenant));
}

test "two tenants get independent stores on the same node" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    var ws_a = WriteSet.init(a);
    defer ws_a.deinit();
    try ws_a.addPut("who", "alice");
    _ = try node.proposeWriteSet(1, "t1", &ws_a);

    var ws_b = WriteSet.init(a);
    defer ws_b.deinit();
    try ws_b.addPut("who", "bob");
    _ = try node.proposeWriteSet(2, "t2", &ws_b);

    const a_who = try node.get(1, "who");
    defer a.free(a_who);
    try testing.expectEqualStrings("alice", a_who);

    const b_who = try node.get(2, "who");
    defer a.free(b_who);
    try testing.expectEqualStrings("bob", b_who);
}

test "multi: inner writesets route by INNER id (cross-tenant + root) through the resolver" {
    // The admin-batch shape (`raft_propose.zig proposeBatch`): one multi
    // through the ANCHOR tenant's group carrying [anchor ws, cross-tenant
    // target ws, root ws]. Apply must route each inner by ITS id — the
    // old slot-routed apply wrote the target's keys into the anchor's
    // store on a follower (cross-tenant corruption) and errored on the
    // root inner.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    // Simulated worker stores: anchor ("admin"), target ("acme"), root ("").
    const open = struct {
        fn open(alloc: std.mem.Allocator, base: []const u8, name: []const u8) !*KvStore {
            const p = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}.db", .{ base, name }, 0);
            defer alloc.free(p);
            return KvStore.open(alloc, p);
        }
    }.open;
    const anchor_store = try open(a, dir, "w-admin");
    defer anchor_store.close();
    const target_store = try open(a, dir, "w-acme");
    defer target_store.close();
    const root_store = try open(a, dir, "w-root");
    defer root_store.close();

    const Resolver = struct {
        anchor: *KvStore,
        target: *KvStore,
        root: *KvStore,
        fn resolve(ctx: *anyopaque, group_id: u64, id_str: []const u8) ?*KvStore {
            _ = group_id;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (id_str.len == 0) return self.root;
            if (std.mem.eql(u8, id_str, "admin")) return self.anchor;
            if (std.mem.eql(u8, id_str, "acme")) return self.target;
            return null;
        }
    };
    var res: Resolver = .{ .anchor = anchor_store, .target = target_store, .root = root_store };
    node.store_resolver = .{ .ctx = &res, .func = Resolver.resolve };

    const gid: u64 = 77;
    const slot = try node.ensureGroup(gid, "admin");

    // Build the three inners.
    var ws_a = WriteSet.init(a);
    defer ws_a.deinit();
    try ws_a.addPut("anchor-key", "anchor-val");
    const ws_a_bytes = try ws_a.encode(a);
    defer a.free(ws_a_bytes);
    const e_anchor = try envelope.encodeWriteSet(a, "admin", ws_a_bytes);
    defer a.free(e_anchor);

    var ws_t = WriteSet.init(a);
    defer ws_t.deinit();
    try ws_t.addPut("target-key", "target-val");
    const ws_t_bytes = try ws_t.encode(a);
    defer a.free(ws_t_bytes);
    const e_target = try envelope.encodeWriteSet(a, "acme", ws_t_bytes);
    defer a.free(e_target);

    var ws_r = WriteSet.init(a);
    defer ws_r.deinit();
    try ws_r.addPut("instance/acme", "1");
    const ws_r_bytes = try ws_r.encode(a);
    defer a.free(ws_r_bytes);
    const e_root = try envelope.encodeRootWriteSet(a, ws_r_bytes);
    defer a.free(e_root);

    const multi = try envelope.encodeMulti(a, &.{ e_anchor, e_target, e_root });
    defer a.free(multi);

    const before = slot.applied_idx;
    try node.propose(gid, multi);
    var spins: u32 = 0;
    while (slot.applied_idx == before and spins < 200) : (spins += 1) {
        _ = try node.pump();
    }
    try testing.expect(slot.applied_idx > before);

    // Each inner landed in ITS tenant's store…
    const av = try anchor_store.get("anchor-key");
    defer a.free(av);
    try testing.expectEqualStrings("anchor-val", av);
    const tv = try target_store.get("target-key");
    defer a.free(tv);
    try testing.expectEqualStrings("target-val", tv);
    const rv = try root_store.get("instance/acme");
    defer a.free(rv);
    try testing.expectEqualStrings("1", rv);

    // …and did NOT leak into the anchor's store (the old corruption).
    try testing.expectError(Error.NotFound, anchor_store.get("target-key"));
    try testing.expectError(Error.NotFound, anchor_store.get("instance/acme"));
}

test "multi: a cross-tenant inner with no resolver fails loud (UnroutedApply)" {
    // A bare node (no worker, no resolver) has nowhere to land a
    // cross-tenant inner — applying it to the anchor's store would be the
    // exact corruption the routing fix removes, so it must surface as an
    // invariant violation instead of applying silently.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    const gid: u64 = 5;
    _ = try node.ensureGroup(gid, "t1");

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    const ws_bytes = try ws.encode(a);
    defer a.free(ws_bytes);
    const e_other = try envelope.encodeWriteSet(a, "other-tenant", ws_bytes);
    defer a.free(e_other);
    const multi = try envelope.encodeMulti(a, &.{e_other});
    defer a.free(multi);

    try node.propose(gid, multi);
    var got: ?Error = null;
    var spins: u32 = 0;
    while (got == null and spins < 200) : (spins += 1) {
        _ = node.pump() catch |e| {
            got = e;
        };
    }
    try testing.expectEqual(@as(?Error, Error.UnroutedApply), got);
    // The mis-addressed write never reached the anchor's store.
    try testing.expectError(Error.NotFound, node.get(gid, "k"));
}

// ── Phase 6: hibernation / active-set ─────────────────────────────────

test "Phase 6: an idle group hibernates out of the active set, a propose re-wakes it" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();
    node.hibernate_ns = 30 * std.time.ns_per_ms; // short so the test is fast

    const tenant: u64 = 9;
    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v1");
    _ = try node.proposeWriteSet(tenant, "t9", &ws);

    // A just-proposed group is active (ticked).
    const slot = node.groups.get(tenant).?;
    try testing.expect(slot.in_active);

    // Let it idle past the hibernate window, pumping all the while — the
    // sweep drops it from the active set, so the pump stops ticking it.
    var spins: u32 = 0;
    while (slot.in_active and spins < 200) : (spins += 1) {
        _ = try node.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(!slot.in_active);
    try testing.expectEqual(@as(usize, 0), node.active.items.len);

    // A new propose wakes it — it ticks again and commits (single-node it is
    // still the leader; hibernation froze the term, did not drop it).
    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addPut("k", "v2");
    _ = try node.proposeWriteSet(tenant, "t9", &ws2);
    try testing.expect(slot.in_active);

    const got = try node.get(tenant, "k");
    defer a.free(got);
    try testing.expectEqualStrings("v2", got);
}

test "Phase 6: many idle groups all drain from the active set (O(active) tick cost)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();
    node.hibernate_ns = 30 * std.time.ns_per_ms;

    // K tenants each take one write. (They enter the active set as they are
    // written; the earliest may already be aging out by the time the last is
    // created — that IS the mechanism — so don't assert a peak count here.)
    const K: u64 = 80;
    var t: u64 = 1;
    while (t <= K) : (t += 1) {
        var ws = WriteSet.init(a);
        defer ws.deinit();
        try ws.addPut("k", "v");
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "t{d}", .{t});
        _ = try node.proposeWriteSet(t, id, &ws);
    }
    try testing.expect(node.groups.count() == K); // all K exist

    // Idle past the window: every group hibernates, so a pump cycle ticks
    // NOTHING — the cost is O(active), not O(K).
    var spins: u32 = 0;
    while (node.active.items.len > 0 and spins < 200) : (spins += 1) {
        _ = try node.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 0), node.active.items.len);
    // All K groups still exist (hibernated ≠ destroyed) — a read still works.
    const got = try node.get(K, "k");
    defer a.free(got);
    try testing.expectEqualStrings("v", got);
}

test "Phase 6: an idle 3-node group hibernates with no spurious leader change, then a propose wakes + replicates" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const voters = [_]u64{ 1, 2, 3 };
    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/h1", .{root}),
        try std.fmt.allocPrint(a, "{s}/h2", .{root}),
        try std.fmt.allocPrint(a, "{s}/h3", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    // Same PID-strided, bind-retry port allocation as the other networked
    // tests (these run in parallel with sibling test binaries).
    var nodes: [3]*Node = undefined;
    var alive = [_]bool{ false, false, false };
    defer for (nodes, 0..) |n, i| if (alive[i]) n.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    var attempt: u32 = 0;
    while (attempt < 24) : (attempt += 1) {
        const base: u16 = @intCast(28000 + ((pid +% attempt *% 619) % 3000) * 8);
        var ok = true;
        for (0..3) |i| {
            var peers: [3]PeerAddr = undefined;
            for (&peers, 0..) |*p, k| p.* = .{ .host = "127.0.0.1", .port = base + @as(u16, @intCast(k)) };
            const addr = std.net.Address.parseIp("127.0.0.1", base + @as(u16, @intCast(i))) catch {
                ok = false;
                break;
            };
            nodes[i] = Node.initMultiNode(a, dirs[i], @intCast(i + 1), &voters, addr, &peers) catch {
                ok = false;
                break;
            };
            // A window long enough to elect, short enough to observe sleep.
            nodes[i].hibernate_ns = 200 * std.time.ns_per_ms;
            alive[i] = true;
        }
        if (ok) break;
        for (0..3) |i| if (alive[i]) {
            nodes[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1] and alive[2])) return error.SkipZigTest;

    const tenant: u64 = 100;
    const id = "tenant-100";
    for (nodes) |n| _ = try n.ensureGroup(tenant, id);

    // Warm the mesh, then elect node 1.
    var warm: u32 = 0;
    while (warm < 80) : (warm += 1) {
        for (nodes) |n| _ = try n.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try nodes[0].campaign(tenant);

    var leader: ?usize = null;
    var spins: u32 = 0;
    while (spins < 2000 and leader == null) : (spins += 1) {
        for (nodes) |n| _ = try n.pump();
        for (nodes, 0..) |n, i| if (n.isLeader(tenant)) {
            leader = i;
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(leader != null);
    const ld = leader.?;

    // Replicate a baseline write so every node has recent real activity.
    {
        var ws = WriteSet.init(a);
        defer ws.deinit();
        try ws.addPut("k", "v1");
        const ws_bytes = try ws.encode(a);
        defer a.free(ws_bytes);
        const env = try envelope.encodeWriteSet(a, id, ws_bytes);
        defer a.free(env);
        try nodes[ld].propose(tenant, env);
        var done = false;
        var s: u32 = 0;
        while (s < 2000 and !done) : (s += 1) {
            for (nodes) |n| _ = try n.pump();
            done = true;
            for (nodes) |n| {
                const v = n.get(tenant, "k") catch {
                    done = false;
                    break;
                };
                a.free(v);
            }
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        try testing.expect(done);
    }

    // Idle the cluster well past the hibernate window. The leader stops
    // heartbeating + the followers stop their election timers — all within
    // jitter of each other (deadlines counted from the same last Append
    // Entries, NOT from heartbeats) — so the frozen election timers never
    // fire a spurious campaign.
    var idle: u32 = 0;
    while (idle < 500) : (idle += 1) {
        for (nodes) |n| _ = try n.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    // Every node hibernated this group (active set empty), and leadership is
    // unchanged — the original leader still leads, no one else campaigned.
    for (nodes) |n| try testing.expectEqual(@as(usize, 0), n.active.items.len);
    try testing.expect(nodes[ld].isLeader(tenant));
    for (nodes, 0..) |n, i| if (i != ld) try testing.expect(!n.isLeader(tenant));

    // A propose wakes the group cluster-wide (no re-election needed — the
    // leader's term was frozen, not lost) and replicates to every node.
    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addPut("k", "v2");
    const ws2_bytes = try ws2.encode(a);
    defer a.free(ws2_bytes);
    const env2 = try envelope.encodeWriteSet(a, id, ws2_bytes);
    defer a.free(env2);
    try nodes[ld].propose(tenant, env2);

    var woke = false;
    var s2: u32 = 0;
    while (s2 < 3000 and !woke) : (s2 += 1) {
        for (nodes) |n| _ = try n.pump();
        woke = true;
        for (nodes) |n| {
            const v = n.get(tenant, "k") catch {
                woke = false;
                break;
            };
            defer a.free(v);
            if (!std.mem.eql(u8, v, "v2")) woke = false;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(woke);
    try testing.expect(nodes[ld].isLeader(tenant));
}
