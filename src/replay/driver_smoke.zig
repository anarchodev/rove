//! End-to-end native driver smoke (Phase 2 §2c). Drives `runWorld` — the ONE
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
    \\    ok: request.ok,
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
    try w.writeAll("\"status\":502,\"ok\":false,\"done\":true,\"fetchId\":\"ftch_1\",\"body\":\"boom\"},");
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
    try runInbound(a);
}
