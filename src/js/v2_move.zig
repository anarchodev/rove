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

const MOVE_SECRET_HEADER = "x-rewind-move-secret";
const TENANT_HEADER = "x-rewind-tenant";

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

    // Leader gate (Phase 5 multi-node): only the tenant's group leader may
    // take the write. A follower would otherwise commit to its own `inst.kv`
    // speculatively and then fault the propose (not leader) WITHOUT rolling
    // that local write back (this immediate-commit endpoint, unlike the
    // parked customer path, has no undo) — diverging the follower. Reject
    // fast instead so the front door retries the leader. Registering first
    // is idempotent and makes `isLeaderOf` resolvable on a single node (the
    // sole voter leads every group, so this is always true there).
    const gid = worker.raft.registerTenant(tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "register failed\n");
    if (!worker.raft.isLeaderOf(gid))
        return reply(server, allocator, ent, sid, sess, 503, "not leader; retry the cluster leader\n");

    // Provision the instance on first sight (the source cluster's tenant
    // store is born here), then write through the real propose path: an
    // immediate kvexp commit followed by a raft propose the move's bundle
    // dump will see.
    const inst = ensureInstance(worker, tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "provision failed\n");

    var txn = inst.kv.beginTrackedImmediate() catch
        return reply(server, allocator, ent, sid, sess, 500, "txn open failed\n");
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    txn.put(key, value) catch {
        txn.rollback() catch {};
        return reply(server, allocator, ent, sid, sess, 500, "put failed\n");
    };
    ws.addPut(key, value) catch {
        txn.rollback() catch {};
        return reply(server, allocator, ent, sid, sess, 500, "writeset failed\n");
    };
    txn.commit() catch {
        return reply(server, allocator, ent, sid, sess, 500, "commit failed\n");
    };

    const proposed = raft_propose.proposeWriteSet(worker, &ws, tenant, "") catch
        return reply(server, allocator, ent, sid, sess, 503, "propose failed\n");
    if (!awaitCommit(worker, proposed.group_id, proposed.seq))
        return reply(server, allocator, ent, sid, sess, 504, "raft commit timed out\n");

    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, null, null);
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

    // Create the instance store, load the bundle into it, then attach the
    // raft group at the migration epoch (source birth 0 + 1) so a fresh
    // index sequence starts and any straggler from the old incarnation is
    // fenced out (moot single-node, load-bearing under Phase-7 overlap).
    const inst = ensureInstance(worker, tenant) catch
        return reply(server, allocator, ent, sid, sess, 500, "provision failed\n");
    inst.kv.loadTenantBundle(body) catch
        return reply(server, allocator, ent, sid, sess, 400, "bundle load failed\n");

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

// ── helpers ──────────────────────────────────────────────────────────

/// Resolve a tenant instance, creating it (existence marker + per-tenant
/// `cluster.kv` store) on first sight. Idempotent.
fn ensureInstance(worker: anytype, tenant: []const u8) !*const tenant_mod.Instance {
    if (try worker.node.tenant.getInstance(tenant)) |inst| return inst;
    try worker.node.tenant.createInstance(tenant);
    return (try worker.node.tenant.getInstance(tenant)) orelse error.ProvisionFailed;
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
