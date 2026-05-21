//! Histograms for the dispatch / raft-propose hot path.
//!
//! Three observation points answer "how big are our raft batches?":
//!
//!   - `dispatch_writeset_size_requests` — handler-bound requests per
//!     writeset envelope (observed at `finalizeBatch` exit).
//!   - `raft_proposal_batch_size_writesets` — writesets packed into
//!     one `raft_recv_entry` call (observed at `packBatch` exit).
//!   - `raft_proposal_linger_wait_us` — time the leader spent in the
//!     linger window before each pack (observed at pack time).
//!
//! Surfaced via `/_system/metrics` so an operator can tell whether
//! the leader's propose pipeline is time-capped (raise
//! `--propose-linger-us`) or size-capped (raise
//! `--propose-linger-max-batch`), and whether per-writeset batch
//! growth would compound that.

const std = @import("std");

/// Histogram for unitless counts (writeset size, batch size).
/// Power-of-2 boundaries up to 1024.
pub const CountHistogram = struct {
    pub const bucket_bounds = [_]u64{
        1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024,
    };
    /// One extra bucket for `+Inf` — observations > 1024 land here.
    pub const bucket_count = bucket_bounds.len + 1;

    buckets: [bucket_count]std.atomic.Value(u64) =
        @splat(std.atomic.Value(u64).init(0)),
    sum: std.atomic.Value(u64) = .init(0),

    pub fn observe(self: *CountHistogram, v: u64) void {
        var idx: usize = bucket_bounds.len; // +Inf default
        var i: usize = 0;
        while (i < bucket_bounds.len) : (i += 1) {
            if (v <= bucket_bounds[i]) {
                idx = i;
                break;
            }
        }
        _ = self.buckets[idx].fetchAdd(1, .monotonic);
        _ = self.sum.fetchAdd(v, .monotonic);
    }

    pub fn snapshot(self: *const CountHistogram) Snapshot {
        var snap: Snapshot = .{
            .buckets = undefined,
            .sum = self.sum.load(.acquire),
            .count = 0,
        };
        var cum: u64 = 0;
        var i: usize = 0;
        while (i < bucket_count) : (i += 1) {
            cum += self.buckets[i].load(.acquire);
            snap.buckets[i] = cum;
        }
        snap.count = cum;
        return snap;
    }

    pub const Snapshot = struct {
        /// Cumulative — `buckets[i]` is the count of observations
        /// whose value was ≤ `bucket_bounds[i]`. `buckets[bucket_count - 1]`
        /// is the +Inf bucket and equals the total `count`.
        buckets: [bucket_count]u64,
        sum: u64,
        count: u64,
    };
};

/// Histogram for microsecond latencies (linger wait time).
pub const MicrosHistogram = struct {
    pub const bucket_bounds_us = [_]u64{
        100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000,
    };
    pub const bucket_count = bucket_bounds_us.len + 1;

    buckets: [bucket_count]std.atomic.Value(u64) =
        @splat(std.atomic.Value(u64).init(0)),
    sum_us: std.atomic.Value(u64) = .init(0),

    pub fn observe(self: *MicrosHistogram, micros: u64) void {
        var idx: usize = bucket_bounds_us.len; // +Inf default
        var i: usize = 0;
        while (i < bucket_bounds_us.len) : (i += 1) {
            if (micros <= bucket_bounds_us[i]) {
                idx = i;
                break;
            }
        }
        _ = self.buckets[idx].fetchAdd(1, .monotonic);
        _ = self.sum_us.fetchAdd(micros, .monotonic);
    }

    pub fn snapshot(self: *const MicrosHistogram) Snapshot {
        var snap: Snapshot = .{
            .buckets = undefined,
            .sum_us = self.sum_us.load(.acquire),
            .count = 0,
        };
        var cum: u64 = 0;
        var i: usize = 0;
        while (i < bucket_count) : (i += 1) {
            cum += self.buckets[i].load(.acquire);
            snap.buckets[i] = cum;
        }
        snap.count = cum;
        return snap;
    }

    pub const Snapshot = struct {
        buckets: [bucket_count]u64,
        sum_us: u64,
        count: u64,
    };
};

test "CountHistogram: buckets are cumulative + +Inf catches overflow" {
    var h: CountHistogram = .{};
    h.observe(1);
    h.observe(5);
    h.observe(100);
    h.observe(2000); // exceeds 1024 → +Inf
    const snap = h.snapshot();
    try std.testing.expectEqual(@as(u64, 4), snap.count);
    try std.testing.expectEqual(@as(u64, 2106), snap.sum);
    // `1` lands in bucket[0] (le=1); `5` in bucket[3] (le=8);
    // `100` in bucket[6] (le=64? no — 100 > 64, so bucket[7] le=128);
    // `2000` in bucket[11] = +Inf.
    try std.testing.expectEqual(@as(u64, 1), snap.buckets[0]); // ≤ 1
    try std.testing.expectEqual(@as(u64, 2), snap.buckets[3]); // ≤ 8
    try std.testing.expectEqual(@as(u64, 3), snap.buckets[7]); // ≤ 128
    try std.testing.expectEqual(@as(u64, 4), snap.buckets[CountHistogram.bucket_count - 1]); // +Inf
}

test "MicrosHistogram: zero-us observation lands in lowest bucket" {
    var h: MicrosHistogram = .{};
    h.observe(0);
    h.observe(50);
    h.observe(200_000); // overflow → +Inf
    const snap = h.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snap.count);
    try std.testing.expectEqual(@as(u64, 2), snap.buckets[0]); // ≤ 100
    try std.testing.expectEqual(@as(u64, 3), snap.buckets[MicrosHistogram.bucket_count - 1]);
}
