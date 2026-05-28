//! Streaming-resume engine + Msg-driven activation firers.
//!
//! Despite the file name, this covers the broader post-commit /
//! Msg-ingress machinery — the original "Streaming-handlers Phase 2b-ii"
//! section in `worker.zig` had grown beyond streaming proper to include
//! every fire*Activation entry point and the Msg-queue dispatch:
//!
//!   - Stream lifecycle: `markStreamDraining`, `setStreamComponents`,
//!     `serviceParkedStreams`, `drainKvWakeInbox`, `matchEventsToWakes`,
//!     `resumeStream` — the wake → resume → ship-chunks loop.
//!   - Activation firers: `fireDisconnectActivation`,
//!     `fireSubscriptionActivation`, `fireChainedActivation` —
//!     synchronous handler invocations from a Msg (no held socket).
//!     `fireFetchEventActivation` stays in `worker.zig` under its
//!     "Gap 2.3 http.fetch" section; the four are near-duplicate
//!     today and collapse together in Phase 4.1.
//!   - Commit-gated buffer: `StreamResumeStage`, `proposeForgetfulWrites`,
//!     `transferStagedChunks`, `firePendingKvWakes`,
//!     `fireKvReactSubscriptions` — the parked-unit commit-arm runtime
//!     `drainRaftPending` invokes for each unit when its raft seq lands.
//!   - Msg ingress + dispatch: `drainMsgInbox`,
//!     `serviceSubscriptionFires`, `dispatchPendingMsgs` (+ two
//!     back-compat aliases) — cross-thread inbox drain → in-thread queue
//!     drain → per-variant fire.
//!
//! Every function takes `worker: anytype` so the structural-typed
//! access to Worker's fields keeps working without forcing this file
//! to depend on the comptime Worker type. Same shape as
//! `worker_dispatch.zig` / `worker_log.zig`.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("raft-kv");
const log_mod = @import("rove-log");
const tape_mod = @import("rove-tape");

const dispatcher_mod = @import("dispatcher.zig");
const Request = dispatcher_mod.Request;
const components_mod = @import("components.zig");
const effect_mod = @import("effect/root.zig");
const raft_propose = @import("raft_propose.zig");
const panic_mod = @import("panic.zig");
const builtin_modules_mod = @import("builtin_modules.zig");

const worker_mod = @import("worker.zig");
const worker_drain = @import("worker_drain.zig");
const ParkedUnit = worker_mod.ParkedUnit;
const KvWakeOp = worker_mod.KvWakeOp;
const KvWakeEvent = worker_mod.KvWakeEvent;
const MAX_STREAM_ACTIVATIONS = worker_mod.MAX_STREAM_ACTIVATIONS;
const captureLogWithId = worker_mod.captureLogWithId;
const resolveDeployment = worker_mod.resolveDeployment;

// ── Stream lifecycle ──────────────────────────────────────────────────

/// Phase 7: flag the stream's draining state via the entity's
/// StreamDraining component. Replaces Phase 6's
/// `moveStreamCellToDraining` (active/draining-map flip). Tolerant
/// to "entity not in stream_data_out" because the resumeStream error
/// branches call this defensively after error logging — if the
/// component fetch fails, the entity was never a stream anyway.
fn markStreamDraining(server: anytype, ent: rove.Entity) void {
    const drain_ptr = server.reg.get(ent, &server.stream_data_out, components_mod.StreamDraining) catch return;
    drain_ptr.is_draining = true;
}

/// Like `markStreamDraining` but tries `stream_response_in` first
/// (where bound-fetch streams briefly live post-commit, before h2
/// moves them to stream_data_out — see `resumeBoundFetchStream`'s
/// dual-collection support). Falls through to stream_data_out for
/// the steady-state case. Same defensive posture: if neither
/// matches, the entity isn't a live stream — silent no-op.
fn markStreamDrainingAnywhere(server: anytype, ent: rove.Entity) void {
    if (server.reg.get(ent, &server.stream_response_in, components_mod.StreamDraining)) |dp| {
        dp.is_draining = true;
        return;
    } else |_| {}
    if (server.reg.get(ent, &server.stream_data_out, components_mod.StreamDraining)) |dp| {
        dp.is_draining = true;
        return;
    } else |_| {}
}

/// Handler-cmds Phase 3: populate the four stream-side components on
/// the entity. After Phase 7, this is the SOLE site that allocates
/// the stream-chain slices; ownership stays on the components for
/// the chain's lifetime.
///
/// `current_coll` must be the collection the entity is in NOW (the
/// caller is about to move it into the stream pipeline; the
/// components ride along via `merged_request_row`). Inputs are
/// borrowed — every slice gets duped for the component-side owners.
pub fn setStreamComponents(
    server: anytype,
    current_coll: anytype,
    ent: rove.Entity,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    correlation_id: ?[]const u8,
    deployment_id: u64,
    module_path: []const u8,
    ctx_json: []const u8,
    initial_chunks: []const []const u8,
    kv_prefixes: []const []const u8,
    interval_ms: i64,
) !void {
    // Each block builds clones for one component then transfers
    // ownership via `reg.set`. The errdefer inside each block fires
    // only if a try BEFORE the set fails; once we exit the block,
    // ownership is the component's. If a LATER block's reg.set
    // fails, the earlier components stay set on the entity — when
    // the caller destroys the entity (or it survives into a
    // collection that doesn't carry the components), the
    // structural deinit runs and frees them. No double-free, no
    // leak.

    {
        const tid = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tid);
        const corr: ?[]u8 = if (correlation_id) |c| try allocator.dupe(u8, c) else null;
        errdefer if (corr) |c| allocator.free(c);
        try server.reg.set(ent, current_coll, components_mod.ChainContext, .{
            .tenant_id = tid,
            .correlation_id = corr,
            .deployment_id = deployment_id,
        });
    }

    {
        const mp = try allocator.dupe(u8, module_path);
        errdefer allocator.free(mp);
        const cj = try allocator.dupe(u8, ctx_json);
        errdefer allocator.free(cj);
        try server.reg.set(ent, current_coll, components_mod.StreamChain, .{
            .module_path = mp,
            .ctx_json = cj,
            .activation_count = 1,
        });
    }

    {
        // Stage chunks through a temporary StreamChunks so the §9.4
        // cap check + dropped_chunks counter applies on the first
        // hop too. The component is then `reg.set` onto the entity
        // (rove takes ownership of the queue+counters).
        var staged: components_mod.StreamChunks = .{};
        errdefer components_mod.StreamChunks.deinit(allocator, (&staged)[0..1]);
        try staged.queue.ensureUnusedCapacity(allocator, initial_chunks.len);
        for (initial_chunks) |c| {
            const cl = try allocator.dupe(u8, c);
            try staged.tryAppend(allocator, cl);
        }
        try server.reg.set(ent, current_coll, components_mod.StreamChunks, staged);
        staged = .{}; // ownership transferred — errdefer is a no-op
    }

    {
        const spine: [][]u8 = if (kv_prefixes.len > 0)
            try allocator.alloc([]u8, kv_prefixes.len)
        else
            &.{};
        errdefer if (kv_prefixes.len > 0) allocator.free(spine);
        var built: usize = 0;
        errdefer for (spine[0..built]) |p| allocator.free(p);
        for (kv_prefixes, 0..) |p, i| {
            spine[i] = try allocator.dupe(u8, p);
            built = i + 1;
        }
        const next_wake_ns: i64 = if (interval_ms > 0)
            @as(i64, @intCast(std.time.nanoTimestamp())) + interval_ms * std.time.ns_per_ms
        else
            std.math.maxInt(i64);
        try server.reg.set(ent, current_coll, components_mod.StreamWakes, .{
            .interval_ms = interval_ms,
            .next_wake_ns = next_wake_ns,
            .kv_prefixes = spine,
        });
    }

}

// Phase 7: `registerStreamCell` removed — stream state lives on
// the entity's components (set by `setStreamComponents` in
// streamRecordIfAnyAt / streamParkIfAny); no side-table cell.
// `Collection.deinit` invokes each component's deinit on shutdown,
// so the per-shutdown manual cleanup site is gone.

/// Phase 2b-ii: per-tick driver for active streaming chains. For each
/// entity currently in `stream_data_out` (h2's "ready for the next
/// DATA frame" state):
///   • chunks pending  → pop one, stamp `RespBody`, move to
///                       `stream_data_in` (h2 frames + sends it,
///                       cycles the entity back here).
///   • chunks drained, timer due → run the next handler activation
///                                 (`resumeStream`). The handler may
///                                 enqueue more chunks or terminate.
///   • chunks drained, `close_pending`
///                       → move to `stream_close_in` (END_STREAM)
///                         and free the chain cell.
///   • chunks drained, no wake yet → idle, wait for the next tick.
///
/// O(parked) per call, gated by `count() == 0` so the worker hot
/// path (no streams) pays nothing.
pub fn serviceParkedStreams(worker: anytype) !void {
    // Drain the inbox UNCONDITIONALLY — even when no cells are
    // parked locally a producer may have just pushed an event that
    // matches the next inbound stream's prefix. Cheap: empty inbox
    // is one mutex lock + a length check.
    try drainKvWakeInbox(worker);

    const server = worker.h2;
    // Phase 7: empty stream_data_out → nothing to do (was guarded by
    // the side-table counts).
    if (server.stream_data_out.entitySlice().len == 0) return;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    // Snapshot (entity, sid, sess) for every entity in stream_data_out
    // that holds a stream chain (non-empty StreamChain.module_path).
    // `move` is queued, so the slice itself stays stable across the
    // loop body. The snapshot keeps per-iter lookups self-contained
    // across resume mutations.
    const Pending = struct { ent: rove.Entity, sid: h2.StreamId, sess: h2.Session };
    var buf: [256]Pending = undefined;
    var n: usize = 0;
    {
        const ents = server.stream_data_out.entitySlice();
        const sids = server.stream_data_out.column(h2.StreamId);
        const sesss = server.stream_data_out.column(h2.Session);
        const chains = server.stream_data_out.column(components_mod.StreamChain);
        for (ents, sids, sesss, chains) |ent, sid, sess, chain| {
            if (chain.module_path.len == 0) continue; // non-stream entity
            if (n >= buf.len) break;
            buf[n] = .{ .ent = ent, .sid = sid, .sess = sess };
            n += 1;
        }
    }

    for (buf[0..n]) |p| {
        // Phase 7: draining state lives on the entity's StreamDraining
        // component instead of a side-table map split. Reads of
        // chunks/wakes/chain identity come from the four stream
        // components.
        const draining_comp = server.reg.get(p.ent, &server.stream_data_out, components_mod.StreamDraining) catch continue;
        const chunks_comp = server.reg.get(p.ent, &server.stream_data_out, components_mod.StreamChunks) catch continue;
        const wakes_comp = server.reg.get(p.ent, &server.stream_data_out, components_mod.StreamWakes) catch continue;
        const chain_comp = server.reg.get(p.ent, &server.stream_data_out, components_mod.StreamChain) catch continue;
        const ctx_comp = server.reg.get(p.ent, &server.stream_data_out, components_mod.ChainContext) catch continue;

        // Drain one chunk per tick — h2 cycles the entity back to
        // `stream_data_out` after each DATA frame ships. Same for
        // both active and draining streams. `popOldest` keeps the
        // `queue_bytes` byte tracker in lockstep with the queue.
        if (chunks_comp.popOldest()) |chunk| {
            // RespBody takes ownership; h2's onDataSourceReadCb frees
            // the buffer after consuming it (h2/root.zig:818).
            try server.reg.set(p.ent, &server.stream_data_out, h2.RespBody, .{
                .data = chunk.ptr,
                .len = @intCast(chunk.len),
            });
            try server.reg.move(p.ent, &server.stream_data_out, &server.stream_data_in);
            continue;
        }

        // Chunks drained. If StreamDraining flagged the chain, close
        // now (END_STREAM); component deinit cleans up on destroy.
        if (draining_comp.is_draining) {
            try server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in);
            continue;
        }

        // Gap 2.2 Phase D: timer-due → push timer entry to the
        // §9.4 ring + advance next_wake_ns; the wake-batch
        // activation below fires from the ring (kv + timer
        // unified). next_wake_ns is reset relative to now
        // (drift-on-each-fire, matching the existing pattern in
        // resumeStream's outcome handler at ~4472).
        if (wakes_comp.interval_ms > 0 and now_ns >= wakes_comp.next_wake_ns) {
            wakes_comp.pending_wakes.push(worker.allocator, .{
                .tag = .timer,
                .fired_at_ns = now_ns,
            });
            wakes_comp.next_wake_ns = now_ns + wakes_comp.interval_ms * std.time.ns_per_ms;
        }

        // Any wakes in the ring? Fire one wake_batch activation
        // (drains kv + timer entries in temporal order; surfaces
        // `lost_oldest` as the §9.4 rate-limit signal).
        if (wakes_comp.pending_wakes.len > 0) {
            if (chain_comp.activation_count >= MAX_STREAM_ACTIVATIONS) {
                std.log.warn(
                    "rove-js stream: tenant={s} corr={s} hit activation cap; closing",
                    .{ ctx_comp.tenant_id, ctx_comp.correlation_id orelse "(none)" },
                );
                try server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in);
                continue;
            }
            resumeStream(worker, p.ent, p.sid, p.sess, .wake_batch) catch |err| {
                std.log.warn(
                    "rove-js stream-resume (wake_batch): tenant={s} corr={s}: {s}; closing",
                    .{ ctx_comp.tenant_id, ctx_comp.correlation_id orelse "(none)", @errorName(err) },
                );
                server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in) catch {};
            };
            continue;
        }

        // No wake registered (interval_ms == 0 AND no kv match):
        // the chain was "stream a finite batch + close" (the §3.3
        // degenerate shape — `acme/stream/index.mjs`). Close now
        // that the initial chunks have shipped.
        if (wakes_comp.interval_ms == 0 and wakes_comp.kv_prefixes.len == 0) {
            try server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in);
            continue;
        }
        // No wake due yet — idle, waiting for either a kv match or
        // the timer.
    }
}

/// Drain the worker's `wake_inbox` of kv-write events. For every
/// stream entity (in one of the h2 stream-pipeline collections,
/// not draining) whose `kv_prefixes` includes a prefix of the
/// event's key, push a `WakeEntry` into the §9.4 `pending_wakes`
/// ring (oldest-first, ring drops oldest + bumps `lost_oldest`
/// on overflow — surfaces to the handler as the rate-limit signal).
/// Events whose tenant_id matches no held stream are simply
/// dropped — the per-tenant scoping § 4.6 invariant lives at
/// REGISTRATION time (a cell only registers prefixes for its own
/// tenant), so a stale event against an old tenant just doesn't
/// match anything.
///
/// Phase 7: side-table iteration replaced by an in-place sweep of
/// the five h2 stream-pipeline collections. Empty collections cost
/// one length check each (no allocator pressure).
fn drainKvWakeInbox(worker: anytype) !void {
    const allocator = worker.allocator;
    var events: std.ArrayListUnmanaged(KvWakeEvent) = .empty;
    defer {
        for (events.items) |*e| e.deinit(allocator);
        events.deinit(allocator);
    }
    try worker.wake_inbox.drainInto(&events);
    if (events.items.len == 0) return;

    const server = worker.h2;
    inline for (.{
        &server.stream_response_in,
        &server.stream_data_out,
        &server.stream_data_in,
        &server.stream_close_in,
        &server._stream_data_sending,
    }) |coll| {
        const wakes_col = coll.column(components_mod.StreamWakes);
        const chains_col = coll.column(components_mod.ChainContext);
        const drain_col = coll.column(components_mod.StreamDraining);
        for (wakes_col, chains_col, drain_col) |*wakes, chain_ctx, drain| {
            if (drain.is_draining) continue;
            if (wakes.kv_prefixes.len == 0) continue;
            try matchEventsToWakes(allocator, &events, wakes, chain_ctx);
        }
    }
}

/// Walk events oldest-first; push every matching event into the §9.4
/// `PendingWakes` ring on this stream. The ring drops oldest +
/// bumps `lost_oldest` on overflow, so a burst of >K matches is
/// rate-limited by construction — the handler sees `lost_oldest > 0`
/// on its next activation and re-reads kv state.
fn matchEventsToWakes(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(KvWakeEvent),
    wakes: *components_mod.StreamWakes,
    chain_ctx: components_mod.ChainContext,
) !void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    // Oldest-first so the ring preserves temporal order (§9.4 wakes
    // surface in the order they happened; the handler iterates).
    for (events.items) |ev| {
        if (!std.mem.eql(u8, ev.tenant_id, chain_ctx.tenant_id)) continue;
        var matched: bool = false;
        for (wakes.kv_prefixes) |pfx| {
            if (std.mem.startsWith(u8, ev.key, pfx)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;

        // `push` takes ownership of the duplicated key on success;
        // on full-ring it drops the oldest (freeing its key) and
        // bumps `lost_oldest`.
        const ring_key = try allocator.dupe(u8, ev.key);
        wakes.pending_wakes.push(allocator, .{
            .tag = .kv,
            .kv_key = ring_key,
            .kv_op = ev.op,
            .fired_at_ns = now_ns,
        });
    }
}

/// Phase 2b-ii: run the next handler activation for a parked stream.
/// Structural twin of `resumeContinuation` — same dispatch surface
/// (re-enter `Dispatcher.runOutcome` with a synthesized `Request`),
/// divergent in the outcome-application tail.
///
/// Handler-cmds Phase 8 TEA-framing (Gap 2.2 reshape):
///   - **Msg**:   `(wake_batch, entity in stream_data_out with
///                non-empty StreamChain.module_path AND
///                StreamWakes.pending_wakes.len > 0)`.
///   - **prep**:  read four stream components on the entity; resolve
///                deployment; drain `pending_wakes` ring into the
///                Request's `activation_wakes` slice + `lost_oldest`
///                snapshot; build request body = `{ctx}` with
///                `.wake_batch` activation.
///   - **run**:   `dispatcher.runOutcome` (chain-tail txn).
///   - **apply (Cmd-list)**: switch on outcome:
///       • terminal → on read-only: append body to StreamChunks +
///         markStreamDraining immediately. On wrote: stage body
///         chunk + mark_draining=true on `BufferedSendKvOps`;
///         `proposeForgetfulWrites`'s parked unit applies them
///         from the commit arm (Phase 4.0.b — `streaming-model.md`
///         §2 rule).
///       • stream → update StreamChain.ctx_json + StreamWakes
///         (kv_prefixes / interval / next_wake) + increment
///         activation_count (eager — internal state). On read-only:
///         transfer chunks now. On wrote: stage chunks on the
///         parked unit; commit arm transfers them onto StreamChunks
///         after raft commits.
///       • continuation → 501 + markStreamDraining (`__rove_next`
///         from a stream-resume hop is out of scope).
///
/// Phase 4b lifted the read-only constraint; Phase 4.0.b closed the
/// chunk-leak: write-path resumes `proposeForgetfulWrites` the txn
/// AND stage their chunks on the parked unit so the chunks reach the
/// wire only after raft commits. A fault arm discards both the txn
/// (rollback) and the staged chunks (`BufferedSendKvOps.deinit`).
fn resumeStream(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    activation: log_mod.ActivationSource,
) !void {
    _ = sid;
    _ = sess; // Reserved for Phase 3 cross-collection resolves; see
    // resumeContinuation's signature for the call-site shape we'll
    // mirror when the activation may not start from `stream_data_out`.

    const allocator = worker.allocator;
    // Handler-cmds Phase 3: chain identity + chunks + wakes ride on
    // the entity's components. Phase 7: draining-state is encoded
    // by `StreamDraining.is_draining` — `resumeStream` only fires
    // for non-draining entities (the caller filters); the terminal /
    // cap-hit branches `markStreamDraining(server, ent)` instead of
    // mutating a `close_pending` field.
    const server = worker.h2;
    const chain_ctx = server.reg.get(ent, &server.stream_data_out, components_mod.ChainContext) catch return error.ResumeNoChainCtx;
    const chain_st = server.reg.get(ent, &server.stream_data_out, components_mod.StreamChain) catch return error.ResumeNoChainState;
    const chunks_st = server.reg.get(ent, &server.stream_data_out, components_mod.StreamChunks) catch return error.ResumeNoChunks;
    const wakes_st = server.reg.get(ent, &server.stream_data_out, components_mod.StreamWakes) catch return error.ResumeNoWakes;

    const path = chain_st.module_path;
    var dep = try resolveDeployment(worker, allocator, chain_ctx.tenant_id, path);
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // Synthesized resume body: `{ctx: <ctx_json>}` — same JSON shape
    // resumeContinuation's deadline path uses, minus the outcome
    // field (a timer wake has no callee result). Handlers read
    // `request.activation` (set via the dispatcher's
    // `activation_source` field, exposed in globals) to branch.
    const body = try std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{chain_st.ctx_json});
    defer allocator.free(body);
    const spath = try std.fmt.allocPrint(allocator, "/{s}", .{path});
    defer allocator.free(spath);

    // Heap-allocate the txn so its pointer can park on a
    // parked_units `ParkedUnit.txn` if the hop wrote (Phase 4b).
    // Same stable-pointer pattern as resumeContinuation (4a) +
    // fireDisconnectActivation (4c).
    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return error.ResumeTxnAlloc;
    var txn_owned = true;
    defer if (txn_owned) allocator.destroy(txn);
    txn.* = inst.kv.beginTrackedImmediate() catch return error.ResumeTxn;
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var readset = tape_mod.Readset.init(allocator, now_ns, @bitCast(now_ns));
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    // wake_batch activation: drain the StreamWakes ring into a
    // temporal-order slice + `lost_oldest` snapshot; resumeStream
    // owns the slice + each entry's `kv_key` for the dispatch's
    // lifetime.
    var batch_owned: []components_mod.WakeEntry = &.{};
    var batch_lost_oldest: u32 = 0;
    defer if (batch_owned.len > 0) {
        for (batch_owned) |*w| w.deinit(allocator);
        allocator.free(batch_owned);
    };
    if (activation == .wake_batch) {
        const drained = wakes_st.pending_wakes.drainInto(allocator) catch
            return error.ResumeWakeDrain;
        batch_owned = drained.wakes;
        batch_lost_oldest = drained.lost_oldest;
    }
    // §9.4 write-pressure: snapshot + reset the chunk-queue drop
    // counter so this activation sees the count of chunks dropped
    // since the last activation (one-shot signal — handler decides
    // whether to refetch / resync / throttle / terminate).
    const dropped_chunks_snapshot = chunks_st.takeDropped();
    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .readset = &readset,
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = chain_ctx.correlation_id,
        .activation_source = activation,
        .activation_wakes = batch_owned,
        .activation_lost_oldest = batch_lost_oldest,
        .activation_write_pressure_dropped = dropped_chunks_snapshot,
    };
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker.dispatcher.runOutcome(
        inst.kv,
        txn,
        &ws,
        bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        request,
        &budget,
    ) catch {
        txn.rollback() catch {};
        txn_done = true;
        markStreamDraining(server, ent);
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    var oc = run_oc;
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                markStreamDraining(server, ent);
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, chain_ctx.correlation_id, activation, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            // Effect-reification Phase 4.0.b: terminal + writes —
            // stage the body chunk + the draining flag on the
            // parked unit so they apply only after raft commits
            // (`streaming-model.md` §2 rule). Pre-fix this arm
            // queued the body into StreamChunks AND fired
            // `markStreamDraining` immediately, both eagerly — a
            // raft fault during the commit-wait window would close
            // the stream and ship the terminal frame whose writes
            // never durably landed. Post-fix the parked_units
            // commit arm (via `transferStagedChunks`) is the single
            // release point.
            if (wrote) {
                var stage: StreamResumeStage = .{
                    .entity = ent,
                    .mark_draining = true,
                };
                defer {
                    for (stage.chunks.items) |c| allocator.free(c);
                    stage.chunks.deinit(allocator);
                }
                if (r.body.len > 0) {
                    const owned = try allocator.dupe(u8, r.body);
                    errdefer allocator.free(owned);
                    try stage.chunks.append(allocator, owned);
                }
                const lh_term: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = @intCast(@max(@min(r.status, 599), 100)),
                    .outcome = .ok,
                    .activation = activation,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, &stage, &readset, lh_term) catch |perr| {
                    std.log.warn("rove-js stream-resume (terminal + writes): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    // No commit gate to wait for — close the stream
                    // now so the customer sees a defined 500 rather
                    // than a half-open stream. Helper has already
                    // freed `stage.chunks`; the defer is a no-op.
                    markStreamDraining(server, ent);
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, chain_ctx.correlation_id, activation, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                // `markStreamDraining` does NOT fire here — the
                // commit arm flips it via `stage.mark_draining`
                // strictly after the body lands in StreamChunks.
                // Until then the stream stays alive; on commit the
                // serviceParkedStreams tick drains the chunk and
                // then closes (chunks-empty + is_draining).
                chain_st.activation_count += 1;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, activation, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            // Clean read-only terminal: flush the body as one last
            // chunk + flag close_pending. Empty body = close
            // immediately on the next service tick.
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeStream.commit(terminal)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            if (r.body.len > 0) {
                const owned = try allocator.dupe(u8, r.body);
                try chunks_st.tryAppend(allocator, owned);
            }
            markStreamDraining(server, ent);
            chain_st.activation_count += 1;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, activation, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // Stream-resume → __rove_next: would transition the
            // chain from a stream into a one-shot continuation,
            // which requires moving the entity out of the stream
            // pipeline and into parked_continuations. Out of scope
            // for Phase 4 — close with a defined 501.
            cval.deinit(allocator);
            txn.rollback() catch {};
            txn_done = true;
            markStreamDraining(server, ent);
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 501, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation, 0);
        },
        .stream => |*s2| {
            // Effect-reification Phase 4.0.b: stream + writes —
            // stage `s2.chunks` on the parked unit so they ship
            // only after raft commits (`streaming-model.md` §2
            // rule). The internal-state updates further down
            // (ctx_json / interval / kv_prefixes / activation_count)
            // stay eager — the §2 rule covers chunks reaching the
            // wire, not per-stream runtime state; handlers re-read
            // kv on every activation so a fault leaving ctx
            // ahead of durable kv is recoverable by the customer.
            var stage: StreamResumeStage = .{
                .entity = ent,
                .mark_draining = false,
            };
            defer {
                for (stage.chunks.items) |c| allocator.free(c);
                stage.chunks.deinit(allocator);
            }
            // Phase 5b-1: hoist fw_seq so the post-block captureLog
            // stamps the propose seq in the wrote case and 0 in the
            // read-only case (no propose ran).
            var fw_seq: u64 = 0;
            if (wrote) {
                // Move s2.chunks → stage.chunks BEFORE the propose
                // so a propose failure frees them via the helper.
                if (s2.chunks.len > 0) {
                    try stage.chunks.ensureUnusedCapacity(allocator, s2.chunks.len);
                    for (s2.chunks) |c| stage.chunks.appendAssumeCapacity(c);
                    allocator.free(s2.chunks);
                    s2.chunks = &.{};
                }
                const lh_stream: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = activation,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, &stage, &readset, lh_stream) catch |perr| {
                    std.log.warn("rove-js stream-resume (stream + writes): propose failed: {s}", .{@errorName(perr)});
                    // Helper already freed `stage.chunks` (the
                    // outer defer is now a no-op). Free what's
                    // left on the outcome struct (headers /
                    // ctx_json / kv_prefixes — chunks slice is
                    // already `&.{}`).
                    s2.deinit(allocator);
                    txn_owned = false;
                    txn_done = true;
                    markStreamDraining(server, ent);
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
            } else {
                txn.commit() catch |e| panic_mod.invariantViolated(
                    "resumeStream.commit(stream)",
                    "err={s}",
                    .{@errorName(e)},
                );
                txn_done = true;
            }
            // Headers on subsequent hops are ignored (the stream's
            // initial response headers already shipped); free them.
            if (s2.headers) |h| allocator.free(h);
            s2.headers = null;
            // Transfer chunks into the StreamChunks component's
            // queue via the §9.4 cap-aware enqueue. `tryAppend`
            // takes ownership of each chunk pointer; cap-overflow
            // frees the chunk + increments `dropped_chunks` (the
            // next activation surfaces it via write_pressure).
            // Phase 4.0.b: on the `wrote` path, `s2.chunks` is
            // already `&.{}` (moved into `stage` above); this loop
            // no-ops there. On the read-only path it ships the
            // chunks immediately — no raft propose, no commit gate.
            for (s2.chunks) |c| try chunks_st.tryAppend(allocator, c);
            if (s2.chunks.len > 0) allocator.free(s2.chunks);
            s2.chunks = &.{};
            // Replace ctx + interval on the component. Old ctx_json
            // is freed; new one is taken from the descriptor
            // (transfer ownership).
            if (chain_st.ctx_json.len > 0) allocator.free(chain_st.ctx_json);
            chain_st.ctx_json = s2.ctx_json;
            s2.ctx_json = &.{};
            if (s2.interval_ms) |iv| {
                wakes_st.interval_ms = iv;
                wakes_st.next_wake_ns = now_ns + iv * std.time.ns_per_ms;
            } else {
                wakes_st.interval_ms = 0;
                wakes_st.next_wake_ns = std.math.maxInt(i64);
            }
            // Replace the StreamWakes' kv-wake registration with
            // whatever the handler returned. Phase 3 v1 keeps
            // re-registration simple: free old prefixes, take
            // ownership of the new ones. The (tenant, prefix)
            // registry is a derived view recomputed on every match
            // scan, so there's no separate unregister/re-register
            // step needed.
            for (wakes_st.kv_prefixes) |p| allocator.free(p);
            if (wakes_st.kv_prefixes.len > 0) allocator.free(wakes_st.kv_prefixes);
            wakes_st.kv_prefixes = s2.kv_prefixes;
            s2.kv_prefixes = &.{};
            chain_st.activation_count += 1;
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation, fw_seq);
        },
    }
}

/// `docs/streaming-model.md` §7 item 1 (Gap #1 follow-up):
/// bound-fetch chunk arriving on an entity that already transitioned
/// cont→stream. Sibling of `resumeStream` — same stream-chain
/// machinery, but the activation kind is `.fetch_chunk` (carrying
/// the chunk bytes/seq/done payload on the Request) and the dispatch
/// targets the module's `onFetchChunk` named export via
/// `?fn=onFetchChunk`.
///
/// Per rove-library principle 1, the caller has already established
/// the entity's state (it's in `stream_data_out`); this function
/// assumes that and reads chain components from there. Outcome
/// handling mirrors `resumeStream`: Response → terminal chunk-drain
/// then close; stream → append chunks + update wakes; continuation
/// → 501 (stream → cont transition is out of scope, same as the
/// existing stream-resume `.continuation` arm).
///
/// `ev` is consumed — every exit path deinits via the caller's
/// outer defer (mirrors `resumeBoundFetchChain`'s ownership).
pub fn resumeBoundFetchStream(
    worker: anytype,
    ent: rove.Entity,
    ev: *components_mod.UpstreamFetchEvent,
) void {
    // Mirror resumeBoundFetchChain's ownership contract: own the
    // event's deinit on every exit path.
    defer components_mod.UpstreamFetchEvent.deinitItem(ev, worker.allocator);

    const allocator = worker.allocator;
    const server = worker.h2;

    // The entity can be in either stream_response_in (post-commit,
    // h2 hasn't moved it to stream_data_out yet — typically a one-
    // tick window) or stream_data_out (steady-state). Both share
    // the StreamRow so components are accessible from either. The
    // caller verified isInCollection before dispatching here;
    // we re-probe to pick the right collection for component reads.
    //
    // markStreamDraining is hardcoded against stream_data_out — when
    // entity is in stream_response_in, we set is_draining directly
    // against the current collection.
    const in_data_out = server.reg.isInCollection(ent, &server.stream_data_out);
    const chain_ctx = if (in_data_out)
        server.reg.get(ent, &server.stream_data_out, components_mod.ChainContext) catch return
    else
        server.reg.get(ent, &server.stream_response_in, components_mod.ChainContext) catch return;
    const chain_st = if (in_data_out)
        server.reg.get(ent, &server.stream_data_out, components_mod.StreamChain) catch return
    else
        server.reg.get(ent, &server.stream_response_in, components_mod.StreamChain) catch return;
    const chunks_st = if (in_data_out)
        server.reg.get(ent, &server.stream_data_out, components_mod.StreamChunks) catch return
    else
        server.reg.get(ent, &server.stream_response_in, components_mod.StreamChunks) catch return;
    const wakes_st = if (in_data_out)
        server.reg.get(ent, &server.stream_data_out, components_mod.StreamWakes) catch return
    else
        server.reg.get(ent, &server.stream_response_in, components_mod.StreamWakes) catch return;

    const path = chain_st.module_path;
    var dep = resolveDeployment(worker, allocator, chain_ctx.tenant_id, path) catch |err| {
        std.log.warn(
            "rove-js bound-fetch stream resume: resolveDeployment tenant={s} module={s}: {s}",
            .{ chain_ctx.tenant_id, path, @errorName(err) },
        );
        return;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // Resume body: `{ctx: <ctx_json>}` matching the other resume
    // engines — request.body is overridden in globals.zig with the
    // chunk bytes for bound fetch_chunk activations
    // (`activation_entity != null` gate).
    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{chain_st.ctx_json}) catch return;
    defer allocator.free(body);
    // Custom `name:` override (matches resumeBoundFetchChain's
    // first-chunk handling) — falls back to `onFetchChunk`.
    const fn_name: []const u8 = if (ev.name.len > 0) ev.name else "onFetchChunk";
    const spath = std.fmt.allocPrint(allocator, "/{s}?fn={s}", .{ path, fn_name }) catch return;
    defer allocator.free(spath);
    const query = std.fmt.allocPrint(allocator, "fn={s}", .{fn_name}) catch return;
    defer allocator.free(query);

    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return;
    var txn_owned = true;
    defer if (txn_owned) allocator.destroy(txn);
    txn.* = inst.kv.beginTrackedImmediate() catch return;
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var readset = tape_mod.Readset.init(allocator, now_ns, @bitCast(now_ns));
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };

    const dropped_chunks_snapshot = chunks_st.takeDropped();
    // Snapshot fetchesPending — same shape as resumeBoundFetchChain.
    // Entity is in `stream_data_out` or `stream_response_in` at
    // this point; both carry BoundFetchCount via the merged Row.
    const fetches_pending: u32 = blk: {
        const cnt_data = server.reg.get(ent, &server.stream_data_out, components_mod.BoundFetchCount) catch null;
        if (cnt_data) |c| break :blk c.pending;
        const cnt_in = server.reg.get(ent, &server.stream_response_in, components_mod.BoundFetchCount) catch null;
        if (cnt_in) |c| break :blk c.pending;
        break :blk 0;
    };

    var req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = query,
        .readset = &readset,
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = chain_ctx.correlation_id,
        .activation_source = .fetch_chunk,
        .activation_fetch_id = ev.fetch_id,
        .is_system_module = builtin_modules_mod.isBuiltinPath(path),
        .activation_write_pressure_dropped = dropped_chunks_snapshot,
        .resume_if_bound = &@TypeOf(worker.*).resumeIfBoundTrampoline,
        .resume_if_bound_ctx = @ptrCast(worker),
        .cancel_fetch = &@TypeOf(worker.*).cancelFetchTrampoline,
        .cancel_fetch_ctx = @ptrCast(worker),
        .register_bound_fetch = &@TypeOf(worker.*).registerBoundFetchTrampoline,
        .register_bound_fetch_ctx = @ptrCast(worker),
        .activation_entity = ent,
        .activation_fetches_pending = fetches_pending,
    };
    req.activation_fetch_seq = ev.seq;
    req.activation_fetch_byte_offset = ev.byte_offset;
    req.activation_fetch_bytes = ev.bytes;
    req.activation_fetch_headers = ev.fetch_headers;
    req.activation_fetch_final = ev.final;
    if (ev.final) {
        req.activation_fetch_terminal_status = ev.terminal_status;
        req.activation_fetch_terminal_ok = ev.terminal_ok;
        req.activation_fetch_body_truncated = ev.body_truncated;
    }

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    var oc = worker.dispatcher.runOutcome(
        inst.kv,
        txn,
        &ws,
        bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        req,
        &budget,
    ) catch {
        txn.rollback() catch {};
        txn_done = true;
        markStreamDrainingAnywhere(server, ent);
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .fetch_chunk, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            // Chain going terminal — cancel sibling binds (same
            // pattern as resumeBoundFetchChain's terminal arm).
            worker_mod.scanAndCancelBoundFetches(worker, ent);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                markStreamDrainingAnywhere(server, ent);
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, chain_ctx.correlation_id, .fetch_chunk, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                var stage: StreamResumeStage = .{ .entity = ent, .mark_draining = true };
                defer {
                    for (stage.chunks.items) |c| allocator.free(c);
                    stage.chunks.deinit(allocator);
                }
                if (r.body.len > 0) {
                    const owned = allocator.dupe(u8, r.body) catch return;
                    errdefer allocator.free(owned);
                    stage.chunks.append(allocator, owned) catch return;
                }
                const lh_term: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = @intCast(@max(@min(r.status, 599), 100)),
                    .outcome = .ok,
                    .activation = .fetch_chunk,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, &stage, &readset, lh_term) catch |perr| {
                    std.log.warn("rove-js bound-fetch stream (terminal + writes): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    markStreamDrainingAnywhere(server, ent);
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, chain_ctx.correlation_id, .fetch_chunk, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                chain_st.activation_count += 1;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .fetch_chunk, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            // Read-only terminal: flush + drain-then-close.
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeBoundFetchStream.commit(terminal_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            if (r.body.len > 0) {
                const owned = allocator.dupe(u8, r.body) catch return;
                chunks_st.tryAppend(allocator, owned) catch {};
            }
            markStreamDrainingAnywhere(server, ent);
            chain_st.activation_count += 1;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .fetch_chunk, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // Stream→cont transition out of scope (same as
            // resumeStream's .continuation arm — 501 + draining).
            cval.deinit(allocator);
            txn.rollback() catch {};
            txn_done = true;
            markStreamDrainingAnywhere(server, ent);
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 501, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .fetch_chunk, 0);
        },
        .stream => |*s2| {
            // stream({write}) on a stream-state chain: append write
            // bytes to StreamChunks (commit-gated on the wrote path,
            // immediate on read-only). Mirrors resumeStream's
            // .stream arm exactly.
            var stage: StreamResumeStage = .{ .entity = ent, .mark_draining = false };
            defer {
                for (stage.chunks.items) |c| allocator.free(c);
                stage.chunks.deinit(allocator);
            }
            var fw_seq: u64 = 0;
            if (wrote) {
                if (s2.chunks.len > 0) {
                    stage.chunks.ensureUnusedCapacity(allocator, s2.chunks.len) catch {};
                    for (s2.chunks) |c| stage.chunks.appendAssumeCapacity(c);
                    allocator.free(s2.chunks);
                    s2.chunks = &.{};
                }
                const lh_stream: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .fetch_chunk,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, &stage, &readset, lh_stream) catch |perr| {
                    std.log.warn("rove-js bound-fetch stream (stream + writes): propose failed: {s}", .{@errorName(perr)});
                    s2.deinit(allocator);
                    txn_owned = false;
                    txn_done = true;
                    markStreamDrainingAnywhere(server, ent);
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .fetch_chunk, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
            } else {
                txn.commit() catch |e| panic_mod.invariantViolated(
                    "resumeBoundFetchStream.commit(stream_ro)",
                    "err={s}",
                    .{@errorName(e)},
                );
                txn_done = true;
            }
            // Headers on subsequent hops ignored; free.
            if (s2.headers) |h| allocator.free(h);
            s2.headers = null;
            for (s2.chunks) |c| chunks_st.tryAppend(allocator, c) catch {};
            if (s2.chunks.len > 0) allocator.free(s2.chunks);
            s2.chunks = &.{};
            if (chain_st.ctx_json.len > 0) allocator.free(chain_st.ctx_json);
            chain_st.ctx_json = s2.ctx_json;
            s2.ctx_json = &.{};
            if (s2.interval_ms) |iv| {
                wakes_st.interval_ms = iv;
                wakes_st.next_wake_ns = now_ns + iv * std.time.ns_per_ms;
            } else {
                wakes_st.interval_ms = 0;
                wakes_st.next_wake_ns = std.math.maxInt(i64);
            }
            for (wakes_st.kv_prefixes) |p| allocator.free(p);
            if (wakes_st.kv_prefixes.len > 0) allocator.free(wakes_st.kv_prefixes);
            wakes_st.kv_prefixes = s2.kv_prefixes;
            s2.kv_prefixes = &.{};
            chain_st.activation_count += 1;
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .fetch_chunk, fw_seq);
        },
    }
}

// ── Activation firers ─────────────────────────────────────────────────

/// Streaming-handlers-plan §4.4: client disconnect on a held stream.
/// h2's `serverStreamClose` routed the entity to `response_out`
/// (FIN/RST observed) without our drain-then-close path firing —
/// `cleanupResponses` notices the populated StreamChain on the
/// entity and calls this before destroying it.
///
/// Handler-cmds Phase 8 TEA-framing:
///   - **Msg**:   `(client-disconnect, entity in response_out with
///                non-empty StreamChain.module_path)`.
///   - **prep**:  read ChainContext + StreamChain; resolveDeployment;
///                build request body = `{ctx}` with `.disconnect`
///                activation.
///   - **run**:   `dispatcher.runOutcome` (the writes commit
///                asynchronously via `proposeForgetfulWrites` since
///                there's no entity awaiting commit — Phase 4c).
///   - **apply (Cmd-list)**: outcome IS moot (socket gone) — we
///                deinit whatever variant the handler returned and
///                record the outcome on the tape with the
///                appropriate status. Writes that fire commit; the
///                customer's cleanup observable effects (`_send/owed/`,
///                kv writes, kv-wakes) materialize for other
///                observers.
///
/// Errors return `void` — caller (`cleanupResponses`) is about to
/// destroy the entity regardless; the worst case is the disconnect
/// activation gets logged as 500 rather than skipped. Stream
/// components on the entity deinit structurally when destroy fires
/// (no manual cleanup site needed since Phase 7).
pub fn fireDisconnectActivation(worker: anytype, ent: rove.Entity) void {
    const allocator = worker.allocator;
    // Handler-cmds Phase 3: reads come from the entity's components
    // (the entity is in `response_out` at this point — same
    // `merged_request_row` covers it). The side-table cell only
    // confirms the entity HAS a stream (the `.contains` check in
    // `cleanupResponses` is the gate that drove us here).
    const server = worker.h2;
    // Phase 7: entity has a stream chain iff StreamChain.module_path
    // is non-empty. Component presence replaces the parked_streams_*
    // map membership check.
    const chain_st = server.reg.get(ent, &server.response_out, components_mod.StreamChain) catch return;
    if (chain_st.module_path.len == 0) return;
    const chain_ctx = server.reg.get(ent, &server.response_out, components_mod.ChainContext) catch return;
    std.log.info(
        "rove-js stream-disconnect: tenant={s} corr={s} activations={d}",
        .{ chain_ctx.tenant_id, chain_ctx.correlation_id orelse "(none)", chain_st.activation_count },
    );

    const path = chain_st.module_path;
    var dep = resolveDeployment(worker, allocator, chain_ctx.tenant_id, path) catch |err| {
        std.log.warn("rove-js stream-disconnect: tenant={s} resolveDeployment failed: {s}; skipping activation", .{ chain_ctx.tenant_id, @errorName(err) });
        return;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{chain_st.ctx_json}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return;
    defer allocator.free(spath);

    // Heap-allocate the txn so the pointer is stable across an
    // optional `pending_txns[seq]` parking (Phase 4c — writes on
    // a disconnect hop). `txn_owned` flips to false once ownership
    // transfers to the pending map.
    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return;
    var txn_owned = true;
    defer if (txn_owned) allocator.destroy(txn);
    txn.* = inst.kv.beginTrackedImmediate() catch return;
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var readset = tape_mod.Readset.init(allocator, now_ns, @bitCast(now_ns));
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    // §9.4 write-pressure: snapshot + reset the chunk-queue drop
    // counter so the disconnect activation sees what was lost.
    // (No socket to flush to anymore, but the handler can still
    // log / persist an "ended with N dropped frames" marker.)
    // StreamChunks lives on the entity in `response_out` post-
    // FIN-routing; `get` here is best-effort (a malformed entity
    // would simply skip the snapshot).
    const dropped_chunks_snapshot: u32 = blk: {
        const sc = server.reg.get(ent, &server.response_out, components_mod.StreamChunks) catch break :blk 0;
        break :blk sc.takeDropped();
    };
    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .readset = &readset,
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = chain_ctx.correlation_id,
        .activation_source = .disconnect,
        .activation_write_pressure_dropped = dropped_chunks_snapshot,
    };
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker.dispatcher.runOutcome(
        inst.kv,
        txn,
        &ws,
        bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        request,
        &budget,
    ) catch {
        txn.rollback() catch {};
        txn_done = true;
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    var oc = run_oc;
    // The handler's return shape is moot — the socket is closed.
    // We deinit whatever it produced, then record the outcome on
    // the tape with the appropriate status. If the hop WROTE,
    // Phase 4c parks the txn on `pending_txns[seq]` so
    // `drainRaftPending` commits it asynchronously (no entity is
    // waiting; the kv writes + any `_send/owed/*` / §4.6 wakes
    // become durable on their own).
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                const lh_disc_term: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = @intCast(@max(@min(r.status, 599), 100)),
                    .outcome = .ok,
                    .activation = .disconnect,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, null, &readset, lh_disc_term) catch |perr| {
                    std.log.warn("rove-js stream-disconnect: propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false; // helper destroyed it
                    txn_done = true;
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireDisconnectActivation.commit(terminal)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // `__rove_next` from a disconnect hop is futile (no
            // socket to hold) — drop the descriptor. The hop's
            // writes (if any) still commit asynchronously so any
            // observable side effects (kv state, http.send fire,
            // §4.6 wakes) materialize for other observers.
            cval.deinit(allocator);
            if (wrote) {
                const lh_disc_cont: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .disconnect,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, null, &readset, lh_disc_cont) catch |perr| {
                    std.log.warn("rove-js stream-disconnect (cont return): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, fw_seq);
                return;
            }
            txn.rollback() catch {};
            txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
        },
        .stream => |*s2| {
            s2.deinit(allocator);
            if (wrote) {
                const lh_disc_stream: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .disconnect,
                    .method = "POST",
                    .path = chain_st.module_path,
                    .host = "",
                    .correlation_id = chain_ctx.correlation_id orelse "",
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id, null, &readset, lh_disc_stream) catch |perr| {
                    std.log.warn("rove-js stream-disconnect (stream return): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, fw_seq);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireDisconnectActivation.commit(stream)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect, 0);
        },
    }
}

/// Source payload for a Gap 2.1 subscription_fire activation.
/// One variant per `SubscriptionEntry.Spec`. Borrowed slices —
/// caller (the firing site in Phases D/E/F) owns the bytes for
/// the duration of `fireSubscriptionActivation`.
pub const SubscriptionFireSource = union(enum) {
    cron: struct { fired_at_ns: i64 },
    kv: struct { key: []const u8, op: u8 },
    boot: struct { deployment_id: u64 },
};

/// Gap 2.1 Phase C: fire a subscription handler as a fresh chain
/// origin. Structural twin of `fireDisconnectActivation` (no held
/// socket, writes commit asynchronously via `proposeForgetfulWrites`)
/// but slimmer — no held stream to drain, no chunks to clean up.
///
/// **TEA framing:**
///   - **Msg**: `(subscription_fire, source)` where source is
///     one of {cron firedAt, kv key+op, boot deployment_id}.
///   - **prep**: resolveDeployment(tenant_id, module_path); mint
///     a fresh correlation_id; synthesize Request body `{ctx:{}}`.
///   - **run**: `dispatcher.runOutcome` (chain-origin txn).
///   - **apply (Cmd-list)**:
///       • terminal → propose writes (if any) + log; bytes go
///         nowhere (no socket to flush).
///       • continuation / stream → recorded + logged; ignored
///         (a subscription chain has no held socket so multi-hop
///         chains aren't expressible in v1; customer composes
///         multi-step via `http.send({on_result: ...})` which
///         routes as a `send_callback` activation, not as a held
///         continuation).
///
/// Errors return `void` — the caller is best-effort (cron sweep,
/// apply-time hook, boot fire). Failures log + skip the activation.
pub fn fireSubscriptionActivation(
    worker: anytype,
    tenant_id: []const u8,
    subscription_name: []const u8,
    module_path: []const u8,
    source: SubscriptionFireSource,
) void {
    const allocator = worker.allocator;
    var dep = resolveDeployment(worker, allocator, tenant_id, module_path) catch |err| {
        std.log.warn(
            "rove-js subscription-fire: tenant={s} name={s} resolveDeployment failed: {s}; skipping",
            .{ tenant_id, subscription_name, @errorName(err) },
        );
        return;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // Subscription chains start fresh — empty ctx, fresh
    // correlation_id. (The handler can pass ctx forward via its
    // own kv state if it wants persistent chain state across
    // fires; the platform doesn't carry any.)
    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{{}}}}", .{}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return;
    var txn_owned = true;
    defer if (txn_owned) allocator.destroy(txn);
    txn.* = inst.kv.beginTrackedImmediate() catch return;
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var readset = tape_mod.Readset.init(allocator, now_ns, @bitCast(now_ns));
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };

    // Gap 2.1 Phase D: inject the `_boot_fired/<dep_id>` marker
    // into the handler's writeset BEFORE the handler runs. The
    // marker commits atomically with the handler's effects through
    // raft, so any subsequent reload (cold start, leader change)
    // sees the marker and skips the re-fire. Writing the marker
    // BEFORE the handler also covers the "handler throws" case —
    // we don't loop on a failing boot; customer redeploys to fix.
    if (source == .boot) {
        var key_buf: [64]u8 = undefined;
        const marker_key = std.fmt.bufPrint(&key_buf, "_boot_fired/{d}", .{source.boot.deployment_id}) catch unreachable;
        txn.put(marker_key, "fired") catch |err| {
            std.log.warn(
                "rove-js boot marker txn.put ({s}/{d}): {s}",
                .{ tenant_id, source.boot.deployment_id, @errorName(err) },
            );
            return;
        };
        ws.addPut(marker_key, "fired") catch |err| {
            std.log.warn(
                "rove-js boot marker ws.addPut ({s}/{d}): {s}",
                .{ tenant_id, source.boot.deployment_id, @errorName(err) },
            );
            return;
        };
    }

    // Mint a fresh correlation_id for this chain origin. Format:
    // `sub-{name-prefix}-{request_id-hex}` — name-scoped + unique
    // enough to dedup in the replay UX. Truncated to keep length
    // bounded.
    var corr_buf: [80]u8 = undefined;
    const name_prefix_len: usize = @min(subscription_name.len, 32);
    const corr_full = std.fmt.bufPrint(
        &corr_buf,
        "sub-{s}-{x:0>16}",
        .{ subscription_name[0..name_prefix_len], request_id },
    ) catch corr_buf[0..0];

    // Synthesize the Request with the activation payload populated
    // per the source variant.
    var req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .readset = &readset,
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = corr_full,
        .activation_source = .subscription_fire,
        .activation_subscription_name = subscription_name,
    };
    switch (source) {
        .cron => |cs| req.activation_subscription_cron_fired_at_ns = cs.fired_at_ns,
        .kv => |kvs| {
            req.activation_subscription_kv_key = kvs.key;
            req.activation_subscription_kv_op = kvs.op;
        },
        .boot => |bs2| req.activation_subscription_boot_deployment_id = bs2.deployment_id,
    }

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker.dispatcher.runOutcome(
        inst.kv,
        txn,
        &ws,
        bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        req,
        &budget,
    ) catch {
        txn.rollback() catch {};
        txn_done = true;
        captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, corr_full, .subscription_fire, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    var oc = run_oc;
    // Subscription chains have no held socket; non-terminal returns
    // are deinit'd + recorded on the tape with a warning. Customers
    // compose multi-hop via http.send({on_result:...}) instead.
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, corr_full, .subscription_fire, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                const lh_sub_term: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = @intCast(@max(@min(r.status, 599), 100)),
                    .outcome = .ok,
                    .activation = .subscription_fire,
                    .method = "POST",
                    .path = module_path,
                    .host = "",
                    .correlation_id = corr_full,
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset, lh_sub_term) catch |perr| {
                    std.log.warn("rove-js subscription-fire ({s}): propose failed: {s}", .{ subscription_name, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, corr_full, .subscription_fire, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, corr_full, .subscription_fire, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireSubscriptionActivation.commit(terminal)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, corr_full, .subscription_fire, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // `__rove_next` from a subscription chain has no held
            // socket to resume into. Recorded but ignored; writes
            // (if any) still commit. Customers compose multi-step
            // via http.send({on_result:...}) which routes its
            // callback as a `send_callback` activation.
            cval.deinit(allocator);
            std.log.warn(
                "rove-js subscription-fire ({s}): __rove_next from subscription origin is a no-op (v1)",
                .{subscription_name},
            );
            if (wrote) {
                const lh_sub_cont: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .subscription_fire,
                    .method = "POST",
                    .path = module_path,
                    .host = "",
                    .correlation_id = corr_full,
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset, lh_sub_cont) catch |perr| {
                    std.log.warn("rove-js subscription-fire ({s}) cont-return propose failed: {s}", .{ subscription_name, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, corr_full, .subscription_fire, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .subscription_fire, fw_seq);
                return;
            }
            txn.rollback() catch {};
            txn_done = true;
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .subscription_fire, 0);
        },
        .stream => |*s2| {
            // `__rove_stream` from a subscription chain — same as
            // `__rove_next` above: no held socket, recorded but
            // ignored; writes commit.
            s2.deinit(allocator);
            std.log.warn(
                "rove-js subscription-fire ({s}): __rove_stream from subscription origin is a no-op (v1)",
                .{subscription_name},
            );
            if (wrote) {
                const lh_sub_stream: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .subscription_fire,
                    .method = "POST",
                    .path = module_path,
                    .host = "",
                    .correlation_id = corr_full,
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset, lh_sub_stream) catch |perr| {
                    std.log.warn("rove-js subscription-fire ({s}) stream-return propose failed: {s}", .{ subscription_name, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, corr_full, .subscription_fire, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .subscription_fire, fw_seq);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireSubscriptionActivation.commit(stream)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .subscription_fire, 0);
        },
    }
}

/// Phase 5 PR-2: dispatch a chained handler activation produced by
/// `__rove_next` from a fetch handler (and post-PR-2c, from the
/// shim's onresult to invoke the customer's `on_result`). Structural
/// twin of `fireSubscriptionActivation`:
///
///   - **Msg**: `SendCallback{tenant_id, module_path, ctx_json,
///     fn_name?, correlation_id?}`.
///   - **prep**: resolve the cont's module on its tenant; build
///     `body = {"ctx":<ctx>}` (mirrors fireSubscriptionActivation
///     so customers' `JSON.parse(request.body).ctx` pattern is
///     uniform); reuse the inherited correlation_id when present
///     (replay UX groups multi-hop chains) or mint one based on
///     the request_id.
///   - **run**: `dispatcher.runOutcome`. `activation_source ==
///     .send_callback` so `request.activation.kind === "send_callback"`.
///   - **apply**: terminal → propose forgetfully; continuation /
///     stream → recorded but no held socket. Same posture as
///     subscription_fire — fire-and-forget.
///
/// No held socket. Writes commit forgetfully via
/// `proposeForgetfulWrites`. Errors return `void` (best-effort:
/// loss on crash is recovered by the producer's own retry hook —
/// PR-2d's retry sweep, when a webhook leaves an `_send/owed/`
/// marker behind).
fn fireChainedActivation(
    worker: anytype,
    sc: *effect_mod.msg.SendCallback,
) void {
    const allocator = worker.allocator;
    const tenant_id = sc.tenant_id;
    const module_path = sc.module_path;

    var dep = resolveDeployment(worker, allocator, tenant_id, module_path) catch |err| {
        std.log.warn(
            "rove-js chained-dispatch: tenant={s} module={s} resolveDeployment failed: {s}; skipping",
            .{ tenant_id, module_path, @errorName(err) },
        );
        return;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    const ctx_src: []const u8 = if (sc.ctx_json.len > 0) sc.ctx_json else "null";
    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{ctx_src}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return;
    var txn_owned = true;
    defer if (txn_owned) allocator.destroy(txn);
    txn.* = inst.kv.beginTrackedImmediate() catch return;
    var txn_done = false;
    defer if (!txn_done) txn.rollback() catch {};

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var readset = tape_mod.Readset.init(allocator, now_ns, @bitCast(now_ns));
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };

    // Inherit correlation_id when the cont carried one (chained from
    // a fetch handler — preserves the parent fetch's chain identity).
    // Otherwise mint `chain-<request_id>` so the hop self-identifies
    // in the replay tape.
    var corr_buf: [80]u8 = undefined;
    const corr_full: []const u8 = if (sc.correlation_id) |c|
        c
    else
        std.fmt.bufPrint(&corr_buf, "chain-{x:0>16}", .{request_id}) catch corr_buf[0..0];

    // Build the synthetic query for the named-export case (the
    // `?fn=<name>` shape inherited from the original Phase-5-retired
    // callback dispatcher; the chain-activation path now consumes
    // it). Default-export when fn_name is null/empty.
    var query_buf: [256]u8 = undefined;
    const query_opt: ?[]const u8 = if (sc.fn_name) |fnn|
        if (fnn.len > 0) std.fmt.bufPrint(&query_buf, "fn={s}", .{fnn}) catch null else null
    else
        null;

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = query_opt,
        .readset = &readset,
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = corr_full,
        .activation_source = .send_callback,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
    };

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker.dispatcher.runOutcome(
        inst.kv,
        txn,
        &ws,
        bc,
        &tc.snap.bytecodes,
        &tc.snap.source_hashes,
        tc.snap.triggers,
        req,
        &budget,
    ) catch {
        txn.rollback() catch {};
        txn_done = true;
        captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, corr_full, .send_callback, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    var oc = run_oc;
    // Chained-dispatch handler has no held socket. Same posture as
    // subscription_fire: terminal propose-forgetful or commit;
    // cont/stream returns are warned + writes still propose.
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, corr_full, .send_callback, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                const lh_chain_term: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = @intCast(@max(@min(r.status, 599), 100)),
                    .outcome = .ok,
                    .activation = .send_callback,
                    .method = "POST",
                    .path = module_path,
                    .host = "",
                    .correlation_id = corr_full,
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset, lh_chain_term) catch |perr| {
                    std.log.warn("rove-js chained-dispatch ({s}): propose failed: {s}", .{ module_path, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, corr_full, .send_callback, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, corr_full, .send_callback, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireChainedActivation.commit(terminal)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, corr_full, .send_callback, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // Chained-from-chained: enqueue another SendCallback Msg
            // so the next hop runs on the following tick (bounded
            // recursion via the dispatch BATCH cap). Inherits the
            // same correlation_id.
            defer cval.deinit(allocator);
            const enqueue_err = worker.node.enqueueChainedDispatchForTenant(
                tenant_id,
                cval.path,
                cval.ctx_json,
                cval.fn_name,
                corr_full,
            );
            if (enqueue_err) |_| {} else |err| std.log.warn(
                "rove-js chained-dispatch ({s}): nested enqueue failed: {s}",
                .{ module_path, @errorName(err) },
            );
            if (wrote) {
                const lh_chain_cont: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .send_callback,
                    .method = "POST",
                    .path = module_path,
                    .host = "",
                    .correlation_id = corr_full,
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset, lh_chain_cont) catch |perr| {
                    std.log.warn("rove-js chained-dispatch ({s}) cont-return propose failed: {s}", .{ module_path, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, corr_full, .send_callback, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .send_callback, fw_seq);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireChainedActivation.commit(cont)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .send_callback, 0);
        },
        .stream => |*s2| {
            // `__rove_stream` from a chained-dispatch handler — no
            // held socket; same posture as subscription_fire stream.
            s2.deinit(allocator);
            std.log.warn(
                "rove-js chained-dispatch ({s}): __rove_stream is a no-op (no held socket)",
                .{module_path},
            );
            if (wrote) {
                const lh_chain_stream: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 200,
                    .outcome = .ok,
                    .activation = .send_callback,
                    .method = "POST",
                    .path = module_path,
                    .host = "",
                    .correlation_id = corr_full,
                };
                const fw_seq = proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset, lh_chain_stream) catch |perr| {
                    std.log.warn("rove-js chained-dispatch ({s}) stream-return propose failed: {s}", .{ module_path, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, corr_full, .send_callback, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .send_callback, fw_seq);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireChainedActivation.commit(stream)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, corr_full, .send_callback, 0);
        },
    }
}

// ── Commit-gated post-propose ─────────────────────────────────────────

/// Effect-reification Phase 4.0.b: a resume-hop's staged chunks +
/// terminal-draining flag, parked on the unit alongside its txn so
/// they apply on commit (chunks transfer into the entity's
/// `StreamChunks` via `tryAppend`; if `mark_draining`, the entity's
/// `StreamDraining.is_draining` flips to true). Discarded on fault
/// — the chunks free via `BufferedSendKvOps.deinit`, the draining
/// flag never sets, the stream stays alive for the next wake.
///
/// Ownership discipline: passed to `proposeForgetfulWrites` by
/// mutable pointer. The helper takes the chunks list (sets
/// `stage.chunks = .empty`) unconditionally — on success the
/// chunks move into the unit; on every error path they free
/// inside the helper's errdefer. Caller's `defer` over
/// `stage.chunks` is then a no-op (the list is empty), making
/// build-staged-chunks-then-hand-off symmetric on success and
/// failure.
pub const StreamResumeStage = struct {
    entity: rove.Entity,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    mark_draining: bool = false,
};

/// Phase 4c: propose a write batch that nobody is waiting on. The
/// txn rides a `ParkedUnit.txn` field that the parked_units sweep
/// in `drainRaftPending` commits at the seq — same gate as the
/// entity-backed path's `pending_txns[seq]`, just routed through
/// the unit drain so we don't need an entity in `raft_pending`.
/// On commit, the unit's §4.6 kv-wakes fire (the existing
/// `firePendingKvWakes` iterates at the same point).
///
/// Used by `fireDisconnectActivation` — the socket is gone, so
/// we can't gate the held-response on commit, but we still want
/// the writes + their side effects to land durably.
///
/// Effect-reification Phase 4.0.b: the optional `stage` parameter
/// is the new commit-gated streaming-chunks payload. When non-null,
/// it carries an entity in `stream_data_out` + the chunks that the
/// `resumeStream` arm would otherwise have appended eagerly. The
/// parked_units commit arm transfers them onto the entity's
/// `StreamChunks` (and, if `stage.mark_draining`, sets the
/// terminal-draining flag) AFTER the txn commits — closing
/// `streaming-model.md` §2's pre-commit chunk leak. Disconnect,
/// subscription, and fetch-event callers pass `null`; they're
/// either entity-less or already disconnect-tolerant.
///
/// On success the helper consumes the txn pointer AND the `stage`
/// chunks (moved into the ParkedUnit). On failure it rolls back +
/// destroys the txn AND frees any staged chunks; the caller's
/// `txn_owned` flag flips to false either way, and the helper
/// resets `stage.chunks` to `.empty` unconditionally so the
/// caller's `defer` over the list is a no-op on every path.
pub fn proposeForgetfulWrites(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    tenant_id: []const u8,
    stage_opt: ?*StreamResumeStage,
    /// Pass `&readset` (slice 1b's per-activation Readset) so this
    /// activation's readset rides the raft entry as the type-0
    /// envelope's `rs_bytes` section (slice 3d-fetch). `null` for
    /// callers without a per-request readset (none today — every
    /// activation in this file owns one). Serialization failures
    /// log + pass empty so the propose still goes through.
    readset_opt: ?*const tape_mod.Readset,
    /// Slice 5a-1: per-activation LogHeader. Stamped into the readset
    /// blob so any follower (Phase 5c) can rebuild the customer
    /// LogRecord without re-executing. Pass `null` only if the call
    /// site genuinely has no header to stamp (no such site today —
    /// every activation here knows request_id + status + activation).
    log_header_opt: ?log_mod.LogHeader,
) !u64 {
    const allocator = worker.allocator;

    // Take ownership of the staged chunks up-front so every error
    // path that returns frees them. The caller's `stage.chunks` is
    // reset to `.empty` immediately, severing the caller's view
    // of the buffers — the helper now owns them unconditionally
    // (transfer-to-unit on success or free-via-errdefer on error).
    var stage_chunks: std.ArrayListUnmanaged([]u8) = if (stage_opt) |s| blk: {
        const taken = s.chunks;
        s.chunks = .empty;
        break :blk taken;
    } else .empty;
    errdefer {
        for (stage_chunks.items) |c| allocator.free(c);
        stage_chunks.deinit(allocator);
    }

    txn.releaseLease();
    // Serialize the activation's readset (with the caller-supplied
    // LogHeader stamped into it, slice 5a-1) and wrap as a 1-item
    // readset list for the anchor envelope's rs_bytes section
    // (`docs/readset-replication-plan.md` Phase 3d-fetch + multi-
    // readset aggregation). Best-effort: any failure logs and we
    // propose with empty rs_bytes (same as pre-3d-fetch behavior —
    // the chain just doesn't get readset-replicated for this entry).
    const rs_blob: []u8 = if (readset_opt) |rs|
        rs.serialize(allocator, log_header_opt) catch |err| blk: {
            std.log.warn(
                "rove-js proposeForgetfulWrites: readset.serialize tenant={s}: {s}",
                .{ tenant_id, @errorName(err) },
            );
            break :blk &.{};
        }
    else
        &.{};
    defer if (rs_blob.len > 0) allocator.free(rs_blob);
    const rs_bytes: []u8 = if (rs_blob.len > 0)
        tape_mod.encodeReadsetList(allocator, &.{rs_blob}) catch |err| blk: {
            std.log.warn(
                "rove-js proposeForgetfulWrites: encodeReadsetList tenant={s}: {s}",
                .{ tenant_id, @errorName(err) },
            );
            break :blk &.{};
        }
    else
        &.{};
    defer if (rs_bytes.len > 0) allocator.free(rs_bytes);
    const seq = raft_propose.proposeBatch(worker, writeset, tenant_id, rs_bytes) catch |err| {
        txn.rollback() catch {};
        allocator.destroy(txn);
        return err;
    };

    // Effect-reification Phase 4.1: build the parked unit's
    // BufferedCmds list directly. Variants:
    //
    //   - kv_wake_broadcast — one per writeset op (the §4.6 fan-out
    //     + kv-react fire); interpretCmd broadcasts to subscribed
    //     stream watchers + the unit's kv-react walk reads them
    //     before releaseAll consumes.
    //   - stream_chunk      — one per staged chunk (Phase 4.0.b
    //     commit-gated stream output to `stage_opt.entity`).
    //   - stream_close      — single Cmd if `stage_opt.mark_draining`
    //     (terminal+writes resume arm); flips the draining flag
    //     strictly after the chunks land.
    //
    // Total Cmd capacity: writes + chunks + (1 close if any).
    var cmds: effect_mod.cmd.BufferedCmds = .{};
    errdefer cmds.deinit(allocator);
    const chunks_count = stage_chunks.items.len;
    const close_count: usize = if (stage_opt) |s| (if (s.mark_draining) 1 else 0) else 0;
    const cap = writeset.ops.items.len + chunks_count + close_count;
    if (cap > 0) cmds.items.ensureUnusedCapacity(allocator, cap) catch |perr|
        std.log.warn("rove-js forgetful-writes cmds ensureCapacity (tenant={s}) failed: {s}", .{ tenant_id, @errorName(perr) });

    for (writeset.ops.items) |op| switch (op) {
        .put => |p| {
            const k = allocator.dupe(u8, p.key) catch break;
            cmds.items.appendAssumeCapacity(.{
                .kv_wake_broadcast = .{ .key = k, .op = 'p' },
            });
        },
        .delete => |d| {
            const k = allocator.dupe(u8, d.key) catch break;
            cmds.items.appendAssumeCapacity(.{
                .kv_wake_broadcast = .{ .key = k, .op = 'd' },
            });
        },
    };
    if (stage_opt) |s| {
        // Transfer chunks one-for-one into stream_chunk Cmds.
        // Each chunk's bytes ownership moves to the Cmd; clear
        // the source slot to invalidate the earlier errdefer.
        for (stage_chunks.items) |chunk_bytes| {
            cmds.items.appendAssumeCapacity(.{
                .stream_chunk = .{
                    .stream_entity = s.entity,
                    .bytes = chunk_bytes,
                },
            });
        }
        stage_chunks.deinit(allocator);
        stage_chunks = .empty;
        if (s.mark_draining) {
            cmds.items.appendAssumeCapacity(.{
                .stream_close = .{ .stream_entity = s.entity },
            });
        }
    }

    // Build the unit, transferring ownership of the cmds list +
    // txn + tenant_id. Same errdefer-then-clear pattern.
    var unit: ParkedUnit = .{
        .seq = seq,
        .deadline_ns = @intCast(std.time.nanoTimestamp() +
            @as(i128, @intCast(worker.commit_wait_timeout_ns))),
        .buffered = cmds,
        .txn = txn,
    };
    cmds = .{};
    errdefer ParkedUnit.deinit(allocator, (&unit)[0..1]);

    // Allocate tenant_id AFTER arming the unit errdefer so a dupe
    // failure leaves the unit's `.tenant_id` as default `&.{}`,
    // and ParkedUnit.deinit's `if (tenant_id.len > 0)` skips
    // freeing it (no double-free).
    unit.tenant_id = try allocator.dupe(u8, tenant_id);

    const ent = try worker.h2.reg.create(&worker.parked_units);
    errdefer worker.h2.reg.destroy(ent) catch {};
    try worker.h2.reg.set(ent, &worker.parked_units, ParkedUnit, unit);
    unit = .{}; // ownership transferred to the column
    return seq;
}

/// Gap 2.1 Phase E (refactored), effect-reification Phase 4.1: for
/// each kv-write event in `unit`'s BufferedCmds, scan the tenant's
/// subscription registry for `.kv` subscriptions whose `prefix`
/// matches; enqueue an `effect.SubscriptionFire` Msg onto the
/// worker's `msg_queue`. `dispatchSubscriptionFires` drains each
/// tick.
///
/// Called from the parked_units commit arm BEFORE
/// `BufferedCmds.releaseAll` so the kv_wake_broadcast Cmd payloads
/// are still readable. The release pass then consumes them via
/// `interpretCmd` (which broadcasts to other workers' KvWakeInbox).
///
/// Pre-4.1 this fn was called from `firePendingKvWakes`, which
/// also did the cross-worker broadcast in one pass. The 4.1 split
/// separates the two concerns: kv-react reads here, broadcast +
/// every other Cmd kind release through interpretCmd. The 4.0.b
/// per-kind helpers (`firePendingKvWakes` +
/// `transferStagedChunks`) collapsed away.
///
/// Leader-only by caller convention (this site only runs on the
/// worker that committed the original writeset).
pub fn fireKvReactSubscriptions(worker: anytype, unit: *ParkedUnit) !void {
    const slot = worker.node.tenant_files_map.get(unit.tenant_id) orelse return;
    const snap = slot.pinCurrent() orelse return;
    defer snap.release();
    if (snap.subscriptions.len == 0) return;

    const allocator = worker.allocator;
    for (snap.subscriptions) |sub| {
        const prefix = switch (sub.spec) {
            .kv => |k| k.prefix,
            else => continue,
        };
        for (unit.buffered.items.items) |cmd| switch (cmd) {
            .kv_wake_broadcast => |w| {
                if (!std.mem.startsWith(u8, w.key, prefix)) continue;
                std.log.info(
                    "rove-js kv-react queue: tenant={s} subscription={s} key={s} op={c}",
                    .{ unit.tenant_id, sub.name, w.key, w.op },
                );
                // Dup onto the payload; payload owns + frees these
                // strings via `SubscriptionFire.deinit` after the
                // fire completes (or on MsgQueue drop-on-shutdown).
                const tid = try allocator.dupe(u8, unit.tenant_id);
                errdefer allocator.free(tid);
                const name = try allocator.dupe(u8, sub.name);
                errdefer allocator.free(name);
                const path = try allocator.dupe(u8, sub.module_path);
                errdefer allocator.free(path);
                const key_dup = try allocator.dupe(u8, w.key);
                errdefer allocator.free(key_dup);

                var payload: effect_mod.msg.SubscriptionFire = .{
                    .tenant_id = tid,
                    .subscription_name = name,
                    .module_path = path,
                    .source = .{ .kv = .{ .key = key_dup, .op = w.op } },
                };
                effect_mod.enqueueMsg(&worker.msg_queue, .{ .subscription_fire = payload }) catch |err| {
                    payload.deinit(allocator);
                    std.log.warn(
                        "rove-js kv-react enqueueMsg (tenant={s}, sub={s}): {s}",
                        .{ unit.tenant_id, sub.name, @errorName(err) },
                    );
                    return err;
                };
            },
            // Other Cmd kinds (stream_chunk, stream_close,
            // http_fetch, respond) don't trigger kv-react — they
            // ride through interpretCmd in releaseAll.
            else => {},
        };
    }
}

// ── Msg inbox + dispatch ──────────────────────────────────────────────

/// Cross-thread enqueue parameters used by
/// `NodeState.enqueueSubscriptionFireForTenant` (cron sweeper, boot
/// loader). Borrowed slices — the cross-thread enqueue dups onto a
/// `PendingFireMessage` on the inbox; `drainSubFireInbox` then moves
/// those owned slices onto an `effect.SubscriptionFire` payload
/// (Phase 2B/2C: no per-tick dup on the worker side).
pub const SubscriptionFireQueueInput = struct {
    tenant_id: []const u8,
    subscription_name: []const u8,
    module_path: []const u8,
    source: SubscriptionFireSource,
};

// `enqueueSubscriptionFire` (the prior collection-creation helper) was
// retired in effect-reification Phase 2C. Every subscription origin
// now routes through `effect.enqueueMsg`:
// - cron / boot: cross-thread inbox → `drainSubFireInbox` →
//   `enqueueMsg` (move-semantics)
// - kv-react: `fireKvReactSubscriptions` → `enqueueMsg` (dup-on-payload)

/// Gap 2.1 Phase D: drain the worker's cross-thread
/// `sub_fire_inbox`, **moving** each `PendingFireMessage`'s owned
/// slices onto an `effect.SubscriptionFire` payload and enqueueing
/// via `effect.enqueueMsg`. Called once per worker tick (from
/// `serviceSubscriptionFires`); cheap when the inbox is empty (one
/// mutex try + length check).
///
/// Effect-reification Phase 2E: drain the worker's unified
/// cross-thread `msg_inbox`, moving each `effect.Msg` onto the
/// in-thread `msg_queue`. One drain function for every cross-thread
/// origin (cron + boot fires, fetch chunk / done / pipe_done events)
/// — the pre-2E pair (`drainSubFireInbox` + `drainFetchChunkInbox`)
/// collapsed into this. Producers built Msg variants on the way in
/// (NodeState.enqueueXxxForTenant); this fn is variant-agnostic.
///
/// Ownership: each Msg popped from the inbox carries owned slices.
/// On `enqueueMsg` success the queue owns them (drains via
/// `dispatchPendingMsgs`). On `error.Full` we `freeOwnedMsg` and
/// log — overflow drops are bounded by the cross-thread inbox's
/// rate and the in-thread queue's cap; the per-origin policy is
/// at-most-once for cron/boot (re-fire on next sweep) and at-most-
/// once for fetch (sender already accepted the upstream chunk —
/// loss surfaces as a fetch_done with mismatched byte counts).
pub fn drainMsgInbox(worker: anytype) void {
    const allocator = worker.allocator;
    var local: std.ArrayListUnmanaged(effect_mod.Msg) = .empty;
    defer local.deinit(allocator);
    worker.msg_inbox.drainInto(&local) catch |err| {
        std.log.warn("rove-js msg-inbox drain: {s}", .{@errorName(err)});
        for (local.items) |*m| effect_mod.freeOwnedMsg(allocator, m);
        return;
    };
    if (local.items.len == 0) return;
    for (local.items) |*m| {
        effect_mod.enqueueMsg(&worker.msg_queue, m.*) catch |err| {
            std.log.warn(
                "rove-js msg-inbox enqueueMsg (kind={s}): {s}",
                .{ @tagName(m.kind()), @errorName(err) },
            );
            // On overflow the Msg never reached the queue; free its
            // owned payload to avoid leak.
            effect_mod.freeOwnedMsg(allocator, m);
        };
    }
}

/// Worker-tick combined pass: drain the cross-thread Msg inbox into
/// the in-thread queue, then dispatch the queue. Called from the
/// workerMain loop on every tick; covers cross-thread producers
/// (boot via deployment_loader, cron via sweeper, FetchPool libcurl
/// threads) AND in-thread producers (kv-react, which `enqueueMsg`s
/// directly from `fireKvReactSubscriptions`).
pub fn serviceSubscriptionFires(worker: anytype) void {
    drainMsgInbox(worker);
    dispatchPendingMsgs(worker);
}

/// Worker-tick system: dequeue Msgs from `worker.msg_queue` (up to
/// `BATCH` per tick) and dispatch each by variant. Per-tick cap
/// bounds tail latency on the request hot path: a misbehaving
/// handler with many activations pending eats at most `BATCH` per
/// tick before yielding back to the h2 loop; remaining drain on
/// subsequent ticks.
///
/// Effect-reification Phase 2D: the unified dispatcher across every
/// migrated Msg variant — subscription fires (cron / boot / kv-react,
/// Phase 2B/C) and outbound HTTP events (chunk / done / pipe_done,
/// Phase 2D). Phases 2E-2F add send-callback / inbound-HTTP arms.
///
/// Re-entrant `enqueueMsg` calls during a dispatch append to the
/// queue's tail; the current tick's batch is capped at `BATCH` so
/// new entries process next tick (deferred dispatch).
pub fn dispatchPendingMsgs(worker: anytype) void {
    const BATCH: usize = 64;
    var fired: usize = 0;
    const allocator = worker.allocator;

    while (fired < BATCH) {
        const msg = worker.msg_queue.dequeue() orelse break;
        switch (msg) {
            .subscription_fire => |sf_const| {
                var sf = sf_const;
                fireSubscriptionActivation(
                    worker,
                    sf.tenant_id,
                    sf.subscription_name,
                    sf.module_path,
                    switch (sf.source) {
                        .cron => |c| SubscriptionFireSource{ .cron = .{ .fired_at_ns = c.fired_at_ns } },
                        .kv => |kv| SubscriptionFireSource{ .kv = .{ .key = kv.key, .op = kv.op } },
                        .boot => |b| SubscriptionFireSource{ .boot = .{ .deployment_id = b.deployment_id } },
                    },
                );
                sf.deinit(allocator);
                fired += 1;
            },
            .fetch_chunk => |ev_const| {
                // Phase 5 PR-1: single fetch activation kind. Every
                // event fires `on_chunk` against the handler; `event.final`
                // distinguishes the terminal event from intermediates.
                // Tape captures the chunk bytes (closes algebra §7
                // worklist #1).
                //
                // Slice 4-fetch-park: fireFetchEventActivation owns
                // the event — internal defer deinits it OR transfers
                // to worker.fetch_pending_durability for the park
                // branch. No external deinit needed.
                //
                // `docs/streaming-model.md` §7 item 1: bound fetch
                // refit. When `ev.bind`, route the chunk into the
                // calling chain's `onFetchChunk` resume instead of
                // firing a separate `fetch-<id>` activation. The
                // worker's bound-fetch registry maps `fetch_id →
                // entity`; lookup misses fall through to the
                // separate-chain path (registry already drained on
                // a prior terminal, or registration failed at
                // bind-call time — either way the chunk should
                // still tape via the unbound path).
                var ev = ev_const;
                if (ev.bind) {
                    if (worker.lookupBoundFetch(ev.fetch_id)) |held_ent| {
                        const final = ev.final;
                        // Copy the fetch_id BEFORE the resume call:
                        // the resume engines consume `ev` and free
                        // its slices on every exit path; reading
                        // `ev.fetch_id` afterward is use-after-free.
                        const fid_copy: ?[]u8 = if (final)
                            allocator.dupe(u8, ev.fetch_id) catch null
                        else
                            null;
                        // rove-library principle 1: dispatch by
                        // collection membership. The held entity's
                        // state IS where it lives:
                        //   - parked_continuations: first chunk on
                        //     a still-cont chain → resumeBoundFetchChain
                        //   - stream_data_out: subsequent chunk on a
                        //     chain that already cont→streamed →
                        //     resumeBoundFetchStream
                        //   - anything else (raft_pending_*, in
                        //     transition): defer one tick by
                        //     re-enqueueing the Msg at the back of
                        //     the queue (it'll re-arrive after the
                        //     pending move commits).
                        const server = worker.h2;
                        if (server.reg.isInCollection(held_ent, &worker.parked_continuations)) {
                            worker_drain.resumeBoundFetchChain(worker, held_ent, &ev);
                        } else if (server.reg.isInCollection(held_ent, &server.stream_data_out) or
                            server.reg.isInCollection(held_ent, &server.stream_response_in))
                        {
                            // Steady-state stream chain (stream_data_out)
                            // OR the brief post-commit window before h2's
                            // consumeStreamResponses ships headers + moves
                            // to stream_data_out (stream_response_in).
                            // resumeBoundFetchStream picks the right
                            // collection internally for component reads.
                            resumeBoundFetchStream(worker, held_ent, &ev);
                        } else {
                            // Transient state — entity is in some
                            // raft_pending_* awaiting commit. Drop
                            // for now (best-effort, like the
                            // existing wake_batch on a draining
                            // stream). Logging at info so an
                            // operator can spot it if a tenant's
                            // bound fetches ever start dropping in
                            // bulk.
                            std.log.info(
                                "rove-js bound-fetch: entity for fetch_id={s} mid-transition (not in parked_continuations or stream_data_out); dropping chunk",
                                .{ev.fetch_id},
                            );
                            components_mod.UpstreamFetchEvent.deinitItem(&ev, allocator);
                        }
                        if (fid_copy) |fid| {
                            worker.unregisterBoundFetch(fid);
                            allocator.free(fid);
                        }
                        fired += 1;
                        continue;
                    }
                    // Lookup miss: log + fall through to unbound path
                    // so the chunk still tapes.
                    std.log.info(
                        "rove-js bound-fetch: no held entity for fetch_id={s}; falling through to separate-chain dispatch",
                        .{ev.fetch_id},
                    );
                }
                worker_mod.fireFetchEventActivation(worker, &ev, null);
                fired += 1;
            },
            .send_callback => |sc_const| {
                // Phase 5 PR-2: chained dispatch — the customer's
                // next-hop handler runs because a previous handler
                // returned `__rove_next(path, {ctx})`. Producer is the
                // fetch-event `.continuation` arm (PR-2 lift); future
                // producers (`webhook.send.js` shim's onresult after
                // PR-2c) compose on this same Msg.
                var sc = sc_const;
                fireChainedActivation(worker, &sc);
                sc.deinit(allocator);
                fired += 1;
            },
            else => {
                std.log.warn(
                    "rove-js msg_queue: unexpected variant kind={s} (no dispatch arm yet)",
                    .{@tagName(msg.kind())},
                );
            },
        }
    }
}

/// Backward-compat alias: callers that explicitly named the
/// subscription-fire dispatcher continue to work. Both this and
/// `dispatchFetchEvents` route into the same unified
/// `dispatchPendingMsgs`; the second-to-call sees an empty queue and
/// is a no-op.
pub fn dispatchSubscriptionFires(worker: anytype) void {
    dispatchPendingMsgs(worker);
}

/// Backward-compat alias — see `dispatchSubscriptionFires`.
pub fn dispatchFetchEvents(worker: anytype) void {
    dispatchPendingMsgs(worker);
}
