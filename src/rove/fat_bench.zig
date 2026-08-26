// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! fat-bench — move-cost microbenchmark for the two storage models:
//! `Registry` (archetype: row = storage) vs `FatRegistry` (fat-entity:
//! shadow store + collections as views), on the same `Collection`
//! machinery. Run via `zig build fat-bench` (pinned ReleaseFast — the
//! shipped optimization mode, where `std.debug.assert` compiles out
//! exactly as it does in production).
//!
//! What it measures, per the model's performance thesis (pay bytes at
//! transitions, keep iteration free):
//!
//! - **phase move** — src/dst rows identical. The models share the same
//!   recipe shape here; expect parity.
//! - **detour, values survive** — the entity passes through a state that
//!   does not use most of its components and the values must survive.
//!   Fat: wide ↔ narrow, parking/unparking the row difference through
//!   the shadow. Archetype: the only way values survive is a carrying
//!   intermediate row that keeps every component, paying full-row copies
//!   on every hop and every swap-remove while resident.
//! - **detour, lossy** — archetype `moveStrip` through a true narrow row
//!   (values destroyed, re-defaulted on return): the cheapest archetype
//!   detour, as context for what the carry costs buy.
//! - **iterate / lookup** — the dense hot path (identical `Collection`
//!   columns in both models), and the resolver costs: `get` through a
//!   known collection vs `getFat`'s runtime dispatch, resident and parked.
//!
//! Methodology: per scenario, REPS repetitions after one warmup; min and
//! median ns/op reported. One run is a noise sample, not a rate — compare
//! mins across models on a quiet box, not single numbers.
const std = @import("std");
const rove = @import("root.zig");
const Row = rove.Row;
const Collection = rove.Collection;
const Registry = rove.Registry;
const FatRegistry = rove.fat_mod.FatRegistry;
const Entity = rove.Entity;

// Component palette: word-sized, mid, and address-shaped (the size of a
// std.net.Address — the fattest thing a rove row realistically inlines).
const A = struct { v: u64 = 0 };
const M = struct { v: [4]u64 = [_]u64{0} ** 4 };
const Addr = struct { bytes: [112]u8 = [_]u8{0} ** 112 };

const PhaseRow = Row(&.{ A, M }); // 40 B
const WideRow = Row(&.{ A, M, Addr }); // 152 B
const NarrowRow = Row(&.{A}); // 8 B
const Universe = WideRow;
const FatReg = FatRegistry(Universe);

const K = 4096; // entities per collection
const MAXE = 65536;
const REPS = 5;
const MOVE_ITERS = 25; // ping-pong iterations per rep (2*K moves each)
const ITER_PASSES = 2000; // column passes per rep
const LOOKUP_PASSES = 200; // entity-loop passes per rep


fn Coll(comptime R: type) type {
    return Collection(R, .{ .capacity = K });
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

fn report(name: []const u8, totals: [REPS]u64, ops_per_rep: u64) void {
    var per: [REPS]f64 = undefined;
    for (totals, 0..) |t, i| {
        per[i] = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(ops_per_rep));
    }
    std.mem.sort(f64, &per, {}, std.sort.asc(f64));
    std.debug.print("{s:<52} min {d:7.1} ns/op   med {d:7.1} ns/op\n", .{ name, per[0], per[REPS / 2] });
}

// ---------------------------------------------------------------------------
// Generic drivers — Registry and FatRegistry share these signatures
// ---------------------------------------------------------------------------

fn createAll(reg: anytype, coll: anytype, ents: []Entity) !void {
    for (ents) |*e| e.* = try reg.create(coll);
}

fn pingPongDeferred(reg: anytype, ents: []const Entity, a: anytype, b: anytype) !u64 {
    var timer = try std.time.Timer.start();
    for (0..MOVE_ITERS) |_| {
        for (ents) |e| try reg.move(e, a, b);
        try reg.flush();
        for (ents) |e| try reg.move(e, b, a);
        try reg.flush();
    }
    return timer.read();
}

fn pingPongImmediate(reg: anytype, ents: []const Entity, a: anytype, b: anytype) !u64 {
    var timer = try std.time.Timer.start();
    for (0..MOVE_ITERS) |_| {
        for (ents) |e| try reg.moveImmediate(e, a, b);
        for (ents) |e| try reg.moveImmediate(e, b, a);
    }
    return timer.read();
}

fn runMoveScenario(
    name: []const u8,
    comptime deferred: bool,
    reg: anytype,
    ents: []const Entity,
    a: anytype,
    b: anytype,
) !void {
    var totals: [REPS]u64 = undefined;
    // Warmup, then measured reps. Every rep ends with the population back
    // in `a`, so reps are identical work.
    _ = if (deferred) try pingPongDeferred(reg, ents, a, b) else try pingPongImmediate(reg, ents, a, b);
    for (&totals) |*t| {
        t.* = if (deferred) try pingPongDeferred(reg, ents, a, b) else try pingPongImmediate(reg, ents, a, b);
    }
    report(name, totals, MOVE_ITERS * 2 * K);
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

/// Identical src/dst rows — the common phase transition. Same recipe
/// shape in both models; this is the parity check.
fn benchPhaseMoves(alloc: std.mem.Allocator) !void {
    {
        var reg = try Registry.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var pa = try Coll(PhaseRow).init(alloc);
        defer pa.deinit();
        reg.registerCollection(&pa);
        var pb = try Coll(PhaseRow).init(alloc);
        defer pb.deinit();
        reg.registerCollection(&pb);

        var ents: [K]Entity = undefined;
        try createAll(&reg, &pa, &ents);
        try runMoveScenario("phase move  40B row | archetype | batch", true, &reg, &ents, &pa, &pb);
        try runMoveScenario("phase move  40B row | archetype | immediate", false, &reg, &ents, &pa, &pb);
    }
    {
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var pa = try Coll(PhaseRow).init(alloc);
        defer pa.deinit();
        reg.registerCollection(&pa);
        var pb = try Coll(PhaseRow).init(alloc);
        defer pb.deinit();
        reg.registerCollection(&pb);

        var ents: [K]Entity = undefined;
        try createAll(&reg, &pa, &ents);
        try runMoveScenario("phase move  40B row | fat       | batch", true, &reg, &ents, &pa, &pb);
        try runMoveScenario("phase move  40B row | fat       | immediate", false, &reg, &ents, &pa, &pb);
    }
}

/// The entity detours through a state that only reads A, and the M/Addr
/// values must survive. Fat parks 144B through the shadow and the narrow
/// residency is an 8B row; the archetype must carry all 152B through
/// every hop to keep the values alive.
fn benchDetourSurvive(alloc: std.mem.Allocator) !void {
    {
        var reg = try Registry.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide);
        var carry = try Coll(WideRow).init(alloc);
        defer carry.deinit();
        reg.registerCollection(&carry);

        var ents: [K]Entity = undefined;
        try createAll(&reg, &wide, &ents);
        try runMoveScenario("detour survive | archetype carry-all | batch", true, &reg, &ents, &wide, &carry);
        try runMoveScenario("detour survive | archetype carry-all | immediate", false, &reg, &ents, &wide, &carry);
    }
    {
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide);
        var narrow = try Coll(NarrowRow).init(alloc);
        defer narrow.deinit();
        reg.registerCollection(&narrow);

        var ents: [K]Entity = undefined;
        try createAll(&reg, &wide, &ents);
        try runMoveScenario("detour survive | fat park/unpark     | batch", true, &reg, &ents, &wide, &narrow);
        try runMoveScenario("detour survive | fat park/unpark     | immediate", false, &reg, &ents, &wide, &narrow);
    }
}

/// Archetype detour through a TRUE narrow row: values destroyed on the
/// way out, re-defaulted on the way back. The cheapest archetype detour
/// — context for what carry-all's survival costs.
fn benchDetourLossy(alloc: std.mem.Allocator) !void {
    var reg = try Registry.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
    defer reg.deinit();
    var wide = try Coll(WideRow).init(alloc);
    defer wide.deinit();
    reg.registerCollection(&wide);
    var narrow = try Coll(NarrowRow).init(alloc);
    defer narrow.deinit();
    reg.registerCollection(&narrow);

    var ents: [K]Entity = undefined;
    try createAll(&reg, &wide, &ents);

    var totals: [REPS]u64 = undefined;
    for (0..REPS + 1) |rep| {
        var timer = try std.time.Timer.start();
        for (0..MOVE_ITERS) |_| {
            for (ents) |e| try reg.moveStripImmediate(e, &wide, &narrow, &.{ M, Addr });
            for (ents) |e| try reg.moveImmediate(e, &narrow, &wide);
        }
        const t = timer.read();
        if (rep > 0) totals[rep - 1] = t; // rep 0 is warmup
    }
    report("detour LOSSY   | archetype moveStrip | immediate", totals, MOVE_ITERS * 2 * K);
}

/// The dense hot path: iterate a column. Identical Collection storage in
/// both models — the fat model's thesis is that this row never changes.
fn benchIterate(alloc: std.mem.Allocator) !void {
    const run = struct {
        fn go(name: []const u8, reg: anytype, wide: anytype, ents: []Entity) !void {
            try createAll(reg, wide, ents);
            for (wide.column(M), 0..) |*m, i| m.v[0] = i;

            var totals: [REPS]u64 = undefined;
            for (0..REPS + 1) |rep| {
                var acc: u64 = 0;
                var timer = try std.time.Timer.start();
                for (0..ITER_PASSES) |_| {
                    for (wide.column(M)) |*m| acc +%= m.v[0];
                }
                const t = timer.read();
                std.mem.doNotOptimizeAway(acc);
                if (rep > 0) totals[rep - 1] = t;
            }
            report(name, totals, ITER_PASSES * K);
        }
    }.go;

    {
        var reg = try Registry.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide);
        var ents: [K]Entity = undefined;
        try run("iterate column M | archetype", &reg, &wide, &ents);
    }
    {
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide);
        var ents: [K]Entity = undefined;
        try run("iterate column M | fat", &reg, &wide, &ents);
    }
}

/// Per-entity resolver costs: `get` through a known collection (both
/// models — same shape), `getFat` resident (fn-table dispatch into the
/// column), `getFat` parked (shadow slot).
fn benchLookup(alloc: std.mem.Allocator) !void {
    {
        var reg = try Registry.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide);
        var ents: [K]Entity = undefined;
        try createAll(&reg, &wide, &ents);

        var totals: [REPS]u64 = undefined;
        for (0..REPS + 1) |rep| {
            var acc: u64 = 0;
            var timer = try std.time.Timer.start();
            for (0..LOOKUP_PASSES) |_| {
                for (ents) |e| acc +%= (try reg.get(e, &wide, M)).v[0];
            }
            const t = timer.read();
            std.mem.doNotOptimizeAway(acc);
            if (rep > 0) totals[rep - 1] = t;
        }
        report("lookup M | archetype get (known coll)", totals, LOOKUP_PASSES * K);
    }
    {
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide);
        var narrow = try Coll(NarrowRow).init(alloc);
        defer narrow.deinit();
        reg.registerCollection(&narrow);
        var ents: [K]Entity = undefined;
        try createAll(&reg, &wide, &ents);

        const run = struct {
            fn go(name: []const u8, reg_: *FatReg, ents_: []const Entity, comptime known: bool, wide_: anytype) !void {
                var totals: [REPS]u64 = undefined;
                for (0..REPS + 1) |rep| {
                    var acc: u64 = 0;
                    var timer = try std.time.Timer.start();
                    for (0..LOOKUP_PASSES) |_| {
                        for (ents_) |e| {
                            const p = if (known) try reg_.get(e, wide_, M) else try reg_.getFat(e, M);
                            acc +%= p.v[0];
                        }
                    }
                    const t = timer.read();
                    std.mem.doNotOptimizeAway(acc);
                    if (rep > 0) totals[rep - 1] = t;
                }
                report(name, totals, LOOKUP_PASSES * K);
            }
        }.go;

        try run("lookup M | fat get (known coll)", &reg, &ents, true, &wide);
        try run("lookup M | fat getFat (resident, dispatched)", &reg, &ents, false, &wide);

        // Park everything and resolve through the shadow.
        for (ents) |e| try reg.move(e, &wide, &narrow);
        try reg.flush();
        try run("lookup M | fat getFat (parked, shadow)", &reg, &ents, false, &wide);
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    std.debug.print(
        "fat-bench  K={d} entities, max_entities={d}, {d} reps (min/median), ReleaseFast\n" ++
            "rows: phase={d}B  wide={d}B  narrow={d}B  (A={d}B M={d}B Addr={d}B)\n" ++
            "a batch rep is {d} coalesced {d}-entity flushes; ns/op is per entity-hop\n\n",
        .{
            K,                MAXE,          REPS,
            @sizeOf(A) + @sizeOf(M), @sizeOf(A) + @sizeOf(M) + @sizeOf(Addr), @sizeOf(A),
            @sizeOf(A),       @sizeOf(M),    @sizeOf(Addr),
            MOVE_ITERS * 2,   K,
        },
    );

    try benchPhaseMoves(alloc);
    std.debug.print("\n", .{});
    try benchDetourSurvive(alloc);
    try benchDetourLossy(alloc);
    std.debug.print("\n", .{});
    try benchIterate(alloc);
    std.debug.print("\n", .{});
    try benchLookup(alloc);
}
