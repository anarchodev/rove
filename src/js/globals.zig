//! JS globals installed on every request context.
//!
//! Four globals for M1:
//!
//!   `kv.get(key)`              → string | null
//!   `kv.set(key, value)`       → undefined
//!   `kv.delete(key)`           → undefined
//!   `console.log(...args)`     → undefined (appended to stderr-buffer)
//!   `request`                  → `{ method, path, body }` (read-only by convention)
//!   `response`                 → `{ status: 200, body: "", headers: {} }`
//!
//! State shared between the C functions and the dispatcher lives in a
//! `DispatchState` struct stashed on the context via
//! `JS_SetContextOpaque`. The C callbacks pull the state pointer out of
//! the context on every call.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");

const c = qjs.c;

// Zig's @cImport can't translate quickjs-ng's designated-initializer
// macros for `JS_UNDEFINED` etc. (they trip `std.mem.zeroInit` on the
// anonymous union). Reconstruct them by hand — the layout is stable in
// non-NaN-boxing mode, which is what our Linux x86_64 build uses.
inline fn mkVal(tag: i64, val: i32) c.JSValue {
    return .{ .u = .{ .int32 = val }, .tag = tag };
}
pub const js_undefined: c.JSValue = mkVal(c.JS_TAG_UNDEFINED, 0);
pub const js_null: c.JSValue = mkVal(c.JS_TAG_NULL, 0);
pub const js_exception: c.JSValue = mkVal(c.JS_TAG_EXCEPTION, 0);

pub const DispatchState = struct {
    allocator: std.mem.Allocator,
    /// Per-request KV store. `kv.get("x")` reads from this handle,
    /// which is the SAME connection the `TrackedTxn` opened its
    /// transaction on, so reads see the transaction's uncommitted
    /// writes — read-your-writes works within one handler.
    kv: *kv_mod.KvStore,
    /// Open tracked transaction on `kv`. Writes from the handler go
    /// through this (for local visibility + undo) AND through the
    /// `writeset` (for raft replication). Committed or rolled back
    /// after raft reports back — see `worker.drainRaftPending`.
    txn: *kv_mod.TrackedTxn,
    /// Raft write accumulator. Shape-parallel to the `TrackedTxn`'s
    /// local writes — followers replay the encoded writeset against
    /// their tenant stores via `applyEncodedWriteSet`.
    writeset: *kv_mod.WriteSet,
    /// Accumulated `console.log` output. Owned by the dispatcher; reset
    /// between requests.
    console: *std.ArrayList(u8),
    /// Set if a kv-level error needs to bubble back to the caller after
    /// the JS runs. We can't throw from inside the C callback cleanly in
    /// all cases, so we record the first error and let the dispatcher
    /// surface it.
    pending_kv_error: ?anyerror = null,
    /// Optional kv tape. When non-null, every `kv.get` / `kv.set` /
    /// `kv.delete` the handler performs is appended as an entry so a
    /// later replay can re-drive the same handler without touching a
    /// live KV store. Null means "don't capture" (tests, legacy paths).
    kv_tape: ?*tape_mod.Tape = null,
    date_tape: ?*tape_mod.Tape = null,
    math_random_tape: ?*tape_mod.Tape = null,
    crypto_random_tape: ?*tape_mod.Tape = null,
    /// PRNG used by our `Math.random` override so the test path and
    /// production path stay deterministic w.r.t. a given seed. Seeded
    /// by the dispatcher per request. Installed only when a tape is
    /// present (so the normal path still uses qjs's built-in Math.random).
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
};

// ── C helpers ──────────────────────────────────────────────────────────

fn getState(ctx: ?*c.JSContext) *DispatchState {
    const opaque_ptr = c.JS_GetContextOpaque(ctx);
    return @ptrCast(@alignCast(opaque_ptr.?));
}

/// Convert a JS value to a Zig-owned string via the state allocator.
/// Caller frees.
fn valueToOwnedString(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    val: c.JSValue,
) ![]u8 {
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const out = try state.allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
    return out;
}

// ── kv.* ──────────────────────────────────────────────────────────────

fn jsKvGet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);

    const value = state.kv.get(key_str) catch |err| switch (err) {
        error.NotFound => {
            if (state.kv_tape) |t| t.appendKv(.get, key_str, "", .not_found) catch {};
            return js_null;
        },
        else => {
            state.pending_kv_error = err;
            if (state.kv_tape) |t| t.appendKv(.get, key_str, "", .err) catch {};
            return js_null;
        },
    };
    defer state.allocator.free(value);

    if (state.kv_tape) |t| t.appendKv(.get, key_str, value, .ok) catch {};
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

fn jsKvSet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);
    const val_str = valueToOwnedString(state, ctx, argv[1]) catch return js_exception;
    defer state.allocator.free(val_str);

    // Two parallel writes:
    //   1. Through the TrackedTxn → local SQLite + undo log. Gives
    //      read-your-writes within this handler and durable local
    //      state on commit.
    //   2. Into the WriteSet → encoded and proposed through raft so
    //      followers apply the same writes via `applyEncodedWriteSet`.
    state.txn.put(key_str, val_str) catch |err| {
        state.pending_kv_error = err;
        if (state.kv_tape) |t| t.appendKv(.set, key_str, val_str, .err) catch {};
        return js_undefined;
    };
    state.writeset.addPut(key_str, val_str) catch |err| {
        state.pending_kv_error = err;
    };
    if (state.kv_tape) |t| t.appendKv(.set, key_str, val_str, .ok) catch {};
    return js_undefined;
}

fn jsKvDelete(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);

    state.txn.delete(key_str) catch |err| {
        state.pending_kv_error = err;
        if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .err) catch {};
        return js_undefined;
    };
    state.writeset.addDelete(key_str) catch |err| {
        state.pending_kv_error = err;
    };
    if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .ok) catch {};
    return js_undefined;
}

// ── Date.now / Math.random / crypto.* ─────────────────────────────────
//
// These are tape-backed non-determinism sources. The MVP shape is:
//   - Only install overrides when `DispatchState` has a matching tape.
//     Without a tape the handler uses qjs's built-ins (qjs Math.random
//     is a stock xoshiro, Date.now is gettimeofday, there's no crypto
//     global). With a tape we stamp a deterministic value AND record
//     it so replay can re-issue the same value.
//   - Phase 4 slice 3 only does capture. Replay mode — reading values
//     back from a `ReplaySource` — is the next slice.
//   - `new Date()` with no args is NOT intercepted yet; handlers should
//     use `Date.now()` for now. Overriding the constructor requires
//     more qjs plumbing than is worth in this slice.

fn jsDateNow(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    // Wall-clock ms. Determinism comes from the tape on replay — the
    // live path still reads the real clock so logs of real requests
    // show real timestamps.
    const ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    if (state.date_tape) |t| t.appendDate(ms) catch {};
    return c.JS_NewInt64(ctx, ms);
}

fn jsMathRandom(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    // Draw a 53-bit mantissa from the PRNG and scale to [0, 1).
    // Matches what qjs's built-in Math.random does, just seeded.
    const bits = state.prng.random().int(u64) >> 11;
    const v: f64 = @as(f64, @floatFromInt(bits)) * (1.0 / @as(f64, @floatFromInt(@as(u64, 1) << 53)));
    if (state.math_random_tape) |t| t.appendMathRandom(v) catch {};
    return c.JS_NewFloat64(ctx, v);
}

fn jsCryptoGetRandomValues(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_exception;
    const state = getState(ctx);

    // The Web Crypto API expects a typed array. We reach into the
    // ArrayBuffer directly via JS_GetArrayBuffer. Non-typed-array
    // inputs get rejected with an exception.
    var byte_len: usize = 0;
    const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, argv[0]);
    if (buf_ptr == null) return js_exception;

    const bytes = buf_ptr[0..byte_len];
    state.prng.random().bytes(bytes);
    if (state.crypto_random_tape) |t| t.appendCryptoRandom(bytes) catch {};
    // Spec says return the input typed array.
    return c.JS_DupValue(ctx, argv[0]);
}

fn jsCryptoRandomUuid(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);

    var raw: [16]u8 = undefined;
    state.prng.random().bytes(&raw);
    // RFC 4122 v4: set the version and variant bits.
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;

    // Capture the raw bytes on the crypto tape so the replay source
    // can reconstruct the same UUID without knowing the formatting.
    if (state.crypto_random_tape) |t| t.appendCryptoRandom(&raw) catch {};

    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var oi: usize = 0;
    for (raw, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0x0f];
        oi += 2;
    }
    return c.JS_NewStringLen(ctx, &out, 36);
}

// ── console.log ───────────────────────────────────────────────────────

fn jsConsoleLog(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    const n: usize = if (argc < 0) 0 else @intCast(argc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) state.console.append(state.allocator, ' ') catch return js_exception;
        const s = valueToOwnedString(state, ctx, argv[i]) catch return js_exception;
        defer state.allocator.free(s);
        state.console.appendSlice(state.allocator, s) catch return js_exception;
    }
    state.console.append(state.allocator, '\n') catch return js_exception;
    return js_undefined;
}

// ── Installation ──────────────────────────────────────────────────────

/// Install the full global surface and attach `state` to `ctx`. Must be
/// called before evaluating handler source.
pub fn install(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    c.JS_SetContextOpaque(ctx, state);

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // kv = { get, set, delete }
    const kv_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "get", c.JS_NewCFunction2(ctx, jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "set", c.JS_NewCFunction2(ctx, jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "delete", c.JS_NewCFunction2(ctx, jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "kv", kv_obj);

    // console = { log }
    const console_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, console_obj, "log", c.JS_NewCFunction2(ctx, jsConsoleLog, "log", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "console", console_obj);

    // request = { method, path, body }
    const req_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, req_obj, "method", c.JS_NewStringLen(ctx, request.method.ptr, request.method.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "path", c.JS_NewStringLen(ctx, request.path.ptr, request.path.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "body", c.JS_NewStringLen(ctx, request.body.ptr, request.body.len));
    _ = c.JS_SetPropertyStr(ctx, global, "request", req_obj);

    // response = { status: 200, body: "", headers: {} }
    const resp_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "status", c.JS_NewInt32(ctx, 200));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "body", c.JS_NewStringLen(ctx, "", 0));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "headers", c.JS_NewObject(ctx));
    _ = c.JS_SetPropertyStr(ctx, global, "response", resp_obj);

    // Non-determinism overrides. Always installed (tape optional) so
    // the handler-visible API is stable whether we're capturing or not;
    // the C callbacks short-circuit their tape branches when the
    // matching `DispatchState` tape is null.
    const date_obj = c.JS_GetPropertyStr(ctx, global, "Date");
    defer c.JS_FreeValue(ctx, date_obj);
    if (!c.JS_IsUndefined(date_obj)) {
        _ = c.JS_SetPropertyStr(ctx, date_obj, "now", c.JS_NewCFunction2(ctx, jsDateNow, "now", 0, c.JS_CFUNC_generic, 0));
    }

    const math_obj = c.JS_GetPropertyStr(ctx, global, "Math");
    defer c.JS_FreeValue(ctx, math_obj);
    if (!c.JS_IsUndefined(math_obj)) {
        _ = c.JS_SetPropertyStr(ctx, math_obj, "random", c.JS_NewCFunction2(ctx, jsMathRandom, "random", 0, c.JS_CFUNC_generic, 0));
    }

    // crypto = { getRandomValues, randomUUID }. No crypto global in
    // qjs-ng by default, so we fabricate one.
    const crypto_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "getRandomValues", c.JS_NewCFunction2(ctx, jsCryptoGetRandomValues, "getRandomValues", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "randomUUID", c.JS_NewCFunction2(ctx, jsCryptoRandomUuid, "randomUUID", 0, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "crypto", crypto_obj);
}
