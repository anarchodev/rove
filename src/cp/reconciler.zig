// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Additive membership reconciler — the RC-6 state machine that converges
//! each placed tenant's DP raft group to its cluster's node set, split out of
//! `cp/main.zig`'s Router. Runs on the directory-leader tick; never touches
//! the read/control-write APIs. Free functions taking `router: anytype` for
//! structural access to the Router's reconciler fields (`demote_inactive_since`,
//! `reconcile_passes`, `confchange_*`, `demote_grace_ns`) + `allocator` +
//! `directory`; backend hops ride `backend_client`, and it borrows the move
//! path's `findDestLeaderUrl` to pick a group leader.

const std = @import("std");
const blob = @import("rove-blob");
const curl = blob.curl;
const wire = @import("rove-wire");
const bc = @import("backend_client.zig");
const move = @import("move.zig");
const Directory = @import("cp-directory").Directory;
const BackendResp = bc.BackendResp;

/// Additive membership reconciler (opt-in `reconcile_membership`).
/// On the directory leader, converge each placed tenant's DP group
/// membership to its cluster's node set: for the first not-caught-up node
/// per group per pass, take a LEARNER-FIRST `ensureMember` step. ADDITIVE
/// ONLY — never removes/migrates/destroys. Blocking HTTP on the loop,
/// bounded to one node per group per pass.
pub fn reconcileMembership(router: anytype) void {
    if (!router.reconcile_membership) return;
    if (!router.directory.isLeader()) return; // single writer
    router.reconcile_passes += 1;
    const a = router.allocator;
    const tenants = router.directory.listPlacements(a) catch return;
    defer {
        for (tenants) |t| a.free(t);
        a.free(tenants);
    }
    for (tenants) |tenant| {
        // resolveOwned (not resolve): the node set is held across the blocking
        // backendCalls below, and a concurrent re-address (applyClusterLocal on
        // the pump thread — exactly the /_control/cluster grow that adds a
        // node) frees `resolve`'s projection-aliased slice → use-after-free.
        // The owned copy is taken under the directory lock.
        var res = (router.directory.resolveOwned(a, tenant) catch continue) orelse continue;
        defer res.deinit(a);
        const nodes = res.nodes;
        if (nodes.len == 0) continue;
        const leader_url = move.findDestLeaderUrl(router, nodes, tenant) orelse {
            std.log.debug("reconcile: no reachable leader for {s} this pass", .{tenant});
            continue;
        };
        defer a.free(leader_url);
        // One membership CHANGE per group per pass: a node that's already
        // good (.done) → check the next; a transient failure (.failed) →
        // try the NEXT node (a single unreachable node must not starve the
        // rest of the cluster from being backfilled); a real mutation
        // (.progressed) → stop and re-observe next pass.
        for (nodes, 0..) |node_url, i| {
            const node_id: u64 = @intCast(i + 1); // POSITIONAL id (nodes[i] ↔ raft id i+1)
            switch (ensureMember(router, tenant, node_url, node_id, leader_url, res.id)) {
                .done, .failed => continue,
                .progressed => break,
            }
        }
    }
}

// ── membership reconciler: ensureMember ─────────────────────────────────
//
// Composes the proven out-of-band endpoints into a LEARNER-FIRST step
// machine that converges a node toward a caught-up voter. Additive/safe:
// the only voting-power removal is a demote-to-learner of a STUCK voter (so
// it can't disrupt elections while it catches up — the __admin__ lesson);
// it never shrinks/migrates/destroys. All over the private CP network via
// backendCall (move-secret auto-added). Blocking HTTP on the CP loop; the
// reconciler does one node per group per pass.
const EnsureResult = enum { done, progressed, failed };
/// caught-up tolerance: matched/applied within this of leader_last counts as
/// caught up (raft replicates the tail in well under this; avoids flapping
/// as leader_last advances on a live group).
const RECONCILE_SLACK: u64 = 16;
const PeerJson = struct { id: u64 = 0, matched: u64 = 0, recent_active: bool = false };
const MemberStatusJson = struct {
    leader_last: u64 = 0,
    voters: []const u64 = &.{},
    learners: []const u64 = &.{},
    peers: []const PeerJson = &.{},
};
fn idIn(list: []const u64, id: u64) bool {
    for (list) |x| if (x == id) return true;
    return false;
}

/// RC-6 hysteresis: true iff `node_id` of `tenant` has been a continuous
/// demote candidate (`!recent_active`, still a hosted voter) for at least
/// `demote_grace_ns`. The FIRST call starts the timer and returns false, so a
/// single `!recent_active` reading (a transient restart) never demotes.
fn demoteGraceElapsed(router: anytype, tenant: []const u8, node_id: u64) bool {
    var kbuf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "{s}|{d}", .{ tenant, node_id }) catch return false;
    const now = std.time.nanoTimestamp();
    if (router.demote_inactive_since.getPtr(key)) |since|
        return now - since.* >= router.demote_grace_ns;
    // First observation — start the grace window; never demote on it.
    const owned = router.allocator.dupe(u8, key) catch return false;
    router.demote_inactive_since.put(router.allocator, owned, now) catch {
        router.allocator.free(owned);
        return false;
    };
    return false;
}

/// Clear `node_id` of `tenant`'s demote grace timer — the voter recovered
/// (recent_active) or left the hosted-voter state, so the window resets.
fn clearDemoteTimer(router: anytype, tenant: []const u8, node_id: u64) void {
    var kbuf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "{s}|{d}", .{ tenant, node_id }) catch return;
    if (router.demote_inactive_since.fetchRemove(key)) |kv| router.allocator.free(kv.key);
}

/// Advance node `node_id` (at `node_url`) ONE step toward being a caught-up
/// voter of `tenant`'s group, talking to `leader_url`. `.done` when already a
/// caught-up voter, `.progressed` after a step (re-check next pass), `.failed`
/// on a transient error (retry next pass).
fn ensureMember(router: anytype, tenant: []const u8, node_url: []const u8, node_id: u64, leader_url: []const u8, cluster_id: []const u8) EnsureResult {
    const a = router.allocator;
    // The leader is trivially a caught-up voter of its own group.
    if (std.mem.eql(u8, node_url, leader_url)) return .done;

    // The joining node's raft transport address from the registry (genesis
    // §3.3), carried on the add/promote conf-change so the leader can dial
    // it. Empty when the node isn't registered (a still-static cluster —
    // the leader falls back to its static peers). Owned; freed below.
    const raft_addr_owned: ?[]u8 = raftAddrFor(router, cluster_id, node_id);
    defer if (raft_addr_owned) |ra| a.free(ra);
    const raft_addr: []const u8 = raft_addr_owned orelse "";

    // 1. Observe the leader's per-peer view.
    const ms_path = std.fmt.allocPrint(a, "/_system/v2-member-status?tenant={s}", .{tenant}) catch return .failed;
    defer a.free(ms_path);
    const ms_resp = bc.call(router, leader_url, ms_path, .GET, "", &.{}) catch return .failed;
    defer a.free(ms_resp.body);
    if (ms_resp.status != 200) return .failed;
    var parsed = std.json.parseFromSlice(MemberStatusJson, a, ms_resp.body, .{ .ignore_unknown_fields = true }) catch return .failed;
    defer parsed.deinit();
    const ms = parsed.value;

    const is_voter = idIn(ms.voters, node_id);
    const is_learner = idIn(ms.learners, node_id);
    var voter_recent_active = false;
    if (is_voter) {
        for (ms.peers) |p| {
            if (p.id == node_id) {
                voter_recent_active = p.recent_active;
                if (p.recent_active and p.matched + RECONCILE_SLACK >= ms.leader_last) {
                    clearDemoteTimer(router, tenant, node_id); // responsive + caught up → reset grace
                    std.log.debug("reconcile observe {s} node={d}: caught-up voter (matched={d} leader_last={d} active={})", .{ tenant, node_id, p.matched, ms.leader_last, p.recent_active });
                    return .done;
                }
                break;
            }
        }
    }

    // OBSERVE whether the node holds a local instance. CRITICAL: distinguish
    // a CONFIRMED-absent (a clean 404 from a reachable node) from an UNKNOWN
    // (unreachable / errored / 5xx). A configured voter is removed ONLY when
    // its absence is confirmed — never on a probe failure, or a merely
    // rebooting/partitioned healthy voter gets torn out of the config (and a
    // rolling deploy makes voters transiently unreachable by design).
    const host = nodeGroupState(router, node_url, tenant);
    // The reconciler's whole observation for this node, one debug line —
    // the quiet no-action passes are exactly the ones a stuck heal needs
    // explained (is the phantom read as a caught-up voter? host unknown?).
    std.log.debug("reconcile observe {s} node={d}: voter={} learner={} active={} matched≈{} host={s}", .{
        tenant,                    node_id,
        is_voter,                  is_learner,
        voter_recent_active,       blk: {
            for (ms.peers) |p| {
                if (p.id == node_id) break :blk p.matched + RECONCILE_SLACK >= ms.leader_last;
            }
            break :blk false;
        },
        @tagName(host),
    });
    if (host == .unknown) return .failed; // can't observe → never mutate; retry next pass

    // RC-6 hysteresis bookkeeping: keep a demote grace timer ONLY while the
    // node is an actual demote candidate (a hosted voter the leader hasn't
    // heard from). Any other observed state resets it, so a transient
    // inactivity long ago can't carry into a later window and demote instantly.
    if (!(is_voter and host == .hosted and !voter_recent_active))
        clearDemoteTimer(router, tenant, node_id);

    if (is_voter) {
        if (host == .hosted) {
            // DEMOTE only a STUCK voter — one the leader has NOT heard from
            // within an election timeout (recent_active=false under
            // check_quorum: partitioned / dead / campaigning without acking
            // appends — the __admin__ wall). Demoting it stops it disrupting
            // elections while it catches up. A RESPONSIVE voter that is merely
            // BEHIND (recent_active but lagging under write load) is catching
            // up fine via normal replication and is NOT disrupting elections —
            // demoting it just churns healthy voters on a busy group (B1).
            // Leave it; raft replicates the tail.
            if (!voter_recent_active) {
                // RC-6: demote only after SUSTAINED inactivity
                // (REWIND_CP_DEMOTE_GRACE_MS). A single !recent_active reading
                // is a transient restart, not a stuck voter, and tearing out a
                // healthy-but-restarting voter shrinks the voter set →
                // sub-majority commit (RC-1's trigger). Wait out the grace; a
                // genuinely stuck voter stays inactive across it and is demoted.
                if (!demoteGraceElapsed(router, tenant, node_id)) return .done;
                clearDemoteTimer(router, tenant, node_id);
                return if (reconcileConfChange(router, leader_url, tenant, node_id, "demote", raft_addr)) .progressed else .failed;
            }
            return .done; // responsive, just behind — no membership change needed
        }
        // host == .absent: a CONFIRMED phantom voter (configured voter,
        // reachable, NO local instance — wiped or never-formed) is REMOVED,
        // not bootstrapped in place. Bootstrapping a voter relies on the
        // leader's Progress.match (stale-HIGH from before the wipe) lining up
        // with the new baseline EXACTLY — and the leader's heartbeat carries
        // commit = min(match, committed), so if the node is reborn below that
        // match raft fatal!s (commit_to out of range). Removing the node drops
        // the leader's Progress entirely; the next pass re-adds it as a
        // LEARNER with a FRESH match=0, so the leader can never send a commit
        // beyond the node's log. The manager's ConfChangeQuorumGuard refuses
        // any remove that would drop below 2 voters, so this can't lose
        // quorum. Structural fix — the panic becomes impossible, not unlikely.
        return if (reconcileConfChange(router, leader_url, tenant, node_id, "remove", raft_addr)) .progressed else .failed;
    }
    if (is_learner) {
        if (host == .absent)
            return if (bootstrapMember(router, leader_url, node_url, tenant, node_id, true, cluster_id)) .progressed else .failed;
        const last_idx = nodeLastIndex(router, node_url, tenant) orelse return .progressed;
        if (last_idx + RECONCILE_SLACK >= ms.leader_last)
            return if (reconcileConfChange(router, leader_url, tenant, node_id, "promote", raft_addr)) .progressed else .failed;
        return .progressed; // catching up
    }
    // Absent from the config entirely: bootstrap as a learner (only if the
    // node doesn't already host the group) then AddLearner on the leader. The
    // born-learner idles (no campaign) until the leader's AddLearner lets it
    // replicate, then it catches up + is promoted next pass.
    if (host == .absent and !bootstrapMember(router, leader_url, node_url, tenant, node_id, true, cluster_id)) return .failed;
    return if (reconcileConfChange(router, leader_url, tenant, node_id, "add", raft_addr)) .progressed else .failed;
}

const HostState = enum { hosted, absent, unknown };
/// Observe whether `node_url` holds a local group instance for `tenant`:
/// `.hosted` (confstate 200), `.absent` (a clean 404 — reachable, no
/// instance), or `.unknown` (unreachable / error / unexpected status). The
/// hosted-vs-absent-vs-unknown distinction is load-bearing: the reconciler
/// must never treat "can't reach the node" as "the node is empty".
fn nodeGroupState(router: anytype, node_url: []const u8, tenant: []const u8) HostState {
    const a = router.allocator;
    const path = std.fmt.allocPrint(a, "/_system/v2-confstate?tenant={s}", .{tenant}) catch return .unknown;
    defer a.free(path);
    const resp = bc.call(router, node_url, path, .GET, "", &.{}) catch return .unknown;
    defer a.free(resp.body);
    return switch (resp.status) {
        200 => .hosted,
        404 => .absent,
        else => .unknown,
    };
}

/// `node_url`'s own raft LOG last index for `tenant` (the learner→promote
/// catch-up signal), or null. Read from the NON-leader-gated `v2-last-index`
/// (a learner is never the leader, so the leader-gated `v2-applied-baseline`
/// would 421). This is the raft log's `last_index()` — entries RECEIVED into
/// the log, which is the right promote gate: it is compared against the
/// leader's own `leader_last` (also `last_index()`), so like is compared with
/// like, and a node whose LOG has caught up is a valid voter (raft votes on
/// log position, not apply). An out-of-band baseline (`apply_local_snapshot`)
/// advances `last_index` directly, unlike the commit-seq atomic or the
/// bundle-seeded store watermark, so a quiescent caught-up learner still trips
/// the gate.
fn nodeLastIndex(router: anytype, node_url: []const u8, tenant: []const u8) ?u64 {
    const a = router.allocator;
    const path = std.fmt.allocPrint(a, "/_system/v2-last-index?tenant={s}", .{tenant}) catch return null;
    defer a.free(path);
    const resp = bc.call(router, node_url, path, .GET, "", &.{}) catch return null;
    defer a.free(resp.body);
    if (resp.status != 200) return null;
    var p = std.json.parseFromSlice(struct { last_index: u64 = 0 }, a, resp.body, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    return p.value.last_index;
}

/// Propose a conf-change (`add`/`promote`/`demote`/`remove`) on `leader_url`.
/// The joining node's raft transport address (`host:port`) from the
/// directory registry, OWNED (caller frees), or null if unregistered. The
/// genesis §3.3 address the reconciler carries on a conf-change add/promote.
fn raftAddrFor(router: anytype, cluster_id: []const u8, node_id: u64) ?[]u8 {
    const a = router.allocator;
    const packed_bytes = (router.directory.nodeAddrOwned(a, cluster_id, node_id) catch return null) orelse return null;
    defer a.free(packed_bytes);
    const na = Directory.unpackNodeAddr(packed_bytes) orelse return null;
    if (na.raft_addr.len == 0) return null;
    return a.dupe(u8, na.raft_addr) catch null;
}

fn reconcileConfChange(router: anytype, leader_url: []const u8, tenant: []const u8, node_id: u64, op: []const u8, raft_addr: []const u8) bool {
    const a = router.allocator;
    // Carry the address only when known (add/promote of a registered node);
    // a demote/remove or a still-static cluster sends the bare body.
    const body = if (raft_addr.len > 0)
        std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"node_id\":{d},\"op\":\"{s}\",\"raft_addr\":\"{s}\"}}", .{ tenant, node_id, op, raft_addr }) catch return false
    else
        std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"node_id\":{d},\"op\":\"{s}\"}}", .{ tenant, node_id, op }) catch return false;
    defer a.free(body);
    router.confchange_total += 1;
    const resp = bc.call(router, leader_url, "/_system/v2-confchange", .POST, body, &.{}) catch {
        router.confchange_failed += 1;
        return false;
    };
    defer a.free(resp.body);
    if (resp.status != 204) {
        router.confchange_failed += 1;
        std.log.warn("rewind-cp: reconcile confchange {s} node={d} {s} → {d}", .{ op, node_id, tenant, resp.status });
        return false;
    }
    std.log.info("rewind-cp: reconcile confchange {s} node={d} on {s}", .{ op, node_id, tenant });
    return true;
}

/// Out-of-band bootstrap of `tenant`'s group onto `node_url`: pull the
/// leader's baseline {index,term} + snapshot bundle, attach (create group +
/// load) on the node, then install the data-free raft baseline so the leader
/// replicates the tail.
/// Build the genesis §4d attach-carry header — `id@raft_addr,…` for every
/// REGISTERED cluster node EXCEPT `skip_id` (the joiner itself) — so a
/// genesis-booted joiner learns the existing members' transport addresses and
/// can ACK the leader's appends. Owned; null/empty when nothing is registered
/// (a static-`REWIND_PEERS` cluster), in which case the header is omitted.
fn peerAddrsHeader(router: anytype, cluster_id: []const u8, skip_id: u64) ?[]u8 {
    const a = router.allocator;
    const entries = router.directory.listClusterNodeAddrs(a, cluster_id) catch return null;
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    for (entries) |e| {
        if (e.id == skip_id) continue;
        const na = Directory.unpackNodeAddr(e.bytes) orelse continue;
        if (na.raft_addr.len == 0) continue;
        if (out.items.len != 0) out.append(a, ',') catch return null;
        out.writer(a).print("{d}@{s}", .{ e.id, na.raft_addr }) catch return null;
    }
    if (out.items.len == 0) return null;
    return out.toOwnedSlice(a) catch null;
}

fn bootstrapMember(router: anytype, leader_url: []const u8, node_url: []const u8, tenant: []const u8, node_id: u64, as_learner: bool, cluster_id: []const u8) bool {
    const a = router.allocator;
    const bpath = std.fmt.allocPrint(a, "/_system/v2-applied-baseline?tenant={s}", .{tenant}) catch return false;
    defer a.free(bpath);
    const bresp = bc.call(router, leader_url, bpath, .GET, "", &.{}) catch return false;
    defer a.free(bresp.body);
    if (bresp.status != 200) return false;
    // One decode pair (`rove-wire`): every field is REQUIRED, so a field
    // the leader stops sending is a loud parse failure here, not a zero
    // that silently mis-births the joiner. The incarnation (#357) rides
    // the SAME reply as the membership it must agree with — a bootstrap
    // that omitted it once opened a legacy name-keyed store on the joining
    // node: the node caught up on the raft log, was promoted, and served
    // an empty tenant.
    var bp = wire.parseAppliedBaseline(a, bresp.body) catch |err| {
        std.log.warn("rewind-cp: bootstrap {s} onto {s}: v2-applied-baseline reply did not parse: {s}", .{ tenant, node_url, @errorName(err) });
        return false;
    };
    defer bp.deinit();

    // The leader's ConfState must be non-empty for a live group. An EMPTY
    // voter set means the leader's group is mid-birth (ConfState not yet
    // committed/applied) — bootstrapping a joiner from it would send an empty
    // `X-Rewind-Voters`, and the joiner would fall back to `{router}` (a rogue
    // sole-router group). Refuse + retry next pass rather than birth a split.
    if (bp.value.voters.len == 0) {
        std.log.warn("rewind-cp: bootstrap {s} onto {s}: leader baseline has EMPTY voters (index={d} term={d} epoch={d}); retrying", .{ tenant, node_url, bp.value.index, bp.value.term, bp.value.epoch });
        return false;
    }

    const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch return false;
    defer a.free(tbody);
    const snap = bc.call(router, leader_url, "/_system/v2-snapshot", .POST, tbody, &.{}) catch return false;
    defer a.free(snap.body);
    if (snap.status != 200) return false;

    // Membership SSOT, the AUGMENTED-ConfState approach: the
    // baseline carries the leader's CURRENT ConfState PLUS this node as a
    // learner, so the joiner learns its membership from the snapshot
    // (raft.rs:2629) AND satisfies the recipient-must-be-in-the-ConfState rule
    // (raft.rs:2581) WITHOUT requiring the leader's AddLearner to commit first.
    // Crucially this keeps the panic-safe bootstrap-THEN-add ORDER: the leader
    // does not track/commit-to this node until the AddLearner that FOLLOWS this
    // bootstrap, so it can never send a commit past the node's just-installed
    // baseline (the `to_commit out of range` abort the add-FIRST reorder hit).
    // `add_self` augments only when the leader's view doesn't already list the
    // node (the absent-from-config first touch); when it is already a learner
    // (re-bootstrap) the set is the leader's as-is.
    const add_self = !idIn(bp.value.voters, node_id) and !idIn(bp.value.learners, node_id);
    var learners_buf: [wire.MAX_MEMBER_IDS + 1]u64 = undefined;
    if (bp.value.learners.len > wire.MAX_MEMBER_IDS) return false;
    @memcpy(learners_buf[0..bp.value.learners.len], bp.value.learners);
    var learners_len = bp.value.learners.len;
    if (add_self) {
        learners_buf[learners_len] = node_id;
        learners_len += 1;
    }

    // Genesis §4d (attach-carry): the existing members' raft addresses, so a
    // genesis joiner can ACK the leader. Null on a static cluster → header
    // omitted. Lives until the call below.
    const peer_addrs = peerAddrsHeader(router, cluster_id, node_id);
    defer if (peer_addrs) |pa| a.free(pa);

    // Attach AND install the baseline atomically (the wire envelope's
    // baseline fields → createGroupAtBaseline on the worker). A separate
    // v2-apply-snapshot POST would leave a window where the freshly-attached
    // empty group (last_index 0) is reachable; a leader heartbeat carrying
    // commit > 0 arriving in that window crashes raft (commit_to out of
    // range). One atomic op closes it. The store bundle (snap.body) is
    // loaded by attach before the group is created, so the baseline's data
    // is already present. The epoch is the LEADER's, not a hard-coded 1, or
    // its epoch-stamped messages are fenced out and the join stalls (the
    // genesis `__admin__` group is epoch 0; a moved tenant is >1).
    // `join_as_learner` seeds the pre-baseline born state — a learner
    // doesn't campaign, so it follows the leader instead of deadlocking a
    // high-term group; the baseline ConfState is authoritative after.
    var enc = wire.encodeAttach(a, .{
        .tenant = tenant,
        .incarnation = bp.value.incarnation,
        .baseline = .{ .index = bp.value.index, .term = bp.value.term },
        .epoch = bp.value.epoch,
        .join_as_learner = as_learner,
        .voters = bp.value.voters,
        .learners = learners_buf[0..learners_len],
        .peer_addrs = peer_addrs,
    }) catch return false;
    defer enc.deinit();
    const ar = bc.call(router, node_url, "/_system/v2-attach", .POST, snap.body, enc.headers) catch return false;
    defer a.free(ar.body);
    if (ar.status != 204) return false;
    std.log.info("rewind-cp: reconcile bootstrapped {s} onto {s} (atomic baseline {d}/{d} epoch {d}, learner={}, conf_state voters={any} learners={any})", .{ tenant, node_url, bp.value.index, bp.value.term, bp.value.epoch, as_learner, bp.value.voters, learners_buf[0..learners_len] });
    return true;
}

// ── RC-6 demote hysteresis ───────────────────────────────────────────────────

test "RC-6: demote needs sustained inactivity — a recovery before the grace resets it" {
    const a = std.testing.allocator;
    // Only the demote-timer fields are exercised by demoteGraceElapsed /
    // clearDemoteTimer; a minimal struct stands in for the full Router (the
    // free fns take `router: anytype`, so structural access is all they need).
    var r = struct {
        allocator: std.mem.Allocator,
        demote_inactive_since: std.StringHashMapUnmanaged(i128),
        demote_grace_ns: i128,
    }{ .allocator = a, .demote_inactive_since = .empty, .demote_grace_ns = 0 };
    defer {
        var it = r.demote_inactive_since.iterator();
        while (it.next()) |e| a.free(e.key_ptr.*);
        r.demote_inactive_since.deinit(a);
    }

    // grace 0: the SECOND consecutive inactive observation is already past the
    // window. Even so, a demote NEVER fires on the FIRST observation — a single
    // !recent_active reading is always treated as a transient.
    r.demote_grace_ns = 0;

    // SUSTAINED candidate (the genuinely-stuck voter): obs #1 starts the timer
    // (no demote), obs #2 is past the (zero) grace → demote. This proves the
    // mechanism still demotes a real stuck voter.
    try std.testing.expect(!demoteGraceElapsed(&r, "stuck", 2)); // obs #1 — never on first sight
    try std.testing.expect(demoteGraceElapsed(&r, "stuck", 2)); // obs #2 — sustained → demote

    // TRANSIENT-THEN-RECOVER (the rolling-restart hazard): SAME grace (0), SAME
    // two inactive observations — but the voter RECOVERS (timer cleared) in
    // between, so the post-recovery observation is a fresh "first" and must NOT
    // demote. The recovery is the only difference from the sustained case above,
    // and it flips the outcome demote → no-demote.
    try std.testing.expect(!demoteGraceElapsed(&r, "flap", 3)); // obs #1 inactive (transient)
    clearDemoteTimer(&r, "flap", 3); //                            recovered: recent_active again
    try std.testing.expect(!demoteGraceElapsed(&r, "flap", 3)); // obs after recovery — NOT demoted

    // Distinct (tenant,node) keys never share a window.
    try std.testing.expect(!demoteGraceElapsed(&r, "flap", 4)); // different node → own fresh timer
    try std.testing.expect(!demoteGraceElapsed(&r, "other", 3)); // different tenant → own fresh timer

    // A real (non-zero) grace never demotes within the window, across repeated
    // observations — a voter inactive for < grace is left a voter.
    r.demote_grace_ns = 60 * std.time.ns_per_s;
    try std.testing.expect(!demoteGraceElapsed(&r, "slow", 5));
    try std.testing.expect(!demoteGraceElapsed(&r, "slow", 5)); // still within 60s → no demote
}
