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
pub fn getOrOpenTenantBodies(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantBodies {
    return worker.tenant_bodies.getOrOpen(worker, inst);
}
