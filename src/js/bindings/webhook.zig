//! `webhook.send` JS binding — appends a `WebhookRow` to the
//! dispatcher's per-batch `pending_webhooks` accumulator. The list is
//! proposed as raft envelope 4 inside the type-7 multi-envelope
//! alongside envelope 0 (writeset) at handler-batch commit. The
//! webhook-server thread (Phase 5.5 d, leader-pinned) reads
//! `webhooks.db`, POSTs the customer URL, and proposes envelope 5
//! (complete) or envelope 6 (retry).
//!
//! Id derivation: `sha256(request_id || call_index)` — both pre-minted
//! so the same handler run against the same inputs produces the same
//! ids, which is what replay determinism wants.
//!
//! Also hosts `__rove_check_email_rate`, the hidden builtin called from
//! the email.send JS wrapper before queuing the webhook row. Lives next
//! to webhook because email.send composes on top of webhook.send and
//! shares the rate-limit posture.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const webhook_server = @import("rove-webhook-server");

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

fn computeWebhookId(request_id: u64, call_index: u32, out: *[64]u8) void {
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

/// Hidden builtin called from the email.send JS wrapper before
/// queuing the webhook row. Throws Error{code:"rate_limited"} when
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
    defer c.JS_FreeValue(ctx, url_v);
    if (!c.JS_IsString(url_v)) {
        _ = c.JS_ThrowTypeError(ctx, "webhook.send: `url` must be a string");
        return js_exception;
    }

    var id_hex: [64]u8 = undefined;
    computeWebhookId(state.request_id, state.webhook_call_index, &id_hex);

    const list = state.pending_webhooks orelse {
        // Production paths always allocate the accumulator; the only
        // way to reach here is a Zig-side test that didn't plumb one
        // through. Throw rather than panic so the calling test can
        // surface the misconfiguration cleanly.
        _ = c.JS_ThrowInternalError(ctx, "webhook.send: dispatcher did not allocate pending_webhooks");
        return js_exception;
    };

    var row = buildRow(ctx, state, opts, &id_hex) catch |err| switch (err) {
        error.JsException => return js_exception,
        else => {
            state.pending_kv_error = err;
            return js_exception;
        },
    };
    errdefer row.deinit(state.allocator);
    list.append(state.allocator, row) catch |err| {
        row.deinit(state.allocator);
        state.pending_kv_error = err;
        return js_exception;
    };
    state.webhook_call_index += 1;
    return c.JS_NewStringLen(ctx, &id_hex, 64);
}

/// Pull the public `webhook.send` options into a `WebhookRow` whose
/// `[]const u8` fields are duplicates owned by `state.allocator`. The
/// row is freed uniformly via `WebhookRow.deinit`. Wire-shape mirrors
/// envelope 4. Customer field defaults match PLAN §2.6: `method=POST`,
/// `body=""`, `headers={}`, `maxAttempts=10`, `timeout=30000`,
/// `retryOn=[408,425,429,500,502,503,504,"network"]`, `context=null`,
/// `onResult=null`.
fn buildRow(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    opts: c.JSValue,
    id_hex: *const [64]u8,
) !webhook_server.WebhookRow {
    const a = state.allocator;
    var owned: ExtractedStrings = .{};
    errdefer owned.deinit(a);

    owned.tenant_id = try a.dupe(u8, state.instance_id);
    owned.url = try dupeJsString(ctx, a, opts, "url", null);
    owned.method = try dupeJsString(ctx, a, opts, "method", "POST");
    owned.body = try dupeJsString(ctx, a, opts, "body", "");
    owned.headers_json = try dupeJsObjectAsJson(ctx, a, opts, "headers", "{}");
    owned.retry_on_json = try dupeJsObjectAsJson(
        ctx,
        a,
        opts,
        "retryOn",
        "[408,425,429,500,502,503,504,\"network\"]",
    );
    owned.context_json = try dupeJsObjectAsJson(ctx, a, opts, "context", "null");
    owned.on_result_path = try dupeJsStringOrEmpty(ctx, a, opts, "onResult");

    const max_attempts = try getIntField(ctx, opts, "maxAttempts", 10);
    const timeout_ms = try getIntField(ctx, opts, "timeout", 30_000);

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

/// Read a string property and dupe it. `default_str` is used if the
/// property is undefined; if `null`, undefined → JsException. Anything
/// else non-string → JsException so the customer sees a clear failure.
fn dupeJsString(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
    default_str: ?[]const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) {
        if (default_str) |d| return try a.dupe(u8, d);
        return error.JsException;
    }
    if (!c.JS_IsString(v)) return error.JsException;
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// Returns `""` when the property is null / undefined; otherwise
/// behaves like `dupeJsString`. Used for `onResult`.
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
    return try a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// JSON.stringify the property and return owned bytes. `default_json`
/// is used when the property is undefined.
fn dupeJsObjectAsJson(
    ctx: ?*c.JSContext,
    a: std.mem.Allocator,
    obj: c.JSValue,
    name: [:0]const u8,
    default_json: []const u8,
) ![]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return try a.dupe(u8, default_json);
    if (c.JS_IsNull(v)) return try a.dupe(u8, "null");
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

fn getIntField(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [:0]const u8,
    default_val: i32,
) !i32 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return default_val;
    var out: i32 = 0;
    if (c.JS_ToInt32(ctx, &out, v) < 0) return error.JsException;
    return out;
}
