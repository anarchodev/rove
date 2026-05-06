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
const webhook_server = @import("rove-webhook-server");

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

    // Phase 5.5 (d), step 4. When the dispatcher allocated a per-batch
    // `pending_webhooks` accumulator (= worker is in `direct` mode),
    // extract a `WebhookRow` from the env we just built and append.
    // No `_outbox/{id}` write — envelope 4 (the merged batch) rides
    // with envelope 0 (writeset) in a type-7 multi-envelope at batch
    // commit. Drainer-mode falls through to the legacy path below.
    if (state.pending_webhooks) |list| {
        var row = extractRowFromEnv(ctx, state, env, &id_hex) catch |err| {
            c.JS_FreeValue(ctx, env);
            switch (err) {
                error.JsException => return js_exception,
                else => {
                    state.pending_kv_error = err;
                    return js_exception;
                },
            }
        };
        c.JS_FreeValue(ctx, env);
        errdefer row.deinit(state.allocator);
        list.append(state.allocator, row) catch |err| {
            row.deinit(state.allocator);
            state.pending_kv_error = err;
            return js_exception;
        };
        state.webhook_call_index += 1;
        return c.JS_NewStringLen(ctx, &id_hex, 64);
    }

    // Drainer mode (legacy): serialize envelope → bytes → _outbox/{id}.
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

/// Walk the JSON envelope we just built and produce a `WebhookRow`
/// owned by `state.allocator`. All `[]const u8` fields are owned
/// duplicates so the row's `deinit` can free them uniformly. The row
/// shape mirrors what envelope 4 carries on the wire.
fn extractRowFromEnv(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    env: c.JSValue,
    id_hex: *const [64]u8,
) !webhook_server.WebhookRow {
    const a = state.allocator;

    var owned: ExtractedStrings = .{};
    errdefer owned.deinit(a);

    owned.tenant_id = try a.dupe(u8, state.instance_id);
    owned.url = try dupeJsString(ctx, a, env, "url");
    owned.method = try dupeJsString(ctx, a, env, "method");
    owned.body = try dupeJsString(ctx, a, env, "body");
    owned.headers_json = try dupeJsObjectAsJson(ctx, a, env, "headers");
    owned.retry_on_json = try dupeJsObjectAsJson(ctx, a, env, "retry_on");
    owned.context_json = try dupeJsObjectAsJson(ctx, a, env, "context");
    // on_result is null when omitted; store as empty string so the
    // delivery-side apply writes `"on_result": null` in the callback.
    owned.on_result_path = try dupeJsStringOrEmpty(ctx, a, env, "on_result");

    const max_attempts = try getIntField(ctx, env, "max_attempts");
    const timeout_ms = try getIntField(ctx, env, "timeout_ms");

    const row: webhook_server.WebhookRow = .{
        .webhook_id_hex = id_hex.*,
        .tenant_id = owned.tenant_id.?,
        .url = owned.url.?,
        .method = owned.method.?,
        .headers_json = owned.headers_json.?,
        .body = owned.body.?,
        .max_attempts = @intCast(@min(@max(max_attempts, 1), 255)),
        .timeout_ms = @intCast(@max(timeout_ms, 1)),
        .retry_on_json = owned.retry_on_json.?,
        .context_json = owned.context_json.?,
        .on_result_path = owned.on_result_path.?,
        .enqueued_at_ns = @intCast(std.time.nanoTimestamp()),
    };
    owned = .{}; // ownership transferred to row
    return row;
}

const ExtractedStrings = struct {
    tenant_id: ?[]u8 = null,
    url: ?[]u8 = null,
    method: ?[]u8 = null,
    headers_json: ?[]u8 = null,
    body: ?[]u8 = null,
    retry_on_json: ?[]u8 = null,
    context_json: ?[]u8 = null,
    on_result_path: ?[]u8 = null,

    fn deinit(self: *ExtractedStrings, a: std.mem.Allocator) void {
        if (self.tenant_id) |s| a.free(s);
        if (self.url) |s| a.free(s);
        if (self.method) |s| a.free(s);
        if (self.headers_json) |s| a.free(s);
        if (self.body) |s| a.free(s);
        if (self.retry_on_json) |s| a.free(s);
        if (self.context_json) |s| a.free(s);
        if (self.on_result_path) |s| a.free(s);
    }
};

fn dupeJsString(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (!c.JS_IsString(v)) return error.JsException;
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const slice = @as([*]const u8, @ptrCast(cstr))[0..len];
    return try a.dupe(u8, slice);
}

/// Same as `dupeJsString` but returns `""` when the property is null
/// or undefined. Used for `on_result` which is allowed to be missing.
fn dupeJsStringOrEmpty(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsNull(v) or c.JS_IsUndefined(v)) return try a.dupe(u8, "");
    if (!c.JS_IsString(v)) return error.JsException;
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const slice = @as([*]const u8, @ptrCast(cstr))[0..len];
    return try a.dupe(u8, slice);
}

/// JSON.stringify the property and return owned bytes. Used for
/// `headers`, `retry_on`, `context` — all of which envelope 4 carries
/// as opaque JSON-string blobs.
fn dupeJsObjectAsJson(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsNull(v) or c.JS_IsUndefined(v)) return try a.dupe(u8, "null");
    const s = c.JS_JSONStringify(ctx, v, js_undefined, js_undefined);
    if (c.JS_IsException(s) or c.JS_IsUndefined(s)) {
        c.JS_FreeValue(ctx, s);
        return error.JsException;
    }
    defer c.JS_FreeValue(ctx, s);
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, s);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

fn getIntField(ctx: ?*c.JSContext, obj: c.JSValue, name: [:0]const u8) !i32 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    var out: i32 = 0;
    if (c.JS_ToInt32(ctx, &out, v) < 0) return error.JsException;
    return out;
}
