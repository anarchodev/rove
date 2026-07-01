//! Native replay driver (Phase 2 §2c) — the entry the `rewind replay` verb
//! calls. Decodes a self-contained fixture (the JSON `rewind pull` writes),
//! drives arenajs's native replay engine over the recorded tape, and emits one
//! LLM-friendly JSON artifact: the replayed response / result / console / error,
//! the produced kv write-set, any tape divergence, and replayed-vs-recorded
//! status. No Node, no WASM, no network — the engine is linked in.
//!
//! `run` is one-shot: arena_init installs process-global engine state, so a CLI
//! invocation replays exactly one request (which is the whole use case).

const std = @import("std");
const decode = @import("tape_decode.zig");
const hostmod = @import("host.zig");
const epilogue = @import("epilogue.zig");
const world = @import("world.zig");
const export_fixture = @import("export_fixture.zig");

/// Transcode a captured `rewind pull` fixture into a declarative sim world.
/// Re-exported for the `rewind export-fixture` verb.
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

/// Replay the fixture and write the LLM-JSON artifact to `out`. `source_dir`,
/// when non-null, serves working-tree module source instead of the pulled
/// source — the "does my local change still satisfy this request?" lever.
pub fn run(
    a: std.mem.Allocator,
    fixture_json: []const u8,
    source_dir: ?[]const u8,
    out: *std.ArrayList(u8),
) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, fixture_json, .{}) catch
        return Error.BadFixture;
    const root = parsed.value;
    if (root != .object) return Error.BadFixture;
    const obj = root.object;

    const request_id = jStr(obj, "request_id") orelse "";
    const tenant = jStr(obj, "tenant") orelse "";
    const activation = jStr(obj, "activation") orelse "inbound";
    const entry = jStr(obj, "entry") orelse "index.mjs";

    const req = if (obj.get("request")) |v| (if (v == .object) v.object else null) else null;
    const method = if (req) |r| (jStr(r, "method") orelse "GET") else "GET";
    const path = if (req) |r| (jStr(r, "path") orelse "/") else "/";
    const host_hdr = if (req) |r| (jStr(r, "host") orelse "") else "";

    // ── decode the tapes the replay host needs ──
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

    // ── non-inbound activation surface (replay-and-sim.md §2-§3) ──
    // For a callback/continuation the inputs ride two channels the inbound path
    // ignores: trigger_payload carries the threaded ctx as a `{"ctx": …}`
    // envelope; fetch_responses carries a fetch result (status/ok/final + body).
    // Both are reconstructed here and handed to the SAME epilogue the sim path
    // uses. (BodyRef-to-blob bytes aren't fetchable offline — inline only.)
    const is_inbound = std.mem.eql(u8, activation, "inbound") or
        std.mem.eql(u8, activation, "inbound_headers") or
        std.mem.eql(u8, activation, "inbound_chunk");
    const ctx_json: ?[]const u8 = if (is_inbound) null else blk: {
        const b64 = if (tapes) |t| jStr(t, "trigger_payload_b64") else null;
        const s = b64 orelse break :blk null;
        const tp = decode.decodeTriggerPayload(a, try b64decode(a, s)) catch break :blk null;
        if (tp.len == 0 or tp[0].batch_id != decode.NO_BATCH or tp[0].inline_bytes.len == 0)
            break :blk null;
        break :blk extractCtx(a, tp[0].inline_bytes);
    };
    var fetch_result: ?epilogue.Result = null;
    var fetch_body: ?[]const u8 = null;
    var resolved_export: ?[]const u8 = null;
    if (!is_inbound) {
        const b64 = if (tapes) |t| jStr(t, "fetch_responses_b64") else null;
        if (b64) |s| {
            const fr = decode.decodeFetchResponses(a, try b64decode(a, s)) catch &.{};
            if (fr.len != 0) {
                var body = std.ArrayList(u8){};
                for (fr) |e| try body.appendSlice(a, e.inline_bytes);
                fetch_body = body.items;
                const last = fr[fr.len - 1];
                fetch_result = .{
                    .status = if (last.final) @as(i64, last.terminal_status) else null,
                    .ok = if (last.final) last.terminal_ok else null,
                    .done = last.final,
                    .fetch_id = last.fetch_id,
                    .chunk_seq = @as(i64, last.seq),
                };
                // Resolve the export by event shape. The `{to}` override is not
                // recorded (replay-and-sim.md §5 G3), so an overridden callback
                // replays under its conventional export — a known limit.
                resolved_export = if (!last.final)
                    "onFetchChunk"
                else if (last.seq == 0) "onFetchResult" else "onFetchDone";
            }
        }
    }

    // ws_message: the frame is `request.activation = {opcode, data}`, taped as
    // activation_bytes = [opcode:u8][data]. Rebuild it into an activation-meta
    // JSON the epilogue installs. Text frames (opcode 1) reproduce faithfully;
    // binary frames (opcode 2) would need a Uint8Array surface (follow-up).
    var ws_activation_json: ?[]const u8 = null;
    if (std.mem.eql(u8, activation, "ws_message")) {
        const b64 = if (tapes) |t| jStr(t, "activation_bytes_b64") else null;
        if (b64) |s| {
            const ab = try b64decode(a, s);
            if (ab.len >= 1) {
                const opcode = ab[0];
                const data = ab[1..];
                var buf = std.ArrayList(u8){};
                var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
                const w = &aw.writer;
                // Binary frame (opcode 2) → `request.activation.data` is a
                // Uint8Array; carry the bytes as base64 and let the epilogue
                // rebuild the array. Text frame (1) → a decoded string.
                if (opcode == 2) {
                    try w.print("{{\"opcode\":{d},\"dataB64\":", .{opcode});
                    try jsonB64(a, w, data);
                } else {
                    try w.print("{{\"opcode\":{d},\"data\":", .{opcode});
                    try jsonStr(w, data);
                }
                try w.writeByte('}');
                buf = aw.toArrayList();
                ws_activation_json = buf.items;
            }
        }
    }

    // ── module sources (path → handler source) ──
    var sources = std.StringHashMapUnmanaged([]const u8){};
    if (obj.get("sources")) |sv| if (sv == .array) {
        for (sv.array.items) |e| {
            if (e != .object) continue;
            const p = jStr(e.object, "path") orelse continue;
            const kind = jStr(e.object, "kind") orelse "";
            if (!std.mem.eql(u8, kind, "handler")) continue;
            const src = jStr(e.object, "source") orelse continue;
            try sources.put(a, p, src);
        }
    };
    // The entry module is run directly via `arena_run_module` (only its imports
    // go through `module_load`). So `--source-dir` must override the ENTRY here
    // too, or a changed top-level handler would silently replay the pulled
    // source. With a source-dir set, the entry MUST come from the working tree
    // (a missing local entry is an error, not a fall-back to the recording).
    const entry_src = blk: {
        if (source_dir) |dir| {
            const ep = std.fs.path.join(a, &.{ dir, entry }) catch return Error.OutOfMemory;
            break :blk std.fs.cwd().readFileAlloc(a, ep, 8 << 20) catch
                return Error.EntrySourceMissing;
        }
        break :blk sources.get(entry) orelse return Error.EntrySourceMissing;
    };

    const binary_body = std.mem.eql(u8, activation, "inbound_chunk") or
        std.mem.eql(u8, activation, "fetch_chunk");
    // A fetch_chunk's `request.body` is the FETCH result body (from
    // fetch_responses), not the inbound request body.
    const eff_body = fetch_body orelse body_bytes;
    const epi = try epilogue.build(a, .{
        .method = method,
        .path = path,
        .host = host_hdr,
        .request_reads = reads,
        .body_bytes = eff_body,
        .export_name = resolved_export orelse epilogue.exportForActivation(activation),
        .binary_body = binary_body,
        .ctx_json = ctx_json,
        .activation_json = ws_activation_json,
        .result = fetch_result,
    });

    const full_src = try std.mem.concatWithSentinel(a, u8, &.{ entry_src, epi }, 0);
    const entry_z = try a.dupeZ(u8, entry);

    // ── drive the engine ──
    if (arena_init(8192, 8192) != 0) return Error.ArenaInit;
    // One-shot: deliberately NO arena_destroy — under the dual-arena allocator
    // JS_FreeRuntime trips a debug-only gc_obj_list assert; process exit
    // reclaims everything (spike.zig §teardown).

    var host = hostmod.Host{ .a = a, .kv = kv_entries, .sources = sources, .source_dir = source_dir };
    host.install();

    const seed = parseU64(jStr(obj, "seed")) orelse 0;
    const ts_ns = parseI64(jStr(obj, "timestamp_ns")) orelse 0;
    const date_ms: u64 = if (ts_ns > 0) @intCast(@divTrunc(ts_ns, std.time.ns_per_ms)) else 0;
    arena_set_random_seed(@truncate(seed), @truncate(seed >> 32));
    arena_set_date_now(@truncate(date_ms), @truncate(date_ms >> 32));
    arena_set_trace_mode(0); // result capture only — no scan/drill timeline

    const rc = arena_run_module(entry_z.ptr, full_src.ptr);

    // ── extract + emit ──
    const replay_json = host.output orelse {
        // No sentinel write — the run died before the epilogue's capture (e.g.
        // a module-load divergence or a syntax error). Emit a structured
        // failure rather than nothing.
        try emitNoOutput(a, out, .{
            .request_id = request_id,
            .tenant = tenant,
            .activation = activation,
            .entry = entry,
            .rc = rc,
            .divergence = host.diverged,
        });
        return;
    };

    // Replayed status: the handler's returned `result.status`, falling back to
    // the mutated `response.status`. Parsed for the recorded-vs-replayed match.
    const replayed_status = statusOf(a, replay_json);
    const recorded = if (obj.get("recorded")) |v| (if (v == .object) v.object else null) else null;
    const recorded_status: ?i64 = if (recorded) |r| jInt(r, "status") else null;

    try emit(a, out, .{
        .request_id = request_id,
        .tenant = tenant,
        .activation = activation,
        .entry = entry,
        .rc = rc,
        .divergence = host.diverged,
        .writes = host.writes.items,
        .replay_json = replay_json,
        .recorded = recorded,
        .replayed_status = replayed_status,
        .recorded_status = recorded_status,
    });
}

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
    });
}

// ── emit helpers ──

const NoOutputArgs = struct {
    request_id: []const u8,
    tenant: []const u8,
    activation: []const u8,
    entry: []const u8,
    rc: c_int,
    divergence: ?[]const u8,
};

fn emitNoOutput(a: std.mem.Allocator, out: *std.ArrayList(u8), args: NoOutputArgs) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(a, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;
    try w.writeAll("{\"request_id\":");
    try jsonStr(w, args.request_id);
    try w.writeAll(",\"tenant\":");
    try jsonStr(w, args.tenant);
    try w.writeAll(",\"activation\":");
    try jsonStr(w, args.activation);
    try w.writeAll(",\"entry\":");
    try jsonStr(w, args.entry);
    try w.print(",\"run_rc\":{d},\"ok\":false,\"divergence\":", .{args.rc});
    try optStr(w, args.divergence);
    try w.writeAll(",\"replay\":null,\"error\":\"the replayed run produced no output (it failed before the handler completed — see divergence / run_rc)\"}");
}

const EmitArgs = struct {
    request_id: []const u8,
    tenant: []const u8,
    activation: []const u8,
    entry: []const u8,
    rc: c_int,
    divergence: ?[]const u8,
    writes: []const hostmod.KvWrite,
    replay_json: []const u8,
    recorded: ?std.json.ObjectMap,
    replayed_status: ?i64,
    recorded_status: ?i64,
};

fn emit(a: std.mem.Allocator, out: *std.ArrayList(u8), args: EmitArgs) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(a, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;

    try w.writeAll("{\"request_id\":");
    try jsonStr(w, args.request_id);
    try w.writeAll(",\"tenant\":");
    try jsonStr(w, args.tenant);
    try w.writeAll(",\"activation\":");
    try jsonStr(w, args.activation);
    try w.writeAll(",\"entry\":");
    try jsonStr(w, args.entry);
    try w.print(",\"run_rc\":{d},\"divergence\":", .{args.rc});
    try optStr(w, args.divergence);

    // kv writes the replayed handler produced.
    try w.writeAll(",\"kv_writes\":[");
    for (args.writes, 0..) |wr, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"op\":");
        try jsonStr(w, @tagName(wr.op));
        try w.writeAll(",\"key\":");
        try jsonStr(w, wr.key);
        if (wr.op == .set) {
            try w.writeAll(",\"value\":");
            try jsonStr(w, wr.value);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');

    // The handler run's parked output (response / result / error / console) —
    // already valid JSON, embedded verbatim.
    try w.writeAll(",\"replay\":");
    try w.writeAll(args.replay_json);

    // recorded summary + the headline match.
    try w.writeAll(",\"recorded\":{\"status\":");
    if (args.recorded_status) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
    try w.writeAll(",\"console\":");
    try optStr(w, if (args.recorded) |r| jStr(r, "console") else null);
    try w.writeAll(",\"exception\":");
    try optStr(w, if (args.recorded) |r| jStr(r, "exception") else null);
    try w.writeByte('}');

    try w.writeAll(",\"replayed_status\":");
    if (args.replayed_status) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
    const status_match = args.replayed_status != null and args.recorded_status != null and
        args.replayed_status.? == args.recorded_status.?;
    try w.print(",\"status_match\":{s}}}", .{if (status_match) "true" else "false"});
}

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
};

/// Emit a sim bundle. Same engine output as `emit`, minus the recorded-vs-
/// replayed comparison (an authored world has no recording to match), plus the
/// `miss_policy` it ran under and the typed `holes` a `resolve` run filled.
fn emitWorld(a: std.mem.Allocator, out: *std.ArrayList(u8), args: EmitWorldArgs) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(a, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;

    try w.writeAll("{\"mode\":\"sim\",\"entry\":");
    try jsonStr(w, args.entry);
    try w.writeAll(",\"activation\":");
    try jsonStr(w, args.activation);
    try w.writeAll(",\"export\":");
    try jsonStr(w, args.export_name);
    try w.writeAll(",\"miss_policy\":");
    try jsonStr(w, @tagName(args.miss));
    try w.print(",\"run_rc\":{d},\"divergence\":", .{args.rc});
    try optStr(w, args.divergence);

    // kv writes the handler produced.
    try w.writeAll(",\"kv_writes\":[");
    for (args.writes, 0..) |wr, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"op\":");
        try jsonStr(w, @tagName(wr.op));
        try w.writeAll(",\"key\":");
        try jsonStr(w, wr.key);
        if (wr.op == .set) {
            try w.writeAll(",\"value\":");
            try jsonStr(w, wr.value);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');

    // typed holes — reads the declared world didn't supply (resolve mode).
    try w.writeAll(",\"holes\":[");
    for (args.holes, 0..) |hole, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"op\":");
        try jsonStr(w, @tagName(hole.op));
        try w.writeAll(",\"key\":");
        try jsonStr(w, hole.key);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    // the run output (response / result / error / console), or null + ok=false
    // when the run died before capture (e.g. a fail-policy divergence).
    if (args.run_json) |rj| {
        try w.writeAll(",\"run\":");
        try w.writeAll(rj);
        try w.writeAll(",\"ok\":true}");
    } else {
        try w.writeAll(",\"run\":null,\"ok\":false,\"error\":\"the run produced no output (it failed before the handler completed — see divergence / run_rc; a fail miss-policy on an under-specified world lands here)\"}");
    }
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
