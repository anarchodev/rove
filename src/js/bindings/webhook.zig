//! `webhook.send` JS binding — writes a serialized delivery envelope
//! to `_outbox/{id}` inside the current handler transaction. The
//! outbox drainer (separate thread on the raft leader) picks these up,
//! makes the HTTP call, and enqueues a callback.
//!
//! Id derivation: `sha256(request_id || call_index)` — both pre-minted
//! so the same handler run against the same inputs produces the same
//! ids, which is what replay determinism wants.
//!
//! Also hosts `__rove_check_email_rate`, the hidden builtin called from
//! the email.send JS wrapper before queuing the outbox row. Lives next
//! to webhook because email.send composes on top of webhook.send and
//! shares the rate-limit posture.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_null = globals.js_null;
const js_exception = globals.js_exception;

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

/// Hidden builtin called from the email.send JS wrapper before
/// queuing the outbox row. Throws Error{code:"rate_limited"} when
/// the per-instance email bucket is exhausted; customer can catch
/// in their handler. No-op when the limiter isn't wired (test
/// paths) so dispatcher tests don't need to plumb a limiter through.
pub fn jsCheckEmailRate(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    const lim = state.limiter orelse return js_undefined;
    if (state.instance_id.len == 0) return js_undefined;

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const allowed = lim.check(state.instance_id, .email, now_ns) catch |err| {
        // Lazy bucket creation OOM. Fail open + log — same posture
        // as the worker.zig request-side check.
        std.log.warn("rove-js: limiter.check email for {s} failed: {s} — fail open", .{ state.instance_id, @errorName(err) });
        return js_undefined;
    };
    if (allowed) return js_undefined;

    const retry_after = lim.retryAfterSeconds(state.instance_id, .email);
    const msg = std.fmt.allocPrintSentinel(
        state.allocator,
        "email rate limit exceeded, retry after {d}s",
        .{retry_after},
        0,
    ) catch return c.JS_ThrowOutOfMemory(ctx);
    defer state.allocator.free(msg);

    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return err;
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, "rate_limited", "rate_limited".len));
    return c.JS_Throw(ctx, err);
}

pub fn jsWebhookSend(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
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
