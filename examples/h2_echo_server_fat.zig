// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The HTTP/2 echo server on the fat-entity registry model. Identical
//! wiring to `h2_echo_server.zig` except the `registry_model` line and
//! one contract: terminal stream entities are ended through
//! `server.destroyEntity`, which frees the h2-owned buffers the
//! archetype's deinit hooks would have freed. Conn foreign state
//! (nghttp2 session, TLS) is reaped by h2's `conn_dead` phase.
//! Default port 8445 so both variants run side by side.
const std = @import("std");
const h2 = @import("rove-h2");

const MyH2 = h2.H2(.{ .registry_model = .fat });

fn processRequests(server: *MyH2, alloc: std.mem.Allocator) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_bodies) |ent, sid, sess, rb| {
        var resp_data: ?[*]u8 = null;
        var resp_len: u32 = 0;

        if (rb.data != null and rb.len > 0) {
            const copy = alloc.alloc(u8, rb.len) catch {
                try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = -1 });
                try server.reg.move(ent, &server.request_out, &server.response_in);
                continue;
            };
            @memcpy(copy, rb.data.?[0..rb.len]);
            resp_data = copy.ptr;
            resp_len = rb.len;
        }

        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 200 });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = resp_data, .len = resp_len });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);

        try server.reg.move(ent, &server.request_out, &server.response_in);
    }
}

fn cleanupResponses(server: *MyH2) !void {
    for (server.response_out.entitySlice()) |ent| {
        try server.destroyEntity(ent);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = try MyH2.Reg.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });
    defer reg.deinit();

    var args = std.process.args();
    _ = args.next();
    const port: u16 = if (args.next()) |a|
        try std.fmt.parseInt(u16, a, 10)
    else
        8445;
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const server = try MyH2.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    defer server.destroy();

    std.debug.print("H2 echo server (fat registry) listening on http://127.0.0.1:{d} (h2c)\n", .{port});

    while (true) {
        try server.poll(1);

        try processRequests(server, alloc);
        try reg.flush();

        try cleanupResponses(server);
        try reg.flush();
    }
}
