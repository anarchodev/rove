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

pub const KvStore = kvstore.KvStore;
pub const WriteSet = writeset.WriteSet;
pub const Envelope = envelope.Envelope;
pub const RangeResult = kvstore.RangeResult;

/// Per-group raft configuration handed to every `createGroupEpoch`. We
/// enable `pre_vote`: a follower that was partitioned, or a hibernated
/// group that wakes, first probes whether an election is winnable before
/// bumping its term — so a node that cannot win cannot disrupt a healthy
/// leader by forcing a term change (and cannot ratchet terms during a
/// mass-wake). The remaining `raft::Config` knobs (check_quorum, the
/// min/max election-tick window, lease reads, priority for leadership
/// transfer) are now reachable through `GroupConfig` but left at raft
/// defaults pending their own validation. All nodes run the same binary,
/// so pre_vote is uniform cluster-wide; a rolling deploy has a transient
/// mixed-pre_vote window, acceptable pre-launch (dev clusters are wiped).
const group_raft_config: raft.manager.GroupConfig = blk: {
    var cfg = raft.manager.defaultGroupConfig();
    cfg.pre_vote = true;
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

/// Default durabilize cadence (V2 port of V1's `Cluster.tickSnapshot`
/// interval): how often the pump folds each dirty tenant store's in-memory
/// overlay into LMDB + stamps its raft watermark + (single-node) compacts the
/// WAL. A committed write is already durable in the fsync'd raft WAL the
/// instant it commits; this checkpoint just bounds how much WAL a restart must
/// replay and lets the WAL be truncated. Tests override with a short value.
pub const DEFAULT_DURABILIZE_NS: i64 = 500 * std.time.ns_per_ms;

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
    /// Still single-node-only by design (the `single and …` guard below):
    /// multi-node compaction needs a follower-match-index floor — a lagging
    /// follower would need a data-carrying snapshot, which is not wired — so a
    /// multi-node node durabilizes (bounding replay) but does not truncate.
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

    /// True when this node is the sole voter (no transport, campaign at
    /// group birth). Multi-node nodes elect via ticks. Public so the bridge
    /// can answer `isLeaderOf` true for every group on a single-node node
    /// (the sole voter leads every group it ever creates).
    pub fn isSingleNode(self: *const Node) bool {
        return self.voters.len == 1;
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
        return self.createGroupCore(tenant_id, id_str, 0, true);
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
    pub fn createGroupAtEpoch(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64) Error!*TenantSlot {
        if (self.groups.get(tenant_id) != null) return Error.GroupExists;
        self.mgr.clearTombstone(tenant_id) catch {};
        // A migration attach is a FRESH group — its state arrives via the
        // bundle, not the WAL — so do NOT replay any (stale) recovered records
        // for this gid.
        return self.createGroupCore(tenant_id, id_str, epoch, false);
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
        return self.createGroupCore(tenant_id, id_str, epoch, true);
    }

    /// Record (or update) a group in the node-local recovery manifest.
    /// Best-effort: a manifest failure is logged, never propagated — the live
    /// group already exists; recovery is a resilience feature, not a gate.
    /// Pump-thread (group lifecycle); `KvStore.put` self-commits.
    fn recordGroup(self: *Node, id_str: []const u8, epoch: u64) void {
        var buf: [24]u8 = undefined;
        const ep = std.fmt.bufPrint(&buf, "{d}", .{epoch}) catch return;
        self.groups_manifest.put(id_str, ep) catch |err| std.log.warn(
            "v2 node: group manifest record {s} failed: {s}",
            .{ id_str, @errorName(err) },
        );
    }

    /// Remove a group from the recovery manifest (move-out). Best-effort.
    fn forgetGroup(self: *Node, id_str: []const u8) void {
        self.groups_manifest.delete(id_str) catch |err| std.log.warn(
            "v2 node: group manifest forget {s} failed: {s}",
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
    fn createGroupCore(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64, recover: bool) Error!*TenantSlot {
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
        const gfs = if (recover)
            raft.GroupedFileStorage.initRecover(self.allocator, self.voters, self.wal, tenant_id) catch return Error.Io
        else
            raft.GroupedFileStorage.init(self.allocator, self.voters, self.wal, tenant_id) catch return Error.Io;
        errdefer gfs.deinit();

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

        try self.mgr.createGroupEpoch(
            tenant_id,
            self.node_id,
            epoch,
            raft.manager.grouped_file_storage_vtable,
            gfs,
            &group_raft_config,
        );
        // After createGroupEpoch succeeds the manager owns `gfs`; cancel
        // the local errdefer so a later failure here doesn't double-free.
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

        // Single-node: force this group to leader so proposes commit
        // immediately (no peers to elect from). Multi-node lets the
        // election fire via ticks (or an explicit `campaign` from the
        // bootstrap) — campaigning here would race the peers that have not
        // yet created the group.
        if (self.isSingleNode()) {
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

    /// Whether this node is the raft leader of `tenant_id`'s group. False
    /// for a group this node has not created yet (a tenant the bridge has
    /// `registerTenant`'d but whose `createGroupEpoch`/`ensureGroup` has not
    /// run here) — guarding the Manager read against an unknown group id.
    pub fn isLeader(self: *const Node, tenant_id: u64) bool {
        if (self.groups.get(tenant_id) == null) return false;
        return self.mgr.isLeader(tenant_id);
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
            if (!slot.pinned and now > slot.active_until_ns) {
                slot.in_active = false;
                _ = self.active.swapRemove(i);
            } else i += 1;
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
        _ = self.mgr.tickGroups(self.active.items);
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
            // group's migration epoch, for the coalesced flush below.
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

        // Hibernate: stop ticking any group idle past its deadline.
        self.sweepHibernated(now);

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
    /// durabilize), then — SINGLE-NODE ONLY — compact the shared WAL up to the
    /// durabilized index so the log is bounded. Multi-node compaction is unsafe
    /// without a follower-match-index floor (a lagging follower would need a
    /// data-carrying snapshot, which is not wired), so a multi-node node
    /// durabilizes (bounding replay) but does not yet truncate. Pump-thread
    /// only. All dirty groups are flushed in one tick so the shared WAL's
    /// interleaved commits clear together.
    fn durabilizeTick(self: *Node, now: i64) void {
        if (self.dirty.items.len == 0) return;
        if (now - self.last_durabilize_ns < self.durabilize_interval_ns) return;
        self.last_durabilize_ns = now;
        const single = self.isSingleNode();
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
            if (single and self.compact_wal) {
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
                slot.gfs.compact(target) catch |e| {
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
