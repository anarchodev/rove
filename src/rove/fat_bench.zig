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

fn CollN(comptime R: type, comptime cap: u32) type {
    return Collection(R, .{ .capacity = cap });
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
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var pa = try Coll(PhaseRow).init(alloc);
        defer pa.deinit();
        reg.registerCollection(&pa, 1);
        var pb = try Coll(PhaseRow).init(alloc);
        defer pb.deinit();
        reg.registerCollection(&pb, 2);

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
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide, 1);
        var narrow = try Coll(NarrowRow).init(alloc);
        defer narrow.deinit();
        reg.registerCollection(&narrow, 2);

        var ents: [K]Entity = undefined;
        try createAll(&reg, &wide, &ents);
        try runMoveScenario("detour survive | fat park/unpark     | batch", true, &reg, &ents, &wide, &narrow);
        try runMoveScenario("detour survive | fat park/unpark     | immediate", false, &reg, &ents, &wide, &narrow);
    }
}

/// A large population RESIDES in the detour state while a small cohort
/// cycles in and out of an active state. The cohort's own copies are at
/// parity between the models (see detour-survive); what residency
/// isolates is everything else: each churn hop swap-fills the hole with
/// a BYSTANDER's row — 8B under fat, 152B under carry-all — and the idle
/// collection's working set is K_RES×8B vs K_RES×152B, which is the
/// difference between staying cache-hot and not once K_RES grows.
fn benchResidentChurn(alloc: std.mem.Allocator, comptime K_RES: u32, comptime C: u32) !void {
    const iters: usize = 200_000 / (2 * C);
    const ops: u64 = iters * 2 * C;

    const churnOnce = struct {
        fn go(reg: anytype, churners: []const Entity, idle: anytype, active: anytype) !u64 {
            var timer = try std.time.Timer.start();
            for (0..iters) |_| {
                for (churners) |e| try reg.moveImmediate(e, idle, active);
                for (churners) |e| try reg.moveImmediate(e, active, idle);
            }
            return timer.read();
        }
    }.go;

    {
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var idle = try CollN(NarrowRow, K_RES).init(alloc);
        defer idle.deinit();
        reg.registerCollection(&idle, 1);
        var active = try CollN(WideRow, K_RES).init(alloc);
        defer active.deinit();
        reg.registerCollection(&active, 2);

        const ents = try alloc.alloc(Entity, K_RES);
        defer alloc.free(ents);
        try createAll(&reg, &active, ents);
        for (ents) |e| try reg.move(e, &active, &idle); // park M+Addr
        try reg.flush();
        const churners = ents[0..C];

        var totals: [REPS]u64 = undefined;
        _ = try churnOnce(&reg, churners, &idle, &active);
        for (&totals) |*t| t.* = try churnOnce(&reg, churners, &idle, &active);
        report(std.fmt.comptimePrint("churn K={d} C={d} | fat idle 8B (144B parked)", .{ K_RES, C }), totals, ops);
    }
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
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide, 1);
        var ents: [K]Entity = undefined;
        try run("iterate column M | fat", &reg, &wide, &ents);
    }
}

/// Per-entity resolver costs: `get` through a known collection (both
/// models — same shape), `getFat` resident (fn-table dispatch into the
/// column), `getFat` parked (shadow slot).
fn benchLookup(alloc: std.mem.Allocator) !void {
    {
        var reg = try FatReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 1024 });
        defer reg.deinit();
        var wide = try Coll(WideRow).init(alloc);
        defer wide.deinit();
        reg.registerCollection(&wide, 1);
        var narrow = try Coll(NarrowRow).init(alloc);
        defer narrow.deinit();
        reg.registerCollection(&narrow, 2);
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

// ---------------------------------------------------------------------------
// Scenario A — unknown-home resolution, shaped like rove-h2's stream chain
// ---------------------------------------------------------------------------
// rove-h2's 11 server-stream chain collections share ONE row type; close
// and streamSet resolve "which collection holds this entity" by scanning
// a candidate tuple (serverStreamColls + isInCollection / getAny /
// moveAny). This measures that dispatch pattern against the fat model's
// id-indexed answers: getFat for reads, collectionIdOf + declared-id
// index for moves (the coll-enum discipline on fat storage).

const Sid = struct { id: u32 = 0, weight: u16 = 0, flags: u16 = 0 };
const Sess = struct { ptr: usize = 0 };
const ReqH = struct { ptr: usize = 0, len: u32 = 0, cap: u32 = 0 };
const ReqB = struct { ptr: usize = 0, len: u32 = 0, cap: u32 = 0 };
const RespH = struct { ptr: usize = 0, len: u32 = 0, cap: u32 = 0 };
const RespB = struct { ptr: usize = 0, len: u32 = 0, cap: u32 = 0 };
const St = struct { code: u16 = 0, phase: u16 = 0, r: u32 = 0 };
const IoRes = struct { v: u64 = 0 };

const StreamRow = Row(&.{ Sid, Sess, ReqH, ReqB, RespH, RespB, St, IoRes });
const StreamColl = Collection(StreamRow, .{ .capacity = K });
const FatStreamReg = FatRegistry(StreamRow);
const NCHAIN = 11;
const CLOSE_CYCLES = 10;

fn benchUnknownHome(alloc: std.mem.Allocator) !void {
    // ---- fat: id-indexed dispatch ----
    {
        var reg = try FatStreamReg.init(alloc, .{ .max_entities = MAXE, .deferred_queue_capacity = 8192 });
        defer reg.deinit();
        var chain: [NCHAIN]StreamColl = undefined;
        for (&chain) |*c| c.* = try StreamColl.init(alloc);
        defer for (&chain) |*c| c.deinit();
        for (&chain, 0..) |*c, ci| reg.registerCollection(c, @intCast(ci + 1));
        var terminal = try StreamColl.init(alloc);
        defer terminal.deinit();
        reg.registerCollection(&terminal, NCHAIN + 1);

        const ents = try alloc.alloc(Entity, K);
        defer alloc.free(ents);
        for (ents, 0..) |*e, i| e.* = try reg.create(&chain[i % NCHAIN]);

        // resolve: getFat is position-independent — one row covers
        // uniform and worst alike
        {
            var totals: [REPS]u64 = undefined;
            for (0..REPS + 1) |rep| {
                var acc: u64 = 0;
                var timer = try std.time.Timer.start();
                for (0..LOOKUP_PASSES) |_| {
                    for (ents) |e| acc +%= (try reg.getFat(e, Sid)).id;
                }
                const t = timer.read();
                std.mem.doNotOptimizeAway(acc);
                if (rep > 0) totals[rep - 1] = t;
            }
            report("resolve | fat getFat, any distribution", totals, LOOKUP_PASSES * K);
        }

        // close from unknown home: membership read via collectionIdOf,
        // typed collection recovered by declared-id index (all chain
        // collections share one type, so the enum switch is an index)
        {
            var totals: [REPS]u64 = undefined;
            for (0..REPS + 1) |rep| {
                var t: u64 = 0;
                for (0..CLOSE_CYCLES) |_| {
                    var timer = try std.time.Timer.start();
                    for (ents) |e| {
                        const raw = reg.collectionIdOf(e) orelse return error.Stale;
                        try reg.move(e, &chain[raw - 1], &terminal);
                    }
                    try reg.flush();
                    t += timer.read();
                    for (ents, 0..) |e, i| try reg.moveImmediate(e, &terminal, &chain[i % NCHAIN]);
                }
                if (rep > 0) totals[rep - 1] = t;
            }
            report("close   | fat id-index (coll-enum ids), uniform", totals, CLOSE_CYCLES * K);
        }
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
    std.debug.print("\n", .{});
    try benchResidentChurn(alloc, 4096, 256);
    try benchResidentChurn(alloc, 16384, 512);
    std.debug.print("\n", .{});
    try benchIterate(alloc);
    std.debug.print("\n", .{});
    try benchLookup(alloc);
    std.debug.print("\nscenario A — h2-shaped unknown-home dispatch ({d} chain colls, {d}B stream row, K={d} uniform)\n", .{ NCHAIN, comptime rowSize(StreamRow), K });
    try benchUnknownHome(alloc);
}

fn rowSize(comptime R: type) comptime_int {
    comptime var n = 0;
    inline for (R.types) |T| n += @sizeOf(T);
    return n;
}
