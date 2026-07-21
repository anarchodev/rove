//! Streaming-resume engine + Msg-driven activation firers.
//!
//! Despite the file name, this covers the broader post-commit /
//! Msg-ingress machinery — beyond streaming proper it includes
//! every fire*Activation entry point and the Msg-queue dispatch:
//!
//!   - Stream lifecycle: `markStreamDraining`, `setStreamComponents`,
//!     `serviceParkedStreams`, `drainKvWakeInbox`, `matchEventsToWakes`,
//!     `resumeStream` — the wake → resume → ship-chunks loop.
//!   - Activation firers: `fireDisconnectActivation`,
//!     `fireSubscriptionActivation`, `fireSchedulerTick`,
//!     `fireDurableWakeActivation`, `fireChainedActivation`,
//!     `fireFetchEventActivation` — synchronous handler invocations
//!     from a Msg (no held socket). All are thin wrappers over the
//!     shared `firePrep` + `runFire` scaffold; per-firer behavior is
//!     a comptime `FinishSpec` (continuation/stream action,
//!     always-propose, tape capture) plus the Request each one
//!     synthesizes.
//!   - Commit-gated buffer: `StreamResumeStage`, `proposeForgetfulWrites`,
//!     `fireKvReactSubscriptions` + `unit.buffered.releaseAll` — the
//!     parked-unit commit-arm runtime `drainRaftPending` invokes for
//!     each unit when its raft seq lands.
//!   - Msg ingress + dispatch: `drainMsgInbox`,
//!     `serviceSubscriptionFires`, `dispatchPendingMsgs` (+ two
//!     aliases) — cross-thread inbox drain → in-thread queue
//!     drain → per-variant fire.
//!
//! The inbound WebSocket seam (chain establish/teardown, the
//! input gate, `serviceWsMessages` → `fireWsMessage` /
//! `fireWsDisconnect`) lives in `worker_ws.zig`; its commit-gated
//! write path calls back into `StreamResumeStage` +
//! `proposeForgetfulWrites` here.
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
const globals = @import("globals.zig");
const router_mod = @import("router.zig");
const Request = dispatcher_mod.Request;
const components_mod = @import("components.zig");
const chunk_spool_mod = @import("chunk_spool.zig");
const effect_mod = @import("effect/root.zig");
const raft_propose = @import("raft_propose.zig");
const panic_mod = @import("panic.zig");
const builtin_modules_mod = @import("builtin_modules.zig");
const deployment_cache = @import("deployment_cache.zig");

const worker_mod = @import("worker.zig");
const worker_drain = @import("worker_drain.zig");
const worker_ws = @import("worker_ws.zig");
const dispatch = @import("worker_dispatch.zig");
const bodies_mod = @import("rove-bodies");
const ParkedUnit = worker_mod.ParkedUnit;
const KvWakeOp = worker_mod.KvWakeOp;
const KvWakeEvent = worker_mod.KvWakeEvent;
const MAX_STREAM_ACTIVATIONS = worker_mod.MAX_STREAM_ACTIVATIONS;
const captureLogWithId = worker_mod.captureLogWithId;
const captureTapesWithActivation = worker_mod.captureTapesWithActivation;
const resolveDeployment = worker_mod.resolveDeployment;

// ── Stream lifecycle ──────────────────────────────────────────────────

/// Flag the stream's draining state via the entity's
/// StreamDraining component. Tolerant
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

/// Populate the four stream-side components on
/// the entity. This is the SOLE site that allocates
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
        const spine: []components_mod.KvArm = if (kv_prefixes.len > 0)
            try allocator.alloc(components_mod.KvArm, kv_prefixes.len)
        else
            &.{};
        errdefer if (kv_prefixes.len > 0) allocator.free(spine);
        var built: usize = 0;
        errdefer for (spine[0..built]) |arm| allocator.free(arm.prefix);
        for (kv_prefixes, 0..) |p, i| {
            spine[i] = .{ .prefix = try allocator.dupe(u8, p) };
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

// Stream state lives on the entity's components (set by
// `setStreamComponents` in streamRecordIfAnyAt / streamParkIfAny);
// there is no side-table cell. `Collection.deinit` invokes each
// component's deinit on shutdown, so no manual per-shutdown cleanup
// site is needed.

/// Per-tick driver for active streaming chains. For each
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
    // Empty stream_data_out → nothing to do.
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
        // Draining state lives on the entity's StreamDraining
        // component. Reads of chunks/wakes/chain identity come from
        // the four stream components.
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

        // Timer-due → stamp `timer_fired_ns` + advance next_wake_ns;
        // the wake-batch activation below fires from the fired state
        // (kv + timer unified). next_wake_ns is reset relative to now
        // (drift-on-each-fire, matching the existing pattern in
        // resumeStream's outcome handler at ~4472).
        if (wakes_comp.interval_ms > 0 and now_ns >= wakes_comp.next_wake_ns) {
            wakes_comp.timer_fired_ns = now_ns;
            wakes_comp.next_wake_ns = now_ns + wakes_comp.interval_ms * std.time.ns_per_ms;
        }

        // Any arm fired? Fire one wake_batch activation (drains the
        // fired kv arms + timer into `request.activation.wakes[]` —
        // fired PREFIXES).
        if (wakes_comp.anyFired()) {
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
        // that the initial chunks have shipped — UNLESS an in-flight
        // bound fetch is still feeding this stream. A chain opened via
        // `on.fetch({stream}) → stream.write()` in onChunk + `next()`
        // (the `__system/static` streamer — the streaming substrate,
        // `docs/architecture/routing-and-ingress.md`)
        // registers no timer/kv wake; its subsequent chunks arrive
        // through `resumeBoundFetchStream`, NOT a wake. Auto-closing the
        // instant the queue first drains races the next bound chunk and
        // truncates the response (the static-serve teardown bug). While
        // `BoundFetchCount.pending > 0` the feeding fetch hasn't sent its
        // `final` event, so stay idle and wait for the next chunk; the
        // final chunk's terminal arm sets `is_draining` (handled above),
        // which is what actually closes the stream.
        const pending_binds: u32 = blk: {
            const cnt = server.reg.get(p.ent, &server.stream_data_out, components_mod.BoundFetchCount) catch break :blk 0;
            break :blk cnt.pending;
        };
        if (pending_binds == 0 and wakes_comp.interval_ms == 0 and wakes_comp.kv_prefixes.len == 0) {
            try server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in);
            continue;
        }
        // No wake due yet — idle, waiting for either a kv match or
        // the timer.
    }
}

/// Drain the worker's `wake_inbox` of kv-write events. For every
/// stream entity (in one of the h2 stream-pipeline collections,
/// not draining), stamp `fired_at_ns` on every armed `kv_prefixes`
/// arm that prefixes the event's key (the fired-prefix contract: a match marks the
/// ARM fired; keys are never accumulated, so a burst of matches is
/// one re-stamp — nothing to overflow, nothing lost).
/// Events whose tenant_id matches no held stream are simply
/// dropped — the per-tenant scoping § 4.6 invariant lives at
/// REGISTRATION time (a cell only registers prefixes for its own
/// tenant), so a stale event against an old tenant just doesn't
/// match anything.
///
/// Sweeps the five h2 stream-pipeline collections in place. Empty
/// collections cost one length check each (no allocator pressure).
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
    // `on.kv`: `parked_continuations` carries
    // the same `StreamColl` Row (StreamWakes / ChainContext /
    // StreamDraining) as the five h2 stream collections, so a held
    // `next()` continuation armed with `on.kv` matches here too. Its
    // ring is serviced by `sweepParkedContinuations` (not
    // `serviceParkedStreams`), but the prefix-match accumulation is
    // identical. Listed last so a stream and a continuation never share
    // a column slice in one iteration.
    inline for (.{
        &server.stream_response_in,
        &server.stream_data_out,
        &server.stream_data_in,
        &server.stream_close_in,
        &server._stream_data_sending,
        &worker.parked_continuations,
    }) |coll| {
        const wakes_col = coll.column(components_mod.StreamWakes);
        const chains_col = coll.column(components_mod.ChainContext);
        const drain_col = coll.column(components_mod.StreamDraining);
        for (wakes_col, chains_col, drain_col) |*wakes, chain_ctx, drain| {
            if (drain.is_draining) continue;
            if (wakes.kv_prefixes.len == 0) continue;
            matchEventsToWakes(&events, wakes, chain_ctx);
        }
    }
}

/// Walk events oldest-first; stamp every armed prefix that matches an
/// event's key as fired (the fired-prefix contract). EVERY
/// matching arm fires — a key under two armed prefixes marks both.
/// No allocation, no accumulation: N matches on one arm are one
/// re-stamp (latest fire time wins), so nothing can overflow.
fn matchEventsToWakes(
    events: *std.ArrayListUnmanaged(KvWakeEvent),
    wakes: *components_mod.StreamWakes,
    chain_ctx: components_mod.ChainContext,
) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    for (events.items) |ev| {
        if (!std.mem.eql(u8, ev.tenant_id, chain_ctx.tenant_id)) continue;
        // §8.4 watch baseline (`on.kv`): a watch armed at `read_version`
        // fires only for a write strictly newer than the state its
        // arming handler read. `read_version == 0` is the unanchored
        // pre-`on.kv` stream path — fire on any prefix match. `maxInt`
        // event versions (producer couldn't read the clock) always pass.
        if (wakes.read_version != 0 and ev.write_version <= wakes.read_version) continue;
        for (wakes.kv_prefixes) |*arm| {
            if (std.mem.startsWith(u8, ev.key, arm.prefix)) {
                arm.fired_at_ns = now_ns;
            }
        }
    }
}

/// Run the next handler activation for a parked stream.
/// Structural twin of `resumeContinuation` — same dispatch surface
/// (re-enter `Dispatcher.runOutcome` with a synthesized `Request`),
/// divergent in the outcome-application tail.
///
/// TEA-framing:
///   - **Msg**:   `(wake_batch, entity in stream_data_out with
///                non-empty StreamChain.module_path AND
///                StreamWakes.anyFired())`.
///   - **prep**:  read four stream components on the entity; resolve
///                deployment; drain the fired arms (`drainFired`) into
///                the Request's wake_batch slice (fired prefixes —
///                the fired-prefix contract); build request body = `{ctx}` with
///                `.wake_batch` activation.
///   - **run**:   `dispatcher.runOutcome` (chain-tail txn).
///   - **apply (Cmd-list)**: switch on outcome:
///       • terminal → on read-only: append body to StreamChunks +
///         markStreamDraining immediately. On wrote: stage body
///         chunk + mark_draining=true on `BufferedSendKvOps`;
///         `proposeForgetfulWrites`'s parked unit applies them
///         from the commit arm (the commit-gated release rule,
///         `routing-and-ingress.md`).
///       • stream → update StreamChain.ctx_json + StreamWakes
///         (kv_prefixes / interval / next_wake) + increment
///         activation_count (eager — internal state). On read-only:
///         transfer chunks now. On wrote: stage chunks on the
///         parked unit; commit arm transfers them onto StreamChunks
///         after raft commits.
///       • continuation → 501 + markStreamDraining (`__rove_next`
///         from a stream-resume hop is out of scope).
///
/// The write path resumes `proposeForgetfulWrites` the txn
/// AND stage their chunks on the parked unit so the chunks reach the
/// wire only after raft commits. A fault arm discards both the txn
/// (rollback) and the staged chunks (`BufferedSendKvOps.deinit`).
/// Which Msg-tape the stream-family log records carry (per-capture
/// materialization; see `finishContResume`'s twin in worker_drain.zig
/// for why the order is part of the wire format).
const StreamTape = enum { wake, fetch };

inline fn streamTapes(worker: anytype, comptime tape: StreamTape, ctx: *const StreamFinishCtx) log_mod.TapePayloads {
    return switch (tape) {
        // A wake resume's Msg is the drained fired-watch
        // batch — tape it (+ readset/ctx) so the hop is replayable.
        // Guarded on the runtime kind: resumeStream only fires
        // `.wake_batch` today, but the activation param is runtime.
        .wake => if (ctx.act == .wake_batch)
            worker_mod.captureWakeBatchTapes(worker, ctx.readset, ctx.tape_body, ctx.wakes, "")
        else
            .{},
        .fetch => worker_mod.captureFetchChunkTapes(worker, ctx.readset, ctx.tape_body, ctx.tape_ev.?),
    };
}

/// Comptime per-site axes of `finishStreamResume` — everything else the
/// two stream-family sites do is identical.
const StreamFinishSpec = struct {
    /// Operator warn-log tag ("stream-resume" / "bound-fetch stream").
    site: []const u8,
    /// Invariant-violation site prefix ("resumeStream" /
    /// "resumeBoundFetchStream").
    panic_site: []const u8,
    /// Cancel sibling bound-fetch binds when the chain goes terminal.
    cancel_binds: bool,
    tape: StreamTape,
};

/// Runtime context for `finishStreamResume` (the stream-family sibling
/// of worker_drain's `ContFinishCtx`). All pointers borrow the caller's
/// locals for the duration of the call.
const StreamFinishCtx = struct {
    ent: rove.Entity,
    ws: *kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    readset: *tape_mod.Readset,
    chain_ctx: *components_mod.ChainContext,
    chain_st: *components_mod.StreamChain,
    chunks_st: *components_mod.StreamChunks,
    wakes_st: *components_mod.StreamWakes,
    request_id: u64,
    now_ns: i64,
    deployment_id: u64,
    wrote: bool,
    txn_owned: *bool,
    txn_done: *bool,
    /// Runtime activation source (`resumeStream` flips wake kinds;
    /// the bound-fetch site is always `.fetch_chunk`).
    act: log_mod.ActivationSource,
    pending_fetches: *std.ArrayListUnmanaged(globals.PendingFetch),
    /// Tape sources: `.fetch` reads `tape_body` + `tape_ev`; `.wake`
    /// reads `tape_body` (the `{"ctx":…}` envelope) + `wakes` (the
    /// drained fired-watch batch).
    tape_body: []const u8 = "",
    tape_ev: ?worker_mod.FetchEvent = null,
    wakes: []const components_mod.WakeEntry = &.{},
};

/// §2.2: the ONE outcome-finishing switch for the two
/// stream-family resume sites — `resumeStream` (timer/kv/send wakes on a
/// live stream) and `resumeBoundFetchStream` (bound-fetch chunks after
/// the cont→stream transition). Siblings: `finishContResume`
/// (worker_drain.zig) and `finishWsResume` (worker_ws.zig).
///
/// Arms: terminal-with-exception → rollback + drain + log; terminal-with-
/// writes → stage body + draining flag on the parked unit, propose via
/// `proposeForgetfulWrites` (commit-gated release, `routing-and-ingress.md`);
/// terminal-read-only → commit + flush + final chunk + drain;
/// continuation → 501 (stream→cont transition out of scope); stream →
/// stage/ship chunks + swap ctx/interval/kv-prefix registrations;
/// no-export probe → defined 500. Draining always via
/// `markStreamDrainingAnywhere` (it handles both the steady-state
/// `stream_data_out` home and the post-commit `stream_response_in`
/// stopover).
/// Read-only commits panic on failure (resumes run inside the chain
/// lease; `commitReadOnlyFire` is the out-of-lease exception).
fn finishStreamResume(
    worker: anytype,
    comptime spec: StreamFinishSpec,
    oc: *dispatcher_mod.RunOutcome,
    ctx: StreamFinishCtx,
) void {
    const allocator = worker.allocator;
    const server = worker.h2;
    const dep_id = ctx.deployment_id;
    const tid = ctx.chain_ctx.tenant_id;
    const corr = ctx.chain_ctx.correlation_id;
    const mpath = ctx.chain_st.module_path;
    switch (oc.*) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (comptime spec.cancel_binds) worker_mod.scanAndCancelBoundFetches(worker, ctx.ent);
            if (r.exception.len > 0) {
                ctx.txn.rollback() catch {};
                ctx.txn_done.* = true;
                markStreamDrainingAnywhere(server, ctx.ent);
                captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 500, .handler_error, r.console, r.exception, streamTapes(worker, spec.tape, &ctx), corr, r.tags, ctx.act, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (ctx.wrote) {
                // Terminal + writes — stage the body chunk + the draining
                // flag on the parked unit so they apply only after raft
                // commits (the commit-gated release rule,
                // `routing-and-ingress.md`): the parked_units
                // commit arm (via `transferStagedChunks`) is the single
                // release point; a raft fault during the commit-wait window
                // must not ship a terminal frame whose writes never landed.
                var stage: StreamResumeStage = .{ .entity = ctx.ent, .mark_draining = true };
                defer {
                    for (stage.chunks.items) |c| allocator.free(c);
                    stage.chunks.deinit(allocator);
                }
                if (r.body.len > 0) {
                    staged: {
                        const owned = allocator.dupe(u8, r.body) catch break :staged;
                        stage.chunks.append(allocator, owned) catch {
                            allocator.free(owned);
                            break :staged;
                        };
                        break :staged;
                    }
                    if (stage.chunks.items.len == 0) {
                        // Defined failure: never propagate out of a resume
                        // with the stream half-mutated, never silently drop
                        // the writes.
                        ctx.txn.rollback() catch {};
                        ctx.txn_done.* = true;
                        markStreamDrainingAnywhere(server, ctx.ent);
                        captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 500, .handler_error, r.console, r.exception, streamTapes(worker, spec.tape, &ctx), corr, r.tags, ctx.act, 0);
                        r.console = &.{};
                        r.exception = &.{};
                        return;
                    }
                }
                const lh_term = fireLogHeader(ctx.request_id, dep_id, @intCast(@max(@min(r.status, 599), 100)), ctx.act, mpath, corr);
                const fw_seq = proposeForgetfulWrites(worker, ctx.ws, ctx.txn, tid, &stage, ctx.pending_fetches, ctx.readset, lh_term) catch |perr| {
                    std.log.warn("rove-js " ++ spec.site ++ " (terminal + writes): propose failed: {s}", .{@errorName(perr)});
                    ctx.txn_owned.* = false;
                    ctx.txn_done.* = true;
                    // No commit gate to wait for — close the stream now so
                    // the customer sees a defined 500 rather than a
                    // half-open stream. The helper already freed
                    // `stage.chunks`; the defer is a no-op.
                    markStreamDrainingAnywhere(server, ctx.ent);
                    captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 500, .fault, r.console, r.exception, streamTapes(worker, spec.tape, &ctx), corr, r.tags, ctx.act, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                ctx.txn_owned.* = false;
                ctx.txn_done.* = true;
                // `markStreamDrainingAnywhere` does NOT fire here — the
                // commit arm flips it via `stage.mark_draining` strictly
                // after the body lands in StreamChunks. Until then the
                // stream stays alive; on commit the serviceParkedStreams
                // tick drains the chunk and closes (chunks-empty +
                // is_draining).
                ctx.chain_st.activation_count += 1;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, st, .ok, r.console, r.exception, streamTapes(worker, spec.tape, &ctx), corr, r.tags, ctx.act, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            // Clean read-only terminal: flush the body as one last chunk +
            // flag close_pending. Empty body = close immediately on the
            // next service tick.
            ctx.txn.commit() catch |e| panic_mod.invariantViolated(
                spec.panic_site ++ ".commit(terminal_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            ctx.txn_done.* = true;
            flushFireFetches(worker, ctx.pending_fetches);
            if (r.body.len > 0) {
                // Post-commit: never propagate (half-mutated chain state)
                // and never silently return — close loudly without the
                // final chunk if it can't be staged. tryAppend frees the
                // chunk on error — no free here.
                if (allocator.dupe(u8, r.body)) |owned| {
                    ctx.chunks_st.tryAppend(allocator, owned) catch |e| {
                        std.log.err("rove-js " ++ spec.site ++ ": terminal chunk append failed ({s}) — closing", .{@errorName(e)});
                    };
                } else |e| std.log.err("rove-js " ++ spec.site ++ ": terminal body dupe failed ({s}) — closing without it", .{@errorName(e)});
            }
            markStreamDrainingAnywhere(server, ctx.ent);
            ctx.chain_st.activation_count += 1;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, st, .ok, r.console, r.exception, streamTapes(worker, spec.tape, &ctx), corr, r.tags, ctx.act, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // Stream-resume → __rove_next: would transition the chain from
            // a stream into a one-shot continuation, which requires moving
            // the entity out of the stream pipeline and into
            // parked_continuations. Out of scope — a defined 501.
            cval.deinit(allocator);
            ctx.txn.rollback() catch {};
            ctx.txn_done.* = true;
            markStreamDrainingAnywhere(server, ctx.ent);
            captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 501, .handler_error, &.{}, &.{}, streamTapes(worker, spec.tape, &ctx), corr, &.{}, ctx.act, 0);
        },
        .stream => |*s2| {
            // stream + writes — stage `s2.chunks` on the parked unit so
            // they ship only after raft commits (§2 rule). The internal-
            // state updates below (ctx_json / interval / kv_prefixes /
            // activation_count) stay eager — the rule covers chunks
            // reaching the wire, not per-stream runtime state; handlers
            // re-read kv every activation so a fault leaving ctx ahead of
            // durable kv is recoverable by the customer.
            var stage: StreamResumeStage = .{ .entity = ctx.ent, .mark_draining = false };
            defer {
                for (stage.chunks.items) |c| allocator.free(c);
                stage.chunks.deinit(allocator);
            }
            // fw_seq: the propose seq in the wrote case, 0 read-only.
            var fw_seq: u64 = 0;
            if (ctx.wrote) {
                // Move s2.chunks → stage.chunks BEFORE the propose so a
                // propose failure frees them via the helper.
                if (s2.chunks.len > 0) {
                    stage.chunks.ensureUnusedCapacity(allocator, s2.chunks.len) catch {
                        // Defined failure — never appendAssumeCapacity
                        // into missing capacity.
                        s2.deinit(allocator);
                        ctx.txn.rollback() catch {};
                        ctx.txn_done.* = true;
                        markStreamDrainingAnywhere(server, ctx.ent);
                        captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 500, .handler_error, &.{}, &.{}, streamTapes(worker, spec.tape, &ctx), corr, &.{}, ctx.act, 0);
                        return;
                    };
                    for (s2.chunks) |c| stage.chunks.appendAssumeCapacity(c);
                    allocator.free(s2.chunks);
                    s2.chunks = &.{};
                }
                const lh_stream = fireLogHeader(ctx.request_id, dep_id, 200, ctx.act, mpath, corr);
                fw_seq = proposeForgetfulWrites(worker, ctx.ws, ctx.txn, tid, &stage, ctx.pending_fetches, ctx.readset, lh_stream) catch |perr| {
                    std.log.warn("rove-js " ++ spec.site ++ " (stream + writes): propose failed: {s}", .{@errorName(perr)});
                    // Helper already freed `stage.chunks` (the outer defer
                    // is now a no-op). Free what's left on the outcome
                    // struct (headers / ctx_json / kv_prefixes — the
                    // chunks slice is already `&.{}`).
                    s2.deinit(allocator);
                    ctx.txn_owned.* = false;
                    ctx.txn_done.* = true;
                    markStreamDrainingAnywhere(server, ctx.ent);
                    captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 500, .fault, &.{}, &.{}, streamTapes(worker, spec.tape, &ctx), corr, &.{}, ctx.act, 0);
                    return;
                };
                ctx.txn_owned.* = false;
                ctx.txn_done.* = true;
            } else {
                ctx.txn.commit() catch |e| panic_mod.invariantViolated(
                    spec.panic_site ++ ".commit(stream_ro)",
                    "err={s}",
                    .{@errorName(e)},
                );
                ctx.txn_done.* = true;
                flushFireFetches(worker, ctx.pending_fetches);
            }
            // Headers on subsequent hops are ignored (the stream's initial
            // response headers already shipped); free them.
            if (s2.headers) |h| allocator.free(h);
            s2.headers = null;
            // Ship read-only chunks immediately via the §9.4 cap-aware
            // enqueue (on the wrote path `s2.chunks` is already `&.{}` —
            // moved into `stage` above; this loop no-ops). Lossless: the
            // producer-pacing gate keeps the queue below the soft cap, so
            // the hard cap is only reachable if one chunk alone exceeds it
            // — close loudly, never silently drop. tryAppend owns/frees
            // the chunk on error.
            for (s2.chunks) |c| ctx.chunks_st.tryAppend(allocator, c) catch |e| {
                std.log.err("rove-js " ++ spec.site ++ ": chunk append failed ({s}) — closing", .{@errorName(e)});
                markStreamDrainingAnywhere(server, ctx.ent);
            };
            if (s2.chunks.len > 0) allocator.free(s2.chunks);
            s2.chunks = &.{};
            // Replace ctx + interval on the component (ownership
            // transfers from the descriptor).
            if (ctx.chain_st.ctx_json.len > 0) allocator.free(ctx.chain_st.ctx_json);
            ctx.chain_st.ctx_json = s2.ctx_json;
            s2.ctx_json = &.{};
            if (s2.interval_ms) |iv| {
                ctx.wakes_st.interval_ms = iv;
                ctx.wakes_st.next_wake_ns = ctx.now_ns + iv * std.time.ns_per_ms;
            } else {
                ctx.wakes_st.interval_ms = 0;
                ctx.wakes_st.next_wake_ns = std.math.maxInt(i64);
            }
            // Replace the StreamWakes kv-wake registration with whatever
            // the handler returned: free old arms, take ownership of the
            // new prefixes as unfired arms (the (tenant, prefix) registry
            // is a derived view recomputed on every match scan — no
            // unregister step). On OOM keep the old arms — the chain
            // stays armed with its previous watches rather than none.
            if (components_mod.armsFromPrefixes(allocator, s2.kv_prefixes)) |arms| {
                for (ctx.wakes_st.kv_prefixes) |arm| allocator.free(arm.prefix);
                if (ctx.wakes_st.kv_prefixes.len > 0) allocator.free(ctx.wakes_st.kv_prefixes);
                ctx.wakes_st.kv_prefixes = arms;
                s2.kv_prefixes = &.{};
            } else |_| {
                std.log.warn("rove-js " ++ spec.site ++ ": wake rearm alloc failed; keeping prior arms", .{});
                for (s2.kv_prefixes) |p| allocator.free(p);
                if (s2.kv_prefixes.len > 0) allocator.free(s2.kv_prefixes);
                s2.kv_prefixes = &.{};
            }
            ctx.chain_st.activation_count += 1;
            captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 200, .ok, &.{}, &.{}, streamTapes(worker, spec.tape, &ctx), corr, &.{}, ctx.act, fw_seq);
        },
        // Only `.inbound_headers` / `.inbound_chunk` activations produce
        // these; stream resumes never dispatch as one. Defined failure.
        .no_onheaders, .no_onchunk => {
            ctx.txn.rollback() catch {};
            ctx.txn_done.* = true;
            markStreamDrainingAnywhere(server, ctx.ent);
            captureLogWithId(worker, tid, ctx.request_id, "POST", mpath, "", dep_id, ctx.now_ns, 500, .handler_error, &.{}, &.{}, streamTapes(worker, spec.tape, &ctx), corr, &.{}, ctx.act, 0);
        },
    }
}

fn resumeStream(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    activation: log_mod.ActivationSource,
) !void {
    _ = sid;
    _ = sess; // Reserved for cross-collection resolves; see
    // resumeContinuation's signature for the call-site shape we'll
    // mirror when the activation may not start from `stream_data_out`.

    const allocator = worker.allocator;
    // Chain identity + chunks + wakes ride on
    // the entity's components. Draining-state is encoded
    // by `StreamDraining.is_draining` — `resumeStream` only fires
    // for non-draining entities (the caller filters); the terminal /
    // cap-hit branches call `markStreamDraining(server, ent)`.
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
    const body = try synthCtxBody(allocator, chain_st.ctx_json);
    defer allocator.free(body);
    const spath = try std.fmt.allocPrint(allocator, "/{s}", .{path});
    defer allocator.free(spath);

    // Heap-allocate the txn so its pointer can park on a
    // parked_units `ParkedUnit.txn` if the hop wrote.
    // Same stable-pointer pattern as resumeContinuation +
    // fireDisconnectActivation.
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
    readset.js_engine_version = dispatcher_mod.JS_ENGINE_VERSION;
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    // wake_batch activation: drain the fired arms (fired
    // PREFIXES, fire-time order) so nothing re-fires next sweep;
    // resumeStream owns the slice + each entry's `prefix` for the
    // dispatch's lifetime.
    var batch_owned: []components_mod.WakeEntry = &.{};
    defer if (batch_owned.len > 0) {
        for (batch_owned) |*w| w.deinit(allocator);
        allocator.free(batch_owned);
    };
    if (activation == .wake_batch) {
        batch_owned = wakes_st.drainFired(allocator) catch
            return error.ResumeWakeDrain;
    }
    // A resumed stream handler re-arms its
    // wakes via `on.*` and emits more output via `stream.write()`, just
    // like the first hop. Wire both accumulators so `finishResponse`
    // rebuilds the internal Stream descriptor (chunks + kv/timer wakes)
    // that the `.stream` arm below re-parks.
    var pending_wakes: std.ArrayListUnmanaged(globals.PendingWakeReg) = .empty;
    defer {
        for (pending_wakes.items) |*pw| pw.deinit(allocator);
        pending_wakes.deinit(allocator);
    }
    // Commit-gated fetch effects: the resumed hop's `http.fetch`es
    // (webhook.send inline fire, blob.put). Write arms commit-gate
    // them via proposeForgetfulWrites; read-only commits flush
    // directly; error arms free via the defer.
    var pending_fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (pending_fetches.items) |*pf| pf.deinit(allocator);
        pending_fetches.deinit(allocator);
    }
    var stream_chunks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stream_chunks.items) |ch| allocator.free(ch);
        stream_chunks.deinit(allocator);
    }
    const request: Request = .{
        .arena_mode = worker_mod.arenaModeFor(worker, inst.id, tc.snap.deployment_id, path),
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        // `activation` is a runtime source (wake_batch / send_callback /
        // other stream-wake kinds) — build the payload arm for wake_batch,
        // fall back to the payload-less arm for the rest.
        .activation = if (activation == .wake_batch)
            .{ .wake_batch = .{ .wakes = batch_owned } }
        else
            dispatcher_mod.Activation.fromSource(activation),
        .trace = .{
            .readset = &readset,
            .request_id = request_id,
            .correlation_id = chain_ctx.correlation_id,
        },
        .plan = .{ .limiter = &worker.limiter, .instance_id = inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = inst.platform },
        .effects = .{
            .pending_wakes = &pending_wakes,
            .pending_stream_chunks = &stream_chunks,
            .pending_fetches = &pending_fetches,
        },
    };
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker_mod.runResume(worker, inst, tc, bc, txn, &ws, request, &budget, path) catch {
        txn.rollback() catch {};
        txn_done = true;
        markStreamDraining(server, ent);
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, &.{}, activation, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    var oc = run_oc;
    finishStreamResume(worker, .{
        .site = "stream-resume",
        .panic_site = "resumeStream",
        .cancel_binds = false,
        .tape = .wake,
    }, &oc, .{
        .ent = ent,
        .ws = &ws,
        .txn = txn,
        .readset = &readset,
        .tape_body = body,
        .wakes = batch_owned,
        .chain_ctx = chain_ctx,
        .chain_st = chain_st,
        .chunks_st = chunks_st,
        .wakes_st = wakes_st,
        .request_id = request_id,
        .now_ns = now_ns,
        .deployment_id = tc.snap.deployment_id,
        .wrote = wrote,
        .txn_owned = &txn_owned,
        .txn_done = &txn_done,
        .act = activation,
        .pending_fetches = &pending_fetches,
    });
}

/// Upstream bound-fetch streaming (`docs/architecture/routing-and-ingress.md`):
/// bound-fetch chunk arriving on an entity that already transitioned
/// cont→stream. Sibling of `resumeStream` — same stream-chain
/// machinery, but the activation kind is `.fetch_chunk` (carrying
/// the chunk bytes/seq/done payload on the Request) and the dispatch
/// targets the module's `onFetchChunk` named export via the
/// first-class `fn_override`.
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
    const body = synthCtxBody(allocator, chain_st.ctx_json) catch return;
    defer allocator.free(body);
    // Custom `name:` override (matches resumeBoundFetchChain's
    // first-chunk handling) — else the conventional fetch export
    // (onFetchResult / onFetchChunk / onFetchDone, handler-shape.md §3).
    // First-class resume target (decisions.md §4.5) — no synthetic
    // `?fn=` query, and the path stays the real module path.
    const fn_name: []const u8 = ev.resolvedExport();
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return;
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
    readset.js_engine_version = dispatcher_mod.JS_ENGINE_VERSION;
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };

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

    // A bound-fetch chunk handler streaming a
    // frame back via `stream.write()` + `next()` re-parks the stream —
    // wire the chunk accumulator for `finishResponse`'s bridge.
    var stream_chunks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stream_chunks.items) |ch| allocator.free(ch);
        stream_chunks.deinit(allocator);
    }
    // Commit-gated fetch effects: see resumeStream — same accumulator,
    // same release discipline.
    var pending_fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (pending_fetches.items) |*pf| pf.deinit(allocator);
        pending_fetches.deinit(allocator);
    }

    // The fetch result is this activation's Msg (an input — L3) → tape it so the
    // fetch_chunk is replayable. Fed to `captureFetchChunkTapes` at the capture
    // sites below.
    const fetch_ev: worker_mod.FetchEvent = .{
        .fetch_id = ev.fetch_id,
        .seq = ev.seq,
        .byte_offset = ev.byte_offset,
        .bytes = ev.bytes,
        .headers = ev.fetch_headers orelse "",
        .final = ev.final,
        .terminal_status = if (ev.final) ev.terminal_status else 0,
        .terminal_ok = if (ev.final) ev.terminal_ok else false,
        .body_truncated = if (ev.final) ev.body_truncated else false,
        .export_name = fn_name, // record the resolved export ({on} / onFetch*) — G3
    };
    const req: Request = .{
        .arena_mode = worker_mod.arenaModeFor(worker, inst.id, tc.snap.deployment_id, path),
        .method = "POST",
        .path = spath,
        .body = body,
        .fn_override = fn_name,
        .is_system_module = builtin_modules_mod.isBuiltinPath(path),
        .activation = .{ .fetch_chunk = .{
            .id = ev.fetch_id,
            .seq = ev.seq,
            .byte_offset = ev.byte_offset,
            .bytes = ev.bytes,
            .headers = ev.fetch_headers,
            .final = ev.final,
            .terminal_status = if (ev.final) ev.terminal_status else 0,
            .terminal_ok = if (ev.final) ev.terminal_ok else false,
            .body_truncated = if (ev.final) ev.body_truncated else false,
        } },
        .activation_entity = ent,
        .activation_fetches_pending = fetches_pending,
        .trace = .{
            .readset = &readset,
            .request_id = request_id,
            .correlation_id = chain_ctx.correlation_id,
        },
        .plan = .{ .limiter = &worker.limiter, .instance_id = inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = inst.platform },
        .trampolines = .{
            .resume_if_bound = &@TypeOf(worker.*).resumeIfBoundTrampoline,
            .resume_if_bound_ctx = @ptrCast(worker),
            .blob_write = &@TypeOf(worker.*).blobWriteTrampoline,
            .blob_seal = &@TypeOf(worker.*).blobSealTrampoline,
            .blob_session_ctx = @ptrCast(worker),
            .cancel_fetch = &@TypeOf(worker.*).cancelFetchTrampoline,
            .cancel_fetch_ctx = @ptrCast(worker),
        },
        .effects = .{
            .pending_stream_chunks = &stream_chunks,
            .pending_fetches = &pending_fetches,
        },
    };

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    var oc = worker_mod.runResume(worker, inst, tc, bc, txn, &ws, req, &budget, path) catch {
        txn.rollback() catch {};
        txn_done = true;
        markStreamDrainingAnywhere(server, ent);
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, worker_mod.captureFetchChunkTapes(worker, &readset, body, fetch_ev), chain_ctx.correlation_id, &.{}, .fetch_chunk, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    finishStreamResume(worker, .{
        .site = "bound-fetch stream",
        .panic_site = "resumeBoundFetchStream",
        .cancel_binds = true,
        .tape = .fetch,
    }, &oc, .{
        .ent = ent,
        .ws = &ws,
        .txn = txn,
        .readset = &readset,
        .chain_ctx = chain_ctx,
        .chain_st = chain_st,
        .chunks_st = chunks_st,
        .wakes_st = wakes_st,
        .request_id = request_id,
        .now_ns = now_ns,
        .deployment_id = tc.snap.deployment_id,
        .wrote = wrote,
        .txn_owned = &txn_owned,
        .txn_done = &txn_done,
        .act = .fetch_chunk,
        .pending_fetches = &pending_fetches,
        .tape_body = body,
        .tape_ev = fetch_ev,
    });
}

// ── Activation firers ───────────────────────────────────────────────────
//
// Every fire*Activation below (and the WS pair in `worker_ws.zig`)
// shares one prep + run + apply choreography; the per-firer behavior
// is the `FinishSpec` axes plus the Request each one synthesizes.
// `firePrep` owns the prep block (deployment pin, txn, writeset,
// readset, request-id mint); `runFire` owns the run + outcome switch.

/// Synthesize a continuation resume's request body: the `next({ctx})`
/// payload as the `{"ctx":<ctx_json>}` envelope that `installRequest`
/// (`globals.zig`) lifts back to `request.ctx`. The SINGLE producer of the
/// shape every WS / SSE / wake / continuation / durable-wake resume emits —
/// kept paired with the one `liftThreadedCtx` reader so the two can't drift
/// (decisions.md §4.9; the divergence that motivated Endpoint A was ~14
/// copies of this format string). `ctx_json` is JSON text embedded verbatim
/// (`"{}"` / `"null"` for none / a `msg`/`ctx` payload). Caller owns the result.
pub fn synthCtxBody(allocator: std.mem.Allocator, ctx_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{ctx_json});
}

/// The `request.ctx` a bound-FETCH resume observes (decisions.md §4.14): the
/// fetch's OWN ctx (`fetch_json` — its `{ctx}` option, or a platform door's
/// result) when it carried one, else the held chain's `next({ctx})` memory
/// (`chain_json`). One deterministic rule on both transports — a WS fetch
/// resume uses the fetch's ctx (not the chain ctx) when the fetch DID
/// carry one, and a no-ctx fetch still threads the
/// connection's `next()` state. Args are JSON text ("null" when absent).
pub fn fetchResumeCtx(fetch_json: []const u8, chain_json: []const u8) []const u8 {
    if (fetch_json.len > 0 and !std.mem.eql(u8, fetch_json, "null")) return fetch_json;
    if (chain_json.len > 0) return chain_json;
    return "null";
}

/// Synthesize an effect-RESULT delivery body: `{"ctx":{result, context}}` —
/// the shape the `send_callback` hoist flattens onto `request.body`/`.status`
/// (metadata → `request.activation`, `context` → `request.ctx`). Used by a
/// bound effect's `on_result` hop AND a §6.4 held-sync resume (the held
/// handler's threaded ctx fills `context`), so both read one way. Args are
/// JSON text. Caller owns the result.
pub fn synthResultBody(allocator: std.mem.Allocator, result_json: []const u8, context_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"ctx\":{{\"result\":{s},\"context\":{s}}}}}", .{ result_json, context_json });
}

/// Prep state shared by every connectionless fire. Build with
/// `firePrep`; `deinit` releases everything not explicitly handed
/// off (`runFire` flips `txn_owned`/`txn_done` when txn ownership
/// transfers to the parked unit on a successful propose).
pub const FirePrep = struct {
    dep: worker_drain.ChainDeployment,
    txn: *kv_mod.KvStore.TrackedTxn,
    txn_owned: bool = true,
    txn_done: bool = false,
    ws: kv_mod.WriteSet,
    readset: tape_mod.Readset,
    now_ns: i64,
    request_id: u64,

    pub fn deinit(p: *FirePrep, allocator: std.mem.Allocator) void {
        if (!p.txn_done) p.txn.rollback() catch {};
        if (p.txn_owned) allocator.destroy(p.txn);
        p.ws.deinit();
        p.readset.deinit();
        p.dep.tc.release();
    }
};

/// Build the shared prep. Returns null (after a warn) when the
/// tenant/deployment can't be resolved or the txn can't open — the
/// caller skips the activation (the best-effort posture all fires
/// share; the producer's own retry/sweep re-fires where one exists).
pub fn firePrep(
    worker: anytype,
    tenant_id: []const u8,
    module_path: []const u8,
    comptime site: []const u8,
) ?FirePrep {
    const allocator = worker.allocator;
    var dep = resolveDeployment(worker, allocator, tenant_id, module_path) catch |err| {
        std.log.warn(
            "rove-js " ++ site ++ ": tenant={s} module={s} resolveDeployment failed: {s}; skipping",
            .{ tenant_id, module_path, @errorName(err) },
        );
        return null;
    };
    // Heap-allocate the txn so the pointer stays stable when
    // ownership transfers to the parked unit (propose path).
    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch {
        dep.tc.release();
        return null;
    };
    txn.* = dep.inst.kv.beginTrackedImmediate() catch {
        allocator.destroy(txn);
        dep.tc.release();
        return null;
    };
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    var rs_init = tape_mod.Readset.init(allocator, now_ns, @bitCast(now_ns));
    rs_init.js_engine_version = dispatcher_mod.JS_ENGINE_VERSION;
    return .{
        .dep = dep,
        .txn = txn,
        .ws = kv_mod.WriteSet.init(allocator),
        .readset = rs_init,
        .now_ns = now_ns,
        .request_id = blk: {
            const tl = worker.tenant_logs.get(dep.inst.id) orelse break :blk 0;
            break :blk tl.id_minter.nextRequestId() catch 0;
        },
    };
}

/// What a `.continuation` return does, per firer.
const ContAction = enum {
    /// Deinit silently (a disconnect hop has nowhere to resume).
    drop,
    /// Warn — held continuations aren't expressible from this origin
    /// (v1); customers compose multi-step via webhook.send on_result.
    warn,
    /// Treat as a bug in our own module: warn, roll back (writes
    /// included), skip the log record entirely.
    rollback_silent,
    /// Enqueue the named module as a chained SendCallback hop on the
    /// next tick (bounded recursion via the dispatch BATCH cap),
    /// inheriting this chain's correlation_id.
    enqueue,
};
const StreamAction = enum { drop, warn, rollback_silent };

/// The per-firer behavior axes of `runFire`'s outcome switch.
/// Comptime so each firer compiles its own lean switch.
const FinishSpec = struct {
    /// Activation tag on log records + propose LogHeaders.
    act: log_mod.ActivationSource,
    /// Warn/panic-site label, e.g. "subscription-fire".
    site: []const u8,
    on_cont: ContAction,
    on_stream: StreamAction,
    /// durable-wake: cleanup deletes are pre-injected, so every
    /// outcome proposes — even a handler that wrote nothing.
    always_propose: bool = false,
    /// What a read-only `.continuation` return does with the txn:
    /// commit (chained/fetch posture) vs rollback (disconnect/
    /// subscription posture); both end a read-only txn.
    readonly_cont_commits: bool = false,
    /// Which Msg-tape every log record carries (see `fireTapes`):
    /// `.activation` (fetch_chunk — the upstream chunk bytes),
    /// `.callback` (send_callback — the `{"ctx":…}` body envelope),
    /// or `.none` for kinds whose Msg needs no dedicated
    /// capture here.
    tape: FireTape = .none,
};

/// The Msg-tape a connectionless fire records (the fire-family sibling
/// of worker_drain's `ContTape`).
const FireTape = enum { none, activation, callback };

/// The LogHeader every propose path ships. Also used by the WS seam
/// (`worker_ws.zig`) with its own activation tags.
pub fn fireLogHeader(
    request_id: u64,
    deployment_id: u64,
    status: u16,
    act: log_mod.ActivationSource,
    path: []const u8,
    corr: ?[]const u8,
) log_mod.LogHeader {
    return .{
        .request_id = request_id,
        .deployment_id = deployment_id,
        .duration_ns = 0,
        .status = status,
        .outcome = .ok,
        .activation = act,
        .method = "POST",
        .path = path,
        .host = "",
        .correlation_id = corr orelse "",
    };
}

/// Tape payloads for one log record. Fresh per call —
/// `captureLogWithId` takes ownership of the byte allocations.
/// `.callback` records the fire's whole body envelope (the callee
/// outcome) plus the resolved export; `.activation`
/// records the input bytes as `activation_bytes` (fetch chunks).
fn fireTapes(
    worker: anytype,
    comptime tape: FireTape,
    readset: *tape_mod.Readset,
    body: []const u8,
    activation_bytes: []const u8,
    export_name: []const u8,
) log_mod.TapePayloads {
    return switch (tape) {
        .none => .{},
        .activation => captureTapesWithActivation(worker, readset, body, activation_bytes),
        .callback => worker_mod.captureSendCallbackTapes(worker, readset, body, export_name),
    };
}

/// Commit a read-only fire txn. kvexp `NotChainHead` (surfaced as
/// `error.Conflict`) is an EXPECTED race here, not an invariant: the
/// txn opened while another activation's propose was still in flight
/// on the same tenant and read through its uncommitted overlay
/// (`saw_speculation`), so kvexp refuses to commit it ahead of its
/// chain predecessor. Commit-or-panic is sound only when every activation
/// sits in the same H2 request collection (the per-tenant dispatch
/// lease serializes them); connectionless fires run outside that
/// collection, so a fire can land inside a propose's quorum window —
/// a chained hop one tick after its parent is the easy repro.
/// Nothing escapes a connectionless fire pre-commit, so there is
/// nothing to commit-gate: roll back and let the producer's re-fire
/// path (cron sweep, owed sweep, scheduler tick) cover any skipped
/// work — the `fireWsDisconnect` posture. Any other commit error is
/// a real infallibility violation.
fn commitReadOnlyFire(p: *FirePrep, comptime site: []const u8) void {
    p.txn.commit() catch |e| switch (e) {
        error.Conflict => p.txn.rollback() catch {},
        else => panic_mod.invariantViolated(site, "err={s}", .{@errorName(e)}),
    };
    p.txn_done = true;
}

/// Run the handler + apply its outcome — the shared tail of every
/// connectionless fire. `log_path` is the module path on log records
/// (no leading slash); `corr` must match `req.trace.correlation_id`;
/// `label` identifies the firer in warn messages (name / module /
/// tenant); `activation_bytes` feeds tape capture when `spec.tape ==
/// .activation` (fetch chunk payloads) — pass "" otherwise (a
/// `.callback` tape reads `req.body` + `req.fn_override` instead).
pub fn runFire(
    worker: anytype,
    p: *FirePrep,
    req: Request,
    comptime spec: FinishSpec,
    log_path: []const u8,
    corr: ?[]const u8,
    label: []const u8,
    activation_bytes: []const u8,
) void {
    const allocator = worker.allocator;
    const tenant_id = p.dep.inst.id;
    const dep_id = p.dep.tc.snap.deployment_id;

    // Commit-gated fetch effects: every fire origin gets an `http.fetch`
    // accumulator so a fetch issued from a wake / subscription /
    // chained activation (`__system/webhook_fire`'s deferred fire, a
    // customer `webhook.send` from an on_result handler) is not
    // silently dropped. Write-path fires hand
    // the list to `proposeForgetfulWrites` (commit-gated
    // `Cmd.http_fetch`); read-only commits flush directly post-commit.
    // Error / rollback paths free via the defer (the chain never
    // fires — at-least-once recovery is the producer's own wake).
    var pending_fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (pending_fetches.items) |*pf| pf.deinit(allocator);
        pending_fetches.deinit(allocator);
    }
    var req_w = req;
    if (req_w.effects.pending_fetches == null) req_w.effects.pending_fetches = &pending_fetches;
    // Known-churny handlers skip the doomed bump attempt (the module
    // identity is the same log_path key the inbound path uses).
    req_w.arena_mode = worker_mod.arenaModeFor(worker, tenant_id, dep_id, log_path);

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    const run_oc = worker_mod.runResume(worker, p.dep.inst, p.dep.tc, p.dep.bc, p.txn, &p.ws, req_w, &budget, log_path) catch {
        worker_mod.noteChurnyOutcome(worker, tenant_id, dep_id, log_path);
        p.txn.rollback() catch {};
        p.txn_done = true;
        captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 500, .handler_error, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, &.{}, spec.act, 0);
        return;
    };

    const wrote = spec.always_propose or p.ws.ops.items.len > 0;
    var oc = run_oc;
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                // Surface connectionless-fire exceptions on stderr too —
                // the log record alone made a failing cron/wake
                // handler invisible to an operator tailing the node.
                std.log.warn(
                    "rove-js " ++ spec.site ++ " ({s}): handler exception: {s}",
                    .{ label, r.exception },
                );
                p.txn.rollback() catch {};
                p.txn_done = true;
                captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 500, .handler_error, r.console, r.exception, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, r.tags, spec.act, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            // A connectionless fire has no caller to see its status —
            // a 4xx/5xx (e.g. the missing-export 404 backstop) would
            // otherwise be visible only in the captured log record.
            if (st >= 400) {
                std.log.warn(
                    "rove-js " ++ spec.site ++ " ({s}): terminal status={d} body={s}",
                    .{ label, st, r.body },
                );
            } else {
                std.log.debug(
                    "rove-js " ++ spec.site ++ " ({s}): terminal status={d} wrote={} body_len={d}",
                    .{ label, st, wrote, r.body.len },
                );
            }
            if (wrote) {
                const lh = fireLogHeader(p.request_id, dep_id, st, spec.act, log_path, corr);
                const fw_seq = proposeForgetfulWrites(worker, &p.ws, p.txn, tenant_id, null, &pending_fetches, &p.readset, lh) catch |perr| {
                    std.log.warn("rove-js " ++ spec.site ++ " ({s}): propose failed: {s}", .{ label, @errorName(perr) });
                    p.txn_owned = false; // helper rolled back + destroyed the txn
                    p.txn_done = true;
                    captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 500, .fault, r.console, r.exception, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, r.tags, spec.act, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                p.txn_owned = false;
                p.txn_done = true;
                captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, st, .ok, r.console, r.exception, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, r.tags, spec.act, fw_seq);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            commitReadOnlyFire(p, spec.site ++ ".commit(terminal)");
            flushFireFetches(worker, &pending_fetches);
            captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, st, .ok, r.console, r.exception, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, r.tags, spec.act, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            defer cval.deinit(allocator);
            switch (comptime spec.on_cont) {
                .drop => {},
                .warn => std.log.warn(
                    "rove-js " ++ spec.site ++ " ({s}): __rove_next from this origin is a no-op (v1)",
                    .{label},
                ),
                .rollback_silent => {
                    std.log.warn("rove-js " ++ spec.site ++ " ({s}): unexpected __rove_next return (no-op)", .{label});
                    p.txn.rollback() catch {};
                    p.txn_done = true;
                    return;
                },
                .enqueue => {
                    worker.node.router.enqueueChainedDispatchForTenant(
                        tenant_id,
                        cval.path,
                        cval.ctx_json,
                        cval.fn_name,
                        corr,
                    ) catch |err| std.log.warn(
                        "rove-js " ++ spec.site ++ " ({s}): chained dispatch enqueue failed: {s}",
                        .{ label, @errorName(err) },
                    );
                },
            }
            if (wrote) {
                const lh = fireLogHeader(p.request_id, dep_id, 200, spec.act, log_path, corr);
                const fw_seq = proposeForgetfulWrites(worker, &p.ws, p.txn, tenant_id, null, &pending_fetches, &p.readset, lh) catch |perr| {
                    std.log.warn("rove-js " ++ spec.site ++ " ({s}): cont-return propose failed: {s}", .{ label, @errorName(perr) });
                    p.txn_owned = false;
                    p.txn_done = true;
                    captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 500, .fault, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, cval.tags, spec.act, 0);
                    return;
                };
                p.txn_owned = false;
                p.txn_done = true;
                captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 200, .ok, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, cval.tags, spec.act, fw_seq);
                return;
            }
            if (comptime spec.readonly_cont_commits) {
                commitReadOnlyFire(p, spec.site ++ ".commit(cont)");
                flushFireFetches(worker, &pending_fetches);
            } else {
                p.txn.rollback() catch {};
                p.txn_done = true;
            }
            captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 200, .ok, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, cval.tags, spec.act, 0);
        },
        .stream => |*s2| {
            s2.deinit(allocator);
            switch (comptime spec.on_stream) {
                .drop => {},
                .warn => std.log.warn(
                    "rove-js " ++ spec.site ++ " ({s}): __rove_stream from this origin is a no-op (v1)",
                    .{label},
                ),
                .rollback_silent => {
                    std.log.warn("rove-js " ++ spec.site ++ " ({s}): unexpected __rove_stream return (no-op)", .{label});
                    p.txn.rollback() catch {};
                    p.txn_done = true;
                    return;
                },
            }
            if (wrote) {
                const lh = fireLogHeader(p.request_id, dep_id, 200, spec.act, log_path, corr);
                const fw_seq = proposeForgetfulWrites(worker, &p.ws, p.txn, tenant_id, null, &pending_fetches, &p.readset, lh) catch |perr| {
                    std.log.warn("rove-js " ++ spec.site ++ " ({s}): stream-return propose failed: {s}", .{ label, @errorName(perr) });
                    p.txn_owned = false;
                    p.txn_done = true;
                    captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 500, .fault, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, &.{}, spec.act, 0);
                    return;
                };
                p.txn_owned = false;
                p.txn_done = true;
                captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 200, .ok, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, &.{}, spec.act, fw_seq);
                return;
            }
            commitReadOnlyFire(p, spec.site ++ ".commit(stream)");
            flushFireFetches(worker, &pending_fetches);
            captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 200, .ok, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, &.{}, spec.act, 0);
        },
        // Only `.inbound_headers` / `.inbound_chunk` activations
        // produce these; connectionless fires never dispatch as one.
        // Defined failure.
        .no_onheaders, .no_onchunk => {
            p.txn.rollback() catch {};
            p.txn_done = true;
            captureLogWithId(worker, tenant_id, p.request_id, "POST", log_path, "", dep_id, p.now_ns, 500, .handler_error, &.{}, &.{}, fireTapes(worker, spec.tape, &p.readset, req.body, activation_bytes, req_w.fn_override orelse ""), corr, &.{}, spec.act, 0);
        },
    }
}

/// Commit-gated fetch effects: submit a read-only fire's accumulated
/// fetches once its txn committed. Connection-scoped (`on.fetch`)
/// entries drop — a fire never holds a connection, so they're inert
/// by the handler-shape scope rule (mirrors `finalizeBatch`'s
/// non-held drop and `proposeForgetfulWrites`' filter on the write
/// path). On enqueue failure the entries stay on the list for the
/// caller's defer to free.
fn flushFireFetches(
    worker: anytype,
    fetches: *std.ArrayListUnmanaged(globals.PendingFetch),
) void {
    const allocator = worker.allocator;
    if (fetches.items.len == 0) return;
    var keep: usize = 0;
    for (fetches.items) |pf_const| {
        var pf = pf_const;
        if (pf.connection_scoped) {
            pf.deinit(allocator);
            continue;
        }
        fetches.items[keep] = pf;
        keep += 1;
    }
    fetches.items.len = keep;
    if (keep == 0) return;
    worker.node.enqueuePendingFetches(fetches.items) catch |err| {
        std.log.warn(
            "rove-js fire fetch flush: enqueuePendingFetches failed: {s} ({d} fetch(es) dropped)",
            .{ @errorName(err), fetches.items.len },
        );
        return; // caller's defer frees
    };
    // Ownership transferred to the engine queue.
    fetches.clearRetainingCapacity();
}

/// Streaming handlers (`docs/architecture/effects-and-handlers.md`): client
/// disconnect on a held stream.
/// h2's `serverStreamClose` routes the entity to `response_out`
/// (FIN/RST observed) without our drain-then-close path firing —
/// `cleanupResponses` notices the populated StreamChain on the
/// entity and calls this before destroying it.
///
/// TEA-framing:
///   - **Msg**:   `(client-disconnect, entity in response_out with
///                non-empty StreamChain.module_path)`.
///   - **prep**:  read ChainContext + StreamChain; resolveDeployment;
///                build request body = `{ctx}` with `.disconnect`
///                activation.
///   - **run**:   `dispatcher.runOutcome` (the writes commit
///                asynchronously via `proposeForgetfulWrites` since
///                there's no entity awaiting commit).
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
/// (no manual cleanup site needed).
pub fn fireDisconnectActivation(worker: anytype, ent: rove.Entity) void {
    const allocator = worker.allocator;
    const server = worker.h2;
    // Entity has a stream chain iff StreamChain.module_path
    // is non-empty — component presence is the membership test.
    const chain_st = server.reg.get(ent, &server.response_out, components_mod.StreamChain) catch return;
    if (chain_st.module_path.len == 0) return;
    const chain_ctx = server.reg.get(ent, &server.response_out, components_mod.ChainContext) catch return;
    std.log.info(
        "rove-js stream-disconnect: tenant={s} corr={s} activations={d}",
        .{ chain_ctx.tenant_id, chain_ctx.correlation_id orelse "(none)", chain_st.activation_count },
    );

    const path = chain_st.module_path;
    var p = firePrep(worker, chain_ctx.tenant_id, path, "stream-disconnect") orelse return;
    defer p.deinit(allocator);

    const body = synthCtxBody(allocator, chain_st.ctx_json) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return;
    defer allocator.free(spath);

    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .activation = .disconnect,
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = chain_ctx.correlation_id },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    // The handler's return shape is moot — the socket is closed
    // (`.drop` on both non-terminal arms). Writes still commit
    // asynchronously so observable side effects (kv
    // state, `_send/owed/*`, §4.5 wakes) materialize.
    runFire(worker, &p, request, .{
        .act = .disconnect,
        .site = "stream-disconnect",
        .on_cont = .drop,
        .on_stream = .drop,
    }, path, chain_ctx.correlation_id, chain_ctx.tenant_id, "");
}

/// Source payload for a subscription_fire activation.
/// One variant per `SubscriptionEntry.Spec`. Borrowed slices —
/// caller (the firing site) owns the bytes for
/// the duration of `fireSubscriptionActivation`.
/// Canonical definition lives in `dispatcher.zig` (next to `Request`,
/// which carries it). Aliased here so this module's callers and the
/// `worker.SubscriptionFireSource` re-export keep working.
pub const SubscriptionFireSource = dispatcher_mod.SubscriptionFireSource;

/// Fire a subscription handler as a fresh chain
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
/// Errors return `void` — the caller is best-effort (apply-time
/// hook, boot fire). Failures log + skip the activation.
/// handler-shape.md §3: the conventional named export a `_subscriptions/`
/// fire dispatches to, by trigger source. Lets one module split its
/// boot / kv-react handling into distinct exports instead of one
/// `default` that branches on `request.activation.source.kind`.
fn subscriptionExport(source: SubscriptionFireSource) []const u8 {
    return switch (source) {
        .kv => "onSubscription",
    };
}

pub fn fireSubscriptionActivation(
    worker: anytype,
    tenant_id: []const u8,
    subscription_name: []const u8,
    module_path: []const u8,
    source: SubscriptionFireSource,
    /// durable-kv-subscriptions: the `_sub/dirty/{name}` marker this
    /// fire retires. Injected as a delete into the fire's writeset
    /// BEFORE the handler runs (the durable-wake cleanup pattern), so
    /// the clear commits atomically with the handler's effects — and
    /// same-tenant serialization makes the plain delete safe (no CAS:
    /// a later write's marker-set is ordered after this delete and
    /// re-arms).
    cleanup_key: []const u8,
) void {
    const allocator = worker.allocator;
    var p = firePrep(worker, tenant_id, module_path, "subscription-fire") orelse return;
    defer p.deinit(allocator);

    p.txn.delete(cleanup_key) catch |err| {
        std.log.warn("rove-js kv-react ({s}/{s}): marker txn.delete failed: {s}", .{ tenant_id, subscription_name, @errorName(err) });
        return; // marker survives -> sweep re-fires
    };
    p.ws.addDelete(cleanup_key) catch |err| {
        std.log.warn("rove-js kv-react ({s}/{s}): marker ws.addDelete failed: {s}", .{ tenant_id, subscription_name, @errorName(err) });
        return;
    };

    // Subscription chains start fresh — empty ctx, fresh
    // correlation_id. (The handler can pass ctx forward via its
    // own kv state if it wants persistent chain state across
    // fires; the platform doesn't carry any.)
    const body = synthCtxBody(allocator, "{}") catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Mint a fresh correlation_id for this chain origin. Format:
    // `sub-{name-prefix}-{request_id-hex}` — name-scoped + unique
    // enough to dedup in the replay UX. Truncated to keep length
    // bounded.
    var corr_buf: [80]u8 = undefined;
    const name_prefix_len: usize = @min(subscription_name.len, 32);
    const corr_full = std.fmt.bufPrint(
        &corr_buf,
        "sub-{s}-{x:0>16}",
        .{ subscription_name[0..name_prefix_len], p.request_id },
    ) catch corr_buf[0..0];

    // Named-export dispatch by trigger source (handler-shape.md §3):
    // a kv-react fire lands in `onSubscription`.
    // The handler never branches on `request.activation.source.kind`.
    // A missing conventional export is the fail-loud 404 backstop.
    // Recurrence (`cron(spec, target)`) names its own target via the
    // durable scheduler — not this path. First-class target
    // (decisions.md §4.5) — no synthetic query.

    // Synthesize the Request carrying the subscription source union
    // (the variant IS the activation payload).
    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .fn_override = subscriptionExport(source),
        .activation = .{ .subscription_fire = .{ .name = subscription_name, .source = source } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    // The marker delete must land even for a read-only handler.
    runFire(worker, &p, req, .{
        .act = .subscription_fire,
        .site = "subscription-fire",
        .on_cont = .warn,
        .on_stream = .warn,
        .always_propose = true,
    }, module_path, corr_full, subscription_name, "");
}

/// §2.6 durable-wake: fire the baked `__system/scheduler_tick`
/// for one tenant. Structural twin of `fireSubscriptionActivation`
/// but: (1) the module is the node-level baked `__system/scheduler_tick`
/// (so `is_system_module` ⇒ it may call the capability-scoped
/// `__rove_set_wake` / `__rove_fire_wake`); (2) it installs the
/// durable-wake trampolines — `set_wake` → THIS tenant's slot,
/// `fire_wake` → the router; (3) no boot-marker injection.
/// `scheduler_tick` writes no kv of its own (the per-entry deletes
/// ride with each fired target's writeset via `__rove_fire_wake`), so
/// its writeset is normally empty → empty commit.
///
/// Fired inline by `durable_wake.sweepDurableWakes` on the
/// partition-owner worker (steady state, when `next_wake_ns` is due)
/// and by the post-commit bootstrap hook (P2). Errors log + skip —
/// the next sweep / promotion re-fires. `scheduler_tick` is our own
/// module and always returns terminal; a continuation/stream return
/// is treated as a bug (rolled back + logged).
pub fn fireSchedulerTick(worker: anytype, tenant_id: []const u8) void {
    const allocator = worker.allocator;
    const module_path = "__system/scheduler_tick";
    var p = firePrep(worker, tenant_id, module_path, "scheduler_tick") orelse return;
    defer p.deinit(allocator);

    const body = allocator.dupe(u8, "{\"ctx\":{}}") catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    var corr_buf: [48]u8 = undefined;
    const corr_full = std.fmt.bufPrint(&corr_buf, "sched-{x:0>16}", .{p.request_id}) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .{ .subscription_fire = .{ .name = "__scheduler_tick", .source = null } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
        .trampolines = .{
            .set_wake = &deployment_cache.TenantSlot.setWakeTrampoline,
            .set_wake_ctx = @ptrCast(p.dep.tc.slot),
            .fire_wake = &@TypeOf(worker.*).fireWakeTrampoline,
            .fire_wake_ctx = @ptrCast(worker),
        },
    };
    // `scheduler_tick` is our own module and always returns terminal;
    // a continuation/stream return is a bug (`.rollback_silent`).
    runFire(worker, &p, req, .{
        .act = .subscription_fire,
        .site = "scheduler_tick",
        .on_cont = .rollback_silent,
        .on_stream = .rollback_silent,
    }, module_path, corr_full, tenant_id, "");
}

// ── blob compose door (`docs/architecture/blob-write-recipes.md` §4) ─────────────

const COMPOSE_URL_PREFIX = "http://rove-compose.internal/";

pub fn isComposeUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, COMPOSE_URL_PREFIX);
}

/// The prompt-compose trigger: `blob.seal` emitted a post-commit fetch
/// Cmd at `rove-compose.internal/{sid}`; `tryDoorFetch` routes it here
/// instead of libcurl. Fire `__system/blob_compose` for the sealing
/// tenant with the Cmd's ctx — the builtin assembles the recipe rows
/// and hands the payload to blob.put (whose on_result flips the recipe
/// and chains to the customer's `{on}`). Deliberately moot-on-loss:
/// every failure here just logs and leaves the sealed meta row for the
/// materializer, so nothing in this function may be load-bearing.
pub fn fireBlobCompose(worker: anytype, pf_in: globals.PendingFetch) void {
    var pf = pf_in;
    defer pf.deinit(worker.allocator);
    const allocator = worker.allocator;
    const module_path = "__system/blob_compose";
    std.log.info("rove-js blob_compose: door fired tenant={s} url={s}", .{ pf.tenant_id, pf.url });

    var p = firePrep(worker, pf.tenant_id, module_path, "blob_compose") orelse return;
    defer p.deinit(allocator);

    const ctx_json = if (pf.ctx_json.len > 0) pf.ctx_json else "null";
    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{ctx_json}) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    var corr_buf: [48]u8 = undefined;
    const corr_full = std.fmt.bufPrint(&corr_buf, "compose-{x:0>16}", .{p.request_id}) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        // durable_wake shape so the Cmd's ctx surfaces as `request.ctx`
        // in the builtin (the webhook_fire convention — subscription
        // fires carry no per-fire payload).
        .activation = .{ .durable_wake = .{
            .id = "blob_compose",
            .key = "",
            .scheduled_at_ns = 0,
            .msg_json = ctx_json,
        } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    runFire(worker, &p, req, .{
        .act = .durable_wake,
        .site = "blob_compose",
        .on_cont = .rollback_silent,
        .on_stream = .rollback_silent,
    }, module_path, corr_full, pf.tenant_id, "");
}

/// §2.6 durable-wake: dispatch one due `_sched/by_time` entry's
/// `target` handler as a `durable_wake` activation. Structural twin of
/// `fireSubscriptionActivation` but: (1) it injects the entry's
/// `cleanup_keys` as deletes into the handler's writeset BEFORE the
/// handler runs, so the entry's removal commits atomically with the
/// handler's effects (exactly-once on the normal path; a crash between
/// fire and commit leaves the keys for a boot/promotion re-fire — the
/// at-least-once *firing* contract); (2) the activation surface is
/// `request.activation = { kind:"durable_wake", id, key,
/// scheduled_at_ns, msg }`. No held socket; writes commit forgetfully.
///
/// Injecting the deletes means `wrote` is always true, so the cleanup
/// always proposes through raft even for a target that itself writes
/// nothing. Errors log + skip — the entry survives for the next
/// tick (its `_sched` keys weren't committed).
const DurableTarget = struct { module: []const u8, method: ?[]const u8 };

/// Split a durable-wake target `"module.method"` into its module path and
/// optional export (handler-shape.md §2.4). The method suffix is
/// recognized ONLY when the module part ends in `.mjs`/`.js` — so a bare
/// `"reports.mjs"` module, a slash path `"jobs/reminder"`, or a `__system/`
/// baked module stays whole (fires `default`), and only the documented
/// `"reports.mjs.weekly"` form carries an export. This rule is unambiguous
/// (a `.mjs` extension never gets mistaken for a method) and MUST match the
/// sim's `wake()` split in `src/replay/rewind_test.mjs`.
fn splitDurableTarget(target: []const u8) DurableTarget {
    const last_dot = std.mem.lastIndexOfScalar(u8, target, '.') orelse
        return .{ .module = target, .method = null };
    const head = target[0..last_dot];
    const tail = target[last_dot + 1 ..];
    if (tail.len > 0 and (std.mem.endsWith(u8, head, ".mjs") or std.mem.endsWith(u8, head, ".js")))
        return .{ .module = head, .method = tail };
    return .{ .module = target, .method = null };
}

test "splitDurableTarget: module.method only when module ends .mjs/.js" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    const expect = std.testing.expect;

    // Documented form → split.
    const a = splitDurableTarget("reports.mjs.weekly");
    try expectEqualStrings("reports.mjs", a.module);
    try expectEqualStrings("weekly", a.method.?);
    const a2 = splitDurableTarget("jobs.mjs.send");
    try expectEqualStrings("jobs.mjs", a2.module);
    try expectEqualStrings("send", a2.method.?);
    const a3 = splitDurableTarget("lib/util.js.run");
    try expectEqualStrings("lib/util.js", a3.module);
    try expectEqualStrings("run", a3.method.?);

    // Bare `.mjs` module (no method) — the extension is NOT a method.
    const b = splitDurableTarget("reports.mjs");
    try expectEqualStrings("reports.mjs", b.module);
    try expect(b.method == null);
    const b2 = splitDurableTarget("jobs/reminder.mjs");
    try expectEqualStrings("jobs/reminder.mjs", b2.module);
    try expect(b2.method == null);

    // No dot / slash path / baked system module → whole module, default.
    const c = splitDurableTarget("jobs/reminder");
    try expectEqualStrings("jobs/reminder", c.module);
    try expect(c.method == null);
    const c2 = splitDurableTarget("__system/cron_tick");
    try expectEqualStrings("__system/cron_tick", c2.module);
    try expect(c2.method == null);

    // A dotted module name that isn't `.mjs`/`.js` stays whole.
    const d = splitDurableTarget("my.config");
    try expectEqualStrings("my.config", d.module);
    try expect(d.method == null);
}

fn fireDurableWakeActivation(worker: anytype, dw: *effect_mod.msg.DurableWake) void {
    const allocator = worker.allocator;
    const tenant_id = dw.tenant_id;
    // A `schedule`/`cron` target may name `"module.method"` — fire the
    // named export instead of `default` (handler-shape.md §2.4).
    // Both verbs land here (`cron` re-dispatches through `schedule({in:0},
    // target)`), so this is the one split site. Mirrors the sim's `wake()`.
    const dt = splitDurableTarget(dw.module_path);
    const module_path = dt.module;
    var p = firePrep(worker, tenant_id, module_path, "durable-wake") orelse return;
    defer p.deinit(allocator);

    // The customer target reads `request.activation.msg`; also surface
    // the msg as `request.body = {"ctx": <msg>}` for uniformity with
    // the other fire paths (`JSON.parse(request.body).ctx`).
    const body = synthCtxBody(allocator, dw.msg_json) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Inject the fired entry's `_sched/` deletes BEFORE the handler
    // runs — they commit atomically with the handler's effects.
    // This is why the spec sets `always_propose`: the writeset is
    // never empty, and even a continuation/stream return still
    // proposes (the cleanup must land).
    for (dw.cleanup_keys) |k| {
        p.txn.delete(k) catch |err| {
            std.log.warn("rove-js durable-wake ({s}/{s}): cleanup txn.delete failed: {s}", .{ tenant_id, dw.id, @errorName(err) });
            return;
        };
        p.ws.addDelete(k) catch |err| {
            std.log.warn("rove-js durable-wake ({s}/{s}): cleanup ws.addDelete failed: {s}", .{ tenant_id, dw.id, @errorName(err) });
            return;
        };
    }

    var corr_buf: [80]u8 = undefined;
    const id_prefix_len: usize = @min(dw.id.len, 32);
    const corr_full = std.fmt.bufPrint(&corr_buf, "wake-{s}-{x:0>16}", .{ dw.id[0..id_prefix_len], p.request_id }) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        // `"module.method"` → fire the named export; a bare module → null
        // → the conventional `default` (rpc_dispatch.defaultExportForKind).
        .fn_override = dt.method,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .{ .durable_wake = .{
            .id = dw.id,
            .key = dw.key,
            .scheduled_at_ns = dw.scheduled_at_ns,
            .msg_json = dw.msg_json,
        } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };

    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s}/{s}", .{ tenant_id, dw.id }) catch tenant_id;
    runFire(worker, &p, req, .{
        .act = .durable_wake,
        .site = "durable-wake",
        .on_cont = .warn,
        .on_stream = .warn,
        .always_propose = true,
    }, module_path, corr_full, label, "");
}

/// Dispatch a chained handler activation produced by
/// `__rove_next` from a fetch handler (and from the
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
/// the retry sweep, when a webhook leaves an `_send/owed/`
/// marker behind).
fn fireChainedActivation(
    worker: anytype,
    sc: *effect_mod.msg.SendCallback,
) void {
    const allocator = worker.allocator;
    const tenant_id = sc.tenant_id;
    const module_path = sc.module_path;
    var p = firePrep(worker, tenant_id, module_path, "chained-dispatch") orelse return;
    defer p.deinit(allocator);

    const ctx_src: []const u8 = if (sc.ctx_json.len > 0) sc.ctx_json else "null";
    const body = synthCtxBody(allocator, ctx_src) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Inherit correlation_id when the cont carried one (chained from
    // a fetch handler — preserves the parent fetch's chain identity).
    // Otherwise mint `chain-<request_id>` so the hop self-identifies
    // in the replay tape.
    var corr_buf: [80]u8 = undefined;
    const corr_full: []const u8 = if (sc.correlation_id) |c|
        c
    else
        std.fmt.bufPrint(&corr_buf, "chain-{x:0>16}", .{p.request_id}) catch corr_buf[0..0];

    // First-class target for the named-export case (decisions.md
    // §4.5); default-export when fn_name is null/empty (parseDispatch
    // treats an empty override as unset).
    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .fn_override = sc.fn_name,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .send_callback,
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
    };
    // `.enqueue`: chained-from-chained re-enqueues another
    // SendCallback hop on the next tick (bounded recursion via the
    // dispatch BATCH cap), inheriting the same correlation_id.
    // `.tape = .callback`: the body envelope IS this hop's Msg — the
    // callee outcome for an on_result delivery, the bare threaded ctx
    // for an internal chained hop — recorded (with the resolved
    // export) so the activation is replayable.
    runFire(worker, &p, req, .{
        .act = .send_callback,
        .site = "chained-dispatch",
        .on_cont = .enqueue,
        .on_stream = .warn,
        .readonly_cont_commits = true,
        .tape = .callback,
    }, module_path, corr_full, module_path, "");
}

// ── Commit-gated post-propose ─────────────────────────────────────────

/// A resume-hop's staged chunks +
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
    /// architecture/websockets.md (piece D): when non-null, the staged `chunks`
    /// are outbound WebSocket frames destined for this conn entity (NOT
    /// `stream_data_out` HTTP DATA). The commit arm then builds one
    /// `ws_send` Cmd per chunk (opcode taken from `ws_opcodes`, kept
    /// parallel to `chunks` by the producer), and — if `mark_draining`
    /// — appends a trailing close frame (opcode 8) instead of a
    /// `stream_close`. Staging the frames on the unit (rather than
    /// emitting `ws_send_in` inline) is what gates a WRITING frame's
    /// output on its writeset commit (batch-of-1 durability). The
    /// `ws_opcodes` list is owned by the producer (`fireWsMessage`);
    /// its u8 values are copied into the Cmds, not transferred.
    ws_conn: ?rove.Entity = null,
    ws_opcodes: std.ArrayListUnmanaged(u8) = .empty,
};

/// Propose a write batch that nobody is waiting on. The
/// txn rides a `ParkedUnit.txn` field that the parked_units sweep
/// in `drainRaftPending` commits at the seq — same gate as the
/// entity-backed path's `pending_txns[seq]`, just routed through
/// the unit drain so we don't need an entity in `raft_pending`.
/// On commit, the unit's §4.5 kv-wakes fire (the existing
/// `firePendingKvWakes` iterates at the same point).
///
/// Used by `fireDisconnectActivation` — the socket is gone, so
/// we can't gate the held-response on commit, but we still want
/// the writes + their side effects to land durably.
///
/// The optional `stage` parameter
/// is the commit-gated streaming-chunks payload. When non-null,
/// it carries an entity in `stream_data_out` + the chunks that the
/// `resumeStream` arm would otherwise have appended eagerly. The
/// parked_units commit arm transfers them onto the entity's
/// `StreamChunks` (and, if `stage.mark_draining`, sets the
/// terminal-draining flag) AFTER the txn commits — closing
/// the pre-commit chunk leak (the commit-gated release rule,
/// `routing-and-ingress.md`). Disconnect,
/// subscription, and fetch-event callers pass `null`; they're
/// either entity-less or already disconnect-tolerant.
///
/// Commit-gated fetch effects: the optional `fetches_opt` parameter is
/// the commit-gated `http.fetch` payload for forgetful fires. When
/// non-null, each accumulated PendingFetch becomes a `Cmd.http_fetch`
/// on the parked unit, released by `interpretCmd` strictly after raft
/// commits — the same gate the inbound path's `finalizeBatch` applies.
/// Connection-scoped (`on.fetch`) entries are dropped (a fire never
/// holds a connection, so they're inert by the handler-shape scope
/// rule). On success ownership moves to the unit and the list is
/// cleared; on propose failure the entries stay on the list for the
/// caller's defer to free (the chain never fires).
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
    fetches_opt: ?*std.ArrayListUnmanaged(globals.PendingFetch),
    /// Pass `&readset` (the per-activation Readset) so this
    /// activation's readset rides the raft entry as the type-0
    /// envelope's `rs_bytes` section. `null` for
    /// callers without a per-request readset (none today — every
    /// activation in this file owns one). Serialization failures
    /// log + pass empty so the propose still goes through.
    readset_opt: ?*const tape_mod.Readset,
    /// Per-activation LogHeader. Stamped into the readset
    /// blob so any follower can rebuild the customer
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
    // LogHeader stamped into it) wrapped as the 1-item
    // readset list the anchor envelope's rs_bytes section expects
    // (readset replication + multi-readset aggregation,
    // `docs/architecture/effects-and-handlers.md`). Best-effort: any failure logs and we
    // propose with empty rs_bytes — the chain just doesn't get
    // readset-replicated for this entry.
    const rs_bytes: []u8 = if (readset_opt) |rs|
        tape_mod.encodeSingleReadset(allocator, rs, log_header_opt) catch |err| blk: {
            std.log.warn(
                "rove-js proposeForgetfulWrites: encodeSingleReadset tenant={s}: {s}",
                .{ tenant_id, @errorName(err) },
            );
            break :blk &.{};
        }
    else
        &.{};
    defer if (rs_bytes.len > 0) allocator.free(rs_bytes);
    // An EMPTY writeset here is the read-side speculation BARRIER (the
    // idiom-0 dual, shipWsFrames' Conflict fallback): the activation read
    // un-durable chain state, so its staged output must gate on the chain
    // committing. `proposeBatch` would skip an empty writeset (seq 0 — no
    // propose, nothing to park on); `proposeWriteSet` always proposes.
    const prop_res = if (writeset.ops.items.len == 0)
        raft_propose.proposeWriteSet(worker, writeset, tenant_id, rs_bytes)
    else
        raft_propose.proposeBatch(worker, writeset, tenant_id, rs_bytes);
    const seq = (prop_res catch |err| {
        txn.rollback() catch {};
        allocator.destroy(txn);
        return err;
    }).seq;

    // Build the parked unit's
    // BufferedCmds list directly. Variants:
    //
    //   - kv_wake_broadcast — one per writeset op (the §4.5 fan-out
    //     + kv-react fire); interpretCmd broadcasts to subscribed
    //     stream watchers + the unit's kv-react walk reads them
    //     before releaseAll consumes.
    //   - stream_chunk      — one per staged chunk (commit-gated
    //     stream output to `stage_opt.entity`).
    //   - stream_close      — single Cmd if `stage_opt.mark_draining`
    //     (terminal+writes resume arm); flips the draining flag
    //     strictly after the chunks land.
    //
    // Total Cmd capacity: writes + chunks + (1 close if any).
    var cmds: effect_mod.cmd.BufferedCmds = .{};
    errdefer cmds.deinit(allocator);

    // P5(a): filter the fire's accumulated fetches BEFORE sizing the
    // Cmd list — connection-scoped (`on.fetch`) registrations are
    // inert from a fire origin (no held connection to bind to).
    var fetches_count: usize = 0;
    if (fetches_opt) |fetches| {
        var keep: usize = 0;
        for (fetches.items) |pf_const| {
            var pf = pf_const;
            if (pf.connection_scoped) {
                pf.deinit(allocator);
                continue;
            }
            fetches.items[keep] = pf;
            keep += 1;
        }
        fetches.items.len = keep;
        fetches_count = keep;
    }

    const chunks_count = stage_chunks.items.len;
    const close_count: usize = if (stage_opt) |s| (if (s.mark_draining) 1 else 0) else 0;
    const cap = writeset.ops.items.len + chunks_count + close_count + fetches_count;
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
        if (s.ws_conn) |conn| {
            // architecture/websockets.md: stage outbound WS frames as commit-
            // gated `ws_send` Cmds (opcode per chunk, parallel to the
            // bytes). `mark_draining` ⇒ append a trailing close frame
            // (opcode 8) AFTER the data so wire order is data-then-close.
            for (stage_chunks.items, 0..) |chunk_bytes, i| {
                const op: u8 = if (i < s.ws_opcodes.items.len) s.ws_opcodes.items[i] else 1;
                cmds.items.appendAssumeCapacity(.{
                    .ws_send = .{ .conn_entity = conn, .opcode = op, .bytes = chunk_bytes },
                });
            }
            stage_chunks.deinit(allocator);
            stage_chunks = .empty;
            if (s.mark_draining) {
                cmds.items.appendAssumeCapacity(.{
                    .ws_send = .{ .conn_entity = conn, .opcode = 8, .bytes = &.{} },
                });
            }
        } else {
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
    }

    // P5(a): transfer the surviving fetches one-for-one into
    // commit-gated `Cmd.http_fetch` entries. `interpretCmd` submits
    // each to the fetch engine strictly after the unit's writeset
    // commits — the fetch + its marker share one commit gate, the
    // same contract `webhook.send`'s inline fire gets on the inbound
    // path. Clear the source list so the caller's defer no-ops.
    if (fetches_opt) |fetches| {
        if (fetches.items.len > 0) {
            for (fetches.items) |pf| {
                cmds.items.appendAssumeCapacity(.{ .http_fetch = pf });
            }
            fetches.clearRetainingCapacity();
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

/// For
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
/// The two concerns are separated: kv-react reads here, broadcast +
/// every other Cmd kind release through interpretCmd.
///
/// Leader-only by caller convention (this site only runs on the
/// worker that committed the original writeset).
pub const SUB_DIRTY_PREFIX = "_sub/dirty/";

/// durable-kv-subscriptions: the post-commit IMMEDIATE-fire arm (the
/// latency path). Prefix matching already happened at WRITE time — the
/// kv binding injected the durable `_sub/dirty/{name}` marker into the
/// writer's own writeset — so this arm just watches the committed unit
/// for those marker puts and marks the sub pending in the worker's
/// in-memory set. The set is bounded (≤ one entry per tenant+sub, no
/// matter the write volume) and DROPPABLE: the durable marker +
/// `sweepDirtySubscriptions` are the at-least-once guarantee; losing
/// an insert here only costs latency.
pub fn fireKvReactSubscriptions(worker: anytype, unit: *ParkedUnit) void {
    for (unit.buffered.items.items) |cmd| switch (cmd) {
        .kv_wake_broadcast => |w| {
            if (!std.mem.startsWith(u8, w.key, SUB_DIRTY_PREFIX)) continue;
            if (w.op != 'p') continue; // the fire's own marker delete
            markSubPending(worker, unit.tenant_id, w.key[SUB_DIRTY_PREFIX.len..]);
        },
        // Other Cmd kinds (stream_chunk, stream_close, http_fetch,
        // respond) ride through interpretCmd in releaseAll.
        else => {},
    };
}

/// Insert (tenant, sub) into the pending set. Key = "tenant\x1fname"
/// (owned). Best-effort by design: on OOM the durable marker is still
/// set and the sweep re-discovers it.
fn markSubPending(worker: anytype, tenant_id: []const u8, name: []const u8) void {
    const allocator = worker.allocator;
    const key = std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ tenant_id, name }) catch return;
    const gop = worker.pending_sub_fires.getOrPut(allocator, key) catch {
        allocator.free(key);
        return;
    };
    if (gop.found_existing) allocator.free(key);
}

/// Fire every pending dirty subscription (the immediate path's second
/// half — the post-commit arm only MARKS; dispatch happens here on the
/// tick, like every other fire origin). The set is moved out first so
/// a fire that writes another watched prefix re-inserts cleanly.
pub fn drainPendingSubscriptionFires(worker: anytype) void {
    if (worker.pending_sub_fires.count() == 0) return;
    const allocator = worker.allocator;
    var pending = worker.pending_sub_fires;
    worker.pending_sub_fires = .empty;
    defer {
        for (pending.keys()) |k| allocator.free(k);
        pending.deinit(allocator);
    }
    for (pending.keys()) |combined| {
        const sep = std.mem.indexOfScalar(u8, combined, 0x1f) orelse continue;
        fireDirtySubscription(worker, combined[0..sep], combined[sep + 1 ..]);
    }
}

fn fireDirtySubscription(worker: anytype, tenant_id: []const u8, name: []const u8) void {
    const allocator = worker.allocator;
    const slot = worker.node.deploy.tenant_files_map.get(tenant_id) orelse return;
    const snap = slot.pinCurrent() orelse return;
    defer snap.release();
    const sub = for (snap.subscriptions) |s| {
        if (std.mem.eql(u8, s.name, name)) break s;
    } else {
        // Undeployed while its marker was dirty — nothing to fire. The
        // stale marker is harmless (skipped here and by the sweep).
        std.log.debug("rove-js kv-react: dirty marker for unregistered subscription {s}/{s}; skipping", .{ tenant_id, name });
        return;
    };
    const prefix = switch (sub.spec) {
        .kv => |k| k.prefix,
    };
    const marker_key = std.fmt.allocPrint(allocator, SUB_DIRTY_PREFIX ++ "{s}", .{name}) catch return;
    defer allocator.free(marker_key);
    std.log.info("rove-js kv-react fire: tenant={s} subscription={s} prefix={s}", .{ tenant_id, name, prefix });
    fireSubscriptionActivation(
        worker,
        tenant_id,
        name,
        sub.module_path,
        .{ .kv = .{ .prefix = prefix } },
        marker_key,
    );
}

/// durable-kv-subscriptions: the sweep GUARANTEE. Scans `_sub/dirty/`
/// for every tenant in this worker's partition that has subscriptions
/// registered, re-marking anything the immediate path dropped (crash
/// between commit and fire, faulted fire, OOM on the pending-set
/// insert). Steady-state it finds nothing; sustained finds mean the
/// immediate path is dropping. Throttled — a backstop, not the
/// delivery path.
const SUB_SWEEP_INTERVAL_NS: i64 = 10 * std.time.ns_per_s;

pub fn sweepDirtySubscriptions(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - worker.last_sub_sweep_ns < SUB_SWEEP_INTERVAL_NS) return;
    worker.last_sub_sweep_ns = now_ns;

    const n_inboxes = blk: {
        worker.node.router.msg_inboxes_mutex.lock();
        defer worker.node.router.msg_inboxes_mutex.unlock();
        break :blk worker.node.router.msg_inboxes.items.len;
    };
    if (n_inboxes == 0) return;

    var it = worker.node.deploy.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const inbox_idx = std.hash.Wyhash.hash(0, slot.instance_id) % n_inboxes;
        if (inbox_idx != worker.msg_inbox_idx) continue;
        // Gate the kv scan on the registry — tenants without
        // subscriptions never pay a read.
        const has_subs = blk: {
            const snap = slot.pinCurrent() orelse break :blk false;
            defer snap.release();
            break :blk snap.subscriptions.len > 0;
        };
        if (!has_subs) continue;
        var page = slot.app_kv.prefix(SUB_DIRTY_PREFIX, "", 64) catch |err| {
            std.log.warn("rove-js kv-react sweep: prefix scan tenant={s}: {s}", .{ slot.instance_id, @errorName(err) });
            continue;
        };
        defer page.deinit();
        for (page.entries) |e| {
            if (e.key.len <= SUB_DIRTY_PREFIX.len) continue;
            markSubPending(worker, slot.instance_id, e.key[SUB_DIRTY_PREFIX.len..]);
        }
    }
}

/// Leadership false→true: force an immediate full sweep — the pending
/// set is volatile, so a freshly-promoted leader must re-discover any
/// dirty markers the old leader hadn't fired (same posture as
/// `sweepDurableWakesOnPromotion`).
pub fn sweepDirtySubscriptionsOnPromotion(worker: anytype) void {
    worker.last_sub_sweep_ns = 0;
    sweepDirtySubscriptions(worker);
}

// ── Msg inbox + dispatch ──────────────────────────────────────────────

// There is no `SubscriptionFireQueueInput` / router
// `enqueueSubscriptionFireForTenant` producer (decisions §4.13,
// durable-kv-subscriptions): kv-react rides the dirty-marker path
// (`fireKvReactSubscriptions` marks; `drainPendingSubscriptionFires`
// dispatches). The Msg variant survives as an empty placeholder for
// the ActivationSource exhaustiveness contract.

/// Drain the worker's unified
/// cross-thread `msg_inbox`, moving each `effect.Msg` onto the
/// in-thread `msg_queue`. One drain function for every cross-thread
/// origin (cron fires, fetch chunk / done / pipe_done events).
/// Producers build Msg variants on the way in
/// (NodeState.enqueueXxxForTenant); this fn is variant-agnostic.
///
/// Ownership: each Msg popped from the inbox carries owned slices.
/// On `enqueueMsg` success the queue owns them (drains via
/// `dispatchPendingMsgs`). On `error.Full` we `freeOwnedMsg` and
/// log — overflow drops are bounded by the cross-thread inbox's
/// rate and the in-thread queue's cap; the per-origin policy is
/// at-most-once for cron (re-fire on next sweep) and at-most-
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
/// (cron via sweeper, FetchPool libcurl
/// threads) AND in-thread producers (kv-react, which `enqueueMsg`s
/// directly from `fireKvReactSubscriptions`).
pub fn serviceSubscriptionFires(worker: anytype) void {
    drainMsgInbox(worker);
    dispatchPendingMsgs(worker);
    // durable-kv-subscriptions: the immediate path (pending set filled
    // by the post-commit arm) + the throttled sweep guarantee.
    drainPendingSubscriptionFires(worker);
    sweepDirtySubscriptions(worker);
}

// ── Bound-fetch chunk spool ───────────────────────────────────────────
//
// The chunk-spool substrate (blob coordinator / chunk spool,
// `docs/architecture/routing-and-ingress.md`). The data structure lives in
// `chunk_spool.zig`; the push/dispatch/drain policy lives here next to
// the resume engines it drives.

/// Append a bound-fetch chunk onto its per-fetch spool, creating the
/// spool (+ duping the fetch_id key) on the first chunk. On success
/// ownership of `ev`'s slices transfers into the spool and the spool
/// pointer is returned; on error the caller retains ownership of `ev`.
fn pushToSpool(
    worker: anytype,
    ev: components_mod.UpstreamFetchEvent,
) !*chunk_spool_mod.ChunkSpool {
    const allocator = worker.allocator;
    const gop = try worker.bound_fetch_spools.getOrPut(allocator, ev.fetch_id);
    if (!gop.found_existing) {
        const sp = allocator.create(chunk_spool_mod.ChunkSpool) catch |e| {
            _ = worker.bound_fetch_spools.remove(ev.fetch_id);
            return e;
        };
        sp.* = .{};
        const key_dup = allocator.dupe(u8, ev.fetch_id) catch |e| {
            allocator.destroy(sp);
            _ = worker.bound_fetch_spools.remove(ev.fetch_id);
            return e;
        };
        gop.key_ptr.* = key_dup;
        gop.value_ptr.* = sp;
    }
    const sp = gop.value_ptr.*;
    try sp.push(allocator, ev, worker.bound_fetch_spool_depth);
    // Track peak inline RAM (K-window bound) + peak queued
    // depth (decoupling evidence: how far the producer ran ahead of
    // the raft-rate consumer) across all spools.
    updateSpoolPeaks(worker);
    return sp;
}

/// Recompute summed inline bytes + summed entry count across every
/// live spool and bump the worker's peak watermarks. O(total spool
/// entries) — only walked on push, which is bounded by the upstream
/// chunk rate.
fn updateSpoolPeaks(worker: anytype) void {
    var total_bytes: usize = 0;
    var total_entries: usize = 0;
    var it = worker.bound_fetch_spools.valueIterator();
    while (it.next()) |sp_ptr| {
        total_bytes += sp_ptr.*.inlineBytes();
        total_entries += sp_ptr.*.len();
    }
    if (total_bytes > worker.bound_fetch_spool_inline_bytes_peak) {
        worker.bound_fetch_spool_inline_bytes_peak = total_bytes;
    }
    if (total_entries > worker.bound_fetch_spool_depth_peak) {
        worker.bound_fetch_spool_depth_peak = total_entries;
    }
}

/// Drop a spool: free its still-pending entries, the `ChunkSpool`
/// itself, and the duped fetch_id key. Idempotent (no-op on miss).
/// Pub so the cleanup paths in `worker.zig`
/// (`scanAndCancelBoundFetches`, `cancelFetchTrampoline`) can drop a
/// spool when its bound fetch is cancelled / its held entity is
/// destroyed (the chunk-spool cleanup path, `routing-and-ingress.md`).
pub fn dropSpool(worker: anytype, fetch_id: []const u8) void {
    const entry = worker.bound_fetch_spools.fetchRemove(fetch_id) orelse return;
    // Count chunks discarded unconsumed (cancel / disconnect). A clean
    // terminal drop has already popped every entry, so this is 0 there.
    worker.bound_fetch_spool_dropped_total += entry.value.len();
    // Coordinator-retained release (`routing-and-ingress.md`): release the coordinator-retained
    // copy of every still-spooled chunk we're discarding, so a
    // cancel/disconnect of a backed-up fetch doesn't leak its backlog
    // in coordinator RAM.
    for (entry.value.entries.items) |*e| {
        if (e.event.coord_submitted) queueCoordRelease(worker, e.event.coord_worker_id, e.event.coord_seq);
    }
    entry.value.deinit(worker.allocator);
    worker.allocator.destroy(entry.value);
    worker.allocator.free(entry.key);
}

/// Pop + resume every spool-head chunk the held entity is currently
/// ready for, in seq order, stopping at the first head it isn't ready
/// for (mid-move / awaiting raft commit) — those stay spooled and are
/// retried by `drainSpools` on a later tick once the prior chunk's
/// writeset commits and moves the entity back to a receivable
/// collection. This is the back-pressure point: chunk consumption
/// runs at the held chain's raft cadence, while arrival ran at
/// upstream rate into the spool.
///
/// Readiness is collection membership (rove principle 1), mirroring
/// the pre-spool inline `.fetch_chunk` dispatch:
///   - `parked_continuations`           → `resumeBoundFetchChain`
///   - `stream_data_out`/`_response_in` → `resumeBoundFetchStream`
///   - `raft_pending_cont`/`_stream`    → not ready, retry later
///   - `isMoving` (deferred move)       → not ready, retry later
///   - none of the above (destroyed)    → drop the whole spool
fn dispatchSpoolHead(worker: anytype, fetch_id: []const u8) void {
    const server = worker.h2;
    // Dupe the key into a function-local buffer and match all map ops
    // by content. The caller's `fetch_id` may alias a spooled entry's
    // slice (freed when the entry is popped/resumed), and — worse — a
    // resume can drop THIS spool out from under us: a handler may call
    // `http.cancelFetch(its-own-id)` or go terminal
    // (`scanAndCancelBoundFetches`), either of which frees the spool-map
    // key. A private dupe is immune to all of these; `dropSpool` frees
    // the map's own key, never this one.
    const key: []u8 = blk: {
        const e = worker.bound_fetch_spools.getEntry(fetch_id) orelse return;
        break :blk worker.allocator.dupe(u8, e.key_ptr.*) catch return;
    };
    defer worker.allocator.free(key);
    while (true) {
        const sp = worker.bound_fetch_spools.get(key) orelse return;
        if (sp.isEmpty()) return;

        const held_ent = worker.lookupBoundFetch(key) orelse {
            // Held chain gone (terminal already drained, or client
            // disconnected) but chunks still spooled — drop them.
            // Matches the stale-registry posture in
            // the chunk-spool substrate (`routing-and-ingress.md`).
            std.log.info(
                "rove-js chunk-spool: no held entity for fetch_id={s}; dropping {d} spooled chunk(s)",
                .{ key, sp.len() },
            );
            dropSpool(worker, key);
            return;
        };

        // Same-tick / pre-commit defer: a prior chunk's writeset move
        // hasn't flushed (`isMoving`) or hasn't committed
        // (`raft_pending_*`). Leave the head spooled; `drainSpools`
        // retries after the commit lands.
        if (server.reg.isMoving(held_ent)) return;
        const ready_cont = server.reg.isInCollection(held_ent, &worker.parked_continuations);
        const ready_stream = server.reg.isInCollection(held_ent, &server.stream_data_out) or
            server.reg.isInCollection(held_ent, &server.stream_response_in);
        if (!ready_cont and !ready_stream) {
            // The held entity isn't in a receivable collection right now.
            // It is only genuinely GONE if it's stale (destroyed/recycled) —
            // in that case no future tick can deliver, so drop the spool.
            //
            // Otherwise the entity is ALIVE but transiently parked somewhere
            // a chunk can't be delivered into THIS tick:
            //   • awaiting a raft commit (`raft_pending_*`),
            //   • a deferred move in flight (`isMoving`),
            //   • mid h2 send — a stream entity cycles
            //     `stream_data_out → stream_data_in → _stream_data_sending →
            //     stream_data_out` for EVERY chunk shipped, and
            //     `response_in → _response_sending` on the head send,
            //   • on the terminal/close path (`stream_close_in` /
            //     `response_in` / `response_out`), about to be destroyed —
            //     at which point `isStale` flips (or `scanAndCancelBoundFetches`
            //     drops the spool) on a later tick.
            // In every one of these the chunk must STAY spooled; `drainSpools`
            // retries next tick once the entity returns to a receivable
            // collection. Enumerating the "alive" collections here is fragile
            // (the one-tick `_stream_data_sending` window is easy to
            // miss, truncating a large static response):
            // invert it — stale ⇒ drop, alive ⇒ retry.
            if (server.reg.isStale(held_ent)) {
                std.log.info(
                    "rove-js chunk-spool: held entity destroyed for fetch_id={s}; dropping {d} spooled chunk(s)",
                    .{ key, sp.len() },
                );
                dropSpool(worker, key);
            }
            return;
        }

        // Backpressure (lossless): if this is a STREAM chain whose output queue
        // is already at the soft high-water, DON'T feed it — leave the head
        // spooled. `serviceParkedStreams` drains the queue one chunk/tick and
        // `drainSpools` retries this each tick, so a fast upstream is paced to
        // the client without dropping. The spool is the backlog (RAM-bounded by
        // its own eviction-to-coordinator). Continuations (first chunk, pre-
        // stream) are never gated — they open the stream.
        if (ready_stream and !ready_cont) {
            const sc: ?*components_mod.StreamChunks =
                (server.reg.get(held_ent, &server.stream_data_out, components_mod.StreamChunks) catch null) orelse
                (server.reg.get(held_ent, &server.stream_response_in, components_mod.StreamChunks) catch null);
            if (sc) |chunks| {
                if (chunks.atSoftCap()) return;
            }
        }

        // Head entity is ready. If the head chunk's inline bytes were
        // evicted to honour the K-window, read them back from the
        // coordinator first — durability-gated: the bytes are only
        // resolvable once the submission seq is durable. If not yet
        // durable, leave the head spooled; `drainSpools` retries once
        // the coord HWM advances (the chunk-spool durability gate,
        // `routing-and-ingress.md`).
        {
            const h = sp.head().?;
            if (h.evicted) {
                const coord = worker.node.blob_coord.coordinator orelse {
                    // No coord but an evicted entry — unreachable in
                    // production (eviction only happens for submitted
                    // chunks, which require a coord). Drop loudly.
                    std.log.warn(
                        "rove-js chunk-spool: evicted head for fetch_id={s} but no coordinator; dropping spool",
                        .{key},
                    );
                    dropSpool(worker, key);
                    return;
                };
                const wid = h.event.coord_worker_id;
                if (coord.durableSeq(wid) <= h.event.coord_seq) {
                    // Bytes not durable yet — defer this head.
                    return;
                }
                const bytes = coord.readBody(wid, h.event.coord_seq, worker.allocator) catch |err| {
                    std.log.warn(
                        "rove-js chunk-spool: coord.readBody fetch_id={s} wid={d} seq={d}: {s}; dropping chunk",
                        .{ key, wid, h.event.coord_seq, @errorName(err) },
                    );
                    // Drop just this chunk (free + remove), keep the
                    // rest of the spool. P6: queue its coord copy for
                    // release (deferred — see queueCoordRelease).
                    var bad = sp.popHead();
                    if (bad.coord_submitted) queueCoordRelease(worker, bad.coord_worker_id, bad.coord_seq);
                    components_mod.UpstreamFetchEvent.deinitItem(&bad, worker.allocator);
                    continue;
                };
                // Materialize: the event now owns `bytes` inline again
                // (resume frees it on consume).
                h.event.bytes = bytes;
                h.evicted = false;
                worker.bound_fetch_spool_readback_total += 1;
            }
        }

        // Head is dispatchable: pop + resume (resume consumes `ev`).
        // The resume may itself drop this spool (handler cancels its
        // own fetch, or goes terminal → `scanAndCancelBoundFetches`);
        // that's fine — `key` is our private dupe, and the cleanup
        // below is idempotent (a no-op if the spool/registry are
        // already gone).
        var ev = sp.popHead();
        const final = ev.final;
        // Coordinator-retained release (`routing-and-ingress.md`): capture the coord identity
        // before resume consumes `ev`, so we can release the
        // coordinator's retained copy of this chunk after it's
        // consumed (every bound chunk was submitted, inline
        // or evicted — releasing bounds coord RAM to the live backlog).
        const rel_submitted = ev.coord_submitted;
        const rel_wid = ev.coord_worker_id;
        const rel_seq = ev.coord_seq;
        if (ready_cont) {
            // A held WS chain reparks in place (no h2 response) — route its
            // bound-fetch resume through the ws-aware path that ships frames
            // via shipWsFrames instead of resolveParked.
            if (worker_ws.wsConnForChain(worker, held_ent)) |conn_ent| {
                worker_ws.resumeBoundFetchChainWs(worker, held_ent, conn_ent, &ev);
            } else {
                worker_drain.resumeBoundFetchChain(worker, held_ent, &ev);
            }
        } else {
            // Steady-state stream (stream_data_out) OR the brief
            // post-commit window in stream_response_in before h2's
            // consumeStreamResponses ships headers + moves to
            // stream_data_out; resumeBoundFetchStream picks the right
            // collection internally.
            resumeBoundFetchStream(worker, held_ent, &ev);
        }
        // P6: chunk consumed — queue its coordinator-retained copy for
        // release. Deferred (not direct) because an in-window chunk is
        // consumed from inline bytes BEFORE its submit is durable, so a
        // direct release would miss the not-yet-set ref. `drainSpools`
        // retries until durable.
        if (rel_submitted) queueCoordRelease(worker, rel_wid, rel_seq);
        if (final) {
            worker.unregisterBoundFetch(key);
            dropSpool(worker, key);
            return;
        }
        // Non-final: loop. If the resume wrote + moved the entity,
        // the next iteration's isMoving / raft_pending check defers
        // the following head.
    }
}

/// Coordinator-retained release (`routing-and-ingress.md`): queue a consumed/dropped bound
/// chunk's coordinator release for retry. Deferred (not direct)
/// because in-window chunks are consumed before their submit is
/// durable; `drainSpools` retries `coord.release` until it succeeds.
fn queueCoordRelease(worker: anytype, worker_id: u8, seq: u64) void {
    // Once-to-queue guard (runtime-safety builds only): each consumed/
    // dropped chunk is released exactly once. Queueing the same
    // (worker_id, seq) twice would make `drainCoordReleases` retry the
    // second copy forever — `coord.release` returns `false` for an
    // already-released seq by contract (indistinguishable from
    // not-yet-durable), so the duplicate never drains, growing
    // `coord_pending_releases` unboundedly. Catch the double-queue at
    // the source rather than chasing the symptom downstream.
    if (std.debug.runtime_safety) {
        for (worker.coord_pending_releases.items) |p| {
            if (p.worker_id == worker_id and p.seq == seq) std.debug.panic(
                "queueCoordRelease: double queue of worker={d} seq={d} (would retry forever)",
                .{ worker_id, seq },
            );
        }
    }
    worker.coord_pending_releases.append(worker.allocator, .{ .worker_id = worker_id, .seq = seq }) catch {
        // OOM: drop the deferred release. The coordinator batch leaks
        // until coord deinit — rare, bounded by this one chunk.
        std.log.warn("rove-js chunk-spool: coord_pending_releases append OOM; release dropped", .{});
    };
}

/// Retry every deferred coordinator release; keep the ones whose
/// submit isn't durable yet (`release` returns false). Drained each
/// tick from `drainSpools` regardless of whether any spool is active.
fn drainCoordReleases(worker: anytype) void {
    const coord = worker.node.blob_coord.coordinator orelse return;
    var i: usize = 0;
    while (i < worker.coord_pending_releases.items.len) {
        const p = worker.coord_pending_releases.items[i];
        if (coord.release(p.worker_id, p.seq)) {
            _ = worker.coord_pending_releases.swapRemove(i); // freed — drop
        } else {
            i += 1; // not durable yet — retry next tick
        }
    }
}

/// Worker-tick system (the chunk-spool dispatch retry, `routing-and-ingress.md`): retry
/// dispatch for every spool whose held entity has returned to a
/// receivable state since the last tick (e.g. after a prior chunk's
/// writeset committed in `drainRaftPending`). Snapshots duped keys
/// up front because `dispatchSpoolHead` can `dropSpool` (mutating the
/// map) and the resume engines can register new bound fetches
/// mid-walk. Cheap no-op when no bound fetch is streaming.
pub fn drainSpools(worker: anytype) void {
    const allocator = worker.allocator;
    // P6: always retry deferred coord releases (a dropped spool may
    // have queued some even when no spool is currently active).
    drainCoordReleases(worker);
    if (worker.bound_fetch_spools.count() == 0) return;

    var keys: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }
    var it = worker.bound_fetch_spools.iterator();
    while (it.next()) |entry| {
        const kd = allocator.dupe(u8, entry.key_ptr.*) catch return;
        keys.append(allocator, kd) catch {
            allocator.free(kd);
            return;
        };
    }
    for (keys.items) |k| {
        // Skip spools dropped by an earlier iteration; the duped key
        // is safe to hash even after the live spool/key was freed.
        if (worker.bound_fetch_spools.get(k) == null) continue;
        dispatchSpoolHead(worker, k);
    }
}

/// Worker-tick system: dequeue Msgs from `worker.msg_queue` (up to
/// `BATCH` per tick) and dispatch each by variant. Per-tick cap
/// bounds tail latency on the request hot path: a misbehaving
/// handler with many activations pending eats at most `BATCH` per
/// tick before yielding back to the h2 loop; remaining drain on
/// subsequent ticks.
///
/// The unified dispatcher across every Msg variant — subscription
/// fires (cron / kv-react), outbound HTTP events (chunk / done /
/// pipe_done), send-callback, and durable-wake.
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
            // No producer (decisions §4.13): kv-react fires ride
            // the durable dirty-marker path (post-commit arm → pending
            // set → drainPendingSubscriptionFires), never this queue.
            // The variant stays for the Msg-over-ActivationSource
            // exhaustiveness contract; the empty payload owns nothing.
            .subscription_fire => {},
            .fetch_chunk => |ev_const| {
                // Single fetch activation kind. Every
                // event fires `on_chunk` against the handler; `event.final`
                // distinguishes the terminal event from intermediates.
                // Tape captures the chunk bytes.
                //
                // fireFetchEventActivation owns
                // the event — internal defer deinits it OR transfers
                // to worker.fetch_pending_durability for the park
                // branch. No external deinit needed.
                //
                // Upstream bound-fetch streaming
                // (`docs/architecture/routing-and-ingress.md`): bound fetch
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
                    if (worker.lookupBoundFetch(ev.fetch_id) != null) {
                        // The chunk-spool dispatch path (`routing-and-ingress.md`): a bound
                        // chunk for a live held chain goes onto the
                        // per-fetch spool instead of dispatching (or
                        // re-enqueueing a Msg) inline. `pushToSpool`
                        // takes ownership of `ev`; `dispatchSpoolHead`
                        // then pops + resumes every head the entity is
                        // currently ready for. Heads the entity isn't
                        // ready for (mid-move / awaiting raft commit)
                        // stay spooled and are retried by `drainSpools`
                        // on the next tick.
                        if (pushToSpool(worker, ev)) |_| {
                            // Ownership transferred. `ev.fetch_id`
                            // still aliases the spooled entry's slice
                            // (valid until dispatched); dispatchSpoolHead
                            // re-anchors to the stable map key.
                            dispatchSpoolHead(worker, ev.fetch_id);
                        } else |err| {
                            std.log.warn(
                                "rove-js chunk-spool: pushToSpool fetch_id={s}: {s}",
                                .{ ev.fetch_id, @errorName(err) },
                            );
                            components_mod.UpstreamFetchEvent.deinitItem(&ev, allocator);
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
                fireFetchEventActivation(worker, &ev, null);
                fired += 1;
            },
            .send_callback => |sc_const| {
                // Chained dispatch — the customer's
                // next-hop handler runs because a previous handler
                // returned `__rove_next(path, {ctx})`. Producer is the
                // fetch-event `.continuation` arm; other
                // producers (`webhook.send.js` shim's onresult)
                // compose on this same Msg.
                var sc = sc_const;
                fireChainedActivation(worker, &sc);
                sc.deinit(allocator);
                fired += 1;
            },
            .durable_wake => |dw_const| {
                // §2.6 durable-wake: one due `_sched/by_time` entry,
                // fanned out by `scheduler_tick` via `__rove_fire_wake`.
                // `fireDurableWakeActivation` injects the entry's
                // `_sched/` deletes into the target's writeset so the
                // removal commits atomically with the handler's effects.
                var dw = dw_const;
                fireDurableWakeActivation(worker, &dw);
                dw.deinit(allocator);
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

/// Alias for callers that name the subscription-fire dispatcher.
/// Both this and
/// `dispatchFetchEvents` route into the same unified
/// `dispatchPendingMsgs`; the second-to-call sees an empty queue and
/// is a no-op.
pub fn dispatchSubscriptionFires(worker: anytype) void {
    dispatchPendingMsgs(worker);
}

/// Alias — see `dispatchSubscriptionFires`.
pub fn dispatchFetchEvents(worker: anytype) void {
    dispatchPendingMsgs(worker);
}

// ── http.fetch chunk/done activations ──────────

/// Alias of
/// `serviceSubscriptionFires` — both drain the unified
/// `msg_inbox` and dispatch the queue. The second-to-call sees an
/// empty inbox + queue and is a cheap no-op. main.zig + the
/// parked_units call site keep their existing call shape.
pub fn serviceFetchEvents(worker: anytype) void {
    drainMsgInbox(worker);
    dispatchPendingMsgs(worker);
}

/// Dispatch one upstream fetch event as a chain activation.
/// Structural twin of `fireSubscriptionActivation` — no held socket,
/// writes commit forgetfully — but the activation source + payload
/// differ.
///
/// **TEA framing:**
///   - **Msg**: `(fetch_chunk, {seq, bytes, final, ...})` per
///     event. `final == true` marks the last event of the fetch
///     and carries terminal fields (status / ok / body_truncated);
///     intermediates have `final == false`.
///   - **prep**: resolve the `on_chunk` module on the event's
///     tenant; correlation_id `fetch-<id>` so every activation of
///     one fetch shares a chain identity; body `{ctx: <ctx_json>}`.
///   - **run**: `dispatcher.runOutcome`.
///   - **apply**: terminal → propose writes (if any) + log;
///     continuation / stream → recorded + logged + ignored (a
///     fetch chain has no held socket, same as subscription_fire).
///
/// Errors return `void` — `dispatchFetchEvents` is best-effort. An
/// event with an empty `on_chunk_module` (binding-side regression)
/// is a silent no-op.
/// Takes ownership of `event` — internal
/// defer deinits it on exit unless the gate logic parks it
/// (transferring ownership to
/// `worker.fetch_pending_durability`).
///
/// `parked_body_ref` is non-null when called from a parked
/// resume: it carries the BodyRef minted at the original
/// append site, and the gate uses it directly instead of
/// re-appending (which would mint a new batch + re-park).
/// Fresh-arrival callers pass `null`.
pub fn fireFetchEventActivation(
    worker: anytype,
    event: *components_mod.UpstreamFetchEvent,
    parked_body_ref: ?bodies_mod.BodyRef,
) void {
    // Ownership handling: deinit the event on every exit path
    // except the park branch (which transfers to
    // fetch_pending_durability).
    var parked_to_durability = false;
    defer if (!parked_to_durability)
        components_mod.UpstreamFetchEvent.deinitItem(event, worker.allocator);

    const module_path = event.on_chunk_module;
    if (module_path.len == 0) {
        std.log.warn(
            "rove-js fetch-event: fetch_id={s} has no on_chunk module; dropping",
            .{event.fetch_id},
        );
        return;
    }
    const tenant_id = event.tenant_id;
    const allocator = worker.allocator;

    var p = firePrep(worker, tenant_id, module_path, "fetch-event") orelse return;
    defer p.deinit(allocator);

    // Body `{ctx: <ctx_json>}`. `ctx_json` is the chain ctx the
    // originating `http.fetch` call passed; empty → `{}`.
    const ctx_src: []const u8 = if (event.ctx_json.len > 0) event.ctx_json else "{}";
    const body = synthCtxBody(allocator, ctx_src) catch return;
    defer allocator.free(body);
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{module_path}) catch return;
    defer allocator.free(spath);

    // Correlation: all activations of one fetch share `fetch-<id>`
    // so the replay UX groups the chunk chain with its terminal.
    var corr_buf: [80]u8 = undefined;
    const id_len: usize = @min(event.fetch_id.len, 64);
    const corr_full = std.fmt.bufPrint(
        &corr_buf,
        "fetch-{s}",
        .{event.fetch_id[0..id_len]},
    ) catch corr_buf[0..0];

    const req: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        .activation = .{ .fetch_chunk = .{
            .id = event.fetch_id,
            .seq = event.seq,
            .byte_offset = event.byte_offset,
            .bytes = event.bytes,
            .headers = event.fetch_headers,
            .final = event.final,
            .terminal_status = if (event.final) event.terminal_status else 0,
            .terminal_ok = if (event.final) event.terminal_ok else false,
            .body_truncated = if (event.final) event.body_truncated else false,
        } },
        .trace = .{ .readset = &p.readset, .request_id = p.request_id, .correlation_id = corr_full },
        .plan = .{ .limiter = &worker.limiter, .instance_id = p.dep.inst.id, .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = p.dep.inst.platform },
        .trampolines = .{
            // §6.4 held-sync resume hook. The baked
            // `__system/webhook_onresult` shim calls `__rove_resume_if_bound`
            // on terminal to wake any parked cont bound to this send-id.
            // Set on every fetch-event activation (the H2 path sets it
            // too, in `worker_dispatch.zig`); without this the JS builtin
            // sees a null trampoline + returns false, leaving the cont
            // parked until its 25s deadline.
            .resume_if_bound = &@TypeOf(worker.*).resumeIfBoundTrampoline,
            .resume_if_bound_ctx = @ptrCast(worker),
            .blob_write = &@TypeOf(worker.*).blobWriteTrampoline,
            .blob_seal = &@TypeOf(worker.*).blobSealTrampoline,
            .blob_session_ctx = @ptrCast(worker),
            .cancel_fetch = &@TypeOf(worker.*).cancelFetchTrampoline,
            .cancel_fetch_ctx = @ptrCast(worker),
        },
    };

    // Small fetch chunks ride inline in
    // the readset's `fetch_responses.inline_bytes` field — no
    // buffer append, no S3 PUT, handler runs immediately. The
    // raft entry's fsync IS the durability substrate (every
    // replica sees the bytes when the entry replicates).
    // Discriminator: `body_ref.batch_id == NO_BATCH` ⇒ inline.
    //
    // Larger chunks submit to the process-global blob coordinator
    // (`coord.submit` → seq) and park in `fetch_pending_durability`;
    // `drainFetchPendingDurability` re-fires the activation with the
    // materialized `BodyRef` once durable (closing the §5.1 outbound
    // unreplayability gap), then `coord.release`s the retained copy.
    //
    // The bytes still ride alongside on `activation_fetch_bytes`
    // for the handler's `request.activation.bytes` view; the
    // tape's `activation_bytes` still captures them too.
    //
    // Terminal-only events (final=true with no body bytes) still
    // capture a tape entry so the chain has the closing seq +
    // terminal status / ok / body_truncated for replay; both
    // body_ref and inline_bytes are empty.
    const FETCH_INLINE_THRESHOLD: usize = 16 * 1024;
    var body_ref: bodies_mod.BodyRef = .{ .batch_id = bodies_mod.NO_BATCH, .offset = 0, .len = 0 };
    var inline_bytes_for_tape: []const u8 = "";
    if (parked_body_ref) |saved| {
        // Resume from a previous park. The
        // body's batch was confirmed durable by
        // drainFetchPendingDurability before this re-fire; use
        // the saved ref directly + skip append. Re-appending
        // would mint a new batch and re-park.
        body_ref = saved;
    } else if (event.bytes.len > 0 and event.bytes.len <= FETCH_INLINE_THRESHOLD) {
        // Inline fast path — no buffer append, the chunk bytes
        // ride on the tape entry directly. Raft entry fsync IS
        // the durability substrate.
        body_ref = .{
            .batch_id = bodies_mod.NO_BATCH,
            .offset = 0,
            .len = @intCast(event.bytes.len),
        };
        inline_bytes_for_tape = event.bytes;
    } else if (event.bytes.len > 0) {
        // Larger-than-threshold chunk — coord submit + park.
        // the streaming substrate (`docs/architecture/routing-and-ingress.md`):
        // submit returns a
        // seq; durability is observed via the coord's per-worker
        // HWM. Always park (no fast-durable bypass — submit is
        // strictly async, durable_seq can't have advanced past
        // this seq before the executor lands the PUT).
        if (worker.node.blob_coord.coordinator) |coord| {
            const wid: u8 = @intCast(worker.log_worker_id);
            const seq = coord.submit(wid, event.bytes) catch |err| blk: {
                std.log.warn(
                    "rove-js fetch-event: coord.submit tenant={s} bytes={d}: {s}",
                    .{ tenant_id, event.bytes.len, @errorName(err) },
                );
                break :blk @as(?u64, null);
            };
            if (seq) |s| {
                worker.fetch_pending_durability.append(worker.allocator, .{
                    .event = event.*,
                    .worker_seq = s,
                    .worker_id = wid,
                    .tenant_id_view = p.dep.inst.id,
                }) catch |err| {
                    std.log.warn(
                        "rove-js fetch-event: fetch_pending_durability.append tenant={s}: {s}",
                        .{ tenant_id, @errorName(err) },
                    );
                    return;
                };
                parked_to_durability = true;
                return;
            }
            // submit failed — fall through with empty body_ref.
            // The activation runs but the tape entry has no
            // BodyRef.
        }
    }
    p.readset.fetch_responses.appendFetchResponse(
        event.fetch_id,
        event.seq,
        event.byte_offset,
        body_ref,
        event.final,
        if (event.final) event.terminal_status else 0,
        if (event.final) event.terminal_ok else false,
        if (event.final) event.body_truncated else false,
        event.fetch_headers orelse "",
        inline_bytes_for_tape,
    ) catch |err| {
        // Tape capture failures must never kill the request. Same
        // posture as `captureTapes`'s per-channel serialize
        // errors: log + skip.
        std.log.warn(
            "rove-js fetch-event: readset.fetch_responses append tenant={s} fetch_id={s}: {s}",
            .{ tenant_id, event.fetch_id, @errorName(err) },
        );
    };

    // The activation's input bytes (the upstream chunk
    // payload) get taped on `TapePayloads.activation_bytes` —
    // `runFire` captures them on every log record (`spec.tape = .activation`) so
    // replay reconstitutes the same handler invocation from the same
    // captured bytes.
    runFire(worker, &p, req, .{
        .act = .fetch_chunk,
        .site = "fetch-event",
        .on_cont = .enqueue,
        .on_stream = .warn,
        .readonly_cont_commits = true,
        .tape = .activation,
    }, module_path, corr_full, module_path, event.bytes);
}
