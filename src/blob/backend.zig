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
const http_blob = @import("http_blob.zig");

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

/// `BlobBackend` is the per-store handle held by every consumer
/// that owns a per-tenant `BlobStore`. Two variants:
///
/// - `s3` — content-addressed bytes shared across leader +
///   followers via S3-shaped object storage. Used for file-blobs
///   (bytecode + static assets) and log-blobs.
/// - `http` — read-only fetch against a colocated files-server
///   over HTTP/2. Used by loop46 worker for manifest reads
///   (production.md #1.4 step 4 — manifests live in raft-replicated
///   KV inside the files-server cluster, not S3).
///
/// Construction picks the variant; the `blobStore()` interface is
/// uniform so consumers don't branch.
pub const BlobBackend = struct {
    inner: union(enum) {
        s3: s3_mod.S3BlobStore,
        http: http_blob.HttpBlobStore,
    },

    /// Open an S3 backend with `config`. The config's `key_prefix` scopes
    /// a shared bucket — e.g. each tenant passes
    /// `key_prefix = "{instance_id}/file-blobs/"`.
    pub fn openS3(allocator: std.mem.Allocator, config: s3_mod.Config) !BlobBackend {
        return .{ .inner = .{ .s3 = try s3_mod.S3BlobStore.init(allocator, config) } };
    }

    /// Open an HTTP-backed backend for one tenant. Read-only: writes
    /// flow through the files-server's raft cluster, never directly
    /// from a client. See `http_blob.HttpBlobStore` for the URL
    /// shape.
    pub fn openHttp(
        allocator: std.mem.Allocator,
        cfg: http_blob.HttpBlobStore.Config,
    ) !BlobBackend {
        return .{ .inner = .{ .http = try http_blob.HttpBlobStore.init(allocator, cfg) } };
    }

    /// Open a per-tenant S3 backend for one tenant's `{subdir}` (e.g.
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
        switch (self.inner) {
            .s3 => |*s| s.deinit(),
            .http => |*h| h.deinit(),
        }
    }

    pub fn blobStore(self: *BlobBackend) root.BlobStore {
        return switch (self.inner) {
            .s3 => |*s| s.blobStore(),
            .http => |*h| h.blobStore(),
        };
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
    try testing.expect(be.inner == .s3);
}

fn testFakeMint(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return allocator.dupe(u8, "fake.jwt");
}

test "BlobBackend: http variant (no I/O)" {
    var be = try BlobBackend.openHttp(testing.allocator, .{
        .base_url = "https://files.loop46.localhost:9090",
        .instance_id = "acme",
        .mint_jwt = testFakeMint,
        .verify_tls = false,
    });
    defer be.deinit();
    _ = be.blobStore();
    try testing.expect(be.inner == .http);
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
    try testing.expectEqualStrings("prod/inst-0001/file-blobs/", be.inner.s3.config.key_prefix);
    try testing.expectEqualStrings("loop46-shared", be.inner.s3.config.bucket);
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
    try testing.expectEqualStrings("inst-abc/log-blobs/", be.inner.s3.config.key_prefix);
}
