// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The WAL's dedicated fsync thread — what keeps a slow fsync out of the
//! pump cycle. The pump appends with direct writes (no userspace buffer),
//! hands this thread a dup of the active segment's fd, and keeps cycling:
//! ticks fire, inbound messages step, and heartbeats leave every cycle,
//! so a leader mid-fsync is no longer heartbeat-silent for the stall's
//! duration (filesystem commit tails reach 100-250ms — an order of
//! magnitude over a millisecond-tick election budget; see
//! docs/architecture/raft-best-practices.md "how to size ...").
//!
//! The durability handshake is unchanged in meaning, only deferred: raft's
//! persist watermark (`mgr.onPersist`) — the point this node's entries
//! count toward the commit quorum and the stashed persistence-asserting
//! messages (append acks, vote responses) go out — advances only once a
//! completed fsync covers the group's latest append. Never durability
//! claimed for volatile bytes.
//!
//! Coalescing is correct by a segment invariant: `roll()` fsyncs a segment
//! before sealing it, so the only non-durable WAL bytes ever live in the
//! ACTIVE segment — fsyncing the newest requested fd therefore covers
//! every earlier request too, and completion publishes the newest seq.
//! The dup'd fd keeps a roll's `close` from invalidating an in-flight
//! sync (the file description outlives the original fd).

const std = @import("std");

pub const WalFlusher = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    stopping: bool = false,
    /// Latest request: seq + a dup'd fd this thread takes ownership of.
    /// A newer request replaces an un-taken older one (coalescing — see
    /// the header invariant). Mutex-guarded; `req_seq` is additionally
    /// readable lock-free from the pump thread (its only writer).
    req_seq: u64 = 0,
    req_fd: std.posix.fd_t = -1,
    /// Highest seq whose fsync has completed. Pump-thread readers use
    /// `.acquire` so the completed bytes happen-before the ack.
    completed: std.atomic.Value(u64) = .init(0),
    /// A failed fsync is a durability loss: no completion is published,
    /// the thread exits, and the pump dies loudly on observing this —
    /// a restart replays the WAL from the last checkpoint.
    failed: std.atomic.Value(bool) = .init(false),

    pub fn started(self: *const WalFlusher) bool {
        return self.thread != null;
    }

    pub fn start(self: *WalFlusher) !void {
        if (self.thread != null) return;
        self.stopping = false;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop + join. Any queued-but-never-synced fd is closed WITHOUT a
    /// completion — the caller does its own tail flush after the pump
    /// stops appending (see `Bridge.stopPump`).
    pub fn stop(self: *WalFlusher) void {
        if (self.thread) |t| {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.stopping = true;
                self.cond.signal();
            }
            t.join();
            self.thread = null;
        }
        // Queued-but-never-synced fd (also reachable with no thread — a
        // request against a never-started flusher): close, no completion.
        if (self.req_fd >= 0) {
            std.posix.close(self.req_fd);
            self.req_fd = -1;
        }
    }

    /// Pump thread: request an fsync covering everything appended so far.
    /// `fd` is a dup of the active segment's fd; ownership transfers here.
    /// Returns the request's seq — the pump stamps awaiting groups with it
    /// and acks them once `completed` reaches it.
    pub fn request(self: *WalFlusher, fd: std.posix.fd_t) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.req_fd >= 0) std.posix.close(self.req_fd);
        self.req_fd = fd;
        self.req_seq += 1;
        self.cond.signal();
        return self.req_seq;
    }

    /// The last requested seq. Pump-thread only (it is the only writer),
    /// so no lock: used to stamp a group that entered the awaiting list
    /// without a new append — any already-covered seq is correct for it.
    pub fn lastRequested(self: *const WalFlusher) u64 {
        return self.req_seq;
    }

    fn run(self: *WalFlusher) void {
        while (true) {
            var fd: std.posix.fd_t = -1;
            var seq: u64 = 0;
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.req_fd < 0 and !self.stopping) self.cond.wait(&self.mutex);
                if (self.req_fd < 0) return; // stopping, nothing queued
                fd = self.req_fd;
                seq = self.req_seq;
                self.req_fd = -1;
            }
            const t0 = std.time.nanoTimestamp();
            std.posix.fsync(fd) catch |e| {
                std.log.err("wal flusher: fsync failed ({s}) — no completion published", .{@errorName(e)});
                std.posix.close(fd);
                self.failed.store(true, .release);
                return;
            };
            std.posix.close(fd);
            // The stall probe rides here now (it measured the pump before
            // the fsync moved off-thread): a slow flush is still worth a
            // stamped warn — it delays commit acks, just no longer
            // heartbeats/ticks.
            const took_us = @divTrunc(std.time.nanoTimestamp() - t0, std.time.ns_per_us);
            if (took_us > 5000)
                std.log.warn("wal fsync took {d}us at={d}", .{ took_us, std.time.milliTimestamp() });
            self.completed.store(seq, .release);
        }
    }
};

const testing = std.testing;

test "WalFlusher: request → completion covers the seq; coalesced requests complete at the newest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("wal", .{});
    defer f.close();

    var fl: WalFlusher = .{};
    try fl.start();
    defer fl.stop();

    const s1 = fl.request(try std.posix.dup(f.handle));
    const s2 = fl.request(try std.posix.dup(f.handle));
    try testing.expect(s2 > s1);
    var spins: usize = 0;
    while (fl.completed.load(.acquire) < s2) : (spins += 1) {
        if (spins > 10_000) return error.TestTimeout;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(!fl.failed.load(.acquire));
}

test "WalFlusher: stop with a queued request closes the fd and publishes no completion" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("wal", .{});
    defer f.close();

    var fl: WalFlusher = .{};
    // Never started: request() queues; stop() must close the un-taken fd
    // without claiming durability for it.
    const s = fl.request(try std.posix.dup(f.handle));
    fl.stop();
    try testing.expect(fl.completed.load(.acquire) < s);
    try testing.expectEqual(@as(std.posix.fd_t, -1), fl.req_fd);
}
