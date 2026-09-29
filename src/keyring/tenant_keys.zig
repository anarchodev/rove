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
const body_seal_mod = @import("body_seal.zig");
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

    /// Something changed under the in-memory key set — a shard landed on
    /// disk behind it, or the tenant's minted watermark advanced — and
    /// `refresh` has not caught up yet. Set with `complete` already
    /// cleared (`markStale`), so the window reads `unverified`, never an
    /// erasure that did not happen.
    stale: std.atomic.Value(bool) = .init(false),

    /// Earliest time (ns) the driver may pull from a peer again while this
    /// node cannot vouch for its keys, and the current backoff — so a
    /// tenant whose peers are all behind too costs a round trip at a
    /// falling rate rather than every sweep. Driver-thread only, under
    /// `claim_lock`.
    repair_after_ns: i64 = 0,
    repair_backoff_ns: i64 = 0,

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
        // Released by hand just before `self` is freed — a `defer` would
        // run after the free and write to released memory. Nothing can
        // claim it in between: the slot is already out of the map, and the
        // driver only ever `tryLock`s.
        self.claim_lock.lock();
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
        self.claim_lock.unlock();
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

    /// Keys held in memory. A diagnostic, not a decision input.
    pub fn keyCount(self: *Self) usize {
        self.map_lock.lock();
        defer self.map_lock.unlock();
        return self.keyring.count();
    }

    /// Open a pool body with the wrap its tape entry carries — the body
    /// twin of `openValue`, with the same three-way answer so a reader
    /// keeps "erased" and "this node cannot tell" apart. An empty wrap is
    /// `.plaintext`: the entry names bytes that were never sealed.
    pub fn openBody(
        self: *Self,
        allocator: std.mem.Allocator,
        sealed_body: []const u8,
        wrap: []const u8,
    ) !keyspace.Opened {
        if (wrap.len == 0) return .plaintext;
        const ref = try body_seal_mod.wrapRef(wrap);
        return switch (self.keyForWrap(ref)) {
            .key => |k| .{ .opened = try body_seal_mod.open(allocator, sealed_body, wrap, k) },
            .shredded => .shredded,
            .unverified => .unverified,
        };
    }

    pub fn tenantSecret(self: *Self) *const crypt.keyring.Secret {
        return self.keyring.tenantSecret();
    }

    // ── catching up with the disk ────────────────────────────────────

    /// The key set may be behind what this node holds or what the tenant
    /// minted. Clears `complete` BEFORE anything else can observe the
    /// change, so a lookup in the window answers `unverified` rather than
    /// calling a key it has not loaded yet destroyed. Cheap and lock-free:
    /// callable from the pump thread and the poll loop. `refresh` does
    /// the work, on the keyring driver.
    pub fn markStale(self: *Self) void {
        self.complete.store(false, .release);
        self.stale.store(true, .release);
    }

    /// Load what is on disk now into the in-memory key set, re-derive the
    /// destroys this node owes, and recompute completeness.
    ///
    /// Completeness settled once, at open, is not enough: a replica opens a
    /// tenant's slot when the tenant is placed on it, before anything is
    /// minted, when an empty keyring IS complete. Everything minted after
    /// that reaches the replica's disk by push and never its memory, so a
    /// flag nobody recomputes stays true over a set that grew stale, and a
    /// failover onto that replica reads every sealed value as erased.
    ///
    /// Tombstoned slots are dropped from the fresh set BEFORE it goes live,
    /// so a key whose shard rewrite is still queued never becomes readable
    /// again; `reconcile` then catches a destroy that applied during the
    /// load. Fsync-free, but it walks the tombstones — driver thread only,
    /// under `claim_lock`, which also keeps it clear of a pool mint.
    pub fn refresh(self: *Self) !void {
        // Cleared first: a mark that lands while this runs asks for
        // another pass rather than being lost.
        self.stale.store(false, .release);

        var fresh = self.keyring.snapshotFromDisk() catch |err| switch (err) {
            // The directory went away — a deprovision's shred. Nothing to
            // load, and nothing this node can vouch for.
            error.NoKeyring => {
                self.complete.store(false, .release);
                return;
            },
            else => return err,
        };
        defer fresh.deinit();
        try self.dropTombstoned(&fresh);

        self.map_lock.lock();
        self.keyring.adoptKeys(&fresh);
        self.map_lock.unlock();

        _ = try self.reconcile();
        self.refreshCompleteness();
    }

    /// Remove every tombstoned slot from `kr`.
    fn dropTombstoned(self: *Self, kr: *crypt.keyring.Keyring) !void {
        var cursor: []const u8 = "";
        var cursor_owned: ?[]u8 = null;
        defer if (cursor_owned) |c| self.allocator.free(c);
        while (true) {
            var res = try self.app_kv.prefix(keyspace.DEAD_PREFIX, cursor, 512);
            defer res.deinit();
            if (res.entries.len == 0) break;
            for (res.entries) |e| {
                const slot = keyspace.parseDeadSlot(e.key) orelse continue;
                kr.evict(slot);
            }
            if (res.entries.len < 512) break;
            const next = try self.allocator.dupe(u8, res.entries[res.entries.len - 1].key);
            if (cursor_owned) |c| self.allocator.free(c);
            cursor_owned = next;
            cursor = next;
        }
    }

    /// Is a pull from a peer due? True while this node cannot vouch for
    /// its keys, nothing is waiting on a refresh, and the backoff has
    /// elapsed.
    pub fn repairDue(self: *Self, now_ns: i64) bool {
        return !self.complete.load(.acquire) and !self.stale.load(.acquire) and
            now_ns >= self.repair_after_ns;
    }

    /// Record a pull's outcome: complete resets the backoff, anything else
    /// doubles it (from `first_ns`, capped at `max_ns`).
    pub fn noteRepair(self: *Self, now_ns: i64, first_ns: i64, max_ns: i64) void {
        if (self.complete.load(.acquire)) {
            self.repair_backoff_ns = 0;
            self.repair_after_ns = 0;
            return;
        }
        self.repair_backoff_ns = if (self.repair_backoff_ns == 0)
            first_ns
        else
            @min(self.repair_backoff_ns * 2, max_ns);
        self.repair_after_ns = now_ns + self.repair_backoff_ns;
    }

    /// The key that opens a body wrap, from the ref the wrap names.
    ///
    /// Two kinds of key material answer to a ref and a caller should not
    /// have to know which: `crypt.TENANT_REF` is DERIVED from the
    /// tenant's stored secret (slot 0 is reserved for it and never
    /// minted, so a lookup would report it shredded), while every other
    /// ref is a minted slot. One branch, here, where the key material
    /// lives.
    pub fn keyForWrap(self: *Self, ref: crypt.KeyRef) keyspace.Lookup {
        if (std.mem.eql(u8, &ref, &crypt.TENANT_REF))
            return .{ .key = body_seal_mod.tenantKey(self.tenantSecret()) };
        return self.lookup(crypt.slotForRef(ref));
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

    /// Move a pool body's wrap from the tenant key onto `key_slot` — the
    /// body half of late binding, run beside `sealWrites` for the same
    /// reason: the identity in force when the handler returns is the one
    /// its bytes answer to.
    ///
    /// It REPLACES the wrap (`body_seal.rewrap`): two wraps of one data
    /// key would leave the tenant key able to read what destroying the
    /// identity promised to erase. A wrap already naming `key_slot` is
    /// left as is; one naming a DIFFERENT slot is refused, because two
    /// identities claiming one body is a caller bug and picking either
    /// silently breaks the other's erasure.
    pub fn bindBodyWrap(self: *Self, wrap: []u8, key_slot: u64) !void {
        if (wrap.len != body_seal_mod.WRAPPED_LEN) return body_seal_mod.Error.MalformedWrap;
        const from_ref = try body_seal_mod.wrapRef(wrap);
        if (!std.mem.eql(u8, &from_ref, &crypt.TENANT_REF)) {
            if (crypt.slotForRef(from_ref) == key_slot) return;
            return body_seal_mod.Error.MalformedWrap;
        }
        const to = switch (self.lookup(key_slot)) {
            .key => |k| k,
            // A wrap under a key that is gone, or one this node cannot
            // vouch for, is one nobody can ever open.
            .shredded, .unverified => return error.KeyDestroyed,
        };
        const moved = try body_seal_mod.rewrap(
            wrap,
            body_seal_mod.tenantKey(self.tenantSecret()),
            to,
            crypt.refForSlot(key_slot),
            seal_mod.KEY_VERSION,
        );
        @memcpy(wrap, &moved);
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
        self.pool.?.start(&self.keyring, self.mapLock(), deps, block_slots, drive) catch |err| {
            self.pool = null;
            ctx_free(self.allocator, ctx);
            return err;
        };
        self.pool_ctx = ctx;
        self.pool_ctx_free = ctx_free;
    }

    /// `map_lock` as the keyring's `MapLock`, for the pool's mints.
    fn mapLock(self: *Self) crypt.keyring.MapLock {
        const L = struct {
            fn lock(ctx: *anyopaque) void {
                const tk: *Self = @ptrCast(@alignCast(ctx));
                tk.map_lock.lock();
            }
            fn unlock(ctx: *anyopaque) void {
                const tk: *Self = @ptrCast(@alignCast(ctx));
                tk.map_lock.unlock();
            }
        };
        return .{ .ctx = self, .lock = L.lock, .unlock = L.unlock };
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

test "a restored keyring does not resurrect a key the tenant destroyed" {
    // The interlock a backup depends on (rove#963 / rove#592). Key material
    // lives outside raft in node-local files, so an OLD backup's shard still
    // holds a key that has since been destroyed. What makes restoring it safe
    // is that the destroy rode the tenant's LOG: the tombstone comes back with
    // the store, and `open` reconciles against it before anyone can reach the
    // keyring.
    //
    // Get this wrong and a restore silently undoes an erasure — the one thing
    // a backup must never do, and the reason the restore order (store first,
    // keyring second) is load-bearing rather than stylistic.
    const a = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const seed = std.crypto.random.int(u64);
    const db_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/rove-tk-test-{x}.kv", .{seed});
    // LMDB (NOSUBDIR) writes `path` and `path-lock`; both go.
    var lock_buf: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}-lock", .{db_path});
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        std.fs.cwd().deleteFile(lock_path) catch {};
    }
    var dir_buf: [96]u8 = undefined;
    const kr_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/rove-tk-keyring-{x}", .{seed});
    defer std.fs.cwd().deleteTree(kr_dir) catch {};

    const kek = "a cluster key-encryption key";
    const destroyed_slot: u64 = 7;
    const live_slot: u64 = 8;

    // The backup's keyring: both slots present, taken before the destroy.
    {
        var kr = try crypt.keyring.Keyring.create(a, kr_dir, "acme", kek, [_]u8{0x5A} ** 32);
        defer kr.deinit();
        try kr.mintRange(destroyed_slot, 2, 1);
        try testing.expect(kr.keyAt(destroyed_slot) != null);
    }

    // The store that comes back with it: the destroy is in the log, so the
    // tombstone is in the restored state.
    const store = try kv_mod.KvStore.open(a, db_path);
    defer store.close();
    const dead = try keyspace.deadKey(a, destroyed_slot);
    defer a.free(dead);
    try store.put(dead, &keyspace.encodeDead(1));

    const keys = (try TenantKeys.open(a, kr_dir, "acme", kek, store)).?;
    defer keys.deinit();

    // Reconciliation runs inside `open`, before this line can observe
    // anything — a node that served before reconciling could hand out a key
    // it had already been told to destroy.
    try testing.expect(keys.lookup(destroyed_slot) == .shredded);
    try testing.expect(keys.lookup(live_slot) == .key);

    // And it is gone from the FILE, not merely hidden in memory: a restore
    // that left the key on disk would hand it back at the next open.
    _ = try keys.drainDestroys();
    var reopened = try crypt.keyring.Keyring.open(a, kr_dir, "acme", kek);
    defer reopened.deinit();
    try testing.expect(reopened.keyAt(destroyed_slot) == null);
    try testing.expect(reopened.keyAt(live_slot) != null);
}

test "a pool body's wrap moves to the identity, and only the identity then opens it" {
    const a = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const seed = std.crypto.random.int(u64);
    const db_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/rove-tk-body-{x}.kv", .{seed});
    var lock_buf: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}-lock", .{db_path});
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        std.fs.cwd().deleteFile(lock_path) catch {};
    }
    var dir_buf: [96]u8 = undefined;
    const kr_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/rove-tk-body-keyring-{x}", .{seed});
    defer std.fs.cwd().deleteTree(kr_dir) catch {};

    const kek = "a cluster key-encryption key";
    const dead_slot: u64 = 7;
    const identity_slot: u64 = 8;
    {
        var kr = try crypt.keyring.Keyring.create(a, kr_dir, "acme", kek, [_]u8{0x5A} ** 32);
        defer kr.deinit();
        try kr.mintRange(dead_slot, 2, 1);
    }
    const store = try kv_mod.KvStore.open(a, db_path);
    defer store.close();
    const dead = try keyspace.deadKey(a, dead_slot);
    defer a.free(dead);
    try store.put(dead, &keyspace.encodeDead(1));
    const keys = (try TenantKeys.open(a, kr_dir, "acme", kek, store)).?;
    defer keys.deinit();

    // Submitted before any handler ran: wrapped for the tenant.
    const tenant_key = body_seal_mod.tenantKey(keys.tenantSecret());
    var s = try body_seal_mod.seal(a, "the request body", tenant_key, crypt.TENANT_REF, 1);
    defer s.deinit(a);
    {
        const res = try keys.openBody(a, s.body, &s.wrapped_key);
        defer if (res == .opened) a.free(res.opened);
        try testing.expectEqualStrings("the request body", res.opened);
    }

    // The handler named an identity: the wrap moves, the body does not.
    try keys.bindBodyWrap(&s.wrapped_key, identity_slot);
    try testing.expectEqual(identity_slot, crypt.slotForRef(try body_seal_mod.wrapRef(&s.wrapped_key)));
    {
        const res = try keys.openBody(a, s.body, &s.wrapped_key);
        defer if (res == .opened) a.free(res.opened);
        try testing.expectEqualStrings("the request body", res.opened);
    }
    // THE property: the tenant key no longer opens it, so destroying the
    // identity leaves nothing that can.
    try testing.expectError(
        crypt.Error.AuthFailed,
        body_seal_mod.open(a, s.body, &s.wrapped_key, tenant_key),
    );

    // Re-binding to the same identity is a no-op; to a different one is a
    // caller bug, refused rather than resolved by picking one.
    try keys.bindBodyWrap(&s.wrapped_key, identity_slot);
    try testing.expectError(body_seal_mod.Error.MalformedWrap, keys.bindBodyWrap(&s.wrapped_key, 9));

    // Binding to a destroyed identity would write a wrap nobody can open.
    var t = try body_seal_mod.seal(a, "x", tenant_key, crypt.TENANT_REF, 1);
    defer t.deinit(a);
    try testing.expectError(error.KeyDestroyed, keys.bindBodyWrap(&t.wrapped_key, dead_slot));

    // A body whose identity is destroyed reads as erased, not as an error.
    var gone = try body_seal_mod.seal(a, "x", [_]u8{0x01} ** crypt.KEY_LEN, crypt.refForSlot(dead_slot), 1);
    defer gone.deinit(a);
    try testing.expect((try keys.openBody(a, gone.body, &gone.wrapped_key)) == .shredded);

    // No wrap means a body that was never sealed.
    try testing.expect((try keys.openBody(a, "plain", "")) == .plaintext);
}

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

test "refresh picks up keys that landed behind an open keyring, and never a destroyed one" {
    // The failover bug this exists for: a replica opens a tenant's keyring
    // at placement, before anything is minted — when an empty keyring IS
    // complete — and every key minted after that reaches its disk by push
    // and never its memory. Without a refresh that set stays empty and the
    // flag stays true, so a lookup calls a live key destroyed.
    const a = testing.allocator;
    var path_buf: [96]u8 = undefined;
    const seed = std.crypto.random.int(u64);
    const db_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/rove-tk-refresh-{x}.kv", .{seed});
    var lock_buf: [128]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}-lock", .{db_path});
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        std.fs.cwd().deleteFile(lock_path) catch {};
    }
    var dir_buf: [96]u8 = undefined;
    const kr_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/rove-tk-refresh-kr-{x}", .{seed});
    defer std.fs.cwd().deleteTree(kr_dir) catch {};
    var src_buf: [96]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&src_buf, "/tmp/rove-tk-refresh-src-{x}", .{seed});
    defer std.fs.cwd().deleteTree(src_dir) catch {};
    const kek = "a cluster key-encryption key";

    // The replica, opened at placement: nothing minted, so complete.
    {
        var kr = try crypt.keyring.Keyring.create(a, kr_dir, "acme", kek, [_]u8{0x5A} ** 32);
        kr.deinit();
    }
    const store = try kv_mod.KvStore.open(a, db_path);
    defer store.close();
    const keys = (try TenantKeys.open(a, kr_dir, "acme", kek, store)).?;
    defer keys.deinit();
    try testing.expect(keys.complete.load(.acquire));

    // The leader mints 1..3 and pushes the shard; the watermark replicates;
    // slot 2 is destroyed through the log before this replica refreshes.
    {
        var leader = try crypt.keyring.Keyring.create(a, src_dir, "acme", kek, [_]u8{0x5A} ** 32);
        defer leader.deinit();
        try leader.mintRange(1, 3, 1);
    }
    const sealed = (try crypt.keyring.readSealedShard(a, src_dir, "acme", kek, 0)).?;
    defer a.free(sealed);
    try crypt.keyring.installSealedShard(a, kr_dir, "acme", kek, 0, sealed);
    try store.put(keyspace.MINTED_KEY, &keyspace.encodeMinted(4));
    const dead = try keyspace.deadKey(a, 2);
    defer a.free(dead);
    try store.put(dead, &keyspace.encodeDead(1));

    // The watermark's apply marks the keyring stale: from here until the
    // refresh, a miss is `unverified`, never an erasure.
    keys.markStale();
    try testing.expect(keys.lookup(1) == .unverified);

    try keys.refresh();
    try testing.expect(keys.lookup(1) == .key);
    try testing.expect(keys.lookup(3) == .key);
    // Destroyed through the log while the key was still on disk: it never
    // becomes readable again.
    try testing.expect(keys.lookup(2) == .shredded);
    try testing.expect(keys.complete.load(.acquire));
    try testing.expect(!keys.stale.load(.acquire));
}
