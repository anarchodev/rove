//! Background deployment loader. The worker's request-handling
//! threads never do network I/O on the request hot path — every
//! manifest fetch, bytecode fetch, and config-mirror write that
//! a new deploy triggers happens here, on a dedicated thread.
//!
//! ## Model
//!
//! 1. A release POST commits `_deploy/current = N` to raft and
//!    returns 200 immediately. No fetch on the request thread.
//! 2. The dispatch tick's `applyPendingReleases` observes the new
//!    release pointer and ENQUEUES a load via `enqueue(tenant_id,
//!    dep_id)` instead of calling `reloadDeployment` inline.
//! 3. This thread picks up the queued load, calls `load_fn` (a
//!    worker-supplied callback), which is responsible for:
//!      - Fetching the manifest from files-server (HTTP).
//!      - Fetching all referenced bytecodes (eventually a
//!        curl_multi pool).
//!      - Mirroring `_config/*.json` rows into kv via raft
//!        propose.
//!      - Atomically swapping the tenant's `TenantFiles` state
//!        into the new deployment.
//! 4. When the load completes the dispatch tick observes the
//!    new `current_deployment_id` and serves requests against
//!    the loaded bytecodes. Eventually (future SSE) the
//!    completion gets pushed to the customer.
//!
//! ## Queue semantics
//!
//! Dedup by tenant id. If 16 release POSTs land for tenant T
//! with dep_ids 2, 3, 4, …, 17, the queue holds one entry: (T, 17).
//! Older dep_ids are obsolete — the customer already moved on.
//! `enqueue(T, N)` replaces any existing entry for T with the
//! higher of (existing, N).
//!
//! ## Threading
//!
//! Single loader thread per worker process. Adding parallelism
//! would require partitioning the queue (e.g. shard by tenant
//! hash) so concurrent loads target different `TenantFiles` —
//! easy to add later. The current single-thread loader is
//! enough to keep dispatch unblocked.

const std = @import("std");

pub const LoadFn = *const fn (
    worker_ctx: ?*anyopaque,
    tenant_id: []const u8,
    dep_id: u64,
) anyerror!void;

pub const DeploymentLoader = struct {
    allocator: std.mem.Allocator,
    worker_ctx: ?*anyopaque,
    load_fn: LoadFn,

    /// Pending loads, deduped by tenant id. The value is the
    /// highest dep_id observed for that tenant so far. Keys are
    /// allocator-owned copies of the tenant id.
    pending: std.StringHashMapUnmanaged(u64),
    pending_mutex: std.Thread.Mutex,

    /// Set by `enqueue` to wake the loader thread; cleared by
    /// the loader at the top of its work loop.
    wake: std.Thread.ResetEvent,

    /// Cooperative shutdown flag — set by `shutdown`, checked by
    /// the loader between drain passes.
    stop: std.atomic.Value(bool),

    /// The loader thread. Null between init and `start`, and
    /// between `shutdown` and `deinit`.
    thread: ?std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        worker_ctx: ?*anyopaque,
        load_fn: LoadFn,
    ) !*DeploymentLoader {
        const self = try allocator.create(DeploymentLoader);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .worker_ctx = worker_ctx,
            .load_fn = load_fn,
            .pending = .empty,
            .pending_mutex = .{},
            .wake = .{},
            .stop = std.atomic.Value(bool).init(false),
            .thread = null,
        };
        return self;
    }

    pub fn start(self: *DeploymentLoader) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn shutdown(self: *DeploymentLoader) void {
        self.stop.store(true, .release);
        self.wake.set();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *DeploymentLoader) void {
        // Caller must have shutdown by here. Free any pending
        // (loader missed them) entries' keys.
        var it = self.pending.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Enqueue a load. If `tenant_id` is already pending with
    /// a lower or equal `dep_id`, replace with this one. If
    /// already pending with a higher `dep_id`, no-op (the
    /// queued load is already at least as new as this one).
    pub fn enqueue(self: *DeploymentLoader, tenant_id: []const u8, dep_id: u64) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        if (self.pending.getPtr(tenant_id)) |slot| {
            if (dep_id > slot.*) slot.* = dep_id;
            // Don't wake — the loader will pick it up; updating
            // the slot in-place doesn't need a fresh wake signal
            // because the existing wake is enough.
            self.wake.set();
            return;
        }

        const key_copy = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(key_copy);
        try self.pending.put(self.allocator, key_copy, dep_id);
        self.wake.set();
    }

    /// Test-only: drain the queue synchronously on the calling
    /// thread. Useful for unit tests that don't want the
    /// background thread spinning. Not safe to call while the
    /// loader thread is running.
    pub fn drainSyncForTesting(self: *DeploymentLoader) void {
        std.debug.assert(self.thread == null);
        self.drainAll();
    }

    fn threadMain(self: *DeploymentLoader) void {
        while (!self.stop.load(.acquire)) {
            self.wake.wait();
            self.wake.reset();
            if (self.stop.load(.acquire)) break;
            self.drainAll();
        }
        // Final drain on shutdown — anything queued between the
        // last wake and `stop = true` still runs so we don't
        // lose a pending load.
        self.drainAll();
    }

    fn drainAll(self: *DeploymentLoader) void {
        while (self.popOne()) |entry| {
            self.load_fn(self.worker_ctx, entry.tenant_id, entry.dep_id) catch |err| {
                std.log.warn(
                    "deployment loader: tenant {s} dep {d} failed: {s}",
                    .{ entry.tenant_id, entry.dep_id, @errorName(err) },
                );
            };
            // `tenant_id` slice was duped from `enqueue`'s input at
            // insertion time — `popOne` transfers ownership to us.
            self.allocator.free(@constCast(entry.tenant_id));
        }
    }

    const PoppedEntry = struct {
        /// Owned by the caller — was duped from `enqueue`'s input
        /// at the time of insertion. Free with the loader's
        /// allocator after the load runs.
        tenant_id: []const u8,
        dep_id: u64,
    };

    fn popOne(self: *DeploymentLoader) ?PoppedEntry {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        var it = self.pending.iterator();
        const entry = it.next() orelse return null;
        const dep_id = entry.value_ptr.*;
        // fetchRemove returns the (still-owned) key we duped at
        // enqueue time. Transfer to caller.
        const kv = self.pending.fetchRemove(entry.key_ptr.*) orelse unreachable;
        return .{ .tenant_id = kv.key, .dep_id = dep_id };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

const TestCounter = struct {
    calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_dep_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn testLoadFn(ctx_opaque: ?*anyopaque, _: []const u8, dep_id: u64) anyerror!void {
    const ctx: *TestCounter = @ptrCast(@alignCast(ctx_opaque.?));
    _ = ctx.calls.fetchAdd(1, .acq_rel);
    ctx.last_dep_id.store(dep_id, .release);
}

test "enqueue + drainSync calls load_fn once per tenant" {
    var counter: TestCounter = .{};
    const loader = try DeploymentLoader.init(testing.allocator, &counter, testLoadFn);
    defer loader.deinit();

    try loader.enqueue("acme", 5);
    try loader.enqueue("beta", 7);
    loader.drainSyncForTesting();

    try testing.expectEqual(@as(u32, 2), counter.calls.load(.acquire));
}

test "enqueue dedups by tenant + keeps higher dep_id" {
    var counter: TestCounter = .{};
    const loader = try DeploymentLoader.init(testing.allocator, &counter, testLoadFn);
    defer loader.deinit();

    try loader.enqueue("acme", 5);
    try loader.enqueue("acme", 3); // lower — should NOT replace
    try loader.enqueue("acme", 9); // higher — replaces
    try loader.enqueue("acme", 7); // lower than 9 — no change

    loader.drainSyncForTesting();

    try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    try testing.expectEqual(@as(u64, 9), counter.last_dep_id.load(.acquire));
}

test "background thread drains queue + responds to shutdown" {
    var counter: TestCounter = .{};
    const loader = try DeploymentLoader.init(testing.allocator, &counter, testLoadFn);
    defer loader.deinit();

    try loader.start();
    try loader.enqueue("acme", 1);
    try loader.enqueue("beta", 2);

    // Wait a beat for the thread to process.
    var spins: u32 = 0;
    while (counter.calls.load(.acquire) < 2 and spins < 100) : (spins += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 2), counter.calls.load(.acquire));

    loader.shutdown();
}
