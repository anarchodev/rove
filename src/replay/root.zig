//! The ONE replay/sim engine — `runWorld(world, code)`. Both `rewind replay`
//! and `rewind sim` call it over the SAME declarative `world.json` (`world.zig`):
//! the request surface, a **closed-world** key→value KV map, ctx, the flattened
//! fetch/callback result, the resolved export, seed, and optionally the
//! `recorded` output. KV reads resolve BY KEY with a write-through overlay
//! (order-independent — `replay-and-sim.md` §1); a key not in the map is
//! `not_found`, never a divergence. Faithfulness is the output-level
//! `status_match` + the ordered effect log, not a per-read check. It emits one
//! LLM-JSON bundle: the response head, disposition, body/ctx, the ordered
//! `effects`, and the recorded comparison. No Node/WASM/network — the arenajs
//! engine is linked in.
//!
//! `runWorld` is one-shot: arena_init installs process-global engine state, so a
//! CLI invocation runs exactly one activation (which is the whole use case).
//! The base64-tape → world transcode lives in `export_fixture.zig` (used by
//! `pull` online + `export-fixture` offline). The old ordered-cursor `run` +
//! its `.tape` host mode are retired — resolution is by-key.

const std = @import("std");
const decode = @import("tape_decode.zig");
const hostmod = @import("host.zig");
const epilogue = @import("epilogue.zig");
const world = @import("world.zig");
const export_fixture = @import("export_fixture.zig");

/// Transcode a captured record (base64 tapes) into the declarative `world.json`
/// — the ONE format `replay`/`sim` consume. Used by `pull` (online) and the
/// `export-fixture` verb (offline).
pub const exportFixture = export_fixture.transcode;
pub const exportFixtureActivation = export_fixture.activationOf;
pub const exportFixtureIsInbound = export_fixture.isInboundFamily;

// ── arenajs native ABI (qjs-arena-reactor.c) ──
extern fn arena_init(base_kb: c_int, request_kb: c_int) c_int;
extern fn arena_run_module(entry_name: [*c]const u8, entry_src: [*c]const u8) c_int;
extern fn arena_set_trace_mode(mode: c_int) void;
extern fn arena_set_date_now(lo: u32, hi: u32) void;
extern fn arena_set_random_seed(lo: u32, hi: u32) void;

pub const Error = error{
    BadFixture,
    EntrySourceMissing,
    ArenaInit,
    NoOutput,
    WriteFailed, // std.Io.Writer.Allocating sink (OOM surfaced as WriteFailed)
} || decode.Error || std.mem.Allocator.Error;


/// Run a **declarative** world (an *authored* fixture, not a captured tape) —
/// the one engine. KV reads resolve order-independently against the world's
/// key→value map — a **closed world**: a key not in the map is `not_found`
/// (never a divergence). Faithfulness lives at the output (`status_match`) + the
/// effect log, not per-read. The request surface is rebuilt by synthesizing
/// `request_reads` entries from the declared request, so the SAME epilogue
/// serves it — undeclared header reads are naturally `undefined`.
pub fn runWorld(
    a: std.mem.Allocator,
    world_json: []const u8,
    source_dir: ?[]const u8,
    out: *std.ArrayList(u8),
) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, world_json, .{}) catch
        return Error.BadFixture;
    const wv = world.fromValue(a, parsed.value) catch return Error.BadFixture;

    // ── synthesize request_reads from the declared request ──
    var reads = std.ArrayList(decode.RequestReadEntry){};
    // header_names: a JSON array of the declared header names.
    var names_buf = std.ArrayList(u8){};
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &names_buf);
        const w = &aw.writer;
        try w.writeByte('[');
        for (wv.headers, 0..) |hh, i| {
            if (i != 0) try w.writeByte(',');
            try jsonStr(w, hh.name);
        }
        try w.writeByte(']');
        names_buf = aw.toArrayList();
    }
    try reads.append(a, .{ .kind = .header_names, .name = "", .value = names_buf.items });
    for (wv.headers) |hh|
        try reads.append(a, .{ .kind = .header_value, .name = hh.name, .value = hh.value });
    if (wv.body != null)
        try reads.append(a, .{ .kind = .body_read, .name = "", .value = "" });
    if (wv.ip) |ip|
        try reads.append(a, .{ .kind = .ip_masked, .name = "", .value = ip });

    // ── kv readset → map (+ the explicitly-absent set) ──
    var kv_map = std.StringHashMapUnmanaged([]const u8){};
    for (wv.kv) |p| try kv_map.put(a, p.key, p.value);

    // ── module sources (inline) ──
    var sources = std.StringHashMapUnmanaged([]const u8){};
    for (wv.sources) |s| {
        if (!std.mem.eql(u8, s.kind, "handler")) continue;
        try sources.put(a, s.path, s.source);
    }

    // Entry source: working tree (if --source-dir) else the inline world.
    const entry_src = blk: {
        if (source_dir) |dir| {
            const ep = std.fs.path.join(a, &.{ dir, wv.entry }) catch return Error.OutOfMemory;
            break :blk std.fs.cwd().readFileAlloc(a, ep, 8 << 20) catch
                return Error.EntrySourceMissing;
        }
        break :blk sources.get(wv.entry) orelse return Error.EntrySourceMissing;
    };

    const binary_body = std.mem.eql(u8, wv.activation, "inbound_chunk") or
        std.mem.eql(u8, wv.activation, "fetch_chunk");
    // The resolved export: the world's explicit `export` (the `{to}` / resolved
    // name a callback needs) wins; else the conventional export for the kind.
    const export_name = wv.export_name orelse epilogue.exportForActivation(wv.activation);
    const result: ?epilogue.Result = if (wv.status != null or wv.ok != null or
        wv.done != null or wv.fetch_id != null or wv.chunk_seq != null)
        .{ .status = wv.status, .ok = wv.ok, .done = wv.done, .fetch_id = wv.fetch_id, .chunk_seq = wv.chunk_seq }
    else
        null;
    const epi = try epilogue.build(a, .{
        .method = wv.method,
        .path = wv.path,
        .host = wv.host,
        .request_reads = reads.items,
        .body_bytes = wv.body,
        .export_name = export_name,
        .binary_body = binary_body,
        .ctx_json = wv.ctx_json,
        .activation_json = wv.activation_json,
        .result = result,
    });
    const full_src = try std.mem.concatWithSentinel(a, u8, &.{ entry_src, epi }, 0);
    const entry_z = try a.dupeZ(u8, wv.entry);

    // ── drive the engine (one-shot; same caveats as `run`) ──
    if (arena_init(8192, 8192) != 0) return Error.ArenaInit;
    var host = hostmod.Host{
        .a = a,
        .mode = .map,
        .kv = &.{},
        .kv_map = kv_map,
        .sources = sources,
        .source_dir = source_dir,
    };
    host.install();

    const date_ms: u64 = wv.now_ms;
    arena_set_random_seed(@truncate(wv.seed), @truncate(wv.seed >> 32));
    arena_set_date_now(@truncate(date_ms), @truncate(date_ms >> 32));
    arena_set_trace_mode(0);

    const rc = arena_run_module(entry_z.ptr, full_src.ptr);

    try emitWorld(a, out, .{
        .entry = wv.entry,
        .activation = wv.activation,
        .export_name = export_name,
        .rc = rc,
        .divergence = host.diverged,
        .writes = host.writes.items,
        .run_json = host.output,
    });

    // Optional `expected` → append a `verify` result (partial, order-independent
    // match over the bundle). Present ⇒ this is a test/replay assertion; absent
    // ⇒ plain sim (bundle only).
    if (wv.expected_json) |ej| appendVerify(a, out, ej) catch {};
}

/// Partial, order-independent matcher: for each facet the `expected` object
/// declares, check the produced bundle satisfies it. Splices
/// `,"verify":{"pass":…,"failures":[…]}` before the bundle's closing `}`. A
/// facet the expected doesn't mention is not checked ("at least these hold").
fn appendVerify(a: std.mem.Allocator, out: *std.ArrayList(u8), expected_json: []const u8) !void {
    const bp = std.json.parseFromSlice(std.json.Value, a, out.items, .{}) catch return;
    if (bp.value != .object) return;
    const bundle = bp.value.object;
    const ep = std.json.parseFromSlice(std.json.Value, a, expected_json, .{}) catch return;
    if (ep.value != .object) return;
    const exp = ep.value.object;

    var fails = std.ArrayList(u8){};
    var fw = std.Io.Writer.Allocating.fromArrayList(a, &fails);
    const w = &fw.writer;
    try w.writeByte('[');
    var nf: usize = 0;

    // response — subset match against bundle.response
    if (exp.get("response")) |rv| if (rv == .object) {
        const br: ?std.json.ObjectMap = if (bundle.get("response")) |b| (if (b == .object) b.object else null) else null;
        var it = rv.object.iterator();
        while (it.next()) |e| {
            const got: ?std.json.Value = if (br) |b| b.get(e.key_ptr.*) else null;
            if (got == null or !valEq(a, got.?, e.value_ptr.*))
                nf = try emitFail(a, w, nf, "response", e.value_ptr.*, got);
        }
    };
    // disposition / body — direct compare
    if (exp.get("disposition")) |dv| {
        const got = bundle.get("disposition");
        if (got == null or !valEq(a, got.?, dv)) nf = try emitFail(a, w, nf, "disposition", dv, got);
    }
    if (exp.get("body")) |bv| {
        const got = bundle.get("body");
        if (got == null or !valEq(a, got.?, bv)) nf = try emitFail(a, w, nf, "body", bv, got);
    }

    // writes / cmds — must be PRESENT somewhere in the effect log (order-free)
    const effects: []const std.json.Value = if (bundle.get("effects")) |ev|
        (if (ev == .array) ev.array.items else &.{})
    else
        &.{};
    if (exp.get("writes")) |wv| if (wv == .array) {
        for (wv.array.items) |want|
            if (!matchWrite(a, effects, want)) {
                nf = try emitFail(a, w, nf, "writes", want, null);
            };
    };
    if (exp.get("cmds")) |cv| if (cv == .array) {
        for (cv.array.items) |want|
            if (!matchCmd(a, effects, want)) {
                nf = try emitFail(a, w, nf, "cmds", want, null);
            };
    };

    try w.writeByte(']');
    fails = fw.toArrayList();

    // splice before the bundle's trailing `}`
    var end = out.items.len;
    while (end > 0 and (out.items[end - 1] == '\n' or out.items[end - 1] == ' ')) end -= 1;
    if (end == 0 or out.items[end - 1] != '}') return;
    var no = std.ArrayList(u8){};
    try no.appendSlice(a, out.items[0 .. end - 1]);
    try no.appendSlice(a, ",\"verify\":{\"pass\":");
    try no.appendSlice(a, if (nf == 0) "true" else "false");
    try no.appendSlice(a, ",\"failures\":");
    try no.appendSlice(a, fails.items);
    try no.appendSlice(a, "}}");
    out.* = no;
}

/// Deep value equality via canonical JSON text (fine for scalars/strings — the
/// common `expected` shape; objects compare by serialized form).
fn valEq(a: std.mem.Allocator, x: std.json.Value, y: std.json.Value) bool {
    const sx = std.json.Stringify.valueAlloc(a, x, .{}) catch return false;
    const sy = std.json.Stringify.valueAlloc(a, y, .{}) catch return false;
    return std.mem.eql(u8, sx, sy);
}

fn emitFail(a: std.mem.Allocator, w: *std.Io.Writer, nf: usize, facet: []const u8, want: std.json.Value, got: ?std.json.Value) !usize {
    _ = a;
    if (nf != 0) try w.writeByte(',');
    try w.writeAll("{\"facet\":");
    try jsonStr(w, facet);
    try w.writeAll(",\"want\":");
    try std.json.Stringify.value(want, .{}, w);
    if (got) |g| {
        try w.writeAll(",\"got\":");
        try std.json.Stringify.value(g, .{}, w);
    }
    try w.writeByte('}');
    return nf + 1;
}

/// A `write` expectation `{key, value?}` must match some `{kind:"write"}` effect.
fn matchWrite(a: std.mem.Allocator, effects: []const std.json.Value, want: std.json.Value) bool {
    if (want != .object) return false;
    for (effects) |e| {
        if (e != .object) continue;
        const kind = e.object.get("kind") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "write")) continue;
        if (want.object.get("key")) |wk| {
            const ek = e.object.get("key") orelse continue;
            if (!valEq(a, ek, wk)) continue;
        }
        if (want.object.get("value")) |wvv| {
            const ev = e.object.get("value") orelse continue;
            if (!valEq(a, ev, wvv)) continue;
        }
        return true;
    }
    return false;
}

/// A `cmd` expectation `{kind, url?, to?}` must match some effect of that kind.
fn matchCmd(a: std.mem.Allocator, effects: []const std.json.Value, want: std.json.Value) bool {
    if (want != .object) return false;
    for (effects) |e| {
        if (e != .object) continue;
        const kind = e.object.get("kind") orelse continue;
        if (want.object.get("kind")) |wk| {
            if (!valEq(a, kind, wk)) continue;
        }
        if (want.object.get("url")) |wu| {
            const eu = e.object.get("url") orelse continue;
            if (!valEq(a, eu, wu)) continue;
        }
        if (want.object.get("to")) |wt| {
            const et = e.object.get("to") orelse continue;
            if (!valEq(a, et, wt)) continue;
        }
        return true;
    }
    return false;
}

// ── `--update`: snapshot the produced bundle's facets as `expected` and write
// it back into the world file (golden regen; overwrites any existing expected) ──

pub fn updateExpected(a: std.mem.Allocator, world_path: []const u8, bundle_json: []const u8) !void {
    var es = std.ArrayList(u8){};
    {
        var ew = std.Io.Writer.Allocating.fromArrayList(a, &es);
        try buildExpected(a, &ew.writer, bundle_json);
        es = ew.toArrayList();
    }
    const ep = std.json.parseFromSlice(std.json.Value, a, es.items, .{}) catch return Error.BadFixture;
    const wbytes = try std.fs.cwd().readFileAlloc(a, world_path, 64 << 20);
    var wp = std.json.parseFromSlice(std.json.Value, a, wbytes, .{}) catch return Error.BadFixture;
    if (wp.value != .object) return Error.BadFixture;
    try wp.value.object.put("expected", ep.value);
    var out = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &out);
    try std.json.Stringify.value(wp.value, .{ .whitespace = .indent_2 }, &aw.writer);
    out = aw.toArrayList();
    try std.fs.cwd().writeFile(.{ .sub_path = world_path, .data = out.items });
}

/// Project the produced bundle → an `expected` object: response.status,
/// disposition, and the writes / cmds from the effect log.
fn buildExpected(a: std.mem.Allocator, w: *std.Io.Writer, bundle_json: []const u8) !void {
    const bp = std.json.parseFromSlice(std.json.Value, a, bundle_json, .{}) catch {
        try w.writeAll("{}");
        return;
    };
    if (bp.value != .object) {
        try w.writeAll("{}");
        return;
    }
    const b = bp.value.object;

    try w.writeAll("{\"response\":{\"status\":");
    const status: ?std.json.Value = blk: {
        if (b.get("response")) |rv| if (rv == .object) if (rv.object.get("status")) |sv| break :blk sv;
        break :blk null;
    };
    if (status) |s| try std.json.Stringify.value(s, .{}, w) else try w.writeAll("null");
    try w.writeByte('}');
    if (b.get("disposition")) |dv| {
        try w.writeAll(",\"disposition\":");
        try std.json.Stringify.value(dv, .{}, w);
    }

    const effects: []const std.json.Value = if (b.get("effects")) |ev|
        (if (ev == .array) ev.array.items else &.{})
    else
        &.{};
    try w.writeAll(",\"writes\":[");
    var nw: usize = 0;
    for (effects) |e| {
        if (e != .object) continue;
        const kind = e.object.get("kind") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "write")) continue;
        if (nw != 0) try w.writeByte(',');
        nw += 1;
        try w.writeAll("{\"key\":");
        try std.json.Stringify.value(e.object.get("key") orelse .null, .{}, w);
        if (e.object.get("value")) |v| {
            try w.writeAll(",\"value\":");
            try std.json.Stringify.value(v, .{}, w);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
    try w.writeAll(",\"cmds\":[");
    var nc: usize = 0;
    for (effects) |e| {
        if (e != .object) continue;
        const kind = e.object.get("kind") orelse continue;
        if (kind != .string or !isCmdKind(kind.string)) continue;
        if (nc != 0) try w.writeByte(',');
        nc += 1;
        try w.writeAll("{\"kind\":");
        try std.json.Stringify.value(kind, .{}, w);
        if (e.object.get("url")) |u| {
            try w.writeAll(",\"url\":");
            try std.json.Stringify.value(u, .{}, w);
        }
        if (e.object.get("to")) |t| if (t != .null) {
            try w.writeAll(",\"to\":");
            try std.json.Stringify.value(t, .{}, w);
        };
        try w.writeByte('}');
    }
    try w.writeByte(']');
    try w.writeByte('}');
}

fn isCmdKind(k: []const u8) bool {
    const kinds = [_][]const u8{ "fetch", "webhook", "email", "schedule", "cron", "timer", "kv-wake", "stream" };
    for (kinds) |c| if (std.mem.eql(u8, k, c)) return true;
    return false;
}

// ── emit helpers ──

const EmitWorldArgs = struct {
    entry: []const u8,
    activation: []const u8,
    export_name: []const u8,
    rc: c_int,
    divergence: ?[]const u8,
    writes: []const hostmod.KvWrite,
    /// The run's parked output (response/result/error/console), or null when the
    /// run died before the epilogue captured it (e.g. a syntax error).
    run_json: ?[]const u8,
};

/// Emit a sim bundle. Same engine output as `emit`, minus the recorded-vs-
/// replayed comparison (an authored world has no recording to match), plus the
/// `miss_policy` it ran under and the typed `holes` a `resolve` run filled.
fn emitWorld(a: std.mem.Allocator, out: *std.ArrayList(u8), args: EmitWorldArgs) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(a, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;

    // Parse the JS run output so we can flatten it to the clean effect-log shape
    // (one `response` head + `disposition` + an ordered `effects` list) instead
    // of leaking the raw response/result/effects nesting.
    var run: ?std.json.ObjectMap = null;
    if (args.run_json) |rj| {
        const p = std.json.parseFromSlice(std.json.Value, a, rj, .{}) catch null;
        if (p) |pp| {
            if (pp.value == .object) run = pp.value.object;
        }
    }

    try w.writeAll("{\"activation\":");
    try jsonStr(w, args.activation);
    try w.writeAll(",\"export\":");
    try jsonStr(w, args.export_name);

    // response HEAD — status / headers / cookies — the ambient `response` global
    // (matches the engine's dispatcher.extractResponseMetadata).
    try w.writeAll(",\"response\":");
    if (run) |r| {
        if (r.get("response")) |rv| try std.json.Stringify.value(rv, .{}, w) else try w.writeAll("null");
    } else try w.writeAll("null");

    // disposition + body/ctx — from the RETURN value: a terminal body (commit +
    // close) or `next({ctx})` (hold the connection). handler-shape §2.1.
    var held = false;
    var ctx_val: ?std.json.Value = null;
    var body_val: ?std.json.Value = null;
    if (run) |r| {
        if (r.get("result")) |res| {
            if (res == .object) {
                if (res.object.get("__rove_disposition")) |disp| {
                    if (disp == .string and std.mem.eql(u8, disp.string, "next")) {
                        held = true;
                        ctx_val = res.object.get("ctx");
                    }
                }
            }
            if (!held) body_val = res;
        }
    }
    try w.writeAll(",\"disposition\":");
    try jsonStr(w, if (held) "held" else "terminal");
    if (held) {
        try w.writeAll(",\"ctx\":");
        if (ctx_val) |cv| try std.json.Stringify.value(cv, .{}, w) else try w.writeAll("null");
    } else {
        try w.writeAll(",\"body\":");
        if (body_val) |bv| {
            if (bv == .null) try w.writeAll("null") else try std.json.Stringify.value(bv, .{}, w);
        } else try w.writeAll("null");
    }

    // effects — ONE ordered log (occurrence order), built in the epilogue: reads,
    // writes, and cmds interleaved as the handler performed them.
    try w.writeAll(",\"effects\":");
    if (run) |r| {
        if (r.get("effects")) |ev| try std.json.Stringify.value(ev, .{}, w) else try w.writeAll("[]");
    } else try w.writeAll("[]");

    try w.writeAll(",\"error\":");
    if (run) |r| {
        if (r.get("error")) |ev| {
            if (ev == .null) try w.writeAll("null") else try std.json.Stringify.value(ev, .{}, w);
        } else try w.writeAll("null");
    } else try w.writeAll("{\"message\":\"the run produced no output — it failed before the handler completed (see divergence)\"}");

    const ok_run = args.run_json != null and args.divergence == null;
    try w.print(",\"ok\":{s}", .{if (ok_run) "true" else "false"});

    // divergence — only when present (replay/fail signal; absent in a clean sim).
    if (args.divergence) |d| {
        try w.writeAll(",\"divergence\":");
        try jsonStr(w, d);
    }
    try w.writeByte('}');
}

/// Extract the threaded ctx from a trigger_payload envelope. A continuation
/// resume parks the ctx as `{"ctx": <value>}` (`worker_drain.zig` synthCtxBody);
/// return the inner value re-serialized as JSON text (→ `request.ctx`). null
/// when the payload isn't a ctx envelope (e.g. a raw inbound body).
fn extractCtx(a: std.mem.Allocator, envelope: []const u8) ?[]const u8 {
    const p = std.json.parseFromSlice(std.json.Value, a, envelope, .{}) catch return null;
    if (p.value != .object) return null;
    const c = p.value.object.get("ctx") orelse return null;
    return std.json.Stringify.valueAlloc(a, c, .{}) catch null;
}

// ── json read/write helpers ──

fn jStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn jInt(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => null,
    };
}
fn parseU64(s: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, s orelse return null, 10) catch null;
}
fn parseI64(s: ?[]const u8) ?i64 {
    return std.fmt.parseInt(i64, s orelse return null, 10) catch null;
}
fn b64decode(a: std.mem.Allocator, s: []const u8) Error![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return Error.BadFixture;
    const buf = try a.alloc(u8, n);
    dec.decode(buf, s) catch return Error.BadFixture;
    return buf;
}

fn optStr(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |v| try jsonStr(w, v) else try w.writeAll("null");
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

/// Base64-encode `bytes` as a JSON string literal (for binary payloads that
/// aren't valid UTF-8 — e.g. a binary WS frame's `request.activation.data`).
fn jsonB64(a: std.mem.Allocator, w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(out);
    _ = enc.encode(out, bytes);
    try jsonStr(w, out);
}

test {
    std.testing.refAllDecls(@This());
    _ = decode;
    _ = hostmod;
    _ = epilogue;
    _ = world;
    _ = export_fixture;
}
