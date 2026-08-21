// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Wiring the per-tenant slot pool to a node: what backs its three
//! consensus-shaped callbacks, and who runs them.
//!
//! ## Why a shared driver instead of a thread per pool
//!
//! A pool is per TENANT, and a node is built to host many. Giving each
//! its own refill thread would scale threads with tenants, which is the
//! shape the hibernating active-set exists to avoid everywhere else. So
//! pools run in `rove-reserve`'s `external` drive and a small worker set
//! turns the crank for all of them.
//!
//! The work is unchanged — reserve through raft, mint, push to a quorum,
//! publish the watermark — and it is all blocking, so it belongs on
//! these threads and nowhere near the poll loop. A request never waits
//! for a key: `tryAcquire` returns null and the activation parks, the
//! same as any write awaiting raft.
//!
//! ## Warm ahead of demand, not on demand
//!
//! The driver keeps refilling once a pool exists, so in steady state a
//! bind finds a slot already minted and durable. Only two situations
//! empty a pool: a tenant's very first demand, and a refill that cannot
//! keep up — which means the reserve or the quorum push is failing, not
//! that the tenant is busy. That is what makes an empty pool worth
//! alarming on rather than routine.
//!
//! ## Lifetime, which is the delicate part
//!
//! `evictTenant` removes a slot from the map under the map lock and then
//! frees it OUTSIDE that lock, so a driver thread holding a raw slot
//! pointer could be working on freed memory.
//!
//! The handoff is `TenantSlot.pool_busy`. A driver claims it WHILE still
//! holding the map lock — so the slot is provably alive at the moment of
//! the claim — then releases the map lock and does its work. Teardown
//! takes the same mutex before touching the pool, so it waits out any
//! in-flight refill instead of pulling the ground from under it. The
//! claim is a `tryLock`, so a busy tenant is skipped this round rather
//! than stalling the map lock behind a raft round trip.

const std = @import("std");
const crypt = @import("rove-crypt");
const reserve = @import("rove-reserve");
const keyring_slots = @import("keyring_slots.zig");
const keyring_shard = @import("keyring_shard.zig");
const deployment_cache = @import("deployment_cache.zig");
const keyring_mod = @import("rove-keyring");
const kv_mod = @import("raft-kv");

const reserved = @import("rove-reserved");
const globals = @import("globals.zig");

/// Slots per reserved block — one shard's worth, so preparing a block is
/// a single `mintRange` and a single shard push. Smaller blocks would
/// rewrite the same shard repeatedly as it filled.
const BLOCK_SLOTS: u32 = crypt.keyring.SLOTS_PER_SHARD;

/// How long a driver thread idles when no pool wants anything. Long
/// enough that sweeping costs nothing at rest, short enough that a first
/// demand is served promptly.
const IDLE_SLEEP_NS: u64 = 25 * std.time.ns_per_ms;

/// Backoff after a failed refill, so a tenant whose consensus is
/// unavailable does not spin the driver on behalf of every other tenant.
const FAIL_SLEEP_NS: u64 = 100 * std.time.ns_per_ms;

/// Per-tenant callback context. Generic over the worker type so this
/// file needs no import of it — the worker owns the deployment cache
/// that owns the slots that own these, and naming it here would close
/// that loop.
pub fn Ctx(comptime W: type) type {
    return struct {
        worker: W,
        allocator: std.mem.Allocator,
        /// Owned: the pool outlives the caller's borrowed tenant id.
        tenant: []u8,

        const Self = @This();

        fn reserveFn(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return keyring_slots.reserve(self.worker, self.tenant, prev_end, count);
        }

        fn replicateFn(ctx: *anyopaque, shard: u32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const gid = self.worker.raft.gidForTenant(self.tenant) orelse
                return error.NotHosted;
            return keyring_shard.pushToQuorum(
                self.allocator,
                self.worker,
                self.tenant,
                gid,
                shard,
            );
        }

        fn commitMintedFn(ctx: *anyopaque, end: u64) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return keyring_slots.commitMinted(self.worker, self.tenant, end);
        }

        pub fn deps(self: *Self) crypt.pool.Deps {
            return .{
                .ctx = self,
                .reserve = Self.reserveFn,
                .replicate = Self.replicateFn,
                .commit_minted = Self.commitMintedFn,
            };
        }

        /// Type-erased free, stored beside the context so teardown needs
        /// no knowledge of `W`.
        pub fn free(allocator: std.mem.Allocator, erased: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(erased));
            allocator.free(self.tenant);
            allocator.destroy(self);
        }
    };
}

/// Give this tenant a slot pool if it can have one. Idempotent.
///
/// A pool needs a keyring to mint into, so a tenant without one (the
/// surface is off, or it predates crypto-shredding) simply gets none and
/// every slot request answers null.
///
/// Leader-gated: the tenant's raft leader owns its pool. Two nodes
/// refilling concurrently would produce shards that disagree about which
/// key sits in a slot, and a peer installing the loser would hand back a
/// wrong key later. Leadership already arbitrates every other write to
/// this tenant.
pub fn ensurePool(worker: anytype, slot: *deployment_cache.TenantSlot) !void {
    const keys = slot.keys orelse return;
    if (keys.hasPool()) return;

    // Leader-gated: two nodes refilling the same tenant would produce
    // shards that disagree about which key sits in a slot, and a peer
    // installing the loser would hand back a wrong key later.
    const gid = worker.raft.gidForTenant(slot.instance_id) orelse return;
    if (!worker.raft.isLeaderOf(gid)) return;

    const allocator = keys.allocator;
    const C = Ctx(@TypeOf(worker));
    const ctx = try allocator.create(C);
    errdefer allocator.destroy(ctx);
    const tenant_owned = try allocator.dupe(u8, slot.instance_id);
    ctx.* = .{ .worker = worker, .allocator = allocator, .tenant = tenant_owned };

    // Ownership of `ctx` transfers: `startPool` frees it on any path
    // that does not keep it, so there is one owner at every instant.
    try keys.startPool(ctx.deps(), ctx, C.free, BLOCK_SLOTS, .external);
}

/// The shared refill worker set.
pub const RefillDriver = struct {
    allocator: std.mem.Allocator,
    dc: *deployment_cache.DeploymentCache,
    threads: []std.Thread = &.{},
    stopping: std.atomic.Value(bool) = .init(false),

    /// Worker count. Small and fixed: the work is one raft round trip
    /// plus a quorum push per block, and blocks are 4096 slots, so even
    /// a busy node needs very few. More would mostly add contention on
    /// the slot map.
    pub const WORKERS: usize = 2;

    pub fn start(
        self: *RefillDriver,
        allocator: std.mem.Allocator,
        dc: *deployment_cache.DeploymentCache,
    ) !void {
        self.* = .{ .allocator = allocator, .dc = dc };
        const ts = try allocator.alloc(std.Thread, WORKERS);
        errdefer allocator.free(ts);
        var started: usize = 0;
        errdefer {
            self.stopping.store(true, .release);
            for (ts[0..started]) |t| t.join();
        }
        while (started < ts.len) : (started += 1) {
            ts[started] = try std.Thread.spawn(.{}, loop, .{self});
        }
        self.threads = ts;
    }

    pub fn deinit(self: *RefillDriver) void {
        self.stopping.store(true, .release);
        for (self.threads) |t| t.join();
        if (self.threads.len != 0) self.allocator.free(self.threads);
        self.threads = &.{};
    }

    /// Claim one pool that wants a block, or null.
    ///
    /// The claim is taken while the map lock is held, which is what makes
    /// the returned pointer safe to use after the lock is released: the
    /// slot was alive at claim time, and teardown blocks on the same
    /// mutex. `tryLock` rather than `lock`, so a tenant another worker is
    /// already refilling is skipped instead of stalling the map lock
    /// behind a raft round trip.
    /// Claim one tenant with work, or null.
    ///
    /// The claim is taken while the map lock is held, which is what makes
    /// the pointer safe to use after the lock is released: the slot was
    /// alive at claim time, and teardown blocks on the same mutex.
    fn claim(self: *RefillDriver) ?*keyring_mod.TenantKeys {
        self.dc.tenant_files_lock.lock();
        defer self.dc.tenant_files_lock.unlock();
        var it = self.dc.tenant_files_map.iterator();
        while (it.next()) |entry| {
            const keys = entry.value_ptr.*.keys orelse continue;
            // Either kind of work claims it. A destroy is owed even by a
            // tenant with no pool — a node can hold keys for a tenant it
            // does not lead, and it still has to erase them.
            if (!keys.hasPendingDestroys() and !keys.poolNeedsRefill()) continue;
            if (!keys.claim_lock.tryLock()) continue;
            return keys;
        }
        return null;
    }

    fn loop(self: *RefillDriver) void {
        while (!self.stopping.load(.acquire)) {
            const keys = self.claim() orelse {
                std.Thread.sleep(IDLE_SLEEP_NS);
                continue;
            };
            // Destroys first: an erasure this node owes outranks keeping
            // its pool warm, and the queue is usually empty.
            const drained = keys.drainDestroys() catch |err| blk: {
                std.log.warn(
                    "keyring {s}: destroy rewrite failed: {s} — reconciliation will retry",
                    .{ keys.instance_id, @errorName(err) },
                );
                break :blk 0;
            };
            _ = drained;
            const res = keys.refillPoolOnce();
            keys.claim_lock.unlock();
            if (res) |_| {} else |err| {
                std.log.warn(
                    "keyring pool {s}: refill failed: {s}",
                    .{ keys.instance_id, @errorName(err) },
                );
                std.Thread.sleep(FAIL_SLEEP_NS);
            }
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "a block is one shard's worth, so preparing one is a single push" {
    // Smaller blocks would rewrite the same shard repeatedly as it
    // filled, which is the cost the shard mapping exists to bound.
    try testing.expectEqual(crypt.keyring.SLOTS_PER_SHARD, BLOCK_SLOTS);
}

test "the driver's worker count is fixed and small" {
    // The refill is one raft round trip plus a quorum push per 4096
    // slots. Scaling workers with tenants would recreate the
    // thread-per-tenant problem the external drive exists to remove.
    try testing.expect(RefillDriver.WORKERS >= 1);
    try testing.expect(RefillDriver.WORKERS <= 4);
}

test "idle sweeps are cheap and failures back off harder" {
    // A tenant whose consensus is unavailable must not spin the driver
    // on behalf of every other tenant.
    try testing.expect(FAIL_SLEEP_NS > IDLE_SLEEP_NS);
}

// ── resolving an identity to its slot ────────────────────────────────

/// Turn the identity a handler named into the slot its writes seal
/// under, binding a fresh one the first time this tenant names it.
///
/// This is `ShredCaps.resolve_slot` (`js/globals.zig`) — the seam that
/// keeps the worker's generic type out of the dispatcher.
///
/// A returning identity costs one kv read and nothing else. Only a NEW
/// identity reaches the pool, which is why demand tracks new-identity
/// rate rather than request rate, and why an empty pool is rare enough
/// to alarm on.
///
/// The binding rides the activation's own raft entry: it is appended to
/// the writeset the request was already sending, and written through the
/// same txn, so naming an identity costs no extra round trip and no
/// extra fsync on the request path.
pub fn resolveSlot(
    worker: anytype,
    allocator: std.mem.Allocator,
    slot: *deployment_cache.TenantSlot,
    identity: []const u8,
    txn: anytype,
    writeset: *kv_mod.WriteSet,
) !u64 {
    const keys = slot.keys orelse return error.KeyringUnavailable;
    const pk = keyring_mod.keyspace.pseudonymKey(keys.tenantSecret());

    const bind_key = try keyring_mod.keyspace.bindKey(allocator, pk, identity);
    defer allocator.free(bind_key);

    // Already bound? Read through the activation's own txn, so an
    // identity named twice in one activation resolves to one slot
    // instead of burning a second.
    if (keys.app_kv.get(bind_key)) |raw| {
        defer allocator.free(raw);
        return keyring_mod.keyspace.resolveBinding(raw, pk, identity);
    } else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }

    // A NEW identity from here on. This is the only place one is minted,
    // and the only place the cap can be enforced without also capping a
    // returning identity — which costs nothing and must stay free.
    //
    // Refused LOUDLY. The alternative every fallback offers is sealing
    // under the tenant key instead, which silently downgrades erasure from
    // per-identity to per-tenant at exactly the moment a customer is under
    // load and least able to notice. An error the handler can see is the
    // only honest answer.
    if (!try admitNewIdentity(worker, slot)) return error.NewIdentityRateLimited;

    try ensurePool(worker, slot);
    // Never waits. The worker is a poll loop, so blocking here would
    // stall every tenant on the node rather than the one request that
    // needed a slot.
    const got = keys.tryAcquireSlot() orelse return error.PoolEmpty;

    const value = keyring_mod.keyspace.bindingFor(pk, identity, got);
    // Both, inseparably: the txn is this node's write, the writeset is
    // what every other node applies.
    try txn.put(bind_key, &value);
    try writeset.addPut(bind_key, &value);
    return got;
}

// ── sealing and opening values ───────────────────────────────────────



// ── destroying an identity ───────────────────────────────────────────


/// Is this tenant allowed one more NEW identity right now?
///
/// Capped because a new identity mints a key into a slot that is never
/// reused — a permanent commitment no cleanup reclaims, landing on the
/// keyring, the pool and the KMS together. Destroys are not capped here:
/// they reclaim rather than commit.
///
/// The failure this guards against is a mistake, not abuse — a handler
/// passing a request id or a per-call UUID as the shred key. That is
/// always wrong, because a key used once can never be usefully shredded,
/// and it turns every request into a permanent key. Identities are people
/// or accounts, so they arrive at signup rate; a per-request id hits the
/// wall almost at once, which is the point.
fn admitNewIdentity(worker: anytype, slot: *deployment_cache.TenantSlot) !bool {
    const lim = &worker.limiter;
    const plan = slot.effectivePlan();
    return lim.check(
        slot.instance_id,
        .new_identity,
        plan.rate,
        slot.plan_gen.load(.acquire),
        @intCast(std.time.nanoTimestamp()),
    );
}
