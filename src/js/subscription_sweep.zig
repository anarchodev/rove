//! `subscription_sweep.zig` — leader-side boot + cron subscription sweeps.
//!
//! Extracted from `worker.zig`. These are the worker poll-loop systems
//! that (re-)fire subscription chains without an inbound request:
//!   - `sweepBootSubscriptions` — on false→true leadership transition,
//!     re-enqueue boot subscriptions whose marker is absent (cold-start
//!     race where slots loaded before raft elected a leader).
//!   - `sweepCronSubscriptions` / `sweepTenantCron` / `findCronState` —
//!     fire cron subscriptions whose `next_fire_at_ns` is due.
//! `CronState` is the per-(tenant, sub_name) next-fire timer, a rove
//! component living on worker 0's `cron_state` collection.
//!
//! Free functions taking `worker: anytype`; `worker.zig` re-exports the
//! public entry points (CronState, the two sweep fns, the interval).

const std = @import("std");
const rove = @import("rove");
const deployment_cache = @import("deployment_cache.zig");

const TenantSlot = deployment_cache.TenantSlot;
const TenantFilesSnapshot = deployment_cache.TenantFilesSnapshot;

/// Rove component owning a cron subscription's next-fire timestamp.
/// One entity per `(tenant_id, sub_name)` pair, living on worker 0's
/// `cron_state` collection. Strings dup'd at create-time, freed on
/// entity destroy via the collection's auto-deinit (rove principle
/// #2). Created lazily by `sweepCronSubscriptions` on first sight
/// (matches the pre-collection hashmap's first-sight initialization).
/// Destroyed on tenant unload.
pub const CronState = struct {
    tenant_id: []u8,
    sub_name: []u8,
    next_fire_at_ns: i64,

    pub fn deinit(allocator: std.mem.Allocator, items: []CronState) void {
        for (items) |*item| {
            allocator.free(item.tenant_id);
            allocator.free(item.sub_name);
        }
    }
};

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

/// Gap 2.1 Phase F: throttled cron sweep — runs at most once per
/// `CRON_SWEEP_INTERVAL_NS` from worker 0 when leader. Walks every
/// loaded tenant slot's cron subscriptions and fires any that are
/// due (or initializes the next-fire time on first sight).
///
/// State lives on `worker.cron_state` (rove collection of `CronState`
/// components, one entity per `(tenant_id, sub_name)`). Not raft-
/// replicated, so leader change resets the cron clock (next fire =
/// now + interval_ms on the new leader). For long-interval crons
/// this can pause up to one interval after failover; customer-side
/// missed-tick tolerance is the documented contract.
pub const CRON_SWEEP_INTERVAL_NS: i64 = 1 * std.time.ns_per_s;

pub fn sweepCronSubscriptions(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - worker.last_cron_sweep_ns < CRON_SWEEP_INTERVAL_NS) return;
    worker.last_cron_sweep_ns = now_ns;

    var it = worker.node.deploy.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const snap = slot.pinCurrent() orelse continue;
        defer snap.release();
        if (snap.subscriptions.len == 0) continue;
        sweepTenantCron(worker, slot, snap, now_ns);
    }
}

/// Find the `CronState` entity for `(tenant_id, sub_name)` in the
/// collection, or null if not yet created. Linear scan — fine at the
/// expected scale (tens of active crons, 1Hz sweep).
fn findCronState(worker: anytype, tenant_id: []const u8, sub_name: []const u8) ?*CronState {
    const states = worker.cron_state.column(CronState);
    for (states) |*s| {
        if (std.mem.eql(u8, s.tenant_id, tenant_id) and std.mem.eql(u8, s.sub_name, sub_name)) {
            return s;
        }
    }
    return null;
}

/// Walk one tenant's cron subscriptions; for each that's due, enqueue
/// a fire and advance `next_fire_at_ns` on the entity. First-sight
/// creates a new entity initialized to `now_ns + interval_ms_ns`
/// (interval-delay before the FIRST fire — keeps cron behavior
/// natural across deploy + restart).
fn sweepTenantCron(
    worker: anytype,
    slot: *TenantSlot,
    snap: *TenantFilesSnapshot,
    now_ns: i64,
) void {
    const allocator = worker.allocator;
    for (snap.subscriptions) |sub| {
        const interval_ms: i64 = switch (sub.spec) {
            .cron => |c| c.interval_ms,
            else => continue,
        };
        const interval_ns: i64 = interval_ms * std.time.ns_per_ms;

        if (findCronState(worker, slot.instance_id, sub.name)) |state| {
            if (now_ns < state.next_fire_at_ns) continue;
            // Advance to next interval. Use cumulative drift
            // (`next + interval`) when within an interval of now;
            // otherwise (long pause / failover) reset to `now +
            // interval` to avoid pile-up.
            state.next_fire_at_ns = if (state.next_fire_at_ns + interval_ns > now_ns)
                state.next_fire_at_ns + interval_ns
            else
                now_ns + interval_ns;
        } else {
            // First sight: create an entity with the next-fire time
            // initialized; don't fire this round. The customer sees
            // the first fire roughly `interval_ms` after this sweep.
            const tenant_dup = allocator.dupe(u8, slot.instance_id) catch continue;
            const sub_dup = allocator.dupe(u8, sub.name) catch {
                allocator.free(tenant_dup);
                continue;
            };
            const ent = worker.h2.reg.create(&worker.cron_state) catch {
                allocator.free(tenant_dup);
                allocator.free(sub_dup);
                continue;
            };
            worker.h2.reg.set(ent, &worker.cron_state, CronState, .{
                .tenant_id = tenant_dup,
                .sub_name = sub_dup,
                .next_fire_at_ns = now_ns + interval_ns,
            }) catch {
                allocator.free(tenant_dup);
                allocator.free(sub_dup);
                continue;
            };
            continue;
        }

        worker.node.router.enqueueSubscriptionFireForTenant(.{
            .tenant_id = slot.instance_id,
            .subscription_name = sub.name,
            .module_path = sub.module_path,
            .source = .{ .cron = .{ .fired_at_ns = now_ns } },
        }) catch |err| std.log.warn(
            "rove-js cron sweep enqueue ({s}/{s}): {s}",
            .{ slot.instance_id, sub.name, @errorName(err) },
        );
    }
}
