//! static_cache.zig — process-wide, byte-bounded LRU of static-asset
//! bytes, keyed by content hash. See docs/static-asset-serving.md.
//!
//! Content-addressing makes entries immutable (same hash ⇒ same bytes),
//! so there is no invalidation and identical assets dedupe across tenants
//! and deployments. The cache is written by the deployment-loader thread
//! (prewarm, `put`) and read by worker dispatch threads (`getCopy`), under
//! one mutex.
//!
//! v1 keeps it simple: `getCopy` copies the bytes into the caller's
//! per-request allocator under the lock, so the response owns its copy
//! (freed after send) — no entry refcounting / lifetime coupling. The copy
//! is memory-only (never I/O). If the single lock contends under load, the
//! follow-ups are lock sharding and/or refcounted zero-copy entries with a
//! release-on-response-completion hook (docs §2).

const std = @import("std");
const files_mod = @import("rove-files");

pub const HASH_HEX_LEN = files_mod.HASH_HEX_LEN; // 64

/// Largest single asset the LRU will hold. Bigger assets are skipped (they
/// take the stream path) so the worker never holds a huge blob in RAM and the
/// cache stays useful for the many-small case. Mirrors the loader-side prewarm
/// cap + the read-through tee's accumulation bound.
pub const PER_ASSET_MAX_BYTES: usize = 4 << 20;

/// One cached asset. Heap-owned by the cache; `bytes` is an owned copy. The
/// content-type is NOT stored — both serve paths carry the authoritative type
/// from the deployment manifest (the LRU is just hash→bytes). `prev`/`next`
/// thread the LRU list (head = MRU).
const Entry = struct {
    hash_hex: [HASH_HEX_LEN]u8,
    bytes: []u8,
    prev: ?*Entry = null,
    next: ?*Entry = null,
};

/// What `getCopy` hands back — the bytes live in the caller's allocator.
pub const Hit = struct {
    bytes: []u8,
};

pub const StaticCache = struct {
    mu: std.Thread.Mutex = .{},
    map: std.StringHashMapUnmanaged(*Entry) = .empty,
    head: ?*Entry = null, // MRU
    tail: ?*Entry = null, // LRU
    total_bytes: usize = 0,
    cap_bytes: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cap_bytes: usize) StaticCache {
        return .{ .cap_bytes = cap_bytes, .allocator = allocator };
    }

    pub fn deinit(self: *StaticCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |e_ptr| self.freeEntry(e_ptr.*);
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeEntry(self: *StaticCache, e: *Entry) void {
        self.allocator.free(e.bytes);
        self.allocator.destroy(e);
    }

    // ── intrusive LRU list helpers (caller holds the lock) ──────────────
    fn unlink(self: *StaticCache, e: *Entry) void {
        if (e.prev) |p| p.next = e.next else self.head = e.next;
        if (e.next) |n| n.prev = e.prev else self.tail = e.prev;
        e.prev = null;
        e.next = null;
    }

    fn pushFront(self: *StaticCache, e: *Entry) void {
        e.prev = null;
        e.next = self.head;
        if (self.head) |h| h.prev = e;
        self.head = e;
        if (self.tail == null) self.tail = e;
    }

    fn touch(self: *StaticCache, e: *Entry) void {
        if (self.head == e) return;
        self.unlink(e);
        self.pushFront(e);
    }

    /// Insert `bytes` under `hash_hex` (an owned copy is made). Idempotent: a
    /// present hash is just promoted to MRU (same content, content-addressed).
    /// Oversized blobs (> the per-asset cap or the whole cache) are skipped —
    /// they take the stream path. Called off the dispatch loop (loader thread
    /// prewarm) or from the read-through tee on the fetch-engine thread.
    pub fn put(
        self: *StaticCache,
        hash_hex: []const u8,
        bytes: []const u8,
    ) !void {
        if (hash_hex.len != HASH_HEX_LEN) return;
        if (bytes.len > PER_ASSET_MAX_BYTES or bytes.len > self.cap_bytes) return;

        self.mu.lock();
        defer self.mu.unlock();

        if (self.map.get(hash_hex)) |e| {
            self.touch(e);
            return;
        }

        const e = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(e);
        @memcpy(&e.hash_hex, hash_hex[0..HASH_HEX_LEN]);
        e.bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(e.bytes);
        e.prev = null;
        e.next = null;

        // Key is the entry's own hash_hex — stable for the entry's life,
        // and removed from the map before the entry is freed.
        try self.map.put(self.allocator, &e.hash_hex, e);
        self.pushFront(e);
        self.total_bytes += e.bytes.len;

        self.evictToFit();
    }

    /// Evict from the LRU tail until within cap. Caller holds the lock.
    fn evictToFit(self: *StaticCache) void {
        while (self.total_bytes > self.cap_bytes) {
            const victim = self.tail orelse break;
            self.unlink(victim);
            _ = self.map.remove(&victim.hash_hex);
            self.total_bytes -= victim.bytes.len;
            self.freeEntry(victim);
        }
    }

    /// Look up `hash_hex`; on hit, copy the bytes into `out` and promote to
    /// MRU. Returns null on miss. The copy lets the response own its bytes
    /// independent of later eviction.
    pub fn getCopy(
        self: *StaticCache,
        hash_hex: []const u8,
        out: std.mem.Allocator,
    ) !?Hit {
        if (hash_hex.len != HASH_HEX_LEN) return null;
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.map.get(hash_hex) orelse return null;
        self.touch(e);
        const bytes = try out.dupe(u8, e.bytes);
        return .{ .bytes = bytes };
    }
};

// ── process-wide singleton ─────────────────────────────────────────────
// Configured once by REWIND_STATIC_CACHE_MB (default 256; 0 disables).

var g_cache: ?*StaticCache = null;
var g_done = std.atomic.Value(bool).init(false);
var g_mu: std.Thread.Mutex = .{};

fn capBytesFromEnv() usize {
    const s = std.posix.getenv("REWIND_STATIC_CACHE_MB") orelse return 256 << 20;
    const t = std.mem.trim(u8, s, " \t\n");
    const mb = std.fmt.parseInt(usize, t, 10) catch {
        std.log.warn("rove-js static_cache: bad REWIND_STATIC_CACHE_MB={s}, using 256", .{t});
        return 256 << 20;
    };
    return mb << 20;
}

/// The shared cache, or null when disabled (REWIND_STATIC_CACHE_MB=0) or
/// if initialization failed (caller falls back to the redirect path).
pub fn instance() ?*StaticCache {
    if (g_done.load(.acquire)) return g_cache;
    g_mu.lock();
    defer g_mu.unlock();
    if (g_done.load(.acquire)) return g_cache;
    defer g_done.store(true, .release);

    const cap = capBytesFromEnv();
    if (cap == 0) return null;
    const c = std.heap.c_allocator.create(StaticCache) catch |err| {
        std.log.warn("rove-js static_cache: init failed: {s}", .{@errorName(err)});
        return null;
    };
    c.* = StaticCache.init(std.heap.c_allocator, cap);
    g_cache = c;
    return g_cache;
}

// ── tests ──────────────────────────────────────────────────────────────
const testing = std.testing;

fn mkhash(comptime n: u8) [HASH_HEX_LEN]u8 {
    return @splat(n);
}

test "put/getCopy round-trips and copies into the caller allocator" {
    var c = StaticCache.init(testing.allocator, 1 << 20);
    defer c.deinit();
    const key = mkhash('a');
    try c.put(&key, "body{}");
    const hit = (try c.getCopy(&key, testing.allocator)).?;
    defer testing.allocator.free(hit.bytes);
    try testing.expectEqualStrings("body{}", hit.bytes);
}

test "miss returns null" {
    var c = StaticCache.init(testing.allocator, 1 << 20);
    defer c.deinit();
    const key = mkhash('z');
    try testing.expect((try c.getCopy(&key, testing.allocator)) == null);
}

test "put is idempotent for a present hash (content-addressed)" {
    var c = StaticCache.init(testing.allocator, 1 << 20);
    defer c.deinit();
    const key = mkhash('a');
    try c.put(&key, "body{}");
    try c.put(&key, "body{}");
    try testing.expectEqual(@as(usize, 6), c.total_bytes); // not doubled
    try testing.expectEqual(@as(u32, 1), c.map.count());
}

test "LRU evicts the least-recently-used to stay within cap" {
    // cap = 10 bytes; three 4-byte entries → the third evicts the LRU.
    var c = StaticCache.init(testing.allocator, 10);
    defer c.deinit();
    const a = mkhash('a');
    const b = mkhash('b');
    const d = mkhash('d');
    try c.put(&a, "aaaa");
    try c.put(&b, "bbbb");
    // touch a so b is the LRU
    {
        const hit = (try c.getCopy(&a, testing.allocator)).?;
        testing.allocator.free(hit.bytes);
    }
    try c.put(&d, "dddd"); // 12 > 10 → evict LRU (b)
    try testing.expect((try c.getCopy(&b, testing.allocator)) == null);
    const ha = (try c.getCopy(&a, testing.allocator)).?;
    testing.allocator.free(ha.bytes);
    const hd = (try c.getCopy(&d, testing.allocator)).?;
    testing.allocator.free(hd.bytes);
    try testing.expect(c.total_bytes <= 10);
}

test "oversized blob (> cap) is skipped" {
    var c = StaticCache.init(testing.allocator, 4);
    defer c.deinit();
    const key = mkhash('a');
    try c.put(&key, "toolong"); // 7 > 4
    try testing.expect((try c.getCopy(&key, testing.allocator)) == null);
    try testing.expectEqual(@as(usize, 0), c.total_bytes);
}
