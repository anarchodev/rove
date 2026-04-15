//! `log_server.thread` — h2 server host for the log read operations.
//!
//! Parallels `code_server/thread.zig` but on the observability side.
//! The worker proxies `/_system/log/{instance}/*` requests here over
//! loopback TCP; each request opens its own per-instance read-only
//! SQLite connection and closes it on return. The worker's h2 thread
//! stays the sole writer to the tenant's `log.db`.
//!
//! ## Wire protocol
//!
//! Plain h2c, no TLS. Routes follow the same `/{instance}/{op}` shape
//! the code-server uses so the worker proxy is a pure prefix strip:
//!
//!   GET  /{instance_id}/list[?limit=N]
//!        → 200 JSON: `{"records": [...]}` (newest first)
//!
//!   GET  /{instance_id}/show/{request_id_hex}
//!        → 200 JSON: full record with console + exception
//!        → 404 if the record isn't present
//!
//!   GET  /{instance_id}/count
//!        → 200 text/plain: decimal count of records
//!
//!   GET  /{instance_id}/blob/{hash}
//!        → 200 bytes: raw blob from the tenant's log-blobs/
//!        → 404 if absent
//!
//! JSON bodies are emitted by hand — the log read path is small and
//! doesn't warrant a full JSON writer. The shape matches what
//! `rove-log-cli bundle` already produces for tape payloads.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const log_server = @import("root.zig");
const log_mod = @import("rove-log");

const LogH2 = h2.H2(.{});

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    port: u16,
    data_dir: []const u8,
    stop: std.atomic.Value(bool),
    ready: std.Thread.ResetEvent,
    bind_err: ?anyerror,

    pub fn shutdown(self: *Handle) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.allocator.destroy(self);
    }
};

pub fn spawn(allocator: std.mem.Allocator, data_dir: []const u8) !*Handle {
    const h = try allocator.create(Handle);
    errdefer allocator.destroy(h);

    h.* = .{
        .allocator = allocator,
        .thread = undefined,
        .port = 0,
        .data_dir = data_dir,
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
        std.log.err("rove-log-server thread exited: {s}", .{@errorName(err)});
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

    const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const server = LogH2.create(&reg, allocator, bind_addr, .{
        .max_connections = 16,
        .buf_count = 64,
        .buf_size = 64 * 1024,
    }, .{}) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer server.destroy();

    h.port = try resolveBoundPort(server);
    h.ready.set();

    std.log.info(
        "rove-log-server thread listening on 127.0.0.1:{d} (h2c) data_dir={s}",
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

fn resolveBoundPort(server: *LogH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

// ── Request processing ────────────────────────────────────────────────

fn processRequests(
    server: *LogH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);

    for (entities, sids, sessions, req_hdrs) |ent, sid, sess, rh| {
        handleOne(server, allocator, data_dir, ent, sid, sess, rh) catch |err| {
            std.log.warn("log-server: handler error: {s}", .{@errorName(err)});
            setResponse(server, ent, sid, sess, 500, null, "internal error\n") catch {};
        };
    }
}

fn handleOne(
    server: *LogH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
) !void {
    var method: []const u8 = "";
    var path: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
        }
    }

    if (!std.mem.eql(u8, method, "GET")) {
        try setResponse(server, ent, sid, sess, 405, null, "method not allowed\n");
        return;
    }

    // Strip query string (we only care about it for `list?limit=`;
    // the parse is done below against the raw remainder).
    const q_idx = std.mem.indexOfScalar(u8, path, '?');
    const path_no_query = if (q_idx) |i| path[0..i] else path;
    const query = if (q_idx) |i| path[i + 1 ..] else "";

    if (path_no_query.len == 0 or path_no_query[0] != '/') {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
        return;
    }
    const after_slash = path_no_query[1..];
    const slash = std.mem.indexOfScalar(u8, after_slash, '/') orelse {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
        return;
    };
    const instance_id = after_slash[0..slash];
    const remainder = after_slash[slash + 1 ..];
    if (instance_id.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing instance id\n");
        return;
    }

    if (std.mem.eql(u8, remainder, "list")) {
        try handleList(server, allocator, data_dir, ent, sid, sess, instance_id, query);
    } else if (std.mem.startsWith(u8, remainder, "show/")) {
        const id_hex = remainder["show/".len..];
        try handleShow(server, allocator, data_dir, ent, sid, sess, instance_id, id_hex);
    } else if (std.mem.eql(u8, remainder, "count")) {
        try handleCount(server, allocator, data_dir, ent, sid, sess, instance_id);
    } else if (std.mem.startsWith(u8, remainder, "blob/")) {
        const key = remainder["blob/".len..];
        try handleBlob(server, allocator, data_dir, ent, sid, sess, instance_id, key);
    } else {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
    }
}

// ── Handlers ──────────────────────────────────────────────────────────

fn handleList(
    server: *LogH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    query: []const u8,
) !void {
    const limit = parseLimit(query, 100);

    var result = log_server.listRecords(allocator, data_dir, instance_id, limit) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "list failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    defer result.deinit();

    const json = try renderListJson(allocator, result.records);
    try setResponse(server, ent, sid, sess, 200, json.ptr, json);
}

fn handleShow(
    server: *LogH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    id_hex: []const u8,
) !void {
    if (id_hex.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing request id\n");
        return;
    }
    const request_id = std.fmt.parseInt(u64, id_hex, 16) catch {
        try setResponse(server, ent, sid, sess, 400, null, "invalid request id (want hex)\n");
        return;
    };

    var maybe_rec = log_server.getRecord(allocator, data_dir, instance_id, request_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "show failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    if (maybe_rec == null) {
        try setResponse(server, ent, sid, sess, 404, null, "record not found\n");
        return;
    }
    defer maybe_rec.?.deinit(allocator);

    const json = try renderRecordJson(allocator, &maybe_rec.?);
    try setResponse(server, ent, sid, sess, 200, json.ptr, json);
}

fn handleCount(
    server: *LogH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
) !void {
    const n = log_server.countRecords(allocator, data_dir, instance_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "count failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{n});
    try setResponse(server, ent, sid, sess, 200, body.ptr, body);
}

fn handleBlob(
    server: *LogH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    key: []const u8,
) !void {
    if (key.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing blob key\n");
        return;
    }
    const bytes = log_server.getBlob(allocator, data_dir, instance_id, key) catch |err| {
        const code: u16 = if (err == log_server.Error.NotFound) 404 else 500;
        const msg = try std.fmt.allocPrint(allocator, "blob failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    try setResponse(server, ent, sid, sess, 200, bytes.ptr, bytes);
}

// ── Helpers ───────────────────────────────────────────────────────────

fn parseLimit(query: []const u8, default: u32) u32 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "limit=")) {
            return std.fmt.parseInt(u32, pair["limit=".len..], 10) catch default;
        }
    }
    return default;
}

fn outcomeName(o: log_mod.Outcome) []const u8 {
    return switch (o) {
        .ok => "ok",
        .fault => "fault",
        .timeout => "timeout",
        .handler_error => "handler_error",
        .kv_error => "kv_error",
        .no_deployment => "no_deployment",
        .unknown_domain => "unknown_domain",
    };
}

fn writeJsonString(w: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try w.append(allocator, '"');
    for (s) |b| {
        switch (b) {
            '"' => try w.appendSlice(allocator, "\\\""),
            '\\' => try w.appendSlice(allocator, "\\\\"),
            '\n' => try w.appendSlice(allocator, "\\n"),
            '\r' => try w.appendSlice(allocator, "\\r"),
            '\t' => try w.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...0x1f => {
                var buf: [8]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{b});
                try w.appendSlice(allocator, esc);
            },
            else => try w.append(allocator, b),
        }
    }
    try w.append(allocator, '"');
}

fn writeRecordJson(
    w: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    r: *const log_mod.LogRecord,
) !void {
    var scratch: [64]u8 = undefined;
    try w.appendSlice(allocator, "{\"request_id\":\"");
    const id_hex = try std.fmt.bufPrint(&scratch, "{x:0>16}", .{r.request_id});
    try w.appendSlice(allocator, id_hex);
    try w.appendSlice(allocator, "\",\"deployment_id\":");
    const dep = try std.fmt.bufPrint(&scratch, "{d}", .{r.deployment_id});
    try w.appendSlice(allocator, dep);
    try w.appendSlice(allocator, ",\"received_ns\":");
    const recv = try std.fmt.bufPrint(&scratch, "{d}", .{r.received_ns});
    try w.appendSlice(allocator, recv);
    try w.appendSlice(allocator, ",\"duration_ns\":");
    const dur = try std.fmt.bufPrint(&scratch, "{d}", .{r.duration_ns});
    try w.appendSlice(allocator, dur);
    try w.appendSlice(allocator, ",\"status\":");
    const st = try std.fmt.bufPrint(&scratch, "{d}", .{r.status});
    try w.appendSlice(allocator, st);
    try w.appendSlice(allocator, ",\"outcome\":");
    try writeJsonString(w, allocator, outcomeName(r.outcome));
    try w.appendSlice(allocator, ",\"method\":");
    try writeJsonString(w, allocator, r.method);
    try w.appendSlice(allocator, ",\"path\":");
    try writeJsonString(w, allocator, r.path);
    try w.appendSlice(allocator, ",\"host\":");
    try writeJsonString(w, allocator, r.host);
    try w.appendSlice(allocator, ",\"console\":");
    try writeJsonString(w, allocator, r.console);
    try w.appendSlice(allocator, ",\"exception\":");
    try writeJsonString(w, allocator, r.exception);
    try w.append(allocator, '}');
}

fn renderListJson(
    allocator: std.mem.Allocator,
    records: []log_mod.LogRecord,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"records\":[");
    for (records, 0..) |*r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeRecordJson(&buf, allocator, r);
    }
    try buf.appendSlice(allocator, "]}\n");
    return buf.toOwnedSlice(allocator);
}

fn renderRecordJson(
    allocator: std.mem.Allocator,
    r: *const log_mod.LogRecord,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeRecordJson(&buf, allocator, r);
    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

fn setResponse(
    server: *LogH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_ptr: ?[*]u8,
    body_slice: []const u8,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_ptr,
        .len = @intCast(body_slice.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn cleanupResponses(server: *LogH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}
