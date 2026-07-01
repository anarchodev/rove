//! Declarative world parser (Phase 12 — `docs/plans/sim-test-framework.md`,
//! "The model — one run, parameterized").
//!
//! A *world* is everything one activation reads: the trigger/request surface,
//! the KV readset, and the deterministic seeds. A **recording** is a world that
//! was *captured* (the base64 RTAP tape `rewind pull` writes); a **fixture** is
//! a world that was *authored* — same shape, different source. This module
//! parses the authored form: a plain, human-/LLM-writable JSON document, e.g.
//!
//! ```json
//! {
//!   "entry": "index.mjs",
//!   "activation": "inbound",
//!   "request": {
//!     "method": "POST", "path": "/api/orders", "host": "shop.example",
//!     "headers": { "content-type": "application/json" },
//!     "body": { "item": "book" }, "ip": "203.0.113.7"
//!   },
//!   "kv": { "user/jess": { "name": "Jess" }, "config/rate": "10" },
//!   "seed": 123, "now_ms": 1700000000000, "missPolicy": "resolve"
//! }
//! ```
//!
//! KV is a key→value **map** (not an ordered tape) — an authored world carries
//! no access order to verify against, so `runWorld` resolves reads against the
//! map order-independently. Non-string values (in `kv`, `request.body`, and
//! header values) are JSON-stringified, since KV/body are byte strings the
//! handler parses itself — letting an author write `{ "name": "Jess" }` instead
//! of a hand-escaped string.
//!
//! Strings borrow the caller's parsed `std.json.Value`; the caller MUST keep it
//! alive for the lifetime of the returned `World`. Slices + stringified values
//! are allocated from `a`.

const std = @import("std");
const host = @import("host.zig");

pub const Header = struct { name: []const u8, value: []const u8 };
pub const KvPair = struct { key: []const u8, value: []const u8 };
pub const Source = struct { path: []const u8, kind: []const u8, source: []const u8 };
/// The recorded run's observable output — for the output-level faithfulness
/// check (`status_match`), the honest place fidelity lives (not per-read).
pub const Recorded = struct {
    status: ?i64 = null,
    console: ?[]const u8 = null,
    exception: ?[]const u8 = null,
};

pub const World = struct {
    entry: []const u8 = "index.mjs",
    activation: []const u8 = "inbound",
    /// The export to invoke. For a callback (a fetch result, a `{to}`, an
    /// `onResult`) this is the *resolved* export name — the runtime doesn't
    /// derive it from the kind (see `architecture/replay-and-sim.md` §2). When
    /// null, `runWorld` falls back to the conventional export for the kind.
    export_name: ?[]const u8 = null,
    method: []const u8 = "GET",
    path: []const u8 = "/",
    host: []const u8 = "",
    headers: []const Header = &.{},
    /// Present iff the world declares a body (handler reads then resolve). For
    /// an `inbound` activation this is the request body; for a fetch-result
    /// activation it is the *response* body (delivered on `request.body`).
    body: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    /// The KV readset as a key→value map.
    kv: []const KvPair = &.{},
    /// Keys explicitly declared **absent** — a read resolves to `not_found`
    /// with no hole (so `miss-policy=fail` reproduces a recording's not-found
    /// reads). `export-fixture` fills this from the recorded not-found reads.
    kv_absent: []const []const u8 = &.{},
    /// The recorded run's output, for the `status_match` faithfulness check.
    recorded: ?Recorded = null,
    seed: u64 = 0,
    now_ms: u64 = 0,
    miss: host.MissPolicy = .resolve,
    /// Inline handler sources (path/kind/source); empty when `--source-dir`
    /// serves the working tree instead.
    sources: []const Source = &.{},

    // ── non-inbound activation surface (`architecture/replay-and-sim.md` §3) ──
    /// The threaded `Ctx` → `request.ctx`. JSON text (any value). `undefined`
    /// on the first activation of a chain.
    ctx_json: ?[]const u8 = null,
    /// `request.activation.*` metadata bag (wakes / msg / error / attempts / …).
    /// JSON text.
    activation_json: ?[]const u8 = null,
    /// The flattened fetch/callback result surface — top-level on `request`.
    status: ?i64 = null,
    ok: ?bool = null,
    done: ?bool = null,
    fetch_id: ?[]const u8 = null,
    chunk_seq: ?i64 = null,
};

pub const Error = error{BadWorld} || std.mem.Allocator.Error;

/// Extract a `World` from an already-parsed JSON value. `a` should be an arena
/// (the slices are never individually freed).
pub fn fromValue(a: std.mem.Allocator, root: std.json.Value) Error!World {
    if (root != .object) return Error.BadWorld;
    const obj = root.object;

    var w = World{};
    if (jStr(obj, "entry")) |s| w.entry = s;
    if (jStr(obj, "activation")) |s| w.activation = s;
    if (jStr(obj, "export")) |s| w.export_name = s;
    if (obj.get("ctx")) |cv| {
        if (cv != .null) w.ctx_json = try jsonText(a, cv);
    }
    if (jStr(obj, "missPolicy")) |s| {
        if (std.mem.eql(u8, s, "fail")) {
            w.miss = .fail;
        } else if (std.mem.eql(u8, s, "resolve") or std.mem.eql(u8, s, "not_found")) {
            w.miss = .resolve;
        } else return Error.BadWorld;
    }
    w.seed = jU64(obj, "seed") orelse 0;
    w.now_ms = jU64(obj, "now_ms") orelse 0;

    // ── request surface ──
    if (obj.get("request")) |rv| {
        if (rv != .object) return Error.BadWorld;
        const r = rv.object;
        if (jStr(r, "method")) |s| w.method = s;
        if (jStr(r, "path")) |s| w.path = s;
        if (jStr(r, "host")) |s| w.host = s;
        if (jStr(r, "ip")) |s| w.ip = s;
        if (r.get("body")) |bv| {
            if (bv != .null) w.body = try valueToStr(a, bv);
        }
        // Flattened fetch/callback result surface (`request.status` etc.).
        w.status = jInt(r, "status");
        if (r.get("ok")) |v| {
            if (v == .bool) w.ok = v.bool;
        }
        if (r.get("done")) |v| {
            if (v == .bool) w.done = v.bool;
        }
        if (jStr(r, "fetchId")) |s| w.fetch_id = s;
        w.chunk_seq = jInt(r, "chunkSeq");
        // `request.activation.*` metadata bag.
        if (r.get("activation")) |av| {
            if (av != .null) w.activation_json = try jsonText(a, av);
        }
        if (r.get("headers")) |hv| {
            if (hv != .object) return Error.BadWorld;
            var hs = std.ArrayList(Header){};
            var it = hv.object.iterator();
            while (it.next()) |e| {
                try hs.append(a, .{ .name = e.key_ptr.*, .value = try valueToStr(a, e.value_ptr.*) });
            }
            w.headers = try hs.toOwnedSlice(a);
        }
    }

    // ── kv readset (map) ──
    if (obj.get("kv")) |kv| {
        if (kv != .object) return Error.BadWorld;
        var ps = std.ArrayList(KvPair){};
        var it = kv.object.iterator();
        while (it.next()) |e| {
            try ps.append(a, .{ .key = e.key_ptr.*, .value = try valueToStr(a, e.value_ptr.*) });
        }
        w.kv = try ps.toOwnedSlice(a);
    }

    // ── explicitly-absent keys ──
    if (obj.get("kvAbsent")) |ka| {
        if (ka != .array) return Error.BadWorld;
        var ks = std.ArrayList([]const u8){};
        for (ka.array.items) |e| {
            if (e == .string) try ks.append(a, e.string);
        }
        w.kv_absent = try ks.toOwnedSlice(a);
    }

    // ── recorded output (for status_match) ──
    if (obj.get("recorded")) |rv| {
        if (rv == .object) {
            const r = rv.object;
            w.recorded = .{
                .status = jInt(r, "status"),
                .console = jStr(r, "console"),
                .exception = jStr(r, "exception"),
            };
        }
    }

    // ── inline sources ──
    if (obj.get("sources")) |sv| {
        if (sv != .array) return Error.BadWorld;
        var ss = std.ArrayList(Source){};
        for (sv.array.items) |e| {
            if (e != .object) continue;
            const p = jStr(e.object, "path") orelse continue;
            const src = jStr(e.object, "source") orelse continue;
            try ss.append(a, .{ .path = p, .kind = jStr(e.object, "kind") orelse "handler", .source = src });
        }
        w.sources = try ss.toOwnedSlice(a);
    }

    return w;
}

/// A string value passes through verbatim; any other JSON value is serialized
/// to JSON text (KV/body bytes the handler parses itself).
fn valueToStr(a: std.mem.Allocator, v: std.json.Value) Error![]const u8 {
    if (v == .string) return v.string;
    return std.json.Stringify.valueAlloc(a, v, .{}) catch Error.BadWorld;
}

/// Serialize any JSON value to JSON *text* — unlike `valueToStr`, a string is
/// quoted (`"hi"`, not `hi`). Used for `ctx` / `request.activation`, which are
/// injected into the epilogue as JS values and so must be valid JSON literals.
fn jsonText(a: std.mem.Allocator, v: std.json.Value) Error![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{}) catch Error.BadWorld;
}

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
fn jU64(o: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => if (v.integer >= 0) @intCast(v.integer) else null,
        .float => if (v.float >= 0) @intFromFloat(v.float) else null,
        .string => std.fmt.parseInt(u64, v.string, 10) catch null,
        else => null,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "fromValue: full declarative world" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{
        \\  "entry": "main.mjs", "activation": "inbound",
        \\  "request": {
        \\    "method": "POST", "path": "/api/orders", "host": "shop.example",
        \\    "headers": { "content-type": "application/json" },
        \\    "body": { "item": "book" }, "ip": "203.0.113.7"
        \\  },
        \\  "kv": { "user/jess": { "name": "Jess" }, "config/rate": "10" },
        \\  "seed": 123, "now_ms": 1700000000000, "missPolicy": "fail"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const w = try fromValue(a, parsed.value);

    try testing.expectEqualStrings("main.mjs", w.entry);
    try testing.expectEqualStrings("POST", w.method);
    try testing.expectEqualStrings("/api/orders", w.path);
    try testing.expectEqualStrings("shop.example", w.host);
    try testing.expectEqualStrings("203.0.113.7", w.ip.?);
    try testing.expectEqual(host.MissPolicy.fail, w.miss);
    try testing.expectEqual(@as(u64, 123), w.seed);
    try testing.expectEqual(@as(u64, 1700000000000), w.now_ms);
    // object body got JSON-stringified
    try testing.expectEqualStrings("{\"item\":\"book\"}", w.body.?);
    try testing.expectEqual(@as(usize, 1), w.headers.len);
    try testing.expectEqualStrings("content-type", w.headers[0].name);
    // kv: string passes through, object stringified
    try testing.expectEqual(@as(usize, 2), w.kv.len);
    var saw_jess = false;
    var saw_rate = false;
    for (w.kv) |p| {
        if (std.mem.eql(u8, p.key, "user/jess")) {
            saw_jess = true;
            try testing.expectEqualStrings("{\"name\":\"Jess\"}", p.value);
        }
        if (std.mem.eql(u8, p.key, "config/rate")) {
            saw_rate = true;
            try testing.expectEqualStrings("10", p.value);
        }
    }
    try testing.expect(saw_jess and saw_rate);
}

test "fromValue: non-inbound (fetch result) surface" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{
        \\  "entry": "h.mjs", "activation": "fetch_chunk", "export": "onUpstream",
        \\  "request": { "status": 502, "ok": false, "done": true, "fetchId": "ftch_1",
        \\               "chunkSeq": 3, "body": "boom",
        \\               "activation": { "attempts": 2, "error": "timeout" } },
        \\  "ctx": { "attempt": 2 }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    const w = try fromValue(a, parsed.value);

    try testing.expectEqualStrings("fetch_chunk", w.activation);
    try testing.expectEqualStrings("onUpstream", w.export_name.?); // {to} override
    try testing.expectEqual(@as(i64, 502), w.status.?);
    try testing.expectEqual(false, w.ok.?);
    try testing.expectEqual(true, w.done.?);
    try testing.expectEqualStrings("ftch_1", w.fetch_id.?);
    try testing.expectEqual(@as(i64, 3), w.chunk_seq.?);
    try testing.expectEqualStrings("boom", w.body.?);
    // ctx + request.activation are JSON *text* (string values would be quoted).
    try testing.expectEqualStrings("{\"attempt\":2}", w.ctx_json.?);
    try testing.expectEqualStrings("{\"attempts\":2,\"error\":\"timeout\"}", w.activation_json.?);
}

test "fromValue: defaults + resolve policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    const w = try fromValue(a, parsed.value);
    try testing.expectEqualStrings("index.mjs", w.entry);
    try testing.expectEqualStrings("inbound", w.activation);
    try testing.expectEqualStrings("GET", w.method);
    try testing.expectEqual(host.MissPolicy.resolve, w.miss);
    try testing.expect(w.body == null);
    try testing.expectEqual(@as(usize, 0), w.kv.len);
}

test "fromValue: a non-object root fails loud" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[]", .{});
    try testing.expectError(Error.BadWorld, fromValue(a, parsed.value));
}
