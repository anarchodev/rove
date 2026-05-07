//! Per-tenant blob backend wrapper. S3-only: rove uses S3-shaped
//! object storage (AWS / OVH / R2 / B2 / MinIO) for content-addressed
//! blobs (source, bytecode, static assets, log batches, snapshots).
//! No filesystem-backed variant — the production deploy is multi-node
//! and needs a shared backend across leader + followers.
//!
//! Each consumer that owns a per-tenant store holds a `BlobBackend`
//! field; construction goes through `openPerTenant` which builds the
//! key prefix `{key_prefix_base}{instance_id}/{subdir}/`. `deinit`
//! and `blobStore()` delegate to the underlying `S3BlobStore`.

const std = @import("std");
const root = @import("root.zig");
const s3_mod = @import("s3.zig");

const Error = root.Error;

/// Operator-supplied configuration. Read from env by `env.zig`,
/// threaded through `WorkerConfig` / `ApplyConfig` / files-server /
/// log-server, and resolved per-tenant via `openPerTenant`. One
/// bucket hosts the whole node; per-tenant scoping is the key prefix
/// `{key_prefix_base}{instance_id}/{subdir}/`. `key_prefix_base` lets
/// a single bucket host multiple deployments (staging + prod).
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

pub const BlobBackend = struct {
    inner: s3_mod.S3BlobStore,

    /// Open a backend with `config`. The config's `key_prefix` scopes
    /// a shared bucket — e.g. each tenant passes
    /// `key_prefix = "{instance_id}/file-blobs/"`.
    pub fn openS3(allocator: std.mem.Allocator, config: s3_mod.Config) !BlobBackend {
        return .{ .inner = try s3_mod.S3BlobStore.init(allocator, config) };
    }

    /// Open a per-tenant backend for one tenant's `{subdir}` (e.g.
    /// `"file-blobs"` or `"log-blobs"`). Builds the key prefix
    /// `"{key_prefix_base}{instance_id}/{subdir}/"`. Same factory used
    /// by both `TenantFiles` and `TenantLog` so the per-tenant layout
    /// in S3 mirrors the on-disk layout exactly.
    pub fn openPerTenant(
        allocator: std.mem.Allocator,
        cfg: BackendConfig,
        instance_id: []const u8,
        subdir: []const u8,
    ) !BlobBackend {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "{s}{s}/{s}/",
            .{ cfg.key_prefix_base, instance_id, subdir },
        );
        defer allocator.free(prefix);
        return openS3(allocator, .{
            .endpoint = cfg.endpoint,
            .region = cfg.region,
            .bucket = cfg.bucket,
            .key_prefix = prefix,
            .access_key = cfg.access_key,
            .secret_key = cfg.secret_key,
            .use_tls = cfg.use_tls,
        });
    }

    pub fn deinit(self: *BlobBackend) void {
        self.inner.deinit();
    }

    pub fn blobStore(self: *BlobBackend) root.BlobStore {
        return self.inner.blobStore();
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
}

test "openPerTenant: builds {base}{id}/{subdir}/ prefix" {
    var be = try BlobBackend.openPerTenant(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "loop46-shared",
        .key_prefix_base = "prod/",
        .access_key = "ak",
        .secret_key = "sk",
    }, "inst-0001", "file-blobs");
    defer be.deinit();
    try testing.expectEqualStrings("prod/inst-0001/file-blobs/", be.inner.config.key_prefix);
    try testing.expectEqualStrings("loop46-shared", be.inner.config.bucket);
}

test "openPerTenant: empty key_prefix_base" {
    var be = try BlobBackend.openPerTenant(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "b",
        .access_key = "ak",
        .secret_key = "sk",
    }, "inst-abc", "log-blobs");
    defer be.deinit();
    try testing.expectEqualStrings("inst-abc/log-blobs/", be.inner.config.key_prefix);
}
