//! End-to-end native driver smoke (Phase 2 §2c). Drives `runWorld` — the ONE
//! replay/sim engine — over declarative worlds on the real arenajs link, no
//! cluster. Two scenarios (own process each; `runWorld` is one-shot): an inbound
//! request (kv.get + kv.set + console + response) and a non-inbound `fetch_chunk`
//! callback (ctx + flattened fetch result). Asserts the emitted bundle
//! reproduces the response, console, and write-set.
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

fn check(out: []const u8, need: []const []const u8, label: []const u8) void {
    var ok = true;
    for (need) |n| if (std.mem.indexOf(u8, out, n) == null) {
        std.debug.print("{s} MISSING: {s}\n", .{ label, n });
        ok = false;
    };
    if (!ok) {
        std.debug.print("{s} FAIL\n", .{label});
        std.process.exit(1);
    }
    std.debug.print("{s} OK\n", .{label});
}

fn runInbound(a: std.mem.Allocator) !void {
    var world = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &world);
    const w = &aw.writer;
    try w.writeAll("{\"entry\":\"index.mjs\",\"activation\":\"inbound\",");
    try w.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/hello\",\"host\":\"ex.test\"},");
    try w.writeAll("\"kv\":{\"user\":\"ada\"},\"seed\":42,");
    try w.writeAll("\"recorded\":{\"status\":200,\"console\":\"hello ada\",\"exception\":\"\"},");
    try w.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(HANDLER, .{}, w);
    try w.writeAll("}]}");
    world = aw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.runWorld(a, world.items, null, .fail, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"status_match\":true", "\"kind\":\"write\"", "\"key\":\"seen\"",
        "\"value\":\"ada\"", "hello ada", "\"ok\":true",
    }, "DRIVER SMOKE");
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
    try root.runWorld(a, world.items, null, .fail, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("FETCH_CHUNK: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");
    check(out.items, &.{
        "\"upstreamStatus\":502", "\"ctxAttempt\":2", "\"bodyLen\":4",
        "\"done\":true", "\"ok\":true",
    }, "FETCH_CHUNK SCENARIO");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // runWorld is one-shot (process-global arena_init), so each scenario runs in
    // its own process — selected by argv. `fetch` = the non-inbound scenario.
    const args = try std.process.argsAlloc(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "fetch")) {
        try runFetchChunk(a);
        return;
    }
    try runInbound(a);
}
