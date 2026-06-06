//! V2 data-plane core — the per-tenant pump (single node).
//!
//! docs/v2-build-order.md §Phase 1: "the heart of the rewrite." A
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

/// Default hibernation idle window (Phase 6, `multiraft-scaling-learnings
/// §3.1`): a group with no propose / non-heartbeat step for this long drops
/// out of the active set and is no longer ticked. Comfortably longer than
/// the raft election timeout in wall-clock terms — what must stay below the
/// election timeout is the *skew* between nodes hibernating the same group
/// (≈ network jitter), not this absolute value; a generous window just
/// avoids re-waking a barely-idle group. Tests override `Node.hibernate_ns`
/// with a short value so the hibernate/wake transitions are observable fast.
pub const DEFAULT_HIBERNATE_NS: i64 = 2 * std.time.ns_per_s;

/// Resolves the per-tenant store a FOLLOWER's replicated entries apply to
/// in `worker_overlay` mode (Phase 5 "Full HA"). Without it, a follower
/// writes the node's own `slot.store` — a file the worker never reads, so
/// a follower promoted to leader would serve from an empty serving store.
/// The bridge sets this (via `setStoreResolver`) to point at the worker's
/// own per-tenant `inst.kv`, provisioned on demand, so a follower's
/// replicated writes land in the SAME store the worker serves from. The
/// resolver runs on the pump thread; the worker's `Tenant` is internally
/// locked, so on-demand provisioning is safe there. `group_id` + `id_str`
/// identify the tenant (the worker keys its instance store on `id_str`).
/// Returns null only on a provisioning failure (treated as a missing
/// group — an invariant violation surfaced by the apply round).
pub const StoreResolver = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, id_str: []const u8) ?*KvStore,
};

/// Fired once per committed *real* entry (writeset / multi / root —
/// not the leader's empty election no-op), AFTER it has applied, with
/// the entry's raft index. The bridge (`bridge.zig`) uses this to bind
/// per-tenant raft commit order to the per-tenant propose seq it handed
/// the worker (the seq → commit-order binding behind the per-tenant
/// watermark; docs/v2-build-order.md §Phase 2). `null` in the Phase-1
/// unit tests, which drive the pump directly and read inline.
pub const CommitHook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, raft_index: u64) void,
};

/// How committed entries apply to the tenant store (docs/v2-build-order.md
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

    /// First error raised by the apply callback during the current
    /// `processReady` round (the C-ABI callback can't return one).
    /// Checked + cleared by `pump` after the round.
    apply_err: ?Error = null,

    /// Optional per-committed-entry notification (see `CommitHook`).
    /// Set by the bridge; left null by the Phase-1 inline tests.
    commit_hook: ?CommitHook = null,

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
        const wal = raft.SharedWal.init(allocator, wal_path) catch return Error.Io;
        errdefer wal.deinit();

        var mgr = try raft.Manager.init();
        errdefer mgr.deinit();

        self.* = .{
            .allocator = allocator,
            .data_dir = dir_dup,
            .node_id = node_id,
            .voters = voters_dup,
            .mgr = mgr,
            .wal = wal,
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

        var it = self.groups.valueIterator();
        while (it.next()) |slot_ptr| {
            const slot = slot_ptr.*;
            slot.store.close();
            a.free(slot.id_str);
            a.destroy(slot);
        }
        self.groups.deinit(a);
        self.active.deinit(a);
        self.woke_scratch.deinit(a);
        a.free(self.ready_buf);
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
        return self.createGroupCore(tenant_id, id_str, 0);
    }

    /// Attach a tenant group at an explicit migration fence `epoch` (the
    /// Phase-4 move-destination path; docs/v2-build-order.md §Phase 4
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
        return self.createGroupCore(tenant_id, id_str, epoch);
    }

    /// Shared group-birth core for `ensureGroup` (epoch 0) and
    /// `createGroupAtEpoch` (migration epoch): open the tenant's kvexp
    /// store, stand up a `GroupedFileStorage` over the shared WAL, create
    /// the raft group at `epoch`, register the slot, and drive it to
    /// leader (single-node campaign). Caller has already verified the
    /// group does not exist.
    fn createGroupCore(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64) Error!*TenantSlot {
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

        const slot = self.allocator.create(TenantSlot) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        const id_dup = self.allocator.dupe(u8, id_str) catch return Error.OutOfMemory;
        errdefer self.allocator.free(id_dup);
        slot.* = .{ .tenant_id = tenant_id, .id_str = id_dup, .store = store };

        // GroupedFileStorage over the shared WAL. raft-rs takes ownership
        // via the vtable userdata slot and frees it when the group is
        // destroyed — do NOT free it here.
        const gfs = raft.GroupedFileStorage.init(self.allocator, self.voters, self.wal, tenant_id) catch
            return Error.Io;
        errdefer gfs.deinit();

        try self.mgr.createGroupEpoch(
            tenant_id,
            self.node_id,
            epoch,
            raft.manager.grouped_file_storage_vtable,
            gfs,
        );
        // After createGroupEpoch succeeds the manager owns `gfs`; cancel
        // the local errdefer so a later failure here doesn't double-free.
        errdefer self.mgr.destroyGroup(tenant_id) catch {};

        self.groups.put(self.allocator, tenant_id, slot) catch return Error.OutOfMemory;
        errdefer _ = self.groups.remove(tenant_id);
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

    /// Tear down a tenant's raft group and reclaim its WAL segments (the
    /// Phase-4 move-source cleanup; docs/v2-build-order.md §Phase 4
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
            if (now > slot.active_until_ns) {
                slot.in_active = false;
                _ = self.active.swapRemove(i);
            } else i += 1;
        }
    }

    /// Propose a raw raft-log entry to `tenant_id`'s group. Returns once
    /// the entry is staged in raft-rs's pending list — NOT once applied.
    /// Drive `pump` to commit + apply it. A propose is activity, so it
    /// wakes the group (`bumpActive`) — a hibernated tenant ticks again and
    /// replicates the entry. Bump first so even a propose that raft-rs
    /// rejects (non-leader) still re-ticks the group toward an election.
    pub fn propose(self: *Node, tenant_id: u64, entry: []const u8) Error!void {
        try self.bumpActive(tenant_id);
        try self.mgr.propose(tenant_id, entry);
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
    /// Mirrors rewind2's `pumpNode`: tick the active set, process every
    /// ready group's committed entries, ONE `wal.flush()` for the whole
    /// cycle (the load-bearing single-fsync constraint), then drain each
    /// ready group's outbox and release it. Single-node has no peers, so
    /// `takeMessages` drains to a no-op sink — but the drain+release is
    /// still required to honour the pollReady/release pairing invariant.
    pub fn pump(self: *Node) Error!bool {
        _ = self.mgr.tickGroups(self.active.items);
        const ready = self.mgr.pollReady(self.ready_buf);

        self.apply_err = null;
        if (ready.len > 0) {
            for (ready) |g| {
                self.mgr.processReady(g, applyCb, self) catch |e| {
                    self.apply_err = self.apply_err orelse mapRaftErr(e);
                };
            }

            // ONE fsync per cycle regardless of how many groups committed.
            self.wal.flush() catch {
                self.apply_err = self.apply_err orelse Error.Io;
            };

            // Drain each ready group's outbox. Single-node: queued to a
            // transport-less sink (a no-op). Multi-node: buffered per
            // destination node, stamped with the group's migration epoch,
            // for the coalesced flush below.
            for (ready) |g| {
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
            t.tick(now, 0) catch {};
            // Wake any group that received a NON-heartbeat message this cycle
            // (real raft traffic = work). Heartbeats are skipped on purpose
            // (§3.1) so a quiet group can't keep itself awake.
            self.woke_scratch.clearRetainingCapacity();
            t.drainWoke(&self.woke_scratch, self.allocator) catch {};
            for (self.woke_scratch.items) |gid| self.bumpActive(gid) catch {};
        }

        // Hibernate: stop ticking any group idle past its deadline.
        self.sweepHibernated(now);

        if (self.apply_err) |e| {
            self.apply_err = null;
            return e;
        }
        return ready.len > 0;
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
        self.applyEntry(group_id, index, bytes) catch |e| {
            self.apply_err = e;
            return;
        };
        // The entry committed + applied cleanly: notify the bridge so it
        // can advance the tenant's committed_seq watermark. Fires only on
        // the success path, so the leader's empty election no-op (len==0,
        // returned above) and any undecodable entry (apply_err, returned
        // above) never advance a tenant's watermark.
        if (self.commit_hook) |h| h.func(h.ctx, group_id, index);
    }

    fn applyEntry(self: *Node, group_id: u64, index: u64, bytes: []const u8) Error!void {
        const env = try envelope.decode(bytes);
        // Decide whether the pump writes the store, or only advances the
        // watermark (the worker's TrackedTxn.commit is the durable write).
        // `worker_overlay` makes that role-aware: skip on the leader (the
        // worker wrote it), write on a follower (no worker here).
        const skip_store = switch (self.apply_mode) {
            .apply_on_commit => false,
            .leader_skip => true,
            .worker_overlay => self.mgr.isLeader(group_id),
        };
        if (skip_store) {
            // We still decode (above) so a stale/unknown envelope type
            // surfaces loudly, and bump applied_idx — but we do NOT touch
            // the store. Root writesets (no per-tenant group) are a no-op
            // here too; their durable write also rode the worker's txn.
            if (self.groups.get(group_id)) |slot| slot.applied_idx = index;
            return;
        }
        switch (env.type) {
            .writeset => {
                const slot = self.groups.get(group_id) orelse return Error.UnknownGroup;
                const store = self.writeStore(slot) orelse return Error.UnknownGroup;
                // Strip the readset frame; apply the writeset bytes (the
                // readset rides for the tape, not the store).
                const wp = try envelope.decodeWriteSetPayload(env.payload);
                try writeset.applyEncoded(store, index, wp.ws_bytes);
                slot.applied_idx = index;
            },
            .multi => {
                const inner = try envelope.decodeMultiInner(self.allocator, env.payload);
                defer self.allocator.free(inner);
                for (inner) |inner_bytes| {
                    const ie = try envelope.decode(inner_bytes);
                    switch (ie.type) {
                        .writeset => {
                            // Inner writesets may target any tenant; in
                            // Phase 1 the only stores that exist are this
                            // node's, so route by the same group's slot.
                            const slot = self.groups.get(group_id) orelse return Error.UnknownGroup;
                            const store = self.writeStore(slot) orelse return Error.UnknownGroup;
                            const wp = try envelope.decodeWriteSetPayload(ie.payload);
                            try writeset.applyEncoded(store, index, wp.ws_bytes);
                            slot.applied_idx = index;
                        },
                        .multi => return envelope.Error.NestedMulti,
                        // root_writeset inside a multi: Phase 2+ (control
                        // plane). No root store in the Phase-1 pump.
                        .root_writeset => return Error.UnknownGroup,
                    }
                }
            },
            // The root store + its producer (provisionInstance / admin)
            // arrive in Phase 2+. The Phase-1 pump has per-tenant stores
            // only, so a stray root_writeset is an invariant violation.
            .root_writeset => return Error.UnknownGroup,
        }
    }

    /// The store a follower's (or `apply_on_commit`'s) committed writeset
    /// applies to. In `worker_overlay` mode with a `store_resolver` set
    /// (the bridge fronting a worker), this is the worker's own per-tenant
    /// serving store — so a follower's replicated writes land in the SAME
    /// store the worker serves from, and a follower promoted to leader
    /// serves the data it replicated (Phase 5 "Full HA"). Without a resolver
    /// (the bare-node multi-node + Phase-1 tests) it is the node's own slot
    /// store. Null only when the resolver fails to provision (→ surfaced as
    /// `UnknownGroup` by the caller).
    fn writeStore(self: *Node, slot: *TenantSlot) ?*KvStore {
        if (self.apply_mode == .worker_overlay) {
            if (self.store_resolver) |r| return r.func(r.ctx, slot.tenant_id, slot.id_str);
        }
        return slot.store;
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
