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

    // Per-tenant S3 prefix: `{key_prefix_base}{inst.id}/readset-blobs/`.
    // Mirrors files-server's "file-blobs" + log-server's "log-blobs"
    // shape so the per-tenant on-disk / in-bucket layout is uniform.
    var backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        worker.node.blob_backend_cfg,
        inst.id,
        "readset-blobs",
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

    for (snapshot.items) |tb| {
        const should =
            tb.buffer.shouldFlushBySize() or
            tb.buffer.shouldFlushByTime(now_ns);
        if (!should) continue;
        _ = tb.buffer.flush(tb.backend.blobStore(), now_ns) catch |err| {
            std.log.warn(
                "rove-js body-flusher: flush tenant={s}: {s}",
                .{ tb.instance_id, @errorName(err) },
            );
        };
    }
}
