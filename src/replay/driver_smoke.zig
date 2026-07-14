//! End-to-end native driver smoke. Drives `runWorld` — the ONE
//! replay/sim engine — over declarative worlds on the real arenajs link, no
//! cluster. Scenarios: an inbound request (kv.get + kv.set + console + response)
//! and a non-inbound `fetch_chunk` callback (ctx + flattened fetch result).
//! Asserts the emitted bundle reproduces the response, console, and write-set.
//!
//! `multi` argv proves the RESETTABLE runtime: three worlds run back-to-back in
//! ONE process (inbound user=ada → fetch_chunk → inbound user=bob) and each
//! bundle is correct AND isolated — run 3 sees `bob`, never the `ada` from run 1
//! (the request arena is wiped between runs). This is the `simulate()` primitive
//! the scenario driver + JS test runner fold over.
//! Build/run: `zig build replay-driver-smoke`.

const std = @import("std");
const root = @import("root.zig");

const HANDLER =
    \\export default function () {
    \\  const u = kv.get('user');
    \\  kv.set('seen', u);
    \\  console.log('hello ' + u);
    \\  return { status: 200, body: 'hi ' + u };
    \\}
;

const FETCH_HANDLER =
    \\export function onFetchResult() {
    \\  response.status = request.status;
    \\  return {
    \\    upstreamStatus: request.status,
    \\    done: request.done,
    \\    fetchId: request.fetchId,
    \\    ctxAttempt: request.ctx.attempt,
    \\    bodyLen: request.body.length,
    \\  };
    \\}
;

fn check(out: []const u8, need: []const []const u8, forbid: []const []const u8, label: []const u8) void {
    var ok = true;
    for (need) |n| if (std.mem.indexOf(u8, out, n) == null) {
        std.debug.print("{s} MISSING: {s}\n", .{ label, n });
        ok = false;
    };
    for (forbid) |f| if (std.mem.indexOf(u8, out, f) != null) {
        std.debug.print("{s} LEAKED (should be absent): {s}\n", .{ label, f });
        ok = false;
    };
    if (!ok) {
        std.debug.print("{s} FAIL\n", .{label});
        std.process.exit(1);
    }
    std.debug.print("{s} OK\n", .{label});
}

/// Run one inbound world for `user`. `forbid` asserts strings that must NOT
/// appear in this bundle — used by `multi` to prove a later run doesn't leak an
/// earlier run's KV through the (reset) request arena.
fn runInboundUser(a: std.mem.Allocator, user: []const u8, forbid: []const []const u8, label: []const u8) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/hello\",\"host\":\"ex.test\"},");
    try w.writeAll("\"kv\":{\"user\":");
    try std.json.Stringify.value(user, .{}, w);
    try w.writeAll("},\"seed\":42,");
    try w.writeAll("\"expected\":{\"response\":{\"status\":200}},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");

    var need_buf: [6][]const u8 = undefined;
    need_buf[0] = "\"verify\":{\"pass\":true";
    need_buf[1] = "\"kind\":\"write\"";
    need_buf[2] = "\"key\":\"seen\"";
    need_buf[3] = try std.fmt.allocPrint(a, "\"value\":\"{s}\"", .{user});
    need_buf[4] = try std.fmt.allocPrint(a, "hello {s}", .{user});
    need_buf[5] = "\"ok\":true";
    check(out.items, &need_buf, forbid, label);
}

fn runInbound(a: std.mem.Allocator) !void {
    try runInboundUser(a, "ada", &.{}, "DRIVER SMOKE");
}

fn runFetchChunk(a: std.mem.Allocator) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"fetch_chunk\",\"export\":\"onFetchResult\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"\",");
    try w.writeAll("\"status\":502,\"done\":true,\"fetchId\":\"ftch_1\",\"body\":\"boom\"},");
    try w.writeAll("\"ctx\":{\"attempt\":2},\"seed\":1,");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(FETCH_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("FETCH_CHUNK: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"upstreamStatus\":502", "\"ctxAttempt\":2", "\"bodyLen\":4",
        "\"done\":true", "\"ok\":true",
    }, &.{}, "FETCH_CHUNK SCENARIO");
}

/// Prove the resettable runtime: three worlds through ONE process. Run 3 must
/// see `bob` and NOT leak `ada` from run 1 — the request arena is wiped between
/// runs, so no KV / allocation crosses. This is the multi-shot `runWorld` the
/// scenario driver + JS test runner depend on.
fn runMulti(a: std.mem.Allocator) !void {
    try runInboundUser(a, "ada", &.{}, "MULTI run1 (inbound ada)");
    try runFetchChunk(a);
    try runInboundUser(a, "bob", &.{"ada"}, "MULTI run3 (inbound bob, no ada leak)");
    std.debug.print("MULTI OK — resettable runtime: 3 runs, 1 process, isolated\n", .{});
}

/// A handler whose CUMULATIVE allocation (~256 MiB) far exceeds the sim's
/// 100 MiB request arena while its peak live set stays ~1 MiB — it can only
/// complete because the GC arena reclaims the dead strings mid-run. Same shape
/// as prod's own bump/GC discriminator (`snap.zig`), the churn prod's bump→GC
/// retry absorbs; the sim runs GC always (issue #70), so it completes offline.
const CHURNY_HANDLER =
    \\export default function () {
    \\  let s = "";
    \\  for (let i = 0; i < 256; i++) { s = "x".repeat(1 << 20) + i; }
    \\  return "len=" + s.length;
    \\}
;

/// GC-always (issue #70): the churny handler completes under GC whether or
/// not the world carries the `arena_gc` regime stamp — the stamp no longer
/// gates the allocator mode — and a normal world afterwards still succeeds
/// (GC does not wedge or leak across the reactor's per-run resets).
fn runArenaGc(a: std.mem.Allocator) !void {
    // Stamped churny world: completes under GC.
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/churn\",\"host\":\"ex.test\"},");
    try w.writeAll("\"seed\":7,\"arena_gc\":true,");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(CHURNY_HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, &out);
    check(out.items, &.{"len=1048579"}, &.{}, "ARENA_GC (stamped churny world completes under GC)");

    // Same execution WITHOUT the stamp: also completes — GC is unconditional,
    // so an authored (unstamped) churny handler is no longer a false OOM.
    var world2 = std.ArrayList(u8){};
    var aw2 = std.Io.Writer.Allocating.fromArrayList(a, &world2);
    const w2 = &aw2.writer;
    try w2.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w2.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/churn\",\"host\":\"ex.test\"},");
    try w2.writeAll("\"seed\":7,");
    try w2.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(CHURNY_HANDLER, .{}, w2);
    try w2.writeAll("}]}");
    world2 = aw2.toArrayList();
    var out2 = std.ArrayList(u8){};
    try root.runWorld(a, world2.items, null, &out2);
    check(out2.items, &.{"len=1048579"}, &.{}, "ARENA_GC (unstamped churny world also completes under GC)");

    // And a normal world afterwards proves GC neither wedges nor leaks across runs.
    try runInboundUser(a, "eve", &.{}, "ARENA_GC (normal run after churn)");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Scenario selected by argv. `fetch` = the non-inbound callback; `multi` =
    // several worlds in ONE process (proves the resettable runtime); default =
    // the single inbound scenario.
    const args = try std.process.argsAlloc(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "fetch")) {
        try runFetchChunk(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "multi")) {
        try runMulti(a);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "arena-gc")) {
        try runArenaGc(a);
        return;
    }
    try runInbound(a);
}
