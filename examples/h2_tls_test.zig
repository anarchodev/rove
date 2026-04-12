const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const MyH2 = h2.H2(.{});

fn processRequests(server: *MyH2, alloc: std.mem.Allocator) !void {
    for (
        server.request_out.entitySlice(),
        server.request_out.column(h2.StreamId),
        server.request_out.column(h2.Session),
        server.request_out.column(h2.ReqBody),
    ) |ent, sid, sess, rb| {
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

    const cert_pem = try std.fs.cwd().readFileAlloc(alloc, "/tmp/test_cert.pem", 65536);
    defer alloc.free(cert_pem);
    const key_pem = try std.fs.cwd().readFileAlloc(alloc, "/tmp/test_key.pem", 65536);
    defer alloc.free(key_pem);

    const tls_cfg = try h2.TlsConfig.create(alloc, cert_pem, key_pem);
    defer tls_cfg.destroy();

    var reg = try rove.Registry.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });
    defer reg.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8443);
    const server = try MyH2.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{
        .tls_config = tls_cfg,
    });
    defer server.destroy();

    std.debug.print("TLS echo server on https://127.0.0.1:8443 (h2 over TLS)\n", .{});

    while (true) {
        try server.poll(1);
        try processRequests(server, alloc);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
}
