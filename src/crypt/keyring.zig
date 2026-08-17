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
//!   destroy one identity  → rewrite its shard without that entry
//!   destroy the tenant    → remove the tenant's directory
//!
//! ## Why a rewrite is a real delete, and what it is not
//!
//! Rewrite-and-rename allocates new blocks; it does not overwrite the
//! old ones, and on flash nothing at this layer can. Effectiveness comes
//! from two other things:
//!
//!  1. The files are **sealed under the KEK**, which lives only in node
//!     configuration and never on disk. Whatever an old block still
//!     holds is ciphertext — useless to anyone reading a decommissioned
//!     disk, a backup, or an object store.
//!  2. The **live** file stops containing the key. That is the whole
//!     difference from a log, where a destroyed key remains in the
//!     current, in-use file forever, readable by every legitimate
//!     reader.
//!
//! So the guarantee is: erasure is effective against everyone without
//! the KEK, and the KEK is the one secret that never touches storage.
//! It is not a claim about physical overwrite.
//!
//! ## Why sharded
//!
//! One file per tenant makes a mint cost a rewrite of every key that
//! tenant has — quadratic to fill, and a tenant with thousands of
//! identities rewrites hundreds of KB to add 48 bytes. Splitting by the
//! first byte of the key ref spreads entries over `SHARD_COUNT` files,
//! so a mint rewrites `entries / SHARD_COUNT` of them. Refs are HMAC
//! output, so the split is uniform without any balancing.
//!
//! Each shard is still rewritten WHOLE, so the property above is
//! untouched: sharding changes only how much a rewrite costs, never
//! whether a destroyed key survives in a live file. `MAX_ENTRIES_PER_
//! SHARD` is what bounds that cost; the per-tenant total is derived from
//! it rather than chosen, so the two can never drift apart.
//!
//! A shard file exists only while it holds entries — an absent file is
//! an empty shard — so a small tenant costs a handful of files and a
//! fully-shredded one costs none.
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
//! Node-local storage only. Minting the tenant secret, delivering it to
//! every node, replicating keyrings, and invalidating caches on destroy
//! are the surrounding work; this file is what they store into.

const std = @import("std");
const crypt = @import("root.zig");

/// Length of a tenant's root secret. The HKDF root for every key
/// derived for that tenant, and the thing whose destruction is a C1
/// shred.
pub const SECRET_LEN: usize = 32;

pub const Secret = [SECRET_LEN]u8;

/// Shards per tenant, indexed by `key_ref[0]`. One per possible value of
/// that byte, so the mapping is a byte read rather than a modulus and
/// cannot be got wrong.
pub const SHARD_COUNT: usize = 256;

/// Entries in ONE shard. This is the real bound: it caps how much a
/// single mint or destroy rewrites, which is the cost that actually
/// bites. 4096 × 48 B keeps a rewrite under 192 KiB even for a shard
/// that has drifted well above its share.
pub const MAX_ENTRIES_PER_SHARD: usize = 4096;

/// Per-tenant capacity, DERIVED so it cannot drift from the bound that
/// does the work. Refs distribute uniformly, so a tenant approaching
/// this total is nowhere near a full shard.
pub const MAX_ENTRIES: usize = SHARD_COUNT * MAX_ENTRIES_PER_SHARD;

const SHARD_MAGIC: u32 = 0x524B5231; // 'RKR1'
const SECRET_MAGIC: u32 = 0x524B5331; // 'RKS1'
const FORMAT_VERSION: u16 = 1;

/// `[4B magic][2B version][1B shard][4B count]`
const SHARD_HEADER_LEN: usize = 4 + 2 + 1 + 4;
/// `[4B magic][2B version][32B secret]`
const SECRET_FILE_LEN: usize = 4 + 2 + SECRET_LEN;
/// `[8B key_ref][32B key][8B created_unix_ns]`
const ENTRY_LEN: usize = crypt.KEY_REF_LEN + crypt.KEY_LEN + 8;

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
    /// One shard is full. Reported rather than silently spilling: a
    /// spill would mean a mint rewriting more than the bound promises.
    ShardFull,
    Io,
    OutOfMemory,
};

const Entry = struct {
    key: crypt.Key,
    created_unix_ns: i64,
};

/// One entry as an audit surface sees it — no key material.
pub const AuditEntry = struct {
    key_ref: crypt.KeyRef,
    created_unix_ns: i64,
};

/// Which shard a ref belongs to. The single definition — every reader
/// and writer routes through it, so a shard can never be written under
/// one rule and looked for under another.
pub fn shardOf(key_ref: crypt.KeyRef) u8 {
    return key_ref[0];
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
    /// Every entry, across all shards. Lookups stay one hash probe —
    /// sharding is a persistence concern, not a lookup one.
    entries: std.AutoHashMapUnmanaged(crypt.KeyRef, Entry) = .empty,
    /// Live count per shard, so a rewrite can size its buffer without
    /// walking the whole map.
    shard_counts: [SHARD_COUNT]u32 = [_]u32{0} ** SHARD_COUNT,
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
        var it = self.entries.iterator();
        while (it.next()) |e| std.crypto.secureZero(u8, &e.value_ptr.key);
        self.entries.deinit(self.allocator);
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
        return self.entries.count();
    }

    /// Look up an identity key. `null` means shredded (or never minted)
    /// — callers surface that as not-found, never as an error, because
    /// "erased" should read like "absent" to everything downstream.
    pub fn get(self: *const Self, key_ref: crypt.KeyRef) ?crypt.Key {
        return (self.entries.get(key_ref) orelse return null).key;
    }

    /// Mint an identity key, or return the existing one.
    ///
    /// Idempotent by construction: a retried request that minted a
    /// second key would strand everything the first key sealed, which
    /// looks exactly like data loss and is unrecoverable.
    ///
    /// Rewrites one shard, not the whole keyring.
    pub fn mint(self: *Self, key_ref: crypt.KeyRef, now_unix_ns: i64) Error!crypt.Key {
        if (self.destroyed) return Error.NoKeyring;
        if (self.entries.get(key_ref)) |e| return e.key;

        const shard = shardOf(key_ref);
        if (self.shard_counts[shard] >= MAX_ENTRIES_PER_SHARD) return Error.ShardFull;

        var key: crypt.Key = undefined;
        std.crypto.random.bytes(&key);
        self.entries.put(self.allocator, key_ref, .{
            .key = key,
            .created_unix_ns = now_unix_ns,
        }) catch return Error.OutOfMemory;
        self.shard_counts[shard] += 1;

        self.flushShard(shard) catch |err| {
            // Roll back so memory cannot claim a key the disk will not
            // have after a restart. Handing out a key that does not
            // survive is how data gets sealed under something
            // unrecoverable.
            _ = self.entries.remove(key_ref);
            self.shard_counts[shard] -= 1;
            return err;
        };
        return key;
    }

    /// Destroy an identity key. Returns whether it existed, so a caller
    /// can distinguish "shredded now" from "already gone" for audit
    /// without either being an error.
    ///
    /// On return the key is absent from the live shard. Everything it
    /// sealed — kv values, log frames, tapes, pooled bodies, and any
    /// copy in a backup — is unreadable from this point.
    pub fn destroy(self: *Self, key_ref: crypt.KeyRef) Error!bool {
        if (self.destroyed) return false;
        var removed = self.entries.fetchRemove(key_ref) orelse return false;
        // Wiped only once the rewrite lands — the rollback below needs
        // these bytes if it does not.
        defer std.crypto.secureZero(u8, &removed.value.key);

        const shard = shardOf(key_ref);
        self.shard_counts[shard] -= 1;

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
            self.entries.putAssumeCapacity(key_ref, removed.value);
            self.shard_counts[shard] += 1;
            return err;
        };
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

        var it = self.entries.iterator();
        while (it.next()) |e| std.crypto.secureZero(u8, &e.value_ptr.key);
        self.entries.clearRetainingCapacity();
        self.shard_counts = [_]u32{0} ** SHARD_COUNT;
        std.crypto.secureZero(u8, &self.secret);
        self.destroyed = true;
    }

    /// Enumerate refs and mint times, never key material. Caller frees.
    pub fn audit(self: *const Self, allocator: std.mem.Allocator) Error![]AuditEntry {
        const out = allocator.alloc(AuditEntry, self.entries.count()) catch
            return Error.OutOfMemory;
        var i: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = .{
                .key_ref = e.key_ptr.*,
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

    fn shardPath(self: *const Self, shard: u8) Error![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{x:0>2}.kr",
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

        const plain = self.readSealed(path) catch |err| switch (err) {
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
    /// directory listing IS the shard set — no probing 256 paths for a
    /// tenant that has three keys.
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

    /// `{NN}.kr` → shard NN. Anything else (the secret file, a leftover
    /// `.tmp.*` from an interrupted rewrite) is not a shard.
    fn parseShardName(name: []const u8) ?u8 {
        if (name.len != 5) return null;
        if (!std.mem.eql(u8, name[2..], ".kr")) return null;
        return std.fmt.parseInt(u8, name[0..2], 16) catch null;
    }

    fn readShard(self: *Self, shard: u8) Error!void {
        const path = try self.shardPath(shard);
        defer self.allocator.free(path);

        const plain = self.readSealed(path) catch |err| switch (err) {
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

        self.entries.ensureUnusedCapacity(self.allocator, n) catch return Error.OutOfMemory;
        var pos: usize = SHARD_HEADER_LEN;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var ref: crypt.KeyRef = undefined;
            @memcpy(&ref, plain[pos..][0..crypt.KEY_REF_LEN]);
            pos += crypt.KEY_REF_LEN;
            var key: crypt.Key = undefined;
            @memcpy(&key, plain[pos..][0..crypt.KEY_LEN]);
            pos += crypt.KEY_LEN;
            const created = std.mem.readInt(i64, plain[pos..][0..8], .little);
            pos += 8;
            self.entries.putAssumeCapacity(ref, .{ .key = key, .created_unix_ns = created });
        }
        self.shard_counts[shard] = n;
    }

    /// Rewrite one shard whole. Never appends: an append-only keyring
    /// would keep destroyed keys in the live file, which is precisely
    /// what this store exists to avoid.
    ///
    /// An emptied shard is removed rather than written as a zero-entry
    /// file, so a fully-shredded tenant leaves no shard behind.
    fn flushShard(self: *Self, shard: u8) Error!void {
        const path = try self.shardPath(shard);
        defer self.allocator.free(path);

        const n = self.shard_counts[shard];
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
        plain[6] = shard;
        std.mem.writeInt(u32, plain[7..11], n, .little);

        var pos: usize = SHARD_HEADER_LEN;
        var it = self.entries.iterator();
        while (it.next()) |e| {
            if (shardOf(e.key_ptr.*) != shard) continue;
            @memcpy(plain[pos..][0..crypt.KEY_REF_LEN], e.key_ptr);
            pos += crypt.KEY_REF_LEN;
            @memcpy(plain[pos..][0..crypt.KEY_LEN], &e.value_ptr.key);
            pos += crypt.KEY_LEN;
            std.mem.writeInt(i64, plain[pos..][0..8], e.value_ptr.created_unix_ns, .little);
            pos += 8;
        }
        // `shard_counts` drives the buffer size, so a disagreement with
        // what the map actually holds would truncate or leave a tail of
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

    fn readSealed(self: *Self, path: []const u8) Error![]u8 {
        const max = crypt.OVERHEAD + SHARD_HEADER_LEN + MAX_ENTRIES_PER_SHARD * ENTRY_LEN;
        const sealed = std.fs.cwd().readFileAlloc(self.allocator, path, max) catch |err| switch (err) {
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
fn validateShardPlain(plain: []const u8, shard: u8) Error!u32 {
    if (plain.len < SHARD_HEADER_LEN) return Error.Corrupt;
    if (std.mem.readInt(u32, plain[0..4], .big) != SHARD_MAGIC) return Error.Corrupt;
    if (std.mem.readInt(u16, plain[4..6], .little) != FORMAT_VERSION) return Error.Corrupt;
    // The shard records which shard it is, so a file moved, renamed, or
    // delivered under the wrong index is caught instead of silently
    // scattering entries into a rewrite set nothing will ever route to.
    if (plain[6] != shard) return Error.Corrupt;

    const n = std.mem.readInt(u32, plain[7..11], .little);
    if (n > MAX_ENTRIES_PER_SHARD) return Error.Corrupt;
    // The count and the byte length must agree exactly. A trailing
    // remainder means the file is not what it claims, and a keyring is
    // the last place to be lenient about that.
    if (plain.len != SHARD_HEADER_LEN + @as(usize, n) * ENTRY_LEN) return Error.Corrupt;

    var pos: usize = SHARD_HEADER_LEN;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // A ref filed under the wrong shard would be unreachable by
        // every later mint and destroy, which route by `shardOf`.
        if (shardOf(plain[pos..][0..crypt.KEY_REF_LEN].*) != shard) return Error.Corrupt;
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
    shard: u8,
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
    shard: u8,
) Error!?[]u8 {
    var kr = try Keyring.init(allocator, base_dir, tenant_id, kek);
    defer kr.deinit();

    const path = try kr.shardPath(shard);
    defer allocator.free(path);

    const max = crypt.OVERHEAD + SHARD_HEADER_LEN + MAX_ENTRIES_PER_SHARD * ENTRY_LEN;
    return std.fs.cwd().readFileAlloc(allocator, path, max) catch |err| switch (err) {
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

const TEST_KEK = "a node-local key-encryption key, never on disk";
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

/// Refs whose FIRST byte varies, so successive `refOf` values land in
/// different shards — the property most of these tests depend on.
fn refOf(n: u8) crypt.KeyRef {
    return [_]u8{ n, 2, 3, 4, 5, 6, 7, 8 };
}

/// Refs sharing a first byte, so they collide into ONE shard.
fn sameShardRef(n: u8) crypt.KeyRef {
    return [_]u8{ 0x7F, n, 3, 4, 5, 6, 7, 8 };
}

test "create then open round-trips the secret and its entries" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var minted: crypt.Key = undefined;
    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        minted = try kr.mint(refOf(1), 1234);
        try testing.expectEqual(@as(usize, 1), kr.count());
    }

    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expectEqualSlices(u8, &TEST_SECRET, kr.tenantSecret());
    try testing.expectEqual(@as(usize, 1), kr.count());
    try testing.expectEqualSlices(u8, &minted, &kr.get(refOf(1)).?);
}

test "minting is idempotent — a retry never strands the first key" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    const first = try kr.mint(refOf(1), 1);
    const again = try kr.mint(refOf(1), 2);
    try testing.expectEqualSlices(u8, &first, &again);
    try testing.expectEqual(@as(usize, 1), kr.count());
}

test "destroy removes the key from memory AND the live shard" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    const doomed = refOf(1);
    const kept = refOf(2);
    var kept_key: crypt.Key = undefined;

    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        _ = try kr.mint(doomed, 1);
        kept_key = try kr.mint(kept, 2);

        try testing.expect(try kr.destroy(doomed));
        try testing.expect(kr.get(doomed) == null);
        // Already-gone is not an error — an audit needs to tell the two
        // apart without either failing.
        try testing.expect(!try kr.destroy(doomed));
    }

    // The decisive assertion: after reopening from disk the destroyed
    // key is still gone. A store that only forgot in memory would pass
    // every check above and fail this one.
    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expect(kr.get(doomed) == null);
    try testing.expectEqualSlices(u8, &kept_key, &kr.get(kept).?);
    try testing.expectEqual(@as(usize, 1), kr.count());
}

test "destroy rewrites only the shard, leaving co-resident entries intact" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    // All three share a first byte, so all three live in one shard and
    // the destroy forces a genuine re-encode rather than an unlink.
    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        _ = try kr.mint(sameShardRef(1), 1);
        _ = try kr.mint(sameShardRef(2), 2);
        _ = try kr.mint(sameShardRef(3), 3);
        try testing.expectEqual(@as(u32, 3), kr.shard_counts[0x7F]);
        try testing.expect(try kr.destroy(sameShardRef(2)));
    }

    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expectEqual(@as(usize, 2), kr.count());
    try testing.expectEqual(@as(u32, 2), kr.shard_counts[0x7F]);
    try testing.expect(kr.get(sameShardRef(1)) != null);
    try testing.expect(kr.get(sameShardRef(2)) == null);
    try testing.expect(kr.get(sameShardRef(3)) != null);
}

test "entries spread across shards, and an emptied shard leaves no file" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    _ = try kr.mint(refOf(0x11), 1);
    _ = try kr.mint(refOf(0x22), 2);
    try testing.expectEqual(@as(u32, 1), kr.shard_counts[0x11]);
    try testing.expectEqual(@as(u32, 1), kr.shard_counts[0x22]);

    const path = try kr.shardPath(0x11);
    defer testing.allocator.free(path);
    try std.fs.cwd().access(path, .{});

    // Emptying a shard removes its file rather than leaving a
    // zero-entry one, so a fully-shredded tenant leaves nothing behind.
    _ = try kr.destroy(refOf(0x11));
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
    try testing.expectEqual(@as(usize, 1), kr.count());
}

test "a full shard is refused rather than rewriting past the bound" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    // Fill one shard to its cap without touching the filesystem for
    // every entry — the bound is what is under test, not the rewrite.
    kr.shard_counts[0x7F] = MAX_ENTRIES_PER_SHARD;
    try testing.expectError(Error.ShardFull, kr.mint(sameShardRef(9), 1));

    // A different shard is unaffected: the bound is per-shard, which is
    // the whole point of it being the bound that matters.
    kr.shard_counts[0x7F] = 0;
    _ = try kr.mint(refOf(0x01), 1);
}

test "the derived total capacity cannot drift from the per-shard bound" {
    try testing.expectEqual(SHARD_COUNT * MAX_ENTRIES_PER_SHARD, MAX_ENTRIES);
    // A rewrite is bounded by one shard, not by the tenant's total. This
    // is the invariant the sharding exists to provide.
    try testing.expect(MAX_ENTRIES_PER_SHARD * ENTRY_LEN <= 256 * 1024);
}

test "a mint rewrites a fraction of the keyring, not all of it" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    const n: u16 = 1024;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        // Vary the first byte (the shard) and a second byte, so entries
        // spread over every shard rather than 256 of them colliding.
        const ref = crypt.KeyRef{ @truncate(i), @truncate(i >> 8), 3, 4, 5, 6, 7, 8 };
        _ = try kr.mint(ref, i);
    }
    try testing.expectEqual(@as(usize, n), kr.count());

    // The cost that matters is the biggest single shard, because that is
    // what one more mint rewrites. Unsharded it would be every entry.
    var largest: u64 = 0;
    var total: u64 = 0;
    var s: usize = 0;
    while (s < SHARD_COUNT) : (s += 1) {
        const path = try kr.shardPath(@intCast(s));
        defer testing.allocator.free(path);
        const stat = std.fs.cwd().statFile(path) catch continue;
        total += stat.size;
        if (stat.size > largest) largest = stat.size;
    }

    // 1024 entries over 256 shards is 4 apiece, so a rewrite touches a
    // small multiple of one entry rather than 1024 of them. Asserting a
    // ratio rather than a byte count keeps this meaningful if ENTRY_LEN
    // or the envelope overhead changes.
    try testing.expect(total > 0);
    try testing.expect(largest * 16 < total);
}

test "a destroyed key can no longer open what it sealed" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();

    const ref = refOf(1);
    const key = try kr.mint(ref, 1);
    const sealed = try crypt.sealAlloc(testing.allocator, "personal data", key, ref, 1);
    defer testing.allocator.free(sealed);

    // Readable while the key lives...
    const opened = try crypt.openAlloc(testing.allocator, sealed, kr.get(ref).?);
    testing.allocator.free(opened);

    _ = try kr.destroy(ref);

    // ...and afterwards the bytes still exist and simply cannot be read.
    // That is the whole property, stated as a test.
    try testing.expect(kr.get(ref) == null);
    const h = try crypt.peek(sealed);
    try testing.expectEqualSlices(u8, &ref, &h.key_ref);
}

test "destroyAll removes the tenant directory — the tenant-level shred" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        _ = try kr.mint(refOf(1), 1);
        _ = try kr.mint(refOf(2), 2);
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
    _ = try kr.mint(refOf(1), 1);
    try kr.destroyAll();

    // The secret is zeroed by destroyAll, so minting on this handle
    // would seal under a key derived from zeroes and write a keyring
    // back for a tenant that no longer exists.
    try testing.expectError(Error.NoKeyring, kr.mint(refOf(2), 2));
    try testing.expect(!try kr.destroy(refOf(1)));
}

test "a wrong KEK is refused" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        _ = try kr.mint(refOf(1), 1);
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

    // Separate directories, separate file keys, separate nonce budgets.
    try testing.expect(!std.mem.eql(u8, a.tenant_dir, b.tenant_dir));
    try testing.expect(!std.mem.eql(u8, &a.file_key, &b.file_key));

    // The same ref in two tenants names two unrelated keys, so one
    // tenant's shred can never reach into another's.
    _ = try a.mint(refOf(1), 1);
    try testing.expect(b.get(refOf(1)) == null);
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
    _ = try kr.mint(refOf(0x11), 1);
    const path = try kr.shardPath(0x11);
    defer testing.allocator.free(path);
    const owned_path = testing.allocator.dupe(u8, path) catch unreachable;
    defer testing.allocator.free(owned_path);
    kr.deinit();

    const f = try std.fs.cwd().createFile(owned_path, .{ .truncate = true });
    try f.writeAll("not an envelope");
    f.close();

    const err = Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    try testing.expect(err == Error.Corrupt or err == Error.AuthFailed);
}

test "a shard file holding the wrong shard's entries is refused" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    _ = try kr.mint(refOf(0x11), 1);
    const src = try kr.shardPath(0x11);
    defer testing.allocator.free(src);
    const dst = try kr.shardPath(0x22);
    defer testing.allocator.free(dst);
    const owned_src = testing.allocator.dupe(u8, src) catch unreachable;
    defer testing.allocator.free(owned_src);
    const owned_dst = testing.allocator.dupe(u8, dst) catch unreachable;
    defer testing.allocator.free(owned_dst);
    kr.deinit();

    // Renaming a shard would file its entries under an index no later
    // mint or destroy would ever route to, leaving them unreachable.
    // The self-describing shard byte catches it.
    try std.fs.cwd().rename(owned_src, owned_dst);
    try testing.expectError(
        Error.Corrupt,
        Keyring.open(testing.allocator, dir, "acme", TEST_KEK),
    );
}

test "audit lists refs and mint times without exposing key material" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
    defer kr.deinit();
    _ = try kr.mint(refOf(1), 111);
    _ = try kr.mint(refOf(2), 222);

    const rows = try kr.audit(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);

    var seen: i64 = 0;
    for (rows) |r| seen += r.created_unix_ns;
    try testing.expectEqual(@as(i64, 333), seen);
}

test "replication: a shard sent from one node opens on another" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    const ref = refOf(0x11);
    var minted: crypt.Key = undefined;

    // Node A mints. Node B is attached with the SAME tenant secret —
    // the CP delivers it at attach; only shards move over the wire.
    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
        defer a.deinit();
        minted = try a.mint(ref, 1);
    }
    {
        var b = try Keyring.create(testing.allocator, node_b, "acme", TEST_KEK, TEST_SECRET);
        b.deinit();
    }

    // The seam: ship the sealed bytes verbatim and install them.
    const sealed = (try readSealedShard(
        testing.allocator,
        node_a,
        "acme",
        TEST_KEK,
        shardOf(ref),
    )).?;
    defer testing.allocator.free(sealed);
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, shardOf(ref), sealed);

    // Node B now holds the same key — the property the whole design
    // rests on: a sealed shard is portable ciphertext, because the file
    // key derives from the cluster KEK and the tenant id alone.
    var b = try Keyring.open(testing.allocator, node_b, "acme", TEST_KEK);
    defer b.deinit();
    try testing.expectEqualSlices(u8, &minted, &b.get(ref).?);
}

test "replication: an empty install removes the shard, propagating a destroy" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    const ref = refOf(0x11);
    {
        var b = try Keyring.create(testing.allocator, node_b, "acme", TEST_KEK, TEST_SECRET);
        defer b.deinit();
        _ = try b.mint(ref, 1);
        try testing.expect(b.get(ref) != null);
    }

    // A shard that emptied has no file, so `readSealedShard` yields
    // null and the transfer carries zero bytes. Installing that must
    // remove the receiver's copy, not leave it stale.
    var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
    a.deinit();
    try testing.expect((try readSealedShard(
        testing.allocator,
        node_a,
        "acme",
        TEST_KEK,
        shardOf(ref),
    )) == null);
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, shardOf(ref), "");

    var b = try Keyring.open(testing.allocator, node_b, "acme", TEST_KEK);
    defer b.deinit();
    try testing.expect(b.get(ref) == null);
}

test "replication: a peer under a different KEK is refused at install" {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const node_a = tmpDirPath(&buf_a);
    defer cleanup(node_a);
    const node_b = tmpDirPath(&buf_b);
    defer cleanup(node_b);

    const ref = refOf(0x11);
    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", "kek-one", TEST_SECRET);
        defer a.deinit();
        _ = try a.mint(ref, 1);
    }
    const sealed = (try readSealedShard(
        testing.allocator,
        node_a,
        "acme",
        "kek-one",
        shardOf(ref),
    )).?;
    defer testing.allocator.free(sealed);

    // Caught on receipt rather than at the next open. An unverified
    // install surfaces at a failover — the moment the peer's copy
    // becomes the only copy.
    try testing.expectError(Error.AuthFailed, installSealedShard(
        testing.allocator,
        node_b,
        "acme",
        "kek-two",
        shardOf(ref),
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

    const ref = refOf(0x11);
    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
        defer a.deinit();
        _ = try a.mint(ref, 1);
    }
    const sealed = (try readSealedShard(
        testing.allocator,
        node_a,
        "acme",
        TEST_KEK,
        shardOf(ref),
    )).?;
    defer testing.allocator.free(sealed);

    // Delivered under the wrong index: the shard is self-describing, so
    // this is caught rather than filed where nothing routes to it.
    try testing.expectError(Error.Corrupt, installSealedShard(
        testing.allocator,
        node_b,
        "acme",
        TEST_KEK,
        shardOf(ref) +% 1,
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
        shardOf(ref),
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

    const ref = refOf(0x11);
    var minted: crypt.Key = undefined;
    {
        var a = try Keyring.create(testing.allocator, node_a, "acme", TEST_KEK, TEST_SECRET);
        defer a.deinit();
        minted = try a.mint(ref, 1);
    }
    {
        var b = try Keyring.create(testing.allocator, node_b, "acme", TEST_KEK, TEST_SECRET);
        b.deinit();
    }

    const sealed = (try readSealedShard(
        testing.allocator,
        node_a,
        "acme",
        TEST_KEK,
        shardOf(ref),
    )).?;
    defer testing.allocator.free(sealed);

    // A push that times out but landed will be retried; the second
    // install must be a no-op rather than corrupting the first.
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, shardOf(ref), sealed);
    try installSealedShard(testing.allocator, node_b, "acme", TEST_KEK, shardOf(ref), sealed);

    var b = try Keyring.open(testing.allocator, node_b, "acme", TEST_KEK);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.count());
    try testing.expectEqualSlices(u8, &minted, &b.get(ref).?);
}

test "many entries across many shards survive a reopen intact" {
    var buf: [64]u8 = undefined;
    const dir = tmpDirPath(&buf);
    defer cleanup(dir);

    const n: u16 = 256;
    {
        var kr = try Keyring.create(testing.allocator, dir, "acme", TEST_KEK, TEST_SECRET);
        defer kr.deinit();
        var i: u16 = 0;
        while (i < n) : (i += 1) _ = try kr.mint(refOf(@intCast(i)), i);
        try testing.expectEqual(@as(usize, n), kr.count());
        _ = try kr.destroy(refOf(128));
    }

    var kr = try Keyring.open(testing.allocator, dir, "acme", TEST_KEK);
    defer kr.deinit();
    try testing.expectEqual(@as(usize, n - 1), kr.count());
    try testing.expect(kr.get(refOf(128)) == null);
    try testing.expect(kr.get(refOf(0)) != null);
    try testing.expect(kr.get(refOf(255)) != null);
}
