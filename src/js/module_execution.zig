//! Module execution — loading + running a tenant's JS module against one
//! request. Extracted from `dispatcher.zig`. These are the engine ops the
//! `Dispatcher` drives each activation: load bytecode, evaluate the module
//! top level, run `_middlewares/index.mjs`'s `before`, then dispatch the
//! named export. They take a `*Dispatcher` + a `*PendingResponse` that the
//! dispatcher's `runOutcome` owns, so this file and `dispatcher.zig` import
//! each other (Zig resolves the cycle lazily). `PendingResponse` — the
//! per-run response accumulator the run* fns populate — lives here;
//! `dispatcher.zig` aliases it back for `finishResponse`.

const std = @import("std");
const qjs = @import("rove-qjs");
const c = qjs.c;
const tape_mod = @import("rove-tape");

const dispatcher = @import("dispatcher.zig");
const Dispatcher = dispatcher.Dispatcher;
const Budget = dispatcher.Budget;
const DispatchError = dispatcher.DispatchError;

const globals = @import("globals.zig");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const ResponseHeader = request_mod.ResponseHeader;
const rpc_dispatch = @import("rpc_dispatch.zig");
const response_building = @import("response_building.zig");
const continuation_mod = @import("bindings/continuation.zig");
const bytecode_cache_mod = @import("bytecode_cache.zig");
const BlobBytes = bytecode_cache_mod.BlobBytes;

const RunError = error{ Interrupted, OutOfMemory, JsException };

/// Mutable response state accumulated across the dispatcher's run.
/// Bundled so the helpers and the run* functions take one pointer
/// instead of six out-params each. `finishResponse` consumes it
/// (cookies/headers via `toOwnedSlice`, body/exception via direct
/// transfer); on the error paths the caller's errdefer fires
/// `deinit` to free anything still owned here.
pub const PendingResponse = struct {
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
    /// Set by the handler path when the return value is a branded
    /// `next(...)` descriptor. Transient (consumed by `finishResponse`
    /// into the `RunOutcome.continuation` arm); never travels with an
    /// h2 entity. Handler-path only — middleware may not return a
    /// continuation in v1 (plan §3b B6).
    continuation: ?continuation_mod.Continuation = null,
    /// Set by `runModule` when an `.inbound_headers` probe found no
    /// `onHeaders` export. `finishResponse` maps it to
    /// `RunOutcome.no_onheaders` — the dispatch site falls back to
    /// classic body buffering instead of a 404.
    no_onheaders: bool = false,
    pub fn deinit(self: *PendingResponse, allocator: std.mem.Allocator) void {
        if (self.continuation) |*cont| cont.deinit(allocator);
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
pub fn loadModuleBytecode(
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
        pending.exception = response_building.jsValueToOwned(d.allocator, ctx.raw, reason) catch
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

    const final = response_building.unwrapPromise(ctx.raw, ret_val.raw);
    if (final.rejected) {
        pending.exception = response_building.jsValueToOwned(d.allocator, ctx.raw, final.val) catch
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
    try response_building.bodyFromReturn(d.allocator, ctx.raw, val, &pending.body, &pending.body_is_json);
    try response_building.extractResponseMetadata(d.allocator, ctx.raw, &pending.status, &pending.cookies, &pending.headers);
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
pub fn runMiddleware(
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
pub fn runModule(
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
    var dispatch = rpc_dispatch.parseDispatch(d.allocator, request) catch |err| switch (err) {
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
        // Handler-surface Phase 4: a missing `onDisconnect` is a no-op,
        // not a 404 — disconnect cleanup is optional (the held stream
        // closes regardless). Other kinds (onWake, etc.) DO require the
        // export; the §6 deploy-time coverage lint flags those.
        if (request.activation == .disconnect) {
            _ = ctx.takeException();
            return;
        }
        // Headers-first probe: a module without `onHeaders` wants the
        // classic buffered path — signal the dispatch site to buffer
        // + re-dispatch instead of 404ing (`docs/architecture/routing-and-ingress.md`
        // §3.5: "exports onHeaders → headers-first" is one dispatch
        // row, and its absence is the normal case, not an error).
        if (request.activation == .inbound_headers) {
            _ = ctx.takeException();
            pending.no_onheaders = true;
            return;
        }
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

    // Trampoline classification — handler path ONLY (middleware may
    // not return a continuation in v1, plan §3b B6, so this is not in
    // the shared `extractBodyAndMeta`). A branded `next(...)` return
    // short-circuits the body path; `finishResponse` hands it up as
    // `RunOutcome.continuation` and the entity moves to
    // `parked_continuations` upstream (collection membership, not a
    // persisted discriminant).
    if (try continuation_mod.tryExtract(d.allocator, ctx.raw, result.val)) |cont| {
        pending.continuation = cont;
        // Handler-surface Phase 2: a `stream.*` + `next()` activation
        // commits the ambient `response.*` head NOW (stream.start). A
        // plain `next()` defers the head — nothing to capture. Pull
        // status/headers/cookies so `finishResponse`'s stream bridge has
        // them (a bare continuation skips this and the head stays open).
        const st = globals.getState(ctx.raw);
        if (st.stream_started) {
            response_building.extractResponseMetadata(d.allocator, ctx.raw, &pending.status, &pending.cookies, &pending.headers) catch
                return error.OutOfMemory;
        }
        return;
    }
    // Handler-surface Phase 2: the `__rove_stream(...)` return verb is
    // gone — a streaming handler returns `next()` (handled above, with
    // the ambient head captured when `stream_started`) and produces
    // output via the `stream.*` effects, which `finishResponse` bridges
    // to the internal Stream descriptor.

    // Body from return value. Status / cookies from the ambient
    // `response` global.
    extractBodyAndMeta(d, ctx, result.val, pending) catch
        return error.OutOfMemory;
}

fn budgetExpired(budget: *Budget) bool {
    const now: i64 = @intCast(std.time.nanoTimestamp());
    return now >= budget.deadline_ns;
}

// ── Module loader ──────────────────────────────────────────────────────

/// Shared module loader infrastructure. Mounted onto the per-request
/// runtime via `JS_SetModuleLoaderFunc` so `import { x } from "./y.mjs"`
/// in handlers resolves against the deployment's bytecode map.
pub const module_loader = struct {
    pub const Ctx = struct {
        allocator: std.mem.Allocator,
        /// Path → bytecode lease into the node-wide cache. Null
        /// means the caller opted out of imports (tests, trivial
        /// single-file handlers).
        bytecodes: ?*const std.StringHashMapUnmanaged(*BlobBytes),
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
        const bb = map.get(name_s) orelse return null;
        const obj = c.JS_ReadObject(ctx, bb.bytes.ptr, bb.bytes.len, c.JS_READ_OBJ_BYTECODE);
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

