const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const MyH2 = h2.H2(.{ .client = true });

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = try rove.Registry.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const client = try MyH2.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    defer reg.deinit();
    defer client.destroy();

    const conn = try reg.create(&client.client_connect_in);
    try reg.set(conn, &client.client_connect_in, h2.ConnectTarget, .{
        .addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8081),
    });

    var connected = false;
    var ticks: u32 = 0;
    while (ticks < 100) : (ticks += 1) {
        try client.poll(0);
        if (client.client_connect_out.entitySlice().len > 0) {
            connected = true;
            break;
        }
        if (client.client_connect_errors.entitySlice().len > 0) {
            std.debug.print("Connect failed!\n", .{});
            return;
        }
    }

    if (!connected) {
        std.debug.print("Connect timed out\n", .{});
        return;
    }

    std.debug.print("Connected!\n", .{});

    const conn_ents = client.client_connect_out.entitySlice();
    const session = (try reg.get(conn_ents[0], &client.client_connect_out, h2.Session)).*;
    try reg.destroy(conn_ents[0]);
    try reg.flush();

    const hdrs = [_]h2.HeaderField{
        .{ .name = ":method", .name_len = 7, .value = "POST", .value_len = 4 },
        .{ .name = ":path", .name_len = 5, .value = "/echo", .value_len = 5 },
        .{ .name = ":scheme", .name_len = 7, .value = "http", .value_len = 4 },
        .{ .name = ":authority", .name_len = 10, .value = "127.0.0.1:8081", .value_len = 14 },
    };

    const req = try reg.create(&client.client_stream_request_in);
    try reg.set(req, &client.client_stream_request_in, h2.Session, session);
    try reg.set(req, &client.client_stream_request_in, h2.ReqHeaders, .{ .fields = @constCast(&hdrs), .count = 4 });

    const chunks = [_][]const u8{ "chunk1\n", "chunk2\n", "chunk3\n" };
    var chunk_idx: u32 = 0;
    var done = false;
    var eof_sent = false;
    ticks = 0;

    while (ticks < 1000 and !done) : (ticks += 1) {
        // Once EOF is sent, block for CQEs — otherwise we busy-loop past the response
        try client.poll(if (eof_sent) 1 else 0);

        for (client.client_stream_data_out.entitySlice()) |ent| {
            if (chunk_idx < chunks.len) {
                const chunk = chunks[chunk_idx];
                const copy = try alloc.alloc(u8, chunk.len);
                @memcpy(copy, chunk);

                try reg.set(ent, &client.client_stream_data_out, h2.ReqBody, .{
                    .data = copy.ptr,
                    .len = @intCast(chunk.len),
                });
                chunk_idx += 1;
                std.debug.print("Sent chunk {d}\n", .{chunk_idx});
                try reg.move(ent, &client.client_stream_data_out, &client.client_stream_data_in);
            } else {
                std.debug.print("Signaling EOF\n", .{});
                try reg.move(ent, &client.client_stream_data_out, &client.client_stream_close_in);
                eof_sent = true;
            }
        }
        try reg.flush();

        const resp_ents = client.client_response_out.entitySlice();
        if (resp_ents.len > 0) {
            const resp_ent = resp_ents[0];
            const status = try reg.get(resp_ent, &client.client_response_out, h2.Status);
            const resp_body = try reg.get(resp_ent, &client.client_response_out, h2.RespBody);
            const io_res = try reg.get(resp_ent, &client.client_response_out, h2.H2IoResult);

            std.debug.print("Status: {d}\n", .{status.code});
            std.debug.print("Error: {d}\n", .{io_res.err});
            if (resp_body.data) |data| {
                std.debug.print("Body: {s}\n", .{data[0..resp_body.len]});
            } else {
                std.debug.print("Body: (empty)\n", .{});
            }

            try reg.destroy(resp_ent);
            try reg.flush();
            done = true;
        }
    }

    for (client._conn_active.entitySlice()) |active| {
        try reg.destroy(active);
    }
    try reg.flush();

    std.debug.print("Done\n", .{});
}
