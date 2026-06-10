const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const Row = rove.Row;
const Collection = rove.Collection;
const Registry = rove.Registry;
const Entity = rove.Entity;
pub const tls = @import("tls.zig");
pub const TlsConfig = tls.TlsConfig;
pub const http1 = @import("http1.zig");
pub const ws = @import("ws.zig");

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

/// Per-WebSocket-message metadata on a WS seam entity (docs/websocket-plan.md
/// §4.6). `opcode` is the RFC 6455 data opcode (`ws.Opcode` int): `1` text,
/// `2` binary on an inbound `ws_message_out` entity (`8` close = client closed);
/// the same field selects the frame type for an outbound `ws_send_in` entity.
/// The payload itself rides the entity's `ReqBody` (allocator-owned bytes).
pub const WsMeta = struct {
    opcode: u8 = 0,
};

/// What an `headers_first` server does with inbound DATA on a stream
/// whose request entity was early-emitted at the HEADERS frame
/// (`docs/blob-storage-plan.md` §3.5.1, the `blob.receive`
/// transport). The entity's lifecycle state is collection
/// membership, not this flag: `request_receiving` (early-emitted,
/// consumer hasn't decided) → `request_buffering`
/// (`requestBodyBuffer` called) → `request_out` (END_STREAM landed,
/// body attached). `BodyMode` is the stream-side window policy that
/// shadows those moves: `.hold` buffers but does NOT consume — the
/// flow-control window closes after one window's worth and the
/// client stalls at the door until the consumer decides. `.buffer`
/// mirrors the classic auto-window path (accumulate + consume
/// immediately). `.discard` drops body bytes (the consumer answered
/// from headers alone). `.auto` is the non-headers_first default
/// (nghttp2 auto window update, no manual consume).
const BodyMode = enum(u8) { auto = 0, hold, buffer, discard };

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
    /// Set true after the first non-empty read on a server-direction
    /// plaintext connection. Used to gate the HTTP/1.1-vs-h2 preface
    /// sniff: only the first read can possibly be a non-h2 protocol;
    /// later frames may have arbitrary leading bytes.
    first_read_seen: bool = false,
    /// HTTP/1.1 connection state, mutually exclusive with `ng_session`.
    /// Set when the first-read sniff (or, in a later phase, ALPN) routes
    /// a server connection to the h1 codec instead of nghttp2. While this
    /// is non-null the connection is driven entirely by `http1Feed` /
    /// `http1WriteResponse` (docs/v2-edge-http1-ingress.md).
    h1: ?*Http1Conn = null,

    pub fn deinit(_: std.mem.Allocator, items: []Conn) void {
        for (items) |*item| {
            if (item.h1) |h1c| {
                h1c.free();
                item.h1 = null;
            }
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

/// Per-connection HTTP/1.1 state (docs/v2-edge-http1-ingress.md, Phase 2).
/// Accumulates inbound bytes, drives the pure `http1` codec, and tracks the
/// single in-flight request (no pipelining). Heap-owned; freed by `Conn.deinit`.
pub const Http1Conn = struct {
    allocator: std.mem.Allocator,
    /// Inbound bytes not yet fully consumed by an emitted request. The head of
    /// a complete request is dropped (compacted out) at emit time; any trailing
    /// bytes (a coalesced next request) stay buffered until the response drains.
    buf: std.ArrayList(u8),
    /// True while a request entity is emitted and awaiting its response. No
    /// second request is parsed until the first responds.
    in_flight: bool = false,
    /// Keep-alive decision captured from the in-flight request's head, applied
    /// when its response is serialized.
    keep_alive: bool = true,
    /// Set once a response with `Connection: close` (or a fatal error response)
    /// has been queued; the connection is reaped by the idle-timeout GC after
    /// the write drains (same path the old 426 used).
    closing: bool = false,
    /// Chunked-request decode state (Phase 4). `chunk_body` accumulates the
    /// assembled body across reads; `chunk_pos` is the resume offset into the
    /// post-head region so consumed chunks are never re-scanned. Reset per
    /// request at emit. `continue_sent` guards against re-emitting `100
    /// Continue` for an `Expect: 100-continue` request on every read.
    chunk_body: std.ArrayList(u8) = .empty,
    chunk_pos: usize = 0,
    continue_sent: bool = false,
    /// A chunked streaming response (SSE / ReadableStream) is in progress: the
    /// head went out with `Transfer-Encoding: chunked` and body pieces are being
    /// written as chunks. Cleared at the terminating zero-chunk.
    streaming: bool = false,
    /// Backpressure: the stream entity parked in `_stream_data_sending` whose
    /// chunk (or head) write is in flight. Released back to `stream_data_out`
    /// (the worker's "push the next piece" signal) only when that write drains
    /// to the socket — so exactly one write is outstanding per stream, which
    /// both paces the producer and keeps the chunks correctly ordered on the
    /// wire. `nil` when no write is in flight.
    sending_entity: Entity = Entity.nil,

    // ── WebSocket mode (docs/websocket-plan.md §4.5/§4.6) ────────────────────
    /// Set once the `101` Upgrade has been queued: the connection has left the
    /// HTTP request/response model and `buf` now accumulates RFC 6455 frames
    /// (parsed by `wsDrive`, not `http1Drive`).
    ws_mode: bool = false,
    /// Reassembly buffer for a fragmented data message (a non-FIN opener +
    /// `continuation` frames). Empty between messages. `ws_msg_opcode` records
    /// the opener's opcode (text/binary); 0 means no message is in progress.
    ws_msg: std.ArrayList(u8) = .empty,
    ws_msg_opcode: u8 = 0,
    /// Outbound framed-byte queue. Every server→client write (the `101`, WS data
    /// frames, auto-pongs, the Close echo) is appended here and flushed by
    /// `wsFlush` with exactly one socket write in flight (`ws_write_inflight`),
    /// which both preserves frame order on the wire and coalesces a burst into
    /// one write. Reused (capacity retained) across flushes.
    ws_out: std.ArrayList(u8) = .empty,
    ws_write_inflight: bool = false,
    /// A Close frame has been queued (client-initiated or protocol error); the
    /// connection is destroyed once `ws_out` drains.
    ws_closing: bool = false,
    /// Routing captured from the `101` Upgrade request (piece D, the worker
    /// seam). The handshake completes at the transport layer without the worker,
    /// then drops the request head — so without this the first inbound frame has
    /// no tenant/module context. The worker reads these via `wsConnRouting` off
    /// the `ws_message_out` entity's `Session`, resolves the tenant from
    /// `ws_authority`, and the handler module from `ws_path`. Owned (duped at
    /// handshake); `""` until then; freed in `free`.
    ws_authority: []u8 = &.{},
    ws_path: []u8 = &.{},

    /// Hard ceiling on a single reassembled WebSocket message at the edge — the
    /// per-frame cap fed to `ws.parseFrame` and the running cap on a fragmented
    /// message. Per-tenant plan limits are the DP worker's job (piece D); this
    /// is the coarse front-door backstop, matching `MAX_BODY_BYTES`.
    pub const MAX_WS_MESSAGE: usize = 16 * 1024 * 1024;

    /// Hard ceiling on a buffered request body at the edge. Per-tenant plan
    /// limits (gap #1, 413) are enforced in the DP worker; this is the coarse
    /// front-door backstop against an unbounded `Content-Length` OOM-ing the
    /// proxy before the request ever reaches a tenant.
    pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

    fn create(allocator: std.mem.Allocator) ?*Http1Conn {
        const h = allocator.create(Http1Conn) catch return null;
        h.* = .{ .allocator = allocator, .buf = .empty };
        return h;
    }

    fn free(self: *Http1Conn) void {
        self.buf.deinit(self.allocator);
        self.chunk_body.deinit(self.allocator);
        self.ws_msg.deinit(self.allocator);
        self.ws_out.deinit(self.allocator);
        if (self.ws_authority.len > 0) self.allocator.free(self.ws_authority);
        if (self.ws_path.len > 0) self.allocator.free(self.ws_path);
        self.allocator.destroy(self);
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
    /// headers_first window policy for inbound body DATA — see the
    /// `BodyMode` doc. `.auto` on non-headers_first instances.
    body_mode: BodyMode = .auto,
    /// Bytes received but not yet `nghttp2_session_consume`d while
    /// `body_mode == .hold` — the held flow-control debt. Repaid
    /// when the consumer picks a mode, at END_STREAM, or (connection
    /// window only) at stream close.
    unconsumed: u32 = 0,
    /// headers_first: END_STREAM has been received — the inbound
    /// body is complete. When the request entity already left the
    /// receiving/buffering collections at that point (the worker
    /// pulled it for a headers-first dispatch decision), the bytes
    /// stay in this Stream's buffer with this flag set;
    /// `requestBodyBuffer` attaches them in place and a `blob.receive`
    /// sink drains them directly.
    inbound_eof: bool = false,
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
    /// Connections idle for longer than this get destroyed by
    /// `driveAllSends` so abandoned clients release their registered
    /// recv buffer back to the pool. 10 s by default — every well-
    /// formed request should complete inside 10 ms (handler budget)
    /// plus at most a couple of raft commit rounds, so 10 s is
    /// already 1000× the expected end-to-end time. A connection
    /// silent for 10 s is either an abandoned client or a stuck
    /// peer; either way, freeing the slot is the right move. Set
    /// to 0 to disable (legacy behavior).
    idle_timeout_ns: u64 = 10 * std.time.ns_per_s,
    tls_config: ?*TlsConfig = null,
    /// Headers-first request emission (`docs/blob-storage-plan.md`
    /// §3.5.1). Off (default): request entities appear in
    /// `request_out` at END_STREAM with the full body — the classic
    /// contract every existing consumer (front door, examples) is
    /// built on. On: a server request whose HEADERS frame lacks
    /// END_STREAM is emitted into `request_receiving` immediately,
    /// with nghttp2's auto window update disabled — body DATA
    /// buffers unconsumed (the client stalls after one window)
    /// until the consumer either calls `requestBodyBuffer` (classic
    /// buffering resumes; h2 moves the entity to `request_out` with
    /// the body attached at END_STREAM) or responds early (h2 flips
    /// the stream to discard). Only the rewind worker enables this.
    headers_first: bool = false,
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

    // WebSocket seam row (docs/websocket-plan.md §4.6): one entity per inbound
    // completed message (`ws_message_out`) or outbound frame (`ws_send_in`).
    // Carries the connection (`Session`), the payload (`ReqBody`), the opcode
    // (`WsMeta`), and an error slot (`H2IoResult`), plus the worker's
    // `request_row` so piece D can attach per-activation state — mirroring how
    // `stream_row` merges it for normal requests.
    const ws_row = Row(&.{ Session, ReqBody, WsMeta, H2IoResult }).merge(opts.request_row);

    // Collection types (for comptime)
    const StreamColl = Collection(stream_row, .{});
    const ReadColl = Collection(rio.ReadBaseRow, .{});
    const ConnColl = Collection(full_conn_row, .{});
    const WsColl = Collection(ws_row, .{});

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
        // headers_first early-emission pipeline (h2_opts.headers_first
        // doc). A request entity whose body is still inbound lives in
        // `request_receiving` (fresh — consumer hasn't decided) or
        // `request_buffering` (consumer called `requestBodyBuffer`);
        // h2 attaches the accumulated body and moves it to
        // `request_out` when END_STREAM lands, so `request_out` keeps
        // its body-complete contract. Always-empty when headers_first
        // is off.
        request_receiving: StreamColl,
        request_buffering: StreamColl,
        response_in: StreamColl,
        response_out: StreamColl,
        _response_sending: StreamColl,

        // Streaming response collections
        stream_response_in: StreamColl,
        stream_data_out: StreamColl,
        stream_data_in: StreamColl,
        stream_close_in: StreamColl,
        _stream_data_sending: StreamColl,

        // WebSocket seam (docs/websocket-plan.md §4.6). `ws_message_out` holds a
        // completed inbound message for the consumer (piece D → `onMessage`);
        // `ws_send_in` holds an outbound frame the consumer queued (piece E ←
        // `stream.write`). Outbound backpressure is on the per-conn `ws_out`
        // byte queue + `ws_write_inflight` (one socket write at a time), not on
        // these entities — so control frames (pong/close) interleave with data
        // frames in wire order, which a per-entity `sending_entity` can't model.
        ws_message_out: WsColl,
        ws_send_in: WsColl,

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

        // ENOBUFS-on-recv tracking. The kernel returns ENOBUFS when
        // the io_uring registered buffer pool (`buf_count`) is empty
        // at recv time. Used to be silently dropped (destroyed the
        // conn, lost the request); now it's treated as back-pressure
        // and the connection is re-armed, with a warning on first
        // occurrence and every 10k events thereafter so the
        // misconfiguration is visible.
        recv_enobufs_total: u64 = 0,
        recv_enobufs_logged: bool = false,
        recv_enobufs_last_logged_decade: u64 = 0,
        /// Consecutive `readsTriage` calls where ENOBUFS fired but
        /// `outstanding` was below half of `buf_count`. Three in a
        /// row aborts the process — see the panic check in
        /// `readsTriage`. Cleared whenever the surfacing condition
        /// stops holding (so a one-time blip during boot doesn't
        /// trip the abort).
        recv_enobufs_low_outstanding_streak: u32 = 0,

        // Shared nghttp2 callbacks — one per H2 instantiation
        var ng_callbacks: ?*c.nghttp2_session_callbacks = null;
        var ng_client_callbacks: ?*c.nghttp2_session_callbacks = null;
        // Server session option for headers_first instances:
        // NO_AUTO_WINDOW_UPDATE, so inbound body flow control is the
        // explicit `nghttp2_session_consume` calls in
        // `onDataChunkRecvCb` / `requestBodyBuffer`. Created once,
        // only when the first headers_first session comes up.
        var ng_server_option: ?*c.nghttp2_option = null;

        // =============================================================
        // COLLECTIONS — single source of truth for the 27 collection
        // fields above. Drives init, registerCollection, deinit, and
        // the serverStreamColls / clientStreamColls helpers via
        // comptime loops, so adding a collection is a one-line spec
        // change rather than edits in 4–6 places.
        // =============================================================

        const Kind = enum {
            server_stream,
            server_read,
            server_conn,
            server_ws,
            client_connect,
            client_stream,
        };

        const CollSpec = struct {
            name: []const u8,
            Coll: type,
            kind: Kind,
            client_only: bool = false,
            // True for collections that hold an entity in some
            // intermediate state of the kind's pipeline (so the
            // serverStreamClose / clientStreamClose helpers iterate
            // them looking for the entity's current home). False for
            // terminal collections (response_out / client_response_out)
            // — those are the move target, not a search target.
            in_chain: bool = false,
        };

        const COLLECTIONS = [_]CollSpec{
            .{ .name = "request_out",          .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "request_receiving",    .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "request_buffering",    .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "response_in",          .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "response_out",         .Coll = StreamColl, .kind = .server_stream },
            .{ .name = "_response_sending",    .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "stream_response_in",   .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "stream_data_out",      .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "stream_data_in",       .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "stream_close_in",      .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "_stream_data_sending", .Coll = StreamColl, .kind = .server_stream, .in_chain = true },
            .{ .name = "ws_message_out",       .Coll = WsColl,     .kind = .server_ws },
            .{ .name = "ws_send_in",           .Coll = WsColl,     .kind = .server_ws },
            .{ .name = "_read_errors",         .Coll = ReadColl,   .kind = .server_read },
            .{ .name = "_read_init",           .Coll = ReadColl,   .kind = .server_read },
            .{ .name = "_read_active",         .Coll = ReadColl,   .kind = .server_read },
            .{ .name = "_read_handshake",      .Coll = ReadColl,   .kind = .server_read },
            .{ .name = "_conn_tls_handshake",  .Coll = ConnColl,   .kind = .server_conn },
            .{ .name = "_conn_active",         .Coll = ConnColl,   .kind = .server_conn },
            .{ .name = "client_connect_in",        .Coll = ClientConnectColl, .kind = .client_connect, .client_only = true },
            .{ .name = "client_connect_out",       .Coll = ClientConnectColl, .kind = .client_connect, .client_only = true },
            .{ .name = "client_connect_errors",    .Coll = ClientConnectColl, .kind = .client_connect, .client_only = true },
            .{ .name = "_client_connect_pending",  .Coll = ClientConnectColl, .kind = .client_connect, .client_only = true },
            .{ .name = "client_request_in",           .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
            .{ .name = "client_response_out",         .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true },
            .{ .name = "_client_request_sending",     .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
            .{ .name = "client_stream_request_in",    .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
            .{ .name = "client_stream_data_out",      .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
            .{ .name = "client_stream_data_in",       .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
            .{ .name = "client_stream_close_in",      .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
            .{ .name = "_client_stream_data_sending", .Coll = ClientStreamColl, .kind = .client_stream, .client_only = true, .in_chain = true },
        };

        const SERVER_STREAM_CHAIN: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            for (COLLECTIONS) |s| {
                if (s.kind == .server_stream and s.in_chain) names = names ++ &[_][]const u8{s.name};
            }
            break :blk names;
        };

        const CLIENT_STREAM_CHAIN: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            for (COLLECTIONS) |s| {
                if (s.kind == .client_stream and s.in_chain) names = names ++ &[_][]const u8{s.name};
            }
            break :blk names;
        };

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
        inline fn serverStreamColls(h2: *Self) [SERVER_STREAM_CHAIN.len]*StreamColl {
            var out: [SERVER_STREAM_CHAIN.len]*StreamColl = undefined;
            inline for (SERVER_STREAM_CHAIN, 0..) |name, i| {
                out[i] = &@field(h2, name);
            }
            return out;
        }

        /// All collections a client stream entity can be in between client_request_in and client_response_out.
        inline fn clientStreamColls(h2: *Self) [CLIENT_STREAM_CHAIN.len]*ClientStreamColl {
            var out: [CLIENT_STREAM_CHAIN.len]*ClientStreamColl = undefined;
            inline for (CLIENT_STREAM_CHAIN, 0..) |name, i| {
                out[i] = &@field(h2, name);
            }
            return out;
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

        /// Piece D (worker seam): routing captured from a WebSocket conn's `101`
        /// Upgrade request. The worker calls this with the `Session.entity` off a
        /// `ws_message_out` entity to resolve the tenant (`authority`) and handler
        /// module (`path`) for the held WS chain. Returns null when the entity is
        /// no longer a live ws-mode conn (closed / not upgraded). Borrowed slices
        /// — valid only while the conn lives; the worker dupes what it retains.
        /// `requestBodyBuffer` outcome — what the consumer should
        /// expect next for the entity it asked to classic-buffer.
        pub const BufferDecision = enum {
            /// Stream re-opened, h2 is accumulating; the entity moved
            /// to `request_buffering` and arrives in `request_out`
            /// body-complete at END_STREAM.
            buffering,
            /// The body had already fully arrived (END_STREAM raced
            /// the decision) — it was attached to the entity in
            /// place, in whatever collection holds it. Dispatch it.
            body_complete,
            /// The stream is gone (client reset / connection died).
            /// Nobody will ever complete this request — answer it.
            gone,
        };

        /// headers_first consumers: classic-buffering decision for an
        /// early-emitted request (in `request_receiving`, or already
        /// pulled into `request_out` for a headers-first dispatch
        /// probe). Re-opens the stream's flow-control window
        /// (repaying the held debt) and resumes accumulate-in-h2 —
        /// or, when END_STREAM already landed, attaches the
        /// accumulated body in place.
        pub fn requestBodyBuffer(h2: *Self, ent: Entity) BufferDecision {
            for ([_]*StreamColl{ &h2.request_receiving, &h2.request_out }) |coll| {
                if (h2.reg.isInCollection(ent, coll)) {
                    const sess = h2.reg.get(ent, coll, Session) catch return .gone;
                    const sid = h2.reg.get(ent, coll, StreamId) catch return .gone;

                    const conn_ptr = getConn(h2, sess.entity) orelse return .gone;
                    const ng_session = conn_ptr.ng_session orelse return .gone;
                    const stream: ?*Stream = @ptrCast(@alignCast(
                        c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                    ));
                    const s = stream orelse return .gone;

                    if (s.inbound_eof) {
                        h2.reg.set(ent, coll, ReqBody, takeBody(s)) catch return .gone;
                        return .body_complete;
                    }
                    s.body_mode = .buffer;
                    if (s.unconsumed > 0) {
                        _ = c.nghttp2_session_consume(ng_session, @intCast(sid.id), s.unconsumed);
                        s.unconsumed = 0;
                    }
                    h2.reg.move(ent, coll, &h2.request_buffering) catch return .gone;
                    return .buffering;
                }
            }
            return .gone;
        }

        pub fn wsConnRouting(h2: *Self, conn_entity: Entity) ?struct { authority: []const u8, path: []const u8 } {
            const cp = getConn(h2, conn_entity) orelse return null;
            const h1c = cp.h1 orelse return null;
            if (!h1c.ws_mode) return null;
            return .{ .authority = h1c.ws_authority, .path = h1c.ws_path };
        }

        /// FD resolver callback for io — searches h2's connection collections in addition to io's.
        fn resolveFdThunk(ctx: *anyopaque, entity: Entity) ?*rio.Fd {
            const h2: *Self = @ptrCast(@alignCast(ctx));
            return h2.reg.getAny(entity, h2.connColls(), rio.Fd) catch null;
        }

        /// Extra-conns callback for io's admission control. Returns the
        /// count of conn entities h2 holds outside `io.connections` —
        /// i.e. those that have already been promoted past the
        /// post-accept window. Combined with `io.connections.len` in
        /// `handleAccept` to estimate total in-flight conns.
        fn extraConnsThunk(ctx: *anyopaque) usize {
            const h2: *Self = @ptrCast(@alignCast(ctx));
            return h2._conn_tls_handshake.entitySlice().len + h2._conn_active.entitySlice().len;
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
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, stream_id),
            ));
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));

            if (!nctx.h2.h2_opts.headers_first) {
                if (stream == null) return 0;
                if (!stream.?.bodyAppend(data, len))
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                return 0;
            }

            // headers_first: auto window update is off, so every byte
            // of inbound DATA is flow-control debt until a consume
            // call repays it. What happens to the bytes follows the
            // stream's BodyMode.
            if (stream == null) {
                // DATA for a stream we no longer track (e.g. reset
                // after an early response). Nothing to deliver, but
                // the bytes still occupied the connection window —
                // release it or the whole connection wedges.
                _ = c.nghttp2_session_consume_connection(session, len);
                return 0;
            }
            const s = stream.?;
            switch (s.body_mode) {
                .auto, .buffer => {
                    // Classic accumulate path; consume immediately so
                    // the client keeps streaming (the WINDOW_UPDATE
                    // goes out on the next send drive).
                    if (!s.bodyAppend(data, len))
                        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                    _ = c.nghttp2_session_consume(session, stream_id, len);
                },
                .hold => {
                    // Window-hold: buffer but do NOT consume. The
                    // client is held at the door after at most one
                    // window's worth while the consumer decides.
                    if (!s.bodyAppend(data, len))
                        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                    s.unconsumed += @intCast(len);
                },
                .discard => {
                    _ = c.nghttp2_session_consume(session, stream_id, len);
                },
            }
            return 0;
        }

        /// Create a request entity in `coll` with the stream's
        /// finalized headers. Capacity is set at boot via the
        /// registry's `max_entities`; the per-tenant rate limiter is
        /// the gate that's supposed to keep entity counts inside that
        /// bound. If we still hit the cap here, that's a
        /// misconfiguration (rate limit too high or cap too low) —
        /// abort with a clear banner so the operator sees it instead
        /// of having streams silently rejected.
        fn emitRequestEntity(
            h2: *Self,
            coll: *StreamColl,
            s: *Stream,
            stream_id: i32,
            conn_entity: Entity,
        ) ?Entity {
            const req_entity = h2.reg.create(coll) catch |err| switch (err) {
                error.Full => {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        "\n================================================================\n" ++
                        "ROVE H2: request_out registry full — bump --rate-limit-* caps\n" ++
                        "  or increase max_entities. Rejecting silently would lose\n" ++
                        "  client requests with no operator signal; aborting.\n" ++
                        "================================================================\n",
                        .{},
                    ) catch buf[0..0];
                    _ = std.posix.write(2, msg) catch {};
                    std.process.abort();
                },
                else => return null,
            };

            var fields: ?[*]HeaderField = null;
            var count: u32 = 0;
            var buf_len: u32 = 0;
            const hdr_buf = s.hdrFinalize(&fields, &count, &buf_len);

            h2.reg.set(req_entity, coll, StreamId, .{ .id = @intCast(stream_id) }) catch return null;
            h2.reg.set(req_entity, coll, Session, .{ .entity = conn_entity }) catch return null;
            h2.reg.set(req_entity, coll, ReqHeaders, .{ .fields = fields, .count = count, ._buf = hdr_buf, ._buf_len = buf_len }) catch return null;
            return req_entity;
        }

        /// Take the stream's accumulated body buffer (shrunk to fit)
        /// out of the Stream, leaving it empty.
        fn takeBody(s: *Stream) ReqBody {
            const body_data = if (s.body_data) |p| blk: {
                if (s.body_len < s.body_cap) {
                    const shrunk = s.allocator.realloc(p[0..s.body_cap], s.body_len) catch p[0..s.body_cap];
                    break :blk @as(?[*]u8, shrunk.ptr);
                }
                break :blk @as(?[*]u8, p);
            } else null;
            const body: ReqBody = .{ .data = body_data, .len = s.body_len };
            s.body_data = null;
            s.body_len = 0;
            s.body_cap = 0;
            return body;
        }

        fn onFrameRecvCb(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            if (frame.*.hd.type != c.NGHTTP2_HEADERS and frame.*.hd.type != c.NGHTTP2_DATA)
                return 0;

            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null) return 0;
            const s = stream.?;
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
            const h2 = nctx.h2;
            const end_stream = frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;

            // headers_first early emission: a request whose HEADERS
            // frame lacks END_STREAM has body DATA still inbound.
            // Emit the entity NOW into `request_receiving` (empty
            // ReqBody) so the consumer can decide the disposition
            // from headers alone; the stream holds the flow-control
            // window shut (`.hold`) until it does.
            if (h2.h2_opts.headers_first and frame.*.hd.type == c.NGHTTP2_HEADERS and !end_stream and !s.emitted) {
                const req_entity = emitRequestEntity(h2, &h2.request_receiving, s, frame.*.hd.stream_id, nctx.conn_entity) orelse
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(req_entity, &h2.request_receiving, ReqBody, .{ .data = null, .len = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                s.emitted = true;
                s.ng_stream_id = frame.*.hd.stream_id;
                s.body_mode = .hold;
                s.entity = req_entity;
                return 0;
            }

            if (!end_stream) return 0;

            if (s.emitted) {
                // END_STREAM on an early-emitted stream: the body is
                // complete. Repay any held flow-control debt (the
                // backpressure question is moot once the last byte is
                // in — only the connection window still matters), then
                // attach the accumulated body and move the entity into
                // `request_out`, restoring its body-complete contract.
                if (s.unconsumed > 0) {
                    _ = c.nghttp2_session_consume(session, frame.*.hd.stream_id, s.unconsumed);
                    s.unconsumed = 0;
                }
                s.inbound_eof = true;
                if (s.body_mode == .discard) return 0;
                for ([_]*StreamColl{ &h2.request_receiving, &h2.request_buffering }) |coll| {
                    if (h2.reg.isInCollection(s.entity, coll)) {
                        h2.reg.set(s.entity, coll, ReqBody, takeBody(s)) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                        h2.reg.move(s.entity, coll, &h2.request_out) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                        return 0;
                    }
                }
                // The entity already left receiving/buffering — the
                // worker pulled it for a headers-first dispatch
                // decision (it's in request_out or parked on a held
                // chain), or an early response is in flight. The bytes
                // stay in this Stream's buffer under `inbound_eof`:
                // `requestBodyBuffer` attaches them in place on a
                // buffer decision, and a `blob.receive` sink drains
                // them directly.
                return 0;
            }

            // Classic path: entity is created at END_STREAM with the
            // full body attached.
            s.emitted = true;
            s.ng_stream_id = frame.*.hd.stream_id;
            const req_entity = emitRequestEntity(h2, &h2.request_out, s, frame.*.hd.stream_id, nctx.conn_entity) orelse
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            h2.reg.set(req_entity, &h2.request_out, ReqBody, takeBody(s)) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
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

            // headers_first: bytes held un-consumed on a stream that
            // dies still occupy the CONNECTION window (the stream
            // window dies with the stream). Repay it or every later
            // stream on this connection inherits a shrunken window.
            if (s.unconsumed > 0) {
                _ = c.nghttp2_session_consume_connection(session, s.unconsumed);
                s.unconsumed = 0;
            }

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
            if (self.h2_opts.headers_first) {
                if (ng_server_option == null) {
                    var opt: ?*c.nghttp2_option = null;
                    if (c.nghttp2_option_new(&opt) != 0) {
                        self.allocator.destroy(nctx);
                        return error.OutOfMemory;
                    }
                    c.nghttp2_option_set_no_auto_window_update(opt, 1);
                    ng_server_option = opt;
                }
                if (c.nghttp2_session_server_new2(&session, ng_callbacks, @ptrCast(nctx), ng_server_option) != 0) {
                    self.allocator.destroy(nctx);
                    return error.Nghttp2SessionCreateFailed;
                }
            } else if (c.nghttp2_session_server_new(&session, ng_callbacks, @ptrCast(nctx)) != 0) {
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
            self.io = io;
            self.h2_opts = h2_opts;
            self.reg = reg;
            self.allocator = allocator;
            self.recv_enobufs_total = 0;
            self.recv_enobufs_logged = false;
            self.recv_enobufs_last_logged_decade = 0;
            self.recv_enobufs_low_outstanding_streak = 0;

            // Init every collection field. Disabled (client_only with
            // has_client = false) collections have field type `void` —
            // assign `{}` so the field is defined.
            inline for (COLLECTIONS) |s| {
                if (s.client_only and !has_client) {
                    @field(self, s.name) = {};
                } else {
                    @field(self, s.name) = try s.Coll.init(allocator);
                }
            }

            inline for (COLLECTIONS) |s| {
                if (s.client_only and !has_client) continue;
                reg.registerCollection(&@field(self, s.name));
            }

            // Register FD resolver with io so that processWriteIn/processReadIn
            // can find connection Fds when h2 has moved them to _conn_active etc.
            self.io.setFdResolver(@ptrCast(self), &resolveFdThunk);
            // Admission control: io counts conns in `io.connections` +
            // whatever this callback returns. h2 holds promoted conns
            // in `_conn_tls_handshake` + `_conn_active`.
            self.io.setExtraConnsFn(@ptrCast(self), &extraConnsThunk);

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            inline for (COLLECTIONS) |s| {
                if (s.client_only and !has_client) continue;
                @field(self, s.name).deinit();
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
            try self.consumeWsSends();
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

            self.sweepOrphanedInbound();
            try self.reg.flush();

            try self.writesAccount();
            try self.reg.flush();
        }

        /// headers_first: a connection that died mid-upload takes its
        /// streams down without firing `onStreamCloseCb`
        /// (`nghttp2_session_del` frees streams silently), so an
        /// early-emitted request still waiting for its body would sit
        /// in `request_receiving` / `request_buffering` forever — the
        /// worker only answers entities it has been shown. Sweep
        /// entities whose connection is gone into `response_out` as
        /// closed streams.
        fn sweepOrphanedInbound(self: *Self) void {
            if (!self.h2_opts.headers_first) return;
            for ([_]*StreamColl{ &self.request_receiving, &self.request_buffering }) |coll| {
                const entities = coll.entitySlice();
                const sessions = coll.column(Session);
                for (entities, sessions) |ent, sess| {
                    if (getConn(self, sess.entity) == null) {
                        self.reg.set(ent, coll, H2IoResult, .{ .err = -1 }) catch {};
                        self.reg.move(ent, coll, &self.response_out) catch {};
                    }
                }
            }
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

                // HTTP/1.1 connection (Phase 2): serialize + write via the h1
                // codec instead of nghttp2 (encrypting if the conn is TLS).
                if (conn_ptr.h1 != null) {
                    self.http1WriteResponse(ent, conn_ptr, sess.entity, status, rh, rb, io_res) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, &self.response_in, &self.response_out);
                    };
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.response_in, &self.response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                self.flipInboundBodyToDiscard(ng_session, sid.id);

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

        /// headers_first: a response is going out while the request
        /// body may still be inbound (early 4xx from headers alone,
        /// worker error paths). Stop accumulating, drop what was
        /// buffered, and repay the held window so the client can
        /// drain or reset cleanly — remaining DATA frames are
        /// consumed-and-dropped by the `.discard` arm.
        fn flipInboundBodyToDiscard(self: *Self, ng_session: *c.nghttp2_session, stream_id: u32) void {
            if (!self.h2_opts.headers_first) return;
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(ng_session, @intCast(stream_id)),
            ));
            const s = stream orelse return;
            if (s.body_mode != .hold and s.body_mode != .buffer) return;
            s.body_mode = .discard;
            if (s.body_data) |p| {
                s.allocator.free(p[0..s.body_cap]);
                s.body_data = null;
                s.body_len = 0;
                s.body_cap = 0;
            }
            if (s.unconsumed > 0) {
                _ = c.nghttp2_session_consume(ng_session, @intCast(stream_id), s.unconsumed);
                s.unconsumed = 0;
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

                // h1 streaming: chunked head + park for chunks (Phase 6).
                if (conn_ptr.h1 != null) {
                    self.http1StreamBegin(ent, conn_ptr, sess.entity, status, rh, io_res) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                    };
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, &self.stream_response_in, &self.response_out);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                self.flipInboundBodyToDiscard(ng_session, sid.id);

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

                // h1 streaming: frame + write the chunk, return for the next.
                if (conn_ptr.h1 != null) {
                    self.http1StreamChunk(ent, conn_ptr, sess.entity, rb) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, &self.stream_data_in, &self.response_out);
                    };
                    continue;
                }

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

                // h1 streaming: write the zero-terminator + finalize (Phase 6).
                if (conn_ptr.h1 != null) {
                    self.http1StreamEnd(ent, conn_ptr, sess.entity, io_res) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, &self.stream_close_in, &self.response_out);
                    };
                    continue;
                }

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

            // Linux io_uring returns this when no buffer is available
            // from the registered buffer ring at recv time. Not a
            // connection-level failure — just back-pressure. Re-arm
            // the recv (via `read_in`) and the next attempt picks up
            // a buffer from the ring (recycled by `processReadIn`).
            const ENOBUFS: i32 = -105;

            var enobufs_this_pass: u32 = 0;
            for (entities, conn_ents, results) |ent, conn_ent, rr| {
                if (self.reg.isStale(conn_ent.entity) or self.reg.isMoving(conn_ent.entity)) {
                    try self.reg.move(ent, &self.io.read_results, &self._read_errors);
                    continue;
                }
                if (rr.result == ENOBUFS) {
                    // Transient: route back to read_in so processReadIn
                    // re-arms recv on this same entity. The buffer ring
                    // refills as other recvs complete + return their
                    // buffers via returnBufferToRing.
                    enobufs_this_pass += 1;
                    try self.reg.move(ent, &self.io.read_results, &self.io.read_in);
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

            // Loud surfacing of recv back-pressure. The pool size is
            // operator-controlled (`buf_count`); recurring ENOBUFS
            // means it's undersized for the workload. We log on first
            // occurrence (so the misconfiguration is visible right
            // away) and every 10k subsequent events (so the rate of
            // back-pressure is visible without flooding the log).
            if (enobufs_this_pass > 0) {
                self.recv_enobufs_total += enobufs_this_pass;

                // Conservation-law surfacing. Pair every "consumed"
                // with "returned"; if `outstanding` is well below
                // `buf_count` while ENOBUFS fires at a sustained
                // rate, the kernel and the ring's userspace
                // accounting disagree. That's the buffer-leak
                // signature the postmortem identified — and below,
                // it's also the abort condition.
                const consumed = self.io.recv_completions_with_data;
                const returned_drain = self.io.recv_buffers_returned;
                const returned_deinit = self.io.cleanup_ctx.recv_buffers_returned_via_deinit;
                const returned = returned_drain + returned_deinit;
                const outstanding = consumed -| returned;

                // INVARIANT (impossible by construction): outstanding
                // strictly less than buf_count. If we ever observe
                // outstanding > buf_count, our counters lie. This is
                // the loudest possible signal — abort, don't recover.
                if (outstanding > self.io.buf_count) {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        "\n================================================================\n" ++
                            "ROVE H2: recv buffer accounting broken — outstanding ({d}) > buf_count ({d}).\n" ++
                            "  consumed={d} returned_drain={d} returned_deinit={d}\n" ++
                            "  This is impossible by construction; counters or ring management is buggy.\n" ++
                            "================================================================\n",
                        .{ outstanding, self.io.buf_count, consumed, returned_drain, returned_deinit },
                    ) catch buf[0..0];
                    _ = std.posix.write(2, msg) catch {};
                    std.process.abort();
                }

                // INVARIANT (drained-but-busy): if ENOBUFS keeps
                // firing at a sustained rate while outstanding is
                // well below `buf_count`, the kernel says "ring is
                // empty" but our accounting says "ring is far from
                // empty." That's a buffer leak fingerprint —
                // buffers handed to userspace and lost via some
                // destruction path that bypasses the regular
                // return cycle (the bug fixed in commit 6ee648a
                // was the canonical case). Abort with the diag
                // numbers so the next investigator sees the
                // imbalance directly instead of having to chase
                // it down by hand.
                //
                // Threshold: hit it three consecutive surfacing
                // attempts to avoid one-off flukes during boot
                // transients. (Logging cadence is "first + every
                // 10k", so three surfacings means at least 20k
                // ENOBUFS events — sustained, not a blip.)
                if (outstanding * 2 < self.io.buf_count and self.recv_enobufs_total > 1_000) {
                    self.recv_enobufs_low_outstanding_streak += 1;
                    if (self.recv_enobufs_low_outstanding_streak >= 3) {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(
                            &buf,
                            "\n================================================================\n" ++
                                "ROVE H2: recv ENOBUFS with low outstanding — buffer leak suspected.\n" ++
                                "  enobufs={d} outstanding={d} buf_count={d}\n" ++
                                "  consumed={d} returned_drain={d} returned_deinit={d}\n" ++
                                "  Some destruction path is taking buffers out of circulation\n" ++
                                "  without returning them to the registered ring.\n" ++
                                "================================================================\n",
                            .{ self.recv_enobufs_total, outstanding, self.io.buf_count, consumed, returned_drain, returned_deinit },
                        ) catch buf[0..0];
                        _ = std.posix.write(2, msg) catch {};
                        std.process.abort();
                    }
                } else {
                    self.recv_enobufs_low_outstanding_streak = 0;
                }

                if (!self.recv_enobufs_logged or self.recv_enobufs_total / 10_000 != self.recv_enobufs_last_logged_decade) {
                    self.recv_enobufs_logged = true;
                    self.recv_enobufs_last_logged_decade = self.recv_enobufs_total / 10_000;
                    std.log.warn(
                        "rove-h2: recv ENOBUFS — io_uring registered buffer pool exhausted ({d} total, +{d} this pass; consumed={d} returned_drain={d} returned_deinit={d} outstanding={d} of {d}). If `outstanding` is far below `buf_count`, this is a leak — see /_system/metrics for the running balance.",
                        .{ self.recv_enobufs_total, enobufs_this_pass, consumed, returned_drain, returned_deinit, outstanding, self.io.buf_count },
                    );
                }
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
                        // ALPN decides the protocol (Phase 3): h2 is taken ONLY
                        // when explicitly negotiated. h2-over-TLS requires ALPN
                        // `h2` (RFC 7540 §3.4), so an h2 client always advertises
                        // it — which means `http/1.1` OR no ALPN at all can only
                        // be HTTP/1.1, and both route to the h1 codec. (HTTPS
                        // predates ALPN; minimal/older h1 clients omit it.) Both
                        // paths decrypt their first app-data flight from
                        // `decrypt_buf`.
                        if (!std.mem.eql(u8, tc.alpnProtocol(), "h2")) {
                            const h1c = Http1Conn.create(self.allocator) orelse {
                                try self.reg.destroy(conn_ent.entity);
                                try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                                continue;
                            };
                            conn_ptr.h1 = h1c;
                            if (feed_result.out_len > 0) {
                                self.http1Feed(conn_ptr, conn_ent.entity, decrypt_buf[0..feed_result.out_len]);
                            }
                            try self.reg.move(ent, &self._read_handshake, &self.io.read_in);
                            continue;
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
                // An ALPN-h1 conn (Phase 3) has no ng_session but is ready once
                // its Http1Conn is set — it must reach _conn_active so its reads
                // are processed and the idle GC can see it.
                if (conn_ptr.ng_session != null or conn_ptr.h1 != null) {
                    try self.reg.move(ent, &self._conn_tls_handshake, &self._conn_active);
                }
            }
        }

        // =============================================================
        // HTTP/1.1 ingress (docs/v2-edge-http1-ingress.md, Phase 2)
        // =============================================================

        /// A plaintext server connection's first read looked like HTTP/1.x.
        /// Tear down the eagerly-created (unused — no bytes fed) nghttp2
        /// session and swap in an `Http1Conn`. Returns null only on OOM.
        fn http1SwapIn(self: *Self, conn_ptr: *Conn) ?*Http1Conn {
            if (conn_ptr.ng_session) |session| {
                c.nghttp2_session_del(session);
                conn_ptr.ng_session = null;
            }
            if (conn_ptr.ng_ctx) |ctx| {
                if (conn_ptr.ng_ctx_destroy) |destroy_fn| destroy_fn(ctx);
                conn_ptr.ng_ctx = null;
                conn_ptr.ng_ctx_destroy = null;
            }
            const h1c = Http1Conn.create(self.allocator) orelse return null;
            conn_ptr.h1 = h1c;
            return h1c;
        }

        /// Append freshly-read plaintext bytes to the h1 buffer and drive the
        /// parser. Any failure surfaces as an error response + close rather
        /// than a silent drop.
        fn http1Feed(self: *Self, conn_ptr: *Conn, conn_entity: Entity, bytes: []const u8) void {
            const h1c = conn_ptr.h1.?;
            if (h1c.closing) return;
            h1c.buf.appendSlice(self.allocator, bytes) catch {
                if (h1c.ws_mode)
                    self.wsClose(conn_ptr, conn_entity, ws.CloseCode.internal_error)
                else
                    self.http1ErrorClose(conn_ptr, conn_entity, 500);
                return;
            };
            // Once upgraded, `buf` carries RFC 6455 frames, not HTTP requests.
            if (h1c.ws_mode) self.wsDrive(conn_ptr, conn_entity) else self.http1Drive(conn_ptr, conn_entity);
        }

        /// Parse as much of the buffer as possible, emitting at most one request
        /// (no pipelining). Called after a read and after a keep-alive response
        /// drains (to pick up a coalesced next request).
        fn http1Drive(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            if (h1c.in_flight or h1c.closing) return;

            var store: [http1.MAX_HEADERS]http1.Header = undefined;
            const res = http1.parseHead(h1c.buf.items, &store) catch |err| {
                const status: u16 = switch (err) {
                    error.HeadTooLarge => 431,
                    error.Malformed => 400,
                    // An h2 preface on an h1 conn should be impossible (we sniff
                    // before swapping in), but refuse it loudly rather than hang.
                    error.NotHttp1 => 400,
                };
                self.http1ErrorClose(conn_ptr, conn_entity, status);
                return;
            };

            const head = switch (res) {
                .need_more => return,
                .head => |h| h,
            };

            // HTTP/1.1 requires Host; without it there's no `:authority`.
            if (head.host == null) {
                self.http1ErrorClose(conn_ptr, conn_entity, 400);
                return;
            }

            // WebSocket Upgrade (piece A): a GET carrying `Upgrade: websocket` +
            // `Connection: upgrade` + `Sec-WebSocket-Key`. The `101` switches the
            // connection out of the HTTP request/response model; `head.head_len`
            // is consumed and any trailing bytes are early WS frames.
            if (wsIsUpgrade(head)) {
                self.wsHandshake(conn_ptr, conn_entity, head);
                return;
            }

            // Frame the body: chunked (Transfer-Encoding) decodes incrementally;
            // otherwise Content-Length (absent ⇒ no body). Either way `body` is
            // the assembled payload and `total` the bytes consumed from `buf`.
            var body: []const u8 = "";
            var total: usize = head.head_len;
            if (head.chunked) {
                const chunk_input = h1c.buf.items[head.head_len..];
                const r = http1.decodeChunked(
                    chunk_input,
                    h1c.chunk_pos,
                    &h1c.chunk_body,
                    self.allocator,
                    Http1Conn.MAX_BODY_BYTES,
                );
                h1c.chunk_pos = r.consumed; // resume offset for the next read
                switch (r.status) {
                    .need_more => {
                        self.http1MaybeContinue(conn_ptr, conn_entity, head);
                        return;
                    },
                    .malformed => {
                        self.http1ErrorClose(conn_ptr, conn_entity, 400);
                        return;
                    },
                    .too_large => {
                        self.http1ErrorClose(conn_ptr, conn_entity, 413);
                        return;
                    },
                    .complete => {},
                }
                body = h1c.chunk_body.items;
                total = head.head_len + r.consumed;
            } else {
                const body_len = head.content_length orelse 0;
                if (body_len > Http1Conn.MAX_BODY_BYTES) {
                    self.http1ErrorClose(conn_ptr, conn_entity, 413);
                    return;
                }
                total = head.head_len + body_len;
                if (h1c.buf.items.len < total) {
                    self.http1MaybeContinue(conn_ptr, conn_entity, head);
                    return; // body still arriving
                }
                body = h1c.buf.items[head.head_len..total];
            }

            // `:scheme` reflects the transport: TLS-terminated h1 is https.
            const scheme: []const u8 = if (conn_ptr.tls_conn != null) "https" else "http";
            self.http1EmitRequest(conn_entity, head, body, scheme) catch {
                self.http1ErrorClose(conn_ptr, conn_entity, 503);
                return;
            };
            h1c.keep_alive = head.keep_alive;
            h1c.in_flight = true;
            // Reset per-request framing state for the next keep-alive request.
            h1c.chunk_pos = 0;
            h1c.chunk_body.clearRetainingCapacity();
            h1c.continue_sent = false;

            // Drop the consumed request from the front of the buffer; the body
            // bytes are now owned by the request entity. Any trailing bytes
            // (a coalesced next request) stay buffered for after the response.
            const leftover = h1c.buf.items.len - total;
            if (leftover > 0) {
                std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[total..]);
            }
            h1c.buf.shrinkRetainingCapacity(leftover);
        }

        /// Send a one-shot `100 Continue` for an `Expect: 100-continue` request
        /// whose body hasn't fully arrived, so the client proceeds. Guarded by
        /// `continue_sent` so repeated reads don't re-emit it.
        fn http1MaybeContinue(self: *Self, conn_ptr: *Conn, conn_entity: Entity, head: http1.Head) void {
            const h1c = conn_ptr.h1.?;
            if (!head.expect_continue or h1c.continue_sent) return;
            h1c.continue_sent = true;
            const msg = self.allocator.dupe(u8, "HTTP/1.1 100 Continue\r\n\r\n") catch return;
            self.http1Send(conn_ptr, conn_entity, msg);
        }

        /// Build a `request_out` entity from a parsed h1 head + body, synthesizing
        /// the h2-style pseudo-headers so all downstream routing/dispatch is
        /// protocol-agnostic. `StreamId` is the synthetic 1 (one request/conn).
        fn http1EmitRequest(self: *Self, conn_entity: Entity, head: http1.Head, body: []const u8, scheme: []const u8) !void {
            const req_entity = try self.reg.create(&self.request_out);
            errdefer self.reg.destroy(req_entity) catch {};

            try self.reg.set(req_entity, &self.request_out, StreamId, .{ .id = 1 });
            try self.reg.set(req_entity, &self.request_out, Session, .{ .entity = conn_entity });

            const rh = try self.http1BuildReqHeaders(head, scheme);
            try self.reg.set(req_entity, &self.request_out, ReqHeaders, rh);

            var body_data: ?[*]u8 = null;
            if (body.len > 0) {
                const copy = try self.allocator.dupe(u8, body);
                body_data = copy.ptr;
            }
            try self.reg.set(req_entity, &self.request_out, ReqBody, .{ .data = body_data, .len = @intCast(body.len) });
        }

        /// True for HTTP/1 connection-specific (hop-by-hop) headers that must not
        /// cross into the h2-style representation, plus `Host` (→ `:authority`).
        fn http1IsHopByHop(name: []const u8) bool {
            const drop = [_][]const u8{
                "host",          "connection",   "keep-alive",
                "transfer-encoding", "upgrade",  "proxy-connection",
                // `Expect: 100-continue` is satisfied at the edge (we answer the
                // 100); the DP gets the fully-decoded body, so it must not leak.
                "expect",
            };
            for (drop) |d| if (std.ascii.eqlIgnoreCase(name, d)) return true;
            return false;
        }

        /// Pack a parsed h1 head into an `h2.ReqHeaders` — four synthesized
        /// pseudo-headers followed by the request's end-to-end headers
        /// (names lowercased to match h2/handler lookups). One combined buffer
        /// holds the field array + name/value bytes, freed by `ReqHeaders.deinit`.
        fn http1BuildReqHeaders(self: *Self, head: http1.Head, scheme: []const u8) !ReqHeaders {
            const Pair = struct { name: []const u8, value: []const u8 };
            const pseudo = [_]Pair{
                .{ .name = ":method", .value = head.method },
                .{ .name = ":path", .value = head.target },
                .{ .name = ":scheme", .value = scheme },
                .{ .name = ":authority", .value = head.host orelse "" },
            };

            var n: usize = pseudo.len;
            var strbytes: usize = 0;
            for (pseudo) |p| strbytes += p.name.len + p.value.len;
            for (head.headers) |hh| {
                if (http1IsHopByHop(hh.name)) continue;
                n += 1;
                strbytes += hh.name.len + hh.value.len;
            }

            const fields_size = n * @sizeOf(HeaderField);
            const total = fields_size + strbytes;
            const buf = try self.allocator.alloc(u8, total);
            const fields: [*]HeaderField = @ptrCast(@alignCast(buf.ptr));
            const strbase = buf.ptr + fields_size;

            var soff: usize = 0;
            var fi: usize = 0;
            const writeField = struct {
                fn go(f: [*]HeaderField, sb: [*]u8, off: *usize, idx: *usize, name: []const u8, value: []const u8, lower: bool) void {
                    const noff = off.*;
                    @memcpy(sb[noff .. noff + name.len], name);
                    if (lower) for (sb[noff .. noff + name.len]) |*ch| {
                        ch.* = std.ascii.toLower(ch.*);
                    };
                    off.* += name.len;
                    const voff = off.*;
                    @memcpy(sb[voff .. voff + value.len], value);
                    off.* += value.len;
                    f[idx.*] = .{
                        .name = sb + noff,
                        .name_len = @intCast(name.len),
                        .value = sb + voff,
                        .value_len = @intCast(value.len),
                    };
                    idx.* += 1;
                }
            }.go;

            for (pseudo) |p| writeField(fields, strbase, &soff, &fi, p.name, p.value, false);
            for (head.headers) |hh| {
                if (http1IsHopByHop(hh.name)) continue;
                writeField(fields, strbase, &soff, &fi, hh.name, hh.value, true);
            }

            return .{ .fields = fields, .count = @intCast(n), ._buf = buf.ptr, ._buf_len = @intCast(total) };
        }

        /// Encrypt (when the connection is TLS) and queue an owned plaintext
        /// buffer for write. Takes ownership of `data`: frees it on any path.
        /// The one place h1 egress bytes cross the TLS boundary, so both the
        /// plaintext and ALPN-h1 paths share identical framing.
        fn http1Send(self: *Self, conn_ptr: *Conn, conn_entity: Entity, data: []u8) void {
            if (conn_ptr.tls_conn) |tc| {
                defer self.allocator.free(data);
                const cipher = tc.encrypt(data, self.allocator) catch return;
                if (cipher.len == 0) return;
                self.submitWrite(conn_entity, cipher) catch self.allocator.free(cipher);
            } else {
                self.submitWrite(conn_entity, data) catch self.allocator.free(data);
            }
        }

        /// Serialize a minimal error response (empty body) and close the
        /// connection — used for malformed/unsupported/over-cap requests.
        fn http1ErrorClose(self: *Self, conn_ptr: *Conn, conn_entity: Entity, status: u16) void {
            const h1c = conn_ptr.h1.?;
            if (h1c.closing) return;
            h1c.closing = true;
            h1c.keep_alive = false;
            var out: std.ArrayList(u8) = .empty;
            http1.writeResponse(&out, self.allocator, status, &.{}, "", false) catch {
                out.deinit(self.allocator);
                return;
            };
            const data = out.toOwnedSlice(self.allocator) catch {
                out.deinit(self.allocator);
                return;
            };
            self.http1Send(conn_ptr, conn_entity, data);
        }

        /// Serialize a deployed-handler response over h1 and queue the write.
        /// Honors keep-alive (drive the next buffered request) vs close.
        fn http1WriteResponse(
            self: *Self,
            ent: Entity,
            conn_ptr: *Conn,
            conn_entity: Entity,
            status: Status,
            rh: RespHeaders,
            rb: RespBody,
            io_res: *H2IoResult,
        ) !void {
            const h1c = conn_ptr.h1.?;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);

            // Translate h2 RespHeaders → h1 RespHeader slices. `:status` and the
            // framing headers are owned by the serializer, so skip pseudo-headers.
            var hdr_store: [http1.MAX_HEADERS]http1.RespHeader = undefined;
            var hn: usize = 0;
            if (rh.fields) |rfields| {
                for (rfields[0..rh.count]) |f| {
                    const name = f.name[0..f.name_len];
                    if (name.len > 0 and name[0] == ':') continue; // pseudo
                    if (hn >= hdr_store.len) break;
                    hdr_store[hn] = .{ .name = name, .value = f.value[0..f.value_len] };
                    hn += 1;
                }
            }

            const body = if (rb.data) |d| d[0..rb.len] else "";
            try http1.writeResponse(&out, self.allocator, status.code, hdr_store[0..hn], body, h1c.keep_alive);
            const data = try out.toOwnedSlice(self.allocator);
            self.http1Send(conn_ptr, conn_entity, data);

            io_res.err = 0;
            try self.reg.move(ent, &self.response_in, &self.response_out);

            if (h1c.keep_alive) {
                h1c.in_flight = false;
                self.http1Drive(conn_ptr, conn_entity);
            } else {
                // Connection: close — let the idle-timeout GC reap once the write
                // drains (same proven path as the old 426 reply).
                h1c.closing = true;
            }
        }

        // ── HTTP/1.1 chunked streaming (SSE / ReadableStream) ────────────────
        //
        // The worker's streaming pipeline (`stream_response_in` → repeated
        // `stream_data_in` → `stream_close_in`) is protocol-agnostic; these three
        // forks make it emit HTTP/1.1 chunked framing instead of nghttp2 DATA
        // frames. Each chunk is serialized and written as it arrives — no data
        // provider, no `resume_data`, no `_stream_data_sending` detour.

        /// Begin a streaming response: write the chunked head, mark the conn
        /// streaming, and park the entity in `stream_data_out` for the worker to
        /// push chunks onto.
        fn http1StreamBegin(self: *Self, ent: Entity, conn_ptr: *Conn, conn_entity: Entity, status: Status, rh: RespHeaders, io_res: *H2IoResult) !void {
            const h1c = conn_ptr.h1.?;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);

            var hdr_store: [http1.MAX_HEADERS]http1.RespHeader = undefined;
            var hn: usize = 0;
            if (rh.fields) |rfields| {
                for (rfields[0..rh.count]) |f| {
                    const name = f.name[0..f.name_len];
                    if (name.len > 0 and name[0] == ':') continue; // pseudo
                    if (hn >= hdr_store.len) break;
                    hdr_store[hn] = .{ .name = name, .value = f.value[0..f.value_len] };
                    hn += 1;
                }
            }

            try http1.writeStreamHead(&out, self.allocator, status.code, hdr_store[0..hn]);
            const data = try out.toOwnedSlice(self.allocator);
            self.http1Send(conn_ptr, conn_entity, data);
            h1c.streaming = true;
            io_res.err = 0;
            // Backpressure: hold the entity until the head write drains, so the
            // worker can't push the first chunk until the head is on the wire
            // (keeps the single-write-in-flight invariant from the very start).
            h1c.sending_entity = ent;
            try self.reg.move(ent, &self.stream_response_in, &self._stream_data_sending);
        }

        /// Write one body piece as a chunk, then return the entity to
        /// `stream_data_out` so the worker can push the next. The worker-owned
        /// `rb.data` is copied into the framed buffer, then freed + nulled (the
        /// same ownership transfer the h2 path does onto its `Stream`).
        fn http1StreamChunk(self: *Self, ent: Entity, conn_ptr: *Conn, conn_entity: Entity, rb: *RespBody) !void {
            const h1c = conn_ptr.h1.?;
            if (rb.data) |d| {
                if (rb.len > 0) {
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(self.allocator);
                    try http1.writeChunk(&out, self.allocator, d[0..rb.len]);
                    const data = try out.toOwnedSlice(self.allocator);
                    self.http1Send(conn_ptr, conn_entity, data);
                    self.allocator.free(d[0..rb.len]);
                    rb.data = null;
                    rb.len = 0;
                    // Backpressure: hold the entity until this chunk's write
                    // drains; `writesAccount` releases it back to stream_data_out.
                    h1c.sending_entity = ent;
                    try self.reg.move(ent, &self.stream_data_in, &self._stream_data_sending);
                    return;
                }
                self.allocator.free(d[0..rb.len]);
                rb.data = null;
                rb.len = 0;
            }
            // Empty piece — nothing to write, so no backpressure: return the
            // entity immediately for the next push.
            try self.reg.move(ent, &self.stream_data_in, &self.stream_data_out);
        }

        /// End a streaming response: write the zero-terminator, then finalize the
        /// entity and honor keep-alive (chunked delimits the body, so the conn
        /// can serve the next request) vs close.
        fn http1StreamEnd(self: *Self, ent: Entity, conn_ptr: *Conn, conn_entity: Entity, io_res: *H2IoResult) !void {
            const h1c = conn_ptr.h1.?;
            const term = try self.allocator.dupe(u8, http1.CHUNK_TERMINATOR);
            self.http1Send(conn_ptr, conn_entity, term);
            h1c.streaming = false;
            io_res.err = 0;
            try self.reg.move(ent, &self.stream_close_in, &self.response_out);
            if (h1c.keep_alive) {
                h1c.in_flight = false;
                self.http1Drive(conn_ptr, conn_entity);
            } else {
                h1c.closing = true;
            }
        }

        // ── WebSocket transport (docs/websocket-plan.md §4.5/§4.6) ───────────
        //
        // Pieces A (101 handshake), C (connection mode + inbound frames), and the
        // h2-side of E (outbound framing). The pure RFC 6455 codec lives in
        // `ws.zig` (piece B); these functions wire it into the connection /
        // entity plumbing. Inbound complete messages surface on `ws_message_out`;
        // outbound frames are queued on `ws_send_in`. Single-tenant / single-node
        // baseline, batch-of-1 durability (the worker seam is piece D).

        /// True for a well-formed WebSocket Upgrade request: a `GET` carrying
        /// `Upgrade: websocket`, an `Upgrade` token in `Connection:`, and a
        /// non-empty `Sec-WebSocket-Key` (RFC 6455 §4.1). Header names are
        /// case-insensitive and the tokens may sit in a comma list, so match
        /// case-insensitively on substrings.
        fn wsIsUpgrade(head: http1.Head) bool {
            if (!std.mem.eql(u8, head.method, "GET")) return false;
            var has_upgrade = false;
            var has_conn_upgrade = false;
            var has_key = false;
            for (head.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) {
                    if (std.ascii.indexOfIgnoreCase(h.value, "websocket") != null) has_upgrade = true;
                } else if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
                    if (std.ascii.indexOfIgnoreCase(h.value, "upgrade") != null) has_conn_upgrade = true;
                } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-key")) {
                    if (h.value.len > 0) has_key = true;
                }
            }
            return has_upgrade and has_conn_upgrade and has_key;
        }

        /// Piece A: complete the `101 Switching Protocols` handshake and switch
        /// the connection into WebSocket mode. The `101` is queued through the WS
        /// outbound path so it precedes — in wire order — any frame the worker
        /// pushes next; trailing bytes already in `buf` (frames the client sent
        /// coalesced with the handshake) are drained by the closing `wsDrive`.
        fn wsHandshake(self: *Self, conn_ptr: *Conn, conn_entity: Entity, head: http1.Head) void {
            const h1c = conn_ptr.h1.?;

            var key: []const u8 = "";
            for (head.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-key")) key = h.value;
            }
            var accept_buf: [ws.ACCEPT_LEN]u8 = undefined;
            const accept = ws.acceptKey(key, &accept_buf);

            // Piece D: capture the Upgrade request's routing (Host → authority,
            // request-target → path) before the head is dropped below — the
            // worker resolves the tenant + handler module from these on the
            // first inbound frame (the handshake completes here without it).
            // OOM duping either fails the connection, same as the response
            // appends below.
            h1c.ws_authority = self.allocator.dupe(u8, head.host orelse "") catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };
            h1c.ws_path = self.allocator.dupe(u8, head.target) catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };

            // Drop the consumed request head; what's left in `buf` is the start of
            // the frame stream. Do this before flipping `ws_mode` so a parse never
            // sees the HTTP head as frame bytes.
            const head_len = head.head_len;
            const leftover = h1c.buf.items.len - head_len;
            if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[head_len..]);
            h1c.buf.shrinkRetainingCapacity(leftover);

            h1c.ws_mode = true;
            h1c.in_flight = false;

            var resp: std.ArrayList(u8) = .empty;
            defer resp.deinit(self.allocator);
            resp.appendSlice(self.allocator, "HTTP/1.1 101 Switching Protocols\r\n") catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };
            resp.appendSlice(self.allocator, "Upgrade: websocket\r\nConnection: Upgrade\r\n") catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };
            resp.appendSlice(self.allocator, "Sec-WebSocket-Accept: ") catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };
            resp.appendSlice(self.allocator, accept) catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };
            resp.appendSlice(self.allocator, "\r\n\r\n") catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };

            h1c.ws_out.appendSlice(self.allocator, resp.items) catch {
                self.reg.destroy(conn_entity) catch {};
                return;
            };
            self.wsFlush(conn_ptr, conn_entity);

            // Process any frames that arrived in the same read as the handshake.
            self.wsDrive(conn_ptr, conn_entity);
        }

        /// Piece C: parse as many complete RFC 6455 frames as `buf` holds,
        /// dispatching each. Control frames are handled inline (auto-pong, Close
        /// echo); data frames are reassembled and surfaced on `ws_message_out`. A
        /// protocol/size error or OOM fails the connection with a Close frame.
        fn wsDrive(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            if (h1c.ws_closing) return;

            var pos: usize = 0;
            while (true) {
                const r = ws.parseFrame(h1c.buf.items[pos..], Http1Conn.MAX_WS_MESSAGE) catch |err| {
                    const code: u16 = switch (err) {
                        error.ProtocolError => ws.CloseCode.protocol_error,
                        error.TooLarge => ws.CloseCode.message_too_big,
                    };
                    self.wsClose(conn_ptr, conn_entity, code);
                    break;
                };
                const frame = switch (r) {
                    .need_more => break,
                    .frame => |f| f,
                };
                self.wsHandleFrame(conn_ptr, conn_entity, frame) catch |err| {
                    const code: u16 = if (err == error.WsProtocol)
                        ws.CloseCode.protocol_error
                    else
                        ws.CloseCode.internal_error;
                    self.wsClose(conn_ptr, conn_entity, code);
                    break;
                };
                pos += frame.consumed;
                if (h1c.ws_closing) break;
            }

            // Compact the consumed prefix out of `buf` (the unconsumed tail is the
            // start of the next, still-incomplete frame).
            if (pos > 0) {
                const leftover = h1c.buf.items.len - pos;
                if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[pos..]);
                h1c.buf.shrinkRetainingCapacity(leftover);
            }
            self.wsFlush(conn_ptr, conn_entity);
        }

        /// Dispatch one parsed inbound frame. `frame.payload` borrows the
        /// (unmasked-in-place) connection buffer, so anything retained past this
        /// call is copied (into `ws_msg` or a `ws_message_out` entity).
        fn wsHandleFrame(self: *Self, conn_ptr: *Conn, conn_entity: Entity, frame: ws.Frame) !void {
            const h1c = conn_ptr.h1.?;
            switch (frame.opcode) {
                // Auto-pong: bounce the application data back; the handler never
                // sees ping/pong (websocket-plan §5).
                .ping => try ws.writeFrame(&h1c.ws_out, self.allocator, .pong, frame.payload),
                .pong => {},
                .close => {
                    // Surface the disconnect (piece D → `onDisconnect`) then echo a
                    // Close and tear down once it drains.
                    try self.wsEmitMessage(conn_entity, @intFromEnum(ws.Opcode.close), "");
                    if (!h1c.ws_closing) {
                        ws.writeClose(&h1c.ws_out, self.allocator, ws.CloseCode.normal, "") catch {};
                        h1c.ws_closing = true;
                    }
                },
                .text, .binary => {
                    // A new data opener while a fragmented message is open is a
                    // protocol error (§5.4).
                    if (h1c.ws_msg_opcode != 0) return error.WsProtocol;
                    if (frame.fin) {
                        try self.wsEmitMessage(conn_entity, @intFromEnum(frame.opcode), frame.payload);
                    } else {
                        h1c.ws_msg.clearRetainingCapacity();
                        try h1c.ws_msg.appendSlice(self.allocator, frame.payload);
                        h1c.ws_msg_opcode = @intFromEnum(frame.opcode);
                    }
                },
                .continuation => {
                    // A continuation with no opener is a protocol error (§5.4).
                    if (h1c.ws_msg_opcode == 0) return error.WsProtocol;
                    if (h1c.ws_msg.items.len + frame.payload.len > Http1Conn.MAX_WS_MESSAGE)
                        return error.WsProtocol;
                    try h1c.ws_msg.appendSlice(self.allocator, frame.payload);
                    if (frame.fin) {
                        try self.wsEmitMessage(conn_entity, h1c.ws_msg_opcode, h1c.ws_msg.items);
                        h1c.ws_msg.clearRetainingCapacity();
                        h1c.ws_msg_opcode = 0;
                    }
                },
                _ => return error.WsProtocol,
            }
        }

        /// Emit a completed inbound message (or a client-close signal, opcode 8)
        /// onto `ws_message_out` for the consumer. `payload` is copied into an
        /// allocator-owned `ReqBody` the entity's destroy frees.
        fn wsEmitMessage(self: *Self, conn_entity: Entity, opcode: u8, payload: []const u8) !void {
            const ent = try self.reg.create(&self.ws_message_out);
            errdefer self.reg.destroy(ent) catch {};
            try self.reg.set(ent, &self.ws_message_out, Session, .{ .entity = conn_entity });
            try self.reg.set(ent, &self.ws_message_out, WsMeta, .{ .opcode = opcode });
            var data: ?[*]u8 = null;
            if (payload.len > 0) {
                const copy = try self.allocator.dupe(u8, payload);
                data = copy.ptr;
            }
            try self.reg.set(ent, &self.ws_message_out, ReqBody, .{ .data = data, .len = @intCast(payload.len) });
        }

        /// Queue a Close frame and begin teardown; the connection is destroyed by
        /// `wsFlush` once the Close (and anything ahead of it) drains.
        fn wsClose(self: *Self, conn_ptr: *Conn, conn_entity: Entity, code: u16) void {
            const h1c = conn_ptr.h1.?;
            if (!h1c.ws_closing) {
                ws.writeClose(&h1c.ws_out, self.allocator, code, "") catch {};
                h1c.ws_closing = true;
            }
            self.wsFlush(conn_ptr, conn_entity);
        }

        /// Flush the per-connection outbound byte queue with exactly one socket
        /// write in flight (`ws_write_inflight`): preserves frame order on the
        /// wire and coalesces a burst into one write. The completion lands in
        /// `writesAccount`, which clears the flag and re-flushes. When a closing
        /// connection has fully drained, reap it.
        fn wsFlush(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            if (h1c.ws_write_inflight) return;
            if (h1c.ws_out.items.len == 0) {
                if (h1c.ws_closing) self.reg.destroy(conn_entity) catch {};
                return;
            }
            const data = h1c.ws_out.toOwnedSlice(self.allocator) catch return;
            h1c.ws_write_inflight = true;
            self.http1Send(conn_ptr, conn_entity, data);
        }

        /// Piece E (h2 side): drain `ws_send_in` — frames the consumer queued via
        /// `stream.write` — RFC-6455-framing each by opcode onto the connection's
        /// outbound queue. A `close` opcode requests a clean teardown. The entity
        /// is one-shot (destroyed here); backpressure lives on `ws_out`.
        fn consumeWsSends(self: *Self) !void {
            const entities = self.ws_send_in.entitySlice();
            const sessions = self.ws_send_in.column(Session);
            const metas = self.ws_send_in.column(WsMeta);
            const bodies = self.ws_send_in.column(ReqBody);

            for (entities, sessions, metas, bodies) |ent, sess, meta, *body| {
                if (self.reg.isStale(sess.entity)) {
                    try self.reg.destroy(ent);
                    continue;
                }
                const conn_ptr = getConn(self, sess.entity) orelse {
                    try self.reg.destroy(ent);
                    continue;
                };
                const h1c = conn_ptr.h1 orelse {
                    try self.reg.destroy(ent);
                    continue;
                };
                if (!h1c.ws_mode or h1c.ws_closing) {
                    try self.reg.destroy(ent);
                    continue;
                }

                const opcode: ws.Opcode = @enumFromInt(@as(u4, @truncate(meta.opcode)));
                const payload = if (body.data) |d| d[0..body.len] else "";
                if (opcode == .close) {
                    self.wsClose(conn_ptr, sess.entity, ws.CloseCode.normal);
                } else {
                    ws.writeFrame(&h1c.ws_out, self.allocator, opcode, payload) catch {
                        try self.reg.destroy(ent);
                        continue;
                    };
                    self.wsFlush(conn_ptr, sess.entity);
                }
                try self.reg.destroy(ent);
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

        /// True if `bytes` look like the start of an HTTP/1.x request
        /// rather than the h2 connection preface. The h2 preface is
        /// `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, so `PRI ` at byte 0 is
        /// h2; any other ASCII method token followed by space is HTTP/1.x.
        /// Only meant to run on the very first read of a connection.
        fn looksLikeHttp1Request(bytes: []const u8) bool {
            if (bytes.len < 4) return false;
            if (std.mem.startsWith(u8, bytes, "PRI ")) return false;
            const methods = [_][]const u8{
                "GET ",   "POST ", "HEAD ", "PUT ", "DELE", "OPTI",
                "PATCH ", "TRAC", "CONN",
            };
            for (methods) |m| {
                if (std.mem.startsWith(u8, bytes, m)) return true;
            }
            return false;
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

                // HTTP/1.1 connection: feed bytes to the h1 codec instead of
                // nghttp2. Runs before the ng_session guard since an h1 conn has
                // no session. TLS-terminated h1 (ALPN, Phase 3) decrypts first;
                // plaintext (Phase 2) feeds raw.
                if (conn_ptr.h1 != null) {
                    if (rr.data) |data_ptr| {
                        const data_len: usize = @intCast(rr.result);
                        if (data_len > 0) {
                            if (conn_ptr.tls_conn) |tc| {
                                var decrypt_buf: [65536]u8 = undefined;
                                const fr = tc.feed(data_ptr[0..data_len], &decrypt_buf);
                                if (fr.result == .err) {
                                    try self.reg.destroy(conn_ent.entity);
                                    try self.reg.move(ent, &self._read_active, &self.io.read_in);
                                    continue;
                                }
                                if (fr.out_len > 0) self.http1Feed(conn_ptr, conn_ent.entity, decrypt_buf[0..fr.out_len]);
                            } else {
                                self.http1Feed(conn_ptr, conn_ent.entity, data_ptr[0..data_len]);
                            }
                            conn_ptr.last_active_ns = monotonicNs();
                        }
                    }
                    try self.reg.move(ent, &self._read_active, &self.io.read_in);
                    continue;
                }

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
                        // Plaintext server connections: sniff for an HTTP/1.x
                        // request on the very first read. nghttp2 would reject
                        // non-h2 bytes and we'd close silently; instead route
                        // the connection to the h1 codec (Phase 2,
                        // docs/v2-edge-http1-ingress.md). Only the first read
                        // can be a non-h2 preface, so the sniff is gated on
                        // first_read_seen.
                        if (conn_ptr.direction == .server and !conn_ptr.first_read_seen and
                            data_len > 0 and looksLikeHttp1Request(data_ptr[0..data_len]))
                        {
                            conn_ptr.first_read_seen = true;
                            _ = self.http1SwapIn(conn_ptr) orelse {
                                try self.reg.destroy(conn_ent.entity);
                                try self.reg.move(ent, &self._read_active, &self.io.read_in);
                                continue;
                            };
                            self.http1Feed(conn_ptr, conn_ent.entity, data_ptr[0..data_len]);
                            conn_ptr.last_active_ns = monotonicNs();
                            try self.reg.move(ent, &self._read_active, &self.io.read_in);
                            continue;
                        }
                        conn_ptr.first_read_seen = true;
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
                const failed = !self.reg.isStale(conn_ent.entity) and io_res.err != 0;

                // h1 streaming backpressure: a completed head/chunk write
                // releases the parked stream entity. There's at most one write
                // in flight per stream (we only push the next piece after the
                // previous drains), so `sending_entity` unambiguously names it.
                if (!self.reg.isStale(conn_ent.entity)) {
                    if (getConn(self, conn_ent.entity)) |conn_ptr| {
                        if (conn_ptr.h1) |h1c| {
                            if (h1c.ws_mode) {
                                // WS backpressure: the single in-flight `ws_out`
                                // flush drained. Clear the flag and push whatever
                                // queued behind it (and reap a drained closing
                                // conn). On failure the conn is destroyed below.
                                h1c.ws_write_inflight = false;
                                if (!failed) self.wsFlush(conn_ptr, conn_ent.entity);
                            } else if (!h1c.sending_entity.isNil()) {
                                const sent = h1c.sending_entity;
                                h1c.sending_entity = Entity.nil;
                                if (self.reg.isInCollection(sent, &self._stream_data_sending)) {
                                    if (failed) {
                                        // The write failed (conn is about to be
                                        // destroyed): surface it so the worker
                                        // reaps the stream from response_out.
                                        try self.reg.set(sent, &self._stream_data_sending, H2IoResult, .{ .err = -1 });
                                        try self.reg.move(sent, &self._stream_data_sending, &self.response_out);
                                    } else {
                                        // Drained — let the worker push the next.
                                        try self.reg.move(sent, &self._stream_data_sending, &self.stream_data_out);
                                    }
                                }
                            }
                        }
                    }
                }

                if (failed) {
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

                // h1 connections have no nghttp2 session to drive — responses
                // are written synchronously in `http1WriteResponse`. They still
                // need idle reaping (a keep-alive conn the client leaves open, or
                // a `Connection: close`/error conn awaiting its write to drain),
                // which the nghttp2 path below does only for h2.
                if (conn_ptr.ng_session == null) {
                    if (conn_ptr.h1 != null and self.h2_opts.idle_timeout_ns > 0 and
                        conn_ptr.last_active_ns > 0 and
                        now -| conn_ptr.last_active_ns > self.h2_opts.idle_timeout_ns)
                    {
                        try self.reg.destroy(ent);
                    }
                    continue;
                }

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
                    // Mirrors the plaintext path below: flush the buffer
                    // when a frame won't fit, then keep going. The old
                    // code destroyed the connection on overflow, which
                    // killed any response > ~64KB (e.g. the codemirror
                    // bundle in the admin UI).
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
                            const cipher = tc.encrypt(accum_buf[0..accum_len], self.allocator) catch {
                                try self.reg.destroy(ent);
                                broke = true;
                                break;
                            };
                            self.submitWrite(ent, cipher) catch {
                                self.allocator.free(cipher);
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
                    // round trip by ~40 ms.
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
