//! `log_index.db` — local SQLite store the log-server (Phase 5.5 a)
//! polls into. Schema mirrors `docs/logs-plan.md` §4.2: one row per
//! batch (for the indexer's idempotency + sidecar bookkeeping) and
//! one row per record (for the dashboard's list / show queries).
//!
//! Single SQLite file owned by the indexer thread. The HTTP query API
//! reads from a separate connection (WAL-friendly); see
//! `src/log_server/standalone.zig` for the wiring. Inserts always
//! happen inside one transaction per sidecar so `_meta.last_seen_key`
//! advances atomically with the indexed rows.

const std = @import("std");
const sidecar = @import("sidecar.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    Sqlite,
    JournalMode,
    OutOfMemory,
};

const SCHEMA: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS _meta (
    \\    k TEXT PRIMARY KEY,
    \\    v TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS batches (
    \\    node_id       TEXT NOT NULL,
    \\    batch_id      TEXT NOT NULL,
    \\    ndjson_key    TEXT NOT NULL,
    \\    ndjson_size   INTEGER NOT NULL,
    \\    ndjson_sha256 TEXT NOT NULL,
    \\    first_received_ns INTEGER NOT NULL,
    \\    last_received_ns  INTEGER NOT NULL,
    \\    indexed_at_ns INTEGER NOT NULL,
    \\    PRIMARY KEY (node_id, batch_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS batches_recv ON batches (last_received_ns DESC);
    \\CREATE TABLE IF NOT EXISTS log_index (
    \\    tenant_id      TEXT NOT NULL,
    \\    request_id     INTEGER NOT NULL,
    \\    received_ns    INTEGER NOT NULL,
    \\    duration_ns    INTEGER NOT NULL,
    \\    method         TEXT,
    \\    path           TEXT,
    \\    host           TEXT,
    \\    status         INTEGER,
    \\    outcome        TEXT,
    \\    deployment_id  INTEGER,
    \\    ndjson_key     TEXT NOT NULL,
    \\    offset         INTEGER NOT NULL,
    \\    length         INTEGER NOT NULL,
    \\    PRIMARY KEY (tenant_id, request_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS log_idx_recv    ON log_index (tenant_id, received_ns DESC);
    \\CREATE INDEX IF NOT EXISTS log_idx_status  ON log_index (tenant_id, status, received_ns DESC);
    \\CREATE INDEX IF NOT EXISTS log_idx_failure ON log_index (tenant_id, received_ns DESC) WHERE outcome != 'ok';
    \\CREATE INDEX IF NOT EXISTS log_idx_deploy  ON log_index (tenant_id, deployment_id, received_ns DESC);
    \\CREATE TABLE IF NOT EXISTS log_tags (
    \\    tenant_id   TEXT NOT NULL,
    \\    request_id  INTEGER NOT NULL,
    \\    key         TEXT NOT NULL,
    \\    value       TEXT NOT NULL,
    \\    received_ns INTEGER NOT NULL,
    \\    PRIMARY KEY (tenant_id, request_id, key)
    \\);
    \\CREATE INDEX IF NOT EXISTS log_tags_lookup ON log_tags (tenant_id, key, value, received_ns DESC);
;

/// Owning handle for a `log_index.db` connection.
///
/// Two connections share one WAL-mode file (`docs/architecture/deployment-and-logs.md`):
///
///   - The **writer** (`open`) is opened by the indexer thread's owner
///     and is ALSO used by the h2 server thread for the push path
///     (`/v1/_internal/batch-pushed` → `indexOneKey` → `insertBatch`).
///     Two threads touch it, so it stays FULLMUTEX (serialized).
///   - The **reader** (`openReader`) is opened per process and used by
///     the h2 server thread alone for the query surface (/list, /show,
///     /count). Single-threaded, so NOMUTEX — and on its own
///     connection, so a list/show/count never waits on the writer's
///     connection mutex while the indexer is mid-`insertBatch`. WAL
///     gives the reader a consistent snapshot without blocking the
///     writer.
///
/// Before the split both roles shared ONE FULLMUTEX connection, so
/// every read serialized against every indexer write — the index's
/// near-term scaling ceiling. WAL was already on; the split just hands
/// reads their own handle.
pub const IndexDb = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,

    /// Open the read+write connection (writer + push path). Creates the
    /// file + schema if absent. Open this BEFORE `openReader` so the
    /// WAL/shm sidecar files exist when the reader attaches.
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) Error!*IndexDb {
        return openConn(allocator, path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, true);
    }

    /// Open a second connection for the query surface only. Opened
    /// READWRITE (not READONLY — a read-only handle can't create the
    /// WAL/shm sidecars, and dodging that pitfall is simpler than
    /// guarding it) but the query helpers never write through it.
    /// NOMUTEX: a single thread (the h2 event loop) owns it. Must be
    /// opened after `open` has created the schema.
    pub fn openReader(allocator: std.mem.Allocator, path: [:0]const u8) Error!*IndexDb {
        return openConn(allocator, path, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX, false);
    }

    fn openConn(
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        open_flags: c_int,
        run_schema: bool,
    ) Error!*IndexDb {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &db, open_flags, null);
        if (rc != c.SQLITE_OK or db == null) return Error.Sqlite;
        errdefer _ = c.sqlite3_close_v2(db);

        // WAL + sane defaults. 5s busy timeout shields against the rare
        // contention spike (e.g. a checkpoint landing during a query,
        // or the writer + push path briefly contending the WAL lock).
        // `journal_mode=WAL` is a no-op once the file is already WAL,
        // so the reader re-asserting it is harmless.
        if (c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null) != c.SQLITE_OK)
            return Error.JournalMode;
        _ = c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA busy_timeout=5000;", null, null, null);
        if (run_schema) {
            if (c.sqlite3_exec(db, SCHEMA.ptr, null, null, null) != c.SQLITE_OK)
                return Error.Sqlite;
        }

        const self = allocator.create(IndexDb) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .db = db.? };
        return self;
    }

    pub fn close(self: *IndexDb) void {
        _ = c.sqlite3_close_v2(self.db);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Idempotently insert a batch's `batches` row + per-record
    /// `log_index` rows. `INSERT OR IGNORE` on both tables means
    /// re-indexing the same object (e.g. after a crash mid-poll) is
    /// a no-op. After the transaction commits, `_meta.last_seen_key`
    /// is updated to point at the .ndjson key (observability only).
    ///
    /// `ndjson_key` is the batch-store key the embedded-sidecar
    /// object lives at. `header_size` is `4 + sidecar_size` so the
    /// per-record offsets stored in `log_index` are file-relative
    /// (sidecar offsets are frame-relative — see `flush_writer.zig`).
    pub fn insertBatch(
        self: *IndexDb,
        idx: *const sidecar.IdxFile,
        ndjson_key: []const u8,
        header_size: u64,
    ) Error!void {
        const indexed_at_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (c.sqlite3_exec(self.db, "BEGIN IMMEDIATE;", null, null, null) != c.SQLITE_OK)
            return Error.Sqlite;
        errdefer _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, null);

        try execBatchInsert(self.db, idx, ndjson_key, indexed_at_ns);
        try execLogIndexInserts(self.db, idx, ndjson_key, header_size);
        try execLogTagsInserts(self.db, idx);
        try setMetaInTxn(self.db, "last_seen_key", ndjson_key);

        if (c.sqlite3_exec(self.db, "COMMIT;", null, null, null) != c.SQLITE_OK)
            return Error.Sqlite;
    }

    /// Read a `_meta` row. Returns null if absent. Caller frees the
    /// returned slice.
    pub fn getMeta(self: *IndexDb, key: []const u8) Error!?[]u8 {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT v FROM _meta WHERE k = ?", -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, key);
        const rc = c.sqlite3_step(st);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;
        return try dupeColumnText(self.allocator, st.?, 0);
    }

    pub fn setMeta(self: *IndexDb, key: []const u8, value: []const u8) Error!void {
        return setMetaInTxn(self.db, key, value);
    }

    /// True if `(node_id, batch_id)` is already recorded in `batches`. The
    /// indexer's cursor-lag buffer re-LISTs a trailing clock-skew window each
    /// poll; this PK lookup lets it skip re-GETting a batch it already indexed,
    /// so the buffer costs LIST calls, not redundant object reads.
    pub fn batchIndexed(self: *IndexDb, node_id: []const u8, batch_id: []const u8) Error!bool {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM batches WHERE node_id = ? AND batch_id = ? LIMIT 1", -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, node_id);
        bindText(st.?, 2, batch_id);
        const rc = c.sqlite3_step(st);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return Error.Sqlite;
    }

    /// Total indexed records for `tenant_id`. Cheap because the
    /// (tenant_id, received_ns DESC) primary index makes the count a
    /// covering scan. Used by `/v1/{tenant}/count` so dashboards can
    /// surface a record total without paginating the whole list.
    /// `floor_received_ns` is the retention read-clamp (docs/architecture/control-plane.md
    /// Lever 3): only records at-or-after it are counted. Pass 0 to disable
    /// the clamp (no plan / CP unreachable).
    pub fn queryCount(self: *IndexDb, tenant_id: []const u8, floor_received_ns: i64) Error!u64 {
        const sql = "SELECT COUNT(*) FROM log_index WHERE tenant_id = ? AND (?2 = 0 OR received_ns >= ?2)";
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, floor_received_ns);
        const rc = c.sqlite3_step(st);
        if (rc != c.SQLITE_ROW) return Error.Sqlite;
        return @intCast(c.sqlite3_column_int64(st, 0));
    }

    /// One row in a list-query response.
    pub const ListRow = struct {
        tenant_id: []u8,
        request_id: u64,
        received_ns: i64,
        duration_ns: i64,
        method: []u8,
        path: []u8,
        host: []u8,
        status: u16,
        outcome: []u8,
        deployment_id: u64,

        pub fn deinit(self: *ListRow, a: std.mem.Allocator) void {
            a.free(self.tenant_id);
            a.free(self.method);
            a.free(self.path);
            a.free(self.host);
            a.free(self.outcome);
        }
    };

    pub const ListResult = struct {
        rows: []ListRow,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ListResult) void {
            for (self.rows) |*r| r.deinit(self.allocator);
            self.allocator.free(self.rows);
        }
    };

    /// Newest-first list of records for `tenant_id`. Pagination cursor:
    /// pass `(after_received_ns, after_request_id)` from the previous
    /// page's tail to advance. `(0, 0)` starts at the newest.
    /// `floor_received_ns` is the retention read-clamp (docs/architecture/control-plane.md
    /// Lever 3): rows before it are never returned. Pass 0 to disable.
    pub fn queryList(
        self: *IndexDb,
        tenant_id: []const u8,
        after_received_ns: i64,
        after_request_id: u64,
        floor_received_ns: i64,
        limit: u32,
        /// Optional tag filter: when both are non-null, only records
        /// carrying a `log_tags` row `(key=tag_key, value=tag_value)`
        /// are returned. Backs `?tag.k=v` and the `/session/{id}`
        /// sugar route (`tag_key = "session"`). Null → no tag filter.
        tag_key: ?[]const u8,
        tag_value: ?[]const u8,
    ) Error!ListResult {
        const sql =
            \\SELECT tenant_id, request_id, received_ns, duration_ns, method, path, host,
            \\       status, outcome, deployment_id
            \\FROM log_index li
            \\WHERE li.tenant_id = ?
            \\  AND (?2 = 0 OR
            \\       received_ns < ?2 OR
            \\       (received_ns = ?2 AND request_id < ?3))
            \\  AND (?5 = 0 OR received_ns >= ?5)
            \\  AND (?6 IS NULL OR EXISTS (
            \\       SELECT 1 FROM log_tags t
            \\        WHERE t.tenant_id = li.tenant_id AND t.request_id = li.request_id
            \\          AND t.key = ?6 AND t.value = ?7))
            \\ORDER BY received_ns DESC, request_id DESC
            \\LIMIT ?4
        ;
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, after_received_ns);
        _ = c.sqlite3_bind_int64(st, 3, @intCast(after_request_id));
        _ = c.sqlite3_bind_int64(st, 4, @intCast(limit));
        _ = c.sqlite3_bind_int64(st, 5, floor_received_ns);
        if (tag_key != null and tag_value != null) {
            bindText(st.?, 6, tag_key.?);
            bindText(st.?, 7, tag_value.?);
        } else {
            _ = c.sqlite3_bind_null(st, 6);
            _ = c.sqlite3_bind_null(st, 7);
        }

        var rows: std.ArrayListUnmanaged(ListRow) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(st);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            const row: ListRow = .{
                .tenant_id = try dupeColumnText(self.allocator, st.?, 0),
                .request_id = @intCast(c.sqlite3_column_int64(st, 1)),
                .received_ns = c.sqlite3_column_int64(st, 2),
                .duration_ns = c.sqlite3_column_int64(st, 3),
                .method = try dupeColumnText(self.allocator, st.?, 4),
                .path = try dupeColumnText(self.allocator, st.?, 5),
                .host = try dupeColumnText(self.allocator, st.?, 6),
                .status = @intCast(c.sqlite3_column_int(st, 7)),
                .outcome = try dupeColumnText(self.allocator, st.?, 8),
                // deployment_id is content-addressed u64 (sha-256
                // truncated); the high bit can be set. SQLite
                // INTEGER stores all 64 bits; reinterpret without
                // a sign check.
                .deployment_id = @bitCast(c.sqlite3_column_int64(st, 9)),
            };
            rows.append(self.allocator, row) catch return Error.OutOfMemory;
        }
        return .{
            .rows = rows.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
            .allocator = self.allocator,
        };
    }

    pub const ShowResult = struct {
        ndjson_key: []u8,
        offset: u64,
        length: u32,
        method: []u8,
        path: []u8,
        host: []u8,
        status: u16,
        outcome: []u8,
        received_ns: i64,
        duration_ns: i64,
        deployment_id: u64,

        pub fn deinit(self: *ShowResult, a: std.mem.Allocator) void {
            a.free(self.ndjson_key);
            a.free(self.method);
            a.free(self.path);
            a.free(self.host);
            a.free(self.outcome);
        }
    };

    /// Look up a single record's payload location + index columns.
    /// Returns null if the record isn't indexed (yet, or ever).
    pub fn queryShow(
        self: *IndexDb,
        tenant_id: []const u8,
        request_id: u64,
    ) Error!?ShowResult {
        const sql =
            \\SELECT ndjson_key, offset, length, method, path, host, status, outcome,
            \\       received_ns, duration_ns, deployment_id
            \\FROM log_index
            \\WHERE tenant_id = ? AND request_id = ?
        ;
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, @intCast(request_id));

        const rc = c.sqlite3_step(st);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return Error.Sqlite;

        return .{
            .ndjson_key = try dupeColumnText(self.allocator, st.?, 0),
            .offset = @intCast(c.sqlite3_column_int64(st, 1)),
            .length = @intCast(c.sqlite3_column_int(st, 2)),
            .method = try dupeColumnText(self.allocator, st.?, 3),
            .path = try dupeColumnText(self.allocator, st.?, 4),
            .host = try dupeColumnText(self.allocator, st.?, 5),
            .status = @intCast(c.sqlite3_column_int(st, 6)),
            .outcome = try dupeColumnText(self.allocator, st.?, 7),
            .received_ns = c.sqlite3_column_int64(st, 8),
            .duration_ns = c.sqlite3_column_int64(st, 9),
            .deployment_id = @bitCast(c.sqlite3_column_int64(st, 10)),
        };
    }
};

// ── Internal helpers ──────────────────────────────────────────────

fn execBatchInsert(
    db: *c.sqlite3,
    idx: *const sidecar.IdxFile,
    ndjson_key: []const u8,
    indexed_at_ns: i64,
) Error!void {
    const sql =
        \\INSERT OR IGNORE INTO batches
        \\(node_id, batch_id, ndjson_key, ndjson_size,
        \\ ndjson_sha256, first_received_ns, last_received_ns, indexed_at_ns)
        \\VALUES (?,?,?,?,?,?,?,?)
    ;
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
    defer _ = c.sqlite3_finalize(st);
    bindText(st.?, 1, idx.node_id);
    bindText(st.?, 2, idx.batch_id);
    bindText(st.?, 3, ndjson_key);
    _ = c.sqlite3_bind_int64(st, 4, @intCast(idx.ndjson_size));
    bindText(st.?, 5, idx.ndjson_sha256);
    _ = c.sqlite3_bind_int64(st, 6, idx.first_received_ns);
    _ = c.sqlite3_bind_int64(st, 7, idx.last_received_ns);
    _ = c.sqlite3_bind_int64(st, 8, indexed_at_ns);
    if (c.sqlite3_step(st) != c.SQLITE_DONE) return Error.Sqlite;
}

fn execLogIndexInserts(
    db: *c.sqlite3,
    idx: *const sidecar.IdxFile,
    ndjson_key: []const u8,
    header_size: u64,
) Error!void {
    const sql =
        \\INSERT OR IGNORE INTO log_index
        \\(tenant_id, request_id, received_ns, duration_ns,
        \\ method, path, host, status, outcome, deployment_id,
        \\ ndjson_key, offset, length)
        \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    ;
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
    defer _ = c.sqlite3_finalize(st);

    for (idx.records) |r| {
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_clear_bindings(st);
        // Each record carries its own tenant_id under the
        // interleaved-per-node layout (Phase 5.5 a-2). The indexer
        // demuxes here so log_index stays per-tenant.
        // The sidecar's per-record offset is frame-relative; add
        // `header_size` (= 4 + sidecar_size) so the stored offset is
        // file-relative — /show's range-GET reads at this offset
        // directly with no further math.
        bindText(st.?, 1, r.tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, @intCast(r.request_id));
        _ = c.sqlite3_bind_int64(st, 3, r.received_ns);
        _ = c.sqlite3_bind_int64(st, 4, r.duration_ns);
        bindText(st.?, 5, r.method);
        bindText(st.?, 6, r.path);
        bindText(st.?, 7, r.host);
        _ = c.sqlite3_bind_int(st, 8, @intCast(r.status));
        bindText(st.?, 9, r.outcome);
        // u64 → i64 bit-cast (high-bit-set deployment_ids are valid
        // content hashes).
        _ = c.sqlite3_bind_int64(st, 10, @bitCast(r.deployment_id));
        bindText(st.?, 11, ndjson_key);
        _ = c.sqlite3_bind_int64(st, 12, @intCast(r.offset + header_size));
        _ = c.sqlite3_bind_int(st, 13, @intCast(r.length));
        if (c.sqlite3_step(st) != c.SQLITE_DONE) return Error.Sqlite;
    }
}

/// Reserved tag key: the engine-populated per-chain correlation id.
/// `request.tag` rejects `_`-prefixed keys, so this can't collide with
/// a user tag. Lets `?tag._corr=<id>` filter by the engine session key
/// even when the handler set no `session` tag of its own.
pub const RESERVED_CORR_TAG = "_corr";

/// Insert each record's user tags (+ the reserved `_corr` tag derived
/// from its correlation_id) into `log_tags`. `INSERT OR IGNORE` on the
/// (tenant_id, request_id, key) primary key keeps re-indexing
/// idempotent. Runs inside the same transaction as the log_index
/// inserts.
fn execLogTagsInserts(db: *c.sqlite3, idx: *const sidecar.IdxFile) Error!void {
    const sql =
        \\INSERT OR IGNORE INTO log_tags
        \\(tenant_id, request_id, key, value, received_ns)
        \\VALUES (?,?,?,?,?)
    ;
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
    defer _ = c.sqlite3_finalize(st);

    for (idx.records) |r| {
        if (r.correlation_id.len > 0)
            try bindTagRow(st.?, r.tenant_id, r.request_id, RESERVED_CORR_TAG, r.correlation_id, r.received_ns);
        for (r.tags) |t| {
            if (t.key.len == 0 or t.value.len == 0) continue;
            try bindTagRow(st.?, r.tenant_id, r.request_id, t.key, t.value, r.received_ns);
        }
    }
}

fn bindTagRow(
    st: *c.sqlite3_stmt,
    tenant_id: []const u8,
    request_id: u64,
    key: []const u8,
    value: []const u8,
    received_ns: i64,
) Error!void {
    _ = c.sqlite3_reset(st);
    _ = c.sqlite3_clear_bindings(st);
    bindText(st, 1, tenant_id);
    _ = c.sqlite3_bind_int64(st, 2, @intCast(request_id));
    bindText(st, 3, key);
    bindText(st, 4, value);
    _ = c.sqlite3_bind_int64(st, 5, received_ns);
    if (c.sqlite3_step(st) != c.SQLITE_DONE) return Error.Sqlite;
}

fn setMetaInTxn(db: *c.sqlite3, key: []const u8, value: []const u8) Error!void {
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(
        db,
        "INSERT INTO _meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
        -1,
        &st,
        null,
    ) != c.SQLITE_OK) return Error.Sqlite;
    defer _ = c.sqlite3_finalize(st);
    bindText(st.?, 1, key);
    bindText(st.?, 2, value);
    if (c.sqlite3_step(st) != c.SQLITE_DONE) return Error.Sqlite;
}

fn bindText(st: *c.sqlite3_stmt, idx: c_int, s: []const u8) void {
    // SQLITE_TRANSIENT (-1 cast to destructor) makes sqlite copy the
    // bytes — caller's slice doesn't have to outlive the statement.
    const transient: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    _ = c.sqlite3_bind_text(st, idx, s.ptr, @intCast(s.len), transient);
}

fn dupeColumnText(allocator: std.mem.Allocator, st: *c.sqlite3_stmt, col: c_int) Error![]u8 {
    const ptr = c.sqlite3_column_text(st, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(st, col));
    const out = allocator.alloc(u8, len) catch return Error.OutOfMemory;
    if (len > 0) @memcpy(out, @as([*]const u8, @ptrCast(ptr))[0..len]);
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tempPath(allocator: std.mem.Allocator, tag: []const u8) ![:0]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/rove-idxdb-{s}-{x}.db",
        .{ tag, seed },
        0,
    );
    std.fs.cwd().deleteFile(path) catch {};
    return path;
}

/// Remove the `-wal` / `-shm` sidecars a WAL connection leaves next to
/// `db_path`. Best-effort; ignores missing files.
fn deleteWalSidecars(db_path: []const u8) void {
    var buf: [512]u8 = undefined;
    inline for (.{ "-wal", "-shm" }) |suffix| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ db_path, suffix }) catch return;
        std.fs.cwd().deleteFile(p) catch {};
    }
}

fn fixtureBatch(records_count: usize, base_request_id: u64, base_ns: i64) sidecar.IdxFile {
    // Caller manages records storage; these tests use a static slice.
    _ = records_count;
    _ = base_request_id;
    _ = base_ns;
    return undefined;
}

test "insertBatch + queryList round-trips, newest-first" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "list");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var records = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
            .request_id = 100,
            .received_ns = 1_000,
            .duration_ns = 500_000,
            .method = "GET",
            .path = "/a",
            .host = "acme.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 100,
        },
        .{
            .tenant_id = "acme",
            .request_id = 101,
            .received_ns = 2_000,
            .duration_ns = 600_000,
            .method = "POST",
            .path = "/b",
            .host = "acme.test",
            .status = 500,
            .outcome = "handler_error",
            .deployment_id = 1,
            .offset = 100,
            .length = 110,
        },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "00000000000000000100-1730764800000",
        .ndjson_size = 210,
        .ndjson_sha256 = "deadbeef",
        .first_received_ns = 1_000,
        .last_received_ns = 2_000,
        .records = &records,
    };
    const ndjson_key = "_logs/00000001/00000000000000000100-1730764800000.ndjson";
    try idx.insertBatch(&batch, ndjson_key, 0);

    var list = try idx.queryList("acme", 0, 0, 0, 10, null, null);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.rows.len);
    // Newest first.
    try testing.expectEqual(@as(u64, 101), list.rows[0].request_id);
    try testing.expectEqual(@as(u64, 100), list.rows[1].request_id);
    try testing.expectEqualStrings("/b", list.rows[0].path);
    try testing.expectEqualStrings("handler_error", list.rows[0].outcome);

    // Pagination: cursor at (received_ns=2000, id=101) returns the
    // older row only.
    var p2 = try idx.queryList("acme", 2_000, 101, 0, 10, null, null);
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 1), p2.rows.len);
    try testing.expectEqual(@as(u64, 100), p2.rows[0].request_id);

    // Retention read-clamp (Lever 3): a floor of 1500 hides the
    // received_ns=1000 record, leaving only the 2000 one — in list AND count.
    var clamped = try idx.queryList("acme", 0, 0, 1_500, 10, null, null);
    defer clamped.deinit();
    try testing.expectEqual(@as(usize, 1), clamped.rows.len);
    try testing.expectEqual(@as(u64, 101), clamped.rows[0].request_id);
    try testing.expectEqual(@as(u64, 2), try idx.queryCount("acme", 0)); // no clamp
    try testing.expectEqual(@as(u64, 1), try idx.queryCount("acme", 1_500)); // clamped
}

test "queryList filters by tag (user session + reserved _corr)" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "tags");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var tags_a = [_]sidecar.Tag{.{ .key = "session", .value = "S1" }};
    var tags_b = [_]sidecar.Tag{.{ .key = "session", .value = "S2" }};
    var records = [_]sidecar.Record{
        .{ .tenant_id = "acme", .request_id = 1, .received_ns = 1_000, .duration_ns = 1, .method = "GET", .path = "/a", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .correlation_id = "C1", .tags = &tags_a, .offset = 0, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 2, .received_ns = 2_000, .duration_ns = 1, .method = "GET", .path = "/b", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .correlation_id = "C1", .tags = &tags_b, .offset = 10, .length = 10 },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "tagbatch",
        .ndjson_size = 20,
        .ndjson_sha256 = "d",
        .first_received_ns = 1_000,
        .last_received_ns = 2_000,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/tagbatch.ndjson", 0);

    // tag.session=S1 → only request 1.
    var s1 = try idx.queryList("acme", 0, 0, 0, 10, "session", "S1");
    defer s1.deinit();
    try testing.expectEqual(@as(usize, 1), s1.rows.len);
    try testing.expectEqual(@as(u64, 1), s1.rows[0].request_id);

    // Reserved _corr tag is auto-derived from correlation_id → both rows
    // share C1, so the engine session key returns the whole connection.
    var c1 = try idx.queryList("acme", 0, 0, 0, 10, "_corr", "C1");
    defer c1.deinit();
    try testing.expectEqual(@as(usize, 2), c1.rows.len);

    // Unknown tag value → no rows (not an error).
    var none = try idx.queryList("acme", 0, 0, 0, 10, "session", "nope");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.rows.len);
}

test "insertBatch is idempotent on the same sidecar key" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "idem");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var records = [_]sidecar.Record{
        .{
            .tenant_id = "globex",
            .request_id = 50,
            .received_ns = 5_000,
            .duration_ns = 1_000,
            .method = "GET",
            .path = "/x",
            .host = "h.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 80,
        },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000002",
        .batch_id = "00000000000000000050-1730764900000",
        .ndjson_size = 80,
        .ndjson_sha256 = "abc",
        .first_received_ns = 5_000,
        .last_received_ns = 5_000,
        .records = &records,
    };
    const ndjson_key = "_logs/00000002/00000000000000000050-1730764900000.ndjson";
    try idx.insertBatch(&batch, ndjson_key, 0);
    try idx.insertBatch(&batch, ndjson_key, 0);
    try idx.insertBatch(&batch, ndjson_key, 0);

    var list = try idx.queryList("globex", 0, 0, 0, 10, null, null);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
}

test "queryShow returns ndjson_key + offset + length" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "show");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var records = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
            .request_id = 7,
            .received_ns = 1,
            .duration_ns = 1,
            .method = "GET",
            .path = "/p",
            .host = "h.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 9,
            .offset = 1234,
            .length = 567,
        },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "b1",
        .ndjson_size = 1801,
        .ndjson_sha256 = "abc",
        .first_received_ns = 1,
        .last_received_ns = 1,
        .records = &records,
    };
    // header_size = 200 covers a 4-byte size prefix + 196-byte sidecar.
    // queryShow should return the file-relative offset (= 1234 + 200).
    try idx.insertBatch(&batch, "_logs/00000001/b1.ndjson", 200);

    var got = (try idx.queryShow("acme", 7)).?;
    defer got.deinit(a);
    try testing.expectEqual(@as(u64, 1434), got.offset);
    try testing.expectEqual(@as(u32, 567), got.length);
    try testing.expectEqualStrings("_logs/00000001/b1.ndjson", got.ndjson_key);
    try testing.expectEqual(@as(u64, 9), got.deployment_id);

    try testing.expectEqual(@as(?IndexDb.ShowResult, null), try idx.queryShow("acme", 9999));
}

test "_meta last_seen_key tracks the most recent insertBatch" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "meta");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    try testing.expectEqual(@as(?[]u8, null), try idx.getMeta("last_seen_key"));

    var records = [_]sidecar.Record{};
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "b1",
        .ndjson_size = 0,
        .ndjson_sha256 = "0",
        .first_received_ns = 0,
        .last_received_ns = 0,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/b1.ndjson", 0);
    const v1 = (try idx.getMeta("last_seen_key")).?;
    defer a.free(v1);
    try testing.expectEqualStrings("_logs/00000001/b1.ndjson", v1);

    try idx.insertBatch(&batch, "_logs/00000001/b2.ndjson", 0);
    const v2 = (try idx.getMeta("last_seen_key")).?;
    defer a.free(v2);
    try testing.expectEqualStrings("_logs/00000001/b2.ndjson", v2);
}

test "openReader sees rows committed by the writer connection" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "split");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path); // WAL/shm left by the two connections
        a.free(db_path);
    }

    // Writer opened first (creates the file + schema + WAL), then a
    // separate reader connection — the production wiring.
    var writer = try IndexDb.open(a, db_path);
    defer writer.close();
    var reader = try IndexDb.openReader(a, db_path);
    defer reader.close();

    var records = [_]sidecar.Record{
        .{
            .tenant_id = "acme",
            .request_id = 42,
            .received_ns = 1_000,
            .duration_ns = 5,
            .method = "GET",
            .path = "/split",
            .host = "h.test",
            .status = 200,
            .outcome = "ok",
            .deployment_id = 1,
            .offset = 0,
            .length = 10,
        },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "b1",
        .ndjson_size = 10,
        .ndjson_sha256 = "abc",
        .first_received_ns = 1_000,
        .last_received_ns = 1_000,
        .records = &records,
    };
    try writer.insertBatch(&batch, "_logs/00000001/b1.ndjson", 0);

    // The reader (own connection, WAL snapshot) sees the committed row.
    var list = try reader.queryList("acme", 0, 0, 0, 10, null, null);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqual(@as(u64, 42), list.rows[0].request_id);
    try testing.expectEqual(@as(u64, 1), try reader.queryCount("acme", 0));
}
