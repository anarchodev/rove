//! BatchStore — read+write surface for log batches under hierarchical
//! `{tenant}/{node}/{batch}.{ext}` keys (Phase 5.5 a).
//!
//! Why not reuse `rove-blob`: that abstraction is per-tenant-prefixed
//! and validates keys to forbid `/`. Logs need (a) hierarchical keys
//! across tenants, (b) a LIST operation the indexer polls. Cleaner to
//! ship a focused interface than to overload `BlobStore`.
//!
//! V1 ships only the filesystem backend (good enough for dev + smoke).
//! S3 backend lands in step 3 when worker-side write code starts
//! pushing real batches at production cadence; the same vtable shape
//! covers both.

const std = @import("std");

pub const Error = error{
    InvalidKey,
    NotFound,
    Io,
    OutOfMemory,
};

/// Maximum supported key length. 256 bytes covers
/// `{tenant 64}/{node 16}/{batch 60}.{ext 12}` with room to spare.
pub const MAX_KEY_LEN: usize = 256;

/// Validate that `key` is safe to pass to any backend. Allows `/` as
/// hierarchy separator (the difference vs `rove-blob.validateKey`).
/// Same path-traversal guards as the blob validator otherwise.
pub fn validateKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > MAX_KEY_LEN) return Error.InvalidKey;
    if (key[0] == '/' or key[0] == '.') return Error.InvalidKey;
    if (std.mem.indexOf(u8, key, "..") != null) return Error.InvalidKey;
    if (std.mem.indexOf(u8, key, "//") != null) return Error.InvalidKey;
    for (key) |b| {
        if (b < 0x20 or b > 0x7e) return Error.InvalidKey;
        if (b == '\\') return Error.InvalidKey;
    }
}

pub const BatchStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void,
        get: *const fn (ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
        /// Range read: returns at most `length` bytes starting at byte
        /// `offset`. EOF before `length` returns the short read.
        getRange: *const fn (
            ptr: *anyopaque,
            key: []const u8,
            offset: u64,
            length: u32,
            allocator: std.mem.Allocator,
        ) anyerror![]u8,
        /// LIST keys with `prefix` in ascending lexical order, returning
        /// up to `max` keys strictly greater than `after`. Pass
        /// `after == ""` to start from the first key. Caller frees each
        /// returned key string + the slice itself with `freeListResult`.
        list: *const fn (
            ptr: *anyopaque,
            prefix: []const u8,
            after: []const u8,
            max: u32,
            allocator: std.mem.Allocator,
        ) anyerror![][]const u8,
    };

    pub fn put(self: BatchStore, key: []const u8, bytes: []const u8) !void {
        try validateKey(key);
        return self.vtable.put(self.ptr, key, bytes);
    }

    pub fn get(self: BatchStore, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
        try validateKey(key);
        return self.vtable.get(self.ptr, key, allocator);
    }

    pub fn getRange(
        self: BatchStore,
        key: []const u8,
        offset: u64,
        length: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        try validateKey(key);
        return self.vtable.getRange(self.ptr, key, offset, length, allocator);
    }

    pub fn list(
        self: BatchStore,
        prefix: []const u8,
        after: []const u8,
        max: u32,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        return self.vtable.list(self.ptr, prefix, after, max, allocator);
    }
};

/// Free a `[]const []const u8` returned by `list`. Caller passes the
/// same allocator the list call used.
pub fn freeListResult(allocator: std.mem.Allocator, keys: [][]const u8) void {
    for (keys) |k| allocator.free(k);
    allocator.free(keys);
}

// ── Filesystem backend ─────────────────────────────────────────────

/// Stores batches under `{root}/{key}`. The key may contain `/` so
/// nested directories materialize naturally.
pub const FilesystemBatchStore = struct {
    allocator: std.mem.Allocator,
    root: []u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !*FilesystemBatchStore {
        const self = try allocator.create(FilesystemBatchStore);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
        };
        std.fs.cwd().makePath(self.root) catch {};
        return self;
    }

    pub fn deinit(self: *FilesystemBatchStore) void {
        self.allocator.free(self.root);
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn batchStore(self: *FilesystemBatchStore) BatchStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: BatchStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .getRange = vtableGetRange,
        .list = vtableList,
    };

    fn vtablePut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *FilesystemBatchStore = @ptrCast(@alignCast(ptr));
        const path = try fullPath(self.allocator, self.root, key);
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        // Atomic-ish write: tmp + rename.
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp);
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        try std.fs.cwd().rename(tmp, path);
    }

    fn vtableGet(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FilesystemBatchStore = @ptrCast(@alignCast(ptr));
        const path = try fullPath(allocator, self.root, key);
        defer allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return err,
        };
        defer file.close();
        return file.readToEndAlloc(allocator, std.math.maxInt(u32));
    }

    fn vtableGetRange(
        ptr: *anyopaque,
        key: []const u8,
        offset: u64,
        length: u32,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *FilesystemBatchStore = @ptrCast(@alignCast(ptr));
        const path = try fullPath(allocator, self.root, key);
        defer allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return err,
        };
        defer file.close();
        try file.seekTo(offset);
        const buf = try allocator.alloc(u8, length);
        errdefer allocator.free(buf);
        const n = try file.readAll(buf);
        if (n < buf.len) return allocator.realloc(buf, n);
        return buf;
    }

    fn vtableList(
        ptr: *anyopaque,
        prefix: []const u8,
        after: []const u8,
        max: u32,
        allocator: std.mem.Allocator,
    ) anyerror![][]const u8 {
        const self: *FilesystemBatchStore = @ptrCast(@alignCast(ptr));
        var collected: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (collected.items) |k| allocator.free(k);
            collected.deinit(allocator);
        }
        var dir = std.fs.cwd().openDir(self.root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return collected.toOwnedSlice(allocator),
            else => return err,
        };
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            // Walk gives us OS-native separators; on Linux that's '/'.
            // Sidestep portability for now (we support Linux only).
            if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
            if (after.len > 0 and std.mem.lessThan(u8, entry.path, after)) continue;
            if (after.len > 0 and std.mem.eql(u8, entry.path, after)) continue;
            const dup = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(dup);
            try collected.append(allocator, dup);
        }
        const slice = try collected.toOwnedSlice(allocator);
        // Sort ascending so the indexer can rely on lexical order even
        // when `dir.walk` returns out of order.
        std.mem.sort([]const u8, slice, {}, lessThan);
        if (slice.len <= max) return slice;
        // Keep first `max`, free the rest.
        for (slice[max..]) |k| allocator.free(k);
        return allocator.realloc(slice, max);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn fullPath(
        allocator: std.mem.Allocator,
        root: []const u8,
        key: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, key });
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tempDir(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrint(allocator, "/tmp/rove-bs-{s}-{x}", .{ tag, seed });
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    return path;
}

test "validateKey allows hierarchical paths and rejects traversal" {
    try validateKey("acme/00000001/00000000000000000001-0001730764800000.idx.json");
    try testing.expectError(Error.InvalidKey, validateKey(""));
    try testing.expectError(Error.InvalidKey, validateKey("/leading"));
    try testing.expectError(Error.InvalidKey, validateKey("../etc/passwd"));
    try testing.expectError(Error.InvalidKey, validateKey("a//b"));
    try testing.expectError(Error.InvalidKey, validateKey(".hidden"));
    try testing.expectError(Error.InvalidKey, validateKey("a\\b"));
}

test "FilesystemBatchStore put + get round-trips" {
    const a = testing.allocator;
    const root = try tempDir(a, "fs1");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();

    try store.put("acme/00000001/000000-001.ndjson", "line1\nline2\n");
    const back = try store.get("acme/00000001/000000-001.ndjson", a);
    defer a.free(back);
    try testing.expectEqualStrings("line1\nline2\n", back);
}

test "FilesystemBatchStore list returns sorted keys after cursor" {
    const a = testing.allocator;
    const root = try tempDir(a, "fs2");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();

    try store.put("acme/00000001/b1.idx.json", "x");
    try store.put("acme/00000001/b1.ndjson", "x");
    try store.put("acme/00000001/b2.idx.json", "x");
    try store.put("acme/00000001/b2.ndjson", "x");
    try store.put("globex/00000001/g1.idx.json", "x");

    const all = try store.list("", "", 100, a);
    defer freeListResult(a, all);
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqualStrings("acme/00000001/b1.idx.json", all[0]);
    try testing.expectEqualStrings("globex/00000001/g1.idx.json", all[4]);

    const acme_only = try store.list("acme/", "", 100, a);
    defer freeListResult(a, acme_only);
    try testing.expectEqual(@as(usize, 4), acme_only.len);

    const after_b1ndjson = try store.list("acme/", "acme/00000001/b1.ndjson", 100, a);
    defer freeListResult(a, after_b1ndjson);
    try testing.expectEqual(@as(usize, 2), after_b1ndjson.len);
    try testing.expectEqualStrings("acme/00000001/b2.idx.json", after_b1ndjson[0]);
    try testing.expectEqualStrings("acme/00000001/b2.ndjson", after_b1ndjson[1]);

    const limit_2 = try store.list("", "", 2, a);
    defer freeListResult(a, limit_2);
    try testing.expectEqual(@as(usize, 2), limit_2.len);
}

test "FilesystemBatchStore getRange reads partial bytes" {
    const a = testing.allocator;
    const root = try tempDir(a, "fs3");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();

    try store.put("acme/00000001/b1.ndjson", "0123456789ABCDEF");
    const slice = try store.getRange("acme/00000001/b1.ndjson", 4, 6, a);
    defer a.free(slice);
    try testing.expectEqualStrings("456789", slice);
}

test "FilesystemBatchStore getRange tolerates short tail" {
    const a = testing.allocator;
    const root = try tempDir(a, "fs4");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();

    try store.put("acme/00000001/b1.ndjson", "abc");
    const slice = try store.getRange("acme/00000001/b1.ndjson", 1, 100, a);
    defer a.free(slice);
    try testing.expectEqualStrings("bc", slice);
}

test "FilesystemBatchStore get on missing key returns NotFound" {
    const a = testing.allocator;
    const root = try tempDir(a, "fs5");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();

    try testing.expectError(Error.NotFound, store.get("missing/key", a));
}
