//! `durable_wake.zig` — §2.6 leader-side durable-scheduled-wake sweep
//! (`docs/durable-wake-plan.md` P0). The engine half of the durable
//! scheduler: it owns ONE next-fire watermark per tenant
//! (`TenantSlot.next_wake_ns`, set by the baked
//! `__system/scheduler_tick` via `__rove_set_wake`) and, once per
//! `WAKE_SWEEP_INTERVAL_NS`, fires `scheduler_tick` for every tenant in
//! THIS worker's partition whose watermark has fallen due. The queue,
//! ordering, and fan-out all live in the `scheduler` JS lib's `_sched/`
//! kv — this file never parses a `_sched/` entry.
//!
//! Generalizes the webhook owed sweep (`owed_retry.zig`): same
//! per-worker `hash(tenant_id) % N_msg_inboxes` partitioning, same 1 Hz
//! throttle, same false→true-promotion reconstruction pass. The
//! difference is the steady-state path is O(tenants-with-a-due-wake)
//! — gated on the cheap atomic `next_wake_ns` load — rather than a kv
//! prefix scan per tenant per tick. The expensive scan happens only
//! inside `scheduler_tick`, and only when a tenant is actually due.
//!
//! Free functions taking `worker: anytype` (the established
//! worker-system pattern); `worker.zig` re-exports the public entry
//! points (`sweepDurableWakes*`).

const std = @import("std");
const worker_streaming = @import("worker_streaming.zig");
const deployment_cache = @import("deployment_cache.zig");

/// `_sched/by_time/` kv prefix — the `scheduler` lib's time-ordered
/// index. Used only by the promotion pass to probe "does this tenant
/// have any scheduled wakes?" before firing a reconstruction tick;
/// the steady sweep gates on the in-memory watermark instead.
pub const SCHED_BY_TIME_PREFIX: []const u8 = "_sched/by_time/";

/// Per-worker durable-wake sweep cadence. Matches `CRON_SWEEP_INTERVAL_NS`
/// + `SEND_SWEEP_INTERVAL_NS` (1 Hz) and `SCHED_TICK_RESOLUTION` — the
/// `scheduler` lib rounds `whenNs` up to the next tick, so a 1 Hz sweep
/// fires every due wake within one resolution window of its target.
pub const WAKE_SWEEP_INTERVAL_NS: i64 = 1 * std.time.ns_per_s;

/// Throttled steady-state sweep. Each leader-side worker, at most once
/// per `WAKE_SWEEP_INTERVAL_NS`, fires `scheduler_tick` for every
/// tenant in its partition whose `next_wake_ns` watermark is due.
///
/// Inert until a `scheduler.at()` (P3) commits the first `_sched/`
/// entry: with no writers, every tenant's `next_wake_ns` is 0 (the
/// "no wake" sentinel) so the gate skips every slot and the sweep is a
/// cheap partition walk doing nothing.
pub fn sweepDurableWakes(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - worker.last_wake_sweep_ns < WAKE_SWEEP_INTERVAL_NS) return;
    worker.last_wake_sweep_ns = now_ns;

    const n_inboxes = blk: {
        worker.node.router.msg_inboxes_mutex.lock();
        defer worker.node.router.msg_inboxes_mutex.unlock();
        break :blk worker.node.router.msg_inboxes.items.len;
    };
    if (n_inboxes == 0) return; // pre-registration cold start

    var it = worker.node.deploy.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const inbox_idx = std.hash.Wyhash.hash(0, slot.instance_id) % n_inboxes;
        if (inbox_idx != worker.msg_inbox_idx) continue;

        const w = slot.next_wake_ns.load(.acquire);
        if (w == 0 or now_ns < w) continue; // no wake / not yet due

        // Due: fire scheduler_tick. It range-scans `_sched/by_time`,
        // fans out the due entries via `__rove_fire_wake`, and calls
        // `__rove_set_wake(new_min)` — advancing or clearing the
        // watermark so the next sweep doesn't re-fire. A crash before
        // that commit leaves the watermark due and self-heals on the
        // next tick.
        worker_streaming.fireSchedulerTick(worker, slot.instance_id);
    }
}

/// Unthrottled reconstruction pass for the false→true leadership
/// transition. `next_wake_ns` is volatile (never raft-replicated), so
/// a freshly-promoted leader's watermarks are all 0 — the steady
/// sweep's gate would skip every tenant and no scheduled wake would
/// ever fire. This pass rebuilds them: for every tenant in this
/// worker's partition that has any `_sched/by_time` entry, it fires
/// `scheduler_tick` once, which fires anything already due and calls
/// `__rove_set_wake` to install the watermark for the rest. Equivalent
/// to `sweepOwedRetriesOnPromotion`; O(tenants-in-partition) once on
/// promotion (the accepted cost — same as today's owed/boot sweeps).
pub fn sweepDurableWakesOnPromotion(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    // Bump the throttle baseline so the steady sweep doesn't
    // immediately re-walk on the next tick.
    worker.last_wake_sweep_ns = now_ns;

    const n_inboxes = blk: {
        worker.node.router.msg_inboxes_mutex.lock();
        defer worker.node.router.msg_inboxes_mutex.unlock();
        break :blk worker.node.router.msg_inboxes.items.len;
    };
    if (n_inboxes == 0) return;

    var it = worker.node.deploy.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const inbox_idx = std.hash.Wyhash.hash(0, slot.instance_id) % n_inboxes;
        if (inbox_idx != worker.msg_inbox_idx) continue;

        // Probe: skip tenants with no scheduled wakes so we don't fire
        // a (wasted) reconstruction tick for every idle tenant. One
        // bounded prefix read — the same per-tenant kv-scan cost the
        // owed promotion sweep already pays.
        var page = slot.app_kv.prefix(SCHED_BY_TIME_PREFIX, "", 1) catch |err| {
            std.log.warn(
                "rove-js wake promotion ({s}): prefix probe failed: {s}",
                .{ slot.instance_id, @errorName(err) },
            );
            continue;
        };
        const has_any = page.entries.len > 0;
        page.deinit();
        if (!has_any) continue;

        worker_streaming.fireSchedulerTick(worker, slot.instance_id);
    }
}

/// §2.6 P2 — commit-gated watermark bootstrap (the marker-commit race
/// fix). Called on the leader's `parked_units` commit arm for every
/// committed unit (both inbound-request writes and forgetful
/// subscription/wake re-arms funnel through here). For each committed
/// `_sched/by_time/{whenNs}/{id}` put, lower the tenant's
/// `next_wake_ns` watermark to `whenNs` — so the steady sweep fires
/// `scheduler_tick` at the new earliest time.
///
/// This is the durable analogue of a kv-react bootstrap
/// (`docs/durable-wake-plan.md` P2): the watermark is set from
/// *committed* state, post-commit, never volatile-set by the `at()`
/// caller (whose `_sched` write is still uncommitted at return — the
/// Phase-4.1 trap). Runs on the committing worker, which may differ
/// from the partition-owner that reads the watermark on its sweep; the
/// atomic monotone-min (`TenantSlot.lowerWake`) makes that race safe.
/// `scheduler_tick` later refines to the exact min via
/// `__rove_set_wake`. Without this, a freshly-scheduled wake would not
/// fire until the next leadership-gain reconstruction pass.
pub fn noteCommittedSchedWrites(worker: anytype, unit: anytype) void {
    var slot: ?*deployment_cache.TenantSlot = null;
    for (unit.buffered.items.items) |cmd| switch (cmd) {
        .kv_wake_broadcast => |w| {
            if (w.op != 'p') continue;
            const when_ns = parseByTimeWhenNs(w.key) orelse continue;
            if (slot == null) slot = worker.node.deploy.tenant_files_map.get(unit.tenant_id);
            if (slot) |s| s.lowerWake(when_ns);
        },
        else => {},
    };
}

/// Parse `whenNs` out of a `_sched/by_time/{whenNs_padded}/{id}` key.
/// Null when the key isn't a by_time index entry or the timestamp
/// segment doesn't parse. Leading zero-padding is fine — `parseInt`
/// ignores it.
fn parseByTimeWhenNs(key: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, key, SCHED_BY_TIME_PREFIX)) return null;
    const rest = key[SCHED_BY_TIME_PREFIX.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return std.fmt.parseInt(i64, rest[0..slash], 10) catch null;
}

test "parseByTimeWhenNs: extracts padded timestamp" {
    const testing = std.testing;
    try testing.expectEqual(@as(?i64, 1717200000000000000), parseByTimeWhenNs("_sched/by_time/01717200000000000000/abc123"));
    try testing.expectEqual(@as(?i64, 5), parseByTimeWhenNs("_sched/by_time/00000000000000000005/x"));
    try testing.expectEqual(@as(?i64, null), parseByTimeWhenNs("_sched/by_id/abc"));
    try testing.expectEqual(@as(?i64, null), parseByTimeWhenNs("_sched/by_time/nodelim"));
    try testing.expectEqual(@as(?i64, null), parseByTimeWhenNs("other/key"));
}
