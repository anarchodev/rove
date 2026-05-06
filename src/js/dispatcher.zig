//! `Dispatcher` — runs one JS handler against a request.
//!
//! Each `Dispatcher` owns a `qjs.Snapshot` (an arenajs dual-arena
//! runtime+context), built once at construction time with all static
//! rove-js globals installed in base (kv, console, crypto, Date.now
//! override, Math.random override). Per request, `run` calls
//! `snapshot.restore()` — one cursor-write reset of the request
//! arena (~9 ns) plus reseeding time/random — installs the
//! per-request `request`/`response` globals, and evaluates the
//! handler bytecode. Nothing allocated by the handler needs to be
//! freed; the next reset wipes the request arena. The base arena is
//! page-protected immortal: all per-request handlers on this thread
//! share it without copying.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const webhook_server = @import("rove-webhook-server");

const globals = @import("globals.zig");
const limiter_mod = @import("limiter.zig");
const c = qjs.c;

pub const DispatchError = error{
    JsException,
    /// A `kv.*` call raised an error that wasn't a plain NotFound. The
    /// underlying `KvError` is available on the dispatcher.
    KvFailed,
    OutOfMemory,
    /// qjs runtime/context construction failed.
    RuntimeCreateFailed,
    ContextCreateFailed,
    /// Handler exceeded its CPU / wall-clock budget and was interrupted
    /// via `JS_SetInterruptHandler`. Distinguished from `JsException` so
    /// the worker can feed the event into the penalty box / circuit
    /// breaker instead of treating it as a normal handler error.
    Interrupted,
};

/// Per-request execution budget. Handed to the QuickJS interrupt handler
/// via its opaque ctx pointer; the handler polls the deadline every ~256
/// bytecode ops and returns 1 when exceeded, causing qjs to throw an
/// uncatchable InternalError into the handler.
///
/// `deadline_ns` is wall-clock (monotonic), not CPU time — simpler, and
/// a runaway JS loop burns wall and CPU in lockstep anyway. Phase 4's
/// tape replay will want deterministic cutoff by `bytecode_op_count`
/// instead; leaving the field here now so the shape is forward-compat.
pub const Budget = struct {
    deadline_ns: i64,
    /// Incremented on every interrupt-handler tick. Not yet used; Phase
    /// 4 tape replay can clamp on this instead of the deadline so replay
    /// cuts off at the same logical point as the original run.
    tick_count: u64 = 0,

    pub const default_duration_ns: i64 = 10 * std.time.ns_per_ms;

    pub fn fromNow(duration_ns: i64) Budget {
        return .{ .deadline_ns = @as(i64, @intCast(std.time.nanoTimestamp())) + duration_ns };
    }
};

fn interruptHandler(_: ?*c.JSRuntime, opaque_ctx: ?*anyopaque) callconv(.c) c_int {
    const budget: *Budget = @ptrCast(@alignCast(opaque_ctx.?));
    budget.tick_count += 1;
    const now: i64 = @intCast(std.time.nanoTimestamp());
    return if (now >= budget.deadline_ns) 1 else 0;
}

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// Wire host (HTTP/2 `:authority`, or HTTP/1 `Host:`). Includes
    /// the `:port` segment when present — admin's JS handler uses
    /// it verbatim to build absolute magic-link URLs that work in
    /// both dev (`app.loop46.localhost:8198`) and prod
    /// (`app.loop46.me`). Empty when the worker dispatches without
    /// a wire request (test paths, internal callback dispatch).
    host: []const u8 = "",
    body: []const u8 = "",
    /// Query string (everything after `?` in the URL, not including
    /// the `?`). Null when the URL had none. Used by module handlers
    /// to find `?fn=<name>` when dispatching function calls, and
    /// available as `request.query` inside the handler.
    query: ?[]const u8 = null,
    /// Wire HTTP headers, lowercase per HTTP/2. Surfaced to JS as
    /// `request.headers` (flat object, pseudo-headers filtered) and
    /// `request.cookies` (parsed `cookie:` header). Null = none
    /// supplied (test paths that don't care).
    headers: ?h2.ReqHeaders = null,
    /// Per-worker rate limiter, plumbed through to DispatchState so
    /// the email-rate-check builtin can take from the email bucket.
    /// Null in test paths that don't exercise rate limiting.
    limiter: ?*limiter_mod.RateLimiter = null,
    /// Instance id this request scopes to. Used as the limiter's
    /// per-instance bucket key. Empty when the dispatcher runs
    /// outside a worker context (test paths).
    instance_id: []const u8 = "",
    /// Optional non-determinism tapes. When set, the matching source of
    /// handler non-determinism (`kv.*`, `Date.now`, `Math.random`,
    /// `crypto.getRandomValues` / `crypto.randomUUID`) is captured
    /// onto the tape so the worker can persist it via `TapeRefs.*_hex`
    /// and replay can re-drive the handler later. Tapes are owned by
    /// the caller, which tears them down after flushing the log
    /// record.
    kv_tape: ?*tape_mod.Tape = null,
    date_tape: ?*tape_mod.Tape = null,
    math_random_tape: ?*tape_mod.Tape = null,
    crypto_random_tape: ?*tape_mod.Tape = null,
    /// Module-resolution tape. Captures `(specifier, source_hash_hex)`
    /// for every `import` the handler resolves so the browser-side
    /// replay shell can fetch the same source bytes by hash and build
    /// an importmap mirroring the original deployment's module graph.
    module_tape: ?*tape_mod.Tape = null,
    /// PRNG seed for `Math.random` and `crypto.*`. Captured alongside
    /// the log record so replay can reconstruct the same stream
    /// (though the tapes themselves are what replay reads from — the
    /// seed is belt-and-suspenders for the "tape was dropped but seed
    /// survived" scenario).
    prng_seed: u64 = 0,
    /// Pre-minted per-request identifier. The dispatcher copies it
    /// onto `DispatchState` so `webhook.send` can derive a stable
    /// outbox id (`sha256(request_id || call_index)`) that matches on
    /// replay. Also used downstream so the log record and the outbox
    /// rows spawned by the request share the same id.
    request_id: u64 = 0,
    /// Resolved session id (`__Host-rove_sid` cookie value or freshly
    /// minted by the worker via `session.resolve`). 64 lowercase hex
    /// chars when set; null on dispatch paths with no browser context
    /// (callbacks, signup, sim/dry-run, internal admin tooling). The
    /// dispatcher copies the bytes into `DispatchState` and exposes
    /// them as `request.session.id` to JS handlers; null surfaces as
    /// `request.session === null` so handlers can branch on it.
    session_id: ?[64]u8 = null,
    /// Non-null on admin-tenant requests — points back at the
    /// `Tenant` so the JS globals can install `platform.root.*` for
    /// the admin handler. Every other tenant's request passes null
    /// and the callbacks reject.
    platform: ?*tenant_mod.Tenant = null,
    /// Collects `platform.root.*` writes made during this request.
    /// When non-null the admin handler's root writes go into both
    /// (a) root.db directly (for immediate read-your-writes) AND
    /// (b) this writeset (for the worker to propose through raft).
    /// Null means writes land locally only — fine for tests and
    /// single-node setups, not for multi-node correctness.
    root_writeset: ?*kv_mod.WriteSet = null,
    /// Trampoline for `platform.instances.deployStarter(name)`.
    /// Non-null on admin-tenant requests when the worker has a
    /// compile callback wired (signup/dev path). The pair (`fn`,
    /// `ctx`) lets the worker pass an opaque `*Worker(opts)`
    /// pointer + a concrete trampoline that knows how to cast it,
    /// without leaking the worker's generic type into globals.zig.
    deploy_starter: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) anyerror!void = null,
    deploy_starter_ctx: ?*anyopaque = null,
    /// Phase 5.5 (d). `webhook.send` appends a `WebhookRow` to this
    /// list; the dispatcher allocates it once per batch and proposes
    /// it as envelope 4 alongside envelope 0 in a multi-envelope at
    /// batch commit. Optional only because dispatcher-test paths can
    /// leave it null (the test helper allocates a local list); the
    /// production dispatcher always sets it non-null. `webhook.send`
    /// throws if it's null.
    pending_webhooks: ?*std.ArrayListUnmanaged(webhook_server.WebhookRow) = null,
};

/// One `(name, value)` pair extracted from the handler's
/// `response.headers` object. Both fields are owned allocator
/// slices; the outer `Response` frees them on `deinit`.
pub const ResponseHeader = struct {
    name: []u8,
    value: []u8,
};

pub const Response = struct {
    status: i32 = 200,
    body: []u8,
    /// Captured `console.log` output (one line per call, newline-terminated).
    console: []u8,
    /// Exception message if the script threw. Empty on success.
    exception: []u8,
    /// Already-sanitized Set-Cookie header values, one per entry the
    /// handler pushed onto `response.cookies`. Each string is an
    /// owned, filter-passed cookie with any `Domain=...` attribute
    /// stripped (see `sanitizeSetCookie`). Empty slice = no cookies.
    set_cookies: [][]u8 = &.{},
    /// Custom response headers the handler set via
    /// `response.headers = {name: value, ...}`. Names are already
    /// lowercased (HTTP/2 wire format) and vetted — pseudo-headers
    /// and hop-by-hop names are rejected in `extractResponseMetadata`.
    /// `set-cookie` specifically is NOT accepted here — cookies go
    /// through `response.cookies` so sanitization fires.
    headers: []ResponseHeader = &.{},
    /// True when the body came from `JSON.stringify(ret)` (i.e. the
    /// handler returned an object/array/number). The worker stamps
    /// `content-type: application/json` on the response when true, so
    /// browser clients can `res.json()` without guessing. Suppressed
    /// when the handler set a content-type via `response.headers`.
    body_is_json: bool = false,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.console);
        allocator.free(self.exception);
        for (self.set_cookies) |cookie| allocator.free(cookie);
        if (self.set_cookies.len > 0) allocator.free(self.set_cookies);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        self.* = undefined;
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    /// Per-dispatcher frozen runtime+context. Built once in `init`,
    /// the base arena is page-protected immortal; each `run` resets
    /// the per-request arena via a single cursor write before
    /// evaluating the handler.
    snapshot: qjs.Snapshot,
    /// Last `kv.*` error surfaced from a JS call during the most recent
    /// `run`. Useful for tests and for the worker to log root causes.
    last_kv_error: ?anyerror = null,

    fn snapshotInitFn(
        rt: *c.JSRuntime,
        ctx: *c.JSContext,
        _: ?*anyopaque,
    ) qjs.snap.Error!void {
        _ = rt;
        // Selective intrinsics keep the base arena small. With arenajs
        // there's no per-request memcpy cost (base is shared in place
        // across all requests), so the optimization is now about base
        // memory + freeze-time work, not per-request bandwidth.
        // Skipping WeakRef / DOMException / Proxy saves 20-30 KB with
        // essentially no loss — handlers that genuinely need them can
        // be added back.
        _ = c.JS_AddIntrinsicBaseObjects(ctx);
        _ = c.JS_AddIntrinsicDate(ctx);
        _ = c.JS_AddIntrinsicEval(ctx);
        _ = c.JS_AddIntrinsicRegExp(ctx);
        _ = c.JS_AddIntrinsicJSON(ctx);
        _ = c.JS_AddIntrinsicMapSet(ctx);
        _ = c.JS_AddIntrinsicTypedArrays(ctx);
        _ = c.JS_AddIntrinsicPromise(ctx);
        _ = c.JS_AddIntrinsicBigInt(ctx);
        globals.installStatic(ctx);
    }

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        const snapshot = try qjs.Snapshot.create(.{}, snapshotInitFn, null);
        return .{
            .allocator = allocator,
            .snapshot = snapshot,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.snapshot.deinit();
        self.* = undefined;
    }

    /// Run pre-compiled `bytecode` as a handler against `request`.
    /// Reads hit `kv` directly — the same SQLite connection the
    /// caller's `TrackedTxn` opened, so reads see the txn's own
    /// uncommitted writes. `kv.set`/`kv.delete` from the handler go
    /// through `txn` (local durability + undo) AND `writeset` (raft
    /// replication).
    ///
    /// The handler contract is shift-js-flavored RPC:
    ///   - `bytecode` MUST be an ES module with named function exports.
    ///     Non-module bytecode is a hard error (500).
    ///   - The caller picks an export by name (`?fn=X` on GET, or
    ///     `{fn:"X",args:[...]}` in the POST body).
    ///   - `args` is a JSON array spread into positional arguments.
    ///     Missing → `[]`. Malformed JSON → 400.
    ///   - The handler's **return value** becomes the response body
    ///     (strings emit as-is; everything else is `JSON.stringify`'d).
    ///   - Status / headers / cookies flow through the ambient
    ///     `response` global (`response.status = 404`, etc.). Body is
    ///     NOT settable via `response` — it always comes from return.
    ///
    /// `bytecodes` is the per-deployment map of path → bytecode bytes
    /// used by the module loader to resolve `import` statements the
    /// entry module pulls in. `null` is valid if the entry has no
    /// imports.
    pub fn run(
        self: *Dispatcher,
        kv: *kv_mod.KvStore,
        txn: *kv_mod.TrackedTxn,
        writeset: *kv_mod.WriteSet,
        bytecode: []const u8,
        bytecodes: ?*const std.StringHashMapUnmanaged([]u8),
        source_hashes: ?*const std.StringHashMapUnmanaged([64]u8),
        triggers: ?[]const globals.TriggerEntry,
        request: Request,
        budget: *Budget,
    ) DispatchError!Response {
        self.last_kv_error = null;

        var console_buf: std.ArrayList(u8) = .empty;
        errdefer console_buf.deinit(self.allocator);

        var state = globals.DispatchState{
            .allocator = self.allocator,
            .kv = kv,
            .txn = txn,
            .writeset = writeset,
            .console = &console_buf,
            .kv_tape = request.kv_tape,
            .date_tape = request.date_tape,
            .math_random_tape = request.math_random_tape,
            .crypto_random_tape = request.crypto_random_tape,
            .module_tape = request.module_tape,
            .prng = std.Random.DefaultPrng.init(request.prng_seed),
            .request_id = request.request_id,
            .session_id = request.session_id,
            .platform = request.platform,
            .root_writeset = request.root_writeset,
            .triggers = triggers,
            .bytecodes = bytecodes,
            .limiter = request.limiter,
            .instance_id = request.instance_id,
            .deploy_starter = request.deploy_starter,
            .deploy_starter_ctx = request.deploy_starter_ctx,
            .pending_webhooks = request.pending_webhooks,
        };

        // Reset the per-request arena (one cursor write) and reseed
        // time/random. The base arena (runtime, intrinsics, globals)
        // is shared in place across all requests on this thread —
        // no memcpy, no relocation.
        const restored = self.snapshot.restore();
        var rt: qjs.Runtime = restored.runtime;
        var ctx: qjs.Context = restored.context;
        // Free any trigger-module namespaces we cached during this
        // request. The request arena reset wipes the QJS-side state;
        // Zig-side hashmap entries (key + JSValue ref counts) need
        // explicit cleanup.
        defer state.deinit(ctx.raw);

        rt.setInterruptHandler(interruptHandler, budget);

        // Install the module loader for this request. Reads bytecode
        // for any `import` the handler performs from the deployment's
        // per-path map. Reinstalled per request so each request sees
        // its own tenant's bytecodes.
        var loader_ctx = module_loader.Ctx{
            .allocator = self.allocator,
            .bytecodes = bytecodes,
            .source_hashes = source_hashes,
            .module_tape = request.module_tape,
        };
        c.JS_SetModuleLoaderFunc(
            rt.raw,
            module_loader.normalize,
            module_loader.load,
            &loader_ctx,
        );

        globals.installRequest(ctx.raw, &state, request);

        var pending: PendingResponse = .{};
        errdefer pending.deinit(self.allocator);

        // Optional `_middlewares/index.mjs` runs before the handler
        // in the same QJS context. Mutations it makes to globalThis
        // — most usefully `request.auth = {...}` — persist into the
        // handler's call. If the middleware returns any non-undefined
        // value, the dispatcher short-circuits with that value as the
        // body and skips the handler. Return undefined / fall off the
        // end → continue.
        const mw_bytecode_opt: ?[]const u8 = blk: {
            if (bytecodes) |bcs| {
                if (bcs.get("_middlewares/index.mjs")) |bc| break :blk bc;
                if (bcs.get("_middlewares/index.js")) |bc| break :blk bc;
            }
            break :blk null;
        };
        if (mw_bytecode_opt) |mw_bc| {
            const mw_fun_val = (try loadModuleBytecode(&ctx, self.allocator, mw_bc, &pending,
                "_middlewares/index.mjs is not an ES module")) orelse
                return finishResponse(self, &state, &pending, &console_buf);
            runMiddleware(self, &rt, &ctx, mw_fun_val, budget, &pending) catch |err| switch (err) {
                error.Interrupted => return DispatchError.Interrupted,
                error.OutOfMemory => return DispatchError.OutOfMemory,
                error.JsException => pending.short_circuit = true,
            };
        }

        if (pending.short_circuit) {
            return finishResponse(self, &state, &pending, &console_buf);
        }

        const fun_val = (try loadModuleBytecode(&ctx, self.allocator, bytecode, &pending,
            "handler bytecode is not an ES module (.mjs)")) orelse
            return finishResponse(self, &state, &pending, &console_buf);

        runModule(self, &rt, &ctx, fun_val, request, budget, &pending) catch |err| switch (err) {
            error.Interrupted => return DispatchError.Interrupted,
            error.OutOfMemory => return DispatchError.OutOfMemory,
            error.JsException => {}, // pending.exception already populated
        };

        return finishResponse(self, &state, &pending, &console_buf);
    }
};

const RunError = error{ Interrupted, OutOfMemory, JsException };

/// Mutable response state accumulated across the dispatcher's run.
/// Bundled so the helpers and the run* functions take one pointer
/// instead of six out-params each. `finishResponse` consumes it
/// (cookies/headers via `toOwnedSlice`, body/exception via direct
/// transfer); on the error paths the caller's errdefer fires
/// `deinit` to free anything still owned here.
const PendingResponse = struct {
    status: i32 = 200,
    body: []u8 = &.{},
    body_is_json: bool = false,
    exception: []u8 = &.{},
    cookies: std.ArrayList([]u8) = .empty,
    headers: std.ArrayList(ResponseHeader) = .empty,
    /// Set by `runMiddleware` when the middleware returns a non-
    /// undefined/null value (or a malformed module) — the caller
    /// skips the handler and goes straight to `finishResponse`.
    short_circuit: bool = false,

    fn deinit(self: *PendingResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.exception);
        for (self.cookies.items) |c2| allocator.free(c2);
        self.cookies.deinit(allocator);
        for (self.headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        self.headers.deinit(allocator);
    }
};

/// Result of `JS_ReadObject` + module-tag validation. Returns `null`
/// when bytecode failed to load or wasn't an ES module — `pending`
/// has been populated with the appropriate exception/body and the
/// caller should fall through to `finishResponse`.
fn loadModuleBytecode(
    ctx: *qjs.Context,
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    pending: *PendingResponse,
    not_a_module_msg: []const u8,
) DispatchError!?qjs.Value {
    const obj = c.JS_ReadObject(ctx.raw, bytecode.ptr, bytecode.len, c.JS_READ_OBJ_BYTECODE);
    var val: qjs.Value = .{ .raw = obj, .ctx = ctx.raw };
    if (val.isException()) {
        pending.exception = ctx.takeExceptionMessage(allocator) catch
            return DispatchError.OutOfMemory;
        val.deinit();
        return null;
    }
    if (val.raw.tag != c.JS_TAG_MODULE) {
        val.deinit();
        pending.status = 500;
        pending.body = allocator.dupe(u8, not_a_module_msg) catch
            return DispatchError.OutOfMemory;
        return null;
    }
    return val;
}

/// Steps shared by middleware and handler module execution: evaluate
/// the module top level, drain microtasks, check for a rejected
/// top-level await, then materialize the namespace. Returns the
/// namespace JSValue; caller owns and must `JS_FreeValue` it.
/// `fun_val_in` is consumed by `JS_EvalFunction` — caller must not
/// reuse it after this call.
fn evalModule(
    d: *Dispatcher,
    rt: *qjs.Runtime,
    ctx: *qjs.Context,
    fun_val_in: qjs.Value,
    budget: *Budget,
    pending: *PendingResponse,
) RunError!c.JSValue {
    const mod_def_ptr: ?*c.JSModuleDef = @ptrCast(@alignCast(fun_val_in.raw.u.ptr));

    var fun_val = fun_val_in;
    const eval_result = c.JS_EvalFunction(ctx.raw, fun_val.raw);
    fun_val = undefined;
    var eval_val: qjs.Value = .{ .raw = eval_result, .ctx = ctx.raw };
    defer eval_val.deinit();

    if (eval_val.isException()) {
        pending.exception = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        if (budgetExpired(budget)) return error.Interrupted;
        return error.JsException;
    }

    rt.pumpJobs();
    if (budgetExpired(budget)) return error.Interrupted;

    if (c.JS_PromiseState(ctx.raw, eval_val.raw) == c.JS_PROMISE_REJECTED) {
        const reason = c.JS_PromiseResult(ctx.raw, eval_val.raw);
        defer c.JS_FreeValue(ctx.raw, reason);
        pending.exception = jsValueToOwned(d.allocator, ctx.raw, reason) catch
            return error.OutOfMemory;
        return error.JsException;
    }

    const ns = c.JS_GetModuleNamespace(ctx.raw, mod_def_ptr);
    if (c.JS_IsException(ns)) {
        pending.exception = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        return error.JsException;
    }
    return ns;
}

const UnwrappedCall = struct {
    val: c.JSValue,
    /// Caller must `JS_FreeValue` iff true (promise-fulfilled path
    /// returns a fresh ref; the not-a-promise path returns a borrow).
    owns: bool,
};

/// Steps shared by middleware-call and handler-call: check the call's
/// return value for a synchronous exception, drain jobs, then unwrap
/// the (possibly-promise) value. Throws `JsException` with `pending.
/// exception` populated on either failure mode.
fn awaitAndUnwrap(
    d: *Dispatcher,
    rt: *qjs.Runtime,
    ctx: *qjs.Context,
    ret_val: qjs.Value,
    budget: *Budget,
    pending: *PendingResponse,
) RunError!UnwrappedCall {
    if (ret_val.isException()) {
        pending.exception = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        if (budgetExpired(budget)) return error.Interrupted;
        return error.JsException;
    }

    rt.pumpJobs();
    if (budgetExpired(budget)) return error.Interrupted;

    const final = unwrapPromise(ctx.raw, ret_val.raw);
    if (final.rejected) {
        pending.exception = jsValueToOwned(d.allocator, ctx.raw, final.val) catch
            return error.OutOfMemory;
        c.JS_FreeValue(ctx.raw, final.val);
        return error.JsException;
    }
    return .{ .val = final.val, .owns = final.owns };
}

/// Populate `pending.body`/`body_is_json` from the handler's return
/// value, then read `pending.status`/`cookies`/`headers` from the
/// ambient `response` global.
fn extractBodyAndMeta(
    d: *Dispatcher,
    ctx: *qjs.Context,
    val: c.JSValue,
    pending: *PendingResponse,
) error{OutOfMemory}!void {
    try bodyFromReturn(d.allocator, ctx.raw, val, &pending.body, &pending.body_is_json);
    try extractResponseMetadata(d.allocator, ctx.raw, &pending.status, &pending.cookies, &pending.headers);
}

/// Run `_middlewares/index.mjs`'s `before` export. The middleware sees
/// the same `globalThis.request` / `globalThis.response` the handler
/// will see — its mutations (most usefully `request.auth = {...}`)
/// persist into the handler's call.
///
/// Return-value semantics differ from `runModule`:
/// - `undefined` / `null` → continue (no `short_circuit_out` set)
/// - any other value → short-circuit. Return value becomes the body
///   (same `bodyFromReturn` rules as a handler); status / cookies /
///   custom headers come from the response global, also like a
///   handler.
///
/// A throw or rejected promise sets `exception_out` and surfaces as
/// `error.JsException`; the caller treats that as a short-circuit
/// with whatever the response global says (typically 500).
///
/// Missing `before` export is treated as an operator-visible 500 —
/// admin's bundle declares it on purpose, and customer middlewares
/// that forget to export it deserve a loud failure.
fn runMiddleware(
    d: *Dispatcher,
    rt: *qjs.Runtime,
    ctx: *qjs.Context,
    fun_val_in: qjs.Value,
    budget: *Budget,
    pending: *PendingResponse,
) RunError!void {
    const ns = try evalModule(d, rt, ctx, fun_val_in, budget, pending);
    defer c.JS_FreeValue(ctx.raw, ns);

    const before_fn = c.JS_GetPropertyStr(ctx.raw, ns, "before");
    defer c.JS_FreeValue(ctx.raw, before_fn);
    if (c.JS_IsException(before_fn) or !c.JS_IsFunction(ctx.raw, before_fn)) {
        // No `before` export — surface as a 500 rather than silently
        // skipping. A malformed middleware should be loud.
        _ = ctx.takeException();
        pending.status = 500;
        pending.body = std.fmt.allocPrint(
            d.allocator,
            "_middlewares/index.mjs must export a `before` function\n",
            .{},
        ) catch return error.OutOfMemory;
        pending.short_circuit = true;
        return;
    }

    const ret = c.JS_Call(ctx.raw, before_fn, globals.js_undefined, 0, null);
    var ret_val: qjs.Value = .{ .raw = ret, .ctx = ctx.raw };
    defer ret_val.deinit();

    const result = try awaitAndUnwrap(d, rt, ctx, ret_val, budget, pending);
    defer if (result.owns) c.JS_FreeValue(ctx.raw, result.val);

    // Undefined / null → middleware passed; handler runs next. Any
    // mutations to globalThis.request and globalThis.response made
    // along the way persist via the shared QJS context.
    if (c.JS_IsUndefined(result.val) or c.JS_IsNull(result.val)) return;

    // Otherwise short-circuit: middleware's return value becomes the
    // body, response-global metadata applies as if it were a handler.
    extractBodyAndMeta(d, ctx, result.val, pending) catch
        return error.OutOfMemory;
    pending.short_circuit = true;
}

/// Evaluate the module top-level, drain jobs, look up `exports[fn]`
/// (fn picked via `?fn=X` on GET or `{fn,args}` JSON body on POST),
/// and call it with positional `args` spread in. The return value
/// becomes the response body; status/headers/cookies come from the
/// ambient `response` global. See `Dispatcher.run` for the full
/// contract.
fn runModule(
    d: *Dispatcher,
    rt: *qjs.Runtime,
    ctx: *qjs.Context,
    fun_val_in: qjs.Value,
    request: Request,
    budget: *Budget,
    pending: *PendingResponse,
) RunError!void {
    const ns = try evalModule(d, rt, ctx, fun_val_in, budget, pending);
    defer c.JS_FreeValue(ctx.raw, ns);

    // ── Resolve fn name + args JSON from the request. ─────────────
    var dispatch = parseDispatch(d.allocator, request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadRequest => {
            pending.status = 400;
            pending.body = std.fmt.allocPrint(d.allocator,
                "RPC envelope: `fn` must be a string and `args` must be an array\n", .{}) catch return error.OutOfMemory;
            return;
        },
    };
    defer dispatch.deinit(d.allocator);

    const fn_name_z = std.fmt.allocPrintSentinel(d.allocator, "{s}", .{dispatch.fn_name}, 0) catch
        return error.OutOfMemory;
    defer d.allocator.free(fn_name_z);

    const handler = c.JS_GetPropertyStr(ctx.raw, ns, fn_name_z.ptr);
    defer c.JS_FreeValue(ctx.raw, handler);
    if (c.JS_IsException(handler) or !c.JS_IsFunction(ctx.raw, handler)) {
        pending.status = 404;
        pending.body = std.fmt.allocPrint(
            d.allocator,
            "module export \"{s}\" not found or not a function\n",
            .{dispatch.fn_name},
        ) catch return error.OutOfMemory;
        return;
    }

    // Parse the args array as a single JSON value, then pull each
    // element by index. Cheaper than re-parsing per element, and
    // lets qjs handle all the nested-value construction in one pass.
    //
    // `JS_ParseJSON` (like `JS_Eval`) reads one byte past the
    // declared length for UTF-8 validation, so the source MUST be
    // NUL-terminated. Copy into an allocSentinel buffer.
    const args_text = dispatch.args_json_text;
    const args_text_z = d.allocator.allocSentinel(u8, args_text.len, 0) catch
        return error.OutOfMemory;
    defer d.allocator.free(args_text_z);
    @memcpy(args_text_z, args_text);
    const args_arr = c.JS_ParseJSON(
        ctx.raw,
        args_text_z.ptr,
        args_text.len,
        "<args>",
    );
    defer c.JS_FreeValue(ctx.raw, args_arr);
    if (c.JS_IsException(args_arr)) {
        pending.status = 400;
        pending.body = std.fmt.allocPrint(d.allocator, "args JSON parse failed\n", .{}) catch
            return error.OutOfMemory;
        _ = ctx.takeException();
        return;
    }
    const args_len_val = c.JS_GetPropertyStr(ctx.raw, args_arr, "length");
    defer c.JS_FreeValue(ctx.raw, args_len_val);
    var args_len: u32 = 0;
    _ = c.JS_ToUint32(ctx.raw, &args_len, args_len_val);

    const args_js = d.allocator.alloc(c.JSValue, args_len) catch
        return error.OutOfMemory;
    defer {
        for (args_js) |v| c.JS_FreeValue(ctx.raw, v);
        d.allocator.free(args_js);
    }
    var idx: u32 = 0;
    while (idx < args_len) : (idx += 1) {
        args_js[idx] = c.JS_GetPropertyUint32(ctx.raw, args_arr, idx);
    }

    const ret = c.JS_Call(
        ctx.raw,
        handler,
        globals.js_undefined,
        @intCast(args_js.len),
        if (args_js.len == 0) null else args_js.ptr,
    );
    var ret_val: qjs.Value = .{ .raw = ret, .ctx = ctx.raw };
    defer ret_val.deinit();

    const result = try awaitAndUnwrap(d, rt, ctx, ret_val, budget, pending);
    defer if (result.owns) c.JS_FreeValue(ctx.raw, result.val);

    // Body from return value. Status / cookies from the ambient
    // `response` global.
    extractBodyAndMeta(d, ctx, result.val, pending) catch
        return error.OutOfMemory;
}

/// Parsed `(fn, args)` from a request. `args_json_text` is a raw
/// JSON array literal (e.g. `[]`, `["foo", 42]`); the caller does
/// one `JS_ParseJSON` on it and spreads the elements into the
/// handler call.
const DispatchCall = struct {
    fn_name: []u8,
    args_json_text: []u8,

    fn deinit(self: *DispatchCall, allocator: std.mem.Allocator) void {
        allocator.free(self.fn_name);
        allocator.free(self.args_json_text);
        self.* = undefined;
    }
};

fn parseDispatch(
    allocator: std.mem.Allocator,
    request: Request,
) (error{ OutOfMemory, BadRequest })!DispatchCall {
    // RPC envelope path: a JSON-looking POST body whose top-level
    // object has `fn: string` (and optionally `args: array`). Anything
    // else — a non-JSON body, an array body, an object without `fn`,
    // or a parse failure — is treated as opaque payload and falls
    // through to the query-string path. The handler reads the raw
    // body via `request.body` in that case.
    if (request.body.len > 0 and looksLikeJson(request.body)) {
        if (std.json.parseFromSlice(
            std.json.Value,
            allocator,
            request.body,
            .{},
        )) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("fn")) |fn_val| {
                    if (fn_val != .string) return error.BadRequest;
                    const fn_owned = try allocator.dupe(u8, fn_val.string);
                    errdefer allocator.free(fn_owned);

                    const args_text = if (parsed.value.object.get("args")) |v| blk: {
                        if (v != .array) return error.BadRequest;
                        break :blk try jsonArrayToOwnedText(allocator, v.array.items);
                    } else try allocator.dupe(u8, "[]");

                    return .{ .fn_name = fn_owned, .args_json_text = args_text };
                }
            }
        } else |_| {}
    }

    // Query-string path: ?fn=name[&args=<urlencoded-json-array>].
    // Both optional. Missing or empty fn → "default" (PLAN §2.4: the
    // default export is the modern path, called with no arguments).
    const query = request.query orelse "";
    const fn_owned: []u8 = blk: {
        if (queryParam(query, "fn")) |s| {
            if (s.len > 0) break :blk try decodePercent(allocator, s);
        }
        break :blk try allocator.dupe(u8, "default");
    };
    errdefer allocator.free(fn_owned);

    const args_text: []u8 = blk: {
        if (queryParam(query, "args")) |s| {
            if (s.len > 0) break :blk try decodePercent(allocator, s);
        }
        break :blk try allocator.dupe(u8, "[]");
    };

    return .{ .fn_name = fn_owned, .args_json_text = args_text };
}

fn looksLikeJson(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) i += 1;
    return i < body.len and (body[i] == '{' or body[i] == '[');
}

/// Re-serialize a parsed `std.json.Value` array (POST body's `args`
/// field) back into compact JSON text. The returned buffer is a full
/// JSON array literal like `[1,"two",{"k":"v"}]` ready for one
/// `JS_ParseJSON` on the qjs side.
fn jsonArrayToOwnedText(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try stringifyJson(allocator, &buf, item);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

fn stringifyJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    v: std.json.Value,
) error{OutOfMemory}!void {
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| try writeJsonEscaped(allocator, buf, s),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try stringifyJson(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try writeJsonEscaped(allocator, buf, kv.key_ptr.*);
                try buf.append(allocator, ':');
                try stringifyJson(allocator, buf, kv.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

fn writeJsonEscaped(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) error{OutOfMemory}!void {
    try buf.append(allocator, '"');
    for (s) |b| switch (b) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0x08 => try buf.appendSlice(allocator, "\\b"),
        0x0C => try buf.appendSlice(allocator, "\\f"),
        0x00...0x07, 0x0B, 0x0E...0x1F => {
            var tmp: [6]u8 = undefined;
            const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{b}) catch unreachable;
            try buf.appendSlice(allocator, hex);
        },
        else => try buf.append(allocator, b),
    };
    try buf.append(allocator, '"');
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (std.mem.eql(u8, pair, name)) return "";
            continue;
        };
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn decodePercent(allocator: std.mem.Allocator, encoded: []const u8) error{OutOfMemory}![]u8 {
    var buf = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(buf);
    var w: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) {
        const b = encoded[i];
        if (b == '+') {
            buf[w] = ' ';
            w += 1;
            i += 1;
        } else if (b == '%' and i + 2 < encoded.len) {
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch {
                buf[w] = b;
                w += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch {
                buf[w] = b;
                w += 1;
                i += 1;
                continue;
            };
            buf[w] = (hi << 4) | lo;
            w += 1;
            i += 3;
        } else {
            buf[w] = b;
            w += 1;
            i += 1;
        }
    }
    return allocator.realloc(buf, w) catch buf[0..w];
}

fn budgetExpired(budget: *Budget) bool {
    const now: i64 = @intCast(std.time.nanoTimestamp());
    return now >= budget.deadline_ns;
}

const Unwrapped = struct {
    val: c.JSValue,
    rejected: bool,
    /// Caller is responsible for freeing `val` iff this is true (the
    /// promise-fulfilled path gives us a new reference).
    owns: bool,
};

fn unwrapPromise(ctx: *c.JSContext, v: c.JSValue) Unwrapped {
    const st = c.JS_PromiseState(ctx, v);
    if (st == c.JS_PROMISE_FULFILLED) {
        const r = c.JS_PromiseResult(ctx, v);
        return .{ .val = r, .rejected = false, .owns = true };
    }
    if (st == c.JS_PROMISE_REJECTED) {
        const r = c.JS_PromiseResult(ctx, v);
        return .{ .val = r, .rejected = true, .owns = true };
    }
    // Not a promise, or still pending (shouldn't happen after pumpJobs).
    return .{ .val = v, .rejected = false, .owns = false };
}

/// Convert the handler's return value to bytes:
///   - string       → raw string (no JSON quoting); `is_json_out` = false
///   - undefined/null → empty body; `is_json_out` = false
///   - anything else → `JSON.stringify(ret)`; `is_json_out` = true
fn bodyFromReturn(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    ret: c.JSValue,
    body_out: *[]u8,
    is_json_out: *bool,
) error{OutOfMemory}!void {
    is_json_out.* = false;
    if (c.JS_IsUndefined(ret) or c.JS_IsNull(ret)) return;
    if (c.JS_IsString(ret)) {
        body_out.* = jsValueToOwned(allocator, ctx, ret) catch return error.OutOfMemory;
        return;
    }
    // JSON.stringify via the C API.
    const json = c.JS_JSONStringify(ctx, ret, globals.js_undefined, globals.js_undefined);
    defer c.JS_FreeValue(ctx, json);
    if (c.JS_IsException(json) or c.JS_IsUndefined(json)) return;
    body_out.* = jsValueToOwned(allocator, ctx, json) catch return error.OutOfMemory;
    is_json_out.* = true;
}

/// Pull status + cookies + custom headers off the ambient `response`
/// global. Body is NOT read from here — it always comes from the
/// return value.
///
/// - `response.status` → `status_out`
/// - `response.cookies` (array of strings) → `cookies_out`, each
///   sanitized via `sanitizeSetCookie`
/// - `response.headers` (object, string→string) → `headers_out`,
///   filtered to reject pseudo-headers (`:xxx`), hop-by-hop names,
///   and `set-cookie` (cookies go through the dedicated array so
///   sanitization fires). Names are lowercased to match HTTP/2.
fn extractResponseMetadata(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    status_out: *i32,
    cookies_out: *std.ArrayList([]u8),
    headers_out: *std.ArrayList(ResponseHeader),
) error{OutOfMemory}!void {
    const global_obj = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global_obj);
    const resp_val = c.JS_GetPropertyStr(ctx, global_obj, "response");
    defer c.JS_FreeValue(ctx, resp_val);
    if (c.JS_IsUndefined(resp_val) or c.JS_IsNull(resp_val)) return;

    const status_val = c.JS_GetPropertyStr(ctx, resp_val, "status");
    defer c.JS_FreeValue(ctx, status_val);
    if (!c.JS_IsUndefined(status_val) and !c.JS_IsNull(status_val)) {
        _ = c.JS_ToInt32(ctx, status_out, status_val);
    }

    // ── response.cookies ────────────────────────────────────────
    const cookies_val = c.JS_GetPropertyStr(ctx, resp_val, "cookies");
    defer c.JS_FreeValue(ctx, cookies_val);
    if (!c.JS_IsUndefined(cookies_val) and !c.JS_IsNull(cookies_val) and c.JS_IsArray(cookies_val)) {
        const len_val = c.JS_GetPropertyStr(ctx, cookies_val, "length");
        defer c.JS_FreeValue(ctx, len_val);
        var n: u32 = 0;
        _ = c.JS_ToUint32(ctx, &n, len_val);
        // Hard cap — a pathological handler pushing thousands of
        // cookies would blow up the HPACK table on every proxy hop.
        const cap: u32 = @min(n, 32);

        var i: u32 = 0;
        while (i < cap) : (i += 1) {
            const elem = c.JS_GetPropertyUint32(ctx, cookies_val, i);
            defer c.JS_FreeValue(ctx, elem);
            if (!c.JS_IsString(elem)) continue;
            var raw_len: usize = 0;
            const cstr = c.JS_ToCStringLen(ctx, &raw_len, elem);
            if (cstr == null) continue;
            defer c.JS_FreeCString(ctx, cstr);
            if (raw_len == 0) continue;
            const raw = @as([*]const u8, @ptrCast(cstr))[0..raw_len];
            const sanitized = try sanitizeSetCookie(allocator, raw);
            if (sanitized.len == 0) {
                allocator.free(sanitized);
                continue;
            }
            cookies_out.append(allocator, sanitized) catch |err| {
                allocator.free(sanitized);
                return err;
            };
        }
    }

    // ── response.headers ────────────────────────────────────────
    //
    // Object keys become header names (lowercased); string values
    // become header values. Disallowed names are silently dropped —
    // handler bugs shouldn't 500 the request. Hard cap 32 for the
    // same HPACK reason as cookies.
    const headers_val = c.JS_GetPropertyStr(ctx, resp_val, "headers");
    defer c.JS_FreeValue(ctx, headers_val);
    if (c.JS_IsUndefined(headers_val) or c.JS_IsNull(headers_val) or !c.JS_IsObject(headers_val)) return;

    var prop_enum: [*c]c.JSPropertyEnum = null;
    var prop_count: u32 = 0;
    const flags: c_int = c.JS_GPN_STRING_MASK | c.JS_GPN_ENUM_ONLY;
    if (c.JS_GetOwnPropertyNames(ctx, &prop_enum, &prop_count, headers_val, flags) < 0) return;
    defer c.js_free(ctx, prop_enum);

    const hdr_cap: u32 = @min(prop_count, 32);
    var hi: u32 = 0;
    while (hi < hdr_cap) : (hi += 1) {
        const atom = prop_enum[hi].atom;
        defer c.JS_FreeAtom(ctx, atom);
        const name_cstr = c.JS_AtomToCString(ctx, atom);
        if (name_cstr == null) continue;
        defer c.JS_FreeCString(ctx, name_cstr);
        const raw_name = std.mem.span(name_cstr);
        if (!isEmittableHeaderName(raw_name)) continue;

        const val = c.JS_GetProperty(ctx, headers_val, atom);
        defer c.JS_FreeValue(ctx, val);
        if (!c.JS_IsString(val)) continue;
        var val_len: usize = 0;
        const val_cstr = c.JS_ToCStringLen(ctx, &val_len, val);
        if (val_cstr == null) continue;
        defer c.JS_FreeCString(ctx, val_cstr);
        const raw_val = @as([*]const u8, @ptrCast(val_cstr))[0..val_len];
        if (!isCleanHeaderValue(raw_val)) continue;

        const name_owned = try allocator.alloc(u8, raw_name.len);
        errdefer allocator.free(name_owned);
        for (raw_name, 0..) |b, i| name_owned[i] = std.ascii.toLower(b);

        const val_owned = try allocator.alloc(u8, raw_val.len);
        errdefer allocator.free(val_owned);
        @memcpy(val_owned, raw_val);

        headers_out.append(allocator, .{ .name = name_owned, .value = val_owned }) catch |err| {
            allocator.free(name_owned);
            allocator.free(val_owned);
            return err;
        };
    }
}

/// Reject HTTP/2 pseudo-headers, hop-by-hop names, and the names
/// we manage ourselves (cookies go through a sanitized pipeline,
/// content-length is computed from the body). Case-insensitive.
fn isEmittableHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == ':') return false; // HTTP/2 pseudo-header
    for (name) |b| {
        // RFC 7230 token chars — be liberal, reject obvious garbage.
        if (b <= 0x20 or b == 0x7f) return false;
    }
    const reserved = [_][]const u8{
        "connection",      "transfer-encoding", "upgrade",
        "keep-alive",      "te",                "trailer",
        "proxy-authenticate", "proxy-authorization",
        "set-cookie",      "content-length",
    };
    for (reserved) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return false;
    }
    return true;
}

/// Header values must not contain CR / LF (header-injection) or NUL.
/// Everything else is opaque to us.
fn isCleanHeaderValue(value: []const u8) bool {
    for (value) |b| {
        if (b == '\r' or b == '\n' or b == 0) return false;
    }
    return true;
}

/// Return an owned copy of `raw` with any `Domain=...` attribute
/// stripped. Attribute matching is case-insensitive on the name and
/// tolerant of surrounding whitespace. Everything else (name=value,
/// Path, HttpOnly, Secure, SameSite, Max-Age, Expires, ...) is
/// preserved in order.
///
/// **Why**: a customer handler writing
/// `Set-Cookie: foo=bar; Domain=loop46.me` would push the cookie
/// onto the parent domain, where a different tenant's handler would
/// read it. The PSL entry at the browser level blocks this too, but
/// server-side stripping is the authoritative defense and the one
/// thing we control (PSL propagation can lag by browser version).
///
/// If `raw` is already Domain-free, the output is byte-identical.
pub fn sanitizeSetCookie(
    allocator: std.mem.Allocator,
    raw: []const u8,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // A Set-Cookie value is `name=value` followed by zero or more
    // `; attr[=val]` segments. Split on `;`, keep the first segment
    // verbatim, filter `Domain` from the rest.
    var it = std.mem.splitScalar(u8, raw, ';');
    var first = true;
    while (it.next()) |raw_seg| {
        const seg = std.mem.trim(u8, raw_seg, " \t");
        if (first) {
            // Preserve the cookie's name=value as-is (caller already
            // built it); trim only leading/trailing whitespace.
            try buf.appendSlice(allocator, seg);
            first = false;
            continue;
        }
        if (seg.len == 0) continue; // `foo=bar;;baz` → drop empty
        const eq = std.mem.indexOfScalar(u8, seg, '=');
        const attr_name = if (eq) |e| seg[0..e] else seg;
        const attr_trim = std.mem.trim(u8, attr_name, " \t");
        if (std.ascii.eqlIgnoreCase(attr_trim, "domain")) continue;
        try buf.appendSlice(allocator, "; ");
        try buf.appendSlice(allocator, seg);
    }
    return buf.toOwnedSlice(allocator);
}

// ── Module loader ──────────────────────────────────────────────────────

/// Shared module loader infrastructure. Mounted onto the per-request
/// runtime via `JS_SetModuleLoaderFunc` so `import { x } from "./y.mjs"`
/// in handlers resolves against the deployment's bytecode map.
pub const module_loader = struct {
    pub const Ctx = struct {
        allocator: std.mem.Allocator,
        /// Path → compiled module bytecode. Null means the caller
        /// opted out of imports (tests, trivial single-file handlers).
        bytecodes: ?*const std.StringHashMapUnmanaged([]u8),
        /// Path → source-blob hash hex (64 chars). Parallel to
        /// `bytecodes` and populated by the same TenantFiles refresh
        /// path. Read by `load` to populate the module-resolution
        /// tape so replay can fetch the same source bytes by hash.
        /// Null when no tape capture is requested.
        source_hashes: ?*const std.StringHashMapUnmanaged([64]u8) = null,
        /// Per-request module-resolution tape. Each successful `load`
        /// appends one entry. Null when capture is disabled.
        module_tape: ?*tape_mod.Tape = null,
    };

    /// Normalize `specifier` (relative or bare) against the importing
    /// module's `base_name` into a canonical path key. Returns a
    /// js_malloc'd buffer — quickjs owns it after this call.
    pub fn normalize(
        ctx: ?*c.JSContext,
        base: [*c]const u8,
        name: [*c]const u8,
        _: ?*anyopaque,
    ) callconv(.c) [*c]u8 {
        const base_s = if (base != null) std.mem.span(base) else "";
        const name_s = if (name != null) std.mem.span(name) else "";
        const resolved = resolveSpecifier(base_s, name_s, static_buf[0..]);

        // Copy into a qjs-allocated buffer so quickjs can free it.
        const out = c.js_malloc(ctx, resolved.len + 1) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(out))[0..resolved.len], resolved);
        @as([*]u8, @ptrCast(out))[resolved.len] = 0;
        return @ptrCast(out);
    }

    pub fn load(
        ctx: ?*c.JSContext,
        name: [*c]const u8,
        opaque_ptr: ?*anyopaque,
    ) callconv(.c) ?*c.JSModuleDef {
        const self: *const Ctx = @ptrCast(@alignCast(opaque_ptr.?));
        const map = self.bytecodes orelse return null;
        const name_s = std.mem.span(name);
        const bytes = map.get(name_s) orelse return null;
        const obj = c.JS_ReadObject(ctx, bytes.ptr, bytes.len, c.JS_READ_OBJ_BYTECODE);
        if (c.JS_IsException(obj)) return null;
        if (obj.tag != c.JS_TAG_MODULE) {
            c.JS_FreeValue(ctx, obj);
            return null;
        }
        const mod_def: ?*c.JSModuleDef = @ptrCast(@alignCast(obj.u.ptr));
        // `JS_ReadObject` returned a borrowed+held module value; qjs
        // expects the loader to return the module def (which keeps
        // its own reference). Drop the JSValue handle.
        c.JS_FreeValue(ctx, obj);

        // Capture the resolved import for replay. The replay shell
        // reads each `(specifier, source_hash)` to fetch the same
        // source bytes and build an importmap so the iframe's module
        // graph matches production.
        if (self.module_tape) |t| {
            if (self.source_hashes) |hashes| {
                if (hashes.get(name_s)) |hash| {
                    t.appendModule(name_s, &hash) catch {};
                }
            }
        }

        return mod_def;
    }

    /// Stack buffer for a normalized path. 512 bytes is generous — path
    /// lengths are bounded by `MAX_PATH_LEN` in rove-files.
    threadlocal var static_buf: [512]u8 = undefined;
};

/// Resolve `specifier` ("./helper.mjs", "../lib/util", or a bare path)
/// against `base` ("_api/kv/index.mjs") into a canonical deployment
/// path key. Writes into `scratch` and returns a subslice pointing
/// into it.
fn resolveSpecifier(base: []const u8, specifier: []const u8, scratch: []u8) []const u8 {
    // Bare / absolute specifiers pass through unchanged.
    if (!std.mem.startsWith(u8, specifier, "./") and !std.mem.startsWith(u8, specifier, "../")) {
        const n = @min(specifier.len, scratch.len);
        @memcpy(scratch[0..n], specifier[0..n]);
        return scratch[0..n];
    }

    // Determine the importing module's directory (everything before
    // the final '/'). Empty if the importer is at the root.
    var dir_len: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| dir_len = slash;

    // Walk `specifier` applying "./" (skip) and "../" (pop one dir).
    var dir_end = dir_len;
    var rest = specifier;
    while (true) {
        if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "../")) {
            if (std.mem.lastIndexOfScalar(u8, base[0..dir_end], '/')) |prev_slash| {
                dir_end = prev_slash;
            } else {
                dir_end = 0;
            }
            rest = rest[3..];
        } else break;
    }

    var w: usize = 0;
    if (dir_end > 0) {
        const n = @min(dir_end, scratch.len);
        @memcpy(scratch[0..n], base[0..n]);
        w = n;
        if (w < scratch.len) {
            scratch[w] = '/';
            w += 1;
        }
    }
    const tail = @min(rest.len, scratch.len - w);
    @memcpy(scratch[w .. w + tail], rest[0..tail]);
    w += tail;
    return scratch[0..w];
}

fn finishResponse(
    d: *Dispatcher,
    state: *globals.DispatchState,
    pending: *PendingResponse,
    console_buf: *std.ArrayList(u8),
) DispatchError!Response {
    if (state.pending_kv_error) |err| {
        d.last_kv_error = err;
        // pending.deinit fires via the caller's errdefer when we
        // return an error — don't double-free here.
        console_buf.deinit(d.allocator);
        return DispatchError.KvFailed;
    }

    const console_bytes = console_buf.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    const set_cookies = pending.cookies.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    const headers_slice = pending.headers.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    // If the handler explicitly set content-type in response.headers,
    // suppress our auto-stamped JSON one so the handler's choice wins.
    var effective_body_is_json = pending.body_is_json;
    if (effective_body_is_json) {
        for (headers_slice) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                effective_body_is_json = false;
                break;
            }
        }
    }

    return .{
        .status = pending.status,
        .body = pending.body,
        .body_is_json = effective_body_is_json,
        .console = console_bytes,
        .exception = pending.exception,
        .set_cookies = set_cookies,
        .headers = headers_slice,
    };
}

fn jsValueToOwned(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    val: c.JSValue,
) error{ OutOfMemory, JsException }![]u8 {
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, val);
    if (cstr == null) return error.JsException;
    defer c.JS_FreeCString(ctx, cstr);
    const out = try allocator.alloc(u8, len);
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "sanitizeSetCookie strips Domain attribute" {
    const a = testing.allocator;

    // Basic: Domain stripped, other attrs preserved.
    {
        const out = try sanitizeSetCookie(a, "foo=bar; Path=/; Domain=loop46.me; HttpOnly");
        defer a.free(out);
        try testing.expectEqualStrings("foo=bar; Path=/; HttpOnly", out);
    }
    // Case-insensitive attribute name.
    {
        const out = try sanitizeSetCookie(a, "sid=abc; domain=foo.com; SameSite=Lax");
        defer a.free(out);
        try testing.expectEqualStrings("sid=abc; SameSite=Lax", out);
    }
    {
        const out = try sanitizeSetCookie(a, "sid=abc; DOMAIN=x.y.z; Secure");
        defer a.free(out);
        try testing.expectEqualStrings("sid=abc; Secure", out);
    }
    // No Domain = pass-through (only whitespace normalization).
    {
        const out = try sanitizeSetCookie(a, "a=b; Path=/; HttpOnly");
        defer a.free(out);
        try testing.expectEqualStrings("a=b; Path=/; HttpOnly", out);
    }
    // Leading/trailing spaces around attrs are trimmed on rewrite.
    {
        const out = try sanitizeSetCookie(a, "k=v;   Domain=foo  ;Path=/");
        defer a.free(out);
        try testing.expectEqualStrings("k=v; Path=/", out);
    }
    // Domain as the only attribute leaves only name=value.
    {
        const out = try sanitizeSetCookie(a, "k=v; Domain=loop46.me");
        defer a.free(out);
        try testing.expectEqualStrings("k=v", out);
    }
    // Flag-only attribute (no `=`) named "domain" still stripped.
    {
        const out = try sanitizeSetCookie(a, "k=v; Domain; HttpOnly");
        defer a.free(out);
        try testing.expectEqualStrings("k=v; HttpOnly", out);
    }
    // Value containing `=` (cookie value has embedded equals) preserved.
    {
        const out = try sanitizeSetCookie(a, "token=a=b=c; Domain=x; Secure");
        defer a.free(out);
        try testing.expectEqualStrings("token=a=b=c; Secure", out);
    }
    // Empty segment dropped without crashing.
    {
        const out = try sanitizeSetCookie(a, "k=v;;;Domain=x;;Path=/;;");
        defer a.free(out);
        try testing.expectEqualStrings("k=v; Path=/", out);
    }
}

fn openTempKv(allocator: std.mem.Allocator, buf: *[64]u8) !*kv_mod.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-js-disp-{x}.db", .{seed});
    return try kv_mod.KvStore.open(allocator, path);
}

fn cleanupTempKv(buf: *[64]u8) void {
    const path_slice = std.mem.sliceTo(buf, 0);
    std.fs.cwd().deleteFile(path_slice) catch {};
}

test "dispatch: simple response write-back" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\response.status = 201;
        \\return "hi " + request.path;
    ,
        .{ .method = "GET", .path = "/hello" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 201), resp.status);
    try testing.expectEqualStrings("hi /hello", resp.body);
    try testing.expectEqualStrings("", resp.exception);
}

test "dispatch: kv.get on missing key returns null" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\const v = kv.get("nope");
        \\return String(v);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("null", resp.body);
}

/// Test harness: wrap a statement-level snippet in a named export
/// named `go`, compile as .mjs, dispatch with `?fn=go`. Matches the
/// production contract — named-export modules only, positional args.
fn runOne(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    body: []const u8,
    request_in: Request,
) !Response {
    const wrapped = try std.fmt.allocPrint(testing.allocator,
        "export function go() {{ {s} }}\n", .{body});
    defer testing.allocator.free(wrapped);

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(wrapped, "h.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(bytecode);

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    // `webhook.send` requires a non-null pending_webhooks list (Phase
    // 5.5 d step 6 removed the legacy `_outbox/{id}` fallback). Tests
    // that don't care still need one allocated; ones that DO care
    // pass their own list in via `request.pending_webhooks` and the
    // local one stays unused.
    var local_webhooks: std.ArrayListUnmanaged(webhook_server.WebhookRow) = .empty;
    defer {
        for (local_webhooks.items) |*r| r.deinit(testing.allocator);
        local_webhooks.deinit(testing.allocator);
    }

    // If the caller didn't set a query, force `fn=go` so the
    // dispatcher finds our wrapper export.
    var request = request_in;
    if (request.query == null) request.query = "fn=go";
    if (request.pending_webhooks == null) request.pending_webhooks = &local_webhooks;

    var budget = Budget.fromNow(Budget.default_duration_ns);
    const resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, request, &budget);
    try txn.commit();
    return resp;
}

test "dispatch: kv.set + kv.get round trip" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

    var r1 = try runOne(
        &d,
        kv,
        \\kv.set("name", "rove");
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // First request committed the txn, so the write is durable.
    // Second request observes it.
    var r2 = try runOne(
        &d,
        kv,
        \\return kv.get("name");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r2.deinit(testing.allocator);

    try testing.expectEqualStrings("rove", r2.body);
}

test "dispatch: cross-tenant events.emit{to:} writes only to caller's kv" {
    // SSE cross-tenant isolation argument from docs/sse-plan.md §2.2.
    // events.emit({to: <tenant-A's sid>}) called from tenant B's
    // handler writes the row into tenant B's app.db, NOT tenant A's.
    // The pump on tenant A's host never reads from tenant B's db,
    // so the spoofing attempt is structurally ineffective.
    //
    // This test models the per-tenant kv isolation by giving each
    // "tenant" its own KvStore and confirming the cross-target emit
    // lands only in the caller's. The actual host→tenant routing
    // happens upstream in worker_dispatch.resolveRequest; here we
    // exercise the kv-scope half of the argument.
    var buf_a: [64]u8 = undefined;
    const kv_a = try openTempKv(testing.allocator, &buf_a);
    defer {
        kv_a.close();
        cleanupTempKv(&buf_a);
    }

    var buf_b: [64]u8 = undefined;
    const kv_b = try openTempKv(testing.allocator, &buf_b);
    defer {
        kv_b.close();
        cleanupTempKv(&buf_b);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Tenant A's session id — what tenant B is going to try to spoof
    // by passing it to events.emit({to: ...}).
    const sid_a = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111";
    const sid_b: [64]u8 = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222".*;

    // Tenant B's handler fires `events.emit({to: <sid_a>, data: "spoof"})`.
    // Dispatch runs against kv_b (tenant B's app.db).
    var resp = try runOne(
        &d,
        kv_b,
        \\events.emit({to: "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111", data: "spoof"});
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/", .session_id = sid_b, .request_id = 1 },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);

    // Spoof landed in tenant B's kv at the targeted sid prefix —
    // confirms the JS-level emit went through.
    const expected_b_key = "_events/" ++ sid_a ++ "/00000000000000000001-000000";
    const v_in_b = try kv_b.get(expected_b_key);
    defer testing.allocator.free(v_in_b);
    try testing.expect(std.mem.indexOf(u8, v_in_b, "\"data\":\"spoof\"") != null);

    // Tenant A's kv has NO _events/ rows — the cross-tenant write
    // was structurally impossible. This is the load-bearing isolation
    // claim: the pump on tenant A's host will iterate ONLY tenant
    // A's kv when delivering to a connected EventSource client, so
    // even though tenant B successfully wrote a row "addressed" to
    // sid_a, nobody connected to tenant A's /_events will ever see it.
    try testing.expectError(error.NotFound, kv_a.get(expected_b_key));
    var scan_a = try kv_a.prefix("_events/", "", 100);
    defer scan_a.deinit();
    try testing.expectEqual(@as(usize, 0), scan_a.entries.len);
}

test "dispatch: events.emit string form writes to current sid" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const sid: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    var resp = try runOne(
        &d,
        kv,
        \\const id = events.emit("hello");
        \\return id;
    ,
        .{ .method = "POST", .path = "/", .session_id = sid, .request_id = 42 },
    );
    defer resp.deinit(testing.allocator);

    // Returned wire id is request_id-call_index, zero-padded.
    try testing.expectEqualStrings("00000000000000000042-000000", resp.body);

    // The envelope was written to _events/{sid}/{wire_id}.
    const expected_key = "_events/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/00000000000000000042-000000";
    const env_bytes = try kv.get(expected_key);
    defer testing.allocator.free(env_bytes);
    // The data field should round-trip the string "hello".
    try testing.expect(std.mem.indexOf(u8, env_bytes, "\"data\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, env_bytes, "\"type\":\"message\"") != null);
    try testing.expect(std.mem.indexOf(u8, env_bytes, "\"v\":1") != null);
}

test "dispatch: events.emit object form with custom type + data" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const sid: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    var resp = try runOne(
        &d,
        kv,
        \\events.emit({type: "tick", data: {count: 7, label: "foo"}});
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/", .session_id = sid, .request_id = 1 },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);

    const expected_key = "_events/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/00000000000000000001-000000";
    const env_bytes = try kv.get(expected_key);
    defer testing.allocator.free(env_bytes);
    try testing.expect(std.mem.indexOf(u8, env_bytes, "\"type\":\"tick\"") != null);
    try testing.expect(std.mem.indexOf(u8, env_bytes, "\"count\":7") != null);
    try testing.expect(std.mem.indexOf(u8, env_bytes, "\"label\":\"foo\"") != null);
}

test "dispatch: events.emit explicit fan-out writes to each sid" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const me: [64]u8 = "1111111111111111111111111111111111111111111111111111111111111111".*;
    var resp = try runOne(
        &d,
        kv,
        \\events.emit({to: ["aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111",
        \\                  "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"],
        \\             data: "x"});
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/", .session_id = me, .request_id = 5 },
    );
    defer resp.deinit(testing.allocator);

    // Both target sids got the envelope. Same wire id, different keys.
    const a = try kv.get("_events/aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111/00000000000000000005-000000");
    defer testing.allocator.free(a);
    const b = try kv.get("_events/bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222/00000000000000000005-000000");
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);

    // The current sid did NOT receive a copy — explicit `to:`
    // overrides the implicit-target.
    try testing.expectError(error.NotFound, kv.get("_events/1111111111111111111111111111111111111111111111111111111111111111/00000000000000000005-000000"));
}

test "dispatch: events.emit increments call_index across calls" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const sid: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    var resp = try runOne(
        &d,
        kv,
        \\const a = events.emit("first");
        \\const b = events.emit("second");
        \\const c = events.emit("third");
        \\return a + "|" + b + "|" + c;
    ,
        .{ .method = "POST", .path = "/", .session_id = sid, .request_id = 9 },
    );
    defer resp.deinit(testing.allocator);

    // Call indices 0, 1, 2 — all under the same request_id.
    try testing.expectEqualStrings(
        "00000000000000000009-000000|00000000000000000009-000001|00000000000000000009-000002",
        resp.body,
    );
}

test "dispatch: events.emit throws when no session and no to:" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { events.emit("hi"); return "no_throw"; }
        \\catch (e) { return e.code; }
    ,
        .{ .method = "POST", .path = "/" }, // no session_id
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("no_session", resp.body);
}

test "dispatch: events.emit rejects customer-supplied id" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const sid: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    var resp = try runOne(
        &d,
        kv,
        \\try { events.emit({id: "cheat", data: "x"}); return "no_throw"; }
        \\catch (e) { return e.code; }
    ,
        .{ .method = "POST", .path = "/", .session_id = sid, .request_id = 1 },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("events_id_reserved", resp.body);
}

test "dispatch: events.emit rejects malformed sid in to:" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const sid: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    var resp = try runOne(
        &d,
        kv,
        \\try { events.emit({to: "not-a-sid", data: "x"}); return "no_throw"; }
        \\catch (e) { return e.code; }
    ,
        .{ .method = "POST", .path = "/", .session_id = sid, .request_id = 1 },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("events_bad_sid", resp.body);
}

test "dispatch: request.session.id surfaces resolved sid" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const known: [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".*;
    var resp = try runOne(
        &d,
        kv,
        \\return request.session.id;
    ,
        .{ .method = "GET", .path = "/", .session_id = known },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings(&known, resp.body);
}

test "dispatch: request.session is null when no sid resolved" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\return String(request.session);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("null", resp.body);
}

test "dispatch: kv.set rejects platform-reserved prefixes" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Attempting to spoof a callback row from customer code throws
    // Error{code: "reserved_key"}. Same shape applies to _events/,
    // _audit/, _magic/, _triggers/, etc.
    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  kv.set("_callback/spoofed", "x");
        \\  return "no_throw";
        \\} catch (e) {
        \\  return e.code + ":" + e.message;
        \\}
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expect(std.mem.startsWith(u8, resp.body, "reserved_key:"));
    try testing.expect(std.mem.indexOf(u8, resp.body, "_callback/spoofed") != null);

    // The spoofed row must NOT be in the kv after commit.
    try testing.expectError(error.NotFound, kv.get("_callback/spoofed"));
}

test "dispatch: kv.delete rejects platform-reserved prefixes" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Seed an event row directly through the kv (simulating a real
    // events.emit having written it earlier).
    try kv.put("_events/sid/0001-000001", "real_event");

    // Customer kv.delete against the reserved prefix throws.
    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  kv.delete("_events/sid/0001-000001");
        \\  return "no_throw";
        \\} catch (e) {
        \\  return e.code;
        \\}
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("reserved_key", resp.body);

    // The seeded row must still be there.
    const v = try kv.get("_events/sid/0001-000001");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("real_event", v);
}

test "dispatch: kv.set into customer namespace still works" {
    // Regression: the reserved-prefix guard must not catch normal
    // customer keys that happen to share a prefix substring (e.g.
    // "my_audit/" should not collide with "_audit/").
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var r1 = try runOne(
        &d,
        kv,
        \\kv.set("my_audit/x", "v1");
        \\kv.set("users/alice", "v2");
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", r1.body);

    const a = try kv.get("my_audit/x");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("v1", a);
    const b = try kv.get("users/alice");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("v2", b);
}

test "dispatch: kv.delete removes key" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

    try kv.put("k", "v");

    var r1 = try runOne(
        &d,
        kv,
        \\kv.delete("k");
        \\return "ok";
    ,
        .{ .method = "DELETE", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // After commit, the key is gone.
    try testing.expectError(error.NotFound, kv.get("k"));
}

test "dispatch: request.host is exposed verbatim from :authority" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\return request.host;
    ,
        .{ .method = "GET", .path = "/", .host = "app.loop46.localhost:8198" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("app.loop46.localhost:8198", resp.body);
}

test "dispatch: read-your-writes within one handler works via TrackedTxn" {
    // The TrackedTxn opens a SQLite transaction, writes go through it
    // (visible to subsequent reads from the same connection), and
    // commit fires after the handler returns. Inside the handler,
    // kv.set is immediately observable to kv.get.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\kv.set("x", "fresh");
        \\return kv.get("x");
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("fresh", resp.body);
}

test "dispatch: console.log captured into response.console" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\console.log("hello", "world");
        \\console.log("line2");
        \\return "x";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("hello world\nline2\n", resp.console);
}

test "dispatch: response.headers emitted, reserved names filtered, custom CT overrides auto-json" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Handler sets: one safe header, one reserved name (dropped),
    // one pseudo-header (dropped), content-type override.
    var resp = try runOne(
        &d,
        kv,
        \\response.headers = {
        \\  "X-Request-Id": "abc123",
        \\  "Set-Cookie": "evil=1",              // reserved → dropped
        \\  ":status": "999",                    // pseudo → dropped
        \\  "content-type": "application/xml",   // overrides auto json
        \\};
        \\return { shape: "object, triggers body_is_json" };
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var saw_request_id = false;
    var saw_content_type_override = false;
    for (resp.headers) |h| {
        if (std.mem.eql(u8, h.name, "x-request-id")) {
            saw_request_id = true;
            try testing.expectEqualStrings("abc123", h.value);
        }
        if (std.mem.eql(u8, h.name, "content-type")) {
            saw_content_type_override = true;
            try testing.expectEqualStrings("application/xml", h.value);
        }
        // Reserved names must not appear.
        try testing.expect(!std.mem.eql(u8, h.name, "set-cookie"));
        try testing.expect(!std.mem.eql(u8, h.name, ":status"));
    }
    try testing.expect(saw_request_id);
    try testing.expect(saw_content_type_override);
    // body_is_json should be suppressed when handler set content-type.
    try testing.expect(!resp.body_is_json);
}

test "dispatch: response.headers empty → no custom headers on Response" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\return "hi";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), resp.headers.len);
}

test "dispatch: response.cookies surface on Response.set_cookies, Domain stripped" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\response.cookies.push("session=abc; Path=/; Domain=loop46.me; HttpOnly");
        \\response.cookies.push("flag=on; Secure");
        \\return "ok";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), resp.set_cookies.len);
    try testing.expectEqualStrings("session=abc; Path=/; HttpOnly", resp.set_cookies[0]);
    try testing.expectEqualStrings("flag=on; Secure", resp.set_cookies[1]);
}

test "dispatch: malformed bytecode surfaces in exception field" {
    // Compile errors happen at upload time in production (rove-files-cli
    // calls compileToBytecode, which returns JsException on bad source),
    // not in the dispatcher. The dispatcher's job is to gracefully
    // handle malformed bytecode at runtime — version skew, corruption,
    // a wrong file type, etc. Pass random bytes and verify the
    // JS_ReadObject failure lands in resp.exception.
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    const garbage = [_]u8{ 0xff, 0x00, 0xde, 0xad, 0xbe, 0xef };
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(
        kv,
        &txn,
        &ws,
        &garbage,
        null,
        null,
        null,
        .{ .method = "GET", .path = "/" },
        &budget,
    );
    defer resp.deinit(testing.allocator);

    try testing.expect(resp.exception.len > 0);
}

test "dispatch: runtime throw leaves exception + partial response" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\throw new Error("boom");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, resp.exception, "boom") != null);
}

test "dispatch: per-store isolation by passing different kv per run" {
    // Two independent stores, one dispatcher. The worker swaps the
    // tenant store per request; this test proves the dispatcher path
    // honors that.
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const kv_a = try openTempKv(testing.allocator, &buf_a);
    const kv_b = try openTempKv(testing.allocator, &buf_b);
    defer {
        kv_a.close();
        kv_b.close();
        cleanupTempKv(&buf_a);
        cleanupTempKv(&buf_b);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

    var r1 = try runOne(
        &d,
        kv_a,
        \\kv.set("name", "alice");
        \\return "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // kv_b never received the write.
    var r2 = try runOne(
        &d,
        kv_b,
        \\return String(kv.get("name"));
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("null", r2.body);

    var r3 = try runOne(
        &d,
        kv_a,
        \\return kv.get("name");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r3.deinit(testing.allocator);
    try testing.expectEqualStrings("alice", r3.body);
}

test "dispatch: kv tape captures get/set/delete with outcomes" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Seed a key so the handler can observe both .ok and .not_found.
    try kv.put("seeded", "v1");

    var tape = tape_mod.Tape.init(testing.allocator, .kv);
    defer tape.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function go() {
        \\    const v = kv.get("seeded");
        \\    const missing = kv.get("missing");
        \\    kv.set("new", v + "!");
        \\    kv.delete("seeded");
        \\    return String(missing);
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "POST",
        .path = "/",
        .query = "fn=go",
        .kv_tape = &tape,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), tape.entries.items.len);

    const e0 = tape.entries.items[0].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e0.op);
    try testing.expectEqualStrings("seeded", e0.key);
    try testing.expectEqualStrings("v1", e0.value);
    try testing.expectEqual(tape_mod.KvOutcome.ok, e0.outcome);

    const e1 = tape.entries.items[1].kv;
    try testing.expectEqual(tape_mod.KvOp.get, e1.op);
    try testing.expectEqualStrings("missing", e1.key);
    try testing.expectEqual(tape_mod.KvOutcome.not_found, e1.outcome);

    const e2 = tape.entries.items[2].kv;
    try testing.expectEqual(tape_mod.KvOp.set, e2.op);
    try testing.expectEqualStrings("new", e2.key);
    try testing.expectEqualStrings("v1!", e2.value);
    try testing.expectEqual(tape_mod.KvOutcome.ok, e2.outcome);

    const e3 = tape.entries.items[3].kv;
    try testing.expectEqual(tape_mod.KvOp.delete, e3.op);
    try testing.expectEqualStrings("seeded", e3.key);
    try testing.expectEqual(tape_mod.KvOutcome.ok, e3.outcome);
}

test "dispatch: Date/Math/crypto tapes capture non-determinism" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var date_tape = tape_mod.Tape.init(testing.allocator, .date);
    defer date_tape.deinit();
    var math_tape = tape_mod.Tape.init(testing.allocator, .math_random);
    defer math_tape.deinit();
    var crypto_tape = tape_mod.Tape.init(testing.allocator, .crypto_random);
    defer crypto_tape.deinit();

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function go() {
        \\    const t = Date.now();
        \\    const r1 = Math.random();
        \\    const r2 = Math.random();
        \\    const buf = new Uint8Array(4);
        \\    crypto.getRandomValues(buf);
        \\    const id = crypto.randomUUID();
        \\    return String(t) + "|" + r1 + "|" + r2 + "|" + id;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();

        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/",
            .query = "fn=go",
            .date_tape = &date_tape,
            .math_random_tape = &math_tape,
            .crypto_random_tape = &crypto_tape,
            .prng_seed = 42,
        }, &budget);
        resp.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(usize, 1), date_tape.entries.items.len);
    try testing.expectEqual(@as(usize, 2), math_tape.entries.items.len);
    // getRandomValues(4 bytes) + randomUUID(16 raw bytes) → two entries
    try testing.expectEqual(@as(usize, 2), crypto_tape.entries.items.len);
    try testing.expectEqual(@as(usize, 4), crypto_tape.entries.items[0].crypto_random.bytes.len);
    try testing.expectEqual(@as(usize, 16), crypto_tape.entries.items[1].crypto_random.bytes.len);

    // Replaying the same seed with a fresh set of tapes should yield
    // bit-identical math_random and crypto values (date is wall-clock
    // so we skip it here).
    var math_tape2 = tape_mod.Tape.init(testing.allocator, .math_random);
    defer math_tape2.deinit();
    var crypto_tape2 = tape_mod.Tape.init(testing.allocator, .crypto_random);
    defer crypto_tape2.deinit();

    {
        var txn2 = try kv.beginTrackedImmediate();
        defer txn2.rollback() catch {};
        var ws2 = kv_mod.WriteSet.init(testing.allocator);
        defer ws2.deinit();
        var budget2 = Budget.fromNow(Budget.default_duration_ns);
        var resp2 = try d.run(kv, &txn2, &ws2, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/",
            .query = "fn=go",
            .math_random_tape = &math_tape2,
            .crypto_random_tape = &crypto_tape2,
            .prng_seed = 42,
        }, &budget2);
        resp2.deinit(testing.allocator);
    }

    try testing.expectEqual(
        math_tape.entries.items[0].math_random.bits,
        math_tape2.entries.items[0].math_random.bits,
    );
    try testing.expectEqual(
        math_tape.entries.items[1].math_random.bits,
        math_tape2.entries.items[1].math_random.bits,
    );
    try testing.expectEqualSlices(
        u8,
        crypto_tape.entries.items[0].crypto_random.bytes,
        crypto_tape2.entries.items[0].crypto_random.bytes,
    );
    try testing.expectEqualSlices(
        u8,
        crypto_tape.entries.items[1].crypto_random.bytes,
        crypto_tape2.entries.items[1].crypto_random.bytes,
    );
}

test "dispatch: tight loop hits budget and returns Interrupted" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Compile a handler that runs forever.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        "export function go() { while (true) {} }",
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    // 5ms budget so the test is fast but the interrupt handler has
    // plenty of ticks to observe.
    var budget = Budget.fromNow(5 * std.time.ns_per_ms);
    const started: i64 = @intCast(std.time.nanoTimestamp());
    const result = d.run(
        kv,
        &txn,
        &ws,
        bytecode,
        null,
        null,
        null,
        .{ .method = "GET", .path = "/", .query = "fn=go" },
        &budget,
    );
    const elapsed_ns: i64 = @as(i64, @intCast(std.time.nanoTimestamp())) - started;

    try testing.expectError(DispatchError.Interrupted, result);
    try testing.expect(budget.tick_count > 0);
    // Should not run much longer than the budget — generous ceiling for
    // CI jitter.
    try testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
}

test "dispatch: short handler does not trip budget" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\return "fast";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("fast", resp.body);
}

test "dispatch: .mjs module + function dispatch with ?fn=" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Compile a tiny module with two exports.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function greet(path) {
        \\    return "hi " + path;
        \\}
        \\export function shout(path) {
        \\    response.status = 201;
        \\    return ("HI " + path).toUpperCase();
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();

    // ?fn=greet with args=["/hello"] → "hi /hello", status 200.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=greet&args=%5B%22%2Fhello%22%5D",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi /hello", resp.body);
    }

    // ?fn=shout → "HI /HELLO", status 201 via response global.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=shout&args=%5B%22%2Fhello%22%5D",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 201), resp.status);
        try testing.expectEqualStrings("HI /HELLO", resp.body);
    }

    // Unknown fn → 404 with a descriptive body.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=nope",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 404), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "nope") != null);
    }
}

// Helper: drive a dispatch where a `_middlewares/index.mjs` is
// present alongside the handler. Bytecodes share the per-tenant
// StringHashMap shape the worker uses in production.
fn runWithMiddleware(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    handler_body: []const u8,
    middleware_src: []const u8,
    request_in: Request,
) !Response {
    const wrapped = try std.fmt.allocPrint(testing.allocator,
        "export function go() {{ {s} }}\n", .{handler_body});
    defer testing.allocator.free(wrapped);

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const handler_bc = try ctx.compileToBytecode(wrapped, "h.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);
    const mw_bc = try ctx.compileToBytecode(middleware_src, "_middlewares/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(mw_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_middlewares/index.mjs", @constCast(mw_bc));

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var request = request_in;
    if (request.query == null) request.query = "fn=go";

    var budget = Budget.fromNow(Budget.default_duration_ns);
    const resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, null, request, &budget);
    try txn.commit();
    return resp;
}

test "dispatch: middleware that returns undefined → handler runs" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function before() {
        \\    // implicit undefined → continue
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("handler-ran", resp.body);
}

test "dispatch: middleware mutation of request.auth flows to handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "is_root=" + (request.auth && request.auth.is_root ? "yes" : "no");
    ,
        \\export function before() {
        \\    request.auth = { is_root: true };
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("is_root=yes", resp.body);
}

test "dispatch: middleware short-circuits with response when before returns a value" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function before() {
        \\    response.status = 401;
        \\    return { error: "no" };
        \\}
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 401), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"no\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "handler-ran") == null);
}

test "dispatch: middleware throw surfaces as 500 with exception" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "should-not-run";
    ,
        \\export function before() { throw new Error("nope"); }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.exception, "nope") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "should-not-run") == null);
}

test "dispatch: middleware without `before` export → 500" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Module exports something else, not `before`. Operator-visible 500
    // rather than silent skip.
    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function notBefore() { return "wrong"; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 500), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "before") != null);
}

test "dispatch: middleware applies to ?fn=<named> RPC dispatch too" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Important property: middleware fires before *any* dispatch,
    // including the dashboard's `?fn=<named-export>` RPC path.
    // Without this admin's named-export RPCs would bypass the auth
    // gate entirely.
    var resp = try runWithMiddleware(
        &d,
        kv,
        \\return "handler-ran";
    ,
        \\export function before() {
        \\    response.status = 401;
        \\    return { error: "blocked" };
        \\}
    ,
        .{ .method = "GET", .path = "/", .query = "fn=go" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 401), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"blocked\"") != null);
}

test "dispatch: missing fn defaults to `default` export, called with no args" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    return "hi from default at " + request.path;
        \\}
        \\export function other() {
        \\    return "should not be called";
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // GET with no query at all → default export, no args.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/landing",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi from default at /landing", resp.body);
    }

    // GET with query that has no fn= → still default.
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
            .method = "GET",
            .path = "/x",
            .query = "page=2&sort=desc",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi from default at /x", resp.body);
    }
}

test "dispatch: no fn and no default export → 404" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function only_named() { return "x"; }
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 404), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "default") != null);
}

test "dispatch: POST with non-envelope JSON body invokes default, body in request.body" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const parsed = JSON.parse(request.body);
        \\    return "got name=" + parsed.name;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "POST",
        .path = "/",
        .body = "{\"name\":\"alice\"}",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("got name=alice", resp.body);
}

test "dispatch: POST RPC envelope still routes to named export" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export function greet(who) {
        \\    return "hi " + who;
        \\}
        \\export default function () { return "default-not-called"; }
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "POST",
        .path = "/",
        .body = "{\"fn\":\"greet\",\"args\":[\"world\"]}",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("hi world", resp.body);
}

// ── request.headers + request.cookies ─────────────────────────────────

/// Build a fake ReqHeaders from a slice of (name, value) pairs.
/// The strings are borrowed — caller keeps them alive for the test.
fn makeReqHeaders(buf: []h2.HeaderField, pairs: []const [2][]const u8) h2.ReqHeaders {
    std.debug.assert(buf.len >= pairs.len);
    for (pairs, 0..) |p, i| {
        buf[i] = .{
            .name = p[0].ptr,
            .name_len = @intCast(p[0].len),
            .value = p[1].ptr,
            .value_len = @intCast(p[1].len),
        };
    }
    return .{ .fields = buf.ptr, .count = @intCast(pairs.len) };
}

test "dispatch: request.headers exposes named headers, filters pseudo-headers" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const h = request.headers;
        \\    return JSON.stringify({
        \\        ua: h["user-agent"] ?? null,
        \\        sig: h["x-slack-signature"] ?? null,
        \\        method_pseudo: h[":method"] ?? null,
        \\        path_pseudo: h[":path"] ?? null,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [8]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ ":method", "GET" },
        .{ ":path", "/" },
        .{ "user-agent", "smoke/1" },
        .{ "x-slack-signature", "v0=abc" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "{\"ua\":\"smoke/1\",\"sig\":\"v0=abc\",\"method_pseudo\":null,\"path_pseudo\":null}",
        resp.body,
    );
}

test "dispatch: request.headers missing → empty object, missing key → undefined" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const h = request.headers;
        \\    return JSON.stringify({
        \\        type: typeof h,
        \\        keys: Object.keys(h).length,
        \\        missing: h["x-not-set"] === undefined,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    // No headers field — exercises the null path.
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"keys\":0,\"missing\":true}",
        resp.body,
    );
}

test "dispatch: request.cookies parses RFC 6265 cookie header" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    const c = request.cookies;
        \\    return JSON.stringify({
        \\        sess: c["sid"] ?? null,
        \\        ab: c["ab"] ?? null,
        \\        missing: c["nope"] ?? null,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "cookie", "sid=abc123; ab=  spaced  ; bare" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    // `bare` (no `=`) is dropped; whitespace around the value is
    // trimmed (matches browser / Express / Hono cookie parsers).
    try testing.expectEqualStrings(
        "{\"sess\":\"abc123\",\"ab\":\"spaced\",\"missing\":null}",
        resp.body,
    );
}

test "dispatch: request.cookies empty when no cookie header" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export default function () {
        \\    return JSON.stringify({
        \\        type: typeof request.cookies,
        \\        keys: Object.keys(request.cookies).length,
        \\    });
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var hdr_buf: [4]h2.HeaderField = undefined;
    const hdrs = makeReqHeaders(&hdr_buf, &.{
        .{ "user-agent", "smoke/1" },
    });

    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/",
        .headers = hdrs,
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"keys\":0}",
        resp.body,
    );
}

test "dispatch: async module handler gets unwrapped" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(
        \\export async function fetchLike(path) {
        \\    const v = await Promise.resolve("async " + path);
        \\    response.status = 202;
        \\    return v;
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, null, null, null, .{
        .method = "GET",
        .path = "/x",
        .query = "fn=fetchLike&args=%5B%22%2Fx%22%5D",
    }, &budget);
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 202), resp.status);
    try testing.expectEqualStrings("async /x", resp.body);
}

test "dispatch: request object fields populated" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator); defer d.deinit();
    var resp = try runOne(
        &d,
        kv,
        \\return request.method + " " + request.path + " " + request.body;
    ,
        .{ .method = "PUT", .path = "/x", .body = "payload" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("PUT /x payload", resp.body);
}

test "dispatch: request.query exposes raw query string" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Dispatch fn has to be set via `fn=` for runOne's wrapper export;
    // we check the full query including the `fn=` entry round-trips.
    var resp = try runOne(
        &d,
        kv,
        \\return String(request.query);
    ,
        .{ .method = "GET", .path = "/", .query = "fn=go&name=alice&tags=x%20y" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("fn=go&name=alice&tags=x%20y", resp.body);
}


test "dispatch: webhook.send appends WebhookRow to pending_webhooks" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var webhooks: std.ArrayListUnmanaged(webhook_server.WebhookRow) = .empty;
    defer {
        for (webhooks.items) |*r| r.deinit(testing.allocator);
        webhooks.deinit(testing.allocator);
    }

    // Handler fires two webhooks; the second exercises call_index = 1.
    var resp = try runOne(
        &d,
        kv,
        \\const id1 = webhook.send({
        \\  url: "https://example.test/a",
        \\  body: "one",
        \\  onResult: "cb/a",
        \\  context: { x: 1 },
        \\});
        \\const id2 = webhook.send({
        \\  url: "https://example.test/b",
        \\  method: "GET",
        \\});
        \\return id1 + "|" + id2;
    ,
        .{
            .method = "GET",
            .path = "/hook",
            .request_id = 0xdeadbeef,
            .pending_webhooks = &webhooks,
        },
    );
    defer resp.deinit(testing.allocator);

    // 64-hex id | 64-hex id → 129 chars total.
    try testing.expectEqual(@as(usize, 64 * 2 + 1), resp.body.len);

    try testing.expectEqual(@as(usize, 2), webhooks.items.len);

    // Insertion order preserved.
    try testing.expectEqualStrings("https://example.test/a", webhooks.items[0].url);
    try testing.expectEqualStrings("POST", webhooks.items[0].method);
    try testing.expectEqualStrings("one", webhooks.items[0].body);
    try testing.expectEqualStrings("cb/a", webhooks.items[0].on_result_path);
    try testing.expectEqualStrings("{\"x\":1}", webhooks.items[0].context_json);

    try testing.expectEqualStrings("https://example.test/b", webhooks.items[1].url);
    try testing.expectEqualStrings("GET", webhooks.items[1].method);

    // Webhook ids match the response body.
    const id1 = resp.body[0..64];
    const id2 = resp.body[65..];
    try testing.expectEqualSlices(u8, id1, &webhooks.items[0].webhook_id_hex);
    try testing.expectEqualSlices(u8, id2, &webhooks.items[1].webhook_id_hex);
}

test "dispatch: webhook.send ids are deterministic under replay" {
    var buf_a: [64]u8 = undefined;
    const kv_a = try openTempKv(testing.allocator, &buf_a);
    defer {
        kv_a.close();
        cleanupTempKv(&buf_a);
    }
    var buf_b: [64]u8 = undefined;
    const kv_b = try openTempKv(testing.allocator, &buf_b);
    defer {
        kv_b.close();
        cleanupTempKv(&buf_b);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Same request_id across two runs → same outbox ids returned.
    var r1 = try runOne(&d, kv_a,
        \\return webhook.send({ url: "https://x.test/" });
    , .{ .method = "POST", .path = "/", .request_id = 42 });
    defer r1.deinit(testing.allocator);

    var r2 = try runOne(&d, kv_b,
        \\return webhook.send({ url: "https://totally-different.example/" });
    , .{ .method = "POST", .path = "/", .request_id = 42 });
    defer r2.deinit(testing.allocator);

    // Ids are derived from (request_id, call_index) only — the url
    // doesn't factor in — so both handlers produce the same id.
    try testing.expectEqualStrings(r1.body, r2.body);
}

test "dispatch: webhook.send rejects missing url" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try {
        \\  webhook.send({ method: "POST" });
        \\  return "ok";
        \\} catch (e) {
        \\  return "threw:" + e.message;
        \\}
    ,
        .{ .method = "GET", .path = "/", .request_id = 1 },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
}

test "dispatch: email.send wraps webhook.send with Resend shape" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var webhooks: std.ArrayListUnmanaged(webhook_server.WebhookRow) = .empty;
    defer {
        for (webhooks.items) |*r| r.deinit(testing.allocator);
        webhooks.deinit(testing.allocator);
    }
    var resp = try runOne(
        &d,
        kv,
        \\return email.send({
        \\  key: "re_test_abc",
        \\  from: "noreply@loop46.me",
        \\  to: "user@example.com",
        \\  subject: "Verify",
        \\  text: "Click me.",
        \\  onResult: "signup/email_result",
        \\  context: { user_id: 42 },
        \\});
    ,
        .{
            .method = "POST",
            .path = "/",
            .request_id = 7,
            .pending_webhooks = &webhooks,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 64), resp.body.len); // id hex

    try testing.expectEqual(@as(usize, 1), webhooks.items.len);
    const row = webhooks.items[0];

    try testing.expectEqualStrings("https://api.resend.com/emails", row.url);
    try testing.expectEqualStrings("POST", row.method);

    var headers = try std.json.parseFromSlice(std.json.Value, testing.allocator, row.headers_json, .{});
    defer headers.deinit();
    try testing.expectEqualStrings(
        "Bearer re_test_abc",
        headers.value.object.get("Authorization").?.string,
    );
    try testing.expectEqualStrings(
        "application/json",
        headers.value.object.get("Content-Type").?.string,
    );
    try testing.expectEqualStrings("signup/email_result", row.on_result_path);

    // Body is a JSON string; parse to check shape.
    var body_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, row.body, .{});
    defer body_parsed.deinit();
    const body_obj = body_parsed.value.object;
    try testing.expectEqualStrings("noreply@loop46.me", body_obj.get("from").?.string);
    try testing.expectEqualStrings("Verify", body_obj.get("subject").?.string);
    try testing.expectEqualStrings("Click me.", body_obj.get("text").?.string);
    // `to` gets array-wrapped even when passed as a string.
    try testing.expectEqual(@as(usize, 1), body_obj.get("to").?.array.items.len);
    try testing.expectEqualStrings("user@example.com", body_obj.get("to").?.array.items[0].string);
}

test "dispatch: email.send rejects missing key/from/to/subject" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    const cases = [_][]const u8{
        // Missing key.
        \\try { email.send({ from: "a@b.com", to: "c@d.com", subject: "s" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
        // Missing from.
        \\try { email.send({ key: "re_x", to: "c@d.com", subject: "s" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
        // Missing to.
        \\try { email.send({ key: "re_x", from: "a@b.com", subject: "s" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
        // Missing subject.
        \\try { email.send({ key: "re_x", from: "a@b.com", to: "c@d.com" }); return "ok"; }
        \\catch (e) { return "threw:" + e.message; }
        ,
    };

    for (cases) |src| {
        var resp = try runOne(&d, kv, src, .{ .method = "POST", .path = "/", .request_id = 1 });
        defer resp.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
    }
}

test "dispatch: crypto.hmacSha256 matches RFC 4231 test vector (string inputs)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // RFC 4231 test case 1:
    //   key  = 0x0b * 20  →  "" * 20
    //   data = "Hi There"
    //   expected = b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
    var resp = try runOne(
        &d,
        kv,
        \\const key = "\x0b".repeat(20);
        \\return crypto.hmacSha256(key, "Hi There");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        resp.body,
    );
}

test "dispatch: crypto.hmacSha256 accepts Uint8Array inputs" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Same RFC 4231 test case 1, both args as Uint8Array. Uses the
    // polyfilled TextEncoder to build UTF-8 bytes.
    var resp = try runOne(
        &d,
        kv,
        \\const key = new Uint8Array(20).fill(0x0b);
        \\const data = new TextEncoder().encode("Hi There");
        \\return crypto.hmacSha256(key, data);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        resp.body,
    );
}

test "dispatch: TextEncoder/TextDecoder round-trip multi-byte UTF-8" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // Includes 1-, 2-, 3-byte UTF-8 codepoints to exercise the
    // polyfill branches. (4-byte needs surrogate pairs which
    // JSON.stringify escapes — tested via a smaller surrogate case
    // below.)
    var resp = try runOne(
        &d,
        kv,
        \\const s = "hi ★ € 世";
        \\const bytes = new TextEncoder().encode(s);
        \\const back = new TextDecoder().decode(bytes);
        \\return {
        \\  byte_count: bytes.length,
        \\  first_byte: bytes[0],
        \\  round_trip_ok: back === s,
        \\  echo: back,
        \\};
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expectEqual(@as(i64, 'h'), out.value.object.get("first_byte").?.integer);
    try testing.expect(out.value.object.get("round_trip_ok").?.bool);
    try testing.expectEqualStrings("hi ★ € 世", out.value.object.get("echo").?.string);
}

test "dispatch: crypto.hmacSha256 throws on missing args" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { crypto.hmacSha256("one"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
}

test "dispatch: crypto.randomBytes returns Uint8Array of requested length" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\const a = crypto.randomBytes(32);
        \\const b = crypto.randomBytes(0);
        \\return {
        \\  ctor_a: a.constructor.name,
        \\  len_a: a.length,
        \\  ctor_b: b.constructor.name,
        \\  len_b: b.length,
        \\};
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    var out = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer out.deinit();
    try testing.expectEqualStrings("Uint8Array", out.value.object.get("ctor_a").?.string);
    try testing.expectEqual(@as(i64, 32), out.value.object.get("len_a").?.integer);
    try testing.expectEqualStrings("Uint8Array", out.value.object.get("ctor_b").?.string);
    try testing.expectEqual(@as(i64, 0), out.value.object.get("len_b").?.integer);
}

test "dispatch: crypto.randomBytes rejects out-of-range n" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // -1 → RangeError; 65537 → RangeError. Both must throw and the
    // catch produces a string starting "threw:".
    const cases = [_][]const u8{
        \\try { crypto.randomBytes(-1); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
        ,
        \\try { crypto.randomBytes(65537); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
        ,
    };
    for (cases) |src| {
        var resp = try runOne(&d, kv, src, .{ .method = "GET", .path = "/" });
        defer resp.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
    }
}

test "dispatch: crypto.sha256 matches empty-string test vector" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // SHA-256 of "" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var resp = try runOne(
        &d,
        kv,
        \\return crypto.sha256("");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        resp.body,
    );
}

test "dispatch: crypto.sha256 string and Uint8Array agree" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\const s = crypto.sha256("Hi There");
        \\const b = crypto.sha256(new TextEncoder().encode("Hi There"));
        \\return s === b ? "match:" + s : "mismatch";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "match:"));
}

test "dispatch: crypto.sha256 throws on missing arg" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { crypto.sha256(); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, resp.body, "threw:"));
}

test "dispatch: platform.instances.create throws on non-admin handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    // state.platform is null in vanilla runOne — the C callback should
    // throw a TypeError mentioning "admin handler".
    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.create("acme"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "admin handler") != null);
}

/// Thin wrapper around tenant test setup. Used by platform.instances.*
/// tests below to put a real `Tenant` behind `state.platform`.
const PlatformFixture = struct {
    allocator: std.mem.Allocator,
    tmp_dir: []u8,
    root_kv: *kv_mod.KvStore,
    tenant: *tenant_mod.Tenant,

    fn init(allocator: std.mem.Allocator) !PlatformFixture {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-disp-pf-{x}", .{seed});
        errdefer allocator.free(tmp_dir);
        std.fs.cwd().deleteTree(tmp_dir) catch {};
        try std.fs.cwd().makePath(tmp_dir);
        const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
        defer allocator.free(root_path);
        const root_kv = try kv_mod.KvStore.open(allocator, root_path);
        errdefer root_kv.close();
        const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
        return .{ .allocator = allocator, .tmp_dir = tmp_dir, .root_kv = root_kv, .tenant = tenant };
    }

    fn deinit(self: *PlatformFixture) void {
        self.tenant.destroy();
        self.root_kv.close();
        std.fs.cwd().deleteTree(self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
    }
};

test "dispatch: platform.instances.create creates instance and mirrors to root_writeset" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\platform.instances.create("acme");
        \\return "ok";
    ,
        .{
            .method = "POST",
            .path = "/",
            .platform = pf.tenant,
            .root_writeset = &root_ws,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);

    // Tenant has the instance in its in-memory map and root.db marker.
    try testing.expect(pf.tenant.instances.get("acme") != null);
    try testing.expectEqual(true, try pf.tenant.instanceExists("acme"));

    // Root writeset got the matching put for raft replication.
    try testing.expectEqual(@as(usize, 1), root_ws.ops.items.len);
    switch (root_ws.ops.items[0]) {
        .put => |p| {
            try testing.expectEqualStrings("instance/acme", p.key);
            try testing.expectEqualStrings("", p.value);
        },
        .delete => try testing.expect(false),
    }
}

test "dispatch: platform.instances.create is idempotent on existing instance" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    try pf.tenant.createInstance("acme"); // pre-existing
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\platform.instances.create("acme");
        \\platform.instances.create("acme");
        \\return "ok";
    ,
        .{
            .method = "POST",
            .path = "/",
            .platform = pf.tenant,
            .root_writeset = &root_ws,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);
}

test "dispatch: platform.instances.create throws coded InvalidName on bad name" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.create("has space"); return "no throw"; }
        \\catch (e) { return "code=" + e.code; }
    ,
        .{
            .method = "POST",
            .path = "/",
            .platform = pf.tenant,
            .root_writeset = &root_ws,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("code=InvalidName", resp.body);
    try testing.expectEqual(@as(usize, 0), root_ws.ops.items.len);
}

/// Stub for `platform.instances.deployStarter`'s trampoline. Records
/// the `target_id` it was called with and optionally fails with a
/// pre-set error. Matches the `Request.deploy_starter` signature.
const DeployStarterRecorder = struct {
    allocator: std.mem.Allocator,
    last_target_id: ?[]u8 = null,
    return_error: ?anyerror = null,
    call_count: u32 = 0,

    fn deinit(self: *DeployStarterRecorder) void {
        if (self.last_target_id) |s| self.allocator.free(s);
    }

    fn trampoline(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        target_id: []const u8,
    ) anyerror!void {
        const self: *DeployStarterRecorder = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        if (self.last_target_id) |old| {
            self.allocator.free(old);
            self.last_target_id = null;
        }
        self.last_target_id = self.allocator.dupe(u8, target_id) catch null;
        if (self.return_error) |err| return err;
    }
};

test "dispatch: platform.instances.deployStarter throws on non-admin handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.deployStarter("acme"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "admin handler") != null);
}

test "dispatch: platform.instances.deployStarter throws when trampoline not configured" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    // Admin platform set, but no deploy_starter fn pointer (test path
    // / library mode without a worker). Should throw a clear error
    // rather than silently no-op.
    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.deployStarter("acme"); return "no throw"; }
        \\catch (e) { return "threw: " + e.message; }
    ,
        .{
            .method = "POST",
            .path = "/",
            .platform = pf.tenant,
            .root_writeset = &root_ws,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "not configured") != null);
}

test "dispatch: platform.instances.deployStarter invokes trampoline with name" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var rec = DeployStarterRecorder{ .allocator = testing.allocator };
    defer rec.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\platform.instances.deployStarter("acme");
        \\return "ok";
    ,
        .{
            .method = "POST",
            .path = "/",
            .platform = pf.tenant,
            .root_writeset = &root_ws,
            .deploy_starter = &DeployStarterRecorder.trampoline,
            .deploy_starter_ctx = &rec,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("ok", resp.body);
    try testing.expectEqual(@as(u32, 1), rec.call_count);
    try testing.expectEqualStrings("acme", rec.last_target_id.?);
}

test "dispatch: platform.instances.deployStarter throws coded InstanceNotFound" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var pf = try PlatformFixture.init(testing.allocator);
    defer pf.deinit();
    var root_ws = kv_mod.WriteSet.init(testing.allocator);
    defer root_ws.deinit();

    var rec = DeployStarterRecorder{
        .allocator = testing.allocator,
        .return_error = error.InstanceNotFound,
    };
    defer rec.deinit();

    var resp = try runOne(
        &d,
        kv,
        \\try { platform.instances.deployStarter("missing"); return "no throw"; }
        \\catch (e) { return "code=" + e.code; }
    ,
        .{
            .method = "POST",
            .path = "/",
            .platform = pf.tenant,
            .root_writeset = &root_ws,
            .deploy_starter = &DeployStarterRecorder.trampoline,
            .deploy_starter_ctx = &rec,
        },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqualStrings("code=InstanceNotFound", resp.body);
}

test "dispatch: email.send accepts array `to`, `cc`, `bcc`" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }
    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

    var webhooks: std.ArrayListUnmanaged(webhook_server.WebhookRow) = .empty;
    defer {
        for (webhooks.items) |*r| r.deinit(testing.allocator);
        webhooks.deinit(testing.allocator);
    }
    var resp = try runOne(
        &d,
        kv,
        \\return email.send({
        \\  key: "re_x",
        \\  from: "a@b.com",
        \\  to: ["c@d.com", "e@f.com"],
        \\  cc: "g@h.com",
        \\  bcc: ["i@j.com"],
        \\  subject: "s",
        \\  text: "t",
        \\});
    ,
        .{
            .method = "POST",
            .path = "/",
            .request_id = 2,
            .pending_webhooks = &webhooks,
        },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), webhooks.items.len);
    var body = try std.json.parseFromSlice(std.json.Value, testing.allocator, webhooks.items[0].body, .{});
    defer body.deinit();

    try testing.expectEqual(@as(usize, 2), body.value.object.get("to").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.value.object.get("cc").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.value.object.get("bcc").?.array.items.len);
}

// ── Triggers (PLAN §2.5) ──────────────────────────────────────────────

test "trigger: afterPut fires after a kv.set inside the handler" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    // Two modules: handler at index.mjs writes a session;
    // trigger at _triggers/users/sessions/index.mjs maintains
    // a reverse index `users/by-session/{sid} -> user_id`.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/sessions/abc", JSON.stringify({ user_id: "u42" }));
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const sess = JSON.parse(event.value);
        \\  const sid = event.key.split('/').pop();
        \\  kv.set("users/by-session/" + sid, sess.user_id);
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/users/sessions/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("users/sessions/"),
        .module_path = @constCast("_triggers/users/sessions/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("ok", resp.body);

    // Trigger should have written the reverse-index row.
    const indexed = try kv.get("users/by-session/abc");
    defer testing.allocator.free(indexed);
    try testing.expectEqualStrings("u42", indexed);
}

test "trigger: afterDelete fires with previousValue" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("orders/o1", JSON.stringify({ total: 100 }));
        \\  kv.delete("orders/o1");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterDelete(event) {
        \\  if (event.previousValue) {
        \\    const order = JSON.parse(event.previousValue);
        \\    kv.set("audit/deleted-totals", String(order.total));
        \\  }
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const audit = try kv.get("audit/deleted-totals");
    defer testing.allocator.free(audit);
    try testing.expectEqualStrings("100", audit);
}

test "trigger: tree-traversal order — outer + inner both fire on AFTER" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Write to users/sessions/abc → matches both
    // _triggers/users/index.mjs AND _triggers/users/sessions/index.mjs.
    // Each appends its name to a marker key so we can verify both fired
    // and in the right order (innermost-first for AFTER).
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/sessions/abc", "v");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const inner_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "inner;");
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(inner_bc);

    const outer_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "outer;");
        \\}
    , "_triggers/users/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(outer_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/users/sessions/index.mjs", inner_bc);
    try bytecodes.put(testing.allocator, "_triggers/users/index.mjs", outer_bc);

    // Sorted longest-first → forward iteration is innermost-first.
    const triggers = [_]globals.TriggerEntry{
        .{ .prefix = @constCast("users/sessions/"), .module_path = @constCast("_triggers/users/sessions/index.mjs") },
        .{ .prefix = @constCast("users/"), .module_path = @constCast("_triggers/users/index.mjs") },
    };

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
    defer testing.allocator.free(trace);
    // AFTER chain fires innermost-first per PLAN §2.5.
    try testing.expectEqualStrings("inner;outer;", trace);
}

test "trigger: cascade depth limit halts runaway recursion" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Trigger that writes another key that matches itself → infinite
    // cascade. The depth cap must throw and abort the handler.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("loop/0", "x");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  const n = parseInt(event.key.split('/').pop()) + 1;
        \\  kv.set("loop/" + n, "x");
        \\}
    , "_triggers/loop/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/loop/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("loop/"),
        .module_path = @constCast("_triggers/loop/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    // Handler doesn't catch → throw bubbles up, populates exception.
    try testing.expect(resp.exception.len > 0);
    try testing.expect(std.mem.indexOf(u8, resp.exception, "depth") != null);
}

test "trigger: platform-key writes do not fire customer triggers" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Customer's catch-all trigger would fire on every write, BUT
    // `_callback/...` is a platform key — the fire-time guard skips
    // dispatch so the customer's afterPut never sees system writes.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("_callback/sys-write", "x");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export default function (event) {
        \\  kv.set("seen/" + event.key, "1");
        \\}
    , "_triggers/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast(""),
        .module_path = @constCast("_triggers/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    // Trigger SHOULD NOT have written `seen/_callback/sys-write`.
    try testing.expectError(error.NotFound, kv.get("seen/_callback/sys-write"));
}

test "trigger: beforePut throw is catchable in handler with code='trigger_rejected'" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler tries to write a session with no user_id; trigger rejects.
    // Handler catches and reports the error code.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  try {
        \\    kv.set("users/sessions/abc", JSON.stringify({}));
        \\    return "should not reach";
        \\  } catch (e) {
        \\    return "code=" + e.code + " msg=" + e.message;
        \\  }
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const sess = JSON.parse(event.value);
        \\  if (!sess.user_id) throw new Error("session missing user_id");
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/users/sessions/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("users/sessions/"),
        .module_path = @constCast("_triggers/users/sessions/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    // code=trigger_rejected, message="<trigger_path>: <original>"
    try testing.expect(std.mem.indexOf(u8, resp.body, "code=trigger_rejected") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "session missing user_id") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "_triggers/users/sessions/index.mjs") != null);

    // The rejected write should NOT be in kv.
    try testing.expectError(error.NotFound, kv.get("users/sessions/abc"));
}

test "trigger: beforePut return-value mutates the written value" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Trigger lowercases the value before storage.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/abc", "ALICE");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  return event.value.toLowerCase();
        \\}
    , "_triggers/users/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/users/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("users/"),
        .module_path = @constCast("_triggers/users/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const stored = try kv.get("users/abc");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings("alice", stored);
}

test "trigger: beforePut throw rolls back trigger-internal writes (the audit gotcha)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Documents the gotcha: a BEFORE that writes an audit row and then
    // throws does NOT keep the audit row — it gets rolled back with
    // the originating write. Customer must use afterPut for "log
    // every accepted write" and the handler itself for "log every
    // rejected attempt." See PLAN §2.5 implementation notes.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  try { kv.set("orders/o1", "{}"); } catch (e) {}
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  kv.set("audit/last-attempt", event.key);
        \\  throw new Error("nope");
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    // Both the originating write AND the trigger's audit write are
    // rolled back by the inner savepoint (audit gotcha).
    try testing.expectError(error.NotFound, kv.get("orders/o1"));
    try testing.expectError(error.NotFound, kv.get("audit/last-attempt"));
}

test "trigger: afterPut throw is catchable AND rolls back the originating write" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler sets a key, AFTER throws, handler catches. Per PLAN
    // §2.5 the originating write must be rolled back even though
    // the handler caught the exception (inner savepoint covers
    // BEFORE+write+AFTER).
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  try {
        \\    kv.set("orders/o1", "{}");
        \\    return "no throw";
        \\  } catch (e) {
        \\    return "caught: code=" + e.code;
        \\  }
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  throw new Error("after rejected");
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);
    try testing.expectEqualStrings("caught: code=trigger_rejected", resp.body);

    // Originating write rolled back via inner savepoint.
    try testing.expectError(error.NotFound, kv.get("orders/o1"));
}

test "trigger: BEFORE chain runs outermost-first (broad validates before narrow)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Two BEFORE triggers: outer + inner. Each appends to a marker.
    // BEFORE chain should fire outermost-first (opposite of AFTER).
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("users/sessions/abc", "v");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const inner_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "inner;");
        \\}
    , "_triggers/users/sessions/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(inner_bc);

    const outer_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + "outer;");
        \\}
    , "_triggers/users/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(outer_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/users/sessions/index.mjs", inner_bc);
    try bytecodes.put(testing.allocator, "_triggers/users/index.mjs", outer_bc);

    // Sorted longest-first → reverse iteration is outermost-first
    // (correct for BEFORE chain).
    const triggers = [_]globals.TriggerEntry{
        .{ .prefix = @constCast("users/sessions/"), .module_path = @constCast("_triggers/users/sessions/index.mjs") },
        .{ .prefix = @constCast("users/"), .module_path = @constCast("_triggers/users/index.mjs") },
    };

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
    defer testing.allocator.free(trace);
    // BEFORE: outer first, then inner. (AFTER would be inner;outer; — see earlier test.)
    try testing.expectEqualStrings("outer;inner;", trace);
}

test "trigger: default export is the catchall when no named export matches" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Trigger only exports `default`. Should fire for both put and
    // delete (and both before+after if they're not separately named).
    // Test: put + delete + verify default ran twice with the right
    // event.op + event.timing values.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("orders/o1", "{}");
        \\  kv.delete("orders/o1");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export default function (event) {
        \\  const cur = kv.get("trace") || "";
        \\  kv.set("trace", cur + event.timing + ":" + event.op + ";");
        \\}
    , "_triggers/orders/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/orders/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("orders/"),
        .module_path = @constCast("_triggers/orders/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
    defer testing.allocator.free(trace);
    // put fires before+after (catchall handles both); then delete
    // fires before+after. AFTER innermost-first, BEFORE outermost-first
    // — but only one trigger here, so order is: before:put, after:put,
    // before:delete, after:delete.
    try testing.expectEqualStrings("before:put;after:put;before:delete;after:delete;", trace);
}

test "trigger: BEFORE sees previousValue on update" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler puts twice. Trigger captures (previousValue, value) on
    // each put so we can verify the second one saw the first's bytes
    // as previousValue.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("docs/d1", "v1");
        \\  kv.set("docs/d1", "v2");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const trigger_bc = try ctx.compileToBytecode(
        \\export function beforePut(event) {
        \\  const cur = kv.get("trace") || "";
        \\  const prev = event.previousValue === null ? "<null>" : event.previousValue;
        \\  kv.set("trace", cur + prev + "->" + event.value + ";");
        \\}
    , "_triggers/docs/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/docs/index.mjs", trigger_bc);

    const triggers = [_]globals.TriggerEntry{.{
        .prefix = @constCast("docs/"),
        .module_path = @constCast("_triggers/docs/index.mjs"),
    }};

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    const trace = try kv.get("trace");
    defer testing.allocator.free(trace);
    // First put: previousValue is null (no existing key). Second put:
    // previousValue is "v1" (the just-written first value, visible
    // via TrackedTxn read-your-writes).
    try testing.expectEqualStrings("<null>->v1;v1->v2;", trace);
}

test "trigger: well-bounded cascade (depth 2, no runaway)" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Handler writes A; A's afterPut writes B (different prefix,
    // different trigger); B's afterPut writes C (no matching trigger,
    // chain ends). Verify event.depth reflects the cascade level.
    const handler_bc = try ctx.compileToBytecode(
        \\export default function () {
        \\  kv.set("a/x", "a-value");
        \\  return "ok";
        \\}
    , "index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(handler_bc);

    const a_trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  kv.set("trace_a", "depth=" + event.depth);
        \\  kv.set("b/y", "b-from-a");
        \\}
    , "_triggers/a/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(a_trigger_bc);

    const b_trigger_bc = try ctx.compileToBytecode(
        \\export function afterPut(event) {
        \\  kv.set("trace_b", "depth=" + event.depth);
        \\  kv.set("c/z", "c-from-b");  // no matching trigger, chain ends
        \\}
    , "_triggers/b/index.mjs", testing.allocator, .{ .kind = .module });
    defer testing.allocator.free(b_trigger_bc);

    var bytecodes: std.StringHashMapUnmanaged([]u8) = .empty;
    defer bytecodes.deinit(testing.allocator);
    try bytecodes.put(testing.allocator, "_triggers/a/index.mjs", a_trigger_bc);
    try bytecodes.put(testing.allocator, "_triggers/b/index.mjs", b_trigger_bc);

    const triggers = [_]globals.TriggerEntry{
        .{ .prefix = @constCast("a/"), .module_path = @constCast("_triggers/a/index.mjs") },
        .{ .prefix = @constCast("b/"), .module_path = @constCast("_triggers/b/index.mjs") },
    };

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, handler_bc, &bytecodes, null, &triggers, .{
        .method = "GET",
        .path = "/",
    }, &budget);
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 200), resp.status);

    // Trigger A fires at depth 1 (handler invocation is depth 0).
    const trace_a = try kv.get("trace_a");
    defer testing.allocator.free(trace_a);
    try testing.expectEqualStrings("depth=1", trace_a);

    // Trigger B fires at depth 2 (cascade from A).
    const trace_b = try kv.get("trace_b");
    defer testing.allocator.free(trace_b);
    try testing.expectEqualStrings("depth=2", trace_b);

    // All three writes landed.
    const c_value = try kv.get("c/z");
    defer testing.allocator.free(c_value);
    try testing.expectEqualStrings("c-from-b", c_value);
}
