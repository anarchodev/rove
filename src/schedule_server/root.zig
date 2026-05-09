//! rove-schedule-server — cluster-wide raft-replicated scheduled
//! HTTP delivery. The platform's outbound HTTP primitive
//! (`http.send` / `http.cancel`).
//!
//! See `docs/http-send-plan.md` for the full design. This module
//! supersedes `webhook_server` in spirit; the cutover lands in a
//! later step of the migration.
//!
//! ## Scope of this module
//!
//! Step 1 of the migration (this commit): on-disk shape, envelope
//! wire format, and apply primitives. The leader-pinned scheduler
//! thread + the `http.send` JS binding + the `webhook.loop46.com`
//! default-policy tenant land in subsequent steps. Mirrors
//! `webhook_server`'s step-1 posture exactly — same module shape,
//! same kv-backed storage trick (swap in real sqlite + indices when
//! the "due rows" query needs them).
//!
//! ## Storage shape
//!
//! Rows live in `{data_dir}/schedules.db` (a single
//! `kv.KvStore`, raft-replicated) keyed by `s/{tenant_id}/{id}`.
//! Each row's value is a `serializeStored`-encoded `StoredSchedule`.
//! The `(tenant_id, id)` composite key falls out of the prefix
//! shape: `s/acme/reminder-foo` and `s/beta/reminder-foo` are
//! distinct kv keys, no further uniqueness logic needed.
//!
//! ## What lives in this module
//!
//! - `ScheduleRow` — in-memory shape for one schedule, owned by the
//!   producer (dispatcher), consumed by the scheduler thread.
//! - `StoredSchedule` — the on-disk row (adds `version`,
//!   `inflight_until_ns`, `is_internal`).
//! - `ScheduleStore` — opens / owns the per-node `schedules.db`
//!   and exposes the apply primitives raft replays.
//! - Wire-format encode/decode for envelope types 8 (upsert),
//!   9 (complete), 10 (cancel). Numbers are transitional during
//!   the webhook-server cutover; they collapse to 4/5/8 once the
//!   legacy webhook envelopes retire (plan §11 step 6).
//!
//! ## What does NOT live here
//!
//! - The leader-pinned scheduler thread (next slice).
//! - The dispatcher's per-handler accumulator + the `http.send` /
//!   `http.cancel` JS bindings (slice after that).
//! - `webhook.loop46.com` — that's a system tenant deployed via
//!   files-server bootstrap, customer-equivalent JS.

const std = @import("std");
const kv = @import("rove-kv");

/// Leader-pinned scheduler thread — picks up due rows, fires them
/// over libcurl, proposes envelope-9 with the result. See plan §5.
pub const thread = @import("thread.zig");

/// URL → cluster-tenant detection (plan §3.2). Called at apply time
/// from `applyScheduleUpsertBatch` to stamp `is_internal` on rows
/// targeting `{id}.{public_suffix}`.
pub const internal_routing = @import("internal_routing.zig");

pub const Error = error{
    Truncated,
    InvalidVersion,
    InvalidOutcome,
    InvalidHandle,
    InvalidMethod,
    OutOfMemory,
    Kv,
};

/// Body cap on what gets stamped into envelope-9 (complete) and
/// handed back to the customer's on_result handler. Mirrors the
/// existing webhook cap; see `docs/http-send-plan.md` §1.
pub const RESPONSE_BODY_CAP: usize = 256 * 1024;

/// Customer-supplied handle width: 1-256 bytes UTF-8, no NUL. The
/// platform-derived id (sha256 hex) is 64 chars, well inside.
pub const ID_MAX_LEN: usize = 256;

// ── Envelope types ─────────────────────────────────────────────────────
//
// Transitional numbers during the webhook-server migration. Plan
// §11 step 6 renames 8 → 4, 9 → 5, 10 → 8 once the legacy webhook
// envelopes are gone. Until then, the numeric slots stay separate
// so both subsystems can run in parallel during the drain window.

pub const ENVELOPE_TYPE_UPSERT: u8 = 8;
pub const ENVELOPE_TYPE_COMPLETE: u8 = 9;
pub const ENVELOPE_TYPE_CANCEL: u8 = 10;
pub const ENVELOPE_TYPE_DEMOTE: u8 = 11;

/// Outcome on the wire — `applyComplete` consults this when deciding
/// whether to deliver `_callback/{id}` with success or failure
/// shape. Same enum byte layout as `webhook_server.Outcome`.
pub const Outcome = enum(u8) {
    delivered = 0,
    failed = 1,
};

// ── In-memory shapes ───────────────────────────────────────────────────

/// One scheduled HTTP call. Owned slices are freed by `deinit`.
/// Wire-format-friendly: round-trips through `encodeUpsertBatch` /
/// `decodeUpsertBatch` losslessly.
pub const ScheduleRow = struct {
    /// Tenant scoping the id. Borrowed from the dispatcher's
    /// per-request state on encode; owned (allocator-allocated)
    /// after decode.
    tenant_id: []const u8,
    /// Customer handle (1-256 bytes utf8, no NUL) OR the platform-
    /// derived sha256 hex (64 chars) when no handle was provided.
    /// Treated as opaque text by storage.
    id: []const u8,
    fire_at_ns: i64,
    url: []const u8,
    method: []const u8,
    /// JSON object `{"Header-Name":"value", ...}`.
    headers_json: []const u8,
    body: []const u8,
    timeout_ms: u32 = 30_000,
    max_body_bytes: u32 = RESPONSE_BODY_CAP,
    /// Customer-tenant module that runs on result. Empty = fire-
    /// and-forget.
    on_result_module: []const u8 = "",
    /// JSON object handed back to the on_result handler.
    context_json: []const u8 = "null",
    /// True if the URL host matches a tenant on this cluster — set
    /// by the apply path via `detectInternal` (next slice). Routes
    /// the row into `dispatchInternalSchedules` instead of the
    /// libcurl path.
    is_internal: bool = false,

    pub fn deinit(self: *ScheduleRow, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.id);
        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.headers_json);
        allocator.free(self.body);
        allocator.free(self.on_result_module);
        allocator.free(self.context_json);
        self.* = undefined;
    }
};

/// On-disk representation. Adds the fields that aren't part of the
/// dispatcher's intent (version, inflight lease) but which the
/// store needs to track.
pub const StoredSchedule = struct {
    row: ScheduleRow,
    /// Bumped on every same-handle upsert. Envelope 9 carries the
    /// version it saw at fire time so apply can drop stale results
    /// after an overwrite-while-firing race (plan §7).
    version: u32,
    /// Lease for ops visibility. Not raft-replicated in v1 — local
    /// only on each node. See plan §7.
    inflight_until_ns: i64 = 0,
    created_at_ns: i64,

    pub fn deinit(self: *StoredSchedule, allocator: std.mem.Allocator) void {
        self.row.deinit(allocator);
        self.* = undefined;
    }
};

// ── Store ──────────────────────────────────────────────────────────────

/// Cluster-wide schedule store. Backed by `{data_dir}/schedules.db`.
/// Rows live under `s/{tenant_id}/{id}` as `serializeStored` bytes.
pub const ScheduleStore = struct {
    allocator: std.mem.Allocator,
    db: *kv.KvStore,

    pub fn open(allocator: std.mem.Allocator, db_path: [:0]const u8) Error!ScheduleStore {
        const db = kv.KvStore.open(allocator, db_path) catch return Error.Kv;
        return .{ .allocator = allocator, .db = db };
    }

    pub fn close(self: *ScheduleStore) void {
        self.db.close();
        self.* = undefined;
    }

    /// Build `s/{tenant_id}/{id}`. Caller-provided buffer must be
    /// at least `2 + tenant_id.len + 1 + id.len` bytes.
    fn rowKey(buf: []u8, tenant_id: []const u8, id: []const u8) []u8 {
        std.debug.assert(buf.len >= 2 + tenant_id.len + 1 + id.len);
        var pos: usize = 0;
        @memcpy(buf[pos..][0..2], "s/");
        pos += 2;
        @memcpy(buf[pos..][0..tenant_id.len], tenant_id);
        pos += tenant_id.len;
        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos..][0..id.len], id);
        pos += id.len;
        return buf[0..pos];
    }

    /// Apply one envelope-8 batch — UPSERT for each row. Bumps
    /// `version` on existing rows; inserts at version=1 for new
    /// rows. Idempotent at the version level: re-applying the same
    /// envelope (e.g., from a raft log replay during catch-up) sets
    /// the row to the same final state, just with a bumped version.
    /// The version mismatch in envelope 9 covers stale results
    /// from prior versions either way.
    pub fn applyUpsertBatch(self: *ScheduleStore, rows: []const ScheduleRow, now_ns: i64) Error!void {
        self.db.begin() catch return Error.Kv;
        errdefer self.db.rollback() catch {};
        for (rows) |row| try self.upsertOne(&row, now_ns);
        self.db.commit() catch return Error.Kv;
    }

    fn upsertOne(self: *ScheduleStore, row: *const ScheduleRow, now_ns: i64) Error!void {
        try validateId(row.id);
        const key_len = 2 + row.tenant_id.len + 1 + row.id.len;
        const key_buf = self.allocator.alloc(u8, key_len) catch return Error.OutOfMemory;
        defer self.allocator.free(key_buf);
        const key = rowKey(key_buf, row.tenant_id, row.id);

        var prev_version: u32 = 0;
        var prev_created: i64 = now_ns;
        const existing = self.db.get(key) catch |err| switch (err) {
            error.NotFound => null,
            else => return Error.Kv,
        };
        if (existing) |bytes| {
            defer self.allocator.free(bytes);
            var prev = parseStored(self.allocator, bytes) catch |err| switch (err) {
                Error.OutOfMemory => return Error.OutOfMemory,
                else => return Error.Truncated,
            };
            defer prev.deinit(self.allocator);
            prev_version = prev.version;
            prev_created = prev.created_at_ns;
        }

        const stored: StoredSchedule = .{
            .row = row.*,
            .version = prev_version + 1,
            .inflight_until_ns = 0,
            .created_at_ns = prev_created,
        };
        const encoded = serializeStored(self.allocator, &stored) catch return Error.OutOfMemory;
        defer self.allocator.free(encoded);
        self.db.put(key, encoded) catch return Error.Kv;
    }

    /// Apply envelope 9 — schedule reached terminal outcome. Checks
    /// `version_at_fire == row.version`; on match deletes the row
    /// (companion `_callback/{id}` write to the tenant's app.db is
    /// the apply path's responsibility, separate connection — see
    /// the next-slice `apply.zig` integration). On mismatch, the
    /// envelope is silently dropped: the customer overwrote the row
    /// while the fire was in flight; the new version stays
    /// scheduled. Idempotent: a missing row is also a no-op.
    pub fn applyComplete(
        self: *ScheduleStore,
        tenant_id: []const u8,
        id: []const u8,
        version_at_fire: u32,
    ) Error!enum { delivered, version_mismatch, missing } {
        try validateId(id);
        const key_len = 2 + tenant_id.len + 1 + id.len;
        const key_buf = self.allocator.alloc(u8, key_len) catch return Error.OutOfMemory;
        defer self.allocator.free(key_buf);
        const key = rowKey(key_buf, tenant_id, id);

        const existing_bytes = self.db.get(key) catch |err| switch (err) {
            error.NotFound => return .missing,
            else => return Error.Kv,
        };
        defer self.allocator.free(existing_bytes);
        var stored = parseStored(self.allocator, existing_bytes) catch |err| switch (err) {
            Error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Truncated,
        };
        defer stored.deinit(self.allocator);

        if (stored.version != version_at_fire) return .version_mismatch;
        self.db.delete(key) catch |err| switch (err) {
            error.NotFound => return .missing,
            else => return Error.Kv,
        };
        return .delivered;
    }

    /// Apply envelope 11 — demote. The worker phase couldn't serve
    /// this internal-pool row in-process (target tenant not hosted
    /// locally on the leader), so it asked us to move the row to
    /// the external pool where the libcurl thread will pick it up.
    /// Idempotent: missing row is a no-op. Already-external row is
    /// a no-op (worker phase scanned the internal pool, but the row
    /// got demoted between scan and propose). Does NOT bump
    /// `version` — that's reserved for customer-driven overwrites
    /// via `http.send` with the same handle.
    pub fn applyDemote(self: *ScheduleStore, tenant_id: []const u8, id: []const u8) Error!void {
        try validateId(id);
        const key_len = 2 + tenant_id.len + 1 + id.len;
        const key_buf = self.allocator.alloc(u8, key_len) catch return Error.OutOfMemory;
        defer self.allocator.free(key_buf);
        const key = rowKey(key_buf, tenant_id, id);

        const existing_bytes = self.db.get(key) catch |err| switch (err) {
            error.NotFound => return,
            else => return Error.Kv,
        };
        defer self.allocator.free(existing_bytes);
        var stored = parseStored(self.allocator, existing_bytes) catch |err| switch (err) {
            Error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Truncated,
        };
        defer stored.deinit(self.allocator);

        if (!stored.row.is_internal) return; // already external; no-op
        stored.row.is_internal = false;

        const encoded = serializeStored(self.allocator, &stored) catch return Error.OutOfMemory;
        defer self.allocator.free(encoded);
        self.db.put(key, encoded) catch return Error.Kv;
    }

    /// Apply envelope 10 — cancel. Idempotent: missing row is a
    /// no-op (already fired or already cancelled). The customer's
    /// on_result handler does NOT fire on cancel — they cancelled,
    /// they don't get a delivery notification.
    pub fn applyCancel(self: *ScheduleStore, tenant_id: []const u8, id: []const u8) Error!void {
        try validateId(id);
        const key_len = 2 + tenant_id.len + 1 + id.len;
        const key_buf = self.allocator.alloc(u8, key_len) catch return Error.OutOfMemory;
        defer self.allocator.free(key_buf);
        const key = rowKey(key_buf, tenant_id, id);
        self.db.delete(key) catch |err| switch (err) {
            error.NotFound => return,
            else => return Error.Kv,
        };
    }

    /// Read one stored schedule. Returns null if absent. Caller
    /// owns the returned `StoredSchedule` and must `deinit` it.
    pub fn get(self: *ScheduleStore, tenant_id: []const u8, id: []const u8) Error!?StoredSchedule {
        try validateId(id);
        const key_len = 2 + tenant_id.len + 1 + id.len;
        const key_buf = self.allocator.alloc(u8, key_len) catch return Error.OutOfMemory;
        defer self.allocator.free(key_buf);
        const key = rowKey(key_buf, tenant_id, id);

        const bytes = self.db.get(key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        return parseStored(self.allocator, bytes) catch |err| switch (err) {
            Error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Truncated,
        };
    }

    /// Scan the external pool — rows the libcurl scheduler thread
    /// should fire: `is_internal=false AND fire_at_ns ≤ now_ns AND
    /// inflight_until_ns ≤ now_ns`.
    ///
    /// Two-pool design (plan §3.2): rows live in exactly one pool at
    /// a time, set by apply. Worker phase reads `dueInternalRows`
    /// and serves in-process when target is hosted locally; when
    /// it isn't, the worker phase proposes envelope-11
    /// (`schedule_demote`) which flips `is_internal=false` and
    /// transfers the row to this pool. No timeouts, no shared
    /// inflight between consumers — the demote envelope is the
    /// only path from internal pool to external pool.
    ///
    /// Caller owns the returned slice; each element must be
    /// `deinit`'d (then the slice freed).
    ///
    /// V1 implementation: full-prefix scan with in-Zig filtering. Fine
    /// for the row counts the platform will see at launch. When the
    /// store grows past ~10k schedules we add a `(fire_at_ns,
    /// is_internal)` index table and a top-N query; the public
    /// surface stays the same.
    pub fn dueRows(
        self: *ScheduleStore,
        allocator: std.mem.Allocator,
        now_ns: i64,
        max: usize,
    ) Error![]StoredSchedule {
        return self.scanRows(allocator, now_ns, max, .external);
    }

    /// Scan the internal pool — rows the worker phase should
    /// dispatch in-process: `is_internal=true AND fire_at_ns ≤
    /// now_ns AND inflight_until_ns ≤ now_ns`. Companion to
    /// `dueRows`; see that comment for the two-pool contract.
    pub fn dueInternalRows(
        self: *ScheduleStore,
        allocator: std.mem.Allocator,
        now_ns: i64,
        max: usize,
    ) Error![]StoredSchedule {
        return self.scanRows(allocator, now_ns, max, .internal);
    }

    const ScanFlavor = enum { external, internal };

    fn scanRows(
        self: *ScheduleStore,
        allocator: std.mem.Allocator,
        now_ns: i64,
        max: usize,
        flavor: ScanFlavor,
    ) Error![]StoredSchedule {
        var out: std.ArrayList(StoredSchedule) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit(allocator);
            out.deinit(allocator);
        }

        var cursor: []const u8 = "";
        var cursor_owned: ?[]u8 = null;
        defer if (cursor_owned) |b| allocator.free(b);

        while (out.items.len < max) {
            var page = self.db.prefix("s/", cursor, 1024) catch return Error.Kv;
            defer page.deinit();
            for (page.entries) |entry| {
                var stored = parseStored(allocator, entry.value) catch |err| switch (err) {
                    Error.OutOfMemory => return Error.OutOfMemory,
                    else => continue,
                };
                if (stored.inflight_until_ns > now_ns or stored.row.fire_at_ns > now_ns) {
                    stored.deinit(allocator);
                    continue;
                }
                const eligible = switch (flavor) {
                    .external => !stored.row.is_internal,
                    .internal => stored.row.is_internal,
                };
                if (!eligible) {
                    stored.deinit(allocator);
                    continue;
                }
                out.append(allocator, stored) catch {
                    stored.deinit(allocator);
                    return Error.OutOfMemory;
                };
                if (out.items.len >= max) break;
            }
            if (page.entries.len < 1024) break;
            const last_key = page.entries[page.entries.len - 1].key;
            if (cursor_owned) |b| allocator.free(b);
            const buf = allocator.alloc(u8, last_key.len) catch return Error.OutOfMemory;
            @memcpy(buf, last_key);
            cursor_owned = buf;
            cursor = buf;
        }
        return out.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }

    /// Whole-store row count. Used by ops dashboards + the
    /// in-flight cap check (plan §13.1).
    pub fn count(self: *ScheduleStore) Error!u64 {
        var total: u64 = 0;
        var cursor: []const u8 = "";
        while (true) {
            var page = self.db.prefix("s/", cursor, 1024) catch return Error.Kv;
            defer page.deinit();
            total += page.entries.len;
            if (page.entries.len < 1024) break;
            cursor = page.entries[page.entries.len - 1].key;
        }
        return total;
    }
};

fn validateId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > ID_MAX_LEN) return Error.InvalidHandle;
    for (id) |b| if (b == 0) return Error.InvalidHandle;
}

// ── Stored shape: serialize / parse ────────────────────────────────────

const STORED_VERSION: u8 = 1;

pub fn serializeStored(allocator: std.mem.Allocator, s: *const StoredSchedule) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, STORED_VERSION);
    try writeU32(allocator, &out, s.version);
    try writeI64(allocator, &out, s.inflight_until_ns);
    try writeI64(allocator, &out, s.created_at_ns);
    try out.append(allocator, @intFromBool(s.row.is_internal));
    try writeU16Bytes(allocator, &out, s.row.tenant_id);
    try writeU16Bytes(allocator, &out, s.row.id);
    try writeI64(allocator, &out, s.row.fire_at_ns);
    try writeU16Bytes(allocator, &out, s.row.url);
    try writeU8Bytes(allocator, &out, s.row.method);
    try writeU32Bytes(allocator, &out, s.row.headers_json);
    try writeU32Bytes(allocator, &out, s.row.body);
    try writeU32(allocator, &out, s.row.timeout_ms);
    try writeU32(allocator, &out, s.row.max_body_bytes);
    try writeU16Bytes(allocator, &out, s.row.on_result_module);
    try writeU32Bytes(allocator, &out, s.row.context_json);
    return out.toOwnedSlice(allocator);
}

pub fn parseStored(allocator: std.mem.Allocator, bytes: []const u8) Error!StoredSchedule {
    var r = Reader{ .data = bytes, .pos = 0 };
    const v = try r.byte();
    if (v != STORED_VERSION) return Error.InvalidVersion;
    const version = try r.u32le();
    const inflight_until_ns = try r.i64le();
    const created_at_ns = try r.i64le();
    const is_internal = (try r.byte()) != 0;
    const tenant_id = try r.bytesU16(allocator);
    errdefer allocator.free(tenant_id);
    const id = try r.bytesU16(allocator);
    errdefer allocator.free(id);
    const fire_at_ns = try r.i64le();
    const url = try r.bytesU16(allocator);
    errdefer allocator.free(url);
    const method = try r.bytesU8(allocator);
    errdefer allocator.free(method);
    const headers_json = try r.bytesU32(allocator);
    errdefer allocator.free(headers_json);
    const body = try r.bytesU32(allocator);
    errdefer allocator.free(body);
    const timeout_ms = try r.u32le();
    const max_body_bytes = try r.u32le();
    const on_result_module = try r.bytesU16(allocator);
    errdefer allocator.free(on_result_module);
    const context_json = try r.bytesU32(allocator);
    errdefer allocator.free(context_json);
    return .{
        .row = .{
            .tenant_id = tenant_id,
            .id = id,
            .fire_at_ns = fire_at_ns,
            .url = url,
            .method = method,
            .headers_json = headers_json,
            .body = body,
            .timeout_ms = timeout_ms,
            .max_body_bytes = max_body_bytes,
            .on_result_module = on_result_module,
            .context_json = context_json,
            .is_internal = is_internal,
        },
        .version = version,
        .inflight_until_ns = inflight_until_ns,
        .created_at_ns = created_at_ns,
    };
}

// ── Wire format: envelope 8 (upsert batch) ─────────────────────────────

pub const ENVELOPE_8_VERSION: u8 = 1;

pub fn encodeUpsertBatch(allocator: std.mem.Allocator, rows: []const ScheduleRow) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_8_VERSION);
    try writeU32(allocator, &out, @intCast(rows.len));
    for (rows) |row| try encodeOneRow(allocator, &out, &row);
    return out.toOwnedSlice(allocator);
}

pub fn decodeUpsertBatch(allocator: std.mem.Allocator, payload: []const u8) Error![]ScheduleRow {
    var r = Reader{ .data = payload, .pos = 0 };
    const v = try r.byte();
    if (v != ENVELOPE_8_VERSION) return Error.InvalidVersion;
    const count = try r.u32le();

    const out = allocator.alloc(ScheduleRow, count) catch return Error.OutOfMemory;
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

fn encodeOneRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), row: *const ScheduleRow) !void {
    try writeU16Bytes(allocator, out, row.tenant_id);
    try writeU16Bytes(allocator, out, row.id);
    try writeI64(allocator, out, row.fire_at_ns);
    try writeU16Bytes(allocator, out, row.url);
    try writeU8Bytes(allocator, out, row.method);
    try writeU32Bytes(allocator, out, row.headers_json);
    try writeU32Bytes(allocator, out, row.body);
    try writeU32(allocator, out, row.timeout_ms);
    try writeU32(allocator, out, row.max_body_bytes);
    try writeU16Bytes(allocator, out, row.on_result_module);
    try writeU32Bytes(allocator, out, row.context_json);
    try out.append(allocator, @intFromBool(row.is_internal));
}

fn decodeOneRow(allocator: std.mem.Allocator, r: *Reader) Error!ScheduleRow {
    const tenant_id = try r.bytesU16(allocator);
    errdefer allocator.free(tenant_id);
    const id = try r.bytesU16(allocator);
    errdefer allocator.free(id);
    try validateId(id);
    const fire_at_ns = try r.i64le();
    const url = try r.bytesU16(allocator);
    errdefer allocator.free(url);
    const method = try r.bytesU8(allocator);
    errdefer allocator.free(method);
    const headers_json = try r.bytesU32(allocator);
    errdefer allocator.free(headers_json);
    const body = try r.bytesU32(allocator);
    errdefer allocator.free(body);
    const timeout_ms = try r.u32le();
    const max_body_bytes = try r.u32le();
    const on_result_module = try r.bytesU16(allocator);
    errdefer allocator.free(on_result_module);
    const context_json = try r.bytesU32(allocator);
    errdefer allocator.free(context_json);
    const is_internal = (try r.byte()) != 0;
    return .{
        .tenant_id = tenant_id,
        .id = id,
        .fire_at_ns = fire_at_ns,
        .url = url,
        .method = method,
        .headers_json = headers_json,
        .body = body,
        .timeout_ms = timeout_ms,
        .max_body_bytes = max_body_bytes,
        .on_result_module = on_result_module,
        .context_json = context_json,
        .is_internal = is_internal,
    };
}

// ── Wire format: envelope 9 (complete) ─────────────────────────────────

pub const ENVELOPE_9_VERSION: u8 = 1;

pub const CompleteEnvelope = struct {
    tenant_id: []const u8,
    id: []const u8,
    version_at_fire: u32,
    outcome: Outcome,
    status: u16,
    response_headers_json: []const u8,
    response_body: []const u8,
    /// Transport-level error string. Empty when the call completed
    /// (regardless of HTTP status); populated for "couldn't connect"
    /// / "tls handshake failed" / "timeout" / etc.
    error_message: []const u8,

    pub fn deinit(self: *CompleteEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.id);
        allocator.free(self.response_headers_json);
        allocator.free(self.response_body);
        allocator.free(self.error_message);
        self.* = undefined;
    }
};

pub fn encodeComplete(allocator: std.mem.Allocator, env: *const CompleteEnvelope) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_9_VERSION);
    try writeU16Bytes(allocator, &out, env.tenant_id);
    try writeU16Bytes(allocator, &out, env.id);
    try writeU32(allocator, &out, env.version_at_fire);
    try out.append(allocator, @intFromEnum(env.outcome));
    try writeU16(allocator, &out, env.status);
    try writeU32Bytes(allocator, &out, env.response_headers_json);
    try writeU32Bytes(allocator, &out, env.response_body);
    try writeU16Bytes(allocator, &out, env.error_message);
    return out.toOwnedSlice(allocator);
}

pub fn decodeComplete(allocator: std.mem.Allocator, payload: []const u8) Error!CompleteEnvelope {
    var r = Reader{ .data = payload, .pos = 0 };
    const v = try r.byte();
    if (v != ENVELOPE_9_VERSION) return Error.InvalidVersion;
    const tenant_id = try r.bytesU16(allocator);
    errdefer allocator.free(tenant_id);
    const id = try r.bytesU16(allocator);
    errdefer allocator.free(id);
    try validateId(id);
    const version_at_fire = try r.u32le();
    const outcome_byte = try r.byte();
    const outcome = std.meta.intToEnum(Outcome, outcome_byte) catch return Error.InvalidOutcome;
    const status = try r.u16le();
    const response_headers_json = try r.bytesU32(allocator);
    errdefer allocator.free(response_headers_json);
    const response_body = try r.bytesU32(allocator);
    errdefer allocator.free(response_body);
    const error_message = try r.bytesU16(allocator);
    errdefer allocator.free(error_message);
    return .{
        .tenant_id = tenant_id,
        .id = id,
        .version_at_fire = version_at_fire,
        .outcome = outcome,
        .status = status,
        .response_headers_json = response_headers_json,
        .response_body = response_body,
        .error_message = error_message,
    };
}

// ── Wire format: envelope 10 (cancel batch) ────────────────────────────

pub const ENVELOPE_10_VERSION: u8 = 1;

pub const CancelTarget = struct {
    tenant_id: []const u8,
    id: []const u8,

    pub fn deinit(self: *CancelTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub fn encodeCancelBatch(allocator: std.mem.Allocator, targets: []const CancelTarget) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_10_VERSION);
    try writeU32(allocator, &out, @intCast(targets.len));
    for (targets) |t| {
        try writeU16Bytes(allocator, &out, t.tenant_id);
        try writeU16Bytes(allocator, &out, t.id);
    }
    return out.toOwnedSlice(allocator);
}

pub fn decodeCancelBatch(allocator: std.mem.Allocator, payload: []const u8) Error![]CancelTarget {
    var r = Reader{ .data = payload, .pos = 0 };
    const v = try r.byte();
    if (v != ENVELOPE_10_VERSION) return Error.InvalidVersion;
    const count = try r.u32le();
    const out = allocator.alloc(CancelTarget, count) catch return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*t| t.deinit(allocator);
        allocator.free(out);
    }
    while (filled < count) : (filled += 1) {
        const tenant_id = try r.bytesU16(allocator);
        errdefer allocator.free(tenant_id);
        const id = try r.bytesU16(allocator);
        errdefer allocator.free(id);
        try validateId(id);
        out[filled] = .{ .tenant_id = tenant_id, .id = id };
    }
    return out;
}

// ── Wire format: envelope 11 (demote) ──────────────────────────────────
//
// Single (tenant_id, id) tuple. The worker phase couldn't serve
// this internal-pool row in-process and is asking apply to flip
// `is_internal=false` so the libcurl thread picks it up. No batch
// shape — demotes are individual decisions; batching them across
// rows would couple unrelated failures into one envelope.

pub const ENVELOPE_11_VERSION: u8 = 1;

pub const DemoteTarget = struct {
    tenant_id: []const u8,
    id: []const u8,

    pub fn deinit(self: *DemoteTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub fn encodeDemote(allocator: std.mem.Allocator, target: *const DemoteTarget) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, ENVELOPE_11_VERSION);
    try writeU16Bytes(allocator, &out, target.tenant_id);
    try writeU16Bytes(allocator, &out, target.id);
    return out.toOwnedSlice(allocator);
}

pub fn decodeDemote(allocator: std.mem.Allocator, payload: []const u8) Error!DemoteTarget {
    var r = Reader{ .data = payload, .pos = 0 };
    const v = try r.byte();
    if (v != ENVELOPE_11_VERSION) return Error.InvalidVersion;
    const tenant_id = try r.bytesU16(allocator);
    errdefer allocator.free(tenant_id);
    const id = try r.bytesU16(allocator);
    errdefer allocator.free(id);
    try validateId(id);
    return .{ .tenant_id = tenant_id, .id = id };
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

// Pull thread.zig's tests into the schedule_server test binary. Without
// this Zig only collects tests from the root file plus any file whose
// declarations are referenced at comptime — `pub const thread = @import`
// is not enough on its own.
test {
    _ = thread;
    _ = internal_routing;
}

fn testRow(allocator: std.mem.Allocator, tenant: []const u8, id: []const u8, fire_at_ns: i64) !ScheduleRow {
    return .{
        .tenant_id = try allocator.dupe(u8, tenant),
        .id = try allocator.dupe(u8, id),
        .fire_at_ns = fire_at_ns,
        .url = try allocator.dupe(u8, "https://api.stripe.com/v1/charges"),
        .method = try allocator.dupe(u8, "POST"),
        .headers_json = try allocator.dupe(u8, "{\"Content-Type\":\"application/json\"}"),
        .body = try allocator.dupe(u8, "amount=500&currency=usd"),
        .timeout_ms = 30_000,
        .max_body_bytes = RESPONSE_BODY_CAP,
        .on_result_module = try allocator.dupe(u8, "stripe_response"),
        .context_json = try allocator.dupe(u8, "{\"order_id\":\"o-42\"}"),
        .is_internal = false,
    };
}

test "envelope 8 upsert batch round-trip" {
    const a = testing.allocator;
    var rows = [_]ScheduleRow{
        try testRow(a, "acme", "reminder-1", 1_700_000_000_000_000_000),
        try testRow(a, "beta", "checkout-99", 0),
    };
    rows[1].is_internal = true;
    defer for (&rows) |*r| r.deinit(a);

    const encoded = try encodeUpsertBatch(a, &rows);
    defer a.free(encoded);

    const decoded = try decodeUpsertBatch(a, encoded);
    defer {
        for (decoded) |*r| {
            var rr = r.*;
            rr.deinit(a);
        }
        a.free(decoded);
    }
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqualStrings("acme", decoded[0].tenant_id);
    try testing.expectEqualStrings("reminder-1", decoded[0].id);
    try testing.expectEqual(@as(i64, 1_700_000_000_000_000_000), decoded[0].fire_at_ns);
    try testing.expect(!decoded[0].is_internal);
    try testing.expectEqualStrings("beta", decoded[1].tenant_id);
    try testing.expectEqualStrings("checkout-99", decoded[1].id);
    try testing.expect(decoded[1].is_internal);
}

test "envelope 8 rejects bad version" {
    const a = testing.allocator;
    const bad = [_]u8{ 99, 0, 0, 0, 0 };
    try testing.expectError(Error.InvalidVersion, decodeUpsertBatch(a, &bad));
}

test "envelope 8 rejects empty handle" {
    const a = testing.allocator;
    var row = try testRow(a, "acme", "x", 0);
    a.free(@constCast(row.id));
    row.id = try a.dupe(u8, "");
    defer row.deinit(a);
    const rows = [_]ScheduleRow{row};
    const encoded = try encodeUpsertBatch(a, &rows);
    defer a.free(encoded);
    try testing.expectError(Error.InvalidHandle, decodeUpsertBatch(a, encoded));
}

test "envelope 9 complete round-trip" {
    const a = testing.allocator;
    const env: CompleteEnvelope = .{
        .tenant_id = try a.dupe(u8, "acme"),
        .id = try a.dupe(u8, "reminder-1"),
        .version_at_fire = 3,
        .outcome = .delivered,
        .status = 200,
        .response_headers_json = try a.dupe(u8, "{\"Content-Type\":\"application/json\"}"),
        .response_body = try a.dupe(u8, "{\"id\":\"ch_123\"}"),
        .error_message = try a.dupe(u8, ""),
    };
    var owned = env;
    defer owned.deinit(a);

    const encoded = try encodeComplete(a, &owned);
    defer a.free(encoded);

    var decoded = try decodeComplete(a, encoded);
    defer decoded.deinit(a);
    try testing.expectEqualStrings("acme", decoded.tenant_id);
    try testing.expectEqualStrings("reminder-1", decoded.id);
    try testing.expectEqual(@as(u32, 3), decoded.version_at_fire);
    try testing.expectEqual(Outcome.delivered, decoded.outcome);
    try testing.expectEqual(@as(u16, 200), decoded.status);
    try testing.expectEqualStrings("{\"id\":\"ch_123\"}", decoded.response_body);
}

test "envelope 9 carries transport error" {
    const a = testing.allocator;
    const env: CompleteEnvelope = .{
        .tenant_id = try a.dupe(u8, "acme"),
        .id = try a.dupe(u8, "x"),
        .version_at_fire = 1,
        .outcome = .failed,
        .status = 0,
        .response_headers_json = try a.dupe(u8, ""),
        .response_body = try a.dupe(u8, ""),
        .error_message = try a.dupe(u8, "tls: handshake failed"),
    };
    var owned = env;
    defer owned.deinit(a);
    const encoded = try encodeComplete(a, &owned);
    defer a.free(encoded);
    var decoded = try decodeComplete(a, encoded);
    defer decoded.deinit(a);
    try testing.expectEqualStrings("tls: handshake failed", decoded.error_message);
    try testing.expectEqual(Outcome.failed, decoded.outcome);
}

test "envelope 10 cancel batch round-trip" {
    const a = testing.allocator;
    const targets = [_]CancelTarget{
        .{ .tenant_id = "acme", .id = "reminder-1" },
        .{ .tenant_id = "beta", .id = "checkout-99" },
    };
    const encoded = try encodeCancelBatch(a, &targets);
    defer a.free(encoded);

    const decoded = try decodeCancelBatch(a, encoded);
    defer {
        for (decoded) |*t| {
            var tt = t.*;
            tt.deinit(a);
        }
        a.free(decoded);
    }
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqualStrings("acme", decoded[0].tenant_id);
    try testing.expectEqualStrings("reminder-1", decoded[0].id);
    try testing.expectEqualStrings("beta", decoded[1].tenant_id);
    try testing.expectEqualStrings("checkout-99", decoded[1].id);
}

test "envelope 11 demote round-trip" {
    const a = testing.allocator;
    const target: DemoteTarget = .{ .tenant_id = "acme", .id = "reminder-1" };
    const encoded = try encodeDemote(a, &target);
    defer a.free(encoded);

    var decoded = try decodeDemote(a, encoded);
    defer decoded.deinit(a);
    try testing.expectEqualStrings("acme", decoded.tenant_id);
    try testing.expectEqualStrings("reminder-1", decoded.id);
}

test "envelope 11 demote rejects bad version" {
    const a = testing.allocator;
    const bad = [_]u8{99} ++ [_]u8{ 0, 0 } ++ [_]u8{ 0, 0 };
    try testing.expectError(Error.InvalidVersion, decodeDemote(a, &bad));
}

// ── Store integration tests ────────────────────────────────────────────

fn openTempStore(allocator: std.mem.Allocator, buf: *[64]u8) !ScheduleStore {
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    const path = try std.fmt.bufPrintZ(buf, "/tmp/rove-sched-{d}.db", .{ts});
    return ScheduleStore.open(allocator, path);
}

fn cleanupTempStore(buf: *[64]u8) void {
    const path = std.mem.sliceTo(buf, 0);
    std.fs.cwd().deleteFile(path) catch {};
}

test "ScheduleStore: upsert then get round-trips" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }

    var row = try testRow(a, "acme", "reminder-1", 1_700_000_000_000_000_000);
    defer row.deinit(a);
    const rows = [_]ScheduleRow{row};
    try store.applyUpsertBatch(&rows, 1_700_000_000_000_000_000);

    const got = (try store.get("acme", "reminder-1")).?;
    var owned = got;
    defer owned.deinit(a);
    try testing.expectEqual(@as(u32, 1), owned.version);
    try testing.expectEqualStrings("https://api.stripe.com/v1/charges", owned.row.url);
    try testing.expectEqualStrings("stripe_response", owned.row.on_result_module);
}

test "ScheduleStore: same-handle upsert bumps version" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }

    var row = try testRow(a, "acme", "x", 1);
    defer row.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 1);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 2);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 3);

    const got = (try store.get("acme", "x")).?;
    var owned = got;
    defer owned.deinit(a);
    try testing.expectEqual(@as(u32, 3), owned.version);
    // created_at_ns of the FIRST insert is preserved across overwrites.
    try testing.expectEqual(@as(i64, 1), owned.created_at_ns);
}

test "ScheduleStore: applyComplete drops row on version match" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }
    var row = try testRow(a, "acme", "x", 0);
    defer row.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 0);

    const outcome = try store.applyComplete("acme", "x", 1);
    try testing.expectEqual(@as(@TypeOf(outcome), .delivered), outcome);
    try testing.expect((try store.get("acme", "x")) == null);
}

test "ScheduleStore: applyComplete with stale version is silently dropped" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }
    var row = try testRow(a, "acme", "x", 0);
    defer row.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 0);  // version=1
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 0);  // version=2

    // Stale envelope-9 from the v1 fire arrives; row is at v2 now.
    const outcome = try store.applyComplete("acme", "x", 1);
    try testing.expectEqual(@as(@TypeOf(outcome), .version_mismatch), outcome);
    // Row still present at v2 — the v1 fire's result was correctly dropped.
    const got = (try store.get("acme", "x")).?;
    var owned = got;
    defer owned.deinit(a);
    try testing.expectEqual(@as(u32, 2), owned.version);
}

test "ScheduleStore: applyComplete missing row is no-op" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }
    const outcome = try store.applyComplete("acme", "ghost", 1);
    try testing.expectEqual(@as(@TypeOf(outcome), .missing), outcome);
}

test "ScheduleStore: applyCancel deletes row + idempotent" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }
    var row = try testRow(a, "acme", "x", 0);
    defer row.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 0);
    try store.applyCancel("acme", "x");
    try testing.expect((try store.get("acme", "x")) == null);
    // Re-cancel of missing row is a no-op.
    try store.applyCancel("acme", "x");
}

test "ScheduleStore: tenant scoping — same id, different tenants" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }
    var ra = try testRow(a, "acme", "reminder-1", 1);
    defer ra.deinit(a);
    var rb = try testRow(a, "beta", "reminder-1", 2);
    defer rb.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{ ra, rb }, 0);

    const ga = (try store.get("acme", "reminder-1")).?;
    var oa = ga;
    defer oa.deinit(a);
    const gb = (try store.get("beta", "reminder-1")).?;
    var ob = gb;
    defer ob.deinit(a);
    try testing.expectEqual(@as(i64, 1), oa.row.fire_at_ns);
    try testing.expectEqual(@as(i64, 2), ob.row.fire_at_ns);

    // Cancel one tenant's row; the other survives.
    try store.applyCancel("acme", "reminder-1");
    try testing.expect((try store.get("acme", "reminder-1")) == null);
    if (try store.get("beta", "reminder-1")) |g| {
        var b_owned = g;
        b_owned.deinit(a);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "ScheduleStore: dueRows returns only external rows; dueInternalRows returns only internal" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }

    var ext = try testRow(a, "acme", "ext", 100);
    defer ext.deinit(a);
    var future = try testRow(a, "acme", "future", std.time.ns_per_s * 60);
    defer future.deinit(a);
    var internal_ = try testRow(a, "acme", "internal", 100);
    internal_.is_internal = true;
    defer internal_.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{ ext, future, internal_ }, 0);

    const due_ext = try store.dueRows(a, 500, 32);
    defer {
        for (due_ext) |*r| {
            var x = r.*;
            x.deinit(a);
        }
        a.free(due_ext);
    }
    try testing.expectEqual(@as(usize, 1), due_ext.len);
    try testing.expectEqualStrings("ext", due_ext[0].row.id);

    const due_int = try store.dueInternalRows(a, 500, 32);
    defer {
        for (due_int) |*r| {
            var x = r.*;
            x.deinit(a);
        }
        a.free(due_int);
    }
    try testing.expectEqual(@as(usize, 1), due_int.len);
    try testing.expectEqualStrings("internal", due_int[0].row.id);
}

test "ScheduleStore: applyDemote flips is_internal to false; idempotent" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }

    var row = try testRow(a, "acme", "x", 100);
    row.is_internal = true;
    defer row.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{row}, 0);

    // Demote: flips to external, preserves version.
    try store.applyDemote("acme", "x");
    {
        const got = (try store.get("acme", "x")).?;
        var owned = got;
        defer owned.deinit(a);
        try testing.expect(!owned.row.is_internal);
        try testing.expectEqual(@as(u32, 1), owned.version);
    }

    // Re-demote: already external, no-op.
    try store.applyDemote("acme", "x");
    {
        const got = (try store.get("acme", "x")).?;
        var owned = got;
        defer owned.deinit(a);
        try testing.expect(!owned.row.is_internal);
    }

    // Demote of missing row: no-op.
    try store.applyDemote("acme", "ghost");
}

test "ScheduleStore: dueInternalRows returns only is_internal rows" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }

    var ext = try testRow(a, "acme", "ext", 100);
    defer ext.deinit(a);
    var int1 = try testRow(a, "acme", "int1", 100);
    int1.is_internal = true;
    defer int1.deinit(a);
    var int_future = try testRow(a, "acme", "int-future", std.time.ns_per_s * 60);
    int_future.is_internal = true;
    defer int_future.deinit(a);
    try store.applyUpsertBatch(&[_]ScheduleRow{ ext, int1, int_future }, 0);

    const due = try store.dueInternalRows(a, 500, 32);
    defer {
        for (due) |*r| {
            var x = r.*;
            x.deinit(a);
        }
        a.free(due);
    }
    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("int1", due[0].row.id);
    try testing.expect(due[0].row.is_internal);
}

test "ScheduleStore: dueRows respects max" {
    const a = testing.allocator;
    var path_buf: [64]u8 = undefined;
    var store = try openTempStore(a, &path_buf);
    defer {
        store.close();
        cleanupTempStore(&path_buf);
    }

    var rows: [5]ScheduleRow = undefined;
    var ids: [5][]u8 = undefined;
    for (&rows, &ids, 0..) |*r, *id, i| {
        const id_str = try std.fmt.allocPrint(a, "row-{d}", .{i});
        id.* = id_str;
        r.* = try testRow(a, "acme", id_str, 100);
    }
    defer for (&rows) |*r| r.deinit(a);
    defer for (ids) |id| a.free(id);
    try store.applyUpsertBatch(&rows, 0);

    const due = try store.dueRows(a, 500, 3);
    defer {
        for (due) |*r| {
            var x = r.*;
            x.deinit(a);
        }
        a.free(due);
    }
    try testing.expectEqual(@as(usize, 3), due.len);
}

test "validateId: bounds + NUL rejection" {
    try validateId("a"); // ok
    var buf: [ID_MAX_LEN]u8 = undefined;
    @memset(&buf, 'a');
    try validateId(&buf); // exactly 256 bytes ok

    var oversize: [ID_MAX_LEN + 1]u8 = undefined;
    @memset(&oversize, 'a');
    try testing.expectError(Error.InvalidHandle, validateId(&oversize));

    try testing.expectError(Error.InvalidHandle, validateId(""));
    try testing.expectError(Error.InvalidHandle, validateId("a\x00b"));
}
