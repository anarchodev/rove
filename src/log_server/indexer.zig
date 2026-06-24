//! Indexer — polling loop that walks the batch store for `.ndjson`
//! batch objects, range-reads the embedded sidecar prefix, and
//! inserts the records into `log_index.db`.
//!
//! Each pass:
//!   1. Enumerate the `_logs/{node}/` prefixes present in the store
//!      (`listNodePrefixes`, a skip-scan — see below).
//!   2. For each node, LIST keys strictly after that node's persisted
//!      catch-up cursor (`_meta` key `cursor:{node_prefix}`).
//!   3. For each `.ndjson` key, range-GET the head bytes
//!      (`HEAD_FETCH_BYTES`), parse `[u32 LE sidecar_size][sidecar JSON]`,
//!      refetch with a larger range if the sidecar exceeds the
//!      initial fetch size.
//!   4. Pass `header_size = 4 + sidecar_size` to `index_db.insertBatch`
//!      so per-record offsets stored in `log_index` are file-relative.
//!      Both `batches` and `log_index` insert with `OR IGNORE`, so a
//!      batch the push path already indexed costs a PK lookup, no write.
//!   5. Advance + persist the node's cursor to the last LISTed key.
//!
//! ## Per-node `start-after` cursor
//!
//! `docs/logs-plan.md` §4.3 sketches an `S3 LIST --start-after last`
//! optimization. The `_logs/{node}/{batch}` key shape IS lex-monotonic
//! per node (batch_id leads with the monotonic first-request-id, so it
//! never goes backward even under clock skew), so a PER-NODE cursor is
//! sound — a new batch always sorts after the node's cursor, and a key
//! written while the indexer was down is picked up on resume. The
//! cluster-wide cursor that the old full-scan avoided was fragile only
//! because a fresh node could emit a key sorting earlier than it; one
//! cursor per node removes that hazard.
//!
//! Node discovery is a skip-scan over `_logs/` (`listNodePrefixes`):
//! list one key, extract its `_logs/{node}/` prefix, jump the cursor
//! past that whole node, repeat. O(nodes) tiny LISTs — no delimiter
//! support needed from the backend, so it works identically on S3 /
//! memory / fs. Per pass the cost is O(nodes), not O(objects-ever-
//! written) as the full scan was; idle passes that find nothing cost a
//! handful of empty LISTs regardless of how much history has accrued.
//!
//! The cursor always advances to the last LISTed key, even past a batch
//! that failed to read (logged + counted in `skipped_invalid`) — so a
//! permanently-bad object never wedges the scan and a node never
//! re-walks its whole history. A transiently-unreadable batch (partial
//! PUT, list-after-write lag) is recovered by the worker→log-server
//! push path (`indexOneKey`), which indexes by direct GET independent
//! of this cursor; missing both is within the logs' lossy-on-failure
//! contract (`docs/logs-plan.md`).
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

/// Root prefix every batch key lives under: `_logs/{node}/{batch}.ndjson`.
const LOGS_PREFIX: []const u8 = "_logs/";

/// One polling pass. Returns counts so callers (and tests) can assert
/// what was indexed. Discovers the node prefixes present in the store,
/// then catches each one up from its persisted cursor; dedup against
/// the push path is handled by `INSERT OR IGNORE` in `insertBatch`.
pub fn pollOnce(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    page_size: u32,
) Error!Stats {
    var stats: Stats = .{};

    const node_prefixes = listNodePrefixes(allocator, store) catch
        return Error.BatchStore;
    defer batch_store_mod.freeListResult(allocator, node_prefixes);

    for (node_prefixes) |node_prefix| {
        try pollNode(allocator, store, db, node_prefix, page_size, &stats);
    }
    return stats;
}

/// Catch one node up: page `node_prefix` strictly after the node's
/// persisted cursor (`_meta` key `cursor:{node_prefix}`), index each
/// `.ndjson` batch, and persist the advanced cursor after every page so
/// a crash mid-catch-up resumes where it left off. The cursor advances
/// to the last LISTed key even past a read failure — see the module doc
/// for why that's safe (push path recovers transient misses).
fn pollNode(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    node_prefix: []const u8,
    page_size: u32,
    stats: *Stats,
) Error!void {
    const meta_key = try cursorMetaKey(allocator, node_prefix);
    defer allocator.free(meta_key);

    var cursor: []u8 = (db.getMeta(meta_key) catch return Error.Sqlite) orelse
        try allocator.dupe(u8, "");
    defer allocator.free(cursor);

    while (true) {
        const keys = store.list(node_prefix, cursor, page_size, allocator) catch
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

        // Advance + persist the cursor to the last LISTed key so the
        // next page (and the next pass, and a restart) resumes here.
        const last_key = keys[keys.len - 1];
        const new_cursor = try allocator.dupe(u8, last_key);
        allocator.free(cursor);
        cursor = new_cursor;
        db.setMeta(meta_key, cursor) catch return Error.Sqlite;

        // Short page → caught up for this node.
        if (keys.len < page_size) break;
    }
}

/// The `_meta` key under which a node's catch-up cursor is persisted.
/// Caller frees.
fn cursorMetaKey(allocator: std.mem.Allocator, node_prefix: []const u8) Error![]u8 {
    return std.fmt.allocPrint(allocator, "cursor:{s}", .{node_prefix}) catch
        return Error.OutOfMemory;
}

/// Extract `_logs/{node}/` from a batch key, or null if the key isn't
/// under `_logs/` or carries no node segment. Returned slice borrows
/// from `key`.
fn nodePrefixOf(key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, key, LOGS_PREFIX)) return null;
    const rest = key[LOGS_PREFIX.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return key[0 .. LOGS_PREFIX.len + slash + 1];
}

/// Smallest string that sorts strictly after every key beginning with
/// `prefix` — used as `start-after` to skip an entire node in one jump.
/// `prefix` always ends in '/' (0x2F), so incrementing the last byte to
/// '0' (0x30) lands below the next node's prefix (node ids are
/// fixed-width, so the differing node byte orders the two before this
/// appended byte ever matters). Caller frees.
fn prefixUpperBound(allocator: std.mem.Allocator, prefix: []const u8) Error![]u8 {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(prefix[prefix.len - 1] != 0xff);
    const buf = allocator.dupe(u8, prefix) catch return Error.OutOfMemory;
    buf[buf.len - 1] += 1;
    return buf;
}

/// Enumerate the distinct `_logs/{node}/` prefixes in the store via a
/// skip-scan: list one key, record its node prefix, jump past that node
/// (`prefixUpperBound`), repeat. O(nodes) LISTs of max=1, using only the
/// `list` primitive (no backend delimiter support needed). Caller frees
/// with `batch_store_mod.freeListResult`.
fn listNodePrefixes(
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
) Error![][]const u8 {
    var prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var after = allocator.dupe(u8, "") catch return Error.OutOfMemory;
    defer allocator.free(after);

    while (true) {
        const keys = store.list(LOGS_PREFIX, after, 1, allocator) catch
            return Error.BatchStore;
        defer batch_store_mod.freeListResult(allocator, keys);
        if (keys.len == 0) break;
        const key = keys[0];

        // Next `start-after`: jump past this whole node when the key has
        // a node segment, else step one key forward. Either way `after`
        // strictly increases, so the scan terminates. Compute the bound
        // BEFORE appending `owned` so a later error here can't leave a
        // dangling errdefer that double-frees an already-appended entry.
        const next: []u8 = if (nodePrefixOf(key)) |np| blk: {
            const bound = try prefixUpperBound(allocator, np);
            errdefer allocator.free(bound);
            const owned = allocator.dupe(u8, np) catch return Error.OutOfMemory;
            errdefer allocator.free(owned);
            prefixes.append(allocator, owned) catch return Error.OutOfMemory;
            break :blk bound;
        } else allocator.dupe(u8, key) catch return Error.OutOfMemory;

        allocator.free(after);
        after = next;
    }

    return prefixes.toOwnedSlice(allocator) catch return Error.OutOfMemory;
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
    var list = try db.queryList("acme", 0, 0, 0, 10, null, null);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqual(@as(u64, 7), list.rows[0].request_id);
}

test "pollOnce cursor skips already-indexed batches on the next pass" {
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

    const stats1 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 1), stats1.batches_indexed);

    // Per-node cursor: the second pass resumes start-after the indexed
    // key, so it re-reads NOTHING — the proof the cursor advanced and
    // persisted. (The old full-scan re-walked the sidecar every pass.)
    const stats2 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 0), stats2.sidecars_seen);
    try testing.expectEqual(@as(u32, 0), stats2.batches_indexed);

    // Still exactly one row in the index after both passes.
    var list = try db.queryList("acme", 0, 0, 0, 10, null, null);
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

    // New sidecar arrives with a later (lex-greater) key. The per-node
    // cursor resumes start-after b1, so the second pass reads ONLY the
    // new b2 — not b1 again. End state: both rows in the index.
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
    try testing.expectEqual(@as(u32, 1), s2.sidecars_seen);
    try testing.expectEqual(@as(u32, 1), s2.batches_indexed);

    var list = try db.queryList("acme", 0, 0, 0, 10, null, null);
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

test "nodePrefixOf + prefixUpperBound" {
    const a = testing.allocator;

    try testing.expectEqualStrings(
        "_logs/00000001/",
        nodePrefixOf("_logs/00000001/00000000000000000007-1730764800000.ndjson").?,
    );
    // A bare node marker still yields its own prefix.
    try testing.expectEqualStrings("_logs/00000002/", nodePrefixOf("_logs/00000002/").?);
    // Not under _logs/, or no node segment → null.
    try testing.expect(nodePrefixOf("other/00000001/b.ndjson") == null);
    try testing.expect(nodePrefixOf("_logs/00000001") == null);

    // The bound replaces the trailing '/' (0x2F) with '0' (0x30) and
    // sorts strictly above every key under the prefix but below the
    // next fixed-width node prefix.
    const bound = try prefixUpperBound(a, "_logs/00000001/");
    defer a.free(bound);
    try testing.expectEqualStrings("_logs/000000010", bound);
    try testing.expect(std.mem.lessThan(u8, "_logs/00000001/zzz.ndjson", bound));
    try testing.expect(std.mem.lessThan(u8, bound, "_logs/00000002/"));
}

test "listNodePrefixes enumerates each node once via skip-scan" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();

    // Three nodes, several batches each, plus a non-_logs object that
    // must be ignored entirely.
    try store.put("_logs/00000001/b1.ndjson", "x");
    try store.put("_logs/00000001/b2.ndjson", "x");
    try store.put("_logs/00000002/b1.ndjson", "x");
    try store.put("_logs/00000003/b1.ndjson", "x");
    try store.put("_logs/00000003/b2.ndjson", "x");
    try store.put("other/ignore-me", "x");

    const prefixes = try listNodePrefixes(a, store);
    defer batch_store_mod.freeListResult(a, prefixes);
    try testing.expectEqual(@as(usize, 3), prefixes.len);
    try testing.expectEqualStrings("_logs/00000001/", prefixes[0]);
    try testing.expectEqualStrings("_logs/00000002/", prefixes[1]);
    try testing.expectEqualStrings("_logs/00000003/", prefixes[2]);
}

test "pollOnce advances each node's cursor independently" {
    const a = testing.allocator;
    const m = try batch_store_mod.MemoryBatchStore.init(a);
    defer m.deinit();
    const store = m.batchStore();
    const db_path = try tempDbPath(a, "multinode");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var db = try index_db_mod.IndexDb.open(a, db_path);
    defer db.close();

    var n1 = [_]sidecar.Record{.{ .tenant_id = "acme", .request_id = 1, .received_ns = 100, .duration_ns = 1, .method = "GET", .path = "/a", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 1 }};
    var n2 = [_]sidecar.Record{.{ .tenant_id = "acme", .request_id = 2, .received_ns = 200, .duration_ns = 1, .method = "GET", .path = "/b", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 1 }};
    try writeSidecar(a, store, "00000001", "00000000000000000001-1", &n1);
    try writeSidecar(a, store, "00000002", "00000000000000000002-1", &n2);

    // First pass indexes both nodes (one batch each).
    const s1 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 2), s1.batches_indexed);

    // A new batch on node 1 only. The node-2 cursor must NOT cause its
    // single batch to re-index, and node 1 must pick up just the new one.
    var n1b = [_]sidecar.Record{.{ .tenant_id = "acme", .request_id = 3, .received_ns = 300, .duration_ns = 1, .method = "GET", .path = "/c", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 1 }};
    try writeSidecar(a, store, "00000001", "00000000000000000003-1", &n1b);

    const s2 = try pollOnce(a, store, db, 32);
    try testing.expectEqual(@as(u32, 1), s2.sidecars_seen);
    try testing.expectEqual(@as(u32, 1), s2.batches_indexed);

    var list = try db.queryList("acme", 0, 0, 0, 10, null, null);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 3), list.rows.len);
}
