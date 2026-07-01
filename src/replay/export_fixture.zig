//! `export-fixture` — transcode a captured recording (the base64-tape fixture
//! `rewind pull` writes, which `rewind replay` consumes) into a **declarative
//! world** (the authored form `rewind sim` consumes). This is the bridge from
//! the replay corner to the sim corner: "what happened in prod" becomes an
//! editable, offline, fail-loud regression scenario
//! (`architecture/replay-and-sim.md` §6).
//!
//! A recording and an authored world are the same world, differently sourced
//! (§1), so this is a transcode, not a re-run. The non-obvious part is the KV
//! channel: the recording is an **ordered cursor** of reads (get/prefix +
//! outcome), but a declarative world is a **key→value map** + an explicit
//! absent set. The map seeds only the *initial* value per key (the first taped
//! read); read-modify-read is reproduced by the sim host's write-through
//! overlay, and recorded `not_found` reads become `kvAbsent` so a
//! `missPolicy:"fail"` sim reproduces the recording exactly — any *new* read
//! the original code never made then diverges (the regression-test sweet spot).
//!
//! Scope: faithful for `inbound` activations. The pulled fixture carries only
//! the kv / request_reads / request_body channels, so a non-inbound activation
//! (`fetch_chunk`/`onWake`/…) loses its ctx + fetch-result surface + resolved
//! export (`replay-and-sim.md` §5 G1/G3) — the caller is warned.

const std = @import("std");
const decode = @import("tape_decode.zig");

pub const Error = error{
    BadFixture,
    WriteFailed, // std.Io.Writer.Allocating sink surfaces OOM as WriteFailed
} || decode.Error || std.mem.Allocator.Error;

/// True when the pulled fixture's activation can be transcoded faithfully
/// (the inbound family — its whole input rides the decoded channels).
pub fn isInboundFamily(activation: []const u8) bool {
    return std.mem.eql(u8, activation, "inbound") or
        std.mem.eql(u8, activation, "inbound_headers");
}

/// Parse the activation field of a pulled fixture (for the caller's warning).
pub fn activationOf(a: std.mem.Allocator, fixture_json: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, fixture_json, .{}) catch return "inbound";
    if (parsed.value != .object) return "inbound";
    return jStr(parsed.value.object, "activation") orelse "inbound";
}

/// Transcode `fixture_json` (a `rewind pull` fixture) into a declarative world
/// JSON, written to `out`.
pub fn transcode(a: std.mem.Allocator, fixture_json: []const u8, out: *std.ArrayList(u8)) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, fixture_json, .{}) catch
        return Error.BadFixture;
    if (parsed.value != .object) return Error.BadFixture;
    const obj = parsed.value.object;

    const entry = jStr(obj, "entry") orelse "index.mjs";
    const activation = jStr(obj, "activation") orelse "inbound";
    const req = if (obj.get("request")) |v| (if (v == .object) v.object else null) else null;
    const method = if (req) |r| (jStr(r, "method") orelse "GET") else "GET";
    const path = if (req) |r| (jStr(r, "path") orelse "/") else "/";
    const host = if (req) |r| (jStr(r, "host") orelse "") else "";

    const export_name = jStr(obj, "export"); // recorded resolved export ({to}) — G3
    const recorded = if (obj.get("recorded")) |v| (if (v == .object) v.object else null) else null;

    const tapes = if (obj.get("tapes")) |v| (if (v == .object) v.object else null) else null;
    const kv_entries: []const decode.KvEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "kv_b64") else null;
        if (b64) |s| break :blk try decode.decodeKv(a, try b64decode(a, s));
        break :blk &.{};
    };
    const reads: []const decode.RequestReadEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "request_reads_b64") else null;
        if (b64) |s| break :blk try decode.decodeRequestReads(a, try b64decode(a, s));
        break :blk &.{};
    };
    const body_bytes: ?[]const u8 = blk: {
        const b64 = if (tapes) |t| jStr(t, "request_body_b64") else null;
        if (b64) |s| break :blk try b64decode(a, s);
        break :blk null;
    };
    const fetch_resp: []const decode.FetchResponseEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "fetch_responses_b64") else null;
        if (b64) |s| break :blk decode.decodeFetchResponses(a, try b64decode(a, s)) catch &.{};
        break :blk &.{};
    };
    const trigger: []const decode.TriggerPayloadEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "trigger_payload_b64") else null;
        if (b64) |s| break :blk decode.decodeTriggerPayload(a, try b64decode(a, s)) catch &.{};
        break :blk &.{};
    };
    const activation_bytes: ?[]const u8 = blk: {
        const b64 = if (tapes) |t| jStr(t, "activation_bytes_b64") else null;
        if (b64) |s| break :blk try b64decode(a, s);
        break :blk null;
    };
    const seed = jStr(obj, "seed");
    const ts_ns = jStr(obj, "timestamp_ns");

    // ── KV: get → initial-snapshot map / absent; prefix → both the map (for
    // later gets) AND kvPrefix (the exact recorded rows, for faithful scans) ──
    var seen = std.StringHashMapUnmanaged(void){};
    var kv = std.ArrayList(KvPair){};
    var absent = std.ArrayList([]const u8){};
    var prefixes = std.ArrayList(PrefixEntry){};
    for (kv_entries) |e| switch (e.op) {
        .get => {
            if (seen.contains(e.key)) continue; // re-read / post-write — overlay reproduces it
            try seen.put(a, e.key, {});
            switch (e.outcome) {
                .ok => try kv.append(a, .{ .key = e.key, .value = e.value }),
                .not_found => try absent.append(a, e.key),
                .err => {},
            }
        },
        .prefix => {
            try prefixes.append(a, .{ .prefix = e.key, .rows = e.results });
            for (e.results) |row| {
                if (seen.contains(row.key)) continue;
                try seen.put(a, row.key, {});
                try kv.append(a, .{ .key = row.key, .value = row.value });
            }
        },
        .set, .delete => {},
    };

    // ── request surface: request_reads ──
    var headers = std.ArrayList(decode.RequestReadEntry){};
    var ip: ?[]const u8 = null;
    var body_read = body_bytes != null;
    for (reads) |r| switch (r.kind) {
        .header_value => try headers.append(a, r),
        .body_read => body_read = true,
        .ip_masked => ip = r.value,
        .header_names, .ip_raw => {},
    };

    // ── fetch result (fetch_chunk): status/ok/done/fetchId + the body ──
    var fetch_status: ?u16 = null;
    var fetch_ok: ?bool = null;
    var fetch_done: ?bool = null;
    var fetch_id: ?[]const u8 = null;
    var fetch_body: ?[]const u8 = null;
    if (fetch_resp.len != 0) {
        var body = std.ArrayList(u8){};
        for (fetch_resp) |e| try body.appendSlice(a, e.inline_bytes);
        fetch_body = body.items;
        const last = fetch_resp[fetch_resp.len - 1];
        fetch_id = last.fetch_id;
        fetch_done = last.final;
        if (last.final) {
            fetch_status = last.terminal_status;
            fetch_ok = last.terminal_ok;
        }
    }
    // request.body: the fetch result body (fetch_chunk) else the inbound body.
    const eff_body: ?[]const u8 = fetch_body orelse body_bytes;
    const eff_body_present = fetch_body != null or body_read;

    // ── ctx (from the trigger_payload `{"ctx": …}` envelope) ──
    const ctx_json: ?[]const u8 = blk: {
        if (trigger.len != 0 and trigger[0].batch_id == decode.NO_BATCH and trigger[0].inline_bytes.len != 0)
            break :blk extractCtx(a, trigger[0].inline_bytes);
        break :blk null;
    };

    // ── ws_message frame: activation_bytes = [opcode][data] ──
    var ws_opcode: ?u8 = null;
    var ws_data: ?[]const u8 = null;
    if (std.mem.eql(u8, activation, "ws_message")) {
        if (activation_bytes) |ab| if (ab.len >= 1) {
            ws_opcode = ab[0];
            ws_data = ab[1..];
        };
    }

    // ── emit the world ──
    var aw = std.Io.Writer.Allocating.fromArrayList(a, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;

    try w.writeAll("{\n  \"entry\": ");
    try jsonStr(w, entry);
    try w.writeAll(",\n  \"activation\": ");
    try jsonStr(w, activation);
    if (export_name) |e| {
        try w.writeAll(",\n  \"export\": ");
        try jsonStr(w, e);
    }
    try w.writeAll(",\n  \"missPolicy\": \"fail\",\n  \"request\": {\n    \"method\": ");
    try jsonStr(w, method);
    try w.writeAll(", \"path\": ");
    try jsonStr(w, path);
    try w.writeAll(", \"host\": ");
    try jsonStr(w, host);
    if (headers.items.len != 0) {
        try w.writeAll(",\n    \"headers\": {");
        for (headers.items, 0..) |h, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(" ");
            try jsonStr(w, h.name);
            try w.writeAll(": ");
            try jsonStr(w, h.value);
        }
        try w.writeAll(" }");
    }
    if (eff_body_present) {
        try w.writeAll(",\n    \"body\": ");
        try jsonStr(w, eff_body orelse "");
    }
    if (ip) |v| {
        try w.writeAll(",\n    \"ip\": ");
        try jsonStr(w, v);
    }
    // flattened fetch-result surface (fetch_chunk)
    if (fetch_status) |s| try w.print(",\n    \"status\": {d}", .{s});
    if (fetch_ok) |b| try w.writeAll(if (b) ",\n    \"ok\": true" else ",\n    \"ok\": false");
    if (fetch_done) |b| try w.writeAll(if (b) ",\n    \"done\": true" else ",\n    \"done\": false");
    if (fetch_id) |id| {
        try w.writeAll(",\n    \"fetchId\": ");
        try jsonStr(w, id);
    }
    // ws frame → request.activation {opcode, data | dataB64}
    if (ws_opcode) |op| {
        try w.print(",\n    \"activation\": {{ \"opcode\": {d}, ", .{op});
        if (op == 2) { // binary → base64 (Uint8Array)
            try w.writeAll("\"dataB64\": ");
            try jsonB64(a, w, ws_data orelse "");
        } else {
            try w.writeAll("\"data\": ");
            try jsonStr(w, ws_data orelse "");
        }
        try w.writeAll(" }");
    }
    try w.writeAll("\n  }");
    if (ctx_json) |cj| {
        try w.writeAll(",\n  \"ctx\": ");
        try w.writeAll(cj);
    }
    try w.writeAll(",\n  \"kv\": {");
    for (kv.items, 0..) |p, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("\n    ");
        try jsonStr(w, p.key);
        try w.writeAll(": ");
        try jsonStr(w, p.value);
    }
    try w.writeAll(if (kv.items.len != 0) "\n  }" else "}");
    if (absent.items.len != 0) {
        try w.writeAll(",\n  \"kvAbsent\": [");
        for (absent.items, 0..) |k, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(" ");
            try jsonStr(w, k);
        }
        try w.writeAll(" ]");
    }
    if (prefixes.items.len != 0) {
        try w.writeAll(",\n  \"kvPrefix\": {");
        for (prefixes.items, 0..) |pe, pi| {
            if (pi != 0) try w.writeByte(',');
            try w.writeAll("\n    ");
            try jsonStr(w, pe.prefix);
            try w.writeAll(": [");
            for (pe.rows, 0..) |row, ri| {
                if (ri != 0) try w.writeByte(',');
                try w.writeAll("{\"key\": ");
                try jsonStr(w, row.key);
                try w.writeAll(", \"value\": ");
                try jsonStr(w, row.value);
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeAll("\n  }");
    }
    if (recorded) |r| {
        try w.writeAll(",\n  \"recorded\": {\"status\": ");
        if (r.get("status")) |sv| (if (sv == .integer) try w.print("{d}", .{sv.integer}) else try w.writeAll("null")) else try w.writeAll("null");
        try w.writeAll(", \"console\": ");
        try jsonStr(w, jStr(r, "console") orelse "");
        try w.writeAll(", \"exception\": ");
        try jsonStr(w, jStr(r, "exception") orelse "");
        try w.writeByte('}');
    }
    if (seed) |s| {
        const n = std.fmt.parseInt(u64, s, 10) catch 0;
        try w.print(",\n  \"seed\": {d}", .{n});
    }
    if (ts_ns) |s| {
        const ns = std.fmt.parseInt(i64, s, 10) catch 0;
        if (ns > 0) try w.print(",\n  \"now_ms\": {d}", .{@divTrunc(ns, std.time.ns_per_ms)});
    }
    // sources: pass through verbatim so the world is self-contained.
    if (obj.get("sources")) |sv| {
        try w.writeAll(",\n  \"sources\": ");
        try std.json.Stringify.value(sv, .{}, w);
    }
    try w.writeAll("\n}\n");
}

const PrefixEntry = struct { prefix: []const u8, rows: []const decode.KvPair };

/// Extract the threaded ctx from a trigger_payload `{"ctx": <value>}` envelope —
/// the inner value re-serialised as JSON text (→ `world.ctx`). null when not a
/// ctx envelope.
fn extractCtx(a: std.mem.Allocator, envelope: []const u8) ?[]const u8 {
    const p = std.json.parseFromSlice(std.json.Value, a, envelope, .{}) catch return null;
    if (p.value != .object) return null;
    const c = p.value.object.get("ctx") orelse return null;
    return std.json.Stringify.valueAlloc(a, c, .{}) catch null;
}

fn jsonB64(a: std.mem.Allocator, w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(buf);
    _ = enc.encode(buf, bytes);
    try jsonStr(w, buf);
}

const KvPair = struct { key: []const u8, value: []const u8 };

fn jStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn b64decode(a: std.mem.Allocator, s: []const u8) Error![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return Error.BadFixture;
    const buf = try a.alloc(u8, n);
    dec.decode(buf, s) catch return Error.BadFixture;
    return buf;
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a base64 kv tape with the given entries (mirrors the encodeEntry
/// format `tape_decode` reads), for a round-trip test.
fn b64KvTape(a: std.mem.Allocator, entries: []const decode.KvEntry) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], decode.MAGIC, .big);
    std.mem.writeInt(u16, hdr[4..6], decode.VERSION, .big);
    std.mem.writeInt(u16, hdr[6..8], @intFromEnum(decode.Channel.kv), .big);
    std.mem.writeInt(u32, hdr[8..12], @intCast(entries.len), .big);
    try buf.appendSlice(a, &hdr);
    for (entries) |e| {
        var ent = std.ArrayList(u8){};
        defer ent.deinit(a);
        try ent.append(a, @intFromEnum(e.op));
        try ent.append(a, @intFromEnum(e.outcome));
        try putLen(&ent, a, e.key);
        try putLen(&ent, a, e.value);
        var l: [4]u8 = undefined;
        std.mem.writeInt(u32, &l, @intCast(ent.items.len), .big);
        try buf.appendSlice(a, &l);
        try buf.appendSlice(a, ent.items);
    }
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(buf.items.len));
    _ = enc.encode(out, buf.items);
    return out;
}
fn putLen(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(s.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, s);
}

test "transcode: kv reads → map + kvAbsent; not-found becomes absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kv_b64 = try b64KvTape(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "user/jess", .value = "{\"n\":1}" },
        .{ .op = .get, .outcome = .not_found, .key = "user/ghost" },
        .{ .op = .get, .outcome = .ok, .key = "user/jess", .value = "{\"n\":2}" }, // re-read → skipped
    });
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"inbound",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "seed":"42", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "kv_b64":"{s}" }}, "sources":[] }}
    , .{kv_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    // round-trip-parse the emitted world and assert the transcode
    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wo = wp.value.object;
    try testing.expectEqualStrings("fail", wo.get("missPolicy").?.string);
    // kv: the FIRST value for user/jess, not the re-read
    const kvm = wo.get("kv").?.object;
    try testing.expectEqualStrings("{\"n\":1}", kvm.get("user/jess").?.string);
    try testing.expect(kvm.get("user/ghost") == null);
    // kvAbsent holds the not-found read
    const ka = wo.get("kvAbsent").?.array;
    try testing.expectEqual(@as(usize, 1), ka.items.len);
    try testing.expectEqualStrings("user/ghost", ka.items[0].string);
    try testing.expectEqual(@as(i64, 42), wo.get("seed").?.integer);
    try testing.expectEqual(@as(i64, 1700000000000), wo.get("now_ms").?.integer);
}

test "isInboundFamily" {
    try testing.expect(isInboundFamily("inbound"));
    try testing.expect(isInboundFamily("inbound_headers"));
    try testing.expect(!isInboundFamily("fetch_chunk"));
    try testing.expect(!isInboundFamily("wake_batch"));
}
