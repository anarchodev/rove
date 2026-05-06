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
const webhook_server = @import("rove-webhook-server");
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
        .files_writeset => apply_mod.encodeFilesWriteSetEnvelope(allocator, instance_id, ws_bytes),
        .root_writeset => apply_mod.encodeRootWriteSetEnvelope(allocator, ws_bytes),
        .webhook_enqueue_batch,
        .webhook_complete,
        .webhook_retry_schedule,
        .multi,
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

/// Per-tenant files.db writeset (envelope type=3). Used by
/// `deployStarterContent` and the files-server's upload + deploy
/// endpoints. Followers replay onto their copy of
/// `{data_dir}/{id}/files.db`. Blob bytes are NOT in the envelope —
/// multi-node setups need a shared BlobStore backend.
///
/// No-op fast path for empty writesets: returns seq=0 so callers
/// don't park on a meaningless raft entry.
pub fn proposeFilesWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    instance_id: []const u8,
) !u64 {
    return proposeEncoded(worker, writeset, .files_writeset, instance_id, true);
}

/// Root writeset (envelope type=2). Followers apply to their own
/// `__root__.db` in `applyRootWriteSet`. Used by signup (instance
/// marker + domain assignment) and by the admin JS handler's
/// `platform.root.*` writes.
///
/// No-op fast path for empty writesets — saves a raft entry for
/// admin requests that only read platform state.
///
/// **Divergence note**: if the caller already wrote to root locally
/// and this propose fails, the leader's root.db has state that
/// followers don't. Current code logs and moves on (at-least-once
/// semantics consistent with the webhook / callback layers). A future
/// iteration can wrap root writes in a TrackedTxn with undo
/// semantics so propose failure triggers a compensating rollback.
pub fn proposeRootWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
) !u64 {
    return proposeEncoded(worker, writeset, .root_writeset, "", true);
}

/// Phase 5.5 (d), step 4. Propose the per-batch writeset + webhook
/// batch as ONE raft entry — the unit of atomicity for the
/// `webhook.path = direct` cutover. Three shapes:
///
///   - both non-empty → type-7 multi-envelope wrapping envelope 0
///     (writeset, with `instance_id`) + envelope 4 (enqueue batch)
///   - writes only → a bare type-0 writeset envelope (same as
///     `proposeWriteSet`)
///   - webhooks only → a bare type-4 enqueue-batch envelope
///
/// Empty + empty is unreachable from the caller (worker_dispatch only
/// calls when `has_writes or has_webhooks`); we still no-op-return
/// `seq=0` rather than panic so refactoring stays graceful.
///
/// Returns the assigned raft seq for the caller to park on.
pub fn proposeBatchAndWebhooks(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    webhooks: []const webhook_server.WebhookRow,
    anchor_id: []const u8,
) !u64 {
    const allocator = worker.allocator;
    const has_writes = writeset.ops.items.len > 0;
    const has_webhooks = webhooks.len > 0;
    if (!has_writes and !has_webhooks) return 0;

    if (has_writes and has_webhooks) {
        const ws_bytes = try writeset.encode(allocator);
        defer allocator.free(ws_bytes);
        const ws_env = try apply_mod.encodeWriteSetEnvelope(allocator, anchor_id, ws_bytes);
        defer allocator.free(ws_env);

        const wh_payload = try webhook_server.encodeEnqueueBatch(allocator, webhooks);
        defer allocator.free(wh_payload);
        const wh_env = try apply_mod.encodeWebhookEnqueueBatchEnvelope(allocator, wh_payload);
        defer allocator.free(wh_env);

        const inner: [2][]const u8 = .{ ws_env, wh_env };
        const multi = try apply_mod.encodeMultiEnvelope(allocator, &inner);
        defer allocator.free(multi);

        const seq = worker.raft.highWatermark() + 1;
        try worker.raft.propose(seq, multi);
        return seq;
    }

    if (has_writes) {
        return proposeWriteSet(worker, writeset, anchor_id);
    }

    // Webhooks only.
    const wh_payload = try webhook_server.encodeEnqueueBatch(allocator, webhooks);
    defer allocator.free(wh_payload);
    const wh_env = try apply_mod.encodeWebhookEnqueueBatchEnvelope(allocator, wh_payload);
    defer allocator.free(wh_env);

    const seq = worker.raft.highWatermark() + 1;
    try worker.raft.propose(seq, wh_env);
    return seq;
}
