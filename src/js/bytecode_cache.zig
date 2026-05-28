//! Process-wide content-addressed cache for compiled module bytecode.
//!
//! Phase 3 of `docs/deployment-snapshots-plan.md`. Lifted into its
//! own module so `globals`, `dispatcher`, and `worker` can all
//! reference `BlobBytes` without cycling through each other:
//!
//!     worker ──┐
//!     globals ─┼──> bytecode_cache
//!     dispatcher
//!
//! Storage model: one entry per unique `sha256(bytecode_bytes)`
//! ever loaded by this node. Snapshots hold leases (`*BlobBytes`);
//! the cache itself holds no standing reference — last lease
//! release removes the entry and frees the bytes.
//!
//! Cross-tenant sharing falls out: 200 tenants pulling the same
//! `loop46-sdk-base.js` bytecode keep one copy in memory.

const std = @import("std");

/// One content-addressed blob. Lifetime is governed entirely by
/// `refcount`; the cache acquires a fresh blob with refcount=1
/// and removes the entry when the last lease releases.
pub const BlobBytes = struct {
    /// Compiled bytecode bytes. Cache-owned; freed when refcount → 0.
    bytes: []u8,
    /// Owning copy of the cache key (64-char hex sha256). The cache's
    /// hashmap key borrows into this field, so the entry stays
    /// hashable for as long as the `*BlobBytes` lives.
    hash_hex: [64]u8,
    /// Per-snapshot leases + per-request retains. The cache itself
    /// holds NO standing reference — `acquire` only bumps on lookup
    /// hits. When the last lease releases, the entry's removed from
    /// the cache and the bytes are freed.
    refcount: std.atomic.Value(u32),
};

pub const BytecodeCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    by_hash: std.StringHashMapUnmanaged(*BlobBytes) = .empty,

    /// Try to lease an already-cached blob. Returns null on miss;
    /// caller fetches the bytes and calls `insert`. On hit, bumps
    /// the refcount under the cache lock.
    pub fn acquire(self: *BytecodeCache, hash_hex: []const u8) ?*BlobBytes {
        self.mutex.lock();
        defer self.mutex.unlock();
        const bb = self.by_hash.get(hash_hex) orelse return null;
        _ = bb.refcount.fetchAdd(1, .acquire);
        return bb;
    }

    /// Insert a freshly-fetched blob with refcount=1. Takes ownership
    /// of `bytes`. If another thread inserted the same hash between
    /// the caller's `acquire` miss and this `insert`, frees the
    /// caller's bytes and returns the existing entry with a bumped
    /// refcount — the cache still satisfies the lease.
    pub fn insert(
        self: *BytecodeCache,
        hash_hex: []const u8,
        bytes: []u8,
    ) !*BlobBytes {
        std.debug.assert(hash_hex.len == 64);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.by_hash.get(hash_hex)) |existing| {
            self.allocator.free(bytes);
            _ = existing.refcount.fetchAdd(1, .acquire);
            return existing;
        }
        const bb = try self.allocator.create(BlobBytes);
        errdefer self.allocator.destroy(bb);
        bb.* = .{
            .bytes = bytes,
            .hash_hex = undefined,
            .refcount = .{ .raw = 1 },
        };
        @memcpy(&bb.hash_hex, hash_hex[0..64]);
        try self.by_hash.put(self.allocator, &bb.hash_hex, bb);
        return bb;
    }

    /// Drop a lease. If this was the last reference, removes the
    /// entry under the lock and frees the bytes + the wrapper.
    /// Lock-during-decrement avoids the
    /// release-then-concurrent-acquire race (a peer can't bump from
    /// 0 → 1 because acquire takes the same lock).
    pub fn release(self: *BytecodeCache, bb: *BlobBytes) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (bb.refcount.fetchSub(1, .release) != 1) return;
        _ = self.by_hash.remove(&bb.hash_hex);
        self.allocator.free(bb.bytes);
        self.allocator.destroy(bb);
    }

    pub fn deinit(self: *BytecodeCache) void {
        // All snapshots that held leases must have released by now;
        // any surviving entry is a leak.
        std.debug.assert(self.by_hash.count() == 0);
        self.by_hash.deinit(self.allocator);
    }

    /// Test/diagnostic accessor: number of distinct blobs currently
    /// cached. Takes the lock briefly.
    pub fn size(self: *BytecodeCache) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.by_hash.count();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "BytecodeCache: miss then insert + acquire" {
    var cache: BytecodeCache = .{ .allocator = testing.allocator };
    defer cache.deinit();

    const h: [64]u8 = [_]u8{'a'} ** 64;
    try testing.expect(cache.acquire(&h) == null);

    const bytes = try testing.allocator.dupe(u8, "hello");
    const bb = try cache.insert(&h, bytes);
    try testing.expectEqual(@as(usize, 1), cache.size());
    try testing.expectEqualStrings("hello", bb.bytes);
    try testing.expectEqual(@as(u32, 1), bb.refcount.load(.acquire));

    const hit = cache.acquire(&h).?;
    try testing.expectEqual(bb, hit);
    try testing.expectEqual(@as(u32, 2), bb.refcount.load(.acquire));

    cache.release(hit);
    try testing.expectEqual(@as(u32, 1), bb.refcount.load(.acquire));
    cache.release(bb);
    try testing.expectEqual(@as(usize, 0), cache.size());
}

test "BytecodeCache: concurrent-insert collapses to one entry" {
    var cache: BytecodeCache = .{ .allocator = testing.allocator };
    defer cache.deinit();

    const h: [64]u8 = [_]u8{'b'} ** 64;
    const bytes_a = try testing.allocator.dupe(u8, "first");
    const bb_a = try cache.insert(&h, bytes_a);

    // Simulate a racing insert: second call sees the existing entry,
    // frees its bytes, returns the original with a bumped refcount.
    const bytes_b = try testing.allocator.dupe(u8, "second");
    const bb_b = try cache.insert(&h, bytes_b);
    try testing.expectEqual(bb_a, bb_b);
    try testing.expectEqual(@as(u32, 2), bb_a.refcount.load(.acquire));
    try testing.expectEqual(@as(usize, 1), cache.size());

    cache.release(bb_b);
    cache.release(bb_a);
    try testing.expectEqual(@as(usize, 0), cache.size());
}
