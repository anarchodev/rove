// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! V2 — the cluster-internal tenant-MOVE surface.
//!
//! The data-plane half of moving a tenant from one cluster to another; the CP
//! (`rewind-cp`) orchestrates, calling these in sequence and flipping the
//! routing directory at the commit point. Each endpoint runs on the rove-js
//! worker, so it has the worker's per-tenant `cluster.kv` stores
//! (`worker.node.tenant`) and the V2 per-tenant raft bridge (`worker.raft`).
//!
//! The move is ZERO-DOWNTIME (the source serves throughout) — there is a
//! single move; no brief-pause quiesce + bundle-dump variant.
//!
//!   v2-kv       — seed (PUT) / read (GET) a tenant store through the real
//!                 propose→commit path. The move smoke's write + read-back.
//!   v2-attach   — stand up a fresh group at the migration epoch (destination);
//!                 the snapshot data arrives separately via the streamed merge.
//!   v2-snapshot-stream?mode=merge — the streamed insert-if-absent snapshot load
//!                 (dest); pushed by the source's `v2-snapshot-push`.
//!   v2-forward-* — open/close the source→dest live-write forward stream.
//!   v2-evict    — destroy the source raft group + drop the instance once the
//!                 directory has flipped (source cleanup).
//!
//! ## Auth
//!
//! A single shared `move_secret` (env `REWIND_MOVE_SECRET`), presented as
//! `X-Rewind-Move-Secret`. The front door holds it; the operator root
//! bearer is intentionally NOT accepted (the front door never holds it),
//! and these endpoints carry no CORS — they are machine-to-machine. When
//! the worker has no `move_secret` configured the surface is disabled.
//!
//! ## Why a bounded wait, not the `RaftWait` park
//!
//! The customer hot path parks entities on `raft_pending_response` and
//! releases them when the per-tenant watermark advances (non-blocking).
//! These endpoints are low-rate internal operations, so they instead
//! block the worker briefly on `bridge.committedSeq` — simpler, and the
//! single-node bridge pump (a separate thread) advances the watermark
//! within a pump cycle. The data is already durable in kvexp after the
//! immediate `txn.commit`; the wait only confirms raft replication.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("raft-kv");
const tenant_mod = @import("rove-tenant");
const respb = @import("response_builder.zig");
const raft_propose = @import("raft_propose.zig");
const plan_mod = @import("rove-plan");
const blob = @import("rove-blob");
const curl = blob.curl;
/// The CP↔worker wire contracts — ONE encode/decode pair per envelope
/// (docs/defect-patterns.md class 3). The attach envelope's fields, header
/// names, and absent-vs-malformed semantics all live there.
const wire = @import("rove-wire");

const MOVE_SECRET_HEADER = "x-rewind-move-secret";
const TENANT_HEADER = wire.TENANT;
// Streamed-snapshot baseline, carried in headers so the body is the pure
// pair stream.
const SNAP_INDEX_HEADER = "x-rewind-snapshot-index";
const SNAP_TERM_HEADER = "x-rewind-snapshot-term";
// "replace" (default, catch-up/promote-back) | "merge" (zero-downtime move).
const SNAP_MODE_HEADER = "x-rewind-snapshot-mode";
// v2-snapshot-push: the dest node base URL the source streams to.
const DEST_HEADER = "x-rewind-dest";
const snapshot_sink_mod = @import("snapshot_sink.zig");

/// Constant-time byte-slice equality for secret comparison: the
/// compare time depends only on the (non-secret) length, never on how
/// many leading bytes matched — so a timing signal can't be used to
/// brute-force the secret one byte at a time. Mirrors the root-token
/// check in `rove-tenant`'s `authenticate`.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}


/// Source-side marker key (in the tenant's own `inst.kv`) holding the
/// destination node list — comma-separated base URLs, leader first — while a
/// zero-downtime move's overlap window is open (a single URL is just a
/// one-element list). When present, the source forwards every
/// committed write for this tenant to the destination so it stays caught up while the
/// source keeps serving. Set by `v2-forward-begin`, cleared by
/// `v2-forward-end`. The `_move/` prefix is itself never forwarded (control
/// metadata, not tenant data).
const FORWARD_MARKER = "_move/forward";

/// Entry point from `tryHandleSystem`. Returns true iff `sys_rest` named
/// a `v2-*` move endpoint (and the response was finalized). `path` still
/// carries the query string (the GET reader needs it); `sys_rest` is the
/// path past `/_system/` with the query already stripped.
pub fn tryHandleV2(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    sys_rest: []const u8,
    path: []const u8,
    rh: h2.ReqHeaders,
    body: []const u8,
) !bool {
    if (!std.mem.startsWith(u8, sys_rest, "v2-")) return false;

    // Auth on the dedicated move secret only (no CORS, no root bearer).
    const secret = worker.move_secret orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 404, "move surface disabled\n", allocator, null, null);
        return true;
    };
    const presented = respb.findHeader(rh, MOVE_SECRET_HEADER) orelse "";
    if (!constantTimeEql(presented, secret)) {
        try respb.setSystemResponse(server, ent, sid, sess, 401, "bad move secret\n", allocator, null, null);
        return true;
    }

    if (std.mem.eql(u8, sys_rest, "v2-kv")) {
        try handleKv(server, allocator, worker, ent, sid, sess, method, path, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-attach")) {
        try handleAttach(server, allocator, worker, ent, sid, sess, method, rh, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-evict")) {
        try handleEvict(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-leader")) {
        try handleLeader(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-apply")) {
        try handleApply(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-forward-begin")) {
        try handleForwardBegin(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-forward-end")) {
        try handleForwardEnd(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-snapshot")) {
        try handleSnapshot(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-snapshot-push")) {
        try armSnapshotPush(server, allocator, worker, ent, sid, sess, method, rh);
    } else if (std.mem.eql(u8, sys_rest, "v2-plan")) {
        try handlePlan(server, allocator, worker, ent, sid, sess, method, path, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-suspend")) {
        try handleSuspend(server, allocator, worker, ent, sid, sess, method, path, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-domain")) {
        try handleDomain(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-confchange")) {
        try handleConfChange(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-confstate")) {
        try handleConfState(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-member-status")) {
        try handleMemberStatus(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-applied-baseline")) {
        try handleAppliedBaseline(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-last-index")) {
        try handleLastIndex(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-raft-state")) {
        try handleRaftState(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-log-entry")) {
        try handleLogEntry(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-transfer-leadership")) {
        try handleTransferLeadership(server, allocator, worker, ent, sid, sess, method, path);
    } else if (std.mem.eql(u8, sys_rest, "v2-load-replace")) {
        try handleLoadReplace(server, allocator, worker, ent, sid, sess, method, rh, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-apply-snapshot")) {
        try handleApplySnapshot(server, allocator, worker, ent, sid, sess, method, body);
    } else {
        try respb.setSystemResponse(server, ent, sid, sess, 404, "unknown v2 move endpoint\n", allocator, null, null);
    }
    return true;
}

// ── v2-kv: seed (PUT) / read (GET) a tenant store ────────────────────

fn handleKv(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    if (std.mem.eql(u8, method, "GET")) {
        const tenant = queryParam(path, "tenant") orelse
            return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
        const key = queryParam(path, "key") orelse
            return reply(server, allocator, ent, sid, sess, 400, "missing ?key\n");
        const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
            return reply(server, allocator, ent, sid, sess, 404, "unknown tenant\n");
        // A read means the tenant is in use: nudge its raft group awake. The
        // read itself is served locally (no leader needed), but if the group
        // has hibernated and its leader died, nothing else would re-tick it —
        // so a survivor that only ever sees reads would never re-elect. Wake +
        // the pump's leaderless escalation recover it. No-op when the group
        // isn't on this node or is already active.
        if (worker.raft.gidForTenant(tenant)) |gid| worker.raft.requestWake(gid);
        const val = inst.kv.get(key) catch |err| switch (err) {
            error.NotFound => return reply(server, allocator, ent, sid, sess, 404, "no such key\n"),
            else => return reply(server, allocator, ent, sid, sess, 500, "kv get failed\n"),
        };
        // val is owned — hand it to the registry-freed owned responder.
        try respb.setSystemResponseOwned(server, ent, sid, sess, 200, val, allocator, null, "text/plain");
        return;
    }
    if (!std.mem.eql(u8, method, "PUT") and !std.mem.eql(u8, method, "POST")) {
        return reply(server, allocator, ent, sid, sess, 405, "GET to read, PUT to write\n");
    }

    var parsed = std.json.parseFromSlice(struct {
        tenant: []const u8,
        key: []const u8,
        value: []const u8,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\",\"key\",\"value\"}\n");
    defer parsed.deinit();
    const tenant = parsed.value.tenant;
    const key = parsed.value.key;
    const value = parsed.value.value;
    if (tenant.len == 0 or key.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "empty tenant/key\n");
    if (std.mem.indexOfScalar(u8, key, 0) != null or std.mem.indexOfScalar(u8, value, 0) != null)
        return reply(server, allocator, ent, sid, sess, 400, "key/value contains NUL\n");

    // Commit through the real leader-gated propose path.
    const rc = commitWrite(worker, allocator, tenant, key, value);
    if (rc == 421) {
        // Not the leader — stamp the believed leader's raft id so the front
        // redirects a non-replayable write straight there (else it bounces
        // 421→503 once its leader hint goes stale). Same header the customer
        // dispatch gate emits.
        const gid = worker.raft.gidForTenant(tenant) orelse 0;
        const leader_id = if (gid != 0) worker.raft.leaderOf(gid) else 0;
        return respb.setNotLeaderResponse(server, ent, sid, sess, allocator, "not leader for this tenant; retry against the cluster leader\n", leader_id);
    }
    if (rc != 0) return reply(server, allocator, ent, sid, sess, rc, "write failed\n");

    // Zero-downtime overlap: if a move is forwarding this
    // tenant, dual-write the committed write to the destination so it stays
    // caught up while we keep serving. A forward failure surfaces as 502 —
    // the (idempotent) write is durable locally, so the caller retries and
    // re-forwards, preserving "acknowledged source write ⇒ on the dest."
    if (forwardTargetFor(worker, tenant)) |dest| {
        defer allocator.free(dest);
        const secret = worker.move_secret orelse "";
        forwardWrite(allocator, secret, dest, tenant, key, value) catch |err| {
            std.log.warn("v2 forward {s} → {s} failed: {s}", .{ tenant, dest, @errorName(err) });
            return reply(server, allocator, ent, sid, sess, 502, "forward to move destination failed\n");
        };
    }

    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── shared write path (v2-kv PUT + v2-apply) ─────────────────────────

/// Commit a single key/value through the leader-gated propose path: an
/// immediate kvexp `TrackedTxn` commit on `inst.kv` followed by a raft
/// propose awaited to quorum. Returns 0 on success, else the HTTP status to
/// reply with. Shared by `v2-kv` (a new source write) and `v2-apply` (a
/// write forwarded from a move source) — both land a write through the same
/// durable path; only `v2-kv` then forwards (`v2-apply` is the receiving
/// end, so it must NOT re-forward — no loops).
fn commitWrite(worker: anytype, allocator: std.mem.Allocator, tenant: []const u8, key: []const u8, value: []const u8) u16 {
    // Leader gate: only the group leader may take the
    // write. A follower would commit to its own `inst.kv` speculatively then
    // fault the propose with no undo (this immediate-commit path, unlike the
    // parked customer path) — diverging it. Reject fast with 421 (the
    // not-leader / nothing-executed status the front door + serve-or-forward
    // retry on) so the caller re-aims at the leader. Registering first is
    // idempotent + makes
    // `isLeaderOf` resolvable on a single node (the sole voter leads every
    // group).
    const gid = worker.raft.registerTenant(tenant) catch return 500;
    if (!worker.raft.isLeaderOf(gid)) {
        // Wake a hibernated leaderless group toward re-election — a gate-
        // rejected write never reaches the propose that would bump it awake.
        worker.raft.requestWake(gid);
        return 421;
    }

    const inst = ensureInstance(worker, tenant) catch return 500;

    var txn = inst.kv.beginTrackedImmediate() catch return 500;
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    // `Conflict` is single-writer CONTENTION, not a failure: the store's lease
    // is held by another dispatch right now (`kvstore.ensureOpen` — the same
    // condition the dispatcher answers by skipping the tick and re-anchoring).
    // It clears on its own, so it has to reach the caller as a RETRYABLE 503;
    // collapsing it into 500 told every caller "permanent, do not retry".
    //
    // That mattered: seeding `__admin__`'s kv right after a deploy contends
    // with the deployment-load dispatch, so `POST /_system/v2-kv` returned
    // `500 write failed` for ~40% of runs. Callers that discard the status then
    // continued against a key that was never written (rove#438).
    txn.put(key, value) catch |err| {
        txn.rollback() catch {};
        return if (err == error.Conflict) 503 else 500;
    };
    ws.addPut(key, value) catch {
        txn.rollback() catch {};
        return 500;
    };
    txn.commit() catch |err| return if (err == error.Conflict) 503 else 500;

    const proposed = raft_propose.proposeWriteSet(worker, &ws, tenant, "") catch return 503;
    // The txn committed BEFORE the propose (immediate-commit path): its
    // writes are already fold-visible, so release the durabilize floor
    // the bridge would otherwise hold for this skipped own-propose. Safe
    // to ack pre-commit — the bridge keeps an acked high-water and never
    // tracks an already-acked seq.
    worker.raft.noteWorkerCommitted(proposed.group_id, proposed.seq);
    if (!awaitCommit(worker, proposed.group_id, proposed.seq)) return 504;
    return 0;
}

// ── v2-domain: set a `__root__/domain/{host}` → tenant alias ──────────
//
// The CP calls this (move-secret S2S) after recording `host → tenant` in its
// directory, so a worker on the owning cluster can resolve a CUSTOM host →
// instance locally (`tenant.resolveDomain`). The CP owns host→tenant
// end-to-end and propagates the worker alias (docs/architecture/auth-consolidation.md
// B3), so `host add` is a single CP call and there's no second operator
// secret. The alias is a `__root__` write — leader-gated, replicated as a
// type-2 root_writeset (followers apply it).
fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    for (host) |b| {
        const ok = (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or
            b == '.' or b == '-';
        if (!ok) return false;
    }
    return true;
}

fn commitRootDomain(worker: anytype, allocator: std.mem.Allocator, host: []const u8, tenant: []const u8) u16 {
    // Leader gate (same convention as commitWrite): only the group leader may
    // take the immediate-commit + propose; a follower would speculatively
    // commit then fault the propose with no undo. 421 → the CP re-aims.
    const gid = worker.raft.registerTenant(tenant_mod.ADMIN_INSTANCE_ID) catch return 500;
    if (!worker.raft.isLeaderOf(gid)) {
        // Wake a hibernated leaderless group toward re-election — a gate-
        // rejected write never reaches the propose that would bump it awake.
        worker.raft.requestWake(gid);
        return 421;
    }

    const key = std.fmt.allocPrint(allocator, "domain/{s}", .{host}) catch return 500;
    defer allocator.free(key);

    var txn = worker.node.tenant.root.beginTrackedImmediate() catch return 500;
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    txn.put(key, tenant) catch {
        txn.rollback() catch {};
        return 500;
    };
    ws.addPut(key, tenant) catch {
        txn.rollback() catch {};
        return 500;
    };
    txn.commit() catch return 500;

    const proposed = raft_propose.proposeRoot(worker, tenant_mod.ADMIN_INSTANCE_ID, &ws) catch return 503;
    worker.raft.noteWorkerCommitted(proposed.group_id, proposed.seq);
    if (!awaitCommit(worker, proposed.group_id, proposed.seq)) return 504;
    return 0;
}

fn handleDomain(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const Body = struct { host: []const u8, tenant: []const u8 };
    var parsed = std.json.parseFromSlice(Body, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"host\",\"tenant\"}\n");
    defer parsed.deinit();
    if (!validHost(parsed.value.host) or parsed.value.tenant.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "host = lowercase fqdn, tenant required\n");
    const status = commitRootDomain(worker, allocator, parsed.value.host, parsed.value.tenant);
    if (status == 0) return reply(server, allocator, ent, sid, sess, 204, "");
    return reply(server, allocator, ent, sid, sess, status, "domain alias write failed\n");
}

// ── v2-attach: load bundle + stand up the group (destination) ─────────

/// Adapts the h2 request-header lookup to `wire.decodeAttach`'s
/// `get(name) ?value` shape.
const HeaderGetter = struct {
    rh: h2.ReqHeaders,
    pub fn get(self: HeaderGetter, name: []const u8) ?[]const u8 {
        return respb.findHeader(self.rh, name);
    }
};

fn handleAttach(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    rh: h2.ReqHeaders,
    body: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST"))
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    // ONE decoder for the whole envelope (`rove-wire`): required fields are
    // decode errors, malformed values NEVER collapse to "absent" — a
    // malformed baseline routed into the no-baseline birth path is the exact
    // last_index-0 crash window the atomic baseline attach closes. The
    // incarnation header is REQUIRED (wire spelling `legacy` for a
    // name-keyed tenant): an absent header means the sender bypassed the
    // shared encoder, and defaulting it to legacy is what once re-keyed a
    // backfilled node onto the wrong storage (#357).
    const dec = wire.decodeAttach(HeaderGetter{ .rh = rh }) catch |err|
        return reply(server, allocator, ent, sid, sess, 400, wire.attachDecodeMessage(err));
    const tenant = dec.tenant;

    // Create the instance store, load the bundle into it (if any), then
    // attach the raft group at the migration epoch (source birth 0 + 1) so a
    // fresh index sequence starts and any straggler from the old incarnation
    // is fenced out (moot single-node, load-bearing under the zero-downtime
    // overlap).
    //
    // An EMPTY body is an "empty attach" (the zero-downtime entry): form
    // the group + instance with NO data so the destination is ready to
    // receive the source's live forwards BEFORE its snapshot is shipped — the
    // snapshot then loads insert-if-absent so it never clobbers a forwarded
    // (newer) key. A non-empty body ships a bundle to load here.
    const incarnation = tenant_mod.Incarnation.fromMarker(dec.incarnation);
    const inst = ensureInstanceWithIncarnation(worker, tenant, incarnation) catch
        return reply(server, allocator, ent, sid, sess, 500, "provision failed\n");
    if (body.len > 0) {
        inst.kv.loadTenantBundle(body) catch
            return reply(server, allocator, ent, sid, sess, 400, "bundle load failed\n");
    }

    // The tenant's plan rides the attach handshake (operational state,
    // docs/architecture/control-plane.md): cache the resolved limits on its slot so enforcement is local
    // from the first post-move request. Non-fatal — a bad/absent plan leaves
    // the tenant on the free tier until a live push corrects it; it must not
    // fail the move.
    if (dec.plan) |plan_blob| {
        applyPlanBlob(worker, allocator, tenant, plan_blob) catch |err|
            std.log.warn("v2-attach: applyPlanBlob({s}) failed: {s}", .{ tenant, @errorName(err) });
    }

    // Genesis §4d (attach-carry): learn the existing members' raft addresses
    // BEFORE the group is created, so the moment the leader's first append lands
    // this node can dial back to ACK it. A genesis joiner booted with an empty
    // peer registry knows no addresses otherwise; a static cluster carries no
    // header and already knows every peer (no-op). Best-effort per entry — a
    // malformed token is skipped, never fatal (the conf-change still drives the
    // join; a missing address just delays this node's reachability one pass).
    if (dec.peer_addrs) |pa| {
        var it = std.mem.tokenizeScalar(u8, pa, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " ");
            const at = std.mem.indexOfScalar(u8, t, '@') orelse continue;
            const id = std.fmt.parseInt(u64, t[0..at], 10) catch continue;
            const addr = t[at + 1 ..];
            if (id == 0 or addr.len == 0) continue;
            worker.raft.learnPeerAddr(id, addr) catch |err|
                std.log.warn("v2-attach: learnPeerAddr({d}, {s}) failed: {s}", .{ id, addr, @errorName(err) });
        }
    }

    const gid = worker.raft.registerTenant(tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "register failed\n");
    // A reconciler bootstrap supplies the leader's baseline {index, term} so
    // the group is created already at that baseline (atomic) rather than at
    // an empty last_index 0 — eliminating the attach→apply-snapshot window
    // where a leader heartbeat carrying commit > 0 would crash the fresh
    // group. Plain attach (moves, empty-attach) carries no baseline and
    // creates at epoch. The epoch is the leader's actual one (default 1):
    // joining a non-epoch-1 group (genesis `__admin__` at epoch 0, a moved
    // tenant at >1) at the wrong epoch gets the leader's messages FENCED and
    // the join silently stalls. `join_as_learner`: the reconciler adds a
    // node learner-first — a born-voter would campaign past a high-term
    // leader and deadlock.
    //
    // The decoded id lists live in `dec`'s inline buffers on this frame —
    // `createGroupAtBaseline` BLOCKS on the pump ControlCmd, so they outlive
    // the install. Absent lists → null → membership-neutral (baseline) /
    // this node's static `REWIND_VOTERS` (plain birth).
    if (dec.baseline) |b| {
        worker.raft.createGroupAtBaseline(gid, dec.epoch, b.index, b.term, dec.join_as_learner, dec.voters(), dec.learners()) catch |err| switch (err) {
            error.GroupExists => {}, // idempotent re-attach
            error.SelfNotInConfState => return reply(server, allocator, ent, sid, sess, 409, "supplied membership omits this node; add it to the group first\n"),
            else => return reply(server, allocator, ent, sid, sess, 500, "group attach (baseline) failed\n"),
        };
    } else {
        worker.raft.createGroupEpoch(gid, dec.epoch, dec.voters()) catch |err| switch (err) {
            error.GroupExists => {}, // idempotent re-attach
            else => return reply(server, allocator, ent, sid, sess, 500, "group attach failed\n"),
        };
    }
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-evict: destroy the source group + drop the instance ────────────

fn handleEvict(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const tenant = parseTenant(allocator, body) orelse
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\"}\n");
    defer allocator.free(tenant);

    if (worker.raft.gidForTenant(tenant)) |gid| {
        worker.raft.destroyGroup(gid) catch
            return reply(server, allocator, ent, sid, sess, 500, "group destroy failed\n");
    }
    // Drop the cached bundle BEFORE the instance goes: the slot is keyed by
    // tenant name, so a name reused later would otherwise be served the
    // previous tenant's code from memory, never reaching storage (#357).
    worker.node.deploy.evictTenant(tenant);
    worker.node.tenant.deleteInstance(tenant) catch |err|
        std.log.warn("v2-evict: deleteInstance({s}) failed: {s}", .{ tenant, @errorName(err) });
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-suspend: live suspension delivery + diagnostic read ───────────

/// `POST /_system/v2-suspend {tenant, suspended}` — install a tenant's
/// suspension state on its hot-path slot (the CP's live push on
/// `/_control/suspend`/`unsuspend`, re-pushed each reconcile pass so a
/// worker restart re-learns it). 204 on success; 409 if the tenant is not
/// active on this cluster. `GET /_system/v2-suspend?tenant=T` reads it
/// back (diagnostic / smoke; kept in tree — diagnostic state is not
/// temporary).
fn handleSuspend(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    if (std.mem.eql(u8, method, "GET")) {
        const tenant = queryParam(path, "tenant") orelse
            return reply(server, allocator, ent, sid, sess, 400, "missing tenant\n");
        const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
            return reply(server, allocator, ent, sid, sess, 404, "unknown tenant\n");
        const slot = worker.node.deploy.getOrOpenTenantSlot(inst) catch
            return reply(server, allocator, ent, sid, sess, 500, "slot open failed\n");
        const json = std.fmt.allocPrint(allocator, "{{\"suspended\":{}}}", .{
            slot.suspended.load(.acquire),
        }) catch return reply(server, allocator, ent, sid, sess, 500, "encode failed\n");
        try respb.setSystemResponseOwned(server, ent, sid, sess, 200, json, allocator, null, "application/json");
        return;
    }
    if (!std.mem.eql(u8, method, "POST"))
        return reply(server, allocator, ent, sid, sess, 405, "GET or POST only\n");

    var parsed = std.json.parseFromSlice(struct {
        tenant: []const u8,
        suspended: bool,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\",\"suspended\"}\n");
    defer parsed.deinit();
    if (parsed.value.tenant.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "empty tenant\n");

    const inst = (worker.node.tenant.getInstance(parsed.value.tenant) catch null) orelse
        return reply(server, allocator, ent, sid, sess, 409, "tenant not active on this cluster\n");
    const slot = worker.node.deploy.getOrOpenTenantSlot(inst) catch
        return reply(server, allocator, ent, sid, sess, 500, "slot open failed\n");
    slot.suspended.store(parsed.value.suspended, .release);
    std.log.warn("v2-suspend: tenant={s} suspended={}", .{ parsed.value.tenant, parsed.value.suspended });
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-plan: live plan delivery + diagnostic read (destination) ──────

/// `POST /_system/v2-plan {tenant, plan}` — install a tenant's resolved plan
/// limits on its hot-path slot (the CP's single-target push on a live tier
/// change; docs/architecture/control-plane.md "Live tier change"). `plan` is the
/// opaque `{tier, overrides}` blob the CP stores. 204 on success; 409 if the
/// tenant is not active on this cluster (the CP pushes to the serving cluster,
/// so that is a routing bug worth surfacing).
///
/// `GET /_system/v2-plan?tenant=T` — the tenant's RESOLVED effective limits as
/// JSON (+ the plan generation). Diagnostic / smoke read-back: it proves
/// delivery end-to-end (attach handshake or live push) without standing up the
/// full enforcement levers. Kept in tree (diagnostic state is not temporary).
fn handlePlan(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    if (std.mem.eql(u8, method, "GET")) {
        const tenant = queryParam(path, "tenant") orelse
            return reply(server, allocator, ent, sid, sess, 400, "missing tenant\n");
        const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
            return reply(server, allocator, ent, sid, sess, 404, "unknown tenant\n");
        const slot = worker.node.deploy.getOrOpenTenantSlot(inst) catch
            return reply(server, allocator, ent, sid, sess, 500, "slot open failed\n");
        const p = slot.effectivePlan();
        const gen = slot.plan_gen.load(.acquire);
        const json = std.fmt.allocPrint(allocator, "{{\"request_capacity\":{d},\"request_refill_per_sec\":{d},\"outbound_enabled\":{},\"outbound_capacity\":{d},\"outbound_refill_per_sec\":{d},\"max_body_bytes\":{d},\"retention_days\":{d},\"max_kv_bytes\":{d},\"max_stored_bytes\":{d},\"plan_gen\":{d}}}", .{
            p.rate.request_capacity,
            p.rate.request_refill_per_sec,
            // The admission gate, not just the buckets: an operator asking
            // "why is this tenant's outbound refused" reads THIS, and a
            // readback that showed only the rate caps answered a question
            // they were not asking (rove#336).
            p.rate.outbound_enabled,
            p.rate.outbound_capacity,
            p.rate.outbound_refill_per_sec,
            p.max_body_bytes,
            p.retention_days,
            p.max_kv_bytes,
            p.max_stored_bytes,
            gen,
        }) catch return reply(server, allocator, ent, sid, sess, 500, "encode failed\n");
        try respb.setSystemResponseOwned(server, ent, sid, sess, 200, json, allocator, null, "application/json");
        return;
    }
    if (!std.mem.eql(u8, method, "POST"))
        return reply(server, allocator, ent, sid, sess, 405, "GET or POST only\n");

    var parsed = std.json.parseFromSlice(struct {
        tenant: []const u8,
        plan: []const u8,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\",\"plan\"}\n");
    defer parsed.deinit();
    if (parsed.value.tenant.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "empty tenant\n");

    applyPlanBlob(worker, allocator, parsed.value.tenant, parsed.value.plan) catch |err| switch (err) {
        error.UnknownTenant => return reply(server, allocator, ent, sid, sess, 409, "tenant not active on this cluster\n"),
        else => return reply(server, allocator, ent, sid, sess, 500, "plan install failed\n"),
    };
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-snapshot: non-quiescing consistent dump (source) ──────────────

/// `POST /_system/v2-snapshot {tenant}` → the tenant's key-space as a
/// migration bundle, dumped WITHOUT quiescing — the source keeps serving
/// (zero-downtime). The snapshot is just `dumpTenantBundle`'s
/// consistent read view; concurrent writes are NOT in this snapshot but are
/// carried to the destination by the live forward stream (`v2-forward-begin`,
/// started BEFORE this snapshot), and the destination loads this bundle
/// insert-if-absent so a forwarded (newer) key is never clobbered by the
/// (older) snapshot. Leader-gated.
fn handleSnapshot(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const tenant = parseTenant(allocator, body) orelse
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\"}\n");
    defer allocator.free(tenant);

    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 409, "tenant not active on this cluster\n");
    if (!worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 421, "not the leader for this tenant; try another node\n");

    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
        return reply(server, allocator, ent, sid, sess, 404, "unknown tenant\n");
    const bundle = inst.kv.dumpTenantBundle(allocator) catch
        return reply(server, allocator, ent, sid, sess, 500, "snapshot dump failed\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, bundle, allocator, null, "application/octet-stream");
}

// ── v2-leader: per-tenant leadership probe ───────────────────────────

/// `GET /_system/v2-leader?tenant=…` → 200 if this node leads the tenant's
/// raft group, 503 if it is a follower, 404 if the tenant is not active on
/// this node. The move orchestrator polls every destination node after the
/// attach fan-out until one reports 200 — i.e. the freshly formed group has
/// elected — before flipping the directory, so post-move traffic finds a
/// leader immediately instead of cycling 503s through an un-elected group.
fn handleLeader(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    if (worker.raft.isLeaderOf(gid)) {
        try respb.setSystemResponse(server, ent, sid, sess, 200, "leader\n", allocator, null, null);
    } else {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "follower\n", allocator, null, null);
    }
}

// ── v2-apply: receive a write forwarded from a move source (dest) ─────

/// `POST /_system/v2-apply {tenant,key,value}` — the destination end of the
/// zero-downtime overlap. Applies a write the move source
/// forwarded, through the SAME durable leader-gated path as `v2-kv` but
/// WITHOUT re-forwarding (this is the receiving side — re-forwarding would
/// loop). So while a tenant is moving, the dest stays caught up with the
/// source's live writes and the source never stops serving.
fn handleApply(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    var parsed = std.json.parseFromSlice(struct {
        tenant: []const u8,
        key: []const u8,
        value: []const u8,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\",\"key\",\"value\"}\n");
    defer parsed.deinit();
    const t = parsed.value.tenant;
    if (t.len == 0 or parsed.value.key.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "empty tenant/key\n");

    const rc = commitWrite(worker, allocator, t, parsed.value.key, parsed.value.value);
    if (rc != 0) return reply(server, allocator, ent, sid, sess, rc, "apply failed\n");
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-forward-begin / -end: open / close the source overlay (source) ─

/// `POST /_system/v2-forward-begin {tenant,dest}` — open the overlap: record
/// the destination node list (comma-separated base URLs, leader first) in
/// the tenant's `inst.kv` (`_move/forward`) so every subsequent committed
/// write is dual-written to the destination, re-aiming past non-leader
/// nodes (421). The marker rides the replicated write path (so a source
/// leader change carries it). Leader-gated like any source write.
fn handleForwardBegin(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    var parsed = std.json.parseFromSlice(struct {
        tenant: []const u8,
        dest: []const u8,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\",\"dest\"}\n");
    defer parsed.deinit();
    if (parsed.value.tenant.len == 0 or parsed.value.dest.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "empty tenant/dest\n");
    const rc = commitWrite(worker, allocator, parsed.value.tenant, FORWARD_MARKER, parsed.value.dest);
    if (rc != 0) return reply(server, allocator, ent, sid, sess, rc, "forward-begin failed\n");
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

/// `POST /_system/v2-forward-end {tenant}` — close the overlap: clear the
/// `_move/forward` marker (write empty) so the source stops dual-writing.
fn handleForwardEnd(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const tenant = parseTenant(allocator, body) orelse
        return reply(server, allocator, ent, sid, sess, 400, "expected {\"tenant\"}\n");
    defer allocator.free(tenant);
    const rc = commitWrite(worker, allocator, tenant, FORWARD_MARKER, "");
    if (rc != 0) return reply(server, allocator, ent, sid, sess, rc, "forward-end failed\n");
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── forwarding (source side) ─────────────────────────────────────────

/// The destination node list (comma-separated, leader-first) this tenant is
/// forwarding to, or null if no overlap is open. Reads the `_move/forward`
/// marker from `inst.kv`; an absent or empty marker means "not forwarding."
/// Owned dup on success.
fn forwardTargetFor(worker: anytype, tenant: []const u8) ?[]u8 {
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse return null;
    const v = inst.kv.get(FORWARD_MARKER) catch return null; // NotFound → null
    if (v.len == 0) {
        worker.allocator.free(v);
        return null;
    }
    return v; // owned by the caller (kvexp get returns an owned copy)
}

/// Dual-write one committed key/value to the move destination's `v2-apply`.
/// `dests` is the comma-separated, leader-first destination node list the
/// orchestrator wrote at forward-begin. Try each node in order: 204 =
/// forwarded; 421 (that node does not lead the dest group — a dest leader
/// change mid-overlap) or a transport failure = re-aim at the next node;
/// any other status = hard fail (a real rejection, e.g. a secret mismatch —
/// don't mask it by retrying it around the cluster). Errors when no listed
/// node takes the write so the source can surface 502 and the caller retry.
fn forwardWrite(allocator: std.mem.Allocator, secret: []const u8, dests: []const u8, tenant: []const u8, key: []const u8, value: []const u8) !void {
    var it = std.mem.splitScalar(u8, dests, ',');
    while (it.next()) |dest_raw| {
        const dest = std.mem.trim(u8, dest_raw, " ");
        if (dest.len == 0) continue;
        const status = forwardWriteOne(allocator, secret, dest, tenant, key, value) catch continue;
        if (status == 204) return;
        if (status != 421) return error.ForwardRejected;
    }
    return error.NoDestLeader;
}

/// One forward attempt against one dest node (blocking libcurl, like the
/// move surface — this is an internal, low-rate overlay path, not the
/// customer hot path). Returns the HTTP status; errors on transport failure.
fn forwardWriteOne(allocator: std.mem.Allocator, secret: []const u8, dest: []const u8, tenant: []const u8, key: []const u8, value: []const u8) !u16 {
    const url = try std.fmt.allocPrint(allocator, "{s}/_system/v2-apply", .{dest});
    defer allocator.free(url);
    const payload = try std.fmt.allocPrint(allocator, "{{\"tenant\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ tenant, key, value });
    defer allocator.free(payload);

    var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
    defer headers.deinit(allocator);
    // The dest's v2-apply is move-secret gated; forwarding is between
    // clusters that share the secret, so present it (the worker holds it).
    try headers.append(allocator, .{ .name = "X-Rewind-Move-Secret", .value = secret });
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });

    var resp = try curl.cpPost(allocator, url, payload, .{ .headers = headers.items });
    defer resp.deinit(allocator);
    return resp.status;
}

// ── helpers ──────────────────────────────────────────────────────────

/// Resolve a tenant instance, creating it (existence marker + per-tenant
/// `cluster.kv` store) on first sight. Idempotent.
fn ensureInstance(worker: anytype, tenant: []const u8) !*const tenant_mod.Instance {
    return ensureInstanceWithIncarnation(worker, tenant, .legacy);
}

/// `ensureInstance`, binding a first-sight instance to the storage incarnation
/// the CP minted for this tenant lifetime (#357). An instance that already
/// exists keeps the incarnation its data is keyed by — re-attach must not
/// re-key a live tenant.
fn ensureInstanceWithIncarnation(worker: anytype, tenant: []const u8, incarnation: tenant_mod.Incarnation) !*const tenant_mod.Instance {
    if (try worker.node.tenant.getInstance(tenant)) |inst| return inst;
    try worker.node.tenant.createInstanceWithIncarnation(tenant, incarnation);
    return (try worker.node.tenant.getInstance(tenant)) orelse error.ProvisionFailed;
}

/// Resolve a CP plan blob into effective limits and cache them on the tenant's
/// hot-path slot (`TenantSlot.setPlan`, which bumps the plan generation so the
/// rate limiter re-snapshots caps). The blob is opaque `{tier, overrides}`
/// JSON; an empty/malformed blob resolves to the tenant's default tier
/// (`plan.parseBlob` — free for a customer, platform for a reserved id).
/// `error.UnknownTenant` if the tenant has no instance on this cluster.
fn applyPlanBlob(worker: anytype, allocator: std.mem.Allocator, tenant: []const u8, plan_blob: []const u8) !void {
    const inst = (try worker.node.tenant.getInstance(tenant)) orelse return error.UnknownTenant;
    const slot = try worker.node.deploy.getOrOpenTenantSlot(inst);
    try slot.setPlan(plan_mod.parseBlob(allocator, tenant, plan_blob));
}

/// Block (bounded by `commit_wait_timeout_ns`) until the tenant's raft
/// watermark reaches `target_seq`. Fails fast (false) if the bridge
/// faults the seq — leadership lost mid-move; the mover retries.
fn awaitCommit(worker: anytype, gid: u64, target_seq: u64) bool {
    worker.raft.awaitCommit(gid, target_seq, worker.commit_wait_timeout_ns) catch return false;
    return true;
}

/// Parse `{"tenant":"..."}`; returns an owned dup the caller frees, or
/// null on malformed input / empty tenant.
fn parseTenant(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(struct { tenant: []const u8 }, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.tenant.len == 0) return null;
    return allocator.dupe(u8, parsed.value.tenant) catch null;
}

/// Read a single query-string value (`?a=b&c=d`) by key. Values are
/// taken verbatim (the move surface uses simple ASCII ids — no percent-
/// decoding). Returns null if absent.
fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.tokenizeScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

// ── v2-confchange / v2-confstate: manual membership change ──

/// `POST /_system/v2-confchange {tenant, node_id, op}` — operator-triggered
/// membership change on `tenant`'s raft group (leader-gated). `op`:
/// `demote`/`add` → learner (AddLearnerNode), `promote` → voter (AddNode),
/// `remove` → drop. A demote of a far-behind voter takes it out of the
/// voters-only WAL-compaction floor so the log truncates again.
fn handleConfChange(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    var parsed = std.json.parseFromSlice(
        // `raft_addr` (optional `host:port`) is the joining node's transport
        // address, carried so the leader can dial it the moment the add commits
        // (docs/architecture/consensus-and-storage.md "Cluster genesis & membership", peer-address
        // resolution) instead of relying on static
        // config. Absent for a demote/remove or a still-static cluster.
        struct { tenant: []const u8, node_id: u64, op: []const u8, raft_addr: []const u8 = "" },
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return reply(server, allocator, ent, sid, sess, 400, "expected {tenant, node_id, op}\n");
    defer parsed.deinit();
    const v = parsed.value;
    if (v.tenant.len == 0)
        return reply(server, allocator, ent, sid, sess, 400, "empty tenant\n");
    // node id 0 is raft's invalid/sentinel id — reject rather than forward it
    // into proposeConfChange where it would target a nonexistent member.
    if (v.node_id == 0)
        return reply(server, allocator, ent, sid, sess, 400, "node_id must be nonzero\n");
    const cc_type: u8 =
        if (std.mem.eql(u8, v.op, "demote") or std.mem.eql(u8, v.op, "add")) 2 else if (std.mem.eql(u8, v.op, "promote")) 0 else if (std.mem.eql(u8, v.op, "remove")) 1 else return reply(server, allocator, ent, sid, sess, 400, "op must be demote|promote|add|remove\n");
    const gid = worker.raft.gidForTenant(v.tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    if (!worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 421, "not the leader for this tenant; try another node\n");
    // Learn the joining node's address BEFORE proposing, so THIS (leader) node
    // can dial it the moment the add commits. Insert-only + no-op when the
    // registry is disabled or the addr is absent.
    if (v.raft_addr.len > 0)
        worker.raft.learnPeerAddr(v.node_id, v.raft_addr) catch
            return reply(server, allocator, ent, sid, sess, 400, "malformed raft_addr\n");
    // Carry the address as the conf-change CONTEXT, so every OTHER replica learns
    // it via the conf-change observer as the change applies (the apply-side
    // completion of point-to-point addressing: a follower added before this node
    // still learns it). Empty for a demote/remove.
    worker.raft.proposeConfChange(gid, v.node_id, cc_type, v.raft_addr) catch |e| switch (e) {
        error.NotLeader => return reply(server, allocator, ent, sid, sess, 421, "not the leader\n"),
        error.ConfChangeQuorumGuard => return reply(server, allocator, ent, sid, sess, 409, "refused: would leave fewer than 2 voters\n"),
        else => return reply(server, allocator, ent, sid, sess, 500, "conf-change propose failed\n"),
    };
    return reply(server, allocator, ent, sid, sess, 204, "");
}

/// `GET /_system/v2-confstate?tenant=` → `{"voters":[…],"learners":[…]}` for
/// the tenant's group on this node (operator + smoke membership query).
fn handleConfState(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    var voters_buf: [16]u64 = undefined;
    var learners_buf: [16]u64 = undefined;
    const cs = worker.raft.confState(gid, &voters_buf, &learners_buf) orelse
        return reply(server, allocator, ent, sid, sess, 404, "no conf state for this group\n");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    w.writeAll("{\"voters\":[") catch return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    for (cs.voters, 0..) |id, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{d}", .{id}) catch {};
    }
    w.writeAll("],\"learners\":[") catch {};
    for (cs.learners, 0..) |id, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{d}", .{id}) catch {};
    }
    w.writeAll("]}\n") catch {};
    const out = buf.toOwnedSlice(allocator) catch return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, out, allocator, null, "application/json");
}

/// `GET /_system/v2-member-status?tenant=` → the LEADER's per-peer replication
/// view — the membership reconciler's "is node N a caught-up member" signal,
/// which `v2-confstate` alone can't give (a phantom voter shows in `voters`
/// with `matched=0`). Shape:
///   {"leader_last":N,"voters":[…],"learners":[…],
///    "peers":[{"id":I,"matched":M,"recent_active":B}, …]}
/// `peers` is the peer VOTERS (self excluded) with their match index + activity;
/// combined with `voters`/`learners` (the ConfState) the caller derives, per
/// desired node, whether it is a caught-up voter (`matched ≈ leader_last &&
/// recent_active`), a learner, or absent. 409 on a non-leader (only the leader
/// tracks peer progress — query `v2-leader` first); 404 if the group is not on
/// this node.
fn handleMemberStatus(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    var ids: [16]u64 = undefined;
    var matched: [16]u64 = undefined;
    var active: [16]u8 = undefined;
    const vp = worker.raft.voterProgress(gid, &ids, &matched, &active) orelse
        return reply(server, allocator, ent, sid, sess, 409, "not leader; query v2-leader first\n");
    var voters_buf: [16]u64 = undefined;
    var learners_buf: [16]u64 = undefined;
    const cs = worker.raft.confState(gid, &voters_buf, &learners_buf);
    const voters: []const u64 = if (cs) |c| c.voters else &.{};
    const learners: []const u64 = if (cs) |c| c.learners else &.{};

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    w.print("{{\"leader_last\":{d},\"voters\":[", .{vp.leader_last}) catch
        return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    for (voters, 0..) |id, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{d}", .{id}) catch {};
    }
    w.writeAll("],\"learners\":[") catch {};
    for (learners, 0..) |id, i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{d}", .{id}) catch {};
    }
    w.writeAll("],\"peers\":[") catch {};
    for (0..vp.len) |i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{{\"id\":{d},\"matched\":{d},\"recent_active\":{}}}", .{ ids[i], matched[i], active[i] != 0 }) catch {};
    }
    w.writeAll("]}\n") catch {};
    const out = buf.toOwnedSlice(allocator) catch return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, out, allocator, null, "application/json");
}

// ── promote-back: out-of-band rejoin of a below-floor learner ──
//
// A node auto-demoted to a learner that then fell below the WAL-compaction
// floor can't catch up by replication (the leader compacted past it) and rove
// has no in-protocol snapshot transport. It rejoins out-of-band:
//   1. GET  v2-applied-baseline (on the leader)  → {index X, term T}
//   2. GET  v2-snapshot         (on the leader)  → a store bundle (⊇ X)
//   3. POST v2-load-replace     (on the learner) → overwrite-load the bundle
//   4. POST v2-apply-snapshot   (on the learner, {index:X, term:T}) → install a
//      DATA-FREE raft baseline at X, so the leader can replicate the tail (> X)
//   5. POST v2-confchange {op:promote} (on the leader) → back to a voter
// The orchestrator (CP / smoke) sequences these; each endpoint is a passive
// primitive, like the tenant-move surface.

/// `GET /_system/v2-applied-baseline?tenant=` →
/// `{"index":X,"term":T,"epoch":E,"voters":[..],"learners":[..],"incarnation":"…"}`
/// — everything a joining node must be born with, in one read. X
/// is the leader's LIVE applied index (`slot.applied_idx`) and T is the term of
/// the log entry at X (so the learner's baseline matches the leader's log).
/// Leader-gated (only the leader tracks term-by-index meaningfully).
///
/// X is the live applied index, NOT the durabilized store watermark
/// (`lastAppliedRaftIdx`). The watermark lags `applied_idx` by up to one
/// durabilize cycle (DEFAULT_DURABILIZE_NS) and under continuous churn sits BELOW
/// the leader's compaction floor — handing it back as a baseline strands the new
/// member below the leader's first log index (the prod __admin__ wall). The live
/// applied index is always >= that floor (compaction truncates to
/// `min(applied, …)`), so the baseline always points at an entry the leader still
/// holds. The bundle (`v2-snapshot`, read separately) reflects applied at its own
/// — later — instant, so it is a superset of X; the tail above X re-applies
/// idempotently.
fn handleAppliedBaseline(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    if (!worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 421, "not the leader for this tenant; try another node\n");
    // The live applied index (slot.applied_idx). index 0 = genesis (nothing
    // applied yet): logTerm(gid, 0) resolves to the genesis sentinel term 0, so
    // this flows through to a {0,0} baseline = a plain (snapshot-free) born
    // attach, with no special case.
    const index = worker.raft.baselineIndex(gid);
    // A baseline is the pair {index, term-of-the-log-entry-at-index}. logTerm
    // returns null when the leader's own log can't resolve a term for `index` (it
    // is beyond last_index, below the compaction floor, or the store watermark has
    // drifted ahead of the raft log) — there is NO valid baseline to hand out.
    // Handing back {index, term:0} would feed an OUT-OF-BAND snapshot a bogus term,
    // which raft-rs's `restore` treats as a same-term match and fast-forwards
    // `commit_to(index)` past the follower's empty log → `fatal!`. Refuse instead:
    // the reconciler retries once the leader's log covers its watermark. null is
    // DISTINCT from a genuine term 0 (the genesis index) — the error channel keeps
    // "no term" separate from a fake 0 — so the abort only ever fires on a real
    // invariant break.
    const term = worker.raft.logTerm(gid, index) orelse
        return reply(server, allocator, ent, sid, sess, 409, "no term-valid baseline (leader log does not cover the applied index)\n");
    // The leader's migration epoch for the group. A joining node MUST birth its
    // local group at this epoch (passed back via `X-Rewind-Epoch` on the attach),
    // or the leader's messages — stamped with this epoch — are fenced out at the
    // receiver and the join silently stalls. Genesis groups (e.g. `__admin__`,
    // born via `ensureGroup`) are epoch 0; provisioned tenants are epoch 1; a
    // moved tenant is higher.
    const epoch = worker.raft.groupEpoch(gid);
    // Membership SSOT: return the leader's ConfState in the SAME
    // response, so a joiner reads {index, term, epoch, conf_state} in ONE call and
    // installs a baseline carrying the real membership — instead of a second
    // `v2-confstate` call that could race a conf-change (the TOCTOU the
    // raft-rs/TiKV cross-check flagged). The membership a baseline carries must
    // match the membership at `index`; one read keeps them consistent.
    var voters_buf: [16]u64 = undefined;
    var learners_buf: [16]u64 = undefined;
    const cs = worker.raft.confState(gid, &voters_buf, &learners_buf) orelse
        return reply(server, allocator, ent, sid, sess, 500, "conf_state unavailable\n");
    // The tenant's storage incarnation, for the same reason the epoch is here:
    // a joiner must be born with it (passed back via `X-Rewind-Incarnation` on
    // the attach) or it opens a DIFFERENT store from the rest of the group and
    // applies replicated writes somewhere nothing reads (#357). Empty for a
    // tenant provisioned before incarnations existed — legacy name-keyed, and
    // the joiner must stay there too.
    const st = worker.node.tenant.storageOf(allocator, tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "incarnation unavailable\n");
    defer st.incarnation.free(allocator);
    // ONE encoder (`rove-wire.AppliedBaseline`): the reconciler parses the
    // same struct with every field required, so this reply and its consumer
    // cannot drift field-by-field.
    const out = wire.encodeAppliedBaseline(allocator, .{
        .index = index,
        .term = term,
        .epoch = epoch,
        .voters = cs.voters,
        .learners = cs.learners,
        .incarnation = st.incarnation.marker(),
    }) catch return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, out, allocator, null, "application/json");
}

/// `GET /_system/v2-last-index?tenant=` → `{"last_index":N}` — this node's local
/// raft last log index for the group. UNLIKE `v2-applied-baseline` this is NOT
/// leader-gated, so a LEARNER (never the leader) can report its own catch-up. The
/// reconciler gates learner→promote on it vs the leader's `leader_last`. Why
/// last_index (not the commit-seq atomic or the store watermark): an out-of-band
/// baseline (`apply_local_snapshot`) advances `last_index` directly, so a born-
/// learner is "caught up" the moment its baseline lands — whereas commit-seq only
/// moves on freshly committed entries (a quiescent learner would never trip it),
/// and the store watermark is pre-seeded by the bundle (high before any replay).
fn handleLastIndex(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    const out = std.fmt.allocPrint(allocator, "{{\"last_index\":{d}}}\n", .{worker.raft.lastIndex(gid)}) catch
        return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, out, allocator, null, "application/json");
}

/// `POST /_system/v2-transfer-leadership?tenant=` → force a leadership handoff of
/// this tenant's group to its most caught-up follower (no-op if this node is not
/// the leader). Test/diagnostic only — drives the churn soak's rapid leadership
/// flips under in-flight writes. 204 always (handoff is best-effort, async).
fn handleTransferLeadership(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST") and !std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "POST/GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    _ = worker.raft.transferLeadership(gid);
    return reply(server, allocator, ent, sid, sess, 204, "");
}

/// `GET /_system/v2-raft-state?tenant=` → this node's per-group raft state, for
/// diagnostics (the RC-1 / `__auth__` fork hunt). NOT leader-gated — every node
/// reports its OWN `{last_index, applied_idx, durabilized_idx, term_at_last,
/// epoch, leader}`. The `applied_idx − durabilized_idx` gap is the worker-overlay
/// fold lag (the RC-1 over-claim window); comparing `applied_idx` + the served
/// store across nodes exposes an apply-side fork that `last_index` alone hides.
fn handleRaftState(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    const last = worker.raft.lastIndex(gid);
    const term = worker.raft.logTerm(gid, last) orelse 0;
    const out = std.fmt.allocPrint(
        allocator,
        "{{\"last_index\":{d},\"applied_idx\":{d},\"durabilized_idx\":{d},\"term_at_last\":{d},\"epoch\":{d},\"leader\":{}}}\n",
        .{ last, worker.raft.appliedRaw(gid), worker.raft.durabilizedRaw(gid), term, worker.raft.groupEpoch(gid), worker.raft.isLeaderOf(gid) },
    ) catch return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, out, allocator, null, "application/json");
}

/// `GET /_system/v2-log-entry?tenant=&index=` → this node's raft LOG entry at
/// `index` as `{index, term, len, data_hex}` — hex of the raw entry bytes (the
/// origin-frame `[magic|origin|seq]` + envelope `[type|id_len|id|payload]` +
/// writeset). Read-only, NOT leader-gated. The diagnostic that distinguishes an
/// orphaned speculative fold (store != log) from divergent committed logs across
/// nodes — the store value alone can't. The client decodes the hex (keys/values
/// are ASCII), so there is no in-engine envelope parsing here (robust +
/// format-agnostic).
fn handleLogEntry(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "GET"))
        return reply(server, allocator, ent, sid, sess, 405, "GET only\n");
    const tenant = queryParam(path, "tenant") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?tenant\n");
    const index_s = queryParam(path, "index") orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing ?index\n");
    const index = std.fmt.parseInt(u64, index_s, 10) catch
        return reply(server, allocator, ent, sid, sess, 400, "bad ?index\n");
    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    // Entries are small (a kv writeset). 64 KiB covers any tenant write; a larger
    // entry returns null (engine -3 buf-too-small) → 404, surfaced loudly here.
    const buf = allocator.alloc(u8, 64 * 1024) catch
        return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    defer allocator.free(buf);
    const e = worker.raft.logEntry(gid, index, buf) orelse
        return reply(server, allocator, ent, sid, sess, 404, "no entry at index (compacted / beyond log / too large)\n");
    const hex_chars = "0123456789abcdef";
    const hexbuf = allocator.alloc(u8, e.data.len * 2) catch
        return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    defer allocator.free(hexbuf);
    for (e.data, 0..) |b, i| {
        hexbuf[i * 2] = hex_chars[b >> 4];
        hexbuf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    const out = std.fmt.allocPrint(
        allocator,
        "{{\"index\":{d},\"term\":{d},\"len\":{d},\"data_hex\":\"{s}\"}}\n",
        .{ index, e.term, e.data.len, hexbuf },
    ) catch return reply(server, allocator, ent, sid, sess, 500, "oom\n");
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, out, allocator, null, "application/json");
}

/// `POST /_system/v2-load-replace` (bundle bytes + `X-Rewind-Tenant`) — true
/// REPLACE-load a bundle into an existing (stale) store: every existing pair is
/// deleted, then the bundle's pairs are written, in one atomic kvexp Txn, so the
/// store ends EXACTLY equal to the bundle. The promote-back store reset for a
/// returning learner whose data is older than the source's — a key the source
/// deleted while the learner was gone is removed, not left as a phantom (which
/// would make the promoted-back voter diverge from the cluster). Unlike the
/// streamed merge load's insert-if-absent (zero-downtime move).
fn handleLoadReplace(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    rh: h2.ReqHeaders,
    body: []const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST"))
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const tenant = respb.findHeader(rh, TENANT_HEADER) orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Tenant\n");
    // The instance must already exist: `v2-attach` is the ONLY door that
    // creates one (and the only carrier of the storage incarnation), and the
    // move/promote-back protocol always attaches before it streams. A
    // replace-load reaching a node that was never attached is a protocol
    // violation — creating the instance here would have to guess its storage
    // identity, which is #357's wrong-lifetime bug by construction.
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not attached on this node\n");
    inst.kv.loadTenantBundleReplace(body) catch
        return reply(server, allocator, ent, sid, sess, 400, "replace load failed\n");
    inst.kv.delete(FORWARD_MARKER) catch |err| switch (err) {
        error.NotFound => {},
        else => std.log.warn("v2-load-replace: clearing inherited {s} failed: {s}", .{ FORWARD_MARKER, @errorName(err) }),
    };
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

/// `POST /_system/v2-apply-snapshot {tenant, index, term}` — install a data-free
/// raft baseline at {index, term} into this node's LOCAL group (promote-back
/// step 4). Must be a learner/follower (a leader can't restore to itself). The
/// KV state for `index` must already be loaded (v2-load-replace). After this the
/// leader replicates the tail (> index) from its log; promote to a voter once
/// caught up.
///
/// On the store watermark: this does NOT stamp the kvexp `lastAppliedRaftIdx` to
/// `index`. It intentionally lags (the bundle load used `durabilize(0)`), and
/// that is SAFE — raft recovers its applied index from the WAL compaction marker
/// the snapshot installs, never from the store watermark (`group_raft_config`
/// passes no `applied`; `durable_idx` only seeds rove's `slot.applied_idx`
/// bookkeeping). A crash in the rejoin window therefore recovers cleanly: raft
/// is at `index`, the store data ≤ index is durable from the bundle, and the
/// watermark self-heals on the next applied write. Proven by the crash-in-window
/// leg of `scripts/smoke/promote_back_smoke_v2.py` — keep it green if this changes.
fn handleApplySnapshot(
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
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    var parsed = std.json.parseFromSlice(
        struct { tenant: []const u8, index: u64, term: u64 },
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return reply(server, allocator, ent, sid, sess, 400, "expected {tenant, index, term}\n");
    defer parsed.deinit();
    const v = parsed.value;
    // A data-free baseline must be a real {index>0, term>0} pair. index 0 is a
    // no-op (nothing ahead of committed) and term 0 crashes raft's restore —
    // reject both at the door instead of relying on the downstream SnapshotStale.
    if (v.index == 0)
        return reply(server, allocator, ent, sid, sess, 400, "index must be nonzero\n");
    if (v.term == 0)
        return reply(server, allocator, ent, sid, sess, 400, "index>0 requires a nonzero term\n");
    const gid = worker.raft.gidForTenant(v.tenant) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
    if (worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 409, "this node leads the group; a leader can't restore a snapshot to itself\n");
    // Membership-neutral (null ConfState) — keeps the group's current prs
    // (the promote-back / catch-up behavior). A ConfState carried through the
    // body would let a joiner learn its membership here instead.
    worker.raft.applyLocalSnapshot(gid, v.index, v.term, null, null) catch |e| switch (e) {
        error.SnapshotStale => return reply(server, allocator, ent, sid, sess, 409, "index not ahead of committed; nothing to install\n"),
        error.NotLeader => return reply(server, allocator, ent, sid, sess, 409, "node leads the group\n"),
        error.SelfNotInConfState => return reply(server, allocator, ent, sid, sess, 409, "supplied membership omits this node; add it to the group first\n"),
        else => return reply(server, allocator, ent, sid, sess, 500, "apply-snapshot failed\n"),
    };
    return reply(server, allocator, ent, sid, sess, 204, "");
}

/// Dest side: arm a streamed-snapshot `BodySink` for a
/// `POST /_system/v2-snapshot-stream`. Auth + parse the baseline {tenant, index,
/// term} from headers (the body is the pure pair stream), resolve the local
/// group + instance, then attach the sink and park the entity in
/// `snapshot_streams`. The 204/4xx/5xx is sent later by `drainSnapshotStreams`
/// (on END_STREAM), since the body streams over many ticks. Always handles the
/// request (responds on any rejection; on success the response is deferred).
pub fn armSnapshotStream(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    rh: h2.ReqHeaders,
) !void {
    const secret = worker.move_secret orelse
        return reply(server, allocator, ent, sid, sess, 404, "move surface disabled\n");
    const presented = respb.findHeader(rh, MOVE_SECRET_HEADER) orelse "";
    if (!constantTimeEql(presented, secret))
        return reply(server, allocator, ent, sid, sess, 401, "bad move secret\n");
    if (!std.mem.eql(u8, method, "POST"))
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const tenant = respb.findHeader(rh, TENANT_HEADER) orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Tenant\n");
    const mode: snapshot_sink_mod.Mode =
        if (respb.findHeader(rh, SNAP_MODE_HEADER)) |m|
            (if (std.mem.eql(u8, std.mem.trim(u8, m, " "), "merge")) .merge else .replace)
        else
            .replace;
    // The instance must already exist: `v2-attach` is the ONLY door that
    // creates one (and the only carrier of the storage incarnation). Both
    // stream modes are attach-first by protocol — merge (zero-downtime move)
    // attaches the empty destination before the snapshot ships, and replace
    // (catch-up/promote-back) targets a node already in the group. Creating
    // an instance here would have to guess its storage identity (#357).
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse
        return reply(server, allocator, ent, sid, sess, 404, "tenant not attached on this node\n");

    var gid: u64 = 0;
    var index: u64 = 0;
    var term: u64 = 0;
    var loader_opts: kv_mod.StreamLoaderOptions = undefined;
    switch (mode) {
        .merge => {
            // Zero-downtime move: insert-if-absent into the already-attached,
            // already-forwarded group. No baseline, no leadership check — it
            // applies out-of-band on EVERY destination node.
            loader_opts = .{ .clear_existing = false, .skip_existing = true };
        },
        .replace => {
            // Catch-up / promote-back: a data-free baseline must be a real
            // {index>0, term>0} (index 0 is a no-op, term 0 crashes restore),
            // and a leader can't restore a snapshot to itself.
            const idx_s = respb.findHeader(rh, SNAP_INDEX_HEADER) orelse
                return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Snapshot-Index\n");
            const term_s = respb.findHeader(rh, SNAP_TERM_HEADER) orelse
                return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Snapshot-Term\n");
            index = std.fmt.parseInt(u64, idx_s, 10) catch
                return reply(server, allocator, ent, sid, sess, 400, "bad snapshot index\n");
            term = std.fmt.parseInt(u64, term_s, 10) catch
                return reply(server, allocator, ent, sid, sess, 400, "bad snapshot term\n");
            if (index == 0 or term == 0)
                return reply(server, allocator, ent, sid, sess, 400, "index and term must be nonzero\n");
            gid = worker.raft.gidForTenant(tenant) orelse
                return reply(server, allocator, ent, sid, sess, 404, "tenant not active on this node\n");
            if (worker.raft.isLeaderOf(gid))
                return reply(server, allocator, ent, sid, sess, 409, "leader can't restore a snapshot to itself\n");
            loader_opts = .{ .clear_existing = true };
        },
    }

    var loader = kv_mod.StreamLoader.init(allocator, inst.kv.manifest, loader_opts) catch
        return reply(server, allocator, ent, sid, sess, 500, "loader init failed\n");
    // Box.create COPIES `loader` into the heap box (which then owns its
    // key/val buffers); on success the local must NOT be deinit'd.
    const box = snapshot_sink_mod.Box.create(allocator, loader, mode, tenant, gid, index, term) catch {
        loader.deinit();
        return reply(server, allocator, ent, sid, sess, 500, "snapshot box alloc failed\n");
    };
    if (!worker.armSnapshotStreamSink(ent, sess.entity, sid.id, box))
        return reply(server, allocator, ent, sid, sess, 503, "snapshot stream could not be armed\n");
    // Armed — the entity is parked in `snapshot_streams`; `drainSnapshotStreams`
    // sends the response once the body completes.
}

/// Dest tick: finalize streamed-snapshot transfers parked in
/// `snapshot_streams`. END_STREAM → finish + durabilize, then by mode: `.replace`
/// installs the data-free raft baseline (catch-up); `.merge` drops the inherited
/// forward marker (zero-downtime move, no raft op) → 204. A parse/apply failure
/// → 500; a benign already-ahead/leader race → 409; a client reset → destroy (no
/// response possible). The entity moves to `response_in` (h2 sends the reply) or
/// is destroyed; either way its `SnapshotStream` component releases the box.
pub fn drainSnapshotStreams(worker: anytype) !void {
    const server = worker.h2;
    const coll = &worker.snapshot_streams;
    const entities = coll.entitySlice();
    const states = coll.column(snapshot_sink_mod.SnapshotStream);
    for (entities, states) |ent, *ss| {
        const box = ss.box orelse continue;
        if (box.aborted) {
            // Client reset mid-upload: no response is possible. Destroy — the
            // component deinit drops the box's component ref (the sink ref
            // releases when h2 reaps the stream).
            try server.reg.destroy(ent);
            continue;
        }
        if (!box.eof and !box.failed) continue; // body still streaming

        var status: u16 = 204;
        if (box.failed) {
            status = 500;
        } else if (box.finish()) |_| {
            switch (box.mode) {
                .replace => {
                    if (box.durabilize()) |_| {
                        // Data durable → advance the raft baseline.
                        worker.raft.applyLocalSnapshot(box.gid, box.index, box.term, null, null) catch |e| switch (e) {
                            // Already advanced past `index` via replication during
                            // the stream, or now leads — benign (driver treats 409
                            // as success).
                            error.SnapshotStale, error.NotLeader, error.SelfNotInConfState => status = 409,
                            else => status = 500,
                        };
                    } else |_| status = 500;
                },
                .merge => {
                    // Drop the source's inherited forward marker (the snapshot
                    // carried it insert-if-absent), THEN durabilize. No raft op —
                    // the forward delta already rides the dest group's log.
                    if (worker.node.tenant.getInstance(box.tenant) catch null) |inst| {
                        inst.kv.delete(FORWARD_MARKER) catch |e| switch (e) {
                            error.NotFound => {},
                            else => std.log.warn("v2-snapshot-stream merge: clearing {s} failed: {s}", .{ FORWARD_MARKER, @errorName(e) }),
                        };
                    }
                    if (box.durabilize()) |_| {} else |_| status = 500;
                },
            }
        } else |_| {
            status = 500;
        }

        // Stage the response + queue the move FIRST (fail-loud: a set/move on a
        // live in-collection entity only fails on OOM, which propagates). Detach
        // the box ref LAST, so a failure here leaves the box attached + the
        // entity parked → retried next tick, never orphaned with a null box.
        try server.reg.set(ent, coll, h2.Status, .{ .code = status });
        try server.reg.set(ent, coll, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, coll, h2.RespBody, .{ .data = null, .len = 0 });
        try server.reg.set(ent, coll, h2.H2IoResult, .{ .err = 0 });
        try server.reg.move(ent, coll, &server.response_in);
        // The sink keeps its own ref until h2 reaps the stream; the value carried
        // into `response_in` is now inert.
        box.unref();
        ss.box = null;
    }
}

/// SOURCE side of a streamed move: `POST /_system/v2-snapshot-push`
/// (CP-triggered). Park the request + enqueue an off-loop job that streams this
/// tenant's held snapshot directly to `X-Rewind-Dest` (a dest node base URL) in
/// the given mode (default `merge` — the zero-downtime move). The 204/5xx is sent
/// by `drainSnapshotPushes` once the dest finishes — deferred, since a multi-GB
/// stream must not block the worker loop. Leader-gated like `v2-snapshot` (only
/// the source leader's store is authoritative at the move point).
pub fn armSnapshotPush(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    rh: h2.ReqHeaders,
) !void {
    const secret = worker.move_secret orelse
        return reply(server, allocator, ent, sid, sess, 404, "move surface disabled\n");
    const presented = respb.findHeader(rh, MOVE_SECRET_HEADER) orelse "";
    if (!constantTimeEql(presented, secret))
        return reply(server, allocator, ent, sid, sess, 401, "bad move secret\n");
    if (!std.mem.eql(u8, method, "POST"))
        return reply(server, allocator, ent, sid, sess, 405, "POST only\n");
    const tenant = respb.findHeader(rh, TENANT_HEADER) orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Tenant\n");
    const dest = respb.findHeader(rh, DEST_HEADER) orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Dest\n");
    const mode: snapshot_sink_mod.Mode =
        if (respb.findHeader(rh, SNAP_MODE_HEADER)) |m|
            (if (std.mem.eql(u8, std.mem.trim(u8, m, " "), "replace")) .replace else .merge)
        else
            .merge;

    const gid = worker.raft.gidForTenant(tenant) orelse
        return reply(server, allocator, ent, sid, sess, 409, "tenant not active on this cluster\n");
    if (!worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 421, "not the leader for this tenant; try another node\n");

    const driver = worker.snapshot_push_driver orelse
        return reply(server, allocator, ent, sid, sess, 503, "snapshot push driver not wired\n");

    // Park FIRST (deferred move — walk-safe), then enqueue. The job streams
    // off-loop; `drainSnapshotPushes` matches the completion back to this entity.
    try server.reg.move(ent, &server.request_out, &worker.snapshot_pushes);
    driver.enqueuePush(ent, tenant, dest, mode) catch
        return reply(server, allocator, ent, sid, sess, 500, "enqueue failed\n");
    // No reply — deferred to drainSnapshotPushes on completion.
}

/// SOURCE tick: respond to parked `v2-snapshot-push` requests as
/// the off-loop driver finishes them. Each completion carries the parked
/// `Entity` + the dest's HTTP status (0 = local/transport failure → 502).
pub fn drainSnapshotPushes(worker: anytype, driver: anytype) !void {
    const server = worker.h2;
    var completions: std.ArrayListUnmanaged(@TypeOf(driver.*).PushCompletion) = .empty;
    defer completions.deinit(worker.allocator);
    try driver.drainPushCompletions(&completions);
    for (completions.items) |c| {
        if (server.reg.isStale(c.entity)) continue; // CP gave up / connection gone
        if (!server.reg.isInCollection(c.entity, &worker.snapshot_pushes)) {
            // The park move hasn't flushed yet (a completion that beat the same
            // tick's flush — vanishingly rare given network RTT ≫ flush). Re-post
            // so we match it next tick rather than drop the reply.
            driver.postCompletion(c.entity, c.status);
            continue;
        }
        const status: u16 = if (c.status == 0) 502 else c.status;
        try server.reg.set(c.entity, &worker.snapshot_pushes, h2.Status, .{ .code = status });
        try server.reg.set(c.entity, &worker.snapshot_pushes, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(c.entity, &worker.snapshot_pushes, h2.RespBody, .{ .data = null, .len = 0 });
        try server.reg.set(c.entity, &worker.snapshot_pushes, h2.H2IoResult, .{ .err = 0 });
        try server.reg.move(c.entity, &worker.snapshot_pushes, &server.response_in);
    }
}

/// Stamp a plain status + message response (no CORS — internal surface).
fn reply(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    code: u16,
    msg: []const u8,
) !void {
    try respb.setSystemResponse(server, ent, sid, sess, code, msg, allocator, null, null);
}
