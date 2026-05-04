//! `qjs-bench` — compares two ways of getting a fresh JS context:
//!
//!   1. Naive: `JS_NewRuntime` + `JS_NewContext` (what each request would
//!      pay without arena pooling).
//!   2. Snapshot: arenajs frozen runtime + `Snapshot.restore` (the
//!      rove-js fast path — one cursor-write reset of the request arena).
//!
//! Prints the per-op cost of each so we can actually see the win.

const std = @import("std");
const qjs = @import("rove-qjs");

const ITERS: usize = 10_000;

pub fn main() !void {
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

    // ── Snapshot path: cursor-reset per iter ───────────────────────────
    {
        var snap = try qjs.Snapshot.create(.{}, snapInit, null);
        defer snap.deinit();

        var total_ns: u64 = 0;
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const t0 = std.time.nanoTimestamp();
            const r = snap.restore();
            var result = try r.context.eval("1 + 1", "bench.js", .{});
            result.deinit();
            total_ns += @intCast(std.time.nanoTimestamp() - t0);
        }
        try w.print(
            "snapshot restore + 1+1 per iter: {d:>8} ns/iter  ({d} iters)\n",
            .{ total_ns / ITERS, ITERS },
        );
    }

    // ── Floor: reset alone, no eval ────────────────────────────────────
    {
        var snap = try qjs.Snapshot.create(.{}, snapInit, null);
        defer snap.deinit();

        var total_ns: u64 = 0;
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const t0 = std.time.nanoTimestamp();
            _ = snap.restore();
            total_ns += @intCast(std.time.nanoTimestamp() - t0);
        }
        try w.print(
            "snapshot reset alone (floor):    {d:>8} ns/iter  ({d} iters)\n",
            .{ total_ns / ITERS, ITERS },
        );
    }

    try w.flush();
}

fn snapInit(rt: *qjs.c.JSRuntime, ctx: *qjs.c.JSContext, _: ?*anyopaque) qjs.snap.Error!void {
    _ = rt;
    _ = qjs.c.JS_AddIntrinsicBaseObjects(ctx);
    _ = qjs.c.JS_AddIntrinsicEval(ctx);
}
