//! Worker-side propose helpers for the three writeset envelope flavors.
//!
//! Each helper:
//!   1. Encodes the writeset.
//!   2. Wraps it in the requested envelope type.
//!   3. Stamps a seq from `raft.highWatermark()+1`.
//!   4. Submits to raft.
//!   5. Returns the seq for the caller to park on.
//!
//! No spinning; the caller stages the entity in `raft_pending` with a
//! `RaftWait{seq}` component. `drainRaftPending` (in worker.zig) observes
//! `raft.committedSeq()` advancing past that stamp and releases the
//! entity into the response pipeline.
//!
//! The log-batch flow (worker.zig:flushLogs) stays inline — its error
//! handling is non-fatal (log + continue) and the local-apply fallback
//! after the propose differs from the writeset path's commit-then-park
//! semantics.

const std = @import("std");
const kv_mod = @import("rove-kv");
const schedule_server = @import("rove-schedule-server");
const apply_mod = @import("apply.zig");

fn proposeEncoded(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    comptime kind: apply_mod.EnvelopeType,
    instance_id: []const u8,
    skip_empty: bool,
) !u64 {
    if (skip_empty and writeset.ops.items.len == 0) return 0;
    const allocator = worker.allocator;

    const ws_bytes = try writeset.encode(allocator);
    defer allocator.free(ws_bytes);

    const envelope = try switch (kind) {
        .writeset => apply_mod.encodeWriteSetEnvelope(allocator, instance_id, ws_bytes),
        .root_writeset => apply_mod.encodeRootWriteSetEnvelope(allocator, ws_bytes),
        .multi,
        .schedule_upsert,
        .schedule_complete,
        .schedule_cancel,
        .schedule_demote,
        => unreachable,
    };
    defer allocator.free(envelope);

    const seq = worker.raft.highWatermark() + 1;
    try worker.raft.propose(seq, envelope);
    return seq;
}

/// Per-tenant app.db writeset (envelope type=0). Always proposes,
/// even for an empty writeset — the seq stamp is still meaningful as
/// a synchronization point for downstream parking.
pub fn proposeWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    instance_id: []const u8,
) !u64 {
    return proposeEncoded(worker, writeset, .writeset, instance_id, false);
}

// (proposeRootWriteSet removed 2026-05-17: Option-A folds
// platform.root.* writes into the batch multi-envelope via
// proposeBatch, so there is no standalone root-writeset proposer.
// The type-2 encoder `apply.encodeRootWriteSetEnvelope` stays —
// proposeBatch and acme.zig use it directly.)

/// Propose the per-batch writeset + http.send/cancel batch as ONE
/// raft entry — the unit of atomicity for the dispatcher path. Three
/// shapes:
///
///   - just writes → a bare type-0 writeset envelope
///   - just one bucket of schedules / cancels → that bucket bare
///   - 2+ buckets non-empty → type-7 multi-envelope wrapping each
///
/// Empty everywhere is unreachable from the caller (worker_dispatch
/// only calls when at least one bucket has content); we still no-op-
/// return `seq=0` rather than panic so refactoring stays graceful.
///
/// Returns the assigned raft seq for the caller to park on.
/// Propose a dynamic list of already-encoded, **non-multi** inner
/// envelopes. Replaces the per-producer fixed `[N][]u8` arrays — the
/// multi wire format already supports up to 255 inners (u8 count) and
/// apply already loops them; the old `[3]`/`[4]` caps were just stack
/// arrays sized for the then-current producers.
///
///  - 0 inners      → no-op, returns seq 0
///  - 1 inner        → bare propose (no multi-wrapper overhead — the
///                      common case, e.g. just a writeset)
///  - 2..255 inners  → one multi-envelope propose (atomic)
///  - >255 inners    → ⌈N/255⌉ multi proposes. By caller convention
///    the writeset rides `inner[0]` so it lands in chunk 0. Each
///    chunk applies atomically; **cross-chunk is NOT atomic**. This
///    is reachable only in the extreme >255-ops-for-one-tenant-in-
///    one-pass case: a mid-chunk leader change can re-fire the not-
///    yet-completed schedules, which `schedule_complete`'s
///    `version_at_fire` guard makes idempotent — the same
///    at-least-once posture as the existing http.send contract.
///
/// Returns the LAST propose's seq (the batch watermark). The H2
/// dispatch path parks its txn on this seq and never exceeds the
/// cap, so it always sees a single-propose seq exactly as before.
pub fn proposeMulti(worker: anytype, inner: []const []const u8) !u64 {
    if (inner.len == 0) return 0;
    const allocator = worker.allocator;
    const CHUNK: usize = 255;
    var seq: u64 = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const end = @min(i + CHUNK, inner.len);
        const slice = inner[i..end];
        seq = worker.raft.highWatermark() + 1;
        if (slice.len == 1) {
            try worker.raft.propose(seq, slice[0]);
        } else {
            const multi = try apply_mod.encodeMultiEnvelope(allocator, slice);
            defer allocator.free(multi);
            try worker.raft.propose(seq, multi);
        }
        i = end;
    }
    return seq;
}

pub fn proposeBatch(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    schedules: []const schedule_server.ScheduleRow,
    cancels: []const schedule_server.CancelTarget,
    anchor_id: []const u8,
) !u64 {
    const allocator = worker.allocator;

    // Build each present envelope into a dynamic inner-list, then
    // hand off to proposeMulti. encodeTyped @memcpy's the payload so
    // each env owns its bytes — transient payload buffers are freed
    // immediately after encoding. Inner order keeps the writes
    // contiguous and early (anchor at inner[0], then the Option-A
    // side writes) so the atomic-critical set lands in chunk 0 in
    // the realistic <255-inner case (proposeMulti's cross-chunk
    // non-atomicity only bites in the extreme >255 path).
    var inner: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (inner.items) |env| allocator.free(env);
        inner.deinit(allocator);
    }

    if (writeset.ops.items.len > 0) {
        const ws_bytes = try writeset.encode(allocator);
        defer allocator.free(ws_bytes);
        try inner.append(allocator, try apply_mod.encodeWriteSetEnvelope(allocator, anchor_id, ws_bytes));
    }
    // Option-A (docs/proposer-audit.md Addendum 3): the admin
    // handler's cross-tenant trampoline writes (per target, type-0
    // with the target id) and `platform.root.*` writes (type-2)
    // ride the SAME multi-envelope → one raft seq the calling admin
    // request is parked on by finalizeBatch. Replaces the per-site
    // fire-and-forget proposes the caller never gated on. `apply`
    // routes each inner to its per-target store atomically.
    for (worker.batch_side.targets.items) |*t| {
        if (t.ws.ops.items.len == 0) continue;
        const tb = try t.ws.encode(allocator);
        defer allocator.free(tb);
        try inner.append(allocator, try apply_mod.encodeWriteSetEnvelope(allocator, t.id, tb));
    }
    if (worker.batch_side.root_ws) |*rw| {
        if (rw.ops.items.len > 0) {
            const rb = try rw.encode(allocator);
            defer allocator.free(rb);
            try inner.append(allocator, try apply_mod.encodeRootWriteSetEnvelope(allocator, rb));
        }
    }
    if (schedules.len > 0) {
        const payload = try schedule_server.encodeUpsertBatch(allocator, schedules);
        defer allocator.free(payload);
        try inner.append(allocator, try apply_mod.encodeScheduleUpsertEnvelope(allocator, payload));
    }
    if (cancels.len > 0) {
        const payload = try schedule_server.encodeCancelBatch(allocator, cancels);
        defer allocator.free(payload);
        try inner.append(allocator, try apply_mod.encodeScheduleCancelEnvelope(allocator, payload));
    }

    return proposeMulti(worker, inner.items);
}
