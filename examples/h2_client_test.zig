const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

// Client-only spec — no server collections needed, but we include them
// since H2 currently always includes server collections.
const Ctx = rove.Context(h2.Collections(.{ .client = true }));
const MyH2 = h2.H2(Ctx);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try Ctx.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });

    // Listen on a dummy port (client doesn't accept, but H2 requires an addr for rove-io)
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const client = try MyH2.create(&ctx, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    // client must be destroyed before ctx (Fd.deinit needs the io_uring ring)
    defer ctx.deinit();
    defer client.destroy();

    // Create a connect entity
    const conn = try ctx.createOneImmediate(.client_connect_in);
    try ctx.set(conn, h2.ConnectTarget, .{
        .addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8081),
    });

    // Poll until connected
    var connected = false;
    var ticks: u32 = 0;
    while (ticks < 100) : (ticks += 1) {
        try client.poll(&ctx, 0);

        // Check connect_out
        if (ctx.entities(.client_connect_out).len > 0) {
            connected = true;
            break;
        }
        // Check connect_errors
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

    // Get the session handle from the connect entity
    const conn_ents = ctx.entities(.client_connect_out);
    const session = (try ctx.get(conn_ents[0], h2.Session));

    // Create a request entity
    // Build headers: :method, :path, :scheme, :authority
    const hdrs = [_]h2.HeaderField{
        .{ .name = ":method", .name_len = 7, .value = "POST", .value_len = 4 },
        .{ .name = ":path", .name_len = 5, .value = "/echo", .value_len = 5 },
        .{ .name = ":scheme", .name_len = 7, .value = "http", .value_len = 4 },
        .{ .name = ":authority", .name_len = 10, .value = "127.0.0.1:8081", .value_len = 14 },
    };

    const body_str = "hello from rove client";
    const body = try alloc.alloc(u8, body_str.len);
    @memcpy(body, body_str);

    const req = try ctx.createOneImmediate(.client_request_in);
    try ctx.set(req, h2.Session, session.*);
    try ctx.set(req, h2.ReqHeaders, .{ .fields = @constCast(&hdrs), .count = 4 });
    try ctx.set(req, h2.ReqBody, .{ .data = body.ptr, .len = @intCast(body.len) });

    // Destroy connect entity — we have the session
    try ctx.destroyOne(conn_ents[0]);
    try ctx.flush();

    // Poll until response — needs several round trips
    ticks = 0;
    while (ticks < 1000) : (ticks += 1) {
        try client.poll(&ctx, 0);

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
            break;
        }
    }

    // Clean up connection entities before shutdown
    for (ctx.entities(._conn_active)) |active| {
        try ctx.destroyOne(active);
    }
    try ctx.flush();

    std.debug.print("Done\n", .{});
}
