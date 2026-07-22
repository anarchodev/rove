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
const bc = @import("backend_client.zig");
const BackendResp = bc.BackendResp;
const TENANT_HEADER = bc.TENANT_HEADER;
const PLAN_HEADER = bc.PLAN_HEADER;

pub fn clusterVotersCsv(a: std.mem.Allocator, n: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        if (i != 1) try buf.append(a, ',');
        try buf.writer(a).print("{d}", .{i});
    }
    return buf.toOwnedSlice(a);
}

pub fn attachToAll(router: anytype, dest_nodes: []const []const u8, bundle: []const u8, tenant: []const u8, plan: ?[]const u8, birth_voters: ?[]const u8) bool {
    const a = router.allocator;
    var hdrs: [3]curl.Header = undefined;
    hdrs[0] = .{ .name = TENANT_HEADER, .value = tenant };
    var nh: usize = 1;
    if (plan) |p| {
        hdrs[nh] = .{ .name = PLAN_HEADER, .value = p };
        nh += 1;
    }
    // Cluster node-set SSOT: the cluster's node set as the born
    // group's voter set, the CP-owned single source of truth — the SAME set
    // for every node, so the group forms consistently without depending on
    // each node's static `REWIND_VOTERS`. Null → the node falls back to its env.
    if (birth_voters) |v| {
        hdrs[nh] = .{ .name = "X-Rewind-Voters", .value = v };
        nh += 1;
    }
    for (dest_nodes) |base| {
        const resp = bc.call(router, base, "/_system/v2-attach", .POST, bundle, hdrs[0..nh]) catch |err| {
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

/// Additive membership reconciler (opt-in `reconcile_membership`).
/// On the directory leader, converge each placed tenant's DP group
/// membership to its cluster's node set: for the first not-caught-up node
/// per group per pass, take a LEARNER-FIRST `ensureMember` step. ADDITIVE
/// ONLY — never removes/migrates/destroys. Blocking HTTP on the loop,
/// bounded to one node per group per pass.

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
        .{ .name = TENANT_HEADER, .value = tenant },
        .{ .name = "x-rewind-dest", .value = dest },
        .{ .name = "x-rewind-snapshot-mode", .value = "merge" },
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
