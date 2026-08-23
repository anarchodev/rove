// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Per-tenant slot reservation — the consensus half of the key pool's
//! `reserve` callback.
//!
//! The pool hands out slot numbers, and a slot names a key. Two leaders
//! handing out the same slot would give two identities one key, so
//! shredding either would shred both — and slots are embedded in the
//! `key_ref` of every ciphertext ever sealed under them, so that is
//! unfixable after the fact. Backups cannot be rewritten.
//!
//! So the counter goes through consensus. Not per slot — that would put
//! a raft round trip on every new identity — but per **block**: reserve
//! a range once, hand slots out of it locally, and reserve the next
//! block in the background before the current one runs out. The
//! double-buffered refill lives in `rove-reserve`, shared with the blob
//! coordinator's `batch_id`; this file is only the provider that backs
//! it with a real proposal.
//!
//! ## The counter
//!
//! `_keys/next_slot` in the tenant's own store — a platform-reserved
//! key, replicated as an ordinary envelope-0 writeset. Per tenant
//! rather than cluster-wide because slot spaces are per tenant: two
//! tenants using slot 7 name two unrelated keys.
//!
//! ## Why the reservation carries a nonce
//!
//! The obvious shape — read the counter, add `count`, propose the sum —
//! is a read-modify-write, and two proposers that read the same value
//! compute the *same* sum. Both writes commit, last-writer-wins leaves
//! the expected number in place, and a read-back check passes for both.
//! Two callers then believe they own the same range, which is the one
//! outcome that cannot be repaired.
//!
//! So the stored value is `[8B end][8B nonce]` with a fresh random
//! nonce per attempt. After commit the value is read back, and a nonce
//! that is not ours means someone else's write landed on top: the
//! reservation is abandoned and retried against the value that won.
//! Identical `end` values no longer look like success.
//!
//! Within one process `rove-reserve` also floors each request at the
//! highest block it has ever issued, so back-to-back refills cannot
//! overlap even while a propose is still in flight.
//!
//! ## Why these writes go through a txn AND a propose
//!
//! A worker runs the pump in `worker_overlay` mode, where the skip
//! decision is keyed on PROVENANCE: an entry this bridge proposed and is
//! still awaiting is skipped, because a worker `TrackedTxn` is presumed
//! to be doing the store write. Proposing without one therefore lands
//! the value on every FOLLOWER and on no leader — the node that most
//! needs it. `bridge.zig`'s worker-overlay test pins exactly that
//! behaviour.
//!
//! So each write here does what every other standalone platform write
//! does (`blob_usage.zig` is the model): write it through a txn locally,
//! then propose the same op to replicate it. The txn is the leader's
//! copy; the propose is everyone else's.
//!
//! That also keeps the read-back honest, which is easy to talk yourself
//! out of. Writing locally does not make the check see only its own
//! value: a competing proposer's entry arrives with a FOREIGN origin, so
//! the pump writes it here too. The read-back therefore still
//! discriminates exactly when it must — both racers see a nonce that is
//! not theirs and both back off, which is conservative rather than
//! lossy.

const std = @import("std");
const crypt = @import("rove-crypt");
const keyring_mod = @import("rove-keyring");
const kv_mod = @import("raft-kv");
const raft_propose = @import("raft_propose.zig");

/// Platform-reserved counter key. Leading `_` is closed to customer
/// writes (`architecture/format-versioning.md`, the reserved-keyspace
/// decision), so a handler cannot forge a reservation.
pub const COUNTER_KEY = "_keys/next_slot";

/// `[1B version][8B end LE][8B nonce LE]` — the version is
/// `rove-keyring`'s `keyspace.VALUE_VERSION`, shared with the binding,
/// the tombstone and the watermark. One namespace, one version: a node
/// that cannot read one `_keys/*` value cannot be trusted to read the
/// rest of the tenant's key state either.
const VALUE_LEN: usize = 1 + 8 + 8;

/// How long to wait for the counter write to commit. Generous: this is
/// a background refill, never a request, so a slow round trip costs
/// pool depth rather than latency.
const COMMIT_TIMEOUT_NS: u64 = 10 * std.time.ns_per_s;

pub const Error = error{
    /// The tenant is not resident here, or has no raft group on this
    /// node — reserving for a tenant this node does not host would
    /// hand out slots nobody else agrees to.
    NotHosted,
    /// Another proposer's write landed on top of ours. The caller
    /// retries; `rove-reserve`'s refill loop already does.
    Raced,
    /// The propose was rejected (not leader) or did not commit in time.
    NotCommitted,
    /// The stored counter is not a value this codec wrote.
    Corrupt,
    /// The counter carries a version this binary does not implement.
    /// Kept distinct from `Corrupt`: reserving on top of a counter
    /// written by a newer node would hand out slots that node believes
    /// are already taken.
    UnsupportedVersion,
    OutOfMemory,
};

fn decode(bytes: []const u8) Error!struct { end: u64, nonce: u64 } {
    if (bytes.len == 0) return Error.Corrupt;
    if (bytes[0] != keyring_mod.keyspace.VALUE_VERSION) return Error.UnsupportedVersion;
    if (bytes.len != VALUE_LEN) return Error.Corrupt;
    return .{
        .end = std.mem.readInt(u64, bytes[1..9], .little),
        .nonce = std.mem.readInt(u64, bytes[9..17], .little),
    };
}

/// Read the committed counter, or `FIRST_SLOT` when the tenant has
/// never reserved. A missing key is the first-reservation case, not an
/// error.
fn readEnd(worker: anytype, tenant: []const u8) Error!u64 {
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
        return Error.NotHosted;
    const raw = inst.kv.get(COUNTER_KEY) catch |err| switch (err) {
        error.NotFound => return crypt.FIRST_SLOT,
        else => return Error.NotHosted,
    };
    defer worker.allocator.free(raw);
    return (try decode(raw)).end;
}

/// Reserve `count` slots strictly after `prev_end`, returning the new
/// exclusive end — so `[end - count, end)` is the caller's block.
///
/// Matches `rove-reserve`'s `ReservationProvider` contract. Runs on the
/// allocator's refill thread, off the poll loop and off the request
/// path.
///
/// The floor is `max(committed, prev_end, FIRST_SLOT)`. `committed`
/// keeps a fresh leader from reissuing its predecessor's range;
/// `prev_end` keeps this process from overlapping its own in-flight
/// refills; `FIRST_SLOT` keeps slot 0 — `TENANT_REF`, the tenant's own
/// key — out of the allocatable space.
pub fn reserve(
    worker: anytype,
    tenant: []const u8,
    prev_end: u64,
    count: u32,
) Error!u64 {
    // Reserving for a tenant this node does not host would hand out
    // slots nobody else agrees to.
    _ = worker.raft.gidForTenant(tenant) orelse return Error.NotHosted;

    const committed = try readEnd(worker, tenant);
    const floor = @max(@max(committed, prev_end), crypt.FIRST_SLOT);
    const new_end = std.math.add(u64, floor, count) catch return Error.Corrupt;
    if (new_end > crypt.keyring.MAX_SLOT) return Error.Corrupt;

    var nonce: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&nonce));

    var value: [VALUE_LEN]u8 = undefined;
    value[0] = keyring_mod.keyspace.VALUE_VERSION;
    std.mem.writeInt(u64, value[1..9], new_end, .little);
    std.mem.writeInt(u64, value[9..17], nonce, .little);

    try writeReplicated(worker, tenant, COUNTER_KEY, &value);

    // Read back and check the nonce. A commit is not proof the range is
    // ours: a concurrent proposer that computed the same `end` would
    // leave a value that looks correct by every measure except this.
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
        return Error.NotHosted;
    const raw = inst.kv.get(COUNTER_KEY) catch return Error.NotCommitted;
    defer worker.allocator.free(raw);
    const stored = try decode(raw);
    if (stored.nonce != nonce) return Error.Raced;

    return new_end;
}

/// Publish the tenant's minted watermark — the replicated statement
/// that every slot below `end` exists and every node should hold its key.
///
/// This is what makes a missing key readable as *erased* rather than
/// *not mine yet*: a node compares its own keyring against this number
/// and the destroy tombstones, and refuses to answer if it comes up
/// short. Without it, absence is an assumption the transport does not
/// back — raft elects on log up-to-dateness and key material travels
/// outside the log, so a node can be fully caught up and still missing
/// shards.
///
/// Called by the pool AFTER mint and quorum replication and BEFORE the
/// block is published, so no ciphertext can ever name a slot that some
/// node has no way to learn about. A failure here withholds the block
/// rather than handing out slots on a claim nobody replicated.
///
/// No read-modify-write and so no nonce guard, unlike the reservation
/// counter: this value is derived from a block the caller already owns,
/// and leadership serializes the writes. A stale leader cannot commit
/// one at all.
pub fn commitMinted(worker: anytype, tenant: []const u8, end: u64) Error!void {
    // Not hosted here ⇒ nothing to write and nobody to replicate to.
    _ = worker.raft.gidForTenant(tenant) orelse return Error.NotHosted;
    const value = keyring_mod.keyspace.encodeMinted(end);
    try writeReplicated(worker, tenant, keyring_mod.keyspace.MINTED_KEY, &value);
}

/// Put `key = value` in the tenant's store on THIS node and on every
/// other, then wait for the replication to commit.
///
/// The local txn is not an optimisation — see the provenance note in the
/// file header. Without it the leader is the one node that never gets
/// the value.
///
/// Local first, so a propose that never commits leaves the counter only
/// AHEAD here. That direction is safe: the floor rule only ever moves
/// forward, so a stale local value costs a skipped range and never
/// reissues one.
fn writeReplicated(
    worker: anytype,
    tenant: []const u8,
    key: []const u8,
    value: []const u8,
) Error!void {
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
        return Error.NotHosted;

    var txn = inst.kv.beginTrackedImmediate() catch return Error.NotCommitted;
    txn.put(key, value) catch {
        txn.rollback() catch {};
        return Error.NotCommitted;
    };
    txn.commit() catch return Error.NotCommitted;

    // No dispatched handler here, so no readset rides the envelope — the
    // stance every non-handler producer takes.
    var ws = kv_mod.WriteSet.init(worker.allocator);
    defer ws.deinit();
    ws.addPut(key, value) catch return Error.OutOfMemory;
    const proposed = raft_propose.proposeWriteSet(worker, &ws, tenant, "") catch
        return Error.NotCommitted;
    worker.raft.awaitCommit(proposed.group_id, proposed.seq, COMMIT_TIMEOUT_NS) catch
        return Error.NotCommitted;
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "the watermark and the reservation counter are different keys" {
    // Conflating them is the failure mode the split exists to prevent: a
    // leader that dies between reserving a block and minting it leaves
    // the RESERVATION ahead of anything that ever existed, and a node
    // measuring completeness against that declares itself permanently
    // incomplete through no fault of its own.
    try testing.expect(!std.mem.eql(u8, COUNTER_KEY, keyring_mod.keyspace.MINTED_KEY));
}

test "the counter key is closed to customer writes" {
    // A handler that could write `_keys/next_slot` could hand itself an
    // arbitrary slot range, which is the same as choosing another
    // identity's key.
    try testing.expect(std.mem.startsWith(u8, COUNTER_KEY, "_"));
}

test "value round-trips end and nonce" {
    var buf: [VALUE_LEN]u8 = undefined;
    buf[0] = keyring_mod.keyspace.VALUE_VERSION;
    std.mem.writeInt(u64, buf[1..9], 4096, .little);
    std.mem.writeInt(u64, buf[9..17], 0xDEADBEEF, .little);
    const d = try decode(&buf);
    try testing.expectEqual(@as(u64, 4096), d.end);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), d.nonce);
}

test "a short or oversized counter value is refused, never guessed at" {
    // Guessing here would mean handing out a slot range derived from
    // bytes this codec did not write. Both widths carry the RIGHT
    // version, so the length check has to fire on its own.
    var short = [_]u8{0} ** (VALUE_LEN - 1);
    short[0] = keyring_mod.keyspace.VALUE_VERSION;
    var long = [_]u8{0} ** (VALUE_LEN + 1);
    long[0] = keyring_mod.keyspace.VALUE_VERSION;
    try testing.expectError(Error.Corrupt, decode(""));
    try testing.expectError(Error.Corrupt, decode(&short));
    try testing.expectError(Error.Corrupt, decode(&long));
}

test "a counter written by a newer binary is refused, not reserved on top of" {
    // The interpretation switch. Reading a v2 counter at v1 widths would
    // return a slot range shifted by whatever the new layout put first —
    // and this codec's answer becomes the range a tenant's keys are
    // minted into, so a plausible wrong number is worse than no answer.
    var future: [VALUE_LEN]u8 = undefined;
    future[0] = keyring_mod.keyspace.VALUE_VERSION + 1;
    std.mem.writeInt(u64, future[1..9], 4096, .little);
    std.mem.writeInt(u64, future[9..17], 0xDEADBEEF, .little);
    try testing.expectError(Error.UnsupportedVersion, decode(&future));
}

test "the pre-version counter layout is refused" {
    // `[8B end][8B nonce]`, byte-for-byte. Reading one at today's widths
    // would shift `end` by a byte and hand out a range that overlaps a
    // block already minted.
    //
    // Which refusal it gets is not determined: byte 0 of the old layout
    // is the low byte of `end`, so a counter ending in 0x01 passes the
    // version check and fails on width, while any other fails on
    // version. Both refuse — that is the requirement, and pinning one
    // would assert a property of an arbitrary counter value.
    for ([_]u64{ 4096, 4097, 0xFF00 }) |old_end| {
        var old = [_]u8{0} ** 16;
        std.mem.writeInt(u64, old[0..8], old_end, .little);
        if (decode(&old)) |_| return error.TestExpectedError else |_| {}
    }
}

test "the floor rule keeps blocks from overlapping" {
    // The three inputs and what each one defends against, checked as
    // arithmetic rather than left to a comment.
    const FIRST = crypt.FIRST_SLOT;

    // A fresh tenant starts after the reserved tenant slot.
    try testing.expectEqual(FIRST, @max(@max(FIRST, 0), FIRST));

    // A new leader must not reissue its predecessor's committed range.
    try testing.expectEqual(@as(u64, 8192), @max(@max(@as(u64, 8192), 0), FIRST));

    // This process must not overlap a refill still in flight, even
    // though the committed value has not caught up yet.
    try testing.expectEqual(@as(u64, 8192), @max(@max(@as(u64, 4096), @as(u64, 8192)), FIRST));
}
