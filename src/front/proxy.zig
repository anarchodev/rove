//! Streaming reverse-proxy core for rewind-front.
//!
//! Forwards each proxied request over same-poll-loop rove-h2 CLIENT
//! legs: one pooled h2c connection per backend node, every proxied
//! request a multiplexed stream on it. Nothing blocks; bodies stream
//! both ways with end-to-end backpressure:
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
//! curl is used ONLY for control-plane lookups (`/_cp/route`; cert +
//! ACME fetches stay in main.zig) — cached, small, off the data path.
//!
//! ## Retry semantics
//!
//! 421 not-leader is retry-safe by contract (nothing entered the raft
//! log). A streaming front can only retry what it can REPLAY — it does
//! not hold the whole body. Every flow keeps
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
//! conn (architecture/websockets.md) — `WsTunnel` pairs the raw-relay
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
    /// pump/terminal entities — architecture/websockets.md).
    tunnel: bool = false,
    /// The upstream Leg this pump entity was submitted on (plan A3) —
    /// its in-flight count is repaid when the terminal lands. Legs
    /// live inside process-lifetime pool entries, so a late terminal
    /// for an abandoned attempt still points at valid memory.
    leg: ?*anyopaque = null,
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

/// Latency histogram bucket bounds (ms) for `front_request_duration_ms`
/// (plan C11). Fixed comptime bounds — no allocation on the record path.
pub const LAT_BOUNDS_MS = [_]u64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 10000 };

/// Reconnect backoff for a backend node whose connect failed.
pub const CONNECT_BACKOFF_NS: i128 = 500 * std.time.ns_per_ms;

/// Upstream connection pool sizing (plan A3). One pooled h2c conn per
/// backend node meant one TCP congestion window head-of-line-blocking
/// every tenant's traffic to that node, one conn death failing all
/// in-flight requests at once, and past the peer's
/// max_concurrent_streams nghttp2 queued submissions invisibly with no
/// depth bound. Now each node gets up to `REWIND_FRONT_UPSTREAM_CONNS`
/// legs (default 2, max 4): submits pick the least-loaded live leg, a
/// spare leg is dialed in the background once the chosen leg is busy,
/// and when every leg is saturated the request is SHED with a
/// retryable 503 (nothing was submitted) instead of queueing
/// invisibly.
pub const MAX_LEGS: usize = 4;
/// Per-leg in-flight stream cap — below the worker's
/// max_concurrent_streams (512) so nghttp2 never locally queues.
pub const LEG_STREAM_CAP: u32 = 480;
/// Chosen-leg in-flight count at which a spare down leg is dialed in
/// the background (gradual scale-out under load).
pub const LEG_GROW_THRESHOLD: u32 = 64;

/// Default between-bytes progress budget for an INBOUND request body
/// (`REWIND_FRONT_BODY_STALL_TIMEOUT_MS`) — nginx's
/// `client_body_timeout`. A client that starts a body and stops sending
/// holds a front flow and a worker stream indefinitely: the per-CONN
/// idle reap never fires as long as any one stream (or a PING) keeps
/// the connection active, so per-stream progress is the only honest
/// signal (plan A5). Between-bytes, not total: legitimate slow uploads
/// survive as long as bytes keep arriving. Response-side progress is
/// deliberately NOT policed at the front — a quiet held SSE stream is
/// indistinguishable from a stall here, and held-connection deadlines
/// are the worker's (see the plan doc).
const BODY_STALL_NS_DEFAULT: i128 = 60_000 * std.time.ns_per_ms;

/// Default deadline for an upstream connect to complete (overridable
/// via `REWIND_FRONT_CONNECT_TIMEOUT_MS`). The io layer puts no
/// timeout on the connect op, so a backend that blackholes SYNs (node
/// down hard, partition, firewall drop) otherwise hangs every flow
/// aimed at it for the kernel SYN-retry budget (~2 min) — no proxy
/// deadline covered the waiting-on-connect window (plan A1). Backends
/// are same-DC private-plane peers; 1 s is generous.
const CONNECT_TIMEOUT_NS_DEFAULT: i128 = 1000 * std.time.ns_per_ms;

/// How long a request parks waiting for a cold route resolution before
/// it gives up with a retryable 503. Bounds the worst case for a
/// never-seen host when the CP is slow/down (a slow resolve must never
/// freeze the whole loop for the libcurl timeout).
const ROUTE_WAIT_NS: i128 = 2500 * std.time.ns_per_ms;

/// A flow whose request is fully sent upstream but that produces no
/// response headers within this window is treated as a stuck stream: the
/// upstream stream is RST and the client gets a 504, rather than hanging
/// until the h2 idle GC (or forever, if the connection never goes idle —
/// see the front-door TTFB investigation). Set well above the worker
/// handler budget (<=10s) so slow-but-valid handlers aren't killed; this
/// only bounds the genuinely-stuck case.
const RESPONSE_WAIT_NS: i128 = 30_000 * std.time.ns_per_ms;

/// How long a live upstream conn may carry tunnels waiting for its peer to
/// advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL` before they give up
/// (re-aim/502). The bit normally lands within one RTT of connect-complete;
/// this only bounds a genuinely non-RFC-8441 upstream (our h2c worker always
/// advertises, so in practice it never fires).
pub const SETTLE_WAIT_NS: i128 = 2000 * std.time.ns_per_ms;

// ── Small shared helpers ──────────────────────────────────────────────

pub const headerValue = util.headerValue;
pub const respHeaderValue = util.respHeaderValue;

/// Map the worker's `x-rewind-leader` raft id to a serving origin in `nodes`.
/// The cluster node list is ordered by raft node id (the `REWIND_CLUSTERS` /
/// voter-set contract: `nodes[i]` is raft node `i+1`, the same ordering the
/// move/attach fan-out relies on), so leader id `L` → `nodes[L-1]`. Returns
/// null for a missing/unparseable header or an id outside `1..nodes.len`
/// (then the caller forgets its stale hint and re-scans, rather than trusting
/// a bad map).
fn leaderOriginHint(rh: h2.RespHeaders, nodes: []const []const u8) ?[]const u8 {
    const v = respHeaderValue(rh, "x-rewind-leader") orelse return null;
    const id = std.fmt.parseInt(u64, v, 10) catch return null;
    if (id == 0 or id > nodes.len) return null;
    return nodes[id - 1];
}

/// Methods a proxy may re-send after an ambiguous transport failure
/// (request head handed to an upstream that died without responding —
/// the worker may have executed the handler). Deliberately narrower
/// than RFC 9110 §9.2.2: PUT/DELETE are formally idempotent, but a
/// rewind handler's method semantics are customer code, so only the
/// safe (read-shaped) methods get the benefit of the doubt. nginx's
/// `proxy_next_upstream` draws the same line via `non_idempotent`.
pub fn isIdempotentMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "GET") or
        std.mem.eql(u8, method, "HEAD") or
        std.mem.eql(u8, method, "OPTIONS");
}

/// Strip a `:port` suffix from an `:authority` / Host value. Bracketed
/// IPv6 literals (`[::1]`, `[::1]:443`) keep their brackets — the old
/// bare `lastIndexOfScalar(':')` split a portless `[::1]` mid-address.
pub fn hostOnly(authority: []const u8) []const u8 {
    if (authority.len > 0 and authority[0] == '[') {
        if (std.mem.indexOfScalar(u8, authority, ']')) |i| return authority[0 .. i + 1];
        return authority; // malformed — normalizeHost's charset gate owns rejection
    }
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |i| return authority[0..i];
    return authority;
}

/// Normalize a client-supplied `:authority` / Host into the canonical
/// routing key (plan B9): port stripped (bracket-aware), LOWERCASED
/// (DNS names are case-insensitive — un-normalized, `HOST.example` and
/// `host.example` were distinct cache entries and distinct CP
/// round-trips, and deliberate case-flipping bypassed the route
/// cache), and charset-restricted so raw client bytes never reach
/// cache keys, the `/_cp/route?host=` query string, or log lines.
/// Null = junk; the caller answers 400. `buf` holds the lowered copy.
pub fn normalizeHost(buf: *[255]u8, authority: []const u8) ?[]const u8 {
    const raw = hostOnly(authority);
    if (raw.len == 0 or raw.len > buf.len) return null;
    for (raw, 0..) |ch, i| {
        const low = std.ascii.toLower(ch);
        const ok = (low >= 'a' and low <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '.' or ch == '-' or ch == '_' or ch == ':' or ch == '[' or ch == ']';
        if (!ok) return null;
        buf[i] = low;
    }
    return buf[0..raw.len];
}

/// hop-by-hop headers must not be forwarded across a proxy (RFC 7230
/// §6.1). `expect` rides along: the front does not implement
/// 100-continue relaying and the worker's h2 server ignores it. The
/// forwarding-identity headers (`x-forwarded-*`, `x-real-ip`,
/// `forwarded`) are stripped because the front IS the trust boundary
/// (plan B7): it terminates the public edge, so any inbound value is
/// client-spoofed — the front re-stamps `x-forwarded-for` /
/// `x-forwarded-proto` from the connection. (If an LB/CDN is ever put
/// in front of the front, this needs a trusted-hops config instead.)
fn dropFromRequest(name: []const u8) bool {
    const hop = [_][]const u8{
        "connection",          "keep-alive",      "proxy-authenticate",
        "proxy-authorization", "te",              "trailer",
        "transfer-encoding",   "upgrade",         "expect",
        "host",                "x-forwarded-for", "x-forwarded-proto",
        "x-forwarded-host",    "x-real-ip",       "forwarded",
    };
    for (hop) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

/// RFC 7230 §6.1: a proxy MUST also remove any header NAMED in the
/// `Connection` header value (h1 ingress; h2 forbids the header but a
/// synthesized h1 head carries it through). Forwarding
/// connection-nominated headers is the mechanism behind published
/// request-smuggling / cache-poisoning classes (plan B8).
fn nominatedByConnection(connection_value: ?[]const u8, name: []const u8) bool {
    const cv = connection_value orelse return false;
    var it = std.mem.tokenizeAny(u8, cv, ", \t");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, name)) return true;
    }
    return false;
}

/// Render `addr`'s bare IP (no port, no IPv6 brackets — the
/// conventional `x-forwarded-for` form) into `buf`; returns the
/// length, 0 on failure/overflow.
fn peerIpString(buf: []u8, addr: std.net.Address) u8 {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{f}", .{addr}) catch return 0;
    var ip = s;
    if (std.mem.lastIndexOfScalar(u8, ip, ':')) |i| ip = ip[0..i];
    if (ip.len >= 2 and ip[0] == '[' and ip[ip.len - 1] == ']') ip = ip[1 .. ip.len - 1];
    if (ip.len == 0 or ip.len > buf.len) return 0;
    @memcpy(buf[0..ip.len], ip);
    return @intCast(ip.len);
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

const pool = @import("proxy/pool.zig");
const util = @import("proxy/util.zig");
const ws_tunnel = @import("proxy/ws_tunnel.zig");
const route_cache = @import("proxy/route_cache.zig");
const dupNodes = route_cache.dupNodes;
const freeNodes = route_cache.freeNodes;
pub const RouteCache = route_cache.RouteCache;
const LeaderCache = route_cache.LeaderCache;
const RouteResult = route_cache.RouteResult;

// Chain the `proxy/` split files' inline tests into the front-test artifact
// (main.zig references proxy.zig, which references these).
test {
    _ = pool;
    _ = util;
    _ = ws_tunnel;
    _ = route_cache;
}

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
        /// Connect verdicts the pool drained from `up.waiters` this turn,
        /// awaiting resume by `dispatchWaiterOutcomes`. Buffered (not
        /// dispatched inline) so `drainWaiters` stays free of the request
        /// state machines.
        waiter_outcomes: std.ArrayListUnmanaged(WaiterOutcome) = .empty,
        /// Live-flow count (operator visibility / leak canary).
        live_flows: usize = 0,
        live_tunnels: usize = 0,
        /// Upstream connect deadline (`REWIND_FRONT_CONNECT_TIMEOUT_MS`;
        /// main.zig overrides after init).
        connect_timeout_ns: i128 = CONNECT_TIMEOUT_NS_DEFAULT,
        /// Inbound request-body between-bytes budget
        /// (`REWIND_FRONT_BODY_STALL_TIMEOUT_MS`; 0 disables).
        body_stall_ns: i128 = BODY_STALL_NS_DEFAULT,
        /// Upstream legs per backend node (`REWIND_FRONT_UPSTREAM_CONNS`,
        /// clamped 1..MAX_LEGS). Applied at pool-entry creation.
        legs_per_node: u8 = 2,
        /// Per-leg in-flight stream cap
        /// (`REWIND_FRONT_UPSTREAM_STREAM_CAP`; see LEG_STREAM_CAP).
        leg_stream_cap: u32 = LEG_STREAM_CAP,

        // ── Observability (plan C11) ──────────────────────────────────
        /// One `front-access:` log line per completed flow
        /// (`REWIND_FRONT_ACCESS_LOG=0` disables).
        access_log: bool = true,
        /// 421 not-leader re-aims (leadership churn / cold leader cache).
        count_reaims_421: u64 = 0,
        /// Upstream connects that blew their deadline (plan A1).
        count_connect_timeouts: u64 = 0,
        /// Upstream connect failures (refused/unreachable).
        count_conn_failures: u64 = 0,
        /// 504s from the response-headers deadline.
        count_resp_timeouts: u64 = 0,
        /// Aborts from the inbound body-stall budget (plan A5).
        count_body_stalls: u64 = 0,
        /// CP route answers: not_found (negative-cached) / transient error.
        count_route_not_found: u64 = 0,
        count_route_errors: u64 = 0,
        /// Flows 503'd out of a cold-route park past ROUTE_WAIT.
        count_route_expired: u64 = 0,
        /// Non-idempotent flows 502'd at the ambiguous-transport-error
        /// gate instead of replayed (plan A2).
        count_ambiguous_502: u64 = 0,
        /// Requests shed 503 because every upstream leg was saturated
        /// (plan A3) — saturation surfaced as a shed rather than an
        /// invisible queue.
        count_upstream_sheds: u64 = 0,
        /// Requests 429'd at the per-client-IP flow cap (plan C13).
        count_client_limited: u64 = 0,
        /// Per-client-IP live flow/tunnel cap
        /// (`REWIND_FRONT_MAX_FLOWS_PER_IP`; 0 = off, the default —
        /// this is an abuse-response knob: legitimate NAT/corp egress
        /// can fan many users out of one address, so the operator
        /// picks the ceiling). Requires the B7 peer capture; a conn
        /// whose peer install hasn't landed yet is not counted.
        max_flows_per_ip: u32 = 0,
        /// peer IP → live flows+tunnels. Keys owned; entries removed
        /// at zero, so the map is bounded by concurrent client IPs.
        flows_by_peer: std.StringHashMapUnmanaged(u32) = .empty,
        /// Request-duration histogram (intake → flow teardown).
        lat_counts: [LAT_BOUNDS_MS.len + 1]u64 = @splat(0),
        lat_sum_ms: u64 = 0,
        lat_total: u64 = 0,

        const StreamKey = struct {
            idx: u32,
            gen: u32,
            sid: u32,
        };

        pub fn keyOf(sess: Entity, sid: u32) StreamKey {
            return .{ .idx = sess.index, .gen = sess.generation, .sid = sid };
        }

        // ── Upstream pool ─────────────────────────────────────────────

        // Upstream connection pool types + methods live in `proxy/pool.zig`
        // (the pool half of the front request path). They are methods on
        // this same `Proxy(FrontH2)` via `pool.Fns`, re-exported below; the
        // pool treats a parked request as an opaque `Waiter` and never names
        // Flow/WsTunnel — the one-way request->pool edge
        // (docs/architecture/routing-and-ingress.md).
        const Waiter = pool.Waiter;
        const WaiterOutcome = pool.WaiterOutcome;
        const Leg = pool.Leg;
        const Upstream = pool.Upstream;

        /// One WS tunnel: a downstream h1 Upgrade paired with an upstream
        /// Extended-CONNECT stream on the pooled h2c conn
        /// (architecture/websockets.md). The front never parses frames — bytes relay verbatim in
        /// both directions; the worker unmasks. Freed when `done` with no
        /// outstanding terminals or sink refs.
        pub const WsTunnel = struct {
            proxy: *Self,
            down_conn: Entity,
            /// The `ws_upgrade_out` handle; valid until `decided`
            /// (wsUpgradeAccept / wsUpgradeReject consume it).
            upgrade_ent: Entity,
            authority: []u8, // owned
            host: []u8, // owned
            /// Forwarding identity (plan B7) — see `Flow.peer_ip`. WS
            /// upgrades are h1 at the edge; TLS-ness rides `fwd_proto`.
            peer_ip: [46]u8 = undefined,
            peer_ip_len: u8 = 0,
            fwd_proto: []const u8 = "http",
            nodes: [][]u8 = &.{},
            node_idx: usize = 0,
            attempt: u32 = 0,
            /// Parked in `route_waiters` awaiting a cold-route resolve — no
            /// upstream attempt started yet (mirrors `Flow.awaiting_route`).
            /// WS has no body to buffer; the downstream socket just waits.
            awaiting_route: bool = false,
            route_deadline_ns: i128 = 0,
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

            // Observability (plan C11): captured at intake, emitted as
            // one access-log line + histogram sample at teardown.
            t_start_ns: i128 = 0,
            method: [8]u8 = undefined, // truncated copy; enough for OPTIONS
            method_len: u8 = 0,
            path: []u8 = &.{}, // owned dupe; empty on alloc failure
            final_status: u16 = 0,
            resp_bytes: u64 = 0,

            // Forwarding identity (plan B7), captured at intake from the
            // downstream connection; stamped upstream on every attempt.
            peer_ip: [46]u8 = undefined, // bare IP, no port/brackets
            peer_ip_len: u8 = 0,
            /// Downstream `:scheme` — "https" when the front terminated
            /// TLS (static strings only; never a borrowed slice).
            fwd_proto: []const u8 = "http",
            /// The appended `Via` entry (RFC 7230 §5.7.1), versioned by
            /// the received protocol.
            via_entry: []const u8 = "2 rewind-front",

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
            /// Monotonic stamp of the last inbound body byte (or sink
            /// attach). 0 = not armed (classic/bodyless flows). Swept
            /// by `expireStalledBodies`.
            last_body_progress_ns: i128 = 0,
            replayable: bool = true,
            /// The request method is safe to re-send after an AMBIGUOUS
            /// transport failure (upstream died after the head was
            /// submitted, before any response). GET/HEAD/OPTIONS only —
            /// rewind handlers make PUT/DELETE semantics customer-defined,
            /// so they don't get the RFC 9110 idempotency benefit of the
            /// doubt. 421 re-aim is NOT gated on this: a 421 proves
            /// nothing executed (decisions.md §10.5).
            idempotent: bool = false,
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

        /// Observability: total in-flight upstream streams summed across
        /// every pooled leg, the live leg count, and the largest single-leg
        /// inflight. `inflight` is submitted-but-not-terminated streams on a
        /// leg (`enqueue`/terminal repay). If half-closed proxied streams
        /// leak (their terminal never lands), this climbs monotonically and
        /// never drains at idle — the pooled-conn leak canary.
        pub const UpstreamStats = struct { inflight: u64 = 0, live_legs: u32 = 0, max_leg_inflight: u32 = 0 };
        pub fn upstreamStats(self: *const Self) UpstreamStats {
            var s: UpstreamStats = .{};
            var it = self.pool.valueIterator();
            while (it.next()) |up_ptr| {
                const up = up_ptr.*;
                for (up.legs[0..up.n_legs]) |*leg| {
                    if (leg.state == .up) s.live_legs += 1;
                    s.inflight += leg.inflight;
                    if (leg.inflight > s.max_leg_inflight) s.max_leg_inflight = leg.inflight;
                }
            }
            return s;
        }

        pub fn deinit(self: *Self) void {
            var it = self.pool.valueIterator();
            while (it.next()) |up| {
                up.*.waiters.deinit(self.allocator);
                self.allocator.free(up.*.origin);
                self.allocator.destroy(up.*);
            }
            self.pool.deinit(self.allocator);
            self.waiter_outcomes.deinit(self.allocator);
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
            var pk = self.flows_by_peer.keyIterator();
            while (pk.next()) |k| self.allocator.free(k.*);
            self.flows_by_peer.deinit(self.allocator);
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
            // Resume connect verdicts BEFORE the settle sweep so a tunnel
            // that re-parks awaiting ENABLE_CONNECT_PROTOCOL is visible to
            // `drainSettledTunnels` this same turn (the pool defers these
            // resumes rather than dispatching them inline).
            self.dispatchWaiterOutcomes();
            // Resume tunnels parked on a live conn awaiting its peer
            // ENABLE_CONNECT_PROTOCOL SETTINGS (cold-leg race), now that this
            // cycle's server poll may have landed that frame.
            self.drainSettledTunnels(now_ns);
            self.dispatchWaiterOutcomes();
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
            // Abort any flow whose inbound request body stalled.
            self.expireStalledBodies(now_ns);
            // Fail over waiters whose upstream connect blew its deadline.
            self.expireStalledConnects(now_ns);
            self.dispatchWaiterOutcomes();
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
                        // Arm the body-progress budget (a body is now
                        // owed; `downSinkPush` refreshes per byte).
                        flow.last_body_progress_ns = now_ns;
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
        // ── WS tunnels (architecture/websockets.md) ──────────────────────────

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
                var host_buf: [255]u8 = undefined;
                const host = normalizeHost(&host_buf, authority_raw) orelse {
                    self.server.wsUpgradeReject(ent, 400);
                    continue;
                };
                var peer_buf: [46]u8 = undefined;
                var peer_len: u8 = 0;
                if (self.server.connPeerAddr(sess.entity)) |peer|
                    peer_len = peerIpString(&peer_buf, peer);
                if (peer_len > 0 and self.peerAtCap(peer_buf[0..peer_len])) {
                    self.count_client_limited += 1;
                    self.server.wsUpgradeReject(ent, 429);
                    continue;
                }
                const route = self.resolveRoute(host, now_ns);
                switch (route) {
                    .not_found => {
                        self.server.wsUpgradeReject(ent, 404);
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
                t.peer_ip_len = peer_len;
                if (peer_len > 0) @memcpy(t.peer_ip[0..peer_len], peer_buf[0..peer_len]);
                const ws_scheme = headerValue(rh, ":scheme") orelse "http";
                t.fwd_proto = if (std.mem.eql(u8, ws_scheme, "https")) "https" else "http";
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
                        self.parkRouteWaiter(host, .{ .kind = .tunnel, .ptr = t }) catch {
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
                if (t.peer_ip_len > 0) self.peerFlowInc(t.peer_ip[0..t.peer_ip_len]);
                fr.ptr = @ptrCast(t);
                fr.tunnel = true;
                if (!t.awaiting_route) self.startTunnelAttempt(t);
            }
        }

        // ── WS tunnel leg (proxy/ws_tunnel.zig) ───────────────────────
        // Extended-CONNECT tunnel lifecycle — methods on this struct,
        // defined in `proxy/ws_tunnel.zig`, re-exported so `self.X()`
        // resolves. intakeWsUpgrades (intake+routing) stays above.
        pub const startTunnelAttempt = ws_tunnel.Fns(FrontH2).startTunnelAttempt;
        pub const submitTunnel = ws_tunnel.Fns(FrontH2).submitTunnel;
        pub const packTunnelHeaders = ws_tunnel.Fns(FrontH2).packTunnelHeaders;
        pub const tunnelAttemptFailed = ws_tunnel.Fns(FrontH2).tunnelAttemptFailed;
        pub const unmapTunnel = ws_tunnel.Fns(FrontH2).unmapTunnel;
        pub const finishTunnel = ws_tunnel.Fns(FrontH2).finishTunnel;
        pub const maybeDestroyTunnel = ws_tunnel.Fns(FrontH2).maybeDestroyTunnel;
        pub const failParkedTunnel = ws_tunnel.Fns(FrontH2).failParkedTunnel;
        pub const tunnelResponse = ws_tunnel.Fns(FrontH2).tunnelResponse;

        // ── Per-client limits (plan C13) ──────────────────────────────

        fn peerAtCap(self: *Self, peer: []const u8) bool {
            if (self.max_flows_per_ip == 0 or peer.len == 0) return false;
            const cnt = self.flows_by_peer.get(peer) orelse return false;
            return cnt >= self.max_flows_per_ip;
        }

        /// Best-effort accounting (LeaderCache's discipline): an OOM
        /// skip degrades the cap toward lenient, never toward wedged.
        fn peerFlowInc(self: *Self, peer: []const u8) void {
            if (self.max_flows_per_ip == 0 or peer.len == 0) return;
            const gop = self.flows_by_peer.getOrPut(self.allocator, peer) catch return;
            if (!gop.found_existing) {
                gop.key_ptr.* = self.allocator.dupe(u8, peer) catch {
                    self.flows_by_peer.removeByPtr(gop.key_ptr);
                    return;
                };
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }

        pub fn peerFlowDec(self: *Self, peer: []const u8) void {
            if (self.max_flows_per_ip == 0 or peer.len == 0) return;
            const e = self.flows_by_peer.getPtr(peer) orelse return;
            e.* -|= 1;
            if (e.* == 0) {
                if (self.flows_by_peer.fetchRemove(peer)) |kv| self.allocator.free(kv.key);
            }
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
            var host_buf: [255]u8 = undefined;
            const host = normalizeHost(&host_buf, authority_raw) orelse {
                try self.replyStatus(coll, ent, sid, sess, 400);
                return null;
            };

            var peer_buf: [46]u8 = undefined;
            var peer_len: u8 = 0;
            if (self.server.connPeerAddr(sess.entity)) |peer|
                peer_len = peerIpString(&peer_buf, peer);
            if (peer_len > 0 and self.peerAtCap(peer_buf[0..peer_len])) {
                self.count_client_limited += 1;
                try self.replyStatus(coll, ent, sid, sess, 429);
                return null;
            }

            const route = self.resolveRoute(host, now_ns);
            switch (route) {
                .not_found => {
                    std.log.warn("front: no placement for host {s} → 404", .{host});
                    try self.replyStatus(coll, ent, sid, sess, 404);
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
                .idempotent = isIdempotentMethod(headerValue(rh, ":method") orelse "GET"),
            };
            flow.peer_ip_len = peer_len;
            if (peer_len > 0) @memcpy(flow.peer_ip[0..peer_len], peer_buf[0..peer_len]);
            const scheme = headerValue(rh, ":scheme") orelse "http";
            flow.fwd_proto = if (std.mem.eql(u8, scheme, "https")) "https" else "http";
            flow.via_entry = if (self.server.connIsHttp1(sess.entity)) "1.1 rewind-front" else "2 rewind-front";
            flow.t_start_ns = now_ns;
            const method = headerValue(rh, ":method") orelse "GET";
            flow.method_len = @intCast(@min(method.len, flow.method.len));
            @memcpy(flow.method[0..flow.method_len], method[0..flow.method_len]);
            flow.path = self.allocator.dupe(u8, headerValue(rh, ":path") orelse "/") catch @constCast(@as([]const u8, &.{}));
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
                    self.parkRouteWaiter(flow.host, .{ .kind = .flow, .ptr = flow }) catch |e| {
                        self.allocator.free(flow.authority);
                        self.allocator.free(flow.host);
                        return e;
                    };
                },
                else => unreachable,
            }
            self.live_flows += 1;
            if (flow.peer_ip_len > 0) self.peerFlowInc(flow.peer_ip[0..flow.peer_ip_len]);
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

            switch (self.acquireLeg(flow.nodes[flow.node_idx], .{ .kind = .flow, .ptr = flow })) {
                .submit => |leg| self.submitAttempt(flow, leg),
                .parked => flow.waiting_conn = true,
                .shed => {
                    // Every leg live but saturated: SHED with a retryable
                    // 503 (nothing submitted) — a bounded, visible shed
                    // rather than an invisible queue in nghttp2 (plan A3).
                    self.count_upstream_sheds += 1;
                    std.log.warn("front: all leg(s) to {s} saturated — shedding", .{flow.nodes[flow.node_idx]});
                    self.finishWithStatus(flow, 503);
                },
                // All legs down inside backoff (fail_over) or pool
                // bookkeeping failed (err) — fail over to the next node.
                .fail_over, .err => self.attemptFailed(flow, false, false),
            }
        }

        /// Outcome of `acquireLeg` — what the request layer does with its
        /// attempt. The one leg-acquire path shared by Flow
        /// (`startAttempt`) and WsTunnel (`startTunnelAttempt`) attempts.
        // ── Upstream pool (proxy/pool.zig) ────────────────────────────
        // The leg pool + connect machinery are methods on this struct,
        // defined in `proxy/pool.zig` and re-exported here so `self.X()`
        // cross-calls resolve; see pool.zig for the bodies.
        pub const acquireLeg = pool.Fns(FrontH2).acquireLeg;
        pub const poolEntry = pool.Fns(FrontH2).poolEntry;
        pub const pickLeg = pool.Fns(FrontH2).pickLeg;
        pub const anyLegUp = pool.Fns(FrontH2).anyLegUp;
        pub const markStaleLegsDown = pool.Fns(FrontH2).markStaleLegsDown;
        pub const dialLeg = pool.Fns(FrontH2).dialLeg;
        pub const consumeConnects = pool.Fns(FrontH2).consumeConnects;
        pub const drainWaiters = pool.Fns(FrontH2).drainWaiters;
        pub const drainSettledTunnels = pool.Fns(FrontH2).drainSettledTunnels;
        pub const expireStalledConnects = pool.Fns(FrontH2).expireStalledConnects;

        /// Submit the current attempt's request head on `leg` via the
        /// streaming client leg. The body (whatever its state) follows
        /// through `pumpUpstream`.
        fn submitAttempt(self: *Self, flow: *Flow, leg: *Leg) void {
            const rh = self.reg.get(flow.down_ent, self.downColl(flow), h2.ReqHeaders) catch {
                self.teardownFlow(flow);
                return;
            };
            const packed_hdrs = self.packUpstreamHeaders(rh.*, flow) catch {
                self.attemptFailed(flow, false, false);
                return;
            };

            const pump = self.reg.create(&self.server.client_stream_request_in) catch {
                if (packed_hdrs._buf) |b| self.allocator.free(b[0..packed_hdrs._buf_len]);
                self.attemptFailed(flow, false, false);
                return;
            };
            const coll = &self.server.client_stream_request_in;
            flow.attempt += 1;
            self.reg.set(pump, coll, h2.Session, .{ .entity = leg.sess }) catch {};
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
            self.reg.set(pump, coll, FlowRef, .{ .ptr = @ptrCast(flow), .attempt = flow.attempt, .leg = @ptrCast(leg) }) catch {};
            if (bodyless) flow.up_closed = true;

            leg.inflight += 1;
            flow.up_sess = leg.sess;
            flow.attempt_live = true;
            flow.pending_terminals += 1;
        }

        /// The current attempt failed before any response. Re-aim or
        /// give up.
        ///
        /// `head_sent` says the request head was already handed to the
        /// failed upstream. That makes the failure AMBIGUOUS for a
        /// non-idempotent request: the worker may have dispatched the
        /// handler (an `onHeaders` export activates on the head alone)
        /// and committed before the connection died — a replay would
        /// double-execute. Same discipline as the never-retried
        /// post-propose 503 (decisions.md §10.5): the client's retry
        /// policy owns the ambiguous case, so it gets a 502, not a
        /// silent re-send. A 421 is NOT ambiguous (nothing entered the
        /// log) and takes `handle421`, never this gate.
        fn attemptFailed(self: *Self, flow: *Flow, conn_died: bool, head_sent: bool) void {
            self.unmapAttempt(flow);
            flow.attempt_live = false;
            if (flow.down_gone or !flow.down_alive) {
                self.teardownFlow(flow);
                return;
            }
            const replay_safe = flow.idempotent or !head_sent;
            if (!replay_safe) {
                // The dead node shouldn't seed future requests' start
                // index, even though this flow can't re-aim.
                if (conn_died) self.leaders.drop(self.allocator, flow.host);
                self.count_ambiguous_502 += 1;
                self.finishWithStatus(flow, 502);
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
        fn handle421(self: *Self, flow: *Flow, rh: h2.RespHeaders) void {
            // Remember we were redirected: a later 2xx in this flow is
            // then provably from the leader (see `noteLeader`).
            flow.saw_421 = true;
            self.count_reaims_421 += 1;
            // Learn the leader from the worker's `x-rewind-leader` redirect
            // hint — works even for a NON-replayable request, which can't
            // re-aim to discover the leader itself and would otherwise bounce
            // 421→503 forever once its cached hint went stale. If the hint is
            // absent (unknown leader: mid-election) or maps nowhere, FORGET
            // the stale hint so the next request re-scans instead of starting
            // at a node that's no longer the leader.
            if (leaderOriginHint(rh, flow.nodes)) |origin| {
                if (std.mem.eql(u8, origin, flow.nodes[flow.node_idx])) {
                    // Hint points back at the node that just refused — stale
                    // (a just-stepped-down leader). Drop, don't loop on it.
                    self.leaders.drop(self.allocator, flow.host);
                } else {
                    self.leaders.note(self.allocator, flow.host, origin);
                }
            } else {
                self.leaders.drop(self.allocator, flow.host);
            }
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

        /// Resume the waiters the pool drained this turn (`drainWaiters`) —
        /// the sole connect-path bridge from the pool back into the Flow /
        /// WsTunnel state machines, casting each opaque waiter to its
        /// concrete type. Dispatch never enqueues (`drainWaiters` runs only
        /// from the connect / settle / connect-expiry sweeps), so iterating
        /// in place then clearing is safe.
        fn dispatchWaiterOutcomes(self: *Self) void {
            for (self.waiter_outcomes.items) |o| switch (o.waiter.kind) {
                .flow => {
                    const flow: *Flow = @ptrCast(@alignCast(o.waiter.ptr));
                    flow.waiting_conn = false;
                    if (flow.down_gone or !flow.down_alive) {
                        self.teardownFlow(flow);
                    } else if (o.ok) {
                        // Re-enter the pick (least-loaded leg / shed), not
                        // a direct submit on any one session.
                        self.startAttempt(flow);
                    } else {
                        self.attemptFailed(flow, false, false);
                    }
                },
                .tunnel => {
                    const t: *WsTunnel = @ptrCast(@alignCast(o.waiter.ptr));
                    t.waiting_conn = false;
                    if (t.down_gone or self.reg.isStale(t.down_conn)) {
                        self.finishTunnel(t);
                    } else if (o.ok) {
                        self.startTunnelAttempt(t);
                    } else {
                        self.tunnelAttemptFailed(t);
                    }
                },
            };
            self.waiter_outcomes.clearRetainingCapacity();
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
                    self.handle421(flow, rh);
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
            flow.final_status = code;
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
                // Repay the submitting leg's in-flight slot (plan A3) —
                // exactly one terminal per submit, current attempt or
                // abandoned. Legs live in process-lifetime pool entries,
                // so a late terminal's pointer is always valid.
                if (fr.leg) |lp| {
                    const leg: *Leg = @ptrCast(@alignCast(lp));
                    leg.inflight -|= 1;
                }
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
                                self.markStaleLegsDown(up);
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
                            if (rb.len > 0) {
                                flow.resp_queue.appendSlice(self.allocator, d[0..rb.len]) catch {};
                                flow.resp_bytes += rb.len;
                            }
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
                        self.handle421(flow, rh);
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
                // A terminal for a submitted request: the head reached
                // the upstream leg — ambiguous for non-idempotent flows.
                self.attemptFailed(flow, conn_died, true);
            }
        }

        fn markDown(self: *Self, flow: *Flow) void {
            if (self.pool.get(flow.nodes[flow.node_idx])) |up| {
                self.markStaleLegsDown(up);
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
            flow.final_status = code;
            flow.resp_bytes += body.len;
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
            self.recordFlowDone(flow);
            if (flow.peer_ip_len > 0) self.peerFlowDec(flow.peer_ip[0..flow.peer_ip_len]);
            self.unmapAttempt(flow);
            flow.body.deinit(self.allocator);
            flow.resp_queue.deinit(self.allocator);
            if (flow.path.len != 0) self.allocator.free(flow.path);
            // A parked flow torn down before its route landed never got
            // a heap node list — its `.nodes` is still the empty default
            // (`&.{}`), which must not be passed to free.
            if (flow.nodes.len != 0) freeNodes(self.allocator, flow.nodes);
            self.allocator.free(flow.authority);
            self.allocator.free(flow.host);
            self.allocator.destroy(flow);
            self.live_flows -= 1;
        }

        /// One histogram sample + one access-log line per completed
        /// flow (plan C11) — the front's RED signals: who was served
        /// what, how fast, by which node, in how many attempts.
        /// `status=0` means the flow died before any
        /// response (client gone / teardown).
        fn recordFlowDone(self: *Self, flow: *Flow) void {
            const dur_ns = std.time.nanoTimestamp() - flow.t_start_ns;
            const dur_ms: u64 = if (dur_ns <= 0) 0 else @intCast(@divTrunc(dur_ns, std.time.ns_per_ms));
            var bucket: usize = LAT_BOUNDS_MS.len; // +Inf
            for (LAT_BOUNDS_MS, 0..) |bound, i| {
                if (dur_ms <= bound) {
                    bucket = i;
                    break;
                }
            }
            self.lat_counts[bucket] += 1;
            self.lat_sum_ms += dur_ms;
            self.lat_total += 1;

            if (!self.access_log) return;
            const node: []const u8 = if (flow.nodes.len > 0)
                flow.nodes[@min(flow.node_idx, flow.nodes.len - 1)]
            else
                "-";
            std.log.info("front-access: {s} {s} \"{s} {s}\" {d} {d}ms node={s} attempts={d} in={d}B out={d}B", .{
                if (flow.peer_ip_len > 0) flow.peer_ip[0..flow.peer_ip_len] else "-",
                flow.host,
                flow.method[0..flow.method_len],
                if (flow.path.len > 0) flow.path else "/",
                flow.final_status,
                dur_ms,
                node,
                flow.attempt,
                flow.body_total,
                flow.resp_bytes,
            });
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
            flow.last_body_progress_ns = std.time.nanoTimestamp();
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
            flow.resp_bytes += bytes.len;
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

        // Header pack/read primitives live in `proxy/util.zig` (pure, no
        // Proxy state) — shared with proxy/ws_tunnel.zig.
        const PackedFields = util.PackedFields;
        const NameValue = util.NameValue;
        const packFields = util.packFields;

        /// Build the upstream request head: pseudo-headers first
        /// (nghttp2 requires it), then the filtered originals, then the
        /// forwarding identity stamped at the trust boundary (plan B7)
        /// and the `Via` entry (§5.7.1).
        fn packUpstreamHeaders(self: *Self, rh: h2.ReqHeaders, flow: *const Flow) !h2.ReqHeaders {
            const a = self.allocator;
            var list: std.ArrayListUnmanaged(NameValue) = .empty;
            defer list.deinit(a);

            const method = headerValue(rh, ":method") orelse "GET";
            const path = headerValue(rh, ":path") orelse "/";
            try list.append(a, .{ .name = ":method", .value = method });
            try list.append(a, .{ .name = ":scheme", .value = "http" });
            try list.append(a, .{ .name = ":path", .value = path });
            try list.append(a, .{ .name = ":authority", .value = flow.authority });

            // Headers nominated by the client's `Connection` value are
            // hop-by-hop too (plan B8).
            const connection_value = headerValue(rh, "connection");

            if (rh.fields) |fields| {
                var i: u32 = 0;
                while (i < rh.count) : (i += 1) {
                    const f = fields[i];
                    const fname = f.name[0..f.name_len];
                    if (fname.len > 0 and fname[0] == ':') continue;
                    if (dropFromRequest(fname)) continue;
                    if (nominatedByConnection(connection_value, fname)) continue;
                    try list.append(a, .{ .name = fname, .value = f.value[0..f.value_len] });
                }
            }
            if (flow.peer_ip_len > 0)
                try list.append(a, .{ .name = "x-forwarded-for", .value = flow.peer_ip[0..flow.peer_ip_len] });
            try list.append(a, .{ .name = "x-forwarded-proto", .value = flow.fwd_proto });
            try list.append(a, .{ .name = "via", .value = flow.via_entry });
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

        /// Non-blocking. A fresh cache hit (positive OR negative)
        /// answers inline; a miss (no entry or past TTL) enqueues an
        /// off-loop resolve and returns `.pending` for the caller to
        /// park on. The CP is never contacted on this thread, and a
        /// stale entry is never served (so a tenant move re-resolves
        /// correctly past the TTL).
        fn resolveRoute(self: *Self, host: []const u8, now_ns: i128) RouteResult {
            if (self.cache.get(host, now_ns)) |hit| switch (hit) {
                .nodes => |nodes| return .{ .nodes = nodes },
                .not_found => return .not_found,
            };
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
                    // Gone: replace any stale entry with a negative one
                    // (short TTL) so scanner floods of garbage hosts
                    // answer 404 from cache instead of serially
                    // occupying the resolver (plan A6).
                    .not_found => {
                        self.count_route_not_found += 1;
                        self.cache.putNegative(c.host, now_ns);
                        self.failRouteWaiters(c.host, 404);
                    },
                    // Transient CP failure: don't touch the cache (a
                    // fresh entry, if any, keeps serving other requests);
                    // the cold parked flows get a retryable 503.
                    .err => {
                        self.count_route_errors += 1;
                        self.failRouteWaiters(c.host, 503);
                    },
                }
                self.allocator.free(c.host);
            }
        }

        fn resumeRouteWaiters(self: *Self, host: []const u8, nodes: []const []const u8) void {
            const kv = self.route_waiters.fetchRemove(host) orelse return;
            var list = kv.value;
            self.allocator.free(kv.key);
            defer list.deinit(self.allocator);
            for (list.items) |w| switch (w.kind) {
                .flow => {
                    const flow: *Flow = @ptrCast(@alignCast(w.ptr));
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
                .tunnel => {
                    const t: *WsTunnel = @ptrCast(@alignCast(w.ptr));
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
            for (list.items) |w| switch (w.kind) {
                .flow => {
                    const flow: *Flow = @ptrCast(@alignCast(w.ptr));
                    flow.awaiting_route = false;
                    if (flow.down_gone or !flow.down_alive) {
                        self.teardownFlow(flow);
                    } else {
                        self.finishWithStatus(flow, code);
                    }
                },
                .tunnel => self.failParkedTunnel(@ptrCast(@alignCast(w.ptr)), code),
            };
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
                    const deadline = switch (w.kind) {
                        .flow => @as(*Flow, @ptrCast(@alignCast(w.ptr))).route_deadline_ns,
                        .tunnel => @as(*WsTunnel, @ptrCast(@alignCast(w.ptr))).route_deadline_ns,
                    };
                    if (now_ns >= deadline) {
                        _ = list.swapRemove(i);
                        self.count_route_expired += 1;
                        switch (w.kind) {
                            .flow => {
                                const flow: *Flow = @ptrCast(@alignCast(w.ptr));
                                flow.awaiting_route = false;
                                if (flow.down_gone or !flow.down_alive) {
                                    self.teardownFlow(flow);
                                } else {
                                    self.finishWithStatus(flow, 503);
                                }
                            },
                            .tunnel => self.failParkedTunnel(@ptrCast(@alignCast(w.ptr)), 503),
                        }
                    } else {
                        i += 1;
                    }
                }
            }
        }

        /// Abort any flow whose inbound request body has made no
        /// progress for `body_stall_ns` (plan A5; nginx
        /// `client_body_timeout`). Per-STREAM: the conn-level idle reap
        /// never fires while any sibling stream (or a PING) keeps the
        /// connection active, so a stalled upload otherwise holds its
        /// front flow and worker stream forever. Between-bytes budget —
        /// slow-but-moving uploads survive. Exemptions: complete bodies
        /// (nothing owed), flows the worker already answered
        /// (`resp_started` — the h2 layer flips the remainder to
        /// discard), and held/response-side streams (never armed).
        /// `serverStreamAbort` reuses the downstream-death teardown:
        /// the sink abort marks `down_gone`, the upstream pump RSTs so
        /// the worker sees a broken stream (never a truncated-but-
        /// complete body), and the entity routes out via the orphan
        /// sweep. Collect first — the abort mutates flow state.
        fn expireStalledBodies(self: *Self, now_ns: i128) void {
            if (self.body_stall_ns == 0) return;
            var stalled: [32]*Flow = undefined;
            var n: usize = 0;
            var it = self.flows_by_up.valueIterator();
            while (it.next()) |fp| {
                const flow = fp.*;
                if (flow.body_complete or flow.resp_started) continue;
                if (flow.down_gone or !flow.down_alive) continue;
                if (flow.last_body_progress_ns == 0) continue;
                if (now_ns - flow.last_body_progress_ns < self.body_stall_ns) continue;
                stalled[n] = flow;
                n += 1;
                if (n == stalled.len) break;
            }
            for (stalled[0..n]) |flow| {
                std.log.warn("front: request body stalled >{d}ms (host={s}) -> abort", .{
                    @divTrunc(self.body_stall_ns, std.time.ns_per_ms), flow.host,
                });
                self.count_body_stalls += 1;
                self.server.serverStreamAbort(flow.down_sess, flow.down_sid);
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
                self.count_resp_timeouts += 1;
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
pub fn resolveOrigin(origin: []const u8) !std.net.Address {
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

test "normalizeHost: lowercases, strips port bracket-aware, rejects junk" {
    var buf: [255]u8 = undefined;

    try testing.expectEqualStrings("acme.example", normalizeHost(&buf, "ACME.Example:8443").?);
    try testing.expectEqualStrings("acme.example", normalizeHost(&buf, "acme.example").?);
    // IPv6 literal keeps its brackets, with and without a port (the
    // old bare last-colon split broke the portless form).
    try testing.expectEqualStrings("[::1]", normalizeHost(&buf, "[::1]:8443").?);
    try testing.expectEqualStrings("[::1]", normalizeHost(&buf, "[::1]").?);
    // Junk never reaches cache keys / the CP query string / logs.
    try testing.expect(normalizeHost(&buf, "a b") == null);
    try testing.expect(normalizeHost(&buf, "acme.example/evil?x=") == null);
    try testing.expect(normalizeHost(&buf, "") == null);
    try testing.expect(normalizeHost(&buf, "acme\r\nx-inject: 1") == null);
}

test "nominatedByConnection: Connection-listed headers are hop-by-hop (RFC 7230 §6.1)" {
    // A client smuggling `Connection: x-secret-hint` must not get
    // x-secret-hint forwarded upstream.
    try testing.expect(nominatedByConnection("x-secret-hint", "x-secret-hint"));
    try testing.expect(nominatedByConnection("keep-alive, X-Secret-Hint", "x-secret-hint"));
    try testing.expect(nominatedByConnection("a,\tb , c", "b"));
    try testing.expect(!nominatedByConnection("keep-alive", "x-secret-hint"));
    try testing.expect(!nominatedByConnection(null, "anything"));
    // Substring is not membership.
    try testing.expect(!nominatedByConnection("x-secret-hint-2", "x-secret-hint"));
}

test "peerIpString: bare IP, no port, no IPv6 brackets" {
    var buf: [46]u8 = undefined;

    const v4 = try std.net.Address.parseIp("192.168.1.7", 12345);
    try testing.expectEqualStrings("192.168.1.7", buf[0..peerIpString(&buf, v4)]);

    const v6 = try std.net.Address.parseIp("2001:db8::1", 443);
    try testing.expectEqualStrings("2001:db8::1", buf[0..peerIpString(&buf, v6)]);
}

test "isIdempotentMethod: only read-shaped methods replay after ambiguous failure" {
    // Safe to re-send after an upstream died post-head, pre-response.
    try testing.expect(isIdempotentMethod("GET"));
    try testing.expect(isIdempotentMethod("HEAD"));
    try testing.expect(isIdempotentMethod("OPTIONS"));
    // Handler-executing methods must NOT silently replay (the worker may
    // have committed before the connection died — decisions.md §10.5).
    try testing.expect(!isIdempotentMethod("POST"));
    try testing.expect(!isIdempotentMethod("PATCH"));
    // PUT/DELETE are RFC-idempotent but customer-defined here: excluded.
    try testing.expect(!isIdempotentMethod("PUT"));
    try testing.expect(!isIdempotentMethod("DELETE"));
    // Case-sensitive by design: h2 methods are uppercase on the wire.
    try testing.expect(!isIdempotentMethod("get"));
}

test "leaderOriginHint maps the x-rewind-leader raft id to its positional node" {
    const nodes = &[_][]const u8{ "http://n1:1", "http://n2:1", "http://n3:1" };

    // Build a RespHeaders carrying a single `x-rewind-leader: <val>`.
    const mk = struct {
        fn go(field: *h2.HeaderField, val: []const u8) h2.RespHeaders {
            const name = "x-rewind-leader";
            field.* = .{ .name = name.ptr, .name_len = name.len, .value = val.ptr, .value_len = @intCast(val.len) };
            return .{ .fields = @as([*]h2.HeaderField, @ptrCast(field)), .count = 1 };
        }
    }.go;
    var f: h2.HeaderField = undefined;

    // raft id L → nodes[L-1] (cluster list ordered by node id).
    try testing.expectEqualStrings("http://n1:1", leaderOriginHint(mk(&f, "1"), nodes).?);
    try testing.expectEqualStrings("http://n2:1", leaderOriginHint(mk(&f, "2"), nodes).?);
    try testing.expectEqualStrings("http://n3:1", leaderOriginHint(mk(&f, "3"), nodes).?);
    // Unknown (0), out of range, or unparseable → null (caller forgets its
    // stale hint and re-scans rather than trusting a bad map).
    try testing.expect(leaderOriginHint(mk(&f, "0"), nodes) == null);
    try testing.expect(leaderOriginHint(mk(&f, "4"), nodes) == null);
    try testing.expect(leaderOriginHint(mk(&f, "nope"), nodes) == null);
    // No hint header at all → null.
    try testing.expect(leaderOriginHint(.{ .fields = null, .count = 0 }, nodes) == null);
}
