//! rove-bodies — transport-layer body streaming buffer.
//!
//! Per `docs/readset-replication-plan.md` Phase 2. Every "body"-shaped
//! payload the handler observes (fetch response body, inbound request
//! body, streamed chunk) flows through a per-tenant in-memory buffer
//! that periodically flushes to a `BlobStore` as one S3 object per
//! batch. The raft entry's readset carries a `BodyRef = (batch_id,
//! offset, len)` pointer; the bytes never ride in the entry.
//!
//! Slice 2a (this commit): the data shape (`BodyRef`), the
//! single-tenant `BodyBuffer`, and `flush()` semantics. Per-worker
//! multiplexing (per-tenant sub-buffers + hash routing) is the next
//! slice. Wiring to the fetch + inbound paths comes after that.
//!
//! ## Addressing model
//!
//! Each tenant has a monotonic sequence of **batches**, identified by
//! `batch_id: u64` starting at 1. A batch accumulates bytes in RAM
//! until a flush trigger fires; on flush, the accumulated bytes are
//! PUT to `{tenant_prefix}/{batch_id}` as a single S3 object and the
//! next batch opens.
//!
//! A `BodyRef = (batch_id, offset, len)` names a range of bytes:
//!   - `batch_id` selects the S3 object (the batch the bytes were
//!     appended into).
//!   - `offset` is the **in-batch** byte offset (relative to that
//!     batch's start), NOT a tenant-global byte position. To GET
//!     the bytes: `BlobStore.getRange(key, offset, len)`.
//!   - `len` is the byte length.
//!
//! `last_flushed_batch_id` is the buffer's "durable_offset" analogue:
//! a `BodyRef` is durable iff `ref.batch_id <= last_flushed_batch_id`
//! (the whole batch published atomically as one PUT).
//!
//! ## Lifetime
//!
//! Bytes live in RAM from `append` through the flush that publishes
//! them. After the flush PUT acks, bytes drop from RAM — they remain
//! readable via `BlobStore.getRange`. A live activation that wants
//! its bytes still in RAM must run **after** the callback fires
//! (post-flush) and read via the slower S3 GET path. The live-read
//! RAM cache is a later optimization.
//!
//! ## Concurrency
//!
//! `BodyBuffer` is single-threaded — owned by a worker thread,
//! appended from the same thread that drives H2 / curl_multi event
//! delivery. The flush PUT itself can block on S3; that's the worker
//! poll's responsibility to handle (async via the existing
//! BatchStore push path, or sync on a dedicated thread). This module
//! exposes `flush()` as a blocking call against a generic
//! `BlobStore` so callers can wrap it however they like.

const std = @import("std");
const blob_mod = @import("rove-blob");

/// Sentinel batch id reserved for "no batch ever flushed." Real
/// batch ids start at 1.
pub const NO_BATCH: u64 = 0;

/// Default size threshold (1 MB) — per
/// `docs/readset-replication-plan.md` §4.3.
pub const DEFAULT_FLUSH_SIZE_BYTES: usize = 1 * 1024 * 1024;

/// Default time threshold (100 ms in nanoseconds) — per §4.3.
pub const DEFAULT_FLUSH_INTERVAL_NS: i64 = 100 * std.time.ns_per_ms;

/// Pointer to a range of bytes the handler observed, stored
/// out-of-band of the raft entry. The bytes live in S3 at
/// `{tenant_prefix}/{batch_id}` once the referenced batch has been
/// flushed; before flush, they live in the buffer's RAM.
pub const BodyRef = struct {
    /// Monotonic per-tenant batch id, starting at 1. `0` is a
    /// reserved sentinel meaning "no body" (callers can use
    /// `len == 0 and batch_id == NO_BATCH` to indicate an absent
    /// body without optional-wrapping).
    batch_id: u64,
    /// Byte offset within the batch object (NOT a tenant-global
    /// counter). The bytes at `[offset, offset+len)` in the
    /// `{tenant_prefix}/{batch_id}` object are this body's payload.
    offset: u64,
    /// Byte length. `u32` cap is 4 GiB which is well above the
    /// per-body cap any handler can produce (the per-batch cap is
    /// far smaller).
    len: u32,
};

/// Single-tenant in-memory body buffer. Holds the current open
/// batch in RAM; `flush(store, key)` publishes it to a `BlobStore`
/// and opens the next batch.
///
/// Callers configure the per-tenant S3 key prefix once at
/// construction; the buffer builds the per-batch key on flush.
/// Tests can use a `MemoryBlobStore`-style fixture (see
/// `BlobStore.VTable`).
///
/// ## Concurrency
///
/// Thread-safe via an internal mutex. The flush PUT releases the
/// mutex around the slow S3 call (toOwnedSlice → unlock → PUT →
/// lock → mark durable) so the worker thread can keep appending
/// while a previous batch is in flight. The producer (`append`)
/// and the consumer (`flush`) are typically on different threads:
/// the worker thread appends in `fireFetchEventActivation`; the
/// log-flusher thread drives `flush` on the periodic tick.
pub const BodyBuffer = struct {
    allocator: std.mem.Allocator,
    /// Guards every mutable field below. Held briefly for
    /// `append` / threshold checks; released across the slow PUT
    /// in `flush` so producers aren't blocked on S3 RTT.
    mutex: std.Thread.Mutex = .{},
    /// In-RAM accumulator for the currently-open batch. Cleared on
    /// each successful flush via `toOwnedSlice` (cheap — the slice
    /// goes straight to the PUT path; capacity returns on the next
    /// append).
    current_bytes: std.ArrayList(u8) = .empty,
    /// Id assigned to the currently-open batch. The first batch is
    /// id 1; the next-id starts at 1 and is bumped on every flush.
    /// Read-only externally — use `currentBatchId()` if needed.
    current_batch_id: u64 = 1,
    /// Id of the most-recently-flushed batch. `NO_BATCH` until the
    /// first successful flush. Callbacks waiting on a body are
    /// durable iff `ref.batch_id <= last_flushed_batch_id`.
    last_flushed_batch_id: u64 = NO_BATCH,
    /// Wall-clock nanoseconds of the most recent flush completion.
    /// Combined with `flush_interval_ns` to drive time-based flush
    /// scheduling.
    last_flush_ns: i64 = 0,
    /// Flush thresholds. Defaults match the plan; tests override
    /// via `init` config.
    flush_size_bytes: usize = DEFAULT_FLUSH_SIZE_BYTES,
    flush_interval_ns: i64 = DEFAULT_FLUSH_INTERVAL_NS,

    pub const Config = struct {
        flush_size_bytes: usize = DEFAULT_FLUSH_SIZE_BYTES,
        flush_interval_ns: i64 = DEFAULT_FLUSH_INTERVAL_NS,
        /// Caller's choice for the initial reference wall-clock —
        /// `shouldFlushByTime` compares against this. Production
        /// callers pass `std.time.nanoTimestamp()`; tests pass a
        /// fixed value for determinism.
        now_ns: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) BodyBuffer {
        return .{
            .allocator = allocator,
            .flush_size_bytes = cfg.flush_size_bytes,
            .flush_interval_ns = cfg.flush_interval_ns,
            .last_flush_ns = cfg.now_ns,
        };
    }

    pub fn deinit(self: *BodyBuffer) void {
        self.current_bytes.deinit(self.allocator);
    }

    /// Append `bytes` to the current open batch and return a
    /// `BodyRef` naming the range. The returned ref is stable —
    /// once minted, the bytes will end up in the named
    /// `(batch_id, offset, len)` regardless of subsequent appends
    /// to the same batch.
    ///
    /// Thread-safe — takes the buffer mutex.
    ///
    /// Errors: OutOfMemory (ArrayList expansion failed).
    pub fn append(self: *BodyBuffer, bytes: []const u8) !BodyRef {
        self.mutex.lock();
        defer self.mutex.unlock();
        const offset = self.current_bytes.items.len;
        try self.current_bytes.appendSlice(self.allocator, bytes);
        return .{
            .batch_id = self.current_batch_id,
            .offset = offset,
            .len = @intCast(bytes.len),
        };
    }

    /// True iff the current open batch has accumulated at least
    /// `flush_size_bytes`. Thread-safe — takes the buffer mutex.
    pub fn shouldFlushBySize(self: *BodyBuffer) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_bytes.items.len >= self.flush_size_bytes;
    }

    /// True iff at least `flush_interval_ns` has elapsed since the
    /// last flush AND the current batch has at least one byte to
    /// flush. Empty-batch ticks are skipped (no point in PUT-ing
    /// an empty object). Thread-safe.
    pub fn shouldFlushByTime(self: *BodyBuffer, now_ns: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.current_bytes.items.len == 0) return false;
        return (now_ns - self.last_flush_ns) >= self.flush_interval_ns;
    }

    /// Bytes accumulated in the current open batch. Useful for
    /// metrics + the RAM-cap signal that triggers backpressure
    /// (`docs/readset-replication-plan.md` §11.6 — not implemented
    /// in this slice). Thread-safe.
    pub fn pendingBytes(self: *BodyBuffer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_bytes.items.len;
    }

    /// Id of the currently-open batch. Pre-flush, this is the
    /// batch any `append` will write into. Thread-safe.
    pub fn currentBatchId(self: *BodyBuffer) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_batch_id;
    }

    /// Build the S3 key for batch `id`. `key_buf` must be at least
    /// 21 bytes (20 digits of u64 + NUL margin handled internally).
    /// Returns a slice into `key_buf`.
    ///
    /// Format: zero-padded 20-digit decimal so lexical S3 LIST
    /// order matches batch-id order. Same shape choice
    /// `log_server/flush_writer.zig` makes for log batch ids.
    pub fn batchKey(id: u64, key_buf: []u8) []u8 {
        return std.fmt.bufPrint(key_buf, "{d:0>20}", .{id}) catch unreachable;
    }

    /// Publish the current open batch to `store` and open the next
    /// one. Empty current batch is a no-op (returns NO_BATCH).
    ///
    /// Thread-safe with a lock-release pattern around the slow
    /// PUT: takes the mutex briefly to claim the bytes + mint the
    /// next batch_id, releases for the network call, re-takes
    /// briefly to advance `last_flushed_batch_id`. Concurrent
    /// `append` calls on the producer thread are blocked only
    /// during the two short critical sections.
    ///
    /// On PUT failure the bytes are **lost** (same lossy posture
    /// as the log-batch flush — `docs/logs-plan.md`). A warning
    /// is the caller's responsibility; the buffer continues with
    /// the next batch.
    ///
    /// Returns the batch id that was just published (or NO_BATCH
    /// if nothing was flushed).
    pub fn flush(
        self: *BodyBuffer,
        store: blob_mod.BlobStore,
        now_ns: i64,
    ) !u64 {
        // Claim the current bytes + mint the next batch_id under
        // the mutex. `toOwnedSlice` transfers the backing buffer;
        // `current_bytes` resets to empty and re-allocs on the
        // next append.
        var flushed_id: u64 = NO_BATCH;
        var bytes_owned: []u8 = &.{};
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.current_bytes.items.len == 0) return NO_BATCH;
            flushed_id = self.current_batch_id;
            bytes_owned = try self.current_bytes.toOwnedSlice(self.allocator);
            self.current_batch_id += 1;
        }
        defer self.allocator.free(bytes_owned);

        var key_buf: [21]u8 = undefined;
        const key = batchKey(flushed_id, &key_buf);

        // Slow path: PUT outside the lock so concurrent appends
        // aren't blocked by S3 RTT.
        try store.put(key, bytes_owned);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_flushed_batch_id = flushed_id;
        self.last_flush_ns = now_ns;
        return flushed_id;
    }

    /// Predicate for the §5.1 callback gate: true iff every byte
    /// referenced by `ref` is durable in stable storage.
    /// Thread-safe.
    pub fn isDurable(self: *BodyBuffer, ref: BodyRef) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return ref.batch_id != NO_BATCH and ref.batch_id <= self.last_flushed_batch_id;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// In-memory blob store fixture — mirrors the test fixtures in
/// `log_server/batch_store.zig` but for the simpler `BlobStore`
/// vtable surface. Local to this module since other test fixtures
/// use the hierarchical-key `BatchStore` instead.
const MemBlobStore = struct {
    allocator: std.mem.Allocator,
    objects: std.StringHashMapUnmanaged([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) MemBlobStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MemBlobStore) void {
        var it = self.objects.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.objects.deinit(self.allocator);
    }

    fn putImpl(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const bytes_copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(bytes_copy);
        const gop = try self.objects.getOrPut(self.allocator, key_copy);
        if (gop.found_existing) {
            self.allocator.free(key_copy);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = bytes_copy;
    }

    fn getImpl(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        const v = self.objects.get(key) orelse return blob_mod.Error.NotFound;
        return try allocator.dupe(u8, v);
    }

    fn existsImpl(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        return self.objects.contains(key);
    }

    fn deleteImpl(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        if (self.objects.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    const vtable: blob_mod.BlobStore.VTable = .{
        .put = putImpl,
        .get = getImpl,
        .exists = existsImpl,
        .delete = deleteImpl,
    };

    fn blobStore(self: *MemBlobStore) blob_mod.BlobStore {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "append: returns BodyRef pointing at the current open batch" {
    var buf = BodyBuffer.init(testing.allocator, .{});
    defer buf.deinit();

    const ref0 = try buf.append("hello");
    try testing.expectEqual(@as(u64, 1), ref0.batch_id);
    try testing.expectEqual(@as(u64, 0), ref0.offset);
    try testing.expectEqual(@as(u32, 5), ref0.len);

    const ref1 = try buf.append("world!");
    try testing.expectEqual(@as(u64, 1), ref1.batch_id);
    try testing.expectEqual(@as(u64, 5), ref1.offset);
    try testing.expectEqual(@as(u32, 6), ref1.len);

    try testing.expectEqual(@as(usize, 11), buf.pendingBytes());
    try testing.expectEqual(@as(u64, NO_BATCH), buf.last_flushed_batch_id);
}

test "flush: publishes one object, bumps batch id, clears pending" {
    var buf = BodyBuffer.init(testing.allocator, .{});
    defer buf.deinit();

    var mem = MemBlobStore.init(testing.allocator);
    defer mem.deinit();

    _ = try buf.append("abc");
    _ = try buf.append("def");

    const flushed = try buf.flush(mem.blobStore(), 1000);
    try testing.expectEqual(@as(u64, 1), flushed);
    try testing.expectEqual(@as(u64, 1), buf.last_flushed_batch_id);
    try testing.expectEqual(@as(u64, 2), buf.currentBatchId());
    try testing.expectEqual(@as(usize, 0), buf.pendingBytes());

    // S3 object exists at the expected key with the appended bytes.
    var key_buf: [21]u8 = undefined;
    const key = BodyBuffer.batchKey(1, &key_buf);
    try testing.expectEqualStrings("00000000000000000001", key);
    const bytes = try mem.blobStore().get(key, testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("abcdef", bytes);
}

test "flush: empty buffer is a no-op" {
    var buf = BodyBuffer.init(testing.allocator, .{});
    defer buf.deinit();
    var mem = MemBlobStore.init(testing.allocator);
    defer mem.deinit();

    const flushed = try buf.flush(mem.blobStore(), 1000);
    try testing.expectEqual(@as(u64, NO_BATCH), flushed);
    try testing.expectEqual(@as(u64, NO_BATCH), buf.last_flushed_batch_id);
    try testing.expectEqual(@as(u64, 1), buf.currentBatchId());
}

test "flush: two consecutive flushes produce two batches" {
    var buf = BodyBuffer.init(testing.allocator, .{});
    defer buf.deinit();
    var mem = MemBlobStore.init(testing.allocator);
    defer mem.deinit();

    const r1 = try buf.append("first");
    _ = try buf.flush(mem.blobStore(), 1000);
    const r2 = try buf.append("second");
    _ = try buf.flush(mem.blobStore(), 2000);

    try testing.expectEqual(@as(u64, 1), r1.batch_id);
    try testing.expectEqual(@as(u64, 2), r2.batch_id);
    try testing.expectEqual(@as(u64, 2), buf.last_flushed_batch_id);

    var key_buf: [21]u8 = undefined;
    const k1 = BodyBuffer.batchKey(1, &key_buf);
    const b1 = try mem.blobStore().get(k1, testing.allocator);
    defer testing.allocator.free(b1);
    try testing.expectEqualStrings("first", b1);

    var key_buf2: [21]u8 = undefined;
    const k2 = BodyBuffer.batchKey(2, &key_buf2);
    const b2 = try mem.blobStore().get(k2, testing.allocator);
    defer testing.allocator.free(b2);
    try testing.expectEqualStrings("second", b2);
}

test "shouldFlushBySize: fires at threshold" {
    var buf = BodyBuffer.init(testing.allocator, .{ .flush_size_bytes = 8 });
    defer buf.deinit();

    _ = try buf.append("1234");
    try testing.expect(!buf.shouldFlushBySize());
    _ = try buf.append("567");
    try testing.expect(!buf.shouldFlushBySize());
    _ = try buf.append("8");
    try testing.expect(buf.shouldFlushBySize());
}

test "shouldFlushByTime: respects interval, skips empty buffer" {
    var buf = BodyBuffer.init(testing.allocator, .{
        .flush_interval_ns = 100,
        .now_ns = 0,
    });
    defer buf.deinit();

    // Empty buffer: never flushes by time, no matter how late.
    try testing.expect(!buf.shouldFlushByTime(1_000_000));

    _ = try buf.append("x");
    // Still inside the interval.
    try testing.expect(!buf.shouldFlushByTime(50));
    // Past the interval.
    try testing.expect(buf.shouldFlushByTime(100));
    try testing.expect(buf.shouldFlushByTime(99999));
}

test "isDurable: gate predicate matches batch publication order" {
    var buf = BodyBuffer.init(testing.allocator, .{});
    defer buf.deinit();
    var mem = MemBlobStore.init(testing.allocator);
    defer mem.deinit();

    const r1 = try buf.append("batch-1-body");
    try testing.expect(!buf.isDurable(r1)); // pre-flush

    _ = try buf.flush(mem.blobStore(), 1000);
    try testing.expect(buf.isDurable(r1)); // post-flush

    const r2 = try buf.append("batch-2-body");
    try testing.expect(buf.isDurable(r1)); // still durable
    try testing.expect(!buf.isDurable(r2)); // newer batch not yet flushed

    _ = try buf.flush(mem.blobStore(), 2000);
    try testing.expect(buf.isDurable(r1));
    try testing.expect(buf.isDurable(r2));
}

test "isDurable: NO_BATCH ref is never durable" {
    var buf = BodyBuffer.init(testing.allocator, .{});
    defer buf.deinit();

    var mem = MemBlobStore.init(testing.allocator);
    defer mem.deinit();

    _ = try buf.append("x");
    _ = try buf.flush(mem.blobStore(), 0);

    try testing.expect(!buf.isDurable(.{ .batch_id = NO_BATCH, .offset = 0, .len = 0 }));
}

test "batchKey: zero-padded for lexical S3 LIST order" {
    var b1: [21]u8 = undefined;
    var b2: [21]u8 = undefined;
    var b3: [21]u8 = undefined;
    try testing.expectEqualStrings("00000000000000000001", BodyBuffer.batchKey(1, &b1));
    try testing.expectEqualStrings("00000000000000000042", BodyBuffer.batchKey(42, &b2));
    try testing.expectEqualStrings("18446744073709551615", BodyBuffer.batchKey(std.math.maxInt(u64), &b3));
}
