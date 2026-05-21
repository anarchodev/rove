//! http.send Option-(b) per-tenant outbox — the marker codec.
//!
//! Re-implements Meaning-1 (no-silent-loss / at-least-once *attempt*)
//! on the per-tenant kv/raft path instead of the central cluster-wide
//! schedule store. Two reserved keys in the issuing tenant's app.db
//! (see `reserved.zig` `_send/`, `docs/http-send-plan.md` §15):
//!
//!   `_send/owed/{id}`   the re-fireable send, written into the
//!                       issuing hop's own writeset (envelope-0,
//!                       committed before the send fires per the
//!                       post-commit discipline). Persists until proof.
//!   `_send/proof/{id}`  the recorded outcome, written on
//!                       callback-commit. Presence ⇒ proven done ⇒
//!                       the owed row may be GC'd.
//!
//! Recovery (any worker, its own tenants — N-way, no central store,
//! no leader-pinned firer) = scan `_send/owed/` for ids lacking a
//! `_send/proof/`, re-fire on the owning worker. Re-send ⇒ a possible
//! duplicate at the target ⇒ resolve-once still required (the
//! retained cost of Option (b) vs pure best-effort).
//!
//! Increment 1 (this file): the pure data shape + codec only —
//! self-contained, unit-tested, ZERO wiring into the dispatch/raft
//! path. Mirrors how `continuation.zig` was 3b's additive increment 1.
//! The on-disk form is length-prefixed binary (NOT JSON): an
//! http.send `body` is arbitrary bytes — JSON would force base64; the
//! rest of the system already stores raft/writeset payloads as
//! length-prefixed blobs, so this matches.

const std = @import("std");

/// Bump if the wire layout changes. Pre-1.0, but the schedule
/// envelopes have evolved enough that a 1-byte version guard is cheap
/// insurance against a silent mis-decode of an in-flight `_send/owed/`
/// row across a deploy.
///
/// V1 → V2 (Gap 2.3 Phase B): the upstream-streaming options
/// (`stream_response`, `pipe_to_held_response`, `headers_passthrough`,
/// `max_response_chunk_bytes`, `max_total_response_bytes`) appended
/// to the encode. `decode` accepts both: V1 rows decode with the
/// v2 fields at their defaults (false / 0) so an in-flight pre-deploy
/// row re-fires as a non-streaming send.
pub const OWED_V: u8 = 2;
pub const OWED_V1: u8 = 1; // accepted by decode for back-compat
pub const PROOF_V: u8 = 1;

pub const OWED_PREFIX = "_send/owed/";
pub const PROOF_PREFIX = "_send/proof/";

/// Max key buffer the formatters need: prefix + ScheduleRow.id
/// (≤256 bytes per its doc; 64-hex for the platform-derived case).
pub const KEY_BUF = PROOF_PREFIX.len + 256;

/// `_send/owed/{id}` into `buf`; returns the filled slice.
pub fn owedKey(buf: []u8, id: []const u8) []const u8 {
    return keyInto(buf, OWED_PREFIX, id);
}

/// `_send/proof/{id}` into `buf`; returns the filled slice.
pub fn proofKey(buf: []u8, id: []const u8) []const u8 {
    return keyInto(buf, PROOF_PREFIX, id);
}

fn keyInto(buf: []u8, comptime prefix: []const u8, id: []const u8) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..id.len], id);
    return buf[0 .. prefix.len + id.len];
}

pub const DecodeError = error{ Truncated, BadVersion, OutOfMemory };

// ── OwedSend: everything needed to (re-)fire the send ──────────────
// The relocatable subset of `schedule_server.ScheduleRow` —
// `tenant_id` is implicit (it IS the tenant's own app.db) and
// `is_internal` is apply-time-derived, so neither is stored.

pub const OwedSend = struct {
    url: []const u8,
    method: []const u8,
    headers_json: []const u8,
    body: []const u8, // binary-safe
    context_json: []const u8,
    on_result_module: []const u8,
    on_result_fn: []const u8,
    on_result_args_json: []const u8,
    timeout_ms: u32,
    max_body_bytes: u32,
    /// 0 = immediate; else the delayed/cron fire time (the durable
    /// timer — a `_send/owed/` row carrying a future fire_at_ns IS
    /// the lightweight durable schedule, §15.5).
    fire_at_ns: i64,

    // ── Gap 2.3 Phase B: upstream-streaming options (V2) ─────
    /// Per-chunk handler visibility: fires `send_chunk` activations
    /// while bytes arrive, then `send_end` on close. Mutually
    /// exclusive with `pipe_to_held_response` — the binding rejects
    /// both at JS level.
    stream_response: bool = false,
    /// Transparent proxy: pipe upstream bytes directly to the
    /// calling chain's held client (`StreamChunks` queue); no
    /// per-chunk handler invocation. `send_pipe_done` fires once
    /// upstream closes. Pipe target entity id is captured in
    /// Phase E (added then via field append + V3 bump).
    pipe_to_held_response: bool = false,
    /// `pipe_to_held_response` only: mirror upstream response
    /// headers as the held client's response headers. Ignored
    /// when `pipe_to_held_response == false`.
    headers_passthrough: bool = false,
    /// Per-chunk libcurl writeback cap. The runtime splits larger
    /// libcurl-side writebacks into chunks of this size before
    /// invoking the activation / appending to StreamChunks. 0 ⇒
    /// default (64 KB applied at fire site). Only meaningful when
    /// `stream_response` or `pipe_to_held_response` is true.
    max_response_chunk_bytes: u32 = 0,
    /// Hard cap on cumulative response bytes from a streaming /
    /// piped send. Exceeding cancels the send + fires the terminal
    /// (`send_end` or `send_pipe_done`) with `ok = false`,
    /// `reason = "max_total_response_bytes"`. 0 ⇒ default (50 MB
    /// applied at fire site).
    max_total_response_bytes: u64 = 0,

    /// Owned slices freed; only valid for the result of `decode`
    /// (which dupes). An `OwedSend` built from borrowed slices for
    /// `encode` must NOT be deinit'd.
    pub fn deinitOwned(self: *OwedSend, a: std.mem.Allocator) void {
        a.free(self.url);
        a.free(self.method);
        a.free(self.headers_json);
        a.free(self.body);
        a.free(self.context_json);
        a.free(self.on_result_module);
        a.free(self.on_result_fn);
        a.free(self.on_result_args_json);
    }

    pub fn encode(self: OwedSend, a: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, OWED_V);
        inline for (.{
            self.url,                 self.method,
            self.headers_json,        self.body,
            self.context_json,        self.on_result_module,
            self.on_result_fn,        self.on_result_args_json,
        }) |f| try putBytes(a, &out, f);
        try putU32(a, &out, self.timeout_ms);
        try putU32(a, &out, self.max_body_bytes);
        try putI64(a, &out, self.fire_at_ns);
        // V2 (Gap 2.3 Phase B) — appended after the V1 layout so
        // a V1 cursor reads exactly the same bytes; V2 decode
        // continues past where V1 stops.
        try out.append(a, @intFromBool(self.stream_response));
        try out.append(a, @intFromBool(self.pipe_to_held_response));
        try out.append(a, @intFromBool(self.headers_passthrough));
        try putU32(a, &out, self.max_response_chunk_bytes);
        try putU64(a, &out, self.max_total_response_bytes);
        return out.toOwnedSlice(a);
    }

    pub fn decode(a: std.mem.Allocator, bytes: []const u8) DecodeError!OwedSend {
        var c = Cursor{ .b = bytes };
        const v = try c.u8_();
        if (v != OWED_V and v != OWED_V1) return error.BadVersion;
        var r: OwedSend = undefined;
        // Dup each field; on any later failure free what we took.
        const url = try c.bytesDup(a);
        errdefer a.free(url);
        const method = try c.bytesDup(a);
        errdefer a.free(method);
        const headers_json = try c.bytesDup(a);
        errdefer a.free(headers_json);
        const body = try c.bytesDup(a);
        errdefer a.free(body);
        const context_json = try c.bytesDup(a);
        errdefer a.free(context_json);
        const on_result_module = try c.bytesDup(a);
        errdefer a.free(on_result_module);
        const on_result_fn = try c.bytesDup(a);
        errdefer a.free(on_result_fn);
        const on_result_args_json = try c.bytesDup(a);
        errdefer a.free(on_result_args_json);
        r = .{
            .url = url,
            .method = method,
            .headers_json = headers_json,
            .body = body,
            .context_json = context_json,
            .on_result_module = on_result_module,
            .on_result_fn = on_result_fn,
            .on_result_args_json = on_result_args_json,
            .timeout_ms = try c.u32_(),
            .max_body_bytes = try c.u32_(),
            .fire_at_ns = try c.i64_(),
        };
        // V2 tail: streaming options. V1 rows leave them at the
        // struct defaults (all false / 0), which means "non-
        // streaming send" — exactly the pre-Phase-B semantics.
        if (v == OWED_V) {
            r.stream_response = (try c.u8_()) != 0;
            r.pipe_to_held_response = (try c.u8_()) != 0;
            r.headers_passthrough = (try c.u8_()) != 0;
            r.max_response_chunk_bytes = try c.u32_();
            r.max_total_response_bytes = try c.u64_();
        }
        return r;
    }
};

// ── Proof: the recorded outcome (presence ⇒ proven done) ───────────

pub const Proof = struct {
    ok: bool,
    status: u16,
    body: []const u8,
    err: []const u8,

    pub fn deinitOwned(self: *Proof, a: std.mem.Allocator) void {
        a.free(self.body);
        a.free(self.err);
    }

    pub fn encode(self: Proof, a: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, PROOF_V);
        try out.append(a, @intFromBool(self.ok));
        try putU32(a, &out, self.status);
        try putBytes(a, &out, self.body);
        try putBytes(a, &out, self.err);
        return out.toOwnedSlice(a);
    }

    pub fn decode(a: std.mem.Allocator, bytes: []const u8) DecodeError!Proof {
        var c = Cursor{ .b = bytes };
        if (try c.u8_() != PROOF_V) return error.BadVersion;
        const ok = (try c.u8_()) != 0;
        const status: u16 = @intCast(try c.u32_());
        const body = try c.bytesDup(a);
        errdefer a.free(body);
        const err = try c.bytesDup(a);
        return .{ .ok = ok, .status = status, .body = body, .err = err };
    }
};

// ── codec primitives ──────────────────────────────────────────────

fn putBytes(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try putU32(a, out, @intCast(s.len));
    try out.appendSlice(a, s);
}

fn putU32(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try out.appendSlice(a, &tmp);
}

fn putI64(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: i64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(i64, &tmp, v, .little);
    try out.appendSlice(a, &tmp);
}

fn putU64(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .little);
    try out.appendSlice(a, &tmp);
}

const Cursor = struct {
    b: []const u8,
    i: usize = 0,

    fn need(self: *Cursor, n: usize) DecodeError!void {
        if (self.i + n > self.b.len) return error.Truncated;
    }
    fn u8_(self: *Cursor) DecodeError!u8 {
        try self.need(1);
        defer self.i += 1;
        return self.b[self.i];
    }
    fn u32_(self: *Cursor) DecodeError!u32 {
        try self.need(4);
        defer self.i += 4;
        return std.mem.readInt(u32, self.b[self.i..][0..4], .little);
    }
    fn i64_(self: *Cursor) DecodeError!i64 {
        try self.need(8);
        defer self.i += 8;
        return std.mem.readInt(i64, self.b[self.i..][0..8], .little);
    }
    fn u64_(self: *Cursor) DecodeError!u64 {
        try self.need(8);
        defer self.i += 8;
        return std.mem.readInt(u64, self.b[self.i..][0..8], .little);
    }
    fn bytesDup(self: *Cursor, a: std.mem.Allocator) DecodeError![]u8 {
        const n = try self.u32_();
        try self.need(n);
        defer self.i += n;
        return a.dupe(u8, self.b[self.i..][0..n]) catch error.OutOfMemory;
    }
};

// ── tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "owedKey / proofKey format" {
    var buf: [KEY_BUF]u8 = undefined;
    try testing.expectEqualStrings("_send/owed/abc123", owedKey(&buf, "abc123"));
    try testing.expectEqualStrings("_send/proof/abc123", proofKey(&buf, "abc123"));
}

test "OwedSend round-trips, including a NUL-bearing binary body + empty fields" {
    const a = testing.allocator;
    const src = OwedSend{
        .url = "https://wb.test/echo",
        .method = "POST",
        .headers_json = "{\"content-type\":\"application/octet-stream\"}",
        .body = &[_]u8{ 0, 1, 2, 0xff, '\n', 0, 'x' }, // binary, NULs
        .context_json = "null",
        .on_result_module = "heldsync/onresult",
        .on_result_fn = "onResult",
        .on_result_args_json = "", // empty field must round-trip
        .timeout_ms = 30_000,
        .max_body_bytes = 1_048_576,
        .fire_at_ns = 0,
    };
    const enc = try src.encode(a);
    defer a.free(enc);
    var got = try OwedSend.decode(a, enc);
    defer got.deinitOwned(a);
    try testing.expectEqualStrings(src.url, got.url);
    try testing.expectEqualStrings(src.method, got.method);
    try testing.expectEqualSlices(u8, src.body, got.body);
    try testing.expectEqualStrings(src.on_result_module, got.on_result_module);
    try testing.expectEqualStrings("", got.on_result_args_json);
    try testing.expectEqual(@as(u32, 30_000), got.timeout_ms);
    try testing.expectEqual(@as(i64, 0), got.fire_at_ns);
}

test "OwedSend carries a future fire_at_ns (the durable timer case)" {
    const a = testing.allocator;
    const src = OwedSend{
        .url = "https://x/", .method = "GET", .headers_json = "{}",
        .body = "", .context_json = "null", .on_result_module = "m",
        .on_result_fn = "", .on_result_args_json = "[]",
        .timeout_ms = 1, .max_body_bytes = 1,
        .fire_at_ns = 9_223_372_036_854_775_000, // ~max; 7-day-out style value
    };
    const enc = try src.encode(a);
    defer a.free(enc);
    var got = try OwedSend.decode(a, enc);
    defer got.deinitOwned(a);
    try testing.expectEqual(src.fire_at_ns, got.fire_at_ns);
}

test "OwedSend V2 streaming fields round-trip" {
    const a = testing.allocator;
    const src = OwedSend{
        .url = "https://x/stream", .method = "GET", .headers_json = "{}",
        .body = "", .context_json = "null", .on_result_module = "m",
        .on_result_fn = "", .on_result_args_json = "[]",
        .timeout_ms = 30_000, .max_body_bytes = 1024,
        .fire_at_ns = 0,
        .stream_response = true,
        .pipe_to_held_response = false,
        .headers_passthrough = false,
        .max_response_chunk_bytes = 64 * 1024,
        .max_total_response_bytes = 100 * 1024 * 1024,
    };
    const enc = try src.encode(a);
    defer a.free(enc);
    var got = try OwedSend.decode(a, enc);
    defer got.deinitOwned(a);
    try testing.expectEqual(true, got.stream_response);
    try testing.expectEqual(false, got.pipe_to_held_response);
    try testing.expectEqual(false, got.headers_passthrough);
    try testing.expectEqual(@as(u32, 64 * 1024), got.max_response_chunk_bytes);
    try testing.expectEqual(@as(u64, 100 * 1024 * 1024), got.max_total_response_bytes);
}

test "OwedSend V2 pipe_to + headers_passthrough round-trips" {
    const a = testing.allocator;
    const src = OwedSend{
        .url = "https://x/big.mp4", .method = "GET", .headers_json = "{}",
        .body = "", .context_json = "null", .on_result_module = "",
        .on_result_fn = "", .on_result_args_json = "[]",
        .timeout_ms = 30_000, .max_body_bytes = 1,
        .fire_at_ns = 0,
        .stream_response = false,
        .pipe_to_held_response = true,
        .headers_passthrough = true,
        .max_response_chunk_bytes = 0,
        .max_total_response_bytes = std.math.maxInt(u64),
    };
    const enc = try src.encode(a);
    defer a.free(enc);
    var got = try OwedSend.decode(a, enc);
    defer got.deinitOwned(a);
    try testing.expectEqual(true, got.pipe_to_held_response);
    try testing.expectEqual(true, got.headers_passthrough);
    try testing.expectEqual(std.math.maxInt(u64), got.max_total_response_bytes);
}

test "OwedSend V1 back-compat: decode legacy row, V2 fields default" {
    const a = testing.allocator;
    // Build a V1 byte stream by hand — same layout as V1's encode.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try out.append(a, OWED_V1);
    inline for (.{
        "https://x/", "GET", "{}", "", "null", "m", "", "[]",
    }) |f| try putBytes(a, &out, f);
    try putU32(a, &out, 30_000); // timeout_ms
    try putU32(a, &out, 1024); // max_body_bytes
    try putI64(a, &out, 0); // fire_at_ns
    // No V2 tail — legacy row stops here.

    var got = try OwedSend.decode(a, out.items);
    defer got.deinitOwned(a);
    try testing.expectEqualStrings("https://x/", got.url);
    try testing.expectEqual(@as(u32, 30_000), got.timeout_ms);
    // V2 fields fall back to struct defaults — pre-streaming
    // semantics ("just a regular send").
    try testing.expectEqual(false, got.stream_response);
    try testing.expectEqual(false, got.pipe_to_held_response);
    try testing.expectEqual(false, got.headers_passthrough);
    try testing.expectEqual(@as(u32, 0), got.max_response_chunk_bytes);
    try testing.expectEqual(@as(u64, 0), got.max_total_response_bytes);
}

test "Proof round-trips (ok and failure shapes)" {
    const a = testing.allocator;
    for ([_]Proof{
        .{ .ok = true, .status = 200, .body = "echoed:v", .err = "" },
        .{ .ok = false, .status = 0, .body = "", .err = "CurlCallFailed" },
    }) |src| {
        const enc = try src.encode(a);
        defer a.free(enc);
        var got = try Proof.decode(a, enc);
        defer got.deinitOwned(a);
        try testing.expectEqual(src.ok, got.ok);
        try testing.expectEqual(src.status, got.status);
        try testing.expectEqualStrings(src.body, got.body);
        try testing.expectEqualStrings(src.err, got.err);
    }
}

test "decode rejects truncation and a bad version" {
    const a = testing.allocator;
    const src = OwedSend{
        .url = "u", .method = "GET", .headers_json = "{}", .body = "b",
        .context_json = "null", .on_result_module = "m", .on_result_fn = "f",
        .on_result_args_json = "[]", .timeout_ms = 1, .max_body_bytes = 1,
        .fire_at_ns = 0,
    };
    const enc = try src.encode(a);
    defer a.free(enc);
    try testing.expectError(error.Truncated, OwedSend.decode(a, enc[0 .. enc.len - 3]));
    try testing.expectError(error.Truncated, OwedSend.decode(a, enc[0..1]));
    var bad = try a.dupe(u8, enc);
    defer a.free(bad);
    bad[0] = 0x7e; // wrong version byte
    try testing.expectError(error.BadVersion, OwedSend.decode(a, bad));
}
