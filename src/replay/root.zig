//! The ONE replay/sim engine — `runWorld(world, code, on-miss)`. Both `rewind
//! replay` (default on-miss=fail) and `rewind sim` (default on-miss=resolve)
//! call it over the SAME declarative `world.json` (`world.zig`): the request
//! surface, a key→value KV map (+ `kvAbsent`, + recorded `kvPrefix` results),
//! ctx, the flattened fetch/callback result, the resolved export, seed, and
//! optionally the `recorded` output. KV reads resolve BY KEY with a write-
//! through overlay (order-independent — `replay-and-sim.md` §1); faithfulness is
//! the output-level `status_match`, not a per-read check. It emits one LLM-JSON
//! bundle: the run's response / result / console / effects, the write-set, typed
//! `holes` (resolve), and the recorded comparison. No Node/WASM/network — the
//! arenajs engine is linked in.
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

/// The on-miss policy a declarative `runWorld` runs under — the replay↔sim
/// axis. Re-exported so CLI callers can pass `--miss-policy` without importing
/// the host internals.
pub const MissPolicy = hostmod.MissPolicy;

pub const Error = error{
    BadFixture,
    EntrySourceMissing,
    ArenaInit,
    NoOutput,
    WriteFailed, // std.Io.Writer.Allocating sink (OOM surfaced as WriteFailed)
} || decode.Error || std.mem.Allocator.Error;


/// Run a **declarative** world (an *authored* fixture, not a captured tape) —
/// the sim corner of the one engine. KV reads resolve order-independently
/// against the world's key→value map; `miss_override` (when set) forces the
/// on-miss policy, else the world's `missPolicy` is used (`fail` = refuse to
/// invent / `resolve` = answer not_found + record a typed hole). The request
/// surface is rebuilt by synthesizing `request_reads` entries from the declared
/// request, so the SAME epilogue serves it — undeclared header reads are
/// naturally `undefined` (resolve), declared ones serve their value.
pub fn runWorld(
    a: std.mem.Allocator,
    world_json: []const u8,
    source_dir: ?[]const u8,
    miss_override: ?hostmod.MissPolicy,
    out: *std.ArrayList(u8),
) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, world_json, .{}) catch
        return Error.BadFixture;
    const wv = world.fromValue(a, parsed.value) catch return Error.BadFixture;
    const miss = miss_override orelse wv.miss;

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
    var kv_absent = std.StringHashMapUnmanaged(void){};
    for (wv.kv_absent) |k| try kv_absent.put(a, k, {});
    // Recorded prefix results, served verbatim (faithful prefix scans).
    var prefix_results = std.StringHashMapUnmanaged([]const decode.KvPair){};
    for (wv.kv_prefix) |pe| {
        const rows = try a.alloc(decode.KvPair, pe.rows.len);
        for (pe.rows, 0..) |row, i| rows[i] = .{ .key = row.key, .value = row.value };
        try prefix_results.put(a, pe.prefix, rows);
    }

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
        .absent = kv_absent,
        .prefix_results = prefix_results,
        .miss = miss,
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
        .miss = miss,
        .rc = rc,
        .divergence = host.diverged,
        .writes = host.writes.items,
        .holes = host.holes.items,
        .run_json = host.output,
        .recorded = wv.recorded,
    });
}

// ── emit helpers ──

const EmitWorldArgs = struct {
    entry: []const u8,
    activation: []const u8,
    export_name: []const u8,
    miss: hostmod.MissPolicy,
    rc: c_int,
    divergence: ?[]const u8,
    writes: []const hostmod.KvWrite,
    holes: []const hostmod.Hole,
    /// The run's parked output (response/result/error/console), or null when the
    /// run died before the epilogue captured it (e.g. a fail-policy divergence
    /// or a syntax error).
    run_json: ?[]const u8,
    /// The recorded output, when this world came from a capture — drives the
    /// output-level faithfulness check (`status_match`).
    recorded: ?world.Recorded = null,
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

    // Output-level faithfulness — when the world carries a recording (replay).
    const replayed_status: ?i64 = if (args.run_json) |rj| statusOf(a, rj) else null;
    if (args.recorded) |rec| {
        try w.writeAll(",\"recorded\":{\"status\":");
        if (rec.status) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
        try w.writeAll(",\"console\":");
        try optStr(w, rec.console);
        try w.writeAll(",\"exception\":");
        try optStr(w, rec.exception);
        try w.writeByte('}');
        try w.writeAll(",\"replayed_status\":");
        if (replayed_status) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
        const match = replayed_status != null and rec.status != null and replayed_status.? == rec.status.?;
        try w.print(",\"status_match\":{s}", .{if (match) "true" else "false"});
    }
    try w.writeByte('}');
}

/// Pull `result.status` (handler return), falling back to `response.status`,
/// from the parked output JSON. A run that threw (non-null `error`) has no
/// meaningful replayed status — return null so a diverged/errored run never
/// reports a spurious status match against the recording.
fn statusOf(a: std.mem.Allocator, replay_json: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, replay_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    if (o.get("error")) |e| if (e == .object) return null; // handler threw
    if (o.get("result")) |r| if (r == .object) {
        if (jInt(r.object, "status")) |s| return s;
    };
    if (o.get("response")) |r| if (r == .object) {
        if (jInt(r.object, "status")) |s| return s;
    };
    return null;
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
