//! V2 control plane — the tenant→cluster directory (docs/v2-build-order.md
//! §Phase 3 "a minimal control plane — the tenant→cluster directory").
//!
//! This is the routing source of truth: given a tenant's store id, which
//! cluster currently serves it. The **front-door** (`src-v2/front/`)
//! reads it on every inbound request to pick a backend; the **move
//! orchestration** (Phase 4) writes it — flipping a tenant's placement is
//! the atomic commit point of a tenant move.
//!
//! ## Scope (Phase 3, deliberately minimal)
//!
//! The build-order says the directory "can start dead simple (a tiny
//! replicated KV map, or even static config for the first move)." This is
//! the static, in-process form: an in-memory map seeded from config, with
//! a mutable `move` seam. It is intentionally NOT replicated yet — a
//! single front door owns the one authoritative copy. Replication (so
//! multiple front doors / control-plane HA agree on placement) is a later
//! hardening step; the interface here is the stable seam that change sits
//! behind.
//!
//! ## The move seam (what Phase 4 flips)
//!
//! `move(tenant, dest)` is the directory half of the tenant-move
//! milestone: source quiesces → bundle ships → destination attaches →
//! **`move` flips placement** → traffic resumes on the destination. Phase
//! 4 adds the `moving` interlock (hold a tenant's requests at the front
//! door while its bundle is in flight); Phase 3 ships only placement, so a
//! tenant is always `active` on exactly one cluster. The `Placement`
//! state enum is carried now (single `active` variant) so the Phase-4
//! interlock is an added variant, not a struct change at the call sites.
//!
//! ## Threading
//!
//! The front door reads `clusterFor` on the request hot path (many reader
//! threads); the control plane writes `assign`/`move` rarely. A single
//! mutex guards both maps — reads are short (one hash lookup + return a
//! pointer-stable `ClusterRef` by value), so lock contention is a
//! non-issue at Phase-3 front-door scale. If it ever shows up, this is the
//! obvious place for an RwLock or a seqlock; not worth it now.

const std = @import("std");

pub const Error = error{
    /// `assign`/`move` named a cluster id that was never `addCluster`'d.
    UnknownCluster,
    /// `move` named a tenant with no current placement (use `assign` for
    /// initial placement; `move` is strictly a re-placement).
    UnknownTenant,
    /// A config string handed to `seedFromConfig` was malformed.
    BadConfig,
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

/// A tenant's placement. Phase 3 has only `active`; Phase 4 adds e.g.
/// `moving` (hold requests) — see file header. Kept as a struct (not a
/// bare cluster id) so that added state rides alongside the cluster
/// without touching `clusterFor`'s callers.
pub const Placement = struct {
    state: State = .active,
    /// Index into `clusters` (the cluster currently serving this tenant).
    cluster_idx: usize,

    /// `active` — the tenant is served normally by `cluster_idx`.
    /// `moving` — a move is in flight: the bundle is shipping to the
    /// destination, so the front door holds the tenant's requests (503)
    /// until `move` flips placement (or `abortMove` reverts to active).
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

    /// Pointer-stable cluster storage. Appended to by `addCluster`, never
    /// reordered or removed (a cluster outlives the process), so an index
    /// into it is a stable handle and the owned id/url slices never move.
    clusters: std.ArrayListUnmanaged(OwnedCluster) = .empty,
    /// cluster id → index into `clusters`.
    cluster_idx: std.StringHashMapUnmanaged(usize) = .empty,
    /// tenant store id → placement.
    placements: std.StringHashMapUnmanaged(Placement) = .empty,

    const OwnedCluster = struct {
        id: []u8,
        /// Owned array of owned node-origin URLs. Allocated once per
        /// `addCluster`; never appended to, so the backing array address is
        /// stable and a `ClusterRef.nodes` slice held past the lock stays
        /// valid even when `clusters` reallocs (the slice header is copied
        /// by value; the array it points at does not move).
        nodes: [][]u8,
    };

    pub fn init(allocator: std.mem.Allocator) Directory {
        return .{ .allocator = allocator };
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
        // `placements` keys are owned dups (see `assign`).
        var it = self.placements.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.placements.deinit(a);
    }

    // ── Cluster registry (control plane) ─────────────────────────────

    /// Register a cluster the directory can place tenants on, with its
    /// member node origins (one URL for a single-node cluster, N for a
    /// multi-node one). Idempotent on `id` — a repeat call with the same id
    /// re-addresses the cluster (replaces its node set) and keeps the index
    /// stable. `nodes` must be non-empty. Safe from any thread.
    pub fn addCluster(self: *Directory, id: []const u8, nodes: []const []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.addClusterLocked(id, nodes);
    }

    fn addClusterLocked(self: *Directory, id: []const u8, nodes: []const []const u8) Error!void {
        const a = self.allocator;
        if (nodes.len == 0) return Error.BadConfig;
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
    /// Safe from any thread.
    pub fn assign(self: *Directory, tenant_id: []const u8, cluster_id: []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.cluster_idx.get(cluster_id) orelse return Error.UnknownCluster;
        const gop = self.placements.getOrPut(self.allocator, tenant_id) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            const key_dup = self.allocator.dupe(u8, tenant_id) catch {
                _ = self.placements.remove(tenant_id);
                return Error.OutOfMemory;
            };
            gop.key_ptr.* = key_dup;
        }
        gop.value_ptr.* = .{ .state = .active, .cluster_idx = idx };
    }

    /// Re-place an already-placed tenant onto `dest_cluster_id`. This is
    /// the directory half of a tenant move (Phase 4): the atomic flip that
    /// redirects the tenant's traffic to the destination cluster. Distinct
    /// from `assign` only in that it rejects an unknown tenant — a move
    /// presupposes an existing placement, so a missing one is a caller bug
    /// worth surfacing rather than silently creating. Safe from any thread.
    pub fn move(self: *Directory, tenant_id: []const u8, dest_cluster_id: []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.cluster_idx.get(dest_cluster_id) orelse return Error.UnknownCluster;
        const p = self.placements.getPtr(tenant_id) orelse return Error.UnknownTenant;
        p.* = .{ .state = .active, .cluster_idx = idx };
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
    /// an unknown tenant (a move presupposes an existing placement).
    pub fn beginMove(self: *Directory, tenant_id: []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.placements.getPtr(tenant_id) orelse return Error.UnknownTenant;
        p.state = .moving;
    }

    /// Revert a `beginMove` without changing placement — the move failed
    /// before the directory flip, so the tenant resumes on its source
    /// cluster. Rejects an unknown tenant.
    pub fn abortMove(self: *Directory, tenant_id: []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.placements.getPtr(tenant_id) orelse return Error.UnknownTenant;
        p.state = .active;
    }

    // ── Static config seeding ────────────────────────────────────────

    /// Seed clusters from a config string of the form
    /// `id=url1,url2,…;id=url;…` — each cluster's value is a comma-separated
    /// list of member node origins (one for a single-node cluster, N for a
    /// multi-node one). Whitespace around tokens is trimmed, a trailing `;`
    /// is allowed. The static-config path — the front door calls this once
    /// at startup from an env var. Each entry is `addCluster`'d (so a repeat
    /// id re-addresses). A back-compatible single-URL value is just a list
    /// of one.
    pub fn seedClusters(self: *Directory, config: []const u8) Error!void {
        var node_buf: [16][]const u8 = undefined;
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
