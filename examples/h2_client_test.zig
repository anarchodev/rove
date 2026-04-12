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
    // client must be destroyed before reg (Fd.deinit needs the io_uring ring)
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
    const session = (try reg.get(conn_ents[0], &client.client_connect_out, h2.Session));

    const hdrs = [_]h2.HeaderField{
        .{ .name = ":method", .name_len = 7, .value = "POST", .value_len = 4 },
        .{ .name = ":path", .name_len = 5, .value = "/echo", .value_len = 5 },
        .{ .name = ":scheme", .name_len = 7, .value = "http", .value_len = 4 },
        .{ .name = ":authority", .name_len = 10, .value = "127.0.0.1:8081", .value_len = 14 },
    };

    const body_str = "hello from rove client";
    const body = try alloc.alloc(u8, body_str.len);
    @memcpy(body, body_str);

    const req = try reg.create(&client.client_request_in);
    try reg.set(req, &client.client_request_in, h2.Session, session.*);
    try reg.set(req, &client.client_request_in, h2.ReqHeaders, .{ .fields = @constCast(&hdrs), .count = 4 });
    try reg.set(req, &client.client_request_in, h2.ReqBody, .{ .data = body.ptr, .len = @intCast(body.len) });

    try reg.destroy(conn_ents[0]);
    try reg.flush();

    ticks = 0;
    while (ticks < 1000) : (ticks += 1) {
        try client.poll(1);

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
            break;
        }
    }

    for (client._conn_active.entitySlice()) |active| {
        try reg.destroy(active);
    }
    try reg.flush();

    std.debug.print("Done\n", .{});
}
