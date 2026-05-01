//! JS globals installed on every request context.
//!
//! Four globals for M1:
//!
//!   `kv.get(key)`              → string | null
//!   `kv.set(key, value)`       → undefined
//!   `kv.delete(key)`           → undefined
//!   `console.log(...args)`     → undefined (appended to stderr-buffer)
//!   `request`                  → `{ method, path, body }` (read-only by convention)
//!   `response`                 → `{ status: 200, body: "", headers: {} }`
//!
//! State shared between the C functions and the dispatcher lives in a
//! `DispatchState` struct stashed on the context via
//! `JS_SetContextOpaque`. The C callbacks pull the state pointer out of
//! the context on every call.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const limiter_mod = @import("limiter.zig");
const crypto_b = @import("bindings/crypto.zig");
const webhook_b = @import("bindings/webhook.zig");

const c = qjs.c;

// Zig's @cImport can't translate quickjs-ng's designated-initializer
// macros for `JS_UNDEFINED` etc. (they trip `std.mem.zeroInit` on the
// anonymous union). Reconstruct them by hand — the layout is stable in
// non-NaN-boxing mode, which is what our Linux x86_64 build uses.
inline fn mkVal(tag: i64, val: i32) c.JSValue {
    return .{ .u = .{ .int32 = val }, .tag = tag };
}
pub const js_undefined: c.JSValue = mkVal(c.JS_TAG_UNDEFINED, 0);
pub const js_null: c.JSValue = mkVal(c.JS_TAG_NULL, 0);
pub const js_exception: c.JSValue = mkVal(c.JS_TAG_EXCEPTION, 0);

/// One row in a tenant's trigger registry. Built at deploy-load time
/// (worker.zig) from manifest paths matching `_triggers/.../index.{mjs,js}`.
/// `prefix` is what we match kv keys against; `module_path` is the
/// bytecode lookup key (into the deployment's bytecode map) and the
/// identity surfaced in error messages (e.g.
/// `"_triggers/users/sessions/index.mjs"`).
pub const TriggerEntry = struct {
    prefix: []u8,
    module_path: []u8,
};

pub const DispatchState = struct {
    allocator: std.mem.Allocator,
    /// Per-request KV store. `kv.get("x")` reads from this handle,
    /// which is the SAME connection the `TrackedTxn` opened its
    /// transaction on, so reads see the transaction's uncommitted
    /// writes — read-your-writes works within one handler.
    kv: *kv_mod.KvStore,
    /// Open tracked transaction on `kv`. Writes from the handler go
    /// through this (for local visibility + undo) AND through the
    /// `writeset` (for raft replication). Committed or rolled back
    /// after raft reports back — see `worker.drainRaftPending`.
    txn: *kv_mod.TrackedTxn,
    /// Raft write accumulator. Shape-parallel to the `TrackedTxn`'s
    /// local writes — followers replay the encoded writeset against
    /// their tenant stores via `applyEncodedWriteSet`.
    writeset: *kv_mod.WriteSet,
    /// Accumulated `console.log` output. Owned by the dispatcher; reset
    /// between requests.
    console: *std.ArrayList(u8),
    /// Set if a kv-level error needs to bubble back to the caller after
    /// the JS runs. We can't throw from inside the C callback cleanly in
    /// all cases, so we record the first error and let the dispatcher
    /// surface it.
    pending_kv_error: ?anyerror = null,
    /// Optional kv tape. When non-null, every `kv.get` / `kv.set` /
    /// `kv.delete` the handler performs is appended as an entry so a
    /// later replay can re-drive the same handler without touching a
    /// live KV store. Null means "don't capture" (tests, legacy paths).
    kv_tape: ?*tape_mod.Tape = null,
    date_tape: ?*tape_mod.Tape = null,
    math_random_tape: ?*tape_mod.Tape = null,
    crypto_random_tape: ?*tape_mod.Tape = null,
    /// PRNG used by our `Math.random` override so the test path and
    /// production path stay deterministic w.r.t. a given seed. Seeded
    /// by the dispatcher per request. Installed only when a tape is
    /// present (so the normal path still uses qjs's built-in Math.random).
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    /// Per-request identifier, pre-minted by the worker. Combined with
    /// `webhook_call_index` to derive a deterministic outbox id for
    /// every `webhook.send` this handler invocation performs.
    request_id: u64 = 0,
    /// 0-based counter of `webhook.send` calls within this handler
    /// invocation. Resets per request. Part of the outbox id derivation
    /// so replays produce the same ids.
    webhook_call_index: u32 = 0,
    /// Singleton admin-capability pointer. Non-null only when the
    /// handler-tenant is `__admin__`; the dispatcher installs the
    /// `platform.*` JS globals (instance / domain / root kv access)
    /// iff this field is set. Regular tenants' handlers see
    /// `platform === undefined` in their runtime.
    platform: ?*tenant_mod.Tenant = null,
    /// Raft writeset accumulating root-store writes the admin
    /// handler makes via `platform.root.set` / `platform.root.delete`.
    /// Dispatcher creates this alongside the per-tenant writeset
    /// when `platform != null`; worker proposes it through raft as
    /// a type=2 envelope after commit so followers' copies of
    /// `__root__.db` stay in sync.
    root_writeset: ?*kv_mod.WriteSet = null,
    /// Trigger registry for the active deployment (PLAN §2.5).
    /// Sorted longest-prefix-first → forward iteration visits
    /// innermost (most-specific) triggers first; AFTER chain uses
    /// forward order, BEFORE chain reverses. Null = no triggers
    /// (test paths that don't care).
    triggers: ?[]const TriggerEntry = null,
    /// Per-deployment bytecode map. Same map the module loader
    /// uses for handler imports — trigger modules live in it under
    /// their `_triggers/.../index.{mjs,js}` paths. Needed by the
    /// trigger fire path to load module bytecode lazily on first
    /// fire and look up named exports.
    bytecodes: ?*const std.StringHashMapUnmanaged([]u8) = null,
    /// Cascade depth: how many trigger frames are currently on the
    /// JS call stack. 0 = user-initiated write. Incremented before
    /// a trigger fires, decremented after. Throws if a fire would
    /// take it past `MAX_TRIGGER_DEPTH` (PLAN §2.5 limits).
    trigger_depth: u32 = 0,
    /// Per-request cache of trigger-module namespaces. Module
    /// top-level state (e.g. `let count = 0`) persists across fires
    /// within one handler invocation but resets between requests
    /// (the snapshot/restore wipes the runtime). Owned values must
    /// be `JS_FreeValue`'d on `deinit`.
    trigger_module_ns: std.StringHashMapUnmanaged(c.JSValue) = .empty,
    /// Per-worker rate limiter. Used by the `__rove_check_email_rate`
    /// builtin (called from the `email.send` JS wrapper) to take
    /// from the email bucket before queuing the outbox row. Null in
    /// test paths that don't care.
    limiter: ?*limiter_mod.RateLimiter = null,
    /// Instance id for limiter lookup. Empty when the dispatcher
    /// runs without a worker (test paths).
    instance_id: []const u8 = "",
    /// Trampoline backing `platform.instances.deployStarter(name)`.
    /// Worker provides a concrete fn that can cast `ctx` back to
    /// its specific `*Worker(opts)` type, opens the target's
    /// files.db, runs the deploy, and proposes the resulting files
    /// writeset through raft. Null on test paths without a worker;
    /// the JS callable throws a clear error in that case.
    deploy_starter: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) anyerror!void = null,
    deploy_starter_ctx: ?*anyopaque = null,

    pub fn deinit(self: *DispatchState, ctx: ?*c.JSContext) void {
        var it = self.trigger_module_ns.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            c.JS_FreeValue(ctx, e.value_ptr.*);
        }
        self.trigger_module_ns.deinit(self.allocator);
        self.* = undefined;
    }
};

/// PLAN §2.5 cascade depth ceiling.
pub const MAX_TRIGGER_DEPTH: u32 = 8;

/// Fire-time platform-key guard. Same list as worker.zig's
/// `PLATFORM_KV_PREFIXES` (deploy-load guard) — defense in depth.
/// If a kv key under a customer's catch-all trigger happens to
/// start with one of these, we silently skip trigger dispatch.
const PLATFORM_KV_PREFIXES_FIRE = [_][]const u8{
    "_audit/",
    "_deploy/",
    "_outbox/",
    "_outbox_inflight/",
    "_dlq/",
    "_callback/",
    "_magic/",
    "_triggers/",
    "_events/",
    "_sessions/",
};

fn isPlatformKey(key: []const u8) bool {
    for (PLATFORM_KV_PREFIXES_FIRE) |p| {
        if (std.mem.startsWith(u8, key, p)) return true;
    }
    return false;
}

// ── C helpers ──────────────────────────────────────────────────────────

pub fn getState(ctx: ?*c.JSContext) *DispatchState {
    const opaque_ptr = c.JS_GetContextOpaque(ctx);
    return @ptrCast(@alignCast(opaque_ptr.?));
}

/// Convert a JS value to a Zig-owned string via the state allocator.
/// Caller frees.
fn valueToOwnedString(
    state: *DispatchState,
    ctx: ?*c.JSContext,
    val: c.JSValue,
) ![]u8 {
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const out = try state.allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
    return out;
}

// ── kv.* ──────────────────────────────────────────────────────────────

fn jsKvGet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);

    const value = state.kv.get(key_str) catch |err| switch (err) {
        error.NotFound => {
            if (state.kv_tape) |t| t.appendKv(.get, key_str, "", .not_found) catch {};
            return js_null;
        },
        else => {
            state.pending_kv_error = err;
            if (state.kv_tape) |t| t.appendKv(.get, key_str, "", .err) catch {};
            return js_null;
        },
    };
    defer state.allocator.free(value);

    if (state.kv_tape) |t| t.appendKv(.get, key_str, value, .ok) catch {};
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

fn jsKvSet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);
    const val_str = valueToOwnedString(state, ctx, argv[1]) catch return js_exception;
    defer state.allocator.free(val_str);

    // Fast path: no triggers match → write directly, no savepoint, no
    // previousValue lookup, no chain machinery. Same cost as before
    // triggers existed.
    if (!anyTriggerMatches(state, key_str)) {
        state.txn.put(key_str, val_str) catch |err| {
            state.pending_kv_error = err;
            if (state.kv_tape) |t| t.appendKv(.set, key_str, val_str, .err) catch {};
            return js_undefined;
        };
        state.writeset.addPut(key_str, val_str) catch |err| {
            state.pending_kv_error = err;
        };
        if (state.kv_tape) |t| t.appendKv(.set, key_str, val_str, .ok) catch {};
        return js_undefined;
    }

    // Slow path: there's at least one matching trigger. Fetch the
    // previousValue, open an inner savepoint, run BEFORE chain
    // (with possible value mutation), do the write, run AFTER chain.
    // Throw anywhere → rollback the savepoint and rethrow as
    // `Error{ code: "trigger_rejected" }`.
    var prev_owned: ?[]u8 = null;
    defer if (prev_owned) |p| state.allocator.free(p);
    if (state.kv.get(key_str)) |bytes| {
        prev_owned = bytes;
    } else |err| switch (err) {
        error.NotFound => {},
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    }

    state.txn.savepoint() catch |err| {
        state.pending_kv_error = err;
        return js_undefined;
    };

    // `cur_value` starts as the original `val_str` (borrowed). If a
    // BEFORE trigger returns a string, the chain helper allocates a
    // fresh buffer, points `cur_value` at it, and tracks ownership
    // via `cur_owned` so we can free it before returning.
    var cur_owned: ?[]u8 = null;
    defer if (cur_owned) |o| state.allocator.free(o);
    var cur_value: ?[]const u8 = val_str;
    if (runBeforeChain(state, ctx, key_str, .put, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
        rollbackInnerSavepoint(state);
        return rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    const write_value: []const u8 = cur_value.?;

    state.txn.put(key_str, write_value) catch |err| {
        state.pending_kv_error = err;
        rollbackInnerSavepoint(state);
        if (state.kv_tape) |t| t.appendKv(.set, key_str, write_value, .err) catch {};
        return js_undefined;
    };
    state.writeset.addPut(key_str, write_value) catch |err| {
        state.pending_kv_error = err;
    };
    if (state.kv_tape) |t| t.appendKv(.set, key_str, write_value, .ok) catch {};

    if (runAfterChain(state, ctx, key_str, .put, write_value, prev_owned)) |trigger_path| {
        rollbackInnerSavepoint(state);
        return rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.release() catch |err| {
        state.pending_kv_error = err;
    };
    return js_undefined;
}

fn jsKvDelete(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const key_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key_str);

    // Fast path mirrors jsKvSet — no triggers means no savepoint, no
    // previousValue lookup, no chain machinery.
    if (!anyTriggerMatches(state, key_str)) {
        state.txn.delete(key_str) catch |err| {
            state.pending_kv_error = err;
            if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .err) catch {};
            return js_undefined;
        };
        state.writeset.addDelete(key_str) catch |err| {
            state.pending_kv_error = err;
        };
        if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .ok) catch {};
        return js_undefined;
    }

    var prev_owned: ?[]u8 = null;
    defer if (prev_owned) |p| state.allocator.free(p);
    if (state.kv.get(key_str)) |bytes| {
        prev_owned = bytes;
    } else |err| switch (err) {
        error.NotFound => {},
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    }

    state.txn.savepoint() catch |err| {
        state.pending_kv_error = err;
        return js_undefined;
    };

    // BEFORE chain: deletes don't carry a value, so cur_value stays
    // null (the helper passes that through to event.value as JS null,
    // and ignores any string return from a beforeDelete handler).
    var cur_owned: ?[]u8 = null;
    defer if (cur_owned) |o| state.allocator.free(o);
    var cur_value: ?[]const u8 = null;
    if (runBeforeChain(state, ctx, key_str, .delete, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
        rollbackInnerSavepoint(state);
        return rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.delete(key_str) catch |err| {
        state.pending_kv_error = err;
        rollbackInnerSavepoint(state);
        if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .err) catch {};
        return js_undefined;
    };
    state.writeset.addDelete(key_str) catch |err| {
        state.pending_kv_error = err;
    };
    if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .ok) catch {};

    if (runAfterChain(state, ctx, key_str, .delete, null, prev_owned)) |trigger_path| {
        rollbackInnerSavepoint(state);
        return rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.release() catch |err| {
        state.pending_kv_error = err;
    };
    return js_undefined;
}

// ── Trigger fire path (PLAN §2.5) ─────────────────────────────────────

const TriggerOp = enum { put, delete };

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
    const bytes = map.get(module_path) orelse return null;

    const obj = c.JS_ReadObject(ctx, bytes.ptr, bytes.len, c.JS_READ_OBJ_BYTECODE);
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
        var rid_buf: [16]u8 = undefined;
        const rid_hex = std.fmt.bufPrint(&rid_buf, "{x:0>16}", .{state.request_id}) catch "";
        _ = c.JS_SetPropertyStr(ctx, actor, "request_id", c.JS_NewStringLen(ctx, rid_hex.ptr, rid_hex.len));
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
fn anyTriggerMatches(state: *DispatchState, key: []const u8) bool {
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
fn rethrowAsTriggerRejected(
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
fn runBeforeChain(
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
fn runAfterChain(
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
fn rollbackInnerSavepoint(state: *DispatchState) void {
    state.txn.rollbackTo() catch |re| std.log.err(
        "rove-js: trigger inner-savepoint rollback failed: {s} (kv state may be inconsistent)",
        .{@errorName(re)},
    );
    state.txn.release() catch |re| std.log.err(
        "rove-js: trigger inner-savepoint release after rollback failed: {s}",
        .{@errorName(re)},
    );
}

/// `kv.prefix(prefix, cursor?, limit?)` → `[ { key, value }, ... ]`
///
/// Prefix scan exposed to handlers. `cursor` is the last key from a
/// previous page (pass "" to start). `limit` defaults to 100, capped
/// at 1000 — this is an admin/introspection surface, not a hot read
/// path, so we err on the side of small pages. Reads go directly
/// through `state.kv`; writes from the same handler are visible here
/// because the underlying SQLite connection sees its own uncommitted
/// txn state.
///
/// NOT tape-captured in this slice — replay of prefix-scanning
/// handlers will see live KV state, not the state at capture time.
/// Deferred until the replay surface actually needs it.
fn jsKvPrefix(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);

    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const KV_PREFIX_MAX: u32 = 1000;
    const KV_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk KV_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), KV_PREFIX_MAX);
    } else KV_PREFIX_DEFAULT;

    var scan = state.kv.prefix(prefix_str, cursor_str, limit) catch |err| {
        state.pending_kv_error = err;
        return js_null;
    };
    defer scan.deinit();

    const arr = c.JS_NewArray(ctx);
    for (scan.entries, 0..) |e, i| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "key", c.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "value", c.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
    }
    return arr;
}

// ── Date.now / Math.random / crypto.* ─────────────────────────────────
//
// These are tape-backed non-determinism sources. The MVP shape is:
//   - Only install overrides when `DispatchState` has a matching tape.
//     Without a tape the handler uses qjs's built-ins (qjs Math.random
//     is a stock xoshiro, Date.now is gettimeofday, there's no crypto
//     global). With a tape we stamp a deterministic value AND record
//     it so replay can re-issue the same value.
//   - Phase 4 slice 3 only does capture. Replay mode — reading values
//     back from a `ReplaySource` — is the next slice.
//   - `new Date()` with no args is NOT intercepted yet; handlers should
//     use `Date.now()` for now. Overriding the constructor requires
//     more qjs plumbing than is worth in this slice.

fn jsDateNow(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    // Wall-clock ms. Determinism comes from the tape on replay — the
    // live path still reads the real clock so logs of real requests
    // show real timestamps.
    const ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    if (state.date_tape) |t| t.appendDate(ms) catch {};
    return c.JS_NewInt64(ctx, ms);
}

fn jsMathRandom(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    // Draw a 53-bit mantissa from the PRNG and scale to [0, 1).
    // Matches what qjs's built-in Math.random does, just seeded.
    const bits = state.prng.random().int(u64) >> 11;
    const v: f64 = @as(f64, @floatFromInt(bits)) * (1.0 / @as(f64, @floatFromInt(@as(u64, 1) << 53)));
    if (state.math_random_tape) |t| t.appendMathRandom(v) catch {};
    return c.JS_NewFloat64(ctx, v);
}



// ── console.log ───────────────────────────────────────────────────────

fn jsConsoleLog(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    const n: usize = if (argc < 0) 0 else @intCast(argc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) state.console.append(state.allocator, ' ') catch return js_exception;
        const s = valueToOwnedString(state, ctx, argv[i]) catch return js_exception;
        defer state.allocator.free(s);
        state.console.appendSlice(state.allocator, s) catch return js_exception;
    }
    state.console.append(state.allocator, '\n') catch return js_exception;
    return js_undefined;
}

// ── platform.root.* (admin singleton only) ────────────────────────
//
// Only installed when the handler-tenant is `__admin__` — gated on
// `state.platform` being non-null in `installRequest`. Provides raw
// access to the platform root store for the admin JS handler's
// instance / domain / user / account reads. Writes currently land
// locally on the leader only (no raft propagation of root writes
// from JS handlers yet); multi-node correctness for admin-handler
// writes is follow-up work. Signup + other platform-level writes
// go through the Zig-native HTTP endpoints, which DO replicate.

fn jsPlatformRootGet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);

    const value = tenant.root.get(key) catch |err| switch (err) {
        error.NotFound => return js_null,
        else => {
            state.pending_kv_error = err;
            return js_null;
        },
    };
    defer state.allocator.free(value);
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

fn jsPlatformRootSet(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);
    const val = valueToOwnedString(state, ctx, argv[1]) catch return js_exception;
    defer state.allocator.free(val);

    tenant.root.put(key, val) catch |err| {
        state.pending_kv_error = err;
    };
    // Mirror the write into the root writeset so the worker can
    // propose it through raft. Admin handlers ALWAYS have this
    // set (dispatcher init checks `platform != null`), so an unset
    // field here means someone built a DispatchState by hand.
    if (state.root_writeset) |ws| {
        ws.addPut(key, val) catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

fn jsPlatformRootDelete(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);

    tenant.root.delete(key) catch |err| switch (err) {
        error.NotFound => {
            // Still propagate the delete to followers so their state
            // converges — a key that's missing locally might exist
            // on other nodes if propose ordering skewed. The follower
            // `applyEncodedWriteSet` treats NotFound as a no-op.
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    if (state.root_writeset) |ws| {
        ws.addDelete(key) catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

fn jsPlatformRootPrefix(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_undefined;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const prefix_str = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(prefix_str);

    const cursor_str = if (argc >= 2 and !c.JS_IsUndefined(argv[1]) and !c.JS_IsNull(argv[1]))
        valueToOwnedString(state, ctx, argv[1]) catch return js_exception
    else
        state.allocator.dupe(u8, "") catch return js_exception;
    defer state.allocator.free(cursor_str);

    const ROOT_PREFIX_MAX: u32 = 1000;
    const ROOT_PREFIX_DEFAULT: u32 = 100;
    const limit: u32 = if (argc >= 3 and !c.JS_IsUndefined(argv[2]) and !c.JS_IsNull(argv[2])) blk: {
        var n: i32 = 0;
        _ = c.JS_ToInt32(ctx, &n, argv[2]);
        if (n <= 0) break :blk ROOT_PREFIX_DEFAULT;
        break :blk @min(@as(u32, @intCast(n)), ROOT_PREFIX_MAX);
    } else ROOT_PREFIX_DEFAULT;

    var scan = tenant.root.prefix(prefix_str, cursor_str, limit) catch |err| {
        state.pending_kv_error = err;
        return js_null;
    };
    defer scan.deinit();

    const arr = c.JS_NewArray(ctx);
    for (scan.entries, 0..) |e, i| {
        const obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, obj, "key", c.JS_NewStringLen(ctx, e.key.ptr, e.key.len));
        _ = c.JS_SetPropertyStr(ctx, obj, "value", c.JS_NewStringLen(ctx, e.value.ptr, e.value.len));
        _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
    }
    return arr;
}

/// `platform.instances.create(name)` — admin-only. Creates the
/// instance directory, opens its app.db, writes the local
/// `instance/{name}` marker, and mirrors the marker into the root
/// writeset for raft replication. Idempotent: re-creating an already
/// existing instance is a no-op (matches the underlying
/// `tenant.createInstance`).
///
/// Throws `Error{code:"InvalidName"}` if the name fails validation
/// (empty, too long, bad characters). Other errors land in
/// `state.pending_kv_error` and surface as a 5xx.
fn jsPlatformInstancesCreate(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.create requires (name)");
        return js_exception;
    }
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const name = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(name);

    tenant.createInstance(name) catch |err| switch (err) {
        error.InvalidInstanceId => {
            const err_obj = c.JS_NewError(ctx);
            if (c.JS_IsException(err_obj)) return err_obj;
            _ = c.JS_SetPropertyStr(ctx, err_obj, "message",
                c.JS_NewStringLen(ctx, "invalid instance name", "invalid instance name".len));
            _ = c.JS_SetPropertyStr(ctx, err_obj, "code",
                c.JS_NewStringLen(ctx, "InvalidName", "InvalidName".len));
            return c.JS_Throw(ctx, err_obj);
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };

    if (state.root_writeset) |ws| {
        var key_buf: [16 + tenant_mod.MAX_INSTANCE_ID_LEN]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "instance/{s}", .{name}) catch
            unreachable; // name was validated by createInstance above
        ws.addPut(key, "") catch |err| {
            state.pending_kv_error = err;
        };
    }
    return js_undefined;
}

/// `platform.instances.deployStarter(name)` — admin-only. Writes
/// the embedded starter content (`index.mjs` + `_static/index.html`)
/// into the target instance's files.db + file-blobs/, then proposes
/// the resulting files writeset through raft so followers see the
/// same deployment.
///
/// Sealed primitive in v1: starter content is platform-baked
/// (`STARTER_INDEX_MJS` / `STARTER_STATIC_INDEX_HTML` in worker.zig),
/// not customer-supplied. A general `platform.deploy(name, files)`
/// is deferred until concrete demand (e.g. a libraries marketplace)
/// — see PLAN §10.
///
/// Throws `Error{code:"InstanceNotFound"}` if `name` doesn't resolve.
/// Throws `TypeError` when called outside an admin handler or before
/// the worker has wired the deploy trampoline (test path).
fn jsPlatformInstancesDeployStarter(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.deployStarter requires (name)");
        return js_exception;
    }
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }
    const fn_ptr = state.deploy_starter orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.deployStarter is not configured (no compile callback)");
        return js_exception;
    };
    const fn_ctx = state.deploy_starter_ctx orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.instances.deployStarter context missing");
        return js_exception;
    };

    const name = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(name);

    fn_ptr(fn_ctx, state.allocator, name) catch |err| switch (err) {
        error.InstanceNotFound => {
            const err_obj = c.JS_NewError(ctx);
            if (c.JS_IsException(err_obj)) return err_obj;
            _ = c.JS_SetPropertyStr(ctx, err_obj, "message",
                c.JS_NewStringLen(ctx, "instance not found", "instance not found".len));
            _ = c.JS_SetPropertyStr(ctx, err_obj, "code",
                c.JS_NewStringLen(ctx, "InstanceNotFound", "InstanceNotFound".len));
            return c.JS_Throw(ctx, err_obj);
        },
        else => {
            state.pending_kv_error = err;
            return js_undefined;
        },
    };
    return js_undefined;
}

// ── Installation ──────────────────────────────────────────────────────

/// Install the pieces of the global surface that do NOT depend on a
/// per-request `DispatchState` or `Request`. Safe to call from a
/// snapshot init callback — pure, deterministic, no clocks, no
/// allocation outside the arena. The bulk of the cost of setting up a
/// JS handler context lives here (C-function bindings register atoms
/// and shape transitions), so doing it once at snapshot creation time
/// and then memcpy-restoring for each request is the whole point of
/// rove-qjs.
///
/// Installs: `kv`, `console`, `crypto`, `Date.now`, `Math.random`,
/// `webhook`, `email`. Installs `platform` on every context too —
/// the per-request `installRequest` gates it on `state.platform` so
/// callbacks reject non-admin handlers at call time.
/// Does NOT install `request`, `response`, or the context opaque —
/// see `installRequest`.
pub fn installStatic(ctx: *c.JSContext) void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // kv = { get, set, delete, prefix }
    const kv_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "get", c.JS_NewCFunction2(ctx, jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "set", c.JS_NewCFunction2(ctx, jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "delete", c.JS_NewCFunction2(ctx, jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, kv_obj, "prefix", c.JS_NewCFunction2(ctx, jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "kv", kv_obj);

    // console = { log }
    const console_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, console_obj, "log", c.JS_NewCFunction2(ctx, jsConsoleLog, "log", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "console", console_obj);

    // Non-determinism overrides. Always installed (tape optional) so
    // the handler-visible API is stable whether we're capturing or not;
    // the C callbacks short-circuit their tape branches when the
    // matching `DispatchState` tape is null.
    const date_obj = c.JS_GetPropertyStr(ctx, global, "Date");
    defer c.JS_FreeValue(ctx, date_obj);
    if (!c.JS_IsUndefined(date_obj)) {
        _ = c.JS_SetPropertyStr(ctx, date_obj, "now", c.JS_NewCFunction2(ctx, jsDateNow, "now", 0, c.JS_CFUNC_generic, 0));
    }

    const math_obj = c.JS_GetPropertyStr(ctx, global, "Math");
    defer c.JS_FreeValue(ctx, math_obj);
    if (!c.JS_IsUndefined(math_obj)) {
        _ = c.JS_SetPropertyStr(ctx, math_obj, "random", c.JS_NewCFunction2(ctx, jsMathRandom, "random", 0, c.JS_CFUNC_generic, 0));
    }

    // crypto = { getRandomValues, randomUUID, randomBytes, sha256,
    // hmacSha256 }. No crypto global in qjs-ng by default, so we
    // fabricate one. hmacSha256 is the vendor-neutral primitive for
    // building Stripe / Slack / AWS style signatures (PLAN §2.6);
    // randomBytes + sha256 are what admin's JS handler composes into
    // magic-link / session token mint and hash-at-rest.
    const crypto_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "getRandomValues", c.JS_NewCFunction2(ctx, crypto_b.jsCryptoGetRandomValues, "getRandomValues", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "randomUUID", c.JS_NewCFunction2(ctx, crypto_b.jsCryptoRandomUuid, "randomUUID", 0, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "randomBytes", c.JS_NewCFunction2(ctx, crypto_b.jsCryptoRandomBytes, "randomBytes", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "sha256", c.JS_NewCFunction2(ctx, crypto_b.jsCryptoSha256, "sha256", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, crypto_obj, "hmacSha256", c.JS_NewCFunction2(ctx, crypto_b.jsCryptoHmacSha256, "hmacSha256", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "crypto", crypto_obj);

    // webhook = { send }. Delivery is async — send() persists the
    // envelope in the handler's transaction and returns an id; the
    // drainer thread on the raft leader does the actual HTTP call.
    const webhook_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, webhook_obj, "send", c.JS_NewCFunction2(ctx, webhook_b.jsWebhookSend, "send", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "webhook", webhook_obj);

    // Hidden builtin: take from the email rate-limit bucket. Called
    // from the email.send JS wrapper below before queuing the outbox
    // row. Throws Error{code:"rate_limited", message:"..."} when the
    // bucket is exhausted; customer can try/catch in their handler.
    // No-op (returns undefined) when state.limiter is null (test paths).
    _ = c.JS_SetPropertyStr(ctx, global, "__rove_check_email_rate",
        c.JS_NewCFunction2(ctx, webhook_b.jsCheckEmailRate, "__rove_check_email_rate", 0, c.JS_CFUNC_generic, 0));

    // email.send — thin wrapper around webhook.send that builds a
    // Resend-shaped POST and takes the API key as a parameter rather
    // than resolving it from platform config. Keeps key storage a
    // customer concern (kv entry, inlined, fetched from elsewhere)
    // and keeps the platform out of the abuse loop: a customer can
    // only email.send using a Resend key they have.
    //
    // Our own magic-link / signup emails are queued by the Zig-
    // native signup handler, which reads the platform Resend key
    // off root.db and writes the outbox row into __admin__'s app.db.
    const email_snippet =
        \\globalThis.email = {
        \\  send(opts) {
        \\    __rove_check_email_rate();
        \\    if (!opts || typeof opts !== "object")
        \\      throw new TypeError("email.send requires an options object");
        \\    if (typeof opts.key !== "string" || opts.key.length === 0)
        \\      throw new TypeError("email.send: `key` must be a non-empty string");
        \\    if (typeof opts.from !== "string")
        \\      throw new TypeError("email.send: `from` must be a string");
        \\    if (typeof opts.subject !== "string")
        \\      throw new TypeError("email.send: `subject` must be a string");
        \\    if (!opts.to)
        \\      throw new TypeError("email.send: `to` is required");
        \\    const body = {
        \\      from: opts.from,
        \\      to: Array.isArray(opts.to) ? opts.to : [opts.to],
        \\      subject: opts.subject,
        \\    };
        \\    if (opts.text) body.text = opts.text;
        \\    if (opts.html) body.html = opts.html;
        \\    if (opts.reply_to) body.reply_to = opts.reply_to;
        \\    if (opts.cc) body.cc = Array.isArray(opts.cc) ? opts.cc : [opts.cc];
        \\    if (opts.bcc) body.bcc = Array.isArray(opts.bcc) ? opts.bcc : [opts.bcc];
        \\    const env = {
        \\      url: "https://api.resend.com/emails",
        \\      method: "POST",
        \\      headers: {
        \\        "Authorization": "Bearer " + opts.key,
        \\        "Content-Type": "application/json",
        \\      },
        \\      body: JSON.stringify(body),
        \\    };
        \\    if (opts.onResult) env.onResult = opts.onResult;
        \\    if (opts.context !== undefined) env.context = opts.context;
        \\    if (opts.maxAttempts) env.maxAttempts = opts.maxAttempts;
        \\    if (opts.timeout) env.timeout = opts.timeout;
        \\    return webhook.send(env);
        \\  },
        \\};
    ;
    const email_result = c.JS_Eval(
        ctx,
        email_snippet.ptr,
        email_snippet.len,
        "email.js",
        c.JS_EVAL_TYPE_GLOBAL,
    );
    c.JS_FreeValue(ctx, email_result);

    // TextEncoder / TextDecoder — UTF-8 only. QuickJS-ng doesn't
    // expose a native intrinsic for these, so we install a minimal
    // JS polyfill. Sufficient for the common use cases: hashing a
    // UTF-8 string, building a Uint8Array body for webhook.send,
    // decoding a webhook response back to a string. NOT feature-
    // complete — doesn't handle streaming or the replacement
    // character on malformed input; handlers that need fidelity
    // against adversarial input should check their bytes.
    const textcodec_snippet =
        \\(function () {
        \\  class TextEncoder {
        \\    get encoding() { return "utf-8"; }
        \\    encode(input) {
        \\      const s = String(input ?? "");
        \\      const out = [];
        \\      for (let i = 0; i < s.length; i++) {
        \\        let cp = s.charCodeAt(i);
        \\        if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
        \\          const low = s.charCodeAt(i + 1);
        \\          if (low >= 0xdc00 && low <= 0xdfff) {
        \\            cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
        \\            i++;
        \\          }
        \\        }
        \\        if (cp < 0x80) {
        \\          out.push(cp);
        \\        } else if (cp < 0x800) {
        \\          out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
        \\        } else if (cp < 0x10000) {
        \\          out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        \\        } else {
        \\          out.push(
        \\            0xf0 | (cp >> 18),
        \\            0x80 | ((cp >> 12) & 0x3f),
        \\            0x80 | ((cp >> 6) & 0x3f),
        \\            0x80 | (cp & 0x3f),
        \\          );
        \\        }
        \\      }
        \\      return new Uint8Array(out);
        \\    }
        \\  }
        \\  class TextDecoder {
        \\    constructor(label, options) {
        \\      const enc = String(label ?? "utf-8").toLowerCase();
        \\      if (enc !== "utf-8" && enc !== "utf8") {
        \\        throw new RangeError("TextDecoder: only utf-8 is supported");
        \\      }
        \\      this._fatal = !!(options && options.fatal);
        \\    }
        \\    get encoding() { return "utf-8"; }
        \\    decode(buffer) {
        \\      if (buffer === undefined || buffer === null) return "";
        \\      let bytes;
        \\      if (buffer instanceof Uint8Array) {
        \\        bytes = buffer;
        \\      } else if (ArrayBuffer.isView(buffer)) {
        \\        bytes = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
        \\      } else if (buffer instanceof ArrayBuffer) {
        \\        bytes = new Uint8Array(buffer);
        \\      } else {
        \\        throw new TypeError("TextDecoder.decode: expected BufferSource");
        \\      }
        \\      let s = "";
        \\      let i = 0;
        \\      while (i < bytes.length) {
        \\        const b = bytes[i++];
        \\        if (b < 0x80) {
        \\          s += String.fromCharCode(b);
        \\        } else if ((b & 0xe0) === 0xc0 && i < bytes.length) {
        \\          const b2 = bytes[i++];
        \\          s += String.fromCharCode(((b & 0x1f) << 6) | (b2 & 0x3f));
        \\        } else if ((b & 0xf0) === 0xe0 && i + 1 < bytes.length) {
        \\          const b2 = bytes[i++], b3 = bytes[i++];
        \\          s += String.fromCharCode(((b & 0x0f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f));
        \\        } else if ((b & 0xf8) === 0xf0 && i + 2 < bytes.length) {
        \\          const b2 = bytes[i++], b3 = bytes[i++], b4 = bytes[i++];
        \\          let cp = ((b & 0x07) << 18) | ((b2 & 0x3f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f);
        \\          cp -= 0x10000;
        \\          s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        \\        } else if (this._fatal) {
        \\          throw new TypeError("TextDecoder: malformed utf-8");
        \\        } else {
        \\          s += "�";
        \\        }
        \\      }
        \\      return s;
        \\    }
        \\  }
        \\  globalThis.TextEncoder = TextEncoder;
        \\  globalThis.TextDecoder = TextDecoder;
        \\})();
    ;
    const textcodec_result = c.JS_Eval(
        ctx,
        textcodec_snippet.ptr,
        textcodec_snippet.len,
        "textcodec.js",
        c.JS_EVAL_TYPE_GLOBAL,
    );
    c.JS_FreeValue(ctx, textcodec_result);

    // platform = { root: { get, set, delete, prefix }, instances:
    // { create } }. Installed on every context; the C callbacks
    // check `state.platform` and throw for non-admin handlers.
    // See `jsPlatformRoot*` and `jsPlatformInstancesCreate`.
    const platform_obj = c.JS_NewObject(ctx);
    const root_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, root_obj, "get", c.JS_NewCFunction2(ctx, jsPlatformRootGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, root_obj, "set", c.JS_NewCFunction2(ctx, jsPlatformRootSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, root_obj, "delete", c.JS_NewCFunction2(ctx, jsPlatformRootDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, root_obj, "prefix", c.JS_NewCFunction2(ctx, jsPlatformRootPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, platform_obj, "root", root_obj);
    const instances_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, instances_obj, "create", c.JS_NewCFunction2(ctx, jsPlatformInstancesCreate, "create", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, instances_obj, "deployStarter", c.JS_NewCFunction2(ctx, jsPlatformInstancesDeployStarter, "deployStarter", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, platform_obj, "instances", instances_obj);
    _ = c.JS_SetPropertyStr(ctx, global, "platform", platform_obj);
}

/// Install the per-request pieces of the global surface: attach
/// `state` as the context opaque, and create `request`/`response`
/// globals populated from the incoming request. Called AFTER
/// `Snapshot.restore` on every request. Cheap — just a handful of
/// `JS_SetPropertyStr` calls.
pub fn installRequest(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    c.JS_SetContextOpaque(ctx, state);

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // request = { method, path, body, query, headers, cookies }
    //
    // `query` is the raw URL query string (everything after `?`) or
    // null when the URL had none. Parsing is the handler's job —
    // QuickJS-ng doesn't ship `URL` / `URLSearchParams`, and a
    // manual `split("&").reduce(...)` is a few lines in the
    // handler. If customer demand for `URLSearchParams` shows up,
    // it can land as another polyfill alongside TextEncoder.
    //
    // `headers` is a flat object, lowercase keys per HTTP/2.
    // Pseudo-headers (`:method`, `:path`, `:scheme`, `:authority`)
    // are filtered out — they're already exposed as `request.method`
    // / `request.path` etc. Multiple headers with the same name
    // comma-join (HTTP-standard fold).
    //
    // `cookies` is a parsed `{name: value}` from the `cookie` header,
    // RFC 6265 semicolon-separated. Empty / no-cookie → `{}`.
    const req_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, req_obj, "method", c.JS_NewStringLen(ctx, request.method.ptr, request.method.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "path", c.JS_NewStringLen(ctx, request.path.ptr, request.path.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "host", c.JS_NewStringLen(ctx, request.host.ptr, request.host.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "body", c.JS_NewStringLen(ctx, request.body.ptr, request.body.len));
    if (request.query) |q| {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", c.JS_NewStringLen(ctx, q.ptr, q.len));
    } else {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", js_null);
    }
    installHeaders(ctx, state, req_obj, request.headers);
    _ = c.JS_SetPropertyStr(ctx, global, "request", req_obj);

    // response = { status: 200, headers: {}, cookies: [] }
    //
    // Response body comes from the exported function's return value —
    // not from `response.body`. The `response` global is ONLY for
    // metadata: status, custom headers, and Set-Cookie entries.
    // Handlers mutate these freely; the dispatcher reads them after
    // the call and merges with the JSON-serialized return value.
    const resp_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "status", c.JS_NewInt32(ctx, 200));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "headers", c.JS_NewObject(ctx));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "cookies", c.JS_NewArray(ctx));
    _ = c.JS_SetPropertyStr(ctx, global, "response", resp_obj);
}

/// Build `request.headers` (flat lowercase object, pseudo-headers
/// filtered) and `request.cookies` (parsed from the `cookie:` header)
/// onto `req_obj`. Last-write-wins on duplicate header names — HTTP/2
/// clients SHOULD coalesce duplicates and most do; if a real customer
/// hits a producer that doesn't, we revisit.
fn installHeaders(
    ctx: *c.JSContext,
    state: *DispatchState,
    req_obj: c.JSValue,
    hdrs_opt: ?h2.ReqHeaders,
) void {
    const headers_obj = c.JS_NewObject(ctx);
    const cookies_obj = c.JS_NewObject(ctx);

    var cookie_value: []const u8 = "";

    if (hdrs_opt) |hdrs| if (hdrs.fields) |fields_ptr| {
        const fields = fields_ptr[0..hdrs.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];

            // Skip pseudo-headers (`:method`, `:path`, `:scheme`,
            // `:authority`). They're already exposed as
            // `request.method` / `request.path` etc.
            if (name.len > 0 and name[0] == ':') continue;

            // NUL-terminate name for JS_SetPropertyStr.
            const name_z = state.allocator.allocSentinel(u8, name.len, 0) catch continue;
            defer state.allocator.free(name_z);
            @memcpy(name_z, name);

            _ = c.JS_SetPropertyStr(
                ctx,
                headers_obj,
                name_z.ptr,
                c.JS_NewStringLen(ctx, value.ptr, value.len),
            );

            // Stash the cookie header for parseCookies below. If the
            // wire has multiple Cookie headers (RFC 7230 says clients
            // SHOULD send one) we take the last; this is consistent
            // with the last-write-wins rule above.
            if (std.mem.eql(u8, name, "cookie")) {
                cookie_value = value;
            }
        }
    };

    parseCookies(ctx, state, cookies_obj, cookie_value);

    _ = c.JS_SetPropertyStr(ctx, req_obj, "headers", headers_obj);
    _ = c.JS_SetPropertyStr(ctx, req_obj, "cookies", cookies_obj);
}

/// RFC 6265 cookie-string parser: semicolon-separated `name=value`
/// pairs, optional whitespace around the separator. Sets each into
/// `cookies_obj` as a string property. Empty `cookie_value` → no-op.
fn parseCookies(
    ctx: *c.JSContext,
    state: *DispatchState,
    cookies_obj: c.JSValue,
    cookie_value: []const u8,
) void {
    if (cookie_value.len == 0) return;

    var it = std.mem.splitScalar(u8, cookie_value, ';');
    while (it.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        // Trim whitespace from the value too. RFC 6265 strictly only
        // trims when parsing Set-Cookie, but every practical Cookie
        // parser (browsers, Express, Hono) trims both sides — matches
        // customer expectations.
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (name.len == 0) continue;

        const name_z = state.allocator.allocSentinel(u8, name.len, 0) catch continue;
        defer state.allocator.free(name_z);
        @memcpy(name_z, name);

        _ = c.JS_SetPropertyStr(
            ctx,
            cookies_obj,
            name_z.ptr,
            c.JS_NewStringLen(ctx, value.ptr, value.len),
        );
    }
}

/// Back-compat wrapper: install everything at once. Used by tests and
/// by any caller that doesn't have a pre-built snapshot to restore
/// from (e.g. the rove-files compile-on-upload path that just needs a
/// throwaway context to compile JS to bytecode).
pub fn install(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    installStatic(ctx);
    installRequest(ctx, state, request);
}
