// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! One tenant's key state on one node: the keyring, the slot pool that
//! keeps minted keys ahead of demand, whether this node can vouch for
//! what it holds, and the destroys it still owes.
//!
//! ## Two locks, and why they are not one
//!
//! `map_lock` guards the in-memory key set. It is taken for a hash probe
//! and released — a read resolving a sealed value must never wait longer
//! than that, because that read happens on the poll loop and a wait there
//! stalls every tenant on the node, not one request.
//!
//! `disk_lock` serialises shard rewrites, which fsync twice and take
//! milliseconds. Nothing on a request path ever takes it.
//!
//! A single lock covering both is what the earlier shape had, and it made
//! every sealed read wait out any concurrent shard rewrite — the cost was
//! documented rather than fixed because fixing it from outside this
//! object was awkward. Owning both locks in one place is what makes the
//! split expressible.
//!
//! Order, where both are needed: `disk_lock` then `map_lock`, never the
//! reverse. A rewrite holds the disk lock for its whole duration and takes
//! the map lock only to read the key set into a buffer.

const std = @import("std");
const crypt = @import("rove-crypt");
const kv_mod = @import("raft-kv");
const keyspace = @import("keyspace.zig");
const seal_mod = @import("seal.zig");
const reserved = @import("rove-reserved");

/// Reserve → mint → replicate → publish, supplied by whoever owns the
/// cluster. See the module header: none of this is knowable here.
pub const Deps = crypt.pool.Deps;

pub const TenantKeys = struct {
    allocator: std.mem.Allocator,
    /// Borrowed; the tenant slot owns it.
    instance_id: []const u8,
    /// Borrowed: the tenant's store, for the replicated `_keys/*` rows.
    app_kv: *kv_mod.KvStore,

    keyring: crypt.keyring.Keyring,
    /// Guards `keyring`'s in-memory key set. Hash-probe scope only.
    map_lock: std.Thread.Mutex = .{},
    /// Serialises shard rewrites. Never taken on a request path.
    disk_lock: std.Thread.Mutex = .{},

    /// Claimed by the shared driver for the duration of one sweep, and by
    /// teardown before it frees anything. `tryLock` from the driver, so a
    /// tenant another worker already has is skipped rather than stalling
    /// the map lock behind a raft round trip.
    claim_lock: std.Thread.Mutex = .{},

    /// Does this node hold every key the tenant has minted? Read on the
    /// lookup path; `false` means a miss says nothing about erasure.
    complete: std.atomic.Value(bool) = .init(false),

    /// Minted keys ahead of demand. Null until a leader starts one.
    pool: ?crypt.pool.SlotPool = null,
    pool_ctx: ?*anyopaque = null,
    pool_ctx_free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,

    /// Slots evicted from memory whose shard has not been rewritten yet.
    /// Losing this costs nothing — the tombstones are committed, so
    /// `reconcile` re-derives the work.
    pending: std.ArrayListUnmanaged(u64) = .empty,

    const Self = @This();

    /// Open this tenant's keyring, or null when there is none — the
    /// surface is off, or the tenant predates crypto-shredding. Neither
    /// is an error, and neither may be read as "everything was erased".
    pub fn open(
        allocator: std.mem.Allocator,
        keyring_dir: []const u8,
        instance_id: []const u8,
        kek: []const u8,
        app_kv: *kv_mod.KvStore,
    ) !?*Self {
        var kr = crypt.keyring.Keyring.open(allocator, keyring_dir, instance_id, kek) catch |err| switch (err) {
            error.NoKeyring => return null,
            else => return err,
        };
        errdefer kr.deinit();

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .instance_id = instance_id,
            .app_kv = app_kv,
            .keyring = kr,
        };
        // Settle both before anyone can reach this: a lookup that read the
        // default would answer for a state nobody had established, and a
        // node that served before reconciling could hand out a key it had
        // already been told to destroy.
        self.refreshCompleteness();
        _ = self.reconcile() catch |err| std.log.warn(
            "keyring {s}: destroy reconciliation failed at open: {s}",
            .{ instance_id, @errorName(err) },
        );
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Wait out any sweep in flight before freeing anything under it.
        self.claim_lock.lock();
        defer self.claim_lock.unlock();
        // Pool before keyring: the pool borrows the keyring it mints into
        // and may be mid-`mintRange`. The disk lock waits that out.
        self.disk_lock.lock();
        if (self.pool) |*p| p.deinit();
        self.pool = null;
        if (self.pool_ctx) |c| {
            if (self.pool_ctx_free) |f| f(self.allocator, c);
            self.pool_ctx = null;
        }
        self.disk_lock.unlock();

        self.pending.deinit(self.allocator);
        self.keyring.deinit();
        self.allocator.destroy(self);
    }

    // ── reads ────────────────────────────────────────────────────────

    /// Resolve a slot to its key, or to why there is not one.
    ///
    /// Holds `map_lock` for a hash probe and nothing else. This runs on
    /// the poll loop.
    pub fn lookup(self: *Self, slot: u64) keyspace.Lookup {
        self.map_lock.lock();
        defer self.map_lock.unlock();
        const c: keyspace.Completeness =
            if (self.complete.load(.acquire)) .complete else .incomplete;
        return keyspace.lookup(&self.keyring, slot, c);
    }

    /// Decide what a stored value is, and open it when this node can.
    pub fn openValue(self: *Self, allocator: std.mem.Allocator, value: []const u8) !keyspace.Opened {
        if (!seal_mod.isSealed(value)) return .plaintext;
        const slot = seal_mod.slotOf(value) orelse return .unverified;
        return switch (self.lookup(slot)) {
            .key => |k| .{ .opened = try seal_mod.open(allocator, value, k) },
            .shredded => .shredded,
            .unverified => .unverified,
        };
    }

    pub fn tenantSecret(self: *Self) *const crypt.keyring.Secret {
        return self.keyring.tenantSecret();
    }

    // ── completeness ─────────────────────────────────────────────────

    /// Recompute whether this node holds every key the tenant minted.
    ///
    /// Every failure path stores `false`. Claiming completeness while
    /// unsure is the one direction that turns a missing key into a
    /// reported erasure, so uncertainty costs availability rather than
    /// truthfulness.
    pub fn refreshCompleteness(self: *Self) void {
        const survey = self.surveyTombstones() catch {
            self.complete.store(false, .release);
            return;
        };
        const minted = self.mintedWatermark() catch {
            self.complete.store(false, .release);
            return;
        };
        self.map_lock.lock();
        const live: u64 = @intCast(self.keyring.count());
        self.map_lock.unlock();
        self.complete.store(
            keyspace.completeness(live, survey.destroyed, minted) == .complete,
            .release,
        );
    }

    fn mintedWatermark(self: *Self) !u64 {
        const raw = self.app_kv.get(keyspace.MINTED_KEY) catch |err| switch (err) {
            error.NotFound => return 0,
            else => return err,
        };
        defer self.allocator.free(raw);
        return keyspace.decodeMinted(raw);
    }

    // ── destroys ─────────────────────────────────────────────────────

    /// Evict a slot's key from memory and queue its durable removal.
    ///
    /// Eviction is synchronous and the rewrite is not: the observable
    /// change must lead the irreversible one, so a read stops resolving
    /// before the shard is rewritten rather than after.
    pub fn evictAndQueue(self: *Self, slot: u64) void {
        self.map_lock.lock();
        self.keyring.evict(slot);
        self.map_lock.unlock();

        self.disk_lock.lock();
        defer self.disk_lock.unlock();
        for (self.pending.items) |q| if (q == slot) return;
        self.pending.append(self.allocator, slot) catch |err| std.log.warn(
            "keyring {s}: could not queue destroy of slot {d}: {s} — reconciliation will retry",
            .{ self.instance_id, slot, @errorName(err) },
        );
    }

    pub fn hasPendingDestroys(self: *Self) bool {
        self.disk_lock.lock();
        defer self.disk_lock.unlock();
        return self.pending.items.len != 0;
    }

    /// Rewrite the shards of everything queued. Fsyncs — never call this
    /// from the pump thread or the poll loop.
    ///
    /// Holds `disk_lock` for the whole rewrite and `map_lock` only for
    /// the map mutations inside it, so a concurrent sealed read waits on
    /// a hash probe rather than on two fsyncs.
    pub fn drainDestroys(self: *Self) !usize {
        self.disk_lock.lock();
        defer self.disk_lock.unlock();
        if (self.pending.items.len == 0) return 0;

        const slots = try self.allocator.dupe(u64, self.pending.items);
        defer self.allocator.free(slots);
        self.pending.clearRetainingCapacity();

        self.map_lock.lock();
        defer self.map_lock.unlock();
        return self.keyring.destroyMany(slots);
    }

    /// What this node still owes, derived rather than stored: a tombstone
    /// whose slot the keyring still holds is work outstanding.
    ///
    /// Per node by construction — node A finishing must not clear node
    /// B's work, which a replicated marker removed on completion would do.
    pub fn reconcile(self: *Self) !usize {
        const survey = try self.surveyTombstones();
        for (survey.outstanding[0..survey.outstanding_len]) |slot| self.evictAndQueue(slot);
        return survey.outstanding_len;
    }

    const Survey = struct {
        /// Every tombstone this tenant has, for the completeness sum.
        destroyed: u64,
        /// Slots this node has not finished destroying. Bounded because
        /// the sweep re-runs: a node further behind than this catches up
        /// over successive passes rather than needing one big buffer.
        outstanding: [256]u64 = undefined,
        outstanding_len: usize = 0,
    };

    /// ONE walk of `_keys/dead/` answering both questions.
    ///
    /// They were two paginated scans doing the same walk at different
    /// moments, which meant completeness and the destroy queue could
    /// disagree about what had been destroyed. Answering both from one
    /// pass makes them consistent by construction.
    fn surveyTombstones(self: *Self) !Survey {
        var out: Survey = .{ .destroyed = 0 };
        var cursor: []const u8 = "";
        var cursor_owned: ?[]u8 = null;
        defer if (cursor_owned) |c| self.allocator.free(c);

        while (true) {
            var res = try self.app_kv.prefix(keyspace.DEAD_PREFIX, cursor, 512);
            defer res.deinit();
            if (res.entries.len == 0) break;
            for (res.entries) |e| {
                const slot = keyspace.parseDeadSlot(e.key) orelse continue;
                out.destroyed += 1;
                if (out.outstanding_len == out.outstanding.len) continue;
                self.map_lock.lock();
                const still_here = self.keyring.keyAt(slot) != null;
                self.map_lock.unlock();
                if (!still_here) continue;
                out.outstanding[out.outstanding_len] = slot;
                out.outstanding_len += 1;
            }
            if (res.entries.len < 512) break;
            const next = try self.allocator.dupe(u8, res.entries[res.entries.len - 1].key);
            if (cursor_owned) |c| self.allocator.free(c);
            cursor_owned = next;
            cursor = next;
        }
        return out;
    }

    // ── writes ───────────────────────────────────────────────────────

    /// Seal every customer value this activation wrote, under `key_slot`.
    ///
    /// Runs after the handler returns, which is what makes late binding
    /// work: the identity in force at that moment is the one the writes
    /// seal under, wherever in the handler it was named.
    pub fn sealWrites(
        self: *Self,
        allocator: std.mem.Allocator,
        key_slot: u64,
        txn: anytype,
        writeset: *kv_mod.WriteSet,
        ws_base: usize,
    ) !void {
        const key = switch (self.lookup(key_slot)) {
            .key => |k| k,
            // Sealing under a key that is gone, or one this node cannot
            // vouch for, would write bytes nobody can ever open.
            .shredded, .unverified => return error.KeyDestroyed,
        };

        for (writeset.ops.items[ws_base..]) |*op| {
            const p = switch (op.*) {
                .put => |put_op| put_op,
                .delete => continue,
            };
            // Seal the TENANT's rows and nothing else. Engine state — the
            // binding row this activation may have just written is among it —
            // lives outside the user root, and sealing it would leave the
            // platform unable to read its own bookkeeping.
            //
            // Asked positively, against the root. The negative form ("is this
            // key reserved") answers YES for every rooted key, since the root
            // itself leads with `_` — which silently disables sealing for the
            // whole store rather than for the rows it means to protect.
            if (!std.mem.startsWith(u8, p.key, reserved.USER_KEY_ROOT)) continue;

            const sealed = try seal_mod.seal(allocator, p.value, key, key_slot, seal_mod.KEY_VERSION);
            defer allocator.free(sealed);
            // Both, inseparably: the txn is this node's write, the
            // writeset is what every other node applies. One without the
            // other leaves the leader holding plaintext where its
            // followers hold ciphertext.
            try txn.put(p.key, sealed);
            try writeset.replacePutValue(op, sealed);
        }
    }

    /// Erase `identity`'s key — permanently, and everywhere.
    ///
    /// The binding row is deleted and `_keys/dead/{slot}` written in the
    /// SAME writeset, so they cannot land apart: a binding removed
    /// without a tombstone leaves a live key nothing names, and a
    /// tombstone without the removal leaves an identity pointing at a
    /// slot being erased.
    ///
    /// The tombstone is the DURABLE INTENT — committed through the
    /// tenant's raft group before any node acts — and it is never
    /// removed, because the completeness check counts it. What each node
    /// still owes is derived from the disagreement between a tombstone
    /// and a keyring that still holds its slot (`reconcile`).
    pub fn destroyIdentity(
        self: *Self,
        allocator: std.mem.Allocator,
        identity: []const u8,
        txn: anytype,
        writeset: *kv_mod.WriteSet,
    ) !void {
        const pk = keyspace.pseudonymKey(self.tenantSecret());
        const bind_key = try keyspace.bindKey(allocator, pk, identity);
        defer allocator.free(bind_key);

        // An identity this tenant never named has nothing to erase. Not
        // an error: a delete-account flow run twice must not fail the
        // second time.
        const raw = self.app_kv.get(bind_key) catch |err| switch (err) {
            error.NotFound => {
                std.log.info(
                    "keyring {s}: destroy names an identity this tenant never bound — nothing to erase",
                    .{self.instance_id},
                );
                return;
            },
            else => return err,
        };
        defer allocator.free(raw);
        const key_slot = try keyspace.resolveBinding(raw, pk, identity);

        const dead_key = try keyspace.deadKey(allocator, key_slot);
        defer allocator.free(dead_key);
        const dead_val = keyspace.encodeDead(@intCast(std.time.nanoTimestamp()));

        try txn.delete(bind_key);
        try txn.put(dead_key, &dead_val);
        try writeset.addDelete(bind_key);
        try writeset.addPut(dead_key, &dead_val);

        // The local half. Every OTHER node does the same when the
        // tombstone applies there.
        std.log.info(
            "keyring {s}: destroying slot {d} — identity erased",
            .{ self.instance_id, key_slot },
        );
        self.evictAndQueue(key_slot);
    }

    // ── the pool ─────────────────────────────────────────────────────

    /// Start the slot pool, once. `ctx` is owned from here on.
    pub fn startPool(
        self: *Self,
        deps: Deps,
        ctx: *anyopaque,
        ctx_free: *const fn (std.mem.Allocator, *anyopaque) void,
        block_slots: u32,
        drive: @import("rove-reserve").Drive,
    ) !void {
        self.disk_lock.lock();
        defer self.disk_lock.unlock();
        if (self.pool != null) {
            ctx_free(self.allocator, ctx);
            return;
        }
        self.pool = .{};
        self.pool.?.start(&self.keyring, deps, block_slots, drive) catch |err| {
            self.pool = null;
            ctx_free(self.allocator, ctx);
            return err;
        };
        self.pool_ctx = ctx;
        self.pool_ctx_free = ctx_free;
    }

    pub fn hasPool(self: *Self) bool {
        self.disk_lock.lock();
        defer self.disk_lock.unlock();
        return self.pool != null;
    }

    /// Take a minted, quorum-durable slot, or null. NEVER waits.
    pub fn tryAcquireSlot(self: *Self) ?u64 {
        if (self.pool) |*p| return p.tryAcquire();
        return null;
    }

    pub fn poolNeedsRefill(self: *Self) bool {
        if (self.pool) |*p| return p.needsRefill();
        return false;
    }

    pub fn refillPoolOnce(self: *Self) anyerror!bool {
        if (self.pool) |*p| return p.refillOnce();
        return false;
    }
};

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "the two locks have distinct jobs, and reads never take the slow one" {
    // The reason this object exists. A read resolving a sealed value runs
    // on the poll loop, so it must never wait on a shard rewrite — the
    // earlier single-lock shape made it do exactly that, and the cost was
    // documented rather than fixed because it could not be fixed from
    // outside. Owning both locks here is what makes the split expressible.
    const TK = TenantKeys;
    try testing.expect(@hasField(TK, "map_lock"));
    try testing.expect(@hasField(TK, "disk_lock"));
    try testing.expect(@hasField(TK, "claim_lock"));
}

test "one object owns what used to be eight fields on the deployment slot" {
    // Those eight put a third of a struct about DEPLOYMENTS in service of
    // cryptography, which forced a cycle bridged by a mutable function
    // pointer installed at startup. The field list here IS the thing that
    // was extracted; if it starts leaking back out, this is where to look.
    const TK = TenantKeys;
    inline for (.{ "keyring", "pool", "pool_ctx", "complete", "pending" }) |f| {
        try testing.expect(@hasField(TK, f));
    }
}
