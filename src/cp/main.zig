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
const acme_issuer = @import("acme.zig");

const CpH2 = h2.H2(.{});

/// Constant-time byte-slice equality for secret comparison: the
/// compare time depends only on the (non-secret) length, never on how
/// many leading bytes matched — so a timing signal can't be used to
/// brute-force the secret one byte at a time. Mirrors the root-token
/// check in `rove-tenant`'s `authenticate`.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

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

// The domain index (host → tenant) is no longer a static in-memory map: it
// moved into the replicated `__directory__` group (`directory.zig` `hosts`
// projection + `host/{host}` keys, gap #2), so it survives a CP restart, spans
// the HA nodes, and accepts runtime custom-domain provisioning via the
// `/_control/host` control write. The static `REWIND_HOSTS` env is now seeded
// INTO the directory (see `main`).

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
/// Carries a tenant's opaque plan blob on `v2-attach` (delivery rides the move
/// handshake) and `v2-plan` (live push). See docs/v2-cp-operational-state.md.
const PLAN_HEADER = "X-Rewind-Plan";

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
    /// The leader-elected ACME issuer (gap #3 slice 3), or null when
    /// `REWIND_ACME_DIRECTORY` is unset. Serves `/_cp/acme-challenge?token=`
    /// from its in-memory challenge store.
    acme: ?*acme_issuer.Handle = null,
    /// Opt-in: run the additive membership reconciler each reconcile tick
    /// (`REWIND_CP_RECONCILE_MEMBERSHIP=1`). OFF by default — a continuous
    /// unattended actor on prod must be deliberately enabled.
    reconcile_membership: bool = false,

    /// RC-6 demote hysteresis. A reconciler demote-to-learner of a voter judged
    /// `!recent_active` must require SUSTAINED inactivity, never a single reading:
    /// a rolling deploy makes a HEALTHY voter transiently unreachable for the
    /// length of its restart, and a one-shot demote would tear that voter out of
    /// the config — shrinking the voter set and enabling sub-majority commit
    /// (RC-1's trigger by another route). A demote candidate's FIRST
    /// `!recent_active` observation starts a timer (keyed `tenant|node_id`); the
    /// demote fires only after it has stayed inactive for `demote_grace_ns`. Any
    /// other observed state (responsive again, or no longer a hosted voter) clears
    /// the timer, so a long-ago transient never carries into a later window.
    /// Tunable via `REWIND_CP_DEMOTE_GRACE_MS` (default 60s — comfortably longer
    /// than a worker restart + group recover).
    demote_grace_ns: i128 = 60 * std.time.ns_per_s,
    demote_inactive_since: std.StringHashMapUnmanaged(i128) = .empty,

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
    /// tenant for `H`, as JSON `{cluster, tenant, nodes:[…]}`, or 404
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
        if (std.mem.startsWith(u8, path, "/_cp/plan")) {
            try self.handleCpPlan(server, ent, sid, sess, path);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/acme-challenge")) {
            try self.handleCpAcmeChallenge(server, ent, sid, sess, path);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/certs")) {
            try self.handleCpCerts(server, ent, sid, sess);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/cert")) {
            try self.handleCpCert(server, ent, sid, sess, path);
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
        const a = self.allocator;
        // Domain index (gap #2): host → tenant from the replicated directory.
        // Owned copy (a host's tenant can be replaced by a concurrent apply,
        // and `resolve` re-takes the directory mutex), freed after we resolve.
        const tenant = (self.directory.hostTenantForOwned(a, host) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        defer a.free(tenant);
        const resolution = self.directory.resolve(tenant) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        const w = buf.writer(a);
        try w.print("{{\"cluster\":\"{s}\",\"tenant\":\"{s}\",\"nodes\":[", .{ resolution.cluster.id, tenant });
        for (resolution.cluster.nodes, 0..) |n, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{n});
        }
        try w.writeAll("]}");
        const owned = try buf.toOwnedSlice(a);
        try replyText(server, ent, sid, sess, 200, owned);
    }

    /// `GET /_cp/plan?tenant=T` — the tenant's opaque plan/limits blob (200 +
    /// the raw value), or 404 if unset (the DP treats absent as the free tier).
    /// The DP reads this to resolve effective limits; placement-independent, so
    /// it's keyed on the tenant, not the host. No auth (same trust as
    /// `/_cp/route` — an internal CP read over the private network).
    fn handleCpPlan(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        const tenant = queryParam(path, "tenant") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const a = self.allocator;
        const plan = (self.directory.planForOwned(a, tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404); // unset → free tier
            return;
        };
        // `plan` is owned; replyText hands it to the registry (RespBody.deinit).
        try replyText(server, ent, sid, sess, 200, plan);
    }

    /// `GET /_cp/cert?host=H` — the host's packed TLS cert+key frame
    /// (`[1B version][4B cert_len][cert][key]`, application/octet-stream;
    /// served verbatim — the front door unpacks), or 404 if no
    /// cert is stored (the front door then SNI-falls-back to the platform
    /// wildcard / refuses). The stateless front-door pool pulls this for SNI
    /// termination (gap #3). No auth: it serves only over the private CP
    /// network, same trust as `/_cp/route`. (The PRIVATE key crosses this hop —
    /// it must stay on the private network; production fronts the CP with the
    /// same network boundary as `/_cp/route`.)
    fn handleCpCert(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        const host = queryParam(path, "host") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const a = self.allocator;
        const packed_bytes = (self.directory.certForOwned(a, host) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404); // no cert for this host
            return;
        };
        // `replyText` serves arbitrary owned bytes (data/len) — the packed
        // frame is binary, but the front door reads it by length, not type.
        try replyText(server, ent, sid, sess, 200, packed_bytes);
    }

    /// `GET /_cp/acme-challenge?token=T` — the HTTP-01 key-authorization for an
    /// in-flight challenge token, served from the issuer's in-memory store. The
    /// front door's `:80` listener (gap #6 phase 5) forwards
    /// `/.well-known/acme-challenge/<token>` here so the ACME CA's validation
    /// reaches the leader that published the token. 404 when no issuer is
    /// running or the token isn't published (the correct "no challenge" answer).
    fn handleCpAcmeChallenge(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        const token = queryParam(path, "token") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const issuer = self.acme orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        const keyauth = issuer.challengeFor(self.allocator, token) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        try replyText(server, ent, sid, sess, 200, keyauth);
    }

    /// `GET /_cp/certs` — newline-separated list of hosts that have a stored
    /// cert. The front door polls this, then pulls each host's frame via
    /// `/_cp/cert?host=` into its SNI store (the SNI handshake callback can't
    /// block on a fetch, so certs are synced proactively, not lazily).
    fn handleCpCerts(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session) !void {
        const a = self.allocator;
        const hosts = self.directory.certHostsOwned(a) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer {
            for (hosts) |h| a.free(h);
            a.free(hosts);
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        for (hosts) |h| {
            buf.appendSlice(a, h) catch {
                try replyStatus(server, ent, sid, sess, 500);
                return;
            };
            buf.append(a, '\n') catch {};
        }
        const owned = buf.toOwnedSlice(a) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
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
        const is_provision = std.mem.eql(u8, path, "/_control/provision");
        const is_plan = std.mem.eql(u8, path, "/_control/plan");
        const is_host = std.mem.eql(u8, path, "/_control/host");
        const is_cert = std.mem.eql(u8, path, "/_control/cert");
        const is_cluster = std.mem.eql(u8, path, "/_control/cluster");
        const is_node_addr = std.mem.eql(u8, path, "/_control/node-address");
        if (!(is_move or is_move_live or is_provision or is_plan or is_host or is_cert or is_cluster or is_node_addr) or !std.mem.eql(u8, method_s, "POST")) {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        }
        const secret = self.move_secret orelse {
            try replyStatus(server, ent, sid, sess, 503); // move surface disabled
            return;
        };
        const presented = headerValue(rh, MOVE_SECRET_HEADER) orelse "";
        if (!constantTimeEql(presented, secret)) {
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
        if (is_plan)
            try self.handlePlan(server, ent, sid, sess, body)
        else if (is_host)
            try self.handleHost(server, ent, sid, sess, body)
        else if (is_cert)
            try self.handleCert(server, ent, sid, sess, body)
        else if (is_cluster)
            try self.handleCluster(server, ent, sid, sess, body)
        else if (is_node_addr)
            try self.handleNodeAddress(server, ent, sid, sess, body)
        else if (is_provision)
            try self.handleProvision(server, ent, sid, sess, body)
        else
            // Convergence (raft-native-alignment): the brief-pause move was
            // dropped — `move` and `move-live` are the SAME (zero-downtime) move.
            // Both route names accepted so existing callers don't break.
            try self.handleMoveLive(server, ent, sid, sess, body);
    }

    /// `POST /_control/cluster {id, nodes:[url,…]}` — define/update a cluster's
    /// node set (the runtime "grow" primitive: add a node to a cluster so the
    /// membership reconciler backfills the placed tenants onto it). A directory
    /// WRITE: leader-gated (a follower already forwarded above), replicated via
    /// `addCluster`. Idempotent — re-defining with the same nodes is a no-op
    /// apply. NOTE: node identity is currently positional (`nodes[i]` ↔ raft id
    /// i+1), matching `REWIND_VOTERS`; the explicit-id model is the SSOT cleanup.
    fn handleCluster(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            id: []const u8,
            nodes: []const []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.id.len == 0 or parsed.value.nodes.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.addCluster(parsed.value.id, parsed.value.nodes) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        std.log.info("rewind-cp: cluster {s} set to {d} node(s)", .{ parsed.value.id, parsed.value.nodes.len });
        try replyStatus(server, ent, sid, sess, 204);
    }

    /// `POST /_control/node-address {cluster, id, raft_addr, cp_raft_addr?,
    /// http_url?}` — register a node's transport addresses in the directory
    /// node-address registry (cluster-genesis-and-membership §3.2). The explicit
    /// raft id → address binding that replaces the static positional
    /// `REWIND_PEERS`; the peer resolver reads it so a node configured with only
    /// its own identity can dial its peers. A directory WRITE: leader-gated (a
    /// follower already forwarded above), replicated via `setNodeAddr`.
    /// Idempotent on (cluster, id) — a repeat re-registers (re-IP).
    fn handleNodeAddress(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            cluster: []const u8,
            id: u64,
            raft_addr: []const u8,
            cp_raft_addr: []const u8 = "",
            http_url: []const u8 = "",
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const v = parsed.value;
        self.directory.setNodeAddr(v.cluster, v.id, v.raft_addr, v.cp_raft_addr, v.http_url) catch |err| {
            // BadConfig (empty cluster/raft_addr, id 0, bad chars) → 400;
            // replication/other → 500.
            const code: u16 = if (err == error.BadConfig) 400 else 500;
            try replyStatus(server, ent, sid, sess, code);
            return;
        };
        std.log.info("rewind-cp: node-address {s}/{d} → {s}", .{ v.cluster, v.id, v.raft_addr });
        try replyStatus(server, ent, sid, sess, 204);
    }

    /// `POST /_control/provision {tenant, cluster, host?}` — stand up a
    /// brand-new tenant (gaps #4 + #5): form its raft group on EVERY node of
    /// `cluster` via an empty-attach (no bundle — the multi-node formation path
    /// that needs no move), await the group's election, then write the
    /// placement (the commit point that makes it routable), and optionally map
    /// `host`→tenant. Create-only: 409 if the tenant is already placed (use
    /// `/_control/move` to relocate); 400 for an unknown cluster. On a
    /// formation failure the freshly-formed groups are evicted, so a failed
    /// provision is a no-op.
    fn handleProvision(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
            cluster: []const u8,
            host: ?[]const u8 = null,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        const cluster = parsed.value.cluster;
        if (tenant.len == 0 or cluster.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }

        // Create-only — provisioning an already-placed tenant is a 409 (its
        // group already exists; relocate via `/_control/move`).
        if (self.directory.resolve(tenant) != null) {
            try replyStatus(server, ent, sid, sess, 409);
            return;
        }
        const cluster_ref = self.directory.clusterById(cluster) orelse {
            try replyStatus(server, ent, sid, sess, 400); // unknown cluster
            return;
        };
        const nodes = cluster_ref.nodes; // pointer-stable across the calls below

        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(tbody);

        // 1. Form the group. TWO births, by whether a membership reconciler is
        //    present to GROW a single-voter group:
        //
        //    - Genesis §2d (born-{self}+grow, when `reconcile_membership`): birth
        //      the group as the SOLE voter `{1}` on the FIRST node ONLY. A
        //      born-`{self}` group auto-leads immediately (no election race —
        //      sidesteps the cold-multi-election bug that took prod down,
        //      `project_prod_genesis_gap`), and the RC-6 reconciler grows it to
        //      the full node set learner-first over the next passes. This is the
        //      path the genesis smoke validates.
        //    - Legacy (no reconciler): birth the full node set on EVERY node
        //      (`1,2,…,nodes.len`) — the cold-multi formation kept for
        //      static-config clusters that have no reconciler to finish a grow.
        //
        //    Either way a new tenant has no plan yet → free tier until
        //    `/_control/plan`. Raft ids are positional (node i ↔ id i+1).
        const grow = self.reconcile_membership;
        const birth_nodes: []const []const u8 = if (grow) nodes[0..1] else nodes;
        const birth_voters = (if (grow) a.dupe(u8, "1") else clusterVotersCsv(a, nodes.len)) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(birth_voters);
        if (!self.attachToAll(birth_nodes, "", tenant, null, birth_voters)) {
            self.evictAll(tenant, birth_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }
        // 2. Await the formed group's leader so the first request finds one. A
        //    born-`{self}` group auto-leads, so this returns at once; a born-multi
        //    group waits out its election.
        if (!self.awaitDestLeader(birth_nodes, tenant)) {
            self.evictAll(tenant, birth_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        }
        // 3. Write the placement — the commit point that makes it routable.
        self.directory.assign(tenant, cluster) catch {
            self.evictAll(tenant, nodes, tbody);
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // 4. Optional host→tenant mapping so the tenant is reachable now. It is
        //    already provisioned (placed) — a host write failure is non-fatal;
        //    retry via `/_control/host`.
        if (parsed.value.host) |host| {
            if (host.len > 0) self.directory.setHost(host, tenant) catch |err|
                std.log.warn("rewind-cp: provision {s}: setHost({s}) failed: {s}", .{ tenant, host, @errorName(err) });
        }
        std.log.info("rewind-cp: provisioned {s} on {s} ({d} node(s))", .{ tenant, cluster, nodes.len });
        try replyStatus(server, ent, sid, sess, 204);
    }

    /// Set a tenant's plan/limits blob: `POST /_control/plan {tenant, plan}`.
    /// `plan` is an opaque string the CP stores verbatim at `plan/{tenant}`
    /// (the DP parses it into effective limits — `docs/architecture/control-plane.md`). A directory
    /// WRITE: leader-gated, so a follower has already forwarded to the leader
    /// by the time we get here.
    fn handlePlan(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
            plan: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        if (tenant.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.setPlan(tenant, parsed.value.plan) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // Live single-target push: the CP knows the tenant's current placement,
        // so it delivers the new plan to the ONE serving cluster's nodes (which
        // bump their slot's plan generation). Best-effort — the CP is now the
        // durable source of truth; a failed push just means the change rides
        // the tenant's next move/attach. Unplaced tenant → nothing to push.
        self.pushPlanToServingCluster(tenant, parsed.value.plan);
        const msg = std.fmt.allocPrint(a, "plan set for {s}\n", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Map a host to a tenant: `POST /_control/host {host, tenant}` (gap #2,
    /// the replicated domain index). A directory WRITE: leader-gated, so a
    /// follower has already forwarded to the leader by the time we get here.
    /// Routing is a pure CP read (`/_cp/route`), so unlike a plan change there
    /// is nothing to push to a DP — the front door picks up the new mapping on
    /// its next CP route query (subject to its route-cache TTL).
    fn handleHost(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            host: []const u8,
            tenant: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.host.len == 0 or parsed.value.tenant.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.setHost(parsed.value.host, parsed.value.tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // Propagate the worker-side `__root__/domain/{host}` alias to the
        // tenant's serving cluster (step3-auth-plan.md B3). The CP owns
        // host→tenant, so it pushes the alias the workers need for local
        // custom-host resolution (`resolveDomain`) — no operator-held worker
        // secret (`ADMIN_OPS_SECRET` retired). If it didn't land (tenant
        // unplaced, or no reachable leader), the directory mapping still
        // stands; report 503 so the operator re-runs once the tenant is placed.
        if (!self.pushDomainToServingCluster(parsed.value.tenant, parsed.value.host)) {
            try replyStatus(server, ent, sid, sess, 503);
            return;
        }
        const msg = std.fmt.allocPrint(a, "host {s} -> {s}\n", .{ parsed.value.host, parsed.value.tenant }) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Store a host's TLS cert: `POST /_control/cert {host, cert, key}` (PEM
    /// strings) — the operator-brings-their-own-cert path (and, until DNS-01
    /// lands, how the platform wildcard is supplied). The leader-elected ACME
    /// issuer writes the same axis directly via `directory.setCert` (no HTTP
    /// hop). A directory WRITE: leader-gated, so a follower has already
    /// forwarded to the leader by the time we get here.
    fn handleCert(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            host: []const u8,
            cert: []const u8,
            key: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.host.len == 0 or parsed.value.cert.len == 0 or parsed.value.key.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.setCert(parsed.value.host, parsed.value.cert, parsed.value.key) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        const msg = std.fmt.allocPrint(a, "cert stored for {s}\n", .{parsed.value.host}) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Deliver a tenant's plan blob to its CURRENT serving cluster — a live
    /// `POST /_system/v2-plan {tenant, plan}` to every node of the cluster the
    /// directory resolves the tenant to (the plan cache is per-node slot state,
    /// so fan out like attach). Best-effort: logs per-node failures, never
    /// blocks the control reply on delivery. No-op if the tenant is unplaced
    /// (the plan rides its first attach instead).
    fn pushPlanToServingCluster(self: *Router, tenant: []const u8, plan: []const u8) void {
        const a = self.allocator;
        const res = self.directory.resolve(tenant) orelse return; // unplaced
        const payload = std.json.Stringify.valueAlloc(a, .{ .tenant = tenant, .plan = plan }, .{}) catch return;
        defer a.free(payload);
        for (res.cluster.nodes) |base| {
            if (self.backendCall(base, "/_system/v2-plan", .POST, payload, &.{})) |resp| {
                var r = resp;
                defer r.deinit(a);
                if (r.status != 204)
                    std.log.warn("rewind-cp: v2-plan push for {s} on {s} → {d}", .{ tenant, base, r.status });
            } else |err| {
                std.log.warn("rewind-cp: v2-plan push for {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    /// Push a `host → tenant` worker alias to the tenant's serving cluster: a
    /// `POST /_system/v2-domain {host, tenant}` to the cluster's nodes. The
    /// alias is a leader-gated `__root__` write, so only the group leader
    /// accepts (204) and the rest answer 421 — fan out, succeed on the first
    /// 204. Returns false if the tenant is unplaced or no node took it (the
    /// caller surfaces that). Mirror of `pushPlanToServingCluster`, but GATED
    /// (a half-mapped host must not report success — step3-auth-plan.md B3).
    fn pushDomainToServingCluster(self: *Router, tenant: []const u8, host: []const u8) bool {
        const a = self.allocator;
        const res = self.directory.resolve(tenant) orelse return false; // unplaced
        const payload = std.json.Stringify.valueAlloc(a, .{ .host = host, .tenant = tenant }, .{}) catch return false;
        defer a.free(payload);
        for (res.cluster.nodes) |base| {
            if (self.backendCall(base, "/_system/v2-domain", .POST, payload, &.{})) |resp| {
                var r = resp;
                defer r.deinit(a);
                if (r.status == 204) return true; // the leader took it
                if (r.status != 421)
                    std.log.warn("rewind-cp: v2-domain push for {s}={s} on {s} → {d}", .{ host, tenant, base, r.status });
            } else |err| {
                std.log.warn("rewind-cp: v2-domain push for {s}={s} on {s} failed: {s}", .{ host, tenant, base, @errorName(err) });
            }
        }
        return false;
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
        const resp = self.backendCall(leader, path, method, body, &.{}) catch |err| {
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
            const resp = self.backendCall(base, "/_cp/leader", .GET, "", &.{}) catch continue;
            const ok = resp.status == 200;
            var r = resp;
            r.deinit(a);
            if (ok) return a.dupe(u8, base) catch null;
        }
        return null;
    }

    /// Fan a `/_system/v2-attach` (bundle + `X-Rewind-Tenant`, plus the
    /// tenant's `X-Rewind-Plan` blob when set) out to every destination node.
    /// The plan rides attach so the destination enforces the right limits from
    /// the first post-move request (docs/v2-cp-operational-state.md). True only
    /// if all returned 204 (idempotent re-attach included). On the first
    /// failure returns false; the caller evicts the partially-attached set.
    /// The cluster's voter set as a comma-separated raft-id list `1,2,…,n` (raft
    /// ids are positional — node index i → id i+1, the `REWIND_PEERS` convention).
    /// Caller frees. The Phase 2e cluster node-set SSOT for a fresh tenant group.
    fn clusterVotersCsv(a: std.mem.Allocator, n: usize) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(a);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            if (i != 1) try buf.append(a, ',');
            try buf.writer(a).print("{d}", .{i});
        }
        return buf.toOwnedSlice(a);
    }

    fn attachToAll(self: *Router, dest_nodes: []const []const u8, bundle: []const u8, tenant: []const u8, plan: ?[]const u8, birth_voters: ?[]const u8) bool {
        const a = self.allocator;
        var hdrs: [3]curl.Header = undefined;
        hdrs[0] = .{ .name = TENANT_HEADER, .value = tenant };
        var nh: usize = 1;
        if (plan) |p| {
            hdrs[nh] = .{ .name = PLAN_HEADER, .value = p };
            nh += 1;
        }
        // Phase 2e (cluster node-set SSOT): the cluster's node set as the born
        // group's voter set, the CP-owned single source of truth — the SAME set
        // for every node, so the group forms consistently without depending on
        // each node's static `REWIND_VOTERS`. Null → the node falls back to its env.
        if (birth_voters) |v| {
            hdrs[nh] = .{ .name = "X-Rewind-Voters", .value = v };
            nh += 1;
        }
        for (dest_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-attach", .POST, bundle, hdrs[0..nh]) catch |err| {
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
                const resp = self.backendCall(base, suffix, .GET, "", &.{}) catch continue;
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
            if (self.backendCall(base, "/_system/v2-evict", .POST, tbody, &.{})) |ev| {
                var e2 = ev;
                e2.deinit(a);
            } else |err| {
                std.log.warn("rewind-cp: evict {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    /// Additive membership reconciler (Phase 4, opt-in `reconcile_membership`).
    /// On the directory leader, converge each placed tenant's DP group
    /// membership to its cluster's node set: for the first not-caught-up node
    /// per group per pass, take a LEARNER-FIRST `ensureMember` step. ADDITIVE
    /// ONLY — never removes/migrates/destroys. Blocking HTTP on the loop,
    /// bounded to one node per group per pass.
    fn reconcileMembership(self: *Router) void {
        if (!self.reconcile_membership) return;
        if (!self.directory.isLeader()) return; // single writer
        const a = self.allocator;
        const tenants = self.directory.listPlacements(a) catch return;
        defer {
            for (tenants) |t| a.free(t);
            a.free(tenants);
        }
        for (tenants) |tenant| {
            // resolveOwned (not resolve): the node set is held across the blocking
            // backendCalls below, and a concurrent re-address (applyClusterLocal on
            // the pump thread — exactly the /_control/cluster grow that adds a
            // node) frees `resolve`'s projection-aliased slice → use-after-free.
            // The owned copy is taken under the directory lock.
            var res = (self.directory.resolveOwned(a, tenant) catch continue) orelse continue;
            defer res.deinit(a);
            const nodes = res.nodes;
            if (nodes.len == 0) continue;
            const leader_url = self.findDestLeaderUrl(nodes, tenant) orelse continue;
            defer a.free(leader_url);
            // One membership CHANGE per group per pass: a node that's already
            // good (.done) → check the next; a transient failure (.failed) →
            // try the NEXT node (a single unreachable node must not starve the
            // rest of the cluster from being backfilled); a real mutation
            // (.progressed) → stop and re-observe next pass.
            for (nodes, 0..) |node_url, i| {
                const node_id: u64 = @intCast(i + 1); // POSITIONAL id (nodes[i] ↔ raft id i+1)
                switch (self.ensureMember(tenant, node_url, node_id, leader_url, res.id)) {
                    .done, .failed => continue,
                    .progressed => break,
                }
            }
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
    ///   4-5. stream the source leader's non-quiescing snapshot peer→peer into
    ///      every dest node in merge mode (insert-if-absent, out-of-band from
    ///      raft) — the CP never buffers the bundle.
    ///   6. flip the directory — the atomic commit point.
    ///   7. evict the source — drops its instance + group + forward marker,
    ///      so it stops serving + forwarding; serve-or-forward routes any
    ///      straggler to the dest.
    ///
    /// A pre-flip failure forward-ends the source (stops dual-writing) +
    /// evicts the half-attached dest, leaving the tenant serving on the
    /// source untouched. Brief-pause `handleMove` stays for callers that want
    /// it. The forward target is the full dest node list (leader first) —
    /// the source re-aims past 421s, so a dest-leader change mid-overlap
    /// degrades to a retry hop, not a failed acked write.
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
        //    The plan blob (if any) rides attach so the dest enforces limits
        //    from the first forwarded write onward.
        const plan_blob = self.directory.planForOwned(a, tenant) catch null;
        defer if (plan_blob) |p| a.free(p);
        if (!self.attachToAll(dest_nodes, "", tenant, plan_blob, null)) {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }
        // 2. Await the dest leader; the source's forward target is the FULL
        //    dest node list, leader first — the source tries it in order and
        //    re-aims past 421s, so a dest leader change mid-overlap costs a
        //    retry hop instead of failing acked source writes.
        const dest_leader = self.findDestLeaderUrl(dest_nodes, tenant) orelse {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        };
        defer a.free(dest_leader);
        const fwd_targets = csvLeaderFirst(a, dest_leader, dest_nodes) orelse {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(fwd_targets);

        // 3. forward-begin on the source leader (dual-write to the dest).
        if (!self.forwardBeginOnLeader(src_nodes, tenant, fwd_targets)) {
            self.evictAll(tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }

        // 4+5. Stream the source leader's non-quiescing snapshot directly to
        //      every dest node in merge mode (insert-if-absent). The source
        //      pushes peer→peer; the CP no longer buffers the bundle, so a
        //      multi-GB tenant moves with bounded memory on all three parties.
        if (!self.streamMergeToAll(src_nodes, dest_nodes, tenant)) {
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
                const resp = self.backendCall(base, suffix, .GET, "", &.{}) catch continue;
                var r = resp;
                r.deinit(a);
                if (r.status == 200) return a.dupe(u8, base) catch null;
            }
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        return null;
    }

    /// The forward-target list for `v2-forward-begin`: every dest node's base
    /// URL, comma-separated, with the current leader first (the common case
    /// is then one forward attempt). Null on OOM.
    fn csvLeaderFirst(a: std.mem.Allocator, leader: []const u8, nodes: []const []const u8) ?[]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(a);
        out.appendSlice(a, leader) catch return null;
        for (nodes) |base| {
            if (std.mem.eql(u8, base, leader)) continue;
            out.append(a, ',') catch return null;
            out.appendSlice(a, base) catch return null;
        }
        return out.toOwnedSlice(a) catch null;
    }

    /// forward-begin on the source leader: try each source node's leader-gated
    /// `/_system/v2-forward-begin {tenant,dest}` until one 204s (the leader).
    fn forwardBeginOnLeader(self: *Router, src_nodes: []const []const u8, tenant: []const u8, dest_url: []const u8) bool {
        const a = self.allocator;
        const fb = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"dest\":\"{s}\"}}", .{ tenant, dest_url }) catch return false;
        defer a.free(fb);
        for (src_nodes) |base| {
            const resp = self.backendCall(base, "/_system/v2-forward-begin", .POST, fb, &.{}) catch continue;
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
            if (self.backendCall(base, "/_system/v2-forward-end", .POST, tbody, &.{})) |r| {
                const ok = r.status == 204;
                var rr = r;
                rr.deinit(a);
                if (ok) return;
            } else |_| {}
        }
    }

    /// raft Phase 2.5: STREAM the source leader's non-quiescing snapshot directly
    /// to every destination node in merge mode (insert-if-absent) — the source
    /// pushes peer→peer, so the CP never buffers a (multi-GB) bundle. Replaces the
    /// retired buffered dump→CP→dest fan (the old `v2-load-merge` load endpoint).
    fn streamMergeToAll(self: *Router, src_nodes: []const []const u8, dest_nodes: []const []const u8, tenant: []const u8) bool {
        for (dest_nodes) |dest| {
            if (!self.snapshotPushToLeader(src_nodes, tenant, dest)) return false;
        }
        return true;
    }

    /// Try each source node's leader-gated `/_system/v2-snapshot-push` until one
    /// accepts (the leader streams its held snapshot to `dest` in merge mode and
    /// only then responds). Blocks for the whole transfer — generous timeout; the
    /// source's own page-pinning deadline aborts first if the tenant is too big.
    fn snapshotPushToLeader(self: *Router, src_nodes: []const []const u8, tenant: []const u8, dest: []const u8) bool {
        const a = self.allocator;
        const hdrs = [_]curl.Header{
            .{ .name = TENANT_HEADER, .value = tenant },
            .{ .name = "x-rewind-dest", .value = dest },
            .{ .name = "x-rewind-snapshot-mode", .value = "merge" },
        };
        for (src_nodes) |base| {
            const resp = self.backendCallTimeout(base, "/_system/v2-snapshot-push", .POST, "", &hdrs, 40 * 60 * 1000) catch |err| {
                std.log.warn("rewind-cp: v2-snapshot-push on {s} → {s}", .{ base, @errorName(err) });
                continue;
            };
            var r = resp;
            defer r.deinit(a);
            switch (r.status) {
                // 204 = streamed + merged; 409 = dest already had it (benign).
                204, 409 => return true,
                // 421 = this source node isn't the leader; try the next.
                421 => continue,
                else => {
                    std.log.warn("rewind-cp: v2-snapshot-push on {s} → {d}", .{ base, r.status });
                    return false;
                },
            }
        }
        return false;
    }

    /// Blocking libcurl call to a backend's move surface, presenting the
    /// move secret plus any `extra_headers` (e.g. `X-Rewind-Tenant`,
    /// `X-Rewind-Plan`). Returns status + an owned copy of the response body.
    // ── membership reconciler: ensureMember (Phase 3) ───────────────────────
    //
    // Composes the proven out-of-band endpoints into a LEARNER-FIRST step
    // machine that converges a node toward a caught-up voter. Additive/safe:
    // the only voting-power removal is a demote-to-learner of a STUCK voter (so
    // it can't disrupt elections while it catches up — the __admin__ lesson);
    // it never shrinks/migrates/destroys. All over the private CP network via
    // backendCall (move-secret auto-added). Blocking HTTP on the CP loop; the
    // reconciler does one node per group per pass.
    const EnsureResult = enum { done, progressed, failed };
    /// caught-up tolerance: matched/applied within this of leader_last counts as
    /// caught up (raft replicates the tail in well under this; avoids flapping
    /// as leader_last advances on a live group).
    const RECONCILE_SLACK: u64 = 16;
    const PeerJson = struct { id: u64 = 0, matched: u64 = 0, recent_active: bool = false };
    const MemberStatusJson = struct {
        leader_last: u64 = 0,
        voters: []const u64 = &.{},
        learners: []const u64 = &.{},
        peers: []const PeerJson = &.{},
    };
    fn idIn(list: []const u64, id: u64) bool {
        for (list) |x| if (x == id) return true;
        return false;
    }

    /// RC-6 hysteresis: true iff `node_id` of `tenant` has been a continuous
    /// demote candidate (`!recent_active`, still a hosted voter) for at least
    /// `demote_grace_ns`. The FIRST call starts the timer and returns false, so a
    /// single `!recent_active` reading (a transient restart) never demotes.
    fn demoteGraceElapsed(self: *Router, tenant: []const u8, node_id: u64) bool {
        var kbuf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{s}|{d}", .{ tenant, node_id }) catch return false;
        const now = std.time.nanoTimestamp();
        if (self.demote_inactive_since.getPtr(key)) |since|
            return now - since.* >= self.demote_grace_ns;
        // First observation — start the grace window; never demote on it.
        const owned = self.allocator.dupe(u8, key) catch return false;
        self.demote_inactive_since.put(self.allocator, owned, now) catch {
            self.allocator.free(owned);
            return false;
        };
        return false;
    }

    /// Clear `node_id` of `tenant`'s demote grace timer — the voter recovered
    /// (recent_active) or left the hosted-voter state, so the window resets.
    fn clearDemoteTimer(self: *Router, tenant: []const u8, node_id: u64) void {
        var kbuf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{s}|{d}", .{ tenant, node_id }) catch return;
        if (self.demote_inactive_since.fetchRemove(key)) |kv| self.allocator.free(kv.key);
    }

    /// Advance node `node_id` (at `node_url`) ONE step toward being a caught-up
    /// voter of `tenant`'s group, talking to `leader_url`. `.done` when already a
    /// caught-up voter, `.progressed` after a step (re-check next pass), `.failed`
    /// on a transient error (retry next pass).
    fn ensureMember(self: *Router, tenant: []const u8, node_url: []const u8, node_id: u64, leader_url: []const u8, cluster_id: []const u8) EnsureResult {
        const a = self.allocator;
        // The leader is trivially a caught-up voter of its own group.
        if (std.mem.eql(u8, node_url, leader_url)) return .done;

        // The joining node's raft transport address from the registry (genesis
        // §3.3), carried on the add/promote conf-change so the leader can dial
        // it. Empty when the node isn't registered (a still-static cluster —
        // the leader falls back to its static peers). Owned; freed below.
        const raft_addr_owned: ?[]u8 = self.raftAddrFor(cluster_id, node_id);
        defer if (raft_addr_owned) |ra| a.free(ra);
        const raft_addr: []const u8 = raft_addr_owned orelse "";

        // 1. Observe the leader's per-peer view.
        const ms_path = std.fmt.allocPrint(a, "/_system/v2-member-status?tenant={s}", .{tenant}) catch return .failed;
        defer a.free(ms_path);
        const ms_resp = self.backendCall(leader_url, ms_path, .GET, "", &.{}) catch return .failed;
        defer a.free(ms_resp.body);
        if (ms_resp.status != 200) return .failed;
        var parsed = std.json.parseFromSlice(MemberStatusJson, a, ms_resp.body, .{ .ignore_unknown_fields = true }) catch return .failed;
        defer parsed.deinit();
        const ms = parsed.value;

        const is_voter = idIn(ms.voters, node_id);
        const is_learner = idIn(ms.learners, node_id);
        var voter_recent_active = false;
        if (is_voter) {
            for (ms.peers) |p| {
                if (p.id == node_id) {
                    voter_recent_active = p.recent_active;
                    if (p.recent_active and p.matched + RECONCILE_SLACK >= ms.leader_last) {
                        self.clearDemoteTimer(tenant, node_id); // responsive + caught up → reset grace
                        return .done;
                    }
                    break;
                }
            }
        }

        // OBSERVE whether the node holds a local instance. CRITICAL: distinguish
        // a CONFIRMED-absent (a clean 404 from a reachable node) from an UNKNOWN
        // (unreachable / errored / 5xx). A configured voter is removed ONLY when
        // its absence is confirmed — never on a probe failure, or a merely
        // rebooting/partitioned healthy voter gets torn out of the config (and a
        // rolling deploy makes voters transiently unreachable by design).
        const host = self.nodeGroupState(node_url, tenant);
        if (host == .unknown) return .failed; // can't observe → never mutate; retry next pass

        // RC-6 hysteresis bookkeeping: keep a demote grace timer ONLY while the
        // node is an actual demote candidate (a hosted voter the leader hasn't
        // heard from). Any other observed state resets it, so a transient
        // inactivity long ago can't carry into a later window and demote instantly.
        if (!(is_voter and host == .hosted and !voter_recent_active))
            self.clearDemoteTimer(tenant, node_id);

        if (is_voter) {
            if (host == .hosted) {
                // DEMOTE only a STUCK voter — one the leader has NOT heard from
                // within an election timeout (recent_active=false under
                // check_quorum: partitioned / dead / campaigning without acking
                // appends — the __admin__ wall). Demoting it stops it disrupting
                // elections while it catches up. A RESPONSIVE voter that is merely
                // BEHIND (recent_active but lagging under write load) is catching
                // up fine via normal replication and is NOT disrupting elections —
                // demoting it just churns healthy voters on a busy group (B1).
                // Leave it; raft replicates the tail.
                if (!voter_recent_active) {
                    // RC-6: demote only after SUSTAINED inactivity
                    // (REWIND_CP_DEMOTE_GRACE_MS). A single !recent_active reading
                    // is a transient restart, not a stuck voter, and tearing out a
                    // healthy-but-restarting voter shrinks the voter set →
                    // sub-majority commit (RC-1's trigger). Wait out the grace; a
                    // genuinely stuck voter stays inactive across it and is demoted.
                    if (!self.demoteGraceElapsed(tenant, node_id)) return .done;
                    self.clearDemoteTimer(tenant, node_id);
                    return if (self.reconcileConfChange(leader_url, tenant, node_id, "demote", raft_addr)) .progressed else .failed;
                }
                return .done; // responsive, just behind — no membership change needed
            }
            // host == .absent: a CONFIRMED phantom voter (configured voter,
            // reachable, NO local instance — wiped or never-formed) is REMOVED,
            // not bootstrapped in place. Bootstrapping a voter relies on the
            // leader's Progress.match (stale-HIGH from before the wipe) lining up
            // with the new baseline EXACTLY — and the leader's heartbeat carries
            // commit = min(match, committed), so if the node is reborn below that
            // match raft fatal!s (commit_to out of range). Removing the node drops
            // the leader's Progress entirely; the next pass re-adds it as a
            // LEARNER with a FRESH match=0, so the leader can never send a commit
            // beyond the node's log. The manager's ConfChangeQuorumGuard refuses
            // any remove that would drop below 2 voters, so this can't lose
            // quorum. Structural fix — the panic becomes impossible, not unlikely.
            return if (self.reconcileConfChange(leader_url, tenant, node_id, "remove", raft_addr)) .progressed else .failed;
        }
        if (is_learner) {
            if (host == .absent)
                return if (self.bootstrapMember(leader_url, node_url, tenant, node_id, true, cluster_id)) .progressed else .failed;
            const last_idx = self.nodeLastIndex(node_url, tenant) orelse return .progressed;
            if (last_idx + RECONCILE_SLACK >= ms.leader_last)
                return if (self.reconcileConfChange(leader_url, tenant, node_id, "promote", raft_addr)) .progressed else .failed;
            return .progressed; // catching up
        }
        // Absent from the config entirely: bootstrap as a learner (only if the
        // node doesn't already host the group) then AddLearner on the leader. The
        // born-learner idles (no campaign) until the leader's AddLearner lets it
        // replicate, then it catches up + is promoted next pass.
        if (host == .absent and !self.bootstrapMember(leader_url, node_url, tenant, node_id, true, cluster_id)) return .failed;
        return if (self.reconcileConfChange(leader_url, tenant, node_id, "add", raft_addr)) .progressed else .failed;
    }

    const HostState = enum { hosted, absent, unknown };
    /// Observe whether `node_url` holds a local group instance for `tenant`:
    /// `.hosted` (confstate 200), `.absent` (a clean 404 — reachable, no
    /// instance), or `.unknown` (unreachable / error / unexpected status). The
    /// hosted-vs-absent-vs-unknown distinction is load-bearing: the reconciler
    /// must never treat "can't reach the node" as "the node is empty".
    fn nodeGroupState(self: *Router, node_url: []const u8, tenant: []const u8) HostState {
        const a = self.allocator;
        const path = std.fmt.allocPrint(a, "/_system/v2-confstate?tenant={s}", .{tenant}) catch return .unknown;
        defer a.free(path);
        const resp = self.backendCall(node_url, path, .GET, "", &.{}) catch return .unknown;
        defer a.free(resp.body);
        return switch (resp.status) {
            200 => .hosted,
            404 => .absent,
            else => .unknown,
        };
    }

    /// `node_url`'s own raft LOG last index for `tenant` (the learner→promote
    /// catch-up signal), or null. Read from the NON-leader-gated `v2-last-index`
    /// (a learner is never the leader, so the leader-gated `v2-applied-baseline`
    /// would 421). This is the raft log's `last_index()` — entries RECEIVED into
    /// the log, which is the right promote gate: it is compared against the
    /// leader's own `leader_last` (also `last_index()`), so like is compared with
    /// like, and a node whose LOG has caught up is a valid voter (raft votes on
    /// log position, not apply). An out-of-band baseline (`apply_local_snapshot`)
    /// advances `last_index` directly, unlike the commit-seq atomic or the
    /// bundle-seeded store watermark, so a quiescent caught-up learner still trips
    /// the gate. (Earlier this was misnamed/-documented as an "applied/committed
    /// index" read from a `v2-committed` endpoint — neither exists; B2.)
    fn nodeLastIndex(self: *Router, node_url: []const u8, tenant: []const u8) ?u64 {
        const a = self.allocator;
        const path = std.fmt.allocPrint(a, "/_system/v2-last-index?tenant={s}", .{tenant}) catch return null;
        defer a.free(path);
        const resp = self.backendCall(node_url, path, .GET, "", &.{}) catch return null;
        defer a.free(resp.body);
        if (resp.status != 200) return null;
        var p = std.json.parseFromSlice(struct { last_index: u64 = 0 }, a, resp.body, .{ .ignore_unknown_fields = true }) catch return null;
        defer p.deinit();
        return p.value.last_index;
    }

    /// Propose a conf-change (`add`/`promote`/`demote`/`remove`) on `leader_url`.
    /// The joining node's raft transport address (`host:port`) from the
    /// directory registry, OWNED (caller frees), or null if unregistered. The
    /// genesis §3.3 address the reconciler carries on a conf-change add/promote.
    fn raftAddrFor(self: *Router, cluster_id: []const u8, node_id: u64) ?[]u8 {
        const a = self.allocator;
        const packed_bytes = (self.directory.nodeAddrOwned(a, cluster_id, node_id) catch return null) orelse return null;
        defer a.free(packed_bytes);
        const na = Directory.unpackNodeAddr(packed_bytes) orelse return null;
        if (na.raft_addr.len == 0) return null;
        return a.dupe(u8, na.raft_addr) catch null;
    }

    fn reconcileConfChange(self: *Router, leader_url: []const u8, tenant: []const u8, node_id: u64, op: []const u8, raft_addr: []const u8) bool {
        const a = self.allocator;
        // Carry the address only when known (add/promote of a registered node);
        // a demote/remove or a still-static cluster sends the bare body.
        const body = if (raft_addr.len > 0)
            std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"node_id\":{d},\"op\":\"{s}\",\"raft_addr\":\"{s}\"}}", .{ tenant, node_id, op, raft_addr }) catch return false
        else
            std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"node_id\":{d},\"op\":\"{s}\"}}", .{ tenant, node_id, op }) catch return false;
        defer a.free(body);
        const resp = self.backendCall(leader_url, "/_system/v2-confchange", .POST, body, &.{}) catch return false;
        defer a.free(resp.body);
        if (resp.status != 204) {
            std.log.warn("rewind-cp: reconcile confchange {s} node={d} {s} → {d}", .{ op, node_id, tenant, resp.status });
            return false;
        }
        std.log.info("rewind-cp: reconcile confchange {s} node={d} on {s}", .{ op, node_id, tenant });
        return true;
    }

    /// Out-of-band bootstrap of `tenant`'s group onto `node_url`: pull the
    /// leader's baseline {index,term} + snapshot bundle, attach (create group +
    /// load) on the node, then install the data-free raft baseline so the leader
    /// replicates the tail.
    /// Format a raft-id list as `a,b,c`, optionally appending one more id. Caller
    /// frees. The Phase 2d augmented-ConfState membership headers.
    fn joinIdsAug(a: std.mem.Allocator, ids: []const u64, extra: ?u64) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(a);
        for (ids, 0..) |id, i| {
            if (i != 0) try buf.append(a, ',');
            try buf.writer(a).print("{d}", .{id});
        }
        if (extra) |e| {
            if (ids.len != 0) try buf.append(a, ',');
            try buf.writer(a).print("{d}", .{e});
        }
        return buf.toOwnedSlice(a);
    }

    /// Build the genesis §4d attach-carry header — `id@raft_addr,…` for every
    /// REGISTERED cluster node EXCEPT `skip_id` (the joiner itself) — so a
    /// genesis-booted joiner learns the existing members' transport addresses and
    /// can ACK the leader's appends. Owned; null/empty when nothing is registered
    /// (a static-`REWIND_PEERS` cluster), in which case the header is omitted.
    fn peerAddrsHeader(self: *Router, cluster_id: []const u8, skip_id: u64) ?[]u8 {
        const a = self.allocator;
        const entries = self.directory.listClusterNodeAddrs(a, cluster_id) catch return null;
        defer {
            for (entries) |*e| e.deinit(a);
            a.free(entries);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(a);
        for (entries) |e| {
            if (e.id == skip_id) continue;
            const na = Directory.unpackNodeAddr(e.bytes) orelse continue;
            if (na.raft_addr.len == 0) continue;
            if (out.items.len != 0) out.append(a, ',') catch return null;
            out.writer(a).print("{d}@{s}", .{ e.id, na.raft_addr }) catch return null;
        }
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(a) catch null;
    }

    fn bootstrapMember(self: *Router, leader_url: []const u8, node_url: []const u8, tenant: []const u8, node_id: u64, as_learner: bool, cluster_id: []const u8) bool {
        const a = self.allocator;
        const bpath = std.fmt.allocPrint(a, "/_system/v2-applied-baseline?tenant={s}", .{tenant}) catch return false;
        defer a.free(bpath);
        const bresp = self.backendCall(leader_url, bpath, .GET, "", &.{}) catch return false;
        defer a.free(bresp.body);
        if (bresp.status != 200) return false;
        var bp = std.json.parseFromSlice(
            struct { index: u64 = 0, term: u64 = 0, epoch: u64 = 1, voters: []const u64 = &.{}, learners: []const u64 = &.{} },
            a,
            bresp.body,
            .{ .ignore_unknown_fields = true },
        ) catch return false;
        defer bp.deinit();

        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch return false;
        defer a.free(tbody);
        const snap = self.backendCall(leader_url, "/_system/v2-snapshot", .POST, tbody, &.{}) catch return false;
        defer a.free(snap.body);
        if (snap.status != 200) return false;

        // Attach AND install the baseline atomically (X-Rewind-Baseline-* headers
        // → createGroupAtBaseline on the worker). A separate v2-apply-snapshot
        // POST would leave a window where the freshly-attached empty group
        // (last_index 0) is reachable; a leader heartbeat carrying commit > 0
        // arriving in that window crashes raft (commit_to out of range). One
        // atomic op closes it. The store bundle (snap.body) is loaded by attach
        // before the group is created, so the baseline's data is already present.
        const bidx = std.fmt.allocPrint(a, "{d}", .{bp.value.index}) catch return false;
        defer a.free(bidx);
        const bterm = std.fmt.allocPrint(a, "{d}", .{bp.value.term}) catch return false;
        defer a.free(bterm);
        // Birth the joining group at the LEADER's epoch, not a hard-coded 1, or
        // the leader's epoch-stamped messages are fenced out and the join stalls
        // (the genesis `__admin__` group is epoch 0; a moved tenant is >1).
        const bepoch = std.fmt.allocPrint(a, "{d}", .{bp.value.epoch}) catch return false;
        defer a.free(bepoch);
        // Membership SSOT (Phase 2d), the AUGMENTED-ConfState approach: the
        // baseline carries the leader's CURRENT ConfState PLUS this node as a
        // learner, so the joiner learns its membership from the snapshot
        // (raft.rs:2629) AND satisfies the recipient-must-be-in-the-ConfState rule
        // (raft.rs:2581) WITHOUT requiring the leader's AddLearner to commit first.
        // Crucially this keeps the panic-safe bootstrap-THEN-add ORDER: the leader
        // does not track/commit-to this node until the AddLearner that FOLLOWS this
        // bootstrap, so it can never send a commit past the node's just-installed
        // baseline (the `to_commit out of range` abort the add-FIRST reorder hit).
        // `add_self` augments only when the leader's view doesn't already list the
        // node (the absent-from-config first touch); when it is already a learner
        // (re-bootstrap) the set is the leader's as-is.
        const add_self = !idIn(bp.value.voters, node_id) and !idIn(bp.value.learners, node_id);
        const voters_csv = joinIdsAug(a, bp.value.voters, null) catch return false;
        defer a.free(voters_csv);
        const learners_csv = joinIdsAug(a, bp.value.learners, if (add_self) node_id else null) catch return false;
        defer a.free(learners_csv);

        // Join as a non-voting learner (born-learner) when ADDING this node to
        // the group — a learner doesn't campaign, so it follows the leader and
        // catches up instead of deadlocking a high-term group. The baseline's
        // ConfState (above) is authoritative for the final role; this seeds the
        // pre-baseline born state.
        // Genesis §4d (attach-carry): the existing members' raft addresses, so a
        // genesis joiner can ACK the leader. Null on a static cluster → header
        // omitted. Lives until the call below.
        const peer_addrs = self.peerAddrsHeader(cluster_id, node_id);
        defer if (peer_addrs) |pa| a.free(pa);
        var th_buf = [_]curl.Header{
            .{ .name = TENANT_HEADER, .value = tenant },
            .{ .name = "X-Rewind-Baseline-Index", .value = bidx },
            .{ .name = "X-Rewind-Baseline-Term", .value = bterm },
            .{ .name = "X-Rewind-Epoch", .value = bepoch },
            .{ .name = "X-Rewind-Join-As-Learner", .value = if (as_learner) "1" else "0" },
            .{ .name = "X-Rewind-Voters", .value = voters_csv },
            .{ .name = "X-Rewind-Learners", .value = learners_csv },
            .{ .name = "X-Rewind-Peer-Addrs", .value = peer_addrs orelse "" },
        };
        const th: []const curl.Header = if (peer_addrs != null) th_buf[0..8] else th_buf[0..7];
        const ar = self.backendCall(node_url, "/_system/v2-attach", .POST, snap.body, th) catch return false;
        defer a.free(ar.body);
        if (ar.status != 204) return false;
        std.log.info("rewind-cp: reconcile bootstrapped {s} onto {s} (atomic baseline {d}/{d} epoch {d}, learner={}, conf_state voters=[{s}] learners=[{s}])", .{ tenant, node_url, bp.value.index, bp.value.term, bp.value.epoch, as_learner, voters_csv, learners_csv });
        return true;
    }

    fn backendCall(
        self: *Router,
        base_url: []const u8,
        path_suffix: []const u8,
        method: curl.Method,
        body: []const u8,
        extra_headers: []const curl.Header,
    ) !BackendResp {
        return self.backendCallTimeout(base_url, path_suffix, method, body, extra_headers, 15_000);
    }

    /// `backendCall` with an explicit total-transfer deadline. A streamed move
    /// push (`v2-snapshot-push`) holds the CP↔source call open for the WHOLE
    /// transfer (the source parks until its off-loop push lands), so it needs a
    /// generous timeout — the source's own `REWIND_SNAPSHOT_XFER_MAX_MS` deadline
    /// aborts + responds first; this is the wedged-source backstop.
    fn backendCallTimeout(
        self: *Router,
        base_url: []const u8,
        path_suffix: []const u8,
        method: curl.Method,
        body: []const u8,
        extra_headers: []const curl.Header,
        timeout_ms: u32,
    ) !BackendResp {
        const a = self.allocator;
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ base_url, path_suffix });
        defer a.free(url);

        var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
        defer headers.deinit(a);
        try headers.append(a, .{ .name = MOVE_SECRET_HEADER, .value = self.move_secret.? });
        for (extra_headers) |h| try headers.append(a, h);

        var easy = try curl.Easy.init(a);
        defer easy.deinit();
        var resp = try easy.request(a, .{
            .method = method,
            .url = url,
            .headers = headers.items,
            .body = body,
            .http_version = .h2c_prior_knowledge,
            .verify_tls = false,
            .timeout_ms = timeout_ms,
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
    // Raft logical-tick cadence (ms). Keep the CP directory group's election
    // timing in lockstep with the workers' tenant groups — same hardware, same
    // number — so election timeout ≈ election_tick × this is uniform across the
    // node (docs/raft-best-practices.md "how to size election/heartbeat"). The
    // default preserves the historical ~1ms cadence. Set BEFORE startPump.
    if (std.posix.getenv("REWIND_RAFT_TICK_MS")) |v| {
        if (std.fmt.parseInt(i64, v, 10)) |ms| {
            if (ms > 0) {
                cp_bridge.node.tick_interval_ns = ms * std.time.ns_per_ms;
                std.log.info("rewind-cp: raft tick interval = {d}ms (election timeout ≈ election_tick × {d}ms)", .{ ms, ms });
            }
        } else |_| {}
    }
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
            try directory.seedHosts(getEnvCfg("REWIND_HOSTS"));
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
                directory.seedHosts(getEnvCfg("REWIND_HOSTS")) catch |e| switch (e) {
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

    // Leader-elected ACME HTTP-01 issuer (gap #3 slice 3). Inert unless
    // `REWIND_ACME_DIRECTORY` is set — then it issues certs for mapped custom
    // domains lacking a `cert/{host}` and serves the challenge via
    // `/_cp/acme-challenge` (the front door's :80 listener forwards to it).
    const acme_handle: ?*acme_issuer.Handle = blk: {
        const dir_url = std.posix.getenv("REWIND_ACME_DIRECTORY") orelse break :blk null;
        const h = acme_issuer.spawn(.{
            .allocator = allocator,
            .directory = directory,
            .data_dir = cp_data_dir,
            .directory_url = dir_url,
            .contact_email = std.posix.getenv("REWIND_ACME_CONTACT"),
            .insecure_tls = std.posix.getenv("REWIND_ACME_INSECURE_TLS") != null,
            .public_suffix = getEnvCfg("REWIND_PUBLIC_SUFFIX"),
            .system_suffix = getEnvCfg("REWIND_SYSTEM_SUFFIX"),
        }) catch |err| {
            std.log.warn("rewind-cp: ACME issuer spawn failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        std.log.info("rewind-cp: ACME issuer enabled (dir={s})", .{dir_url});
        break :blk h;
    };
    defer if (acme_handle) |h| {
        h.signalStop();
        h.join();
    };

    const reconcile_membership = blk: {
        const v = std.posix.getenv("REWIND_CP_RECONCILE_MEMBERSHIP") orelse break :blk false;
        break :blk std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    };
    // The reconciler drives every DP membership call through backendCall, which
    // presents the move secret. Enabling it without REWIND_MOVE_SECRET would
    // panic on the first tick (move_secret.?). Refuse at boot instead.
    if (reconcile_membership and move_secret == null) {
        std.log.err("rewind-cp: REWIND_CP_RECONCILE_MEMBERSHIP=1 requires REWIND_MOVE_SECRET", .{});
        return error.MissingMoveSecret;
    }
    // RC-6 demote hysteresis grace (default 60s); tunable for tests/operators.
    const demote_grace_ns: i128 = blk: {
        const v = std.posix.getenv("REWIND_CP_DEMOTE_GRACE_MS") orelse break :blk 60 * std.time.ns_per_s;
        const ms = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t"), 10) catch break :blk 60 * std.time.ns_per_s;
        break :blk @as(i128, ms) * std.time.ns_per_ms;
    };
    var router = Router{ .allocator = allocator, .directory = directory, .move_secret = move_secret, .cp_peer_urls = cp_peer_urls, .self_cp_idx = cp_self_idx, .acme = acme_handle, .reconcile_membership = reconcile_membership, .demote_grace_ns = demote_grace_ns };

    // Periodic membership reconciliation on the directory leader (between
    // request batches). last=0 → the first iteration reconciles, so a CP
    // restart / failover converges membership within one tick. Period from
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
                router.reconcileMembership();
            }
        }
    }
    std.log.info("rewind-cp: shut down", .{});
}

// ── RC-6 demote hysteresis ───────────────────────────────────────────────────

test "RC-6: demote needs sustained inactivity — a recovery before the grace resets it" {
    const a = std.testing.allocator;
    // Only the demote-timer fields are exercised by demoteGraceElapsed /
    // clearDemoteTimer; the rest of Router is never touched here.
    var r: Router = undefined;
    r.allocator = a;
    r.demote_inactive_since = .empty;
    defer {
        var it = r.demote_inactive_since.iterator();
        while (it.next()) |e| a.free(e.key_ptr.*);
        r.demote_inactive_since.deinit(a);
    }

    // grace 0: the SECOND consecutive inactive observation is already past the
    // window. Even so, a demote NEVER fires on the FIRST observation — a single
    // !recent_active reading is always treated as a transient.
    r.demote_grace_ns = 0;

    // SUSTAINED candidate (the genuinely-stuck voter): obs #1 starts the timer
    // (no demote), obs #2 is past the (zero) grace → demote. This proves the
    // mechanism still demotes a real stuck voter.
    try std.testing.expect(!r.demoteGraceElapsed("stuck", 2)); // obs #1 — never on first sight
    try std.testing.expect(r.demoteGraceElapsed("stuck", 2)); // obs #2 — sustained → demote

    // TRANSIENT-THEN-RECOVER (the rolling-restart hazard): SAME grace (0), SAME
    // two inactive observations — but the voter RECOVERS (timer cleared) in
    // between, so the post-recovery observation is a fresh "first" and must NOT
    // demote. The recovery is the only difference from the sustained case above,
    // and it flips the outcome demote → no-demote.
    try std.testing.expect(!r.demoteGraceElapsed("flap", 3)); // obs #1 inactive (transient)
    r.clearDemoteTimer("flap", 3); //                            recovered: recent_active again
    try std.testing.expect(!r.demoteGraceElapsed("flap", 3)); // obs after recovery — NOT demoted

    // Distinct (tenant,node) keys never share a window.
    try std.testing.expect(!r.demoteGraceElapsed("flap", 4)); // different node → own fresh timer
    try std.testing.expect(!r.demoteGraceElapsed("other", 3)); // different tenant → own fresh timer

    // A real (non-zero) grace never demotes within the window, across repeated
    // observations — a voter inactive for < grace is left a voter.
    r.demote_grace_ns = 60 * std.time.ns_per_s;
    try std.testing.expect(!r.demoteGraceElapsed("slow", 5));
    try std.testing.expect(!r.demoteGraceElapsed("slow", 5)); // still within 60s → no demote
}
