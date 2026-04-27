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
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");

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
    /// Singleton admin-capability pointer. Non-null only when the
    /// handler-tenant is `__admin__`; the dispatcher installs the
    /// `platform.*` JS globals (instance / domain / root kv access)
    /// iff this field is set. Regular tenants' handlers see
    /// `platform === undefined` in their runtime.
    platform: ?*tenant_mod.Tenant = null,
    /// Raft writeset accumulating root-store writes the admin
    /// handler makes via `platform.root.set` / `platform.root.delete`.
    /// Dispatcher creates this alongside the per-tenant writeset
    /// when `platform != null`; worker proposes it through raft as
    /// a type=2 envelope after commit so followers' copies of
    /// `__root__.db` stay in sync.
    root_writeset: ?*kv_mod.WriteSet = null,
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

/// `crypto.hmacSha256(key, data)` → hex string (64 chars).
///
/// Both arguments accept either a JS string (UTF-8 bytes) or a
/// Uint8Array. Deterministic — does NOT tape-capture (HMAC of known
/// inputs is a pure function, so replay reproduces the same digest).
///
/// PLAN §2.6: we keep `webhook.send` vendor-neutral and expose this
/// as the primitive customers compose into Stripe-Signature,
/// Slack X-Slack-Signature, AWS SigV4 derivations, etc.
fn jsCryptoHmacSha256(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) {
        _ = c.JS_ThrowTypeError(ctx, "crypto.hmacSha256 requires (key, data)");
        return js_exception;
    }

    var key_cstr: [*c]const u8 = null;
    defer if (key_cstr != null) c.JS_FreeCString(ctx, key_cstr);
    var data_cstr: [*c]const u8 = null;
    defer if (data_cstr != null) c.JS_FreeCString(ctx, data_cstr);

    const key_bytes = extractKeyOrDataBytes(ctx, argv[0], &key_cstr) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.hmacSha256: key must be a string or Uint8Array");
        return js_exception;
    };
    const data_bytes = extractKeyOrDataBytes(ctx, argv[1], &data_cstr) orelse {
        _ = c.JS_ThrowTypeError(ctx, "crypto.hmacSha256: data must be a string or Uint8Array");
        return js_exception;
    };

    var digest: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&digest, data_bytes, key_bytes);

    var out: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return c.JS_NewStringLen(ctx, &out, 64);
}

/// Read a JS value as a byte slice. Tries string first (common path
/// for HMAC over request bodies), falls back to Uint8Array (for
/// binary secrets / pre-hashed data). Returns null if neither.
///
/// When the string path is taken, `cstr_out` gets the JS_ToCStringLen
/// pointer that the caller must free via `JS_FreeCString`.
fn extractKeyOrDataBytes(
    ctx: ?*c.JSContext,
    val: c.JSValue,
    cstr_out: *[*c]const u8,
) ?[]const u8 {
    if (c.JS_IsString(val)) {
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(ctx, &len, val);
        if (cstr == null) return null;
        cstr_out.* = cstr;
        return @as([*]const u8, @ptrCast(cstr))[0..len];
    }
    var byte_len: usize = 0;
    const buf_ptr = c.JS_GetUint8Array(ctx, &byte_len, val);
    if (buf_ptr == null) {
        // JS_GetUint8Array may have set a pending exception — clear
        // it so we can throw our own message above.
        const pending = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, pending);
        return null;
    }
    return buf_ptr[0..byte_len];
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

/// Copy `opts[src_name]` to `dst[dst_name]` when present. Used to map
/// the camelCase public API (`onResult`, `maxAttempts`, ...) onto the
/// snake_case envelope shape that tools on the delivery side read.
fn copyFieldRenamed(
    ctx: ?*c.JSContext,
    opts: c.JSValue,
    dst: c.JSValue,
    src_name: [:0]const u8,
    dst_name: [:0]const u8,
    default_val: ?c.JSValue,
) void {
    const v = c.JS_GetPropertyStr(ctx, opts, src_name.ptr);
    if (c.JS_IsUndefined(v)) {
        c.JS_FreeValue(ctx, v);
        if (default_val) |d| setOwned(ctx, dst, dst_name, d);
        return;
    }
    if (default_val) |d| c.JS_FreeValue(ctx, d);
    setOwned(ctx, dst, dst_name, v);
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

    // Public input shape uses camelCase (matches PLAN §2.6); envelope
    // on disk uses snake_case so Zig-side tools + JSON tooling around
    // the drainer don't have to transliterate.
    copyField(ctx, opts, env, "method", c.JS_NewString(ctx, "POST"));
    copyField(ctx, opts, env, "headers", c.JS_NewObject(ctx));
    copyField(ctx, opts, env, "body", c.JS_NewString(ctx, ""));
    copyField(ctx, opts, env, "context", js_null);
    copyFieldRenamed(ctx, opts, env, "onResult", "on_result", js_null);
    copyFieldRenamed(ctx, opts, env, "maxAttempts", "max_attempts", c.JS_NewInt32(ctx, 10));
    copyFieldRenamed(ctx, opts, env, "timeout", "timeout_ms", c.JS_NewInt32(ctx, 30_000));
    // retryOn: default the standard retryable status list + "network".
    const default_retry = c.JS_NewArray(ctx);
    const default_codes = [_]i32{ 408, 425, 429, 500, 502, 503, 504 };
    for (default_codes, 0..) |code, i| {
        _ = c.JS_SetPropertyUint32(ctx, default_retry, @intCast(i), c.JS_NewInt32(ctx, code));
    }
    _ = c.JS_SetPropertyUint32(ctx, default_retry, default_codes.len, c.JS_NewString(ctx, "network"));
    copyFieldRenamed(ctx, opts, env, "retryOn", "retry_on", default_retry);

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

// ── platform.root.* (admin singleton only) ────────────────────────
//
// Only installed when the handler-tenant is `__admin__` — gated on
// `state.platform` being non-null in `installRequest`. Provides raw
// access to the platform root store for the admin JS handler's
// instance / domain / user / account reads. Writes currently land
// locally on the leader only (no raft propagation of root writes
// from JS handlers yet); multi-node correctness for admin-handler
// writes is follow-up work. Signup + other platform-level writes
// go through the Zig-native HTTP endpoints, which DO replicate.

fn jsPlatformRootGet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);

    const value = tenant.root.get(key) catch |err| switch (err) {
        error.NotFound => return js_null,
        else => {
            state.pending_kv_error = err;
            return js_null;
        },
    };
    defer state.allocator.free(value);
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

fn jsPlatformRootSet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);
    const val = valueToOwnedString(state, ctx, argv[1]) catch return js_exception;
    defer state.allocator.free(val);

    tenant.root.put(key, val) catch |err| {
        state.pending_kv_error = err;
    };
    // Mirror the write into the root writeset so the worker can
    // propose it through raft. Admin handlers ALWAYS have this
    // set (dispatcher init checks `platform != null`), so an unset
    // field here means someone built a DispatchState by hand.
    if (state.root_writeset) |ws| {
        ws.addPut(key, val) catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

fn jsPlatformRootDelete(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);

    tenant.root.delete(key) catch |err| switch (err) {
        error.NotFound => {
            // Still propagate the delete to followers so their state
            // converges — a key that's missing locally might exist
            // on other nodes if propose ordering skewed. The follower
            // `applyEncodedWriteSet` treats NotFound as a no-op.
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    if (state.root_writeset) |ws| {
        ws.addDelete(key) catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

fn jsPlatformRootPrefix(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);

    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const ROOT_PREFIX_MAX: u32 = 1000;
    const ROOT_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk ROOT_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), ROOT_PREFIX_MAX);
    } else ROOT_PREFIX_DEFAULT;

    var scan = tenant.root.prefix(prefix_str, cursor_str, limit) catch |err| {
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
/// Installs: `kv`, `console`, `crypto`, `Date.now`, `Math.random`,
/// `webhook`, `email`. Installs `platform` on every context too —
/// the per-request `installRequest` gates it on `state.platform` so
/// callbacks reject non-admin handlers at call time.
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

    // crypto = { getRandomValues, randomUUID, hmacSha256 }. No crypto
    // global in qjs-ng by default, so we fabricate one. hmacSha256 is
    // the vendor-neutral primitive for building Stripe / Slack / AWS
    // style signatures in handler code (see PLAN §2.6).
    const crypto_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "getRandomValues", c.JS_NewCFunction2(ctx, jsCryptoGetRandomValues, "getRandomValues", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "randomUUID", c.JS_NewCFunction2(ctx, jsCryptoRandomUuid, "randomUUID", 0, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "hmacSha256", c.JS_NewCFunction2(ctx, jsCryptoHmacSha256, "hmacSha256", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "crypto", crypto_obj);

    // webhook = { send }. Delivery is async — send() persists the
    // envelope in the handler's transaction and returns an id; the
    // drainer thread on the raft leader does the actual HTTP call.
    const webhook_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, webhook_obj, "send", c.JS_NewCFunction2(ctx, jsWebhookSend, "send", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "webhook", webhook_obj);

    // email.send — thin wrapper around webhook.send that builds a
    // Resend-shaped POST and takes the API key as a parameter rather
    // than resolving it from platform config. Keeps key storage a
    // customer concern (kv entry, inlined, fetched from elsewhere)
    // and keeps the platform out of the abuse loop: a customer can
    // only email.send using a Resend key they have.
    //
    // Our own magic-link / signup emails are queued by the Zig-
    // native signup handler, which reads the platform Resend key
    // off root.db and writes the outbox row into __admin__'s app.db.
    const email_snippet =
        \\globalThis.email = {
        \\  send(opts) {
        \\    if (!opts || typeof opts !== "object")
        \\      throw new TypeError("email.send requires an options object");
        \\    if (typeof opts.key !== "string" || opts.key.length === 0)
        \\      throw new TypeError("email.send: `key` must be a non-empty string");
        \\    if (typeof opts.from !== "string")
        \\      throw new TypeError("email.send: `from` must be a string");
        \\    if (typeof opts.subject !== "string")
        \\      throw new TypeError("email.send: `subject` must be a string");
        \\    if (!opts.to)
        \\      throw new TypeError("email.send: `to` is required");
        \\    const body = {
        \\      from: opts.from,
        \\      to: Array.isArray(opts.to) ? opts.to : [opts.to],
        \\      subject: opts.subject,
        \\    };
        \\    if (opts.text) body.text = opts.text;
        \\    if (opts.html) body.html = opts.html;
        \\    if (opts.reply_to) body.reply_to = opts.reply_to;
        \\    if (opts.cc) body.cc = Array.isArray(opts.cc) ? opts.cc : [opts.cc];
        \\    if (opts.bcc) body.bcc = Array.isArray(opts.bcc) ? opts.bcc : [opts.bcc];
        \\    const env = {
        \\      url: "https://api.resend.com/emails",
        \\      method: "POST",
        \\      headers: {
        \\        "Authorization": "Bearer " + opts.key,
        \\        "Content-Type": "application/json",
        \\      },
        \\      body: JSON.stringify(body),
        \\    };
        \\    if (opts.onResult) env.onResult = opts.onResult;
        \\    if (opts.context !== undefined) env.context = opts.context;
        \\    if (opts.maxAttempts) env.maxAttempts = opts.maxAttempts;
        \\    if (opts.timeout) env.timeout = opts.timeout;
        \\    return webhook.send(env);
        \\  },
        \\};
    ;
    const email_result = c.JS_Eval(
        ctx,
        email_snippet.ptr,
        email_snippet.len,
        "email.js",
        c.JS_EVAL_TYPE_GLOBAL,
    );
    c.JS_FreeValue(ctx, email_result);

    // TextEncoder / TextDecoder — UTF-8 only. QuickJS-ng doesn't
    // expose a native intrinsic for these, so we install a minimal
    // JS polyfill. Sufficient for the common use cases: hashing a
    // UTF-8 string, building a Uint8Array body for webhook.send,
    // decoding a webhook response back to a string. NOT feature-
    // complete — doesn't handle streaming or the replacement
    // character on malformed input; handlers that need fidelity
    // against adversarial input should check their bytes.
    const textcodec_snippet =
        \\(function () {
        \\  class TextEncoder {
        \\    get encoding() { return "utf-8"; }
        \\    encode(input) {
        \\      const s = String(input ?? "");
        \\      const out = [];
        \\      for (let i = 0; i < s.length; i++) {
        \\        let cp = s.charCodeAt(i);
        \\        if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
        \\          const low = s.charCodeAt(i + 1);
        \\          if (low >= 0xdc00 && low <= 0xdfff) {
        \\            cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
        \\            i++;
        \\          }
        \\        }
        \\        if (cp < 0x80) {
        \\          out.push(cp);
        \\        } else if (cp < 0x800) {
        \\          out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
        \\        } else if (cp < 0x10000) {
        \\          out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        \\        } else {
        \\          out.push(
        \\            0xf0 | (cp >> 18),
        \\            0x80 | ((cp >> 12) & 0x3f),
        \\            0x80 | ((cp >> 6) & 0x3f),
        \\            0x80 | (cp & 0x3f),
        \\          );
        \\        }
        \\      }
        \\      return new Uint8Array(out);
        \\    }
        \\  }
        \\  class TextDecoder {
        \\    constructor(label, options) {
        \\      const enc = String(label ?? "utf-8").toLowerCase();
        \\      if (enc !== "utf-8" && enc !== "utf8") {
        \\        throw new RangeError("TextDecoder: only utf-8 is supported");
        \\      }
        \\      this._fatal = !!(options && options.fatal);
        \\    }
        \\    get encoding() { return "utf-8"; }
        \\    decode(buffer) {
        \\      if (buffer === undefined || buffer === null) return "";
        \\      let bytes;
        \\      if (buffer instanceof Uint8Array) {
        \\        bytes = buffer;
        \\      } else if (ArrayBuffer.isView(buffer)) {
        \\        bytes = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
        \\      } else if (buffer instanceof ArrayBuffer) {
        \\        bytes = new Uint8Array(buffer);
        \\      } else {
        \\        throw new TypeError("TextDecoder.decode: expected BufferSource");
        \\      }
        \\      let s = "";
        \\      let i = 0;
        \\      while (i < bytes.length) {
        \\        const b = bytes[i++];
        \\        if (b < 0x80) {
        \\          s += String.fromCharCode(b);
        \\        } else if ((b & 0xe0) === 0xc0 && i < bytes.length) {
        \\          const b2 = bytes[i++];
        \\          s += String.fromCharCode(((b & 0x1f) << 6) | (b2 & 0x3f));
        \\        } else if ((b & 0xf0) === 0xe0 && i + 1 < bytes.length) {
        \\          const b2 = bytes[i++], b3 = bytes[i++];
        \\          s += String.fromCharCode(((b & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f));
        \\        } else if ((b & 0xf8) === 0xf0 && i + 2 < bytes.length) {
        \\          const b2 = bytes[i++], b3 = bytes[i++], b4 = bytes[i++];
        \\          let cp = ((b & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
        \\          cp -= 0x10000;
        \\          s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        \\        } else if (this._fatal) {
        \\          throw new TypeError("TextDecoder: malformed utf-8");
        \\        } else {
        \\          s += "�";
        \\        }
        \\      }
        \\      return s;
        \\    }
        \\  }
        \\  globalThis.TextEncoder = TextEncoder;
        \\  globalThis.TextDecoder = TextDecoder;
        \\})();
    ;
    const textcodec_result = c.JS_Eval(
        ctx,
        textcodec_snippet.ptr,
        textcodec_snippet.len,
        "textcodec.js",
        c.JS_EVAL_TYPE_GLOBAL,
    );
    c.JS_FreeValue(ctx, textcodec_result);

    // platform = { root: { get, set, delete, prefix } }. Installed
    // on every context; the C callbacks check `state.platform` and
    // throw for non-admin handlers. See `jsPlatformRoot*`.
    const platform_obj = c.JS_NewObject(ctx);
    const root_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, root_obj, "get", c.JS_NewCFunction2(ctx, jsPlatformRootGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, root_obj, "set", c.JS_NewCFunction2(ctx, jsPlatformRootSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, root_obj, "delete", c.JS_NewCFunction2(ctx, jsPlatformRootDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, root_obj, "prefix", c.JS_NewCFunction2(ctx, jsPlatformRootPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, platform_obj, "root", root_obj);
    _ = c.JS_SetPropertyStr(ctx, global, "platform", platform_obj);
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

    // request = { method, path, body, query, headers, cookies }
    //
    // `query` is the raw URL query string (everything after `?`) or
    // null when the URL had none. Parsing is the handler's job —
    // QuickJS-ng doesn't ship `URL` / `URLSearchParams`, and a
    // manual `split("&").reduce(...)` is a few lines in the
    // handler. If customer demand for `URLSearchParams` shows up,
    // it can land as another polyfill alongside TextEncoder.
    //
    // `headers` is a flat object, lowercase keys per HTTP/2.
    // Pseudo-headers (`:method`, `:path`, `:scheme`, `:authority`)
    // are filtered out — they're already exposed as `request.method`
    // / `request.path` etc. Multiple headers with the same name
    // comma-join (HTTP-standard fold).
    //
    // `cookies` is a parsed `{name: value}` from the `cookie` header,
    // RFC 6265 semicolon-separated. Empty / no-cookie → `{}`.
    const req_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, req_obj, "method", c.JS_NewStringLen(ctx, request.method.ptr, request.method.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "path", c.JS_NewStringLen(ctx, request.path.ptr, request.path.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "body", c.JS_NewStringLen(ctx, request.body.ptr, request.body.len));
    if (request.query) |q| {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", c.JS_NewStringLen(ctx, q.ptr, q.len));
    } else {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", js_null);
    }
    installHeaders(ctx, state, req_obj, request.headers);
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

/// Build `request.headers` (flat lowercase object, pseudo-headers
/// filtered) and `request.cookies` (parsed from the `cookie:` header)
/// onto `req_obj`. Last-write-wins on duplicate header names — HTTP/2
/// clients SHOULD coalesce duplicates and most do; if a real customer
/// hits a producer that doesn't, we revisit.
fn installHeaders(
    ctx: *c.JSContext,
    state: *DispatchState,
    req_obj: c.JSValue,
    hdrs_opt: ?h2.ReqHeaders,
) void {
    const headers_obj = c.JS_NewObject(ctx);
    const cookies_obj = c.JS_NewObject(ctx);

    var cookie_value: []const u8 = "";

    if (hdrs_opt) |hdrs| if (hdrs.fields) |fields_ptr| {
        const fields = fields_ptr[0..hdrs.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];

            // Skip pseudo-headers (`:method`, `:path`, `:scheme`,
            // `:authority`). They're already exposed as
            // `request.method` / `request.path` etc.
            if (name.len > 0 and name[0] == ':') continue;

            // NUL-terminate name for JS_SetPropertyStr.
            const name_z = state.allocator.allocSentinel(u8, name.len, 0) catch continue;
            defer state.allocator.free(name_z);
            @memcpy(name_z, name);

            _ = c.JS_SetPropertyStr(
                ctx,
                headers_obj,
                name_z.ptr,
                c.JS_NewStringLen(ctx, value.ptr, value.len),
            );

            // Stash the cookie header for parseCookies below. If the
            // wire has multiple Cookie headers (RFC 7230 says clients
            // SHOULD send one) we take the last; this is consistent
            // with the last-write-wins rule above.
            if (std.mem.eql(u8, name, "cookie")) {
                cookie_value = value;
            }
        }
    };

    parseCookies(ctx, state, cookies_obj, cookie_value);

    _ = c.JS_SetPropertyStr(ctx, req_obj, "headers", headers_obj);
    _ = c.JS_SetPropertyStr(ctx, req_obj, "cookies", cookies_obj);
}

/// RFC 6265 cookie-string parser: semicolon-separated `name=value`
/// pairs, optional whitespace around the separator. Sets each into
/// `cookies_obj` as a string property. Empty `cookie_value` → no-op.
fn parseCookies(
    ctx: *c.JSContext,
    state: *DispatchState,
    cookies_obj: c.JSValue,
    cookie_value: []const u8,
) void {
    if (cookie_value.len == 0) return;

    var it = std.mem.splitScalar(u8, cookie_value, ';');
    while (it.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        // Trim whitespace from the value too. RFC 6265 strictly only
        // trims when parsing Set-Cookie, but every practical Cookie
        // parser (browsers, Express, Hono) trims both sides — matches
        // customer expectations.
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (name.len == 0) continue;

        const name_z = state.allocator.allocSentinel(u8, name.len, 0) catch continue;
        defer state.allocator.free(name_z);
        @memcpy(name_z, name);

        _ = c.JS_SetPropertyStr(
            ctx,
            cookies_obj,
            name_z.ptr,
            c.JS_NewStringLen(ctx, value.ptr, value.len),
        );
    }
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
