// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `log_index.db` — local SQLite store the log-server polls into.
//! Schema mirrors the log-server index model
//! (`docs/architecture/deployment-and-logs.md`): one row per
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
const metrics = @import("metrics.zig");

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
    \\    activation     TEXT,
    \\    exec_seq       INTEGER,
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
    \\CREATE TABLE IF NOT EXISTS log_sagas (
    \\    tenant_id         TEXT NOT NULL,
    \\    corr_id           TEXT NOT NULL,
    \\    first_received_ns INTEGER NOT NULL,
    \\    last_received_ns  INTEGER NOT NULL,
    \\    activation_count  INTEGER NOT NULL,
    \\    root_method       TEXT,
    \\    root_path         TEXT,
    \\    root_host         TEXT,
    \\    last_status       INTEGER,
    \\    last_outcome      TEXT,
    \\    error_count       INTEGER NOT NULL,
    \\    closed_at_ns      INTEGER,
    \\    PRIMARY KEY (tenant_id, corr_id)
    \\);
    \\CREATE INDEX IF NOT EXISTS log_sagas_recent ON log_sagas (tenant_id, last_received_ns DESC, corr_id DESC);
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
/// The two connections keep reads off the writer's mutex: a single
/// shared FULLMUTEX connection would serialize every read against
/// every indexer write.
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
            try migrate(db.?);
        }

        const self = allocator.create(IndexDb) catch return Error.OutOfMemory;
        self.* = .{ .allocator = allocator, .db = db.? };
        return self;
    }

    /// Bring an already-created `log_index.db` up to the current
    /// schema. `CREATE TABLE IF NOT EXISTS` is a no-op on a file that
    /// already has the table, so a column added to `SCHEMA` never
    /// reaches a deployed index — every node's `log_index.db` predates
    /// it. Additive columns therefore need an explicit `ALTER`.
    ///
    /// Idempotent by inspection (`PRAGMA table_info`) rather than by a
    /// stored schema version: the check is one pragma on a table that
    /// is open anyway, and it stays correct if a file is restored from
    /// a backup or hand-repaired, where a version counter would lie.
    /// Runs on the writer connection only — the reader attaches after
    /// it (see `openReader`), so it never races a migration.
    fn migrate(db: *c.sqlite3) Error!void {
        if (!try hasColumn(db, "log_index", "activation")) {
            // NULL for every pre-existing row, which reads as "kind
            // unknown" — see `sidecar.Record.activation`. Backfilling
            // them to 'inbound' would assert something the index never
            // recorded.
            if (c.sqlite3_exec(db, "ALTER TABLE log_index ADD COLUMN activation TEXT", null, null, null) != c.SQLITE_OK)
                return Error.Sqlite;
        }

        if (!try hasColumn(db, "log_index", "exec_seq")) {
            // NULL for every pre-existing row AND for unstamped records —
            // the tape position was never recorded, and backfilling one
            // would assert an order the index never saw.
            if (c.sqlite3_exec(db, "ALTER TABLE log_index ADD COLUMN exec_seq INTEGER", null, null, null) != c.SQLITE_OK)
                return Error.Sqlite;
        }
        // After the column exists on every path (fresh file via SCHEMA,
        // old file via the ALTER above) — partial: unstamped rows have no
        // place on the tape, so the seq-window scan never visits them.
        if (c.sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS log_idx_exec ON log_index (tenant_id, exec_seq) WHERE exec_seq IS NOT NULL", null, null, null) != c.SQLITE_OK)
            return Error.Sqlite;

        // The engine's reserved tag was `_saga` before the saga rename.
        // Rewrite the rows rather than aliasing on read: an alias would
        // put an `OR` back into the tag filter, which is precisely the
        // shape that cannot be planned (#443) — the fix there was to
        // delete a conditional from that query, and this would
        // reintroduce one.
        //
        // Bounded and one-time: it touches only rows whose key is the
        // retired constant, and once none remain the statement is a
        // no-op on every subsequent open. Safe to interrupt — a partial
        // run leaves a mix, and the next open finishes it.
        if (c.sqlite3_exec(
            db,
            "UPDATE OR IGNORE log_tags SET key = '" ++ RESERVED_SAGA_TAG ++ "' WHERE key = '" ++ RETIRED_CORR_TAG ++ "'",
            null,
            null,
            null,
        ) != c.SQLITE_OK) return Error.Sqlite;
    }

    fn hasColumn(db: *c.sqlite3, table: [:0]const u8, column: []const u8) Error!bool {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT 1 FROM pragma_table_info(?) WHERE name = ?", -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, table);
        bindText(st.?, 2, column);
        const rc = c.sqlite3_step(st);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return Error.Sqlite;
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
        /// Activation kind that produced the record. Empty when the
        /// row was indexed before the field existed (stored NULL) —
        /// "unknown", never `inbound`.
        activation: []u8,
        /// The execution-sequence stamp — the record's position on its
        /// tenant's execution tape. 0 when unstamped (stored NULL):
        /// the activation never entered execution, or the row predates
        /// the field. Ordered but NOT dense.
        exec_seq: u64 = 0,

        pub fn deinit(self: *ListRow, a: std.mem.Allocator) void {
            a.free(self.tenant_id);
            a.free(self.method);
            a.free(self.path);
            a.free(self.host);
            a.free(self.outcome);
            a.free(self.activation);
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

    /// Newest-first list of records for `tenant_id`, unfiltered.
    /// Driven by `log_idx_recv (tenant_id, received_ns DESC)`, so the
    /// `LIMIT` is satisfied by walking the head of that index.
    ///
    /// Shares parameter numbering with `LIST_SQL_TAGGED` (?1 tenant,
    /// ?2/?3 cursor, ?4 limit, ?5 floor) so both bind identically.
    ///
    /// HEAD/TAIL split: optional list FILTERS (`ListFilter`) splice
    /// their AND clauses between the two, each shape prepared as its
    /// own exact statement — never a parameter-guarded conditional
    /// clause, which is the un-plannable spelling LIST_SQL_TAGGED's
    /// comment documents.
    const LIST_SQL_UNTAGGED_HEAD =
        \\SELECT tenant_id, request_id, received_ns, duration_ns, method, path, host,
        \\       status, outcome, deployment_id, activation, exec_seq
        \\FROM log_index
        \\WHERE tenant_id = ?1
        \\  AND (?2 = 0 OR
        \\       received_ns < ?2 OR
        \\       (received_ns = ?2 AND request_id < ?3))
        \\  AND (?5 = 0 OR received_ns >= ?5)
    ;
    const LIST_SQL_UNTAGGED_TAIL =
        \\
        \\ORDER BY received_ns DESC, request_id DESC
        \\LIMIT ?4
    ;
    const LIST_SQL_UNTAGGED: [:0]const u8 = LIST_SQL_UNTAGGED_HEAD ++ LIST_SQL_UNTAGGED_TAIL;

    /// The same list, restricted to records carrying a `log_tags` row.
    ///
    /// **Drives from `log_tags`, and must keep doing so.** The obvious
    /// spelling — one statement with `(?6 IS NULL OR EXISTS (…))` — is
    /// unusable: SQLite cannot flatten an `EXISTS` guarded by a
    /// parameter test into a semi-join (the subquery may or may not
    /// apply, so it stays correlated), which forces a full scan of the
    /// tenant's window with a per-row probe into `log_tags`. Cost then
    /// tracks *scan distance to fill the LIMIT*, not the number of
    /// matching rows, so the worst case is a **small** result: a tag
    /// matching fewer records than `limit` never fills it and scans to
    /// the retention floor. Measured at 2 s vs 0 ms on a 2M-record
    /// index — which is the whole reason this is a separate statement
    /// rather than one with a conditional clause.
    ///
    /// `log_tags.received_ns` is denormalized from the record
    /// (`bindTagRow`) precisely so the cursor and the retention clamp
    /// can be applied on the driving table; the plan-shape test below
    /// pins the resulting index use.
    /// `CROSS JOIN`, not `JOIN`: in SQLite that is the documented way to
    /// PIN the join order, and the order is the whole point (see the
    /// doc comment above). A plain JOIN lets the planner invert the
    /// drive once a spliced column filter (e.g. `li.status BETWEEN`)
    /// makes `log_idx_status` look attractive — landing on exactly the
    /// materialize-then-sort shape this statement exists to avoid: a
    /// TEMP B-TREE over every match instead of streaming the LIMIT off
    /// `log_tags_lookup`'s time order.
    const LIST_SQL_TAGGED_HEAD =
        \\SELECT li.tenant_id, li.request_id, li.received_ns, li.duration_ns,
        \\       li.method, li.path, li.host, li.status, li.outcome, li.deployment_id,
        \\       li.activation, li.exec_seq
        \\FROM log_tags t
        \\CROSS JOIN log_index li ON li.tenant_id = t.tenant_id AND li.request_id = t.request_id
        \\WHERE t.tenant_id = ?1 AND t.key = ?6 AND t.value = ?7
        \\  AND (?2 = 0 OR
        \\       t.received_ns < ?2 OR
        \\       (t.received_ns = ?2 AND t.request_id < ?3))
        \\  AND (?5 = 0 OR t.received_ns >= ?5)
    ;
    const LIST_SQL_TAGGED_TAIL =
        \\
        \\ORDER BY t.received_ns DESC, t.request_id DESC
        \\LIMIT ?4
    ;
    const LIST_SQL_TAGGED: [:0]const u8 = LIST_SQL_TAGGED_HEAD ++ LIST_SQL_TAGGED_TAIL;

    /// Optional `/list` filters — every field ANDs onto the base shape.
    /// The zero value means "no filter" throughout, so a default-inited
    /// struct is the unfiltered list.
    pub const ListFilter = struct {
        /// Inclusive status range; `(0, 0)` = no status filter. An
        /// exact match is `min == max`; a class ("5xx") is `500..599`.
        status_min: u16 = 0,
        status_max: u16 = 0,
        /// `outcome != 'ok'` — the `log_idx_failure` partial-index
        /// predicate, spelled as the same literal so the planner can
        /// match it.
        failures_only: bool = false,
        /// Exact method match (as logged, e.g. "GET").
        method: ?[]const u8 = null,
        /// Exact activation-kind match (e.g. "inbound", "ws_message").
        activation: ?[]const u8 = null,
        /// Case-sensitive substring of the request path (`instr`) —
        /// paths are case-sensitive, and `instr` sidesteps LIKE's
        /// wildcard/ESCAPE surface entirely.
        path_contains: ?[]const u8 = null,

        pub fn any(self: *const ListFilter) bool {
            return self.status_min != 0 or self.status_max != 0 or
                self.failures_only or self.method != null or
                self.activation != null or self.path_contains != null;
        }
    };

    /// Parameter indices a built filter statement binds its values at —
    /// 0 = the clause is absent. Filled by `buildListSql`.
    const FilterParams = struct {
        status: u8 = 0, // binds min at .status, max at .status + 1
        method: u8 = 0,
        activation: u8 = 0,
        path: u8 = 0,
    };

    /// Compose the list statement for one exact filter shape:
    /// HEAD ++ (one AND clause per present filter) ++ TAIL. Each shape
    /// is its own SQL text, so SQLite plans it precisely — the
    /// tenant-prefixed indices keep every shape a SEARCH (the plan
    /// tests below pin that). Caller frees the returned SQL.
    fn buildListSql(
        allocator: std.mem.Allocator,
        tagged: bool,
        filter: *const ListFilter,
        params: *FilterParams,
    ) ![:0]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        const col = if (tagged) "li." else "";
        // ?1..?5 are shared; the tagged head also uses ?6/?7.
        var p: u8 = if (tagged) 8 else 6;
        try buf.appendSlice(allocator, if (tagged) LIST_SQL_TAGGED_HEAD else LIST_SQL_UNTAGGED_HEAD);
        const w = buf.writer(allocator);
        if (filter.status_min != 0 or filter.status_max != 0) {
            params.status = p;
            try w.print("\n  AND {s}status BETWEEN ?{d} AND ?{d}", .{ col, p, p + 1 });
            p += 2;
        }
        if (filter.failures_only) {
            try w.print("\n  AND {s}outcome != 'ok'", .{col});
        }
        if (filter.method != null) {
            params.method = p;
            try w.print("\n  AND {s}method = ?{d}", .{ col, p });
            p += 1;
        }
        if (filter.activation != null) {
            params.activation = p;
            try w.print("\n  AND {s}activation = ?{d}", .{ col, p });
            p += 1;
        }
        if (filter.path_contains != null) {
            params.path = p;
            try w.print("\n  AND instr({s}path, ?{d}) > 0", .{ col, p });
            p += 1;
        }
        try buf.appendSlice(allocator, if (tagged) LIST_SQL_TAGGED_TAIL else LIST_SQL_UNTAGGED_TAIL);
        return buf.toOwnedSliceSentinel(allocator, 0);
    }

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
        /// Optional column filters (status/failures/method/activation/
        /// path). `.{}` = unfiltered.
        filter: ListFilter,
    ) Error!ListResult {
        // Two base statements, not one with a conditional tag clause —
        // see LIST_SQL_TAGGED for why the conditional spelling can't be
        // planned. Column filters splice per-shape via buildListSql,
        // same discipline: every shape is its own exact SQL text.
        const tagged = tag_key != null and tag_value != null;
        var fparams: FilterParams = .{};
        const built: ?[:0]u8 = if (filter.any())
            buildListSql(self.allocator, tagged, &filter, &fparams) catch return Error.OutOfMemory
        else
            null;
        defer if (built) |b| self.allocator.free(b);
        const sql: [:0]const u8 = built orelse
            (if (tagged) LIST_SQL_TAGGED else LIST_SQL_UNTAGGED);
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, after_received_ns);
        _ = c.sqlite3_bind_int64(st, 3, @intCast(after_request_id));
        _ = c.sqlite3_bind_int64(st, 4, @intCast(limit));
        _ = c.sqlite3_bind_int64(st, 5, floor_received_ns);
        if (tagged) {
            // ?6/?7 exist only in the tagged statement; binding them on
            // the untagged one would be out of range.
            bindText(st.?, 6, tag_key.?);
            bindText(st.?, 7, tag_value.?);
        }
        if (fparams.status != 0) {
            _ = c.sqlite3_bind_int(st, fparams.status, filter.status_min);
            _ = c.sqlite3_bind_int(st, fparams.status + 1, filter.status_max);
        }
        if (fparams.method != 0) bindText(st.?, fparams.method, filter.method.?);
        if (fparams.activation != 0) bindText(st.?, fparams.activation, filter.activation.?);
        if (fparams.path != 0) bindText(st.?, fparams.path, filter.path_contains.?);

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
                // NULL (pre-migration row) reads back as "" — the
                // unknown-kind sentinel.
                .activation = try dupeColumnText(self.allocator, st.?, 10),
                // NULL (unstamped / pre-migration) reads back as 0.
                .exec_seq = @intCast(c.sqlite3_column_int64(st, 11)),
            };
            rows.append(self.allocator, row) catch return Error.OutOfMemory;
        }
        return .{
            .rows = rows.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
            .allocator = self.allocator,
        };
    }

    /// The seq-window statement — the tape view. Ascending over
    /// `exec_seq` (execution order), which `/list`'s time view cannot
    /// provide: wall-clock ordering breaks across leader failover, and
    /// the saga viewer's window/gap/blame questions all key on the
    /// stamp. Same keyset-cursor discipline as the list statements;
    /// `exec_seq` is unique per tenant, so the cursor is the single
    /// `?2` bound (strictly-greater-than). Unstamped rows carry NULL
    /// and are skipped by the `IS NOT NULL` predicate (which also
    /// matches `log_idx_exec`'s partial-index predicate). ?5 is the
    /// same retention read-clamp `/list` applies.
    const WINDOW_SQL: [:0]const u8 =
        \\SELECT tenant_id, request_id, received_ns, duration_ns, method, path, host,
        \\       status, outcome, deployment_id, activation, exec_seq
        \\FROM log_index
        \\WHERE tenant_id = ?1
        \\  AND exec_seq IS NOT NULL
        \\  AND exec_seq > ?2
        \\  AND (?3 = 0 OR exec_seq <= ?3)
        \\  AND (?5 = 0 OR received_ns >= ?5)
        \\ORDER BY exec_seq ASC
        \\LIMIT ?4
    ;

    /// Execution-tape window for `tenant_id`: records with
    /// `after_seq < exec_seq <= to_seq`, ascending. `to_seq = 0` means
    /// unbounded above. Pagination: pass the previous page's last
    /// `exec_seq` as `after_seq` (an inclusive `seq_from` is
    /// `seq_from - 1` here — callers own that conversion).
    /// `floor_received_ns` is the retention read-clamp, as in
    /// `queryList`.
    pub fn queryWindow(
        self: *IndexDb,
        tenant_id: []const u8,
        after_seq: u64,
        to_seq: u64,
        floor_received_ns: i64,
        limit: u32,
    ) Error!ListResult {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, WINDOW_SQL.ptr, @intCast(WINDOW_SQL.len), &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, @intCast(after_seq));
        _ = c.sqlite3_bind_int64(st, 3, @intCast(to_seq));
        _ = c.sqlite3_bind_int64(st, 4, @intCast(limit));
        _ = c.sqlite3_bind_int64(st, 5, floor_received_ns);

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
                .deployment_id = @bitCast(c.sqlite3_column_int64(st, 9)),
                .activation = try dupeColumnText(self.allocator, st.?, 10),
                .exec_seq = @intCast(c.sqlite3_column_int64(st, 11)),
            };
            rows.append(self.allocator, row) catch return Error.OutOfMemory;
        }
        return .{
            .rows = rows.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
            .allocator = self.allocator,
        };
    }

    /// One saga in a saga-list response — the roll-up row, not its
    /// activations. `closed_at_ns` is 0 for "no close was seen"; see
    /// `execSagaUpsert` for why that is not the same as "still live".
    pub const SagaRow = struct {
        corr_id: []u8,
        first_received_ns: i64,
        last_received_ns: i64,
        activation_count: u64,
        root_method: []u8,
        root_path: []u8,
        root_host: []u8,
        last_status: u16,
        last_outcome: []u8,
        error_count: u64,
        closed_at_ns: i64,

        pub fn deinit(self: *SagaRow, a: std.mem.Allocator) void {
            a.free(self.corr_id);
            a.free(self.root_method);
            a.free(self.root_path);
            a.free(self.root_host);
            a.free(self.last_outcome);
        }
    };

    pub const SagaListResult = struct {
        rows: []SagaRow,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *SagaListResult) void {
            for (self.rows) |*r| r.deinit(self.allocator);
            self.allocator.free(self.rows);
        }
    };

    /// Sagas for `tenant_id`, most-recently-active first. Cursor is
    /// `(after_last_received_ns, after_saga_id)` from the previous
    /// page's tail; `(0, "")` starts at the newest.
    ///
    /// Index-only against `log_sagas_recent` — the whole reason the
    /// roll-up row is materialized. The natural alternative,
    /// `GROUP BY value ORDER BY MAX(received_ns)` over `log_tags`,
    /// reads every tag row in the window AND cannot be keyset-paginated
    /// at all, because its sort key is an aggregate.
    ///
    /// **Rows accumulate forward only — there is no backfill.** The
    /// table is built by the indexer as records arrive, so an index
    /// that already held records when the table was created lists no
    /// sagas for them. Their *activations* stay fully queryable by
    /// saga id (the tag-filtered record list); it is only the
    /// enumeration of past sagas that starts empty and fills with new
    /// traffic. Reconstructing them means a one-time grouped pass over
    /// `log_tags` + `log_index` whose cost scales with the whole
    /// retained window — deliberately not paid at open, where it would
    /// block the log-server's startup for as long as that takes.
    ///
    /// `floor_received_ns` is the same retention read-clamp the record
    /// list applies, on `last_received_ns`: a saga whose every
    /// activation predates the floor has nothing left to show, so
    /// listing it would offer a row that opens empty.
    pub fn querySagas(
        self: *IndexDb,
        tenant_id: []const u8,
        after_last_received_ns: i64,
        after_saga_id: []const u8,
        floor_received_ns: i64,
        limit: u32,
    ) Error!SagaListResult {
        const sql =
            \\SELECT corr_id, first_received_ns, last_received_ns, activation_count,
            \\       root_method, root_path, root_host, last_status, last_outcome,
            \\       error_count, closed_at_ns
            \\FROM log_sagas
            \\WHERE tenant_id = ?1
            \\  AND (?2 = 0 OR
            \\       last_received_ns < ?2 OR
            \\       (last_received_ns = ?2 AND corr_id < ?3))
            \\  AND (?4 = 0 OR last_received_ns >= ?4)
            \\ORDER BY last_received_ns DESC, corr_id DESC
            \\LIMIT ?5
        ;
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &st, null) != c.SQLITE_OK)
            return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        bindText(st.?, 1, tenant_id);
        _ = c.sqlite3_bind_int64(st, 2, after_last_received_ns);
        bindText(st.?, 3, after_saga_id);
        _ = c.sqlite3_bind_int64(st, 4, floor_received_ns);
        _ = c.sqlite3_bind_int64(st, 5, @intCast(limit));

        var rows: std.ArrayListUnmanaged(SagaRow) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(self.allocator);
            rows.deinit(self.allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(st);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return Error.Sqlite;
            const row: SagaRow = .{
                .corr_id = try dupeColumnText(self.allocator, st.?, 0),
                .first_received_ns = c.sqlite3_column_int64(st, 1),
                .last_received_ns = c.sqlite3_column_int64(st, 2),
                .activation_count = @intCast(c.sqlite3_column_int64(st, 3)),
                .root_method = try dupeColumnText(self.allocator, st.?, 4),
                .root_path = try dupeColumnText(self.allocator, st.?, 5),
                .root_host = try dupeColumnText(self.allocator, st.?, 6),
                .last_status = @intCast(c.sqlite3_column_int(st, 7)),
                .last_outcome = try dupeColumnText(self.allocator, st.?, 8),
                .error_count = @intCast(c.sqlite3_column_int64(st, 9)),
                // NULL → 0, the "no close seen" sentinel.
                .closed_at_ns = c.sqlite3_column_int64(st, 10),
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
        \\ activation, exec_seq, ndjson_key, offset, length)
        \\VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ;
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
    defer _ = c.sqlite3_finalize(st);

    // The saga roll-up rides this loop rather than a second pass,
    // because it must fire ONLY for a record the index actually
    // accepted — `activation_count` is a running total with no primary
    // key to protect it, so a re-indexed batch would inflate every
    // count it touched. `log_index`'s PK gives us that signal here and
    // nowhere else.
    var saga_st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, SAGA_UPSERT_SQL.ptr, -1, &saga_st, null) != c.SQLITE_OK) return Error.Sqlite;
    defer _ = c.sqlite3_finalize(saga_st);

    for (idx.records) |r| {
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_clear_bindings(st);
        // Each record carries its own tenant_id under the
        // interleaved-per-node layout. The indexer demuxes here so
        // log_index stays per-tenant.
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
        // An older sidecar carries no activation kind. Store NULL, not
        // '', so "this index predates the field" stays distinguishable
        // from a kind that was recorded — see `sidecar.Record`.
        if (r.activation.len > 0) bindText(st.?, 11, r.activation) else _ = c.sqlite3_bind_null(st, 11);
        // 0 = unstamped: store NULL so the record has no place on the
        // tape (the partial seq index skips it) rather than a fake
        // position 0. The publish guard keeps real stamps < 2^63, so the
        // i64 cast can't flip sign and break the index order.
        if (r.exec_seq != 0) _ = c.sqlite3_bind_int64(st, 12, @intCast(r.exec_seq)) else _ = c.sqlite3_bind_null(st, 12);
        bindText(st.?, 13, ndjson_key);
        _ = c.sqlite3_bind_int64(st, 14, @intCast(r.offset + header_size));
        _ = c.sqlite3_bind_int(st, 15, @intCast(r.length));
        if (c.sqlite3_step(st) != c.SQLITE_DONE) return Error.Sqlite;

        // `INSERT OR IGNORE` swallows a primary-key clash, and the two things
        // it can be swallowing are opposites. Ask which one happened.
        if (c.sqlite3_changes(db) == 0) {
            classifyIgnored(db, r, ndjson_key, header_size);
        } else {
            // Accepted, so it is exactly one new activation of its saga.
            // A record with no saga id has no saga to roll up
            // (early-error captures before request handling started).
            if (r.saga_id.len > 0) try execSagaUpsert(saga_st.?, r);
        }
    }
}

/// Fold one accepted record into its saga's roll-up row.
///
/// **Order-independent by construction.** The indexer walks S3 batches
/// per node, and a saga's connectionless hops (`fireChainedActivation`,
/// `send_callback`) can be logged by a different node than the one
/// holding the connection — so records do NOT arrive in saga order, and
/// this must produce the same row whichever order they land in. Hence
/// MIN/MAX on the timestamps and a `CASE` on every field that describes
/// a specific end of the saga: the root columns move only for a record
/// that is genuinely earlier, the `last_*` columns only for one that is
/// genuinely later. A plain "last writer wins" makes saga rows flicker
/// their identity as late batches arrive — visible only in production,
/// under multi-node, days later.
///
/// SQLite evaluates every `DO UPDATE SET` right-hand side against the
/// PRE-update row, so the `CASE`s comparing against `first_received_ns`
/// see the old value even though the same statement also assigns it.
/// The clause order is therefore not load-bearing.
///
/// `closed_at_ns` takes the first close seen and keeps it
/// (`COALESCE`), so a replayed batch cannot move a saga's end.
const SAGA_UPSERT_SQL: [:0]const u8 =
    \\INSERT INTO log_sagas
    \\  (tenant_id, corr_id, first_received_ns, last_received_ns, activation_count,
    \\   root_method, root_path, root_host, last_status, last_outcome,
    \\   error_count, closed_at_ns)
    \\VALUES (?1,?2,?3,?3,1,?4,?5,?6,?7,?8,?9,?10)
    \\ON CONFLICT(tenant_id, corr_id) DO UPDATE SET
    \\  first_received_ns = MIN(first_received_ns, excluded.first_received_ns),
    \\  last_received_ns  = MAX(last_received_ns,  excluded.last_received_ns),
    \\  activation_count  = activation_count + 1,
    \\  error_count       = error_count + excluded.error_count,
    \\  root_method  = CASE WHEN excluded.first_received_ns < first_received_ns
    \\                      THEN excluded.root_method  ELSE root_method  END,
    \\  root_path    = CASE WHEN excluded.first_received_ns < first_received_ns
    \\                      THEN excluded.root_path    ELSE root_path    END,
    \\  root_host    = CASE WHEN excluded.first_received_ns < first_received_ns
    \\                      THEN excluded.root_host    ELSE root_host    END,
    \\  last_status  = CASE WHEN excluded.last_received_ns > last_received_ns
    \\                      THEN excluded.last_status  ELSE last_status  END,
    \\  last_outcome = CASE WHEN excluded.last_received_ns > last_received_ns
    \\                      THEN excluded.last_outcome ELSE last_outcome END,
    \\  closed_at_ns = COALESCE(closed_at_ns, excluded.closed_at_ns)
;

fn execSagaUpsert(st: *c.sqlite3_stmt, r: sidecar.Record) Error!void {
    _ = c.sqlite3_reset(st);
    _ = c.sqlite3_clear_bindings(st);
    bindText(st, 1, r.tenant_id);
    bindText(st, 2, r.saga_id);
    _ = c.sqlite3_bind_int64(st, 3, r.received_ns);
    bindText(st, 4, r.method);
    bindText(st, 5, r.path);
    bindText(st, 6, r.host);
    _ = c.sqlite3_bind_int(st, 7, @intCast(r.status));
    bindText(st, 8, r.outcome);
    _ = c.sqlite3_bind_int64(st, 9, if (std.mem.eql(u8, r.outcome, "ok")) 0 else 1);
    // A `disconnect` activation is a saga's explicit end. NULL
    // otherwise — and NULL forever is the NORMAL case for plenty of
    // sagas (a crashed worker, an abandoned upload session, a chain
    // that simply stops), so a reader must treat NULL as "no close was
    // seen", never as "still live". Idle is derived at read time from
    // `last_received_ns`; nothing sweeps these rows.
    if (std.mem.eql(u8, r.activation, "disconnect"))
        _ = c.sqlite3_bind_int64(st, 10, r.received_ns)
    else
        _ = c.sqlite3_bind_null(st, 10);
    if (c.sqlite3_step(st) != c.SQLITE_DONE) return Error.Sqlite;
}

/// A record the index refused. Same record arriving again, or a genuine
/// identity collision?
///
/// `(tenant_id, request_id)` is the primary key, and it is only unique within
/// one run of a tenant's counter — a fresh cluster lifetime re-issues the same
/// numbers (rove#266). So an ignored insert means EITHER "this record is
/// already indexed" (routine) OR "a different request already owns this
/// identity" (the new record is dropped and can never be queried or replayed;
/// data loss). Those need opposite reactions.
///
/// The discriminator is `received_ns` — the request's own arrival time — NOT
/// where the record is stored. A record legitimately arrives in more than one
/// object: the promotion-time LogRecord walker re-emits already-flushed
/// records so they survive a leader dying mid-flush, so the same request shows
/// up under a later batch key at a different offset. Keying on storage
/// location classified every one of those as loss — 111 phantom conflicts on
/// one node within minutes of deploying, which would have fired an alert that
/// then got ignored, which is the failure this metric exists to avoid.
fn classifyIgnored(
    db: *c.sqlite3,
    r: sidecar.Record,
    ndjson_key: []const u8,
    header_size: u64,
) void {
    var q: ?*c.sqlite3_stmt = null;
    const sql = "SELECT ndjson_key, offset, received_ns FROM log_index WHERE tenant_id = ? AND request_id = ?";
    if (c.sqlite3_prepare_v2(db, sql, -1, &q, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(q);
    bindText(q.?, 1, r.tenant_id);
    _ = c.sqlite3_bind_int64(q, 2, @intCast(r.request_id));
    if (c.sqlite3_step(q) != c.SQLITE_ROW) return;

    const held_key_ptr = c.sqlite3_column_text(q, 0);
    const held_key: []const u8 = if (held_key_ptr) |p|
        std.mem.span(@as([*:0]const u8, @ptrCast(p)))
    else
        "";
    const held_offset: u64 = @intCast(c.sqlite3_column_int64(q, 1));
    const held_received_ns: i64 = c.sqlite3_column_int64(q, 2);

    // `received_ns == 0` means UNKNOWN, not "epoch": the promotion-time walker
    // reconstructs records from the raft log, whose replicated header carries
    // no arrival time (`worker_upload_walker.zig`). Those re-emissions are the
    // same requests, so an incoming zero cannot be compared and must not be
    // read as "a different request" — doing so reported 78 phantom conflicts
    // on one node, every one of them a re-emit of a record the index already
    // held with its real timestamp.
    if (r.received_ns == 0 or held_received_ns == r.received_ns) {
        // Same request, arriving again — from the poll path's clock-skew
        // window, a resume after a crash, or the promotion walker re-emitting
        // it into a later batch. Already indexed; nothing is lost.
        metrics.Metrics.inc(&metrics.global.index_reindexed);
        return;
    }

    metrics.Metrics.inc(&metrics.global.index_conflicts);
    // Warn, not err: an error-level log fails any test that drives this path
    // (rove#274), and this one is worth testing. The counter is the alertable
    // signal; the log names the two objects so the loss is diagnosable.
    std.log.warn(
        "log-index CONFLICT: {s}/{d} already held by a DIFFERENT request (received_ns {d}, at {s}@{d}); " ++
            "DROPPING the record received_ns {d} at {s}@{d} — it is unqueryable and unreplayable (rove#266).",
        .{
            r.tenant_id,   r.request_id, held_received_ns, held_key, held_offset,
            r.received_ns, ndjson_key,   r.offset + header_size,
        },
    );
}

/// Reserved tag key: the engine-populated per-saga id. `request.tag`
/// rejects `_`-prefixed keys, so this can't collide with a user tag.
/// Lets `?tag._saga=<id>` filter to one saga's activations even when
/// the handler set no `session` tag of its own.
pub const RESERVED_SAGA_TAG = "_saga";

/// The retired spelling. Rows written before the rename carry it, and
/// `migrate` rewrites them in place — this constant exists so that
/// migration has a name for what it is looking for, not as a fallback
/// on the read path. Nothing writes it.
pub const RETIRED_CORR_TAG = "_corr";

/// Insert each record's user tags (+ the reserved `_saga` tag derived
/// from its saga id) into `log_tags`. `INSERT OR IGNORE` on the
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
        if (r.saga_id.len > 0)
            try bindTagRow(st.?, r.tenant_id, r.request_id, RESERVED_SAGA_TAG, r.saga_id, r.received_ns);
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

    var list = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{});
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.rows.len);
    // Newest first.
    try testing.expectEqual(@as(u64, 101), list.rows[0].request_id);
    try testing.expectEqual(@as(u64, 100), list.rows[1].request_id);
    try testing.expectEqualStrings("/b", list.rows[0].path);
    try testing.expectEqualStrings("handler_error", list.rows[0].outcome);

    // Pagination: cursor at (received_ns=2000, id=101) returns the
    // older row only.
    var p2 = try idx.queryList("acme", 2_000, 101, 0, 10, null, null, .{});
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 1), p2.rows.len);
    try testing.expectEqual(@as(u64, 100), p2.rows[0].request_id);

    // Retention read-clamp (Lever 3): a floor of 1500 hides the
    // received_ns=1000 record, leaving only the 2000 one — in list AND count.
    var clamped = try idx.queryList("acme", 0, 0, 1_500, 10, null, null, .{});
    defer clamped.deinit();
    try testing.expectEqual(@as(usize, 1), clamped.rows.len);
    try testing.expectEqual(@as(u64, 101), clamped.rows[0].request_id);
    try testing.expectEqual(@as(u64, 2), try idx.queryCount("acme", 0)); // no clamp
    try testing.expectEqual(@as(u64, 1), try idx.queryCount("acme", 1_500)); // clamped
}

test "queryWindow walks the tape in exec_seq order, skipping unstamped rows" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "window");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    // Stamps deliberately DISAGREE with received_ns order (a failover
    // reordering wall-clock is the whole reason the stamp exists): the
    // record received last carries the middle stamp. Term 7 base.
    const t7: u64 = 7 << 40;
    var records = [_]sidecar.Record{
        .{ .tenant_id = "acme", .request_id = 1, .received_ns = 3_000, .duration_ns = 1, .method = "GET", .path = "/b", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .exec_seq = t7 + 2, .offset = 0, .length = 1 },
        .{ .tenant_id = "acme", .request_id = 2, .received_ns = 1_000, .duration_ns = 1, .method = "GET", .path = "/a", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .exec_seq = t7 + 1, .offset = 1, .length = 1 },
        .{ .tenant_id = "acme", .request_id = 3, .received_ns = 2_000, .duration_ns = 1, .method = "GET", .path = "/c", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .exec_seq = t7 + 3, .offset = 2, .length = 1 },
        // Unstamped (a pre-dispatch reject): no place on the tape.
        .{ .tenant_id = "acme", .request_id = 4, .received_ns = 2_500, .duration_ns = 1, .method = "GET", .path = "/r", .host = "h", .status = 429, .outcome = "handler_error", .deployment_id = 1, .exec_seq = 0, .offset = 3, .length = 1 },
        // Another tenant's stamp in the same numeric range must not leak.
        .{ .tenant_id = "other", .request_id = 5, .received_ns = 1_500, .duration_ns = 1, .method = "GET", .path = "/o", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .exec_seq = t7 + 2, .offset = 4, .length = 1 },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "00000000000000000200-1730764800000",
        .ndjson_size = 5,
        .ndjson_sha256 = "deadbeef",
        .first_received_ns = 1_000,
        .last_received_ns = 3_000,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/w.ndjson", 0);

    // Whole tape: execution order, not arrival order; unstamped skipped.
    var w = try idx.queryWindow("acme", 0, 0, 0, 10);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 3), w.rows.len);
    try testing.expectEqual(@as(u64, 2), w.rows[0].request_id);
    try testing.expectEqual(@as(u64, 1), w.rows[1].request_id);
    try testing.expectEqual(@as(u64, 3), w.rows[2].request_id);
    try testing.expectEqual(t7 + 1, w.rows[0].exec_seq);

    // Keyset cursor: strictly after the first stamp.
    var p2 = try idx.queryWindow("acme", t7 + 1, 0, 0, 10);
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 2), p2.rows.len);
    try testing.expectEqual(t7 + 2, p2.rows[0].exec_seq);

    // Bounded window [t7+1, t7+2].
    var bounded = try idx.queryWindow("acme", t7, t7 + 2, 0, 10);
    defer bounded.deinit();
    try testing.expectEqual(@as(usize, 2), bounded.rows.len);
    try testing.expectEqual(t7 + 2, bounded.rows[1].exec_seq);

    // The retention read-clamp applies to the tape view too.
    var clamped = try idx.queryWindow("acme", 0, 0, 1_500, 10);
    defer clamped.deinit();
    try testing.expectEqual(@as(usize, 2), clamped.rows.len);
    try testing.expectEqual(@as(u64, 1), clamped.rows[0].request_id);
}

test "queryList filters by tag (user session + reserved _saga)" {
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
        .{ .tenant_id = "acme", .request_id = 1, .received_ns = 1_000, .duration_ns = 1, .method = "GET", .path = "/a", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .saga_id = "C1", .tags = &tags_a, .offset = 0, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 2, .received_ns = 2_000, .duration_ns = 1, .method = "GET", .path = "/b", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .saga_id = "C1", .tags = &tags_b, .offset = 10, .length = 10 },
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
    var s1 = try idx.queryList("acme", 0, 0, 0, 10, "session", "S1", .{});
    defer s1.deinit();
    try testing.expectEqual(@as(usize, 1), s1.rows.len);
    try testing.expectEqual(@as(u64, 1), s1.rows[0].request_id);

    // Reserved _saga tag is auto-derived from saga_id → both rows
    // share C1, so the engine session key returns the whole connection.
    var c1 = try idx.queryList("acme", 0, 0, 0, 10, "_saga", "C1", .{});
    defer c1.deinit();
    try testing.expectEqual(@as(usize, 2), c1.rows.len);

    // Unknown tag value → no rows (not an error).
    var none = try idx.queryList("acme", 0, 0, 0, 10, "session", "nope", .{});
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.rows.len);
}

/// Concatenated `detail` column of `EXPLAIN QUERY PLAN <sql>`. SQLite
/// fixes the plan at prepare time without consulting bound values, so
/// the shape can be inspected without binding anything.
fn explainQueryPlan(a: std.mem.Allocator, db: *c.sqlite3, sql: [:0]const u8) ![]u8 {
    const eqp = try std.fmt.allocPrintSentinel(a, "EXPLAIN QUERY PLAN {s}", .{sql}, 0);
    defer a.free(eqp);
    var st: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, eqp.ptr, -1, &st, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(st);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    while (c.sqlite3_step(st) == c.SQLITE_ROW) {
        const txt = c.sqlite3_column_text(st, 3) orelse continue;
        try out.appendSlice(a, std.mem.span(@as([*:0]const u8, @ptrCast(txt))));
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

test "the tag-filtered list drives from log_tags, never a tenant-window scan" {
    // A plan-shape guard, not a timing test: timings are flaky, and the
    // plan is what regressed. The prior spelling folded the tag filter
    // into the untagged statement as `(?6 IS NULL OR EXISTS (…))`,
    // which SQLite cannot flatten into a semi-join — so it scanned the
    // tenant's whole window and probed `log_tags` per row (2 s vs 0 ms
    // on a 2M-record index, worst on SMALL results, which never fill
    // the LIMIT and so scan to the retention floor).
    //
    // No ANALYZE here, deliberately: production never runs it
    // (`log_index.db` has no `sqlite_stat1`), so the planner must reach
    // the right shape from the schema alone, which is the condition
    // this pins.
    const a = testing.allocator;
    const db_path = try tempPath(a, "plan");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    const tagged = try explainQueryPlan(a, idx.db, IndexDb.LIST_SQL_TAGGED);
    defer a.free(tagged);

    // Drives from the tag index built for this lookup...
    try testing.expect(std.mem.indexOf(u8, tagged, "log_tags_lookup") != null);
    // ...and reaches log_index by primary key, one probe per matched row.
    try testing.expect(std.mem.indexOf(u8, tagged, "sqlite_autoindex_log_index_1") != null);
    // The two regression signatures of the old spelling. `SCAN` is
    // SQLite's word for a full table/index walk (as opposed to
    // `SEARCH`), and a re-correlated subquery means the filter stopped
    // being a join again.
    try testing.expect(std.mem.indexOf(u8, tagged, "SCAN") == null);
    try testing.expect(std.mem.indexOf(u8, tagged, "CORRELATED") == null);

    // The untagged list keeps its own plan: the (tenant_id,
    // received_ns DESC) index, whose head satisfies the LIMIT directly.
    const untagged = try explainQueryPlan(a, idx.db, IndexDb.LIST_SQL_UNTAGGED);
    defer a.free(untagged);
    try testing.expect(std.mem.indexOf(u8, untagged, "log_idx_recv") != null);
    try testing.expect(std.mem.indexOf(u8, untagged, "log_tags") == null);
}

test "list filters narrow by status, failures, method, activation, and path" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "filters");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var records = [_]sidecar.Record{
        .{ .tenant_id = "acme", .request_id = 1, .received_ns = 1_000, .duration_ns = 1, .method = "GET", .path = "/api/checkout", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .saga_id = "C1", .activation = "inbound", .offset = 0, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 2, .received_ns = 2_000, .duration_ns = 1, .method = "POST", .path = "/api/checkout", .host = "h", .status = 500, .outcome = "fault", .deployment_id = 1, .saga_id = "C1", .activation = "inbound", .offset = 10, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 3, .received_ns = 3_000, .duration_ns = 1, .method = "GET", .path = "/static/logo.png", .host = "h", .status = 404, .outcome = "ok", .deployment_id = 1, .saga_id = "", .activation = "inbound", .offset = 20, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 4, .received_ns = 4_000, .duration_ns = 1, .method = "GET", .path = "/ws", .host = "h", .status = 0, .outcome = "ok", .deployment_id = 1, .saga_id = "", .activation = "ws_message", .offset = 30, .length = 10 },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "filterbatch",
        .ndjson_size = 40,
        .ndjson_sha256 = "d",
        .first_received_ns = 1_000,
        .last_received_ns = 4_000,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/filterbatch.ndjson", 0);

    // Status class 5xx → only the 500.
    var fivexx = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .status_min = 500, .status_max = 599 });
    defer fivexx.deinit();
    try testing.expectEqual(@as(usize, 1), fivexx.rows.len);
    try testing.expectEqual(@as(u64, 2), fivexx.rows[0].request_id);

    // Exact status.
    var exact = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .status_min = 404, .status_max = 404 });
    defer exact.deinit();
    try testing.expectEqual(@as(usize, 1), exact.rows.len);
    try testing.expectEqual(@as(u64, 3), exact.rows[0].request_id);

    // Failures = outcome != 'ok' — catches the fault regardless of status.
    var fails = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .failures_only = true });
    defer fails.deinit();
    try testing.expectEqual(@as(usize, 1), fails.rows.len);
    try testing.expectEqual(@as(u64, 2), fails.rows[0].request_id);

    // Method + activation exact matches.
    var post = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .method = "POST" });
    defer post.deinit();
    try testing.expectEqual(@as(usize, 1), post.rows.len);
    var ws = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .activation = "ws_message" });
    defer ws.deinit();
    try testing.expectEqual(@as(usize, 1), ws.rows.len);
    try testing.expectEqual(@as(u64, 4), ws.rows[0].request_id);

    // Path substring, newest-first ordering preserved.
    var checkout = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .path_contains = "checkout" });
    defer checkout.deinit();
    try testing.expectEqual(@as(usize, 2), checkout.rows.len);
    try testing.expectEqual(@as(u64, 2), checkout.rows[0].request_id);
    try testing.expectEqual(@as(u64, 1), checkout.rows[1].request_id);

    // Filters compose (AND).
    var combo = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{ .status_min = 200, .status_max = 299, .path_contains = "checkout" });
    defer combo.deinit();
    try testing.expectEqual(@as(usize, 1), combo.rows.len);
    try testing.expectEqual(@as(u64, 1), combo.rows[0].request_id);

    // Filters compose with the TAGGED shape (a saga narrowed to its failures).
    var sagafail = try idx.queryList("acme", 0, 0, 0, 10, RESERVED_SAGA_TAG, "C1", .{ .failures_only = true });
    defer sagafail.deinit();
    try testing.expectEqual(@as(usize, 1), sagafail.rows.len);
    try testing.expectEqual(@as(u64, 2), sagafail.rows[0].request_id);
}

test "every filter shape stays a SEARCH — no tenant-window table scan" {
    // Same discipline as the tag-plan test above: pin the plan shape,
    // no ANALYZE (production has no sqlite_stat1). Every filtered shape
    // must still enter log_index through a tenant-prefixed index — a
    // filter that degrades the list to a table SCAN would make "find my
    // request" cost the whole table, not the tenant's window.
    const a = testing.allocator;
    const db_path = try tempPath(a, "filterplan");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    const shapes = [_]IndexDb.ListFilter{
        .{ .status_min = 500, .status_max = 599 },
        .{ .failures_only = true },
        .{ .path_contains = "x" },
        .{ .method = "GET", .activation = "inbound" },
        .{ .status_min = 200, .status_max = 299, .failures_only = true, .method = "GET", .activation = "inbound", .path_contains = "x" },
    };
    for (shapes) |f| {
        var params: IndexDb.FilterParams = .{};
        const sql = try IndexDb.buildListSql(a, false, &f, &params);
        defer a.free(sql);
        const plan = try explainQueryPlan(a, idx.db, sql);
        defer a.free(plan);
        try testing.expect(std.mem.indexOf(u8, plan, "SCAN") == null);
        try testing.expect(std.mem.indexOf(u8, plan, "SEARCH log_index") != null);
    }

    // The tagged shape keeps driving from log_tags with filters spliced in.
    var params: IndexDb.FilterParams = .{};
    const f: IndexDb.ListFilter = .{ .status_min = 500, .status_max = 599, .failures_only = true };
    const sql = try IndexDb.buildListSql(a, true, &f, &params);
    defer a.free(sql);
    const plan = try explainQueryPlan(a, idx.db, sql);
    defer a.free(plan);
    try testing.expect(std.mem.indexOf(u8, plan, "log_tags_lookup") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "SCAN") == null);
    try testing.expect(std.mem.indexOf(u8, plan, "CORRELATED") == null);
}

test "a tag row's received_ns equals its record's — the tagged cursor depends on it" {
    // LIST_SQL_TAGGED applies the pagination cursor and the retention
    // clamp to `log_tags.received_ns` because that is the driving
    // table, while the cursor handed back to the caller comes from the
    // `log_index` row. The two are the same value only because
    // `bindTagRow` denormalizes the record's own `received_ns` onto
    // every tag row. If that ever diverges, paging silently skips or
    // repeats rows at page boundaries, so pin it here.
    const a = testing.allocator;
    const db_path = try tempPath(a, "tagns");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var tags = [_]sidecar.Tag{.{ .key = "session", .value = "S1" }};
    var records = [_]sidecar.Record{
        .{ .tenant_id = "acme", .request_id = 7, .received_ns = 4_242, .duration_ns = 1, .method = "GET", .path = "/a", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .saga_id = "C9", .tags = &tags, .offset = 0, .length = 10 },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "nsbatch",
        .ndjson_size = 10,
        .ndjson_sha256 = "d",
        .first_received_ns = 4_242,
        .last_received_ns = 4_242,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/nsbatch.ndjson", 0);

    var st: ?*c.sqlite3_stmt = null;
    const sql =
        \\SELECT COUNT(*) FROM log_tags t JOIN log_index li
        \\  ON li.tenant_id = t.tenant_id AND li.request_id = t.request_id
        \\ WHERE t.received_ns != li.received_ns
    ;
    try testing.expect(c.sqlite3_prepare_v2(idx.db, sql, -1, &st, null) == c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(st);
    try testing.expect(c.sqlite3_step(st) == c.SQLITE_ROW);
    try testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(st, 0));

    // Both tag rows for the record (the user tag and the derived
    // `_saga`) carry it, so either filter pages identically.
    try testing.expectEqual(@as(usize, 2), blk: {
        var st2: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(idx.db, "SELECT COUNT(*) FROM log_tags WHERE received_ns = 4242", -1, &st2, null);
        defer _ = c.sqlite3_finalize(st2);
        _ = c.sqlite3_step(st2);
        break :blk @as(usize, @intCast(c.sqlite3_column_int64(st2, 0)));
    });
}

test "the retired _corr tag is migrated to _saga, so old sagas stay queryable" {
    // The engine's reserved tag was `_corr` before the saga rename.
    // Rows already in a deployed index carry it, and nothing on the
    // read path looks for it any more — so without this migration a
    // tenant silently loses the ability to query every saga recorded
    // before the rename.
    //
    // Migrated rather than aliased on read: an alias would put an `OR`
    // back into the tag filter, which is the exact shape SQLite cannot
    // plan (the two-statement fix, `LIST_SQL_TAGGED`).
    const a = testing.allocator;
    const db_path = try tempPath(a, "corrmig");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    // Seed a pre-rename index: rows tagged `_corr`, plus a user tag
    // that must be left alone.
    {
        var idx0 = try IndexDb.open(a, db_path);
        defer idx0.close();
        var recs = [_]sidecar.Record{
            sagaRec(1, 1_000, "C1", .{}),
            sagaRec(2, 2_000, "C1", .{ .activation = "ws_message" }),
        };
        try putBatch(idx0, "b1", &recs);
        try testing.expect(c.sqlite3_exec(
            idx0.db,
            "UPDATE log_tags SET key='_corr' WHERE key='_saga';" ++
                "INSERT OR IGNORE INTO log_tags VALUES ('acme',1,'session','S1',1000);",
            null,
            null,
            null,
        ) == c.SQLITE_OK);

        // Precondition: the new spelling finds nothing.
        var pre = try idx0.queryList("acme", 0, 0, 0, 10, RESERVED_SAGA_TAG, "C1", .{});
        defer pre.deinit();
        try testing.expectEqual(@as(usize, 0), pre.rows.len);
    }

    // Re-opening migrates.
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var post = try idx.queryList("acme", 0, 0, 0, 10, RESERVED_SAGA_TAG, "C1", .{});
    defer post.deinit();
    try testing.expectEqual(@as(usize, 2), post.rows.len);

    // The retired key is gone, not duplicated.
    var stale = try idx.queryList("acme", 0, 0, 0, 10, RETIRED_CORR_TAG, "C1", .{});
    defer stale.deinit();
    try testing.expectEqual(@as(usize, 0), stale.rows.len);

    // A user tag is untouched — the migration is scoped to the engine key.
    var user = try idx.queryList("acme", 0, 0, 0, 10, "session", "S1", .{});
    defer user.deinit();
    try testing.expectEqual(@as(usize, 1), user.rows.len);

    // Idempotent: a second open must not fail or double-write.
    var again = try IndexDb.open(a, db_path);
    defer again.close();
    var post2 = try again.queryList("acme", 0, 0, 0, 10, RESERVED_SAGA_TAG, "C1", .{});
    defer post2.deinit();
    try testing.expectEqual(@as(usize, 2), post2.rows.len);
}

test "an index_db created before the activation column is migrated in place" {
    // The failure this pins is invisible to every other test: they all
    // start from a fresh file, where `SCHEMA` supplies the column. A
    // DEPLOYED `log_index.db` has the table already, so
    // `CREATE TABLE IF NOT EXISTS` is a no-op and the new column never
    // arrives — every insert then fails on an unknown column, and the
    // log-server stops indexing. Build the hostile shape explicitly.
    const a = testing.allocator;
    const db_path = try tempPath(a, "migrate");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    // A v0 file: log_index exactly as it was before this change.
    {
        var raw: ?*c.sqlite3 = null;
        try testing.expect(c.sqlite3_open_v2(
            db_path.ptr,
            &raw,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        ) == c.SQLITE_OK);
        defer _ = c.sqlite3_close_v2(raw);
        const old_schema =
            \\CREATE TABLE log_index (
            \\    tenant_id TEXT NOT NULL, request_id INTEGER NOT NULL,
            \\    received_ns INTEGER NOT NULL, duration_ns INTEGER NOT NULL,
            \\    method TEXT, path TEXT, host TEXT, status INTEGER,
            \\    outcome TEXT, deployment_id INTEGER,
            \\    ndjson_key TEXT NOT NULL, offset INTEGER NOT NULL,
            \\    length INTEGER NOT NULL,
            \\    PRIMARY KEY (tenant_id, request_id)
            \\);
            \\INSERT INTO log_index VALUES
            \\  ('acme',1,1000,1,'GET','/old','h',200,'ok',1,'k',0,10);
        ;
        try testing.expect(c.sqlite3_exec(raw, old_schema, null, null, null) == c.SQLITE_OK);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    // Opening migrated it, and the pre-existing row reads as UNKNOWN —
    // not backfilled to 'inbound', which would invent a fact the index
    // never recorded.
    var pre = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{});
    defer pre.deinit();
    try testing.expectEqual(@as(usize, 1), pre.rows.len);
    try testing.expectEqualStrings("", pre.rows[0].activation);

    // And a record indexed after the migration carries its kind.
    var records = [_]sidecar.Record{
        .{ .tenant_id = "acme", .request_id = 2, .received_ns = 2_000, .duration_ns = 1, .method = "GET", .path = "/new", .host = "h", .status = 200, .outcome = "ok", .deployment_id = 1, .activation = "disconnect", .offset = 0, .length = 10 },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "migbatch",
        .ndjson_size = 10,
        .ndjson_sha256 = "d",
        .first_received_ns = 2_000,
        .last_received_ns = 2_000,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/migbatch.ndjson", 0);

    var post = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{});
    defer post.deinit();
    try testing.expectEqual(@as(usize, 2), post.rows.len);
    try testing.expectEqualStrings("disconnect", post.rows[0].activation);
    try testing.expectEqualStrings("", post.rows[1].activation);

    // Idempotent: re-opening an already-migrated file must not fail on
    // a duplicate-column ALTER.
    var again = try IndexDb.open(a, db_path);
    defer again.close();
    try testing.expect(try IndexDb.hasColumn(again.db, "log_index", "activation"));
}

// ── saga roll-up (#445) ───────────────────────────────────────────

/// One record of a saga. Defaults are the boring case; tests override
/// the field under examination so the interesting bit is the only thing
/// visible at the call site.
fn sagaRec(
    id: u64,
    ns: i64,
    corr: []const u8,
    opts: struct {
        method: []const u8 = "GET",
        path: []const u8 = "/",
        host: []const u8 = "h",
        status: u16 = 200,
        outcome: []const u8 = "ok",
        activation: []const u8 = "inbound",
        tenant: []const u8 = "acme",
    },
) sidecar.Record {
    return .{
        .tenant_id = opts.tenant,
        .request_id = id,
        .received_ns = ns,
        .duration_ns = 1,
        .method = opts.method,
        .path = opts.path,
        .host = opts.host,
        .status = opts.status,
        .outcome = opts.outcome,
        .deployment_id = 1,
        .saga_id = corr,
        .activation = opts.activation,
        .offset = 0,
        .length = 10,
    };
}

fn putBatch(idx: *IndexDb, batch_id: []const u8, records: []sidecar.Record) !void {
    const b = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = batch_id,
        .ndjson_size = 10,
        .ndjson_sha256 = "d",
        .first_received_ns = records[0].received_ns,
        .last_received_ns = records[records.len - 1].received_ns,
        .records = records,
    };
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "_logs/00000001/{s}.ndjson", .{batch_id});
    try idx.insertBatch(&b, key, 0);
}

test "the saga roll-up is identical whichever order its batches arrive in" {
    // THE trap. Records do not arrive in saga order — a saga's
    // connectionless hops can be logged by a different node than the
    // one holding the connection, so batches interleave arbitrarily.
    // Build the same three-activation saga twice, feeding the batches
    // in opposite orders, and require byte-identical roll-ups. A
    // "last writer wins" upsert passes the forward case and fails
    // here, which is exactly the shape that would otherwise surface in
    // production days later.
    const a = testing.allocator;

    var results: [2]struct {
        first: i64 = 0,
        last: i64 = 0,
        count: u64 = 0,
        root_path: [16]u8 = undefined,
        root_path_len: usize = 0,
        last_status: u16 = 0,
        closed: i64 = 0,
    } = .{ .{}, .{} };

    for (0..2) |variant| {
        const db_path = try tempPath(a, "sagaorder");
        defer {
            std.fs.cwd().deleteFile(db_path) catch {};
            deleteWalSidecars(db_path);
            a.free(db_path);
        }
        var idx = try IndexDb.open(a, db_path);
        defer idx.close();

        // The saga: open (earliest) → frame → close (latest).
        var early = [_]sidecar.Record{sagaRec(1, 1_000, "C1", .{ .path = "/open", .status = 101 })};
        var mid = [_]sidecar.Record{sagaRec(2, 2_000, "C1", .{ .path = "/mid", .activation = "ws_message", .status = 0 })};
        var late = [_]sidecar.Record{sagaRec(3, 3_000, "C1", .{ .path = "/close", .activation = "disconnect", .status = 0 })};

        if (variant == 0) {
            try putBatch(idx, "b1", &early);
            try putBatch(idx, "b2", &mid);
            try putBatch(idx, "b3", &late);
        } else {
            // Reverse: the close lands before the open is even indexed.
            try putBatch(idx, "b3", &late);
            try putBatch(idx, "b2", &mid);
            try putBatch(idx, "b1", &early);
        }

        var list = try idx.querySagas("acme", 0, "", 0, 10);
        defer list.deinit();
        try testing.expectEqual(@as(usize, 1), list.rows.len);
        const row = list.rows[0];
        results[variant].first = row.first_received_ns;
        results[variant].last = row.last_received_ns;
        results[variant].count = row.activation_count;
        @memcpy(results[variant].root_path[0..row.root_path.len], row.root_path);
        results[variant].root_path_len = row.root_path.len;
        results[variant].last_status = row.last_status;
        results[variant].closed = row.closed_at_ns;
    }

    const fwd = results[0];
    const rev = results[1];
    try testing.expectEqual(fwd.first, rev.first);
    try testing.expectEqual(fwd.last, rev.last);
    try testing.expectEqual(fwd.count, rev.count);
    try testing.expectEqual(fwd.last_status, rev.last_status);
    try testing.expectEqual(fwd.closed, rev.closed);
    try testing.expectEqualStrings(
        fwd.root_path[0..fwd.root_path_len],
        rev.root_path[0..rev.root_path_len],
    );

    // And the values are the RIGHT ones, not merely equal: root from
    // the earliest activation, bounds spanning the whole saga.
    try testing.expectEqual(@as(i64, 1_000), fwd.first);
    try testing.expectEqual(@as(i64, 3_000), fwd.last);
    try testing.expectEqual(@as(u64, 3), fwd.count);
    try testing.expectEqualStrings("/open", fwd.root_path[0..fwd.root_path_len]);
    try testing.expectEqual(@as(i64, 3_000), fwd.closed);
}

test "re-indexing a batch does not inflate the activation count" {
    // `activation_count` is a running total with no primary key to
    // protect it, unlike every other column the indexer writes. The
    // indexer's cursor-lag buffer re-LISTs a trailing window every
    // poll, so a batch WILL be offered twice; the count must be driven
    // by whether `log_index` accepted the row, not by the record
    // arriving.
    const a = testing.allocator;
    const db_path = try tempPath(a, "sagaidem");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var recs = [_]sidecar.Record{
        sagaRec(1, 1_000, "C1", .{}),
        sagaRec(2, 2_000, "C1", .{ .activation = "ws_message" }),
    };
    try putBatch(idx, "b1", &recs);
    try putBatch(idx, "b1", &recs); // same batch again
    try putBatch(idx, "b1", &recs); // and again

    var list = try idx.querySagas("acme", 0, "", 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqual(@as(u64, 2), list.rows[0].activation_count);
}

test "closed_at_ns is set only by a disconnect, and only once" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "sagaclose");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    // An open saga: frames, no close. NULL → 0, and a reader must NOT
    // read that as "still live" — plenty of sagas never get a close.
    var open = [_]sidecar.Record{
        sagaRec(1, 1_000, "OPEN", .{}),
        sagaRec(2, 2_000, "OPEN", .{ .activation = "ws_message" }),
    };
    try putBatch(idx, "bo", &open);

    // A closed one, whose disconnect arrives in a LATER batch.
    var c_open = [_]sidecar.Record{sagaRec(10, 1_500, "DONE", .{})};
    try putBatch(idx, "bc1", &c_open);
    var c_close = [_]sidecar.Record{sagaRec(11, 2_500, "DONE", .{ .activation = "disconnect" })};
    try putBatch(idx, "bc2", &c_close);

    var list = try idx.querySagas("acme", 0, "", 0, 10);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.rows.len);

    for (list.rows) |row| {
        if (std.mem.eql(u8, row.corr_id, "OPEN")) {
            try testing.expectEqual(@as(i64, 0), row.closed_at_ns);
        } else {
            try testing.expectEqualStrings("DONE", row.corr_id);
            try testing.expectEqual(@as(i64, 2_500), row.closed_at_ns);
        }
    }

    // A replayed close cannot move the saga's end.
    try putBatch(idx, "bc2", &c_close);
    var again = try idx.querySagas("acme", 0, "", 0, 10);
    defer again.deinit();
    for (again.rows) |row| {
        if (std.mem.eql(u8, row.corr_id, "DONE"))
            try testing.expectEqual(@as(i64, 2_500), row.closed_at_ns);
    }
}

test "the saga list keyset-pages, clamps to retention, and counts errors" {
    const a = testing.allocator;
    const db_path = try tempPath(a, "sagapage");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    // Five sagas, one activation each, 1000ns apart. The middle one
    // errors.
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        var saga_buf: [8]u8 = undefined;
        const corr = try std.fmt.bufPrint(&saga_buf, "S{d}", .{i});
        var batch_buf: [8]u8 = undefined;
        const bid = try std.fmt.bufPrint(&batch_buf, "b{d}", .{i});
        var recs = [_]sidecar.Record{sagaRec(
            i + 1,
            @intCast((i + 1) * 1_000),
            corr,
            if (i == 2) .{ .outcome = "handler_error", .status = 500 } else .{},
        )};
        try putBatch(idx, bid, &recs);
    }

    // Page 1: newest two.
    var p1 = try idx.querySagas("acme", 0, "", 0, 2);
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 2), p1.rows.len);
    try testing.expectEqualStrings("S4", p1.rows[0].corr_id);
    try testing.expectEqualStrings("S3", p1.rows[1].corr_id);

    // Page 2 from the previous tail — no repeat, no gap.
    const tail = p1.rows[1];
    var p2 = try idx.querySagas("acme", tail.last_received_ns, tail.corr_id, 0, 2);
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 2), p2.rows.len);
    try testing.expectEqualStrings("S2", p2.rows[0].corr_id);
    try testing.expectEqualStrings("S1", p2.rows[1].corr_id);
    // The error saga carries its count; a healthy one does not.
    try testing.expectEqual(@as(u64, 1), p2.rows[0].error_count);
    try testing.expectEqual(@as(u16, 500), p2.rows[0].last_status);
    try testing.expectEqual(@as(u64, 0), p2.rows[1].error_count);

    // Retention clamp: a floor above a saga's last activity hides it,
    // because every step it could show is clamped away too.
    var clamped = try idx.querySagas("acme", 0, "", 3_500, 10);
    defer clamped.deinit();
    try testing.expectEqual(@as(usize, 2), clamped.rows.len);
    try testing.expectEqualStrings("S4", clamped.rows[0].corr_id);
    try testing.expectEqualStrings("S3", clamped.rows[1].corr_id);
}

test "the saga list is index-only — no scan, no aggregate" {
    // Same posture as the tag-filtered list guard: pin the PLAN, since
    // the whole point of materializing `log_sagas` is that listing
    // sagas never degrades into the `GROUP BY` over `log_tags` this
    // table exists to replace. No ANALYZE — production has none.
    const a = testing.allocator;
    const db_path = try tempPath(a, "sagaplan");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    const sql =
        \\SELECT corr_id, first_received_ns, last_received_ns, activation_count,
        \\       root_method, root_path, root_host, last_status, last_outcome,
        \\       error_count, closed_at_ns
        \\FROM log_sagas
        \\WHERE tenant_id = ?1
        \\  AND (?2 = 0 OR last_received_ns < ?2 OR (last_received_ns = ?2 AND corr_id < ?3))
        \\  AND (?4 = 0 OR last_received_ns >= ?4)
        \\ORDER BY last_received_ns DESC, corr_id DESC
        \\LIMIT ?5
    ;
    const plan = try explainQueryPlan(a, idx.db, sql);
    defer a.free(plan);
    try testing.expect(std.mem.indexOf(u8, plan, "log_sagas_recent") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "SCAN") == null);
    // A temp b-tree here would mean the index isn't supplying the sort,
    // which is the property that makes paging O(page) instead of
    // O(all sagas) per request.
    try testing.expect(std.mem.indexOf(u8, plan, "TEMP B-TREE") == null);
}

test "the activation kind survives the tag-filtered path too" {
    // A saga's steps are listed through the tagged statement (#443), so
    // the kind has to come back on THAT path, not just the plain list —
    // the two select their columns separately.
    const a = testing.allocator;
    const db_path = try tempPath(a, "actkind");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        deleteWalSidecars(db_path);
        a.free(db_path);
    }

    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    var records = [_]sidecar.Record{
        .{ .tenant_id = "acme", .request_id = 1, .received_ns = 1_000, .duration_ns = 1, .method = "GET", .path = "/ws", .host = "h", .status = 101, .outcome = "ok", .deployment_id = 1, .saga_id = "C1", .activation = "inbound", .offset = 0, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 2, .received_ns = 2_000, .duration_ns = 1, .method = "GET", .path = "/ws", .host = "h", .status = 0, .outcome = "ok", .deployment_id = 1, .saga_id = "C1", .activation = "ws_message", .offset = 10, .length = 10 },
        .{ .tenant_id = "acme", .request_id = 3, .received_ns = 3_000, .duration_ns = 1, .method = "GET", .path = "/ws", .host = "h", .status = 0, .outcome = "ok", .deployment_id = 1, .saga_id = "C1", .activation = "disconnect", .offset = 20, .length = 10 },
    };
    const batch = sidecar.IdxFile{
        .node_id = "00000001",
        .batch_id = "wsbatch",
        .ndjson_size = 30,
        .ndjson_sha256 = "d",
        .first_received_ns = 1_000,
        .last_received_ns = 3_000,
        .records = &records,
    };
    try idx.insertBatch(&batch, "_logs/00000001/wsbatch.ndjson", 0);

    // The whole saga, newest-first: close, frame, open.
    var saga = try idx.queryList("acme", 0, 0, 0, 10, "_saga", "C1", .{});
    defer saga.deinit();
    try testing.expectEqual(@as(usize, 3), saga.rows.len);
    try testing.expectEqualStrings("disconnect", saga.rows[0].activation);
    try testing.expectEqualStrings("ws_message", saga.rows[1].activation);
    try testing.expectEqualStrings("inbound", saga.rows[2].activation);
}

test "a re-index counts as re-index, a collision counts as a CONFLICT" {
    // The two things `INSERT OR IGNORE` swallows, told apart. Both drop a row;
    // only one is data loss, and before rove#266 they were indistinguishable —
    // which is why an hour of production records vanished while every counter
    // stayed green.
    const a = testing.allocator;
    const db_path = try tempPath(a, "conflict");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();

    const before_conflicts = metrics.global.index_conflicts.load(.monotonic);
    const before_reindex = metrics.global.index_reindexed.load(.monotonic);

    var rec = [_]sidecar.Record{.{
        .tenant_id = "acme", .request_id = 7, .received_ns = 1_000, .duration_ns = 10,
        .method = "GET", .path = "/first", .host = "h.test", .status = 200,
        .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 40,
    }};
    const batch = sidecar.IdxFile{
        .node_id = "00000001", .batch_id = "b1", .ndjson_size = 40,
        .ndjson_sha256 = "aaa", .first_received_ns = 1_000, .last_received_ns = 1_000,
        .records = &rec,
    };
    try idx.insertBatch(&batch, "_logs/00000001/b1.ndjson", 0);
    try testing.expectEqual(before_conflicts, metrics.global.index_conflicts.load(.monotonic));

    // Same object again — the poll path re-listing its clock-skew window.
    try idx.insertBatch(&batch, "_logs/00000001/b1.ndjson", 0);
    try testing.expectEqual(before_reindex + 1, metrics.global.index_reindexed.load(.monotonic));
    try testing.expectEqual(before_conflicts, metrics.global.index_conflicts.load(.monotonic));

    // The SAME request re-emitted into a DIFFERENT object at a different
    // offset — what the promotion-time LogRecord walker does so records
    // survive a leader dying mid-flush. Still the same request (`received_ns`
    // matches), so still not loss. Keying on storage location instead called
    // this a conflict and produced 111 phantom alerts in production within
    // minutes.
    const walker = sidecar.IdxFile{
        .node_id = "00000001", .batch_id = "b1-again", .ndjson_size = 40,
        .ndjson_sha256 = "aaa", .first_received_ns = 1_000, .last_received_ns = 1_000,
        .records = &rec,
    };
    try idx.insertBatch(&walker, "_logs/00000001/b1-RE-EMITTED.ndjson", 512);
    try testing.expectEqual(before_reindex + 2, metrics.global.index_reindexed.load(.monotonic));
    try testing.expectEqual(before_conflicts, metrics.global.index_conflicts.load(.monotonic));

    // A DIFFERENT record claiming the same (tenant, request_id) — a fresh
    // cluster lifetime re-issuing id 7 at a new object. This is the loss.
    var clash = [_]sidecar.Record{.{
        .tenant_id = "acme", .request_id = 7, .received_ns = 9_000, .duration_ns = 20,
        .method = "POST", .path = "/second-lifetime", .host = "h.test", .status = 201,
        .outcome = "ok", .deployment_id = 2, .offset = 0, .length = 55,
    }};
    const batch2 = sidecar.IdxFile{
        .node_id = "00000001", .batch_id = "b2", .ndjson_size = 55,
        .ndjson_sha256 = "bbb", .first_received_ns = 9_000, .last_received_ns = 9_000,
        .records = &clash,
    };
    try idx.insertBatch(&batch2, "_logs/00000001/b2.ndjson", 0);
    try testing.expectEqual(before_conflicts + 1, metrics.global.index_conflicts.load(.monotonic));
    // …and the two benign re-arrivals above are still counted as re-index, not
    // swept into the conflict total.
    try testing.expectEqual(before_reindex + 2, metrics.global.index_reindexed.load(.monotonic));

    // And the loss is real: the FIRST record still owns the identity.
    var list = try idx.queryList("acme", 0, 0, 0, 10, null, null, .{});
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqualStrings("/first", list.rows[0].path);
}

test "an undatable re-emit is a re-index, not a conflict" {
    // The promotion walker rebuilds records from the raft log, which carries no
    // arrival time, so it emits received_ns = 0. Treating that zero as a real
    // timestamp says "different request" for what is the same request — 78
    // phantom conflicts in production before this was understood.
    const a = testing.allocator;
    const db_path = try tempPath(a, "undatable");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();
    const before_conflicts = metrics.global.index_conflicts.load(.monotonic);
    const before_reindex = metrics.global.index_reindexed.load(.monotonic);

    var real = [_]sidecar.Record{.{
        .tenant_id = "registry", .request_id = 9, .received_ns = 1_785_438_625_761_330_313,
        .duration_ns = 10, .method = "POST", .path = "/v1/publish", .host = "r.test",
        .status = 201, .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 40,
    }};
    try idx.insertBatch(&.{
        .node_id = "00000001", .batch_id = "real", .ndjson_size = 40, .ndjson_sha256 = "a",
        .first_received_ns = 1, .last_received_ns = 1, .records = &real,
    }, "_logs/00000001/real.ndjson", 0);

    // The walker re-emits the same request with no timestamp.
    var walked = [_]sidecar.Record{.{
        .tenant_id = "registry", .request_id = 9, .received_ns = 0,
        .duration_ns = 10, .method = "POST", .path = "/v1/publish", .host = "r.test",
        .status = 201, .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 40,
    }};
    try idx.insertBatch(&.{
        .node_id = "00000001", .batch_id = "walked", .ndjson_size = 40, .ndjson_sha256 = "b",
        .first_received_ns = 0, .last_received_ns = 0, .records = &walked,
    }, "_logs/00000001/walked.ndjson", 0);

    try testing.expectEqual(before_conflicts, metrics.global.index_conflicts.load(.monotonic));
    try testing.expectEqual(before_reindex + 1, metrics.global.index_reindexed.load(.monotonic));
}

test "the same id in a DIFFERENT tenant is not a conflict" {
    // The key is (tenant_id, request_id). Tenants mint independently, so id 7
    // existing for one tenant says nothing about another — counting that as a
    // conflict would make the metric fire constantly and get ignored.
    const a = testing.allocator;
    const db_path = try tempPath(a, "crosstenant");
    defer {
        std.fs.cwd().deleteFile(db_path) catch {};
        a.free(db_path);
    }
    var idx = try IndexDb.open(a, db_path);
    defer idx.close();
    const before = metrics.global.index_conflicts.load(.monotonic);

    inline for (.{ "acme", "globex" }) |tenant| {
        var rec = [_]sidecar.Record{.{
            .tenant_id = tenant, .request_id = 7, .received_ns = 1_000, .duration_ns = 10,
            .method = "GET", .path = "/p", .host = "h.test", .status = 200,
            .outcome = "ok", .deployment_id = 1, .offset = 0, .length = 40,
        }};
        const b = sidecar.IdxFile{
            .node_id = "00000001", .batch_id = tenant, .ndjson_size = 40,
            .ndjson_sha256 = "x", .first_received_ns = 1_000, .last_received_ns = 1_000,
            .records = &rec,
        };
        try idx.insertBatch(&b, "_logs/00000001/" ++ tenant ++ ".ndjson", 0);
    }
    try testing.expectEqual(before, metrics.global.index_conflicts.load(.monotonic));
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

    var list = try idx.queryList("globex", 0, 0, 0, 10, null, null, .{});
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
    var list = try reader.queryList("acme", 0, 0, 0, 10, null, null, .{});
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.rows.len);
    try testing.expectEqual(@as(u64, 42), list.rows[0].request_id);
    try testing.expectEqual(@as(u64, 1), try reader.queryCount("acme", 0));
}
