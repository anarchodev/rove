// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Per-tenant blob backend wrapper. S3-only: rove uses S3-shaped
//! object storage (AWS / OVH / R2 / B2 / MinIO) for content-addressed
//! blobs (source, bytecode, static assets, log batches, snapshots).
//! No filesystem-backed variant — the production deploy is multi-node
//! and needs a shared backend across leader + followers.
//!
//! Each consumer that owns a per-tenant store holds a `BlobBackend`
//! field; per-tenant construction goes through
//! `TenantStorage.openBackend` (rove-tenant's `storage.zig`), which
//! owns the `{key_prefix_base}{instance_id}[/{incarnation}]/{subdir}/`
//! prefix rule — this module never derives a per-tenant path itself.
//! `deinit` and `blobStore()` delegate to the underlying `S3BlobStore`.

const std = @import("std");
const root = @import("root.zig");
const s3_mod = @import("s3.zig");

const Error = root.Error;

/// Operator-supplied configuration. Read from env by `env.zig`,
/// threaded through `WorkerConfig` / `ApplyConfig` / log-server, and
/// resolved per-tenant via `TenantStorage.openBackend`.
/// One bucket hosts the whole node; per-tenant scoping is the key
/// prefix `{key_prefix_base}{instance_id}/{subdir}/`. `key_prefix_base`
/// lets a single bucket host multiple deployments (staging + prod).
pub const BackendConfig = struct {
    endpoint: []const u8 = "",
    region: []const u8 = "",
    bucket: []const u8 = "",
    /// Prepended to every per-tenant prefix. Must be empty or end in
    /// `/`. Empty by default.
    key_prefix_base: []const u8 = "",
    access_key: []const u8 = "",
    secret_key: []const u8 = "",
    use_tls: bool = true,
};

/// `BlobBackend` is the per-store handle held by every consumer that
/// owns a per-tenant `BlobStore`: content-addressed bytes shared
/// across leader + followers via S3-shaped object storage, used for
/// file-blobs (bytecode + static assets) and log-blobs.
///
/// One variant only — every node must read the same content-addressed
/// store, so S3 is mandatory even single-node
/// (`docs/architecture/deployment-and-logs.md`). The wrapper stays
/// because consumers hold it by value and construct it through
/// `TenantStorage.openBackend`, which owns the prefix rule.
pub const BlobBackend = struct {
    s3: s3_mod.S3BlobStore,

    /// Open an S3 backend with `config`. The config's `key_prefix` scopes
    /// a shared bucket — e.g. each tenant passes
    /// `key_prefix = "{instance_id}/file-blobs/"`.
    pub fn openS3(allocator: std.mem.Allocator, config: s3_mod.Config) !BlobBackend {
        return .{ .s3 = try s3_mod.S3BlobStore.init(allocator, config) };
    }

    pub fn deinit(self: *BlobBackend) void {
        self.s3.deinit();
    }

    pub fn blobStore(self: *BlobBackend) root.BlobStore {
        return self.s3.blobStore();
    }

    /// Delete every object under `sub_prefix` (relative to this backend's
    /// `key_prefix`), returning how many were removed. Idempotent, so a
    /// partial sweep converges on re-run — see `S3BlobStore.deletePrefix`.
    ///
    /// Not on the `BlobStore` vtable: enumeration is a storage-lifecycle
    /// operation (teardown, GC), not part of the hash-keyed read/write surface
    /// that every caller shares.
    pub fn deletePrefix(self: *BlobBackend, sub_prefix: []const u8) !u64 {
        return self.s3.deletePrefix(sub_prefix);
    }

    /// Build a presigned GET URL for `key`. Caller frees.
    ///
    /// 302-redirects static asset requests directly to S3 (deployment
    /// snapshots — `docs/architecture/deployment-and-logs.md`). `expires_secs` caps the
    /// URL's lifetime (max 604800 = 7 days per the SigV4 spec).
    /// `response_content_type` overrides whatever Content-Type S3
    /// has stored for the object — set it from the static
    /// manifest's `content_type`.
    pub fn presignGet(
        self: *BlobBackend,
        key: []const u8,
        expires_secs: u32,
        response_content_type: ?[]const u8,
        body_allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.s3.presignGet(key, expires_secs, response_content_type, body_allocator);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "BlobBackend: s3 init through wrapper (no I/O)" {
    var be = try BlobBackend.openS3(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "loop46",
        .key_prefix = "tenant-acme/file-blobs/",
        .access_key = "ak",
        .secret_key = "sk",
    });
    defer be.deinit();
    _ = be.blobStore();
    try testing.expectEqualStrings("loop46", be.s3.config.bucket);
}

