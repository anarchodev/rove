//! End-to-end native driver smoke (Phase 2 §2c). Builds an in-memory fixture
//! (a handler that does kv.get + kv.set + console.log + returns a response, plus
//! a one-entry kv read tape), runs the full `root.run` path, and asserts the
//! emitted LLM-JSON reproduces the response, the captured console, and the
//! produced write-set. Proves decode → host cursor → epilogue → extraction on
//! the real engine, without a live cluster. Build/run: `zig build replay-driver-smoke`.

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

/// Build one `.kv` channel tape with a single `get "user" ok "ada"` entry, in
/// the exact RTAP wire format `src/tape/root.zig` `Tape.serialize` produces.
fn buildKvTape(a: std.mem.Allocator) ![]u8 {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0x52544150, .big); // MAGIC
    std.mem.writeInt(u16, hdr[4..6], 5, .big); // VERSION
    std.mem.writeInt(u16, hdr[6..8], 0, .big); // channel kv
    std.mem.writeInt(u32, hdr[8..12], 1, .big); // count
    // entry payload: op=get(0), outcome=ok(0), [len key][len value]
    var e = std.ArrayList(u8){};
    try e.append(a, 0); // get
    try e.append(a, 0); // ok
    var l4: [4]u8 = undefined;
    std.mem.writeInt(u32, &l4, 4, .big);
    try e.appendSlice(a, &l4);
    try e.appendSlice(a, "user");
    std.mem.writeInt(u32, &l4, 3, .big);
    try e.appendSlice(a, &l4);
    try e.appendSlice(a, "ada");
    // assemble: header + [len][payload]
    var buf = std.ArrayList(u8){};
    try buf.appendSlice(a, &hdr);
    std.mem.writeInt(u32, &l4, @intCast(e.items.len), .big);
    try buf.appendSlice(a, &l4);
    try buf.appendSlice(a, e.items);
    return buf.toOwnedSlice(a);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kv_tape = try buildKvTape(a);
    const enc = std.base64.standard.Encoder;
    const kv_b64 = try a.alloc(u8, enc.calcSize(kv_tape.len));
    _ = enc.encode(kv_b64, kv_tape);

    // Assemble the fixture exactly as `rewind pull` will write it.
    var fixture = std.ArrayList(u8){};
    var faw = std.Io.Writer.Allocating.fromArrayList(a, &fixture);
    const fw = &faw.writer;
    try fw.writeAll("{\"request_id\":\"req_deadbeef\",\"tenant\":\"smoke\",\"activation\":\"inbound\",\"entry\":\"index.mjs\",");
    try fw.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/hello\",\"host\":\"ex.test\"},");
    try fw.writeAll("\"recorded\":{\"status\":200,\"console\":\"hello ada\",\"exception\":\"\"},");
    try fw.writeAll("\"seed\":\"42\",\"timestamp_ns\":\"1700000000000000000\",\"js_engine_version\":1,");
    try fw.print("\"tapes\":{{\"kv_b64\":\"{s}\"}},", .{kv_b64});
    try fw.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(HANDLER, .{}, fw); // JS source as a JSON string
    try fw.writeAll("}]}");
    fixture = faw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.run(a, fixture.items, null, &out);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");

    // Assertions — fail loud if the artifact regresses.
    const j = out.items;
    const need = [_][]const u8{
        "\"status_match\":true",
        "\"op\":\"set\"",
        "\"key\":\"seen\"",
        "\"value\":\"ada\"",
        "hello ada", // captured console
        "\"divergence\":null",
    };
    var ok = true;
    for (need) |n| {
        if (std.mem.indexOf(u8, j, n) == null) {
            std.debug.print("MISSING: {s}\n", .{n});
            ok = false;
        }
    }
    if (!ok) {
        std.debug.print("DRIVER SMOKE FAIL\n", .{});
        std.process.exit(1);
    }
    std.debug.print("DRIVER SMOKE OK\n", .{});
}
