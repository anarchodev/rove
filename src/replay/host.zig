//! Native replay host — the input side of the arenajs replay ABI
//! (`qjs-arena-replay-bindings.h`), Phase 2 §2c.
//!
//! `arena_init` installs the replay bindings; the embedder registers a
//! `ReplayHost` whose responders serve the recorded tape. The kv channel is
//! READS-ONLY (`appendKv(.get)` / `appendKvPrefix` in `src/js/globals.zig` —
//! `set`/`delete` are never taped, they are handler OUTPUTS), so `kv_get` /
//! `kv_prefix` walk the decoded read cursor in recorded order (any op/key
//! mismatch is a divergence, the exact lever Phase 3's `simulate` reuses) while
//! `kv_set` / `kv_delete` are captured as the produced write-set. `module_load`
//! serves source by specifier (path), optionally overridden from a working-tree
//! `--source-dir` for "does my local change still satisfy this request?".
//!
//! Responder contract (from the header): return 0 ok / 1 not-installed /
//! 2 exhausted / <0 divergence; `out_outcome` is the JS-visible kv result
//! (0 ok / 1 not_found / 2 err). Byte-buffer out-params are malloc'd here and
//! free()d by the engine; `out_src` / `out_json` MUST be NUL-terminated (the
//! module / JSON parsers read one sentinel byte past `len`).

const std = @import("std");
const decode = @import("tape_decode.zig");

/// The C ABI struct (`arena_replay_host`). Field order + signatures mirror the
/// header exactly; a NULL responder reports "tape not installed" (code 1).
pub const ReplayHost = extern struct {
    kv_get: ?*const fn ([*c]const u8, c_int, [*c]c_int, [*c][*c]u8, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    kv_set: ?*const fn ([*c]const u8, c_int, [*c]const u8, c_int, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    kv_delete: ?*const fn ([*c]const u8, c_int, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    kv_prefix: ?*const fn ([*c]const u8, c_int, [*c]const u8, c_int, c_int, [*c]c_int, [*c][*c]u8, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
    module_load: ?*const fn ([*c]const u8, c_int, [*c][*c]u8, [*c]c_int, ?*anyopaque) callconv(.c) c_int,
};
extern fn arena_replay_set_host(host: *const ReplayHost, user: ?*anyopaque) void;

/// The sentinel key the replay epilogue writes its captured run output under.
/// The `kv_set` responder intercepts it (it is NOT a handler write) — the side
/// channel that extracts results without reaching the reactor's static context.
pub const OUTPUT_KEY = "__replay_output__";

pub const KvWrite = struct {
    op: enum { set, delete },
    key: []const u8,
    value: []const u8 = "",
};

/// How the kv read side resolves the world. `.tape` is replay's ordered cursor
/// over a captured RTAP tape (any op/key mismatch is a divergence). `.map` is
/// the declarative-sim mode: reads resolve order-independently against a
/// key→value map (`kv_map`), and `kv.prefix` scans that map — the world is
/// *authored*, so it carries no access order to verify against.
pub const Mode = enum { tape, map };

/// On-miss policy — the replay↔sim axis (`docs/plans/sim-test-framework.md`).
/// `.fail` refuses to invent (a missed read is a divergence — the replay
/// corner); `.resolve` returns `not_found` and records a typed hole (sim).
/// Only consulted in `.map` mode; the `.tape` cursor is always fail-loud.
pub const MissPolicy = enum { fail, resolve };

/// A typed hole — a read the declared world didn't supply. The calling surface
/// (CLI flag, UI form, an LLM) binds it; for now we report it on the bundle.
pub const Hole = struct { op: decode.KvOp, key: []const u8 };

/// `malloc`+copy matching the responder ownership contract (engine `free()`s
/// it). `nul` appends a trailing NUL for the buffers whose parser reads one
/// sentinel byte past `len` (`out_src`, `out_json`).
fn dupC(bytes: []const u8, nul: bool) ?[*c]u8 {
    const n = bytes.len + @as(usize, if (nul) 1 else 0);
    const p: [*c]u8 = @ptrCast(std.c.malloc(n) orelse return null);
    if (bytes.len != 0) @memcpy(p[0..bytes.len], bytes);
    if (nul) p[bytes.len] = 0;
    return p;
}

/// Per-replay host state, handed to each responder via the ABI `user` pointer.
/// Single-shot: one `Host` drives one `arena_run_module`.
pub const Host = struct {
    a: std.mem.Allocator,
    /// Read resolution strategy. `.tape` uses the ordered `kv` cursor below;
    /// `.map` uses `kv_map` + `miss` (declarative sim). Default `.tape` keeps
    /// the replay path byte-identical.
    mode: Mode = .tape,
    /// Recorded kv reads (`.get` / `.prefix`) in capture order. The cursor
    /// advances on each served read; a live read that doesn't match the entry
    /// at the cursor is a divergence. (`.tape` mode only.)
    kv: []const decode.KvEntry,
    kv_cursor: usize = 0,
    /// Declarative world: key→value map reads resolve against (`.map` mode).
    /// `kv.get` is a lookup; `kv.prefix` scans for matching keys.
    kv_map: std.StringHashMapUnmanaged([]const u8) = .{},
    /// What a missed `kv.get` does in `.map` mode (`.tape` is always fail-loud).
    miss: MissPolicy = .fail,
    /// Keys the world declares explicitly **absent** (recorded `not_found`
    /// reads), plus keys the handler `delete`s during the run. A miss on an
    /// absent key resolves to `not_found` with **NO hole** — a *known* absence,
    /// so `miss-policy=fail` reproduces a recording exactly. (`.map` mode.)
    absent: std.StringHashMapUnmanaged(void) = .{},
    /// Typed holes recorded when `.resolve` fills a missed read.
    holes: std.ArrayList(Hole) = .{},
    /// Handler-produced writes (`kv.set` / `kv.delete`), in order.
    writes: std.ArrayList(KvWrite) = .{},
    /// Captured `OUTPUT_KEY` payload (the run's parked result JSON).
    output: ?[]const u8 = null,
    /// Module source by specifier (path); the entry's imports resolve here.
    sources: std.StringHashMapUnmanaged([]const u8) = .{},
    /// When set, `module_load` reads `{source_dir}/{spec}` from the working
    /// tree instead of `sources` — the what-if lever for local changes.
    source_dir: ?[]const u8 = null,
    /// First divergence message, if any. Distinct from a handler-thrown error:
    /// a divergence means the replay asked for an input the capture never
    /// recorded (or the local source tree diverged).
    diverged: ?[]const u8 = null,

    pub fn install(self: *Host) void {
        arena_replay_set_host(&HOST_VTABLE, self);
    }

    fn setDiv(self: *Host, comptime fmt: []const u8, args: anytype) void {
        if (self.diverged != null) return; // keep the FIRST divergence
        self.diverged = std.fmt.allocPrint(self.a, fmt, args) catch "divergence (oom formatting detail)";
    }

    fn recordHole(self: *Host, op: decode.KvOp, key: []const u8) void {
        const kc = self.a.dupe(u8, key) catch return;
        self.holes.append(self.a, .{ .op = op, .key = kc }) catch {};
    }
};

const HOST_VTABLE = ReplayHost{
    .kv_get = &kvGet,
    .kv_set = &kvSet,
    .kv_delete = &kvDelete,
    .kv_prefix = &kvPrefix,
    .module_load = &moduleLoad,
};

fn hostOf(user: ?*anyopaque) *Host {
    return @ptrCast(@alignCast(user.?));
}

fn kvGet(
    key: [*c]const u8,
    key_len: c_int,
    out_outcome: [*c]c_int,
    out_val: [*c][*c]u8,
    out_val_len: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = hostOf(user);
    const k = key[0..@intCast(key_len)];
    if (h.mode == .map) {
        if (h.kv_map.get(k)) |v| {
            out_outcome.* = @intFromEnum(decode.KvOutcome.ok);
            out_val.* = dupC(v, false) orelse return -1;
            out_val_len.* = @intCast(v.len);
            return 0;
        }
        // A *known* absence (declared in `kvAbsent`, or deleted by the handler)
        // resolves to not_found with no hole — it's not an under-specified read.
        if (h.absent.contains(k)) {
            out_outcome.* = @intFromEnum(decode.KvOutcome.not_found);
            out_val.* = null;
            out_val_len.* = 0;
            return 0;
        }
        // A read the declared world doesn't supply: record the hole, then let
        // the miss policy decide — `.fail` refuses to invent (divergence),
        // `.resolve` answers `not_found` (the sim corner).
        h.recordHole(.get, k);
        if (h.miss == .fail) {
            h.setDiv("kv.get('{s}') has no value in the world — not recorded (replay) / not declared (sim) (miss-policy=fail)", .{k});
            return 2;
        }
        out_outcome.* = @intFromEnum(decode.KvOutcome.not_found);
        out_val.* = null;
        out_val_len.* = 0;
        return 0;
    }
    if (h.kv_cursor >= h.kv.len) {
        h.setDiv("kv.get('{s}') past end of recorded kv tape", .{k});
        return 2; // exhausted
    }
    const e = h.kv[h.kv_cursor];
    if (e.op != .get) {
        h.setDiv("kv.get('{s}') but tape expected a .{s} next", .{ k, @tagName(e.op) });
        return -3;
    }
    if (!std.mem.eql(u8, e.key, k)) {
        h.setDiv("kv.get('{s}') but tape recorded key '{s}'", .{ k, e.key });
        return -4;
    }
    h.kv_cursor += 1;
    out_outcome.* = @intFromEnum(e.outcome);
    if (e.outcome == .ok) {
        out_val.* = dupC(e.value, false) orelse return -1;
        out_val_len.* = @intCast(e.value.len);
    } else {
        out_val.* = null;
        out_val_len.* = 0;
    }
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
    const h = hostOf(user);
    const k = key[0..@intCast(key_len)];
    const v = val[0..@intCast(val_len)];
    if (std.mem.eql(u8, k, OUTPUT_KEY)) {
        h.output = h.a.dupe(u8, v) catch return -1;
    } else {
        const kc = h.a.dupe(u8, k) catch return -1;
        const vc = h.a.dupe(u8, v) catch return -1;
        h.writes.append(h.a, .{ .op = .set, .key = kc, .value = vc }) catch return -1;
        // Read-your-writes: a later get of this key in the same run sees the
        // value the handler just wrote (the kvexp overlay, in declarative form).
        // Reuses the writes[] dups — no second copy. (`.map` mode.)
        if (h.mode == .map) {
            h.kv_map.put(h.a, kc, vc) catch return -1;
            _ = h.absent.remove(kc);
        }
    }
    out_outcome.* = 0; // ok
    return 0;
}

fn kvDelete(
    key: [*c]const u8,
    key_len: c_int,
    out_outcome: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = hostOf(user);
    const kc = h.a.dupe(u8, key[0..@intCast(key_len)]) catch return -1;
    h.writes.append(h.a, .{ .op = .delete, .key = kc }) catch return -1;
    // Read-your-deletes: a later get sees not_found (a known absence, no hole).
    if (h.mode == .map) {
        _ = h.kv_map.remove(kc);
        h.absent.put(h.a, kc, {}) catch return -1;
    }
    out_outcome.* = 0; // ok
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
    _ = cursor;
    _ = cursor_len;
    _ = limit;
    const h = hostOf(user);
    const p = prefix[0..@intCast(prefix_len)];
    if (h.mode == .map) {
        // Scan the declared map for keys under the prefix, sorted for a
        // deterministic result. An empty match is a legitimate answer (the
        // world declares no such keys), so a prefix scan never holes/diverges.
        var keys = std.ArrayList([]const u8){};
        defer keys.deinit(h.a);
        var it = h.kv_map.iterator();
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv.key_ptr.*, p)) keys.append(h.a, kv.key_ptr.*) catch return -1;
        }
        std.mem.sort([]const u8, keys.items, {}, lessThanStr);
        var buf = std.ArrayList(u8){};
        defer buf.deinit(h.a);
        var aw = std.Io.Writer.Allocating.fromArrayList(h.a, &buf);
        const w = &aw.writer;
        w.writeByte('[') catch return -1;
        for (keys.items, 0..) |kk, i| {
            if (i != 0) w.writeByte(',') catch return -1;
            w.writeAll("{\"key\":") catch return -1;
            writeJsonString(w, kk) catch return -1;
            w.writeAll(",\"value\":") catch return -1;
            writeJsonString(w, h.kv_map.get(kk).?) catch return -1;
            w.writeByte('}') catch return -1;
        }
        w.writeByte(']') catch return -1;
        buf = aw.toArrayList();
        out_json.* = dupC(buf.items, true) orelse return -1;
        out_json_len.* = @intCast(buf.items.len);
        out_outcome.* = 0; // ok
        return 0;
    }
    if (h.kv_cursor >= h.kv.len) {
        h.setDiv("kv.prefix('{s}') past end of recorded kv tape", .{p});
        return 2;
    }
    const e = h.kv[h.kv_cursor];
    if (e.op != .prefix) {
        h.setDiv("kv.prefix('{s}') but tape expected a .{s} next", .{ p, @tagName(e.op) });
        return -3;
    }
    if (!std.mem.eql(u8, e.key, p)) {
        h.setDiv("kv.prefix('{s}') but tape recorded prefix '{s}'", .{ p, e.key });
        return -4;
    }
    h.kv_cursor += 1;
    // The binding parses `out_json` via JS_ParseJSON into the array of
    // {key, value} rows kv.prefix returns. Build it NUL-terminated.
    var buf = std.ArrayList(u8){};
    defer buf.deinit(h.a);
    var aw = std.Io.Writer.Allocating.fromArrayList(h.a, &buf);
    const w = &aw.writer;
    w.writeByte('[') catch return -1;
    for (e.results, 0..) |row, i| {
        if (i != 0) w.writeByte(',') catch return -1;
        w.writeAll("{\"key\":") catch return -1;
        writeJsonString(w, row.key) catch return -1;
        w.writeAll(",\"value\":") catch return -1;
        writeJsonString(w, row.value) catch return -1;
        w.writeByte('}') catch return -1;
    }
    w.writeByte(']') catch return -1;
    buf = aw.toArrayList();
    out_json.* = dupC(buf.items, true) orelse return -1;
    out_json_len.* = @intCast(buf.items.len);
    out_outcome.* = 0; // ok
    return 0;
}

fn moduleLoad(
    spec: [*c]const u8,
    spec_len: c_int,
    out_src: [*c][*c]u8,
    out_src_len: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = hostOf(user);
    const s = spec[0..@intCast(spec_len)];
    // Working-tree override: serve the local file so a changed handler can be
    // replayed against the recorded inputs. A missing local file IS a
    // divergence ("your tree doesn't have this module").
    if (h.source_dir) |dir| {
        const path = std.fs.path.join(h.a, &.{ dir, s }) catch return -1;
        const bytes = std.fs.cwd().readFileAlloc(h.a, path, 8 << 20) catch {
            h.setDiv("module '{s}' not found under --source-dir '{s}'", .{ s, dir });
            return -6;
        };
        out_src.* = dupC(bytes, true) orelse return -1;
        out_src_len.* = @intCast(bytes.len);
        return 0;
    }
    if (h.sources.get(s)) |src| {
        out_src.* = dupC(src, true) orelse return -1;
        out_src_len.* = @intCast(src.len);
        return 0;
    }
    h.setDiv("module '{s}' not in the pulled fixture sources", .{s});
    return -6;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
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

test "kv read cursor: ordered get hits + divergence on wrong key" {
    var h = Host{
        .a = testing.allocator,
        .kv = &.{
            .{ .op = .get, .outcome = .ok, .key = "user", .value = "ada" },
            .{ .op = .get, .outcome = .not_found, .key = "missing" },
        },
    };
    defer if (h.diverged) |d| testing.allocator.free(d);

    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;
    // entry 0: get user -> ok ada
    try testing.expectEqual(@as(c_int, 0), kvGet("user", 4, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@as(c_int, 0), outcome);
    try testing.expectEqualStrings("ada", val[0..@intCast(vlen)]);
    std.c.free(val);
    // entry 1: get the wrong key -> divergence (-4), cursor not advanced past
    try testing.expect(kvGet("elsewhere", 9, &outcome, &val, &vlen, &h) < 0);
    try testing.expect(h.diverged != null);
}

test "map mode: get resolves by key, order-independent" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    try map.put(a, "user/jess", "{\"name\":\"Jess\"}");
    try map.put(a, "config/rate", "10");
    var h = Host{ .a = a, .mode = .map, .kv = &.{}, .kv_map = map, .miss = .resolve };
    defer h.holes.deinit(a);

    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;
    // read config/rate first even though it was inserted second — map lookup
    try testing.expectEqual(@as(c_int, 0), kvGet("config/rate", 11, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.ok), outcome);
    try testing.expectEqualStrings("10", val[0..@intCast(vlen)]);
    std.c.free(val);
    try testing.expectEqual(@as(usize, 0), h.holes.items.len);
}

test "map mode: resolve miss → not_found + recorded hole; fail miss → divergence" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;

    // resolve: a missing key answers not_found and records a hole
    var hr = Host{ .a = a, .mode = .map, .kv = &.{}, .kv_map = map, .miss = .resolve };
    defer {
        for (hr.holes.items) |hole| a.free(hole.key);
        hr.holes.deinit(a);
    }
    try testing.expectEqual(@as(c_int, 0), kvGet("absent", 6, &outcome, &val, &vlen, &hr));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.not_found), outcome);
    try testing.expectEqual(@as(usize, 1), hr.holes.items.len);
    try testing.expectEqualStrings("absent", hr.holes.items[0].key);

    // fail: a missing key is a divergence (refuse to invent)
    var hf = Host{ .a = a, .mode = .map, .kv = &.{}, .kv_map = map, .miss = .fail };
    defer {
        for (hf.holes.items) |hole| a.free(hole.key);
        hf.holes.deinit(a);
        if (hf.diverged) |d| a.free(d);
    }
    try testing.expect(kvGet("absent", 6, &outcome, &val, &vlen, &hf) > 0);
    try testing.expect(hf.diverged != null);
}

test "map mode: prefix scans the declared map, sorted" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    try map.put(a, "orders/2", "b");
    try map.put(a, "orders/1", "a");
    try map.put(a, "users/9", "z");
    var h = Host{ .a = a, .mode = .map, .kv = &.{}, .kv_map = map, .miss = .resolve };
    defer h.holes.deinit(a);

    var outcome: c_int = -1;
    var json: [*c]u8 = null;
    var jlen: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), kvPrefix("orders/", 7, "", 0, 100, &outcome, &json, &jlen, &h));
    try testing.expectEqual(@as(c_int, 0), outcome);
    const got = json[0..@intCast(jlen)];
    try testing.expectEqualStrings(
        "[{\"key\":\"orders/1\",\"value\":\"a\"},{\"key\":\"orders/2\",\"value\":\"b\"}]",
        got,
    );
    std.c.free(json);
}

test "map mode: write-through overlay (read-your-writes) + kvAbsent" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    var absent = std.StringHashMapUnmanaged(void){};
    try map.put(a, "count", "1");
    try absent.put(a, "gone", {}); // declared explicitly absent
    var h = Host{ .a = a, .mode = .map, .kv = &.{}, .kv_map = map, .absent = absent, .miss = .fail };
    defer {
        for (h.writes.items) |wr| {
            a.free(wr.key);
            if (wr.value.len != 0) a.free(wr.value);
        }
        h.writes.deinit(a);
        h.kv_map.deinit(a);
        h.absent.deinit(a);
        for (h.holes.items) |hole| a.free(hole.key);
        h.holes.deinit(a);
        if (h.diverged) |d| a.free(d);
    }
    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;

    // read-your-writes: set then get returns the written value
    try testing.expectEqual(@as(c_int, 0), kvSet("count", 5, "2", 1, &outcome, &h));
    try testing.expectEqual(@as(c_int, 0), kvGet("count", 5, &outcome, &val, &vlen, &h));
    try testing.expectEqualStrings("2", val[0..@intCast(vlen)]);
    std.c.free(val);

    // a declared-absent key is not_found with NO hole, even under miss=fail
    try testing.expectEqual(@as(c_int, 0), kvGet("gone", 4, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.not_found), outcome);

    // delete then get → not_found, no hole, no divergence
    try testing.expectEqual(@as(c_int, 0), kvDelete("count", 5, &outcome, &h));
    try testing.expectEqual(@as(c_int, 0), kvGet("count", 5, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.not_found), outcome);

    try testing.expectEqual(@as(usize, 0), h.holes.items.len);
    try testing.expect(h.diverged == null);
}

test "kv writes captured; sentinel intercepted as output" {
    var h = Host{ .a = testing.allocator, .kv = &.{} };
    defer {
        for (h.writes.items) |wr| {
            testing.allocator.free(wr.key);
            if (wr.value.len != 0) testing.allocator.free(wr.value);
        }
        h.writes.deinit(testing.allocator);
        if (h.output) |o| testing.allocator.free(o);
    }
    var outcome: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), kvSet("seen", 4, "ada", 3, &outcome, &h));
    try testing.expectEqual(@as(c_int, 0), kvSet(OUTPUT_KEY, OUTPUT_KEY.len, "{\"ok\":1}", 8, &outcome, &h));
    try testing.expectEqual(@as(usize, 1), h.writes.items.len);
    try testing.expectEqualStrings("seen", h.writes.items[0].key);
    try testing.expectEqualStrings("ada", h.writes.items[0].value);
    try testing.expect(h.output != null);
    try testing.expectEqualStrings("{\"ok\":1}", h.output.?);
}
