// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Background deployment loader. The worker's request-handling
//! threads never do network I/O on the request hot path — every
//! manifest fetch, bytecode fetch, and config-mirror write that
//! a new deploy triggers happens here, on a dedicated thread.
//!
//! ## Model
//!
//! 1. A release POST commits `_deploy/current = N` to raft and
//!    returns 200 immediately. No fetch on the request thread.
//! 2. The proposing trampoline (`releasePublishTrampoline` for
//!    `platform.releases.publish`, `handleRelease` for the
//!    bootstrap-only `/_system/release` route) calls `enqueue`
//!    inline. On follower nodes, `apply.zig`'s envelope-0 apply
//!    detects `_deploy/current` writes and enqueues there too,
//!    closing the cross-node propagation loop without an
//!    in-memory ReleaseTable.
//! 3. This thread picks up the queued load, calls `load_fn` (a
//!    worker-supplied callback), which is responsible for:
//!      - Fetching the manifest from the deployment manifest backend.
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

/// What failed, in the callback's own words, for the loader's failure line.
///
/// A load failure is reported HERE and nowhere else: the release POST has
/// already returned 200 (see the model above), so this line and
/// `failures_total` are the only signal a deploy did not take effect. An
/// error name alone ("SubscriptionSpecMissingField") does not say WHICH
/// subscription or which field, and the callback cannot log it itself
/// without duplicating what this line already reports.
///
/// Fixed buffer, copied — NOT a borrowed slice. The interesting text
/// (subscription names, spec fields) points into a manifest the callback
/// frees while unwinding, so a slice would dangle by the time it is read.
pub const Detail = struct {
    /// Sized for the longest message plus a long subscription name: the
    /// retired-kind recipes run past 290 bytes on their own.
    buf: [512]u8 = undefined,
    len: usize = 0,

    /// Record the detail, truncating rather than failing — a diagnostic must
    /// never be the reason an error path takes a different turn.
    ///
    /// `getWritten` reports exactly the bytes written, so the length can
    /// never exceed them. `bufPrint` would report the overflow without
    /// saying how much it wrote, leaving the recovery path to assume the
    /// whole buffer was filled — true only as long as every formatter
    /// writes partially before giving up, which is not a documented
    /// guarantee. This does not depend on it.
    pub fn set(self: *Detail, comptime fmt: []const u8, args: anytype) void {
        var stream = std.io.fixedBufferStream(&self.buf);
        stream.writer().print(fmt, args) catch {};
        self.len = stream.getWritten().len;
    }

    pub fn slice(self: *const Detail) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const LoadFn = *const fn (
    worker_ctx: ?*anyopaque,
    tenant_id: []const u8,
    dep_id: u64,
    detail: *Detail,
) anyerror!void;

pub const DeploymentLoader = struct {
    allocator: std.mem.Allocator,
    worker_ctx: ?*anyopaque,
    load_fn: LoadFn,

    /// Pending loads, deduped by tenant id. The value is the
    /// highest dep_id observed for that tenant so far. Keys are
    /// allocator-owned copies of the tenant id.
    pending: std.StringHashMapUnmanaged(u64),
    /// Failed loads awaiting retry, deduped by tenant id. A load does
    /// remote S3 I/O, so transient failures are expected — a dropped
    /// failure would leave the tenant serving 503 (no prior snapshot)
    /// or silently pinned to the previous deployment until something
    /// else re-enqueues. Retries back off (1s, 5s, then every 30s) and
    /// never give up: a deterministic failure (e.g. a corrupt manifest
    /// object) stays loudly visible in the log + metrics and self-heals
    /// the moment the input is fixed. A fresh `enqueue` for the tenant
    /// supersedes its retry entry (highest dep_id wins). Guarded by
    /// `pending_mutex`.
    retrying: std.StringHashMapUnmanaged(Retry),
    pending_mutex: std.Thread.Mutex,

    /// Total failed load attempts since process start (monotonic; the
    /// `deployment_load_failures_total` metric). Atomic — read by the
    /// worker thread's metrics render while this thread writes.
    failures_total: std.atomic.Value(u64),
    /// Tenants currently in the retry set (the
    /// `deployment_loads_retrying` gauge): >0 means some tenant's
    /// released deployment is NOT what's serving. Mirrors
    /// `retrying.count()` so the metrics render needs no lock.
    retrying_gauge: std.atomic.Value(u64),

    /// Backoff unit in ms — the retry ladder is unit×1, ×5, then ×30
    /// forever. Tests shrink it so a retry becomes due immediately.
    retry_unit_ms: u64,

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
            .retrying = .empty,
            .pending_mutex = .{},
            .failures_total = std.atomic.Value(u64).init(0),
            .retrying_gauge = std.atomic.Value(u64).init(0),
            .retry_unit_ms = 1000,
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
        var rit = self.retrying.iterator();
        while (rit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.retrying.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Enqueue a load. If `tenant_id` is already pending with
    /// a lower or equal `dep_id`, replace with this one. If
    /// already pending with a higher `dep_id`, no-op (the
    /// queued load is already at least as new as this one).
    pub fn enqueue(self: *DeploymentLoader, tenant_id: []const u8, dep_id: u64) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        // A fresh enqueue supersedes any parked retry for the tenant:
        // fold its dep_id in (highest wins) and load NOW — the retry
        // backoff was for the failed attempt, not the new release.
        var effective = dep_id;
        if (self.retrying.fetchRemove(tenant_id)) |old| {
            self.allocator.free(@constCast(old.key));
            if (old.value.dep_id > effective) effective = old.value.dep_id;
            self.retrying_gauge.store(self.retrying.count(), .monotonic);
        }

        if (self.pending.getPtr(tenant_id)) |slot| {
            if (effective > slot.*) slot.* = effective;
            // Don't wake — the loader will pick it up; updating
            // the slot in-place doesn't need a fresh wake signal
            // because the existing wake is enough.
            self.wake.set();
            return;
        }

        const key_copy = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(key_copy);
        try self.pending.put(self.allocator, key_copy, effective);
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
            // With retries parked, sleep only until the earliest one is
            // due (an enqueue's wake still interrupts early); otherwise
            // block until woken.
            if (self.earliestRetryDelayNs()) |delay_ns| {
                self.wake.timedWait(delay_ns) catch {};
            } else {
                self.wake.wait();
            }
            self.wake.reset();
            if (self.stop.load(.acquire)) break;
            self.drainAll();
        }
        // Final drain on shutdown — anything queued between the
        // last wake and `stop = true` still runs so we don't
        // lose a pending load. (Parked retries are deliberately NOT
        // drained: they already failed once and restart re-enqueues
        // every tenant's current deployment anyway.)
        self.drainAll();
    }

    /// Nanoseconds until the earliest parked retry is due (0 if one is
    /// already due), or null when nothing is parked.
    fn earliestRetryDelayNs(self: *DeploymentLoader) ?u64 {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        var min_due: ?i64 = null;
        var it = self.retrying.iterator();
        while (it.next()) |e| {
            if (min_due == null or e.value_ptr.due_ms < min_due.?) min_due = e.value_ptr.due_ms;
        }
        const due = min_due orelse return null;
        const now = std.time.milliTimestamp();
        if (due <= now) return 0;
        return @as(u64, @intCast(due - now)) * std.time.ns_per_ms;
    }

    fn retryDelayMs(self: *const DeploymentLoader, attempt: u32) u64 {
        // 1×, 5×, then 30× the unit forever — bounded backoff,
        // unbounded attempts (see the `retrying` field doc).
        return self.retry_unit_ms * @as(u64, switch (attempt) {
            0 => 1,
            1 => 5,
            else => 30,
        });
    }

    fn drainAll(self: *DeploymentLoader) void {
        while (self.popOne()) |entry| {
            var detail: Detail = .{};
            self.load_fn(self.worker_ctx, entry.tenant_id, entry.dep_id, &detail) catch |err| {
                if (detail.len > 0) {
                    std.log.warn(
                        "deployment loader: tenant {s} dep {d} failed (attempt {d}): {s} — {s}",
                        .{ entry.tenant_id, entry.dep_id, entry.attempt + 1, @errorName(err), detail.slice() },
                    );
                } else {
                    std.log.warn(
                        "deployment loader: tenant {s} dep {d} failed (attempt {d}): {s}",
                        .{ entry.tenant_id, entry.dep_id, entry.attempt + 1, @errorName(err) },
                    );
                }
                _ = self.failures_total.fetchAdd(1, .monotonic);
                self.parkRetry(entry) catch |park_err| std.log.warn(
                    "deployment loader: tenant {s} retry park failed: {s} — load dropped until the next release/restart",
                    .{ entry.tenant_id, @errorName(park_err) },
                );
                continue;
            };
            // `tenant_id` slice was duped from `enqueue`'s input at
            // insertion time — `popOne` transfers ownership to us.
            self.allocator.free(@constCast(entry.tenant_id));
        }
    }

    /// Park a failed load for a later attempt. Takes ownership of
    /// `entry.tenant_id` (freed here on every path). If a NEWER load
    /// for the tenant was enqueued while this one ran, drop instead —
    /// the pending entry supersedes.
    fn parkRetry(self: *DeploymentLoader, entry: PoppedEntry) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        errdefer self.allocator.free(@constCast(entry.tenant_id));

        if (self.pending.contains(entry.tenant_id)) {
            self.allocator.free(@constCast(entry.tenant_id));
            return;
        }
        const retry: Retry = .{
            .dep_id = entry.dep_id,
            .attempt = entry.attempt + 1,
            .due_ms = std.time.milliTimestamp() + @as(i64, @intCast(self.retryDelayMs(entry.attempt))),
        };
        if (self.retrying.getPtr(entry.tenant_id)) |slot| {
            // Already parked (shouldn't happen — popOne removed it) —
            // keep the higher dep, refresh the clock.
            if (retry.dep_id > slot.dep_id) slot.dep_id = retry.dep_id;
            slot.attempt = retry.attempt;
            slot.due_ms = retry.due_ms;
            self.allocator.free(@constCast(entry.tenant_id));
        } else {
            try self.retrying.put(self.allocator, entry.tenant_id, retry);
        }
        self.retrying_gauge.store(self.retrying.count(), .monotonic);
    }

    const Retry = struct {
        dep_id: u64,
        /// Failed attempts so far (drives the backoff rung).
        attempt: u32,
        /// Wall-clock ms when this entry becomes due.
        due_ms: i64,
    };

    const PoppedEntry = struct {
        /// Owned by the caller — was duped from `enqueue`'s input
        /// at the time of insertion. Free with the loader's
        /// allocator after the load runs.
        tenant_id: []const u8,
        dep_id: u64,
        /// Failed attempts BEFORE this one (0 for a fresh enqueue).
        attempt: u32 = 0,
    };

    fn popOne(self: *DeploymentLoader) ?PoppedEntry {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        var it = self.pending.iterator();
        if (it.next()) |entry| {
            const dep_id = entry.value_ptr.*;
            // fetchRemove returns the (still-owned) key we duped at
            // enqueue time. Transfer to caller.
            const kv = self.pending.fetchRemove(entry.key_ptr.*) orelse unreachable;
            return .{ .tenant_id = kv.key, .dep_id = dep_id };
        }

        // No fresh work — pick up a due retry.
        const now = std.time.milliTimestamp();
        var rit = self.retrying.iterator();
        while (rit.next()) |e| {
            if (e.value_ptr.due_ms > now) continue;
            const r = e.value_ptr.*;
            const kv = self.retrying.fetchRemove(e.key_ptr.*) orelse unreachable;
            self.retrying_gauge.store(self.retrying.count(), .monotonic);
            return .{ .tenant_id = kv.key, .dep_id = r.dep_id, .attempt = r.attempt };
        }
        return null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

const TestCounter = struct {
    calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_dep_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn testLoadFn(ctx_opaque: ?*anyopaque, _: []const u8, dep_id: u64, _: *Detail) anyerror!void {
    const ctx: *TestCounter = @ptrCast(@alignCast(ctx_opaque.?));
    _ = ctx.calls.fetchAdd(1, .acq_rel);
    ctx.last_dep_id.store(dep_id, .release);
}

test "Detail: records, and truncates to what fit rather than undefined bytes" {
    var d: Detail = .{};
    try testing.expectEqualStrings("", d.slice());

    d.set("subscription `{s}` kind=kv missing `{s}` field", .{ "orders", "prefix" });
    try testing.expectEqualStrings(
        "subscription `orders` kind=kv missing `prefix` field",
        d.slice(),
    );

    // Overflow must yield a SHORT message, never `len` running past what was
    // actually written — the loader logs `slice()` verbatim, so a too-long
    // length would print the buffer's undefined tail. The retired-kind
    // recipes are ~291 bytes, so this path is reachable in production, not
    // theoretical.
    var big: Detail = .{};
    const long = "x" ** 900;
    big.set("{s}", .{long});
    try testing.expectEqual(big.buf.len, big.len);
    try testing.expectEqualStrings(long[0..big.buf.len], big.slice());

    // Every byte reported is a byte written — asserted for an overflow on a
    // LATER segment, where a length taken from the buffer's capacity rather
    // than from the write would be reporting bytes no formatter promised to
    // have filled.
    var edge: Detail = .{};
    const pad = "y" ** 510;
    edge.set("{s}{d}", .{ pad, 12345 });
    try testing.expect(edge.len <= edge.buf.len);
    for (edge.slice(), 0..) |c, i| {
        if (i < pad.len) {
            try testing.expectEqual(@as(u8, 'y'), c);
        } else {
            try testing.expect(c >= '0' and c <= '9');
        }
    }

    // The longest real message fits without truncation.
    var recipe: Detail = .{};
    recipe.set(
        "subscription `{s}` kind=cron is retired — register recurrence from any " ++
            "handler activation instead: `cron(\"*/1 * * * *\", \"module/path\")` (crontab, durable) " ++
            "or a self-re-arming `schedule({{in: ms}}, ..., {{key}})` for sub-minute intervals; " ++
            "registrations are idempotent by key and survive deploys",
        .{"a-subscription-with-a-fairly-long-name"},
    );
    try testing.expect(recipe.len < recipe.buf.len);
    try testing.expect(std.mem.endsWith(u8, recipe.slice(), "survive deploys"));
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

const FlakyCounter = struct {
    calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Attempts that fail before one succeeds.
    fail_first: u32,
};

fn flakyLoadFn(ctx_opaque: ?*anyopaque, _: []const u8, _: u64, _: *Detail) anyerror!void {
    const ctx: *FlakyCounter = @ptrCast(@alignCast(ctx_opaque.?));
    const n = ctx.calls.fetchAdd(1, .acq_rel);
    if (n < ctx.fail_first) return error.TransientFetchFailure;
}

test "failed load parks on retry + eventually succeeds" {
    var counter: FlakyCounter = .{ .fail_first = 2 };
    const loader = try DeploymentLoader.init(testing.allocator, &counter, flakyLoadFn);
    defer loader.deinit();
    loader.retry_unit_ms = 0; // retries due immediately

    try loader.enqueue("acme", 5);

    // Attempt 1 fails → parked (drainAll stops when nothing is due,
    // but unit=0 makes the retry due at once, so one drain runs the
    // whole ladder: fail, fail, succeed).
    loader.drainSyncForTesting();
    try testing.expectEqual(@as(u32, 3), counter.calls.load(.acquire));
    try testing.expectEqual(@as(u64, 2), loader.failures_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), loader.retrying_gauge.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), loader.retrying.count());
}

test "retry with future due time stays parked; fresh enqueue supersedes it" {
    var counter: FlakyCounter = .{ .fail_first = 1 };
    const loader = try DeploymentLoader.init(testing.allocator, &counter, flakyLoadFn);
    defer loader.deinit();
    // Default unit: first retry due in 1s — far enough to observe the
    // parked state without racing the clock.

    try loader.enqueue("acme", 5);
    loader.drainSyncForTesting();
    try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    try testing.expectEqual(@as(u64, 1), loader.retrying_gauge.load(.monotonic));

    // Not due → another drain is a no-op.
    loader.drainSyncForTesting();
    try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));

    // A fresh release supersedes the parked retry (higher dep wins,
    // loads immediately — no backoff for new work).
    try loader.enqueue("acme", 9);
    try testing.expectEqual(@as(u64, 0), loader.retrying_gauge.load(.monotonic));
    loader.drainSyncForTesting();
    try testing.expectEqual(@as(u32, 2), counter.calls.load(.acquire));
    try testing.expectEqual(@as(usize, 0), loader.retrying.count());
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
