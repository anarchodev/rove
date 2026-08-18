// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The slot pool — where a tenant's keys are minted, and where they are
//! deliberately NOT minted.
//!
//! Sealing a value needs a key. Minting one needs a random draw, a
//! keyring rewrite with its fsync, and a quorum round trip to make it
//! durable. None of that belongs on raft commit, which is the most
//! latency-sensitive path in the system and already has a dedicated
//! thread keeping fsync out of its way.
//!
//! So keys are minted **ahead of demand** into a pool, and the request
//! path only takes a slot number that is already backed by a durable
//! key. Binding that slot to a customer identity is an ordinary kv
//! write riding the raft entry the request was already sending.
//!
//! ## The invariant
//!
//! **A slot is never handed out before its key is durable on a quorum.**
//!
//! If it were, a leader could seal data under a key, commit that data
//! through raft, and die — leaving a new leader holding data sealed
//! under a key that exists nowhere. That is unrecoverable, and it looks
//! exactly like data loss because it is.
//!
//! The invariant is structural here rather than enforced: preparing a
//! block *is* reserve-then-mint-then-replicate, and `ReservationAllocator`
//! only publishes a block once its provider returns. A provider that
//! fails publishes nothing, so a quorum outage stalls the pool instead
//! of handing out slots it cannot stand behind.
//!
//! ## The hot path never waits
//!
//! `tryAcquire` is what a request calls, and it returns `null` rather
//! than waiting for a refill. The worker is a poll loop, so a blocking
//! acquire would not slow the one request that needed a slot — it would
//! stop serving every tenant on the node. `null` means park and retry,
//! which is what the hot path already does for a write awaiting raft.
//!
//! `acquire` keeps the waiting behaviour for background callers, and is
//! documented as such so the distinction is not left to whoever wires it
//! up next.
//!
//! ## Why this is mostly composition
//!
//! "Hand out cluster-unique ids from blocks reserved through consensus,
//! keeping the next block warm so the common path never blocks" is
//! `rove-reserve`, already written and tested for the blob coordinator's
//! `batch_id`. The pool is that allocator with a provider that also
//! mints and replicates — so the double-buffered watermark refill, the
//! retry-on-provider-failure, and the no-reissue-across-leaders
//! guarantee all come for free rather than being written a second time.
//!
//! A block is one shard's worth of slots by default, so preparing one
//! costs a single `mintRange` and a single shard push. Smaller blocks
//! would rewrite the same shard repeatedly as it filled.

const std = @import("std");
const crypt = @import("root.zig");
const keyring_mod = @import("keyring.zig");
const reserve = @import("rove-reserve");

pub const Error = error{Shutdown};

/// Reserve `count` slots strictly after `prev_end` through consensus,
/// returning the new exclusive end. In production this proposes a
/// per-tenant counter key and waits for commit — the same block
/// reservation the blob coordinator does, and for the same reason: two
/// leaders must never hand out the same number.
pub const ReserveFn = *const fn (ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64;

/// Make `shard` durable on a quorum of the tenant's replica set.
/// Returning an error means "not durable"; the pool then refuses to
/// hand out any slot from that block.
pub const ReplicateFn = *const fn (ctx: *anyopaque, shard: u32) anyerror!void;

pub const Deps = struct {
    ctx: *anyopaque,
    reserve: ReserveFn,
    replicate: ReplicateFn,
    /// Injected so tests are not at the mercy of the wall clock.
    now: *const fn () i64 = defaultNow,
};

fn defaultNow() i64 {
    return @intCast(std.time.nanoTimestamp());
}

pub const SlotPool = struct {
    keyring: *keyring_mod.Keyring = undefined,
    deps: Deps = undefined,
    alloc: reserve.ReservationAllocator = .{},

    const Self = @This();

    /// Wire the pool and start its background refill.
    ///
    /// Call once, IN PLACE — the allocator's refill thread captures
    /// `&self.alloc`, so `self` must already be at its final address.
    ///
    /// `block_slots` defaults to one shard, so preparing a block is one
    /// `mintRange` and one shard push.
    pub fn start(
        self: *Self,
        kr: *keyring_mod.Keyring,
        deps: Deps,
        block_slots: u32,
    ) !void {
        self.keyring = kr;
        self.deps = deps;
        try self.alloc.start(.{
            .provider = .{ .ctx = self, .reserveFn = prepareBlock },
            .block_size = block_slots,
            // Slot 0 is `TENANT_REF`, the tenant's own key — never
            // allocatable to an identity.
            .first_id = crypt.FIRST_SLOT,
            .label = "keyring slots",
        });
    }

    pub fn deinit(self: *Self) void {
        self.alloc.deinit();
    }

    /// Take a slot whose key is minted and quorum-durable, or `null` if
    /// the pool is momentarily empty. **Never waits** — this is the one
    /// a request path calls.
    ///
    /// `null` means park and retry, not fail: the caller has the same
    /// options it already has for a write awaiting raft, and the poll
    /// loop keeps serving every other tenant meanwhile.
    ///
    /// It should also be rare enough to alarm on. Only a *new* identity
    /// reaches the pool — a returning one is a map lookup — so demand
    /// tracks new-identity rate, not request rate, orders of magnitude
    /// below what the refill sustains. A dry pool means the KMS is
    /// degraded, not that the tenant is busy.
    pub fn tryAcquire(self: *Self) ?u64 {
        return self.alloc.tryNext();
    }

    /// Take a slot, **waiting** for a refill if the pool is empty.
    ///
    /// Background callers only. The wait is unbounded, so on the poll
    /// loop it would stall every tenant on the node rather than the one
    /// request that needed a slot — the hot path uses `tryAcquire`.
    ///
    /// Returns `Shutdown` if `deinit` fired while parked.
    pub fn acquire(self: *Self) Error!u64 {
        return self.alloc.next() catch |err| switch (err) {
            reserve.Error.Shutdown => Error.Shutdown,
        };
    }

    /// The key for a slot this pool handed out. `null` once shredded,
    /// which callers surface as not-found.
    pub fn keyAt(self: *const Self, slot: u64) ?crypt.Key {
        return self.keyring.keyAt(slot);
    }

    /// Reserve → mint → replicate. Runs on the allocator's refill
    /// thread, ahead of demand, never on a request.
    ///
    /// Ordering is the whole point and is not rearrangeable: consensus
    /// decides the range before any key exists for it, the keys become
    /// durable locally before they are offered to peers, and the block
    /// is only returned — and so only published — once a quorum holds
    /// them.
    fn prepareBlock(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const new_end = try self.deps.reserve(self.deps.ctx, prev_end, count);
        if (new_end < prev_end + count) return error.ReservationTooSmall;
        const base = new_end - count;

        try self.keyring.mintRange(base, count, self.deps.now());

        // Push every shard the range touches. A block is normally one
        // shard's worth, but it can straddle a boundary since blocks are
        // sized, not aligned.
        var shard = keyring_mod.shardOf(base);
        const last_shard = keyring_mod.shardOf(new_end - 1);
        while (true) {
            try self.deps.replicate(self.deps.ctx, shard);
            if (shard == last_shard) break;
            shard += 1;
        }

        return new_end;
    }
};

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_KEK = "a node-local cluster key-encryption key";
const TEST_SECRET: keyring_mod.Secret = [_]u8{0x5A} ** keyring_mod.SECRET_LEN;

fn tmpDirPath(buf: []u8) []const u8 {
    const p = std.fmt.bufPrint(buf, "/tmp/rove-pool-test-{x}", .{std.crypto.random.int(u64)}) catch
        unreachable;
    std.fs.cwd().makePath(p) catch unreachable;
    return p;
}

fn cleanup(dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
}

/// A consensus stand-in: a monotonic counter with the production floor
/// rule, plus counters and a failure injector.
const Harness = struct {
    committed_end: std.atomic.Value(u64) = .init(0),
    reserve_calls: std.atomic.Value(u32) = .init(0),
    replicate_calls: std.atomic.Value(u32) = .init(0),
    /// Shards this harness has been asked to replicate, newest last.
    replicated: std.ArrayListUnmanaged(u32) = .empty,
    replicated_mu: std.Thread.Mutex = .{},
    fail_reserve: std.atomic.Value(u32) = .init(0),
    fail_replicate: std.atomic.Value(bool) = .init(false),

    fn reserve(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
        const s: *Harness = @ptrCast(@alignCast(ctx));
        _ = s.reserve_calls.fetchAdd(1, .monotonic);
        if (s.fail_reserve.load(.monotonic) > 0) {
            _ = s.fail_reserve.fetchSub(1, .monotonic);
            return error.NotLeader;
        }
        const floor = @max(@max(s.committed_end.load(.monotonic), prev_end), crypt.FIRST_SLOT);
        const new_end = floor + count;
        s.committed_end.store(new_end, .monotonic);
        return new_end;
    }

    fn replicate(ctx: *anyopaque, shard: u32) anyerror!void {
        const s: *Harness = @ptrCast(@alignCast(ctx));
        _ = s.replicate_calls.fetchAdd(1, .monotonic);
        if (s.fail_replicate.load(.monotonic)) return error.NoQuorum;
        s.replicated_mu.lock();
        defer s.replicated_mu.unlock();
        s.replicated.append(testing.allocator, shard) catch unreachable;
    }

    fn deps(self: *Harness) Deps {
        return .{
            .ctx = self,
            .reserve = Harness.reserve,
            .replicate = Harness.replicate,
            .now = fixedNow,
        };
    }

    fn sawShard(self: *Harness, shard: u32) bool {
        self.replicated_mu.lock();
        defer self.replicated_mu.unlock();
        for (self.replicated.items) |s| if (s == shard) return true;
        return false;
    }

    fn deinit(self: *Harness) void {
        self.replicated.deinit(testing.allocator);
    }
};

fn fixedNow() i64 {
    return 1_700_000_000_000_000_000;
}

test "every slot handed out already has a durable key" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 8);
    defer pool.deinit();

    // The invariant, checked on every slot rather than at the end: by
    // the time `acquire` returns, the key exists locally AND its shard
    // has been replicated.
    var prev: u64 = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const slot = try pool.acquire();
        try testing.expect(slot >= crypt.FIRST_SLOT);
        try testing.expect(slot > prev);
        prev = slot;
        try testing.expect(pool.keyAt(slot) != null);
        try testing.expect(h.sawShard(keyring_mod.shardOf(slot)));
    }
}

test "slots start after the reserved tenant key" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 4);
    defer pool.deinit();

    // Slot 0 is TENANT_REF. Handing it to an identity would make a
    // tenant-level seal and an identity-level one name the same key.
    const first = try pool.acquire();
    try testing.expectEqual(crypt.FIRST_SLOT, first);
    try testing.expect(crypt.slotForRef(crypt.refForSlot(first)) != 0);
}

test "a slot is NOT handed out when replication cannot reach a quorum" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    h.fail_replicate.store(true, .monotonic);

    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 4);

    // This is the property the whole ordering exists for. A leader that
    // sealed under a locally-minted but unreplicated key, committed the
    // data, and died would leave its successor holding data sealed
    // under a key that exists nowhere.
    const Waiter = struct {
        fn run(p: *SlotPool, out: *Error!u64) void {
            out.* = p.acquire();
        }
    };
    var result: Error!u64 = 0;
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ &pool, &result });

    // Give the refill loop room to try and fail more than once.
    std.Thread.sleep(250 * std.time.ns_per_ms);
    try testing.expect(h.replicate_calls.load(.monotonic) >= 2);

    pool.deinit();
    t.join();
    // Stalled, never satisfied with an undurable slot.
    try testing.expectError(Error.Shutdown, result);
}

test "tryAcquire returns null instead of waiting when the pool cannot fill" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    // Replication never succeeds, so no block is ever published and the
    // pool stays permanently dry.
    h.fail_replicate.store(true, .monotonic);

    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 4);
    defer pool.deinit();

    // The whole point: this RETURNS. The worker is a poll loop, so a
    // blocking acquire here would stop serving every tenant on the node
    // rather than slowing the one request that wanted a slot.
    try testing.expect(pool.tryAcquire() == null);
    try testing.expect(pool.tryAcquire() == null);

    // And it kicked a refill on the way out, so a caller that parks and
    // retries is not waiting on nothing.
    std.Thread.sleep(150 * std.time.ns_per_ms);
    try testing.expect(h.replicate_calls.load(.monotonic) >= 1);
}

test "tryAcquire yields durable slots on the fast path" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 8);
    defer pool.deinit();

    // The first block has to land; `tryAcquire` never waits for it.
    var first: ?u64 = null;
    var spins: usize = 0;
    while (first == null and spins < 200) : (spins += 1) {
        first = pool.tryAcquire();
        if (first == null) std.Thread.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(crypt.FIRST_SLOT, first.?);

    // The invariant holds on this path too: a slot handed out has a key
    // locally and its shard has been replicated.
    try testing.expect(pool.keyAt(first.?) != null);
    try testing.expect(h.sawShard(keyring_mod.shardOf(first.?)));

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const slot = pool.tryAcquire().?;
        try testing.expect(pool.keyAt(slot) != null);
    }
}

test "a reservation failure is retried without surfacing to the caller" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    // Losing leadership mid-propose is transient; a caller asking for a
    // slot should wait it out, not fail.
    h.fail_reserve.store(3, .monotonic);

    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 4);
    defer pool.deinit();

    const slot = try pool.acquire();
    try testing.expect(pool.keyAt(slot) != null);
    try testing.expectEqual(@as(u32, 0), h.fail_reserve.load(.monotonic));
}

test "a block straddling a shard boundary replicates both shards" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    // Start the counter just below a shard boundary so the first block
    // spans two shards. Blocks are sized, not aligned, so this is the
    // normal case rather than an edge one.
    h.committed_end.store(keyring_mod.SLOTS_PER_SHARD - 2, .monotonic);

    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 4);
    defer pool.deinit();

    const slot = try pool.acquire();
    try testing.expectEqual(keyring_mod.SLOTS_PER_SHARD - 2, slot);
    // A shard left unreplicated would strand every key in it on one
    // node, so both halves must be pushed before the block is published.
    try testing.expect(h.sawShard(0));
    try testing.expect(h.sawShard(1));
}

test "keys survive a restart, and slots are not reissued after one" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var h = Harness{};
    defer h.deinit();

    var first_slots: [6]u64 = undefined;
    var first_keys: [6]crypt.Key = undefined;
    {
        var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        var pool = SlotPool{};
        try pool.start(&kr, h.deps(), 4);
        for (&first_slots, 0..) |*s, i| {
            s.* = try pool.acquire();
            first_keys[i] = pool.keyAt(s.*).?;
        }
        pool.deinit();
    }

    // A restart — or a leader change — reopens the keyring and takes a
    // fresh block. Reissuing a slot would give two identities one key,
    // so shredding either would shred both.
    var kr = try keyring_mod.Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 4);
    defer pool.deinit();

    for (first_slots, first_keys) |slot, key| {
        try testing.expectEqualSlices(u8, &key, &pool.keyAt(slot).?);
    }
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const slot = try pool.acquire();
        for (first_slots) |prior| try testing.expect(slot != prior);
    }
}

test "a shredded slot reads as absent without disturbing the pool" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try keyring_mod.Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    var h = Harness{};
    defer h.deinit();
    var pool = SlotPool{};
    try pool.start(&kr, h.deps(), 8);
    defer pool.deinit();

    const doomed = try pool.acquire();
    const kept = try pool.acquire();
    try testing.expect(try kr.destroy(doomed));

    try testing.expect(pool.keyAt(doomed) == null);
    try testing.expect(pool.keyAt(kept) != null);
    // The slot is spent either way — allocation moves forward, so a
    // shredded slot is never reissued to someone else.
    try testing.expect(try pool.acquire() > kept);
}
