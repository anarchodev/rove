//! Per-tenant request dispatch — the hot path of `rove-js`.
//!
//! `dispatchOnce` walks `request_out` once per tick, anchoring on the
//! first handler-bound request's tenant. Subsequent matching requests
//! run under per-handler savepoints inside the shared `TrackedTxn`;
//! mismatches and short-circuits (auth, /_system/*, 404, rate limit,
//! penalty box) finalize inline. After the walk, `finalizeBatch`
//! commits the txn and proposes the merged writeset through raft —
//! either parking entries in `raft_pending` (writes present) or moving
//! straight to `response_in` (read-only batch).
//!
//! Lives in its own file so the worker.zig module can stay focused on
//! lifecycle (init, polling, tenant-state caching, log flush) while
//! the request-shaped logic clusters here.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("rove-kv");
const log_mod = @import("rove-log");
const jwt = @import("rove-jwt");
const tenant_mod = @import("rove-tenant");
const webhook_server_mod = @import("rove-webhook-server");

const dispatcher_mod = @import("dispatcher.zig");
const router_mod = @import("router.zig");
const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const raft_propose = @import("raft_propose.zig");
const panic_mod = @import("panic.zig");
const worker_mod = @import("worker.zig");
const session_mod = @import("session.zig");
const events_mod = @import("events.zig");
const events_pump = @import("events_pump.zig");

const Request = dispatcher_mod.Request;
const RaftWait = worker_mod.RaftWait;

/// Per-handler record carried through the batch walk, from a
/// successful `dispatcher.run` to the shared commit + propose at
/// end-of-walk. Owns `console_owned` / `exception_owned` until
/// they transfer into a log record after commit.
const SuccessRec = struct {
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status_code: u16,
    body_ptr: ?[*]u8,
    body_len: u32,
    console_owned: []u8,
    exception_owned: []u8,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    tape_refs: log_mod.TapeRefs,
    /// Pre-minted id reused on commit-time log capture so the log
    /// record shares its id with any webhook rows `webhook.send`
    /// wrote during this request's handler.
    request_id: u64,
};

/// End-of-walk: commit the shared batch txn, propose the merged
/// writeset through raft (unless read-only), then move each success
/// onward. Three exit paths:
///
///  - **commit failure**: SQLite already rolled back; every success
///    downgrades to 503 with `.kv_error` outcome in the log.
///  - **read-only batch**: no writes → no raft hop → every success
///    moves straight to `response_in` with its normal status.
///  - **writes present**: propose the writeset; on success the
///    entries park in `raft_pending` with a `RaftWait` stamp, and
///    `drainRaftPending` moves them onward once `committedSeq`
///    advances past them. On propose failure we `undoTxn` and
///    downgrade each success to 503 `.fault`.
///
/// Returns the number of entries finalized.
fn finalizeBatch(
    worker: anytype,
    anchor: *const tenant_mod.Instance,
    txn: *kv_mod.KvStore.TrackedTxn,
    writeset: *const kv_mod.WriteSet,
    pending_webhooks: *const std.ArrayListUnmanaged(webhook_server_mod.WebhookRow),
    successes: *std.ArrayList(SuccessRec),
) !usize {
    const server = worker.h2;
    const allocator = worker.allocator;
    const anchor_id = anchor.id;
    const store = anchor.kv;
    const batch_seq = txn.txn_seq;
    const has_writes = writeset.ops.items.len > 0;
    const has_webhooks = pending_webhooks.items.len > 0;
    var processed: usize = 0;

    // Commit-fail downgrade path: SQLite has already rolled back, so
    // every success-recorded handler gets its body replaced with 503
    // and a `.kv_error` log outcome.
    txn.commit() catch |err| panic_mod.invariantViolated(
        "finalizeBatch.commit",
        "tenant={s} err={s}",
        .{ anchor_id, @errorName(err) },
    );

    // SSE: now that the writes are durable on the leader, mark any
    // sids touched by `_events/{sid}/...` rows as dirty so the next
    // pump tick wakes them up. Skip on no-writes (nothing to mark)
    // and on lookup failure (anchor must exist for us to be here,
    // but fail-soft if the tenant_files map raced a teardown).
    if (has_writes) {
        if (worker.tenant_files_map.get(anchor_id)) |tc| {
            events_pump.markDirtyFromWriteset(tc, writeset) catch |err| {
                std.log.warn(
                    "rove-js: events_pump.markDirtyFromWriteset({s}) failed: {s}",
                    .{ anchor_id, @errorName(err) },
                );
            };
        }
    }

    if (!has_writes and !has_webhooks) {
        // Pure read-only batch: no raft hop.
        for (successes.items) |*s| {
            server.reg.move(s.ent, &server.request_out, &server.response_in) catch |err| panic_mod.invariantViolated(
                "finalizeBatch.move(read_only)",
                "tenant={s} err={s}",
                .{ anchor_id, @errorName(err) },
            );
            const console_owned = s.console_owned;
            const exception_owned = s.exception_owned;
            s.console_owned = &.{};
            s.exception_owned = &.{};
            worker_mod.captureLogWithId(worker, anchor_id, s.request_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, s.status_code, .ok, console_owned, exception_owned, s.tape_refs);
            processed += 1;
        }
        successes.clearRetainingCapacity();
        return processed;
    }

    // Writes and/or webhooks present: propose ONE raft entry. The
    // shape is multi-envelope (env 0 + env 4) when both, or a single
    // envelope when only one side has content. See
    // `raft_propose.proposeBatchAndWebhooks` for the wire decision.
    // On failure: compensating-rollback via undoTxn + downgrade every
    // success. The webhook accumulator is freed by the caller's
    // `defer` regardless of which branch we take here.
    const seq = raft_propose.proposeBatchAndWebhooks(worker, writeset, pending_webhooks.items, anchor_id) catch |err| {
        std.log.warn("rove-js raft propose (batch, tenant={s}) failed: {s}", .{ anchor_id, @errorName(err) });
        store.undoTxn(batch_seq) catch |undo_err| panic_mod.invariantViolated(
            "finalizeBatch.undoTxn(after_propose_fail)",
            "tenant={s} txn_seq={d} err={s}",
            .{ anchor_id, batch_seq, @errorName(undo_err) },
        );
        for (successes.items) |*s| {
            respb.overwriteWith503(server, s.ent, allocator, s.body_ptr, s.body_len) catch |err2| panic_mod.invariantViolated(
                "finalizeBatch.respb.overwriteWith503(propose_fail)",
                "tenant={s} err={s}",
                .{ anchor_id, @errorName(err2) },
            );
            server.reg.move(s.ent, &server.request_out, &server.response_in) catch |err2| panic_mod.invariantViolated(
                "finalizeBatch.move(propose_fail)",
                "tenant={s} err={s}",
                .{ anchor_id, @errorName(err2) },
            );
            const console_owned = s.console_owned;
            const exception_owned = s.exception_owned;
            s.console_owned = &.{};
            s.exception_owned = &.{};
            worker_mod.captureLogWithId(worker, anchor_id, s.request_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, 503, .fault, console_owned, exception_owned, s.tape_refs);
            processed += 1;
        }
        successes.clearRetainingCapacity();
        return processed;
    };

    const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() + @as(i128, @intCast(worker.commit_wait_timeout_ns)));
    for (successes.items) |*s| {
        try server.reg.set(s.ent, &server.request_out, RaftWait, .{
            .seq = seq,
            .txn_seq = batch_seq,
            .deadline_ns = deadline_ns,
            .store = store,
        });
        try server.reg.move(s.ent, &server.request_out, &worker.raft_pending);

        const console_owned = s.console_owned;
        const exception_owned = s.exception_owned;
        s.console_owned = &.{};
        s.exception_owned = &.{};
        worker_mod.captureLogWithId(worker, anchor_id, s.request_id, s.method, s.path, s.host, s.deployment_id, s.received_ns, s.status_code, .ok, console_owned, exception_owned, s.tape_refs);
        processed += 1;
    }
    successes.clearRetainingCapacity();
    return processed;
}

/// `/_system/*` route handler — CORS preflight + `services-token`
/// mint + `release` POST. Returns true iff the request matched and
/// was finalized (response stamped + moved to `response_in`).
fn tryHandleSystem(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    rh: h2.ReqHeaders,
    body: []const u8,
) !bool {
    if (!std.mem.startsWith(u8, path, "/_system/")) return false;

    // Every /_system/* response carries CORS headers when the worker
    // has an admin origin configured. Browsers enforce the origin
    // match on their side against `Access-Control-Allow-Origin`, so
    // stamping headers even on requests without an Origin is harmless.
    const cors_origin = worker.admin_origin;

    // Preflight: browser sends OPTIONS before the real request to
    // discover allowed methods/headers. Answer 204 with the
    // preflight-specific CORS headers and never touch auth —
    // preflights don't carry the bearer token.
    if (std.mem.eql(u8, method, "OPTIONS")) {
        if (cors_origin) |o| {
            const req_origin = respb.findHeader(rh, "origin") orelse "";
            if (req_origin.len == 0 or !std.mem.eql(u8, req_origin, o)) {
                try respb.setSystemResponse(server, ent, sid, sess, 403, "cors origin not allowed\n", allocator, null, null);
            } else {
                const hdrs = try respb.buildSystemRespHeaders(allocator, o, true, null);
                try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 204 });
                try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
                try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
                try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
                try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
                try server.reg.set(ent, &server.request_out, h2.Session, sess);
                try server.reg.move(ent, &server.request_out, &server.response_in);
            }
        } else {
            try respb.setSimpleResponse(server, ent, sid, sess, 405, "OPTIONS not supported\n", allocator);
        }
        return true;
    }

    // Strip `?query=string` off the path before routing.
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    const sys_rest = path_no_q["/_system/".len..];

    // Per-endpoint auth. Most `/_system/*` endpoints require admin
    // auth (root bearer or session cookie); a small allow-list of
    // cluster-internal endpoints also accept a services-JWT carrying
    // the matching capability so files-server can push deploys +
    // config without holding the operator's root bearer. The cap
    // alternative is gated to the exact endpoint that needs it —
    // there is no global "admin or cap" pass.
    const required_cap: ?[]const u8 = if (std.mem.eql(u8, sys_rest, "release"))
        jwt.Cap.RELEASE
    else if (std.mem.eql(u8, sys_rest, "admin-kv"))
        jwt.Cap.ADMIN_KV
    else
        null;

    if (!try authorizeSystemRequest(server, allocator, worker, ent, sid, sess, rh, cors_origin, required_cap)) {
        return true;
    }

    // Phase 5.5(a) Step B / Phase 5.5(e) Step F1 — JWT minter for
    // the standalone services (log-server + files-server). Caller is
    // already admin-authenticated; we hand back a 5-minute HS256
    // token + the public origins of both services so the dashboard
    // can call them directly cross-origin.
    if (std.mem.eql(u8, sys_rest, "services-token")) {
        try handleServicesTokenMint(server, allocator, worker, ent, sid, sess, cors_origin);
        return true;
    }

    // Phase 5.5(e) F2 — push-based release. The dashboard / CLI
    // POSTs `{"tenant_id":"...","dep_id":N}` here right after a
    // successful files-server deploy; we record the new id in the
    // process-wide `ReleaseTable` and every worker's next dispatch
    // tick reloads bytecodes via `applyPendingReleases`. Replaces
    // the legacy 2-second `refreshDeployments` polling loop.
    if (std.mem.eql(u8, sys_rest, "release")) {
        try handleRelease(server, allocator, worker, ent, sid, sess, method, body, cors_origin);
        return true;
    }

    // Leader-status probe used by smokes + files-server bootstrap to
    // discover which node will accept release / admin-kv POSTs. The
    // tenant-routing leader-skip in dispatchOnce doesn't apply here
    // (`/_system/*` short-circuits before tenant routing), so /_system
    // probes alone can't tell leader from follower. Returns 200 on the
    // leader and 503 ("not leader; retry against the cluster leader\n")
    // on followers — same shape as the customer-tenant leader-skip
    // response so tooling can treat both the same way.
    if (std.mem.eql(u8, sys_rest, "leader")) {
        if (worker.raft.isLeader()) {
            try respb.setSystemResponse(server, ent, sid, sess, 200, "leader\n", allocator, cors_origin, null);
        } else {
            try respb.setSystemResponse(server, ent, sid, sess, 503, "not leader; retry against the cluster leader\n", allocator, cors_origin, null);
        }
        return true;
    }

    // Cluster-wide admin config push. files-server-standalone POSTs
    // `{"pairs":[{"key":"...","value":"..."},...]}` here at platform
    // bootstrap time so operator-supplied --bootstrap-kv values land
    // in `__admin__/app.db` via raft (envelope 0). Replaces the
    // worker's old --bootstrap-kv flag, which wrote per-node
    // bypassing raft.
    if (std.mem.eql(u8, sys_rest, "admin-kv")) {
        try handleAdminKv(server, allocator, worker, ent, sid, sess, method, body, cors_origin);
        return true;
    }

    // No remaining proxy subsystems on the worker — `/_system/log/*`
    // retired in Phase 5.5(a) Step B, `/_system/files/*` retired in
    // Phase 5.5(e) Step F1. `/_system/kv/*` and `/_system/tenant/*`
    // moved to the `__admin__` JS handler long before.
    try respb.setSystemResponse(server, ent, sid, sess, 501, "system endpoint not implemented\n", allocator, cors_origin, null);
    return true;
}

/// Auth gate for `/_system/*` requests. Accepts either:
///   - admin auth: session cookie (`rove_session`) or `Authorization:
///     Bearer <root-token>`
///   - **only when `required_cap` is set**: a services-JWT signed by
///     `LOOP46_SERVICES_JWT_SECRET` whose `caps` claim contains the
///     given cap. Used by files-server to push platform deploys +
///     config without holding the operator's root bearer.
///
/// Returns true when the caller is allowed to proceed, false when
/// the response (401 / 500) has already been stamped onto the entity.
fn authorizeSystemRequest(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    cors_origin: ?[]const u8,
    required_cap: ?[]const u8,
) !bool {
    const auth_ctx = auth.extractAdminAuth(worker.tenant, rh) catch |err| {
        std.log.warn("rove-js: authenticate failed: {s}", .{@errorName(err)});
        try respb.setSystemResponse(server, ent, sid, sess, 500, "auth check failed\n", allocator, cors_origin, null);
        return false;
    };
    if (auth_ctx != null) return true;

    // Admin auth missing/invalid. If this endpoint accepts a cap
    // alternative, try the services-JWT.
    if (required_cap) |cap| {
        const secret = worker.services_jwt_secret;
        const token = auth.extractBearerToken(rh);
        if (secret != null and token != null) {
            const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
            if (jwt.verifyWithCap(secret.?, token.?, now_ms, cap)) |_| {
                return true;
            } else |_| {
                // Fall through to 401 — the cap check failed for
                // some reason (expired, wrong secret, missing cap).
            }
        }
    }

    try respb.setSystemResponse(server, ent, sid, sess, 401, "unauthenticated\n", allocator, cors_origin, null);
    return false;
}

/// Mint an HS256 JWT for the standalone services. Body shape:
///   `{"token":"<jwt>","log_url":"<base>","files_url":"<base>","exp_ms":<...>}`
/// Token expires in 5 minutes; the dashboard refreshes by hitting
/// this endpoint again. 503 when the server wasn't started with a
/// JWT secret (operator skipped Step B / F1 wiring).
fn handleServicesTokenMint(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cors_origin: ?[]const u8,
) !void {
    const secret = worker.services_jwt_secret orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "services jwt not configured\n", allocator, cors_origin, null);
        return;
    };
    const log_base = worker.log_public_base orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "log-server public base not configured\n", allocator, cors_origin, null);
        return;
    };
    const files_base = worker.files_public_base orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "files-server public base not configured\n", allocator, cors_origin, null);
        return;
    };

    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const exp_ms: i64 = now_ms + 5 * 60 * 1000;
    const token = jwt.mint(allocator, secret, .{ .exp_ms = exp_ms }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "mint failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    defer allocator.free(token);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"token\":\"{s}\",\"log_url\":\"{s}\",\"files_url\":\"{s}\",\"exp_ms\":{d}}}\n",
        .{ token, log_base, files_base, exp_ms },
    );
    try respb.setSystemResponseOwned(server, ent, sid, sess, 200, body, allocator, cors_origin, "application/json");
}

/// Body shape: `{"tenant_id":"<id>","dep_id":<u64>}`. Persists the
/// release pointer to the tenant's app.db at `_deploy/current`
/// (replicated via raft envelope 0 so cold-starts and other nodes
/// see it), records the release in the process-wide `ReleaseTable`
/// (so the per-worker dispatch tick observes it without polling),
/// and returns 204. Idempotent — a repeat with the same dep_id
/// re-stamps the kv row and re-publishes the table entry.
fn handleRelease(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    body: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST")) {
        try respb.setSystemResponse(server, ent, sid, sess, 405, "POST only\n", allocator, cors_origin, null);
        return;
    }
    const table = worker.release_table orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "release table not configured\n", allocator, cors_origin, null);
        return;
    };

    var parsed = std.json.parseFromSlice(struct {
        tenant_id: []const u8,
        dep_id: u64,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try respb.setSystemResponse(server, ent, sid, sess, 400, "expected {\"tenant_id\":\"...\",\"dep_id\":N}\n", allocator, cors_origin, null);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.tenant_id.len == 0 or parsed.value.dep_id == 0) {
        try respb.setSystemResponse(server, ent, sid, sess, 400, "tenant_id required and dep_id must be > 0\n", allocator, cors_origin, null);
        return;
    }

    // Reject unknown tenants — keeps stale dashboard sessions from
    // populating the table with garbage that never matches.
    const inst_opt = worker.tenant.getInstance(parsed.value.tenant_id) catch null;
    const inst = inst_opt orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 404, "unknown tenant\n", allocator, cors_origin, null);
        return;
    };

    // Persist the release pointer to the tenant's app.db. Stamps
    // `_deploy/current = {dep_id:016x}` and proposes through raft
    // envelope 0; followers' apply path picks it up and the worker's
    // openTenantFiles reads it on first request after a restart.
    var hex_buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{parsed.value.dep_id}) catch unreachable;

    var txn = inst.kv.beginTrackedImmediate() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "release txn open failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    txn.put("_deploy/current", hex) catch |err| {
        txn.rollback() catch {};
        const msg = try std.fmt.allocPrint(allocator, "release put failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    ws.addPut("_deploy/current", hex) catch |err| {
        txn.rollback() catch {};
        const msg = try std.fmt.allocPrint(allocator, "release writeset failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    txn.commit() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "release commit failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    _ = raft_propose.proposeWriteSet(worker, &ws, parsed.value.tenant_id) catch |err| {
        // At-least-once semantics: leader has the write; followers
        // may not. Same compromise the outbox / root paths take.
        std.log.warn(
            "release: propose envelope 0 for {s}/_deploy/current = {x:0>16} failed: {s}",
            .{ parsed.value.tenant_id, parsed.value.dep_id, @errorName(err) },
        );
    };
    inst.kv.commitTxn(txn.txn_seq) catch |err| {
        std.log.warn(
            "release: commitTxn drop-undo for {s} failed: {s}",
            .{ parsed.value.tenant_id, @errorName(err) },
        );
    };

    table.set(parsed.value.tenant_id, parsed.value.dep_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "release table failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
}

/// Body shape: `{"pairs":[{"key":"<k>","value":"<v>"}, ...]}`. Writes
/// each pair into `__admin__/app.db` via a raft-replicated envelope
/// 0 writeset, so every node sees the same admin config. Used by
/// files-server-standalone at platform-bootstrap time to ship
/// operator-supplied config (resend_key, platform_email_from, ...)
/// without a per-node `--bootstrap-kv` flag.
///
/// Idempotent: re-posting the same pairs re-stamps the kv rows. The
/// caller (files-server) does this on every restart with the same
/// values, which is fine.
fn handleAdminKv(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    body: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, method, "POST")) {
        try respb.setSystemResponse(server, ent, sid, sess, 405, "POST only\n", allocator, cors_origin, null);
        return;
    }

    const Pair = struct { key: []const u8, value: []const u8 };
    var parsed = std.json.parseFromSlice(struct {
        pairs: []const Pair,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try respb.setSystemResponse(server, ent, sid, sess, 400, "expected {\"pairs\":[{\"key\":\"...\",\"value\":\"...\"},...]}\n", allocator, cors_origin, null);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.pairs.len == 0) {
        try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
        return;
    }

    const admin_inst_opt = worker.tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch null;
    const admin_inst = admin_inst_opt orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "__admin__ tenant not initialized\n", allocator, cors_origin, null);
        return;
    };

    var txn = admin_inst.kv.beginTrackedImmediate() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "admin-kv txn open failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    for (parsed.value.pairs) |p| {
        if (p.key.len == 0) {
            txn.rollback() catch {};
            try respb.setSystemResponse(server, ent, sid, sess, 400, "empty key\n", allocator, cors_origin, null);
            return;
        }
        if (std.mem.indexOfScalar(u8, p.key, 0) != null or
            std.mem.indexOfScalar(u8, p.value, 0) != null)
        {
            txn.rollback() catch {};
            try respb.setSystemResponse(server, ent, sid, sess, 400, "key/value contains NUL\n", allocator, cors_origin, null);
            return;
        }
        txn.put(p.key, p.value) catch |err| {
            txn.rollback() catch {};
            const msg = try std.fmt.allocPrint(allocator, "admin-kv put failed: {s}\n", .{@errorName(err)});
            try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
            return;
        };
        ws.addPut(p.key, p.value) catch |err| {
            txn.rollback() catch {};
            const msg = try std.fmt.allocPrint(allocator, "admin-kv writeset failed: {s}\n", .{@errorName(err)});
            try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
            return;
        };
    }
    txn.commit() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "admin-kv commit failed: {s}\n", .{@errorName(err)});
        try respb.setSystemResponseOwned(server, ent, sid, sess, 500, msg, allocator, cors_origin, null);
        return;
    };

    _ = raft_propose.proposeWriteSet(worker, &ws, tenant_mod.ADMIN_INSTANCE_ID) catch |err| {
        std.log.warn(
            "admin-kv: propose envelope 0 for {d} pair(s) failed: {s}",
            .{ parsed.value.pairs.len, @errorName(err) },
        );
    };
    admin_inst.kv.commitTxn(txn.txn_seq) catch |err| {
        std.log.warn(
            "admin-kv: commitTxn drop-undo failed: {s}",
            .{@errorName(err)},
        );
    };

    try respb.setSystemResponse(server, ent, sid, sess, 204, "", allocator, cors_origin, null);
}

/// Outcome of `resolveRequest`: either the request was finalized
/// inline (caller bumps `processed` and continues) or the caller
/// should fall through to the shared handler-dispatch path with the
/// resolved `(handler_inst, scope_inst)` pair plus an `is_admin`
/// flag that gates CORS + static-first behavior.
const ResolvedDispatch = struct {
    handler_inst: *const tenant_mod.Instance,
    scope_inst: *const tenant_mod.Instance,
    is_admin: bool,
};

const ResolveResult = union(enum) {
    handled,
    dispatch: ResolvedDispatch,
};

/// Decide what to do with a single request pre-handler. Three shapes
/// fall out of the call:
///
///  1. Admin host (`host == admin_api_domain`) — run OPTIONS preflight,
///     public static fallthrough, pre-auth routes, auth gate, post-auth
///     `/v1/session`, then scope resolution via `X-Rove-Scope`. Either
///     finalizes (any of the above) or returns the admin tenant as
///     `handler_inst` and the scoped tenant as `scope_inst`.
///
///  2. Customer subdomain — lookup via `resolveDomain`. Finalizes on
///     unknown host or returns the tenant as both handler and scope.
///
///  3. Fall-through handler dispatch — the caller runs the same
///     per-handler code for both shapes, branched on `is_admin` for
///     CORS + static-first decisions.
fn resolveRequest(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    rh: h2.ReqHeaders,
) !ResolveResult {
    const is_admin_host = if (worker.admin_api_domain) |pat|
        pat.len > 0 and std.mem.eql(u8, host, pat)
    else
        false;

    if (!is_admin_host) {
        const r = worker.tenant.resolveDomain(host) catch |err| {
            std.log.warn("rove-js: tenant.resolveDomain({s}) failed: {s}", .{ host, @errorName(err) });
            try respb.setSimpleResponse(server, ent, sid, sess, 500, "tenant resolution failed\n", allocator);
            return .handled;
        };
        if (r == null) {
            const ps = worker.tenant.publicSuffix() orelse "(none)";
            const ad = worker.admin_api_domain orelse "(none)";
            const body_owned = std.fmt.allocPrint(
                allocator,
                "no tenant for host '{s}'\n" ++
                    "  admin_api_domain={s}\n" ++
                    "  public_suffix={s}\n" ++
                    "  no domain alias registered for this host\n",
                .{ host, ad, ps },
            ) catch null;
            defer if (body_owned) |b| allocator.free(b);
            const body: []const u8 = body_owned orelse "no tenant for host\n";
            try respb.setSimpleResponse(server, ent, sid, sess, 404, body, allocator);
            return .handled;
        }
        return .{ .dispatch = .{
            .handler_inst = r.?,
            .scope_inst = r.?,
            .is_admin = false,
        } };
    }

    // ── Admin host branch ─────────────────────────────────────────
    //
    // CORS preflight + static bundle + /v1/* pre-auth + auth + scope.

    // Preflight: browser sends OPTIONS before the real admin API
    // call. 204 with CORS preflight headers; never touch auth.
    if (std.mem.eql(u8, method, "OPTIONS")) {
        if (worker.admin_origin) |o| {
            const req_origin = respb.findHeader(rh, "origin") orelse "";
            if (req_origin.len == 0 or !std.mem.eql(u8, req_origin, o)) {
                try respb.setSystemResponse(server, ent, sid, sess, 403, "cors origin not allowed\n", allocator, null, null);
            } else {
                const hdrs = try respb.buildSystemRespHeaders(allocator, o, true, null);
                try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 204 });
                try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
                try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
                try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
                try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
                try server.reg.set(ent, &server.request_out, h2.Session, sess);
                try server.reg.move(ent, &server.request_out, &server.response_in);
            }
        } else {
            try respb.setSimpleResponse(server, ent, sid, sess, 405, "OPTIONS not supported\n", allocator);
        }
        return .handled;
    }

    const admin_cors = worker.admin_origin;

    // Public static bundle: the admin UI's HTML/JS/CSS must reach
    // the browser before any JS dispatch happens so the login page
    // can render without being told it's unauthenticated. Serves
    // GET requests with no query string; everything else falls
    // through to admin's JS bundle (where `_middlewares/index.mjs`
    // applies the auth gate).
    const has_query = std.mem.indexOfScalar(u8, path, '?') != null;
    const is_static_method = std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD");
    if (is_static_method and !has_query) {
        const admin_inst = worker.tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch null;
        if (admin_inst) |ai| {
            const admin_tc = worker_mod.getOrOpenTenantFiles(worker, ai) catch null;
            if (admin_tc) |tc| {
                const outcome = try respb.tryServeStatic(server, allocator, ent, sid, sess, tc, method, path, rh);
                if (outcome != .miss) return .handled;
            }
        }
    }

    // Auth for the admin host is owned by admin's deployed
    // `_middlewares/index.mjs` — it runs before every dispatch
    // (default export AND named-export RPCs), checks cookie/bearer,
    // and either sets request.auth or short-circuits 401. Pre-auth
    // paths (signup / auth / login / logout) skip the gate inside
    // the middleware. Zig is no longer in the admin auth path —
    // `/_system/*` keeps its own auth gate via `tryHandleSystem`
    // until the files-server + log-server detach (PLAN §10.13).

    const admin_opt = worker.tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch null;
    if (admin_opt == null) {
        try respb.setSystemResponse(server, ent, sid, sess, 503, "admin tenant not provisioned\n", allocator, admin_cors, null);
        return .handled;
    }
    const handler_inst = admin_opt.?;

    // Scope resolution: every cross-tenant admin call carries the
    // target tenant in `X-Rove-Scope: <id>`. Empty header → admin
    // operates on its own app.db. (The dashboard JS sets this header
    // explicitly — see `web/admin/api.js`.)
    const effective_scope = respb.findHeader(rh, "x-rove-scope") orelse "";

    const scope_inst: *const tenant_mod.Instance = if (effective_scope.len == 0)
        handler_inst
    else blk: {
        const s_opt = worker.tenant.getInstance(effective_scope) catch |err| inner: {
            std.log.warn("rove-js: admin getInstance({s}) failed: {s}", .{ effective_scope, @errorName(err) });
            break :inner null;
        };
        if (s_opt == null) {
            try respb.setSystemResponse(server, ent, sid, sess, 404, "unknown instance\n", allocator, admin_cors, null);
            return .handled;
        }
        break :blk s_opt.?;
    };

    return .{ .dispatch = .{
        .handler_inst = handler_inst,
        .scope_inst = scope_inst,
        .is_admin = true,
    } };
}

pub fn dispatchOnce(worker: anytype, blocked: anytype) !usize {
    const server = worker.h2;
    const allocator = worker.allocator;

    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    // Leader-only request handling. Followers serve no client traffic
    // — they just replicate the leader's raft entries. Any request
    // that lands on a follower is bounced with 503 + a hint so the
    // client retries against the leader.
    const is_leader = worker.raft.isLeader();

    // Batch state. Set lazily on the first handler-bound request we
    // see; subsequent requests in the same walk that target a
    // different tenant are left in request_out for a future
    // dispatchOnce call to pick up.
    var anchor: ?*const tenant_mod.Instance = null;
    var txn: ?kv_mod.KvStore.TrackedTxn = null;
    var writeset = kv_mod.WriteSet.init(allocator);
    defer writeset.deinit();

    // Per-batch webhook accumulator. `webhook.send` appends a
    // `WebhookRow` here; `finalizeBatch` proposes the merged batch as
    // envelope 4 inside the type-7 multi-envelope alongside envelope
    // 0 (writeset). Rows own allocator-allocated strings; the defer
    // frees them regardless of how the batch ends.
    var pending_webhooks: std.ArrayListUnmanaged(webhook_server_mod.WebhookRow) = .empty;
    defer {
        for (pending_webhooks.items) |*r| r.deinit(allocator);
        pending_webhooks.deinit(allocator);
    }

    // Successful handlers awaiting the shared commit + final move.
    // Owns `console_owned` / `exception_owned` until they transfer
    // into a log record after commit.
    var successes: std.ArrayList(SuccessRec) = .empty;
    defer {
        for (successes.items) |*s| {
            if (s.console_owned.len > 0) allocator.free(s.console_owned);
            if (s.exception_owned.len > 0) allocator.free(s.exception_owned);
        }
        successes.deinit(allocator);
    }

    var processed: usize = 0;

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, req_body| {
        if (!is_leader) {
            try respb.setSimpleResponse(server, ent, sid, sess, 503, "not leader; retry against the cluster leader\n", allocator);
            processed += 1;
            continue;
        }

        const received_ns: i64 = @intCast(std.time.nanoTimestamp());

        const method = respb.findHeader(rh, ":method") orelse "GET";
        const path = respb.findHeader(rh, ":path") orelse "/";
        const authority = respb.findHeader(rh, ":authority") orelse "";
        const body: []const u8 = if (req_body.data) |p| p[0..req_body.len] else "";

        // `/_system/*` — CORS gate, then auth + system route dispatch.
        if (try tryHandleSystem(server, allocator, worker, ent, sid, sess, method, path, rh, body)) {
            processed += 1;
            continue;
        }

        const host = worker_mod.hostOnly(authority);

        const resolved = switch (try resolveRequest(server, allocator, worker, ent, sid, sess, method, path, host, rh)) {
            .handled => {
                processed += 1;
                continue;
            },
            .dispatch => |d| d,
        };
        const handler_inst = resolved.handler_inst;
        const scope_inst = resolved.scope_inst;
        const is_admin_request = resolved.is_admin;

        // Lazy-open the tenant log eagerly on every request, BEFORE
        // any of the early-exit `captureLog` paths below (rate-limit,
        // static-served, no-handler 404, penalty-box, no-deployment).
        // `captureLogInner` looks up the per-worker `tenant_logs`
        // cache and silently drops the record on miss; without this
        // line, runtime-created tenants (signup) lose their first
        // request's log entry on every non-handler-dispatch path
        // until something else opens the log. Multi-worker
        // SO_REUSEPORT inherits the same cold-cache problem on each
        // worker's first request for a given tenant.
        //
        // The handler-dispatch path also lazy-opens (at the
        // request-id mint just below the per-handler section), but
        // that runs AFTER these early exits — so the early-exit
        // captures need their own seed.
        _ = worker_mod.getOrOpenTenantLog(worker, scope_inst) catch |err| {
            std.log.warn(
                "rove-js: getOrOpenTenantLog({s}) failed before captureLog: {s}",
                .{ scope_inst.id, @errorName(err) },
            );
        };

        // Lazy-open: instances created at runtime aren't in the map yet.
        const tc = worker_mod.getOrOpenTenantFiles(worker, handler_inst) catch |err| {
            std.log.warn("rove-js: lazy openTenantFiles({s}) failed: {s}", .{ handler_inst.id, @errorName(err) });
            try respb.setSimpleResponse(server, ent, sid, sess, 500, "tenant code state missing\n", allocator);
            worker_mod.captureLog(worker, scope_inst.id, method, path, host, 0, received_ns, 500, .handler_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };
        if (tc.current_deployment_id == 0) {
            try respb.setSimpleResponse(server, ent, sid, sess, 503, "no deployment for this tenant\n", allocator);
            worker_mod.captureLog(worker, scope_inst.id, method, path, host, 0, received_ns, 503, .no_deployment, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        // `/_events` — SSE endpoint, scoped to the resolved tenant
        // (its sse_connections + dirty_sids tables). Mints
        // `__Host-rove_sid` if absent, sends text/event-stream
        // headers, moves into stream_response_in for the pump to
        // drive on subsequent ticks. Caps + connect-rate enforced
        // here so a flooding tenant can't exhaust resources before
        // the connection table even sees them. See
        // docs/sse-plan.md §11d-f.
        if (try events_mod.tryHandleEvents(
            server,
            allocator,
            tc,
            scope_inst.id,
            &worker.limiter,
            events_mod.FREE,
            ent,
            sid,
            sess,
            method,
            path,
            rh,
            received_ns,
        )) {
            worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 200, .ok, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        // Rate limiter: customer-tenant requests check the per-instance
        // request bucket. Admin requests bypass entirely (operational
        // traffic — locking ourselves out would be bad). Runs BEFORE
        // static dispatch so static file requests count against the
        // bucket too — they consume worker resources (h2 stream +
        // memcpy + content-type header build) and are customer-
        // attributable. On exhaustion: 429 + Retry-After header.
        if (!is_admin_request) {
            const allowed = worker.limiter.check(scope_inst.id, .request, received_ns) catch |err| blk: {
                std.log.warn("rove-js: limiter.check({s}) failed: {s} — fail open", .{ scope_inst.id, @errorName(err) });
                break :blk true;
            };
            if (!allowed) {
                const retry_after = worker.limiter.retryAfterSeconds(scope_inst.id, .request);
                try respb.setRateLimitedResponse(server, ent, sid, sess, allocator, retry_after);
                worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 429, .handler_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            }
        }

        // Static-first dispatch for customer traffic only. Admin
        // requests already ran their own pre-auth static check above —
        // running it here again would shadow the admin JS handler with
        // `_static/index.html` on `/?fn=...` API calls. Both GET and
        // HEAD route through here; HEAD gets identical headers but no
        // body (RFC 9110 §9.3.2).
        if (!is_admin_request and (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD"))) {
            const static_outcome = try respb.tryServeStatic(
                server,
                allocator,
                ent,
                sid,
                sess,
                tc,
                method,
                path,
                rh,
            );
            switch (static_outcome) {
                .served => |status| {
                    worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, status, .ok, &.{}, &.{}, .{});
                    processed += 1;
                    continue;
                },
                .miss => {},
            }
        }

        var route = router_mod.resolveRoute(allocator, path) catch |err| {
            std.log.warn("rove-js router failed: {s}", .{@errorName(err)});
            try respb.setErrorResponse(server, ent, sid, sess);
            worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .handler_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };
        defer route.deinit();

        const bytecode = (try worker_mod.findBytecode(tc, route.module_base, allocator)) orelse {
            // Convention 404: serve `_static/_404.html` if the tenant
            // has it. Otherwise fall back to the built-in text body.
            if (!try respb.serveConvention404(server, allocator, ent, sid, sess, tc)) {
                try respb.setSimpleResponse(server, ent, sid, sess, 404, "not found\n", allocator);
            }
            worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 404, .handler_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };

        if (worker.penalty_box.isBoxed(handler_inst.id, tc.current_deployment_id, received_ns)) {
            try respb.setSimpleResponse(server, ent, sid, sess, 503, "tenant temporarily disabled (cpu budget)\n", allocator);
            worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 503, .timeout, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        // This is a handler-bound request. Either establish the
        // tick's anchor tenant (open the batch txn) or — if an anchor
        // already exists and this entity targets a different tenant
        // (or the tenant was marked busy earlier this tick) — skip it,
        // leaving it in request_out for a future dispatchOnce call.
        if (anchor) |a| {
            if (a != scope_inst) continue;
        } else {
            // Already proven BUSY earlier this tick? Skip.
            var skip_blocked = false;
            for (blocked.slice()) |b| {
                if (b == scope_inst) {
                    skip_blocked = true;
                    break;
                }
            }
            if (skip_blocked) continue;

            var new_txn = scope_inst.kv.beginTrackedImmediate() catch |err| {
                std.log.warn("rove-js beginTrackedImmediate({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
                try respb.setSimpleResponse(server, ent, sid, sess, 500, "txn begin failed\n", allocator);
                worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            };
            // Eagerly open the underlying SQLite txn so SQLITE_BUSY
            // surfaces HERE — if another worker holds RESERVED on
            // this tenant's app.db we note the tenant as blocked for
            // the remainder of this tick and skip past it to try a
            // different anchor (Stage 3: cross-tenant scheduling on
            // contention).
            new_txn.open() catch |err| {
                if (err == kv_mod.KvError.Conflict) {
                    blocked.append(scope_inst) catch {
                        // blocked list is bounded; overflow means this
                        // tick has already tried more tenants than we
                        // budgeted for. Leave the entity in place and
                        // return what we've processed so far — next
                        // tick gets a fresh blocked list.
                        return processed;
                    };
                    continue;
                }
                std.log.warn("rove-js open tracked txn ({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
                try respb.setSimpleResponse(server, ent, sid, sess, 500, "txn open failed\n", allocator);
                worker_mod.captureLog(worker, scope_inst.id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
                processed += 1;
                continue;
            };
            txn = new_txn;
            anchor = scope_inst;
        }

        // At this point `anchor` is set and equals `scope_inst`, and
        // `txn` is open. Run the handler under its own savepoint so a
        // JS exception or CPU-budget kill rolls back only this handler's
        // writes without poisoning the rest of the batch.
        var tapes = worker_mod.RequestTapes.init(allocator);
        defer tapes.deinit();

        // Pre-mint the request id. webhook.send derives its webhook id
        // from this (so replays produce matching ids), and captureLog
        // at the end reuses it so the log record shares the id with
        // every webhook row this request spawned. Lazy-opens the log
        // store if the tenant was created at runtime.
        const request_id: u64 = blk: {
            const tl_opt = worker_mod.getOrOpenTenantLog(worker, scope_inst) catch |err| {
                std.log.warn("rove-js: getOrOpenTenantLog({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
                break :blk 0;
            };
            break :blk tl_opt.store.nextRequestId() catch |err| {
                std.log.warn("rove-js: nextRequestId({s}) failed: {s}", .{ scope_inst.id, @errorName(err) });
                break :blk 0;
            };
        };

        // Admin-handler requests get a root writeset allocated for
        // them so any `platform.root.set/delete` the handler issues
        // can be proposed through raft after commit. Customer-tenant
        // requests never have `platform` set, so they skip this.
        var root_ws_storage: kv_mod.WriteSet = undefined;
        var root_ws_ptr: ?*kv_mod.WriteSet = null;
        if (handler_inst.platform != null) {
            root_ws_storage = kv_mod.WriteSet.init(allocator);
            root_ws_ptr = &root_ws_storage;
        }
        defer if (root_ws_ptr) |ws| ws.deinit();

        // Resolve (or eagerly mint) the platform session cookie. Static
        // assets and /_system/* short-circuited above, so reaching here
        // means we're about to invoke a customer/admin JS handler — the
        // points where SSE event-routing identity matters. If the
        // browser sent no `__Host-rove_sid` (or sent a malformed one),
        // we mint a fresh sid and append a `Set-Cookie` to the response
        // below. See docs/sse-plan.md §1.
        var sid_prng = std.Random.DefaultPrng.init(@bitCast(received_ns));
        const session_resolved = session_mod.resolve(rh, sid_prng.random());

        const request: Request = .{
            .method = method,
            .path = path,
            .host = authority,
            .body = body,
            .query = route.query,
            .headers = rh,
            .kv_tape = &tapes.kv,
            .date_tape = &tapes.date,
            .math_random_tape = &tapes.math_random,
            .crypto_random_tape = &tapes.crypto_random,
            .module_tape = &tapes.module,
            .prng_seed = @bitCast(received_ns),
            .request_id = request_id,
            .session_id = session_resolved.sid,
            // Non-null only when the handler-tenant is the admin
            // singleton — gates installation of `platform.root.*`.
            .platform = handler_inst.platform,
            .root_writeset = root_ws_ptr,
            // Limiter scope: the SCOPE tenant (the kv this handler
            // operates on), not the handler tenant. Admin handlers
            // running as `__admin__` scoped to `acme` should pull
            // from acme's email bucket, not __admin__'s.
            .limiter = &worker.limiter,
            .instance_id = scope_inst.id,
            // Deploy-starter trampoline. Only meaningful on admin-
            // handler requests; customer requests have no platform
            // capability, and the JS callable rejects them at the
            // gate before ever reaching this fn pointer.
            .deploy_starter = if (handler_inst.platform != null)
                &@TypeOf(worker.*).deployStarterTrampoline
            else
                null,
            .deploy_starter_ctx = if (handler_inst.platform != null)
                @ptrCast(worker)
            else
                null,
            .pending_webhooks = &pending_webhooks,
        };

        txn.?.savepoint() catch |err| panic_mod.invariantViolated(
            "dispatchOnce.savepoint",
            "tenant={s} err={s}",
            .{ scope_inst.id, @errorName(err) },
        );

        // Admin tenant requests get a longer budget — signup + deploy
        // legitimately block on S3 PUTs for a few seconds. Customer
        // tenants stay on the default (1s).
        const budget_ns = if (std.mem.eql(u8, scope_inst.id, tenant_mod.ADMIN_INSTANCE_ID))
            dispatcher_mod.Budget.admin_duration_ns
        else
            dispatcher_mod.Budget.default_duration_ns;
        var budget = dispatcher_mod.Budget.fromNow(budget_ns);
        var resp = worker.dispatcher.run(
            scope_inst.kv,
            &txn.?,
            &writeset,
            bytecode,
            &tc.bytecodes,
            &tc.source_hashes,
            tc.triggers,
            request,
            &budget,
        ) catch |err| {
            txn.?.rollbackTo() catch |re| panic_mod.invariantViolated(
                "dispatchOnce.rollbackTo(after_dispatch_error)",
                "tenant={s} err={s}",
                .{ scope_inst.id, @errorName(re) },
            );
            const outcome: log_mod.Outcome = if (err == dispatcher_mod.DispatchError.Interrupted)
                .timeout
            else
                .handler_error;
            const status: u16 = if (err == dispatcher_mod.DispatchError.Interrupted) 504 else 500;
            if (err == dispatcher_mod.DispatchError.Interrupted) {
                try respb.setSimpleResponse(server, ent, sid, sess, 504, "handler exceeded cpu budget\n", allocator);
                worker.penalty_box.recordKill(
                    handler_inst.id,
                    tc.current_deployment_id,
                    received_ns,
                ) catch |pe| std.log.warn("rove-js penalty recordKill failed: {s}", .{@errorName(pe)});
            } else {
                try respb.setErrorResponse(server, ent, sid, sess);
            }
            worker_mod.captureLogWithId(worker, scope_inst.id, request_id, method, path, host, tc.current_deployment_id, received_ns, status, outcome, &.{}, &.{}, .{});
            processed += 1;
            continue;
        };
        // `resp.console` / `resp.exception` are freed here unless we
        // transfer them into a SuccessRec below.
        defer {
            if (resp.console.len > 0) allocator.free(resp.console);
            if (resp.exception.len > 0) allocator.free(resp.exception);
        }

        // JS exception → 500 with the message in the body. The
        // dispatcher captured the throw into resp.exception while
        // leaving status at the default 200 and body empty, so without
        // this check we'd ship a 200 empty body.
        if (resp.exception.len > 0) {
            txn.?.rollbackTo() catch |re| panic_mod.invariantViolated(
                "dispatchOnce.rollbackTo(after_js_exception)",
                "tenant={s} err={s}",
                .{ scope_inst.id, @errorName(re) },
            );
            const console_owned = resp.console;
            const exception_owned = resp.exception;
            resp.console = &.{};
            resp.exception = &.{};
            const ex_body = std.fmt.allocPrint(allocator, "handler threw: {s}\n", .{exception_owned}) catch &.{};
            defer if (ex_body.len > 0) allocator.free(ex_body);
            const ex_body_slice: []const u8 = if (ex_body.len > 0) ex_body else "handler threw\n";
            try respb.setSimpleResponse(server, ent, sid, sess, 500, ex_body_slice, allocator);
            worker_mod.captureLogWithId(worker, scope_inst.id, request_id, method, path, host, tc.current_deployment_id, received_ns, 500, .handler_error, console_owned, exception_owned, .{});
            processed += 1;
            continue;
        }

        if (worker.dispatcher.last_kv_error != null) {
            std.log.warn("rove-js handler kv error: {s}", .{@errorName(worker.dispatcher.last_kv_error.?)});
            worker.dispatcher.last_kv_error = null;
            txn.?.rollbackTo() catch |re| panic_mod.invariantViolated(
                "dispatchOnce.rollbackTo(after_kv_error)",
                "tenant={s} err={s}",
                .{ scope_inst.id, @errorName(re) },
            );
            try respb.setSimpleResponse(server, ent, sid, sess, 500, "kv error during handler\n", allocator);
            worker_mod.captureLogWithId(worker, scope_inst.id, request_id, method, path, host, tc.current_deployment_id, received_ns, 500, .kv_error, &.{}, &.{}, .{});
            processed += 1;
            continue;
        }

        txn.?.release() catch |err| panic_mod.invariantViolated(
            "dispatchOnce.release",
            "tenant={s} err={s}",
            .{ scope_inst.id, @errorName(err) },
        );

        // Propose the root writeset (if the admin handler made any
        // `platform.root.*` writes). The local writes already landed
        // on `root.db` inside the callbacks; this step just replicates
        // them to followers. Proposed per-handler rather than batched
        // because there's only one admin-tenant anchor at a time —
        // batching wouldn't save anything.
        if (root_ws_ptr) |root_ws| {
            if (root_ws.ops.items.len > 0) {
                _ = raft_propose.proposeRootWriteSet(worker, root_ws) catch |err| {
                    std.log.warn(
                        "rove-js: platform.root writeset propose failed: {s} (leader wrote, followers may diverge)",
                        .{@errorName(err)},
                    );
                };
            }
        }

        // Stamp response components on the entity. They ride through
        // `raft_pending` → `response_in` (or straight to `response_in`
        // for pure-read batches) without rewrites. The entity stays
        // in `request_out` until the shared commit completes below.
        const body_ptr: ?[*]u8 = if (resp.body.len > 0) resp.body.ptr else null;
        const body_len: u32 = @intCast(resp.body.len);
        resp.body = &.{};
        const status_code: u16 = @intCast(@max(@min(resp.status, 599), 100));

        // Admin-host responses carry CORS headers so the browser UI
        // on a different origin can read them. Non-admin user traffic
        // is same-origin (it's their tenant's own domain) and gets
        // empty RespHeaders (plus any Set-Cookies the handler pushed
        // via `response.cookies`).
        const handler_cors = if (is_admin_request) worker.admin_origin else null;
        const handler_ct: ?[]const u8 = if (resp.body_is_json) "application/json" else null;
        // Append the platform `__Host-rove_sid` Set-Cookie when the
        // worker had to mint a new sid for this request. Owned slice
        // freed via h2's RespHeaders teardown of the packed header buf.
        const platform_cookie: ?[]u8 = if (session_resolved.mint_set_cookie)
            try session_mod.formatSetCookie(allocator, &session_resolved.sid)
        else
            null;
        defer if (platform_cookie) |pc| allocator.free(pc);
        const handler_resp_hdrs: h2.RespHeaders = try respb.buildHandlerRespHeaders(
            allocator,
            handler_cors,
            platform_cookie,
            resp.set_cookies,
            handler_ct,
            resp.headers,
        );
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status_code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, handler_resp_hdrs);
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = body_ptr, .len = body_len });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);

        // Upload tapes now — blob-addressed and idempotent, so storing
        // them before commit is safe even if the batch later rolls
        // back. The refs get carried into the log record after commit.
        // `body` is the inbound request body; `body_ptr[0..body_len]`
        // is the outbound response body the worker just stamped on
        // `request_out`. Both get captured.
        const response_body_slice: []const u8 = if (body_ptr) |p| p[0..body_len] else &.{};
        const tape_refs = worker_mod.uploadTapes(worker, scope_inst.id, &tapes, body, response_body_slice);

        const console_owned = resp.console;
        const exception_owned = resp.exception;
        resp.console = &.{};
        resp.exception = &.{};

        try successes.append(allocator, .{
            .ent = ent,
            .sid = sid,
            .sess = sess,
            .status_code = status_code,
            .body_ptr = body_ptr,
            .body_len = body_len,
            .console_owned = console_owned,
            .exception_owned = exception_owned,
            .method = method,
            .path = path,
            .host = host,
            .deployment_id = tc.current_deployment_id,
            .received_ns = received_ns,
            .tape_refs = tape_refs,
            .request_id = request_id,
        });
    }

    // End of walk. If no anchor was opened we're done — all processing
    // was short-circuit (failed) paths.
    if (anchor == null) return processed;
    processed += try finalizeBatch(worker, anchor.?, &txn.?, &writeset, &pending_webhooks, &successes);
    return processed;
}
