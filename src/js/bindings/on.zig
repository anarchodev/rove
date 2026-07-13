//! `_system.on` — connection wake triggers (`docs/handler-shape.md`
//! §2.3). `on.timer(ms)` /
//! `on.kv(prefix, {on?})` register a wake **for the current
//! connection**: a body-builder effect (not a return verb) that
//! accumulates onto `DispatchState.pending_wakes` during the
//! activation. At end-of-activation the worker arms the accumulated
//! wakes onto the held entity's `StreamWakes` (timer interval + kv
//! prefixes) so a later kv-write / timer expiry re-invokes the handler
//! while it still holds the socket.
//!
//! Ephemeral + node-local (never touch raft) — the held continuation
//! is the wake's owner by construction, nothing addressable. `on.*` is
//! a **connection** trigger: on a connectionless activation
//! (subscription / durable_wake / test path) the accumulator is null
//! and these calls are inert no-ops, per the model (all `on.*` wakes
//! are for the current connection).
//!
//! `{ on: "module.method" | "method" }` routes the wake to a specific
//! export; the default is `onWake` (the generic "edge wake — go look"
//! export, wired in the kind→export map). The target reuses the
//! continuation `path`/`fn_name` resolution. The key is `on` end to end
//! — the same spelling the customer writes (the `after.js` shim passes
//! opts through; there is no separate wire spelling).

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

const PendingWakeReg = globals.PendingWakeReg;

/// Read the optional `{ on }` selector from an opts object arg. Returns
/// an owned dup or null. On allocation failure returns null (the wake
/// still arms, defaulting to `onWake` — losing a non-default target is
/// preferable to dropping the wake).
fn readOn(state: *globals.DispatchState, ctx: ?*c.JSContext, opts: c.JSValue) ?[]u8 {
    if (!c.JS_IsObject(opts)) return null;
    const tv = c.JS_GetPropertyStr(ctx, opts, "on");
    defer c.JS_FreeValue(ctx, tv);
    if (!c.JS_IsString(tv)) return null;
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, tv);
    if (s == null) return null;
    defer c.JS_FreeCString(ctx, s);
    if (len == 0) return null;
    return state.allocator.dupe(u8, s[0..len]) catch null;
}

/// `on.timer(ms, opts?)` — wake the held connection after `ms`
/// milliseconds. Inert (no-op) when there is no held connection.
pub fn jsOnTimer(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "after.ms(ms) requires a millisecond interval");
        return js_exception;
    }
    var ms: i64 = 0;
    if (c.JS_ToInt64(ctx, &ms, argv[0]) < 0) return js_exception;
    if (ms <= 0) {
        _ = c.JS_ThrowTypeError(ctx, "after.ms(ms): ms must be > 0");
        return js_exception;
    }
    const list = state.pending_wakes orelse return js_undefined; // connectionless ⇒ inert
    const on: ?[]u8 = if (argc >= 2) readOn(state, ctx, argv[1]) else null;
    list.append(state.allocator, .{ .kind = .timer, .interval_ms = ms, .on = on }) catch {
        if (on) |t| state.allocator.free(t);
        _ = c.JS_ThrowInternalError(ctx, "after.ms: out of memory");
        return js_exception;
    };
    return js_undefined;
}

/// `on.kv(prefix, opts?)` — wake the held connection when any key under
/// `prefix` changes since the version this activation read. Inert
/// (no-op) when there is no held connection.
pub fn jsOnKv(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (argc < 1 or !c.JS_IsString(argv[0])) {
        _ = c.JS_ThrowTypeError(ctx, "on.kv(prefix, opts?) requires a string prefix");
        return js_exception;
    }
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (s == null) return js_exception;
    defer c.JS_FreeCString(ctx, s);

    const list = state.pending_wakes orelse return js_undefined; // connectionless ⇒ inert
    const prefix = state.allocator.dupe(u8, s[0..len]) catch {
        _ = c.JS_ThrowInternalError(ctx, "after.kv: out of memory");
        return js_exception;
    };
    const on: ?[]u8 = if (argc >= 2) readOn(state, ctx, argv[1]) else null;
    list.append(state.allocator, .{ .kind = .kv, .prefix = prefix, .on = on }) catch {
        state.allocator.free(prefix);
        if (on) |t| state.allocator.free(t);
        _ = c.JS_ThrowInternalError(ctx, "after.kv: out of memory");
        return js_exception;
    };
    return js_undefined;
}
