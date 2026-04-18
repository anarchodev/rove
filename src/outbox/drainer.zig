//! Webhook drainer thread.
//!
//! Scans `_outbox/*` across tenants, calls the HTTP client, and
//! updates / deletes / DLQs rows based on the outcome. Runs only when
//! the raft node is the leased leader so two leaders don't
//! double-deliver.
//!
//! ## Design notes (slice 3a scope)
//!
//! - **Single thread.** Multi-threaded drainer + inflight leases land
//!   in slice 3c alongside real failover resilience.
//! - **No raft propagation of drainer state changes.** A successful
//!   delete / retry bump / DLQ move is a local SQLite write on the
//!   leader's copy. Followers still have the original envelope from
//!   the handler's raft-propagated commit; on leader failover, the
//!   new leader re-scans and may re-deliver. Receivers dedup on the
//!   `X-Rove-Webhook-Id` header per PLAN §2.6 at-least-once semantics.
//! - **Iterates every known tenant every 250ms.** Known LRU hot spot:
//!   when the LRU cache eviction lands, this scan would keep every
//!   tenant warm. Slice 3b adds a `__root__/outbox_pending/{instance}`
//!   marker that the drainer consults first, opening tenants only
//!   when they have work. Documented and planned.
//! - **Callback dispatch is stubbed.** When a row finishes (success
//!   or terminal), `deliveredResult` logs an info line; the actual
//!   callback-invocation path lands in commit 5.

const std = @import("std");
const kv_mod = @import("rove-kv");
const http_client = @import("http_client.zig");
const ssrf = @import("ssrf.zig");

pub const InstanceInfo = struct {
    /// Tenant id. Borrowed — valid only for the duration of the
    /// callback's return value.
    id: []const u8,
    /// Path to `{data_dir}/{id}`. Drainer opens `{dir}/app.db` from
    /// here. Borrowed — same lifetime as `id`.
    dir: []const u8,
};

pub const InstanceProvider = struct {
    /// Returns the current set of tenants to scan. Caller owns the
    /// returned slice; the drainer calls `deinit` after each pass.
    /// Implementation is responsible for its own synchronization
    /// against concurrent tenant creates.
    snapshot: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]InstanceInfo,
    deinit: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, slice: []InstanceInfo) void,
    ctx: ?*anyopaque = null,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    raft: *kv_mod.RaftNode,
    instances: InstanceProvider,
    /// How often the drainer wakes and scans when idle. 250ms keeps
    /// worst-case webhook latency under a second while leaving plenty
    /// of breathing room between iterations at tens-of-tenants scale.
    poll_interval_ms: u32 = 250,
    /// Exponential-backoff base for retries. Delay = full-jittered
    /// `min(cap, base * 2^attempt)`.
    retry_base_ms: u32 = 1_000,
    retry_cap_ms: u32 = 5 * 60 * 1_000,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    config: Config,

    pub fn signalStop(self: *Handle) void {
        self.stop_flag.store(true, .release);
    }

    pub fn join(self: *Handle) void {
        self.thread.join();
        self.allocator.destroy(self);
    }
};

/// Launch the drainer on its own thread. Caller must eventually
/// `signalStop` + `join` — the drainer won't exit on its own.
pub fn spawn(config: Config) !*Handle {
    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .stop_flag = .init(false),
        .config = config,
    };
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    return h;
}

fn threadMain(h: *Handle) void {
    runLoop(h) catch |err| {
        std.log.err("outbox drainer thread exited: {s}", .{@errorName(err)});
    };
}

fn runLoop(h: *Handle) !void {
    std.log.info("outbox drainer: started", .{});
    const seed: u64 = @bitCast(@as(i64, @truncate(std.time.nanoTimestamp())));
    var prng: std.Random.DefaultPrng = .init(seed);

    while (!h.stop_flag.load(.acquire)) {
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (h.config.raft.isLeasedLeader(now_ns)) {
            drainOnce(h, prng.random()) catch |err| {
                std.log.warn("outbox drainer: scan error: {s}", .{@errorName(err)});
            };
        }
        std.Thread.sleep(@as(u64, h.config.poll_interval_ms) * std.time.ns_per_ms);
    }
    std.log.info("outbox drainer: stopped", .{});
}

/// One scan pass: snapshot the tenant set, deliver any ready rows.
fn drainOnce(h: *Handle, rand: std.Random) !void {
    const slice = try h.config.instances.snapshot(h.config.instances.ctx, h.allocator);
    defer h.config.instances.deinit(h.config.instances.ctx, h.allocator, slice);

    for (slice) |inst| {
        drainTenant(h, inst, rand) catch |err| {
            std.log.warn(
                "outbox drainer: tenant {s}: {s}",
                .{ inst.id, @errorName(err) },
            );
        };
    }
}

fn drainTenant(h: *Handle, inst: InstanceInfo, rand: std.Random) !void {
    // Open a per-call kv connection. NOMUTEX requires one connection
    // per thread; the worker threads own theirs, we own ours.
    // Short-lived so we don't hold fds while idle — revisit when the
    // root-marker path lands.
    const db_path = try std.fmt.allocPrintSentinel(
        h.allocator,
        "{s}/app.db",
        .{inst.dir},
        0,
    );
    defer h.allocator.free(db_path);

    const kv = kv_mod.KvStore.open(h.allocator, db_path) catch |err| {
        // Tenants that don't exist on disk yet (e.g., bootstrap race)
        // are skipped silently. Everything else is an actual error.
        if (err == error.FileNotFound) return;
        return err;
    };
    defer kv.close();

    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    // Prefix-scan for rows. Cap per-pass work so one busy tenant
    // doesn't starve others. 64 is generous — at the 250ms tick that's
    // ~250 deliveries/s per tenant if every row is ready at once.
    const MAX_PER_PASS = 64;
    var scan = try kv.prefix("_outbox/", "", MAX_PER_PASS);
    defer scan.deinit();

    for (scan.entries) |entry| {
        deliverOne(h, inst, kv, entry.key, entry.value, now_ms, rand) catch |err| {
            std.log.warn(
                "outbox drainer: {s}/{s}: {s}",
                .{ inst.id, entry.key, @errorName(err) },
            );
        };
    }
}

fn deliverOne(
    h: *Handle,
    inst: InstanceInfo,
    kv: *kv_mod.KvStore,
    key: []const u8,
    envelope_bytes: []const u8,
    now_ms: i64,
    rand: std.Random,
) !void {
    var parsed = std.json.parseFromSlice(Envelope, h.allocator, envelope_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn(
            "outbox drainer: {s}/{s}: malformed envelope ({s}), moving to _dlq",
            .{ inst.id, key, @errorName(err) },
        );
        try moveToDlq(h.allocator, kv, key, envelope_bytes, "malformed envelope");
        return;
    };
    defer parsed.deinit();
    const env = parsed.value;

    if (env.next_attempt_at_ms > now_ms) return; // not ready yet

    // Delivery. Method/body/headers are owned by the parsed arena.
    const headers = try renderHeaders(h.allocator, env.headers);
    defer h.allocator.free(headers);

    const outcome = classifyAttempt(http_client.deliver(h.allocator, .{
        .url = env.url,
        .method = env.method,
        .body = env.body,
        .headers = headers,
        .timeout_ms = env.timeout_ms,
    }));

    switch (outcome) {
        .delivered => |resp| {
            defer {
                var r = resp;
                r.deinit();
            }
            std.log.info(
                "outbox drainer: {s}/{s}: delivered status={d} (truncated={})",
                .{ inst.id, key, resp.status, resp.truncated },
            );
            // TODO(slice 3a.5): enqueue the onResult callback with
            // outcome=delivered, response, attempts.
            try kv.delete(key);
        },
        .retry => |err| {
            const attempts_next = env.attempts + 1;
            if (attempts_next >= env.max_attempts) {
                std.log.warn(
                    "outbox drainer: {s}/{s}: attempts exhausted ({d}), moving to _dlq ({s})",
                    .{ inst.id, key, attempts_next, @errorName(err) },
                );
                try moveToDlq(h.allocator, kv, key, envelope_bytes, @errorName(err));
                // TODO(slice 3a.5): enqueue onResult callback with
                // outcome=failed.
                return;
            }
            const delay = backoffDelayMs(h.config, attempts_next, rand);
            const next_at = now_ms + @as(i64, @intCast(delay));
            std.log.info(
                "outbox drainer: {s}/{s}: retryable ({s}), attempt {d}/{d}, next in {d}ms",
                .{ inst.id, key, @errorName(err), attempts_next, env.max_attempts, delay },
            );
            try rescheduleEnvelope(h.allocator, kv, key, envelope_bytes, attempts_next, next_at);
        },
        .terminal => |err| {
            std.log.warn(
                "outbox drainer: {s}/{s}: terminal ({s}), moving to _dlq",
                .{ inst.id, key, @errorName(err) },
            );
            try moveToDlq(h.allocator, kv, key, envelope_bytes, @errorName(err));
            // TODO(slice 3a.5): enqueue onResult callback with
            // outcome=failed.
        },
    }
}

const Envelope = struct {
    v: i32 = 1,
    id: []const u8,
    url: []const u8,
    method: []const u8,
    headers: std.json.Value = .null,
    body: []const u8 = "",
    on_result: ?[]const u8 = null,
    context: std.json.Value = .null,
    max_attempts: i32 = 10,
    timeout_ms: u32 = 30_000,
    retry_on: std.json.Value = .null,
    attempts: i32 = 0,
    next_attempt_at_ms: i64 = 0,
    created_at_ms: i64 = 0,
    parent_request_id: i64 = 0,
};

/// Flatten a JSON-object `headers` into the std.http.Header slice the
/// client wants. Non-object headers → empty.
fn renderHeaders(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]std.http.Header {
    const obj = switch (value) {
        .object => |o| o,
        else => return try allocator.alloc(std.http.Header, 0),
    };
    var list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer list.deinit(allocator);
    var it = obj.iterator();
    while (it.next()) |kv| {
        const val_str = switch (kv.value_ptr.*) {
            .string => |s| s,
            else => continue, // drop non-string header values
        };
        try list.append(allocator, .{ .name = kv.key_ptr.*, .value = val_str });
    }
    return list.toOwnedSlice(allocator);
}

const AttemptOutcome = union(enum) {
    delivered: http_client.Response,
    retry: anyerror,
    terminal: anyerror,
};

/// Classify a delivery attempt. 2xx is success; 408/429/5xx and network
/// failures retry; everything else is terminal.
fn classifyAttempt(result: http_client.DeliverError!http_client.Response) AttemptOutcome {
    if (result) |resp| {
        if (resp.status >= 200 and resp.status < 300) return .{ .delivered = resp };
        if (resp.status == 408 or resp.status == 425 or resp.status == 429 or resp.status >= 500) {
            // Throw away the body — we reclassify as retry.
            var r = resp;
            r.deinit();
            return .{ .retry = error.HttpStatusRetryable };
        }
        var r = resp;
        r.deinit();
        return .{ .terminal = error.HttpStatusTerminal };
    } else |err| switch (err) {
        error.BlockedAddress, error.HttpsRequired, error.InvalidUrl, error.InvalidMethod => {
            return .{ .terminal = err };
        },
        else => return .{ .retry = err },
    }
}

/// Full-jitter exponential: delay = uniform(0, min(cap, base * 2^attempt)).
fn backoffDelayMs(config: Config, attempts: i32, rand: std.Random) u32 {
    // Guard against overflow: after ~20 attempts we're at cap anyway.
    const shift: u6 = @intCast(@min(attempts, 20));
    const raw: u64 = @as(u64, config.retry_base_ms) << shift;
    const capped: u64 = @min(raw, @as(u64, config.retry_cap_ms));
    if (capped == 0) return 0;
    return @intCast(rand.uintLessThan(u64, capped));
}

fn rescheduleEnvelope(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    key: []const u8,
    envelope_bytes: []const u8,
    attempts_next: i32,
    next_attempt_at_ms: i64,
) !void {
    const rewritten = try rewriteAttempts(allocator, envelope_bytes, attempts_next, next_attempt_at_ms);
    defer allocator.free(rewritten);
    try kv.put(key, rewritten);
}

fn moveToDlq(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    outbox_key: []const u8,
    envelope_bytes: []const u8,
    reason: []const u8,
) !void {
    std.debug.assert(std.mem.startsWith(u8, outbox_key, "_outbox/"));
    const id = outbox_key["_outbox/".len..];
    var dlq_key_buf: [5 + 64]u8 = undefined;
    const dlq_key = std.fmt.bufPrint(&dlq_key_buf, "_dlq/{s}", .{id}) catch return error.InvalidKey;

    // Append a `last_error` field to the envelope for post-mortem.
    const with_error = try appendLastError(allocator, envelope_bytes, reason);
    defer allocator.free(with_error);
    try kv.put(dlq_key, with_error);
    try kv.delete(outbox_key);
}

/// Parse `envelope_bytes`, patch attempts + next_attempt_at_ms, and
/// return the re-serialized JSON. `std.json.stringify` preserves
/// object shape — existing fields, including headers / context /
/// retry_on, round-trip verbatim.
fn rewriteAttempts(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
    attempts: i32,
    next_attempt_at_ms: i64,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        envelope_bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |*o| o,
        else => return error.InvalidEnvelope,
    };
    try obj.put("attempts", .{ .integer = attempts });
    try obj.put("next_attempt_at_ms", .{ .integer = next_attempt_at_ms });
    return try stringifyAlloc(allocator, parsed.value);
}

fn appendLastError(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
    reason: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        envelope_bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |*o| o,
        else => return error.InvalidEnvelope,
    };
    try obj.put("last_error", .{ .string = reason });
    return try stringifyAlloc(allocator, parsed.value);
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return try aw.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "backoffDelayMs: grows exponentially, capped" {
    var prng: std.Random.DefaultPrng = .init(42);
    const rand = prng.random();
    const cfg: Config = .{
        .allocator = testing.allocator,
        .raft = undefined,
        .instances = undefined,
        .retry_base_ms = 100,
        .retry_cap_ms = 10_000,
    };
    // 100 samples per attempt value to confirm bounds.
    var attempt: i32 = 1;
    while (attempt <= 6) : (attempt += 1) {
        const max_expected: u64 = @min(
            @as(u64, cfg.retry_base_ms) << @as(u6, @intCast(attempt)),
            @as(u64, cfg.retry_cap_ms),
        );
        var sample: usize = 0;
        while (sample < 100) : (sample += 1) {
            const d = backoffDelayMs(cfg, attempt, rand);
            try testing.expect(d < max_expected);
        }
    }
}

test "classifyAttempt: 2xx delivered, 5xx retry, 4xx terminal" {
    const ok = http_client.Response{
        .status = 204,
        .body = &[_]u8{},
        .truncated = false,
        .allocator = testing.allocator,
    };
    switch (classifyAttempt(@as(http_client.DeliverError!http_client.Response, ok))) {
        .delivered => |r| {
            var rr = r;
            rr.deinit();
        },
        else => try testing.expect(false),
    }

    const srv_err = http_client.Response{
        .status = 503,
        .body = &[_]u8{},
        .truncated = false,
        .allocator = testing.allocator,
    };
    try testing.expect(classifyAttempt(srv_err) == .retry);

    const too_many = http_client.Response{
        .status = 429,
        .body = &[_]u8{},
        .truncated = false,
        .allocator = testing.allocator,
    };
    try testing.expect(classifyAttempt(too_many) == .retry);

    const not_found = http_client.Response{
        .status = 404,
        .body = &[_]u8{},
        .truncated = false,
        .allocator = testing.allocator,
    };
    try testing.expect(classifyAttempt(not_found) == .terminal);
}

test "classifyAttempt: SSRF + invalid URL are terminal, network retries" {
    try testing.expect(classifyAttempt(http_client.DeliverError.BlockedAddress) == .terminal);
    try testing.expect(classifyAttempt(http_client.DeliverError.HttpsRequired) == .terminal);
    try testing.expect(classifyAttempt(http_client.DeliverError.InvalidUrl) == .terminal);
    try testing.expect(classifyAttempt(http_client.DeliverError.Network) == .retry);
    try testing.expect(classifyAttempt(http_client.DeliverError.Timeout) == .retry);
    try testing.expect(classifyAttempt(http_client.DeliverError.Tls) == .retry);
}

test "rewriteAttempts: patches fields, preserves everything else" {
    const original =
        \\{"v":1,"id":"abc","url":"https://x/","method":"POST","attempts":0,
        \\ "next_attempt_at_ms":0,"context":{"charge":"c1"},"headers":{"X":"Y"}}
    ;
    const out = try rewriteAttempts(testing.allocator, original, 3, 12345);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("attempts").?.integer);
    try testing.expectEqual(@as(i64, 12345), parsed.value.object.get("next_attempt_at_ms").?.integer);
    try testing.expectEqualStrings("abc", parsed.value.object.get("id").?.string);
    try testing.expectEqualStrings(
        "c1",
        parsed.value.object.get("context").?.object.get("charge").?.string,
    );
}

test "appendLastError: stamps reason" {
    const original = "{\"id\":\"abc\",\"url\":\"https://x/\"}";
    const out = try appendLastError(testing.allocator, original, "BlockedAddress");
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("BlockedAddress", parsed.value.object.get("last_error").?.string);
}
