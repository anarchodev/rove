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
