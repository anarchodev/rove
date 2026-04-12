const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const Ctx = rove.Context(h2.Collections(.{}));
const MyH2 = h2.H2(Ctx);

fn processRequests(ctx: *Ctx, alloc: std.mem.Allocator) !void {
    const entities = ctx.entities(.request_out);
    const sids = ctx.column(.request_out, h2.StreamId);
    const sessions = ctx.column(.request_out, h2.Session);
    const req_bodies = ctx.column(.request_out, h2.ReqBody);

    for (entities, sids, sessions, req_bodies) |ent, sid, sess, rb| {
        var resp_data: ?[*]u8 = null;
        var resp_len: u32 = 0;

        if (rb.data != null and rb.len > 0) {
            const copy = alloc.alloc(u8, rb.len) catch continue;
            @memcpy(copy, rb.data.?[0..rb.len]);
            resp_data = copy.ptr;
            resp_len = rb.len;
        }

        try ctx.set(ent, h2.Status, .{ .code = 200 });
        try ctx.set(ent, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try ctx.set(ent, h2.RespBody, .{ .data = resp_data, .len = resp_len });
        try ctx.set(ent, h2.H2IoResult, .{ .err = 0 });
        try ctx.set(ent, h2.StreamId, sid);
        try ctx.set(ent, h2.Session, sess);
        try ctx.moveOneFrom(ent, .request_out, .response_in);
    }
}

fn cleanupResponses(ctx: *Ctx) !void {
    for (ctx.entities(.response_out)) |ent| {
        try ctx.destroyOne(ent);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try Ctx.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });
    defer ctx.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8082);
    const server = try MyH2.create(&ctx, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{
        .max_h2_connections = 2,
        .idle_timeout_ns = 500 * std.time.ns_per_ms, // 500ms
    });
    defer server.destroy();

    std.debug.print("Limit test server on :8082 (max_conn=2, idle=500ms)\n", .{});

    while (true) {
        try server.poll(&ctx, 1);
        try processRequests(&ctx, alloc);
        try ctx.flush();
        try cleanupResponses(&ctx);
        try ctx.flush();
    }
}
