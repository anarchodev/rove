const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const Row = rove.Row;
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

/// Request headers — owned by h2, freed on entity destroy.
/// `_buf` is a single allocation: fields array followed by string data.
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

/// Request body — owned by h2, freed on entity destroy.
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

/// Response headers — app-allocated fields array, freed on entity destroy.
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

/// Response body — app-allocated, freed on entity destroy.
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

/// Internal per-connection state — carries the nghttp2 session.
/// Registered as a connection component; deinit cleans up nghttp2.
pub const Direction = enum(u8) { server = 0, client = 1 };

pub const Conn = struct {
    ng_session: ?*c.nghttp2_session = null,
    ng_ctx: ?*anyopaque = null,
    ng_ctx_destroy: ?*const fn (?*anyopaque) void = null,
    tls_conn: ?*tls.TlsConn = null,
    direction: Direction = .server,
    last_active_ns: u64 = 0,
    /// For client connections: the user's connect entity parked in _connect_pending.
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

        // Store offsets + 1 to avoid @ptrFromInt(0) which is UB.
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
        if (self.body_len + need > self.body_cap) {
            const new_cap = if (self.body_cap > 0) self.body_cap * 2 else 4096;
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

/// Body data provider for nghttp2 response sends.
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
// Spec
// =============================================================================

/// Target for outgoing client connections.
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
    /// Maximum concurrent HTTP/2 streams per connection (SETTINGS_MAX_CONCURRENT_STREAMS).
    max_concurrent_streams: u32 = 128,
    /// Initial flow-control window size per stream in bytes (SETTINGS_INITIAL_WINDOW_SIZE).
    initial_window_size: u32 = 65535,
    /// Maximum frame size in bytes (SETTINGS_MAX_FRAME_SIZE).
    max_frame_size: u32 = 16384,
    /// Maximum header list size in bytes (SETTINGS_MAX_HEADER_LIST_SIZE). 0 = nghttp2 default.
    max_header_list_size: u32 = 0,
    /// Maximum concurrent h2 connections. 0 = unlimited (bounded only by rove-io's max_connections).
    max_h2_connections: u32 = 0,
    /// Idle connection timeout in nanoseconds. 0 = no timeout.
    idle_timeout_ns: u64 = 0,
    /// TLS config. null = h2c (plaintext). Set to enable TLS (h2 over TLS).
    tls_config: ?*TlsConfig = null,
};

pub fn Collections(comptime opts: Options) type {
    const conn_row = Row(&.{Conn}).merge(opts.connection_row);
    return rove.MergeCollections(.{
        rio.Collections(.{ .connection_row = conn_row, .connect = opts.client }),
        H2OnlySpec(opts),
    });
}

fn H2OnlySpec(comptime opts: Options) type {
    const conn_row = rio.ConnectionBaseRow.merge(Row(&.{Conn})).merge(opts.connection_row);
    const stream_row = StreamBaseRow.merge(opts.request_row);
    const connect_row = Row(&.{ ConnectTarget, Session, H2IoResult }).merge(opts.request_row);
    const C = rove.Collection;

    const base_fields = .{
        // Server request/response
        rove.col("request_out", C(stream_row, .{})),
        rove.col("response_in", C(stream_row, .{})),
        rove.col("response_out", C(stream_row, .{})),
        rove.col("_response_sending", C(stream_row, .{})),
        // Streaming response collections
        rove.col("stream_response_in", C(stream_row, .{})),
        rove.col("stream_data_out", C(stream_row, .{})),
        rove.col("stream_data_in", C(stream_row, .{})),
        rove.col("stream_close_in", C(stream_row, .{})),
        rove.col("_stream_data_sending", C(stream_row, .{})),
        // Internal
        rove.col("_read_errors", C(rio.ReadBaseRow, .{})),
        rove.col("_read_init", C(rio.ReadBaseRow, .{})),
        rove.col("_read_active", C(rio.ReadBaseRow, .{})),
        rove.col("_conn_tls_handshake", C(conn_row, .{})),
        rove.col("_conn_active", C(conn_row, .{})),
        rove.col("_read_handshake", C(rio.ReadBaseRow, .{})),
    };

    const client_fields = if (opts.client) .{
        // Client connect lifecycle
        rove.col("client_connect_in", C(connect_row, .{})),
        rove.col("client_connect_out", C(connect_row, .{})),
        rove.col("client_connect_errors", C(connect_row, .{})),
        rove.col("_client_connect_pending", C(connect_row, .{})),
        // Client request/response
        rove.col("client_request_in", C(stream_row, .{})),
        rove.col("client_response_out", C(stream_row, .{})),
        rove.col("_client_request_sending", C(stream_row, .{})),
        // Client streaming request collections
        rove.col("client_stream_request_in", C(stream_row, .{})),
        rove.col("client_stream_data_out", C(stream_row, .{})),
        rove.col("client_stream_data_in", C(stream_row, .{})),
        rove.col("client_stream_close_in", C(stream_row, .{})),
        rove.col("_client_stream_data_sending", C(stream_row, .{})),
    } else .{};

    return rove.MakeCollections(&(base_fields ++ client_fields));
}

// =============================================================================
// H2 — HTTP/2 server runtime
// =============================================================================

pub fn H2(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const has_client = @hasField(Ctx.CollectionId, "client_connect_in");

        io: *rio.Io(Ctx),
        h2_opts: H2Options,
        allocator: std.mem.Allocator,

        // Shared nghttp2 callbacks — one per H2(Ctx) instantiation.
        var ng_callbacks: ?*c.nghttp2_session_callbacks = null;

        // =============================================================
        // NgCtx — nghttp2 session user_data, lives inside H2(Ctx)
        // so callbacks can access Ctx directly.
        // =============================================================

        const NgCtx = struct {
            ctx: *Ctx,
            allocator: std.mem.Allocator,
            conn_entity: Entity = Entity.nil,
        };

        // =============================================================
        // nghttp2 callbacks — inside H2(Ctx), full access to Ctx
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

            // Create request entity inline — we have Ctx access
            const req_entity = nctx.ctx.createOneImmediate(.request_out) catch
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;

            var fields: ?[*]HeaderField = null;
            var count: u32 = 0;
            var buf_len: u32 = 0;
            const hdr_buf = s.hdrFinalize(&fields, &count, &buf_len);

            nctx.ctx.set(req_entity, StreamId, .{ .id = @intCast(frame.*.hd.stream_id) }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            nctx.ctx.set(req_entity, Session, .{ .entity = nctx.conn_entity }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            nctx.ctx.set(req_entity, ReqHeaders, .{ .fields = fields, .count = count, ._buf = hdr_buf, ._buf_len = buf_len }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            // Shrink body allocation to exact size for clean ownership transfer
            const body_data = if (s.body_data) |p| blk: {
                if (s.body_len < s.body_cap) {
                    const shrunk = s.allocator.realloc(p[0..s.body_cap], s.body_len) catch p[0..s.body_cap];
                    break :blk @as(?[*]u8, shrunk.ptr);
                }
                break :blk @as(?[*]u8, p);
            } else null;
            nctx.ctx.set(req_entity, ReqBody, .{ .data = body_data, .len = s.body_len }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;

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

            if (s.emitted and !s.entity.isNil() and !nctx.ctx.isStale(s.entity)) {
                const err: i32 = if (s.send_complete and error_code == 0) 0 else -1;
                nctx.ctx.set(s.entity, H2IoResult, .{ .err = err }) catch {};
                nctx.ctx.moveOne(s.entity, .response_out) catch {};
            }

            s.send_data = null; // Stream.free() handles the rest
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
                    // EOF: app closed the stream
                    if (s.stream_eof and s.stream_chunk_data == null) {
                        data_flags[0] |= @intCast(c.NGHTTP2_DATA_FLAG_EOF);
                        s.send_complete = true;
                        return 0;
                    }
                    // No chunk available — defer until resume_data
                    if (s.stream_chunk_data == null)
                        return c.NGHTTP2_ERR_DEFERRED;

                    // Send chunk bytes
                    const remaining = s.stream_chunk_len - s.stream_chunk_offset;
                    const to_copy: u32 = if (remaining < @as(u32, @intCast(length))) remaining else @intCast(length);
                    @memcpy(buf[0..to_copy], s.stream_chunk_data.?[s.stream_chunk_offset .. s.stream_chunk_offset + to_copy]);
                    s.stream_chunk_offset += to_copy;

                    if (s.stream_chunk_offset >= s.stream_chunk_len) {
                        // Chunk fully consumed — free, move entity back to ready
                        s.allocator.free(s.stream_chunk_data.?[0..s.stream_chunk_len]);
                        s.stream_chunk_data = null;
                        s.stream_chunk_len = 0;
                        s.stream_chunk_offset = 0;

                        const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
                        if (comptime has_client) {
                            if (s.client_stream) {
                                nctx.ctx.moveOneFrom(s.entity, ._client_stream_data_sending, .client_stream_data_out) catch {};
                            } else {
                                nctx.ctx.moveOneFrom(s.entity, ._stream_data_sending, .stream_data_out) catch {};
                            }
                        } else {
                            nctx.ctx.moveOneFrom(s.entity, ._stream_data_sending, .stream_data_out) catch {};
                        }
                    }
                    return @intCast(to_copy);
                }
            }

            // --- Non-streaming path (complete body) ---
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

        fn sessionCreate(ctx: *Ctx, allocator: std.mem.Allocator, conn: *Conn, conn_entity: Entity, opts: H2Options) !void {
            try ensureCallbacks();

            const nctx = try allocator.create(NgCtx);
            nctx.* = .{ .ctx = ctx, .allocator = allocator, .conn_entity = conn_entity };

            var session: ?*c.nghttp2_session = null;
            if (c.nghttp2_session_server_new(&session, ng_callbacks, @ptrCast(nctx)) != 0) {
                allocator.destroy(nctx);
                return error.Nghttp2SessionCreateFailed;
            }

            conn.ng_session = session;
            conn.ng_ctx = @ptrCast(nctx);
            conn.ng_ctx_destroy = &destroyNgCtx;

            var settings_buf: [4]c.nghttp2_settings_entry = undefined;
            var settings_count: usize = 0;

            settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = opts.max_concurrent_streams };
            settings_count += 1;

            if (opts.initial_window_size != 65535) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = opts.initial_window_size };
                settings_count += 1;
            }
            if (opts.max_frame_size != 16384) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE, .value = opts.max_frame_size };
                settings_count += 1;
            }
            if (opts.max_header_list_size != 0) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = opts.max_header_list_size };
                settings_count += 1;
            }

            if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings_buf, settings_count) != 0) {
                c.nghttp2_session_del(session);
                allocator.destroy(nctx);
                conn.ng_session = null;
                conn.ng_ctx = null;
                return error.Nghttp2SettingsFailed;
            }
        }


        // =============================================================
        // Client: nghttp2 callbacks
        // =============================================================

        var ng_client_callbacks: ?*c.nghttp2_session_callbacks = null;

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

            // Parse :status pseudo-header
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

            // Populate response components on the entity
            if (!s.entity.isNil() and !nctx.ctx.isStale(s.entity)) {
                var fields: ?[*]HeaderField = null;
                var count: u32 = 0;
                var buf_len: u32 = 0;
                const hdr_buf = s.hdrFinalize(&fields, &count, &buf_len);

                nctx.ctx.set(s.entity, RespHeaders, .{
                    .fields = fields,
                    .count = count,
                    ._buf = hdr_buf,
                    ._buf_len = buf_len,
                }) catch {};

                const body_data = if (s.body_data) |p| blk: {
                    if (s.body_len < s.body_cap) {
                        const shrunk = s.allocator.realloc(p[0..s.body_cap], s.body_len) catch p[0..s.body_cap];
                        break :blk @as(?[*]u8, shrunk.ptr);
                    }
                    break :blk @as(?[*]u8, p);
                } else null;
                nctx.ctx.set(s.entity, RespBody, .{ .data = body_data, .len = s.body_len }) catch {};
                nctx.ctx.set(s.entity, Status, .{ .code = s.response_status }) catch {};

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

            if (!s.entity.isNil() and !nctx.ctx.isStale(s.entity)) {
                const err: i32 = if (error_code == 0) 0 else -1;
                nctx.ctx.set(s.entity, H2IoResult, .{ .err = err }) catch {};
                nctx.ctx.moveOne(s.entity, .client_response_out) catch {};
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

            // Client uses same begin_headers (allocates stream if needed)
            c.nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, &onBeginHeadersCb);
            c.nghttp2_session_callbacks_set_on_header_callback(cbs, &onHeaderClientCb);
            c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, &onDataChunkRecvCb);
            c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, &onFrameRecvClientCb);
            c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, &onStreamCloseClientCb);

            ng_client_callbacks = cbs;
        }

        fn clientSessionCreate(ctx: *Ctx, allocator: std.mem.Allocator, conn: *Conn, conn_entity: Entity, opts: H2Options) !void {
            try ensureClientCallbacks();

            const nctx = try allocator.create(NgCtx);
            nctx.* = .{ .ctx = ctx, .allocator = allocator, .conn_entity = conn_entity };

            var session: ?*c.nghttp2_session = null;
            if (c.nghttp2_session_client_new(&session, ng_client_callbacks, @ptrCast(nctx)) != 0) {
                allocator.destroy(nctx);
                return error.Nghttp2SessionCreateFailed;
            }

            conn.ng_session = session;
            conn.ng_ctx = @ptrCast(nctx);
            conn.ng_ctx_destroy = &destroyNgCtx;

            var settings_buf: [2]c.nghttp2_settings_entry = undefined;
            var settings_count: usize = 0;
            settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = opts.max_concurrent_streams };
            settings_count += 1;

            if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings_buf, settings_count) != 0) {
                c.nghttp2_session_del(session);
                allocator.destroy(nctx);
                conn.ng_session = null;
                conn.ng_ctx = null;
                return error.Nghttp2SettingsFailed;
            }
        }

        // =============================================================
        // Public API
        // =============================================================

        pub fn create(ctx: *Ctx, allocator: std.mem.Allocator, addr: std.net.Address, io_opts: rio.IoOptions, h2_opts: H2Options) !*Self {
            try ensureCallbacks();

            const io = try rio.Io(Ctx).create(ctx, allocator, addr, io_opts);
            errdefer io.destroy();

            const self = try allocator.create(Self);
            self.* = .{
                .io = io,
                .h2_opts = h2_opts,
                .allocator = allocator,
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.io.destroy();
            allocator.destroy(self);
        }

        pub fn poll(self: *Self, ctx: *Ctx, min_complete: u32) !void {
            _ = try self.io.poll(ctx, min_complete);

            // Consume user input (responses + streaming + client)
            try consumeResponses(ctx, self.allocator);
            try consumeStreamResponses(ctx, self.allocator);
            try consumeStreamData(ctx);
            try consumeStreamClose(ctx);
            if (has_client) {
                try self.consumeConnectRequests(ctx);
                try self.consumeClientRequests(ctx);
                try self.consumeClientStreamRequests(ctx);
                try consumeClientStreamData(ctx);
                try consumeClientStreamClose(ctx);
            }
            try ctx.flush();

            // Read triage
            try readsTriage(ctx);
            try ctx.flush();

            // Handle read errors
            try readsHandleErrors(ctx);
            try ctx.flush();

            // Client: process connect results/errors
            if (has_client) {
                try self.processConnectResults(ctx);
                try self.processConnectErrors(ctx);
                try ctx.flush();
            }

            // Init new connections (create TLS or nghttp2 sessions)
            try self.readsInitConnections(ctx);
            try ctx.flush();

            // Transition connections → _conn_tls_handshake or _conn_active
            try self.transitionNewConnections(ctx);
            try ctx.flush();

            // TLS handshake
            if (self.h2_opts.tls_config != null) {
                try self.readsTlsHandshake(ctx);
                try ctx.flush();

                try transitionHandshakeConnections(ctx);
                try ctx.flush();
            }

            // Feed data to nghttp2 (decrypt if TLS)
            try self.readsFeedData(ctx);
            try ctx.flush();

            // Write accounting
            try writesAccount(ctx);
            try ctx.flush();

            // Drive sends (encrypt if TLS)
            try self.driveAllSends(ctx);
            try ctx.flush();
        }

        // =============================================================
        // Phase 1: Consume user responses
        // =============================================================

        fn consumeResponses(ctx: *Ctx, allocator: std.mem.Allocator) !void {
            const entities = ctx.entities(.response_in);
            const sessions = ctx.column(.response_in, Session);
            const sids = ctx.column(.response_in, StreamId);
            const statuses = ctx.column(.response_in, Status);
            const resp_hdrs = ctx.column(.response_in, RespHeaders);
            const resp_bodies = ctx.column(.response_in, RespBody);
            const io_results = ctx.column(.response_in, H2IoResult);

            for (entities, sessions, sids, statuses, resp_hdrs, resp_bodies, io_results) |ent, sess, sid, status, rh, rb, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .response_in, .response_out);
                    continue;
                };

                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .response_in, .response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                var status_buf: [3]u8 = undefined;
                const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status.code}) catch "500";
                const status_len = status_str.len;

                const nv_count: usize = 1 + @as(usize, rh.count);
                const nva_slice = allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .response_in, .response_out);
                    continue;
                };
                const nva: [*]c.nghttp2_nv = nva_slice.ptr;
                defer allocator.free(nva_slice);

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
                    body_data_ptr = BodyData.create(allocator, rb.data.?, rb.len) orelse {
                        io_res.err = -1;
                        try ctx.moveOneFrom(ent, .response_in, .response_out);
                        continue;
                    };
                    data_prd.source = .{ .ptr = @ptrCast(body_data_ptr) };
                    data_prd.read_callback = &onDataSourceReadCb;
                }

                const rv = c.nghttp2_submit_response(ng_session, @intCast(sid.id), nva, nv_count, if (data_prd.read_callback != null) &data_prd else null);

                if (rv < 0) {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .response_in, .response_out);
                    continue;
                }

                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream) |s| {
                    s.entity = ent;
                    s.send_complete = (data_prd.read_callback == null);
                    s.send_data = body_data_ptr;
                    try ctx.moveOneFrom(ent, .response_in, ._response_sending);
                } else {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .response_in, .response_out);
                }
            }
        }

        // =============================================================
        // Streaming: consume stream_response_in
        // =============================================================

        fn consumeStreamResponses(ctx: *Ctx, allocator: std.mem.Allocator) !void {
            const entities = ctx.entities(.stream_response_in);
            const sessions = ctx.column(.stream_response_in, Session);
            const sids = ctx.column(.stream_response_in, StreamId);
            const statuses = ctx.column(.stream_response_in, Status);
            const resp_hdrs = ctx.column(.stream_response_in, RespHeaders);
            const io_results = ctx.column(.stream_response_in, H2IoResult);

            for (entities, sessions, sids, statuses, resp_hdrs, io_results) |ent, sess, sid, status, rh, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_response_in, .response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_response_in, .response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                var status_buf: [3]u8 = undefined;
                const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status.code}) catch "500";

                const nv_count: usize = 1 + @as(usize, rh.count);
                const nva_slice = allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_response_in, .response_out);
                    continue;
                };
                const nva: [*]c.nghttp2_nv = nva_slice.ptr;
                defer allocator.free(nva_slice);

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

                // Deferred data provider — source.ptr NULL signals streaming path
                var data_prd = c.nghttp2_data_provider{
                    .source = .{ .ptr = null },
                    .read_callback = &onDataSourceReadCb,
                };

                const rv = c.nghttp2_submit_response(ng_session, @intCast(sid.id), nva, nv_count, &data_prd);
                if (rv < 0) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_response_in, .response_out);
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
                    try ctx.moveOneFrom(ent, .stream_response_in, .stream_data_out);
                } else {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_response_in, .response_out);
                }
            }
        }

        // =============================================================
        // Streaming: consume stream_data_in
        // =============================================================

        fn consumeStreamData(ctx: *Ctx) !void {
            const entities = ctx.entities(.stream_data_in);
            const sessions = ctx.column(.stream_data_in, Session);
            const sids = ctx.column(.stream_data_in, StreamId);
            const resp_bodies = ctx.column(.stream_data_in, RespBody);
            const io_results = ctx.column(.stream_data_in, H2IoResult);

            for (entities, sessions, sids, resp_bodies, io_results) |ent, sess, sid, *rb, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_data_in, .response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_data_in, .response_out);
                    continue;
                }

                // Skip empty chunks — move back to ready
                if (rb.data == null or rb.len == 0) {
                    try ctx.moveOneFrom(ent, .stream_data_in, .stream_data_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_data_in, .response_out);
                    continue;
                }

                const s = stream.?;

                // Transfer chunk ownership from component to stream struct
                s.stream_chunk_data = rb.data;
                s.stream_chunk_len = rb.len;
                s.stream_chunk_offset = 0;
                rb.data = null;
                rb.len = 0;

                // Un-defer so nghttp2 calls onDataSourceReadCb
                _ = c.nghttp2_session_resume_data(ng_session, s.ng_stream_id);

                try ctx.moveOneFrom(ent, .stream_data_in, ._stream_data_sending);
            }
        }

        // =============================================================
        // Streaming: consume stream_close_in
        // =============================================================

        fn consumeStreamClose(ctx: *Ctx) !void {
            const entities = ctx.entities(.stream_close_in);
            const sessions = ctx.column(.stream_close_in, Session);
            const sids = ctx.column(.stream_close_in, StreamId);
            const io_results = ctx.column(.stream_close_in, H2IoResult);

            for (entities, sessions, sids, io_results) |ent, sess, sid, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_close_in, .response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_close_in, .response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .stream_close_in, .response_out);
                    continue;
                }

                stream.?.stream_eof = true;

                // Un-defer so onDataSourceReadCb sees EOF and sets NGHTTP2_DATA_FLAG_EOF
                _ = c.nghttp2_session_resume_data(ng_session, stream.?.ng_stream_id);

                try ctx.moveOneFrom(ent, .stream_close_in, ._stream_data_sending);
            }
        }

        // =============================================================
        // Phase 2: Read triage
        // =============================================================

        fn readsTriage(ctx: *Ctx) !void {
            const entities = ctx.entities(.read_results);
            const conn_ents = ctx.column(.read_results, rio.ConnEntity);
            const results = ctx.column(.read_results, rio.ReadResult);

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (ctx.isStale(conn_ent.entity) or ctx.isMoving(conn_ent.entity)) {
                    try ctx.moveOneFrom(ent, .read_results, ._read_errors);
                    continue;
                }
                if (rr.result <= 0) {
                    try ctx.moveOneFrom(ent, .read_results, ._read_errors);
                    continue;
                }
                if (ctx.isInCollection(conn_ent.entity, .connections)) {
                    try ctx.moveOneFrom(ent, .read_results, ._read_init);
                    continue;
                }
                if (ctx.isInCollection(conn_ent.entity, ._conn_tls_handshake)) {
                    try ctx.moveOneFrom(ent, .read_results, ._read_handshake);
                    continue;
                }
                if (ctx.isInCollection(conn_ent.entity, ._conn_active)) {
                    try ctx.moveOneFrom(ent, .read_results, ._read_active);
                    continue;
                }
                try ctx.moveOneFrom(ent, .read_results, ._read_errors);
            }
        }

        // =============================================================
        // Phase 3: Handle read errors
        // =============================================================

        fn readsHandleErrors(ctx: *Ctx) !void {
            const entities = ctx.entities(._read_errors);
            const conn_ents = ctx.column(._read_errors, rio.ConnEntity);

            for (entities, conn_ents) |ent, conn_ent| {
                if (!ctx.isStale(conn_ent.entity)) {
                    try ctx.destroyOne(conn_ent.entity);
                }
                // Move to read_in — rove-io returns the buffer to the ring
                try ctx.moveOneFrom(ent, ._read_errors, .read_in);
            }
        }

        // =============================================================
        // Phase 4: Init new connections
        // =============================================================

        fn readsInitConnections(self: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(._read_init);
            const conn_ents = ctx.column(._read_init, rio.ConnEntity);

            for (entities, conn_ents) |ent, conn_ent| {
                if (ctx.isStale(conn_ent.entity)) {
                    try ctx.moveOneFrom(ent, ._read_init, .read_in);
                    continue;
                }

                const conn_ptr = ctx.get(conn_ent.entity, Conn) catch {
                    try ctx.moveOneFrom(ent, ._read_init, .read_in);
                    continue;
                };

                if (self.h2_opts.tls_config) |tls_cfg| {
                    // TLS mode: create SSL connection, start handshake
                    conn_ptr.tls_conn = tls.TlsConn.create(tls_cfg, self.allocator) catch {
                        try ctx.destroyOne(conn_ent.entity);
                        try ctx.moveOneFrom(ent, ._read_init, .read_in);
                        continue;
                    };
                    // Feed initial data to start handshake
                    try ctx.moveOneFrom(ent, ._read_init, ._read_handshake);
                } else {
                    // h2c mode: create nghttp2 session directly
                    sessionCreate(ctx, self.allocator, conn_ptr, conn_ent.entity, self.h2_opts) catch {
                        try ctx.destroyOne(conn_ent.entity);
                        try ctx.moveOneFrom(ent, ._read_init, .read_in);
                        continue;
                    };
                    try ctx.moveOneFrom(ent, ._read_init, ._read_active);
                }
            }
        }

        // =============================================================
        // Phase 5: Transition new connections → _conn_active
        // =============================================================

        fn transitionNewConnections(self: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(.connections);
            const max = self.h2_opts.max_h2_connections;
            var active_count: u32 = @intCast(ctx.entities(._conn_active).len);

            for (entities) |ent| {
                const conn_ptr = ctx.get(ent, Conn) catch continue;

                // TLS connections go to handshake first
                if (conn_ptr.tls_conn != null and conn_ptr.ng_session == null) {
                    if (max > 0 and active_count >= max) {
                        try ctx.destroyOne(ent);
                        continue;
                    }
                    conn_ptr.last_active_ns = monotonicNs();
                    try ctx.moveOneFrom(ent, .connections, ._conn_tls_handshake);
                    active_count += 1;
                    continue;
                }

                if (conn_ptr.ng_session == null) continue;

                if (max > 0 and active_count >= max) {
                    try ctx.destroyOne(ent);
                    continue;
                }

                conn_ptr.last_active_ns = monotonicNs();
                try ctx.moveOneFrom(ent, .connections, ._conn_active);
                active_count += 1;
            }
        }

        // =============================================================
        // Phase 6: Feed active data to nghttp2
        // =============================================================

        // =============================================================
        // TLS handshake
        // =============================================================

        fn readsTlsHandshake(self: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(._read_handshake);
            const conn_ents = ctx.column(._read_handshake, rio.ConnEntity);
            const results = ctx.column(._read_handshake, rio.ReadResult);

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (ctx.isStale(conn_ent.entity)) {
                    try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                    continue;
                }

                const conn_ptr = ctx.get(conn_ent.entity, Conn) catch {
                    try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                    continue;
                };

                const tc = conn_ptr.tls_conn orelse {
                    try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                    continue;
                };

                // Feed raw data to TLS
                const raw = if (rr.data) |d| d[0..@intCast(rr.result)] else &[_]u8{};
                var decrypt_buf: [16384]u8 = undefined;
                const feed_result = tc.feed(raw, &decrypt_buf);

                switch (feed_result.result) {
                    .need_more => {
                        // Send handshake output, recycle read
                        if (tc.drainOutput(self.allocator) catch null) |output| {
                            self.submitWrite(ctx, conn_ent.entity, output) catch {
                                self.allocator.free(output);
                            };
                        }
                        try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                    },
                    .handshake_done => {
                        // Send final handshake output
                        if (tc.drainOutput(self.allocator) catch null) |output| {
                            self.submitWrite(ctx, conn_ent.entity, output) catch {
                                self.allocator.free(output);
                            };
                        }
                        // Create nghttp2 session now that TLS is done
                        sessionCreate(ctx, self.allocator, conn_ptr, conn_ent.entity, self.h2_opts) catch {
                            try ctx.destroyOne(conn_ent.entity);
                            try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                            continue;
                        };
                        // If there's decrypted app data, feed it to nghttp2
                        if (feed_result.out_len > 0 and conn_ptr.ng_session != null) {
                            _ = c.nghttp2_session_mem_recv(
                                conn_ptr.ng_session.?,
                                &decrypt_buf,
                                feed_result.out_len,
                            );
                        }
                        try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                    },
                    .data, .err => {
                        // Error during handshake
                        try ctx.destroyOne(conn_ent.entity);
                        try ctx.moveOneFrom(ent, ._read_handshake, .read_in);
                    },
                }
            }
        }

        fn transitionHandshakeConnections(ctx: *Ctx) !void {
            const entities = ctx.entities(._conn_tls_handshake);
            for (entities) |ent| {
                const conn_ptr = ctx.get(ent, Conn) catch continue;
                // Move to active once nghttp2 session is created (handshake complete)
                if (conn_ptr.ng_session != null) {
                    try ctx.moveOneFrom(ent, ._conn_tls_handshake, ._conn_active);
                }
            }
        }

        // =============================================================
        // Helper: submit a write entity
        // =============================================================

        fn submitWrite(_: *Self, ctx: *Ctx, conn_entity: Entity, data: []u8) !void {
            const we = try ctx.createOneImmediate(.write_in);
            try ctx.set(we, rio.ConnEntity, .{ .entity = conn_entity });
            try ctx.set(we, rio.WriteBuf, .{ .data = data.ptr, .len = @intCast(data.len) });
        }

        // =============================================================
        // Feed active data to nghttp2
        // =============================================================

        fn readsFeedData(_: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(._read_active);
            const conn_ents = ctx.column(._read_active, rio.ConnEntity);
            const results = ctx.column(._read_active, rio.ReadResult);

            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (ctx.isStale(conn_ent.entity)) {
                    try ctx.moveOneFrom(ent, ._read_active, .read_in);
                    continue;
                }

                const conn_ptr = ctx.get(conn_ent.entity, Conn) catch {
                    try ctx.moveOneFrom(ent, ._read_active, .read_in);
                    continue;
                };

                if (conn_ptr.ng_session == null) {
                    try ctx.moveOneFrom(ent, ._read_active, .read_in);
                    continue;
                }

                // Feed data to nghttp2 — decrypt first if TLS.
                if (rr.data) |data_ptr| {
                    const data_len: usize = @intCast(rr.result);

                    if (conn_ptr.tls_conn) |tc| {
                        // TLS: decrypt then feed
                        var decrypt_buf: [65536]u8 = undefined;
                        const feed_result = tc.feed(data_ptr[0..data_len], &decrypt_buf);
                        if (feed_result.result == .err) {
                            try ctx.destroyOne(conn_ent.entity);
                            try ctx.moveOneFrom(ent, ._read_active, .read_in);
                            continue;
                        }
                        if (feed_result.out_len > 0) {
                            const rv = c.nghttp2_session_mem_recv(conn_ptr.ng_session.?, &decrypt_buf, feed_result.out_len);
                            if (rv < 0) {
                                try ctx.destroyOne(conn_ent.entity);
                                try ctx.moveOneFrom(ent, ._read_active, .read_in);
                                continue;
                            }
                        }
                    } else {
                        // h2c: feed raw data directly
                        const rv = c.nghttp2_session_mem_recv(conn_ptr.ng_session.?, data_ptr, data_len);
                        if (rv < 0) {
                            try ctx.destroyOne(conn_ent.entity);
                            try ctx.moveOneFrom(ent, ._read_active, .read_in);
                            continue;
                        }
                    }
                    conn_ptr.last_active_ns = monotonicNs();
                }

                try ctx.moveOneFrom(ent, ._read_active, .read_in);
            }
        }

        // =============================================================
        // Phase 7: Write accounting
        // =============================================================

        fn writesAccount(ctx: *Ctx) !void {
            const entities = ctx.entities(.write_results);
            const conn_ents = ctx.column(.write_results, rio.ConnEntity);
            const io_results = ctx.column(.write_results, rio.IoResult);

            for (entities, conn_ents, io_results) |ent, conn_ent, io_res| {
                // Close connection on write error
                if (!ctx.isStale(conn_ent.entity) and io_res.err != 0) {
                    try ctx.destroyOne(conn_ent.entity);
                }

                // WriteBuf.deinit frees the frame data
                try ctx.destroyOne(ent);
            }
        }

        // =============================================================
        // Phase 8: Drive all nghttp2 sends
        // =============================================================

        fn driveAllSends(self: *Self, ctx: *Ctx) !void {
            const entities = ctx.entities(._conn_active);
            const now = monotonicNs();

            for (entities) |ent| {
                if (ctx.isStale(ent)) continue;

                const conn_ptr = ctx.get(ent, Conn) catch continue;
                if (conn_ptr.ng_session == null) continue;

                // Evict idle connections
                if (self.h2_opts.idle_timeout_ns > 0 and conn_ptr.last_active_ns > 0 and
                    now -| conn_ptr.last_active_ns > self.h2_opts.idle_timeout_ns)
                {
                    try ctx.destroyOne(ent);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                if (c.nghttp2_session_want_write(ng_session) == 0 and
                    c.nghttp2_session_want_read(ng_session) == 0)
                {
                    try ctx.destroyOne(ent);
                    continue;
                }

                if (c.nghttp2_session_want_write(ng_session) == 0) continue;

                if (conn_ptr.tls_conn) |tc| {
                    // TLS: accumulate all output, encrypt, send as one chunk
                    var accum_buf: [65536]u8 = undefined;
                    var accum_len: usize = 0;

                    while (true) {
                        var frame_data: [*c]const u8 = undefined;
                        const len = c.nghttp2_session_mem_send(ng_session, &frame_data);
                        if (len < 0) { try ctx.destroyOne(ent); break; }
                        if (len == 0) break;
                        const flen: usize = @intCast(len);
                        if (accum_len + flen > accum_buf.len) {
                            try ctx.destroyOne(ent);
                            break;
                        }
                        @memcpy(accum_buf[accum_len .. accum_len + flen], frame_data[0..flen]);
                        accum_len += flen;
                    }

                    if (accum_len > 0) {
                        const cipher = tc.encrypt(accum_buf[0..accum_len], self.allocator) catch {
                            try ctx.destroyOne(ent);
                            continue;
                        };
                        self.submitWrite(ctx, ent, cipher) catch {
                            self.allocator.free(cipher);
                            try ctx.destroyOne(ent);
                            continue;
                        };
                    }
                } else {
                    // h2c: send plaintext directly
                    while (true) {
                        var frame_data: [*c]const u8 = undefined;
                        const len = c.nghttp2_session_mem_send(ng_session, &frame_data);
                        if (len < 0) { try ctx.destroyOne(ent); break; }
                        if (len == 0) break;

                        const copy_len: u32 = @intCast(len);
                        const copy = self.allocator.alloc(u8, copy_len) catch {
                            try ctx.destroyOne(ent);
                            break;
                        };
                        @memcpy(copy, frame_data[0..copy_len]);

                        self.submitWrite(ctx, ent, copy) catch {
                            self.allocator.free(copy);
                            try ctx.destroyOne(ent);
                            break;
                        };
                    }
                }

                conn_ptr.last_active_ns = now;
            }
        }

        // =============================================================
        // =============================================================
        // Client: consume connect requests
        // =============================================================

        fn consumeConnectRequests(self: *Self, ctx: *Ctx) !void {
            if (!has_client) return;
            const entities = ctx.entities(.client_connect_in);
            const targets = ctx.column(.client_connect_in, ConnectTarget);

            for (entities, targets) |ent, target| {
                // Create rove-io connect entity
                const ce = ctx.createOneImmediate(.connect_in) catch {
                    try ctx.set(ent, H2IoResult, .{ .err = -1 });
                    try ctx.moveOneFrom(ent, .client_connect_in, .client_connect_errors);
                    continue;
                };
                try ctx.set(ce, rio.ConnectAddr, .{ .addr = target.addr });
                // Mark as client direction on the connection component
                try ctx.set(ce, Conn, .{ .direction = .client, .pending_connect_entity = ent });

                // Park user entity
                try ctx.moveOneFrom(ent, .client_connect_in, ._client_connect_pending);
                _ = self;
            }
        }

        // =============================================================
        // Client: process connect results
        // =============================================================

        fn processConnectResults(self: *Self, ctx: *Ctx) !void {
            if (!has_client) return;
            const entities = ctx.entities(.connections);

            for (entities) |ent| {
                const conn_ptr = ctx.get(ent, Conn) catch continue;
                if (conn_ptr.direction != .client) continue;
                if (conn_ptr.pending_connect_entity.isNil()) continue;

                const user_ent = conn_ptr.pending_connect_entity;
                if (ctx.isStale(user_ent)) {
                    conn_ptr.pending_connect_entity = Entity.nil;
                    continue;
                }

                // Create client nghttp2 session
                clientSessionCreate(ctx, self.allocator, conn_ptr, ent, self.h2_opts) catch {
                    ctx.set(user_ent, H2IoResult, .{ .err = -1 }) catch {};
                    ctx.moveOneFrom(user_ent, ._client_connect_pending, .client_connect_errors) catch {};
                    ctx.destroyOne(ent) catch {};
                    continue;
                };

                // Set session handle on user entity
                ctx.set(user_ent, Session, .{ .entity = ent }) catch {};
                ctx.set(user_ent, H2IoResult, .{ .err = 0 }) catch {};
                ctx.moveOneFrom(user_ent, ._client_connect_pending, .client_connect_out) catch {};

                conn_ptr.pending_connect_entity = Entity.nil;
                conn_ptr.last_active_ns = monotonicNs();
            }
        }

        // =============================================================
        // Client: process connect errors
        // =============================================================

        fn processConnectErrors(self: *Self, ctx: *Ctx) !void {
            if (!has_client) return;
            _ = self;
            const entities = ctx.entities(.connect_errors);
            const conns = ctx.column(.connect_errors, Conn);

            for (entities, conns) |ent, conn| {
                const user_ent = conn.pending_connect_entity;
                if (!user_ent.isNil() and !ctx.isStale(user_ent)) {
                    ctx.set(user_ent, H2IoResult, .{ .err = -1 }) catch {};
                    ctx.moveOneFrom(user_ent, ._client_connect_pending, .client_connect_errors) catch {};
                }
                try ctx.destroyOne(ent);
            }
        }

        // =============================================================
        // Client: consume client requests
        // =============================================================

        fn consumeClientRequests(self: *Self, ctx: *Ctx) !void {
            if (!has_client) return;
            const entities = ctx.entities(.client_request_in);
            const sessions = ctx.column(.client_request_in, Session);
            const req_hdrs = ctx.column(.client_request_in, ReqHeaders);
            const req_bodies = ctx.column(.client_request_in, ReqBody);
            const io_results = ctx.column(.client_request_in, H2IoResult);

            for (entities, sessions, req_hdrs, req_bodies, io_results) |ent, sess, rh, rb, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                // Build nghttp2_nv from request headers
                const nv_count: usize = @as(usize, rh.count);
                if (nv_count == 0) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
                    continue;
                }

                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
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

                // Data provider for request body
                var data_prd: c.nghttp2_data_provider = std.mem.zeroes(c.nghttp2_data_provider);
                var body_data_ptr: ?*BodyData = null;
                if (rb.data != null and rb.len > 0) {
                    body_data_ptr = BodyData.create(self.allocator, rb.data.?, rb.len) orelse {
                        io_res.err = -1;
                        try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
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
                    try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
                    continue;
                }

                // Create stream and associate
                const stream = Stream.create(sess.entity, self.allocator) orelse {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_request_in, .client_response_out);
                    continue;
                };
                stream.entity = ent;
                stream.send_complete = (data_prd.read_callback == null);
                stream.send_data = body_data_ptr;
                _ = c.nghttp2_session_set_stream_user_data(ng_session, stream_id, @ptrCast(stream));

                try ctx.set(ent, StreamId, .{ .id = @intCast(stream_id) });
                try ctx.moveOneFrom(ent, .client_request_in, ._client_request_sending);
            }
        }

        // =============================================================
        // Client streaming: consume client_stream_request_in
        // =============================================================

        fn consumeClientStreamRequests(self: *Self, ctx: *Ctx) !void {
            if (!has_client) return;
            const entities = ctx.entities(.client_stream_request_in);
            const sessions = ctx.column(.client_stream_request_in, Session);
            const req_hdrs = ctx.column(.client_stream_request_in, ReqHeaders);
            const io_results = ctx.column(.client_stream_request_in, H2IoResult);

            for (entities, sessions, req_hdrs, io_results) |ent, sess, rh, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_request_in, .client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_request_in, .client_response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                const nv_count: usize = @as(usize, rh.count);
                if (nv_count == 0) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_request_in, .client_response_out);
                    continue;
                }

                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_request_in, .client_response_out);
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

                // Deferred data provider — source.ptr NULL signals streaming path
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
                    try ctx.moveOneFrom(ent, .client_stream_request_in, .client_response_out);
                    continue;
                }

                const stream = Stream.create(sess.entity, self.allocator) orelse {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_request_in, .client_response_out);
                    continue;
                };
                stream.entity = ent;
                stream.emitted = true;
                stream.streaming = true;
                stream.client_stream = true;
                stream.send_complete = false;
                stream.send_data = null;
                _ = c.nghttp2_session_set_stream_user_data(ng_session, stream_id, @ptrCast(stream));

                try ctx.set(ent, StreamId, .{ .id = @intCast(stream_id) });
                try ctx.moveOneFrom(ent, .client_stream_request_in, .client_stream_data_out);
            }
        }

        // =============================================================
        // Client streaming: consume client_stream_data_in
        // =============================================================

        fn consumeClientStreamData(ctx: *Ctx) !void {
            if (!has_client) return;
            const entities = ctx.entities(.client_stream_data_in);
            const sessions = ctx.column(.client_stream_data_in, Session);
            const sids = ctx.column(.client_stream_data_in, StreamId);
            const req_bodies = ctx.column(.client_stream_data_in, ReqBody);
            const io_results = ctx.column(.client_stream_data_in, H2IoResult);

            for (entities, sessions, sids, req_bodies, io_results) |ent, sess, sid, *rb, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_data_in, .client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_data_in, .client_response_out);
                    continue;
                }

                // Skip empty chunks — move back to ready
                if (rb.data == null or rb.len == 0) {
                    try ctx.moveOneFrom(ent, .client_stream_data_in, .client_stream_data_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_data_in, .client_response_out);
                    continue;
                }

                const s = stream.?;

                // Transfer chunk ownership from component to stream struct
                s.stream_chunk_data = rb.data;
                s.stream_chunk_len = rb.len;
                s.stream_chunk_offset = 0;
                rb.data = null;
                rb.len = 0;

                // Un-defer so nghttp2 calls onDataSourceReadCb
                _ = c.nghttp2_session_resume_data(ng_session, s.ng_stream_id);

                try ctx.moveOneFrom(ent, .client_stream_data_in, ._client_stream_data_sending);
            }
        }

        // =============================================================
        // Client streaming: consume client_stream_close_in
        // =============================================================

        fn consumeClientStreamClose(ctx: *Ctx) !void {
            if (!has_client) return;
            const entities = ctx.entities(.client_stream_close_in);
            const sessions = ctx.column(.client_stream_close_in, Session);
            const sids = ctx.column(.client_stream_close_in, StreamId);
            const io_results = ctx.column(.client_stream_close_in, H2IoResult);

            for (entities, sessions, sids, io_results) |ent, sess, sid, *io_res| {
                const conn_ptr = ctx.get(sess.entity, Conn) catch {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_close_in, .client_response_out);
                    continue;
                };
                if (conn_ptr.ng_session == null or ctx.isStale(sess.entity)) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_close_in, .client_response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try ctx.moveOneFrom(ent, .client_stream_close_in, .client_response_out);
                    continue;
                }

                stream.?.stream_eof = true;

                // Un-defer so onDataSourceReadCb sees EOF and sets NGHTTP2_DATA_FLAG_EOF
                _ = c.nghttp2_session_resume_data(ng_session, stream.?.ng_stream_id);

                try ctx.moveOneFrom(ent, .client_stream_close_in, ._client_stream_data_sending);
            }
        }

    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn testRow(comptime S: type, comptime name: []const u8) type {
    return rove.CollectionRow(S, name);
}

test "spec produces all expected collections" {
    const S = Collections(.{});
    try testing.expect(@hasField(S, "connections"));
    try testing.expect(@hasField(S, "read_results"));
    try testing.expect(@hasField(S, "write_results"));
    try testing.expect(@hasField(S, "read_in"));
    try testing.expect(@hasField(S, "write_in"));
    try testing.expect(@hasField(S, "_read_pending"));
    try testing.expect(@hasField(S, "_write_pending"));
    try testing.expect(@hasField(S, "request_out"));
    try testing.expect(@hasField(S, "response_in"));
    try testing.expect(@hasField(S, "response_out"));
    try testing.expect(@hasField(S, "_response_sending"));
    try testing.expect(@hasField(S, "_read_errors"));
    try testing.expect(@hasField(S, "_read_init"));
    try testing.expect(@hasField(S, "_read_active"));
    try testing.expect(@hasField(S, "_conn_active"));
}

test "stream collections share the same row" {
    const S = Collections(.{});
    try testing.expect(testRow(S, "request_out").equal(testRow(S, "response_in")));
    try testing.expect(testRow(S, "response_in").equal(testRow(S, "response_out")));
    try testing.expect(testRow(S, "response_out").equal(testRow(S, "_response_sending")));
}

test "stream row contains all h2 base components" {
    const R = testRow(Collections(.{}), "request_out");
    try testing.expect(R.contains(StreamId));
    try testing.expect(R.contains(Session));
    try testing.expect(R.contains(ReqHeaders));
    try testing.expect(R.contains(ReqBody));
    try testing.expect(R.contains(RespHeaders));
    try testing.expect(R.contains(RespBody));
    try testing.expect(R.contains(Status));
    try testing.expect(R.contains(H2IoResult));
}

test "connection rows" {
    const S = Collections(.{});
    try testing.expect(testRow(S, "connections").contains(Conn));
    try testing.expect(testRow(S, "connections").contains(rio.Fd));
    try testing.expect(testRow(S, "connections").contains(rio.ReadCycleEntity));
    try testing.expect(testRow(S, "connections").isSubsetOf(testRow(S, "_conn_active")));
}

test "read triage collections match rove-io read row" {
    const S = Collections(.{});
    try testing.expect(testRow(S, "read_results").equal(testRow(S, "_read_errors")));
    try testing.expect(testRow(S, "read_results").equal(testRow(S, "_read_init")));
    try testing.expect(testRow(S, "read_results").equal(testRow(S, "_read_active")));
}

test "user rows pass through" {
    const MyAppData = struct { tag: u64 };
    const MySession = struct { id: u64 };
    const S = Collections(.{ .request_row = Row(&.{MyAppData}), .connection_row = Row(&.{MySession}) });
    try testing.expect(testRow(S, "request_out").contains(MyAppData));
    try testing.expect(testRow(S, "_response_sending").contains(MyAppData));
    try testing.expect(testRow(S, "connections").contains(MySession));
    try testing.expect(testRow(S, "_conn_active").contains(MySession));
}

test "spec works with MergeCollections and Context" {
    const MySession = struct { id: u64 };
    const AppSpec = rove.MakeCollections(&.{
        rove.col("app_state", rove.Collection(Row(&.{MySession}), .{})),
    });
    const Spec = rove.MergeCollections(.{ Collections(.{ .connection_row = Row(&.{MySession}) }), AppSpec });
    const Ctx = rove.Context(Spec);
    var ctx = try Ctx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const conn = try ctx.createOne(.connections);
    const req = try ctx.createOne(.request_out);
    try ctx.flush();
    try testing.expect(!ctx.isStale(conn));
    try testing.expect(!ctx.isStale(req));
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
