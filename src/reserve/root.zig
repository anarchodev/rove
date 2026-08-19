// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `ReservationAllocator` — cluster-unique u64s handed out from
//! raft-reserved blocks.
//!
//! Some ids must be unique across the whole cluster and must stay unique
//! across a leader change: a leader that reissues an id another leader
//! already gave out corrupts whatever that id names. Proposing every id
//! through consensus would be correct and far too slow, so instead a
//! `ReservationProvider` proposes "reserve N ids past `prev_end`" once
//! per **block**, and ids come out of the block locally. A new leader
//! reserves a fresh block, so overlap is impossible by construction.
//!
//! The allocator hands out from `current` and keeps an `upcoming` block
//! warm — the next block is reserved once the current one crosses a low
//! watermark, so `next()` almost never blocks on consensus. With no
//! provider (tests, single process) it falls back to a local atomic
//! counter.
//!
//! ## Who runs the refill
//!
//! Two drives, same work. `owned_thread` gives the allocator its own
//! thread and suits ONE allocator per process — the blob coordinator's
//! `batch_id`, where a dedicated thread is self-contained and costs
//! nothing to reason about.
//!
//! `external` hands the steps to a caller through `needsRefill` /
//! `refillOnce`, for PER-TENANT allocators: the keyring's slot pool is
//! one allocator per tenant, and an owned thread there would be a thread
//! per tenant on a node built to host many of them. A small shared worker
//! set can then keep every tenant's pool warm.
//!
//! What must not diverge is the double-buffered handoff, which is the
//! trickiest concurrency here — so both drives run the same claim /
//! reserve / install steps rather than each carrying a copy.
//!
//! ## Callers
//!
//! The keyring's slot allocation, where a reissued slot would mean two
//! identities sharing one key — so shredding one would shred the other.
//!
//! Note what is NOT a caller: the body pool. An object there is named by
//! its own content, which removes the uniqueness problem rather than
//! coordinating it — no block to reserve, no counter to replay after a
//! restart, and nothing to get wrong at genesis. Reach for this
//! allocator only when the id must be unique AND cannot be derived from
//! what it names.
//!
//! Slot 0 is a sentinel, which is why `first_id` defaults to 1; it is
//! configurable because that is a property of the caller's id space,
//! not of this allocator.
//!
//! The double-buffered `current`/`upcoming` refill is the trickiest
//! concurrency here, which is exactly why it lives in one place with a
//! `next()` seam a test can drive directly rather than being written
//! twice.

const std = @import("std");

/// Provider of cluster-unique blocks. `reserveFn(ctx, prev_end, count)`
/// reserves `count` ids strictly after `prev_end` and returns the new
/// block's exclusive end, so `[end - count, end)` is the reserved block.
/// In production this proposes a counter key through raft.
pub const ReservationProvider = struct {
    ctx: *anyopaque,
    reserveFn: *const fn (ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64,
};

/// `next` fails only when the allocator is shutting down (a parked
/// caller is woken to unwind). Provider errors never surface here — the
/// refill loop retries them internally.
pub const Error = error{Shutdown};

/// Who runs the refill.
pub const Drive = enum {
    /// The allocator owns a thread. Right when there is ONE allocator
    /// per process — the blob coordinator's `batch_id` — where a
    /// dedicated thread is self-contained and costs nothing to reason
    /// about.
    owned_thread,
    /// A caller drives refills through `needsRefill` / `refillOnce`.
    ///
    /// For PER-TENANT allocators, where an owned thread would mean a
    /// thread per tenant on a node built to host many of them. The work
    /// is unchanged — the same reserve, the same double buffering — only
    /// who executes it moves, so a small shared worker set can keep
    /// every tenant's pool warm.
    external,
};

pub const Config = struct {
    /// `null` selects local mode: a process-local counter, no consensus.
    provider: ?ReservationProvider = null,
    block_size: u32 = 10_000,
    /// Percentage of a block consumed before the next one is reserved.
    low_watermark_pct: u8 = 80,
    /// First id in local mode. 1 by default because every caller so far
    /// reserves 0 as a sentinel.
    first_id: u64 = 1,
    /// Used only in the refill-failure log line, so an operator can tell
    /// which id space is starving.
    label: []const u8 = "reservation",
    /// Defaults to the owned thread, so existing callers are unchanged.
    drive: Drive = .owned_thread,
};

/// One reserved half-open block `[base, end)`; `next` is the cursor.
const Reservation = struct { base: u64, next: u64, end: u64 };

pub const ReservationAllocator = struct {
    cfg: Config = .{},

    /// Local-mode source — used when `cfg.provider` is null.
    local_ctr: std.atomic.Value(u64) = .init(0),

    /// Reservation state, guarded by `mu`. Only used with a provider.
    mu: std.Thread.Mutex = .{},
    id_avail: std.Thread.Condition = .{},
    refill_cond: std.Thread.Condition = .{},
    current: Reservation = .{ .base = 0, .next = 0, .end = 0 },
    upcoming: ?Reservation = null,
    refill_needed: bool = false,
    refill_in_progress: bool = false,
    /// In-memory ceiling of every block ever reserved this process
    /// lifetime. The refill thread floors the next propose at this so
    /// back-to-back refills never overlap even on a slow propose path.
    prev_committed_end: u64 = 0,
    refill_thread: ?std.Thread = null,

    shutdown_flag: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    /// Configure and (with a provider) spawn the refill thread. Call
    /// once, IN PLACE — the thread captures `self`, so `self` must
    /// already be at its final address.
    pub fn start(self: *Self, cfg: Config) !void {
        self.cfg = cfg;
        self.local_ctr = .init(cfg.first_id);
        if (cfg.provider != null and cfg.drive == .owned_thread) {
            self.refill_thread = try std.Thread.spawn(.{}, refillLoop, .{self});
        }
    }

    /// Is a block wanted right now? The driver's poll in external mode.
    ///
    /// False while one is already being reserved, so two drivers cannot
    /// both take the same pending refill.
    pub fn needsRefill(self: *Self) bool {
        if (self.cfg.provider == null) return false;
        self.mu.lock();
        defer self.mu.unlock();
        return self.refill_needed and !self.refill_in_progress;
    }

    /// Reserve at most one block. True when one was installed, false
    /// when nothing was pending. Errors are the provider's, surfaced so
    /// the driver owns the backoff — it is the piece that knows how many
    /// other tenants are waiting on the same worker.
    ///
    /// External mode only, and safe to call from several drivers: the
    /// in-progress flag admits exactly one.
    pub fn refillOnce(self: *Self) anyerror!bool {
        std.debug.assert(self.cfg.drive == .external);
        const provider = self.cfg.provider orelse return false;

        self.mu.lock();
        if (self.shutdown_flag.load(.acquire) or !self.beginRefillLocked()) {
            self.mu.unlock();
            return false;
        }
        const prev_end = self.prevEndLocked();
        self.mu.unlock();

        const new_end = provider.reserveFn(provider.ctx, prev_end, self.cfg.block_size) catch |err| {
            self.abandonRefill();
            return err;
        };
        self.installBlock(new_end);
        return true;
    }

    /// Signal shutdown, wake the refill thread and any parked caller,
    /// and join. Safe once (it joins the thread).
    pub fn deinit(self: *Self) void {
        self.shutdown_flag.store(true, .release);
        self.mu.lock();
        self.refill_cond.broadcast();
        self.id_avail.broadcast();
        self.mu.unlock();
        if (self.refill_thread) |t| t.join();
    }

    /// Mint one id, **waiting** if no block has one yet.
    ///
    /// Only for callers that may block — a background thread, a
    /// low-rate control path. A caller on a poll loop must use
    /// `tryNext`: the wait here is unbounded, so on a shared event loop
    /// it stalls every tenant on the node, not just the request that
    /// needed an id.
    ///
    /// Returns `Shutdown` if `deinit` fired while parked.
    pub fn next(self: *Self) Error!u64 {
        if (self.cfg.provider == null) {
            return self.local_ctr.fetchAdd(1, .monotonic);
        }

        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.shutdown_flag.load(.acquire)) return Error.Shutdown;
            if (self.takeLocked()) |id| return id;
            self.kickRefillLocked();
            self.id_avail.wait(&self.mu);
        }
    }

    /// Mint one id if a block already has one, else `null`. **Never
    /// waits.**
    ///
    /// This is what a request path calls. `null` means "not right now"
    /// — the caller parks its work and retries on a later cycle rather
    /// than holding the loop. A refill is kicked on the way out, so the
    /// retry has something to find.
    ///
    /// It does take the allocator's mutex, which is held for a handful
    /// of field updates and never across I/O — bounded, unlike the
    /// condvar wait `next` can enter.
    ///
    /// `null` is also the shutdown answer: a caller that cannot wait has
    /// nothing useful to do with the distinction.
    pub fn tryNext(self: *Self) ?u64 {
        if (self.cfg.provider == null) {
            return self.local_ctr.fetchAdd(1, .monotonic);
        }

        self.mu.lock();
        defer self.mu.unlock();
        if (self.shutdown_flag.load(.acquire)) return null;
        if (self.takeLocked()) |id| return id;
        self.kickRefillLocked();
        return null;
    }

    /// Take an id from `current`, promoting `upcoming` when `current` is
    /// spent. Null when neither has one. Caller holds `mu`.
    fn takeLocked(self: *Self) ?u64 {
        while (true) {
            if (self.current.next < self.current.end) {
                const id = self.current.next;
                self.current.next += 1;
                self.maybeKickRefillLocked();
                return id;
            }
            const up = self.upcoming orelse return null;
            self.current = up;
            self.upcoming = null;
        }
    }

    /// Ask the refill thread for a block if one is not already coming.
    /// Caller holds `mu`.
    fn kickRefillLocked(self: *Self) void {
        if (self.refill_in_progress or self.refill_needed) return;
        self.refill_needed = true;
        self.refill_cond.signal();
    }

    fn maybeKickRefillLocked(self: *Self) void {
        if (self.upcoming != null) return;
        if (self.refill_in_progress or self.refill_needed) return;
        const consumed = self.current.next - self.current.base;
        const block_size: u64 = self.cfg.block_size;
        const lwm = block_size * @as(u64, self.cfg.low_watermark_pct) / 100;
        if (consumed >= lwm) {
            self.refill_needed = true;
            self.refill_cond.signal();
        }
    }

    /// Claim the pending refill. Caller holds `mu`. False when there is
    /// nothing to do or someone else already has it.
    fn beginRefillLocked(self: *Self) bool {
        if (!self.refill_needed or self.refill_in_progress) return false;
        self.refill_needed = false;
        self.refill_in_progress = true;
        return true;
    }

    /// Floor for the next reservation. Caller holds `mu`.
    fn prevEndLocked(self: *Self) u64 {
        if (self.upcoming) |up| return up.end;
        if (self.current.end > self.prev_committed_end) return self.current.end;
        return self.prev_committed_end;
    }

    /// Give the claim back so the refill is retried.
    fn abandonRefill(self: *Self) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.refill_in_progress = false;
        self.refill_needed = true;
        self.refill_cond.signal();
    }

    /// Install a freshly reserved block and wake anyone parked.
    fn installBlock(self: *Self, new_end: u64) void {
        const block_size: u64 = self.cfg.block_size;
        std.debug.assert(new_end >= block_size);
        const base = new_end - block_size;
        const block: Reservation = .{ .base = base, .next = base, .end = new_end };

        self.mu.lock();
        defer self.mu.unlock();
        if (new_end > self.prev_committed_end) self.prev_committed_end = new_end;
        if (self.current.next >= self.current.end) {
            self.current = block;
        } else {
            // Current still has ids — stash as upcoming. If upcoming
            // already exists (shouldn't normally — refill only kicks
            // one at a time), drop the new block (its ids end up
            // unused, harmless).
            if (self.upcoming == null) self.upcoming = block;
        }
        self.refill_in_progress = false;
        self.id_avail.broadcast();
    }

    /// Owned-thread drive. The same claim / reserve / install steps
    /// `refillOnce` runs — deliberately one implementation, because the
    /// double-buffered handoff is the trickiest concurrency here and a
    /// second copy would drift from it.
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
            _ = self.beginRefillLocked();
            const prev_end = self.prevEndLocked();
            self.mu.unlock();

            const provider = self.cfg.provider.?;
            const new_end = provider.reserveFn(provider.ctx, prev_end, self.cfg.block_size) catch |err| {
                std.log.warn(
                    "rove-reserve: {s} refill failed: {s}; retrying in 100ms",
                    .{ self.cfg.label, @errorName(err) },
                );
                std.Thread.sleep(100 * std.time.ns_per_ms);
                self.abandonRefill();
                continue;
            };
            std.debug.assert(new_end >= prev_end + self.cfg.block_size);
            self.installBlock(new_end);
        }
    }
};

const testing = std.testing;

test "local mode mints a monotonic counter from first_id" {
    var r = ReservationAllocator{};
    try r.start(.{});
    defer r.deinit();
    try testing.expectEqual(@as(u64, 1), try r.next());
    try testing.expectEqual(@as(u64, 2), try r.next());
    try testing.expectEqual(@as(u64, 3), try r.next());
}

test "first_id is the caller's to choose" {
    var r = ReservationAllocator{};
    try r.start(.{ .first_id = 100 });
    defer r.deinit();
    try testing.expectEqual(@as(u64, 100), try r.next());
    try testing.expectEqual(@as(u64, 101), try r.next());
}

/// A test provider mirroring the production floor rule: reserve `count`
/// past `max(committed, prev_end, 1)`, so blocks never start at the 0
/// sentinel and never overlap.
const TestProvider = struct {
    end: std.atomic.Value(u64) = .init(0),
    calls: std.atomic.Value(u32) = .init(0),

    fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
        const s: *@This() = @ptrCast(@alignCast(ctx));
        _ = s.calls.fetchAdd(1, .monotonic);
        const floor = @max(@max(s.end.load(.monotonic), prev_end), @as(u64, 1));
        const new_end = floor + count;
        s.end.store(new_end, .monotonic);
        return new_end;
    }

    fn provider(self: *@This()) ReservationProvider {
        return .{ .ctx = self, .reserveFn = @This().reserve };
    }
};

test "provider mode mints contiguous ids across block refills" {
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4 }); // 4-id blocks
    defer r.deinit();

    // Five blocks' worth: unique, strictly increasing, and — with the
    // low-watermark refill keeping `upcoming` warm — contiguous from 1.
    var i: u64 = 1;
    while (i <= 20) : (i += 1) {
        try testing.expectEqual(i, try r.next());
    }
}

test "external drive owns no thread" {
    // The whole point: a per-tenant allocator must not cost a thread per
    // tenant on a node built to host many of them.
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4, .drive = .external });
    defer r.deinit();
    try testing.expect(r.refill_thread == null);
}

test "external drive: nothing is reserved until a driver runs" {
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4, .drive = .external });
    defer r.deinit();

    // Nothing wanted yet, so a driver poll costs nothing.
    try testing.expect(!r.needsRefill());
    try testing.expectEqual(@as(u32, 0), p.calls.load(.monotonic));

    // A hot-path miss asks for a block and does NOT wait for one.
    try testing.expect(r.tryNext() == null);
    try testing.expect(r.needsRefill());
    try testing.expectEqual(@as(u32, 0), p.calls.load(.monotonic));

    // The driver supplies it.
    try testing.expect(try r.refillOnce());
    try testing.expectEqual(@as(u32, 1), p.calls.load(.monotonic));
    try testing.expect(!r.needsRefill());
    try testing.expectEqual(@as(?u64, 1), r.tryNext());
}

test "external drive: refillOnce is a no-op when nothing is pending" {
    // A driver sweeping many tenants calls this on every one of them, so
    // the idle case must cost nothing and must not reserve a block that
    // nobody asked for — slots are never reused, so a wasted block is
    // permanently wasted.
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4, .drive = .external });
    defer r.deinit();

    try testing.expect(!try r.refillOnce());
    try testing.expectEqual(@as(u32, 0), p.calls.load(.monotonic));
}

test "external drive: a provider failure surfaces and leaves the refill pending" {
    // The driver owns the backoff, because it is the piece that knows how
    // many other tenants are waiting on the same worker. Swallowing the
    // error here would strand the pool with nobody aware it is starving.
    const Failing = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = prev_end;
            _ = count;
            _ = self.calls.fetchAdd(1, .monotonic);
            return error.NotLeader;
        }
    };
    var f = Failing{};
    var r = ReservationAllocator{};
    try r.start(.{
        .provider = .{ .ctx = &f, .reserveFn = Failing.reserve },
        .block_size = 4,
        .drive = .external,
    });
    defer r.deinit();

    try testing.expect(r.tryNext() == null);
    try testing.expectError(error.NotLeader, r.refillOnce());
    // Still wanted, so the driver comes back to it.
    try testing.expect(r.needsRefill());
    try testing.expectError(error.NotLeader, r.refillOnce());
    try testing.expectEqual(@as(u32, 2), f.calls.load(.monotonic));
}

test "external drive mints the same ids the owned thread would" {
    // Moving WHO runs the refill must not change WHAT comes out — same
    // double buffering, same contiguity, same no-reissue guarantee.
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4, .drive = .external });
    defer r.deinit();

    var got: [20]u64 = undefined;
    var n: usize = 0;
    var guard: usize = 0;
    while (n < got.len) {
        if (r.tryNext()) |id| {
            got[n] = id;
            n += 1;
        } else {
            _ = try r.refillOnce();
        }
        guard += 1;
        try testing.expect(guard < 200);
    }
    var i: usize = 0;
    while (i < got.len) : (i += 1) try testing.expectEqual(@as(u64, i + 1), got[i]);
}

test "external drive: a claimed refill is not handed to a second driver" {
    // Two workers sweeping the same tenant must not both reserve — the
    // loser's block would be dead ids, and slots are never reused.
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4, .drive = .external });
    defer r.deinit();

    try testing.expect(r.tryNext() == null);
    try testing.expect(r.needsRefill());

    r.mu.lock();
    try testing.expect(r.beginRefillLocked()); // stands in for driver A
    try testing.expect(!r.beginRefillLocked()); // driver B finds nothing
    r.mu.unlock();
    try testing.expect(!r.needsRefill());
    try testing.expect(!try r.refillOnce());
}

test "ids are never reissued across a simulated leader change" {
    // The property that matters: a second allocator taking over the same
    // id space must not hand back anything the first one did. A reissued
    // id would mean two things sharing one name.
    var p = TestProvider{};

    var first = ReservationAllocator{};
    try first.start(.{ .provider = p.provider(), .block_size = 8 });
    var seen: [12]u64 = undefined;
    for (&seen) |*slot| slot.* = try first.next();
    first.deinit();

    var second = ReservationAllocator{};
    try second.start(.{ .provider = p.provider(), .block_size = 8 });
    defer second.deinit();

    var j: usize = 0;
    while (j < 12) : (j += 1) {
        const id = try second.next();
        for (seen) |prior| try testing.expect(id != prior);
    }
}

test "a provider that fails is retried rather than surfacing to the caller" {
    // Refill failures are transient (a propose that lost leadership, a
    // quorum blip). A caller asking for an id should wait, not fail —
    // and must not be woken with a duplicate.
    const Flaky = struct {
        inner: TestProvider = .{},
        fail_first: std.atomic.Value(u32) = .init(3),

        fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.fail_first.load(.monotonic) > 0) {
                _ = s.fail_first.fetchSub(1, .monotonic);
                return error.NotLeader;
            }
            return TestProvider.reserve(&s.inner, prev_end, count);
        }
    };
    var f = Flaky{};
    var r = ReservationAllocator{};
    try r.start(.{
        .provider = .{ .ctx = &f, .reserveFn = Flaky.reserve },
        .block_size = 4,
    });
    defer r.deinit();

    try testing.expectEqual(@as(u64, 1), try r.next());
    try testing.expectEqual(@as(u64, 2), try r.next());
    try testing.expect(f.fail_first.load(.monotonic) == 0);
}

test "tryNext yields ids from a live block, and null once it is dry" {
    // A provider that serves exactly one block and then stalls, so the
    // pool is guaranteed to run dry.
    const OneBlock = struct {
        served: std.atomic.Value(u32) = .init(0),
        gate: std.Thread.ResetEvent = .{},
        fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.served.fetchAdd(1, .monotonic) > 0) {
                s.gate.wait();
                return error.Cancelled;
            }
            _ = prev_end;
            return 1 + count;
        }
    };
    var p = OneBlock{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = .{ .ctx = &p, .reserveFn = OneBlock.reserve }, .block_size = 4 });

    // The first block has to land before ids appear; `tryNext` never
    // waits for it, so poll rather than assuming.
    var first: ?u64 = null;
    var spins: usize = 0;
    while (first == null and spins < 200) : (spins += 1) {
        first = r.tryNext();
        if (first == null) std.Thread.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u64, 1), first.?);
    try testing.expectEqual(@as(u64, 2), r.tryNext().?);
    try testing.expectEqual(@as(u64, 3), r.tryNext().?);
    try testing.expectEqual(@as(u64, 4), r.tryNext().?);

    // Dry, and the next block will never come. The point of the test is
    // that this RETURNS — a blocking acquire here would hang the poll
    // loop and with it every tenant on the node.
    try testing.expect(r.tryNext() == null);
    try testing.expect(r.tryNext() == null);

    p.gate.set();
    r.deinit();
}

test "tryNext returns null under shutdown rather than an error" {
    // A caller that cannot wait has nothing useful to do with the
    // distinction between "empty" and "shutting down" — both mean park.
    var p = TestProvider{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = p.provider(), .block_size = 4 });
    r.shutdown_flag.store(true, .release);
    try testing.expect(r.tryNext() == null);
    r.deinit();
}

test "deinit unparks a caller waiting on an exhausted block" {
    // A provider that never returns: the parked caller must be released
    // by shutdown rather than hanging a joining thread forever.
    const Stalled = struct {
        gate: std.Thread.ResetEvent = .{},
        fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            _ = prev_end;
            _ = count;
            s.gate.wait();
            return error.Cancelled;
        }
    };
    var s = Stalled{};
    var r = ReservationAllocator{};
    try r.start(.{ .provider = .{ .ctx = &s, .reserveFn = Stalled.reserve }, .block_size = 4 });

    const Waiter = struct {
        fn run(alloc: *ReservationAllocator, out: *anyerror!u64) void {
            out.* = alloc.next();
        }
    };
    var result: anyerror!u64 = 0;
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ &r, &result });

    r.shutdown_flag.store(true, .release);
    r.mu.lock();
    r.id_avail.broadcast();
    r.mu.unlock();
    t.join();
    try testing.expectError(Error.Shutdown, result);

    s.gate.set();
    r.deinit();
}
