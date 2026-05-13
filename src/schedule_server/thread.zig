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

const MAX_PER_PASS: u32 = 64;

/// **TEST-ONLY** escape hatch that lets the scheduler talk to
/// `http://` URLs (in addition to `https://`). Paired with
/// `schedule_server.ssrf.test_allow_loopback` under loop46's
/// `--dev-webhook-unsafe` flag so smokes can point at on-box echo
/// servers. **Never set in production** — plaintext outbound leaks
/// request bodies on any intermediate hop.
pub var test_allow_plaintext: bool = false;

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Process-shared schedule store. Owned by the caller; we hold a
    /// pointer. Under kvexp every consumer of schedules.db must share
    /// one ScheduleStore — separate envs to the same file don't see
    /// each other's main_overlay writes.
    store: *schedule_server.ScheduleStore,
    raft: *kv_mod.RaftNode,
    /// Cap on idle sleep duration. Reached when the external pool has
    /// no future work scheduled — the thread still wakes occasionally
    /// to check `isLeader` and to log liveness. The apply path's
    /// wake-on-new-work means a cap this high doesn't add fire-time
    /// latency; rows still ship within an apply tick of arrival.
    idle_max_ms: u32 = 60_000,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    /// Wake signal for early termination of the per-tick sleep. Apply
    /// path fires `signalWork` after envelope-8 lands so the delivery
    /// loop picks the row up immediately instead of waiting out the
    /// rest of `poll_interval_ms`. `signalStop` also sets it so
    /// shutdown joins quickly.
    wake: std.Thread.ResetEvent,
    config: Config,

    pub fn signalStop(self: *Handle) void {
        self.stop_flag.store(true, .release);
        self.wake.set();
    }

    /// Cheap futex wakeup; safe from any thread; safe when nobody is
    /// waiting (next `timedWait` returns immediately and resets).
    pub fn signalWork(self: *Handle) void {
        self.wake.set();
    }

    pub fn join(self: *Handle) void {
        self.thread.join();
        self.allocator.destroy(self);
    }
};

pub fn spawn(config: Config) !*Handle {
    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .stop_flag = .init(false),
        .wake = .{},
        .config = config,
    };
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    return h;
}

fn threadMain(h: *Handle) void {
    runLoop(h) catch |err| {
        std.log.err("schedule-server thread exited: {s}", .{@errorName(err)});
    };
}

fn runLoop(h: *Handle) !void {
    std.log.info("schedule-server: started", .{});

    blob_mod.curl.globalInit();

    const store = h.config.store;

    var easy = try blob_mod.curl.Easy.init(h.allocator);
    defer easy.deinit();

    var in_flight: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = in_flight.iterator();
        while (it.next()) |entry| h.allocator.free(entry.key_ptr.*);
        in_flight.deinit(h.allocator);
    }

    while (!h.stop_flag.load(.acquire)) {
        if (h.config.raft.isLeader()) {
            deliveryPass(h, store, easy, &in_flight) catch |err| {
                std.log.warn("schedule-server: pass error: {s}", .{@errorName(err)});
            };
        } else {
            // Drop in-flight bookkeeping when we're not leader — a
            // future leadership-acquired transition starts fresh.
            var it = in_flight.iterator();
            while (it.next()) |entry| h.allocator.free(entry.key_ptr.*);
            in_flight.clearRetainingCapacity();
        }
        // Adaptive sleep: until the soonest external row's fire_at_ns
        // (capped at `idle_max_ms`). Apply-side wake fires when a
        // sooner row lands, so we don't oversleep new work. Followers
        // stay capped at idle_max_ms — they're not firing anything
        // anyway.
        const sleep_ns = computeSleepNs(store, h.config.idle_max_ms) catch
            @as(u64, h.config.idle_max_ms) * std.time.ns_per_ms;
        h.wake.timedWait(sleep_ns) catch {};
        h.wake.reset();
    }
    std.log.info("schedule-server: stopped", .{});
}

fn computeSleepNs(store: *schedule_server.ScheduleStore, idle_max_ms: u32) !u64 {
    const cap_ns: u64 = @as(u64, idle_max_ms) * std.time.ns_per_ms;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const next = (try store.nextExternalFireNs(now_ns)) orelse return cap_ns;
    const delta = next - now_ns;
    if (delta <= 0) return 0;
    return @min(@as(u64, @intCast(delta)), cap_ns);
}

/// Build the in-flight set key: `{tenant_id}\x00{id}`. NUL is a safe
/// separator — `validateId` rejects ids containing NUL, so the
/// concatenation is unambiguous.
fn buildInflightKey(allocator: std.mem.Allocator, tenant_id: []const u8, id: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, tenant_id.len + 1 + id.len);
    @memcpy(buf[0..tenant_id.len], tenant_id);
    buf[tenant_id.len] = 0;
    @memcpy(buf[tenant_id.len + 1 ..], id);
    return buf;
}

fn deliveryPass(
    h: *Handle,
    store: *schedule_server.ScheduleStore,
    easy: *blob_mod.curl.Easy,
    in_flight: *std.StringHashMapUnmanaged(void),
) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const ready = try store.dueRows(h.allocator, now_ns, MAX_PER_PASS);
    defer {
        for (ready) |*r| {
            var x = r.*;
            x.deinit(h.allocator);
        }
        h.allocator.free(ready);
    }

    for (ready) |stored| {
        const probe = try buildInflightKey(h.allocator, stored.row.tenant_id, stored.row.id);
        if (in_flight.contains(probe)) {
            h.allocator.free(probe);
            continue;
        }
        // `probe` is the stored key — owned by the hashmap until we
        // remove it below.
        try in_flight.put(h.allocator, probe, {});
        defer {
            const removed = in_flight.fetchRemove(probe);
            if (removed) |kv| h.allocator.free(kv.key);
        }

        deliverOne(h, easy, &stored) catch |err| {
            std.log.warn(
                "schedule-server: deliver {s}/{s}: {s}",
                .{ stored.row.tenant_id, stored.row.id, @errorName(err) },
            );
        };
    }
}

fn deliverOne(
    h: *Handle,
    easy: *blob_mod.curl.Easy,
    stored: *const schedule_server.StoredSchedule,
) !void {
    const a = h.allocator;
    const row = &stored.row;

    // SSRF check: resolve + reject blocked addresses BEFORE handing
    // the URL to libcurl. libcurl re-resolves internally so this is
    // racy against rebinding, but the hot-path check still catches
    // the common cases (literal RFC1918, EC2 metadata, loopback).
    checkSsrf(a, row.url) catch |err| switch (err) {
        error.BlockedAddress => {
            std.log.warn(
                "schedule-server: {s}/{s}: blocked address",
                .{ row.tenant_id, row.id },
            );
            try proposeComplete(h, stored, .failed, 0, "", "blocked address (SSRF)");
            return;
        },
        error.HttpsRequired => {
            try proposeComplete(h, stored, .failed, 0, "", "https required");
            return;
        },
        error.InvalidUrl => {
            try proposeComplete(h, stored, .failed, 0, "", "invalid url");
            return;
        },
        else => {
            // Network / OOM — propose a transport failure so the
            // customer's on_result handler sees it. (OOM here would
            // also fail the propose; the warn covers both.)
            try proposeComplete(h, stored, .failed, 0, "", @errorName(err));
            return;
        },
    };

    var version_buf: [12]u8 = undefined;
    const version_str = try std.fmt.bufPrint(&version_buf, "{d}", .{stored.version});

    const headers = renderHeadersWithMeta(a, row.headers_json, row.id, version_str) catch |err| {
        std.log.warn(
            "schedule-server: {s}/{s}: bad headers ({s})",
            .{ row.tenant_id, row.id, @errorName(err) },
        );
        try proposeComplete(h, stored, .failed, 0, "", "invalid headers");
        return;
    };
    defer {
        for (headers) |hdr| {
            a.free(hdr.name);
            a.free(hdr.value);
        }
        a.free(headers);
    }

    const method = parseMethod(row.method) orelse {
        try proposeComplete(h, stored, .failed, 0, "", "invalid method");
        return;
    };

    const verify_tls = !test_allow_plaintext;
    const resp = easy.request(a, .{
        .method = method,
        .url = row.url,
        .headers = headers,
        .body = if (method == .PUT or method == .POST) row.body else &.{},
        .timeout_ms = row.timeout_ms,
        .verify_tls = verify_tls,
    }) catch |err| {
        std.log.warn(
            "schedule-server: {s}/{s}: transport {s}",
            .{ row.tenant_id, row.id, @errorName(err) },
        );
        try proposeComplete(h, stored, .failed, 0, "", @errorName(err));
        return;
    };
    var resp_owned = resp;
    defer resp_owned.deinit(a);

    const body_full = resp_owned.body orelse "";
    const body_capped = if (body_full.len > row.max_body_bytes)
        body_full[0..row.max_body_bytes]
    else
        body_full;

    const outcome: schedule_server.Outcome = if (resp_owned.status >= 200 and resp_owned.status < 300)
        .delivered
    else
        .failed;

    std.log.info(
        "schedule-server: {s}/{s}: status={d} outcome={s}",
        .{ row.tenant_id, row.id, resp_owned.status, @tagName(outcome) },
    );
    try proposeComplete(h, stored, outcome, resp_owned.status, body_capped, "");
}

fn proposeComplete(
    h: *Handle,
    stored: *const schedule_server.StoredSchedule,
    outcome: schedule_server.Outcome,
    status: u16,
    response_body: []const u8,
    error_message: []const u8,
) !void {
    const a = h.allocator;
    const env: schedule_server.CompleteEnvelope = .{
        .tenant_id = stored.row.tenant_id,
        .id = stored.row.id,
        .version_at_fire = stored.version,
        .outcome = outcome,
        .status = status,
        .response_headers_json = "",
        .response_body = response_body,
        .error_message = error_message,
    };
    const inner = try schedule_server.encodeComplete(a, &env);
    defer a.free(inner);

    // Wrap in the typed envelope (type=9). schedule_server doesn't
    // know about apply.zig's envelope wrapper format, so we
    // hand-assemble: `[1B type][2B id_len BE][id bytes][payload]`.
    // tenant_id rides in the wrapper header so the apply path can
    // use it without decoding the inner payload twice.
    const tenant_id = stored.row.tenant_id;
    if (tenant_id.len > 0xffff) return error.InvalidEnvelope;
    const wrapped_len = 1 + 2 + tenant_id.len + inner.len;
    const wrapped = try a.alloc(u8, wrapped_len);
    defer a.free(wrapped);
    wrapped[0] = schedule_server.ENVELOPE_TYPE_COMPLETE;
    std.mem.writeInt(u16, wrapped[1..3], @intCast(tenant_id.len), .big);
    @memcpy(wrapped[3..][0..tenant_id.len], tenant_id);
    @memcpy(wrapped[3 + tenant_id.len ..][0..inner.len], inner);

    const seq = h.config.raft.highWatermark() + 1;
    h.config.raft.propose(seq, wrapped) catch |err| {
        std.log.warn(
            "schedule-server: {s}/{s}: propose envelope-9 failed: {s}",
            .{ tenant_id, stored.row.id, @errorName(err) },
        );
        return err;
    };
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

