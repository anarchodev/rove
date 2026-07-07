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
const version_mod = @import("version.zig");

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

/// Per-request allocator regime (arenajs 0.3 `JSArenaReqMode`).
/// `.bump`: ~3-instruction allocs, O(1) reset, ceiling = CUMULATIVE
/// allocation. `.gc`: dlmalloc mspace + refcount/cycle GC, ~20-30%
/// slower, costlier reset, ceiling = PEAK live set — the churny-
/// handler fallback.
pub const ReqMode = enum { bump, gc };

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

        // arenajs 0.3.0 defaults the request allocator to GC mode
        // (dlmalloc mspace + refcount/cycle GC). Rove runs handlers on
        // the BUMP regime — ~3-instruction allocs, O(1) reset — and
        // will opt churny handlers into GC per-request later (the
        // header's intended oom→retry pattern). Selection takes effect
        // at the next reset; restore() runs one before every request.
        c.js_dual_arena_set_request_mode(c.JS_GetDualArena(rt), c.JS_ARENA_REQ_MODE_BUMP);

        return .{ .rt = rt, .ctx = ctx, .version = version_mod.JS_ENGINE_VERSION };
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
        return self.restoreMode(.bump);
    }

    /// `restore` with an explicit allocator regime for THIS request.
    /// Mode selection binds at the reset (arenajs contract: a request
    /// runs entirely under one regime), so set-then-reset. The mode
    /// persists on the arena until the next restoreMode — which is why
    /// the plain `restore()` pins `.bump` instead of inheriting
    /// whatever the previous request chose.
    pub fn restoreMode(self: *Snapshot, mode: ReqMode) Restored {
        c.js_dual_arena_set_request_mode(c.JS_GetDualArena(self.rt), switch (mode) {
            .bump => c.JS_ARENA_REQ_MODE_BUMP,
            .gc => c.JS_ARENA_REQ_MODE_GC,
        });
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

    /// True iff the request arena refused an allocation THIS request
    /// (cleared by the next reset). The capacity-vs-user-error
    /// discriminator: by the time the OOM propagates, QJS may have
    /// mangled it into a bare `null` exception — this record is the
    /// source of truth (and the bump→GC retry trigger).
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

test "GC mode: the churny loop SUCCEEDS (ceiling = peak live set)" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();
    const r = snap.restoreMode(.gc);
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
    // A later plain restore() must pin the arena back to BUMP.
    _ = snap.restore();
    try testing.expectEqual(
        @as(c_uint, c.JS_ARENA_REQ_MODE_BUMP),
        c.js_dual_arena_request_mode(c.JS_GetDualArena(snap.rt)),
    );
}

test "request allocator runs in BUMP mode (arenajs 0.3 defaults to GC)" {
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();
    const r = snap.restore();
    _ = r;
    try testing.expectEqual(
        @as(c_uint, c.JS_ARENA_REQ_MODE_BUMP),
        c.js_dual_arena_request_mode(c.JS_GetDualArena(snap.rt)),
    );
}

test "BUMP semantics canary: cumulative allocation OOMs even when garbage" {
    // The bump/GC discriminator: this loop's PEAK live set is ~1 MiB
    // (each iteration drops the last string) but its CUMULATIVE
    // allocation far exceeds the request arena. Under BUMP (ceiling =
    // cumulative) it MUST OOM with oom_hit set; under GC (ceiling =
    // peak) it would succeed — so this test failing "successfully"
    // means the mode selection silently regressed to GC.
    var snap = try Snapshot.create(.{}, minimalInit, null);
    defer snap.deinit();
    const r = snap.restore();
    var result = r.context.eval(
        \\let s = "";
        \\for (let i = 0; i < 256; i++) { s = "x".repeat(1 << 20) + i; }
        \\s.length
    ,
        "churny.js",
        .{},
    ) catch {
        // Eval failed — the OOM propagated as an exception. The arena's
        // exhaustion record must confirm this was capacity, not a JS
        // throw.
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
