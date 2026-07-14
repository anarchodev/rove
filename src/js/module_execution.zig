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

    // The export is called with no positional arguments. Resume
    // payloads (ctx / outcome) ride `request.body` and the typed
    // `request.activation` union, read through the request surface so
    // every read is taped (decisions.md §4.5).
    const ret = c.JS_Call(
        ctx.raw,
        handler,
        globals.js_undefined,
        0,
        null,
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

        const resolved = resolveSpecifier(base_s, name_s, static_buf[0..]);
        return dupToJs(ctx, resolved);
    }

    /// Copy `s` into a qjs-allocated NUL-terminated buffer quickjs owns.
    fn dupToJs(ctx: ?*c.JSContext, s: []const u8) [*c]u8 {
        const out = c.js_malloc(ctx, s.len + 1) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(out))[0..s.len], s);
        @as([*]u8, @ptrCast(out))[s.len] = 0;
        return @ptrCast(out);
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
        const map = self.bytecodes orelse {
            _ = c.JS_ThrowReferenceError(ctx, "could not load module '%s'", name);
            return null;
        };
        const bb = map.get(name_s) orelse {
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

/// Per-importer `@scope/pkg` resolution. Package modules live in
/// the deployment bytecode map under `/pkg/<pkg_hash>/…`; this maps a
/// bare specifier to the resolved package's entry key. Resolution is
/// keyed on the *importer* (`base`) — which is the whole flat-surface /
/// encapsulated-internals guarantee (`docs/architecture/package-resolution.md`
/// §2, §4): the same specifier resolves to the app's pinned version from
/// an app handler, and to the package's own frozen dep from inside a
/// package. Owned by the tenant snapshot; slices returned by `resolve`
/// live as long as the maps (the whole request).
pub const PackageResolver = struct {
    /// bare specifier → package-virtual entry key, for app-context importers.
    app_imports: std.StringHashMapUnmanaged([]const u8),
    /// package-virtual dir ("/pkg/<hash>/") → that package's own
    /// {specifier → entry key} map (its encapsulated, frozen-at-publish deps).
    pkg_imports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),

    /// Resolve `specifier` for the module at `base`, or null to pass
    /// through (relative imports, `__system/*`, undeclared specifiers).
    pub fn resolve(self: *const PackageResolver, base: []const u8, specifier: []const u8) ?[]const u8 {
        if (packageDirOf(base)) |pkg_dir| {
            // Importer is a package → its own encapsulated imports.
            const inner = self.pkg_imports.getPtr(pkg_dir) orelse return null;
            return inner.get(specifier);
        }
        // Importer is an app handler → the flat app surface.
        return self.app_imports.get(specifier);
    }

    /// Free every owned key/value (buildResolver allocates them all).
    pub fn deinit(self: *PackageResolver, allocator: std.mem.Allocator) void {
        var ai = self.app_imports.iterator();
        while (ai.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        self.app_imports.deinit(allocator);
        var pi = self.pkg_imports.iterator();
        while (pi.next()) |e| {
            allocator.free(e.key_ptr.*);
            var inner = e.value_ptr;
            var ii = inner.iterator();
            while (ii.next()) |ie| {
                allocator.free(ie.key_ptr.*);
                allocator.free(ie.value_ptr.*);
            }
            inner.deinit(allocator);
        }
        self.pkg_imports.deinit(allocator);
    }
};

/// The entry-module key for a package: `/pkg/<pkg_hash>/index.mjs`.
fn pkgEntryKey(allocator: std.mem.Allocator, pkg_hash_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/pkg/{s}/index.mjs", .{pkg_hash_hex});
}

/// The virtual-dir key for a package: `/pkg/<pkg_hash>/` (the `pkg_imports` key).
fn pkgDirKey(allocator: std.mem.Allocator, pkg_hash_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/pkg/{s}/", .{pkg_hash_hex});
}

/// Build a `PackageResolver` from a manifest's (or a deploy-time
/// `Resolution`'s) package sections. `app_imports` becomes the
/// flat app surface; each package's `imports` becomes its encapsulated
/// per-importer map (keyed by its `/pkg/<hash>/` dir). Values are entry
/// keys (`/pkg/<dep_hash>/index.mjs`). Caller owns the result —
/// `resolver.deinit(allocator)` frees it. On error, everything allocated
/// so far is freed.
pub fn buildResolver(
    allocator: std.mem.Allocator,
    packages: []const files_mod.manifest_json.Package,
    app_imports: []const files_mod.manifest_json.ImportEntry,
) !PackageResolver {
    var r = PackageResolver{ .app_imports = .empty, .pkg_imports = .empty };
    errdefer r.deinit(allocator);

    for (app_imports) |ie| {
        const spec = try allocator.dupe(u8, ie.specifier);
        errdefer allocator.free(spec);
        const key = try pkgEntryKey(allocator, &ie.pkg_hash_hex);
        errdefer allocator.free(key);
        try r.app_imports.put(allocator, spec, key);
    }

    for (packages) |p| {
        var inner: std.StringHashMapUnmanaged([]const u8) = .empty;
        // On failure mid-package, free `inner`'s own entries before the
        // outer errdefer (which only knows the packages already in the map).
        errdefer {
            var it = inner.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            inner.deinit(allocator);
        }
        for (p.imports) |ie| {
            const spec = try allocator.dupe(u8, ie.specifier);
            errdefer allocator.free(spec);
            const val = try pkgEntryKey(allocator, &ie.pkg_hash_hex);
            errdefer allocator.free(val);
            try inner.put(allocator, spec, val);
        }
        const dir = try pkgDirKey(allocator, &p.pkg_hash_hex);
        errdefer allocator.free(dir);
        try r.pkg_imports.put(allocator, dir, inner);
    }
    return r;
}

/// `/pkg/<hash>/lib/x.mjs` → `/pkg/<hash>/` (the package's virtual dir,
/// the `pkg_imports` key). Null when `base` isn't a package-virtual path.
fn packageDirOf(base: []const u8) ?[]const u8 {
    const prefix = "/pkg/";
    if (!std.mem.startsWith(u8, base, prefix)) return null;
    const rest = base[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return base[0 .. prefix.len + slash + 1]; // include the trailing '/'
}

// ── resolution tests ────────────────────────────────────────

const testing = std.testing;

test "resolveSpecifier: bare passthrough + relative resolution (regression)" {
    var buf: [512]u8 = undefined;
    // Bare / builtin specifiers pass through unchanged.
    try testing.expectEqualStrings("@rewind/oidc", resolveSpecifier("index.mjs", "@rewind/oidc", &buf));
    try testing.expectEqualStrings("__system/x", resolveSpecifier("index.mjs", "__system/x", &buf));
    // Relative resolution against the importer's dir.
    try testing.expectEqualStrings("lib/util.mjs", resolveSpecifier("index.mjs", "./lib/util.mjs", &buf));
    try testing.expectEqualStrings("util.mjs", resolveSpecifier("lib/index.mjs", "../util.mjs", &buf));
    // A package's internal relative import stays within its /pkg/<hash>/ dir.
    try testing.expectEqualStrings("/pkg/OIDC/lib/token.mjs", resolveSpecifier("/pkg/OIDC/index.mjs", "./lib/token.mjs", &buf));
}

test "packageDirOf: extracts the package-virtual dir" {
    try testing.expectEqualStrings("/pkg/abc/", packageDirOf("/pkg/abc/index.mjs").?);
    try testing.expectEqualStrings("/pkg/abc/", packageDirOf("/pkg/abc/lib/token.mjs").?);
    try testing.expect(packageDirOf("index.mjs") == null);
    try testing.expect(packageDirOf("_triggers/users/index.mjs") == null);
    try testing.expect(packageDirOf("/pkg/abc") == null); // no file segment
}

test "PackageResolver: app vs package importer (flat surface + encapsulation)" {
    const a = testing.allocator;
    var app_imports: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer app_imports.deinit(a);
    try app_imports.put(a, "@rewind/oidc", "/pkg/OIDC/index.mjs");
    try app_imports.put(a, "@rewind/jwt", "/pkg/JWT19/index.mjs"); // app pins jwt 1.9

    var oidc_imports: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer oidc_imports.deinit(a);
    try oidc_imports.put(a, "@rewind/jwt", "/pkg/JWT14/index.mjs"); // oidc's OWN frozen jwt 1.4

    var pkg_imports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
    defer pkg_imports.deinit(a);
    try pkg_imports.put(a, "/pkg/OIDC/", oidc_imports);

    const r = PackageResolver{ .app_imports = app_imports, .pkg_imports = pkg_imports };

    // App handler → the flat app surface.
    try testing.expectEqualStrings("/pkg/OIDC/index.mjs", r.resolve("index.mjs", "@rewind/oidc").?);
    try testing.expectEqualStrings("/pkg/JWT19/index.mjs", r.resolve("index.mjs", "@rewind/jwt").?);
    // Inside oidc, @rewind/jwt resolves to oidc's OWN pinned jwt 1.4 — the
    // encapsulation guarantee (app pins 1.9, oidc keeps 1.4).
    try testing.expectEqualStrings("/pkg/JWT14/index.mjs", r.resolve("/pkg/OIDC/index.mjs", "@rewind/jwt").?);
    // A package file deeper than index still resolves via its dir key.
    try testing.expectEqualStrings("/pkg/JWT14/index.mjs", r.resolve("/pkg/OIDC/lib/token.mjs", "@rewind/jwt").?);
    // Undeclared / builtin specifiers pass through (null → normalize falls
    // to resolveSpecifier): __system/*, unknown app dep, unknown pkg dep.
    try testing.expect(r.resolve("index.mjs", "__system/scheduler_tick") == null);
    try testing.expect(r.resolve("index.mjs", "@rewind/unknown") == null);
    try testing.expect(r.resolve("/pkg/OIDC/index.mjs", "@rewind/unknown") == null);
    // An importer under an unknown /pkg/ dir → null (no import map).
    try testing.expect(r.resolve("/pkg/NOPE/index.mjs", "@rewind/jwt") == null);
}

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

