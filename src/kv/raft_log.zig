//! SQLite-backed raft log + persistent state (currentTerm, votedFor).
//!
//! ## Durability contract
//!
//! Every `append`, `saveState`, `truncateAfter`, `truncateBefore` call
//! MUST be durable on disk before returning. This is what willemt/raft
//! expects from its `persist_term`, `persist_vote`, `log_offer`, `log_pop`,
//! and `log_poll` callbacks — and it's what the raft algorithm's safety
//! property depends on: a node must not acknowledge an AppendEntries or
//! RequestVote whose effects aren't on disk, because a crash-restart must
//! never expose a weaker view of history than what was acked.
//!
//! We get this by:
//!
//! 1. **WAL mode**: `PRAGMA journal_mode=WAL`. Verified at open — if the
//!    filesystem can't do WAL (rare, e.g. some network mounts), `open`
//!    returns `Error.JournalMode` rather than silently falling back to
//!    rollback-journal semantics we haven't audited.
//!
//! 2. **`synchronous=FULL`**: each auto-commit statement triggers an
//!    fsync of the WAL file before returning. This is SQLite's default
//!    but we pin it explicitly so a future edit can't quietly weaken
//!    durability.
//!
//! 3. **Auto-commit per statement**: none of the methods here wrap work
//!    in an explicit transaction. Each `sqlite3_step` becomes its own
//!    one-statement transaction, which in WAL+FULL mode fsyncs on commit.
//!
//! What this does NOT protect against:
//!   - A misbehaving filesystem that lies about fsync (ext4 with
//!     `barrier=0`, some network filesystems). Out of rove-kv's control.
//!   - Bit rot on disk after the write has landed. SQLite's WAL does frame
//!     checksums so torn writes are caught at read time and rejected, but
//!     silent media corruption on pages already written is not.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    NotFound,
    Sqlite,
    /// `PRAGMA journal_mode=WAL` didn't take — the underlying filesystem
    /// or SQLite build doesn't support WAL. The durability guarantees this
    /// module promises depend on WAL mode, so we refuse to open rather
    /// than silently degrade.
    JournalMode,
    /// `PRAGMA synchronous=FULL` didn't take or failed to report back.
    SynchronousMode,
    OutOfMemory,
};

pub const Entry = struct {
    index: u64,
    term: u64,
    data: []u8,
};

pub const PersistentState = struct {
    term: u64,
    voted_for: i32,
};

const SQL_CREATE_LOG =
    \\CREATE TABLE IF NOT EXISTS raft_log (
    \\  idx  INTEGER PRIMARY KEY,
    \\  term INTEGER NOT NULL,
    \\  data BLOB NOT NULL
    \\);
;

const SQL_CREATE_STATE =
    \\CREATE TABLE IF NOT EXISTS raft_state (
    \\  id           INTEGER PRIMARY KEY CHECK (id = 1),
    \\  current_term INTEGER NOT NULL DEFAULT 0,
    \\  voted_for    INTEGER NOT NULL DEFAULT -1
    \\);
;

const SQL_SEED_STATE =
    \\INSERT OR IGNORE INTO raft_state (id, current_term, voted_for)
    \\VALUES (1, 0, -1);
;

const SQL_APPEND = "INSERT OR REPLACE INTO raft_log (idx, term, data) VALUES (?, ?, ?);";
const SQL_GET = "SELECT term, data FROM raft_log WHERE idx = ?;";
const SQL_TRUNC_AFTER = "DELETE FROM raft_log WHERE idx > ?;";
const SQL_TRUNC_BEFORE = "DELETE FROM raft_log WHERE idx <= ?;";
const SQL_LAST = "SELECT idx, term FROM raft_log ORDER BY idx DESC LIMIT 1;";
const SQL_SAVE_STATE = "UPDATE raft_state SET current_term = ?, voted_for = ? WHERE id = 1;";
const SQL_LOAD_STATE = "SELECT current_term, voted_for FROM raft_state WHERE id = 1;";

pub const RaftLog = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    stmt_append: *c.sqlite3_stmt,
    stmt_get: *c.sqlite3_stmt,
    stmt_trunc_after: *c.sqlite3_stmt,
    stmt_trunc_before: *c.sqlite3_stmt,
    stmt_last: *c.sqlite3_stmt,
    stmt_save_state: *c.sqlite3_stmt,
    stmt_load_state: *c.sqlite3_stmt,

    pub fn open(allocator: std.mem.Allocator, db_path: [:0]const u8) Error!*RaftLog {
        const self = try allocator.create(RaftLog);
        errdefer allocator.destroy(self);

        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(db_path.ptr, &db, flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return Error.Sqlite;
        }
        errdefer _ = c.sqlite3_close(db.?);

        try pinDurability(db.?);
        _ = c.sqlite3_exec(db, "PRAGMA busy_timeout=5000;", null, null, null);

        if (c.sqlite3_exec(db, SQL_CREATE_LOG, null, null, null) != c.SQLITE_OK) return Error.Sqlite;
        if (c.sqlite3_exec(db, SQL_CREATE_STATE, null, null, null) != c.SQLITE_OK) return Error.Sqlite;
        if (c.sqlite3_exec(db, SQL_SEED_STATE, null, null, null) != c.SQLITE_OK) return Error.Sqlite;

        self.allocator = allocator;
        self.db = db.?;

        var prepared: usize = 0;
        const stmts = [_]struct { sql: []const u8, field: []const u8 }{
            .{ .sql = SQL_APPEND, .field = "stmt_append" },
            .{ .sql = SQL_GET, .field = "stmt_get" },
            .{ .sql = SQL_TRUNC_AFTER, .field = "stmt_trunc_after" },
            .{ .sql = SQL_TRUNC_BEFORE, .field = "stmt_trunc_before" },
            .{ .sql = SQL_LAST, .field = "stmt_last" },
            .{ .sql = SQL_SAVE_STATE, .field = "stmt_save_state" },
            .{ .sql = SQL_LOAD_STATE, .field = "stmt_load_state" },
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

    pub fn close(self: *RaftLog) void {
        _ = c.sqlite3_finalize(self.stmt_append);
        _ = c.sqlite3_finalize(self.stmt_get);
        _ = c.sqlite3_finalize(self.stmt_trunc_after);
        _ = c.sqlite3_finalize(self.stmt_trunc_before);
        _ = c.sqlite3_finalize(self.stmt_last);
        _ = c.sqlite3_finalize(self.stmt_save_state);
        _ = c.sqlite3_finalize(self.stmt_load_state);
        _ = c.sqlite3_close(self.db);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Append (or overwrite) an entry at the given index.
    pub fn append(self: *RaftLog, index: u64, term: u64, data: []const u8) Error!void {
        const st = self.stmt_append;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(index));
        _ = c.sqlite3_bind_int64(st, 2, @bitCast(term));
        _ = c.sqlite3_bind_blob(st, 3, data.ptr, @intCast(data.len), c.SQLITE_STATIC);

        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    /// Get a single entry. Returned `data` is owned by the caller (use the
    /// allocator passed to open() to free).
    pub fn get(self: *RaftLog, index: u64) Error!Entry {
        const st = self.stmt_get;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(index));

        const rc = c.sqlite3_step(st);
        defer _ = c.sqlite3_reset(st);

        if (rc == c.SQLITE_ROW) {
            const term: u64 = @bitCast(c.sqlite3_column_int64(st, 0));
            const blob = c.sqlite3_column_blob(st, 1);
            const blen: usize = @intCast(c.sqlite3_column_bytes(st, 1));
            const copy = try self.allocator.alloc(u8, blen);
            if (blen > 0) {
                @memcpy(copy, @as([*]const u8, @ptrCast(blob))[0..blen]);
            }
            return .{ .index = index, .term = term, .data = copy };
        }
        if (rc == c.SQLITE_DONE) return Error.NotFound;
        return Error.Sqlite;
    }

    /// Delete all entries with index > after_index.
    pub fn truncateAfter(self: *RaftLog, after_index: u64) Error!void {
        const st = self.stmt_trunc_after;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(after_index));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    /// Delete all entries with index <= through_index (compaction).
    pub fn truncateBefore(self: *RaftLog, through_index: u64) Error!void {
        const st = self.stmt_trunc_before;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(through_index));
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    /// Returns (index, term) of the last entry, or (0, 0) if the log is empty.
    pub fn last(self: *RaftLog) Error!struct { index: u64, term: u64 } {
        const st = self.stmt_last;
        _ = c.sqlite3_reset(st);
        const rc = c.sqlite3_step(st);
        defer _ = c.sqlite3_reset(st);

        if (rc == c.SQLITE_ROW) {
            return .{
                .index = @bitCast(c.sqlite3_column_int64(st, 0)),
                .term = @bitCast(c.sqlite3_column_int64(st, 1)),
            };
        }
        if (rc == c.SQLITE_DONE) return .{ .index = 0, .term = 0 };
        return Error.Sqlite;
    }

    pub fn saveState(self: *RaftLog, term: u64, voted_for: i32) Error!void {
        const st = self.stmt_save_state;
        _ = c.sqlite3_reset(st);
        _ = c.sqlite3_bind_int64(st, 1, @bitCast(term));
        _ = c.sqlite3_bind_int(st, 2, voted_for);
        const rc = c.sqlite3_step(st);
        _ = c.sqlite3_reset(st);
        if (rc != c.SQLITE_DONE) return Error.Sqlite;
    }

    pub fn loadState(self: *RaftLog) Error!PersistentState {
        const st = self.stmt_load_state;
        _ = c.sqlite3_reset(st);
        const rc = c.sqlite3_step(st);
        defer _ = c.sqlite3_reset(st);

        if (rc == c.SQLITE_ROW) {
            return .{
                .term = @bitCast(c.sqlite3_column_int64(st, 0)),
                .voted_for = c.sqlite3_column_int(st, 1),
            };
        }
        if (rc == c.SQLITE_DONE) return .{ .term = 0, .voted_for = -1 };
        return Error.Sqlite;
    }
};

fn prepare(db: *c.sqlite3, sql: []const u8) Error!*c.sqlite3_stmt {
    var st: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &st, null);
    if (rc != c.SQLITE_OK or st == null) return Error.Sqlite;
    return st.?;
}

/// Apply the pragmas that give us the durability contract described at
/// the top of this file, verifying each one actually took.
fn pinDurability(db: *c.sqlite3) Error!void {
    // journal_mode=WAL returns the resulting mode as a TEXT row. A quiet
    // fallback to rollback-journal yields mode "delete" (or similar).
    {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        const rc = c.sqlite3_step(st);
        if (rc != c.SQLITE_ROW) return Error.JournalMode;
        const text_ptr = c.sqlite3_column_text(st, 0);
        const text_len: usize = @intCast(c.sqlite3_column_bytes(st, 0));
        if (text_ptr == null or text_len == 0) return Error.JournalMode;
        const mode: []const u8 = @as([*]const u8, @ptrCast(text_ptr))[0..text_len];
        if (!std.ascii.eqlIgnoreCase(mode, "wal")) return Error.JournalMode;
    }
    // synchronous=FULL (value 2). Confirm by reading it back.
    if (c.sqlite3_exec(db, "PRAGMA synchronous=FULL;", null, null, null) != c.SQLITE_OK) {
        return Error.SynchronousMode;
    }
    {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "PRAGMA synchronous;", -1, &st, null) != c.SQLITE_OK) return Error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        if (c.sqlite3_step(st) != c.SQLITE_ROW) return Error.SynchronousMode;
        const sync_level = c.sqlite3_column_int(st, 0);
        if (sync_level != 2) return Error.SynchronousMode; // 2 = FULL
    }
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDbPath(buf: *[64]u8) [:0]const u8 {
    const ts = std.time.nanoTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(ts)));
    return std.fmt.bufPrintZ(buf, "/tmp/rove-raftlog-test-{x}.db", .{seed}) catch unreachable;
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

test "open empty log returns last (0, 0)" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();

    const l = try log.last();
    try testing.expectEqual(@as(u64, 0), l.index);
    try testing.expectEqual(@as(u64, 0), l.term);
}

test "append and get" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();

    try log.append(1, 1, "hello");
    try log.append(2, 1, "world");
    try log.append(3, 2, "!");

    const e = try log.get(2);
    defer testing.allocator.free(e.data);
    try testing.expectEqual(@as(u64, 2), e.index);
    try testing.expectEqual(@as(u64, 1), e.term);
    try testing.expectEqualStrings("world", e.data);

    const l = try log.last();
    try testing.expectEqual(@as(u64, 3), l.index);
    try testing.expectEqual(@as(u64, 2), l.term);
}

test "get on missing index returns NotFound" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();

    try testing.expectError(Error.NotFound, log.get(42));
}

test "append overwrites existing index" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();

    try log.append(1, 1, "first");
    try log.append(1, 2, "second");

    const e = try log.get(1);
    defer testing.allocator.free(e.data);
    try testing.expectEqual(@as(u64, 2), e.term);
    try testing.expectEqualStrings("second", e.data);
}

test "truncateAfter and truncateBefore" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();

    try log.append(1, 1, "a");
    try log.append(2, 1, "b");
    try log.append(3, 1, "c");
    try log.append(4, 1, "d");
    try log.append(5, 1, "e");

    try log.truncateAfter(3);
    const l1 = try log.last();
    try testing.expectEqual(@as(u64, 3), l1.index);
    try testing.expectError(Error.NotFound, log.get(4));

    try log.truncateBefore(2);
    try testing.expectError(Error.NotFound, log.get(1));
    try testing.expectError(Error.NotFound, log.get(2));
    const e = try log.get(3);
    defer testing.allocator.free(e.data);
    try testing.expectEqualStrings("c", e.data);
}

test "save and load persistent state" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();

    const initial = try log.loadState();
    try testing.expectEqual(@as(u64, 0), initial.term);
    try testing.expectEqual(@as(i32, -1), initial.voted_for);

    try log.saveState(7, 3);
    const s = try log.loadState();
    try testing.expectEqual(@as(u64, 7), s.term);
    try testing.expectEqual(@as(i32, 3), s.voted_for);
}

test "state survives close and reopen" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    {
        var log = try RaftLog.open(testing.allocator, path);
        defer log.close();
        try log.append(1, 5, "x");
        try log.saveState(5, 2);
    }

    var log = try RaftLog.open(testing.allocator, path);
    defer log.close();
    const s = try log.loadState();
    try testing.expectEqual(@as(u64, 5), s.term);
    try testing.expectEqual(@as(i32, 2), s.voted_for);

    const e = try log.get(1);
    defer testing.allocator.free(e.data);
    try testing.expectEqual(@as(u64, 5), e.term);
}
