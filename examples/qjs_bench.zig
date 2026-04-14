//! `qjs-bench` — compares two ways of getting a fresh JS context:
//!
//!   1. Naive: `JS_NewRuntime` + `JS_NewContext` (what each request would
//!      pay without snapshots).
//!   2. Snapshot: pre-built snapshot + `Snapshot.restore` into a reset
//!      arena (the rove-js fast path).
//!
//! Prints the per-op cost of each so we can actually see the win.

const std = @import("std");
const qjs = @import("rove-qjs");

const ITERS: usize = 1_000;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    // ── Naive path: Runtime + Context per iter ─────────────────────────
    {
        var total_ns: u64 = 0;
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const t0 = std.time.nanoTimestamp();
            var rt = try qjs.Runtime.init();
            var ctx = try rt.newContext();
            var r = try ctx.eval("1 + 1", "bench.js", .{});
            r.deinit();
            ctx.deinit();
            rt.deinit();
            total_ns += @intCast(std.time.nanoTimestamp() - t0);
        }
        try w.print(
            "naive JS_NewRuntime+NewContext:  {d:>8} ns/iter  ({d} iters)\n",
            .{ total_ns / ITERS, ITERS },
        );
    }

    // ── Snapshot path: restore into arena per iter ─────────────────────
    {
        var arena_src = try qjs.Arena.create(allocator);
        defer arena_src.destroy();
        var snap = try qjs.Snapshot.create(allocator, arena_src, snapInit, null);
        defer snap.deinit();

        var arena_dst = try qjs.Arena.create(allocator);
        defer arena_dst.destroy();

        var total_ns: u64 = 0;
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            arena_dst.reset();
            const t0 = std.time.nanoTimestamp();
            const r = try snap.restore(arena_dst);
            var result = try r.context.eval("1 + 1", "bench.js", .{});
            result.deinit();
            total_ns += @intCast(std.time.nanoTimestamp() - t0);
        }
        try w.print(
            "snapshot restore + reused arena: {d:>8} ns/iter  ({d} iters)\n",
            .{ total_ns / ITERS, ITERS },
        );
        try w.print(
            "snapshot size:                   {d:>8} bytes\n",
            .{snap.data.len},
        );
        try w.print(
            "relocations in bitmap:           {d:>8}\n",
            .{snap.reloc_count()},
        );
        try w.print(
            "volatile slots:                  {d:>8}\n",
            .{snap.volatile_count()},
        );
    }

    // ── Decomposition: memcpy alone, bitmap walk alone ─────────────────
    //
    // Upper bound on what a "pre-relocated cached snapshot" optimization
    // could achieve: just the memcpy, no bitmap fixup, no JS_Set* calls,
    // no eval. Also times the bitmap walk in isolation so we know whether
    // the optimization is worth pursuing.
    {
        var arena_src = try qjs.Arena.create(allocator);
        defer arena_src.destroy();
        var snap = try qjs.Snapshot.create(allocator, arena_src, snapInit, null);
        defer snap.deinit();

        var arena_dst = try qjs.Arena.create(allocator);
        defer arena_dst.destroy();

        // memcpy only
        {
            var total_ns: u64 = 0;
            var i: usize = 0;
            while (i < ITERS) : (i += 1) {
                const t0 = std.time.nanoTimestamp();
                @memcpy(arena_dst.data[0..snap.data.len], snap.data);
                total_ns += @intCast(std.time.nanoTimestamp() - t0);
            }
            try w.print(
                "memcpy-only (lower bound):       {d:>8} ns/iter  ({d} iters)\n",
                .{ total_ns / ITERS, ITERS },
            );
        }

        // bitmap walk only (on an already-copied buffer)
        {
            @memcpy(arena_dst.data[0..snap.data.len], snap.data);
            var total_ns: u64 = 0;
            var i: usize = 0;
            const delta: i64 = 12345; // arbitrary non-zero — forces the store path
            while (i < ITERS) : (i += 1) {
                const t0 = std.time.nanoTimestamp();
                for (snap.bitmap, 0..) |word_const, word_idx| {
                    var word = word_const;
                    while (word != 0) {
                        const bit: u6 = @intCast(@ctz(word));
                        const slot_idx = word_idx * 64 + bit;
                        const offset = slot_idx * @sizeOf(*anyopaque);
                        var slot_val: u64 = 0;
                        @memcpy(std.mem.asBytes(&slot_val), arena_dst.data[offset..][0..8]);
                        const relocated: u64 = @bitCast(@as(i64, @bitCast(slot_val)) + delta);
                        @memcpy(arena_dst.data[offset..][0..8], std.mem.asBytes(&relocated));
                        word &= word - 1;
                    }
                }
                total_ns += @intCast(std.time.nanoTimestamp() - t0);
            }
            try w.print(
                "bitmap walk only (cost of fixup):{d:>8} ns/iter  ({d} iters)\n",
                .{ total_ns / ITERS, ITERS },
            );
        }
    }

    try w.flush();
}

fn snapInit(
    arena: *qjs.Arena,
    out_rt_offset: *usize,
    out_ctx_offset: *usize,
    _: ?*anyopaque,
) qjs.snap.Error!void {
    const rt = qjs.c.JS_NewRuntime2(&qjs.bump_mf, arena.qjsOpaque()) orelse
        return qjs.snap.Error.RuntimeCreateFailed;
    const ctx = qjs.c.JS_NewContext(rt) orelse return qjs.snap.Error.ContextCreateFailed;
    out_rt_offset.* = qjs.offsetOf(arena, rt);
    out_ctx_offset.* = qjs.offsetOf(arena, ctx);
}
