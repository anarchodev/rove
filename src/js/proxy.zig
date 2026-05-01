//! HTTP/2 proxy subsystem used by the worker to forward
//! `/_system/{code,log}/*` requests to the in-process files-server
//! and log-server. Each subsystem keeps its own pending/inflight
//! collections + persistent client session; the worker holds two
//! `ProxySubsystem` instances (one per subsystem).
//!
//! Lifecycle per tick:
//!   1. `connectProxies` — open a new client session if the existing
//!      one is stale and we're not already mid-connect.
//!   2. `ingestProxyConnects` — drain `client_connect_out` /
//!      `client_connect_errors`, route each by `ProxyTag`.
//!   3. `flushProxyPending` — for each subsystem, copy parked server
//!      requests onto the client side, rewrite the `:path` header to
//!      strip `/_system/{subsystem}`, and submit upstream.
//!   4. `drainProxyResponses` — map upstream responses back onto the
//!      original server entities and move them to `response_in`.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");

const respb = @import("response_builder.zig");

/// Cross-reference component on the server-side entity pointing at
/// the matching client-side entity in `client_request_in`/`inflight`.
/// Set in `flushProxyPending`, read in `mapOneResponse`.
pub const ProxyPeer = struct { client: rove.Entity };

/// Tag applied to every client-side entity the worker submits so
/// `ingestProxyConnects` and `drainProxyResponses` can route each
/// entity back to its originating subsystem without scanning.
/// `.none` is the default for non-proxy client entities (tests /
/// future uses) and is a no-op sentinel.
pub const ProxyTag = struct {
    kind: enum(u8) { none = 0, code = 1, log = 2 } = .none,
};

/// Per-subsystem proxy state. The worker holds one of these for
/// `code` and one for `log`; the proxy systems below take a
/// `*ProxySubsystem` argument instead of reaching into fields by
/// name, so adding a third subsystem later is a matter of
/// constructing a third instance and tagging its client entities.
pub fn ProxySubsystem(comptime StreamCollT: type) type {
    return struct {
        const Self = @This();
        pending: StreamCollT,
        inflight: StreamCollT,
        session: rove.Entity = rove.Entity.nil,
        addr: ?std.net.Address = null,
        connecting: bool = false,
        tag: ProxyTag,

        pub fn init(allocator: std.mem.Allocator, tag: ProxyTag, addr: ?std.net.Address) !Self {
            return .{
                .pending = try StreamCollT.init(allocator),
                .inflight = try StreamCollT.init(allocator),
                .addr = addr,
                .tag = tag,
            };
        }

        pub fn deinit(self: *Self) void {
            self.inflight.deinit();
            self.pending.deinit();
        }
    };
}

/// Open a new client session for any subsystem whose existing one is
/// stale (or never opened). Skipped for subsystems that aren't
/// configured (`addr == null`) and for those that already have an
/// in-flight connect (`connecting == true`, awaiting either
/// `client_connect_out` or `client_connect_errors` to finish
/// establishing one). Called once per poll-loop tick before the
/// other proxy systems.
pub fn connectProxies(worker: anytype) !void {
    try connectOne(worker, &worker.code_proxy, "code");
    try connectOne(worker, &worker.log_proxy, "log");
}

fn connectOne(
    worker: anytype,
    ps: anytype,
    name: []const u8,
) !void {
    const addr = ps.addr orelse return;
    const server = worker.h2;
    const reg = server.reg;

    const session_live = !worker.reg.isStale(ps.session);
    if (session_live or ps.connecting) return;

    const conn = try reg.create(&server.client_connect_in);
    try reg.set(conn, &server.client_connect_in, h2.ConnectTarget, .{ .addr = addr });
    try reg.set(conn, &server.client_connect_in, ProxyTag, ps.tag);
    ps.connecting = true;
    std.log.info("rove-js: connecting to {s} server at {any}", .{ name, addr });
}

/// Drain `client_connect_out` + `client_connect_errors`. Each
/// entity carries a `ProxyTag` set at connect time, which we use
/// to route the new session back to the right subsystem.
pub fn ingestProxyConnects(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;

    {
        const ents = server.client_connect_out.entitySlice();
        // Snapshot because the loop destroys entities.
        const snap = try worker.allocator.dupe(rove.Entity, ents);
        defer worker.allocator.free(snap);

        for (snap) |ent| {
            const sess = try reg.get(ent, &server.client_connect_out, h2.Session);
            const tag = reg.get(ent, &server.client_connect_out, ProxyTag) catch null;
            const kind = if (tag) |t| t.kind else .none;
            switch (kind) {
                .code => {
                    worker.code_proxy.session = sess.entity;
                    worker.code_proxy.connecting = false;
                    std.log.info("rove-js: files-server connected (session={d})", .{sess.entity.index});
                },
                .log => {
                    worker.log_proxy.session = sess.entity;
                    worker.log_proxy.connecting = false;
                    std.log.info("rove-js: log server connected (session={d})", .{sess.entity.index});
                },
                .none => std.log.warn("rove-js: untagged proxy connect succeeded", .{}),
            }
            try reg.destroy(ent);
        }
    }
    {
        const ents = server.client_connect_errors.entitySlice();
        const snap = try worker.allocator.dupe(rove.Entity, ents);
        defer worker.allocator.free(snap);

        for (snap) |ent| {
            const tag = reg.get(ent, &server.client_connect_errors, ProxyTag) catch null;
            const kind = if (tag) |t| t.kind else .none;
            switch (kind) {
                .code => worker.code_proxy.connecting = false,
                .log => worker.log_proxy.connecting = false,
                .none => {},
            }
            const io = reg.get(ent, &server.client_connect_errors, h2.H2IoResult) catch null;
            const err_code: i32 = if (io) |i| i.err else -1;
            std.log.warn("rove-js: {any} proxy connect failed: {d}", .{ kind, err_code });
            try reg.destroy(ent);
        }
    }
}

/// Forward parked proxy requests for every subsystem with a live
/// upstream session.
pub fn flushProxyPending(worker: anytype) !void {
    try flushOne(worker, &worker.code_proxy);
    try flushOne(worker, &worker.log_proxy);
}

fn flushOne(
    worker: anytype,
    ps: anytype,
) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    if (worker.reg.isStale(ps.session)) return;
    const upstream_session = ps.session;

    const entities = ps.pending.entitySlice();
    const snapshot = try allocator.dupe(rove.Entity, entities);
    defer allocator.free(snapshot);

    for (snapshot) |server_ent| {
        const rh = try worker.reg.get(server_ent, &ps.pending, h2.ReqHeaders);
        const req_body = try worker.reg.get(server_ent, &ps.pending, h2.ReqBody);

        // Rewrite `:path` by stripping the `/_system/{subsystem}`
        // prefix so the subsystem's routes match. `forwardHeaders`
        // handles this for both subsystems — same rule applies.
        const header_fields = forwardHeaders(allocator, rh.*) catch |err| {
            std.log.warn("rove-js proxy: forwardHeaders failed: {s}", .{@errorName(err)});
            const body = try allocator.dupe(u8, "internal proxy error\n");
            try setProxyFault(server, server_ent, &ps.pending, 500, body, allocator, worker.admin_origin);
            try worker.reg.move(server_ent, &ps.pending, &server.response_in);
            continue;
        };

        var body_copy: ?[*]u8 = null;
        var body_len: u32 = 0;
        if (req_body.data != null and req_body.len > 0) {
            const buf = try allocator.alloc(u8, req_body.len);
            @memcpy(buf, req_body.data.?[0..req_body.len]);
            body_copy = buf.ptr;
            body_len = req_body.len;
        }

        const client_ent = try reg.create(&server.client_request_in);
        try reg.set(client_ent, &server.client_request_in, h2.Session, .{ .entity = upstream_session });
        try reg.set(client_ent, &server.client_request_in, ProxyTag, ps.tag);
        try reg.set(client_ent, &server.client_request_in, h2.ReqHeaders, .{
            .fields = header_fields.ptr,
            .count = @intCast(header_fields.len),
        });
        try reg.set(client_ent, &server.client_request_in, h2.ReqBody, .{
            .data = body_copy,
            .len = body_len,
        });

        try worker.reg.set(server_ent, &ps.pending, ProxyPeer, .{ .client = client_ent });
        try worker.reg.move(server_ent, &ps.pending, &ps.inflight);
    }
}

/// Map upstream responses back onto server-side peers. Uses
/// `ProxyTag` on the client entity to route to the right inflight
/// collection in O(1).
pub fn drainProxyResponses(worker: anytype) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    const client_ents = server.client_response_out.entitySlice();
    if (client_ents.len == 0) return;

    const client_snapshot = try allocator.dupe(rove.Entity, client_ents);
    defer allocator.free(client_snapshot);

    for (client_snapshot) |client_ent| {
        const tag = reg.get(client_ent, &server.client_response_out, ProxyTag) catch null;
        const kind = if (tag) |t| t.kind else .none;

        switch (kind) {
            .code => try mapOneResponse(worker, &worker.code_proxy, client_ent),
            .log => try mapOneResponse(worker, &worker.log_proxy, client_ent),
            .none => {
                std.log.warn("rove-js proxy: untagged upstream response", .{});
                try reg.destroy(client_ent);
            },
        }
    }
}

fn mapOneResponse(
    worker: anytype,
    ps: anytype,
    client_ent: rove.Entity,
) !void {
    const server = worker.h2;
    const reg = server.reg;
    const allocator = worker.allocator;

    const inflight_ents = ps.inflight.entitySlice();
    const peers = ps.inflight.column(ProxyPeer);
    var server_ent: rove.Entity = rove.Entity.nil;
    for (inflight_ents, peers) |cand, p| {
        if (p.client.index == client_ent.index and p.client.generation == client_ent.generation) {
            server_ent = cand;
            break;
        }
    }
    if (server_ent.index == 0 and server_ent.generation == 0) {
        std.log.warn("rove-js proxy: orphan upstream response", .{});
        try reg.destroy(client_ent);
        return;
    }

    const ust = try reg.get(client_ent, &server.client_response_out, h2.Status);
    const urb = try reg.get(client_ent, &server.client_response_out, h2.RespBody);
    const uio = try reg.get(client_ent, &server.client_response_out, h2.H2IoResult);

    if (uio.err != 0) {
        std.log.warn("rove-js proxy: upstream error {d} → 502", .{uio.err});
        const body = try allocator.dupe(u8, "bad gateway\n");
        try setProxyFault(server, server_ent, &ps.inflight, 502, body, allocator, worker.admin_origin);
        try worker.reg.move(server_ent, &ps.inflight, &server.response_in);
        try reg.destroy(client_ent);
        return;
    }

    try worker.reg.set(server_ent, &ps.inflight, h2.Status, .{ .code = ust.code });

    var body_copy: ?[*]u8 = null;
    var body_len: u32 = 0;
    if (urb.data != null and urb.len > 0) {
        const buf = try allocator.alloc(u8, urb.len);
        @memcpy(buf, urb.data.?[0..urb.len]);
        body_copy = buf.ptr;
        body_len = urb.len;
    }
    try worker.reg.set(server_ent, &ps.inflight, h2.RespBody, .{ .data = body_copy, .len = body_len });
    const resp_hdrs: h2.RespHeaders = if (worker.admin_origin) |o|
        try respb.buildSystemRespHeaders(allocator, o, false, null)
    else
        .{ .fields = null, .count = 0 };
    try worker.reg.set(server_ent, &ps.inflight, h2.RespHeaders, resp_hdrs);
    try worker.reg.set(server_ent, &ps.inflight, h2.H2IoResult, .{ .err = 0 });

    try worker.reg.move(server_ent, &ps.inflight, &server.response_in);
    try reg.destroy(client_ent);
}

/// Duplicate the request headers, rewriting `:path` to strip the
/// `/_system/{subsystem}` prefix so downstream subsystem routes
/// (`/{instance_id}/upload`, `/{instance_id}/list`, etc.) match. The
/// prefix is two segments: `/_system` + `/code` or `/log`. We walk
/// past the first two `/`s. `:authority` is left alone — subsystems
/// don't care what host name the caller used. Fields are allocated
/// on `allocator` and owned by the returned slice; rove-h2 frees
/// them when the request finishes.
fn forwardHeaders(
    allocator: std.mem.Allocator,
    rh: h2.ReqHeaders,
) ![]h2.HeaderField {
    if (rh.fields == null or rh.count == 0) return &.{};
    const fields = rh.fields.?[0..rh.count];
    const out = try allocator.alloc(h2.HeaderField, fields.len);
    for (fields, 0..) |f, i| {
        const name = try allocator.alloc(u8, f.name_len);
        @memcpy(name, f.name[0..f.name_len]);

        var value_slice: []const u8 = f.value[0..f.value_len];
        if (f.name_len == 5 and std.mem.eql(u8, name, ":path")) {
            if (std.mem.startsWith(u8, value_slice, "/_system/")) {
                // Find the second '/' after "/_system/" to strip
                // `/{subsystem}` as well.
                const after_sys = value_slice["/_system/".len..];
                if (std.mem.indexOfScalar(u8, after_sys, '/')) |slash| {
                    value_slice = after_sys[slash..];
                    if (value_slice.len == 0) value_slice = "/";
                }
            }
        }

        const value = try allocator.alloc(u8, value_slice.len);
        @memcpy(value, value_slice);
        out[i] = .{
            .name = name.ptr,
            .name_len = f.name_len,
            .value = value.ptr,
            .value_len = @intCast(value_slice.len),
        };
    }
    return out;
}

fn setProxyFault(
    server: anytype,
    ent: rove.Entity,
    src_coll: anytype,
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,
    cors_origin: ?[]const u8,
) !void {
    try server.reg.set(ent, src_coll, h2.Status, .{ .code = status });
    const resp_hdrs: h2.RespHeaders = if (cors_origin) |o|
        try respb.buildSystemRespHeaders(allocator, o, false, null)
    else
        .{ .fields = null, .count = 0 };
    try server.reg.set(ent, src_coll, h2.RespHeaders, resp_hdrs);
    try server.reg.set(ent, src_coll, h2.RespBody, .{ .data = body.ptr, .len = @intCast(body.len) });
    try server.reg.set(ent, src_coll, h2.H2IoResult, .{ .err = 0 });
}
