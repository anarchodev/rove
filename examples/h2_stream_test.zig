const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const Ctx = rove.Context(h2.Collections(.{}));
const MyH2 = h2.H2(Ctx);

/// Streaming state machine per request:
///   request_out → stream_response_in (send headers)
///   stream_data_out → stream_data_in (send chunk 1: "chunk1\n")
///   stream_data_out → stream_data_in (send chunk 2: "chunk2\n")
///   stream_data_out → stream_close_in (signal EOF)
///   response_out → destroy

var chunk_index: u32 = 0;

fn processRequests(ctx: *Ctx) !void {
    for (
        ctx.entities(.request_out),
        ctx.column(.request_out, h2.StreamId),
        ctx.column(.request_out, h2.Session),
    ) |ent, sid, sess| {
        // Start streaming response: send headers, no body yet
        try ctx.set(ent, h2.Status, .{ .code = 200 });
        try ctx.set(ent, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try ctx.set(ent, h2.H2IoResult, .{ .err = 0 });
        try ctx.set(ent, h2.StreamId, sid);
        try ctx.set(ent, h2.Session, sess);
        chunk_index = 0;
        try ctx.moveOneFrom(ent, .request_out, .stream_response_in);
    }
}

fn sendChunks(ctx: *Ctx, alloc: std.mem.Allocator) !void {
    for (ctx.entities(.stream_data_out)) |ent| {
        if (chunk_index < 3) {
            // Send a chunk
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "chunk{}\n", .{chunk_index + 1}) catch "?\n";
            const copy = alloc.alloc(u8, msg.len) catch continue;
            @memcpy(copy, msg);

            try ctx.set(ent, h2.RespBody, .{
                .data = copy.ptr,
                .len = @intCast(msg.len),
            });
            chunk_index += 1;
            try ctx.moveOneFrom(ent, .stream_data_out, .stream_data_in);
        } else {
            // Done — signal EOF
            try ctx.moveOneFrom(ent, .stream_data_out, .stream_close_in);
        }
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

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8083);
    const server = try MyH2.create(&ctx, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    defer server.destroy();

    std.debug.print("Streaming test server on :8083\n", .{});

    while (true) {
        try server.poll(&ctx, 1);

        try processRequests(&ctx);
        try ctx.flush();

        try sendChunks(&ctx, alloc);
        try ctx.flush();

        try cleanupResponses(&ctx);
        try ctx.flush();
    }
}
