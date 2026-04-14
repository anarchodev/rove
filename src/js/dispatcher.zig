//! `Dispatcher` — runs one JS handler against a request.
//!
//! Construction takes a `KvStore`. `run(source, request)` spins up a
//! fresh quickjs `Runtime`+`Context`, installs globals, evaluates the
//! source, extracts the response, and tears the runtime down. No
//! caching — that's the snapshot/restore optimization that lands in a
//! later session.

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");

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
};

pub const Response = struct {
    status: i32 = 200,
    body: []u8,
    /// Captured `console.log` output (one line per call, newline-terminated).
    console: []u8,
    /// Exception message if the script threw. Empty on success.
    exception: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.console);
        allocator.free(self.exception);
        self.* = undefined;
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    /// Last `kv.*` error surfaced from a JS call during the most recent
    /// `run`. Useful for tests and for the worker to log root causes.
    last_kv_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    /// Run pre-compiled `bytecode` as a handler against `request`.
    /// Reads hit `kv` directly — the same SQLite connection the
    /// caller's `TrackedTxn` opened, so reads see the txn's own
    /// uncommitted writes. `kv.set`/`kv.delete` from the handler go
    /// through `txn` (local durability + undo) AND `writeset` (raft
    /// replication). Each call uses a fresh `Runtime`+`Context`.
    /// Returns an owned `Response`; caller frees with `Response.deinit`.
    ///
    /// The bytecode is produced at deploy time by `rove-code-cli`'s
    /// compile hook (which calls `Context.compileToBytecode`). The
    /// filename baked into the bytecode is what shows up in stack
    /// traces — no filename parameter here because it's part of the
    /// bytecode blob itself.
    pub fn run(
        self: *Dispatcher,
        kv: *kv_mod.KvStore,
        txn: *kv_mod.TrackedTxn,
        writeset: *kv_mod.WriteSet,
        bytecode: []const u8,
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
        };

        var rt = qjs.Runtime.init() catch return DispatchError.RuntimeCreateFailed;
        defer rt.deinit();
        var ctx = rt.newContext() catch return DispatchError.ContextCreateFailed;
        defer ctx.deinit();

        rt.setInterruptHandler(interruptHandler, budget);
        defer rt.clearInterruptHandler();

        globals.install(ctx.raw, &state, request);

        var exception_msg: []u8 = &.{};
        errdefer self.allocator.free(exception_msg);
        var body_buf: []u8 = &.{};
        errdefer self.allocator.free(body_buf);
        var status: i32 = 200;

        // Deserialize the bytecode. The returned value is either a
        // JS_TAG_FUNCTION_BYTECODE (script) or a JS_TAG_MODULE (module),
        // depending on which compile flag produced it.
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
            // Script fallthrough: no eval happened, no body to extract.
            return finishResponse(self, &state, status, body_buf, exception_msg, &console_buf);
        }

        const is_module = fun_val.raw.tag == c.JS_TAG_MODULE;

        if (is_module) {
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
                &exception_msg,
            ) catch |err| switch (err) {
                error.Interrupted => return DispatchError.Interrupted,
                error.OutOfMemory => return DispatchError.OutOfMemory,
                error.JsException => {}, // exception_msg already populated
            };
        } else {
            runScript(
                self,
                &ctx,
                fun_val,
                budget,
                &status,
                &body_buf,
                &exception_msg,
            ) catch |err| switch (err) {
                error.Interrupted => return DispatchError.Interrupted,
                error.OutOfMemory => return DispatchError.OutOfMemory,
                error.JsException => {}, // exception_msg already populated
            };
        }

        return finishResponse(self, &state, status, body_buf, exception_msg, &console_buf);
    }
};

const RunError = error{ Interrupted, OutOfMemory, JsException };

/// Script path: eval the top-level function, then pull `status` and
/// `body` off the `response` global the way M1 has always done.
fn runScript(
    d: *Dispatcher,
    ctx: *qjs.Context,
    fun_val_in: qjs.Value,
    budget: *Budget,
    status_out: *i32,
    body_out: *[]u8,
    exception_out: *[]u8,
) RunError!void {
    // JS_EvalFunction consumes fun_val's reference.
    var fun_val = fun_val_in;
    const eval_result = c.JS_EvalFunction(ctx.raw, fun_val.raw);
    fun_val = undefined;
    var eval_val: qjs.Value = .{ .raw = eval_result, .ctx = ctx.raw };
    defer eval_val.deinit();

    if (eval_val.isException()) {
        exception_out.* = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        if (now >= budget.deadline_ns) return error.Interrupted;
        // Fall through: scripts may have written partial state onto the
        // `response` global before throwing — extract anyway.
    }

    extractResponseFromGlobal(d.allocator, ctx.raw, status_out, body_out) catch
        return error.OutOfMemory;
}

/// Module path: eval the module (returns a promise for top-level
/// eval), pump jobs, inspect the promise state, extract the namespace,
/// look up the `?fn=<name>` export, call it with the request object,
/// pump jobs again (async handlers), and extract the response from
/// the return value.
///
/// Response convention: the exported function returns either an
/// object with `{ status, body }` or a plain string (treated as body
/// with status 200). No `response` global is touched — modules are
/// clean, no ambient mutable state.
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
    exception_out: *[]u8,
) RunError!void {
    _ = state;
    // Extract JSModuleDef pointer BEFORE JS_EvalFunction consumes
    // the value. `.u.ptr` works on the struct representation rove-qjs
    // uses; shift-js does the same via JS_VALUE_GET_PTR.
    const mod_def_ptr: ?*c.JSModuleDef = @ptrCast(@alignCast(fun_val_in.raw.u.ptr));

    // JS_EvalFunction consumes the module value's reference.
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

    // Drain the microtask queue so the module's top-level evaluation
    // (and any imports, once we support them) settles.
    rt.pumpJobs();
    if (budgetExpired(budget)) return error.Interrupted;

    // The eval result is a promise for the module's evaluation. If it
    // rejected, surface the rejection reason.
    if (c.JS_PromiseState(ctx.raw, eval_val.raw) == c.JS_PROMISE_REJECTED) {
        const reason = c.JS_PromiseResult(ctx.raw, eval_val.raw);
        defer c.JS_FreeValue(ctx.raw, reason);
        exception_out.* = jsValueToOwned(d.allocator, ctx.raw, reason) catch
            return error.OutOfMemory;
        return error.JsException;
    }

    // Grab the namespace — the object holding all the module's exports.
    const ns = c.JS_GetModuleNamespace(ctx.raw, mod_def_ptr);
    defer c.JS_FreeValue(ctx.raw, ns);
    if (c.JS_IsException(ns)) {
        exception_out.* = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        return error.JsException;
    }

    // Resolve the function name from `?fn=<name>` in the request query.
    // Absent or empty → try `default` export.
    const fn_name = fnNameFromQuery(request.query) orelse "default";
    const fn_name_z = std.fmt.allocPrintSentinel(d.allocator, "{s}", .{fn_name}, 0) catch
        return error.OutOfMemory;
    defer d.allocator.free(fn_name_z);

    const handler = c.JS_GetPropertyStr(ctx.raw, ns, fn_name_z.ptr);
    defer c.JS_FreeValue(ctx.raw, handler);
    if (c.JS_IsException(handler) or !c.JS_IsFunction(ctx.raw, handler)) {
        status_out.* = 404;
        body_out.* = std.fmt.allocPrint(
            d.allocator,
            "module export \"{s}\" not found or not a function\n",
            .{fn_name},
        ) catch return error.OutOfMemory;
        return;
    }

    // Build the `request` arg object. We already installed `request`
    // as a global via `globals.install`, so reuse that by reading it
    // back — single source of truth for request shape.
    const global = c.JS_GetGlobalObject(ctx.raw);
    defer c.JS_FreeValue(ctx.raw, global);
    const request_obj = c.JS_GetPropertyStr(ctx.raw, global, "request");
    defer c.JS_FreeValue(ctx.raw, request_obj);

    var args = [_]c.JSValue{request_obj};
    const ret = c.JS_Call(ctx.raw, handler, globals.js_undefined, 1, &args);
    var ret_val: qjs.Value = .{ .raw = ret, .ctx = ctx.raw };
    defer ret_val.deinit();

    if (ret_val.isException()) {
        exception_out.* = ctx.takeExceptionMessage(d.allocator) catch
            return error.OutOfMemory;
        if (budgetExpired(budget)) return error.Interrupted;
        return error.JsException;
    }

    // Async handler support: if the return value is a promise, pump
    // and unwrap once.
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

    extractResponseFromReturn(d.allocator, ctx.raw, final_val.raw, status_out, body_out) catch
        return error.OutOfMemory;
}

fn budgetExpired(budget: *Budget) bool {
    const now: i64 = @intCast(std.time.nanoTimestamp());
    return now >= budget.deadline_ns;
}

fn fnNameFromQuery(query: ?[]const u8) ?[]const u8 {
    const q = query orelse return null;
    // Look for `fn=...` as a top-level query param. Cheap hand-parse
    // that avoids bringing in a full URL parser for the MVP.
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "fn=")) {
            const v = pair[3..];
            if (v.len == 0) return null;
            return v;
        }
    }
    return null;
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

fn extractResponseFromGlobal(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    status_out: *i32,
    body_out: *[]u8,
) error{OutOfMemory}!void {
    const global_obj = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global_obj);
    const resp_val = c.JS_GetPropertyStr(ctx, global_obj, "response");
    defer c.JS_FreeValue(ctx, resp_val);
    if (c.JS_IsUndefined(resp_val) or c.JS_IsNull(resp_val)) return;

    const status_val = c.JS_GetPropertyStr(ctx, resp_val, "status");
    defer c.JS_FreeValue(ctx, status_val);
    _ = c.JS_ToInt32(ctx, status_out, status_val);

    const body_val = c.JS_GetPropertyStr(ctx, resp_val, "body");
    defer c.JS_FreeValue(ctx, body_val);
    body_out.* = jsValueToOwned(allocator, ctx, body_val) catch return error.OutOfMemory;
}

fn extractResponseFromReturn(
    allocator: std.mem.Allocator,
    ctx: *c.JSContext,
    ret: c.JSValue,
    status_out: *i32,
    body_out: *[]u8,
) error{OutOfMemory}!void {
    // Convention: string return → body (status 200). Object return →
    // `{status, body}` plucked off. Anything else → stringify and use
    // that as the body.
    if (c.JS_IsString(ret)) {
        body_out.* = jsValueToOwned(allocator, ctx, ret) catch return error.OutOfMemory;
        return;
    }
    if (c.JS_IsObject(ret) and !c.JS_IsNull(ret) and !c.JS_IsUndefined(ret)) {
        const status_val = c.JS_GetPropertyStr(ctx, ret, "status");
        defer c.JS_FreeValue(ctx, status_val);
        if (!c.JS_IsUndefined(status_val)) {
            _ = c.JS_ToInt32(ctx, status_out, status_val);
        }
        const body_val = c.JS_GetPropertyStr(ctx, ret, "body");
        defer c.JS_FreeValue(ctx, body_val);
        if (!c.JS_IsUndefined(body_val) and !c.JS_IsNull(body_val)) {
            body_out.* = jsValueToOwned(allocator, ctx, body_val) catch
                return error.OutOfMemory;
        }
        return;
    }
    // Null/undefined return: leave body empty.
}

fn finishResponse(
    d: *Dispatcher,
    state: *globals.DispatchState,
    status: i32,
    body_buf: []u8,
    exception_msg: []u8,
    console_buf: *std.ArrayList(u8),
) DispatchError!Response {
    if (state.pending_kv_error) |err| {
        d.last_kv_error = err;
        d.allocator.free(body_buf);
        d.allocator.free(exception_msg);
        console_buf.deinit(d.allocator);
        return DispatchError.KvFailed;
    }

    const console_bytes = console_buf.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    return .{
        .status = status,
        .body = body_buf,
        .console = console_bytes,
        .exception = exception_msg,
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\response.status = 201;
        \\response.body = "hi " + request.path;
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\const v = kv.get("nope");
        \\response.body = String(v);
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("null", resp.body);
}

/// Test harness that mirrors the worker's per-request flow: compile
/// the source to bytecode once, open a tracked txn, run the dispatcher
/// on the bytecode, commit (or rollback on handler error). Returns
/// the Response; caller owns and deinits.
fn runOne(
    d: *Dispatcher,
    kv: *kv_mod.KvStore,
    source: []const u8,
    request: Request,
) !Response {
    // Compile on a throwaway runtime. In production the bytecode comes
    // from rove-code's compile-on-upload; tests compile inline.
    var rt = try qjs.Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();
    const bytecode = try ctx.compileToBytecode(source, "h.js", testing.allocator, .{});
    defer testing.allocator.free(bytecode);

    var txn = try kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    const resp = try d.run(kv, &txn, &ws, bytecode, request, &budget);
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

    var d = Dispatcher.init(testing.allocator);

    var r1 = try runOne(
        &d,
        kv,
        \\kv.set("name", "rove");
        \\response.body = "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // First request committed the txn, so the write is durable.
    // Second request observes it.
    var r2 = try runOne(
        &d,
        kv,
        \\response.body = kv.get("name");
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

    var d = Dispatcher.init(testing.allocator);

    try kv.put("k", "v");

    var r1 = try runOne(
        &d,
        kv,
        \\kv.delete("k");
        \\response.body = "ok";
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\kv.set("x", "fresh");
        \\response.body = kv.get("x");
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\console.log("hello", "world");
        \\console.log("line2");
        \\response.body = "x";
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("hello world\nline2\n", resp.console);
}

test "dispatch: malformed bytecode surfaces in exception field" {
    // Compile errors happen at upload time in production (rove-code-cli
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

    var d = Dispatcher.init(testing.allocator);
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\response.body = "before throw";
        \\throw new Error("boom");
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("before throw", resp.body);
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

    var d = Dispatcher.init(testing.allocator);

    var r1 = try runOne(
        &d,
        kv_a,
        \\kv.set("name", "alice");
        \\response.body = "ok";
    ,
        .{ .method = "POST", .path = "/" },
    );
    defer r1.deinit(testing.allocator);

    // kv_b never received the write.
    var r2 = try runOne(
        &d,
        kv_b,
        \\response.body = String(kv.get("name"));
    ,
        .{ .method = "GET", .path = "/" },
    );
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("null", r2.body);

    var r3 = try runOne(
        &d,
        kv_a,
        \\response.body = kv.get("name");
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
        \\const v = kv.get("seeded");
        \\const missing = kv.get("missing");
        \\kv.set("new", v + "!");
        \\kv.delete("seeded");
        \\response.body = String(missing);
    ,
        "h.js",
        testing.allocator,
        .{},
    );
    defer testing.allocator.free(bytecode);

    var d = Dispatcher.init(testing.allocator);
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();

    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, .{
        .method = "POST",
        .path = "/",
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
        \\const t = Date.now();
        \\const r1 = Math.random();
        \\const r2 = Math.random();
        \\const buf = new Uint8Array(4);
        \\crypto.getRandomValues(buf);
        \\const id = crypto.randomUUID();
        \\response.body = String(t) + "|" + r1 + "|" + r2 + "|" + id;
    ,
        "h.js",
        testing.allocator,
        .{},
    );
    defer testing.allocator.free(bytecode);

    var d = Dispatcher.init(testing.allocator);
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();

        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, .{
            .method = "GET",
            .path = "/",
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
        var resp2 = try d.run(kv, &txn2, &ws2, bytecode, .{
            .method = "GET",
            .path = "/",
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
        "while (true) {}",
        "h.js",
        testing.allocator,
        .{},
    );
    defer testing.allocator.free(bytecode);

    var d = Dispatcher.init(testing.allocator);
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
        .{ .method = "GET", .path = "/" },
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\response.body = "fast";
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
        \\export function greet(req) {
        \\    return { status: 200, body: "hi " + req.path };
        \\}
        \\export function shout(req) {
        \\    return { status: 201, body: ("HI " + req.path).toUpperCase() };
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = Dispatcher.init(testing.allocator);

    // ?fn=greet → "hi /hello"
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=greet",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 200), resp.status);
        try testing.expectEqualStrings("hi /hello", resp.body);
    }

    // ?fn=shout → "HI /HELLO", status 201
    {
        var txn = try kv.beginTrackedImmediate();
        defer txn.rollback() catch {};
        var ws = kv_mod.WriteSet.init(testing.allocator);
        defer ws.deinit();
        var budget = Budget.fromNow(Budget.default_duration_ns);
        var resp = try d.run(kv, &txn, &ws, bytecode, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=shout",
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
        var resp = try d.run(kv, &txn, &ws, bytecode, .{
            .method = "GET",
            .path = "/hello",
            .query = "fn=nope",
        }, &budget);
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 404), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "nope") != null);
    }
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
        \\export async function fetchLike(req) {
        \\    const v = await Promise.resolve("async " + req.path);
        \\    return { status: 202, body: v };
        \\}
    ,
        "h.mjs",
        testing.allocator,
        .{ .kind = .module },
    );
    defer testing.allocator.free(bytecode);

    var d = Dispatcher.init(testing.allocator);
    var txn = try kv.beginTrackedImmediate();
    defer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(testing.allocator);
    defer ws.deinit();
    var budget = Budget.fromNow(Budget.default_duration_ns);
    var resp = try d.run(kv, &txn, &ws, bytecode, .{
        .method = "GET",
        .path = "/x",
        .query = "fn=fetchLike",
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

    var d = Dispatcher.init(testing.allocator);
    var resp = try runOne(
        &d,
        kv,
        \\response.body = request.method + " " + request.path + " " + request.body;
    ,
        .{ .method = "PUT", .path = "/x", .body = "payload" },
    );
    defer resp.deinit(testing.allocator);

    try testing.expectEqualStrings("PUT /x payload", resp.body);
}
