// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Standalone log-server — combines the background indexer thread +
//! an h2 query API in one process.
//!
//! Reachable at `logs.{public_suffix}` with TLS + JWT handoff. The
//! wire shape follows the log-server query surface
//! (`docs/architecture/deployment-and-logs.md`):
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
//!   GET /v1/{tenant_id}/count
//!       → 200 text/plain (decimal record count for the tenant)
//!
//! The binary spawns one indexer + one h2 server, both against a
//! `BatchStore` / `IndexDb` the caller wires up. The worker-side
//! flush path (`log.backend = s3`) is what populates the bucket.
//! There is no `/v1/{tenant_id}/blob/{hash}` endpoint and no
//! per-tenant `log-blobs/` store — tape + body bytes ride inline in
//! the ndjson record (`record.tapes.{kv,date,...}_b64`). The replay
//! UI's /show round-trip returns the bytes it needs, no second
//! fetch.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const log_mod = @import("rove-log");
const batch_store_mod = @import("batch_store.zig");
const index_db_mod = @import("index_db.zig");
const seam_mod = @import("seam.zig");
const body_ref_mod = @import("body_ref.zig");
const indexer_mod = @import("indexer.zig");
const metrics_mod = @import("metrics.zig");
const jwt = @import("rove-jwt");
const plan_mod = @import("rove-plan");
const blob = @import("rove-blob");
const curl = blob.curl;
const zlib = @cImport({
    @cInclude("zlib.h");
});

const log_h2_opts = h2.Options{ .registry_model = .fat };

/// The log server's world, declared by the module that instantiates it
/// (explicit `.world`, not the root `rove_world` pattern): this module
/// also compiles inside test builds, whose root declares nothing.
pub const LogWorld = rove.World(.{ .parts = h2.parts(log_h2_opts) });

const LogH2 = h2.H2(.{ .registry_model = .fat, .world = LogWorld });

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Where the indexer reads sidecars + ndjson from (and where
    /// /show range-reads the payload).
    store: batch_store_mod.BatchStore,
    /// Local SQLite index — the **writer** connection. Used by the
    /// indexer thread (`pollOnce`) and by the h2 server thread for the
    /// push path (`/v1/_internal/batch-pushed` → `indexOneKey`). Two
    /// threads, so it's FULLMUTEX (see `index_db.IndexDb`).
    db: *index_db_mod.IndexDb,
    /// Second connection to the same WAL file — the **reader**, used by
    /// the h2 server thread for the query surface (/list, /show,
    /// /count) so reads get their own snapshot and never wait on the
    /// writer's connection mutex during an `insertBatch`.
    read_db: *index_db_mod.IndexDb,
    /// Where to bind the h2 listener. Pass `0` for an ephemeral
    /// port; the resolved port is written to `Handle.port`.
    bind_addr: std.net.Address,
    /// Indexer cadence. Tests override to ~50ms.
    poll_interval_ms: u32 = 5_000,
    /// h2 connection cap.
    max_connections: u32 = 64,
    /// Object store for out-of-line PAYLOAD bytes — the body pool and the
    /// tenants' content-addressed blobs. A DIFFERENT store from `store`,
    /// and deliberately so: log batches are prefixed by
    /// `LOG_S3_KEY_PREFIX` while `_pool/` and `{tenant}/app-blobs/` sit
    /// under `S3_KEY_PREFIX_BASE`, so one handle cannot reach both. Null
    /// disables `/v1/{tenant}/body/...`, which then reports that the
    /// payload is unreachable rather than serving an empty body.
    content_store: ?batch_store_mod.BatchStore = null,
    /// Optional TLS — when set, the listener does TLS termination via
    /// rove-h2's standard path. The `rewind-logs` binary builds this
    /// from its own `--tls-cert` / `--tls-key` flags (`main.zig`); it
    /// is NOT shared with the worker, which serves h2c on the private
    /// plane. Null = h2c (the deployed shape, and the smoke path).
    tls_config: ?*h2.TlsConfig = null,
    /// Required for `/v1/*` requests — HMAC-SHA256 secret used to
    /// verify the JWT in `Authorization: Bearer <token>`. The worker's
    /// fetch engine mints these as tenant-scoped `logs-read` tokens
    /// when it rewrites the privileged `rewind-logs.internal` host
    /// (`docs/architecture/cli-and-deploy.md` §7), so a token can only
    /// read the tenant it was minted for. When null, every `/v1/*`
    /// request returns 401 (lets a smoke spin up a standalone without
    /// auth wired).
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

    var reg = LogH2.Reg.init(allocator, .{
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
        .read_db = h.config.read_db,
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
    for (entities) |ent| try server.destroyEntity(ent);
}

// ── Request routing ───────────────────────────────────────────────

const ReqCtx = struct {
    cfg: *const Config,
    store: batch_store_mod.BatchStore,
    /// Writer connection — used only by the push path on this thread.
    db: *index_db_mod.IndexDb,
    /// Reader connection — used by the /list, /show, /count handlers.
    read_db: *index_db_mod.IndexDb,
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
/// the tenant's default tier. Any transport error / non-200-non-404 ⇒ null
/// (don't clamp).
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
    if (resp.status == 404) return plan_mod.retentionNs(plan_mod.defaultFor(tenant));
    if (resp.status != 200) return null; // transient / error → don't clamp
    const body = resp.body orelse return null;
    return plan_mod.retentionNs(plan_mod.parseBlob(allocator, tenant, body));
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
        // Named separately from "malformed": the token is well-formed and
        // correctly signed, and the fault is that THIS binary is older than
        // the one that minted it. An operator chasing a 401 during a rolling
        // deploy needs that sentence, not a generic one.
        jwt.Error.UnsupportedVersion => "token claims-schema version not supported by this build\n",
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
    //     chokepoint guarantee (docs/architecture/cli-and-deploy.md §7; docs/architecture/auth-consolidation.md
    //     A4): the worker's fetch engine mints the scoped token when it
    //     rewrites the `rewind-logs.internal` host the `__admin__`
    //     chokepoint issues.
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
            metrics_mod.Metrics.inc(&metrics_mod.global.query_list);
            const tf = parseTagFilter(route.query);
            // Decode the tag VALUE so `?tag._saga={id}` and `/saga/{id}`
            // resolve the same stored bytes — saga ids are arbitrary
            // ≤256-byte header bytes and browser clients send them
            // percent-encoded (URLSearchParams / encodeURIComponent).
            // Conventional `[a-z0-9_]` tag values decode to themselves.
            var tagv_buf: [MAX_PATH_FILTER]u8 = undefined;
            const tag_value: ?[]const u8 = if (tf) |t|
                (percentDecode(&tagv_buf, t.value) orelse {
                    try setResponse(server, ent, sid, sess, 400, "invalid tag value (bad percent-encoding or > 256 bytes)\n", rctx.cfg);
                    return;
                })
            else
                null;
            try handleList(server, allocator, rctx.read_db, ent, sid, sess, route.tenant_id, route.query, floor_ns, rctx.cfg, if (tf) |t| t.key else null, tag_value);
        },
        // Replay sugar: list this session's activations, newest-first.
        // `/session/{id}` ≡ `/list?tag.session={id}`.
        .session => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_list);
            try handleList(server, allocator, rctx.read_db, ent, sid, sess, route.tenant_id, route.query, floor_ns, rctx.cfg, "session", route.tail);
        },
        .show => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_show);
            try handleShow(server, allocator, rctx.store, rctx.read_db, ent, sid, sess, route.tenant_id, route.tail, floor_ns, rctx.cfg);
        },
        .count => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_count);
            try handleCount(server, allocator, rctx.read_db, ent, sid, sess, route.tenant_id, floor_ns, rctx.cfg);
        },
        .window => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_list);
            try handleWindow(server, allocator, rctx.read_db, ent, sid, sess, route.tenant_id, route.query, floor_ns, rctx.cfg);
        },
        .saga => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_list);
            try handleSaga(server, allocator, rctx.read_db, ent, sid, sess, route.tenant_id, route.tail, route.query, floor_ns, rctx.cfg);
        },
        .seam => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_show);
            try handleSeam(server, allocator, rctx.store, rctx.read_db, ent, sid, sess, route.tenant_id, route.query, floor_ns, rctx.cfg);
        },
        .body => {
            metrics_mod.Metrics.inc(&metrics_mod.global.query_body);
            try handleBody(server, allocator, rctx.store, rctx.read_db, ent, sid, sess, route.tenant_id, route.tail, floor_ns, rctx.cfg);
        },
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
        metrics_mod.Metrics.inc(&metrics_mod.global.push_received);
        if (!std.mem.startsWith(u8, key, "_logs/") or
            !std.mem.endsWith(u8, key, ".ndjson"))
        {
            std.log.warn("log-server: rejecting bad batch key shape: {s}", .{key});
            metrics_mod.Metrics.inc(&metrics_mod.global.push_errors);
            continue;
        }
        _ = indexer_mod.indexOneKey(allocator, rctx.store, rctx.db, key) catch |err| {
            std.log.warn(
                "log-server: indexOneKey {s}: {s}",
                .{ key, @errorName(err) },
            );
            metrics_mod.Metrics.inc(&metrics_mod.global.push_errors);
            continue;
        };
        metrics_mod.Metrics.inc(&metrics_mod.global.push_indexed);
    }
    if (seen == 0) {
        try setResponse(server, ent, sid, sess, 400, "no batch keys in body\n", rctx.cfg);
        return;
    }
    try setResponse(server, ent, sid, sess, 204, "", rctx.cfg);
}

const RouteKind = enum { list, show, count, session, window, saga, seam, body };

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
/// `/v1/{tenant_id}/count`, `/v1/{tenant_id}/session/{session_id}`
/// (replay sugar for `list?tag.session={session_id}`),
/// `/v1/{tenant_id}/window[?...]` (the execution-tape view — ascending
/// by `exec_seq`), or `/v1/{tenant_id}/saga/{saga_id}[?...]` (one
/// saga's window: roll-up + hops + gap summaries). Returns null on
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
    if (std.mem.eql(u8, remainder, "window")) {
        return .{ .kind = .window, .tenant_id = tenant_id, .tail = "", .query = query };
    }
    if (std.mem.eql(u8, remainder, "seam")) {
        return .{ .kind = .seam, .tenant_id = tenant_id, .tail = "", .query = query };
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
    if (std.mem.startsWith(u8, remainder, "saga/")) {
        const tail = remainder["saga/".len..];
        if (tail.len == 0) return null;
        return .{ .kind = .saga, .tenant_id = tenant_id, .tail = tail, .query = query };
    }
    if (std.mem.startsWith(u8, remainder, "body/")) {
        const tail = remainder["body/".len..];
        if (tail.len == 0) return null;
        return .{ .kind = .body, .tenant_id = tenant_id, .tail = tail, .query = query };
    }
    return null;
}

/// The three segments of a `/body/` tail: `{request_id}/{channel}/{index}`.
/// Split here rather than in the handler so the shape is testable without
/// an h2 server, and so a malformed address is one `null` rather than
/// three scattered guards.
const BodyAddr = struct {
    request_id: u64,
    channel: body_ref_mod.Channel,
    index: u32,
};

fn parseBodyTail(tail: []const u8) ?BodyAddr {
    var it = std.mem.splitScalar(u8, tail, '/');
    const id_str = it.next() orelse return null;
    const chan_str = it.next() orelse return null;
    const idx_str = it.next() orelse return null;
    if (it.next() != null) return null; // trailing junk — not our address
    const request_id = log_mod.parsePrefixedId(log_mod.REQUEST_ID_PREFIX, id_str) orelse
        return null;
    const channel = body_ref_mod.Channel.fromPath(chan_str) orelse return null;
    const index = std.fmt.parseInt(u32, idx_str, 10) catch return null;
    return .{ .request_id = request_id, .channel = channel, .index = index };
}

/// Extract a single `tag.<key>=<value>` filter from the query string,
/// if present. Returns the (key, value) borrowing into `query`, or null
/// when no `tag.` param is present. Only the first is honored — one tag
/// filter per query keeps the index plan simple (multi-tag AND can be
/// added when a customer needs it). The `<value>` is returned RAW; the
/// route dispatch percent-decodes it before matching, so this filter
/// and the `/saga/{id}` path segment resolve the same stored bytes.
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

    // Column filters. Unlike the cursor these do NOT degrade on a bad
    // value: a mistyped filter silently ignored returns unfiltered rows
    // PRESENTED as filtered — worse than an error for "find my request".
    var filter: index_db_mod.IndexDb.ListFilter = .{};
    if (queryStr(query, "status")) |s| {
        const range = parseStatusFilter(s) orelse {
            try setResponse(server, ent, sid, sess, 400, "invalid status filter (want NNN or Nxx)\n", cfg);
            return;
        };
        filter.status_min = range[0];
        filter.status_max = range[1];
    }
    if (queryStr(query, "failures")) |s| {
        if (!std.mem.eql(u8, s, "1")) {
            try setResponse(server, ent, sid, sess, 400, "invalid failures filter (want failures=1)\n", cfg);
            return;
        }
        filter.failures_only = true;
    }
    // An empty value (`?method=`) is a cleared control, not a filter
    // that matches nothing — treat it as absent.
    filter.method = nonEmpty(queryStr(query, "method"));
    filter.activation = nonEmpty(queryStr(query, "activation"));
    // The path term arrives percent-encoded (the dashboard uses
    // URLSearchParams, which encodes `/`); decode before matching
    // against the stored raw path.
    var path_buf: [MAX_PATH_FILTER]u8 = undefined;
    if (nonEmpty(queryStr(query, "path"))) |s| {
        filter.path_contains = percentDecode(&path_buf, s) orelse {
            try setResponse(server, ent, sid, sess, 400, "invalid path filter (bad percent-encoding or > 256 bytes)\n", cfg);
            return;
        };
    }

    var list = db.queryList(tenant_id, after_received_ns, after_request_id, floor_received_ns, limit, tag_key, tag_value, filter) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "list failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer list.deinit();

    const json = try renderRowsJson(allocator, list.rows, .time);
    try setResponseOwned(server, ent, sid, sess, 200, json, cfg);
}

/// The execution-tape window: records ordered ASCENDING by `exec_seq`
/// (execution order — the order that survives leader failover, unlike
/// `/list`'s wall-clock view). Params, all decimal integers:
/// `seq_from` (inclusive lower bound), `seq_to` (inclusive upper bound,
/// 0/absent = unbounded), `after_seq` (keyset cursor — strictly after;
/// overrides `seq_from` when present), `limit`. Stamps exceed 2^53, so
/// they travel as decimal strings in the response JSON and parse from
/// the query string here; unstamped records have no place on the tape
/// and never appear.
fn handleWindow(
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
) !void {
    const limit = parseUint(u32, query, "limit", 100);
    const seq_from = parseUint(u64, query, "seq_from", 0);
    const seq_to = parseUint(u64, query, "seq_to", 0);
    const after_seq = parseUint(u64, query, "after_seq", 0);
    // The statement's lower bound is strictly-greater-than; an inclusive
    // seq_from enters as its predecessor. The cursor wins when present.
    const after = if (after_seq != 0) after_seq else (seq_from -| 1);

    var list = db.queryWindow(tenant_id, after, seq_to, floor_received_ns, limit) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "window failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer list.deinit();

    const json = try renderRowsJson(allocator, list.rows, .seq);
    try setResponseOwned(server, ent, sid, sess, 200, json, cfg);
}

/// Gap counts stop scanning here — "1000+ quiet" is the honest
/// rendering of a seam bigger than anyone reads, and an uncapped COUNT
/// is an index-range scan proportional to the seam.
const GAP_COUNT_CAP: u32 = 1000;

/// The unplaced addendum's display cap — announced via
/// `unplaced_truncated`, never silent.
const UNPLACED_CAP: u32 = 100;

/// One saga's window — the saga viewer's data source. Response:
///
///   {"saga":{...roll-up...},
///    "hops":[<row>...],            // stamped, ascending tape order
///    "gaps":[{"after_seq":"..","before_seq":"..","count":N,
///             "truncated":bool,"quiet_ns":N}],  // between in-page hops
///    "unplaced":[<row>...],        // unstamped hops, first page only
///    "unplaced_truncated":bool,    // the addendum cap, announced
///    "next_cursor":{"exec_seq":".."} | null}
///
/// `gaps[i]` sits between `hops[i]` and `hops[i+1]` — seams across a
/// page boundary are the client's to stitch (it holds both edge hops).
/// 404 when the index has never seen the saga. The roll-up's
/// `closed_at_ns == 0` means "no close was seen" — NOT a liveness
/// signal (the holder is the only authority on open connections).
fn handleSaga(
    server: *LogH2,
    allocator: std.mem.Allocator,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    saga_tail: []const u8,
    query: []const u8,
    floor_received_ns: i64,
    cfg: *const Config,
) !void {
    // Clamped: each in-page seam below costs a bounded count scan, so
    // the page size bounds the whole request's work — an unclamped
    // client limit would be a cost amplifier /list doesn't have.
    const limit = @min(parseUint(u32, query, "limit", 100), 500);
    const after_seq = parseUint(u64, query, "after_seq", 0);

    // The saga id may be client-supplied (`X-Rove-Correlation-Id`,
    // ≤256 bytes) and so arrives percent-encoded in the path segment.
    // `parseTagFilter` decodes tag values the same way, so
    // `/saga/{id}` and `/list?tag._saga={id}` resolve one saga
    // identically.
    var corr_buf: [MAX_PATH_FILTER]u8 = undefined;
    const corr_id = percentDecode(&corr_buf, saga_tail) orelse {
        try setResponse(server, ent, sid, sess, 400, "invalid saga id (bad percent-encoding or > 256 bytes)\n", cfg);
        return;
    };

    var roll = (db.querySagaRoll(tenant_id, corr_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "saga failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    }) orelse {
        try setResponse(server, ent, sid, sess, 404, "unknown saga\n", cfg);
        return;
    };
    // The roll-up's strings were duped by the db's own allocator.
    defer roll.deinit(db.allocator);

    var hops = db.querySagaHops(tenant_id, corr_id, after_seq, floor_received_ns, limit) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "saga hops failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer hops.deinit();

    // Unstamped hops ride the first page only — they have no tape
    // position, so paging them under a seq cursor would re-send them
    // on every page. Fetch one past the cap so a cap hit is announced,
    // never silent. A db error here 500s like every sibling query —
    // an empty addendum on error would affirmatively claim the saga
    // has no unstamped hops.
    var unplaced: ?index_db_mod.IndexDb.ListResult = null;
    defer if (unplaced) |*u| u.deinit();
    var unplaced_truncated = false;
    if (after_seq == 0) {
        unplaced = db.querySagaUnplaced(tenant_id, corr_id, floor_received_ns, UNPLACED_CAP + 1) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "saga unplaced failed: {s}\n", .{@errorName(err)});
            try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
            return;
        };
        if (unplaced.?.rows.len > UNPLACED_CAP) unplaced_truncated = true;
    }

    // One bounded count per in-page seam (one prepared statement,
    // rebound per seam). A count failure 500s — success can never
    // produce fabricated gap data.
    const gaps = db.gapCounts(allocator, tenant_id, hops.rows, floor_received_ns, GAP_COUNT_CAP) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "saga gaps failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer allocator.free(gaps);

    const unplaced_rows = if (unplaced) |*u| u.rows[0..@min(u.rows.len, UNPLACED_CAP)] else &.{};
    const json = try renderSagaJson(allocator, &roll, hops.rows, gaps, unplaced_rows, unplaced_truncated);
    try setResponseOwned(server, ent, sid, sess, 200, json, cfg);
}

/// Seam-scan bounds. Each scanned candidate costs one range-GET +
/// inflate + tape parse, serial on this thread, so the default stays
/// small and the clamp hard; `scan_truncated` announces the cap. The
/// per-row key lists cap at MATCH_KEY_CAP with their own flag.
const SEAM_SCAN_DEFAULT: u32 = 16;
const SEAM_SCAN_MAX: u32 = 64;
const MATCH_KEY_CAP: usize = 32;

/// One seam's interference — the bounded per-gap scan
/// (`docs/architecture/deployment-and-logs.md`, the saga window; a
/// key→writer blame INDEX can come later without changing this
/// surface). `GET /v1/{t}/seam?after_seq=A&before_seq=B[&limit=K]`:
/// the hop at B supplies the read set (what the next hop observed),
/// the hop at A the write set (what the previous hop left), both from
/// their kv tapes; every stamped foreign record in the OPEN interval
/// (A,B) is fetched NEWEST-first (blame wants the latest writer) and
/// kept iff its writes hit B's reads (`wrote`) or its reads hit A's
/// writes (`read`). A=0 means the seam before the first hop (no write
/// side). Adjacent-hop key sets are a deliberate approximation of the
/// saga's cumulative sets — the seam's own hops are what the marks
/// point at.
///
/// Response:
///   {"after_seq":"A","before_seq":"B",
///    "probe":{"reads":N,"read_prefixes":N,"writes":N,
///             "hop_tapes_truncated":bool,
///             "before_no_tape":bool,"after_no_tape":bool},
///    "scanned":N,"scan_truncated":bool,"skipped_no_tape":N,
///    "interacting":[{<row>,"wrote":[..],"read":[..],
///                    "keys_truncated":bool}]}
///
/// `*_no_tape` flags are load-bearing: a hop with no kv tape yields
/// EMPTY probe sets, and "nothing interacted" must be distinguishable
/// from "nothing was probeable".
fn handleSeam(
    server: *LogH2,
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    query: []const u8,
    floor_received_ns: i64,
    cfg: *const Config,
) !void {
    const after_seq = parseUint(u64, query, "after_seq", 0);
    const before_seq = parseUint(u64, query, "before_seq", 0);
    if (before_seq == 0) {
        try setResponse(server, ent, sid, sess, 400, "seam requires before_seq (the right hop's exec_seq)\n", cfg);
        return;
    }
    const scan_cap = @min(parseUint(u32, query, "limit", SEAM_SCAN_DEFAULT), SEAM_SCAN_MAX);

    // The right hop (its READS are the probe). Must exist — a seam is
    // defined by its hops.
    var before_loc = (db.querySeamLocAt(tenant_id, before_seq, floor_received_ns) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "seam failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    }) orelse {
        try setResponse(server, ent, sid, sess, 404, "no record at before_seq\n", cfg);
        return;
    };
    defer before_loc.deinit(db.allocator);

    var before_sets, const before_no_tape = hopKeySets(allocator, store, &before_loc) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "seam probe failed at before_seq: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer before_sets.deinit();

    // The left hop (its WRITES are the mirror probe); absent when
    // after_seq = 0 — the seam before the saga's first hop. The empty
    // default owns nothing, so it is never deinit'd: only a set the
    // probe actually produced is (a probe failure must not leave a
    // deinit aimed at an unassigned value).
    var after_no_tape = false;
    var after_sets: seam_mod.KeySets = .{ .allocator = allocator };
    var after_sets_owned = false;
    defer if (after_sets_owned) after_sets.deinit();
    if (after_seq != 0) {
        var after_loc = (db.querySeamLocAt(tenant_id, after_seq, floor_received_ns) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "seam failed: {s}\n", .{@errorName(err)});
            try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
            return;
        }) orelse {
            try setResponse(server, ent, sid, sess, 404, "no record at after_seq\n", cfg);
            return;
        };
        defer after_loc.deinit(db.allocator);
        const probed = hopKeySets(allocator, store, &after_loc) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "seam probe failed at after_seq: {s}\n", .{@errorName(err)});
            try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
            return;
        };
        after_sets = probed[0];
        after_sets_owned = true;
        after_no_tape = probed[1];
    }

    var candidates = db.querySeamLocs(tenant_id, after_seq, before_seq, floor_received_ns, scan_cap + 1) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "seam scan failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer candidates.deinit();

    const json = renderSeamJson(allocator, store, .{
        .after_seq = after_seq,
        .before_seq = before_seq,
        .before = &before_sets,
        .after = &after_sets,
        .before_no_tape = before_no_tape,
        .after_no_tape = after_no_tape,
        .scan_rows = candidates.rows[0..@min(candidates.rows.len, scan_cap)],
        .scan_truncated = candidates.rows.len > scan_cap,
    }) catch |err| {
        // Every failure here is loud: a candidate we cannot probe must
        // never render as a quiet seam, which would read as data.
        const msg = try std.fmt.allocPrint(allocator, "seam scan failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    try setResponseOwned(server, ent, sid, sess, 200, json, cfg);
}

/// Everything `renderSeamJson` needs: the seam's bounds, both hops'
/// probe sets (+ whether each was probeable), and the capped candidate
/// page.
const SeamRender = struct {
    after_seq: u64,
    before_seq: u64,
    before: *const seam_mod.KeySets,
    after: *const seam_mod.KeySets,
    before_no_tape: bool,
    after_no_tape: bool,
    scan_rows: []index_db_mod.IndexDb.SeamLoc,
    scan_truncated: bool,
};

/// Render the seam response, probing each candidate against the two
/// hop key sets. Returns an error — never a partial body — if any
/// candidate can't be read or decoded; the caller answers 500.
fn renderSeamJson(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    r: SeamRender,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        // Runs on the error return too, handing the buffer back so the
        // errdefer above owns exactly one free.
        defer buf = aw.toArrayList();
        const w = &aw.writer;

        try w.print(
            "{{\"after_seq\":\"{d}\",\"before_seq\":\"{d}\",\"probe\":{{\"reads\":{d},\"read_prefixes\":{d},\"writes\":{d},\"hop_tapes_truncated\":{},\"before_no_tape\":{},\"after_no_tape\":{}}},\"scanned\":{d},\"scan_truncated\":{},\"interacting\":[",
            .{ r.after_seq, r.before_seq, r.before.reads.len, r.before.read_prefixes.len, r.after.writes.len, r.before.truncated or r.after.truncated, r.before_no_tape, r.after_no_tape, r.scan_rows.len, r.scan_truncated },
        );

        var wrote_any = false;
        var skipped_no_tape: u32 = 0;
        for (r.scan_rows) |*cand| {
            const rec_json = fetchRecordJson(allocator, store, cand.ndjson_key, cand.offset, cand.length) catch |err| {
                std.log.warn("seam: candidate frame unreadable at {s}: {s}", .{ cand.ndjson_key, @errorName(err) });
                return error.SeamCandidateUnreadable;
            };
            defer allocator.free(rec_json);
            var blobs = seam_mod.blobsFromRecordJson(allocator, rec_json) catch |err| {
                std.log.warn("seam: candidate record undecodable at {s}: {s}", .{ cand.ndjson_key, @errorName(err) });
                return error.SeamCandidateUndecodable;
            };
            defer blobs.deinit(allocator);
            // Neither side captured ⇒ unprobeable, counted not guessed.
            if (blobs.kv_tape == null and blobs.write_keys_blob == null) {
                skipped_no_tape += 1;
                continue;
            }
            const wkeys = seam_mod.decodeWriteKeys(allocator, blobs.write_keys_blob) catch |err| {
                std.log.warn("seam: candidate write keys undecodable at {s}: {s}", .{ cand.ndjson_key, @errorName(err) });
                return error.SeamCandidateUndecodable;
            };
            defer allocator.free(wkeys);
            var cand_sets = seam_mod.extractKeySets(allocator, blobs.kv_tape, wkeys) catch |err| {
                std.log.warn("seam: candidate tape undecodable at {s}: {s}", .{ cand.ndjson_key, @errorName(err) });
                return error.SeamCandidateUndecodable;
            };
            defer cand_sets.deinit();

            // A candidate whose writes never committed (outcome != ok —
            // rolled back) cannot have influenced anyone's reads; only
            // its own reads participate (it did observe committed state).
            const cand_committed = std.mem.eql(u8, cand.outcome, "ok");
            var wrote: seam_mod.Matches = if (cand_committed)
                try seam_mod.writesMatching(allocator, &cand_sets, r.before, MATCH_KEY_CAP)
            else
                .{ .keys = &.{}, .truncated = false };
            defer if (cand_committed) wrote.deinit(allocator);
            var read = try seam_mod.readsMatching(allocator, &cand_sets, r.after, MATCH_KEY_CAP);
            defer read.deinit(allocator);
            if (wrote.keys.len == 0 and read.keys.len == 0) continue;

            if (wrote_any) try w.writeAll(",");
            wrote_any = true;
            var rid_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
            const rid = log_mod.formatPrefixedId(&rid_buf, log_mod.REQUEST_ID_PREFIX, cand.request_id);
            try w.print(
                "{{\"request_id\":\"{s}\",\"exec_seq\":\"{d}\",\"received_ns\":{d},\"status\":{d},\"method\":",
                .{ rid, cand.exec_seq, cand.received_ns, cand.status },
            );
            try writeJsonString(w, cand.method);
            try w.writeAll(",\"path\":");
            try writeJsonString(w, cand.path);
            try w.writeAll(",\"outcome\":");
            try writeJsonString(w, cand.outcome);
            try w.writeAll(",\"activation\":");
            try writeJsonString(w, cand.activation);
            try w.writeAll(",\"wrote\":[");
            for (wrote.keys, 0..) |k, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonString(w, k);
            }
            try w.writeAll("],\"read\":[");
            for (read.keys, 0..) |k, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonString(w, k);
            }
            try w.print("],\"keys_truncated\":{}}}", .{wrote.truncated or read.truncated});
        }

        try w.print("],\"skipped_no_tape\":{d}}}\n", .{skipped_no_tape});
    }
    return try buf.toOwnedSlice(allocator);
}

/// Fetch one hop's record and extract its key sets (reads from the kv
/// tape, writes from the write-key list). `(sets, true)` with empty
/// sets when the record carries neither — the caller surfaces the flag
/// so an unprobeable hop is never read as "touched nothing".
fn hopKeySets(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    loc: *const index_db_mod.IndexDb.SeamLoc,
) !struct { seam_mod.KeySets, bool } {
    const rec_json = try fetchRecordJson(allocator, store, loc.ndjson_key, loc.offset, loc.length);
    defer allocator.free(rec_json);
    var blobs = try seam_mod.blobsFromRecordJson(allocator, rec_json);
    defer blobs.deinit(allocator);
    const no_tape = blobs.kv_tape == null and blobs.write_keys_blob == null;
    const wkeys = try seam_mod.decodeWriteKeys(allocator, blobs.write_keys_blob);
    defer allocator.free(wkeys);
    return .{ try seam_mod.extractKeySets(allocator, blobs.kv_tape, wkeys), no_tape };
}

fn renderSagaJson(
    allocator: std.mem.Allocator,
    roll: *const index_db_mod.IndexDb.SagaRow,
    hops: []index_db_mod.IndexDb.ListRow,
    gaps: []const index_db_mod.IndexDb.GapCount,
    unplaced: []const index_db_mod.IndexDb.ListRow,
    unplaced_truncated: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    {
        defer buf = aw.toArrayList();
        try aw.writer.writeAll("{\"saga\":{\"saga_id\":");
        try writeJsonString(&aw.writer, roll.corr_id);
        try aw.writer.print(
            ",\"first_received_ns\":{d},\"last_received_ns\":{d},\"activation_count\":{d},\"error_count\":{d},\"last_status\":{d},\"closed_at_ns\":{d}",
            .{ roll.first_received_ns, roll.last_received_ns, roll.activation_count, roll.error_count, roll.last_status, roll.closed_at_ns },
        );
        try aw.writer.writeAll(",\"last_outcome\":");
        try writeJsonString(&aw.writer, roll.last_outcome);
        try aw.writer.writeAll(",\"root_method\":");
        try writeJsonString(&aw.writer, roll.root_method);
        try aw.writer.writeAll(",\"root_path\":");
        try writeJsonString(&aw.writer, roll.root_path);
        try aw.writer.writeAll(",\"root_host\":");
        try writeJsonString(&aw.writer, roll.root_host);
        try aw.writer.writeAll("},\"hops\":[");
    }
    for (hops, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeRowJson(allocator, &buf, &r);
    }
    aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    {
        defer buf = aw.toArrayList();
        try aw.writer.writeAll("],\"gaps\":[");
        for (gaps, 0..) |g, i| {
            if (i > 0) try aw.writer.writeAll(",");
            // The seam's endpoints as decimal strings, same 2^53 stance
            // as every stamp this surface emits. `quiet_ns` is the
            // END-to-start wall gap (the previous hop's own execution
            // time is not "quiet"), clamped at zero: tape order is
            // authoritative while received_ns is per-node wall clock,
            // so a failover seam can legitimately measure negative —
            // meaningless as a duration, so it floors.
            const prev_end = hops[i].received_ns +| hops[i].duration_ns;
            const quiet_ns = @max(hops[i + 1].received_ns -| prev_end, 0);
            try aw.writer.print(
                "{{\"after_seq\":\"{d}\",\"before_seq\":\"{d}\",\"count\":{d},\"truncated\":{},\"quiet_ns\":{d}}}",
                .{ hops[i].exec_seq, hops[i + 1].exec_seq, g.count, g.truncated, quiet_ns },
            );
        }
        try aw.writer.writeAll("],\"unplaced\":[");
    }
    for (unplaced, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeRowJson(allocator, &buf, &r);
    }
    aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    {
        defer buf = aw.toArrayList();
        try aw.writer.print("],\"unplaced_truncated\":{}", .{unplaced_truncated});
        try writeSeqCursorTail(&aw.writer, hops);
    }
    return buf.toOwnedSlice(allocator);
}

/// The seq-keyset cursor envelope tail: `,"next_cursor":{"exec_seq":".."}}`
/// from the last row's stamp, or `null` when the page is empty. The ONE
/// spelling for every stamp-cursored endpoint (`/window`, `/saga`) — the
/// dashboard's cursor parser must never see two shapes.
fn writeSeqCursorTail(w: *std.Io.Writer, rows: []const index_db_mod.IndexDb.ListRow) !void {
    if (rows.len == 0) {
        try w.writeAll(",\"next_cursor\":null}\n");
    } else {
        try w.print(",\"next_cursor\":{{\"exec_seq\":\"{d}\"}}}}\n", .{rows[rows.len - 1].exec_seq});
    }
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

    const decompressed = fetchRecordJson(allocator, store, row.ndjson_key, row.offset, row.length) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "payload fetch failed for {s}: {s}\n",
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

/// `GET /v1/{tenant}/body/{request_id}/{channel}/{index}` — the bytes of
/// one recorded payload, resolved out of line.
///
/// A payload over the inline cap is not in the record; the record holds a
/// pointer and the bytes stay in object storage. This is the door that
/// turns the pointer back into bytes, so that a large input is replayable
/// rather than silently replayed as empty (the out-of-line reference
/// discipline — a reference is only worth writing if some reader can
/// resolve it).
///
/// The address is `(record, channel, entry index)` and never a raw
/// a raw `BodyRef`. The body pool is cross-tenant, so accepting
/// a caller-supplied batch and offset would let anyone past the tenant
/// gate walk offsets into a neighbour's bytes; deriving the reference
/// here, from a record this token may already read, makes that
/// unrepresentable. The record lookup carries the same tenant scoping and
/// the same retention clamp as `/show` — a body must not outlive the
/// record that names it.
///
/// Status codes are a resolution VERDICT, never a body:
///   404 — no such record, or no such entry in that channel
///   409 — the entry recorded the payload as nothing (`NotRecorded`)
///   410 — the referenced object is no longer in storage
///   503 — no content store configured, so the pointer is unreachable
/// None of these is an empty 200, which is the outcome the whole arc
/// exists to eliminate.
fn handleBody(
    server: *LogH2,
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    tail: []const u8,
    floor_received_ns: i64,
    cfg: *const Config,
) !void {
    const addr = parseBodyTail(tail) orelse {
        try setResponse(
            server,
            ent,
            sid,
            sess,
            400,
            "invalid body address (want req_<16hex>/{trigger_payload|fetch_responses}/<index>)\n",
            cfg,
        );
        return;
    };

    const content_store = cfg.content_store orelse {
        try setResponse(server, ent, sid, sess, 503, "content store not configured\n", cfg);
        return;
    };

    var maybe = db.queryShow(tenant_id, addr.request_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "body lookup failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    if (maybe == null) {
        try setResponse(server, ent, sid, sess, 404, "record not found\n", cfg);
        return;
    }
    defer maybe.?.deinit(allocator);
    const row = maybe.?;

    // Same clamp as `/show`: a record outside the tenant's retention
    // window is 404, and its payload must not be reachable by a route
    // that skipped the check.
    if (floor_received_ns != 0 and row.received_ns < floor_received_ns) {
        try setResponse(server, ent, sid, sess, 404, "record not found\n", cfg);
        return;
    }

    const record_json = fetchRecordJson(allocator, store, row.ndjson_key, row.offset, row.length) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "payload fetch failed for {s}: {s}\n",
            .{ row.ndjson_key, @errorName(err) },
        );
        try setResponseOwned(server, ent, sid, sess, 500, msg, cfg);
        return;
    };
    defer allocator.free(record_json);

    var resolved = body_ref_mod.resolveFromRecord(
        allocator,
        content_store,
        tenant_id,
        record_json,
        addr.channel,
        addr.index,
    ) catch |err| {
        metrics_mod.Metrics.inc(&metrics_mod.global.query_body_unresolved);
        const status: u16, const msg: []const u8 = switch (err) {
            body_ref_mod.Error.ChannelNotCaptured => .{ 404, "no tape for that channel\n" },
            body_ref_mod.Error.NoSuchEntry => .{ 404, "no such entry in that channel\n" },
            body_ref_mod.Error.NotRecorded => .{ 409, "the payload was not recorded\n" },
            body_ref_mod.Error.Gone => .{ 410, "the referenced bytes are no longer stored\n" },
            body_ref_mod.Error.TooLarge => .{ 413, "the reference exceeds the resolution ceiling\n" },
            body_ref_mod.Error.MalformedRef => .{ 422, "the recorded reference is malformed\n" },
            body_ref_mod.Error.BadRecordJson => .{ 422, "the record could not be decoded\n" },
            else => .{ 500, "body resolution failed\n" },
        };
        try setResponse(server, ent, sid, sess, status, msg, cfg);
        return;
    };
    defer resolved.deinit(allocator);

    // Base64-in-JSON, like every other byte field a record carries
    // (`request_body_b64`, `activation_bytes_b64`, the tape blobs). The
    // dashboard reaches this door through a same-origin chokepoint that
    // relays door results as TEXT, so raw octets would be UTF-8 mangled
    // in transit; and the caller needs the verdict alongside the bytes to
    // distinguish "resolved out of the pool" from "rode along inline",
    // which a bare body cannot carry.
    const enc_len = std.base64.standard.Encoder.calcSize(resolved.bytes.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, enc_len + 96);
    try out.appendSlice(allocator, "{\"source\":\"");
    try out.appendSlice(allocator, resolved.source.name());
    try out.appendSlice(allocator, "\",\"len\":");
    try out.print(allocator, "{d}", .{resolved.bytes.len});
    try out.appendSlice(allocator, ",\"bytes_b64\":\"");
    const enc_at = out.items.len;
    try out.resize(allocator, enc_at + enc_len);
    _ = std.base64.standard.Encoder.encode(out.items[enc_at..], resolved.bytes);
    try out.appendSlice(allocator, "\"}\n");
    try setResponseOwned(server, ent, sid, sess, 200, try out.toOwnedSlice(allocator), cfg);
}

/// Range-read + inflate one record's stored JSON: each record is its
/// own raw-deflate stream, and the index's `(ndjson_key, offset,
/// length)` brackets exactly one frame. Caller owns the returned
/// bytes. Shared by `/show` (returns it verbatim) and the seam scan
/// (parses it for the kv tape).
fn fetchRecordJson(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    ndjson_key: []const u8,
    offset: u64,
    length: u32,
) ![]u8 {
    const payload = try store.getRange(ndjson_key, offset, length, allocator);
    defer allocator.free(payload);
    return try decompressRawDeflate(allocator, payload);
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

/// Total record count for a tenant. Plain decimal
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

/// Which keyset the `next_cursor` object carries: the `/list` time
/// cursor (`received_ns` + opaque `request_id` token) or the `/window`
/// tape cursor (`exec_seq` decimal string). One renderer for both
/// endpoints so an envelope change can never drift them apart — the
/// dashboard parses the two responses with the same client.
const CursorFlavor = enum { time, seq };

fn renderRowsJson(
    allocator: std.mem.Allocator,
    rows: []index_db_mod.IndexDb.ListRow,
    flavor: CursorFlavor,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"records\":[");
    for (rows, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeRowJson(allocator, &buf, &r);
    }
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = aw.toArrayList();
        try aw.writer.writeAll("]");
        switch (flavor) {
            // Hand back the cursor request_id as the opaque prefixed
            // token the client passes verbatim to `?after_request_id=`
            // (§7.5).
            .time => if (rows.len == 0) {
                try aw.writer.writeAll(",\"next_cursor\":null}\n");
            } else {
                const last = &rows[rows.len - 1];
                var cur_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
                const cur_rid = log_mod.formatPrefixedId(&cur_buf, log_mod.REQUEST_ID_PREFIX, last.request_id);
                try aw.writer.print(
                    ",\"next_cursor\":{{\"received_ns\":{d},\"request_id\":\"{s}\"}}}}\n",
                    .{ last.received_ns, cur_rid },
                );
            },
            .seq => try writeSeqCursorTail(&aw.writer, rows),
        }
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
    // Per-step kind, so a caller listing a saga's activations can
    // label each one without a `/show` per row. Empty on rows indexed
    // before the field existed.
    try aw.writer.writeAll(",\"activation\":");
    try writeJsonString(&aw.writer, r.activation);
    // The execution-sequence stamp as a DECIMAL STRING — its values
    // exceed 2^53, and a bare JSON number would silently round in
    // dashboard JS, breaking stamp equality/ordering. "0" = unstamped.
    try aw.writer.print(",\"exec_seq\":\"{d}\"", .{r.exec_seq});
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
    const headers = try buildResponseHeaders(server.allocator, cfg, null);
    try server.reg.set(ent, server.coll(.request_out), h2.Status, .{ .code = status });
    try server.reg.set(ent, server.coll(.request_out), h2.RespHeaders, headers);
    try server.reg.set(ent, server.coll(.request_out), h2.RespBody, .{
        .data = null,
        .len = @intCast(body_static.len),
    });
    try server.reg.set(ent, server.coll(.request_out), h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, server.coll(.request_out), h2.StreamId, sid);
    try server.reg.set(ent, server.coll(.request_out), h2.Session, sess);
    try server.reg.move(ent, server.coll(.request_out), server.coll(.response_in));
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
    const headers = try buildResponseHeaders(server.allocator, cfg, null);
    try server.reg.set(ent, server.coll(.request_out), h2.Status, .{ .code = status });
    try server.reg.set(ent, server.coll(.request_out), h2.RespHeaders, headers);
    try server.reg.set(ent, server.coll(.request_out), h2.RespBody, .{
        .data = body_owned.ptr,
        .len = @intCast(body_owned.len),
    });
    try server.reg.set(ent, server.coll(.request_out), h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, server.coll(.request_out), h2.StreamId, sid);
    try server.reg.set(ent, server.coll(.request_out), h2.Session, sess);
    try server.reg.move(ent, server.coll(.request_out), server.coll(.response_in));
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
    const headers = try buildResponseHeaders(server.allocator, cfg, .preflight);
    try server.reg.set(ent, server.coll(.request_out), h2.Status, .{ .code = 204 });
    try server.reg.set(ent, server.coll(.request_out), h2.RespHeaders, headers);
    try server.reg.set(ent, server.coll(.request_out), h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, server.coll(.request_out), h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, server.coll(.request_out), h2.StreamId, sid);
    try server.reg.set(ent, server.coll(.request_out), h2.Session, sess);
    try server.reg.move(ent, server.coll(.request_out), server.coll(.response_in));
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
/// `NNN` (exact, 100–599) or `Nxx` (a class: `5xx` → 500..599).
/// Null on anything else — the caller 400s rather than silently
/// dropping the filter.
fn parseStatusFilter(s: []const u8) ?struct { u16, u16 } {
    if (s.len == 3 and s[1] == 'x' and s[2] == 'x') {
        if (s[0] < '1' or s[0] > '5') return null;
        const base: u16 = @as(u16, s[0] - '0') * 100;
        return .{ base, base + 99 };
    }
    const exact = std.fmt.parseInt(u16, s, 10) catch return null;
    if (exact < 100 or exact > 599) return null;
    return .{ exact, exact };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    if (s) |v| if (v.len != 0) return v;
    return null;
}

const MAX_PATH_FILTER = 256;

/// Percent-decode `s` into `buf` (no `+`-as-space — the dashboard uses
/// `URLSearchParams`/`encodeURIComponent`, which emit `%20`). Null on a
/// malformed escape or a term longer than the buffer.
fn percentDecode(buf: *[MAX_PATH_FILTER]u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n >= buf.len) return null;
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return null;
            buf[n] = @intCast(hi * 16 + lo);
            i += 3;
        } else {
            buf[n] = s[i];
            i += 1;
        }
        n += 1;
    }
    if (n == 0) return null; // an empty term filters nothing — reject loudly
    return buf[0..n];
}

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

test "parseStatusFilter accepts NNN and Nxx, rejects everything else" {
    try std.testing.expectEqual(@as(u16, 404), parseStatusFilter("404").?[0]);
    try std.testing.expectEqual(@as(u16, 404), parseStatusFilter("404").?[1]);
    try std.testing.expectEqual(@as(u16, 500), parseStatusFilter("5xx").?[0]);
    try std.testing.expectEqual(@as(u16, 599), parseStatusFilter("5xx").?[1]);
    try std.testing.expectEqual(@as(u16, 200), parseStatusFilter("2xx").?[0]);
    try std.testing.expect(parseStatusFilter("6xx") == null);
    try std.testing.expect(parseStatusFilter("0xx") == null);
    try std.testing.expect(parseStatusFilter("99") == null);
    try std.testing.expect(parseStatusFilter("600") == null);
    try std.testing.expect(parseStatusFilter("abc") == null);
    try std.testing.expect(parseStatusFilter("") == null);
}

test "percentDecode round-trips an encoded path term and rejects malformed input" {
    var buf: [MAX_PATH_FILTER]u8 = undefined;
    try std.testing.expectEqualStrings("/api/checkout", percentDecode(&buf, "%2Fapi%2Fcheckout").?);
    try std.testing.expectEqualStrings("plain", percentDecode(&buf, "plain").?);
    try std.testing.expectEqualStrings("a b", percentDecode(&buf, "a%20b").?);
    try std.testing.expect(percentDecode(&buf, "%2") == null); // truncated escape
    try std.testing.expect(percentDecode(&buf, "%zz") == null); // non-hex
    try std.testing.expect(percentDecode(&buf, "") == null); // empty term
    const too_long = "a" ** (MAX_PATH_FILTER + 1);
    try std.testing.expect(percentDecode(&buf, too_long) == null);
}

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

test "parseRoute matches /v1/{tenant}/window and /v1/{tenant}/saga/{id}" {
    const w = parseRoute("/v1/acme/window?seq_from=5&limit=20").?;
    try testing.expectEqual(RouteKind.window, w.kind);
    try testing.expectEqualStrings("acme", w.tenant_id);
    try testing.expectEqualStrings("seq_from=5&limit=20", w.query);

    const s = parseRoute("/v1/acme/saga/corr-7f1a?after_seq=9").?;
    try testing.expectEqual(RouteKind.saga, s.kind);
    try testing.expectEqualStrings("acme", s.tenant_id);
    try testing.expectEqualStrings("corr-7f1a", s.tail);
    try testing.expectEqualStrings("after_seq=9", s.query);
    // Empty saga id is a 404 (no tail).
    try testing.expect(parseRoute("/v1/acme/saga/") == null);

    const m = parseRoute("/v1/acme/seam?after_seq=4&before_seq=9").?;
    try testing.expectEqual(RouteKind.seam, m.kind);
    try testing.expectEqualStrings("acme", m.tenant_id);
    try testing.expectEqualStrings("after_seq=4&before_seq=9", m.query);
}

test "parseRoute matches /v1/{tenant}/body/{id}/{channel}/{index}" {
    const r = parseRoute("/v1/acme/body/req_00000000000000ff/trigger_payload/0").?;
    try testing.expectEqual(RouteKind.body, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("req_00000000000000ff/trigger_payload/0", r.tail);
    try testing.expect(parseRoute("/v1/acme/body/") == null);
}

test "parseBodyTail: the address is a triple, and nothing looser" {
    const a = parseBodyTail("req_00000000000000ff/fetch_responses/7").?;
    try testing.expectEqual(@as(u64, 0xff), a.request_id);
    try testing.expectEqual(body_ref_mod.Channel.fetch_responses, a.channel);
    try testing.expectEqual(@as(u32, 7), a.index);

    // Too few segments, too many segments, junk index, unknown channel,
    // and a bare integer where the opaque request-id token belongs —
    // each is an address we refuse rather than guess at.
    try testing.expect(parseBodyTail("req_00000000000000ff/trigger_payload") == null);
    try testing.expect(parseBodyTail("req_00000000000000ff/trigger_payload/0/extra") == null);
    try testing.expect(parseBodyTail("req_00000000000000ff/trigger_payload/x") == null);
    try testing.expect(parseBodyTail("req_00000000000000ff/kv/0") == null);
    try testing.expect(parseBodyTail("255/trigger_payload/0") == null);
    try testing.expect(parseBodyTail("") == null);
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
