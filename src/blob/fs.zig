//! Filesystem backend for `rove-blob`.
//!
//! Stores one blob per file directly under a root directory: a blob
//! keyed `abc123` lives at `{root}/abc123`. No sharding or directory
//! nesting — fine for the dev scale we target in M1. If a production
//! deployment later grows past the point where ext4's 10k-entries-per-
//! dir linear scan matters (~100k blobs), add a two-level prefix
//! (`ab/c123`) in a follow-up commit.
//!
//! Writes use `atomicFile`: data lands in a temp file and gets renamed
//! into place. A crash mid-write leaves the old blob intact (if any)
//! and never produces a partial read. Reads use `readFileAlloc`.
//!
//! The root directory is owned by the `FilesystemBlobStore` struct
//! and held open as a `std.fs.Dir` file descriptor for the lifetime
//! of the store. All ops are relative to that fd, which means the
//! store survives the root being renamed mid-flight (common enough
//! during test teardown).

const std = @import("std");
const root = @import("root.zig");

const Error = root.Error;

pub const FilesystemBlobStore = struct {
    allocator: std.mem.Allocator,
    /// Owned directory handle for the blob root. Closed on `deinit`.
    dir: std.fs.Dir,

    /// Open (or create) a blob store rooted at `path`. `path` is
    /// resolved against the process CWD. The directory is created
    /// recursively if missing.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FilesystemBlobStore {
        std.fs.cwd().makePath(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try std.fs.cwd().openDir(path, .{});
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn deinit(self: *FilesystemBlobStore) void {
        self.dir.close();
        self.* = undefined;
    }

    /// Obtain a `BlobStore` interface over this backend.
    pub fn blobStore(self: *FilesystemBlobStore) root.BlobStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── vtable impls ───────────────────────────────────────────────────

    fn vPut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *FilesystemBlobStore = @ptrCast(@alignCast(ptr));
        // Buffer is required by AtomicFile in Zig 0.15; 4 KiB is fine —
        // the file contents come from the caller's `bytes` slice, not
        // this buffer.
        var write_buf: [4096]u8 = undefined;
        var atomic = self.dir.atomicFile(key, .{ .write_buffer = &write_buf }) catch |err| {
            std.log.warn("rove-blob fs: atomicFile({s}): {s}", .{ key, @errorName(err) });
            return Error.Io;
        };
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(bytes) catch |err| {
            std.log.warn("rove-blob fs: writeAll({s}): {s}", .{ key, @errorName(err) });
            return Error.Io;
        };
        atomic.finish() catch |err| {
            std.log.warn("rove-blob fs: finish({s}): {s}", .{ key, @errorName(err) });
            return Error.Io;
        };
    }

    fn vGet(
        ptr: *anyopaque,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *FilesystemBlobStore = @ptrCast(@alignCast(ptr));
        return self.dir.readFileAlloc(allocator, key, std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => Error.NotFound,
            error.OutOfMemory => Error.OutOfMemory,
            else => {
                std.log.warn("rove-blob fs: readFileAlloc({s}): {s}", .{ key, @errorName(err) });
                return Error.Io;
            },
        };
    }

    fn vExists(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *FilesystemBlobStore = @ptrCast(@alignCast(ptr));
        self.dir.access(key, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => {
                std.log.warn("rove-blob fs: access({s}): {s}", .{ key, @errorName(err) });
                return Error.Io;
            },
        };
        return true;
    }

    fn vDelete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *FilesystemBlobStore = @ptrCast(@alignCast(ptr));
        self.dir.deleteFile(key) catch |err| switch (err) {
            error.FileNotFound => return, // idempotent — deleting a missing key is success
            else => {
                std.log.warn("rove-blob fs: deleteFile({s}): {s}", .{ key, @errorName(err) });
                return Error.Io;
            },
        };
    }

    const vtable: root.BlobStore.VTable = .{
        .put = vPut,
        .get = vGet,
        .exists = vExists,
        .delete = vDelete,
    };
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDir(buf: *[64]u8) []const u8 {
    const ts = std.time.nanoTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(ts)));
    return std.fmt.bufPrint(buf, "/tmp/rove-blob-test-{x}", .{seed}) catch unreachable;
}

fn cleanup(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

test "put + get round trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try bs.put("hello", "world");
    const got = try bs.get("hello", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("world", got);
}

test "get on missing key returns NotFound" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try testing.expectError(Error.NotFound, bs.get("nope", testing.allocator));
}

test "exists reports correctly for present + missing keys" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try testing.expectEqual(false, try bs.exists("x"));
    try bs.put("x", "data");
    try testing.expectEqual(true, try bs.exists("x"));
}

test "delete removes key, idempotent on missing" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try bs.put("k", "v");
    try testing.expectEqual(true, try bs.exists("k"));
    try bs.delete("k");
    try testing.expectEqual(false, try bs.exists("k"));

    // Deleting again is a no-op success, not an error.
    try bs.delete("k");
}

test "put overwrites existing value atomically" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try bs.put("counter", "1");
    try bs.put("counter", "2");
    try bs.put("counter", "3-much-longer-value-than-before");

    const got = try bs.get("counter", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("3-much-longer-value-than-before", got);
}

test "binary (non-utf8) round trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    try bs.put("raw-bytes", &bytes);

    const got = try bs.get("raw-bytes", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &bytes, got);
}

test "empty value round trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try bs.put("empty", "");
    const got = try bs.get("empty", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "invalid keys are rejected at the interface layer" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    var store = try FilesystemBlobStore.open(testing.allocator, path);
    defer store.deinit();
    const bs = store.blobStore();

    try testing.expectError(Error.InvalidKey, bs.put("../escape", "x"));
    try testing.expectError(Error.InvalidKey, bs.put("has/slash", "x"));
    try testing.expectError(Error.InvalidKey, bs.get("..", testing.allocator));
    try testing.expectError(Error.InvalidKey, bs.exists(".hidden"));
    try testing.expectError(Error.InvalidKey, bs.delete(""));
}

test "store survives close + reopen" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDir(&path_buf);
    defer cleanup(path);

    {
        var store = try FilesystemBlobStore.open(testing.allocator, path);
        defer store.deinit();
        try store.blobStore().put("persisted", "hello");
    }
    {
        var store = try FilesystemBlobStore.open(testing.allocator, path);
        defer store.deinit();
        const got = try store.blobStore().get("persisted", testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("hello", got);
    }
}
