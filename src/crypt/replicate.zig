// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Keyring replication — the wire format and the quorum rule.
//!
//! A key that exists on one node is a key that dies with it, and a
//! keyring entry lost is data lost with no retry and no repair. So key
//! material has to reach a quorum before anything is sealed under it.
//!
//! ## Why this can be a file copy
//!
//! A shard's file key is `HKDF(cluster KEK, tenant id)` — the same
//! derivation on every node — so a sealed shard is **portable
//! ciphertext**. Replication ships the bytes verbatim: nothing is
//! decrypted in transit, no key is negotiated, and a peer installs what
//! it receives without ever holding a plaintext keyring. Repair and
//! backfill are the same operation as a normal update.
//!
//! ## What does NOT come through here
//!
//! Destroys. A destroy carries only a `key_ref` — an HMAC, no key
//! material — so it rides the tenant's raft group as an ordinary
//! replicated command and every node applies it to its own keyring
//! locally. That is deliberate: raft gives ordered, durable delivery to
//! nodes that were *down* at the time, which is exactly the guarantee
//! erasure needs and the one a best-effort push cannot make. Key
//! material can never take that path, because the log would keep a
//! destroyed key legible forever.
//!
//! So the split is: **erasure through the log, key material around it.**
//!
//! ## Single writer
//!
//! The tenant's raft leader owns its pool. Two nodes refilling
//! concurrently would produce shards that disagree about which key sits
//! in a slot, and a peer installing the loser would hand back a wrong
//! key later. Leadership is already the arbiter for every other write to
//! this tenant, so it arbitrates this one too.

const std = @import("std");
const crypt = @import("root.zig");
const keyring = @import("keyring.zig");

/// `RKX1` — distinct from the shard magic so a transfer frame and a
/// keyring file can never be mistaken for one another.
const MAGIC: u32 = 0x524B5831;
pub const WIRE_VERSION: u16 = 1;

/// `[4B magic][2B version][2B tenant_len][4B shard][4B sealed_len]`
pub const HEADER_LEN: usize = 4 + 2 + 2 + 4 + 4;

/// Ceiling on one frame, so a malformed length cannot make a receiver
/// allocate without bound. A shard's size is capped by construction —
/// its slot range cannot hold more than it contains — so this is that
/// bound plus the envelope.
pub const MAX_SEALED_LEN: usize = crypt.OVERHEAD + keyring.MAX_SHARD_BYTES;

pub const Error = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    TooLarge,
    OutOfMemory,
};

/// One shard's worth of sealed bytes, addressed to a tenant.
pub const Frame = struct {
    tenant_id: []const u8,
    /// Shard index. Shards are contiguous slot ranges, so the space
    /// grows with the tenant rather than being fixed.
    shard: u32,
    /// Sealed shard bytes, byte-identical to what the sender has on
    /// disk. Borrowed from the decoded buffer.
    sealed: []const u8,
};

pub fn encode(allocator: std.mem.Allocator, frame: Frame) Error![]u8 {
    if (frame.tenant_id.len > keyring.MAX_TENANT_ID_LEN) return Error.TooLarge;
    if (frame.sealed.len > MAX_SEALED_LEN) return Error.TooLarge;

    const total = HEADER_LEN + frame.tenant_id.len + frame.sealed.len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    errdefer allocator.free(out);

    std.mem.writeInt(u32, out[0..4], MAGIC, .big);
    std.mem.writeInt(u16, out[4..6], WIRE_VERSION, .little);
    std.mem.writeInt(u16, out[6..8], @intCast(frame.tenant_id.len), .little);
    std.mem.writeInt(u32, out[8..12], frame.shard, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(frame.sealed.len), .little);
    @memcpy(out[HEADER_LEN..][0..frame.tenant_id.len], frame.tenant_id);
    @memcpy(out[HEADER_LEN + frame.tenant_id.len ..], frame.sealed);
    return out;
}

/// Decode a frame. Slices borrow from `bytes`.
///
/// Version is checked before anything is trusted: a peer running a
/// newer wire format must be refused loudly rather than have its frame
/// half-understood, because a half-understood keyring transfer installs
/// wrong key material.
pub fn decode(bytes: []const u8) Error!Frame {
    if (bytes.len < HEADER_LEN) return Error.Truncated;
    if (std.mem.readInt(u32, bytes[0..4], .big) != MAGIC) return Error.BadMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != WIRE_VERSION)
        return Error.UnsupportedVersion;

    const id_len = std.mem.readInt(u16, bytes[6..8], .little);
    const shard = std.mem.readInt(u32, bytes[8..12], .little);
    const sealed_len = std.mem.readInt(u32, bytes[12..16], .little);
    if (id_len > keyring.MAX_TENANT_ID_LEN) return Error.TooLarge;
    if (sealed_len > MAX_SEALED_LEN) return Error.TooLarge;

    const want = HEADER_LEN + @as(usize, id_len) + @as(usize, sealed_len);
    // Exact, not "at least": a trailing remainder means the sender and
    // this decoder disagree about the frame, and guessing which is right
    // is how wrong bytes get installed as keys.
    if (bytes.len != want) return Error.Truncated;

    return .{
        .tenant_id = bytes[HEADER_LEN..][0..id_len],
        .shard = shard,
        .sealed = bytes[HEADER_LEN + id_len ..],
    };
}

// ── quorum ───────────────────────────────────────────────────────────

/// Whether a replication round has reached the point where the pool
/// keys it carries may be handed out.
pub const State = enum {
    /// Still waiting; not safe to seal under these keys yet.
    pending,
    /// Durable on a majority — a new leader is guaranteed to have them.
    durable,
    /// Enough peers failed that a majority can no longer be reached.
    /// Reported so the caller fails fast instead of waiting out a
    /// timeout it cannot win.
    impossible,
};

/// Majority tracking for one round of shard pushes.
///
/// Counts the sender itself: the node doing the refill has written its
/// own copy before pushing, so on a three-node cluster one peer ack is
/// already a majority.
pub const Quorum = struct {
    /// Nodes holding this tenant, including the sender.
    total: usize,
    acked: usize,
    failed: usize,

    /// `total` must be the tenant's full replica set, not the reachable
    /// subset. Sizing a majority against who happens to be up would let
    /// a partition declare durability that a healed cluster does not
    /// have.
    pub fn init(total: usize) Quorum {
        std.debug.assert(total >= 1);
        // The sender's own copy is written before the push begins.
        return .{ .total = total, .acked = 1, .failed = 0 };
    }

    pub fn needed(self: Quorum) usize {
        return self.total / 2 + 1;
    }

    pub fn ack(self: *Quorum) void {
        self.acked += 1;
    }

    pub fn fail(self: *Quorum) void {
        self.failed += 1;
    }

    pub fn state(self: Quorum) State {
        if (self.acked >= self.needed()) return .durable;
        // Everything not yet failed could still ack. When even all of
        // those would not reach a majority, waiting is pointless.
        const possible = self.total - self.failed;
        if (possible < self.needed()) return .impossible;
        return .pending;
    }
};

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "a frame round-trips" {
    const a = testing.allocator;
    const sealed = "sealed shard bytes";
    const buf = try encode(a, .{ .tenant_id = "acme", .shard = 0x2A, .sealed = sealed });
    defer a.free(buf);

    const f = try decode(buf);
    try testing.expectEqualStrings("acme", f.tenant_id);
    try testing.expectEqual(@as(u32, 0x2A), f.shard);
    try testing.expectEqualStrings(sealed, f.sealed);
}

test "an empty shard transfers — it is how a peer learns a shard emptied" {
    const a = testing.allocator;
    const buf = try encode(a, .{ .tenant_id = "acme", .shard = 0, .sealed = "" });
    defer a.free(buf);
    const f = try decode(buf);
    try testing.expectEqual(@as(usize, 0), f.sealed.len);
}

test "truncation, bad magic, and a future version are all refused" {
    const a = testing.allocator;
    try testing.expectError(Error.Truncated, decode("short"));

    const buf = try encode(a, .{ .tenant_id = "acme", .shard = 1, .sealed = "xyz" });
    defer a.free(buf);

    // A trailing byte means sender and decoder disagree about the
    // frame; installing a partially-understood keyring is worse than
    // failing.
    const extended = try a.alloc(u8, buf.len + 1);
    defer a.free(extended);
    @memcpy(extended[0..buf.len], buf);
    try testing.expectError(Error.Truncated, decode(extended));

    const bad_magic = try a.dupe(u8, buf);
    defer a.free(bad_magic);
    bad_magic[0] ^= 0xFF;
    try testing.expectError(Error.BadMagic, decode(bad_magic));

    const future = try a.dupe(u8, buf);
    defer a.free(future);
    std.mem.writeInt(u16, future[4..6], WIRE_VERSION + 1, .little);
    try testing.expectError(Error.UnsupportedVersion, decode(future));
}

test "a declared length beyond the cap is refused before allocating" {
    const a = testing.allocator;
    const buf = try encode(a, .{ .tenant_id = "acme", .shard = 1, .sealed = "xyz" });
    defer a.free(buf);
    std.mem.writeInt(u32, buf[12..16], @intCast(MAX_SEALED_LEN + 1), .little);
    try testing.expectError(Error.TooLarge, decode(buf));
}

test "the keyring magic is not mistaken for a transfer frame" {
    // Both formats begin with a big-endian magic; a keyring file fed to
    // the frame decoder must be rejected rather than partly parsed.
    var shard_file: [64]u8 = undefined;
    std.mem.writeInt(u32, shard_file[0..4], 0x524B5231, .big); // 'RKR1'
    try testing.expectError(Error.BadMagic, decode(&shard_file));
}

test "a three-node quorum needs one peer ack" {
    var q = Quorum.init(3);
    try testing.expectEqual(@as(usize, 2), q.needed());
    // The sender's own copy is already written.
    try testing.expectEqual(State.pending, q.state());
    q.ack();
    try testing.expectEqual(State.durable, q.state());
}

test "a single-node cluster is durable without any peer" {
    var q = Quorum.init(1);
    try testing.expectEqual(@as(usize, 1), q.needed());
    try testing.expectEqual(State.durable, q.state());
    // A failure it cannot have does not change that.
    q.fail();
    try testing.expectEqual(State.durable, q.state());
}

test "quorum turns impossible as soon as enough peers fail" {
    var q = Quorum.init(3);
    q.fail();
    // One peer left; sender + that peer would still be a majority.
    try testing.expectEqual(State.pending, q.state());
    q.fail();
    // Both peers gone — waiting can no longer win, so say so rather
    // than stall until a timeout.
    try testing.expectEqual(State.impossible, q.state());
}

test "a five-node cluster needs two peer acks" {
    var q = Quorum.init(5);
    try testing.expectEqual(@as(usize, 3), q.needed());
    q.ack();
    try testing.expectEqual(State.pending, q.state());
    q.ack();
    try testing.expectEqual(State.durable, q.state());
}

test "durable once reached is not undone by a later failure" {
    // A late failure from a straggler must not retract a majority that
    // already exists — the keys are durable and the caller may have
    // acted on that.
    var q = Quorum.init(5);
    q.ack();
    q.ack();
    try testing.expectEqual(State.durable, q.state());
    q.fail();
    try testing.expectEqual(State.durable, q.state());
}

test "quorum is sized against the replica set, not who is reachable" {
    // Three nodes, one partitioned away. The two on this side are a
    // majority; the single node on the other side must not be.
    var majority_side = Quorum.init(3);
    majority_side.ack();
    try testing.expectEqual(State.durable, majority_side.state());

    var minority_side = Quorum.init(3);
    minority_side.fail();
    minority_side.fail();
    try testing.expectEqual(State.impossible, minority_side.state());
}
