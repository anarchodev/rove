//! `subscription_sweep.zig` — leader-side boot subscription sweep.
//!
//! Extracted from `worker.zig`. `sweepBootSubscriptions` is the worker
//! poll-loop system that, on false→true leadership transition,
//! re-enqueues boot subscriptions whose marker is absent (cold-start
//! race where slots loaded before raft elected a leader).
//!
//! The cron half (`CronState` + `sweepCronSubscriptions`, the
//! non-durable in-memory interval clock behind manifest `kind=cron`
//! subscriptions) retired with durable-wake-plan P5(b): recurrence is
//! the `cron(spec, target)` verb (a self-re-arming durable wake via
//! `__system/cron_tick`) or a customer's own self-re-arming
//! `scheduler.after` — both survive leader change, which the
//! in-memory clock never did.
//!
//! Free function taking `worker: anytype`; `worker.zig` re-exports it.

const std = @import("std");
const deployment_cache = @import("deployment_cache.zig");

/// Gap 2.1 Phase D: on `false→true` leadership transition, walk
/// every loaded tenant slot and (re-)enqueue any boot
/// subscriptions whose marker is absent. Covers the cold-start
/// race where slots loaded BEFORE raft elected a leader, so
/// `reloadDeployment`'s leader-gated enqueue saw `isLeader() ==
/// false` and skipped. Gated to worker 0 to avoid duplicate
/// enqueues across the leader's local workers.
pub fn sweepBootSubscriptions(worker: anytype) void {
    var it = worker.node.deploy.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const snap = slot.pinCurrent() orelse continue;
        defer snap.release();
        deployment_cache.enqueueBootSubscriptions(slot, snap) catch |err| std.log.warn(
            "rove-js boot sweep ({s}): {s}",
            .{ slot.instance_id, @errorName(err) },
        );
    }
}

