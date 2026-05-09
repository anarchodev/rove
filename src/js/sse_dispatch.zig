//! Worker → sse-server emit POST sink (sse-plan §3.2).
//!
//! Owns the shape of the per-request `EmitEntry` buffer that
//! `events.emit` populates, the per-batch accumulator that
//! `worker_dispatch.dispatchOnce` collects, and the fire-and-forget
//! POST that fires after raft acks the batch.
//!
//! The customer's `app.db` remains the source of truth — sse-server
//! is a notification channel, not a durable store. Losing an emit is
//! acceptable: the next reconnect's sentinel + state refetch covers
//! it. So this path:
//!
//!   - Best-effort: log on failure, never bubble back to the client.
//!   - Tight timeout (default 1 s, sse-plan §3.2). Don't park the
//!     worker thread on a dead sse-server.
//!   - Synchronous inside the drain (v1). Plan §3.2 calls for an
//!     async background queue eventually; until that's needed we
//!     keep it simple — POST inline, log + move on.

const std = @import("std");
const blob_curl = @import("rove-blob").curl;

/// Same shape as the wire id `events.emit` produces:
/// `{request_id:020d}-{call_index:06d}` = 27 chars.
pub const EVENT_ID_LEN: usize = 27;

/// One captured `events.emit` call. Owned by the dispatch state's
/// allocator; freed via `deinit` when the per-batch list drains.
pub const EmitEntry = struct {
    /// `{request_id:020d}-{call_index:06d}` — deterministic across
    /// tape replays so resume-by-Last-Event-ID works after replay.
    event_id: [EVENT_ID_LEN]u8,
    /// Customer-supplied `type` (defaults to `"message"`).
    event_type: []u8,
    /// Customer-supplied payload, JSON-serialized. Embedded
    /// verbatim into the wire body's `data` field.
    data_json: []u8,
    /// Target sids. Defaults to `[request.session.id]`; explicit
    /// `to: [...]` produces multi-target fan-out.
    target_sids: [][]u8,
    /// Wall-clock at emit. Forwarded to sse-server's ring cache so
    /// the catch-up replay carries the original timestamp.
    created_at_ms: i64,

    pub fn deinit(self: *EmitEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.data_json);
        for (self.target_sids) |s| allocator.free(s);
        allocator.free(self.target_sids);
        self.* = undefined;
    }
};

/// POST URL builder. Returns an owned NUL-free slice; caller frees.
fn buildPostUrl(allocator: std.mem.Allocator, public_base: []const u8) ![]u8 {
    // Strip trailing slash so concatenation never produces `//v1/emit`.
    const base = if (public_base.len > 0 and public_base[public_base.len - 1] == '/')
        public_base[0 .. public_base.len - 1]
    else
        public_base;
    return std.fmt.allocPrint(allocator, "{s}/v1/emit", .{base});
}

/// Encode the per-batch emit POST body
/// (`{v, tenant_id, request_id, events:[]}`). Caller frees the
/// returned slice. Does no validation of the input — callers feed
/// EmitEntry values from `events.emit` which already enforced
/// caps / sid format.
pub fn encodeBatch(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    request_id: u64,
    events: []const EmitEntry,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    {
        // Inner block so the `defer` syncs the writer's internal list
        // back into `out` BEFORE `toOwnedSlice` reads from it. Without
        // the block scope `defer out = aw.toArrayList()` would run
        // after the return expression evaluates, leaking the bytes.
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
        defer out = aw.toArrayList();

        try aw.writer.writeAll("{\"v\":1,\"tenant_id\":");
        try writeJsonString(&aw.writer, tenant_id);
        try aw.writer.print(",\"request_id\":{d},\"events\":[", .{request_id});
        for (events, 0..) |e, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.writeAll("{\"event_id\":\"");
            try aw.writer.writeAll(&e.event_id);
            try aw.writer.writeAll("\",\"type\":");
            try writeJsonString(&aw.writer, e.event_type);
            try aw.writer.writeAll(",\"data\":");
            // `data_json` is already encoded JSON — embed verbatim. If
            // the customer's emit produced empty bytes (unset), serialize
            // as null.
            if (e.data_json.len == 0)
                try aw.writer.writeAll("null")
            else
                try aw.writer.writeAll(e.data_json);
            try aw.writer.writeAll(",\"target_sids\":[");
            for (e.target_sids, 0..) |s, j| {
                if (j > 0) try aw.writer.writeAll(",");
                try writeJsonString(&aw.writer, s);
            }
            try aw.writer.print("],\"created_at_ms\":{d}}}", .{e.created_at_ms});
        }
        try aw.writer.writeAll("]}");
    }
    return out.toOwnedSlice(allocator);
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

/// Fire one batch of emits at sse-server. Best-effort:
/// non-2xx + transport errors are logged and swallowed.
/// `easy` is mutex-guarded internally; callers may invoke from
/// any thread.
///
/// `public_base` is the operator-supplied origin (e.g.
/// `https://sse.loop46.me` or `http://127.0.0.1:8230`).
/// `internal_token` is the shared bearer matched by sse-server's
/// `SSE_INTERNAL_TOKEN`.
pub fn fireBatch(
    allocator: std.mem.Allocator,
    easy: *blob_curl.Easy,
    public_base: []const u8,
    internal_token: []const u8,
    tenant_id: []const u8,
    request_id: u64,
    events: []const EmitEntry,
) void {
    if (events.len == 0) return;

    const body = encodeBatch(allocator, tenant_id, request_id, events) catch |err| {
        std.log.warn("sse-emit: encodeBatch failed: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(body);

    const url = buildPostUrl(allocator, public_base) catch |err| {
        std.log.warn("sse-emit: buildPostUrl failed: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(url);

    const auth_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{internal_token}) catch {
        std.log.warn("sse-emit: build auth header OOM", .{});
        return;
    };
    defer allocator.free(auth_value);

    const headers = [_]blob_curl.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_value },
    };

    var resp = easy.request(allocator, .{
        .method = .POST,
        .url = url,
        .headers = &headers,
        .body = body,
        // Plan §3.2 baseline: 1 s. We're talking to a private-network
        // sse-server, not a customer endpoint — it should be much
        // faster than that, but cap so a dead instance doesn't park
        // the worker drain.
        .timeout_ms = 1_000,
        .connect_timeout_ms = 500,
    }) catch |err| {
        std.log.warn("sse-emit: POST {s} failed: {s}", .{ url, @errorName(err) });
        return;
    };
    defer resp.deinit(allocator);

    if (resp.status < 200 or resp.status >= 300) {
        std.log.warn("sse-emit: POST {s} → {d}", .{ url, resp.status });
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "buildPostUrl strips trailing slash" {
    const a = testing.allocator;
    {
        const u = try buildPostUrl(a, "http://127.0.0.1:8099");
        defer a.free(u);
        try testing.expectEqualStrings("http://127.0.0.1:8099/v1/emit", u);
    }
    {
        const u = try buildPostUrl(a, "https://sse.loop46.me/");
        defer a.free(u);
        try testing.expectEqualStrings("https://sse.loop46.me/v1/emit", u);
    }
}

test "encodeBatch shape + verbatim data + sid array" {
    const a = testing.allocator;
    var sids = try a.alloc([]u8, 2);
    defer {
        for (sids) |s| a.free(s);
        a.free(sids);
    }
    sids[0] = try a.dupe(u8, "abc");
    sids[1] = try a.dupe(u8, "def");
    var event_id: [EVENT_ID_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&event_id, "{d:0>20}-{d:0>6}", .{ 1, 0 }) catch unreachable;

    var entries = [_]EmitEntry{.{
        .event_id = event_id,
        .event_type = try a.dupe(u8, "msg"),
        .data_json = try a.dupe(u8, "{\"x\":1}"),
        .target_sids = sids,
        .created_at_ms = 1730764800000,
    }};
    defer a.free(entries[0].event_type);
    defer a.free(entries[0].data_json);

    const body = try encodeBatch(a, "acme", 1234, &entries);
    defer a.free(body);
    try testing.expectEqualStrings(
        "{\"v\":1,\"tenant_id\":\"acme\",\"request_id\":1234,\"events\":[" ++
            "{\"event_id\":\"00000000000000000001-000000\",\"type\":\"msg\",\"data\":{\"x\":1}," ++
            "\"target_sids\":[\"abc\",\"def\"],\"created_at_ms\":1730764800000}]}",
        body,
    );
}

test "encodeBatch null data when data_json empty" {
    const a = testing.allocator;
    var sids = try a.alloc([]u8, 1);
    defer {
        for (sids) |s| a.free(s);
        a.free(sids);
    }
    sids[0] = try a.dupe(u8, "s");
    var event_id: [EVENT_ID_LEN]u8 = undefined;
    _ = std.fmt.bufPrint(&event_id, "{d:0>20}-{d:0>6}", .{ 0, 0 }) catch unreachable;

    var entries = [_]EmitEntry{.{
        .event_id = event_id,
        .event_type = try a.dupe(u8, "p"),
        .data_json = try a.dupe(u8, ""),
        .target_sids = sids,
        .created_at_ms = 1,
    }};
    defer a.free(entries[0].event_type);
    defer a.free(entries[0].data_json);

    const body = try encodeBatch(a, "t", 0, &entries);
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"data\":null") != null);
}
