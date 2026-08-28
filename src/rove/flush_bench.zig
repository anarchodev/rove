// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! flush-bench — deferred-queue machinery microbenchmark for
//! `FatRegistry.flush`. Run via `zig build flush-bench` (pinned
//! ReleaseFast, same isolation as fat-bench).
//!
//! `flush` is a phase-boundary primitive: rove-h2's poll prelude/postlude
//! alone call it ~15 times per poll iteration, most with an empty or tiny
//! queue. So the costs that matter are the empty-call fast path, the
//! small-batch overhead (any sorting done to restore highest-offset-first
//! execution within a source collection — the swap-remove discipline),
//! and how enqueue-time RLE coalescing fares when a funnel verb
//! interleaves ops across collections. Each scenario pins one enqueue
//! PATTERN; what the queue machinery makes of it is the measurement.
//!
//! Scenarios, hot path then sweeps:
//!
//! - **empty**       — flush with nothing pending, the dominant call.
//! - **1 op**        — single-entity ping-pong, one op per flush.
//! - **2×8 funnel**  — 16 ops per flush, enqueue alternating between two
//!   source collections in churned (non-ascending) offset order.
//! - **sweep ascending**   — 4096 ops, one source, iteration order:
//!   contiguous ascending offsets, RLE's best case (parity with
//!   fat-bench's batch phase move).
//! - **sweep interleaved** — 2×2048 ops alternating between two sources,
//!   each side in iteration order: same total work as ascending; the
//!   delta vs ascending is what per-op queue machinery the alternation
//!   costs.
//! - **sweep shuffled**    — 4096 ops, one source, random enqueue order:
//!   the sort's full-work bound (no structure to exploit).
//!
//! Methodology: per scenario, REPS repetitions after one warmup; min and
//! median reported. Hot-path scenarios report ns per FLUSH CALL; sweep
//! scenarios report ns per entity-op. Sweep restores run outside the
//! timer. One run is a noise sample, not a rate — compare mins on a
//! quiet box.
const std = @import("std");
const rove = @import("root.zig");
const Row = rove.Row;
const Collection = rove.Collection;
const FatRegistry = rove.fat_mod.FatRegistry;
const Entity = rove.Entity;

// Same 40B phase row as fat-bench's phase-move scenario, so the sweep
// numbers sit on the same scale as its batch line.
const A = struct { v: u64 = 0 };
const M = struct { v: [4]u64 = [_]u64{0} ** 4 };
const PhaseRow = Row(&.{ A, M });
const Universe = PhaseRow;
const FatReg = FatRegistry(Universe);

const K = 4096; // sweep width (entities per cycle)
const MAXE = 65536;
const REPS = 5;
const QCAP = 8192; // > K: worst case is a sweep whose ops never coalesce

const EMPTY_FLUSHES = 1_000_000;
const PING_ITERS = 100_000; // 2 flushes each
const FUNNEL_ITERS = 20_000; // 2 flushes each
const SWEEP_CYCLES = 10; // K timed ops each

fn CollN(comptime cap: u32) type {
    return Collection(PhaseRow, .{ .capacity = cap });
}

/// Full compiler barrier: without it, ReleaseFast can prove an
/// empty-queue flush loop changes nothing and delete it.
inline fn clobberMemory() void {
    asm volatile ("" ::: .{ .memory = true });
}

fn report(name: []const u8, totals: [REPS]u64, ops_per_rep: u64) void {
    var per: [REPS]f64 = undefined;
    for (totals, 0..) |t, i| {
        per[i] = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(ops_per_rep));
    }
    std.mem.sort(f64, &per, {}, std.sort.asc(f64));
    std.debug.print("{s:<52} min {d:7.1} ns/op   med {d:7.1} ns/op\n", .{ name, per[0], per[REPS / 2] });
}

// ---------------------------------------------------------------------------
// Hot path — the per-poll-iteration flush calls
// ---------------------------------------------------------------------------

fn benchEmptyFlush(alloc: std.mem.Allocator) !void {
    var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = QCAP });
    defer reg.deinit();
    var ca = try CollN(K).init(alloc);
    defer ca.deinit();
    reg.registerCollection(&ca, 1);
    var ents: [K]Entity = undefined;
    for (&ents) |*e| e.* = try reg.create(&ca);

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var timer = try std.time.Timer.start();
        for (0..EMPTY_FLUSHES) |_| {
            try reg.flush();
            clobberMemory();
        }
        const t = timer.read();
        if (rep > 0) totals[rep - 1] = t;
    }
    report("flush | empty queue           (ns per flush)", totals, EMPTY_FLUSHES);
}

fn benchOneOpFlush(alloc: std.mem.Allocator) !void {
    var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = QCAP });
    defer reg.deinit();
    var ca = try CollN(16).init(alloc);
    defer ca.deinit();
    reg.registerCollection(&ca, 1);
    var cb = try CollN(16).init(alloc);
    defer cb.deinit();
    reg.registerCollection(&cb, 2);
    const e = try reg.create(&ca);

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var timer = try std.time.Timer.start();
        for (0..PING_ITERS) |_| {
            try reg.move(e, &ca, &cb);
            try reg.flush();
            try reg.move(e, &cb, &ca);
            try reg.flush();
        }
        const t = timer.read();
        if (rep > 0) totals[rep - 1] = t;
    }
    report("flush | 1 op ping-pong        (ns per flush)", totals, PING_ITERS * 2);
}

/// One funnel-shaped phase: 8 entities of each side cross in the same
/// batch, enqueued alternating a,b,a,b — the pattern of a sweep that
/// touches two collections per entity (conn + stream). Churn leaves each
/// side's offsets non-ascending, so this is the small-batch sort case.
fn benchFunnelFlush(alloc: std.mem.Allocator) !void {
    var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = QCAP });
    defer reg.deinit();
    // Each side transiently holds both cohorts mid-flush (appends land
    // before the removals for lower-id sources execute).
    var ca = try CollN(32).init(alloc);
    defer ca.deinit();
    reg.registerCollection(&ca, 1);
    var cb = try CollN(32).init(alloc);
    defer cb.deinit();
    reg.registerCollection(&cb, 2);

    var ea: [8]Entity = undefined;
    for (&ea) |*e| e.* = try reg.create(&ca);
    var eb: [8]Entity = undefined;
    for (&eb) |*e| e.* = try reg.create(&cb);

    const step = struct {
        // x currently resides in `from`, y in `to`; they swap.
        fn go(reg_: *FatReg, x: []const Entity, y: []const Entity, from: anytype, to: anytype) !void {
            for (x, y) |ex, ey| {
                try reg_.move(ex, from, to);
                try reg_.move(ey, to, from);
            }
            try reg_.flush();
        }
    }.go;

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var timer = try std.time.Timer.start();
        for (0..FUNNEL_ITERS) |_| {
            try step(&reg, &ea, &eb, &ca, &cb);
            try step(&reg, &eb, &ea, &ca, &cb);
        }
        const t = timer.read();
        if (rep > 0) totals[rep - 1] = t;
    }
    report("flush | 2x8 interleaved funnel (ns per flush)", totals, FUNNEL_ITERS * 2);
}

// ---------------------------------------------------------------------------
// Sweeps — one big teardown-shaped batch, restore untimed
// ---------------------------------------------------------------------------

/// K ops from one source in iteration order: contiguous ascending, so
/// enqueue coalesces the whole sweep into one block op.
fn benchSweepAscending(alloc: std.mem.Allocator) !void {
    var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = QCAP });
    defer reg.deinit();
    var ca = try CollN(K).init(alloc);
    defer ca.deinit();
    reg.registerCollection(&ca, 1);
    var term = try CollN(K).init(alloc);
    defer term.deinit();
    reg.registerCollection(&term, 2);

    const ents = try alloc.alloc(Entity, K);
    defer alloc.free(ents);
    for (ents) |*e| e.* = try reg.create(&ca);

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var t: u64 = 0;
        for (0..SWEEP_CYCLES) |_| {
            var timer = try std.time.Timer.start();
            for (ents) |e| try reg.move(e, &ca, &term);
            try reg.flush();
            t += timer.read();
            // Restore in creation order so every cycle starts from
            // offsets 0..K-1 in `ents` order.
            for (ents) |e| try reg.moveImmediate(e, &term, &ca);
        }
        if (rep > 0) totals[rep - 1] = t;
    }
    report("sweep | 4096 one source, ascending", totals, SWEEP_CYCLES * K);
}

/// The same K entity-hops as the ascending sweep, but the enqueue
/// alternates between two source collections, each side arriving in
/// ascending offset order. The delta vs the ascending sweep is whatever
/// the queue machinery loses to the alternation — nothing about the
/// entity work itself differs.
fn benchSweepInterleaved(alloc: std.mem.Allocator) !void {
    var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = QCAP });
    defer reg.deinit();
    var ca = try CollN(K / 2).init(alloc);
    defer ca.deinit();
    reg.registerCollection(&ca, 1);
    var cb = try CollN(K / 2).init(alloc);
    defer cb.deinit();
    reg.registerCollection(&cb, 2);
    var term = try CollN(K).init(alloc);
    defer term.deinit();
    reg.registerCollection(&term, 3);

    const ea = try alloc.alloc(Entity, K / 2);
    defer alloc.free(ea);
    for (ea) |*e| e.* = try reg.create(&ca);
    const eb = try alloc.alloc(Entity, K / 2);
    defer alloc.free(eb);
    for (eb) |*e| e.* = try reg.create(&cb);

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var t: u64 = 0;
        for (0..SWEEP_CYCLES) |_| {
            var timer = try std.time.Timer.start();
            for (ea, eb) |x, y| {
                try reg.move(x, &ca, &term);
                try reg.move(y, &cb, &term);
            }
            try reg.flush();
            t += timer.read();
            for (ea) |x| try reg.moveImmediate(x, &term, &ca);
            for (eb) |y| try reg.moveImmediate(y, &term, &cb);
        }
        if (rep > 0) totals[rep - 1] = t;
    }
    report("sweep | 2x2048 interleaved sources", totals, SWEEP_CYCLES * K);
}

/// K ops from one source in a fixed shuffled order: random offsets give
/// the sort no structure and RLE nothing contiguous — the full-work
/// bound for any design that still sorts unordered appends.
fn benchSweepShuffled(alloc: std.mem.Allocator) !void {
    var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = QCAP });
    defer reg.deinit();
    var ca = try CollN(K).init(alloc);
    defer ca.deinit();
    reg.registerCollection(&ca, 1);
    var term = try CollN(K).init(alloc);
    defer term.deinit();
    reg.registerCollection(&term, 2);

    const ents = try alloc.alloc(Entity, K);
    defer alloc.free(ents);
    for (ents) |*e| e.* = try reg.create(&ca);

    // One deterministic shuffle, reused every cycle; the restore below
    // re-establishes `ents`-order offsets, so shuffled enqueue order =
    // random offset order on every cycle.
    const shuffled = try alloc.alloc(Entity, K);
    defer alloc.free(shuffled);
    @memcpy(shuffled, ents);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().shuffle(Entity, shuffled);

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var t: u64 = 0;
        for (0..SWEEP_CYCLES) |_| {
            var timer = try std.time.Timer.start();
            for (shuffled) |e| try reg.move(e, &ca, &term);
            try reg.flush();
            t += timer.read();
            for (ents) |e| try reg.moveImmediate(e, &term, &ca);
        }
        if (rep > 0) totals[rep - 1] = t;
    }
    report("sweep | 4096 shuffled, sort full-work bound", totals, SWEEP_CYCLES * K);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    std.debug.print(
        "flush-bench  deferred queue cap={d}, {d} reps (min/median), ReleaseFast\n" ++
            "row: {d}B | hot path: ns per flush CALL | sweeps: ns per entity-op, K={d}\n\n",
        .{ QCAP, REPS, @sizeOf(A) + @sizeOf(M), K },
    );

    try benchEmptyFlush(alloc);
    try benchOneOpFlush(alloc);
    try benchFunnelFlush(alloc);
    std.debug.print("\n", .{});
    try benchSweepAscending(alloc);
    try benchSweepInterleaved(alloc);
    try benchSweepShuffled(alloc);
}
