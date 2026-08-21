// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `__rove.dispatch` — place a platform action in ANOTHER tenant's scope.
//!
//! The engine half of rove#691's primitive, and deliberately the whole of
//! it: this enqueues one activation and returns. Durability — the owed
//! marker, the watchdog re-fire, the resolve-once — is composed in JS over
//! this one op plus ordinary kv writes, exactly as `webhook.send` composes
//! delivery over one outbound primitive (`docs/decisions.md` §3.3). Registered
//! under the `__rove.*` privileged-ops holder
//! (`docs/architecture/privileged-surface.md`).
//!
//! What it unfuses: *whose code runs* from *whose data it runs against*. An
//! activation dispatched here runs the platform's own baked module on the
//! worker anchoring the TARGET tenant, under that tenant's lease, proposing
//! into that tenant's own raft group — so the write takes a position in that
//! tenant's activation order instead of arriving from another tenant's raft
//! log with no order relative to it.
//!
//! Two gates, and NEITHER is here. Both live at the router funnel beside
//! `isContinuationTargetable`, so a second producer of a dispatch inherits
//! them rather than re-deriving them:
//!
//!   1. only a platform-bound dispatcher may target another scope;
//!   2. only BAKED code may be the target.
//!
//! What IS here is the third gate, and it has to be: `is_system_module`, so
//! customer JS cannot name this op at all. The dispatching tenant's platform
//! grant is read from `state.platform` and carried on the input — from the
//! CALLER's identity, never from the module path. That distinction is
//! rove#643's lesson: dispatch once granted `is_system_module` from the path,
//! so anything a customer could arm inherited the exemption.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const log_mod = @import("rove-log");

const js_exception = globals.js_exception;
const js_false = globals.js_false;
const js_true = globals.js_true;

const Borrowed = struct {
    cstr: [*c]const u8,
    slice: []const u8,
};

fn borrowStr(ctx: ?*c.JSContext, v: c.JSValue) ?Borrowed {
    if (!c.JS_IsString(v)) return null;
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return null;
    return .{ .cstr = s, .slice = @as([*]const u8, @ptrCast(s))[0..len] };
}

/// The three attribution values, as the JS side names them. Spelled out
/// rather than taken as an integer so a caller cannot pass `7` and land on
/// whatever variant that happens to be — and so the vocabulary reads the same
/// in the shim as in the record.
fn actorFromName(name: []const u8) ?log_mod.PlatformActor {
    if (std.mem.eql(u8, name, "tenant_user")) return .tenant_user;
    if (std.mem.eql(u8, name, "operator")) return .operator;
    if (std.mem.eql(u8, name, "system")) return .system;
    return null;
}

/// `__rove.dispatch(targetTenant, modulePath, ctxJson, fnName|null, actor, dispatchId|null)`
///
/// `dispatchId` names the caller's own `_dispatch/owed/{id}` marker, so the
/// target's completion can be reported back and the marker resolved. The
/// ORIGIN tenant is NOT an argument — it is stamped from `state.instance_id`
/// below, because a caller able to name its own origin could aim another
/// tenant's marker at itself.
///
/// Returns true when the activation was enqueued. Throws — rather than
/// returning false — when the op is unavailable or the arguments are wrong,
/// so a caller cannot mistake "refused" for "delivered". A router-side
/// refusal (not platform-bound, non-baked target, no worker) surfaces as
/// false: the call was well-formed and the answer is no.
pub fn jsPlatformDispatch(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (!state.is_system_module) {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch is not available to customer code");
        return js_exception;
    }
    if (argc < 5) {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch(targetTenant, modulePath, ctxJson, fnName, actor, dispatchId) requires 5 args");
        return js_exception;
    }

    const target = borrowStr(ctx, argv[0]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: targetTenant must be a string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, target.cstr);
    if (target.slice.len == 0) {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: targetTenant must be non-empty");
        return js_exception;
    }

    const module = borrowStr(ctx, argv[1]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: modulePath must be a string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, module.cstr);

    const ctx_json = borrowStr(ctx, argv[2]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: ctxJson must be a JSON string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, ctx_json.cstr);

    var fn_name: ?[]const u8 = null;
    var fn_borrow: ?Borrowed = null;
    if (!c.JS_IsNull(argv[3]) and !c.JS_IsUndefined(argv[3])) {
        fn_borrow = borrowStr(ctx, argv[3]) orelse {
            _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: fnName must be a string or null");
            return js_exception;
        };
        if (fn_borrow.?.slice.len > 0) fn_name = fn_borrow.?.slice;
    }
    defer if (fn_borrow) |b| c.JS_FreeCString(ctx, b.cstr);

    const actor_name = borrowStr(ctx, argv[4]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: actor must be a string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, actor_name.cstr);
    const actor = actorFromName(actor_name.slice) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: actor must be one of tenant_user, operator, system");
        return js_exception;
    };

    var did: []const u8 = "";
    var did_borrow: ?Borrowed = null;
    if (argc >= 6 and !c.JS_IsNull(argv[5]) and !c.JS_IsUndefined(argv[5])) {
        did_borrow = borrowStr(ctx, argv[5]) orelse {
            _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch: dispatchId must be a string or null");
            return js_exception;
        };
        did = did_borrow.?.slice;
    }
    defer if (did_borrow) |b| c.JS_FreeCString(ctx, b.cstr);

    const dispatch_fn = state.platform_dispatch orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch is not available on this path");
        return js_exception;
    };
    const fn_ctx = state.worker_ctx orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove.dispatch is not available on this path");
        return js_exception;
    };

    // Authority comes from the DISPATCHING tenant's identity. Read here,
    // decided at the funnel.
    const ok = dispatch_fn(fn_ctx, .{
        .target_tenant = target.slice,
        .module_path = module.slice,
        .ctx_json = ctx_json.slice,
        .fn_name = fn_name,
        .actor = actor,
        // Report back to the tenant this activation is running IN, not to a
        // tenant the caller named. Empty `did` ⇒ no marker ⇒ no report.
        .origin_tenant = if (did.len > 0) state.instance_id else "",
        .dispatch_id = did,
        .dispatcher_is_platform = state.platform != null,
    });
    return if (ok) js_true else js_false;
}

const testing = std.testing;

test "actorFromName: the three attribution values, and nothing else" {
    try testing.expectEqual(log_mod.PlatformActor.tenant_user, actorFromName("tenant_user").?);
    try testing.expectEqual(log_mod.PlatformActor.operator, actorFromName("operator").?);
    try testing.expectEqual(log_mod.PlatformActor.system, actorFromName("system").?);

    // Anything else is refused rather than defaulted. A default would put the
    // wrong answer in the target tenant's log to the question the record
    // exists to answer — was this me, or was this them? — and it would be
    // wrong silently.
    for ([_][]const u8{ "", "Operator", "OPERATOR", "sysadmin", "tenant-user", "admin", "0" }) |bad| {
        try testing.expect(actorFromName(bad) == null);
    }
}

test "actorFromName: every PlatformActor variant has a name" {
    // The vocabulary must be total: a variant the JS side cannot spell is one
    // no shim can ever produce, which reads as a value nobody uses rather
    // than as the gap it is.
    inline for (@typeInfo(log_mod.PlatformActor).@"enum".fields) |f| {
        try testing.expect(actorFromName(f.name) != null);
        try testing.expectEqual(@as(log_mod.PlatformActor, @enumFromInt(f.value)), actorFromName(f.name).?);
    }
}
