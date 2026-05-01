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
        .log_batch => unreachable,
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
/// semantics consistent with the outbox / callback layers). A future
/// iteration can wrap root writes in a TrackedTxn with undo
/// semantics so propose failure triggers a compensating rollback.
pub fn proposeRootWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
) !u64 {
    return proposeEncoded(worker, writeset, .root_writeset, "", true);
}
