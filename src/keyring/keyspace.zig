// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The identity→slot binding, and the destroy command — the two things
//! that travel through the tenant's raft log so that key material never
//! has to.
//!
//! The keyring is indexed by slot, because keys are minted into a pool
//! before any identity exists. Something has to say which slot a given
//! customer identity seals under, and that something must be replicated,
//! durable and ordered. It is an ordinary envelope-0 kv write in the
//! tenant's own store, riding the raft entry the request was already
//! sending — no extra round trip and no extra fsync on the hot path.
//!
//! ## The identity never appears in a key name
//!
//! The binding is keyed by `crypt.identityRef` — an HMAC of the identity
//! under a subkey of the tenant secret — not by the identity itself. KV
//! key names are deliberately left plaintext elsewhere because range
//! scans need them, which is why the surrogate-identifier convention
//! exists; here it costs nothing to close the gap outright, since a
//! binding is only ever looked up by exact identity and never scanned.
//!
//! The same ref names the identity in the log index, so "every record
//! for identity X" and "shred identity X" are the same name rather than
//! two spellings that have to be kept in step.
//!
//! ## Why the value carries the full HMAC
//!
//! A ref is 8 bytes. Two identities colliding would share one slot, so
//! shredding either would shred both — and a slot is embedded in every
//! ciphertext ever sealed under it, so that is unfixable after the fact
//! and unrewritable in backups.
//!
//! The value therefore carries the FULL mac beside the slot, and a
//! resolve compares it. A collision then fails loudly at bind time
//! instead of silently handing two identities one key. This is the same
//! posture as the slot counter's nonce: a value that merely looks right
//! is not proof the range is ours.
//!
//! ## A destroy is a tombstone PUT, not a delete
//!
//! The natural spelling — delete the binding — cannot work. The apply
//! observer is handed an empty value for `.delete`, so a node applying
//! one cannot learn WHICH slot to destroy, and reconstructing that from
//! earlier puts would need a projection that a restarted node does not
//! have.
//!
//! So a destroy is one writeset containing both halves: the binding row
//! is deleted AND `_keys/dead/{slot}` is written. They commit atomically,
//! and the tombstone is what carries the slot number to every node —
//! including nodes that were DOWN when it happened, which is the
//! guarantee erasure most needs and the one a best-effort push cannot
//! make.
//!
//! It also keeps the live envelope types at three. A destroy is data in
//! a reserved key, observed at apply, exactly like the `_deploy/current`
//! release pointer.
//!
//! ## Absence means shredded only where completeness is CHECKED
//!
//! The scheme's cheapest property is that a missing key means *erased*,
//! never *not loaded* — that is what removes the entire cache
//! invalidation class. It holds only while a node's keyring really does
//! hold every key it should, and nothing about raft delivers that: raft
//! elects on LOG up-to-dateness, and key material deliberately travels
//! outside the log, so a node can carry every committed entry and still
//! be missing shards. Left unchecked, a routine leader change onto such
//! a node reports live customer data as erased.
//!
//! So completeness is derived rather than assumed, from state raft has
//! already replicated:
//!
//!   live keys + destroyed slots  must cover  [FIRST_SLOT, minted)
//!
//! `_keys/minted` is the watermark, and it is deliberately NOT the
//! reservation counter. A leader that dies between reserving a block and
//! minting it leaves `_keys/next_slot` ahead of anything that ever
//! existed, and a node measuring against that would declare itself
//! permanently incomplete through no fault of its own — one crash would
//! take the tenant down. The watermark therefore advances only after a
//! block is minted AND quorum-durable, which is exactly the point the
//! pool already reaches before it publishes a block.
//!
//! The two sets are disjoint (a destroy removes the key and writes the
//! tombstone in one apply) and both sit inside the range, so covering it
//! is a counting question and needs no per-slot walk. Holding MORE than
//! the range requires is complete too: a node can have applied a shard
//! push before the watermark write reaches it.
//!
//! A node that comes up short does not get to answer. It reports
//! `unverified`, which is not-found's opposite — the whole point is that
//! it must never be mistaken for erasure.
//!
//! ## Both halves of a node, not just the follower half
//!
//! The apply observer does NOT fire on the node that proposed the entry
//! — the leader-skip returns before `notifyApply`, because that node's
//! worker already wrote its own overlay. An effect wired only to the
//! observer therefore runs on followers and not on the leader, which for
//! a destroy means the one node still serving the tenant keeps the key.
//!
//! Every replicated effect here is consequently a pair: the follower
//! half in the apply observer, and the proposing-node half inline after
//! commit. `_deploy/current` and the durable-wake watermark are both
//! built that way, and this is not an exception.

const std = @import("std");
const crypt = @import("rove-crypt");

/// Identity→slot bindings. Platform-reserved: the leading `_` keyspace
/// is closed to customer writes, so a handler cannot rebind itself onto
/// another identity's key.
pub const BIND_PREFIX = "_keys/bind/";

/// Destroy tombstones, keyed by slot. The command that carries an
/// erasure to every node through the log.
pub const DEAD_PREFIX = "_keys/dead/";

/// Slots minted AND made quorum-durable, as an exclusive end — the
/// denominator of the completeness check.
///
/// Distinct from `_keys/next_slot`, which counts slots RESERVED. See the
/// watermark note in the file header: measuring against reservations
/// would let one badly-timed leader crash mark every node incomplete
/// forever.
pub const MINTED_KEY = "_keys/minted";

/// Keyring root under the node's data dir — one directory per tenant
/// beneath it. Lives here, with the other keyring facts, so a consumer
/// that only needs the path does not pull in the HTTP transport.
pub fn keyringDir(allocator: std.mem.Allocator, data_dir: []const u8) Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/keyrings", .{data_dir}) catch Error.OutOfMemory;
}

/// Label for the subkey that pseudonymises identities. Distinct from
/// every sealing key: this one names data, it never opens it.
const PSEUDONYM_LABEL = "rewind-identity-ref/v1";

/// `[8B slot LE][32B full mac]`
const BIND_VALUE_LEN: usize = 8 + std.crypto.auth.hmac.sha2.HmacSha256.mac_length;

/// `[8B destroyed_unix_ns LE]`. Stamped by the proposer and replicated,
/// never recomputed per node — a value derived at apply time would
/// differ between nodes applying the same entry.
const DEAD_VALUE_LEN: usize = 8;

const HEX_REF_LEN: usize = crypt.KEY_REF_LEN * 2;

/// What this node can say about a slot it does not hold.
pub const Completeness = enum {
    /// Every key this tenant should have is here, so a miss is an
    /// erasure and may be reported as one.
    complete,
    /// This node is missing key material. A miss here says nothing about
    /// whether the data was erased, and must never be reported as if it
    /// did.
    incomplete,
};

/// The answer to "open the ciphertext at this slot".
pub const Lookup = union(enum) {
    key: crypt.Key,
    /// Destroyed. Callers surface not-found — "erased" should read like
    /// "absent" to everything downstream.
    shredded,
    /// This node cannot tell, and says so instead of guessing. Reporting
    /// erasure from here would be a lie about the one thing customers
    /// are promised.
    unverified,
};

/// What a stored value turned out to be.
///
/// Lives beside the keyspace rather than in the engine's globals: it is
/// the vocabulary of "can this node read that", and every reader needs
/// the same four answers.
pub const Opened = union(enum) {
    /// Not sealed. The bytes are the value.
    plaintext,
    /// Sealed and opened; caller frees.
    opened: []u8,
    /// Sealed, and its key is gone. A live read answers ABSENT —
    /// "erased" reads like "absent" to everything downstream.
    shredded,
    /// Sealed, and this node cannot say whether the key is gone or
    /// merely missing here. Never absent: a node short of key material
    /// must not report an erasure it cannot stand behind.
    unverified,
};

pub const Error = error{
    /// Stored bytes this codec did not write.
    Corrupt,
    /// The ref matched but the full mac did not: two identities hashed
    /// to one ref. Never resolved to a slot — that would hand them one
    /// key, and shredding either would shred both.
    RefCollision,
    OutOfMemory,
};

pub const Binding = struct {
    slot: u64,
    mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8,
};

/// The tenant's pseudonym key, derived from its root secret. Every node
/// holding the tenant derives the same one, so a ref is stable across
/// the cluster and across restarts.
pub fn pseudonymKey(secret: *const crypt.keyring.Secret) crypt.Key {
    return crypt.deriveSubkey(secret, PSEUDONYM_LABEL);
}

/// Full HMAC of an identity — the collision guard stored beside the slot.
fn fullMac(pk: crypt.Key, identity: []const u8) [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, identity, &pk);
    return mac;
}

fn writeHex(out: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xF];
    }
}

/// `_keys/bind/{16 hex}` for an identity. Caller frees.
pub fn bindKey(allocator: std.mem.Allocator, pk: crypt.Key, identity: []const u8) Error![]u8 {
    const ref = crypt.identityRef(pk, identity);
    const out = allocator.alloc(u8, BIND_PREFIX.len + HEX_REF_LEN) catch
        return Error.OutOfMemory;
    @memcpy(out[0..BIND_PREFIX.len], BIND_PREFIX);
    writeHex(out[BIND_PREFIX.len..], &ref);
    return out;
}

/// `_keys/dead/{16 hex}` for a slot. Caller frees.
///
/// Keyed by the slot rather than by the identity: the slot is what the
/// keyring is indexed by, and it is what a node needs in order to act.
/// The identity's own row is deleted in the same writeset, so nothing
/// here has to carry it.
pub fn deadKey(allocator: std.mem.Allocator, slot: u64) Error![]u8 {
    var ref_bytes: [crypt.KEY_REF_LEN]u8 = undefined;
    std.mem.writeInt(u64, &ref_bytes, slot, .big);
    const out = allocator.alloc(u8, DEAD_PREFIX.len + HEX_REF_LEN) catch
        return Error.OutOfMemory;
    @memcpy(out[0..DEAD_PREFIX.len], DEAD_PREFIX);
    writeHex(out[DEAD_PREFIX.len..], &ref_bytes);
    return out;
}

/// The slot a `_keys/dead/…` key names, or null when `key` is not one.
/// This is the apply-side entry point: an observer sees a put, asks
/// this, and acts only on a yes.
pub fn parseDeadSlot(key: []const u8) ?u64 {
    if (key.len != DEAD_PREFIX.len + HEX_REF_LEN) return null;
    if (!std.mem.startsWith(u8, key, DEAD_PREFIX)) return null;
    const slot = std.fmt.parseInt(u64, key[DEAD_PREFIX.len..], 16) catch return null;
    return slot;
}

pub fn encodeBinding(slot: u64, mac: [32]u8) [BIND_VALUE_LEN]u8 {
    var out: [BIND_VALUE_LEN]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], slot, .little);
    @memcpy(out[8..], &mac);
    return out;
}

pub fn decodeBinding(bytes: []const u8) Error!Binding {
    if (bytes.len != BIND_VALUE_LEN) return Error.Corrupt;
    var b: Binding = .{ .slot = std.mem.readInt(u64, bytes[0..8], .little), .mac = undefined };
    @memcpy(&b.mac, bytes[8..]);
    return b;
}

/// Resolve a stored binding to its slot, refusing a ref collision.
///
/// The mac comparison is the whole point of the call: without it a
/// second identity that happened to hash to the same ref would silently
/// adopt the first one's key.
pub fn resolveBinding(stored: []const u8, pk: crypt.Key, identity: []const u8) Error!u64 {
    const b = try decodeBinding(stored);
    const want = fullMac(pk, identity);
    // Constant-time: the stored mac is derived from a secret, and a
    // timing oracle here would leak it a byte at a time.
    if (!std.crypto.timing_safe.eql([32]u8, b.mac, want)) return Error.RefCollision;
    return b.slot;
}

/// Value for a fresh binding of `identity` to `slot`.
pub fn bindingFor(pk: crypt.Key, identity: []const u8, slot: u64) [BIND_VALUE_LEN]u8 {
    return encodeBinding(slot, fullMac(pk, identity));
}

pub fn encodeMinted(end: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, end, .little);
    return out;
}

pub fn decodeMinted(bytes: []const u8) Error!u64 {
    if (bytes.len != 8) return Error.Corrupt;
    return std.mem.readInt(u64, bytes[0..8], .little);
}

/// Does this node hold everything the tenant has minted?
///
/// `live` is the keyring's key count, `destroyed` the tombstone count,
/// `minted` the watermark. Holding more than the range requires is
/// complete: a shard push can land before the watermark write that
/// announces it.
pub fn completeness(live: u64, destroyed: u64, minted: u64) Completeness {
    const required = if (minted <= crypt.FIRST_SLOT) 0 else minted - crypt.FIRST_SLOT;
    const held = live +| destroyed;
    return if (held >= required) .complete else .incomplete;
}

/// Resolve a slot against this node's keyring, refusing to call a miss
/// an erasure unless the keyring is known complete.
pub fn lookup(kr: *const crypt.keyring.Keyring, slot: u64, c: Completeness) Lookup {
    if (kr.keyAt(slot)) |k| return .{ .key = k };
    return switch (c) {
        .complete => .shredded,
        .incomplete => .unverified,
    };
}

pub fn encodeDead(destroyed_unix_ns: i64) [DEAD_VALUE_LEN]u8 {
    var out: [DEAD_VALUE_LEN]u8 = undefined;
    std.mem.writeInt(i64, out[0..8], destroyed_unix_ns, .little);
    return out;
}

pub fn decodeDead(bytes: []const u8) Error!i64 {
    if (bytes.len != DEAD_VALUE_LEN) return Error.Corrupt;
    return std.mem.readInt(i64, bytes[0..8], .little);
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_SECRET: crypt.keyring.Secret = [_]u8{0x11} ** crypt.keyring.SECRET_LEN;

test "both keyspaces are closed to customer writes" {
    // A handler that could write either could rebind itself onto another
    // identity's key, or forge an erasure it never performed.
    try testing.expect(std.mem.startsWith(u8, BIND_PREFIX, "_"));
    try testing.expect(std.mem.startsWith(u8, DEAD_PREFIX, "_"));
}

test "the plaintext identity never appears in the key" {
    const pk = pseudonymKey(&TEST_SECRET);
    const key = try bindKey(testing.allocator, pk, "user@example.com");
    defer testing.allocator.free(key);
    try testing.expect(std.mem.indexOf(u8, key, "user@example.com") == null);
    try testing.expect(std.mem.indexOf(u8, key, "example") == null);
    try testing.expect(std.mem.startsWith(u8, key, BIND_PREFIX));
}

test "a binding key is stable for one identity and distinct across them" {
    const pk = pseudonymKey(&TEST_SECRET);
    const a1 = try bindKey(testing.allocator, pk, "u_7f3a9c");
    defer testing.allocator.free(a1);
    const a2 = try bindKey(testing.allocator, pk, "u_7f3a9c");
    defer testing.allocator.free(a2);
    const b = try bindKey(testing.allocator, pk, "u_0e11bd");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a1, a2);
    try testing.expect(!std.mem.eql(u8, a1, b));
}

test "a different tenant secret yields a different key for one identity" {
    // Otherwise a ref would be portable between tenants, and a binding
    // row copied across would resolve to the wrong tenant's slot.
    const other: crypt.keyring.Secret = [_]u8{0x22} ** crypt.keyring.SECRET_LEN;
    const a = try bindKey(testing.allocator, pseudonymKey(&TEST_SECRET), "u_1");
    defer testing.allocator.free(a);
    const b = try bindKey(testing.allocator, pseudonymKey(&other), "u_1");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "a binding round-trips to its slot" {
    const pk = pseudonymKey(&TEST_SECRET);
    const v = bindingFor(pk, "u_7f3a9c", 4097);
    try testing.expectEqual(@as(u64, 4097), try resolveBinding(&v, pk, "u_7f3a9c"));
}

test "a ref collision fails loudly instead of sharing a key" {
    // Simulated by resolving a stored binding with the wrong identity:
    // exactly the bytes a colliding second identity would find waiting.
    // Sharing a slot would mean shredding either identity shreds both,
    // and the slot is already in every ciphertext sealed under it.
    const pk = pseudonymKey(&TEST_SECRET);
    const v = bindingFor(pk, "u_first", 12);
    try testing.expectError(Error.RefCollision, resolveBinding(&v, pk, "u_second"));
}

test "a short or oversized binding value is refused, never guessed at" {
    try testing.expectError(Error.Corrupt, decodeBinding(""));
    try testing.expectError(Error.Corrupt, decodeBinding(&[_]u8{0} ** (BIND_VALUE_LEN - 1)));
    try testing.expectError(Error.Corrupt, decodeBinding(&[_]u8{0} ** (BIND_VALUE_LEN + 1)));
}

test "a dead key round-trips its slot" {
    const k = try deadKey(testing.allocator, 8191);
    defer testing.allocator.free(k);
    try testing.expectEqual(@as(?u64, 8191), parseDeadSlot(k));
}

test "parseDeadSlot ignores every key that is not a tombstone" {
    // The apply observer acts on a yes here, so a false positive would
    // destroy a key on the strength of an unrelated write.
    const pk = pseudonymKey(&TEST_SECRET);
    const bind = try bindKey(testing.allocator, pk, "u_1");
    defer testing.allocator.free(bind);
    try testing.expectEqual(@as(?u64, null), parseDeadSlot(bind));
    try testing.expectEqual(@as(?u64, null), parseDeadSlot("_deploy/current"));
    try testing.expectEqual(@as(?u64, null), parseDeadSlot("_keys/next_slot"));
    try testing.expectEqual(@as(?u64, null), parseDeadSlot(DEAD_PREFIX));
    try testing.expectEqual(@as(?u64, null), parseDeadSlot(DEAD_PREFIX ++ "zzzzzzzzzzzzzzzz"));
    try testing.expectEqual(@as(?u64, null), parseDeadSlot(DEAD_PREFIX ++ "00ff"));
}

test "slot 0 is never bindable — it is the tenant's own key" {
    // `deadKey` will encode it, but nothing may allocate it: a C2 destroy
    // of slot 0 would be a C1 shred wearing the wrong name.
    try testing.expect(crypt.FIRST_SLOT > 0);
    try testing.expectEqualSlices(u8, &crypt.TENANT_REF, &[_]u8{0} ** crypt.KEY_REF_LEN);
}

test "completeness: a node holding the whole range may report erasure" {
    // 4096 minted from slot 1 ⇒ 4095 slots to account for.
    try testing.expectEqual(Completeness.complete, completeness(4095, 0, 4096));
    try testing.expectEqual(Completeness.complete, completeness(4090, 5, 4096));
    try testing.expectEqual(Completeness.complete, completeness(0, 4095, 4096));
}

test "completeness: a node short of the range may NOT report erasure" {
    // The failover case. One missing shard is the difference between
    // "this was erased" and "I never received it", and only this check
    // can tell them apart.
    try testing.expectEqual(Completeness.incomplete, completeness(4094, 0, 4096));
    try testing.expectEqual(Completeness.incomplete, completeness(0, 0, 4096));
    try testing.expectEqual(Completeness.incomplete, completeness(2048, 1, 4096));
}

test "completeness: a fresh tenant is complete, not incomplete" {
    // Nothing minted ⇒ nothing to be missing. Reporting incomplete here
    // would make every new tenant unserveable.
    try testing.expectEqual(Completeness.complete, completeness(0, 0, 0));
    try testing.expectEqual(Completeness.complete, completeness(0, 0, crypt.FIRST_SLOT));
}

test "completeness: holding more than the watermark requires is complete" {
    // A shard push can land before the watermark write that announces
    // it. Calling that node incomplete would take a HEALTHY node out of
    // service on ordinary message ordering.
    try testing.expectEqual(Completeness.complete, completeness(8191, 0, 4096));
}

test "completeness measures MINTED, never RESERVED" {
    // A leader that dies between reserving a block and minting it leaves
    // the reservation counter ahead of anything that ever existed. If
    // the check measured that, one crash would mark every node in the
    // cluster incomplete forever — the tenant goes down and no repair
    // helps, because the missing keys were never minted.
    const reserved: u64 = 8192; // `_keys/next_slot` after the dead leader
    const minted: u64 = 4096; // what actually reached a quorum
    const live: u64 = 4095;
    try testing.expectEqual(Completeness.complete, completeness(live, 0, minted));
    try testing.expectEqual(Completeness.incomplete, completeness(live, 0, reserved));
}

test "an incomplete node answers unverified, never shredded" {
    // The failure this whole check exists to prevent: a node that is
    // merely missing key material telling a customer their data was
    // erased.
    var buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "/tmp/rove-kb-test-{x}", .{std.crypto.random.int(u64)}) catch unreachable;
    std.fs.cwd().makePath(dir) catch unreachable;
    defer std.fs.cwd().deleteTree(dir) catch {};

    var kr = try crypt.keyring.Keyring.create(testing.allocator, dir, "acme", "test-kek", TEST_SECRET);
    defer kr.deinit();
    try kr.mintRange(1, 4, 1);

    // A slot this node holds resolves the same either way.
    try testing.expect(lookup(&kr, 2, .complete) == .key);
    try testing.expect(lookup(&kr, 2, .incomplete) == .key);

    // A slot it does not hold is an erasure ONLY when it can stand
    // behind the claim.
    try testing.expect(lookup(&kr, 9, .complete) == .shredded);
    try testing.expect(lookup(&kr, 9, .incomplete) == .unverified);
}

test "a minted watermark round-trips" {
    try testing.expectEqual(@as(u64, 12288), try decodeMinted(&encodeMinted(12288)));
    try testing.expectError(Error.Corrupt, decodeMinted(""));
    try testing.expectError(Error.Corrupt, decodeMinted(&[_]u8{0} ** 7));
}

test "the watermark key is closed to customer writes" {
    // A handler that could write it could declare itself complete and
    // turn every missing key into a reported erasure.
    try testing.expect(std.mem.startsWith(u8, MINTED_KEY, "_"));
}

test "a dead marker round-trips its timestamp" {
    try testing.expectEqual(@as(i64, 1787000000000000000), try decodeDead(&encodeDead(1787000000000000000)));
    try testing.expectError(Error.Corrupt, decodeDead(""));
}
