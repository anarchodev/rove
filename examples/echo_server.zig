const std = @import("std");
const rio = @import("rove-io");

const MyIo = rio.Io(.{});

fn processReads(io: *MyIo, reg: *MyIo.Reg, alloc: std.mem.Allocator) !void {
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
            // EOF or error: the conn still owns a live fd, so hand it to
            // `conn_closing` — io's teardown system shuts the socket down
            // and retires it. A direct destroy bypasses that path (and
            // `Fd.deinit` aborts on the leaked descriptor slot). The read
            // entity holds no buffer at EOF/error and can simply go.
            try reg.destroy(ent);
            try reg.move(conn_ent.entity, &io.connections, &io.conn_closing);
        }
    }
}

fn processWrites(io: *MyIo, reg: *MyIo.Reg) !void {
    // `write_done` is the terminal collection whose system frees the
    // buffer — an entity can only reach it from `write_results`, so being
    // there means the send's CQE landed and the kernel is done with the
    // bytes. Destroying straight out of `write_results` leaks the copy.
    for (io.write_results.entitySlice()) |ent| {
        try reg.move(ent, &io.write_results, &io.write_done);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = try MyIo.Reg.init(alloc, .{
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
