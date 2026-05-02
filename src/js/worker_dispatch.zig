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
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const router_mod = @import("router.zig");
const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const raft_propose = @import("raft_propose.zig");
const panic_mod = @import("panic.zig");
const worker_mod = @import("worker.zig");

const Request = dispatcher_mod.Request;
const ProxyPeer = worker_mod.ProxyPeer;
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
    /// record shares its id with any outbox rows `webhook.send`
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
    successes: *std.ArrayList(SuccessRec),
) !usize {
    const server = worker.h2;
    const allocator = worker.allocator;
    const anchor_id = anchor.id;
    const store = anchor.kv;
    const batch_seq = txn.txn_seq;
    const has_writes = writeset.ops.items.len > 0;
    var processed: usize = 0;

    // Commit-fail downgrade path: SQLite has already rolled back, so
    // every success-recorded handler gets its body replaced with 503
    // and a `.kv_error` log outcome.
    txn.commit() catch |err| panic_mod.invariantViolated(
        "finalizeBatch.commit",
        "tenant={s} err={s}",
        .{ anchor_id, @errorName(err) },
    );

    if (!has_writes) {
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

    // Writes present: propose the merged writeset once. On failure,
    // compensating-rollback via undoTxn + downgrade every success.
    const seq = raft_propose.proposeWriteSet(worker, writeset, anchor_id) catch |err| {
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

/// `/_system/*` proxy + preflight handler. Returns true iff the
/// request matched and was finalized (response stamped + moved to
/// `response_in` or forwarded to a subsystem `pending` queue).
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

    // Auth shape: cookie first, then Authorization: Bearer. Lets the
    // dashboard JS call /_system/files/* and /_system/log/* without
    // juggling a bearer header.
    const auth_ctx = auth.extractAdminAuth(worker.tenant, rh) catch |err| {
        std.log.warn("rove-js: authenticate failed: {s}", .{@errorName(err)});
        try respb.setSystemResponse(server, ent, sid, sess, 500, "auth check failed\n", allocator, cors_origin, null);
        return true;
    };
    if (auth_ctx == null) {
        try respb.setSystemResponse(server, ent, sid, sess, 401, "unauthenticated\n", allocator, cors_origin, null);
        return true;
    }

    // Strip `?query=string` off the path before routing. Subsystems
    // (log, code proxies) forward the whole `:path` downstream;
    // query parsing happens in the subsystem thread, not here.
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;

    const sys_rest = path_no_q["/_system/".len..];
    const sub_slash = std.mem.indexOfScalar(u8, sys_rest, '/') orelse {
        try respb.setSystemResponse(server, ent, sid, sess, 404, "malformed system path\n", allocator, cors_origin, null);
        return true;
    };
    const subsystem = sys_rest[0..sub_slash];
    const after_sub = sys_rest[sub_slash + 1 ..];

    // `/_system/tenant/*` and `/_system/kv/*` moved to the
    // `__admin__` JS handler; callers target the bare admin host
    // (`app.loop46.me/?fn=listKv`, optionally with `X-Rove-Scope`).
    // `/_system/log/*` and `/_system/files/*` remain native — log
    // queries poll frequently (would meta-log themselves through JS)
    // and code uploads are byte-heavy (fit the subsystem thread).
    const inst_slash = std.mem.indexOfScalar(u8, after_sub, '/');
    const sys_instance_id = if (inst_slash) |s| after_sub[0..s] else after_sub;
    if (sys_instance_id.len == 0) {
        try respb.setSystemResponse(server, ent, sid, sess, 404, "missing instance id\n", allocator, cors_origin, null);
        return true;
    }
    const allowed = worker.tenant.canAccessInstance(auth_ctx.?, sys_instance_id) catch false;
    if (!allowed) {
        try respb.setSystemResponse(server, ent, sid, sess, 403, "forbidden\n", allocator, cors_origin, null);
        return true;
    }

    if (std.mem.eql(u8, subsystem, "files")) {
        if (worker.code_proxy.addr == null) {
            try respb.setSystemResponse(server, ent, sid, sess, 503, "files subsystem disabled\n", allocator, cors_origin, null);
            return true;
        }
        try server.reg.set(ent, &server.request_out, ProxyPeer, .{ .client = rove.Entity.nil });
        try server.reg.move(ent, &server.request_out, &worker.code_proxy.pending);
        return true;
    }
    if (std.mem.eql(u8, subsystem, "log")) {
        if (worker.log_proxy.addr == null) {
            try respb.setSystemResponse(server, ent, sid, sess, 503, "log subsystem disabled\n", allocator, cors_origin, null);
            return true;
        }
        try server.reg.set(ent, &server.request_out, ProxyPeer, .{ .client = rove.Entity.nil });
        try server.reg.move(ent, &server.request_out, &worker.log_proxy.pending);
        return true;
    }

    try respb.setSystemResponse(server, ent, sid, sess, 501, "system endpoint not implemented\n", allocator, cors_origin, null);
    return true;
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
    if (std.mem.eql(u8, method, "GET") and !has_query) {
        const admin_inst = worker.tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch null;
        if (admin_inst) |ai| {
            const admin_tc = worker_mod.getOrOpenTenantFiles(worker, ai) catch null;
            if (admin_tc) |tc| {
                const outcome = try respb.tryServeStatic(server, allocator, ent, sid, sess, tc, path, rh);
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

        // `/_system/*` — CORS gate, then auth + proxy routing.
        if (try tryHandleSystem(server, allocator, worker, ent, sid, sess, method, path, rh)) {
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
        // `_static/index.html` on `/?fn=...` API calls.
        if (!is_admin_request and std.mem.eql(u8, method, "GET")) {
            const static_outcome = try respb.tryServeStatic(
                server,
                allocator,
                ent,
                sid,
                sess,
                tc,
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

        // Pre-mint the request id. webhook.send derives its outbox id
        // from this (so replays produce matching ids), and captureLog
        // at the end reuses it so the log record shares the id with
        // every outbox row this request spawned. Lazy-opens the log
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
        };

        txn.?.savepoint() catch |err| panic_mod.invariantViolated(
            "dispatchOnce.savepoint",
            "tenant={s} err={s}",
            .{ scope_inst.id, @errorName(err) },
        );

        var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
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
        const handler_resp_hdrs: h2.RespHeaders = try respb.buildHandlerRespHeaders(
            allocator,
            handler_cors,
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
        const tape_refs = worker_mod.uploadTapes(worker, scope_inst.id, &tapes);

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
    processed += try finalizeBatch(worker, anchor.?, &txn.?, &writeset, &successes);
    return processed;
}
