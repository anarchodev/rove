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
//!    HTTP dispatch fault path;
//!  - SSE emits are parked on the propose seq and released at
//!    commit (idiom-1), not fired at accept.
//!
//! Row shape, per-row run, the "needs propose" predicate, and the
//! propose tail are injected via `policy` (see
//! `callback_dispatch.SendCompletionPolicy`). `tc` is passed through
//! opaque to keep this file free of a `worker.zig` import cycle.
const std = @import("std");
const kv_mod = @import("rove-kv");
const tenant_mod = @import("rove-tenant");
const sse_dispatch = @import("sse_dispatch.zig");

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

    var writeset = kv_mod.WriteSet.init(allocator);
    defer writeset.deinit();

    var pending_emits: std.ArrayListUnmanaged(sse_dispatch.EmitEntry) = .empty;
    defer {
        for (pending_emits.items) |*e| e.deinit(allocator);
        pending_emits.deinit(allocator);
    }
    var visited: usize = 0;
    for (rows[0..n]) |row| {
        visited += 1;
        policy.runOne(
            worker,
            tc,
            inst,
            &txn,
            &writeset,
            &pending_emits,
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
        // Read-only emits fire immediately; no raft hop to gate on.
        txn.rollback() catch {};
        committed = true;
        fireEmits(worker, inst.id, &pending_emits);
        return visited;
    }

    try txn.commit();
    committed = true;

    policy.propose(worker, inst, &writeset, &pending_emits) catch |err| {
        // The local write was a kvexp *speculative* commit (volatile
        // — LMDB only at raft-apply); a propose that never reached
        // raft leaves nothing durable, so there is no local undo to
        // perform (kvexp has no kv_undo table — proposer-audit.md
        // volatility). propose failed BEFORE parkEmits, so
        // pending_emits is intact and the defer discards it
        // (correct: nothing committed → the emit must not fire).
        return err;
    };

    // Emits are NOT fired here (accept). policy.propose parked them
    // on worker.pending_units keyed by the propose seq; the drain
    // releases them at commit (committedSeq>=seq) / discards on
    // fault — docs/unified-effect-gating.md idiom-1. (pending_emits
    // is now emptied; its defer is a no-op.)
    return visited;
}

/// Hand the merged batch emits to the in-process SSE thread. No-op
/// when there's no in-process SSE or the batch produced none
/// (best-effort — SSE is lossy by design).
fn fireEmits(
    worker: anytype,
    tenant_id: []const u8,
    pe: *std.ArrayListUnmanaged(sse_dispatch.EmitEntry),
) void {
    if (pe.items.len == 0) return;
    const h = worker.sse_handle orelse return;
    h.enqueueEmit(tenant_id, pe.items);
}
