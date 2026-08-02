// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `ReservationAllocator` — the globally-unique `batch_id` source for the blob
//! coordinator, extracted from `coordinator.zig` (it never touches bytes).
//!
//! A `batch_id` names a pooled blob object (`{key_prefix_base}_pool/{id:0>20}`)
//! and must be globally unique across the cluster. Production mints them from
//! raft-reserved blocks: a `ReservationProvider` proposes "reserve N ids past
//! `prev_end`" through consensus and returns the new block's exclusive end. This
//! allocator hands out ids from the `current` block and keeps an `upcoming`
//! block warm — a background refill thread reserves the next block once the
//! current one crosses a low-watermark, so `nextBatchId` almost never blocks.
//! With no provider (tests / single-process) it falls back to a local atomic
//! counter.
//!
//! The double-buffered `current`/`upcoming` refill is the trickiest concurrency
//! in the coordinator; as its own struct it gets a `nextBatchId()` seam that a
//! test can drive directly.

const std = @import("std");

/// Provider of globally-unique `batch_id` blocks. `reserveFn(ctx, prev_end,
/// count)` reserves `count` ids strictly after `prev_end` and returns the new
/// block's exclusive end (so `[end - count, end)` is the reserved block). In
/// production this proposes `_system/coord_next_pool_batch` through raft.
pub const ReservationProvider = struct {
    ctx: *anyopaque,
    reserveFn: *const fn (ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64,
};

/// `nextBatchId` fails only when the allocator is shutting down (a parked
/// submitter is woken to unwind). Provider errors never surface here — the
/// refill loop retries them internally.
pub const Error = error{Shutdown};

/// One reserved half-open block `[base, end)`; `next` is the cursor.
const Reservation = struct { base: u64, next: u64, end: u64 };

pub const ReservationAllocator = struct {
    provider: ?ReservationProvider = null,
    block_size: u32 = 10_000,
    low_watermark_pct: u8 = 80,

    /// Local-mode source — used when `provider` is null. Starts at 1 (skips the
    /// `NO_BATCH = 0` sentinel the coordinator reserves).
    local_batch_ctr: std.atomic.Value(u64) = .init(1),

    /// Reservation state, guarded by `mu`. Only used when `provider` is non-null.
    mu: std.Thread.Mutex = .{},
    id_avail: std.Thread.Condition = .{},
    refill_cond: std.Thread.Condition = .{},
    current: Reservation = .{ .base = 0, .next = 0, .end = 0 },
    upcoming: ?Reservation = null,
    refill_needed: bool = false,
    refill_in_progress: bool = false,
    /// In-memory ceiling of every block ever reserved this process lifetime. The
    /// refill thread floors the next propose at this so back-to-back refills
    /// never overlap even on a slow propose path.
    prev_committed_end: u64 = 0,
    refill_thread: ?std.Thread = null,

    shutdown_flag: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    /// Configure the allocator and (in production) spawn the refill thread.
    /// Call once, IN PLACE — the thread captures `self`, so `self` must already
    /// be at its final address (embedded in the heap-allocated coordinator).
    pub fn start(self: *Self, provider: ?ReservationProvider, block_size: u32, low_watermark_pct: u8) !void {
        self.provider = provider;
        self.block_size = block_size;
        self.low_watermark_pct = low_watermark_pct;
        if (provider != null) {
            self.refill_thread = try std.Thread.spawn(.{}, refillLoop, .{self});
        }
    }

    /// Signal shutdown, wake the refill thread + any parked submitter, and join.
    /// Idempotent-safe only once (joins the thread).
    pub fn deinit(self: *Self) void {
        self.shutdown_flag.store(true, .release);
        self.mu.lock();
        self.refill_cond.broadcast();
        self.id_avail.broadcast();
        self.mu.unlock();
        if (self.refill_thread) |t| t.join();
    }

    /// Mint one batch_id. In local mode (`provider == null`) returns from an
    /// atomic counter. In production draws from the `current` block; blocks on
    /// `id_avail` if it's exhausted and the refill hasn't landed yet. Returns
    /// `Shutdown` if `deinit` fired while parked.
    pub fn nextBatchId(self: *Self) Error!u64 {
        if (self.provider == null) {
            return self.local_batch_ctr.fetchAdd(1, .monotonic);
        }

        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.shutdown_flag.load(.acquire)) return Error.Shutdown;
            if (self.current.next < self.current.end) {
                const id = self.current.next;
                self.current.next += 1;
                self.maybeKickRefillLocked();
                return id;
            }
            // Current exhausted; swap upcoming if available.
            if (self.upcoming) |up| {
                self.current = up;
                self.upcoming = null;
                continue;
            }
            // No block available; ensure refill is in flight + wait.
            if (!self.refill_in_progress and !self.refill_needed) {
                self.refill_needed = true;
                self.refill_cond.signal();
            }
            self.id_avail.wait(&self.mu);
        }
    }

    fn maybeKickRefillLocked(self: *Self) void {
        if (self.upcoming != null) return;
        if (self.refill_in_progress or self.refill_needed) return;
        const consumed = self.current.next - self.current.base;
        const block_size: u64 = self.block_size;
        const lwm = block_size * @as(u64, self.low_watermark_pct) / 100;
        if (consumed >= lwm) {
            self.refill_needed = true;
            self.refill_cond.signal();
        }
    }

    fn refillLoop(self: *Self) void {
        while (true) {
            self.mu.lock();
            while (!self.shutdown_flag.load(.acquire) and !self.refill_needed) {
                self.refill_cond.wait(&self.mu);
            }
            if (self.shutdown_flag.load(.acquire)) {
                self.mu.unlock();
                return;
            }
            self.refill_needed = false;
            self.refill_in_progress = true;
            const prev_end: u64 = if (self.upcoming) |up|
                up.end
            else if (self.current.end > self.prev_committed_end)
                self.current.end
            else
                self.prev_committed_end;
            self.mu.unlock();

            const provider = self.provider.?;
            const block_size: u32 = self.block_size;
            const new_end = provider.reserveFn(provider.ctx, prev_end, block_size) catch |err| {
                std.log.warn(
                    "rove-blob coordinator: reservation refill failed: {s}; retrying in 100ms",
                    .{@errorName(err)},
                );
                std.Thread.sleep(100 * std.time.ns_per_ms);
                self.mu.lock();
                self.refill_in_progress = false;
                self.refill_needed = true;
                self.refill_cond.signal();
                self.mu.unlock();
                continue;
            };
            std.debug.assert(new_end >= prev_end + block_size);
            const base = new_end - block_size;
            const block: Reservation = .{ .base = base, .next = base, .end = new_end };

            self.mu.lock();
            if (new_end > self.prev_committed_end) self.prev_committed_end = new_end;
            if (self.current.next >= self.current.end) {
                self.current = block;
            } else {
                // Current still has ids — stash as upcoming. If upcoming already
                // exists (shouldn't normally — refill only kicks one at a time),
                // drop the new block (its ids end up unused, harmless).
                if (self.upcoming == null) self.upcoming = block;
            }
            self.refill_in_progress = false;
            self.id_avail.broadcast();
            self.mu.unlock();
        }
    }
};

const testing = std.testing;

test "ReservationAllocator: local mode mints a monotonic counter from 1" {
    var r = ReservationAllocator{};
    try r.start(null, 10_000, 80);
    defer r.deinit();
    try testing.expectEqual(@as(u64, 1), try r.nextBatchId());
    try testing.expectEqual(@as(u64, 2), try r.nextBatchId());
    try testing.expectEqual(@as(u64, 3), try r.nextBatchId());
}

test "ReservationAllocator: provider mode mints contiguous ids across block refills" {
    // A test provider: reserve `count` ids past max(committed, prev_end, 1) —
    // mirrors the prod floor rule so blocks never start at the NO_BATCH=0
    // sentinel and never overlap.
    const P = struct {
        end: std.atomic.Value(u64) = .init(0),
        fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            const floor = @max(@max(s.end.load(.monotonic), prev_end), @as(u64, 1));
            const new_end = floor + count;
            s.end.store(new_end, .monotonic);
            return new_end;
        }
    };
    var p = P{};
    var r = ReservationAllocator{};
    try r.start(.{ .ctx = &p, .reserveFn = P.reserve }, 4, 80); // 4-id blocks
    defer r.deinit();

    // Five blocks' worth: ids are unique, strictly increasing, and (with the
    // low-watermark refill keeping `upcoming` warm) contiguous from 1.
    var i: u64 = 1;
    while (i <= 20) : (i += 1) {
        try testing.expectEqual(i, try r.nextBatchId());
    }
}
