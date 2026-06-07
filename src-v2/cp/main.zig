//! rewind-cp — the V2 control plane (docs/v2-front-door-architecture.md).
//!
//! The CP is the authoritative, replicated directory: it owns placement
//! (tenant → cluster), the host→tenant index, and orchestrates moves. It
//! runs as its OWN small raft cluster (3–5 voters) and is **never on the
//! request hot path** — the stateless `rewind-front` proxy learns placement
//! from this binary's `/_cp/route` endpoint and caches it.
//!
//! This split fixes the prototype's inverted scaling: previously the front
//! door hosted the directory raft, so every front-door replica was a CP
//! voter (front-door count == voter count). Now the directory raft lives
//! only here; front doors scale horizontally as stateless read-replicas.
//!
//! Surface served (control only — NO customer traffic):
//!   - `POST /_control/move` / `/_control/move-live` — move orchestration
//!     (the directory flip is the atomic commit point; a directory WRITE,
//!     so leader-gated with follower→leader forwarding for CP HA).
//!   - `GET  /_cp/route?host=H` — authoritative owner lookup (front-door
//!     routing + DP serve-or-forward consult this).
//!   - `GET  /_cp/leader` — directory-group leader probe (CP HA discovery).
//!
//! Storage + HA config mirror the worker's: `REWIND_CP_DATA_DIR` (durable
//! directory store), `REWIND_CP_NODE_ID`/`VOTERS`/`PEERS` (multi-node raft),
//! `REWIND_CP_PEER_URLS` (peer HTTP origins for write forwarding).

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const blob = @import("rove-blob");

const curl = blob.curl;
const directory_mod = @import("cp-directory");
const Directory = directory_mod.Directory;
const bridge_mod = @import("bridge");
const Bridge = bridge_mod.Bridge;

const CpH2 = h2.H2(.{});

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

// ── Multi-node CP (HA) config ─────────────────────────────────────────

/// Parsed multi-node CP bridge config, owned for the lifetime of the
/// `initMultiNode` call (the slices are duped by the node/transport, so this
/// is freed right after). `null` = single-node CP.
const CpMultiNode = struct {
    node_id: u64,
    voters: []u64,
    peers: []bridge_mod.PeerAddr,
    /// Backing storage for the peer host slices (`host:port` left of `:`).
    peer_bufs: [][]u8,
    listen_addr: std.net.Address,
    listen_str: []u8,

    fn deinit(self: *const CpMultiNode, a: std.mem.Allocator) void {
        a.free(self.voters);
        a.free(self.peers);
        for (self.peer_bufs) |b| a.free(b);
        a.free(self.peer_bufs);
        a.free(self.listen_str);
    }
};

/// Build multi-node CP config from env, or null if `REWIND_CP_NODE_ID` is
/// unset (single-node CP). Required together — the CP's directory raft group
/// spans these nodes:
///   - `REWIND_CP_NODE_ID`  this CP node's 1-based raft id (∈ the voter set).
///   - `REWIND_CP_VOTERS`   comma-separated voter ids, e.g. `1,2,3`.
///   - `REWIND_CP_PEERS`    comma-separated raft transport `host:port`s,
///                          indexed by raft id − 1. Distinct from the HTTP
///                          listen port (argv[1]).
/// Errors loud on malformed / inconsistent config.
fn parseCpMultiNode(a: std.mem.Allocator) !?CpMultiNode {
    const node_id_s = std.posix.getenv("REWIND_CP_NODE_ID") orelse return null;
    const voters_s = std.posix.getenv("REWIND_CP_VOTERS") orelse return error.MissingCpVoters;
    const peers_s = std.posix.getenv("REWIND_CP_PEERS") orelse return error.MissingCpPeers;

    const node_id = try std.fmt.parseInt(u64, std.mem.trim(u8, node_id_s, " \t"), 10);

    var voters: std.ArrayListUnmanaged(u64) = .empty;
    errdefer voters.deinit(a);
    var vit = std.mem.tokenizeScalar(u8, voters_s, ',');
    while (vit.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        try voters.append(a, try std.fmt.parseInt(u64, t, 10));
    }
    if (voters.items.len == 0) return error.MissingCpVoters;

    var peers: std.ArrayListUnmanaged(bridge_mod.PeerAddr) = .empty;
    errdefer peers.deinit(a);
    var peer_bufs: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (peer_bufs.items) |b| a.free(b);
        peer_bufs.deinit(a);
    }
    var pit = std.mem.tokenizeScalar(u8, peers_s, ',');
    while (pit.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        const colon = std.mem.lastIndexOfScalar(u8, t, ':') orelse return error.BadCpPeer;
        const host = try a.dupe(u8, t[0..colon]);
        errdefer a.free(host);
        const port = try std.fmt.parseInt(u16, t[colon + 1 ..], 10);
        try peer_bufs.append(a, host);
        try peers.append(a, .{ .host = host, .port = port });
    }
    if (node_id == 0 or node_id > peers.items.len) return error.BadCpNodeId;

    const listen = peers.items[node_id - 1];
    const listen_addr = try std.net.Address.parseIp(listen.host, listen.port);
    const listen_str = try std.fmt.allocPrint(a, "{s}:{d}", .{ listen.host, listen.port });

    return CpMultiNode{
        .node_id = node_id,
        .voters = try voters.toOwnedSlice(a),
        .peers = try peers.toOwnedSlice(a),
        .peer_bufs = try peer_bufs.toOwnedSlice(a),
        .listen_addr = listen_addr,
        .listen_str = listen_str,
    };
}

// ── Host → tenant index (the CP domain index) ─────────────────────────
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
    /// HTTP origins of the CP nodes (HA), for forwarding a directory WRITE
    /// (`/_control/*`) when this node is not the directory group leader.
    /// Empty for a single-node CP (this node always leads). `REWIND_CP_PEER_URLS`,
    /// indexed by CP node id − 1 (same convention as `REWIND_CP_PEERS`).
    /// Borrowed; owned by `main`.
    cp_peer_urls: []const []const u8 = &.{},
    /// This node's own index into `cp_peer_urls` (= CP node id − 1), so the
    /// leader probe NEVER calls its own `/_cp/leader`: that is a synchronous
    /// self-call from the poll loop (which is busy making the call), so it
    /// can't be served and hangs until the request timeout. Null for a
    /// single-node CP (no forwarding).
    self_cp_idx: ?usize = null,

    /// Reply helper: set an immediate status (no body) on the request
    /// entity and move it to response_in.
    fn replyStatus(server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16) !void {
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
    fn replyText(server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16, msg: []u8) !void {
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = msg.ptr, .len = @intCast(msg.len) });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        try server.reg.move(ent, &server.request_out, &server.response_in);
    }

    /// The CP serves ONLY its control surface — `/_control/*` (move
    /// orchestration) and `/_cp/*` (route lookup + leader probe). Customer
    /// traffic never reaches here (it goes to `rewind-front` → DP); any other
    /// path 404s.
    fn processRequests(self: *Router, server: *CpH2) !void {
        const entities = server.request_out.entitySlice();
        const sids = server.request_out.column(h2.StreamId);
        const sessions = server.request_out.column(h2.Session);
        const req_hdrs = server.request_out.column(h2.ReqHeaders);
        const req_bodies = server.request_out.column(h2.ReqBody);

        for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
            const req_path = headerValue(rh, ":path") orelse "/";

            // `/_control/move` is handled by the CP itself (the move
            // orchestrator), not proxied: it owns the directory, so the
            // move's directory flip is its atomic commit point.
            if (std.mem.startsWith(u8, req_path, "/_control/")) {
                try self.handleControl(server, ent, sid, sess, rh, rb, req_path);
                continue;
            }

            // `/_cp/route?host=H` — the authoritative owner lookup the
            // front door (routing) and DP clusters (serve-or-forward)
            // consult; `/_cp/leader` — directory-group leader probe.
            if (std.mem.startsWith(u8, req_path, "/_cp/")) {
                try self.handleCp(server, ent, sid, sess, req_path);
                continue;
            }

            try replyStatus(server, ent, sid, sess, 404);
        }
    }

    // ── Control plane: owner lookup (routing + serve-or-forward) ──────

    /// `GET /_cp/route?host=H` — return the cluster that currently owns the
    /// tenant for `H`, as JSON `{cluster, tenant, moving, nodes:[…]}`, or 404
    /// if the host maps to no tenant / the tenant is unplaced. The front door
    /// caches this for routing; a DP cluster that can't serve a request
    /// locally consults it and forwards to the owner (serve-or-forward) — so a
    /// stale route costs an extra hop, never a failure. No auth: it leaks only
    /// placement (host→cluster), which the public proxy config already
    /// encodes.
    fn handleCp(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        // `/_cp/leader` — 200 iff THIS CP node leads the directory raft group
        // (so directory WRITES can commit here), else 503. A follower CP node
        // uses this to discover the leader to forward a `/_control/*` write to;
        // a single-node CP always answers 200.
        if (std.mem.startsWith(u8, path, "/_cp/leader")) {
            try replyStatus(server, ent, sid, sess, if (self.directory.isLeader()) 200 else 503);
            return;
        }
        if (!std.mem.startsWith(u8, path, "/_cp/route")) {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        }
        const host = queryParam(path, "host") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const tenant = self.hosts.tenantFor(host) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        const resolution = self.directory.resolve(tenant) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };

        const a = self.allocator;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        const w = buf.writer(a);
        try w.print("{{\"cluster\":\"{s}\",\"tenant\":\"{s}\",\"moving\":{},\"nodes\":[", .{ resolution.cluster.id, tenant, resolution.moving });
        for (resolution.cluster.nodes, 0..) |n, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{n});
        }
        try w.writeAll("]}");
        const owned = try buf.toOwnedSlice(a);
        try replyText(server, ent, sid, sess, 200, owned);
    }

    // ── Control plane: tenant-move orchestration ─────────────────────

    /// Route + auth a `/_control/*` request. `POST /_control/move` (brief
    /// pause) and `POST /_control/move-live` (zero-downtime) exist; both
    /// require the move secret (`X-Rewind-Move-Secret`).
    fn handleControl(
        self: *Router,
        server: *CpH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        rh: h2.ReqHeaders,
        rb: h2.ReqBody,
        path: []const u8,
    ) !void {
        const method_s = headerValue(rh, ":method") orelse "GET";
        const is_move = std.mem.eql(u8, path, "/_control/move");
        const is_move_live = std.mem.eql(u8, path, "/_control/move-live");
        if (!(is_move or is_move_live) or !std.mem.eql(u8, method_s, "POST")) {
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

        // Multi-node CP (HA): the move flips the directory, which only commits
        // on the directory-group LEADER. If this CP node is a follower, forward
        // the whole control request to the CP leader and relay its response —
        // so an operator can target any CP node. (Single-node CP always leads;
        // `cp_peer_urls` is empty → handle locally.)
        if (self.cp_peer_urls.len > 0 and !self.directory.isLeader()) {
            try self.forwardControlToLeader(server, ent, sid, sess, rh, rb, path);
            return;
        }

        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else &.{};
        if (is_move_live)
            try self.handleMoveLive(server, ent, sid, sess, body)
        else
            try self.handleMove(server, ent, sid, sess, body);
    }

    /// Forward a `/_control/*` request to the CP node that currently leads the
    /// directory group (discovered via `/_cp/leader`), relaying its response.
    /// Used when this CP node is a follower (directory writes can't commit
    /// here). 503 if no CP leader is reachable (the client retries).
    fn forwardControlToLeader(
        self: *Router,
        server: *CpH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        rh: h2.ReqHeaders,
        rb: h2.ReqBody,
        path: []const u8,
    ) !void {
        const a = self.allocator;
        const leader = self.findCpLeaderUrl() orelse {
            try replyStatus(server, ent, sid, sess, 503); // no CP leader right now
            return;
        };
        defer a.free(leader);
        const method = methodFrom(headerValue(rh, ":method") orelse "POST") orelse .POST;
        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else &.{};
        const resp = self.backendCall(leader, path, method, body, null) catch |err| {
            std.log.warn("rewind-cp: forward control to CP leader {s} failed: {s}", .{ leader, @errorName(err) });
            try replyStatus(server, ent, sid, sess, 502);
            return;
        };
        var r = resp;
        defer r.deinit(a);
        if (r.body.len == 0) {
            try replyStatus(server, ent, sid, sess, @intCast(r.status));
            return;
        }
        const owned = a.dupe(u8, r.body) catch {
            try replyStatus(server, ent, sid, sess, @intCast(r.status));
            return;
        };
        try replyText(server, ent, sid, sess, @intCast(r.status), owned);
    }

    /// Find the CP node currently leading the directory group: try each CP
    /// peer's `/_cp/leader` until one answers 200, returning its URL (owned).
    /// Null if none leads (mid-election / all unreachable).
    fn findCpLeaderUrl(self: *Router) ?[]u8 {
        const a = self.allocator;
        for (self.cp_peer_urls, 0..) |base, i| {
            // Never probe self — a blocking call to our own /_cp/leader from
            // inside the poll loop self-deadlocks (we are the loop, busy here).
            // We are forwarding precisely because we are NOT the leader.
            if (self.self_cp_idx) |self_i| {
                if (i == self_i) continue;
            }
            const resp = self.backendCall(base, "/_cp/leader", .GET, "", null) catch continue;
            const ok = resp.status == 200;
            var r = resp;
            r.deinit(a);
            if (ok) return a.dupe(u8, base) catch null;
        }
        return null;
    }

    /// Orchestrate a brief-pause tenant move (docs/v2-build-order.md
    /// §Phase 4): hold the tenant → dump+quiesce on source → ship the
    /// bundle to the destination → attach there → **flip the directory**
    /// (the commit point) → evict the source. On any pre-flip failure the
    /// directory reverts and the source is resumed, so a failed move is a
    /// no-op the tenant survives.
    fn handleMove(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
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

        // Per-step timing — the move is a chain of blocking back-end calls +
        // directory raft commits; this surfaces which step stalls when the
        // whole move runs long. Kept in tree (diagnostic state is not
        // temporary).
        var t_ms: i64 = std.time.milliTimestamp();
        const T = struct {
            fn lap(prev: *i64, comptime label: []const u8) void {
                const now = std.time.milliTimestamp();
                std.log.info("rewind-cp: move step {s}: {d}ms", .{ label, now - prev.* });
                prev.* = now;
            }
        };

        self.directory.beginMove(tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        T.lap(&t_ms, "beginMove");

        // 1. Quiesce + dump the source LEADER (v2-bundle is leader-gated —
        //    a follower 421s, so try each source node until one returns the
        //    bundle). Single-node source → one node, the leader.
        var dump = self.bundleFromLeader(src_nodes, tbody) orelse {
            self.resumeAll(tenant, src_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        };
        defer dump.deinit(a);
        T.lap(&t_ms, "bundle");

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
        T.lap(&t_ms, "attach");

        // 3. Await the freshly formed destination group's election so
        //    post-move traffic finds a leader immediately (v2-leader polls).
        if (!self.awaitDestLeader(dest_nodes, tenant)) {
            self.evictAll(tenant, dest_nodes, tbody);
            self.resumeAll(tenant, src_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        }
        T.lap(&t_ms, "awaitDestLeader");

        // 4. Flip the directory — the atomic commit point of the move.
        self.directory.move(tenant, dest) catch {
            // Both tenant + dest were validated above; a failure here is
            // an invariant violation. Leave moving-held + surface 500.
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        T.lap(&t_ms, "flip");

        // 5. Evict the source on EVERY source node (destroy each group
        //    incarnation + drop the instance). Best-effort: the move already
        //    committed; a stale source group is reclaimed lazily and never
        //    serves traffic again.
        self.evictAll(tenant, src_nodes, tbody);
        T.lap(&t_ms, "evict");

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
                std.log.warn("rewind-cp: v2-bundle on {s} failed: {s}", .{ base, @errorName(err) });
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
                std.log.warn("rewind-cp: v2-attach on {s} failed: {s}", .{ base, @errorName(err) });
                return false;
            };
            var r = resp;
            defer r.deinit(a);
            if (r.status != 204) {
                std.log.warn("rewind-cp: v2-attach on {s} → {d}", .{ base, r.status });
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
                std.log.warn("rewind-cp: evict {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
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
                std.log.warn("rewind-cp: resume source {s} ({s}) failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    // ── Stuck-move reconciliation (move crash recovery) ──────────────

    /// Reconcile moves the directory durably recorded as in-flight but that no
    /// orchestration is completing. The `moving` hold is durable, so a CP crash
    /// between `beginMove` and the terminal `move`/`abortMove` leaves a tenant
    /// stuck `moving` forever (front door 503s its traffic, source quiesced).
    /// The flip is the move's commit point, so a still-`moving` placement means
    /// the flip never happened and the SOURCE remains authoritative: abort the
    /// move (revert to active) + resume the source.
    ///
    /// Runs ONLY on the directory leader (abort is a directory write), from the
    /// serve loop between request batches. The CP is single-threaded and a move
    /// orchestration is fully synchronous within one `handleControl` (one
    /// serve-loop iteration), so this never overlaps a live move — any tenant
    /// `moving` when this runs is a genuine stuck move from a prior / crashed
    /// orchestration, safe to abort.
    fn reconcileStuckMoves(self: *Router) void {
        if (!self.directory.isLeader()) return;
        const a = self.allocator;
        const moving = self.directory.collectMoving(a) catch return;
        defer {
            for (moving) |t| a.free(t);
            a.free(moving);
        }
        for (moving) |tenant| {
            const res = self.directory.resolve(tenant) orelse continue;
            if (!res.moving) continue; // raced a completing move — skip
            const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch continue;
            defer a.free(tbody);
            std.log.warn("rewind-cp: reconciling stuck move for {s} (abort + resume source {s})", .{ tenant, res.cluster.id });
            // resumeAll: abortMove (revert to active) + best-effort resume each
            // source node (lift a brief-pause quiesce). The source node list is
            // pointer-stable past the resolve.
            self.resumeAll(tenant, res.cluster.nodes, tbody);
        }
    }

    // ── Zero-downtime move (Phase 7 slice c) ─────────────────────────

    /// Orchestrate a ZERO-DOWNTIME tenant move — the source keeps serving the
    /// whole time; no quiesce, no `moving` hold. Built on slice (b)'s
    /// SYNCHRONOUS forwarding (a source write is acked only after the dest
    /// applies it), so the dest always has every acked write and the snapshot
    /// loads insert-if-absent without clobbering a forwarded (newer) key:
    ///
    ///   1. empty-attach the dest (form group + instance, NO data) on all
    ///      destination nodes — ready to receive forwards.
    ///   2. await the dest group's leader (its URL is the forward target).
    ///   3. forward-begin on the source leader → it dual-writes every commit
    ///      to the dest leader (synchronous).
    ///   4. snapshot the source leader (non-quiescing — it keeps serving).
    ///   5. load-merge the snapshot into every dest node (insert-if-absent,
    ///      out-of-band from raft).
    ///   6. flip the directory — the atomic commit point.
    ///   7. evict the source — drops its instance + group + forward marker,
    ///      so it stops serving + forwarding; serve-or-forward routes any
    ///      straggler to the dest.
    ///
    /// A pre-flip failure forward-ends the source (stops dual-writing) +
    /// evicts the half-attached dest, leaving the tenant serving on the
    /// source untouched. Brief-pause `handleMove` stays for callers that want
    /// it. (First cut: single forward target = the dest leader URL; a
    /// dest-leader change mid-move is a noted refinement.)
    fn handleMoveLive(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct { tenant: []const u8, dest: []const u8 }, a, body, .{ .ignore_unknown_fields = true }) catch {
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
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        if (resolution.moving) {
            try replyStatus(server, ent, sid, sess, 409);
            return;
        }
        const src = resolution.cluster;
        if (std.mem.eql(u8, src.id, dest)) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        const dest_ref = self.directory.clusterById(dest) orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const src_nodes = src.nodes;
        const dest_nodes = dest_ref.nodes;
        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(tbody);

        // 1. Empty-attach the dest (no bundle → just the group + instance).
        if (!self.attachToAll(dest_nodes, "", tenant)) {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }
        // 2. Await the dest leader; its URL is the source's forward target.
        const dest_leader = self.findDestLeaderUrl(dest_nodes, tenant) orelse {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        };
        defer a.free(dest_leader);

        // 3. forward-begin on the source leader (dual-write to the dest leader).
        if (!self.forwardBeginOnLeader(src_nodes, tenant, dest_leader)) {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }

        // 4. Snapshot the source leader (non-quiescing; it keeps serving).
        var snap = self.snapshotFromLeader(src_nodes, tbody) orelse {
            self.forwardEndOnLeader(src_nodes, tenant);
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        };
        defer snap.deinit(a);

        // 5. Load-merge the snapshot into every dest node (insert-if-absent).
        if (!self.loadMergeToAll(dest_nodes, snap.body, tenant)) {
            self.forwardEndOnLeader(src_nodes, tenant);
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }

        // 6. Flip the directory — the atomic commit point.
        self.directory.move(tenant, dest) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };

        // 7. Evict the source (drops instance + group + forward marker → it
        //    stops serving + forwarding; serve-or-forward routes stragglers
        //    to the dest). Evict subsumes forward-end on the happy path.
        self.evictAll(tenant, src_nodes, tbody);

        const msg = std.fmt.allocPrint(a, "moved-live {s}: {s} -> {s}\n", .{ tenant, src.id, dest }) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Poll every destination node's `/_system/v2-leader?tenant=` until one
    /// reports 200, and return that node's base URL (owned) — the source's
    /// forward target. Null on timeout.
    fn findDestLeaderUrl(self: *Router, dest_nodes: []const []const u8, tenant: []const u8) ?[]u8 {
        const a = self.allocator;
        const suffix = std.fmt.allocPrint(a, "/_system/v2-leader?tenant={s}", .{tenant}) catch return null;
        defer a.free(suffix);
        const deadline: i128 = std.time.nanoTimestamp() + 15 * std.time.ns_per_s;
        while (std.time.nanoTimestamp() < deadline) {
            for (dest_nodes) |base| {
                const resp = self.backendCall(base, suffix, .GET, "", null) catch continue;
                var r = resp;
                r.deinit(a);
                if (r.status == 200) return a.dupe(u8, base) catch null;
            }
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return null;
    }

    /// forward-begin on the source leader: try each source node's leader-gated
    /// `/_system/v2-forward-begin {tenant,dest}` until one 204s (the leader).
    fn forwardBeginOnLeader(self: *Router, src_nodes: []const []const u8, tenant: []const u8, dest_url: []const u8) bool {
        const a = self.allocator;
        const fb = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"dest\":\"{s}\"}}", .{ tenant, dest_url }) catch return false;
        defer a.free(fb);
        for (src_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-forward-begin", .POST, fb, null) catch continue;
            const ok = resp.status == 204;
            var r = resp;
            r.deinit(a);
            if (ok) return true;
        }
        return false;
    }

    /// forward-end on the source leader (abort cleanup): best-effort.
    fn forwardEndOnLeader(self: *Router, src_nodes: []const []const u8, tenant: []const u8) void {
        const a = self.allocator;
        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch return;
        defer a.free(tbody);
        for (src_nodes) |base| {
            if (self.backendCall(base, "/_system/v2-forward-end", .POST, tbody, null)) |r| {
                const ok = r.status == 204;
                var rr = r;
                rr.deinit(a);
                if (ok) return;
            } else |_| {}
        }
    }

    /// Dump the source LEADER's NON-quiescing snapshot (try each source node's
    /// leader-gated `/_system/v2-snapshot` until one 200s). Owned body.
    fn snapshotFromLeader(self: *Router, src_nodes: []const []const u8, tbody: []const u8) ?BackendResp {
        const a = self.allocator;
        for (src_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-snapshot", .POST, tbody, null) catch continue;
            if (resp.status == 200) return resp;
            var r = resp;
            r.deinit(a);
        }
        return null;
    }

    /// Load-merge a snapshot (insert-if-absent) into every destination node.
    fn loadMergeToAll(self: *Router, dest_nodes: []const []const u8, bundle: []const u8, tenant: []const u8) bool {
        const a = self.allocator;
        for (dest_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-load-merge", .POST, bundle, tenant) catch |err| {
                std.log.warn("rewind-cp: v2-load-merge on {s} failed: {s}", .{ base, @errorName(err) });
                return false;
            };
            var r = resp;
            defer r.deinit(a);
            if (r.status != 204) return false;
        }
        return true;
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

/// Read a single query-string value (`/p?a=b&c=d`) by key. Values taken
/// verbatim (no percent-decoding — the CP route lookup uses bare hostnames).
fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.tokenizeScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn cleanupResponses(server: *CpH2) !void {
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
    const port_str = arg_it.next() orelse "9090";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // Control-plane directory — durable, backed by the CP `bridge` (one
    // "directory" raft group; docs/v2-cp-directory-replication.md Slice 1).
    // The store at `REWIND_CP_DATA_DIR` persists placement across restarts;
    // `initReplicated` replays it before the pump thread starts. Required: a
    // CP without durable storage loses every committed move on restart, which
    // is a misconfiguration — fail loud rather than default to an ephemeral
    // path that silently re-seeds static config.
    const cp_data_dir = std.posix.getenv("REWIND_CP_DATA_DIR") orelse {
        std.log.err("rewind-cp: REWIND_CP_DATA_DIR is required (the durable directory store path)", .{});
        return error.MissingCpDataDir;
    };
    // Single-node CP by default; a multi-node (HA) CP is configured by env
    // (this CP node's raft id, the voter set, the consensus transport
    // addresses). The directory raft group spans the voter set.
    var cp_self_idx: ?usize = null;
    const cp_bridge = if (try parseCpMultiNode(allocator)) |mn| blk: {
        defer mn.deinit(allocator);
        cp_self_idx = mn.node_id - 1; // index into REWIND_CP_PEER_URLS
        std.log.info("rewind-cp: multi-node CP id={d} voters={d} listen={s}", .{ mn.node_id, mn.voters.len, mn.listen_str });
        break :blk try Bridge.initMultiNode(allocator, cp_data_dir, mn.node_id, mn.voters, mn.listen_addr, mn.peers);
    } else try Bridge.initSingleNode(allocator, cp_data_dir);
    const directory = try Directory.initReplicated(allocator, cp_bridge);
    // Teardown order matters: the pump fires the directory's apply observer,
    // so the pump must STOP (`cp_bridge.deinit` → `stopPump`) before the
    // directory is freed. Defers run LIFO, so declare `directory.destroy`
    // first (runs last) and `cp_bridge.deinit` second (runs first).
    defer directory.destroy();
    defer cp_bridge.deinit();
    try cp_bridge.startPump();

    // Static config seeds ONLY a fresh (empty) directory — a restart over a
    // populated store keeps its committed placements (incl. completed moves)
    // rather than re-seeding back to the static config.
    //
    // Single-node CP: this node is always the leader, so seed immediately.
    // Multi-node CP: a directory write only commits on the LEADER, so only the
    // leader seeds (once); every follower boots empty and fills its projection
    // from the leader's replicated seed (the apply observer). Wait briefly for
    // election / replication to settle before deciding.
    if (cp_bridge.node.isSingleNode()) {
        if (directory.isEmpty()) {
            try directory.seedClusters(getEnvCfg("REWIND_CLUSTERS"));
            try directory.seedPlacements(getEnvCfg("REWIND_PLACEMENT"));
            std.log.info("rewind-cp: seeded directory from static config", .{});
        } else {
            std.log.info("rewind-cp: directory replayed from {s} (skipping static seed)", .{cp_data_dir});
        }
    } else {
        const deadline: i128 = std.time.nanoTimestamp() + 10 * std.time.ns_per_s;
        while (std.time.nanoTimestamp() < deadline and !directory.isLeader() and directory.isEmpty()) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (directory.isLeader() and directory.isEmpty()) {
            // Seed as the leader, RETRYING transient replication faults:
            // leadership can still be settling right after election, so a
            // propose may fault even though we just read isLeader()==true.
            // Seeds are idempotent (addCluster/assign upsert), so re-running
            // after a partial seed is safe. Stop if we lose leadership (a peer
            // will seed) or the store fills (replicated from elsewhere).
            var seeded = false;
            var attempt: u32 = 0;
            while (attempt < 100) : (attempt += 1) {
                if (!directory.isLeader() or !directory.isEmpty()) break;
                directory.seedClusters(getEnvCfg("REWIND_CLUSTERS")) catch |e| switch (e) {
                    error.Replication => {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return e, // malformed config / OOM → fail loud
                };
                directory.seedPlacements(getEnvCfg("REWIND_PLACEMENT")) catch |e| switch (e) {
                    error.Replication => {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return e,
                };
                seeded = true;
                break;
            }
            if (seeded) {
                std.log.info("rewind-cp: directory leader seeded from static config", .{});
            } else if (directory.isEmpty()) {
                std.log.warn("rewind-cp: leader could not seed (replication unstable); will rely on replication / a peer", .{});
            } else {
                std.log.info("rewind-cp: directory replayed/replicated (skipping static seed)", .{});
            }
        } else if (directory.isEmpty()) {
            std.log.info("rewind-cp: CP follower — awaiting directory replication from the leader", .{});
        } else {
            std.log.info("rewind-cp: directory replayed/replicated (skipping static seed)", .{});
        }
    }

    // CP peer HTTP origins (HA) — the OTHER CP nodes' control URLs, so a
    // follower can forward a `/_control/*` write to the directory leader.
    // `REWIND_CP_PEER_URLS=http://a:9090;http://b:9090;http://c:9090`. Empty
    // for a single-node CP (this node always leads → no forward).
    const cp_peer_urls = try parseUrlList(allocator, getEnvCfg("REWIND_CP_PEER_URLS"));
    defer freeUrlList(allocator, cp_peer_urls);

    var hosts = HostMap.init(allocator);
    defer hosts.deinit();
    try hosts.seed(getEnvCfg("REWIND_HOSTS"));

    // V2 Phase 4 — shared secret for the cluster-internal move surface. The CP
    // presents it to backends' `/_system/v2-*` endpoints and requires it on
    // `/_control/move`. Unset → move control disabled.
    const move_secret: ?[]const u8 = std.posix.getenv("REWIND_MOVE_SECRET");

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 8192,
        .deferred_queue_capacity = 2048,
    });
    defer reg.deinit();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    const server = try CpH2.create(&reg, allocator, addr, .{
        .max_connections = 1024,
        .buf_count = 1024,
        .buf_size = 16384,
        .listen_backlog = 1024,
        .reuseport = true,
    }, .{ .tls_config = null });
    defer server.destroy();

    var router = Router{ .allocator = allocator, .directory = directory, .hosts = &hosts, .move_secret = move_secret, .cp_peer_urls = cp_peer_urls, .self_cp_idx = cp_self_idx };

    // Periodic stuck-move reconciliation on the directory leader (between
    // request batches; never overlaps a synchronous move — see
    // `reconcileStuckMoves`). last=0 → the first iteration reconciles, so a CP
    // restart / failover cleans up a crashed move within one tick. Period from
    // `REWIND_CP_RECONCILE_SECS` (default 5); 0 disables reconciliation.
    const reconcile_secs: i128 = blk: {
        const s = std.posix.getenv("REWIND_CP_RECONCILE_SECS") orelse break :blk 5;
        break :blk std.fmt.parseInt(i128, std.mem.trim(u8, s, " \t"), 10) catch 5;
    };
    const reconcile_period_ns: i128 = reconcile_secs * std.time.ns_per_s;
    var last_reconcile_ns: i128 = 0;

    std.log.info("rewind-cp: listening on 0.0.0.0:{d} (move control {s}, reconcile {s})", .{
        port,
        if (move_secret != null) "enabled" else "disabled",
        if (reconcile_secs > 0) "on" else "off",
    });
    while (!stop_flag.load(.acquire)) {
        server.pollWithTimeout(10 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        try router.processRequests(server);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();

        if (reconcile_secs > 0) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_reconcile_ns > reconcile_period_ns) {
                last_reconcile_ns = now_ns;
                router.reconcileStuckMoves();
            }
        }
    }
    std.log.info("rewind-cp: shut down", .{});
}
