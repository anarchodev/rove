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
//! The engine is an `Engine` holding a *resettable* **sim** reactor (arenajs
//! 0.3.3's instance API, `arena_reactor_new` + `arena_run_module_r`): base is
//! frozen once at `Engine.init`, and every run wipes the request arena
//! (`JS_ResetRequestArena`) — the production per-request model — so one reactor
//! runs many worlds isolated by construction. `Engine.simulate(world) → bundle`
//! is the atom; `runWorld` is the one-shot wrapper (`rewind sim`/`replay`), and
//! the JS-authored test runner (`harness.zig`, `runTests`) holds ONE persistent
//! `Engine` and folds a whole saga over repeated `simulate` calls, running the
//! test body itself on a SEPARATE harness reactor — two reactors, one thread,
//! the de-singletoned instance API's headline use case.
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

// ── the JS-authored test runner (harness reactor + saga library) ──
const harness = @import("harness.zig");
pub const runTests = harness.runTests;
pub const TestOptions = harness.Options;
pub const TestReport = harness.Report;
pub const TestFileResult = harness.FileResult;

// ── arenajs native ABI — instance API (qjs-arena-reactor.h) ──
// The reactor was de-singletoned in arenajs 0.3.3 (`arena_reactor_new` + the
// `_r` variants): each `ArenaReactor*` owns its own runtime, so two can coexist
// on one thread and runs may NEST across them. That is exactly the shape the
// rewind test runner needs — a long-lived harness runtime whose test body
// synchronously drives a reset-reused sim runtime via `simulate()` — so we drop
// the old process-global singleton (`arena_init`/`arena_run_module`) entirely
// and consume the instance surface (converge to one path, no coexistence).
pub const ArenaReactor = opaque {};
extern fn arena_reactor_new(base_kb: c_int, request_kb: c_int) ?*ArenaReactor;
// arenajs 0.3.4 deferred-freeze construction — lets us install the compute
// globals (`sim_globals.PRELUDE`) into the base before it freezes.
extern fn arena_reactor_new_open(base_kb: c_int, request_kb: c_int) ?*ArenaReactor;
extern fn arena_reactor_eval_base(r: *ArenaReactor, src: [*c]const u8) c_int;
extern fn arena_reactor_freeze(r: *ArenaReactor) void;
extern fn arena_run_module_r(r: *ArenaReactor, entry_name: [*c]const u8, entry_src: [*c]const u8) c_int;

const sim_globals = @import("sim_globals.zig");
extern fn arena_set_trace_mode_r(r: *ArenaReactor, mode: c_int) void;
extern fn arena_set_date_now_r(r: *ArenaReactor, ms: i64) void;
extern fn arena_set_random_seed_r(r: *ArenaReactor, seed: u64) void;
extern fn arena_set_request_mode_r(r: *ArenaReactor, mode: c_int) void;

pub const Error = error{
    BadFixture,
    EntrySourceMissing,
    ArenaInit,
    NoOutput,
    WriteFailed, // std.Io.Writer.Allocating sink (OOM surfaced as WriteFailed)
} || decode.Error || std.mem.Allocator.Error;

/// The one replay/sim engine, holding a resettable **sim** reactor. Each
/// `simulate()` resets that reactor's request arena and runs one world through
/// it, so repeated calls are isolated by construction (no cross-run kv/alloc
/// leak). One `Engine` runs many worlds on one thread; the harness runner
/// (`harness.zig`) holds ONE persistent `Engine` and folds a whole saga over
/// repeated `simulate()` calls, while `runWorld` below is the one-shot wrapper
/// for `rewind sim` / `rewind replay`.
pub const Engine = struct {
    sim: *ArenaReactor,

    pub fn init() Error!Engine {
        // Build the base unfrozen, eval the compute-globals prelude into it, then
        // seal — so every handler run gets crypto/base64url/jwt/oidc/sessions/…
        // from a shared frozen base (one install, not per-request).
        // A 16 MiB request arena (vs the worker's 8): the bump allocator never
        // frees mid-run, so BigInt-heavy pure-JS crypto (ES256/RS256 verify)
        // churns more than a typical handler. The worker survives such churn via
        // its GC-on-OOM fallback, which the sim lacks — this headroom stands in
        // for it. Reset per run, so it's a ceiling, not steady growth.
        const s = arena_reactor_new_open(8192, 16384) orelse return Error.ArenaInit;
        if (arena_reactor_eval_base(s, sim_globals.PRELUDE.ptr) != 0) return Error.ArenaInit;
        arena_reactor_freeze(s);
        return .{ .sim = s };
    }

    /// The sim reactor is **process-lived** and deliberately NOT torn down here.
    /// Each `simulate` run's epilogue roots the handler surface (`request`,
    /// `kv`, `response`, `after`, …) on the reactor's base global object, so
    /// those objects outlive the request arena but are referenced from base —
    /// `JS_FreeRuntime`'s leak check would abort if we freed the runtime with
    /// them still rooted. The replay/sim/test CLIs are one-shot processes, so
    /// the reactor is reclaimed at exit (the same lifetime the pre-0.3.3
    /// singleton had — it never freed either). `deinit` stays for API symmetry
    /// and to mark the owning scope.
    pub fn deinit(self: *Engine) void {
        _ = self;
    }

    /// Run a **declarative** world (an *authored* fixture, not a captured tape)
    /// on the sim reactor, appending the LLM-JSON bundle to `out`. KV reads
    /// resolve order-independently against the world's key→value map — a
    /// **closed world**: a key not in the map is `not_found` (never a
    /// divergence). Faithfulness lives at the output (`expected`) + the effect
    /// log, not per-read. The request surface is rebuilt by synthesizing
    /// `request_reads` entries from the declared request, so the SAME epilogue
    /// serves it — undeclared header reads are naturally `undefined`.
    ///
    /// Installs the sim reactor's replay host for the duration of the run. When
    /// a nested caller (the harness) had its own host installed, it must
    /// re-install after this returns — the host registration is process-global
    /// by arenajs's contract (one thread, N instances, save/restore at the
    /// call site).
    /// Source resolution precedence (highest first): the world's own
    /// `source_dir` (`scenario({ sourceDir })`), then an explicit
    /// `source_dir` override (`--source-dir`), then the world's inline
    /// `sources`, then `base_dir` (the `rewind test` app dir — a fallback used
    /// only when nothing more specific applies). An explicit dir wins over
    /// inline sources so `rewind sim --source-dir ./tree` stays the working-tree
    /// "what-if" lever; inline sources win over the bare `base_dir` fallback so
    /// `scenario({ sources })` runs its own code.
    pub fn simulate(
        self: *Engine,
        a: std.mem.Allocator,
        world_json: []const u8,
        source_dir: ?[]const u8,
        base_dir: ?[]const u8,
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

        // ── kv readset → map ──
        var kv_map = std.StringHashMapUnmanaged([]const u8){};
        for (wv.kv) |p| try kv_map.put(a, p.key, p.value);

        // ── module sources (inline) ──
        var sources = std.StringHashMapUnmanaged([]const u8){};
        for (wv.sources) |s| {
            if (!std.mem.eql(u8, s.kind, "handler")) continue;
            try sources.put(a, s.path, s.source);
        }

        // Source resolution (see the doc-comment): world source_dir / explicit
        // override win over inline `sources`, which win over the `base_dir`
        // fallback. `src_dir` non-null ⇒ resolve from disk; null ⇒ inline.
        const explicit_dir = wv.source_dir orelse source_dir;
        const src_dir = explicit_dir orelse (if (sources.count() != 0) null else base_dir);

        // Entry source: working tree (if a source dir) else the inline world.
        const entry_src = blk: {
            if (src_dir) |dir| {
                const ep = std.fs.path.join(a, &.{ dir, wv.entry }) catch return Error.OutOfMemory;
                break :blk std.fs.cwd().readFileAlloc(a, ep, 8 << 20) catch
                    return Error.EntrySourceMissing;
            }
            break :blk sources.get(wv.entry) orelse return Error.EntrySourceMissing;
        };

        const binary_body = std.mem.eql(u8, wv.activation, "inbound_chunk") or
            std.mem.eql(u8, wv.activation, "fetch_chunk");

        // Run the real `_middlewares/index.mjs` `before` iff it's resolvable AND
        // this is an inbound-family (trust-boundary) activation — the worker
        // skips middleware for continuations (a resume already ran behind the
        // gate). Resolvable = inline in `sources`, or on disk under `src_dir`.
        const MW_PATH = "_middlewares/index.mjs";
        const is_trust_boundary = std.mem.eql(u8, wv.activation, "inbound") or
            std.mem.eql(u8, wv.activation, "inbound_headers") or
            std.mem.eql(u8, wv.activation, "inbound_chunk") or
            std.mem.eql(u8, wv.activation, "ws_message");
        const has_middleware = if (sources.get(MW_PATH) != null)
            true
        else if (src_dir) |dir| blk: {
            const mp = std.fs.path.join(a, &.{ dir, MW_PATH }) catch break :blk false;
            std.fs.cwd().access(mp, .{}) catch break :blk false;
            break :blk true;
        } else false;
        const run_middleware = is_trust_boundary and has_middleware;
        // The resolved export: the world's explicit `export` (the `{to}` /
        // resolved name a callback needs) wins; else the conventional export.
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
            .session_json = wv.session_json,
            .run_middleware = run_middleware,
            .real_effects = wv.real_effects,
            .result = result,
        });
        const full_src = try std.mem.concatWithSentinel(a, u8, &.{ entry_src, epi }, 0);
        const entry_z = try a.dupeZ(u8, wv.entry);

        // ── drive the sim reactor. `arena_run_module_r` resets the request
        // arena on entry, so repeated simulate() calls on `self.sim` are
        // isolated (no cross-run kv/alloc leak). ──
        var host = hostmod.Host{
            .a = a,
            .kv_map = kv_map,
            .sources = sources,
            .source_dir = src_dir,
        };
        host.install();

        // Replay under the regime the live request completed under (mode binds
        // at the entry reset). Set EVERY run — the choice is sticky on the
        // reactor, so a GC world must not leak GC mode into the next bump world.
        arena_set_request_mode_r(self.sim, if (wv.arena_gc) 0 else 1);
        arena_set_random_seed_r(self.sim, wv.seed);
        // Reinterpret the u64 ms bit-pattern as the i64 the API takes (matches
        // the pre-instance lo/hi split, which passed the same 64 bits); a plain
        // @intCast would panic on a pathological now_ms ≥ 2^63.
        arena_set_date_now_r(self.sim, @bitCast(wv.now_ms));
        arena_set_trace_mode_r(self.sim, 0);

        const rc = arena_run_module_r(self.sim, entry_z.ptr, full_src.ptr);

        try emitWorld(a, out, .{
            .entry = wv.entry,
            .activation = wv.activation,
            .export_name = export_name,
            .rc = rc,
            .divergence = host.diverged,
            .writes = host.writes.items,
            .run_json = host.output,
        });

        // Optional `expected` → append a `verify` result (partial,
        // order-independent match over the bundle). Present ⇒ test/replay
        // assertion; absent ⇒ plain sim (bundle only).
        if (wv.expected_json) |ej| appendVerify(a, out, ej) catch {};
    }
};

/// Process-global sim engine backing `runWorld`. Lazily created once and
/// **reused** (each `simulate` resets the sim reactor's request arena), so
/// repeated `runWorld` calls in one process share one reactor rather than
/// leaking a fresh ~16 MiB runtime per call — the pre-0.3.3 init-once behavior.
/// Not thread-safe (one thread, per the reactor contract). The harness runner
/// holds its OWN separate `Engine`; this is only `rewind sim`/`replay`.
var g_run_engine: ?Engine = null;

/// Run a single declarative world and emit its bundle — `rewind sim` / `rewind
/// replay`. Reuses the process-global engine. Callers folding MANY worlds
/// should hold their own persistent `Engine` and call `simulate` directly
/// rather than looping `runWorld` (each call would otherwise re-parse and the
/// intent — one reused reactor — is clearer with an explicit `Engine`).
pub fn runWorld(
    a: std.mem.Allocator,
    world_json: []const u8,
    source_dir: ?[]const u8,
    out: *std.ArrayList(u8),
) Error!void {
    if (g_run_engine == null) g_run_engine = try Engine.init();
    try g_run_engine.?.simulate(a, world_json, source_dir, null, out);
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
    _ = harness;
}
