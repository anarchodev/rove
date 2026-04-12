const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const MyH2 = h2.H2(.{});

var chunk_index: u32 = 0;

fn processRequests(server: *MyH2) !void {
    for (
        server.request_out.entitySlice(),
        server.request_out.column(h2.StreamId),
        server.request_out.column(h2.Session),
    ) |ent, sid, sess| {
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 200 });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        chunk_index = 0;
        try server.reg.move(ent, &server.request_out, &server.stream_response_in);
    }
}

fn sendChunks(server: *MyH2, alloc: std.mem.Allocator) !void {
    for (server.stream_data_out.entitySlice()) |ent| {
        if (chunk_index < 3) {
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "chunk{}\n", .{chunk_index + 1}) catch "?\n";
            const copy = alloc.alloc(u8, msg.len) catch continue;
            @memcpy(copy, msg);

            try server.reg.set(ent, &server.stream_data_out, h2.RespBody, .{
                .data = copy.ptr,
                .len = @intCast(msg.len),
            });
            chunk_index += 1;
            try server.reg.move(ent, &server.stream_data_out, &server.stream_data_in);
        } else {
            try server.reg.move(ent, &server.stream_data_out, &server.stream_close_in);
        }
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

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8083);
    const server = try MyH2.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    defer server.destroy();

    std.debug.print("Streaming test server on :8083\n", .{});

    while (true) {
        try server.poll(1);

        try processRequests(server);
        try reg.flush();

        try sendChunks(server, alloc);
        try reg.flush();

        try cleanupResponses(server);
        try reg.flush();
    }
}
