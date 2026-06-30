//! Process-global operator metrics for the standalone log-server.
//!
//! Atomic counters bumped from the indexer poll loop (`indexer.runLoop`) and
//! the request handlers (`standalone.zig`), rendered as Prometheus text and
//! served on a dedicated loopback HTTP/1.1 port (`main.zig` → the shared
//! `metrics-server` module). The query port is h2c-only, which stock
//! Prometheus/Alloy can't scrape — same reason the worker runs a separate h1
//! metrics listener.
//!
//! The poll-path and push-path index counters are deliberately SEPARATE
//! (`batches_indexed` vs `push_indexed`): a non-zero `push_*` set is the
//! positive signal that the worker→log-server batch-push fast-path is live,
//! distinct from the S3 LIST poll doing the work.

const std = @import("std");

const Counter = std.atomic.Value(u64);

pub const Metrics = struct {
    // ── indexer (S3 LIST poll path) ──
    /// Poll passes completed.
    poll_cycles: Counter = .init(0),
    /// Poll passes that returned an error.
    poll_errors: Counter = .init(0),
    /// Batches indexed by the poll path.
    batches_indexed: Counter = .init(0),
    /// Records indexed by the poll path.
    records_indexed: Counter = .init(0),
    /// Batches re-LISTed inside the clock-skew buffer that were already
    /// indexed (skipped via the `batches` PK, no object GET).
    skipped_already: Counter = .init(0),
    /// Batch objects that failed to read/parse (logged + skipped).
    skipped_invalid: Counter = .init(0),

    // ── push path (worker → POST /v1/_internal/batch-pushed) ──
    /// Push requests received.
    push_received: Counter = .init(0),
    /// Batches indexed by the push path (by-key GET, bypassing the poll).
    push_indexed: Counter = .init(0),
    /// Push requests whose index attempt errored.
    push_errors: Counter = .init(0),

    // ── query surface ──
    query_list: Counter = .init(0),
    query_show: Counter = .init(0),
    query_count: Counter = .init(0),

    pub inline fn inc(c: *Counter) void {
        _ = c.fetchAdd(1, .monotonic);
    }
    pub inline fn add(c: *Counter, n: u64) void {
        if (n != 0) _ = c.fetchAdd(n, .monotonic);
    }
};

/// The one process-wide instance.
pub var global: Metrics = .{};

/// Render the current counters as Prometheus text. Caller owns the slice.
pub fn render(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;
    const m = &global;
    try counter(w, "log_indexer_poll_cycles_total", "Indexer poll passes completed.", m.poll_cycles.load(.monotonic));
    try counter(w, "log_indexer_poll_errors_total", "Indexer poll passes that errored.", m.poll_errors.load(.monotonic));
    try counter(w, "log_indexer_batches_indexed_total", "Batches indexed by the S3 LIST poll path.", m.batches_indexed.load(.monotonic));
    try counter(w, "log_indexer_records_indexed_total", "Records indexed by the poll path.", m.records_indexed.load(.monotonic));
    try counter(w, "log_indexer_skipped_already_total", "Batches re-listed in the clock-skew buffer but already indexed (no GET).", m.skipped_already.load(.monotonic));
    try counter(w, "log_indexer_skipped_invalid_total", "Batch objects that failed to read/parse.", m.skipped_invalid.load(.monotonic));
    try counter(w, "log_push_received_total", "Batch-push requests received.", m.push_received.load(.monotonic));
    try counter(w, "log_push_indexed_total", "Batches indexed by the push fast-path (bypassing the poll).", m.push_indexed.load(.monotonic));
    try counter(w, "log_push_errors_total", "Batch-push requests whose index attempt errored.", m.push_errors.load(.monotonic));
    try counter(w, "log_query_list_total", "list queries served.", m.query_list.load(.monotonic));
    try counter(w, "log_query_show_total", "show queries served.", m.query_show.load(.monotonic));
    try counter(w, "log_query_count_total", "count queries served.", m.query_count.load(.monotonic));
    buf = aw.toArrayList();
    return buf.toOwnedSlice(allocator);
}

fn counter(w: *std.Io.Writer, name: []const u8, help: []const u8, val: u64) !void {
    try w.print("# HELP {s} {s}\n# TYPE {s} counter\n{s} {d}\n", .{ name, help, name, name, val });
}

test "render emits Prometheus counter lines" {
    // Isolate from other tests' increments by snapshotting deltas via substrings.
    global.push_received.store(7, .monotonic);
    const txt = try render(std.testing.allocator);
    defer std.testing.allocator.free(txt);
    try std.testing.expect(std.mem.indexOf(u8, txt, "# TYPE log_push_received_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "log_push_received_total 7") != null);
    global.push_received.store(0, .monotonic);
}
