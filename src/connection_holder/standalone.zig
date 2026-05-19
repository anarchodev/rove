//! connection-holder standalone — h2 listener + connection table +
//! readiness queue. See `docs/connection-actor-plan.md`.
//!
//! Phase 1 scope (this file): stand up the subsystem, accept a held
//! connection, park its h2 request entity (the stream stays open, the
//! client waits), record it in the connection table keyed by a
//! serializable connection-id, and arm a holder-level deadline so a
//! parked connection cannot hang forever. The deadline sweep resolving
//! a 504 is the primitive form of the plan §6.4 *mandatory `timeout`
//! wake* — Phase 3 turns it into a real wake into the JS handler;
//! Phase 1 keeps it holder-level so the skeleton has a correct
//! lifecycle and is exercisable on its own.
//!
//! Routes:
//!   GET  /v1/health           → 200 "ok\n" (LB health check).
//!   *    /v1/{tenant}/hold     → park the connection. No response is
//!                                sent; the stream is held until the
//!                                deadline (Phase 1) or a resolving
//!                                wake (Phase 3).
//!
//! Single-process for v1 (plan §5 failover contract / sse-plan §4.6):
//! on holder restart the socket dies, the client retries, and in-flight
//! frontier / pending frames / timers are lost. Durable application
//! state is the handler's composition; connection bookkeeping is
//! best-effort by design.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const blob_curl = @import("rove-blob").curl;
const wake_dispatch = @import("wake_dispatch.zig");

const HolderH2 = h2.H2(.{});

/// A connection-id is the serializable handle the plan §1 describes —
/// a *different* future wake (an `http.send` callback, §6.4) can pend
/// writes to the same connection by this id. Monotonic per process;
/// not reused within a process lifetime so a stale callback addressed
/// at a closed connection is detectably stale (resolve-once, Phase 3).
pub const ConnId = u64;

/// Wake reasons (plan §3). Phase 1 only ever produces `timeout` (the
/// holder-level deadline sweep); the rest are defined now so the
/// readiness queue and dispatcher (Phase 2) don't change shape when
/// the other producers land.
pub const WakeReason = enum { open, message, signal, timeout, close };

/// Random-handle width. 16 bytes = 128 bits of CSPRNG entropy, hex
/// to 32 chars. The *externally-visible* handle is this token — NOT
/// the monotonic `ConnId` (which never leaves the holder). Layer 1 of
/// the cross-tenant isolation model: a handle is unguessable, so it
/// cannot be enumerated across tenants. It is a taped input when a
/// wake surfaces it to the handler (same class as a sid — plan §2).
pub const HANDLE_BYTES: usize = 16;
pub const HANDLE_HEX_LEN: usize = HANDLE_BYTES * 2;
pub const ConnHandle = [HANDLE_HEX_LEN]u8;

/// Errors from the owning-tenant chokepoint (layer 2). Every handle
/// operation routes through `resolveOwned`, so a foreign-tenant or
/// stale handle fails loud here rather than silently acting on
/// another tenant's socket.
pub const HolderError = error{ UnknownHandle, TenantMismatch };

/// Mint an unguessable handle. `std.crypto.random` is the OS CSPRNG;
/// the handle is assigned by the holder (an external identity, like a
/// sid), so it is not part of replay determinism — it becomes a taped
/// input only when a wake carries it to the handler.
fn mintHandle() ConnHandle {
    var raw: [HANDLE_BYTES]u8 = undefined;
    std.crypto.random.bytes(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Constant-time slice compare for the internal bearer (layer 3) —
/// mirrors sse-server's `constantTimeEql`.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Layer 3: a privileged (connection-mutating) request must carry the
/// internal bearer. The secret lives only in worker process env
/// (`CONN_HOLDER_INTERNAL_TOKEN`), never surfaced to QJS — so a
/// customer handler, which can `http.send` anywhere, still cannot
/// forge a wake-ack / resolve. Null config → privileged routes 401
/// (lets a smoke spin up without auth, mirroring sse-server).
fn internalAuthOk(cfg: *const Config, authz: []const u8) bool {
    const expected = cfg.internal_token orelse return false;
    if (!std.mem.startsWith(u8, authz, "Bearer ")) return false;
    return constantTimeEql(authz["Bearer ".len..], expected);
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Where to bind the h2 listener. Port `0` → ephemeral; the
    /// resolved port is written to `Handle.port`.
    bind_addr: std.net.Address,
    /// h2 connection cap (transport-level).
    max_connections: u32 = 1024,
    /// TLS config — when set, the listener does TLS termination via
    /// rove-h2's standard path. Null = h2c (smoke driver path).
    tls_config: ?*h2.TlsConfig = null,
    /// Hard cap on simultaneously *parked* connections across all
    /// tenants. The (cap+1)th park is refused 503. Plan §6.4 calls
    /// this load-bearing: held-synchrony silently reintroduces the
    /// synchronous-proxy resource model, so the cap is mandatory, not
    /// an optimization.
    max_held_total: u32 = 4096,
    /// Per-tenant parked-connection cap. Defends one tenant from
    /// exhausting the global pool.
    max_held_per_tenant: u32 = 1024,
    /// Holder-level hold deadline. A parked connection with no
    /// resolving wake by this long after accept is resolved with a
    /// 504. Plan §6.4: this must be < the minimum intermediary
    /// timeout (browser / LB / CDN, often <60s) so a real
    /// 504-class response goes out before any of them give up.
    default_hold_deadline_ms: i64 = 25_000,
    /// Layer 3 shared bearer for the worker → holder privileged
    /// channel (wake-ack / resolve). Held only in worker process env
    /// (`CONN_HOLDER_INTERNAL_TOKEN`); never reachable from QJS. Null
    /// → privileged routes 401.
    internal_token: ?[]const u8 = null,
    /// Worker origin the `open` wake is forwarded to (the §6.1
    /// degenerate path), e.g. `http://127.0.0.1:8080`. Null → the
    /// wake is dropped through the counted sink (2a behaviour: the
    /// connection then resolves via its deadline). The forwarded
    /// request carries the internal bearer so the worker can treat it
    /// as platform-originated.
    worker_base: ?[]const u8 = null,
    /// Skip TLS verification on the holder→worker hop. Dev/smoke
    /// only; the worker is a private-network peer in production.
    worker_insecure_tls: bool = false,
    /// Timeout for the synchronous holder→worker forward. The wake
    /// runs the tenant handler + its raft propose, so this is larger
    /// than sse-emit's 1 s; still bounded so a wedged worker can't
    /// pin the holder thread past it (the deadline then 504s).
    worker_timeout_ms: u32 = 15_000,
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
        std.log.err("connection-holder: thread exited: {s}", .{@errorName(err)});
    };
}

fn runThread(h: *Handle) !void {
    const allocator = h.allocator;

    var reg = rove.Registry.init(allocator, .{
        .max_entities = 8192,
        .deferred_queue_capacity = 2048,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer reg.deinit();

    const server = HolderH2.create(&reg, allocator, h.config.bind_addr, .{
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
        std.log.info("connection-holder: h2 (TLS) on port {d}", .{h.port});
    } else {
        std.log.info("connection-holder: h2c on 127.0.0.1:{d}", .{h.port});
    }

    var state: HolderState = .init(allocator, &h.config);
    defer state.deinit();

    // One libcurl easy handle for the holder→worker forward. Not
    // thread-safe, but the holder is single-threaded (the loop
    // below), same as schedule-server's owned handle. Only created
    // when a worker is configured; otherwise wakes fall to the 2a
    // counted sink and the deadline resolves the connection.
    const easy: ?*blob_curl.Easy = if (h.config.worker_base != null)
        blob_curl.Easy.init(allocator) catch |err| blk: {
            std.log.warn("connection-holder: curl init failed: {s}; wakes will 504 at deadline", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    defer if (easy) |e| e.deinit();

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(server, &state);
        try reg.flush();
        state.drainReadiness(server, easy);
        try reg.flush();
        try sweepDeadlines(server, &state);
        try reg.flush();
        try cleanupClosedConnections(server, &state);
        try cleanupResponses(server);
        try reg.flush();
    }

    state.dropAll();
}

fn resolveBoundPort(server: *HolderH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

fn cleanupResponses(server: *HolderH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

// ── Connection table + readiness queue ─────────────────────────────

/// One held connection. Owns its `tenant_id` slice and its
/// `pending` buffer. The plan §1/§5 primitive-level state lives here:
/// the consumed inbound frontier cursor, the pending-write buffer
/// (flushed post-commit, Phase 2+), the armed timer (the holder-level
/// `deadline_ns` for Phase 1), and the version counter (resolve-once,
/// Phase 3). Phase 1 populates the lifecycle fields; the frontier /
/// pending machinery is present-but-inert until later phases drive it.
const Connection = struct {
    id: ConnId,
    /// The unguessable external handle. A wake carries this to the
    /// handler; a later wake (an http.send callback, §6.4) addresses
    /// the connection by it. The monotonic `id` above is holder-only
    /// and never leaves the process.
    handle: ConnHandle,
    /// The parked h2 request entity. It physically stays in
    /// `server.request_out` (an in-chain intermediate collection — the
    /// stream is held open, the client waits). `processRequests`
    /// skips it because it is in the table; resolving moves it
    /// `request_out → response_in`.
    stream_ent: rove.Entity,
    /// Captured at park time so a *later* wake can build the response
    /// without re-reading the request.
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []u8,
    /// Inbound frontier — per-connection consumed cursor (plan §1).
    /// Inert in Phase 1 (the held-sync projection has no client
    /// inbound after the request); Phase 2+ advances it on reads.
    consumed_cursor: u64 = 0,
    /// Pending-write buffer (plan §1) — bytes a wake pends, flushed to
    /// the socket only after the wake's raft propose applies. Inert in
    /// Phase 1; owned by `allocator`.
    pending: std.ArrayListUnmanaged(u8) = .empty,
    /// Armed timer: absolute deadline. Phase 1 = holder-level hold
    /// deadline; Phase 3 = the §6.4 mandatory `timeout` wake.
    deadline_ns: i64,
    /// Resolve-once guard (plan §6.4). Phase 3 hooks this into the
    /// existing http.send / callback version-counter idempotency
    /// defense; Phase 1 just stamps it at accept.
    version: u64 = 0,
    accepted_ns: i64,
    /// The frozen input snapshot for the `open` wake (plan §1) — the
    /// connect request, captured + owned at park time so the wake can
    /// replay it to a worker without re-reading the (recyclable) h2
    /// buffers. Degenerate §6.1: this IS the request the base-case
    /// handler runs. Full header pass-through is a later refinement;
    /// 2b carries method/path/body/content-type, which is enough for
    /// the chain-length-one proof.
    req_method: []u8,
    req_path: []u8,
    req_body: []u8,
    req_ctype: []u8,
    /// The wake reason currently armed for this connection, if any.
    /// Readiness is collection membership (the `ready` queue, plan
    /// §3); this field is the per-connection coalescing latch so a
    /// burst doesn't enqueue N duplicate wakes (plan §3 "edge-
    /// triggered and coalesced"). null = no wake outstanding.
    pending_wake: ?WakeReason = null,

    fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        allocator.free(self.tenant_id);
        allocator.free(self.req_method);
        allocator.free(self.req_path);
        allocator.free(self.req_body);
        allocator.free(self.req_ctype);
    }
};

/// A pending wake. Readiness is collection membership (plan §3): a
/// connection is "ready" iff it is in this queue. The dispatcher
/// (Phase 2) drains it; it is never an O(N-connections) per-tick scan.
const Ready = struct {
    id: ConnId,
    reason: WakeReason,
};

const HolderState = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    /// The connection table, keyed by the serializable connection-id.
    conns: std.AutoHashMapUnmanaged(ConnId, *Connection) = .empty,
    /// Reverse index entity → id, so `processRequests` can skip an
    /// already-parked entity and `cleanupClosedConnections` can map a
    /// closed h2 entity back to its connection without scanning.
    by_entity: std.AutoHashMapUnmanaged(rove.Entity, ConnId) = .empty,
    /// Handle → id. The chokepoint (`resolveOwned`) looks up here, so
    /// every cross-process op names a connection by its unguessable
    /// handle, never by the holder-internal id.
    by_handle: std.AutoHashMapUnmanaged(ConnHandle, ConnId) = .empty,
    /// Wakes handed to the dispatch sink. 2a's sink is counted-noop
    /// (the real worker channel is 2b); the counter makes the wake
    /// state machine observable in tests without the cross-process leg.
    wakes_dispatched: u64 = 0,
    /// Per-tenant parked count, for the per-tenant cap. Keyed by an
    /// owned tenant_id slice (freed when the count hits zero).
    per_tenant: std.StringHashMapUnmanaged(u32) = .empty,
    /// Readiness queue (plan §3 collection membership).
    ready: std.ArrayListUnmanaged(Ready) = .empty,
    /// Monotonic id source; never reuses an id within the process.
    next_id: ConnId = 1,
    /// Cached soonest deadline across all parked connections. The
    /// per-tick check is O(1) against this; the O(parked) recompute
    /// runs only when something actually expires. Honors the
    /// no-O(N)-on-the-hot-path rule for the common (nothing-expired)
    /// case. `maxInt` = "no parked connection".
    next_deadline_ns: i64 = std.math.maxInt(i64),

    fn init(allocator: std.mem.Allocator, config: *const Config) HolderState {
        return .{ .allocator = allocator, .config = config };
    }

    fn deinit(self: *HolderState) void {
        var it = self.conns.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(e.value_ptr.*);
        }
        self.conns.deinit(self.allocator);
        self.by_entity.deinit(self.allocator);
        self.by_handle.deinit(self.allocator);
        var pt = self.per_tenant.iterator();
        while (pt.next()) |e| self.allocator.free(e.key_ptr.*);
        self.per_tenant.deinit(self.allocator);
        self.ready.deinit(self.allocator);
    }

    /// Layer 2 — the single owning-tenant chokepoint. Resolve a
    /// handle to its connection and reject it unless `claimed_tenant`
    /// is exactly the connection's owning tenant. EVERY handle op
    /// (resolve, pend-write, cancel, arm-timer, frontier-read) must go
    /// through here; that is what stops tenant B from acting on tenant
    /// A's socket even past layers 1 and 3.
    fn resolveOwned(self: *HolderState, handle: []const u8, claimed_tenant: []const u8) HolderError!*Connection {
        if (handle.len != HANDLE_HEX_LEN) return error.UnknownHandle;
        var key: ConnHandle = undefined;
        @memcpy(&key, handle[0..HANDLE_HEX_LEN]);
        const id = self.by_handle.get(key) orelse return error.UnknownHandle;
        const conn = self.conns.get(id) orelse return error.UnknownHandle;
        if (!std.mem.eql(u8, conn.tenant_id, claimed_tenant)) return error.TenantMismatch;
        return conn;
    }

    fn tenantCount(self: *HolderState, tenant_id: []const u8) u32 {
        return self.per_tenant.get(tenant_id) orelse 0;
    }

    /// Insert a parked connection. Caller has already enforced the
    /// caps. Takes ownership of `conn` (heap-allocated by the caller).
    fn track(self: *HolderState, conn: *Connection) !void {
        try self.conns.put(self.allocator, conn.id, conn);
        errdefer _ = self.conns.remove(conn.id);
        try self.by_entity.put(self.allocator, conn.stream_ent, conn.id);
        errdefer _ = self.by_entity.remove(conn.stream_ent);
        try self.by_handle.put(self.allocator, conn.handle, conn.id);
        errdefer _ = self.by_handle.remove(conn.handle);

        const gop = try self.per_tenant.getOrPut(self.allocator, conn.tenant_id);
        if (!gop.found_existing) {
            // Own a stable key copy — `conn.tenant_id` is freed when
            // the connection is dropped, which may outlive the count.
            gop.key_ptr.* = try self.allocator.dupe(u8, conn.tenant_id);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;

        if (conn.deadline_ns < self.next_deadline_ns) {
            self.next_deadline_ns = conn.deadline_ns;
        }
    }

    /// Drop a tracked connection: unlink from every index, decrement
    /// the per-tenant count (freeing the key at zero), and free the
    /// connection itself. Does NOT touch the h2 entity — the caller
    /// decides whether to resolve it or let h2 reap a closed stream.
    fn drop(self: *HolderState, id: ConnId) void {
        const conn = self.conns.get(id) orelse return;
        _ = self.conns.remove(id);
        _ = self.by_entity.remove(conn.stream_ent);
        _ = self.by_handle.remove(conn.handle);
        if (self.per_tenant.getEntry(conn.tenant_id)) |e| {
            e.value_ptr.* -= 1;
            if (e.value_ptr.* == 0) {
                const key = e.key_ptr.*;
                _ = self.per_tenant.remove(conn.tenant_id);
                self.allocator.free(key);
            }
        }
        conn.deinit(self.allocator);
        self.allocator.destroy(conn);
    }

    /// Arm a wake (plan §3): edge-triggered and coalesced. If a wake
    /// is already outstanding for this connection the readiness edge
    /// is absorbed — no duplicate queue entry — because readiness is
    /// membership, not a count. A 50-message burst is one wake.
    fn armWake(self: *HolderState, conn: *Connection, reason: WakeReason) !void {
        if (conn.pending_wake != null) return;
        conn.pending_wake = reason;
        try self.ready.append(self.allocator, .{ .id = conn.id, .reason = reason });
    }

    /// Drain the readiness queue. For the `open` wake (plan §6.1),
    /// when transport + a worker are configured, forward the captured
    /// request to the worker and flush its response onto the held
    /// socket (chain-length-one: the connection resolves and closes
    /// in this tick). Dispatching clears the per-conn latch so the
    /// next readiness edge re-arms (plan §3). O(ready), never
    /// O(connections).
    ///
    /// `server`/`easy` are optional: null (unit tests, or no worker
    /// configured) keeps the 2a counted-noop semantics — the latch
    /// clears, the counter ticks, and the connection then resolves
    /// via its deadline. A failed forward also falls through to the
    /// deadline (the connection is NOT dropped), so a wedged worker
    /// degrades to a 504 rather than a hung socket.
    fn drainReadiness(self: *HolderState, server: ?*HolderH2, easy: ?*blob_curl.Easy) void {
        for (self.ready.items) |r| {
            // A connection can be dropped (client gone / deadline)
            // between arming and drain — skip a stale entry.
            const conn = self.conns.get(r.id) orelse continue;
            conn.pending_wake = null;
            self.wakes_dispatched += 1;

            if (r.reason != .open) continue; // only open is wired in 2b
            const srv = server orelse continue;
            const e = easy orelse continue;
            const wb = self.config.worker_base orelse continue;
            fireOpenWake(self, srv, e, wb, conn) catch |err| {
                std.log.warn(
                    "connection-holder: conn {d}: open wake failed: {s} (will 504 at deadline)",
                    .{ conn.id, @errorName(err) },
                );
            };
        }
        self.ready.clearRetainingCapacity();
    }

    /// Recompute `next_deadline_ns` from scratch — O(parked), run
    /// only after an expiry actually fired (rare), never per tick.
    fn recomputeNextDeadline(self: *HolderState) void {
        var soonest: i64 = std.math.maxInt(i64);
        var it = self.conns.valueIterator();
        while (it.next()) |c| {
            if (c.*.deadline_ns < soonest) soonest = c.*.deadline_ns;
        }
        self.next_deadline_ns = soonest;
    }

    /// Cleanup hook before thread exit — drop all owned connection
    /// records. The h2 entities get torn down by `server.destroy()`.
    fn dropAll(self: *HolderState) void {
        var it = self.conns.valueIterator();
        while (it.next()) |c| {
            c.*.deinit(self.allocator);
            self.allocator.destroy(c.*);
        }
        self.conns.clearRetainingCapacity();
        self.by_entity.clearRetainingCapacity();
        self.by_handle.clearRetainingCapacity();
        var pt = self.per_tenant.iterator();
        while (pt.next()) |e| self.allocator.free(e.key_ptr.*);
        self.per_tenant.clearRetainingCapacity();
        self.ready.clearRetainingCapacity();
        self.next_deadline_ns = std.math.maxInt(i64);
    }
};

// ── Request dispatch ───────────────────────────────────────────────

fn processRequests(server: *HolderH2, state: *HolderState) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        // Skip an entity that is already parked — it physically stays
        // in `request_out` (held stream), so it re-appears here every
        // tick until a resolving wake moves it on. Table membership IS
        // the "already parked" state (collection-membership, not a
        // flag on the entity).
        if (state.by_entity.contains(ent)) continue;

        handleOne(server, state, ent, sid, sess, rh, rb) catch |err| {
            std.log.warn("connection-holder: handler error: {s}", .{@errorName(err)});
            setSimpleResponse(server, ent, sid, sess, 500, "internal error\n") catch |se| std.log.err(
                "connection-holder: 500 write failed: {s}",
                .{@errorName(se)},
            );
        };
    }
}

fn handleOne(
    server: *HolderH2,
    state: *HolderState,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    rb: h2.ReqBody,
) !void {
    var method: []const u8 = "";
    var path: []const u8 = "";
    var authz: []const u8 = "";
    var ctype: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
            if (std.mem.eql(u8, name, "authorization")) authz = value;
            if (std.mem.eql(u8, name, "content-type")) ctype = value;
        }
    }
    const body: []const u8 = if (rb.data) |d| d[0..rb.len] else "";

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
        .hold => {
            try parkConnection(server, state, ent, sid, sess, route.tenant_id, method, path, body, ctype);
        },
        .internal_resolve => {
            if (!std.mem.eql(u8, method, "POST")) {
                try setSimpleResponse(server, ent, sid, sess, 405, "POST only\n");
                return;
            }
            try handleInternalResolve(server, state, ent, sid, sess, authz, rb);
        },
    }
}

const RouteKind = enum { health, hold, internal_resolve };

const ParsedRoute = struct {
    kind: RouteKind,
    /// Empty for `health`.
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
    // The privileged worker→holder channel. Matched before the
    // generic `/v1/{tenant}/...` branch; `_internal` is not a valid
    // customer tenant id (reserved prefix) so there is no collision.
    if (std.mem.eql(u8, path_no_q, "/v1/_internal/resolve")) {
        return .{ .kind = .internal_resolve, .query = query };
    }
    const v1_prefix = "/v1/";
    if (std.mem.startsWith(u8, path_no_q, v1_prefix)) {
        const after = path_no_q[v1_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        const tenant_id = after[0..slash];
        const tail = after[slash + 1 ..];
        if (tenant_id.len == 0) return null;
        if (std.mem.eql(u8, tail, "hold")) {
            return .{ .kind = .hold, .tenant_id = tenant_id, .query = query };
        }
    }
    return null;
}

// ── Park ───────────────────────────────────────────────────────────

/// Accept a held connection: enforce the caps, allocate a
/// connection-id, record it in the table, arm the holder-level
/// deadline, and *do not respond*. The h2 request entity is left in
/// `request_out`; the stream stays open and the client waits. This is
/// the plan §1 primitive's accept step. Phase 1 has no `open` wake
/// into the JS handler yet (Phase 2) and no http.send fired on accept
/// (Phase 3) — the connection simply holds until the deadline.
fn parkConnection(
    server: *HolderH2,
    state: *HolderState,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    ctype: []const u8,
) !void {
    // Hard caps fail loud (explicit 503), never silently — plan §6.4
    // load-bearing constraint + the fail-loud-on-resource-exhaustion
    // discipline. A refused park is a completed request, not a held
    // one, so it does NOT enter the table.
    if (state.conns.count() >= state.config.max_held_total) {
        try setSimpleResponse(server, ent, sid, sess, 503, "holder at capacity\n");
        return;
    }
    if (state.tenantCount(tenant_id) >= state.config.max_held_per_tenant) {
        try setSimpleResponse(server, ent, sid, sess, 503, "tenant hold cap reached\n");
        return;
    }

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const a = state.allocator;
    const conn = try a.create(Connection);
    errdefer a.destroy(conn);
    const tid_owned = try a.dupe(u8, tenant_id);
    errdefer a.free(tid_owned);
    const m_owned = try a.dupe(u8, method);
    errdefer a.free(m_owned);
    const p_owned = try a.dupe(u8, path);
    errdefer a.free(p_owned);
    const b_owned = try a.dupe(u8, body);
    errdefer a.free(b_owned);
    const ct_owned = try a.dupe(u8, ctype);
    errdefer a.free(ct_owned);

    const id = state.next_id;
    state.next_id += 1;
    conn.* = .{
        .id = id,
        .handle = mintHandle(),
        .stream_ent = ent,
        .sid = sid,
        .sess = sess,
        .tenant_id = tid_owned,
        .deadline_ns = now_ns + state.config.default_hold_deadline_ms * std.time.ns_per_ms,
        .accepted_ns = now_ns,
        .req_method = m_owned,
        .req_path = p_owned,
        .req_body = b_owned,
        .req_ctype = ct_owned,
    };
    try state.track(conn);
    // Arm the `open` wake (plan §3/§6.1). 2a drains it through the
    // counted-noop sink; 2b delivers it to the owning tenant's
    // handler. Until then the connection still has its deadline, so a
    // parked connection cannot hang past it.
    try state.armWake(conn, .open);
}

// ── Privileged resolve (worker → holder, layers 2 + 3) ─────────────

/// Resolve a held connection from the authenticated worker→holder
/// channel. This is the primitive 2b's post-commit flush calls; 2a
/// ships it so the security layers are exercisable end-to-end now.
///
/// Three guards, in order:
///   - layer 3: the request must carry the internal bearer, or 401.
///   - layer 1: a malformed/unknown handle is indistinguishable from
///     a guess → 404 (no oracle: same code for "no such handle").
///   - layer 2: the body's `tenant` must be the handle's OWNING
///     tenant, or 403. This is the line that stops tenant B resolving
///     tenant A's socket.
///
/// `ent` is the internal POST itself (→ 204/4xx); the *held*
/// connection's own stream entity gets the resolved status.
fn handleInternalResolve(
    server: *HolderH2,
    state: *HolderState,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    authz: []const u8,
    rb: h2.ReqBody,
) !void {
    if (!internalAuthOk(state.config, authz)) {
        try setSimpleResponse(server, ent, sid, sess, 401, "bad internal token\n");
        return;
    }
    if (rb.data == null or rb.len == 0) {
        try setSimpleResponse(server, ent, sid, sess, 400, "missing body\n");
        return;
    }
    const body = rb.data.?[0..rb.len];

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const Wire = struct {
        handle: []const u8 = "",
        tenant: []const u8 = "",
        status: u16 = 200,
        // §6.4 callback path: the `on_result` handler computed a real
        // response. Text/UTF-8 only here (JSON string); binary / large
        // payloads are the plan §8 content-addressed path, out of
        // scope for v1 held-sync.
        body: []const u8 = "",
        content_type: []const u8 = "",
    };
    const w = std.json.parseFromSliceLeaky(Wire, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try setSimpleResponse(server, ent, sid, sess, 400, "malformed body\n");
        return;
    };

    const conn = state.resolveOwned(w.handle, w.tenant) catch |err| switch (err) {
        // Same response for unknown and malformed handle — no
        // enumeration oracle.
        error.UnknownHandle => {
            try setSimpleResponse(server, ent, sid, sess, 404, "no such handle\n");
            return;
        },
        error.TenantMismatch => {
            std.log.warn(
                "connection-holder: REJECTED cross-tenant resolve: tenant {s} tried handle owned by another tenant",
                .{w.tenant},
            );
            try setSimpleResponse(server, ent, sid, sess, 403, "tenant mismatch\n");
            return;
        },
    };

    // Authorized (layers 1–3 + owning-tenant). Flush the §6.4
    // callback's response onto the held stream, drop the record
    // (which is also the resolve-once guard — see below), ack the
    // POST. The stream entity is still parked in `request_out` (the
    // `open` handler returned the hold sentinel, so it was never
    // resolved), so the request_out→response_in move is valid here.
    const id = conn.id;
    setResponseWithBody(server, state.allocator, conn.stream_ent, conn.sid, conn.sess, w.status, w.body, w.content_type) catch |e| {
        std.log.err("connection-holder: conn {d}: resolve flush failed: {s}", .{ id, @errorName(e) });
    };
    // RESOLVE-ONCE: drop removes the handle from `by_handle`, so any
    // later delivery — http.send is at-least-once, leadership change
    // can re-fire (plan §6.4) — or a deadline-sweep race resolves to
    // `UnknownHandle` → 404 below / skipped in the sweep. Table
    // membership IS the guard (state-is-collection); the per-conn
    // version counter is reserved, not needed while resolved
    // connections simply cease to exist.
    state.drop(id);
    state.recomputeNextDeadline();
    try setSimpleResponse(server, ent, sid, sess, 204, "");
}

// ── Open wake → worker forward (plan §6.1 degenerate case) ─────────

/// Forward the parked connect request to a worker, flush the worker's
/// response onto the held socket, and drop the record. Chain-length
/// one (plan §6.1): the handle is never held past this wake. On any
/// transport/build error this returns the error WITHOUT dropping the
/// connection, so the caller's deadline still 504s it — a wedged
/// worker degrades to a timeout, never a hung socket or a leak.
fn fireOpenWake(
    state: *HolderState,
    server: *HolderH2,
    easy: *blob_curl.Easy,
    worker_base: []const u8,
    conn: *Connection,
) !void {
    var res = try wake_dispatch.deliverOpenWake(
        state.allocator,
        easy,
        worker_base,
        state.config.internal_token,
        conn.tenant_id,
        &conn.handle,
        conn.req_method,
        conn.req_body,
        conn.req_ctype,
        state.config.worker_insecure_tls,
        state.config.worker_timeout_ms,
    );
    defer res.deinit(state.allocator);

    // Plan §6.4: the `open` handler fired `http.send(on_result)` and
    // returned the hold sentinel — it pended nothing. Keep the
    // connection PARKED. A later `connection.respond` callback
    // (POST /v1/_internal/resolve, Phase 3b) resolves it; if none
    // arrives, the deadline sweep 504s it (the §6.4 *mandatory
    // timeout*, which must fire before any intermediary gives up).
    // Do NOT touch the h2 entity and do NOT drop the record.
    if (res.held) {
        std.log.debug("connection-holder: conn {d}: held (open fired http.send; awaiting callback or deadline)", .{conn.id});
        return;
    }

    // Degenerate §6.1: a normal response — resolve + close now.
    const id = conn.id;
    try setResponseWithBody(server, state.allocator, conn.stream_ent, conn.sid, conn.sess, res.status, res.body, res.ctype);
    state.drop(id);
    state.recomputeNextDeadline();
}

// ── Deadline sweep (Phase-1 holder-level `timeout`) ────────────────

/// The Phase-1 form of the plan §6.4 mandatory `timeout` wake: a
/// parked connection with no resolving wake by its deadline is
/// resolved with a 504 so a real response goes out before any
/// intermediary gives up. Phase 3 turns this into a real `timeout`
/// wake into the JS handler (which gets the last word on the body);
/// Phase 1 keeps it holder-level so the lifecycle is correct on its
/// own. The per-tick cost is O(1) (the cached soonest deadline);
/// the O(parked) walk runs only on a tick where something expired.
fn sweepDeadlines(server: *HolderH2, state: *HolderState) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns < state.next_deadline_ns) return;

    var expired: std.ArrayListUnmanaged(ConnId) = .empty;
    defer expired.deinit(state.allocator);
    var it = state.conns.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.*.deadline_ns <= now_ns) {
            try expired.append(state.allocator, e.key_ptr.*);
        }
    }

    for (expired.items) |id| {
        const conn = state.conns.get(id) orelse continue;
        // Resolve the held stream with a 504, then drop the record.
        // The entity is currently parked in `request_out`.
        setSimpleResponse(server, conn.stream_ent, conn.sid, conn.sess, 504, "hold deadline exceeded\n") catch |err| {
            std.log.warn(
                "connection-holder: conn {d}: 504 resolve failed: {s}",
                .{ id, @errorName(err) },
            );
        };
        state.drop(id);
    }

    state.recomputeNextDeadline();
}

// ── Closed-stream cleanup ──────────────────────────────────────────

/// A client that disconnects a parked stream surfaces in
/// `response_out`. Map the closed h2 entity back to its connection via
/// the reverse index and drop the record so the table doesn't leak.
fn cleanupClosedConnections(server: *HolderH2, state: *HolderState) !void {
    const closed = server.response_out.entitySlice();
    if (closed.len == 0) return;
    var any_dropped = false;
    for (closed) |ent| {
        if (state.by_entity.get(ent)) |id| {
            state.drop(id);
            any_dropped = true;
        }
    }
    if (any_dropped) state.recomputeNextDeadline();
}

// ── h2 response helpers ────────────────────────────────────────────

const HdrPair = struct { name: []const u8, value: []const u8 };

fn setSimpleResponse(
    server: *HolderH2,
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

/// Pack a single optional header (content-type) into an h2.RespHeaders
/// — a one-header subset of sse-server's `packHeaders`. The buffer is
/// owned by the entity (freed by `h2.RespHeaders.deinit` on destroy),
/// matching how the body bytes below are handed off.
fn packCtype(allocator: std.mem.Allocator, ctype: []const u8) !h2.RespHeaders {
    const fields_size = @sizeOf(h2.HeaderField);
    const name = "content-type";
    const buf = try allocator.alloc(u8, fields_size + name.len + ctype.len);
    errdefer allocator.free(buf);
    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    @memcpy(buf[off..][0..name.len], name);
    const name_start = off;
    off += name.len;
    @memcpy(buf[off..][0..ctype.len], ctype);
    fields_ptr[0] = .{
        .name = buf[name_start..].ptr,
        .name_len = @intCast(name.len),
        .value = buf[off..].ptr,
        .value_len = @intCast(ctype.len),
    };
    return .{ .fields = fields_ptr, .count = 1 };
}

/// Resolve a held stream with a real body (the worker's response, plan
/// §6.1). Empty body → the `setSimpleResponse` shape (no allocation).
/// Otherwise the body is duped into an entity-owned buffer and handed
/// to h2 via `RespBody.data` (same handoff sse-server's emit path
/// uses); on a `move` failure the slot is nulled before freeing so
/// the entity's eventual deinit cannot double-free.
fn setResponseWithBody(
    server: *HolderH2,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body: []const u8,
    ctype: []const u8,
) !void {
    if (body.len == 0) {
        try setSimpleResponse(server, ent, sid, sess, status, "");
        return;
    }
    const owned = try allocator.dupe(u8, body);
    var owned_taken = false;
    errdefer if (!owned_taken) allocator.free(owned);

    const resp_hdrs: h2.RespHeaders = if (ctype.len > 0)
        try packCtype(allocator, ctype)
    else
        .{ .fields = null, .count = 0 };

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, resp_hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = owned.ptr,
        .len = @intCast(owned.len),
    });
    owned_taken = true; // the entity's RespBody owns it now
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    server.reg.move(ent, &server.request_out, &server.response_in) catch |err| {
        server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 }) catch {};
        allocator.free(owned);
        return err;
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseRoute matches /v1/health" {
    const r = parseRoute("/v1/health").?;
    try testing.expectEqual(RouteKind.health, r.kind);
}

test "parseRoute matches /v1/{tenant}/hold with query" {
    const r = parseRoute("/v1/acme/hold?to=https%3A%2F%2Fx").?;
    try testing.expectEqual(RouteKind.hold, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("to=https%3A%2F%2Fx", r.query);
}

test "parseRoute rejects bad shapes" {
    try testing.expect(parseRoute("/") == null);
    try testing.expect(parseRoute("/v2/health") == null);
    try testing.expect(parseRoute("/v1/") == null);
    try testing.expect(parseRoute("/v1/acme") == null);
    try testing.expect(parseRoute("/v1/acme/foo") == null);
    try testing.expect(parseRoute("/v1//hold") == null);
}

test "HolderState track / drop maintains every index + per-tenant count" {
    const a = testing.allocator;
    const cfg = Config{ .allocator = a, .bind_addr = undefined };
    var state = HolderState.init(a, &cfg);
    defer state.deinit();

    const mk = struct {
        fn one(st: *HolderState, tid: []const u8, deadline: i64) !ConnId {
            const c = try st.allocator.create(Connection);
            const id = st.next_id;
            st.next_id += 1;
            c.* = .{
                .id = id,
                .handle = mintHandle(),
                .stream_ent = rove.Entity{ .index = @intCast(id), .generation = 1 },
                .sid = .{ .id = 0 },
                .sess = .{ .entity = rove.Entity.nil },
                .tenant_id = try st.allocator.dupe(u8, tid),
                .deadline_ns = deadline,
                .accepted_ns = 0,
                .req_method = try st.allocator.dupe(u8, ""),
                .req_path = try st.allocator.dupe(u8, ""),
                .req_body = try st.allocator.dupe(u8, ""),
                .req_ctype = try st.allocator.dupe(u8, ""),
            };
            try st.track(c);
            return id;
        }
    };

    const a1 = try mk.one(&state, "acme", 500);
    const a2 = try mk.one(&state, "acme", 300);
    const b1 = try mk.one(&state, "beta", 900);

    try testing.expectEqual(@as(usize, 3), state.conns.count());
    try testing.expectEqual(@as(u32, 2), state.tenantCount("acme"));
    try testing.expectEqual(@as(u32, 1), state.tenantCount("beta"));
    // Cached soonest deadline is the min across all parked conns.
    try testing.expectEqual(@as(i64, 300), state.next_deadline_ns);

    state.drop(a2);
    try testing.expectEqual(@as(u32, 1), state.tenantCount("acme"));
    state.recomputeNextDeadline();
    try testing.expectEqual(@as(i64, 500), state.next_deadline_ns);

    // Reverse index resolves the surviving entities, not the dropped.
    try testing.expect(state.by_entity.get(.{ .index = @intCast(a1), .generation = 1 }) != null);
    try testing.expect(state.by_entity.get(.{ .index = @intCast(a2), .generation = 1 }) == null);

    state.drop(a1);
    state.drop(b1);
    try testing.expectEqual(@as(usize, 0), state.conns.count());
    // Per-tenant keys freed at zero — no leak (testing.allocator
    // would fail the test otherwise).
    try testing.expectEqual(@as(u32, 0), state.tenantCount("acme"));
    try testing.expectEqual(@as(u32, 0), state.tenantCount("beta"));
}

test "connection-id is monotonic and never reused" {
    const a = testing.allocator;
    const cfg = Config{ .allocator = a, .bind_addr = undefined };
    var state = HolderState.init(a, &cfg);
    defer state.deinit();

    var seen: [8]ConnId = undefined;
    for (0..8) |i| {
        const c = try a.create(Connection);
        const id = state.next_id;
        state.next_id += 1;
        c.* = .{
            .id = id,
            .handle = mintHandle(),
            .stream_ent = .{ .index = @intCast(100 + i), .generation = 1 },
            .sid = .{ .id = 0 },
            .sess = .{ .entity = rove.Entity.nil },
            .tenant_id = try a.dupe(u8, "t"),
            .deadline_ns = std.math.maxInt(i64),
            .accepted_ns = 0,
            .req_method = try a.dupe(u8, ""),
            .req_path = try a.dupe(u8, ""),
            .req_body = try a.dupe(u8, ""),
            .req_ctype = try a.dupe(u8, ""),
        };
        try state.track(c);
        seen[i] = id;
        state.drop(id); // drop immediately; id must NOT be reused
    }
    for (1..8) |i| try testing.expect(seen[i] > seen[i - 1]);
}

/// Track a connection with an explicit handle + tenant for the
/// security tests. Returns the (holder-internal) id.
fn trackWithHandle(st: *HolderState, handle: ConnHandle, tid: []const u8) !ConnId {
    const c = try st.allocator.create(Connection);
    const id = st.next_id;
    st.next_id += 1;
    c.* = .{
        .id = id,
        .handle = handle,
        .stream_ent = .{ .index = @intCast(900 + id), .generation = 1 },
        .sid = .{ .id = 0 },
        .sess = .{ .entity = rove.Entity.nil },
        .tenant_id = try st.allocator.dupe(u8, tid),
        .deadline_ns = std.math.maxInt(i64),
        .accepted_ns = 0,
        .req_method = try st.allocator.dupe(u8, ""),
        .req_path = try st.allocator.dupe(u8, ""),
        .req_body = try st.allocator.dupe(u8, ""),
        .req_ctype = try st.allocator.dupe(u8, ""),
    };
    try st.track(c);
    return id;
}

test "mintHandle is 128-bit, lowercase hex, and unguessably distinct" {
    var seen: [64]ConnHandle = undefined;
    for (0..64) |i| {
        seen[i] = mintHandle();
        try testing.expectEqual(HANDLE_HEX_LEN, seen[i].len);
        for (seen[i]) |ch| {
            const hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
            try testing.expect(hex);
        }
    }
    // No collision across 64 mints (would be astronomically unlikely
    // for a real CSPRNG; catches a degenerate/zeroed source).
    for (0..64) |i| for (i + 1..64) |j|
        try testing.expect(!std.mem.eql(u8, &seen[i], &seen[j]));
}

test "resolveOwned is the owning-tenant chokepoint (layer 2)" {
    const a = testing.allocator;
    const cfg = Config{ .allocator = a, .bind_addr = undefined };
    var state = HolderState.init(a, &cfg);
    defer state.deinit();

    const h_acme: ConnHandle = [_]u8{'a'} ** HANDLE_HEX_LEN;
    const h_beta: ConnHandle = [_]u8{'b'} ** HANDLE_HEX_LEN;
    _ = try trackWithHandle(&state, h_acme, "acme");
    _ = try trackWithHandle(&state, h_beta, "beta");

    // Correct owner resolves.
    const c = try state.resolveOwned(&h_acme, "acme");
    try testing.expectEqualStrings("acme", c.tenant_id);

    // THE security property: tenant "beta" naming acme's handle is
    // rejected, NOT served — even though the handle is valid.
    try testing.expectError(error.TenantMismatch, state.resolveOwned(&h_acme, "beta"));

    // Unknown handle (valid length, absent) and malformed-length
    // handle both → UnknownHandle (no enumeration oracle).
    const h_absent: ConnHandle = [_]u8{'c'} ** HANDLE_HEX_LEN;
    try testing.expectError(error.UnknownHandle, state.resolveOwned(&h_absent, "acme"));
    try testing.expectError(error.UnknownHandle, state.resolveOwned("short", "acme"));
}

test "resolve-once: first resolution drops; later delivery is UnknownHandle" {
    // §6.4: http.send is at-least-once and leadership change can
    // re-fire the callback; the deadline sweep can also race the
    // callback. The guard is table membership — the first resolution
    // `drop`s the handle, so every later attempt (double-delivered
    // callback, post-resolve deadline) misses the table.
    const a = testing.allocator;
    const cfg = Config{ .allocator = a, .bind_addr = undefined };
    var state = HolderState.init(a, &cfg);
    defer state.deinit();

    const h: ConnHandle = [_]u8{'d'} ** HANDLE_HEX_LEN;
    const id = try trackWithHandle(&state, h, "acme");

    // First callback delivery resolves it — the real path calls
    // setResponseWithBody (needs a server) then drop(); the
    // resolve-once *property* is purely the drop, so assert that.
    try testing.expect((try state.resolveOwned(&h, "acme")).id == id);
    state.drop(id);

    // Second (double-delivered) callback, and a racing deadline
    // sweep, both miss the table — no double-resolve of the socket.
    try testing.expectError(error.UnknownHandle, state.resolveOwned(&h, "acme"));
    try testing.expect(state.conns.get(id) == null); // sweep would skip
}

test "internalAuthOk enforces the shared bearer (layer 3)" {
    // Null config token → privileged routes are closed.
    const closed = Config{ .allocator = testing.allocator, .bind_addr = undefined };
    try testing.expect(!internalAuthOk(&closed, "Bearer anything"));

    const open = Config{
        .allocator = testing.allocator,
        .bind_addr = undefined,
        .internal_token = "s3cret-shared-with-worker",
    };
    try testing.expect(internalAuthOk(&open, "Bearer s3cret-shared-with-worker"));
    try testing.expect(!internalAuthOk(&open, "Bearer wrong"));
    try testing.expect(!internalAuthOk(&open, "s3cret-shared-with-worker")); // no scheme
    try testing.expect(!internalAuthOk(&open, ""));
}

test "armWake coalesces; drainReadiness dispatches once per edge and skips dropped" {
    const a = testing.allocator;
    const cfg = Config{ .allocator = a, .bind_addr = undefined };
    var state = HolderState.init(a, &cfg);
    defer state.deinit();

    const h1: ConnHandle = [_]u8{'1'} ** HANDLE_HEX_LEN;
    const h2_: ConnHandle = [_]u8{'2'} ** HANDLE_HEX_LEN;
    const id1 = try trackWithHandle(&state, h1, "acme");
    const id2 = try trackWithHandle(&state, h2_, "acme");
    const c1 = state.conns.get(id1).?;
    const c2 = state.conns.get(id2).?;

    // A burst on one connection coalesces to a single queue entry.
    try state.armWake(c1, .open);
    try state.armWake(c1, .message);
    try state.armWake(c2, .open);
    try testing.expectEqual(@as(usize, 2), state.ready.items.len);

    // c2 is dropped between arm and drain — its stale entry is
    // skipped, not dispatched.
    state.drop(id2);

    // No server/easy → 2a counted-noop semantics preserved (latch
    // clears, counter ticks, stale entries skipped).
    state.drainReadiness(null, null);
    try testing.expectEqual(@as(u64, 1), state.wakes_dispatched);
    try testing.expectEqual(@as(usize, 0), state.ready.items.len);
    // Latch cleared → the next readiness edge re-arms.
    try testing.expect(c1.pending_wake == null);
    try state.armWake(c1, .timeout);
    try testing.expectEqual(@as(usize, 1), state.ready.items.len);
}
