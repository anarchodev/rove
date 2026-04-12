const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const Ctx = rove.Context(h2.Collections(.{ .client = true }));
const MyH2 = h2.H2(Ctx);

/// Client streaming test — sends a POST with body in 3 chunks,
/// reads back the echoed response.
///
/// Flow:
///   client_connect_in → client_connect_out (connect)
///   client_stream_request_in → client_stream_data_out (send headers)
///   client_stream_data_out → client_stream_data_in (send chunk 1)
///   client_stream_data_out → client_stream_data_in (send chunk 2)
///   client_stream_data_out → client_stream_data_in (send chunk 3)
///   client_stream_data_out → client_stream_close_in (signal EOF)
///   client_response_out → destroy

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try Ctx.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const client = try MyH2.create(&ctx, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    defer ctx.deinit();
    defer client.destroy();

    // Connect
    const conn = try ctx.createOneImmediate(.client_connect_in);
    try ctx.set(conn, h2.ConnectTarget, .{
        .addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8081),
    });

    var connected = false;
    var ticks: u32 = 0;
    while (ticks < 100) : (ticks += 1) {
        try client.poll(&ctx, 0);
        if (ctx.entities(.client_connect_out).len > 0) {
            connected = true;
            break;
        }
        if (ctx.entities(.client_connect_errors).len > 0) {
            std.debug.print("Connect failed!\n", .{});
            return;
        }
    }

    if (!connected) {
        std.debug.print("Connect timed out\n", .{});
        return;
    }

    std.debug.print("Connected!\n", .{});

    const conn_ents = ctx.entities(.client_connect_out);
    const session = (try ctx.get(conn_ents[0], h2.Session)).*;
    try ctx.destroyOne(conn_ents[0]);
    try ctx.flush();

    // Start streaming request — headers only, no body yet
    const hdrs = [_]h2.HeaderField{
        .{ .name = ":method", .name_len = 7, .value = "POST", .value_len = 4 },
        .{ .name = ":path", .name_len = 5, .value = "/echo", .value_len = 5 },
        .{ .name = ":scheme", .name_len = 7, .value = "http", .value_len = 4 },
        .{ .name = ":authority", .name_len = 10, .value = "127.0.0.1:8081", .value_len = 14 },
    };

    const req = try ctx.createOneImmediate(.client_stream_request_in);
    try ctx.set(req, h2.Session, session);
    try ctx.set(req, h2.ReqHeaders, .{ .fields = @constCast(&hdrs), .count = 4 });

    // Send chunks
    const chunks = [_][]const u8{ "chunk1\n", "chunk2\n", "chunk3\n" };
    var chunk_idx: u32 = 0;
    var done = false;
    ticks = 0;

    while (ticks < 1000 and !done) : (ticks += 1) {
        try client.poll(&ctx, 0);

        // Feed next chunk or close
        for (ctx.entities(.client_stream_data_out)) |ent| {
            if (chunk_idx < chunks.len) {
                const chunk = chunks[chunk_idx];
                const copy = try alloc.alloc(u8, chunk.len);
                @memcpy(copy, chunk);

                try ctx.set(ent, h2.ReqBody, .{
                    .data = copy.ptr,
                    .len = @intCast(chunk.len),
                });
                chunk_idx += 1;
                std.debug.print("Sent chunk {d}\n", .{chunk_idx});
                try ctx.moveOneFrom(ent, .client_stream_data_out, .client_stream_data_in);
            } else {
                // All chunks sent — signal EOF
                std.debug.print("Signaling EOF\n", .{});
                try ctx.moveOneFrom(ent, .client_stream_data_out, .client_stream_close_in);
            }
        }
        try ctx.flush();

        // Check for response
        const resp_ents = ctx.entities(.client_response_out);
        if (resp_ents.len > 0) {
            const resp_ent = resp_ents[0];
            const status = try ctx.get(resp_ent, h2.Status);
            const resp_body = try ctx.get(resp_ent, h2.RespBody);
            const io_res = try ctx.get(resp_ent, h2.H2IoResult);

            std.debug.print("Status: {d}\n", .{status.code});
            std.debug.print("Error: {d}\n", .{io_res.err});
            if (resp_body.data) |data| {
                std.debug.print("Body: {s}\n", .{data[0..resp_body.len]});
            } else {
                std.debug.print("Body: (empty)\n", .{});
            }

            try ctx.destroyOne(resp_ent);
            try ctx.flush();
            done = true;
        }
    }

    // Clean up
    for (ctx.entities(._conn_active)) |active| {
        try ctx.destroyOne(active);
    }
    try ctx.flush();

    std.debug.print("Done\n", .{});
}
