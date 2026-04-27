//! `Dispatcher` — runs one JS handler against a request.
//!
//! Each `Dispatcher` owns a `qjs.Arena` + `qjs.Snapshot` pair, built
//! once at construction time. The snapshot captures a fully-initialized
//! QuickJS runtime + context with all static rove-js globals installed
//! (kv, console, crypto, Date.now override, Math.random override). Per
//! request, `run` memcpy-restores the snapshot into the arena
//! (~microseconds), installs the per-request `request`/`response`
//! globals, and evaluates the handler bytecode. Nothing allocated by
//! the handler needs to be freed — the next restore overwrites the
//! whole arena. This is the whole point of the rove-qjs design and is
//! worth ~50%+ of handler CPU over the old per-request
//! `JS_NewRuntime` + `JS_NewContext` + `installStatic` path.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");

const globals = @import("globals.zig");
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
    /// Per-dispatcher arena that holds the live QuickJS runtime+context
    /// (plus any allocations they make during handler execution). The
    /// snapshot memcpys its frozen image into this arena at the start
    /// of every `run`, so anything the previous handler dirtied is
    /// wiped in one shot.
    arena: *qjs.Arena,
    /// Frozen post-`installStatic` image of the runtime+context. Built
    /// once in `init`, read-only thereafter.
    snapshot: qjs.Snapshot,
    /// Last `kv.*` error surfaced from a JS call during the most recent
    /// `run`. Useful for tests and for the worker to log root causes.
    last_kv_error: ?anyerror = null,

    fn snapshotInitFn(
        arena: *qjs.Arena,
        out_rt_offset: *usize,
        out_ctx_offset: *usize,
        _: ?*anyopaque,
    ) qjs.snap.Error!void {
        const rt = c.JS_NewRuntime2(&qjs.bump_mf, arena.qjsOpaque()) orelse
            return qjs.snap.Error.RuntimeCreateFailed;
        // Use JS_NewContextRaw + selective intrinsics so the snapshot
        // only contains what handlers actually use. Every intrinsic we
        // add grows the snapshot image and costs per-request memcpy
        // bandwidth at restore. Skipping WeakRef / DOMException /
        // Proxy saves 20-30 KB with essentially no loss — handlers
        // that genuinely need them can be added back.
        const ctx = c.JS_NewContextRaw(rt) orelse
            return qjs.snap.Error.ContextCreateFailed;
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
        out_rt_offset.* = qjs.offsetOf(arena, rt);
        out_ctx_offset.* = qjs.offsetOf(arena, ctx);
    }

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        const arena = try qjs.Arena.create(allocator);
        errdefer arena.destroy();
        const snapshot = try qjs.Snapshot.create(allocator, arena, snapshotInitFn, null);
        return .{
            .allocator = allocator,
            .arena = arena,
            .snapshot = snapshot,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.snapshot.deinit();
        self.arena.destroy();
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
            .prng = std.Random.DefaultPrng.init(request.prng_seed),
            .request_id = request.request_id,
            .platform = request.platform,
            .root_writeset = request.root_writeset,
        };

        // Memcpy-restore the frozen post-init image of
        // runtime+context+static globals into our arena. Handler
        // allocations from the previous request get overwritten in one
        // shot; no per-request teardown needed.
        const restored = self.snapshot.restore(self.arena) catch
            return DispatchError.RuntimeCreateFailed;
        var rt: qjs.Runtime = restored.runtime;
        var ctx: qjs.Context = restored.context;

        rt.setInterruptHandler(interruptHandler, budget);

        // Install the module loader for this request. Reads bytecode
        // for any `import` the handler performs from the deployment's
        // per-path map. Reinstalled per request so each request sees
        // its own tenant's bytecodes.
        var loader_ctx = module_loader.Ctx{
            .allocator = self.allocator,
            .bytecodes = bytecodes,
        };
        c.JS_SetModuleLoaderFunc(
            rt.raw,
            module_loader.normalize,
            module_loader.load,
            &loader_ctx,
        );

        globals.installRequest(ctx.raw, &state, request);

        var exception_msg: []u8 = &.{};
        errdefer self.allocator.free(exception_msg);
        var body_buf: []u8 = &.{};
        errdefer self.allocator.free(body_buf);
        var body_is_json: bool = false;
        var status: i32 = 200;
        var cookies: std.ArrayList([]u8) = .empty;
        errdefer {
            for (cookies.items) |c2| self.allocator.free(c2);
            cookies.deinit(self.allocator);
        }
        var headers: std.ArrayList(ResponseHeader) = .empty;
        errdefer {
            for (headers.items) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            headers.deinit(self.allocator);
        }

        const fun_obj = c.JS_ReadObject(
            ctx.raw,
            bytecode.ptr,
            bytecode.len,
            c.JS_READ_OBJ_BYTECODE,
        );
        var fun_val: qjs.Value = .{ .raw = fun_obj, .ctx = ctx.raw };

        if (fun_val.isException()) {
            exception_msg = ctx.takeExceptionMessage(self.allocator) catch
                return DispatchError.OutOfMemory;
            fun_val.deinit();
            return finishResponse(self, &state, status, body_buf, body_is_json, exception_msg, &console_buf, &cookies, &headers);
        }

        if (fun_val.raw.tag != c.JS_TAG_MODULE) {
            fun_val.deinit();
            status = 500;
            body_buf = self.allocator.dupe(u8, "handler bytecode is not an ES module (.mjs)") catch
                return DispatchError.OutOfMemory;
            return finishResponse(self, &state, status, body_buf, body_is_json, exception_msg, &console_buf, &cookies, &headers);
        }

        runModule(
            self,
            &rt,
            &ctx,
            &state,
            fun_val,
            request,
            budget,
            &status,
            &body_buf,
            &body_is_json,
            &exception_msg,
            &cookies,
            &headers,
        ) catch |err| switch (err) {
            error.Interrupted => return DispatchError.Interrupted,
            error.OutOfMemory => return DispatchError.OutOfMemory,
            error.JsException => {}, // exception_msg already populated
        };

        return finishResponse(self, &state, status, body_buf, body_is_json, exception_msg, &console_buf, &cookies, &headers);
    }
};

const RunError = error{ Interrupted, OutOfMemory, JsException };

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
    state: *globals.DispatchState,
    fun_val_in: qjs.Value,
    request: Request,
    budget: *Budget,
    status_out: *i32,
    body_out: *[]u8,
    body_is_json_out: *bool,
    exception_out: *[]u8,
    cookies_out: *std.ArrayList([]u8),
    headers_out: *std.ArrayList(ResponseHeader),
) RunError!void {
    _ = state;
    const mod_def_ptr: ?*c.JSModuleDef = @ptrCast(@alignCast(fun_val_in.raw.u.ptr));

    var fun_val = fun_val_in;
    const eval_result = c.JS_EvalFunction(ctx.raw, fun_val.raw);
    fun_val = undefined;
    var eval_val: qjs.Value = .{ .raw = eval_result, .ctx = ctx.raw };
    defer eval_val.deinit();

    if (eval_val.isException()) {
        exception_out.* = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        if (budgetExpired(budget)) return error.Interrupted;
        return error.JsException;
    }

    rt.pumpJobs();
    if (budgetExpired(budget)) return error.Interrupted;

    if (c.JS_PromiseState(ctx.raw, eval_val.raw) == c.JS_PROMISE_REJECTED) {
        const reason = c.JS_PromiseResult(ctx.raw, eval_val.raw);
        defer c.JS_FreeValue(ctx.raw, reason);
        exception_out.* = jsValueToOwned(d.allocator, ctx.raw, reason) catch
            return error.OutOfMemory;
        return error.JsException;
    }

    const ns = c.JS_GetModuleNamespace(ctx.raw, mod_def_ptr);
    defer c.JS_FreeValue(ctx.raw, ns);
    if (c.JS_IsException(ns)) {
        exception_out.* = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        return error.JsException;
    }

    // ── Resolve fn name + args JSON from the request. ─────────────
    var dispatch = parseDispatch(d.allocator, request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadRequest => {
            status_out.* = 400;
            body_out.* = std.fmt.allocPrint(d.allocator,
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
        status_out.* = 404;
        body_out.* = std.fmt.allocPrint(
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
        status_out.* = 400;
        body_out.* = std.fmt.allocPrint(d.allocator, "args JSON parse failed\n", .{}) catch
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

    if (ret_val.isException()) {
        exception_out.* = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        if (budgetExpired(budget)) return error.Interrupted;
        return error.JsException;
    }

    rt.pumpJobs();
    if (budgetExpired(budget)) return error.Interrupted;

    const final = unwrapPromise(ctx.raw, ret_val.raw);
    if (final.rejected) {
        exception_out.* = jsValueToOwned(d.allocator, ctx.raw, final.val) catch
            return error.OutOfMemory;
        c.JS_FreeValue(ctx.raw, final.val);
        return error.JsException;
    }
    var final_val: qjs.Value = .{ .raw = final.val, .ctx = ctx.raw };
    defer if (final.owns) final_val.deinit();

    // Body from return value. Status / cookies from the ambient
    // `response` global.
    bodyFromReturn(d.allocator, ctx.raw, final_val.raw, body_out, body_is_json_out) catch
        return error.OutOfMemory;
    extractResponseMetadata(d.allocator, ctx.raw, status_out, cookies_out, headers_out) catch
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
    status: i32,
    body_buf: []u8,
    body_is_json: bool,
    exception_msg: []u8,
    console_buf: *std.ArrayList(u8),
    cookies: *std.ArrayList([]u8),
    headers: *std.ArrayList(ResponseHeader),
) DispatchError!Response {
    if (state.pending_kv_error) |err| {
        d.last_kv_error = err;
        d.allocator.free(body_buf);
        d.allocator.free(exception_msg);
        console_buf.deinit(d.allocator);
        // Cookies + headers get cleaned up by the caller's errdefer
        // when we return an error from here — don't double-free.
        return DispatchError.KvFailed;
    }

    const console_bytes = console_buf.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    const set_cookies = cookies.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    const headers_slice = headers.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    // If the handler explicitly set content-type in response.headers,
    // suppress our auto-stamped JSON one so the handler's choice wins.
    var effective_body_is_json = body_is_json;
    if (effective_body_is_json) {
        for (headers_slice) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                effective_body_is_json = false;
                break;
            }
        }
    }

    return .{
        .status = status,
        .body = body_buf,
        .body_is_json = effective_body_is_json,
        .console = console_bytes,
        .exception = exception_msg,
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

    // If the caller didn't set a query, force `fn=go` so the
    // dispatcher finds our wrapper export.
    var request = request_in;
    if (request.query == null) request.query = "fn=go";

    var budget = Budget.fromNow(Budget.default_duration_ns);
    const resp = try d.run(kv, &txn, &ws, bytecode, null, request, &budget);
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
        var resp2 = try d.run(kv, &txn2, &ws2, bytecode, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=nope",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 404), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "nope") != null);
    }
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
        var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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
    var resp = try d.run(kv, &txn, &ws, bytecode, null, .{
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


test "dispatch: webhook.send writes _outbox/{id} with the envelope" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    var d = try Dispatcher.init(testing.allocator);
    defer d.deinit();

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
        .{ .method = "GET", .path = "/hook", .request_id = 0xdeadbeef },
    );
    defer resp.deinit(testing.allocator);

    // 64-hex id | 64-hex id → 129 chars total.
    try testing.expectEqual(@as(usize, 64 * 2 + 1), resp.body.len);

    // Commit has already fired inside runOne. Scan `_outbox/*`; expect
    // two rows in insertion order, each with the envelope we fed in.
    const scan = try kv.prefix("_outbox/", "", 10);
    defer {
        var m = scan;
        m.deinit();
    }
    try testing.expectEqual(@as(usize, 2), scan.entries.len);

    // Each value must be JSON with the url/body/context we passed.
    const parsed_a = try std.json.parseFromSlice(std.json.Value, testing.allocator, scan.entries[0].value, .{});
    defer parsed_a.deinit();
    const url_a = parsed_a.value.object.get("url").?.string;
    try testing.expect(std.mem.endsWith(u8, url_a, "/a") or std.mem.endsWith(u8, url_a, "/b"));

    const attempts = parsed_a.value.object.get("attempts").?.integer;
    try testing.expectEqual(@as(i64, 0), attempts);

    const parent = parsed_a.value.object.get("parent_request_id").?.integer;
    try testing.expectEqual(@as(i64, 0xdeadbeef), parent);
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
        .{ .method = "POST", .path = "/", .request_id = 7 },
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 64), resp.body.len); // id hex

    const scan = try kv.prefix("_outbox/", "", 10);
    defer {
        var m = scan;
        m.deinit();
    }
    try testing.expectEqual(@as(usize, 1), scan.entries.len);

    var env = try std.json.parseFromSlice(std.json.Value, testing.allocator, scan.entries[0].value, .{});
    defer env.deinit();
    const obj = env.value.object;

    try testing.expectEqualStrings("https://api.resend.com/emails", obj.get("url").?.string);
    try testing.expectEqualStrings("POST", obj.get("method").?.string);
    try testing.expectEqualStrings(
        "Bearer re_test_abc",
        obj.get("headers").?.object.get("Authorization").?.string,
    );
    try testing.expectEqualStrings(
        "application/json",
        obj.get("headers").?.object.get("Content-Type").?.string,
    );
    try testing.expectEqualStrings("signup/email_result", obj.get("on_result").?.string);

    // Body is a JSON string; parse to check shape.
    var body_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, obj.get("body").?.string, .{});
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

test "dispatch: email.send accepts array `to`, `cc`, `bcc`" {
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
        .{ .method = "POST", .path = "/", .request_id = 2 },
    );
    defer resp.deinit(testing.allocator);

    const scan = try kv.prefix("_outbox/", "", 10);
    defer {
        var m = scan;
        m.deinit();
    }
    var env = try std.json.parseFromSlice(std.json.Value, testing.allocator, scan.entries[0].value, .{});
    defer env.deinit();
    var body = try std.json.parseFromSlice(std.json.Value, testing.allocator, env.value.object.get("body").?.string, .{});
    defer body.deinit();

    try testing.expectEqual(@as(usize, 2), body.value.object.get("to").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.value.object.get("cc").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), body.value.object.get("bcc").?.array.items.len);
}
