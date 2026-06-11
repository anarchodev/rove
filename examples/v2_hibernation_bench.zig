//! V2 Phase-6 exit bench (v2-build-order §Phase 6,
//! docs/v2-phase6-hibernation.md, multiraft-scaling-learnings §3.1).
//!
//! Measures the one thing Phase 6 exists to fix: the per-pump-cycle cost as
//! a function of how many tenant groups are in the active (ticked) set. With
//! hibernation, K mostly-idle tenants drain out of the active set, so a pump
//! cycle ticks ~nothing — the cost is O(active), not O(K). This bench shows
//! that directly on one node: form K groups, measure a pump cycle with all K
//! active, let them hibernate, then measure a pump cycle with the active set
//! drained to zero.
//!
//! Build + run (ReleaseFast — Debug numbers are not representative):
//!   zig build v2-hibernation-bench -Doptimize=ReleaseFast
//!   ./zig-out/bin/v2-hibernation-bench [K=2000] [cycles=500]
//!
//! This is the node-level pump-cost microbench the build-order's "K-tenant
//! bench" exit calls for; a full cluster-scale h2load macrobench over
//! thousands of live tenants is the separate, larger follow-up noted in the
//! Phase-6 doc.

const std = @import("std");
const node_mod = @import("node");

const Node = node_mod.Node;

fn nowDir(a: std.mem.Allocator) ![]u8 {
    // A unique-ish temp dir without Date.now(): the pid is enough here.
    const pid: u32 = @intCast(std.os.linux.getpid());
    return std.fmt.allocPrint(a, "/tmp/v2-hib-bench-{d}", .{pid});
}

/// Time `cycles` pump cycles and return the mean wall time per cycle in
/// nanoseconds. Pure tick cost — no proposes, so nothing commits.
fn meanCycleNs(node: *Node, cycles: u32) !u64 {
    var timer = try std.time.Timer.start();
    var i: u32 = 0;
    while (i < cycles) : (i += 1) _ = try node.pump();
    const total = timer.read();
    return total / cycles;
}

pub fn main() !void {
    const a = std.heap.c_allocator;

    var args = std.process.args();
    _ = args.next();
    const K: u64 = if (args.next()) |s| try std.fmt.parseInt(u64, s, 10) else 2000;
    const cycles: u32 = if (args.next()) |s| try std.fmt.parseInt(u32, s, 10) else 500;

    const dir = try nowDir(a);
    defer a.free(dir);
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    // Keep every group awake through formation: a long window so nothing
    // hibernates while we are still creating groups.
    node.hibernate_ns = std.time.ns_per_hour;

    std.debug.print("forming {d} tenant groups (single node)...\n", .{K});
    var form_timer = try std.time.Timer.start();
    var t: u64 = 1;
    while (t <= K) : (t += 1) {
        var idbuf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "tenant-{d}", .{t});
        _ = try node.ensureGroup(t, id);
    }
    const form_ms = form_timer.read() / std.time.ns_per_ms;
    std.debug.print("  formed in {d} ms; active set = {d}\n\n", .{ form_ms, node.active.items.len });

    // Synchronize every group's hibernate deadline to a single short window
    // (formation set per-group deadlines an hour out + staggered by form
    // time; re-bump them all to now + 300ms so regime 1 sees all K active
    // and they then all expire together for the drain).
    node.hibernate_ns = 300 * std.time.ns_per_ms;
    {
        var it = node.groups.keyIterator();
        while (it.next()) |gid| try node.bumpActive(gid.*);
    }

    // ── Regime 1: all K groups active (the pre-hibernation tick-all cost) ─
    const active_n = node.active.items.len;
    const us_active = try meanCycleNs(node, cycles);

    // ── Let them hibernate: drain the active set to zero. ────────────────
    var spins: u32 = 0;
    while (node.active.items.len > 0 and spins < 5000) : (spins += 1) {
        _ = try node.pump();
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    // ── Regime 2: active set drained — the idle-tenant cost. ─────────────
    const idle_n = node.active.items.len;
    const us_idle = try meanCycleNs(node, cycles);

    const af: f64 = @floatFromInt(us_active);
    const idf: f64 = @floatFromInt(us_idle);
    const win = if (idf > 0) af / idf else 0;

    std.debug.print("pump cycle cost ({d} cycles each, {d} tenants total)\n", .{ cycles, K });
    std.debug.print("  regime         active_set   mean_cycle\n", .{});
    std.debug.print("  ----------------------------------------------\n", .{});
    std.debug.print("  tick-all       {d:>8}     {d:.1} us/cycle ({d} cycles/sec)\n", .{ active_n, af / 1000.0, perSec(us_active) });
    std.debug.print("  hibernated     {d:>8}     {d:.1} us/cycle ({d} cycles/sec)\n", .{ idle_n, idf / 1000.0, perSec(us_idle) });
    std.debug.print("  ----------------------------------------------\n", .{});
    std.debug.print("  => {d:.1}x lower pump cycle time when {d} tenants are idle\n", .{ win, K });
    std.debug.print("     (all {d} groups still exist — hibernated, not destroyed)\n", .{node.groups.count()});
}

fn perSec(ns_per_cycle: u64) u64 {
    if (ns_per_cycle == 0) return 0;
    return std.time.ns_per_s / ns_per_cycle;
}
