//! Process-wide map of `tenant_id → released_deployment_id`.
//!
//! Phase 5.5(e) F2 replaced the worker's `refreshDeployments` polling
//! loop with a push: the dashboard / CLI POSTs to `/_system/release`
//! after every successful files-server deploy, the system handler
//! writes the new deployment id into this table, and each worker's
//! dispatch tick reads its own tenant_files_map and reloads any
//! tenant whose entry advanced.
//!
//! Single instance per process; every worker thread shares it. Cheap
//! enough that workers can read it on every tick — one map lookup per
//! tenant they have loaded. Mutex-guarded; contention is negligible
//! because writes only happen on /_system/release POST (admin-rate)
//! and reads are non-blocking lookups on hot tenants.
//!
//! Multi-node propagation is out of scope for this iteration. When
//! it lands, the same writeset that proposes envelope 0 from the
//! release POST will carry a sentinel that the apply path turns
//! into a per-node `set` on the local table.

const std = @import("std");

pub const ReleaseTable = struct {
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    /// Owns its key copies; values are deployment ids. Insert-only
    /// from the worker's perspective — entries are never removed
    /// (a tenant deletion would race with in-flight dispatch ticks).
    map: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn init(allocator: std.mem.Allocator) ReleaseTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReleaseTable) void {
        var it = self.map.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.map.deinit(self.allocator);
    }

    /// Record a release. Overwrites any older value; advancing dep_id
    /// monotonically is the caller's responsibility (out-of-order
    /// release calls on the same tenant are nonsense — files-server
    /// always returns a strictly-increasing dep_id).
    pub fn set(self: *ReleaseTable, tenant_id: []const u8, dep_id: u64) !void {
        self.mu.lock();
        defer self.mu.unlock();

        const gop = try self.map.getOrPut(self.allocator, tenant_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, tenant_id) catch |err| {
                _ = self.map.remove(tenant_id);
                return err;
            };
        }
        gop.value_ptr.* = dep_id;
    }

    /// Returns the latest released dep_id for `tenant_id`, or null if
    /// nothing has been released yet (the worker should leave its
    /// cached `current_deployment_id` alone — possibly 0, possibly a
    /// pre-existing value loaded at startup).
    pub fn get(self: *ReleaseTable, tenant_id: []const u8) ?u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.map.get(tenant_id);
    }

    /// Iterate (tenant_id, dep_id) pairs under the table's mutex.
    /// `visit` is called once per entry; the tenant_id slice is
    /// borrowed (valid only for the duration of the visit). The
    /// callback should keep work cheap — the mutex blocks
    /// concurrent `set` calls.
    ///
    /// Used by the dispatch tick's `applyPendingReleases` so it
    /// can iterate just the released tenants rather than scanning
    /// every loaded tenant (production.md #1.5 cleanup).
    pub fn visit(
        self: *ReleaseTable,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), tenant_id: []const u8, dep_id: u64) void,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            cb(ctx, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

test "set then get round-trips per tenant" {
    var rt = ReleaseTable.init(std.testing.allocator);
    defer rt.deinit();

    try rt.set("acme", 7);
    try rt.set("widgetco", 3);
    try rt.set("acme", 9);

    try std.testing.expectEqual(@as(?u64, 9), rt.get("acme"));
    try std.testing.expectEqual(@as(?u64, 3), rt.get("widgetco"));
    try std.testing.expectEqual(@as(?u64, null), rt.get("nobody"));
}
