//! Penalty box / circuit breaker for noisy-neighbor handlers.
//!
//! When a handler exceeds its CPU budget (`DispatchError.Interrupted`),
//! the worker calls `recordKill`. After `kill_threshold` kills within
//! `window_ns`, the tenant+deployment is marked "open" for
//! `open_duration_ns`. While open, `isBoxed` returns true and the
//! worker responds 503 immediately without invoking qjs — protecting
//! other tenants from a runaway handler burning the event loop.
//!
//! **Auto-release on redeploy.** A key is `(instance_id, deployment_id)`
//! from the caller's perspective, but storage is keyed by `instance_id`
//! alone with the deployment id stamped into the entry. When a new
//! deployment rolls out and the worker's `current_deployment_id`
//! advances, the next `isBoxed` call observes the mismatch and resets
//! the entry to closed. That's the escape hatch: a customer who ships
//! a fix gets their traffic back without operator intervention.
//!
//! **Thread safety.** Not internally synchronized. The rove-js worker
//! is single-threaded (h2 thread does all dispatch), so the PenaltyBox
//! lives on that thread only. Migrating to shift-js's per-worker model
//! later will want one PenaltyBox per worker thread, not a shared one —
//! sharing would reintroduce the contention we're trying to avoid.

const std = @import("std");

pub const State = enum(u8) { closed, open };

pub const Entry = struct {
    deployment_id: u64,
    /// Kills observed in the current window. Reset when the window
    /// rolls over or the deployment changes.
    kill_count: u32,
    window_start_ns: i64,
    state: State,
    /// Only meaningful when `state == .open`.
    opened_at_ns: i64,
};

pub const Config = struct {
    kill_threshold: u32 = 3,
    window_ns: i64 = 10 * std.time.ns_per_s,
    open_duration_ns: i64 = 30 * std.time.ns_per_s,
};

pub const PenaltyBox = struct {
    allocator: std.mem.Allocator,
    config: Config,
    entries: std.StringHashMapUnmanaged(Entry),

    pub fn init(allocator: std.mem.Allocator, config: Config) PenaltyBox {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *PenaltyBox) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.entries.deinit(self.allocator);
    }

    /// Is this tenant currently in penalty?
    ///
    /// Side effects: if a `.open` entry's duration has elapsed, or the
    /// deployment id has advanced, the entry flips back to `.closed`
    /// here so subsequent calls see a fresh state.
    pub fn isBoxed(
        self: *PenaltyBox,
        instance_id: []const u8,
        deployment_id: u64,
        now_ns: i64,
    ) bool {
        const entry = self.entries.getPtr(instance_id) orelse return false;

        // Redeploy releases the box unconditionally.
        if (entry.deployment_id != deployment_id) {
            entry.* = .{
                .deployment_id = deployment_id,
                .kill_count = 0,
                .window_start_ns = now_ns,
                .state = .closed,
                .opened_at_ns = 0,
            };
            return false;
        }

        if (entry.state == .open) {
            if (now_ns - entry.opened_at_ns >= self.config.open_duration_ns) {
                // Duration elapsed — close and reset the kill window.
                // Next kill starts fresh accounting; if the handler is
                // still broken we re-open on the next threshold breach.
                entry.state = .closed;
                entry.kill_count = 0;
                entry.window_start_ns = now_ns;
                return false;
            }
            return true;
        }
        return false;
    }

    /// Record a budget-exceeded kill. May flip the entry from
    /// `.closed` to `.open` if the threshold is met.
    pub fn recordKill(
        self: *PenaltyBox,
        instance_id: []const u8,
        deployment_id: u64,
        now_ns: i64,
    ) !void {
        const gop = try self.entries.getOrPut(self.allocator, instance_id);
        if (!gop.found_existing) {
            const owned = try self.allocator.dupe(u8, instance_id);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{
                .deployment_id = deployment_id,
                .kill_count = 0,
                .window_start_ns = now_ns,
                .state = .closed,
                .opened_at_ns = 0,
            };
        }
        const entry = gop.value_ptr;

        if (entry.deployment_id != deployment_id) {
            entry.deployment_id = deployment_id;
            entry.kill_count = 0;
            entry.window_start_ns = now_ns;
            entry.state = .closed;
            entry.opened_at_ns = 0;
        }

        if (now_ns - entry.window_start_ns >= self.config.window_ns) {
            entry.kill_count = 0;
            entry.window_start_ns = now_ns;
        }

        entry.kill_count += 1;
        if (entry.state == .closed and entry.kill_count >= self.config.kill_threshold) {
            entry.state = .open;
            entry.opened_at_ns = now_ns;
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "penalty: closed by default" {
    var pb = PenaltyBox.init(testing.allocator, .{});
    defer pb.deinit();
    try testing.expect(!pb.isBoxed("acme", 1, 0));
}

test "penalty: opens after threshold kills within window" {
    var pb = PenaltyBox.init(testing.allocator, .{
        .kill_threshold = 3,
        .window_ns = 10 * std.time.ns_per_s,
        .open_duration_ns = 30 * std.time.ns_per_s,
    });
    defer pb.deinit();

    try pb.recordKill("acme", 1, 0);
    try testing.expect(!pb.isBoxed("acme", 1, 1));
    try pb.recordKill("acme", 1, 2);
    try testing.expect(!pb.isBoxed("acme", 1, 3));
    try pb.recordKill("acme", 1, 4);
    try testing.expect(pb.isBoxed("acme", 1, 5));
}

test "penalty: closes after open duration elapses" {
    var pb = PenaltyBox.init(testing.allocator, .{
        .kill_threshold = 1,
        .window_ns = 10 * std.time.ns_per_s,
        .open_duration_ns = 100,
    });
    defer pb.deinit();

    try pb.recordKill("acme", 1, 0);
    try testing.expect(pb.isBoxed("acme", 1, 50));
    try testing.expect(!pb.isBoxed("acme", 1, 200));
}

test "penalty: kills outside window reset counter" {
    var pb = PenaltyBox.init(testing.allocator, .{
        .kill_threshold = 3,
        .window_ns = 100,
        .open_duration_ns = 1000,
    });
    defer pb.deinit();

    try pb.recordKill("acme", 1, 0);
    try pb.recordKill("acme", 1, 50);
    // Third kill lands AFTER the window — counter resets, threshold
    // not met, box stays closed.
    try pb.recordKill("acme", 1, 200);
    try testing.expect(!pb.isBoxed("acme", 1, 201));
}

test "penalty: new deployment auto-releases" {
    var pb = PenaltyBox.init(testing.allocator, .{
        .kill_threshold = 2,
        .window_ns = 10 * std.time.ns_per_s,
        .open_duration_ns = 10 * std.time.ns_per_s,
    });
    defer pb.deinit();

    try pb.recordKill("acme", 1, 0);
    try pb.recordKill("acme", 1, 1);
    try testing.expect(pb.isBoxed("acme", 1, 2));
    // New deployment id — box auto-releases; the kill counter resets
    // so a single fresh kill against v2 does NOT reopen.
    try testing.expect(!pb.isBoxed("acme", 2, 3));
    try pb.recordKill("acme", 2, 4);
    try testing.expect(!pb.isBoxed("acme", 2, 5));
}

test "penalty: tenants are independent" {
    var pb = PenaltyBox.init(testing.allocator, .{ .kill_threshold = 1 });
    defer pb.deinit();
    try pb.recordKill("acme", 1, 0);
    try testing.expect(pb.isBoxed("acme", 1, 1));
    try testing.expect(!pb.isBoxed("beta", 1, 1));
}
