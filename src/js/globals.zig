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
    /// Per-request identifier, pre-minted by the worker. Combined with
    /// `webhook_call_index` to derive a deterministic outbox id for
    /// every `webhook.send` this handler invocation performs.
    request_id: u64 = 0,
    /// 0-based counter of `webhook.send` calls within this handler
    /// invocation. Resets per request. Part of the outbox id derivation
    /// so replays produce the same ids.
    webhook_call_index: u32 = 0,
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

/// `kv.prefix(prefix, cursor?, limit?)` → `[ { key, value }, ... ]`
///
/// Prefix scan exposed to handlers. `cursor` is the last key from a
/// previous page (pass "" to start). `limit` defaults to 100, capped
/// at 1000 — this is an admin/introspection surface, not a hot read
/// path, so we err on the side of small pages. Reads go directly
/// through `state.kv`; writes from the same handler are visible here
/// because the underlying SQLite connection sees its own uncommitted
/// txn state.
///
/// NOT tape-captured in this slice — replay of prefix-scanning
/// handlers will see live KV state, not the state at capture time.
/// Deferred until the replay surface actually needs it.
fn jsKvPrefix(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);

    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const KV_PREFIX_MAX: u32 = 1000;
    const KV_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk KV_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), KV_PREFIX_MAX);
    } else KV_PREFIX_DEFAULT;

    var scan = state.kv.prefix(prefix_str, cursor_str, limit) catch |err| {
        state.pending_kv_error = err;
        return js_null;
    };
    defer scan.deinit();

    const arr = c.JS_NewArray(ctx);
    for (scan.entries, 0..) |e, i| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "key", c.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "value", c.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
    }
    return arr;
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

// ── webhook.send ──────────────────────────────────────────────────────
//
// Writes a serialized delivery envelope to `_outbox/{id}` inside the
// current handler transaction. The drainer (separate thread on the
// raft leader) picks these up, makes the HTTP call, and enqueues a
// callback. Id derivation: `sha256(request_id || call_index)` — both
// pre-minted so the same handler run against the same inputs produces
// the same ids, which is what replay determinism wants.
//
// We build the envelope as a JS object with a normalized shape
// (defaults filled in, derived fields stamped), then `JS_JSONStringify`
// it. Cheaper than hand-rolling the escaping for strings / headers /
// context.

fn computeOutboxId(request_id: u64, call_index: u32, out: *[64]u8) void {
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], request_id, .big);
    std.mem.writeInt(u32, buf[8..12], call_index, .big);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&buf, &digest, .{});
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Transfer `src` to `dst[name]`. Ownership moves — don't free `src`
/// after this.
fn setOwned(ctx: ?*c.JSContext, dst: c.JSValue, name: [:0]const u8, src: c.JSValue) void {
    _ = c.JS_SetPropertyStr(ctx, dst, name.ptr, src);
}

/// Copy `opts[name]` to `dst[name]` when present. If `default_val` is
/// non-null, fall back to it (refcount consumed).
fn copyField(
    ctx: ?*c.JSContext,
    opts: c.JSValue,
    dst: c.JSValue,
    name: [:0]const u8,
    default_val: ?c.JSValue,
) void {
    const v = c.JS_GetPropertyStr(ctx, opts, name.ptr);
    if (c.JS_IsUndefined(v)) {
        c.JS_FreeValue(ctx, v);
        if (default_val) |d| setOwned(ctx, dst, name, d);
        return;
    }
    if (default_val) |d| c.JS_FreeValue(ctx, d);
    setOwned(ctx, dst, name, v);
}

fn jsWebhookSend(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "webhook.send requires an options object");
        return js_exception;
    }
    const opts = argv[0];

    // url is required and must be a string.
    const url_v = c.JS_GetPropertyStr(ctx, opts, "url");
    if (!c.JS_IsString(url_v)) {
        c.JS_FreeValue(ctx, url_v);
        _ = c.JS_ThrowTypeError(ctx, "webhook.send: `url` must be a string");
        return js_exception;
    }

    var id_hex: [64]u8 = undefined;
    computeOutboxId(state.request_id, state.webhook_call_index, &id_hex);

    // Build the canonical envelope. Users supply the interesting
    // fields; we derive id / attempts / next_attempt_at / created_at /
    // parent_request_id. Setting on env transfers ownership — don't
    // free the `url_v` below.
    const env = c.JS_NewObject(ctx);
    setOwned(ctx, env, "v", c.JS_NewInt32(ctx, 1));
    setOwned(ctx, env, "id", c.JS_NewStringLen(ctx, &id_hex, 64));
    setOwned(ctx, env, "url", url_v);

    // method: default "POST".
    copyField(ctx, opts, env, "method", c.JS_NewString(ctx, "POST"));
    // headers: default {}.
    copyField(ctx, opts, env, "headers", c.JS_NewObject(ctx));
    // body: default "".
    copyField(ctx, opts, env, "body", c.JS_NewString(ctx, ""));
    // onResult: default null (no callback).
    copyField(ctx, opts, env, "on_result", js_null);
    // context: default null.
    copyField(ctx, opts, env, "context", js_null);
    // max_attempts: default 10.
    copyField(ctx, opts, env, "max_attempts", c.JS_NewInt32(ctx, 10));
    // timeout_ms: default 30_000.
    copyField(ctx, opts, env, "timeout_ms", c.JS_NewInt32(ctx, 30_000));
    // retry_on: default the standard retryable status list + "network".
    const default_retry = c.JS_NewArray(ctx);
    const default_codes = [_]i32{ 408, 425, 429, 500, 502, 503, 504 };
    for (default_codes, 0..) |code, i| {
        _ = c.JS_SetPropertyUint32(ctx, default_retry, @intCast(i), c.JS_NewInt32(ctx, code));
    }
    _ = c.JS_SetPropertyUint32(ctx, default_retry, default_codes.len, c.JS_NewString(ctx, "network"));
    copyField(ctx, opts, env, "retry_on", default_retry);

    // Derived state. These advance as the drainer works through it.
    setOwned(ctx, env, "attempts", c.JS_NewInt32(ctx, 0));
    setOwned(ctx, env, "next_attempt_at_ms", c.JS_NewInt64(ctx, 0));
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    setOwned(ctx, env, "created_at_ms", c.JS_NewInt64(ctx, now_ms));
    setOwned(ctx, env, "parent_request_id", c.JS_NewInt64(ctx, @bitCast(state.request_id)));

    // Serialize envelope → bytes.
    const json = c.JS_JSONStringify(ctx, env, js_undefined, js_undefined);
    c.JS_FreeValue(ctx, env);
    if (c.JS_IsException(json) or c.JS_IsUndefined(json)) {
        c.JS_FreeValue(ctx, json);
        return js_exception;
    }
    defer c.JS_FreeValue(ctx, json);

    var json_len: usize = 0;
    const json_cstr = c.JS_ToCStringLen(ctx, &json_len, json);
    if (json_cstr == null) return js_exception;
    defer c.JS_FreeCString(ctx, json_cstr);
    const json_slice = @as([*]const u8, @ptrCast(json_cstr))[0..json_len];

    // Write `_outbox/{id}` through the handler's tx + writeset so the
    // outbox entry commits (or rolls back) atomically with the rest of
    // the handler's kv writes.
    var key_buf: [8 + 64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "_outbox/{s}", .{id_hex}) catch unreachable;

    state.txn.put(key, json_slice) catch |err| {
        state.pending_kv_error = err;
        return js_exception;
    };
    state.writeset.addPut(key, json_slice) catch |err| {
        state.pending_kv_error = err;
        return js_exception;
    };

    state.webhook_call_index += 1;
    return c.JS_NewStringLen(ctx, &id_hex, 64);
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

/// Install the pieces of the global surface that do NOT depend on a
/// per-request `DispatchState` or `Request`. Safe to call from a
/// snapshot init callback — pure, deterministic, no clocks, no
/// allocation outside the arena. The bulk of the cost of setting up a
/// JS handler context lives here (C-function bindings register atoms
/// and shape transitions), so doing it once at snapshot creation time
/// and then memcpy-restoring for each request is the whole point of
/// rove-qjs.
///
/// Installs: `kv`, `console`, `crypto`, `Date.now`, `Math.random`.
/// Does NOT install `request`, `response`, or the context opaque —
/// see `installRequest`.
pub fn installStatic(ctx: *c.JSContext) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // kv = { get, set, delete, prefix }
    const kv_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "get", c.JS_NewCFunction2(ctx, jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "set", c.JS_NewCFunction2(ctx, jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "delete", c.JS_NewCFunction2(ctx, jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "prefix", c.JS_NewCFunction2(ctx, jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "kv", kv_obj);

    // console = { log }
    const console_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, console_obj, "log", c.JS_NewCFunction2(ctx, jsConsoleLog, "log", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "console", console_obj);

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

    // webhook = { send }. Delivery is async — send() persists the
    // envelope in the handler's transaction and returns an id; the
    // drainer thread on the raft leader does the actual HTTP call.
    const webhook_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, webhook_obj, "send", c.JS_NewCFunction2(ctx, jsWebhookSend, "send", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "webhook", webhook_obj);
}

/// Install the per-request pieces of the global surface: attach
/// `state` as the context opaque, and create `request`/`response`
/// globals populated from the incoming request. Called AFTER
/// `Snapshot.restore` on every request. Cheap — just a handful of
/// `JS_SetPropertyStr` calls.
pub fn installRequest(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    c.JS_SetContextOpaque(ctx, state);

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // request = { method, path, body }
    const req_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, req_obj, "method", c.JS_NewStringLen(ctx, request.method.ptr, request.method.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "path", c.JS_NewStringLen(ctx, request.path.ptr, request.path.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "body", c.JS_NewStringLen(ctx, request.body.ptr, request.body.len));
    _ = c.JS_SetPropertyStr(ctx, global, "request", req_obj);

    // response = { status: 200, headers: {}, cookies: [] }
    //
    // Response body comes from the exported function's return value —
    // not from `response.body`. The `response` global is ONLY for
    // metadata: status, custom headers, and Set-Cookie entries.
    // Handlers mutate these freely; the dispatcher reads them after
    // the call and merges with the JSON-serialized return value.
    const resp_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "status", c.JS_NewInt32(ctx, 200));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "headers", c.JS_NewObject(ctx));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "cookies", c.JS_NewArray(ctx));
    _ = c.JS_SetPropertyStr(ctx, global, "response", resp_obj);
}

/// Back-compat wrapper: install everything at once. Used by tests and
/// by any caller that doesn't have a pre-built snapshot to restore
/// from (e.g. the rove-files compile-on-upload path that just needs a
/// throwaway context to compile JS to bytecode).
pub fn install(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    installStatic(ctx);
    installRequest(ctx, state, request);
}
