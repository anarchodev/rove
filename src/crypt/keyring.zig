// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The per-tenant keyring — the store whose *delete* is the erasure.
//!
//! Crypto shredding needs somewhere to put keys that a delete genuinely
//! removes. That rules out the obvious homes: a key replicated through
//! raft, or written to any append-only log, stays legible in the live
//! log after it is "destroyed", so shredding would defeat itself one
//! level down. This file is the answer — per-tenant files that are
//! **rewritten whole** on every change and never appended to.
//!
//!   destroy one key   → rewrite its shard without that entry
//!   destroy a tenant  → remove the tenant's directory
//!
//! ## Why a rewrite is a real delete, and what it is not
//!
//! Rewrite-and-rename allocates new blocks; it does not overwrite the
//! old ones, and on flash nothing at this layer can. Effectiveness comes
//! from two other things:
//!
//!  1. The files are **sealed under the KEK**, so whatever an old block
//!     still holds is ciphertext — useless to anyone who has the bytes
//!     but not the key: a backup, an object store, a disk pulled from a
//!     decommissioned node.
//!  2. The **live** file stops containing the key. That is the whole
//!     difference from a log, where a destroyed key remains in the
//!     current, in-use file forever, readable by every legitimate
//!     reader.
//!
//! So the guarantee is: **erasure is effective against everyone who
//! does not hold the KEK.** It is not a claim about physical overwrite,
//! and it is not a claim that the KEK is unobtainable.
//!
//! Be precise about that second limit, because it is easy to overstate.
//! This code never writes the KEK anywhere; whether the *deployment*
//! keeps it off persistent storage is a separate property and not one
//! this file can assert. Where the KEK ships in the same on-disk
//! environment file as every other node secret, a recovered disk yields
//! both halves and residue here is readable — which is why destroying a
//! node's copy is a **rotation** question (`key_version` exists for it)
//! rather than something the seal alone settles.
//!
//! ## Keys are indexed by SLOT, not by identity
//!
//! Keys are minted into a pool **before any identity exists**, so there
//! is nothing identity-shaped to index them by. A slot is just a
//! number; the identity→slot binding lives in replicated KV, written by
//! the request path inside the raft entry it was already sending.
//!
//! That indirection is the whole point: it keeps minting — with its
//! quorum round trip and its fsync — off the commit path, which is the
//! most latency-sensitive path in the system. A keyring indexed by
//! identity would force a keyring write the first time each identity
//! appeared, which is exactly the cost the pool exists to avoid.
//!
//! ## Sharding, and why the capacity bound is structural
//!
//! One file per tenant would make a mint rewrite every key that tenant
//! has — quadratic to fill, and a tenant with thousands of identities
//! rewriting hundreds of KB to add 48 bytes.
//!
//! Slots are allocated in ascending order, so shards are **contiguous
//! ranges**: shard S holds exactly the slots `[S·SLOTS_PER_SHARD,
//! (S+1)·SLOTS_PER_SHARD)`, and the number of shards grows with the
//! tenant instead of being fixed.
//!
//! Every write rewrites the shard it touches, and only that one. For a
//! refill that is the tail shard, since refills append; for a destroy it
//! is whichever shard holds the slot, which may be any of them. Either
//! way the cost is one shard, which is what the mapping bounds.
//!
//! **Slots are never reused.** A destroy leaves a hole, and the
//! allocator keeps moving forward. That is deliberate: reuse would make
//! a stale reference to a destroyed slot resolve to some *other*
//! tenant's-identity key instead of failing, turning "this key was
//! shredded" into "this ciphertext belongs to someone else" — a
//! distinction worth keeping. The cost is that a heavily-churning
//! tenant accumulates sparse shards, bounded by total-ever-minted
//! rather than live keys. An emptied shard has no file at all, so the
//! cost is one file per shard that still holds a survivor.
//!
//! A shard's capacity is then a property of the mapping rather than a
//! limit anyone has to enforce: a shard cannot hold more slots than its
//! range contains. There is no "shard full" error to handle and no
//! bound that can quietly stop matching the rewrite cost it claims to
//! cap.
//!
//! Each shard is still rewritten WHOLE, so the erasure property above is
//! untouched — sharding changes only what a rewrite costs, never
//! whether a destroyed key survives in a live file. A shard file exists
//! only while it holds entries, so a small tenant costs a handful of
//! files and a fully-shredded one costs none.
//!
//! ## Key loss is data loss
//!
//! Losing a keyring entry destroys the data it protects, with no retry
//! and no repair — a strictly worse failure than losing a write, which
//! a caller can simply reissue. So every write here fsyncs the file
//! *and* the parent directory, in that order, and neither result is
//! ignored: an unchecked fsync is how a destroy silently fails to
//! survive a power cut while reporting success.
//!
//! ## Scope
//!
//! Node-local storage only. Reserving slot ranges through raft,
//! delivering the tenant secret to every node, and invalidating caches
//! on destroy are the surrounding work; this file is what they store
//! into.

const std = @import("std");
const crypt = @import("root.zig");

/// Length of a tenant's root secret. The HKDF root for every key
/// derived for that tenant, and the thing whose destruction is a C1
/// shred.
pub const SECRET_LEN: usize = 32;

pub const Secret = [SECRET_LEN]u8;

/// Slots per shard, as a power of two so the slot→shard mapping is a
/// shift rather than a division.
pub const SHARD_BITS: u6 = 12;
pub const SLOTS_PER_SHARD: u64 = 1 << SHARD_BITS;

/// Largest addressable slot. Shard indices are `u32`, so this is where
/// the mapping runs out — 2^44 slots per tenant, far past any real
/// use, and checked rather than allowed to wrap into another shard.
pub const MAX_SLOT: u64 = (@as(u64, std.math.maxInt(u32)) << SHARD_BITS) | (SLOTS_PER_SHARD - 1);

const SHARD_MAGIC: u32 = 0x524B5231; // 'RKR1'
const SECRET_MAGIC: u32 = 0x524B5331; // 'RKS1'
const FORMAT_VERSION: u16 = 1;

/// `[4B magic][2B version][4B shard][4B count]`
const SHARD_HEADER_LEN: usize = 4 + 2 + 4 + 4;
/// `[4B magic][2B version][32B secret]`
const SECRET_FILE_LEN: usize = 4 + 2 + SECRET_LEN;
/// `[8B slot][32B key][8B created_unix_ns]`
const ENTRY_LEN: usize = 8 + crypt.KEY_LEN + 8;

/// The most one rewrite can cost, which is what sharding exists to
/// bound. Structural: a shard's range cannot hold more than this.
pub const MAX_SHARD_BYTES: usize =
    SHARD_HEADER_LEN + @as(usize, SLOTS_PER_SHARD) * ENTRY_LEN;

const SECRET_FILE_NAME = "tenant.kr";

/// Cap on the tenant id accepted into a keyring path, matching the
/// envelope codec's store-id bound so an id encodable there is always
/// nameable here.
pub const MAX_TENANT_ID_LEN: usize = 256;

pub const Error = error{
    /// The keyring does not exist. Distinct from a corrupt one: this is
    /// the "not attached here yet" case.
    NoKeyring,
    /// A keyring exists where one was about to be created.
    KeyringExists,
    /// Magic, version, or length checks failed — refuse rather than
    /// guess, because guessing wrong means handing back a wrong key.
    Corrupt,
    /// The KEK does not open this keyring, or a file was altered.
    AuthFailed,
    TenantIdTooLong,
    /// A slot past `MAX_SLOT`, or a range that would wrap.
    SlotOutOfRange,
    Io,
    OutOfMemory,
};

const Entry = struct {
    key: crypt.Key,
    created_unix_ns: i64,
};

/// One entry as an audit surface sees it — no key material.
pub const AuditEntry = struct {
    slot: u64,
    created_unix_ns: i64,
};

/// Which shard a slot lives in. The single definition — every reader
/// and writer routes through it, so a slot can never be written under
/// one rule and looked for under another.
pub fn shardOf(slot: u64) u32 {
    return @intCast(slot >> SHARD_BITS);
}

/// First slot of `shard`.
pub fn shardBase(shard: u32) u64 {
    return @as(u64, shard) << SHARD_BITS;
}

pub const Keyring = struct {
    allocator: std.mem.Allocator,
    /// This tenant's directory, `{base}/{hash}`. Owned.
    tenant_dir: []u8,
    /// KEK subkey for THIS tenant. Per-tenant rather than one key for
    /// every keyring on the node: seals share a random 96-bit nonce
    /// space, so scoping the key scopes the nonce budget with it (see
    /// the nonce-budget note in `crypt`).
    file_key: crypt.Key,
    secret: Secret,
    /// Every key, across all shards. Lookups stay one hash probe —
    /// sharding is a persistence concern, not a lookup one.
    keys: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    /// Live count per shard, so a rewrite can size its buffer without
    /// scanning. Only shards that hold entries appear.
    shard_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Set by `destroyAll`. The secret is zeroed at that point, so a
    /// later mint would seal under a key derived from zeroes and write
    /// a keyring back for a tenant that no longer exists. Refuse.
    destroyed: bool = false,

    const Self = @This();

    /// Create a keyring for a tenant that does not have one on this node.
    ///
    /// `secret` is supplied by the caller and MUST be the same bytes on
    /// every node holding the tenant. Minting it here would key the same
    /// tenant's data differently per node — a correctness fault, not
    /// merely a leak, and the identical trap the storage incarnation
    /// documents at its own mint site.
    pub fn create(
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        tenant_id: []const u8,
        kek: []const u8,
        secret: Secret,
    ) Error!Self {
        var self = try init(allocator, base_dir, tenant_id, kek);
        errdefer self.deinit();
        self.secret = secret;

        const secret_path = try self.secretPath();
        defer self.allocator.free(secret_path);
        std.fs.cwd().access(secret_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try self.writeSecretFile();
                return self;
            },
            else => return Error.Io,
        };
        return Error.KeyringExists;
    }

    /// Load this tenant's keyring. `NoKeyring` when absent — the caller
    /// decides whether that means "attach it" or "this tenant is gone",
    /// which are different situations that must not be conflated.
    pub fn open(
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        tenant_id: []const u8,
        kek: []const u8,
    ) Error!Self {
        var self = try init(allocator, base_dir, tenant_id, kek);
        errdefer self.deinit();
        try self.readSecretFile();
        try self.readShards();
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Key material outlives the map's memory unless it is cleared —
        // a freed page is still readable by whatever allocates it next.
        var it = self.keys.iterator();
        while (it.next()) |e| std.crypto.secureZero(u8, &e.value_ptr.key);
        self.keys.deinit(self.allocator);
        self.shard_counts.deinit(self.allocator);
        std.crypto.secureZero(u8, &self.secret);
        std.crypto.secureZero(u8, &self.file_key);
        self.allocator.free(self.tenant_dir);
    }

    /// The tenant's root secret — the HKDF root for every key derived
    /// for this tenant.
    pub fn tenantSecret(self: *const Self) *const Secret {
        return &self.secret;
    }

    pub fn count(self: *const Self) usize {
        return self.keys.count();
    }

    /// Look up a key by slot. `null` means shredded (or never minted) —
    /// callers surface that as not-found, never as an error, because
    /// "erased" should read like "absent" to everything downstream.
    pub fn keyAt(self: *const Self, slot: u64) ?crypt.Key {
        return (self.keys.get(slot) orelse return null).key;
    }

    /// Convenience for callers holding a ciphertext header rather than a
    /// slot. The envelope's key ref IS the slot (`crypt.refForSlot`).
    pub fn keyForRef(self: *const Self, ref: crypt.KeyRef) ?crypt.Key {
        return self.keyAt(crypt.slotForRef(ref));
    }

    /// Mint keys for `[from_slot, from_slot + n)` — the pool refill.
    ///
    /// Idempotent: a slot that already holds a key keeps it. A retried
    /// refill that minted fresh keys over live ones would strand
    /// everything they had sealed, which is unrecoverable and looks
    /// exactly like data loss.
    ///
    /// Rewrites only the shards the range touches, and a range that
    /// stays inside one shard rewrites exactly one file — which is the
    /// normal case, since refills are sized to a shard.
    ///
    /// On a mid-range failure the shards already written stay written.
    /// They hold correctly-minted keys, so that is durable progress
    /// rather than damage, and the caller retries the whole range.
    pub fn mintRange(self: *Self, from_slot: u64, n: u64, now_unix_ns: i64) Error!void {
        if (self.destroyed) return Error.NoKeyring;
        if (n == 0) return;
        if (from_slot < crypt.FIRST_SLOT) return Error.SlotOutOfRange;
        // Checked rather than allowed to wrap: a wrapped range would
        // silently mint into shard 0 and overwrite live keys.
        const last = std.math.add(u64, from_slot, n - 1) catch return Error.SlotOutOfRange;
        if (last > MAX_SLOT) return Error.SlotOutOfRange;

        var shard = shardOf(from_slot);
        const last_shard = shardOf(last);
        while (shard <= last_shard) : (shard += 1) {
            const lo = @max(from_slot, shardBase(shard));
            const hi = @min(last, shardBase(shard) + SLOTS_PER_SHARD - 1);
            try self.mintWithinShard(shard, lo, hi, now_unix_ns);
            if (shard == last_shard) break; // `shard + 1` could overflow u32
        }
    }

    fn mintWithinShard(self: *Self, shard: u32, lo: u64, hi: u64, now_unix_ns: i64) Error!void {
        var added: u32 = 0;
        errdefer self.rollbackMint(shard, lo, hi, added);

        var slot = lo;
        while (slot <= hi) : (slot += 1) {
            if (self.keys.contains(slot)) continue;
            var key: crypt.Key = undefined;
            std.crypto.random.bytes(&key);
            self.keys.put(self.allocator, slot, .{
                .key = key,
                .created_unix_ns = now_unix_ns,
            }) catch return Error.OutOfMemory;
            added += 1;
        }
        if (added == 0) return; // every slot already present; nothing to write

        const gop = self.shard_counts.getOrPut(self.allocator, shard) catch
            return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += added;

        // Roll memory back if the rewrite does not land, so no caller
        // ever receives a key the disk will not have after a restart.
        self.flushShard(shard) catch |err| {
            gop.value_ptr.* -= added;
            return err;
        };
    }

    fn rollbackMint(self: *Self, shard: u32, lo: u64, hi: u64, added: u32) void {
        _ = shard;
        if (added == 0) return;
        var slot = lo;
        var removed: u32 = 0;
        while (slot <= hi and removed < added) : (slot += 1) {
            if (self.keys.remove(slot)) removed += 1;
        }
    }

    /// Destroy one key. Returns whether it existed, so a caller can
    /// distinguish "shredded now" from "already gone" for audit without
    /// either being an error.
    ///
    /// On return the key is absent from the live shard. Everything it
    /// sealed — kv values, log frames, tapes, pooled bodies, and any
    /// copy in a backup — is unreadable from this point.
    pub fn destroy(self: *Self, slot: u64) Error!bool {
        if (self.destroyed) return false;
        var removed = self.keys.fetchRemove(slot) orelse return false;
        // Wiped only once the rewrite lands — the rollback below needs
        // these bytes if it does not.
        defer std.crypto.secureZero(u8, &removed.value.key);

        const shard = shardOf(slot);
        const cnt = self.shard_counts.getPtr(shard) orelse return Error.Corrupt;
        cnt.* -= 1;

        self.flushShard(shard) catch |err| {
            // Put it back: reporting a shred that did not reach disk is
            // worse than reporting a failure, because the caller has
            // been told data is gone when a restart brings it back.
            //
            // `putAssumeCapacity` cannot fail — `fetchRemove` leaves the
            // capacity in place — so the rollback has no error path of
            // its own to swallow. An allocating put here could fail and
            // leave memory and disk disagreeing, and the next successful
            // flush would then quietly complete a destroy this call
            // reported as failed.
            self.keys.putAssumeCapacity(slot, removed.value);
            cnt.* += 1;
            return err;
        };
        if (cnt.* == 0) _ = self.shard_counts.remove(shard);
        return true;
    }

    /// Destroy the whole keyring — the tenant-level shred. Removes the
    /// tenant's directory and clears memory; every key for this tenant,
    /// at both levels, is gone.
    pub fn destroyAll(self: *Self) Error!void {
        std.fs.cwd().deleteTree(self.tenant_dir) catch return Error.Io;
        // The tenant directory is gone, so its own fsync target is gone
        // with it — sync the parent, which is what recorded the removal.
        try syncPath(std.fs.path.dirname(self.tenant_dir) orelse ".");

        var it = self.keys.iterator();
        while (it.next()) |e| std.crypto.secureZero(u8, &e.value_ptr.key);
        self.keys.clearRetainingCapacity();
        self.shard_counts.clearRetainingCapacity();
        std.crypto.secureZero(u8, &self.secret);
        self.destroyed = true;
    }

    /// Enumerate slots and mint times, never key material. Caller frees.
    pub fn audit(self: *const Self, allocator: std.mem.Allocator) Error![]AuditEntry {
        const out = allocator.alloc(AuditEntry, self.keys.count()) catch
            return Error.OutOfMemory;
        var i: usize = 0;
        var it = self.keys.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = .{
                .slot = e.key_ptr.*,
                .created_unix_ns = e.value_ptr.created_unix_ns,
            };
        }
        return out;
    }

    // ── internals ────────────────────────────────────────────────────

    fn init(
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        tenant_id: []const u8,
        kek: []const u8,
    ) Error!Self {
        if (tenant_id.len > MAX_TENANT_ID_LEN) return Error.TenantIdTooLong;

        // The tenant id is hashed into the path rather than used raw: an
        // id is customer-visible and can carry characters a path cannot,
        // and a directory listing should not enumerate tenants.
        var name_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(tenant_id, &name_digest, .{});
        const dir = std.fmt.allocPrint(
            allocator,
            "{s}/{x}",
            .{ base_dir, name_digest[0..16] },
        ) catch return Error.OutOfMemory;
        errdefer allocator.free(dir);

        var label_buf: [MAX_TENANT_ID_LEN + 32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "rove-keyring/v1/{s}", .{tenant_id}) catch
            return Error.TenantIdTooLong;

        return .{
            .allocator = allocator,
            .tenant_dir = dir,
            .file_key = crypt.deriveSubkey(kek, label),
            .secret = std.mem.zeroes(Secret),
        };
    }

    fn secretPath(self: *const Self) Error![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/" ++ SECRET_FILE_NAME,
            .{self.tenant_dir},
        ) catch Error.OutOfMemory;
    }

    fn shardPath(self: *const Self, shard: u32) Error![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{x:0>8}.kr",
            .{ self.tenant_dir, shard },
        ) catch Error.OutOfMemory;
    }

    fn writeSecretFile(self: *Self) Error!void {
        var plain: [SECRET_FILE_LEN]u8 = undefined;
        std.mem.writeInt(u32, plain[0..4], SECRET_MAGIC, .big);
        std.mem.writeInt(u16, plain[4..6], FORMAT_VERSION, .little);
        @memcpy(plain[6..][0..SECRET_LEN], &self.secret);
        defer std.crypto.secureZero(u8, &plain);

        const path = try self.secretPath();
        defer self.allocator.free(path);
        try self.writeSealed(path, &plain);
    }

    fn readSecretFile(self: *Self) Error!void {
        const path = try self.secretPath();
        defer self.allocator.free(path);

        const plain = self.readSealed(path, SECRET_FILE_LEN) catch |err| switch (err) {
            Error.NoKeyring => return Error.NoKeyring,
            else => return err,
        };
        defer {
            std.crypto.secureZero(u8, plain);
            self.allocator.free(plain);
        }

        if (plain.len != SECRET_FILE_LEN) return Error.Corrupt;
        if (std.mem.readInt(u32, plain[0..4], .big) != SECRET_MAGIC) return Error.Corrupt;
        if (std.mem.readInt(u16, plain[4..6], .little) != FORMAT_VERSION) return Error.Corrupt;
        @memcpy(&self.secret, plain[6..][0..SECRET_LEN]);
    }

    /// Load every shard present. Absent shards are empty, so the
    /// directory listing IS the shard set — no probing a shard space
    /// that grows with the tenant.
    fn readShards(self: *Self) Error!void {
        var d = std.fs.cwd().openDir(self.tenant_dir, .{ .iterate = true }) catch
            return Error.NoKeyring;
        defer d.close();

        var it = d.iterate();
        while (it.next() catch return Error.Io) |ent| {
            if (ent.kind != .file) continue;
            const shard = parseShardName(ent.name) orelse continue;
            try self.readShard(shard);
        }
    }

    /// `{XXXXXXXX}.kr` → shard. Anything else (the secret file, a
    /// leftover `.tmp.*` from an interrupted rewrite) is not a shard.
    fn parseShardName(name: []const u8) ?u32 {
        if (name.len != 11) return null;
        if (!std.mem.eql(u8, name[8..], ".kr")) return null;
        return std.fmt.parseInt(u32, name[0..8], 16) catch null;
    }

    fn readShard(self: *Self, shard: u32) Error!void {
        const path = try self.shardPath(shard);
        defer self.allocator.free(path);

        const plain = self.readSealed(path, MAX_SHARD_BYTES) catch |err| switch (err) {
            // Raced with a destroy that emptied it; an absent shard is
            // an empty shard.
            Error.NoKeyring => return,
            else => return err,
        };
        defer {
            std.crypto.secureZero(u8, plain);
            self.allocator.free(plain);
        }

        const n = try validateShardPlain(plain, shard);
        self.keys.ensureUnusedCapacity(self.allocator, n) catch return Error.OutOfMemory;

        var pos: usize = SHARD_HEADER_LEN;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const slot = std.mem.readInt(u64, plain[pos..][0..8], .little);
            pos += 8;
            var key: crypt.Key = undefined;
            @memcpy(&key, plain[pos..][0..crypt.KEY_LEN]);
            pos += crypt.KEY_LEN;
            const created = std.mem.readInt(i64, plain[pos..][0..8], .little);
            pos += 8;
            self.keys.putAssumeCapacity(slot, .{ .key = key, .created_unix_ns = created });
        }
        if (n > 0) self.shard_counts.put(self.allocator, shard, n) catch
            return Error.OutOfMemory;
    }

    /// Rewrite one shard whole. Never appends: an append-only keyring
    /// would keep destroyed keys in the live file, which is precisely
    /// what this store exists to avoid.
    ///
    /// An emptied shard is removed rather than written as a zero-entry
    /// file, so a fully-shredded tenant leaves no shard behind.
    fn flushShard(self: *Self, shard: u32) Error!void {
        const path = try self.shardPath(shard);
        defer self.allocator.free(path);

        const n: u32 = if (self.shard_counts.get(shard)) |c| c else 0;
        if (n == 0) {
            std.fs.cwd().deleteFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return Error.Io,
            };
            return syncPath(self.tenant_dir);
        }

        const plain = self.allocator.alloc(u8, SHARD_HEADER_LEN + @as(usize, n) * ENTRY_LEN) catch
            return Error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, plain);
            self.allocator.free(plain);
        }

        std.mem.writeInt(u32, plain[0..4], SHARD_MAGIC, .big);
        std.mem.writeInt(u16, plain[4..6], FORMAT_VERSION, .little);
        std.mem.writeInt(u32, plain[6..10], shard, .little);
        std.mem.writeInt(u32, plain[10..14], n, .little);

        // Walk the shard's slot RANGE rather than the whole key map, so
        // a rewrite costs the shard's size regardless of how many keys
        // the tenant has. It also emits in slot order, which makes a
        // shard's plaintext identical on every node holding it.
        var pos: usize = SHARD_HEADER_LEN;
        var slot = shardBase(shard);
        const end = slot + SLOTS_PER_SHARD;
        while (slot < end) : (slot += 1) {
            const e = self.keys.get(slot) orelse continue;
            std.mem.writeInt(u64, plain[pos..][0..8], slot, .little);
            pos += 8;
            @memcpy(plain[pos..][0..crypt.KEY_LEN], &e.key);
            pos += crypt.KEY_LEN;
            std.mem.writeInt(i64, plain[pos..][0..8], e.created_unix_ns, .little);
            pos += 8;
        }
        // `shard_counts` sized the buffer, so a disagreement with what
        // the map actually holds would truncate or leave a tail of
        // uninitialised bytes — either way, keys silently lost.
        if (pos != plain.len) return Error.Corrupt;

        try self.writeSealed(path, plain);
    }

    /// Seal `plain` and land it at `path` atomically and durably.
    fn writeSealed(self: *Self, path: []const u8, plain: []const u8) Error!void {
        const sealed = crypt.sealAlloc(
            self.allocator,
            plain,
            self.file_key,
            crypt.TENANT_REF,
            FORMAT_VERSION,
        ) catch return Error.OutOfMemory;
        defer self.allocator.free(sealed);
        try self.writeRaw(path, sealed);
    }

    /// Land already-sealed bytes at `path` atomically and durably.
    ///
    /// Split out because replication installs a peer's shard **byte for
    /// byte** — re-sealing it locally would produce different bytes for
    /// the same content, so a shard could never be compared or repaired
    /// by identity.
    fn writeRaw(self: *Self, path: []const u8, sealed: []const u8) Error!void {
        std.fs.cwd().makePath(self.tenant_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.Io,
        };

        const tmp = std.fmt.allocPrint(
            self.allocator,
            "{s}.tmp.{x}",
            .{ path, std.crypto.random.int(u64) },
        ) catch return Error.OutOfMemory;
        defer self.allocator.free(tmp);

        {
            const f = std.fs.cwd().createFile(tmp, .{ .mode = 0o600 }) catch return Error.Io;
            defer f.close();
            f.writeAll(sealed) catch {
                std.fs.cwd().deleteFile(tmp) catch {};
                return Error.Io;
            };
            // Durable BEFORE the rename, or the rename can publish a
            // name pointing at bytes a crash never wrote.
            f.sync() catch {
                std.fs.cwd().deleteFile(tmp) catch {};
                return Error.Io;
            };
        }

        std.fs.cwd().rename(tmp, path) catch {
            std.fs.cwd().deleteFile(tmp) catch {};
            return Error.Io;
        };
        // And the directory, or the rename itself can be lost.
        try syncPath(self.tenant_dir);
    }

    fn readSealed(self: *Self, path: []const u8, max_plain: usize) Error![]u8 {
        const sealed = std.fs.cwd().readFileAlloc(
            self.allocator,
            path,
            crypt.OVERHEAD + max_plain,
        ) catch |err| switch (err) {
            error.FileNotFound => return Error.NoKeyring,
            else => return Error.Io,
        };
        defer self.allocator.free(sealed);

        return crypt.openAlloc(self.allocator, sealed, self.file_key) catch |err| switch (err) {
            crypt.Error.AuthFailed => Error.AuthFailed,
            crypt.Error.OutOfMemory => Error.OutOfMemory,
            // A truncated or non-envelope file is corruption, not a
            // wrong key — say which, because the operator responses
            // differ (restore vs. fix the KEK).
            else => Error.Corrupt,
        };
    }
};

/// Structural check on a decrypted shard, returning its entry count.
///
/// Shared by the local read path and the replication install path so a
/// shard arriving from a peer is held to exactly the same standard as
/// one read off local disk — a peer is not a more trusted source of key
/// material than a file is.
fn validateShardPlain(plain: []const u8, shard: u32) Error!u32 {
    if (plain.len < SHARD_HEADER_LEN) return Error.Corrupt;
    if (std.mem.readInt(u32, plain[0..4], .big) != SHARD_MAGIC) return Error.Corrupt;
    if (std.mem.readInt(u16, plain[4..6], .little) != FORMAT_VERSION) return Error.Corrupt;
    // The shard records which shard it is, so a file moved, renamed, or
    // delivered under the wrong index is caught instead of silently
    // scattering entries into a rewrite set nothing will ever route to.
    if (std.mem.readInt(u32, plain[6..10], .little) != shard) return Error.Corrupt;

    const n = std.mem.readInt(u32, plain[10..14], .little);
    if (n > SLOTS_PER_SHARD) return Error.Corrupt;
    // The count and the byte length must agree exactly. A trailing
    // remainder means the file is not what it claims, and a keyring is
    // the last place to be lenient about that.
    if (plain.len != SHARD_HEADER_LEN + @as(usize, n) * ENTRY_LEN) return Error.Corrupt;

    var pos: usize = SHARD_HEADER_LEN;
    var i: u32 = 0;
    var prev: ?u64 = null;
    while (i < n) : (i += 1) {
        const slot = std.mem.readInt(u64, plain[pos..][0..8], .little);
        // A slot outside this shard's range would be unreachable by
        // every later mint and destroy, which route by `shardOf`.
        if (shardOf(slot) != shard) return Error.Corrupt;
        // Ascending and distinct. Writers emit in slot order, so a
        // repeat or an inversion means the file was tampered with or
        // written by something that is not this codec — and a duplicate
        // slot would silently drop one of the two keys on load.
        if (prev) |p| if (slot <= p) return Error.Corrupt;
        prev = slot;
        pos += ENTRY_LEN;
    }
    return n;
}

/// Install a sealed shard received from a peer.
///
/// The bytes are written **verbatim**: a shard's file key is
/// `HKDF(cluster KEK, tenant id)`, identical on every node, so a sealed
/// shard is portable ciphertext and re-sealing it locally would only
/// produce different bytes for the same content.
///
/// Verified before it lands, not at the next open. An unverified
/// install poisons the receiver silently and surfaces at a failover —
/// the worst possible moment, since that is exactly when the peer's
/// copy becomes the only copy. Both failure modes are distinguished:
/// `AuthFailed` means the sender's KEK differs from ours, `Corrupt`
/// means the bytes are not a shard.
///
/// An empty `sealed` removes the shard, which is how a peer learns that
/// a shard was emptied by destroys rather than merely not updated.
pub fn installSealedShard(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    tenant_id: []const u8,
    kek: []const u8,
    shard: u32,
    sealed: []const u8,
) Error!void {
    var kr = try Keyring.init(allocator, base_dir, tenant_id, kek);
    defer kr.deinit();

    const path = try kr.shardPath(shard);
    defer allocator.free(path);

    if (sealed.len == 0) {
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return Error.Io,
        };
        return syncPath(kr.tenant_dir);
    }

    const plain = crypt.openAlloc(allocator, sealed, kr.file_key) catch |err| switch (err) {
        crypt.Error.AuthFailed => return Error.AuthFailed,
        crypt.Error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.Corrupt,
    };
    defer {
        std.crypto.secureZero(u8, plain);
        allocator.free(plain);
    }
    _ = try validateShardPlain(plain, shard);

    try kr.writeRaw(path, sealed);
}

/// Read a shard's sealed bytes for sending to a peer, or null when the
/// shard is empty. Caller frees.
///
/// Deliberately returns the bytes as stored rather than re-encoding
/// from memory: what a peer installs is then exactly what this node
/// has, with no chance of a divergence between the two representations.
pub fn readSealedShard(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    tenant_id: []const u8,
    kek: []const u8,
    shard: u32,
) Error!?[]u8 {
    var kr = try Keyring.init(allocator, base_dir, tenant_id, kek);
    defer kr.deinit();

    const path = try kr.shardPath(shard);
    defer allocator.free(path);

    return std.fs.cwd().readFileAlloc(
        allocator,
        path,
        crypt.OVERHEAD + MAX_SHARD_BYTES,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => Error.Io,
    };
}

/// fsync a directory, so a rename or unlink cannot be the thing a power
/// cut loses.
///
/// `.iterate = true` is load-bearing, not incidental: without it
/// `openDir` yields an `O_PATH` descriptor on Linux, and fsync on
/// `O_PATH` fails with `EBADF` — which Zig's wrapper treats as
/// unreachable, so the process dies rather than the durability step
/// quietly not happening.
fn syncPath(dir_path: []const u8) Error!void {
    var d = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return Error.Io;
    defer d.close();
    const as_file = std.fs.File{ .handle = d.fd };
    as_file.sync() catch return Error.Io;
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_KEK = "a node-local cluster key-encryption key";
const TEST_SECRET: Secret = [_]u8{0x5A} ** SECRET_LEN;

fn tmpDirPath(buf: []u8) []const u8 {
    const p = std.fmt.bufPrint(buf, "/tmp/rove-keyring-test-{x}", .{std.crypto.random.int(u64)}) catch
        unreachable;
    std.fs.cwd().makePath(p) catch unreachable;
    return p;
}

fn cleanup(dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
}

test "slot to shard is a contiguous range mapping" {
    try testing.expectEqual(@as(u32, 0), shardOf(crypt.FIRST_SLOT));
    try testing.expectEqual(@as(u32, 0), shardOf(SLOTS_PER_SHARD - 1));
    try testing.expectEqual(@as(u32, 1), shardOf(SLOTS_PER_SHARD));
    try testing.expectEqual(@as(u64, 0), shardBase(0));
    try testing.expectEqual(SLOTS_PER_SHARD, shardBase(1));

    // Capacity is a property of the mapping, not a limit to enforce: a
    // shard's range simply cannot hold more slots than it contains.
    try testing.expectEqual(
        SLOTS_PER_SHARD,
        shardBase(1) - shardBase(0),
    );
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), shardOf(MAX_SLOT));
}

test "create then open round-trips the secret and its keys" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var minted: crypt.Key = undefined;
    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        try kr.mintRange(1, 4, 1234);
        try testing.expectEqual(@as(usize, 4), kr.count());
        minted = kr.keyAt(1).?;
    }

    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expectEqualSlices(u8, &TEST_SECRET, kr.tenantSecret());
    try testing.expectEqual(@as(usize, 4), kr.count());
    try testing.expectEqualSlices(u8, &minted, &kr.keyAt(1).?);
    try testing.expect(kr.keyAt(5) == null);
}

test "minting is idempotent — a retry never strands a live key" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    try kr.mintRange(1, 4, 1);
    const first = kr.keyAt(2).?;
    // An overlapping retry must keep every key that already exists;
    // minting fresh ones over them would strand everything they sealed.
    try kr.mintRange(1, 8, 2);
    try testing.expectEqualSlices(u8, &first, &kr.keyAt(2).?);
    try testing.expectEqual(@as(usize, 8), kr.count());
}

test "a range spanning shards writes each of them" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    const from = SLOTS_PER_SHARD - 2;
    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        try kr.mintRange(from, 4, 1);
        try testing.expectEqual(@as(u32, 2), kr.shard_counts.get(0).?);
        try testing.expectEqual(@as(u32, 2), kr.shard_counts.get(1).?);
    }

    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expectEqual(@as(usize, 4), kr.count());
    try testing.expect(kr.keyAt(from) != null);
    try testing.expect(kr.keyAt(from + 3) != null);
}

test "an out-of-range or wrapping mint is refused, never wrapped into shard 0" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    // Slot 0 is the reserved tenant ref, not an allocatable slot.
    try testing.expectError(Error.SlotOutOfRange, kr.mintRange(0, 1, 1));
    try testing.expectError(Error.SlotOutOfRange, kr.mintRange(MAX_SLOT, 2, 1));
    // A wrapped range would silently mint into shard 0 over live keys.
    try testing.expectError(
        Error.SlotOutOfRange,
        kr.mintRange(std.math.maxInt(u64) - 1, 4, 1),
    );
    try testing.expectEqual(@as(usize, 0), kr.count());
}

test "destroy removes the key from memory AND the live shard" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kept: crypt.Key = undefined;
    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        try kr.mintRange(1, 3, 1);
        kept = kr.keyAt(3).?;

        try testing.expect(try kr.destroy(2));
        try testing.expect(kr.keyAt(2) == null);
        // Already-gone is not an error — an audit needs to tell the two
        // apart without either failing.
        try testing.expect(!try kr.destroy(2));
    }

    // The decisive assertion: after reopening from disk the destroyed
    // key is still gone. A store that only forgot in memory would pass
    // every check above and fail this one.
    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expect(kr.keyAt(2) == null);
    try testing.expectEqualSlices(u8, &kept, &kr.keyAt(3).?);
    try testing.expectEqual(@as(usize, 2), kr.count());
}

test "a destroyed key can no longer open what it sealed" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    const slot: u64 = 7;
    try kr.mintRange(slot, 1, 1);
    const ref = crypt.refForSlot(slot);
    const sealed = try crypt.sealAlloc(
        testing.allocator,
        "personal data",
        kr.keyAt(slot).?,
        ref,
        1,
    );
    defer testing.allocator.free(sealed);

    // Readable while the key lives, and reachable straight from the
    // ciphertext header — the envelope's ref IS the slot, so no binding
    // lookup stands between a reader and its key.
    const h = try crypt.peek(sealed);
    const opened = try crypt.openAlloc(testing.allocator, sealed, kr.keyForRef(h.key_ref).?);
    testing.allocator.free(opened);

    _ = try kr.destroy(slot);

    // Afterwards the bytes still exist and simply cannot be read. That
    // is the whole property, stated as a test.
    try testing.expect(kr.keyForRef(h.key_ref) == null);
    try testing.expectEqual(slot, crypt.slotForRef(h.key_ref));
}

test "emptying a shard leaves no file behind" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();
    try kr.mintRange(1, 2, 1);

    const path = try kr.shardPath(0);
    defer testing.allocator.free(path);
    try std.fs.cwd().access(path, .{});

    _ = try kr.destroy(1);
    try std.fs.cwd().access(path, .{}); // still one key left
    _ = try kr.destroy(2);
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
    try testing.expectEqual(@as(usize, 0), kr.count());
}

test "a destroy rewrites its OWN shard and leaves the others byte-identical" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    // Three shards. Refills append at the tail, but a destroy can land
    // anywhere — it must rewrite the shard that holds the slot, not the
    // shard that happens to be current.
    try kr.mintRange(1, SLOTS_PER_SHARD * 2 + 5, 1);

    const before_1 = (try readSealedShard(testing.allocator, dir, "acme", TEST_KEK, 1)).?;
    defer testing.allocator.free(before_1);
    const before_2 = (try readSealedShard(testing.allocator, dir, "acme", TEST_KEK, 2)).?;
    defer testing.allocator.free(before_2);

    // Destroy in shard 0 — the oldest, furthest from the tail.
    try testing.expect(try kr.destroy(3));

    const after_1 = (try readSealedShard(testing.allocator, dir, "acme", TEST_KEK, 1)).?;
    defer testing.allocator.free(after_1);
    const after_2 = (try readSealedShard(testing.allocator, dir, "acme", TEST_KEK, 2)).?;
    defer testing.allocator.free(after_2);

    // Untouched shards are byte-identical: not merely equivalent in
    // content, but not rewritten at all. A fresh seal would differ in
    // its nonce even for identical entries, so equality here proves no
    // write happened.
    try testing.expectEqualSlices(u8, before_1, after_1);
    try testing.expectEqualSlices(u8, before_2, after_2);

    var reopened = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer reopened.deinit();
    try testing.expect(reopened.keyAt(3) == null);
    try testing.expect(reopened.keyAt(2) != null);
    try testing.expect(reopened.keyAt(SLOTS_PER_SHARD) != null);
    try testing.expect(reopened.keyAt(SLOTS_PER_SHARD * 2) != null);
}

test "emptying a middle shard removes only its file" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    // One key in each of shards 0, 1, 2 — sparse, which is the shape a
    // churning tenant ends up with since slots are never reused.
    try kr.mintRange(1, 1, 1);
    try kr.mintRange(SLOTS_PER_SHARD, 1, 1);
    try kr.mintRange(SLOTS_PER_SHARD * 2, 1, 1);

    const mid = try kr.shardPath(1);
    defer testing.allocator.free(mid);
    try std.fs.cwd().access(mid, .{});

    try testing.expect(try kr.destroy(SLOTS_PER_SHARD));
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(mid, .{}));

    var reopened = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 2), reopened.count());
    try testing.expect(reopened.keyAt(1) != null);
    try testing.expect(reopened.keyAt(SLOTS_PER_SHARD * 2) != null);
}

test "one rewrite is bounded by a shard, not by the tenant's total" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    // Four shards' worth of keys. A refill into the tail shard rewrites
    // that shard alone, so cost is flat in the tenant's size — the
    // property sharding exists to provide.
    try kr.mintRange(1, SLOTS_PER_SHARD * 3 + 10, 1);
    try testing.expectEqual(@as(usize, SLOTS_PER_SHARD * 3 + 10), kr.count());

    var largest: u64 = 0;
    var total: u64 = 0;
    for ([_]u32{ 0, 1, 2, 3 }) |s| {
        const p = try kr.shardPath(s);
        defer testing.allocator.free(p);
        const st = std.fs.cwd().statFile(p) catch continue;
        total += st.size;
        if (st.size > largest) largest = st.size;
        try testing.expect(st.size <= crypt.OVERHEAD + MAX_SHARD_BYTES);
    }
    try testing.expect(total > largest);
}

test "destroyAll removes the tenant directory — the tenant-level shred" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        try kr.mintRange(1, 4, 1);
        try kr.destroyAll();
        try testing.expectEqual(@as(usize, 0), kr.count());
        try testing.expectError(error.FileNotFound, std.fs.cwd().access(kr.tenant_dir, .{}));
    }

    try testing.expectError(
        Error.NoKeyring,
        Keyring.open(testing.allocator, dir, "acme", TEST_KEK),
    );
}

test "a destroyed keyring refuses to mint rather than resurrect the tenant" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();
    try kr.mintRange(1, 2, 1);
    try kr.destroyAll();

    // The secret is zeroed by destroyAll, so minting on this handle
    // would seal under a key derived from zeroes and write a keyring
    // back for a tenant that no longer exists.
    try testing.expectError(Error.NoKeyring, kr.mintRange(3, 1, 2));
    try testing.expect(!try kr.destroy(1));
}

test "a wrong KEK is refused" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        try kr.mintRange(1, 1, 1);
    }

    try testing.expectError(
        Error.AuthFailed,
        Keyring.open(testing.allocator, dir, "acme", "the wrong kek"),
    );
}

test "tenants are isolated — one KEK, different directories and file keys" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var a = try Keyring.create(testing.allocator, dir, "tenant-a", TEST_KEK, TEST_SECRET);
    defer a.deinit();
    const b_secret: Secret = [_]u8{0x11} ** SECRET_LEN;
    var b = try Keyring.create(testing.allocator, dir, "tenant-b", TEST_KEK, b_secret);
    defer b.deinit();

    try testing.expect(!std.mem.eql(u8, a.tenant_dir, b.tenant_dir));
    try testing.expect(!std.mem.eql(u8, &a.file_key, &b.file_key));

    // The same slot in two tenants names two unrelated keys, so one
    // tenant's shred can never reach into another's.
    try a.mintRange(1, 1, 1);
    try testing.expect(b.keyAt(1) == null);
}

test "opening a missing keyring says NoKeyring, not corrupt" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    try testing.expectError(
        Error.NoKeyring,
        Keyring.open(testing.allocator, dir, "never-attached", TEST_KEK),
    );
}

test "create refuses to clobber an existing keyring" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    kr.deinit();

    // A second create would mint a fresh secret over the live one and
    // strand every byte the tenant has sealed.
    try testing.expectError(
        Error.KeyringExists,
        Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET),
    );
}

test "a garbage shard file is corrupt, never silently accepted" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    try kr.mintRange(1, 1, 1);
    const path = try kr.shardPath(0);
    const owned = testing.allocator.dupe(u8, path) catch unreachable;
    testing.allocator.free(path);
    defer testing.allocator.free(owned);
    kr.deinit();

    const f = try std.fs.cwd().createFile(owned, .{ .truncate = true });
    try f.writeAll("not an envelope");
    f.close();

    const err = Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    try testing.expect(err == Error.Corrupt or err == Error.AuthFailed);
}

test "audit lists slots and mint times without exposing key material" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();
    try kr.mintRange(1, 3, 111);

    const rows = try kr.audit(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);

    var slot_sum: u64 = 0;
    for (rows) |r| {
        slot_sum += r.slot;
        try testing.expectEqual(@as(i64, 111), r.created_unix_ns);
    }
    try testing.expectEqual(@as(u64, 6), slot_sum);
}

// ── replication seam ─────────────────────────────────────────────────

test "replication: a shard sent from one node opens on another" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    var minted: crypt.Key = undefined;
    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
        defer a.deinit();
        try a.mintRange(1, 3, 1);
        minted = a.keyAt(2).?;
    }
    {
        var b = try Keyring.create(testing.allocator, node_b, "acme", TEST_KEK, TEST_SECRET);
        b.deinit();
    }

    // The seam: ship the sealed bytes verbatim and install them.
    const sealed = (try readSealedShard(testing.allocator, node_a, "acme", TEST_KEK, 0)).?;
    defer testing.allocator.free(sealed);
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, 0, sealed);

    // Node B now holds the same keys — the property the whole design
    // rests on: a sealed shard is portable ciphertext, because the file
    // key derives from the cluster KEK and the tenant id alone.
    var b = try Keyring.open(testing.allocator, node_b, "acme", TEST_KEK);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 3), b.count());
    try testing.expectEqualSlices(u8, &minted, &b.keyAt(2).?);
}

test "replication: an empty install removes the shard, propagating a destroy" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    {
        var b = try Keyring.create(testing.allocator, node_b, "acme", TEST_KEK, TEST_SECRET);
        defer b.deinit();
        try b.mintRange(1, 1, 1);
        try testing.expect(b.keyAt(1) != null);
    }

    // A shard that emptied has no file, so `readSealedShard` yields
    // null and the transfer carries zero bytes. Installing that must
    // remove the receiver's copy, not leave it stale.
    var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
    a.deinit();
    try testing.expect((try readSealedShard(testing.allocator, node_a, "acme", TEST_KEK, 0)) == null);
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, 0, "");

    var b = try Keyring.open(testing.allocator, node_b, "acme", TEST_KEK);
    defer b.deinit();
    try testing.expect(b.keyAt(1) == null);
}

test "replication: a peer under a different KEK is refused at install" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", "kek-one", TEST_SECRET);
        defer a.deinit();
        try a.mintRange(1, 1, 1);
    }
    const sealed = (try readSealedShard(testing.allocator, node_a, "acme", "kek-one", 0)).?;
    defer testing.allocator.free(sealed);

    // Caught on receipt rather than at the next open. An unverified
    // install surfaces at a failover — the moment the peer's copy
    // becomes the only copy.
    try testing.expectError(Error.AuthFailed, installSealedShard(
        testing.allocator,
        node_b,
        "acme",
        "kek-two",
        0,
        sealed,
    ));
}

test "replication: corrupt bytes and a wrong shard index are refused at install" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
        defer a.deinit();
        try a.mintRange(1, 1, 1);
    }
    const sealed = (try readSealedShard(testing.allocator, node_a, "acme", TEST_KEK, 0)).?;
    defer testing.allocator.free(sealed);

    // Delivered under the wrong index: the shard is self-describing, so
    // this is caught rather than filed where nothing routes to it.
    try testing.expectError(Error.Corrupt, installSealedShard(
        testing.allocator,
        node_b,
        "acme",
        TEST_KEK,
        1,
        sealed,
    ));

    const tampered = try testing.allocator.dupe(u8, sealed);
    defer testing.allocator.free(tampered);
    tampered[tampered.len - 1] ^= 0x01;
    try testing.expectError(Error.AuthFailed, installSealedShard(
        testing.allocator,
        node_b,
        "acme",
        TEST_KEK,
        0,
        tampered,
    ));

    // Nothing was written by either rejected install.
    try testing.expectError(
        Error.NoKeyring,
        Keyring.open(testing.allocator, node_b, "acme", TEST_KEK),
    );
}

test "replication: installing is idempotent, so a retried push is safe" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    var minted: crypt.Key = undefined;
    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
        defer a.deinit();
        try a.mintRange(1, 2, 1);
        minted = a.keyAt(1).?;
    }
    {
        var b = try Keyring.create(testing.allocator, node_b, "acme", TEST_KEK, TEST_SECRET);
        b.deinit();
    }

    const sealed = (try readSealedShard(testing.allocator, node_a, "acme", TEST_KEK, 0)).?;
    defer testing.allocator.free(sealed);

    // A push that times out but landed will be retried; the second
    // install must be a no-op rather than corrupting the first.
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, 0, sealed);
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, 0, sealed);

    var b = try Keyring.open(testing.allocator, node_b, "acme", TEST_KEK);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 2), b.count());
    try testing.expectEqualSlices(u8, &minted, &b.keyAt(1).?);
}
