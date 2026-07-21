//! The rewind **test harness** — the second-runtime runner that turns the
//! `simulate(world) → bundle` atom into a JS-authored test surface
//! (`docs/architecture/replay-and-sim.md` "The saga test model").
//!
//! Two reactors, one thread (arenajs 0.3.3's instance API,
//! `qjs-arena-reactor.h`):
//!
//!   - the **harness** reactor `H` runs each `_tests/*.mjs` file — the test
//!     body's `expect`/loops/`scenario` control flow — and imports the embedded
//!     `rewind:test` library;
//!   - the **sim** reactor `S` (held by `root.Engine`) runs each world the test
//!     asks for, reset-reused between runs.
//!
//! The bridge is the KV channel — no arenajs change. arenajs installs `kv.*` on
//! every reactor's base pre-freeze, so the library reaches the host without a
//! bespoke native (the `arena_multi_reactor.c` shape, where a `kv.get`
//! responder synchronously runs a module on the sibling instance). The library
//! stashes a world (`kv.set(WORLD_KEY, json)`) then triggers the run
//! (`kv.get(RUN_KEY)` → the bundle), and streams each assertion outcome
//! (`kv.set(ASSERT_KEY, json)`) and snapshot read/write (`SNAP_PREFIX`) back to
//! this host. Because the host registration is process-global (one thread, N
//! instances), the run-trigger saves/restores it around the nested sim run.

const std = @import("std");
const root = @import("root.zig");
const hostmod = @import("host.zig");
const decode = @import("tape_decode.zig");
const path_confine = @import("path_confine.zig");

extern fn arena_reactor_new(base_kb: c_int, request_kb: c_int) ?*root.ArenaReactor;
extern fn arena_set_request_mode_r(r: *root.ArenaReactor, mode: c_int) void;
extern fn arena_run_module_r(r: *root.ArenaReactor, entry_name: [*c]const u8, entry_src: [*c]const u8) c_int;
extern fn arena_replay_set_host(host: *const hostmod.ReplayHost, user: ?*anyopaque) void;

/// The embedded saga library. `import { scenario, expect } from "rewind:test"`
/// in a test file resolves here (served by `moduleLoad`).
pub const LIB_SOURCE = @embedFile("rewind_test.mjs");
pub const LIB_SPECIFIER = "rewind:test";

// ── the magic-kv bridge protocol (host ⇄ harness JS) ──
const WORLD_KEY = "\x00rt/world"; // set: stash the world to run next
const RUN_KEY = "\x00rt/run"; // get: run the stashed world → bundle JSON
const ASSERT_KEY = "\x00rt/assert"; // set: append one assertion outcome
const DONE_KEY = "\x00rt/done"; // set: the test file evaluated to completion
/// `DONE_KEY` as a JS string *literal* (the `\x00` escape, not a raw NUL) — the
/// appended marker is spliced into module source, where a raw NUL byte would
/// truncate the C string and corrupt the parse.
const DONE_KEY_JS = "\\x00rt/done";
const SNAP_PREFIX = "\x00rt/snap/"; // get/set <name>: read/write a snapshot
const UPDATE_KEY = "\x00rt/update"; // get: "1" when running under --update

pub const RC_OK = 0;

/// One assertion's streamed outcome. `pass` is parsed from the top-level `pass`
/// field ONCE at capture (never re-derived from the raw text — a substring scan
/// would false-match a `"pass":true` nested inside the `detail` payload of a
/// FAILING assertion and report it green). `json` retains the full record for
/// the human report (name / detail).
pub const Assert = struct { json: []const u8, pass: bool };

/// The result of running one `_tests/*.mjs` file.
pub const FileResult = struct {
    path: []const u8,
    /// Streamed assertion outcomes, in order.
    asserts: []const Assert,
    /// The module evaluated to completion (reached the appended DONE marker).
    /// False ⇒ an uncaught error aborted it mid-file.
    completed: bool,
    /// The arena reactor's return code (`ARENA_RC_*`).
    rc: c_int,

    pub fn passed(self: FileResult) usize {
        var n: usize = 0;
        for (self.asserts) |as_| {
            if (as_.pass) n += 1;
        }
        return n;
    }
    pub fn failed(self: FileResult) usize {
        return self.asserts.len - self.passed();
    }
    /// A file is OK iff it completed and every streamed assertion passed.
    pub fn ok(self: FileResult) bool {
        return self.completed and self.failed() == 0;
    }
};

/// Parse the top-level `pass` boolean from one streamed assertion record.
/// Defaults to `false` (fail-safe) on a parse error or a missing/non-bool field.
fn parseAssertPass(a: std.mem.Allocator, json: []const u8) bool {
    var p = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return false;
    defer p.deinit(); // returns only a bool — safe to reclaim (no borrowed slices)
    if (p.value != .object) return false;
    const v = p.value.object.get("pass") orelse return false;
    return v == .bool and v.bool;
}

/// Per-test-file host state, handed to each responder via the ABI `user` ptr.
/// Lives for the duration of one file's run.
const Harness = struct {
    a: std.mem.Allocator,
    eng: *root.Engine,
    /// Scratch arena for sim runs — reset after each so folding a whole saga
    /// doesn't accumulate. The returned bundle is malloc-copied out first.
    sim_arena: *std.heap.ArenaAllocator,
    /// Explicit `--source-dir` override threaded into every `simulate` (wins
    /// over a world's inline `sources`); null when not passed.
    source_dir: ?[]const u8,
    /// The `rewind test [dir]` app dir — the source fallback used only when a
    /// world declares neither its own `sourceDir` nor inline `sources`.
    base_dir: ?[]const u8,
    /// Directory holding the test file, for resolving sibling `import`s.
    test_dir: []const u8,
    /// Running under `--update` — the library rewrites mismatched snapshots
    /// instead of failing them (read via `UPDATE_KEY`).
    update: bool,

    world_stash: ?[]const u8 = null,
    asserts: std.ArrayList(Assert) = .{},
    completed: bool = false,

    /// name → snapshot value, loaded from the file's `__snapshots__` sidecar and
    /// updated on `SNAP_PREFIX` set.
    snapshots: std.StringHashMapUnmanaged([]const u8) = .{},
    snap_dirty: bool = false,

    fn install(self: *Harness) void {
        arena_replay_set_host(&VTABLE, self);
    }
};

const VTABLE = hostmod.ReplayHost{
    .kv_get = &kvGet,
    .kv_set = &kvSet,
    .kv_delete = &kvDelete,
    .kv_prefix = &kvPrefix,
    .module_load = &moduleLoad,
};

fn harnessOf(user: ?*anyopaque) *Harness {
    return @ptrCast(@alignCast(user.?));
}

/// The responder-ownership `malloc`+copy — shared with the sim host.
const dupC = hostmod.dupC;

fn kvGet(
    key: [*c]const u8,
    key_len: c_int,
    out_outcome: [*c]c_int,
    out_val: [*c][*c]u8,
    out_val_len: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = harnessOf(user);
    const k = key[0..@intCast(key_len)];

    if (std.mem.eql(u8, k, RUN_KEY)) {
        // Run the stashed world on the sim reactor, return its bundle. This
        // NESTS a sim run inside the harness run: the sim host is installed for
        // the duration, so re-install the harness host before returning.
        const world_json = h.world_stash orelse {
            out_outcome.* = @intFromEnum(decode.KvOutcome.err);
            return 0;
        };
        var out = std.ArrayList(u8){};
        const sa = h.sim_arena.allocator();
        h.eng.simulate(sa, world_json, h.source_dir, h.base_dir, &out) catch |e| {
            // Surface the engine failure to the library as a bundle-shaped error
            // so the test sees a structured result rather than a thrown host op.
            out.clearRetainingCapacity();
            const msg = std.fmt.allocPrint(sa, "{{\"ok\":false,\"error\":{{\"message\":\"simulate failed: {s}\"}},\"effects\":[],\"response\":null}}", .{@errorName(e)}) catch "{\"ok\":false}";
            out.appendSlice(sa, msg) catch {};
        };
        h.install(); // re-take the host from the nested sim run
        out_val.* = dupC(out.items, false) orelse return -1;
        out_val_len.* = @intCast(out.items.len);
        out_outcome.* = @intFromEnum(decode.KvOutcome.ok);
        _ = h.sim_arena.reset(.retain_capacity);
        h.world_stash = null;
        return 0;
    }

    if (std.mem.eql(u8, k, UPDATE_KEY)) {
        if (h.update) {
            out_val.* = dupC("1", false) orelse return -1;
            out_val_len.* = 1;
            out_outcome.* = @intFromEnum(decode.KvOutcome.ok);
        } else {
            out_val.* = null;
            out_val_len.* = 0;
            out_outcome.* = @intFromEnum(decode.KvOutcome.not_found);
        }
        return 0;
    }

    if (std.mem.startsWith(u8, k, SNAP_PREFIX)) {
        const name = k[SNAP_PREFIX.len..];
        if (h.snapshots.get(name)) |v| {
            out_val.* = dupC(v, false) orelse return -1;
            out_val_len.* = @intCast(v.len);
            out_outcome.* = @intFromEnum(decode.KvOutcome.ok);
        } else {
            // No stored snapshot — the library treats not_found as "new".
            out_val.* = null;
            out_val_len.* = 0;
            out_outcome.* = @intFromEnum(decode.KvOutcome.not_found);
        }
        return 0;
    }

    // The harness body performs no ordinary kv reads.
    out_val.* = null;
    out_val_len.* = 0;
    out_outcome.* = @intFromEnum(decode.KvOutcome.not_found);
    return 0;
}

fn kvSet(
    key: [*c]const u8,
    key_len: c_int,
    val: [*c]const u8,
    val_len: c_int,
    out_outcome: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = harnessOf(user);
    const k = key[0..@intCast(key_len)];
    const v = val[0..@intCast(val_len)];

    if (std.mem.eql(u8, k, WORLD_KEY)) {
        h.world_stash = h.a.dupe(u8, v) catch return -1;
    } else if (std.mem.eql(u8, k, ASSERT_KEY)) {
        const j = h.a.dupe(u8, v) catch return -1;
        h.asserts.append(h.a, .{ .json = j, .pass = parseAssertPass(h.a, j) }) catch return -1;
    } else if (std.mem.eql(u8, k, DONE_KEY)) {
        h.completed = true;
    } else if (std.mem.startsWith(u8, k, SNAP_PREFIX)) {
        const name = h.a.dupe(u8, k[SNAP_PREFIX.len..]) catch return -1;
        const vc = h.a.dupe(u8, v) catch return -1;
        h.snapshots.put(h.a, name, vc) catch return -1;
        h.snap_dirty = true;
    }
    // Any other key: a stray harness-body write — ignore.
    out_outcome.* = 0;
    return 0;
}

fn kvDelete(
    key: [*c]const u8,
    key_len: c_int,
    out_outcome: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    _ = key;
    _ = key_len;
    _ = user;
    out_outcome.* = 0;
    return 0;
}

fn kvPrefix(
    prefix: [*c]const u8,
    prefix_len: c_int,
    cursor: [*c]const u8,
    cursor_len: c_int,
    limit: c_int,
    out_outcome: [*c]c_int,
    out_json: [*c][*c]u8,
    out_json_len: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    _ = prefix;
    _ = prefix_len;
    _ = cursor;
    _ = cursor_len;
    _ = limit;
    _ = user;
    // The harness body performs no kv.prefix scans — return an empty set.
    out_json.* = dupC("[]", true) orelse return -1;
    out_json_len.* = 2;
    out_outcome.* = 0;
    return 0;
}

fn moduleLoad(
    spec: [*c]const u8,
    spec_len: c_int,
    out_src: [*c][*c]u8,
    out_src_len: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = harnessOf(user);
    const s = spec[0..@intCast(spec_len)];

    if (std.mem.eql(u8, s, LIB_SPECIFIER)) {
        out_src.* = dupC(LIB_SOURCE, true) orelse return -1;
        out_src_len.* = @intCast(LIB_SOURCE.len);
        return 0;
    }
    // A sibling helper (`import "./_helpers.mjs"` / `"../lib/x.mjs"`) — resolve
    // against the test file's own directory, but CONFINE resolution to the app
    // deployment root (the parent of `_tests/`). Prod clamps module resolution
    // to the deployment root (package_resolver.resolveSpecifier), so an
    // over-popped `../` that escapes the app tree names a file prod could never
    // serve — refuse it rather than let the OS read outside the app. A missing
    // helper (or an escaping one) is a divergence (rc < 0).
    const app_root = std.fs.path.dirname(h.test_dir) orelse h.test_dir;
    const path = path_confine.confineUnderRoot(h.a, app_root, h.test_dir, s) orelse {
        std.log.warn("rewind test: import '{s}' escapes the app root '{s}' — refused (prod confines module resolution to the deployment root)", .{ s, app_root });
        return -6;
    };
    const bytes = std.fs.cwd().readFileAlloc(h.a, path, 8 << 20) catch return -6;
    out_src.* = dupC(bytes, true) orelse return -1;
    out_src_len.* = @intCast(bytes.len);
    return 0;
}

// ── the runner ──────────────────────────────────────────────────────────────

pub const Options = struct {
    /// Rewrite mismatched / new snapshots into the `__snapshots__` sidecars.
    update: bool = false,
    /// Explicit `--source-dir` override (wins over a world's inline `sources`);
    /// null when not passed.
    source_dir: ?[]const u8 = null,
    /// The `rewind test [dir]` app dir — the source fallback for worlds that
    /// declare neither `sourceDir` nor inline `sources`.
    base_dir: ?[]const u8 = null,
};

pub const Report = struct {
    files: []const FileResult,

    pub fn ok(self: Report) bool {
        for (self.files) |f| if (!f.ok()) return false;
        return true;
    }
};

/// Discover and run every `_tests/*.mjs` under `dir`, each in a fresh harness
/// run on the shared reactors. Files whose basename starts with `_` are helpers
/// (imported, not run). Returns a per-file `Report`; the caller prints and sets
/// the exit code.
pub fn runTests(gpa: std.mem.Allocator, dir: []const u8, opts: Options) !Report {
    // Both reactors are process-lived (see `root.Engine.deinit`): a run's
    // epilogue roots the handler surface on the base global, so freeing the
    // runtime mid-process would trip `JS_FreeRuntime`'s leak check. `rewind
    // test` is one-shot, so they are reclaimed at exit.
    const H = arena_reactor_new(8192, 8192) orelse return error.ArenaInit;
    // The harness reactor runs the `_tests/*.mjs` driver code (assertions,
    // world construction) in GC mode too, matching the sim reactor
    // — a driver that builds a large fixture world reclaims to peak-live-set
    // instead of OOMing the bump arena. `eng`'s sim reactor is GC via
    // `Engine.init`.
    arena_set_request_mode_r(H, 0);
    var eng = try root.Engine.init();

    const tests_dir = try std.fs.path.join(gpa, &.{ dir, "_tests" });
    var td = std.fs.cwd().openDir(tests_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.NoTestsDir,
        else => return e,
    };
    defer td.close();

    // Collect + sort test file names for a deterministic run order.
    var names = std.ArrayList([]const u8){};
    var it = td.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".mjs")) continue;
        if (std.mem.startsWith(u8, ent.name, "_")) continue; // helper, not a test
        try names.append(gpa, try gpa.dupe(u8, ent.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    var results = std.ArrayList(FileResult){};
    for (names.items) |name| {
        const res = try runOneFile(gpa, H, &eng, tests_dir, name, opts);
        try results.append(gpa, res);
    }
    return .{ .files = try results.toOwnedSlice(gpa) };
}

fn runOneFile(
    gpa: std.mem.Allocator,
    H: *root.ArenaReactor,
    eng: *root.Engine,
    tests_dir: []const u8,
    name: []const u8,
    opts: Options,
) !FileResult {
    // One arena per file — every allocation (asserts, snapshots, sim scratch) is
    // reclaimed wholesale after the file's result is copied to `gpa`.
    var arena = std.heap.ArenaAllocator.init(gpa);
    // NOTE: kept alive until after we dupe the result out (below).
    const a = arena.allocator();

    var sim_arena = std.heap.ArenaAllocator.init(gpa);
    defer sim_arena.deinit();

    const path = try std.fs.path.join(a, &.{ tests_dir, name });
    const source = std.fs.cwd().readFileAlloc(a, path, 8 << 20) catch |e| {
        arena.deinit();
        return e;
    };

    var h = Harness{
        .a = a,
        .eng = eng,
        .sim_arena = &sim_arena,
        .source_dir = opts.source_dir,
        .base_dir = opts.base_dir,
        .test_dir = tests_dir,
        .update = opts.update,
    };
    try loadSnapshots(a, tests_dir, name, &h);
    h.install();

    // Append a completion marker so an uncaught error mid-file is detectable
    // (the appended write never runs if the body throws at top level).
    const full = try std.fmt.allocPrintSentinel(a, "{s}\n;kv.set(\"{s}\", \"1\");\n", .{ source, DONE_KEY_JS }, 0);
    const name_z = try a.dupeZ(u8, name);
    const rc = arena_run_module_r(H, name_z.ptr, full.ptr);

    // The library only marks snapshots dirty in the allowed cases (a new
    // snapshot, or a mismatch under --update), so persist whenever dirty.
    if (h.snap_dirty) try writeSnapshots(a, tests_dir, name, &h);

    // Copy the result out to `gpa` (the per-file arena is about to be freed).
    var out_asserts = try gpa.alloc(Assert, h.asserts.items.len);
    for (h.asserts.items, 0..) |as_, i| out_asserts[i] = .{ .json = try gpa.dupe(u8, as_.json), .pass = as_.pass };
    const res = FileResult{
        .path = try gpa.dupe(u8, name),
        .asserts = out_asserts,
        .completed = h.completed,
        .rc = rc,
    };
    arena.deinit();
    return res;
}

/// `{tests_dir}/__snapshots__/{name}.json` → `{name: value, …}` into the map.
/// Each stored value is the library's stable-JSON serialization held as an
/// OPAQUE STRING (the sidecar double-encodes it), so it round-trips byte-exact
/// — never re-serialized through `std.json`, whose key order / number format
/// could differ from the library's and cause spurious mismatches.
fn loadSnapshots(a: std.mem.Allocator, tests_dir: []const u8, name: []const u8, h: *Harness) !void {
    const snap_path = try snapPath(a, tests_dir, name);
    const bytes = std.fs.cwd().readFileAlloc(a, snap_path, 8 << 20) catch return; // absent ⇒ empty
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return;
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        try h.snapshots.put(a, try a.dupe(u8, e.key_ptr.*), try a.dupe(u8, e.value_ptr.*.string));
    }
}

fn writeSnapshots(a: std.mem.Allocator, tests_dir: []const u8, name: []const u8, h: *Harness) !void {
    const dir_path = try std.fs.path.join(a, &.{ tests_dir, "__snapshots__" });
    std.fs.cwd().makePath(dir_path) catch {};

    // Emit keys sorted so the committed sidecar is deterministic (hash-map
    // iteration order would churn the file across runs / insertions).
    var keys = std.ArrayList([]const u8){};
    var kit = h.snapshots.keyIterator();
    while (kit.next()) |k| try keys.append(a, k.*);
    std.mem.sort([]const u8, keys.items, {}, lessThanStr);

    var buf = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
    const w = &aw.writer;
    try w.writeByte('{');
    for (keys.items, 0..) |key, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.Stringify.value(key, .{}, w);
        try w.writeByte(':');
        // The value is the library's stable-JSON held as an opaque string;
        // emit it as a JSON string literal (escaped) so it reloads byte-exact.
        try std.json.Stringify.value(h.snapshots.get(key).?, .{}, w);
    }
    try w.writeByte('}');
    try w.writeByte('\n');
    buf = aw.toArrayList();
    const snap_path = try snapPath(a, tests_dir, name);
    try std.fs.cwd().writeFile(.{ .sub_path = snap_path, .data = buf.items });
}

fn snapPath(a: std.mem.Allocator, tests_dir: []const u8, name: []const u8) ![]const u8 {
    const base = std.fs.path.stem(name);
    const file = try std.fmt.allocPrint(a, "{s}.json", .{base});
    return std.fs.path.join(a, &.{ tests_dir, "__snapshots__", file });
}

fn lessThanStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "lib source embeds and names its exports" {
    try testing.expect(std.mem.indexOf(u8, LIB_SOURCE, "export function scenario") != null);
    try testing.expect(std.mem.indexOf(u8, LIB_SOURCE, "export function expect") != null);
}

test "parseAssertPass reads the top-level pass, not a nested one" {
    const a = testing.allocator;
    try testing.expect(parseAssertPass(a, "{\"name\":\"x\",\"pass\":true}"));
    try testing.expect(!parseAssertPass(a, "{\"name\":\"x\",\"pass\":false}"));
    // A FAILING assertion whose detail contains a nested "pass":true must stay
    // a fail — a substring scan would report this green.
    try testing.expect(!parseAssertPass(a,
        "{\"name\":\"x\",\"pass\":false,\"detail\":{\"expected\":{\"pass\":true}}}"));
    try testing.expect(!parseAssertPass(a, "not json"));
}
