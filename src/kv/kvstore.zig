//! SQLite-backed KV store with a seq column for raft delta replication.
//!
//! ## Durability contract
//!
//! KV state on followers is re-applied from the raft log on restart, so
//! KV-level fsync isn't strictly required for raft *correctness*. But:
//!
//! 1. On the leader, the shift-js pattern is "worker writes locally, then
//!    proposes." If the worker's local write isn't durable and the leader
//!    crashes before the proposal commits via raft, the worker's pre-crash
//!    read-your-own-write might be lost on restart. For consistency, KV
//!    writes should be fsynced.
//!
//! 2. Fast restart: if KV is durable, we can skip re-applying already-
//!    applied entries on restart (future optimization — not yet wired).
//!
//! We pin `journal_mode=WAL` and `synchronous=FULL` for the same reasons
//! as the raft log. See `raft_log.zig` for the full rationale.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    Conflict,
    NotFound,
    Sqlite,
    /// `PRAGMA journal_mode=WAL` didn't take.
    JournalMode,
    /// `PRAGMA synchronous=FULL` didn't take or report back.
    SynchronousMode,
    OutOfMemory,
};

pub const Entry = struct {
    key: []u8,
    value: []u8,
};

pub const DeltaEntry = struct {
    key: []u8,
    value: []u8,
    seq: u64,
};

pub const RangeResult = struct {
    entries: []Entry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RangeResult) void {
        for (self.entries) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

pub const DeltaResult = struct {
    entries: []DeltaEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DeltaResult) void {
        for (self.entries) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

const SQL_CREATE =
    \\CREATE TABLE IF NOT EXISTS kv (
    \\  key   TEXT PRIMARY KEY NOT NULL,
    \\  value BLOB NOT NULL,
    \\  seq   INTEGER NOT NULL DEFAULT 0
    \\) WITHOUT ROWID;
;

const SQL_CREATE_SEQ =
    \\CREATE TABLE IF NOT EXISTS kv_seq (id INTEGER PRIMARY KEY AUTOINCREMENT);
;

// Undo log. See module doc comment for the full rationale. Briefly: a
// `TrackedTxn` captures the pre-image of every key it touches so a crash
// between local commit and raft commit can be rolled back on startup. A
// NULL `prev_value` means "this key didn't exist before the txn" — the
// undo action is then a delete rather than a restore.
const SQL_CREATE_UNDO =
    \\CREATE TABLE IF NOT EXISTS kv_undo (
    \\  txn_seq    INTEGER NOT NULL,
    \\  key        TEXT    NOT NULL,
    \\  prev_value BLOB,
    \\  prev_seq   INTEGER,
    \\  PRIMARY KEY (txn_seq, key)
    \\) WITHOUT ROWID;
;

const SQL_GET = "SELECT value FROM kv WHERE key = ?;";
const SQL_GET_WITH_SEQ = "SELECT value, seq FROM kv WHERE key = ?;";
const SQL_PUT = "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?);";
const SQL_PUT_SEQ = "INSERT OR REPLACE INTO kv (key, value, seq) VALUES (?, ?, ?);";
const SQL_DEL = "DELETE FROM kv WHERE key = ?;";
const SQL_RANGE = "SELECT key, value FROM kv WHERE key >= ? AND key < ? ORDER BY key LIMIT ?;";
const SQL_DELTA = "SELECT key, value, seq FROM kv WHERE seq > ? AND seq <= ? ORDER BY seq;";
const SQL_BEGIN = "BEGIN;";
// BEGIN IMMEDIATE acquires RESERVED at begin time, serializing
// concurrent writers up front (they block inside SQLite's busy retry
// loop for up to `busy_timeout` ms). Used by rove-js so per-tenant
// handler transactions get clean FIFO serialization without bubbling
// SQLITE_BUSY up to the dispatcher.
const SQL_BEGIN_IMMEDIATE = "BEGIN IMMEDIATE;";
const SQL_COMMIT = "COMMIT;";
const SQL_ROLLBACK = "ROLLBACK;";
const SQL_NEXT_SEQ = "INSERT INTO kv_seq DEFAULT VALUES;";
const SQL_SEQ_TRUNC = "DELETE FROM kv_seq WHERE id <= ?;";
const SQL_MAX_SEQ = "SELECT MAX(seq) FROM kv;";

// Undo log statements.
const SQL_UNDO_INSERT =
    \\INSERT OR IGNORE INTO kv_undo (txn_seq, key, prev_value, prev_seq)
    \\VALUES (?, ?, ?, ?);
;
const SQL_UNDO_SELECT_UNCOMMITTED =
    \\SELECT txn_seq, key, prev_value, prev_seq FROM kv_undo
    \\WHERE txn_seq > ?
    \\ORDER BY txn_seq DESC, key;
;
const SQL_UNDO_DELETE_COMMITTED = "DELETE FROM kv_undo WHERE txn_seq <= ?;";
const SQL_UNDO_DELETE_UNCOMMITTED = "DELETE FROM kv_undo WHERE txn_seq > ?;";
const SQL_UNDO_DELETE_TXN = "DELETE FROM kv_undo WHERE txn_seq = ?;";

pub const KvStore = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    stmt_get: *c.sqlite3_stmt,
    stmt_get_with_seq: *c.sqlite3_stmt,
    stmt_put: *c.sqlite3_stmt,
    stmt_put_seq: *c.sqlite3_stmt,
    stmt_del: *c.sqlite3_stmt,
    stmt_range: *c.sqlite3_stmt,
    stmt_delta: *c.sqlite3_stmt,
    stmt_begin: *c.sqlite3_stmt,
    stmt_begin_immediate: *c.sqlite3_stmt,
    stmt_commit: *c.sqlite3_stmt,
    stmt_rollback: *c.sqlite3_stmt,
    stmt_next_seq: *c.sqlite3_stmt,
    stmt_seq_trunc: *c.sqlite3_stmt,
    stmt_undo_insert: *c.sqlite3_stmt,
    stmt_undo_select_uncommitted: *c.sqlite3_stmt,
    stmt_undo_delete_committed: *c.sqlite3_stmt,
    stmt_undo_delete_uncommitted: *c.sqlite3_stmt,
    stmt_undo_delete_txn: *c.sqlite3_stmt,

    /// Open mode for `openInternal`. Most callers use `open` for the
    /// read-write path; `openReadOnly` is for inspection tools (the
    /// log/code CLIs) that share a database file with a running worker
    /// and need to avoid acquiring write locks or running schema DDL
    /// against the live store.
    const OpenMode = enum { read_write, read_only };

    /// Open or create a KV store backed by the given SQLite file.
    /// Each thread should call open() to get its own connection.
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) Error!*KvStore {
        return openInternal(allocator, path, .read_write);
    }

    /// Open an EXISTING KV store in read-only mode. The database file
    /// must already exist with the rove-kv schema (this function does
    /// NOT run CREATE TABLE statements). Use this from inspection
    /// tools that read alongside a running worker — read-only opens
    /// don't acquire the write lock and don't conflict with the
    /// worker's writes under WAL mode. Calling any write method
    /// (`put`, `delete`, `begin`, ...) on a read-only KvStore returns
    /// SQLITE_READONLY at step time, which surfaces as `Error.Sqlite`.
    pub fn openReadOnly(allocator: std.mem.Allocator, path: [:0]const u8) Error!*KvStore {
        return openInternal(allocator, path, .read_only);
    }

    fn openInternal(
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        mode: OpenMode,
    ) Error!*KvStore {
        const self = try allocator.create(KvStore);
        errdefer allocator.destroy(self);

        var db: ?*c.sqlite3 = null;
        const flags: c_int = switch (mode) {
            .read_write => c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
            .read_only => c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX,
        };
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.Sqlite;
        }
        errdefer _ = c.sqlite3_close(db.?);

        // Install the busy handler BEFORE the durability pragmas.
        // `PRAGMA journal_mode=WAL;` briefly needs exclusive access
        // on the initial switch; if another connection is racing to
        // set it at the same instant (e.g. N workers all opening
        // the same file at startup in the shift-js shared-nothing
        // model), SQLite returns SQLITE_BUSY immediately unless a
        // busy handler is installed. With a 5-second timeout, losing
        // connections wait for the winner to finish transitioning
        // and then see WAL already enabled — their own journal-mode
        // pragma becomes a cheap confirmation read.
        //
        // busy_timeout works in both read-write and read-only modes
        // so we set it unconditionally.
        _ = c.sqlite3_exec(db, "PRAGMA busy_timeout=5000;", null, null, null);

        // Durability pragmas (journal_mode=WAL, synchronous=FULL) are
        // settings that mutate the database — only valid on a
        // read-write connection.
        if (mode == .read_write) {
            try pinDurability(db.?);
        }

        if (mode == .read_write) {
            if (c.sqlite3_exec(db, SQL_CREATE, null, null, null) != c.SQLITE_OK) return Error.Sqlite;
            if (c.sqlite3_exec(db, SQL_CREATE_SEQ, null, null, null) != c.SQLITE_OK) return Error.Sqlite;
            if (c.sqlite3_exec(db, SQL_CREATE_UNDO, null, null, null) != c.SQLITE_OK) return Error.Sqlite;
        }

        self.allocator = allocator;
        self.db = db.?;

        // Prepare statements; on failure, finalize what we've prepared so far.
        var prepared: usize = 0;
        const stmts = [_]struct { sql: []const u8, field: []const u8 }{
            .{ .sql = SQL_GET, .field = "stmt_get" },
            .{ .sql = SQL_GET_WITH_SEQ, .field = "stmt_get_with_seq" },
            .{ .sql = SQL_PUT, .field = "stmt_put" },
            .{ .sql = SQL_PUT_SEQ, .field = "stmt_put_seq" },
            .{ .sql = SQL_DEL, .field = "stmt_del" },
            .{ .sql = SQL_RANGE, .field = "stmt_range" },
            .{ .sql = SQL_DELTA, .field = "stmt_delta" },
            .{ .sql = SQL_BEGIN, .field = "stmt_begin" },
            .{ .sql = SQL_BEGIN_IMMEDIATE, .field = "stmt_begin_immediate" },
            .{ .sql = SQL_COMMIT, .field = "stmt_commit" },
            .{ .sql = SQL_ROLLBACK, .field = "stmt_rollback" },
            .{ .sql = SQL_NEXT_SEQ, .field = "stmt_next_seq" },
            .{ .sql = SQL_SEQ_TRUNC, .field = "stmt_seq_trunc" },
            .{ .sql = SQL_UNDO_INSERT, .field = "stmt_undo_insert" },
            .{ .sql = SQL_UNDO_SELECT_UNCOMMITTED, .field = "stmt_undo_select_uncommitted" },
            .{ .sql = SQL_UNDO_DELETE_COMMITTED, .field = "stmt_undo_delete_committed" },
            .{ .sql = SQL_UNDO_DELETE_UNCOMMITTED, .field = "stmt_undo_delete_uncommitted" },
            .{ .sql = SQL_UNDO_DELETE_TXN, .field = "stmt_undo_delete_txn" },
        };

        errdefer {
            inline for (stmts, 0..) |s, i| {
                if (i < prepared) {
                    _ = c.sqlite3_finalize(@field(self, s.field));
                }
            }
        }

        inline for (stmts) |s| {
            @field(self, s.field) = try prepare(self.db, s.sql);
            prepared += 1;
        }

        return self;
    }

    pub fn close(self: *KvStore) void {
        _ = c.sqlite3_finalize(self.stmt_get);
        _ = c.sqlite3_finalize(self.stmt_get_with_seq);
        _ = c.sqlite3_finalize(self.stmt_put);
        _ = c.sqlite3_finalize(self.stmt_put_seq);
        _ = c.sqlite3_finalize(self.stmt_del);
        _ = c.sqlite3_finalize(self.stmt_range);
        _ = c.sqlite3_finalize(self.stmt_delta);
        _ = c.sqlite3_finalize(self.stmt_begin);
        _ = c.sqlite3_finalize(self.stmt_begin_immediate);
        _ = c.sqlite3_finalize(self.stmt_commit);
        _ = c.sqlite3_finalize(self.stmt_rollback);
        _ = c.sqlite3_finalize(self.stmt_next_seq);
        _ = c.sqlite3_finalize(self.stmt_seq_trunc);
        _ = c.sqlite3_finalize(self.stmt_undo_insert);
        _ = c.sqlite3_finalize(self.stmt_undo_select_uncommitted);
        _ = c.sqlite3_finalize(self.stmt_undo_delete_committed);
        _ = c.sqlite3_finalize(self.stmt_undo_delete_uncommitted);
        _ = c.sqlite3_finalize(self.stmt_undo_delete_txn);
        _ = c.sqlite3_close(self.db);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    // ── Transactions ──────────────────────────────────────────────────

    pub fn begin(self: *KvStore) Error!void {
        return runVoid(self.stmt_begin);
    }

    pub fn commit(self: *KvStore) Error!void {
        return runVoid(self.stmt_commit);
    }

    pub fn rollback(self: *KvStore) Error!void {
        const st = self.stmt_rollback;
        _ = c.sqlite3_reset(st);
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    // ── Core ops ──────────────────────────────────────────────────────

    /// Returns an owned slice (caller frees with allocator passed to open()),
    /// or Error.NotFound if the key doesn't exist.
    pub fn get(self: *KvStore, key: []const u8) Error![]u8 {
        const st = self.stmt_get;
        _ = c.sqlite3_reset(st);
        bindText(st, 1, key);

        const rc = c.sqlite3_step(st);
        defer _ = c.sqlite3_reset(st);

        if (rc == c.SQLITE_ROW) {
            const blob = c.sqlite3_column_blob(st, 0);
            const blen: usize = @intCast(c.sqlite3_column_bytes(st, 0));
            const out = try self.allocator.alloc(u8, blen);
            if (blen > 0) {
                @memcpy(out, @as([*]const u8, @ptrCast(blob))[0..blen]);
            }
            return out;
        }
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        return Error.Sqlite;
    }

    pub fn put(self: *KvStore, key: []const u8, value: []const u8) Error!void {
        const st = self.stmt_put;
        _ = c.sqlite3_reset(st);
        bindText(st, 1, key);
        bindBlob(st, 2, value);

        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    pub fn putSeq(self: *KvStore, key: []const u8, value: []const u8, seq: u64) Error!void {
        const st = self.stmt_put_seq;
        _ = c.sqlite3_reset(st);
        bindText(st, 1, key);
        bindBlob(st, 2, value);
        _ = c.sqlite3_bind_int64(st, 3, @bitCast(seq));

        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    pub fn delete(self: *KvStore, key: []const u8) Error!void {
        const st = self.stmt_del;
        _ = c.sqlite3_reset(st);
        bindText(st, 1, key);

        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    /// Range scan: keys where start <= key < end, up to `count` results.
    pub fn range(
        self: *KvStore,
        start: []const u8,
        end: []const u8,
        count: u32,
    ) Error!RangeResult {
        const st = self.stmt_range;
        _ = c.sqlite3_reset(st);
        bindText(st, 1, start);
        bindText(st, 2, end);
        _ = c.sqlite3_bind_int64(st, 3, count);

        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            list.deinit(self.allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(st);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                _ = c.sqlite3_reset(st);
                return Error.Sqlite;
            }

            const k_ptr = c.sqlite3_column_text(st, 0);
            const k_len: usize = @intCast(c.sqlite3_column_bytes(st, 0));
            const v_ptr = c.sqlite3_column_blob(st, 1);
            const v_len: usize = @intCast(c.sqlite3_column_bytes(st, 1));

            const k_copy = try self.allocator.alloc(u8, k_len);
            errdefer self.allocator.free(k_copy);
            if (k_len > 0) @memcpy(k_copy, @as([*]const u8, @ptrCast(k_ptr))[0..k_len]);

            const v_copy = try self.allocator.alloc(u8, v_len);
            errdefer self.allocator.free(v_copy);
            if (v_len > 0) @memcpy(v_copy, @as([*]const u8, @ptrCast(v_ptr))[0..v_len]);

            try list.append(self.allocator, .{ .key = k_copy, .value = v_copy });
        }

        _ = c.sqlite3_reset(st);
        return .{
            .entries = try list.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    // ── Sequence / replication ────────────────────────────────────────

    /// Allocate a monotonic sequence number inside the current transaction.
    /// Must be called between begin() and commit(). Returns 0 on error.
    pub fn nextSeq(self: *KvStore) u64 {
        const st = self.stmt_next_seq;
        _ = c.sqlite3_reset(st);
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return 0;
        return @bitCast(c.sqlite3_last_insert_rowid(self.db));
    }

    /// Delete sequence entries up to and including `through_seq`.
    pub fn seqTruncate(self: *KvStore, through_seq: u64) Error!void {
        const st = self.stmt_seq_trunc;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(through_seq));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    /// Returns the maximum seq value in the kv table, or 0 if empty.
    pub fn maxSeq(self: *KvStore) u64 {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, SQL_MAX_SEQ, -1, &st, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(st);
        var result: u64 = 0;
        if (c.sqlite3_step(st) == c.SQLITE_ROW) {
            result = @bitCast(c.sqlite3_column_int64(st, 0));
        }
        return result;
    }

    /// Delta query: all KV entries with after_seq < seq <= through_seq.
    /// Pass through_seq = std.math.maxInt(u64) for unbounded upper end.
    pub fn delta(
        self: *KvStore,
        after_seq: u64,
        through_seq: u64,
    ) Error!DeltaResult {
        const st = self.stmt_delta;
        _ = c.sqlite3_reset(st);
        // SQLite stores seq as signed int64; clamp to maxInt(i64) so callers
        // can pass maxInt(u64) for "unbounded upper end" without it bitcasting
        // to -1 and matching nothing.
        const through_clamped: i64 = if (through_seq > std.math.maxInt(i64))
            std.math.maxInt(i64)
        else
            @intCast(through_seq);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(after_seq));
        _ = c.sqlite3_bind_int64(st, 2, through_clamped);

        var list: std.ArrayList(DeltaEntry) = .empty;
        errdefer {
            for (list.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            list.deinit(self.allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(st);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                _ = c.sqlite3_reset(st);
                return Error.Sqlite;
            }

            const k_ptr = c.sqlite3_column_text(st, 0);
            const k_len: usize = @intCast(c.sqlite3_column_bytes(st, 0));
            const v_ptr = c.sqlite3_column_blob(st, 1);
            const v_len: usize = @intCast(c.sqlite3_column_bytes(st, 1));
            const seq: u64 = @bitCast(c.sqlite3_column_int64(st, 2));

            const k_copy = try self.allocator.alloc(u8, k_len);
            errdefer self.allocator.free(k_copy);
            if (k_len > 0) @memcpy(k_copy, @as([*]const u8, @ptrCast(k_ptr))[0..k_len]);

            const v_copy = try self.allocator.alloc(u8, v_len);
            errdefer self.allocator.free(v_copy);
            if (v_len > 0) @memcpy(v_copy, @as([*]const u8, @ptrCast(v_ptr))[0..v_len]);

            try list.append(self.allocator, .{ .key = k_copy, .value = v_copy, .seq = seq });
        }

        _ = c.sqlite3_reset(st);
        return .{
            .entries = try list.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    // ── Checkpointing ─────────────────────────────────────────────────

    /// Disable automatic WAL checkpointing on this connection.
    /// Call once after open() for connections managed by the raft leader.
    pub fn disableAutoCheckpoint(self: *KvStore) void {
        _ = c.sqlite3_wal_autocheckpoint(self.db, 0);
    }

    /// Manually checkpoint the WAL (passive — doesn't block readers).
    pub fn checkpoint(self: *KvStore) Error!void {
        _ = try self.checkpointV2();
    }

    pub const CheckpointResult = struct {
        /// Total frames currently in the WAL file after the call.
        log_pages: u32,
        /// Number of frames already checkpointed (moved from WAL to the
        /// main DB file). `log_pages == ckpt_pages` means the WAL fully
        /// drained; `log_pages > ckpt_pages` means a reader was blocking
        /// some frames from being reclaimed (still safe, just not freed
        /// yet).
        ckpt_pages: u32,
    };

    /// Passive WAL checkpoint that also reports frame counts. Safe to call
    /// repeatedly at any rate — returns cheaply when the WAL is already
    /// drained. Use the returned `log_pages` as a size probe to decide
    /// whether stronger measures (e.g. RESTART mode) are warranted.
    pub fn checkpointV2(self: *KvStore) Error!CheckpointResult {
        var n_log: c_int = 0;
        var n_ckpt: c_int = 0;
        const rc = c.sqlite3_wal_checkpoint_v2(
            self.db,
            null,
            c.SQLITE_CHECKPOINT_PASSIVE,
            &n_log,
            &n_ckpt,
        );
        if (rc != c.SQLITE_OK) return Error.Sqlite;
        // -1 means "not in WAL mode" or "error during the call"; both are
        // failure modes we should surface.
        if (n_log < 0 or n_ckpt < 0) return Error.Sqlite;
        return .{
            .log_pages = @intCast(n_log),
            .ckpt_pages = @intCast(n_ckpt),
        };
    }

    // ── Tracked transactions (undo log) ────────────────────────────────
    //
    // Problem we're solving: the "worker writes locally, then proposes" fast
    // path has a crash window between the local commit and the raft commit.
    // If the leader crashes in that window and the raft entry is eventually
    // discarded by the new leader, the local row is an orphan — visible on
    // this node but not on any other.
    //
    // The fix is a second table (kv_undo) that records the pre-image of
    // every key touched by a tracked txn, atomically with the forward
    // write. On startup, we walk kv_undo: txns whose seq > committed_seq
    // are rolled back (restoring the pre-images); txns whose seq
    // ≤ committed_seq are GC'd (they've been made durable via raft).

    /// A transaction that records undo info for every put/delete, letting
    /// the caller or a startup sweep roll back the writes if the raft
    /// proposal built on this txn fails to commit. Create via
    /// `KvStore.beginTracked`.
    pub const TrackedTxn = struct {
        store: *KvStore,
        /// Caller-visible seq (matches kv_seq's autoincrement id). Also
        /// used as the row's `seq` column and as the propose() seq.
        /// Zero until the underlying SQLite txn is actually opened —
        /// see `ensureOpen`. Read-only handlers never allocate a seq
        /// (and thus never fsync the WAL).
        txn_seq: u64,
        kind: enum { normal, immediate },
        opened: bool,

        /// Open the underlying SQLite txn on first write. Idempotent —
        /// subsequent writes on the same TrackedTxn skip it.
        fn ensureOpen(self: *TrackedTxn) Error!void {
            if (self.opened) return;
            switch (self.kind) {
                .normal => try self.store.begin(),
                .immediate => {
                    const st = self.store.stmt_begin_immediate;
                    _ = c.sqlite3_reset(st);
                    const rc = c.sqlite3_step(st);
                    _ = c.sqlite3_reset(st);
                    if (rc != c.SQLITE_DONE) return Error.Sqlite;
                },
            }
            const seq = self.store.nextSeq();
            if (seq == 0) {
                self.store.rollback() catch {};
                return Error.Sqlite;
            }
            self.txn_seq = seq;
            self.opened = true;
        }

        /// Insert-or-replace with undo tracking. If the key already exists
        /// and no undo row has been recorded for (txn_seq, key) yet, the
        /// current value is captured first. Must be called only between
        /// `beginTracked` and `commit`/`rollback`.
        pub fn put(self: *TrackedTxn, key: []const u8, value: []const u8) Error!void {
            try self.ensureOpen();
            try self.captureUndo(key);
            try self.store.putSeq(key, value, self.txn_seq);
        }

        pub fn delete(self: *TrackedTxn, key: []const u8) Error!void {
            try self.ensureOpen();
            try self.captureUndo(key);
            try self.store.delete(key);
        }

        pub fn commit(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            try self.store.commit();
        }

        pub fn rollback(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            // Rollback drops everything we did in this SQLite txn, including
            // the kv_undo INSERTs. No separate cleanup needed.
            try self.store.rollback();
        }

        fn captureUndo(self: *TrackedTxn, key: []const u8) Error!void {
            // Read the current value+seq for this key, if any.
            const st_get = self.store.stmt_get_with_seq;
            _ = c.sqlite3_reset(st_get);
            bindText(st_get, 1, key);
            const rc = c.sqlite3_step(st_get);

            // Prepare the undo insert.
            const st_ins = self.store.stmt_undo_insert;
            _ = c.sqlite3_reset(st_ins);
            _ = c.sqlite3_bind_int64(st_ins, 1, @bitCast(self.txn_seq));
            bindText(st_ins, 2, key);

            if (rc == c.SQLITE_ROW) {
                const blob = c.sqlite3_column_blob(st_get, 0);
                const blen: usize = @intCast(c.sqlite3_column_bytes(st_get, 0));
                const seq: i64 = c.sqlite3_column_int64(st_get, 1);
                // Bind the current value as prev_value. SQLITE_STATIC is
                // safe because we complete the step inline before stepping
                // the get stmt again.
                _ = c.sqlite3_bind_blob(st_ins, 3, blob, @intCast(blen), c.SQLITE_STATIC);
                _ = c.sqlite3_bind_int64(st_ins, 4, seq);
            } else if (rc == c.SQLITE_DONE) {
                // Key didn't exist — prev_value is NULL.
                _ = c.sqlite3_bind_null(st_ins, 3);
                _ = c.sqlite3_bind_null(st_ins, 4);
            } else {
                _ = c.sqlite3_reset(st_get);
                return Error.Sqlite;
            }

            const ins_rc = c.sqlite3_step(st_ins);
            _ = c.sqlite3_reset(st_get);
            _ = c.sqlite3_reset(st_ins);
            if (ins_rc != c.SQLITE_DONE) return Error.Sqlite;
        }
    };

    /// Start a tracked transaction. Eagerly opens a SQLite txn and
    /// allocates a `txn_seq` from `kv_seq`. Caller must eventually call
    /// `commit` or `rollback`. Callers that want the hot-path no-fsync
    /// behavior for pure reads should use `beginTrackedImmediate`
    /// instead — it lazy-opens on first write.
    pub fn beginTracked(self: *KvStore) Error!TrackedTxn {
        try self.begin();
        errdefer self.rollback() catch {};
        const seq = self.nextSeq();
        if (seq == 0) return Error.Sqlite;
        return .{ .store = self, .txn_seq = seq, .kind = .normal, .opened = true };
    }

    /// Start a tracked transaction that lazily opens the underlying
    /// SQLite txn with `BEGIN IMMEDIATE` on the first `put`/`delete` —
    /// pure-reader handlers never allocate a seq, never INSERT into
    /// `kv_seq`, and never fsync the WAL. First-write callers block in
    /// SQLite's busy retry loop up to `busy_timeout` if another writer
    /// holds RESERVED.
    pub fn beginTrackedImmediate(self: *KvStore) Error!TrackedTxn {
        return .{ .store = self, .txn_seq = 0, .kind = .immediate, .opened = false };
    }

    /// Compensating rollback: walks the `kv_undo` rows for a SINGLE txn_seq
    /// (in unspecified key order — there's only one row per key per txn
    /// by virtue of the PRIMARY KEY) and restores each pre-image. Wraps
    /// the work in its own SQLite txn, so a crash mid-undo still leaves
    /// the row pointers consistent. Intended for workers that observe
    /// `faultedSeq >= my_seq` and need to discard their optimistic write.
    pub fn undoTxn(self: *KvStore, txn_seq: u64) Error!void {
        try self.begin();
        errdefer self.rollback() catch {};

        // We reuse stmt_undo_select_uncommitted by passing (txn_seq - 1),
        // which yields exactly this txn's rows (since txn_seq is monotonic
        // and we filter > that). The descending ORDER BY doesn't matter
        // for a single txn_seq.
        const st = self.stmt_undo_select_uncommitted;
        _ = c.sqlite3_reset(st);
        const lower: i64 = if (txn_seq == 0) -1 else @as(i64, @bitCast(txn_seq - 1));
        _ = c.sqlite3_bind_int64(st, 1, lower);

        // We have to buffer the rows because we'll be issuing other
        // statements against the same connection that would conflict with
        // an open cursor on kv_undo.
        const collected = try self.collectUndoRows(st, txn_seq, txn_seq);
        defer freeUndoRows(self.allocator, collected);

        for (collected) |row| try self.restoreOne(row);

        // Clear out the undo rows for this txn.
        try self.deleteUndoTxn(txn_seq);

        try self.commit();
    }

    /// Mark a single transaction as committed through the durability
    /// layer (raft or equivalent) and drop its `kv_undo` row. Called
    /// per-txn on the happy path so the compensating-rollback record
    /// is gone once it's no longer needed.
    ///
    /// Per-txn (not range) GC is required when multiple concurrent
    /// txns have different fates: one can commit while an earlier or
    /// later one still pends or faults. Using `gcUndoThrough` with a
    /// range would incorrectly delete unrelated pending txns' undo
    /// rows. `commitTxn` targets the specific `txn_seq` only.
    pub fn commitTxn(self: *KvStore, txn_seq: u64) Error!void {
        return self.deleteUndoTxn(txn_seq);
    }

    /// GC committed undo rows up through `committed_seq`. Safe to call any
    /// time; idempotent.
    pub fn gcUndoThrough(self: *KvStore, committed_seq: u64) Error!void {
        const st = self.stmt_undo_delete_committed;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(committed_seq));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    /// Startup orphan sweep. Called once after the raft log has been
    /// replayed and we know `committed_seq` (the max seq of all committed
    /// raft entries). Restores pre-images for any txn with seq above
    /// committed_seq (uncommitted, must be rolled back) and GCs the undo
    /// rows for txns with seq at or below committed_seq (committed, can be
    /// dropped). Atomic in one SQLite transaction.
    pub fn recoverOrphans(self: *KvStore, committed_seq: u64) Error!void {
        try self.begin();
        errdefer self.rollback() catch {};

        // Collect uncommitted rows in descending txn_seq order so we peel
        // the newest writes off first. Within a txn_seq the key order
        // doesn't affect correctness (each undo is independent), but we
        // get a deterministic order for free.
        const st = self.stmt_undo_select_uncommitted;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(committed_seq));

        const collected = try self.collectUndoRows(st, committed_seq + 1, std.math.maxInt(u64));
        defer freeUndoRows(self.allocator, collected);

        for (collected) |row| try self.restoreOne(row);

        // Everything at or below committed_seq is durable through raft;
        // just drop those rows. Everything above has been restored; drop
        // those too (we've already applied their undo).
        try self.deleteUndoBelowEq(committed_seq);
        try self.deleteUndoAbove(committed_seq);

        try self.commit();
    }

    const UndoRow = struct {
        txn_seq: u64,
        key: []u8,
        prev_value: ?[]u8,
        prev_seq: ?i64,
    };

    /// Collect rows from a cursor (must already have its parameters bound)
    /// into an owned slice. Called while the cursor is active on the
    /// connection, so we drain it fully before touching other statements.
    /// `min_seq`/`max_seq` are caller-provided bounds for defensive
    /// filtering — rows outside the range are skipped.
    fn collectUndoRows(
        self: *KvStore,
        st: *c.sqlite3_stmt,
        min_seq: u64,
        max_seq: u64,
    ) Error![]UndoRow {
        var list: std.ArrayList(UndoRow) = .empty;
        errdefer freeUndoRows(self.allocator, list.items);

        while (true) {
            const rc = c.sqlite3_step(st);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                _ = c.sqlite3_reset(st);
                return Error.Sqlite;
            }

            const txn_seq: u64 = @bitCast(c.sqlite3_column_int64(st, 0));
            if (txn_seq < min_seq or txn_seq > max_seq) continue;

            const k_ptr = c.sqlite3_column_text(st, 1);
            const k_len: usize = @intCast(c.sqlite3_column_bytes(st, 1));
            const k_copy = try self.allocator.alloc(u8, k_len);
            errdefer self.allocator.free(k_copy);
            if (k_len > 0) @memcpy(k_copy, @as([*]const u8, @ptrCast(k_ptr))[0..k_len]);

            var prev_value: ?[]u8 = null;
            if (c.sqlite3_column_type(st, 2) != c.SQLITE_NULL) {
                const v_ptr = c.sqlite3_column_blob(st, 2);
                const v_len: usize = @intCast(c.sqlite3_column_bytes(st, 2));
                const v_copy = try self.allocator.alloc(u8, v_len);
                errdefer self.allocator.free(v_copy);
                if (v_len > 0) @memcpy(v_copy, @as([*]const u8, @ptrCast(v_ptr))[0..v_len]);
                prev_value = v_copy;
            }

            const prev_seq: ?i64 = if (c.sqlite3_column_type(st, 3) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(st, 3);

            try list.append(self.allocator, .{
                .txn_seq = txn_seq,
                .key = k_copy,
                .prev_value = prev_value,
                .prev_seq = prev_seq,
            });
        }

        _ = c.sqlite3_reset(st);
        return try list.toOwnedSlice(self.allocator);
    }

    fn restoreOne(self: *KvStore, row: UndoRow) Error!void {
        if (row.prev_value) |pv| {
            // Restore (prev_value, prev_seq).
            const st = self.stmt_put_seq;
            _ = c.sqlite3_reset(st);
            bindText(st, 1, row.key);
            bindBlob(st, 2, pv);
            const seq_i64: i64 = row.prev_seq orelse 0;
            _ = c.sqlite3_bind_int64(st, 3, seq_i64);
            const rc = c.sqlite3_step(st);
            _ = c.sqlite3_reset(st);
            if (rc != c.SQLITE_DONE) return Error.Sqlite;
        } else {
            // Key didn't exist before the txn — delete it.
            const st = self.stmt_del;
            _ = c.sqlite3_reset(st);
            bindText(st, 1, row.key);
            const rc = c.sqlite3_step(st);
            _ = c.sqlite3_reset(st);
            if (rc != c.SQLITE_DONE) return Error.Sqlite;
        }
    }

    fn deleteUndoTxn(self: *KvStore, txn_seq: u64) Error!void {
        const st = self.stmt_undo_delete_txn;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(txn_seq));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    fn deleteUndoBelowEq(self: *KvStore, committed_seq: u64) Error!void {
        const st = self.stmt_undo_delete_committed;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(committed_seq));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    fn deleteUndoAbove(self: *KvStore, committed_seq: u64) Error!void {
        const st = self.stmt_undo_delete_uncommitted;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(committed_seq));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }
};

fn freeUndoRows(allocator: std.mem.Allocator, rows: []const KvStore.UndoRow) void {
    for (rows) |row| {
        allocator.free(row.key);
        if (row.prev_value) |pv| allocator.free(pv);
    }
    allocator.free(rows);
}

// ── helpers ────────────────────────────────────────────────────────────

fn prepare(db: *c.sqlite3, sql: []const u8) Error!*c.sqlite3_stmt {
    var st: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &st, null);
    if (rc != c.SQLITE_OK or st == null) return Error.Sqlite;
    return st.?;
}

/// Pin WAL mode + synchronous=FULL and verify both took. See the module
/// doc-comment for why these matter.
fn pinDurability(db: *c.sqlite3) Error!void {
    {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        if (c.sqlite3_step(st) != c.SQLITE_ROW) return Error.JournalMode;
        const text_ptr = c.sqlite3_column_text(st, 0);
        const text_len: usize = @intCast(c.sqlite3_column_bytes(st, 0));
        if (text_ptr == null or text_len == 0) return Error.JournalMode;
        const mode: []const u8 = @as([*]const u8, @ptrCast(text_ptr))[0..text_len];
        if (!std.ascii.eqlIgnoreCase(mode, "wal")) return Error.JournalMode;
    }
    // synchronous=NORMAL is the right level for tenant kv + log kv:
    // raft is the durability boundary, so an in-process fsync on every
    // kv commit is redundant. raft_log.db stays FULL (it's the source
    // of truth on restart). NORMAL still fsyncs at WAL checkpoints,
    // which is what we want — each commit just gets written to the WAL
    // page cache without blocking.
    if (c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", null, null, null) != c.SQLITE_OK) {
        return Error.SynchronousMode;
    }
    {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "PRAGMA synchronous;", -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        if (c.sqlite3_step(st) != c.SQLITE_ROW) return Error.SynchronousMode;
        if (c.sqlite3_column_int(st, 0) != 1) return Error.SynchronousMode;
    }
}

fn bindText(st: *c.sqlite3_stmt, idx: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(st, idx, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
}

fn bindBlob(st: *c.sqlite3_stmt, idx: c_int, blob: []const u8) void {
    _ = c.sqlite3_bind_blob(st, idx, blob.ptr, @intCast(blob.len), c.SQLITE_STATIC);
}

fn runVoid(st: *c.sqlite3_stmt) Error!void {
    _ = c.sqlite3_reset(st);
    const rc = c.sqlite3_step(st);
    _ = c.sqlite3_reset(st);
    if (rc == c.SQLITE_BUSY) return Error.Conflict;
    if (rc != c.SQLITE_DONE) return Error.Sqlite;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDbPath(buf: *[64]u8) [:0]const u8 {
    const ts = std.time.nanoTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(ts)));
    return std.fmt.bufPrintZ(buf, "/tmp/rove-kv-test-{x}.db", .{seed}) catch unreachable;
}

fn cleanupDb(path: [:0]const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var wal_buf: [128]u8 = undefined;
    var shm_buf: [128]u8 = undefined;
    const wal = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path}) catch return;
    const shm = std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path}) catch return;
    std.fs.cwd().deleteFile(wal) catch {};
    std.fs.cwd().deleteFile(shm) catch {};
}

test "open, put, get, delete" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("hello", "world");
    const v = try kv.get("hello");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("world", v);

    try kv.delete("hello");
    try testing.expectError(Error.NotFound, kv.get("hello"));
}

test "get on missing key returns NotFound" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try testing.expectError(Error.NotFound, kv.get("nope"));
}

test "binary blob round trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    const payload = [_]u8{ 0, 1, 2, 0xff, 0, 0xaa };
    try kv.put("bin", &payload);
    const v = try kv.get("bin");
    defer testing.allocator.free(v);
    try testing.expectEqualSlices(u8, &payload, v);
}

test "transaction commit and rollback" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.begin();
    try kv.put("a", "1");
    try kv.put("b", "2");
    try kv.commit();

    const a = try kv.get("a");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("1", a);

    try kv.begin();
    try kv.put("c", "3");
    try kv.rollback();
    try testing.expectError(Error.NotFound, kv.get("c"));
}

test "range scan" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("a/1", "x");
    try kv.put("a/2", "y");
    try kv.put("a/3", "z");
    try kv.put("b/1", "ignored");

    var r = try kv.range("a/", "a/~", 100);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.entries.len);
    try testing.expectEqualStrings("a/1", r.entries[0].key);
    try testing.expectEqualStrings("a/2", r.entries[1].key);
    try testing.expectEqualStrings("a/3", r.entries[2].key);
    try testing.expectEqualStrings("z", r.entries[2].value);
}

test "seq allocation and putSeq" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.begin();
    const s1 = kv.nextSeq();
    const s2 = kv.nextSeq();
    try testing.expect(s2 > s1);
    try kv.putSeq("k1", "v1", s1);
    try kv.putSeq("k2", "v2", s2);
    try kv.commit();

    try testing.expectEqual(s2, kv.maxSeq());
}

test "delta query" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.begin();
    const s1 = kv.nextSeq();
    try kv.putSeq("a", "1", s1);
    const s2 = kv.nextSeq();
    try kv.putSeq("b", "2", s2);
    const s3 = kv.nextSeq();
    try kv.putSeq("c", "3", s3);
    try kv.commit();

    var d = try kv.delta(s1, std.math.maxInt(u64));
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.entries.len);
    try testing.expectEqualStrings("b", d.entries[0].key);
    try testing.expectEqual(s2, d.entries[0].seq);
    try testing.expectEqualStrings("c", d.entries[1].key);
    try testing.expectEqual(s3, d.entries[1].seq);

    try kv.seqTruncate(s2);
    var d2 = try kv.delta(0, std.math.maxInt(u64));
    defer d2.deinit();
    // seqTruncate only removes from kv_seq, kv rows persist
    try testing.expectEqual(@as(usize, 3), d2.entries.len);
}

test "checkpoint and disable auto" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    kv.disableAutoCheckpoint();
    try kv.put("k", "v");
    try kv.checkpoint();
}

test "open pins WAL + synchronous=NORMAL" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    // Re-query the pragmas from the live connection and verify.
    var st: ?*c.sqlite3_stmt = null;
    try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_prepare_v2(kv.db, "PRAGMA journal_mode;", -1, &st, null));
    defer _ = c.sqlite3_finalize(st);
    try testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(st));
    const mode_ptr = c.sqlite3_column_text(st, 0);
    const mode_len: usize = @intCast(c.sqlite3_column_bytes(st, 0));
    const mode: []const u8 = @as([*]const u8, @ptrCast(mode_ptr))[0..mode_len];
    try testing.expect(std.ascii.eqlIgnoreCase(mode, "wal"));

    var st2: ?*c.sqlite3_stmt = null;
    try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_prepare_v2(kv.db, "PRAGMA synchronous;", -1, &st2, null));
    defer _ = c.sqlite3_finalize(st2);
    try testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(st2));
    try testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(st2, 0));
}

test "tracked txn: undo recovers orphan key (scenario A)" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    // First process: pretend a worker writes a new key via a tracked txn,
    // commits locally, but we never signal raft commit. Simulating the
    // "leader crashed between kv.commit() and raft_committed_seq advance"
    // scenario by just closing without GCing the undo row.
    {
        var kv = try KvStore.open(testing.allocator, path);
        defer kv.close();

        var txn = try kv.beginTracked();
        try txn.put("orphan", "pending");
        try txn.commit();

        // Confirm the row is visible right now.
        const v = try kv.get("orphan");
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("pending", v);
    }

    // Second process: the raft log had nothing committed past seq 0, so
    // the orphan must be swept on startup.
    {
        var kv = try KvStore.open(testing.allocator, path);
        defer kv.close();

        // Row is still there before recovery.
        const v_before = try kv.get("orphan");
        testing.allocator.free(v_before);

        try kv.recoverOrphans(0);

        try testing.expectError(Error.NotFound, kv.get("orphan"));
    }
}

test "tracked txn: undo restores overwritten committed value" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    // Anchor: write "original" via a tracked txn, then mark it committed
    // by GC'ing its undo row (simulating raft ack).
    var anchor = try kv.beginTracked();
    const anchor_seq = anchor.txn_seq;
    try anchor.put("k", "original");
    try anchor.commit();
    try kv.gcUndoThrough(anchor_seq);

    // A worker now overwrites.
    var txn = try kv.beginTracked();
    try testing.expect(txn.txn_seq > anchor_seq);
    try txn.put("k", "pending");
    try txn.commit();

    const during = try kv.get("k");
    defer testing.allocator.free(during);
    try testing.expectEqualStrings("pending", during);

    // Pretend raft faulted. committed_seq stays at the anchor, so the
    // worker's txn falls into the "uncommitted, must be rolled back"
    // bucket.
    try kv.recoverOrphans(anchor_seq);

    const after = try kv.get("k");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("original", after);
}

test "tracked txn: committed txns are GC'd not undone" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    // Worker writes and commits a tracked txn.
    var txn = try kv.beginTracked();
    const seq = txn.txn_seq;
    try txn.put("committed_key", "value");
    try txn.commit();

    // Pretend raft committed this seq — recoverOrphans should GC the
    // undo row but leave the forward write alone.
    try kv.recoverOrphans(seq);

    const v = try kv.get("committed_key");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("value", v);
}

test "tracked txn: multiple uncommitted txns undo in descending order" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    // Anchor via tracked txn so kv_seq advances too. Then GC the undo
    // row to simulate raft committing the anchor.
    var anchor = try kv.beginTracked();
    const anchor_seq = anchor.txn_seq;
    try anchor.put("hot", "v0");
    try anchor.commit();
    try kv.gcUndoThrough(anchor_seq);

    // Worker A: reads v0, writes v1.
    var a = try kv.beginTracked();
    try a.put("hot", "v1");
    try a.commit();

    // Worker B: reads v1 (A's pending — visible because SQLite serializes
    // them and A committed first), writes v2.
    var b = try kv.beginTracked();
    try b.put("hot", "v2");
    try b.commit();

    // Now both txns fault. committed_seq is the anchor. The sweep must
    // peel B's undo first (restoring v1), then A's (restoring v0).
    try kv.recoverOrphans(anchor_seq);

    const v = try kv.get("hot");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("v0", v);
}

test "undoTxn rolls back a single txn in place" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    var anchor = try kv.beginTracked();
    try anchor.put("k", "before");
    try anchor.commit();
    try kv.gcUndoThrough(anchor.txn_seq);

    var txn = try kv.beginTracked();
    try txn.put("k", "after");
    try txn.commit();

    try kv.undoTxn(txn.txn_seq);

    const v = try kv.get("k");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("before", v);
}

test "checkpointV2 drains the WAL and reports frame counts" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    // Turn off auto-checkpoint so writes accumulate in the WAL until we
    // call checkpointV2 ourselves.
    kv.disableAutoCheckpoint();

    // Write enough rows that at least one frame lands in the WAL. Exact
    // count depends on SQLite page size and row layout.
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        var k_buf: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&k_buf, "key-{d}", .{i}) catch unreachable;
        try kv.put(k, "value");
    }

    const result = try kv.checkpointV2();
    // With no other readers, a PASSIVE checkpoint drains everything it
    // saw — log_pages should equal ckpt_pages.
    try testing.expectEqual(result.log_pages, result.ckpt_pages);
}
