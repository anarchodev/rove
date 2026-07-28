//! Promotion-time LogRecord catch-up driver
//! (`docs/architecture/deployment-and-logs.md`).
//!
//! When a node wins leadership of a tenant's raft group, the previous
//! leader may have crashed between proposing a writeset and flushing the
//! LogRecords it buffered in RAM. Those records never reached S3, so the
//! requests vanished from the customer's logs — but the raft entries
//! survive on this (now-leader) node. This driver re-derives the missing
//! records from the live log on promotion.
//!
//! On each promotion edge it seeds a per-group cursor spanning
//! `[firstIndex .. lastIndex]` (the whole uncompacted log — the resume
//! point is derived from the group's live log, not a durable mark, since
//! a node-local mark can't say how far a *different* dead leader's
//! flusher got; correctness comes from the log indexer's idempotent
//! `(tenant_id, request_id)` INSERT OR IGNORE, which dedups any record
//! the dead leader had in fact already flushed). Each poll tick advances
//! the open cursors by up to `WALKER_BATCH_CAP` entries total —
//! `bridge.logEntry` is a pump control op, so the cap bounds the pump
//! contention a fresh promotion adds — decoding each entry's
//! `EntryFrame`, hydrating its LogRecords, and appending them to the
//! worker's `log.log_buffer` for the normal `flushLogs` → S3 path.

const std = @import("std");
const walker = @import("worker_upload_walker.zig");
const envelope = @import("bridge").envelope;

pub const WALKER_BATCH_CAP = walker.WALKER_BATCH_CAP;

/// Initial per-read buffer; grown on demand for an oversized entry (a
/// batched `multi` or an inline-body-carrying readset can exceed this).
const INITIAL_BUF_CAP: usize = 64 * 1024;
/// Ceiling for the grow-on-demand read buffer. An entry larger than this
/// is skipped + logged (its log line is lost, but the request's KV state
/// is safe — the write applied) rather than unbounded-allocating.
const MAX_BUF_CAP: usize = 8 * 1024 * 1024;

const Cursor = struct {
    gid: u64,
    /// Next raft index to read (inclusive).
    next: u64,
    /// Last raft index to read (inclusive); snapshotted at seed time.
    target: u64,
};

pub const LogWalker = struct {
    /// Open per-group catch-up cursors. Drained as each group finishes.
    cursors: std.ArrayListUnmanaged(Cursor) = .empty,
    /// Reusable read buffer for `bridge.logEntry`, grown on demand.
    buf: []u8 = &.{},

    pub fn deinit(self: *LogWalker, allocator: std.mem.Allocator) void {
        self.cursors.deinit(allocator);
        if (self.buf.len > 0) allocator.free(self.buf);
        self.* = undefined;
    }

    /// Seed (or refresh) the catch-up cursor for a freshly-promoted
    /// group. `bridge` must expose `firstIndex(gid)` / `lastIndex(gid)`.
    /// No-op when the group's live log is empty. An already-open cursor
    /// for the same gid has its target extended (a re-promotion before
    /// the prior catch-up drained).
    pub fn seed(self: *LogWalker, allocator: std.mem.Allocator, bridge: anytype, gid: u64) void {
        const first = bridge.firstIndex(gid);
        const last = bridge.lastIndex(gid);
        if (first == 0 or last < first) return;
        for (self.cursors.items) |*c| {
            if (c.gid == gid) {
                if (last > c.target) c.target = last;
                return;
            }
        }
        self.cursors.append(allocator, .{ .gid = gid, .next = first, .target = last }) catch |err| {
            std.log.warn("rove-js log-walker: seed gid={d} failed: {s}", .{ gid, @errorName(err) });
        };
    }

    /// Advance every open cursor, bounded to `WALKER_BATCH_CAP` entries
    /// total this tick. `worker` must expose `.allocator`, `.raft` (the
    /// bridge), and `.log.log_buffer`. Finished cursors are removed.
    pub fn drive(self: *LogWalker, worker: anytype) void {
        if (self.cursors.items.len == 0) return;

        var budget: u64 = WALKER_BATCH_CAP;
        var i: usize = 0;
        while (i < self.cursors.items.len and budget > 0) {
            const c = &self.cursors.items[i];
            while (c.next <= c.target and budget > 0) : (budget -= 1) {
                self.walkOne(worker, c.gid, c.next);
                c.next += 1;
            }
            if (c.next > c.target) {
                _ = self.cursors.swapRemove(i); // done — don't advance i (swapped-in entry now at i)
            } else {
                i += 1;
            }
        }
    }

    /// Read + hydrate + buffer the LogRecords for one raft entry.
    /// Best-effort: a missing/undecodable/oversized entry is skipped
    /// (logged for the oversized case) — idempotency + the surviving KV
    /// state keep this safe.
    fn walkOne(self: *LogWalker, worker: anytype, gid: u64, index: u64) void {
        const allocator = worker.allocator;
        const entry = self.readEntry(worker, gid, index) orelse return;

        const frame = envelope.decodeEntryFrame(entry) catch return;
        const records = walker.hydrateRecordsFromEnvelope(allocator, frame.env_bytes, frame.seq) catch |err| {
            std.log.warn("rove-js log-walker: hydrate gid={d} idx={d} failed: {s}", .{ gid, index, @errorName(err) });
            return;
        };
        defer allocator.free(records);
        for (records) |rec| {
            var r = rec;
            worker.log.log_buffer.append(r) catch |err| {
                // Buffer append failed (OOM) — free the record we can't
                // enqueue so we don't leak, and stop draining this entry.
                r.deinit(allocator);
                std.log.warn("rove-js log-walker: log_buffer append gid={d} idx={d}: {s}", .{ gid, index, @errorName(err) });
            };
        }
    }

    /// Read the entry at `index` into the reusable buffer, growing it
    /// (up to `MAX_BUF_CAP`) if the entry doesn't fit. Returns the entry
    /// bytes (aliasing `self.buf`) or null (compacted / beyond log /
    /// oversized). Disambiguates buf-too-small from a genuinely absent
    /// entry via `logTerm`, so a big entry is grown-into rather than
    /// silently dropped.
    fn readEntry(self: *LogWalker, worker: anytype, gid: u64, index: u64) ?[]const u8 {
        const allocator = worker.allocator;
        if (self.buf.len == 0) {
            self.buf = allocator.alloc(u8, INITIAL_BUF_CAP) catch return null;
        }
        while (true) {
            if (worker.raft.logEntry(gid, index, self.buf)) |e| return e.data;
            // Null: entry absent, or buf too small. If the term resolves
            // the entry exists → grow + retry; otherwise it's gone.
            if (worker.raft.logTerm(gid, index) == null) return null;
            if (self.buf.len >= MAX_BUF_CAP) {
                std.log.warn("rove-js log-walker: entry gid={d} idx={d} exceeds {d} bytes — skipped", .{ gid, index, MAX_BUF_CAP });
                return null;
            }
            const new_cap = @min(self.buf.len * 2, MAX_BUF_CAP);
            self.buf = allocator.realloc(self.buf, new_cap) catch return null;
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "seed: empty log (first==0) is a no-op; dedup extends target" {
    var w: LogWalker = .{};
    defer w.deinit(testing.allocator);

    const FakeBridge = struct {
        first: u64,
        last: u64,
        pub fn firstIndex(self: *@This(), gid: u64) u64 {
            _ = gid;
            return self.first;
        }
        pub fn lastIndex(self: *@This(), gid: u64) u64 {
            _ = gid;
            return self.last;
        }
    };

    var empty = FakeBridge{ .first = 0, .last = 0 };
    w.seed(testing.allocator, &empty, 7);
    try testing.expectEqual(@as(usize, 0), w.cursors.items.len);

    var live = FakeBridge{ .first = 3, .last = 10 };
    w.seed(testing.allocator, &live, 7);
    try testing.expectEqual(@as(usize, 1), w.cursors.items.len);
    try testing.expectEqual(@as(u64, 3), w.cursors.items[0].next);
    try testing.expectEqual(@as(u64, 10), w.cursors.items[0].target);

    // Re-seed same gid with a higher last → target extends, no new cursor.
    var grown = FakeBridge{ .first = 3, .last = 20 };
    w.seed(testing.allocator, &grown, 7);
    try testing.expectEqual(@as(usize, 1), w.cursors.items.len);
    try testing.expectEqual(@as(u64, 20), w.cursors.items[0].target);
}
