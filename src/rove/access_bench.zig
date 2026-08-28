// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Access-pattern microbenchmark: the number behind collections.
//!
//! Three ways to touch the SAME 10k logical entities out of a 100k
//! world, per element size:
//!   dense   — walk a 10k contiguous array (what a collection is)
//!   gather  — 10k random indices into the 100k array (what getFat-ish
//!             point access over a big table is)
//!   scan    — walk all 100k testing a 10%-density flag (what
//!             flag-on-a-fat-struct iteration is)
//! ReleaseFast, min/median of reps, checksum accumulated so nothing
//! folds away. Run via `zig build access-bench`.
const std = @import("std");

const WORLD = 100_000;
const SUBSET = 10_000;
const REPS = 7;
const INNER = 200; // repeats per rep so timings are µs-scale

fn Elem(comptime size: usize) type {
    return struct {
        v: u64,
        _pad: [size - 8]u8 align(8) = undefined,
    };
}

fn benchSize(comptime size: usize, alloc: std.mem.Allocator, rand: std.Random, w: anytype) !void {
    const E = Elem(size);
    const world = try alloc.alloc(E, WORLD);
    defer alloc.free(world);
    const denseArr = try alloc.alloc(E, SUBSET);
    defer alloc.free(denseArr);
    const idx = try alloc.alloc(u32, SUBSET);
    defer alloc.free(idx);
    const flags = try alloc.alloc(bool, WORLD);
    defer alloc.free(flags);

    for (world, 0..) |*e, i| e.v = i;
    for (denseArr, 0..) |*e, i| e.v = i;
    @memset(flags, false);
    // 10% of the world flagged, and the gather hits those same slots —
    // one shuffled sample of SUBSET distinct indices.
    const all = try alloc.alloc(u32, WORLD);
    defer alloc.free(all);
    for (all, 0..) |*p, i| p.* = @intCast(i);
    rand.shuffle(u32, all);
    for (all[0..SUBSET], 0..) |i, k| {
        idx[k] = i;
        flags[i] = true;
    }

    var sink: u64 = 0;
    var t_dense: [REPS]u64 = undefined;
    var t_gather: [REPS]u64 = undefined;
    var t_scan: [REPS]u64 = undefined;

    for (0..REPS) |r| {
        var timer = try std.time.Timer.start();
        for (0..INNER) |_| {
            var s: u64 = 0;
            for (denseArr) |*e| s +%= e.v;
            sink +%= s;
        }
        t_dense[r] = timer.read();

        timer.reset();
        for (0..INNER) |_| {
            var s: u64 = 0;
            for (idx) |i| s +%= world[i].v;
            sink +%= s;
        }
        t_gather[r] = timer.read();

        timer.reset();
        for (0..INNER) |_| {
            var s: u64 = 0;
            for (world, flags) |*e, f| {
                if (f) s +%= e.v;
            }
            sink +%= s;
        }
        t_scan[r] = timer.read();
    }

    const per = struct {
        fn f(ts: []u64) struct { min: f64, med: f64 } {
            std.mem.sort(u64, ts, {}, std.sort.asc(u64));
            const denom: f64 = @floatFromInt(SUBSET * INNER);
            return .{
                .min = @as(f64, @floatFromInt(ts[0])) / denom,
                .med = @as(f64, @floatFromInt(ts[ts.len / 2])) / denom,
            };
        }
    }.f;
    const d = per(&t_dense);
    const g = per(&t_gather);
    const sc = per(&t_scan);
    try w.print(
        "{d:>3}B | dense 10k          min {d:>7.2} ns/elem   med {d:>7.2}\n" ++
            "     | gather 10k of 100k min {d:>7.2} ns/elem   med {d:>7.2}   ({d:.1}x dense)\n" ++
            "     | scan 100k @10%%    min {d:>7.2} ns/hit    med {d:>7.2}   ({d:.1}x dense)\n",
        .{ size, d.min, d.med, g.min, g.med, g.med / d.med, sc.min, sc.med, sc.med / d.med },
    );
    std.mem.doNotOptimizeAway(sink);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const w = &stdout.interface;

    try w.print("access-bench  world={d} subset={d} reps={d} (min/median, ReleaseFast)\n", .{ WORLD, SUBSET, REPS });
    inline for (.{ 8, 32, 64, 152 }) |size| {
        try benchSize(size, alloc, prng.random(), w);
    }
    try w.flush();
}
