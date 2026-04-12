const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const Ctx = rove.Context(h2.Collections(.{}));
const MyH2 = h2.H2(Ctx);

fn processRequests(ctx: *Ctx, alloc: std.mem.Allocator) !void {
    for (
        ctx.entities(.request_out),
        ctx.column(.request_out, h2.StreamId),
        ctx.column(.request_out, h2.Session),
        ctx.column(.request_out, h2.ReqBody),
    ) |ent, sid, sess, rb| {
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

    // Load cert and key
    const cert_pem = try std.fs.cwd().readFileAlloc(alloc, "/tmp/test_cert.pem", 65536);
    defer alloc.free(cert_pem);
    const key_pem = try std.fs.cwd().readFileAlloc(alloc, "/tmp/test_key.pem", 65536);
    defer alloc.free(key_pem);

    const tls_cfg = try h2.TlsConfig.create(alloc, cert_pem, key_pem);
    defer tls_cfg.destroy();

    var ctx = try Ctx.init(alloc, .{
        .max_entities = 4096,
        .deferred_queue_capacity = 1024,
    });
    defer ctx.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8443);
    const server = try MyH2.create(&ctx, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{
        .tls_config = tls_cfg,
    });
    defer server.destroy();

    std.debug.print("TLS echo server on https://127.0.0.1:8443 (h2 over TLS)\n", .{});

    while (true) {
        try server.poll(&ctx, 1);
        try processRequests(&ctx, alloc);
        try ctx.flush();
        try cleanupResponses(&ctx);
        try ctx.flush();
    }
}
