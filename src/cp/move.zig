// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Tenant-move orchestration helpers — the reply-free workers behind the
//! CP's `/_control/move-live` + provisioning paths, split out of
//! `cp/main.zig`'s Router. Each takes explicit node/tenant args and returns a
//! bool/value (the handler — `handleMoveLive` / `handleProvision` — stays in
//! Router and does the HTTP replies). Free functions taking `router: anytype`
//! for structural access to the Router's `allocator` + `directory`, the same
//! shape the worker_*.zig family uses. Backend hops ride `backend_client`.

const std = @import("std");
const blob = @import("rove-blob");
const curl = blob.curl;
const wire = @import("rove-wire");
const bc = @import("backend_client.zig");
const BackendResp = bc.BackendResp;

/// The cluster's voter set as raft ids `1..n` (raft ids are positional —
/// node index i → id i+1, the `REWIND_PEERS` convention). Caller frees.
/// The cluster node-set SSOT for a fresh tenant group.
pub fn clusterVoterIds(a: std.mem.Allocator, n: usize) ![]u64 {
    const ids = try a.alloc(u64, n);
    for (ids, 0..) |*id, i| id.* = i + 1;
    return ids;
}

/// Fan an EMPTY `/_system/v2-attach` (`X-Rewind-Tenant`, plus the tenant's
/// `X-Rewind-Plan` blob when set) out to every destination node — attach
/// forms the group + instance with no data; state arrives via the streamed
/// snapshot push / log replication. The plan rides attach so the destination
/// enforces the right limits from the first post-move request (CP
/// operational-state model, docs/architecture/control-plane.md). True only if
/// all returned 204 (idempotent re-attach included). On the first failure
/// returns false; the caller evicts the partially-attached set.
///
/// `incarnation` is the tenant's storage incarnation (#357) in MARKER
/// spelling: every node must key the tenant's storage identically, so EVERY
/// attach — provision, move, membership backfill — carries the one the CP
/// recorded at provision. Empty = the legacy name-keyed layout (correct only
/// for tenants provisioned before incarnations existed); the shared encoder
/// puts it on the wire explicitly either way.
///
/// `birth_voters` is the cluster node-set SSOT: the CP-owned voter set the
/// born group forms with — the SAME set for every node, so the group forms
/// consistently without depending on each node's static `REWIND_VOTERS`.
/// Null → the node falls back to its env.
/// `secret` is the tenant's keyring root, 64 hex, and is sent ONLY at
/// birth — one minter fanning the same bytes to every birth node is what
/// makes it agree cluster-wide. A move passes null: the destination is a
/// new home for an existing tenant, so its keyring arrives from a peer as
/// KEK-sealed ciphertext rather than being re-minted (re-minting would
/// strand every byte the old key sealed).
pub fn attachToAll(router: anytype, dest_nodes: []const []const u8, tenant: []const u8, plan: ?[]const u8, birth_voters: ?[]const u64, incarnation: []const u8, secret: ?[]const u8) bool {
    const a = router.allocator;
    var enc = wire.encodeAttach(a, .{
        .tenant = tenant,
        .incarnation = incarnation,
        .plan = plan,
        .voters = birth_voters,
        .secret = secret,
    }) catch return false;
    defer enc.deinit();
    for (dest_nodes) |base| {
        const resp = bc.call(router, base, "/_system/v2-attach", .POST, "", enc.headers) catch |err| {
            std.log.warn("rewind-cp: v2-attach on {s} failed: {s}", .{ base, @errorName(err) });
            return false;
        };
        var r = resp;
        defer r.deinit(a);
        if (r.status != 204) {
            std.log.warn("rewind-cp: v2-attach on {s} → {d}", .{ base, r.status });
            return false;
        }
    }
    return true;
}

/// Poll every destination node's `/_system/v2-leader?tenant=…` until one
/// reports 200 (the formed group elected a leader), bounded by a wall
/// deadline. True once a leader is seen; false on timeout.
pub fn awaitDestLeader(router: anytype, dest_nodes: []const []const u8, tenant: []const u8) bool {
    const a = router.allocator;
    const suffix = std.fmt.allocPrint(a, "/_system/v2-leader?tenant={s}", .{tenant}) catch return false;
    defer a.free(suffix);
    const deadline: i128 = std.time.nanoTimestamp() + 15 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        for (dest_nodes) |base| {
            const resp = bc.call(router, base, suffix, .GET, "", &.{}) catch continue;
            var r = resp;
            r.deinit(a);
            if (r.status == 200) return true;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

/// Best-effort `/_system/v2-evict` to every node of a cluster (the move
/// committed, or we are unwinding a partial attach). Logs failures.
pub fn evictAll(router: anytype, tenant: []const u8, nodes: []const []const u8, tbody: []const u8) void {
    const a = router.allocator;
    for (nodes) |base| {
        if (bc.call(router, base, "/_system/v2-evict", .POST, tbody, &.{})) |ev| {
            var e2 = ev;
            e2.deinit(a);
        } else |err| {
            std.log.warn("rewind-cp: evict {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
        }
    }
}

/// `evictAll`, but reporting whether EVERY node accepted. A deprovision needs
/// the answer: a move can treat a failed evict as cosmetic (the tenant lives on
/// elsewhere), while a delete that silently skipped a node would leave an
/// orphaned group holding the tenant's name on that node forever.
///
/// A node that no longer has the group answers 204 as well — `v2-evict` is
/// idempotent — so a retry after a partial failure converges to true.
pub fn evictAllChecked(router: anytype, tenant: []const u8, nodes: []const []const u8, tbody: []const u8) bool {
    const a = router.allocator;
    var all = true;
    for (nodes) |base| {
        if (bc.call(router, base, "/_system/v2-evict", .POST, tbody, &.{})) |ev| {
            var e2 = ev;
            defer e2.deinit(a);
            if (e2.status != 204 and e2.status != 200) {
                std.log.warn("rewind-cp: evict {s} on {s}: status {d}", .{ tenant, base, e2.status });
                all = false;
            }
        } else |err| {
            std.log.warn("rewind-cp: evict {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
            all = false;
        }
    }
    return all;
}

/// Pick a serving leader URL for `tenant` from `dest_nodes` — the forward
/// target for a live move. Returns the first node that self-reports as the
/// group leader, or null if none does yet.
pub fn findDestLeaderUrl(router: anytype, dest_nodes: []const []const u8, tenant: []const u8) ?[]u8 {
    const a = router.allocator;
    const suffix = std.fmt.allocPrint(a, "/_system/v2-leader?tenant={s}", .{tenant}) catch return null;
    defer a.free(suffix);
    const deadline: i128 = std.time.nanoTimestamp() + 15 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        for (dest_nodes) |base| {
            const resp = bc.call(router, base, suffix, .GET, "", &.{}) catch continue;
            var r = resp;
            r.deinit(a);
            if (r.status == 200) return a.dupe(u8, base) catch null;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return null;
}

/// The forward-target list for `v2-forward-begin`: every dest node's base
/// URL, comma-separated, with the current leader first (the common case
/// is then one forward attempt). Null on OOM.
pub fn csvLeaderFirst(a: std.mem.Allocator, leader: []const u8, nodes: []const []const u8) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    out.appendSlice(a, leader) catch return null;
    for (nodes) |base| {
        if (std.mem.eql(u8, base, leader)) continue;
        out.append(a, ',') catch return null;
        out.appendSlice(a, base) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

/// forward-begin on the source leader: try each source node's leader-gated
/// `/_system/v2-forward-begin {tenant,dest}` until one 204s (the leader).
pub fn forwardBeginOnLeader(router: anytype, src_nodes: []const []const u8, tenant: []const u8, dest_url: []const u8) bool {
    const a = router.allocator;
    const fb = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"dest\":\"{s}\"}}", .{ tenant, dest_url }) catch return false;
    defer a.free(fb);
    for (src_nodes) |base| {
        const resp = bc.call(router, base, "/_system/v2-forward-begin", .POST, fb, &.{}) catch continue;
        const ok = resp.status == 204;
        var r = resp;
        r.deinit(a);
        if (ok) return true;
    }
    return false;
}

/// forward-end on the source leader (abort cleanup): best-effort.
pub fn forwardEndOnLeader(router: anytype, src_nodes: []const []const u8, tenant: []const u8) void {
    const a = router.allocator;
    const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch return;
    defer a.free(tbody);
    for (src_nodes) |base| {
        if (bc.call(router, base, "/_system/v2-forward-end", .POST, tbody, &.{})) |r| {
            const ok = r.status == 204;
            var rr = r;
            rr.deinit(a);
            if (ok) return;
        } else |_| {}
    }
}

/// STREAM the source leader's non-quiescing snapshot directly to every
/// destination node in merge mode (insert-if-absent) — the source pushes
/// peer→peer, so the CP never buffers a (multi-GB) bundle.
pub fn streamMergeToAll(router: anytype, src_nodes: []const []const u8, dest_nodes: []const []const u8, tenant: []const u8) bool {
    for (dest_nodes) |dest| {
        if (!snapshotPushToLeader(router, src_nodes, tenant, dest)) return false;
    }
    return true;
}

/// Try each source node's leader-gated `/_system/v2-snapshot-push` until one
/// accepts (the leader streams its held snapshot to `dest` in merge mode and
/// only then responds). Blocks for the whole transfer — generous timeout; the
/// source's own page-pinning deadline aborts first if the tenant is too big.
pub fn snapshotPushToLeader(router: anytype, src_nodes: []const []const u8, tenant: []const u8, dest: []const u8) bool {
    const a = router.allocator;
    const hdrs = [_]curl.Header{
        .{ .name = wire.TENANT, .value = tenant },
        .{ .name = wire.DEST, .value = dest },
        .{ .name = wire.SNAPSHOT_MODE, .value = "merge" },
    };
    for (src_nodes) |base| {
        const resp = bc.callTimeout(router, base, "/_system/v2-snapshot-push", .POST, "", &hdrs, 40 * 60 * 1000) catch |err| {
            std.log.warn("rewind-cp: v2-snapshot-push on {s} → {s}", .{ base, @errorName(err) });
            continue;
        };
        var r = resp;
        defer r.deinit(a);
        switch (r.status) {
            // 204 = streamed + merged; 409 = dest already had it (benign).
            204, 409 => return true,
            // 421 = this source node isn't the leader; try the next.
            421 => continue,
            else => {
                std.log.warn("rewind-cp: v2-snapshot-push on {s} → {d}", .{ base, r.status });
                return false;
            },
        }
    }
    return false;
}
