// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const Row = rove.Row;
const Collection = rove.Collection;
const Entity = rove.Entity;
pub const tls = @import("tls.zig");
pub const TlsConfig = tls.TlsConfig;
pub const http1 = @import("http1.zig");
pub const ws = @import("ws.zig");

const c = @import("nghttp2_c.zig").c;

// =============================================================================
// Component types
// =============================================================================

// ── Connection/stream leaf state ────────────────────────────────────
// The non-generic per-connection / per-stream types (Conn, Http1Conn +
// its lifecycle arms, Stream, WsReassembler, HeaderBuf, BodySink, …)
// live in conn_state.zig; re-exported here so call sites — internal or
// external — reference them through this module.
const conn_state = @import("conn_state.zig");
pub const HeaderField = conn_state.HeaderField;
pub const BodySink = conn_state.BodySink;
pub const Direction = conn_state.Direction;
pub const Conn = conn_state.Conn;
pub const Http1Conn = conn_state.Http1Conn;
const WsReassembler = conn_state.WsReassembler;
const HeaderBuf = conn_state.HeaderBuf;
const Stream = conn_state.Stream;
const BodyData = conn_state.BodyData;

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
    /// `client_stream_request_in` only: the request body — possibly empty —
    /// is already complete at submit time. The submit carries END_STREAM
    /// with the HEADERS (empty body) or after the attached body's DATA, so
    /// a proxied bodyless request never looks body-carrying upstream (the
    /// worker's headers-first disposition would mis-route it to
    /// `onHeaders`). No `client_stream_data_in` / `client_stream_close_in`
    /// pump follows. Ignored on every other collection.
    complete: bool = false,

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

/// Map an HTTP status code to a class index for `http_requests_total`:
/// [0]=other(0/<100/≥600) [1]=1xx [2]=2xx [3]=3xx [4]=4xx [5]=5xx.
fn statusClass(code: u16) usize {
    const cls = code / 100;
    return if (cls >= 1 and cls <= 5) cls else 0;
}

/// A bounded, hand-picked set of individually-tracked statuses for
/// `http_responses_status_total`. The `statusClass` buckets answer "how many
/// 4xx?"; these answer "401 vs 404 vs 409 vs 421 vs 502 vs 503?" — the
/// difference between "auth is broken", "route not found", and "not the
/// leader" (rove#216: a deploy-auth 401 storm was indistinguishable from any
/// other 4xx in Grafana). The active-series rule still holds — this is a fixed
/// list, NOT per-route/tenant, and everything not listed rolls up into the
/// class buckets only.
const NOTABLE_STATUS = [_]u16{ 400, 401, 403, 404, 409, 421, 429, 499, 500, 502, 503, 504 };

fn notableStatusIndex(code: u16) ?usize {
    for (NOTABLE_STATUS, 0..) |s, i| if (s == code) return i;
    return null;
}

pub const H2IoResult = struct {
    err: i32 = 0,
    /// Client terminals only (rove#532): the request HEADERS were serialized
    /// and NOT covered by a failed socket write — i.e. the head is on the
    /// wire, or unknowably in flight; either way a proxy must treat the
    /// request as possibly executed. False means the head provably never
    /// left this process (never serialized, or its covering write failed
    /// before any byte was queued), so a re-send cannot double-execute.
    head_written: bool = false,
};

/// Per-WebSocket-message metadata on a WS seam entity
/// (docs/architecture/websockets.md). `opcode` is the RFC 6455 data opcode (`ws.Opcode` int): `1` text,
/// `2` binary on an inbound `ws_message_out` entity (`8` close = client closed);
/// the same field selects the frame type for an outbound `ws_send_in` entity.
/// The payload itself rides the entity's `ReqBody` (allocator-owned bytes).
pub const WsMeta = struct {
    opcode: u8 = 0,
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
    /// The declared world this instantiation runs in. When null, the
    /// root module's `rove_world` declaration is consulted
    /// (`rove.declared_world`). The world must contain h2's parts —
    /// build it from `parts(the same Options)`, appending the
    /// composing layer's own parts; a composer's collections join the
    /// one namespace as its own Part.
    world: ?type = null,
};

/// The rows h2's collections materialize, given the caller's fragments —
/// the single computation `H2(...)` and `parts(...)` both read, so a
/// declared world and the instantiated types cannot drift apart.
fn RowsFor(comptime opts: Options) type {
    return struct {
        pub const stream = StreamBaseRow.merge(opts.request_row);
        pub const connect_full = Row(&.{ ConnectTarget, Session, H2IoResult }).merge(opts.request_row);
        pub const full_conn = rio.ConnectionBaseRow.merge(Row(&.{Conn})).merge(opts.connection_row);
        pub const ws_seam = Row(&.{ Session, ReqBody, WsMeta, H2IoResult }).merge(opts.request_row);
    };
}

/// The rove-io options this layer derives from its own — the single
/// derivation `H2(...)` and `parts(...)` share. Retirement hands conns
/// to `conn_dead` so `processConnDead` can free the foreign state
/// riding them (nghttp2 session, TLS conn, h1) at a point provably
/// after every reader.
pub fn ioOptions(comptime opts: Options) rio.Options {
    return .{
        .connection_row = Row(&.{Conn}).merge(opts.connection_row),
        .connect = opts.client,
        .on_retire = .hand_off,
        .world = opts.world,
    };
}

/// Which of h2's collection shapes an entry stores; `.io` marks entries
/// owned by rove-io (present so ONE flattened reference list spans the
/// shared registry).
const CollKind = enum {
    io,
    server_stream,
    server_read,
    server_conn,
    server_ws,
    client_connect,
    client_stream,
    /// The stream dead-letter: empty row, terminal, reaped by
    /// `processStreamDead` (fat model).
    dead,
};

const CollSpec = struct {
    name: [:0]const u8,
    kind: CollKind,
    client_only: bool = false,
    // True for collections that hold an entity in some
    // intermediate state of the kind's pipeline (so the
    // serverStreamClose / clientStreamClose helpers iterate
    // them looking for the entity's current home). False for
    // terminal collections (response_out / client_response_out)
    // — those are the move target, not a search target.
    in_chain: bool = false,
};

// Single source of truth for h2's collection fields. Drives init,
// registerCollection, deinit, the `Coll` enum + chain lookups, and the
// layer's world part, so adding a collection is a one-line spec change
// rather than edits in 4–6 places. The storage type is derived from
// `.kind` (see `collRowFor` / `H2`'s `CollTypeOf`).
const COLLECTIONS = [_]CollSpec{
    .{ .name = "request_out", .kind = .server_stream, .in_chain = true },
    .{ .name = "request_receiving", .kind = .server_stream, .in_chain = true },
    .{ .name = "request_buffering", .kind = .server_stream, .in_chain = true },
    .{ .name = "response_in", .kind = .server_stream, .in_chain = true },
    .{ .name = "response_out", .kind = .server_stream },
    .{ .name = "_response_sending", .kind = .server_stream, .in_chain = true },
    .{ .name = "stream_response_in", .kind = .server_stream, .in_chain = true },
    .{ .name = "stream_data_out", .kind = .server_stream, .in_chain = true },
    .{ .name = "stream_data_in", .kind = .server_stream, .in_chain = true },
    .{ .name = "stream_close_in", .kind = .server_stream, .in_chain = true },
    .{ .name = "_stream_data_sending", .kind = .server_stream, .in_chain = true },
    .{ .name = "ws_message_out", .kind = .server_ws },
    .{ .name = "ws_send_in", .kind = .server_ws },
    // Not in_chain: WS identity entities die with their stream
    // (destroyed in onStreamCloseCb), never via serverStreamClose.
    .{ .name = "ws_connect_out", .kind = .server_stream },
    .{ .name = "ws_streams", .kind = .server_stream },
    .{ .name = "ws_upgrade_out", .kind = .server_stream },
    .{ .name = "_read_errors", .kind = .server_read },
    .{ .name = "_read_init", .kind = .server_read },
    .{ .name = "_read_active", .kind = .server_read },
    .{ .name = "_read_handshake", .kind = .server_read },
    .{ .name = "_read_h1_paused", .kind = .server_read },
    .{ .name = "_conn_tls_handshake", .kind = .server_conn },
    .{ .name = "_conn_active", .kind = .server_conn },
    .{ .name = "client_connect_in", .kind = .client_connect, .client_only = true },
    .{ .name = "client_connect_out", .kind = .client_connect, .client_only = true },
    .{ .name = "client_connect_errors", .kind = .client_connect, .client_only = true },
    .{ .name = "_client_connect_pending", .kind = .client_connect, .client_only = true },
    .{ .name = "client_request_in", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "client_response_out", .kind = .client_stream, .client_only = true },
    // Output-only, never a request entity's home — out of the
    // chain so clientStreamClose/streamSet never match it.
    .{ .name = "client_response_receiving", .kind = .client_stream, .client_only = true },
    .{ .name = "_client_request_sending", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "client_stream_request_in", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "client_stream_data_out", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "client_stream_data_in", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "client_stream_close_in", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "_client_stream_data_sending", .kind = .client_stream, .client_only = true, .in_chain = true },
    .{ .name = "_stream_dead", .kind = .dead },
};

fn collRowFor(comptime opts: Options, comptime kind: CollKind) type {
    const rows = RowsFor(opts);
    return switch (kind) {
        .io => @compileError("io-owned entries come from rio.parts, not h2's table"),
        .server_stream, .client_stream => rows.stream,
        .server_read => rio.ReadBaseRow,
        .server_conn => rows.full_conn,
        .server_ws => rows.ws_seam,
        .client_connect => rows.connect_full,
        .dead => Row(&.{}),
    };
}

/// The server-stream row this Options value produces — for a composer
/// declaring its own collections on the same row (the worker's parked
/// stream states). Identity with the instantiated `H2(...).StreamRow`
/// holds because the row computation is shared and memoized on the
/// same fragments.
pub fn StreamRowFor(comptime opts: Options) type {
    return RowsFor(opts).stream;
}

/// h2's contribution to a declared world: io's parts (with the io
/// options this layer derives) followed by h2's own. A binary on the
/// fat model composes its root `rove_world` from this — appending its
/// own parts — passing the SAME options value it instantiates `H2`
/// with.
pub fn parts(comptime opts: Options) []const rove.Part {
    comptime var decls: []const rove.CollDecl = &.{};
    inline for (COLLECTIONS) |s| {
        if (s.client_only and !opts.client) continue;
        decls = decls ++ [_]rove.CollDecl{.{ .name = s.name, .row = collRowFor(opts, s.kind) }};
    }
    return rio.parts(ioOptions(opts)) ++ [_]rove.Part{.{ .name = "rove-h2", .collections = decls }};
}

/// Comptime guard: the declared world's storage type for `name` must be
/// the very type this instantiation computed — see rove-io's twin.
fn checkWorldColl(comptime WorldT: type, comptime name: [:0]const u8, comptime Local: type) void {
    if (!@hasField(WorldT.CollId, name)) @compileError(
        "rove-h2: the declared world lacks h2's '" ++ name ++
            "' — build the root rove_world from rh2.parts(the same Options)",
    );
    if (WorldT.CollOf(@field(WorldT.CollId, name)) != Local) @compileError(
        "rove-h2: world row for '" ++ name ++
            "' does not match this instantiation — the root rove_world was built from different Options; declare the options once and use the same value at both sites",
    );
}

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
    /// to 0 to disable idle reaping entirely.
    idle_timeout_ns: u64 = 10 * std.time.ns_per_s,
    /// Idle reap timeout for CLIENT-direction connections (this
    /// instance acting as an h2 client — e.g. the front door's pooled
    /// front→worker legs). 0 (default) ⇒ fall back to
    /// `idle_timeout_ns`. The front door sets this BELOW the worker's
    /// server-side `idle_timeout_ns` so the front always recycles a
    /// pooled upstream connection before the worker reaps it — the
    /// standard "LB idle < backend keepalive" rule, which keeps the
    /// reuse-vs-reap teardown on the side that owns the next request
    /// (clean recycle between requests) instead of reacting to the
    /// peer's GOAWAY mid-reuse. See the front-door TTFB investigation.
    client_idle_timeout_ns: u64 = 0,
    /// TOTAL budget for a TLS handshake to complete (accept →
    /// handshake_done). The idle reaper covers only `_conn_active`;
    /// without this a peer that opens TCP and stalls mid-handshake
    /// pins a connection slot forever — classic slowloris against
    /// `max_connections` (front-door hardening plan A4). This is a
    /// deadline from accept, not an idle window: `last_active_ns` is
    /// stamped once at accept and never refreshed during the
    /// handshake, so trickling one handshake byte at a time buys
    /// nothing. 0 disables.
    tls_handshake_timeout_ns: u64 = 10 * std.time.ns_per_s,
    tls_config: ?*TlsConfig = null,
    /// Headers-first request emission (`docs/architecture/routing-and-ingress.md`
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
    /// Client-side mirror of `headers_first` (the front door's
    /// streaming reverse proxy). Off (default): a client response is
    /// delivered complete — RespHeaders/RespBody/Status attach to the
    /// request entity at END_STREAM and it lands in
    /// `client_response_out`. On: a final (non-1xx) response whose
    /// HEADERS frame lacks END_STREAM emits a FRESH entity into
    /// `client_response_receiving` immediately (Status + RespHeaders;
    /// the consumer destroys it after reading), with nghttp2's auto
    /// window update disabled — body DATA buffers unconsumed (the
    /// upstream stalls after one stream window) until the consumer
    /// attaches a `BodySink` via `requestBodySink` (same call as the
    /// server side; the sink's drain rate then paces the upstream).
    /// The request entity still reaches `client_response_out` at
    /// stream close as the terminal signal, without headers/body
    /// re-attached.
    client_headers_first: bool = false,
    /// Answer HTTP/1.1 `Upgrade: websocket` handshakes (RFC 6455 piece
    /// A) on server connections. On (default) for the worker — the
    /// edge or a direct client speaks WS to it. The front door turns
    /// this OFF: terminating WS at the proxy would strand the frames
    /// there (WS tunneling through the front is a separate, unbuilt
    /// leg), so an Upgrade request degrades to a classic proxied GET
    /// and the backend answers it as plain HTTP.
    websocket_upgrades: bool = true,
    /// RFC 8441 Extended CONNECT on SERVER sessions
    /// (architecture/websockets.md): advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL` and surface
    /// each `:method CONNECT` + `:protocol websocket` stream as an
    /// identity entity in `ws_connect_out` for the consumer's
    /// disposition (`wsConnectAccept` → the stream becomes a live WS
    /// carried as RFC 6455 frames in stream DATA, messages on
    /// `ws_message_out`; `wsConnectReject(status)` → the tunnel is
    /// refused before any 200). The rewind worker enables this — it is
    /// how WS reaches the worker once the front terminates the
    /// handshake at the edge.
    extended_connect: bool = false,
    /// Surface h1 `Upgrade: websocket` heads to the consumer instead of
    /// auto-completing the handshake (architecture/websockets.md, the front
    /// door): each valid Upgrade emits a `ws_upgrade_out` entity
    /// (Session = conn, ReqHeaders = the head) and the connection
    /// parks until `wsUpgradeAccept(ent, sink)` — deferred 101 +
    /// raw-relay tunnel mode — or `wsUpgradeReject(ent, status)`.
    /// Mutually exclusive with `websocket_upgrades` (surface wins).
    websocket_surface: bool = false,
    /// Accept HTTP/1.1 on server connections (the plaintext first-read
    /// sniff / ALPN-h1). The rewind worker turns this OFF
    /// (architecture/websockets.md): h1 termination is the front's job alone —
    /// every byte that reaches a worker is h2c. An h1-looking first
    /// read just closes (the firewall-bounded private network has no
    /// legitimate h1 speakers).
    accept_http1: bool = true,
};

// =============================================================================
// H2 — HTTP/2 runtime
// =============================================================================

pub fn H2(comptime opts: Options) type {
    const rows = RowsFor(opts);
    const stream_row = rows.stream;
    const connect_row_full = rows.connect_full;
    const full_conn_row = rows.full_conn;

    const has_client = opts.client;

    comptime {
        if (opts.world == null and rove.declared_world == null) @compileError(
            "rove-h2: no declared world — declare `pub const rove_world = rove.World(.{ .parts = rh2.parts(opts) })` in the binary's root module, or pass `.world` explicitly (tests' mini-worlds)",
        );
    }

    // Rove-io type for this h2 configuration — see `ioOptions` for what
    // this layer derives.
    const IoType = rio.Io(ioOptions(opts));

    // WebSocket seam row (docs/architecture/websockets.md): one entity per inbound
    // completed message (`ws_message_out`) or outbound frame (`ws_send_in`).
    // Carries the connection (`Session`), the payload (`ReqBody`), the opcode
    // (`WsMeta`), and an error slot (`H2IoResult`), plus the worker's
    // `request_row` so piece D can attach per-activation state — mirroring how
    // `stream_row` merges it for normal requests.
    const ws_row = rows.ws_seam;

    // Collection types (for comptime)
    const StreamColl = Collection(stream_row, .{});
    const ReadColl = Collection(rio.ReadBaseRow, .{});
    const ConnColl = Collection(full_conn_row, .{});
    const WsColl = Collection(ws_row, .{});

    const ClientConnectColl = if (has_client) Collection(connect_row_full, .{}) else void;
    const ClientStreamColl = if (has_client) Collection(stream_row, .{}) else void;
    const DeadColl = Collection(Row(&.{}), .{});

    // The declared world — same resolution as rove-io: the explicit
    // option wins, the root's `rove_world` is the fallback (required;
    // checked above).
    const maybe_world: ?type = if (opts.world) |W| W else rove.declared_world;
    const WorldT = maybe_world.?;

    comptime {
        for (COLLECTIONS) |s| {
            if (s.client_only and !has_client) continue;
            checkWorldColl(WorldT, s.name, Collection(collRowFor(opts, s.kind), .{}));
        }
    }

    return struct {
        const Self = @This();

        // Public row types (for external access)
        pub const StreamRow = stream_row;
        pub const ConnectionRow = full_conn_row;

        /// The registry type this instantiation runs on (crystallized by
        /// rove-io from the folded universe; re-exported here so the
        /// composing layer writes `MyH2.Reg` without knowing the layers).
        pub const Reg = IoType.Reg;

        // The io instance (heap-allocated by rio.Io.create)
        io: *IoType,

        // ── Collections, grouped by the poll phase that drives them ──
        // (§4.5: the field ORDER is the poll loop's shape. Phase names
        // are `poll`'s: 1 = consume user inputs (pollPrelude), 2 = drive
        // nghttp2 sends, 3 = io.poll, 4 = read triage / conn transitions
        // (pollPostlude), 5 = readsFeedData → nghttp2 callbacks emit
        // entities. `*_out` = h2 produces, the consumer reads between
        // polls; `*_in` = the consumer produces, Phase 1 drains;
        // `_underscore` collections are h2-internal parking.)

        // Server request/response: Phase 5 emits `request_out` (+ the
        // headers_first receiving/buffering stopovers); the consumer
        // answers on `response_in`, drained by Phase 1's
        // `consumeResponses` and shipped by Phase 2.
        request_out: CollField(StreamColl),
        // headers_first early-emission pipeline (h2_opts.headers_first
        // doc). A request entity whose body is still inbound lives in
        // `request_receiving` (fresh — consumer hasn't decided) or
        // `request_buffering` (consumer called `requestBodyBuffer`);
        // h2 attaches the accumulated body and moves it to
        // `request_out` when END_STREAM lands, so `request_out` keeps
        // its body-complete contract. Always-empty when headers_first
        // is off.
        request_receiving: CollField(StreamColl),
        request_buffering: CollField(StreamColl),
        response_in: CollField(StreamColl),
        response_out: CollField(StreamColl),
        _response_sending: CollField(StreamColl),

        // Streaming responses: consumer feeds `stream_response_in` /
        // `stream_data_in` / `stream_close_in`; Phase 1's
        // `consumeStream*` drain them; `stream_data_out` is the
        // "push the next piece" signal back to the consumer, released
        // by write completions (`writesAccount`) — one write in
        // flight per stream is the backpressure.
        stream_response_in: CollField(StreamColl),
        stream_data_out: CollField(StreamColl),
        stream_data_in: CollField(StreamColl),
        stream_close_in: CollField(StreamColl),
        _stream_data_sending: CollField(StreamColl),

        // WebSocket seam (docs/architecture/websockets.md). `ws_message_out` holds a
        // completed inbound message for the consumer (piece D → `onMessage`);
        // `ws_send_in` holds an outbound frame the consumer queued (piece E ←
        // `stream.write`). Outbound backpressure is on the per-conn ws arm's
        // `WsWrite.out` byte queue + `write_inflight` (one socket write at a
        // time), not on
        // these entities — so control frames (pong/close) interleave with data
        // frames in wire order, which a per-entity `sending_entity` can't model.
        ws_message_out: CollField(WsColl),
        ws_send_in: CollField(WsColl),

        // Extended-CONNECT WS identity entities (architecture/websockets.md,
        // `extended_connect` instances only). One entity per WS-over-h2
        // stream (Session = conn, StreamId, ReqHeaders = the CONNECT
        // headers). `ws_connect_out`: awaiting the consumer's
        // disposition (`wsConnectAccept` / `wsConnectReject`).
        // `ws_streams`: live tunnels — the entity IS the logical WS
        // connection identity the consumer keys its state by (the h2
        // mirror of the h1 conn entity); destroyed at stream close.
        ws_connect_out: CollField(StreamColl),
        ws_streams: CollField(StreamColl),
        // websocket_surface instances (the front): h1 Upgrade heads
        // awaiting the consumer's disposition (`wsUpgradeAccept` /
        // `wsUpgradeReject`). Session = conn, ReqHeaders = the head.
        ws_upgrade_out: CollField(StreamColl),

        // Read triage (h2-internal): Phase 4 `readsTriage` routes each
        // completed read here by connection state; Phase 5 feeds
        // `_read_active` data to the parsers.
        _read_errors: CollField(ReadColl),
        _read_init: CollField(ReadColl),
        _read_active: CollField(ReadColl),
        _read_handshake: CollField(ReadColl),
        // h1 inbound-body backpressure: the conn's read entity parks here
        // (instead of re-arming via io.read_in) while streamed body bytes
        // have outrun the consumer; `http1UnparkRead` re-arms it. At most
        // one entry per h1 conn (`Http1Conn.paused_read`).
        _read_h1_paused: CollField(ReadColl),

        // Connection pipeline (h2-internal): Phase 4 transitions
        // accepted conns through TLS handshake into active.
        _conn_tls_handshake: CollField(ConnColl),
        _conn_active: CollField(ConnColl),

        // Client connect lifecycle (client instances): consumer feeds
        // `client_connect_in` (Phase 1 drains); Phase 4's
        // `processConnectResults`/`Errors` emit `_out`/`_errors`.
        client_connect_in: CollField(ClientConnectColl),
        client_connect_out: CollField(ClientConnectColl),
        client_connect_errors: CollField(ClientConnectColl),
        _client_connect_pending: CollField(ClientConnectColl),

        // Client request/response (client instances): consumer feeds
        // `client_request_in` (Phase 1); Phase 5 emits
        // `client_response_out` (+ the client_headers_first
        // receiving stopover).
        client_request_in: CollField(ClientStreamColl),
        client_response_out: CollField(ClientStreamColl),
        _client_request_sending: CollField(ClientStreamColl),
        // client_headers_first early-emission output (see the
        // `H2Options.client_headers_first` doc): one FRESH entity per
        // streaming response's HEADERS (Status + RespHeaders + Session
        // + StreamId). Consumer-owned — read it, attach a body sink
        // via `requestBodySink`, destroy it. Always-empty when
        // client_headers_first is off.
        client_response_receiving: CollField(ClientStreamColl),

        // Client streaming (client instances): same shape as the
        // server streaming group, mirrored (consumer-fed `_in`s
        // drained by Phase 1; `_out` released by write completions).
        client_stream_request_in: CollField(ClientStreamColl),
        client_stream_data_out: CollField(ClientStreamColl),
        client_stream_data_in: CollField(ClientStreamColl),
        client_stream_close_in: CollField(ClientStreamColl),
        _client_stream_data_sending: CollField(ClientStreamColl),
        /// The stream dead-letter (fat model; empty and unused under the
        /// archetype, whose deinit hooks free at destroy): every h2-owned
        /// entity ends by moving here — `destroyEntity` routes it, even
        /// mid-move — and `processStreamDead` frees the four buffer
        /// components and destroys, at a known phase outside nghttp2's
        /// callbacks.
        _stream_dead: CollField(DeadColl),

        h2_opts: H2Options,
        reg: *Reg,
        allocator: std.mem.Allocator,


        // ENOBUFS-on-recv tracking. The kernel returns ENOBUFS when
        // the io_uring registered buffer pool (`buf_count`) is empty
        // at recv time. Treated as back-pressure: the connection is
        // re-armed rather than dropped, with a warning on first
        // occurrence and every 10k events thereafter so the
        // misconfiguration is visible.
        recv_enobufs_total: u64 = 0,
        /// Connections destroyed for blowing the TLS handshake budget
        /// (`tls_handshake_timeout_ns`) — the slowloris canary: a
        /// climbing rate under normal load means someone is holding
        /// slots open with stalled handshakes.
        handshake_reaped_total: u64 = 0,
        recv_enobufs_logged: bool = false,
        recv_enobufs_last_logged_decade: u64 = 0,
        /// Server-side response counts by HTTP status CLASS, indexed
        /// [0]=other(<100) [1]=1xx [2]=2xx [3]=3xx [4]=4xx [5]=5xx — the RED
        /// error-rate signal (the serving-path metric the consensus/io gauges
        /// don't cover). NO per-route/tenant labels (the active-series rule), just
        /// the 6 bounded classes. Bumped in `consumeResponses` for every
        /// response emitted to a client (h1 + h2); read by `writeConnMetrics`
        /// on the SAME poll-loop thread, so plain counters (no atomics). On the
        /// front these are the client-facing statuses it relays (a failed
        /// upstream forward surfaces here as a 5xx).
        http_status_class: [6]u64 = .{ 0, 0, 0, 0, 0, 0 },
        /// Per-status counters for the hand-picked `NOTABLE_STATUS` set
        /// (rove#216) — same single-thread, no-atomics discipline as
        /// `http_status_class`. Rendered as `http_responses_status_total`.
        http_status_notable: [NOTABLE_STATUS.len]u64 = .{0} ** NOTABLE_STATUS.len,
        /// Consecutive `readsTriage` calls where ENOBUFS fired but
        /// `outstanding` was below half of `buf_count`. Three in a
        /// row aborts the process — see the panic check in
        /// `readsTriage`. Cleared whenever the surfacing condition
        /// stops holding (so a one-time blip during boot doesn't
        /// trip the abort).
        recv_enobufs_low_outstanding_streak: u32 = 0,

        /// Active `.sink` streams (`requestBodySink`). The sweep
        /// repays flow-control window as each sink drains, and is the
        /// single release point for h2's sink reference — it detects
        /// dead streams (closed normally OR torn down with the
        /// connection, where no close callback fires) and releases
        /// exactly once.
        body_sinks: std.ArrayListUnmanaged(SinkRef) = .empty,

        const SinkRef = struct {
            conn_entity: Entity,
            stream_id: i32,
            sink: BodySink,
        };

        // Shared nghttp2 callbacks — one per H2 instantiation
        var ng_callbacks: ?*c.nghttp2_session_callbacks = null;
        var ng_client_callbacks: ?*c.nghttp2_session_callbacks = null;
        // Server session option for headers_first instances:
        // NO_AUTO_WINDOW_UPDATE, so inbound body flow control is the
        // explicit `nghttp2_session_consume` calls in
        // `onDataChunkRecvCb` / `requestBodyBuffer`. Created once,
        // only when the first headers_first session comes up.
        var ng_server_option: ?*c.nghttp2_option = null;
        // Client mirror for client_headers_first sessions.
        var ng_client_option: ?*c.nghttp2_option = null;

        /// Connection-level recv window for headers_first /
        /// client_headers_first sessions. With manual window
        /// management, every `.hold`/`.sink` stream's unconsumed bytes
        /// are debt against BOTH its stream window and the shared
        /// connection window. The stream window (65535 default) bounds
        /// per-stream buffering — that's the backpressure we want. But
        /// at the default 64 KiB CONNECTION window, a single held
        /// stream wedges every other stream on the connection — fatal
        /// for a proxy multiplexing many clients over one upstream
        /// conn, and for the worker receiving that conn. Raise the
        /// connection window so per-stream holds stay independent
        /// (~256 concurrently-held streams before connection-level
        /// pushback).
        const HELD_CONN_RECV_WINDOW: i32 = 16 * 1024 * 1024;

        // =============================================================
        // COLLECTIONS (file scope) — single source of truth for the
        // collection fields above. Drives init, registerCollection,
        // deinit, the `Coll` enum + chain lookups, and `parts`, so
        // adding a collection is a one-line spec change rather than
        // edits in 4–6 places.
        // =============================================================

        /// The storage type behind a spec's kind, in this instantiation.
        fn CollTypeOf(comptime kind: CollKind) type {
            return switch (kind) {
                .io => @compileError("io-owned entries have no h2 storage type"),
                .server_stream => StreamColl,
                .server_read => ReadColl,
                .server_conn => ConnColl,
                .server_ws => WsColl,
                .client_connect => ClientConnectColl,
                .client_stream => ClientStreamColl,
                .dead => DeadColl,
            };
        }

        /// Collection storage per model: registry-owned (a stable
        /// pointer fetched at `create`) under a declared world, an
        /// h2 field otherwise.
        fn CollField(comptime C: type) type {
            if (C == void) return void;
            return *C;
        }

        /// Pointer to one of h2's collections — the storage is the
        /// registry's; these fields carry its stable pointers.
        pub inline fn coll(self: *Self, comptime name: @TypeOf(.enum_literal)) @FieldType(Self, @tagName(name)) {
            return @field(self, @tagName(name));
        }

        // =============================================================
        // Coll — the collection set as declared VALUES
        // =============================================================
        // `COLLECTIONS` names every collection; this enum gives those names
        // VALUES, and the registry ids are declared off it. That is what
        // makes an entity's collection readable rather than merely testable:
        // `collectionOf` is a cast over the registry's `collection_ids` byte,
        // and a `switch` on the result recovers the typed collection pointer.
        // An id assigned from a counter is anonymous, and recovering the
        // collection from one means walking a candidate list per call site.

        /// The collections live in THIS instantiation. `client_only` specs
        /// drop out when the instance has no client half, so `Coll` never
        /// names a field whose type is `void`.
        /// Which layer owns the field a variant names.
        const Owner = enum { io, h2 };

        /// A variant's backing collection, flattened across both layers.
        const CollRef = struct {
            name: [:0]const u8,
            owner: Owner,
            kind: CollKind,
            in_chain: bool = false,
        };

        /// io's collections followed by this instance's. The merge mirrors
        /// `Row.merge`: io publishes its set, the upper layer extends it —
        /// except the enum flows back DOWN as the shared interpretation of
        /// the registry's `collection_ids` byte.
        const ACTIVE: []const CollRef = blk: {
            var out: []const CollRef = &.{};
            for (rio.COLLECTIONS) |ic| {
                if (ic.connect_only and !has_client) continue;
                out = out ++ &[_]CollRef{.{
                    .name = ic.name,
                    .owner = .io,
                    .kind = .io,
                }};
            }
            for (COLLECTIONS) |hc| {
                if (hc.client_only and !has_client) continue;
                out = out ++ &[_]CollRef{.{
                    .name = hc.name,
                    .owner = .h2,
                    .kind = hc.kind,
                    .in_chain = hc.in_chain,
                }};
            }
            break :blk out;
        };

        /// One namespace over the shared registry: the world's table IS
        /// the enum, valued by registry id directly — io's entries, this
        /// layer's, and any composing layer's own parts.
        pub const Coll = WorldT.CollId;

        /// The `CollRef` behind a variant, or null when the variant belongs
        /// to the composing layer — this layer can name those collections
        /// but owns none of them, so every accessor here declines them.
        fn specOf(comptime k: Coll) ?CollRef {
            // By name — the world table's numbering is not ACTIVE's
            // order; the names are the stable identity. A variant not
            // in ACTIVE (a composer's collection, or a world set entry)
            // is declined.
            @setEvalBranchQuota(1_000_000);
            inline for (ACTIVE) |a| {
                if (comptime std.mem.eql(u8, a.name, @tagName(k))) return a;
            }
            return null;
        }

        /// The field behind a variant this layer owns, on whichever of the
        /// two layers holds it. Only called from an arm that has already
        /// established `specOf(k) != null`.
        inline fn fieldOf(h2: *Self, comptime k: Coll) @FieldType(
            if (specOf(k).?.owner == .io) IoType else Self,
            specOf(k).?.name,
        ) {
            const s = comptime specOf(k).?;
            return if (comptime s.owner == .io) @field(h2.io, s.name) else @field(h2, s.name);
        }

        /// The collection an entity is in, as a value.
        ///
        /// Named for what it returns, not for what the design reads into it.
        /// Collection membership IS how lifecycle state is encoded here, but
        /// that is a property of most of these collections, not all: some are
        /// pipeline phases (`request_receiving` → `request_buffering`), some
        /// are seams a consumer drains (`response_in`, `ws_send_in`), and some
        /// are identity homes (`ws_streams`). "Collection" is the part that is
        /// uniformly true.
        ///
        /// Null when the handle is stale or out of range, or when the entity
        /// sits in a collection registered by a layer ABOVE this one — those
        /// share the registry but are not in `Coll`.
        pub fn collectionOf(h2: *const Self, entity: Entity) ?Coll {
            const core = &h2.reg.core;
            const idx = entity.index;
            if (idx >= core.max_entities) return null;
            if (core.generations[idx] != entity.generation) return null;
            const raw = core.collection_ids[idx];
            // 0 is the registry's free pool and is never a collection;
            // `CollId` is valued by registry id directly.
            if (raw == 0) return null;
            return @enumFromInt(raw);
        }

        /// The server-stream chain collection a state names, or null if the
        /// state is not one. `inline else` makes this a jump table over
        /// `Coll` — the typed `getCollection` an anonymous `registry_id`
        /// cannot express, and what replaces walking a candidate list.
        inline fn serverChainColl(h2: *Self, k: Coll) ?*StreamColl {
            return switch (k) {
                inline else => |tag| blk: {
                    const s = comptime specOf(tag) orelse break :blk null;
                    if (comptime s.kind == .server_stream and s.in_chain) {
                        break :blk @field(h2, s.name);
                    } else {
                        break :blk null;
                    }
                },
            };
        }


        /// Client mirror of `serverChainColl`.
        inline fn clientChainColl(h2: *Self, k: Coll) ?*ClientStreamColl {
            return switch (k) {
                inline else => |tag| blk: {
                    const s = comptime specOf(tag) orelse break :blk null;
                    if (comptime s.kind == .client_stream and s.in_chain) {
                        break :blk @field(h2, s.name);
                    } else {
                        break :blk null;
                    }
                },
            };
        }


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

        /// All collections a connection entity can be in (io's + h2's).
        /// The collections a LIVE conn can be in — the sources `closeConn`
        /// moves from. `conn_closing` is deliberately absent: it is the
        /// destination, never a source.
        inline fn liveConnColls(h2: *Self) struct { @TypeOf(h2.io.coll(.connections)), *ConnColl, *ConnColl } {
            return .{ h2.io.coll(.connections), h2.coll(._conn_tls_handshake), h2.coll(._conn_active) };
        }

        /// Every collection a conn entity can be in, closing included — a
        /// completion that lands after the move still has to resolve its
        /// conn. Derived from `liveConnColls` so the two cannot drift.
        inline fn connColls(h2: *Self) struct { @TypeOf(h2.io.coll(.connections)), *ConnColl, *ConnColl, @TypeOf(h2.io.coll(.conn_closing)) } {
            const live = h2.liveConnColls();
            return live ++ .{h2.io.coll(.conn_closing)};
        }

        /// End a connection. h2 decides a conn should stop; io ends it —
        /// so this routes the entity into io's `conn_closing` seam and
        /// never calls `reg.destroy`. io created the conn in
        /// `handleAccept`, so io is what releases its descriptor slot.
        ///
        /// The ending is `evictOnly` — deferred, entity-keyed, and
        /// NEVER refused: a conn mid-move has its queued op land first
        /// and is then collected from wherever it landed, so no caller
        /// records a retry and no retry pass exists. The quiesce drops
        /// every state-axis membership an upper layer gave the conn,
        /// unnamed here; identity memberships (all_conns) survive.
        /// Always returns true once the conn is ending (or already
        /// ended); the bool remains for callers that check it.
        pub fn closeConn(h2: *Self, entity: Entity) bool {
            // Already ending (or ended): done, not an error. conn_dead
            // must not be re-collected into conn_closing.
            if (h2.reg.isInCollection(entity, h2.io.coll(.conn_closing))) return true;
            if (h2.reg.isInCollection(entity, h2.io.coll(.conn_dead))) return true;

            h2.reg.evictOnly(entity, h2.io.coll(.conn_closing)) catch |err| switch (err) {
                // Already gone: nothing holds a slot, so the conn is ended.
                error.Stale, error.InvalidEntity => return true,
                else => {
                    std.log.err("h2: closeConn could not queue conn {d}'s ending — {s}", .{ entity.index, @errorName(err) });
                    return false;
                },
            };
            return true;
        }

        /// Set H2IoResult on a server stream entity and move it to
        /// response_out. The entity's collection is READ, not searched.
        fn serverStreamClose(h2: *Self, entity: Entity, err: i32) void {
            const k = h2.collectionOf(entity) orelse return;
            const src = h2.serverChainColl(k) orelse return;
            h2.reg.set(entity, src, H2IoResult, .{ .err = err }) catch {};
            h2.reg.move(entity, src, h2.coll(.response_out)) catch {};
        }

        /// Set a component on a stream entity in whichever chain it is in.
        fn streamSet(h2: *Self, entity: Entity, comptime T: type, value: T) void {
            const k = h2.collectionOf(entity) orelse return;
            if (h2.serverChainColl(k)) |src| {
                h2.reg.set(entity, src, T, value) catch {};
                return;
            }
            if (comptime has_client) {
                if (h2.clientChainColl(k)) |src| {
                    h2.reg.set(entity, src, T, value) catch {};
                }
            }
        }

        /// Find the current collection of a client stream entity, set H2IoResult, and move to client_response_out.
        fn clientStreamClose(h2: *Self, entity: Entity, err: i32, head_written: bool) void {
            if (comptime !has_client) return;
            const k = h2.collectionOf(entity) orelse return;
            const src = h2.clientChainColl(k) orelse return;
            h2.reg.set(entity, src, H2IoResult, .{ .err = err, .head_written = head_written }) catch {};
            h2.reg.move(entity, src, h2.coll(.client_response_out)) catch {};
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
            for ([_]*StreamColl{ h2.coll(.request_receiving), h2.coll(.request_out) }) |cl| {
                if (h2.reg.isInCollection(ent, cl)) {
                    const sess = h2.reg.get(ent, cl, Session) catch return .gone;
                    const sid = h2.reg.get(ent, cl, StreamId) catch return .gone;

                    const conn_ptr = getConn(h2, sess.entity) orelse return .gone;

                    // h1 streaming body: the conn's in-flight Stream plays
                    // the nghttp2 user-data role. "Re-opening the window" =
                    // committing to the body: send the gated 100 Continue
                    // and re-arm a parked read.
                    if (conn_ptr.h1) |h1c| {
                        const hst = switch (h1c.state) {
                            .http1 => |*hst| hst,
                            else => return .gone,
                        };
                        const s = hst.stream orelse return .gone;
                        if (!s.entity.eql(ent)) return .gone;
                        if (s.inbound_eof) {
                            h2.reg.set(ent, cl, ReqBody, takeBody(s)) catch return .gone;
                            return .body_complete;
                        }
                        s.body_mode = .buffer;
                        s.unconsumed = 0;
                        h2.http1MaybeContinueStored(conn_ptr, sess.entity);
                        h2.http1UnparkRead(h1c);
                        h2.reg.move(ent, cl, h2.coll(.request_buffering)) catch return .gone;
                        return .buffering;
                    }

                    const ng_session = conn_ptr.ng_session orelse return .gone;
                    const stream: ?*Stream = @ptrCast(@alignCast(
                        c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                    ));
                    const s = stream orelse return .gone;

                    if (s.inbound_eof) {
                        h2.reg.set(ent, cl, ReqBody, takeBody(s)) catch return .gone;
                        return .body_complete;
                    }
                    s.body_mode = .buffer;
                    if (s.unconsumed > 0) {
                        _ = c.nghttp2_session_consume(ng_session, @intCast(sid.id), s.unconsumed);
                        s.unconsumed = 0;
                    }
                    h2.reg.move(ent, cl, h2.coll(.request_buffering)) catch return .gone;
                    return .buffering;
                }
            }
            return .gone;
        }

        /// `requestBodySink` outcome.
        pub const SinkAttach = enum {
            /// DATA is flowing to the sink; END_STREAM will `finish`.
            streaming,
            /// The body had already fully arrived — the sink received
            /// everything (buffered bytes + `finish`) during this call.
            eof,
            /// The stream is gone; the sink got nothing and the caller
            /// should abort the job. h2 holds NO reference.
            gone,
        };

        /// Attach a body sink (the `blob.receive` upload driver) to an
        /// early-emitted request's stream, identified by its Session
        /// conn entity + StreamId (the request entity may be parked
        /// anywhere by now — a held continuation — so identity, not
        /// collection membership, addresses the stream). Bytes already
        /// buffered under `.hold` are pushed first; their window debt
        /// is repaid by `sweepBodySinks` as the sink drains, so the
        /// client's send rate follows the upload rate end to end. On
        /// any non-`.gone` return h2 holds one sink reference,
        /// released by the sweep when the stream dies.
        pub fn requestBodySink(h2: *Self, conn_entity: Entity, stream_id: u32, sink: BodySink) SinkAttach {
            // Also serves client_headers_first consumers — the sink
            // machinery (mode switch, sweep, window repayment) is
            // direction-agnostic; the stream is addressed the same way.
            if (!h2.h2_opts.headers_first and !h2.h2_opts.client_headers_first) return .gone;
            const conn_ptr = getConn(h2, conn_entity) orelse return .gone;

            // h1 streaming body: same attach contract, with read re-arm in
            // place of window repayment (the sweep paces reads off
            // `drained` exactly as it repays h2 window).
            if (conn_ptr.h1) |h1c| {
                const hst = switch (h1c.state) {
                    .http1 => |*hst| hst,
                    else => return .gone,
                };
                const s = hst.stream orelse return .gone;
                if (s.ng_stream_id != @as(i32, @intCast(stream_id))) return .gone;
                if (s.body_data) |p| {
                    if (s.body_len > 0) {
                        if (!sink.push(sink.ctx, p[0..s.body_len])) return .gone;
                    }
                    s.allocator.free(p[0..s.body_cap]);
                    s.body_data = null;
                    s.body_len = 0;
                    s.body_cap = 0;
                }
                h2.body_sinks.append(h2.allocator, .{
                    .conn_entity = conn_entity,
                    .stream_id = @intCast(stream_id),
                    .sink = sink,
                }) catch return .gone;
                s.sink = sink;
                s.body_mode = .sink;
                if (s.inbound_eof) {
                    sink.finish(sink.ctx);
                    s.sink_finished = true;
                    return .eof;
                }
                h2.http1MaybeContinueStored(conn_ptr, conn_entity);
                h2.http1UnparkRead(h1c);
                return .streaming;
            }

            const ng_session = conn_ptr.ng_session orelse return .gone;
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(ng_session, @intCast(stream_id)),
            ));
            const s = stream orelse return .gone;

            // Hand over whatever buffered under `.hold`. The sink
            // copies; any held window debt stays on `unconsumed` and
            // is repaid by the sweep as the sink reports drainage.
            if (s.body_data) |p| {
                if (s.body_len > 0) {
                    if (!sink.push(sink.ctx, p[0..s.body_len])) return .gone;
                }
                s.allocator.free(p[0..s.body_cap]);
                s.body_data = null;
                s.body_len = 0;
                s.body_cap = 0;
            }

            h2.body_sinks.append(h2.allocator, .{
                .conn_entity = conn_entity,
                .stream_id = @intCast(stream_id),
                .sink = sink,
            }) catch return .gone;
            s.sink = sink;
            s.body_mode = .sink;

            if (s.inbound_eof) {
                sink.finish(sink.ctx);
                s.sink_finished = true;
                return .eof;
            }
            return .streaming;
        }

        /// Repay flow-control window on `.sink` streams as their
        /// drivers drain, and release h2's sink reference when the
        /// stream dies (the SOLE release point — covers both normal
        /// close and connection teardown, where nghttp2 fires no
        /// per-stream close callback). The job-side `abort` is
        /// idempotent, so the belt-and-braces abort here is safe
        /// after a close-path abort already ran.
        fn sweepBodySinks(self: *Self) void {
            var i: usize = 0;
            while (i < self.body_sinks.items.len) {
                const ref = &self.body_sinks.items[i];
                // Resolve the live stream this ref still drives: h2 via
                // nghttp2 stream user data; h1 via the conn's in-flight
                // Stream — where a ctx mismatch means a NEW request's sink
                // already replaced this one on the synthetic stream id (the
                // old request's cycle is over → release this ref).
                var ng: ?*c.nghttp2_session = null;
                var h1c: ?*Http1Conn = null;
                const live: ?*Stream = blk: {
                    const conn_ptr = getConn(self, ref.conn_entity) orelse break :blk null;
                    if (conn_ptr.h1) |h| {
                        h1c = h;
                        // stream_id 0 = h1 tunnel sink (wsUpgradeAccept):
                        // repay = read unpark off `tunnel_unconsumed`;
                        // no Stream involved.
                        if (ref.stream_id == 0) {
                            const tn = switch (h.state) {
                                .ws_tunnel => |*tn| tn,
                                else => break :blk null,
                            };
                            if (tn.sink.ctx != ref.sink.ctx) break :blk null;
                            const delta = ref.sink.drained(ref.sink.ctx);
                            if (delta > 0) tn.unconsumed -|= @min(delta, tn.unconsumed);
                            if (tn.unconsumed < Http1Conn.STREAM_PAUSE_BYTES) self.http1UnparkRead(h);
                            i += 1;
                            continue;
                        }
                        const hst = switch (h.state) {
                            .http1 => |*hst| hst,
                            else => break :blk null,
                        };
                        const s = hst.stream orelse break :blk null;
                        const sk = s.sink orelse break :blk null;
                        if (sk.ctx != ref.sink.ctx) break :blk null;
                        break :blk s;
                    }
                    ng = conn_ptr.ng_session orelse break :blk null;
                    const st: ?*Stream = @ptrCast(@alignCast(
                        c.nghttp2_session_get_stream_user_data(ng.?, ref.stream_id),
                    ));
                    const s = st orelse break :blk null;
                    if (s.sink == null) break :blk null;
                    break :blk s;
                };
                if (live) |s| {
                    const delta = ref.sink.drained(ref.sink.ctx);
                    if (delta > 0 and s.unconsumed > 0) {
                        const repay = @min(delta, s.unconsumed);
                        if (ng) |sess| _ = c.nghttp2_session_consume(sess, ref.stream_id, repay);
                        s.unconsumed -= repay;
                    }
                    // h1 window repayment = re-arming the socket read.
                    if (h1c) |h| {
                        if (s.unconsumed < Http1Conn.STREAM_PAUSE_BYTES) self.http1UnparkRead(h);
                    }
                    i += 1;
                    continue;
                }
                ref.sink.abort(ref.sink.ctx);
                ref.sink.release(ref.sink.ctx);
                _ = self.body_sinks.swapRemove(i);
            }
        }

        /// Abort an upstream (client-direction) stream: RST_STREAM with
        /// CANCEL. The proxy uses this to abandon an attempt (a 421
        /// re-aim, a downstream that died mid-upload) without
        /// half-closing — a clean END_STREAM would make the peer treat
        /// a truncated body as complete. The reset surfaces through
        /// `onStreamCloseClientCb` → the request entity lands in
        /// `client_response_out` with `err != 0`.
        pub fn clientStreamReset(h2: *Self, conn_entity: Entity, stream_id: u32) void {
            if (!has_client) return;
            const conn_ptr = getConn(h2, conn_entity) orelse return;
            const ng = conn_ptr.ng_session orelse return;
            _ = c.nghttp2_submit_rst_stream(ng, c.NGHTTP2_FLAG_NONE, @intCast(stream_id), c.NGHTTP2_CANCEL);
        }

        /// Abort a server-direction stream whose response can no longer
        /// complete (the proxy's upstream died mid-relay). h2: RST so
        /// the client sees a hard stream error, never a clean
        /// END_STREAM on a truncated body. h1: there is no mid-response
        /// abort signal — destroy the connection (a chunked body with
        /// no terminator IS the truncation signal).
        pub fn serverStreamAbort(h2: *Self, conn_entity: Entity, stream_id: u32) void {
            const conn_ptr = getConn(h2, conn_entity) orelse return;
            if (conn_ptr.h1 != null) {
                _ = h2.closeConn(conn_entity);
                return;
            }
            const ng = conn_ptr.ng_session orelse return;
            _ = c.nghttp2_submit_rst_stream(ng, c.NGHTTP2_FLAG_NONE, @intCast(stream_id), c.NGHTTP2_INTERNAL_ERROR);
        }

        pub fn wsConnRouting(h2: *Self, conn_entity: Entity) ?struct { authority: []const u8, path: []const u8 } {
            const cp = getConn(h2, conn_entity) orelse return null;
            const h1c = cp.h1 orelse return null;
            return switch (h1c.state) {
                .ws_framed => |*fr| .{ .authority = fr.authority, .path = fr.path },
                else => null,
            };
        }

        // ── Extended-CONNECT WS (architecture/websockets.md) ─────────────────

        /// Routing for a WS identity entity (h2 tunnel): `:authority` /
        /// `:path` straight off the CONNECT headers. Valid while the
        /// entity lives (`ws_connect_out` pre-accept, `ws_streams`
        /// after); borrowed slices — the consumer dupes what it keeps.
        pub fn wsStreamRouting(h2: *Self, ws_ent: Entity) ?struct { authority: []const u8, path: []const u8 } {
            for ([_]*StreamColl{ h2.coll(.ws_streams), h2.coll(.ws_connect_out) }) |cl| {
                if (!h2.reg.isInCollection(ws_ent, cl)) continue;
                const rh = h2.reg.get(ws_ent, cl, ReqHeaders) catch return null;
                const fields = rh.fields orelse return null;
                var authority: ?[]const u8 = null;
                var path: ?[]const u8 = null;
                for (fields[0..rh.count]) |f| {
                    const name = f.name[0..f.name_len];
                    if (std.mem.eql(u8, name, ":authority")) authority = f.value[0..f.value_len];
                    if (std.mem.eql(u8, name, ":path")) path = f.value[0..f.value_len];
                }
                return .{ .authority = authority orelse return null, .path = path orelse return null };
            }
            return null;
        }

        /// Resolve a WS identity entity to its live nghttp2 stream.
        fn wsStreamOf(h2: *Self, cl: *StreamColl, ws_ent: Entity) ?struct { ng: *c.nghttp2_session, sid: i32, s: *Stream } {
            const sess = h2.reg.get(ws_ent, cl, Session) catch return null;
            const sid = h2.reg.get(ws_ent, cl, StreamId) catch return null;
            const conn_ptr = getConn(h2, sess.entity) orelse return null;
            const ng = conn_ptr.ng_session orelse return null;
            const st: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(ng, @intCast(sid.id)),
            ));
            const s = st orelse return null;
            return .{ .ng = ng, .sid = @intCast(sid.id), .s = s };
        }

        /// True when the peer of a CLIENT connection advertised RFC 8441
        /// Extended CONNECT (`SETTINGS_ENABLE_CONNECT_PROTOCOL`). A
        /// client MUST observe the setting before submitting a
        /// `:protocol` CONNECT — the front gates tunnel opens on this.
        pub fn connExtendedConnect(h2: *Self, conn_entity: Entity) bool {
            const conn_ptr = getConn(h2, conn_entity) orelse return false;
            const ng = conn_ptr.ng_session orelse return false;
            return c.nghttp2_session_get_remote_settings(ng, c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL) == 1;
        }

        /// Peer (remote) socket address of a connection entity, via
        /// getpeername on its fd. Null when the entity or fd is gone.
        /// Used by the front door to stamp `x-forwarded-for` at the
        /// trust boundary (front-door hardening plan B7).
        pub fn connPeerAddr(h2: *Self, conn_entity: Entity) ?std.net.Address {
            if (h2.reg.isStale(conn_entity)) return null;
            const pa = h2.reg.getAny(conn_entity, h2.connColls(), rio.PeerAddr) catch return null;
            if (!pa.valid) return null;
            return pa.addr;
        }

        /// True when the connection is driven by the HTTP/1.1 codec
        /// (vs an nghttp2 session). Feeds the front door's `Via`
        /// received-protocol version.
        pub fn connIsHttp1(h2: *Self, conn_entity: Entity) bool {
            const conn_ptr = getConn(h2, conn_entity) orelse return false;
            return conn_ptr.h1 != null;
        }

        pub const WsConnectDecision = enum { ok, gone };

        /// Accept a pending Extended-CONNECT tunnel: reply `:status
        /// 200` (no END_STREAM — the open-ended WS body), attach the
        /// frame reassembler, hand over any pre-accept held bytes +
        /// repay their window debt, and move the identity entity to
        /// `ws_streams`. From here inbound messages surface on
        /// `ws_message_out` and `ws_send_in` frames ship back.
        pub fn wsConnectAccept(h2: *Self, ws_ent: Entity) WsConnectDecision {
            if (!h2.reg.isInCollection(ws_ent, h2.coll(.ws_connect_out))) return .gone;
            const live = h2.wsStreamOf(h2.coll(.ws_connect_out), ws_ent) orelse return .gone;
            const s = live.s;
            const wr = WsReassembler.create(h2.allocator) orelse return .gone;

            var status_buf: [3]u8 = .{ '2', '0', '0' };
            var nva = [_]c.nghttp2_nv{.{
                .name = @constCast(":status"),
                .namelen = 7,
                .value = &status_buf,
                .valuelen = 3,
                .flags = c.NGHTTP2_NV_FLAG_NONE,
            }};
            var data_prd = c.nghttp2_data_provider{
                .source = .{ .ptr = null },
                .read_callback = &onDataSourceReadCb,
            };
            if (c.nghttp2_submit_response(live.ng, live.sid, &nva, nva.len, &data_prd) != 0) {
                wr.free();
                return .gone;
            }
            s.ws_reasm = wr;
            // Pre-accept bytes buffered under `.hold`: feed them to the
            // parser and repay the held window.
            if (s.body_data) |p| {
                if (s.body_len > 0) {
                    wr.buf.appendSlice(h2.allocator, p[0..s.body_len]) catch {
                        s.ws_reasm = null;
                        wr.free();
                        return .gone;
                    };
                }
                s.allocator.free(p[0..s.body_cap]);
                s.body_data = null;
                s.body_len = 0;
                s.body_cap = 0;
            }
            if (s.unconsumed > 0) {
                _ = c.nghttp2_session_consume(live.ng, live.sid, s.unconsumed);
                s.unconsumed = 0;
            }
            s.body_mode = .auto;
            h2.reg.move(ws_ent, h2.coll(.ws_connect_out), h2.coll(.ws_streams)) catch return .gone;
            h2.wsStreamDrive(live.ng, s);
            return .ok;
        }

        /// Refuse a pending tunnel with an HTTP status (421 = wrong
        /// node, re-aim; 404/403 = no such tenant/handler). The
        /// response carries END_STREAM; the identity entity dies here
        /// (stream close skips it via staleness).
        pub fn wsConnectReject(h2: *Self, ws_ent: Entity, status: u16) void {
            if (!h2.reg.isInCollection(ws_ent, h2.coll(.ws_connect_out))) return;
            if (h2.wsStreamOf(h2.coll(.ws_connect_out), ws_ent)) |live| {
                var status_buf: [3]u8 = undefined;
                const code = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "500";
                var nva = [_]c.nghttp2_nv{.{
                    .name = @constCast(":status"),
                    .namelen = 7,
                    .value = @constCast(code.ptr),
                    .valuelen = code.len,
                    .flags = c.NGHTTP2_NV_FLAG_NONE,
                }};
                _ = c.nghttp2_submit_response(live.ng, live.sid, &nva, nva.len, null);
                // Repay any held pre-accept bytes so the connection
                // window survives the refusal.
                if (live.s.unconsumed > 0) {
                    _ = c.nghttp2_session_consume(live.ng, live.sid, live.s.unconsumed);
                    live.s.unconsumed = 0;
                }
            }
            // Through the stream funnel: the identity entity carries the
            // CONNECT ReqHeaders, which the ending must release.
            h2.destroyEntity(ws_ent) catch {};
        }

        /// Parse buffered inbound tunnel bytes into messages (the h2
        /// mirror of `wsDrive`/`wsHandleFrame`): auto-pong, Close →
        /// opcode-8 message + echo + our-side END, data frames
        /// (+continuations) reassemble onto `ws_message_out` keyed by
        /// the identity entity.
        fn wsStreamDrive(h2: *Self, session: ?*c.nghttp2_session, s: *Stream) void {
            const wr = s.ws_reasm orelse return;
            var resume_send = false;
            var pos: usize = 0;
            drive: while (true) {
                const r = ws.parseFrame(wr.buf.items[pos..], Http1Conn.MAX_WS_MESSAGE) catch {
                    // Protocol error / oversize: close our side; the
                    // peer sees Close + END_STREAM.
                    if (!wr.closing) {
                        ws.writeClose(&wr.send_buf, h2.allocator, ws.CloseCode.protocol_error, "") catch {};
                        wr.closing = true;
                        resume_send = true;
                    }
                    break :drive;
                };
                const frame = switch (r) {
                    .need_more => break :drive,
                    .frame => |f| f,
                };
                switch (frame.opcode) {
                    .ping => {
                        ws.writeFrame(&wr.send_buf, h2.allocator, .pong, frame.payload) catch {};
                        resume_send = true;
                    },
                    .pong => {},
                    .close => {
                        if (!wr.client_closed) {
                            wr.client_closed = true;
                            h2.wsEmitMessage(s.entity, @intFromEnum(ws.Opcode.close), "") catch {};
                        }
                        if (!wr.closing) {
                            ws.writeClose(&wr.send_buf, h2.allocator, ws.CloseCode.normal, "") catch {};
                            wr.closing = true;
                        }
                        resume_send = true;
                    },
                    // Data frames: the shared `WsFragments` core owns the §5.4
                    // rules + the running size cap. Any feed error — a protocol
                    // violation, or OOM mid-reassembly (dropping the frame
                    // silently would desync the fragment state) — closes
                    // with 1002, matching this parser's oversize posture above.
                    .text, .binary, .continuation => blk: {
                        const fed = wr.frag.feed(h2.allocator, frame.opcode, frame.fin, frame.payload, Http1Conn.MAX_WS_MESSAGE) catch {
                            ws.writeClose(&wr.send_buf, h2.allocator, ws.CloseCode.protocol_error, "") catch {};
                            wr.closing = true;
                            resume_send = true;
                            break :blk;
                        };
                        switch (fed) {
                            .pending => {},
                            .message => |m| {
                                h2.wsEmitMessage(s.entity, m.opcode, m.payload) catch {};
                                wr.frag.reset();
                            },
                        }
                    },
                    _ => {
                        ws.writeClose(&wr.send_buf, h2.allocator, ws.CloseCode.protocol_error, "") catch {};
                        wr.closing = true;
                        resume_send = true;
                        break :drive;
                    },
                }
                pos += frame.consumed;
                if (wr.closing) break :drive;
            }
            if (pos > 0) {
                const leftover = wr.buf.items.len - pos;
                if (leftover > 0) std.mem.copyForwards(u8, wr.buf.items[0..leftover], wr.buf.items[pos..]);
                wr.buf.shrinkRetainingCapacity(leftover);
            }
            if (resume_send) {
                _ = c.nghttp2_session_resume_data(session, s.ng_stream_id);
            }
        }

        /// Queue one outbound frame on a live tunnel (the h2 arm of
        /// `consumeWsSends`). Close → Close frame then END_STREAM once
        /// the queue drains.
        fn wsStreamSend(h2: *Self, ws_ent: Entity, opcode: u8, payload: []const u8) void {
            const live = h2.wsStreamOf(h2.coll(.ws_streams), ws_ent) orelse return;
            const wr = live.s.ws_reasm orelse return;
            if (wr.closing) return;
            const op: ws.Opcode = @enumFromInt(@as(u4, @truncate(opcode)));
            if (op == .close) {
                ws.writeClose(&wr.send_buf, h2.allocator, ws.CloseCode.normal, "") catch {};
                wr.closing = true;
            } else {
                ws.writeFrame(&wr.send_buf, h2.allocator, op, payload) catch return;
            }
            _ = c.nghttp2_session_resume_data(live.ng, live.sid);
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
            if (getConn(nctx.h2, nctx.conn_entity)) |cp| cp.open_streams += 1;
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

            if (!nctx.h2.h2_opts.headers_first and !nctx.h2.h2_opts.client_headers_first) {
                if (stream == null) return 0;
                if (!stream.?.bodyAppend(data, len))
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                return 0;
            }

            // headers_first / client_headers_first: auto window update
            // is off on this stream's direction (server resp. client
            // sessions); on the other direction the streams stay in
            // `.auto` mode, whose `consume` call is a harmless no-op
            // under nghttp2's auto window update.
            //
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
            // Live Extended-CONNECT WS stream: DATA carries RFC 6455
            // frames. Consume immediately (the worker's input gate is
            // the real backpressure) and drive the parser. Pre-accept
            // (`is_ws` but no reassembler yet) falls through to the
            // `.hold` arm like any undecided body.
            if (s.ws_reasm) |wr| {
                _ = c.nghttp2_session_consume(session, stream_id, len);
                wr.buf.appendSlice(nctx.h2.allocator, data[0..len]) catch
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                nctx.h2.wsStreamDrive(session, s);
                return 0;
            }
            // Shared routing core (`Stream.routeInbound`); this arm owns
            // only the h2-specific repayment + failure verbs: consume =
            // WINDOW_UPDATE on the next send drive; append failure kills
            // the callback; a sink push failure is fatal for this stream
            // only (RST via temporal failure), not the connection.
            switch (s.routeInbound(data[0..len], null)) {
                .consume => _ = c.nghttp2_session_consume(session, stream_id, len),
                .held => {},
                .append_failed => return c.NGHTTP2_ERR_CALLBACK_FAILURE,
                .over_cap => unreachable, // no cap passed on h2 (the window bounds it)
                .sink_failed => return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE,
            }
            return 0;
        }

        /// Create a request entity in `cl` with the stream's
        /// finalized headers. Capacity is set at boot via the
        /// registry's `max_entities`; the per-tenant rate limiter is
        /// the gate that's supposed to keep entity counts inside that
        /// bound. If we still hit the cap here, that's a
        /// misconfiguration (rate limit too high or cap too low) —
        /// abort with a clear banner so the operator sees it instead
        /// of having streams silently rejected.
        fn emitRequestEntity(
            h2: *Self,
            cl: *StreamColl,
            s: *Stream,
            stream_id: i32,
            conn_entity: Entity,
        ) ?Entity {
            const req_entity = h2.reg.create(cl) catch |err| switch (err) {
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

            h2.reg.set(req_entity, cl, StreamId, .{ .id = @intCast(stream_id) }) catch return null;
            h2.reg.set(req_entity, cl, Session, .{ .entity = conn_entity }) catch return null;
            h2.reg.set(req_entity, cl, ReqHeaders, .{ .fields = fields, .count = count, ._buf = hdr_buf, ._buf_len = buf_len }) catch return null;
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

            // Extended CONNECT (architecture/websockets.md): `:method CONNECT`
            // + `:protocol websocket` opens a WS tunnel, not a request.
            // Emit the identity entity into `ws_connect_out` for the
            // consumer's disposition; inbound DATA holds (window-held)
            // until `wsConnectAccept` attaches the reassembler. Checked
            // before the headers_first early-emit so a CONNECT never
            // masquerades as a body-carrying request.
            if (h2.h2_opts.extended_connect and frame.*.hd.type == c.NGHTTP2_HEADERS and !s.emitted) {
                if (s.hdrValue(":method")) |m| {
                    if (std.mem.eql(u8, m, "CONNECT")) {
                        const proto = s.hdrValue(":protocol") orelse "";
                        // Only websocket tunnels; a CONNECT that already
                        // half-closed can never carry one.
                        if (!std.mem.eql(u8, proto, "websocket") or end_stream) {
                            _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, frame.*.hd.stream_id, c.NGHTTP2_REFUSED_STREAM);
                            return 0;
                        }
                        const ws_ent = emitRequestEntity(h2, h2.coll(.ws_connect_out), s, frame.*.hd.stream_id, nctx.conn_entity) orelse
                            return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                        h2.reg.set(ws_ent, h2.coll(.ws_connect_out), ReqBody, .{ .data = null, .len = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                        s.emitted = true;
                        s.is_ws = true;
                        s.ng_stream_id = frame.*.hd.stream_id;
                        s.body_mode = .hold;
                        s.entity = ws_ent;
                        return 0;
                    }
                }
            }

            // Extended-CONNECT WS stream: the only HEADERS/DATA event
            // that matters past this point is the peer's END_STREAM —
            // surface it as a disconnect (unless a Close frame already
            // did) and finish our side once the send queue drains.
            if (s.is_ws) {
                if (end_stream) {
                    if (s.ws_reasm) |wr| {
                        if (!wr.client_closed) {
                            wr.client_closed = true;
                            h2.wsEmitMessage(s.entity, @intFromEnum(ws.Opcode.close), "") catch {};
                        }
                        wr.closing = true;
                        _ = c.nghttp2_session_resume_data(session, frame.*.hd.stream_id);
                    }
                    // Pre-accept END (no reassembler): the close
                    // callback reaps the identity entity.
                }
                return 0;
            }

            // headers_first early emission: a request whose HEADERS
            // frame lacks END_STREAM has body DATA still inbound.
            // Emit the entity NOW into `request_receiving` (empty
            // ReqBody) so the consumer can decide the disposition
            // from headers alone; the stream holds the flow-control
            // window shut (`.hold`) until it does.
            if (h2.h2_opts.headers_first and frame.*.hd.type == c.NGHTTP2_HEADERS and !end_stream and !s.emitted) {
                const req_entity = emitRequestEntity(h2, h2.coll(.request_receiving), s, frame.*.hd.stream_id, nctx.conn_entity) orelse
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(req_entity, h2.coll(.request_receiving), ReqBody, .{ .data = null, .len = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
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
                if (s.body_mode == .sink) {
                    if (s.sink) |sk| {
                        sk.finish(sk.ctx);
                        s.sink_finished = true;
                    }
                    return 0;
                }
                if (s.body_mode == .discard) return 0;
                // Only a `.buffer` decision auto-completes: attach the
                // body and restore request_out's body-complete
                // contract. An entity still in `request_receiving`
                // stays there — EVERY body-carrying request flows
                // through the worker's disposition point (uniform
                // headers-first dispatch regardless of body timing);
                // the bytes wait in this Stream's buffer under
                // `inbound_eof`, attached in place by
                // `requestBodyBuffer` or drained by a `blob.receive`
                // sink.
                if (h2.reg.isInCollection(s.entity, h2.coll(.request_buffering))) {
                    h2.reg.set(s.entity, h2.coll(.request_buffering), ReqBody, takeBody(s)) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                    h2.reg.move(s.entity, h2.coll(.request_buffering), h2.coll(.request_out)) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                }
                return 0;
            }

            // Classic path: entity is created at END_STREAM with the
            // full body attached.
            s.emitted = true;
            s.ng_stream_id = frame.*.hd.stream_id;
            const req_entity = emitRequestEntity(h2, h2.coll(.request_out), s, frame.*.hd.stream_id, nctx.conn_entity) orelse
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            h2.reg.set(req_entity, h2.coll(.request_out), ReqBody, takeBody(s)) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
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

            // Pairs with the increment where this stream's user data was
            // attached; nghttp2 fires this exactly once per opened stream.
            if (getConn(nctx.h2, nctx.conn_entity)) |cp| cp.open_streams -|= 1;

            // headers_first: bytes held un-consumed on a stream that
            // dies still occupy the CONNECTION window (the stream
            // window dies with the stream). Repay it or every later
            // stream on this connection inherits a shrunken window.
            if (s.unconsumed > 0) {
                _ = c.nghttp2_session_consume_connection(session, s.unconsumed);
                s.unconsumed = 0;
            }

            // Sink stream closing before END_STREAM delivered: the
            // upload can't complete — tell the driver. (Release of
            // h2's sink ref is `sweepBodySinks`' job — it detects the
            // dead stream and releases exactly once; the job's abort
            // is idempotent.)
            if (s.sink) |sk| {
                if (!s.sink_finished) sk.abort(sk.ctx);
                s.sink = null;
            }

            if (s.is_ws) {
                // WS identity entities die with their stream — the
                // consumer's staleness sweep is the disconnect signal.
                // Through the stream funnel: the identity entity owns its
                // routing ReqHeaders.
                if (!s.entity.isNil() and !nctx.h2.reg.isStale(s.entity)) {
                    nctx.h2.destroyEntity(s.entity) catch {};
                }
            } else if (s.emitted and !s.entity.isNil() and !nctx.h2.reg.isStale(s.entity)) {
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
                // Extended-CONNECT WS: hand the queued framed bytes to
                // nghttp2; defer when idle, EOF once closing and drained.
                if (s.ws_reasm) |wr| {
                    if (wr.send_buf.items.len == 0) {
                        if (wr.closing) {
                            data_flags[0] |= @intCast(c.NGHTTP2_DATA_FLAG_EOF);
                            s.send_complete = true;
                            return 0;
                        }
                        return c.NGHTTP2_ERR_DEFERRED;
                    }
                    const n = @min(length, wr.send_buf.items.len);
                    @memcpy(buf[0..n], wr.send_buf.items[0..n]);
                    const leftover = wr.send_buf.items.len - n;
                    if (leftover > 0) std.mem.copyForwards(u8, wr.send_buf.items[0..leftover], wr.send_buf.items[n..]);
                    wr.send_buf.shrinkRetainingCapacity(leftover);
                    return @intCast(n);
                }
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
                                h2.reg.move(s.entity, h2.coll(._client_stream_data_sending), h2.coll(.client_stream_data_out)) catch {};
                            } else {
                                h2.reg.move(s.entity, h2.coll(._stream_data_sending), h2.coll(.stream_data_out)) catch {};
                            }
                        } else {
                            h2.reg.move(s.entity, h2.coll(._stream_data_sending), h2.coll(.stream_data_out)) catch {};
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

            var settings_buf: [5]c.nghttp2_settings_entry = undefined;
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
            if (self.h2_opts.extended_connect) {
                settings_buf[settings_count] = .{ .settings_id = c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL, .value = 1 };
                settings_count += 1;
            }

            if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings_buf, settings_count) != 0) {
                c.nghttp2_session_del(session);
                self.allocator.destroy(nctx);
                conn.ng_session = null;
                conn.ng_ctx = null;
                return error.Nghttp2SettingsFailed;
            }

            // Manual window management: keep per-stream holds from
            // starving the shared connection window — essential once a
            // streaming front door multiplexes many clients' requests
            // over ONE connection to this server (see the
            // HELD_CONN_RECV_WINDOW doc).
            if (self.h2_opts.headers_first) {
                _ = c.nghttp2_session_set_local_window_size(session, c.NGHTTP2_FLAG_NONE, 0, HELD_CONN_RECV_WINDOW);
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

            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null) return 0;

            const s = stream.?;
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
            const h2 = nctx.h2;
            const end_stream = frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;

            // client_headers_first early emission: a final (non-1xx)
            // response whose HEADERS frame lacks END_STREAM has body
            // DATA still inbound. Emit a FRESH entity into
            // `client_response_receiving` now (Status + RespHeaders)
            // so the consumer can start relaying; the stream holds the
            // flow-control window shut (`.hold`) until a sink is
            // attached. A post-1xx final response misses the
            // HCAT_RESPONSE gate and falls back to the classic
            // buffered delivery — correct, just not streamed.
            if (h2.h2_opts.client_headers_first and
                frame.*.hd.type == c.NGHTTP2_HEADERS and
                frame.*.headers.cat == c.NGHTTP2_HCAT_RESPONSE and
                !end_stream and !s.resp_emitted and s.response_status >= 200)
            {
                const cl = h2.coll(.client_response_receiving);
                const resp_entity = h2.reg.create(cl) catch
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                var fields: ?[*]HeaderField = null;
                var count: u32 = 0;
                var buf_len: u32 = 0;
                const hdr_buf = s.hdrFinalize(&fields, &count, &buf_len);
                h2.reg.set(resp_entity, cl, StreamId, .{ .id = @intCast(frame.*.hd.stream_id) }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, Session, .{ .entity = nctx.conn_entity }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, Status, .{ .code = s.response_status }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, RespHeaders, .{ .fields = fields, .count = count, ._buf = hdr_buf, ._buf_len = buf_len }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, ReqHeaders, .{ .fields = null, .count = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, ReqBody, .{ .data = null, .len = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, RespBody, .{ .data = null, .len = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                h2.reg.set(resp_entity, cl, H2IoResult, .{ .err = 0 }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                s.resp_emitted = true;
                s.body_mode = .hold;
                return 0;
            }

            if (!end_stream) return 0;

            if (s.resp_emitted) {
                // END_STREAM on an early-emitted response: the body is
                // complete. Repay held debt (backpressure is moot once
                // the last byte is in); tell a sink. Headers/body are
                // NOT re-attached to the request entity — they were
                // delivered on the receiving entity; the request
                // entity reaches `client_response_out` at stream close
                // as the terminal signal.
                if (s.unconsumed > 0) {
                    _ = c.nghttp2_session_consume(session, frame.*.hd.stream_id, s.unconsumed);
                    s.unconsumed = 0;
                }
                s.inbound_eof = true;
                if (s.body_mode == .sink) {
                    if (s.sink) |sk| {
                        sk.finish(sk.ctx);
                        s.sink_finished = true;
                    }
                }
                return 0;
            }

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

            // Pairs with the increment where this stream's user data was
            // attached; nghttp2 fires this exactly once per opened stream.
            if (getConn(nctx.h2, nctx.conn_entity)) |cp| cp.open_streams -|= 1;

            // client_headers_first: bytes held un-consumed on a dying
            // stream still occupy the CONNECTION window — repay it or
            // every later stream on this connection inherits a
            // shrunken window. (Mirror of the server-side close.)
            if (s.unconsumed > 0) {
                _ = c.nghttp2_session_consume_connection(session, s.unconsumed);
                s.unconsumed = 0;
            }

            // Sink stream closing before END_STREAM delivered: the
            // response can't complete — tell the driver. Release of
            // h2's sink ref stays `sweepBodySinks`' job.
            if (s.sink) |sk| {
                if (!s.sink_finished) sk.abort(sk.ctx);
                s.sink = null;
            } else if (s.resp_emitted and s.body_len > 0 and
                !s.entity.isNil() and !nctx.h2.reg.isStale(s.entity))
            {
                // Early-emitted response whose stream closed before the
                // consumer attached a sink (a fast response can arrive
                // and close within ONE poll — the receiving entity and
                // this close land in the same turn). The `.hold` bytes
                // would die with the Stream; hand them to the request
                // entity instead — the terminal `client_response_out`
                // event carries the body tail (the consumer relays it,
                // gated on `err`).
                const tail = takeBody(s);
                streamSet(nctx.h2, s.entity, RespBody, .{ .data = tail.data, .len = tail.len });
            }

            if (!s.entity.isNil() and !nctx.h2.reg.isStale(s.entity)) {
                const err: i32 = if (error_code == 0) 0 else -1;
                // Did the request head reach the peer? (rove#532 — the
                // proxy's retry-safety signal; see `H2IoResult.head_written`.)
                // Three ways to prove it did NOT: never serialized;
                // serialized into a buffer at/after the conn's first failed
                // socket write (a failed write queues nothing); or the PEER
                // attested it — REFUSED_STREAM is h2's contract that the
                // stream was not processed (a draining server's GOAWAY
                // refuses streams above last_stream_id exactly so a proxy
                // can re-send them, RFC 9113 §8.7). Conn already gone → the
                // fail seq is unknowable; a serialized head then stays
                // ambiguous.
                const head_written = blk: {
                    if (s.head_send_mark == 0) break :blk false;
                    if (error_code == c.NGHTTP2_REFUSED_STREAM) break :blk false;
                    if (getConn(nctx.h2, nctx.conn_entity)) |cp| {
                        if (cp.send_fail_seq != 0 and s.head_send_mark >= cp.send_fail_seq)
                            break :blk false;
                    }
                    break :blk true;
                };
                clientStreamClose(nctx.h2, s.entity, err, head_written);
            }

            s.send_data = null;
            _ = c.nghttp2_session_set_stream_user_data(session, stream_id, null);
            s.free();
            return 0;
        }

        /// Client on_frame_send: stamp the stream's `head_send_mark` the
        /// moment its request HEADERS are serialized. Serialization happens
        /// inside `nghttp2_session_mem_send` while `driveAllSends` is
        /// filling the accumulation buffer that will be handed to
        /// `enqueueConnSend` as seq `send_seq + 1` — so that is the seq
        /// whose write completion decides whether the head reached the
        /// peer (rove#532).
        fn onFrameSendClientCb(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
            const stream: ?*Stream = @ptrCast(@alignCast(
                c.nghttp2_session_get_stream_user_data(session, frame.*.hd.stream_id),
            ));
            if (stream == null) return 0;
            const s = stream.?;
            if (s.head_send_mark != 0) return 0;
            const nctx: *NgCtx = @ptrCast(@alignCast(user_data));
            if (getConn(nctx.h2, nctx.conn_entity)) |cp| {
                s.head_send_mark = cp.send_seq + 1;
            }
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
            c.nghttp2_session_callbacks_set_on_frame_send_callback(cbs, &onFrameSendClientCb);

            ng_client_callbacks = cbs;
        }

        fn clientSessionCreate(self: *Self, conn: *Conn, conn_entity: Entity) !void {
            try ensureClientCallbacks();

            const nctx = try self.allocator.create(NgCtx);
            nctx.* = .{ .h2 = self, .allocator = self.allocator, .conn_entity = conn_entity };

            var session: ?*c.nghttp2_session = null;
            if (self.h2_opts.client_headers_first) {
                if (ng_client_option == null) {
                    var opt: ?*c.nghttp2_option = null;
                    if (c.nghttp2_option_new(&opt) != 0) {
                        self.allocator.destroy(nctx);
                        return error.OutOfMemory;
                    }
                    c.nghttp2_option_set_no_auto_window_update(opt, 1);
                    ng_client_option = opt;
                }
                if (c.nghttp2_session_client_new2(&session, ng_client_callbacks, @ptrCast(nctx), ng_client_option) != 0) {
                    self.allocator.destroy(nctx);
                    return error.Nghttp2SessionCreateFailed;
                }
            } else if (c.nghttp2_session_client_new(&session, ng_client_callbacks, @ptrCast(nctx)) != 0) {
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

            // Manual window management: keep per-stream holds from
            // starving the shared connection window (see the
            // HELD_CONN_RECV_WINDOW doc).
            if (self.h2_opts.client_headers_first) {
                _ = c.nghttp2_session_set_local_window_size(session, c.NGHTTP2_FLAG_NONE, 0, HELD_CONN_RECV_WINDOW);
            }
        }

        // =============================================================
        // Public API
        // =============================================================

        /// A snapshot of the io-buffer-ring + connection-depth counters
        /// for this server. Shared by the worker's /_system/metrics and
        /// the front's metrics/diagnostics so the two can't drift.
        pub const ConnStats = struct {
            recv_completions: u64,
            recv_returned_drain: u64,
            recv_returned_deinit: u64,
            recv_returned_stale: u64,
            recv_outstanding: u64,
            buf_count: u64,
            recv_enobufs: u64,
            admission_denied: u64,
            request_out: usize,
            response_in: usize,
            response_out: usize,
            conn_active: usize,
            conn_tls_handshake: usize,
            handshake_reaped: u64,
            io_connections: usize,
            /// Peak live `WriteBuf` count — what a fixed egress pool must
            /// cover. Read from collection membership, not counted.
            write_bufs_peak: usize,
            write_bufs_now: usize,
            /// Write entities destroyed still holding a buffer — they bypassed
            /// the release path and that buffer leaked. Must stay 0.
            write_bufs_leaked: u64,
        };

        pub fn connStats(self: *Self) ConnStats {
            const drain = self.io.recv_buffers_returned;
            // The destructor-era return path is gone (buffers return by
            // transition only); the field stays 0 so the wire metric —
            // and any dashboard on it — keeps its identity.
            const deinit_r: u64 = 0;
            const stale_r = self.io.recv_buffers_returned_via_stale;
            const comp = self.io.recv_completions_with_data;
            return .{
                .recv_completions = comp,
                .recv_returned_drain = drain,
                .recv_returned_deinit = deinit_r,
                .recv_returned_stale = stale_r,
                .recv_outstanding = comp -| (drain + deinit_r + stale_r),
                .buf_count = @as(u64, self.io.buf_count),
                .recv_enobufs = self.recv_enobufs_total,
                .admission_denied = self.io.admission_denied_total,
                .request_out = self.request_out.entitySlice().len,
                .response_in = self.response_in.entitySlice().len,
                .response_out = self.response_out.entitySlice().len,
                .conn_active = self._conn_active.entitySlice().len,
                .conn_tls_handshake = self._conn_tls_handshake.entitySlice().len,
                .handshake_reaped = self.handshake_reaped_total,
                .io_connections = self.io.connections.entitySlice().len,
                .write_bufs_peak = self.io.write_bufs_peak,
                .write_bufs_now = self.io.writeBufsLive(),
                // The bypass counter died with the destructor machinery;
                // the invariant is now the write_done phase itself. 0
                // keeps the must-stay-0 metric's identity.
                .write_bufs_leaked = 0,
            };
        }

        /// Emit the io-ring + connection-depth metrics in Prometheus text
        /// to `w`. Used by both the worker and front metrics surfaces.
        pub fn writeConnMetrics(self: *Self, w: anytype) !void {
            const s = self.connStats();
            try w.print(
                \\# HELP io_recv_completions_total recv CQEs that carried data (one buffer consumed from the registered ring each).
                \\# TYPE io_recv_completions_total counter
                \\io_recv_completions_total {d}
                \\# HELP io_recv_buffers_returned_total buffers returned to the registered ring, by source.
                \\# TYPE io_recv_buffers_returned_total counter
                \\io_recv_buffers_returned_total{{src="drain"}} {d}
                \\io_recv_buffers_returned_total{{src="deinit"}} {d}
                \\io_recv_buffers_returned_total{{src="stale"}} {d}
                \\# HELP io_recv_outstanding buffers currently held by the kernel (completions - returned). Must stay below buf_count.
                \\# TYPE io_recv_outstanding gauge
                \\io_recv_outstanding {d}
                \\# HELP io_recv_buf_count registered ring capacity (--buf-count).
                \\# TYPE io_recv_buf_count gauge
                \\io_recv_buf_count {d}
                \\# HELP io_recv_enobufs_total recv completions with -ENOBUFS (kernel had no buffer to give).
                \\# TYPE io_recv_enobufs_total counter
                \\io_recv_enobufs_total {d}
                \\# HELP io_admission_denied_total accepts refused because in-flight conns ≥ admission budget.
                \\# TYPE io_admission_denied_total counter
                \\io_admission_denied_total {d}
                \\# HELP h2_request_out_size requests received, waiting for dispatch.
                \\# TYPE h2_request_out_size gauge
                \\h2_request_out_size {d}
                \\# HELP h2_response_in_size responses ready to dispatch back through h2.
                \\# TYPE h2_response_in_size gauge
                \\h2_response_in_size {d}
                \\# HELP h2_response_out_size responses in-flight on the send path.
                \\# TYPE h2_response_out_size gauge
                \\h2_response_out_size {d}
                \\# HELP h2_conn_active_size active h2 sessions.
                \\# TYPE h2_conn_active_size gauge
                \\h2_conn_active_size {d}
                \\# HELP h2_conn_tls_handshake_size connections still in TLS handshake.
                \\# TYPE h2_conn_tls_handshake_size gauge
                \\h2_conn_tls_handshake_size {d}
                \\# HELP h2_handshake_reaped_total connections destroyed for blowing the TLS handshake budget (slowloris canary).
                \\# TYPE h2_handshake_reaped_total counter
                \\h2_handshake_reaped_total {d}
                \\# HELP io_write_bufs_live egress buffers io is holding right now, across write_in + _write_pending + write_results.
                \\# TYPE io_write_bufs_live gauge
                \\io_write_bufs_live {d}
                \\# HELP io_write_bufs_peak high-water of the above — the size a fixed egress buffer pool would have to cover.
                \\# TYPE io_write_bufs_peak gauge
                \\io_write_bufs_peak {d}
                \\# HELP io_write_bufs_leaked_total write entities destroyed while still holding a buffer — bypassed the release path. Must be 0.
                \\# TYPE io_write_bufs_leaked_total counter
                \\io_write_bufs_leaked_total {d}
                \\# HELP h2_io_connections_size raw tcp connections owned by the io layer (pre-handshake or post-handshake unclaimed).
                \\# TYPE h2_io_connections_size gauge
                \\h2_io_connections_size {d}
                \\
            , .{
                s.recv_completions,
                s.recv_returned_drain,
                s.recv_returned_deinit,
                s.recv_returned_stale,
                s.recv_outstanding,
                s.buf_count,
                s.recv_enobufs,
                s.admission_denied,
                s.request_out,
                s.response_in,
                s.response_out,
                s.conn_active,
                s.conn_tls_handshake,
                s.handshake_reaped,
                s.write_bufs_now,
                s.write_bufs_peak,
                s.write_bufs_leaked,
                s.io_connections,
            });

            // RED error-rate signal: responses served to clients by status
            // class. The serving-path counter the consensus/io gauges don't
            // provide — an on-call's first question ("are we serving 5xx, and
            // how many?") is answerable + alertable. Bounded labels (5 classes + other);
            // tenant/route stay OUT (active-series rule) — they're trace
            // exemplars, not labels.
            const hc = self.http_status_class;
            try w.print(
                \\# HELP http_requests_total responses served to clients by HTTP status class (the RED rate+error signal).
                \\# TYPE http_requests_total counter
                \\http_requests_total{{code="1xx"}} {d}
                \\http_requests_total{{code="2xx"}} {d}
                \\http_requests_total{{code="3xx"}} {d}
                \\http_requests_total{{code="4xx"}} {d}
                \\http_requests_total{{code="5xx"}} {d}
                \\http_requests_total{{code="other"}} {d}
                \\
            , .{ hc[1], hc[2], hc[3], hc[4], hc[5], hc[0] });

            // The bounded exact-status breakdown (rove#216) — complements the
            // class buckets so an auth-401 storm is distinguishable from a
            // 404/409/421 storm without SSH-grepping logs.
            const hn = self.http_status_notable;
            try w.writeAll(
                \\# HELP http_responses_status_total responses served for a bounded set of individually-notable statuses (auth/routing/leader diagnosis; complements http_requests_total).
                \\# TYPE http_responses_status_total counter
                \\
            );
            inline for (NOTABLE_STATUS, 0..) |code, idx| {
                try w.print("http_responses_status_total{{status=\"{d}\"}} {d}\n", .{ code, hn[idx] });
            }
        }

        /// Every Server field `create` initializes by NAME (the collection
        /// fields are covered by the `COLLECTIONS` inline-for instead). The
        /// comptime check below walks the struct's real field list and
        /// refuses to compile if any field is in neither set — because
        /// `allocator.create` returns raw memory where field DEFAULTS never
        /// apply, a field added to the struct but not to `create` would
        /// otherwise ship uninitialized (silently correct under Debug's 0xAA
        /// fill, garbage under ReleaseFast — the rove#574 KvStore class).
        const CREATE_INITIALIZES = [_][]const u8{
            "io",           "h2_opts",                        "reg",                  "allocator",
            "recv_enobufs_total", "handshake_reaped_total",   "recv_enobufs_logged",  "recv_enobufs_last_logged_decade",
            "recv_enobufs_low_outstanding_streak", "http_status_class", "http_status_notable", "body_sinks",
        };
        comptime {
            @setEvalBranchQuota(1_000_000);
            outer: for (@typeInfo(Self).@"struct".fields) |f| {
                for (COLLECTIONS) |s| if (std.mem.eql(u8, s.name, f.name)) continue :outer;
                for (CREATE_INITIALIZES) |n| if (std.mem.eql(u8, n, f.name)) continue :outer;
                @compileError("h2 Server field '" ++ f.name ++ "' is not initialized by create() — " ++
                    "assign it there AND add it to CREATE_INITIALIZES (create() memory takes no field defaults)");
            }
        }

        pub fn create(reg: *Reg, allocator: std.mem.Allocator, addr: std.net.Address, io_opts: rio.IoOptions, h2_opts: H2Options) !*Self {
            try ensureCallbacks();

            const io = try IoType.create(reg, allocator, addr, io_opts);
            errdefer io.destroy();

            const self = try allocator.create(Self);
            self.io = io;
            self.h2_opts = h2_opts;
            self.reg = reg;
            self.allocator = allocator;
            self.recv_enobufs_total = 0;
            self.handshake_reaped_total = 0;
            self.recv_enobufs_logged = false;
            self.recv_enobufs_last_logged_decade = 0;
            self.recv_enobufs_low_outstanding_streak = 0;
            self.http_status_class = .{ 0, 0, 0, 0, 0, 0 };
            self.http_status_notable = .{0} ** NOTABLE_STATUS.len;
            self.body_sinks = .empty;

            // Every collection field is a stable pointer into the world
            // registry's owned storage (it constructed and registered
            // every entry). Disabled (client_only with has_client =
            // false) collections have field type `void` — assign `{}`
            // so the field is defined.
            inline for (COLLECTIONS) |s| {
                if (comptime s.client_only and !has_client) {
                    @field(self, s.name) = {};
                } else {
                    @field(self, s.name) = reg.coll(@field(WorldT.CollId, s.name));
                }
            }

            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            // End every live conn the way every conn ends.
            inline for (self.liveConnColls()) |cl| {
                for (cl.entitySlice()) |ent| _ = self.closeConn(ent);
            }
            self.reg.flush() catch {};
            self.io.shutdownAllConns();
            // Reap the conns' foreign state (nghttp2 session, TLS, h1):
            // conn_dead holds the retired, and conns still in
            // conn_closing (shutdown posted, recv not yet quiet) are
            // reaped too — their socket ops are already with the
            // kernel, and nothing reads the session after this point.
            self.reapConnForeign(self.io.coll(.conn_dead));
            self.reapConnForeign(self.io.coll(.conn_closing));
            self.reg.flush() catch {};
            // Same for the stream-owned buffers: entities the
            // consumer never ended (requests in flight at shutdown)
            // and the dead-letter's unreaped tail. EVERY world
            // collection is swept, a composer's parked stream states
            // included — the release row is what bounds the sweep
            // (io rows and worker-only rows read as null defaults
            // through getFat and are skipped), so reading any
            // entity is safe.
            inline for (@typeInfo(WorldT.CollId).@"enum".fields) |cf| {
                const cid = @field(WorldT.CollId, cf.name);
                if (comptime WorldT.declOf(cid).kind == .set) continue;
                for (self.reg.coll(cid).entitySlice()) |ent| {
                    self.freeStreamForeign(ent);
                }
            }
            for (self.body_sinks.items) |ref| {
                ref.sink.abort(ref.sink.ctx);
                ref.sink.release(ref.sink.ctx);
            }
            self.body_sinks.deinit(allocator);
            self.io.destroy();
            allocator.destroy(self);
        }

        /// Wait for `min_complete` io_uring completions — a COUNT, not a
        /// duration. `pollWithTimeout` is the one that takes nanoseconds.
        ///
        /// The assert exists because the two are trivially confusable: both
        /// take an integer, so `poll(10 * std.time.ns_per_ms)` compiles and
        /// then blocks forever waiting for ten million completions. The front
        /// door's `:80` listener did exactly that, and the symptom was silent —
        /// the kernel still completes the TCP handshake, so the port looks
        /// alive while nothing is ever answered. Real callers wait on 0 or 1.
        /// Upper bound on a sane `poll` wait. A caller that wants "drain
        /// whatever is ready" passes 0 and one that wants "make progress"
        /// passes 1; nothing legitimately waits on more. Anything larger is a
        /// duration that took a wrong turn.
        const MAX_MIN_COMPLETE: u32 = 1024;

        pub fn poll(self: *Self, min_complete: u32) !void {
            std.debug.assert(min_complete <= MAX_MIN_COMPLETE);
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

        /// Free one collection's members' foreign conn state and destroy
        /// the entities (deferred; caller flushes). The Conn component is
        /// parked by the time a conn reaches `conn_dead` — `getFat`
        /// resolves it wherever it lives — and `conn_state.Conn.deinit`
        /// nulls what it frees, so a slot can never double-free.
        fn reapConnForeign(self: *Self, cl: anytype) void {
            for (cl.entitySlice()) |ent| {
                if (self.reg.isStale(ent)) continue;
                if (self.reg.isMoving(ent)) continue;
                const conn_ptr = self.reg.getFat(ent, Conn) catch continue;
                conn_state.Conn.deinit(self.allocator, @as([*]Conn, @ptrCast(conn_ptr))[0..1]);
                // Plain destroy, not the stream funnel: a conn entity
                // carries no stream buffers, and its foreign state was
                // just freed — the dead-letter would only add a lap.
                self.reg.destroy(ent) catch {};
            }
        }

        /// Drain the terminal hand-off collection (fat model): every conn
        /// here finished teardown — socket down, read cycle released, no
        /// reader left — so this is provably after every access, the same
        /// guarantee destroy-time firing gave the archetype's hook.
        fn processConnDead(self: *Self) void {
            self.reapConnForeign(self.io.coll(.conn_dead));
        }

        /// Drain the stream dead-letter (fat): free each ended entity's
        /// four buffer components — `getFat` resolves them resident or
        /// parked, and a component never held reads as its null default
        /// so the free skips — then destroy (deferred; the caller owns
        /// the flush). Entities ended after this pass's flushes wait
        /// one poll, exactly like `conn_dead`.
        fn processStreamDead(self: *Self) void {
            for (self.coll(._stream_dead).entitySlice()) |ent| {
                if (self.reg.isStale(ent) or self.reg.isMoving(ent)) continue;
                self.freeStreamForeign(ent);
                self.reg.destroy(ent) catch {};
            }
        }

        /// End an h2-owned entity — the stream funnel verb, like
        /// `closeConn` for conns. The entity routes to the
        /// `_stream_dead` dead-letter — an entity-keyed deferred evict,
        /// so an ending is NEVER refused, a mid-move entity included
        /// (the queued op lands first, then the ending collects it) —
        /// and the pollPostlude reaper frees the stream-owned buffers
        /// and destroys, at a known phase outside nghttp2's callbacks.
        /// Consumers of terminal collections (response_out and kin) end
        /// entities through this, not reg.destroy — the same funnel
        /// contract every ending seam in this codebase carries.
        pub fn destroyEntity(self: *Self, ent: Entity) !void {
            if (self.reg.isInCollection(ent, self.coll(._stream_dead))) return;
            return self.reg.evict(ent, self.coll(._stream_dead));
        }

        /// The union of the stream-shaped rows — server streams, the WS
        /// seam, the client connect flow — which is h2's four buffer
        /// components plus every consumer `request_row` fragment. NOT
        /// the whole universe: conn and io rows release through their
        /// own phases (conn_dead, write_done), and their deinits carry
        /// guards and contexts a generic sweep must not trip.
        const stream_release_row = stream_row.merge(ws_row).merge(
            if (has_client) connect_row_full else Row(&.{}),
        );

        fn freeStreamForeign(self: *Self, ent: Entity) void {
            inline for (comptime stream_release_row.deinitTypes()) |T| {
                comptime {
                    if (rove.row_mod.componentDeinitNeedsCtx(T)) @compileError(
                        "stream component " ++ @typeName(T) ++ " wants a deinit ctx — the dead-letter reaper has none; use the ctx-less batch deinit (null out what you free)",
                    );
                }
                const p = self.reg.getFat(ent, T) catch return;
                T.deinit(self.allocator, @as([*]T, @ptrCast(p))[0..1]);
            }
        }

        fn pollPrelude(self: *Self) !void {
            // Phase 1: Consume user inputs queued between polls (responses, chunks).
            // Must run before io.poll so the writes they generate can be submitted
            // in the same iteration.
            self.sweepBodySinks();
            self.sweepPausedH1Reads();
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
            // The terminal phases first: conns io retired into
            // `conn_dead` this pass get their foreign state freed, and
            // the stream dead-letter is reaped — both at a known phase
            // outside nghttp2's callbacks.
            self.processConnDead();
            self.processStreamDead();
            try self.reg.flush();

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
            if (has_client) self.sweepOrphanedClient();
            try self.reg.flush();

            // Idle reap runs HERE — after reads were fed to nghttp2 above
            // — so a request that just arrived on an idle connection has
            // refreshed `last_active_ns` and survives. The GOAWAY it
            // queues flushes on the next `pollPrelude`/`driveAllSends`.
            // (Cures the idle-keepalive reuse-vs-reap race; see
            // `reapIdleConnections` + the front-door TTFB investigation.)
            try self.reapIdleConnections();
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
            for ([_]*StreamColl{ self.coll(.request_receiving), self.coll(.request_buffering) }) |cl| {
                const entities = cl.entitySlice();
                const sessions = cl.column(Session);
                for (entities, sessions) |ent, sess| {
                    if (getConn(self, sess.entity) == null) {
                        self.reg.set(ent, cl, H2IoResult, .{ .err = -1 }) catch {};
                        self.reg.move(ent, cl, self.coll(.response_out)) catch {};
                    }
                }
            }
        }

        /// Client-side counterpart of `sweepOrphanedInbound`: an
        /// upstream connection that dies takes its nghttp2 streams
        /// down without firing per-stream close callbacks, so request
        /// entities parked in the pump collections would wait forever
        /// — the consumer only reacts to entities it is shown. Sweep
        /// entities whose connection is gone into
        /// `client_response_out` as failed streams. (Response-body
        /// sinks on those streams are aborted + released by
        /// `sweepBodySinks`, which detects the dead conn the same
        /// way.)
        fn sweepOrphanedClient(self: *Self) void {
            if (!has_client) return;
            for ([_]*ClientStreamColl{ self.coll(.client_stream_data_out), self.coll(._client_stream_data_sending), self.coll(._client_request_sending) }) |cl| {
                const entities = cl.entitySlice();
                const sessions = cl.column(Session);
                for (entities, sessions) |ent, sess| {
                    if (getConn(self, sess.entity) == null) {
                        self.reg.set(ent, cl, H2IoResult, .{ .err = -1 }) catch {};
                        self.reg.move(ent, cl, self.coll(.client_response_out)) catch {};
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
                // RED error-rate signal: count this client-facing response by
                // status class BEFORE the per-transport branches, so h1 and h2
                // (and the early conn-gone bail below) are all counted.
                self.http_status_class[statusClass(status.code)] += 1;
                if (notableStatusIndex(status.code)) |ni| self.http_status_notable[ni] += 1;
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
                    continue;
                };

                // HTTP/1.1 connection (Phase 2): serialize + write via the h1
                // codec instead of nghttp2 (encrypting if the conn is TLS).
                if (conn_ptr.h1 != null) {
                    self.http1WriteResponse(ent, conn_ptr, sess.entity, status, rh, rb, io_res) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
                    };
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
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
                    try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
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
                        try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
                        continue;
                    };
                    data_prd.source = .{ .ptr = @ptrCast(body_data_ptr) };
                    data_prd.read_callback = &onDataSourceReadCb;
                }

                const rv = c.nghttp2_submit_response(ng_session, @intCast(sid.id), nva, nv_count, if (data_prd.read_callback != null) &data_prd else null);

                if (rv < 0) {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
                    continue;
                }

                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream) |s| {
                    s.entity = ent;
                    s.send_complete = (data_prd.read_callback == null);
                    s.send_data = body_data_ptr;
                    try self.reg.move(ent, self.coll(.response_in), self.coll(._response_sending));
                } else {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
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
            const repaid = s.flipToDiscard() orelse return;
            if (repaid > 0) {
                _ = c.nghttp2_session_consume(ng_session, @intCast(stream_id), repaid);
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
                    try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
                    continue;
                };

                // h1 streaming: chunked head + park for chunks (Phase 6).
                if (conn_ptr.h1 != null) {
                    self.http1StreamBegin(ent, conn_ptr, sess.entity, status, rh, io_res) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
                    };
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                self.flipInboundBodyToDiscard(ng_session, sid.id);

                var status_buf: [3]u8 = undefined;
                const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status.code}) catch "500";

                const nv_count: usize = 1 + @as(usize, rh.count);
                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
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
                    try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
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
                    try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.stream_data_out));
                } else {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
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
                    try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.response_out));
                    continue;
                };

                // h1 streaming: frame + write the chunk, return for the next.
                if (conn_ptr.h1 != null) {
                    self.http1StreamChunk(ent, conn_ptr, sess.entity, rb) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.response_out));
                    };
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.response_out));
                    continue;
                }

                if (rb.data == null or rb.len == 0) {
                    try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.stream_data_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.response_out));
                    continue;
                }

                const s = stream.?;

                s.stream_chunk_data = rb.data;
                s.stream_chunk_len = rb.len;
                s.stream_chunk_offset = 0;
                rb.data = null;
                rb.len = 0;

                _ = c.nghttp2_session_resume_data(ng_session, s.ng_stream_id);

                try self.reg.move(ent, self.coll(.stream_data_in), self.coll(._stream_data_sending));
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
                    try self.reg.move(ent, self.coll(.stream_close_in), self.coll(.response_out));
                    continue;
                };

                // h1 streaming: write the zero-terminator + finalize (Phase 6).
                if (conn_ptr.h1 != null) {
                    self.http1StreamEnd(ent, conn_ptr, sess.entity, io_res) catch {
                        io_res.err = -1;
                        try self.reg.move(ent, self.coll(.stream_close_in), self.coll(.response_out));
                    };
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_close_in), self.coll(.response_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.stream_close_in), self.coll(.response_out));
                    continue;
                }

                stream.?.stream_eof = true;
                _ = c.nghttp2_session_resume_data(ng_session, stream.?.ng_stream_id);

                try self.reg.move(ent, self.coll(.stream_close_in), self.coll(._stream_data_sending));
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
                    try self.reg.move(ent, self.io.coll(.read_results), self.coll(._read_errors));
                    continue;
                }
                if (rr.result == ENOBUFS) {
                    // Transient: route back to read_in so processReadIn
                    // re-arms recv on this same entity. The buffer ring
                    // refills as other recvs complete + return their
                    // buffers via returnBufferToRing.
                    enobufs_this_pass += 1;
                    try self.reg.move(ent, self.io.coll(.read_results), self.io.coll(.read_in));
                    continue;
                }
                if (rr.result <= 0) {
                    try self.reg.move(ent, self.io.coll(.read_results), self.coll(._read_errors));
                    continue;
                }
                if (self.reg.isInCollection(conn_ent.entity, self.io.coll(.connections))) {
                    try self.reg.move(ent, self.io.coll(.read_results), self.coll(._read_init));
                    continue;
                }
                if (self.reg.isInCollection(conn_ent.entity, self.coll(._conn_tls_handshake))) {
                    try self.reg.move(ent, self.io.coll(.read_results), self.coll(._read_handshake));
                    continue;
                }
                if (self.reg.isInCollection(conn_ent.entity, self.coll(._conn_active))) {
                    try self.reg.move(ent, self.io.coll(.read_results), self.coll(._read_active));
                    continue;
                }
                try self.reg.move(ent, self.io.coll(.read_results), self.coll(._read_errors));
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
                const returned_stale = self.io.recv_buffers_returned_via_stale;
                const returned = returned_drain + returned_stale;
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
                            "  consumed={d} returned_drain={d} returned_stale={d}\n" ++
                            "  This is impossible by construction; counters or ring management is buggy.\n" ++
                            "================================================================\n",
                        .{ outstanding, self.io.buf_count, consumed, returned_drain, returned_stale },
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
                // return cycle. Abort with the diag
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
                                "  consumed={d} returned_drain={d}\n" ++
                                "  Some destruction path is taking buffers out of circulation\n" ++
                                "  without returning them to the registered ring.\n" ++
                                "================================================================\n",
                            .{ self.recv_enobufs_total, outstanding, self.io.buf_count, consumed, returned_drain },
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
                        "rove-h2: recv ENOBUFS — io_uring registered buffer pool exhausted ({d} total, +{d} this pass; consumed={d} returned_drain={d} outstanding={d} of {d}). If `outstanding` is far below `buf_count`, this is a leak — see /_system/metrics for the running balance.",
                        .{ self.recv_enobufs_total, enobufs_this_pass, consumed, returned_drain, outstanding, self.io.buf_count },
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
                    _ = self.closeConn(conn_ent.entity);
                }
                try self.reg.move(ent, self.coll(._read_errors), self.io.coll(.read_in));
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
                    try self.reg.move(ent, self.coll(._read_init), self.io.coll(.read_in));
                    continue;
                }

                const conn_ptr = self.reg.get(conn_ent.entity, self.io.coll(.connections), Conn) catch {
                    try self.reg.move(ent, self.coll(._read_init), self.io.coll(.read_in));
                    continue;
                };

                if (self.h2_opts.tls_config) |tls_cfg| {
                    conn_ptr.tls_conn = tls.TlsConn.create(tls_cfg, self.allocator) catch {
                        _ = self.closeConn(conn_ent.entity);
                        try self.reg.move(ent, self.coll(._read_init), self.io.coll(.read_in));
                        continue;
                    };
                    try self.reg.move(ent, self.coll(._read_init), self.coll(._read_handshake));
                } else {
                    self.sessionCreate(conn_ptr, conn_ent.entity) catch {
                        _ = self.closeConn(conn_ent.entity);
                        try self.reg.move(ent, self.coll(._read_init), self.io.coll(.read_in));
                        continue;
                    };
                    try self.reg.move(ent, self.coll(._read_init), self.coll(._read_active));
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
                const conn_ptr = self.reg.get(ent, self.io.coll(.connections), Conn) catch continue;

                if (conn_ptr.tls_conn != null and conn_ptr.ng_session == null) {
                    if (max > 0 and active_count >= max) {
                        _ = self.closeConn(ent);
                        continue;
                    }
                    conn_ptr.last_active_ns = monotonicNs();
                    try self.reg.move(ent, self.io.coll(.connections), self.coll(._conn_tls_handshake));
                    active_count += 1;
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    // Not yet claimable — no first byte has arrived, so
                    // neither TLS nor a session exists. Stamp the accept
                    // time once so the pre-protocol sweep in
                    // `reapIdleConnections` can bound a SILENT connection
                    // (zero bytes → it never reaches `_read_init`, so it
                    // would otherwise sit here holding a slot forever).
                    if (conn_ptr.direction == .server and conn_ptr.last_active_ns == 0)
                        conn_ptr.last_active_ns = monotonicNs();
                    continue;
                }

                if (max > 0 and active_count >= max) {
                    _ = self.closeConn(ent);
                    continue;
                }

                conn_ptr.last_active_ns = monotonicNs();
                try self.reg.move(ent, self.io.coll(.connections), self.coll(._conn_active));
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
                    try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                    continue;
                }

                const conn_ptr = getConn(self, conn_ent.entity) orelse {
                    try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                    continue;
                };

                const tc = conn_ptr.tls_conn orelse {
                    try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
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
                        try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
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
                            if (!self.h2_opts.accept_http1) {
                                _ = self.closeConn(conn_ent.entity);
                                try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                                continue;
                            }
                            const h1c = Http1Conn.create(self.allocator) orelse {
                                _ = self.closeConn(conn_ent.entity);
                                try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                                continue;
                            };
                            conn_ptr.h1 = h1c;
                            if (feed_result.out_len > 0) {
                                self.http1Feed(conn_ptr, conn_ent.entity, decrypt_buf[0..feed_result.out_len]);
                            }
                            try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                            continue;
                        }
                        self.sessionCreate(conn_ptr, conn_ent.entity) catch {
                            _ = self.closeConn(conn_ent.entity);
                            try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                            continue;
                        };
                        if (feed_result.out_len > 0 and conn_ptr.ng_session != null) {
                            _ = c.nghttp2_session_mem_recv(
                                conn_ptr.ng_session.?,
                                &decrypt_buf,
                                feed_result.out_len,
                            );
                        }
                        try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                    },
                    .data, .err => {
                        _ = self.closeConn(conn_ent.entity);
                        try self.reg.move(ent, self.coll(._read_handshake), self.io.coll(.read_in));
                    },
                }
            }
        }

        fn transitionHandshakeConnections(self: *Self) !void {
            const entities = self._conn_tls_handshake.entitySlice();
            for (entities) |ent| {
                const conn_ptr = self.reg.get(ent, self.coll(._conn_tls_handshake), Conn) catch continue;
                // An ALPN-h1 conn (Phase 3) has no ng_session but is ready once
                // its Http1Conn is set — it must reach _conn_active so its reads
                // are processed and the idle GC can see it.
                if (conn_ptr.ng_session != null or conn_ptr.h1 != null) {
                    try self.reg.move(ent, self.coll(._conn_tls_handshake), self.coll(._conn_active));
                }
            }
        }

        // =============================================================
        // HTTP/1.1 ingress (`docs/architecture/routing-and-ingress.md`)
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
            switch (h1c.state) {
                // Raw-relay tunnel: bytes go straight to the consumer sink —
                // no buffering, no parsing. A push failure means the far end
                // is gone; tear the conn down.
                .ws_tunnel => |*tn| {
                    if (!tn.sink.push(tn.sink.ctx, bytes)) {
                        h1c.closing = true;
                        _ = self.closeConn(conn_entity);
                        return;
                    }
                    tn.unconsumed +|= @intCast(bytes.len);
                },
                // Upgraded: `buf` carries RFC 6455 frames, not HTTP requests.
                .ws_framed => {
                    h1c.buf.appendSlice(self.allocator, bytes) catch {
                        self.wsClose(conn_ptr, conn_entity, ws.CloseCode.internal_error);
                        return;
                    };
                    self.wsDrive(conn_ptr, conn_entity);
                },
                // A streaming inbound body consumes its framing first; if that
                // completes the body AND the response already went out,
                // `http1BodyComplete` re-enters `http1Drive` for a pipelined next
                // request, so the plain call below stays a no-op double-check.
                .http1 => |*st| {
                    h1c.buf.appendSlice(self.allocator, bytes) catch {
                        self.http1ErrorClose(conn_ptr, conn_entity, 500);
                        return;
                    };
                    if (st.body_active) self.http1DriveBody(conn_ptr, conn_entity);
                    self.http1Drive(conn_ptr, conn_entity);
                },
            }
        }

        /// Parse as much of the buffer as possible, emitting at most one request
        /// (no pipelining). Called after a read and after a keep-alive response
        /// drains (to pick up a coalesced next request).
        fn http1Drive(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            if (st.in_flight or st.body_active or h1c.closing) return;

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
            if (self.h2_opts.websocket_surface and wsIsUpgrade(head)) {
                self.http1SurfaceUpgrade(conn_ptr, conn_entity, head);
                return;
            }
            if (self.h2_opts.websocket_upgrades and wsIsUpgrade(head)) {
                self.wsHandshake(conn_ptr, conn_entity, head);
                return;
            }

            // `:scheme` reflects the transport: TLS-terminated h1 is https.
            const scheme: []const u8 = if (conn_ptr.tls_conn != null) "https" else "http";

            // Frame the body: chunked (Transfer-Encoding) decodes incrementally;
            // otherwise Content-Length (absent ⇒ no body). A body that has fully
            // arrived takes the classic body-complete emit below — the h1 mirror
            // of h2's END_STREAM-at-HEADERS path. An incomplete body on a
            // headers_first instance early-emits into `request_receiving` and
            // streams (`http1BeginStreamingBody`); on classic instances it waits
            // in `buf` exactly as before.
            var body: []const u8 = "";
            var total: usize = head.head_len;
            if (head.chunked) {
                const chunk_input = h1c.buf.items[head.head_len..];
                const r = http1.decodeChunked(
                    chunk_input,
                    st.chunk_pos,
                    &st.chunk_body,
                    self.allocator,
                    Http1Conn.MAX_BODY_BYTES,
                );
                st.chunk_pos = r.consumed; // resume offset for the next read
                switch (r.status) {
                    .need_more => {
                        if (self.h2_opts.headers_first) {
                            self.http1BeginStreamingBody(conn_ptr, conn_entity, head, scheme);
                        } else {
                            self.http1MaybeContinue(conn_ptr, conn_entity, head);
                        }
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
                body = st.chunk_body.items;
                total = head.head_len + r.consumed;
            } else {
                const body_len = head.content_length orelse 0;
                // The 16 MiB edge backstop guards BUFFERING, not transit: a
                // headers_first consumer may sink an arbitrarily large body
                // (`blob.receive`), so the up-front declared-length reject
                // applies only to classic instances; streaming enforces the
                // cap where bytes actually accumulate (`http1RouteBody`,
                // plus the worker's plan-tier 413 on the declared length).
                if (body_len > Http1Conn.MAX_BODY_BYTES and !self.h2_opts.headers_first) {
                    self.http1ErrorClose(conn_ptr, conn_entity, 413);
                    return;
                }
                total = head.head_len + body_len;
                if (h1c.buf.items.len < total) {
                    if (self.h2_opts.headers_first) {
                        self.http1BeginStreamingBody(conn_ptr, conn_entity, head, scheme);
                    } else {
                        self.http1MaybeContinue(conn_ptr, conn_entity, head);
                    }
                    return; // body still arriving
                }
                body = h1c.buf.items[head.head_len..total];
            }
            self.http1EmitRequest(conn_entity, head, body, scheme) catch {
                self.http1ErrorClose(conn_ptr, conn_entity, 503);
                return;
            };
            st.keep_alive = head.keep_alive;
            st.in_flight = true;
            // Reset per-request framing state for the next keep-alive request.
            st.chunk_pos = 0;
            st.chunk_body.clearRetainingCapacity();
            st.continue_sent = false;

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
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            if (!head.expect_continue or st.continue_sent) return;
            st.continue_sent = true;
            const msg = self.allocator.dupe(u8, "HTTP/1.1 100 Continue\r\n\r\n") catch return;
            self.http1Send(conn_ptr, conn_entity, msg);
        }

        // ── h1 inbound body streaming (headers_first) ─────────────────────────
        //
        // The h1 mirror of the h2 early-emission pipeline: an incomplete body
        // early-emits the request into `request_receiving` at head-parse time
        // (synthetic StreamId 1), and inbound bytes route per the consumer's
        // disposition through the SAME `Stream` accumulator + `BodyMode` switch
        // the h2 DATA callback uses — so `requestBodyBuffer` / `requestBodySink`
        // / `sweepBodySinks` serve both protocols. Where h2 backpressure is
        // flow-control window debt, h1's is the socket read: the read entity
        // parks in `_read_h1_paused` when bytes outrun the consumer and is
        // re-armed as the sink drains / the disposition lands.

        /// headers_first: the head is parsed but the body hasn't fully arrived.
        /// Early-emit the request and switch the connection into body-streaming
        /// mode. The `Expect: 100-continue` reply is decision-gated (sent when
        /// the consumer commits to the body via buffer/sink), not sent here.
        fn http1BeginStreamingBody(self: *Self, conn_ptr: *Conn, conn_entity: Entity, head: http1.Head, scheme: []const u8) void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            const s = Stream.create(conn_entity, self.allocator) orelse {
                self.http1ErrorClose(conn_ptr, conn_entity, 503);
                return;
            };
            s.emitted = true;
            s.ng_stream_id = 1;
            s.body_mode = .hold;

            const req_entity = self.http1CreateEntity(self.coll(.request_receiving), conn_entity, head, scheme) catch {
                s.free();
                self.http1ErrorClose(conn_ptr, conn_entity, 503);
                return;
            };
            s.entity = req_entity;
            st.stream = s;

            st.keep_alive = head.keep_alive;
            st.expect_continue = head.expect_continue;
            st.in_flight = true;
            st.body_active = true;
            st.body_chunked = head.chunked;
            st.body_remaining = if (head.chunked) null else (head.content_length orelse 0);
            st.body_seen = 0;

            // Drop the head; `buf` now starts at the body region (the chunked
            // resume offset `chunk_pos` is relative to it). The head's slices
            // (`head`, the entity's ReqHeaders source) were consumed above.
            const leftover = h1c.buf.items.len - head.head_len;
            if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[head.head_len..]);
            h1c.buf.shrinkRetainingCapacity(leftover);

            // Chunked: the parse attempt already decoded a prefix into
            // `chunk_body` — route it (under `.hold`) before continuing.
            if (head.chunked and st.chunk_body.items.len > 0) {
                const ok = self.http1RouteBody(conn_ptr, conn_entity, st.chunk_body.items);
                st.chunk_body.clearRetainingCapacity();
                if (!ok) return;
            }
            // Consume whatever body bytes already arrived.
            self.http1DriveBody(conn_ptr, conn_entity);
        }

        /// Consume available inbound body bytes for the in-flight streaming
        /// request (the h1 mirror of `onDataChunkRecvCb` + the END_STREAM
        /// block). Leaves `buf` holding only not-yet-consumable bytes (a
        /// chunk-framing tail / a pipelined next request).
        fn http1DriveBody(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            if (!st.body_active or h1c.closing) return;
            const s = st.stream orelse return;

            if (st.body_chunked) {
                // The decode cap guards ACCUMULATION: `.hold`/`.buffer` grow
                // the stream's buffer, so bound their remaining allowance at
                // the edge backstop; `.sink`/`.discard` route bytes straight
                // out and per-pass input is already bounded by read pacing.
                const cap: usize = switch (s.body_mode) {
                    .hold, .buffer, .auto => Http1Conn.MAX_BODY_BYTES -| s.body_len,
                    .sink, .discard => std.math.maxInt(usize),
                };
                const r = http1.decodeChunked(h1c.buf.items, st.chunk_pos, &st.chunk_body, self.allocator, cap);
                if (st.chunk_body.items.len > 0) {
                    const ok = self.http1RouteBody(conn_ptr, conn_entity, st.chunk_body.items);
                    st.chunk_body.clearRetainingCapacity();
                    if (!ok) return;
                }
                switch (r.status) {
                    .need_more, .complete => {
                        // Drop fully-decoded framing from the buffer; the
                        // resume offset is relative to what remains.
                        if (r.consumed > 0) {
                            const leftover = h1c.buf.items.len - r.consumed;
                            if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[r.consumed..]);
                            h1c.buf.shrinkRetainingCapacity(leftover);
                        }
                        st.chunk_pos = 0;
                        if (r.status == .complete) self.http1BodyComplete(conn_ptr, conn_entity);
                    },
                    .malformed => self.http1ErrorClose(conn_ptr, conn_entity, 400),
                    .too_large => self.http1ErrorClose(conn_ptr, conn_entity, 413),
                }
                return;
            }

            const remaining = st.body_remaining orelse 0;
            const take = @min(h1c.buf.items.len, remaining);
            if (take > 0) {
                if (!self.http1RouteBody(conn_ptr, conn_entity, h1c.buf.items[0..take])) return;
                const leftover = h1c.buf.items.len - take;
                if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[take..]);
                h1c.buf.shrinkRetainingCapacity(leftover);
                st.body_remaining = remaining - take;
            }
            if ((st.body_remaining orelse 0) == 0) self.http1BodyComplete(conn_ptr, conn_entity);
        }

        /// Route streamed body bytes per the in-flight stream's mode. Returns
        /// false when the request can take no more bytes (error response
        /// queued / connection torn down) — callers stop driving.
        fn http1RouteBody(self: *Self, conn_ptr: *Conn, conn_entity: Entity, bytes: []const u8) bool {
            const h1c = conn_ptr.h1.?;
            const st = &h1c.state.http1; // only reachable mid streaming body
            const s = st.stream.?;
            st.body_seen += bytes.len;
            // Shared routing core (`Stream.routeInbound`); this arm owns only
            // the h1-specific verbs. No repayment on .consume — the wire
            // bytes are already read; h1's "debt" (`unconsumed`) is purely
            // the read-pause accounting. The cap is the Content-Length
            // analog of the chunked decode backstop (413). A sink failure
            // tears the CONNECTION down — for h1 the stream IS the
            // connection (`serverStreamAbort`'s rule); `closing` makes the
            // rest of this drive inert while the destroy is in flight.
            switch (s.routeInbound(bytes, Http1Conn.MAX_BODY_BYTES)) {
                .consume, .held => {},
                .append_failed => {
                    self.http1ErrorClose(conn_ptr, conn_entity, 500);
                    return false;
                },
                .over_cap => {
                    self.http1ErrorClose(conn_ptr, conn_entity, 413);
                    return false;
                },
                .sink_failed => {
                    h1c.closing = true;
                    _ = self.closeConn(conn_entity);
                    return false;
                },
            }
            return true;
        }

        /// The last body byte was consumed off the wire — the h1 mirror of the
        /// h2 END_STREAM block in `onFrameRecvCb`.
        fn http1BodyComplete(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            const s = st.stream orelse return;
            st.body_active = false;
            s.inbound_eof = true;
            self.http1UnparkRead(h1c);
            switch (s.body_mode) {
                .sink => {
                    if (s.sink) |sk| {
                        sk.finish(sk.ctx);
                        s.sink_finished = true;
                    }
                },
                .discard => {},
                // Only a `.buffer` decision auto-completes (same contract as
                // h2): attach the body and restore request_out's
                // body-complete shape. `.hold` bytes wait under `inbound_eof`
                // for the consumer's disposition (`requestBodyBuffer`
                // attaches in place / a sink drains them at attach).
                .buffer => {
                    if (self.reg.isInCollection(s.entity, self.coll(.request_buffering))) {
                        self.reg.set(s.entity, self.coll(.request_buffering), ReqBody, takeBody(s)) catch {};
                        self.reg.move(s.entity, self.coll(.request_buffering), self.coll(.request_out)) catch {};
                    }
                },
                .hold, .auto => {},
            }
            // The response already went out (early reply mid-body): the cycle
            // is over — reset and pick up a pipelined next request.
            if (!st.in_flight and !h1c.closing) {
                if (st.keep_alive) {
                    self.http1FinishCycle(conn_ptr);
                    self.http1Drive(conn_ptr, conn_entity);
                } else {
                    h1c.closing = true;
                }
            }
        }

        /// A request cycle fully ended (response written AND inbound body fully
        /// consumed): drop the per-request stream state so the next keep-alive
        /// request starts clean. A sink reference, if any, is released by
        /// `sweepBodySinks` (it sees the stream gone — or, when a new request's
        /// sink has replaced it, the ctx mismatch).
        fn http1FinishCycle(self: *Self, conn_ptr: *Conn) void {
            _ = self;
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            if (st.stream) |s| {
                s.free();
                st.stream = null;
            }
            st.body_active = false;
            st.body_remaining = null;
            st.body_chunked = false;
            st.body_seen = 0;
            st.expect_continue = false;
            st.continue_sent = false;
            st.chunk_pos = 0;
            st.chunk_body.clearRetainingCapacity();
        }

        /// h1 mirror of `flipInboundBodyToDiscard`: a response is going out
        /// while the request body is still inbound. Stop accumulating and keep
        /// draining the remaining wire bytes so keep-alive framing survives.
        /// An `Expect: 100-continue` client that was never told to proceed
        /// will never send the body — close instead of waiting forever.
        /// Runs BEFORE the response serializes (it may clear `keep_alive`).
        fn http1FlipInboundToDiscard(self: *Self, conn_ptr: *Conn) void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            if (!st.body_active) return;
            const s = st.stream orelse return;
            if (st.expect_continue and !st.continue_sent and st.body_seen == 0) {
                st.keep_alive = false;
            }
            _ = s.flipToDiscard() orelse return;
            self.http1UnparkRead(h1c);
        }

        /// Decision-gated `100 Continue` for a streaming body: sent when the
        /// consumer commits to reading it (buffer / sink attach).
        fn http1MaybeContinueStored(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => return,
            };
            if (!st.expect_continue or st.continue_sent or !st.body_active) return;
            st.continue_sent = true;
            const msg = self.allocator.dupe(u8, "HTTP/1.1 100 Continue\r\n\r\n") catch return;
            self.http1Send(conn_ptr, conn_entity, msg);
        }

        /// Re-arm a read parked for inbound-body backpressure.
        fn http1UnparkRead(self: *Self, h1c: *Http1Conn) void {
            if (h1c.paused_read.isNil()) return;
            const ent = h1c.paused_read;
            h1c.paused_read = Entity.nil;
            self.reg.move(ent, self.coll(._read_h1_paused), self.io.coll(.read_in)) catch {};
        }

        /// True when the in-flight streaming body has outrun its consumer:
        /// `.hold` accumulated past the cap with no disposition yet, or
        /// `.sink` pushed-but-undrained debt past the cap. The caller parks
        /// the read entity instead of re-arming.
        fn http1ReadShouldPause(self: *Self, conn_ptr: *Conn) bool {
            _ = self;
            const h1c = conn_ptr.h1 orelse return false;
            if (h1c.closing) return false;
            switch (h1c.state) {
                // Tunnel backpressure: pushed-but-undrained relay bytes.
                .ws_tunnel => |*tn| return tn.unconsumed >= Http1Conn.STREAM_PAUSE_BYTES,
                // Framed mode has no inbound read backpressure (pre-existing;
                // flagged in the §4.1 analysis as a separate audit note).
                .ws_framed => return false,
                .http1 => |*st| {
                    if (!st.body_active) return false;
                    const s = st.stream orelse return false;
                    return switch (s.body_mode) {
                        .hold => s.body_len >= Http1Conn.STREAM_PAUSE_BYTES,
                        .sink => s.unconsumed >= Http1Conn.STREAM_PAUSE_BYTES,
                        else => false,
                    };
                },
            }
        }

        /// Return parked h1 reads whose connection died to the io pool, the
        /// same recycling `readsFeedData` does for live-path stale reads (conn
        /// teardown can't — it doesn't know the read entity).
        fn sweepPausedH1Reads(self: *Self) void {
            const entities = self._read_h1_paused.entitySlice();
            const conn_ents = self._read_h1_paused.column(rio.ConnEntity);
            for (entities, conn_ents) |ent, ce| {
                if (self.reg.isStale(ce.entity)) {
                    self.reg.move(ent, self.coll(._read_h1_paused), self.io.coll(.read_in)) catch {};
                }
            }
        }

        /// Create a request entity in `cl` from a parsed h1 head, synthesizing
        /// the h2-style pseudo-headers so all downstream routing/dispatch is
        /// protocol-agnostic. `StreamId` is the synthetic 1 (one request/conn);
        /// `ReqBody` starts empty (the caller attaches a complete body or
        /// streams into it).
        fn http1CreateEntity(self: *Self, cl: *StreamColl, conn_entity: Entity, head: http1.Head, scheme: []const u8) !Entity {
            const req_entity = try self.reg.create(cl);
            errdefer self.destroyEntity(req_entity) catch {};

            try self.reg.set(req_entity, cl, StreamId, .{ .id = 1 });
            try self.reg.set(req_entity, cl, Session, .{ .entity = conn_entity });

            const rh = try self.http1BuildReqHeaders(head, scheme);
            try self.reg.set(req_entity, cl, ReqHeaders, rh);
            try self.reg.set(req_entity, cl, ReqBody, .{ .data = null, .len = 0 });
            return req_entity;
        }

        /// Build a `request_out` entity from a parsed h1 head + complete body.
        fn http1EmitRequest(self: *Self, conn_entity: Entity, head: http1.Head, body: []const u8, scheme: []const u8) !void {
            const req_entity = try self.http1CreateEntity(self.coll(.request_out), conn_entity, head, scheme);
            errdefer self.destroyEntity(req_entity) catch {};

            var body_data: ?[*]u8 = null;
            if (body.len > 0) {
                const copy = try self.allocator.dupe(u8, body);
                body_data = copy.ptr;
            }
            try self.reg.set(req_entity, self.coll(.request_out), ReqBody, .{ .data = body_data, .len = @intCast(body.len) });
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

        /// RFC 7230 §6.1: any header NAMED in the request's `Connection`
        /// value is hop-by-hop too and must not survive the h1→h2
        /// synthesis (forwarding one is the request-smuggling /
        /// cache-poisoning vector — front-door hardening plan B8). This
        /// runs HERE (not in the proxy) because `http1IsHopByHop`
        /// removes `connection` itself from the synthesized head, so
        /// downstream consumers can never see the nomination list.
        fn http1NominatedByConnection(head: http1.Head, name: []const u8) bool {
            for (head.headers) |hh| {
                if (!std.ascii.eqlIgnoreCase(hh.name, "connection")) continue;
                var it = std.mem.tokenizeAny(u8, hh.value, ", \t");
                while (it.next()) |tok| {
                    if (std.ascii.eqlIgnoreCase(tok, name)) return true;
                }
            }
            return false;
        }

        /// Pack a parsed h1 head into an `h2.ReqHeaders` — four synthesized
        /// pseudo-headers followed by the request's end-to-end headers
        /// (names lowercased to match h2/handler lookups). One combined buffer
        /// holds the field array + name/value bytes, freed by `ReqHeaders.deinit`.
        /// Build the h1 request's ReqHeaders through the SAME `HeaderBuf`
        /// the h2 path uses — one hardened growth/pack implementation, one
        /// combined-allocation layout (§4.2: a separate h1 layout would
        /// risk drifting from the h2spec-hardened builder).
        /// Pseudo-headers first (h2 ordering rules), then the head's real
        /// headers lowercased, minus hop-by-hop + Connection-nominated.
        fn http1BuildReqHeaders(self: *Self, head: http1.Head, scheme: []const u8) !ReqHeaders {
            var hb: HeaderBuf = .{};
            defer hb.deinit(self.allocator);

            if (!hb.append(self.allocator, ":method", head.method, false)) return error.OutOfMemory;
            if (!hb.append(self.allocator, ":path", head.target, false)) return error.OutOfMemory;
            if (!hb.append(self.allocator, ":scheme", scheme, false)) return error.OutOfMemory;
            if (!hb.append(self.allocator, ":authority", head.host orelse "", false)) return error.OutOfMemory;
            for (head.headers) |hh| {
                if (http1IsHopByHop(hh.name)) continue;
                if (http1NominatedByConnection(head, hh.name)) continue;
                if (!hb.append(self.allocator, hh.name, hh.value, true)) return error.OutOfMemory;
            }

            var fields: ?[*]HeaderField = null;
            var count: u32 = 0;
            var buf_len: u32 = 0;
            const buf = hb.finalize(self.allocator, &fields, &count, &buf_len) orelse
                return error.OutOfMemory; // count >= 4 (pseudo) — null here is alloc failure
            return .{ .fields = fields, .count = count, ._buf = buf, ._buf_len = buf_len };
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
            switch (h1c.state) {
                .http1 => |*st| st.keep_alive = false,
                else => {},
            }
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
            // A streaming body that error-closed mid-flight (malformed chunk,
            // cap) already queued its 4xx and doomed the conn — a worker
            // response for that request has nowhere to go. (Unreachable on
            // the classic path: parse errors precede emission there. The
            // non-http1 arms are equally response-less by construction.)
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => null,
            };
            if (h1c.closing or st == null) {
                io_res.err = -1;
                try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));
                return;
            }
            // Responding while the request body is still inbound (early 4xx,
            // worker error paths): flip the inbound side to discard FIRST —
            // it may clear `keep_alive`, which the serializer consults below.
            self.http1FlipInboundToDiscard(conn_ptr);
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
            try http1.writeResponse(&out, self.allocator, status.code, hdr_store[0..hn], body, st.?.keep_alive);
            const data = try out.toOwnedSlice(self.allocator);
            self.http1Send(conn_ptr, conn_entity, data);

            io_res.err = 0;
            try self.reg.move(ent, self.coll(.response_in), self.coll(.response_out));

            if (st.?.keep_alive) {
                st.?.in_flight = false;
                if (!st.?.body_active) {
                    // Cycle over (body already complete / never had one);
                    // pick up a coalesced next request. When the body is
                    // still draining post-flip, `http1BodyComplete` finishes
                    // the cycle instead.
                    self.http1FinishCycle(conn_ptr);
                    self.http1Drive(conn_ptr, conn_entity);
                }
            } else {
                // Connection: close — let the idle-timeout GC reap once the write
                // drains.
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
            // Same mid-flight error-close guard as `http1WriteResponse`.
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                else => null,
            };
            if (h1c.closing or st == null) {
                io_res.err = -1;
                try self.reg.move(ent, self.coll(.stream_response_in), self.coll(.response_out));
                return;
            }
            // Same early-reply rule as `http1WriteResponse`: a streaming
            // response starting while the request body is still inbound flips
            // the inbound side to discard (may clear `keep_alive`, consulted
            // at `http1StreamEnd`).
            self.http1FlipInboundToDiscard(conn_ptr);
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
            st.?.streaming = true;
            io_res.err = 0;
            // Backpressure: hold the entity until the head write drains, so the
            // worker can't push the first chunk until the head is on the wire
            // (keeps the single-write-in-flight invariant from the very start).
            st.?.sending_entity = ent;
            try self.reg.move(ent, self.coll(.stream_response_in), self.coll(._stream_data_sending));
        }

        /// Write one body piece as a chunk, then return the entity to
        /// `stream_data_out` so the worker can push the next. The worker-owned
        /// `rb.data` is copied into the framed buffer, then freed + nulled (the
        /// same ownership transfer the h2 path does onto its `Stream`).
        fn http1StreamChunk(self: *Self, ent: Entity, conn_ptr: *Conn, conn_entity: Entity, rb: *RespBody) !void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                // Non-http1 arms never host stream entities; drop the piece.
                else => {
                    if (rb.data) |d| {
                        self.allocator.free(d[0..rb.len]);
                        rb.data = null;
                        rb.len = 0;
                    }
                    try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.stream_data_out));
                    return;
                },
            };
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
                    st.sending_entity = ent;
                    try self.reg.move(ent, self.coll(.stream_data_in), self.coll(._stream_data_sending));
                    return;
                }
                self.allocator.free(d[0..rb.len]);
                rb.data = null;
                rb.len = 0;
            }
            // Empty piece — nothing to write, so no backpressure: return the
            // entity immediately for the next push.
            try self.reg.move(ent, self.coll(.stream_data_in), self.coll(.stream_data_out));
        }

        /// End a streaming response: write the zero-terminator, then finalize the
        /// entity and honor keep-alive (chunked delimits the body, so the conn
        /// can serve the next request) vs close.
        fn http1StreamEnd(self: *Self, ent: Entity, conn_ptr: *Conn, conn_entity: Entity, io_res: *H2IoResult) !void {
            const h1c = conn_ptr.h1.?;
            const st = switch (h1c.state) {
                .http1 => |*st| st,
                // Non-http1 arms never host stream entities; finalize the
                // entity without touching conn state.
                else => {
                    io_res.err = 0;
                    try self.reg.move(ent, self.coll(.stream_close_in), self.coll(.response_out));
                    return;
                },
            };
            const term = try self.allocator.dupe(u8, http1.CHUNK_TERMINATOR);
            self.http1Send(conn_ptr, conn_entity, term);
            st.streaming = false;
            io_res.err = 0;
            try self.reg.move(ent, self.coll(.stream_close_in), self.coll(.response_out));
            if (st.keep_alive) {
                st.in_flight = false;
                if (!st.body_active) {
                    self.http1FinishCycle(conn_ptr);
                    self.http1Drive(conn_ptr, conn_entity);
                }
            } else {
                h1c.closing = true;
            }
        }

        // ── WebSocket transport (docs/architecture/websockets.md) ───────────
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

        /// websocket_surface (architecture/websockets.md): park the connection and
        /// emit the Upgrade head to the consumer for disposition. The 101 is
        /// DEFERRED — `wsUpgradeAccept` sends it only once the upstream
        /// tunnel exists, so a refused tunnel degrades to a plain HTTP error
        /// (no half-upgraded socket). Early frame bytes the client coalesced
        /// after the handshake stay in `buf` until accept.
        fn http1SurfaceUpgrade(self: *Self, conn_ptr: *Conn, conn_entity: Entity, head: http1.Head) void {
            const h1c = conn_ptr.h1.?;
            var key: []const u8 = "";
            for (head.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-key")) key = h.value;
            }
            const key_owned = self.allocator.dupe(u8, key) catch {
                self.http1ErrorClose(conn_ptr, conn_entity, 500);
                return;
            };
            const scheme: []const u8 = if (conn_ptr.tls_conn != null) "https" else "http";
            _ = self.http1CreateEntity(self.coll(.ws_upgrade_out), conn_entity, head, scheme) catch {
                self.allocator.free(key_owned);
                self.http1ErrorClose(conn_ptr, conn_entity, 503);
                return;
            };
            h1c.beginPendingUpgrade(key_owned, head.keep_alive);
            // Drop the head; anything left in `buf` is early frame bytes.
            const leftover = h1c.buf.items.len - head.head_len;
            if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[head.head_len..]);
            h1c.buf.shrinkRetainingCapacity(leftover);
        }

        pub const WsUpgradeDecision = enum { ok, gone };

        /// Accept a surfaced Upgrade: send the deferred `101`, switch the
        /// connection into raw-relay tunnel mode (socket bytes → `sink`,
        /// verbatim — no frame parsing at this hop), and hand any early
        /// frame bytes over. h2 holds one sink reference, released by
        /// `sweepBodySinks` when the connection dies; window repayment is
        /// the socket-read park/unpark at the streamed-body cap.
        pub fn wsUpgradeAccept(h2: *Self, ent: Entity, sink: BodySink) WsUpgradeDecision {
            if (!h2.reg.isInCollection(ent, h2.coll(.ws_upgrade_out))) return .gone;
            const sess = h2.reg.get(ent, h2.coll(.ws_upgrade_out), Session) catch return .gone;
            defer h2.destroyEntity(ent) catch {};
            const conn_ptr = getConn(h2, sess.entity) orelse return .gone;
            const h1c = conn_ptr.h1 orelse return .gone;
            const pending_key = switch (h1c.state) {
                .http1 => |*st| st.pending_upgrade orelse return .gone,
                else => return .gone,
            };
            if (h1c.closing) return .gone;

            var accept_buf: [ws.ACCEPT_LEN]u8 = undefined;
            const accept = ws.acceptKey(pending_key, &accept_buf);
            var resp: std.ArrayList(u8) = .empty;
            defer resp.deinit(h2.allocator);
            resp.appendSlice(h2.allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ") catch return .gone;
            resp.appendSlice(h2.allocator, accept) catch return .gone;
            resp.appendSlice(h2.allocator, "\r\n\r\n") catch return .gone;

            // Materialize the 101 BEFORE any state flips so every failure arm
            // leaves the conn in its parked-pending shape (rolling back by
            // hand would briefly hold a half-flipped conn).
            const out = resp.toOwnedSlice(h2.allocator) catch return .gone;

            h2.body_sinks.append(h2.allocator, .{
                .conn_entity = sess.entity,
                .stream_id = 0, // sentinel: h1 tunnel sink (no h2 stream)
                .sink = sink,
            }) catch {
                h2.allocator.free(out);
                return .gone;
            };

            // Flip to tunnel BEFORE sending the 101: the write completion must
            // land in the ws arm of `writesAccount` (→ wsFlush) so tunnel bytes
            // queued behind the 101 ship as soon as it drains.
            h1c.acceptTunnel(sink);
            h2.http1Send(conn_ptr, sess.entity, out);

            // Early frame bytes that rode in with the handshake.
            if (h1c.buf.items.len > 0) {
                if (!sink.push(sink.ctx, h1c.buf.items)) {
                    // End the CONN the way every conn ends — through
                    // conn_closing, so io releases the descriptor slot. A
                    // bare destroy here bypassed the teardown entirely
                    // (and, under the archetype, tripped the Fd guard's
                    // conditions).
                    _ = h2.closeConn(sess.entity);
                    return .ok; // sink owns the failure; conn is going down
                }
                h1c.state.ws_tunnel.unconsumed +|= @intCast(h1c.buf.items.len);
                h1c.buf.clearRetainingCapacity();
            }
            return .ok;
        }

        /// Refuse a surfaced Upgrade with a plain HTTP status — the client
        /// never sees a 101.
        pub fn wsUpgradeReject(h2: *Self, ent: Entity, status: u16) void {
            if (!h2.reg.isInCollection(ent, h2.coll(.ws_upgrade_out))) return;
            const sess = h2.reg.get(ent, h2.coll(.ws_upgrade_out), Session) catch return;
            defer h2.destroyEntity(ent) catch {};
            const conn_ptr = getConn(h2, sess.entity) orelse return;
            self_reject: {
                const h1c = conn_ptr.h1 orelse break :self_reject;
                switch (h1c.state) {
                    .http1 => |*st| if (st.pending_upgrade == null) break :self_reject,
                    else => break :self_reject,
                }
                h1c.rejectPendingUpgrade();
            }
            h2.http1ErrorClose(conn_ptr, sess.entity, status);
        }

        /// Write raw bytes down a tunnel connection (the upstream leg's
        /// relay). Order-preserving, one socket write in flight (the
        /// `WsWrite.out` queue).
        pub fn wsTunnelWrite(h2: *Self, conn_entity: Entity, bytes: []const u8) void {
            const conn_ptr = getConn(h2, conn_entity) orelse return;
            const h1c = conn_ptr.h1 orelse return;
            const tn = switch (h1c.state) {
                .ws_tunnel => |*tn| tn,
                else => return,
            };
            if (tn.wr.closing) return;
            tn.wr.out.appendSlice(h2.allocator, bytes) catch return;
            h2.wsFlush(conn_ptr, conn_entity);
        }

        /// Close a tunnel connection once its outbound queue drains (the
        /// upstream side ended). The sink reference releases via
        /// `sweepBodySinks` when the conn dies.
        pub fn wsTunnelClose(h2: *Self, conn_entity: Entity) void {
            const conn_ptr = getConn(h2, conn_entity) orelse return;
            const h1c = conn_ptr.h1 orelse return;
            const wr = h1c.wsWrite() orelse {
                _ = h2.closeConn(conn_entity);
                return;
            };
            wr.closing = true;
            h2.wsFlush(conn_ptr, conn_entity);
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
            const authority = self.allocator.dupe(u8, head.host orelse "") catch {
                _ = self.closeConn(conn_entity);
                return;
            };
            const path = self.allocator.dupe(u8, head.target) catch {
                self.allocator.free(authority);
                _ = self.closeConn(conn_entity);
                return;
            };

            // Drop the consumed request head; what's left in `buf` is the start of
            // the frame stream. Do this before switching arms so a parse never
            // sees the HTTP head as frame bytes.
            const head_len = head.head_len;
            const leftover = h1c.buf.items.len - head_len;
            if (leftover > 0) std.mem.copyForwards(u8, h1c.buf.items[0..leftover], h1c.buf.items[head_len..]);
            h1c.buf.shrinkRetainingCapacity(leftover);

            h1c.acceptFramed(authority, path);
            const fr = &h1c.state.ws_framed;

            var resp: std.ArrayList(u8) = .empty;
            defer resp.deinit(self.allocator);
            resp.appendSlice(self.allocator, "HTTP/1.1 101 Switching Protocols\r\n") catch {
                _ = self.closeConn(conn_entity);
                return;
            };
            resp.appendSlice(self.allocator, "Upgrade: websocket\r\nConnection: Upgrade\r\n") catch {
                _ = self.closeConn(conn_entity);
                return;
            };
            resp.appendSlice(self.allocator, "Sec-WebSocket-Accept: ") catch {
                _ = self.closeConn(conn_entity);
                return;
            };
            resp.appendSlice(self.allocator, accept) catch {
                _ = self.closeConn(conn_entity);
                return;
            };
            resp.appendSlice(self.allocator, "\r\n\r\n") catch {
                _ = self.closeConn(conn_entity);
                return;
            };

            fr.wr.out.appendSlice(self.allocator, resp.items) catch {
                _ = self.closeConn(conn_entity);
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
            const fr = switch (h1c.state) {
                .ws_framed => |*fr| fr,
                else => return,
            };
            if (fr.wr.closing) return;

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
                if (fr.wr.closing) break;
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
        /// call is copied (into the fragment buffer or a `ws_message_out` entity).
        fn wsHandleFrame(self: *Self, conn_ptr: *Conn, conn_entity: Entity, frame: ws.Frame) !void {
            const h1c = conn_ptr.h1.?;
            const fr = switch (h1c.state) {
                .ws_framed => |*fr| fr,
                else => return,
            };
            switch (frame.opcode) {
                // Auto-pong: bounce the application data back; the handler never
                // sees ping/pong (architecture/websockets.md).
                .ping => try ws.writeFrame(&fr.wr.out, self.allocator, .pong, frame.payload),
                .pong => {},
                .close => {
                    // Surface the disconnect (piece D → `onDisconnect`) then echo a
                    // Close and tear down once it drains.
                    try self.wsEmitMessage(conn_entity, @intFromEnum(ws.Opcode.close), "");
                    if (!fr.wr.closing) {
                        ws.writeClose(&fr.wr.out, self.allocator, ws.CloseCode.normal, "") catch {};
                        fr.wr.closing = true;
                    }
                },
                // Data frames: the fragmentation core owns the §5.4 rules + the
                // running size cap; a completed message surfaces to the consumer.
                .text, .binary, .continuation => {
                    switch (try fr.frag.feed(self.allocator, frame.opcode, frame.fin, frame.payload, Http1Conn.MAX_WS_MESSAGE)) {
                        .pending => {},
                        .message => |m| {
                            try self.wsEmitMessage(conn_entity, m.opcode, m.payload);
                            fr.frag.reset();
                        },
                    }
                },
                _ => return error.WsProtocol,
            }
        }

        /// Emit a completed inbound message (or a client-close signal, opcode 8)
        /// onto `ws_message_out` for the consumer. `payload` is copied into an
        /// allocator-owned `ReqBody` the entity's destroy frees.
        fn wsEmitMessage(self: *Self, conn_entity: Entity, opcode: u8, payload: []const u8) !void {
            const ent = try self.reg.create(self.coll(.ws_message_out));
            errdefer self.destroyEntity(ent) catch {};
            try self.reg.set(ent, self.coll(.ws_message_out), Session, .{ .entity = conn_entity });
            try self.reg.set(ent, self.coll(.ws_message_out), WsMeta, .{ .opcode = opcode });
            var data: ?[*]u8 = null;
            if (payload.len > 0) {
                const copy = try self.allocator.dupe(u8, payload);
                data = copy.ptr;
            }
            try self.reg.set(ent, self.coll(.ws_message_out), ReqBody, .{ .data = data, .len = @intCast(payload.len) });
        }

        /// Queue a Close frame and begin teardown; the connection is destroyed by
        /// `wsFlush` once the Close (and anything ahead of it) drains.
        fn wsClose(self: *Self, conn_ptr: *Conn, conn_entity: Entity, code: u16) void {
            const h1c = conn_ptr.h1.?;
            const wr = h1c.wsWrite() orelse return;
            if (!wr.closing) {
                ws.writeClose(&wr.out, self.allocator, code, "") catch {};
                wr.closing = true;
            }
            self.wsFlush(conn_ptr, conn_entity);
        }

        /// Flush the per-connection outbound byte queue with exactly one socket
        /// write in flight (`WsWrite.write_inflight`): preserves frame order on the
        /// wire and coalesces a burst into one write. The completion lands in
        /// `writesAccount`, which clears the flag and re-flushes. When a closing
        /// connection has fully drained, reap it.
        fn wsFlush(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            const h1c = conn_ptr.h1.?;
            const wr = h1c.wsWrite() orelse return;
            if (wr.write_inflight) return;
            if (wr.out.items.len == 0) {
                if (wr.closing) _ = self.closeConn(conn_entity);
                return;
            }
            const data = wr.out.toOwnedSlice(self.allocator) catch return;
            wr.write_inflight = true;
            self.http1Send(conn_ptr, conn_entity, data);
        }

        /// Piece E (h2 side): drain `ws_send_in` — frames the consumer queued via
        /// `stream.write` — RFC-6455-framing each by opcode onto the connection's
        /// outbound queue. A `close` opcode requests a clean teardown. The entity
        /// is one-shot (destroyed here); backpressure lives on `WsWrite.out`.
        fn consumeWsSends(self: *Self) !void {
            const entities = self.ws_send_in.entitySlice();
            const sessions = self.ws_send_in.column(Session);
            const metas = self.ws_send_in.column(WsMeta);
            const bodies = self.ws_send_in.column(ReqBody);

            for (entities, sessions, metas, bodies) |ent, sess, meta, *body| {
                if (self.reg.isStale(sess.entity)) {
                    try self.destroyEntity(ent);
                    continue;
                }
                // Extended-CONNECT tunnel: the Session is a WS identity
                // entity (not a conn) — frames ride the stream's send
                // queue.
                if (self.reg.isInCollection(sess.entity, self.coll(.ws_streams))) {
                    const payload = if (body.data) |d| d[0..body.len] else "";
                    self.wsStreamSend(sess.entity, meta.opcode, payload);
                    try self.destroyEntity(ent);
                    continue;
                }
                const conn_ptr = getConn(self, sess.entity) orelse {
                    try self.destroyEntity(ent);
                    continue;
                };
                const h1c = conn_ptr.h1 orelse {
                    try self.destroyEntity(ent);
                    continue;
                };
                const wr = h1c.wsWrite() orelse {
                    try self.destroyEntity(ent);
                    continue;
                };
                if (wr.closing) {
                    try self.destroyEntity(ent);
                    continue;
                }

                const opcode: ws.Opcode = @enumFromInt(@as(u4, @truncate(meta.opcode)));
                const payload = if (body.data) |d| d[0..body.len] else "";
                if (opcode == .close) {
                    self.wsClose(conn_ptr, sess.entity, ws.CloseCode.normal);
                } else {
                    ws.writeFrame(&wr.out, self.allocator, opcode, payload) catch {
                        try self.destroyEntity(ent);
                        continue;
                    };
                    self.wsFlush(conn_ptr, sess.entity);
                }
                try self.destroyEntity(ent);
            }
        }

        // =============================================================
        // Helper: submit a write entity
        // =============================================================

        fn submitWrite(self: *Self, conn_entity: Entity, data: []u8) !void {
            const we = try self.reg.create(self.io.coll(.write_in));
            try self.reg.set(we, self.io.coll(.write_in), rio.ConnEntity, .{ .entity = conn_entity });
            try self.reg.set(we, self.io.coll(.write_in), rio.WriteBuf, .{ .data = data.ptr, .len = @intCast(data.len) });
        }

        /// Serialized egress for the h2 server DATA path: hand `data` to the
        /// connection's ordered send queue (takes ownership) and submit it
        /// only if no write is in flight for that conn — otherwise it waits
        /// its turn, submitted by `writesAccount` when the current write
        /// completes. This is what keeps a multi-batch large response (or
        /// TLS record stream) in wire order; see `Conn.send_queue`. On a
        /// submit/enqueue failure the buffer is freed (the caller has
        /// already relinquished it).
        fn enqueueConnSend(self: *Self, conn_ptr: *Conn, conn_entity: Entity, data: []u8) void {
            conn_ptr.send_seq += 1;
            if (conn_ptr.send_inflight) {
                conn_ptr.send_queue.append(self.allocator, data) catch self.allocator.free(data);
                return;
            }
            self.submitWrite(conn_entity, data) catch {
                self.allocator.free(data);
                return;
            };
            conn_ptr.send_inflight = true;
        }

        /// A completed write drained (`writesAccount`): clear the in-flight
        /// flag and submit the next queued buffer, if any, preserving order.
        /// Called only on a live conn (a failed/destroyed conn frees the
        /// queue in `Conn.deinit`).
        fn pumpConnSend(self: *Self, conn_ptr: *Conn, conn_entity: Entity) void {
            conn_ptr.send_inflight = false;
            if (conn_ptr.send_queue.items.len == 0) return;
            const next = conn_ptr.send_queue.orderedRemove(0);
            self.submitWrite(conn_entity, next) catch {
                self.allocator.free(next);
                return;
            };
            conn_ptr.send_inflight = true;
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
                    try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                    continue;
                }

                const conn_ptr = self.reg.get(conn_ent.entity, self.coll(._conn_active), Conn) catch {
                    try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
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
                                    _ = self.closeConn(conn_ent.entity);
                                    try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                                    continue;
                                }
                                if (fr.out_len > 0) self.http1Feed(conn_ptr, conn_ent.entity, decrypt_buf[0..fr.out_len]);
                            } else {
                                self.http1Feed(conn_ptr, conn_ent.entity, data_ptr[0..data_len]);
                            }
                            conn_ptr.last_active_ns = monotonicNs();
                        }
                    }
                    // Inbound-body backpressure: park instead of re-arming
                    // when the streamed body has outrun its consumer. The
                    // feed may have torn the conn down (deferred destroy) —
                    // re-resolve before dereferencing.
                    if (!self.reg.isStale(conn_ent.entity)) {
                        if (getConn(self, conn_ent.entity)) |cp| {
                            if (self.http1ReadShouldPause(cp)) {
                                cp.h1.?.paused_read = ent;
                                try self.reg.move(ent, self.coll(._read_active), self.coll(._read_h1_paused));
                                continue;
                            }
                        }
                    }
                    try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                    continue;
                }

                if (conn_ptr.ng_session == null) {
                    try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                    continue;
                }

                if (rr.data) |data_ptr| {
                    const data_len: usize = @intCast(rr.result);

                    if (conn_ptr.tls_conn) |tc| {
                        var decrypt_buf: [65536]u8 = undefined;
                        const feed_result = tc.feed(data_ptr[0..data_len], &decrypt_buf);
                        if (feed_result.result == .err) {
                            _ = self.closeConn(conn_ent.entity);
                            try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                            continue;
                        }
                        if (feed_result.out_len > 0) {
                            const rv = c.nghttp2_session_mem_recv(conn_ptr.ng_session.?, &decrypt_buf, feed_result.out_len);
                            if (rv < 0) {
                                _ = self.closeConn(conn_ent.entity);
                                try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                                continue;
                            }
                        }
                    } else {
                        // Plaintext server connections: sniff for an HTTP/1.x
                        // request on the very first read. nghttp2 would reject
                        // non-h2 bytes and we'd close silently; instead route
                        // the connection to the h1 codec (HTTP/1.1 ingress,
                        // docs/architecture/routing-and-ingress.md). Only the first read
                        // can be a non-h2 preface, so the sniff is gated on
                        // first_read_seen.
                        if (conn_ptr.direction == .server and !conn_ptr.first_read_seen and
                            data_len > 0 and looksLikeHttp1Request(data_ptr[0..data_len]))
                        {
                            // h2c-only instances (the worker —
                            // architecture/websockets.md): h1 terminates at the
                            // front; refuse rather than swap in.
                            if (!self.h2_opts.accept_http1) {
                                _ = self.closeConn(conn_ent.entity);
                                try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                                continue;
                            }
                            conn_ptr.first_read_seen = true;
                            _ = self.http1SwapIn(conn_ptr) orelse {
                                _ = self.closeConn(conn_ent.entity);
                                try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                                continue;
                            };
                            self.http1Feed(conn_ptr, conn_ent.entity, data_ptr[0..data_len]);
                            conn_ptr.last_active_ns = monotonicNs();
                            try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                            continue;
                        }
                        conn_ptr.first_read_seen = true;
                        const rv = c.nghttp2_session_mem_recv(conn_ptr.ng_session.?, data_ptr, data_len);
                        if (rv < 0) {
                            _ = self.closeConn(conn_ent.entity);
                            try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
                            continue;
                        }
                    }
                    conn_ptr.last_active_ns = monotonicNs();
                }

                try self.reg.move(ent, self.coll(._read_active), self.io.coll(.read_in));
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
                        // Retry-safety watermark (see `Conn.send_seq`):
                        // completions arrive in submit order, so the
                        // just-completed buffer's seq is `send_done`
                        // after the bump; a failure pins the FIRST
                        // never-delivered seq.
                        conn_ptr.send_done += 1;
                        if (failed and conn_ptr.send_fail_seq == 0)
                            conn_ptr.send_fail_seq = conn_ptr.send_done;
                        if (conn_ptr.h1) |h1c| {
                            if (h1c.wsWrite()) |wr| {
                                // WS backpressure: the single in-flight flush
                                // drained. Clear the flag and push whatever
                                // queued behind it (and reap a drained closing
                                // conn). On failure the conn is destroyed below.
                                // NB: the tunnel 101 lands HERE (wsUpgradeAccept
                                // flips the arm before sending it) — its
                                // completion must trigger the first tunnel
                                // flush, exactly as it always has.
                                wr.write_inflight = false;
                                if (!failed) self.wsFlush(conn_ptr, conn_ent.entity);
                            } else if (!h1c.state.http1.sending_entity.isNil()) {
                                const sent = h1c.state.http1.sending_entity;
                                h1c.state.http1.sending_entity = Entity.nil;
                                if (self.reg.isInCollection(sent, self.coll(._stream_data_sending))) {
                                    if (failed) {
                                        // The write failed (conn is about to be
                                        // destroyed): surface it so the worker
                                        // reaps the stream from response_out.
                                        try self.reg.set(sent, self.coll(._stream_data_sending), H2IoResult, .{ .err = -1 });
                                        try self.reg.move(sent, self.coll(._stream_data_sending), self.coll(.response_out));
                                    } else {
                                        // Drained — let the worker push the next.
                                        try self.reg.move(sent, self.coll(._stream_data_sending), self.coll(.stream_data_out));
                                    }
                                }
                            }
                        } else if (!failed) {
                            // h2 server DATA path: the single in-flight
                            // serialized send drained — submit the next queued
                            // buffer in order (`enqueueConnSend`/`Conn.send_queue`).
                            // A failed conn is destroyed below; its queue frees
                            // in `Conn.deinit`.
                            self.pumpConnSend(conn_ptr, conn_ent.entity);
                        }
                    }
                }

                if (failed) {
                    _ = self.closeConn(conn_ent.entity);
                }
                // io owns the buffer's release: it was kernel-visible until the
                // completion landed, and reaching `write_done` is what proves it did.
                try self.reg.move(ent, self.io.coll(.write_results), self.io.coll(.write_done));
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

                const conn_ptr = self.reg.get(ent, self.coll(._conn_active), Conn) catch continue;

                // h1 connections have no nghttp2 session to drive — responses
                // are written synchronously in `http1WriteResponse`. Idle
                // reaping for them happens in `reapIdleConnections` (run
                // AFTER reads), so a just-arrived request isn't reaped out
                // from under itself.
                if (conn_ptr.ng_session == null) continue;

                // Graceful idle reap (h2): the idle DETECTION that queues
                // the GOAWAY lives in `reapIdleConnections`, which runs
                // in `pollPostlude` AFTER inbound reads are fed to nghttp2 —
                // so a request that just arrived on an idle connection
                // refreshes `last_active_ns` and is never reaped out from
                // under itself (the idle-keepalive reuse race; see the
                // front-door TTFB investigation). Here we only FINISH a
                // reap already in progress: flush the queued GOAWAY (the
                // want_write path below) and force-destroy once the peer
                // drains or the grace deadline fires. `draining` is sticky.
                if (conn_ptr.draining and now >= conn_ptr.drain_deadline_ns) {
                    _ = self.closeConn(ent);
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                if (c.nghttp2_session_want_write(ng_session) == 0 and
                    c.nghttp2_session_want_read(ng_session) == 0)
                {
                    // nghttp2 is done, but our serialized send queue may still
                    // hold response bytes not yet on the socket — destroying
                    // now would drop them. Wait for `writesAccount` to drain
                    // the queue; the draining-deadline force-destroy above is
                    // the backstop for a peer that stops reading.
                    if (conn_ptr.send_inflight or conn_ptr.send_queue.items.len > 0) continue;
                    _ = self.closeConn(ent);
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
                            try self.destroyEntity(ent);
                            broke = true;
                            break;
                        }
                        if (len == 0) break;
                        const flen: usize = @intCast(len);
                        if (accum_len + flen > accum_buf.len) {
                            const cipher = tc.encrypt(accum_buf[0..accum_len], self.allocator) catch {
                                try self.destroyEntity(ent);
                                broke = true;
                                break;
                            };
                            // Ordered egress: the TLS record stream MUST reach
                            // the socket in sequence or the peer's MAC desyncs.
                            self.enqueueConnSend(conn_ptr, ent, cipher);
                            accum_len = 0;
                        }
                        @memcpy(accum_buf[accum_len .. accum_len + flen], frame_data[0..flen]);
                        accum_len += flen;
                    }

                    if (!broke and accum_len > 0) {
                        const cipher = tc.encrypt(accum_buf[0..accum_len], self.allocator) catch {
                            try self.destroyEntity(ent);
                            continue;
                        };
                        self.enqueueConnSend(conn_ptr, ent, cipher);
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
                            try self.destroyEntity(ent);
                            broke = true;
                            break;
                        }
                        if (len == 0) break;
                        const flen: usize = @intCast(len);
                        if (accum_len + flen > accum_buf.len) {
                            // Flush what we have so far, then continue
                            // with a fresh buffer. Serialized per-conn (same
                            // as TLS): plaintext h2 frames must also reach the
                            // socket in order, or the peer's frame stream is
                            // corrupted — loopback masks it (buffers rarely
                            // fill), a real network doesn't.
                            const copy = self.allocator.dupe(u8, accum_buf[0..accum_len]) catch {
                                try self.destroyEntity(ent);
                                broke = true;
                                break;
                            };
                            self.enqueueConnSend(conn_ptr, ent, copy);
                            accum_len = 0;
                        }
                        @memcpy(accum_buf[accum_len .. accum_len + flen], frame_data[0..flen]);
                        accum_len += flen;
                    }

                    if (!broke and accum_len > 0) {
                        const copy = self.allocator.dupe(u8, accum_buf[0..accum_len]) catch {
                            try self.destroyEntity(ent);
                            continue;
                        };
                        self.enqueueConnSend(conn_ptr, ent, copy);
                    }
                }

                conn_ptr.last_active_ns = now;
            }
        }

        /// Graceful shutdown drain (front-door hardening plan C10):
        /// close ACTIVE server connections out from under waiting
        /// clients GRACEFULLY so a rolling restart stops cutting
        /// in-flight requests. h2: queue a GOAWAY (in-flight streams
        /// finish; `grace_ns` bounds a dawdling peer before
        /// `driveAllSends` force-destroys). h1 (no GOAWAY exists):
        /// a conn idle BETWEEN requests is destroyed now (the kernel
        /// flushes queued response bytes on the graceful close);
        /// a conn mid-request gets `keep_alive = false` so its
        /// response carries `Connection: close` and the NEXT sweep
        /// destroys it. WS-mode h1 conns are left to the caller's
        /// drain deadline. Idempotent — the caller re-invokes each
        /// drain-loop iteration, which also covers connections
        /// accepted after the first sweep.
        pub fn drainServerConns(self: *Self, grace_ns: u64) !void {
            const entities = self._conn_active.entitySlice();
            const now = monotonicNs();
            for (entities) |ent| {
                if (self.reg.isStale(ent)) continue;
                const conn_ptr = self.reg.get(ent, self.coll(._conn_active), Conn) catch continue;
                if (conn_ptr.direction != .server) continue;
                if (conn_ptr.ng_session) |ng| {
                    if (conn_ptr.draining) continue;
                    _ = c.nghttp2_session_terminate_session(ng, c.NGHTTP2_NO_ERROR);
                    conn_ptr.draining = true;
                    conn_ptr.drain_deadline_ns = now + grace_ns;
                } else if (conn_ptr.h1) |h1c| {
                    const st = switch (h1c.state) {
                        // Live WS conns (framed or tunnel) ride out a drain.
                        .ws_framed, .ws_tunnel => continue,
                        .http1 => |*st| st,
                    };
                    // Destroyable: idle between requests, or `closing`
                    // (response served, Connection: close — that path
                    // never resets `in_flight`; it normally waits for
                    // the idle GC, far beyond a drain budget). The
                    // 500 ms quiet window (last_active is the last
                    // READ; the response write follows within ms) lets
                    // the final write reach the kernel before the
                    // graceful close flushes it out.
                    const quiet_ns: u64 = 500 * std.time.ns_per_ms;
                    const idle_between = !st.in_flight and !st.body_active and
                        !st.streaming and st.sending_entity.isNil();
                    const close_pending = h1c.closing and st.sending_entity.isNil();
                    if ((idle_between or close_pending) and
                        conn_ptr.last_active_ns != 0 and
                        now -| conn_ptr.last_active_ns > quiet_ns)
                    {
                        _ = self.closeConn(ent);
                    } else if (!h1c.closing) {
                        // Mid-request — INCLUDING a parked pending Upgrade
                        // (pending_upgrade ⇒ in_flight): the eventual
                        // response carries Connection: close; a later sweep
                        // reaps it. Explicit choice: a drain refuses to
                        // leave an undecided tunnel park open.
                        st.keep_alive = false;
                    }
                }
            }
        }

        /// Idle-connection reaper. Runs in `pollPostlude` AFTER inbound
        /// reads have been fed to nghttp2 (`readsFeedData`) — so a
        /// request that just arrived on an idle connection has already
        /// refreshed `last_active_ns` and is NOT reaped out from under
        /// itself. This ordering is the cure for the idle-keepalive
        /// reuse-vs-reap race (the front-door TTFB stall): if the
        /// detection ran in `driveAllSends` (BEFORE reads), a reuse
        /// request landing exactly as the idle timer expired would be
        /// terminated before it was ever read, stranding the client.
        ///
        /// For h2 we queue a graceful GOAWAY (`terminate_session`) and
        /// mark the connection `draining`; the next `driveAllSends` pass
        /// flushes the GOAWAY and the drain finalizes there. For h1
        /// (no nghttp2 session) we destroy directly. The CLIENT-direction
        /// timeout (`client_idle_timeout_ns`, 0 ⇒ fall back to the
        /// server-side `idle_timeout_ns`) lets the front door recycle a
        /// pooled upstream leg before the worker reaps it.
        fn reapIdleConnections(self: *Self) !void {
            // Grace window for a GOAWAY'd idle connection to finish
            // closing before `driveAllSends` force-destroys it (backstop
            // for a peer that stops reading after we signal GOAWAY).
            const GOAWAY_DRAIN_GRACE_NS: u64 = 2 * std.time.ns_per_s;
            const entities = self._conn_active.entitySlice();
            const now = monotonicNs();

            // Connection-setup deadline (plan A4), two stages sharing
            // one budget (`tls_handshake_timeout_ns`; a peer straddling
            // both gets at most 2×):
            //
            //   1. SILENT stage — a server conn still in
            //      `io.connections` with no first byte (zero reads →
            //      never reached `_read_init`, so no TLS conn and no
            //      session). `last_active_ns` is the accept stamp from
            //      `transitionNewConnections`.
            //   2. TLS handshake stage — `_conn_tls_handshake`.
            //      `readsTlsHandshake` never refreshes `last_active_ns`
            //      (it's the stamp from the move), so this is a total
            //      handshake budget, not an idle window — trickled
            //      bytes buy nothing.
            //
            // Neither stage has a session to GOAWAY: destroy directly
            // (the same teardown the handshake `.err` path uses). The
            // idle reaper below only ever covered `_conn_active`;
            // without these sweeps a stalled peer pinned one of the
            // `max_connections` slots forever — classic slowloris.
            if (self.h2_opts.tls_handshake_timeout_ns > 0) {
                const budget = self.h2_opts.tls_handshake_timeout_ns;
                const raw = self.io.connections.entitySlice();
                for (raw) |ent| {
                    if (self.reg.isStale(ent)) continue;
                    const conn_ptr = self.reg.get(ent, self.io.coll(.connections), Conn) catch continue;
                    if (conn_ptr.direction != .server) continue;
                    // Claimable / mid-transition conns belong to the
                    // handshake or active sweeps.
                    if (conn_ptr.tls_conn != null or conn_ptr.ng_session != null or conn_ptr.h1 != null) continue;
                    if (conn_ptr.last_active_ns == 0) continue;
                    if (now -| conn_ptr.last_active_ns <= budget) continue;
                    self.handshake_reaped_total += 1;
                    _ = self.closeConn(ent);
                }
                const hs = self._conn_tls_handshake.entitySlice();
                for (hs) |ent| {
                    if (self.reg.isStale(ent)) continue;
                    const conn_ptr = self.reg.get(ent, self.coll(._conn_tls_handshake), Conn) catch continue;
                    if (conn_ptr.last_active_ns == 0) continue;
                    if (now -| conn_ptr.last_active_ns <= budget) continue;
                    self.handshake_reaped_total += 1;
                    _ = self.closeConn(ent);
                }
            }

            for (entities) |ent| {
                if (self.reg.isStale(ent)) continue;
                const conn_ptr = self.reg.get(ent, self.coll(._conn_active), Conn) catch continue;

                // Direction-aware idle budget: client legs may reap
                // sooner than server connections (LB-idle < backend-idle).
                // A connection with work in flight is NOT idle, however long
                // its socket has been quiet. A large response whose peer
                // reads slowly stops the byte flow legitimately — the receive
                // window stays unrepaid until the reader drains — so reaping
                // on elapsed-bytes alone truncates that response mid-body,
                // after its 200 was already committed. Stalls are the
                // business of the per-stream deadlines, which can answer with
                // a status; this reaper only frees genuinely unused slots.
                if (conn_ptr.open_streams > 0) continue;

                const timeout: u64 = if (conn_ptr.direction == .client and
                    self.h2_opts.client_idle_timeout_ns > 0)
                    self.h2_opts.client_idle_timeout_ns
                else
                    self.h2_opts.idle_timeout_ns;
                if (timeout == 0 or conn_ptr.last_active_ns == 0) continue;
                if (now -| conn_ptr.last_active_ns <= timeout) continue;

                // h1: no session to drain — destroy directly.
                if (conn_ptr.ng_session == null) {
                    if (conn_ptr.h1 != null) _ = self.closeConn(ent);
                    continue;
                }

                // h2: already draining ⇒ leave it to `driveAllSends`.
                if (conn_ptr.draining) continue;

                // Initiate a graceful reap: GOAWAY now, flush + finalize
                // in `driveAllSends`. `draining` is sticky so late traffic
                // that refreshes `last_active_ns` can't cancel it.
                _ = c.nghttp2_session_terminate_session(conn_ptr.ng_session.?, c.NGHTTP2_NO_ERROR);
                conn_ptr.draining = true;
                conn_ptr.drain_deadline_ns = now + GOAWAY_DRAIN_GRACE_NS;
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
                const ce = self.reg.create(self.io.coll(.connect_in)) catch {
                    try self.reg.set(ent, self.coll(.client_connect_in), H2IoResult, .{ .err = -1 });
                    try self.reg.move(ent, self.coll(.client_connect_in), self.coll(.client_connect_errors));
                    continue;
                };

                // The target address goes into io's `connect_addrs` table,
                // whose slots are stable for the entity's lifetime — a
                // component column is not, and `prep_connect` outlives the
                // move that would reshuffle it. No allocation, so no failure
                // path and nothing to free.
                try self.io.setConnectAddr(ce, self.io.coll(.connect_in), target.addr);
                try self.reg.set(ce, self.io.coll(.connect_in), Conn, .{ .direction = .client, .pending_connect_entity = ent });

                try self.reg.move(ent, self.coll(.client_connect_in), self.coll(._client_connect_pending));
            }
        }

        // =============================================================
        // Client: process connect results
        // =============================================================

        fn processConnectResults(self: *Self) !void {
            if (!has_client) return;
            const entities = self.io.connections.entitySlice();

            for (entities) |ent| {
                const conn_ptr = self.reg.get(ent, self.io.coll(.connections), Conn) catch continue;
                if (conn_ptr.direction != .client) continue;
                if (conn_ptr.pending_connect_entity.isNil()) continue;

                const user_ent = conn_ptr.pending_connect_entity;
                if (self.reg.isStale(user_ent)) {
                    conn_ptr.pending_connect_entity = Entity.nil;
                    continue;
                }

                self.clientSessionCreate(conn_ptr, ent) catch {
                    self.reg.set(user_ent, self.coll(._client_connect_pending), H2IoResult, .{ .err = -1 }) catch {};
                    self.reg.move(user_ent, self.coll(._client_connect_pending), self.coll(.client_connect_errors)) catch {};
                    _ = self.closeConn(ent);
                    continue;
                };

                self.reg.set(user_ent, self.coll(._client_connect_pending), Session, .{ .entity = ent }) catch {};
                self.reg.set(user_ent, self.coll(._client_connect_pending), H2IoResult, .{ .err = 0 }) catch {};
                self.reg.move(user_ent, self.coll(._client_connect_pending), self.coll(.client_connect_out)) catch {};

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
                    self.reg.set(user_ent, self.coll(._client_connect_pending), H2IoResult, .{ .err = -1 }) catch {};
                    self.reg.move(user_ent, self.coll(._client_connect_pending), self.coll(.client_connect_errors)) catch {};
                }
                try self.destroyEntity(ent);
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
                    try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                const nv_count: usize = @as(usize, rh.count);
                if (nv_count == 0) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
                    continue;
                }

                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
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
                        try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
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
                    try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
                    continue;
                }

                const stream = Stream.create(sess.entity, self.allocator) orelse {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_request_in), self.coll(.client_response_out));
                    continue;
                };
                stream.entity = ent;
                stream.send_complete = (data_prd.read_callback == null);
                stream.send_data = body_data_ptr;
                stream.ng_stream_id = stream_id;
                _ = c.nghttp2_session_set_stream_user_data(ng_session, stream_id, @ptrCast(stream));
                if (getConn(self, sess.entity)) |cp| cp.open_streams += 1;

                try self.reg.set(ent, self.coll(.client_request_in), StreamId, .{ .id = @intCast(stream_id) });
                try self.reg.move(ent, self.coll(.client_request_in), self.coll(._client_request_sending));
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
            const req_bodies = self.client_stream_request_in.column(ReqBody);
            const io_results = self.client_stream_request_in.column(H2IoResult);

            for (entities, sessions, req_hdrs, req_bodies, io_results) |ent, sess, rh, rb, *io_res| {
                const conn_ptr = getConn(self, sess.entity) orelse {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;

                const nv_count: usize = @as(usize, rh.count);
                if (nv_count == 0) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
                    continue;
                }

                const nva_slice = self.allocator.alloc(c.nghttp2_nv, nv_count) catch {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
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

                // `ReqBody.complete`: the body is fully known at submit (the
                // proxy's bodyless / body-complete case) — submit it with the
                // request so END_STREAM rides the HEADERS (empty) or the
                // attached body's final DATA. No pump follows; the entity
                // still parks in `client_stream_data_out` so the consumer
                // learns the stream id for response mapping.
                var data_prd = c.nghttp2_data_provider{
                    .source = .{ .ptr = null },
                    .read_callback = &onDataSourceReadCb,
                };
                var prd: ?*c.nghttp2_data_provider = &data_prd;
                var body_data_ptr: ?*BodyData = null;
                if (rb.complete) {
                    if (rb.data != null and rb.len > 0) {
                        body_data_ptr = BodyData.create(self.allocator, rb.data.?, rb.len) orelse {
                            io_res.err = -1;
                            try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
                            continue;
                        };
                        data_prd.source = .{ .ptr = @ptrCast(body_data_ptr) };
                    } else {
                        prd = null;
                    }
                }

                const stream_id = c.nghttp2_submit_request(
                    ng_session,
                    null,
                    nva_slice.ptr,
                    nv_count,
                    prd,
                    null,
                );

                if (stream_id < 0) {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
                    continue;
                }

                const stream = Stream.create(sess.entity, self.allocator) orelse {
                    if (body_data_ptr) |bd| bd.destroy();
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_response_out));
                    continue;
                };
                stream.entity = ent;
                stream.emitted = true;
                stream.streaming = !rb.complete;
                stream.client_stream = true;
                stream.send_complete = rb.complete and body_data_ptr == null;
                stream.send_data = body_data_ptr;
                stream.ng_stream_id = stream_id;
                _ = c.nghttp2_session_set_stream_user_data(ng_session, stream_id, @ptrCast(stream));
                if (getConn(self, sess.entity)) |cp| cp.open_streams += 1;

                try self.reg.set(ent, self.coll(.client_stream_request_in), StreamId, .{ .id = @intCast(stream_id) });
                try self.reg.move(ent, self.coll(.client_stream_request_in), self.coll(.client_stream_data_out));
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
                    try self.reg.move(ent, self.coll(.client_stream_data_in), self.coll(.client_response_out));
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_data_in), self.coll(.client_response_out));
                    continue;
                }

                if (rb.data == null or rb.len == 0) {
                    try self.reg.move(ent, self.coll(.client_stream_data_in), self.coll(.client_stream_data_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_data_in), self.coll(.client_response_out));
                    continue;
                }

                const s = stream.?;

                s.stream_chunk_data = rb.data;
                s.stream_chunk_len = rb.len;
                s.stream_chunk_offset = 0;
                rb.data = null;
                rb.len = 0;

                _ = c.nghttp2_session_resume_data(ng_session, s.ng_stream_id);

                try self.reg.move(ent, self.coll(.client_stream_data_in), self.coll(._client_stream_data_sending));
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
                    try self.reg.move(ent, self.coll(.client_stream_close_in), self.coll(.client_response_out));
                    continue;
                };
                if (conn_ptr.ng_session == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_close_in), self.coll(.client_response_out));
                    continue;
                }

                const ng_session = conn_ptr.ng_session.?;
                const stream: ?*Stream = @ptrCast(@alignCast(
                    c.nghttp2_session_get_stream_user_data(ng_session, @intCast(sid.id)),
                ));
                if (stream == null) {
                    io_res.err = -1;
                    try self.reg.move(ent, self.coll(.client_stream_close_in), self.coll(.client_response_out));
                    continue;
                }

                stream.?.stream_eof = true;
                _ = c.nghttp2_session_resume_data(ng_session, stream.?.ng_stream_id);

                try self.reg.move(ent, self.coll(.client_stream_close_in), self.coll(._client_stream_data_sending));
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// Type-shape fixtures — tests' mini-worlds via explicit `.world`.
const ShapeWorld = rove.World(.{ .parts = parts(.{}) });
const ShapeH2 = H2(.{ .world = ShapeWorld });
const client_shape_opts = Options{ .client = true };
const ClientShapeWorld = rove.World(.{ .parts = parts(client_shape_opts) });
const ClientShapeH2 = H2(.{ .client = true, .world = ClientShapeWorld });

test "stream row contains all h2 base components" {
    const H2Type = ShapeH2;
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
    const H2Type = ShapeH2;
    try testing.expect(H2Type.ConnectionRow.contains(Conn));
    try testing.expect(H2Type.ConnectionRow.contains(rio.Fd));
    try testing.expect(H2Type.ConnectionRow.contains(rio.ReadCycleEntity));
}

const PassAppData = struct { tag: u64 };
const PassSession = struct { id: u64 };
const pass_opts = Options{ .request_row = Row(&.{PassAppData}), .connection_row = Row(&.{PassSession}) };
const PassWorld = rove.World(.{ .parts = parts(pass_opts) });

test "user rows pass through" {
    const MyAppData = PassAppData;
    const MySession = PassSession;
    const H2Type = H2(.{ .request_row = Row(&.{PassAppData}), .connection_row = Row(&.{PassSession}), .world = PassWorld });
    try testing.expect(H2Type.StreamRow.contains(MyAppData));
    try testing.expect(H2Type.ConnectionRow.contains(MySession));
}

test "H2 type has expected collections" {
    const H2Type = ShapeH2;
    try testing.expect(@hasField(H2Type, "request_out"));
    try testing.expect(@hasField(H2Type, "response_in"));
    try testing.expect(@hasField(H2Type, "response_out"));
    try testing.expect(@hasField(H2Type, "_response_sending"));
    try testing.expect(@hasField(H2Type, "_conn_active"));
}

test "H2 client has client collections" {
    const H2Type = ClientShapeH2;
    try testing.expect(@hasField(H2Type, "client_connect_in"));
    try testing.expect(@hasField(H2Type, "client_response_out"));
}

test "nghttp2 linked and callable" {
    const info = c.nghttp2_version(0);
    try testing.expect(info != null);
    try testing.expect(info.*.proto_str != null);
}

test {
    // Pull these files' inline tests into this module's test build — a bare
    // `const = @import(...)`, even a `pub` one, does NOT: re-exporting a file
    // makes its declarations available, not its tests. `http1` and `ws` had
    // standalone test modules for exactly this reason; referencing them here
    // runs their tests against the real rove-h2 module instead.
    _ = conn_state;
    _ = http1;
    _ = ws;
}

test "stream accumulator — headers and body" {
    const stream = Stream.create(Entity{ .index = 5, .generation = 2 }, testing.allocator) orelse
        return error.OutOfMemory;
    defer stream.free();

    try testing.expect(stream.hdrAppend(":method", 7, "GET", 3));
    try testing.expect(stream.hdrAppend(":path", 5, "/hello", 6));
    try testing.expect(stream.hdrAppend("host", 4, "localhost", 9));
    try testing.expectEqual(@as(u32, 3), stream.hdr.count);

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


// ── Fat-model stream-buffer release (the dead-letter + reaper) ──
// testing.allocator is the leak gate: every byte these tests allocate
// through h2's allocator must be freed by the reaper or the teardown
// sweep, or the test fails on leak.

const fat_test_opts = Options{};
const FatTestWorld = rove.World(.{ .parts = parts(fat_test_opts) });
const FatTestH2 = H2(.{ .world = FatTestWorld });

fn fatTestServer(reg: *FatTestH2.Reg) !*FatTestH2 {
    return FatTestH2.create(reg, testing.allocator, try std.net.Address.parseIp("127.0.0.1", 0), .{
        .ring_entries = 8,
        .buf_count = 8,
        .buf_size = 256,
        .max_connections = 8,
    }, .{});
}

fn allocStreamBuffers(server: *FatTestH2, ent: Entity, cl: anytype) !void {
    const hdr_buf = try testing.allocator.alloc(u8, 64);
    try server.reg.set(ent, cl, ReqHeaders, .{ .fields = null, .count = 0, ._buf = hdr_buf.ptr, ._buf_len = 64 });
    const body = try testing.allocator.alloc(u8, 128);
    try server.reg.set(ent, cl, ReqBody, .{ .data = body.ptr, .len = 128 });
    const resp = try testing.allocator.alloc(u8, 32);
    try server.reg.set(ent, cl, RespBody, .{ .data = resp.ptr, .len = 32 });
}

test "fat: destroyEntity routes to the dead-letter; the reaper frees the buffers" {
    var reg = try FatTestH2.Reg.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();
    const server = fatTestServer(&reg) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer server.destroy();

    const request_out = reg.coll(.request_out);
    const ent = try reg.create(request_out);
    try allocStreamBuffers(server, ent, request_out);

    try server.destroyEntity(ent);
    // Deferred: nothing freed, nothing destroyed before the flush.
    try testing.expect(!reg.isStale(ent));

    try reg.flush();
    try testing.expect(reg.isInCollection(ent, reg.coll(._stream_dead)));

    server.processStreamDead();
    try reg.flush();
    try testing.expect(reg.isStale(ent));
    // The leak gate at test end proves the three buffers came back.
}

test "fat: an ending is never refused — a mid-move entity still reaches the dead-letter" {
    var reg = try FatTestH2.Reg.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();
    const server = fatTestServer(&reg) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer server.destroy();

    const request_out = reg.coll(.request_out);
    const response_in = reg.coll(.response_in);
    const ent = try reg.create(request_out);
    try allocStreamBuffers(server, ent, request_out);

    // A move is already queued when the ending arrives — the exact shape
    // that used to fail PendingMove into a silent `catch {}` leak.
    try reg.move(ent, request_out, response_in);
    try server.destroyEntity(ent);
    try reg.flush();
    try testing.expect(reg.isInCollection(ent, reg.coll(._stream_dead)));

    server.processStreamDead();
    try reg.flush();
    try testing.expect(reg.isStale(ent));
}

test "fat: teardown frees the buffers of entities the consumer never ended" {
    var reg = try FatTestH2.Reg.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();
    const server = fatTestServer(&reg) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };

    // Live entities in three shapes at shutdown: an unanswered request,
    // one already in the dead-letter but not yet reaped, and a WS seam
    // carrier. destroy() must release all of it.
    const request_out = reg.coll(.request_out);
    const ent_a = try reg.create(request_out);
    try allocStreamBuffers(server, ent_a, request_out);

    const ent_b = try reg.create(request_out);
    try allocStreamBuffers(server, ent_b, request_out);
    try server.destroyEntity(ent_b);
    try reg.flush(); // in _stream_dead, unreaped

    const ws_out = reg.coll(.ws_message_out);
    const ent_c = try reg.create(ws_out);
    const payload = try testing.allocator.alloc(u8, 16);
    try reg.set(ent_c, ws_out, ReqBody, .{ .data = payload.ptr, .len = 16 });

    server.destroy();
}
