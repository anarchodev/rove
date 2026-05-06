//! SQLite plumbing for `KvStore`: SQL string constants, statement
//! preparation, durability pragmas, and bind/step helpers.
//!
//! This module is structurally a binding layer — it does NOT know about
//! the durability contract (raft commit vs. local commit, undo log
//! semantics, seq allocation). All of that lives in `kvstore.zig`,
//! which composes these primitives. Splitting them keeps the
//! crash-safety story (TrackedTxn / captureUndo / undoTxn /
//! recoverOrphans) in one focused file.

const std = @import("std");

pub const c = @cImport({
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

// ── Schema ────────────────────────────────────────────────────────────

pub const SQL_CREATE =
    \\CREATE TABLE IF NOT EXISTS kv (
    \\  key   TEXT PRIMARY KEY NOT NULL,
    \\  value BLOB NOT NULL,
    \\  seq   INTEGER NOT NULL DEFAULT 0
    \\) WITHOUT ROWID;
;

pub const SQL_CREATE_SEQ =
    \\CREATE TABLE IF NOT EXISTS kv_seq (id INTEGER PRIMARY KEY AUTOINCREMENT);
;

// Index on kv.seq so `MAX(seq)` at open is O(log n) and the delta
// replication query (`WHERE seq > ? AND seq <= ?`) is a range scan
// instead of a full table scan. Created lazily inside openInternal so
// existing databases pick it up on next open without a migration step.
pub const SQL_CREATE_SEQ_INDEX =
    \\CREATE INDEX IF NOT EXISTS kv_seq_idx ON kv (seq);
;

// Undo log. See kvstore.zig's module doc comment for the full
// rationale. Briefly: a `TrackedTxn` captures the pre-image of every
// key it touches so a crash between local commit and raft commit can
// be rolled back on startup. A NULL `prev_value` means "this key
// didn't exist before the txn" — the undo action is then a delete
// rather than a restore.
pub const SQL_CREATE_UNDO =
    \\CREATE TABLE IF NOT EXISTS kv_undo (
    \\  txn_seq    INTEGER NOT NULL,
    \\  key        TEXT    NOT NULL,
    \\  prev_value BLOB,
    \\  prev_seq   INTEGER,
    \\  PRIMARY KEY (txn_seq, key)
    \\) WITHOUT ROWID;
;

// Phase 5.5(c) — per-store apply-state for the snapshot model.
// Each replicated store (per-tenant app.db, __root__.db, webhooks.db)
// stamps `('last_applied_raft_idx', N)` here inside the same SQLite
// transaction as every applied writeset. The follower-side snapshot
// load populates it from the manifest's `snapshot_idx`; subsequent
// raft entries replay through the apply path with `idx <= last_applied`
// short-circuited so nothing applies twice. Default empty (= 0); on a
// pre-snapshot db every committed raft entry is "new" relative to the
// floor, which matches today's behavior.
pub const SQL_CREATE_APPLY_STATE =
    \\CREATE TABLE IF NOT EXISTS _apply_state (
    \\  k TEXT PRIMARY KEY NOT NULL,
    \\  v INTEGER NOT NULL
    \\) WITHOUT ROWID;
;
pub const SQL_GET_APPLY_STATE = "SELECT v FROM _apply_state WHERE k = ?;";
pub const SQL_PUT_APPLY_STATE = "INSERT OR REPLACE INTO _apply_state (k, v) VALUES (?, ?);";
pub const APPLY_STATE_KEY_LAST_APPLIED: []const u8 = "last_applied_raft_idx";

// ── Prepared statement SQL ────────────────────────────────────────────

pub const SQL_GET = "SELECT value FROM kv WHERE key = ?;";
pub const SQL_PUT = "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?);";
pub const SQL_PUT_SEQ = "INSERT OR REPLACE INTO kv (key, value, seq) VALUES (?, ?, ?);";
pub const SQL_DEL = "DELETE FROM kv WHERE key = ?;";
pub const SQL_PREFIX = "SELECT key, value FROM kv WHERE key >= ? AND key < ? ORDER BY key LIMIT ?;";
pub const SQL_DELTA = "SELECT key, value, seq FROM kv WHERE seq > ? AND seq <= ? ORDER BY seq;";
pub const SQL_BEGIN = "BEGIN;";

// BEGIN IMMEDIATE acquires RESERVED at begin time, serializing
// concurrent writers up front (they block inside SQLite's busy retry
// loop for up to `busy_timeout` ms). Used by rove-js so per-tenant
// handler transactions get clean FIFO serialization without bubbling
// SQLITE_BUSY up to the dispatcher.
pub const SQL_BEGIN_IMMEDIATE = "BEGIN IMMEDIATE;";
pub const SQL_COMMIT = "COMMIT;";
pub const SQL_ROLLBACK = "ROLLBACK;";
pub const SQL_MAX_SEQ = "SELECT MAX(seq) FROM kv;";

// Initial seq for a fresh store / for verifying migration from an older
// schema. Reads the historical high-water mark from kv_seq's
// `sqlite_sequence` row — AUTOINCREMENT tracks "max id ever used" even
// after rows are deleted, so this is stable across restarts. Seq
// allocation is now done in-memory (see `SeqCounter`), but we still
// seed from max(kv_seq historical max, MAX(kv.seq)) so an upgrade from
// the old per-write-INSERT scheme never reuses a value.
pub const SQL_MAX_SEQ_SEQUENCE = "SELECT COALESCE(seq, 0) FROM sqlite_sequence WHERE name = 'kv_seq';";

// ── Undo log statements ───────────────────────────────────────────────
//
// `SQL_UNDO_CAPTURE` folds the "SELECT prev value, seq FROM kv / bind /
// INSERT OR IGNORE INTO kv_undo" pair into a single statement. The
// one-row literal subquery (`SELECT ?2 AS key`) guarantees we always
// generate exactly one candidate undo row — the LEFT JOIN fills
// prev_value/prev_seq with NULLs when the key did not exist. On the
// second+ capture for the same (txn_seq, key) pair within one txn,
// `INSERT OR IGNORE` no-ops, so only the first pre-image sticks —
// same contract as the old two-statement path.
pub const SQL_UNDO_CAPTURE =
    \\INSERT OR IGNORE INTO kv_undo (txn_seq, key, prev_value, prev_seq)
    \\SELECT ?1, lit.key, k.value, k.seq
    \\FROM (SELECT ?2 AS key) AS lit
    \\LEFT JOIN kv AS k ON k.key = lit.key;
;
pub const SQL_UNDO_SELECT_UNCOMMITTED =
    \\SELECT txn_seq, key, prev_value, prev_seq FROM kv_undo
    \\WHERE txn_seq > ?
    \\ORDER BY txn_seq DESC, key;
;
pub const SQL_UNDO_DELETE_COMMITTED = "DELETE FROM kv_undo WHERE txn_seq <= ?;";
pub const SQL_UNDO_DELETE_UNCOMMITTED = "DELETE FROM kv_undo WHERE txn_seq > ?;";
pub const SQL_UNDO_DELETE_TXN = "DELETE FROM kv_undo WHERE txn_seq = ?;";

// Single reusable savepoint name. Handlers in a batched dispatch run
// sequentially — each one SAVEPOINT+RELEASE (or ROLLBACK TO) before
// the next starts — so there's never more than one savepoint live at
// once, and reusing the name is safe. Using a fixed name lets us
// prepare these statements once at open time instead of formatting a
// new savepoint name per handler.
pub const SQL_SAVEPOINT_H = "SAVEPOINT h;";
pub const SQL_RELEASE_H = "RELEASE h;";
pub const SQL_ROLLBACK_TO_H = "ROLLBACK TO h;";

// ── Helpers ───────────────────────────────────────────────────────────

pub fn prepare(db: *c.sqlite3, sql: []const u8) Error!*c.sqlite3_stmt {
    var st: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &st, null);
    if (rc != c.SQLITE_OK or st == null) return Error.Sqlite;
    return st.?;
}

/// Pin WAL mode + synchronous=NORMAL and verify both took.
pub fn pinDurability(db: *c.sqlite3) Error!void {
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

/// Read max(MAX(kv.seq), sqlite_sequence['kv_seq']) — the historical
/// high-water mark. AUTOINCREMENT preserves this across restarts even
/// after we stopped INSERTing into kv_seq. Returns 0 on a fresh db.
pub fn readSeqFloor(db: *c.sqlite3) u64 {
    var floor: u64 = 0;

    var st1: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, SQL_MAX_SEQ, -1, &st1, null) == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(st1);
        if (c.sqlite3_step(st1) == c.SQLITE_ROW) {
            const v: u64 = @bitCast(c.sqlite3_column_int64(st1, 0));
            if (v > floor) floor = v;
        }
    }

    var st2: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, SQL_MAX_SEQ_SEQUENCE, -1, &st2, null) == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(st2);
        if (c.sqlite3_step(st2) == c.SQLITE_ROW) {
            const v: u64 = @bitCast(c.sqlite3_column_int64(st2, 0));
            if (v > floor) floor = v;
        }
    }

    return floor;
}

pub fn bindText(st: *c.sqlite3_stmt, idx: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(st, idx, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
}

pub fn bindBlob(st: *c.sqlite3_stmt, idx: c_int, blob: []const u8) void {
    _ = c.sqlite3_bind_blob(st, idx, blob.ptr, @intCast(blob.len), c.SQLITE_STATIC);
}

/// Reset → step → reset. Returns Conflict on SQLITE_BUSY (BEGIN
/// IMMEDIATE collisions show up here), Sqlite on any other non-DONE
/// status. The bracketing reset ensures the statement is left in a
/// clean state regardless of step outcome.
pub fn runVoid(st: *c.sqlite3_stmt) Error!void {
    _ = c.sqlite3_reset(st);
    const rc = c.sqlite3_step(st);
    _ = c.sqlite3_reset(st);
    if (rc == c.SQLITE_BUSY) return Error.Conflict;
    if (rc != c.SQLITE_DONE) return Error.Sqlite;
}
