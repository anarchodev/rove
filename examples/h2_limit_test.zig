const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const MyH2 = h2.H2(.{});

fn processRequests(server: *MyH2, alloc: std.mem.Allocator) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_bodies) |ent, sid, sess, rb| {
        var resp_data: ?[*]u8 = null;
        var resp_len: u32 = 0;

        if (rb.data != null and rb.len > 0) {
            const copy = alloc.alloc(u8, rb.len) catch continue;
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
        try server.reg.destroy(ent);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = try rove.Registry.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });
    defer reg.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8082);
    const server = try MyH2.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{
        .max_h2_connections = 2,
        .idle_timeout_ns = 500 * std.time.ns_per_ms,
    });
    defer server.destroy();

    std.debug.print("Limit test server on :8082 (max_conn=2, idle=500ms)\n", .{});

    while (true) {
        try server.poll(1);
        try processRequests(server, alloc);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
}
