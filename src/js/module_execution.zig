// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Module execution — loading + running a tenant's JS module against one
//! request. These are the engine ops the
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
const files_mod = @import("rove-files"); // manifest_json (resolver build)
// Pure `@scope/pkg` resolution, shared verbatim with the offline simulator
// (`src/replay/`) so the two can't drift. The qjs `normalize` glue below wraps
// it. Re-exported so existing consumers keep the `module_execution.*` spelling.
const package_resolver = @import("package_resolver.zig");
pub const PackageResolver = package_resolver.PackageResolver;
pub const buildResolver = package_resolver.buildResolver;
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
    /// Set by `runModule` when an `.inbound_chunk` probe found no
    /// `onChunk` export. `finishResponse` maps it to
    /// `RunOutcome.no_onchunk` — the dispatch site falls back to the
    /// classic `.inbound` dispatch instead of a 404.
    no_onchunk: bool = false,
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
/// (fn = the resume path's `Request.fn_override`, else the activation
/// kind's conventional export — `rpc_dispatch.parseDispatch`), and
/// call it with no positional arguments (resume payloads ride
/// `request.body` / `request.activation`). The return value becomes
/// the response body; status/headers/cookies come from the ambient
/// `response` global. See `Dispatcher.run` for the full contract.
pub fn runModule(
    d: *Dispatcher,
    rt: *qjs.Runtime,
    ctx: *qjs.Context,
    fun_val_in: qjs.Value,
    request: Request,
    /// The activation object from `globals.installRequest` — the single
    /// argument the export receives
    /// (`docs/architecture/package-isolation.md`, the
    /// received-not-ambient model). Borrowed; the caller owns it.
    activation: c.JSValue,
    budget: *Budget,
    pending: *PendingResponse,
) RunError!void {
    const ns = try evalModule(d, rt, ctx, fun_val_in, budget, pending);
    defer c.JS_FreeValue(ctx.raw, ns);

    // ── Resolve the target export for this activation. ─────
    const fn_name = try rpc_dispatch.parseDispatch(d.allocator, request);
    defer d.allocator.free(fn_name);

    const fn_name_z = std.fmt.allocPrintSentinel(d.allocator, "{s}", .{fn_name}, 0) catch
        return error.OutOfMemory;
    defer d.allocator.free(fn_name_z);

    const handler = c.JS_GetPropertyStr(ctx.raw, ns, fn_name_z.ptr);
    defer c.JS_FreeValue(ctx.raw, handler);
    if (c.JS_IsException(handler) or !c.JS_IsFunction(ctx.raw, handler)) {
        // A missing `onDisconnect` is a no-op,
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
        // Chunk-dispatch probe: a module without `onChunk`
        // wants the classic buffered path — same fall-back posture as
        // the `onHeaders` probe above, not a 404.
        if (request.activation == .inbound_chunk) {
            _ = ctx.takeException();
            pending.no_onchunk = true;
            return;
        }
        pending.status = 404;
        pending.body = std.fmt.allocPrint(
            d.allocator,
            "module export \"{s}\" not found or not a function\n",
            .{fn_name},
        ) catch return error.OutOfMemory;
        return;
    }

    // The export receives ONE argument: the activation object
    // (`docs/architecture/package-isolation.md`, the received-not-ambient
    // model), carrying `request`/`response` as own properties and the
    // capabilities by prototype. Resume payloads (ctx / outcome) still
    // ride `request.body` and the typed `request.activation` union, read
    // through the request surface so every read is taped
    // (decisions.md §4.5) — reaching that surface by parameter rather
    // than by free variable changes nothing about taping, because the
    // accessors live on the object.
    var argv = [_]c.JSValue{activation};
    const ret = c.JS_Call(
        ctx.raw,
        handler,
        globals.js_undefined,
        argv.len,
        &argv,
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
        // A `stream.*` + `next()` activation
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
    // A streaming handler returns `next()` (handled above, with the
    // ambient head captured when `stream_started`) and produces output
    // via the `stream.*` effects, which `finishResponse` bridges to the
    // internal Stream descriptor. There is no `__rove_stream(...)` return
    // verb.

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
        /// Package-manager resolution (PM P0). Maps `@scope/pkg` bare
        /// specifiers to package-virtual keys (`/pkg/<pkg_hash>/index.mjs`)
        /// per-importer. Null ⇒ no packages ⇒ plain path resolution (every
        /// current deployment). See `docs/architecture/package-resolution.md`.
        resolver: ?*const PackageResolver = null,
        /// Path → SOURCE, consulted when `bytecodes` has no entry: the
        /// deploy-time compile of a bundle, where a module's siblings exist
        /// only as source that has not been compiled yet.
        ///
        /// Needed because compilation resolves imports EAGERLY — quickjs runs
        /// `js_resolve_module` even under `COMPILE_ONLY` — so compiling
        /// `index.mjs` pulls in every module it imports, transitively. Without
        /// this a handler could not import a sibling handler at all (#344).
        /// Compiling on demand here is the same recursion quickjs would drive
        /// for bytecode; a source that imports another source resolves through
        /// this path again.
        sources: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    };

    /// Normalize `specifier` (relative or bare) against the importing
    /// module's `base_name` into a canonical path key. Returns a
    /// js_malloc'd buffer — quickjs owns it after this call.
    pub fn normalize(
        ctx: ?*c.JSContext,
        base: [*c]const u8,
        name: [*c]const u8,
        opaque_ptr: ?*anyopaque,
    ) callconv(.c) [*c]u8 {
        const base_s = if (base != null) std.mem.span(base) else "";
        const name_s = if (name != null) std.mem.span(name) else "";

        // A bare `@scope/pkg` specifier resolves via the
        // per-importer package resolver (app_imports for an app handler,
        // the importing package's own imports for a `/pkg/…` importer).
        // A miss falls through to the string resolver below, so relative
        // imports and `__system/*` builtins are untouched.
        if (opaque_ptr) |op| {
            const self: *const Ctx = @ptrCast(@alignCast(op));
            if (self.resolver) |r| {
                if (!std.mem.startsWith(u8, name_s, "./") and !std.mem.startsWith(u8, name_s, "../")) {
                    if (r.resolve(base_s, name_s)) |key| {
                        return dupToJs(ctx, key);
                    }
                }
            }
        }

        const resolved = package_resolver.resolveSpecifier(base_s, name_s, static_buf[0..]);
        return dupToJs(ctx, resolved);
    }

    /// Copy `s` into a qjs-allocated NUL-terminated buffer quickjs owns.
    fn dupToJs(ctx: ?*c.JSContext, s: []const u8) [*c]u8 {
        const out = c.js_malloc(ctx, s.len + 1) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(out))[0..s.len], s);
        @as([*]u8, @ptrCast(out))[s.len] = 0;
        return @ptrCast(out);
    }

    /// Compile `src` as a module named `name` and hand quickjs its module
    /// def. The mirror of the bytecode path below: `JS_ReadObject` yields a
    /// module-tagged value there, `JS_Eval` under `COMPILE_ONLY` yields one
    /// here, and both drop the value handle because the def carries its own
    /// reference. A syntax error inside the sibling surfaces as that module's
    /// exception, naming the file the author has to fix.
    fn compileSourceModule(ctx: ?*c.JSContext, name: []const u8, src: []const u8) ?*c.JSModuleDef {
        // quickjs reads one byte past `len` when validating UTF-8, so the
        // buffer must be NUL-terminated (the same trap `compileToBytecode`
        // documents). Sources here come from a HashMap and carry no sentinel.
        const a = std.heap.c_allocator;
        const src_z = a.allocSentinel(u8, src.len, 0) catch return null;
        defer a.free(src_z);
        @memcpy(src_z, src);
        const name_z = a.allocSentinel(u8, name.len, 0) catch return null;
        defer a.free(name_z);
        @memcpy(name_z, name);

        const val = c.JS_Eval(ctx, src_z.ptr, src.len, name_z.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
        if (c.JS_IsException(val)) return null;
        if (val.tag != c.JS_TAG_MODULE) {
            c.JS_FreeValue(ctx, val);
            _ = c.JS_ThrowReferenceError(ctx, "source for '%s' did not compile to a module", name_z.ptr);
            return null;
        }
        const def: ?*c.JSModuleDef = @ptrCast(@alignCast(val.u.ptr));
        c.JS_FreeValue(ctx, val);
        return def;
    }

    pub fn load(
        ctx: ?*c.JSContext,
        name: [*c]const u8,
        opaque_ptr: ?*anyopaque,
    ) callconv(.c) ?*c.JSModuleDef {
        const self: *const Ctx = @ptrCast(@alignCast(opaque_ptr.?));
        const name_s = std.mem.span(name);
        // quickjs contract: when a loader func is installed and returns
        // NULL, quickjs does NOT throw for us (it only synthesizes
        // "could not load module" when NO loader is installed) — a
        // silent null here surfaces as an exception-less failure
        // ("[uninitialized]"). Throw the canonical message ourselves so
        // compile-time validation and runtime load failures both name
        // the module.
        const bb = blk: {
            if (self.bytecodes) |map| {
                if (map.get(name_s)) |hit| break :blk hit;
            }
            // No bytecode: at deploy time the module may exist only as a
            // source sibling in the same bundle. Compile it here — the
            // resolution quickjs is in the middle of doing needs a module
            // def, and this is the only point that can supply one.
            if (self.sources) |srcs| {
                if (srcs.get(name_s)) |src| return compileSourceModule(ctx, name_s, src);
            }
            _ = c.JS_ThrowReferenceError(ctx, "could not load module '%s'", name);
            return null;
        };
        const obj = c.JS_ReadObject(ctx, bb.bytes.ptr, bb.bytes.len, c.JS_READ_OBJ_BYTECODE);
        if (c.JS_IsException(obj)) return null;
        if (obj.tag != c.JS_TAG_MODULE) {
            c.JS_FreeValue(ctx, obj);
            _ = c.JS_ThrowReferenceError(ctx, "module blob for '%s' is not a module", name);
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


const testing = std.testing;

fn expectGlobalStr(ctx_raw: ?*c.JSContext, global: c.JSValue, name: [*:0]const u8, want: []const u8) !void {
    const v = c.JS_GetPropertyStr(ctx_raw, global, name);
    defer c.JS_FreeValue(ctx_raw, v);
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx_raw, &len, v);
    defer c.JS_FreeCString(ctx_raw, cstr);
    try testing.expectEqualStrings(want, @as([*]const u8, @ptrCast(cstr))[0..len]);
}

test "PM: compile validates resolution but does NOT bake it — same source+filename → identical bytes under different pins" {
    // quickjs's JS_Eval(COMPILE_ONLY) runs js_resolve_module (normalize +
    // load every import — compile FAILS if the loader can't serve them),
    // but JS_WriteModule serializes only the module's OWN name + the
    // AS-WRITTEN specifiers; JS_ReadModule re-resolves through the live
    // loader on every load. So bytecode = f(source, filename) — the pin
    // lives in the snapshot resolver, never in the handler bytes. This
    // test is the teeth on that claim (package-compile-caching.md).
    const a = testing.allocator;
    const J19 = "b" ** 64;
    const J14 = "c" ** 64;

    var bc_by_pin: [2][]u8 = undefined;
    var got: usize = 0;
    defer for (bc_by_pin[0..got]) |bc| a.free(bc);

    inline for ([_][:0]const u8{ "/pkg/" ++ J19 ++ "/index.mjs", "/pkg/" ++ J14 ++ "/index.mjs" }) |jwt_key| {
        var rt = try qjs.Runtime.init();
        defer rt.deinit();
        var ctx = try rt.newContext();
        defer ctx.deinit();

        var app_imports: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer app_imports.deinit(a);
        try app_imports.put(a, "@rewind/jwt", jwt_key);
        var resolver = PackageResolver{ .app_imports = app_imports, .pkg_imports = .empty };

        var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
        defer bytecodes.deinit(a);
        const dep_bc = try ctx.compileToBytecode("export const v = 1;", jwt_key, a, .{ .kind = .module });
        defer a.free(dep_bc);
        var dep_bb = BlobBytes{ .bytes = dep_bc, .hash_hex = @splat('x'), .refcount = std.atomic.Value(u32).init(1) };
        try bytecodes.put(a, jwt_key, &dep_bb);

        var lctx = module_loader.Ctx{ .allocator = a, .bytecodes = &bytecodes, .resolver = &resolver };
        c.JS_SetModuleLoaderFunc(rt.raw, module_loader.normalize, module_loader.load, &lctx);

        bc_by_pin[got] = try ctx.compileToBytecode(
            "import {v} from '@rewind/jwt'; export const out = v;",
            "index.mjs", a, .{ .kind = .module });
        got += 1;
    }
    try testing.expectEqualSlices(u8, bc_by_pin[0], bc_by_pin[1]);
}

test "PM P1 fixture smoke: manifest → buildResolver → quickjs resolves an encapsulated multi-version chain" {
    const a = testing.allocator;
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Two jwt versions + oidc. oidc imports @rewind/jwt (→ its OWN jwt@1.4);
    // the app also imports @rewind/jwt (→ jwt@1.9). Same specifier, two
    // versions coexisting — the encapsulation guarantee, end to end.
    const OIDC = "a" ** 64;
    const JWT19 = "b" ** 64;
    const JWT14 = "c" ** 64;
    const H = "d" ** 64; // filler file hashes (unused by resolution)

    // Build the resolver from a REAL v2 manifest (exercises decode + buildResolver).
    const mbytes =
        "{\"v\":2,\"deployment_id\":\"0000000000000001\",\"entries\":[]," ++
        "\"packages\":[" ++
        "{\"spec\":\"@rewind/oidc\",\"version\":\"2.0.0\",\"pkg_hash\":\"" ++ OIDC ++ "\"," ++
        "\"files\":[{\"path\":\"index.mjs\",\"bytecode_hash\":\"" ++ H ++ "\",\"source_hash\":\"" ++ H ++ "\"}]," ++
        "\"imports\":{\"@rewind/jwt\":\"" ++ JWT14 ++ "\"},\"capabilities\":[]}," ++
        "{\"spec\":\"@rewind/jwt\",\"version\":\"1.9.0\",\"pkg_hash\":\"" ++ JWT19 ++ "\"," ++
        "\"files\":[{\"path\":\"index.mjs\",\"bytecode_hash\":\"" ++ H ++ "\",\"source_hash\":\"" ++ H ++ "\"}]," ++
        "\"imports\":{},\"capabilities\":[]}," ++
        "{\"spec\":\"@rewind/jwt\",\"version\":\"1.4.0\",\"pkg_hash\":\"" ++ JWT14 ++ "\"," ++
        "\"files\":[{\"path\":\"index.mjs\",\"bytecode_hash\":\"" ++ H ++ "\",\"source_hash\":\"" ++ H ++ "\"}]," ++
        "\"imports\":{},\"capabilities\":[],\"private\":true}" ++
        "]," ++
        "\"app_imports\":{\"@rewind/oidc\":\"" ++ OIDC ++ "\",\"@rewind/jwt\":\"" ++ JWT19 ++ "\"}}";
    var manifest = try files_mod.manifest_json.decode(a, mbytes);
    defer manifest.deinit();
    var resolver = try buildResolver(a, manifest.packages, manifest.app_imports);
    defer resolver.deinit(a);

    // quickjs resolves + loads module imports at COMPILE time (a validation
    // gate — compile fails if an import can't resolve), so the loader
    // (resolver + map) must be live before compiling, and packages compile in
    // dependency order (leaves first). What bakes into the bytes is NOT the
    // resolved targets (see the bake test above) but the module's OWN name:
    // a package compiles under its `/pkg/<hash>/` filename so that (a) its
    // bare imports normalize in PACKAGE context at compile AND at every
    // runtime load (JS_ReadModule re-resolves with base = the baked name —
    // oidc's `@rewind/jwt` → jwt@1.4), and (b) the loaded module registers
    // under the exact key importers resolve to (one instance per version).
    var bytecodes: std.StringHashMapUnmanaged(*BlobBytes) = .empty;
    defer bytecodes.deinit(a);
    var lctx = module_loader.Ctx{ .allocator = a, .bytecodes = &bytecodes, .resolver = &resolver };
    c.JS_SetModuleLoaderFunc(rt.raw, module_loader.normalize, module_loader.load, &lctx);

    const j19_bc = try ctx.compileToBytecode(
        "globalThis.__log=(globalThis.__log||'')+'j19;'; export const v='jwt19';",
        "/pkg/" ++ JWT19 ++ "/index.mjs", a, .{ .kind = .module });
    defer a.free(j19_bc);
    var j19_bb = BlobBytes{ .bytes = j19_bc, .hash_hex = @splat('9'), .refcount = std.atomic.Value(u32).init(1) };
    try bytecodes.put(a, "/pkg/" ++ JWT19 ++ "/index.mjs", &j19_bb);

    const j14_bc = try ctx.compileToBytecode(
        "globalThis.__log=(globalThis.__log||'')+'j14;'; export const v='jwt14';",
        "/pkg/" ++ JWT14 ++ "/index.mjs", a, .{ .kind = .module });
    defer a.free(j14_bc);
    var j14_bb = BlobBytes{ .bytes = j14_bc, .hash_hex = @splat('4'), .refcount = std.atomic.Value(u32).init(1) };
    try bytecodes.put(a, "/pkg/" ++ JWT14 ++ "/index.mjs", &j14_bb);

    const oidc_bc = ctx.compileToBytecode(
        "import {v} from '@rewind/jwt'; globalThis.__oidcJwt=v; export const p='oidc';",
        "/pkg/" ++ OIDC ++ "/index.mjs", a, .{ .kind = .module }) catch |e| {
        if (ctx.takeExceptionMessage(a)) |m| {
            defer a.free(m);
            std.debug.print("\noidc compile failed: {s}\n", .{m});
        } else |_| {}
        return e;
    };
    defer a.free(oidc_bc);
    var oidc_bb = BlobBytes{ .bytes = oidc_bc, .hash_hex = @splat('O'), .refcount = std.atomic.Value(u32).init(1) };
    try bytecodes.put(a, "/pkg/" ++ OIDC ++ "/index.mjs", &oidc_bb);

    const app_src = "import {p} from '@rewind/oidc'; import {v} from '@rewind/jwt'; globalThis.__appJwt=v; globalThis.__appOidc=p;";
    const app_z = try a.allocSentinel(u8, app_src.len, 0);
    defer a.free(app_z);
    @memcpy(app_z, app_src);
    var res = ctx.eval(app_z, "index.mjs", .{ .kind = .module }) catch |e| {
        if (ctx.takeExceptionMessage(a)) |msg| {
            defer a.free(msg);
            std.debug.print("\nmodule eval failed: {s}\n", .{msg});
        } else |_| {}
        return e;
    };
    res.deinit();
    // Drain any deferred module jobs so top-level side effects are visible.
    var pctx: ?*c.JSContext = null;
    while (c.JS_ExecutePendingJob(rt.raw, &pctx) > 0) {}

    const global = c.JS_GetGlobalObject(ctx.raw);
    defer c.JS_FreeValue(ctx.raw, global);
    try expectGlobalStr(ctx.raw, global, "__appOidc", "oidc"); // app resolved oidc
    try expectGlobalStr(ctx.raw, global, "__appJwt", "jwt19"); // app's @rewind/jwt → 1.9
    try expectGlobalStr(ctx.raw, global, "__oidcJwt", "jwt14"); // oidc's @rewind/jwt → 1.4 (encapsulated)
}

