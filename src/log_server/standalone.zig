//! Standalone log-server (Phase 5.5 a, step 2) — combines the
//! background indexer thread + an h2 query API in one process.
//!
//! Loopback-only at this stage (no public TLS); step 6 of the
//! migration moves it to `logs.{public_suffix}` with TLS + JWT
//! handoff. The wire shape follows `docs/logs-plan.md` §5:
//!
//!   GET /v1/{tenant_id}/list
//!         ?limit=N&after_received_ns=X&after_request_id=Y
//!       → 200 application/json
//!         {"records":[...],"next_cursor":{"received_ns":...,
//!                                          "request_id":...}}
//!
//!   GET /v1/{tenant_id}/show/{request_id_decimal}
//!       → 200 application/json (the full record line as captured
//!         in the .ndjson payload)
//!       → 404 if the request id isn't indexed
//!
//!   GET /v1/{tenant_id}/count                       (Phase 5.5 a, A2)
//!       → 200 text/plain (decimal record count for the tenant)
//!
//! For step 2 the binary spawns one indexer + one h2 server, both
//! against a `BatchStore` / `IndexDb` the caller wires up. Step 3
//! added the worker-side flush path (`log.backend = s3`) so real
//! traffic populates the bucket. Phase 5.5 a-2 retired
//! `/v1/{tenant_id}/blob/{hash}` and the per-tenant `log-blobs/`
//! store — tape + body bytes now ride inline in the ndjson record
//! (`record.tapes.{kv,date,...}_b64`). The replay UI's existing
//! /show round-trip already returns the bytes it needs, no second
//! fetch.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const log_mod = @import("rove-log");
const batch_store_mod = @import("batch_store.zig");
const index_db_mod = @import("index_db.zig");
const indexer_mod = @import("indexer.zig");
const jwt = @import("rove-jwt");
const plan_mod = @import("rove-plan");
const blob = @import("rove-blob");
const curl = blob.curl;
const zlib = @cImport({
    @cInclude("zlib.h");
});

const LogH2 = h2.H2(.{});

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Where the indexer reads sidecars + ndjson from (and where
    /// /show range-reads the payload).
    store: batch_store_mod.BatchStore,
    /// Local SQLite index. The indexer thread + the h2 server share
    /// one connection — WAL would let us split, but a single thread
    /// owning both is simpler and matches the actual workload (one
    /// indexer + one event loop).
    db: *index_db_mod.IndexDb,
    /// Where to bind the h2 listener. Pass `0` for an ephemeral
    /// port; the resolved port is written to `Handle.port`.
    bind_addr: std.net.Address,
    /// Indexer cadence. Tests override to ~50ms.
    poll_interval_ms: u32 = 5_000,
    /// h2 connection cap.
    max_connections: u32 = 64,
    /// Optional TLS — when set, the listener does TLS termination via
    /// rove-h2's standard path (the `*TlsConfig` is shared with the
    /// worker, both built once by `loop46/main.zig::resolveTls`).
    /// Null = h2c (the standalone binary's smoke driver path).
    tls_config: ?*h2.TlsConfig = null,
    /// Required for `/v1/*` requests — HMAC-SHA256 secret used to
    /// verify the JWT in `Authorization: Bearer <token>`. The worker
    /// mints these tokens at `/_system/log-token` after a session /
    /// bearer-auth check; the dashboard sends them with each
    /// log-server call. When null, every `/v1/*` request returns 401
    /// (lets a smoke spin up a standalone without auth wired).
    jwt_secret: ?[]const u8 = null,
    /// `Access-Control-Allow-Origin` value emitted on every `/v1/*`
    /// response. The dashboard at `https://app.{suffix}` calls the
    /// log-server at `https://logs.{suffix}`, so the browser refuses
    /// the response without a matching CORS header. Null = no CORS
    /// (the standalone binary's loopback smoke path doesn't need it).
    cors_origin: ?[]const u8 = null,
    /// CP base URL (e.g. `http://cp:9090`) for the retention read-clamp
    /// (docs/architecture/control-plane.md Lever 3): each `/v1/{tenant}/list|show|count`
    /// resolves the tenant's plan from `{cp_url}/_cp/plan?tenant=` (cached)
    /// and hides records older than `retention_days`. Null disables the clamp
    /// (the loopback smoke path / single-tenant deploys with no CP) — every
    /// record is returned, as before. Borrowed; caller keeps it alive.
    cp_url: ?[]const u8 = null,
    /// TLS verification for the CP plan fetch. False in dev/smoke clusters
    /// with self-signed internal certs; production leaves it true.
    cp_insecure_tls: bool = false,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    indexer: *indexer_mod.Handle,
    port: u16,
    stop: std.atomic.Value(bool),
    ready: std.Thread.ResetEvent,
    bind_err: ?anyerror,
    config: Config,

    pub fn shutdown(self: *Handle) void {
        self.stop.store(true, .release);
        self.indexer.signalStop();
        self.thread.join();
        self.indexer.join();
        self.allocator.destroy(self);
    }
};

pub fn spawn(config: Config) !*Handle {
    const indexer_handle = try indexer_mod.spawn(.{
        .allocator = config.allocator,
        .store = config.store,
        .db = config.db,
        .poll_interval_ms = config.poll_interval_ms,
    });
    errdefer {
        indexer_handle.signalStop();
        indexer_handle.join();
    }

    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .indexer = indexer_handle,
        .port = 0,
        .stop = .init(false),
        .ready = .{},
        .bind_err = null,
        .config = config,
    };
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    h.ready.wait();
    if (h.bind_err) |err| {
        h.thread.join();
        return err;
    }
    return h;
}

fn threadMain(h: *Handle) void {
    runThread(h) catch |err| {
        std.log.err("rewind-logs: thread exited: {s}", .{@errorName(err)});
    };
}

fn runThread(h: *Handle) !void {
    const allocator = h.allocator;

    var reg = rove.Registry.init(allocator, .{
        .max_entities = 1024,
        .deferred_queue_capacity = 256,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer reg.deinit();

    const server = LogH2.create(&reg, allocator, h.config.bind_addr, .{
        .max_connections = h.config.max_connections,
        .buf_count = 64,
        .buf_size = 64 * 1024,
    }, .{
        .tls_config = h.config.tls_config,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer server.destroy();

    h.port = try resolveBoundPort(server);
    h.ready.set();

    if (h.config.tls_config != null) {
        std.log.info("rewind-logs: h2 (TLS) on port {d}", .{h.port});
    } else {
        std.log.info("rewind-logs: h2c on 127.0.0.1:{d}", .{h.port});
    }

    var retention = RetentionCache.init(allocator);
    defer retention.deinit();

    const rctx: ReqCtx = .{
        .cfg = &h.config,
        .store = h.config.store,
        .db = h.config.db,
        .retention = &retention,
    };

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(server, allocator, rctx);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
}

fn resolveBoundPort(server: *LogH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

fn cleanupResponses(server: *LogH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

// ── Request routing ───────────────────────────────────────────────

const ReqCtx = struct {
    cfg: *const Config,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    retention: *RetentionCache,
};

// ── Retention read-clamp (docs/architecture/control-plane.md Lever 3) ──────────────
//
// The log-query surface enforces the per-tenant retention window by hiding
// records older than `now - retention_days`. `retention_days` comes from the
// tenant's plan, which lives in the CP — so the log-server resolves it from
// `{cp_url}/_cp/plan?tenant=` and caches the window per tenant with a short
// TTL (a CP round-trip per query would be wasteful for an operator-facing,
// low-rate surface). Single-threaded (the server event loop is the sole
// accessor), so no lock.

/// Per-tenant cached retention window (in ns) + when it was fetched.
const RetentionEntry = struct {
    retention_ns: i64,
    fetched_ns: i64,
};

const RetentionCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(RetentionEntry) = .empty,

    /// How long a resolved window stays fresh. A plan change (rare, billing-
    /// driven) takes effect within this window on the query surface.
    const TTL_NS: i64 = 30 * std.time.ns_per_s;

    fn init(allocator: std.mem.Allocator) RetentionCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RetentionCache) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit(self.allocator);
    }

    /// The retention floor (`now_ns - retention_ns`) for `tenant`, or 0 to
    /// disable the clamp. 0 is returned when no CP is configured OR the CP is
    /// unreachable — fail OPEN (show more), the same direction the rate/body
    /// levers fail: a transient CP outage must not hide a paying customer's
    /// data (the data is never deleted, only window-hidden). A definitive 404
    /// from the CP means "unset ⇒ free tier" and DOES clamp.
    fn floorNs(self: *RetentionCache, cfg: *const Config, tenant: []const u8, now_ns: i64) i64 {
        const cp_url = cfg.cp_url orelse return 0; // clamp disabled
        const retention_ns = self.resolveRetentionNs(cfg, cp_url, tenant, now_ns) orelse return 0;
        const floor = now_ns - retention_ns;
        return if (floor > 0) floor else 0;
    }

    /// Cached-or-fetched retention window (ns) for `tenant`. Null ⇒ "couldn't
    /// determine, don't clamp" (CP unreachable). A 404 resolves to the free
    /// tier's window (a real clamp).
    fn resolveRetentionNs(self: *RetentionCache, cfg: *const Config, cp_url: []const u8, tenant: []const u8, now_ns: i64) ?i64 {
        if (self.map.get(tenant)) |e| {
            if (now_ns - e.fetched_ns < TTL_NS) return e.retention_ns;
        }
        const rns = fetchRetentionNs(self.allocator, cp_url, tenant, cfg.cp_insecure_tls) orelse return null;
        // Cache it (best-effort; a put failure just means we refetch next time).
        const gop = self.map.getOrPut(self.allocator, tenant) catch return rns;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, tenant) catch {
                _ = self.map.remove(tenant);
                return rns;
            };
        }
        gop.value_ptr.* = .{ .retention_ns = rns, .fetched_ns = now_ns };
        return rns;
    }
};

/// Fetch + resolve a tenant's retention window (ns) from the CP. 404 ⇒ unset ⇒
/// free tier. Any transport error / non-200-non-404 ⇒ null (don't clamp).
fn fetchRetentionNs(allocator: std.mem.Allocator, cp_url: []const u8, tenant: []const u8, insecure_tls: bool) ?i64 {
    const url = std.fmt.allocPrint(allocator, "{s}/_cp/plan?tenant={s}", .{ cp_url, tenant }) catch return null;
    defer allocator.free(url);
    var easy = curl.Easy.init(allocator) catch return null;
    defer easy.deinit();
    var resp = easy.request(allocator, .{
        .method = .GET,
        .url = url,
        .http_version = .h2c_prior_knowledge,
        .verify_tls = !insecure_tls,
    }) catch return null;
    defer resp.deinit(allocator);
    if (resp.status == 404) return plan_mod.retentionNs(plan_mod.table(.free));
    if (resp.status != 200) return null; // transient / error → don't clamp
    const body = resp.body orelse return null;
    return plan_mod.retentionNs(plan_mod.parseBlob(allocator, body));
}

fn processRequests(
    server: *LogH2,
    allocator: std.mem.Allocator,
    rctx: ReqCtx,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        handleOne(server, allocator, rctx, ent, sid, sess, rh, rb) catch |err| {
            std.log.warn("rewind-logs: handler error: {s}", .{@errorName(err)});
            setResponse(server, ent, sid, sess, 500, "internal error\n", rctx.cfg) catch |se| std.log.err(
                "rewind-logs: 500 write failed: {s}",
                .{@errorName(se)},
            );
        };
    }
}

/// Map a JWT verify failure to a terse 401 body. Shared by the push
/// (plain verify) and read (tenant-scoped verify) gates.
fn jwtErrMsg(err: jwt.Error) []const u8 {
    return switch (err) {
        jwt.Error.Expired => "token expired\n",
        jwt.Error.BadSignature => "bad signature\n",
        jwt.Error.Malformed, jwt.Error.UnsupportedAlg, jwt.Error.InvalidTenant => "malformed token\n",
        jwt.Error.MissingCap, jwt.Error.InvalidCap => "missing required capability\n",
        jwt.Error.WrongTenant => "token not valid for this tenant\n",
        jwt.Error.OutOfMemory => "out of memory\n",
    };
}

fn handleOne(
    server: *LogH2,
    allocator: std.mem.Allocator,
    rctx: ReqCtx,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    rb: h2.ReqBody,
) !void {
    var method: []const u8 = "";
    var path: []const u8 = "";
    var authz: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
            if (std.mem.eql(u8, name, "authorization")) authz = value;
        }
    }

    // CORS preflight from the dashboard's cross-origin fetch. Browser
    // sends `OPTIONS` before any GET that carries a custom header
    // (Authorization counts). Reply 204 with the allow-set; the real
    // request follows on the same connection.
    if (std.mem.eql(u8, method, "OPTIONS")) {
        try setPreflight(server, ent, sid, sess, rctx.cfg);
        return;
    }
    const is_push = std.mem.eql(u8, method, "POST") and
        std.mem.eql(u8, path, "/v1/_internal/batch-pushed");
    if (!std.mem.eql(u8, method, "GET") and !is_push) {
        try setResponse(server, ent, sid, sess, 405, "method not allowed\n", rctx.cfg);
        return;
    }

    // Liveness probe for load balancers / systemd-style supervisors.
    // No auth — health probes don't carry the services JWT. Always
    // 200 on a running listener; the request never reaches this
    // branch if the process is wedged.
    if (std.mem.eql(u8, path, "/v1/health")) {
        try setResponse(server, ent, sid, sess, 200, "ok\n", rctx.cfg);
        return;
    }

    // JWT gate. Two shapes, by route:
    //   • READ routes (`/v1/{tenant}/list|count|show`) require a
    //     TENANT-SCOPED `logs-read` capability token —
    //     `verifyWithCapAndTenant` rejects an unscoped ("any tenant")
    //     token AND a token scoped to a different tenant. This is the
    //     chokepoint guarantee (rewind-cli-plan.md §7; step3-auth-plan.md
    //     A4): the worker's fetch engine mints the scoped token when it
    //     rewrites the `rewind-logs.internal` host the `__admin__`
    //     chokepoint issues. Closes the audit's open latent-critical —
    //     the old "trusts `exp`, treats every token as any-tenant" gap is
    //     deleted, not patched.
    //   • The worker→log-server batch PUSH (`/v1/_internal/batch-pushed`)
    //     is inherently multi-tenant ingestion (one S3 flush interleaves
    //     tenants), so it can't be tenant-scoped; it takes a plain
    //     signature+expiry verify. TODO(step3): give the push path its own
    //     `logs-push` cap so a read token can't drive ingestion.
    const secret = rctx.cfg.jwt_secret orelse {
        try setResponse(server, ent, sid, sess, 401, "auth not configured\n", rctx.cfg);
        return;
    };
    if (!std.mem.startsWith(u8, authz, "Bearer ")) {
        try setResponse(server, ent, sid, sess, 401, "missing bearer token\n", rctx.cfg);
        return;
    }
    const token = authz["Bearer ".len..];
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    // Worker → log-server push: indexer fetches the named batch
    // directly without waiting for the LIST polling cycle to catch
    // up. See `indexer.indexOneKey` for the why. Plain verify (see above).
    if (is_push) {
        _ = jwt.verify(secret, token, now_ms) catch |err| {
            try setResponse(server, ent, sid, sess, 401, jwtErrMsg(err), rctx.cfg);
            return;
        };
        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else "";
        try handleBatchPushed(server, allocator, rctx, ent, sid, sess, body);
        return;
    }

    // Read route — parse first so the tenant is in hand for the
    // tenant-scoped verify below.
    const route = parseRoute(path) orelse {
        try setResponse(server, ent, sid, sess, 404, "not found\n", rctx.cfg);
        return;
    };
    _ = jwt.verifyWithCapAndTenant(secret, token, now_ms, jwt.Cap.LOGS_READ, route.tenant_id) catch |err| {
        try setResponse(server, ent, sid, sess, 401, jwtErrMsg(err), rctx.cfg);
        return;
    };
    // Retention read-clamp (docs/architecture/control-plane.md Lever 3): resolve the tenant's
    // window from the CP (cached) and hide records older than it. 0 ⇒ no clamp
    // (CP not configured / unreachable).
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const floor_ns = rctx.retention.floorNs(rctx.cfg, route.tenant_id, now_ns);
    switch (route.kind) {
        .list => {
            const tf = parseTagFilter(route.query);
            try handleList(server, allocator, rctx.db, ent, sid, sess, route.tenant_id, route.query, floor_ns, rctx.cfg, if (tf) |t| t.key else null, if (tf) |t| t.value else null);
        },
        // Replay sugar: list this session's activations, newest-first.
        // `/session/{id}` ≡ `/list?tag.session={id}`.
        .session => try handleList(server, allocator, rctx.db, ent, sid, sess, route.tenant_id, route.query, floor_ns, rctx.cfg, "session", route.tail),
        .show => try handleShow(server, allocator, rctx.store, rctx.db, ent, sid, sess, route.tenant_id, route.tail, floor_ns, rctx.cfg),
        .count => try handleCount(server, allocator, rctx.db, ent, sid, sess, route.tenant_id, floor_ns, rctx.cfg),
    }
}

/// Body is one or more newline-separated batch keys. We index each
/// in turn; any failure is logged but doesn't fail the whole request
/// — LIST polling is the catch-up for anything we drop.
fn handleBatchPushed(
    server: *LogH2,
    allocator: std.mem.Allocator,
    rctx: ReqCtx,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    body: []const u8,
) !void {
    if (body.len == 0) {
        try setResponse(server, ent, sid, sess, 400, "empty body — expected newline-separated batch keys\n", rctx.cfg);
        return;
    }

    var it = std.mem.splitScalar(u8, body, '\n');
    var seen: usize = 0;
    while (it.next()) |raw| {
        const key = std.mem.trim(u8, raw, " \r\t");
        if (key.len == 0) continue;
        seen += 1;
        // Sanity: only accept keys that look like log batches. Prevents
        // an attacker (already past the JWT gate) from probing arbitrary
        // S3 keys via this endpoint.
        if (!std.mem.startsWith(u8, key, "_logs/") or
            !std.mem.endsWith(u8, key, ".ndjson"))
        {
            std.log.warn("log-server: rejecting bad batch key shape: {s}", .{key});
            continue;
        }
        _ = indexer_mod.indexOneKey(allocator, rctx.store, rctx.db, key) catch |err| {
            std.log.warn(
                "log-server: indexOneKey {s}: {s}",
                .{ key, @errorName(err) },
            );
            continue;
        };
    }
    if (seen == 0) {
        try setResponse(server, ent, sid, sess, 400, "no batch keys in body\n", rctx.cfg);
        return;
    }
    try setResponse(server, ent, sid, sess, 204, "", rctx.cfg);
}

const RouteKind = enum { list, show, count, session };

const ParsedRoute = struct {
    kind: RouteKind,
    tenant_id: []const u8,
    /// For `show`: the request_id segment. For `session`: the session
    /// id (filters `tag.session`). Empty otherwise.
    tail: []const u8,
    /// Raw query string (after `?`). Empty if absent.
    query: []const u8,
};

/// `/v1/{tenant_id}/list[?...]`, `/v1/{tenant_id}/show/{request_id}`,
/// `/v1/{tenant_id}/count`, or `/v1/{tenant_id}/session/{session_id}`
/// (replay sugar for `list?tag.session={session_id}`). Returns null on
/// shape mismatch (caller responds 404).
fn parseRoute(path: []const u8) ?ParsedRoute {
    const q_idx = std.mem.indexOfScalar(u8, path, '?');
    const path_no_query = if (q_idx) |i| path[0..i] else path;
    const query = if (q_idx) |i| path[i + 1 ..] else "";

    const v1_prefix = "/v1/";
    if (!std.mem.startsWith(u8, path_no_query, v1_prefix)) return null;
    const after_v1 = path_no_query[v1_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, after_v1, '/') orelse return null;
    const tenant_id = after_v1[0..slash];
    if (tenant_id.len == 0) return null;
    const remainder = after_v1[slash + 1 ..];

    if (std.mem.eql(u8, remainder, "list")) {
        return .{ .kind = .list, .tenant_id = tenant_id, .tail = "", .query = query };
    }
    if (std.mem.eql(u8, remainder, "count")) {
        return .{ .kind = .count, .tenant_id = tenant_id, .tail = "", .query = query };
    }
    if (std.mem.startsWith(u8, remainder, "show/")) {
        const tail = remainder["show/".len..];
        if (tail.len == 0) return null;
        return .{ .kind = .show, .tenant_id = tenant_id, .tail = tail, .query = query };
    }
    if (std.mem.startsWith(u8, remainder, "session/")) {
        const tail = remainder["session/".len..];
        if (tail.len == 0) return null;
        return .{ .kind = .session, .tenant_id = tenant_id, .tail = tail, .query = query };
    }
    return null;
}

/// Extract a single `tag.<key>=<value>` filter from the query string,
/// if present. Returns the (key, value) borrowing into `query`, or null
/// when no `tag.` param is present. Only the first is honored — one tag
/// filter per query keeps the index plan simple (multi-tag AND can be
/// added when a customer needs it). The `<value>` is NOT percent-decoded
/// here; low-cardinality tag values are `[a-z0-9_]`-shaped by convention.
fn parseTagFilter(query: []const u8) ?struct { key: []const u8, value: []const u8 } {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (!std.mem.startsWith(u8, pair, "tag.")) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair["tag.".len..eq];
        const value = pair[eq + 1 ..];
        if (key.len == 0 or value.len == 0) continue;
        return .{ .key = key, .value = value };
    }
    return null;
}

// ── Handlers ──────────────────────────────────────────────────────

fn handleList(
    server: *LogH2,
    allocator: std.mem.Allocator,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    query: []const u8,
    floor_received_ns: i64,
    cfg: *const Config,
    /// Optional `tag.<key>=<value>` filter (or `"session"` + the id for
    /// the `/session/{id}` sugar route). Null → unfiltered list.
    tag_key: ?[]const u8,
    tag_value: ?[]const u8,
) !void {
    const limit = parseUint(u32, query, "limit", 100);
    const after_received_ns = parseInt(i64, query, "after_received_ns", 0);
    // The cursor is the opaque `req_<16hex>` token from `next_cursor`
    // (§7.5). Tolerate a bare-hex/missing value (→ 0, the unfiltered
    // start) so a hand-built or truncated cursor degrades to "from the
    // top" rather than erroring.
    const after_request_id: u64 = if (queryStr(query, "after_request_id")) |s|
        (log_mod.parsePrefixedId(log_mod.REQUEST_ID_PREFIX, s) orelse 0)
    else
        0;

    var list = db.queryList(tenant_id, after_received_ns, after_request_id, floor_received_ns, limit, tag_key, tag_value) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "list failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer list.deinit();

    const json = try renderListJson(allocator, list.rows);
    try setResponseOwned(server, ent, sid, sess, 200, json, cfg);
}

fn handleShow(
    server: *LogH2,
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    request_id_str: []const u8,
    floor_received_ns: i64,
    cfg: *const Config,
) !void {
    // The path segment is the opaque `req_<16hex>` token (§7.5) — the
    // same form `/list` and `request.actor.request_id` hand out.
    const request_id = log_mod.parsePrefixedId(log_mod.REQUEST_ID_PREFIX, request_id_str) orelse {
        try setResponse(server, ent, sid, sess, 400, "invalid request id (want req_<16hex>)\n", cfg);
        return;
    };
    var maybe = db.queryShow(tenant_id, request_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "show failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    if (maybe == null) {
        try setResponse(server, ent, sid, sess, 404, "record not found\n", cfg);
        return;
    }
    defer maybe.?.deinit(allocator);
    const row = maybe.?;

    // Retention read-clamp (Lever 3): a record older than the tenant's window
    // is 404 — same as if it never existed. The clamp is a billing boundary,
    // so a direct /show must not bypass what /list hides.
    if (floor_received_ns != 0 and row.received_ns < floor_received_ns) {
        try setResponse(server, ent, sid, sess, 404, "record not found\n", cfg);
        return;
    }

    // Range-read the compressed frame out of the batch payload.
    // Each record is its own raw-deflate stream; the sidecar's
    // `(offset, length)` brackets exactly one frame.
    const payload = store.getRange(row.ndjson_key, row.offset, row.length, allocator) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "payload fetch failed for {s}: {s}\n",
            .{ row.ndjson_key, @errorName(err) },
        );
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer allocator.free(payload);

    const decompressed = decompressRawDeflate(allocator, payload) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "frame decompress failed for {s}: {s}\n",
            .{ row.ndjson_key, @errorName(err) },
        );
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer allocator.free(decompressed);

    // Wrap in `{record: ...}` so callers can branch on shape later
    // (e.g. error responses).
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"record\":");
    try buf.appendSlice(allocator, decompressed);
    try buf.appendSlice(allocator, "}\n");
    const out = try buf.toOwnedSlice(allocator);
    try setResponseOwned(server, ent, sid, sess, 200, out, cfg);
}

/// Decode one raw-deflate frame (the per-record framing the worker
/// emits, see `flush_writer.DeflateStream.appendFrame`). Uses libz
/// directly — keeps both ends of the wire format on the same
/// implementation (Zig stdlib's `flate.Compress` is incomplete in
/// 0.15.x; see `feedback`/memory). The full decompressed JSON is
/// small (≤ a few hundred KB after the 256 KB body cap) so we grow
/// the output buffer in chunks rather than streaming.
fn decompressRawDeflate(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var z: zlib.z_stream = std.mem.zeroes(zlib.z_stream);
    // -15 = raw deflate window, matches the writer side.
    if (zlib.inflateInit2_(
        &z,
        -15,
        zlib.zlibVersion(),
        @sizeOf(zlib.z_stream),
    ) != zlib.Z_OK) return error.InflateInit;
    defer _ = zlib.inflateEnd(&z);

    z.next_in = @constCast(src.ptr);
    z.avail_in = @intCast(src.len);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Initial guess: 4× compressed size, grown in 64 KB chunks if
    // we underestimate. JSON-of-base64 typically deflates 4-6×.
    var capacity: usize = @max(src.len * 4, 4096);
    try out.ensureTotalCapacity(allocator, capacity);
    out.items.len = capacity;
    var written: usize = 0;
    while (true) {
        z.next_out = out.items[written..].ptr;
        z.avail_out = @intCast(capacity - written);
        const rc = zlib.inflate(&z, zlib.Z_NO_FLUSH);
        written = capacity - z.avail_out;
        if (rc == zlib.Z_STREAM_END) break;
        if (rc != zlib.Z_OK) return error.InflateBadData;
        // Need more space — grow.
        capacity += 64 * 1024;
        try out.ensureTotalCapacity(allocator, capacity);
        out.items.len = capacity;
    }
    out.items.len = written;
    return out.toOwnedSlice(allocator);
}

/// Total record count for a tenant (Phase 5.5 a, A2). Plain decimal
/// body (`{count}\n`) so a shell pipeline can `wc`/`grep` it without
/// pulling in jq. Backed by `IndexDb.queryCount` — covering scan on
/// the (tenant_id, received_ns) primary index, cheap.
fn handleCount(
    server: *LogH2,
    allocator: std.mem.Allocator,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    floor_received_ns: i64,
    cfg: *const Config,
) !void {
    const total = db.queryCount(tenant_id, floor_received_ns) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "count failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{total});
    try setResponseOwned(server, ent, sid, sess, 200, body, cfg);
}

// ── JSON rendering ─────────────────────────────────────────────────

fn renderListJson(
    allocator: std.mem.Allocator,
    rows: []index_db_mod.IndexDb.ListRow,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"records\":[");
    for (rows, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeRowJson(allocator, &buf, &r);
    }
    if (rows.len == 0) {
        try buf.appendSlice(allocator, "],\"next_cursor\":null}\n");
    } else {
        const last = &rows[rows.len - 1];
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = aw.toArrayList();
        // Hand back the cursor request_id as the opaque prefixed token the
        // client passes verbatim to `?after_request_id=` (§7.5).
        var cur_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
        const cur_rid = log_mod.formatPrefixedId(&cur_buf, log_mod.REQUEST_ID_PREFIX, last.request_id);
        try aw.writer.print(
            "],\"next_cursor\":{{\"received_ns\":{d},\"request_id\":\"{s}\"}}}}\n",
            .{ last.received_ns, cur_rid },
        );
    }
    return buf.toOwnedSlice(allocator);
}

fn writeRowJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    r: *const index_db_mod.IndexDb.ListRow,
) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, buf);
    defer buf.* = aw.toArrayList();
    // Customer-visible ids as opaque prefixed tokens (§7.5).
    var rid_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
    var dep_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
    const rid = log_mod.formatPrefixedId(&rid_buf, log_mod.REQUEST_ID_PREFIX, r.request_id);
    const dep = log_mod.formatPrefixedId(&dep_buf, log_mod.DEPLOYMENT_ID_PREFIX, r.deployment_id);
    try aw.writer.print(
        "{{\"request_id\":\"{s}\",\"received_ns\":{d},\"duration_ns\":{d},\"status\":{d},\"deployment_id\":\"{s}\",\"method\":",
        .{ rid, r.received_ns, r.duration_ns, r.status, dep },
    );
    try writeJsonString(&aw.writer, r.method);
    try aw.writer.writeAll(",\"path\":");
    try writeJsonString(&aw.writer, r.path);
    try aw.writer.writeAll(",\"host\":");
    try writeJsonString(&aw.writer, r.host);
    try aw.writer.writeAll(",\"outcome\":");
    try writeJsonString(&aw.writer, r.outcome);
    try aw.writer.writeAll("}");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

// ── Helpers ───────────────────────────────────────────────────────

const HdrPair = struct { name: []const u8, value: []const u8 };

/// Pack a flat list of header pairs into an `h2.RespHeaders`. The
/// h2 writer frees the underlying allocation when the response
/// finishes. Returns an empty set when `pairs` is empty.
fn packHeaders(allocator: std.mem.Allocator, pairs: []const HdrPair) !h2.RespHeaders {
    if (pairs.len == 0) return .{ .fields = null, .count = 0 };
    const fields_size = pairs.len * @sizeOf(h2.HeaderField);
    var str_size: usize = 0;
    for (pairs) |p| str_size += p.name.len + p.value.len;

    const buf = try allocator.alloc(u8, fields_size + str_size);
    errdefer allocator.free(buf);
    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    for (pairs, 0..) |p, i| {
        const name_start = off;
        @memcpy(buf[off..][0..p.name.len], p.name);
        off += p.name.len;
        const value_start = off;
        @memcpy(buf[off..][0..p.value.len], p.value);
        off += p.value.len;
        fields_ptr[i] = .{
            .name = buf[name_start..].ptr,
            .name_len = @intCast(p.name.len),
            .value = buf[value_start..].ptr,
            .value_len = @intCast(p.value.len),
        };
    }
    return .{ .fields = fields_ptr, .count = @intCast(pairs.len) };
}

/// Stamp a response with optional CORS + content-type. Static literal
/// body bytes are NOT framed (rove-h2 reads from `data`); the helper
/// passes `data = null, len = body.len` so the writer treats it as a
/// short canned response.
fn setResponse(
    server: *LogH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_static: []const u8,
    cfg: *const Config,
) !void {
    const headers = try buildResponseHeaders(server.reg.allocator, cfg, null);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, headers);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = null,
        .len = @intCast(body_static.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn setResponseOwned(
    server: *LogH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_owned: []u8,
    cfg: *const Config,
) !void {
    const headers = try buildResponseHeaders(server.reg.allocator, cfg, null);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, headers);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_owned.ptr,
        .len = @intCast(body_owned.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// CORS preflight response — 204 with the full allow-set so the
/// browser caches the policy for `max-age` seconds. Body is empty.
fn setPreflight(
    server: *LogH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cfg: *const Config,
) !void {
    const headers = try buildResponseHeaders(server.reg.allocator, cfg, .preflight);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 204 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, headers);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

const ResponseKind = enum { normal, preflight };

/// Builds the CORS header set used by every response. When
/// `cfg.cors_origin` is null (loopback / smoke), returns an empty
/// header set. Preflight responses additionally carry
/// allow-methods + allow-headers + max-age so the browser can cache
/// the policy.
fn buildResponseHeaders(allocator: std.mem.Allocator, cfg: *const Config, kind: ?ResponseKind) !h2.RespHeaders {
    const origin = cfg.cors_origin orelse return .{ .fields = null, .count = 0 };
    var pairs: [5]HdrPair = undefined;
    var n: usize = 0;
    pairs[n] = .{ .name = "access-control-allow-origin", .value = origin };
    n += 1;
    pairs[n] = .{ .name = "vary", .value = "origin" };
    n += 1;
    if (kind == .preflight) {
        pairs[n] = .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" };
        n += 1;
        pairs[n] = .{ .name = "access-control-allow-headers", .value = "authorization" };
        n += 1;
        pairs[n] = .{ .name = "access-control-max-age", .value = "600" };
        n += 1;
    }
    return packHeaders(allocator, pairs[0..n]);
}

fn parseUint(comptime T: type, query: []const u8, key: []const u8, default: T) T {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return std.fmt.parseInt(T, pair[eq + 1 ..], 10) catch default;
    }
    return default;
}

/// Raw string value of a query key, or null if absent. Used for the
/// `after_request_id` cursor, which is the opaque `req_<16hex>` token we
/// handed out in `next_cursor` (§7.5), not a bare integer.
fn queryStr(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return pair[eq + 1 ..];
    }
    return null;
}

fn parseInt(comptime T: type, query: []const u8, key: []const u8, default: T) T {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return std.fmt.parseInt(T, pair[eq + 1 ..], 10) catch default;
    }
    return default;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseRoute matches /v1/{tenant}/list" {
    const r = parseRoute("/v1/acme/list?limit=10").?;
    try testing.expectEqual(RouteKind.list, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("limit=10", r.query);
}

test "parseRoute matches /v1/{tenant}/show/{id}" {
    const r = parseRoute("/v1/acme/show/12345").?;
    try testing.expectEqual(RouteKind.show, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("12345", r.tail);
}

test "parseRoute matches /v1/{tenant}/count" {
    const r = parseRoute("/v1/acme/count").?;
    try testing.expectEqual(RouteKind.count, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("", r.tail);
}

test "parseRoute matches /v1/{tenant}/session/{id}" {
    const r = parseRoute("/v1/acme/session/abc-123?limit=20").?;
    try testing.expectEqual(RouteKind.session, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("abc-123", r.tail);
    try testing.expectEqualStrings("limit=20", r.query);
    // Empty session id is a 404 (no tail).
    try testing.expect(parseRoute("/v1/acme/session/") == null);
}

test "parseTagFilter pulls a tag.k=v from the query" {
    const tf = parseTagFilter("limit=20&tag.session=s1&after_received_ns=5").?;
    try testing.expectEqualStrings("session", tf.key);
    try testing.expectEqualStrings("s1", tf.value);
    try testing.expect(parseTagFilter("limit=20") == null);
    try testing.expect(parseTagFilter("tag.=v") == null);
    try testing.expect(parseTagFilter("tag.k=") == null);
}

test "parseRoute rejects bad shapes" {
    try testing.expect(parseRoute("/") == null);
    try testing.expect(parseRoute("/v1/") == null);
    try testing.expect(parseRoute("/v1/acme") == null);
    try testing.expect(parseRoute("/v1/acme/unknown") == null);
    try testing.expect(parseRoute("/v1//list") == null);
    try testing.expect(parseRoute("/v1/acme/show/") == null);
    try testing.expect(parseRoute("/v2/acme/list") == null);
}

test "parseUint reads ?limit= or returns default" {
    try testing.expectEqual(@as(u32, 10), parseUint(u32, "limit=10", "limit", 100));
    try testing.expectEqual(@as(u32, 100), parseUint(u32, "", "limit", 100));
    try testing.expectEqual(@as(u32, 100), parseUint(u32, "after=5", "limit", 100));
    try testing.expectEqual(@as(u32, 7), parseUint(u32, "after=5&limit=7", "limit", 100));
}
