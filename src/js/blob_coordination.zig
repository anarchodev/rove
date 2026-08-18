// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `BlobCoordination` — the process-global readset-blob write subsystem
//! for the rove-js worker node.
//!
//! Owns the singleton `BlobCoordinator` (one drainer + K=32 executor
//! pool) and the shared `_pool/` S3 backend it writes against.
//! See the blob coordinator / chunk spool (`docs/architecture/routing-and-ingress.md`).
//!
//! All worker bodies > 16 KB (inbound + outbound fetch chunks) submit
//! to `coordinator`; the coordinator demuxes them out of the one
//! `_pool/` backend by the extent a `BodyRef` names. Nothing here
//! coordinates object names across nodes: a pool object is named by its
//! own content, so two nodes writing at the same instant produce two
//! distinct objects by construction.
//!
//! Dependencies: `allocator` and the process `blob_mod.BackendConfig`.

const std = @import("std");
const blob_mod = @import("rove-blob");

pub const BlobCoordination = struct {
    allocator: std.mem.Allocator,

    /// Process-wide blob backend config (copied from `NodeState`; the
    /// borrowed slices outlive both). Used by `start` to open the
    /// `_pool/` backend at the same store every other per-tenant
    /// backend on the node points at.
    blob_backend_cfg: blob_mod.BackendConfig,

    /// The blob coordinator (`docs/architecture/routing-and-ingress.md`):
    /// process-global write coordinator for readset blob PUTs. All worker bodies (inbound +
    /// outbound fetch chunks > 16 KB) submit here; the coord runs one
    /// drainer + K=32 executor pool. Lazy init via `start` after the
    /// node is wired + `num_workers` is known.
    coordinator: ?*blob_mod.BlobCoordinator = null,

    /// The blob coordinator (`docs/architecture/routing-and-ingress.md`): backend that owns the
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

    /// The blob coordinator (`docs/architecture/routing-and-ingress.md`): spawn the
    /// process-global blob coordinator. Idempotent. Called once from
    /// `main.zig` after the node is wired + `num_workers` is known
    /// (the coord allocates per-worker queues up front).
    ///
    /// Opens a single shared S3 backend at the
    /// `{key_prefix_base}_pool/` prefix; submissions land in that one
    /// pool, demuxed by the extent a `BodyRef` names.
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

        const coord = try blob_mod.BlobCoordinator.init(
            self.allocator,
            self.pool_backend.?.blobStore(),
            .{ .worker_count = worker_count },
        );
        self.coordinator = coord;
    }

    /// Tear down in reverse start order: stop + join the coordinator
    /// (its executor threads reach the pool backend), then the pool
    /// backend. The caller MUST have already shut down any producer
    /// (e.g. the FetchEngine) that reads `coordinator` before invoking
    /// this.
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
