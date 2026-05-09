//! sse-server — h2 listener + ring cache + connection table.
//!
//! Owns the entire SSE delivery path: workers POST emits here after a
//! kv commit, browsers hold long-lived `text/event-stream` connections
//! here, and the in-memory ring cache covers reconnect catch-up. The
//! customer's `app.db` remains the source of truth for state — events
//! tell the UI "something changed, refetch what you need" — so losing
//! the ring on restart is acceptable and signals via the `rove:resync`
//! sentinel (sse-plan §4.4).
//!
//! Three routes:
//!
//!   GET  /v1/health
//!         → 200 plain "ok\n". Used by the LB health check.
//!
//!   POST /v1/emit                                (worker → sse-server)
//!         Authorization: Bearer <SSE_INTERNAL_TOKEN>
//!         body: {v, tenant_id, request_id, events:[{event_id,type,
//!                                                     data,target_sids,
//!                                                     created_at_ms}]}
//!         → 204 on success.
//!
//!   GET  /v1/{tenant_id}/sse?token=<jwt>         (browser EventSource)
//!         [Last-Event-ID: <id>]
//!         → 200 text/event-stream. Headers go out immediately; frames
//!           follow as they're emitted. Keepalive every 15s.
//!
//! Single-process for v1 (sse-plan §1, §4.6). Failover is "load
//! balancer points at a different node, clients reconnect, hit
//! sentinel, refetch."

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const jwt = @import("rove-jwt");

const SseH2 = h2.H2(.{});

/// Per-(tenant, sid) ring buffer capacity. Sized for brief reconnect
/// catch-up windows (page hidden 30s, network blip), not for backlog
/// buffering. See sse-plan §2.3 for the math.
pub const RING_CAPACITY: usize = 30;

/// Stable wire id width — 20 digit request id + dash + 6 digit call
/// index, matching the format `events.emit` produces in the worker.
pub const EVENT_ID_LEN: usize = 27;

/// Default reserved sentinel — fires when reconnect arrives with a
/// Last-Event-ID that isn't in the ring (evicted, or sse-server
/// restarted since the id was minted).
const SENTINEL_FRAME =
    "event: rove:resync\n" ++
    "id: 00000000000000000000-000000\n" ++
    "data: {\"reason\":\"events_evicted\",\"advice\":\"refetch_state\"}\n\n";

/// Keepalive every this many ns. EventSource's auto-reconnect default
/// is 3s; 15s of silence is well inside that window but avoids waking
/// every connection on every tick.
const KEEPALIVE_INTERVAL_NS: i64 = 15 * std.time.ns_per_s;

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Where to bind the h2 listener. Pass port `0` for an ephemeral
    /// port; the resolved port is written to `Handle.port`.
    bind_addr: std.net.Address,
    /// h2 connection cap.
    max_connections: u32 = 1024,
    /// TLS config — when set, the listener does TLS termination via
    /// rove-h2's standard path. Null = h2c (smoke driver path).
    tls_config: ?*h2.TlsConfig = null,
    /// HMAC-SHA256 secret used to verify the EventSource JWT in the
    /// `?token=...` query param (sse-plan §5.1). Null = `/v1/{t}/sse`
    /// returns 401 (lets a smoke spin up without auth).
    jwt_secret: ?[]const u8 = null,
    /// Shared secret in `Authorization: Bearer ...` for the worker →
    /// sse-server emit POST. Null = `/v1/emit` returns 401.
    internal_token: ?[]const u8 = null,
    /// Per-tenant connection cap. The (cap+1)th simultaneous connect
    /// is refused 503. Defends a single tenant from exhausting h2
    /// streams.
    max_connections_per_tenant: u32 = 1_000,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    port: u16,
    stop: std.atomic.Value(bool),
    ready: std.Thread.ResetEvent,
    bind_err: ?anyerror,
    config: Config,

    pub fn shutdown(self: *Handle) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.allocator.destroy(self);
    }
};

pub fn spawn(config: Config) !*Handle {
    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
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
        std.log.err("sse-server: thread exited: {s}", .{@errorName(err)});
    };
}

fn runThread(h: *Handle) !void {
    const allocator = h.allocator;

    var reg = rove.Registry.init(allocator, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer reg.deinit();

    const server = SseH2.create(&reg, allocator, h.config.bind_addr, .{
        .max_connections = h.config.max_connections,
        .buf_count = 128,
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
        std.log.info("sse-server: h2 (TLS) on port {d}", .{h.port});
    } else {
        std.log.info("sse-server: h2c on 127.0.0.1:{d}", .{h.port});
    }

    var state: ServerState = .init(allocator);
    defer state.deinit();

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(server, allocator, &state, &h.config);
        try reg.flush();
        try pumpKeepalives(server, allocator, &state);
        try reg.flush();
        try cleanupClosedConnections(server, &state);
        try cleanupResponses(server);
        try reg.flush();
    }

    state.dropAllConnections();
}

fn resolveBoundPort(server: *SseH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

fn cleanupResponses(server: *SseH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

// ── Per-tenant state ──────────────────────────────────────────────

/// One ring buffer per (tenant, sid). RING_CAPACITY entries; oldest
/// evicted on overflow. Reads hand back a contiguous slice of entries
/// after a given id (for Last-Event-ID catch-up).
const Ring = struct {
    /// Backing array; entries past `count` are undefined.
    entries: [RING_CAPACITY]RingEntry = undefined,
    /// Number of valid entries (≤ RING_CAPACITY).
    count: usize = 0,
    /// Index of the next slot to write. Wraps mod RING_CAPACITY.
    write_pos: usize = 0,

    fn append(self: *Ring, allocator: std.mem.Allocator, e: RingEntry) void {
        if (self.count == RING_CAPACITY) {
            // Overwriting the oldest at write_pos — free its owned bytes
            // before stomping the slot.
            self.entries[self.write_pos].deinit(allocator);
        }
        self.entries[self.write_pos] = e;
        self.write_pos = (self.write_pos + 1) % RING_CAPACITY;
        if (self.count < RING_CAPACITY) self.count += 1;
    }

    fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
        var n: usize = 0;
        const start: usize = if (self.count == RING_CAPACITY) self.write_pos else 0;
        while (n < self.count) : (n += 1) {
            const idx = (start + n) % RING_CAPACITY;
            self.entries[idx].deinit(allocator);
        }
        self.count = 0;
        self.write_pos = 0;
    }

    /// Iterate entries in chronological order, oldest first.
    fn forEach(self: *const Ring, f: anytype) void {
        const start: usize = if (self.count == RING_CAPACITY) self.write_pos else 0;
        var n: usize = 0;
        while (n < self.count) : (n += 1) {
            const idx = (start + n) % RING_CAPACITY;
            f(&self.entries[idx]);
        }
    }

    /// True iff any entry has the given event_id.
    fn contains(self: *const Ring, event_id: []const u8) bool {
        const start: usize = if (self.count == RING_CAPACITY) self.write_pos else 0;
        var n: usize = 0;
        while (n < self.count) : (n += 1) {
            const idx = (start + n) % RING_CAPACITY;
            if (std.mem.eql(u8, &self.entries[idx].event_id, event_id)) return true;
        }
        return false;
    }
};

const RingEntry = struct {
    event_id: [EVENT_ID_LEN]u8,
    event_type: []u8,
    data_json: []u8,

    fn deinit(self: *RingEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.data_json);
    }
};

const Connection = struct {
    stream_ent: rove.Entity,
    sid: []u8,
    last_send_ns: i64,
    /// Most recent event delivered on this connection. null until
    /// the first emit lands.
    last_event_id: ?[EVENT_ID_LEN]u8 = null,
    /// Bytes staged at connect time (resume payload or sentinel) that
    /// couldn't be pushed yet because h2 hadn't parked the entity in
    /// `stream_data_out`. The keepalive pump drains this on the first
    /// tick that sees the entity parked. Owned by `allocator`.
    pending_chunk: ?[]u8 = null,
};

const TenantState = struct {
    /// Owns the tenant_id slice itself (for hash map key stability).
    id: []u8,
    /// Per-sid ring caches. Keys (sid strings) are owned alongside the
    /// ring; freed on tenant deinit.
    rings: std.StringHashMapUnmanaged(*Ring) = .empty,
    /// Open EventSource connections for this tenant.
    connections: std.ArrayListUnmanaged(*Connection) = .empty,

    fn deinit(self: *TenantState, allocator: std.mem.Allocator) void {
        var it = self.rings.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.free(entry.key_ptr.*);
            allocator.destroy(entry.value_ptr.*);
        }
        self.rings.deinit(allocator);
        for (self.connections.items) |c| {
            allocator.free(c.sid);
            allocator.destroy(c);
        }
        self.connections.deinit(allocator);
        allocator.free(self.id);
    }

    /// Get or create the ring for `sid`. The tenant owns the string.
    fn getOrCreateRing(self: *TenantState, allocator: std.mem.Allocator, sid: []const u8) !*Ring {
        if (self.rings.get(sid)) |r| return r;
        const sid_owned = try allocator.dupe(u8, sid);
        errdefer allocator.free(sid_owned);
        const r = try allocator.create(Ring);
        errdefer allocator.destroy(r);
        r.* = .{};
        try self.rings.put(allocator, sid_owned, r);
        return r;
    }
};

const ServerState = struct {
    allocator: std.mem.Allocator,
    tenants: std.StringHashMapUnmanaged(*TenantState) = .empty,

    fn init(allocator: std.mem.Allocator) ServerState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ServerState) void {
        var it = self.tenants.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.tenants.deinit(self.allocator);
    }

    fn getOrCreateTenant(self: *ServerState, tenant_id: []const u8) !*TenantState {
        if (self.tenants.get(tenant_id)) |t| return t;
        const id_owned = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(id_owned);
        const t = try self.allocator.create(TenantState);
        errdefer self.allocator.destroy(t);
        t.* = .{ .id = id_owned };
        try self.tenants.put(self.allocator, id_owned, t);
        return t;
    }

    /// Cleanup hook before thread exit — drop all owned connection
    /// records. The h2 entities get torn down by `server.destroy()`.
    fn dropAllConnections(self: *ServerState) void {
        var it = self.tenants.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr.*;
            for (t.connections.items) |c| {
                self.allocator.free(c.sid);
                self.allocator.destroy(c);
            }
            t.connections.clearRetainingCapacity();
        }
    }
};

// ── Request dispatch ──────────────────────────────────────────────

fn processRequests(
    server: *SseH2,
    allocator: std.mem.Allocator,
    state: *ServerState,
    cfg: *const Config,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        handleOne(server, allocator, state, cfg, ent, sid, sess, rh, rb) catch |err| {
            std.log.warn("sse-server: handler error: {s}", .{@errorName(err)});
            setSimpleResponse(server, ent, sid, sess, 500, "internal error\n") catch |se| std.log.err(
                "sse-server: 500 write failed: {s}",
                .{@errorName(se)},
            );
        };
    }
}

fn handleOne(
    server: *SseH2,
    allocator: std.mem.Allocator,
    state: *ServerState,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    rb: h2.ReqBody,
) !void {
    var method: []const u8 = "";
    var path: []const u8 = "";
    var authz: []const u8 = "";
    var last_event_id_hdr: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
            if (std.mem.eql(u8, name, "authorization")) authz = value;
            if (std.mem.eql(u8, name, "last-event-id")) last_event_id_hdr = value;
        }
    }

    const route = parseRoute(path) orelse {
        try setSimpleResponse(server, ent, sid, sess, 404, "not found\n");
        return;
    };

    switch (route.kind) {
        .health => {
            if (!std.mem.eql(u8, method, "GET")) {
                try setSimpleResponse(server, ent, sid, sess, 405, "GET only\n");
                return;
            }
            try setSimpleResponse(server, ent, sid, sess, 200, "ok\n");
        },
        .emit => {
            if (!std.mem.eql(u8, method, "POST")) {
                try setSimpleResponse(server, ent, sid, sess, 405, "POST only\n");
                return;
            }
            try handleEmit(server, allocator, state, cfg, ent, sid, sess, authz, rb);
        },
        .sse => {
            if (!std.mem.eql(u8, method, "GET")) {
                try setSimpleResponse(server, ent, sid, sess, 405, "GET only\n");
                return;
            }
            try handleSseConnect(
                server,
                allocator,
                state,
                cfg,
                ent,
                sid,
                sess,
                route.tenant_id,
                route.query,
                last_event_id_hdr,
            );
        },
    }
}

const RouteKind = enum { health, emit, sse };

const ParsedRoute = struct {
    kind: RouteKind,
    /// Empty for `health` and `emit`.
    tenant_id: []const u8 = "",
    /// Raw query string (after `?`); empty if absent.
    query: []const u8 = "",
};

fn parseRoute(path: []const u8) ?ParsedRoute {
    const q_idx = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (q_idx) |i| path[0..i] else path;
    const query = if (q_idx) |i| path[i + 1 ..] else "";

    if (std.mem.eql(u8, path_no_q, "/v1/health")) {
        return .{ .kind = .health };
    }
    if (std.mem.eql(u8, path_no_q, "/v1/emit")) {
        return .{ .kind = .emit, .query = query };
    }
    const v1_prefix = "/v1/";
    if (std.mem.startsWith(u8, path_no_q, v1_prefix)) {
        const after = path_no_q[v1_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        const tenant_id = after[0..slash];
        const tail = after[slash + 1 ..];
        if (tenant_id.len == 0) return null;
        if (std.mem.eql(u8, tail, "sse")) {
            return .{ .kind = .sse, .tenant_id = tenant_id, .query = query };
        }
    }
    return null;
}

// ── Emit POST ─────────────────────────────────────────────────────

fn handleEmit(
    server: *SseH2,
    allocator: std.mem.Allocator,
    state: *ServerState,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    authz: []const u8,
    rb: h2.ReqBody,
) !void {
    const expected = cfg.internal_token orelse {
        try setSimpleResponse(server, ent, sid, sess, 401, "auth not configured\n");
        return;
    };
    if (!std.mem.startsWith(u8, authz, "Bearer ")) {
        try setSimpleResponse(server, ent, sid, sess, 401, "missing bearer token\n");
        return;
    }
    const token = authz["Bearer ".len..];
    if (!constantTimeEql(token, expected)) {
        try setSimpleResponse(server, ent, sid, sess, 401, "bad internal token\n");
        return;
    }

    if (rb.data == null or rb.len == 0) {
        try setSimpleResponse(server, ent, sid, sess, 400, "missing body\n");
        return;
    }
    const body = rb.data.?[0..rb.len];

    const parsed = parseEmitBody(allocator, body) catch |err| switch (err) {
        error.MalformedBody => {
            try setSimpleResponse(server, ent, sid, sess, 400, "malformed body\n");
            return;
        },
        else => return err,
    };
    defer parsed.deinit(allocator);

    const tenant = try state.getOrCreateTenant(parsed.tenant_id);

    // Per-connection frame accumulator. `reg.move` is deferred —
    // doing one set+move per (event, conn) pair would let the second
    // event's set overwrite the first event's RespBody.data slot
    // before h2 has picked it up, and the second move would then
    // error `PendingMove` (use-after-free + double-free territory,
    // gpa caught it). Mirrors events_pump.zig's writeset accumulator
    // shape: build the bytes for ALL events targeting a conn, then
    // one set+move per conn.
    var conn_buffers: std.AutoHashMapUnmanaged(*Connection, std.ArrayListUnmanaged(u8)) = .empty;
    var conn_last_event: std.AutoHashMapUnmanaged(*Connection, [EVENT_ID_LEN]u8) = .empty;
    defer {
        var it = conn_buffers.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        conn_buffers.deinit(allocator);
        conn_last_event.deinit(allocator);
    }

    for (parsed.events) |e| {
        // Cache-then-collect: every target sid's ring records the event;
        // any matching live connection accumulates the wire bytes.
        for (e.target_sids) |target_sid| {
            const ring = try tenant.getOrCreateRing(allocator, target_sid);
            const entry = RingEntry{
                .event_id = e.event_id,
                .event_type = try allocator.dupe(u8, e.event_type),
                .data_json = try allocator.dupe(u8, e.data_json),
            };
            ring.append(allocator, entry);

            for (tenant.connections.items) |conn| {
                if (!std.mem.eql(u8, conn.sid, target_sid)) continue;
                if (!server.reg.isInCollection(conn.stream_ent, &server.stream_data_out)) continue;
                const buf_entry = try conn_buffers.getOrPut(allocator, conn);
                if (!buf_entry.found_existing) buf_entry.value_ptr.* = .empty;
                try formatEventFrameInto(
                    buf_entry.value_ptr,
                    allocator,
                    &e.event_id,
                    e.event_type,
                    e.data_json,
                );
                try conn_last_event.put(allocator, conn, e.event_id);
            }
        }
    }

    // Flush each conn's accumulated bytes — one set+move per conn.
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var it = conn_buffers.iterator();
    while (it.next()) |entry| {
        const conn = entry.key_ptr.*;
        const buf = entry.value_ptr;
        if (buf.items.len == 0) continue;
        const owned = try buf.toOwnedSlice(allocator);
        // Buf is now empty; the slot below assumes ownership of
        // `owned`. Errors after `set` need to null the slot before
        // freeing so the entity's eventual deinit doesn't double-free.
        server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
            .data = owned.ptr,
            .len = @intCast(owned.len),
        }) catch |err| {
            allocator.free(owned);
            return err;
        };
        server.reg.move(conn.stream_ent, &server.stream_data_out, &server.stream_data_in) catch |err| {
            server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
                .data = null,
                .len = 0,
            }) catch {};
            allocator.free(owned);
            return err;
        };
        conn.last_send_ns = now_ns;
        if (conn_last_event.get(conn)) |last_id| conn.last_event_id = last_id;
    }

    try setSimpleResponse(server, ent, sid, sess, 204, "");
}

const ParsedEvent = struct {
    event_id: [EVENT_ID_LEN]u8,
    event_type: []const u8,
    data_json: []const u8,
    target_sids: []const []const u8,
};

const ParsedEmit = struct {
    tenant_id: []const u8,
    events: []const ParsedEvent,
    /// Backing buffer for all the borrowed slices above.
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *const ParsedEmit, _: std.mem.Allocator) void {
        var arena = self.arena;
        arena.deinit();
    }
};

/// Decode the worker → sse-server emit body. v1 wire format
/// (sse-plan §2.2) is small and stable; we use std.json.parseFromSlice
/// so the schema can grow without us hand-rolling everything.
fn parseEmitBody(allocator: std.mem.Allocator, body: []const u8) !ParsedEmit {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const Wire = struct {
        v: u32 = 1,
        tenant_id: []const u8 = "",
        request_id: u64 = 0,
        events: []const struct {
            event_id: []const u8 = "",
            type: []const u8 = "message",
            data: std.json.Value = .null,
            target_sids: []const []const u8 = &.{},
            created_at_ms: i64 = 0,
        } = &.{},
    };

    const parsed = std.json.parseFromSliceLeaky(Wire, arena_allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedBody;
    if (parsed.tenant_id.len == 0) return error.MalformedBody;

    var events = try arena_allocator.alloc(ParsedEvent, parsed.events.len);
    for (parsed.events, 0..) |w, i| {
        if (w.event_id.len != EVENT_ID_LEN) return error.MalformedBody;
        var ev: ParsedEvent = .{
            .event_id = undefined,
            .event_type = w.type,
            .data_json = try jsonValueToString(arena_allocator, w.data),
            .target_sids = w.target_sids,
        };
        @memcpy(&ev.event_id, w.event_id[0..EVENT_ID_LEN]);
        events[i] = ev;
    }
    return .{
        .tenant_id = parsed.tenant_id,
        .events = events,
        .arena = arena,
    };
}

/// Render a parsed `data` field back to compact JSON for the wire
/// `data:` line. Strings stay as JSON strings (with surrounding quotes)
/// so `data: "hello"` is wire-valid; objects/arrays render compact.
fn jsonValueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    {
        // Block scope so the writer's internal list syncs back into
        // `out` BEFORE `toOwnedSlice` reads from it. Without this the
        // returned slice is empty and the bytes leak (the same bug
        // sse_dispatch.encodeBatch fixed).
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
        defer out = aw.toArrayList();
        try std.json.Stringify.value(v, .{}, &aw.writer);
    }
    return out.toOwnedSlice(allocator);
}

// ── EventSource connect ───────────────────────────────────────────

fn handleSseConnect(
    server: *SseH2,
    allocator: std.mem.Allocator,
    state: *ServerState,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    query: []const u8,
    last_event_id_hdr: []const u8,
) !void {
    const secret = cfg.jwt_secret orelse {
        try setSimpleResponse(server, ent, sid, sess, 401, "auth not configured\n");
        return;
    };

    const token = extractQueryParam(query, "token") orelse {
        try setSimpleResponse(server, ent, sid, sess, 401, "missing token\n");
        return;
    };

    var payload_buf: [512]u8 = undefined;
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const payload = jwt.verifyAndCopyPayload(secret, token, now_ms, &payload_buf) catch |err| {
        const msg = switch (err) {
            jwt.Error.Expired => "token expired\n",
            jwt.Error.BadSignature => "bad signature\n",
            jwt.Error.Malformed, jwt.Error.UnsupportedAlg => "malformed token\n",
            else => "auth failed\n",
        };
        try setSimpleResponse(server, ent, sid, sess, 401, msg);
        return;
    };

    // tenant_id in the URL must match the JWT — otherwise a token
    // minted for tenant A could subscribe to tenant B's events.
    const claim_tenant = extractJsonStringField(payload, "tenant_id") orelse {
        try setSimpleResponse(server, ent, sid, sess, 401, "token missing tenant_id\n");
        return;
    };
    if (!std.mem.eql(u8, claim_tenant, tenant_id)) {
        try setSimpleResponse(server, ent, sid, sess, 403, "tenant mismatch\n");
        return;
    }
    const claim_sid = extractJsonStringField(payload, "sid") orelse {
        try setSimpleResponse(server, ent, sid, sess, 401, "token missing sid\n");
        return;
    };

    const tenant = try state.getOrCreateTenant(tenant_id);
    if (tenant.connections.items.len >= cfg.max_connections_per_tenant) {
        try setSimpleResponse(server, ent, sid, sess, 503, "tenant connection cap reached\n");
        return;
    }

    // Headers: text/event-stream + cache-control: no-store + CORS.
    //
    // Browsers DO enforce CORS on EventSource — "withCredentials:
    // false" only skips the preflight, but the browser still checks
    // the response's `Access-Control-Allow-Origin` header before
    // letting JS read the stream. `*` is safe here because:
    //   - the JWT in `?token=` is the auth boundary (not cookies),
    //   - withCredentials: false → no cookie / Authorization header
    //     leaks regardless of origin,
    //   - the path itself encodes the tenant, and the JWT's
    //     tenant_id claim must match (validated above).
    // (sse-plan §4.2 said this wasn't needed; fixing here, doc to
    // be reconciled.)
    const pairs = [_]HdrPair{
        .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-accel-buffering", .value = "no" },
        .{ .name = "access-control-allow-origin", .value = "*" },
    };
    const hdrs = try packHeaders(allocator, &pairs);

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 200 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.stream_response_in);

    const conn = try allocator.create(Connection);
    errdefer allocator.destroy(conn);
    const sid_owned = try allocator.dupe(u8, claim_sid);
    errdefer allocator.free(sid_owned);
    conn.* = .{
        .stream_ent = ent,
        .sid = sid_owned,
        .last_send_ns = @intCast(std.time.nanoTimestamp()),
        .last_event_id = null,
    };
    try tenant.connections.append(allocator, conn);

    // Last-Event-ID resume: header takes precedence over ?last_event_id.
    const resume_id_raw: ?[]const u8 = if (last_event_id_hdr.len > 0)
        last_event_id_hdr
    else
        extractQueryParam(query, "last_event_id");
    if (resume_id_raw) |raw| {
        if (raw.len == EVENT_ID_LEN) {
            try queueResumePayload(server, allocator, tenant, conn, raw);
        } else {
            // Malformed cursor → treat as evicted: deliver sentinel on
            // the first chunk so the client refetches state.
            try queueSentinelPayload(server, allocator, conn);
        }
    }
}

/// Build the catch-up payload for a reconnecting client. If the cursor
/// is in the ring, every entry strictly after it becomes a frame; if
/// the cursor isn't found (evicted, or fresh process), send the
/// `rove:resync` sentinel.
fn queueResumePayload(
    server: *SseH2,
    allocator: std.mem.Allocator,
    tenant: *TenantState,
    conn: *Connection,
    cursor: []const u8,
) !void {
    const ring = tenant.rings.get(conn.sid) orelse {
        try queueSentinelPayload(server, allocator, conn);
        return;
    };
    if (!ring.contains(cursor)) {
        try queueSentinelPayload(server, allocator, conn);
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const start: usize = if (ring.count == RING_CAPACITY) ring.write_pos else 0;
    var n: usize = 0;
    var past_cursor = false;
    var last_id_seen: [EVENT_ID_LEN]u8 = undefined;
    while (n < ring.count) : (n += 1) {
        const idx = (start + n) % RING_CAPACITY;
        const e = &ring.entries[idx];
        if (!past_cursor) {
            if (std.mem.eql(u8, &e.event_id, cursor)) past_cursor = true;
            continue;
        }
        try formatEventFrameInto(&out, allocator, &e.event_id, e.event_type, e.data_json);
        last_id_seen = e.event_id;
    }
    if (out.items.len == 0) return;
    const owned = try out.toOwnedSlice(allocator);
    try queueChunkOnEntity(server, allocator, conn, owned);
    conn.last_event_id = last_id_seen;
    conn.last_send_ns = @intCast(std.time.nanoTimestamp());
}

fn queueSentinelPayload(
    server: *SseH2,
    allocator: std.mem.Allocator,
    conn: *Connection,
) !void {
    const owned = try allocator.dupe(u8, SENTINEL_FRAME);
    try queueChunkOnEntity(server, allocator, conn, owned);
    conn.last_send_ns = @intCast(std.time.nanoTimestamp());
}

/// Stage `chunk` (owned by allocator) on the connection's h2 entity.
/// At connect time the entity sits in `stream_response_in` (h2 hasn't
/// flushed headers yet) — we can't push body until h2 parks it in
/// `stream_data_out`. Stash the chunk on the connection so the next
/// pump tick that sees the entity parked will write it.
fn queueChunkOnEntity(
    server: *SseH2,
    allocator: std.mem.Allocator,
    conn: *Connection,
    chunk: []u8,
) !void {
    if (server.reg.isInCollection(conn.stream_ent, &server.stream_data_out)) {
        try server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
            .data = chunk.ptr,
            .len = @intCast(chunk.len),
        });
        try server.reg.move(conn.stream_ent, &server.stream_data_out, &server.stream_data_in);
        return;
    }
    // h2 hasn't parked the entity yet; the keepalive pump will pick it
    // up next tick. Stash via a side-channel on the connection.
    if (conn.pending_chunk) |old| allocator.free(old);
    conn.pending_chunk = chunk;
}

fn pumpKeepalives(server: *SseH2, allocator: std.mem.Allocator, state: *ServerState) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var it = state.tenants.iterator();
    while (it.next()) |entry| {
        const tenant = entry.value_ptr.*;
        for (tenant.connections.items) |conn| {
            if (!server.reg.isInCollection(conn.stream_ent, &server.stream_data_out)) continue;
            // First, drain any pending chunk staged at connect time
            // (resume payload or sentinel) — h2 only just now parked
            // the entity, so we can finally write it.
            if (conn.pending_chunk) |chunk| {
                conn.pending_chunk = null;
                try server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
                    .data = chunk.ptr,
                    .len = @intCast(chunk.len),
                });
                try server.reg.move(conn.stream_ent, &server.stream_data_out, &server.stream_data_in);
                conn.last_send_ns = now_ns;
                continue;
            }
            if (now_ns - conn.last_send_ns < KEEPALIVE_INTERVAL_NS) continue;
            const ping = try allocator.dupe(u8, ":keepalive\n\n");
            try server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
                .data = ping.ptr,
                .len = @intCast(ping.len),
            });
            try server.reg.move(conn.stream_ent, &server.stream_data_out, &server.stream_data_in);
            conn.last_send_ns = now_ns;
        }
    }
}

fn cleanupClosedConnections(server: *SseH2, state: *ServerState) !void {
    const closed = server.response_out.entitySlice();
    if (closed.len == 0) return;
    var it = state.tenants.iterator();
    while (it.next()) |entry| {
        const tenant = entry.value_ptr.*;
        if (tenant.connections.items.len == 0) continue;
        for (closed) |ent| {
            var i: usize = 0;
            while (i < tenant.connections.items.len) {
                const c = tenant.connections.items[i];
                if (c.stream_ent.eql(ent)) {
                    if (c.pending_chunk) |chunk| state.allocator.free(chunk);
                    state.allocator.free(c.sid);
                    state.allocator.destroy(c);
                    _ = tenant.connections.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
}

// ── Wire helpers ──────────────────────────────────────────────────

/// Build one SSE wire frame: `id:` + `event:` + `data:` + blank line.
/// Caller frees with `allocator.free`.
fn formatEventFrame(
    allocator: std.mem.Allocator,
    event_id: *const [EVENT_ID_LEN]u8,
    event_type: []const u8,
    data_json: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try formatEventFrameInto(&out, allocator, event_id, event_type, data_json);
    return out.toOwnedSlice(allocator);
}

fn formatEventFrameInto(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    event_id: *const [EVENT_ID_LEN]u8,
    event_type: []const u8,
    data_json: []const u8,
) !void {
    try out.appendSlice(allocator, "id: ");
    try out.appendSlice(allocator, event_id);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "event: ");
    try out.appendSlice(allocator, event_type);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "data: ");
    // Newlines in `data:` need explicit per-line repetition per the
    // SSE spec; `data_json` is compact JSON so this is one line.
    try out.appendSlice(allocator, data_json);
    try out.appendSlice(allocator, "\n\n");
}

fn extractQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return pair[eq + 1 ..];
    }
    return null;
}

/// Pull a string-typed JSON field out of the verified token payload.
/// Tight hand-coded reader so connect doesn't pay std.json's setup
/// cost on every EventSource open.
fn extractJsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    needle_buf[2 + key.len] = ':';
    const needle = needle_buf[0 .. 3 + key.len];
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        if (json[i] == '\\') i += 1;
    }
    if (i >= json.len) return null;
    return json[start..i];
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ── h2 response helpers ───────────────────────────────────────────

const HdrPair = struct { name: []const u8, value: []const u8 };

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

fn setSimpleResponse(
    server: *SseH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_static: []const u8,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = null,
        .len = @intCast(body_static.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseRoute matches /v1/health" {
    const r = parseRoute("/v1/health").?;
    try testing.expectEqual(RouteKind.health, r.kind);
}

test "parseRoute matches /v1/emit" {
    const r = parseRoute("/v1/emit").?;
    try testing.expectEqual(RouteKind.emit, r.kind);
}

test "parseRoute matches /v1/{tenant}/sse with query" {
    const r = parseRoute("/v1/acme/sse?token=abc").?;
    try testing.expectEqual(RouteKind.sse, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("token=abc", r.query);
}

test "parseRoute rejects bad shapes" {
    try testing.expect(parseRoute("/") == null);
    try testing.expect(parseRoute("/v2/health") == null);
    try testing.expect(parseRoute("/v1/") == null);
    try testing.expect(parseRoute("/v1/acme") == null);
    try testing.expect(parseRoute("/v1/acme/foo") == null);
    try testing.expect(parseRoute("/v1//sse") == null);
}

test "extractQueryParam basic" {
    try testing.expectEqualStrings("xyz", extractQueryParam("token=xyz", "token").?);
    try testing.expectEqualStrings("xyz", extractQueryParam("a=1&token=xyz&b=2", "token").?);
    try testing.expect(extractQueryParam("a=1", "token") == null);
}

test "extractJsonStringField pulls tenant_id and sid" {
    const json = "{\"v\":1,\"tenant_id\":\"acme\",\"sid\":\"abc123\",\"exp\":1000}";
    try testing.expectEqualStrings("acme", extractJsonStringField(json, "tenant_id").?);
    try testing.expectEqualStrings("abc123", extractJsonStringField(json, "sid").?);
    try testing.expect(extractJsonStringField(json, "missing") == null);
}

test "Ring append + eviction + contains" {
    const a = testing.allocator;
    var ring: Ring = .{};
    defer ring.deinit(a);

    var i: usize = 0;
    while (i < RING_CAPACITY + 5) : (i += 1) {
        var event_id: [EVENT_ID_LEN]u8 = undefined;
        _ = std.fmt.bufPrint(&event_id, "{:0>20}-{:0>6}", .{ i, 0 }) catch unreachable;
        ring.append(a, .{
            .event_id = event_id,
            .event_type = try a.dupe(u8, "msg"),
            .data_json = try a.dupe(u8, "{}"),
        });
    }
    try testing.expectEqual(@as(usize, RING_CAPACITY), ring.count);

    // Earliest 5 evicted; entries 5..(5+RING_CAPACITY) survive.
    var probe_old: [EVENT_ID_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&probe_old, "{:0>20}-{:0>6}", .{ 0, 0 }) catch unreachable;
    try testing.expect(!ring.contains(&probe_old));

    var probe_present: [EVENT_ID_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&probe_present, "{:0>20}-{:0>6}", .{ 5, 0 }) catch unreachable;
    try testing.expect(ring.contains(&probe_present));
}

test "parseEmitBody round-trips data field as compact JSON" {
    const a = testing.allocator;
    const body =
        \\{"v":1,"tenant_id":"acme","request_id":42,"events":[
        \\  {"event_id":"00000000000000000042-000000",
        \\   "type":"comment_added",
        \\   "data":{"id":99},
        \\   "target_sids":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
        \\   "created_at_ms":1730764800000}
        \\]}
    ;
    var parsed = try parseEmitBody(a, body);
    defer parsed.deinit(a);
    try testing.expectEqual(@as(usize, 1), parsed.events.len);
    // The smoke caught a bug here once: jsonValueToString returned ""
    // because the writer-list sync defer ran after toOwnedSlice. Keep
    // this expectation tight so it can't silently regress.
    try testing.expectEqualStrings("{\"id\":99}", parsed.events[0].data_json);
}

test "formatEventFrame shape" {
    const a = testing.allocator;
    var event_id: [EVENT_ID_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&event_id, "{:0>20}-{:0>6}", .{ 1, 0 }) catch unreachable;
    const out = try formatEventFrame(a, &event_id, "comment_added", "{\"id\":99}");
    defer a.free(out);
    try testing.expectEqualStrings(
        "id: 00000000000000000001-000000\nevent: comment_added\ndata: {\"id\":99}\n\n",
        out,
    );
}
