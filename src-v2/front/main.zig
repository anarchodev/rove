//! rewind-front — the V2 front door (docs/v2-front-door-architecture.md).
//!
//! A STATELESS HTTP/2 reverse proxy. Per customer request:
//!
//!   read :authority / Host → resolve placement via the CP's
//!   `/_cp/route?host=H` (cached) → reverse-proxy to the owning cluster's
//!   nodes (leader-aware retry on 503).
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
//! ## Deliberate first-cut simplifications
//!
//!   - **Blocking forward, sequential.** Each proxied request (and each CP
//!     route lookup on a cache miss) runs a synchronous libcurl call inside
//!     the single-threaded h2 poll loop; connection pooling + concurrency is
//!     a noted deferral. Horizontal scaling is multiple front-door processes
//!     (SO_REUSEPORT) behind the L4 ingress, not threads.
//!   - **Status + body passthrough only.** Response headers (incl.
//!     content-type) are dropped for now — a follow-up before cutover.
//!   - **h2c.** Public TLS termination is a later slice; today the front door
//!     speaks h2c and assumes TLS is terminated upstream.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const blob = @import("rove-blob");

const curl = blob.curl;

const FrontH2 = h2.H2(.{});

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

// ── Header lookup over h2 ReqHeaders ──────────────────────────────────
fn headerValue(rh: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    const fields = rh.fields orelse return null;
    var i: u32 = 0;
    while (i < rh.count) : (i += 1) {
        const f = fields[i];
        const fname = f.name[0..f.name_len];
        if (std.ascii.eqlIgnoreCase(fname, name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

fn methodFrom(s: []const u8) ?curl.Method {
    if (std.mem.eql(u8, s, "GET")) return .GET;
    if (std.mem.eql(u8, s, "PUT")) return .PUT;
    if (std.mem.eql(u8, s, "POST")) return .POST;
    if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
    return null;
}

// ── Owned-node helpers ────────────────────────────────────────────────
fn dupNodes(a: std.mem.Allocator, src: []const []const u8) ![][]u8 {
    const out = try a.alloc([]u8, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |n| a.free(n);
        a.free(out);
    }
    for (src, 0..) |n, i| {
        out[i] = try a.dupe(u8, n);
        filled = i + 1;
    }
    return out;
}

fn freeNodes(a: std.mem.Allocator, nodes: [][]u8) void {
    for (nodes) |n| a.free(n);
    a.free(nodes);
}

// ── Route cache (host → cluster nodes, short TTL) ─────────────────────
//
// The front door is single-threaded (one poll loop), so the cache needs no
// locking; horizontal scaling is separate processes. A stale entry is safe —
// serve-or-forward at the DP corrects a wrong cluster, so the only cost is a
// hop. Entries simply expire (checked on read); no active eviction in the
// first cut (size is bounded by distinct active hosts — a noted follow-up if
// that grows unbounded).
const RouteCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    ttl_ns: i128,

    const Entry = struct {
        nodes: [][]u8,
        expires_ns: i128,
    };

    fn init(allocator: std.mem.Allocator, ttl_ns: i128) RouteCache {
        return .{ .allocator = allocator, .ttl_ns = ttl_ns };
    }

    fn deinit(self: *RouteCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            freeNodes(self.allocator, e.value_ptr.nodes);
        }
        self.map.deinit(self.allocator);
    }

    /// Fresh node list for `host`, or null (miss / expired).
    fn get(self: *RouteCache, host: []const u8, now_ns: i128) ?[]const []const u8 {
        const e = self.map.getPtr(host) orelse return null;
        if (now_ns >= e.expires_ns) return null;
        return e.nodes;
    }

    /// Cache `owned_nodes` (ownership transferred) for `host` with the
    /// configured TTL. Replaces + frees any existing entry's nodes.
    fn putOwned(self: *RouteCache, host: []const u8, owned_nodes: [][]u8, now_ns: i128) !void {
        errdefer freeNodes(self.allocator, owned_nodes);
        const gop = try self.map.getOrPut(self.allocator, host);
        if (gop.found_existing) {
            freeNodes(self.allocator, gop.value_ptr.nodes);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, host) catch |e| {
                self.map.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.nodes = owned_nodes;
        gop.value_ptr.expires_ns = now_ns + self.ttl_ns;
    }

    /// Drop a host's entry (e.g. its cluster stopped answering — likely
    /// moved/evicted; re-query the CP next time).
    fn invalidate(self: *RouteCache, host: []const u8) void {
        if (self.map.fetchRemove(host)) |kv| {
            self.allocator.free(kv.key);
            freeNodes(self.allocator, kv.value.nodes);
        }
    }
};

// ── CP route lookup result ────────────────────────────────────────────
const CpRoute = union(enum) {
    not_found,
    moving,
    placed: [][]u8, // owned node URLs
};

const RouteResult = union(enum) {
    nodes: []const []const u8, // cache-owned; valid for this loop iteration
    moving,
    not_found,
};

const Router = struct {
    allocator: std.mem.Allocator,
    /// CP origins to resolve placement against (any node answers `/_cp/route`;
    /// it's a read served from every CP node's projection). Tried in order;
    /// the first reachable one wins. `REWIND_CP_URL`.
    cp_urls: []const []const u8,
    cache: *RouteCache,

    /// Reply helper: set an immediate status (no body) on the request
    /// entity and move it to response_in.
    fn replyStatus(server: *FrontH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16) !void {
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        try server.reg.move(ent, &server.request_out, &server.response_in);
    }

    fn processRequests(self: *Router, server: *FrontH2) !void {
        const entities = server.request_out.entitySlice();
        const sids = server.request_out.column(h2.StreamId);
        const sessions = server.request_out.column(h2.Session);
        const req_hdrs = server.request_out.column(h2.ReqHeaders);
        const req_bodies = server.request_out.column(h2.ReqBody);

        const now_ns = std.time.nanoTimestamp();
        for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
            // Resolve the inbound tenant's cluster from :authority (fall back
            // to Host). Strip any `:port` — placement is keyed on the bare
            // hostname, matching the worker's `hostOnly`.
            const authority_raw = headerValue(rh, ":authority") orelse headerValue(rh, "host") orelse {
                try replyStatus(server, ent, sid, sess, 400); // no host → bad request
                continue;
            };
            const authority = hostOnly(authority_raw);

            const route = self.resolveRoute(authority, now_ns) catch {
                // CP unreachable — can't determine placement; client retries.
                std.log.warn("front: CP route lookup for {s} failed → 503", .{authority});
                try replyStatus(server, ent, sid, sess, 503);
                continue;
            };
            switch (route) {
                .not_found => {
                    std.log.warn("front: no placement for host {s} → 404", .{authority});
                    try replyStatus(server, ent, sid, sess, 404);
                },
                // Mid-move: hold the tenant's traffic with a retryable 503
                // until the directory flip completes (the brief pause).
                .moving => try replyStatus(server, ent, sid, sess, 503),
                .nodes => |nodes| {
                    const req_path = headerValue(rh, ":path") orelse "/";
                    const method_s = headerValue(rh, ":method") orelse "GET";
                    const method = methodFrom(method_s) orelse {
                        try replyStatus(server, ent, sid, sess, 405);
                        continue;
                    };
                    const st = try self.proxyToCluster(server, ent, sid, sess, rh, rb, req_path, authority, method, nodes);
                    // All nodes unreachable (502) → the cached cluster is
                    // likely stale (moved/evicted). Drop it so the next
                    // request re-resolves against the CP.
                    if (st == 502) self.cache.invalidate(authority);
                },
            }
        }
    }

    /// Resolve `host` → cluster nodes, cache-first. On miss, query the CP and
    /// cache the result (unless `moving`, which is transient). Errors only if
    /// no CP node is reachable.
    fn resolveRoute(self: *Router, host: []const u8, now_ns: i128) !RouteResult {
        if (self.cache.get(host, now_ns)) |nodes| return .{ .nodes = nodes };
        switch (try self.cpRouteQuery(host)) {
            .not_found => return .not_found,
            .moving => return .moving,
            .placed => |owned| {
                try self.cache.putOwned(host, owned, now_ns);
                return .{ .nodes = self.cache.get(host, now_ns).? };
            },
        }
    }

    /// Query the CP's `GET /_cp/route?host=H`, trying each CP origin until one
    /// answers. 200 → parse `{cluster,tenant,moving,nodes}` (moving → `.moving`,
    /// else `.placed` with owned nodes); 404 → `.not_found`. Errors if no CP
    /// node returned a usable response.
    fn cpRouteQuery(self: *Router, host: []const u8) !CpRoute {
        const a = self.allocator;
        const suffix = try std.fmt.allocPrint(a, "/_cp/route?host={s}", .{host});
        defer a.free(suffix);

        var last_err: anyerror = error.CpUnreachable;
        for (self.cp_urls) |base| {
            const url = std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix }) catch |e| {
                last_err = e;
                continue;
            };
            defer a.free(url);
            var easy = curl.Easy.init(a) catch |e| {
                last_err = e;
                continue;
            };
            defer easy.deinit();
            var resp = easy.request(a, .{
                .method = .GET,
                .url = url,
                .headers = &[_]curl.Header{},
                .body = "",
                .http_version = .h2c_prior_knowledge,
                .verify_tls = false,
            }) catch |e| {
                std.log.warn("front: CP route {s} on {s} failed: {s}", .{ host, base, @errorName(e) });
                last_err = e;
                continue;
            };
            defer resp.deinit(a);

            if (resp.status == 404) return .not_found;
            if (resp.status != 200) {
                last_err = error.CpBadStatus;
                continue; // try the next CP node
            }
            const body = resp.body orelse "";
            var parsed = std.json.parseFromSlice(struct {
                cluster: []const u8 = "",
                tenant: []const u8 = "",
                moving: bool = false,
                nodes: []const []const u8 = &.{},
            }, a, body, .{ .ignore_unknown_fields = true }) catch {
                last_err = error.CpBadBody;
                continue;
            };
            defer parsed.deinit();
            if (parsed.value.moving) return .moving;
            return .{ .placed = try dupNodes(a, parsed.value.nodes) };
        }
        return last_err;
    }

    /// Reverse-proxy one request to whichever node of `nodes` currently leads
    /// the tenant's group, discovered by retrying on 503 (a follower's
    /// not-leader response). Relays the first non-503 backend response (or the
    /// last 503 if every node is a follower / mid-election — the client
    /// retries). A transport error against one node falls through to the next;
    /// all-failed → 502. Returns the relayed status (502 sentinel on
    /// all-failed) so the caller can invalidate a stale cache entry.
    fn proxyToCluster(
        self: *Router,
        server: *FrontH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        rh: h2.ReqHeaders,
        rb: h2.ReqBody,
        path: []const u8,
        authority: []const u8,
        method: curl.Method,
        nodes: []const []const u8,
    ) !u16 {
        const a = self.allocator;

        // Forward non-pseudo request headers, overriding Host to the
        // original authority so the backend resolves the same domain.
        var fwd_headers: std.ArrayListUnmanaged(curl.Header) = .empty;
        defer fwd_headers.deinit(a);
        try fwd_headers.append(a, .{ .name = "Host", .value = authority });
        if (rh.fields) |fields| {
            var i: u32 = 0;
            while (i < rh.count) : (i += 1) {
                const f = fields[i];
                const fname = f.name[0..f.name_len];
                if (fname.len > 0 and fname[0] == ':') continue; // pseudo
                if (std.ascii.eqlIgnoreCase(fname, "host")) continue; // set above
                if (isHopByHop(fname)) continue;
                try fwd_headers.append(a, .{ .name = fname, .value = f.value[0..f.value_len] });
            }
        }
        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else &.{};

        var have_resp = false;
        var relay_status: u16 = 502;
        var relay_data: ?[*]u8 = null;
        var relay_len: u32 = 0;

        for (nodes, 0..) |node_base, ni| {
            const last = ni + 1 == nodes.len;
            const url = try std.fmt.allocPrint(a, "{s}{s}", .{ node_base, path });
            defer a.free(url);

            var easy = curl.Easy.init(a) catch {
                if (!last) continue;
                break;
            };
            defer easy.deinit();
            var resp = easy.request(a, .{
                .method = method,
                .url = url,
                .headers = fwd_headers.items,
                .body = body,
                .http_version = .h2c_prior_knowledge,
                .verify_tls = false,
            }) catch |e| {
                std.log.warn("front: forward {s} → {s} failed: {s}", .{ authority, url, @errorName(e) });
                if (!last) continue;
                break;
            };
            defer resp.deinit(a);

            // A 503 from a non-last node means "not the leader" — try next.
            if (resp.status == 503 and !last) continue;

            relay_status = resp.status;
            relay_data = null;
            relay_len = 0;
            if (resp.body) |bdy| {
                if (bdy.len > 0) {
                    const copy = a.alloc(u8, bdy.len) catch {
                        if (!last) continue;
                        break;
                    };
                    @memcpy(copy, bdy);
                    relay_data = copy.ptr;
                    relay_len = @intCast(bdy.len);
                }
            }
            have_resp = true;
            break;
        }

        if (!have_resp) {
            try replyStatus(server, ent, sid, sess, 502);
            return 502;
        }
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = relay_status });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = relay_data, .len = relay_len });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        try server.reg.move(ent, &server.request_out, &server.response_in);
        return relay_status;
    }
};

/// Strip a `:port` suffix from an `:authority` / Host value, matching the
/// worker's `hostOnly`. Leaves bare hostnames untouched.
fn hostOnly(authority: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |i| return authority[0..i];
    return authority;
}

/// hop-by-hop headers must not be forwarded across a proxy (RFC 7230 §6.1).
fn isHopByHop(name: []const u8) bool {
    const hop = [_][]const u8{
        "connection",        "keep-alive",         "proxy-authenticate",
        "proxy-authorization", "te",               "trailer",
        "transfer-encoding", "upgrade",
    };
    for (hop) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

fn cleanupResponses(server: *FrontH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

fn getEnvCfg(name: []const u8) []const u8 {
    return std.posix.getenv(name) orelse "";
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

    // Route-cache TTL (ms). A stale entry costs at most a serve-or-forward hop,
    // so keep it short but non-zero to keep the CP off the per-request path.
    const cache_ms: i128 = blk: {
        const s = std.posix.getenv("REWIND_ROUTE_CACHE_MS") orelse break :blk 1000;
        break :blk std.fmt.parseInt(i128, std.mem.trim(u8, s, " \t"), 10) catch 1000;
    };
    var cache = RouteCache.init(allocator, cache_ms * std.time.ns_per_ms);
    defer cache.deinit();

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 8192,
        .deferred_queue_capacity = 2048,
    });
    defer reg.deinit();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    const server = try FrontH2.create(&reg, allocator, addr, .{
        .max_connections = 1024,
        .buf_count = 1024,
        .buf_size = 16384,
        .listen_backlog = 1024,
        .reuseport = true,
    }, .{ .tls_config = null });
    defer server.destroy();

    var router = Router{ .allocator = allocator, .cp_urls = cp_urls, .cache = &cache };

    std.log.info("rewind-front: listening on 0.0.0.0:{d} (cp {d} node(s), route cache {d}ms)", .{ port, cp_urls.len, cache_ms });
    while (!stop_flag.load(.acquire)) {
        server.pollWithTimeout(10 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        try router.processRequests(server);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
    std.log.info("rewind-front: shut down", .{});
}
