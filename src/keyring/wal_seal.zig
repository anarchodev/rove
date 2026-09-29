// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Sealing raft WAL entries per tenant — the key half of the WAL's payload
//! codec (the WAL itself, in `raft-rs-zig`, knows nothing about keys).
//!
//! ## Why the WAL needs it
//!
//! The raft WAL is one file per node, every tenant's entries interleaved,
//! and it is the only place readsets live. A tenant keeps its last
//! `snapshot_grace` entries uncompacted, and the active segment rolls only
//! by size — so a quiet tenant's writes and reads, and a deprovisioned
//! tenant's in an unrolled segment, sit on disk with no time bound. No file
//! can be deleted for one tenant, because every file holds them all.
//!
//! So each tenant's entries are sealed under a key only that tenant's
//! keyring can produce: a subkey DERIVED from its stored secret. A derived
//! key is shreddable exactly when its root is — and this root is the
//! tenant's own stored secret, which a deprovision unlinks. Destroying the
//! keyring makes every entry the tenant ever wrote to any WAL unreadable at
//! once, whichever segment holds it.
//!
//! Only an entry's data is sealed. Framing, hard state and membership stay
//! plaintext, so a node never forgets its term or vote for want of a key.
//!
//! ## Which groups
//!
//! A tenant's group seals. The system groups — the root group and the CP's
//! directory — carry instance and domain rows rather than customer data and
//! stay plaintext. A group this node cannot attribute is neither: its key
//! is UNAVAILABLE, and the caller stalls the group rather than writing it in
//! the clear (`OwnerOf.unknown`).
//!
//! ## A key that is not here yet
//!
//! A replica can hold a tenant's group before its keyring — a voter added
//! after birth, a move destination — until the keyring driver pulls one.
//! Then this answers `error.KeyUnavailable`, never a plaintext fallback, and
//! the consensus layer holds the group still until it can. A missing
//! keyring is never cached, so the next attempt finds one that arrived.

const std = @import("std");
const crypt = @import("rove-crypt");
const keyspace = @import("keyspace.zig");
const seal_mod = @import("seal.zig");

/// Separates the WAL subkey from every other key derived from the same
/// per-tenant secret. Bump the version, never reuse it.
pub const LABEL = "rove-crypt/wal/v1";

/// Who a raft group belongs to, for sealing.
pub const Owner = union(enum) {
    /// A tenant: seal under its WAL subkey. The id is copied out, so the
    /// resolver's storage need not outlive the call.
    tenant: []const u8,
    /// A system group (root, directory): plaintext by design.
    plaintext,
    /// Not attributable on this node right now. Sealing refuses.
    unknown,
};

/// Resolves a group id to its owner. Called on the pump thread for every
/// append and at recovery — a map lookup, never I/O.
pub const OwnerOf = struct {
    ctx: *anyopaque,
    /// Write the tenant id into `buf` when the owner is a tenant.
    resolve: *const fn (ctx: *anyopaque, group_id: u64, buf: []u8) Owner,
};

pub const Error = error{
    /// The group wants sealing and this node holds no key for it yet.
    KeyUnavailable,
    OutOfMemory,
} || crypt.Error || crypt.keyring.Error;

pub const WalSeal = struct {
    allocator: std.mem.Allocator,
    keyring_dir: []u8,
    kek: []const u8,
    owner_of: OwnerOf,
    /// Derived subkeys by tenant id. Guarded by `lock`: appends run on the
    /// pump, and `forget` runs wherever a tenant is torn down.
    cache: std.StringHashMapUnmanaged(crypt.Key) = .empty,
    lock: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        kek: []const u8,
        owner_of: OwnerOf,
    ) !WalSeal {
        return .{
            .allocator = allocator,
            .keyring_dir = try keyspace.keyringDir(allocator, data_dir),
            .kek = kek,
            .owner_of = owner_of,
        };
    }

    pub fn deinit(self: *WalSeal) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            crypt.wipe(e.value_ptr);
            self.allocator.free(e.key_ptr.*);
        }
        self.cache.deinit(self.allocator);
        self.allocator.free(self.keyring_dir);
    }

    /// Seal `data` for `group_id`, or null when the group is plaintext.
    pub fn seal(self: *WalSeal, allocator: std.mem.Allocator, group_id: u64, data: []const u8) Error!?[]u8 {
        var key = (try self.keyFor(group_id)) orelse return null;
        defer crypt.wipe(&key);
        return try crypt.sealAlloc(allocator, data, key, crypt.TENANT_REF, seal_mod.KEY_VERSION);
    }

    /// Open sealed entry data for `group_id`.
    pub fn open(self: *WalSeal, allocator: std.mem.Allocator, group_id: u64, sealed: []const u8) Error![]u8 {
        // A sealed record for a group that resolves plaintext is a
        // contradiction, not a key to go looking for.
        var key = (try self.keyFor(group_id)) orelse return error.KeyUnavailable;
        defer crypt.wipe(&key);
        return try crypt.openAlloc(allocator, sealed, key);
    }

    /// Does this node hold `tenant`'s keyring, so its WAL entries can be
    /// sealed and opened? Reads the secret file; boot and attach only.
    pub fn holdsKeyFor(self: *WalSeal, tenant: []const u8) bool {
        var secret = (crypt.keyring.readTenantSecret(self.allocator, self.keyring_dir, tenant, self.kek) catch return false) orelse
            return false;
        std.crypto.secureZero(u8, &secret);
        return true;
    }

    /// Drop a tenant's cached key — at deprovision, so the key does not
    /// outlive its keyring in memory.
    pub fn forget(self: *WalSeal, tenant_id: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.cache.fetchRemove(tenant_id)) |kv| {
            var k = kv.value;
            crypt.wipe(&k);
            self.allocator.free(kv.key);
        }
    }

    /// The group's key, null for a plaintext group, or KeyUnavailable.
    fn keyFor(self: *WalSeal, group_id: u64) Error!?crypt.Key {
        var buf: [crypt.keyring.MAX_TENANT_ID_LEN]u8 = undefined;
        const tenant = switch (self.owner_of.resolve(self.owner_of.ctx, group_id, &buf)) {
            .plaintext => return null,
            .unknown => return error.KeyUnavailable,
            .tenant => |t| t,
        };

        self.lock.lock();
        defer self.lock.unlock();
        if (self.cache.get(tenant)) |k| return k;

        // Not cached negatively: a keyring the driver pulls later must be
        // found by the next attempt.
        var secret = (try crypt.keyring.readTenantSecret(self.allocator, self.keyring_dir, tenant, self.kek)) orelse
            return error.KeyUnavailable;
        defer std.crypto.secureZero(u8, &secret);
        const key = crypt.deriveSubkey(&secret, LABEL);

        const owned = try self.allocator.dupe(u8, tenant);
        errdefer self.allocator.free(owned);
        try self.cache.put(self.allocator, owned, key);
        return key;
    }
};

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// Group 1 → tenant "acme", 2 → plaintext, anything else → unknown.
const TestOwners = struct {
    fn resolve(_: *anyopaque, group_id: u64, buf: []u8) Owner {
        return switch (group_id) {
            1 => blk: {
                @memcpy(buf[0..4], "acme");
                break :blk .{ .tenant = buf[0..4] };
            },
            2 => .plaintext,
            else => .unknown,
        };
    }
};

fn testDir(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/rove-walseal-{x}", .{std.crypto.random.int(u64)});
}

test "a tenant's entries seal under its keyring and open again; a system group stays plaintext" {
    const a = testing.allocator;
    var dbuf: [64]u8 = undefined;
    const data_dir = try testDir(&dbuf);
    defer std.fs.cwd().deleteTree(data_dir) catch {};
    const kek = "a cluster key-encryption key";
    const kdir = try keyspace.keyringDir(a, data_dir);
    defer a.free(kdir);
    {
        var kr = try crypt.keyring.Keyring.create(a, kdir, "acme", kek, [_]u8{0x5A} ** 32);
        kr.deinit();
    }
    var dummy: u8 = 0;
    var ws = try WalSeal.init(a, data_dir, kek, .{ .ctx = &dummy, .resolve = TestOwners.resolve });
    defer ws.deinit();

    const sealed = (try ws.seal(a, 1, "the readset of a request")).?;
    defer a.free(sealed);
    try testing.expect(std.mem.indexOf(u8, sealed, "readset") == null);
    const opened = try ws.open(a, 1, sealed);
    defer a.free(opened);
    try testing.expectEqualStrings("the readset of a request", opened);

    try testing.expect((try ws.seal(a, 2, "a domain row")) == null);
    try testing.expectError(error.KeyUnavailable, ws.seal(a, 99, "anything"));
}

test "no keyring yet means KeyUnavailable, and a keyring that arrives later is found" {
    const a = testing.allocator;
    var dbuf: [64]u8 = undefined;
    const data_dir = try testDir(&dbuf);
    defer std.fs.cwd().deleteTree(data_dir) catch {};
    const kek = "a cluster key-encryption key";
    var dummy: u8 = 0;
    var ws = try WalSeal.init(a, data_dir, kek, .{ .ctx = &dummy, .resolve = TestOwners.resolve });
    defer ws.deinit();

    try testing.expectError(error.KeyUnavailable, ws.seal(a, 1, "x"));

    const kdir = try keyspace.keyringDir(a, data_dir);
    defer a.free(kdir);
    {
        var kr = try crypt.keyring.Keyring.create(a, kdir, "acme", kek, [_]u8{0x5A} ** 32);
        kr.deinit();
    }
    const sealed = (try ws.seal(a, 1, "x")).?;
    a.free(sealed);
}

test "destroying the tenant's keyring leaves its sealed entries unreadable" {
    // THE property: the WAL bytes are untouched and still on disk; a node
    // that no longer holds the tenant's secret cannot open them.
    const a = testing.allocator;
    var dbuf: [64]u8 = undefined;
    const data_dir = try testDir(&dbuf);
    defer std.fs.cwd().deleteTree(data_dir) catch {};
    const kek = "a cluster key-encryption key";
    const kdir = try keyspace.keyringDir(a, data_dir);
    defer a.free(kdir);
    var kr = try crypt.keyring.Keyring.create(a, kdir, "acme", kek, [_]u8{0x5A} ** 32);
    defer kr.deinit();

    var dummy: u8 = 0;
    var ws = try WalSeal.init(a, data_dir, kek, .{ .ctx = &dummy, .resolve = TestOwners.resolve });
    defer ws.deinit();
    const sealed = (try ws.seal(a, 1, "customer data")).?;
    defer a.free(sealed);

    try kr.destroyAll();
    ws.forget("acme");
    try testing.expectError(error.KeyUnavailable, ws.open(a, 1, sealed));
}
