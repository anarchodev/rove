//! Webhook-server delivery thread (Phase 5.5 d, step 3).
//!
//! A leader-pinned poll loop inside the loop46 binary. On each tick,
//! if this node is the raft leader, scans `webhooks.db` for ready
//! rows, POSTs them to the customer's URL via `outbox/http_client`,
//! and proposes envelope 5 (`webhook_complete`) or envelope 6
//! (`webhook_retry_schedule`) through the local raft node.
//!
//! ## Why a poll loop and not start-on-leadership-acquired
//!
//! The plan's prose says "thread starts when leader, stops when
//! follower". A poll loop that gates per-tick on `raft.isLeader()`
//! achieves the same observable behavior with simpler lifecycle:
//!   - Become leader → next tick the gate opens, processing begins.
//!   - Lose leadership → next tick the gate closes, thread idles.
//!   - Process shutdown → `signalStop` flips, loop exits cleanly.
//! The wasted work on followers is one `isLeader` load every
//! `poll_interval_ms` (250ms default), but the loop also wakes
//! eagerly: `apply.applyWebhookEnqueueBatch` fires `signalWork()` on
//! this handle after writing new rows so a fresh enqueue ships within
//! the apply tick + delivery latency, not the next poll deadline. The
//! poll cadence stays as a backstop for retry-schedule applies whose
//! `next_attempt_ns` is in the future and for the leader-acquired
//! transition where existing rows need a kick.
//!
//! ## What this module owns
//!
//! - The poll loop + stop signal.
//! - One `WebhookStore` connection (opened at spawn, closed at join).
//!   This is a NOMUTEX SQLite connection bound to this thread; the
//!   raft thread has its own connection through `ApplyCtx`. WAL mode
//!   serializes the cross-connection writes.
//! - An in-memory in-flight set so a slow delivery doesn't get
//!   re-picked-up on the next tick before its envelope-5 commits.
//!   Lease columns in `webhooks.db` are reserved for cross-leader
//!   handover (post-v1).
//!
//! ## What it does NOT own
//!
//! - SSRF rules — reuses `outbox/ssrf.zig`.
//! - The HTTP client + body cap — reuses `outbox/http_client.zig`.
//! - JSON header rendering — duplicated locally because outbox's
//!   variant lives in the drainer-private file. Kept short and tested
//!   in `apply.zig`'s callback-shape tests.
//! - Tenant-side `_callback/{id}` writes — those happen in the apply
//!   path on every node when envelope 5 commits.

const std = @import("std");
const kv_mod = @import("rove-kv");
const ssrf = @import("ssrf.zig");
const http_client = @import("http_client.zig");

const webhook_server = @import("root.zig");

const MAX_PER_PASS: u32 = 64;

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// `{data_dir}` — `webhooks.db` lives at the top of this directory.
    data_dir: []const u8,
    raft: *kv_mod.RaftNode,
    /// Poll cadence when leader and idle. 250ms keeps webhook latency
    /// under a second even without the apply-side wakeup.
    poll_interval_ms: u32 = 250,
    /// Exponential-backoff base. Delay = jittered min(cap, base * 2^attempts).
    retry_base_ms: u32 = 1_000,
    retry_cap_ms: u32 = 5 * 60 * 1_000,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    /// Wake signal for early termination of the per-tick sleep. Apply
    /// path fires `signalWork` after envelope-4 / envelope-6 lands so
    /// the delivery loop picks the row up immediately instead of
    /// waiting out the rest of `poll_interval_ms`. `signalStop` also
    /// sets it so shutdown joins quickly.
    wake: std.Thread.ResetEvent,
    config: Config,

    pub fn signalStop(self: *Handle) void {
        self.stop_flag.store(true, .release);
        self.wake.set();
    }

    /// Apply path calls this after writing new rows to webhooks.db so
    /// the delivery loop wakes from its `timedWait` and processes the
    /// rows on this tick rather than the next polling deadline.
    /// Cheap (one futex wakeup); safe to call from any thread; safe to
    /// call when no thread is waiting (the next `timedWait` returns
    /// immediately and resets).
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
        std.log.err("webhook-server thread exited: {s}", .{@errorName(err)});
    };
}

fn runLoop(h: *Handle) !void {
    std.log.info("webhook-server: started", .{});

    const db_path = try std.fmt.allocPrintSentinel(
        h.allocator,
        "{s}/webhooks.db",
        .{h.config.data_dir},
        0,
    );
    defer h.allocator.free(db_path);

    var store = try webhook_server.WebhookStore.open(h.allocator, db_path);
    defer store.close();

    var in_flight: std.AutoHashMapUnmanaged([webhook_server.WEBHOOK_ID_HEX_LEN]u8, void) = .empty;
    defer in_flight.deinit(h.allocator);

    const seed: u64 = @bitCast(@as(i64, @truncate(std.time.nanoTimestamp())));
    var prng: std.Random.DefaultPrng = .init(seed);

    while (!h.stop_flag.load(.acquire)) {
        if (h.config.raft.isLeader()) {
            deliveryPass(h, &store, &in_flight, prng.random()) catch |err| {
                std.log.warn("webhook-server: pass error: {s}", .{@errorName(err)});
            };
        } else {
            // Drop in-flight bookkeeping when we're not leader — a
            // future leadership-acquired transition starts fresh.
            in_flight.clearRetainingCapacity();
        }
        // Wait up to `poll_interval_ms`, but return immediately when
        // `wake.set()` fires from the apply path. `timedWait` returns
        // `error.Timeout` on cadence expiry — both branches reset the
        // event so the next iteration rearms.
        h.wake.timedWait(@as(u64, h.config.poll_interval_ms) * std.time.ns_per_ms) catch {};
        h.wake.reset();
    }
    std.log.info("webhook-server: stopped", .{});
}

fn deliveryPass(
    h: *Handle,
    store: *webhook_server.WebhookStore,
    in_flight: *std.AutoHashMapUnmanaged([webhook_server.WEBHOOK_ID_HEX_LEN]u8, void),
    rand: std.Random,
) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const ready = try store.readyRows(h.allocator, now_ns, MAX_PER_PASS);
    defer {
        for (ready) |*r| {
            var x = r.*;
            x.deinit(h.allocator);
        }
        h.allocator.free(ready);
    }

    for (ready) |row| {
        if (in_flight.contains(row.row.webhook_id_hex)) continue;
        try in_flight.put(h.allocator, row.row.webhook_id_hex, {});
        defer _ = in_flight.remove(row.row.webhook_id_hex);

        deliverOne(h, &row, rand) catch |err| {
            std.log.warn(
                "webhook-server: deliver {s}: {s}",
                .{ row.row.webhook_id_hex[0..8], @errorName(err) },
            );
        };
    }
}

fn deliverOne(h: *Handle, row: *const webhook_server.StoredWebhook, rand: std.Random) !void {
    const a = h.allocator;
    const attempts_next: u32 = row.attempts + 1;

    var attempt_buf: [12]u8 = undefined;
    const attempt_str = try std.fmt.bufPrint(&attempt_buf, "{d}", .{attempts_next});

    const headers = renderHeadersWithMeta(
        a,
        row.row.headers_json,
        &row.row.webhook_id_hex,
        attempt_str,
    ) catch |err| {
        // Bad headers JSON → terminal failure; propose envelope 5 fail.
        std.log.warn(
            "webhook-server: {s}: bad headers ({s}), terminal",
            .{ row.row.webhook_id_hex[0..8], @errorName(err) },
        );
        try proposeComplete(h, row, .failed, attempts_next, 0, "");
        return;
    };
    defer a.free(headers);

    const result = http_client.deliver(a, .{
        .url = row.row.url,
        .method = row.row.method,
        .body = row.row.body,
        .headers = headers,
        .timeout_ms = row.row.timeout_ms,
    });

    switch (classify(result)) {
        .delivered => |resp| {
            defer {
                var r = resp;
                r.deinit();
            }
            std.log.info(
                "webhook-server: {s}: delivered status={d}",
                .{ row.row.webhook_id_hex[0..8], resp.status },
            );
            try proposeComplete(h, row, .delivered, attempts_next, resp.status, resp.body);
        },
        .retry => |err| {
            if (attempts_next >= row.row.max_attempts) {
                std.log.warn(
                    "webhook-server: {s}: attempts exhausted ({d}), terminal ({s})",
                    .{ row.row.webhook_id_hex[0..8], attempts_next, @errorName(err) },
                );
                try proposeComplete(h, row, .failed, attempts_next, 0, "");
                return;
            }
            const delay_ms = backoffDelayMs(h.config, attempts_next, rand);
            const next_at_ns = @as(i64, @intCast(std.time.nanoTimestamp())) +
                @as(i64, delay_ms) * std.time.ns_per_ms;
            std.log.info(
                "webhook-server: {s}: retry ({s}), attempt {d}/{d}, next in {d}ms",
                .{
                    row.row.webhook_id_hex[0..8],
                    @errorName(err),
                    attempts_next,
                    row.row.max_attempts,
                    delay_ms,
                },
            );
            try proposeRetrySchedule(h, row, attempts_next, next_at_ns);
        },
        .terminal => |err| {
            std.log.warn(
                "webhook-server: {s}: terminal ({s})",
                .{ row.row.webhook_id_hex[0..8], @errorName(err) },
            );
            try proposeComplete(h, row, .failed, attempts_next, 0, "");
        },
    }
}

fn proposeComplete(
    h: *Handle,
    row: *const webhook_server.StoredWebhook,
    outcome: webhook_server.Outcome,
    attempts: u32,
    status: u16,
    response_body: []const u8,
) !void {
    const a = h.allocator;
    const env = webhook_server.CompleteEnvelope{
        .webhook_id_hex = row.row.webhook_id_hex,
        .tenant_id = row.row.tenant_id,
        .outcome = outcome,
        .attempts = attempts,
        .status = status,
        .response_headers_json = "",
        .response_body = response_body,
    };
    const inner = try webhook_server.encodeComplete(a, &env);
    defer a.free(inner);

    const wrapped = try webhook_server.wrapApplyEnvelope(
        a,
        webhook_server.ENVELOPE_TYPE_COMPLETE,
        row.row.tenant_id,
        inner,
    );
    defer a.free(wrapped);

    const seq = h.config.raft.highWatermark() + 1;
    h.config.raft.propose(seq, wrapped) catch |err| {
        std.log.warn(
            "webhook-server: {s}: propose envelope-5 failed: {s}",
            .{ row.row.webhook_id_hex[0..8], @errorName(err) },
        );
        return err;
    };
}

fn proposeRetrySchedule(
    h: *Handle,
    row: *const webhook_server.StoredWebhook,
    attempts: u32,
    next_attempt_at_ns: i64,
) !void {
    const a = h.allocator;
    const env = webhook_server.RetryScheduleEnvelope{
        .webhook_id_hex = row.row.webhook_id_hex,
        .attempts = attempts,
        .next_attempt_at_ns = next_attempt_at_ns,
    };
    const inner = try webhook_server.encodeRetrySchedule(a, &env);
    defer a.free(inner);

    const wrapped = try webhook_server.wrapApplyEnvelope(
        a,
        webhook_server.ENVELOPE_TYPE_RETRY_SCHEDULE,
        "",
        inner,
    );
    defer a.free(wrapped);

    const seq = h.config.raft.highWatermark() + 1;
    h.config.raft.propose(seq, wrapped) catch |err| {
        std.log.warn(
            "webhook-server: {s}: propose envelope-6 failed: {s}",
            .{ row.row.webhook_id_hex[0..8], @errorName(err) },
        );
        return err;
    };
}

const AttemptOutcome = union(enum) {
    delivered: http_client.Response,
    retry: anyerror,
    terminal: anyerror,
};

/// Same classification rules as `outbox/drainer.zig`: 2xx is success;
/// 408/425/429/5xx + network errors retry; everything else is
/// terminal (URL-shaped errors, blocked addresses, malformed methods).
fn classify(result: http_client.DeliverError!http_client.Response) AttemptOutcome {
    if (result) |resp| {
        if (resp.status >= 200 and resp.status < 300) return .{ .delivered = resp };
        if (resp.status == 408 or resp.status == 425 or resp.status == 429 or resp.status >= 500) {
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

fn backoffDelayMs(config: Config, attempts: u32, rand: std.Random) u32 {
    const shift: u6 = @intCast(@min(attempts, 20));
    const raw: u64 = @as(u64, config.retry_base_ms) << shift;
    const capped: u64 = @min(raw, @as(u64, config.retry_cap_ms));
    if (capped == 0) return 0;
    return @intCast(rand.uintLessThan(u64, capped));
}

/// Parse the row's `headers_json` (a JSON object string) into the
/// `std.http.Header` slice the client wants, then append the
/// vendor-neutral `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt`
/// headers. Customer attempts to set those reserved names are
/// silently dropped — the platform owns them. Same shape and reserved
/// header semantics as `outbox/drainer.zig`'s `renderHeadersWithMeta`.
fn renderHeadersWithMeta(
    allocator: std.mem.Allocator,
    headers_json: []const u8,
    webhook_id_hex: []const u8,
    attempt_str: []const u8,
) ![]std.http.Header {
    var list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer list.deinit(allocator);

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
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-rove-webhook-id")) continue;
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-rove-webhook-attempt")) continue;
                // Header name + value are owned by `parsed`; std.json's
                // arena lives inside parsed.arena. The headers slice is
                // consumed before parsed.deinit ... wait — we DO deinit
                // parsed at the end of this function, before the caller
                // uses headers. Need to dupe.
                const name_copy = try allocator.dupe(u8, kv.key_ptr.*);
                errdefer allocator.free(name_copy);
                const value_copy = try allocator.dupe(u8, val_str);
                errdefer allocator.free(value_copy);
                try list.append(allocator, .{ .name = name_copy, .value = value_copy });
            }
        }
    }

    const id_copy = try allocator.dupe(u8, webhook_id_hex);
    errdefer allocator.free(id_copy);
    const attempt_copy = try allocator.dupe(u8, attempt_str);
    errdefer allocator.free(attempt_copy);
    try list.append(allocator, .{ .name = "X-Rove-Webhook-Id", .value = id_copy });
    try list.append(allocator, .{ .name = "X-Rove-Webhook-Attempt", .value = attempt_copy });
    return list.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "renderHeadersWithMeta parses customer headers + appends meta + drops reserved" {
    const a = testing.allocator;
    const headers = try renderHeadersWithMeta(
        a,
        "{\"Content-Type\":\"application/json\",\"X-Rove-Webhook-Id\":\"forged\"}",
        "deadbeef",
        "3",
    );
    defer {
        for (headers) |h| {
            a.free(@constCast(h.name));
            a.free(@constCast(h.value));
        }
        a.free(headers);
    }
    var saw_content_type = false;
    var saw_id = false;
    var saw_attempt = false;
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "Content-Type")) {
            saw_content_type = true;
            try testing.expectEqualStrings("application/json", h.value);
        }
        if (std.mem.eql(u8, h.name, "X-Rove-Webhook-Id")) {
            saw_id = true;
            try testing.expectEqualStrings("deadbeef", h.value);
        }
        if (std.mem.eql(u8, h.name, "X-Rove-Webhook-Attempt")) {
            saw_attempt = true;
            try testing.expectEqualStrings("3", h.value);
        }
    }
    try testing.expect(saw_content_type);
    try testing.expect(saw_id);
    try testing.expect(saw_attempt);
}

test "renderHeadersWithMeta tolerates empty headers_json" {
    const a = testing.allocator;
    const headers = try renderHeadersWithMeta(a, "", "abc", "1");
    defer {
        for (headers) |h| {
            a.free(@constCast(h.name));
            a.free(@constCast(h.value));
        }
        a.free(headers);
    }
    try testing.expectEqual(@as(usize, 2), headers.len);
}

test "backoffDelayMs caps at retry_cap_ms" {
    var prng: std.Random.DefaultPrng = .init(42);
    const cfg: Config = .{
        .allocator = testing.allocator,
        .data_dir = "x",
        .raft = undefined,
        .retry_base_ms = 1_000,
        .retry_cap_ms = 60_000,
    };
    // attempts=20 saturates the shift; uniform draw over [0, cap).
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const d = backoffDelayMs(cfg, 30, prng.random());
        try testing.expect(d < cfg.retry_cap_ms);
    }
}
