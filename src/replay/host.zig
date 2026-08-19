// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Native replay/sim host — the input side of the arenajs replay ABI
//! (`qjs-arena-replay-bindings.h`).
//!
//! `arena_init` installs the replay bindings; the embedder registers a `Host`
//! whose responders serve a **closed-world** `world.json` (`world.zig`). KV
//! reads resolve BY KEY against `kv_map` (order-independent — an authored world
//! carries no access order to verify against): `kv_get` of a key not in the map
//! is `not_found` (never a divergence), `kv_prefix` scans the map (cursor +
//! limit). `kv_set` / `kv_delete` are handler OUTPUTS — captured as the
//! write-set AND folded back into `kv_map` (read-your-writes overlay).
//! `module_load` serves source by specifier (path), optionally overridden from a
//! working-tree `--source-dir` for "does my local change still satisfy this
//! request?" — a module the tree/fixture lacks IS a divergence.
//!
//! Responder contract (from the header): return 0 ok / 1 not-installed /
//! 2 exhausted / <0 divergence; `out_outcome` is the JS-visible kv result
//! (0 ok / 1 not_found / 2 err). Byte-buffer out-params are malloc'd here and
//! free()d by the engine; `out_src` / `out_json` MUST be NUL-terminated (the
//! module / JSON parsers read one sentinel byte past `len`).

const std = @import("std");
const decode = @import("tape_decode.zig");
const path_confine = @import("path_confine.zig");
const guards = @import("rove-binding").guards;

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

/// The rove-side mirror of the registered replay host. The common kv binding
/// (`kv_binding.zig`) dispatches through THIS pair exactly the way arenajs's
/// own kv binding dispatches through its static copy — the indirection is
/// what keeps the two host implementations (this run host and the rewind-test
/// harness's, which re-takes the host around nested sim runs) polymorphic
/// under one registered JS surface. Every installer goes through `setHost`,
/// so the mirror cannot drift from what arenajs sees.
pub var active_vtable: ?*const ReplayHost = null;
pub var active_user: ?*anyopaque = null;

/// Bumped on every install — per-run state keyed on it (the kv delegate's
/// subscription-marker dedup) resets when a new host takes over.
pub var generation: u64 = 0;

pub fn setHost(vt: *const ReplayHost, user: ?*anyopaque) void {
    active_vtable = vt;
    active_user = user;
    generation +%= 1;
    arena_replay_set_host(vt, user);
}

/// The poison door (the divergence model of the engine-parity epic): a
/// captured-world read the tape cannot answer records its verdict here and
/// the read RETURNS ABSENT — nothing is thrown at the read site, so a
/// handler cannot `catch` a divergence and keep running on fiction
/// invisibly. The uncatchable interrupt (`root.zig` simInterruptHandler)
/// brakes the run once poisoned, and the driver reports from this flag
/// POST-RUN regardless — a run that completes before the next interrupt
/// poll still reports diverged. Only the sim/replay run host can be
/// poisoned; under the rewind-test harness host this is a no-op (the
/// harness runs no captured worlds).
pub fn poisonActive(what: []const u8) void {
    if (active_vtable != &HOST_VTABLE) return;
    const h: *Host = @ptrCast(@alignCast(active_user orelse return));
    h.setDiv(
        "REPLAY DIVERGENCE: {s} was read by the handler but is not on the capture tape — the handler observed an input the original run never read",
        .{what},
    );
}

/// Whether the active run host replays a CAPTURE's outcomes: the kv binding
/// consults the recorded refusals and never re-decides the rules — the tape
/// stays faithful to the rules that were live when it was cut.
pub fn activeReplaysOutcomes() bool {
    if (active_vtable != &HOST_VTABLE) return false;
    const h: *Host = @ptrCast(@alignCast(active_user orelse return false));
    return h.captured;
}

/// The refusal CODE the capture recorded for this write, if any. `op_ch` is
/// 's' (set) / 'd' (delete).
pub fn activeTapedRefusal(op_ch: u8, key: []const u8) ?[]const u8 {
    if (active_vtable != &HOST_VTABLE) return null;
    const h: *Host = @ptrCast(@alignCast(active_user orelse return null));
    if (h.refusals.count() == 0) return null;
    var buf: [300]u8 = undefined;
    if (key.len + 1 > buf.len) return null; // keys are ≤256 by the capture's own rules
    buf[0] = op_ch;
    @memcpy(buf[1 .. 1 + key.len], key);
    return h.refusals.get(buf[0 .. 1 + key.len]);
}

/// The active run's spent write budget, and the charge for one write. Host
/// state rather than delegate state because the delegate is constructed per
/// call; offline, one run is one activation, so these ARE the activation's
/// slice (`reserved.KV_WRITES_MAX` / `KV_WRITE_BYTES_MAX`, enforced by the
/// shared guard so a sim refuses exactly where prod does).
pub fn activeWriteBudget() guards.WriteBudget {
    const h: *Host = @ptrCast(@alignCast(active_user orelse return .{}));
    if (active_vtable != &HOST_VTABLE) return .{};
    return .{ .ops = h.write_ops, .bytes = h.write_bytes };
}

pub fn noteActiveWrite(bytes: usize) void {
    if (active_vtable != &HOST_VTABLE) return;
    const h: *Host = @ptrCast(@alignCast(active_user orelse return));
    h.write_ops += 1;
    h.write_bytes += bytes;
}

/// `Host`-side twin of `activeElidedRead` for the responders, which already
/// hold the host pointer.
fn elidedFor(h: *Host, op_ch: u8, key: []const u8) ?u64 {
    if (h.elided.count() == 0) return null;
    var buf: [300]u8 = undefined;
    if (key.len + 1 > buf.len) return null;
    buf[0] = op_ch;
    @memcpy(buf[1 .. 1 + key.len], key);
    return h.elided.get(buf[0 .. 1 + key.len]);
}

/// The byte count the capture elided for this read, if any. `op_ch` is 'g'
/// (get) / 'p' (prefix). A `prefix` hit matches the whole prefix, not one
/// page: a scan whose recorded page was dropped cannot be reconstructed from
/// the map at any cursor, so every scan of it must refuse. Over-broad on
/// purpose — the wrong direction here is answering, not refusing.
pub fn activeElidedRead(op_ch: u8, key: []const u8) ?u64 {
    if (active_vtable != &HOST_VTABLE) return null;
    const h: *Host = @ptrCast(@alignCast(active_user orelse return null));
    if (h.elided.count() == 0) return null;
    var buf: [300]u8 = undefined;
    if (key.len + 1 > buf.len) return null; // keys are ≤256 by the capture's own rules
    buf[0] = op_ch;
    @memcpy(buf[1 .. 1 + key.len], key);
    return h.elided.get(buf[0 .. 1 + key.len]);
}

/// Whether the active run host carries a divergence verdict — the interrupt
/// handler's second trigger (`return poisoned || over_budget`).
pub fn activePoisoned() bool {
    if (active_vtable != &HOST_VTABLE) return false;
    const h: *Host = @ptrCast(@alignCast(active_user orelse return false));
    return h.diverged != null;
}

/// The sentinel key the replay epilogue writes its captured run output under.
/// The `kv_set` responder intercepts it (it is NOT a handler write) — the side
/// channel that extracts results without reaching the reactor's static context.
pub const OUTPUT_KEY = "__replay_output__";

pub const KvWrite = struct {
    op: enum { set, delete },
    key: []const u8,
    value: []const u8 = "",
};

/// `malloc`+copy matching the responder ownership contract (engine `free()`s
/// it). `nul` appends a trailing NUL for the buffers whose parser reads one
/// sentinel byte past `len` (`out_src`, `out_json`). Shared with the harness
/// host (`harness.zig`), which serves the same ABI.
pub fn dupC(bytes: []const u8, nul: bool) ?[*c]u8 {
    const n = bytes.len + @as(usize, if (nul) 1 else 0);
    const p: [*c]u8 = @ptrCast(std.c.malloc(n) orelse return null);
    if (bytes.len != 0) @memcpy(p[0..bytes.len], bytes);
    if (nul) p[bytes.len] = 0;
    return p;
}

/// Per-run host state, handed to each responder via the ABI `user` pointer.
/// Single-shot: one `Host` drives one `arena_run_module`.
pub const Host = struct {
    a: std.mem.Allocator,
    /// Closed-world key→value store reads resolve against: `kv.get` of a key not
    /// in the map is `not_found`; `kv.prefix` scans the map (cursor + limit
    /// honored). `kv.set`/`delete` update it in place (read-your-writes /
    /// read-your-deletes).
    kv_map: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Handler-produced writes (`kv.set` / `kv.delete`), in order.
    writes: std.ArrayList(KvWrite) = .{},
    /// Captured `OUTPUT_KEY` payload (the run's parked result JSON).
    output: ?[]const u8 = null,
    /// Module source by specifier (path); the entry's imports resolve here.
    sources: std.StringHashMapUnmanaged([]const u8) = .{},
    /// When set, `module_load` reads `{source_dir}/{spec}` from the working
    /// tree instead of `sources` — the what-if lever for local changes.
    source_dir: ?[]const u8 = null,
    /// This run's spent write budget (see `activeWriteBudget`). Per Host, so
    /// a fresh run starts with a fresh allowance.
    write_ops: u32 = 0,
    write_bytes: usize = 0,
    /// First divergence message, if any. Two producers: `module_load` (a
    /// module the source tree / fixture lacks) and the poison door
    /// (`poisonActive` — a captured-world request-surface read the tape
    /// cannot answer). Distinct from a handler-thrown error.
    diverged: ?[]const u8 = null,
    /// The world was transcoded from a CAPTURE → the kv binding replays
    /// outcomes instead of re-deciding the rules (`activeReplaysOutcomes`).
    captured: bool = false,
    /// Guard refusals the capture recorded, keyed `"s"/"d" ++ key` → the
    /// refusal CODE. A hit replays the refusal; on a captured world a write
    /// with NO entry succeeded at capture and proceeds unguarded.
    refusals: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Reads whose values the capture's kv budget dropped
    /// (`world.KvElided`), keyed `"g"/"p" ++ key` → the lost byte count.
    /// A hit is a REFUSAL, not an answer: the closed world's miss rule
    /// (absent ⇒ `not_found`) is exactly the wrong answer here, because the
    /// live run read real data. The kv binding poisons the run instead.
    elided: std.StringHashMapUnmanaged(u64) = .{},

    pub fn install(self: *Host) void {
        setHost(&HOST_VTABLE, self);
    }

    fn setDiv(self: *Host, comptime fmt: []const u8, args: anytype) void {
        if (self.diverged != null) return; // keep the FIRST divergence
        self.diverged = std.fmt.allocPrint(self.a, fmt, args) catch "divergence (oom formatting detail)";
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
    // A read the capture resolved but did not keep. The closed world's miss
    // rule would answer `not_found`, which is the one answer that is certainly
    // wrong: the live run read real data here. Record the divergence and let
    // the interrupt brake the run — the value is unrecoverable, so there is
    // nothing to serve.
    if (elidedFor(h, 'g', k)) |lost| {
        h.setDiv(
            "kv.get(\"{s}\") — the capture elided this value ({d} bytes over the " ++
                "activation's kv budget), so this run cannot be replayed against it",
            .{ k, lost },
        );
        out_outcome.* = @intFromEnum(decode.KvOutcome.elided);
        out_val.* = null;
        out_val_len.* = 0;
        return 0;
    }
    if (h.kv_map.get(k)) |v| {
        out_outcome.* = @intFromEnum(decode.KvOutcome.ok);
        out_val.* = dupC(v, false) orelse return -1;
        out_val_len.* = @intCast(v.len);
        return 0;
    }
    // Closed world: a key not in the map is `not_found` — a legitimate answer,
    // not a divergence. The effect log records the read (present false);
    // faithfulness lives at the output (the `expected` matcher).
    out_outcome.* = @intFromEnum(decode.KvOutcome.not_found);
    out_val.* = null;
    out_val_len.* = 0;
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
        // Reuses the writes[] dups — no second copy.
        h.kv_map.put(h.a, kc, vc) catch return -1;
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
    // Read-your-deletes: drop from the map so a later get is not_found.
    _ = h.kv_map.remove(kc);
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
    const h = hostOf(user);
    const p = prefix[0..@intCast(prefix_len)];
    const cur = cursor[0..@intCast(cursor_len)]; // "" = from start; else strictly-greater
    // A scan whose recorded page the capture's kv budget dropped. The rows are
    // simply not in the map, so reconstructing the scan would produce a SHORT
    // page and present it as complete. Refuse the run instead; the empty array
    // below is only what the braking run unwinds through.
    if (elidedFor(h, 'p', p)) |lost| {
        h.setDiv(
            "kv.prefix(\"{s}\") — the capture elided this page ({d} row bytes over " ++
                "the activation's kv budget), so this run cannot be replayed against it",
            .{ p, lost },
        );
    }
    // Reconstruct the scan from the closed-world map: keys under the prefix,
    // sorted, strictly after `cursor`, capped at `limit`. The map holds the
    // foreign matches; the handler's own writes are refilled by re-execution
    // (kvSet → kv_map), so no separate recorded rows are needed. An empty match
    // is a legitimate answer (a prefix scan never holes/diverges).
    var keys = std.ArrayList([]const u8){};
    defer keys.deinit(h.a);
    var it = h.kv_map.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (!std.mem.startsWith(u8, k, p)) continue;
        if (cur.len != 0 and std.mem.order(u8, k, cur) != .gt) continue; // strictly > cursor
        keys.append(h.a, k) catch return -1;
    }
    std.mem.sort([]const u8, keys.items, {}, lessThanStr);
    // Match prod's page bounds (globals.zig KV_PREFIX_DEFAULT/KV_PREFIX_MAX):
    // an omitted / non-positive limit defaults to 100, and any request is
    // capped at 1000. Without this the closed-world scan returns every match,
    // so a pagination loop written against the sim silently truncates live.
    const KV_PREFIX_DEFAULT: usize = 100;
    const KV_PREFIX_MAX: usize = 1000;
    const cap: usize = if (limit > 0)
        @min(@as(usize, @intCast(limit)), KV_PREFIX_MAX)
    else
        KV_PREFIX_DEFAULT;
    const n: usize = @min(cap, keys.items.len);
    // The binding parses `out_json` via JS_ParseJSON into the array of
    // {key, value} rows kv.prefix returns. Build it NUL-terminated.
    var buf = std.ArrayList(u8){};
    defer buf.deinit(h.a);
    var aw = std.Io.Writer.Allocating.fromArrayList(h.a, &buf);
    const w = &aw.writer;
    w.writeByte('[') catch return -1;
    for (keys.items[0..n], 0..) |kk, i| {
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

fn moduleLoad(
    spec: [*c]const u8,
    spec_len: c_int,
    out_src: [*c][*c]u8,
    out_src_len: [*c]c_int,
    user: ?*anyopaque,
) callconv(.c) c_int {
    const h = hostOf(user);
    const s = spec[0..@intCast(spec_len)];
    // Content-addressed package modules (`/pkg/<hash>/…`, issue #50) live ONLY
    // inline in the world's package sources — they have no on-disk home. Serve
    // them from the `sources` map even under a working-tree `--source-dir`
    // override (which otherwise reads app modules from disk); else the offline
    // resolver would look for `{source_dir}/pkg/<hash>/…` and diverge.
    if (std.mem.startsWith(u8, s, "/pkg/")) {
        if (h.sources.get(s)) |src| {
            out_src.* = dupC(src, true) orelse return -1;
            out_src_len.* = @intCast(src.len);
            return 0;
        }
        h.setDiv("package module '{s}' not in the world's package sources", .{s});
        return -6;
    }
    // Working-tree override: serve the local file so a changed handler can be
    // replayed against the recorded inputs. A missing local file IS a
    // divergence ("your tree doesn't have this module").
    if (h.source_dir) |dir| {
        // Confine to the deployment root — prod clamps module resolution there
        // (package_resolver.resolveSpecifier), so an over-popped `../` that
        // escapes `--source-dir` names a file prod could never serve.
        const path = path_confine.confineUnderRoot(h.a, dir, dir, s) orelse {
            h.setDiv("module '{s}' escapes --source-dir '{s}' — refused (prod confines resolution to the deployment root)", .{ s, dir });
            return -6;
        };
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

test "map mode: get resolves by key, order-independent" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    try map.put(a, "user/jess", "{\"name\":\"Jess\"}");
    try map.put(a, "config/rate", "10");
    var h = Host{ .a = a, .kv_map = map };

    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;
    // read config/rate first even though it was inserted second — map lookup
    try testing.expectEqual(@as(c_int, 0), kvGet("config/rate", 11, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.ok), outcome);
    try testing.expectEqualStrings("10", val[0..@intCast(vlen)]);
    std.c.free(val);
}

test "map mode: closed world — a missing key is not_found, never a divergence" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;

    var h = Host{ .a = a, .kv_map = map };
    try testing.expectEqual(@as(c_int, 0), kvGet("absent", 6, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.not_found), outcome);
    try testing.expect(h.diverged == null);
}

test "elided read: refused, never answered as absent" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    var elided = std.StringHashMapUnmanaged(u64){};
    defer elided.deinit(a);
    // "g" ++ key — the capture recorded this read and dropped its value.
    try elided.put(a, "gbig/blob", 900_000);
    var h = Host{ .a = a, .kv_map = map, .elided = elided };
    defer if (h.diverged) |d| a.free(d);

    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), kvGet("big/blob", 8, &outcome, &val, &vlen, &h));

    // The closed world's miss rule (`not_found`) is the one answer that is
    // certainly wrong here: the live run read 900 KB of real data.
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.elided), outcome);
    try testing.expect(h.diverged != null);
    try testing.expect(std.mem.indexOf(u8, h.diverged.?, "big/blob") != null);
    try testing.expect(std.mem.indexOf(u8, h.diverged.?, "900000") != null);
}

test "elided page: every scan of that prefix refuses" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    // A row the map DOES hold — a short page would look like a complete scan.
    try map.put(a, "p/1", "kept");
    var elided = std.StringHashMapUnmanaged(u64){};
    defer elided.deinit(a);
    try elided.put(a, "pp/", 400_000);
    var h = Host{ .a = a, .kv_map = map, .elided = elided };
    defer if (h.diverged) |d| a.free(d);

    var outcome: c_int = -1;
    var json: [*c]u8 = null;
    var jlen: c_int = -1;
    try testing.expectEqual(
        @as(c_int, 0),
        kvPrefix("p/", 2, "", 0, 100, &outcome, &json, &jlen, &h),
    );
    if (json != null) std.c.free(json);
    try testing.expect(h.diverged != null);
    try testing.expect(std.mem.indexOf(u8, h.diverged.?, "kv.prefix") != null);
}

test "map mode: prefix scans the declared map, sorted (cursor + limit honored)" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    defer map.deinit(a);
    try map.put(a, "orders/2", "b");
    try map.put(a, "orders/1", "a");
    try map.put(a, "orders/3", "c");
    try map.put(a, "users/9", "z");
    var h = Host{ .a = a, .kv_map = map };

    var outcome: c_int = -1;
    var json: [*c]u8 = null;
    var jlen: c_int = -1;
    // limit 2 → first two, sorted; users/9 excluded (not under the prefix)
    try testing.expectEqual(@as(c_int, 0), kvPrefix("orders/", 7, "", 0, 2, &outcome, &json, &jlen, &h));
    try testing.expectEqual(@as(c_int, 0), outcome);
    try testing.expectEqualStrings(
        "[{\"key\":\"orders/1\",\"value\":\"a\"},{\"key\":\"orders/2\",\"value\":\"b\"}]",
        json[0..@intCast(jlen)],
    );
    std.c.free(json);
    // cursor "orders/2" → strictly-greater keys only
    try testing.expectEqual(@as(c_int, 0), kvPrefix("orders/", 7, "orders/2", 8, 0, &outcome, &json, &jlen, &h));
    try testing.expectEqualStrings("[{\"key\":\"orders/3\",\"value\":\"c\"}]", json[0..@intCast(jlen)]);
    std.c.free(json);
}

test "map mode: write-through overlay (read-your-writes / read-your-deletes)" {
    const a = testing.allocator;
    var map = std.StringHashMapUnmanaged([]const u8){};
    try map.put(a, "count", "1");
    var h = Host{ .a = a, .kv_map = map };
    defer {
        for (h.writes.items) |wr| {
            a.free(wr.key);
            if (wr.value.len != 0) a.free(wr.value);
        }
        h.writes.deinit(a);
        h.kv_map.deinit(a);
    }
    var outcome: c_int = -1;
    var val: [*c]u8 = null;
    var vlen: c_int = -1;

    // read-your-writes: set then get returns the written value
    try testing.expectEqual(@as(c_int, 0), kvSet("count", 5, "2", 1, &outcome, &h));
    try testing.expectEqual(@as(c_int, 0), kvGet("count", 5, &outcome, &val, &vlen, &h));
    try testing.expectEqualStrings("2", val[0..@intCast(vlen)]);
    std.c.free(val);

    // read-your-deletes: delete then get → not_found, no divergence
    try testing.expectEqual(@as(c_int, 0), kvDelete("count", 5, &outcome, &h));
    try testing.expectEqual(@as(c_int, 0), kvGet("count", 5, &outcome, &val, &vlen, &h));
    try testing.expectEqual(@intFromEnum(decode.KvOutcome.not_found), outcome);
    try testing.expect(h.diverged == null);
}

test "kv writes captured; sentinel intercepted as output" {
    var h = Host{ .a = testing.allocator };
    defer {
        for (h.writes.items) |wr| {
            testing.allocator.free(wr.key);
            if (wr.value.len != 0) testing.allocator.free(wr.value);
        }
        h.writes.deinit(testing.allocator);
        // kvSet folds each write into kv_map too (reusing the writes[] dups —
        // no second copy), so free only the map's backing, not its values.
        h.kv_map.deinit(testing.allocator);
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
