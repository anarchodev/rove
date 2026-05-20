//! Per-tenant batched transactional dispatch skeleton.
//!
//! Shared by the callback path (`callback_dispatch.zig`) and — after
//! the schedule_ops envelope merge — the internal-schedule path. Owns
//! the subtle, regression-prone discipline that was duplicated across
//! those paths:
//!
//!  - open ONE tracked txn for the tenant; skip cleanly on lock
//!    `Conflict` (another worker got here first / mid-commit);
//!  - run every row's handler under that txn, accumulating into one
//!    shared writeset + pending Cmd buffers (a failed row is logged
//!    and kept for retry — the receipt isn't consumed);
//!  - take the read-only fast path (rollback, no raft hop) when the
//!    policy says nothing needs replicating;
//!  - else speculative-commit-then-propose-once; a synchronous
//!    propose failure needs no compensation (kvexp volatility —
//!    the overlay is lost, no on-disk divergence), mirroring the
//!    HTTP dispatch fault path.
//!
//! Row shape, per-row run, the "needs propose" predicate, and the
//! propose tail are injected via `policy` (see
//! `callback_dispatch.SendCompletionPolicy`). `tc` is passed through
//! opaque to keep this file free of a `worker.zig` import cycle.
const std = @import("std");
const kv_mod = @import("rove-kv");
const tenant_mod = @import("rove-tenant");

/// Run one tenant's contiguous row slice as a single batched txn.
/// Processes at most `max_rows` (the remainder catches up next pass).
/// Returns rows visited (delivered + kept-for-retry).
pub fn drainTenantBatch(
    worker: anytype,
    tc: anytype,
    inst: *const tenant_mod.Instance,
    rows: anytype,
    max_rows: usize,
    policy: anytype,
) !usize {
    const allocator = worker.allocator;
    _ = allocator;
    const n = @min(rows.len, max_rows);
    if (n == 0) return 0;

    var txn = try inst.kv.beginTrackedImmediate();
    txn.open() catch |err| {
        if (err == kv_mod.KvError.Conflict) return 0; // another worker got here first
        return err;
    };
    var committed = false;
    errdefer if (!committed) {
        txn.rollback() catch {};
    };

    var writeset = kv_mod.WriteSet.init(worker.allocator);
    defer writeset.deinit();

    var visited: usize = 0;
    for (rows[0..n]) |row| {
        visited += 1;
        policy.runOne(
            worker,
            tc,
            inst,
            &txn,
            &writeset,
            row,
        ) catch |err| {
            std.log.warn(
                "tenant-batch {s}: runOne kept-for-retry: {s}",
                .{ inst.id, @errorName(err) },
            );
            continue;
        };
    }

    if (!policy.needsPropose(&writeset)) {
        // Nothing to replicate — release the txn without proposing.
        txn.rollback() catch {};
        committed = true;
        return visited;
    }

    try txn.commit();
    committed = true;

    policy.propose(worker, inst, &writeset) catch |err| {
        // The local write was a kvexp *speculative* commit (volatile
        // — LMDB only at raft-apply); a propose that never reached
        // raft leaves nothing durable, so there is no local undo to
        // perform (kvexp has no kv_undo table — proposer-audit.md
        // volatility).
        return err;
    };

    return visited;
}
