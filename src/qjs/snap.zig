// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! arenajs wrapper for rove-qjs.
//!
//! Wraps the arenajs dual-arena model: the runtime+context are created
//! and frozen once into a base arena that lives forever; each request
//! resets the request arena via a single cursor write (~9 ns) and
//! reseeds time/random.
//!
//! Lifecycle (paired with caller code, typically a Dispatcher):
//!
//!   var snap = try Snapshot.create(.{}, init_fn, user_data);
//!   // init_fn ran with ALLOC mode = base; everything it allocated
//!   // (intrinsics, globals, prelude eval results) lives in the
//!   // immortal base. JS_FreezeRuntime has flipped allocation to
//!   // request mode and page-protected base.
//!
//!   for each request:
//!       const restored = snap.restore();
//!       // restored.runtime / .context are the same pointers each
//!       // request — base is shared. Per-request allocations land
//!       // in the request arena.
//!       defer snap.resetForNext();  // or call at top of next request
//!
//!   snap.deinit();
//!
//! Constraints inherited from arenajs (see vendor/arenajs/README.md):
//!
//!   - One arena-backed runtime per *thread* (per the per-thread fix
//!     in arenajs master). Multi-tenant rove deploys one Snapshot per
//!     worker thread.
//!   - Single context per runtime.
//!   - No JS_FreeRuntime after JS_FreezeRuntime; teardown is
//!     js_dual_arena_free (called from Snapshot.deinit).
//!   - Fixed buffer sizes — sized at create() and never grow. Sizing
//!     is the embedder's responsibility.

const std = @import("std");
const root = @import("root.zig");
const version_mod = @import("version.zig");

pub const c = root.c;

/// Default base-arena size: holds the runtime, intrinsics, globals,
/// and any setup eval the init_fn does. Must fit everything the
/// init_fn allocates plus arenajs's internal overhead.
pub const DEFAULT_BASE_SIZE: usize = 10 * 1024 * 1024;

/// Default request-arena size: holds per-request allocations (loaded
/// handler bytecode, intermediate JS values, response building).
/// Handler authors who exceed this see JS OOM on the offending alloc.
///
/// Sizing notes:
/// - This bounds the PEAK LIVE SET per activation: the request
///   allocator is arenajs's GC regime (dlmalloc mspace + refcount /
///   cycle GC), so garbage is reclaimed mid-run and only what a
///   handler holds at once counts. A few MiB is still too tight for
///   handlers touching ~100 KB+ payloads once any allocation-
///   amplifying code runs over them.
/// - Request memory is provider-backed extents acquired on demand
///   (qjs-arena.h `js_dual_arena_new2`), so this is a budget, not a
///   reservation: RSS grows to each worker's high-water mark, not
///   worker_count × 100 MiB.
pub const DEFAULT_REQUEST_SIZE: usize = 100 * 1024 * 1024;

pub const Sizes = struct {
    base_size: usize = DEFAULT_BASE_SIZE,
    request_size: usize = DEFAULT_REQUEST_SIZE,
};

pub const Error = error{
    RuntimeCreateFailed,
    ContextCreateFailed,
    InitFnFailed,
    OutOfMemory,
    RequestCreateFailed,
    /// `JS_EnterRequest` / `JS_LeaveRequest` / `JS_FreeRequest` refuse
    /// with a JS frame live — request switches happen only between
    /// runs, where the C stack holds no JS.
    RequestSwitchInsideJs,
};

/// A request arena that may be held across a return to the host
/// (arenajs requests-as-objects). Values never cross requests: a
/// JSValue obtained while one request is entered is dereferenced only
/// while that same request is entered again.
pub const HeldRequest = *c.JSRequestArena;

/// Caller-supplied setup. Runs ONCE during Snapshot.create with the
/// dual arena in BASE mode — every allocation lands in the immortal
/// base arena. Install intrinsics, globals, and run any prelude eval
/// here. After init_fn returns, Snapshot.create calls
/// JS_FreezeRuntime which page-protects base; subsequent JS execution
/// is verified base-clean by arenajs's test262 sweep.
///
/// Must NOT call JS_FreeRuntime / JS_FreeContext.
pub const InitFn = *const fn (
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    user_data: ?*anyopaque,
) Error!void;

/// Frozen runtime+context. Owns the dual arena; lives until deinit.
pub const Snapshot = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    /// The JS engine version this snapshot's runtime embodies
    /// (`version.zig`). Stamped per-request into the `LogRecord` and the
    /// replicated readset header so replay can later fetch the matching
    /// engine. Set from the compile-time constant at create; one engine
    /// per binary today (selection is a no-op until the first bump).
    version: u16 = version_mod.JS_ENGINE_VERSION,
    /// The per-request memory budget every request arena is created
    /// with (`Sizes.request_size`) — `newRequest` uses it so a detached
    /// hot-path request and its replacement have the same ceiling.
    request_cap: usize = DEFAULT_REQUEST_SIZE,

    pub const Restored = struct {
        runtime: root.Runtime,
        context: root.Context,
    };

    /// Build the runtime, run init_fn against base, freeze.
    pub fn create(sizes: Sizes, init_fn: InitFn, user_data: ?*anyopaque) Error!Snapshot {
        const rt = c.JS_NewRuntimeArena(sizes.base_size, sizes.request_size) orelse
            return Error.RuntimeCreateFailed;
        errdefer c.js_dual_arena_free(c.JS_GetDualArena(rt));

        // JS_NewContextRaw + selective intrinsics: lets init_fn pick
        // which intrinsics to install. JS_NewContext is fine too;
        // both work pre-freeze.
        const ctx = c.JS_NewContextRaw(rt) orelse return Error.ContextCreateFailed;

        try init_fn(rt, ctx, user_data);

        // Flip allocator to request mode + page-protect base + relocate
        // per-request mutable runtime state. After this returns, no JS
        // code can mutate base bytes (verified by arenajs's test262
        // sweep at vendor/arenajs/arena-test262.c).
        c.JS_FreezeRuntime(rt);

        // The request allocator is the GC regime (dlmalloc mspace +
        // refcount/cycle GC) — the ONLY regime rove runs, on every
        // engine (worker, offline sim, browser replay). Its ceiling is
        // the peak live set, so an activation's transient garbage never
        // counts against the budget and there is no bump-mode OOM to
        // retry from; an OOM here is a genuinely too-large live set and
        // fails loud (`decisions.md` §4.12). arenajs already defaults
        // to GC; set it explicitly so the invariant is stated in code,
        // not inherited. Selection binds at the next reset; restore()
        // runs one before every request.
        c.js_dual_arena_set_request_mode(c.JS_GetDualArena(rt), c.JS_ARENA_REQ_MODE_GC);

        return .{ .rt = rt, .ctx = ctx, .version = version_mod.JS_ENGINE_VERSION, .request_cap = sizes.request_size };
    }

    pub fn deinit(self: *Snapshot) void {
        c.js_dual_arena_free(c.JS_GetDualArena(self.rt));
        self.* = undefined;
    }

    /// Reset the request arena (one cursor write) and reseed the
    /// per-request time / random state. Returns the runtime+context
    /// pointers (same every call — base is shared).
    ///
    /// Call before evaluating each request's handler. On the very
    /// first request this is also fine — JS_FreezeRuntime leaves the
    /// request arena in a clean state, and the reseed gets the
    /// per-request state to a sensible value.
    pub fn restore(self: *Snapshot) Restored {
        c.JS_ResetRequestArena(self.rt);

        // performance.timeOrigin is a getter reading whatever we set
        // here; performance.now() is `monotonic_now_ms - time_origin`.
        // arenajs's internal `js__now_ms` reads CLOCK_MONOTONIC (via
        // `js__hrtime_ns`); we set time_origin from the same clock so
        // performance.now() returns small relative ms instead of
        // process-uptime ms.
        c.JS_SetTimeOrigin(self.ctx, monotonicMs());
        // Math.random() degenerates to always-0 with a 0 seed; xorshift
        // needs any non-zero seed.
        c.JS_SetRandomSeed(self.ctx, @intCast(std.time.microTimestamp()));

        return .{
            .runtime = .{ .raw = self.rt },
            .context = .{ .raw = self.ctx },
        };
    }

    // ── requests as objects ──────────────────────────────────────────
    //
    // The frozen runtime runs one request at a time but may hold any
    // number. The worker's hot path never sees this: `restore()` resets
    // whichever request is entered. A handler that returns to the host
    // with a promise awaiting a host operation keeps its request — the
    // dispatcher leaves it, gives the runtime a fresh one, and re-enters
    // the held one when the operation completes. Enter/leave/free only
    // between runs (no JS frame live).

    /// The request allocations currently land in — null when none is
    /// entered (the runtime then accepts no allocation).
    pub fn currentRequest(self: *const Snapshot) ?HeldRequest {
        return c.JS_CurrentRequest(self.rt);
    }

    /// Create a request arena with the snapshot's per-request budget
    /// (peak live set, the GC regime). NOT entered: the entered request,
    /// if any, stays entered.
    pub fn newRequest(self: *Snapshot) Error!HeldRequest {
        return c.JS_NewRequest(self.rt, self.request_cap, null, c.JS_ARENA_REQ_MODE_GC) orelse
            Error.RequestCreateFailed;
    }

    pub fn enterRequest(self: *Snapshot, req: HeldRequest) Error!void {
        if (c.JS_EnterRequest(self.rt, req) != 0) return Error.RequestSwitchInsideJs;
    }

    pub fn leaveRequest(self: *Snapshot) Error!void {
        if (c.JS_LeaveRequest(self.rt) != 0) return Error.RequestSwitchInsideJs;
    }

    /// Free the request's memory (leaves it first if it is entered).
    pub fn freeRequest(self: *Snapshot, req: HeldRequest) Error!void {
        if (c.JS_FreeRequest(self.rt, req) != 0) return Error.RequestSwitchInsideJs;
    }

    /// Bytes a request holds across a park — every extent it has
    /// acquired, whether or not its allocator is using them. The
    /// per-held-connection memory cost.
    pub fn heldBytes(req: HeldRequest) usize {
        return c.js_request_arena_held(req);
    }

    /// True iff the request arena refused an allocation THIS request
    /// (cleared by the next reset). The capacity-vs-user-error
    /// discriminator: by the time the OOM propagates, QJS may have
    /// mangled it into a bare `null` exception — this record is the
    /// source of truth (and what turns a mangled OOM outcome into a
    /// loud 500 instead of a plausible success).
    pub fn oomHit(self: *const Snapshot) bool {
        return c.js_dual_arena_oom_hit(c.JS_GetDualArena(self.rt));
    }

    pub const OomStats = struct { requested: usize, used: usize, limit: usize };

    /// The refused allocation's numbers, for actionable logs.
    pub fn oomStats(self: *const Snapshot) OomStats {
        const da = c.JS_GetDualArena(self.rt);
        return .{
            .requested = c.js_dual_arena_oom_requested(da),
            .used = c.js_dual_arena_oom_used(da),
            .limit = c.js_dual_arena_oom_limit(da),
        };
    }
};

/// Monotonic milliseconds, matching arenajs's internal `js__now_ms`
/// (which reads CLOCK_MONOTONIC via `js__hrtime_ns`). Used as the
/// `performance.timeOrigin` anchor so `performance.now()` returns
/// small relative milliseconds.
pub fn monotonicMs() f64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return 0;
    const sec_ms = @as(f64, @floatFromInt(ts.sec)) * 1000.0;
    const nsec_ms = @as(f64, @floatFromInt(ts.nsec)) / 1_000_000.0;
    return sec_ms + nsec_ms;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn minimalInit(rt: *c.JSRuntime, ctx: *c.JSContext, _: ?*anyopaque) Error!void {
    _ = rt;
    _ = c.JS_AddIntrinsicBaseObjects(ctx);
    _ = c.JS_AddIntrinsicEval(ctx);
    // performance.now() / performance.timeOrigin land on the global
    // via this; without it the perf-time-origin test below sees
    // ReferenceError on `performance`.
    _ = c.JS_AddPerformance(ctx);
}

test "Snapshot.create succeeds with minimal init" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();
}

test "Snapshot.restore round-trips: 1 + 1 still = 2" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();

    const r = snap.restore();
    var result = try evalOrReport(r.context, "1 + 1", "snap-test.js");
    defer result.deinit();
    try testing.expectEqual(@as(i32, 2), try result.toI32());
}

test "Snapshot.restore repeated N times is stable" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const r = snap.restore();
        var result = try evalOrReport(r.context, "2 * 21", "snap-test.js");
        defer result.deinit();
        try testing.expectEqual(@as(i32, 42), try result.toI32());
    }
}

test "Snapshot.restore: performance.now and Math.random work after restore" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();

    const r = snap.restore();
    const ctx = r.context;

    var perf_result = try ctx.eval("performance.now()", "perf.js", .{});
    defer perf_result.deinit();
    const elapsed_ms = try perf_result.toF64();
    try testing.expect(std.math.isFinite(elapsed_ms));
    try testing.expect(elapsed_ms >= 0);
    try testing.expect(elapsed_ms < 1000);

    var origin_result = try ctx.eval("performance.timeOrigin", "origin.js", .{});
    defer origin_result.deinit();
    const origin_ms = try origin_result.toF64();
    try testing.expect(std.math.isFinite(origin_ms));
    try testing.expect(origin_ms > 0);

    var rand_result = try ctx.eval("Math.random()", "rand.js", .{});
    defer rand_result.deinit();
    const rv = try rand_result.toF64();
    try testing.expect(std.math.isFinite(rv));
    try testing.expect(rv >= 0);
    try testing.expect(rv < 1);

    var rv2_result = try ctx.eval("Math.random()", "rand2.js", .{});
    defer rv2_result.deinit();
    const rv2 = try rv2_result.toF64();
    try testing.expect(rv2 != rv);
}

test "request allocator runs in GC mode: the churny loop succeeds (ceiling = peak live set)" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();
    const r = snap.restore();
    try testing.expectEqual(
        @as(c_uint, c.JS_ARENA_REQ_MODE_GC),
        c.js_dual_arena_request_mode(c.JS_GetDualArena(snap.rt)),
    );
    // Cumulative allocation (256 MiB) far exceeds the arena; the peak
    // live set (~1 MiB) does not. Only a reclaiming allocator completes it.
    var result = try r.context.eval(
        \\let s = "";
        \\for (let i = 0; i < 256; i++) { s = "x".repeat(1 << 20) + i; }
        \\s.length
    ,
        "churny-gc.js",
        .{},
    );
    defer result.deinit();
    try testing.expect(!c.js_dual_arena_oom_hit(c.JS_GetDualArena(snap.rt)));
}

test "GC canary: a live set past the arena budget OOMs with oom_hit set" {
    // The budget is the PEAK live set: hold every string at once (16 MiB
    // against an 8 MiB arena) and the request must be refused with the
    // arena's exhaustion record set — that record is what separates
    // capacity from a JS throw once QJS has mangled the exception.
    var snap = try Snapshot.create(.{ .request_size = 8 * 1024 * 1024 }, minimalInit, null);
    defer snap.deinit();
    const r = snap.restore();
    var result = r.context.eval(
        \\const a = [];
        \\for (let i = 0; i < 32; i++) a.push("x".repeat(1 << 19) + i);
        \\a.length
    ,
        "live-set.js",
        .{},
    ) catch {
        try testing.expect(c.js_dual_arena_oom_hit(c.JS_GetDualArena(snap.rt)));
        return;
    };
    result.deinit();
    return error.TestExpectedOom;
}

test "Snapshot.restore preserves complex JS behavior" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();

    const r = snap.restore();
    var result = try r.context.eval(
        \\const nums = [1, 2, 3, 4, 5];
        \\const squared = nums.map(n => n * n);
        \\const sum = squared.reduce((a, b) => a + b, 0);
        \\`sum=${sum}`
    ,
        "complex.js",
        .{},
    );
    defer result.deinit();
    const str = try result.toOwnedString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("sum=55", str);
}

/// `minimalInit` plus an install-time script that allocates far more than the
/// base budget — what a shim outgrowing the arena does, without needing to
/// grow a real shim to reach it. Reports what `JS_Eval` did through
/// `user_data` so the test can assert on it.
fn hungryInit(rt: *c.JSRuntime, ctx: *c.JSContext, user_data: ?*anyopaque) Error!void {
    try minimalInit(rt, ctx, null);
    const src = "globalThis.__hog = []; for (let i = 0; i < 200000; i++) __hog.push({ i: i, s: 'x'.repeat(64) });";
    const v = c.JS_Eval(ctx, src.ptr, src.len, "hungry.js", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, v);
    if (user_data) |ud| {
        const threw: *bool = @ptrCast(@alignCast(ud));
        threw.* = c.JS_IsException(v);
    }
}

test "base-arena exhaustion during install surfaces as a JS exception, not silence" {
    // This pins the MECHANISM the loud-install guard depends on. rove's
    // `evalSnippet` panics with the JS exception text when a global shim
    // fails to evaluate; that guard is only worth having if an arena that
    // runs out during install actually raises one, rather than failing the
    // allocation quietly and letting `JS_FreezeRuntime` page-protect a
    // half-built object graph.
    //
    // Checked rather than assumed: `js_dual_arena_oom_hit()` does NOT report
    // base-arena misses — it stayed false through this exact scenario, which
    // is why there is no OOM check in `create`. A guard that cannot trip is
    // worse than no guard, because it reads like coverage.
    var threw = false;
    var snap = try Snapshot.create(.{ .base_size = 2 * 1024 * 1024 }, hungryInit, &threw);
    defer snap.deinit();
    try std.testing.expect(threw);
}

// `JS_UNDEFINED` is a macro with a struct initializer that translate-c
// does not carry over; the same construction `globals.zig` uses.
fn jsUndefined() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
}

fn promiseInit(rt: *c.JSRuntime, ctx: *c.JSContext, ud: ?*anyopaque) Error!void {
    try minimalInit(rt, ctx, ud);
    _ = c.JS_AddIntrinsicPromise(ctx);
}

/// Eval that surfaces the thrown value's text on failure (a bare
/// `error.JsException` says nothing about a held-request mistake).
fn evalOrReport(ctx: root.Context, src: [:0]const u8, name: [:0]const u8) !root.Value {
    return ctx.eval(src, name, .{}) catch |e| {
        const exc = c.JS_GetException(ctx.raw);
        defer c.JS_FreeValue(ctx.raw, exc);
        const cs = c.JS_ToCString(ctx.raw, exc);
        defer c.JS_FreeCString(ctx.raw, cs);
        std.debug.print("\n{s}: {s}\n", .{ name, if (cs != null) std.mem.span(cs) else "<no message>" });
        return e;
    };
}

test "held request: a promise awaiting the host survives leave/enter and settles on resume" {
    var snap = try Snapshot.create(.{}, promiseInit, null);
    defer snap.deinit();
    const r = snap.restore();
    const ctx = snap.ctx;

    // Park the request entered at freeze — the worker's hot-path request.
    // A park never migrates values: the parked request keeps its memory
    // and the runtime is handed a fresh one for everything else.
    const parked = snap.currentRequest() orelse return error.NoCurrentRequest;

    // The host-side promise. The resolver lives in `parked`'s memory; Zig
    // keeps only the handle and calls it while `parked` is entered again.
    var funcs: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(ctx, &funcs);
    try testing.expect(!c.JS_IsException(promise));
    {
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);
        // A write to the (base) global object shadows it into `parked`.
        try testing.expect(c.JS_SetPropertyStr(ctx, global, "p", promise) >= 0);
    }
    var ev = try evalOrReport(r.context, "globalThis.out = 'pending'; p.then(v => { globalThis.out = 'got:' + v; }); 0", "held-a.js");
    ev.deinit();
    r.runtime.pumpJobs();
    {
        var v = try evalOrReport(r.context, "globalThis.out", "held-a2.js");
        defer v.deinit();
        const sv = try v.toOwnedString(testing.allocator);
        defer testing.allocator.free(sv);
        try testing.expectEqualStrings("pending", sv);
    }

    // Park it. Give the runtime a fresh request and run an unrelated
    // request to completion on it — the reset-per-request hot path.
    try snap.leaveRequest();
    const fresh = try snap.newRequest();
    try snap.enterRequest(fresh);
    const r2 = snap.restore();
    {
        // Nothing of the parked request is visible: its shadows of the
        // global are its own, and its promise is not this request's.
        var v = try evalOrReport(r2.context, "typeof globalThis.out + ':' + typeof globalThis.p", "fresh.js");
        defer v.deinit();
        const sv = try v.toOwnedString(testing.allocator);
        defer testing.allocator.free(sv);
        try testing.expectEqualStrings("undefined:undefined", sv);
    }
    try snap.leaveRequest();

    // Resume: re-enter the parked request. Its heap is exactly as left.
    try snap.enterRequest(parked);
    {
        var v = try evalOrReport(r.context, "globalThis.out", "held-b.js");
        defer v.deinit();
        const sv = try v.toOwnedString(testing.allocator);
        defer testing.allocator.free(sv);
        try testing.expectEqualStrings("pending", sv);
    }
    // The host operation completed: settle the promise from Zig, drain
    // the request's microtasks, observe the continuation ran.
    var arg = c.JS_NewInt32(ctx, 42);
    const rv = c.JS_Call(ctx, funcs[0], jsUndefined(), 1, &arg);
    try testing.expect(!c.JS_IsException(rv));
    c.JS_FreeValue(ctx, rv);
    r.runtime.pumpJobs();
    {
        var v = try evalOrReport(r.context, "globalThis.out", "held-c.js");
        defer v.deinit();
        const sv = try v.toOwnedString(testing.allocator);
        defer testing.allocator.free(sv);
        try testing.expectEqualStrings("got:42", sv);
    }
    c.JS_FreeValue(ctx, funcs[0]);
    c.JS_FreeValue(ctx, funcs[1]);

    // What a parked request costs: its extents, whether used or not. This
    // is the per-held-connection memory number the budget is set from.
    const held_parked = Snapshot.heldBytes(parked);
    const held_fresh = Snapshot.heldBytes(fresh);
    try testing.expect(held_parked > 0);
    std.debug.print("\nheld-request bytes: parked={d} fresh(after one run)={d}\n", .{ held_parked, held_fresh });

    try snap.freeRequest(fresh);
    // `parked` stays entered — it is the runtime's default request and
    // `deinit` frees every request arena still owned.
}
