// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Connection/stream leaf state for the h2 runtime: the non-generic
//! per-connection and per-stream types — `Conn`, `Http1Conn` (with its
//! lifecycle arms), the `Stream` accumulator, the shared `HeaderBuf`
//! and `WsFragments` cores, `WsReassembler`, `BodySink`/`BodyData`. root.zig re-exports
//! these types; the generic `H2(opts)` runtime (poll loop, nghttp2
//! callbacks, public API) lives in root.zig.
//!
//! The nghttp2 C import is shared via nghttp2_c.zig — a second
//! `@cImport` would mint DISTINCT pointer types and `Conn.ng_session`
//! would stop unifying with the runtime's session pointers.

const std = @import("std");
const rove = @import("rove");
const Entity = rove.Entity;
const tls = @import("tls.zig");
const ws = @import("ws.zig");
const c = @import("nghttp2_c.zig").c;

pub const HeaderField = struct {
    name: [*]const u8,
    name_len: u32,
    value: [*]const u8,
    value_len: u32,
};

/// What an `headers_first` server does with inbound DATA on a stream
/// whose request entity was early-emitted at the HEADERS frame
/// (`docs/architecture/routing-and-ingress.md`, the `blob.receive`
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
/// from headers alone). `.sink` routes body bytes to a registered
/// `BodySink` (a `blob.receive` upload driver) — the window opens
/// only as the sink reports drained bytes, so the client's send rate
/// is throttled to the sink's upload rate. `.auto` is the
/// non-headers_first default (nghttp2 auto window update, no manual
/// consume).
pub const BodyMode = enum(u8) { auto = 0, hold, buffer, discard, sink };

/// Consumer-supplied destination for inbound body bytes on a `.sink`
/// stream (`requestBodySink`). All callbacks are invoked on the h2
/// poll thread while the Stream is alive; `release` is the LAST call
/// — h2 drops its reference at stream close and never touches the
/// sink again. `push` borrows the bytes (the sink copies what it
/// keeps). `drained` returns bytes the sink has consumed since the
/// last call — h2 repays exactly that much flow-control window, so
/// backpressure follows the sink's real drain rate.
pub const BodySink = struct {
    ctx: *anyopaque,
    /// One DATA frame's bytes. Return false on a fatal sink error —
    /// h2 resets the stream.
    push: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
    /// END_STREAM: the body is complete; no more `push` calls.
    finish: *const fn (ctx: *anyopaque) void,
    /// The stream died before END_STREAM (client reset / connection
    /// gone). No more calls except `release`.
    abort: *const fn (ctx: *anyopaque) void,
    /// Bytes consumed by the sink since the last `drained` call.
    drained: *const fn (ctx: *anyopaque) u32,
    /// h2 is done with this sink (stream closed). Drop h2's ref.
    release: *const fn (ctx: *anyopaque) void,
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
    /// Set true after the first non-empty read on a server-direction
    /// plaintext connection. Used to gate the HTTP/1.1-vs-h2 preface
    /// sniff: only the first read can possibly be a non-h2 protocol;
    /// later frames may have arbitrary leading bytes.
    first_read_seen: bool = false,
    /// HTTP/1.1 connection state, mutually exclusive with `ng_session`.
    /// Set when the first-read sniff (or ALPN) routes a server
    /// connection to the h1 codec instead of nghttp2. While this
    /// is non-null the connection is driven entirely by `http1Feed` /
    /// `http1WriteResponse` (HTTP/1.1 ingress, `docs/architecture/routing-and-ingress.md`).
    h1: ?*Http1Conn = null,
    /// Graceful idle reap. When the idle GC decides to close an h2
    /// connection it queues a GOAWAY and sets `draining` instead of
    /// destroying outright, so the frame actually reaches the client —
    /// a silent close strands a client mid-reuse (the idle-keepalive
    /// reuse race: a request put on a connection the server already
    /// killed hangs until the client's own timeout, or forever).
    /// `drain_deadline_ns` is the backstop for a peer that never
    /// finishes closing.
    draining: bool = false,
    drain_deadline_ns: u64 = 0,

    /// Egress serialization (h2 server DATA path). A single TCP socket is
    /// one ordered byte stream, and for TLS every record's MAC binds an
    /// implicit sequence number — so two concurrent `prep_send` SQEs for
    /// the same conn that reach the socket out of order desync the peer's
    /// record layer (`bad record mac`). We therefore
    /// keep AT MOST ONE io write in flight per connection and queue the
    /// rest in FIFO order; `writesAccount` submits the next on completion.
    /// `send_queue` owns each buffer until it is handed to `submitWrite`
    /// (which takes ownership); a conn torn down mid-flight frees the
    /// remainder here.
    send_inflight: bool = false,
    send_queue: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(allocator: std.mem.Allocator, items: []Conn) void {
        for (items) |*item| {
            for (item.send_queue.items) |buf| allocator.free(buf);
            item.send_queue.deinit(allocator);
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

/// Per-connection HTTP/1.1 state (HTTP/1.1 ingress, `docs/architecture/routing-and-ingress.md`).
/// Accumulates inbound bytes, drives the pure `http1` codec, and tracks the
/// single in-flight request (no pipelining). Heap-owned; freed by `Conn.deinit`.
///
/// A connection lives in exactly ONE of three lifecycles, structural via
/// `state`: plain HTTP/1.1 request/response (including
/// the parked websocket_surface Upgrade — a SUB-state, see
/// `Http1State.pending_upgrade`), RFC 6455 framed WebSocket (worker
/// `websocket_upgrades` instances), or the raw-relay tunnel (front
/// `websocket_surface` instances). Framed vs tunnel are per-instance disjoint
/// (comptime opts), and an upgrade head only ever parses from the
/// idle-between-requests state, so cross-phase combinations (`body_active`
/// while framed, a tunnel sink mid-body, …) are unrepresentable.
/// Deliberately TOP-LEVEL because more than one phase
/// consults them:
///   - `buf` — the inbound accumulator across the whole life: request bytes,
///     then the coalesced early frame bytes that ride across an upgrade,
///     then the frame stream (framed) / nothing (tunnel pushes straight
///     through).
///   - `closing` — every phase's fatal/teardown path, the feed gate, and the
///     idle-GC reap all consult it.
///   - `paused_read` — the parked read entity; h1 streaming bodies AND
///     tunnel backpressure park here, and the unpark sweeps are phase-blind.
pub const Http1Conn = struct {
    allocator: std.mem.Allocator,
    /// Inbound bytes not yet fully consumed by an emitted request. The head of
    /// a complete request is dropped (compacted out) at emit time; any trailing
    /// bytes (a coalesced next request) stay buffered until the response drains.
    /// After an upgrade, carries RFC 6455 frame bytes instead.
    buf: std.ArrayList(u8),
    /// Set once a response with `Connection: close` (or a fatal error response)
    /// has been queued, or a phase's fatal path fired; the connection is reaped
    /// by the idle-timeout GC after the write drains.
    closing: bool = false,
    /// The read entity parked in `_read_h1_paused` while inbound bytes have
    /// outrun the consumer (streaming h1 body OR tunnel relay). nil = reads
    /// armed. TCP receive-window pushback is h1's flow-control window; not
    /// re-arming the socket read is how we stop repaying it.
    paused_read: Entity = Entity.nil,
    state: State = .{ .http1 = .{} },

    pub const State = union(enum) {
        http1: Http1State,
        ws_framed: WsFramed,
        ws_tunnel: WsTunnel,
    };

    /// Plain HTTP/1.1 request/response state — including the parked
    /// websocket_surface Upgrade (`pending_upgrade`), which is a sub-state
    /// rather than a union arm because the REJECT path resumes this exact
    /// machinery: `http1ErrorClose` serializes over `keep_alive`/`closing`,
    /// and the drain/idle reaps read `in_flight`/`sending_entity`.
    pub const Http1State = struct {
        /// True while a request entity is emitted and awaiting its response. No
        /// second request is parsed until the first responds. (Also set while a
        /// surfaced Upgrade is parked — no further parse on this conn.)
        in_flight: bool = false,
        /// Keep-alive decision captured from the in-flight request's head, applied
        /// when its response is serialized.
        keep_alive: bool = true,
        /// Chunked-request decode state. `chunk_body` accumulates the
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

        // ── Inbound body streaming (headers_first instances only) ────────────
        /// The in-flight request's stream state while its body is still inbound —
        /// the same `Stream` accumulator the h2 path keeps as nghttp2 stream user
        /// data (`body_mode` routing, accumulated bytes, sink ref + drain debt,
        /// `inbound_eof`), so `requestBodyBuffer` / `requestBodySink` /
        /// `sweepBodySinks` drive both protocols through one shape. Created at
        /// early-emit, freed at request-cycle end (`http1FinishCycle`) or conn
        /// teardown. Null when no streaming body is in flight.
        stream: ?*Stream = null,
        /// True from early-emit until the last body byte is consumed off the wire.
        /// While set, inbound bytes route to `http1DriveBody` and no next request
        /// is parsed (`buf` holds body framing, not a request head).
        body_active: bool = false,
        /// Content-Length bytes still owed. Null while the in-flight body is
        /// chunked (`chunk_pos` / `chunk_body` carry the framing state instead).
        body_remaining: ?usize = null,
        body_chunked: bool = false,
        /// Total body bytes routed so far (the `Expect: 100-continue` early-reply
        /// close-out needs "has the client started sending?").
        body_seen: usize = 0,
        /// `Expect: 100-continue` captured from the head — the head bytes are
        /// compacted away at early-emit, and the decision-gated `100 Continue`
        /// (sent when the consumer commits to the body) fires later.
        expect_continue: bool = false,
        /// `websocket_surface`: non-null once the Upgrade head was emitted to the
        /// consumer (`ws_upgrade_out`) and the connection is parked — no request
        /// parse, no 101 — until `wsUpgradeAccept` / `wsUpgradeReject` decides.
        /// Holds the owned `Sec-WebSocket-Key` for the deferred 101. Early frame
        /// bytes the client coalesced after the handshake accumulate in `buf`.
        pending_upgrade: ?[]u8 = null,
    };

    /// Outbound framed-byte queue shared by BOTH ws arms. Every server→client
    /// write (the 101, WS data frames, auto-pongs, the Close echo, tunnel relay
    /// bytes) is appended to `out` and flushed by `wsFlush` with exactly one
    /// socket write in flight (`write_inflight`), which both preserves frame
    /// order on the wire and coalesces a burst into one write. Reused (capacity
    /// retained) across flushes. `closing`: a Close frame has been queued (or
    /// the tunnel's far end hung up); the connection is destroyed once `out`
    /// drains.
    pub const WsWrite = struct {
        out: std.ArrayList(u8) = .empty,
        write_inflight: bool = false,
        closing: bool = false,

        pub fn deinit(self: *WsWrite, allocator: std.mem.Allocator) void {
            self.out.deinit(allocator);
        }
    };

    /// RFC 6455 fragmentation core: reassembles one
    /// fragmented data message at a time. `feed` enforces the §5.4 rules (no
    /// nested opener, no orphan continuation) plus the running size cap, and
    /// yields the completed message at FIN. Deliberately transport-free so the
    /// WS-over-h2 reassembler (`WsReassembler`) can adopt it.
    pub const WsFragments = struct {
        /// Reassembly buffer for a fragmented data message (a non-FIN opener +
        /// `continuation` frames). Empty between messages.
        msg: std.ArrayList(u8) = .empty,
        /// The opener's opcode (text/binary); 0 means no message in progress.
        msg_opcode: u8 = 0,

        const Fed = union(enum) {
            /// Frame consumed; the message is still assembling.
            pending,
            /// A complete message. `payload` borrows the caller's frame payload
            /// (unfragmented case) or `msg` (fragmented case) — consume it, then
            /// call `reset` before the next `feed`.
            message: struct { opcode: u8, payload: []const u8 },
        };

        pub fn deinit(self: *WsFragments, allocator: std.mem.Allocator) void {
            self.msg.deinit(allocator);
        }

        /// Feed one DATA-class frame (text / binary / continuation only).
        pub fn feed(
            self: *WsFragments,
            allocator: std.mem.Allocator,
            opcode: ws.Opcode,
            fin: bool,
            payload: []const u8,
            max_message: usize,
        ) error{ WsProtocol, OutOfMemory }!Fed {
            switch (opcode) {
                .text, .binary => {
                    // A new data opener while a fragmented message is open is a
                    // protocol error (§5.4).
                    if (self.msg_opcode != 0) return error.WsProtocol;
                    if (fin) return .{ .message = .{ .opcode = @intFromEnum(opcode), .payload = payload } };
                    self.msg.clearRetainingCapacity();
                    try self.msg.appendSlice(allocator, payload);
                    self.msg_opcode = @intFromEnum(opcode);
                    return .pending;
                },
                .continuation => {
                    // A continuation with no opener is a protocol error (§5.4).
                    if (self.msg_opcode == 0) return error.WsProtocol;
                    if (self.msg.items.len + payload.len > max_message)
                        return error.WsProtocol;
                    try self.msg.appendSlice(allocator, payload);
                    if (fin) return .{ .message = .{ .opcode = self.msg_opcode, .payload = self.msg.items } };
                    return .pending;
                },
                else => unreachable, // control frames are dispatched before feed
            }
        }

        /// Consume a completed message (clears the buffer + opener). No-op for
        /// the unfragmented case (nothing was buffered).
        pub fn reset(self: *WsFragments) void {
            self.msg.clearRetainingCapacity();
            self.msg_opcode = 0;
        }
    };

    /// RFC 6455 framed mode (worker `websocket_upgrades` instances): `buf`
    /// accumulates frames (parsed by `wsDrive`, not `http1Drive`).
    pub const WsFramed = struct {
        frag: WsFragments = .{},
        /// Routing captured from the `101` Upgrade request (piece D, the worker
        /// seam). The handshake completes at the transport layer without the
        /// worker, then drops the request head — so without this the first
        /// inbound frame has no tenant/module context. The worker reads these
        /// via `wsConnRouting` off the `ws_message_out` entity's `Session`,
        /// resolves the tenant from `authority`, and the handler module from
        /// `path`. Owned (duped at handshake).
        authority: []u8 = &.{},
        path: []u8 = &.{},
        wr: WsWrite = .{},
    };

    /// Raw-relay tunnel (front `websocket_surface` instances, set by
    /// `wsUpgradeAccept`): socket bytes push to the consumer `sink` VERBATIM —
    /// no RFC 6455 parsing at this hop; masking survives to the far end.
    /// Outbound tunnel bytes ride `wr.out` / `wsTunnelWrite`. Backpressure:
    /// `unconsumed` (pushed-but-undrained) parks the socket read at the same
    /// 1 MiB cap streamed bodies use; `sweepBodySinks` repays from the sink's
    /// `drained`.
    pub const WsTunnel = struct {
        sink: BodySink,
        unconsumed: u32 = 0,
        wr: WsWrite = .{},
    };

    /// Hard ceiling on a single reassembled WebSocket message at the edge — the
    /// per-frame cap fed to `ws.parseFrame` and the running cap on a fragmented
    /// message. Per-tenant plan limits are the DP worker's job (piece D); this
    /// is the coarse front-door backstop, matching `MAX_BODY_BYTES`.
    pub const MAX_WS_MESSAGE: usize = 16 * 1024 * 1024;

    /// Hard ceiling on a buffered request body at the edge. Per-tenant plan
    /// limits (413) are enforced in the DP worker; this is the coarse
    /// front-door backstop against an unbounded `Content-Length` OOM-ing the
    /// proxy before the request ever reaches a tenant.
    pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

    /// Backpressure cap for a streaming h1 inbound body: stop arming socket
    /// reads when held-undecided bytes (`.hold`) or pushed-but-undrained sink
    /// bytes (`.sink`) cross this; resume as the consumer decides / the sink
    /// drains. Matches the 1 MiB h2 stream windows the worker and front
    /// configure, so h1 and h2 uploads see the same per-stream buffering
    /// bound at the edge.
    pub const STREAM_PAUSE_BYTES: usize = 1024 * 1024;

    pub fn create(allocator: std.mem.Allocator) ?*Http1Conn {
        const h = allocator.create(Http1Conn) catch return null;
        h.* = .{ .allocator = allocator, .buf = .empty };
        return h;
    }

    pub fn free(self: *Http1Conn) void {
        self.buf.deinit(self.allocator);
        switch (self.state) {
            .http1 => |*st| {
                if (st.stream) |s| s.free();
                st.chunk_body.deinit(self.allocator);
                if (st.pending_upgrade) |k| self.allocator.free(k);
            },
            .ws_framed => |*fr| {
                fr.frag.deinit(self.allocator);
                fr.wr.deinit(self.allocator);
                if (fr.authority.len > 0) self.allocator.free(fr.authority);
                if (fr.path.len > 0) self.allocator.free(fr.path);
            },
            .ws_tunnel => |*tn| tn.wr.deinit(self.allocator),
        }
        self.allocator.destroy(self);
    }

    /// The active ws arm's outbound queue, or null in plain-http1 phase
    /// (callers treat that as "not a WS connection").
    pub fn wsWrite(self: *Http1Conn) ?*WsWrite {
        return switch (self.state) {
            .http1 => null,
            .ws_framed => |*fr| &fr.wr,
            .ws_tunnel => |*tn| &tn.wr,
        };
    }

    // ── Phase transitions ─────────────────────────────────────────────

    /// http1 → parked Upgrade (websocket_surface). Stays `.http1` — see
    /// `Http1State.pending_upgrade` for why pending is a sub-state. Takes
    /// ownership of `key`. The request cycle is idle by construction (an
    /// upgrade head only parses when `!in_flight and !body_active`).
    pub fn beginPendingUpgrade(self: *Http1Conn, key: []u8, keep_alive: bool) void {
        const st = &self.state.http1;
        std.debug.assert(st.pending_upgrade == null and !st.in_flight and !st.body_active);
        st.pending_upgrade = key;
        st.in_flight = true; // no further request parse on this conn
        st.keep_alive = keep_alive;
    }

    /// Abandon a parked Upgrade (the reject path): free the key and resume
    /// the plain http1 machinery — the caller serializes the error response
    /// over the still-live request/response state.
    pub fn rejectPendingUpgrade(self: *Http1Conn) void {
        const st = &self.state.http1;
        if (st.pending_upgrade) |k| self.allocator.free(k);
        st.pending_upgrade = null;
    }

    /// http1 (parked Upgrade) → raw-relay tunnel. The http1 arm dies here;
    /// its only owned allocations at this point are the key + the (empty)
    /// chunk accumulator — the idle-cycle assertions pin that.
    pub fn acceptTunnel(self: *Http1Conn, sink: BodySink) void {
        const st = &self.state.http1;
        std.debug.assert(st.pending_upgrade != null);
        std.debug.assert(st.stream == null and !st.body_active);
        if (st.pending_upgrade) |k| self.allocator.free(k);
        st.chunk_body.deinit(self.allocator);
        self.state = .{ .ws_tunnel = .{ .sink = sink } };
    }

    /// http1 → framed WebSocket (worker websocket_upgrades; no pending step —
    /// the 101 is immediate). Takes ownership of `authority` + `path`.
    pub fn acceptFramed(self: *Http1Conn, authority: []u8, path: []u8) void {
        const st = &self.state.http1;
        std.debug.assert(st.pending_upgrade == null and st.stream == null and !st.body_active);
        st.chunk_body.deinit(self.allocator);
        self.state = .{ .ws_framed = .{ .authority = authority, .path = path } };
    }
};

/// Per-stream WS state for an Extended CONNECT tunnel (architecture/websockets.md).
/// Lives from `wsConnectAccept` to stream close. Inbound stream DATA bytes
/// accumulate in `buf` and feed the RFC 6455 parser (`wsStreamDrive`);
/// fragmented messages reassemble in `msg`; outbound framed bytes queue on
/// `send_buf` and ship through the stream's deferred data provider (one
/// nghttp2 submit, resumed as frames are queued).
pub const WsReassembler = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Fragmented-message reassembly — the same `WsFragments` core the h1
    /// framed arm uses (ONE fragmentation state machine, not two).
    frag: Http1Conn.WsFragments = .{},
    send_buf: std.ArrayList(u8) = .empty,
    /// Our side is done after `send_buf` drains (Close sent / END_STREAM
    /// requested): the provider returns EOF instead of deferring.
    closing: bool = false,
    /// The peer's close was already surfaced (opcode-8 message emitted) —
    /// an END_STREAM after a clean Close frame must not emit a second one.
    client_closed: bool = false,

    pub fn create(allocator: std.mem.Allocator) ?*WsReassembler {
        const wr = allocator.create(WsReassembler) catch return null;
        wr.* = .{ .allocator = allocator };
        return wr;
    }

    pub fn free(self: *WsReassembler) void {
        self.buf.deinit(self.allocator);
        self.frag.deinit(self.allocator);
        self.send_buf.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// The ONE builder for the `{HeaderField[] | string blob}` combined
/// allocation that request/response headers ship as (`ReqHeaders._buf`
/// layout: the field array, then the name/value bytes it points into).
/// Both protocols build headers through this — h2 incrementally from
/// nghttp2 header callbacks, h1 from a parsed head — so the growth
/// hardening lives ONCE:
///
///   - `append`'s string-buffer growth loops the doubling until the new
///     capacity actually fits: a single header (reassembled across h2
///     CONTINUATION frames) can exceed double the current cap, and a
///     single doubling would leave the @memcpy writing past the
///     allocation — a remote heap overflow (h2spec http2/6.10).
///   - Pre-finalize, field name/value pointers are OFFSETS+1 into
///     `strbuf` (not addresses — the buffer reallocs); `value` decodes
///     them for the HEADERS-frame-time lookups. `finalize` rewrites
///     them into real pointers inside the combined allocation.
pub const HeaderBuf = struct {
    fields: ?[*]HeaderField = null,
    count: u32 = 0,
    cap: u32 = 0,
    strbuf: ?[*]u8 = null,
    strbuf_len: u32 = 0,
    strbuf_cap: u32 = 0,

    pub fn deinit(self: *HeaderBuf, allocator: std.mem.Allocator) void {
        if (self.fields) |f| allocator.free(@as([*]HeaderField, @ptrCast(@alignCast(f)))[0..self.cap]);
        if (self.strbuf) |b| allocator.free(b[0..self.strbuf_cap]);
        self.* = .{};
    }

    /// Append one header. `lower_name` folds the name to lowercase while
    /// copying (h1 heads arrive mixed-case; h2 names are already lower).
    pub fn append(self: *HeaderBuf, allocator: std.mem.Allocator, name: []const u8, value_bytes: []const u8, lower_name: bool) bool {
        if (self.count == self.cap) {
            const new_cap = if (self.cap > 0) self.cap * 2 else 16;
            const old = if (self.fields) |f| @as([*]HeaderField, @ptrCast(@alignCast(f)))[0..self.cap] else @as([]HeaderField, &.{});
            const new_buf = allocator.realloc(old, new_cap) catch return false;
            self.fields = @ptrCast(new_buf.ptr);
            self.cap = @intCast(new_buf.len);
        }

        const need: u32 = @intCast(name.len + value_bytes.len);
        if (self.strbuf_len + need > self.strbuf_cap) {
            // Grow until the buffer actually fits (see the struct doc).
            var new_cap: u32 = if (self.strbuf_cap > 0) self.strbuf_cap else 1024;
            while (new_cap < self.strbuf_len + need) new_cap *|= 2;
            const old = if (self.strbuf) |b| b[0..self.strbuf_cap] else @as([]u8, &.{});
            const new_buf = allocator.realloc(old, new_cap) catch return false;
            self.strbuf = new_buf.ptr;
            self.strbuf_cap = @intCast(new_buf.len);
        }

        const name_off = self.strbuf_len;
        const name_dst = self.strbuf.?[name_off .. name_off + @as(u32, @intCast(name.len))];
        @memcpy(name_dst, name);
        if (lower_name) for (name_dst) |*ch| {
            ch.* = std.ascii.toLower(ch.*);
        };
        self.strbuf_len += @intCast(name.len);

        const value_off = self.strbuf_len;
        @memcpy(self.strbuf.?[value_off .. value_off + @as(u32, @intCast(value_bytes.len))], value_bytes);
        self.strbuf_len += @intCast(value_bytes.len);

        self.fields.?[self.count] = .{
            .name = @ptrFromInt(name_off + 1),
            .name_len = @intCast(name.len),
            .value = @ptrFromInt(value_off + 1),
            .value_len = @intCast(value_bytes.len),
        };
        self.count += 1;
        return true;
    }

    /// Pre-finalize lookup (offset-encoded pointers; see the struct doc).
    pub fn value(self: *const HeaderBuf, name: []const u8) ?[]const u8 {
        const fields = self.fields orelse return null;
        const sb = self.strbuf orelse return null;
        for (fields[0..self.count]) |f| {
            const n = sb[(@intFromPtr(f.name) - 1)..][0..f.name_len];
            if (std.mem.eql(u8, n, name)) {
                return sb[(@intFromPtr(f.value) - 1)..][0..f.value_len];
            }
        }
        return null;
    }

    /// Copy into the combined `{fields|strbuf}` allocation, rewriting the
    /// offset-encoded pointers into real ones. The accumulator stays
    /// intact (freed by `deinit`); the caller owns the returned buffer.
    pub fn finalize(self: *const HeaderBuf, allocator: std.mem.Allocator, out_fields: *?[*]HeaderField, out_count: *u32, out_buf_len: *u32) ?[*]u8 {
        const n = self.count;
        if (n == 0) {
            out_fields.* = null;
            out_count.* = 0;
            out_buf_len.* = 0;
            return null;
        }

        const fields_size = @as(usize, n) * @sizeOf(HeaderField);
        const total = fields_size + self.strbuf_len;
        const buf_slice = allocator.alloc(u8, total) catch return null;
        const buf_ptr: [*]u8 = buf_slice.ptr;

        const strbuf_base = buf_ptr + fields_size;
        @memcpy(strbuf_base[0..self.strbuf_len], self.strbuf.?[0..self.strbuf_len]);

        const result_fields: [*]HeaderField = @ptrCast(@alignCast(buf_ptr));
        for (0..n) |i| {
            const src = self.fields.?[i];
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
};

// =============================================================================
// Stream accumulator (nghttp2 stream user_data)
// =============================================================================

pub const Stream = struct {
    conn_entity: Entity,
    allocator: std.mem.Allocator,
    hdr: HeaderBuf = .{},
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
    /// `.sink` mode destination (`requestBodySink`). h2 holds one
    /// reference: released (and nulled) at stream close, after
    /// `finish` or `abort`.
    sink: ?BodySink = null,
    /// client_headers_first: the response HEADERS were early-emitted
    /// into `client_response_receiving` — the END_STREAM /
    /// stream-close paths must not re-attach headers/body to the
    /// request entity.
    resp_emitted: bool = false,
    /// True once `sink.finish` was called (END_STREAM delivered) —
    /// stream close then releases without aborting.
    sink_finished: bool = false,
    send_data: ?*BodyData = null,
    response_status: u16 = 0,
    stream_chunk_data: ?[*]u8 = null,
    stream_chunk_len: u32 = 0,
    stream_chunk_offset: u32 = 0,
    /// Extended-CONNECT WS stream (architecture/websockets.md). Set at CONNECT
    /// detection; `entity` is the identity entity in `ws_connect_out` /
    /// `ws_streams` and stream close destroys it (instead of the
    /// request-entity `serverStreamClose` routing).
    is_ws: bool = false,
    /// Non-null once the consumer accepted the tunnel (`wsConnectAccept`).
    /// Pre-accept, inbound DATA rides the `.hold` arm like any undecided
    /// body.
    ws_reasm: ?*WsReassembler = null,

    pub fn create(conn_entity: Entity, allocator: std.mem.Allocator) ?*Stream {
        const s = allocator.create(Stream) catch return null;
        s.* = .{ .conn_entity = conn_entity, .allocator = allocator };
        return s;
    }

    pub fn free(self: *Stream) void {
        const allocator = self.allocator;
        self.hdr.deinit(allocator);
        if (self.body_data) |p| allocator.free(p[0..self.body_cap]);
        if (self.send_data) |d| d.destroy();
        if (self.stream_chunk_data) |cd| allocator.free(cd[0..self.stream_chunk_len]);
        if (self.ws_reasm) |wr| wr.free();
        allocator.destroy(self);
    }

    /// Pre-finalize header lookup (HEADERS-frame time, before any entity
    /// exists). Delegates to the shared builder.
    pub fn hdrValue(self: *const Stream, name: []const u8) ?[]const u8 {
        return self.hdr.value(name);
    }

    /// nghttp2 header-callback shape over `HeaderBuf.append` (names from
    /// nghttp2 are already lowercase).
    pub fn hdrAppend(self: *Stream, name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize) bool {
        return self.hdr.append(self.allocator, name[0..name_len], value[0..value_len], false);
    }

    pub fn hdrFinalize(self: *Stream, out_fields: *?[*]HeaderField, out_count: *u32, out_buf_len: *u32) ?[*]u8 {
        return self.hdr.finalize(self.allocator, out_fields, out_count, out_buf_len);
    }

    /// Outcome of routing one inbound body chunk per `body_mode` —
    /// the ONE routing decision both protocols share (`onDataChunkRecvCb`
    /// for h2 DATA, `http1RouteBody` for h1 wire bytes). Callers own the
    /// transport-specific flow-control repayment and failure verbs (h2:
    /// consume / RST; h1: nothing-to-repay / error-close / conn teardown).
    const RouteOutcome = enum {
        /// Accepted (accumulated or discarded); repay flow-control credit
        /// now — the client keeps streaming.
        consume,
        /// Accepted as held debt (`unconsumed` charged): the consumer's
        /// decision (.hold) or the sink's drain report repays it later.
        held,
        /// Accumulation allocation failed.
        append_failed,
        /// Accumulating would exceed `max_buffer` (h1's 413 edge backstop;
        /// h2 passes null — the stream window bounds accumulation).
        over_cap,
        /// The sink rejected the push (consumer gone).
        sink_failed,
    };

    pub fn routeInbound(self: *Stream, bytes: []const u8, max_buffer: ?usize) RouteOutcome {
        switch (self.body_mode) {
            .auto, .buffer => {
                if (max_buffer) |cap| if (self.body_len + bytes.len > cap) return .over_cap;
                if (!self.bodyAppend(bytes.ptr, bytes.len)) return .append_failed;
                return .consume;
            },
            .hold => {
                // Window-hold: buffer but do NOT repay. The client is held
                // at the door after at most one window's worth while the
                // consumer decides.
                if (!self.bodyAppend(bytes.ptr, bytes.len)) return .append_failed;
                self.unconsumed +|= @intCast(bytes.len);
                return .held;
            },
            .discard => return .consume,
            .sink => {
                // Route to the upload driver; credit is repaid by
                // `sweepBodySinks` as the sink reports drained bytes — the
                // client's send rate follows the upload rate.
                const sk = self.sink orelse return .consume;
                if (!sk.push(sk.ctx, bytes)) return .sink_failed;
                self.unconsumed +|= @intCast(bytes.len);
                return .held;
            },
        }
    }

    /// Flip an undecided/accumulating inbound body to discard (a response
    /// is going out mid-body): drop the accumulator, keep draining wire
    /// bytes so framing survives. Returns the held debt the caller repays
    /// (h2: nghttp2 consume; h1: nothing — its debt is read-pause
    /// accounting, cleared here). Null (no-op) unless mode ∈ {hold,
    /// buffer} — a `.sink` keeps draining (the driver owns the bytes).
    pub fn flipToDiscard(self: *Stream) ?u32 {
        if (self.body_mode != .hold and self.body_mode != .buffer) return null;
        self.body_mode = .discard;
        if (self.body_data) |p| {
            self.allocator.free(p[0..self.body_cap]);
            self.body_data = null;
            self.body_len = 0;
            self.body_cap = 0;
        }
        const repaid = self.unconsumed;
        self.unconsumed = 0;
        return repaid;
    }

    pub fn bodyAppend(self: *Stream, data: [*]const u8, len: usize) bool {
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

pub const BodyData = struct {
    data: []const u8,
    offset: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, data: [*]const u8, len: u32) ?*BodyData {
        const copy = allocator.alloc(u8, len) catch return null;
        @memcpy(copy, data[0..len]);
        const bd = allocator.create(BodyData) catch {
            allocator.free(copy);
            return null;
        };
        bd.* = .{ .data = copy, .allocator = allocator };
        return bd;
    }

    pub fn destroy(self: *BodyData) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};
