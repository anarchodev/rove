//! Per-tenant body-buffer lifecycle (open / free / lazy-open).
//!
//! Per `docs/readset-replication-plan.md` Phase 2b. Each worker holds
//! a `TenantMap(TenantBodies)` of in-memory body buffers keyed by
//! tenant id. Bodies arrive on the same worker thread that handles
//! H2 frames / curl_multi events; tenants are hash-routed to a single
//! worker (the kv-affinity worker), so per-worker per-tenant matches
//! the natural data ownership.
//!
//! Each `TenantBodies` owns:
//!   - a `BlobBackend` opened against the node's shared
//!     `blob_backend_cfg` with `{tenant_id}/readset-blobs/{batch_id}`
//!     key shape (same `openPerTenant` factory file-blobs and log-
//!     blobs use, just a different subdir).
//!   - a single-tenant `bodies_mod.BodyBuffer` that accepts appends
//!     and periodically flushes to the backend.
//!
//! Same file shape as `worker_log.zig`: every fn takes
//! `worker: anytype` so the structural-typed access to Worker's
//! fields keeps working without dragging the comptime Worker type
//! into this file.
//!
//! Slice 2b ships the lifecycle. Slices 2c (outbound) + 2d (inbound)
//! wire the actual append + flush call sites.

const std = @import("std");
const bodies_mod = @import("rove-bodies");
const blob_mod = @import("rove-blob");
const tenant_mod = @import("rove-tenant");

const worker_mod = @import("worker.zig");
const TenantBodies = worker_mod.TenantBodies;

pub fn openTenantBodies(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantBodies {
    const allocator = worker.allocator;

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    // Per-tenant S3 prefix:
    // `{key_prefix_base}{inst.id}/readset-blobs/w{worker_id}/`.
    // Mirrors files-server's "file-blobs" + log-server's "log-blobs"
    // shape, but appends the per-worker subdir so each worker's
    // `BodyBuffer` writes into its own namespace. Multiple workers
    // on the same node share a tenant via the kv-affinity hash, but
    // each maintains its own monotonic batch_id counter — without
    // the per-worker subdir, worker A and worker B both mint
    // batch_id=1 and PUT to the same key, which the backend rejects
    // with 409 OperationAborted (observed in body_gate_bench against
    // OVH). Same shape `worker_log.openTenantLog` uses by baking
    // `log_worker_id` into the upper 16 bits of `request_id`.
    var subdir_buf: [32]u8 = undefined;
    const subdir = std.fmt.bufPrint(
        &subdir_buf,
        "readset-blobs/w{d}",
        .{worker.log_worker_id},
    ) catch unreachable;
    var backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        worker.node.blob_backend_cfg,
        inst.id,
        subdir,
    );
    errdefer backend.deinit();

    const tb = try allocator.create(TenantBodies);
    errdefer allocator.destroy(tb);

    tb.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .backend = backend,
        .buffer = bodies_mod.BodyBuffer.init(allocator, .{
            // Defaults from the plan (100ms / 1MB); tests / operator
            // tuning can override later via WorkerConfig if needed.
            // Reference now_ns so the very first
            // `shouldFlushByTime(now)` check uses a stable baseline.
            .now_ns = @intCast(std.time.nanoTimestamp()),
        }),
    };
    return tb;
}

pub fn freeTenantBodies(allocator: std.mem.Allocator, tb: *TenantBodies) void {
    // Buffer holds the per-tenant in-RAM accumulator; flush all of
    // it on shutdown? Slice 2b chooses "drop on shutdown" — same
    // lossy posture as `worker_log.flushLogs`'s shutdown path (no
    // synchronous final flush; whatever's in RAM is best-effort).
    // The flush-on-shutdown variant comes when bodies actually
    // matter for the tape upload (post-slice 2c).
    tb.buffer.deinit();
    tb.backend.deinit();
    allocator.free(tb.instance_id);
    allocator.destroy(tb);
}

/// Lookup-or-lazy-open. Wraps `worker.tenant_bodies.getOrOpen` for
/// callers that only hold a worker pointer. Mirrors
/// `getOrOpenTenantLog` for the body-buffer map.
///
/// Thread-safe: callers from the worker main thread (append site)
/// and the log-flusher thread (flush-tick iteration) can both call
/// this. Acquires `worker.tenant_bodies_mu` around the map lookup
/// + grow path.
pub fn getOrOpenTenantBodies(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantBodies {
    worker.tenant_bodies_mu.lock();
    defer worker.tenant_bodies_mu.unlock();
    return worker.tenant_bodies.getOrOpen(worker, inst);
}

/// Iterate every tenant body buffer and flush any that hit a size
/// or time threshold. Called from the log-flusher thread on its
/// periodic tick (50ms cadence — shorter than the default 100ms
/// time threshold so a buffer with one byte still gets flushed
/// within ~150ms of arrival).
///
/// Snapshots the map's *pointer* values under
/// `worker.tenant_bodies_mu`, then drops the lock before walking
/// each buffer. Each buffer has its own internal mutex; flush
/// releases that mutex around the slow S3 PUT, so concurrent
/// appends on the worker thread aren't blocked.
///
/// Ready tenants are dispatched to `worker.body_flush_pool` so
/// multiple tenants can be PUT'd in parallel (per
/// [[project-s3-throughput-ceiling]]: 8 workers × 1-in-flight = 8
/// parallel PUTs node-wide saturated only ~30% of wire at 1 MB
/// batch size; per-worker fan-out across ready tenants is the
/// cheap fix). The pool's `submitAndWait` blocks until all flushes
/// in this tick complete — preserves the "at most one flush in
/// flight per tenant" invariant that `BodyBuffer.flush` relies on
/// (out-of-order completion would let `last_flushed_batch_id`
/// regress).
///
/// Best-effort: PUT failures are logged + skipped (same posture
/// as `worker_log.flushLogs`). The buffer continues with the next
/// batch on the next tick.
pub fn flushBodiesTick(worker: anytype) void {
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    // Snapshot the tenant-body pointers under the map lock. The
    // pointers are stable for the lifetime of the map entries
    // (closed only in `freeTenantBodies` on worker shutdown), so
    // we can drop the map lock before walking them.
    var snapshot: std.ArrayListUnmanaged(*TenantBodies) = .empty;
    defer snapshot.deinit(allocator);
    {
        worker.tenant_bodies_mu.lock();
        defer worker.tenant_bodies_mu.unlock();
        snapshot.ensureTotalCapacity(allocator, worker.tenant_bodies.map.count()) catch return;
        var it = worker.tenant_bodies.iterator();
        while (it.next()) |entry| {
            snapshot.appendAssumeCapacity(entry.value_ptr.*);
        }
    }

    // Pick the ones that actually need flushing this tick.
    var work: std.ArrayListUnmanaged(BodyFlushPool.WorkItem) = .empty;
    defer work.deinit(allocator);
    work.ensureTotalCapacity(allocator, snapshot.items.len) catch return;
    for (snapshot.items) |tb| {
        const should =
            tb.buffer.shouldFlushBySize() or
            tb.buffer.shouldFlushByTime(now_ns);
        if (should) work.appendAssumeCapacity(.{ .tb = tb, .now_ns = now_ns });
    }

    if (worker.body_flush_pool) |pool| {
        pool.submitAndWait(work.items);
    } else {
        // Pool absent during early init / some test fixtures —
        // serial fallback preserves prior behavior.
        for (work.items) |item| BodyFlushPool.doFlush(item);
    }
}

/// Per-worker thread pool that runs S3 PUTs in parallel across
/// tenants ready to flush. The flusher_thread submits the per-tick
/// batch via `submitAndWait` and blocks until every tenant in the
/// batch has completed (success or logged failure). Workers spin
/// on a condvar when idle; per-tick wake-up cost is one broadcast.
///
/// Size knob: `ROVE_BODY_FLUSH_POOL_SIZE` (default 4 per worker).
/// At 8 workers × 4 threads = 32 in-flight PUTs node-wide, which
/// matches the K=32 sweet spot from the OVH sweep (96% of wire at
/// 4 MB batches, no timeouts). Higher values eat EasyPool slots
/// (default pool = 64, shared with files-server + log-server) and
/// past K=64 latency explodes — see [[project-s3-throughput-ceiling]].
///
/// Invariant: caller must NOT overlap `submitAndWait` invocations
/// from different threads. The flusher_thread is the single caller
/// by construction.
pub const BodyFlushPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    mu: std.Thread.Mutex = .{},
    queue: std.ArrayListUnmanaged(WorkItem) = .empty,
    work_cond: std.Thread.Condition = .{},
    /// Items submitted in the current batch that haven't completed
    /// yet (queued + in-flight). `submitAndWait` blocks on
    /// `done_cond` until this reaches 0.
    in_flight: u32 = 0,
    done_cond: std.Thread.Condition = .{},
    shutdown_flag: std.atomic.Value(bool) = .init(false),

    pub const WorkItem = struct {
        tb: *TenantBodies,
        now_ns: i64,
    };

    /// Default pool size per worker. 4 × 8 workers = 32 = K=32
    /// from the OVH sweep, near-saturating at 4 MB batches.
    pub const DEFAULT_SIZE: u8 = 4;

    pub fn init(allocator: std.mem.Allocator, size: u8) !*BodyFlushPool {
        std.debug.assert(size > 0);
        const self = try allocator.create(BodyFlushPool);
        errdefer allocator.destroy(self);
        const threads = try allocator.alloc(std.Thread, size);
        errdefer allocator.free(threads);
        self.* = .{ .allocator = allocator, .threads = threads };
        var spawned: usize = 0;
        errdefer {
            self.shutdown_flag.store(true, .release);
            self.mu.lock();
            self.work_cond.broadcast();
            self.mu.unlock();
            for (threads[0..spawned]) |t| t.join();
        }
        for (threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{self});
            spawned += 1;
        }
        return self;
    }

    pub fn deinit(self: *BodyFlushPool) void {
        self.mu.lock();
        self.shutdown_flag.store(true, .release);
        self.work_cond.broadcast();
        self.mu.unlock();
        for (self.threads) |t| t.join();
        self.queue.deinit(self.allocator);
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    /// Enqueue `items` and block until all have completed. No-op
    /// when items is empty.
    pub fn submitAndWait(self: *BodyFlushPool, items: []const WorkItem) void {
        if (items.len == 0) return;

        self.mu.lock();
        self.queue.appendSlice(self.allocator, items) catch {
            // OOM growing the queue: fall back to inline serial
            // flush. Rare — queue size is bounded by ready tenants
            // per tick.
            self.mu.unlock();
            for (items) |item| doFlush(item);
            return;
        };
        self.in_flight = @intCast(items.len);
        self.work_cond.broadcast();
        while (self.in_flight > 0) {
            self.done_cond.wait(&self.mu);
        }
        self.mu.unlock();
    }

    fn workerLoop(self: *BodyFlushPool) void {
        while (true) {
            self.mu.lock();
            while (self.queue.items.len == 0 and !self.shutdown_flag.load(.acquire)) {
                self.work_cond.wait(&self.mu);
            }
            if (self.queue.items.len == 0 and self.shutdown_flag.load(.acquire)) {
                self.mu.unlock();
                return;
            }
            const item = self.queue.pop().?;
            self.mu.unlock();

            doFlush(item);

            self.mu.lock();
            self.in_flight -= 1;
            if (self.in_flight == 0) self.done_cond.signal();
            self.mu.unlock();
        }
    }

    pub fn doFlush(item: WorkItem) void {
        _ = item.tb.buffer.flush(item.tb.backend.blobStore(), item.now_ns) catch |err| {
            std.log.warn(
                "rove-js body-flusher: flush tenant={s}: {s}",
                .{ item.tb.instance_id, @errorName(err) },
            );
        };
    }
};

/// Read `ROVE_BODY_FLUSH_POOL_SIZE`; fall back to DEFAULT_SIZE on
/// missing / unparseable / zero.
pub fn poolSizeFromEnv() u8 {
    const env_str = std.posix.getenv("ROVE_BODY_FLUSH_POOL_SIZE") orelse return BodyFlushPool.DEFAULT_SIZE;
    const trimmed = std.mem.trim(u8, env_str, &std.ascii.whitespace);
    const n = std.fmt.parseInt(u8, trimmed, 10) catch {
        std.log.warn(
            "rove-js body-flusher: invalid ROVE_BODY_FLUSH_POOL_SIZE={s}, using {d}",
            .{ trimmed, BodyFlushPool.DEFAULT_SIZE },
        );
        return BodyFlushPool.DEFAULT_SIZE;
    };
    if (n == 0) {
        std.log.warn("rove-js body-flusher: ROVE_BODY_FLUSH_POOL_SIZE=0 invalid, using {d}", .{BodyFlushPool.DEFAULT_SIZE});
        return BodyFlushPool.DEFAULT_SIZE;
    }
    return n;
}
