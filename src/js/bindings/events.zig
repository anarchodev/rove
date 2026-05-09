//! `events.emit` JS binding — writes an SSE event envelope to
//! `_events/{sid}/{seq}` rows in the current handler transaction.
//! The pump (in worker.zig, separate phase) reads those rows and
//! drives connected `EventSource` clients. See docs/sse-plan.md §1.4
//! and §11c.
//!
//! ## Storage shape
//!
//! Key: `_events/{sid}/{request_id:020d}-{call_index:06d}`. Zero-pad
//! both fields so lexical sort = numeric sort, which the pump relies
//! on when paginating after a Last-Event-ID cursor. 20 digits fits
//! any u64; 6 digits fits the per-request emit cap with headroom.
//!
//! Value (JSON):
//! ```
//! {"v":1, "id":"<request_id>-<call_index>", "type":"...", "data":...,
//!  "created_at_ms":..., "parent_request_id":...}
//! ```
//!
//! ## Argument shapes
//!
//! - `events.emit("text")` → current sid, type="message", data="text"
//! - `events.emit({data, type?, to?})`
//!   - `to` defaults to current sid; accepts string or array of strings.
//!   - omitted `data` becomes `null`.
//!   - `type` defaults to "message".
//!
//! Customer-supplied `id` is rejected — id derivation must remain
//! deterministic from `(request_id, call_index)` for tape replay.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const limiter_mod = @import("../limiter.zig");
const sse_dispatch = @import("../sse_dispatch.zig");

const js_undefined = globals.js_undefined;
const js_null = globals.js_null;
const js_exception = globals.js_exception;

/// Width of the request_id segment in the storage key.
const REQUEST_ID_WIDTH: usize = 20;
/// Width of the call_index segment in the storage key.
const CALL_INDEX_WIDTH: usize = 6;
/// Width of the wire id (`{request_id}-{call_index}`).
pub const WIRE_ID_LEN: usize = REQUEST_ID_WIDTH + 1 + CALL_INDEX_WIDTH;

/// Format the wire id into `out` and return it.
fn formatWireId(out: *[WIRE_ID_LEN]u8, request_id: u64, call_index: u32) []const u8 {
    return std.fmt.bufPrint(
        out,
        "{d:0>20}-{d:0>6}",
        .{ request_id, call_index },
    ) catch unreachable;
}

/// Throw `Error{message: "...", code: <code>}` mirroring the existing
/// rate-limited / reserved-key shape so customer JS can branch on
/// `err.code`.
fn throwCoded(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    code: []const u8,
    msg: []const u8,
) c.JSValue {
    _ = state;
    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return err;
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, code.ptr, code.len));
    return c.JS_Throw(ctx, err);
}

/// Pull `to` out of the options object and resolve to a slice of sid
/// strings. Returns null when `to` is absent (caller falls back to
/// current sid). `out_storage` owns the strings; caller calls
/// `freeToList` to release them.
const ToList = struct {
    sids: [][]u8,
    storage: std.ArrayList([]u8),

    fn deinit(self: *ToList, allocator: std.mem.Allocator) void {
        for (self.sids) |s| allocator.free(s);
        self.storage.deinit(allocator);
    }
};

fn parseToList(
    ctx: ?*c.JSContext,
    state: *globals.DispatchState,
    opts: c.JSValue,
) !?ToList {
    const v = c.JS_GetPropertyStr(ctx, opts, "to");
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsUndefined(v) or c.JS_IsNull(v)) return null;

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| state.allocator.free(s);
        list.deinit(state.allocator);
    }

    if (c.JS_IsString(v)) {
        const s = try valueToOwnedString(state.allocator, ctx, v);
        try list.append(state.allocator, s);
    } else if (c.JS_IsArray(v)) {
        const len_v = c.JS_GetPropertyStr(ctx, v, "length");
        defer c.JS_FreeValue(ctx, len_v);
        var len: u32 = 0;
        if (c.JS_ToUint32(ctx, &len, len_v) < 0) return error.JsException;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const item = c.JS_GetPropertyUint32(ctx, v, i);
            defer c.JS_FreeValue(ctx, item);
            if (!c.JS_IsString(item)) return error.NotString;
            const s = try valueToOwnedString(state.allocator, ctx, item);
            try list.append(state.allocator, s);
        }
    } else {
        return error.NotStringOrArray;
    }

    return .{ .sids = list.items, .storage = list };
}

/// Local copy of the helper from globals.zig (private there). Reads
/// a JSValue, decodes as UTF-8, returns an owned slice.
fn valueToOwnedString(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    val: c.JSValue,
) ![]u8 {
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const out = try allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
    return out;
}

/// Validate sid: must be exactly 64 lowercase-hex chars (the
/// `__Host-rove_sid` cookie format from session.zig). Customer-supplied
/// fan-out targets are validated to keep the storage prefix sane and
/// to refuse obviously-wrong values like empty strings.
fn isValidSid(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub fn jsEventsEmit(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "events.emit requires at least one argument");
        return js_exception;
    }

    // Per-instance rate limit on emit calls. One token per call
    // regardless of fan-out cardinality. No-op when limiter is
    // unwired (test paths) — same posture as email.send.
    if (state.limiter) |lim| {
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        const allowed = lim.check(state.instance_id, .events_emit, now_ns) catch true;
        if (!allowed) {
            return throwCoded(ctx, state, "rate_limited",
                "events.emit: per-instance emit rate exceeded");
        }
    }

    // Argument normalization. String form → {data: <s>, type: "message",
    // to: current}. Object form → read data/type/to.
    var type_owned: ?[]u8 = null;
    defer if (type_owned) |t| state.allocator.free(t);
    var to_list: ?ToList = null;
    defer if (to_list) |*tl| tl.deinit(state.allocator);

    var data_json: c.JSValue = js_null;
    defer c.JS_FreeValue(ctx, data_json);

    if (c.JS_IsString(argv[0])) {
        // String form. Wrap the value as a JSON string so the on-wire
        // envelope's `data` field is a JSON string.
        data_json = c.JS_JSONStringify(ctx, argv[0], js_undefined, js_undefined);
        if (c.JS_IsException(data_json)) return js_exception;
    } else if (c.JS_IsObject(argv[0])) {
        const opts = argv[0];

        // `id` is reserved — derived from (request_id, call_index).
        const id_v = c.JS_GetPropertyStr(ctx, opts, "id");
        const id_supplied = !c.JS_IsUndefined(id_v);
        c.JS_FreeValue(ctx, id_v);
        if (id_supplied) {
            return throwCoded(ctx, state, "events_id_reserved",
                "events.emit: `id` is platform-derived, do not supply");
        }

        // type → owned string; default "message"
        const t_v = c.JS_GetPropertyStr(ctx, opts, "type");
        defer c.JS_FreeValue(ctx, t_v);
        if (!c.JS_IsUndefined(t_v) and !c.JS_IsNull(t_v)) {
            if (!c.JS_IsString(t_v)) {
                return throwCoded(ctx, state, "events_bad_arg",
                    "events.emit: `type` must be a string");
            }
            type_owned = valueToOwnedString(state.allocator, ctx, t_v) catch
                return js_exception;
        }

        // data → JSON-stringified
        const d_v = c.JS_GetPropertyStr(ctx, opts, "data");
        defer c.JS_FreeValue(ctx, d_v);
        if (c.JS_IsUndefined(d_v)) {
            // Leave as js_null.
        } else {
            data_json = c.JS_JSONStringify(ctx, d_v, js_undefined, js_undefined);
            if (c.JS_IsException(data_json)) return js_exception;
        }

        // to → list of sids
        to_list = parseToList(ctx, state, opts) catch |err| switch (err) {
            error.NotString, error.NotStringOrArray => return throwCoded(
                ctx, state, "events_bad_arg",
                "events.emit: `to` must be a string or array of strings",
            ),
            error.JsException => return js_exception,
            else => return c.JS_ThrowOutOfMemory(ctx),
        };
    } else {
        _ = c.JS_ThrowTypeError(ctx, "events.emit: argument must be a string or object");
        return js_exception;
    }

    // Resolve target sid list. Implicit-target (no `to:`) routes to
    // the current request's session id; throws when there's no session
    // (callbacks, signup, sim/dry-run).
    const targets: [][]const u8 = blk: {
        if (to_list) |tl| {
            if (tl.sids.len == 0) {
                return throwCoded(ctx, state, "events_bad_arg",
                    "events.emit: `to` must be non-empty");
            }
            // Cast [][]u8 → [][]const u8 via reinterpret. They're
            // bit-identical at the Zig type-system level.
            break :blk @ptrCast(tl.sids);
        }
        if (state.session_id) |*sid| {
            // Single-element borrow into the static `sid` byte slice.
            // Lifetime is OK — state outlives this function.
            const sid_slice: []const u8 = sid;
            const arr = state.allocator.alloc([]const u8, 1) catch
                return c.JS_ThrowOutOfMemory(ctx);
            arr[0] = sid_slice;
            break :blk arr;
        }
        return throwCoded(ctx, state, "no_session",
            "events.emit: no `to:` and request.session is null");
    };
    // Free the implicit-target allocation on exit. The fan-out path's
    // sids are owned by `to_list` and freed via its deinit.
    defer if (to_list == null) state.allocator.free(targets);

    // Validate all sids before any write so a bad sid in position N
    // doesn't leave N-1 events committed.
    for (targets) |sid| {
        if (!isValidSid(sid)) {
            return throwCoded(ctx, state, "events_bad_sid",
                "events.emit: target sid must be 64 lowercase hex chars");
        }
    }

    // Build envelope (JSON). Per emit, not per target — the same
    // envelope bytes get written under each target's prefix.
    var wire_id: [WIRE_ID_LEN]u8 = undefined;
    const wire_id_slice = formatWireId(&wire_id, state.request_id, state.events_call_index);
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    const env = c.JS_NewObject(ctx);
    defer c.JS_FreeValue(ctx, env);
    _ = c.JS_SetPropertyStr(ctx, env, "v", c.JS_NewInt32(ctx, 1));
    _ = c.JS_SetPropertyStr(ctx, env, "id", c.JS_NewStringLen(ctx, wire_id_slice.ptr, wire_id_slice.len));
    if (type_owned) |t| {
        _ = c.JS_SetPropertyStr(ctx, env, "type", c.JS_NewStringLen(ctx, t.ptr, t.len));
    } else {
        _ = c.JS_SetPropertyStr(ctx, env, "type", c.JS_NewStringLen(ctx, "message", "message".len));
    }
    // `data` field. The JS_JSONStringify above produced a JS string
    // holding the JSON; parse it back into an object/value so the
    // outer envelope's stringify embeds it as a value, not as a string.
    if (c.JS_IsNull(data_json)) {
        _ = c.JS_SetPropertyStr(ctx, env, "data", js_null);
    } else {
        var json_len: usize = 0;
        const json_cstr = c.JS_ToCStringLen(ctx, &json_len, data_json);
        if (json_cstr == null) return js_exception;
        const parsed = c.JS_ParseJSON(ctx, json_cstr, json_len, "<data>");
        c.JS_FreeCString(ctx, json_cstr);
        if (c.JS_IsException(parsed)) return js_exception;
        _ = c.JS_SetPropertyStr(ctx, env, "data", parsed);
    }
    _ = c.JS_SetPropertyStr(ctx, env, "created_at_ms", c.JS_NewInt64(ctx, now_ms));
    _ = c.JS_SetPropertyStr(ctx, env, "parent_request_id", c.JS_NewInt64(ctx, @bitCast(state.request_id)));

    // Serialize envelope → bytes.
    const json = c.JS_JSONStringify(ctx, env, js_undefined, js_undefined);
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

    // Write `_events/{sid}/{wire_id}` for each target through the
    // handler's tx + writeset so all events commit (or roll back)
    // atomically with the rest of the handler's kv writes.
    var key_buf: [8 + 64 + 1 + WIRE_ID_LEN]u8 = undefined;
    for (targets) |sid| {
        const key = std.fmt.bufPrint(
            &key_buf,
            "_events/{s}/{s}",
            .{ sid, wire_id_slice },
        ) catch unreachable;

        state.txn.put(key, json_slice) catch |err| {
            state.pending_kv_error = err;
            return js_exception;
        };
        state.writeset.addPut(key, json_slice) catch |err| {
            state.pending_kv_error = err;
            return js_exception;
        };
    }

    // Plan §3 parallel-run path: append to the per-batch emit buffer
    // so the worker's post-raft pump can fire a fire-and-forget POST
    // at sse-server. The legacy kv-row write above stays in place
    // until the worker's `/_events` route is retired (plan §7 step 7).
    if (state.emit_buffer) |buf| {
        appendEmitEntry(state, buf, wire_id_slice, type_owned, json_slice, targets, now_ms) catch |err| {
            state.pending_kv_error = err;
            return js_exception;
        };
    }

    state.events_call_index += 1;
    return c.JS_NewStringLen(ctx, wire_id_slice.ptr, wire_id_slice.len);
}

/// Allocate one `EmitEntry` (owning copies of type/data/targets) and
/// push it onto the per-batch buffer. Errors propagate to the caller,
/// which routes them through `pending_kv_error` like every other
/// fallible kv-side allocation in this binding.
fn appendEmitEntry(
    state: *globals.DispatchState,
    buf: *std.ArrayListUnmanaged(sse_dispatch.EmitEntry),
    wire_id: []const u8,
    type_owned: ?[]u8,
    data_json: []const u8,
    targets: []const []const u8,
    created_at_ms: i64,
) !void {
    const a = state.allocator;
    var entry: sse_dispatch.EmitEntry = undefined;
    @memcpy(&entry.event_id, wire_id[0..sse_dispatch.EVENT_ID_LEN]);
    entry.event_type = if (type_owned) |t| try a.dupe(u8, t) else try a.dupe(u8, "message");
    errdefer a.free(entry.event_type);
    entry.data_json = try a.dupe(u8, data_json);
    errdefer a.free(entry.data_json);
    entry.target_sids = try a.alloc([]u8, targets.len);
    errdefer a.free(entry.target_sids);
    var owned_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < owned_count) : (i += 1) a.free(entry.target_sids[i]);
    }
    for (targets, 0..) |s, i| {
        entry.target_sids[i] = try a.dupe(u8, s);
        owned_count = i + 1;
    }
    entry.created_at_ms = created_at_ms;
    try buf.append(a, entry);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "formatWireId: zero-padded request_id and call_index" {
    var out: [WIRE_ID_LEN]u8 = undefined;
    const s = formatWireId(&out, 0, 0);
    try testing.expectEqualStrings("00000000000000000000-000000", s);
}

test "formatWireId: max u64 request_id, max u32 call_index" {
    var out: [WIRE_ID_LEN]u8 = undefined;
    const s = formatWireId(&out, std.math.maxInt(u64), 1);
    try testing.expectEqualStrings("18446744073709551615-000001", s);
}

test "formatWireId: mid-range" {
    var out: [WIRE_ID_LEN]u8 = undefined;
    const s = formatWireId(&out, 42, 7);
    try testing.expectEqualStrings("00000000000000000042-000007", s);
}

test "isValidSid: 64 lowercase hex" {
    try testing.expect(isValidSid("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
}

test "isValidSid: rejects wrong length" {
    try testing.expect(!isValidSid(""));
    try testing.expect(!isValidSid("abc"));
    try testing.expect(!isValidSid("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde")); // 63
    try testing.expect(!isValidSid("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0")); // 65
}

test "isValidSid: rejects uppercase or non-hex" {
    try testing.expect(!isValidSid("0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"));
    try testing.expect(!isValidSid("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeZ"));
}
