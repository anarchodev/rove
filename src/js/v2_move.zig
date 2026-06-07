//! V2 Phase 4 — the cluster-internal tenant-MOVE surface.
//!
//! docs/v2-build-order.md §Phase 4 ("Quiesce + brief-pause move"). These
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

/// Carries a tenant's opaque CP plan blob (`{tier, overrides}` JSON) on the
/// `v2-attach` handshake (docs/v2-cp-operational-state.md "Delivery to the
/// DP" — the plan rides attach on a move). Absent header ⇒ no plan delivered
/// (the tenant stays free until a live push / the next attach).
const PLAN_HEADER = "x-rewind-plan";

/// Source-side marker key (in the tenant's own `inst.kv`) holding the
/// destination base URL while a zero-downtime move's overlap window is open
/// (Phase 7 slice b). When present, the source forwards every committed
/// write for this tenant to the destination so it stays caught up while the
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
    if (presented.len != secret.len or !std.mem.eql(u8, presented, secret)) {
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
    // parked customer path) — diverging it. Reject fast so the caller retries
    // the leader. Registering first is idempotent + makes `isLeaderOf`
    // resolvable on a single node (the sole voter leads every group).
    const gid = worker.raft.registerTenant(tenant) catch return 500;
    if (!worker.raft.isLeaderOf(gid)) return 503;

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
    if (!awaitCommit(worker, proposed.group_id, proposed.seq)) return 504;
    return 0;
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
    worker.raft.createGroupEpoch(gid, 1) catch |err| switch (err) {
        error.GroupExists => {}, // idempotent re-attach
        else => return reply(server, allocator, ent, sid, sess, 500, "group attach failed\n"),
    };
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
/// the destination base URL in the tenant's `inst.kv` (`_move/forward`) so
/// every subsequent committed write is dual-written to the destination. The
/// marker rides the replicated write path (so a source leader change carries
/// it). Leader-gated like any source write.
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

/// The destination base URL this tenant is forwarding to, or null if no
/// overlap is open. Reads the `_move/forward` marker from `inst.kv`; an
/// absent or empty marker means "not forwarding." Owned dup on success.
fn forwardTargetFor(worker: anytype, tenant: []const u8) ?[]u8 {
    const inst = (worker.node.tenant.getInstance(tenant) catch null) orelse return null;
    const v = inst.kv.get(FORWARD_MARKER) catch return null; // NotFound → null
    if (v.len == 0) {
        worker.allocator.free(v);
        return null;
    }
    return v; // owned by the caller (kvexp get returns an owned copy)
}

/// Dual-write one committed key/value to the move destination's `v2-apply`
/// (blocking libcurl, like the move surface — this is an internal, low-rate
/// overlay path, not the customer hot path). Errors on a non-204 / transport
/// failure so the source can surface 502 and the caller retry.
fn forwardWrite(allocator: std.mem.Allocator, secret: []const u8, dest: []const u8, tenant: []const u8, key: []const u8, value: []const u8) !void {
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
    if (resp.status != 204) return error.ForwardRejected;
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
