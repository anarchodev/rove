//! `http.send` / `http.cancel` JS bindings — the platform's outbound
//! HTTP primitive (docs/http-send-plan.md §1). Both bindings
//! accumulate intent onto the dispatcher's per-batch lists; the
//! actual propose-through-raft happens at end-of-batch in
//! `worker_dispatch.finalizeBatch`. By the time the customer
//! handler returns, the row is durably committed cluster-wide
//! (atomic with the customer's kv writeset via the multi-envelope).
//!
//! The customer-facing API:
//!
//!   const id = http.send({
//!     handle?, url, method, headers, body, fire_at_ns?,
//!     on_result?, timeout_ms?, max_body_bytes?,
//!   });
//!
//!   http.cancel({ handle? | id? });
//!
//! See the design doc for full semantics. This file is the C-level
//! glue; argument validation + accumulator append + nothing else.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const schedule_server = @import("rove-schedule-server");

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

pub fn jsHttpSend(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.send requires an options object");
        return js_exception;
    }
    const opts = argv[0];

    const list = state.pending_schedules orelse {
        _ = c.JS_ThrowInternalError(ctx, "http.send: dispatcher did not allocate pending_schedules");
        return js_exception;
    };

    var row = buildRow(ctx, state, opts) catch |err| switch (err) {
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
    state.http_call_index += 1;

    return c.JS_NewStringLen(ctx, row.id.ptr, row.id.len);
}

pub fn jsHttpCancel(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.cancel requires an options object with `handle` or `id`");
        return js_exception;
    }
    const opts = argv[0];

    const list = state.pending_cancels orelse {
        _ = c.JS_ThrowInternalError(ctx, "http.cancel: dispatcher did not allocate pending_cancels");
        return js_exception;
    };

    // `handle` and `id` are equivalent for the cancel API — both
    // resolve to the row id. Customers using a customer-supplied
    // handle pass `handle`; customers holding the value http.send
    // returned (which is just the id) pass `id`. The cancel envelope
    // doesn't care which name they used.
    const id_owned = readHandleOrId(ctx, state.allocator, opts) catch |err| switch (err) {
        error.JsException => return js_exception,
        else => {
            state.pending_kv_error = err;
            return js_exception;
        },
    };
    errdefer state.allocator.free(id_owned);

    const tenant_owned = state.allocator.dupe(u8, state.instance_id) catch {
        state.allocator.free(id_owned);
        state.pending_kv_error = error.OutOfMemory;
        return js_exception;
    };
    errdefer state.allocator.free(tenant_owned);

    const target: schedule_server.CancelTarget = .{
        .tenant_id = tenant_owned,
        .id = id_owned,
    };
    list.append(state.allocator, target) catch {
        state.allocator.free(id_owned);
        state.allocator.free(tenant_owned);
        state.pending_kv_error = error.OutOfMemory;
        return js_exception;
    };
    return js_undefined;
}

// ── Build a ScheduleRow from the JS options object ─────────────────────

fn buildRow(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    opts: c.JSValue,
) !schedule_server.ScheduleRow {
    const a = state.allocator;
    var owned: ExtractedStrings = .{};
    errdefer owned.deinit(a);

    owned.tenant_id = try a.dupe(u8, state.instance_id);
    owned.id = try resolveId(ctx, state, opts);
    owned.url = try dupeJsString(ctx, a, opts, "url", null);
    owned.method = try dupeJsString(ctx, a, opts, "method", "POST");
    owned.body = try dupeJsString(ctx, a, opts, "body", "");
    owned.headers_json = try dupeJsObjectAsJson(ctx, a, opts, "headers", "{}");
    owned.context_json = try dupeJsObjectAsJson(ctx, a, opts, "context", "null");
    owned.on_result_module = try resolveOnResultModule(ctx, a, opts);
    owned.on_result_fn = try resolveOnResultFn(ctx, a, opts);
    owned.on_result_args_json = try resolveOnResultArgs(ctx, a, opts);

    const fire_at_ns_i64 = try resolveFireAtNs(ctx, opts);
    const timeout_ms = try getIntField(ctx, opts, "timeout_ms", 30_000);
    const max_body_bytes = try getIntField(ctx, opts, "max_body_bytes", schedule_server.RESPONSE_BODY_CAP);

    const row: schedule_server.ScheduleRow = .{
        .tenant_id = owned.tenant_id.?,
        .id = owned.id.?,
        .fire_at_ns = fire_at_ns_i64,
        .url = owned.url.?,
        .method = owned.method.?,
        .headers_json = owned.headers_json.?,
        .body = owned.body.?,
        .timeout_ms = @intCast(@max(timeout_ms, 1)),
        .max_body_bytes = @intCast(@max(max_body_bytes, 1)),
        .on_result_module = owned.on_result_module.?,
        .on_result_fn = owned.on_result_fn.?,
        .on_result_args_json = owned.on_result_args_json.?,
        .context_json = owned.context_json.?,
        .is_internal = false, // apply path detects + stamps
    };
    owned = .{}; // ownership transferred
    return row;
}

const ExtractedStrings = struct {
    tenant_id: ?[]u8 = null,
    id: ?[]u8 = null,
    url: ?[]u8 = null,
    method: ?[]u8 = null,
    headers_json: ?[]u8 = null,
    body: ?[]u8 = null,
    on_result_module: ?[]u8 = null,
    on_result_fn: ?[]u8 = null,
    on_result_args_json: ?[]u8 = null,
    context_json: ?[]u8 = null,

    fn deinit(self: *ExtractedStrings, a: std.mem.Allocator) void {
        if (self.tenant_id) |s| a.free(s);
        if (self.id) |s| a.free(s);
        if (self.url) |s| a.free(s);
        if (self.method) |s| a.free(s);
        if (self.headers_json) |s| a.free(s);
        if (self.body) |s| a.free(s);
        if (self.on_result_module) |s| a.free(s);
        if (self.on_result_fn) |s| a.free(s);
        if (self.on_result_args_json) |s| a.free(s);
        if (self.context_json) |s| a.free(s);
    }
};

/// Resolve the row id. Customer-supplied handle (string `handle`
/// field) wins; otherwise derive sha256 hex of `request_id ||
/// http_call_index` so tape replay produces the same id.
fn resolveId(ctx: ?*c.JSContext, state: *globals.DispatchState, opts: c.JSValue) ![]u8 {
    const handle_v = c.JS_GetPropertyStr(ctx, opts, "handle");
    defer c.JS_FreeValue(ctx, handle_v);
    if (!c.JS_IsUndefined(handle_v) and !c.JS_IsNull(handle_v)) {
        if (!c.JS_IsString(handle_v)) {
            _ = c.JS_ThrowTypeError(ctx, "http.send: `handle` must be a string");
            return error.JsException;
        }
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(ctx, &len, handle_v);
        if (cstr == null) return error.JsException;
        defer c.JS_FreeCString(ctx, cstr);
        if (len == 0 or len > schedule_server.ID_MAX_LEN) {
            _ = c.JS_ThrowRangeError(ctx, "http.send: `handle` must be 1-256 utf8 bytes");
            return error.JsException;
        }
        const bytes = @as([*]const u8, @ptrCast(cstr))[0..len];
        for (bytes) |b| if (b == 0) {
            _ = c.JS_ThrowTypeError(ctx, "http.send: `handle` must not contain NUL");
            return error.JsException;
        };
        return state.allocator.dupe(u8, bytes);
    }
    return derivedIdHex(state.allocator, state.request_id, state.http_call_index);
}

/// Hex(sha256(u64-le(request_id) || u32-le(call_index))). 64 chars,
/// stable across tape replays — same shape webhook.send uses.
fn derivedIdHex(a: std.mem.Allocator, request_id: u64, call_index: u32) ![]u8 {
    var input: [12]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], request_id, .little);
    std.mem.writeInt(u32, input[8..12], call_index, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&input, &digest, .{});
    const out = try a.alloc(u8, 64);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

/// `on_result` is `{ tenant?, module, context? }`. We currently only
/// store the module name (cross-tenant routing deferred per
/// docs/http-send-plan.md §13.3); `context` lives on the row's
/// `context_json` slot via `dupeJsObjectAsJson` above. Returns "" if
/// the customer omitted on_result entirely (fire-and-forget).
fn resolveOnResultModule(ctx: ?*c.JSContext, a: std.mem.Allocator, opts: c.JSValue) ![]u8 {
    const on_result = c.JS_GetPropertyStr(ctx, opts, "on_result");
    defer c.JS_FreeValue(ctx, on_result);
    if (c.JS_IsUndefined(on_result) or c.JS_IsNull(on_result)) {
        return a.dupe(u8, "");
    }
    if (!c.JS_IsObject(on_result)) {
        _ = c.JS_ThrowTypeError(ctx, "http.send: `on_result` must be an object");
        return error.JsException;
    }
    const module_v = c.JS_GetPropertyStr(ctx, on_result, "module");
    defer c.JS_FreeValue(ctx, module_v);
    if (!c.JS_IsString(module_v)) {
        _ = c.JS_ThrowTypeError(ctx, "http.send: `on_result.module` must be a string");
        return error.JsException;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, module_v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// `on_result.fn` is optional. Empty string = use the dispatcher's
/// default (`?fn=`) → calls the module's `default` export. When set,
/// the synthesized callback request gets `?fn={on_result_fn}`.
fn resolveOnResultFn(ctx: ?*c.JSContext, a: std.mem.Allocator, opts: c.JSValue) ![]u8 {
    const on_result = c.JS_GetPropertyStr(ctx, opts, "on_result");
    defer c.JS_FreeValue(ctx, on_result);
    if (c.JS_IsUndefined(on_result) or c.JS_IsNull(on_result)) return a.dupe(u8, "");
    if (!c.JS_IsObject(on_result)) return a.dupe(u8, "");
    const fn_v = c.JS_GetPropertyStr(ctx, on_result, "fn");
    defer c.JS_FreeValue(ctx, fn_v);
    if (c.JS_IsUndefined(fn_v) or c.JS_IsNull(fn_v)) return a.dupe(u8, "");
    if (!c.JS_IsString(fn_v)) {
        _ = c.JS_ThrowTypeError(ctx, "http.send: `on_result.fn` must be a string");
        return error.JsException;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, fn_v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// `on_result.args` is optional. JSON-stringified positional args
/// to pass to `on_result.fn`. Empty / omitted = no args. Validated
/// to be a JS array; non-array throws TypeError.
fn resolveOnResultArgs(ctx: ?*c.JSContext, a: std.mem.Allocator, opts: c.JSValue) ![]u8 {
    const on_result = c.JS_GetPropertyStr(ctx, opts, "on_result");
    defer c.JS_FreeValue(ctx, on_result);
    if (c.JS_IsUndefined(on_result) or c.JS_IsNull(on_result)) return a.dupe(u8, "");
    if (!c.JS_IsObject(on_result)) return a.dupe(u8, "");
    const args_v = c.JS_GetPropertyStr(ctx, on_result, "args");
    defer c.JS_FreeValue(ctx, args_v);
    if (c.JS_IsUndefined(args_v) or c.JS_IsNull(args_v)) return a.dupe(u8, "");
    if (!c.JS_IsArray(args_v)) {
        _ = c.JS_ThrowTypeError(ctx, "http.send: `on_result.args` must be an array");
        return error.JsException;
    }
    const s = c.JS_JSONStringify(ctx, args_v, js_undefined, js_undefined);
    if (c.JS_IsException(s) or c.JS_IsUndefined(s)) {
        c.JS_FreeValue(ctx, s);
        return error.JsException;
    }
    defer c.JS_FreeValue(ctx, s);
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, s);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    return a.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

/// `fire_at_ns` is optional. null / undefined = fire ASAP (0).
/// Number is treated as ns (matches BigInt's coercion to f64 for
/// values in safe-integer range; bigger values stay BigInt-only —
/// see the comment below).
fn resolveFireAtNs(ctx: ?*c.JSContext, opts: c.JSValue) !i64 {
    const v = c.JS_GetPropertyStr(ctx, opts, "fire_at_ns");
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v)) return 0;

    // BigInt path: customer code that does the math correctly.
    if (c.JS_IsBigInt(v)) {
        var out: i64 = 0;
        if (c.JS_ToBigInt64(ctx, &out, v) < 0) return error.JsException;
        return out;
    }
    // Number path: convertible to i64. We accept floats (truncate)
    // because JS Date.now() * 1_000_000 is the natural construction
    // and lands at a safe-integer-range float for plausible dates.
    var as_i64: i64 = 0;
    if (c.JS_ToInt64Ext(ctx, &as_i64, v) < 0) return error.JsException;
    return as_i64;
}

fn readHandleOrId(ctx: ?*c.JSContext, a: std.mem.Allocator, opts: c.JSValue) ![]u8 {
    // Try `handle` first.
    var v = c.JS_GetPropertyStr(ctx, opts, "handle");
    const have_handle = !(c.JS_IsUndefined(v) or c.JS_IsNull(v));
    if (have_handle and !c.JS_IsString(v)) {
        c.JS_FreeValue(ctx, v);
        _ = c.JS_ThrowTypeError(ctx, "http.cancel: `handle` must be a string");
        return error.JsException;
    }
    if (!have_handle) {
        c.JS_FreeValue(ctx, v);
        v = c.JS_GetPropertyStr(ctx, opts, "id");
        if (c.JS_IsUndefined(v) or c.JS_IsNull(v)) {
            c.JS_FreeValue(ctx, v);
            _ = c.JS_ThrowTypeError(ctx, "http.cancel: requires `handle` or `id` field");
            return error.JsException;
        }
        if (!c.JS_IsString(v)) {
            c.JS_FreeValue(ctx, v);
            _ = c.JS_ThrowTypeError(ctx, "http.cancel: `id` must be a string");
            return error.JsException;
        }
    }
    defer c.JS_FreeValue(ctx, v);
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, v);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    if (len == 0 or len > schedule_server.ID_MAX_LEN) {
        _ = c.JS_ThrowRangeError(ctx, "http.cancel: id must be 1-256 utf8 bytes");
        return error.JsException;
    }
    const bytes = @as([*]const u8, @ptrCast(cstr))[0..len];
    for (bytes) |b| if (b == 0) {
        _ = c.JS_ThrowTypeError(ctx, "http.cancel: id must not contain NUL");
        return error.JsException;
    };
    return a.dupe(u8, bytes);
}

// ── Generic JS-property extraction helpers ─────────────────────────────

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

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "derivedIdHex: stable across calls with same inputs" {
    const a = testing.allocator;
    const id1 = try derivedIdHex(a, 42, 0);
    defer a.free(id1);
    const id2 = try derivedIdHex(a, 42, 0);
    defer a.free(id2);
    try testing.expectEqualStrings(id1, id2);
    try testing.expectEqual(@as(usize, 64), id1.len);
    for (id1) |b| try testing.expect((b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'));
}

test "derivedIdHex: differs across call indices" {
    const a = testing.allocator;
    const id_a = try derivedIdHex(a, 42, 0);
    defer a.free(id_a);
    const id_b = try derivedIdHex(a, 42, 1);
    defer a.free(id_b);
    try testing.expect(!std.mem.eql(u8, id_a, id_b));
}

test "derivedIdHex: differs across request ids" {
    const a = testing.allocator;
    const id_a = try derivedIdHex(a, 42, 0);
    defer a.free(id_a);
    const id_b = try derivedIdHex(a, 43, 0);
    defer a.free(id_b);
    try testing.expect(!std.mem.eql(u8, id_a, id_b));
}
