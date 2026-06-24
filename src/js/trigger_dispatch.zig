//! Trigger fire path (PLAN §2.5).
//!
//! Customer code under `_triggers/{prefix}/index.{mjs,js}` registers
//! BEFORE/AFTER hooks for `kv.set`/`kv.delete` operations matching
//! the prefix. This module orchestrates those hooks: chain iteration
//! (outermost-first for BEFORE, innermost-first for AFTER), the qjs
//! handler lookup + invocation, savepoint rollback on rejection, and
//! conversion of customer exceptions into `Error{code:"trigger_rejected"}`.
//!
//! The public surface is what `jsKvSet` / `jsKvDelete` need:
//!   - `anyTriggerMatches` — cheap probe to skip the slow path.
//!   - `runBeforeChain` / `runAfterChain` — full chain execution.
//!   - `rollbackInnerSavepoint` — savepoint cleanup on the reject path.
//!   - `rethrowAsTriggerRejected` — convert ctx exception to typed error.
//!   - `TriggerOp` — passed by callers to label the operation.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const log_mod = @import("rove-log");

const globals = @import("globals.zig");

const DispatchState = globals.DispatchState;
const TriggerEntry = globals.TriggerEntry;
const MAX_TRIGGER_DEPTH = globals.MAX_TRIGGER_DEPTH;
const js_undefined = globals.js_undefined;
const js_null = globals.js_null;

/// Platform-owned prefixes whose writes never fire customer triggers,
/// even when a catch-all trigger is registered. Keeps customer code
/// from observing (or stalling) internal infrastructure writes.
///
/// If a kv key under a customer's catch-all trigger happens to
/// start with one of these, we silently skip trigger dispatch.
const PLATFORM_KV_PREFIXES_FIRE = [_][]const u8{
    "_audit/",
    "_deploy/",
    "_callback/",
    "_magic/",
    "_triggers/",
    "_sessions/",
};

fn isPlatformKey(key: []const u8) bool {
    for (PLATFORM_KV_PREFIXES_FIRE) |p| {
        if (std.mem.startsWith(u8, key, p)) return true;
    }
    return false;
}

pub const TriggerOp = enum { put, delete };

/// Load the trigger module's namespace into the qjs context, caching
/// it on `state.trigger_module_ns` so subsequent fires within the
/// same request share the same namespace (so module top-level state
/// like `let count = 0` persists across fires within one request).
/// Returns `null` on any failure (missing bytecode, malformed module,
/// init exception); the caller logs and skips the trigger.
fn loadTriggerModuleNs(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    module_path: []const u8,
) ?c.JSValue {
    if (state.trigger_module_ns.get(module_path)) |cached| {
        return c.JS_DupValue(ctx, cached);
    }

    const map = state.bytecodes orelse return null;
    const bb = map.get(module_path) orelse return null;

    const obj = c.JS_ReadObject(ctx, bb.bytes.ptr, bb.bytes.len, c.JS_READ_OBJ_BYTECODE);
    if (c.JS_IsException(obj)) {
        _ = c.JS_GetException(ctx); // discard
        return null;
    }
    if (obj.tag != c.JS_TAG_MODULE) {
        c.JS_FreeValue(ctx, obj);
        return null;
    }
    const mod_def: ?*c.JSModuleDef = @ptrCast(@alignCast(obj.u.ptr));

    // JS_EvalFunction consumes `obj` and runs the module's
    // top-level code. For sync modules this returns a resolved
    // promise; we don't pump jobs (triggers should be sync) — top-
    // level await would break the deterministic execution model.
    const eval_result = c.JS_EvalFunction(ctx, obj);
    if (c.JS_IsException(eval_result)) {
        _ = c.JS_GetException(ctx); // discard — caller logs
        return null;
    }
    c.JS_FreeValue(ctx, eval_result);

    const ns = c.JS_GetModuleNamespace(ctx, mod_def);
    if (c.JS_IsException(ns)) {
        _ = c.JS_GetException(ctx);
        return null;
    }

    const key_copy = state.allocator.dupe(u8, module_path) catch {
        c.JS_FreeValue(ctx, ns);
        return null;
    };
    // Cache holds one ref; we return a duped ref to the caller.
    state.trigger_module_ns.put(state.allocator, key_copy, ns) catch {
        state.allocator.free(key_copy);
        c.JS_FreeValue(ctx, ns);
        return null;
    };
    return c.JS_DupValue(ctx, ns);
}

/// Build the event object passed as the trigger handler's argument.
/// Shape (PLAN §2.5):
///   { key, value, previousValue, op, timing, timestamp,
///     actor: { request_id } | null, depth }
fn buildTriggerEvent(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    key: []const u8,
    op: TriggerOp,
    timing: []const u8,
    new_value: ?[]const u8,
    prev_value: ?[]const u8,
) c.JSValue {
    const event = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, event, "key", c.JS_NewStringLen(ctx, key.ptr, key.len));

    if (new_value) |v| {
        _ = c.JS_SetPropertyStr(ctx, event, "value", c.JS_NewStringLen(ctx, v.ptr, v.len));
    } else {
        _ = c.JS_SetPropertyStr(ctx, event, "value", js_null);
    }

    if (prev_value) |v| {
        _ = c.JS_SetPropertyStr(ctx, event, "previousValue", c.JS_NewStringLen(ctx, v.ptr, v.len));
    } else {
        _ = c.JS_SetPropertyStr(ctx, event, "previousValue", js_null);
    }

    const op_str: []const u8 = switch (op) {
        .put => "put",
        .delete => "delete",
    };
    _ = c.JS_SetPropertyStr(ctx, event, "op", c.JS_NewStringLen(ctx, op_str.ptr, op_str.len));
    _ = c.JS_SetPropertyStr(ctx, event, "timing", c.JS_NewStringLen(ctx, timing.ptr, timing.len));

    const ts_ms: f64 = @floatFromInt(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_ms));
    _ = c.JS_SetPropertyStr(ctx, event, "timestamp", c.JS_NewFloat64(ctx, ts_ms));

    if (state.request_id != 0) {
        const actor = c.JS_NewObject(ctx);
        // Customer-visible: opaque `req_<16hex>` prefixed form, never the
        // bare integer (format-versioning-audit.md §7.5).
        var rid_buf: [log_mod.PREFIXED_ID_BUF]u8 = undefined;
        const rid = log_mod.formatPrefixedId(&rid_buf, log_mod.REQUEST_ID_PREFIX, state.request_id);
        _ = c.JS_SetPropertyStr(ctx, actor, "request_id", c.JS_NewStringLen(ctx, rid.ptr, rid.len));
        _ = c.JS_SetPropertyStr(ctx, event, "actor", actor);
    } else {
        _ = c.JS_SetPropertyStr(ctx, event, "actor", js_null);
    }

    _ = c.JS_SetPropertyStr(ctx, event, "depth", c.JS_NewInt32(ctx, @intCast(state.trigger_depth)));
    return event;
}

/// Pick the right named export for `(op, timing)`, falling back to
/// `default` if the named export isn't a function. Returns the
/// JS function value (caller must `JS_FreeValue`) or `js_undefined`
/// if no callable export matches.
fn lookupTriggerHandler(
    ctx: ?*c.JSContext,
    ns: c.JSValue,
    op: TriggerOp,
    timing: []const u8,
) c.JSValue {
    const named: [:0]const u8 = switch (op) {
        .put => if (std.mem.eql(u8, timing, "before")) "beforePut" else "afterPut",
        .delete => if (std.mem.eql(u8, timing, "before")) "beforeDelete" else "afterDelete",
    };

    const named_fn = c.JS_GetPropertyStr(ctx, ns, named.ptr);
    if (c.JS_IsFunction(ctx, named_fn)) return named_fn;
    c.JS_FreeValue(ctx, named_fn);

    const default_fn = c.JS_GetPropertyStr(ctx, ns, "default");
    if (c.JS_IsFunction(ctx, default_fn)) return default_fn;
    c.JS_FreeValue(ctx, default_fn);

    return js_undefined;
}

/// Cheap probe used by `kv.set` / `kv.delete` to decide whether
/// to pay the previousValue lookup cost. Walks the registry, returns
/// true on the first prefix match. No qjs interaction. Returns false
/// for platform keys (matches the fire-time guard's behavior so we
/// don't pay the lookup for traffic that won't fire triggers anyway).
pub fn anyTriggerMatches(state: *DispatchState, key: []const u8) bool {
    const triggers = state.triggers orelse return false;
    if (triggers.len == 0) return false;
    if (isPlatformKey(key)) return false;
    for (triggers) |entry| {
        if (std.mem.startsWith(u8, key, entry.prefix)) return true;
    }
    return false;
}

/// Take whatever exception is on the qjs context, format it as
/// `<trigger_path>: <original message>`, and rethrow as a fresh
/// Error with `code: "trigger_rejected"` (PLAN §2.5). Always
/// returns `js_exception` for caller's convenience. Caller MUST
/// have already rolled back the inner savepoint before calling
/// this — this only handles the JS-side throw.
pub fn rethrowAsTriggerRejected(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    trigger_path: []const u8,
) c.JSValue {
    // Pull the original message off the context. Some trigger
    // failures (e.g. depth-cap throw, internal errors during
    // module load) never leave a real exception on the context —
    // in that case ctx.takeExceptionMessage returns "" and we
    // fall back to a synthetic message.
    const ctx_wrap = qjs.Context{ .raw = ctx.? };
    const original = ctx_wrap.takeExceptionMessage(state.allocator) catch
        return c.JS_ThrowOutOfMemory(ctx);
    defer state.allocator.free(original);

    const fallback = "trigger rejected the write";
    const original_or_fallback = if (original.len > 0) original else fallback;

    const msg = std.fmt.allocPrintSentinel(
        state.allocator,
        "{s}: {s}",
        .{ trigger_path, original_or_fallback },
        0,
    ) catch return c.JS_ThrowOutOfMemory(ctx);
    defer state.allocator.free(msg);

    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return err;

    _ = c.JS_SetPropertyStr(
        ctx,
        err,
        "message",
        c.JS_NewStringLen(ctx, msg.ptr, msg.len),
    );
    _ = c.JS_SetPropertyStr(
        ctx,
        err,
        "code",
        c.JS_NewStringLen(ctx, "trigger_rejected", "trigger_rejected".len),
    );

    return c.JS_Throw(ctx, err);
}

/// Outcome of running one trigger function. Captures both the
/// success path (with optional value mutation for BEFORE) and the
/// failure path (exception left on the qjs context). The caller
/// is responsible for savepoint rollback + rethrow on failure.
const FireOutcome = union(enum) {
    /// No-op (module didn't export a matching handler, or load failed).
    skipped: void,
    /// Trigger ran. `new_value` is non-null only when this was a
    /// BEFORE put and the trigger returned a string — that string
    /// is the customer's mutated value, owned by the state allocator;
    /// caller frees.
    ok: struct { new_value: ?[]u8 },
    /// Trigger threw. The exception is sitting on the qjs context;
    /// caller must `rethrowAsTriggerRejected` (after rolling back
    /// the inner savepoint).
    rejected: void,
};

/// Run a single trigger's handler for one op×timing combination.
/// Pure execution — no savepoint management, no chain iteration;
/// the caller (`runBeforeChain` / `runAfterChain`) wraps that.
fn fireOneTrigger(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    entry: TriggerEntry,
    key: []const u8,
    op: TriggerOp,
    timing: []const u8,
    cur_value: ?[]const u8,
    prev_value: ?[]const u8,
) FireOutcome {
    if (state.trigger_depth >= MAX_TRIGGER_DEPTH) {
        const msg = std.fmt.allocPrintSentinel(
            state.allocator,
            "trigger cascade depth exceeded ({d}) at {s}",
            .{ MAX_TRIGGER_DEPTH, entry.module_path },
            0,
        ) catch return .rejected;
        defer state.allocator.free(msg);
        _ = c.JS_ThrowInternalError(ctx, msg.ptr);
        return .rejected;
    }

    const ns = loadTriggerModuleNs(state, ctx, entry.module_path) orelse {
        std.log.warn("rove-js: trigger module {s} failed to load — skipping", .{entry.module_path});
        return .skipped;
    };
    defer c.JS_FreeValue(ctx, ns);

    const handler = lookupTriggerHandler(ctx, ns, op, timing);
    if (c.JS_IsUndefined(handler)) return .skipped;
    defer c.JS_FreeValue(ctx, handler);

    // Depth bumps BEFORE event build so event.depth reflects this
    // trigger's own cascade level (PLAN §2.5: handler-initiated
    // writes are depth 0; the trigger fired by them is depth 1;
    // its cascade is depth 2; etc.).
    state.trigger_depth += 1;
    defer state.trigger_depth -= 1;

    const event = buildTriggerEvent(state, ctx, key, op, timing, cur_value, prev_value);
    defer c.JS_FreeValue(ctx, event);

    var args = [_]c.JSValue{event};
    const ret = c.JS_Call(ctx, handler, js_undefined, 1, &args);
    if (c.JS_IsException(ret)) return .rejected;

    // BEFORE-put trigger return value (if a string) becomes the
    // mutated value for the actual write. Other return types
    // (object, number, undefined, null) leave the value untouched —
    // customer who wants to mutate must `return JSON.stringify(x)`.
    //
    // Order matters: copy the bytes off the JS string BEFORE
    // freeing the JS value. JS_ToCStringLen returns a pointer
    // into the string's internal buffer; JS_FreeValue would drop
    // the last reference and invalidate it.
    defer c.JS_FreeValue(ctx, ret);
    if (op == .put and std.mem.eql(u8, timing, "before") and c.JS_IsString(ret)) {
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(ctx, &len, ret);
        if (cstr == null) return .{ .ok = .{ .new_value = null } };
        defer c.JS_FreeCString(ctx, cstr);

        const owned = state.allocator.alloc(u8, len) catch
            return .{ .ok = .{ .new_value = null } };
        if (len > 0) @memcpy(owned, @as([*]const u8, @ptrCast(cstr))[0..len]);
        return .{ .ok = .{ .new_value = owned } };
    }

    return .{ .ok = .{ .new_value = null } };
}

/// Run the BEFORE chain for a write. Tree-traversal order is
/// outermost-first (per PLAN §2.5 "broad policies validate before
/// narrow ones") — registry is sorted longest-first, so we iterate
/// in reverse. Each trigger may mutate the value via its return.
///
/// `cur_value` tracks the current value being written — starts at
/// the original (borrowed) buffer the customer passed; if any
/// BEFORE returns a string, the helper allocates a fresh buffer
/// and updates both `cur_value` and `cur_owned`. The caller frees
/// `cur_owned.*` if non-null.
///
/// Returns `null` on success; returns the rejecting trigger's
/// path on failure (caller rolls back + rethrows).
pub fn runBeforeChain(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    key: []const u8,
    op: TriggerOp,
    cur_value: *?[]const u8,
    cur_owned: *?[]u8,
    prev_value: ?[]const u8,
) ?[]const u8 {
    const triggers = state.triggers orelse return null;

    var i: usize = triggers.len;
    while (i > 0) {
        i -= 1;
        const entry = triggers[i];
        if (!std.mem.startsWith(u8, key, entry.prefix)) continue;

        const outcome = fireOneTrigger(
            state,
            ctx,
            entry,
            key,
            op,
            "before",
            cur_value.*,
            prev_value,
        );
        switch (outcome) {
            .skipped => {},
            .rejected => return entry.module_path,
            .ok => |o| if (o.new_value) |new| {
                if (cur_owned.*) |old| state.allocator.free(old);
                cur_owned.* = new;
                cur_value.* = new;
            },
        }
    }
    return null;
}

/// Run the AFTER chain for a write. Tree-traversal order is
/// innermost-first (registry already sorted longest-first → forward
/// iteration). AFTER triggers' return values are ignored; throws
/// roll back the originating write via the inner savepoint.
pub fn runAfterChain(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    key: []const u8,
    op: TriggerOp,
    cur_value: ?[]const u8,
    prev_value: ?[]const u8,
) ?[]const u8 {
    const triggers = state.triggers orelse return null;

    for (triggers) |entry| {
        if (!std.mem.startsWith(u8, key, entry.prefix)) continue;

        const outcome = fireOneTrigger(
            state,
            ctx,
            entry,
            key,
            op,
            "after",
            cur_value,
            prev_value,
        );
        switch (outcome) {
            .skipped => {},
            .rejected => return entry.module_path,
            .ok => {}, // AFTER return value is ignored
        }
    }
    return null;
}

/// Roll back the inner savepoint and release it. Always called on
/// the trigger-rejection path. Logs but doesn't throw on rollback
/// failure (per fail-fast: surface but don't compound).
pub fn rollbackInnerSavepoint(state: *DispatchState) void {
    state.txn.rollbackTo() catch |re| std.log.err(
        "rove-js: trigger inner-savepoint rollback failed: {s} (kv state may be inconsistent)",
        .{@errorName(re)},
    );
    state.txn.release() catch |re| std.log.err(
        "rove-js: trigger inner-savepoint release after rollback failed: {s}",
        .{@errorName(re)},
    );
}

