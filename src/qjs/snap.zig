//! Snapshot + arena machinery for rove-qjs.
//!
//! This is the port of shift-js's `qjs_snap.c`/`.h` — the memcpy-restore
//! trick that lets us reset a JS runtime to a fully-initialized state in
//! microseconds. The model:
//!
//! 1. All JS runtime allocations flow through a per-arena bump allocator
//!    (`BumpMallocFunctions`) wired into QuickJS via `JS_NewRuntime2`.
//! 2. `Snapshot.create` runs an init callback TWICE in two separately-
//!    allocated arenas. By diffing the two byte images, we identify:
//!      - bytes that are identical → constants, copy verbatim on restore
//!      - 8-byte slots that differ by exactly `(baseB - baseA)` → relocatable
//!        pointers; remember them in a bitmap
//!      - 8-byte slots that differ otherwise → non-deterministic ("volatile")
//!        slots that must be re-seeded per restore. QuickJS has two:
//!        `random_state` and `time_origin`, both inside `JSContext`.
//! 3. `Snapshot.restore` memcpy's the frozen image into a target arena,
//!    walks the bitmap adding `(new_base - old_base)` to each flagged slot,
//!    rewrites the JSRuntime opaque pointer, re-seeds the volatile slots
//!    from the wall clock, and returns the rebuilt `Runtime` + `Context`.
//!
//! The determinism check is the load-bearing correctness property. If a
//! future quickjs-ng upgrade introduces new non-deterministic state inside
//! JSContext, `create` will detect it and either grow the volatile list or
//! abort. Volatile slots outside JSContext are considered a catastrophic
//! bug and panic.

const std = @import("std");
const root = @import("root.zig");

pub const c = root.c;

/// Bytes reserved per arena. Matches shift-js. Any JS runtime + context +
/// global setup must fit in this; we don't grow.
pub const ARENA_SIZE: usize = 10 * 1024 * 1024;

/// Hard cap on non-deterministic slots the snapshot can tolerate.
/// QuickJS currently has two (`random_state`, `time_origin`). If this
/// trips, either the runtime gained a new volatile field or our init
/// function introduced one via a global (e.g. `Math.random()` called
/// during init). Either way, investigate before bumping.
pub const MAX_VOLATILE: usize = 8;

pub const Error = error{
    ArenaAllocFailed,
    ArenaOutOfMemory,
    InitFnFailed,
    NonDeterministic,
    /// A non-deterministic slot was detected during snapshot creation.
    /// Under the rove-kv deterministic-init patch applied to vendor/
    /// quickjs-ng (see vendor/quickjs-ng/rove-kv-deterministic-init.patch.md),
    /// there should be ZERO volatile slots. This error means either:
    ///   1. The quickjs-ng upgrade reintroduced volatile state; reapply
    ///      the patch or extend it.
    ///   2. The user-supplied init_fn invoked a non-deterministic op
    ///      (Math.random, Date.now, crypto.getRandomValues, reading
    ///      an env var, ...).
    VolatileSlotDetected,
    RuntimeCreateFailed,
    ContextCreateFailed,
    OutOfMemory,
};

// ── Bump arena ─────────────────────────────────────────────────────────

/// Per-request arena. Holds exactly `ARENA_SIZE` bytes of owned memory.
///
/// **The bump cursor lives INSIDE the data buffer** (at offset 0) rather
/// than as a separate field on this struct. Reason: QuickJS stores the
/// opaque pointer we hand to `JS_NewRuntime2` inside its `JSRuntime`
/// struct, and that pointer has to relocate correctly across snapshot
/// restore. If we passed `&arena` (the Zig control struct), its address
/// has no fixed relationship to the arena buffer base — so the two
/// determinism-verifying init passes would compute different `opaque`
/// values whose delta is unrelated to the arena-data delta, and the
/// snapshot diff would classify it as "volatile" (unrelocatable random
/// state). By passing `arena.data.ptr` directly as the opaque, we make
/// its delta across runs exactly equal the data-base delta, so the
/// diff classifies it as a relocatable pointer and the bitmap handles
/// it just like any other.
///
/// The first 16 bytes of `data` are reserved (8 for the used counter,
/// 8 for padding to keep everything 16-aligned). Allocations start at
/// offset 16.
pub const Arena = struct {
    allocator: std.mem.Allocator,
    /// Owned backing storage, 16-byte aligned. First 16 bytes are the
    /// reserved prefix described above.
    data: []align(16) u8,

    /// Initial `used` value for a fresh or reset arena. 16 bytes of
    /// prefix: 8 for the counter + 8 padding to keep user allocations
    /// 16-aligned after the counter.
    const PREFIX_LEN: usize = 16;

    pub fn create(allocator: std.mem.Allocator) Error!*Arena {
        const self = allocator.create(Arena) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);
        const buf = allocator.alignedAlloc(u8, .@"16", ARENA_SIZE) catch return Error.ArenaAllocFailed;
        self.* = .{ .allocator = allocator, .data = buf };
        self.writeUsed(PREFIX_LEN);
        return self;
    }

    pub fn destroy(self: *Arena) void {
        const allocator = self.allocator;
        allocator.free(self.data);
        allocator.destroy(self);
    }

    /// Opaque pointer to hand to `JS_NewRuntime2`. This is the arena
    /// data base, which contains the used counter at offset 0.
    pub fn qjsOpaque(self: *Arena) *anyopaque {
        return @ptrCast(self.data.ptr);
    }

    /// Current bump cursor (number of bytes consumed including the
    /// 16-byte prefix). Reads from the in-buffer counter.
    pub fn used(self: *const Arena) usize {
        return std.mem.readInt(usize, self.data[0..@sizeOf(usize)], .little);
    }

    fn writeUsed(self: *Arena, n: usize) void {
        std.mem.writeInt(usize, self.data[0..@sizeOf(usize)], n, .little);
    }

    /// Rewind the bump cursor to the empty state. Required before
    /// restoring into this arena (though `Snapshot.restore` does it
    /// for you).
    pub fn reset(self: *Arena) void {
        self.writeUsed(PREFIX_LEN);
    }

    /// Clear ALL bytes in the arena to zero and reset the cursor.
    /// Used by `Snapshot.create` before each determinism-verifying
    /// init pass so stale content can't sneak in.
    fn zero(self: *Arena) void {
        @memset(self.data, 0);
        self.writeUsed(PREFIX_LEN);
    }
};

// ── QuickJS bump malloc functions ──────────────────────────────────────
//
// Each alloc is a 16-byte-aligned block prefixed by an 8-byte size
// header: `[hdr: u64][payload]`. `free` is a no-op (arena resets wipe
// the lot). `realloc` can grow in place IFF the block is at the end of
// the used region.

const BumpHeader = extern struct {
    size: usize,
};

/// Read the used counter given the opaque data base.
inline fn readUsed(data_ptr: [*]u8) usize {
    const slice: *[@sizeOf(usize)]u8 = @ptrCast(data_ptr);
    return std.mem.readInt(usize, slice, .little);
}

inline fn writeUsedAt(data_ptr: [*]u8, n: usize) void {
    const slice: *[@sizeOf(usize)]u8 = @ptrCast(data_ptr);
    std.mem.writeInt(usize, slice, n, .little);
}

fn bumpMalloc(opaque_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const data_ptr: [*]u8 = @ptrCast(opaque_ptr.?);
    const used = readUsed(data_ptr);
    const need = std.mem.alignForward(usize, @sizeOf(BumpHeader) + size, 16);
    if (used + need > ARENA_SIZE) return null;
    const slot_ptr: [*]u8 = data_ptr + used;
    writeUsedAt(data_ptr, used + need);
    const hdr: *BumpHeader = @ptrCast(@alignCast(slot_ptr));
    hdr.size = size;
    return @ptrCast(slot_ptr + @sizeOf(BumpHeader));
}

fn bumpCalloc(opaque_ptr: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = count * size;
    const p = bumpMalloc(opaque_ptr, total);
    if (p) |ptr| {
        const bytes: [*]u8 = @ptrCast(ptr);
        @memset(bytes[0..total], 0);
    }
    return p;
}

fn bumpFree(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // no-op — arena reset reclaims everything
}

fn bumpRealloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, new_size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return bumpMalloc(opaque_ptr, new_size);
    if (new_size == 0) return null;

    const data_ptr: [*]u8 = @ptrCast(opaque_ptr.?);
    const hdr_ptr: *BumpHeader = @ptrFromInt(@intFromPtr(ptr.?) - @sizeOf(BumpHeader));
    const old_size = hdr_ptr.size;

    const old_total = std.mem.alignForward(usize, @sizeOf(BumpHeader) + old_size, 16);
    const old_end = @intFromPtr(hdr_ptr) + old_total;
    const used = readUsed(data_ptr);
    const arena_end = @intFromPtr(data_ptr) + used;

    if (old_end == arena_end) {
        const new_total = std.mem.alignForward(usize, @sizeOf(BumpHeader) + new_size, 16);
        if (new_total >= old_total) {
            const delta = new_total - old_total;
            if (used + delta > ARENA_SIZE) return null;
            writeUsedAt(data_ptr, used + delta);
        } else {
            writeUsedAt(data_ptr, used - (old_total - new_total));
        }
        hdr_ptr.size = new_size;
        return ptr;
    }

    const new_ptr = bumpMalloc(opaque_ptr, new_size) orelse return null;
    const copy_len = @min(old_size, new_size);
    const src: [*]const u8 = @ptrCast(ptr.?);
    const dst: [*]u8 = @ptrCast(new_ptr);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    return new_ptr;
}

fn bumpUsableSize(ptr: ?*const anyopaque) callconv(.c) usize {
    const hdr_ptr: *const BumpHeader = @ptrFromInt(@intFromPtr(ptr.?) - @sizeOf(BumpHeader));
    return hdr_ptr.size;
}

pub const bump_mf: c.JSMallocFunctions = .{
    .js_calloc = &bumpCalloc,
    .js_malloc = &bumpMalloc,
    .js_free = &bumpFree,
    .js_realloc = &bumpRealloc,
    .js_malloc_usable_size = &bumpUsableSize,
};

// ── Init callback ──────────────────────────────────────────────────────

/// Called by `Snapshot.create` to build the runtime+context inside an
/// arena. Must:
///
///   1. Call `c.JS_NewRuntime2(&bump_mf, arena)` to create the runtime.
///   2. Call `c.JS_NewContext(rt)` to create the context.
///   3. Install any globals / evaluate any setup code.
///   4. Return the offsets of the rt and ctx pointers within the arena
///      bytes via `out_rt_offset` / `out_ctx_offset`.
///
/// The same init function is called TWICE by `create` for the
/// determinism verification, so it must be fully deterministic — no
/// timestamps, no reading /dev/urandom, no filesystem I/O that could
/// change between calls.
pub const InitFn = *const fn (
    arena: *Arena,
    out_rt_offset: *usize,
    out_ctx_offset: *usize,
    user_data: ?*anyopaque,
) Error!void;

/// Compute the offset of `ptr` within `arena.data`. The init callback
/// uses this to report rt/ctx offsets.
pub fn offsetOf(arena: *const Arena, ptr: *const anyopaque) usize {
    return @intFromPtr(ptr) - @intFromPtr(arena.data.ptr);
}

// ── Snapshot type ──────────────────────────────────────────────────────

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    data: []u8, // owned frozen image
    bitmap: []u64, // one bit per 8-byte slot; set = needs relocation
    /// Pointer value that the frozen image was originally built against.
    /// The restore path uses this to compute the delta for relocation.
    old_base: [*]const u8,
    rt_offset: usize,
    ctx_offset: usize,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.data);
        self.allocator.free(self.bitmap);
        self.* = undefined;
    }

    pub fn reloc_count(self: *const Snapshot) usize {
        var n: usize = 0;
        for (self.bitmap) |w| n += @popCount(w);
        return n;
    }

    /// For diagnostics only. Always 0 under the deterministic-init patch.
    pub fn volatile_count(self: *const Snapshot) usize {
        _ = self;
        return 0;
    }

    /// Two-pass determinism-verified snapshot of the runtime an init
    /// callback produces. Allocates a scratch arena at a different
    /// address for the second pass so relocatable pointers can be
    /// distinguished from stable data by diffing.
    pub fn create(
        allocator: std.mem.Allocator,
        arena_a: *Arena,
        init_fn: InitFn,
        user_data: ?*anyopaque,
    ) Error!Snapshot {
        arena_a.zero();
        var rt_off_a: usize = 0;
        var ctx_off_a: usize = 0;
        try init_fn(arena_a, &rt_off_a, &ctx_off_a, user_data);
        const used_a = arena_a.used();

        // Copy pass-A's bytes so we can diff them while pass B reuses
        // the live arena state.
        const data_a = allocator.alloc(u8, used_a) catch return Error.OutOfMemory;
        errdefer allocator.free(data_a);
        @memcpy(data_a, arena_a.data[0..used_a]);

        // Scratch arena at a different address.
        const arena_b = try Arena.create(allocator);
        defer arena_b.destroy();
        arena_b.zero();

        var rt_off_b: usize = 0;
        var ctx_off_b: usize = 0;
        try init_fn(arena_b, &rt_off_b, &ctx_off_b, user_data);
        const used_b = arena_b.used();

        if (used_a != used_b or rt_off_a != rt_off_b or ctx_off_a != ctx_off_b) {
            std.log.err(
                "qjs_snap: non-deterministic init (used {d} vs {d}, rt_off {d} vs {d}, ctx_off {d} vs {d})",
                .{ used_a, used_b, rt_off_a, rt_off_b, ctx_off_a, ctx_off_b },
            );
            return Error.NonDeterministic;
        }

        // Build the relocation bitmap by comparing 8-byte slots.
        //
        // Under the rove-kv deterministic-init patch (see
        // vendor/quickjs-ng/rove-kv-deterministic-init.patch.md), every
        // 8-byte slot must fall into exactly one of three categories:
        //
        //   1. Bit-identical across passes → stable non-pointer data.
        //      Stored verbatim.
        //   2. Differs by exactly `base_delta` → relocatable pointer.
        //      Marked in the relocation bitmap.
        //   3. Differs by anything else → FATAL. Something introduced
        //      non-determinism we don't understand. Either a
        //      quickjs-ng upgrade reintroduced time_origin/random_state
        //      seeding (reapply the patch), or the user's init_fn did
        //      something nondeterministic (called Math.random,
        //      Date.now, read an env var, etc.).
        const num_slots = used_a / @sizeOf(*anyopaque);
        const bitmap_words = (num_slots + 63) / 64;
        const bitmap = allocator.alloc(u64, bitmap_words) catch return Error.OutOfMemory;
        errdefer allocator.free(bitmap);
        @memset(bitmap, 0);

        const base_delta: i64 = @as(i64, @intCast(@intFromPtr(arena_b.data.ptr))) -
            @as(i64, @intCast(@intFromPtr(arena_a.data.ptr)));

        for (0..num_slots) |i| {
            var val_a: u64 = 0;
            var val_b: u64 = 0;
            const byte_off = i * @sizeOf(*anyopaque);
            @memcpy(std.mem.asBytes(&val_a), data_a[byte_off..][0..8]);
            @memcpy(std.mem.asBytes(&val_b), arena_b.data[byte_off..][0..8]);
            if (val_a == val_b) continue;

            const diff: i64 = @bitCast(val_b -% val_a);
            if (diff == base_delta) {
                bitmap[i / 64] |= @as(u64, 1) << @intCast(i % 64);
                continue;
            }

            std.log.err(
                "qjs_snap: non-deterministic slot detected at byte offset {d} (a=0x{x:0>16} b=0x{x:0>16}, base_delta={d}). Under the rove-kv deterministic-init patch this should never happen; audit the patch + your init_fn.",
                .{ byte_off, val_a, val_b, base_delta },
            );
            return Error.VolatileSlotDetected;
        }

        return .{
            .allocator = allocator,
            .data = data_a,
            .bitmap = bitmap,
            .old_base = arena_a.data.ptr,
            .rt_offset = rt_off_a,
            .ctx_offset = ctx_off_a,
        };
    }

    /// Restore a snapshot into `target`. Memcpy's the frozen image,
    /// relocates pointers via the bitmap, re-seeds volatile slots from
    /// the current wall clock, and returns the rebuilt Runtime/Context.
    ///
    /// The returned `Runtime` wraps the reconstructed `JSRuntime*`. Do
    /// NOT call `Runtime.deinit` on it — the memory is owned by the
    /// arena, not by QuickJS's normal free path. Reset the arena instead
    /// (or restore a new snapshot over the top).
    pub fn restore(
        self: *const Snapshot,
        target: *Arena,
    ) Error!struct { runtime: root.Runtime, context: root.Context } {
        // memcpy the full frozen image. Byte 0..8 holds the bump used
        // counter, so target.used() is automatically restored too.
        @memcpy(target.data[0..self.data.len], self.data);

        const new_base: i64 = @intCast(@intFromPtr(target.data.ptr));
        const old_base: i64 = @intCast(@intFromPtr(self.old_base));
        const delta: i64 = new_base - old_base;

        if (delta != 0) {
            for (self.bitmap, 0..) |word_const, word_idx| {
                var word = word_const;
                while (word != 0) {
                    const bit: u6 = @intCast(@ctz(word));
                    const slot_idx = word_idx * 64 + bit;
                    const offset = slot_idx * @sizeOf(*anyopaque);
                    var slot_val: u64 = 0;
                    @memcpy(std.mem.asBytes(&slot_val), target.data[offset..][0..8]);
                    const relocated: u64 = @bitCast(@as(i64, @bitCast(slot_val)) + delta);
                    @memcpy(target.data[offset..][0..8], std.mem.asBytes(&relocated));
                    word &= word - 1;
                }
            }
        }

        const rt_ptr: *c.JSRuntime = @ptrCast(@alignCast(target.data[self.rt_offset..].ptr));
        const ctx_ptr: *c.JSContext = @ptrCast(@alignCast(target.data[self.ctx_offset..].ptr));

        c.JS_UpdateStackTop(rt_ptr);
        c.JS_SetMaxStackSize(rt_ptr, c.JS_DEFAULT_STACK_SIZE);

        // Inject fresh time/seed into the two deterministic-by-default
        // fields. See vendor/quickjs-ng/rove-kv-deterministic-init.patch.md.
        //
        // time_origin MUST come from the same monotonic clock quickjs-ng
        // uses internally (`js__hrtime_ns`). JS_GetMonotonicTimeMs is
        // exposed by the patch for exactly this purpose — using wall-
        // clock time here would make `performance.now()` return large
        // negative values.
        //
        // random_state seed can be anything non-zero; wall-clock
        // microseconds is a convenient source of entropy.
        c.JS_SetTimeOrigin(ctx_ptr, c.JS_GetMonotonicTimeMs());
        c.JS_SetRandomSeed(ctx_ptr, @intCast(std.time.microTimestamp()));

        return .{
            .runtime = .{ .raw = rt_ptr },
            .context = .{ .raw = ctx_ptr },
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Default init callback for tests — just creates a runtime + context
/// with no extra globals or setup. Deterministic.
fn minimalInit(
    arena: *Arena,
    out_rt_offset: *usize,
    out_ctx_offset: *usize,
    _: ?*anyopaque,
) Error!void {
    const rt = c.JS_NewRuntime2(&bump_mf, arena.qjsOpaque()) orelse return Error.RuntimeCreateFailed;
    const ctx = c.JS_NewContext(rt) orelse return Error.ContextCreateFailed;
    out_rt_offset.* = offsetOf(arena, rt);
    out_ctx_offset.* = offsetOf(arena, ctx);
}

test "arena alloc/destroy cycle" {
    var arena = try Arena.create(testing.allocator);
    defer arena.destroy();
    try testing.expectEqual(ARENA_SIZE, arena.data.len);
    try testing.expectEqual(Arena.PREFIX_LEN, arena.used());

    arena.reset();
    try testing.expectEqual(Arena.PREFIX_LEN, arena.used());
}

test "bump allocator serves sequential allocs within arena" {
    var arena = try Arena.create(testing.allocator);
    defer arena.destroy();

    const opq = arena.qjsOpaque();
    const a = bumpMalloc(opq, 100);
    try testing.expect(a != null);
    const b = bumpMalloc(opq, 200);
    try testing.expect(b != null);
    try testing.expect(@intFromPtr(b.?) > @intFromPtr(a.?));

    // Oversize request → null, no state corruption.
    const huge = bumpMalloc(opq, ARENA_SIZE);
    try testing.expect(huge == null);

    // A smaller alloc after the failure still works.
    const c2 = bumpMalloc(opq, 50);
    try testing.expect(c2 != null);
}

test "Snapshot.create succeeds with minimal init" {
    var arena = try Arena.create(testing.allocator);
    defer arena.destroy();

    var snap = try Snapshot.create(testing.allocator, arena, minimalInit, null);
    defer snap.deinit();

    // With the deterministic-init patch applied, there should be zero
    // volatile slots — every non-identical byte between the two init
    // passes must be a relocatable pointer.
    try testing.expect(snap.data.len > 0);
    try testing.expect(snap.reloc_count() > 0);
    try testing.expectEqual(@as(usize, 0), snap.volatile_count());
}

test "Snapshot.restore round-trips: 1 + 1 still = 2" {
    var arena_src = try Arena.create(testing.allocator);
    defer arena_src.destroy();

    var snap = try Snapshot.create(testing.allocator, arena_src, minimalInit, null);
    defer snap.deinit();

    // Restore into a DIFFERENT arena (different base address) to
    // exercise the relocation path.
    var arena_dst = try Arena.create(testing.allocator);
    defer arena_dst.destroy();

    const restored = try snap.restore(arena_dst);
    const ctx = restored.context;

    var result = try ctx.eval("1 + 1", "snap-test.js", .{});
    defer result.deinit();
    try testing.expectEqual(@as(i32, 2), try result.toI32());
}

test "Snapshot.restore repeated N times is stable" {
    var arena_src = try Arena.create(testing.allocator);
    defer arena_src.destroy();

    var snap = try Snapshot.create(testing.allocator, arena_src, minimalInit, null);
    defer snap.deinit();

    var arena_dst = try Arena.create(testing.allocator);
    defer arena_dst.destroy();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        arena_dst.reset();
        const r = try snap.restore(arena_dst);
        var result = try r.context.eval("2 * 21", "snap-test.js", .{});
        defer result.deinit();
        try testing.expectEqual(@as(i32, 42), try result.toI32());
    }
}

test "Snapshot.restore: performance.now and Math.random work after restore" {
    var arena_src = try Arena.create(testing.allocator);
    defer arena_src.destroy();
    var snap = try Snapshot.create(testing.allocator, arena_src, minimalInit, null);
    defer snap.deinit();

    var arena_dst = try Arena.create(testing.allocator);
    defer arena_dst.destroy();

    const r = try snap.restore(arena_dst);
    const ctx = r.context;

    // performance.now() reads `js__now_ms() - ctx.time_origin`. If
    // restore didn't call JS_SetTimeOrigin, time_origin would be 0 and
    // performance.now() would return a giant hrtime value. With the
    // setter called, elapsed_ms should be a small non-negative number.
    var perf_result = try ctx.eval("performance.now()", "perf.js", .{});
    defer perf_result.deinit();
    const elapsed_ms = try perf_result.toF64();
    try testing.expect(std.math.isFinite(elapsed_ms));
    try testing.expect(elapsed_ms >= 0);
    try testing.expect(elapsed_ms < 1000); // < 1s between restore and eval

    // performance.timeOrigin is now a getter (rove-kv patch), so it
    // must reflect whatever JS_SetTimeOrigin wrote.
    var origin_result = try ctx.eval("performance.timeOrigin", "origin.js", .{});
    defer origin_result.deinit();
    const origin_ms = try origin_result.toF64();
    try testing.expect(std.math.isFinite(origin_ms));
    try testing.expect(origin_ms > 0);

    // Math.random() must produce a valid [0, 1) double. Requires
    // JS_SetRandomSeed to have been called post-restore; otherwise
    // random_state is 0 and xorshift64 degenerates to always 0.
    var rand_result = try ctx.eval("Math.random()", "rand.js", .{});
    defer rand_result.deinit();
    const r_val = try rand_result.toF64();
    try testing.expect(std.math.isFinite(r_val));
    try testing.expect(r_val >= 0);
    try testing.expect(r_val < 1);

    // Two consecutive calls should give different values (proves the
    // PRNG is actually stepping, not just returning 0).
    var r_val2_result = try ctx.eval("Math.random()", "rand2.js", .{});
    defer r_val2_result.deinit();
    const r_val2 = try r_val2_result.toF64();
    try testing.expect(r_val2 != r_val);
}

test "Snapshot.restore preserves complex JS behavior" {
    var arena_src = try Arena.create(testing.allocator);
    defer arena_src.destroy();

    var snap = try Snapshot.create(testing.allocator, arena_src, minimalInit, null);
    defer snap.deinit();

    var arena_dst = try Arena.create(testing.allocator);
    defer arena_dst.destroy();

    const r = try snap.restore(arena_dst);
    const ctx = r.context;

    // Closures, array methods, template literals — real JS features
    // that exercise the shape/atom tables we relocated.
    var result = try ctx.eval(
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
