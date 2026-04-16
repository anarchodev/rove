//! `code_server.thread` — the background-thread host for the
//! synchronous code-server operations in `root.zig`.
//!
//! The design goal is "compile does not block the worker's h2 event
//! loop." The mechanism is standard: spawn a thread that owns its own
//! rove registry + io_uring + rove-h2 server instance, binding to a
//! loopback TCP port. The worker (on a separate thread) connects as
//! an HTTP/2 client and forwards any request whose path starts with
//! `/_system/code/` here.
//!
//! Unix domain sockets would be nicer (no port, filesystem perms as
//! auth) but rove-io's connect path is currently hard-coded to
//! AF_INET. Loopback TCP on 127.0.0.1:ephemeral is equivalent for the
//! single-host case we're in, and switching to unix sockets later is
//! a rove-io extension — no changes to this module.
//!
//! ## Wire protocol
//!
//! Plain HTTP/2 (h2c), no TLS. The routes are:
//!
//!   POST /{instance_id}/upload     X-Rove-Path: <path>
//!                                  body: source bytes
//!                                  → 204 on success, 4xx/5xx on failure
//!
//!   POST /{instance_id}/deploy     → 200, body = decimal deployment id
//!
//!   GET  /{instance_id}/source/{hash}
//!                                  → 200, body = raw source bytes
//!                                  → 404 if the blob isn't present
//!
//! The instance-id-first shape lets the worker's `/_system/code/*`
//! proxy do a pure prefix strip — `/_system/code/acme/upload` maps
//! directly to `/acme/upload` without reordering segments.
//!
//! The handler path intentionally avoids JSON — the only structured
//! field the CLI needs to send is the deployment-relative file path,
//! and a header carries that cleanly. Bodies are opaque bytes.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const code_server = @import("root.zig");

const CodeH2 = h2.H2(.{});

/// Handle returned by `spawn`. The caller is expected to hold this
/// for the life of the worker process; `shutdown` tears it down.
pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    port: u16,
    /// Absolute path to `{data_dir}`. Borrowed from the caller — must
    /// outlive the handle.
    data_dir: []const u8,
    /// Max concurrent inbound h2c connections this server accepts.
    /// Sized from the worker count at spawn time — each worker holds
    /// one persistent client, so the cap must be `>= num_workers` or
    /// later workers get ECONNREFUSED and spin in a reconnect loop.
    max_connections: u32,
    /// Signalled by the main thread to request graceful shutdown.
    /// The thread's poll loop observes it between ticks.
    stop: std.atomic.Value(bool),
    /// Signalled by the thread once the h2 server has bound its
    /// listen socket (success or failure). The parent `spawn` waits
    /// on this before reading `port` or `bind_err`.
    ready: std.Thread.ResetEvent,
    /// Non-null if the bind or H2 create failed. Checked by the
    /// parent after `ready` fires.
    bind_err: ?anyerror,

    pub fn shutdown(self: *Handle) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.allocator.destroy(self);
    }
};

/// Launch the code-server thread. Returns once the thread has bound
/// its listen socket (or failed trying). The returned `Handle.port`
/// is the concrete port the caller should connect to — 0 is never
/// returned (OS picks an ephemeral port for us).
pub fn spawn(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    max_connections: u32,
) !*Handle {
    const h = try allocator.create(Handle);
    errdefer allocator.destroy(h);

    h.* = .{
        .allocator = allocator,
        .thread = undefined,
        .port = 0,
        .data_dir = data_dir,
        .max_connections = max_connections,
        .stop = .{ .raw = false },
        .ready = .{},
        .bind_err = null,
    };

    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    h.ready.wait();

    if (h.bind_err) |err| {
        h.thread.join();
        allocator.destroy(h);
        return err;
    }
    return h;
}

fn threadMain(h: *Handle) void {
    runThread(h) catch |err| {
        std.log.err("rove-code-server thread exited: {s}", .{@errorName(err)});
    };
}

fn runThread(h: *Handle) !void {
    const allocator = h.allocator;

    var reg = rove.Registry.init(allocator, .{
        .max_entities = 1024,
        .deferred_queue_capacity = 256,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer reg.deinit();

    // Bind to port 0 — OS picks one. After `H2.create` returns we'll
    // read it back off the listen_fd with getsockname. Same pattern
    // most test servers use.
    const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const server = CodeH2.create(&reg, allocator, bind_addr, .{
        .max_connections = h.max_connections,
        .buf_count = 64,
        .buf_size = 64 * 1024,
    }, .{}) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer server.destroy();

    // Read the actual bound port via getsockname(listen_fd).
    h.port = try resolveBoundPort(server);

    // Signal readiness — parent spawn() returns after this.
    h.ready.set();

    std.log.info(
        "rove-code-server thread listening on 127.0.0.1:{d} (h2c) data_dir={s}",
        .{ h.port, h.data_dir },
    );

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(server, allocator, h.data_dir);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
}

fn resolveBoundPort(server: *CodeH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

// ── Request processing ────────────────────────────────────────────────

fn processRequests(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        handleOne(server, allocator, data_dir, ent, sid, sess, rh, rb) catch |err| {
            std.log.warn("code-server: handler error: {s}", .{@errorName(err)});
            setResponse(server, ent, sid, sess, 500, null, "internal error\n") catch {};
        };
    }
}

fn handleOne(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    rb: h2.ReqBody,
) !void {
    // Extract `:method` and `:path` from the request headers. We
    // don't route by anything else — no content-type negotiation, no
    // query strings except on /source where the hash is a path
    // segment.
    var method: []const u8 = "";
    var path: []const u8 = "";
    var x_rove_path: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
            if (std.mem.eql(u8, name, "x-rove-path")) x_rove_path = value;
        }
    }

    // All routes share the shape `/{instance_id}/{op}[/{tail...}]`.
    // Split once to get the instance id and remainder, then dispatch
    // on the remainder.
    if (path.len == 0 or path[0] != '/') {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
        return;
    }
    const after_slash = path[1..];
    const slash_idx = std.mem.indexOfScalar(u8, after_slash, '/') orelse {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
        return;
    };
    const instance_id = after_slash[0..slash_idx];
    const remainder = after_slash[slash_idx + 1 ..]; // "upload", "deploy", "source/abc..."
    if (instance_id.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing instance id\n");
        return;
    }

    if (std.mem.eql(u8, remainder, "upload") and std.mem.eql(u8, method, "POST")) {
        try handleUpload(server, allocator, data_dir, ent, sid, sess, instance_id, x_rove_path, rb);
    } else if (std.mem.eql(u8, remainder, "deploy") and std.mem.eql(u8, method, "POST")) {
        try handleDeploy(server, allocator, data_dir, ent, sid, sess, instance_id);
    } else if (std.mem.startsWith(u8, remainder, "source/") and std.mem.eql(u8, method, "GET")) {
        const hash = remainder["source/".len..];
        try handleSource(server, allocator, data_dir, ent, sid, sess, instance_id, hash);
    } else {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
    }
}

fn handleUpload(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    x_rove_path: []const u8,
    rb: h2.ReqBody,
) !void {
    if (x_rove_path.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing X-Rove-Path header\n");
        return;
    }
    const source: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    code_server.uploadFile(allocator, data_dir, instance_id, x_rove_path, source) catch |err| {
        std.log.warn("code-server: uploadFile failed: {s}", .{@errorName(err)});
        const msg = try std.fmt.allocPrint(
            allocator,
            "upload failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    try setResponse(server, ent, sid, sess, 204, null, "");
}

fn handleDeploy(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
) !void {
    const dep_id = code_server.deploy(allocator, data_dir, instance_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "deploy failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{dep_id});
    try setResponse(server, ent, sid, sess, 200, body.ptr, body);
}

fn handleSource(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    hash: []const u8,
) !void {
    if (hash.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing hash\n");
        return;
    }

    const bytes = code_server.getSourceByHash(allocator, data_dir, instance_id, hash) catch |err| {
        const code: u16 = if (err == code_server.Error.NotFound) 404 else 500;
        const msg = try std.fmt.allocPrint(
            allocator,
            "source fetch failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    try setResponse(server, ent, sid, sess, 200, bytes.ptr, bytes);
}

/// Stamp a Status + RespBody + friends onto the entity and move it
/// from request_out to response_in. The body bytes are transferred
/// into the RespBody component; ownership passes to rove-h2 which
/// frees them after sending. Passing `body_ptr = null` is fine for
/// empty responses.
fn setResponse(
    server: *CodeH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_ptr: ?[*]u8,
    body_slice: []const u8,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{
        .fields = null,
        .count = 0,
    });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_ptr,
        .len = @intCast(body_slice.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn cleanupResponses(server: *CodeH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| {
        try server.reg.destroy(ent);
    }
}
