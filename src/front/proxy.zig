//! Streaming reverse-proxy core for rewind-front.
//!
//! Replaces the first-cut blocking-curl forward (one synchronous
//! `easy.request` per proxied request inside the poll loop) with
//! same-poll-loop rove-h2 CLIENT legs: one pooled h2c connection per
//! backend node, every proxied request a multiplexed stream on it.
//! Nothing blocks; bodies stream both ways with end-to-end
//! backpressure:
//!
//!   downstream request body  → BodySink on the front's h2 SERVER side
//!                              (headers_first) → per-flow buffer →
//!                              client_stream_data_in chunks upstream;
//!                              the sink repays downstream window only
//!                              as chunks drain upstream.
//!   upstream response body   → client_headers_first early emit +
//!                              BodySink on the front's h2 CLIENT side
//!                              → per-flow queue → stream_data_in
//!                              chunks downstream; the sink repays
//!                              upstream window only as chunks drain
//!                              to the downstream socket.
//!
//! curl survives ONLY for control-plane lookups (`/_cp/route`; cert +
//! ACME fetches stay in main.zig) — cached, small, off the data path.
//!
//! ## Retry semantics (unchanged contracts, new mechanics)
//!
//! 421 not-leader is retry-safe by contract (nothing entered the raft
//! log). The old front retried because it held the whole body; a
//! streaming front can only retry what it can REPLAY. Every flow keeps
//! the request body in a replay buffer until it outgrows `REPLAY_CAP`
//! (complete classic bodies are kept whole regardless of size — they
//! are already in RAM). On 421 / transport-error-before-response with
//! the buffer intact, the flow re-aims at the next node and replays.
//! Once a streamed body has run past the cap, a 421 maps to a plain
//! retryable 503 (nothing executed — the follower refused at the
//! door) and the client's retry policy owns the decision, exactly
//! like the ambiguous post-propose 503, which is never platform-
//! retried (docs/architecture/routing-and-ingress.md §2).
//!
//! WebSocket: the h1 listener surfaces Upgrade heads
//! (`websocket_surface`), and each accepted connection tunnels
//! upstream as an RFC 8441 Extended CONNECT stream on the pooled h2c
//! conn (websocket-plan §8.5) — `WsTunnel` pairs the raw-relay
//! downstream socket with the CONNECT stream; 421 re-aims like any
//! request; the downstream 101 waits for the upstream 200.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const blob = @import("rove-blob");

const curl = blob.curl;
const Entity = rove.Entity;

const route_resolver = @import("route_resolver.zig");
const RouteResolver = route_resolver.RouteResolver;

/// Per-entity correlation component, merged into the front's h2
/// `request_row`. On proxy-created entities (upstream pump entities,
/// connect entities) it points at the owning Flow / Upstream; on
/// h2-created entities it is zero. `attempt` guards against terminal
/// events from an abandoned (re-aimed) upstream attempt being
/// credited to the current one.
pub const FlowRef = struct {
    ptr: ?*anyopaque = null,
    attempt: u32 = 0,
    /// `ptr` is a *WsTunnel, not a *Flow (Extended-CONNECT WS tunnel
    /// pump/terminal entities — websocket-plan §8.5).
    tunnel: bool = false,
};

/// Request-body bytes kept for 421 / transport-error replay. Streamed
/// bodies that outgrow this forfeit platform-side retry (the client
/// sees a retryable 503 / 502 instead). Complete classic bodies are
/// exempt — they replay at any size.
pub const REPLAY_CAP: usize = 256 * 1024;

/// Per-stream chunk size for both pump directions. One chunk is in
/// flight per stream per direction (the entity cycle), so this also
/// bounds the per-flow copy unit.
pub const CHUNK_MAX: u32 = 64 * 1024;

/// Reconnect backoff for a backend node whose connect failed.
const CONNECT_BACKOFF_NS: i128 = 500 * std.time.ns_per_ms;

/// How long a request parks waiting for a cold route resolution before
/// it gives up with a retryable 503. Bounds the worst case for a
/// never-seen host when the CP is slow/down (vs. the old behavior of
/// freezing the whole loop for the libcurl timeout).
const ROUTE_WAIT_NS: i128 = 2500 * std.time.ns_per_ms;

/// A flow whose request is fully sent upstream but that produces no
/// response headers within this window is treated as a stuck stream: the
/// upstream stream is RST and the client gets a 504, rather than hanging
/// until the h2 idle GC (or forever, if the connection never goes idle —
/// see the front-door TTFB investigation). Set well above the worker
/// handler budget (<=10s) so slow-but-valid handlers aren't killed; this
/// only bounds the genuinely-stuck case.
const RESPONSE_WAIT_NS: i128 = 30_000 * std.time.ns_per_ms;

/// How long a WS tunnel waits for a live upstream conn to advertise
/// `SETTINGS_ENABLE_CONNECT_PROTOCOL` before giving up (re-aim/502). The
/// peer SETTINGS normally lands within one RTT of connect-complete; this
/// only bounds a genuinely non-RFC-8441 upstream.
const SETTINGS_WAIT_NS: i128 = 2000 * std.time.ns_per_ms;

// ── Small shared helpers (formerly in main.zig) ───────────────────────

pub fn headerValue(rh: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    const fields = rh.fields orelse return null;
    var i: u32 = 0;
    while (i < rh.count) : (i += 1) {
        const f = fields[i];
        if (std.ascii.eqlIgnoreCase(f.name[0..f.name_len], name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

/// Strip a `:port` suffix from an `:authority` / Host value, matching
/// the worker's `hostOnly`. Leaves bare hostnames untouched.
pub fn hostOnly(authority: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |i| return authority[0..i];
    return authority;
}

/// hop-by-hop headers must not be forwarded across a proxy (RFC 7230
/// §6.1). `expect` rides along: the front does not implement
/// 100-continue relaying and the worker's h2 server ignores it.
fn dropFromRequest(name: []const u8) bool {
    const hop = [_][]const u8{
        "connection",          "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te",         "trailer",
        "transfer-encoding",   "upgrade",    "expect",
        "host",
    };
    for (hop) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

/// A response header that must NOT be relayed: hop-by-hop, pseudo
/// (`:status`), and framing headers the downstream response layer owns
/// (`content-length` — the relay re-frames as h2 DATA / h1 chunked).
fn dropFromResponse(name: []const u8) bool {
    const hop = [_][]const u8{
        "connection",          "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te",         "trailer",
        "transfer-encoding",   "upgrade",    "content-length",
    };
    if (name.len > 0 and name[0] == ':') return true;
    for (hop) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

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

// ── Route cache (host → cluster nodes, single TTL) ────────────────────
//
// Single-threaded (one poll loop), no locking. No active eviction (size
// bounded by distinct active hosts). A fresh entry (within `ttl_ns`) is
// served inline; past the TTL the host re-resolves by PARKING (the
// off-loop resolver answers, the parked flow resumes) — never by
// blocking the poll loop, and never by serving a stale entry. Re-
// resolving past the TTL (instead of serving stale) is what keeps a
// tenant MOVE correct: serving the cached old cluster after it evicted
// the tenant returns a relayed 404, so we must re-resolve, not serve
// stale. The TTL therefore also bounds move-propagation latency.
pub const RouteCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    ttl_ns: i128,

    const CacheEntry = struct {
        nodes: [][]u8,
        expires_ns: i128,
    };

    pub fn init(allocator: std.mem.Allocator, ttl_ns: i128) RouteCache {
        return .{ .allocator = allocator, .ttl_ns = ttl_ns };
    }

    pub fn deinit(self: *RouteCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            freeNodes(self.allocator, e.value_ptr.nodes);
        }
        self.map.deinit(self.allocator);
    }

    fn get(self: *RouteCache, host: []const u8, now_ns: i128) ?[]const []const u8 {
        const e = self.map.getPtr(host) orelse return null;
        if (now_ns >= e.expires_ns) return null;
        return e.nodes;
    }

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

    pub fn invalidate(self: *RouteCache, host: []const u8) void {
        if (self.map.fetchRemove(host)) |kv| {
            self.allocator.free(kv.key);
            freeNodes(self.allocator, kv.value.nodes);
        }
    }
};

// ── Leader hint cache (host → leader node origin) ─────────────────────
//
// The worker dispatch-gate makes every follower 421 a *dynamic* request
// (static is served node-local before the gate, so it never enters the 421
// path). So a 2xx that follows a 421 in a flow can only have come from the
// leader — we record it here (`note`) and start the next request for that
// host AT the leader (`startIdx`), skipping the sequential redirect scan
// that would otherwise tax every read. Self-correcting: after a leadership
// change or tenant move the stale origin isn't found in the fresh `nodes`,
// so `startIdx` returns 0 and the next 421 re-learns; if the cached leader
// is found DOWN, the flow's transport-error path calls `drop`. Independent
// of `RouteCache` (which can be TTL-disabled, re-resolving every request),
// so the hint survives route re-resolution. Keys + values are owned.
const LeaderCache = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(self: *LeaderCache, a: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.map.deinit(a);
    }

    /// Index of the cached leader for `host` within `nodes`, or 0 when
    /// there's no hint or the hinted origin is absent (stale → scan + relearn).
    fn startIdx(self: *const LeaderCache, host: []const u8, nodes: []const []const u8) usize {
        const origin = self.map.get(host) orelse return 0;
        for (nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n, origin)) return i;
        }
        return 0;
    }

    /// Record `origin` as the leader for `host`. Idempotent; replaces a
    /// changed value (freeing the old), dupes the key on first insert.
    /// Best-effort: an allocation failure just skips the hint (correctness
    /// is the 421 re-aim; this is only the optimization).
    fn note(self: *LeaderCache, a: std.mem.Allocator, host: []const u8, origin: []const u8) void {
        const gop = self.map.getOrPut(a, host) catch return;
        if (gop.found_existing) {
            if (std.mem.eql(u8, gop.value_ptr.*, origin)) return;
            a.free(gop.value_ptr.*);
        } else {
            const key = a.dupe(u8, host) catch {
                _ = self.map.remove(host);
                return;
            };
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = a.dupe(u8, origin) catch {
            const k = gop.key_ptr.*;
            _ = self.map.remove(host);
            a.free(k);
            return;
        };
    }

    /// Forget the cached leader for `host` (the node we started at is down).
    fn drop(self: *LeaderCache, a: std.mem.Allocator, host: []const u8) void {
        if (self.map.fetchRemove(host)) |kv| {
            a.free(kv.key);
            a.free(kv.value);
        }
    }
};

const RouteResult = union(enum) {
    nodes: []const []const u8, // cache-owned; valid for this loop iteration
    moving,
    not_found,
    /// No cached route — a resolve was enqueued; the caller parks the
    /// request until `drainRouteCompletions` lands the answer.
    pending,
};

// ── The proxy ─────────────────────────────────────────────────────────

pub fn Proxy(comptime FrontH2: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        reg: *rove.Registry,
        server: *FrontH2,
        /// CP origins for `/_cp/route` (any CP node answers; tried in
        /// order). `REWIND_CP_URL`.
        cp_urls: []const []const u8,
        cache: *RouteCache,
        /// Off-loop CP route resolver — the poll loop never blocks on a
        /// `/_cp/route` query.
        resolver: *RouteResolver,
        /// host → flows/tunnels parked awaiting a cold route resolution.
        /// Keys are allocator-owned host copies. Mirrors the `up.waiters`
        /// park-on-connect pattern, keyed by host instead of upstream.
        route_waiters: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Waiter)) = .empty,
        /// Hosts with a resolve in flight (dedupe). Loop-thread only —
        /// no lock. Keys are allocator-owned host copies.
        route_pending: std.StringHashMapUnmanaged(void) = .empty,
        /// host → backend pool entry, keyed by node origin URL.
        pool: std.StringHashMapUnmanaged(*Upstream) = .empty,
        /// host → leader node origin, to start each request at the leader
        /// and skip the redirect scan. See `LeaderCache`.
        leaders: LeaderCache = .{},
        /// (upstream Session entity, stream id) → flow, for correlating
        /// h2-created `client_response_receiving` entities (which carry
        /// no FlowRef).
        flows_by_up: std.AutoHashMapUnmanaged(StreamKey, *Flow) = .empty,
        /// WS tunnels by upstream (sess, sid) — the CONNECT-response
        /// mapping (checked BEFORE flows_by_up: an unmapped receiving
        /// stream is reset, which must never hit a tunnel).
        tunnels_by_up: std.AutoHashMapUnmanaged(StreamKey, *WsTunnel) = .empty,
        /// Live-flow count (operator visibility / leak canary).
        live_flows: usize = 0,
        live_tunnels: usize = 0,

        const StreamKey = struct {
            idx: u32,
            gen: u32,
            sid: u32,
        };

        fn keyOf(sess: Entity, sid: u32) StreamKey {
            return .{ .idx = sess.index, .gen = sess.generation, .sid = sid };
        }

        // ── Upstream pool ─────────────────────────────────────────────

        const Waiter = union(enum) {
            flow: *Flow,
            tunnel: *WsTunnel,
        };

        const Upstream = struct {
            origin: []u8, // owned, also the pool key
            state: enum { down, connecting, up } = .down,
            sess: Entity = Entity.nil,
            addr: ?std.net.Address = null,
            last_fail_ns: i128 = 0,
            /// Flows/tunnels waiting on the in-flight connect.
            waiters: std.ArrayListUnmanaged(Waiter) = .empty,
        };

        /// One WS tunnel: a downstream h1 Upgrade paired with an upstream
        /// Extended-CONNECT stream on the pooled h2c conn (websocket-plan
        /// §8.5). The front never parses frames — bytes relay verbatim in
        /// both directions; the worker unmasks. Freed when `done` with no
        /// outstanding terminals or sink refs.
        const WsTunnel = struct {
            proxy: *Self,
            down_conn: Entity,
            /// The `ws_upgrade_out` handle; valid until `decided`
            /// (wsUpgradeAccept / wsUpgradeReject consume it).
            upgrade_ent: Entity,
            authority: []u8, // owned
            host: []u8, // owned
            nodes: [][]u8 = &.{},
            node_idx: usize = 0,
            attempt: u32 = 0,
            /// Parked in `route_waiters` awaiting a cold-route resolve — no
            /// upstream attempt started yet (mirrors `Flow.awaiting_route`).
            /// WS has no body to buffer; the downstream socket just waits.
            awaiting_route: bool = false,
            route_deadline_ns: i128 = 0,
            /// Parked on a live pool conn whose peer SETTINGS hasn't yet
            /// advertised ENABLE_CONNECT_PROTOCOL (a freshly-`.up` leg —
            /// its SETTINGS trails connect-complete). Re-checked each cycle
            /// by `serviceTunnelSettingsWaiters` until the bit shows up or
            /// `settings_deadline_ns` fires. `up_sess` holds the conn.
            awaiting_settings: bool = false,
            settings_deadline_ns: i128 = 0,
            up_sess: Entity = Entity.nil,
            up_sid: u32 = 0,
            waiting_conn: bool = false,
            attempt_live: bool = false,
            pending_terminals: u8 = 0,
            /// Downstream socket bytes awaiting upstream chunks.
            up_buf: std.ArrayListUnmanaged(u8) = .empty,
            /// Bytes moved into upstream chunks, not yet reported to the
            /// downstream tunnel sink's `drained` (read unpark).
            down_drained: u32 = 0,
            /// Upstream response bytes written downstream, not yet
            /// reported to the upstream sink's `drained` (window repay).
            up_drained: u32 = 0,
            chunk_inflight: u32 = 0,
            accepted: bool = false,
            decided: bool = false,
            down_gone: bool = false,
            done: bool = false,
            sink_refs: u8 = 0,
        };

        // ── Flow — one proxied request ────────────────────────────────

        const DownHome = enum { receiving, classic, responding };

        const Flow = struct {
            proxy: *Self,
            authority: []u8, // owned; raw (with :port), for :authority upstream
            host: []u8, // owned; portless, the cache/invalidate key

            // downstream identity
            down_ent: Entity,
            down_sess: Entity,
            down_sid: u32,
            /// Which collection the downstream entity currently sits in
            /// while it is OURS to move (`request_receiving` for
            /// streaming intake, `request_out` for classic). Once moved
            /// into the response pipeline it belongs to h2.
            down_home: DownHome,
            down_alive: bool = true,
            /// Downstream died mid-request-body (sink abort).
            down_gone: bool = false,

            // request body (replay buffer / forwarding window)
            body: std.ArrayListUnmanaged(u8) = .empty,
            /// Absolute body offset of body.items[0] (prefix may be
            /// trimmed once non-replayable).
            body_base: usize = 0,
            /// Absolute body bytes received from downstream so far.
            body_total: usize = 0,
            body_complete: bool = false,
            replayable: bool = true,
            down_sink_live: bool = false,
            /// Bytes forwarded upstream, not yet reported to the
            /// downstream sink's `drained` (window repayment).
            down_drained: u32 = 0,

            // route resolution (cold-host park)
            /// Parked in `route_waiters` awaiting a CP route answer; no
            /// upstream attempt started yet, body still buffering.
            awaiting_route: bool = false,
            route_deadline_ns: i128 = 0,

            // upstream attempt
            nodes: [][]u8 = &.{},
            node_idx: usize = 0,
            /// Set once this flow has seen a 421 (not-leader) from some
            /// node. A later 2xx then provably came from the leader (see
            /// `leaders`), so we record `nodes[node_idx]` as the leader.
            saw_421: bool = false,
            attempt: u32 = 0,
            /// Pump entities issued but not yet seen terminal in
            /// `client_response_out` — the flow may not be freed while
            /// any are outstanding (their FlowRef points here).
            pending_terminals: u8 = 0,
            attempt_live: bool = false,
            reconnect_budget: u8 = 1,
            waiting_conn: bool = false,
            up_sess: Entity = Entity.nil,
            up_sid: u32 = 0,
            /// Absolute body bytes handed to the current attempt.
            sent: usize = 0,
            up_chunk_inflight: u32 = 0,
            up_closed: bool = false,

            // response relay
            resp_started: bool = false,
            /// Armed (to `now + RESPONSE_WAIT_NS`) once the request body
            /// is fully forwarded and we're awaiting response headers. If
            /// it fires before `resp_started`, the upstream is stuck: RST
            /// it and 504 the client instead of hanging. 0 = not armed.
            response_deadline_ns: i128 = 0,
            resp_streaming: bool = false,
            resp_queue: std.ArrayListUnmanaged(u8) = .empty,
            resp_eof: bool = false,
            /// Upstream died mid-response — abort downstream instead of
            /// a clean close.
            resp_failed: bool = false,
            resp_sink_live: bool = false,
            /// Bytes written downstream, not yet repaid to the upstream
            /// response sink's `drained`.
            resp_drained: u32 = 0,
            down_chunk_inflight: u32 = 0,
            down_closed: bool = false,

            /// h2 sink references still pointing at this flow.
            sink_refs: u8 = 0,
            /// The downstream entity has been reaped from
            /// `response_out` — its FlowRef no longer exists. The flow
            /// may only be freed once this is true (every server
            /// stream entity eventually reaches `response_out`:
            /// normal completion, serverStreamClose, the orphan
            /// sweeps, or writesAccount error paths).
            detached: bool = false,

            fn bodyAvail(f: *const Flow) usize {
                return f.body_total - f.sent;
            }

            fn canRetry(f: *const Flow) bool {
                return f.replayable and !f.resp_started;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            reg: *rove.Registry,
            server: *FrontH2,
            cp_urls: []const []const u8,
            cache: *RouteCache,
            resolver: *RouteResolver,
        ) Self {
            return .{
                .allocator = allocator,
                .reg = reg,
                .server = server,
                .cp_urls = cp_urls,
                .cache = cache,
                .resolver = resolver,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.pool.valueIterator();
            while (it.next()) |up| {
                up.*.waiters.deinit(self.allocator);
                self.allocator.free(up.*.origin);
                self.allocator.destroy(up.*);
            }
            self.pool.deinit(self.allocator);
            self.flows_by_up.deinit(self.allocator);
            self.tunnels_by_up.deinit(self.allocator);
            // Parked flows themselves leak at shutdown (like live flows
            // — the process is exiting); free the map's own keys/lists.
            var rw = self.route_waiters.iterator();
            while (rw.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.deinit(self.allocator);
            }
            self.route_waiters.deinit(self.allocator);
            var rp = self.route_pending.keyIterator();
            while (rp.next()) |k| self.allocator.free(k.*);
            self.route_pending.deinit(self.allocator);
            self.leaders.deinit(self.allocator);
        }

        /// One proxy turn — run after `server.poll…()` each loop
        /// iteration. Phases are ordered so response events for a
        /// stream are seen before its pump turn, and terminal events
        /// last.
        pub fn run(self: *Self, now_ns: i128) !void {
            // Land any routes the resolver finished since last cycle
            // BEFORE intake, so this cycle's requests for the same host
            // hit the cache instead of re-parking.
            try self.drainRouteCompletions(now_ns);
            try self.intakeStreaming(now_ns);
            try self.intakeClassic(now_ns);
            try self.intakeWsUpgrades(now_ns);
            try self.reg.flush();
            try self.consumeConnects(now_ns);
            // Resume tunnels parked on a live conn awaiting its peer
            // ENABLE_CONNECT_PROTOCOL SETTINGS (cold-leg race), now that
            // this cycle's server poll may have landed that frame.
            self.serviceTunnelSettingsWaiters(now_ns);
            try self.reg.flush();
            try self.consumeResponseHeaders();
            try self.reg.flush();
            try self.pumpUpstream();
            try self.pumpDownstream();
            try self.reg.flush();
            try self.consumeUpstreamTerminal();
            try self.reg.flush();
            try self.consumeServerTerminal();
            try self.reg.flush();
            // 503 any flow that parked too long on a cold route.
            self.expireParkedRoutes(now_ns);
            // 504 any flow stuck awaiting upstream response headers.
            self.expireStalledResponses(now_ns);
            try self.reg.flush();
        }

        // ── Intake ────────────────────────────────────────────────────

        /// Early-emitted h2 requests (body still inbound). Attach a
        /// body sink and start the upstream attempt with the headers —
        /// headers-first propagates END TO END: the worker sees them
        /// while the body is still arriving at the edge.
        fn intakeStreaming(self: *Self, now_ns: i128) !void {
            const coll = &self.server.request_receiving;
            const entities = coll.entitySlice();
            const sids = coll.column(h2.StreamId);
            const sessions = coll.column(h2.Session);
            const req_hdrs = coll.column(h2.ReqHeaders);
            const flow_refs = coll.column(FlowRef);

            for (entities, sids, sessions, req_hdrs, flow_refs) |ent, sid, sess, rh, *fr| {
                if (fr.ptr != null) continue; // already flow-bound
                const flow = (try self.beginFlow(coll, ent, sid, sess, rh, now_ns, .receiving)) orelse continue;
                fr.ptr = @ptrCast(flow);

                // Body sink: bytes land in the flow's buffer; window is
                // repaid as they drain upstream.
                switch (self.server.requestBodySink(sess.entity, sid.id, downSinkOf(flow))) {
                    .streaming => {
                        flow.down_sink_live = true;
                        flow.sink_refs += 1;
                    },
                    .eof => {
                        // push()es + finish() already ran synchronously.
                        flow.sink_refs += 1; // released by sweep at close
                        flow.down_sink_live = true;
                    },
                    .gone => {
                        // Downstream died between emit and now; the
                        // orphan sweep will route the entity out.
                        flow.down_gone = true;
                    },
                }
                // A parked (cold-route) flow starts its attempt when the
                // route lands; here the body just buffers into the sink.
                if (!flow.awaiting_route) self.startAttempt(flow);
            }
        }

        /// Body-complete requests: h1 ingress and bodyless/classic h2.
        /// The body is stolen from the entity into the flow (replay
        /// buffer) — always replayable, whatever its size.
        fn intakeClassic(self: *Self, now_ns: i128) !void {
            const coll = &self.server.request_out;
            const entities = coll.entitySlice();
            const sids = coll.column(h2.StreamId);
            const sessions = coll.column(h2.Session);
            const req_hdrs = coll.column(h2.ReqHeaders);
            const req_bodies = coll.column(h2.ReqBody);
            const flow_refs = coll.column(FlowRef);

            for (entities, sids, sessions, req_hdrs, req_bodies, flow_refs) |ent, sid, sess, rh, *rb, *fr| {
                if (fr.ptr != null) continue;
                const flow = (try self.beginFlow(coll, ent, sid, sess, rh, now_ns, .classic)) orelse continue;
                fr.ptr = @ptrCast(flow);

                // Steal the body: raw component overwrite transfers
                // ownership to the flow (set() does not deinit the old
                // value; the entity now holds the empty body).
                if (rb.data) |d| {
                    flow.body = std.ArrayListUnmanaged(u8){
                        .items = d[0..rb.len],
                        .capacity = rb.len,
                    };
                    flow.body_total = rb.len;
                    rb.data = null;
                    rb.len = 0;
                }
                flow.body_complete = true;
                if (!flow.awaiting_route) self.startAttempt(flow);
            }
        }

        /// Shared intake front half: authority → route → Flow. Returns
        /// null after answering the request directly (4xx/5xx).
        // ── WS tunnels (websocket-plan §8.5) ──────────────────────────

        /// Surfaced h1 Upgrade heads: resolve the route and open the
        /// upstream Extended-CONNECT attempt. The downstream 101 waits
        /// for the upstream 200 (`consumeResponseHeaders`), so a refused
        /// tunnel is a plain HTTP error downstream.
        fn intakeWsUpgrades(self: *Self, now_ns: i128) !void {
            const coll = &self.server.ws_upgrade_out;
            const entities = coll.entitySlice();
            const sids = coll.column(h2.StreamId);
            const sessions = coll.column(h2.Session);
            const req_hdrs = coll.column(h2.ReqHeaders);
            const flow_refs = coll.column(FlowRef);

            for (entities, sids, sessions, req_hdrs, flow_refs) |ent, sid, sess, rh, *fr| {
                _ = sid;
                if (fr.ptr != null) continue; // already tunnel-bound
                if (self.reg.isStale(sess.entity)) {
                    // Downstream died before disposition.
                    try self.reg.destroy(ent);
                    continue;
                }
                const authority_raw = headerValue(rh, ":authority") orelse {
                    self.server.wsUpgradeReject(ent, 400);
                    continue;
                };
                const host = hostOnly(authority_raw);
                const route = self.resolveRoute(host, now_ns);
                switch (route) {
                    .not_found => {
                        self.server.wsUpgradeReject(ent, 404);
                        continue;
                    },
                    .moving => {
                        self.server.wsUpgradeReject(ent, 503);
                        continue;
                    },
                    .nodes => |n| if (n.len == 0) {
                        self.server.wsUpgradeReject(ent, 502);
                        continue;
                    },
                    // Cold route: the resolve is enqueued; park the tunnel
                    // (like a cold Flow) and resume when the answer lands.
                    .pending => {},
                }

                const t = self.allocator.create(WsTunnel) catch {
                    self.server.wsUpgradeReject(ent, 503);
                    continue;
                };
                t.* = .{
                    .proxy = self,
                    .down_conn = sess.entity,
                    .upgrade_ent = ent,
                    .authority = undefined,
                    .host = undefined,
                };
                t.authority = self.allocator.dupe(u8, authority_raw) catch {
                    self.allocator.destroy(t);
                    self.server.wsUpgradeReject(ent, 503);
                    continue;
                };
                t.host = self.allocator.dupe(u8, host) catch {
                    self.allocator.free(t.authority);
                    self.allocator.destroy(t);
                    self.server.wsUpgradeReject(ent, 503);
                    continue;
                };
                switch (route) {
                    .nodes => |n| t.nodes = dupNodes(self.allocator, n) catch {
                        self.allocator.free(t.authority);
                        self.allocator.free(t.host);
                        self.allocator.destroy(t);
                        self.server.wsUpgradeReject(ent, 503);
                        continue;
                    },
                    .pending => {
                        t.awaiting_route = true;
                        t.route_deadline_ns = now_ns + ROUTE_WAIT_NS;
                        self.parkRouteWaiter(host, .{ .tunnel = t }) catch {
                            self.allocator.free(t.authority);
                            self.allocator.free(t.host);
                            self.allocator.destroy(t);
                            self.server.wsUpgradeReject(ent, 503);
                            continue;
                        };
                    },
                    else => unreachable,
                }
                self.live_tunnels += 1;
                fr.ptr = @ptrCast(t);
                fr.tunnel = true;
                if (!t.awaiting_route) self.startTunnelAttempt(t);
            }
        }

        fn startTunnelAttempt(self: *Self, t: *WsTunnel) void {
            t.up_sid = 0;
            t.up_sess = Entity.nil;
            t.chunk_inflight = 0;
            const origin = t.nodes[t.node_idx];
            const up = self.poolEntry(origin) catch {
                self.tunnelAttemptFailed(t);
                return;
            };
            switch (up.state) {
                .up => {
                    if (self.reg.isStale(up.sess)) {
                        up.state = .down;
                        up.sess = Entity.nil;
                        self.connectUpstream(up, .{ .tunnel = t });
                    } else {
                        self.submitTunnel(t, up.sess);
                    }
                },
                .connecting => {
                    up.waiters.append(self.allocator, .{ .tunnel = t }) catch {
                        self.tunnelAttemptFailed(t);
                        return;
                    };
                    t.waiting_conn = true;
                },
                .down => self.connectUpstream(up, .{ .tunnel = t }),
            }
        }

        /// Open the Extended-CONNECT stream on a live pool conn. RFC 8441
        /// requires the peer's ENABLE_CONNECT_PROTOCOL before submitting.
        fn submitTunnel(self: *Self, t: *WsTunnel, sess: Entity) void {
            if (!self.server.connExtendedConnect(sess)) {
                // Live conn, but the peer's ENABLE_CONNECT_PROTOCOL SETTINGS
                // hasn't been seen yet — common on a freshly-`.up` leg whose
                // SETTINGS trails connect-complete. Park and re-check next
                // cycle (serviceTunnelSettingsWaiters) instead of failing;
                // the old immediate give-up surfaced a transient 502 on cold
                // upstream connections.
                t.up_sess = sess;
                t.awaiting_settings = true;
                return;
            }
            const packed_hdrs = self.packTunnelHeaders(t) catch {
                self.tunnelAttemptFailed(t);
                return;
            };
            const pump = self.reg.create(&self.server.client_stream_request_in) catch {
                if (packed_hdrs._buf) |b| self.allocator.free(b[0..packed_hdrs._buf_len]);
                self.tunnelAttemptFailed(t);
                return;
            };
            const coll = &self.server.client_stream_request_in;
            t.attempt += 1;
            self.reg.set(pump, coll, h2.Session, .{ .entity = sess }) catch {};
            self.reg.set(pump, coll, h2.ReqHeaders, packed_hdrs) catch {};
            self.reg.set(pump, coll, h2.ReqBody, .{}) catch {};
            self.reg.set(pump, coll, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.set(pump, coll, h2.StreamId, .{ .id = 0 }) catch {};
            self.reg.set(pump, coll, FlowRef, .{ .ptr = @ptrCast(t), .attempt = t.attempt, .tunnel = true }) catch {};
            t.up_sess = sess;
            t.attempt_live = true;
            t.pending_terminals += 1;
        }

        /// The five RFC 8441 CONNECT headers, one owned buffer.
        fn packTunnelHeaders(self: *Self, t: *WsTunnel) !h2.ReqHeaders {
            const Pair = struct { name: []const u8, value: []const u8 };
            const pairs = [_]Pair{
                .{ .name = ":method", .value = "CONNECT" },
                .{ .name = ":protocol", .value = "websocket" },
                .{ .name = ":scheme", .value = "http" },
                .{ .name = ":authority", .value = t.authority },
                .{ .name = ":path", .value = "/" }, // overwritten below
            };
            // :path comes from the Upgrade head (still on the entity).
            const rh_src = self.reg.get(t.upgrade_ent, &self.server.ws_upgrade_out, h2.ReqHeaders) catch null;
            const path: []const u8 = if (rh_src) |rh| (headerValue(rh.*, ":path") orelse "/") else "/";

            var strbytes: usize = 0;
            for (pairs[0..4]) |p| strbytes += p.name.len + p.value.len;
            strbytes += ":path".len + path.len;

            const n = pairs.len;
            const fields_size = n * @sizeOf(h2.HeaderField);
            const buf = try self.allocator.alloc(u8, fields_size + strbytes);
            errdefer self.allocator.free(buf);
            const fields: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
            const strbase = buf.ptr + fields_size;
            var soff: usize = 0;
            var fi: usize = 0;
            const put = struct {
                fn go(f: [*]h2.HeaderField, sb: [*]u8, off: *usize, idx: *usize, name: []const u8, value: []const u8) void {
                    @memcpy(sb[off.* .. off.* + name.len], name);
                    const noff = off.*;
                    off.* += name.len;
                    @memcpy(sb[off.* .. off.* + value.len], value);
                    const voff = off.*;
                    off.* += value.len;
                    f[idx.*] = .{
                        .name = sb + noff,
                        .name_len = @intCast(name.len),
                        .value = sb + voff,
                        .value_len = @intCast(value.len),
                    };
                    idx.* += 1;
                }
            }.go;
            for (pairs[0..4]) |p| put(fields, strbase, &soff, &fi, p.name, p.value);
            put(fields, strbase, &soff, &fi, ":path", path);
            return .{ .fields = fields, .count = @intCast(n), ._buf = buf.ptr, ._buf_len = @intCast(buf.len) };
        }

        /// Current tunnel attempt failed before the 200: next node or
        /// refuse the downstream Upgrade.
        fn tunnelAttemptFailed(self: *Self, t: *WsTunnel) void {
            self.unmapTunnel(t);
            t.attempt_live = false;
            if (t.down_gone or self.reg.isStale(t.down_conn)) {
                self.finishTunnel(t);
                return;
            }
            if (t.node_idx + 1 < t.nodes.len) {
                t.node_idx += 1;
                self.startTunnelAttempt(t);
                return;
            }
            self.cache.invalidate(t.host);
            self.finishTunnel(t);
        }

        fn unmapTunnel(self: *Self, t: *WsTunnel) void {
            if (!t.up_sess.isNil() and t.up_sid != 0) {
                _ = self.tunnels_by_up.remove(keyOf(t.up_sess, t.up_sid));
            }
        }

        /// Terminal state: nothing more will happen for this tunnel. An
        /// undecided downstream Upgrade is refused here (also destroys
        /// the handle entity when the conn is already dead). Frees once
        /// outstanding terminals + sink refs drain.
        fn finishTunnel(self: *Self, t: *WsTunnel) void {
            if (!t.decided) {
                t.decided = true;
                self.server.wsUpgradeReject(t.upgrade_ent, 502);
            }
            t.done = true;
            self.maybeDestroyTunnel(t);
        }

        fn maybeDestroyTunnel(self: *Self, t: *WsTunnel) void {
            if (!t.done or t.pending_terminals != 0 or t.sink_refs != 0) return;
            self.unmapTunnel(t);
            self.allocator.free(t.authority);
            self.allocator.free(t.host);
            freeNodes(self.allocator, t.nodes);
            t.up_buf.deinit(self.allocator);
            self.live_tunnels -= 1;
            self.allocator.destroy(t);
        }

        /// Terminal failure of a route-parked tunnel: reject the still-held
        /// Upgrade with `code` (retryable), unless the downstream already
        /// died — `finishTunnel` then just reaps the handle. No upstream
        /// attempt was ever started, so there are no terminals to await.
        fn failParkedTunnel(self: *Self, t: *WsTunnel, code: u16) void {
            t.awaiting_route = false;
            if (!t.decided and !t.down_gone and !self.reg.isStale(t.down_conn)) {
                t.decided = true;
                self.server.wsUpgradeReject(t.upgrade_ent, code);
            }
            self.finishTunnel(t);
        }

        // Tunnel sinks. Downstream socket bytes → `up_buf` (pumped as
        // upstream chunks); upstream response bytes → the downstream
        // write queue. Both run on the poll thread.
        fn tunnelOf(ctx: *anyopaque) *WsTunnel {
            return @ptrCast(@alignCast(ctx));
        }
        fn downTunnelPush(ctx: *anyopaque, bytes: []const u8) bool {
            const t = tunnelOf(ctx);
            if (t.done) return false;
            t.up_buf.appendSlice(t.proxy.allocator, bytes) catch return false;
            return true;
        }
        fn downTunnelFinish(_: *anyopaque) void {}
        fn downTunnelAbort(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            t.down_gone = true;
        }
        fn downTunnelDrained(ctx: *anyopaque) u32 {
            const t = tunnelOf(ctx);
            const d = t.down_drained;
            t.down_drained = 0;
            return d;
        }
        fn downTunnelRelease(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            t.down_gone = true;
            t.sink_refs -|= 1;
            t.proxy.maybeDestroyTunnel(t);
        }
        fn downTunnelSinkOf(t: *WsTunnel) h2.BodySink {
            return .{
                .ctx = @ptrCast(t),
                .push = &downTunnelPush,
                .finish = &downTunnelFinish,
                .abort = &downTunnelAbort,
                .drained = &downTunnelDrained,
                .release = &downTunnelRelease,
            };
        }
        fn upTunnelPush(ctx: *anyopaque, bytes: []const u8) bool {
            const t = tunnelOf(ctx);
            if (t.down_gone or t.proxy.reg.isStale(t.down_conn)) return false;
            t.proxy.server.wsTunnelWrite(t.down_conn, bytes);
            t.up_drained +%= @intCast(bytes.len);
            return true;
        }
        fn upTunnelFinish(ctx: *anyopaque) void {
            // Upstream ended cleanly (worker sent Close + END): close
            // the downstream socket once its queue drains.
            const t = tunnelOf(ctx);
            t.proxy.server.wsTunnelClose(t.down_conn);
        }
        fn upTunnelAbort(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            if (!t.down_gone and !t.proxy.reg.isStale(t.down_conn)) {
                t.proxy.reg.destroy(t.down_conn) catch {};
            }
        }
        fn upTunnelDrained(ctx: *anyopaque) u32 {
            const t = tunnelOf(ctx);
            const d = t.up_drained;
            t.up_drained = 0;
            return d;
        }
        fn upTunnelRelease(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            t.sink_refs -|= 1;
            t.proxy.maybeDestroyTunnel(t);
        }
        fn upTunnelSinkOf(t: *WsTunnel) h2.BodySink {
            return .{
                .ctx = @ptrCast(t),
                .push = &upTunnelPush,
                .finish = &upTunnelFinish,
                .abort = &upTunnelAbort,
                .drained = &upTunnelDrained,
                .release = &upTunnelRelease,
            };
        }

        fn beginFlow(
            self: *Self,
            coll: anytype,
            ent: Entity,
            sid: h2.StreamId,
            sess: h2.Session,
            rh: h2.ReqHeaders,
            now_ns: i128,
            home: DownHome,
        ) !?*Flow {
            const authority_raw = headerValue(rh, ":authority") orelse headerValue(rh, "host") orelse {
                try self.replyStatus(coll, ent, sid, sess, 400);
                return null;
            };
            const host = hostOnly(authority_raw);

            const route = self.resolveRoute(host, now_ns);
            switch (route) {
                .not_found => {
                    std.log.warn("front: no placement for host {s} → 404", .{host});
                    try self.replyStatus(coll, ent, sid, sess, 404);
                    return null;
                },
                // Mid-move: hold the tenant's traffic with a retryable
                // 503 until the directory flip completes.
                .moving => {
                    try self.replyStatus(coll, ent, sid, sess, 503);
                    return null;
                },
                .nodes => |n| if (n.len == 0) {
                    try self.replyStatus(coll, ent, sid, sess, 502);
                    return null;
                },
                .pending => {}, // park below — resolve already enqueued
            }

            const flow = try self.allocator.create(Flow);
            errdefer self.allocator.destroy(flow);
            flow.* = .{
                .proxy = self,
                .authority = try self.allocator.dupe(u8, authority_raw),
                .host = undefined,
                .down_ent = ent,
                .down_sess = sess.entity,
                .down_sid = sid.id,
                .down_home = home,
            };
            flow.host = self.allocator.dupe(u8, host) catch |e| {
                self.allocator.free(flow.authority);
                return e;
            };
            switch (route) {
                .nodes => |n| {
                    flow.nodes = dupNodes(self.allocator, n) catch |e| {
                        self.allocator.free(flow.authority);
                        self.allocator.free(flow.host);
                        return e;
                    };
                    // Start at the cached leader (if any) — skip the scan.
                    flow.node_idx = self.leaders.startIdx(flow.host, flow.nodes);
                },
                .pending => {
                    // Cold host: park (body still buffers via the sink)
                    // until the resolve lands or the deadline fires.
                    flow.awaiting_route = true;
                    flow.route_deadline_ns = now_ns + ROUTE_WAIT_NS;
                    self.parkRouteWaiter(flow.host, .{ .flow = flow }) catch |e| {
                        self.allocator.free(flow.authority);
                        self.allocator.free(flow.host);
                        return e;
                    };
                },
                else => unreachable,
            }
            self.live_flows += 1;
            return flow;
        }

        // ── Upstream attempts ─────────────────────────────────────────

        /// Begin (or re-begin, on retry) the upstream attempt against
        /// `nodes[node_idx]`: resolve the pooled connection and submit,
        /// or park the flow on the pending connect.
        fn startAttempt(self: *Self, flow: *Flow) void {
            if (flow.down_gone) {
                self.teardownFlow(flow);
                return;
            }
            flow.sent = flow.body_base; // replay from the buffer start
            flow.up_closed = false;
            flow.up_sid = 0;
            flow.up_sess = Entity.nil;
            flow.up_chunk_inflight = 0;

            const origin = flow.nodes[flow.node_idx];
            const up = self.poolEntry(origin) catch {
                self.attemptFailed(flow, false);
                return;
            };
            switch (up.state) {
                .up => {
                    if (self.reg.isStale(up.sess)) {
                        // Idle-reaped (or died quietly). Reconnect.
                        up.state = .down;
                        up.sess = Entity.nil;
                        self.connectUpstream(up, .{ .flow = flow });
                    } else {
                        self.submitAttempt(flow, up.sess);
                    }
                },
                .connecting => {
                    up.waiters.append(self.allocator, .{ .flow = flow }) catch {
                        self.attemptFailed(flow, false);
                        return;
                    };
                    flow.waiting_conn = true;
                },
                .down => self.connectUpstream(up, .{ .flow = flow }),
            }
        }

        fn poolEntry(self: *Self, origin: []const u8) !*Upstream {
            if (self.pool.get(origin)) |up| return up;
            const up = try self.allocator.create(Upstream);
            errdefer self.allocator.destroy(up);
            up.* = .{ .origin = try self.allocator.dupe(u8, origin) };
            try self.pool.put(self.allocator, up.origin, up);
            return up;
        }

        /// Kick off (or join) a connect to a down upstream. Inside the
        /// backoff window the attempt fails over immediately instead
        /// of hammering a dead node.
        fn connectUpstream(self: *Self, up: *Upstream, waiter: Waiter) void {
            const now = std.time.nanoTimestamp();
            if (up.state == .down and now - up.last_fail_ns < CONNECT_BACKOFF_NS) {
                self.waiterFailed(waiter);
                return;
            }
            const addr = up.addr orelse blk: {
                const a = resolveOrigin(up.origin) catch {
                    up.last_fail_ns = now;
                    self.waiterFailed(waiter);
                    return;
                };
                up.addr = a;
                break :blk a;
            };

            const ce = self.reg.create(&self.server.client_connect_in) catch {
                self.waiterFailed(waiter);
                return;
            };
            self.reg.set(ce, &self.server.client_connect_in, h2.ConnectTarget, .{ .addr = addr }) catch {};
            self.reg.set(ce, &self.server.client_connect_in, h2.Session, .{}) catch {};
            self.reg.set(ce, &self.server.client_connect_in, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.set(ce, &self.server.client_connect_in, FlowRef, .{ .ptr = @ptrCast(up) }) catch {};

            up.state = .connecting;
            up.waiters.append(self.allocator, waiter) catch {
                // The connect proceeds (other waiters may join); this
                // one fails over.
                self.waiterFailed(waiter);
                return;
            };
            switch (waiter) {
                .flow => |f| f.waiting_conn = true,
                .tunnel => |t| t.waiting_conn = true,
            }
        }

        fn waiterFailed(self: *Self, waiter: Waiter) void {
            switch (waiter) {
                .flow => |f| self.attemptFailed(f, false),
                .tunnel => |t| self.tunnelAttemptFailed(t),
            }
        }

        /// Submit the current attempt's request head on `sess` via the
        /// streaming client leg. The body (whatever its state) follows
        /// through `pumpUpstream`.
        fn submitAttempt(self: *Self, flow: *Flow, sess: Entity) void {
            const rh = self.reg.get(flow.down_ent, self.downColl(flow), h2.ReqHeaders) catch {
                self.teardownFlow(flow);
                return;
            };
            const packed_hdrs = self.packUpstreamHeaders(rh.*, flow.authority) catch {
                self.attemptFailed(flow, false);
                return;
            };

            const pump = self.reg.create(&self.server.client_stream_request_in) catch {
                if (packed_hdrs._buf) |b| self.allocator.free(b[0..packed_hdrs._buf_len]);
                self.attemptFailed(flow, false);
                return;
            };
            const coll = &self.server.client_stream_request_in;
            flow.attempt += 1;
            self.reg.set(pump, coll, h2.Session, .{ .entity = sess }) catch {};
            self.reg.set(pump, coll, h2.ReqHeaders, packed_hdrs) catch {};
            // A bodyless request (GET/HEAD/DELETE — body complete with zero
            // bytes) must carry END_STREAM on its upstream HEADERS: a proxy
            // preserves END_STREAM position. Left open, the worker's
            // headers-first disposition sees a phantom inbound body and a
            // GET to an `onHeaders` module mis-dispatches to `onHeaders`
            // instead of the default export. Non-empty bodies keep the
            // streamed pump (chunks + close) — they ARE body-carrying.
            const bodyless = flow.body_complete and flow.body_total == 0;
            self.reg.set(pump, coll, h2.ReqBody, .{ .complete = bodyless }) catch {};
            self.reg.set(pump, coll, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.set(pump, coll, h2.StreamId, .{ .id = 0 }) catch {};
            self.reg.set(pump, coll, FlowRef, .{ .ptr = @ptrCast(flow), .attempt = flow.attempt }) catch {};
            if (bodyless) flow.up_closed = true;

            flow.up_sess = sess;
            flow.attempt_live = true;
            flow.pending_terminals += 1;
        }

        /// The current attempt failed before any response. Re-aim or
        /// give up.
        fn attemptFailed(self: *Self, flow: *Flow, conn_died: bool) void {
            self.unmapAttempt(flow);
            flow.attempt_live = false;
            if (flow.down_gone or !flow.down_alive) {
                self.teardownFlow(flow);
                return;
            }
            if (conn_died and flow.reconnect_budget > 0 and flow.canRetry()) {
                flow.reconnect_budget -= 1;
                self.startAttempt(flow); // same node, fresh conn
                return;
            }
            if (flow.canRetry() and flow.node_idx + 1 < flow.nodes.len) {
                // A node we routed to is down. If it was the cached leader
                // (we start there), drop the hint so we re-learn instead of
                // dialing the dead node on every future request.
                if (conn_died) self.leaders.drop(self.allocator, flow.host);
                flow.node_idx += 1;
                self.startAttempt(flow);
                return;
            }
            // All nodes unreachable → 502; the cached cluster is likely
            // stale (moved/evicted) — drop it so the next request
            // re-resolves against the CP.
            self.cache.invalidate(flow.host);
            self.finishWithStatus(flow, 502);
        }

        /// 421 not-leader from the current node: retry-safe by contract
        /// (nothing entered the log). Re-aim while the body is
        /// replayable; otherwise (or when nodes are exhausted —
        /// mid-election) surface a plain retryable 503 rather than the
        /// internal re-aim status.
        fn handle421(self: *Self, flow: *Flow) void {
            // Remember we were redirected: a later 2xx in this flow is
            // then provably from the leader (see `noteLeader`).
            flow.saw_421 = true;
            // Re-aim is rare once the leader cache is warm — it signals a
            // leadership change (or a cold/first request), so info-level is
            // the right volume, not per-request noise.
            std.log.info("front: 421 re-aim host={s} off node={s}", .{
                flow.host, flow.nodes[flow.node_idx],
            });
            self.abandonAttempt(flow);
            if (flow.canRetry() and flow.node_idx + 1 < flow.nodes.len) {
                flow.node_idx += 1;
                self.startAttempt(flow);
                return;
            }
            self.finishWithStatus(flow, 503);
        }

        /// Abandon the in-flight attempt (RST upstream so the worker
        /// never half-sees the rest of the body).
        fn abandonAttempt(self: *Self, flow: *Flow) void {
            if (flow.attempt_live and !flow.up_sess.isNil() and flow.up_sid != 0) {
                self.server.clientStreamReset(flow.up_sess, flow.up_sid);
            }
            self.unmapAttempt(flow);
            flow.attempt_live = false;
        }

        fn unmapAttempt(self: *Self, flow: *Flow) void {
            if (!flow.up_sess.isNil() and flow.up_sid != 0) {
                _ = self.flows_by_up.remove(keyOf(flow.up_sess, flow.up_sid));
            }
        }

        // ── Connect results ───────────────────────────────────────────

        fn consumeConnects(self: *Self, now_ns: i128) !void {
            {
                const coll = &self.server.client_connect_out;
                const entities = coll.entitySlice();
                const sessions = coll.column(h2.Session);
                const flow_refs = coll.column(FlowRef);
                for (entities, sessions, flow_refs) |ent, sess, fr| {
                    if (fr.ptr) |p| {
                        const up: *Upstream = @ptrCast(@alignCast(p));
                        up.state = .up;
                        up.sess = sess.entity;
                        self.drainWaiters(up, true);
                    }
                    try self.reg.destroy(ent);
                }
            }
            {
                const coll = &self.server.client_connect_errors;
                const entities = coll.entitySlice();
                const flow_refs = coll.column(FlowRef);
                for (entities, flow_refs) |ent, fr| {
                    if (fr.ptr) |p| {
                        const up: *Upstream = @ptrCast(@alignCast(p));
                        up.state = .down;
                        up.sess = Entity.nil;
                        up.last_fail_ns = now_ns;
                        std.log.warn("front: connect to {s} failed", .{up.origin});
                        self.drainWaiters(up, false);
                    }
                    try self.reg.destroy(ent);
                }
            }
        }

        fn drainWaiters(self: *Self, up: *Upstream, ok: bool) void {
            // Take the list — submit/fail paths may re-append to it.
            var waiters = up.waiters;
            up.waiters = .empty;
            defer waiters.deinit(self.allocator);
            for (waiters.items) |w| switch (w) {
                .flow => |flow| {
                    flow.waiting_conn = false;
                    if (flow.down_gone or !flow.down_alive) {
                        self.teardownFlow(flow);
                    } else if (ok) {
                        self.submitAttempt(flow, up.sess);
                    } else {
                        self.attemptFailed(flow, false);
                    }
                },
                .tunnel => |t| {
                    t.waiting_conn = false;
                    if (t.down_gone or self.reg.isStale(t.down_conn)) {
                        self.finishTunnel(t);
                    } else if (ok) {
                        self.submitTunnel(t, up.sess);
                    } else {
                        self.tunnelAttemptFailed(t);
                    }
                },
            };
        }

        // ── Response relay ────────────────────────────────────────────

        /// Streaming response heads (client_headers_first early emit).
        fn consumeResponseHeaders(self: *Self) !void {
            const coll = &self.server.client_response_receiving;
            const entities = coll.entitySlice();
            const sids = coll.column(h2.StreamId);
            const sessions = coll.column(h2.Session);
            const statuses = coll.column(h2.Status);
            const resp_hdrs = coll.column(h2.RespHeaders);

            for (entities, sids, sessions, statuses, resp_hdrs) |ent, sid, sess, status, rh| {
                defer self.reg.destroy(ent) catch {};
                // WS tunnel CONNECT responses first — an unmapped stream
                // is reset below, which must never hit a live tunnel.
                if (self.tunnels_by_up.get(keyOf(sess.entity, sid.id))) |t| {
                    self.tunnelResponse(t, sess.entity, sid.id, status.code);
                    continue;
                }
                const flow = self.flows_by_up.get(keyOf(sess.entity, sid.id)) orelse {
                    // Response on a stream we no longer track (abandoned
                    // attempt that raced our RST). Make sure it dies.
                    self.server.clientStreamReset(sess.entity, sid.id);
                    continue;
                };
                if (!flow.down_alive or flow.down_gone) {
                    self.abandonAttempt(flow);
                    self.teardownFlow(flow);
                    continue;
                }
                if (status.code == 421) {
                    self.handle421(flow);
                    continue;
                }
                // Relay the head downstream and switch the flow to
                // streaming-response mode.
                const packed_hdrs = self.packDownstreamHeaders(rh) catch {
                    self.abandonAttempt(flow);
                    self.finishWithStatus(flow, 502);
                    continue;
                };
                // A 2xx (any non-421 served head) after a 421 in this flow
                // is provably from the leader — cache it for next time.
                if (flow.saw_421) self.leaders.note(self.allocator, flow.host, flow.nodes[flow.node_idx]);
                self.relayHead(flow, status.code, packed_hdrs);
                flow.resp_streaming = true;

                switch (self.server.requestBodySink(sess.entity, sid.id, respSinkOf(flow))) {
                    .streaming, .eof => {
                        flow.resp_sink_live = true;
                        flow.sink_refs += 1;
                    },
                    .gone => {
                        // The stream already CLOSED — a fast response
                        // arrives and closes within one poll. h2 handed
                        // the buffered body tail to the request entity;
                        // the terminal `client_response_out` event
                        // delivers it (or the error).
                    },
                }
            }
        }

        /// An early-emitted response on a tunnel's CONNECT stream. 200 =
        /// tunnel accepted: send the deferred downstream 101 and wire
        /// both relay sinks. Anything else = refused mid-handshake.
        fn tunnelResponse(self: *Self, t: *WsTunnel, up_sess: Entity, up_sid: u32, code: u16) void {
            if (code != 200 or t.down_gone or self.reg.isStale(t.down_conn)) {
                self.server.clientStreamReset(up_sess, up_sid);
                self.tunnelAttemptFailed(t);
                return;
            }
            t.decided = true;
            switch (self.server.wsUpgradeAccept(t.upgrade_ent, downTunnelSinkOf(t))) {
                .ok => {
                    t.accepted = true;
                    t.sink_refs += 1;
                },
                .gone => {
                    // Downstream died between intake and the 200.
                    self.server.clientStreamReset(up_sess, up_sid);
                    self.finishTunnel(t);
                    return;
                },
            }
            switch (self.server.requestBodySink(up_sess, up_sid, upTunnelSinkOf(t))) {
                .streaming, .eof => t.sink_refs += 1,
                .gone => {
                    // Upstream stream already dead; terminal will land.
                    self.server.wsTunnelClose(t.down_conn);
                },
            }
        }

        /// Move the downstream entity into the streaming-response
        /// pipeline with the relayed status + headers.
        fn relayHead(self: *Self, flow: *Flow, code: u16, packed_hdrs: h2.RespHeaders) void {
            const src = self.downColl(flow);
            self.reg.set(flow.down_ent, src, h2.Status, .{ .code = code }) catch {};
            self.reg.set(flow.down_ent, src, h2.RespHeaders, packed_hdrs) catch {};
            self.reg.set(flow.down_ent, src, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.move(flow.down_ent, src, &self.server.stream_response_in) catch {};
            flow.down_home = .responding;
            flow.resp_started = true;
        }

        /// Upstream pump: feed request-body chunks / close, account
        /// drained chunks, register fresh attempts' stream ids.
        fn pumpUpstream(self: *Self) !void {
            const coll = &self.server.client_stream_data_out;
            const entities = coll.entitySlice();
            const sids = coll.column(h2.StreamId);
            const sessions = coll.column(h2.Session);
            const flow_refs = coll.column(FlowRef);

            for (entities, sids, sessions, flow_refs) |ent, sid, sess, fr| {
                const p = fr.ptr orelse continue;
                // WS tunnel pump: register the stream id, repay the
                // downstream read window for drained chunks, relay the
                // next slice of downstream bytes upstream.
                if (fr.tunnel) {
                    const t: *WsTunnel = @ptrCast(@alignCast(p));
                    if (fr.attempt != t.attempt) continue;
                    if (t.up_sid == 0) {
                        t.up_sid = sid.id;
                        t.up_sess = sess.entity;
                        self.tunnels_by_up.put(self.allocator, keyOf(sess.entity, sid.id), t) catch {};
                    }
                    if (t.chunk_inflight > 0) {
                        t.down_drained +|= t.chunk_inflight;
                        t.chunk_inflight = 0;
                    }
                    if (t.down_gone or self.reg.isStale(t.down_conn)) {
                        // Downstream socket died — no clean WS Close
                        // exists; reset so the worker sees disconnect.
                        self.server.clientStreamReset(sess.entity, sid.id);
                        continue;
                    }
                    if (t.up_buf.items.len > 0) {
                        const n: u32 = @intCast(@min(t.up_buf.items.len, CHUNK_MAX));
                        const chunk = self.allocator.alloc(u8, n) catch continue;
                        @memcpy(chunk, t.up_buf.items[0..n]);
                        const leftover = t.up_buf.items.len - n;
                        if (leftover > 0) std.mem.copyForwards(u8, t.up_buf.items[0..leftover], t.up_buf.items[n..]);
                        t.up_buf.shrinkRetainingCapacity(leftover);
                        self.reg.set(ent, coll, h2.ReqBody, .{ .data = chunk.ptr, .len = n }) catch {};
                        self.reg.move(ent, coll, &self.server.client_stream_data_in) catch {};
                        t.chunk_inflight = n;
                    }
                    continue;
                }
                const flow: *Flow = @ptrCast(@alignCast(p));
                if (fr.attempt != flow.attempt) continue; // abandoned; close cb will reap it

                if (flow.up_sid == 0) {
                    flow.up_sid = sid.id;
                    self.flows_by_up.put(self.allocator, keyOf(sess.entity, sid.id), flow) catch {};
                }
                // The previous chunk has fully drained into nghttp2's
                // frames — repay the downstream window.
                if (flow.up_chunk_inflight > 0) {
                    flow.down_drained +|= flow.up_chunk_inflight;
                    flow.up_chunk_inflight = 0;
                }
                if (flow.down_gone and !flow.body_complete) {
                    // Downstream died mid-upload: never half-close —
                    // reset so the worker sees a broken stream, not a
                    // truncated-but-complete body.
                    self.server.clientStreamReset(sess.entity, sid.id);
                    continue;
                }

                const avail = flow.bodyAvail();
                if (avail > 0) {
                    const off = flow.sent - flow.body_base;
                    const n: u32 = @intCast(@min(avail, CHUNK_MAX));
                    const chunk = self.allocator.alloc(u8, n) catch continue;
                    @memcpy(chunk, flow.body.items[off .. off + n]);
                    self.reg.set(ent, coll, h2.ReqBody, .{ .data = chunk.ptr, .len = n }) catch {};
                    self.reg.move(ent, coll, &self.server.client_stream_data_in) catch {};
                    flow.sent += n;
                    flow.up_chunk_inflight = n;
                    if (!flow.replayable) self.compactBody(flow);
                } else if (flow.body_complete and !flow.up_closed) {
                    self.reg.move(ent, coll, &self.server.client_stream_close_in) catch {};
                    flow.up_closed = true;
                }
                // else: nothing to send yet — the entity waits here.
            }
        }

        /// Downstream pump: feed response chunks / close / abort.
        fn pumpDownstream(self: *Self) !void {
            const coll = &self.server.stream_data_out;
            const entities = coll.entitySlice();
            const flow_refs = coll.column(FlowRef);

            for (entities, flow_refs) |ent, fr| {
                const p = fr.ptr orelse continue;
                const flow: *Flow = @ptrCast(@alignCast(p));
                if (flow.down_closed) continue;

                if (flow.down_chunk_inflight > 0) {
                    flow.resp_drained +|= flow.down_chunk_inflight;
                    flow.down_chunk_inflight = 0;
                }

                if (flow.resp_queue.items.len > 0) {
                    const n: u32 = @intCast(@min(flow.resp_queue.items.len, CHUNK_MAX));
                    const chunk = self.allocator.alloc(u8, n) catch continue;
                    @memcpy(chunk, flow.resp_queue.items[0..n]);
                    const rem = flow.resp_queue.items.len - n;
                    std.mem.copyForwards(u8, flow.resp_queue.items[0..rem], flow.resp_queue.items[n..]);
                    flow.resp_queue.shrinkRetainingCapacity(rem);
                    self.reg.set(ent, coll, h2.RespBody, .{ .data = chunk.ptr, .len = n }) catch {};
                    self.reg.move(ent, coll, &self.server.stream_data_in) catch {};
                    flow.down_chunk_inflight = n;
                } else if (flow.resp_failed) {
                    // Upstream died mid-response: hard-abort downstream
                    // (RST / connection close), never a clean EOF on a
                    // truncated body.
                    self.server.serverStreamAbort(flow.down_sess, flow.down_sid);
                    flow.down_closed = true;
                } else if (flow.resp_eof) {
                    self.reg.move(ent, coll, &self.server.stream_close_in) catch {};
                    flow.down_closed = true;
                }
            }
        }

        /// Terminal events for upstream request entities.
        fn consumeUpstreamTerminal(self: *Self) !void {
            const coll = &self.server.client_response_out;
            const entities = coll.entitySlice();
            const sids = coll.column(h2.StreamId);
            const statuses = coll.column(h2.Status);
            const resp_hdrs = coll.column(h2.RespHeaders);
            const resp_bodies = coll.column(h2.RespBody);
            const io_results = coll.column(h2.H2IoResult);
            const flow_refs = coll.column(FlowRef);

            for (entities, sids, statuses, resp_hdrs, resp_bodies, io_results, flow_refs) |ent, sid, status, rh, *rb, io_res, fr| {
                defer self.reg.destroy(ent) catch {};
                _ = sid;
                const p = fr.ptr orelse continue;
                // WS tunnel terminal: the CONNECT stream ended.
                if (fr.tunnel) {
                    const t: *WsTunnel = @ptrCast(@alignCast(p));
                    t.pending_terminals -|= 1;
                    if (fr.attempt != t.attempt) {
                        self.maybeDestroyTunnel(t);
                        continue;
                    }
                    self.unmapTunnel(t);
                    t.attempt_live = false;
                    if (t.accepted) {
                        // Live tunnel over (worker side ended / died):
                        // close the downstream socket once it drains.
                        // The sinks already saw finish/abort.
                        self.server.wsTunnelClose(t.down_conn);
                        self.finishTunnel(t);
                        continue;
                    }
                    // Refused before any 200 (worker 421/transport
                    // error): the rejected-CONNECT response rides this
                    // terminal. 421 / conn death → re-aim at the next
                    // node; anything else refuses the Upgrade.
                    const conn_died = io_res.err != 0 and self.reg.isStale(t.up_sess);
                    if (status.code == 421 or io_res.err != 0) {
                        if (conn_died) {
                            if (self.pool.get(t.nodes[t.node_idx])) |up| {
                                if (up.state == .up and self.reg.isStale(up.sess)) {
                                    up.state = .down;
                                    up.sess = Entity.nil;
                                    up.last_fail_ns = 0;
                                }
                            }
                        }
                        self.tunnelAttemptFailed(t);
                        continue;
                    }
                    if (!t.decided) {
                        t.decided = true;
                        self.server.wsUpgradeReject(t.upgrade_ent, if (status.code != 0) status.code else 502);
                    }
                    self.finishTunnel(t);
                    continue;
                }
                const flow: *Flow = @ptrCast(@alignCast(p));
                flow.pending_terminals -|= 1;
                if (fr.attempt != flow.attempt) {
                    // A previously-abandoned attempt finishing its
                    // close. Nothing to do beyond the count.
                    self.maybeDestroyFlow(flow);
                    continue;
                }
                self.unmapAttempt(flow);
                flow.attempt_live = false;

                if (flow.resp_streaming) {
                    if (!flow.resp_sink_live) {
                        // Sink never attached (the stream closed in the
                        // same poll the response arrived — see
                        // consumeResponseHeaders). The body tail rides
                        // this terminal entity.
                        if (rb.data) |d| {
                            if (rb.len > 0)
                                flow.resp_queue.appendSlice(self.allocator, d[0..rb.len]) catch {};
                        }
                        if (io_res.err == 0) {
                            flow.resp_eof = true;
                        } else {
                            flow.resp_failed = true;
                        }
                    }
                    // Otherwise the sink relayed (or is relaying) the
                    // body; a mid-relay error already fired its abort.
                    self.maybeDestroyFlow(flow);
                    continue;
                }
                if (!flow.down_alive or flow.down_gone) {
                    self.teardownFlow(flow);
                    continue;
                }

                if (io_res.err == 0 and status.code != 0) {
                    // Complete buffered response (END_STREAM at/near
                    // HEADERS — no early emit happened).
                    if (status.code == 421) {
                        self.handle421(flow);
                        continue;
                    }
                    // A non-421 buffered response after a 421 in this flow
                    // is provably from the leader — cache it for next time.
                    if (flow.saw_421) self.leaders.note(self.allocator, flow.host, flow.nodes[flow.node_idx]);
                    const packed_hdrs = self.packDownstreamHeaders(rh) catch h2.RespHeaders{ .fields = null, .count = 0 };
                    // Steal the body for the downstream entity (raw
                    // overwrite; allocators match).
                    const body: h2.RespBody = .{ .data = rb.data, .len = rb.len };
                    rb.data = null;
                    rb.len = 0;
                    self.respondFull(flow, status.code, packed_hdrs, body);
                    continue;
                }

                // Transport/stream error with no usable response.
                const conn_died = self.reg.isStale(flow.up_sess);
                if (conn_died) self.markDown(flow);
                std.log.warn("front: forward {s} → {s} failed", .{ flow.host, flow.nodes[flow.node_idx] });
                self.attemptFailed(flow, conn_died);
            }
        }

        fn markDown(self: *Self, flow: *Flow) void {
            if (self.pool.get(flow.nodes[flow.node_idx])) |up| {
                if (up.state == .up and self.reg.isStale(up.sess)) {
                    up.state = .down;
                    up.sess = Entity.nil;
                    up.last_fail_ns = 0; // a reap is not a failure — no backoff
                }
            }
        }

        /// Terminal events for downstream entities (response written or
        /// stream dead). Detach + destroy.
        fn consumeServerTerminal(self: *Self) !void {
            const coll = &self.server.response_out;
            const entities = coll.entitySlice();
            const flow_refs = coll.column(FlowRef);

            for (entities, flow_refs) |ent, fr| {
                if (fr.ptr) |p| {
                    const flow: *Flow = @ptrCast(@alignCast(p));
                    if (flow.down_ent.index == ent.index and flow.down_ent.generation == ent.generation) {
                        flow.down_alive = false;
                        flow.detached = true;
                        if (flow.attempt_live) self.abandonAttempt(flow);
                        self.maybeDestroyFlow(flow);
                    }
                }
                try self.reg.destroy(ent);
            }
        }

        // ── Direct replies / flow termination ─────────────────────────

        fn replyStatus(self: *Self, coll: anytype, ent: Entity, sid: h2.StreamId, sess: h2.Session, code: u16) !void {
            try self.reg.set(ent, coll, h2.Status, .{ .code = code });
            try self.reg.set(ent, coll, h2.RespHeaders, .{ .fields = null, .count = 0 });
            try self.reg.set(ent, coll, h2.RespBody, .{ .data = null, .len = 0 });
            try self.reg.set(ent, coll, h2.H2IoResult, .{ .err = 0 });
            try self.reg.set(ent, coll, h2.StreamId, sid);
            try self.reg.set(ent, coll, h2.Session, sess);
            try self.reg.move(ent, coll, &self.server.response_in);
        }

        /// Answer the flow's downstream request with a buffered
        /// response (ownership of headers + body transfers to the
        /// entity). h2's consumeResponses flips a still-inbound request
        /// body to discard.
        fn respondFull(self: *Self, flow: *Flow, code: u16, packed_hdrs: h2.RespHeaders, body: h2.RespBody) void {
            const src = self.downColl(flow);
            self.reg.set(flow.down_ent, src, h2.Status, .{ .code = code }) catch {};
            self.reg.set(flow.down_ent, src, h2.RespHeaders, packed_hdrs) catch {};
            self.reg.set(flow.down_ent, src, h2.RespBody, body) catch {};
            self.reg.set(flow.down_ent, src, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.move(flow.down_ent, src, &self.server.response_in) catch {};
            flow.down_home = .responding;
            flow.resp_started = true;
        }

        fn finishWithStatus(self: *Self, flow: *Flow, code: u16) void {
            if (flow.down_alive and !flow.resp_started) {
                self.respondFull(flow, code, .{ .fields = null, .count = 0 }, .{ .data = null, .len = 0 });
            }
            self.maybeDestroyFlow(flow);
        }

        /// Hard teardown: downstream is gone (or was never answerable).
        /// Abort whatever upstream attempt is in flight; the downstream
        /// entity (if any) flows out via the orphan sweep / terminal.
        fn teardownFlow(self: *Self, flow: *Flow) void {
            if (flow.attempt_live) self.abandonAttempt(flow);
            self.maybeDestroyFlow(flow);
        }

        fn downColl(self: *Self, flow: *Flow) *@TypeOf(self.server.request_out) {
            return switch (flow.down_home) {
                .receiving => &self.server.request_receiving,
                .classic, .responding => &self.server.request_out, // .responding never used as a source
            };
        }

        fn maybeDestroyFlow(self: *Self, flow: *Flow) void {
            // STRICTLY gated on detach: until the downstream entity is
            // reaped from response_out, its FlowRef points here.
            if (!flow.detached) return;
            if (flow.attempt_live or flow.waiting_conn or flow.awaiting_route) return;
            if (flow.sink_refs != 0 or flow.pending_terminals != 0) return;
            self.unmapAttempt(flow);
            flow.body.deinit(self.allocator);
            flow.resp_queue.deinit(self.allocator);
            // A parked flow torn down before its route landed never got
            // a heap node list — its `.nodes` is still the empty default
            // (`&.{}`), which must not be passed to free.
            if (flow.nodes.len != 0) freeNodes(self.allocator, flow.nodes);
            self.allocator.free(flow.authority);
            self.allocator.free(flow.host);
            self.allocator.destroy(flow);
            self.live_flows -= 1;
        }

        fn compactBody(self: *Self, flow: *Flow) void {
            _ = self;
            const consumed = flow.sent - flow.body_base;
            if (consumed == 0) return;
            const rem = flow.body.items.len - consumed;
            std.mem.copyForwards(u8, flow.body.items[0..rem], flow.body.items[consumed..]);
            flow.body.shrinkRetainingCapacity(rem);
            flow.body_base += consumed;
        }

        // ── Body sinks ────────────────────────────────────────────────
        //
        // Callbacks run on the poll thread, inside h2's poll phases.
        // They only touch Flow fields / buffers — registry mutations
        // happen in the proxy's own phases.

        fn downSinkOf(flow: *Flow) h2.BodySink {
            return .{
                .ctx = @ptrCast(flow),
                .push = downSinkPush,
                .finish = downSinkFinish,
                .abort = downSinkAbort,
                .drained = downSinkDrained,
                .release = sinkRelease,
            };
        }

        fn respSinkOf(flow: *Flow) h2.BodySink {
            return .{
                .ctx = @ptrCast(flow),
                .push = respSinkPush,
                .finish = respSinkFinish,
                .abort = respSinkAbort,
                .drained = respSinkDrained,
                .release = sinkRelease,
            };
        }

        fn flowOf(ctx: *anyopaque) *Flow {
            return @ptrCast(@alignCast(ctx));
        }

        fn downSinkPush(ctx: *anyopaque, bytes: []const u8) bool {
            const flow = flowOf(ctx);
            if (flow.down_gone) return false;
            flow.body.appendSlice(flow.proxy.allocator, bytes) catch return false;
            flow.body_total += bytes.len;
            if (flow.replayable and !flow.body_complete and flow.body.items.len > REPLAY_CAP) {
                flow.replayable = false;
            }
            return true;
        }

        fn downSinkFinish(ctx: *anyopaque) void {
            flowOf(ctx).body_complete = true;
        }

        fn downSinkAbort(ctx: *anyopaque) void {
            flowOf(ctx).down_gone = true;
        }

        fn downSinkDrained(ctx: *anyopaque) u32 {
            const flow = flowOf(ctx);
            const d = flow.down_drained;
            flow.down_drained = 0;
            return d;
        }

        fn respSinkPush(ctx: *anyopaque, bytes: []const u8) bool {
            const flow = flowOf(ctx);
            // Downstream is gone → returning false RSTs the upstream
            // stream, which is exactly the cancel we want.
            if (flow.down_gone or !flow.down_alive or flow.down_closed) return false;
            flow.resp_queue.appendSlice(flow.proxy.allocator, bytes) catch return false;
            return true;
        }

        fn respSinkFinish(ctx: *anyopaque) void {
            flowOf(ctx).resp_eof = true;
        }

        fn respSinkAbort(ctx: *anyopaque) void {
            const flow = flowOf(ctx);
            if (!flow.resp_eof) flow.resp_failed = true;
        }

        fn respSinkDrained(ctx: *anyopaque) u32 {
            const flow = flowOf(ctx);
            const d = flow.resp_drained;
            flow.resp_drained = 0;
            return d;
        }

        fn sinkRelease(ctx: *anyopaque) void {
            const flow = flowOf(ctx);
            flow.sink_refs -= 1;
            // Release fires from sweepBodySinks / h2 teardown (inside
            // poll) — maybeDestroyFlow touches only proxy-owned state
            // and the flows_by_up map, no registry mutation, so this
            // is safe here.
            flow.proxy.maybeDestroyFlow(flow);
        }

        // ── Header packing ────────────────────────────────────────────

        const PackedFields = struct {
            fields: ?[*]h2.HeaderField,
            count: u32,
            buf: ?[*]u8,
            buf_len: u32,
        };

        const NameValue = struct { name: []const u8, value: []const u8 };

        fn packFields(a: std.mem.Allocator, list: []const NameValue) !PackedFields {
            if (list.len == 0) return .{ .fields = null, .count = 0, .buf = null, .buf_len = 0 };
            const HF = h2.HeaderField;
            var strbytes: usize = 0;
            for (list) |nv| strbytes += nv.name.len + nv.value.len;
            const fields_size = list.len * @sizeOf(HF);
            const total = fields_size + strbytes;
            const buf = try a.alloc(u8, total);
            const fields: [*]HF = @ptrCast(@alignCast(buf.ptr));
            const sb = buf.ptr + fields_size;
            var off: usize = 0;
            for (list, 0..) |nv, i| {
                const noff = off;
                @memcpy(sb[noff .. noff + nv.name.len], nv.name);
                // HTTP/2 requires lowercase field names (h1 ingress may
                // carry mixed case).
                for (sb[noff .. noff + nv.name.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
                off += nv.name.len;
                const voff = off;
                @memcpy(sb[voff .. voff + nv.value.len], nv.value);
                off += nv.value.len;
                fields[i] = .{
                    .name = sb + noff,
                    .name_len = @intCast(nv.name.len),
                    .value = sb + voff,
                    .value_len = @intCast(nv.value.len),
                };
            }
            return .{ .fields = fields, .count = @intCast(list.len), .buf = buf.ptr, .buf_len = @intCast(total) };
        }

        /// Build the upstream request head: pseudo-headers first
        /// (nghttp2 requires it), then the filtered originals.
        fn packUpstreamHeaders(self: *Self, rh: h2.ReqHeaders, authority: []const u8) !h2.ReqHeaders {
            const a = self.allocator;
            var list: std.ArrayListUnmanaged(NameValue) = .empty;
            defer list.deinit(a);

            const method = headerValue(rh, ":method") orelse "GET";
            const path = headerValue(rh, ":path") orelse "/";
            try list.append(a, .{ .name = ":method", .value = method });
            try list.append(a, .{ .name = ":scheme", .value = "http" });
            try list.append(a, .{ .name = ":path", .value = path });
            try list.append(a, .{ .name = ":authority", .value = authority });

            if (rh.fields) |fields| {
                var i: u32 = 0;
                while (i < rh.count) : (i += 1) {
                    const f = fields[i];
                    const fname = f.name[0..f.name_len];
                    if (fname.len > 0 and fname[0] == ':') continue;
                    if (dropFromRequest(fname)) continue;
                    try list.append(a, .{ .name = fname, .value = f.value[0..f.value_len] });
                }
            }
            const p = try packFields(a, list.items);
            return .{ .fields = p.fields, .count = p.count, ._buf = p.buf, ._buf_len = p.buf_len };
        }

        /// Repack a backend response's headers for the downstream
        /// reply (filtered; owned by the downstream entity).
        fn packDownstreamHeaders(self: *Self, rh: h2.RespHeaders) !h2.RespHeaders {
            const a = self.allocator;
            var list: std.ArrayListUnmanaged(NameValue) = .empty;
            defer list.deinit(a);
            if (rh.fields) |fields| {
                var i: u32 = 0;
                while (i < rh.count) : (i += 1) {
                    const f = fields[i];
                    const fname = f.name[0..f.name_len];
                    if (dropFromResponse(fname)) continue;
                    try list.append(a, .{ .name = fname, .value = f.value[0..f.value_len] });
                }
            }
            const p = try packFields(a, list.items);
            return .{ .fields = p.fields, .count = p.count, ._buf = p.buf, ._buf_len = p.buf_len };
        }

        // ── Route resolution (off-loop; never blocks) ─────────────────

        /// Non-blocking. A fresh cache hit returns nodes inline; a miss
        /// (no entry or past TTL) enqueues an off-loop resolve and
        /// returns `.pending` for the caller to park on. The CP is never
        /// contacted on this thread, and a stale entry is never served
        /// (so a tenant move re-resolves correctly past the TTL).
        fn resolveRoute(self: *Self, host: []const u8, now_ns: i128) RouteResult {
            if (self.cache.get(host, now_ns)) |nodes| return .{ .nodes = nodes };
            self.enqueueResolve(host);
            return .pending;
        }

        /// Enqueue an off-loop CP resolve for `host`, deduped: at most
        /// one in-flight resolve per host even if N requests for a cold
        /// host arrive in the same cycle.
        fn enqueueResolve(self: *Self, host: []const u8) void {
            if (self.route_pending.contains(host)) return;
            const key = self.allocator.dupe(u8, host) catch return; // best-effort
            self.route_pending.put(self.allocator, key, {}) catch {
                self.allocator.free(key);
                return;
            };
            self.resolver.enqueue(host) catch {
                // Couldn't enqueue — re-arm so a later request retries.
                if (self.route_pending.fetchRemove(host)) |kv| self.allocator.free(kv.key);
            };
        }

        /// Park a flow awaiting a cold route. Mirrors `up.waiters`, but
        /// keyed by host. The bucket key is an owned dupe (separate from
        /// `flow.host`), freed when the bucket is resumed/failed.
        fn parkRouteWaiter(self: *Self, host: []const u8, waiter: Waiter) !void {
            const gop = try self.route_waiters.getOrPut(self.allocator, host);
            if (!gop.found_existing) {
                gop.key_ptr.* = self.allocator.dupe(u8, host) catch |e| {
                    self.route_waiters.removeByPtr(gop.key_ptr);
                    return e;
                };
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(self.allocator, waiter);
        }

        /// Drain off-loop resolutions: update the cache and resume (or
        /// fail) the flows parked on each host. Runs first in `run()`.
        fn drainRouteCompletions(self: *Self, now_ns: i128) !void {
            var completions = self.resolver.takeCompletions();
            defer completions.deinit(self.allocator);
            for (completions.items) |c| {
                // Re-arm dedupe so future refreshes can enqueue again.
                if (self.route_pending.fetchRemove(c.host)) |kv| self.allocator.free(kv.key);
                switch (c.outcome) {
                    .placed => |nodes| {
                        // Resume from the freshly-resolved nodes directly
                        // (NOT via cache.get — a TTL of 0 would read the
                        // just-stored entry as already expired). putOwned
                        // takes ownership after; the waiters dup their own.
                        self.resumeRouteWaiters(c.host, nodes);
                        self.cache.putOwned(c.host, nodes, now_ns) catch {
                            freeNodes(self.allocator, nodes);
                        };
                    },
                    // Move in progress / gone: stop serving the stale
                    // entry and surface a retryable 503 / 404.
                    .moving => {
                        self.cache.invalidate(c.host);
                        self.failRouteWaiters(c.host, 503);
                    },
                    .not_found => {
                        self.cache.invalidate(c.host);
                        self.failRouteWaiters(c.host, 404);
                    },
                    // Transient CP failure: don't touch the cache (a
                    // fresh entry, if any, keeps serving other requests);
                    // the cold parked flows get a retryable 503.
                    .err => self.failRouteWaiters(c.host, 503),
                }
                self.allocator.free(c.host);
            }
        }

        fn resumeRouteWaiters(self: *Self, host: []const u8, nodes: []const []const u8) void {
            const kv = self.route_waiters.fetchRemove(host) orelse return;
            var list = kv.value;
            self.allocator.free(kv.key);
            defer list.deinit(self.allocator);
            for (list.items) |w| switch (w) {
                .flow => |flow| {
                    flow.awaiting_route = false;
                    if (flow.down_gone or !flow.down_alive) {
                        self.teardownFlow(flow);
                        continue;
                    }
                    if (nodes.len == 0) {
                        self.finishWithStatus(flow, 502);
                        continue;
                    }
                    flow.nodes = dupNodes(self.allocator, nodes) catch {
                        self.finishWithStatus(flow, 503);
                        continue;
                    };
                    // Start at the cached leader (if any) — skip the scan.
                    flow.node_idx = self.leaders.startIdx(flow.host, flow.nodes);
                    self.startAttempt(flow);
                },
                .tunnel => |t| {
                    t.awaiting_route = false;
                    if (t.down_gone or self.reg.isStale(t.down_conn)) {
                        self.finishTunnel(t);
                        continue;
                    }
                    if (nodes.len == 0) {
                        self.failParkedTunnel(t, 502);
                        continue;
                    }
                    t.nodes = dupNodes(self.allocator, nodes) catch {
                        self.failParkedTunnel(t, 503);
                        continue;
                    };
                    self.startTunnelAttempt(t);
                },
            };
        }

        fn failRouteWaiters(self: *Self, host: []const u8, code: u16) void {
            const kv = self.route_waiters.fetchRemove(host) orelse return;
            var list = kv.value;
            self.allocator.free(kv.key);
            defer list.deinit(self.allocator);
            for (list.items) |w| switch (w) {
                .flow => |flow| {
                    flow.awaiting_route = false;
                    if (flow.down_gone or !flow.down_alive) {
                        self.teardownFlow(flow);
                    } else {
                        self.finishWithStatus(flow, code);
                    }
                },
                .tunnel => |t| self.failParkedTunnel(t, code),
            };
        }

        /// Resume (or expire) WS tunnels parked in `submitTunnel` waiting for
        /// their upstream conn's `ENABLE_CONNECT_PROTOCOL` SETTINGS. A parked
        /// tunnel is referenced only by its still-undecided `ws_upgrade_out`
        /// entity's FlowRef (no CONNECT stream opened yet), so sweep that
        /// collection. Submit once the bit shows up; re-aim if the conn died;
        /// give up past `SETTINGS_WAIT_NS` (a genuinely non-RFC-8441 upstream).
        fn serviceTunnelSettingsWaiters(self: *Self, now_ns: i128) void {
            const coll = &self.server.ws_upgrade_out;
            const flow_refs = coll.column(FlowRef);
            for (flow_refs) |fr| {
                if (!fr.tunnel) continue;
                const p = fr.ptr orelse continue;
                const t: *WsTunnel = @ptrCast(@alignCast(p));
                if (!t.awaiting_settings) continue;
                if (t.down_gone or self.reg.isStale(t.down_conn)) {
                    t.awaiting_settings = false;
                    self.finishTunnel(t);
                    continue;
                }
                if (self.reg.isStale(t.up_sess)) {
                    // Pool conn died while we waited — re-aim (next node).
                    t.awaiting_settings = false;
                    t.settings_deadline_ns = 0;
                    self.tunnelAttemptFailed(t);
                    continue;
                }
                if (self.server.connExtendedConnect(t.up_sess)) {
                    t.awaiting_settings = false;
                    t.settings_deadline_ns = 0;
                    self.submitTunnel(t, t.up_sess);
                    continue;
                }
                if (t.settings_deadline_ns == 0) {
                    t.settings_deadline_ns = now_ns + SETTINGS_WAIT_NS;
                } else if (now_ns >= t.settings_deadline_ns) {
                    std.log.warn("front: {s} never advertised extended-connect — failing WS tunnel", .{t.nodes[t.node_idx]});
                    t.awaiting_settings = false;
                    t.settings_deadline_ns = 0;
                    self.tunnelAttemptFailed(t);
                }
            }
        }

        /// 503 any flow whose cold-route park outlived `ROUTE_WAIT_NS`.
        /// Emptied buckets are left in place — they're reclaimed when
        /// the still-in-flight resolve for that host completes (its
        /// `route_pending` entry guarantees it will).
        fn expireParkedRoutes(self: *Self, now_ns: i128) void {
            var it = self.route_waiters.iterator();
            while (it.next()) |e| {
                const list = e.value_ptr;
                var i: usize = 0;
                while (i < list.items.len) {
                    const w = list.items[i];
                    const deadline = switch (w) {
                        .flow => |flow| flow.route_deadline_ns,
                        .tunnel => |t| t.route_deadline_ns,
                    };
                    if (now_ns >= deadline) {
                        _ = list.swapRemove(i);
                        switch (w) {
                            .flow => |flow| {
                                flow.awaiting_route = false;
                                if (flow.down_gone or !flow.down_alive) {
                                    self.teardownFlow(flow);
                                } else {
                                    self.finishWithStatus(flow, 503);
                                }
                            },
                            .tunnel => |t| self.failParkedTunnel(t, 503),
                        }
                    } else {
                        i += 1;
                    }
                }
            }
        }

        /// 504 any flow whose request was fully forwarded upstream but
        /// that has gone `RESPONSE_WAIT_NS` with no response headers — a
        /// stuck stream that otherwise hangs the client until the h2 idle
        /// GC (or forever, if the connection never goes idle). Gated on
        /// `body_complete` so a slow upload in progress isn't mistaken for
        /// a stall, and on `!resp_started` so a streaming response isn't
        /// cut off. `abandonAttempt` mutates `flows_by_up`, so collect the
        /// stalled flows first, then act.
        fn expireStalledResponses(self: *Self, now_ns: i128) void {
            var stalled: [32]*Flow = undefined;
            var n: usize = 0;
            var it = self.flows_by_up.valueIterator();
            while (it.next()) |fp| {
                const flow = fp.*;
                if (flow.resp_started or !flow.body_complete) continue;
                if (flow.response_deadline_ns == 0) {
                    flow.response_deadline_ns = now_ns + RESPONSE_WAIT_NS;
                    continue;
                }
                if (now_ns >= flow.response_deadline_ns) {
                    stalled[n] = flow;
                    n += 1;
                    if (n == stalled.len) break;
                }
            }
            for (stalled[0..n]) |flow| {
                std.log.warn("front: upstream response timeout (host={s}) -> 504", .{flow.host});
                self.abandonAttempt(flow); // RST_STREAM to the stuck upstream
                self.finishWithStatus(flow, 504); // 504 to the client + teardown
            }
        }
    };
}

/// Parse a node origin (`http://host:port`) into a socket address.
/// IP literals resolve directly; hostnames go through the blocking
/// resolver (private-network names; resolved once per pool entry).
/// Parse a node origin (`http://host:port`) into a socket address.
/// Origins MUST be IP literals — production uses vRack private IPs
/// (REWIND_CLUSTERS). A hostname is REJECTED, not resolved:
/// `std.net.getAddressList` is a blocking DNS call and this runs on the
/// :443 poll loop, which must never block (a slow resolver would stall
/// accept/TLS for every tenant). A hostname origin is a config error —
/// fail loud + fast (the caller fails the connect over) instead.
fn resolveOrigin(origin: []const u8) !std.net.Address {
    var rest = origin;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    var host: []const u8 = rest;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
        host = rest[0..i];
        port = try std.fmt.parseInt(u16, rest[i + 1 ..], 10);
    }
    return std.net.Address.parseIp(host, port) catch {
        std.log.err(
            "front: origin {s} is not an IP literal — hostname origins are unsupported (would block the poll loop on DNS); set IP-literal origins in REWIND_CLUSTERS",
            .{origin},
        );
        return error.HostnameOriginUnsupported;
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "RouteCache: fresh hit within TTL, miss past it (re-resolve, no stale serve)" {
    const ttl_ns: i128 = 100;
    var cache = RouteCache.init(testing.allocator, ttl_ns);
    defer cache.deinit();

    const nodes = try dupNodes(testing.allocator, &.{ "http://a:1", "http://b:1" });
    try cache.putOwned("acme.example", nodes, 1000); // expires at 1100

    // Within TTL: hit.
    try testing.expectEqual(@as(usize, 2), cache.get("acme.example", 1050).?.len);
    // At/after expiry: miss → caller parks + re-resolves (never serves
    // the stale entry, so a move past the TTL routes correctly).
    try testing.expect(cache.get("acme.example", 1100) == null);
    try testing.expect(cache.get("acme.example", 1200) == null);
    // Unknown host: miss.
    try testing.expect(cache.get("nope.example", 1050) == null);
}

test "RouteCache: putOwned refreshes the entry in place and frees the old nodes" {
    var cache = RouteCache.init(testing.allocator, 100);
    defer cache.deinit();

    try cache.putOwned("h", try dupNodes(testing.allocator, &.{"http://old:1"}), 1000);
    // Re-store with a new list; the old one must be freed (testing
    // allocator catches a leak) and the expiry pushed out.
    try cache.putOwned("h", try dupNodes(testing.allocator, &.{ "http://new:1", "http://new:2" }), 1200);
    try testing.expectEqual(@as(usize, 2), cache.get("h", 1250).?.len);

    cache.invalidate("h");
    try testing.expect(cache.get("h", 1250) == null);
}

test "LeaderCache: note seeds the start index; stale origin falls back to 0" {
    const a = testing.allocator;
    var lc: LeaderCache = .{};
    defer lc.deinit(a);

    const nodes = &[_][]const u8{ "http://n1:1", "http://n2:1", "http://n3:1" };

    // Cold: no hint → start at 0 (the front then scans + learns).
    try testing.expectEqual(@as(usize, 0), lc.startIdx("acme", nodes));

    // Learn the leader is n3 → subsequent requests start at index 2 directly
    // (no redirect scan — the tax is gone).
    lc.note(a, "acme", "http://n3:1");
    try testing.expectEqual(@as(usize, 2), lc.startIdx("acme", nodes));

    // A different host is independent.
    lc.note(a, "beta", "http://n2:1");
    try testing.expectEqual(@as(usize, 1), lc.startIdx("beta", nodes));

    // Stale hint after a move/membership change: the cached origin is no
    // longer in `nodes` → fall back to 0 so the next 421 re-learns.
    const moved_nodes = &[_][]const u8{ "http://m1:1", "http://m2:1" };
    try testing.expectEqual(@as(usize, 0), lc.startIdx("acme", moved_nodes));
}

test "LeaderCache: note replaces in place (no leak); drop forgets" {
    const a = testing.allocator;
    var lc: LeaderCache = .{};
    defer lc.deinit(a);

    const nodes = &[_][]const u8{ "http://n1:1", "http://n2:1", "http://n3:1" };

    lc.note(a, "acme", "http://n1:1");
    // Re-note with a new leader (leadership changed): the old value must be
    // freed in place (testing allocator catches a leak) and the index move.
    lc.note(a, "acme", "http://n3:1");
    try testing.expectEqual(@as(usize, 2), lc.startIdx("acme", nodes));
    // Idempotent re-note of the same value is a no-op.
    lc.note(a, "acme", "http://n3:1");
    try testing.expectEqual(@as(usize, 2), lc.startIdx("acme", nodes));

    // drop forgets → back to a cold start.
    lc.drop(a, "acme");
    try testing.expectEqual(@as(usize, 0), lc.startIdx("acme", nodes));
    // drop of an absent host is a harmless no-op.
    lc.drop(a, "acme");
}
