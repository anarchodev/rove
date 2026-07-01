//! Replay-side `request` reconstruction — the Zig port of
//! `rewind-apps/replay/_static/request-replay.mjs` `buildRequestEpilogue`
//! (Phase 2 §2c). Returns a JS source string the driver APPENDS to the entry
//! module's source before `arena_run_module`. Appended lines never shift the
//! original source's line numbers, so the trace timeline stays aligned.
//!
//! The epilogue:
//!   - rebuilds `globalThis.request` with the lazy-accessor shape the worker
//!     installs (`src/js/globals.zig` installRequest): header getters from the
//!     recorded `request_reads` name set, values from recorded reads; body /
//!     cookies / ip accessors; `unmaskedIp()`;
//!   - throws a loud REPLAY-DIVERGENCE error when the handler reads anything the
//!     capture tape didn't record (never a silent undefined);
//!   - installs a CAPTURING console (the bare arena has none) so the replayed
//!     run's logs land in the output;
//!   - invokes the activation's export via `__arena_entry_ns()` and parks the
//!     run output — response / result / error / console — under the host's
//!     sentinel kv key (`host.OUTPUT_KEY`), the side channel the native driver
//!     reads back (the reactor's result context is static / unreachable).

const std = @import("std");
const decode = @import("tape_decode.zig");
const host = @import("host.zig");

pub const Opts = struct {
    method: []const u8 = "GET",
    /// The raw request path, query string included (split on '?' here).
    path: []const u8 = "/",
    host: []const u8 = "",
    /// Parsed `request_reads` entries (capture order). Empty for records with
    /// no recorded reads.
    request_reads: []const decode.RequestReadEntry = &.{},
    /// The request body bytes, when the handler read them and they rode inline
    /// in the record (≤16 KB). null otherwise.
    body_bytes: ?[]const u8 = null,
    /// The export the activation invokes ("default", "onChunk", ...).
    export_name: []const u8 = "default",
    /// Chunk activations (`inbound_chunk` / `fetch_chunk`): the live
    /// `request.body` is a byte-exact Uint8Array, so the replay body is base64
    /// (binary), not a decoded string.
    binary_body: bool = false,

    // ── non-inbound activation surface (`architecture/replay-and-sim.md` §3) ──
    /// The threaded `Ctx` as JSON text → `request.ctx`. null on the first
    /// activation of a chain (and for inbound, which has no ctx).
    ctx_json: ?[]const u8 = null,
    /// `request.activation.*` metadata as JSON text (wakes / msg / …).
    activation_json: ?[]const u8 = null,
    /// The flattened fetch/callback result → top-level `request.*`.
    result: ?Result = null,
};

/// The flattened fetch/callback result surface (handler-shape §7) — the fields
/// a `request.body` already covers (the bytes) live in `Opts.body_bytes`;
/// these are the scalar siblings.
pub const Result = struct {
    status: ?i64 = null,
    ok: ?bool = null,
    done: ?bool = null,
    fetch_id: ?[]const u8 = null,
    chunk_seq: ?i64 = null,
};

/// Mirror `rpc_dispatch.defaultExportForKind` / the mjs `exportForActivation`.
pub fn exportForActivation(activation: []const u8) []const u8 {
    const map = .{
        .{ "wake_batch", "onWake" },
        .{ "kv_wake", "onWake" },
        .{ "timer", "onWake" },
        .{ "durable_wake", "onWake" },
        .{ "disconnect", "onDisconnect" },
        .{ "ws_message", "onMessage" },
        .{ "inbound_headers", "onHeaders" },
        .{ "inbound_chunk", "onChunk" },
        // A fetch result's *real* export is the resolved name (onFetchResult /
        // onFetchChunk / onFetchDone) carried on the wake, not derivable from
        // the kind (`architecture/replay-and-sim.md` §2). For an authored world
        // we default to the whole-body case; an explicit `export` overrides for
        // chunk/done. (At runtime this kind is dispatched by `resolvedExport`,
        // never this fallback.)
        .{ "fetch_chunk", "onFetchResult" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, activation, pair[0])) return pair[1];
    }
    return "default";
}

const Folded = struct {
    names_json: []const u8 = "[]", // header_names value (already a JSON array)
    values: []const decode.RequestReadEntry = &.{}, // header_value entries
    body_read: bool = false,
    ip_masked: ?[]const u8 = null,
    ip_raw: ?[]const u8 = null,
};

fn fold(a: std.mem.Allocator, entries: []const decode.RequestReadEntry) !Folded {
    var out = Folded{};
    var values = std.ArrayList(decode.RequestReadEntry){};
    for (entries) |e| switch (e.kind) {
        .header_names => out.names_json = if (validJsonArray(e.value)) e.value else "[]",
        .header_value => try values.append(a, e),
        .body_read => out.body_read = true,
        .ip_masked => out.ip_masked = e.value,
        .ip_raw => out.ip_raw = e.value,
    };
    out.values = values.items;
    return out;
}

fn validJsonArray(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return t.len >= 2 and t[0] == '[';
}

/// Build the epilogue source. The caller owns the returned slice (allocated
/// from `a`).
pub fn build(a: std.mem.Allocator, opts: Opts) ![]u8 {
    const f = try fold(a, opts.request_reads);

    const q = std.mem.indexOfScalar(u8, opts.path, '?');
    const path = if (q) |i| opts.path[0..i] else opts.path;
    const query: ?[]const u8 = if (q) |i| opts.path[i + 1 ..] else null;
    const body_read = f.body_read or opts.body_bytes != null;

    var buf = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
    const w = &aw.writer;

    // ── the data object `D` (a JS object literal, JSON-safe) ──
    try w.writeAll("\n;(() => {\n  const D = {");
    try w.writeAll("\"method\":");
    try jsonStr(w, opts.method);
    try w.writeAll(",\"path\":");
    try jsonStr(w, path);
    try w.writeAll(",\"query\":");
    if (query) |qq| try jsonStr(w, qq) else try w.writeAll("null");
    try w.writeAll(",\"host\":");
    try jsonStr(w, opts.host);
    try w.writeAll(",\"names\":");
    try w.writeAll(f.names_json); // already a JSON array literal
    try w.writeAll(",\"values\":{");
    for (f.values, 0..) |v, i| {
        if (i != 0) try w.writeByte(',');
        try jsonStr(w, v.name);
        try w.writeByte(':');
        try jsonStr(w, v.value);
    }
    try w.writeAll("},\"bodyRead\":");
    try w.writeAll(if (body_read) "true" else "false");
    // body (text) vs bodyB64 (binary, chunk activations).
    try w.writeAll(",\"body\":");
    if (opts.binary_body or opts.body_bytes == null) {
        try w.writeAll("null");
    } else {
        try jsonStr(w, opts.body_bytes.?);
    }
    try w.writeAll(",\"bodyB64\":");
    if (opts.binary_body and opts.body_bytes != null) {
        try jsonB64(a, w, opts.body_bytes.?);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"ipMasked\":");
    try optValue(w, f.ip_masked);
    try w.writeAll(",\"ipRaw\":");
    try optValue(w, f.ip_raw);
    // ctx / activation are pre-serialized JSON values (null for inbound, so the
    // inbound surface is byte-identical to before).
    try w.writeAll(",\"ctx\":");
    try w.writeAll(opts.ctx_json orelse "null");
    try w.writeAll(",\"activation\":");
    try w.writeAll(opts.activation_json orelse "null");
    try w.writeAll(",\"result\":");
    if (opts.result) |r| {
        try w.writeAll("{\"status\":");
        try optInt(w, r.status);
        try w.writeAll(",\"ok\":");
        try optBool(w, r.ok);
        try w.writeAll(",\"done\":");
        try optBool(w, r.done);
        try w.writeAll(",\"fetchId\":");
        if (r.fetch_id) |s| try jsonStr(w, s) else try w.writeAll("null");
        try w.writeAll(",\"chunkSeq\":");
        try optInt(w, r.chunk_seq);
        try w.writeByte('}');
    } else try w.writeAll("null");
    try w.writeAll(",\"fn\":");
    try jsonStr(w, opts.export_name);
    try w.writeAll("};\n");

    // ── the fixed reconstruction + invoke + side-channel capture ──
    try w.writeAll(EPILOGUE_BODY);
    try w.print("  kv.set({s}, __out);\n}})();\n", .{quotedOutputKey});

    buf = aw.toArrayList();
    return buf.toOwnedSlice(a);
}

/// `"__replay_output__"` as a JS string literal for the `kv.set` call.
const quotedOutputKey = "\"" ++ host.OUTPUT_KEY ++ "\"";

const EPILOGUE_BODY =
    \\  const miss = (what) => { throw new Error("REPLAY DIVERGENCE: " + what + " was read by the handler but is not on the capture tape — the handler observed an input the original run never read"); };
    \\  const __logs = [];
    \\  const __sink = (...a) => { __logs.push(a.map((x) => { try { return typeof x === "string" ? x : JSON.stringify(x); } catch (_) { return String(x); } }).join(" ")); };
    \\  globalThis.console = { log: __sink, warn: __sink, error: __sink, info: __sink, debug: __sink };
    \\  const headers = {};
    \\  for (const n of D.names) Object.defineProperty(headers, n, {
    \\    enumerable: true, configurable: true,
    \\    get() { if (!(n in D.values)) miss("header '" + n + "'"); return D.values[n]; },
    \\  });
    \\  const request = { method: D.method, path: D.path, host: D.host, query: D.query, headers };
    \\  Object.defineProperty(request, "body", { enumerable: true, configurable: true,
    \\    get() {
    \\      if (!D.bodyRead) miss("request.body");
    \\      let v;
    \\      if (D.bodyB64 != null) {
    \\        const bin = atob(D.bodyB64);
    \\        v = new Uint8Array(bin.length);
    \\        for (let i = 0; i < bin.length; i++) v[i] = bin.charCodeAt(i);
    \\      } else { v = D.body ?? ""; }
    \\      Object.defineProperty(request, "body", { enumerable: true, configurable: true, writable: true, value: v });
    \\      return v;
    \\    } });
    \\  Object.defineProperty(request, "cookies", { enumerable: true, configurable: true,
    \\    get() {
    \\      const out = {};
    \\      if (D.names.includes("cookie")) {
    \\        const cv = headers.cookie;
    \\        for (const part of cv.split(";")) {
    \\          const eq = part.indexOf("=");
    \\          if (eq < 0) continue;
    \\          const name = part.slice(0, eq).trim();
    \\          if (name) out[name] = part.slice(eq + 1).trim();
    \\        }
    \\      }
    \\      Object.defineProperty(request, "cookies", { enumerable: true, configurable: true, writable: true, value: out });
    \\      return out;
    \\    } });
    \\  Object.defineProperty(request, "ip", { enumerable: true, configurable: true,
    \\    get() { if (!D.ipMasked) miss("request.ip"); return D.ipMasked.value || null; } });
    \\  request.unmaskedIp = function () { if (!D.ipRaw) miss("request.unmaskedIp()"); return D.ipRaw.value || null; };
    \\  // Non-inbound activation surface (null for inbound → no-ops):
    \\  // the threaded ctx, the request.activation metadata bag, and the
    \\  // flattened fetch/callback result (request.status/.ok/.done/...).
    \\  if (D.ctx !== null) request.ctx = D.ctx;
    \\  if (D.activation !== null) {
    \\    // A binary WS frame carries its bytes as base64 → rebuild the
    \\    // Uint8Array on request.activation.data (a text frame keeps its string).
    \\    if (D.activation.dataB64 != null) {
    \\      const bin = atob(D.activation.dataB64);
    \\      const u = new Uint8Array(bin.length);
    \\      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    \\      D.activation.data = u; delete D.activation.dataB64;
    \\    }
    \\    request.activation = D.activation;
    \\  }
    \\  if (D.result !== null) {
    \\    if (D.result.status !== null) request.status = D.result.status;
    \\    if (D.result.ok !== null) request.ok = D.result.ok;
    \\    if (D.result.done !== null) request.done = D.result.done;
    \\    if (D.result.fetchId !== null) request.fetchId = D.result.fetchId;
    \\    if (D.result.chunkSeq !== null) request.chunkSeq = D.result.chunkSeq;
    \\  }
    \\  // ── effect shims ──
    \\  // The bare replay arena has no ambient effect globals, so a real handler
    \\  // (TextDecoder / stream.* / on.* / next / webhook.send) would ReferenceError.
    \\  // Outputs are CAPTURED (not fired) so the bundle shows what the handler did
    \\  // and re-execution stays deterministic. stream/on/next/TextDecoder are
    \\  // fully faithful (no side effects to reproduce); webhook/email/schedule/
    \\  // cron/blob are recorded but do NOT re-run their durability shims (their
    \\  // kv markers / bytes aren't reproduced — the handler's own kv writes are).
    \\  const __b2s = (c) => { if (typeof c === "string") return c; let s = ""; for (let i = 0; i < c.length; i++) s += String.fromCharCode(c[i]); return s; };
    \\  if (typeof globalThis.TextDecoder === "undefined") {
    \\    globalThis.TextDecoder = function () {};
    \\    globalThis.TextDecoder.prototype.decode = function (u) { if (u == null) return ""; try { return decodeURIComponent(escape(__b2s(u))); } catch (_) { return __b2s(u); } };
    \\    globalThis.TextEncoder = function () {};
    \\    globalThis.TextEncoder.prototype.encode = function (s) { s = String(s); const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i) & 0xff; return u; };
    \\  }
    \\  const __stream = [];
    \\  globalThis.stream = { start() {}, write(c) { __stream.push(__b2s(c)); } };
    \\  const __wakes = [];
    \\  globalThis.on = {
    \\    fetch(url, opts, to) { __wakes.push({ kind: "fetch", url, to: (to && to.to) || (opts && opts.to) || null }); },
    \\    kv(prefix, to) { __wakes.push({ kind: "kv", prefix, to: (to && to.to) || null }); },
    \\    timer(ms, to) { __wakes.push({ kind: "timer", ms, to: (to && to.to) || null }); },
    \\  };
    \\  const __sends = [];
    \\  globalThis.webhook = { send(url, opts) { __sends.push({ kind: "webhook", url, onResult: (opts && opts.onResult) || null }); } };
    \\  globalThis.email = { send(opts) { __sends.push({ kind: "email", to: (opts && opts.to) || null }); } };
    \\  globalThis.schedule = (when, target) => { __sends.push({ kind: "schedule", when, target: target || null }); };
    \\  globalThis.cron = (spec, target) => { __sends.push({ kind: "cron", spec, target: target || null }); };
    \\  globalThis.blob = { get() {}, put() {}, receive() {}, seal() {} };
    \\  globalThis.next = (ctx) => ({ __rove_disposition: "next", ctx: ctx === undefined ? null : ctx });
    \\  if (typeof request.tag !== "function") request.tag = function () { return request; };
    \\  globalThis.request = request;
    \\  globalThis.response = { status: 200, headers: {}, cookies: [] };
    \\  let __result = null, __err = null;
    \\  try {
    \\    const ns = __arena_entry_ns();
    \\    if (typeof ns[D.fn] !== "function") throw new Error("replay: entry module has no '" + D.fn + "' export");
    \\    __result = ns[D.fn]();
    \\    globalThis.__replay_result = __result;
    \\  } catch (e) {
    \\    __err = { message: String((e && e.message) || e), stack: String((e && e.stack) || "") };
    \\  }
    \\  let __out;
    \\  try {
    \\    __out = JSON.stringify({ response: globalThis.response, result: __result, error: __err, console: __logs, stream: __stream, wakes: __wakes, sends: __sends });
    \\  } catch (e) {
    \\    __out = JSON.stringify({ response: null, result: null, console: __logs, stream: __stream, wakes: __wakes, sends: __sends,
    \\      error: { message: "replay result not JSON-serialisable: " + String((e && e.message) || e), stack: "" } });
    \\  }
    \\
;

fn optInt(w: *std.Io.Writer, v: ?i64) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
}
fn optBool(w: *std.Io.Writer, v: ?bool) !void {
    try w.writeAll(if (v) |b| (if (b) "true" else "false") else "null");
}

/// `{"value": "<s>"}` or `null` — the ipMasked / ipRaw shape the getters read.
fn optValue(w: *std.Io.Writer, v: ?[]const u8) !void {
    if (v) |s| {
        try w.writeAll("{\"value\":");
        try jsonStr(w, s);
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
}

fn jsonB64(a: std.mem.Allocator, w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(out);
    _ = enc.encode(out, bytes);
    try jsonStr(w, out);
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        // U+2028 / U+2029 can't appear in a single UTF-8 byte, so byte-level
        // escaping of the C0 controls + quote + backslash is sufficient here.
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "exportForActivation maps activation kinds" {
    try testing.expectEqualStrings("default", exportForActivation("inbound"));
    try testing.expectEqualStrings("onWake", exportForActivation("kv_wake"));
    try testing.expectEqualStrings("onMessage", exportForActivation("ws_message"));
    try testing.expectEqualStrings("onChunk", exportForActivation("inbound_chunk"));
}

test "build: GET embeds request meta + parks output under sentinel" {
    // The driver always builds under a per-replay arena (root.zig `run`); the
    // intermediate fold allocations are reclaimed wholesale, so mirror that.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reads = [_]decode.RequestReadEntry{
        .{ .kind = .header_names, .name = "", .value = "[\"content-type\"]" },
        .{ .kind = .header_value, .name = "content-type", .value = "application/json" },
    };
    const src = try build(a, .{
        .method = "GET",
        .path = "/hello?x=1",
        .host = "ex.test",
        .request_reads = &reads,
        .export_name = "default",
    });

    try testing.expect(std.mem.indexOf(u8, src, "\"path\":\"/hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"query\":\"x=1\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "[\"content-type\"]") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"content-type\":\"application/json\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "__arena_entry_ns()") != null);
    try testing.expect(std.mem.indexOf(u8, src, "kv.set(\"" ++ host.OUTPUT_KEY ++ "\"") != null);
}
