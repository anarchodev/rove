const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const Row = rove.Row;
const Collection = rove.Collection;
const Registry = rove.Registry;
const Entity = rove.Entity;
pub const tls = @import("tls.zig");
pub const TlsConfig = tls.TlsConfig;

const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

// =============================================================================
// Component types
// =============================================================================

pub const HeaderField = struct {
    name: [*]const u8,
    name_len: u32,
    value: [*]const u8,
    value_len: u32,
};

pub const StreamId = struct {
    id: u32 = 0,
};

pub const Session = struct {
    entity: Entity = Entity.nil,
};

pub const ReqHeaders = struct {
    fields: ?[*]HeaderField = null,
    count: u32 = 0,
    _buf: ?[*]u8 = null,
    _buf_len: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []ReqHeaders) void {
        for (items) |*item| {
            if (item._buf) |buf| allocator.free(buf[0..item._buf_len]);
            item.fields = null;
            item.count = 0;
            item._buf = null;
            item._buf_len = 0;
        }
    }
};

pub const ReqBody = struct {
    data: ?[*]u8 = null,
    len: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []ReqBody) void {
        for (items) |*item| {
            if (item.data) |ptr| allocator.free(ptr[0..item.len]);
            item.data = null;
            item.len = 0;
        }
    }
};

pub const RespHeaders = struct {
    fields: ?[*]HeaderField = null,
    count: u32 = 0,
    _buf: ?[*]u8 = null,
    _buf_len: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []RespHeaders) void {
        for (items) |*item| {
            if (item._buf) |buf| allocator.free(buf[0..item._buf_len]);
            item.fields = null;
            item.count = 0;
            item._buf = null;
            item._buf_len = 0;
        }
    }
};

pub const RespBody = struct {
    data: ?[*]u8 = null,
    len: u32 = 0,

    pub fn deinit(allocator: std.mem.Allocator, items: []RespBody) void {
        for (items) |*item| {
            if (item.data) |ptr| allocator.free(ptr[0..item.len]);
            item.data = null;
            item.len = 0;
        }
    }
};

pub const Status = struct {
    code: u16 = 0,
};

pub const H2IoResult = struct {
    err: i32 = 0,
};

pub const Direction = enum(u8) { server = 0, client = 1 };

pub const Conn = struct {
    ng_session: ?*c.nghttp2_session = null,
    ng_ctx: ?*anyopaque = null,
    ng_ctx_destroy: ?*const fn (?*anyopaque) void = null,
    tls_conn: ?*tls.TlsConn = null,
    direction: Direction = .server,
    last_active_ns: u64 = 0,
    /// For client connections: the user's connect entity parked in _client_connect_pending.
    pending_connect_entity: Entity = Entity.nil,

    pub fn deinit(_: std.mem.Allocator, items: []Conn) void {
        for (items) |*item| {
            if (item.ng_session) |session| {
                _ = c.nghttp2_session_terminate_session(session, c.NGHTTP2_NO_ERROR);
                while (c.nghttp2_session_want_write(session) != 0) {
                    var data: [*c]const u8 = undefined;
                    const len = c.nghttp2_session_mem_send(session, &data);
                    if (len <= 0) break;
                }
                c.nghttp2_session_del(session);
                item.ng_session = null;
            }
            if (item.ng_ctx) |ctx| {
                if (item.ng_ctx_destroy) |destroy_fn| destroy_fn(ctx);
                item.ng_ctx = null;
            }
            if (item.tls_conn) |tc| {
                tc.destroy();
                item.tls_conn = null;
            }
        }
    }
};

// =============================================================================
// Stream accumulator (nghttp2 stream user_data)
// =============================================================================

const Stream = struct {
    conn_entity: Entity,
    allocator: std.mem.Allocator,
    hdr_fields: ?[*]HeaderField = null,
    hdr_count: u32 = 0,
    hdr_cap: u32 = 0,
    hdr_strbuf: ?[*]u8 = null,
    hdr_strbuf_len: u32 = 0,
    hdr_strbuf_cap: u32 = 0,
    body_data: ?[*]u8 = null,
    body_len: u32 = 0,
    body_cap: u32 = 0,
    entity: Entity = Entity.nil,
    emitted: bool = false,
    send_complete: bool = false,
    streaming: bool = false,
    client_stream: bool = false,
    stream_eof: bool = false,
    ng_stream_id: i32 = 0,
    send_data: ?*BodyData = null,
    response_status: u16 = 0,
    stream_chunk_data: ?[*]u8 = null,
    stream_chunk_len: u32 = 0,
    stream_chunk_offset: u32 = 0,

    fn create(conn_entity: Entity, allocator: std.mem.Allocator) ?*Stream {
        const s = allocator.create(Stream) catch return null;
        s.* = .{ .conn_entity = conn_entity, .allocator = allocator };
        return s;
    }

    fn free(self: *Stream) void {
        const allocator = self.allocator;
        if (self.hdr_fields) |f| allocator.free(@as([*]HeaderField, @ptrCast(@alignCast(f)))[0..self.hdr_cap]);
        if (self.hdr_strbuf) |b| allocator.free(b[0..self.hdr_strbuf_cap]);
        if (self.body_data) |p| allocator.free(p[0..self.body_cap]);
        if (self.send_data) |d| d.destroy();
        if (self.stream_chunk_data) |cd| allocator.free(cd[0..self.stream_chunk_len]);
        allocator.destroy(self);
    }

    fn hdrAppend(self: *Stream, name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize) bool {
        if (self.hdr_count == self.hdr_cap) {
            const new_cap = if (self.hdr_cap > 0) self.hdr_cap * 2 else 16;
            const old = if (self.hdr_fields) |f| @as([*]HeaderField, @ptrCast(@alignCast(f)))[0..self.hdr_cap] else @as([]HeaderField, &.{});
            const new_buf = self.allocator.realloc(old, new_cap) catch return false;
            self.hdr_fields = @ptrCast(new_buf.ptr);
            self.hdr_cap = @intCast(new_buf.len);
        }

        const need: u32 = @intCast(name_len + value_len);
        if (self.hdr_strbuf_len + need > self.hdr_strbuf_cap) {
            const new_cap = if (self.hdr_strbuf_cap > 0) self.hdr_strbuf_cap * 2 else 1024;
            const old = if (self.hdr_strbuf) |b| b[0..self.hdr_strbuf_cap] else @as([]u8, &.{});
            const new_buf = self.allocator.realloc(old, new_cap) catch return false;
            self.hdr_strbuf = new_buf.ptr;
            self.hdr_strbuf_cap = @intCast(new_buf.len);
        }

        const name_off = self.hdr_strbuf_len;
        @memcpy(self.hdr_strbuf.?[name_off .. name_off + @as(u32, @intCast(name_len))], name[0..name_len]);
        self.hdr_strbuf_len += @intCast(name_len);

        const value_off = self.hdr_strbuf_len;
        @memcpy(self.hdr_strbuf.?[value_off .. value_off + @as(u32, @intCast(value_len))], value[0..value_len]);
        self.hdr_strbuf_len += @intCast(value_len);

        self.hdr_fields.?[self.hdr_count] = .{
            .name = @ptrFromInt(name_off + 1),
            .name_len = @intCast(name_len),
            .value = @ptrFromInt(value_off + 1),
            .value_len = @intCast(value_len),
        };
        self.hdr_count += 1;
        return true;
    }

    fn hdrFinalize(self: *Stream, out_fields: *?[*]HeaderField, out_count: *u32, out_buf_len: *u32) ?[*]u8 {
        const n = self.hdr_count;
        if (n == 0) {
            out_fields.* = null;
            out_count.* = 0;
            out_buf_len.* = 0;
            return null;
        }

        const fields_size = @as(usize, n) * @sizeOf(HeaderField);
        const total = fields_size + self.hdr_strbuf_len;
        const buf_slice = self.allocator.alloc(u8, total) catch return null;
        const buf_ptr: [*]u8 = buf_slice.ptr;

        const strbuf_base = buf_ptr + fields_size;
        @memcpy(strbuf_base[0..self.hdr_strbuf_len], self.hdr_strbuf.?[0..self.hdr_strbuf_len]);

        const result_fields: [*]HeaderField = @ptrCast(@alignCast(buf_ptr));
        for (0..n) |i| {
            const src = self.hdr_fields.?[i];
            result_fields[i] = .{
                .name = strbuf_base + (@intFromPtr(src.name) - 1),
                .name_len = src.name_len,
                .value = strbuf_base + (@intFromPtr(src.value) - 1),
                .value_len = src.value_len,
            };
        }

        out_fields.* = result_fields;
        out_count.* = n;
        out_buf_len.* = @intCast(total);
        return buf_ptr;
    }

    fn bodyAppend(self: *Stream, data: [*]const u8, len: usize) bool {
        const need: u32 = @intCast(len);
        const required = self.body_len + need;
        if (required > self.body_cap) {
            // Grow to AT LEAST `required`, not just one doubling
            // past the old capacity. A single inbound DATA frame can
            // be larger than `body_cap * 2` — for example an empty
            // stream (body_cap=0) receiving a 6 KB chunk on the
            // first call. Only doubling once leaves `new_cap = 4096`
            // while the memcpy below writes 6 KB, overrunning by 2 KB
            // and corrupting whatever allocation sits next in the
            // heap. The canary on that allocation then fails on its
            // next free, and you get an "Invalid free" panic several
            // code paths away from the actual bug. Loop until the
            // new capacity actually covers `required`.
            var new_cap: u32 = if (self.body_cap > 0) self.body_cap else 4096;
            while (new_cap < required) new_cap *= 2;
            const old = if (self.body_data) |p| p[0..self.body_cap] else @as([]u8, &.{});
            const new_buf = self.allocator.realloc(old, new_cap) catch return false;
            self.body_data = new_buf.ptr;
            self.body_cap = @intCast(new_buf.len);
        }
        @memcpy(self.body_data.?[self.body_len .. self.body_len + need], data[0..len]);
        self.body_len += need;
        return true;
    }
};

const BodyData = struct {
    data: []const u8,
    offset: u32 = 0,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, data: [*]const u8, len: u32) ?*BodyData {
        const copy = allocator.alloc(u8, len) catch return null;
        @memcpy(copy, data[0..len]);
        const bd = allocator.create(BodyData) catch {
            allocator.free(copy);
            return null;
        };
        bd.* = .{ .data = copy, .allocator = allocator };
        return bd;
    }

    fn destroy(self: *BodyData) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};

fn monotonicNs() u64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

// =============================================================================
// Base row types
// =============================================================================

const StreamBaseRow = Row(&.{ StreamId, Session, ReqHeaders, ReqBody, RespHeaders, RespBody, Status, H2IoResult });

// =============================================================================
// Options
// =============================================================================

pub const ConnectTarget = struct {
    addr: std.net.Address,
    hostname: ?[*]const u8 = null,
    hostname_len: u32 = 0,
};

pub const Options = struct {
    request_row: type = Row(&.{}),
    connection_row: type = Row(&.{}),
    client: bool = false,
};

pub const H2Options = struct {
    max_concurrent_streams: u32 = 128,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 0,
    max_h2_connections: u32 = 0,
    idle_timeout_ns: u64 = 0,
    tls_config: ?*TlsConfig = null,
};

// =============================================================================
// H2 — HTTP/2 runtime
// =============================================================================

pub fn H2(comptime opts: Options) type {
    const stream_row = StreamBaseRow.merge(opts.request_row);
    const connect_row_full = Row(&.{ ConnectTarget, Session, H2IoResult }).merge(opts.request_row);
    const full_conn_row = rio.ConnectionBaseRow.merge(Row(&.{Conn})).merge(opts.connection_row);

    const has_client = opts.client;

    // Rove-io type for this h2 configuration
    const IoType = rio.Io(.{
        .connection_row = Row(&.{Conn}).merge(opts.connection_row),
        .connect = has_client,
    });

    // Collection types (for comptime)
    const StreamColl = Collection(stream_row, .{});
    const ReadColl = Collection(rio.ReadBaseRow, .{});
    const ConnColl = Collection(full_conn_row, .{});

    const ClientConnectColl = if (has_client) Collection(connect_row_full, .{}) else void;
    const ClientStreamColl = if (has_client) Collection(stream_row, .{}) else void;

    return struct {
        const Self = @This();

        // Public row types (for external access)
        pub const StreamRow = stream_row;
        pub const ConnectionRow = full_conn_row;

        // The io instance (heap-allocated by rio.Io.create)
        io: *IoType,

        // H2-specific collections: server request/response
        request_out: StreamColl,
        response_in: StreamColl,
        response_out: StreamColl,
        _response_sending: StreamColl,

        // Streaming response collections
        stream_response_in: StreamColl,
        stream_data_out: StreamColl,
        stream_data_in: StreamColl,
        stream_close_in: StreamColl,
        _stream_data_sending: StreamColl,

        // Read triage
        _read_errors: ReadColl,
        _read_init: ReadColl,
        _read_active: ReadColl,
        _read_handshake: ReadColl,

        // Connection pipeline
        _conn_tls_handshake: ConnColl,
        _conn_active: ConnColl,

        // Client connect lifecycle (conditional)
        client_connect_in: ClientConnectColl,
        client_connect_out: ClientConnectColl,
        client_connect_errors: ClientConnectColl,
        _client_connect_pending: ClientConnectColl,

        // Client request/response (conditional)
        client_request_in: ClientStreamColl,
        client_response_out: ClientStreamColl,
        _client_request_sending: ClientStreamColl,

        // Client streaming (conditional)
        client_stream_request_in: ClientStreamColl,
        client_stream_data_out: ClientStreamColl,
        client_stream_data_in: ClientStreamColl,
        client_stream_close_in: ClientStreamColl,
        _client_stream_data_sending: ClientStreamColl,

        h2_opts: H2Options,
        reg: *Registry,
        allocator: std.mem.Allocator,

        // Shared nghttp2 callbacks — one per H2 instantiation
        var ng_callbacks: ?*c.nghttp2_session_callbacks = null;
        var ng_client_callbacks: ?*c.nghttp2_session_callbacks = null;

        // =============================================================
        // NgCtx — nghttp2 session user_data, holds *Self for collection access
        // =============================================================

        const NgCtx = struct {
            h2: *Self,
            allocator: std.mem.Allocator,
            conn_entity: Entity = Entity.nil,
        };

        // =============================================================
        // Helpers for entity dispatch across collections
        // =============================================================

        /// All collections a server stream entity can be in between request_out and response_out.
        inline fn serverStreamColls(h2: *Self) [8]*StreamColl {
            return .{
                &h2.request_out,
                &h2.response_in,
                &h2._response_sending,
                &h2.stream_response_in,
                &h2.stream_data_out,
                &h2.stream_data_in,
                &h2.stream_close_in,
                &h2._stream_data_sending,
            };
        }

        /// All collections a client stream entity can be in between client_request_in and client_response_out.
        inline fn clientStreamColls(h2: *Self) [7]*ClientStreamColl {
            return .{
                &h2.client_request_in,
                &h2._client_request_sending,
                &h2.client_stream_request_in,
                &h2.client_stream_data_out,
                &h2.client_stream_data_in,
                &h2.client_stream_close_in,
                &h2._client_stream_data_sending,
            };
        }

        /// All collections a connection entity can be in (io's + h2's).
        inline fn connColls(h2: *Self) struct { *@TypeOf(h2.io.connections), *ConnColl, *ConnColl } {
            return .{ &h2.io.connections, &h2._conn_tls_handshake, &h2._conn_active };
        }

        /// Find the current collection of a server stream entity, set H2IoResult, and move to response_out.
        fn serverStreamClose(h2: *Self, entity: Entity, err: i32) void {
            for (h2.serverStreamColls()) |src| {
                if (h2.reg.isInCollection(entity, src)) {
                    h2.reg.set(entity, src, H2IoResult, .{ .err = err }) catch {};
                    h2.reg.move(entity, src, &h2.response_out) catch {};
                    return;
                }
            }
        }

        /// Find a stream entity's current collection and set a component (shared among stream collections).
        fn streamSet(h2: *Self, entity: Entity, comptime T: type, value: T) void {
            for (h2.serverStreamColls()) |src| {
                if (h2.reg.isInCollection(entity, src)) {
                    h2.reg.set(entity, src, T, value) catch {};
                    return;
                }
            }
            if (comptime has_client) {
                for (h2.clientStreamColls()) |src| {
                    if (h2.reg.isInCollection(entity, src)) {
                        h2.reg.set(entity, src, T, value) catch {};
                        return;
                    }
                }
            }
        }

        /// Find the current collection of a client stream entity, set H2IoResult, and move to client_response_out.
        fn clientStreamClose(h2: *Self, entity: Entity, err: i32) void {
            if (!has_client) return;
            for (h2.clientStreamColls()) |src| {
                if (h2.reg.isInCollection(entity, src)) {
                    h2.reg.set(entity, src, H2IoResult, .{ .err = err }) catch {};
                    h2.reg.move(entity, src, &h2.client_response_out) catch {};
                    return;
                }
            }
        }

        /// Get the Conn component for a connection entity (searches the three conn collections).
        fn getConn(h2: *Self, entity: Entity) ?*Conn {
            return h2.reg.getAny(entity, h2.connColls(), Conn) catch null;
        }

        /// FD resolver callback for io — searches h2's connection collections in addition to io's.
        fn resolveFdThunk(ctx: *anyopaque, entity: Entity) ?*rio.Fd {
            const h2: *Self = @ptrCast(@alignCast(ctx));
            return h2.reg.getAny(entity, h2.connColls(), rio.Fd) catch null;
        }

        // =============================================================
        // nghttp2 server callbacks
        // =============================================================

        fn onBeginHeadersCb(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            if (frame.*.hd.type != c.NGHTTP2_HEADERS or
                frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST)
                return 0;

            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
            const stream = Stream.create(nctx.conn_entity, nctx.allocator) orelse
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;

            _ = c.nghttp2_session_set_stream_user_data(session, frame.*.hd.stream_id, @ptrCast(stream));
            return 0;
        }

        fn onHeaderCb(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            name: [*c]const u8,
            name_len: usize,
            value: [*c]const u8,
            value_len: usize,
            flags: u8,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            _ = user_data;
            if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;

            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null) return 0;

            if (!stream.?.hdrAppend(name, name_len, value, value_len))
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onDataChunkRecvCb(
            session: ?*c.nghttp2_session,
            flags: u8,
            stream_id: i32,
            data: [*c]const u8,
            len: usize,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            _ = user_data;
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, stream_id),
            ));
            if (stream == null) return 0;

            if (!stream.?.bodyAppend(data, len))
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onFrameRecvCb(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            if (frame.*.hd.type != c.NGHTTP2_HEADERS and frame.*.hd.type != c.NGHTTP2_DATA)
                return 0;
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0)
                return 0;

            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null or stream.?.emitted) return 0;

            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
            const s = stream.?;
            s.emitted = true;
            s.ng_stream_id = frame.*.hd.stream_id;

            const h2 = nctx.h2;

            // Create request entity in request_out
            const req_entity = h2.reg.create(&h2.request_out) catch
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;

            var fields: ?[*]HeaderField = null;
            var count: u32 = 0;
            var buf_len: u32 = 0;
            const hdr_buf = s.hdrFinalize(&fields, &count, &buf_len);

            h2.reg.set(req_entity, &h2.request_out, StreamId, .{ .id = @intCast(frame.*.hd.stream_id) }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            h2.reg.set(req_entity, &h2.request_out, Session, .{ .entity = nctx.conn_entity }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            h2.reg.set(req_entity, &h2.request_out, ReqHeaders, .{ .fields = fields, .count = count, ._buf = hdr_buf, ._buf_len = buf_len }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;

            const body_data = if (s.body_data) |p| blk: {
                if (s.body_len < s.body_cap) {
                    const shrunk = s.allocator.realloc(p[0..s.body_cap], s.body_len) catch p[0..s.body_cap];
                    break :blk @as(?[*]u8, shrunk.ptr);
                }
                break :blk @as(?[*]u8, p);
            } else null;
            h2.reg.set(req_entity, &h2.request_out, ReqBody, .{ .data = body_data, .len = s.body_len }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;

            s.body_data = null;
            s.body_len = 0;
            s.body_cap = 0;
            s.entity = req_entity;
            return 0;
        }

        fn onStreamCloseCb(
            session: ?*c.nghttp2_session,
            stream_id: i32,
            error_code: u32,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, stream_id),
            ));
            if (stream == null) return 0;

            const s = stream.?;
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));

            if (s.emitted and !s.entity.isNil() and !nctx.h2.reg.isStale(s.entity)) {
                const err: i32 = if (s.send_complete and error_code == 0) 0 else -1;
                serverStreamClose(nctx.h2, s.entity, err);
            }

            s.send_data = null;
            _ = c.nghttp2_session_set_stream_user_data(session, stream_id, null);
            s.free();
            return 0;
        }

        fn onDataSourceReadCb(
            session: ?*c.nghttp2_session,
            stream_id: i32,
            buf: [*c]u8,
            length: usize,
            data_flags: [*c]u32,
            source: [*c]c.nghttp2_data_source,
            user_data: ?*anyopaque,
        ) callconv(.c) c.nghttp2_ssize {
            // --- Streaming path ---
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, stream_id),
            ));
            if (stream) |s| {
                if (s.streaming) {
                    if (s.stream_eof and s.stream_chunk_data == null) {
                        data_flags[0] |= @intCast(c.NGHTTP2_DATA_FLAG_EOF);
                        s.send_complete = true;
                        return 0;
                    }
                    if (s.stream_chunk_data == null)
                        return c.NGHTTP2_ERR_DEFERRED;

                    const remaining = s.stream_chunk_len - s.stream_chunk_offset;
                    const to_copy: u32 = if (remaining < @as(u32, @intCast(length))) remaining else @intCast(length);
                    @memcpy(buf[0..to_copy], s.stream_chunk_data.?[s.stream_chunk_offset .. s.stream_chunk_offset + to_copy]);
                    s.stream_chunk_offset += to_copy;

                    if (s.stream_chunk_offset >= s.stream_chunk_len) {
                        s.allocator.free(s.stream_chunk_data.?[0..s.stream_chunk_len]);
                        s.stream_chunk_data = null;
                        s.stream_chunk_len = 0;
                        s.stream_chunk_offset = 0;

                        const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
                        const h2 = nctx.h2;
                        if (comptime has_client) {
                            if (s.client_stream) {
                                h2.reg.move(s.entity, &h2._client_stream_data_sending, &h2.client_stream_data_out) catch {};
                            } else {
                                h2.reg.move(s.entity, &h2._stream_data_sending, &h2.stream_data_out) catch {};
                            }
                        } else {
                            h2.reg.move(s.entity, &h2._stream_data_sending, &h2.stream_data_out) catch {};
                        }
                    }
                    return @intCast(to_copy);
                }
            }

            // --- Non-streaming path ---
            const rd: *BodyData = @ptrCast(@alignCast(source.*.ptr));
            const data_len: u32 = @intCast(rd.data.len);
            const remaining = data_len - rd.offset;
            const to_copy: u32 = if (remaining < @as(u32, @intCast(length))) remaining else @intCast(length);

            @memcpy(buf[0..to_copy], rd.data[rd.offset .. rd.offset + to_copy]);
            rd.offset += to_copy;

            if (rd.offset >= data_len) {
                data_flags[0] |= @intCast(c.NGHTTP2_DATA_FLAG_EOF);
                if (stream) |s| {
                    s.send_complete = true;
                    s.send_data = null;
                }
                rd.destroy();
            }
            return @intCast(to_copy);
        }

        // =============================================================
        // Session management
        // =============================================================

        fn ensureCallbacks() !void {
            if (ng_callbacks != null) return;

            var cbs: ?*c.nghttp2_session_callbacks = null;
            if (c.nghttp2_session_callbacks_new(&cbs) != 0)
                return error.OutOfMemory;

            c.nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, &onBeginHeadersCb);
            c.nghttp2_session_callbacks_set_on_header_callback(cbs, &onHeaderCb);
            c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, &onDataChunkRecvCb);
            c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, &onFrameRecvCb);
            c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, &onStreamCloseCb);

            ng_callbacks = cbs;
        }

        fn destroyNgCtx(ptr: ?*anyopaque) void {
            if (ptr) |p| {
                const nctx: *NgCtx = @ptrCast(@alignCast(p));
                nctx.allocator.destroy(nctx);
            }
        }

        fn sessionCreate(self: *Self, conn: *Conn, conn_entity: Entity) !void {
            try ensureCallbacks();

            const nctx = try self.allocator.create(NgCtx);
            nctx.* = .{ .h2 = self, .allocator = self.allocator, .conn_entity = conn_entity };

            var session: ?*c.nghttp2_session = null;
            if (c.nghttp2_session_server_new(&session, ng_callbacks, @ptrCast(nctx)) != 0) {
                self.allocator.destroy(nctx);
                return error.Nghttp2SessionCreateFailed;
            }

            conn.ng_session = session;
            conn.ng_ctx = @ptrCast(nctx);
            conn.ng_ctx_destroy = &destroyNgCtx;

            var settings_buf: [4]c.nghttp2_settings_entry = undefined;
            var settings_count: usize = 0;

            settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = self.h2_opts.max_concurrent_streams };
            settings_count += 1;

            if (self.h2_opts.initial_window_size != 65535) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = self.h2_opts.initial_window_size };
                settings_count += 1;
            }
            if (self.h2_opts.max_frame_size != 16384) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE, .value = self.h2_opts.max_frame_size };
                settings_count += 1;
            }
            if (self.h2_opts.max_header_list_size != 0) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = self.h2_opts.max_header_list_size };
                settings_count += 1;
            }

            if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings_buf, settings_count) != 0) {
                c.nghttp2_session_del(session);
                self.allocator.destroy(nctx);
                conn.ng_session = null;
                conn.ng_ctx = null;
                return error.Nghttp2SettingsFailed;
            }
        }

        // =============================================================
        // Client: nghttp2 callbacks
        // =============================================================

        fn onHeaderClientCb(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            name: [*c]const u8,
            name_len: usize,
            value: [*c]const u8,
            value_len: usize,
            flags: u8,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            _ = user_data;
            if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;

            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null) return 0;
            const s = stream.?;

            if (name_len == 7 and std.mem.eql(u8, name[0..7], ":status")) {
                var buf: [4]u8 = undefined;
                const n = @min(value_len, 3);
                @memcpy(buf[0..n], value[0..n]);
                buf[n] = 0;
                s.response_status = std.fmt.parseInt(u16, buf[0..n], 10) catch 0;
                return 0;
            }

            if (!s.hdrAppend(name, name_len, value, value_len))
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onFrameRecvClientCb(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            if (frame.*.hd.type != c.NGHTTP2_HEADERS and frame.*.hd.type != c.NGHTTP2_DATA)
                return 0;
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0)
                return 0;

            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null) return 0;

            const s = stream.?;
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
            const h2 = nctx.h2;

            if (!s.entity.isNil() and !h2.reg.isStale(s.entity)) {
                var fields: ?[*]HeaderField = null;
                var count: u32 = 0;
                var buf_len: u32 = 0;
                const hdr_buf = s.hdrFinalize(&fields, &count, &buf_len);

                streamSet(h2, s.entity, RespHeaders, .{
                    .fields = fields,
                    .count = count,
                    ._buf = hdr_buf,
                    ._buf_len = buf_len,
                });

                const body_data = if (s.body_data) |p| blk: {
                    if (s.body_len < s.body_cap) {
                        const shrunk = s.allocator.realloc(p[0..s.body_cap], s.body_len) catch p[0..s.body_cap];
                        break :blk @as(?[*]u8, shrunk.ptr);
                    }
                    break :blk @as(?[*]u8, p);
                } else null;
                streamSet(h2, s.entity, RespBody, .{ .data = body_data, .len = s.body_len });
                streamSet(h2, s.entity, Status, .{ .code = s.response_status });

                s.body_data = null;
                s.body_len = 0;
                s.body_cap = 0;
            }

            return 0;
        }

        fn onStreamCloseClientCb(
            session: ?*c.nghttp2_session,
            stream_id: i32,
            error_code: u32,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, stream_id),
            ));
            if (stream == null) return 0;

            const s = stream.?;
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));

            if (!s.entity.isNil() and !nctx.h2.reg.isStale(s.entity)) {
                const err: i32 = if (error_code == 0) 0 else -1;
                clientStreamClose(nctx.h2, s.entity, err);
            }

            s.send_data = null;
            _ = c.nghttp2_session_set_stream_user_data(session, stream_id, null);
            s.free();
            return 0;
        }

        fn ensureClientCallbacks() !void {
            if (ng_client_callbacks != null) return;

            var cbs: ?*c.nghttp2_session_callbacks = null;
            if (c.nghttp2_session_callbacks_new(&cbs) != 0)
                return error.OutOfMemory;

            c.nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, &onBeginHeadersCb);
            c.nghttp2_session_callbacks_set_on_header_callback(cbs, &onHeaderClientCb);
            c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, &onDataChunkRecvCb);
            c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, &onFrameRecvClientCb);
            c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, &onStreamCloseClientCb);

            ng_client_callbacks = cbs;
        }

        fn clientSessionCreate(self: *Self, conn: *Conn, conn_entity: Entity) !void {
            try ensureClientCallbacks();

            const nctx = try self.allocator.create(NgCtx);
            nctx.* = .{ .h2 = self, .allocator = self.allocator, .conn_entity = conn_entity };

            var session: ?*c.nghttp2_session = null;
            if (c.nghttp2_session_client_new(&session, ng_client_callbacks, @ptrCast(nctx)) != 0) {
                self.allocator.destroy(nctx);
                return error.Nghttp2SessionCreateFailed;
            }

            conn.ng_session = session;
            conn.ng_ctx = @ptrCast(nctx);
            conn.ng_ctx_destroy = &destroyNgCtx;

            var settings_buf: [2]c.nghttp2_settings_entry = undefined;
            var settings_count: usize = 0;
            settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = self.h2_opts.max_concurrent_streams };
            settings_count += 1;

            if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings_buf, settings_count) != 0) {
                c.nghttp2_session_del(session);
                self.allocator.destroy(nctx);
                conn.ng_session = null;
                conn.ng_ctx = null;
                return error.Nghttp2SettingsFailed;
            }
        }

        // =============================================================
        // Public API
        // =============================================================

        pub fn create(reg: *Registry, allocator: std.mem.Allocator, addr: std.net.Address, io_opts: rio.IoOptions, h2_opts: H2Options) !*Self {
            try ensureCallbacks();

            const io = try IoType.create(reg, allocator, addr, io_opts);
            errdefer io.destroy();

            const self = try allocator.create(Self);
            self.* = .{
                .io = io,
                .request_out = try StreamColl.init(allocator),
                .response_in = try StreamColl.init(allocator),
                .response_out = try StreamColl.init(allocator),
                ._response_sending = try StreamColl.init(allocator),
                .stream_response_in = try StreamColl.init(allocator),
                .stream_data_out = try StreamColl.init(allocator),
                .stream_data_in = try StreamColl.init(allocator),
                .stream_close_in = try StreamColl.init(allocator),
                ._stream_data_sending = try StreamColl.init(allocator),
                ._read_errors = try ReadColl.init(allocator),
                ._read_init = try ReadColl.init(allocator),
                ._read_active = try ReadColl.init(allocator),
                ._read_handshake = try ReadColl.init(allocator),
                ._conn_tls_handshake = try ConnColl.init(allocator),
                ._conn_active = try ConnColl.init(allocator),
                .client_connect_in = if (has_client) try ClientConnectColl.init(allocator) else {},
                .client_connect_out = if (has_client) try ClientConnectColl.init(allocator) else {},
                .client_connect_errors = if (has_client) try ClientConnectColl.init(allocator) else {},
                ._client_connect_pending = if (has_client) try ClientConnectColl.init(allocator) else {},
                .client_request_in = if (has_client) try ClientStreamColl.init(allocator) else {},
                .client_response_out = if (has_client) try ClientStreamColl.init(allocator) else {},
                ._client_request_sending = if (has_client) try ClientStreamColl.init(allocator) else {},
                .client_stream_request_in = if (has_client) try ClientStreamColl.init(allocator) else {},
                .client_stream_data_out = if (has_client) try ClientStreamColl.init(allocator) else {},
                .client_stream_data_in = if (has_client) try ClientStreamColl.init(allocator) else {},
                .client_stream_close_in = if (has_client) try ClientStreamColl.init(allocator) else {},
                ._client_stream_data_sending = if (has_client) try ClientStreamColl.init(allocator) else {},
                .h2_opts = h2_opts,
                .reg = reg,
                .allocator = allocator,
            };

            // Register all collections
            reg.registerCollection(&self.request_out);
            reg.registerCollection(&self.response_in);
            reg.registerCollection(&self.response_out);
            reg.registerCollection(&self._response_sending);
            reg.registerCollection(&self.stream_response_in);
            reg.registerCollection(&self.stream_data_out);
            reg.registerCollection(&self.stream_data_in);
            reg.registerCollection(&self.stream_close_in);
            reg.registerCollection(&self._stream_data_sending);
            reg.registerCollection(&self._read_errors);
            reg.registerCollection(&self._read_init);
            reg.registerCollection(&self._read_active);
            reg.registerCollection(&self._read_handshake);
            reg.registerCollection(&self._conn_tls_handshake);
            reg.registerCollection(&self._conn_active);
            if (has_client) {
                reg.registerCollection(&self.client_connect_in);
                reg.registerCollection(&self.client_connect_out);
                reg.registerCollection(&self.client_connect_errors);
                reg.registerCollection(&self._client_connect_pending);
                reg.registerCollection(&self.client_request_in);
                reg.registerCollection(&self.client_response_out);
                reg.registerCollection(&self._client_request_sending);
                reg.registerCollection(&self.client_stream_request_in);
                reg.registerCollection(&self.client_stream_data_out);
                reg.registerCollection(&self.client_stream_data_in);
                reg.registerCollection(&self.client_stream_close_in);
                reg.registerCollection(&self._client_stream_data_sending);
            }

            // Register FD resolver with io so that processWriteIn/processReadIn
            // can find connection Fds when h2 has moved them to _conn_active etc.
            self.io.setFdResolver(@ptrCast(self), &resolveFdThunk);

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.request_out.deinit();
            self.response_in.deinit();
            self.response_out.deinit();
            self._response_sending.deinit();
            self.stream_response_in.deinit();
            self.stream_data_out.deinit();
            self.stream_data_in.deinit();
            self.stream_close_in.deinit();
            self._stream_data_sending.deinit();
            self._read_errors.deinit();
            self._read_init.deinit();
            self._read_active.deinit();
            self._read_handshake.deinit();
            self._conn_tls_handshake.deinit();
            self._conn_active.deinit();
            if (has_client) {
                self.client_connect_in.deinit();
                self.client_connect_out.deinit();
                self.client_connect_errors.deinit();
                self._client_connect_pending.deinit();
                self.client_request_in.deinit();
                self.client_response_out.deinit();
                self._client_request_sending.deinit();
                self.client_stream_request_in.deinit();
                self.client_stream_data_out.deinit();
                self.client_stream_data_in.deinit();
                self.client_stream_close_in.deinit();
                self._client_stream_data_sending.deinit();
            }
            self.io.destroy();
            allocator.destroy(self);
        }

        pub fn poll(self: *Self, min_complete: u32) !void {
            try self.pollPrelude();
            // Phase 3: io.poll submits pending writes and (optionally) waits for CQEs.
            _ = try self.io.poll(min_complete);
            try self.pollPostlude();
        }

        /// Like `poll(1)` but with a wall-clock upper bound. Used by
        /// outer poll loops with external state needing periodic
        /// attention — see rove-io's `pollWithTimeout` doc and
        /// rove-library memory rule #13.
        pub fn pollWithTimeout(self: *Self, timeout_ns: u64) !void {
            try self.pollPrelude();
            _ = try self.io.pollWithTimeout(timeout_ns);
            try self.pollPostlude();
        }

        fn pollPrelude(self: *Self) !void {
            // Phase 1: Consume user inputs queued between polls (responses, chunks).
            // Must run before io.poll so the writes they generate can be submitted
            // in the same iteration.
            try self.consumeResponses();
            try self.consumeStreamResponses();
            try self.consumeStreamData();
            try self.consumeStreamClose();
            if (has_client) {
                try self.consumeConnectRequests();
                try self.consumeClientRequests();
                try self.consumeClientStreamRequests();
                try self.consumeClientStreamData();
                try self.consumeClientStreamClose();
            }
            try self.reg.flush();

            // Phase 2: Drive nghttp2 sends — converts queued responses/chunks into
            // write_in entities that io.poll will submit below.
            try self.driveAllSends();
            try self.reg.flush();
        }

        fn pollPostlude(self: *Self) !void {

            // Phase 4: Triage reads that just arrived.
            try self.readsTriage();
            try self.reg.flush();

            try self.readsHandleErrors();
            try self.reg.flush();

            if (has_client) {
                try self.processConnectResults();
                try self.processConnectErrors();
                try self.reg.flush();
            }

            try self.readsInitConnections();
            try self.reg.flush();

            try self.transitionNewConnections();
            try self.reg.flush();

            if (self.h2_opts.tls_config != null) {
                try self.readsTlsHandshake();
                try self.reg.flush();

                try self.transitionHandshakeConnections();
                try self.reg.flush();
            }

            // Phase 5: Feed read data to nghttp2 — triggers callbacks that create
            // request entities for the user to pick up.
            try self.readsFeedData();
            try self.reg.flush();

            try self.writesAccount();
            try self.reg.flush();
        }

        // =============================================================
        // Phase 1: Consume user responses
        // =============================================================

        fn consumeResponses(self: *Self) !void {
            const entities = self.response_in.entitySlice();
            const sessions = self.response_in.column(Session);
            const sids = self.response_in.column(StreamId);
            const statuses = self.response_in.column(Status);
            const resp_hdrs = self.response_in.column(RespHeaders);
            const resp_bodies = self.response_in.column(RespBody);
            const io_results = self.response_in.column(H2IoResult);

            for (entities, sessions, sids, statuses, resp_hdrs, resp_bodies, io_results) |ent, sess, sid, status, rh, rb, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.response_in, &self.response_out);
                    continue;
                };

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.response_in, &self.response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                var status_buf: [3]u8 = undefined;
                const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status.code}) catch "500";
                const status_len = status_str.len;

                const nv_count: usize = 1 + @as(usize, rh.count);
                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.response_in, &self.response_out);
                    continue;
                };
                const nva: [*]c.nghttp2_nv = nva_slice.ptr;
                defer self.allocator.free(nva_slice);

                nva[0] = .{
                    .name = @constCast(@ptrCast(":status")),
                    .namelen = 7,
                    .value = @constCast(&status_buf),
                    .valuelen = status_len,
                    .flags = c.NGHTTP2_NV_FLAG_NO_COPY_NAME,
                };

                if (rh.fields) |fields| {
                    for (0..rh.count) |j| {
                        nva[1 + j] = .{
                            .name = @constCast(fields[j].name),
                            .namelen = fields[j].name_len,
                            .value = @constCast(fields[j].value),
                            .valuelen = fields[j].value_len,
                            .flags = c.NGHTTP2_NV_FLAG_NO_COPY_NAME | c.NGHTTP2_NV_FLAG_NO_COPY_VALUE,
                        };
                    }
                }

                var data_prd: c.nghttp2_data_provider = std.mem.zeroes(c.nghttp2_data_provider);
                var body_data_ptr: ?*BodyData = null;
                if (rb.data != null and rb.len > 0) {
                    body_data_ptr = BodyData.create(self.allocator, rb.data.?, rb.len) orelse {
                        io_res.err = -1;
                        try self.reg.move(ent, &self.response_in, &self.response_out);
                        continue;
                    };
                    data_prd.source = .{ .ptr = @ptrCast(body_data_ptr) };
                    data_prd.read_callback = &onDataSourceReadCb;
                }

                const rv = c.nghttp2_submit_response(ng_session, @intCast(sid.id), nva, nv_count, if (data_prd.read_callback != null) &data_prd else null);

                if (rv < 0) {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, &self.response_in, &self.response_out);
                    continue;
                }

                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream) |s| {
                    s.entity = ent;
                    s.send_complete = (data_prd.read_callback == null);
                    s.send_data = body_data_ptr;
                    try self.reg.move(ent, &self.response_in, &self._response_sending);
                } else {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, &self.response_in, &self.response_out);
                }
            }
        }

        // =============================================================
        // Streaming: consume stream_response_in
        // =============================================================

        fn consumeStreamResponses(self: *Self) !void {
            const entities = self.stream_response_in.entitySlice();
            const sessions = self.stream_response_in.column(Session);
            const sids = self.stream_response_in.column(StreamId);
            const statuses = self.stream_response_in.column(Status);
            const resp_hdrs = self.stream_response_in.column(RespHeaders);
            const io_results = self.stream_response_in.column(H2IoResult);

            for (entities, sessions, sids, statuses, resp_hdrs, io_results) |ent, sess, sid, status, rh, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                var status_buf: [3]u8 = undefined;
                const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status.code}) catch "500";

                const nv_count: usize = 1 + @as(usize, rh.count);
                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                    continue;
                };
                const nva: [*]c.nghttp2_nv = nva_slice.ptr;
                defer self.allocator.free(nva_slice);

                nva[0] = .{
                    .name = @constCast(@ptrCast(":status")),
                    .namelen = 7,
                    .value = @constCast(&status_buf),
                    .valuelen = status_str.len,
                    .flags = c.NGHTTP2_NV_FLAG_NO_COPY_NAME,
                };
                if (rh.fields) |fields| {
                    for (0..rh.count) |j| {
                        nva[1 + j] = .{
                            .name = @constCast(fields[j].name),
                            .namelen = fields[j].name_len,
                            .value = @constCast(fields[j].value),
                            .valuelen = fields[j].value_len,
                            .flags = c.NGHTTP2_NV_FLAG_NO_COPY_NAME | c.NGHTTP2_NV_FLAG_NO_COPY_VALUE,
                        };
                    }
                }

                var data_prd = c.nghttp2_data_provider{
                    .source = .{ .ptr = null },
                    .read_callback = &onDataSourceReadCb,
                };

                const rv = c.nghttp2_submit_response(ng_session, @intCast(sid.id), nva, nv_count, &data_prd);
                if (rv < 0) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                    continue;
                }

                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream) |s| {
                    s.entity = ent;
                    s.emitted = true;
                    s.streaming = true;
                    s.send_complete = false;
                    s.send_data = null;
                    try self.reg.move(ent, &self.stream_response_in, &self.stream_data_out);
                } else {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                }
            }
        }

        // =============================================================
        // Streaming: consume stream_data_in
        // =============================================================

        fn consumeStreamData(self: *Self) !void {
            const entities = self.stream_data_in.entitySlice();
            const sessions = self.stream_data_in.column(Session);
            const sids = self.stream_data_in.column(StreamId);
            const resp_bodies = self.stream_data_in.column(RespBody);
            const io_results = self.stream_data_in.column(H2IoResult);

            for (entities, sessions, sids, resp_bodies, io_results) |ent, sess, sid, *rb, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_data_in, &self.response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_data_in, &self.response_out);
                    continue;
                }

                if (rb.data == null or rb.len == 0) {
                    try self.reg.move(ent, &self.stream_data_in, &self.stream_data_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_data_in, &self.response_out);
                    continue;
                }

                const s = stream.?;

                s.stream_chunk_data = rb.data;
                s.stream_chunk_len = rb.len;
                s.stream_chunk_offset = 0;
                rb.data = null;
                rb.len = 0;

                _ = c.nghttp2_session_resume_data(ng_session, s.ng_stream_id);

                try self.reg.move(ent, &self.stream_data_in, &self._stream_data_sending);
            }
        }

        // =============================================================
        // Streaming: consume stream_close_in
        // =============================================================

        fn consumeStreamClose(self: *Self) !void {
            const entities = self.stream_close_in.entitySlice();
            const sessions = self.stream_close_in.column(Session);
            const sids = self.stream_close_in.column(StreamId);
            const io_results = self.stream_close_in.column(H2IoResult);

            for (entities, sessions, sids, io_results) |ent, sess, sid, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_close_in, &self.response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_close_in, &self.response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_close_in, &self.response_out);
                    continue;
                }

                stream.?.stream_eof = true;
                _ = c.nghttp2_session_resume_data(ng_session, stream.?.ng_stream_id);

                try self.reg.move(ent, &self.stream_close_in, &self._stream_data_sending);
            }
        }

        // =============================================================
        // Phase 2: Read triage
        // =============================================================

        fn readsTriage(self: *Self) !void {
            const entities = self.io.read_results.entitySlice();
            const conn_ents = self.io.read_results.column(rio.ConnEntity);
            const results = self.io.read_results.column(rio.ReadResult);

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (self.reg.isStale(conn_ent.entity) or self.reg.isMoving(conn_ent.entity)) {
                    try self.reg.move(ent, &self.io.read_results, &self._read_errors);
                    continue;
                }
                if (rr.result <= 0) {
                    try self.reg.move(ent, &self.io.read_results, &self._read_errors);
                    continue;
                }
                if (self.reg.isInCollection(conn_ent.entity, &self.io.connections)) {
                    try self.reg.move(ent, &self.io.read_results, &self._read_init);
                    continue;
                }
                if (self.reg.isInCollection(conn_ent.entity, &self._conn_tls_handshake)) {
                    try self.reg.move(ent, &self.io.read_results, &self._read_handshake);
                    continue;
                }
                if (self.reg.isInCollection(conn_ent.entity, &self._conn_active)) {
                    try self.reg.move(ent, &self.io.read_results, &self._read_active);
                    continue;
                }
                try self.reg.move(ent, &self.io.read_results, &self._read_errors);
            }
        }

        // =============================================================
        // Phase 3: Handle read errors
        // =============================================================

        fn readsHandleErrors(self: *Self) !void {
            const entities = self._read_errors.entitySlice();
            const conn_ents = self._read_errors.column(rio.ConnEntity);

            for (entities, conn_ents) |ent, conn_ent| {
                if (!self.reg.isStale(conn_ent.entity)) {
                    try self.reg.destroy(conn_ent.entity);
                }
                try self.reg.move(ent, &self._read_errors, &self.io.read_in);
            }
        }

        // =============================================================
        // Phase 4: Init new connections
        // =============================================================

        fn readsInitConnections(self: *Self) !void {
            const entities = self._read_init.entitySlice();
            const conn_ents = self._read_init.column(rio.ConnEntity);

            for (entities, conn_ents) |ent, conn_ent| {
                if (self.reg.isStale(conn_ent.entity)) {
                    try self.reg.move(ent, &self._read_init, &self.io.read_in);
                    continue;
                }

                const conn_ptr = self.reg.get(conn_ent.entity, &self.io.connections, Conn) catch {
                    try self.reg.move(ent, &self._read_init, &self.io.read_in);
                    continue;
                };

                if (self.h2_opts.tls_config) |tls_cfg| {
                    conn_ptr.tls_conn = tls.TlsConn.create(tls_cfg, self.allocator) catch {
                        try self.reg.destroy(conn_ent.entity);
                        try self.reg.move(ent, &self._read_init, &self.io.read_in);
                        continue;
                    };
                    try self.reg.move(ent, &self._read_init, &self._read_handshake);
                } else {
                    self.sessionCreate(conn_ptr, conn_ent.entity) catch {
                        try self.reg.destroy(conn_ent.entity);
                        try self.reg.move(ent, &self._read_init, &self.io.read_in);
                        continue;
                    };
                    try self.reg.move(ent, &self._read_init, &self._read_active);
                }
            }
        }

        // =============================================================
        // Phase 5: Transition new connections → _conn_active
        // =============================================================

        fn transitionNewConnections(self: *Self) !void {
            const entities = self.io.connections.entitySlice();
            const max = self.h2_opts.max_h2_connections;
            var active_count: u32 = @intCast(self._conn_active.entitySlice().len);

            for (entities) |ent| {
                const conn_ptr = self.reg.get(ent, &self.io.connections, Conn) catch continue;

                if (conn_ptr.tls_conn != null and conn_ptr.ng_session == null) {
                    if (max > 0 and active_count >= max) {
                        try self.reg.destroy(ent);
                        continue;
                    }
                    conn_ptr.last_active_ns = monotonicNs();
                    try self.reg.move(ent, &self.io.connections, &self._conn_tls_handshake);
                    active_count += 1;
                    continue;
                }

                if (conn_ptr.ng_session == null) continue;

                if (max > 0 and active_count >= max) {
                    try self.reg.destroy(ent);
                    continue;
                }

                conn_ptr.last_active_ns = monotonicNs();
                try self.reg.move(ent, &self.io.connections, &self._conn_active);
                active_count += 1;
            }
        }

        // =============================================================
        // TLS handshake
        // =============================================================

        fn readsTlsHandshake(self: *Self) !void {
            const entities = self._read_handshake.entitySlice();
            const conn_ents = self._read_handshake.column(rio.ConnEntity);
            const results = self._read_handshake.column(rio.ReadResult);

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (self.reg.isStale(conn_ent.entity)) {
                    try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                    continue;
                }

                const conn_ptr = getConn(self, conn_ent.entity) orelse {
                    try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                    continue;
                };

                const tc = conn_ptr.tls_conn orelse {
                    try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                    continue;
                };

                const raw = if (rr.data) |d| d[0..@intCast(rr.result)] else &[_]u8{};
                var decrypt_buf: [16384]u8 = undefined;
                const feed_result = tc.feed(raw, &decrypt_buf);

                switch (feed_result.result) {
                    .need_more => {
                        if (tc.drainOutput(self.allocator) catch null) |output| {
                            self.submitWrite(conn_ent.entity, output) catch {
                                self.allocator.free(output);
                            };
                        }
                        try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                    },
                    .handshake_done => {
                        if (tc.drainOutput(self.allocator) catch null) |output| {
                            self.submitWrite(conn_ent.entity, output) catch {
                                self.allocator.free(output);
                            };
                        }
                        self.sessionCreate(conn_ptr, conn_ent.entity) catch {
                            try self.reg.destroy(conn_ent.entity);
                            try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                            continue;
                        };
                        if (feed_result.out_len > 0 and conn_ptr.ng_session != null) {
                            _ = c.nghttp2_session_mem_recv(
                                conn_ptr.ng_session.?,
                                &decrypt_buf,
                                feed_result.out_len,
                            );
                        }
                        try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                    },
                    .data, .err => {
                        try self.reg.destroy(conn_ent.entity);
                        try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                    },
                }
            }
        }

        fn transitionHandshakeConnections(self: *Self) !void {
            const entities = self._conn_tls_handshake.entitySlice();
            for (entities) |ent| {
                const conn_ptr = self.reg.get(ent, &self._conn_tls_handshake, Conn) catch continue;
                if (conn_ptr.ng_session != null) {
                    try self.reg.move(ent, &self._conn_tls_handshake, &self._conn_active);
                }
            }
        }

        // =============================================================
        // Helper: submit a write entity
        // =============================================================

        fn submitWrite(self: *Self, conn_entity: Entity, data: []u8) !void {
            const we = try self.reg.create(&self.io.write_in);
            try self.reg.set(we, &self.io.write_in, rio.ConnEntity, .{ .entity = conn_entity });
            try self.reg.set(we, &self.io.write_in, rio.WriteBuf, .{ .data = data.ptr, .len = @intCast(data.len) });
        }

        // =============================================================
        // Feed active data to nghttp2
        // =============================================================

        fn readsFeedData(self: *Self) !void {
            const entities = self._read_active.entitySlice();
            const conn_ents = self._read_active.column(rio.ConnEntity);
            const results = self._read_active.column(rio.ReadResult);

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (self.reg.isStale(conn_ent.entity)) {
                    try self.reg.move(ent, &self._read_active, &self.io.read_in);
                    continue;
                }

                const conn_ptr = self.reg.get(conn_ent.entity, &self._conn_active, Conn) catch {
                    try self.reg.move(ent, &self._read_active, &self.io.read_in);
                    continue;
                };

                if (conn_ptr.ng_session == null) {
                    try self.reg.move(ent, &self._read_active, &self.io.read_in);
                    continue;
                }

                if (rr.data) |data_ptr| {
                    const data_len: usize = @intCast(rr.result);

                    if (conn_ptr.tls_conn) |tc| {
                        var decrypt_buf: [65536]u8 = undefined;
                        const feed_result = tc.feed(data_ptr[0..data_len], &decrypt_buf);
                        if (feed_result.result == .err) {
                            try self.reg.destroy(conn_ent.entity);
                            try self.reg.move(ent, &self._read_active, &self.io.read_in);
                            continue;
                        }
                        if (feed_result.out_len > 0) {
                            const rv = c.nghttp2_session_mem_recv(conn_ptr.ng_session.?, &decrypt_buf, feed_result.out_len);
                            if (rv < 0) {
                                try self.reg.destroy(conn_ent.entity);
                                try self.reg.move(ent, &self._read_active, &self.io.read_in);
                                continue;
                            }
                        }
                    } else {
                        const rv = c.nghttp2_session_mem_recv(conn_ptr.ng_session.?, data_ptr, data_len);
                        if (rv < 0) {
                            try self.reg.destroy(conn_ent.entity);
                            try self.reg.move(ent, &self._read_active, &self.io.read_in);
                            continue;
                        }
                    }
                    conn_ptr.last_active_ns = monotonicNs();
                }

                try self.reg.move(ent, &self._read_active, &self.io.read_in);
            }
        }

        // =============================================================
        // Phase 7: Write accounting
        // =============================================================

        fn writesAccount(self: *Self) !void {
            const entities = self.io.write_results.entitySlice();
            const conn_ents = self.io.write_results.column(rio.ConnEntity);
            const io_results = self.io.write_results.column(rio.IoResult);

            for (entities, conn_ents, io_results) |ent, conn_ent, io_res| {
                if (!self.reg.isStale(conn_ent.entity) and io_res.err != 0) {
                    try self.reg.destroy(conn_ent.entity);
                }
                try self.reg.destroy(ent);
            }
        }

        // =============================================================
        // Phase 8: Drive all nghttp2 sends
        // =============================================================

        fn driveAllSends(self: *Self) !void {
            const entities = self._conn_active.entitySlice();
            const now = monotonicNs();

            for (entities) |ent| {
                if (self.reg.isStale(ent)) continue;

                const conn_ptr = self.reg.get(ent, &self._conn_active, Conn) catch continue;
                if (conn_ptr.ng_session == null) continue;

                if (self.h2_opts.idle_timeout_ns > 0 and conn_ptr.last_active_ns > 0 and
                    now -| conn_ptr.last_active_ns > self.h2_opts.idle_timeout_ns)
                {
                    try self.reg.destroy(ent);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                if (c.nghttp2_session_want_write(ng_session) == 0 and
                    c.nghttp2_session_want_read(ng_session) == 0)
                {
                    try self.reg.destroy(ent);
                    continue;
                }

                if (c.nghttp2_session_want_write(ng_session) == 0) continue;

                if (conn_ptr.tls_conn) |tc| {
                    var accum_buf: [65536]u8 = undefined;
                    var accum_len: usize = 0;

                    while (true) {
                        var frame_data: [*c]const u8 = undefined;
                        const len = c.nghttp2_session_mem_send(ng_session, &frame_data);
                        if (len < 0) {
                            try self.reg.destroy(ent);
                            break;
                        }
                        if (len == 0) break;
                        const flen: usize = @intCast(len);
                        if (accum_len + flen > accum_buf.len) {
                            try self.reg.destroy(ent);
                            break;
                        }
                        @memcpy(accum_buf[accum_len .. accum_len + flen], frame_data[0..flen]);
                        accum_len += flen;
                    }

                    if (accum_len > 0) {
                        const cipher = tc.encrypt(accum_buf[0..accum_len], self.allocator) catch {
                            try self.reg.destroy(ent);
                            continue;
                        };
                        self.submitWrite(ent, cipher) catch {
                            self.allocator.free(cipher);
                            try self.reg.destroy(ent);
                            continue;
                        };
                    }
                } else {
                    // Accumulate ALL frames nghttp2 wants to send into a
                    // single buffer + single write. Without this, HEADERS
                    // + DATA for each response become separate `prep_send`
                    // SQEs and therefore separate TCP segments, and the
                    // client's delayed-ACK stalls every request-response
                    // round trip by ~40 ms. Mirrors the TLS path above.
                    var accum_buf: [65536]u8 = undefined;
                    var accum_len: usize = 0;
                    var broke = false;

                    while (true) {
                        var frame_data: [*c]const u8 = undefined;
                        const len = c.nghttp2_session_mem_send(ng_session, &frame_data);
                        if (len < 0) {
                            try self.reg.destroy(ent);
                            broke = true;
                            break;
                        }
                        if (len == 0) break;
                        const flen: usize = @intCast(len);
                        if (accum_len + flen > accum_buf.len) {
                            // Flush what we have so far, then continue
                            // with a fresh buffer. Big responses can still
                            // fan out into multiple segments — that's OK,
                            // Nagle only bites on tiny trailing fragments.
                            const copy = self.allocator.dupe(u8, accum_buf[0..accum_len]) catch {
                                try self.reg.destroy(ent);
                                broke = true;
                                break;
                            };
                            self.submitWrite(ent, copy) catch {
                                self.allocator.free(copy);
                                try self.reg.destroy(ent);
                                broke = true;
                                break;
                            };
                            accum_len = 0;
                        }
                        @memcpy(accum_buf[accum_len .. accum_len + flen], frame_data[0..flen]);
                        accum_len += flen;
                    }

                    if (!broke and accum_len > 0) {
                        const copy = self.allocator.dupe(u8, accum_buf[0..accum_len]) catch {
                            try self.reg.destroy(ent);
                            continue;
                        };
                        self.submitWrite(ent, copy) catch {
                            self.allocator.free(copy);
                            try self.reg.destroy(ent);
                            continue;
                        };
                    }
                }

                conn_ptr.last_active_ns = now;
            }
        }

        // =============================================================
        // Client: consume connect requests
        // =============================================================

        fn consumeConnectRequests(self: *Self) !void {
            if (!has_client) return;
            const entities = self.client_connect_in.entitySlice();
            const targets = self.client_connect_in.column(ConnectTarget);

            for (entities, targets) |ent, target| {
                const ce = self.reg.create(&self.io.connect_in) catch {
                    try self.reg.set(ent, &self.client_connect_in, H2IoResult, .{ .err = -1 });
                    try self.reg.move(ent, &self.client_connect_in, &self.client_connect_errors);
                    continue;
                };

                // Heap-allocate the target address so the pointer we
                // hand io_uring is stable across swap-remove. Ownership
                // transfers to the `ConnectAddr` component; its deinit
                // frees the allocation when the entity is destroyed or
                // the component is stripped during `moveStripImmediate`
                // on connect success.
                const addr_ptr = self.allocator.create(std.net.Address) catch {
                    try self.reg.destroy(ce);
                    try self.reg.set(ent, &self.client_connect_in, H2IoResult, .{ .err = -1 });
                    try self.reg.move(ent, &self.client_connect_in, &self.client_connect_errors);
                    continue;
                };
                addr_ptr.* = target.addr;

                try self.reg.set(ce, &self.io.connect_in, rio.ConnectAddr, .{ .addr = addr_ptr });
                try self.reg.set(ce, &self.io.connect_in, Conn, .{ .direction = .client, .pending_connect_entity = ent });

                try self.reg.move(ent, &self.client_connect_in, &self._client_connect_pending);
            }
        }

        // =============================================================
        // Client: process connect results
        // =============================================================

        fn processConnectResults(self: *Self) !void {
            if (!has_client) return;
            const entities = self.io.connections.entitySlice();

            for (entities) |ent| {
                const conn_ptr = self.reg.get(ent, &self.io.connections, Conn) catch continue;
                if (conn_ptr.direction != .client) continue;
                if (conn_ptr.pending_connect_entity.isNil()) continue;

                const user_ent = conn_ptr.pending_connect_entity;
                if (self.reg.isStale(user_ent)) {
                    conn_ptr.pending_connect_entity = Entity.nil;
                    continue;
                }

                self.clientSessionCreate(conn_ptr, ent) catch {
                    self.reg.set(user_ent, &self._client_connect_pending, H2IoResult, .{ .err = -1 }) catch {};
                    self.reg.move(user_ent, &self._client_connect_pending, &self.client_connect_errors) catch {};
                    self.reg.destroy(ent) catch {};
                    continue;
                };

                self.reg.set(user_ent, &self._client_connect_pending, Session, .{ .entity = ent }) catch {};
                self.reg.set(user_ent, &self._client_connect_pending, H2IoResult, .{ .err = 0 }) catch {};
                self.reg.move(user_ent, &self._client_connect_pending, &self.client_connect_out) catch {};

                conn_ptr.pending_connect_entity = Entity.nil;
                conn_ptr.last_active_ns = monotonicNs();
            }
        }

        // =============================================================
        // Client: process connect errors
        // =============================================================

        fn processConnectErrors(self: *Self) !void {
            if (!has_client) return;
            const entities = self.io.connect_errors.entitySlice();
            const conns = self.io.connect_errors.column(Conn);

            for (entities, conns) |ent, conn| {
                const user_ent = conn.pending_connect_entity;
                if (!user_ent.isNil() and !self.reg.isStale(user_ent)) {
                    self.reg.set(user_ent, &self._client_connect_pending, H2IoResult, .{ .err = -1 }) catch {};
                    self.reg.move(user_ent, &self._client_connect_pending, &self.client_connect_errors) catch {};
                }
                try self.reg.destroy(ent);
            }
        }

        // =============================================================
        // Client: consume client requests
        // =============================================================

        fn consumeClientRequests(self: *Self) !void {
            if (!has_client) return;
            const entities = self.client_request_in.entitySlice();
            const sessions = self.client_request_in.column(Session);
            const req_hdrs = self.client_request_in.column(ReqHeaders);
            const req_bodies = self.client_request_in.column(ReqBody);
            const io_results = self.client_request_in.column(H2IoResult);

            for (entities, sessions, req_hdrs, req_bodies, io_results) |ent, sess, rh, rb, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                const nv_count: usize = @as(usize, rh.count);
                if (nv_count == 0) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                    continue;
                }

                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                    continue;
                };
                defer self.allocator.free(nva_slice);

                if (rh.fields) |fields| {
                    for (0..rh.count) |j| {
                        nva_slice[j] = .{
                            .name = @constCast(fields[j].name),
                            .namelen = fields[j].name_len,
                            .value = @constCast(fields[j].value),
                            .valuelen = fields[j].value_len,
                            .flags = c.NGHTTP2_NV_FLAG_NO_COPY_NAME | c.NGHTTP2_NV_FLAG_NO_COPY_VALUE,
                        };
                    }
                }

                var data_prd: c.nghttp2_data_provider = std.mem.zeroes(c.nghttp2_data_provider);
                var body_data_ptr: ?*BodyData = null;
                if (rb.data != null and rb.len > 0) {
                    body_data_ptr = BodyData.create(self.allocator, rb.data.?, rb.len) orelse {
                        io_res.err = -1;
                        try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                        continue;
                    };
                    data_prd.source = .{ .ptr = @ptrCast(body_data_ptr) };
                    data_prd.read_callback = &onDataSourceReadCb;
                }

                const stream_id = c.nghttp2_submit_request(
                    ng_session,
                    null,
                    nva_slice.ptr,
                    nv_count,
                    if (data_prd.read_callback != null) &data_prd else null,
                    null,
                );

                if (stream_id < 0) {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                    continue;
                }

                const stream = Stream.create(sess.entity, self.allocator) orelse {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_request_in, &self.client_response_out);
                    continue;
                };
                stream.entity = ent;
                stream.send_complete = (data_prd.read_callback == null);
                stream.send_data = body_data_ptr;
                stream.ng_stream_id = stream_id;
                _ = c.nghttp2_session_set_stream_user_data(ng_session, stream_id, @ptrCast(stream));

                try self.reg.set(ent, &self.client_request_in, StreamId, .{ .id = @intCast(stream_id) });
                try self.reg.move(ent, &self.client_request_in, &self._client_request_sending);
            }
        }

        // =============================================================
        // Client streaming: consume client_stream_request_in
        // =============================================================

        fn consumeClientStreamRequests(self: *Self) !void {
            if (!has_client) return;
            const entities = self.client_stream_request_in.entitySlice();
            const sessions = self.client_stream_request_in.column(Session);
            const req_hdrs = self.client_stream_request_in.column(ReqHeaders);
            const io_results = self.client_stream_request_in.column(H2IoResult);

            for (entities, sessions, req_hdrs, io_results) |ent, sess, rh, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_request_in, &self.client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_request_in, &self.client_response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                const nv_count: usize = @as(usize, rh.count);
                if (nv_count == 0) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_request_in, &self.client_response_out);
                    continue;
                }

                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_request_in, &self.client_response_out);
                    continue;
                };
                defer self.allocator.free(nva_slice);

                if (rh.fields) |fields| {
                    for (0..rh.count) |j| {
                        nva_slice[j] = .{
                            .name = @constCast(fields[j].name),
                            .namelen = fields[j].name_len,
                            .value = @constCast(fields[j].value),
                            .valuelen = fields[j].value_len,
                            .flags = c.NGHTTP2_NV_FLAG_NO_COPY_NAME | c.NGHTTP2_NV_FLAG_NO_COPY_VALUE,
                        };
                    }
                }

                var data_prd = c.nghttp2_data_provider{
                    .source = .{ .ptr = null },
                    .read_callback = &onDataSourceReadCb,
                };

                const stream_id = c.nghttp2_submit_request(
                    ng_session,
                    null,
                    nva_slice.ptr,
                    nv_count,
                    &data_prd,
                    null,
                );

                if (stream_id < 0) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_request_in, &self.client_response_out);
                    continue;
                }

                const stream = Stream.create(sess.entity, self.allocator) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_request_in, &self.client_response_out);
                    continue;
                };
                stream.entity = ent;
                stream.emitted = true;
                stream.streaming = true;
                stream.client_stream = true;
                stream.send_complete = false;
                stream.send_data = null;
                stream.ng_stream_id = stream_id;
                _ = c.nghttp2_session_set_stream_user_data(ng_session, stream_id, @ptrCast(stream));

                try self.reg.set(ent, &self.client_stream_request_in, StreamId, .{ .id = @intCast(stream_id) });
                try self.reg.move(ent, &self.client_stream_request_in, &self.client_stream_data_out);
            }
        }

        // =============================================================
        // Client streaming: consume client_stream_data_in
        // =============================================================

        fn consumeClientStreamData(self: *Self) !void {
            if (!has_client) return;
            const entities = self.client_stream_data_in.entitySlice();
            const sessions = self.client_stream_data_in.column(Session);
            const sids = self.client_stream_data_in.column(StreamId);
            const req_bodies = self.client_stream_data_in.column(ReqBody);
            const io_results = self.client_stream_data_in.column(H2IoResult);

            for (entities, sessions, sids, req_bodies, io_results) |ent, sess, sid, *rb, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_data_in, &self.client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_data_in, &self.client_response_out);
                    continue;
                }

                if (rb.data == null or rb.len == 0) {
                    try self.reg.move(ent, &self.client_stream_data_in, &self.client_stream_data_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_data_in, &self.client_response_out);
                    continue;
                }

                const s = stream.?;

                s.stream_chunk_data = rb.data;
                s.stream_chunk_len = rb.len;
                s.stream_chunk_offset = 0;
                rb.data = null;
                rb.len = 0;

                _ = c.nghttp2_session_resume_data(ng_session, s.ng_stream_id);

                try self.reg.move(ent, &self.client_stream_data_in, &self._client_stream_data_sending);
            }
        }

        // =============================================================
        // Client streaming: consume client_stream_close_in
        // =============================================================

        fn consumeClientStreamClose(self: *Self) !void {
            if (!has_client) return;
            const entities = self.client_stream_close_in.entitySlice();
            const sessions = self.client_stream_close_in.column(Session);
            const sids = self.client_stream_close_in.column(StreamId);
            const io_results = self.client_stream_close_in.column(H2IoResult);

            for (entities, sessions, sids, io_results) |ent, sess, sid, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_close_in, &self.client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_close_in, &self.client_response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.client_stream_close_in, &self.client_response_out);
                    continue;
                }

                stream.?.stream_eof = true;
                _ = c.nghttp2_session_resume_data(ng_session, stream.?.ng_stream_id);

                try self.reg.move(ent, &self.client_stream_close_in, &self._client_stream_data_sending);
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stream row contains all h2 base components" {
    const H2Type = H2(.{});
    try testing.expect(H2Type.StreamRow.contains(StreamId));
    try testing.expect(H2Type.StreamRow.contains(Session));
    try testing.expect(H2Type.StreamRow.contains(ReqHeaders));
    try testing.expect(H2Type.StreamRow.contains(ReqBody));
    try testing.expect(H2Type.StreamRow.contains(RespHeaders));
    try testing.expect(H2Type.StreamRow.contains(RespBody));
    try testing.expect(H2Type.StreamRow.contains(Status));
    try testing.expect(H2Type.StreamRow.contains(H2IoResult));
}

test "connection row contains Conn" {
    const H2Type = H2(.{});
    try testing.expect(H2Type.ConnectionRow.contains(Conn));
    try testing.expect(H2Type.ConnectionRow.contains(rio.Fd));
    try testing.expect(H2Type.ConnectionRow.contains(rio.ReadCycleEntity));
}

test "user rows pass through" {
    const MyAppData = struct { tag: u64 };
    const MySession = struct { id: u64 };
    const H2Type = H2(.{ .request_row = Row(&.{MyAppData}), .connection_row = Row(&.{MySession}) });
    try testing.expect(H2Type.StreamRow.contains(MyAppData));
    try testing.expect(H2Type.ConnectionRow.contains(MySession));
}

test "H2 type has expected collections" {
    const H2Type = H2(.{});
    try testing.expect(@hasField(H2Type, "request_out"));
    try testing.expect(@hasField(H2Type, "response_in"));
    try testing.expect(@hasField(H2Type, "response_out"));
    try testing.expect(@hasField(H2Type, "_response_sending"));
    try testing.expect(@hasField(H2Type, "_conn_active"));
}

test "H2 client has client collections" {
    const H2Type = H2(.{ .client = true });
    try testing.expect(@hasField(H2Type, "client_connect_in"));
    try testing.expect(@hasField(H2Type, "client_response_out"));
}

test "nghttp2 linked and callable" {
    const info = c.nghttp2_version(0);
    try testing.expect(info != null);
    try testing.expect(info.*.proto_str != null);
}

test "stream accumulator — headers and body" {
    const stream = Stream.create(Entity{ .index = 5, .generation = 2 }, testing.allocator) orelse
        return error.OutOfMemory;
    defer stream.free();

    try testing.expect(stream.hdrAppend(":method", 7, "GET", 3));
    try testing.expect(stream.hdrAppend(":path", 5, "/hello", 6));
    try testing.expect(stream.hdrAppend("host", 4, "localhost", 9));
    try testing.expectEqual(@as(u32, 3), stream.hdr_count);

    try testing.expect(stream.bodyAppend("hello world", 11));
    try testing.expectEqual(@as(u32, 11), stream.body_len);

    var fields: ?[*]HeaderField = null;
    var count: u32 = 0;
    var buf_len: u32 = 0;
    const buf = stream.hdrFinalize(&fields, &count, &buf_len);
    defer if (buf) |b| testing.allocator.free(b[0..buf_len]);

    try testing.expect(buf != null);
    try testing.expect(fields != null);
    try testing.expectEqual(@as(u32, 3), count);

    const f0 = fields.?[0];
    try testing.expectEqualStrings(":method", f0.name[0..f0.name_len]);
    try testing.expectEqualStrings("GET", f0.value[0..f0.value_len]);

    const f2 = fields.?[2];
    try testing.expectEqualStrings("host", f2.name[0..f2.name_len]);
    try testing.expectEqualStrings("localhost", f2.value[0..f2.value_len]);
}
