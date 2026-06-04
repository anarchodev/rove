//! Apply callback for the worker's raft state machine.
//!
//! ## Wire format
//!
//! Every envelope the worker proposes is:
//!
//!   `[1B type][2B id_len BE][id bytes][payload]`
//!
//! `type=0` → per-tenant writeset (payload is `WriteSet.encode` bytes,
//!           target store = `{data_dir}/{id}/app.db`)
//! `type=1` → multi-envelope wrapper — bundles N inner writeset
//!           envelopes into one raft entry; each inner envelope
//!           applies in order against its own target (see
//!           `EnvelopeType.multi`)
//! `type=2` → ROOT writeset (payload is `WriteSet.encode` bytes,
//!           target store = `{data_dir}/__root__.db`, id_len must
//!           be 0 — the envelope carries no per-tenant id)
//!
//! `log_batch` (originally type 1) and `files_writeset` (type 3) were
//! retired in Phase 5.5 (a) and 5.5 (e) F2-storage respectively; type
//! 1 was later reused for `multi`. Log records flow worker → S3
//! (sidecar + ndjson) directly; per-tenant manifests live in a
//! per-tenant `deployments/` BlobBackend, with the runtime release
//! pointer riding envelope 0 in the customer's own app.db. The decoder
//! rejects every retired type byte as `UnknownEnvelopeType` so any
//! stale entry in an old raft log surfaces loudly instead of silently
//! mis-applying — the full retired-slot list lives on `EnvelopeType`.
//!
//! The `id` is the tenant `instance_id`. `id_len` caps at 64KB. The
//! trailing `payload` is whatever the dispatch callback for that
//! type knows how to decode.
//!
//! ## Dispatch by type
//!
//! - **type=0 writeset**: leader-skips (because the worker's open
//!   `TrackedTxn` already wrote locally), follower replays through
//!   `kv.applyEncodedWriteSet` against the apply context's own
//!   per-tenant kv store.
//!
//! ## Threading model — strict isolation from worker state
//!
//! `applyOne` runs on the raft thread. It must NOT reach into any
//! worker's per-tenant state — doing so would share NOMUTEX sqlite
//! connections between the raft thread and worker threads, which is
//! undefined behavior per sqlite's threading docs.
//!
//! Instead, `ApplyCtx` owns ITS OWN per-tenant store map (`kv_stores`),
//! opened lazily on first apply for each tenant. These connections
//! are raft-thread-local and never touched by any worker. They point
//! at the same sqlite files the workers use, but via independent
//! connections — WAL mode handles the coexistence.
//!
//! On the leader, the writeset apply short-circuits via the
//! leader-skip, so the raft-thread-owned connections stay idle. Cost
//! of an idle cached connection is a pair of fds per tenant;
//! acceptable.
//!
//! On followers, the raft thread is the only thread that writes
//! tenant state, so there is no contention to coordinate with.

const std = @import("std");
const kv = @import("raft-kv");
// V2 Phase 2c: the V1 follower apply-fns (`applyWriteSet` /
// `applyRootWriteSet`) + `Loop46Ctx` were deleted — apply now happens in
// the V2 bridge/node (leader-skip on a single node), so this file is just
// the envelope codec the worker uses to encode proposes. The codec
// symbols resolve through the spine-free facade (`raft-kv` → kvlimbs).

pub const Error = error{
    Truncated,
    UnknownInstance,
    UnknownEnvelopeType,
    ApplyFailed,
    NestedMulti,
};

/// Single-sourced from the shared cluster codec.
pub const MAX_ID_LEN: usize = kv.MAX_ID_LEN;

pub const EnvelopeType = enum(u8) {
    writeset = 0,
    /// Phase 5.5 (d) — multi-envelope wrapper. Payload is
    /// `[u8 count][u32 inner_len][inner_envelope_bytes]{count}` where
    /// each inner envelope is a complete `[type][id_len][id][payload]`
    /// blob. Inner envelopes apply in order; nesting (a `multi` inside
    /// a `multi`) panics. The standard envelope `instance_id` is empty
    /// for type=1 — per-inner-envelope ids carry the real targets.
    /// Numbered to match `kv.cluster.ENVELOPE_TYPE_MULTI` for the
    /// migration toward the shared Cluster library (raft-kv-design.md
    /// step 4). The previous value (7) is retired with the rest of
    /// the pre-migration types below.
    multi = 1,
    root_writeset = 2,
    // RETIRED SLOTS (not enum variants ⇒ `decodeEnvelope` rejects
    // them as `UnknownEnvelopeType`, so any stale raft-log entry
    // trips the apply panic at startup instead of silently
    // mis-applying — deliberate; every migration window predates 1.0):
    //   3        files_writeset (Phase 5.5(e) F2-storage; manifests
    //            now in a per-tenant deployments/ BlobBackend,
    //            `_deploy/current` rides envelope 0).
    //   4/5/6    webhook_{enqueue_batch,complete,retry_schedule}
    //            (rove-webhook-server retired; webhook.send is a JS
    //            polyfill over http.send).
    //   7        old `multi` pre-renumber (now type 1).
    //   8/9/10/11 schedule_{upsert,complete,cancel,demote} — RETIRED
    //            Option (b) 5b-2: the central schedule subsystem is
    //            dissolved; webhook.send (effect-reification-plan.md
    //            Phase 5 PR-3) composes durability in JS on top of
    //            kv.set + http.fetch + the per-worker partitioned
    //            retry sweep — see `globals/webhook.js`. No
    //            schedules.db, no leader-pinned schedule-server
    //            thread, no env-9 callback rows, and no Zig-side
    //            SendDispatch kernel either (PR-3 deleted it).
};

/// Type-0 envelope payload layout
/// (`docs/readset-replication-plan.md` Phase 3). The original layout
/// was just the writeset bytes; the extended layout interleaves the
/// writeset with the request's serialized readset so the tape can
/// be reconstructed on any follower that ever applies this entry.
///
/// Wire format:
///   `[u32 LE ws_len][ws_bytes][u32 LE rs_len][rs_bytes]`
///
/// `rs_len == 0` is valid + frequent — non-handler producers (ACME,
/// background trampolines) and the secondary inner envelopes of a
/// batched propose carry an empty readset section. The anchor
/// envelope in a batch carries the dispatch's readset; targets and
/// root_writeset in the same batch carry empty (the readset is
/// per-dispatch, not per-envelope).
pub const WriteSetPayload = struct {
    /// Borrowed slice into the input payload — the writeset bytes.
    ws_bytes: []const u8,
    /// Borrowed slice into the input payload — the readset list bytes
    /// (empty for non-handler producers). When non-empty, the bytes
    /// are a `tape_mod.encodeReadsetList` blob containing one or more
    /// `Readset.serialize` entries (one per successful request in the
    /// batched dispatch that produced this envelope);
    /// `tape_mod.parseReadsetList` validates the outer shape, and
    /// `tape_mod.parseReadset` validates each per-readset blob.
    rs_bytes: []const u8,
};

pub fn decodeWriteSetPayload(payload: []const u8) Error!WriteSetPayload {
    if (payload.len < 4) return Error.Truncated;
    const ws_len = std.mem.readInt(u32, payload[0..4], .little);
    if (payload.len < 4 + ws_len + 4) return Error.Truncated;
    const ws_bytes = payload[4 .. 4 + ws_len];
    const rs_len = std.mem.readInt(u32, payload[4 + ws_len ..][0..4], .little);
    const rs_start: usize = 4 + ws_len + 4;
    if (payload.len != rs_start + rs_len) return Error.Truncated;
    return .{
        .ws_bytes = ws_bytes,
        .rs_bytes = payload[rs_start .. rs_start + rs_len],
    };
}

pub fn encodeWriteSetPayload(
    allocator: std.mem.Allocator,
    ws_bytes: []const u8,
    rs_bytes: []const u8,
) ![]u8 {
    const total = 4 + ws_bytes.len + 4 + rs_bytes.len;
    const out = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(ws_bytes.len), .little);
    @memcpy(out[4..][0..ws_bytes.len], ws_bytes);
    std.mem.writeInt(u32, out[4 + ws_bytes.len ..][0..4], @intCast(rs_bytes.len), .little);
    @memcpy(out[4 + ws_bytes.len + 4 ..][0..rs_bytes.len], rs_bytes);
    return out;
}

/// Build a type-0 writeset envelope. `id_len` and `id` plus a leading
/// type=0 byte; payload is `encodeWriteSetPayload(ws_bytes, rs_bytes)`.
/// Pass `rs_bytes == ""` for non-handler producers (ACME, secondary
/// inner envelopes of a batched propose).
pub fn encodeWriteSetEnvelope(
    allocator: std.mem.Allocator,
    id: []const u8,
    ws_bytes: []const u8,
    rs_bytes: []const u8,
) ![]u8 {
    const payload = try encodeWriteSetPayload(allocator, ws_bytes, rs_bytes);
    defer allocator.free(payload);
    return encodeTyped(allocator, .writeset, id, payload);
}

/// Build a root writeset envelope. type=2, no per-tenant id (id_len=0).
/// Applied to `{data_dir}/__root__.db` on followers. Used for writes
/// that update platform-level tables (tenant registry, domain
/// mappings) — signup's `tenant.createInstance` and the admin JS
/// handler's `platform.root.set/delete` collect their ops here.
///
/// Type 2 stays writeset-only — its producers include non-handler
/// flows (ACME cert renewal in `acme.zig`) that have no readset to
/// attach. The handler-originated producers (signup, admin
/// `platform.root.*`) ride alongside type-0 envelopes in a batched
/// propose, and the readset lives on the anchor type-0 of the same
/// batch — same dispatch, same readset.
pub fn encodeRootWriteSetEnvelope(
    allocator: std.mem.Allocator,
    ws_bytes: []const u8,
) ![]u8 {
    return encodeTyped(allocator, .root_writeset, "", ws_bytes);
}


/// Build a multi-envelope wrapper (type=1) carrying `inner` as already-
/// encoded inner envelopes. The wrapper's `instance_id` is empty;
/// real targets live on each inner envelope's id.
///
/// Inner envelopes must NOT themselves be type=1. The apply path
/// panics on nested multi to keep the recursion bounded.
///
/// Thin wrapper over the shared `kv.encodeMulti` codec — the
/// `[1B type=1][2B id_len=0][u8 count]([u32 len][inner]){count}` byte
/// layout lives once in `kv/cluster.zig`.
pub fn encodeMultiEnvelope(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) ![]u8 {
    return kv.encodeMulti(allocator, inner);
}

/// Decode the inner-envelope byte slices from a type=1 wrapper's
/// payload (i.e., `Envelope.payload` for an envelope whose type is
/// `multi`). Returned slices alias the caller's payload buffer; do
/// not free individually. Caller frees the outer slice with
/// `allocator.free`.
///
/// Thin wrapper over the shared `kv.decodeMultiInner` codec.
pub fn decodeMultiInner(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![][]const u8 {
    return kv.decodeMultiInner(allocator, payload);
}

fn encodeTyped(
    allocator: std.mem.Allocator,
    t: EnvelopeType,
    id: []const u8,
    payload: []const u8,
) ![]u8 {
    // Thin wrapper over the shared `kv.encodeEnvelope` header codec;
    // the `[1B type][2B id_len BE][id][payload]` layout (and the
    // `id.len > MAX_ID_LEN` guard) live once in `kv/cluster.zig`.
    return kv.encodeEnvelope(allocator, @intFromEnum(t), id, payload);
}

pub const Envelope = struct {
    type: EnvelopeType,
    instance_id: []const u8,
    payload: []const u8,
};

/// Decode an envelope into the enum-typed loop46 view. Slices into the
/// input buffer; valid until the caller drops `payload`.
///
/// Thin wrapper over the shared `kv.decodeEnvelope` header codec: the
/// raw `u8` type is mapped to `EnvelopeType`, so any stale retired-type
/// byte trips `UnknownEnvelopeType` here (the propose / upload-walker /
/// test side). NB: the *live* apply path decodes through
/// `kv.decodeEnvelope` directly inside the cluster — the retired-type
/// guard for that path lives there (see the cluster's handler table).
pub fn decodeEnvelope(payload: []const u8) Error!Envelope {
    const raw = kv.decodeEnvelope(payload) catch return Error.Truncated;
    const t = std.meta.intToEnum(EnvelopeType, raw.type) catch
        return Error.UnknownEnvelopeType;
    return .{
        .type = t,
        .instance_id = raw.id,
        .payload = raw.payload,
    };
}

/// Visit every writeset (type-0) envelope in a committed raft-log
/// entry, whether top-level or unwrapped from a multi (type-1).
/// Root-writeset (type-2) envelopes carry no per-tenant readset and
/// are skipped, as is an (illegal) nested multi. A decode failure on
/// the outer entry or the multi payload aborts quietly — callers treat
/// a corrupt / foreign entry as "nothing to extract"; a bad inner
/// envelope is skipped.
///
/// `ctx` is any value exposing
/// `fn visitWriteSet(self, instance_id: []const u8, payload: []const u8) !void`.
/// The slices alias `entry_bytes` / the decoded multi buffer and are
/// valid only for the duration of the call. This is the single owner
/// of the read-only envelope-tree shape; `Cluster.applyOne` /
/// `applyMulti` is the write-side twin.
pub fn forEachWriteSetEnvelope(
    allocator: std.mem.Allocator,
    entry_bytes: []const u8,
    ctx: anytype,
) !void {
    const env = decodeEnvelope(entry_bytes) catch return;
    switch (env.type) {
        .writeset => try ctx.visitWriteSet(env.instance_id, env.payload),
        .multi => {
            const inner_slice = decodeMultiInner(allocator, env.payload) catch return;
            defer allocator.free(inner_slice);
            for (inner_slice) |inner_bytes| {
                const inner_env = decodeEnvelope(inner_bytes) catch continue;
                if (inner_env.type == .writeset)
                    try ctx.visitWriteSet(inner_env.instance_id, inner_env.payload);
                // nested multi + root_writeset carry no readset: skip.
            }
        },
        .root_writeset => {},
    }
}


// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeset envelope encode/decode round trip (empty readset)" {
    const id = "acme";
    const ws = "ws bytes here";
    const enc = try encodeWriteSetEnvelope(testing.allocator, id, ws, "");
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.writeset, dec.type);
    try testing.expectEqualStrings(id, dec.instance_id);

    const payload = try decodeWriteSetPayload(dec.payload);
    try testing.expectEqualStrings(ws, payload.ws_bytes);
    try testing.expectEqual(@as(usize, 0), payload.rs_bytes.len);
}

test "writeset envelope encode/decode round trip (with readset)" {
    const id = "acme";
    const ws = "ws bytes here";
    const rs = "fake readset blob";
    const enc = try encodeWriteSetEnvelope(testing.allocator, id, ws, rs);
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    const payload = try decodeWriteSetPayload(dec.payload);
    try testing.expectEqualStrings(ws, payload.ws_bytes);
    try testing.expectEqualStrings(rs, payload.rs_bytes);
}

test "root writeset envelope encode/decode round trip" {
    const ws = "root ws bytes";
    const enc = try encodeRootWriteSetEnvelope(testing.allocator, ws);
    defer testing.allocator.free(enc);

    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.root_writeset, dec.type);
    try testing.expectEqualStrings("", dec.instance_id);
    try testing.expectEqualStrings(ws, dec.payload);
}

test "decodeEnvelope rejects truncated input" {
    try testing.expectError(Error.Truncated, decodeEnvelope(""));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{0x00}));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{ 0x00, 0x00 }));
    // type=0, id_len=5 but no id bytes
    try testing.expectError(
        Error.Truncated,
        decodeEnvelope(&[_]u8{ 0x00, 0x00, 0x05 }),
    );
}

test "decodeEnvelope rejects unknown type" {
    try testing.expectError(
        Error.UnknownEnvelopeType,
        decodeEnvelope(&[_]u8{ 0xFF, 0x00, 0x00 }),
    );
}

test "decodeEnvelope handles empty payload (empty ws + empty rs)" {
    const enc = try encodeWriteSetEnvelope(testing.allocator, "x", "", "");
    defer testing.allocator.free(enc);
    const dec = try decodeEnvelope(enc);
    try testing.expectEqual(EnvelopeType.writeset, dec.type);
    try testing.expectEqualStrings("x", dec.instance_id);
    // payload is now `[u32 ws_len=0][u32 rs_len=0]` = 8 bytes.
    try testing.expectEqual(@as(usize, 8), dec.payload.len);
    const p = try decodeWriteSetPayload(dec.payload);
    try testing.expectEqual(@as(usize, 0), p.ws_bytes.len);
    try testing.expectEqual(@as(usize, 0), p.rs_bytes.len);
}

test "multi envelope wraps + unwraps several inner envelopes" {
    const a = testing.allocator;
    const inner_ws = try encodeWriteSetEnvelope(a, "acme", "ws bytes", "");
    defer a.free(inner_ws);
    const inner_root = try encodeRootWriteSetEnvelope(a, "root bytes");
    defer a.free(inner_root);

    const wrapped = try encodeMultiEnvelope(a, &.{ inner_ws, inner_root });
    defer a.free(wrapped);

    const outer = try decodeEnvelope(wrapped);
    try testing.expectEqual(EnvelopeType.multi, outer.type);
    try testing.expectEqualStrings("", outer.instance_id);

    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 2), inner.len);

    const e0 = try decodeEnvelope(inner[0]);
    try testing.expectEqual(EnvelopeType.writeset, e0.type);
    try testing.expectEqualStrings("acme", e0.instance_id);
    const p0 = try decodeWriteSetPayload(e0.payload);
    try testing.expectEqualStrings("ws bytes", p0.ws_bytes);
    try testing.expectEqual(@as(usize, 0), p0.rs_bytes.len);

    const e1 = try decodeEnvelope(inner[1]);
    try testing.expectEqual(EnvelopeType.root_writeset, e1.type);
    try testing.expectEqualStrings("", e1.instance_id);
    try testing.expectEqualStrings("root bytes", e1.payload);
}

test "multi envelope with empty inner list" {
    const a = testing.allocator;
    const wrapped = try encodeMultiEnvelope(a, &.{});
    defer a.free(wrapped);
    const outer = try decodeEnvelope(wrapped);
    try testing.expectEqual(EnvelopeType.multi, outer.type);
    const inner = try decodeMultiInner(a, outer.payload);
    defer a.free(inner);
    try testing.expectEqual(@as(usize, 0), inner.len);
}

test "decodeMultiInner rejects truncated payload" {
    const a = testing.allocator;
    try testing.expectError(Error.Truncated, decodeMultiInner(a, ""));
    // count=1 but no length prefix
    try testing.expectError(Error.Truncated, decodeMultiInner(a, &[_]u8{1}));
    // count=1, length=10 but only 4 bytes follow
    try testing.expectError(
        Error.Truncated,
        decodeMultiInner(a, &[_]u8{ 1, 10, 0, 0, 0, 'a', 'b', 'c', 'd' }),
    );
}

