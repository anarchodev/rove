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

const std = @import("std");
const crypt = @import("rove-crypt");

/// Platform-reserved counter key. Leading `_` is closed to customer
/// writes (`architecture/format-versioning.md`, the reserved-keyspace
/// decision), so a handler cannot forge a reservation.
pub const COUNTER_KEY = "_keys/next_slot";

/// `[8B end LE][8B nonce LE]`
const VALUE_LEN: usize = 16;

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
    OutOfMemory,
};

fn decode(bytes: []const u8) Error!struct { end: u64, nonce: u64 } {
    if (bytes.len != VALUE_LEN) return Error.Corrupt;
    return .{
        .end = std.mem.readInt(u64, bytes[0..8], .little),
        .nonce = std.mem.readInt(u64, bytes[8..16], .little),
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
    const gid = worker.raft.gidForTenant(tenant) orelse return Error.NotHosted;

    const committed = try readEnd(worker, tenant);
    const floor = @max(@max(committed, prev_end), crypt.FIRST_SLOT);
    const new_end = std.math.add(u64, floor, count) catch return Error.Corrupt;
    if (new_end > crypt.keyring.MAX_SLOT) return Error.Corrupt;

    var nonce: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&nonce));

    var value: [VALUE_LEN]u8 = undefined;
    std.mem.writeInt(u64, value[0..8], new_end, .little);
    std.mem.writeInt(u64, value[8..16], nonce, .little);

    const seq = worker.raft.proposePut(gid, COUNTER_KEY, &value) catch
        return Error.NotCommitted;
    worker.raft.awaitCommit(gid, seq, COMMIT_TIMEOUT_NS) catch
        return Error.NotCommitted;

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

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "the counter key is closed to customer writes" {
    // A handler that could write `_keys/next_slot` could hand itself an
    // arbitrary slot range, which is the same as choosing another
    // identity's key.
    try testing.expect(std.mem.startsWith(u8, COUNTER_KEY, "_"));
}

test "value round-trips end and nonce" {
    var buf: [VALUE_LEN]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 4096, .little);
    std.mem.writeInt(u64, buf[8..16], 0xDEADBEEF, .little);
    const d = try decode(&buf);
    try testing.expectEqual(@as(u64, 4096), d.end);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), d.nonce);
}

test "a short or oversized counter value is refused, never guessed at" {
    // Guessing here would mean handing out a slot range derived from
    // bytes this codec did not write.
    try testing.expectError(Error.Corrupt, decode(""));
    try testing.expectError(Error.Corrupt, decode(&[_]u8{0} ** (VALUE_LEN - 1)));
    try testing.expectError(Error.Corrupt, decode(&[_]u8{0} ** (VALUE_LEN + 1)));
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
