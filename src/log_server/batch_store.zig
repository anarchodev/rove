//! BatchStore — read+write surface for log batches under hierarchical
//! `{tenant}/{node}/{batch}.{ext}` keys (Phase 5.5 a).
//!
//! Why not reuse `rove-blob`: that abstraction is per-tenant-prefixed
//! and validates keys to forbid `/`. Logs need (a) hierarchical keys
//! across tenants, (b) a LIST operation the indexer polls. Cleaner to
//! ship a focused interface than to overload `BlobStore`.
//!
//! Backends:
//!   - `S3BatchStore` (`batch_store_s3.zig`) — production. Real S3
//!     PUT/GET with Range header + ListObjectsV2.
//!   - `MemoryBatchStore` (this file) — in-process map-backed test
//!     fixture. Used by unit tests to stay hermetic; production
//!     never touches it.
//!
//! There is no longer a filesystem backend — the design ships
//! S3-only after Phase 5.5 (a) step 3. Local-disk batch storage
//! created subtle drift between dev and prod (different list
//! semantics, different consistency, different operational story);
//! collapsing to one backend removes that fork.

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

// ── In-process backend (test fixture only) ─────────────────────────

/// In-memory implementation backed by a `StringHashMap`. **Test-only**
/// — production code paths use `S3BatchStore`. Exposed publicly so
/// dispatcher / indexer / flush_writer unit tests can drive the
/// interface without an S3 endpoint.
///
/// Concurrency: NOT thread-safe. Each test owns its own instance.
pub const MemoryBatchStore = struct {
    allocator: std.mem.Allocator,
    objects: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !*MemoryBatchStore {
        const self = try allocator.create(MemoryBatchStore);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *MemoryBatchStore) void {
        var it = self.objects.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.objects.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn batchStore(self: *MemoryBatchStore) BatchStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: BatchStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .getRange = vtableGetRange,
        .list = vtableList,
    };

    fn vtablePut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *MemoryBatchStore = @ptrCast(@alignCast(ptr));
        const value = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(value);

        if (self.objects.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        try self.objects.put(self.allocator, k, value);
    }

    fn vtableGet(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *MemoryBatchStore = @ptrCast(@alignCast(ptr));
        const v = self.objects.get(key) orelse return Error.NotFound;
        return allocator.dupe(u8, v);
    }

    fn vtableGetRange(
        ptr: *anyopaque,
        key: []const u8,
        offset: u64,
        length: u32,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *MemoryBatchStore = @ptrCast(@alignCast(ptr));
        const v = self.objects.get(key) orelse return Error.NotFound;
        if (offset >= v.len) return allocator.dupe(u8, "");
        const end = @min(@as(u64, @intCast(v.len)), offset + length);
        return allocator.dupe(u8, v[@intCast(offset)..@intCast(end)]);
    }

    fn vtableList(
        ptr: *anyopaque,
        prefix: []const u8,
        after: []const u8,
        max: u32,
        allocator: std.mem.Allocator,
    ) anyerror![][]const u8 {
        const self: *MemoryBatchStore = @ptrCast(@alignCast(ptr));
        var collected: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (collected.items) |k| allocator.free(k);
            collected.deinit(allocator);
        }
        var it = self.objects.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (!std.mem.startsWith(u8, k, prefix)) continue;
            if (after.len > 0 and !std.mem.lessThan(u8, after, k)) continue;
            const dup = try allocator.dupe(u8, k);
            errdefer allocator.free(dup);
            try collected.append(allocator, dup);
        }
        const slice = try collected.toOwnedSlice(allocator);
        std.mem.sort([]const u8, slice, {}, lessThan);
        if (slice.len <= max) return slice;
        for (slice[max..]) |k| allocator.free(k);
        return allocator.realloc(slice, max);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "validateKey allows hierarchical paths and rejects traversal" {
    try validateKey("acme/00000001/00000000000000000001-0001730764800000.idx.json");
    try testing.expectError(Error.InvalidKey, validateKey(""));
    try testing.expectError(Error.InvalidKey, validateKey("/leading"));
    try testing.expectError(Error.InvalidKey, validateKey("../etc/passwd"));
    try testing.expectError(Error.InvalidKey, validateKey("a//b"));
    try testing.expectError(Error.InvalidKey, validateKey(".hidden"));
    try testing.expectError(Error.InvalidKey, validateKey("a\\b"));
}

test "MemoryBatchStore put + get round-trips" {
    const a = testing.allocator;
    const m = try MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/00000001/000000-001.ndjson", "line1\nline2\n");
    const back = try store.get("acme/00000001/000000-001.ndjson", a);
    defer a.free(back);
    try testing.expectEqualStrings("line1\nline2\n", back);
}

test "MemoryBatchStore list returns sorted keys after cursor" {
    const a = testing.allocator;
    const m = try MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

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

test "MemoryBatchStore getRange reads partial bytes" {
    const a = testing.allocator;
    const m = try MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/00000001/b1.ndjson", "0123456789ABCDEF");
    const slice = try store.getRange("acme/00000001/b1.ndjson", 4, 6, a);
    defer a.free(slice);
    try testing.expectEqualStrings("456789", slice);
}

test "MemoryBatchStore getRange tolerates short tail" {
    const a = testing.allocator;
    const m = try MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    try store.put("acme/00000001/b1.ndjson", "abc");
    const slice = try store.getRange("acme/00000001/b1.ndjson", 1, 100, a);
    defer a.free(slice);
    try testing.expectEqualStrings("bc", slice);
}

test "MemoryBatchStore get on missing key returns NotFound" {
    const a = testing.allocator;
    const m = try MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    try testing.expectError(Error.NotFound, store.get("missing/key", a));
}
