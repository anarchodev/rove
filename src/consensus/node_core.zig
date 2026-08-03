// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Data-plane core — the per-tenant pump.
//!
//! A `Node` owns one `SharedWal` + one raft-rs `Manager`, and a pump that
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
//! reuses the limbs: the `envelope` codec, `writeset.applyEncoded`,
//! and `kvexp` via `KvStore` as the per-tenant state engine.
//!
//! Hibernation (`multiraft-scaling-learnings §3.1`): the `active` set is a
//! true HIBERNATING set — a group idle (no propose, no non-heartbeat
//! inbound step) for `hibernate_ns` drops out and is no longer ticked, so
//! an idle tenant stops heartbeating (leader) / running its election timer
//! (follower) and costs the pump nothing. The activity bump deliberately
//! SKIPS heartbeats (a heartbeat means "don't elect me," not "I have
//! work"), so a quiet group's own keep-alive traffic can't keep it awake.
//! Correctness across nodes: every node counts a group's idle deadline
//! from the last REAL message (all see it ~simultaneously), so they
//! hibernate within network-jitter of each other — well under the election
//! timeout — and a hibernated group's frozen election timer never fires a
//! spurious campaign. A propose or a non-heartbeat step wakes it
//! cluster-wide.
//!
//! Entries apply on commit (both the proposer and any follower run the
//! same apply); the `TrackedTxn` pre-write-then-propose latency
//! optimization lives in the request path. Migration attaches a group at
//! an explicit epoch fence (`createGroupAtEpoch`); birth is epoch 0
//! (`createGroup`). A single-node node has no cross-node transport, so
//! `takeMessages` drains to nowhere and groups campaign to leader at
//! creation.

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

/// The runtime node id → transport address map (see its file doc). Moved
/// to its own file — it is injected into the Transport and owned by the
/// Bridge; nothing in `Node` touches it.
pub const PeerRegistry = @import("peer_registry.zig").PeerRegistry;

/// The hibernating active set — the pump's per-node gid worklists (`active` /
/// `dirty` / `persist_ack` / `woke_scratch`) + the dedup-append invariant.
/// `Node` embeds `ActiveSet`; `TenantSlot` embeds `SlotHib`.
const active_set_mod = @import("active_set.zig");
pub const ActiveSet = active_set_mod.ActiveSet;
pub const SlotHib = active_set_mod.SlotHib;

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
pub const group_raft_config: raft.manager.GroupConfig = blk: {
    var cfg = raft.manager.defaultGroupConfig();
    cfg.pre_vote = true;
    cfg.check_quorum = true;
    break :blk cfg;
};

/// Default hibernation idle window (`multiraft-scaling-learnings §3.1`): a
/// group with no propose / non-heartbeat step for this long drops
/// out of the active set and is no longer ticked. Comfortably longer than
/// the raft election timeout in wall-clock terms — what must stay below the
/// election timeout is the *skew* between nodes hibernating the same group
/// (≈ network jitter), not this absolute value; a generous window just
/// avoids re-waking a barely-idle group. Tests override `Node.hibernate_ns`
/// with a short value so the hibernate/wake transitions are observable fast.
pub const DEFAULT_HIBERNATE_NS: i64 = 2 * std.time.ns_per_s;

/// Leaderless-escalation window in TICKS (see `Node.leaderless_escalate_ns`):
/// a group active + leaderless for this many tick intervals gets a forced
/// (lease-bypassing, pre-vote-free) campaign. ~15 election timeouts
/// (election_tick is 10) — long enough that a normal election (cold start, or
/// peers whose leases expire on their own) completes first and never triggers
/// it, short enough that a genuinely wedged hard-failover recovers promptly
/// rather than waiting on luck. Tick-denominated because the window must keep
/// that ratio when an operator widens the tick (`setTickInterval`): a fixed
/// wall-clock window would fall INSIDE the widened election timeout and
/// force-campaign past peers' leases mid-election.
pub const LEADERLESS_ESCALATE_TICKS: i64 = 150;
pub const DEFAULT_LEADERLESS_ESCALATE_NS: i64 = LEADERLESS_ESCALATE_TICKS * DEFAULT_TICK_NS;

/// Default durabilize cadence: how often the pump folds each dirty tenant store's in-memory
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

/// Auto-demote policy: on the leader, a peer voter that
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
/// justifiable number. The default is a ~1ms idle cadence while also CAPPING
/// the rate under load; raise it
/// (env `REWIND_RAFT_TICK_MS`) once a soak has measured the broadcast-time +
/// pause-jitter tail this must clear (see docs/architecture/raft-best-practices.md).
pub const DEFAULT_TICK_NS: i64 = 1 * std.time.ns_per_ms;

/// Resolves the store a replicated entry applies to, keyed by the
/// envelope's tenant id string. Two callers need it:
///
///   - a FOLLOWER's apply in `worker_overlay` mode:
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
/// unit tests, which drive the pump directly and read inline.
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
/// Which kind of writeset op an `ApplyObserver` is being told about. Explicit
/// rather than signalled by an empty value: a legitimately-empty value is
/// indistinguishable from a removal, and an observer that guessed wrong would
/// silently keep or drop projection state. Adding a variant here forces every
/// observer to decide what it means.
pub const ApplyOp = enum { put, delete };

pub const ApplyObserver = struct {
    ctx: *anyopaque,
    /// `value` is the written bytes for `.put`, and empty for `.delete`.
    func: *const fn (ctx: *anyopaque, group_id: u64, id_str: []const u8, op: ApplyOp, key: []const u8, value: []const u8) void,
};

/// How committed entries apply to the tenant store (v2-build-order
/// §Phase 2 leader-skip + the speculative overlay).
pub const ApplyMode = enum {
    /// Decode a committed writeset and write it to the tenant's kvexp
    /// store. The default and the bare-node multi-node test: there
    /// is no speculative overlay, so apply IS the write.
    apply_on_commit,
    /// Single-node LEADER unconditional skip: the worker already wrote the
    /// entry into its own `TrackedTxn` speculative overlay before proposing
    /// and commits that overlay when the watermark advances — so the pump
    /// must NOT re-write the store (it would double-apply on a second
    /// handle). The bridge uses the role-aware `worker_overlay` instead;
    /// this stays for any caller that wants an unconditional skip.
    leader_skip,
    /// Worker-fronted multi-node: the apply behavior depends on
    /// this node's role in the group. On the **leader**, the worker owns
    /// the speculative overlay and commits it on watermark advance, so the
    /// pump skips the store write (as `leader_skip`). On a **follower**,
    /// there is no worker/overlay for this tenant here, so the pump must
    /// write the committed entry to the store itself (as `apply_on_commit`)
    /// — that is how followers stay in sync and how a tenant's data is
    /// present on the survivors after a leader failure.
    worker_overlay,
};

/// The apply policy — how a committed entry applies on this node. Six knobs
/// that jointly define bare-node vs worker-overlay behavior: the bridge sets
/// the worker-overlay hooks (commit_hook / skip_query / durabilize_floor) +
/// apply_mode together, and independently installs apply_observer (the CP
/// directory group) + store_resolver (a follower's serving store). Bare-node
/// tests keep every default. Grouped so the two legal configurations are one
/// value, not six fields smeared across the Node struct.
pub const ApplyPolicy = struct {
    /// Optional per-committed-entry notification (see `CommitHook`). Set by
    /// the bridge; left null by the inline tests.
    commit_hook: ?CommitHook = null,
    /// Optional worker-overlay skip oracle (see `SkipQuery`). Set alongside
    /// `commit_hook`; when null, `worker_overlay` falls back to the role-keyed
    /// `isLeader` skip (bare-node tests only).
    skip_query: ?SkipQuery = null,
    /// Optional durabilize floor (see `DurabilizeFloor`). Set alongside
    /// `commit_hook`; trivially unconstrained (`maxInt`) outside worker_overlay.
    durabilize_floor: ?DurabilizeFloor = null,
    /// Optional per-applied-put notification (see `ApplyObserver`). Set by the
    /// bridge for the CP directory group so a node's projection tracks
    /// replicated applies (leader + follower). Null everywhere else.
    apply_observer: ?ApplyObserver = null,
    /// Optional follower-apply store resolver (see `StoreResolver`). Set in
    /// worker_overlay mode so a follower's replicated writes land in the
    /// worker's own serving store. Null in bare-node tests.
    store_resolver: ?StoreResolver = null,
    /// How committed entries apply (see `ApplyMode`): write the store
    /// (`apply_on_commit`, default) vs. role-aware skip-on-leader
    /// (`worker_overlay`, set when the bridge fronts a worker's overlay).
    apply_mode: ApplyMode = .apply_on_commit,
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
    /// Hibernation / active-set state (see `SlotHib`): the idle deadline, the
    /// three dedup guard bits (`in_active` / `in_dirty` / `in_persist_ack`), the
    /// always-active `pinned` flag, and the leaderless-escalation cursor —
    /// grouped so the active-set machine's per-slot fields sit behind one name.
    hib: SlotHib = .{},
    /// Highest raft index durabilized into the store's LMDB (folded out of the
    /// in-memory overlay + stamped as `lastAppliedRaftIdx`) by `durabilizeTick`.
    /// `applied_idx > durabilized_idx` ⇒ this group has committed-but-not-yet-
    /// durable writes (it is "dirty"). Single-node compacts the WAL up to here.
    durabilized_idx: u64 = 0,
    /// Borrowed `GroupedFileStorage` for this group — the Manager owns it (via
    /// the storage vtable) and frees it on `destroyGroup`, but we keep the
    /// pointer to drive WAL compaction (`gfs.compact`) without a Manager API.
    /// Valid for the slot's lifetime (we control `destroyGroup`).
    gfs: *raft.GroupedFileStorage,
};

/// One node: a `Manager` of per-tenant raft groups over one shared
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

    /// Cross-node transport. `null` for a single-node node
    /// (`initSingleNode`): no peers, so groups campaign to leader at
    /// creation and `takeMessages` drains to nowhere. Non-null for a
    /// multi-node node: the pump drives it each cycle (flush coalesced
    /// sends + tick to deliver inbound → step) and groups elect via ticks.
    transport: ?*Transport = null,

    /// tenant_id → slot. Iterated on deinit; looked up in the apply
    /// callback by `group_id`.
    groups: std.AutoHashMapUnmanaged(u64, *TenantSlot) = .empty,
    /// The pump's hibernating active set + its derived worklists (see
    /// `ActiveSet`): `active` (ticked each cycle), `dirty`, `persist_ack`, and
    /// `woke_scratch`, plus the dedup-append invariant guarding the per-slot
    /// guard bits. O(active) pump cost, not O(all groups) — the
    /// multiraft-scaling-learnings §3.1 win at K = thousands.
    active_set: ActiveSet = .{},
    /// `pollReady` scratch, grown to `groups.count()` as groups are added.
    ready_buf: []u64 = &.{},
    /// Second `pollReady` scratch for the post-fsync apply pass (pass 2
    /// of `pump` — `ready_buf` still holds pass 1's ids at that point).
    ready_buf2: []u64 = &.{},

    /// Wall-clock of the last `durabilizeTick`; the tick is interval-gated
    /// (`durabilize_interval_ns`) — folding the overlay into LMDB is an
    /// fsync, amortized over many commits.
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
    /// Whether `durabilizeTick` also COMPACTS the WAL after durabilizing —
    /// truncating the log up to the durabilized index so it stays bounded. ON.
    /// Safe because durabilize folds the overlay into LMDB (and stamps
    /// `lastAppliedRaftIdx`) BEFORE truncating, so data up to the compaction
    /// point is durable independent of the WAL; recovery reloads it from LMDB
    /// and replays only the post-compaction tail.
    ///
    /// Requires two raft-rs-zig properties (pinned at 5092bc6): the
    /// compact→recover hardstate fix that persists the `LightReady` commit index
    /// (else a recovered group loads a stale `commit=0` → `hs.commit out of
    /// range`), and raft-sys built at `opt-level = 1` (a rustc -O0
    /// `movaps`/`.rodata.cst16` alignment GPF otherwise).
    ///
    /// On single- and multi-node alike (`durabilizeTick`): each node truncates
    /// per its own durable apply watermark less the fixed catch-up buffer, so a
    /// lagging voter within the buffer catches up from the log — snapshot-free.
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

    /// How committed entries apply here (see `ApplyPolicy`): the worker-overlay
    /// hooks + apply_observer + store_resolver, grouped. Bare-node = defaults.
    apply: ApplyPolicy = .{},



    /// Count of transport tick failures (rate-limited logging in `pump`
    /// — a persistently broken transport must be operator-visible, not a
    /// silently-swallowed partition).
    transport_err_count: u64 = 0,



    /// Hibernation idle window. Overridable per node (tests use a
    /// short value); production keeps `DEFAULT_HIBERNATE_NS`.
    hibernate_ns: i64 = DEFAULT_HIBERNATE_NS,
    /// Leaderless-escalation window: how long an active group may stay
    /// leaderless (this node not the leader AND `leaderId == 0`) before the pump
    /// FORCE-campaigns it past peers' `check_quorum` leases (`escalateLeaderless`
    /// → `mgr.campaignForce`). Comfortably above the election timeout
    /// (`election_tick × tick_interval`) so the cheap normal pre-vote path
    /// gets a few rounds first — the force-campaign is the BACKSTOP that makes a
    /// hard (SIGKILL) failover deterministic instead of relying on the peers'
    /// leases happening to expire in time. Tick-denominated ratio: a wider
    /// tick widens this with it via `setTickInterval` (never set the tick by
    /// assigning `tick_interval_ns` directly, or this window falls inside the
    /// election timeout). Tests override with a short value.
    leaderless_escalate_ns: i64 = DEFAULT_LEADERLESS_ESCALATE_NS,



    // ── Methods split into sibling files (see node.zig header). Re-exported
    // here so `self.X()` resolves; the bodies live in node_{groups,membership,pump}.zig.

    // node_groups.zig
    pub const PersistedGroup = @import("node_groups.zig").PersistedGroup;
    pub const ensureGroup = @import("node_groups.zig").ensureGroup;
    pub const createGroupAtEpoch = @import("node_groups.zig").createGroupAtEpoch;
    pub const recoverGroup = @import("node_groups.zig").recoverGroup;
    pub const recordGroup = @import("node_groups.zig").recordGroup;
    pub const forgetGroup = @import("node_groups.zig").forgetGroup;
    pub const persistedGroups = @import("node_groups.zig").persistedGroups;
    pub const freePersistedGroups = @import("node_groups.zig").freePersistedGroups;
    pub const createGroupCore = @import("node_groups.zig").createGroupCore;
    pub const destroyGroupAndReclaim = @import("node_groups.zig").destroyGroupAndReclaim;

    // node_membership.zig
    pub const VoterProgressRaw = @import("node_membership.zig").VoterProgressRaw;
    pub const campaign = @import("node_membership.zig").campaign;
    pub const transferLeadershipAway = @import("node_membership.zig").transferLeadershipAway;
    pub const proposeConfChange = @import("node_membership.zig").proposeConfChange;
    pub const setConfChangeObserver = @import("node_membership.zig").setConfChangeObserver;
    pub const confState = @import("node_membership.zig").confState;
    pub const voterProgress = @import("node_membership.zig").voterProgress;
    pub const logEntry = @import("node_membership.zig").logEntry;
    pub const logTerm = @import("node_membership.zig").logTerm;
    pub const lastIndex = @import("node_membership.zig").lastIndex;
    pub const firstIndex = @import("node_membership.zig").firstIndex;
    pub const snapshotPendingPeers = @import("node_membership.zig").snapshotPendingPeers;
    pub const baselineIndex = @import("node_membership.zig").baselineIndex;
    pub const appliedRaw = @import("node_membership.zig").appliedRaw;
    pub const durabilizedRaw = @import("node_membership.zig").durabilizedRaw;
    pub const groupEpoch = @import("node_membership.zig").groupEpoch;
    pub const applyLocalSnapshot = @import("node_membership.zig").applyLocalSnapshot;

    // node_pump.zig
    pub const growReadyBuf = @import("node_pump.zig").growReadyBuf;
    pub const notePersistAck = @import("node_pump.zig").notePersistAck;
    pub const bumpActive = @import("node_pump.zig").bumpActive;
    pub const pinActive = @import("node_pump.zig").pinActive;
    pub const dropActive = @import("node_pump.zig").dropActive;
    pub const sweepHibernated = @import("node_pump.zig").sweepHibernated;
    pub const escalateLeaderless = @import("node_pump.zig").escalateLeaderless;
    pub const propose = @import("node_pump.zig").propose;
    pub const proposeFramed = @import("node_pump.zig").proposeFramed;
    pub const proposeWriteSet = @import("node_pump.zig").proposeWriteSet;
    pub const pump = @import("node_pump.zig").pump;
    pub const durabilizeTick = @import("node_pump.zig").durabilizeTick;
    pub const autoDemoteTick = @import("node_pump.zig").autoDemoteTick;
    pub const markDirty = @import("node_pump.zig").markDirty;
    pub const applyEntry = @import("node_pump.zig").applyEntry;
    pub const storeFor = @import("node_pump.zig").storeFor;
    pub const notifyApply = @import("node_pump.zig").notifyApply;

    /// Stand up a single-node node (voter id 1, voter set `{1}`).
    pub fn initSingleNode(allocator: std.mem.Allocator, data_dir: []const u8) Error!*Node {
        return Node.init(allocator, data_dir, 1, &.{1});
    }

    /// Stand up a multi-node node: `node_id` ∈ `voters`, the full
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

    /// Stand up a GENESIS node (consensus-and-storage.md "Cluster genesis &
    /// membership", genesis): configured
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
    /// (consensus-and-storage.md "Cluster genesis & membership", genesis) has a
    /// transport but births its
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
        // `init`. Using `init` here (truncate-fresh) would discard every
        // committed entry on restart — the fsync'd log thrown away, so a
        // hard crash would lose all writes since the last graceful close.
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
        self.active_set.deinit(a);
        self.commit_notify.deinit(a);
        a.free(self.ready_buf);
        a.free(self.ready_buf2);
        a.free(self.voters);
        a.free(self.data_dir);
        a.destroy(self);
    }

    /// Snapshot the cross-node heartbeat round-trip histogram (broadcast-time
    /// samples), or null on a single-node node (no transport). Lock-free read
    /// (atomic buckets) — safe off the pump thread.
    pub fn heartbeatRttSnapshot(self: *Node) ?kvlimbs.MicrosHistogram.Snapshot {
        const t = self.transport orelse return null;
        return t.heartbeatRttSnapshot();
    }

    /// Set the raft logical-tick cadence, rescaling the tick-denominated
    /// windows with it: the leaderless-escalation window keeps its
    /// `LEADERLESS_ESCALATE_TICKS` ratio (~15 election timeouts), so widening
    /// the tick cannot leave the force-campaign backstop inside the election
    /// timeout, where it would bypass peers' leases mid-election. The
    /// boot-time `REWIND_RAFT_TICK_MS` override goes through here; call
    /// before the pump starts.
    pub fn setTickInterval(self: *Node, interval_ns: i64) void {
        self.tick_interval_ns = interval_ns;
        self.leaderless_escalate_ns = LEADERLESS_ESCALATE_TICKS * interval_ns;
    }

    /// Snapshot the node-wide outbound dial-mesh (configured vs connected
    /// peers), or null on a single-node node (no transport — no peers to
    /// reach). Lock-free read off the pump thread; see `Transport.meshSnapshot`.
    pub fn meshSnapshot(self: *Node) ?transport_mod.Transport.MeshSnapshot {
        const t = self.transport orelse return null;
        return t.meshSnapshot();
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

};


const testing = std.testing;

test {
    // Pull the split-out file's inline tests into the node test build (a
    // bare `pub const = @import(...)` alone does not).
    _ = @import("peer_registry.zig");
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
    try testing.expect(slot.hib.in_dirty == false); // drained from the dirty set

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
    // The genesis primitive (consensus-and-storage.md "Cluster genesis &
    // membership", genesis): a node that
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
    // target ws, root ws]. Apply must route each inner by ITS id: slot-routed
    // apply would write the target's keys into the anchor's store on a
    // follower (cross-tenant corruption) and error on the root inner.
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
    node.apply.store_resolver = .{ .ctx = &res, .func = Resolver.resolve };

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

    // …and did NOT leak into the anchor's store (the cross-tenant corruption).
    try testing.expectError(Error.NotFound, anchor_store.get("target-key"));
    try testing.expectError(Error.NotFound, anchor_store.get("instance/acme"));
}

test "multi: a cross-tenant inner with no resolver fails loud (UnroutedApply)" {
    // A bare node (no worker, no resolver) has nowhere to land a
    // cross-tenant inner — applying it to the anchor's store would be exactly
    // the cross-tenant corruption routing-by-inner-id prevents, so it must
    // surface as an invariant violation instead of applying silently.
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

// ── hibernation / active-set ─────────────────────────────────

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
    try testing.expect(slot.hib.in_active);

    // Let it idle past the hibernate window, pumping all the while — the
    // sweep drops it from the active set, so the pump stops ticking it.
    var spins: u32 = 0;
    while (slot.hib.in_active and spins < 200) : (spins += 1) {
        _ = try node.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(!slot.hib.in_active);
    try testing.expectEqual(@as(usize, 0), node.active_set.active.items.len);

    // A new propose wakes it — it ticks again and commits (single-node it is
    // still the leader; hibernation froze the term, did not drop it).
    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addPut("k", "v2");
    _ = try node.proposeWriteSet(tenant, "t9", &ws2);
    try testing.expect(slot.hib.in_active);

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
    while (node.active_set.active.items.len > 0 and spins < 200) : (spins += 1) {
        _ = try node.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 0), node.active_set.active.items.len);
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
    for (nodes) |n| try testing.expectEqual(@as(usize, 0), n.active_set.active.items.len);
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

test "leaderless-escalation window sits above the randomized election timeout" {
    // The backstop force-campaigns past peers' `check_quorum` leases, so it
    // must never fire inside a normal election: raft randomizes the timeout
    // in [election_tick, 2 × election_tick) ticks, and both windows scale
    // with the same tick interval (`setTickInterval`), so this tick-count
    // comparison is the whole invariant — at any operator-chosen tick.
    try testing.expect(LEADERLESS_ESCALATE_TICKS > 2 * group_raft_config.election_tick);
}

test "setTickInterval rescales the leaderless-escalation window with the tick" {
    var n: Node = undefined;
    n.tick_interval_ns = DEFAULT_TICK_NS;
    n.leaderless_escalate_ns = DEFAULT_LEADERLESS_ESCALATE_NS;
    n.setTickInterval(10 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i64, 10 * std.time.ns_per_ms), n.tick_interval_ns);
    try testing.expectEqual(LEADERLESS_ESCALATE_TICKS * 10 * std.time.ns_per_ms, n.leaderless_escalate_ns);
    // The rescaled window still clears the widened randomized election
    // timeout (2 × election_tick × tick).
    const election_ticks: i64 = @intCast(group_raft_config.election_tick);
    try testing.expect(n.leaderless_escalate_ns > 2 * election_ticks * n.tick_interval_ns);
}
