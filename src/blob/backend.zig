//! Tagged-union wrapper around the concrete `BlobStore`
//! implementations. Lets callers hold a single `BlobBackend` field
//! that can be either filesystem or S3 without forcing every
//! consumer to refactor to the `BlobStore` interface.
//!
//! Pattern: each consumer that previously held
//! `blob_backend: blob_mod.FilesystemBlobStore` now holds
//! `blob_backend: BlobBackend`. Construction picks the variant from
//! a config switch; `deinit` and `blobStore()` delegate to the
//! active variant.
//!
//! This is the smallest-surface integration that keeps the
//! existing per-tenant blob_backend ownership model intact while
//! adding S3 as a second backend.

const std = @import("std");
const root = @import("root.zig");
const fs_mod = @import("fs.zig");
const s3_mod = @import("s3.zig");

const Error = root.Error;

/// Operator-supplied configuration that picks the backend for a
/// rove process. Read from env / CLI by the binary, threaded through
/// `WorkerConfig` / `ApplyConfig` / files-server / log-server, and
/// resolved per-tenant via `BlobBackend.openPerTenant`.
///
/// `fs` keeps the existing layout: each tenant's blob backend lives
/// at `{tenant_dir}/{subdir}/`.
///
/// `s3` shares one bucket across the whole node; per-tenant scoping
/// is the key prefix `{key_prefix_base}{instance_id}/{subdir}/`.
/// `key_prefix_base` lets a single bucket host multiple deployments
/// (e.g. staging + prod) without overlap.
pub const BackendConfig = union(enum) {
    fs,
    s3: S3SharedConfig,
};

pub const S3SharedConfig = struct {
    endpoint: []const u8,
    region: []const u8,
    bucket: []const u8,
    /// Prepended to every per-tenant prefix. Must be empty or end in
    /// `/`. Empty by default.
    key_prefix_base: []const u8 = "",
    access_key: []const u8,
    secret_key: []const u8,
    use_tls: bool = true,
};

pub const BlobBackend = union(enum) {
    fs: fs_mod.FilesystemBlobStore,
    s3: s3_mod.S3BlobStore,

    /// Open a filesystem-backed blob store rooted at `path`. Mirrors
    /// `FilesystemBlobStore.open` for callers that want to keep
    /// per-tenant directory layouts.
    pub fn openFs(allocator: std.mem.Allocator, path: []const u8) !BlobBackend {
        return .{ .fs = try fs_mod.FilesystemBlobStore.open(allocator, path) };
    }

    /// Open an S3-backed blob store with `config`. The config's
    /// `key_prefix` is what the caller uses to scope a shared
    /// bucket across tenants — e.g. each tenant passes
    /// `key_prefix = "{instance_id}/file-blobs/"`.
    pub fn openS3(allocator: std.mem.Allocator, config: s3_mod.Config) !BlobBackend {
        return .{ .s3 = try s3_mod.S3BlobStore.init(allocator, config) };
    }

    /// Open a per-tenant backend for one tenant's `{subdir}` (e.g.
    /// `"file-blobs"` or `"log-blobs"`). The dispatch is:
    ///
    /// - `.fs` → `openFs(fs_path)` — `fs_path` already encodes the
    ///   per-tenant + per-subdir layout (e.g.
    ///   `{inst.dir}/file-blobs/`).
    /// - `.s3` → `openS3` with `key_prefix =
    ///   "{key_prefix_base}{instance_id}/{subdir}/"`. The prefix is
    ///   built into a stack buffer and then duped by S3BlobStore.init,
    ///   so no caller-side lifetime tracking is needed.
    ///
    /// Same factory used by both `TenantFiles` and `TenantLog` so the
    /// per-tenant layout in S3 mirrors the on-disk layout exactly.
    pub fn openPerTenant(
        allocator: std.mem.Allocator,
        cfg: BackendConfig,
        fs_path: []const u8,
        instance_id: []const u8,
        subdir: []const u8,
    ) !BlobBackend {
        return switch (cfg) {
            .fs => try openFs(allocator, fs_path),
            .s3 => |s| blk: {
                const prefix = try std.fmt.allocPrint(
                    allocator,
                    "{s}{s}/{s}/",
                    .{ s.key_prefix_base, instance_id, subdir },
                );
                defer allocator.free(prefix);
                break :blk try openS3(allocator, .{
                    .endpoint = s.endpoint,
                    .region = s.region,
                    .bucket = s.bucket,
                    .key_prefix = prefix,
                    .access_key = s.access_key,
                    .secret_key = s.secret_key,
                    .use_tls = s.use_tls,
                });
            },
        };
    }

    pub fn deinit(self: *BlobBackend) void {
        switch (self.*) {
            .fs => |*x| x.deinit(),
            .s3 => |*x| x.deinit(),
        }
    }

    pub fn blobStore(self: *BlobBackend) root.BlobStore {
        return switch (self.*) {
            .fs => |*x| x.blobStore(),
            .s3 => |*x| x.blobStore(),
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "BlobBackend: fs round-trips through union" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/rove-blob-backend-{x}", .{seed}) catch unreachable;
    defer std.fs.cwd().deleteTree(path) catch {};

    var be = try BlobBackend.openFs(testing.allocator, path);
    defer be.deinit();
    const bs = be.blobStore();
    try bs.put("hello", "world");
    const got = try bs.get("hello", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("world", got);
}

test "BlobBackend: s3 init through union (no I/O)" {
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

test "openPerTenant: fs uses fs_path verbatim" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var path_buf: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/rove-blob-pt-{x}", .{seed}) catch unreachable;
    defer std.fs.cwd().deleteTree(path) catch {};

    var be = try BlobBackend.openPerTenant(testing.allocator, .fs, path, "inst-0001", "file-blobs");
    defer be.deinit();
    const bs = be.blobStore();
    try bs.put("hello", "world");
    const got = try bs.get("hello", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("world", got);
}

test "openPerTenant: s3 builds {base}{id}/{subdir}/ prefix" {
    var be = try BlobBackend.openPerTenant(testing.allocator, .{ .s3 = .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "loop46-shared",
        .key_prefix_base = "prod/",
        .access_key = "ak",
        .secret_key = "sk",
    } }, "/ignored/for/s3", "inst-0001", "file-blobs");
    defer be.deinit();
    try testing.expectEqualStrings("prod/inst-0001/file-blobs/", be.s3.config.key_prefix);
    try testing.expectEqualStrings("loop46-shared", be.s3.config.bucket);
}

test "openPerTenant: s3 with empty base" {
    var be = try BlobBackend.openPerTenant(testing.allocator, .{ .s3 = .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "b",
        .access_key = "ak",
        .secret_key = "sk",
    } }, "/ignored", "inst-abc", "log-blobs");
    defer be.deinit();
    try testing.expectEqualStrings("inst-abc/log-blobs/", be.s3.config.key_prefix);
}
