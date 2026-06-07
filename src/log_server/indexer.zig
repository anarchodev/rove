//! Indexer — polling loop that walks the batch store for `.ndjson`
//! batch objects, range-reads the embedded sidecar prefix, and
//! inserts the records into `log_index.db`.
//!
//! Each pass:
//!   1. LIST every key in the batch store (no cross-pass cursor — see below).
//!   2. For each `.ndjson` key, range-GET the head bytes
//!      (`HEAD_FETCH_BYTES`), parse `[u32 LE sidecar_size][sidecar JSON]`,
//!      refetch with a larger range if the sidecar exceeds the
//!      initial fetch size.
//!   3. Pass `header_size = 4 + sidecar_size` to `index_db.insertBatch`
//!      so per-record offsets stored in `log_index` are file-relative.
//!      Both `batches` and `log_index` insert with `OR IGNORE`, so
//!      already-indexed batches cost a PK lookup and skip writes.
//!   4. `_meta.last_seen_key` is updated for observability + future
//!      cursor-based optimization, but isn't consulted on read.
//!
//! ## Why a full scan instead of `--start-after` cursor
//!
//! `docs/logs-plan.md` §4.3 sketches an `S3 LIST --start-after last`
//! optimization. The `_logs/{node}/{batch}` key shape IS lex-monotonic
//! per node, but a cluster-wide cursor is fragile if a new node first
//! emits a batch whose key sorts earlier than the current cursor.
//! Per-pass full scan with `INSERT OR IGNORE` dedup is simpler and
//! cheap (cost dominated by the S3 LIST itself). Cursor refinement
//! with per-`node` book-keeping is a v2 task.
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

const NDJSON_SUFFIX: []const u8 = ".ndjson";

/// Initial Range-GET length when reading the embedded sidecar header.
/// Sidecars at 1024 records × ~250 bytes/record JSON ≈ 256 KB. 512 KB
/// covers typical batches in one round trip; oversized sidecars trigger
/// a refetch below.
const HEAD_FETCH_BYTES: u32 = 512 * 1024;

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
            if (!std.mem.endsWith(u8, key, NDJSON_SUFFIX)) {
                stats.skipped_non_sidecars += 1;
                continue;
            }
            stats.sidecars_seen += 1;

            const parsed = readEmbeddedSidecar(allocator, store, key) catch |err| {
                std.log.warn("log-indexer: read {s}: {s}", .{ key, @errorName(err) });
                stats.skipped_invalid += 1;
                continue;
            };
            var idx = parsed.idx;
            defer idx.deinit(allocator);

            db.insertBatch(&idx, key, parsed.header_size) catch |err| {
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

/// Index a single batch key by direct GET (no LIST roundtrip).
///
/// Used by the worker→log-server push path: after the worker PUTs
/// a batch to S3, it POSTs the resulting key to log-server's
/// `/v1/_internal/batch-pushed`, which calls this. Lets us bypass
/// LIST's eventual-consistency window on S3-compatible providers
/// where read-after-write is strong but list-after-write isn't
/// (OVH being the practical case). The 500ms polling cycle remains
/// the catch-up path for batches we missed (push dropped, log-server
/// restart, batches that pre-date the running log-server).
///
/// Returns `Stats{ sidecars_seen=1, batches_indexed=1 }` on success.
/// Non-fatal errors (S3 not-found, invalid sidecar) are logged + the
/// per-error stats bumped; the function still returns ok so the
/// caller can ack the push without retrying.
pub fn indexOneKey(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    key: []const u8,
) Error!Stats {
    var stats: Stats = .{};
    if (!std.mem.endsWith(u8, key, NDJSON_SUFFIX)) {
        stats.skipped_non_sidecars += 1;
        return stats;
    }
    stats.sidecars_seen += 1;

    const parsed = readEmbeddedSidecar(allocator, store, key) catch |err| {
        std.log.warn("log-indexer: push read {s}: {s}", .{ key, @errorName(err) });
        stats.skipped_invalid += 1;
        return stats;
    };
    var idx = parsed.idx;
    defer idx.deinit(allocator);

    db.insertBatch(&idx, key, parsed.header_size) catch |err| {
        std.log.warn("log-indexer: push insert {s}: {s}", .{ key, @errorName(err) });
        return Error.Sqlite;
    };
    stats.batches_indexed += 1;
    stats.records_indexed += @intCast(idx.records.len);
    return stats;
}

const ParsedSidecar = struct {
    idx: sidecar.IdxFile,
    /// `4 + sidecar_size`. Indexer adds this to per-record offsets
    /// when populating `log_index` so /show's stored offset is
    /// file-relative.
    header_size: u64,
};

/// Range-GET the head of `key`, parse the embedded sidecar prefix
/// (`[u32 LE sidecar_size][sidecar JSON]`), and return the parsed
/// `IdxFile` plus `header_size`. Issues a second range-GET if the
/// sidecar is larger than `HEAD_FETCH_BYTES`.
fn readEmbeddedSidecar(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    key: []const u8,
) !ParsedSidecar {
    var head = store.getRange(key, 0, HEAD_FETCH_BYTES, allocator) catch
        return error.BatchStoreRead;
    defer allocator.free(head);
    if (head.len < 4) return error.SidecarTruncated;

    const sidecar_size = std.mem.readInt(u32, head[0..4], .little);
    const want: usize = 4 + @as(usize, sidecar_size);

    if (head.len < want) {
        // Oversized sidecar — refetch enough bytes to cover it.
        // Replace `head` with the larger fetch so the existing defer
        // frees the right buffer.
        const refetched = store.getRange(key, 0, @intCast(want), allocator) catch
            return error.BatchStoreRead;
        allocator.free(head);
        head = refetched;
        if (head.len < want) return error.SidecarTruncated;
    }

    const idx = try sidecar.parse(allocator, head[4..want]);
    return .{ .idx = idx, .header_size = want };
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

fn tempDbPath(allocator: std.mem.Allocator, tag: []const u8) ![:0]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/rove-idxer-{s}-{x}.db",
        .{ tag, seed },
        0,
    );
    std.fs.cwd().deleteFile(path) catch {};
    return path;
}

/// Test helper: PUT a `.ndjson` object with the embedded-sidecar
/// layout the indexer expects ([u32 LE sidecar_size][sidecar JSON]).
/// No real frames region — the indexer only reads the sidecar.
fn writeSidecar(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    node: []const u8,
    batch_id: []const u8,
    records: []sidecar.Record,
) !void {
    const ndjson_key = try std.fmt.allocPrint(
        allocator,
        "_logs/{s}/{s}.ndjson",
        .{ node, batch_id },
    );
    defer allocator.free(ndjson_key);

    const idx = sidecar.IdxFile{
        .node_id = node,
        .batch_id = batch_id,
        .ndjson_size = 0,
        .ndjson_sha256 = "deadbeef",
        .first_received_ns = if (records.len == 0) 0 else records[0].received_ns,
        .last_received_ns = if (records.len == 0) 0 else records[records.len - 1].received_ns,
        .records = records,
    };
    const sidecar_bytes = try sidecar.encode(allocator, &idx);
    defer allocator.free(sidecar_bytes);

    const sidecar_size = std.math.cast(u32, sidecar_bytes.len) orelse return error.SidecarTooLarge;
    const obj = try allocator.alloc(u8, 4 + sidecar_bytes.len);
    defer allocator.free(obj);
    std.mem.writeInt(u32, obj[0..4], sidecar_size, .little);
    @memcpy(obj[4..], sidecar_bytes);
    try store.put(ndjson_key, obj);
}

test "pollOnce indexes a single sidecar end-to-end" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    const db_path = try tempDbPath(a, "single");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var records = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
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
    try writeSidecar(a, store, "00000001", "00000000000000000007-1730764800000", &records);

    const stats = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 1), stats.sidecars_seen);
    try testing.expectEqual(@as(u32, 1), stats.batches_indexed);
    try testing.expectEqual(@as(u32, 1), stats.records_indexed);
    // Single object — embedded sidecar lives inside the .ndjson.
    try testing.expectEqual(@as(u32, 0), stats.skipped_non_sidecars);

    // Index now has the row.
    var list = try db.queryList("acme", 0, 0, 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqual(@as(u64, 7), list.rows[0].request_id);
}

test "pollOnce is idempotent across runs" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();
    const db_path = try tempDbPath(a, "idem");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var records = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
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
    try writeSidecar(a, store, "00000001", "b1-001", &records);

    _ = try pollOnce(a, store, db, 32);
    const stats2 = try pollOnce(a, store, db, 32);
    // Full-scan model: the second pass DOES see the sidecar again,
    // but `INSERT OR IGNORE` in `index_db.insertBatch` keeps the
    // table state idempotent. Records-indexed counts the per-row
    // INSERT calls regardless of whether they actually wrote.
    try testing.expectEqual(@as(u32, 1), stats2.sidecars_seen);
    try testing.expectEqual(@as(u32, 1), stats2.batches_indexed);

    // Still exactly one row in the index after both passes.
    var list = try db.queryList("acme", 0, 0, 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
}

test "pollOnce picks up newly-arrived sidecars across passes" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();
    const db_path = try tempDbPath(a, "incr");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var r1 = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
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
    try writeSidecar(a, store, "00000001", "b1", &r1);
    const s1 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 1), s1.batches_indexed);

    // New sidecar arrives — second pass walks both sidecars again
    // (full-scan model). The new one INSERTs; the old one is a
    // no-op via `OR IGNORE`. End state: both rows in the index.
    var r2 = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
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
    try writeSidecar(a, store, "00000001", "b2", &r2);
    const s2 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 2), s2.sidecars_seen);
    try testing.expectEqual(@as(u32, 2), s2.batches_indexed);

    var list = try db.queryList("acme", 0, 0, 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.rows.len);
    try testing.expectEqual(@as(u64, 2), list.rows[0].request_id);
    try testing.expectEqual(@as(u64, 1), list.rows[1].request_id);
}

test "pollOnce skips garbage objects" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();
    const db_path = try tempDbPath(a, "noise");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    // garbage.ndjson has random bytes — readEmbeddedSidecar will read a
    // bogus sidecar_size, refetch, fail, and skip with skipped_invalid.
    try store.put("_logs/00000001/garbage.ndjson", "no sidecar yet");
    try store.put("_logs/00000001/junk.txt", "garbage");

    const stats = try pollOnce(a, store, db, 32);
    // .ndjson is seen but invalid; .txt is not even attempted.
    try testing.expectEqual(@as(u32, 1), stats.sidecars_seen);
    try testing.expectEqual(@as(u32, 0), stats.batches_indexed);
    try testing.expectEqual(@as(u32, 1), stats.skipped_invalid);
    try testing.expectEqual(@as(u32, 1), stats.skipped_non_sidecars);
}
