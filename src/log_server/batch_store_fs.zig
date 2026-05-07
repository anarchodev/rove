//! Filesystem `BatchStore` backend. Files live at
//! `{base_dir}/{key}` — keys are hierarchical (`{tenant}/{node}/{batch}.{ext}`)
//! so the on-disk layout mirrors S3 exactly. Used by the cross-
//! process worker → log-server-standalone path when the operator
//! hasn't wired S3 (typical local dev / smoke).
//!
//! Phase 5.5(a) step 3 originally retired the on-disk batch store
//! to keep dev and prod on a single backend. Phase 5.5(a) Task #61
//! (the standalone-process split) brings it back as the cross-
//! process equivalent of MemoryBatchStore: same behavior, but the
//! state lives on disk so the worker's PUT and the standalone's
//! LIST/GET see each other across process boundaries.
//!
//! Concurrency: two-process safe for the normal worker / standalone
//! shape (worker writes, standalone reads). Atomic writes via temp
//! + rename so a half-written file never appears in `list`.

const std = @import("std");
const batch_store_mod = @import("batch_store.zig");

const Error = batch_store_mod.Error;

pub const FsBatchStore = struct {
    allocator: std.mem.Allocator,
    /// Owned base directory path. Each `put` creates intermediate
    /// directories under this prefix as needed.
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !*FsBatchStore {
        const dir_copy = try allocator.dupe(u8, base_dir);
        errdefer allocator.free(dir_copy);
        std.fs.cwd().makePath(dir_copy) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const self = try allocator.create(FsBatchStore);
        self.* = .{ .allocator = allocator, .base_dir = dir_copy };
        return self;
    }

    pub fn deinit(self: *FsBatchStore) void {
        const a = self.allocator;
        a.free(self.base_dir);
        a.destroy(self);
    }

    pub fn batchStore(self: *FsBatchStore) batch_store_mod.BatchStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: batch_store_mod.BatchStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .getRange = vtableGetRange,
        .list = vtableList,
    };

    fn fullPath(self: *FsBatchStore, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.base_dir, key });
    }

    fn vtablePut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *FsBatchStore = @ptrCast(@alignCast(ptr));
        const path = try self.fullPath(key, self.allocator);
        defer self.allocator.free(path);

        // Make sure intermediate directories exist. The dirname of
        // a key like `acme/00000001/b.ndjson` is
        // `{base_dir}/acme/00000001` — `makePath` creates it.
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Write to a tempfile + atomic rename so the indexer's `list`
        // never observes a half-written file. The temp file lives in
        // the same directory so the rename is a same-fs operation.
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp.{x}", .{ path, std.crypto.random.int(u64) });
        defer self.allocator.free(tmp);

        {
            const f = try std.fs.cwd().createFile(tmp, .{ .mode = 0o600 });
            defer f.close();
            try f.writeAll(bytes);
        }
        std.fs.cwd().rename(tmp, path) catch |err| {
            std.fs.cwd().deleteFile(tmp) catch {};
            return err;
        };
    }

    fn vtableGet(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FsBatchStore = @ptrCast(@alignCast(ptr));
        const path = try self.fullPath(key, self.allocator);
        defer self.allocator.free(path);
        return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => Error.NotFound,
            else => err,
        };
    }

    fn vtableGetRange(
        ptr: *anyopaque,
        key: []const u8,
        offset: u64,
        length: u32,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *FsBatchStore = @ptrCast(@alignCast(ptr));
        const path = try self.fullPath(key, self.allocator);
        defer self.allocator.free(path);
        const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return err,
        };
        defer f.close();

        const stat = try f.stat();
        if (offset >= stat.size) return allocator.dupe(u8, "");
        const end: u64 = @min(stat.size, offset + length);
        const want: usize = @intCast(end - offset);
        const buf = try allocator.alloc(u8, want);
        errdefer allocator.free(buf);
        try f.seekTo(offset);
        const got = try f.readAll(buf);
        if (got != want) return allocator.realloc(buf, got);
        return buf;
    }

    fn vtableList(
        ptr: *anyopaque,
        prefix: []const u8,
        after: []const u8,
        max: u32,
        allocator: std.mem.Allocator,
    ) anyerror![][]const u8 {
        const self: *FsBatchStore = @ptrCast(@alignCast(ptr));
        var collected: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (collected.items) |k| allocator.free(k);
            collected.deinit(allocator);
        }

        // openDir on the base; if it doesn't exist (no batches written
        // yet), return an empty list.
        var root = std.fs.cwd().openDir(self.base_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc([]const u8, 0),
            else => return err,
        };
        defer root.close();

        try walkInto(allocator, &root, "", prefix, &collected);

        const slice = try collected.toOwnedSlice(allocator);
        std.mem.sort([]const u8, slice, {}, lessThan);

        // Drop temp files and anything <= cursor.
        var keep: usize = 0;
        for (slice) |k| {
            if (std.mem.indexOf(u8, k, ".tmp.") != null) {
                allocator.free(k);
                continue;
            }
            if (after.len > 0 and !std.mem.lessThan(u8, after, k)) {
                allocator.free(k);
                continue;
            }
            slice[keep] = k;
            keep += 1;
        }

        const trimmed = try allocator.realloc(slice, keep);
        if (trimmed.len <= max) return trimmed;
        for (trimmed[max..]) |k| allocator.free(k);
        return allocator.realloc(trimmed, max);
    }

    fn walkInto(
        allocator: std.mem.Allocator,
        dir: *std.fs.Dir,
        rel: []const u8,
        prefix: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            const child_rel: []const u8 = if (rel.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
            defer allocator.free(child_rel);

            switch (entry.kind) {
                .directory => {
                    var sub = try dir.openDir(entry.name, .{ .iterate = true });
                    defer sub.close();
                    try walkInto(allocator, &sub, child_rel, prefix, out);
                },
                .file => {
                    if (prefix.len > 0 and !std.mem.startsWith(u8, child_rel, prefix)) continue;
                    const dup = try allocator.dupe(u8, child_rel);
                    errdefer allocator.free(dup);
                    try out.append(allocator, dup);
                },
                else => {},
            }
        }
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDir(buf: *[96]u8, tag: []const u8) []const u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    return std.fmt.bufPrint(buf, "/tmp/rove-fsbatch-{s}-{x}", .{ tag, seed }) catch unreachable;
}

test "FsBatchStore put + get round-trips through the filesystem" {
    var path_buf: [96]u8 = undefined;
    const path = tmpDir(&path_buf, "rt");
    defer std.fs.cwd().deleteTree(path) catch {};

    const m = try FsBatchStore.init(testing.allocator, path);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/00000001/b1.ndjson", "line1\nline2\n");
    const back = try store.get("acme/00000001/b1.ndjson", testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("line1\nline2\n", back);
}

test "FsBatchStore list returns sorted keys after cursor" {
    var path_buf: [96]u8 = undefined;
    const path = tmpDir(&path_buf, "list");
    defer std.fs.cwd().deleteTree(path) catch {};

    const m = try FsBatchStore.init(testing.allocator, path);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/00000001/b1.idx.json", "x");
    try store.put("acme/00000001/b1.ndjson", "x");
    try store.put("acme/00000001/b2.idx.json", "x");
    try store.put("acme/00000001/b2.ndjson", "x");
    try store.put("globex/00000001/g1.idx.json", "x");

    const all = try store.list("", "", 100, testing.allocator);
    defer batch_store_mod.freeListResult(testing.allocator, all);
    try testing.expectEqual(@as(usize, 5), all.len);
    try testing.expectEqualStrings("acme/00000001/b1.idx.json", all[0]);
    try testing.expectEqualStrings("globex/00000001/g1.idx.json", all[4]);

    const acme_only = try store.list("acme/", "", 100, testing.allocator);
    defer batch_store_mod.freeListResult(testing.allocator, acme_only);
    try testing.expectEqual(@as(usize, 4), acme_only.len);

    const after_b1ndjson = try store.list("acme/", "acme/00000001/b1.ndjson", 100, testing.allocator);
    defer batch_store_mod.freeListResult(testing.allocator, after_b1ndjson);
    try testing.expectEqual(@as(usize, 2), after_b1ndjson.len);
    try testing.expectEqualStrings("acme/00000001/b2.idx.json", after_b1ndjson[0]);
    try testing.expectEqualStrings("acme/00000001/b2.ndjson", after_b1ndjson[1]);
}

test "FsBatchStore getRange reads partial bytes" {
    var path_buf: [96]u8 = undefined;
    const path = tmpDir(&path_buf, "range");
    defer std.fs.cwd().deleteTree(path) catch {};

    const m = try FsBatchStore.init(testing.allocator, path);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/b.ndjson", "0123456789ABCDEF");
    const slice = try store.getRange("acme/b.ndjson", 4, 6, testing.allocator);
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings("456789", slice);
}

test "FsBatchStore get on missing key returns NotFound" {
    var path_buf: [96]u8 = undefined;
    const path = tmpDir(&path_buf, "miss");
    defer std.fs.cwd().deleteTree(path) catch {};

    const m = try FsBatchStore.init(testing.allocator, path);
    defer m.deinit();
    const store = m.batchStore();

    try testing.expectError(Error.NotFound, store.get("missing/key", testing.allocator));
}

test "FsBatchStore atomic put: temp files never surface in list" {
    var path_buf: [96]u8 = undefined;
    const path = tmpDir(&path_buf, "atomic");
    defer std.fs.cwd().deleteTree(path) catch {};

    const m = try FsBatchStore.init(testing.allocator, path);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/01.ndjson", "abc");
    // Plant a stray temp file directly on disk to simulate a crashed
    // half-write — the list filter must skip it.
    {
        var dir = try std.fs.cwd().openDir(path, .{});
        defer dir.close();
        try dir.makePath("acme");
        const f = try dir.createFile("acme/02.ndjson.tmp.deadbeef", .{ .mode = 0o600 });
        f.close();
    }
    const all = try store.list("", "", 100, testing.allocator);
    defer batch_store_mod.freeListResult(testing.allocator, all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("acme/01.ndjson", all[0]);
}
