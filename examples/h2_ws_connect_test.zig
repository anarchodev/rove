//! Extended-CONNECT WS tunnel test (architecture/websockets.md) — a server and a
//! client rove-h2 instance in one process. The client opens an RFC 8441
//! CONNECT (`:protocol: websocket`), pumps a MASKED text frame as raw tunnel
//! bytes (what the front relays verbatim from a browser), and asserts:
//!
//!   1. the server surfaces the tunnel on `ws_connect_out` with routing
//!      (`wsStreamRouting`) from the CONNECT headers, and `wsConnectAccept`
//!      answers `:status 200` without END_STREAM;
//!   2. the inbound frame lands on `ws_message_out` (unmasked, opcode 1)
//!      keyed by the identity entity;
//!   3. an echo queued on `ws_send_in` (Session = identity entity) reaches
//!      the client as an unmasked text frame in the CONNECT stream's
//!      response DATA;
//!   4. a client Close frame surfaces opcode 8, the server echoes Close +
//!      END_STREAM, and the client's stream terminal arrives.
//!
//! Exits 0 on success, 1 with a message on any failed expectation.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");

const ServerH2 = h2.H2(.{});
const ClientH2 = h2.H2(.{ .client = true });

const PORT: u16 = 18441;

/// Client→server frames must be masked (RFC 6455 §5.1) — the browser does
/// this; the front relays the bytes verbatim. Fixed mask key: fine for a test.
fn writeMaskedFrame(out: *std.ArrayList(u8), a: std.mem.Allocator, opcode: u8, payload: []const u8) !void {
    std.debug.assert(payload.len <= 125);
    try out.append(a, 0x80 | opcode);
    try out.append(a, 0x80 | @as(u8, @intCast(payload.len)));
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    try out.appendSlice(a, &mask);
    for (payload, 0..) |b, i| try out.append(a, b ^ mask[i & 3]);
}

/// Collector BodySink for the client side of the tunnel (server→client
/// bytes).
const Collector = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    drained_pending: u32 = 0,
    finished: bool = false,
    aborted: bool = false,

    fn push(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.bytes.appendSlice(self.a, bytes) catch return false;
        self.drained_pending +%= @intCast(bytes.len);
        return true;
    }
    fn finish(ctx: *anyopaque) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.finished = true;
    }
    fn abort(ctx: *anyopaque) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.aborted = true;
    }
    fn drained(ctx: *anyopaque) u32 {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        const d = self.drained_pending;
        self.drained_pending = 0;
        return d;
    }
    fn release(_: *anyopaque) void {}

    fn sink(self: *Collector) h2.BodySink {
        return .{
            .ctx = @ptrCast(self),
            .push = &push,
            .finish = &finish,
            .abort = &abort,
            .drained = &drained,
            .release = &release,
        };
    }
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // ── Server (worker-shaped: headers_first + extended_connect) ──────
    var sreg = try rove.Registry.init(alloc, .{ .max_entities = 4096, .deferred_queue_capacity = 1024 });
    const server = try ServerH2.create(&sreg, alloc, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, PORT), .{
        .max_connections = 64,
        .buf_count = 64,
        .buf_size = 16384,
    }, .{
        .headers_first = true,
        .extended_connect = true,
    });
    defer sreg.deinit();
    defer server.destroy();

    // ── Client (front-shaped: client_headers_first) ───────────────────
    var creg = try rove.Registry.init(alloc, .{ .max_entities = 4096, .deferred_queue_capacity = 1024 });
    const client = try ClientH2.create(&creg, alloc, std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0), .{
        .max_connections = 64,
        .buf_count = 64,
        .buf_size = 16384,
    }, .{
        .client_headers_first = true,
    });
    defer creg.deinit();
    defer client.destroy();

    const conn = try creg.create(&client.client_connect_in);
    try creg.set(conn, &client.client_connect_in, h2.ConnectTarget, .{
        .addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, PORT),
    });

    var session: h2.Session = undefined;
    var connected = false;
    var ticks: u32 = 0;
    while (ticks < 200) : (ticks += 1) {
        try client.poll(0);
        try server.poll(0);
        const outs = client.client_connect_out.entitySlice();
        if (outs.len > 0) {
            session = (try creg.get(outs[0], &client.client_connect_out, h2.Session)).*;
            try creg.destroy(outs[0]);
            try creg.flush();
            connected = true;
            break;
        }
        if (client.client_connect_errors.entitySlice().len > 0) fail("connect error", .{});
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (!connected) fail("connect timeout", .{});

    // Peer SETTINGS must advertise Extended CONNECT before we submit.
    ticks = 0;
    while (ticks < 200 and !client.connExtendedConnect(session.entity)) : (ticks += 1) {
        try client.poll(0);
        try server.poll(0);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (!client.connExtendedConnect(session.entity)) fail("peer never advertised ENABLE_CONNECT_PROTOCOL", .{});

    // ── Open the tunnel ────────────────────────────────────────────────
    const hdrs = [_]h2.HeaderField{
        .{ .name = ":method", .name_len = 7, .value = "CONNECT", .value_len = 7 },
        .{ .name = ":protocol", .name_len = 9, .value = "websocket", .value_len = 9 },
        .{ .name = ":scheme", .name_len = 7, .value = "http", .value_len = 4 },
        .{ .name = ":path", .name_len = 5, .value = "/chat", .value_len = 5 },
        .{ .name = ":authority", .name_len = 10, .value = "acme.localhost", .value_len = 14 },
    };
    const req = try creg.create(&client.client_stream_request_in);
    try creg.set(req, &client.client_stream_request_in, h2.Session, session);
    try creg.set(req, &client.client_stream_request_in, h2.ReqHeaders, .{ .fields = @constCast(&hdrs), .count = hdrs.len });

    var collector: Collector = .{ .a = alloc };
    defer collector.bytes.deinit(alloc);

    // Pre-frame the two client payloads (masked).
    var hello_frame: std.ArrayList(u8) = .empty;
    defer hello_frame.deinit(alloc);
    try writeMaskedFrame(&hello_frame, alloc, 0x1, "hello");
    var close_frame: std.ArrayList(u8) = .empty;
    defer close_frame.deinit(alloc);
    try writeMaskedFrame(&close_frame, alloc, 0x8, &.{});

    var accepted = false;
    var got_200 = false;
    var sink_live = false;
    var server_saw_hello = false;
    var echoed = false;
    var got_echo = false;
    var sent_close = false;
    var server_saw_close = false;
    var client_terminal = false;
    var pending_send: ?[]const u8 = hello_frame.items;

    ticks = 0;
    while (ticks < 2000 and !client_terminal) : (ticks += 1) {
        try client.poll(0);
        try server.poll(0);
        std.Thread.sleep(1 * std.time.ns_per_ms);

        // ── server: disposition pending tunnels ──
        {
            const ents = server.ws_connect_out.entitySlice();
            if (ents.len > 0 and !accepted) {
                const r = server.wsStreamRouting(ents[0]) orelse fail("no routing on ws_connect_out", .{});
                if (!std.mem.eql(u8, r.authority, "acme.localhost")) fail("authority {s}", .{r.authority});
                if (!std.mem.eql(u8, r.path, "/chat")) fail("path {s}", .{r.path});
                if (server.wsConnectAccept(ents[0]) != .ok) fail("wsConnectAccept != ok", .{});
                accepted = true;
            }
            try sreg.flush();
        }

        // ── server: inbound messages → assert + echo / close ──
        {
            const ents = server.ws_message_out.entitySlice();
            const sessions = server.ws_message_out.column(h2.Session);
            const metas = server.ws_message_out.column(h2.WsMeta);
            const bodies = server.ws_message_out.column(h2.ReqBody);
            for (ents, sessions, metas, bodies) |ent, sess, meta, body| {
                const payload: []const u8 = if (body.data) |d| d[0..body.len] else "";
                if (meta.opcode == 8) {
                    server_saw_close = true;
                } else {
                    if (!std.mem.eql(u8, payload, "hello")) fail("server payload {s}", .{payload});
                    server_saw_hello = true;
                    // Echo it back through the seam surface.
                    const se = try sreg.create(&server.ws_send_in);
                    try sreg.set(se, &server.ws_send_in, h2.Session, .{ .entity = sess.entity });
                    try sreg.set(se, &server.ws_send_in, h2.WsMeta, .{ .opcode = 1 });
                    const dup = try alloc.dupe(u8, payload);
                    try sreg.set(se, &server.ws_send_in, h2.ReqBody, .{ .data = dup.ptr, .len = @intCast(dup.len) });
                    echoed = true;
                }
                try sreg.destroy(ent);
            }
            try sreg.flush();
        }

        // ── client: the CONNECT response head ──
        {
            const ents = client.client_response_receiving.entitySlice();
            const stats = client.client_response_receiving.column(h2.Status);
            const sids = client.client_response_receiving.column(h2.StreamId);
            const sessions = client.client_response_receiving.column(h2.Session);
            for (ents, stats, sids, sessions) |ent, st, sid, sess| {
                if (st.code != 200) fail("CONNECT status {d}", .{st.code});
                got_200 = true;
                switch (client.requestBodySink(sess.entity, sid.id, collector.sink())) {
                    .streaming, .eof => sink_live = true,
                    .gone => fail("response sink attach: gone", .{}),
                }
                try creg.destroy(ent);
            }
            try creg.flush();
        }

        // ── client: pump outbound tunnel bytes; END our side after the
        // Close frame went out (both sides END → full stream close →
        // the terminal fires) ──
        {
            const ents = client.client_stream_data_out.entitySlice();
            for (ents) |ent| {
                if (pending_send) |bytes| {
                    const copy = try alloc.dupe(u8, bytes);
                    try creg.set(ent, &client.client_stream_data_out, h2.ReqBody, .{ .data = copy.ptr, .len = @intCast(copy.len) });
                    try creg.move(ent, &client.client_stream_data_out, &client.client_stream_data_in);
                    if (bytes.ptr == close_frame.items.ptr) sent_close = true;
                    pending_send = null;
                } else if (sent_close) {
                    try creg.move(ent, &client.client_stream_data_out, &client.client_stream_close_in);
                }
            }
            try creg.flush();
        }

        // ── client: check collected tunnel bytes ──
        if (!got_echo and collector.bytes.items.len >= 7) {
            const want = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
            if (!std.mem.eql(u8, collector.bytes.items[0..7], &want))
                fail("echo bytes {any}", .{collector.bytes.items[0..7]});
            got_echo = true;
            pending_send = close_frame.items; // now close
        }

        // ── client: terminal ──
        {
            const ents = client.client_response_out.entitySlice();
            for (ents) |ent| {
                client_terminal = true;
                try creg.destroy(ent);
            }
            try creg.flush();
        }
    }

    if (!accepted) fail("tunnel never accepted", .{});
    if (!got_200) fail("no 200", .{});
    if (!sink_live) fail("no sink", .{});
    if (!server_saw_hello) fail("server never saw hello", .{});
    if (!echoed) fail("no echo queued", .{});
    if (!got_echo) fail("client never got echo", .{});
    if (!sent_close) fail("close never sent", .{});
    if (!server_saw_close) fail("server never saw close (opcode 8)", .{});
    if (!client_terminal) fail("no client terminal", .{});
    // The Close echo (0x88 0x00) should follow the text echo in the bytes.
    const tail = collector.bytes.items[7..];
    if (tail.len < 2 or tail[0] != 0x88) fail("no Close echo in tunnel bytes: {any}", .{tail});

    std.debug.print("PASS h2-ws-connect-test: CONNECT accepted (routing ok), masked frame in → message out, echo + Close echo relayed, terminal delivered\n", .{});
}
