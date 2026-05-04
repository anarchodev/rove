//! SSE pump: reads `_events/{sid}/...` rows from each tenant's app.db
//! and pushes wire frames to connected EventSource clients.
//!
//! Architecture (docs/sse-plan.md §4.1):
//! - `TenantFiles.sse_connections` is a per-tenant list of active
//!   SSE connection records (sid + h2 stream entity + last_event_id +
//!   last_send_ns). Lookup is linear; v1 caps connections-per-instance
//!   at 100 (free) / 10k (paid) so a linear scan is fine for free tier
//!   and acceptable for paid (10k * O(microsecond) per tick).
//! - `TenantFiles.dirty_sids` is a hashset of sids with new events
//!   since the last pump tick. `markDirtyFromWriteset` populates it
//!   after each successful commit by scanning the writeset's ops for
//!   `_events/{sid}/...` keys.
//! - `pumpEvents(worker)` iterates `tenant_files_map`, drives ready
//!   connections (those whose h2 entity sits in `stream_data_out`,
//!   meaning h2 is asking for the next chunk). For each ready
//!   connection: if the sid is dirty OR keepalive is overdue, format
//!   a wire frame, set RespBody, move to `stream_data_in`.
//! - `cleanupClosedSseConnections(worker)` scans `response_out` BEFORE
//!   `cleanupResponses` runs and removes our records for entities h2
//!   has finished.
//!
//! The pump runs in the same worker thread as the dispatcher — no
//! cross-thread synchronization needed. Single-node v1.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("rove-kv");

const events_mod = @import("events.zig");
const limiter_mod = @import("limiter.zig");

/// Per-connection record. Owned by the tenant's `TenantFiles`.
pub const SseConnection = struct {
    /// The h2 stream entity. Lifecycle managed by h2. We read its
    /// current collection (`stream_data_out` vs `stream_data_in` vs
    /// `response_out`) to know whether it's ready for our next push.
    stream_ent: rove.Entity,
    /// Owned 64-hex sid. Same value as the cookie.
    sid: [64]u8,
    /// Wire id of the most recent event we pushed (zero-padded
    /// "request_id-call_index" — 27 chars). The pump's prefix scan
    /// starts strictly after this. Initialized from the request's
    /// `Last-Event-ID` header (or `?since=`) on connect, default
    /// "00000000000000000000-000000".
    last_event_id: [27]u8,
    /// Monotonic-ns timestamp of the last frame we wrote (data or
    /// keepalive ping). Drives the keepalive cycle.
    last_send_ns: i64,

    pub fn newAt(stream_ent: rove.Entity, sid: [64]u8, last_event_id: [27]u8, now_ns: i64) SseConnection {
        return .{
            .stream_ent = stream_ent,
            .sid = sid,
            .last_event_id = last_event_id,
            .last_send_ns = now_ns,
        };
    }
};

/// Default Last-Event-ID for fresh connections — sorts before every
/// real wire id, so the first prefix scan sees all retained events.
pub const ZERO_LAST_EVENT_ID: [27]u8 = "00000000000000000000-000000".*;

/// Parse a Last-Event-ID header value (or ?since= query param). The
/// expected shape is `{request_id:020d}-{call_index:06d}` (27 chars).
/// Returns `ZERO_LAST_EVENT_ID` on missing/malformed input — same as
/// fresh connect, which is the "deliver everything currently in
/// retention" behavior.
pub fn parseLastEventId(s: ?[]const u8) [27]u8 {
    const v = s orelse return ZERO_LAST_EVENT_ID;
    if (v.len != 27) return ZERO_LAST_EVENT_ID;
    if (v[20] != '-') return ZERO_LAST_EVENT_ID;
    for (v[0..20]) |b| {
        if (b < '0' or b > '9') return ZERO_LAST_EVENT_ID;
    }
    for (v[21..27]) |b| {
        if (b < '0' or b > '9') return ZERO_LAST_EVENT_ID;
    }
    var out: [27]u8 = undefined;
    @memcpy(&out, v);
    return out;
}

/// Keepalive cadence — emit `:ping\n\n` to any connection quiet for
/// this long. 25s sits comfortably inside common LB / proxy idle
/// timeouts (30s+).
pub const KEEPALIVE_INTERVAL_NS: i64 = 25 * std.time.ns_per_s;

/// Per-pump-tick scan budget per connection. The pump processes at
/// most this many `_events/{sid}/...` rows per connection per tick;
/// the rest deliver next tick. Bounds tail latency under bursts.
pub const PUMP_BATCH_LIMIT: u32 = 32;

// ── Connection-table operations ───────────────────────────────────

/// `tc` is `*TenantFiles` (we leave the type erased to break a
/// circular import — worker.zig imports events_pump.zig too via
/// the worker tick loop).
pub fn addConnection(
    tc: anytype,
    conn: SseConnection,
) !void {
    try tc.sse_connections.append(tc.allocator, conn);
}

pub fn removeConnectionByEntity(tc: anytype, ent: rove.Entity) void {
    var i: usize = 0;
    while (i < tc.sse_connections.items.len) : (i += 1) {
        if (rove.Entity.eql(tc.sse_connections.items[i].stream_ent, ent)) {
            _ = tc.sse_connections.swapRemove(i);
            return;
        }
    }
}

pub fn countConnections(tc: anytype) u32 {
    return @intCast(tc.sse_connections.items.len);
}

pub fn countConnectionsForSid(tc: anytype, sid: []const u8) u32 {
    var n: u32 = 0;
    for (tc.sse_connections.items) |*conn| {
        if (std.mem.eql(u8, &conn.sid, sid)) n += 1;
    }
    return n;
}

// ── Dirty-marking ─────────────────────────────────────────────────

/// Inspect a freshly-committed writeset for `_events/{sid}/...` keys
/// and insert each sid into `tc.dirty_sids` IFF the tenant has at
/// least one connection subscribed to that sid. Skipping the
/// no-listener case keeps pump work proportional to actual
/// connections, not to per-tenant emit volume.
pub fn markDirtyFromWriteset(
    tc: anytype,
    writeset: *const kv_mod.WriteSet,
) !void {
    if (tc.sse_connections.items.len == 0) return;
    for (writeset.ops.items) |op| {
        const key = switch (op) {
            .put => |p| p.key,
            .delete => |d| d.key,
        };
        const sid = sidFromEventsKey(key) orelse continue;
        // Skip if no connection for this sid.
        if (countConnectionsForSid(tc, sid) == 0) continue;
        // dirty_sids is a hashmap keyed by the sid string. We need an
        // owned key the table can hold; allocate-on-insert via
        // getOrPut and dupe on first sight.
        const gop = try tc.dirty_sids.getOrPut(tc.allocator, sid);
        if (!gop.found_existing) {
            const owned = try tc.allocator.dupe(u8, sid);
            gop.key_ptr.* = owned;
        }
    }
}

/// Extract the sid from a key shaped `_events/{sid}/{seq}`. Returns
/// null if the key doesn't match (no `_events/` prefix, missing sid,
/// missing slash after sid). Sid validation (64 lowercase hex) is
/// the JS binding's responsibility — by the time keys land in the
/// writeset the sid has already passed `events.zig:isValidSid`.
pub fn sidFromEventsKey(key: []const u8) ?[]const u8 {
    const PREFIX = "_events/";
    if (!std.mem.startsWith(u8, key, PREFIX)) return null;
    const rest = key[PREFIX.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

// ── Wire-frame formatting ─────────────────────────────────────────

/// Format an SSE wire frame from a stored envelope into `out`. Returns
/// the slice that was filled. Returns error.Overflow if `out` is too
/// small.
///
/// Wire shape:
/// ```
/// id: <wire_id>
/// event: <type>
/// data: <data as JSON>
///
/// ```
/// (trailing blank line per SSE spec)
///
/// `wire_id` comes from the storage key suffix (the part after the
/// last `/`). `type` and `data` come from the JSON envelope written
/// by `events.emit`.
pub fn formatFrame(
    out: []u8,
    wire_id: []const u8,
    envelope_json: []const u8,
) ![]u8 {
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    try w.print("id: {s}\n", .{wire_id});

    // Pull `type` and `data` out of the envelope without a full JSON
    // parse — we wrote it ourselves in events.zig and the field
    // layout is stable. Substring search is fine; envelope JSON
    // never contains `"type":` or `"data":` inside string values
    // that would collide (event types are user-supplied strings but
    // we control the envelope's outer shape).
    if (extractJsonField(envelope_json, "\"type\":\"")) |type_val| {
        try w.print("event: {s}\n", .{type_val});
    }
    if (extractJsonValue(envelope_json, "\"data\":")) |data_val| {
        // Newlines in `data:` need explicit per-line repetition per
        // the SSE spec. v1 emits compact JSON (no newlines) so this
        // is a single line.
        try w.print("data: {s}\n", .{data_val});
    }
    try w.writeAll("\n");
    return fbs.getWritten();
}

/// Format a `:ping\n\n` keepalive frame. Returns the canonical bytes.
pub fn keepaliveFrame() []const u8 {
    return ":ping\n\n";
}

/// Extract a JSON string field's value from a substring search.
/// Returns the slice between the opening quote (after `prefix`) and
/// the next unescaped quote. Used for `"type"` extraction; `data`
/// uses `extractJsonValue` because the value may not be a string.
fn extractJsonField(json: []const u8, prefix: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    const start = idx + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

/// Extract a JSON value (after `"key":`) until a balanced delimiter.
/// Handles strings, numbers, objects, arrays, true/false/null. v1
/// implementation is a simple bracket-counter that stops at the
/// matching `}` or `,` at the outer level.
fn extractJsonValue(json: []const u8, prefix: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, prefix) orelse return null;
    var i = idx + prefix.len;
    if (i >= json.len) return null;
    const start = i;
    var depth: i32 = 0;
    var in_str = false;
    var escape = false;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (ch == '\\') {
                escape = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return json[start..i];
                depth -= 1;
            },
            ',' => if (depth == 0) return json[start..i],
            else => {},
        }
    }
    return json[start..];
}

// ── Pump cycle ────────────────────────────────────────────────────

/// Drive every tenant's SSE connections one tick. Called from the
/// user's poll loop between `worker.poll()` and `reg.flush()`,
/// alongside `flushLogs`, `dispatchCallbacks`, etc.
///
/// For each connection that h2 has parked in `stream_data_out`
/// (meaning it's asking for the next chunk to send):
///   1. If the sid is in `dirty_sids` AND the prefix scan returns
///      rows: format frames, write, move to `stream_data_in`.
///   2. Else if `last_send_ns + KEEPALIVE_INTERVAL_NS <= now`: emit
///      `:ping\n\n`, move to `stream_data_in`.
///   3. Else: leave in `stream_data_out`.
///
/// Connections in `stream_data_in` (waiting for h2 to flush) or in
/// terminal collections (`response_out`) are ignored — h2 owns
/// their state until they come back.
pub fn pumpEvents(worker: anytype) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (tc.sse_connections.items.len == 0) continue;

        const inst_opt = worker.tenant.getInstance(tc.instance_id) catch null;
        const inst = inst_opt orelse continue;

        try pumpTenant(worker, tc, inst, now_ns);
    }
}

/// Outcome of one connection's push attempt this tick.
const PushOutcome = enum {
    /// Wrote at least one frame. Move on; the dirty mark is consumed.
    pushed,
    /// Dirty mark fired but the prefix scan came up empty. Clear the
    /// mark — this was either a stale signal or rows already drained
    /// last tick.
    no_rows,
    /// Had rows ready but the events_bytes_out bucket was empty.
    /// Keep the sid dirty so we retry next tick (when the bucket has
    /// refilled).
    backpressured,
};

fn pumpTenant(
    worker: anytype,
    tc: anytype,
    inst: *const @import("rove-tenant").Instance,
    now_ns: i64,
) !void {
    const server = worker.h2;
    const allocator = worker.allocator;
    const limiter: ?*limiter_mod.RateLimiter = &worker.limiter;
    const instance_id = inst.id;

    // Sids that backpressured this tick — kept in dirty_sids after
    // the drain at the bottom so we retry next tick.
    var keep: std.StringHashMapUnmanaged(void) = .empty;
    defer keep.deinit(allocator);

    // Walk connections; for each in stream_data_out, decide what to
    // push. We mutate sse_connections (advancing last_event_id /
    // last_send_ns) but don't add or remove during the walk.
    var i: usize = 0;
    while (i < tc.sse_connections.items.len) : (i += 1) {
        const conn = &tc.sse_connections.items[i];
        if (!server.reg.isInCollection(conn.stream_ent, &server.stream_data_out)) continue;

        const sid_dirty = tc.dirty_sids.contains(&conn.sid);
        if (sid_dirty) {
            const outcome = try pushDirtyEvents(server, allocator, inst, conn, limiter, instance_id, now_ns);
            switch (outcome) {
                .pushed => {
                    conn.last_send_ns = now_ns;
                    continue;
                },
                .backpressured => {
                    // Remember to retain this sid in dirty_sids so we
                    // retry next tick. We can't insert directly while
                    // iterating dirty_sids' keys (we don't), but we
                    // can use a side hashmap.
                    try keep.put(allocator, &conn.sid, {});
                    // Still consider keepalive — wire isn't blocked.
                },
                .no_rows => {
                    // Stale dirty mark; nothing to do, fall through.
                },
            }
        }

        if (now_ns - conn.last_send_ns >= KEEPALIVE_INTERVAL_NS) {
            try writeKeepalive(server, allocator, conn);
            conn.last_send_ns = now_ns;
        }
    }

    // Drain dirty_sids, retaining sids in `keep`. The retained sids
    // need NEW owned allocations because the originals get freed in
    // clearDirtySids.
    try drainDirtyExcept(tc, &keep);
}

fn drainDirtyExcept(tc: anytype, keep: *const std.StringHashMapUnmanaged(void)) !void {
    var to_keep: std.ArrayListUnmanaged([]u8) = .empty;
    defer to_keep.deinit(tc.allocator);

    var it = tc.dirty_sids.iterator();
    while (it.next()) |entry| {
        const sid = entry.key_ptr.*;
        if (keep.contains(sid)) {
            const dup = try tc.allocator.dupe(u8, sid);
            errdefer tc.allocator.free(dup);
            try to_keep.append(tc.allocator, dup);
        }
        tc.allocator.free(sid);
    }
    tc.dirty_sids.clearRetainingCapacity();

    for (to_keep.items) |sid| {
        try tc.dirty_sids.put(tc.allocator, sid, {});
    }
}

// `clearDirtySids` superseded by `drainDirtyExcept` in the pump path.
// Retained as a freestanding helper for tests / callers that want a
// full wipe.
fn clearDirtySids(tc: anytype) void {
    var it = tc.dirty_sids.iterator();
    while (it.next()) |entry| tc.allocator.free(entry.key_ptr.*);
    tc.dirty_sids.clearRetainingCapacity();
}

/// Returns true when at least one wire frame was written and the
/// entity moved into `stream_data_in`. Returns false when the prefix
/// scan came up empty (the entity stays in `stream_data_out`).
fn pushDirtyEvents(
    server: anytype,
    allocator: std.mem.Allocator,
    inst: *const @import("rove-tenant").Instance,
    conn: *SseConnection,
    limiter: ?*limiter_mod.RateLimiter,
    instance_id: []const u8,
    now_ns: i64,
) !PushOutcome {
    var key_buf: [8 + 64 + 1]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &key_buf,
        "_events/{s}/",
        .{conn.sid},
    ) catch unreachable;

    var scan = inst.kv.prefix(prefix, &conn.last_event_id, PUMP_BATCH_LIMIT) catch |err| switch (err) {
        error.NotFound => return .no_rows,
        else => return err,
    };
    defer scan.deinit();
    if (scan.entries.len == 0) return .no_rows;

    // Build a single buffer holding every frame for this tick. h2
    // copies it into its own send buffer when it picks up the
    // RespBody, so we can free our copy before the pump returns.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var last_id: [27]u8 = conn.last_event_id;
    for (scan.entries) |e| {
        // Storage key is `_events/{sid}/{wire_id}`. Wire id is the
        // segment after the second slash.
        const slash2 = std.mem.lastIndexOfScalar(u8, e.key, '/') orelse continue;
        const wire_id_slice = e.key[slash2 + 1 ..];
        if (wire_id_slice.len != 27) continue;

        // formatFrame needs an upper bound; the envelope plus our
        // boilerplate fits in 4 KiB at the per-emit payload cap, but
        // be generous — heap-allocate a per-frame scratch.
        var frame_buf: [16 * 1024]u8 = undefined;
        const frame = formatFrame(&frame_buf, wire_id_slice, e.value) catch continue;
        try out.appendSlice(allocator, frame);
        @memcpy(&last_id, wire_id_slice[0..27]);
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return .no_rows;
    }

    // events_bytes_out rate limit. 1 token = 1 byte. When the bucket
    // can't cover the whole frame buffer, defer this connection to
    // the next tick — caller leaves the sid in dirty_sids so we
    // retry. The buffer is discarded; we'll re-build next tick from
    // a fresh prefix scan (cheap because last_event_id wasn't
    // advanced).
    if (limiter) |lim| {
        const want: u32 = @intCast(out.items.len);
        const allowed = lim.checkN(instance_id, .events_bytes_out, want, now_ns) catch true;
        if (!allowed) {
            out.deinit(allocator);
            return .backpressured;
        }
    }

    const owned = try out.toOwnedSlice(allocator);
    server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
        .data = owned.ptr,
        .len = @intCast(owned.len),
    }) catch |err| {
        allocator.free(owned);
        return err;
    };
    server.reg.move(conn.stream_ent, &server.stream_data_out, &server.stream_data_in) catch |err| {
        allocator.free(owned);
        return err;
    };

    conn.last_event_id = last_id;
    return .pushed;
}

fn writeKeepalive(server: anytype, allocator: std.mem.Allocator, conn: *SseConnection) !void {
    const ping = keepaliveFrame();
    const owned = try allocator.dupe(u8, ping);
    server.reg.set(conn.stream_ent, &server.stream_data_out, h2.RespBody, .{
        .data = owned.ptr,
        .len = @intCast(owned.len),
    }) catch |err| {
        allocator.free(owned);
        return err;
    };
    server.reg.move(conn.stream_ent, &server.stream_data_out, &server.stream_data_in) catch |err| {
        allocator.free(owned);
        return err;
    };
}

/// Scan `response_out` for h2 entities that match SSE connection
/// records and remove them from the per-tenant table. Runs BEFORE
/// `cleanupResponses` so the records are gone by the time h2
/// destroys the entities.
pub fn cleanupClosedSseConnections(worker: anytype) !void {
    const server = worker.h2;
    const closed = server.response_out.entitySlice();
    if (closed.len == 0) return;

    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        if (tc.sse_connections.items.len == 0) continue;
        for (closed) |ent| removeConnectionByEntity(tc, ent);
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "sidFromEventsKey: extracts sid from valid key" {
    const sid_in = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const key = "_events/" ++ sid_in ++ "/00000000000000000001-000000";
    const out = sidFromEventsKey(key).?;
    try testing.expectEqualStrings(sid_in, out);
}

test "sidFromEventsKey: rejects non-_events/ keys" {
    try testing.expect(sidFromEventsKey("users/alice") == null);
    try testing.expect(sidFromEventsKey("_outbox/abc") == null);
    try testing.expect(sidFromEventsKey("") == null);
}

test "sidFromEventsKey: missing slash after sid → null" {
    try testing.expect(sidFromEventsKey("_events/justasid") == null);
}

test "parseLastEventId: valid header → echoed bytes" {
    const v = "00000000000000000042-000007";
    const out = parseLastEventId(v);
    try testing.expectEqualStrings(v, &out);
}

test "parseLastEventId: null / wrong-length / bad chars → zero" {
    try testing.expectEqualStrings(&ZERO_LAST_EVENT_ID, &parseLastEventId(null));
    try testing.expectEqualStrings(&ZERO_LAST_EVENT_ID, &parseLastEventId("toosshort"));
    try testing.expectEqualStrings(&ZERO_LAST_EVENT_ID, &parseLastEventId("0000000000000000004!-000007"));
    try testing.expectEqualStrings(&ZERO_LAST_EVENT_ID, &parseLastEventId("00000000000000000042X000007")); // no dash
}

test "extractJsonField: pulls string value" {
    const env = "{\"v\":1,\"id\":\"abc\",\"type\":\"tick\",\"data\":null}";
    try testing.expectEqualStrings("tick", extractJsonField(env, "\"type\":\"").?);
    try testing.expectEqualStrings("abc", extractJsonField(env, "\"id\":\"").?);
}

test "extractJsonValue: pulls null" {
    const env = "{\"v\":1,\"data\":null}";
    try testing.expectEqualStrings("null", extractJsonValue(env, "\"data\":").?);
}

test "extractJsonValue: pulls object" {
    const env = "{\"data\":{\"count\":7,\"label\":\"foo\"},\"v\":1}";
    try testing.expectEqualStrings("{\"count\":7,\"label\":\"foo\"}", extractJsonValue(env, "\"data\":").?);
}

test "extractJsonValue: pulls string with escapes" {
    const env = "{\"data\":\"hel\\\"lo\",\"v\":1}";
    try testing.expectEqualStrings("\"hel\\\"lo\"", extractJsonValue(env, "\"data\":").?);
}

test "extractJsonValue: pulls number" {
    const env = "{\"v\":1,\"data\":42}";
    try testing.expectEqualStrings("42", extractJsonValue(env, "\"data\":").?);
}

test "formatFrame: id + event + data + blank line" {
    const env = "{\"v\":1,\"id\":\"00000000000000000001-000000\",\"type\":\"tick\",\"data\":{\"x\":1}}";
    var buf: [256]u8 = undefined;
    const out = try formatFrame(&buf, "00000000000000000001-000000", env);
    try testing.expectEqualStrings(
        "id: 00000000000000000001-000000\nevent: tick\ndata: {\"x\":1}\n\n",
        out,
    );
}

test "formatFrame: handles null data" {
    const env = "{\"v\":1,\"id\":\"00000000000000000001-000000\",\"type\":\"message\",\"data\":null}";
    var buf: [256]u8 = undefined;
    const out = try formatFrame(&buf, "00000000000000000001-000000", env);
    try testing.expectEqualStrings(
        "id: 00000000000000000001-000000\nevent: message\ndata: null\n\n",
        out,
    );
}

test "keepaliveFrame: stable bytes" {
    try testing.expectEqualStrings(":ping\n\n", keepaliveFrame());
}

/// Mimics the TenantFiles fields markDirtyFromWriteset reads. Lives
/// inside the test only — production callers pass a real
/// `*TenantFiles`.
const StubTc = struct {
    allocator: std.mem.Allocator,
    sse_connections: std.ArrayListUnmanaged(SseConnection),
    dirty_sids: std.StringHashMapUnmanaged(void),

    fn initTest(allocator: std.mem.Allocator) StubTc {
        return .{
            .allocator = allocator,
            .sse_connections = .empty,
            .dirty_sids = .empty,
        };
    }

    fn deinitTest(self: *StubTc) void {
        self.sse_connections.deinit(self.allocator);
        var it = self.dirty_sids.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.dirty_sids.deinit(self.allocator);
    }
};

test "markDirtyFromWriteset: skips when no connections" {
    const a = testing.allocator;
    var tc = StubTc.initTest(a);
    defer tc.deinitTest();

    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("_events/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/00000000000000000001-000000", "{\"v\":1}");

    try markDirtyFromWriteset(&tc, &ws);
    try testing.expectEqual(@as(usize, 0), tc.dirty_sids.count());
}

test "markDirtyFromWriteset: marks sid that has a connection" {
    const a = testing.allocator;
    var tc = StubTc.initTest(a);
    defer tc.deinitTest();

    const sid: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    try tc.sse_connections.append(a, SseConnection.newAt(rove.Entity{ .index = 1, .generation = 1 }, sid, ZERO_LAST_EVENT_ID, 0));

    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("_events/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/00000000000000000001-000000", "{\"v\":1}");

    try markDirtyFromWriteset(&tc, &ws);
    try testing.expectEqual(@as(usize, 1), tc.dirty_sids.count());
    try testing.expect(tc.dirty_sids.contains(&sid));
}

test "markDirtyFromWriteset: ignores non-_events ops" {
    const a = testing.allocator;
    var tc = StubTc.initTest(a);
    defer tc.deinitTest();

    const sid: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    try tc.sse_connections.append(a, SseConnection.newAt(rove.Entity{ .index = 1, .generation = 1 }, sid, ZERO_LAST_EVENT_ID, 0));

    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("users/alice", "v");
    try ws.addPut("orders/123", "v");

    try markDirtyFromWriteset(&tc, &ws);
    try testing.expectEqual(@as(usize, 0), tc.dirty_sids.count());
}

test "markDirtyFromWriteset: ignores _events/ for sids with no connection" {
    const a = testing.allocator;
    var tc = StubTc.initTest(a);
    defer tc.deinitTest();

    const sid_have: [64]u8 = "1111111111111111111111111111111111111111111111111111111111111111".*;
    try tc.sse_connections.append(a, SseConnection.newAt(rove.Entity{ .index = 1, .generation = 1 }, sid_have, ZERO_LAST_EVENT_ID, 0));

    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    // Emit aimed at a different sid (no listener) — should NOT mark.
    try ws.addPut("_events/2222222222222222222222222222222222222222222222222222222222222222/00000000000000000001-000000", "{\"v\":1}");

    try markDirtyFromWriteset(&tc, &ws);
    try testing.expectEqual(@as(usize, 0), tc.dirty_sids.count());
}

test "markDirtyFromWriteset: dedupes across multiple ops to same sid" {
    const a = testing.allocator;
    var tc = StubTc.initTest(a);
    defer tc.deinitTest();

    const sid: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    try tc.sse_connections.append(a, SseConnection.newAt(rove.Entity{ .index = 1, .generation = 1 }, sid, ZERO_LAST_EVENT_ID, 0));

    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("_events/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/00000000000000000001-000000", "{}");
    try ws.addPut("_events/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/00000000000000000001-000001", "{}");
    try ws.addPut("_events/abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789/00000000000000000001-000002", "{}");

    try markDirtyFromWriteset(&tc, &ws);
    try testing.expectEqual(@as(usize, 1), tc.dirty_sids.count());
}

test "addConnection / removeConnectionByEntity / countConnectionsForSid" {
    const a = testing.allocator;
    var tc = StubTc.initTest(a);
    defer tc.deinitTest();

    const sid_a: [64]u8 = "1111111111111111111111111111111111111111111111111111111111111111".*;
    const sid_b: [64]u8 = "2222222222222222222222222222222222222222222222222222222222222222".*;

    const ent1 = rove.Entity{ .index = 1, .generation = 1 };
    const ent2 = rove.Entity{ .index = 2, .generation = 1 };
    const ent3 = rove.Entity{ .index = 3, .generation = 1 };

    try addConnection(&tc, SseConnection.newAt(ent1, sid_a, ZERO_LAST_EVENT_ID, 0));
    try addConnection(&tc, SseConnection.newAt(ent2, sid_a, ZERO_LAST_EVENT_ID, 0));
    try addConnection(&tc, SseConnection.newAt(ent3, sid_b, ZERO_LAST_EVENT_ID, 0));

    try testing.expectEqual(@as(u32, 3), countConnections(&tc));
    try testing.expectEqual(@as(u32, 2), countConnectionsForSid(&tc, &sid_a));
    try testing.expectEqual(@as(u32, 1), countConnectionsForSid(&tc, &sid_b));

    removeConnectionByEntity(&tc, ent1);
    try testing.expectEqual(@as(u32, 2), countConnections(&tc));
    try testing.expectEqual(@as(u32, 1), countConnectionsForSid(&tc, &sid_a));

    // Removing an entity that isn't there is a no-op.
    removeConnectionByEntity(&tc, ent1);
    try testing.expectEqual(@as(u32, 2), countConnections(&tc));
}
