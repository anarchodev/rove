//! Indexer — polling loop that walks the batch store for `.idx.json`
//! sidecars and inserts them into `log_index.db` (Phase 5.5 a).
//!
//! Each pass:
//!   1. LIST every sidecar in the batch store (no cursor — see below).
//!   2. For each sidecar key, GET → parse → `index_db.insertBatch`.
//!      Both `batches` and `log_index` insert with `OR IGNORE`, so
//!      already-indexed sidecars cost a PK lookup and skip writes.
//!   3. `_meta.last_seen_key` is updated for observability + future
//!      cursor-based optimization, but isn't consulted on read.
//!
//! ## Why a full scan instead of `--start-after` cursor
//!
//! `docs/logs-plan.md` §4.3 sketches an `S3 LIST --start-after last`
//! optimization. That works only when keys arrive in lex-monotonic
//! order; it breaks when a NEW tenant whose id sorts lex-earlier
//! than the current cursor first writes a sidecar — the cursor would
//! leapfrog past their first batch and never come back. Step 2 keeps
//! the simpler full-scan approach (cost is `O(total sidecars)` per
//! pass, dominated by the S3 LIST). The cursor optimization with
//! per-`(tenant, node)` book-keeping is a v2 refinement.
//!
//! Two surfaces:
//!   - `pollOnce` runs a single pass and returns. Useful for tests
//!     and for the HTTP query path's "wait until indexed" helper.
//!   - `Handle` (via `spawn`) runs the loop in its own thread until
//!     `signalStop` flips the atomic.
//!
//! No graceful "drain" beyond a single pass — the loop sleeps on the
//! poll interval and wakes for the stop check.

const std = @import("std");
const batch_store_mod = @import("batch_store.zig");
const index_db_mod = @import("index_db.zig");
const sidecar = @import("sidecar.zig");

const SIDECAR_SUFFIX: []const u8 = ".idx.json";

pub const Error = error{
    Sqlite,
    InvalidSidecar,
    BatchStore,
    OutOfMemory,
};

pub const Stats = struct {
    sidecars_seen: u32 = 0,
    batches_indexed: u32 = 0,
    records_indexed: u32 = 0,
    skipped_non_sidecars: u32 = 0,
    skipped_invalid: u32 = 0,
};

/// One polling pass. Returns counts so callers (and tests) can assert
/// what was indexed. Walks the entire batch store every pass; dedup
/// is handled by `INSERT OR IGNORE` in `index_db.insertBatch`.
pub fn pollOnce(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    page_size: u32,
) Error!Stats {
    var stats: Stats = .{};

    // Page through everything strictly greater than the previous
    // page's last key. Within a single pass this is monotonic (keys
    // already exist), so the cursor-based pagination IS safe — only
    // ACROSS passes does using a cursor break under interleaved
    // tenant arrivals (see module doc). Per pass we always start at
    // `""` so newly-arrived sidecars whose keys sort earlier than
    // anything indexed get picked up too.
    var cursor_owned = try allocator.dupe(u8, "");
    defer allocator.free(cursor_owned);

    while (true) {
        const keys = store.list("", cursor_owned, page_size, allocator) catch
            return Error.BatchStore;
        defer batch_store_mod.freeListResult(allocator, keys);
        if (keys.len == 0) break;

        for (keys) |key| {
            if (!std.mem.endsWith(u8, key, SIDECAR_SUFFIX)) {
                stats.skipped_non_sidecars += 1;
                continue;
            }
            stats.sidecars_seen += 1;

            const bytes = store.get(key, allocator) catch |err| {
                std.log.warn("log-indexer: GET {s}: {s}", .{ key, @errorName(err) });
                stats.skipped_invalid += 1;
                continue;
            };
            defer allocator.free(bytes);

            var idx = sidecar.parse(allocator, bytes) catch |err| {
                std.log.warn("log-indexer: parse {s}: {s}", .{ key, @errorName(err) });
                stats.skipped_invalid += 1;
                continue;
            };
            defer idx.deinit(allocator);

            db.insertBatch(&idx, key) catch |err| {
                std.log.warn("log-indexer: insert {s}: {s}", .{ key, @errorName(err) });
                return Error.Sqlite;
            };
            stats.batches_indexed += 1;
            stats.records_indexed += @intCast(idx.records.len);
        }

        // Advance the in-pass cursor to keep paginating; resets on
        // the next pollOnce invocation.
        const last_key = keys[keys.len - 1];
        const new_cursor = try allocator.dupe(u8, last_key);
        allocator.free(cursor_owned);
        cursor_owned = new_cursor;

        // Short page → no more keys; stop.
        if (keys.len < page_size) break;
    }

    return stats;
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    /// How long to sleep between passes when there's nothing to do.
    /// Per `docs/logs-plan.md` §4.3 the default cadence is 5s; tests
    /// override to something smaller so they finish quickly.
    poll_interval_ms: u32 = 5_000,
    page_size: u32 = 256,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    config: Config,
    /// Atomically updated after each pass so callers (esp. tests +
    /// smokes) can wait until indexed-state catches up to a known
    /// cursor without polling SQLite directly.
    passes_completed: std.atomic.Value(u32),

    pub fn signalStop(self: *Handle) void {
        self.stop_flag.store(true, .release);
    }

    pub fn join(self: *Handle) void {
        self.thread.join();
        self.allocator.destroy(self);
    }

    pub fn passesCompleted(self: *Handle) u32 {
        return self.passes_completed.load(.acquire);
    }
};

pub fn spawn(config: Config) !*Handle {
    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .stop_flag = .init(false),
        .config = config,
        .passes_completed = .init(0),
    };
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    return h;
}

fn threadMain(h: *Handle) void {
    runLoop(h) catch |err| {
        std.log.err("log-indexer: thread exited: {s}", .{@errorName(err)});
    };
}

fn runLoop(h: *Handle) !void {
    std.log.info("log-indexer: started", .{});
    while (!h.stop_flag.load(.acquire)) {
        _ = pollOnce(h.config.allocator, h.config.store, h.config.db, h.config.page_size) catch |err| {
            std.log.warn("log-indexer: pass error: {s}", .{@errorName(err)});
        };
        _ = h.passes_completed.fetchAdd(1, .release);
        std.Thread.sleep(@as(u64, h.config.poll_interval_ms) * std.time.ns_per_ms);
    }
    std.log.info("log-indexer: stopped", .{});
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tempDir(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrint(allocator, "/tmp/rove-idxer-{s}-{x}", .{ tag, seed });
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    return path;
}

fn writeSidecar(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    tenant: []const u8,
    node: []const u8,
    batch_id: []const u8,
    records: []sidecar.Record,
) !void {
    const ndjson_key = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.ndjson",
        .{ tenant, node, batch_id },
    );
    defer allocator.free(ndjson_key);
    const idx_key = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.idx.json",
        .{ tenant, node, batch_id },
    );
    defer allocator.free(idx_key);

    const idx = sidecar.IdxFile{
        .tenant_id = tenant,
        .node_id = node,
        .batch_id = batch_id,
        .ndjson_key = ndjson_key,
        .ndjson_size = 0,
        .ndjson_sha256 = "deadbeef",
        .first_received_ns = if (records.len == 0) 0 else records[0].received_ns,
        .last_received_ns = if (records.len == 0) 0 else records[records.len - 1].received_ns,
        .records = records,
    };
    const bytes = try sidecar.encode(allocator, &idx);
    defer allocator.free(bytes);

    // Write the ndjson before the sidecar — orphan-payload safety:
    // the indexer only keys off sidecars.
    try store.put(ndjson_key, "placeholder ndjson bytes");
    try store.put(idx_key, bytes);
}

test "pollOnce indexes a single sidecar end-to-end" {
    const a = testing.allocator;
    const root = try tempDir(a, "single");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/index.db", .{root}, 0);
    defer a.free(db_path);
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var records = [_]sidecar.Record{
        .{
            .request_id = 7,
            .received_ns = 1_000,
            .duration_ns = 500,
            .method = "GET",
            .path = "/foo",
            .host = "acme.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 100,
        },
    };
    try writeSidecar(a, store, "acme", "00000001", "00000000000000000007-1730764800000", &records);

    const stats = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 1), stats.sidecars_seen);
    try testing.expectEqual(@as(u32, 1), stats.batches_indexed);
    try testing.expectEqual(@as(u32, 1), stats.records_indexed);
    // Two non-sidecar entries: the .ndjson + the SQLite file's own
    // `index.db-wal` / `index.db-shm` may show up too, depending on
    // sync state. Lower-bound.
    try testing.expect(stats.skipped_non_sidecars >= 1);

    // Index now has the row.
    var list = try db.queryList("acme", 0, 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqual(@as(u64, 7), list.rows[0].request_id);
}

test "pollOnce is idempotent across runs" {
    const a = testing.allocator;
    const root = try tempDir(a, "idem");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/index.db", .{root}, 0);
    defer a.free(db_path);
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var records = [_]sidecar.Record{
        .{
            .request_id = 1,
            .received_ns = 100,
            .duration_ns = 1,
            .method = "GET",
            .path = "/",
            .host = "h.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 1,
        },
    };
    try writeSidecar(a, store, "acme", "00000001", "b1-001", &records);

    _ = try pollOnce(a, store, db, 32);
    const stats2 = try pollOnce(a, store, db, 32);
    // Full-scan model: the second pass DOES see the sidecar again,
    // but `INSERT OR IGNORE` in `index_db.insertBatch` keeps the
    // table state idempotent. Records-indexed counts the per-row
    // INSERT calls regardless of whether they actually wrote.
    try testing.expectEqual(@as(u32, 1), stats2.sidecars_seen);
    try testing.expectEqual(@as(u32, 1), stats2.batches_indexed);

    // Still exactly one row in the index after both passes.
    var list = try db.queryList("acme", 0, 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
}

test "pollOnce picks up newly-arrived sidecars across passes" {
    const a = testing.allocator;
    const root = try tempDir(a, "incr");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/index.db", .{root}, 0);
    defer a.free(db_path);
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var r1 = [_]sidecar.Record{
        .{
            .request_id = 1,
            .received_ns = 100,
            .duration_ns = 1,
            .method = "GET",
            .path = "/a",
            .host = "h.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 1,
        },
    };
    try writeSidecar(a, store, "acme", "00000001", "b1", &r1);
    const s1 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 1), s1.batches_indexed);

    // New sidecar arrives — second pass walks both sidecars again
    // (full-scan model). The new one INSERTs; the old one is a
    // no-op via `OR IGNORE`. End state: both rows in the index.
    var r2 = [_]sidecar.Record{
        .{
            .request_id = 2,
            .received_ns = 200,
            .duration_ns = 1,
            .method = "GET",
            .path = "/b",
            .host = "h.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 1,
        },
    };
    try writeSidecar(a, store, "acme", "00000001", "b2", &r2);
    const s2 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 2), s2.sidecars_seen);
    try testing.expectEqual(@as(u32, 2), s2.batches_indexed);

    var list = try db.queryList("acme", 0, 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.rows.len);
    try testing.expectEqual(@as(u64, 2), list.rows[0].request_id);
    try testing.expectEqual(@as(u64, 1), list.rows[1].request_id);
}

test "pollOnce skips non-sidecar files" {
    const a = testing.allocator;
    const root = try tempDir(a, "noise");
    defer {
        std.fs.cwd().deleteTree(root) catch {};
        a.free(root);
    }
    const fs_store = try batch_store_mod.FilesystemBatchStore.init(a, root);
    defer fs_store.deinit();
    const store = fs_store.batchStore();
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/index.db", .{root}, 0);
    defer a.free(db_path);
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    try store.put("acme/00000001/orphan.ndjson", "no sidecar yet");
    try store.put("acme/00000001/junk.txt", "garbage");

    const stats = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 0), stats.sidecars_seen);
    try testing.expectEqual(@as(u32, 0), stats.batches_indexed);
    try testing.expect(stats.skipped_non_sidecars >= 2);
}
