//! rove-webhook-server — cluster-wide raft-replicated webhook delivery.
//!
//! Phase 5.5 (d). Replaces the per-tenant `_outbox/*` + drainer model
//! with a single `webhooks.db` shared across the cluster, written
//! through new raft envelope types 4/5/6 and read by a leader-pinned
//! delivery thread inside the loop46 binary. See
//! `docs/webhook-server-plan.md` for the full design.
//!
//! ## Scope of this module
//!
//! Step 1 of the migration (this commit): schema, envelope wire
//! format, and apply primitives. The delivery thread comes in step 2;
//! the dispatcher cutover (where `webhook.send` accumulates
//! per-handler and rides atomically with the writeset via
//! multi-envelope-per-raft-entry) lands in step 3.
//!
//! ## Storage shape
//!
//! For step 1, `WebhookStore` is a thin wrapper over a kv-store: rows
//! live under `wh/{webhook_id_hex}` as serialized bodies. This keeps
//! the dependency footprint small (no raw sqlite from this module)
//! and lets us land the apply path without designing the partial-
//! index schema the future delivery loop will want. Step 2 swaps in
//! a real sqlite schema (per webhook-server-plan.md §2.2) when the
//! "ready rows" query needs to be index-backed.
//!
//! ## What lives in this module
//!
//! - `WebhookRow` — the in-memory shape of one webhook. Mirrors the
//!   eventual on-disk schema.
//! - `WebhookStore` — opens / owns a kv-store at
//!   `{data_dir}/webhooks.db` for apply-path operations.
//! - Wire-format encode/decode for envelope types 4 (enqueue
//!   batch), 5 (complete), and 6 (retry schedule).
//!
//! ## What does NOT live here
//!
//! - The delivery loop (step 2).
//! - The dispatcher's per-handler webhook accumulator (step 3).
//! - Customer-facing JS bindings.

const std = @import("std");
const kv = @import("rove-kv");

pub const thread = @import("thread.zig");

pub const Error = error{
    Truncated,
    InvalidVersion,
    InvalidState,
    InvalidOutcome,
    Kv,
    OutOfMemory,
};

/// 256 KB cap on response bodies stored in apply path. Mirrors the
/// log/tape cap so dashboard and replay UIs see consistent ceilings.
pub const RESPONSE_BODY_CAP: usize = 256 * 1024;

pub const WEBHOOK_ID_HEX_LEN: usize = 64;

/// Apply-envelope type bytes (mirroring `src/js/apply.zig`'s
/// `EnvelopeType`). Duplicated here so `webhook_server.thread` can
/// build raft envelopes without depending on `rove-js`. Keep in sync;
/// `apply.zig` is the authority.
pub const ENVELOPE_TYPE_ENQUEUE_BATCH: u8 = 4;
pub const ENVELOPE_TYPE_COMPLETE: u8 = 5;
pub const ENVELOPE_TYPE_RETRY_SCHEDULE: u8 = 6;
pub const ENVELOPE_MAX_ID_LEN: usize = 256;

/// Build the apply envelope: `[type][u16 id_len BE][id][payload]`.
/// Used by the webhook-server thread when proposing envelopes 5 + 6.
/// Caller frees.
pub fn wrapApplyEnvelope(
    allocator: std.mem.Allocator,
    envelope_type: u8,
    instance_id: []const u8,
    payload: []const u8,
) ![]u8 {
    if (instance_id.len > ENVELOPE_MAX_ID_LEN) return error.OutOfMemory;
    const total = 1 + 2 + instance_id.len + payload.len;
    const out = try allocator.alloc(u8, total);
    out[0] = envelope_type;
    std.mem.writeInt(u16, out[1..3], @intCast(instance_id.len), .big);
    @memcpy(out[3 .. 3 + instance_id.len], instance_id);
    @memcpy(out[3 + instance_id.len ..], payload);
    return out;
}

/// Lifecycle state of a single webhook. The future delivery loop
/// walks rows in `pending` state ordered by `next_attempt_at_ns`.
pub const WebhookState = enum {
    pending,
    inflight,
    failed_pending_callback,

    pub fn fromString(s: []const u8) ?WebhookState {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "inflight")) return .inflight;
        if (std.mem.eql(u8, s, "failed_pending_callback")) return .failed_pending_callback;
        return null;
    }

    pub fn toString(self: WebhookState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .inflight => "inflight",
            .failed_pending_callback => "failed_pending_callback",
        };
    }
};

pub const Outcome = enum(u8) {
    delivered = 0,
    failed = 1,
};

/// One webhook in the queue. Owned slices are freed by `deinit`.
/// Wire-format-friendly: serialize/parse round-trips one of these
/// per webhook in an envelope-4 batch.
pub const WebhookRow = struct {
    webhook_id_hex: [WEBHOOK_ID_HEX_LEN]u8,
    tenant_id: []const u8,
    url: []const u8,
    method: []const u8,
    /// JSON object `{"Header-Name":"value", ...}`. Stored verbatim and
    /// re-emitted as request headers at delivery time.
    headers_json: []const u8,
    body: []const u8,
    max_attempts: u8 = 10,
    timeout_ms: u32 = 30_000,
    /// JSON array of retryable status codes / "network".
    retry_on_json: []const u8,
    /// JSON object passed back to `onResult` at callback time.
    context_json: []const u8,
    /// `<path>.mjs`-style handler path that fires on completion.
    on_result_path: []const u8,
    enqueued_at_ns: i64,

    pub fn deinit(self: *WebhookRow, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.headers_json);
        allocator.free(self.body);
        allocator.free(self.retry_on_json);
        allocator.free(self.context_json);
        allocator.free(self.on_result_path);
        self.* = undefined;
    }
};

/// Serialized state-bearing fields of a webhook in the kv store.
/// Decoded into a `StoredWebhook` on read.
pub const StoredWebhook = struct {
    row: WebhookRow,
    state: WebhookState,
    next_attempt_at_ns: i64,
    attempts: u32,
    inflight_lease_ns: ?i64 = null,
    inflight_leader_term: ?u64 = null,

    pub fn deinit(self: *StoredWebhook, allocator: std.mem.Allocator) void {
        self.row.deinit(allocator);
        self.* = undefined;
    }
};

/// Cluster-wide webhook store. Backed by `{data_dir}/webhooks.db`.
/// Rows live under `wh/{webhook_id_hex}` as `serializeStored` bytes.
pub const WebhookStore = struct {
    allocator: std.mem.Allocator,
    db: *kv.KvStore,

    pub fn open(allocator: std.mem.Allocator, db_path: [:0]const u8) Error!WebhookStore {
        const db = kv.KvStore.open(allocator, db_path) catch return Error.Kv;
        return .{ .allocator = allocator, .db = db };
    }

    pub fn close(self: *WebhookStore) void {
        self.db.close();
        self.* = undefined;
    }

    fn rowKey(buf: *[3 + WEBHOOK_ID_HEX_LEN]u8, webhook_id_hex: []const u8) []u8 {
        std.debug.assert(webhook_id_hex.len == WEBHOOK_ID_HEX_LEN);
        @memcpy(buf[0..3], "wh/");
        @memcpy(buf[3..], webhook_id_hex);
        return buf;
    }

    /// Apply one envelope-4 batch — INSERT OR IGNORE for each row.
    /// Idempotent: re-applying the same envelope (e.g., from a raft
    /// log replay during catch-up) is a no-op for rows already
    /// present. Rows start in state='pending' with attempts=0 and
    /// next_attempt_at_ns=enqueued_at_ns.
    pub fn applyEnqueueBatch(self: *WebhookStore, rows: []const WebhookRow) Error!void {
        self.db.begin() catch return Error.Kv;
        errdefer self.db.rollback() catch {};
        for (rows) |row| try self.insertIfAbsent(&row);
        self.db.commit() catch return Error.Kv;
    }

    fn insertIfAbsent(self: *WebhookStore, row: *const WebhookRow) Error!void {
        var key_buf: [3 + WEBHOOK_ID_HEX_LEN]u8 = undefined;
        const key = rowKey(&key_buf, &row.webhook_id_hex);

        const existing = self.db.get(key) catch |err| switch (err) {
            error.NotFound => null,
            else => return Error.Kv,
        };
        if (existing) |bytes| {
            self.allocator.free(bytes);
            return; // already present — idempotent
        }

        const stored: StoredWebhook = .{
            .row = row.*,
            .state = .pending,
            .next_attempt_at_ns = row.enqueued_at_ns,
            .attempts = 0,
        };
        const encoded = serializeStored(self.allocator, &stored) catch return Error.OutOfMemory;
        defer self.allocator.free(encoded);
        self.db.put(key, encoded) catch return Error.Kv;
    }

    /// Apply envelope 5 — webhook reached terminal outcome.
    /// Removes the row from `webhooks.db`. The companion
    /// `_callback/{id}` write to the tenant's app.db is the apply
    /// path's responsibility (separate connection; see
    /// `applyWebhookComplete` in `src/js/apply.zig`). Idempotent:
    /// deleting a missing row is a no-op.
    pub fn applyComplete(self: *WebhookStore, webhook_id_hex: []const u8) Error!void {
        std.debug.assert(webhook_id_hex.len == WEBHOOK_ID_HEX_LEN);
        var key_buf: [3 + WEBHOOK_ID_HEX_LEN]u8 = undefined;
        const key = rowKey(&key_buf, webhook_id_hex);
        self.db.delete(key) catch |err| switch (err) {
            error.NotFound => return,
            else => return Error.Kv,
        };
    }

    /// Apply envelope 6 — schedule a retry. Reads the existing row,
    /// updates attempts + next_attempt_at_ns + clears the inflight
    /// lease, writes back. Missing row → no-op (the webhook was
    /// already completed by a race; envelope 5 won and 6 lost).
    pub fn applyRetrySchedule(
        self: *WebhookStore,
        webhook_id_hex: []const u8,
        attempts: u32,
        next_attempt_at_ns: i64,
    ) Error!void {
        std.debug.assert(webhook_id_hex.len == WEBHOOK_ID_HEX_LEN);
        var key_buf: [3 + WEBHOOK_ID_HEX_LEN]u8 = undefined;
        const key = rowKey(&key_buf, webhook_id_hex);

        const existing_bytes = self.db.get(key) catch |err| switch (err) {
            error.NotFound => return,
            else => return Error.Kv,
        };
        defer self.allocator.free(existing_bytes);

        var stored = try parseStored(self.allocator, existing_bytes);
        defer stored.deinit(self.allocator);
        stored.attempts = attempts;
        stored.next_attempt_at_ns = next_attempt_at_ns;
        stored.state = .pending;
        stored.inflight_lease_ns = null;
        stored.inflight_leader_term = null;

        const encoded = serializeStored(self.allocator, &stored) catch return Error.OutOfMemory;
        defer self.allocator.free(encoded);
        self.db.put(key, encoded) catch return Error.Kv;
    }

    /// Read one stored webhook by id. Returns null if absent. Caller
    /// owns the returned `StoredWebhook` and must `deinit` it.
    pub fn get(self: *WebhookStore, webhook_id_hex: []const u8) Error!?StoredWebhook {
        std.debug.assert(webhook_id_hex.len == WEBHOOK_ID_HEX_LEN);
        var key_buf: [3 + WEBHOOK_ID_HEX_LEN]u8 = undefined;
        const key = rowKey(&key_buf, webhook_id_hex);
        const bytes = self.db.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return try parseStored(self.allocator, bytes);
    }

    /// Scan all rows in `state='pending'` whose `next_attempt_at_ns`
    /// is `<= now_ns`, ordered ascending by `next_attempt_at_ns`. Cap
    /// is `max`. Caller owns the returned slice; each entry must be
    /// `deinit`'d, then the slice freed.
    ///
    /// V1 does a full prefix scan + in-memory filter. The kv-backed
    /// store has no partial index; the future sqlite-schema variant
    /// (webhook-server-plan.md §2.2) will use the
    /// `webhooks_ready` partial index to cut scan cost. Per the
    /// existing module doc, this stand-in is acceptable while the
    /// delivery loop's request rate is single-leader and small.
    pub fn readyRows(
        self: *WebhookStore,
        allocator: std.mem.Allocator,
        now_ns: i64,
        max: u32,
    ) Error![]StoredWebhook {
        const SCAN_PAGE: u32 = 256;
        var collected: std.ArrayList(StoredWebhook) = .empty;
        errdefer {
            for (collected.items) |*r| r.deinit(allocator);
            collected.deinit(allocator);
        }

        var cursor_buf: [3 + WEBHOOK_ID_HEX_LEN]u8 = undefined;
        var have_cursor: bool = false;

        while (true) {
            const cursor_slice: []const u8 = if (have_cursor) cursor_buf[0..] else "";
            var page = self.db.prefix("wh/", cursor_slice, SCAN_PAGE) catch return Error.Kv;
            defer page.deinit();
            if (page.entries.len == 0) break;

            for (page.entries) |entry| {
                var stored = parseStored(allocator, entry.value) catch |err| switch (err) {
                    Error.OutOfMemory => return Error.OutOfMemory,
                    else => continue, // skip malformed; retain in store for later inspection
                };
                if (stored.state != .pending or stored.next_attempt_at_ns > now_ns) {
                    stored.deinit(allocator);
                    continue;
                }
                collected.append(allocator, stored) catch |err| {
                    stored.deinit(allocator);
                    switch (err) {
                        error.OutOfMemory => return Error.OutOfMemory,
                    }
                };
            }

            if (page.entries.len < SCAN_PAGE) break;
            // Page-cursor: last key seen this page.
            const last_key = page.entries[page.entries.len - 1].key;
            if (last_key.len != cursor_buf.len) break; // unexpected key shape — stop
            @memcpy(&cursor_buf, last_key);
            have_cursor = true;
        }

        std.mem.sort(StoredWebhook, collected.items, {}, lessByNextAttempt);
        if (collected.items.len > max) {
            for (collected.items[max..]) |*r| r.deinit(allocator);
            collected.shrinkRetainingCapacity(max);
        }
        return collected.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }
};

fn lessByNextAttempt(_: void, a: StoredWebhook, b: StoredWebhook) bool {
    return a.next_attempt_at_ns < b.next_attempt_at_ns;
}

// ── StoredWebhook serialization (kv value bytes) ──────────────────────
//
// Layout (little-endian, version-prefixed for forward compat):
//
//   [u8 version=1][WebhookRow encoded] (see encodeOneRow below)
//   [u8 state_byte][i64 next_attempt_at_ns][u32 attempts]
//   [u8 lease_present][i64 inflight_lease_ns?][u64 inflight_leader_term?]

const STORED_VERSION: u8 = 1;

pub fn serializeStored(allocator: std.mem.Allocator, s: *const StoredWebhook) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, STORED_VERSION);
    try encodeOneRow(allocator, &out, &s.row);
    try out.append(allocator, stateToByte(s.state));
    try writeI64(allocator, &out, s.next_attempt_at_ns);
    try writeU32(allocator, &out, s.attempts);
    if (s.inflight_lease_ns) |ns| {
        try out.append(allocator, 1);
        try writeI64(allocator, &out, ns);
        try writeU64(allocator, &out, s.inflight_leader_term orelse 0);
    } else {
        try out.append(allocator, 0);
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseStored(allocator: std.mem.Allocator, bytes: []const u8) Error!StoredWebhook {
    var r = Reader{ .data = bytes, .pos = 0 };
    const version = try r.byte();
    if (version != STORED_VERSION) return Error.InvalidVersion;
    var row = try decodeOneRow(allocator, &r);
    errdefer row.deinit(allocator);
    const state_byte = try r.byte();
    const state = byteToState(state_byte) orelse return Error.InvalidState;
    const next_attempt_at_ns = try r.i64le();
    const attempts = try r.u32le();
    const lease_present = try r.byte();
    var lease_ns: ?i64 = null;
    var lease_term: ?u64 = null;
    if (lease_present == 1) {
        lease_ns = try r.i64le();
        lease_term = try r.u64le();
    }
    return .{
        .row = row,
        .state = state,
        .next_attempt_at_ns = next_attempt_at_ns,
        .attempts = attempts,
        .inflight_lease_ns = lease_ns,
        .inflight_leader_term = lease_term,
    };
}

fn stateToByte(s: WebhookState) u8 {
    return switch (s) {
        .pending => 0,
        .inflight => 1,
        .failed_pending_callback => 2,
    };
}

fn byteToState(b: u8) ?WebhookState {
    return switch (b) {
        0 => .pending,
        1 => .inflight,
        2 => .failed_pending_callback,
        else => null,
    };
}

// ── Wire format: envelope 4 (enqueue batch) ────────────────────────────

pub const ENVELOPE_4_VERSION: u8 = 1;

pub fn encodeEnqueueBatch(
    allocator: std.mem.Allocator,
    rows: []const WebhookRow,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_4_VERSION);
    try writeU32(allocator, &out, @intCast(rows.len));
    for (rows) |row| try encodeOneRow(allocator, &out, &row);
    return out.toOwnedSlice(allocator);
}

pub fn decodeEnqueueBatch(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error![]WebhookRow {
    var r = Reader{ .data = payload, .pos = 0 };
    const version = try r.byte();
    if (version != ENVELOPE_4_VERSION) return Error.InvalidVersion;
    const count = try r.u32le();

    const out = allocator.alloc(WebhookRow, count) catch return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*row| row.deinit(allocator);
        allocator.free(out);
    }
    while (filled < count) : (filled += 1) {
        out[filled] = try decodeOneRow(allocator, &r);
    }
    return out;
}

fn encodeOneRow(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    row: *const WebhookRow,
) !void {
    try out.appendSlice(allocator, &row.webhook_id_hex);
    try writeU16Bytes(allocator, out, row.tenant_id);
    try writeU16Bytes(allocator, out, row.url);
    try writeU8Bytes(allocator, out, row.method);
    try writeU32Bytes(allocator, out, row.headers_json);
    try writeU32Bytes(allocator, out, row.body);
    try out.append(allocator, row.max_attempts);
    try writeU32(allocator, out, row.timeout_ms);
    try writeU16Bytes(allocator, out, row.retry_on_json);
    try writeU32Bytes(allocator, out, row.context_json);
    try writeU16Bytes(allocator, out, row.on_result_path);
    try writeI64(allocator, out, row.enqueued_at_ns);
}

fn decodeOneRow(allocator: std.mem.Allocator, r: *Reader) Error!WebhookRow {
    if (r.remaining() < WEBHOOK_ID_HEX_LEN) return Error.Truncated;
    var hex_buf: [WEBHOOK_ID_HEX_LEN]u8 = undefined;
    @memcpy(&hex_buf, r.data[r.pos..][0..WEBHOOK_ID_HEX_LEN]);
    r.pos += WEBHOOK_ID_HEX_LEN;

    const tenant_id = try r.bytesU16(allocator);
    errdefer allocator.free(tenant_id);
    const url = try r.bytesU16(allocator);
    errdefer allocator.free(url);
    const method = try r.bytesU8(allocator);
    errdefer allocator.free(method);
    const headers_json = try r.bytesU32(allocator);
    errdefer allocator.free(headers_json);
    const body = try r.bytesU32(allocator);
    errdefer allocator.free(body);
    const max_attempts = try r.byte();
    const timeout_ms = try r.u32le();
    const retry_on_json = try r.bytesU16(allocator);
    errdefer allocator.free(retry_on_json);
    const context_json = try r.bytesU32(allocator);
    errdefer allocator.free(context_json);
    const on_result_path = try r.bytesU16(allocator);
    errdefer allocator.free(on_result_path);
    const enqueued_at_ns = try r.i64le();

    return .{
        .webhook_id_hex = hex_buf,
        .tenant_id = tenant_id,
        .url = url,
        .method = method,
        .headers_json = headers_json,
        .body = body,
        .max_attempts = max_attempts,
        .timeout_ms = timeout_ms,
        .retry_on_json = retry_on_json,
        .context_json = context_json,
        .on_result_path = on_result_path,
        .enqueued_at_ns = enqueued_at_ns,
    };
}

// ── Wire format: envelope 5 (complete) ─────────────────────────────────

pub const ENVELOPE_5_VERSION: u8 = 1;

pub const CompleteEnvelope = struct {
    webhook_id_hex: [WEBHOOK_ID_HEX_LEN]u8,
    tenant_id: []const u8,
    outcome: Outcome,
    attempts: u32,
    status: u16,
    response_headers_json: []const u8,
    response_body: []const u8,

    pub fn deinit(self: *CompleteEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.response_headers_json);
        allocator.free(self.response_body);
        self.* = undefined;
    }
};

pub fn encodeComplete(
    allocator: std.mem.Allocator,
    env: *const CompleteEnvelope,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_5_VERSION);
    try out.appendSlice(allocator, &env.webhook_id_hex);
    try writeU16Bytes(allocator, &out, env.tenant_id);
    try out.append(allocator, @intFromEnum(env.outcome));
    try writeU32(allocator, &out, env.attempts);
    try writeU16(allocator, &out, env.status);
    try writeU32Bytes(allocator, &out, env.response_headers_json);
    try writeU32Bytes(allocator, &out, env.response_body);
    return out.toOwnedSlice(allocator);
}

pub fn decodeComplete(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error!CompleteEnvelope {
    var r = Reader{ .data = payload, .pos = 0 };
    const version = try r.byte();
    if (version != ENVELOPE_5_VERSION) return Error.InvalidVersion;
    if (r.remaining() < WEBHOOK_ID_HEX_LEN) return Error.Truncated;
    var hex_buf: [WEBHOOK_ID_HEX_LEN]u8 = undefined;
    @memcpy(&hex_buf, r.data[r.pos..][0..WEBHOOK_ID_HEX_LEN]);
    r.pos += WEBHOOK_ID_HEX_LEN;

    const tenant_id = try r.bytesU16(allocator);
    errdefer allocator.free(tenant_id);
    const outcome_byte = try r.byte();
    const outcome = std.meta.intToEnum(Outcome, outcome_byte) catch return Error.InvalidOutcome;
    const attempts = try r.u32le();
    const status = try r.u16le();
    const response_headers_json = try r.bytesU32(allocator);
    errdefer allocator.free(response_headers_json);
    const response_body = try r.bytesU32(allocator);
    errdefer allocator.free(response_body);

    return .{
        .webhook_id_hex = hex_buf,
        .tenant_id = tenant_id,
        .outcome = outcome,
        .attempts = attempts,
        .status = status,
        .response_headers_json = response_headers_json,
        .response_body = response_body,
    };
}

// ── Wire format: envelope 6 (retry schedule) ───────────────────────────

pub const ENVELOPE_6_VERSION: u8 = 1;

pub const RetryScheduleEnvelope = struct {
    webhook_id_hex: [WEBHOOK_ID_HEX_LEN]u8,
    attempts: u32,
    next_attempt_at_ns: i64,
};

pub fn encodeRetrySchedule(
    allocator: std.mem.Allocator,
    env: *const RetryScheduleEnvelope,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_6_VERSION);
    try out.appendSlice(allocator, &env.webhook_id_hex);
    try writeU32(allocator, &out, env.attempts);
    try writeI64(allocator, &out, env.next_attempt_at_ns);
    return out.toOwnedSlice(allocator);
}

pub fn decodeRetrySchedule(payload: []const u8) Error!RetryScheduleEnvelope {
    var r = Reader{ .data = payload, .pos = 0 };
    const version = try r.byte();
    if (version != ENVELOPE_6_VERSION) return Error.InvalidVersion;
    if (r.remaining() < WEBHOOK_ID_HEX_LEN) return Error.Truncated;
    var hex_buf: [WEBHOOK_ID_HEX_LEN]u8 = undefined;
    @memcpy(&hex_buf, r.data[r.pos..][0..WEBHOOK_ID_HEX_LEN]);
    r.pos += WEBHOOK_ID_HEX_LEN;
    const attempts = try r.u32le();
    const next_attempt_at_ns = try r.i64le();
    return .{
        .webhook_id_hex = hex_buf,
        .attempts = attempts,
        .next_attempt_at_ns = next_attempt_at_ns,
    };
}

// ── Reader / writer helpers ────────────────────────────────────────────

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }
    fn byte(self: *Reader) Error!u8 {
        if (self.remaining() < 1) return Error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn u16le(self: *Reader) Error!u16 {
        if (self.remaining() < 2) return Error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn u32le(self: *Reader) Error!u32 {
        if (self.remaining() < 4) return Error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn u64le(self: *Reader) Error!u64 {
        if (self.remaining() < 8) return Error.Truncated;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn i64le(self: *Reader) Error!i64 {
        if (self.remaining() < 8) return Error.Truncated;
        const v: i64 = @bitCast(std.mem.readInt(u64, self.data[self.pos..][0..8], .little));
        self.pos += 8;
        return v;
    }
    fn bytesU8(self: *Reader, allocator: std.mem.Allocator) Error![]u8 {
        const n = try self.byte();
        return self.bytesNAlloc(allocator, n);
    }
    fn bytesU16(self: *Reader, allocator: std.mem.Allocator) Error![]u8 {
        const n = try self.u16le();
        return self.bytesNAlloc(allocator, n);
    }
    fn bytesU32(self: *Reader, allocator: std.mem.Allocator) Error![]u8 {
        const n = try self.u32le();
        return self.bytesNAlloc(allocator, n);
    }
    fn bytesNAlloc(self: *Reader, allocator: std.mem.Allocator, n: usize) Error![]u8 {
        if (self.remaining() < n) return Error.Truncated;
        const out = allocator.alloc(u8, n) catch return Error.OutOfMemory;
        @memcpy(out, self.data[self.pos..][0..n]);
        self.pos += n;
        return out;
    }
};

fn writeU16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}
fn writeU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}
fn writeU64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}
fn writeI64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(v), .little);
    try out.appendSlice(allocator, &buf);
}
fn writeU8Bytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > 0xff) return error.OutOfMemory;
    try out.append(allocator, @intCast(s.len));
    try out.appendSlice(allocator, s);
}
fn writeU16Bytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len > 0xffff) return error.OutOfMemory;
    try writeU16(allocator, out, @intCast(s.len));
    try out.appendSlice(allocator, s);
}
fn writeU32Bytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try writeU32(allocator, out, @intCast(s.len));
    try out.appendSlice(allocator, s);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn fillHex(seed: u8) [WEBHOOK_ID_HEX_LEN]u8 {
    var buf: [WEBHOOK_ID_HEX_LEN]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = "0123456789abcdef"[(seed +% @as(u8, @intCast(i))) % 16];
    return buf;
}

fn testRow(allocator: std.mem.Allocator, seed: u8) !WebhookRow {
    return .{
        .webhook_id_hex = fillHex(seed),
        .tenant_id = try allocator.dupe(u8, "acme"),
        .url = try allocator.dupe(u8, "https://example.test/hook"),
        .method = try allocator.dupe(u8, "POST"),
        .headers_json = try allocator.dupe(u8, "{\"Content-Type\":\"application/json\"}"),
        .body = try allocator.dupe(u8, "{\"event\":\"hello\"}"),
        .max_attempts = 5,
        .timeout_ms = 30_000,
        .retry_on_json = try allocator.dupe(u8, "[408,429,500,502,503,504,\"network\"]"),
        .context_json = try allocator.dupe(u8, "{\"tag\":\"smoke\"}"),
        .on_result_path = try allocator.dupe(u8, "stripe/charge_result"),
        .enqueued_at_ns = 1_700_000_000_000_000_000,
    };
}

test "envelope 4 enqueue batch round-trip" {
    const a = testing.allocator;
    var rows = [_]WebhookRow{
        try testRow(a, 0xa),
        try testRow(a, 0xb),
    };
    defer for (&rows) |*r| r.deinit(a);

    const enc = try encodeEnqueueBatch(a, &rows);
    defer a.free(enc);

    const dec = try decodeEnqueueBatch(a, enc);
    defer {
        for (dec) |*r| r.deinit(a);
        a.free(dec);
    }

    try testing.expectEqual(@as(usize, 2), dec.len);
    try testing.expectEqualSlices(u8, &rows[0].webhook_id_hex, &dec[0].webhook_id_hex);
    try testing.expectEqualStrings(rows[0].url, dec[0].url);
    try testing.expectEqualStrings(rows[1].context_json, dec[1].context_json);
    try testing.expectEqual(rows[0].max_attempts, dec[0].max_attempts);
    try testing.expectEqual(rows[1].timeout_ms, dec[1].timeout_ms);
    try testing.expectEqual(rows[0].enqueued_at_ns, dec[0].enqueued_at_ns);
}

test "envelope 4 truncated payload errors cleanly" {
    const a = testing.allocator;
    try testing.expectError(Error.Truncated, decodeEnqueueBatch(a, &.{}));
    try testing.expectError(Error.Truncated, decodeEnqueueBatch(a, &.{1}));
    var hdr: [5]u8 = .{ 1, 1, 0, 0, 0 };
    try testing.expectError(Error.Truncated, decodeEnqueueBatch(a, &hdr));
}

test "envelope 4 wrong version errors" {
    const a = testing.allocator;
    var hdr: [5]u8 = .{ 99, 0, 0, 0, 0 };
    try testing.expectError(Error.InvalidVersion, decodeEnqueueBatch(a, &hdr));
}

test "envelope 5 complete round-trip" {
    const a = testing.allocator;
    var env = CompleteEnvelope{
        .webhook_id_hex = fillHex(0x5),
        .tenant_id = try a.dupe(u8, "acme"),
        .outcome = .delivered,
        .attempts = 3,
        .status = 200,
        .response_headers_json = try a.dupe(u8, "{\"content-type\":\"application/json\"}"),
        .response_body = try a.dupe(u8, "{\"ok\":true}"),
    };
    defer env.deinit(a);

    const enc = try encodeComplete(a, &env);
    defer a.free(enc);

    var dec = try decodeComplete(a, enc);
    defer dec.deinit(a);

    try testing.expectEqualSlices(u8, &env.webhook_id_hex, &dec.webhook_id_hex);
    try testing.expectEqualStrings(env.tenant_id, dec.tenant_id);
    try testing.expectEqual(env.outcome, dec.outcome);
    try testing.expectEqual(env.attempts, dec.attempts);
    try testing.expectEqual(env.status, dec.status);
    try testing.expectEqualStrings(env.response_body, dec.response_body);
}

test "envelope 6 retry schedule round-trip" {
    const a = testing.allocator;
    const env = RetryScheduleEnvelope{
        .webhook_id_hex = fillHex(0x6),
        .attempts = 7,
        .next_attempt_at_ns = 1_700_000_005_000_000_000,
    };
    const enc = try encodeRetrySchedule(a, &env);
    defer a.free(enc);
    const dec = try decodeRetrySchedule(enc);
    try testing.expectEqualSlices(u8, &env.webhook_id_hex, &dec.webhook_id_hex);
    try testing.expectEqual(env.attempts, dec.attempts);
    try testing.expectEqual(env.next_attempt_at_ns, dec.next_attempt_at_ns);
}

test "WebhookStore enqueue → retry → complete round-trip" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-webhook-test-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/webhooks.db", .{tmp_dir}, 0);
    defer a.free(db_path);

    var store = try WebhookStore.open(a, db_path);
    defer store.close();

    var rows = [_]WebhookRow{ try testRow(a, 0x1), try testRow(a, 0x2) };
    defer for (&rows) |*r| r.deinit(a);

    try store.applyEnqueueBatch(&rows);
    // Idempotent: second apply is a no-op.
    try store.applyEnqueueBatch(&rows);

    // Row 0 starts pending, attempts=0, next=enqueued_at_ns.
    var fetched_a = (try store.get(&rows[0].webhook_id_hex)).?;
    defer fetched_a.deinit(a);
    try testing.expectEqual(WebhookState.pending, fetched_a.state);
    try testing.expectEqual(@as(u32, 0), fetched_a.attempts);
    try testing.expectEqual(rows[0].enqueued_at_ns, fetched_a.next_attempt_at_ns);
    try testing.expectEqualStrings(rows[0].url, fetched_a.row.url);

    // Retry schedule shifts attempts + next_attempt_at_ns.
    try store.applyRetrySchedule(&rows[0].webhook_id_hex, 2, 1_700_000_010_000_000_000);
    var fetched_a2 = (try store.get(&rows[0].webhook_id_hex)).?;
    defer fetched_a2.deinit(a);
    try testing.expectEqual(@as(u32, 2), fetched_a2.attempts);
    try testing.expectEqual(@as(i64, 1_700_000_010_000_000_000), fetched_a2.next_attempt_at_ns);
    try testing.expectEqual(WebhookState.pending, fetched_a2.state);

    // Complete row 1 — DELETE + idempotent on re-apply.
    try store.applyComplete(&rows[1].webhook_id_hex);
    try store.applyComplete(&rows[1].webhook_id_hex);
    try testing.expect((try store.get(&rows[1].webhook_id_hex)) == null);

    // Retry on a missing webhook is a no-op (no error).
    try store.applyRetrySchedule(&rows[1].webhook_id_hex, 5, 1);
}

test "WebhookStore readyRows filters by state + next_attempt_at_ns and orders earliest-first" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-webhook-ready-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/webhooks.db", .{tmp_dir}, 0);
    defer a.free(db_path);

    var store = try WebhookStore.open(a, db_path);
    defer store.close();

    // Three rows with different enqueue times. fillHex collapses on
    // `seed % 16`, so derive distinct ids from a base hex pattern.
    var row_now = try testRow(a, 0x1);
    @memcpy(&row_now.webhook_id_hex, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    row_now.enqueued_at_ns = 100;
    var row_old = try testRow(a, 0x2);
    @memcpy(&row_old.webhook_id_hex, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    row_old.enqueued_at_ns = 50;
    var row_future = try testRow(a, 0x3);
    @memcpy(&row_future.webhook_id_hex, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
    row_future.enqueued_at_ns = 1_000_000;

    var rows = [_]WebhookRow{ row_now, row_old, row_future };
    defer for (&rows) |*r| r.deinit(a);
    try store.applyEnqueueBatch(&rows);

    // now=200 → row_old (50) and row_now (100) ready, row_future (1M) not.
    const ready = try store.readyRows(a, 200, 16);
    defer {
        for (ready) |*r| r.deinit(a);
        a.free(ready);
    }
    try testing.expectEqual(@as(usize, 2), ready.len);
    try testing.expectEqual(@as(i64, 50), ready[0].next_attempt_at_ns);
    try testing.expectEqual(@as(i64, 100), ready[1].next_attempt_at_ns);

    // Cap respected.
    const capped = try store.readyRows(a, 200, 1);
    defer {
        for (capped) |*r| r.deinit(a);
        a.free(capped);
    }
    try testing.expectEqual(@as(usize, 1), capped.len);
    try testing.expectEqual(@as(i64, 50), capped[0].next_attempt_at_ns);

    // Pushing row_old's state forward via complete removes it from results.
    try store.applyComplete(&row_old.webhook_id_hex);
    const after_complete = try store.readyRows(a, 200, 16);
    defer {
        for (after_complete) |*r| r.deinit(a);
        a.free(after_complete);
    }
    try testing.expectEqual(@as(usize, 1), after_complete.len);
    try testing.expectEqualSlices(u8, &row_now.webhook_id_hex, &after_complete[0].row.webhook_id_hex);
}

test "applyComplete on missing id is a no-op" {
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(a, "/tmp/rove-webhook-test2-{x}", .{seed});
    defer a.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/webhooks.db", .{tmp_dir}, 0);
    defer a.free(db_path);

    var store = try WebhookStore.open(a, db_path);
    defer store.close();

    const missing_id = fillHex(0xdd);
    try store.applyComplete(&missing_id);
}
