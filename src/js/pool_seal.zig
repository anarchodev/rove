// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The worker's side of sealing a body on its way into the cross-tenant
//! body pool — resolving the tenant's key material and refusing to spill
//! without it.
//!
//! `keyring.body_seal` owns the mechanism (a data key per body, wrapped
//! under key material a destroy can reach). This file owns the part that
//! needs a worker: finding the tenant's keyring, and deciding what to do
//! when there isn't one.
//!
//! ## Why a missing keyring fails the spill
//!
//! The alternative is submitting plaintext, and that failure is silent,
//! permanent and invisible at exactly the moment it matters: the bytes go
//! to a content-addressed object shared with other tenants, get copied
//! into every backup taken afterwards, and no later destroy can reach
//! them. There is no repair — the object cannot be rewritten, and by the
//! time anyone notices, the plaintext is in backup generations nobody
//! will re-derive.
//!
//! So the same posture the rest of this epic takes: a node that cannot
//! vouch for a tenant's key material refuses to act rather than
//! downgrading quietly. It costs a large-body request on a node whose
//! keyring has not arrived; it does not cost an unrecoverable leak.

const std = @import("std");
const crypt = @import("rove-crypt");
const keyring_mod = @import("rove-keyring");
const tape_mod = @import("rove-tape");
const bodies_mod = @import("rove-bodies");

const body_seal = keyring_mod.body_seal;

pub const WRAPPED_LEN = body_seal.WRAPPED_LEN;

/// An all-zero wrap: no sealed body. Distinguishable from a real wrap
/// because a real one always leads with `crypt.ALG_AES_256_GCM`, which is
/// non-zero — so the absence is exact rather than probabilistic, the same
/// discipline `keyring/seal.zig`'s marker follows.
pub const NO_WRAP: [WRAPPED_LEN]u8 = [_]u8{0} ** WRAPPED_LEN;

pub fn isWrapped(wrap: *const [WRAPPED_LEN]u8) bool {
    return wrap[0] != 0;
}

pub const Error = error{
    /// This node holds no keyring for the tenant, so it cannot seal. The
    /// caller must fail the body rather than submit plaintext.
    NoKeyring,
} || body_seal.Error;

pub const Sealed = struct {
    /// Hand this to `Coordinator.submit` — the pool carries ciphertext.
    body: []u8,
    /// Record this beside the `BodyRef` on the tape entry.
    wrapped_key: [WRAPPED_LEN]u8,
};

/// This node's key state for `instance_id`, or null.
fn keysFor(worker: anytype, instance_id: []const u8) ?*keyring_mod.TenantKeys {
    const slot = worker.node.deploy.tenant_files_map.get(instance_id) orelse return null;
    return slot.keys;
}

/// This tenant's body-pool key, or null when this node holds no keyring.
///
/// Separate from `sealForPool` because a caller that holds bytes but not a
/// worker — the inbound-chunk job, which takes everything by injection —
/// resolves the key once at arm time and seals many payloads with it.
pub fn tenantKeyFor(worker: anytype, instance_id: []const u8) ?crypt.Key {
    const keys = keysFor(worker, instance_id) orelse return null;
    return body_seal.tenantKey(keys.tenantSecret());
}

/// Seal `plaintext` for the pool under an already-resolved tenant key.
pub fn sealWithKey(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    tenant_key: crypt.Key,
) Error!Sealed {
    const s = try body_seal.seal(
        allocator,
        plaintext,
        tenant_key,
        crypt.TENANT_REF,
        keyring_mod.seal.KEY_VERSION,
    );
    return .{ .body = s.body, .wrapped_key = s.wrapped_key };
}

/// Seal `plaintext` for the pool under the TENANT's key.
///
/// The tenant and not an identity, because no identity exists yet: a body
/// is submitted before any handler code runs. `TenantKeys.bindBodyWrap`
/// moves the wrap once the activation names one.
pub fn sealForPool(
    worker: anytype,
    allocator: std.mem.Allocator,
    instance_id: []const u8,
    plaintext: []const u8,
) Error!Sealed {
    const key = tenantKeyFor(worker, instance_id) orelse return Error.NoKeyring;
    return sealWithKey(allocator, plaintext, key);
}

// ── sealing an activation's recorded payloads ───────────────────────

/// Seal every payload this activation's readset records, under the identity
/// it named or, failing that, the tenant: bytes riding a tape inline are
/// sealed in place, and a pool body's wrap moves from the tenant onto the
/// identity. Run once per activation by `captureTapes`, after the last
/// payload is appended and before either copy of the readset is serialized
/// — the flushed record here, the raft entry after.
///
/// It FAILS CLOSED and never fails the activation. Capture runs after the
/// handler, where refusing would cost the customer a response over a
/// recording concern; recording plaintext instead is the one outcome this
/// module exists to prevent. So a payload that cannot be sealed as asked —
/// no keyring on this node, or an identity whose key is gone or cannot be
/// vouched for — is DROPPED to the unretained shape: its recorded length and
/// no bytes, which every reader already reports as a payload that was not
/// kept.
///
/// Idempotent: an entry that already carries a wrap beside inline bytes is
/// sealed and is left alone.
pub fn sealReadsetPayloads(worker: anytype, readset: *tape_mod.Readset, instance_id: []const u8) void {
    // Test harnesses capture with a bare `.{ .allocator }` stand-in and no
    // node, so there is no keyring to reach.
    const W = @TypeOf(worker);
    const T = if (@typeInfo(W) == .pointer) @typeInfo(W).pointer.child else W;
    if (comptime !@hasField(T, "node")) return;
    sealWithKeys(worker.allocator, keysFor(worker, instance_id), readset);
}

/// The key a payload seals under, and the ref its wrap names.
const Target = struct { key: crypt.Key, ref: crypt.KeyRef, slot: ?u64 };

/// `sealReadsetPayloads` with the key state resolved — the testable half.
pub fn sealWithKeys(
    allocator: std.mem.Allocator,
    keys_opt: ?*keyring_mod.TenantKeys,
    readset: *tape_mod.Readset,
) void {
    const target: ?Target = blk: {
        const keys = keys_opt orelse break :blk null;
        if (readset.shred_slot) |slot| break :blk switch (keys.lookup(slot)) {
            .key => |k| .{ .key = k, .ref = crypt.refForSlot(slot), .slot = slot },
            .shredded, .unverified => null,
        };
        break :blk .{ .key = body_seal.tenantKey(keys.tenantSecret()), .ref = crypt.TENANT_REF, .slot = null };
    };
    var dropped: usize = 0;
    for ([_]*tape_mod.Tape{ &readset.trigger_payload, &readset.fetch_responses, &readset.activation }) |tape| {
        for (tape.entries.items, 0..) |*e, i| {
            if (!sealEntry(allocator, keys_opt, target, readset.shred_slot != null, tape, e, i)) dropped += 1;
        }
    }
    if (dropped > 0) std.log.warn(
        "rove-js payload seal: {d} recorded payload(s) DROPPED — {s}; the record keeps their lengths and no bytes",
        .{ dropped, if (keys_opt == null) "this node holds no keyring for the tenant" else "the named identity's key is destroyed or unverified here" },
    );
}

/// Seal one entry. False when its payload had to be dropped.
fn sealEntry(
    allocator: std.mem.Allocator,
    keys_opt: ?*keyring_mod.TenantKeys,
    target: ?Target,
    identity_named: bool,
    tape: *tape_mod.Tape,
    e: *tape_mod.Entry,
    i: usize,
) bool {
    const slots: struct { ref: *bodies_mod.BodyRef, bytes: *[]const u8, key: *[]const u8 } = switch (e.*) {
        .trigger_payload => |*t| .{ .ref = &t.body_ref, .bytes = &t.inline_bytes, .key = &t.body_key },
        .fetch_responses => |*f| .{ .ref = &f.body_ref, .bytes = &f.inline_bytes, .key = &f.body_key },
        .activation => |*a| .{ .ref = &a.body_ref, .bytes = &a.inline_bytes, .key = &a.body_key },
        else => return true,
    };
    if (slots.bytes.len > 0) {
        if (slots.key.len > 0) return true; // already sealed
        const t = target orelse {
            dropInline(tape, i);
            return false;
        };
        var s = body_seal.seal(allocator, slots.bytes.*, t.key, t.ref, keyring_mod.seal.KEY_VERSION) catch {
            dropInline(tape, i);
            return false;
        };
        defer s.deinit(allocator);
        tape.sealInlinePayload(i, s.body, &s.wrapped_key) catch {
            dropInline(tape, i);
            return false;
        };
        return true;
    }
    // A pool body: sealed at submit under the tenant, and moved only when
    // an identity was named. With none named, its tenant wrap is the right
    // one whatever this node holds now.
    if (slots.key.len == 0 or !identity_named) return true;
    const moved = blk: {
        const t = target orelse break :blk false;
        const keys = keys_opt orelse break :blk false;
        keys.bindBodyWrap(@constCast(slots.key.*), t.slot.?) catch break :blk false;
        break :blk true;
    };
    if (moved) return true;
    // The body cannot answer to the identity it was promised to, and a
    // tenant wrap left in place would outlive that identity's destroy. Drop
    // the POINTER: the bytes stay sealed in the pool, reachable by nothing.
    slots.ref.* = bodies_mod.BodyRef.carried(slots.ref.len);
    tape.dropInlinePayload(i);
    return false;
}

/// The unretained shape: the entry's recorded length, no bytes.
fn dropInline(tape: *tape_mod.Tape, i: usize) void {
    tape.dropInlinePayload(i);
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "the absence of a wrap is exact, not a guess" {
    // A real wrap always leads with the algorithm id, so a zeroed field
    // can never be mistaken for one. The inverse — sniffing the BODY for
    // sealedness — is what `keyring/seal.zig` rejects as probabilistic,
    // and a body is arbitrary bytes so it has no unusable leading byte
    // to spend.
    try testing.expect(!isWrapped(&NO_WRAP));
    var w = NO_WRAP;
    w[0] = crypt.ALG_AES_256_GCM;
    try testing.expect(isWrapped(&w));
}

const kv_mod = @import("raft-kv");

/// A real keyring with slots 7 (destroyed) and 8 (live), on disk under a
/// random name — the key states the seal has to tell apart.
const TestKeys = struct {
    db_path: [96]u8 = undefined,
    db_len: usize = 0,
    dir_buf: [96]u8 = undefined,
    dir_len: usize = 0,
    store: *kv_mod.KvStore = undefined,
    keys: *keyring_mod.TenantKeys = undefined,

    const DEAD: u64 = 7;
    const LIVE: u64 = 8;

    fn init(self: *TestKeys, a: std.mem.Allocator) !void {
        const seed = std.crypto.random.int(u64);
        const db = try std.fmt.bufPrintZ(&self.db_path, "/tmp/rove-ps-{x}.kv", .{seed});
        self.db_len = db.len;
        const dir = try std.fmt.bufPrint(&self.dir_buf, "/tmp/rove-ps-kr-{x}", .{seed});
        self.dir_len = dir.len;
        const kek = "a cluster key-encryption key";
        {
            var kr = try crypt.keyring.Keyring.create(a, dir, "acme", kek, [_]u8{0x5A} ** 32);
            defer kr.deinit();
            try kr.mintRange(DEAD, 2, 1);
        }
        self.store = try kv_mod.KvStore.open(a, db);
        const dead = try keyring_mod.keyspace.deadKey(a, DEAD);
        defer a.free(dead);
        try self.store.put(dead, &keyring_mod.keyspace.encodeDead(1));
        self.keys = (try keyring_mod.TenantKeys.open(a, dir, "acme", kek, self.store)).?;
    }

    fn deinit(self: *TestKeys) void {
        self.keys.deinit();
        self.store.close();
        const db = self.db_path[0..self.db_len];
        std.fs.cwd().deleteFile(db) catch {};
        var lock_buf: [128]u8 = undefined;
        const lock = std.fmt.bufPrint(&lock_buf, "{s}-lock", .{db}) catch return;
        std.fs.cwd().deleteFile(lock) catch {};
        std.fs.cwd().deleteTree(self.dir_buf[0..self.dir_len]) catch {};
    }
};

test "capture seals every inline payload under the tenant when no identity is named" {
    const a = testing.allocator;
    var tk: TestKeys = .{};
    try tk.init(a);
    defer tk.deinit();

    var rs = tape_mod.Readset.init(a, 0, 0);
    defer rs.deinit();
    try rs.trigger_payload.appendTriggerPayload(bodies_mod.BodyRef.carried(5), "hello", "");
    try rs.activation.appendActivation("onMessage", bodies_mod.BodyRef.carried(3), "\x01hi");

    sealWithKeys(a, tk.keys, &rs);

    const t = rs.trigger_payload.entries.items[0].trigger_payload;
    try testing.expect(!std.mem.eql(u8, t.inline_bytes, "hello"));
    try testing.expect(try body_seal.isTenantWrapped(t.body_key));
    const opened = try tk.keys.openBody(a, t.inline_bytes, t.body_key);
    defer a.free(opened.opened);
    try testing.expectEqualStrings("hello", opened.opened);

    const act = rs.activation.entries.items[0].activation;
    try testing.expect(act.body_key.len == WRAPPED_LEN);

    // Idempotent: a second pass leaves the sealed entries exactly as they are.
    const before = try a.dupe(u8, t.inline_bytes);
    defer a.free(before);
    sealWithKeys(a, tk.keys, &rs);
    try testing.expectEqualSlices(u8, before, rs.trigger_payload.entries.items[0].trigger_payload.inline_bytes);
}

test "capture seals under the named identity, and moves a pool wrap onto it" {
    const a = testing.allocator;
    var tk: TestKeys = .{};
    try tk.init(a);
    defer tk.deinit();

    var rs = tape_mod.Readset.init(a, 0, 0);
    defer rs.deinit();
    rs.shred_slot = TestKeys.LIVE;
    try rs.trigger_payload.appendTriggerPayload(bodies_mod.BodyRef.carried(5), "hello", "");
    // A pool body sealed at submit, under the tenant.
    var pooled = try body_seal.seal(a, "big", body_seal.tenantKey(tk.keys.tenantSecret()), crypt.TENANT_REF, 1);
    defer pooled.deinit(a);
    const ref: bodies_mod.BodyRef = .{
        .written_unix_ms = 1_700_000_000_000,
        .digest = [_]u8{1} ** bodies_mod.pool_object.DIGEST_LEN,
        .offset = 0,
        .len = @intCast(pooled.body.len),
    };
    try rs.fetch_responses.appendFetchResponse("f1", 0, 0, ref, true, 200, true, false, "", "", "", &pooled.wrapped_key);

    sealWithKeys(a, tk.keys, &rs);

    const t = rs.trigger_payload.entries.items[0].trigger_payload;
    try testing.expectEqual(TestKeys.LIVE, crypt.slotForRef(try body_seal.wrapRef(t.body_key)));
    const f = rs.fetch_responses.entries.items[0].fetch_responses;
    try testing.expectEqual(TestKeys.LIVE, crypt.slotForRef(try body_seal.wrapRef(f.body_key)));
    // The pool bytes never changed, and now only the identity opens them.
    const opened = try tk.keys.openBody(a, pooled.body, f.body_key);
    defer a.free(opened.opened);
    try testing.expectEqualStrings("big", opened.opened);
}

test "a payload that cannot be sealed as asked is dropped, never recorded in plaintext" {
    const a = testing.allocator;
    var tk: TestKeys = .{};
    try tk.init(a);
    defer tk.deinit();

    // The identity the handler named is destroyed.
    var rs = tape_mod.Readset.init(a, 0, 0);
    defer rs.deinit();
    rs.shred_slot = TestKeys.DEAD;
    try rs.trigger_payload.appendTriggerPayload(bodies_mod.BodyRef.carried(6), "secret", "");
    var pooled = try body_seal.seal(a, "big", body_seal.tenantKey(tk.keys.tenantSecret()), crypt.TENANT_REF, 1);
    defer pooled.deinit(a);
    const ref: bodies_mod.BodyRef = .{
        .written_unix_ms = 1_700_000_000_000,
        .digest = [_]u8{1} ** bodies_mod.pool_object.DIGEST_LEN,
        .offset = 0,
        .len = @intCast(pooled.body.len),
    };
    try rs.fetch_responses.appendFetchResponse("f1", 0, 0, ref, true, 200, true, false, "", "", "", &pooled.wrapped_key);

    sealWithKeys(a, tk.keys, &rs);

    const t = rs.trigger_payload.entries.items[0].trigger_payload;
    try testing.expectEqual(@as(usize, 0), t.inline_bytes.len);
    try testing.expectEqual(@as(u32, 6), t.body_ref.len);
    // The pool body keeps its length and loses its pointer: a tenant wrap
    // left in place would outlive the identity's destroy.
    const f = rs.fetch_responses.entries.items[0].fetch_responses;
    try testing.expect(f.body_ref.isNone());
    try testing.expectEqual(@as(usize, 0), f.body_key.len);

    // No keyring at all: same fate for the inline payload.
    var rs2 = tape_mod.Readset.init(a, 0, 0);
    defer rs2.deinit();
    try rs2.trigger_payload.appendTriggerPayload(bodies_mod.BodyRef.carried(6), "secret", "");
    sealWithKeys(a, null, &rs2);
    try testing.expectEqual(@as(usize, 0), rs2.trigger_payload.entries.items[0].trigger_payload.inline_bytes.len);
}
