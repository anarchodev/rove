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
//!   - **Status + headers + body passthrough.** The backend's response
//!     headers (content-type et al.) are relayed (`packRespHeaders`),
//!     lowercased for h2, minus hop-by-hop + framing headers.
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

/// Split the CP's packed cert frame (`[4B BE cert_len][cert_pem][key_pem]`).
const UnpackedCert = struct { cert: []const u8, key: []const u8 };
fn unpackCert(frame: []const u8) ?UnpackedCert {
    if (frame.len < 4) return null;
    const clen = std.mem.readInt(u32, frame[0..4], .big);
    if (4 + clen > frame.len) return null;
    return .{ .cert = frame[4 .. 4 + clen], .key = frame[4 + clen ..] };
}

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
                // `putOwned` stores (and now owns) `owned`; return it directly
                // rather than re-`get`-ting — a re-get with a 0ms TTL
                // (always-fresh mode) would miss and panic the `.?`. The slice
                // stays valid for this loop iteration (no eviction until a
                // later put/invalidate).
                try self.cache.putOwned(host, owned, now_ns);
                return .{ .nodes = owned };
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
        var relay_headers: h2.RespHeaders = .{ .fields = null, .count = 0 };

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
            // Relay the backend's response headers (content-type et al.). Packed
            // into its own buffer, so it survives `resp.deinit` at loop end.
            relay_headers = packRespHeaders(a, resp.headers) catch .{ .fields = null, .count = 0 };
            have_resp = true;
            break;
        }

        if (!have_resp) {
            try replyStatus(server, ent, sid, sess, 502);
            return 502;
        }
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = relay_status });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, relay_headers);
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

// ── Phase 5: the :80 plaintext listener (ACME HTTP-01 + HTTP→HTTPS redirect) ──
//
// rove-h2 now speaks HTTP/1.1 (gap #6 phases 1–4), so the front door answers
// the ACME HTTP-01 `:80` challenge natively — retiring the gap #3 slice-3 `:80`
// wrinkle. Two behaviors: serve `/.well-known/acme-challenge/<token>` (the
// key-authorization fetched from the CP issuer, slice 3) and 308-redirect every
// other request to its HTTPS origin.

const ACME_PREFIX = "/.well-known/acme-challenge/";

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

/// A response header that must NOT be relayed through the proxy: connection-
/// specific (hop-by-hop) headers, plus framing headers the h2/h1 response layer
/// owns (`content-length` — nghttp2 frames DATA / the h1 serializer recomputes
/// it from the buffered body; `transfer-encoding` — chunked is the h1 codec's,
/// never crosses to h2). `:status` is the status line, not a header here.
fn dropFromResponse(name: []const u8) bool {
    return isHopByHop(name) or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        (name.len > 0 and name[0] == ':');
}

/// Pack a backend's response headers into the `h2.RespHeaders` layout (one
/// buffer: field array + name/value bytes, freed by `RespHeaders.deinit`).
/// Names are lowercased — HTTP/2 requires lowercase field names, and the h1
/// codec is case-insensitive — so `content-type` et al. survive the proxy hop.
/// Hop-by-hop + framing headers are dropped. Empty result ⇒ null fields.
fn packRespHeaders(a: std.mem.Allocator, headers: []const curl.Header) !h2.RespHeaders {
    const HF = h2.HeaderField;
    var n: usize = 0;
    var strbytes: usize = 0;
    for (headers) |h| {
        if (dropFromResponse(h.name)) continue;
        n += 1;
        strbytes += h.name.len + h.value.len;
    }
    if (n == 0) return .{ .fields = null, .count = 0 };

    const fields_size = n * @sizeOf(HF);
    const total = fields_size + strbytes;
    const buf = try a.alloc(u8, total);
    const fields: [*]HF = @ptrCast(@alignCast(buf.ptr));
    const sb = buf.ptr + fields_size;

    var soff: usize = 0;
    var fi: usize = 0;
    for (headers) |h| {
        if (dropFromResponse(h.name)) continue;
        const noff = soff;
        @memcpy(sb[noff .. noff + h.name.len], h.name);
        for (sb[noff .. noff + h.name.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
        soff += h.name.len;
        const voff = soff;
        @memcpy(sb[voff .. voff + h.value.len], h.value);
        soff += h.value.len;
        fields[fi] = .{ .name = sb + noff, .name_len = @intCast(h.name.len), .value = sb + voff, .value_len = @intCast(h.value.len) };
        fi += 1;
    }
    return .{ .fields = fields, .count = @intCast(n), ._buf = buf.ptr, ._buf_len = @intCast(total) };
}

/// Reply with status + headers + (optional, owned) body. Mirrors
/// `Router.replyStatus` but carries a header set and body.
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
/// Owned 200 body or null (no active challenge / CP unreachable). The CP
/// endpoint itself is gap #3 slice 3 — until it exists this 404s, which is the
/// correct answer for "no challenge in flight."
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
        const path = headerValue(rh, ":path") orelse "/";

        // ACME HTTP-01: serve the key-authorization fetched from the CP.
        if (std.mem.startsWith(u8, path, ACME_PREFIX)) {
            const token = path[ACME_PREFIX.len..];
            if (token.len > 0) {
                if (acmeChallengeLookup(a, cp_urls, token)) |ka| {
                    const ct = packRespHeader(a, "content-type", "text/plain") catch {
                        a.free(ka);
                        try Router.replyStatus(server, ent, sid, sess, 500);
                        continue;
                    };
                    try replyFull(server, ent, sid, sess, 200, ct, ka);
                    continue;
                }
            }
            try Router.replyStatus(server, ent, sid, sess, 404);
            continue;
        }

        // Everything else → 308 to the HTTPS origin (preserves method + body).
        const host_raw = headerValue(rh, ":authority") orelse headerValue(rh, "host") orelse {
            try Router.replyStatus(server, ent, sid, sess, 400);
            continue;
        };
        const host = hostOnly(host_raw);
        const location = std.fmt.allocPrint(a, "https://{s}{s}", .{ host, path }) catch {
            try Router.replyStatus(server, ent, sid, sess, 500);
            continue;
        };
        defer a.free(location);
        const loc = packRespHeader(a, "location", location) catch {
            try Router.replyStatus(server, ent, sid, sess, 500);
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
    }, .{ .tls_config = tls_config });
    defer server.destroy();

    var router = Router{ .allocator = allocator, .cp_urls = cp_urls, .cache = &cache };

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
        }, .{});
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
    // `REWIND_CERT_SYNC_MS` (default 2000); first pass runs before serving so a
    // restart re-populates the SNI store immediately.
    var cert_sync: ?CertSync = if (tls_config) |t|
        .{ .allocator = allocator, .cp_urls = cp_urls, .tls = t }
    else
        null;
    const cert_sync_ms: i128 = blk: {
        const s = std.posix.getenv("REWIND_CERT_SYNC_MS") orelse break :blk 2000;
        break :blk std.fmt.parseInt(i128, std.mem.trim(u8, s, " \t"), 10) catch 2000;
    };
    const cert_sync_period_ns: i128 = cert_sync_ms * std.time.ns_per_ms;
    var last_cert_sync_ns: i128 = 0;
    if (cert_sync) |*cs| cs.sync();

    std.log.info("rewind-front: listening on 0.0.0.0:{d} (cp {d} node(s), route cache {d}ms, tls {s})", .{ port, cp_urls.len, cache_ms, if (tls_config != null) "on" else "off (h2c)" });
    while (!stop_flag.load(.acquire)) {
        server.pollWithTimeout(10 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        try router.processRequests(server);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();

        // Phase 5: drain the low-traffic :80 listener non-blocking (its latency
        // budget — ACME validation, redirects — tolerates the ~10ms main cycle).
        if (server80) |s80| {
            s80.poll(0) catch |err| switch (err) {
                error.SignalInterrupt => {},
                else => return err,
            };
            try processPort80(s80, allocator, cp_urls);
            try reg80_ptr.?.flush();
            try cleanupResponses(s80);
            try reg80_ptr.?.flush();
        }

        if (cert_sync) |*cs| {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_cert_sync_ns > cert_sync_period_ns) {
                last_cert_sync_ns = now_ns;
                cs.sync();
            }
        }
    }
    std.log.info("rewind-front: shut down", .{});
}
