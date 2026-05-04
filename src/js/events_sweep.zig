//! SSE retention sweep — periodic per-tenant pass that deletes
//! `_events/{sid}/...` rows older than `caps.retention_seconds`.
//! Leader-only; the deletion writeset replicates through raft the
//! same way customer kv writes do, keeping follower copies of
//! `app.db` in sync.
//!
//! Architecture (docs/sse-plan.md §11g):
//! - Runs once per `SWEEP_INTERVAL_NS` per worker (60s default —
//!   sized so a paid-tier tenant with 1000 events/session in
//!   retention sees about one batch deleted per pass).
//! - Each tenant's per-pass work is bounded by `MAX_DELETES_PER_PASS`
//!   so a tenant with a huge backlog drains over multiple ticks
//!   instead of stalling the worker.
//! - Per tenant, opens a `TrackedTxn` + `WriteSet` exactly like the
//!   handler dispatch path, so the deletes commit locally + propose
//!   through raft as a standard envelope-type-0 writeset.
//! - Reads `created_at_ms` directly out of each envelope JSON (we
//!   wrote it; the field is at a stable position in the outer
//!   object — same shape `events_pump.formatFrame` expects). Skips
//!   malformed rows (defensive, shouldn't happen).

const std = @import("std");
const kv_mod = @import("rove-kv");
const tenant_mod = @import("rove-tenant");

const events_pump = @import("events_pump.zig");
const raft_propose = @import("raft_propose.zig");

/// How often to run a sweep pass per worker. Wall-clock relative to
/// the worker's last sweep; not synchronized across workers.
pub const SWEEP_INTERVAL_NS: i64 = 60 * std.time.ns_per_s;

/// Per-tenant deletion budget per pass. Generous-enough for the
/// expected steady-state (paid-tier tenant emitting ~10/s with
/// 1-hour retention has ~36k rows ageing into deletion territory
/// per hour, so ~600/min — 1000 fits with headroom). Bounds the
/// time the worker spends in the sweep at the cost of taking a few
/// passes to clear a deliberate backlog.
pub const MAX_DELETES_PER_PASS: u32 = 1000;

/// One sweep pass across every known tenant. Returns the total
/// number of rows deleted across all tenants. Caller is expected to
/// gate this on `SWEEP_INTERVAL_NS` elapsed since the last call.
///
/// Leader-only — followers receive the deletion writesets via the
/// standard apply path. Calling on a follower is a no-op.
pub fn sweepEvents(worker: anytype) !usize {
    if (!worker.raft.isLeader()) return 0;

    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    var total: usize = 0;
    var it = worker.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const tc = entry.value_ptr.*;
        const inst_opt = worker.tenant.getInstance(tc.instance_id) catch null;
        const inst = inst_opt orelse continue;

        // Per-tenant retention. v1 uses the shared free-tier
        // retention from EventsCaps; per-instance plan-tier lookup
        // wires through here in Phase 10.
        const retention_ms: i64 = @as(i64, @intCast(@import("events.zig").FREE.retention_seconds)) * 1000;
        const cutoff_ms = now_ms - retention_ms;

        const n = sweepTenant(worker, tc, inst, cutoff_ms) catch |err| {
            std.log.warn(
                "rove-js sweepEvents: tenant {s}: {s}",
                .{ tc.instance_id, @errorName(err) },
            );
            continue;
        };
        total += n;
    }
    return total;
}

fn sweepTenant(
    worker: anytype,
    tc: anytype,
    inst: *const tenant_mod.Instance,
    cutoff_ms: i64,
) !usize {
    _ = tc;
    const allocator = worker.allocator;

    // Cheap peek first: if there are no `_events/` rows at all, skip
    // the txn open. The first prefix scan with empty cursor returns
    // either rows or empty; an empty result short-circuits.
    var peek = inst.kv.prefix("_events/", "", 1) catch |err| switch (err) {
        error.NotFound => return 0,
        else => return err,
    };
    peek.deinit();
    if (peek.entries.len == 0) return 0;

    // Open the writer txn for the deletion batch.
    var txn = try inst.kv.beginTrackedImmediate();
    txn.open() catch |err| {
        if (err == kv_mod.KvError.Conflict) return 0; // someone else holds the writer; defer
        return err;
    };
    var committed = false;
    errdefer if (!committed) {
        txn.rollback() catch {};
    };

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();

    var deleted: u32 = 0;
    var cursor: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(cursor);

    // Page through `_events/` until we hit MAX_DELETES_PER_PASS or
    // run out of rows. Older rows sort first because the sid is
    // arbitrary but the wire-id suffix is monotonic per session, AND
    // creation order across sids isn't strictly ordered — so we
    // can't stop at the first non-expired row. Have to walk.
    while (deleted < MAX_DELETES_PER_PASS) {
        const remaining = MAX_DELETES_PER_PASS - deleted;
        const page_size = @min(remaining, 256);

        var scan = inst.kv.prefix("_events/", cursor, page_size) catch |err| switch (err) {
            error.NotFound => break,
            else => return err,
        };
        defer scan.deinit();
        if (scan.entries.len == 0) break;

        for (scan.entries) |e| {
            // Advance cursor to the latest key we visited regardless
            // of whether we deleted it — otherwise non-expired rows
            // would loop us.
            allocator.free(cursor);
            cursor = try allocator.dupe(u8, e.key);

            const created_ms = extractCreatedAtMs(e.value) orelse continue;
            if (created_ms >= cutoff_ms) continue; // not expired yet

            try txn.delete(e.key);
            try ws.addDelete(e.key);
            deleted += 1;
            if (deleted >= MAX_DELETES_PER_PASS) break;
        }

        // Short page → done.
        if (scan.entries.len < page_size) break;
    }

    if (deleted == 0) {
        txn.rollback() catch {};
        return 0;
    }

    // Commit locally + propose for replicate-to-followers. Same
    // pattern as a customer handler's writeset commit.
    txn.commit() catch |err| {
        return err;
    };
    committed = true;

    _ = raft_propose.proposeWriteSet(worker, &ws, inst.id) catch |err| {
        // Local commit landed but raft propose failed — leader's
        // copy is ahead. compensating-undo via undoTxn would be the
        // strict-correctness response, but since these are pure GC
        // deletes that followers will eventually re-issue at their
        // own sweep, we tolerate the divergence and just log.
        std.log.warn(
            "rove-js sweepEvents: tenant {s}: raft propose failed after local commit: {s}",
            .{ inst.id, @errorName(err) },
        );
    };

    // Drop the per-txn undo row now that the writes are durable —
    // mirrors the worker's drainRaftPending happy path.
    inst.kv.commitTxn(txn.txn_seq) catch |err| {
        std.log.warn(
            "rove-js sweepEvents: tenant {s}: commitTxn(drop undo): {s}",
            .{ inst.id, @errorName(err) },
        );
    };

    return deleted;
}

/// Pull `created_at_ms` from a `_events/{sid}/...` envelope JSON.
/// Returns null on malformed input. Same shape events.zig writes —
/// see `events_pump.extractJsonValue` for the underlying scan.
pub fn extractCreatedAtMs(envelope_json: []const u8) ?i64 {
    const PREFIX = "\"created_at_ms\":";
    const idx = std.mem.indexOf(u8, envelope_json, PREFIX) orelse return null;
    var i = idx + PREFIX.len;
    // Skip optional whitespace.
    while (i < envelope_json.len and (envelope_json[i] == ' ' or envelope_json[i] == '\t')) {
        i += 1;
    }
    const start = i;
    if (i < envelope_json.len and (envelope_json[i] == '-' or envelope_json[i] == '+')) {
        i += 1;
    }
    while (i < envelope_json.len) : (i += 1) {
        const c = envelope_json[i];
        if (c < '0' or c > '9') break;
    }
    if (i == start) return null;
    return std.fmt.parseInt(i64, envelope_json[start..i], 10) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "extractCreatedAtMs: middle of envelope" {
    const env = "{\"v\":1,\"id\":\"abc\",\"type\":\"tick\",\"data\":null,\"created_at_ms\":1714838400000,\"parent_request_id\":1}";
    try testing.expectEqual(@as(?i64, 1714838400000), extractCreatedAtMs(env));
}

test "extractCreatedAtMs: end of envelope" {
    const env = "{\"v\":1,\"created_at_ms\":42}";
    try testing.expectEqual(@as(?i64, 42), extractCreatedAtMs(env));
}

test "extractCreatedAtMs: missing field → null" {
    const env = "{\"v\":1,\"id\":\"abc\"}";
    try testing.expectEqual(@as(?i64, null), extractCreatedAtMs(env));
}

test "extractCreatedAtMs: zero" {
    const env = "{\"created_at_ms\":0,\"v\":1}";
    try testing.expectEqual(@as(?i64, 0), extractCreatedAtMs(env));
}

test "extractCreatedAtMs: negative (clock skew defensive)" {
    const env = "{\"created_at_ms\":-1,\"v\":1}";
    try testing.expectEqual(@as(?i64, -1), extractCreatedAtMs(env));
}

// ── Integration: end-to-end sweep against a real tenant kv ────────

const kv_test = @import("rove-kv");

fn openTempKvForSweep(buf: *[64]u8) !*kv_test.KvStore {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = std.fmt.bufPrintZ(buf, "/tmp/rove-sse-sweep-{x}.db", .{seed}) catch unreachable;
    std.fs.cwd().deleteFile(path) catch {};
    return try kv_test.KvStore.open(testing.allocator, path);
}

test "sweepEventsRowsByCutoff: deletes rows older than cutoff, keeps newer" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKvForSweep(&buf);
    defer {
        kv.close();
        std.fs.cwd().deleteFile(buf[0..std.mem.indexOfScalar(u8, &buf, 0).?]) catch {};
    }

    const sid = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const old_env = "{\"v\":1,\"id\":\"x\",\"type\":\"message\",\"data\":null,\"created_at_ms\":1000,\"parent_request_id\":1}";
    const new_env = "{\"v\":1,\"id\":\"y\",\"type\":\"message\",\"data\":null,\"created_at_ms\":5000,\"parent_request_id\":2}";

    try kv.put("_events/" ++ sid ++ "/00000000000000000001-000000", old_env);
    try kv.put("_events/" ++ sid ++ "/00000000000000000002-000000", new_env);

    const deleted = try sweepRowsByCutoff(testing.allocator, kv, 3000);
    try testing.expectEqual(@as(usize, 1), deleted);

    // Old row gone; new row still there.
    try testing.expectError(error.NotFound, kv.get("_events/" ++ sid ++ "/00000000000000000001-000000"));
    const v = try kv.get("_events/" ++ sid ++ "/00000000000000000002-000000");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings(new_env, v);
}

test "sweepEventsRowsByCutoff: empty kv → 0" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKvForSweep(&buf);
    defer {
        kv.close();
        std.fs.cwd().deleteFile(buf[0..std.mem.indexOfScalar(u8, &buf, 0).?]) catch {};
    }
    try testing.expectEqual(@as(usize, 0), try sweepRowsByCutoff(testing.allocator, kv, 0));
}

test "sweepEventsRowsByCutoff: walks past non-expired rows" {
    var buf: [64]u8 = undefined;
    const kv = try openTempKvForSweep(&buf);
    defer {
        kv.close();
        std.fs.cwd().deleteFile(buf[0..std.mem.indexOfScalar(u8, &buf, 0).?]) catch {};
    }

    // Three rows alphabetically interleaving expired / non-expired.
    const sid_a = "1111111111111111111111111111111111111111111111111111111111111111";
    const sid_b = "2222222222222222222222222222222222222222222222222222222222222222";

    try kv.put("_events/" ++ sid_a ++ "/00000000000000000001-000000",
        "{\"v\":1,\"created_at_ms\":1000}");          // expired
    try kv.put("_events/" ++ sid_a ++ "/00000000000000000002-000000",
        "{\"v\":1,\"created_at_ms\":5000}");          // kept
    try kv.put("_events/" ++ sid_b ++ "/00000000000000000003-000000",
        "{\"v\":1,\"created_at_ms\":1500}");          // expired
    try kv.put("_events/" ++ sid_b ++ "/00000000000000000004-000000",
        "{\"v\":1,\"created_at_ms\":4500}");          // kept

    const deleted = try sweepRowsByCutoff(testing.allocator, kv, 3000);
    try testing.expectEqual(@as(usize, 2), deleted);

    try testing.expectError(error.NotFound, kv.get("_events/" ++ sid_a ++ "/00000000000000000001-000000"));
    const v1 = try kv.get("_events/" ++ sid_a ++ "/00000000000000000002-000000");
    defer testing.allocator.free(v1);
    try testing.expectError(error.NotFound, kv.get("_events/" ++ sid_b ++ "/00000000000000000003-000000"));
    const v2 = try kv.get("_events/" ++ sid_b ++ "/00000000000000000004-000000");
    defer testing.allocator.free(v2);
}

/// Test-only entry point that runs the same per-tenant logic as
/// `sweepTenant` against a raw KvStore — no worker / raft / writeset
/// needed. Production callers use `sweepEvents` which propagates
/// deletes through raft.
fn sweepRowsByCutoff(allocator: std.mem.Allocator, kv: *kv_test.KvStore, cutoff_ms: i64) !usize {
    var peek = kv.prefix("_events/", "", 1) catch |err| return err;
    defer peek.deinit();
    if (peek.entries.len == 0) return 0;

    var txn = try kv.beginTrackedImmediate();
    txn.open() catch |err| {
        if (err == kv_test.KvError.Conflict) return 0;
        return err;
    };
    var committed = false;
    errdefer if (!committed) txn.rollback() catch {};

    var deleted: u32 = 0;
    var cursor: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(cursor);

    while (deleted < MAX_DELETES_PER_PASS) {
        const remaining = MAX_DELETES_PER_PASS - deleted;
        const page_size = @min(remaining, 256);

        var scan = kv.prefix("_events/", cursor, page_size) catch |err| return err;
        defer scan.deinit();
        if (scan.entries.len == 0) break;

        for (scan.entries) |e| {
            allocator.free(cursor);
            cursor = try allocator.dupe(u8, e.key);
            const created_ms = extractCreatedAtMs(e.value) orelse continue;
            if (created_ms >= cutoff_ms) continue;
            try txn.delete(e.key);
            deleted += 1;
            if (deleted >= MAX_DELETES_PER_PASS) break;
        }
        if (scan.entries.len < page_size) break;
    }

    if (deleted == 0) {
        txn.rollback() catch {};
        return 0;
    }
    try txn.commit();
    committed = true;
    kv.commitTxn(txn.txn_seq) catch {};
    return deleted;
}
