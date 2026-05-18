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
//!  - else commit-then-propose-once, with compensating `undoTxn` on
//!    propose failure (mirrors the HTTP dispatch fault path);
//!  - fire SSE emits after raft accept.
//!
//! Row shape, per-row run, the "needs propose" predicate, and the
//! propose tail are injected via `policy` (see
//! `callback_dispatch.CallbackPolicy`). `tc` is passed through opaque
//! to keep this file free of a `worker.zig` import cycle.
const std = @import("std");
const kv_mod = @import("rove-kv");
const tenant_mod = @import("rove-tenant");
const schedule_server = @import("rove-schedule-server");
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
    var pending_schedules: std.ArrayListUnmanaged(schedule_server.ScheduleRow) = .empty;
    defer {
        for (pending_schedules.items) |*r| r.deinit(allocator);
        pending_schedules.deinit(allocator);
    }
    var pending_cancels: std.ArrayListUnmanaged(schedule_server.CancelTarget) = .empty;
    defer {
        for (pending_cancels.items) |*t| t.deinit(allocator);
        pending_cancels.deinit(allocator);
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
            &pending_schedules,
            &pending_cancels,
            row,
        ) catch |err| {
            std.log.warn(
                "tenant-batch {s}: runOne kept-for-retry: {s}",
                .{ inst.id, @errorName(err) },
            );
            continue;
        };
    }

    const batch_seq = txn.txn_seq;
    if (!policy.needsPropose(&writeset, &pending_schedules, &pending_cancels)) {
        // Nothing to replicate — release the txn without proposing.
        // Read-only emits fire immediately; no raft hop to gate on.
        txn.rollback() catch {};
        committed = true;
        fireEmits(worker, inst.id, &pending_emits);
        return visited;
    }

    try txn.commit();
    committed = true;

    policy.propose(worker, inst, &writeset, &pending_schedules, &pending_cancels, &pending_emits) catch |err| {
        // Local writes already committed; compensating rollback via
        // the undo log mirrors the HTTP dispatch fault path. On this
        // path propose failed BEFORE parkEmits, so pending_emits is
        // intact and the defer discards it (correct: nothing
        // committed → the emit must not fire).
        inst.kv.undoTxn(batch_seq) catch |undo_err|
            std.log.err(
                "tenant-batch {s}: undoTxn after propose error failed: {s}",
                .{ inst.id, @errorName(undo_err) },
            );
        return err;
    };

    // Emits are NOT fired here (accept). policy.propose parked them
    // on worker.pending_units keyed by the propose seq; the drain
    // releases them at commit (committedSeq>=seq) / discards on
    // fault — docs/unified-effect-gating.md idiom-1. (pending_emits
    // is now emptied; its defer is a no-op.)
    return visited;
}

/// Fire-and-forget the merged batch emits at sse-server. No-op when
/// the worker isn't wired for SSE or the batch produced none.
fn fireEmits(
    worker: anytype,
    tenant_id: []const u8,
    pe: *std.ArrayListUnmanaged(sse_dispatch.EmitEntry),
) void {
    if (pe.items.len == 0) return;
    const easy = worker.sse_curl orelse return;
    const base = worker.sse_public_base orelse return;
    const tok = worker.sse_internal_token orelse return;
    if (base.len == 0 or tok.len == 0) return;
    sse_dispatch.fireBatch(
        worker.allocator,
        easy,
        base,
        tok,
        tenant_id,
        // No batch-level request_id breadcrumb — batched dispatch
        // isn't tied to one inbound request. sse-server ignores it.
        0,
        pe.items,
        worker.sse_insecure_tls,
    );
}
