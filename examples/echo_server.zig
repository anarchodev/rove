// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The TCP echo server, in the declared-world
//! shape: the root module declares the program's world ONCE (`rove_world`,
//! the `std_options` idiom), built from io's part; `MyIo.Reg` resolves to
//! the world's registry, which OWNS every declared collection — consumers
//! address them through `reg.coll(.name)` in the world's one namespace.
//! Moves are total and no lifecycle hooks run — release happens by
//! transition through `conn_closing` and `write_done`.
const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");

const io_opts = rio.Options{};

/// The world type, declared once at root scope. Values of its registry
/// are constructed in `main` (one per worker thread in a threaded
/// program) — never at root scope.
pub const rove_world = rove.World(.{ .parts = rio.parts(io_opts) });

const MyIo = rio.Io(io_opts);

fn processReads(reg: *MyIo.Reg, alloc: std.mem.Allocator) !void {
    const read_results = reg.coll(.read_results);
    for (
        read_results.entitySlice(),
        read_results.column(rio.ConnEntity),
        read_results.column(rio.ReadResult),
    ) |ent, conn_ent, result| {
        if (result.result > 0) {
            const data_len: u32 = @intCast(result.result);
            const copy = try alloc.alloc(u8, data_len);
            @memcpy(copy, result.data.?[0..data_len]);

            const write_in = reg.coll(.write_in);
            const we = try reg.create(write_in);
            try reg.set(we, write_in, rio.ConnEntity, conn_ent);
            try reg.set(we, write_in, rio.WriteBuf, .{
                .data = copy.ptr,
                .len = data_len,
            });

            try reg.move(ent, read_results, reg.coll(.read_in));
        } else {
            // EOF or error: the conn still owns a live fd, so hand it to
            // `conn_closing` — io's teardown system shuts the socket down
            // and retires it. The read entity holds no buffer at EOF/error
            // and can simply go.
            try reg.destroy(ent);
            try reg.move(conn_ent.entity, reg.coll(.connections), reg.coll(.conn_closing));
        }
    }
}

fn processWrites(reg: *MyIo.Reg) !void {
    // `write_done` is the terminal collection whose system frees the
    // buffer — reaching it means the send's CQE landed and the kernel is
    // done with the bytes.
    const write_results = reg.coll(.write_results);
    for (write_results.entitySlice()) |ent| {
        try reg.move(ent, write_results, reg.coll(.write_done));
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
        try processReads(&reg, alloc);
        try reg.flush();
        try processWrites(&reg);
        try reg.flush();
    }
}
