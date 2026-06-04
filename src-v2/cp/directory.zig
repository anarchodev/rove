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

/// Where a cluster lives, from the front door's point of view. `base_url`
/// is the origin the front door forwards a tenant's request to (e.g.
/// `http://127.0.0.1:18091`); `id` is the logical name used in placement
/// config and move commands. Both slices point into the `Directory`'s
/// owned storage and are stable for the directory's lifetime, so a
/// `ClusterRef` returned by value is safe to hold past the lock.
pub const ClusterRef = struct {
    id: []const u8,
    base_url: []const u8,
};

/// A tenant's placement. Phase 3 has only `active`; Phase 4 adds e.g.
/// `moving` (hold requests) — see file header. Kept as a struct (not a
/// bare cluster id) so that added state rides alongside the cluster
/// without touching `clusterFor`'s callers.
pub const Placement = struct {
    state: State = .active,
    /// Index into `clusters` (the cluster currently serving this tenant).
    cluster_idx: usize,

    pub const State = enum { active };
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
        base_url: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Directory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Directory) void {
        const a = self.allocator;
        for (self.clusters.items) |c| {
            a.free(c.id);
            a.free(c.base_url);
        }
        self.clusters.deinit(a);
        self.cluster_idx.deinit(a);
        // `placements` keys are owned dups (see `assign`).
        var it = self.placements.keyIterator();
        while (it.next()) |k| a.free(k.*);
        self.placements.deinit(a);
    }

    // ── Cluster registry (control plane) ─────────────────────────────

    /// Register a cluster the directory can place tenants on. Idempotent
    /// on `id` — a repeat call with the same id updates its `base_url`
    /// (re-addressing a cluster) and keeps the index stable. Safe from any
    /// thread.
    pub fn addCluster(self: *Directory, id: []const u8, base_url: []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.addClusterLocked(id, base_url);
    }

    fn addClusterLocked(self: *Directory, id: []const u8, base_url: []const u8) Error!void {
        const a = self.allocator;
        if (self.cluster_idx.get(id)) |idx| {
            // Re-address in place; the id slice (and its index) stay put.
            const new_url = a.dupe(u8, base_url) catch return Error.OutOfMemory;
            a.free(self.clusters.items[idx].base_url);
            self.clusters.items[idx].base_url = new_url;
            return;
        }
        const id_dup = a.dupe(u8, id) catch return Error.OutOfMemory;
        errdefer a.free(id_dup);
        const url_dup = a.dupe(u8, base_url) catch return Error.OutOfMemory;
        errdefer a.free(url_dup);
        const idx = self.clusters.items.len;
        self.clusters.append(a, .{ .id = id_dup, .base_url = url_dup }) catch return Error.OutOfMemory;
        errdefer _ = self.clusters.pop();
        // Key the index on the owned id dup so it outlives the caller's slice.
        self.cluster_idx.put(a, id_dup, idx) catch return Error.OutOfMemory;
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
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.placements.get(tenant_id) orelse return null;
        const c = self.clusters.items[p.cluster_idx];
        return .{ .id = c.id, .base_url = c.base_url };
    }

    // ── Static config seeding ────────────────────────────────────────

    /// Seed clusters from a config string of the form
    /// `id=base_url;id=base_url;…` (whitespace around tokens trimmed,
    /// trailing `;` allowed). The Phase-3 "dead simple static config" path
    /// — the front door calls this once at startup from an env var. Each
    /// entry is `addCluster`'d (so a repeat id re-addresses).
    pub fn seedClusters(self: *Directory, config: []const u8) Error!void {
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return Error.BadConfig;
            const id = std.mem.trim(u8, entry[0..eq], " \t");
            const url = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (id.len == 0 or url.len == 0) return Error.BadConfig;
            try self.addCluster(id, url);
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

test "directory: addCluster + assign + clusterFor round-trips" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    try dir.addCluster("cluster-1", "http://127.0.0.1:18091");
    try dir.addCluster("cluster-2", "http://127.0.0.1:18092");
    try dir.assign("alice", "cluster-1");
    try dir.assign("bob", "cluster-2");

    const a = dir.clusterFor("alice").?;
    try testing.expectEqualStrings("cluster-1", a.id);
    try testing.expectEqualStrings("http://127.0.0.1:18091", a.base_url);
    const b = dir.clusterFor("bob").?;
    try testing.expectEqualStrings("cluster-2", b.id);

    try testing.expect(dir.clusterFor("nobody") == null);
}

test "directory: move flips placement (the Phase-4 seam)" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try dir.addCluster("c1", "http://h:1");
    try dir.addCluster("c2", "http://h:2");
    try dir.assign("t", "c1");

    try testing.expectEqualStrings("c1", dir.clusterFor("t").?.id);
    try dir.move("t", "c2");
    try testing.expectEqualStrings("c2", dir.clusterFor("t").?.id);
    // base_url follows the new cluster.
    try testing.expectEqualStrings("http://h:2", dir.clusterFor("t").?.base_url);
}

test "directory: error surfaces — unknown cluster / unknown tenant" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try dir.addCluster("c1", "http://h:1");

    try testing.expectError(error.UnknownCluster, dir.assign("t", "nope"));
    try testing.expectError(error.UnknownTenant, dir.move("ghost", "c1"));
    try dir.assign("t", "c1");
    try testing.expectError(error.UnknownCluster, dir.move("t", "nope"));
}

test "directory: assign is idempotent / re-placeable; addCluster re-addresses" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    try dir.addCluster("c1", "http://h:1");
    try dir.addCluster("c2", "http://h:2");

    try dir.assign("t", "c1");
    try dir.assign("t", "c1"); // idempotent
    try testing.expectEqualStrings("c1", dir.clusterFor("t").?.id);
    try dir.assign("t", "c2"); // re-place via assign
    try testing.expectEqualStrings("c2", dir.clusterFor("t").?.id);

    // Re-address c1 in place; existing placements pointing at it follow.
    try dir.assign("u", "c1");
    try dir.addCluster("c1", "http://newhost:9");
    try testing.expectEqualStrings("http://newhost:9", dir.clusterFor("u").?.base_url);
}

test "directory: seedClusters + seedPlacements parse static config" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    try dir.seedClusters("cluster-1=http://127.0.0.1:18091; cluster-2=http://127.0.0.1:18092 ;");
    try dir.seedPlacements("alice=cluster-1; bob=cluster-2");

    try testing.expectEqualStrings("http://127.0.0.1:18091", dir.clusterFor("alice").?.base_url);
    try testing.expectEqualStrings("cluster-2", dir.clusterFor("bob").?.id);

    try testing.expectError(error.BadConfig, dir.seedClusters("missing-equals"));
    try testing.expectError(error.BadConfig, dir.seedClusters("=http://nohost"));
    try testing.expectError(error.UnknownCluster, dir.seedPlacements("x=ghost-cluster"));
}
