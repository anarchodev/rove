//! rove-log-server — per-instance log read operations.
//!
//! Mirror of `rove-files-server/root.zig` for the observability side.
//! The worker forwards `/_system/log/{instance}/*` requests to the
//! log-server thread, which services them against each tenant's
//! `{data_dir}/{instance}/log.db` + `log-blobs/` using a fresh
//! **read-only** SQLite connection per call.
//!
//! ## Why read-only
//!
//! The worker's h2 thread owns the log.db **writer** — it's the only
//! thread that calls `LogStore.append` / `LogStore.applyBatch`,
//! serialized through the h2 event loop. That invariant is load-
//! bearing because rove-kv opens SQLite connections with NOMUTEX
//! (one connection per thread). Opening a writer from the log-server
//! thread would violate it; opening a second thread that also writes
//! would violate it transitively. Read-only is safe — WAL journal
//! mode supports many readers + one writer, and `openReadOnly`
//! skips all DDL so the two connections can't race on schema.
//!
//! ## Operations exposed
//!
//! - `list(instance, limit)` — newest-first summaries of the last N
//!   records, via `LogStore.list`.
//! - `show(instance, request_id)` — the full record, including
//!   console / exception text and tape refs, via `LogStore.get`.
//! - `getBlob(instance, key)` — raw bytes from the tenant's
//!   `log-blobs/` (tape blobs, or eventually S3-offloaded batch
//!   payloads). Used by the replay path so the browser shim can
//!   fetch the tape data referenced on a log record.
//! - `count(instance)` — total record count. Useful for smoke tests
//!   and "am I catching up with the raft log?" sanity checks.
//!
//! Bundle assembly (what `rove-log-cli bundle` does today) stays
//! outside this module for now — it spans multiple subsystems
//! (source blob lookup via rove-files, record fetch here) and will
//! become a ctl-side operation once the log-server also exposes the
//! code-source route. Layering order: compose from the client side.

const std = @import("std");
const kv_mod = @import("rove-kv");
const blob_mod = @import("rove-blob");
const log_mod = @import("rove-log");

pub const thread = @import("thread.zig");

pub const Error = error{
    InvalidInstanceId,
    OutOfMemory,
    Io,
    Kv,
    Blob,
    NotFound,
    InvalidManifest,
};

pub const MAX_INSTANCE_ID_LEN: usize = 128;

fn validateInstanceId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > MAX_INSTANCE_ID_LEN) return Error.InvalidInstanceId;
    for (id) |b| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_';
        if (!ok) return Error.InvalidInstanceId;
    }
}

/// Stack-local instance context. Like `files_server.InstanceCtx`,
/// this MUST be constructed in place (not returned by value) because
/// `log_mod.LogStore` holds a `BlobStore` vtable pointing at
/// `&self.blob_backend` — moving the struct would leave that
/// pointer dangling.
const InstanceCtx = struct {
    allocator: std.mem.Allocator,
    kv: *kv_mod.KvStore,
    blob_backend: blob_mod.FilesystemBlobStore,
    store: log_mod.LogStore,

    fn initReadOnly(
        self: *InstanceCtx,
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        instance_id: []const u8,
    ) Error!void {
        try validateInstanceId(instance_id);

        const db_path = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}/log.db",
            .{ data_dir, instance_id },
            0,
        ) catch return Error.OutOfMemory;
        defer allocator.free(db_path);

        const blob_dir = std.fmt.allocPrint(
            allocator,
            "{s}/{s}/log-blobs",
            .{ data_dir, instance_id },
        ) catch return Error.OutOfMemory;
        defer allocator.free(blob_dir);

        self.allocator = allocator;
        self.kv = kv_mod.KvStore.openReadOnly(allocator, db_path) catch
            return Error.Kv;
        errdefer self.kv.close();

        self.blob_backend = blob_mod.FilesystemBlobStore.open(allocator, blob_dir) catch
            return Error.Blob;
        errdefer self.blob_backend.deinit();

        // worker_id = 0 is fine: list / get / applyBatch don't
        // consume request ids. `nextRequestId` would be the only
        // caller affected, and this read-only context never calls it.
        self.store = log_mod.LogStore.init(
            allocator,
            self.kv,
            self.blob_backend.blobStore(),
            0,
        ) catch return Error.Kv;
    }

    fn deinit(self: *InstanceCtx) void {
        self.store.deinit();
        self.blob_backend.deinit();
        self.kv.close();
    }
};

/// List recent log records for `instance`, newest first. Returns an
/// owned `ListResult` the caller must `deinit`.
pub fn listRecords(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    limit: u32,
) Error!log_mod.ListResult {
    var h: InstanceCtx = undefined;
    try h.initReadOnly(allocator, data_dir, instance_id);
    defer h.deinit();
    return h.store.list(.{ .limit = limit }) catch |err| mapLogError(err);
}

/// Fetch a single log record by request id. Returns `null` if the
/// record isn't present in the tenant's log store (e.g. it was
/// created on a different node that hasn't replicated yet, or it
/// was GC'd by a retention sweep).
pub fn getRecord(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    request_id: u64,
) Error!?log_mod.LogRecord {
    var h: InstanceCtx = undefined;
    try h.initReadOnly(allocator, data_dir, instance_id);
    defer h.deinit();
    return h.store.get(request_id) catch |err| mapLogError(err);
}

/// Return the total count of log records for `instance`. Implemented
/// as "list everything, count it" since rove-log doesn't expose a
/// direct `count` API — fine for the sizes we care about today, but
/// should become a native count in rove-log when retention lands.
pub fn countRecords(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
) Error!usize {
    var h: InstanceCtx = undefined;
    try h.initReadOnly(allocator, data_dir, instance_id);
    defer h.deinit();
    var result = h.store.list(.{ .limit = std.math.maxInt(u32) }) catch |err|
        return mapLogError(err);
    defer result.deinit();
    return result.records.len;
}

/// Fetch raw bytes from the tenant's log-blob store by hash key.
/// Used by the replay path for tape blobs stamped onto records via
/// `LogRecord.tape_refs`.
pub fn getBlob(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    key: []const u8,
) Error![]u8 {
    try validateInstanceId(instance_id);

    const blob_dir = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/log-blobs",
        .{ data_dir, instance_id },
    ) catch return Error.OutOfMemory;
    defer allocator.free(blob_dir);

    var backend = blob_mod.FilesystemBlobStore.open(allocator, blob_dir) catch
        return Error.Blob;
    defer backend.deinit();

    return backend.blobStore().get(key, allocator) catch Error.NotFound;
}

fn mapLogError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.NotFound => Error.NotFound,
        error.InvalidRecord, error.CorruptStore => Error.InvalidManifest,
        error.Kv => Error.Kv,
        else => Error.Kv,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrint(allocator, "/tmp/rove-ls-{x}", .{seed});
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    return path;
}

/// Write a single record through a writer LogStore so the read-only
/// operations have something to find. Opens a read-write connection
/// in the current thread, writes + flushes, closes. The log-server
/// read operations then open a separate read-only connection under
/// the hood and see the persisted state.
fn seedLogStore(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    count: usize,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/log.db", .{inst_dir}, 0);
    defer allocator.free(db_path);
    const blob_dir = try std.fmt.allocPrint(allocator, "{s}/log-blobs", .{inst_dir});
    defer allocator.free(blob_dir);

    const kv = try kv_mod.KvStore.open(allocator, db_path);
    defer kv.close();
    var backend = try blob_mod.FilesystemBlobStore.open(allocator, blob_dir);
    defer backend.deinit();
    var store = try log_mod.LogStore.init(allocator, kv, backend.blobStore(), 1);
    defer store.deinit();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const id = try store.nextRequestId();
        try store.append(.{
            .request_id = id,
            .deployment_id = 1,
            .received_ns = 1_000_000_000 + @as(i64, @intCast(i)),
            .duration_ns = 1000,
            .method = try allocator.dupe(u8, "GET"),
            .path = try std.fmt.allocPrint(allocator, "/r{d}", .{i}),
            .host = try allocator.dupe(u8, "test.host"),
            .status = 200,
            .outcome = .ok,
            .console = try allocator.dupe(u8, ""),
            .exception = try allocator.dupe(u8, ""),
        });
    }

    // Drain + apply to persist the buffered records to SQLite.
    const batch = (try store.drainBatch(allocator)).?;
    defer allocator.free(batch);
    try store.applyBatch(batch);
}

test "listRecords returns records newest-first" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try seedLogStore(allocator, data_dir, "acme", 3);

    var result = try listRecords(allocator, data_dir, "acme", 10);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.records.len);
    // newest-first — request ids descend.
    try testing.expect(result.records[0].request_id > result.records[1].request_id);
    try testing.expect(result.records[1].request_id > result.records[2].request_id);
}

test "getRecord round-trips a known record" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try seedLogStore(allocator, data_dir, "acme", 2);

    // Find a valid id via list.
    var result = try listRecords(allocator, data_dir, "acme", 10);
    const target_id = result.records[0].request_id;
    result.deinit();

    var rec = (try getRecord(allocator, data_dir, "acme", target_id)).?;
    defer rec.deinit(allocator);
    try testing.expectEqual(target_id, rec.request_id);
    try testing.expectEqualStrings("GET", rec.method);
}

test "getRecord returns null for unknown id" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try seedLogStore(allocator, data_dir, "acme", 1);
    try testing.expectEqual(
        @as(?log_mod.LogRecord, null),
        try getRecord(allocator, data_dir, "acme", 0xdeadbeef_cafebabe),
    );
}

test "countRecords matches seeded count" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try seedLogStore(allocator, data_dir, "acme", 5);
    try testing.expectEqual(@as(usize, 5), try countRecords(allocator, data_dir, "acme"));
}

test "invalid instance id rejected" {
    const allocator = testing.allocator;
    try testing.expectError(
        Error.InvalidInstanceId,
        listRecords(allocator, "/tmp/rove-ls-inv", "", 10),
    );
    try testing.expectError(
        Error.InvalidInstanceId,
        listRecords(allocator, "/tmp/rove-ls-inv", "../evil", 10),
    );
}
