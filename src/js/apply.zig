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
const tape_mod = @import("rove-tape");
const panic_mod = @import("panic.zig");
const deployment_loader_mod = @import("deployment_loader.zig");
const worker_mod = @import("worker.zig");

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

/// Loop46-specific apply state — auxiliary fields the library's
/// `kv.Cluster` doesn't know about. The cluster handles raft + per-
/// store cache + global_apply_idx + root_store; this struct carries
/// what's left over:
///
///   - `schedules_store` — singleton `schedules.db` handle. Custom
///     ScheduleStore type wraps a KvStore with typed queries; can't
///     route through `cluster.openStore` which returns raw `*KvStore`.
///   - Scheduler-wake signals (`schedule_wake`, `worker_phase_wake`)
///     for the libcurl scheduler thread and the worker-phase dispatch
///     loop respectively.
///   - `public_suffix` for `is_internal` tenant detection at
///     `applyScheduleUpsertBatch` time.
///   - `deployment_loader` for the follower-side `_deploy/current`
///     post-write hook in `applyWriteSet`.
///
/// Stash a pointer to this in `Cluster.Config.user_ctx`; handlers
/// cast back via `loop46Ctx(user_ctx)`.
pub const Loop46Ctx = struct {
    allocator: std.mem.Allocator,
    worker_phase_wake: ?*std.Thread.ResetEvent = null,
    public_suffix: ?[]const u8 = null,
    deployment_loader: ?*deployment_loader_mod.DeploymentLoader = null,
    /// streaming-handlers-plan §4.6: pointer to the process-wide
    /// `NodeState` so `applyWriteSet` can broadcast kv-write events
    /// to every worker's `KvWakeInbox` after a follower-side apply.
    /// Borrowed; null on test paths that don't run the full worker
    /// stack. Type-erased to `*anyopaque` because `NodeState` is
    /// inside the rove-js module and apply.zig is part of the same
    /// module — the cast is local.
    node_state: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Loop46Ctx {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Loop46Ctx) void {
        // `schedules_store` is owned by the caller (main.zig opens it
        // once and threads the pointer in). We just borrow.
        _ = self;
    }

};

fn loop46Ctx(user_ctx: ?*anyopaque) *Loop46Ctx {
    return @ptrCast(@alignCast(user_ctx orelse panic_mod.invariantViolated(
        "apply: missing user_ctx",
        "expected *Loop46Ctx",
        .{},
    )));
}

// ── Envelope handlers (library `ApplyFn` signature) ──────────────────
//
// Each handler is registered via `cluster.registerEnvelope(type, ...)`
// in loop46/main.zig. The library handles the global apply filter,
// envelope decode, leader_skip check, and multi-envelope unwrap; these
// handlers only see envelopes their type was registered for. The
// returned `ApplyError` (rare — these handlers panic on most errors)
// surfaces back to library which panics at `applyCallback`. Hot path
// is panic-free; errors here are invariant violations.

/// Per-tenant writeset (envelope type=0). Registered with
/// `leader_skip = true` — the worker already wrote locally via its
/// own TrackedTxn before proposing, so this only runs on followers.
/// Library attaches a store handle for `env.id` (hashed via
/// `kvstore.hashStoreId`) inside the cluster's node-wide kvexp
/// manifest at `{data_dir}/cluster.kv`.
pub fn applyWriteSet(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;

    const store = cluster.openStore(env.id) catch |err| switch (err) {
        error.OutOfMemory => return kv.ClusterApplyError.OutOfMemory,
        else => return kv.ClusterApplyError.Sqlite,
    };

    // Phase 3 (`docs/readset-replication-plan.md`): the type-0
    // payload now carries `[u32 ws_len][ws][u32 rs_len][rs]`. The
    // `rs_bytes` section is a `tape_mod.encodeReadsetList` blob
    // (one or more readsets — multi-readset aggregation lifted the
    // "first only" limitation from slice 3d). Extract the writeset
    // half + validate the readset list shape. Phase 5 will materialize
    // tapes from each list entry for follower tape upload; for now
    // followers just verify the wire shape and discard.
    const payload = decodeWriteSetPayload(env.payload) catch |err| panic_mod.invariantViolated(
        "applyWriteSet.decodeWriteSetPayload",
        "tenant={s} err={s}",
        .{ env.id, @errorName(err) },
    );
    if (payload.rs_bytes.len > 0) {
        var parsed_list = tape_mod.parseReadsetList(cluster.allocator, payload.rs_bytes) catch |err| panic_mod.invariantViolated(
            "applyWriteSet.parseReadsetList",
            "tenant={s} rs_len={d} err={s}",
            .{ env.id, payload.rs_bytes.len, @errorName(err) },
        );
        defer parsed_list.deinit(cluster.allocator);
        for (parsed_list.blobs, 0..) |blob, i| {
            _ = tape_mod.parseReadset(blob) catch |err| panic_mod.invariantViolated(
                "applyWriteSet.parseReadset[i]",
                "tenant={s} i={d} blob_len={d} err={s}",
                .{ env.id, i, blob.len, @errorName(err) },
            );
        }
    }

    kv.applyEncodedWriteSet(store, 0, payload.ws_bytes) catch |err| panic_mod.invariantViolated(
        "applyWriteSet.applyEncodedWriteSet",
        "tenant={s} err={s}",
        .{ env.id, @errorName(err) },
    );

    // Follower-side release propagation: if this writeset stamped
    // `_deploy/current`, the leader just published a new release for
    // this tenant. Enqueue the deployment loader so the follower's
    // worker has the new bytecode ready when traffic arrives. The
    // payload is `{N:0>16}` hex (16 chars); anything else is a
    // pre-existing kv write happening to use the same key (shouldn't
    // happen but we tolerate it by silently ignoring).
    const ctx = loop46Ctx(user_ctx);

    // Phase 5 PR-3: the `_send/owed/*` apply-time classifier hook is
    // GONE. webhook.send (the JS-shim composition) writes the marker
    // as an ordinary envelope-0 kv put; the per-worker partitioned
    // sweep (`sweepOwedRetries` — leader-local) picks it up
    // post-commit. No Zig-side SendDispatch arming, no follower
    // feed for an in-flight set. Cross-failover recovery comes from
    // `sweepOwedRetriesOnPromotion` running on the new leader.

    if (ctx.deployment_loader) |loader| {
        if (kv.scanWriteSetPutValue(payload.ws_bytes, "_deploy/current")) |hex_bytes| {
            const dep_id = std.fmt.parseInt(u64, hex_bytes, 16) catch return;
            loader.enqueue(env.id, dep_id) catch |err| std.log.warn(
                "applyWriteSet: deployment loader enqueue {s}/{d} failed: {s}",
                .{ env.id, dep_id, @errorName(err) },
            );
        }
    }

    // streaming-handlers-plan §4.6: kv-write wake fan-out (follower
    // path). Decode the just-applied writeset's ops and broadcast
    // each `put`/`delete` to every worker's `KvWakeInbox`. The
    // worker's tick drain scans its stream-pipeline collections for
    // prefix matches and pushes a `WakeEntry` onto the §9.4
    // `pending_wakes` ring; the next `serviceParkedStreams` pass
    // fires `resumeStream(.wake_batch)` which drains the ring.
    // Best-effort: a per-event decode/push failure logs and we
    // continue — §9.4 "spurious + overflow" allows dropped wakes
    // (handler refetches authoritative state on its next run when
    // `lost_oldest > 0`).
    //
    // The leader-skipped property of `applyWriteSet` means this
    // hook only fires on followers; the leader-side mirror lives
    // in `worker_dispatch.zig`'s `finalizeBatch` (eager-fire on
    // local commit). Both paths broadcast to the SAME registry, so
    // single-node deployments and cross-node deployments converge
    // on identical wake semantics.
    if (ctx.node_state) |opaque_node| {
        var ops: std.ArrayListUnmanaged(kv.WriteSetOp) = .empty;
        defer ops.deinit(ctx.allocator);
        kv.decodeWriteSetOps(payload.ws_bytes, ctx.allocator, &ops) catch |derr| {
            std.log.warn(
                "applyWriteSet: kv-wake decode tenant={s}: {s}; skipping wake fan-out",
                .{ env.id, @errorName(derr) },
            );
            return;
        };
        const ns: *worker_mod.NodeState = @ptrCast(@alignCast(opaque_node));
        // §8.4 watch baseline: this writeset just landed via
        // `applyEncodedWriteSet`, so the follower store's write clock now
        // reflects it. Read it once and stamp every op's wake event;
        // `maxInt` (contended lease) fires-always rather than dropping a
        // wake.
        const wv: u64 = store.writeVersion() orelse std.math.maxInt(u64);
        var fired: usize = 0;
        for (ops.items) |op| switch (op) {
            .put => |p| {
                ns.router.broadcastKvWake(env.id, p.key, 'p', wv);
                fired += 1;
            },
            .delete => |d| {
                ns.router.broadcastKvWake(env.id, d.key, 'd', wv);
                fired += 1;
            },
        };
        if (fired > 0) {
            std.log.info(
                "rove-js kv-wake apply: tenant={s} fanned out {d} op(s) on follower",
                .{ env.id, fired },
            );
        }
    }
}

/// Root writeset (envelope type=2). Registered with
/// `leader_skip = true` — same model as the per-tenant writeset: the
/// worker (signup / admin handler `platform.root.*`) wrote to
/// `__root__.db` locally before proposing, so this only runs on
/// followers. Library opens via `cluster.openRoot()`.
pub fn applyRootWriteSet(
    cluster: *kv.Cluster,
    env: kv.Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) kv.ClusterApplyError!void {
    _ = entry_idx;
    _ = inside_multi;
    _ = user_ctx;
    std.debug.assert(env.id.len == 0);

    const store = cluster.openRoot() catch |err| switch (err) {
        error.OutOfMemory => return kv.ClusterApplyError.OutOfMemory,
        else => return kv.ClusterApplyError.Sqlite,
    };

    kv.applyEncodedWriteSet(store, 0, env.payload) catch |err| panic_mod.invariantViolated(
        "applyRootWriteSet.applyEncodedWriteSet",
        "err={s}",
        .{@errorName(err)},
    );
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

