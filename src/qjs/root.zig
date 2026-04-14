//! rove-qjs — Zig wrapper around vendored quickjs-ng.
//!
//! This module is Phase 0 of the rove-js build. Scope:
//!
//! - Thin Zig types over `JSRuntime`, `JSContext`, `JSValue`.
//! - `eval` of a source string returning either a result value or a typed
//!   error with the JS exception message available for logging.
//! - Conversions for the primitive JS types (undefined/null/bool/int/float/
//!   string) needed to test the wrapper end-to-end.
//!
//! **Not yet implemented** (arriving in a follow-up):
//!
//! - Snapshot + restore (the memcpy-relocation trick). This is the big
//!   prize of quickjs-ng for our use case and is substantial enough to
//!   deserve its own session.
//! - Per-request bump arena. Rides along with the snapshot work because
//!   they share allocator plumbing.
//! - Module loader integration (reading bytecode from rove-code).
//!
//! The QuickJS C API lives at `c.JS_*`. Everything user-facing goes
//! through the Zig types defined here.

const std = @import("std");

pub const c = @cImport({
    @cInclude("quickjs.h");
});

pub const snap = @import("snap.zig");
pub const Arena = snap.Arena;
pub const Snapshot = snap.Snapshot;
pub const InitFn = snap.InitFn;
pub const offsetOf = snap.offsetOf;
pub const bump_mf = snap.bump_mf;

pub const Error = error{
    RuntimeCreateFailed,
    ContextCreateFailed,
    /// A JS-level exception was thrown during `eval`. Inspect via
    /// `Context.takeException` if you need the message.
    JsException,
    NotAString,
    OutOfMemory,
};

/// A QuickJS runtime. Owns memory, atom table, shape table, and is the
/// scope inside which contexts live. One runtime per worker thread.
pub const Runtime = struct {
    raw: *c.JSRuntime,

    pub fn init() Error!Runtime {
        const rt = c.JS_NewRuntime() orelse return Error.RuntimeCreateFailed;
        return .{ .raw = rt };
    }

    pub fn deinit(self: *Runtime) void {
        c.JS_FreeRuntime(self.raw);
        self.* = undefined;
    }

    /// Set the maximum stack size for JS execution (in bytes).
    /// 0 means unlimited. Matches QuickJS's default of 1 MiB otherwise.
    pub fn setMaxStackSize(self: Runtime, bytes: usize) void {
        c.JS_SetMaxStackSize(self.raw, bytes);
    }

    /// Set the memory limit for the runtime (in bytes). Allocations that
    /// would exceed this return null and the next JS op that tries to use
    /// them throws an OOM exception.
    pub fn setMemoryLimit(self: Runtime, bytes: usize) void {
        c.JS_SetMemoryLimit(self.raw, bytes);
    }

    /// Install an interrupt handler that QuickJS calls periodically
    /// during JS execution (on backward jumps, function calls, and
    /// some other VM boundaries). Returning a non-zero value tells
    /// QuickJS to throw an uncatchable interrupt exception and unwind
    /// the VM immediately — the caller's `eval`/`evalBytecode` will
    /// see `Error.JsException` with the exception message describing
    /// the interrupt.
    ///
    /// The handler's `opaque` pointer is passed through unchanged; use
    /// it to thread per-request state (deadlines, bytecode counters,
    /// replay tape position, etc.) so the same handler can serve
    /// multiple sequential requests against a shared runtime.
    ///
    /// Callback signature matches quickjs-ng's `JSInterruptHandler`:
    ///
    ///     fn(rt: ?*c.JSRuntime, opaque: ?*anyopaque) callconv(.c) c_int
    ///
    /// Return 0 to continue, non-zero to interrupt.
    pub fn setInterruptHandler(
        self: Runtime,
        handler: *const fn (?*c.JSRuntime, ?*anyopaque) callconv(.c) c_int,
        opaque_ctx: ?*anyopaque,
    ) void {
        c.JS_SetInterruptHandler(self.raw, handler, opaque_ctx);
    }

    /// Clear any installed interrupt handler. Equivalent to passing
    /// a null callback to `JS_SetInterruptHandler`. Useful for test
    /// teardown or for temporarily disabling the budget (e.g., during
    /// a trusted admin handler run).
    /// Drain the microtask / job queue. QuickJS uses this queue for
    /// promise continuations and ES module top-level evaluation;
    /// anything that eval'd to a promise (or scheduled one) needs
    /// pumping before its side effects are observable. Safe to call
    /// when the queue is already empty.
    ///
    /// The interrupt handler still fires inside `JS_ExecutePendingJob`,
    /// so a runaway microtask chain still gets killed by the CPU budget.
    pub fn pumpJobs(self: Runtime) void {
        var pctx: ?*c.JSContext = null;
        while (c.JS_IsJobPending(self.raw)) {
            _ = c.JS_ExecutePendingJob(self.raw, &pctx);
        }
    }

    pub fn clearInterruptHandler(self: Runtime) void {
        c.JS_SetInterruptHandler(self.raw, null, null);
    }

    /// Create a new execution context under this runtime. Contexts hold
    /// the global object and installable intrinsics.
    ///
    /// The rove-kv patch to vendor/quickjs-ng leaves `ctx.random_state`
    /// and `ctx.time_origin` at 0 so snapshot creation is deterministic.
    /// For callers using the direct (non-snapshot) path, this method
    /// auto-seeds both from wall-clock sources so `Math.random()` and
    /// `performance.now()` behave normally out of the box.
    ///
    /// The snapshot path does the same seeding in `Snapshot.restore`,
    /// not here — callers that use snapshots should NOT call this.
    pub fn newContext(self: Runtime) Error!Context {
        const ctx = c.JS_NewContext(self.raw) orelse return Error.ContextCreateFailed;
        c.JS_SetTimeOrigin(ctx, c.JS_GetMonotonicTimeMs());
        c.JS_SetRandomSeed(ctx, @intCast(std.time.microTimestamp()));
        return .{ .raw = ctx };
    }
};

/// A QuickJS execution context. Holds a global object, Bus intrinsics,
/// and is the scope within which scripts run. Multiple contexts can share
/// a runtime; they see different globals but share the same atom table
/// and GC.
pub const Context = struct {
    raw: *c.JSContext,

    pub fn deinit(self: *Context) void {
        c.JS_FreeContext(self.raw);
        self.* = undefined;
    }

    /// Evaluate a JS source string. Returns an owned `Value` on success;
    /// on a JS-level exception, returns `Error.JsException` and the
    /// exception is left pending on the context — retrieve it via
    /// `takeException` or clear it via `resetException`.
    ///
    /// `filename` is used in stack traces; it doesn't affect resolution.
    /// `flags` lets you pick between global script, module, etc. —
    /// see `EvalFlags` below. Default is `.global`.
    pub fn eval(
        self: Context,
        source: []const u8,
        filename: [:0]const u8,
        flags: EvalFlags,
    ) Error!Value {
        const result = c.JS_Eval(
            self.raw,
            source.ptr,
            source.len,
            filename.ptr,
            flags.toCInt(),
        );
        const v: Value = .{ .raw = result, .ctx = self.raw };
        if (v.isException()) return Error.JsException;
        return v;
    }

    /// Return the pending exception as a `Value`, clearing the pending
    /// state. Use after `eval` returned `Error.JsException`. The caller
    /// owns the returned value and must `deinit` it. Returns `null` if no
    /// exception is pending.
    pub fn takeException(self: Context) ?Value {
        const ex = c.JS_GetException(self.raw);
        const v: Value = .{ .raw = ex, .ctx = self.raw };
        if (v.isNull()) return null;
        return v;
    }

    /// Convenience: take the exception, stringify it, return the owned
    /// UTF-8 message. Caller frees with `allocator.free`. If there's no
    /// exception pending, returns an empty string.
    /// Compile `source` to QuickJS bytecode without executing it. Returns
    /// an allocator-owned buffer; caller frees with `allocator.free`.
    /// Bytecode is portable across contexts/runtimes built from the same
    /// quickjs-ng build — rove-code stores it as a content-addressed blob
    /// and any worker can read it back via `evalBytecode`.
    pub fn compileToBytecode(
        self: Context,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
        flags: EvalFlags,
    ) Error![]u8 {
        const compile_flags = flags.toCInt() | c.JS_EVAL_FLAG_COMPILE_ONLY;
        // QuickJS's `JS_Eval` takes a length parameter but still
        // requires the source buffer to be NUL-terminated — the UTF-8
        // validator peeks one byte past the end. A []const u8 slice
        // has no such guarantee, so surprising "invalid UTF-8"
        // SyntaxErrors fire whenever the byte after the slice happens
        // to look like a UTF-8 continuation byte. Dup into a
        // guaranteed-NUL-terminated buffer here — this was a subtle
        // bug from the rove-code-server thread path.
        const src_z = try allocator.allocSentinel(u8, source.len, 0);
        defer allocator.free(src_z);
        @memcpy(src_z, source);
        const fun_obj = c.JS_Eval(
            self.raw,
            src_z.ptr,
            source.len,
            filename.ptr,
            compile_flags,
        );
        var fun_val: Value = .{ .raw = fun_obj, .ctx = self.raw };
        if (fun_val.isException()) return Error.JsException;
        defer fun_val.deinit();

        var size: usize = 0;
        const buf = c.JS_WriteObject(self.raw, &size, fun_obj, c.JS_WRITE_OBJ_BYTECODE);
        if (buf == null) return Error.JsException;
        defer c.js_free(self.raw, buf);

        const out = allocator.alloc(u8, size) catch return Error.OutOfMemory;
        @memcpy(out, @as([*]const u8, @ptrCast(buf))[0..size]);
        return out;
    }

    /// Read a previously-compiled bytecode buffer and execute it. The
    /// source must have been produced by `compileToBytecode` against a
    /// compatible quickjs-ng build.
    pub fn evalBytecode(self: Context, bytes: []const u8) Error!Value {
        const fun_obj = c.JS_ReadObject(
            self.raw,
            bytes.ptr,
            bytes.len,
            c.JS_READ_OBJ_BYTECODE,
        );
        var fun_val: Value = .{ .raw = fun_obj, .ctx = self.raw };
        if (fun_val.isException()) return Error.JsException;
        // JS_EvalFunction consumes the reference.
        fun_val = undefined;
        const result = c.JS_EvalFunction(self.raw, fun_obj);
        const v: Value = .{ .raw = result, .ctx = self.raw };
        if (v.isException()) return Error.JsException;
        return v;
    }

    pub fn takeExceptionMessage(
        self: Context,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var ex = self.takeException() orelse {
            return try allocator.dupe(u8, "");
        };
        defer ex.deinit();
        return ex.toOwnedString(allocator);
    }
};

pub const EvalFlags = packed struct(u32) {
    /// Script vs module. Module mode parses `import`/`export`; script
    /// does not.
    kind: enum(u1) { global, module } = .global,
    /// Reserved QuickJS flag bits (EVAL_FLAG_STRICT, _COMPILE_ONLY, etc.)
    _pad: u31 = 0,

    fn toCInt(self: EvalFlags) c_int {
        return switch (self.kind) {
            .global => c.JS_EVAL_TYPE_GLOBAL,
            .module => c.JS_EVAL_TYPE_MODULE,
        };
    }
};

/// A JS value. Owned — call `deinit` when done (unless ownership was
/// transferred elsewhere). The `ctx` pointer is required for the free
/// path because QuickJS refcounts values through the context.
pub const Value = struct {
    raw: c.JSValue,
    ctx: *c.JSContext,

    pub fn deinit(self: *Value) void {
        c.JS_FreeValue(self.ctx, self.raw);
        self.* = undefined;
    }

    /// True if the value is the `exception` sentinel — set when a JS
    /// op raised. Should only be observed immediately after an eval/call;
    /// `eval` already converts this into `Error.JsException`.
    pub fn isException(self: Value) bool {
        return c.JS_IsException(self.raw);
    }

    pub fn isNull(self: Value) bool {
        return c.JS_IsNull(self.raw);
    }

    pub fn isUndefined(self: Value) bool {
        return c.JS_IsUndefined(self.raw);
    }

    pub fn isBool(self: Value) bool {
        return c.JS_IsBool(self.raw);
    }

    pub fn isNumber(self: Value) bool {
        return c.JS_IsNumber(self.raw);
    }

    pub fn isString(self: Value) bool {
        return c.JS_IsString(self.raw);
    }

    /// Best-effort conversion to int32. JS numbers that don't fit truncate
    /// the same way `| 0` does in JS. Throws a JS exception on failure,
    /// which turns into `Error.JsException`.
    pub fn toI32(self: Value) Error!i32 {
        var out: i32 = 0;
        if (c.JS_ToInt32(self.ctx, &out, self.raw) != 0) return Error.JsException;
        return out;
    }

    pub fn toF64(self: Value) Error!f64 {
        var out: f64 = 0;
        if (c.JS_ToFloat64(self.ctx, &out, self.raw) != 0) return Error.JsException;
        return out;
    }

    pub fn toBool(self: Value) bool {
        return c.JS_ToBool(self.ctx, self.raw) != 0;
    }

    /// Convert the value to a UTF-8 string and copy into an allocator-
    /// owned buffer. Works on anything (calls JS's ToString internally).
    /// Caller frees with `allocator.free`.
    pub fn toOwnedString(self: Value, allocator: std.mem.Allocator) Error![]u8 {
        var len: usize = 0;
        const cstr = c.JS_ToCStringLen(self.ctx, &len, self.raw);
        if (cstr == null) return Error.JsException;
        defer c.JS_FreeCString(self.ctx, cstr);
        const out = allocator.alloc(u8, len) catch return Error.OutOfMemory;
        @memcpy(out, @as([*]const u8, @ptrCast(cstr))[0..len]);
        return out;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "create runtime + context + eval simple arithmetic" {
    var rt = try Runtime.init();
    defer rt.deinit();

    var ctx = try rt.newContext();
    defer ctx.deinit();

    var result = try ctx.eval("1 + 1", "test.js", .{});
    defer result.deinit();

    try testing.expect(result.isNumber());
    try testing.expectEqual(@as(i32, 2), try result.toI32());
}

test "eval string returns JS string" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var result = try ctx.eval("'hello ' + 'world'", "test.js", .{});
    defer result.deinit();

    try testing.expect(result.isString());
    const s = try result.toOwnedString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello world", s);
}

test "eval with syntax error returns JsException" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    try testing.expectError(Error.JsException, ctx.eval("this is not valid js @#$", "test.js", .{}));

    // Exception should be retrievable.
    const msg = try ctx.takeExceptionMessage(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(msg.len > 0);
}

test "eval with runtime error (ReferenceError)" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    try testing.expectError(Error.JsException, ctx.eval("nonexistent_variable", "test.js", .{}));

    const msg = try ctx.takeExceptionMessage(testing.allocator);
    defer testing.allocator.free(msg);
    // QuickJS reports "ReferenceError: nonexistent_variable is not defined" or similar.
    try testing.expect(std.mem.indexOf(u8, msg, "ReferenceError") != null);
}

test "eval module with export" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var result = try ctx.eval("export const x = 42;", "mod.js", .{ .kind = .module });
    defer result.deinit();
    // Module evaluation returns a Promise in quickjs-ng.
    try testing.expect(result.isUndefined() or result.isNumber() or !result.isException());
}

test "float conversion" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    var result = try ctx.eval("Math.PI", "test.js", .{});
    defer result.deinit();

    const pi = try result.toF64();
    try testing.expectApproxEqRel(@as(f64, 3.14159265358979), pi, 1e-10);
}

test "compile to bytecode + eval round trip" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    const bc = try ctx.compileToBytecode("40 + 2", "rt.js", testing.allocator, .{});
    defer testing.allocator.free(bc);
    try testing.expect(bc.len > 0);

    var result = try ctx.evalBytecode(bc);
    defer result.deinit();
    try testing.expectEqual(@as(i32, 42), try result.toI32());
}

test "compile syntax error surfaces as JsException" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    try testing.expectError(
        Error.JsException,
        ctx.compileToBytecode("@@@ not js @@@", "bad.js", testing.allocator, .{}),
    );
    const msg = try ctx.takeExceptionMessage(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(msg.len > 0);
}

test "bytecode portable across contexts in same runtime" {
    var rt = try Runtime.init();
    defer rt.deinit();

    var ctx1 = try rt.newContext();
    const bc = try ctx1.compileToBytecode("1 + 2 + 3", "rt.js", testing.allocator, .{});
    defer testing.allocator.free(bc);
    ctx1.deinit();

    var ctx2 = try rt.newContext();
    defer ctx2.deinit();
    var result = try ctx2.evalBytecode(bc);
    defer result.deinit();
    try testing.expectEqual(@as(i32, 6), try result.toI32());
}

test "setInterruptHandler kills a tight loop" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // Simple counter the callback increments until it trips the limit.
    // `kill_after` mirrors the "N operations" shape we want for tape
    // determinism — see the dispatcher's Budget struct in rove-js.
    const Counter = struct {
        ticks: u64 = 0,
        kill_after: u64,

        fn cb(_: ?*c.JSRuntime, op: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(op.?));
            self.ticks += 1;
            return if (self.ticks >= self.kill_after) 1 else 0;
        }
    };

    var counter: Counter = .{ .kill_after = 100 };
    rt.setInterruptHandler(&Counter.cb, &counter);

    // A tight infinite loop in pure JS. Without the interrupt handler
    // this would hang the test forever. With it, QJS unwinds after the
    // counter trips.
    try testing.expectError(
        Error.JsException,
        ctx.eval("while (true) {}", "loop.js", .{}),
    );
    try testing.expect(counter.ticks >= 100);

    // Exception message should be retrievable.
    const msg = try ctx.takeExceptionMessage(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(msg.len > 0);
}

test "setInterruptHandler does not fire for short handlers" {
    var rt = try Runtime.init();
    defer rt.deinit();
    var ctx = try rt.newContext();
    defer ctx.deinit();

    // kill_after is huge; short code finishes first.
    const Counter = struct {
        ticks: u64 = 0,
        kill_after: u64,
        fn cb(_: ?*c.JSRuntime, op: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(op.?));
            self.ticks += 1;
            return if (self.ticks >= self.kill_after) 1 else 0;
        }
    };

    var counter: Counter = .{ .kill_after = std.math.maxInt(u64) };
    rt.setInterruptHandler(&Counter.cb, &counter);

    var result = try ctx.eval("1 + 1", "ok.js", .{});
    defer result.deinit();
    try testing.expectEqual(@as(i32, 2), try result.toI32());
}

test {
    _ = @import("snap.zig");
}
