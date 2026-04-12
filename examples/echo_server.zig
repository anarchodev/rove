const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");

const MyIo = rio.Io(.{});

fn processReads(io: *MyIo, reg: *rove.Registry, alloc: std.mem.Allocator) !void {
    for (
        io.read_results.entitySlice(),
        io.read_results.column(rio.ConnEntity),
        io.read_results.column(rio.ReadResult),
    ) |ent, conn_ent, result| {
        if (result.result > 0) {
            const data_len: u32 = @intCast(result.result);
            const copy = try alloc.alloc(u8, data_len);
            @memcpy(copy, result.data.?[0..data_len]);

            const we = try reg.create(&io.write_in);
            try reg.set(we, &io.write_in, rio.ConnEntity, conn_ent);
            try reg.set(we, &io.write_in, rio.WriteBuf, .{
                .data = copy.ptr,
                .len = data_len,
            });

            try reg.move(ent, &io.read_results, &io.read_in);
        } else {
            try reg.destroy(conn_ent.entity);
            try reg.destroy(ent);
        }
    }
}

fn processWrites(io: *MyIo, reg: *rove.Registry) !void {
    for (io.write_results.entitySlice()) |ent| {
        try reg.destroy(ent);
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

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const io = try MyIo.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 4096,
    });
    defer io.destroy();

    std.debug.print("Echo server listening on 127.0.0.1:8080\n", .{});

    while (true) {
        _ = try io.poll(1);
        try processReads(io, &reg, alloc);
        try reg.flush();
        try processWrites(io, &reg);
        try reg.flush();
    }
}
