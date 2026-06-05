//! rewind-front — the V2 front door (docs/v2-build-order.md §Phase 3,
//! docs/v2-phase3-directory-routing.md §3b).
//!
//! A small HTTP/2 terminator that routes each inbound request to the
//! cluster currently serving its tenant. Per request:
//!
//!   read :authority / Host → Host→tenant (static map) →
//!   directory.clusterFor(tenant) → reverse-proxy to cluster.base_url
//!
//! It is the one component that sees all clusters; a `rewind` worker only
//! holds the tenants placed on it, so a request for a tenant on another
//! cluster has to leave the process. The front door reads ONLY the
//! directory (cluster-agnostic), so it ports forward to multi-node (Phase
//! 5) unchanged — `base_url` just becomes a per-cluster leader address.
//!
//! ## Phase-3 simplifications (documented, deliberate)
//!
//!   - **Static config.** Clusters / Host→tenant / placement all come from
//!     env (`REWIND_CLUSTERS` / `REWIND_HOSTS` / `REWIND_PLACEMENT`). The
//!     replicated control-plane directory + domain index is later
//!     hardening behind `Directory`'s interface.
//!   - **Blocking forward, sequential.** Each proxied request runs a
//!     synchronous libcurl call inside the single-threaded h2 poll loop —
//!     fine for the Phase-3 exit smoke (sequential requests); connection
//!     pooling + concurrency is a noted deferral.
//!   - **Status + body passthrough only.** Response headers (incl.
//!     content-type) are dropped for now — the routing proof is on status
//!     codes. Real header passthrough is a follow-up.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const blob = @import("rove-blob");

const curl = blob.curl;
const directory_mod = @import("cp-directory");
const Directory = directory_mod.Directory;

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

// ── Host → tenant static map (Phase-3 stand-in for the CP domain index)─
const HostMap = struct {
    allocator: std.mem.Allocator,
    /// host → tenant store id. Both owned dups.
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) HostMap {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *HostMap) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    /// Parse `host=tenant;host=tenant;…`.
    fn seed(self: *HostMap, config: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, config, ';');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadConfig;
            const host = std.mem.trim(u8, entry[0..eq], " \t");
            const tenant = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            if (host.len == 0 or tenant.len == 0) return error.BadConfig;
            const h_dup = try self.allocator.dupe(u8, host);
            errdefer self.allocator.free(h_dup);
            const t_dup = try self.allocator.dupe(u8, tenant);
            errdefer self.allocator.free(t_dup);
            try self.map.put(self.allocator, h_dup, t_dup);
        }
    }

    fn tenantFor(self: *HostMap, host: []const u8) ?[]const u8 {
        return self.map.get(host);
    }
};

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

const MOVE_SECRET_HEADER = "X-Rewind-Move-Secret";
const TENANT_HEADER = "X-Rewind-Tenant";

/// One backend response the orchestrator cares about: status + an owned
/// copy of the body (the source bundle, relayed into the attach call).
const BackendResp = struct {
    status: u16,
    body: []u8,
    fn deinit(self: BackendResp, a: std.mem.Allocator) void {
        a.free(self.body);
    }
};

const Router = struct {
    allocator: std.mem.Allocator,
    directory: *Directory,
    hosts: *HostMap,
    /// Shared secret presented to backends' `/_system/v2-*` move surface,
    /// and required (via `X-Rewind-Move-Secret`) on `/_control/move`.
    /// Null disables the move control surface (503).
    move_secret: ?[]const u8,

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

    /// Reply with a status + owned text body (`msg` is freed by the
    /// registry via `RespBody.deinit`).
    fn replyText(server: *FrontH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16, msg: []u8) !void {
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = msg.ptr, .len = @intCast(msg.len) });
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

        for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
            const req_path = headerValue(rh, ":path") orelse "/";

            // 0. Control plane: `/_control/move` is handled by the front
            //    door itself (the move orchestrator), not proxied to a
            //    backend. It is the one component that sees all clusters +
            //    owns the directory, so the move's directory flip is its
            //    atomic commit point.
            if (std.mem.startsWith(u8, req_path, "/_control/")) {
                try self.handleControl(server, ent, sid, sess, rh, rb, req_path);
                continue;
            }

            // 1. Resolve the inbound tenant from :authority (fall back to
            //    Host). Strip any `:port` — the host map is keyed on the
            //    bare hostname, matching the worker's `hostOnly`.
            const authority_raw = headerValue(rh, ":authority") orelse headerValue(rh, "host") orelse {
                try replyStatus(server, ent, sid, sess, 400); // no host → bad request
                continue;
            };
            const authority = hostOnly(authority_raw);
            const tenant = self.hosts.tenantFor(authority) orelse {
                std.log.warn("front: no tenant for host {s} → 404", .{authority});
                try replyStatus(server, ent, sid, sess, 404);
                continue;
            };
            const resolution = self.directory.resolve(tenant) orelse {
                std.log.warn("front: tenant {s} unplaced → 421", .{tenant});
                try replyStatus(server, ent, sid, sess, 421); // misdirected: no placement
                continue;
            };
            // Mid-move: hold the tenant's traffic with a retryable 503
            // until the directory flip completes (the brief pause).
            if (resolution.moving) {
                try replyStatus(server, ent, sid, sess, 503);
                continue;
            }
            const method_s = headerValue(rh, ":method") orelse "GET";
            const method = methodFrom(method_s) orelse {
                try replyStatus(server, ent, sid, sess, 405);
                continue;
            };

            // 2. Forward to the cluster, leader-aware (Phase 5). A
            //    multi-node cluster has N node origins but only the tenant's
            //    group leader takes writes; a follower 503s a write (the
            //    bridge faults a non-leader propose), so try nodes in order
            //    and stop at the first non-503. A single-node cluster has
            //    one node — one attempt, unchanged from the milestone.
            try self.proxyToCluster(server, ent, sid, sess, rh, rb, req_path, authority, method, resolution.cluster.nodes);
        }
    }

    /// Reverse-proxy one request to whichever node of `nodes` currently
    /// leads the tenant's group, discovered by retrying on 503 (a follower's
    /// not-leader response). Relays the first non-503 backend response (or
    /// the last 503 if every node is a follower / mid-election — the client
    /// retries). A transport error against one node falls through to the
    /// next; all-failed → 502. The forward headers + body are built once and
    /// reused across node attempts (a retried write re-POSTs the same body —
    /// safe, since only the leader commits it).
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
    ) !void {
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

        // The relay state we keep from the chosen attempt (owned body copy
        // freed by the registry via RespBody.deinit).
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

            // Relay this response: copy the body into a registry-owned alloc.
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
            return;
        }
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = relay_status });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = relay_data, .len = relay_len });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        try server.reg.move(ent, &server.request_out, &server.response_in);
    }

    // ── Control plane: tenant-move orchestration ─────────────────────

    /// Route + auth a `/_control/*` request. Only `POST /_control/move`
    /// exists; it requires the move secret (`X-Rewind-Move-Secret`).
    fn handleControl(
        self: *Router,
        server: *FrontH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        rh: h2.ReqHeaders,
        rb: h2.ReqBody,
        path: []const u8,
    ) !void {
        const method_s = headerValue(rh, ":method") orelse "GET";
        if (!std.mem.eql(u8, path, "/_control/move") or !std.mem.eql(u8, method_s, "POST")) {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        }
        const secret = self.move_secret orelse {
            try replyStatus(server, ent, sid, sess, 503); // move surface disabled
            return;
        };
        const presented = headerValue(rh, MOVE_SECRET_HEADER) orelse "";
        if (presented.len != secret.len or !std.mem.eql(u8, presented, secret)) {
            try replyStatus(server, ent, sid, sess, 401);
            return;
        }
        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else &.{};
        try self.handleMove(server, ent, sid, sess, body);
    }

    /// Orchestrate a brief-pause tenant move (docs/v2-build-order.md
    /// §Phase 4): hold the tenant → dump+quiesce on source → ship the
    /// bundle to the destination → attach there → **flip the directory**
    /// (the commit point) → evict the source. On any pre-flip failure the
    /// directory reverts and the source is resumed, so a failed move is a
    /// no-op the tenant survives.
    fn handleMove(self: *Router, server: *FrontH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
            dest: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        const dest = parsed.value.dest;
        if (tenant.len == 0 or dest.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }

        const resolution = self.directory.resolve(tenant) orelse {
            try replyStatus(server, ent, sid, sess, 404); // unknown tenant
            return;
        };
        if (resolution.moving) {
            try replyStatus(server, ent, sid, sess, 409); // already moving
            return;
        }
        const src = resolution.cluster;
        if (std.mem.eql(u8, src.id, dest)) {
            try replyStatus(server, ent, sid, sess, 400); // already on dest
            return;
        }
        const dest_ref = self.directory.clusterById(dest) orelse {
            try replyStatus(server, ent, sid, sess, 400); // unknown dest cluster
            return;
        };
        // The node lists are pointer-stable for the directory's lifetime, so
        // these slices stay valid across the blocking backend calls below.
        const src_nodes = src.nodes;
        const dest_nodes = dest_ref.nodes;

        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(tbody);

        self.directory.beginMove(tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };

        // 1. Quiesce + dump the source LEADER (v2-bundle is leader-gated —
        //    a follower 421s, so try each source node until one returns the
        //    bundle). Single-node source → one node, the leader.
        var dump = self.bundleFromLeader(src_nodes, tbody) orelse {
            self.resumeAll(tenant, src_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        };
        defer dump.deinit(a);

        // 2. Attach on EVERY destination node (the group is formed across the
        //    whole destination cluster: each node loads the bundle + creates
        //    its incarnation at the migration epoch). All must 204; on any
        //    failure, evict the nodes that did attach + resume the source.
        if (!self.attachToAll(dest_nodes, dump.body, tenant)) {
            self.evictAll(tenant, dest_nodes, tbody);
            self.resumeAll(tenant, src_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }

        // 3. Await the freshly formed destination group's election so
        //    post-move traffic finds a leader immediately (v2-leader polls).
        if (!self.awaitDestLeader(dest_nodes, tenant)) {
            self.evictAll(tenant, dest_nodes, tbody);
            self.resumeAll(tenant, src_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        }

        // 4. Flip the directory — the atomic commit point of the move.
        self.directory.move(tenant, dest) catch {
            // Both tenant + dest were validated above; a failure here is
            // an invariant violation. Leave moving-held + surface 500.
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };

        // 5. Evict the source on EVERY source node (destroy each group
        //    incarnation + drop the instance). Best-effort: the move already
        //    committed; a stale source group is reclaimed lazily and never
        //    serves traffic again.
        self.evictAll(tenant, src_nodes, tbody);

        const msg = std.fmt.allocPrint(a, "moved {s}: {s} -> {s}\n", .{ tenant, src.id, dest }) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Try each source node's leader-gated `/_system/v2-bundle` until one
    /// returns 200 (the group leader) and hand back its bundle body. A
    /// follower 421s (no quiesce taken there). Null if no node produced a
    /// bundle (none is the leader / all unreachable). The caller owns the
    /// returned `BackendResp`.
    fn bundleFromLeader(self: *Router, src_nodes: []const []const u8, tbody: []const u8) ?BackendResp {
        const a = self.allocator;
        for (src_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-bundle", .POST, tbody, null) catch |err| {
                std.log.warn("front: v2-bundle on {s} failed: {s}", .{ base, @errorName(err) });
                continue;
            };
            if (resp.status == 200) return resp;
            var r = resp;
            r.deinit(a); // 421 follower / other — try the next node
        }
        return null;
    }

    /// Fan a `/_system/v2-attach` (bundle + `X-Rewind-Tenant`) out to every
    /// destination node. True only if all returned 204 (idempotent
    /// re-attach included). On the first failure returns false; the caller
    /// evicts the partially-attached set.
    fn attachToAll(self: *Router, dest_nodes: []const []const u8, bundle: []const u8, tenant: []const u8) bool {
        const a = self.allocator;
        for (dest_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-attach", .POST, bundle, tenant) catch |err| {
                std.log.warn("front: v2-attach on {s} failed: {s}", .{ base, @errorName(err) });
                return false;
            };
            var r = resp;
            defer r.deinit(a);
            if (r.status != 204) {
                std.log.warn("front: v2-attach on {s} → {d}", .{ base, r.status });
                return false;
            }
        }
        return true;
    }

    /// Poll every destination node's `/_system/v2-leader?tenant=…` until one
    /// reports 200 (the formed group elected a leader), bounded by a wall
    /// deadline. True once a leader is seen; false on timeout.
    fn awaitDestLeader(self: *Router, dest_nodes: []const []const u8, tenant: []const u8) bool {
        const a = self.allocator;
        const suffix = std.fmt.allocPrint(a, "/_system/v2-leader?tenant={s}", .{tenant}) catch return false;
        defer a.free(suffix);
        const deadline: i128 = std.time.nanoTimestamp() + 15 * std.time.ns_per_s;
        while (std.time.nanoTimestamp() < deadline) {
            for (dest_nodes) |base| {
                const resp = self.backendCall(base, suffix, .GET, "", null) catch continue;
                var r = resp;
                r.deinit(a);
                if (r.status == 200) return true;
            }
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return false;
    }

    /// Best-effort `/_system/v2-evict` to every node of a cluster (the move
    /// committed, or we are unwinding a partial attach). Logs failures.
    fn evictAll(self: *Router, tenant: []const u8, nodes: []const []const u8, tbody: []const u8) void {
        const a = self.allocator;
        for (nodes) |base| {
            if (self.backendCall(base, "/_system/v2-evict", .POST, tbody, null)) |ev| {
                var e2 = ev;
                e2.deinit(a);
            } else |err| {
                std.log.warn("front: evict {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    /// Abort path: revert the directory hold + resume EVERY source node (lift
    /// the leader's quiesce; a no-op on followers that never quiesced) so a
    /// failed move leaves the tenant serving where it started. Best-effort.
    fn resumeAll(self: *Router, tenant: []const u8, src_nodes: []const []const u8, tbody: []const u8) void {
        const a = self.allocator;
        self.directory.abortMove(tenant) catch {};
        for (src_nodes) |base| {
            if (self.backendCall(base, "/_system/v2-resume", .POST, tbody, null)) |r| {
                var rr = r;
                rr.deinit(a);
            } else |err| {
                std.log.warn("front: resume source {s} ({s}) failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    /// Blocking libcurl call to a backend's move surface, presenting the
    /// move secret (+ optional `X-Rewind-Tenant`). Returns status + an
    /// owned copy of the response body.
    fn backendCall(
        self: *Router,
        base_url: []const u8,
        path_suffix: []const u8,
        method: curl.Method,
        body: []const u8,
        tenant_hdr: ?[]const u8,
    ) !BackendResp {
        const a = self.allocator;
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ base_url, path_suffix });
        defer a.free(url);

        var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
        defer headers.deinit(a);
        try headers.append(a, .{ .name = MOVE_SECRET_HEADER, .value = self.move_secret.? });
        if (tenant_hdr) |t| try headers.append(a, .{ .name = TENANT_HEADER, .value = t });

        var easy = try curl.Easy.init(a);
        defer easy.deinit();
        var resp = try easy.request(a, .{
            .method = method,
            .url = url,
            .headers = headers.items,
            .body = body,
            .http_version = .h2c_prior_knowledge,
            .verify_tls = false,
        });
        defer resp.deinit(a);

        const body_copy = if (resp.body) |b| try a.dupe(u8, b) else try a.dupe(u8, "");
        return .{ .status = resp.status, .body = body_copy };
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

pub fn main() !void {
    curl.globalInit();
    const allocator = std.heap.c_allocator;
    installSignalHandlers();

    var arg_it = std.process.args();
    _ = arg_it.next();
    const port_str = arg_it.next() orelse "8080";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // Static config (Phase-3 stand-in for the replicated control plane).
    var directory = Directory.init(allocator);
    defer directory.deinit();
    try directory.seedClusters(getEnvCfg("REWIND_CLUSTERS"));
    try directory.seedPlacements(getEnvCfg("REWIND_PLACEMENT"));

    var hosts = HostMap.init(allocator);
    defer hosts.deinit();
    try hosts.seed(getEnvCfg("REWIND_HOSTS"));

    // V2 Phase 4 — shared secret for the cluster-internal move surface.
    // The front door presents it to backends' `/_system/v2-*` endpoints
    // and requires it on `/_control/move`. Unset → move control disabled.
    const move_secret: ?[]const u8 = std.posix.getenv("REWIND_MOVE_SECRET");

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

    var router = Router{ .allocator = allocator, .directory = &directory, .hosts = &hosts, .move_secret = move_secret };

    std.log.info("rewind-front: listening on 0.0.0.0:{d} (move control {s})", .{ port, if (move_secret != null) "enabled" else "disabled" });
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
