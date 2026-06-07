//! V2 control plane — the tenant→cluster directory (docs/v2-build-order.md
//! §Phase 3 "a minimal control plane — the tenant→cluster directory";
//! docs/v2-cp-directory-replication.md Slice 1).
//!
//! This is the routing source of truth: given a tenant's store id, which
//! cluster currently serves it. The **front-door** (`src-v2/front/`)
//! reads it on every inbound request to pick a backend; the **move
//! orchestration** (Phase 4 / Phase 7) writes it — flipping a tenant's
//! placement is the atomic commit point of a tenant move.
//!
//! ## Two representations: the durable log + the in-memory projection
//!
//! Placement must survive a control-plane restart and (Slice 2) agree
//! across HA nodes, so the authoritative state lives in a **replicated
//! kvexp store** behind our own `bridge`/`Node` raft substrate — a single
//! "directory" raft group (gid = hash of `__directory__`). Each mutating
//! op (`addCluster` / `assign` / `move` / `beginMove` / `abortMove`)
//! encodes a writeset and **proposes it through the directory group,
//! awaiting commit** before it takes effect; the directory flip is
//! therefore one committed raft write.
//!
//! Reads, however, stay on a pointer-stable **in-memory projection** (the
//! `clusters` / `cluster_idx` / `placements` maps) — a materialized view
//! of the committed log. This keeps the front-door hot path zero-alloc and
//! lock-short (one hash lookup, return a `ClusterRef` by value whose slices
//! outlive the lock), and keeps request-path reads OFF the pump thread's
//! store entirely (the store is read only once, at boot, single-threaded,
//! to rebuild the projection). The projection is updated under the mutex by
//! the writer after its write commits.
//!
//! ## Boot / replay
//!
//! `initReplicated` registers the directory group, `ensureGroup`s it (which
//! reopens the persisted store + replays the WAL on a restart), then scans
//! `cluster/*` + `placement/*` to rebuild the projection. This MUST run
//! before `bridge.startPump()` — `ensureGroup` and the boot scan touch the
//! `Node` directly, which is only safe before the pump thread is live (the
//! bridge's load-bearing single-pump-thread invariant). After the pump is
//! started, a directory write goes through `propose` + watermark like any
//! tenant write. Static `REWIND_CLUSTERS` / `REWIND_PLACEMENT` seeding is
//! the front door's job, post-pump, and **only if the replayed store is
//! empty** (so a restart never re-seeds over a committed move).
//!
//! ## Ephemeral mode (tests)
//!
//! `init` (no bridge) keeps the pure in-memory behavior — the mutating ops
//! skip replication and just update the projection. The pure unit tests use
//! this; the durability test wires a real single-node bridge.
//!
//! ## Slice 1 scope / deferrals
//!
//!   - **Single-node CP only.** Writes assume this node leads the directory
//!     group (single-node always does). Slice 2 adds multi-node HA: a write
//!     on a follower faults → leader-aware retry; followers update their
//!     projection from the apply path, not just from local proposes.
//!   - **Host→tenant** is now a replicated axis here too (gap #2): the
//!     `hosts` projection + `host/{host}` keys, authored by the
//!     `/_control/host` write and seeded from `REWIND_HOSTS`. (It was a
//!     static front-door map in Slice 1.)

const std = @import("std");
const bridge_mod = @import("bridge");

const Bridge = bridge_mod.Bridge;

/// Store id of the single directory raft group, hashed to a gid by the
/// bridge. One per CP, fixed for the cluster's lifetime.
const DIR_STORE_ID = "__directory__";

/// Bound on how long a directory write waits for its raft commit before
/// surfacing `Replication`. A single-node commit is sub-ms; the generous
/// ceiling only guards a wedged pump (then the move 500s and the operator
/// retries).
const COMMIT_TIMEOUT_NS: i128 = 10 * std.time.ns_per_s;

/// Max member nodes per cluster (matches `seedClusters`' parse buffer).
const MAX_CLUSTER_NODES = 16;

pub const Error = error{
    /// `assign`/`move` named a cluster id that was never `addCluster`'d.
    UnknownCluster,
    /// `move` named a tenant with no current placement (use `assign` for
    /// initial placement; `move` is strictly a re-placement).
    UnknownTenant,
    /// A config string handed to `seedFromConfig` was malformed.
    BadConfig,
    /// A directory write could not be replicated through the directory raft
    /// group (propose rejected, commit faulted, or timed out). The caller
    /// surfaces this as a 5xx — the durable state was NOT changed.
    Replication,
    OutOfMemory,
};

/// Where a cluster lives, from the front door's point of view. `nodes` is
/// the cluster's member node origins (e.g. `http://127.0.0.1:18092`) — one
/// for a single-node cluster, N for a multi-node (Phase 5) cluster. The
/// front door forwards a tenant's request to whichever node currently
/// leads its group (it discovers the leader by trying nodes; a follower
/// 503s a write so the front door retries the next), and fans a move's
/// attach/evict out to every node. `id` is the logical name used in
/// placement config and move commands. All slices (and the `nodes` backing
/// array) point into the `Directory`'s owned storage and are stable for
/// its lifetime, so a `ClusterRef` returned by value is safe past the lock.
pub const ClusterRef = struct {
    id: []const u8,
    nodes: []const []const u8,
};

/// A tenant's placement. `active` — served normally by `cluster_idx`.
/// `moving` — a move is in flight; the front door holds the tenant's
/// requests (brief-pause move) until `move` flips placement (or `abortMove`
/// reverts to active). Kept as a struct (not a bare cluster id) so added
/// state rides alongside the cluster without touching `clusterFor`'s callers.
pub const Placement = struct {
    state: State = .active,
    /// Index into `clusters` (the cluster currently serving this tenant).
    cluster_idx: usize,

    pub const State = enum { active, moving };
};

/// What `resolve` hands the router: the cluster currently responsible for
/// a tenant plus whether the tenant is mid-move (hold its traffic).
pub const Resolution = struct {
    cluster: ClusterRef,
    moving: bool,
};

pub const Directory = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    /// The replication substrate. Null in ephemeral (test) mode — the
    /// mutating ops then skip the durable log and only update the
    /// projection. Borrowed; the constructing process owns the bridge's
    /// lifetime (the directory never deinits it).
    bridge: ?*Bridge = null,
    /// The directory raft group id (set by `initReplicated`).
    dir_gid: u64 = 0,

    /// Pointer-stable cluster storage. Appended to by `addCluster`, never
    /// reordered or removed (a cluster outlives the process), so an index
    /// into it is a stable handle and the owned id/url slices never move.
    clusters: std.ArrayListUnmanaged(OwnedCluster) = .empty,
    /// cluster id → index into `clusters`.
    cluster_idx: std.StringHashMapUnmanaged(usize) = .empty,
    /// tenant store id → placement.
    placements: std.StringHashMapUnmanaged(Placement) = .empty,
    /// tenant store id → opaque plan/limits blob (`{tier, overrides}` JSON,
    /// authored by the admin app). The CP is dumb here — it stores + replicates
    /// + serves the bytes verbatim; the DP parses them into effective limits
    /// (`plan-tiers.md`, `v2-cp-operational-state.md`). Owned key + value.
    plans: std.StringHashMapUnmanaged([]u8) = .empty,
    /// host (`acme.com`) → tenant store id — the replicated domain index
    /// (gap #2). The front door resolves `host → tenant → cluster` via
    /// `/_cp/route`; this is the first hop, authored by a control write so
    /// custom domains can be provisioned at runtime (replacing the static
    /// `REWIND_HOSTS` env map). Placement-independent — a host points at a
    /// tenant, not a cluster, so it never changes on a move. Owned key + value.
    hosts: std.StringHashMapUnmanaged([]u8) = .empty,

    const OwnedCluster = struct {
        id: []u8,
        /// Owned array of owned node-origin URLs. Allocated once per
        /// `addCluster`; never appended to, so the backing array address is
        /// stable and a `ClusterRef.nodes` slice held past the lock stays
        /// valid even when `clusters` reallocs (the slice header is copied
        /// by value; the array it points at does not move).
        nodes: [][]u8,
    };

    /// Ephemeral directory — pure in-memory, no durable log. Used by the
    /// pure unit tests. Production / HA uses `initReplicated`.
    pub fn init(allocator: std.mem.Allocator) Directory {
        return .{ .allocator = allocator };
    }

    /// Durable directory backed by `bridge`'s directory raft group. Registers
    /// the `__directory__` group, creates/reopens it (replaying the persisted
    /// store on a restart), rebuilds the in-memory projection from the
    /// committed `cluster/*` / `placement/*` keys, and registers an apply
    /// observer so the projection tracks ONGOING replicated applies (the
    /// leader's own writes AND a follower's replicated entries).
    ///
    /// **Heap-allocated** (returns `*Directory`, freed by `destroy`) because
    /// the apply observer captures `self` — its address must be stable for the
    /// bridge's lifetime, which a by-value return can't promise. (The pure
    /// `init` stays by-value; it has no observer.)
    ///
    /// MUST be called BEFORE `bridge.startPump()` — `ensureGroup`, the boot
    /// scan, and setting the observer all touch the `Node` directly, which is
    /// only race-free while no pump thread is running.
    pub fn initReplicated(allocator: std.mem.Allocator, bridge: *Bridge) Error!*Directory {
        const self = allocator.create(Directory) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = Directory.init(allocator);
        self.bridge = bridge;
        self.dir_gid = bridge.registerTenant(DIR_STORE_ID) catch return Error.Replication;
        // Create/reopen the directory group's store on this (pre-pump)
        // thread. On a restart this replays the WAL so the committed
        // placement writesets are present to scan.
        _ = bridge.node.ensureGroup(self.dir_gid, DIR_STORE_ID) catch return Error.Replication;
        errdefer self.deinit();
        // The directory group must NEVER hibernate — it has to keep ticking so
        // a follower re-elects on leader death (reads never propose to wake
        // it). One always-active group is O(1).
        bridge.pinGroupActive(self.dir_gid) catch return Error.Replication;
        try self.replayFromStore();
        // `self` is now at its final (heap) address — safe to hand the
        // observer a pointer to it. Pre-pump, so setting the node field races
        // nothing; subsequent applies (post-startPump) update the projection.
        bridge.setApplyObserver(.{ .ctx = self, .func = onApply });
        return self;
    }

    /// Tear down + free a `initReplicated` (heap) directory. (The by-value
    /// `init` directory uses `deinit` directly.)
    pub fn destroy(self: *Directory) void {
        const a = self.allocator;
        self.deinit();
        a.destroy(self);
    }

    pub fn deinit(self: *Directory) void {
        const a = self.allocator;
        for (self.clusters.items) |c| {
            a.free(c.id);
            for (c.nodes) |n| a.free(n);
            a.free(c.nodes);
        }
        self.clusters.deinit(a);
        self.cluster_idx.deinit(a);
        // `placements` keys are owned dups (see `applyPlacementLocal`).
        var it = self.placements.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.placements.deinit(a);
        // `plans` keys AND values are owned dups (see `applyPlanLocal`).
        var pit = self.plans.iterator();
        while (pit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.plans.deinit(a);
        // `hosts` keys AND values are owned dups (see `applyHostLocal`).
        var hit = self.hosts.iterator();
        while (hit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.hosts.deinit(a);
    }

    /// True when no cluster has been registered yet — the front door seeds
    /// static config only into an empty (fresh) directory, so a restart over
    /// a populated store never re-seeds.
    pub fn isEmpty(self: *Directory) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clusters.items.len == 0;
    }

    /// Collect the tenant ids currently in `moving` state (owned dups; caller
    /// frees each + the slice). The reconciler uses this to find moves the
    /// directory durably recorded as in-flight — a CP crash between `beginMove`
    /// and the terminal `move`/`abortMove` leaves a tenant stuck `moving`
    /// forever, since the `moving` hold is now durable. (docs/v2-cp-directory-
    /// replication.md move-crash recovery.)
    pub fn collectMoving(self: *Directory, a: std.mem.Allocator) Error![][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |t| a.free(t);
            out.deinit(a);
        }
        var it = self.placements.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.state == .moving) {
                out.append(a, a.dupe(u8, e.key_ptr.*) catch return Error.OutOfMemory) catch return Error.OutOfMemory;
            }
        }
        return out.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    /// Whether THIS CP node leads the directory raft group — i.e. directory
    /// WRITES (the move flip) can commit here. Reads work on any node (the
    /// apply-driven projection), but a write proposed on a follower faults,
    /// so a multi-node CP follower must forward a control write to the leader.
    /// Always true for a single-node CP and for an ephemeral directory.
    pub fn isLeader(self: *Directory) bool {
        const bridge = self.bridge orelse return true;
        return bridge.isLeaderOf(self.dir_gid);
    }

    // ── Boot replay ──────────────────────────────────────────────────

    /// Rebuild the in-memory projection from the directory group's store:
    /// scan `cluster/*` (so placements can resolve their cluster id) then
    /// `placement/*`. Single-threaded (pre-pump) — reads the node store
    /// directly. A no-op when the store is empty (a fresh CP).
    fn replayFromStore(self: *Directory) Error!void {
        const node = self.bridge.?.node;
        const a = self.allocator;

        // Clusters first.
        var cursor: []u8 = try a.dupe(u8, "");
        defer a.free(cursor);
        while (true) {
            var rr = node.prefix(self.dir_gid, "cluster/", cursor, 256) catch return Error.Replication;
            defer rr.deinit();
            if (rr.entries.len == 0) break;
            for (rr.entries) |e| {
                const id = e.key["cluster/".len..];
                self.applyClusterFromJoined(id, e.value) catch |err| {
                    std.log.warn("cp directory replay: bad cluster {s}: {s}", .{ id, @errorName(err) });
                };
            }
            const done = rr.entries.len < 256;
            const last = rr.entries[rr.entries.len - 1].key;
            a.free(cursor);
            cursor = try a.dupe(u8, last);
            if (done) break;
        }

        // Placements (reference clusters by id, now all present).
        a.free(cursor);
        cursor = try a.dupe(u8, "");
        while (true) {
            var rr = node.prefix(self.dir_gid, "placement/", cursor, 256) catch return Error.Replication;
            defer rr.deinit();
            if (rr.entries.len == 0) break;
            for (rr.entries) |e| {
                const tenant = e.key["placement/".len..];
                self.applyPlacementFromValue(tenant, e.value) catch |err| {
                    std.log.warn("cp directory replay: bad placement {s}: {s}", .{ tenant, @errorName(err) });
                };
            }
            const done = rr.entries.len < 256;
            const last = rr.entries[rr.entries.len - 1].key;
            a.free(cursor);
            cursor = try a.dupe(u8, last);
            if (done) break;
        }

        // Plans — opaque per-tenant limit blobs, independent of clusters.
        a.free(cursor);
        cursor = try a.dupe(u8, "");
        while (true) {
            var rr = node.prefix(self.dir_gid, "plan/", cursor, 256) catch return Error.Replication;
            defer rr.deinit();
            if (rr.entries.len == 0) break;
            for (rr.entries) |e| {
                const tenant = e.key["plan/".len..];
                self.applyPlanLocal(tenant, e.value) catch |err| {
                    std.log.warn("cp directory replay: bad plan {s}: {s}", .{ tenant, @errorName(err) });
                };
            }
            const done = rr.entries.len < 256;
            const last = rr.entries[rr.entries.len - 1].key;
            a.free(cursor);
            cursor = try a.dupe(u8, last);
            if (done) break;
        }

        // Hosts — the domain index (host → tenant), independent of clusters.
        a.free(cursor);
        cursor = try a.dupe(u8, "");
        while (true) {
            var rr = node.prefix(self.dir_gid, "host/", cursor, 256) catch return Error.Replication;
            defer rr.deinit();
            if (rr.entries.len == 0) break;
            for (rr.entries) |e| {
                const host = e.key["host/".len..];
                self.applyHostLocal(host, e.value) catch |err| {
                    std.log.warn("cp directory replay: bad host {s}: {s}", .{ host, @errorName(err) });
                };
            }
            const done = rr.entries.len < 256;
            const last = rr.entries[rr.entries.len - 1].key;
            a.free(cursor);
            cursor = try a.dupe(u8, last);
            if (done) break;
        }
    }

    /// Parse a `cluster/*` value (`url1,url2,…`) and upsert the cluster into
    /// the projection (no replication — this IS the replicated state).
    fn applyClusterFromJoined(self: *Directory, id: []const u8, joined: []const u8) Error!void {
        var node_buf: [MAX_CLUSTER_NODES][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, joined, ',');
        while (it.next()) |u| {
            if (n >= node_buf.len) return Error.BadConfig;
            node_buf[n] = u;
            n += 1;
        }
        if (n == 0) return Error.BadConfig;
        try self.applyClusterLocal(id, node_buf[0..n]);
    }

    /// Parse a `placement/*` value (`state:cluster_id`) and upsert it.
    fn applyPlacementFromValue(self: *Directory, tenant: []const u8, value: []const u8) Error!void {
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return Error.BadConfig;
        const state_s = value[0..colon];
        const cluster_id = value[colon + 1 ..];
        const idx = self.cluster_idx.get(cluster_id) orelse return Error.UnknownCluster;
        const state: Placement.State = if (std.mem.eql(u8, state_s, "moving")) .moving else .active;
        try self.applyPlacementLocal(tenant, idx, state);
    }

    // ── Write path: replicate → apply observer materializes ──────────

    /// Apply a single directory `key=value`. Replicated mode: propose it
    /// through the directory group and block until it commits; the **apply
    /// observer** (`onApply`, fired on the pump thread) materializes it into
    /// the projection — on the leader AND on every follower. Ephemeral mode
    /// (no bridge, tests): update the projection inline.
    ///
    /// The caller must NOT hold `self.mutex` here. The observer takes the
    /// mutex on the pump thread, so a writer that held it while awaiting
    /// commit would deadlock: the watermark only advances after `applyCb`
    /// (and its observer) runs, but the observer would be blocked on the
    /// writer's lock. So mutating ops validate under a brief lock, release
    /// it, then call this. Read-your-write still holds: the observer fires
    /// inside `applyCb`, strictly before the commit hook advances the
    /// watermark this awaits, so the projection reflects the write by the
    /// time this returns.
    fn applyDirWrite(self: *Directory, key: []const u8, value: []const u8) Error!void {
        if (self.bridge) |bridge| {
            const seq = bridge.proposePut(self.dir_gid, key, value) catch return Error.Replication;
            const deadline: i128 = std.time.nanoTimestamp() + COMMIT_TIMEOUT_NS;
            while (bridge.committedSeq(self.dir_gid) < seq) {
                if (bridge.faultedSeq(self.dir_gid) >= seq) return Error.Replication;
                if (std.time.nanoTimestamp() > deadline) return Error.Replication;
                std.Thread.sleep(200 * std.time.ns_per_us);
            }
        } else {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.applyDirKv(key, value);
        }
    }

    /// The apply observer (`Bridge.setApplyObserver`): fired on the pump
    /// thread once per committed directory PUT, on the leader and every
    /// follower. Materializes the write into the in-memory projection under
    /// the mutex — the seam by which a CP follower (no local proposer) stays
    /// in sync, and the leader's own writes land. Best-effort: a parse error
    /// is logged, not fatal (the durable store remains the source of truth).
    fn onApply(ctx: *anyopaque, gid: u64, key: []const u8, value: []const u8) void {
        const self: *Directory = @ptrCast(@alignCast(ctx));
        if (gid != self.dir_gid) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.applyDirKv(key, value) catch |e| {
            std.log.warn("cp directory apply {s}: {s}", .{ key, @errorName(e) });
        };
    }

    /// Route a committed directory `key=value` to the projection by key
    /// prefix. Caller holds `self.mutex`. Unknown keys are ignored
    /// (forward-compatible with a later host-index axis).
    fn applyDirKv(self: *Directory, key: []const u8, value: []const u8) Error!void {
        if (std.mem.startsWith(u8, key, "cluster/")) {
            try self.applyClusterFromJoined(key["cluster/".len..], value);
        } else if (std.mem.startsWith(u8, key, "placement/")) {
            try self.applyPlacementFromValue(key["placement/".len..], value);
        } else if (std.mem.startsWith(u8, key, "plan/")) {
            try self.applyPlanLocal(key["plan/".len..], value);
        } else if (std.mem.startsWith(u8, key, "host/")) {
            try self.applyHostLocal(key["host/".len..], value);
        }
    }

    /// Join a node list into a `cluster/*` value (`url1,url2,…`). Owned.
    fn joinNodes(a: std.mem.Allocator, nodes: []const []const u8) Error![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(a);
        for (nodes, 0..) |n, i| {
            if (i > 0) buf.append(a, ',') catch return Error.OutOfMemory;
            buf.appendSlice(a, n) catch return Error.OutOfMemory;
        }
        return buf.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    // ── Cluster registry (control plane) ─────────────────────────────

    /// Register a cluster the directory can place tenants on, with its
    /// member node origins (one URL for a single-node cluster, N for a
    /// multi-node one). Idempotent on `id` — a repeat call with the same id
    /// re-addresses the cluster (replaces its node set) and keeps the index
    /// stable. `nodes` must be non-empty. Replicates before it takes effect
    /// (the projection updates via the apply observer / inline ephemerally).
    pub fn addCluster(self: *Directory, id: []const u8, nodes: []const []const u8) Error!void {
        if (nodes.len == 0) return Error.BadConfig;
        const a = self.allocator;
        const joined = try joinNodes(a, nodes);
        defer a.free(joined);
        const key = std.fmt.allocPrint(a, "cluster/{s}", .{id}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirWrite(key, joined);
    }

    /// Upsert a cluster into the in-memory projection (no replication). The
    /// committed-state applier, shared by replay + the post-commit update.
    fn applyClusterLocal(self: *Directory, id: []const u8, nodes: []const []const u8) Error!void {
        const a = self.allocator;
        const nodes_dup = try dupeNodes(a, nodes);
        errdefer freeNodes(a, nodes_dup);

        if (self.cluster_idx.get(id)) |idx| {
            // Re-address in place; the id slice (and its index) stay put.
            const old = self.clusters.items[idx].nodes;
            self.clusters.items[idx].nodes = nodes_dup;
            freeNodes(a, old);
            return;
        }
        const id_dup = a.dupe(u8, id) catch return Error.OutOfMemory;
        errdefer a.free(id_dup);
        const idx = self.clusters.items.len;
        self.clusters.append(a, .{ .id = id_dup, .nodes = nodes_dup }) catch return Error.OutOfMemory;
        errdefer _ = self.clusters.pop();
        // Key the index on the owned id dup so it outlives the caller's slice.
        self.cluster_idx.put(a, id_dup, idx) catch return Error.OutOfMemory;
    }

    /// Deep-copy a node-URL list into owned storage.
    fn dupeNodes(a: std.mem.Allocator, nodes: []const []const u8) Error![][]u8 {
        const out = a.alloc([]u8, nodes.len) catch return Error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |n| a.free(n);
            a.free(out);
        }
        for (nodes, 0..) |n, i| {
            out[i] = a.dupe(u8, n) catch return Error.OutOfMemory;
            filled = i + 1;
        }
        return out;
    }

    fn freeNodes(a: std.mem.Allocator, nodes: [][]u8) void {
        for (nodes) |n| a.free(n);
        a.free(nodes);
    }

    // ── Placement (control plane writes, front door reads) ───────────

    /// Place a tenant on a cluster for the first time (or re-affirm its
    /// placement). Idempotent. `cluster_id` must already be `addCluster`'d.
    /// Replicates before it takes effect.
    pub fn assign(self: *Directory, tenant_id: []const u8, cluster_id: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.cluster_idx.get(cluster_id) == null) return Error.UnknownCluster;
        }
        return self.writePlacement(tenant_id, cluster_id, .active);
    }

    /// Re-place an already-placed tenant onto `dest_cluster_id`. The
    /// directory half of a tenant move: the atomic flip that redirects the
    /// tenant's traffic to the destination cluster. Distinct from `assign`
    /// only in that it rejects an unknown tenant — a move presupposes an
    /// existing placement, so a missing one is a caller bug worth surfacing.
    pub fn move(self: *Directory, tenant_id: []const u8, dest_cluster_id: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.cluster_idx.get(dest_cluster_id) == null) return Error.UnknownCluster;
            if (self.placements.getPtr(tenant_id) == null) return Error.UnknownTenant;
        }
        return self.writePlacement(tenant_id, dest_cluster_id, .active);
    }

    /// Build + apply a `placement/{tenant}` = `{state}:{cluster}` write
    /// (replicated → apply observer materializes it; inline ephemerally).
    /// The caller has already validated under a brief lock; this holds no
    /// lock across the replicate/await (see `applyDirWrite`).
    fn writePlacement(self: *Directory, tenant: []const u8, cluster_id: []const u8, state: Placement.State) Error!void {
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "placement/{s}", .{tenant}) catch return Error.OutOfMemory;
        defer a.free(key);
        const value = std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(state), cluster_id }) catch return Error.OutOfMemory;
        defer a.free(value);
        return self.applyDirWrite(key, value);
    }

    /// Upsert a placement into the in-memory projection (no replication).
    fn applyPlacementLocal(self: *Directory, tenant_id: []const u8, cluster_idx: usize, state: Placement.State) Error!void {
        const gop = self.placements.getOrPut(self.allocator, tenant_id) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            const key_dup = self.allocator.dupe(u8, tenant_id) catch {
                _ = self.placements.remove(tenant_id);
                return Error.OutOfMemory;
            };
            gop.key_ptr.* = key_dup;
        }
        gop.value_ptr.* = .{ .state = state, .cluster_idx = cluster_idx };
    }

    /// Resolve a tenant to the cluster currently serving it, or null if the
    /// tenant has no placement (the front door 404s / 421-misdirects). The
    /// hot-path read. Returns the `ClusterRef` by value; its slices are
    /// pointer-stable, so the caller may hold them past the lock.
    pub fn clusterFor(self: *Directory, tenant_id: []const u8) ?ClusterRef {
        return if (self.resolve(tenant_id)) |r| r.cluster else null;
    }

    /// Hot-path read with move state: the serving cluster plus whether the
    /// tenant is mid-move. The router holds (503) a `moving` tenant's
    /// requests. Slices are pointer-stable; safe to hold past the lock.
    pub fn resolve(self: *Directory, tenant_id: []const u8) ?Resolution {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.placements.get(tenant_id) orelse return null;
        const c = self.clusters.items[p.cluster_idx];
        return .{
            .cluster = .{ .id = c.id, .nodes = c.nodes },
            .moving = p.state == .moving,
        };
    }

    /// Resolve a cluster id to its `ClusterRef` (the move orchestrator
    /// needs the destination cluster's node set). Null if unknown.
    pub fn clusterById(self: *Directory, cluster_id: []const u8) ?ClusterRef {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.cluster_idx.get(cluster_id) orelse return null;
        const c = self.clusters.items[idx];
        return .{ .id = c.id, .nodes = c.nodes };
    }

    // ── Move state (control plane writes; front door orchestration) ──

    /// Mark a tenant `moving` — the front door holds its requests while
    /// its bundle ships to the destination. The placement still points at
    /// the source cluster (so an abort just reverts to `active`). Rejects
    /// an unknown tenant. Replicates the state change.
    pub fn beginMove(self: *Directory, tenant_id: []const u8) Error!void {
        return self.setMoveState(tenant_id, .moving);
    }

    /// Revert a `beginMove` without changing placement — the move failed
    /// before the directory flip, so the tenant resumes on its source
    /// cluster. Rejects an unknown tenant. Replicates the state change.
    pub fn abortMove(self: *Directory, tenant_id: []const u8) Error!void {
        return self.setMoveState(tenant_id, .active);
    }

    fn setMoveState(self: *Directory, tenant_id: []const u8, state: Placement.State) Error!void {
        // The placement keeps pointing at its current cluster across a
        // begin/abort; only the state changes. Capture the current cluster id
        // under a brief lock (its slice is pointer-stable, so it stays valid
        // after release), then replicate the full `{state}:{cluster}` value
        // without holding the lock (see `applyDirWrite`).
        const cluster_id = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const p = self.placements.getPtr(tenant_id) orelse return Error.UnknownTenant;
            break :blk self.clusters.items[p.cluster_idx].id;
        };
        return self.writePlacement(tenant_id, cluster_id, state);
    }

    // ── Plan / limits (admin-plane writes, DP reads) ─────────────────

    /// Set a tenant's opaque plan/limits blob (`plan/{tenant} = value`). The
    /// value is whatever the admin app authors (a `{tier, overrides}` JSON
    /// string); the CP never parses it. Replicates before it takes effect
    /// (the apply observer materializes it on the leader AND every follower).
    /// Placement-independent — it does NOT move with the tenant's cluster.
    pub fn setPlan(self: *Directory, tenant_id: []const u8, value: []const u8) Error!void {
        if (tenant_id.len == 0) return Error.BadConfig;
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "plan/{s}", .{tenant_id}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirWrite(key, value);
    }

    /// A tenant's plan blob as an OWNED copy (caller frees), or null if unset.
    /// Copies under the lock because, unlike cluster slices, a plan value can
    /// be replaced (freed) by a concurrent apply — so a borrowed slice held
    /// past the lock would be unsafe.
    pub fn planForOwned(self: *Directory, a: std.mem.Allocator, tenant_id: []const u8) Error!?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = self.plans.get(tenant_id) orelse return null;
        return a.dupe(u8, v) catch return Error.OutOfMemory;
    }

    /// Upsert a plan blob into the in-memory projection (no replication). The
    /// committed-state applier, shared by replay + the post-commit observer.
    fn applyPlanLocal(self: *Directory, tenant: []const u8, value: []const u8) Error!void {
        const a = self.allocator;
        const val_dup = a.dupe(u8, value) catch return Error.OutOfMemory;
        errdefer a.free(val_dup);
        const gop = self.plans.getOrPut(a, tenant) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, tenant) catch {
                _ = self.plans.remove(tenant);
                return Error.OutOfMemory;
            };
        } else {
            a.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val_dup;
    }

    // ── Domain index (host → tenant; gap #2) ─────────────────────────

    /// Map a host to a tenant store id (`host/{host} = tenant`). The first hop
    /// of routing — the front door resolves `host → tenant` here, then
    /// `tenant → cluster` via `resolve`. Authored by a control write so custom
    /// domains can be provisioned at runtime. Replicates before it takes effect
    /// (apply observer materializes it on the leader AND every follower).
    /// Placement-independent — a host points at a tenant, never a cluster.
    pub fn setHost(self: *Directory, host: []const u8, tenant_id: []const u8) Error!void {
        if (host.len == 0 or tenant_id.len == 0) return Error.BadConfig;
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "host/{s}", .{host}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirWrite(key, tenant_id);
    }

    /// The tenant a host maps to, as an OWNED copy (caller frees), or null if
    /// the host is unmapped. Copies under the lock because — like a plan value
    /// and unlike a pointer-stable cluster slice — a host's tenant can be
    /// replaced (freed) by a concurrent apply, so a borrowed slice held past
    /// the lock would be unsafe. (Also: `resolve` takes the same mutex, so the
    /// route handler must release before resolving the tenant → cluster.)
    pub fn hostTenantForOwned(self: *Directory, a: std.mem.Allocator, host: []const u8) Error!?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = self.hosts.get(host) orelse return null;
        return a.dupe(u8, v) catch return Error.OutOfMemory;
    }

    /// Upsert a host→tenant mapping into the in-memory projection (no
    /// replication). The committed-state applier, shared by replay + the
    /// post-commit observer.
    fn applyHostLocal(self: *Directory, host: []const u8, tenant: []const u8) Error!void {
        const a = self.allocator;
        const val_dup = a.dupe(u8, tenant) catch return Error.OutOfMemory;
        errdefer a.free(val_dup);
        const gop = self.hosts.getOrPut(a, host) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, host) catch {
                _ = self.hosts.remove(host);
                return Error.OutOfMemory;
            };
        } else {
            a.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val_dup;
    }

    // ── Static config seeding ────────────────────────────────────────

    /// Seed clusters from a config string of the form
    /// `id=url1,url2,…;id=url;…` — each cluster's value is a comma-separated
    /// list of member node origins (one for a single-node cluster, N for a
    /// multi-node one). Whitespace around tokens is trimmed, a trailing `;`
    /// is allowed. The static-config path — the front door calls this once
    /// at startup (into an empty directory) from an env var. Each entry is
    /// `addCluster`'d (so it replicates + a repeat id re-addresses).
    pub fn seedClusters(self: *Directory, config: []const u8) Error!void {
        var node_buf: [MAX_CLUSTER_NODES][]const u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return Error.BadConfig;
            const id = std.mem.trim(u8, entry[0..eq], " \t");
            const urls = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (id.len == 0 or urls.len == 0) return Error.BadConfig;

            var n: usize = 0;
            var nit = std.mem.tokenizeScalar(u8, urls, ',');
            while (nit.next()) |rawn| {
                const url = std.mem.trim(u8, rawn, " \t");
                if (url.len == 0) continue;
                if (n >= node_buf.len) return Error.BadConfig; // > 16 nodes/cluster
                node_buf[n] = url;
                n += 1;
            }
            if (n == 0) return Error.BadConfig;
            try self.addCluster(id, node_buf[0..n]);
        }
    }

    /// Seed initial placements from a config string of the form
    /// `tenant=cluster_id;tenant=cluster_id;…`. Each entry is `assign`'d,
    /// so every named cluster must already be seeded (`seedClusters`
    /// first). The Phase-3 "static placement for the first move" path.
    pub fn seedPlacements(self: *Directory, config: []const u8) Error!void {
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return Error.BadConfig;
            const tenant = std.mem.trim(u8, entry[0..eq], " \t");
            const cluster = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (tenant.len == 0 or cluster.len == 0) return Error.BadConfig;
            try self.assign(tenant, cluster);
        }
    }

    /// Seed the domain index from a config string of the form
    /// `host=tenant;host=tenant;…` (the old static `REWIND_HOSTS` map, now
    /// written INTO the replicated directory so it survives a restart + spans
    /// the HA nodes). Each entry is `setHost`'d (replicated). Runtime custom
    /// domains are added later via the `/_control/host` control write.
    pub fn seedHosts(self: *Directory, config: []const u8) Error!void {
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return Error.BadConfig;
            const host = std.mem.trim(u8, entry[0..eq], " \t");
            const tenant = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (host.len == 0 or tenant.len == 0) return Error.BadConfig;
            try self.setHost(host, tenant);
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test helper: register a single-node cluster (one node origin).
fn addNode1(dir: *Directory, id: []const u8, url: []const u8) !void {
    try dir.addCluster(id, &.{url});
}

test "directory: addCluster + assign + clusterFor round-trips" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    try addNode1(&dir, "cluster-1", "http://127.0.0.1:18091");
    try addNode1(&dir, "cluster-2", "http://127.0.0.1:18092");
    try dir.assign("alice", "cluster-1");
    try dir.assign("bob", "cluster-2");

    const a = dir.clusterFor("alice").?;
    try testing.expectEqualStrings("cluster-1", a.id);
    try testing.expectEqual(@as(usize, 1), a.nodes.len);
    try testing.expectEqualStrings("http://127.0.0.1:18091", a.nodes[0]);
    const b = dir.clusterFor("bob").?;
    try testing.expectEqualStrings("cluster-2", b.id);

    try testing.expect(dir.clusterFor("nobody") == null);
}

test "directory: move flips placement (the Phase-4 seam)" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try addNode1(&dir, "c1", "http://h:1");
    try addNode1(&dir, "c2", "http://h:2");
    try dir.assign("t", "c1");

    try testing.expectEqualStrings("c1", dir.clusterFor("t").?.id);
    try dir.move("t", "c2");
    try testing.expectEqualStrings("c2", dir.clusterFor("t").?.id);
    // node origin follows the new cluster.
    try testing.expectEqualStrings("http://h:2", dir.clusterFor("t").?.nodes[0]);
}

test "directory: setPlan + planForOwned round-trip, update, unset→null" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    const a = testing.allocator;

    // unset → null
    try testing.expect((try dir.planForOwned(a, "acme")) == null);

    // set → read back
    try dir.setPlan("acme", "{\"tier\":\"pro\"}");
    {
        const p = (try dir.planForOwned(a, "acme")).?;
        defer a.free(p);
        try testing.expectEqualStrings("{\"tier\":\"pro\"}", p);
    }

    // update replaces (old value freed — no leak under the testing allocator)
    try dir.setPlan("acme", "{\"tier\":\"enterprise\"}");
    {
        const p = (try dir.planForOwned(a, "acme")).?;
        defer a.free(p);
        try testing.expectEqualStrings("{\"tier\":\"enterprise\"}", p);
    }

    // unrelated tenant stays null; plan is placement-independent
    try testing.expect((try dir.planForOwned(a, "other")) == null);
}

test "directory: setHost + hostTenantForOwned round-trip, update, unset→null" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    const a = testing.allocator;

    // unmapped → null
    try testing.expect((try dir.hostTenantForOwned(a, "acme.com")) == null);

    // map → read back
    try dir.setHost("acme.com", "acme");
    {
        const t = (try dir.hostTenantForOwned(a, "acme.com")).?;
        defer a.free(t);
        try testing.expectEqualStrings("acme", t);
    }

    // re-point the host to a different tenant (old value freed — no leak)
    try dir.setHost("acme.com", "acme2");
    {
        const t = (try dir.hostTenantForOwned(a, "acme.com")).?;
        defer a.free(t);
        try testing.expectEqualStrings("acme2", t);
    }

    // empty host / tenant rejected
    try testing.expectError(error.BadConfig, dir.setHost("", "x"));
    try testing.expectError(error.BadConfig, dir.setHost("h", ""));

    // seedHosts parses the static map form
    try dir.seedHosts("a.com=alice; b.com=bob ;");
    {
        const t = (try dir.hostTenantForOwned(a, "b.com")).?;
        defer a.free(t);
        try testing.expectEqualStrings("bob", t);
    }
    try testing.expectError(error.BadConfig, dir.seedHosts("missing-equals"));
}

test "directory: multi-node cluster carries every node origin" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try dir.addCluster("c3", &.{ "http://h:1", "http://h:2", "http://h:3" });
    try dir.assign("t", "c3");
    const c = dir.clusterFor("t").?;
    try testing.expectEqual(@as(usize, 3), c.nodes.len);
    try testing.expectEqualStrings("http://h:1", c.nodes[0]);
    try testing.expectEqualStrings("http://h:3", c.nodes[2]);
    // Re-address replaces the whole node set.
    try dir.addCluster("c3", &.{"http://h:9"});
    try testing.expectEqual(@as(usize, 1), dir.clusterFor("t").?.nodes.len);
    try testing.expectEqualStrings("http://h:9", dir.clusterFor("t").?.nodes[0]);
}

test "directory: beginMove holds, move flips, abort reverts" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try addNode1(&dir, "c1", "http://h:1");
    try addNode1(&dir, "c2", "http://h:2");
    try dir.assign("t", "c1");

    // Active on c1.
    var r = dir.resolve("t").?;
    try testing.expectEqualStrings("c1", r.cluster.id);
    try testing.expect(!r.moving);

    // beginMove holds traffic but keeps the source placement.
    try dir.beginMove("t");
    r = dir.resolve("t").?;
    try testing.expectEqualStrings("c1", r.cluster.id);
    try testing.expect(r.moving);

    // The directory flip commits the move: now active on c2.
    try dir.move("t", "c2");
    r = dir.resolve("t").?;
    try testing.expectEqualStrings("c2", r.cluster.id);
    try testing.expect(!r.moving);

    // A second move that aborts reverts to the (now) source c2.
    try dir.beginMove("t");
    try testing.expect(dir.resolve("t").?.moving);
    try dir.abortMove("t");
    r = dir.resolve("t").?;
    try testing.expectEqualStrings("c2", r.cluster.id);
    try testing.expect(!r.moving);

    // clusterById resolves the destination's node set for the orchestrator.
    try testing.expectEqualStrings("http://h:1", dir.clusterById("c1").?.nodes[0]);
    try testing.expect(dir.clusterById("nope") == null);
}

test "directory: error surfaces — unknown cluster / unknown tenant" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try addNode1(&dir, "c1", "http://h:1");

    try testing.expectError(error.UnknownCluster, dir.assign("t", "nope"));
    try testing.expectError(error.UnknownTenant, dir.move("ghost", "c1"));
    try dir.assign("t", "c1");
    try testing.expectError(error.UnknownCluster, dir.move("t", "nope"));
}

test "directory: assign is idempotent / re-placeable; addCluster re-addresses" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try addNode1(&dir, "c1", "http://h:1");
    try addNode1(&dir, "c2", "http://h:2");

    try dir.assign("t", "c1");
    try dir.assign("t", "c1"); // idempotent
    try testing.expectEqualStrings("c1", dir.clusterFor("t").?.id);
    try dir.assign("t", "c2"); // re-place via assign
    try testing.expectEqualStrings("c2", dir.clusterFor("t").?.id);

    // Re-address c1 in place; existing placements pointing at it follow.
    try dir.assign("u", "c1");
    try addNode1(&dir, "c1", "http://newhost:9");
    try testing.expectEqualStrings("http://newhost:9", dir.clusterFor("u").?.nodes[0]);
}

test "directory: seedClusters + seedPlacements parse static config" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    try dir.seedClusters("cluster-1=http://127.0.0.1:18091; cluster-2=http://127.0.0.1:18092 ;");
    try dir.seedPlacements("alice=cluster-1; bob=cluster-2");

    try testing.expectEqualStrings("http://127.0.0.1:18091", dir.clusterFor("alice").?.nodes[0]);
    try testing.expectEqualStrings("cluster-2", dir.clusterFor("bob").?.id);

    // A multi-node cluster: comma-separated node origins.
    try dir.seedClusters("cluster-3=http://127.0.0.1:18093,http://127.0.0.1:18094,http://127.0.0.1:18095");
    try dir.seedPlacements("carol=cluster-3");
    const c3 = dir.clusterFor("carol").?;
    try testing.expectEqual(@as(usize, 3), c3.nodes.len);
    try testing.expectEqualStrings("http://127.0.0.1:18095", c3.nodes[2]);

    try testing.expectError(error.BadConfig, dir.seedClusters("missing-equals"));
    try testing.expectError(error.BadConfig, dir.seedClusters("=http://nohost"));
    try testing.expectError(error.UnknownCluster, dir.seedPlacements("x=ghost-cluster"));
}

// ── Replicated (durable) directory — Slice 1 ────────────────────────────

test "directory: replicated placement survives a CP restart (Slice 1 exit)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);

    // First incarnation: seed clusters + assign + move, all replicated
    // through the directory raft group.
    {
        const bridge = try Bridge.initSingleNode(a, dir_path);
        const d = try Directory.initReplicated(a, bridge);
        // Stop the pump (→ no more apply-observer fires) before freeing the
        // directory the observer points at: declare `destroy` first so it
        // runs LAST, `bridge.deinit` second so it runs first.
        defer d.destroy();
        defer bridge.deinit();
        try bridge.startPump();

        try d.addCluster("c1", &.{"http://h:1"});
        try d.addCluster("c2", &.{"http://h:2"});
        try d.assign("t", "c1");
        try testing.expectEqualStrings("c1", d.clusterFor("t").?.id);
        try d.move("t", "c2");
        try testing.expectEqualStrings("c2", d.clusterFor("t").?.id);
    }

    // Second incarnation over the SAME data_dir: the store/WAL replays, so
    // the move is still recorded — t is on c2, not its original c1.
    {
        const bridge = try Bridge.initSingleNode(a, dir_path);
        const d = try Directory.initReplicated(a, bridge);
        // Stop the pump (→ no more apply-observer fires) before freeing the
        // directory the observer points at: declare `destroy` first so it
        // runs LAST, `bridge.deinit` second so it runs first.
        defer d.destroy();
        defer bridge.deinit();

        try testing.expect(!d.isEmpty());
        const r = d.clusterFor("t") orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("c2", r.id);
        try testing.expectEqualStrings("http://h:2", r.nodes[0]);
        // The cluster registry replayed too.
        try testing.expectEqualStrings("http://h:1", d.clusterById("c1").?.nodes[0]);
    }
}

test "directory: replicated move state (moving) survives a restart" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);

    {
        const bridge = try Bridge.initSingleNode(a, dir_path);
        const d = try Directory.initReplicated(a, bridge);
        // Stop the pump (→ no more apply-observer fires) before freeing the
        // directory the observer points at: declare `destroy` first so it
        // runs LAST, `bridge.deinit` second so it runs first.
        defer d.destroy();
        defer bridge.deinit();
        try bridge.startPump();
        try d.addCluster("c1", &.{"http://h:1"});
        try d.assign("t", "c1");
        try d.beginMove("t"); // held mid-move when the CP "crashes"
        try testing.expect(d.resolve("t").?.moving);
    }
    {
        const bridge = try Bridge.initSingleNode(a, dir_path);
        const d = try Directory.initReplicated(a, bridge);
        // Stop the pump (→ no more apply-observer fires) before freeing the
        // directory the observer points at: declare `destroy` first so it
        // runs LAST, `bridge.deinit` second so it runs first.
        defer d.destroy();
        defer bridge.deinit();
        // The moving hold is durable — the recovered CP still holds traffic
        // until an operator completes or aborts the move.
        const r = d.resolve("t") orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("c1", r.cluster.id);
        try testing.expect(r.moving);
    }
}

test "directory: stuck 'moving' is collectable + abortable (Slice 2 recovery)" {
    // The move-crash recovery primitives: a durable `moving` state (a CP crash
    // between beginMove and the terminal move/abort) is found by
    // `collectMoving` and cleared by `abortMove` (revert to active on the
    // source — the flip never committed, so the source stays authoritative).
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);

    const bridge = try Bridge.initSingleNode(a, dir_path);
    const d = try Directory.initReplicated(a, bridge);
    defer d.destroy();
    defer bridge.deinit();
    try bridge.startPump();

    try d.addCluster("c1", &.{"http://h:1"});
    try d.addCluster("c2", &.{"http://h:2"});
    try d.assign("alice", "c1");
    try d.assign("bob", "c1");
    // bob is mid-move (stuck); alice is healthy/active.
    try d.beginMove("bob");

    // collectMoving finds ONLY the stuck tenant.
    {
        const moving = try d.collectMoving(a);
        defer {
            for (moving) |t| a.free(t);
            a.free(moving);
        }
        try testing.expectEqual(@as(usize, 1), moving.len);
        try testing.expectEqualStrings("bob", moving[0]);
    }

    // Reconcile = abortMove (revert to active on the source). bob resumes
    // active on c1 (its placement never flipped); alice is untouched.
    try d.abortMove("bob");
    try testing.expect(!d.resolve("bob").?.moving);
    try testing.expectEqualStrings("c1", d.resolve("bob").?.cluster.id);

    // Nothing is moving anymore.
    {
        const moving = try d.collectMoving(a);
        defer {
            for (moving) |t| a.free(t);
            a.free(moving);
        }
        try testing.expectEqual(@as(usize, 0), moving.len);
    }
}

// ── Multi-node CP — Slice 2: apply-driven projection / HA ───────────────

test "directory: a leader's write replicates to FOLLOWER projections (Slice 2A)" {
    // The heart of multi-node CP: a directory write on the leader replicates
    // through the directory raft group, and each FOLLOWER's apply observer
    // materializes it into that node's in-memory projection — so any CP node
    // (not just the leader) resolves the placement. A follower has no local
    // proposer, so this can ONLY come from the apply path.
    //
    // Manual-pump (the test thread is the sole Node toucher), so we drive
    // election with an explicit campaign and write via `bridge.proposePut`
    // directly rather than the blocking `Directory.move` (which would need a
    // separate pump thread to make progress).
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const voters = [_]u64{ 1, 2, 3 };
    const dirs = [_][]u8{
        try std.fmt.allocPrint(a, "{s}/c1", .{root}),
        try std.fmt.allocPrint(a, "{s}/c2", .{root}),
        try std.fmt.allocPrint(a, "{s}/c3", .{root}),
    };
    defer for (dirs) |d| a.free(d);

    // PID-strided, bind-retry port allocation (parallel test binaries).
    var bridges: [3]*Bridge = undefined;
    var alive = [_]bool{ false, false, false };
    const pid: u32 = @intCast(std.os.linux.getpid());
    var attempt: u32 = 0;
    blk: while (attempt < 24) : (attempt += 1) {
        const bp: u16 = @intCast(25000 + ((pid +% attempt *% 631) % 4000) * 8);
        var ok = true;
        for (0..3) |i| {
            var peers: [3]bridge_mod.PeerAddr = undefined;
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
        if (ok) break :blk;
        for (0..3) |i| if (alive[i]) {
            bridges[i].deinit();
            alive[i] = false;
        };
    }
    if (!(alive[0] and alive[1] and alive[2])) return error.SkipZigTest;
    defer for (bridges) |b| b.deinit();

    // Each node stands up its directory (registers group + observer + scans
    // the empty store). Multi-node `ensureGroup` does NOT campaign, so this
    // is non-blocking.
    var directories: [3]*Directory = undefined;
    for (&directories, bridges) |*d, b| d.* = try Directory.initReplicated(a, b);
    defer for (directories) |d| d.destroy();

    const dir_gid = directories[0].dir_gid;
    for (directories) |d| try testing.expectEqual(dir_gid, d.dir_gid);

    // Warm the transport, elect node 1 leader of the directory group.
    var warm: u32 = 0;
    while (warm < 150) : (warm += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try bridges[0].node.campaign(dir_gid);
    var leader: ?usize = null;
    var spins: u32 = 0;
    while (spins < 2000 and leader == null) : (spins += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        for (bridges, 0..) |b, i| if (b.node.isLeader(dir_gid)) {
            leader = i;
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(leader != null);
    const li = leader.?;

    // Write cluster + placement THROUGH the leader bridge (proposePut), then
    // pump until every node has committed seq 2 (the placement).
    _ = try bridges[li].proposePut(dir_gid, "cluster/west", "http://w:1,http://w:2");
    const pseq = try bridges[li].proposePut(dir_gid, "placement/acme", "active:west");
    var done = false;
    var s2: u32 = 0;
    while (s2 < 3000 and !done) : (s2 += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        if (bridges[li].committedSeq(dir_gid) >= pseq) done = true;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(done);

    // Give followers a few cycles to apply the replicated entries (their
    // observers run inside `pumpOnce`).
    var settle: u32 = 0;
    while (settle < 200) : (settle += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
    }

    // EVERY node — leader and both followers — resolves acme → west via its
    // OWN projection, materialized from the replicated applies.
    for (directories, 0..) |d, i| {
        const r = d.resolve("acme") orelse {
            std.debug.print("node {d} has no placement for acme\n", .{i});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("west", r.cluster.id);
        try testing.expectEqual(@as(usize, 2), r.cluster.nodes.len);
        try testing.expectEqualStrings("http://w:2", r.cluster.nodes[1]);
        try testing.expect(!r.moving);
    }
}
