const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");

const Ctx = rove.Context(rio.Collections(.{}));

const MyIo = rio.Io(Ctx);

fn processReads(ctx: *Ctx, alloc: std.mem.Allocator) !void {
    for (
        ctx.entities(.read_results),
        ctx.column(.read_results, rio.ConnEntity),
        ctx.column(.read_results, rio.ReadResult),
    ) |ent, conn_ent, result| {
        if (result.result > 0) {
            const data_len: u32 = @intCast(result.result);
            const copy = try alloc.alloc(u8, data_len);
            @memcpy(copy, result.data.?[0..data_len]);

            const we = try ctx.createOneImmediate(.write_in);
            try ctx.set(we, rio.ConnEntity, conn_ent);
            try ctx.set(we, rio.WriteBuf, .{
                .data = copy.ptr,
                .len = data_len,
            });

            try ctx.moveOneFrom(ent, .read_results, .read_in);
        } else {
            try ctx.destroyOne(conn_ent.entity);
            try ctx.destroyOne(ent);
        }
    }
}

fn processWrites(ctx: *Ctx) !void {
    for (ctx.entities(.write_results)) |ent| {
        // WriteBuf.deinit frees the data on entity destroy
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

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const io = try MyIo.create(&ctx, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 4096,
    });
    defer io.destroy();

    std.debug.print("Echo server listening on 127.0.0.1:8080\n", .{});

    while (true) {
        _ = try io.poll(&ctx, 1);
        try processReads(&ctx, alloc);
        try ctx.flush();
        try processWrites(&ctx);
        try ctx.flush();
    }
}
