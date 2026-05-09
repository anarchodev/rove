//! Hidden builtin `__rove_check_email_rate` called from the email.send
//! JS wrapper before queuing the row. Lives next to (the legacy)
//! webhook bindings for historical reasons; this is the only piece
//! that's still active.
//!
//! The `webhook.send` C binding retired when http.send took over the
//! outbound surface — the customer-facing `webhook.send` is now a JS
//! polyfill on top of `http.send` (`bindings/webhook.js`). This file
//! could be renamed to `email_rate_limit.zig` once we settle on
//! whether email rate limiting belongs alongside its only caller
//! (email.js) or as a standalone module. For now: stays here so the
//! globals.zig namespace registration (`__rove_check_email_rate`)
//! doesn't churn.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

/// Hidden builtin called from the email.send JS wrapper before
/// queuing the schedule row. Throws Error{code:"rate_limited"} when
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
