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

// ── fetch_chunk scenario: replay a callback (non-inbound) activation ──

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

fn b64(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}
fn chanHeader(buf: *std.ArrayList(u8), a: std.mem.Allocator, channel: u16, count: u32) !void {
    var h: [12]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], 0x52544150, .big);
    std.mem.writeInt(u16, h[4..6], 5, .big);
    std.mem.writeInt(u16, h[6..8], channel, .big);
    std.mem.writeInt(u32, h[8..12], count, .big);
    try buf.appendSlice(a, &h);
}
fn lp(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(s.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, s);
}
fn frame(buf: *std.ArrayList(u8), a: std.mem.Allocator, payload: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(payload.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, payload);
}
fn u(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime T: type, n: T) !void {
    var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &b, n, .big);
    try buf.appendSlice(a, &b);
}

/// fetch_responses tape: one terminal entry, status 502 ok, inline body "boom".
fn buildFetchTape(a: std.mem.Allocator) ![]u8 {
    var e = std.ArrayList(u8){};
    try lp(&e, a, "ftch_1"); // fetch_id
    try u(&e, a, u32, 0); // seq
    try u(&e, a, u64, 0); // byte_offset
    try u(&e, a, u64, 0); // batch_id = NO_BATCH
    try u(&e, a, u64, 0); // body_ref.offset
    try u(&e, a, u32, 4); // body_ref.len
    try e.append(a, 1); // final
    try u(&e, a, u16, 502); // status
    try e.append(a, 1); // ok
    try e.append(a, 0); // trunc
    try lp(&e, a, "{}"); // headers
    try lp(&e, a, "boom"); // inline_bytes
    var buf = std.ArrayList(u8){};
    try chanHeader(&buf, a, 2, 1); // channel fetch_responses
    try frame(&buf, a, e.items);
    return buf.toOwnedSlice(a);
}

/// trigger_payload tape: the threaded ctx envelope `{"ctx":{"attempt":2}}`.
fn buildTriggerTape(a: std.mem.Allocator) ![]u8 {
    var e = std.ArrayList(u8){};
    try u(&e, a, u64, 0); // batch_id = NO_BATCH
    try u(&e, a, u64, 0); // body_ref.offset
    try u(&e, a, u32, 0); // body_ref.len
    try lp(&e, a, "{\"ctx\":{\"attempt\":2}}");
    var buf = std.ArrayList(u8){};
    try chanHeader(&buf, a, 3, 1); // channel trigger_payload
    try frame(&buf, a, e.items);
    return buf.toOwnedSlice(a);
}

fn runFetchChunkScenario(a: std.mem.Allocator) !void {
    const fr_b64 = try b64(a, try buildFetchTape(a));
    const tp_b64 = try b64(a, try buildTriggerTape(a));

    var fixture = std.ArrayList(u8){};
    var faw = std.Io.Writer.Allocating.fromArrayList(a, &fixture);
    const fw = &faw.writer;
    try fw.writeAll("{\"request_id\":\"req_fc\",\"tenant\":\"smoke\",\"activation\":\"fetch_chunk\",\"entry\":\"index.mjs\",");
    try fw.writeAll("\"request\":{\"method\":\"GET\",\"path\":\"/\",\"host\":\"\"},");
    try fw.writeAll("\"recorded\":{\"status\":502,\"console\":\"\",\"exception\":\"\"},");
    try fw.writeAll("\"seed\":\"1\",\"timestamp_ns\":\"0\",");
    try fw.print("\"tapes\":{{\"fetch_responses_b64\":\"{s}\",\"trigger_payload_b64\":\"{s}\"}},", .{ fr_b64, tp_b64 });
    try fw.writeAll("\"sources\":[{\"path\":\"index.mjs\",\"kind\":\"handler\",\"source\":");
    try std.json.Stringify.value(FETCH_HANDLER, .{}, fw);
    try fw.writeAll("}]}");
    fixture = faw.toArrayList();

    var out = std.ArrayList(u8){};
    try root.run(a, fixture.items, null, &out);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("FETCH_CHUNK: ");
    try stdout.writeAll(out.items);
    try stdout.writeAll("\n");

    const need = [_][]const u8{
        "\"upstreamStatus\":502", // flattened request.status reached the handler
        "\"ctxAttempt\":2", // request.ctx threaded from trigger_payload
        "\"bodyLen\":4", // request.body = fetch result bytes "boom"
        "\"done\":true",
        "\"divergence\":null",
        "\"status_match\":true",
    };
    var ok = true;
    for (need) |n| if (std.mem.indexOf(u8, out.items, n) == null) {
        std.debug.print("FETCH_CHUNK MISSING: {s}\n", .{n});
        ok = false;
    };
    if (!ok) {
        std.debug.print("FETCH_CHUNK SCENARIO FAIL\n", .{});
        std.process.exit(1);
    }
    std.debug.print("FETCH_CHUNK SCENARIO OK\n", .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // root.run is one-shot (process-global arena_init), so each scenario runs in
    // its own process — selected by argv. `fetch` = the non-inbound replay.
    const args = try std.process.argsAlloc(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "fetch")) {
        try runFetchChunkScenario(a);
        return;
    }

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
