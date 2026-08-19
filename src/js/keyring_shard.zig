// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Keyring shard transport — the wire that makes a minted key durable
//! somewhere other than the node that minted it.
//!
//! A key that exists on one node dies with it, and a lost keyring entry
//! is data lost with no retry and no repair: whatever it sealed becomes
//! unreadable. So a slot is never handed out before its key has reached
//! a quorum of the tenant's replica set, and this is how it gets there.
//!
//! ## Ciphertext on the wire, by construction
//!
//! A shard's file key is `HKDF(cluster KEK, tenant id)` — the same
//! derivation on every node — so a sealed shard is **portable
//! ciphertext**. The bytes move verbatim: nothing is decrypted in
//! transit, no key is negotiated, and a receiver installs what it got
//! without ever holding a plaintext keyring. Backfill and repair are
//! the same operation as a normal update, so there is no separate
//! reconciliation path to get wrong.
//!
//! ## What does NOT come through here
//!
//! Destroys. A destroy carries only a slot number, no key material, so
//! it rides the tenant's raft group as a replicated command — which is
//! what delivers it, in order, to nodes that were *down* when it
//! happened. A best-effort push cannot make that guarantee, and erasure
//! is the half that most needs it. Key material can never take that
//! path, because the log would keep a destroyed key legible forever.
//!
//! Erasure through the log, key material around it.
//!
//! ## Threading
//!
//! `pushToQuorum` blocks on HTTP and MUST NOT run on the poll loop. It
//! is called from the slot pool's block-preparation callback, which runs
//! on the allocator's background refill thread — ahead of demand, never
//! on a request.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const crypt = @import("rove-crypt");
const blob = @import("rove-blob");
const curl = blob.curl;
const respb = @import("response_builder.zig");
const bridge_control = @import("bridge").control;

/// `/_system/` suffix this handles. Registered in the `v2-*` family, so
/// it inherits that family's move-secret gate.
pub const ROUTE = "v2-keyring-shard";

const MOVE_SECRET_HEADER = "X-Rewind-Move-Secret";

/// Cap on a tenant's voter set when reading its membership. Groups are
/// three or five voters in practice; this is a buffer bound, not a
/// policy.
const MAX_VOTERS = 16;

/// Keyring root under the node's data dir. One directory per tenant
/// beneath it.
pub fn keyringDir(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/keyrings", .{data_dir});
}

// ── receive ──────────────────────────────────────────────────────────

/// `POST /_system/v2-keyring-shard` — install a sealed shard from a peer.
///
/// The frame is verified before it lands, not at the next open. An
/// unverified install poisons the receiver silently and surfaces at a
/// failover — the worst possible moment, because that is exactly when
/// this node's copy becomes the only copy.
///
/// Status codes distinguish faults an operator responds to differently:
/// a malformed frame is a version or wire problem, a KEK mismatch is
/// node configuration, and a bad shard body is a corrupt transfer.
pub fn handlePush(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    body: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST"))
        return respb.setSystemResponse(server, ent, sid, sess, 405, "POST only\n", allocator, null, null);

    const kek = worker.keyring_kek orelse
        return respb.setSystemResponse(server, ent, sid, sess, 404, "keyring surface disabled\n", allocator, null, null);
    const data_dir = worker.data_dir orelse
        return respb.setSystemResponse(server, ent, sid, sess, 404, "keyring surface disabled\n", allocator, null, null);

    const frame = crypt.replicate.decode(body) catch |err| {
        std.log.warn("v2-keyring-shard: undecodable frame: {s}", .{@errorName(err)});
        return respb.setSystemResponse(server, ent, sid, sess, 400, "bad keyring frame\n", allocator, null, null);
    };

    const dir = try keyringDir(allocator, data_dir);
    defer allocator.free(dir);

    crypt.keyring.installSealedShard(
        allocator,
        dir,
        frame.tenant_id,
        kek,
        frame.shard,
        frame.sealed,
    ) catch |err| {
        const status: u16 = switch (err) {
            // The sender seals under a different KEK than we open with:
            // the two nodes are configured differently, and every future
            // push will fail the same way until that is fixed.
            error.AuthFailed => 409,
            error.Corrupt => 422,
            else => 500,
        };
        std.log.warn(
            "v2-keyring-shard {s} shard={d}: install failed: {s}",
            .{ frame.tenant_id, frame.shard, @errorName(err) },
        );
        return respb.setSystemResponse(server, ent, sid, sess, status, "keyring install failed\n", allocator, null, null);
    };

    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── push ─────────────────────────────────────────────────────────────

pub const PushError = error{
    /// A majority of the tenant's replica set did not take the shard.
    NoQuorum,
    /// The tenant's membership could not be read, so a majority is not
    /// even definable — never guessed at.
    UnknownMembership,
    KeyringDisabled,
    OutOfMemory,
};

/// Push `shard` to the tenant's replica set and return only once a
/// majority holds it.
///
/// Quorum is sized on the group's **voter set**, not on who happens to
/// answer: sizing a majority against the reachable subset would let a
/// partition declare durability that a healed cluster does not have.
/// The local copy counts, because it is written before this is called.
///
/// An absent shard pushes zero bytes, which is how a peer learns a
/// shard emptied rather than merely not being updated.
pub fn pushToQuorum(
    allocator: std.mem.Allocator,
    worker: anytype,
    tenant: []const u8,
    gid: u64,
    shard: u32,
) PushError!void {
    const kek = worker.keyring_kek orelse return PushError.KeyringDisabled;
    const data_dir = worker.data_dir orelse return PushError.KeyringDisabled;
    const secret = worker.move_secret orelse return PushError.KeyringDisabled;

    var voters_buf: [MAX_VOTERS]u64 = undefined;
    var learners_buf: [MAX_VOTERS]u64 = undefined;
    const cs = bridge_control.confState(worker.raft, gid, &voters_buf, &learners_buf) orelse
        return PushError.UnknownMembership;
    if (cs.voters.len == 0) return PushError.UnknownMembership;

    const dir = keyringDir(allocator, data_dir) catch return PushError.OutOfMemory;
    defer allocator.free(dir);

    const sealed = crypt.keyring.readSealedShard(allocator, dir, tenant, kek, shard) catch |err| {
        std.log.warn(
            "keyring push {s} shard={d}: local read failed: {s}",
            .{ tenant, shard, @errorName(err) },
        );
        return PushError.NoQuorum;
    };
    defer if (sealed) |s| allocator.free(s);

    const body = crypt.replicate.encode(allocator, .{
        .tenant_id = tenant,
        .shard = shard,
        .sealed = sealed orelse "",
    }) catch return PushError.OutOfMemory;
    defer allocator.free(body);

    var q = crypt.replicate.Quorum.init(cs.voters.len);
    const self_id: u64 = worker.raft.config.node_id;

    // EVERY voter is offered the shard, not just enough of them.
    //
    // A majority is the bar for calling the key durable; it is the wrong
    // bar for stopping. Stopping there leaves a voter that is up and
    // reachable without the shard, and nothing brings it one later:
    // pushes are per-shard and refills append to the TAIL shard, so once
    // minting moves past a shard — or the tenant simply stops taking new
    // identities — that node's gap is permanent.
    //
    // It matters because raft elects on LOG up-to-dateness and the
    // keyring deliberately sits outside the log, so those two majorities
    // are unrelated. The node that missed a shard can win an election,
    // and a node that answers reads while missing a key reports live
    // data as erased — `keyAt` returns null and absence is authoritative.
    //
    // Cost is bounded: this runs on the refill path, ahead of demand,
    // never on a request. A slow peer delays a future block, not a seal.
    for (cs.voters) |peer| {
        if (peer == self_id) continue; // already written locally

        const base = peerUrl(worker, peer) orelse {
            q.fail();
            continue;
        };
        if (postShard(allocator, base, secret, body)) {
            q.ack();
        } else {
            q.fail();
        }
        // A majority is unreachable — stop rather than time out against
        // peers that cannot change the answer. Unreachable only while
        // NOT yet durable: `state` checks `acked >= needed` first, so a
        // later peer failing after quorum cannot un-durable the push.
        if (q.state() == .impossible) break;
    }

    if (q.state() != .durable) {
        std.log.warn(
            "keyring push {s} shard={d}: no quorum ({d}/{d} of {d} voters)",
            .{ tenant, shard, q.acked, q.needed(), cs.voters.len },
        );
        return PushError.NoQuorum;
    }
}

/// Resolve a raft node id to its HTTP base. Node ids are 1-based
/// indices into `REWIND_PEER_URLS`, the same mapping snapshot catch-up
/// uses — a peer with no entry is misconfiguration, and is logged as
/// such rather than silently counted as a failure with no explanation.
fn peerUrl(worker: anytype, peer: u64) ?[]const u8 {
    const urls = worker.peer_urls;
    if (peer == 0 or peer - 1 >= urls.len) {
        std.log.warn(
            "keyring push: no REWIND_PEER_URLS entry for peer {d} ({d} configured)",
            .{ peer, urls.len },
        );
        return null;
    }
    return urls[peer - 1];
}

/// One shard POST. True only on 204 — anything else is "this peer does
/// not have it", which is the only thing quorum counting may believe.
fn postShard(
    allocator: std.mem.Allocator,
    base: []const u8,
    secret: []const u8,
    body: []const u8,
) bool {
    const url = std.fmt.allocPrint(allocator, "{s}/_system/" ++ ROUTE, .{base}) catch return false;
    defer allocator.free(url);

    const headers = [_]curl.Header{
        .{ .name = MOVE_SECRET_HEADER, .value = secret },
        .{ .name = "Content-Type", .value = "application/octet-stream" },
    };
    var resp = curl.cpPost(allocator, url, body, .{ .headers = &headers }) catch |err| {
        std.log.warn("keyring push to {s}: transport error: {s}", .{ base, @errorName(err) });
        return false;
    };
    defer resp.deinit(allocator);

    if (resp.status != 204) {
        std.log.warn("keyring push to {s}: peer replied {d}", .{ base, resp.status });
        return false;
    }
    return true;
}
