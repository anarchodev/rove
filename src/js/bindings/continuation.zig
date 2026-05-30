//! `_system.next` — the trampoline continuation primitive
//! (connection-actor §6.1/§6.4, the unified return-as-continuation
//! model). A handler returns `next(path, { fn?, ctx? })` instead of a
//! response value to mean "I am not done — invoke this module next."
//! Returning a normal value stays terminal, exactly as today; the
//! trampoline only engages when a continuation is returned.
//!
//! A continuation is a *returned value*, not an effect: `next` is a
//! pure constructor of a branded descriptor, no DispatchState
//! mutation, no tape. Detection happens when the handler's return
//! value is classified (`tryExtract`) — consistent with "treat my
//! return value as the data" and replay-clean (the descriptor is the
//! taped output; the next hop is a fresh pure invocation).
//!
//! There is deliberately NO connection handle in this surface
//! (project-connection-actor-unified-trigger): the continuation IS
//! the connection's next step by construction; nothing is addressable.
//!
//! The brand is a per-process random nonce. Its only job is to stop a
//! customer object that *accidentally* looks like a continuation from
//! being misclassified — a customer *deliberately* shaping one just
//! makes their own request a continuation in their own tenant, which
//! is exactly what calling `next` does. So accidental-collision
//! resistance is sufficient; the nonce makes it certain at ~zero cost.

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

const BRAND_PROP = "__rove_cont";

// ── The continuation descriptor (Zig side) ─────────────────────────

/// Extracted from a handler's `next(...)` return value. Owned by the
/// allocator passed to `tryExtract`; `deinit` frees it.
pub const Continuation = struct {
    /// Module path the next hop dispatches to (e.g. "handlers/login").
    path: []u8,
    /// Named export to invoke, or null → the module's default export.
    /// Mirrors the existing request contract (`?fn=` / RPC envelope vs
    /// default export); a continuation is resolved through the SAME
    /// dispatch path a request is — it is not a new calling
    /// convention.
    fn_name: ?[]u8,
    /// The author's `ctx`, JSON-serialized. The runtime later forms
    /// the next hop's request body as ctx + the injected effect
    /// outcome (Phase 3b-iii); 3b-i only captures it.
    ctx_json: []u8,

    pub fn deinit(self: *Continuation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.fn_name) |f| allocator.free(f);
        allocator.free(self.ctx_json);
    }
};

// ── `_system.next(path, opts?)` ────────────────────────────────────

pub fn jsNext(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "next(path, { fn?, ctx? }) requires a string path");
        return js_exception;
    }

    const obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(obj)) return js_exception;

    // Brand (consumed by JS_SetPropertyStr).
    const b = brand();
    _ = c.JS_SetPropertyStr(ctx, obj, BRAND_PROP, c.JS_NewStringLen(ctx, b.ptr, b.len));
    // path — dup argv[0]; SetPropertyStr steals the ref.
    _ = c.JS_SetPropertyStr(ctx, obj, "path", c.JS_DupValue(ctx, argv[0]));

    if (argc >= 2 and c.JS_IsObject(argv[1])) {
        const opts = argv[1];

        const fn_v = c.JS_GetPropertyStr(ctx, opts, "fn");
        if (c.JS_IsString(fn_v)) {
            _ = c.JS_SetPropertyStr(ctx, obj, "fn", fn_v); // steals ref
        } else {
            c.JS_FreeValue(ctx, fn_v);
        }

        const ctx_v = c.JS_GetPropertyStr(ctx, opts, "ctx");
        defer c.JS_FreeValue(ctx, ctx_v);
        const ctx_json = c.JS_JSONStringify(ctx, ctx_v, js_undefined, js_undefined);
        if (c.JS_IsException(ctx_json) or c.JS_IsUndefined(ctx_json)) {
            c.JS_FreeValue(ctx, ctx_json);
            _ = c.JS_SetPropertyStr(ctx, obj, "ctx", c.JS_NewStringLen(ctx, "null", 4));
        } else {
            _ = c.JS_SetPropertyStr(ctx, obj, "ctx", ctx_json); // steals ref
        }
    } else {
        _ = c.JS_SetPropertyStr(ctx, obj, "ctx", c.JS_NewStringLen(ctx, "null", 4));
    }

    return obj;
}

// ── Classify a handler return value ────────────────────────────────

/// Return a `Continuation` iff `val` is a branded `next(...)`
/// descriptor; otherwise null (the value is an ordinary terminal
/// response and the existing body path handles it verbatim). Only
/// OOM propagates — a malformed/forged-looking object is simply "not
/// a continuation", never an error (no oracle, no surprise).
pub fn tryExtract(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    val: c.JSValue,
) error{OutOfMemory}!?Continuation {
    if (!c.JS_IsObject(val)) return null;

    const bv = c.JS_GetPropertyStr(ctx, val, BRAND_PROP);
    defer c.JS_FreeValue(ctx, bv);
    if (!c.JS_IsString(bv)) return null;
    if (!jsStrEql(ctx, bv, brand())) return null;

    const path = (try ownedJsStr(allocator, ctx, val, "path")) orelse return null;
    errdefer allocator.free(path);
    const fn_name = try ownedJsStr(allocator, ctx, val, "fn"); // optional
    errdefer if (fn_name) |f| allocator.free(f);
    const ctx_json = (try ownedJsStr(allocator, ctx, val, "ctx")) orelse
        try allocator.dupe(u8, "null");

    return .{ .path = path, .fn_name = fn_name, .ctx_json = ctx_json };
}

fn jsStrEql(ctx: ?*c.JSContext, v: c.JSValue, want: []const u8) bool {
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return false;
    defer c.JS_FreeCString(ctx, s);
    return std.mem.eql(u8, s[0..len], want);
}

/// Read `obj[prop]` as an owned UTF-8 copy; null if absent/not-string.
fn ownedJsStr(
    allocator: std.mem.Allocator,
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    prop: [:0]const u8,
) error{OutOfMemory}!?[]u8 {
    const v = c.JS_GetPropertyStr(ctx, obj, prop.ptr);
    defer c.JS_FreeValue(ctx, v);
    if (!c.JS_IsString(v)) return null;
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return error.OutOfMemory;
    defer c.JS_FreeCString(ctx, s);
    return try allocator.dupe(u8, s[0..len]);
}

test "BENCH tryExtract per-request hot-path tax (ROVE_BENCH=1)" {
    // Suspect #1: `tryExtract` runs on EVERY handler return. Baseline
    // cost is zero (it didn't exist), so its ns/op on a representative
    // JSON-return object IS the per-request tax. Contextualized vs the
    // `JS_JSONStringify` every object-returning handler already pays.
    if (std.posix.getenv("ROVE_BENCH") == null) return error.SkipZigTest;
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Representative non-continuation response object.
    const obj = c.JS_NewObject(ctx.raw);
    defer c.JS_FreeValue(ctx.raw, obj);
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "id", c.JS_NewInt32(ctx.raw, 42));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "name", c.JS_NewStringLen(ctx.raw, "rove", 4));
    _ = c.JS_SetPropertyStr(ctx.raw, obj, "ok", c.JS_NewInt32(ctx.raw, 1));

    const N: usize = 2_000_000;

    var t1 = try std.time.Timer.start();
    var sink: usize = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const r = try tryExtract(std.testing.allocator, ctx.raw, obj);
        if (r) |rr| {
            var m = rr;
            m.deinit(std.testing.allocator);
            sink += 1;
        }
    }
    const extract_ns = t1.read() / N;

    var t2 = try std.time.Timer.start();
    i = 0;
    while (i < N) : (i += 1) {
        const j = c.JS_JSONStringify(ctx.raw, obj, js_undefined, js_undefined);
        c.JS_FreeValue(ctx.raw, j);
    }
    const stringify_ns = t2.read() / N;

    std.debug.print(
        "\n[BENCH] tryExtract={d} ns/op  JS_JSONStringify(same obj)={d} ns/op  " ++
            "added-tax≈{d}% of the stringify already paid per object return (sink={d})\n",
        .{ extract_ns, stringify_ns, if (stringify_ns > 0) extract_ns * 100 / stringify_ns else 0, sink },
    );
}

// ── `_system.continuation.resumeIfBound(send_id, event_json)` ──────
//
// Phase 5 PR-3: the §6.4 held-sync resume hook from the JS shim.
// The `__system/webhook_onresult` baked module calls this on
// terminal — if any parked continuation on this worker has
// `bound_schedule_id == send_id`, the call dispatches a
// `resumeContinuation` with `outcome_json = event_json`. Returns
// `true` when it matched (caller skips its own __rove_next chain);
// `false` for the ordinary webhook path (no held-sync open hop).
//
// Tenant scoping: every parked-continuation entity carries its
// tenant_id in `ChainContext`; the lookup matches both tenant_id
// (from DispatchState.instance_id) AND send_id. No cross-tenant
// resume is possible from a JS-level call.

pub fn jsContinuationResumeIfBound(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 2 or !c.JS_IsString(argv[0]) or !c.JS_IsString(argv[1])) {
        _ = c.JS_ThrowTypeError(
            ctx,
            "_system.continuation.resumeIfBound(send_id, event_json) requires two strings",
        );
        return js_exception;
    }
    // Read both strings without owning copies — `resumeBoundContinuation`
    // is called synchronously here and dups internally.
    var id_len: usize = 0;
    const id_cstr = c.JS_ToCStringLen(ctx, &id_len, argv[0]);
    if (id_cstr == null) return js_exception;
    defer c.JS_FreeCString(ctx, id_cstr);
    const send_id = @as([*]const u8, @ptrCast(id_cstr))[0..id_len];

    var ev_len: usize = 0;
    const ev_cstr = c.JS_ToCStringLen(ctx, &ev_len, argv[1]);
    if (ev_cstr == null) return js_exception;
    defer c.JS_FreeCString(ctx, ev_cstr);
    const event_json = @as([*]const u8, @ptrCast(ev_cstr))[0..ev_len];

    // The DispatchState carries a worker trampoline when the dispatch
    // is hosted by a real worker (production path). On test /
    // anonymous paths the field is null — the call is a no-op (returns
    // false), matching the "no parked continuations to match" outcome.
    const fn_ptr = state.resume_if_bound orelse return globals.js_false;
    const fn_ctx = state.resume_if_bound_ctx orelse return globals.js_false;
    const matched = fn_ptr(fn_ctx, state.instance_id, send_id, event_json);
    return if (matched) globals.js_true else globals.js_false;
}

test "brand is stable within a process and 32 hex chars" {
    const a = brand();
    const b = brand();
    try std.testing.expectEqual(@as(usize, 32), a.len);
    try std.testing.expectEqualSlices(u8, a, b);
    for (a) |ch| try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
}
