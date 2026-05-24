//! `http.fetch` / `http.cancelFetch` (transient streaming HTTP —
//! `docs/upstream-streaming-plan.md`, Gap 2.3) JS bindings.
//!
//! Phase 5 PR-3 (effect-reification) retired the `http.send` /
//! `http.cancel` durable primitive: durability is now composed in JS
//! by `globals/webhook.js` (kv.set marker → http.fetch → baked
//! `__system/webhook_onresult` shim → optional `__rove_next` to
//! customer `on_result`). The Zig kernel — `send_dispatch.zig` /
//! `send_inflight.zig` / `send_outbox.zig` / `callback_dispatch.zig`
//! — deleted in the same atomic commit (see
//! `docs/effect-reification-plan.md` Phase 5 PR-3 for the locked
//! design).
//!
//!   http.fetch — transient, best-effort, fire-immediately. No
//!     raft involvement; the fetch-pool thread issues libcurl as
//!     soon as the binding accumulates it; no retry on crash. One
//!     callback (`on_chunk`); one knob (`stream: bool`) for
//!     "give me only the first chunk" (default) vs. "deliver
//!     every chunk as it arrives." Phase 5 PR-1 collapsed today's
//!     three patterns (on_chunk / pipe_to / fire-and-forget +
//!     on_done) into this single shape.
//!
//! The customer-facing API:
//!
//!   const fetch_id = http.fetch({
//!     url, method?, headers?, body?, timeout_ms?,
//!     on_chunk,                                       // required
//!     stream?,                                        // default false
//!     max_response_chunk_bytes?, max_total_response_bytes?, ctx?,
//!   });
//!   http.cancelFetch({ id });
//!
//! See the design docs for full semantics. This file is the
//! C-level glue; argument validation + accumulator append + nothing
//! else.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const schedule_server = @import("rove-schedule-server");

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

// ── http.fetch / http.cancelFetch — Gap 2.3 ──────────────────────────────

/// `http.fetch(opts) -> fetch_id` — transient streaming HTTP.
pub fn jsHttpFetch(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.fetch requires an options object");
        return js_exception;
    }
    const opts = argv[0];

    var row = buildFetchRow(ctx, state, opts) catch |err| switch (err) {
        error.JsException => return js_exception,
        else => {
            state.pending_kv_error = err;
            return js_exception;
        },
    };
    state.http_fetch_index += 1;
    // Build the id JS string NOW — `appendPendingFetch` transfers
    // ownership of `row.id` into the PendingFetch and clears the
    // carrier's copy, so reading `row.id` afterward yields an
    // empty slice. `JS_NewStringLen` copies the bytes, so `res`
    // is independent of `row`'s subsequent fate.
    const res = c.JS_NewStringLen(ctx, row.id.ptr, row.id.len);
    // Gap 2.3 Phase C1: accumulate into the per-DispatchState
    // pending-fetches list. The worker's batch-finalize phase
    // flushes the list to NodeState.fetch_pending; the fetch-pool
    // thread (Phase C2) drains that queue and fires libcurl. If
    // the handler throws / faults before flush, DispatchState's
    // deinit frees the entries — no orphan fetches.
    appendPendingFetch(state, &row) catch |err| {
        // Allocator failure on the dupe/append; tear down `row`
        // (still allocator-owned by this fn) + the id string, and
        // surface as a JS exception.
        c.JS_FreeValue(ctx, res);
        row.deinit(state.allocator);
        state.pending_kv_error = err;
        return js_exception;
    };
    // `appendPendingFetch` transferred ownership of every owned
    // slice on `row` into the PendingFetch (or, on the null-
    // accumulator path, left them for this `deinit` to free).
    row.deinit(state.allocator);
    return res;
}

/// Transfer `BuiltFetch`'s owned slices into a `PendingFetch`
/// appended to `state.pending_fetches.*`. Dups `tenant_id` (which
/// `BuiltFetch` doesn't carry — it's implicit on the binding
/// side). On allocator failure, returns OutOfMemory; caller
/// frees the source `row` (the dups that DID succeed get freed
/// by the partial-rollback below).
fn appendPendingFetch(state: *globals.DispatchState, row: *BuiltFetch) !void {
    const a = state.allocator;
    // If the caller didn't provide a fetch accumulator (test
    // paths, anonymous dispatch), the fetch is dropped — the
    // binding still returns an id so the customer's code sees
    // success, but no transport will fire.
    const out = state.pending_fetches orelse return;

    const tid_dup = try a.dupe(u8, state.instance_id);
    errdefer a.free(tid_dup);

    try out.ensureUnusedCapacity(a, 1);
    out.appendAssumeCapacity(.{
        .tenant_id = tid_dup,
        .id = row.id,
        .url = row.url,
        .method = row.method,
        .headers_json = row.headers_json,
        .body = row.body,
        .timeout_ms = row.timeout_ms,
        .on_chunk_module = row.on_chunk_module,
        .ctx_json = row.ctx_json,
        .stream = row.stream,
        .max_response_chunk_bytes = row.max_response_chunk_bytes,
        .max_total_response_bytes = row.max_total_response_bytes,
    });
    // Ownership transferred — clear the carrier's slices so its
    // deinit is a no-op.
    row.id = &.{};
    row.url = &.{};
    row.method = &.{};
    row.headers_json = &.{};
    row.body = &.{};
    row.on_chunk_module = &.{};
    row.ctx_json = &.{};
}

/// `http.cancelFetch({id})` — cancel a not-yet-completed fetch.
pub fn jsHttpCancelFetch(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1 or !c.JS_IsObject(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "http.cancelFetch requires an options object with `id`");
        return js_exception;
    }
    const opts = argv[0];
    const id_v = c.JS_GetPropertyStr(ctx, opts, "id");
    defer c.JS_FreeValue(ctx, id_v);
    if (!c.JS_IsString(id_v)) {
        _ = c.JS_ThrowTypeError(ctx, "http.cancelFetch: `id` must be a string");
        return js_exception;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, id_v);
    if (cstr == null) return js_exception;
    defer c.JS_FreeCString(ctx, cstr);
    if (len == 0 or len > schedule_server.ID_MAX_LEN) {
        _ = c.JS_ThrowRangeError(ctx, "http.cancelFetch: `id` must be 1-256 utf8 bytes");
        return js_exception;
    }
    // Phase B no-op; Phase C wires the actual cancellation onto
    // the fetch-pool's libcurl handle for this id.
    std.log.warn(
        "http.cancelFetch (Phase B): cancel-request accepted for id={s} (transport not yet wired; lands in Gap 2.3 Phase C)",
        .{cstr[0..len]},
    );
    return js_undefined;
}

/// Local carrier for a just-built fetch. `deinit` frees every owned slice.
const BuiltFetch = struct {
    id: []u8,
    url: []u8,
    method: []u8,
    headers_json: []u8,
    body: []u8,
    timeout_ms: u32,
    /// `on_chunk` module path. Required by `buildFetchRow` —
    /// Phase 5 PR-1 dropped `on_done` and `pipe_to` so the
    /// chunk callback is the only path. Allocator-owned.
    on_chunk_module: []u8,
    /// Threaded forward to each activation as `request.ctx`. JSON
    /// string; "null" when omitted.
    ctx_json: []u8,
    /// Phase 5 PR-1: `stream: false` (default) → fire exactly one
    /// `on_chunk` event with `final: true` (up to
    /// `max_response_chunk_bytes` of body; cap-overflow sets
    /// `body_truncated`). `stream: true` → fire one event per
    /// upstream writeback, last carrying `final: true`.
    stream: bool,
    max_response_chunk_bytes: u32,
    max_total_response_bytes: u64,

    fn deinit(self: *BuiltFetch, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.headers_json);
        allocator.free(self.body);
        allocator.free(self.on_chunk_module);
        allocator.free(self.ctx_json);
        self.* = undefined;
    }
};

/// Build + validate the fetch options object → owned `BuiltFetch`.
/// `on_chunk` is required. `stream: bool` (default false) selects
/// single-chunk vs streaming delivery.
fn buildFetchRow(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    opts: c.JSValue,
) !BuiltFetch {
    const a = state.allocator;
    var fetched: FetchExtracted = .{};
    errdefer fetched.deinit(a);

    fetched.id = try deriveFetchIdHex(a, state.request_id, state.http_fetch_index);
    fetched.url = try dupeJsString(ctx, a, opts, "url", null);
    fetched.method = try dupeJsString(ctx, a, opts, "method", "GET");
    fetched.body = try dupeJsString(ctx, a, opts, "body", "");
    fetched.headers_json = try dupeJsObjectAsJson(ctx, a, opts, "headers", "{}");
    fetched.ctx_json = try dupeJsObjectAsJson(ctx, a, opts, "ctx", "null");
    fetched.on_chunk_module = try dupeJsString(ctx, a, opts, "on_chunk", "");

    if (fetched.on_chunk_module.?.len == 0) {
        _ = c.JS_ThrowTypeError(ctx, "http.fetch: `on_chunk` (module path) is required");
        return error.JsException;
    }

    const stream = try getBoolField(ctx, opts, "stream", false);
    const timeout_ms_i32 = try getIntField(ctx, opts, "timeout_ms", 30_000);
    const max_chunk_i32 = try getIntField(ctx, opts, "max_response_chunk_bytes", 256 * 1024);
    const max_total_i64 = try getInt64Field(ctx, opts, "max_total_response_bytes", 50 * 1024 * 1024);

    const row: BuiltFetch = .{
        .id = fetched.id.?,
        .url = fetched.url.?,
        .method = fetched.method.?,
        .headers_json = fetched.headers_json.?,
        .body = fetched.body.?,
        .timeout_ms = @intCast(@max(timeout_ms_i32, 1)),
        .on_chunk_module = fetched.on_chunk_module.?,
        .ctx_json = fetched.ctx_json.?,
        .stream = stream,
        .max_response_chunk_bytes = @intCast(@max(max_chunk_i32, 1)),
        .max_total_response_bytes = if (max_total_i64 < 1) 1 else @intCast(max_total_i64),
    };
    fetched = .{}; // ownership transferred
    return row;
}

const FetchExtracted = struct {
    id: ?[]u8 = null,
    url: ?[]u8 = null,
    method: ?[]u8 = null,
    headers_json: ?[]u8 = null,
    body: ?[]u8 = null,
    ctx_json: ?[]u8 = null,
    on_chunk_module: ?[]u8 = null,

    fn deinit(self: *FetchExtracted, a: std.mem.Allocator) void {
        if (self.id) |s| a.free(s);
        if (self.url) |s| a.free(s);
        if (self.method) |s| a.free(s);
        if (self.headers_json) |s| a.free(s);
        if (self.body) |s| a.free(s);
        if (self.ctx_json) |s| a.free(s);
        if (self.on_chunk_module) |s| a.free(s);
    }
};

/// Hex(sha256(u64-le(request_id) || u32-le("FTCH") || u32-le(fetch_index))).
/// 64 chars; stable per-replay. The "FTCH" tag is the literal
/// string `"FTCH"` (4 ASCII bytes) — a leftover from when
/// `http.send`'s `derivedIdHex` shared the id namespace and the
/// tag was the disambiguator. Kept verbatim now so any in-flight
/// fetch ids that were already deterministic across replay stay
/// stable through the PR-3 cutover.
pub fn deriveFetchIdHex(a: std.mem.Allocator, request_id: u64, fetch_index: u32) ![]u8 {
    var input: [16]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], request_id, .little);
    @memcpy(input[8..12], "FTCH");
    std.mem.writeInt(u32, input[12..16], fetch_index, .little);
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

fn getInt64Field(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [:0]const u8,
    default_val: i64,
) !i64 {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return default_val;
    var out: i64 = 0;
    if (c.JS_ToInt64(ctx, &out, v) < 0) return error.JsException;
    return out;
}

fn getBoolField(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [:0]const u8,
    default_val: bool,
) !bool {
    const v = c.JS_GetPropertyStr(ctx, obj, name.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v)) return default_val;
    const r = c.JS_ToBool(ctx, v);
    if (r < 0) return error.JsException;
    return r != 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "deriveFetchIdHex: stable across calls with same inputs" {
    const a = testing.allocator;
    const f1 = try deriveFetchIdHex(a, 42, 0);
    defer a.free(f1);
    const f2 = try deriveFetchIdHex(a, 42, 0);
    defer a.free(f2);
    try testing.expectEqualStrings(f1, f2);
    try testing.expectEqual(@as(usize, 64), f1.len);

    const f3 = try deriveFetchIdHex(a, 42, 1);
    defer a.free(f3);
    try testing.expect(!std.mem.eql(u8, f1, f3));
}
