//! `_system.stream` — the iterative streaming primitive
//! (streaming-handlers-plan §3.3). A handler returns
//! `stream({ status?, headers?, write?, waitFor?, ctx? })` instead of
//! a response value to mean: "I am still streaming — flush these
//! chunks to the held socket, then re-invoke this module when the
//! waitFor condition fires."
//!
//! Same affine model as `_system.next`: a stream is a *returned
//! value*, not an effect — no DispatchState mutation, no tape. The
//! dispatcher classifies the return value (`tryExtract`) and the
//! worker either flushes-and-closes (Response), runs the one-shot
//! continuation path (`_system.next`), or routes through the
//! iterative streaming path (this).
//!
//! There is deliberately NO connection handle in this surface
//! (project-connection-actor-unified-trigger): the held socket is
//! the chain's by construction; nothing is addressable.
//!
//! Phase 2 minimum scope: a single timer wake (`{ intervalMs }`) +
//! the implicit-disconnect wake every held stream gets for free.
//! Multi-condition `waitFor` arrays + kv-write wakes land in later
//! phases.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

// ── Per-process brand nonce ────────────────────────────────────────

var brand_once = std.once(initBrand);
var brand_hex: [32]u8 = undefined;

fn initBrand() void {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    brand_hex = std.fmt.bytesToHex(raw, .lower);
}

fn brand() []const u8 {
    brand_once.call();
    return &brand_hex;
}

const BRAND_PROP = "__rove_stream";

// ── The stream descriptor (Zig side) ───────────────────────────────

/// Extracted from a handler's `stream(...)` return value. Owned by
/// the allocator passed to `tryExtract`; `deinit` frees it.
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

// ── `_system.stream(opts)` ─────────────────────────────────────────

pub fn jsStream(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "stream({ status?, headers?, write?, waitFor?, ctx? }) requires an options object");
        return js_exception;
    }
    const opts = argv[0];

    const obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(obj)) return js_exception;

    // Brand.
    const b = brand();
    _ = c.JS_SetPropertyStr(ctx, obj, BRAND_PROP, c.JS_NewStringLen(ctx, b.ptr, b.len));

    // Pass-through fields: status (number), headers (object →
    // wire string), write (string[]), waitFor (object), ctx (any).
    // The Zig-side `tryExtract` does the typed parse; here we just
    // shallow-copy the props onto the branded object.
    inline for ([_][]const u8{ "status", "headers", "write", "waitFor", "ctx" }) |prop| {
        const v = c.JS_GetPropertyStr(ctx, opts, prop.ptr);
        if (!c.JS_IsUndefined(v) and !c.JS_IsException(v)) {
            _ = c.JS_SetPropertyStr(ctx, obj, prop.ptr, v); // steals ref
        } else {
            c.JS_FreeValue(ctx, v);
        }
    }

    return obj;
}

// ── Classify a handler return value ────────────────────────────────

/// Return a `Stream` iff `val` is a branded `stream(...)` descriptor;
/// otherwise null. Only OOM propagates — malformed/forged-looking
/// objects are simply "not a stream" (same accidental-collision
/// resistance posture as `Continuation.tryExtract`).
pub fn tryExtract(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    val: c.JSValue,
) error{OutOfMemory}!?Stream {
    if (!c.JS_IsObject(val)) return null;

    const bv = c.JS_GetPropertyStr(ctx, val, BRAND_PROP);
    defer c.JS_FreeValue(ctx, bv);
    if (!c.JS_IsString(bv)) return null;
    if (!jsStrEql(ctx, bv, brand())) return null;

    // status (optional, default 200).
    var status: u16 = 200;
    {
        const sv = c.JS_GetPropertyStr(ctx, val, "status");
        defer c.JS_FreeValue(ctx, sv);
        if (c.JS_IsNumber(sv)) {
            var n: i32 = 0;
            if (c.JS_ToInt32(ctx, &n, sv) == 0) {
                status = @intCast(@max(@min(n, 599), 100));
            }
        }
    }

    // headers (optional object → wire-format `Key: Val\r\n` lines).
    var headers: ?[]u8 = null;
    errdefer if (headers) |h| allocator.free(h);
    {
        const hv = c.JS_GetPropertyStr(ctx, val, "headers");
        defer c.JS_FreeValue(ctx, hv);
        if (c.JS_IsObject(hv)) {
            headers = try renderHeaders(allocator, ctx, hv);
        }
    }

    // write (optional string[]).
    var chunks: [][]u8 = try allocator.alloc([]u8, 0);
    errdefer {
        for (chunks) |ch| allocator.free(ch);
        allocator.free(chunks);
    }
    {
        const wv = c.JS_GetPropertyStr(ctx, val, "write");
        defer c.JS_FreeValue(ctx, wv);
        if (c.JS_IsArray(wv)) {
            const lv = c.JS_GetPropertyStr(ctx, wv, "length");
            defer c.JS_FreeValue(ctx, lv);
            var n: i32 = 0;
            if (c.JS_ToInt32(ctx, &n, lv) == 0 and n > 0) {
                allocator.free(chunks);
                chunks = try allocator.alloc([]u8, @intCast(n));
                var built: usize = 0;
                errdefer for (chunks[0..built]) |ch| allocator.free(ch);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const ev = c.JS_GetPropertyUint32(ctx, wv, i);
                    defer c.JS_FreeValue(ctx, ev);
                    chunks[i] = try jsValueAsOwnedBytes(allocator, ctx, ev);
                    built = i + 1;
                }
            }
        }
    }

    // waitFor — accepted in two shapes:
    //   - object: { timer: { intervalMs }, kv: { prefix } }
    //   - array:  [{ timer: {...} }, { kv: { prefix } }, ...]
    // (streaming-handlers-plan §3.3 prescribes the array form; we
    // accept the singular-object form too for ergonomics.) Each
    // condition is parsed independently — multiple kv prefixes are
    // accumulated into `kv_prefixes`; at most one timer interval is
    // honored (last-wins).
    var interval_ms: ?i64 = null;
    var prefixes_list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (prefixes_list.items) |p| allocator.free(p);
        prefixes_list.deinit(allocator);
    }
    {
        const wf = c.JS_GetPropertyStr(ctx, val, "waitFor");
        defer c.JS_FreeValue(ctx, wf);
        if (c.JS_IsArray(wf)) {
            const lv = c.JS_GetPropertyStr(ctx, wf, "length");
            defer c.JS_FreeValue(ctx, lv);
            var n: i32 = 0;
            if (c.JS_ToInt32(ctx, &n, lv) == 0 and n > 0) {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const elt = c.JS_GetPropertyUint32(ctx, wf, i);
                    defer c.JS_FreeValue(ctx, elt);
                    if (c.JS_IsObject(elt)) {
                        try parseWaitForCondition(allocator, ctx, elt, &interval_ms, &prefixes_list);
                    }
                }
            }
        } else if (c.JS_IsObject(wf)) {
            try parseWaitForCondition(allocator, ctx, wf, &interval_ms, &prefixes_list);
        }
    }
    const kv_prefixes = try prefixes_list.toOwnedSlice(allocator);
    errdefer {
        for (kv_prefixes) |p| allocator.free(p);
        if (kv_prefixes.len > 0) allocator.free(kv_prefixes);
    }

    // ctx (any → JSON string; default "null").
    const ctx_json = blk: {
        const cv = c.JS_GetPropertyStr(ctx, val, "ctx");
        defer c.JS_FreeValue(ctx, cv);
        if (c.JS_IsUndefined(cv) or c.JS_IsException(cv)) {
            break :blk try allocator.dupe(u8, "null");
        }
        const j = c.JS_JSONStringify(ctx, cv, js_undefined, js_undefined);
        defer c.JS_FreeValue(ctx, j);
        if (c.JS_IsException(j) or c.JS_IsUndefined(j)) {
            break :blk try allocator.dupe(u8, "null");
        }
        break :blk try jsValueAsOwnedBytes(allocator, ctx, j);
    };

    return .{
        .status = status,
        .headers = headers,
        .chunks = chunks,
        .interval_ms = interval_ms,
        .kv_prefixes = kv_prefixes,
        .ctx_json = ctx_json,
    };
}

/// Read one waitFor condition `{ timer: {...} }` or `{ kv: { prefix } }`
/// (or both, on the same object) and accumulate into the caller's
/// `interval_ms` / `prefixes_list`. Unknown keys are ignored — keeps
/// forward-compat with future condition variants. OOM propagates;
/// malformed condition shapes (missing `prefix`, bad types) are silent
/// no-ops (same accidental-collision posture as `tryExtract`).
fn parseWaitForCondition(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    interval_ms: *?i64,
    prefixes_list: *std.ArrayListUnmanaged([]u8),
) error{OutOfMemory}!void {
    {
        const tv = c.JS_GetPropertyStr(ctx, obj, "timer");
        defer c.JS_FreeValue(ctx, tv);
        if (c.JS_IsObject(tv)) {
            const iv = c.JS_GetPropertyStr(ctx, tv, "intervalMs");
            defer c.JS_FreeValue(ctx, iv);
            if (c.JS_IsNumber(iv)) {
                var n: f64 = 0;
                if (c.JS_ToFloat64(ctx, &n, iv) == 0 and n > 0) {
                    interval_ms.* = @intFromFloat(n);
                }
            }
        }
    }
    {
        const kv = c.JS_GetPropertyStr(ctx, obj, "kv");
        defer c.JS_FreeValue(ctx, kv);
        if (c.JS_IsObject(kv)) {
            const pv = c.JS_GetPropertyStr(ctx, kv, "prefix");
            defer c.JS_FreeValue(ctx, pv);
            if (c.JS_IsString(pv)) {
                const dup = try jsValueAsOwnedBytes(allocator, ctx, pv);
                errdefer allocator.free(dup);
                try prefixes_list.append(allocator, dup);
            }
        }
    }
}

fn jsStrEql(ctx: ?*c.JSContext, v: c.JSValue, want: []const u8) bool {
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return false;
    defer c.JS_FreeCString(ctx, s);
    return std.mem.eql(u8, s[0..len], want);
}

fn jsValueAsOwnedBytes(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    v: c.JSValue,
) error{OutOfMemory}![]u8 {
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return error.OutOfMemory;
    defer c.JS_FreeCString(ctx, s);
    return try allocator.dupe(u8, s[0..len]);
}

/// Render `{key: value, ...}` as wire-format `Key: value\r\n` lines.
/// Values are coerced to strings via `JS_ToCString`. Returns the
/// owned buffer (no terminator); empty when the object has no
/// string-valued props.
fn renderHeaders(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    obj: c.JSValue,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var ptab: ?[*]c.JSPropertyEnum = null;
    var plen: u32 = 0;
    if (c.JS_GetOwnPropertyNames(
        ctx,
        &ptab,
        &plen,
        obj,
        c.JS_GPN_STRING_MASK | c.JS_GPN_ENUM_ONLY,
    ) != 0) return error.OutOfMemory;
    defer {
        var i: u32 = 0;
        while (i < plen) : (i += 1) c.JS_FreeAtom(ctx, ptab.?[i].atom);
        if (ptab != null) c.js_free(ctx, ptab);
    }

    var i: u32 = 0;
    while (i < plen) : (i += 1) {
        const atom = ptab.?[i].atom;
        const name_v = c.JS_AtomToString(ctx, atom);
        defer c.JS_FreeValue(ctx, name_v);
        var nlen: usize = 0;
        const np = c.JS_ToCStringLen(ctx, &nlen, name_v);
        if (np == null) return error.OutOfMemory;
        defer c.JS_FreeCString(ctx, np);

        const val_v = c.JS_GetProperty(ctx, obj, atom);
        defer c.JS_FreeValue(ctx, val_v);
        var vlen: usize = 0;
        const vp = c.JS_ToCStringLen(ctx, &vlen, val_v);
        if (vp == null) return error.OutOfMemory;
        defer c.JS_FreeCString(ctx, vp);

        try out.appendSlice(allocator, np[0..nlen]);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, vp[0..vlen]);
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "brand is stable within a process and 32 hex chars (Stream)" {
    const a = brand();
    const b = brand();
    try testing.expectEqual(@as(usize, 32), a.len);
    try testing.expectEqualSlices(u8, a, b);
}

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
