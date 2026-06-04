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

// V2 Phase 2c: the raft-backed cross-tenant `batch_id` reservation
// (`CoordReservationCtx`, which proposed an envelope-2 root_writeset
// through `kv.Cluster.proposeAndWait`) is removed. Single-node V2 uses
// the coordinator's local atomic counter, which is correct for one node.
// Multi-node (Phase 5) reintroduces cluster-wide reservation through the
// bridge's `__root__` group — see docs/streaming-model.md §7 Phase 5.

pub const BlobCoordination = struct {
    allocator: std.mem.Allocator,

    /// Process-wide blob backend config (copied from `NodeState`; the
    /// borrowed slices outlive both). Used by `start` to open the
    /// `_pool/` backend at the same store every other per-tenant
    /// backend on the node points at.
    blob_backend_cfg: blob_mod.BackendConfig,

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

    pub fn init(
        allocator: std.mem.Allocator,
        blob_backend_cfg: blob_mod.BackendConfig,
    ) BlobCoordination {
        return .{ .allocator = allocator, .blob_backend_cfg = blob_backend_cfg };
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

        // V2 Phase 2c single-node: local atomic-counter reservation
        // (`reservation = null`). The cross-tenant raft-backed reservation
        // returns in Phase 5 (multi-node) via the bridge's `__root__`
        // group — see the file header.
        const coord = try blob_mod.BlobCoordinator.init(
            self.allocator,
            self.pool_backend.?.blobStore(),
            .{
                .worker_count = worker_count,
                .reservation = null,
            },
        );
        self.coordinator = coord;
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
    }
};
