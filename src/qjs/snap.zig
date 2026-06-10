//! arenajs wrapper for rove-qjs.
//!
//! Replaces shift-js's memcpy + bitmap-relocation snapshot machinery
//! with the arenajs dual-arena model: the runtime+context are created
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

pub const c = root.c;

/// Default base-arena size: holds the runtime, intrinsics, globals,
/// and any setup eval the init_fn does. Must fit everything the
/// init_fn allocates plus arenajs's internal overhead. Matches the
/// 10 MiB ceiling shift-js's old memcpy snapshot used to hit.
pub const DEFAULT_BASE_SIZE: usize = 10 * 1024 * 1024;

/// Default request-arena size: holds per-request allocations (loaded
/// handler bytecode, intermediate JS values, response building).
/// Handler authors who exceed this see JS OOM on the offending alloc.
///
/// Sizing notes (raised 4 MiB → 100 MiB, 2026-06-09):
/// - This bounds ALLOCATION VOLUME per activation, not live-set —
///   a bump arena never reclaims within a request, so transient
///   garbage counts in full. 4 MiB proved tight for handlers
///   touching ~100 KB+ payloads once any allocation-amplifying
///   code ran over them.
/// - The arena is lazily-committed anonymous mmap (qjs-arena.c), so
///   the per-worker cost is virtual until touched; RSS grows to
///   each worker's high-water mark, not worker_count × 100 MiB.
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
};

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

        return .{ .rt = rt, .ctx = ctx };
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
    var result = try r.context.eval("1 + 1", "snap-test.js", .{});
    defer result.deinit();
    try testing.expectEqual(@as(i32, 2), try result.toI32());
}

test "Snapshot.restore repeated N times is stable" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const r = snap.restore();
        var result = try r.context.eval("2 * 21", "snap-test.js", .{});
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
