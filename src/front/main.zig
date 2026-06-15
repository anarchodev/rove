//! rewind-front — the V2 front door (docs/v2-front-door-architecture.md).
//!
//! A STATELESS HTTP/2 reverse proxy. Per customer request:
//!
//!   read :authority / Host → resolve placement via the CP's
//!   `/_cp/route?host=H` (cached) → reverse-proxy to the owning cluster's
//!   nodes (leader-aware retry on 421 not-leader; ambiguous 503s relay).
//!
//! It holds NO directory / raft state — placement lives in the CP
//! (`rewind-cp`), which this binary reads as a cached read-replica. That is
//! the split that fixes the prototype's inverted scaling (front door used to
//! BE a CP raft voter): front doors now scale horizontally behind an L4
//! ingress, independent of the CP voter set. A stale cache costs at most a
//! serve-or-forward hop at the DP, never a wrong answer (the CP is the one
//! authority, serve-or-forward the one backstop, this cache an
//! intentionally-stale hint).
//!
//! ## The streaming proxy (src/front/proxy.zig)
//!
//! The data path is a same-poll-loop rove-h2 CLIENT leg: one pooled h2c
//! connection per backend node, every proxied request a multiplexed
//! stream. Request bodies stream in (headers_first + BodySink on the
//! server side) and out (the client streaming leg); response bodies
//! stream back (client_headers_first + BodySink on the client side,
//! relayed through the server's stream_response/stream_data pipeline,
//! h2 AND h1 downstream). Backpressure is end-to-end window-repayment-
//! on-drain in both directions. Nothing on the data path blocks;
//! libcurl survives only for CP control-plane lookups (route / cert /
//! ACME) — cached, small, off the data path. Retry semantics (421
//! re-aim with a replay buffer, ambiguous-503 relay, 502 cache
//! invalidation) live in proxy.zig.
//!
//! WebSocket terminates at the edge and tunnels upstream as an RFC
//! 8441 Extended CONNECT stream on the pooled h2c conn
//! (websocket-plan §8.5): the Upgrade head surfaces to the proxy
//! (`websocket_surface`), the downstream 101 waits for the upstream
//! 200, then bytes relay verbatim (the worker unmasks).

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const blob = @import("rove-blob");
const proxy_mod = @import("proxy.zig");
const route_resolver_mod = @import("route_resolver.zig");

const curl = blob.curl;

const FrontH2 = h2.H2(.{
    .client = true,
    .request_row = rove.Row(&.{proxy_mod.FlowRef}),
});

const Proxy = proxy_mod.Proxy(FrontH2);

// ── Signal-driven shutdown ────────────────────────────────────────────
var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ── Cert sync (gap #3 slice 2): pull per-host certs from the CP ────────
//
// The front door terminates public TLS and SNI-selects a per-host cert. The
// SNI servername callback runs *inside* the handshake and cannot block on a CP
// fetch, so certs are synced PROACTIVELY into the `TlsConfig` host store on a
// timer: poll `/_cp/certs` (the certed-host list), pull each host's frame via
// `/_cp/cert`, and install it (`putHostCertInMemory`, a no-op when the content
// version is unchanged). A freshly-issued domain's first connection in the poll
// gap falls back to the wildcard; the next connection (post-sync) gets its
// cert. Null `tls` (h2c front door, no TLS env) ⇒ this is inert.
const CertSync = struct {
    allocator: std.mem.Allocator,
    cp_urls: []const []const u8,
    tls: *h2.TlsConfig,

    /// GET `suffix` from the first reachable CP node; owned 200 body or null.
    fn cpGet(self: *CertSync, suffix: []const u8) ?[]u8 {
        const a = self.allocator;
        for (self.cp_urls) |base| {
            const url = std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix }) catch continue;
            defer a.free(url);
            var easy = curl.Easy.init(a) catch continue;
            defer easy.deinit();
            var resp = easy.request(a, .{
                .method = .GET,
                .url = url,
                .headers = &[_]curl.Header{},
                .body = "",
                .http_version = .h2c_prior_knowledge,
                .verify_tls = false,
            }) catch continue;
            defer resp.deinit(a);
            if (resp.status != 200) continue;
            const body = resp.body orelse "";
            return a.dupe(u8, body) catch null;
        }
        return null;
    }

    /// One sync pass: install/renew every certed host's cert. Best-effort — a
    /// CP that's unreachable leaves the current SNI store untouched.
    fn sync(self: *CertSync) void {
        const a = self.allocator;
        const list = self.cpGet("/_cp/certs") orelse return;
        defer a.free(list);
        var it = std.mem.tokenizeScalar(u8, list, '\n');
        while (it.next()) |raw| {
            const host = std.mem.trim(u8, raw, " \t\r");
            if (host.len == 0) continue;
            const suffix = std.fmt.allocPrint(a, "/_cp/cert?host={s}", .{host}) catch continue;
            defer a.free(suffix);
            const frame = self.cpGet(suffix) orelse continue;
            defer a.free(frame);
            const u = unpackCert(frame) orelse continue;
            const ver = std.hash.Wyhash.hash(0, frame);
            self.tls.putHostCertInMemory(host, u.cert, u.key, ver) catch |e|
                std.log.warn("front: install cert for {s} failed: {s}", .{ host, @errorName(e) });
        }
    }
};

/// Runs `CertSync.sync` on a dedicated thread so the periodic CP cert
/// pull never blocks the poll loop — a slow/unreachable CP would
/// otherwise freeze serving for every host on every `REWIND_CERT_SYNC_MS`
/// tick. Safe because the TLS host store it writes
/// (`putHostCertInMemory`) takes `store_rw` exclusively while the
/// in-handshake SNI reader takes it shared (h2/tls.zig). The first pass
/// runs on the thread too, so a brand-new domain's first connection in
/// the boot window falls back to the wildcard until the pass lands —
/// the same gap the periodic sync already tolerated, just at startup.
const CertSyncThread = struct {
    cs: CertSync,
    period_ns: u64,
    stop: std.atomic.Value(bool),
    wake: std.Thread.ResetEvent,
    thread: ?std.Thread,

    fn start(
        allocator: std.mem.Allocator,
        cp_urls: []const []const u8,
        tls: *h2.TlsConfig,
        period_ns: u64,
    ) !*CertSyncThread {
        const self = try allocator.create(CertSyncThread);
        self.* = .{
            .cs = .{ .allocator = allocator, .cp_urls = cp_urls, .tls = tls },
            .period_ns = period_ns,
            .stop = std.atomic.Value(bool).init(false),
            .wake = .{},
            .thread = null,
        };
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |e| {
            allocator.destroy(self);
            return e;
        };
        return self;
    }

    fn threadMain(self: *CertSyncThread) void {
        self.cs.sync(); // first pass: repopulate the SNI store after a restart
        while (!self.stop.load(.acquire)) {
            // Wakes on the period (Timeout) or on `shutdown` (wake.set).
            self.wake.timedWait(self.period_ns) catch {};
            if (self.stop.load(.acquire)) break;
            self.cs.sync();
        }
    }

    fn shutdownAndDestroy(self: *CertSyncThread, allocator: std.mem.Allocator) void {
        self.stop.store(true, .release);
        self.wake.set();
        if (self.thread) |t| t.join();
        allocator.destroy(self);
    }
};

/// Split the CP's packed cert frame (`[4B BE cert_len][cert_pem][key_pem]`).
const UnpackedCert = struct { cert: []const u8, key: []const u8 };
fn unpackCert(frame: []const u8) ?UnpackedCert {
    if (frame.len < 4) return null;
    const clen = std.mem.readInt(u32, frame[0..4], .big);
    if (4 + clen > frame.len) return null;
    return .{ .cert = frame[4 .. 4 + clen], .key = frame[4 + clen ..] };
}

fn cleanupResponses(server: *FrontH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

fn getEnvCfg(name: []const u8) []const u8 {
    return std.posix.getenv(name) orelse "";
}

/// Parse a millisecond config env var, falling back to `default` when
/// unset or unparseable.
fn envMs(name: []const u8, default: i128) i128 {
    const s = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(i128, std.mem.trim(u8, s, " \t"), 10) catch default;
}

// ── Phase 5: the :80 plaintext listener (ACME HTTP-01 + HTTP→HTTPS redirect) ──
//
// rove-h2 speaks HTTP/1.1 (gap #6 phases 1–4), so the front door answers
// the ACME HTTP-01 `:80` challenge natively. Two behaviors: serve
// `/.well-known/acme-challenge/<token>` (the key-authorization fetched from
// the CP issuer, slice 3) and 308-redirect every other request to its HTTPS
// origin.

const ACME_PREFIX = "/.well-known/acme-challenge/";

/// Reply helper for the `:80` listener: immediate status, no body.
fn replyStatus80(server: *FrontH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Pack a single response header into the `h2.RespHeaders` layout — one buffer
/// holding the field array + name/value bytes, freed by `RespHeaders.deinit`
/// when the response entity is destroyed.
fn packRespHeader(a: std.mem.Allocator, name: []const u8, value: []const u8) !h2.RespHeaders {
    const HF = h2.HeaderField;
    const fields_size = @sizeOf(HF);
    const total = fields_size + name.len + value.len;
    const buf = try a.alloc(u8, total);
    const fields: [*]HF = @ptrCast(@alignCast(buf.ptr));
    const sb = buf.ptr + fields_size;
    @memcpy(sb[0..name.len], name);
    @memcpy(sb[name.len .. name.len + value.len], value);
    fields[0] = .{ .name = sb, .name_len = @intCast(name.len), .value = sb + name.len, .value_len = @intCast(value.len) };
    return .{ .fields = fields, .count = 1, ._buf = buf.ptr, ._buf_len = @intCast(total) };
}

/// Reply with status + headers + (optional, owned) body. Mirrors
/// `replyStatus80` but carries a header set and body.
fn replyFull(server: *FrontH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16, rh: h2.RespHeaders, body: ?[]u8) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, rh);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = if (body) |b| b.ptr else null,
        .len = if (body) |b| @intCast(b.len) else 0,
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// Fetch the ACME HTTP-01 key-authorization for `token` from the CP issuer.
/// Owned 200 body or null (no active challenge / CP unreachable).
fn acmeChallengeLookup(a: std.mem.Allocator, cp_urls: []const []const u8, token: []const u8) ?[]u8 {
    for (cp_urls) |base| {
        const url = std.fmt.allocPrint(a, "{s}/_cp/acme-challenge?token={s}", .{ base, token }) catch continue;
        defer a.free(url);
        var easy = curl.Easy.init(a) catch continue;
        defer easy.deinit();
        var resp = easy.request(a, .{
            .method = .GET,
            .url = url,
            .headers = &[_]curl.Header{},
            .body = "",
            .http_version = .h2c_prior_knowledge,
            .verify_tls = false,
            // Runs on the :80 thread now (off the :443 loop), but still
            // bound tight so a slow CP can't pile up other :80 requests.
            .connect_timeout_ms = 1000,
            .timeout_ms = 2000,
        }) catch continue;
        defer resp.deinit(a);
        if (resp.status != 200) continue;
        return a.dupe(u8, resp.body orelse "") catch null;
    }
    return null;
}

/// Drive the `:80` server's request queue: ACME challenge or HTTPS redirect.
fn processPort80(server: *FrontH2, a: std.mem.Allocator, cp_urls: []const []const u8) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);

    for (entities, sids, sessions, req_hdrs) |ent, sid, sess, rh| {
        const path = proxy_mod.headerValue(rh, ":path") orelse "/";

        // ACME HTTP-01: serve the key-authorization fetched from the CP.
        if (std.mem.startsWith(u8, path, ACME_PREFIX)) {
            const token = path[ACME_PREFIX.len..];
            if (token.len > 0) {
                if (acmeChallengeLookup(a, cp_urls, token)) |ka| {
                    const ct = packRespHeader(a, "content-type", "text/plain") catch {
                        a.free(ka);
                        try replyStatus80(server, ent, sid, sess, 500);
                        continue;
                    };
                    try replyFull(server, ent, sid, sess, 200, ct, ka);
                    continue;
                }
            }
            try replyStatus80(server, ent, sid, sess, 404);
            continue;
        }

        // Everything else → 308 to the HTTPS origin (preserves method + body).
        const host_raw = proxy_mod.headerValue(rh, ":authority") orelse proxy_mod.headerValue(rh, "host") orelse {
            try replyStatus80(server, ent, sid, sess, 400);
            continue;
        };
        const host = proxy_mod.hostOnly(host_raw);
        const location = std.fmt.allocPrint(a, "https://{s}{s}", .{ host, path }) catch {
            try replyStatus80(server, ent, sid, sess, 500);
            continue;
        };
        defer a.free(location);
        const loc = packRespHeader(a, "location", location) catch {
            try replyStatus80(server, ent, sid, sess, 500);
            continue;
        };
        try replyFull(server, ent, sid, sess, 308, loc, null);
    }
}

/// Parse a `;`/`,`-separated list of origins into an owned, owned-element
/// slice. Empty input → empty slice. Whitespace trimmed; blanks skipped.
fn parseUrlList(a: std.mem.Allocator, config: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |u| a.free(u);
        list.deinit(a);
    }
    var it = std.mem.tokenizeAny(u8, config, ";,");
    while (it.next()) |raw| {
        const url = std.mem.trim(u8, raw, " \t\r\n");
        if (url.len == 0) continue;
        try list.append(a, try a.dupe(u8, url));
    }
    return list.toOwnedSlice(a);
}

fn freeUrlList(a: std.mem.Allocator, urls: []const []const u8) void {
    for (urls) |u| a.free(u);
    a.free(urls);
}

pub fn main() !void {
    curl.globalInit();
    const allocator = std.heap.c_allocator;
    installSignalHandlers();

    var arg_it = std.process.args();
    _ = arg_it.next();
    const port_str = arg_it.next() orelse "8080";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // CP origins to resolve placement against. Required — a front door with no
    // CP cannot route. `REWIND_CP_URL=http://cp1:9090;http://cp2:9090;…`
    // (any CP node answers `/_cp/route`; multiple for HA).
    const cp_urls = try parseUrlList(allocator, getEnvCfg("REWIND_CP_URL"));
    defer freeUrlList(allocator, cp_urls);
    if (cp_urls.len == 0) {
        std.log.err("rewind-front: REWIND_CP_URL is required (the CP origin(s) to resolve placement)", .{});
        return error.MissingCpUrl;
    }

    // Route-cache TTL (ms). Within the TTL a host is served from cache
    // (the CP is not consulted); past it the next request re-resolves by
    // PARKING off the poll loop (never blocking it, never serving a
    // stale entry — so a tenant move re-routes correctly past the TTL).
    // The TTL thus also bounds move-propagation latency.
    const cache_ms = envMs("REWIND_ROUTE_CACHE_MS", 1_000);
    var cache = proxy_mod.RouteCache.init(allocator, cache_ms * std.time.ns_per_ms);
    defer cache.deinit();

    // Off-loop route resolver: CP `/_cp/route` queries run on this
    // background thread so a slow/stuck CP never freezes the poll loop.
    // Shut down (join) before the cache/proxy deinit so no late
    // completion outlives them; its own deinit frees undrained items.
    const resolver = try route_resolver_mod.RouteResolver.init(allocator, cp_urls);
    defer resolver.deinit();
    try resolver.start();
    defer resolver.shutdown();

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 8192,
        .deferred_queue_capacity = 2048,
    });
    defer reg.deinit();

    // Public TLS termination (gap #3 slice 2). The default ctx is the platform
    // wildcard from `REWIND_TLS_CERT`/`REWIND_TLS_KEY`; per-host custom-domain
    // certs are synced from the CP (`CertSync`). Both env unset ⇒ the front
    // door stays h2c (TLS terminated upstream) — the prior behavior, so
    // existing h2c smokes are unaffected.
    const tls_config: ?*h2.TlsConfig = blk: {
        const cert = std.posix.getenv("REWIND_TLS_CERT");
        const key = std.posix.getenv("REWIND_TLS_KEY");
        if (cert == null or key == null) break :blk null;
        break :blk try h2.TlsConfig.createFromFiles(allocator, cert.?, key.?, null);
    };
    defer if (tls_config) |t| t.destroy();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    const server = try FrontH2.create(&reg, allocator, addr, .{
        .max_connections = 1024,
        .buf_count = 1024,
        .buf_size = 16384,
        .listen_backlog = 1024,
        .reuseport = true,
    }, .{
        .tls_config = tls_config,
        // Streaming proxy: early-emit inbound h2 requests (server side)
        // and upstream responses (client side); the proxy relays both
        // as they arrive. Worker-matched 1 MiB stream windows bound
        // per-stream buffering at the edge.
        .headers_first = true,
        .client_headers_first = true,
        .initial_window_size = 1024 * 1024,
        .max_concurrent_streams = 512,
        // WS terminates at the edge and tunnels upstream over Extended
        // CONNECT (websocket-plan §8.5): Upgrade heads surface to the
        // proxy; the 101 waits for the upstream 200.
        .websocket_upgrades = false,
        .websocket_surface = true,
    });
    var proxy = Proxy.init(allocator, &reg, server, cp_urls, &cache, resolver);
    // Teardown order matters: `server.destroy()` releases any still-live
    // body sinks, and those callbacks walk proxy-owned Flow state — so the
    // server must go down while the proxy is still alive. One defer block
    // (LIFO with separate defers would run proxy.deinit first and the sink
    // release would touch freed flows).
    defer {
        server.destroy();
        proxy.deinit();
    }

    // Phase 5: optional plaintext `:80` listener (ACME HTTP-01 + HTTP→HTTPS
    // redirect). Defaults to :80 when we terminate TLS (we own the public edge);
    // disabled in h2c mode (TLS terminated upstream → the LB owns :80). Override
    // with `REWIND_HTTP_PORT` (0 disables; a high port for tests).
    const http_port: u16 = blk: {
        if (std.posix.getenv("REWIND_HTTP_PORT")) |v|
            break :blk std.fmt.parseInt(u16, std.mem.trim(u8, v, " \t"), 10) catch 0;
        break :blk if (tls_config != null) 80 else 0;
    };
    var server80: ?*FrontH2 = null;
    var reg80_ptr: ?*rove.Registry = null;
    if (http_port != 0) {
        const r80 = try allocator.create(rove.Registry);
        r80.* = try rove.Registry.init(allocator, .{ .max_entities = 2048, .deferred_queue_capacity = 512 });
        reg80_ptr = r80;
        const addr80 = try std.net.Address.parseIp("0.0.0.0", http_port);
        server80 = try FrontH2.create(r80, allocator, addr80, .{
            .max_connections = 512,
            .buf_count = 512,
            .buf_size = 16384,
            .listen_backlog = 512,
            .reuseport = true,
        }, .{ .websocket_upgrades = false });
        std.log.info("rewind-front: :80 listener on 0.0.0.0:{d} (ACME HTTP-01 + HTTPS redirect)", .{http_port});
    }
    // server destroy must run before its registry deinit (it owns collections in
    // it), so declare the registry-cleanup defer first (LIFO → runs last).
    defer if (reg80_ptr) |r| {
        r.deinit();
        allocator.destroy(r);
    };
    defer if (server80) |s| s.destroy();

    // Proactive cert sync (only meaningful when we terminate TLS). Period from
    // `REWIND_CERT_SYNC_MS` (default 2000). Runs on its OWN thread so the
    // periodic CP pull never blocks the poll loop.
    const cert_sync_ms = envMs("REWIND_CERT_SYNC_MS", 2000);
    const cert_sync_thread: ?*CertSyncThread = if (tls_config) |t|
        try CertSyncThread.start(allocator, cp_urls, t, @intCast(cert_sync_ms * std.time.ns_per_ms))
    else
        null;
    // Join (and free) the cert-sync thread before tls_config.destroy() and
    // the cp_urls free — declared last here so LIFO runs it first.
    defer if (cert_sync_thread) |cst| cst.shutdownAndDestroy(allocator);

    // The :80 listener (ACME HTTP-01 + HTTP→HTTPS redirect) runs on its OWN
    // thread, NOT the :443 poll loop. Its ACME challenge lookup does a
    // blocking CP curl; on the main loop a slow CP would freeze :443
    // (accept/TLS handshakes stall → new HTTPS connections hang). Isolated
    // here, that blocking can only ever delay other :80 work. server80 +
    // reg80 are exclusive to this thread (the :443 loop never touches them);
    // shared state is read-only cp_urls + the atomic stop flag.
    var port80_thread: ?std.Thread = null;
    if (server80) |s80| {
        port80_thread = try std.Thread.spawn(.{}, port80Loop, .{ s80, reg80_ptr.?, allocator, cp_urls });
    }
    // Join the :80 thread before its server/registry are destroyed (declared
    // after those defers → LIFO runs this first).
    defer if (port80_thread) |t| t.join();

    std.log.info("rewind-front: listening on 0.0.0.0:{d} (cp {d} node(s), route cache {d}ms (off-loop resolve), tls {s}, streaming proxy)", .{ port, cp_urls.len, cache_ms, if (tls_config != null) "on" else "off (h2c)" });
    while (!stop_flag.load(.acquire)) {
        server.pollWithTimeout(10 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        try proxy.run(std.time.nanoTimestamp());
    }
    std.log.info("rewind-front: shut down", .{});
}

/// The :80 listener loop — its own thread (see the spawn site). Owns
/// `s80` + `reg80` exclusively. Blocking work here (the ACME challenge
/// CP lookup) cannot stall the :443 poll loop.
fn port80Loop(s80: *FrontH2, reg80: *rove.Registry, allocator: std.mem.Allocator, cp_urls: []const []const u8) void {
    while (!stop_flag.load(.acquire)) {
        s80.poll(10 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => {
                std.log.err("rewind-front :80: poll failed: {s}", .{@errorName(err)});
                return;
            },
        };
        processPort80(s80, allocator, cp_urls) catch |err|
            std.log.warn("rewind-front :80: process failed: {s}", .{@errorName(err)});
        reg80.flush() catch {};
        cleanupResponses(s80) catch {};
        reg80.flush() catch {};
    }
}
