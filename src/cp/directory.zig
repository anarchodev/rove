// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! V2 control plane — the tenant→cluster directory; directory replication
//! (`docs/architecture/control-plane.md`).
//!
//! This is the routing source of truth: given a tenant's store id, which
//! cluster currently serves it. The **front-door** (`src/front/`)
//! reads it on every inbound request to pick a backend; the **move
//! orchestration** writes it — flipping a tenant's placement is the atomic
//! commit point of a tenant move.
//!
//! ## Two representations: the durable log + the in-memory projection
//!
//! Placement must survive a control-plane restart and agree
//! across HA nodes, so the authoritative state lives in a **replicated
//! kvexp store** behind our own `bridge`/`Node` raft substrate — a single
//! "directory" raft group (gid = hash of `__directory__`). Each mutating
//! op (`addCluster` / `assign` / `move`)
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
//! ## Single-writer + HA
//!
//!   - Directory WRITES commit only on the node that leads the directory
//!     group; a write proposed on a follower faults, so a multi-node CP
//!     follower forwards a control write to the leader (single-node always
//!     leads). Followers update their projection from the apply path, not
//!     from local proposes.
//!   - **Host→tenant** is a replicated axis here too: the `hosts` projection
//!     + `host/{host}` keys, authored by the `/_control/host` write and
//!     seeded from `REWIND_HOSTS`.

const std = @import("std");
const bridge_mod = @import("bridge");
const origin_mod = @import("rove-origin");
const acme_expiry = @import("rove-acme").expiry;

const Bridge = bridge_mod.Bridge;

/// Store id of the single directory raft group, hashed to a gid by the
/// bridge. One per CP, fixed for the cluster's lifetime.
const DIR_STORE_ID = "__directory__";

/// Bound on how long a directory write waits for its raft commit before
/// surfacing `Replication`. A single-node commit is sub-ms; the generous
/// ceiling only guards a wedged pump (then the move 500s and the operator
/// retries).
const COMMIT_TIMEOUT_NS: u64 = 10 * std.time.ns_per_s;

/// Max member nodes per cluster (matches `seedClusters`' parse buffer).
/// Public so the seed caller's error message can state the limit rather
/// than repeat the number.
pub const MAX_CLUSTER_NODES = 16;

/// Why a static config string (`REWIND_CLUSTERS` / `REWIND_PLACEMENT` /
/// `REWIND_HOSTS`) could not be parsed. One value per condition: these are
/// hand-edited env vars, so "which entry, and what about it" is the whole
/// diagnostic. `seedBadEntry` carries the offending text alongside.
///
/// The seed callers switch over this set with NO `else`, so a new
/// condition is a compile error until it gets an operator message.
pub const ConfigError = error{
    /// An entry had no `=` separating key from value.
    SeedEntryMissingEquals,
    /// `id=` with an empty cluster id.
    SeedClusterIdEmpty,
    /// An entry named a cluster but listed no node origins.
    SeedClusterNodesEmpty,
    /// More than `MAX_CLUSTER_NODES` origins for one cluster.
    SeedClusterTooManyNodes,
    /// A node origin is not an IP literal (a hostname, most likely). The
    /// front door cannot dial it — see `rove-origin`.
    SeedOriginNotIpLiteral,
    /// A node origin's `:port` suffix is not a u16.
    SeedOriginBadPort,
    /// A node origin had no host at all.
    SeedOriginEmpty,
    /// `=cluster` with an empty tenant id.
    SeedPlacementTenantEmpty,
    /// `tenant=` with an empty cluster id.
    SeedPlacementClusterEmpty,
    /// `=tenant` with an empty host.
    SeedHostEmpty,
    /// `host=` with an empty tenant id.
    SeedHostTenantEmpty,
};

pub const Error = error{
    /// `assign`/`move` named a cluster id that was never `addCluster`'d.
    UnknownCluster,
    /// `move` named a tenant with no current placement (use `assign` for
    /// initial placement; `move` is strictly a re-placement).
    UnknownTenant,
    /// A runtime control write (`setHost`/`setCert`/`setNodeAddr`) carried
    /// an empty or malformed field. Distinct from `ConfigError`, which is
    /// for boot-time env parsing: this one maps to a 400 on the control
    /// API, so it stays a single value the HTTP layer can test for.
    BadConfig,
    /// A directory write could not be replicated through the directory raft
    /// group (propose rejected, commit faulted, or timed out). The caller
    /// surfaces this as a 5xx — the durable state was NOT changed.
    Replication,
    OutOfMemory,
};

/// Where a cluster lives, from the front door's point of view. `nodes` is
/// the cluster's member node origins (e.g. `http://127.0.0.1:18092`) — one
/// for a single-node cluster, N for a multi-node cluster. The
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

/// A tenant's placement. Kept as a struct (not a bare cluster id) so added
/// state can ride alongside the cluster without touching `clusterFor`'s callers.
/// The move is one zero-downtime path that keeps the source serving until the
/// atomic `move` flip, so there is no mid-move hold state.
pub const Placement = struct {
    /// Index into `clusters` (the cluster currently serving this tenant).
    cluster_idx: usize,
};

/// What `resolve` hands the router: the cluster currently responsible for
/// a tenant.
pub const Resolution = struct {
    cluster: ClusterRef,
};

/// Where a written certificate is copied so it survives a cold bring-up. A hook
/// rather than a direct dependency: the directory replicates and projects
/// state, and knows nothing about object storage. Deliberately infallible — the
/// certificate is already durable in raft by the time this runs, so a mirror
/// failure is a warning to log, not a write to fail.
pub const CertMirrorHook = struct {
    ctx: *anyopaque,
    put: *const fn (ctx: *anyopaque, host: []const u8, frame: []const u8) void,
};

pub const Directory = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},


    /// The replication substrate. Null in ephemeral (test) mode — the
    /// mutating ops then skip the durable log and only update the
    /// projection. Borrowed; the constructing process owns the bridge's
    /// lifetime (the directory never deinits it).
    bridge: ?*Bridge = null,

    /// Optional durable copy of every certificate written here, kept outside
    /// the state a cold bring-up destroys (`cert_mirror.zig`). Null leaves
    /// certificates raft-only, which means a genesis destroys them and the
    /// re-issue spends CA rate-limit quota. Borrowed; the CP owns it.
    cert_mirror: ?CertMirrorHook = null,
    /// The directory raft group id (set by `initReplicated`).
    dir_gid: u64 = 0,

    /// The config entry that produced the last `ConfigError`, so the seed
    /// caller can name it. Borrowed from the caller's config string, which
    /// is an env var and outlives the process. Empty until a seed fails.
    seed_bad_entry: []const u8 = "",

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
    /// (decisions.md §10.9 + docs/architecture/control-plane.md). Owned key + value.
    plans: std.StringHashMapUnmanaged([]u8) = .empty,
    /// tenant → storage incarnation (#357). The CP mints one per tenant
    /// LIFETIME at provision and must be able to hand it to EVERY later attach
    /// — a move, a membership backfill, a node rejoining. A node that attaches
    /// without it opens a legacy-keyed store while the rest of the cluster uses
    /// the incarnation-keyed one, and the tenant's data silently diverges.
    incarnations: std.StringHashMapUnmanaged([]u8) = .empty,
    /// host (`acme.com`) → tenant store id — the replicated domain index.
    /// The front door resolves `host → tenant → cluster` via
    /// `/_cp/route`; this is the first hop, authored by a control write so
    /// custom domains can be provisioned at runtime (replacing the static
    /// `REWIND_HOSTS` env map). Placement-independent — a host points at a
    /// tenant, not a cluster, so it never changes on a move. Owned key + value.
    hosts: std.StringHashMapUnmanaged([]u8) = .empty,
    /// host (`acme.com`) → packed TLS cert+key (`[4B BE cert_len][cert_pem]
    /// [key_pem]`, `packCert`) — the replicated cert-state axis. The
    /// single leader-elected ACME issuer (or a `/_control/cert` operator
    /// upload) writes here; every stateless front-door pulls a host's cert via
    /// `/_cp/cert` for SNI termination. Admin-authored + placement-independent
    /// (survives moves), so it's a sibling axis here, not per-cluster
    /// `__root__.db` (`docs/architecture/auth-and-domains.md` — cert state).
    /// Owned key + value.
    certs: std.StringHashMapUnmanaged([]u8) = .empty,
    /// `{cluster}/{id}` → packed node transport address (`packNodeAddr`:
    /// `raft_addr \t cp_raft_addr \t http_url`) — the node-address registry, the
    /// rove analog of PD's store-address table (docs/architecture/consensus-and-storage.md
    /// "Cluster genesis & membership", node-address registry). The single
    /// source of truth for raft id → transport address, for
    /// both worker tenant groups and the CP directory group; it lets a node be
    /// configured with only its own identity and learn its peers' addresses from
    /// here (replacing the static positional `REWIND_PEERS`). Replicated like the
    /// other axes; placement-independent. Owned key + value.
    node_addrs: std.StringHashMapUnmanaged([]u8) = .empty,

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
        // `incarnations` keys AND values are owned dups, like `plans`.
        var iit = self.incarnations.iterator();
        while (iit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.incarnations.deinit(a);

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
        // `certs` keys AND values are owned dups (see `applyCertLocal`).
        var cit = self.certs.iterator();
        while (cit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.certs.deinit(a);
        // `node_addrs` keys AND values are owned dups (see `applyNodeAddrLocal`).
        var nit = self.node_addrs.iterator();
        while (nit.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.node_addrs.deinit(a);
    }

    /// True when no cluster has been registered yet — the front door seeds
    /// static config only into an empty (fresh) directory, so a restart over
    /// a populated store never re-seeds.
    pub fn isEmpty(self: *Directory) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.clusters.items.len == 0;
    }

    /// All placed tenant ids (owned dups; caller frees each + the slice). The
    /// membership reconciler iterates these as DESIRED state, resolving each to
    /// its cluster.
    pub fn listPlacements(self: *Directory, a: std.mem.Allocator) Error![][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |t| a.free(t);
            out.deinit(a);
        }
        var it = self.placements.keyIterator();
        while (it.next()) |k| {
            out.append(a, a.dupe(u8, k.*) catch return Error.OutOfMemory) catch return Error.OutOfMemory;
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

        // Certs — the cert-state axis (host → packed cert+key), independent
        // of clusters.
        a.free(cursor);
        cursor = try a.dupe(u8, "");
        while (true) {
            var rr = node.prefix(self.dir_gid, "cert/", cursor, 256) catch return Error.Replication;
            defer rr.deinit();
            if (rr.entries.len == 0) break;
            for (rr.entries) |e| {
                const host = e.key["cert/".len..];
                self.applyCertLocal(host, e.value) catch |err| {
                    std.log.warn("cp directory replay: bad cert {s}: {s}", .{ host, @errorName(err) });
                };
            }
            const done = rr.entries.len < 256;
            const last = rr.entries[rr.entries.len - 1].key;
            a.free(cursor);
            cursor = try a.dupe(u8, last);
            if (done) break;
        }

        // Node-address registry (`node/{cluster}/{id}` → packed addr),
        // independent of clusters — feeds the peer resolver.
        a.free(cursor);
        cursor = try a.dupe(u8, "");
        while (true) {
            var rr = node.prefix(self.dir_gid, "node/", cursor, 256) catch return Error.Replication;
            defer rr.deinit();
            if (rr.entries.len == 0) break;
            for (rr.entries) |e| {
                const suffix = e.key["node/".len..];
                self.applyNodeAddrLocal(suffix, e.value) catch |err| {
                    std.log.warn("cp directory replay: bad node-addr {s}: {s}", .{ suffix, @errorName(err) });
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

    /// Parse a `placement/*` value (`cluster_id`) and upsert it.
    fn applyPlacementFromValue(self: *Directory, tenant: []const u8, value: []const u8) Error!void {
        const idx = self.cluster_idx.get(value) orelse return Error.UnknownCluster;
        try self.applyPlacementLocal(tenant, idx);
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
            bridge.awaitCommit(self.dir_gid, seq, COMMIT_TIMEOUT_NS) catch return Error.Replication;
        } else {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.applyDirKv(key, value);
        }
    }

    /// The removal twin of `applyDirWrite`: replicate a directory key's DELETE
    /// and block until it commits. Same locking discipline — the caller must
    /// NOT hold `self.mutex` (the observer takes it on the pump thread).
    fn applyDirDelete(self: *Directory, key: []const u8) Error!void {
        if (self.bridge) |bridge| {
            const seq = bridge.proposeDelete(self.dir_gid, key) catch return Error.Replication;
            bridge.awaitCommit(self.dir_gid, seq, COMMIT_TIMEOUT_NS) catch return Error.Replication;
        } else {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.applyDirKvDelete(key);
        }
    }

    /// The apply observer (`Bridge.setApplyObserver`): fired on the pump
    /// thread once per committed directory PUT, on the leader and every
    /// follower. Materializes the write into the in-memory projection under
    /// the mutex — the seam by which a CP follower (no local proposer) stays
    /// in sync, and the leader's own writes land. Best-effort: a parse error
    /// is logged, not fatal (the durable store remains the source of truth).
    fn onApply(ctx: *anyopaque, gid: u64, id_str: []const u8, op: bridge_mod.ApplyOp, key: []const u8, value: []const u8) void {
        // `id_str` (the writeset's target tenant id) is unused: the
        // directory filters on its own group id — every entry in that
        // group is a directory write.
        _ = id_str;
        const self: *Directory = @ptrCast(@alignCast(ctx));
        if (gid != self.dir_gid) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (op) {
            .put => self.applyDirKv(key, value) catch |e| {
                std.log.warn("cp directory apply {s}: {s}", .{ key, @errorName(e) });
            },
            // A deprovision's row removal: a follower drops it here, which is
            // what keeps its projection equal to the leader's.
            .delete => self.applyDirKvDelete(key) catch |e| {
                std.log.warn("cp directory apply delete {s}: {s}", .{ key, @errorName(e) });
            },
        }
    }

    /// One replicated directory axis: a key prefix and the applier that
    /// materializes a committed `{suffix}=value` write of that axis into the
    /// in-memory projection. The single table drives the write dispatch (and
    /// documents the axis set) so adding an axis is one row, not another
    /// hand-wired `startsWith` + prefix-strip branch (the strip is centralized
    /// in `applyDirKv`, killing the per-branch off-by-one risk).
    const DirAxis = struct {
        prefix: []const u8,
        apply: *const fn (*Directory, []const u8, []const u8) Error!void,
        /// Materialize a committed DELETE of this axis. Null = the axis has no
        /// removal path; a delete arriving for it is logged and ignored rather
        /// than silently treated as a write. `cluster/` and `node/` are
        /// topology, not tenant state: removing a cluster out from under live
        /// placements is a different operation with its own safety questions,
        /// so deprovision does not get to do it by accident.
        remove: ?*const fn (*Directory, []const u8) void = null,
    };
    const dir_axes = [_]DirAxis{
        .{ .prefix = "cluster/", .apply = applyClusterFromJoined },
        .{ .prefix = "placement/", .apply = applyPlacementFromValue, .remove = removePlacementLocal },
        .{ .prefix = "plan/", .apply = applyPlanLocal, .remove = removePlanLocal },
        .{ .prefix = "incarnation/", .apply = applyIncarnationLocal, .remove = removeIncarnationLocal },
        .{ .prefix = "host/", .apply = applyHostLocal, .remove = removeHostLocal },
        .{ .prefix = "cert/", .apply = applyCertLocal, .remove = removeCertLocal },
        .{ .prefix = "node/", .apply = applyNodeAddrLocal },
    };

    /// Route a committed directory `key=value` to the projection by key
    /// prefix. Caller holds `self.mutex`. Unknown keys are ignored
    /// (forward-compatible with a later host-index axis).
    fn applyDirKv(self: *Directory, key: []const u8, value: []const u8) Error!void {
        for (dir_axes) |ax| {
            if (std.mem.startsWith(u8, key, ax.prefix)) {
                return ax.apply(self, key[ax.prefix.len..], value);
            }
        }
    }

    /// Route a committed directory DELETE to the projection by key prefix.
    /// Caller holds `self.mutex`. An axis with no remover logs and ignores —
    /// never falls through to a write.
    fn applyDirKvDelete(self: *Directory, key: []const u8) Error!void {
        for (dir_axes) |ax| {
            if (!std.mem.startsWith(u8, key, ax.prefix)) continue;
            const remove = ax.remove orelse {
                std.log.warn("cp directory: delete of {s} ignored — axis {s} has no removal path", .{ key, ax.prefix });
                return;
            };
            remove(self, key[ax.prefix.len..]);
            return;
        }
    }

    /// Drop a placement from the projection. Freeing the owned key requires
    /// `fetchRemove` — plain `remove` would leak the duped tenant id.
    fn removePlacementLocal(self: *Directory, tenant: []const u8) void {
        if (self.placements.fetchRemove(tenant)) |kv| self.allocator.free(kv.key);
    }

    /// Drop a plan; both the key and the blob are owned.
    fn removePlanLocal(self: *Directory, tenant: []const u8) void {
        if (self.plans.fetchRemove(tenant)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    fn removeHostLocal(self: *Directory, host: []const u8) void {
        if (self.hosts.fetchRemove(host)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    fn removeCertLocal(self: *Directory, host: []const u8) void {
        if (self.certs.fetchRemove(host)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
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
        return self.writePlacement(tenant_id, cluster_id);
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
        return self.writePlacement(tenant_id, dest_cluster_id);
    }

    /// Build + apply a `placement/{tenant}` = `{cluster}` write
    /// (replicated → apply observer materializes it; inline ephemerally).
    /// The caller has already validated under a brief lock; this holds no
    /// lock across the replicate/await (see `applyDirWrite`).
    fn writePlacement(self: *Directory, tenant: []const u8, cluster_id: []const u8) Error!void {
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "placement/{s}", .{tenant}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirWrite(key, cluster_id);
    }

    /// Upsert a placement into the in-memory projection (no replication).
    fn applyPlacementLocal(self: *Directory, tenant_id: []const u8, cluster_idx: usize) Error!void {
        const gop = self.placements.getOrPut(self.allocator, tenant_id) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            const key_dup = self.allocator.dupe(u8, tenant_id) catch {
                _ = self.placements.remove(tenant_id);
                return Error.OutOfMemory;
            };
            gop.key_ptr.* = key_dup;
        }
        gop.value_ptr.* = .{ .cluster_idx = cluster_idx };
    }

    /// Withdraw a tenant's placement — the tenant stops being routable and its
    /// name becomes reusable. The directory half of a deprovision.
    ///
    /// Idempotent: removing an absent placement succeeds, so a retried teardown
    /// after a partial failure converges instead of 500ing. That matters more
    /// than reporting "already gone" — a deprovision is a sequence of steps
    /// across several nodes, and any of them may be retried.
    pub fn unassign(self: *Directory, tenant_id: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.placements.getPtr(tenant_id) == null) return; // already gone
        }
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "placement/{s}", .{tenant_id}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirDelete(key);
    }

    /// Drop a host→tenant mapping, so the host stops resolving and may be
    /// remapped. Idempotent (see `unassign`).
    pub fn removeHost(self: *Directory, host: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.hosts.getPtr(host) == null) return;
        }
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "host/{s}", .{host}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirDelete(key);
    }

    /// Record a tenant's storage incarnation so later attaches can carry it.
    /// Replicates like every other directory axis.
    pub fn setIncarnation(self: *Directory, tenant_id: []const u8, value: []const u8) Error!void {
        if (tenant_id.len == 0) return Error.BadConfig;
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "incarnation/{s}", .{tenant_id}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirWrite(key, value);
    }

    /// A tenant's incarnation as an OWNED copy (caller frees), or empty when it
    /// has none — a tenant provisioned before incarnations existed, which stays
    /// on the legacy name-keyed layout.
    pub fn incarnationForOwned(self: *Directory, a: std.mem.Allocator, tenant_id: []const u8) Error![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = self.incarnations.get(tenant_id) orelse return a.dupe(u8, "") catch Error.OutOfMemory;
        return a.dupe(u8, v) catch Error.OutOfMemory;
    }

    fn applyIncarnationLocal(self: *Directory, tenant: []const u8, value: []const u8) Error!void {
        const a = self.allocator;
        const val_dup = a.dupe(u8, value) catch return Error.OutOfMemory;
        errdefer a.free(val_dup);
        const gop = self.incarnations.getOrPut(a, tenant) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, tenant) catch {
                _ = self.incarnations.remove(tenant);
                return Error.OutOfMemory;
            };
        } else a.free(gop.value_ptr.*);
        gop.value_ptr.* = val_dup;
    }

    fn removeIncarnationLocal(self: *Directory, tenant: []const u8) void {
        if (self.incarnations.fetchRemove(tenant)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Withdraw a tenant's incarnation row (deprovision). Idempotent.
    pub fn removeIncarnation(self: *Directory, tenant_id: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.incarnations.getPtr(tenant_id) == null) return;
        }
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "incarnation/{s}", .{tenant_id}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirDelete(key);
    }

    /// Drop a tenant's plan blob; the DP then treats it as the free tier
    /// (absent has always meant free). Idempotent (see `unassign`).
    pub fn removePlan(self: *Directory, tenant_id: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.plans.getPtr(tenant_id) == null) return;
        }
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "plan/{s}", .{tenant_id}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirDelete(key);
    }

    /// Drop a host's stored cert+key. Idempotent (see `unassign`).
    pub fn removeCert(self: *Directory, host: []const u8) Error!void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.certs.getPtr(host) == null) return;
        }
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "cert/{s}", .{host}) catch return Error.OutOfMemory;
        defer a.free(key);
        return self.applyDirDelete(key);
    }

    /// Every host currently mapped to `tenant_id`, as owned strings (caller
    /// frees each and the slice). A deprovision needs this because the
    /// host→tenant index has no reverse direction: the rows to withdraw can
    /// only be found by scanning.
    pub fn hostsForOwned(self: *Directory, a: std.mem.Allocator, tenant_id: []const u8) Error![][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |h| a.free(h);
            out.deinit(a);
        }
        var it = self.hosts.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.value_ptr.*, tenant_id)) continue;
            const dup = a.dupe(u8, e.key_ptr.*) catch return Error.OutOfMemory;
            out.append(a, dup) catch {
                a.free(dup);
                return Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    /// Resolve a tenant to the cluster currently serving it, or null if the
    /// tenant has no placement (the front door 404s / 421-misdirects). The
    /// hot-path read. Returns the `ClusterRef` by value; its slices are
    /// pointer-stable, so the caller may hold them past the lock.
    pub fn clusterFor(self: *Directory, tenant_id: []const u8) ?ClusterRef {
        return if (self.resolve(tenant_id)) |r| r.cluster else null;
    }

    /// Hot-path read: the serving cluster for a tenant. Slices are
    /// pointer-stable; safe to hold past the lock.
    pub fn resolve(self: *Directory, tenant_id: []const u8) ?Resolution {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.placements.get(tenant_id) orelse return null;
        const c = self.clusters.items[p.cluster_idx];
        return .{ .cluster = .{ .id = c.id, .nodes = c.nodes } };
    }

    /// A tenant's placement with the cluster id + node set DEEP-COPIED into
    /// caller-owned storage. Caller calls `deinit`.
    pub const OwnedResolution = struct {
        id: []u8,
        nodes: [][]u8,
        pub fn deinit(self: *OwnedResolution, a: std.mem.Allocator) void {
            freeNodes(a, self.nodes);
            a.free(self.id);
        }
    };

    /// Like `resolve`, but the cluster id + node set are copied UNDER THE LOCK
    /// into owned storage — safe to hold across blocking I/O. `resolve`'s
    /// `ClusterRef.nodes` aliases the projection, which a concurrent re-address
    /// (`applyClusterLocal` on the pump thread — e.g. a `/_control/cluster` grow)
    /// frees out from under a held ref. Any caller that keeps the result past the
    /// lock while doing blocking work (the membership reconciler) MUST use this.
    /// Copying after `resolve` returns is NOT enough — the array can be freed in
    /// the window between unlock and the copy; the copy has to happen under the lock.
    pub fn resolveOwned(self: *Directory, a: std.mem.Allocator, tenant_id: []const u8) Error!?OwnedResolution {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.placements.get(tenant_id) orelse return null;
        const c = self.clusters.items[p.cluster_idx];
        const nodes = try dupeNodes(a, c.nodes);
        errdefer freeNodes(a, nodes);
        const id = a.dupe(u8, c.id) catch return Error.OutOfMemory;
        return OwnedResolution{ .id = id, .nodes = nodes };
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

    /// The one configured cluster, or null when there are zero or several.
    /// Lets a caller that has no basis to choose — self-serve provisioning —
    /// omit the cluster in the single-cluster deployment that is the norm,
    /// while a multi-cluster deployment still has to say which, because
    /// picking one IS a placement policy.
    pub fn soleCluster(self: *Directory) ?ClusterRef {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.clusters.items.len != 1) return null;
        const c = self.clusters.items[0];
        return .{ .id = c.id, .nodes = c.nodes };
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

    // ── Domain index (host → tenant) ─────────────────────────────────

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

    // ── Cert state (ACME issuer / operator writes, front-door reads) ─────

    /// A host's packed TLS cert+key
    /// (`[1B version][4B BE cert_len][cert_pem][key_pem]`), split into PEM
    /// slices. Front doors feed these straight into OpenSSL.
    pub const Cert = struct { cert_pem: []const u8, key_pem: []const u8 };

    /// Packed-cert format version (`docs/architecture/format-versioning.md` §3.4).
    /// A leading version byte so a future cert-frame change (extra fields,
    /// a chain split) is a soft upgrade; `unpackCert` rejects other values.
    /// Frozen v1 at the pre-launch format freeze.
    pub const CERT_PACK_VERSION: u8 = 1;

    /// Pack a cert+key into the on-wire/at-rest frame (caller owns the result).
    pub fn packCert(a: std.mem.Allocator, cert_pem: []const u8, key_pem: []const u8) Error![]u8 {
        const out = a.alloc(u8, 1 + 4 + cert_pem.len + key_pem.len) catch return Error.OutOfMemory;
        out[0] = CERT_PACK_VERSION;
        std.mem.writeInt(u32, out[1..5], @intCast(cert_pem.len), .big);
        @memcpy(out[5 .. 5 + cert_pem.len], cert_pem);
        @memcpy(out[5 + cert_pem.len ..], key_pem);
        return out;
    }

    /// Split a packed frame into its PEM slices (borrowed from `packed_bytes`),
    /// or null if the frame is malformed or carries an unknown version.
    pub fn unpackCert(packed_bytes: []const u8) ?Cert {
        if (packed_bytes.len < 5) return null;
        if (packed_bytes[0] != CERT_PACK_VERSION) return null;
        const clen = std.mem.readInt(u32, packed_bytes[1..5], .big);
        if (5 + clen > packed_bytes.len) return null;
        return .{ .cert_pem = packed_bytes[5 .. 5 + clen], .key_pem = packed_bytes[5 + clen ..] };
    }

    /// Store a host's cert: `cert/{host} = packCert(cert, key)`. Written by the
    /// leader-elected ACME issuer (in-process) or a `/_control/cert` operator
    /// upload. Replicates before it takes effect (apply observer materializes
    /// it on the leader AND every follower). Placement-independent.
    pub fn setCert(self: *Directory, host: []const u8, cert_pem: []const u8, key_pem: []const u8) Error!void {
        if (host.len == 0 or cert_pem.len == 0 or key_pem.len == 0) return Error.BadConfig;
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "cert/{s}", .{host}) catch return Error.OutOfMemory;
        defer a.free(key);
        const value = try packCert(a, cert_pem, key_pem);
        defer a.free(value);
        try self.applyDirWrite(key, value);
        // Mirror AFTER the write commits: the raft copy is the live one, and a
        // mirror of something that failed to replicate would be a certificate
        // no node is serving. Both cert writers (the ACME issuer and the
        // `/_control/cert` upload) funnel through here, so the mirror cannot be
        // missed by adding a third.
        if (self.cert_mirror) |m| m.put(m.ctx, host, value);
    }

    /// A host's packed cert frame as an OWNED copy (caller frees + `unpackCert`s),
    /// or null if no cert is stored. Owned copy because — like a plan/host value
    /// — a cert can be replaced (freed) by a concurrent apply (a renewal).
    pub fn certForOwned(self: *Directory, a: std.mem.Allocator, host: []const u8) Error!?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = self.certs.get(host) orelse return null;
        return a.dupe(u8, v) catch return Error.OutOfMemory;
    }

    /// Whether a (any) cert is stored for `host` — the issuer's "already issued?"
    /// check, cheaper than copying the bytes out.
    pub fn hasCert(self: *Directory, host: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.certs.contains(host);
    }

    /// True when `host` has a stored certificate that is still good for at
    /// least `renew_window_s`. This — not `hasCert` — is the question the
    /// issuer's skip-if-already-done guard must ask: an expiring certificate
    /// IS a stored certificate, so a `hasCert` guard would skip exactly the
    /// hosts that need renewing.
    pub fn hasUsableCert(
        self: *Directory,
        a: std.mem.Allocator,
        host: []const u8,
        now_s: i64,
        renew_window_s: i64,
    ) bool {
        const frame = (self.certForOwned(a, host) catch return false) orelse return false;
        defer a.free(frame);
        const parsedc = unpackCert(frame) orelse return false;
        return !acme_expiry.needsRenewal(a, parsedc.cert_pem, now_s, renew_window_s);
    }

    /// The hosts that currently have a stored cert (owned dups; caller frees
    /// each + the slice). The front door polls this (`/_cp/certs`) to learn
    /// which per-host certs to pull into its SNI store.
    pub fn certHostsOwned(self: *Directory, a: std.mem.Allocator) Error![][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |h| a.free(h);
            out.deinit(a);
        }
        var it = self.certs.keyIterator();
        while (it.next()) |k| {
            out.append(a, a.dupe(u8, k.*) catch return Error.OutOfMemory) catch return Error.OutOfMemory;
        }
        return out.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    /// Upsert a packed cert into the in-memory projection (no replication). The
    /// committed-state applier, shared by replay + the post-commit observer.
    fn applyCertLocal(self: *Directory, host: []const u8, value: []const u8) Error!void {
        const a = self.allocator;
        const val_dup = a.dupe(u8, value) catch return Error.OutOfMemory;
        errdefer a.free(val_dup);
        const gop = self.certs.getOrPut(a, host) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, host) catch {
                _ = self.certs.remove(host);
                return Error.OutOfMemory;
            };
        } else {
            a.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val_dup;
    }

    // ── Node-address registry (operator writes, peer resolver reads) ─────
    //
    // The rove analog of PD's store-address table: raft id → transport address,
    // keyed `node/{cluster}/{id}`. A node configured with only its own identity
    // (docs/architecture/consensus-and-storage.md "Cluster genesis & membership",
    // node-address registry) registers itself here; peers resolve
    // each other's addresses from here instead of a static positional
    // `REWIND_PEERS`. The CP directory group uses it for its own membership too.

    /// A node's transport addresses, split out of the packed registry value.
    /// `raft_addr` is the load-bearing field (the worker raft-net `host:port`);
    /// `cp_raft_addr` is the CP directory raft `host:port` (CP nodes only);
    /// `http_url` is the node's HTTP origin. Borrowed from the packed bytes.
    pub const NodeAddr = struct {
        raft_addr: []const u8,
        cp_raft_addr: []const u8,
        http_url: []const u8,
    };

    /// Packed node-address frame version (`docs/architecture/format-versioning.md`).
    /// A leading version byte so adding a field later is a soft upgrade;
    /// `unpackNodeAddr` rejects other values. Frozen v1.
    pub const NODE_ADDR_PACK_VERSION: u8 = 1;

    /// One entry of a cluster's node-address list (owned packed bytes — unpack
    /// with `unpackNodeAddr`). Caller `deinit`s each.
    pub const NodeAddrEntry = struct {
        id: u64,
        bytes: []u8,
        pub fn deinit(self: *NodeAddrEntry, a: std.mem.Allocator) void {
            a.free(self.bytes);
        }
    };

    /// Pack the three address fields into the registry value (`[version]` then
    /// the fields tab-joined). Caller owns the result. Inputs must not contain a
    /// tab (the field separator) — `setNodeAddr` validates that.
    pub fn packNodeAddr(a: std.mem.Allocator, raft_addr: []const u8, cp_raft_addr: []const u8, http_url: []const u8) Error![]u8 {
        const out = a.alloc(u8, 1 + raft_addr.len + 1 + cp_raft_addr.len + 1 + http_url.len) catch return Error.OutOfMemory;
        out[0] = NODE_ADDR_PACK_VERSION;
        var i: usize = 1;
        @memcpy(out[i..][0..raft_addr.len], raft_addr);
        i += raft_addr.len;
        out[i] = '\t';
        i += 1;
        @memcpy(out[i..][0..cp_raft_addr.len], cp_raft_addr);
        i += cp_raft_addr.len;
        out[i] = '\t';
        i += 1;
        @memcpy(out[i..][0..http_url.len], http_url);
        return out;
    }

    /// Split a packed registry value into its address fields (borrowed from
    /// `bytes`), or null if malformed / an unknown version / a missing
    /// `raft_addr`. `cp_raft_addr` / `http_url` may be empty.
    pub fn unpackNodeAddr(bytes: []const u8) ?NodeAddr {
        if (bytes.len < 1 or bytes[0] != NODE_ADDR_PACK_VERSION) return null;
        var it = std.mem.splitScalar(u8, bytes[1..], '\t');
        const raft_addr = it.next() orelse return null;
        const cp_raft_addr = it.next() orelse "";
        const http_url = it.next() orelse "";
        if (raft_addr.len == 0) return null;
        return .{ .raft_addr = raft_addr, .cp_raft_addr = cp_raft_addr, .http_url = http_url };
    }

    /// Register (or re-register) a node's transport addresses:
    /// `node/{cluster}/{id} = packNodeAddr(...)`. Idempotent on (cluster, id) —
    /// a repeat overwrites (re-IP). `raft_addr` is required; the others may be
    /// empty. Replicates before it takes effect (apply observer materializes it
    /// on the leader AND every follower).
    pub fn setNodeAddr(self: *Directory, cluster: []const u8, id: u64, raft_addr: []const u8, cp_raft_addr: []const u8, http_url: []const u8) Error!void {
        if (cluster.len == 0 or id == 0 or raft_addr.len == 0) return Error.BadConfig;
        // A tab would corrupt the field framing; reject loudly rather than store
        // an unparseable value. A '/' in the cluster would break key parsing.
        if (std.mem.indexOfScalar(u8, cluster, '/') != null) return Error.BadConfig;
        for ([_][]const u8{ raft_addr, cp_raft_addr, http_url }) |f| {
            if (std.mem.indexOfScalar(u8, f, '\t') != null) return Error.BadConfig;
        }
        const a = self.allocator;
        const key = std.fmt.allocPrint(a, "node/{s}/{d}", .{ cluster, id }) catch return Error.OutOfMemory;
        defer a.free(key);
        const value = try packNodeAddr(a, raft_addr, cp_raft_addr, http_url);
        defer a.free(value);
        return self.applyDirWrite(key, value);
    }

    /// A node's packed address frame as an OWNED copy (caller frees + unpacks),
    /// or null if unregistered. Owned because a re-register (re-IP) can free the
    /// projection value under a concurrent apply.
    pub fn nodeAddrOwned(self: *Directory, a: std.mem.Allocator, cluster: []const u8, id: u64) Error!?[]u8 {
        const suffix = std.fmt.allocPrint(a, "{s}/{d}", .{ cluster, id }) catch return Error.OutOfMemory;
        defer a.free(suffix);
        self.mutex.lock();
        defer self.mutex.unlock();
        const v = self.node_addrs.get(suffix) orelse return null;
        return a.dupe(u8, v) catch return Error.OutOfMemory;
    }

    /// Every registered node in `cluster` (owned packed bytes; caller `deinit`s
    /// each entry + frees the slice). The peer resolver bulk-loads this to learn
    /// a cluster's id → address map.
    pub fn listClusterNodeAddrs(self: *Directory, a: std.mem.Allocator, cluster: []const u8) Error![]NodeAddrEntry {
        const prefix = std.fmt.allocPrint(a, "{s}/", .{cluster}) catch return Error.OutOfMemory;
        defer a.free(prefix);
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged(NodeAddrEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(a);
            out.deinit(a);
        }
        var it = self.node_addrs.iterator();
        while (it.next()) |e| {
            const suffix = e.key_ptr.*;
            if (!std.mem.startsWith(u8, suffix, prefix)) continue;
            const id_str = suffix[prefix.len..];
            const id = std.fmt.parseInt(u64, id_str, 10) catch continue;
            const bytes = a.dupe(u8, e.value_ptr.*) catch return Error.OutOfMemory;
            out.append(a, .{ .id = id, .bytes = bytes }) catch {
                a.free(bytes);
                return Error.OutOfMemory;
            };
        }
        return out.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    /// Upsert a packed node address into the in-memory projection (no
    /// replication). The committed-state applier, shared by replay + the
    /// post-commit observer. `suffix` is the key's `{cluster}/{id}` part.
    fn applyNodeAddrLocal(self: *Directory, suffix: []const u8, value: []const u8) Error!void {
        const a = self.allocator;
        const val_dup = a.dupe(u8, value) catch return Error.OutOfMemory;
        errdefer a.free(val_dup);
        const gop = self.node_addrs.getOrPut(a, suffix) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, suffix) catch {
                _ = self.node_addrs.remove(suffix);
                return Error.OutOfMemory;
            };
        } else {
            a.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val_dup;
    }

    /// Collect the mapped hosts that need a certificate issued (owned dups;
    /// caller frees each + the slice) — the ACME issuer's work-list.
    ///
    /// A host needs one when it has none, OR when the one it has expires within
    /// `renew_window_s`. Both are the same job: certificates are short-lived by
    /// design, so "has a cert" is not the same question as "has a usable cert",
    /// and treating only the first as work means every certificate is issued
    /// once and then serves until it dies.
    ///
    /// Expiry is evaluated OUTSIDE the lock — parsing is pure and the frames
    /// are copied, so the mutex covers the index walk only.
    pub fn collectHostsNeedingCert(
        self: *Directory,
        a: std.mem.Allocator,
        now_s: i64,
        renew_window_s: i64,
    ) Error![][]u8 {
        const Candidate = struct { host: []u8, frame: ?[]u8 };
        var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
        defer {
            for (candidates.items) |c| {
                a.free(c.host);
                if (c.frame) |f| a.free(f);
            }
            candidates.deinit(a);
        }

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.hosts.keyIterator();
            while (it.next()) |k| {
                const host = a.dupe(u8, k.*) catch return Error.OutOfMemory;
                errdefer a.free(host);
                const frame: ?[]u8 = if (self.certs.get(k.*)) |v|
                    (a.dupe(u8, v) catch return Error.OutOfMemory)
                else
                    null;
                candidates.append(a, .{ .host = host, .frame = frame }) catch return Error.OutOfMemory;
            }
        }

        var out: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (out.items) |h| a.free(h);
            out.deinit(a);
        }
        for (candidates.items) |cand| {
            const needs = if (cand.frame) |frame| blk: {
                // An unreadable frame counts as needing issuance for the same
                // reason an unreadable certificate does — it cannot be vouched
                // for, and re-issuing is cheap next to serving something broken.
                const parsedc = unpackCert(frame) orelse break :blk true;
                break :blk acme_expiry.needsRenewal(a, parsedc.cert_pem, now_s, renew_window_s);
            } else true;
            if (needs) out.append(a, a.dupe(u8, cand.host) catch return Error.OutOfMemory) catch
                return Error.OutOfMemory;
        }
        return out.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    // ── Static config seeding ────────────────────────────────────────

    /// Seed clusters from a config string of the form
    /// `id=url1,url2,…;id=url;…` — each cluster's value is a comma-separated
    /// list of member node origins (one for a single-node cluster, N for a
    /// multi-node one). Whitespace around tokens is trimmed, a trailing `;`
    /// is allowed. The static-config path — the front door calls this once
    /// at startup (into an empty directory) from an env var. Each entry is
    /// `addCluster`'d (so it replicates + a repeat id re-addresses).
    ///
    /// Every origin is validated against `rove-origin` BEFORE anything
    /// replicates: an origin the front door cannot dial must not reach the
    /// directory, because from there it fans out to every front and only
    /// fails at dial time, far from the operator who typed it. Validation
    /// is per entry and precedes that entry's `addCluster`, so a bad entry
    /// cannot be replicated — though entries before it already have (the
    /// caller treats a seed failure as fatal, and seeds are idempotent).
    pub fn seedClusters(self: *Directory, config: []const u8) (ConfigError || Error)!void {
        var node_buf: [MAX_CLUSTER_NODES][]const u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            self.seed_bad_entry = entry;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse
                return ConfigError.SeedEntryMissingEquals;
            const id = std.mem.trim(u8, entry[0..eq], " \t");
            const urls = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (id.len == 0) return ConfigError.SeedClusterIdEmpty;
            if (urls.len == 0) return ConfigError.SeedClusterNodesEmpty;

            var n: usize = 0;
            var nit = std.mem.tokenizeScalar(u8, urls, ',');
            while (nit.next()) |rawn| {
                const url = std.mem.trim(u8, rawn, " \t");
                if (url.len == 0) continue;
                if (n >= node_buf.len) return ConfigError.SeedClusterTooManyNodes;
                _ = origin_mod.parse(url) catch |e| {
                    self.seed_bad_entry = url;
                    return switch (e) {
                        error.HostnameOriginUnsupported => ConfigError.SeedOriginNotIpLiteral,
                        error.OriginBadPort => ConfigError.SeedOriginBadPort,
                        error.OriginEmpty => ConfigError.SeedOriginEmpty,
                    };
                };
                node_buf[n] = url;
                n += 1;
            }
            if (n == 0) return ConfigError.SeedClusterNodesEmpty;
            try self.addCluster(id, node_buf[0..n]);
        }
        self.seed_bad_entry = "";
    }

    /// Seed initial placements from a config string of the form
    /// `tenant=cluster_id;tenant=cluster_id;…`. Each entry is `assign`'d,
    /// so every named cluster must already be seeded (`seedClusters`
    /// first). The static-placement path (into a fresh directory).
    pub fn seedPlacements(self: *Directory, config: []const u8) (ConfigError || Error)!void {
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            self.seed_bad_entry = entry;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse
                return ConfigError.SeedEntryMissingEquals;
            const tenant = std.mem.trim(u8, entry[0..eq], " \t");
            const cluster = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (tenant.len == 0) return ConfigError.SeedPlacementTenantEmpty;
            if (cluster.len == 0) return ConfigError.SeedPlacementClusterEmpty;
            try self.assign(tenant, cluster);
        }
        self.seed_bad_entry = "";
    }

    /// Seed the domain index from a config string of the form
    /// `host=tenant;host=tenant;…` (the static `REWIND_HOSTS` map, written
    /// INTO the replicated directory so it survives a restart + spans
    /// the HA nodes). Each entry is `setHost`'d (replicated). Runtime custom
    /// domains are added later via the `/_control/host` control write.
    pub fn seedHosts(self: *Directory, config: []const u8) (ConfigError || Error)!void {
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            self.seed_bad_entry = entry;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse
                return ConfigError.SeedEntryMissingEquals;
            const host = std.mem.trim(u8, entry[0..eq], " \t");
            const tenant = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (host.len == 0) return ConfigError.SeedHostEmpty;
            if (tenant.len == 0) return ConfigError.SeedHostTenantEmpty;
            try self.setHost(host, tenant);
        }
        self.seed_bad_entry = "";
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
    try testing.expectError(error.SeedEntryMissingEquals, dir.seedHosts("missing-equals"));
}

test "directory: setNodeAddr registry round-trips, re-registers, lists per cluster" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    const a = testing.allocator;

    // unregistered → null
    try testing.expect((try dir.nodeAddrOwned(a, "prod", 1)) == null);

    // register node 1 with all three fields
    try dir.setNodeAddr("prod", 1, "10.0.0.1:9001", "10.0.0.1:9101", "http://10.0.0.1:8080");
    {
        const v = (try dir.nodeAddrOwned(a, "prod", 1)).?;
        defer a.free(v);
        const na = Directory.unpackNodeAddr(v).?;
        try testing.expectEqualStrings("10.0.0.1:9001", na.raft_addr);
        try testing.expectEqualStrings("10.0.0.1:9101", na.cp_raft_addr);
        try testing.expectEqualStrings("http://10.0.0.1:8080", na.http_url);
    }

    // re-register (re-IP) overwrites; old value freed — no leak
    try dir.setNodeAddr("prod", 1, "10.0.0.9:9001", "", "");
    {
        const v = (try dir.nodeAddrOwned(a, "prod", 1)).?;
        defer a.free(v);
        const na = Directory.unpackNodeAddr(v).?;
        try testing.expectEqualStrings("10.0.0.9:9001", na.raft_addr);
        try testing.expectEqualStrings("", na.cp_raft_addr);
        try testing.expectEqualStrings("", na.http_url);
    }

    // a second node + a node in a different cluster
    try dir.setNodeAddr("prod", 2, "10.0.0.2:9001", "", "");
    try dir.setNodeAddr("staging", 1, "10.1.0.1:9001", "", "");

    // list is scoped to the cluster and parses ids
    {
        const entries = try dir.listClusterNodeAddrs(a, "prod");
        defer {
            for (entries) |*e| e.deinit(a);
            a.free(entries);
        }
        try testing.expectEqual(@as(usize, 2), entries.len);
        var seen1 = false;
        var seen2 = false;
        for (entries) |e| {
            const na = Directory.unpackNodeAddr(e.bytes).?;
            if (e.id == 1) {
                seen1 = true;
                try testing.expectEqualStrings("10.0.0.9:9001", na.raft_addr);
            } else if (e.id == 2) {
                seen2 = true;
                try testing.expectEqualStrings("10.0.0.2:9001", na.raft_addr);
            } else return error.UnexpectedId;
        }
        try testing.expect(seen1 and seen2);
    }

    // validation: empty cluster / id 0 / empty raft_addr / '/' in cluster / tab in a field
    try testing.expectError(error.BadConfig, dir.setNodeAddr("", 1, "h:1", "", ""));
    try testing.expectError(error.BadConfig, dir.setNodeAddr("prod", 0, "h:1", "", ""));
    try testing.expectError(error.BadConfig, dir.setNodeAddr("prod", 3, "", "", ""));
    try testing.expectError(error.BadConfig, dir.setNodeAddr("a/b", 1, "h:1", "", ""));
    try testing.expectError(error.BadConfig, dir.setNodeAddr("prod", 3, "h:1", "x\ty", ""));

    // unpack rejects a bad version / empty raft_addr
    try testing.expect(Directory.unpackNodeAddr(&[_]u8{ 9, 'a' }) == null);
    try testing.expect(Directory.unpackNodeAddr(&[_]u8{Directory.NODE_ADDR_PACK_VERSION}) == null);
}

test "directory: setCert + certForOwned round-trip, pack/unpack, uncerted list" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    const a = testing.allocator;

    try testing.expect(!dir.hasCert("acme.com"));
    try testing.expect((try dir.certForOwned(a, "acme.com")) == null);

    try dir.setCert("acme.com", "CERTPEM", "KEYPEM");
    try testing.expect(dir.hasCert("acme.com"));
    {
        const packed_bytes = (try dir.certForOwned(a, "acme.com")).?;
        defer a.free(packed_bytes);
        // Frame carries the version byte first (`docs/architecture/format-versioning.md` §3.4).
        try testing.expectEqual(Directory.CERT_PACK_VERSION, packed_bytes[0]);
        const u = Directory.unpackCert(packed_bytes).?;
        try testing.expectEqualStrings("CERTPEM", u.cert_pem);
        try testing.expectEqualStrings("KEYPEM", u.key_pem);
        // An unknown version is rejected loudly (null), not mis-split.
        var bad = a.dupe(u8, packed_bytes) catch unreachable;
        defer a.free(bad);
        bad[0] = 0xFE;
        try testing.expect(Directory.unpackCert(bad) == null);
    }

    // renewal replaces (old value freed — no leak under the testing allocator)
    try dir.setCert("acme.com", "CERT2", "KEY2");
    {
        const packed_bytes = (try dir.certForOwned(a, "acme.com")).?;
        defer a.free(packed_bytes);
        const u = Directory.unpackCert(packed_bytes).?;
        try testing.expectEqualStrings("CERT2", u.cert_pem);
    }

    try testing.expectError(error.BadConfig, dir.setCert("", "c", "k"));
    try testing.expectError(error.BadConfig, dir.setCert("h", "", "k"));

    // Issuance work-list. "Needs a cert" is three cases, and the middle one is
    // the whole reason this is not just `!certs.contains(host)`.
    const real_pem = acme_expiry.testdata.cert_pem;
    const expires_at = acme_expiry.testdata.not_after;
    const day = std.time.s_per_day;

    try dir.setHost("valid.com", "t1"); // a real, unexpired certificate
    try dir.setCert("valid.com", real_pem, "KEYPEM");
    try dir.setHost("none.com", "t2"); // no certificate at all
    try dir.setHost("broken.com", "t3"); // a certificate that will not parse
    try dir.setCert("broken.com", "NOT-A-PEM", "KEYPEM");

    const listPending = struct {
        fn call(d: *Directory, alloc: std.mem.Allocator, now: i64, window: i64) ![][]u8 {
            return d.collectHostsNeedingCert(alloc, now, window);
        }
    }.call;

    {
        // Well before expiry: only the missing and the unreadable are work.
        const pending = try listPending(&dir, a, expires_at - 60 * day, 30 * day);
        defer {
            for (pending) |h| a.free(h);
            a.free(pending);
        }
        try testing.expectEqual(@as(usize, 2), pending.len);
        var saw_none = false;
        var saw_broken = false;
        for (pending) |h| {
            if (std.mem.eql(u8, h, "none.com")) saw_none = true;
            if (std.mem.eql(u8, h, "broken.com")) saw_broken = true;
            // The valid cert must NOT be work yet — that is the case a
            // renew-everything loop would get wrong, burning issuance quota.
            try testing.expect(!std.mem.eql(u8, h, "valid.com"));
        }
        try testing.expect(saw_none and saw_broken);
    }

    {
        // Inside the renewal window the still-valid certificate becomes work.
        // `hasCert` is true for it throughout, so a containment check would
        // never surface it and the certificate would expire in place.
        const pending = try listPending(&dir, a, expires_at - 10 * day, 30 * day);
        defer {
            for (pending) |h| a.free(h);
            a.free(pending);
        }
        try testing.expectEqual(@as(usize, 3), pending.len);
        var saw_valid = false;
        for (pending) |h| {
            if (std.mem.eql(u8, h, "valid.com")) saw_valid = true;
        }
        try testing.expect(saw_valid);
    }

    // The issuer's skip-guard has to agree with the work-list, or it would
    // filter back out exactly what the list surfaced.
    try testing.expect(dir.hasUsableCert(a, "valid.com", expires_at - 60 * day, 30 * day));
    try testing.expect(!dir.hasUsableCert(a, "valid.com", expires_at - 10 * day, 30 * day));
    try testing.expect(!dir.hasUsableCert(a, "broken.com", 0, 0));
    try testing.expect(!dir.hasUsableCert(a, "none.com", 0, 0));
    // …while `hasCert` cannot tell the last two apart from a healthy one.
    try testing.expect(dir.hasCert("broken.com"));
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

test "directory: assign places, move flips the directory" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try addNode1(&dir, "c1", "http://h:1");
    try addNode1(&dir, "c2", "http://h:2");
    try dir.assign("t", "c1");

    // Placed on c1.
    var r = dir.resolve("t").?;
    try testing.expectEqualStrings("c1", r.cluster.id);

    // The directory flip commits the move: now served by c2.
    try dir.move("t", "c2");
    r = dir.resolve("t").?;
    try testing.expectEqualStrings("c2", r.cluster.id);

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

    try testing.expectError(error.SeedEntryMissingEquals, dir.seedClusters("missing-equals"));
    try testing.expectError(error.SeedClusterIdEmpty, dir.seedClusters("=http://nohost"));
    try testing.expectError(error.UnknownCluster, dir.seedPlacements("x=ghost-cluster"));
}

test "directory: removal withdraws each axis and is idempotent" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    const a = testing.allocator;

    try dir.seedClusters("c1=http://127.0.0.1:1");
    try dir.assign("acme", "c1");
    try dir.setHost("acme.test", "acme");
    try dir.setPlan("acme", "{\"tier\":\"pro\"}");

    try testing.expect(dir.resolve("acme") != null);
    {
        const t = (try dir.hostTenantForOwned(a, "acme.test")).?;
        defer a.free(t);
        try testing.expectEqualStrings("acme", t);
    }

    // Withdrawing a placement makes the tenant unroutable and frees the name.
    try dir.unassign("acme");
    try testing.expect(dir.resolve("acme") == null);

    try dir.removeHost("acme.test");
    try testing.expect((try dir.hostTenantForOwned(a, "acme.test")) == null);

    try dir.removePlan("acme");
    try testing.expect((try dir.planForOwned(a, "acme")) == null);

    // Idempotent: a retried teardown after a partial failure must converge,
    // not error — every one of these runs again in a retry.
    try dir.unassign("acme");
    try dir.removeHost("acme.test");
    try dir.removePlan("acme");

    // And the name is genuinely reusable afterwards.
    try dir.assign("acme", "c1");
    try testing.expectEqualStrings("c1", dir.resolve("acme").?.cluster.id);
}

test "directory: a removed row does not resurrect on replay" {
    // The property a follower depends on: rebuilding the projection from the
    // durable store must reach the same state as the leader. A real DELETE
    // (not an empty-value tombstone) means the key is simply absent from the
    // prefix scan — so this is really asserting that the delete reached the
    // store, not just the in-memory map.
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    try dir.seedClusters("c1=http://127.0.0.1:1");
    try dir.assign("gone", "c1");
    try dir.assign("stays", "c1");
    try dir.unassign("gone");

    // Re-derive the projection the way `replayFromStore` would: drop the
    // in-memory state and re-apply what the axes hold.
    dir.removePlacementLocal("gone");
    try testing.expect(dir.resolve("gone") == null);
    try testing.expect(dir.resolve("stays") != null);
}

test "directory: hostsForOwned finds the rows a deprovision must withdraw" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    const a = testing.allocator;

    try dir.seedClusters("c1=http://127.0.0.1:1");
    try dir.setHost("one.test", "acme");
    try dir.setHost("two.test", "acme");
    try dir.setHost("other.test", "globex");

    // The host index has no reverse direction, so teardown can only find a
    // tenant's hosts by scanning — without this, a deprovisioned tenant's
    // custom domains would dangle and could never be remapped.
    const hosts = try dir.hostsForOwned(a, "acme");
    defer {
        for (hosts) |h| a.free(h);
        a.free(hosts);
    }
    try testing.expectEqual(@as(usize, 2), hosts.len);
    for (hosts) |h| {
        try testing.expect(std.mem.eql(u8, h, "one.test") or std.mem.eql(u8, h, "two.test"));
    }

    const none = try dir.hostsForOwned(a, "nobody");
    defer a.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "directory: soleCluster answers only when there is no choice to make" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    // Nothing configured — a provisioner has nowhere to place a tenant.
    try testing.expect(dir.soleCluster() == null);

    try dir.seedClusters("only=http://127.0.0.1:18091");
    try testing.expectEqualStrings("only", dir.soleCluster().?.id);

    // A second cluster makes placement a policy decision, so the default
    // disappears rather than silently favouring the first-seeded one.
    try dir.seedClusters("only=http://127.0.0.1:18091; other=http://127.0.0.1:18092");
    try testing.expect(dir.soleCluster() == null);
}

test "directory: every seed parse failure is a distinct error naming its entry" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    // One error per condition — a single BadConfig for all of these told the
    // operator only that the variable was wrong somewhere.
    try testing.expectError(error.SeedEntryMissingEquals, dir.seedClusters("no-equals-here"));
    try testing.expectError(error.SeedClusterIdEmpty, dir.seedClusters("  =http://10.0.0.1:1"));
    try testing.expectError(error.SeedClusterNodesEmpty, dir.seedClusters("c1="));
    try testing.expectError(error.SeedClusterNodesEmpty, dir.seedClusters("c1= , ,"));

    try testing.expectError(error.SeedPlacementTenantEmpty, dir.seedPlacements("=c1"));
    try testing.expectError(error.SeedPlacementClusterEmpty, dir.seedPlacements("alice="));
    try testing.expectError(error.SeedEntryMissingEquals, dir.seedPlacements("alice"));

    try testing.expectError(error.SeedHostEmpty, dir.seedHosts("=alice"));
    try testing.expectError(error.SeedHostTenantEmpty, dir.seedHosts("a.com="));

    // The offending entry is recorded so the caller's message can name it
    // without re-parsing the config string.
    try testing.expectError(error.SeedClusterIdEmpty, dir.seedClusters("ok=http://10.0.0.1:1; =http://10.0.0.2:2"));
    try testing.expectEqualStrings("=http://10.0.0.2:2", dir.seed_bad_entry);

    // Cleared on success, so a stale entry cannot be reported against a
    // later failure.
    try dir.seedClusters("c9=http://10.0.0.9:9");
    try testing.expectEqualStrings("", dir.seed_bad_entry);
}

test "directory: seedClusters rejects origins the front door cannot dial" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    // The whole point: a hostname here would replicate to every front and
    // only fail at dial time, one hop from the operator who typed it.
    try testing.expectError(
        error.SeedOriginNotIpLiteral,
        dir.seedClusters("c1=http://worker-1.internal:8443"),
    );
    try testing.expectError(
        error.SeedOriginNotIpLiteral,
        dir.seedClusters("c1=http://localhost:8443"),
    );
    try testing.expectError(error.SeedOriginBadPort, dir.seedClusters("c1=http://10.0.0.1:https"));

    // Rejected BEFORE the cluster is added — nothing replicates.
    try testing.expect(dir.clusterById("c1") == null);

    // The bad origin is what gets recorded, not the whole entry: with 16
    // origins allowed per cluster, naming the entry would not locate it.
    try testing.expectError(
        error.SeedOriginNotIpLiteral,
        dir.seedClusters("c2=http://10.0.0.1:1,http://bad-host:2"),
    );
    try testing.expectEqualStrings("http://bad-host:2", dir.seed_bad_entry);

    // And the valid forms still pass.
    try dir.seedClusters("c3=http://10.0.0.1:8443,10.0.0.2:8443,https://10.0.0.3:8443");
    try testing.expectEqual(@as(usize, 3), dir.clusterById("c3").?.nodes.len);
}

// ── Replicated (durable) directory ──────────────────────────────────────

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

// ── Multi-node CP: apply-driven projection / HA ─────────────────────────

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
    const pseq = try bridges[li].proposePut(dir_gid, "placement/acme", "west");
    var done = false;
    var s2: u32 = 0;
    while (s2 < 3000 and !done) : (s2 += 1) {
        for (bridges) |b| _ = try b.pumpOnce();
        if (bridges[li].committedSeq(dir_gid) >= pseq) {
            done = true;
        } else {
            // Manual-pump loop, so `Bridge.awaitCommit` (which sleeps) can't
            // be used here — but keep its fail-fast: a faulted seq will
            // never commit, so spinning out the full 3000 rounds is noise.
            try testing.expect(bridges[li].faultedSeq(dir_gid) < pseq);
        }
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
    }
}
