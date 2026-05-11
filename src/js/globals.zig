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
const schedule_server = @import("rove-schedule-server");
const limiter_mod = @import("limiter.zig");
const sse_dispatch = @import("sse_dispatch.zig");
const crypto_b = @import("bindings/crypto.zig");
const email_rate_b = @import("bindings/email_rate.zig");
const events_b = @import("bindings/events.zig");
const http_b = @import("bindings/http.zig");
const td = @import("trigger_dispatch.zig");
const reserved = @import("reserved.zig");


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
pub const js_true: c.JSValue = mkVal(c.JS_TAG_BOOL, 1);
pub const js_false: c.JSValue = mkVal(c.JS_TAG_BOOL, 0);

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
    /// Per-request module-resolution tape — see Request.module_tape.
    /// Read by the QuickJS module loader (dispatcher.module_loader.load)
    /// to capture each successful import as `(specifier, source_hash)`.
    module_tape: ?*tape_mod.Tape = null,
    /// PRNG used by our `Math.random` override so the test path and
    /// production path stay deterministic w.r.t. a given seed. Seeded
    /// by the dispatcher per request. Installed only when a tape is
    /// present (so the normal path still uses qjs's built-in Math.random).
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    /// Per-request identifier, pre-minted by the worker. Combined with
    /// `http_call_index` to derive a deterministic schedule id for
    /// every `http.send` this handler invocation performs.
    request_id: u64 = 0,
    /// 0-based counter of `http.send` calls within this handler
    /// invocation. Resets per request. Combined with `request_id`
    /// to derive the platform-default schedule id (sha256(req_id ||
    /// call_index)) when the customer didn't supply a `handle`.
    http_call_index: u32 = 0,
    /// 0-based counter of `events.emit` calls within this handler
    /// invocation. Resets per request. Combined with `request_id`
    /// to derive the SSE wire id (`{request_id:020d}-{call_index:06d}`)
    /// so replays produce the same ids and lexical sort = numeric sort.
    /// One emit increments by one regardless of fan-out cardinality
    /// (`{to: [a, b, c]}` is one emit, three writes — all share the
    /// same wire id).
    events_call_index: u32 = 0,
    /// Resolved session id (see `Request.session_id`). 64 lowercase hex
    /// chars when set; null in non-browser dispatch paths. Surfaced as
    /// `request.session = {id: ...}` (or `request.session = null`).
    session_id: ?[64]u8 = null,
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
    /// Per-batch http.send accumulator (docs/http-send-plan.md §1).
    /// `http.send` appends a `ScheduleRow` here; `worker_dispatch.
    /// finalizeBatch` proposes envelope-8 (schedule_upsert) alongside
    /// envelope-0 (writeset) in a multi-envelope after raft commits.
    /// Owned by `dispatchOnce`, freed by its `defer` regardless of
    /// which exit path the batch takes. Optional purely so the
    /// dispatcher's standalone test paths (which don't allocate the
    /// list) can leave it null; production worker code always sets
    /// it non-null.
    pending_schedules: ?*std.ArrayListUnmanaged(schedule_server.ScheduleRow) = null,
    /// Per-batch http.cancel accumulator. `http.cancel` appends a
    /// `CancelTarget`; `finalizeBatch` proposes envelope-10 alongside
    /// the writeset.
    pending_cancels: ?*std.ArrayListUnmanaged(schedule_server.CancelTarget) = null,
    /// Per-batch SSE emit accumulator (sse-plan §3.2). `events.emit`
    /// appends an entry here as it runs; `worker_dispatch.finalizeBatch`
    /// hands the merged list to `sse_dispatch.fireBatch` after raft
    /// acks, fire-and-forget. Owned by `worker_dispatch.dispatchOnce`;
    /// rows' `[]u8` fields are allocator-owned strings freed on the
    /// list's `EmitEntry.deinit`. Optional so the dispatcher's standalone
    /// test paths can leave it null and skip the POST path.
    emit_buffer: ?*std.ArrayListUnmanaged(sse_dispatch.EmitEntry) = null,
    /// Per-worker rate limiter. Used by the `__rove_check_email_rate`
    /// builtin (called from the `email.send` JS wrapper) to take
    /// from the email bucket before queuing the webhook row. Null in
    /// test paths that don't care.
    limiter: ?*limiter_mod.RateLimiter = null,
    /// Instance id for limiter lookup. Empty when the dispatcher
    /// runs without a worker (test paths).
    instance_id: []const u8 = "",
    /// Trampoline backing `platform.instances.deployStarter(name)`.
    /// Worker provides a concrete fn that can cast `ctx` back to
    /// its specific `*Worker(opts)` type, deploys the embedded
    /// starter content into the target tenant's manifest_backend,
    /// and proposes `_deploy/current = 1` through raft envelope 0.
    /// Null on test paths without a worker; the JS callable throws
    /// a clear error in that case.
    deploy_starter: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) anyerror!void = null,
    deploy_starter_ctx: ?*anyopaque = null,

    /// Trampoline backing `platform.releases.publish(tenant_id,
    /// dep_id)`. Stamps `_deploy/current = dep_id` on the target
    /// tenant's app.db, proposes envelope-0 through raft (fire-
    /// and-forget — does not block on consensus), and enqueues
    /// the deployment loader so it starts fetching dep_id's
    /// manifest + bytecodes immediately. The customer-visible
    /// effect: a release POST returns in <10ms after one local
    /// fsync + two queue inserts. Raft consensus + bytecode
    /// load happen async. Null on test paths without a worker;
    /// the JS callable throws.
    release_publish: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
        dep_id: u64,
    ) anyerror!void = null,
    release_publish_ctx: ?*anyopaque = null,

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

/// Throw `Error{message: "...", code: "reserved_key"}` for a customer
/// `kv.set` / `kv.delete` against a platform-reserved namespace. Same
/// shape as the `rate_limited` error from `email.send` so customer
/// JS can branch on `err.code`.
fn throwReservedKey(ctx: ?*c.JSContext, key: []const u8) c.JSValue {
    const state = getState(ctx);
    const msg = std.fmt.allocPrintSentinel(
        state.allocator,
        "kv: '{s}' is in a platform-reserved prefix",
        .{key},
        0,
    ) catch return c.JS_ThrowOutOfMemory(ctx);
    defer state.allocator.free(msg);

    const err = c.JS_NewError(ctx);
    if (c.JS_IsException(err)) return err;
    _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
    _ = c.JS_SetPropertyStr(ctx, err, "code", c.JS_NewStringLen(ctx, "reserved_key", "reserved_key".len));
    return c.JS_Throw(ctx, err);
}

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

    // Reject writes into platform-reserved namespaces. Platform writers
    // (http.send → pending_schedules accumulator, events.emit →
    // _events/, etc.) bypass jsKvSet and write through state.txn /
    // state.writeset directly (or the per-batch schedule list), so
    // this guard only fires when customer JS tries to spoof a
    // platform key.
    if (reserved.isCustomerWriteReserved(key_str)) {
        return throwReservedKey(ctx, key_str);
    }

    // Fast path: no triggers match → write directly, no savepoint, no
    // previousValue lookup, no chain machinery. Same cost as before
    // triggers existed.
    if (!td.anyTriggerMatches(state, key_str)) {
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
    if (td.runBeforeChain(state, ctx, key_str, .put, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    const write_value: []const u8 = cur_value.?;

    state.txn.put(key_str, write_value) catch |err| {
        state.pending_kv_error = err;
        td.rollbackInnerSavepoint(state);
        if (state.kv_tape) |t| t.appendKv(.set, key_str, write_value, .err) catch {};
        return js_undefined;
    };
    state.writeset.addPut(key_str, write_value) catch |err| {
        state.pending_kv_error = err;
    };
    if (state.kv_tape) |t| t.appendKv(.set, key_str, write_value, .ok) catch {};

    if (td.runAfterChain(state, ctx, key_str, .put, write_value, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
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

    // Same reserved-namespace guard as jsKvSet — see the comment there.
    if (reserved.isCustomerWriteReserved(key_str)) {
        return throwReservedKey(ctx, key_str);
    }

    // Fast path mirrors jsKvSet — no triggers means no savepoint, no
    // previousValue lookup, no chain machinery.
    if (!td.anyTriggerMatches(state, key_str)) {
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
    if (td.runBeforeChain(state, ctx, key_str, .delete, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.delete(key_str) catch |err| {
        state.pending_kv_error = err;
        td.rollbackInnerSavepoint(state);
        if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .err) catch {};
        return js_undefined;
    };
    state.writeset.addDelete(key_str) catch |err| {
        state.pending_kv_error = err;
    };
    if (state.kv_tape) |t| t.appendKv(.delete, key_str, "", .ok) catch {};

    if (td.runAfterChain(state, ctx, key_str, .delete, null, prev_owned)) |trigger_path| {
        td.rollbackInnerSavepoint(state);
        return td.rethrowAsTriggerRejected(state, ctx, trigger_path);
    }

    state.txn.release() catch |err| {
        state.pending_kv_error = err;
    };
    return js_undefined;
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
/// Tape-captured via `appendKvPrefix` — the captured entry holds the
/// inputs (prefix/cursor/limit) AND the full result list, so the
/// replay shell's `kv.prefix` stub can return the same rows without
/// reaching live KV state.
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
        // Capture the failure path too — replay needs to surface the
        // same null return, otherwise a defensive `if (page === null)`
        // branch in the handler would diverge.
        if (state.kv_tape) |t| t.appendKvPrefix(prefix_str, cursor_str, limit, &.{}, .err) catch {};
        return js_null;
    };
    defer scan.deinit();

    if (state.kv_tape) |t| {
        // Convert `kv.PrefixScan.entries` (rove-kv's shape) into the
        // tape's `KvPair`s. Both are the same `(key, value)` pair, but
        // they belong to different modules so we materialize the
        // bridge on the stack. `appendKvPrefix` dups everything into
        // tape storage, so the lifetime of `pairs` and `scan` doesn't
        // need to extend past this call.
        var stack_pairs: [256]tape_mod.KvPair = undefined;
        const heap_pairs: ?[]tape_mod.KvPair = if (scan.entries.len <= stack_pairs.len)
            null
        else
            state.allocator.alloc(tape_mod.KvPair, scan.entries.len) catch null;
        defer if (heap_pairs) |h| state.allocator.free(h);
        const pairs: []tape_mod.KvPair = if (heap_pairs) |h| h else stack_pairs[0..scan.entries.len];
        for (scan.entries, 0..) |e, i| {
            pairs[i] = .{ .key = e.key, .value = e.value };
        }
        t.appendKvPrefix(prefix_str, cursor_str, limit, pairs, .ok) catch {};
    }

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

/// `platform.auth.checkRootToken(token_hex)` — admin-only.
/// Returns `true` iff `token_hex` matches the operator-supplied
/// root token (read from `LOOP46_ROOT_TOKEN` at worker startup).
/// Constant-time compare via `tenant.authenticate`. JS handler uses
/// this from `/v1/login` so the secret never crosses into JS state
/// or the SQLite root store.
fn jsPlatformAuthCheckRootToken(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return js_false;
    const state = getState(ctx);
    const tenant = state.platform orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    };

    const token = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(token);

    const auth = tenant.authenticate(token) catch |err| {
        state.pending_kv_error = err;
        return js_false;
    };
    return if (auth != null) js_true else js_false;
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
/// into the target instance's `file-blobs/` + writes a manifest
/// JSON to `deployments/`, then proposes `_deploy/current = 1`
/// through raft so followers see the active deployment.
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

/// `platform.releases.publish(tenant_id, dep_id)` — admin-only.
/// Stamps `_deploy/current = hex(dep_id)` on the target tenant's
/// app.db, proposes envelope-0 through raft (no spin / no
/// blocking on consensus), and enqueues the deployment loader
/// so it starts fetching dep_id's manifest + bytecodes
/// immediately. Returns `undefined` once the local commit +
/// raft queue insert + loader enqueue are done — typically
/// sub-millisecond.
///
/// Customer-visible effect: a release POST returns in <10ms.
/// Raft consensus + bytecode load run async on the background
/// loader + raft threads. Eventually (SSE work — future) the
/// customer gets a completion event.
///
/// Throws `Error{code:"InstanceNotFound"}` when `tenant_id`
/// doesn't resolve. Throws `TypeError` when called outside an
/// admin handler.
fn jsPlatformReleasesPublish(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 2) {
        _ = c.JS_ThrowTypeError(ctx, "platform.releases.publish requires (tenant_id, dep_id)");
        return js_exception;
    }
    const state = getState(ctx);
    if (state.platform == null) {
        _ = c.JS_ThrowTypeError(ctx, "platform is only available on the admin handler");
        return js_exception;
    }
    const fn_ptr = state.release_publish orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.releases.publish is not configured on this worker");
        return js_exception;
    };
    const fn_ctx = state.release_publish_ctx orelse {
        _ = c.JS_ThrowTypeError(ctx, "platform.releases.publish context missing");
        return js_exception;
    };

    const tenant_id = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(tenant_id);

    var dep_id_f64: f64 = 0;
    if (c.JS_ToFloat64(ctx, &dep_id_f64, argv[1]) < 0) return js_exception;
    if (dep_id_f64 < 1 or dep_id_f64 > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        _ = c.JS_ThrowRangeError(ctx, "platform.releases.publish: dep_id must be a positive integer");
        return js_exception;
    }
    const dep_id: u64 = @intFromFloat(dep_id_f64);

    fn_ptr(fn_ctx, state.allocator, tenant_id, dep_id) catch |err| switch (err) {
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

    // Build the fresh-namespace tree (kv, console, crypto, webhook,
    // platform/...). For nested paths the parent must already exist
    // as a JSObject, so STATIC_NAMESPACES is ordered parent-before-
    // child — the empty `platform` entry creates the holder before
    // platform.root and platform.instances populate it.
    for (STATIC_NAMESPACES) |ns| installNamespace(ctx, global, ns);

    // Extend existing intrinsics. Skipped if the intrinsic isn't
    // installed in this runtime (Dispatcher.snapshotInitFn keeps
    // the intrinsic-add minimal). Tape capture is gated on a non-
    // null DispatchState tape, so the API is stable whether we're
    // capturing or not.
    for (INTRINSIC_EXTENSIONS) |ns| extendIntrinsic(ctx, global, ns);

    // Globals attached directly to globalThis with no namespace.
    for (GLOBAL_BUILTINS) |fb| attachFn(ctx, global, fb);

    // JS-side wrappers/polyfills evaluated last so they can call
    // into the native bindings installed above. Order matters
    // because some snippets depend on globals other snippets
    // install:
    //   - textcodec.js: TextEncoder/TextDecoder. Used by base64.js
    //     + urlsearchparams.js for UTF-8 byte handling.
    //   - base64.js: atob/btoa, globalThis.base64url, globalThis.hex.
    //   - urlsearchparams.js: URLSearchParams class.
    //   - retry.js: customer-side retry helper on http.send.
    //   - webhook.js: legacy webhook.send shim on http.send.
    //   - email.js: Resend wrapper that calls webhook.send (the shim).
    evalSnippet(ctx, "textcodec.js", TEXTCODEC_JS);
    evalSnippet(ctx, "base64.js", BASE64_JS);
    evalSnippet(ctx, "urlsearchparams.js", URLSEARCHPARAMS_JS);
    // jwt depends on base64 + crypto.verifyRsa/Ecdsa.
    evalSnippet(ctx, "jwt.js", JWT_JS);
    // oauth depends on base64 + crypto + URLSearchParams.
    evalSnippet(ctx, "oauth.js", OAUTH_JS);
    // sessions is standalone (kv + crypto.randomUUID + cookie parsing).
    evalSnippet(ctx, "sessions.js", SESSIONS_JS);
    // cron is standalone.
    evalSnippet(ctx, "cron.js", CRON_JS);
    evalSnippet(ctx, "retry.js", RETRY_JS);
    evalSnippet(ctx, "webhook.js", WEBHOOK_JS);
    evalSnippet(ctx, "email.js", EMAIL_JS);
}

const NativeFn = *const fn (
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue;

const FnBinding = struct {
    name: [:0]const u8,
    cfunc: NativeFn,
    argc: c_int,
};

const NamespaceBindings = struct {
    /// Path under globalThis. Non-empty. Multi-element paths require
    /// their parent path to appear earlier in STATIC_NAMESPACES.
    path: []const [:0]const u8,
    fns: []const FnBinding,
};

const STATIC_NAMESPACES = [_]NamespaceBindings{
    .{ .path = &.{"kv"}, .fns = &.{
        .{ .name = "get",    .cfunc = jsKvGet,    .argc = 1 },
        .{ .name = "set",    .cfunc = jsKvSet,    .argc = 2 },
        .{ .name = "delete", .cfunc = jsKvDelete, .argc = 1 },
        .{ .name = "prefix", .cfunc = jsKvPrefix, .argc = 3 },
    } },
    .{ .path = &.{"console"}, .fns = &.{
        .{ .name = "log", .cfunc = jsConsoleLog, .argc = 1 },
    } },
    // crypto. No crypto global in qjs-ng by default, so we fabricate
    // one. hmacSha256 is the vendor-neutral primitive for building
    // Stripe / Slack / AWS style signatures (PLAN §2.6); randomBytes +
    // sha256 are what admin's JS handler composes into magic-link /
    // session token mint and hash-at-rest.
    .{ .path = &.{"crypto"}, .fns = &.{
        .{ .name = "getRandomValues", .cfunc = crypto_b.jsCryptoGetRandomValues, .argc = 1 },
        .{ .name = "randomUUID",      .cfunc = crypto_b.jsCryptoRandomUuid,      .argc = 0 },
        .{ .name = "randomBytes",     .cfunc = crypto_b.jsCryptoRandomBytes,     .argc = 1 },
        .{ .name = "sha256",          .cfunc = crypto_b.jsCryptoSha256,          .argc = 1 },
        .{ .name = "hmacSha256",      .cfunc = crypto_b.jsCryptoHmacSha256,      .argc = 2 },
        // RSA-PKCS#1 v1.5 verify (RS256 / RS384 / RS512). Customer
        // composes JWT/OIDC verification on top — see retry.js +
        // base64url.* helpers.
        .{ .name = "verifyRsa",       .cfunc = crypto_b.jsCryptoVerifyRsa,       .argc = 4 },
        // ECDSA verify (ES256 / ES384 / ES512). Required for Sign in
        // with Apple, AWS Cognito on EC keys, etc. Sig is JWS raw
        // R||S concatenation (the binding converts to DER internally).
        .{ .name = "verifyEcdsa",     .cfunc = crypto_b.jsCryptoVerifyEcdsa,     .argc = 4 },
    } },
    // http.send / http.cancel — the platform's outbound HTTP
    // primitive (docs/http-send-plan.md). send appends a
    // ScheduleRow to the dispatcher's per-batch list and returns
    // an id; the leader-pinned scheduler thread reads schedules.db
    // and fires libcurl. cancel appends a CancelTarget to drop a
    // pending row. webhook.send + email.send polyfill on top
    // (see webhook.js + email.js).
    .{ .path = &.{"http"}, .fns = &.{
        .{ .name = "send",   .cfunc = http_b.jsHttpSend,   .argc = 1 },
        .{ .name = "cancel", .cfunc = http_b.jsHttpCancel, .argc = 1 },
    } },
    // events.emit. Writes _events/{sid}/{seq} rows in the handler tx;
    // the SSE pump (worker.zig) drives connected EventSource clients
    // off those rows. Cross-tenant integrity is structural — each
    // tenant's events live only in that tenant's app.db.
    .{ .path = &.{"events"}, .fns = &.{
        .{ .name = "emit", .cfunc = events_b.jsEventsEmit, .argc = 1 },
    } },
    // platform = { root, instances }. Installed on every context;
    // the C callbacks check `state.platform` and throw for non-admin
    // handlers.
    .{ .path = &.{"platform"}, .fns = &.{} },
    .{ .path = &.{ "platform", "root" }, .fns = &.{
        .{ .name = "get",    .cfunc = jsPlatformRootGet,    .argc = 1 },
        .{ .name = "set",    .cfunc = jsPlatformRootSet,    .argc = 2 },
        .{ .name = "delete", .cfunc = jsPlatformRootDelete, .argc = 1 },
        .{ .name = "prefix", .cfunc = jsPlatformRootPrefix, .argc = 3 },
    } },
    .{ .path = &.{ "platform", "instances" }, .fns = &.{
        .{ .name = "create",        .cfunc = jsPlatformInstancesCreate,        .argc = 1 },
        .{ .name = "deployStarter", .cfunc = jsPlatformInstancesDeployStarter, .argc = 1 },
    } },
    .{ .path = &.{ "platform", "releases" }, .fns = &.{
        .{ .name = "publish", .cfunc = jsPlatformReleasesPublish, .argc = 2 },
    } },
    .{ .path = &.{ "platform", "auth" }, .fns = &.{
        .{ .name = "checkRootToken", .cfunc = jsPlatformAuthCheckRootToken, .argc = 1 },
    } },
};

const INTRINSIC_EXTENSIONS = [_]NamespaceBindings{
    .{ .path = &.{"Date"}, .fns = &.{
        .{ .name = "now", .cfunc = jsDateNow, .argc = 0 },
    } },
    .{ .path = &.{"Math"}, .fns = &.{
        .{ .name = "random", .cfunc = jsMathRandom, .argc = 0 },
    } },
};

const GLOBAL_BUILTINS = [_]FnBinding{
    // Take from the email rate-limit bucket. Called from the
    // email.send JS wrapper before queuing the webhook row. Throws
    // Error{code:"rate_limited"} on exhaustion; no-op (returns
    // undefined) when state.limiter is null (test paths).
    .{ .name = "__rove_check_email_rate", .cfunc = email_rate_b.jsCheckEmailRate, .argc = 0 },
};

const BASE64_JS = @embedFile("base64_js");
const URLSEARCHPARAMS_JS = @embedFile("urlsearchparams_js");
const JWT_JS = @embedFile("jwt_js");
const OAUTH_JS = @embedFile("oauth_js");
const SESSIONS_JS = @embedFile("sessions_js");
const CRON_JS = @embedFile("cron_js");
const RETRY_JS = @embedFile("retry_js");
const WEBHOOK_JS = @embedFile("webhook_js");
const EMAIL_JS = @embedFile("email_js");
const TEXTCODEC_JS = @embedFile("textcodec_js");

fn installNamespace(ctx: *c.JSContext, global: c.JSValue, ns: NamespaceBindings) void {
    const leaf = c.JS_NewObject(ctx);
    for (ns.fns) |fb| attachFn(ctx, leaf, fb);

    // Walk to the parent of the leaf. parent starts as a fresh dup
    // so the same free-and-replace pattern works on iteration zero
    // and onwards.
    var parent = c.JS_DupValue(ctx, global);
    defer c.JS_FreeValue(ctx, parent);

    for (ns.path[0 .. ns.path.len - 1]) |seg| {
        const next = c.JS_GetPropertyStr(ctx, parent, seg.ptr);
        c.JS_FreeValue(ctx, parent);
        parent = next;
    }

    _ = c.JS_SetPropertyStr(ctx, parent, ns.path[ns.path.len - 1].ptr, leaf);
}

fn extendIntrinsic(ctx: *c.JSContext, global: c.JSValue, ns: NamespaceBindings) void {
    var target = c.JS_DupValue(ctx, global);
    defer c.JS_FreeValue(ctx, target);

    for (ns.path) |seg| {
        const next = c.JS_GetPropertyStr(ctx, target, seg.ptr);
        c.JS_FreeValue(ctx, target);
        target = next;
    }

    if (c.JS_IsUndefined(target)) return;

    for (ns.fns) |fb| attachFn(ctx, target, fb);
}

fn attachFn(ctx: *c.JSContext, target: c.JSValue, fb: FnBinding) void {
    _ = c.JS_SetPropertyStr(
        ctx,
        target,
        fb.name.ptr,
        c.JS_NewCFunction2(ctx, fb.cfunc, fb.name.ptr, fb.argc, c.JS_CFUNC_generic, 0),
    );
}

fn evalSnippet(ctx: *c.JSContext, name: [*:0]const u8, source: []const u8) void {
    const result = c.JS_Eval(ctx, source.ptr, source.len, name, c.JS_EVAL_TYPE_GLOBAL);
    c.JS_FreeValue(ctx, result);
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

    // request.session = {id: "<64hex>"} when the worker resolved a
    // session cookie (or freshly minted one) for this request, else
    // null. Customer JS branches on `request.session === null` for
    // the "called outside browser context" cases (callbacks, signup,
    // sim/dry-run). Eager mint on browser-facing handler invocations
    // means the null branch is rare in production handler code.
    if (state.session_id) |sid| {
        const session_obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, session_obj, "id", c.JS_NewStringLen(ctx, &sid, sid.len));
        _ = c.JS_SetPropertyStr(ctx, req_obj, "session", session_obj);
    } else {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "session", js_null);
    }

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
