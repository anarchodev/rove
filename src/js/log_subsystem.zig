// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `LogSubsystem` — the per-request log buffer + S3-batch flusher + log-server
//! push machinery grouped out of the `Worker` god-struct. Its behavior lives
//! in `worker_log.zig`; grouping the state makes the shutdown teardown
//! ordering local + auditable (see `deinit`).
//!
//! The flusher thread drains `log_buffer` into S3 batches and enqueues the
//! batch keys onto `push_queue`; the push thread notifies the log-server of
//! those keys (bypassing its eventual-consistent LIST). Both are lazily
//! spawned by `worker_log`; their handles + stop flags + wakes live here.

const std = @import("std");
const log_mod = @import("rove-log");
const log_server_mod = @import("rove-log-server");
const blob_mod = @import("rove-blob");

pub const LogSubsystem = struct {
    /// Per-request log record buffer; the flusher drains it into S3 batches.
    log_buffer: log_mod.NodeLogBuffer,
    /// This worker's request-id minter identity (`log_mod.MinterId`).
    minter_id: log_mod.MinterId,
    /// S3-backed batch store the flusher writes log batches to.
    log_batch_store: log_server_mod.batch_store.BatchStore,
    /// Public base URL of the log-server (for the push notification), if any.
    log_public_base: ?[]const u8,
    /// Log-server base URLs the push thread notifies of new batch keys.
    log_push_bases: []const []const u8,
    /// libcurl handle owned by the push thread (null when push is disabled).
    log_push_curl: ?*blob_mod.curl.Easy,
    /// Count of per-request log records permanently dropped by `flushLogs`
    /// (batch drained before the S3 PUT failed / leadership lost). Lossy by
    /// design; counted so the data-loss volume is visible. Never reset.
    log_records_dropped_total: u64 = 0,

    /// The S3-batch flusher: drains `log_buffer`, PUTs batches, enqueues keys.
    flusher_thread: ?std.Thread = null,
    flusher_should_stop: std.atomic.Value(bool) = .init(false),
    flusher_wake: std.Thread.ResetEvent = .{},

    /// The log-server push thread + its FIFO of owned batch keys to notify.
    push_queue: std.ArrayList([]u8) = .empty,
    push_queue_mutex: std.Thread.Mutex = .{},
    push_wake: std.Thread.ResetEvent = .{},
    push_should_stop: std.atomic.Value(bool) = .init(false),
    push_thread: ?std.Thread = null,

    /// Stop + join both threads IN ORDER, then free the push queue. The order
    /// is load-bearing: join the flusher FIRST (its only blocking call is a
    /// libcurl PUT bounded by the Easy 15 s timeout, so join can't hang), then
    /// the push thread — the flusher enqueues to `push_queue` on its final
    /// tick, so stopping push first would leak whatever it emitted. Only once
    /// BOTH threads are joined (no more producers/consumers) is it safe to free
    /// the still-queued keys. Best-effort on shutdown: the log-server picks up
    /// any unpushed batches on its LIST poll.
    pub fn deinit(self: *LogSubsystem, allocator: std.mem.Allocator) void {
        if (self.flusher_thread) |t| {
            self.flusher_should_stop.store(true, .release);
            self.flusher_wake.set();
            t.join();
            self.flusher_thread = null;
        }
        if (self.push_thread) |t| {
            self.push_should_stop.store(true, .release);
            self.push_wake.set();
            t.join();
            self.push_thread = null;
        }
        self.push_queue_mutex.lock();
        for (self.push_queue.items) |k| allocator.free(k);
        self.push_queue.deinit(allocator);
        self.push_queue_mutex.unlock();
    }
};
