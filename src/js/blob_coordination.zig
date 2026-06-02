//! `BlobCoordination` — the process-global readset-blob write subsystem
//! for the rove-js worker node.
//!
//! Extracted from `NodeState` (worker.zig) as the second step of the
//! NodeState decomposition. Owns the singleton `BlobCoordinator` (one
//! drainer + K=32 executor pool), the shared `_pool/` S3 backend it
//! writes against, and the heap-owned raft-backed reservation context.
//! See `docs/streaming-model.md §7` Phases 3 + 5.
//!
//! All worker bodies > 16 KB (inbound + outbound fetch chunks) submit
//! to `coordinator`; the coordinator demuxes them into the one `_pool/`
//! backend by `BodyRef.(offset, len)`. `batch_id` reservation goes
//! through raft when a cluster handle is wired (production), or a local
//! atomic counter otherwise (single-process / test paths).
//!
//! Dependencies: `allocator`, the process `blob_mod.BackendConfig`, and
//! (optionally) the `kv.Cluster` handle for raft-backed reservation.

const std = @import("std");
const blob_mod = @import("rove-blob");
const kv_mod = @import("raft-kv");
const apply_mod = @import("apply.zig");

/// Heap-owned reservation provider context. Lives as long as the
/// `BlobCoordinator` does so the coord's refill thread can resolve the
/// cluster + raft handles after `start` returns. Reserves cluster-wide
/// `batch_id` blocks by advancing a pointer in `__root__.db` via an
/// envelope-2 root_writeset, committed through raft.
pub const CoordReservationCtx = struct {
    cluster: *kv_mod.Cluster,

    /// Key in `__root__.db` that holds the cluster-wide "next
    /// unreserved batch_id" pointer. Treated as 0 when absent; the
    /// reserve path advances it by the requested block size.
    const RESERVATION_KEY: []const u8 = "_system/coord_next_pool_batch";

    /// Total time we'll wait for a single reservation propose to
    /// commit. On timeout the coord's refill loop retries after a
    /// 100ms backoff.
    const RESERVATION_PROPOSE_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;

    pub fn reserveFn(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
        const self: *CoordReservationCtx = @ptrCast(@alignCast(ctx));
        const cluster = self.cluster;
        const root_store = cluster.openRoot() catch |err| return err;

        // Read the latest committed pointer. Absent → 0.
        const stored: u64 = blk: {
            const buf = root_store.get(RESERVATION_KEY) catch |err| switch (err) {
                error.NotFound => break :blk 0,
                else => return err,
            };
            defer cluster.allocator.free(buf);
            if (buf.len != 8) return error.MalformedReservationPointer;
            break :blk std.mem.readInt(u64, buf[0..8], .big);
        };

        // Floor at prev_end so back-to-back local refills can't
        // overlap even if the committed pointer is stale (rare —
        // would only happen if a previous propose failed to land).
        // Floor at 1 so batch_id 0 (NO_BATCH sentinel) is never
        // minted.
        const base = @max(stored, prev_end, @as(u64, 1));
        const new_end = base + count;

        // Build the writeset that bumps the pointer. The leader's
        // local applyRootWriteSet is leader-skip — we must apply
        // locally before proposing so the next refill on this node
        // (and any concurrent reader) sees the new value.
        var ws = kv_mod.WriteSet.init(cluster.allocator);
        defer ws.deinit();
        var new_end_be: [8]u8 = undefined;
        std.mem.writeInt(u64, &new_end_be, new_end, .big);
        try ws.addPut(RESERVATION_KEY, &new_end_be);

        // Local apply on the leader. On a follower this races — but
        // followers never reserve (no submissions arrive), so the
        // race window is empty in practice.
        try root_store.put(RESERVATION_KEY, &new_end_be);

        // Replicate via envelope-2 root_writeset, wait for commit.
        const ws_bytes = try ws.encode(cluster.allocator);
        defer cluster.allocator.free(ws_bytes);
        const env = try apply_mod.encodeRootWriteSetEnvelope(cluster.allocator, ws_bytes);
        defer cluster.allocator.free(env);

        _ = cluster.proposeAndWait(env, RESERVATION_PROPOSE_TIMEOUT_NS) catch |err| switch (err) {
            error.NotLeader => return error.NotLeader,
            error.ProposalTimedOut => return error.ProposalTimedOut,
            else => return err,
        };

        return new_end;
    }
};

pub const BlobCoordination = struct {
    allocator: std.mem.Allocator,

    /// Process-wide blob backend config (copied from `NodeState`; the
    /// borrowed slices outlive both). Used by `start` to open the
    /// `_pool/` backend at the same store every other per-tenant
    /// backend on the node points at.
    blob_backend_cfg: blob_mod.BackendConfig,

    /// `kv.Cluster` handle — borrowed; owned by `main.zig`. Threaded
    /// in via `setCluster` after `init` so `start` can install the
    /// raft-backed reservation provider.
    cluster: ?*kv_mod.Cluster = null,

    /// `docs/streaming-model.md §7` Phase 3: process-global write
    /// coordinator for readset blob PUTs. Replaces the per-worker
    /// `BodyFlushPool`. All worker bodies (inbound + outbound fetch
    /// chunks > 16 KB) submit here; the coord runs one drainer + K=32
    /// executor pool. Lazy init via `start` after the node is wired +
    /// `num_workers` is known.
    coordinator: ?*blob_mod.BlobCoordinator = null,

    /// `docs/streaming-model.md §7` Phase 5: backend that owns the
    /// cross-tenant `_pool/` prefix the coordinator writes against.
    /// Opened once in `start`, deinit'd in `deinit` (after the coord
    /// itself shuts down + joins).
    pool_backend: ?blob_mod.BlobBackend = null,

    /// `docs/streaming-model.md §7` Phase 5: heap-owned reservation
    /// provider context. Lives as long as `coordinator` does so the
    /// coord's refill thread can resolve cluster + raft handles after
    /// `start` returns.
    reservation_ctx: ?*CoordReservationCtx = null,

    pub fn init(
        allocator: std.mem.Allocator,
        blob_backend_cfg: blob_mod.BackendConfig,
    ) BlobCoordination {
        return .{ .allocator = allocator, .blob_backend_cfg = blob_backend_cfg };
    }

    /// Wire the cluster handle so `start` can install the raft-backed
    /// reservation provider. MUST be called before `start`; once the
    /// coord is running this is a no-op (the reservation is captured at
    /// coord init).
    pub fn setCluster(self: *BlobCoordination, cluster: *kv_mod.Cluster) void {
        self.cluster = cluster;
    }

    /// `docs/streaming-model.md §7` Phase 3 + Phase 5: spawn the
    /// process-global blob coordinator. Idempotent. Called once from
    /// `main.zig` after the node is wired + `num_workers` is known
    /// (the coord allocates per-worker queues up front).
    ///
    /// Phase 5: opens a single shared S3 backend at the
    /// `{key_prefix_base}_pool/` prefix; submissions land in that one
    /// pool, demuxed by `BodyRef.(offset, len)`. When `cluster` is
    /// non-null the coord uses raft-backed `batch_id` reservation
    /// (`_system/coord_next_pool_batch`); when null the coord falls
    /// back to a local atomic counter (single-process / test paths).
    pub fn start(self: *BlobCoordination, worker_count: u8) !void {
        if (self.coordinator != null) return;

        // Open the pool backend — one BlobBackend, prefix
        // `{key_prefix_base}_pool/`, identical layout across leader +
        // followers. We thread the prefix through `s3.Config` directly
        // so the existing `openS3` factory can produce it without
        // per-tenant gymnastics.
        const cfg = self.blob_backend_cfg;
        const pool_prefix = try std.fmt.allocPrint(
            self.allocator,
            "{s}_pool/",
            .{cfg.key_prefix_base},
        );
        defer self.allocator.free(pool_prefix);

        var pool_backend = try blob_mod.BlobBackend.openS3(self.allocator, .{
            .endpoint = cfg.endpoint,
            .region = cfg.region,
            .bucket = cfg.bucket,
            .key_prefix = pool_prefix,
            .access_key = cfg.access_key,
            .secret_key = cfg.secret_key,
            .use_tls = cfg.use_tls,
        });
        errdefer pool_backend.deinit();
        self.pool_backend = pool_backend;

        // Build the reservation provider only when a cluster handle is
        // wired in (production path). Without it the coord falls back to
        // a local atomic counter — fine for tests, not safe across
        // leader switches in a multi-node deploy.
        var reservation: ?blob_mod.coordinator.ReservationProvider = null;
        var res_ctx: ?*CoordReservationCtx = null;
        if (self.cluster) |cl| {
            const ctx = try self.allocator.create(CoordReservationCtx);
            errdefer self.allocator.destroy(ctx);
            ctx.* = .{ .cluster = cl };
            res_ctx = ctx;
            reservation = .{
                .ctx = ctx,
                .reserveFn = CoordReservationCtx.reserveFn,
            };
        }

        const coord = blob_mod.BlobCoordinator.init(
            self.allocator,
            self.pool_backend.?.blobStore(),
            .{
                .worker_count = worker_count,
                .reservation = reservation,
            },
        ) catch |err| {
            if (res_ctx) |c| self.allocator.destroy(c);
            return err;
        };
        self.coordinator = coord;
        self.reservation_ctx = res_ctx;
    }

    /// Tear down in reverse start order: stop + join the coordinator
    /// (its refill thread reaches the reservation ctx + pool backend),
    /// then the pool backend, then the reservation ctx. The caller
    /// MUST have already shut down any producer (e.g. the FetchEngine)
    /// that reads `coordinator` before invoking this.
    pub fn deinit(self: *BlobCoordination) void {
        if (self.coordinator) |c| {
            c.deinit();
            self.coordinator = null;
        }
        if (self.pool_backend) |*be| {
            be.deinit();
            self.pool_backend = null;
        }
        if (self.reservation_ctx) |ctx| {
            self.allocator.destroy(ctx);
            self.reservation_ctx = null;
        }
    }
};
