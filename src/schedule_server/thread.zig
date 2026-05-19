//! Schedule-server delivery thread (http-send-plan §5).
//!
//! Leader-pinned poll loop inside the loop46 binary. On each tick,
//! if this node is the raft leader, scans `schedules.db` for rows
//! whose `fire_at_ns ≤ now`, fires them over libcurl, and proposes
//! envelope 9 (`schedule_complete`) through the local raft node so
//! every node deletes the row + writes the customer's
//! `_callback/{id}` row in their app.db on a version match.
//!
//! ## Why a poll loop and not start-on-leadership-acquired
//!
//! Same reasoning as `webhook_server/thread.zig`: gating per-tick on
//! `raft.isLeader()` is simpler than reactive lifecycle and the
//! wasted cycles on followers are a single atomic load every
//! `poll_interval_ms`. The apply-side wakeup (`schedule_wake`) means
//! a fresh `http.send` lands within an apply tick + delivery latency,
//! not the next poll deadline.
//!
//! ## What this module owns
//!
//! - Poll loop + stop signal.
//! - One `ScheduleStore` connection (NOMUTEX SQLite, opened at spawn,
//!   closed at join). The raft thread has its own connection through
//!   `ApplyCtx`; WAL serializes the cross-connection writes.
//! - One `curl.Easy` handle. libcurl easy handles are NOT thread-safe;
//!   this thread is the only caller.
//! - In-memory in-flight set so a slow delivery doesn't get
//!   re-picked-up on the next tick before its envelope-9 commits.
//!   Dropped on demote — a future leader starts fresh, which can
//!   re-fire rows already in flight on the previous leader. That's
//!   the at-least-once contract the customer's on_result handler is
//!   responsible for tolerating (plan §7).
//!
//! ## What it does NOT own
//!
//! - SSRF rules — `schedule_server.ssrf`. (Originally vendored in
//!   from rove-webhook-server; moved here as part of that module's
//!   retirement.)
//! - Tenant-side `_callback/{id}` writes — those happen in the apply
//!   path on every node when envelope 9 commits.
//! - Per-tenant rate limiting (plan §13) — future slice.
//! - Internal-routed schedules — `is_internal=true` rows are skipped
//!   here and dispatched from the worker phase (future slice). The
//!   `dueRows` query already filters them out so the libcurl path
//!   never sees them.

const std = @import("std");
const kv_mod = @import("rove-kv");
const blob_mod = @import("rove-blob");

const schedule_server = @import("root.zig");
const ssrf = @import("ssrf.zig");


/// **TEST-ONLY** escape hatch that lets the scheduler talk to
/// `http://` URLs (in addition to `https://`). Paired with
/// `schedule_server.ssrf.test_allow_loopback` under loop46's
/// `--dev-webhook-unsafe` flag so smokes can point at on-box echo
/// servers. **Never set in production** — plaintext outbound leaks
/// request bodies on any intermediate hop.
pub var test_allow_plaintext: bool = false;


/// The fields a single outbound fire needs — exactly the intersection
/// of `schedule_server.ScheduleRow` (the live env-8 path) and
/// `send_outbox.OwedSend` (Option (b)'s `_send/owed/` path), so one
/// transport serves both. `id`/`version_str` are the
/// `X-Rove-Schedule-Id` / `-Version` header-meta values.
pub const FireParams = struct {
    url: []const u8,
    method: []const u8,
    headers_json: []const u8,
    body: []const u8,
    timeout_ms: u32,
    max_body_bytes: u32,
    id: []const u8,
    version_str: []const u8,
};

/// Outcome of one fire. `body` is allocator-OWNED (the caller frees
/// via `deinit`) and capped to `max_body_bytes`; `null` on failure /
/// no body. `err` is a static reason string on `.failed`, `""` on
/// `.delivered` — never owned, safe to copy.
pub const FireResult = struct {
    outcome: schedule_server.Outcome,
    status: u16,
    body: ?[]u8,
    err: []const u8,

    pub fn bodyOr(self: *const FireResult, fallback: []const u8) []const u8 {
        return self.body orelse fallback;
    }
    pub fn deinit(self: *FireResult, a: std.mem.Allocator) void {
        if (self.body) |b| a.free(b);
    }
};

/// Option (b) 4c-i: the reusable outbound-HTTP transport, extracted
/// behavior-identically from `deliverOne` (minus the env-9
/// `proposeComplete`, which is the schedule-path's result delivery).
/// SSRF gate → header-meta render → method parse → libcurl request →
/// 2xx/cap outcome. Pure transport: no raft, no logging, no tenant
/// context — the caller maps the `FireResult` to its own resolution
/// (schedule path → `proposeComplete`; Option (b) 4c-iii → 7-A). The
/// SSRF resolve is racy vs rebinding (libcurl re-resolves) but
/// catches the common literals, same as before.
pub fn fireOnce(
    a: std.mem.Allocator,
    easy: *blob_mod.curl.Easy,
    p: FireParams,
) FireResult {
    checkSsrf(a, p.url) catch |err| return .{
        .outcome = .failed,
        .status = 0,
        .body = null,
        .err = switch (err) {
            error.BlockedAddress => "blocked address (SSRF)",
            error.HttpsRequired => "https required",
            error.InvalidUrl => "invalid url",
            // Network / OOM resolving — surface as a transport failure
            // so the customer's on_result sees it.
            else => @errorName(err),
        },
    };

    const headers = renderHeadersWithMeta(a, p.headers_json, p.id, p.version_str) catch
        return .{ .outcome = .failed, .status = 0, .body = null, .err = "invalid headers" };
    defer {
        for (headers) |hdr| {
            a.free(hdr.name);
            a.free(hdr.value);
        }
        a.free(headers);
    }

    const method = parseMethod(p.method) orelse
        return .{ .outcome = .failed, .status = 0, .body = null, .err = "invalid method" };

    const resp = easy.request(a, .{
        .method = method,
        .url = p.url,
        .headers = headers,
        .body = if (method == .PUT or method == .POST) p.body else &.{},
        .timeout_ms = p.timeout_ms,
        .verify_tls = !test_allow_plaintext,
    }) catch |err| return .{
        .outcome = .failed,
        .status = 0,
        .body = null,
        .err = @errorName(err),
    };
    var resp_owned = resp;
    defer resp_owned.deinit(a);

    const body_full = resp_owned.body orelse "";
    const body_capped = if (body_full.len > p.max_body_bytes)
        body_full[0..p.max_body_bytes]
    else
        body_full;

    const outcome: schedule_server.Outcome = if (resp_owned.status >= 200 and resp_owned.status < 300)
        .delivered
    else
        .failed;

    // Own the capped body past `resp_owned.deinit`. The only added
    // alloc vs the pre-extraction inline path; an OOM here degrades
    // to a transport-style failure (on_result sees it) rather than
    // crashing — strictly safer.
    const owned = a.dupe(u8, body_capped) catch return .{
        .outcome = .failed,
        .status = resp_owned.status,
        .body = null,
        .err = "oom capturing response body",
    };
    return .{ .outcome = outcome, .status = resp_owned.status, .body = owned, .err = "" };
}

const SsrfError = error{
    BlockedAddress,
    HttpsRequired,
    InvalidUrl,
    UnresolvableHost,
    OutOfMemory,
};

fn checkSsrf(allocator: std.mem.Allocator, url: []const u8) SsrfError!void {
    const uri = std.Uri.parse(url) catch return SsrfError.InvalidUrl;
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const is_http = std.ascii.eqlIgnoreCase(uri.scheme, "http");
    if (!is_https and !(is_http and test_allow_plaintext)) return SsrfError.HttpsRequired;

    const host = switch (uri.host orelse return SsrfError.InvalidUrl) {
        .raw => |hh| hh,
        .percent_encoded => |hh| hh,
    };
    const port: u16 = uri.port orelse (if (is_https) @as(u16, 443) else @as(u16, 80));

    _ = ssrf.resolveSafe(allocator, host, port) catch |err| switch (err) {
        error.BlockedAddress => return SsrfError.BlockedAddress,
        error.EmptyHost => return SsrfError.InvalidUrl,
        error.OutOfMemory => return SsrfError.OutOfMemory,
        else => return SsrfError.UnresolvableHost,
    };
}

fn parseMethod(s: []const u8) ?blob_mod.curl.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
    return null;
}

/// Parse the row's `headers_json` (a JSON object string) into the
/// libcurl `Header` slice and stamp the platform-owned
/// `X-Rove-Schedule-Id` + `X-Rove-Schedule-Version` headers. Customer
/// attempts to set those reserved names are silently dropped.
/// Plan §7: upstream uses these headers as the natural idempotency key.
fn renderHeadersWithMeta(
    allocator: std.mem.Allocator,
    headers_json: []const u8,
    schedule_id: []const u8,
    version_str: []const u8,
) ![]blob_mod.curl.Header {
    var list: std.ArrayList(blob_mod.curl.Header) = .empty;
    errdefer {
        for (list.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        list.deinit(allocator);
    }

    if (headers_json.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidEnvelope,
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |kv| {
                const val_str = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-rove-schedule-id")) continue;
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-rove-schedule-version")) continue;
                const name_copy = try allocator.dupe(u8, kv.key_ptr.*);
                errdefer allocator.free(name_copy);
                const value_copy = try allocator.dupe(u8, val_str);
                errdefer allocator.free(value_copy);
                try list.append(allocator, .{ .name = name_copy, .value = value_copy });
            }
        }
    }

    const id_name = try allocator.dupe(u8, "X-Rove-Schedule-Id");
    errdefer allocator.free(id_name);
    const id_value = try allocator.dupe(u8, schedule_id);
    errdefer allocator.free(id_value);
    try list.append(allocator, .{ .name = id_name, .value = id_value });

    const ver_name = try allocator.dupe(u8, "X-Rove-Schedule-Version");
    errdefer allocator.free(ver_name);
    const ver_value = try allocator.dupe(u8, version_str);
    errdefer allocator.free(ver_value);
    try list.append(allocator, .{ .name = ver_name, .value = ver_value });

    return list.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "renderHeadersWithMeta stamps id + version, drops reserved" {
    const a = testing.allocator;
    const headers = try renderHeadersWithMeta(
        a,
        "{\"Content-Type\":\"application/json\",\"X-Rove-Schedule-Id\":\"forged\"}",
        "abc123",
        "7",
    );
    defer {
        for (headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(headers);
    }
    var saw_ct = false;
    var saw_id = false;
    var saw_ver = false;
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "Content-Type")) {
            saw_ct = true;
            try testing.expectEqualStrings("application/json", h.value);
        }
        if (std.mem.eql(u8, h.name, "X-Rove-Schedule-Id")) {
            saw_id = true;
            try testing.expectEqualStrings("abc123", h.value);
        }
        if (std.mem.eql(u8, h.name, "X-Rove-Schedule-Version")) {
            saw_ver = true;
            try testing.expectEqualStrings("7", h.value);
        }
    }
    try testing.expect(saw_ct);
    try testing.expect(saw_id);
    try testing.expect(saw_ver);
}

test "renderHeadersWithMeta tolerates empty headers_json" {
    const a = testing.allocator;
    const headers = try renderHeadersWithMeta(a, "", "x", "1");
    defer {
        for (headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(headers);
    }
    try testing.expectEqual(@as(usize, 2), headers.len);
}

test "checkSsrf rejects http://" {
    try testing.expectError(SsrfError.HttpsRequired, checkSsrf(testing.allocator, "http://example.com/"));
}

test "checkSsrf rejects loopback literal" {
    try testing.expectError(SsrfError.BlockedAddress, checkSsrf(testing.allocator, "https://127.0.0.1/"));
}

test "parseMethod recognizes the http verbs" {
    try testing.expect(parseMethod("GET").? == .GET);
    try testing.expect(parseMethod("POST").? == .POST);
    try testing.expect(parseMethod("put").? == .PUT);
    try testing.expect(parseMethod("DELETE").? == .DELETE);
    try testing.expect(parseMethod("FOO") == null);
}

test "fireOnce: offline failure mappings (the extracted checkSsrf branch)" {
    const a = testing.allocator;
    const easy = try blob_mod.curl.Easy.init(a); // unused on these paths
    defer easy.deinit();

    const base = FireParams{
        .url = undefined,
        .method = "POST",
        .headers_json = "{}",
        .body = "",
        .timeout_ms = 1000,
        .max_body_bytes = 1024,
        .id = "sid",
        .version_str = "1",
    };

    for ([_]struct { url: []const u8, err: []const u8 }{
        .{ .url = "not a url", .err = "invalid url" },
        .{ .url = "http://example.com/", .err = "https required" },
        .{ .url = "https://127.0.0.1/", .err = "blocked address (SSRF)" },
    }) |c| {
        var p = base;
        p.url = c.url;
        var r = fireOnce(a, easy, p);
        defer r.deinit(a);
        try testing.expectEqual(schedule_server.Outcome.failed, r.outcome);
        try testing.expectEqual(@as(u16, 0), r.status);
        try testing.expect(r.body == null);
        try testing.expectEqualStrings(c.err, r.err);
        try testing.expectEqualStrings("", r.bodyOr("")); // null → fallback
    }
}

