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
const kv_mod = @import("raft-kv");
const apply_mod = @import("apply.zig");

/// V2 Phase 2c: the result of a propose. `group_id` is the tenant's raft
/// group (the worker parks `RaftWait{group_id, seq}` and the drain polls
/// `bridge.committedSeq(group_id)`); `seq` is the per-tenant propose seq,
/// or 0 when nothing was proposed (empty writeset, skip path). Replaces
/// the bare `u64` seq the V1 global watermark used.
pub const Proposed = struct {
    group_id: u64 = 0,
    seq: u64 = 0,
};

fn proposeEncoded(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    comptime kind: apply_mod.EnvelopeType,
    instance_id: []const u8,
    rs_bytes: []const u8,
    skip_empty: bool,
) !Proposed {
    if (skip_empty and writeset.ops.items.len == 0) return .{};
    const allocator = worker.allocator;

    // Resolve (or assign) this tenant's raft group id. Idempotent; the
    // bridge maps the envelope `id` string → numeric gid (Phase-3
    // directory stub). The root writeset (`instance_id == ""`) maps to a
    // reserved root group.
    const gid = try worker.raft.registerTenant(instance_id);

    const ws_bytes = try writeset.encode(allocator);
    defer allocator.free(ws_bytes);

    const envelope = try switch (kind) {
        .writeset => apply_mod.encodeWriteSetEnvelope(allocator, instance_id, ws_bytes, rs_bytes),
        .root_writeset => apply_mod.encodeRootWriteSetEnvelope(allocator, ws_bytes),
        .multi => unreachable,
    };
    defer allocator.free(envelope);

    // The bridge copies the envelope + assigns the per-tenant seq.
    const seq = try worker.raft.propose(gid, envelope);
    return .{ .group_id = gid, .seq = seq };
}

/// Per-tenant app.db writeset (envelope type=0). Always proposes,
/// even for an empty writeset — the seq stamp is still meaningful as
/// a synchronization point for downstream parking.
///
/// `rs_bytes` rides the envelope's readset section
/// (`docs/readset-replication-plan.md` Phase 3). Pass `""` from
/// non-handler producers (ACME, config mirror, internal admin
/// endpoints); pass `tape_mod.Readset.serialize(...)` bytes from
/// dispatched-handler paths. Slice 3b ships the signature change
/// with every call site passing `""`; slice 3d wires the actual
/// readset serialization from `dispatchPending`.
pub fn proposeWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    instance_id: []const u8,
    rs_bytes: []const u8,
) !Proposed {
    return proposeEncoded(worker, writeset, .writeset, instance_id, rs_bytes, false);
}

// (proposeRootWriteSet removed 2026-05-17: Option-A folds
// platform.root.* writes into the batch multi-envelope via
// proposeBatch, so there is no standalone root-writeset proposer.
// The type-2 encoder `apply.encodeRootWriteSetEnvelope` stays —
// proposeBatch and acme.zig use it directly.)

/// Propose a single `__root__` writeset (type=2 → `{data_dir}/__root__.db`)
/// through `anchor_id`'s raft group. Narrow standalone proposer re-added for
/// the control-plane domain-alias write (`/_system/v2-domain`, step3-auth-plan
/// B3): the caller must have already committed the write to its root overlay
/// speculatively (so the leader sees it; the durabilize floor folds it on the
/// `noteWorkerCommitted` ack); followers apply this envelope. Returns the
/// proposed group/seq for the caller to await.
pub fn proposeRoot(
    worker: anytype,
    anchor_id: []const u8,
    writeset: *const kv_mod.WriteSet,
) !Proposed {
    const allocator = worker.allocator;
    const gid = try worker.raft.registerTenant(anchor_id);
    const ws_bytes = try writeset.encode(allocator);
    defer allocator.free(ws_bytes);
    const root_env = try apply_mod.encodeRootWriteSetEnvelope(allocator, ws_bytes);
    defer allocator.free(root_env);
    // proposeMulti with a single inner does a bare propose (no multi wrapper)
    // and does not take ownership of `root_env` — freed by the defer above
    // after it returns.
    return proposeMulti(worker, gid, &.{root_env});
}

/// Propose a dynamic list of already-encoded, **non-multi** inner
/// envelopes. Replaces the per-producer fixed `[N][]u8` arrays — the
/// multi wire format already supports up to 255 inners (u8 count) and
/// apply already loops them; the old `[3]`/`[4]` caps were just stack
/// arrays sized for the then-current producers.
///
///  - 0 inners      → no-op, returns seq 0
///  - 1 inner        → bare propose (no multi-wrapper overhead — the
///                      common case, e.g. just a writeset)
///  - 2..255 inners  → one multi-envelope propose (atomic at the raft-
///                      LOG level; apply is per-inner — see below)
///  - >255 inners    → ⌈N/255⌉ multi proposes. By caller convention
///    the writeset rides `inner[0]` so it lands in chunk 0. Each
///    chunk replicates as one raft entry, but **neither cross-chunk
///    nor cross-inner apply is transactional** — `applyMulti` commits
///    each inner in its own kvexp txn, so recovery leans on idempotent
///    replay, not rollback. This only bites in the extreme >255-ops-
///    for-one-tenant-in-one-pass case: a mid-chunk leader change can
///    re-apply the not-yet-resolved `_send/owed/` markers, which
///    Option-(b) resolve-once (proof-presence + send-id dedup) makes
///    idempotent — the same at-least-once posture as the existing
///    http.send contract.
///
/// Returns the LAST propose's seq (the batch watermark). The H2
/// dispatch path parks its txn on this seq and never exceeds the
/// cap, so it always sees a single-propose seq exactly as before.
pub fn proposeMulti(worker: anytype, gid: u64, inner: []const []const u8) !Proposed {
    if (inner.len == 0) return .{};
    const allocator = worker.allocator;
    const CHUNK: usize = 255;
    var seq: u64 = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const end = @min(i + CHUNK, inner.len);
        const slice = inner[i..end];
        // V2 Phase 2c: the whole multi (anchor writeset + any same-batch
        // side writes) replicates through the ANCHOR tenant's group. The
        // V1 cross-tenant trampoline (target tenants + root in one multi)
        // is an admin/control-plane path off the single-tenant slice;
        // Phase 3 (directory) routes those per-target.
        if (slice.len == 1) {
            seq = try worker.raft.propose(gid, slice[0]);
        } else {
            const multi = try apply_mod.encodeMultiEnvelope(allocator, slice);
            defer allocator.free(multi);
            seq = try worker.raft.propose(gid, multi);
        }
        i = end;
    }
    return .{ .group_id = gid, .seq = seq };
}

/// `rs_bytes` rides the anchor envelope (inner[0]) only. Targets
/// + root_ws envelopes in the same batch carry empty readsets —
/// the readset is per-dispatch, not per-envelope, and the batch's
/// dispatching handler's readset already covers the whole batch.
/// Pass `""` for non-handler-driven proposes (the propose path is
/// signature-symmetric across producers).
pub fn proposeBatch(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    anchor_id: []const u8,
    rs_bytes: []const u8,
) !Proposed {
    const allocator = worker.allocator;
    const gid = try worker.raft.registerTenant(anchor_id);

    // Build each present envelope into a dynamic inner-list, then
    // hand off to proposeMulti. encodeTyped @memcpy's the payload so
    // each env owns its bytes — transient payload buffers are freed
    // immediately after encoding. Inner order keeps the writes
    // contiguous and early (anchor at inner[0], then the Option-A
    // side writes) so the atomic-critical set lands in the first
    // chunk in the realistic case (proposeMulti splits at its
    // `CHUNK` = 255; cross-chunk non-atomicity only bites in the
    // extreme >255-inners-for-one-batch path).
    var inner: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (inner.items) |env| allocator.free(env);
        inner.deinit(allocator);
    }

    if (writeset.ops.items.len > 0) {
        const ws_bytes = try writeset.encode(allocator);
        defer allocator.free(ws_bytes);
        try inner.append(allocator, try apply_mod.encodeWriteSetEnvelope(allocator, anchor_id, ws_bytes, rs_bytes));
    }
    // Option-A (docs/proposer-audit.md Addendum 3): the admin
    // handler's cross-tenant trampoline writes (per target, type-0
    // with the target id) and `platform.root.*` writes (type-2)
    // ride the SAME multi-envelope → one raft seq the calling admin
    // request is parked on by finalizeBatch. Replaces the per-site
    // fire-and-forget proposes the caller never gated on. `apply`
    // routes each inner to its per-target store; the inners share one
    // raft entry (atomic replication), but each commits its own kvexp
    // txn — apply is not cross-inner transactional, so recovery is via
    // idempotent replay, not rollback.
    //
    // Target + root envelopes carry empty rs_bytes — the readset
    // lives on the anchor envelope (inner[0]) above; one readset
    // per dispatch, not per envelope.
    for (worker.batch_side.targets.items) |*t| {
        if (t.ws.ops.items.len == 0) continue;
        const tb = try t.ws.encode(allocator);
        defer allocator.free(tb);
        try inner.append(allocator, try apply_mod.encodeWriteSetEnvelope(allocator, t.id, tb, ""));
    }
    if (worker.batch_side.root_ws) |*rw| {
        if (rw.ops.items.len > 0) {
            const rb = try rw.encode(allocator);
            defer allocator.free(rb);
            try inner.append(allocator, try apply_mod.encodeRootWriteSetEnvelope(allocator, rb));
        }
    }
    return proposeMulti(worker, gid, inner.items);
}
