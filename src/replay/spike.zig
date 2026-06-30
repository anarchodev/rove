//! De-risking spike for the native arenajs replay path (Phase 2, plan §2a).
//!
//! Proves, end to end and self-contained (no Node, no WASM), that we can:
//!   1. link arenajs's native reactor + replay-bindings + trace (TRACE on),
//!   2. register a native `arena_replay_host` whose responders serve a tape,
//!   3. run a handler module through `arena_run_module`,
//!   4. capture console + the handler result WITHOUT access to the reactor's
//!      static `g_ctx` — via a sentinel `kv.set("__replay_output__", json)` that
//!      our kv_set responder intercepts (the side channel the real driver uses).
//!
//! If this runs and prints the captured output JSON, the whole native replay
//! design is sound and the real driver is just "decode a real RTAP tape + build
//! the real request epilogue + emit nicer JSON" on top of this skeleton.

const std = @import("std");

// ── arenajs native ABI (qjs-arena-reactor.c / -replay-bindings.{c,h}) ──────
extern fn arena_init(base_kb: c_int, request_kb: c_int) c_int;
extern fn arena_run_module(entry_name: [*c]const u8, entry_src: [*c]const u8) c_int;
extern fn arena_set_trace_mode(mode: c_int) void;
extern fn arena_set_date_now(lo: u32, hi: u32) void;
extern fn arena_set_random_seed(lo: u32, hi: u32) void;
extern fn arena_destroy() void;

const ReplayHost = extern struct {
    kv_get: ?*const fn ([*c]const u8, c_int, [*c]c_int, [*c][*c]u8, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    kv_set: ?*const fn ([*c]const u8, c_int, [*c]const u8, c_int, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    kv_delete: ?*const fn ([*c]const u8, c_int, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    kv_prefix: ?*const fn ([*c]const u8, c_int, [*c]const u8, c_int, c_int, [*c]c_int, [*c][*c]u8, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    module_load: ?*const fn ([*c]const u8, c_int, [*c][*c]u8, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
};
extern fn arena_replay_set_host(host: *const ReplayHost, user: ?*anyopaque) void;

// ── the "tape": a trivial in-memory kv map + a captured write-set ──────────
const KvPair = struct { key: []const u8, val: []const u8 };
var g_tape = [_]KvPair{
    .{ .key = "user", .val = "ada" },
};
// The captured write-set (including the sentinel output). Static so the C
// callbacks can reach it; the spike is single-shot.
var g_writes: std.ArrayList(KvPair) = .{};
var g_gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// malloc + copy matching the responder contract (engine free()s it). `nul`
/// appends a trailing NUL where the parser reads one sentinel byte past `len`.
fn dupC(bytes: []const u8, nul: bool) ?[*c]u8 {
    const n = bytes.len + @as(usize, if (nul) 1 else 0);
    const p: [*c]u8 = @ptrCast(std.c.malloc(n) orelse return null);
    @memcpy(p[0..bytes.len], bytes);
    if (nul) p[bytes.len] = 0;
    return p;
}

fn kvGet(
    key: [*c]const u8,
    key_len: c_int,
    out_outcome: [*c]c_int,
    out_val: [*c][*c]u8,
    out_val_len: [*c]c_int,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const k = key[0..@intCast(key_len)];
    for (g_tape) |e| {
        if (std.mem.eql(u8, e.key, k)) {
            out_val.* = dupC(e.val, false) orelse return -1;
            out_val_len.* = @intCast(e.val.len);
            out_outcome.* = 0; // ok
            return 0;
        }
    }
    out_outcome.* = 1; // not_found → kv.get() == null
    return 0;
}

fn kvSet(
    key: [*c]const u8,
    key_len: c_int,
    val: [*c]const u8,
    val_len: c_int,
    out_outcome: [*c]c_int,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const a = g_gpa.allocator();
    const k = a.dupe(u8, key[0..@intCast(key_len)]) catch return -1;
    const v = a.dupe(u8, val[0..@intCast(val_len)]) catch return -1;
    g_writes.append(a, .{ .key = k, .val = v }) catch return -1;
    out_outcome.* = 0; // ok
    return 0;
}

fn moduleLoad(
    spec: [*c]const u8,
    spec_len: c_int,
    _: [*c][*c]u8,
    _: [*c]c_int,
    _: ?*anyopaque,
) callconv(.c) c_int {
    _ = spec;
    _ = spec_len;
    return -5; // divergence: the spike handler imports nothing
}

// The handler under replay + the result-extraction epilogue. The epilogue
// defines console (arenajs has no quickjs-libc console natively), invokes the
// default export, and parks the run's output as a sentinel kv.set our responder
// captures — the side channel that dodges the reactor's static g_ctx.
const SRC =
    \\function handler() {
    \\  const u = kv.get('user');
    \\  kv.set('seen', u);
    \\  console.log('hello ' + u);
    \\  return { status: 200, body: 'hi ' + u };
    \\}
    \\export default handler;
    \\;(function () {
    \\  const __logs = [];
    \\  const sink = (...a) => __logs.push(a.map(String).join(' '));
    \\  globalThis.console = { log: sink, error: sink, warn: sink, info: sink };
    \\  globalThis.response = { status: 200, headers: {}, body: null };
    \\  let __result, __err = null;
    \\  try { __result = __arena_entry_ns().default(); }
    \\  catch (e) { __err = { message: String(e && e.message || e), stack: String(e && e.stack || '') }; }
    \\  kv.set('__replay_output__', JSON.stringify({
    \\    response: globalThis.response, result: __result, error: __err, console: __logs,
    \\  }));
    \\})();
;

pub fn main() !void {
    if (arena_init(8192, 8192) != 0) {
        std.debug.print("arena_init failed\n", .{});
        std.process.exit(1);
    }
    // One-shot: emit output, then exit and let the OS reclaim. We deliberately
    // do NOT call arena_destroy() — under the dual-arena allocator JS_FreeRuntime
    // trips a debug-only GC-accounting assert (the last run's objects are arena-
    // owned, not individually freed). A one-shot CLI has nothing to tear down.

    const host = ReplayHost{
        .kv_get = &kvGet,
        .kv_set = &kvSet,
        .kv_delete = null,
        .kv_prefix = null,
        .module_load = &moduleLoad,
    };
    arena_replay_set_host(&host, null);

    arena_set_date_now(0, 0);
    arena_set_random_seed(1, 0);
    arena_set_trace_mode(0); // SCAN/DRILL not needed for the output-capture proof

    const rc = arena_run_module("index.mjs", SRC);
    std.debug.print("arena_run_module rc={d}\n", .{rc});

    var found = false;
    for (g_writes.items) |w| {
        if (std.mem.eql(u8, w.key, "__replay_output__")) {
            std.debug.print("REPLAY_OUTPUT {s}\n", .{w.val});
            found = true;
        } else {
            std.debug.print("kv.set {s} = {s}\n", .{ w.key, w.val });
        }
    }
    if (!found) {
        std.debug.print("FAIL: no __replay_output__ captured\n", .{});
        std.process.exit(1);
    }
    std.debug.print("SPIKE OK\n", .{});
}
