//! WebSocket echo server — proves the rove-h2 inbound WS transport
//! (docs/architecture/websockets.md pieces A/C + the h2 side of E) end-to-end,
//! before the worker seam (piece D). Mirrors `h2_stream_test.zig`: it drives
//! the server's collections directly instead of going through a JS worker.
//!
//! The server upgrades any `Upgrade: websocket` request (handled entirely
//! inside rove-h2), then surfaces each complete inbound message on
//! `ws_message_out`. This loop echoes every message straight back by queueing
//! an `ws_send_in` frame with the same opcode — the stand-in for what the
//! `onMessage` handler will do once piece D lands.
//!
//! Run: `zig build ws-echo` (listens on 127.0.0.1:8085). Drive it with any WS
//! client, e.g. `scripts/ws_echo_smoke.py`.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const MyH2 = h2.H2(.{});

/// Echo every completed inbound message back to its connection with the same
/// opcode (text→text, binary→binary). A client-close signal (opcode 8) has
/// nothing to echo; just drop it.
fn echoMessages(server: *MyH2, alloc: std.mem.Allocator) !void {
    for (
        server.ws_message_out.entitySlice(),
        server.ws_message_out.column(h2.Session),
        server.ws_message_out.column(h2.WsMeta),
        server.ws_message_out.column(h2.ReqBody),
    ) |ent, sess, meta, body| {
        if (meta.opcode == @intFromEnum(h2.ws.Opcode.close)) {
            try server.reg.destroy(ent);
            continue;
        }

        const payload = if (body.data) |d| d[0..body.len] else "";
        const copy = alloc.alloc(u8, payload.len) catch {
            try server.reg.destroy(ent);
            continue;
        };
        @memcpy(copy, payload);

        const out = try server.reg.create(&server.ws_send_in);
        try server.reg.set(out, &server.ws_send_in, h2.Session, sess);
        try server.reg.set(out, &server.ws_send_in, h2.WsMeta, meta);
        try server.reg.set(out, &server.ws_send_in, h2.ReqBody, .{ .data = copy.ptr, .len = @intCast(payload.len) });

        try server.reg.destroy(ent);
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

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8085);
    const server = try MyH2.create(&reg, alloc, addr, .{
        .max_connections = 256,
        .buf_count = 256,
        .buf_size = 16384,
    }, .{});
    defer server.destroy();

    std.debug.print("WebSocket echo server on ws://127.0.0.1:8085\n", .{});

    while (true) {
        try server.poll(1);

        try echoMessages(server, alloc);
        try reg.flush();
    }
}
