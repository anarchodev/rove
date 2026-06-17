//! V2 Phase 4 — the cluster-internal tenant-MOVE surface.
//!
//! v2-build-order §Phase 4 ("Quiesce + brief-pause move"). These
//! `/_system/v2-*` endpoints are the data-plane half of moving a tenant
//! from one single-node cluster to another; the front door
//! (`rewind-front`) is the orchestrator that calls them in sequence and
//! flips the routing directory at the commit point. Each endpoint runs on
//! the reused rove-js worker, so it has the worker's per-tenant
//! `cluster.kv` stores (`worker.node.tenant`) and the V2 per-tenant raft
//! bridge (`worker.raft`).
//!
//!   v2-kv     — seed (PUT) / read (GET) a tenant store through the real
//!               propose→commit path. The move smoke's write + read-back.
//!   v2-bundle — quiesce the tenant + dump its key-space as a migration
//!               bundle (source). The bundle ships KV state only; blobs
//!               are served from the shared content-addressed store.
//!   v2-attach — load a bundle into a fresh instance + stand up its raft
//!               group at the migration epoch (destination).
//!   v2-evict  — destroy the source raft group + drop the instance once
//!               the directory has flipped (source cleanup).
//!   v2-resume — lift a quiesce (abort path: the move never completed).
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

const MOVE_SECRET_HEADER = "x-rewind-move-secret";
const TENANT_HEADER = "x-rewind-tenant";

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

/// Carries a tenant's opaque CP plan blob (`{tier, overrides}` JSON) on the
/// `v2-attach` handshake (docs/v2-cp-operational-state.md "Delivery to the
/// DP" — the plan rides attach on a move). Absent header ⇒ no plan delivered
/// (the tenant stays free until a live push / the next attach).
const PLAN_HEADER = "x-rewind-plan";
// Optional atomic-baseline headers on v2-attach: when both are present the group
// is created AND given a data-free raft baseline at {index, term} in one pump op
// (createGroupAtBaseline) — the reconciler bootstrap path, which must never leave
// the fresh group observable at last_index 0 (see bridge.createGroupAtBaseline).
const BASELINE_INDEX_HEADER = "x-rewind-baseline-index";
const BASELINE_TERM_HEADER = "x-rewind-baseline-term";
// "1" → birth the local group with this node as a non-voting LEARNER (joining an
// existing group learner-first) instead of a voter from the static voter set.
const JOIN_LEARNER_HEADER = "x-rewind-join-as-learner";

/// Source-side marker key (in the tenant's own `inst.kv`) holding the
/// destination node list — comma-separated base URLs, leader first — while a
/// zero-downtime move's overlap window is open (Phase 7 slice b; a single
/// URL is just a one-element list). When present, the source forwards every
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
    } else if (std.mem.eql(u8, sys_rest, "v2-bundle")) {
        try handleBundle(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-attach")) {
        try handleAttach(server, allocator, worker, ent, sid, sess, method, rh, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-evict")) {
        try handleEvict(server, allocator, worker, ent, sid, sess, method, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-resume")) {
        try handleResume(server, allocator, worker, ent, sid, sess, method, body);
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
    } else if (std.mem.eql(u8, sys_rest, "v2-load-merge")) {
        try handleLoadMerge(server, allocator, worker, ent, sid, sess, method, rh, body);
    } else if (std.mem.eql(u8, sys_rest, "v2-plan")) {
        try handlePlan(server, allocator, worker, ent, sid, sess, method, path, body);
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
    if (rc != 0) return reply(server, allocator, ent, sid, sess, rc, "write failed\n");

    // Zero-downtime overlap (Phase 7 slice b): if a move is forwarding this
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
    // Leader gate (Phase 5 multi-node): only the group leader may take the
    // write. A follower would commit to its own `inst.kv` speculatively then
    // fault the propose with no undo (this immediate-commit path, unlike the
    // parked customer path) — diverging it. Reject fast with 421 (the
    // not-leader / nothing-executed status the front door + serve-or-forward
    // retry on; same convention as the v2-bundle gates below) so the caller
    // re-aims at the leader. Registering first is idempotent + makes
    // `isLeaderOf` resolvable on a single node (the sole voter leads every
    // group).
    const gid = worker.raft.registerTenant(tenant) catch return 500;
    if (!worker.raft.isLeaderOf(gid)) return 421;

    const inst = ensureInstance(worker, tenant) catch return 500;

    var txn = inst.kv.beginTrackedImmediate() catch return 500;
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    txn.put(key, value) catch {
        txn.rollback() catch {};
        return 500;
    };
    ws.addPut(key, value) catch {
        txn.rollback() catch {};
        return 500;
    };
    txn.commit() catch return 500;

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
// instance locally (`tenant.resolveDomain`). Replaces the retired
// `ADMIN_OPS_SECRET`-gated `/ops/assign-domain` JS route (step3-auth-plan.md
// B3): the CP now owns host→tenant end-to-end and propagates the worker alias,
// so `host add` is a single CP call and there's no second operator secret. The
// alias is a `__root__` write — leader-gated, replicated as a type-2
// root_writeset (followers apply it).
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
    if (!worker.raft.isLeaderOf(gid)) return 421;

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

// ── v2-bundle: quiesce + dump (source) ───────────────────────────────

fn handleBundle(
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

    // Leader gate (Phase 5 multi-node): the bundle must be dumped from the
    // node that leads the tenant's group — the only node taking live writes,
    // so quiescing it is what makes the snapshot a consistent point. A
    // follower 421s so the front door's bundle step retries the next node.
    // Single node → always leader, so the milestone path is unchanged.
    if (!worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 421, "not the leader for this tenant; try another node\n");

    // Quiesce: stop admitting writes, then wait for in-flight to drain to
    // applied == committed so the dump is a consistent point.
    const drained_to = worker.raft.quiesce(gid) catch
        return reply(server, allocator, ent, sid, sess, 500, "quiesce failed\n");
    if (!awaitCommit(worker, gid, drained_to)) {
        worker.raft.unquiesce(gid);
        return reply(server, allocator, ent, sid, sess, 504, "drain timed out\n");
    }
    // `committedSeq >= drained_to` proves raft commit + apply-skip, but a
    // parked customer write's TrackedTxn only promotes into the store in
    // drainRaftPending — which runs between dispatches on THIS worker
    // thread, so it cannot make progress while we block here, and a dump
    // taken now would silently MISS raft-committed writes (the move then
    // destroys the source group → acked data lost). Reply 423: the CP
    // retries shortly; between attempts the worker loop drains and the
    // overlay catches up. The quiesce stays held across retries (no new
    // writes; same keep-quiesced contract as the 200 path — an abandoned
    // move releases it via v2-resume).
    if (!worker.raft.workerAckedThrough(gid, drained_to)) {
        return reply(server, allocator, ent, sid, sess, 423, "overlay drain in progress; retry\n");
    }

    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse {
        worker.raft.unquiesce(gid);
        return reply(server, allocator, ent, sid, sess, 404, "unknown tenant\n");
    };
    const bundle = inst.kv.dumpTenantBundle(allocator) catch {
        worker.raft.unquiesce(gid);
        return reply(server, allocator, ent, sid, sess, 500, "bundle dump failed\n");
    };
    // The tenant stays quiesced — the move continues with attach on the
    // destination + evict here. An aborted move calls v2-resume.
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, bundle, allocator, null, "application/octet-stream");
}

// ── v2-attach: load bundle + stand up the group (destination) ─────────

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
    const tenant = respb.findHeader(rh, TENANT_HEADER) orelse
        return reply(server, allocator, ent, sid, sess, 400, "missing X-Rewind-Tenant\n");

    // Create the instance store, load the bundle into it (if any), then
    // attach the raft group at the migration epoch (source birth 0 + 1) so a
    // fresh index sequence starts and any straggler from the old incarnation
    // is fenced out (moot single-node, load-bearing under Phase-7 overlap).
    //
    // An EMPTY body is an "empty attach" (Phase 7 zero-downtime entry): form
    // the group + instance with NO data so the destination is ready to
    // receive the source's live forwards BEFORE its snapshot is shipped — the
    // snapshot then loads insert-if-absent so it never clobbers a forwarded
    // (newer) key. The brief-pause Phase-4/5d move ships the bundle here.
    const inst = ensureInstance(worker, tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "provision failed\n");
    if (body.len > 0) {
        inst.kv.loadTenantBundle(body) catch
            return reply(server, allocator, ent, sid, sess, 400, "bundle load failed\n");
    }

    // The tenant's plan rides the attach handshake (docs/v2-cp-operational-
    // state.md): cache the resolved limits on its slot so enforcement is local
    // from the first post-move request. Non-fatal — a bad/absent plan leaves
    // the tenant on the free tier until a live push corrects it; it must not
    // fail the move.
    if (respb.findHeader(rh, PLAN_HEADER)) |plan_blob| {
        applyPlanBlob(worker, allocator, tenant, plan_blob) catch |err|
            std.log.warn("v2-attach: applyPlanBlob({s}) failed: {s}", .{ tenant, @errorName(err) });
    }

    const gid = worker.raft.registerTenant(tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "register failed\n");
    // A reconciler bootstrap supplies the leader's baseline {index, term} so the
    // group is created already at that baseline (atomic) rather than at an empty
    // last_index 0 — eliminating the attach→apply-snapshot window where a leader
    // heartbeat carrying commit > 0 would crash the fresh group. Plain attach
    // (moves, empty-attach) omits the headers and creates at epoch with no baseline.
    // Baseline headers: ABSENT → no baseline (plain attach). PRESENT but
    // unparseable → hard 400. A malformed header must NEVER silently collapse
    // to "no baseline" (catch 0) and route the reconciler bootstrap into the
    // last_index-0 birth path — the exact crash window documented above.
    const baseline_index: u64 = if (respb.findHeader(rh, BASELINE_INDEX_HEADER)) |s|
        (std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch
            return reply(server, allocator, ent, sid, sess, 400, "malformed " ++ BASELINE_INDEX_HEADER ++ "\n"))
    else
        0;
    const baseline_term: u64 = if (respb.findHeader(rh, BASELINE_TERM_HEADER)) |s|
        (std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch
            return reply(server, allocator, ent, sid, sess, 400, "malformed " ++ BASELINE_TERM_HEADER ++ "\n"))
    else
        0;
    // INVARIANT: a baseline at index>0 must carry a real term (a term-0 baseline
    // crashes raft's restore — Bridge.InvalidBaseline enforces the same at install).
    if (baseline_index > 0 and baseline_term == 0)
        return reply(server, allocator, ent, sid, sess, 400, "baseline index>0 requires a nonzero term\n");
    // Join an EXISTING group as a non-voting learner (the reconciler adds a node
    // learner-first: a born-voter would campaign past a high-term leader and
    // deadlock). The leader must already hold the matching AddLearner conf-change.
    const join_as_learner = if (respb.findHeader(rh, JOIN_LEARNER_HEADER)) |s|
        std.mem.eql(u8, std.mem.trim(u8, s, " "), "1")
    else
        false;
    if (baseline_index > 0) {
        worker.raft.createGroupAtBaseline(gid, 1, baseline_index, baseline_term, join_as_learner) catch |err| switch (err) {
            error.GroupExists => {}, // idempotent re-attach
            else => return reply(server, allocator, ent, sid, sess, 500, "group attach (baseline) failed\n"),
        };
    } else {
        worker.raft.createGroupEpoch(gid, 1) catch |err| switch (err) {
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
    worker.node.tenant.deleteInstance(tenant) catch |err|
        std.log.warn("v2-evict: deleteInstance({s}) failed: {s}", .{ tenant, @errorName(err) });
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-resume: lift a quiesce (abort path) ───────────────────────────

fn handleResume(
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
    if (worker.raft.gidForTenant(tenant)) |gid| worker.raft.unquiesce(gid);
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
}

// ── v2-plan: live plan delivery + diagnostic read (destination) ──────

/// `POST /_system/v2-plan {tenant, plan}` — install a tenant's resolved plan
/// limits on its hot-path slot (the CP's single-target push on a live tier
/// change; docs/v2-cp-operational-state.md "Live tier change"). `plan` is the
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
        const json = std.fmt.allocPrint(allocator, "{{\"request_capacity\":{d},\"request_refill_per_sec\":{d},\"email_capacity\":{d},\"email_refill_per_sec\":{d},\"max_body_bytes\":{d},\"retention_days\":{d},\"plan_gen\":{d}}}", .{
            p.rate.request_capacity,
            p.rate.request_refill_per_sec,
            p.rate.email_capacity,
            p.rate.email_refill_per_sec,
            p.max_body_bytes,
            p.retention_days,
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
/// (Phase 7 zero-downtime). Unlike `v2-bundle` (which quiesces + drains for
/// the brief-pause move), the snapshot is just `dumpTenantBundle`'s
/// consistent read view; concurrent writes are NOT in this snapshot but are
/// carried to the destination by the live forward stream (`v2-forward-begin`,
/// started BEFORE this snapshot), and the destination loads this bundle
/// insert-if-absent so a forwarded (newer) key is never clobbered by the
/// (older) snapshot. Leader-gated like `v2-bundle`.
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

// ── v2-load-merge: insert-if-absent snapshot load (destination) ──────

/// `POST /_system/v2-load-merge` (bundle bytes + `X-Rewind-Tenant`) — load a
/// non-quiescing snapshot into an already-attached (empty) destination group,
/// INSERT-IF-ABSENT: a key a live forward already wrote (newer) is kept; the
/// snapshot's older value is dropped. This is the zero-downtime move's
/// out-of-band snapshot load — the bytes go straight into `inst.kv`, never
/// the raft log (only the forward delta replicates through raft). One
/// exclusive kvexp txn, so it is race-free against concurrent forward-applies
/// on this node. Fanned to EVERY destination node by the orchestrator (like
/// the attach fan-out). The instance + group already exist (empty-attach).
fn handleLoadMerge(
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
    const inst = ensureInstance(worker, tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "provision failed\n");
    inst.kv.loadTenantBundleMerge(body) catch
        return reply(server, allocator, ent, sid, sess, 400, "merge load failed\n");
    // The snapshot was dumped from the SOURCE's store, which holds the
    // source's `_move/forward` marker (it lives in the tenant store today).
    // The destination must NEVER inherit it — after the flip it would read
    // that stale target and forward to it (often itself), deadlocking its own
    // worker. Drop it. (Cleaner long-term: keep the forward marker out of the
    // tenant data store entirely so it never enters a snapshot.)
    inst.kv.delete(FORWARD_MARKER) catch |err| switch (err) {
        error.NotFound => {},
        else => std.log.warn("v2-load-merge: clearing inherited {s} failed: {s}", .{ FORWARD_MARKER, @errorName(err) }),
    };
    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
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
/// zero-downtime overlap (Phase 7 slice b). Applies a write the move source
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

    var easy = try curl.Easy.init(allocator);
    defer easy.deinit();
    var resp = try easy.request(allocator, .{
        .method = .POST,
        .url = url,
        .headers = headers.items,
        .body = payload,
        .http_version = .h2c_prior_knowledge,
        .verify_tls = false,
    });
    defer resp.deinit(allocator);
    return resp.status;
}

// ── helpers ──────────────────────────────────────────────────────────

/// Resolve a tenant instance, creating it (existence marker + per-tenant
/// `cluster.kv` store) on first sight. Idempotent.
fn ensureInstance(worker: anytype, tenant: []const u8) !*const tenant_mod.Instance {
    if (try worker.node.tenant.getInstance(tenant)) |inst| return inst;
    try worker.node.tenant.createInstance(tenant);
    return (try worker.node.tenant.getInstance(tenant)) orelse error.ProvisionFailed;
}

/// Resolve a CP plan blob into effective limits and cache them on the tenant's
/// hot-path slot (`TenantSlot.setPlan`, which bumps the plan generation so the
/// rate limiter re-snapshots caps). The blob is opaque `{tier, overrides}`
/// JSON; an empty/malformed blob resolves to the free tier (`plan.parseBlob`).
/// `error.UnknownTenant` if the tenant has no instance on this cluster.
fn applyPlanBlob(worker: anytype, allocator: std.mem.Allocator, tenant: []const u8, plan_blob: []const u8) !void {
    const inst = (try worker.node.tenant.getInstance(tenant)) orelse return error.UnknownTenant;
    const slot = try worker.node.deploy.getOrOpenTenantSlot(inst);
    try slot.setPlan(plan_mod.parseBlob(allocator, plan_blob));
}

/// Block (bounded by `commit_wait_timeout_ns`) until the tenant's raft
/// watermark reaches `target_seq`. The bridge pump thread advances it.
fn awaitCommit(worker: anytype, gid: u64, target_seq: u64) bool {
    if (target_seq == 0) return true;
    const deadline: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(worker.commit_wait_timeout_ns));
    while (std.time.nanoTimestamp() < deadline) {
        if (worker.raft.committedSeq(gid) >= target_seq) return true;
        std.Thread.sleep(200 * std.time.ns_per_us);
    }
    return worker.raft.committedSeq(gid) >= target_seq;
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

// ── v2-confchange / v2-confstate: manual membership change (conf_change Ph1) ──

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
        struct { tenant: []const u8, node_id: u64, op: []const u8 },
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
    worker.raft.proposeConfChange(gid, v.node_id, cc_type) catch |e| switch (e) {
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

// ── promote-back: out-of-band rejoin of a below-floor learner (Ph2) ──
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

/// `GET /_system/v2-applied-baseline?tenant=` → `{"index":X,"term":T}` where X
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
    // this flows through to a {0,0} baseline = a plain (snapshot-free) born attach
    // — exactly as before, no special case.
    const index = worker.raft.appliedIndex(gid);
    // A baseline is the pair {index, term-of-the-log-entry-at-index}. logTerm now
    // returns null when the leader's own log can't resolve a term for `index` (it
    // is beyond last_index, below the compaction floor, or the store watermark has
    // drifted ahead of the raft log) — there is NO valid baseline to hand out.
    // Handing back {index, term:0} would feed an OUT-OF-BAND snapshot a bogus term,
    // which raft-rs's `restore` treats as a same-term match and fast-forwards
    // `commit_to(index)` past the follower's empty log → `fatal!`. Refuse instead:
    // the reconciler retries once the leader's log covers its watermark. null is
    // DISTINCT from a genuine term 0 (the genesis index) — the error channel no
    // longer collapses "no term" into a fake 0 — so the abort only ever fires on a
    // real invariant break, exactly as it should.
    const term = worker.raft.logTerm(gid, index) orelse
        return reply(server, allocator, ent, sid, sess, 409, "no term-valid baseline (leader log does not cover the applied index)\n");
    const out = std.fmt.allocPrint(allocator, "{{\"index\":{d},\"term\":{d}}}\n", .{ index, term }) catch
        return reply(server, allocator, ent, sid, sess, 500, "oom\n");
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

/// `POST /_system/v2-load-replace` (bundle bytes + `X-Rewind-Tenant`) — true
/// REPLACE-load a bundle into an existing (stale) store: every existing pair is
/// deleted, then the bundle's pairs are written, in one atomic kvexp Txn, so the
/// store ends EXACTLY equal to the bundle. The promote-back store reset for a
/// returning learner whose data is older than the source's — a key the source
/// deleted while the learner was gone is removed, not left as a phantom (which
/// would make the promoted-back voter diverge from the cluster). Unlike
/// `v2-load-merge`'s insert-if-absent (zero-downtime move).
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
    const inst = ensureInstance(worker, tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "provision failed\n");
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
/// leg of `scripts/promote_back_smoke_v2.py` — keep it green if this changes.
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
    worker.raft.applyLocalSnapshot(gid, v.index, v.term) catch |e| switch (e) {
        error.SnapshotStale => return reply(server, allocator, ent, sid, sess, 409, "index not ahead of committed; nothing to install\n"),
        error.NotLeader => return reply(server, allocator, ent, sid, sess, 409, "node leads the group\n"),
        else => return reply(server, allocator, ent, sid, sess, 500, "apply-snapshot failed\n"),
    };
    return reply(server, allocator, ent, sid, sess, 204, "");
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
