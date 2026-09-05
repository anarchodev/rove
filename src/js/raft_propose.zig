// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
const bridge_mod = @import("bridge");
// The wire limit every batch has to fit inside, and the arithmetic for how
// many bytes a thing puts on it — one authority, derived from the receiver's
// buffer size.
const sizing = @import("rove-sizing");
const tenant_mod = @import("rove-tenant");

comptime {
    // The budgets and their partition of the entry are derived and asserted
    // once, in `rove-sizing`. What has to hold HERE is the one term that
    // derivation could not see: the longest id an envelope actually carries.
    // Under-reserving it would make the entry's fixed framing a guess again.
    std.debug.assert(tenant_mod.MAX_INSTANCE_ID_LEN <= sizing.MAX_ENVELOPE_ID_BYTES);
}

/// What an entry has left for a readset once `writeset` is on it, for a
/// producer that proposes ONE envelope alone (a cont-resume, a fire's
/// forgetful writes). The batch path computes this from its running total
/// instead; both hand it to `serializeForEntry`, so no producer can put a
/// readset on an entry that has no room for it.
pub fn entryRoomFor(writeset: *const kv_mod.WriteSet) usize {
    const spent = sizing.ENTRY_FIXED_BYTES + writeset.encodedSize();
    return sizing.MAX_ENTRY_BYTES -| spent -| sizing.RS_BLOB_HDR_BYTES;
}

/// The result of a propose. `group_id` is the tenant's raft group (the
/// worker parks `RaftWait{group_id, seq}` and the drain polls
/// `bridge.committedSeq(group_id)`); `seq` is the per-tenant propose
/// seq, or 0 when nothing was proposed (empty writeset, skip path).
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
    // bridge maps the envelope `id` string → numeric gid (directory
    // stub). The root writeset (`instance_id == ""`) maps to a
    // reserved root group.
    const gid = try worker.raft.registerTenant(instance_id);

    const ws_bytes = try writeset.encode(allocator);
    defer allocator.free(ws_bytes);

    const envelope = try switch (kind) {
        .writeset => apply_mod.encodeWriteSetEnvelope(allocator, instance_id, ws_bytes, rs_bytes),
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
/// (readset replication, `docs/architecture/effects-and-handlers.md`). Pass `""` from
/// non-handler producers (ACME, config mirror, internal admin
/// endpoints); pass `tape_mod.Readset.serialize(...)` bytes from
/// dispatched-handler paths.
pub fn proposeWriteSet(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    instance_id: []const u8,
    rs_bytes: []const u8,
) !Proposed {
    return proposeEncoded(worker, writeset, .writeset, instance_id, rs_bytes, false);
}

// platform.root.* writes fold into the batch multi-envelope via
// `proposeBatch`, so there is no general standalone root-writeset
// proposer.
// control-plane domain-alias write). The type-2 encoder
// `apply.encodeRootWriteSetEnvelope` is used by `proposeBatch` and
// `acme.zig` directly.


/// Propose a dynamic list of already-encoded, **non-multi** inner
/// envelopes. The multi wire format supports up to 255 inners (u8
/// count) and apply loops them, so the inner list is dynamic rather
/// than a fixed-size array.
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
///    resolve-once (proof-presence + send-id dedup) makes idempotent
///    — the same at-least-once posture as the http.send contract.
///
/// Returns the LAST propose's seq (the batch watermark). The H2
/// dispatch path parks its txn on this seq and never exceeds the
/// cap, so it always sees a single-propose seq.
pub fn proposeMulti(worker: anytype, gid: u64, inner: []const []const u8) !Proposed {
    if (inner.len == 0) return .{};
    const allocator = worker.allocator;
    const CHUNK: usize = 255;
    var seq: u64 = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const end = chunkEnd(inner, i, CHUNK);
        const slice = inner[i..end];
        // The whole multi (anchor writeset + any same-batch side
        // writes) replicates through the ANCHOR tenant's group. The
        // cross-tenant trampoline (target tenants + root in one multi)
        // is an admin/control-plane path off the single-tenant slice;
        // the directory routes those per-target.
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

/// Where the chunk starting at `from` has to stop: at `max_count` inners (the
/// multi wire format's u8 count), or at the point where the encoded chunk would
/// no longer fit ONE raft entry (`MAX_ENTRY_BYTES`) — whichever comes first.
///
/// Counting was the only bound before, and count does not bound bytes: 255
/// inners of a few KB each build an entry no follower can receive, with no
/// single large value anywhere in sight. The batch exists to amortise raft
/// entries, so spilling into a second entry is exactly the right answer;
/// what must never happen is one entry that cannot be sent.
///
/// Always returns at least `from + 1`: a single inner that does not fit cannot
/// be split here, and `Bridge.propose` refuses it with `EntryTooLarge` so the
/// caller gets a defined error instead of a silent drop.
fn chunkEnd(inner: []const []const u8, from: usize, max_count: usize) usize {
    var total: usize = sizing.MULTI_HDR_BYTES;
    var end = from;
    while (end < inner.len and end - from < max_count) {
        const next = total + sizing.MULTI_INNER_HDR_BYTES + inner[end].len;
        if (end > from and next > bridge_mod.transport.MAX_ENTRY_BYTES) break;
        total = next;
        end += 1;
    }
    return @max(end, from + 1);
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
    // contiguous and early (anchor at inner[0], then the side
    // writes) so the atomic-critical set lands in the first
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
    // The admin handler's cross-tenant trampoline writes (per target,
    // type-0 with the target id) and `platform.root.*` writes (type-2)
    // ride the SAME multi-envelope → one raft seq the calling admin
    // request is parked on by finalizeBatch (the proposer invariant,
    // docs/architecture/consensus-robustness.md). `apply` routes each inner to its per-target store;
    // the inners share one raft entry (atomic replication), but each
    // commits its own kvexp txn — apply is not cross-inner
    // transactional, so recovery is via idempotent replay, not
    // rollback.
    //
    // Target envelopes carry empty rs_bytes — the readset
    // lives on the anchor envelope (inner[0]) above; one readset
    // per dispatch, not per envelope.
    for (worker.batch_side.targets.items) |*t| {
        if (t.ws.ops.items.len == 0) continue;
        const tb = try t.ws.encode(allocator);
        defer allocator.free(tb);
        try inner.append(allocator, try apply_mod.encodeWriteSetEnvelope(allocator, t.id, tb, ""));
    }
    return proposeMulti(worker, gid, inner.items);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "proposeMulti chunking: bytes bound the batch, not just the count" {
    const LIMIT = bridge_mod.transport.MAX_ENTRY_BYTES;

    // 255 inners of 8 KB each is a legal COUNT and an illegal ENTRY: ~2 MB,
    // which no follower can receive. Count was the only bound before, so this
    // is the batch that built an undeliverable entry with no large value
    // anywhere in it.
    var inners: [255][]const u8 = undefined;
    const chunk = "x" ** (8 * 1024);
    for (&inners) |*e| e.* = chunk;

    var from: usize = 0;
    var entries: usize = 0;
    while (from < inners.len) {
        const end = chunkEnd(&inners, from, 255);
        try testing.expect(end > from); // always makes progress
        // Every chunk fits one entry.
        var total: usize = 4;
        for (inners[from..end]) |e| total += 4 + e.len;
        try testing.expect(total <= LIMIT);
        from = end;
        entries += 1;
    }
    // It spilled rather than building one oversize entry.
    try testing.expect(entries > 1);
}

test "proposeMulti chunking: a single inner that cannot fit still advances" {
    // One inner larger than an entry cannot be split here — the chunk is that
    // inner alone, and `Bridge.propose` refuses it with EntryTooLarge so the
    // caller gets a defined error. Returning `from` would spin forever.
    const big = "y" ** 64;
    var inners = [_][]const u8{big};
    try testing.expectEqual(@as(usize, 1), chunkEnd(&inners, 0, 255));
}

test "proposeMulti chunking: the ordinary batch is untouched" {
    // A handful of small envelopes still rides ONE entry — the batching win
    // (fewer raft entries per dispatch pass) is the reason this exists.
    var inners = [_][]const u8{ "a" ** 128, "b" ** 128, "c" ** 128 };
    try testing.expectEqual(@as(usize, 3), chunkEnd(&inners, 0, 255));
}
