//! `_system.stream.start()` / `_system.stream.write(chunk)` — the
//! connection-output EFFECT surface (handler-surface Phase 2,
//! `docs/handler-shape.md` §2.2). `stream` is an ambient namespace (like
//! `kv`), NOT a return verb: a held handler produces its streamed
//! response over time via these effects + `on.*` waits + `return next()`
//! (keep streaming) / a terminal (close). The effects accumulate onto
//! `DispatchState` (`stream_started` + `pending_stream_chunks`); the
//! dispatcher's `finishResponse` bridge turns `(next() + stream_started)`
//! into the internal `Stream` descriptor below, which the worker
//! `.stream` arm + the bound-fetch resume paths drive through the h2
//! stream pipeline.
//!
//! Phase 2 retired the `__rove_stream({status, headers, write, waitFor,
//! ctx})` RETURN verb + its JS constructor (`jsStream`), brand nonce,
//! and `tryExtract` JS→Stream parse: the head comes from the ambient
//! `response.*`, the chunks from the `stream.write` buffer, and the
//! waits from `on.*` — so none of the descriptor parsing survives. The
//! `Stream` struct + `jsValueAsOwnedBytes` remain (built by the bridge /
//! used by `jsStreamWrite`).
//!
//! There is deliberately NO connection handle in this surface
//! (project-connection-actor-unified-trigger): the held socket is the
//! chain's by construction; nothing is addressable.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const components = @import("../components.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

// ── The internal stream descriptor (Zig side) ──────────────────────

/// Internal representation of a streamed response. Handler-surface
/// Phase 2 retired the `__rove_stream({...})` return verb + its JS
/// constructor / brand / `tryExtract` parse; this struct is now built
/// ONLY by the dispatcher's `finishResponse` bridge from the `stream.*`
/// effect surface (`buildStreamFromEffects`) and consumed by the worker
/// `.stream` arm + the bound-fetch resume paths. `deinit` frees it.
pub const Stream = struct {
    /// First-hop status code. Default 200. Ignored on subsequent
    /// activations (the stream's status line already went out with
    /// the first headers flush).
    status: u16 = 200,
    /// First-hop response headers (lines joined by `\r\n`). Owned;
    /// `null` on subsequent activations. The first activation sets
    /// up the SSE-like response shape via these headers.
    headers: ?[]u8 = null,
    /// Zero or more chunks to flush to the held socket before
    /// parking. Each is an owned UTF-8 byte slice (raw bytes are
    /// fine; SSE framing is the customer's responsibility). On
    /// terminal-close, the last chunks ride the END_STREAM frame.
    chunks: [][]u8,
    /// Timer-wake interval in ms. null = no timer wake (chain ends
    /// after chunks drain unless a kv-prefix wake fires first).
    interval_ms: ?i64 = null,
    /// streaming-handlers-plan §4.6: prefix-only kv-write wakes.
    /// Each entry is a tenant-scoped key prefix; when any key with
    /// that prefix is `put`/`delete`'d by ANY request on the cell's
    /// owning tenant, the apply-time hook fires a `kv_wake`
    /// activation. Empty slice = no kv wakes registered.
    /// Allocator-owned: each prefix is its own dup'd buffer, and
    /// the spine `[][]u8` is allocator-owned too.
    kv_prefixes: [][]u8 = &.{},
    /// Author's `ctx`, JSON-serialized. Threaded forward to the next
    /// activation as `request.ctx`.
    ctx_json: []u8,

    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        if (self.headers) |h| allocator.free(h);
        for (self.chunks) |ch| allocator.free(ch);
        allocator.free(self.chunks);
        for (self.kv_prefixes) |p| allocator.free(p);
        if (self.kv_prefixes.len > 0) allocator.free(self.kv_prefixes);
        allocator.free(self.ctx_json);
    }
};

// ── `_system.stream.start()` / `_system.stream.write(chunk)` ───────
//
// Handler-surface Phase 2 (`docs/handler-shape.md` §2.2): `stream` is
// an **effect namespace** (ambient, like `kv`), NOT a return verb. The
// streamed response is produced over time by `stream.start()` (commit
// the ambient `response.*` head + open the stream) and
// `stream.write(chunk)` (emit a chunk, commit-gated). Both accumulate
// onto `DispatchState`; the worker drives the stream-pipeline entry +
// stages the chunks as commit-gated `Cmd.stream_chunk` at park. The
// handler's disposition is `return next()` (keep producing) / a
// terminal (close) — `stream.*` never returns a value into *this*
// activation.
//
// Connection-only, like `on.*`: on a connectionless activation
// (cron / schedule / webhook.send callback / test path) the
// `pending_stream_chunks` accumulator is null and these calls are inert
// no-ops, per the model (§2.4 — disposition verbs + `stream.*`/`on.*`
// are inert without a held socket).

/// `_system.stream.start()` — open the streamed response (commit the
/// ambient head). Idempotent flag set; the first `stream.write()` would
/// imply it anyway. Inert when there's no held connection.
pub fn jsStreamStart(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (state.pending_stream_chunks == null) return js_undefined; // connectionless ⇒ inert
    state.stream_started = true;
    return js_undefined;
}

/// `_system.stream.write(chunk)` — emit one chunk to the held socket.
/// Commit-gated: the chunk reaches the wire only after this activation's
/// writes commit (`streaming-model.md` §2). `chunk` is coerced to bytes
/// (string or typed value → UTF-8). Inert when there's no connection.
pub fn jsStreamWrite(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    const list = state.pending_stream_chunks orelse return js_undefined; // connectionless ⇒ inert
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "stream.write(chunk) requires a chunk argument");
        return js_exception;
    }
    var opcode: u8 = 0;
    const bytes = jsValueAsOwnedBytes(state.allocator, ctx, argv[0], &opcode) catch {
        _ = c.JS_ThrowInternalError(ctx, "stream.write: out of memory");
        return js_exception;
    };
    // Lossless backstop: a single activation can't be backpressured mid-run, so
    // cap its cumulative writes at the hard ceiling and throw (never drop). The
    // bound-fetch / wake paths produce one chunk per activation and pace via the
    // queue's soft cap; this only fires on a synchronous flood (a `for` loop
    // writing > the cap in one go) — the fix is to paginate with `next()`.
    if (state.stream_pending_bytes + bytes.len > components.StreamChunks.QUEUE_HARD_CAP) {
        state.allocator.free(bytes);
        _ = c.JS_ThrowRangeError(ctx, "stream.write: too many bytes buffered in one activation; emit fewer per activation and continue with next()");
        return js_exception;
    }
    // Writing implies the stream is open — `start()` is optional.
    state.stream_started = true;
    list.append(state.allocator, bytes) catch {
        state.allocator.free(bytes);
        _ = c.JS_ThrowInternalError(ctx, "stream.write: out of memory");
        return js_exception;
    };
    state.stream_pending_bytes += bytes.len;
    // websocket-plan §5: on a WS connection activation, record this
    // chunk's frame opcode in lockstep (text iff the arg was a string,
    // binary otherwise) so the worker frames it correctly. Null on
    // SSE/HTTP chains (opcode irrelevant). Push AFTER the chunk append
    // succeeds so the two lists stay the same length; on OOM here, undo
    // the chunk append to preserve that invariant.
    if (state.pending_stream_chunk_opcodes) |ops| {
        ops.append(state.allocator, opcode) catch {
            const dropped = list.pop().?;
            state.allocator.free(dropped);
            _ = c.JS_ThrowInternalError(ctx, "stream.write: out of memory");
            return js_exception;
        };
    }
    return js_undefined;
}

/// Coerce a `stream.write` argument to owned bytes, reporting the RFC
/// 6455 data opcode in `opcode_out` (1 = text, the value was a string;
/// 2 = binary, an ArrayBuffer/TypedArray). A string is UTF-8-encoded via
/// `JS_ToCStringLen`; a typed array's raw backing bytes are copied via
/// `JS_GetUint8Array` — running binary through `JS_ToCStringLen` would
/// truncate at embedded NULs and mangle non-UTF-8, so the type must be
/// distinguished here (the same split `crypto.zig`'s `extractKeyOrDataBytes`
/// makes). Any non-string that isn't a Uint8Array view falls back to the
/// string coercion (e.g. numbers → their decimal text, a text frame).
fn jsValueAsOwnedBytes(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    v: c.JSValue,
    opcode_out: *u8,
) error{OutOfMemory}![]u8 {
    if (!c.JS_IsString(v)) {
        var byte_len: usize = 0;
        const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, v);
        if (buf_ptr != null) {
            opcode_out.* = 2; // binary frame
            return try allocator.dupe(u8, buf_ptr[0..byte_len]);
        }
        // Not a typed array — clear the pending exception JS_GetUint8Array
        // set and fall through to the string coercion (text frame).
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
    }
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return error.OutOfMemory;
    defer c.JS_FreeCString(ctx, s);
    opcode_out.* = 1; // text frame
    return try allocator.dupe(u8, s[0..len]);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "Stream.deinit frees all owned slices" {
    const a = testing.allocator;
    const chunks = try a.alloc([]u8, 2);
    chunks[0] = try a.dupe(u8, "data: hello\n\n");
    chunks[1] = try a.dupe(u8, "data: world\n\n");
    var s: Stream = .{
        .status = 200,
        .headers = try a.dupe(u8, "Content-Type: text/event-stream\r\n"),
        .chunks = chunks,
        .interval_ms = 30_000,
        .ctx_json = try a.dupe(u8, "{\"n\":1}"),
    };
    s.deinit(a);
}

test "Stream.deinit frees kv_prefixes (streaming-handlers Phase 3)" {
    const a = testing.allocator;
    const prefixes = try a.alloc([]u8, 2);
    prefixes[0] = try a.dupe(u8, "orders/alice/");
    prefixes[1] = try a.dupe(u8, "notifications/");
    var s: Stream = .{
        .status = 200,
        .headers = null,
        .chunks = try a.alloc([]u8, 0),
        .interval_ms = null,
        .kv_prefixes = prefixes,
        .ctx_json = try a.dupe(u8, "null"),
    };
    s.deinit(a);
}
