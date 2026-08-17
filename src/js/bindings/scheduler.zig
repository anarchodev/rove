// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `__rove.wake.set` / `__rove.wake.fire` — the durable-wake
//! engine primitive, gated to baked `__system/` modules (durable-wake
//! P0; `docs/architecture/effects-and-handlers.md`). Registered under the
//! `__rove.*` privileged-ops holder (STATIC_NAMESPACES, globals.zig).
//! These are the ONLY two ops the durable-wake primitive adds;
//! everything else (the queue, ordering, fan-out, backoff) lives in JS
//! (`schedule.js` + `scheduler_tick.mjs`), per durability-as-JS-shim.
//!
//! Both are gated on `state.is_system_module`: they throw for ordinary
//! customer handlers, so only the baked `__system/scheduler_tick`
//! reaches them. That scoping is what closes the clobber footgun — a
//! customer cannot set or fire another tenant's (or their own) raw
//! wake slot; they go through the `scheduler` lib's kv queue.
//!
//! ns timestamps cross the JS↔Zig boundary as **decimal strings**
//! (not BigInt / Number) — the same convention webhook's owed marker
//! uses for `next_at_ns`. Wall-clock ns exceeds 2^53 (lossy as a JS
//! Number) and the BigInt C-API is awkward; a decimal string is exact
//! and trivial to parse both directions.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;

const globals = @import("../globals.zig");
const builtin_modules = @import("../builtin_modules.zig");

const js_undefined = globals.js_undefined;
const js_exception = globals.js_exception;

/// Parse a borrowed decimal-string JS arg into i64. Returns null on a
/// non-string / unparseable value (caller throws a TypeError).
fn argNs(ctx: ?*c.JSContext, v: c.JSValue) ?i64 {
    if (!c.JS_IsString(v)) return null;
    var len: usize = 0;
    const s = c.JS_ToCStringLen(ctx, &len, v);
    if (s == null) return null;
    defer c.JS_FreeCString(ctx, s);
    return std.fmt.parseInt(i64, s[0..len], 10) catch null;
}

/// Borrow a string arg as a slice valid until `JS_FreeCString`. The
/// returned `cstr` MUST be freed by the caller; `slice` aliases it.
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

// ── `__rove_set_wake(whenNsDecimalStr)` ─────────────────────────────

/// Set THIS tenant's single next-fire watermark (absolute ns). `"0"`
/// clears it. Idempotent overwrite — `scheduler_tick` computes the
/// exact min from committed `_sched/by_time` state and calls this with
/// the result; the engine stores it verbatim on the tenant slot.
pub fn jsSetWake(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (!state.is_system_module) {
        _ = c.JS_ThrowTypeError(ctx, "__rove.wake.set is not available to customer code");
        return js_exception;
    }
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "__rove_set_wake(whenNs) requires a decimal-string argument");
        return js_exception;
    }
    const when_ns = argNs(ctx, argv[0]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove_set_wake(whenNs): whenNs must be a decimal string");
        return js_exception;
    };

    // Null trampoline ⇒ test / non-worker dispatch: no slot to set.
    const fn_ptr = state.set_wake orelse return js_undefined;
    const fn_ctx = state.set_wake_ctx orelse return js_undefined;
    fn_ptr(fn_ctx, state.instance_id, when_ns);
    return js_undefined;
}

// ── `__rove_fire_wake(target, id, key, scheduledAtNs, msg, cleanup, armedBy?)` ─

/// Enqueue one `durable_wake` activation for THIS tenant. Called once
/// per due `_sched/by_time` entry by `scheduler_tick`. Args:
///   0 target        — handler target (string): a module path, or the
///                     `"module.method"` form (split in
///                     `fireDurableWakeActivation`)
///   1 id            — scheduler entry id (string)
///   2 key           — idempotency key (string | null)
///   3 scheduledAtNs — absolute fire time, decimal string
///   4 msg           — customer payload, JSON-encoded string ("null" ok)
///   5 cleanupKeys   — array of `_sched/` keys to delete in the
///                     target activation's writeset
///   6 armedBy       — OPTIONAL: the arming saga's id ("" = absent),
///                     provenance for the fired record's `_parent` tag.
///                     Tolerated absent so taped ticks from before the
///                     field replay without divergence.
/// Throws if no worker is registered (a fire is never silently lost).
pub fn jsFireWake(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = globals.getState(ctx);
    if (!state.is_system_module) {
        _ = c.JS_ThrowTypeError(ctx, "__rove.wake.fire is not available to customer code");
        return js_exception;
    }
    if (argc < 6) {
        _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake(target, id, key, scheduledAtNs, msg, cleanupKeys) requires 6 args");
        return js_exception;
    }

    const target = borrowStr(ctx, argv[0]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake: target must be a string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, target.cstr);

    const id = borrowStr(ctx, argv[1]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake: id must be a string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, id.cstr);

    // key is optional (null/undefined ⇒ no idempotency key).
    const key_b: ?Borrowed = borrowStr(ctx, argv[2]);
    defer if (key_b) |k| c.JS_FreeCString(ctx, k.cstr);

    const scheduled_at_ns = argNs(ctx, argv[3]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake: scheduledAtNs must be a decimal string");
        return js_exception;
    };

    const msg_json = borrowStr(ctx, argv[4]) orelse {
        _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake: msg must be a JSON string");
        return js_exception;
    };
    defer c.JS_FreeCString(ctx, msg_json.cstr);

    // cleanupKeys: an array of strings. Borrow each into a parallel
    // pair of slice-list + cstr-list (the cstrs stay alive across the
    // trampoline call; the trampoline dups what it keeps).
    if (!c.JS_IsArray(argv[5])) {
        _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake: cleanupKeys must be an array of strings");
        return js_exception;
    }
    const n_keys: usize = blk: {
        const lv = c.JS_GetPropertyStr(ctx, argv[5], "length");
        defer c.JS_FreeValue(ctx, lv);
        var n: u32 = 0;
        if (c.JS_ToUint32(ctx, &n, lv) < 0) break :blk 0;
        break :blk n;
    };

    const a = state.allocator;
    var cstrs = std.ArrayListUnmanaged([*c]const u8){};
    defer {
        for (cstrs.items) |cs| c.JS_FreeCString(ctx, cs);
        cstrs.deinit(a);
    }
    var slices = std.ArrayListUnmanaged([]const u8){};
    defer slices.deinit(a);

    var i: usize = 0;
    while (i < n_keys) : (i += 1) {
        const ev = c.JS_GetPropertyUint32(ctx, argv[5], @intCast(i));
        defer c.JS_FreeValue(ctx, ev);
        const kb = borrowStr(ctx, ev) orelse {
            _ = c.JS_ThrowTypeError(ctx, "__rove_fire_wake: cleanupKeys entries must be strings");
            return js_exception;
        };
        cstrs.append(a, kb.cstr) catch {
            c.JS_FreeCString(ctx, kb.cstr);
            _ = c.JS_ThrowInternalError(ctx, "__rove_fire_wake: out of memory");
            return js_exception;
        };
        slices.append(a, kb.slice) catch {
            _ = c.JS_ThrowInternalError(ctx, "__rove_fire_wake: out of memory");
            return js_exception;
        };
    }

    // A `_sched/` record names its own target and the prefix is
    // customer-writable by design, so the target is customer input — and
    // `fireDurableWakeActivation` grants `is_system_module` from the module
    // PATH, not from who armed the entry. Two `kv.set` calls would otherwise
    // invoke ANY baked module, as a system module, with a `msg` the tenant
    // chose (rove#495).
    //
    // Refused as a `false` RETURN rather than a throw: this runs inside
    // `__system/scheduler_tick`'s fan-out loop, and a throw would roll the
    // whole tick back — including the `_sched/` deletes of the entries that
    // fired legitimately, which re-fires them next tick, forever. The caller
    // drops the offending entry instead (the same treatment a corrupt record
    // gets), so a refusal ends the chain rather than looping it.
    if (builtin_modules.isBuiltinPath(target.slice) and
        !builtin_modules.isWakeTargetable(target.slice))
    {
        std.log.warn(
            "rove-js: tenant={s} armed a wake at {s} — not a wake-targetable module; entry dropped",
            .{ state.instance_id, target.slice },
        );
        return globals.js_false;
    }

    // Optional arg 6: the arming saga (`_sched/*.armed_by`) for the
    // fired record's `_parent` provenance tag. Tolerant — absent on
    // entries (and taped `scheduler_tick` runs) that predate the field.
    const armed_by_b: ?Borrowed = if (argc >= 7) borrowStr(ctx, argv[6]) else null;
    defer if (armed_by_b) |ab| c.JS_FreeCString(ctx, ab.cstr);

    const input: globals.FireWakeInput = .{
        .tenant_id = state.instance_id,
        .target = target.slice,
        .id = id.slice,
        .key = if (key_b) |k| k.slice else null,
        .scheduled_at_ns = scheduled_at_ns,
        .msg_json = msg_json.slice,
        .cleanup_keys = slices.items,
        .armed_by = if (armed_by_b) |ab| (if (ab.slice.len > 0) ab.slice else null) else null,
    };

    if (state.side_effects_flag) |f| f.* = true;
    const fn_ptr = state.fire_wake orelse {
        // Test / non-worker dispatch: nothing to enqueue. Report false so a
        // caller can detect the no-op; not an error on test paths.
        //
        // `false` therefore means two things — "refused" above, and "no
        // worker" here — and `scheduler_tick` responds to both by dropping
        // the entry. That is deliberate: both say this entry did not
        // dispatch and re-offering it will not change that, so keeping it
        // only re-runs the same decision every tick. No test drives the tick
        // through this path today; if one ever does, it gets a dropped entry
        // rather than a retained one.
        return globals.js_false;
    };
    const fn_ctx = state.fire_wake_ctx orelse return globals.js_false;
    const fired = fn_ptr(fn_ctx, input);
    if (!fired) {
        _ = c.JS_ThrowInternalError(ctx, "__rove_fire_wake: no worker registered to receive the wake");
        return js_exception;
    }
    return globals.js_true;
}
