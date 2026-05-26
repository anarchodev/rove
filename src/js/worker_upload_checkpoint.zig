//! Per-worker durable "last raft seq I've uploaded a log batch for"
//! checkpoint (`docs/readset-replication-plan.md` Phase 5b).
//!
//! The leader's existing `flushLogs` pipeline is "best effort early
//! visibility": it drains the in-memory `log_buffer` into one
//! ndjson batch and PUTs to S3 before raft has committed the
//! underlying entries. If the leader crashes between propose and
//! flush, the buffered records die in RAM — followers see the
//! entries replicated but have no LogRecord to surface to the
//! customer.
//!
//! Phase 5c will close that gap by walking raft entries on
//! promotion and re-deriving LogRecords from each readset's
//! `LogHeader`. To know WHERE to resume, the walker needs a
//! durable "the last seq the dead leader covered" mark.
//!
//! This module provides that mark. One small file per worker at
//! `{data_dir}/_meta/last_uploaded_seq_w{log_worker_id:0>4}.txt`
//! holding the u64 raft seq as decimal ASCII + trailing newline.
//! Atomic write via write-to-`.tmp` + `rename`.
//!
//! Concurrency: each worker writes its OWN file (different
//! `log_worker_id`) so no inter-worker contention on the path.
//! Each worker's writer is the per-tick flusher, single-threaded
//! against that worker's file.
//!
//! On promotion (Phase 5c), the walker reads every per-worker
//! checkpoint in `_meta/` and starts from the MINIMUM across them
//! — that's the safe high-water mark covering all workers'
//! workloads.

const std = @import("std");

/// Directory under `data_dir` where per-worker checkpoints live.
pub const META_SUBDIR = "_meta";

/// Compose the absolute checkpoint path for a worker. Caller owns
/// the returned slice.
pub fn checkpointPath(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    log_worker_id: u16,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}/last_uploaded_seq_w{x:0>4}.txt",
        .{ data_dir, META_SUBDIR, log_worker_id },
    );
}

/// Compose the per-worker `.tmp` path used for atomic write
/// staging.
pub fn checkpointTmpPath(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    log_worker_id: u16,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}/last_uploaded_seq_w{x:0>4}.tmp",
        .{ data_dir, META_SUBDIR, log_worker_id },
    );
}

/// Read the per-worker checkpoint. Returns 0 if the file is
/// missing OR malformed (the safe boot default — Phase 5c will
/// just re-upload more entries, which idempotency at the indexer
/// absorbs).
///
/// Caller-supplied `data_dir` is the loop46 instance's
/// `--data-dir`. The `_meta` subdir is created lazily on the
/// first `writeCheckpoint` call.
pub fn readCheckpoint(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    log_worker_id: u16,
) u64 {
    const path = checkpointPath(allocator, data_dir, log_worker_id) catch return 0;
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64) catch return 0;
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

/// Persist the worker's checkpoint. Atomic: write to `.tmp`,
/// fsync, rename over the final path. Caller is expected to gate
/// on `new_seq > current_seq` so we don't churn the disk for
/// no-op updates.
///
/// Caller-supplied `data_dir` must be writable. The `_meta`
/// subdir is created if missing.
pub fn writeCheckpoint(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    log_worker_id: u16,
    new_seq: u64,
) !void {
    const meta_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, META_SUBDIR });
    defer allocator.free(meta_dir);
    std.fs.cwd().makePath(meta_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const tmp_path = try checkpointTmpPath(allocator, data_dir, log_worker_id);
    defer allocator.free(tmp_path);
    const final_path = try checkpointPath(allocator, data_dir, log_worker_id);
    defer allocator.free(final_path);

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o600 });
        defer f.close();
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d}\n", .{new_seq});
        try f.writeAll(line);
        try f.sync();
    }
    try std.fs.cwd().rename(tmp_path, final_path);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "checkpoint roundtrip: missing → 0 → write → read" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(testing.allocator, "/tmp/rove-js-uploadchk-{x}", .{seed});
    defer testing.allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Missing file → 0.
    try testing.expectEqual(@as(u64, 0), readCheckpoint(testing.allocator, tmp_dir, 7));

    // Write + roundtrip.
    try writeCheckpoint(testing.allocator, tmp_dir, 7, 12_345);
    try testing.expectEqual(@as(u64, 12_345), readCheckpoint(testing.allocator, tmp_dir, 7));

    // Overwrite — last write wins, atomic.
    try writeCheckpoint(testing.allocator, tmp_dir, 7, 999_999_999_999);
    try testing.expectEqual(@as(u64, 999_999_999_999), readCheckpoint(testing.allocator, tmp_dir, 7));

    // Different worker_id → independent value.
    try writeCheckpoint(testing.allocator, tmp_dir, 8, 42);
    try testing.expectEqual(@as(u64, 42), readCheckpoint(testing.allocator, tmp_dir, 8));
    // Worker 7 untouched by the worker-8 write.
    try testing.expectEqual(@as(u64, 999_999_999_999), readCheckpoint(testing.allocator, tmp_dir, 7));
}

test "checkpoint: malformed content reads as 0" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(testing.allocator, "/tmp/rove-js-uploadchk-bad-{x}", .{seed});
    defer testing.allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const meta_dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ tmp_dir, META_SUBDIR });
    defer testing.allocator.free(meta_dir);
    try std.fs.cwd().makePath(meta_dir);

    const path = try checkpointPath(testing.allocator, tmp_dir, 3);
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "garbage not a number\n" });

    try testing.expectEqual(@as(u64, 0), readCheckpoint(testing.allocator, tmp_dir, 3));
}

test "checkpoint: empty file reads as 0" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(testing.allocator, "/tmp/rove-js-uploadchk-empty-{x}", .{seed});
    defer testing.allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const meta_dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ tmp_dir, META_SUBDIR });
    defer testing.allocator.free(meta_dir);
    try std.fs.cwd().makePath(meta_dir);

    const path = try checkpointPath(testing.allocator, tmp_dir, 0);
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "" });

    try testing.expectEqual(@as(u64, 0), readCheckpoint(testing.allocator, tmp_dir, 0));
}
