// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The storage half of request-record retention: delete every request-log
//! batch (`_logs/`) and spilled body (`_pool/`) older than `PURGE_AGE_NS`,
//! and prune this log-server's index rows for the records they held.
//!
//! What a customer can READ is bounded by their plan's window — the read
//! clamp in the query surface. What we KEEP is bounded here: one age for
//! every tenant, because the objects are shared across tenants and a
//! fleet-wide age is the one rule that never deletes a record some tenant's
//! window still shows (no window exceeds it). Erasing ONE tenant or one
//! identity before that age is key destruction, not this.
//!
//! ## Why a walk this cheap is sound
//!
//! The two families live in different stores — `_logs/` under the log
//! prefix, `_pool/` under the content prefix the body route reads — so the
//! pass takes both.
//!
//! Both families lead their keys with time — `_logs/{node}/{flush_ns:020}-…`
//! and `_pool/{written_ms:0>13}-…` — so a LIST from the start of a prefix
//! yields objects oldest-first and the pass stops at the first one young
//! enough to keep. It costs about what it deletes, with no cursor to
//! persist: the previous pass already removed everything before where this
//! one starts.
//!
//! ## Fences
//!
//! - **Never ahead of the indexer.** A `_logs/` batch above this server's
//!   persisted cursor for its node has not been indexed here; it is left for
//!   a later pass (or a server that has caught up). A node with no cursor
//!   here is skipped entirely.
//! - **Rows before objects.** The index is pruned first, by RECEIVE time,
//!   and objects go by flush or write time, which is never earlier, so no
//!   surviving row ever names a deleted object.
//! - **Idempotent.** Every log-server runs the pass over the same shared
//!   store; deleting an object another server already deleted is a no-op.

const std = @import("std");
const batch_store_mod = @import("batch_store.zig");
const index_db_mod = @import("index_db.zig");
const indexer = @import("indexer.zig");
const plan_mod = @import("rove-plan");

/// How long request records are kept: the longest plan window, after which
/// every record of every tenant is gone. The published retention period.
pub const PURGE_AGE_NS: i64 = @as(i64, plan_mod.MAX_RETENTION_DAYS) * std.time.ns_per_day;

/// How often a log-server runs the pass. The published period is "deleted
/// within a day after `PURGE_AGE_NS`".
pub const PURGE_INTERVAL_NS: i64 = std.time.ns_per_day;

const LOGS_PREFIX = "_logs/";
const POOL_PREFIX = "_pool/";
const PAGE: u32 = 1000;

pub const Stats = struct {
    rows_pruned: u64 = 0,
    batches_deleted: u64 = 0,
    pool_deleted: u64 = 0,
    /// `_logs/` batches old enough to delete but left in place because they
    /// sit above this server's indexer cursor for their node.
    fenced: u64 = 0,
};

pub const Error = error{ BatchStore, Sqlite, OutOfMemory };

/// One pass at `now_ns`, deleting what is older than `age_ns`. Production
/// passes `PURGE_AGE_NS`; tests pass a shorter age.
pub fn purgeOnce(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    pool_store: ?batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    now_ns: i64,
    age_ns: i64,
) Error!Stats {
    var stats: Stats = .{};
    const cutoff_ns = now_ns - age_ns;
    if (cutoff_ns <= 0) return stats;

    stats.rows_pruned = db.pruneBefore(cutoff_ns) catch return Error.Sqlite;

    const nodes = indexer.listNodePrefixes(allocator, store) catch return Error.BatchStore;
    defer batch_store_mod.freeListResult(allocator, nodes);
    for (nodes) |node_prefix| try purgeNode(allocator, store, db, node_prefix, cutoff_ns, &stats);

    if (pool_store) |ps| {
        const cutoff_ms = @divTrunc(cutoff_ns, std.time.ns_per_ms);
        try sweep(allocator, ps, POOL_PREFIX, cutoff_ms, poolStampMs, null, &stats.pool_deleted, &stats.fenced);
    }
    return stats;
}

fn purgeNode(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    node_prefix: []const u8,
    cutoff_ns: i64,
    stats: *Stats,
) Error!void {
    const meta_key = indexer.cursorMetaKey(allocator, node_prefix) catch return Error.OutOfMemory;
    defer allocator.free(meta_key);
    const cursor = (db.getMeta(meta_key) catch return Error.Sqlite) orelse return;
    defer allocator.free(cursor);
    try sweep(allocator, store, node_prefix, cutoff_ns, batchFlushNs, cursor, &stats.batches_deleted, &stats.fenced);
}

/// Delete keys under `prefix`, oldest first, while their stamp is below
/// `cutoff`. Stops at the first key that is young enough to keep, or (with
/// a `fence`) the first key above it. A key whose stamp can't be read is
/// left alone — it isn't one of ours to judge.
fn sweep(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    prefix: []const u8,
    cutoff: i64,
    stampOf: *const fn (prefix: []const u8, key: []const u8) ?i64,
    fence: ?[]const u8,
    deleted: *u64,
    fenced: *u64,
) Error!void {
    var after = allocator.dupe(u8, "") catch return Error.OutOfMemory;
    defer allocator.free(after);
    while (true) {
        const keys = store.list(prefix, after, PAGE, allocator) catch return Error.BatchStore;
        defer batch_store_mod.freeListResult(allocator, keys);
        if (keys.len == 0) return;
        for (keys) |key| {
            const stamp = stampOf(prefix, key) orelse continue;
            if (stamp >= cutoff) return;
            if (fence) |f| if (std.mem.order(u8, key, f) == .gt) {
                fenced.* += 1;
                return;
            };
            store.delete(key) catch return Error.BatchStore;
            deleted.* += 1;
        }
        allocator.free(after);
        after = allocator.dupe(u8, keys[keys.len - 1]) catch return Error.OutOfMemory;
    }
}

/// `_logs/{node}/{flush_ns:020}-{first_req:020}.ndjson` → flush_ns.
fn batchFlushNs(node_prefix: []const u8, key: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, key, node_prefix)) return null;
    const rest = key[node_prefix.len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    return std.fmt.parseInt(i64, rest[0..dash], 10) catch null;
}

/// `_pool/{written_ms:0>13}-{digest}` → written_ms.
fn poolStampMs(prefix: []const u8, key: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const rest = key[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    return std.fmt.parseInt(i64, rest[0..dash], 10) catch null;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sidecar = @import("sidecar.zig");

const NODE = "_logs/00000001/";
const DAY = std.time.ns_per_day;

fn rec(id: u64, ns: i64) sidecar.Record {
    return .{
        .tenant_id = "acme",
        .request_id = id,
        .received_ns = ns,
        .duration_ns = 1,
        .method = "GET",
        .path = "/",
        .host = "h",
        .status = 200,
        .outcome = "ok",
        .deployment_id = 1,
        .saga_id = "S",
        .offset = 0,
        .length = 1,
    };
}

/// One batch flushed at `flush_ns` holding one record received at the same
/// instant: the object in the store and its row in the index.
fn putBatch(store: batch_store_mod.BatchStore, idx: *index_db_mod.IndexDb, id: u64, flush_ns: i64) !void {
    var bid_buf: [64]u8 = undefined;
    const bid = try std.fmt.bufPrint(&bid_buf, "{d:0>20}-{d:0>20}", .{ @as(u64, @intCast(flush_ns)), id });
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, NODE ++ "{s}.ndjson", .{bid});
    try store.put(key, "x");
    var recs = [_]sidecar.Record{rec(id, flush_ns)};
    const b = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = bid,
        .ndjson_size = 1,
        .ndjson_sha256 = "d",
        .first_received_ns = flush_ns,
        .last_received_ns = flush_ns,
        .records = &recs,
    };
    try idx.insertBatch(&b, key, 0);
}

fn putPool(store: batch_store_mod.BatchStore, written_ns: i64) !void {
    var key_buf: [96]u8 = undefined;
    const ms: u64 = @intCast(@divTrunc(written_ns, std.time.ns_per_ms));
    const key = try std.fmt.bufPrint(&key_buf, "_pool/{d:0>13}-aaaa", .{ms});
    try store.put(key, "b");
}

fn count(store: batch_store_mod.BatchStore, prefix: []const u8) !usize {
    const keys = try store.list(prefix, "", 1000, testing.allocator);
    defer batch_store_mod.freeListResult(testing.allocator, keys);
    return keys.len;
}

fn openIdx(tag: []const u8) !struct { idx: *index_db_mod.IndexDb, path: [:0]u8 } {
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/rove-purge-{s}-{x}.db", .{ tag, std.crypto.random.int(u64) }, 0);
    return .{ .idx = try index_db_mod.IndexDb.open(testing.allocator, path), .path = path };
}

fn closeIdx(o: anytype) void {
    o.idx.close();
    std.fs.cwd().deleteFile(o.path) catch {};
    inline for (.{ "-wal", "-shm" }) |sfx| {
        var buf: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ o.path, sfx }) catch unreachable;
        std.fs.cwd().deleteFile(p) catch {};
    }
    testing.allocator.free(o.path);
}

test "purge deletes what is past the age, keeps the rest, and prunes the index first" {
    const mem = try batch_store_mod.MemoryBatchStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.batchStore();
    const o = try openIdx("age");
    defer closeIdx(o);

    const now: i64 = 1000 * DAY;
    try putBatch(store, o.idx, 1, now - 400 * DAY); // past 365 days
    try putBatch(store, o.idx, 2, now - 366 * DAY); // past
    try putBatch(store, o.idx, 3, now - 364 * DAY); // kept
    try putBatch(store, o.idx, 4, now - 1 * DAY); // kept
    try putPool(store, now - 370 * DAY);
    try putPool(store, now - 10 * DAY);
    // The indexer is caught up: its cursor is past every batch.
    try o.idx.setMeta("cursor:" ++ NODE, NODE ++ "99999999999999999999-");

    const s = try purgeOnce(testing.allocator, store, store, o.idx, now, PURGE_AGE_NS);
    try testing.expectEqual(@as(u64, 2), s.batches_deleted);
    try testing.expectEqual(@as(u64, 1), s.pool_deleted);
    try testing.expectEqual(@as(u64, 2), s.rows_pruned);
    try testing.expectEqual(@as(usize, 2), try count(store, NODE));
    try testing.expectEqual(@as(usize, 1), try count(store, "_pool/"));
    // Only the kept records are still indexed.
    try testing.expectEqual(@as(u64, 2), try o.idx.queryCount("acme", 0));

    // A second pass finds nothing left to do.
    const again = try purgeOnce(testing.allocator, store, store, o.idx, now, PURGE_AGE_NS);
    try testing.expectEqual(@as(u64, 0), again.batches_deleted + again.pool_deleted + again.rows_pruned);
}

test "purge never deletes a batch this server has not indexed" {
    const mem = try batch_store_mod.MemoryBatchStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.batchStore();
    const o = try openIdx("fence");
    defer closeIdx(o);

    const now: i64 = 1000 * DAY;
    try putBatch(store, o.idx, 1, now - 400 * DAY);
    try putBatch(store, o.idx, 2, now - 390 * DAY);

    // No cursor for the node: this server has not caught up, so nothing of
    // that node's is touched.
    var s = try purgeOnce(testing.allocator, store, store, o.idx, now, PURGE_AGE_NS);
    try testing.expectEqual(@as(u64, 0), s.batches_deleted);
    try testing.expectEqual(@as(usize, 2), try count(store, NODE));

    // A cursor between the two: the older goes, the newer is fenced.
    var cbuf: [96]u8 = undefined;
    const cur = try std.fmt.bufPrint(&cbuf, NODE ++ "{d:0>20}-", .{@as(u64, @intCast(now - 395 * DAY))});
    try o.idx.setMeta("cursor:" ++ NODE, cur);
    s = try purgeOnce(testing.allocator, store, store, o.idx, now, PURGE_AGE_NS);
    try testing.expectEqual(@as(u64, 1), s.batches_deleted);
    try testing.expectEqual(@as(u64, 1), s.fenced);
    try testing.expectEqual(@as(usize, 1), try count(store, NODE));
}

test "purge leaves alone a key whose stamp it cannot read" {
    const mem = try batch_store_mod.MemoryBatchStore.init(testing.allocator);
    defer mem.deinit();
    const store = mem.batchStore();
    const o = try openIdx("odd");
    defer closeIdx(o);
    try store.put("_pool/not-a-stamp", "b");
    _ = try purgeOnce(testing.allocator, store, store, o.idx, 1000 * DAY, PURGE_AGE_NS);
    try testing.expectEqual(@as(usize, 1), try count(store, "_pool/"));
}
