//! Webhook drainer thread.
//!
//! Scans `_outbox/*` across tenants, calls the HTTP client, and
//! updates / deletes / DLQs rows based on the outcome. Runs only when
//! the raft node is the leased leader so two leaders don't
//! double-deliver.
//!
//! ## Design notes (slice 3a + 3b scope)
//!
//! - **Single thread.** Multi-threaded drainer lands in slice 3c
//!   alongside per-destination rate shaping.
//! - **Inflight lease.** Before calling `http_client.deliver`, the
//!   row moves `_outbox/{id}` → `_outbox_inflight/{id}` with a
//!   `leased_at_ms` stamp. Success clears the lease; retry writes
//!   the row back to `_outbox/{id}`; terminal failure moves it to
//!   `_dlq/{id}`. Every pass sweeps leases older than
//!   `lease_stale_after_ms` back into `_outbox/*` — the recovery
//!   path for a drainer crash or leader failover mid-delivery.
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
//! - **Callback dispatch.** On delivery complete (success or
//!   terminal), `writeCallback` persists `_callback/{id}`; the
//!   tenant-side `dispatchCallbacks` phase in rove-js drains those
//!   receipts and invokes the customer's `onResult` handler.

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
    /// Lease records older than this get swept back into `_outbox/*`
    /// on every drain pass. A running drainer's own leases are
    /// cleared inline as each delivery completes, so the only rows a
    /// sweep ever observes are prior-run orphans (drainer crash,
    /// process restart, leader failover after local inflight write).
    /// Default 2× the per-attempt HTTP timeout (default 30s) — big
    /// enough to never race a slow-but-alive delivery, small enough
    /// that a real crash recovers in under a minute.
    lease_stale_after_ms: i64 = 60_000,
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

    // Phase 1: recover orphan leases first. Anything in `_outbox_inflight/*`
    // older than `lease_stale_after_ms` is from a prior crash/restart —
    // move it back to `_outbox/*` so the normal scan picks it up.
    sweepStaleLeases(h, inst, kv, now_ms) catch |err| {
        std.log.warn(
            "outbox drainer: {s}: stale-lease sweep: {s}",
            .{ inst.id, @errorName(err) },
        );
    };

    // Phase 2: prefix-scan ready rows. Cap per-pass work so one busy
    // tenant doesn't starve others. 64 is generous — at the 250ms
    // tick that's ~250 deliveries/s per tenant if every row is ready
    // at once.
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

/// Move every `_outbox_inflight/*` row whose `leased_at_ms` is older
/// than `config.lease_stale_after_ms` back to `_outbox/{id}`. Called
/// once per drain pass, before the main scan. See the module doc for
/// the at-least-once reasoning.
fn sweepStaleLeases(
    h: *Handle,
    inst: InstanceInfo,
    kv: *kv_mod.KvStore,
    now_ms: i64,
) !void {
    const MAX_PER_SWEEP = 64;
    var scan = try kv.prefix("_outbox_inflight/", "", MAX_PER_SWEEP);
    defer scan.deinit();
    const threshold = h.config.lease_stale_after_ms;
    for (scan.entries) |entry| {
        const leased_at = extractLeasedAtMs(entry.value) orelse continue;
        if (now_ms - leased_at < threshold) continue;
        // Preserve attempts — we don't know if delivery happened;
        // receivers dedup on `X-Rove-Webhook-Id` per PLAN §2.6.
        returnLeaseToOutbox(h.allocator, kv, entry.key, entry.value) catch |err| {
            std.log.warn(
                "outbox drainer: {s}/{s}: recover lease: {s}",
                .{ inst.id, entry.key, @errorName(err) },
            );
            continue;
        };
        std.log.info(
            "outbox drainer: {s}/{s}: stale lease recovered ({d}ms old)",
            .{ inst.id, entry.key, now_ms - leased_at },
        );
    }
}

fn deliverOne(
    h: *Handle,
    inst: InstanceInfo,
    kv: *kv_mod.KvStore,
    outbox_key: []const u8,
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
            .{ inst.id, outbox_key, @errorName(err) },
        );
        try moveToDlq(h.allocator, kv, outbox_key, envelope_bytes, "malformed envelope");
        return;
    };
    defer parsed.deinit();
    const env = parsed.value;

    if (env.next_attempt_at_ms > now_ms) return; // not ready yet

    // Take out the lease BEFORE calling the network. If the drainer
    // crashes inside `deliver`, the next pass's stale-lease sweep
    // recovers the row; receivers dedup via `X-Rove-Webhook-Id`.
    const leased_bytes = try leaseEnvelope(h.allocator, kv, outbox_key, envelope_bytes, now_ms);
    defer h.allocator.free(leased_bytes);

    const inflight_key = try formatKey(h.allocator, "_outbox_inflight/", env.id);
    defer h.allocator.free(inflight_key);

    // Delivery. Method/body/headers are owned by the parsed arena.
    // We also stamp two vendor-neutral metadata headers so receivers
    // can dedup (at-least-once semantics — PLAN §2.6).
    var attempt_buf: [12]u8 = undefined;
    const attempt_str = std.fmt.bufPrint(
        &attempt_buf,
        "{d}",
        .{env.attempts + 1},
    ) catch return error.InvalidEnvelope;

    const headers = try renderHeadersWithMeta(h.allocator, env.headers, env.id, attempt_str);
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
                .{ inst.id, outbox_key, resp.status, resp.truncated },
            );
            try writeCallback(h.allocator, kv, env, .{
                .outcome = "delivered",
                .status = resp.status,
                .body = resp.body,
                .truncated = resp.truncated,
                .attempts = env.attempts + 1,
                .err = null,
            });
            try kv.delete(inflight_key);
        },
        .retry => |err| {
            const attempts_next = env.attempts + 1;
            if (attempts_next >= env.max_attempts) {
                std.log.warn(
                    "outbox drainer: {s}/{s}: attempts exhausted ({d}), moving to _dlq ({s})",
                    .{ inst.id, outbox_key, attempts_next, @errorName(err) },
                );
                try writeCallback(h.allocator, kv, env, .{
                    .outcome = "failed",
                    .status = 0,
                    .body = "",
                    .truncated = false,
                    .attempts = attempts_next,
                    .err = @errorName(err),
                });
                try moveInflightToDlq(h.allocator, kv, inflight_key, leased_bytes, @errorName(err));
                return;
            }
            const delay = backoffDelayMs(h.config, attempts_next, rand);
            const next_at = now_ms + @as(i64, @intCast(delay));
            std.log.info(
                "outbox drainer: {s}/{s}: retryable ({s}), attempt {d}/{d}, next in {d}ms",
                .{ inst.id, outbox_key, @errorName(err), attempts_next, env.max_attempts, delay },
            );
            try returnLeaseToOutboxWithAttempts(h.allocator, kv, inflight_key, leased_bytes, attempts_next, next_at);
        },
        .terminal => |err| {
            std.log.warn(
                "outbox drainer: {s}/{s}: terminal ({s}), moving to _dlq",
                .{ inst.id, outbox_key, @errorName(err) },
            );
            try writeCallback(h.allocator, kv, env, .{
                .outcome = "failed",
                .status = 0,
                .body = "",
                .truncated = false,
                .attempts = env.attempts + 1,
                .err = @errorName(err),
            });
            try moveInflightToDlq(h.allocator, kv, inflight_key, leased_bytes, @errorName(err));
        },
    }
}

// ── Callback receipts ────────────────────────────────────────────────
//
// When a webhook finishes (delivered or terminally failed), the
// drainer records an event envelope at `_callback/{id}` so a future
// handler dispatcher can invoke the customer's `on_result` hook. This
// commit only writes the receipt — the dispatcher that consumes them
// lands in a follow-up.
//
// Schema:
//   {
//     "webhook_id": "<64-hex>",
//     "on_result": "path/to/handler" | null,
//     "outcome": "delivered" | "failed",
//     "attempts": N,
//     "context": <opaque user JSON>,
//     "response": { "status": int, "body": string, "truncated": bool },  // delivered only
//     "error": "ErrorName"   // failed only
//   }

const CallbackInput = struct {
    outcome: []const u8,
    status: u16,
    body: []const u8,
    truncated: bool,
    attempts: i32,
    err: ?[]const u8,
};

fn writeCallback(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    env: Envelope,
    input: CallbackInput,
) !void {
    if (env.on_result == null) return; // customer didn't want a callback

    var obj: std.json.ObjectMap = .init(allocator);
    defer obj.deinit();
    try obj.put("webhook_id", .{ .string = env.id });
    try obj.put("on_result", .{ .string = env.on_result.? });
    try obj.put("outcome", .{ .string = input.outcome });
    try obj.put("attempts", .{ .integer = input.attempts });
    try obj.put("context", env.context);

    if (std.mem.eql(u8, input.outcome, "delivered")) {
        var resp_obj: std.json.ObjectMap = .init(allocator);
        // resp_obj is moved into the Value below — do NOT deinit here.
        try resp_obj.put("status", .{ .integer = @as(i64, @intCast(input.status)) });
        try resp_obj.put("body", .{ .string = input.body });
        try resp_obj.put("truncated", .{ .bool = input.truncated });
        try obj.put("response", .{ .object = resp_obj });
    } else if (input.err) |e| {
        try obj.put("error", .{ .string = e });
    }

    const body = try stringifyAlloc(allocator, .{ .object = obj });
    defer allocator.free(body);

    var key_buf: [10 + 64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "_callback/{s}", .{env.id}) catch return error.InvalidKey;
    try kv.put(key, body);
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
/// client wants, then append the vendor-neutral metadata headers
/// (`X-Rove-Webhook-Id` stable across retries; `X-Rove-Webhook-Attempt`
/// = the attempt we're about to make, 1-based). Non-object `headers`
/// is treated as empty. Customer headers with the same name come
/// FIRST so the metadata headers win on duplicate lookups that read
/// "last value wins" — a conservative choice given std.http doesn't
/// de-duplicate on send.
fn renderHeadersWithMeta(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    webhook_id: []const u8,
    attempt_str: []const u8,
) ![]std.http.Header {
    var list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    errdefer list.deinit(allocator);

    if (value == .object) {
        var it = value.object.iterator();
        while (it.next()) |kv| {
            const val_str = switch (kv.value_ptr.*) {
                .string => |s| s,
                else => continue, // drop non-string header values
            };
            // Silently drop any customer attempt to set the reserved
            // metadata header names — we control those.
            if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-rove-webhook-id")) continue;
            if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-rove-webhook-attempt")) continue;
            try list.append(allocator, .{ .name = kv.key_ptr.*, .value = val_str });
        }
    }

    try list.append(allocator, .{ .name = "X-Rove-Webhook-Id", .value = webhook_id });
    try list.append(allocator, .{ .name = "X-Rove-Webhook-Attempt", .value = attempt_str });
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

// ── Lease helpers ─────────────────────────────────────────────────
//
// Leases live at `_outbox_inflight/{id}` for the duration of a
// delivery attempt. All four transitions (take / clear / return /
// dlq) are two SQLite writes that are NOT txn-wrapped — on a crash
// between them, the next pass's stale-lease sweep converges the
// state. `_outbox/{id}` + `_outbox_inflight/{id}` simultaneously
// present for the same id means "row in flight"; the stale-sweep
// harmlessly re-queues the inflight clone if its lease has aged out,
// and the live drainer clears it once delivery completes.

/// Move `_outbox/{id}` → `_outbox_inflight/{id}`, stamping
/// `leased_at_ms` onto the envelope so stale leases can be detected
/// later. Returns the written (lease-stamped) envelope bytes — the
/// caller uses them for the DLQ / retry branches without re-reading.
fn leaseEnvelope(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    outbox_key: []const u8,
    envelope_bytes: []const u8,
    now_ms: i64,
) ![]u8 {
    std.debug.assert(std.mem.startsWith(u8, outbox_key, "_outbox/"));
    const id = outbox_key["_outbox/".len..];
    const inflight_key = try formatKey(allocator, "_outbox_inflight/", id);
    defer allocator.free(inflight_key);

    const stamped = try stampLeasedAt(allocator, envelope_bytes, now_ms);
    errdefer allocator.free(stamped);
    try kv.put(inflight_key, stamped);
    try kv.delete(outbox_key);
    return stamped;
}

/// Retry branch: rewrite attempts + next_attempt_at_ms, drop the
/// `leased_at_ms` field, write back to `_outbox/{id}`, and delete
/// the inflight row. Matches the original `rescheduleEnvelope`
/// behavior once the in-flight model is threaded through.
fn returnLeaseToOutboxWithAttempts(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    inflight_key: []const u8,
    envelope_bytes: []const u8,
    attempts_next: i32,
    next_attempt_at_ms: i64,
) !void {
    std.debug.assert(std.mem.startsWith(u8, inflight_key, "_outbox_inflight/"));
    const id = inflight_key["_outbox_inflight/".len..];
    const outbox_key = try formatKey(allocator, "_outbox/", id);
    defer allocator.free(outbox_key);

    const rewritten = try rewriteAttemptsAndClearLease(allocator, envelope_bytes, attempts_next, next_attempt_at_ms);
    defer allocator.free(rewritten);
    try kv.put(outbox_key, rewritten);
    try kv.delete(inflight_key);
}

/// Stale-sweep branch: the lease aged out before its owner came back
/// to clear it. Write the envelope back to `_outbox/{id}` with
/// attempts preserved (we don't know if delivery happened), and drop
/// the inflight row.
fn returnLeaseToOutbox(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    inflight_key: []const u8,
    envelope_bytes: []const u8,
) !void {
    std.debug.assert(std.mem.startsWith(u8, inflight_key, "_outbox_inflight/"));
    const id = inflight_key["_outbox_inflight/".len..];
    const outbox_key = try formatKey(allocator, "_outbox/", id);
    defer allocator.free(outbox_key);

    const cleaned = try clearLeasedAt(allocator, envelope_bytes);
    defer allocator.free(cleaned);
    try kv.put(outbox_key, cleaned);
    try kv.delete(inflight_key);
}

/// Terminal branch: write to `_dlq/{id}`, delete the inflight row.
fn moveInflightToDlq(
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    inflight_key: []const u8,
    envelope_bytes: []const u8,
    reason: []const u8,
) !void {
    std.debug.assert(std.mem.startsWith(u8, inflight_key, "_outbox_inflight/"));
    const id = inflight_key["_outbox_inflight/".len..];
    const dlq_key = try formatKey(allocator, "_dlq/", id);
    defer allocator.free(dlq_key);

    const with_error = try appendLastError(allocator, envelope_bytes, reason);
    defer allocator.free(with_error);
    try kv.put(dlq_key, with_error);
    try kv.delete(inflight_key);
}

fn formatKey(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, id });
}

fn stampLeasedAt(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
    leased_at_ms: i64,
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
    try obj.put("leased_at_ms", .{ .integer = leased_at_ms });
    return try stringifyAlloc(allocator, parsed.value);
}

fn clearLeasedAt(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
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
    _ = obj.orderedRemove("leased_at_ms");
    return try stringifyAlloc(allocator, parsed.value);
}

fn rewriteAttemptsAndClearLease(
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
    _ = obj.orderedRemove("leased_at_ms");
    return try stringifyAlloc(allocator, parsed.value);
}

/// Quick leased-at extraction used by the stale-lease sweep. Returns
/// null for envelopes without the field (shouldn't happen for rows
/// the drainer itself wrote, but tolerate external writers / partial
/// crashes gracefully).
fn extractLeasedAtMs(envelope_bytes: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        envelope_bytes,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("leased_at_ms") orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
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

test "rewriteAttemptsAndClearLease: patches fields + drops leased_at_ms, preserves everything else" {
    const original =
        \\{"v":1,"id":"abc","url":"https://x/","method":"POST","attempts":0,
        \\ "next_attempt_at_ms":0,"leased_at_ms":999999,
        \\ "context":{"charge":"c1"},"headers":{"X":"Y"}}
    ;
    const out = try rewriteAttemptsAndClearLease(testing.allocator, original, 3, 12345);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("attempts").?.integer);
    try testing.expectEqual(@as(i64, 12345), parsed.value.object.get("next_attempt_at_ms").?.integer);
    try testing.expect(parsed.value.object.get("leased_at_ms") == null);
    try testing.expectEqualStrings("abc", parsed.value.object.get("id").?.string);
    try testing.expectEqualStrings(
        "c1",
        parsed.value.object.get("context").?.object.get("charge").?.string,
    );
}

test "stampLeasedAt: adds leased_at_ms integer" {
    const original = "{\"id\":\"abc\",\"url\":\"https://x/\",\"attempts\":0}";
    const out = try stampLeasedAt(testing.allocator, original, 42);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("leased_at_ms").?.integer);
}

test "extractLeasedAtMs: present / missing / malformed" {
    try testing.expectEqual(@as(?i64, 100), extractLeasedAtMs("{\"leased_at_ms\":100}"));
    try testing.expectEqual(@as(?i64, null), extractLeasedAtMs("{\"id\":\"abc\"}"));
    try testing.expectEqual(@as(?i64, null), extractLeasedAtMs("not json"));
    try testing.expectEqual(@as(?i64, null), extractLeasedAtMs("{\"leased_at_ms\":\"str\"}"));
}

test "clearLeasedAt: removes field, preserves rest" {
    const original =
        \\{"id":"abc","url":"https://x/","leased_at_ms":999,"attempts":2}
    ;
    const out = try clearLeasedAt(testing.allocator, original);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("leased_at_ms") == null);
    try testing.expectEqualStrings("abc", parsed.value.object.get("id").?.string);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("attempts").?.integer);
}

test "returnLeaseToOutbox: moves row, strips leased_at_ms" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    const id = "abc";
    const original = "{\"id\":\"abc\",\"url\":\"https://x/\",\"attempts\":2,\"leased_at_ms\":111}";
    try kv.put("_outbox_inflight/abc", original);

    try returnLeaseToOutbox(testing.allocator, kv, "_outbox_inflight/abc", original);

    // inflight row is gone
    try testing.expectError(kv_mod.KvError.NotFound, kv.get("_outbox_inflight/abc"));

    // outbox row exists without leased_at_ms, attempts preserved
    const got = try kv.get("_outbox/abc");
    defer testing.allocator.free(got);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("leased_at_ms") == null);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("attempts").?.integer);
    try testing.expectEqualStrings(id, parsed.value.object.get("id").?.string);
}

test "returnLeaseToOutboxWithAttempts: bumps attempts + sets next_at_ms" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    const original = "{\"id\":\"xyz\",\"attempts\":0,\"leased_at_ms\":100}";
    try kv.put("_outbox_inflight/xyz", original);

    try returnLeaseToOutboxWithAttempts(testing.allocator, kv, "_outbox_inflight/xyz", original, 3, 55555);

    const got = try kv.get("_outbox/xyz");
    defer testing.allocator.free(got);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("attempts").?.integer);
    try testing.expectEqual(@as(i64, 55555), parsed.value.object.get("next_attempt_at_ms").?.integer);
    try testing.expect(parsed.value.object.get("leased_at_ms") == null);
    try testing.expectError(kv_mod.KvError.NotFound, kv.get("_outbox_inflight/xyz"));
}

test "moveInflightToDlq: writes _dlq/{id} + deletes inflight + stamps last_error" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKv(testing.allocator, &buf);
    defer {
        kv.close();
        cleanupTempKv(&buf);
    }

    const original = "{\"id\":\"dd\",\"leased_at_ms\":1}";
    try kv.put("_outbox_inflight/dd", original);

    try moveInflightToDlq(testing.allocator, kv, "_outbox_inflight/dd", original, "BlockedAddress");

    const got = try kv.get("_dlq/dd");
    defer testing.allocator.free(got);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("BlockedAddress", parsed.value.object.get("last_error").?.string);
    try testing.expectError(kv_mod.KvError.NotFound, kv.get("_outbox_inflight/dd"));
}

fn openTempKv(allocator: std.mem.Allocator, buf: *[64]u8) !*kv_mod.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-drainer-{x}.db", .{seed});
    return try kv_mod.KvStore.open(allocator, path);
}

fn cleanupTempKv(buf: *[64]u8) void {
    const path_slice = std.mem.sliceTo(buf, 0);
    std.fs.cwd().deleteFile(path_slice) catch {};
}

test "renderHeadersWithMeta: stamps id + attempt, strips customer-set reserved names" {
    const src =
        \\{"X-Custom":"v1","X-Rove-Webhook-Id":"evil","x-rove-webhook-attempt":"99","Content-Type":"application/json"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();

    const hdrs = try renderHeadersWithMeta(testing.allocator, parsed.value, "abc123", "2");
    defer testing.allocator.free(hdrs);

    // Expect: X-Custom, Content-Type, X-Rove-Webhook-Id=abc123, X-Rove-Webhook-Attempt=2.
    // (Order among customer headers depends on std.json; order between
    // customer block and metadata block is fixed — metadata goes last.)
    var found_custom = false;
    var found_ct = false;
    var found_id: ?[]const u8 = null;
    var found_attempt: ?[]const u8 = null;
    var saw_customer_reserved = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-custom")) found_custom = true;
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) found_ct = true;
        if (std.ascii.eqlIgnoreCase(h.name, "x-rove-webhook-id")) {
            if (found_id != null) saw_customer_reserved = true;
            found_id = h.value;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "x-rove-webhook-attempt")) {
            if (found_attempt != null) saw_customer_reserved = true;
            found_attempt = h.value;
        }
    }
    try testing.expect(found_custom);
    try testing.expect(found_ct);
    try testing.expect(!saw_customer_reserved);
    try testing.expectEqualStrings("abc123", found_id.?);
    try testing.expectEqualStrings("2", found_attempt.?);
}

test "renderHeadersWithMeta: empty / non-object headers still gets metadata" {
    const hdrs = try renderHeadersWithMeta(testing.allocator, .null, "id7", "5");
    defer testing.allocator.free(hdrs);
    try testing.expectEqual(@as(usize, 2), hdrs.len);
    try testing.expectEqualStrings("X-Rove-Webhook-Id", hdrs[0].name);
    try testing.expectEqualStrings("id7", hdrs[0].value);
    try testing.expectEqualStrings("X-Rove-Webhook-Attempt", hdrs[1].name);
    try testing.expectEqualStrings("5", hdrs[1].value);
}

test "appendLastError: stamps reason" {
    const original = "{\"id\":\"abc\",\"url\":\"https://x/\"}";
    const out = try appendLastError(testing.allocator, original, "BlockedAddress");
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("BlockedAddress", parsed.value.object.get("last_error").?.string);
}
