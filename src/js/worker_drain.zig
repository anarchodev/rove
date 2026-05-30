//! Post-raft-commit reconciliation + held-continuation resume engine.
//!
//! The original "Dispatch system" section in `worker.zig` — covers
//! the two systems the worker tick runs after `dispatchOnce`:
//!
//!   - **`drainRaftPending`** — the reconciler. One snapshot of
//!     `(committed, faulted, now_ns)` per tick, fed into `effect.classify`
//!     on every parked unit. The three raft_pending sibling collections
//!     (`raft_pending_response` / `_cont` / `_stream`) share
//!     `drainEntityArm`; the entity-less `parked_units` sweep is the
//!     fourth arm and the commit-gated buffer release point (see
//!     `worker_streaming.firePendingKvWakes` + `transferStagedChunks`).
//!   - **`resumeContinuation` / `resumeBoundContinuation` /
//!     `sweepParkedContinuations` / `drainPendingBoundResumes`** —
//!     the held-sync trampoline. Continuation activations re-enter
//!     `Dispatcher.runOutcome` on the parked entity, then either
//!     resolve the held socket (terminal) or re-park (recipe-1 retry).
//!     `proposeAndParkContResume` is the write-path bridge: a hop
//!     that wrote stages everything on `pending_txns[seq]` and parks
//!     the entity on `raft_pending_cont` so the next reconciler tick
//!     routes the committed entity back to `parked_continuations`.
//!
//! `resolveDeployment` is the shared `(tenant_id, module_path) →
//! (instance, bytecode)` helper; every resume engine calls it
//! (worker_streaming's three fire*Activation + resumeStream too).
//!
//! Phase 7 audit (folded with this extraction, 2026-05-24):
//! the side tables `parked_meta` / `parked_streams_active` /
//! `parked_streams_meta` / `parked_streams_draining` /
//! `pending_stream_meta` have no field-level existence anywhere in
//! the codebase. The code-side migration shipped earlier; what
//! remained — and what this extraction cleans up — is stale doc
//! comments that still narrated the side-table world. Replaced in
//! place during the move; no behavior change.
//!
//! Every function takes `worker: anytype` so the structural-typed
//! access to Worker's fields keeps working without forcing this file
//! to depend on the comptime Worker type. Same shape as
//! `worker_dispatch.zig` / `worker_log.zig` / `worker_streaming.zig`.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("raft-kv");
const tape_mod = @import("rove-tape");
const log_mod = @import("rove-log");
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const Request = dispatcher_mod.Request;
const continuation_mod = @import("bindings/continuation.zig");
const Continuation = continuation_mod.Continuation;
const components_mod = @import("components.zig");
const effect_mod = @import("effect/root.zig");
const raft_propose = @import("raft_propose.zig");
const panic_mod = @import("panic.zig");
const builtin_modules_mod = @import("builtin_modules.zig");
const respb = @import("response_builder.zig");

const worker_mod = @import("worker.zig");
const worker_streaming = @import("worker_streaming.zig");
const bodies_mod = @import("rove-bodies");
const ParkedUnit = worker_mod.ParkedUnit;
const RaftWait = worker_mod.RaftWait;
const BodyDurabilityWait = worker_mod.BodyDurabilityWait;
const TenantFiles = worker_mod.TenantFiles;
const captureLogWithId = worker_mod.captureLogWithId;
const OWED_PREFIX = worker_mod.OWED_PREFIX;
const CONT_HOLD_DEADLINE_NS = worker_mod.CONT_HOLD_DEADLINE_NS;

// ── Reconciler ────────────────────────────────────────────────────────

/// Shared body of the three raft_pending_X sibling drains
/// (response / cont / stream). The pre-3.2.b world had three near-
/// identical functions; this fn unifies them, parameterised by the
/// source collection + a panic-label site name.
///
/// Commit arm: take the deferred TrackedTxn through the watermark;
/// the entity's commit-time move is the parked_units arm's job via
/// `interpretCmd .respond` (every path that parks an entity in
/// raft_pending_X also emits a Cmd.respond on the parked_units
/// unit — see effect-reification-plan.md Phase 4.1.3 Option-2).
///
/// Fault arm: rollback the txn, overwrite the response body to 503,
/// move the entity to `server.response_in` for h2 to ship.
/// `response_in` is hard-coded for the fault destination — the three
/// arms all routed fault there for the 503 downgrade, that's a
/// per-sibling invariant of the H2 reference path.
fn drainEntityArm(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    wm: effect_mod.Watermarks,
    source: anytype,
    comptime site_label: []const u8,
) !void {
    const entities = source.entitySlice();
    const waits = source.column(RaftWait);
    const resp_bodies = source.column(h2.RespBody);
    var i: usize = 0;
    while (i < entities.len) : (i += 1) {
        const ent = entities[i];
        const wait = waits[i];
        const resp_body = resp_bodies[i];

        switch (effect_mod.classify(wait.seq, wait.deadline_ns, wm)) {
            .pending => continue,
            .commit => {
                switch (worker.pending_txns.commitAndTake(allocator, wait.seq)) {
                    .took, .absent => {},
                    .conflict => continue,
                    .failed => |err| panic_mod.invariantViolated(
                        site_label ++ ".commit",
                        "seq={d} err={s}",
                        .{ wait.seq, @errorName(err) },
                    ),
                }
                // Commit-arm entity move lives on the parked_units
                // arm via `interpretCmd .respond` (Phase 4.1.3
                // Option-2). Nothing more to do here.
            },
            .fault => {
                switch (worker.pending_txns.rollbackAndTake(allocator, wait.seq)) {
                    .took, .absent => {},
                    .failed => |err| panic_mod.invariantViolated(
                        site_label ++ ".rollback",
                        "seq={d} err={s}",
                        .{ wait.seq, @errorName(err) },
                    ),
                }
                // Per-sibling on-entity cleanup (ContDescriptor /
                // stream components / etc.) deinits structurally when
                // cleanupResponses destroys the entity — no manual
                // side-table teardown.
                const old_body_ptr: ?[*]u8 = resp_body.data;
                const old_body_len: u32 = resp_body.len;
                try respb.overwrite503InPending(worker, source, ent, allocator);
                if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);
                try server.reg.move(ent, source, &server.response_in);
            },
        }
    }
}

/// Iterate `raft_pending`, check each entity's `RaftWait.seq` against
/// the raft node's committed and faulted watermarks, and run the
/// deferred TrackedTxn commit/rollback for each batch as it crosses
/// the watermark.
///
/// Per kvexp README §1 (speculative apply): `txn.commit` happens HERE,
/// after raft confirms the batch's seq, not in `finalizeBatch`. Many
/// `raft_pending` entries share one TrackedTxn (one batch → one
/// propose → one seq → many entries); `worker.pending_txns[seq]`
/// holds the single owning pointer. The first entry for each seq that
/// crosses the watermark performs the commit; subsequent entries find
/// the seq missing from the map and just drain.
///
/// On fault or timeout we rollback the txn (kvexp `Txn.rollback`
/// cascades chain successors — fine for our model since the per-
/// tenant lock means at most one in-flight txn per tenant). The
/// response body is overwritten with 503.
pub fn drainRaftPending(worker: anytype) !void {
    const server = worker.h2;
    const allocator = worker.allocator;

    // Effect-reification Phase 3.2.a: one snapshot per tick, shared
    // across every parked-seq sweep below. The four arms
    // (raft_pending_response / _cont / _stream + parked_units) all
    // classify against this same Watermarks via `effect.classify`,
    // so commit / fault / timeout decisions are byte-identical
    // across arms by construction.
    const wm: effect_mod.Watermarks = .{
        .committed = worker.raft.committedSeq(),
        .faulted = worker.raft.faultedSeq(),
        .now_ns = @intCast(std.time.nanoTimestamp()),
    };

    // Handler-cmds Phase 5: raft_pending is THREE sibling collections.
    // Each entity is parked on the sibling matching its commit
    // destination, so the dispatch in each loop is direct — no
    // `desc.cont != null` field check, no `pending_stream_meta.contains`
    // probe. Whichever loop processes a given seq first commits the
    // shared TrackedTxn; later siblings find the map empty and just
    // queue moves. Forward-iter preserves per-tenant chain order
    // (entities enter the siblings in propose-seq order from
    // finalizeBatch).
    try drainEntityArm(worker, server, allocator, wm, &worker.raft_pending_response, "raft_pending_response");
    try drainEntityArm(worker, server, allocator, wm, &worker.raft_pending_cont, "raft_pending_cont");
    try drainEntityArm(worker, server, allocator, wm, &worker.raft_pending_stream, "raft_pending_stream");

    // ── Additive: non-entity parked units (idiom-1 SSE-emit gating,
    //    docs/unified-effect-gating.md). The H2 entity path above is
    //    untouched — H2 behaviour is byte-identical.
    //
    // Iterates a snapshot of entity ids so that re-entrant park-*
    // calls (e.g. via firePendingKvWakes → kv-react fire path) that
    // create new parked_units entities land in the deferred-create
    // queue and process next tick — no iterate-while-modify trap
    // (the v1 flat ArrayList bit us with a GPE here in Phase E;
    // collection + reg.destroy fixes it by construction).
    {
        const slice = worker.parked_units.entitySlice();
        var buf: [256]rove.Entity = undefined;
        const n = @min(slice.len, buf.len);
        std.mem.copyForwards(rove.Entity, buf[0..n], slice[0..n]);
        for (buf[0..n]) |ent| {
            const unit = server.reg.get(ent, &worker.parked_units, ParkedUnit) catch continue;
            switch (effect_mod.classify(unit.seq, unit.deadline_ns, wm)) {
                .pending => continue,
                .commit => {
                    // Phase 4c: forgetful-writes units carry their own
                    // `TrackedTxn` (no entity in raft_pending waiting on
                    // this seq — see `proposeForgetfulWrites`). Commit
                    // it here; the firePending* helpers run alongside,
                    // same post-commit firing order as the entity-backed
                    // path. Null `txn` after commit so ParkedUnit.deinit
                    // doesn't try to rollback on destroy.
                    if (unit.txn) |t| {
                        t.commit() catch |cerr| switch (cerr) {
                            // kvexp NotChainHead: predecessor hasn't
                            // committed its head yet. Retry next tick
                            // — same posture as the entity-backed
                            // branch below (and as
                            // `worker_streaming.proposeForgetfulWrites`
                            // documents). Leave unit.txn attached and
                            // the unit parked; classify on the next
                            // tick still says `.commit` once the
                            // predecessor lands. Pre-fix this aborted
                            // every concurrent same-tenant heldsync
                            // under multi-worker load (kv_shard_bench /
                            // heldsync_multiworker_smoke).
                            error.Conflict => continue,
                            else => panic_mod.invariantViolated(
                                "drainRaftPending.parked_units.commit",
                                "seq={d} tenant={s} err={s}",
                                .{ unit.seq, unit.tenant_id, @errorName(cerr) },
                            ),
                        };
                        allocator.destroy(t);
                        unit.txn = null;
                    } else if (worker.pending_txns.contains(unit.seq)) {
                        // Entity-backed unit (no own txn): a sibling
                        // `drainEntityArm` arm is responsible for
                        // committing the txn at this seq. If the txn
                        // is still parked, that arm conflicted
                        // (kvexp NotChainHead — predecessor not
                        // committed yet) and skipped its move. Our
                        // `Cmd.respond` would otherwise move the
                        // entity before its writes are durable — and
                        // the orphaned txn would block every later
                        // forgetful commit in the chain. Defer to
                        // the next tick; the unit stays in
                        // `parked_units` for retry.
                        //
                        // Effect-reification Phase 4.1.3 Option-2:
                        // this check restores commit + move atomicity
                        // that the pre-4.1.3 inline-move arm got for
                        // free. The `Cmd.respond` Phase 4.1.3 decoupled
                        // re-introduces a window where commit-and-move
                        // are split across the entity arm and the unit
                        // arm; this gate closes that window.
                        continue;
                    }
                    // Effect-reification Phase 4.1: the unified
                    // commit-arm release. fireKvReactSubscriptions
                    // walks the kv_wake_broadcast Cmds (read-only,
                    // enqueues kv-react fires onto worker.msg_queue),
                    // then releaseAll interprets every Cmd in order
                    // (kv broadcasts via interpretCmd, stream
                    // chunks transfer to StreamChunks, stream_close
                    // flips the draining flag). Both pre-4.1
                    // helpers — firePendingKvWakes +
                    // transferStagedChunks — collapsed into this
                    // pair of calls. Same operations, one switch
                    // site (`effect.interpretCmd`) instead of three
                    // hand-rolled per-kind functions.
                    worker_streaming.fireKvReactSubscriptions(worker, unit) catch |err|
                        std.log.warn(
                            "rove-js kv-react ({s}): {s}",
                            .{ unit.tenant_id, @errorName(err) },
                        );
                    unit.buffered.releaseAll(worker, unit.tenant_id);
                    server.reg.destroy(ent) catch |err| std.log.warn(
                        "rove-js parked_units commit destroy: {s}",
                        .{@errorName(err)},
                    );
                },
                .fault => {
                    // Phase 4c: rollback the attached txn before
                    // discarding. `ParkedUnit.deinit` is the structural
                    // safety net (shutdown path); doing it here keeps
                    // the fault/timeout discard ordering symmetric with
                    // commit's destroy-then-clear pattern.
                    if (unit.txn) |t| {
                        t.rollback() catch |rerr| std.log.warn(
                            "rove-js drainRaftPending.parked_units.rollback seq={d} tenant={s}: {s}",
                            .{ unit.seq, unit.tenant_id, @errorName(rerr) },
                        );
                        allocator.destroy(t);
                        unit.txn = null;
                    }
                    server.reg.destroy(ent) catch |err| std.log.warn(
                        "rove-js parked_units fault destroy: {s}",
                        .{@errorName(err)},
                    );
                },
            }
        }
    }

    // Gap 2.1 Phase E (refactored), effect-reification Phase 2C:
    // dispatch any subscription fires the kv-react site enqueued
    // onto `worker.msg_queue` during the parked_units loop.
    // Re-entrant fires append to the queue's tail; the current
    // tick's BATCH was already capped, so they process next tick
    // — no iterate-while-modify trap.
    worker_streaming.dispatchSubscriptionFires(worker);
}

// ── Shared deployment-resolve ─────────────────────────────────────────

/// Handler-cmds Phase 8: the deployment + bytecode resolution that
/// every resume engine shares (the only truly-shared block across
/// `resumeContinuation` / `resumeStream` / `fireDisconnectActivation`
/// after Phase 7 deletions). Caller defers `dep.tc.release()` on
/// success; on error the helper releases internally.
///
/// Why only this one helper: the engines' outcome-application logic
/// is intrinsically divergent (cont reparks + bound_schedule_id +
/// 6.4 deadline / stream appends chunks to a component queue +
/// marks draining / disconnect ignores output entirely). Forcing a
/// unified outcome-switch obscures rather than clarifies, so each
/// engine keeps its tail. See the doc comment on each engine for
/// the prep / run / apply phase structure.
const ChainDeployment = struct {
    inst: *const tenant_mod.Instance,
    tc: TenantFiles,
    bc: []u8,
};

pub fn resolveDeployment(
    worker: anytype,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    module_path: []const u8,
) !ChainDeployment {
    const slot = worker.node.tenant_files_map.get(tenant_id) orelse return error.ResumeNoTenant;
    const snap = slot.pinCurrent() orelse return error.ResumeNoDeployment;
    var tc = TenantFiles{ .slot = slot, .snap = snap };
    errdefer tc.release();
    const inst = (worker.node.tenant.getInstance(tenant_id) catch return error.ResumeNoInstance) orelse
        return error.ResumeNoInstance;
    const bc = blk: {
        if (tc.snap.bytecodes.get(module_path)) |bb| break :blk bb.bytes;
        const mjs = try std.fmt.allocPrint(allocator, "{s}.mjs", .{module_path});
        defer allocator.free(mjs);
        if (tc.snap.bytecodes.get(mjs)) |bb| break :blk bb.bytes;
        const js = try std.fmt.allocPrint(allocator, "{s}.js", .{module_path});
        defer allocator.free(js);
        if (tc.snap.bytecodes.get(js)) |bb| break :blk bb.bytes;
        // Phase 5 PR-2b: `__system/<name>` falls through to the
        // node-level built-in registry. Bytecode compiled once at
        // NodeState init from sources baked into the binary; shared
        // across tenants. The handler runs in the tenant's context,
        // so it sees the tenant's globals (kv, http, __rove_next).
        if (builtin_modules_mod.isBuiltinPath(module_path)) {
            if (worker.node.builtin_modules.get(module_path)) |b| break :blk b;
            if (worker.node.builtin_modules.get(mjs)) |b| break :blk b;
        }
        return error.ResumeNoBytecode;
    };
    return .{ .inst = inst, .tc = tc, .bc = bc };
}

// ── Held-continuation resume engine ───────────────────────────────────

/// Resolve a parked stream: stamp the response on the
/// `parked_continuations` collection and move it to `response_in`.
/// The move is the resolve-ONCE guard — `isInCollection` gates it, so
/// a racing trigger (3b-iii callback vs deadline) that already moved
/// it out is a silent no-op (expected, not an error). Body is duped
/// into an entity-owned buffer (freed by h2's RespBody teardown).
fn resolveParked(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body: []const u8,
) !void {
    const server = worker.h2;
    const allocator = worker.allocator;
    if (!server.reg.isInCollection(ent, &worker.parked_continuations)) return; // already resolved
    const owned = try allocator.dupe(u8, body);
    var owned_taken = false;
    errdefer if (!owned_taken) allocator.free(owned);
    try server.reg.set(ent, &worker.parked_continuations, h2.Status, .{ .code = status });
    try server.reg.set(ent, &worker.parked_continuations, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = owned.ptr, .len = @intCast(owned.len) });
    owned_taken = true;
    try server.reg.set(ent, &worker.parked_continuations, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &worker.parked_continuations, h2.StreamId, sid);
    try server.reg.set(ent, &worker.parked_continuations, h2.Session, sess);
    server.reg.move(ent, &worker.parked_continuations, &server.response_in) catch |err| {
        server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = null, .len = 0 }) catch {};
        allocator.free(owned);
        return err;
    };
}

/// Phase 4: post-handler-write path for a continuation-resume hop.
/// Takes ownership of `txn` (heap-allocated by the caller); on
/// success the txn is parked on `pending_txns[seq]` for
/// `drainRaftPending` to commit; on failure the helper rolls it
/// back, destroys it, and frees any owned resources in `next` so
/// the caller can degrade to a defined 500.
///
/// The post-commit move depends on `next`:
///   • `.terminal` — h2 response components are stamped on the
///     entity (still in `parked_continuations`), RaftWait is set,
///     entity moves to `raft_pending_cont`. `drainRaftPending`
///     commits → routes back to `parked_continuations`; the
///     terminal resolve then ships the response via the next
///     resume / resolveParked call. The entity's ContDescriptor
///     deinits structurally when the entity destroys; nothing to
///     clear here.
///   • `.repark` — the entity's `ContDescriptor` is mutated in
///     place: the old cont is deinit'd, the new one + new
///     bound_schedule_id transfer in, deadline refreshes; RaftWait
///     is set; entity moves to `raft_pending_cont`. Commit routes
///     back to `parked_continuations` waiting on the new
///     bound_schedule_id (or the §6.4 deadline).
///
/// Also parks the kv-wake commit gates (`parkKvWakes`) on the same
/// seq so any §4.6 wake fan-outs fire AFTER commit, alongside the
/// entity's state transition. (The send-arm commit gate retired
/// with the SendDispatch kernel in Phase 5 PR-3; `_send/owed/*` is
/// now an ordinary kv put.)
const ContResumeNext = union(enum) {
    /// Terminal flush. `body` is allocator-owned; ownership
    /// transferred into the entity's RespBody on success.
    terminal: struct { status: u16, body: []u8 },
    /// Re-park with a new continuation. `new_cont` is owned
    /// (transferred onto the entity's ContDescriptor).
    /// `new_bound_sched_id` is allocator-owned if non-null (the
    /// lone `_send/owed/{id}` this hop wrote — same §6.4
    /// inferred-bind rule as the inbound trampoline open hop).
    repark: struct {
        new_cont: Continuation,
        new_bound_sched_id: ?[]u8,
    },
    /// `docs/streaming-model.md` §7 item 1: cont→stream resume.
    /// The handler returned `stream({write, status?, headers?})`
    /// from a cont-parked entity (bound-fetch onFetchChunk
    /// resume that opens a streaming response). All slices owned
    /// and transferred onto the entity's stream components +
    /// h2 components. Module path is duped from the resume's
    /// cont module path (the chain's named-export module stays
    /// fixed across activations).
    stream: struct {
        status: u16,
        /// Response headers parsed from the stream Cmd. Caller-
        /// allocated slice + entries; ownership transfers into the
        /// h2 RespHeaders pack built by `setSimpleHeaders` /
        /// equivalent. Empty slice = no extra headers.
        resp_headers: []dispatcher_mod.ResponseHeader,
        /// Initial chunks the stream emits before the first wake.
        /// Spine + entries allocator-owned; transferred into the
        /// entity's `StreamChunks.queue` via
        /// `setStreamComponents`-equivalent staging.
        chunks: [][]u8,
        /// Customer ctx_json — threaded forward into the next
        /// activation's request body.
        ctx_json: []u8,
        /// Module path for resume — typically the same path the
        /// cont was parked against. Allocator-owned dup.
        module_path: []u8,
        /// kv-react wake prefixes. Spine + entries owned.
        kv_prefixes: [][]u8,
        /// Timer-wake interval (0 = no timer wake — fetch chunks
        /// are the wake source).
        interval_ms: i64,
    },
};

fn proposeAndParkContResume(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    writeset: *const kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    tenant_id: []const u8,
    next: ContResumeNext,
    /// Slice 3d-fetch: the cont-resume dispatch's readset, serialized
    /// onto the raft envelope's `rs_bytes` section so the resumed
    /// activation is replayable on any follower. Pointer (not value)
    /// because the readset lives in the caller's stack frame.
    readset: *const tape_mod.Readset,
    /// Slice 5a-1: per-activation LogHeader stamped into the readset
    /// blob so any follower (Phase 5c) can rebuild the customer
    /// LogRecord. `null` only for paths that genuinely have no
    /// header to stamp — caller convention is to populate it.
    log_header_opt: ?log_mod.LogHeader,
) !u64 {
    const allocator = worker.allocator;
    const server = worker.h2;

    // Release the dispatch lease BEFORE proposing — same posture as
    // worker_dispatch.zig's write path. The chain orders commits;
    // the next per-tenant batch's open lease isn't blocked on raft
    // here.
    txn.releaseLease();

    // Slice 3d-fetch: serialize the cont-resume's readset (with the
    // caller-supplied LogHeader stamped into it, slice 5a-1) wrapped
    // as the 1-item readset list the anchor envelope expects, so the
    // resumed activation is replayable on any follower. Best-effort —
    // any failure logs and we propose with empty rs_bytes (same as
    // pre-3d behavior).
    const rs_bytes: []u8 = tape_mod.encodeSingleReadset(allocator, readset, log_header_opt) catch |err| blk: {
        std.log.warn(
            "rove-js cont-resume: encodeSingleReadset tenant={s}: {s}",
            .{ tenant_id, @errorName(err) },
        );
        break :blk &.{};
    };
    defer if (rs_bytes.len > 0) allocator.free(rs_bytes);
    const seq = raft_propose.proposeBatch(worker, writeset, tenant_id, rs_bytes) catch |err| {
        // On propose failure: rollback txn, destroy it (caller's
        // ownership is implicit — we promised to consume it on
        // success OR free it on failure), free any owned resources in
        // `next`. ContDescriptor on the entity deinits structurally
        // when the entity is destroyed. Caller's catch path handles
        // the 500 flush + log.
        txn.rollback() catch {};
        allocator.destroy(txn);
        switch (next) {
            .terminal => {}, // caller still owns `body`; caller's catch frees.
            .repark => |*r| {
                if (r.new_bound_sched_id) |b| allocator.free(b);
                var c = r.new_cont;
                c.deinit(allocator);
            },
            .stream => |*s| {
                // Caller passed ownership of every slice into the
                // .stream payload; we own freeing them on the
                // propose-fail path.
                for (s.resp_headers) |h| {
                    allocator.free(h.name);
                    allocator.free(h.value);
                }
                if (s.resp_headers.len > 0) allocator.free(s.resp_headers);
                for (s.chunks) |c| allocator.free(c);
                if (s.chunks.len > 0) allocator.free(s.chunks);
                allocator.free(s.ctx_json);
                allocator.free(s.module_path);
                for (s.kv_prefixes) |p| allocator.free(p);
                if (s.kv_prefixes.len > 0) allocator.free(s.kv_prefixes);
            },
        }
        return err;
    };
    // Propose accepted. From here we own the parked-side
    // bookkeeping; if it fails the chain is in a half-state we can't
    // gracefully roll back (the raft entry is committed-pending).
    try worker.pending_txns.park(allocator, seq, txn);
    // parkKvWakes rides this seq so the kv-react wakes fire AFTER
    // commit. Best-effort: log and continue if parking fails —
    // same posture as the inbound write path. Cont-resume hops
    // don't accumulate http.fetch'es (the binding's
    // pending_fetches lives on `DispatchState`, set only by the
    // inbound H2 dispatch's `Request`).
    //
    // Phase 4.1.3 Option-2: also emit Cmd.respond so the
    // commit-arm move (raft_pending_cont → {response_in,
    // parked_continuations, stream_response_in}) routes through
    // `interpretCmd` instead of `drainEntityArm`'s inline move.
    //   - terminal → `response_in`: the chain is DONE; h2 ships the
    //     stamped Status/RespBody + closes. This mirrors the
    //     wrote=false terminal branch (which `resolveParked`s straight
    //     to `response_in`). Routing terminal-with-writes back to
    //     `parked_continuations` instead relied on "a subsequent
    //     resume/sweep ships the body" — true for chains that get a
    //     follow-up event, but a bound-fetch chain whose fetches are
    //     all done has none, so the response never shipped (the
    //     multi-bind writes-per-chunk case, docs/chunk-spool-plan.md).
    //   - repark → `parked_continuations`: the chain awaits its next
    //     bound-fetch chunk / callback.
    //   - cont→stream → `stream_response_in`: h2 picks up the stream.
    const respond_dest: effect_mod.cmd.RespondOut.DestColl = switch (next) {
        .terminal => .response_in,
        .repark => .parked_continuations,
        .stream => .stream_response_in,
    };
    var cont_cmds: effect_mod.cmd.BufferedCmds = .{};
    cont_cmds.items.append(allocator, .{ .respond = .{
        .entity = ent,
        .source = .raft_pending_cont,
        .dest = respond_dest,
    } }) catch {};
    worker_mod.parkKvWakes(worker, seq, tenant_id, writeset, cont_cmds) catch |perr|
        std.log.warn("rove-js cont-resume parkKvWakes (tenant={s}) failed: {s}", .{ tenant_id, @errorName(perr) });

    const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() +
        @as(i128, @intCast(worker.commit_wait_timeout_ns)));

    switch (next) {
        .terminal => |t| {
            // Cont-resume terminal+writes: stamp response components
            // on the entity (still in parked_continuations), then
            // move to raft_pending_cont. The raft_pending_cont
            // drainEntityArm routes the committed entity back to
            // parked_continuations; the subsequent resume / sweep /
            // resolve site ships the body. ContDescriptor stays
            // populated and deinits when the entity destroys —
            // sweep gates on isInCollection before reading it, so a
            // stale desc on an entity mid-commit-flow can't fire
            // spuriously.
            try server.reg.set(ent, &worker.parked_continuations, h2.Status, .{ .code = t.status });
            try server.reg.set(ent, &worker.parked_continuations, h2.RespHeaders, .{ .fields = null, .count = 0 });
            try server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = t.body.ptr, .len = @intCast(t.body.len) });
            try server.reg.set(ent, &worker.parked_continuations, h2.H2IoResult, .{ .err = 0 });
            try server.reg.set(ent, &worker.parked_continuations, h2.StreamId, sid);
            try server.reg.set(ent, &worker.parked_continuations, h2.Session, sess);
            try server.reg.set(ent, &worker.parked_continuations, RaftWait, .{
                .seq = seq,
                .deadline_ns = deadline_ns,
            });
            try server.reg.move(ent, &worker.parked_continuations, &worker.raft_pending_cont);
        },
        .repark => |r| {
            // Update the entity's ContDescriptor in place — replace
            // cont, refresh bound_schedule_id, refresh deadline.
            // The raft_pending_cont drainEntityArm sees the entity
            // at commit and routes back to parked_continuations.
            // Ownership of r.new_cont and r.new_bound_sched_id
            // transfers directly into the component.
            const desc = try server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor);
            if (desc.cont) |*old_c| old_c.deinit(allocator);
            desc.cont = r.new_cont;
            if (desc.bound_schedule_id) |old_b| {
                // `docs/cross-worker-held-state-plan.md` Phase 1:
                // drop the NodeState owner mirror for the OLD
                // send_id; the new one was registered above when
                // the repark scanned the writeset.
                worker.node.unregisterBoundSendOwner(old_b);
                worker.unregisterBoundSendEntity(old_b);
                allocator.free(old_b);
            }
            desc.bound_schedule_id = r.new_bound_sched_id;
            // §6.4 mandatory-timeout refresh: each new hop gets the
            // standard hold deadline, identical to the inbound
            // trampoline open hop's parking.
            const refreshed_deadline_ns: i64 = @as(i64, @intCast(std.time.nanoTimestamp())) + CONT_HOLD_DEADLINE_NS;
            desc.deadline_ns = refreshed_deadline_ns;
            try server.reg.set(ent, &worker.parked_continuations, RaftWait, .{
                .seq = seq,
                .deadline_ns = deadline_ns,
            });
            try server.reg.move(ent, &worker.parked_continuations, &worker.raft_pending_cont);
        },
        .stream => |s| {
            // `docs/streaming-model.md` §7 item 1 + Phase 2b lift:
            // cont→stream transition. The entity moves from
            // parked_continuations → raft_pending_cont → (commit
            // Cmd.respond) → stream_response_in. We install the
            // stream components (StreamChain / StreamChunks /
            // StreamWakes) on the entity in parked_continuations;
            // they ride the move into raft_pending_cont and onward
            // into stream_response_in via the merged Row.
            //
            // The existing ContDescriptor on the entity becomes
            // stale — deinit its Continuation and clear the fields.
            // ChainContext stays — same tenant / correlation id;
            // only the deployment_id and slices are reused unchanged.
            const desc = try server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor);
            if (desc.cont) |*old_c| old_c.deinit(allocator);
            if (desc.bound_schedule_id) |old_b| {
                // Phase 1 NodeState cleanup — chain is no longer
                // a cont, drop the send owner.
                worker.node.unregisterBoundSendOwner(old_b);
                worker.unregisterBoundSendEntity(old_b);
                allocator.free(old_b);
            }
            desc.* = .{};

            // Stamp h2 response components: Status + RespHeaders
            // (built from the customer-provided ResponseHeader list)
            // + empty RespBody (first-hop "empty body" — actual
            // bytes ride via StreamChunks) + H2IoResult OK +
            // identity.
            const handler_resp_hdrs: h2.RespHeaders = try respb.buildHandlerRespHeaders(
                allocator,
                null, // no CORS at this layer; the held inbound's response already set CORS via the original handler return path (not modeled here for the read-only first-hop)
                null,
                &.{},
                null,
                s.resp_headers,
            );
            // Free the customer-allocated ResponseHeader list now
            // that buildHandlerRespHeaders has packed its bytes.
            for (s.resp_headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            if (s.resp_headers.len > 0) allocator.free(s.resp_headers);

            try server.reg.set(ent, &worker.parked_continuations, h2.Status, .{ .code = s.status });
            try server.reg.set(ent, &worker.parked_continuations, h2.RespHeaders, handler_resp_hdrs);
            try server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = null, .len = 0 });
            try server.reg.set(ent, &worker.parked_continuations, h2.H2IoResult, .{ .err = 0 });
            try server.reg.set(ent, &worker.parked_continuations, h2.StreamId, sid);
            try server.reg.set(ent, &worker.parked_continuations, h2.Session, sess);

            // Install StreamChain on the entity (already in
            // parked_continuations). Module path + ctx_json transfer
            // ownership into the component.
            try server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChain, .{
                .module_path = s.module_path,
                .ctx_json = s.ctx_json,
                .activation_count = 1,
            });

            // Stage chunks through a temporary StreamChunks so the
            // §9.4 cap check fires on the first-hop chunks too —
            // identical to `setStreamComponents`'s pattern.
            {
                var staged: components_mod.StreamChunks = .{};
                errdefer components_mod.StreamChunks.deinit(allocator, (&staged)[0..1]);
                try staged.queue.ensureUnusedCapacity(allocator, s.chunks.len);
                for (s.chunks) |chunk| try staged.tryAppend(allocator, chunk);
                try server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChunks, staged);
            }
            // The spine of s.chunks held pointers transferred into
            // StreamChunks via tryAppend; free the outer spine.
            if (s.chunks.len > 0) allocator.free(s.chunks);

            // Install StreamWakes (kv-prefixes spine + entries
            // transfer ownership). interval_ms = 0 = no timer wake;
            // bound-fetch chunks are the wake source.
            const next_wake_ns: i64 = if (s.interval_ms > 0)
                @as(i64, @intCast(std.time.nanoTimestamp())) + s.interval_ms * std.time.ns_per_ms
            else
                std.math.maxInt(i64);
            try server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{
                .interval_ms = s.interval_ms,
                .next_wake_ns = next_wake_ns,
                .kv_prefixes = s.kv_prefixes,
            });

            try server.reg.set(ent, &worker.parked_continuations, RaftWait, .{
                .seq = seq,
                .deadline_ns = deadline_ns,
            });
            try server.reg.move(ent, &worker.parked_continuations, &worker.raft_pending_cont);
        },
    }
    return seq;
}

/// The trampoline resume engine (connection-actor 3b-iii post-Phase-4).
///
/// Handler-cmds Phase 8 TEA-framing:
///   - **Msg**:   `(send_callback outcome, parked-cont entity)`.
///   - **prep**:  read `ContDescriptor + ChainContext` on the entity in
///                `parked_continuations`; resolveDeployment; build
///                request body = `{fn?, args:[ctx, outcome]}` or
///                `{ctx, outcome}` with `.send_callback` activation.
///   - **run**:   `dispatcher.runOutcome` against the chain-tail txn.
///   - **apply (Cmd-list)**: switch on outcome ×
///                {writes? × allow_repark?}:
///       • terminal + no writes → flush to the held socket immediately.
///       • terminal + writes → propose, park on raft_pending_cont,
///         flush on commit (`proposeAndParkContResume(.terminal)`).
///       • continuation + no writes → re-park (only if `allow_repark`);
///         speculative commit is durable enough — no raft hop.
///       • continuation + writes (allow_repark) → propose, park on
///         raft_pending_cont; the drainEntityArm re-parks on commit
///         (`proposeAndParkContResume(.repark)` — recipe-1 real-retry).
///       • continuation + !allow_repark → defined 504 (deadline).
///       • stream → defined 501 (`cont → stream` is a later phase).
/// The deadline trigger passes `allow_repark = false`.
/// `error.Resume*` → caller falls back to a hard 504.
fn resumeContinuation(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    outcome_json: []const u8,
    allow_repark: bool,
) !void {
    const allocator = worker.allocator;
    const server = worker.h2;
    // Resolve-once guard: membership in `parked_continuations` IS
    // the cont-state discriminant. Cont state (path / fn_name /
    // ctx_json / tenant_id / correlation_id) reads from the
    // entity's components. The slices borrow into the component's
    // heap allocations; they stay valid across moves
    // (`merged_request_row` carries the components on every
    // destination collection) and across in-place mutations
    // (`proposeAndParkContResume` deinits the old cont before
    // installing a new one — but only AFTER capturing these locals,
    // and the function never reuses them after the mutation site).
    if (!server.reg.isInCollection(ent, &worker.parked_continuations)) return; // resolve-once
    const desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch return;
    const chain = server.reg.get(ent, &worker.parked_continuations, components_mod.ChainContext) catch return;
    const c = desc.cont orelse return;
    const tenant_id = chain.tenant_id;
    const correlation_id = chain.correlation_id;
    const cont_path = c.path;
    const cont_fn_name = c.fn_name;
    const cont_ctx_json = c.ctx_json;
    const path = cont_path;
    var dep = try resolveDeployment(worker, allocator, tenant_id, path);
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // A continuation is an internal request: named export → RPC
    // envelope `{fn,args:[ctx,outcome]}`; default export → body
    // object `{ctx,outcome}`. ctx_json/outcome_json are JSON text
    // embedded verbatim.
    const body = if (cont_fn_name) |fnname|
        try std.fmt.allocPrint(allocator, "{{\"fn\":\"{s}\",\"args\":[{s},{s}]}}", .{ fnname, cont_ctx_json, outcome_json })
    else
        try std.fmt.allocPrint(allocator, "{{\"ctx\":{s},\"outcome\":{s}}}", .{ cont_ctx_json, outcome_json });
    defer allocator.free(body);
    const spath = try std.fmt.allocPrint(allocator, "/{s}", .{path});
    defer allocator.free(spath);

    // Heap-allocate the txn so its pointer can be parked on
    // `pending_txns[seq]` if this hop wrote (Phase 4). Same stable-
    // address pattern the inbound dispatch path uses.
    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return error.ResumeTxnAlloc;
    var txn_owned = true; // we destroy unless ownership transfers to pending_txns
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
        // Inherit the chain id from the parking request so every
        // tape row of this chain shares one correlation_id; mark
        // this activation as a send-callback resume (streaming-
        // handlers-plan §6).
        .correlation_id = correlation_id,
        .activation_source = .send_callback,
    };
    std.log.info("rove-js corr: resume corr={s} request_id={d} tenant={s}", .{ correlation_id orelse "(none)", request_id, inst.id });
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    var oc = worker.dispatcher.runOutcome(
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
        try resolveParked(worker, ent, sid, sess, 500, "continuation handler error\n");
        return;
    };

    const wrote = ws.ops.items.len > 0;
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            // A thrown resume hop is an EXPECTED condition (author
            // error). It must be a defined 5xx, never a flushed
            // 200-empty (that masked the recipe-1 effectful-resume
            // gap) — feedback_infallibility_violations.
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                try resolveParked(worker, ent, sid, sess, 500, "continuation handler error\n");
                // Phase 1b: record the resume's tape entry. Activation
                // source = send_callback so the row shares the chain
                // id with the inbound entry and the replay UX groups
                // them.
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, correlation_id, .send_callback, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                // Phase 4: terminal + writes — propose the writes
                // through raft, park the entity on `raft_pending_cont`
                // with the response components staged on it. The
                // raft_pending_cont drainEntityArm routes the
                // committed entity back to `parked_continuations`,
                // where the subsequent resume / sweep / resolve
                // site ships the response.
                const corr_id = correlation_id;
                const dep_id = tc.snap.deployment_id;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                const body_dup = try allocator.dupe(u8, r.body);
                errdefer allocator.free(body_dup);
                const console_owned = r.console;
                const exception_owned = r.exception;
                r.console = &.{};
                r.exception = &.{};
                const lh_terminal: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = dep_id,
                    .duration_ns = 0,
                    .status = st,
                    .outcome = .ok,
                    .activation = .send_callback,
                    .method = "POST",
                    .path = cont_path,
                    .host = "",
                    .correlation_id = corr_id orelse "",
                };
                const cont_seq = proposeAndParkContResume(
                    worker,
                    ent,
                    sid,
                    sess,
                    &ws,
                    txn,
                    tenant_id,
                    .{ .terminal = .{
                        .status = st,
                        .body = body_dup,
                    } },
                    &readset,
                    lh_terminal,
                ) catch |perr| {
                    // Propose-fail / pre-park alloc failure: degrade
                    // to a 500 over the held socket. The txn was
                    // rolled back + destroyed inside the helper.
                    std.log.warn("rove-js cont-resume: propose failed: {s}", .{@errorName(perr)});
                    allocator.free(body_dup);
                    txn_owned = false; // helper destroyed it
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "continuation write replication failed\n") catch {};
                    captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, 500, .fault, console_owned, exception_owned, .{}, corr_id, .send_callback, 0);
                    return;
                };
                // proposeAndParkContResume took ownership of txn (moved
                // into pending_txns) and body_dup (stamped onto entity).
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, st, .ok, console_owned, exception_owned, .{}, corr_id, .send_callback, cont_seq);
                return;
            }
            // Clean read-only commit cannot fault (mirrors
            // finalizeBatch read-only invariant) — panic, never soft.
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeContinuation.commit(read_only)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            try resolveParked(worker, ent, sid, sess, st, r.body);
            captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, correlation_id, .send_callback, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |c2| {
            var c2m = c2;
            if (!allow_repark) {
                // Deadline path: §6.4 mandatory timeout must
                // terminate, not extend. Reject any new cont with
                // a defined 504 over the held socket.
                c2m.deinit(allocator);
                txn.rollback() catch {};
                txn_done = true;
                try resolveParked(worker, ent, sid, sess, 504, "hold deadline exceeded\n");
                return;
            }
            if (wrote) {
                // Phase 4: continuation + writes — propose, park
                // on `raft_pending_cont`; on commit the
                // raft_pending_cont drainEntityArm routes the
                // entity back to `parked_continuations`
                // with the in-place-updated ContDescriptor (new
                // cont, refreshed bound_schedule_id, refreshed
                // deadline). The new bound_schedule_id (the lone
                // `_send/owed/` this hop wrote, if exactly one)
                // becomes the wake the next callback resolves on.
                // Same fail-fast posture as the terminal+writes
                // branch.
                const corr_id = correlation_id;
                const dep_id = tc.snap.deployment_id;
                // §6.4 binding for the repark: scan the writeset
                // for the single _send/owed/{id} put. 0 / >1 → null
                // (deadline-only resume).
                const new_bound_sched_id: ?[]u8 = blk: {
                    const only = worker_mod.scanLoneOwedSendId(ws.ops.items) orelse break :blk null;
                    break :blk try allocator.dupe(u8, only);
                };
                // `docs/cross-worker-held-state-plan.md` Phase 1:
                // repark re-binds to a (possibly new) send_id —
                // stamp the owner. Same Phase 2 dependency as the
                // open-hop site in worker_dispatch.zig.
                if (new_bound_sched_id) |send_id| {
                    _ = worker.node.registerBoundSendOwner(send_id, worker.msg_inbox_idx);
                    // Phase 3 mirror.
                    worker.registerBoundSendEntity(send_id, ent);
                }
                const lh_repark: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = dep_id,
                    .duration_ns = 0,
                    // captureLogWithId on this branch records status=0
                    // (the parked-hop convention — same shape as the
                    // inbound trampoline open hop). Mirror that here
                    // so replay surfaces the same value.
                    .status = 0,
                    .outcome = .ok,
                    .activation = .send_callback,
                    .method = "POST",
                    .path = cont_path,
                    .host = "",
                    .correlation_id = corr_id orelse "",
                };
                const repark_seq = proposeAndParkContResume(
                    worker,
                    ent,
                    sid,
                    sess,
                    &ws,
                    txn,
                    tenant_id,
                    .{ .repark = .{
                        .new_cont = c2m,
                        .new_bound_sched_id = new_bound_sched_id,
                    } },
                    &readset,
                    lh_repark,
                ) catch |perr| {
                    // Helper rolled back + destroyed txn + freed
                    // c2m + new_bound_sched_id on failure; we just
                    // log + degrade.
                    std.log.warn("rove-js cont-resume (repark): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "continuation write replication failed\n") catch {};
                    captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, 500, .fault, &.{}, &.{}, .{}, corr_id, .send_callback, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                // Log the repark hop's tape row. status=0 (parked,
                // same as the inbound trampoline open hop's
                // captureSuccess shape).
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, 0, .ok, &.{}, &.{}, .{}, corr_id, .send_callback, repark_seq);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeContinuation.commit(repark_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            // Re-park: swap the descriptor in place on the entity's
            // ContDescriptor component, refresh the deadline; the
            // entity stays in `parked_continuations`. Ownership of
            // c2m transfers directly to the component;
            // bound_schedule_id is untouched on the read-only path
            // (only the write-batch repark in
            // `proposeAndParkContResume` rewrites it).
            const refreshed_deadline_ns: i64 = now_ns + CONT_HOLD_DEADLINE_NS;
            if (desc.cont) |*old_c| old_c.deinit(allocator);
            desc.cont = c2m;
            desc.deadline_ns = refreshed_deadline_ns;
        },
        .stream => |*s| {
            // `docs/streaming-model.md` §7 item 1 (Phase 2b lift):
            // cont→stream transition on resume. Install stream
            // components on the entity (still in
            // parked_continuations); on a write path propose +
            // park via raft + Cmd.respond(dest=stream_response_in);
            // on read-only path commit inline + move directly to
            // stream_response_in. Either way the held socket
            // transitions from "cont awaiting one wake" to
            // "stream emitting chunks per wake" — bound-fetch
            // chunks become the wake source.
            //
            // Parse the customer's stream({headers}) wire-format
            // buffer (`Key: Val\r\n…`) into the typed list shape
            // proposeAndParkContResume expects. Empty / null →
            // empty list.
            const parsed_headers: []dispatcher_mod.ResponseHeader = if (s.headers) |hbuf|
                @import("worker_dispatch.zig").parseStreamHeaders(allocator, hbuf) catch &.{}
            else
                &.{};
            // headers buffer consumed (parseStreamHeaders copied
            // bytes onto its return entries); free the original.
            if (s.headers) |h| allocator.free(h);
            s.headers = null;

            // Module path for resume — duped from the cont's
            // current path so subsequent fetch chunks find the
            // same module.
            const module_path_dup = allocator.dupe(u8, cont_path) catch {
                // Allocator failure: free what we have, 500.
                for (parsed_headers) |h| { allocator.free(h.name); allocator.free(h.value); }
                if (parsed_headers.len > 0) allocator.free(parsed_headers);
                s.deinit(allocator);
                txn.rollback() catch {};
                txn_done = true;
                try resolveParked(worker, ent, sid, sess, 500, "stream resume alloc failed\n");
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, correlation_id, .send_callback, 0);
                return;
            };

            // Transfer ownership of every slice OUT of `s` into
            // the .stream ContResumeNext payload. Clear `s`'s
            // fields so its remaining lifetime is a no-op deinit
            // — we don't call s.deinit() (the payload is now in
            // the variant).
            const stream_status = s.status;
            const stream_chunks = s.chunks;
            const stream_ctx_json = s.ctx_json;
            const stream_kv_prefixes = s.kv_prefixes;
            const stream_interval = s.interval_ms orelse 0;
            s.chunks = &.{};
            s.ctx_json = &.{};
            s.kv_prefixes = &.{};

            if (wrote) {
                const lh_stream: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 0, // parked-hop convention (matches repark)
                    .outcome = .ok,
                    .activation = .send_callback,
                    .method = "POST",
                    .path = cont_path,
                    .host = "",
                    .correlation_id = correlation_id orelse "",
                };
                const stream_seq = proposeAndParkContResume(
                    worker,
                    ent,
                    sid,
                    sess,
                    &ws,
                    txn,
                    tenant_id,
                    .{ .stream = .{
                        .status = stream_status,
                        .resp_headers = parsed_headers,
                        .chunks = stream_chunks,
                        .ctx_json = stream_ctx_json,
                        .module_path = module_path_dup,
                        .kv_prefixes = stream_kv_prefixes,
                        .interval_ms = stream_interval,
                    } },
                    &readset,
                    lh_stream,
                ) catch |perr| {
                    // proposeAndParkContResume's failure arm freed
                    // every payload slice + destroyed the txn.
                    std.log.warn("rove-js cont-resume (stream): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "stream resume write replication failed\n") catch {};
                    captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, correlation_id, .send_callback, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 0, .ok, &.{}, &.{}, .{}, correlation_id, .send_callback, stream_seq);
                return;
            }

            // Read-only stream resume: commit inline (nothing to
            // replicate), install stream components, ship initial
            // response, move parked_continuations →
            // stream_response_in directly. The §2 one-rule still
            // holds — read-only commits before the chunk reaches
            // the wire (h2 ships from stream_data_out, which the
            // entity reaches only after this move).
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeContinuation.commit(stream_read_only)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;

            // Dupe cont_path BEFORE clearing the ContDescriptor —
            // cont_path borrows into desc.cont.path; the deinit
            // frees that backing memory and any later read (e.g.
            // captureLogWithId below) would be use-after-free.
            const cont_path_for_log = allocator.dupe(u8, cont_path) catch &.{};
            defer if (cont_path_for_log.len > 0) allocator.free(cont_path_for_log);

            // Clear the stale ContDescriptor (the chain is no
            // longer a cont). ChainContext stays.
            const stale_desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch null;
            if (stale_desc) |d| {
                if (d.cont) |*old_c| old_c.deinit(allocator);
                if (d.bound_schedule_id) |b| {
                    worker.node.unregisterBoundSendOwner(b);
                    worker.unregisterBoundSendEntity(b);
                    allocator.free(b);
                }
                d.* = .{};
            }

            const handler_resp_hdrs: h2.RespHeaders = respb.buildHandlerRespHeaders(
                allocator,
                null,
                null,
                &.{},
                null,
                parsed_headers,
            ) catch {
                for (parsed_headers) |h| { allocator.free(h.name); allocator.free(h.value); }
                if (parsed_headers.len > 0) allocator.free(parsed_headers);
                allocator.free(module_path_dup);
                allocator.free(stream_ctx_json);
                for (stream_chunks) |chunk_bytes| allocator.free(chunk_bytes);
                if (stream_chunks.len > 0) allocator.free(stream_chunks);
                for (stream_kv_prefixes) |p| allocator.free(p);
                if (stream_kv_prefixes.len > 0) allocator.free(stream_kv_prefixes);
                resolveParked(worker, ent, sid, sess, 500, "stream resume header build failed\n") catch {};
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path_for_log, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, correlation_id, .send_callback, 0);
                return;
            };
            for (parsed_headers) |h| { allocator.free(h.name); allocator.free(h.value); }
            if (parsed_headers.len > 0) allocator.free(parsed_headers);

            server.reg.set(ent, &worker.parked_continuations, h2.Status, .{ .code = stream_status }) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.RespHeaders, handler_resp_hdrs) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = null, .len = 0 }) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.H2IoResult, .{ .err = 0 }) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.StreamId, sid) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.Session, sess) catch {};
            server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChain, .{
                .module_path = module_path_dup,
                .ctx_json = stream_ctx_json,
                .activation_count = 1,
            }) catch {};

            var staged: components_mod.StreamChunks = .{};
            staged.queue.ensureUnusedCapacity(allocator, stream_chunks.len) catch {};
            for (stream_chunks) |chunk| staged.tryAppend(allocator, chunk) catch {};
            server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChunks, staged) catch {};
            if (stream_chunks.len > 0) allocator.free(stream_chunks);

            const next_wake_ns: i64 = if (stream_interval > 0)
                @as(i64, @intCast(std.time.nanoTimestamp())) + stream_interval * std.time.ns_per_ms
            else
                std.math.maxInt(i64);
            server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{
                .interval_ms = stream_interval,
                .next_wake_ns = next_wake_ns,
                .kv_prefixes = stream_kv_prefixes,
            }) catch {};

            // moveImmediate so subsequent fetch chunks arriving in
            // the same worker tick see the entity in
            // stream_response_in (chunks 0..N from the same bound
            // fetch typically arrive in one batch — see Gap #1
            // smoke). reg.move (deferred) would leave the entity in
            // parked_continuations until the next flush, causing
            // chunks 1+ to dispatch against stale state.
            server.reg.moveImmediate(ent, &worker.parked_continuations, &server.stream_response_in) catch |merr|
                std.log.warn("rove-js cont→stream move: {s}", .{@errorName(merr)});
            captureLogWithId(worker, tenant_id, request_id, "POST", cont_path_for_log, "", tc.snap.deployment_id, now_ns, 0, .ok, &.{}, &.{}, .{}, correlation_id, .send_callback, 0);
        },
    }
}

/// `docs/streaming-model.md` §7 item 1 + `docs/handler-shape.md`
/// §5.5: bound-fetch resume engine. Sibling of `resumeContinuation`:
/// an upstream chunk for a fetch issued from a held chain wakes the
/// chain via its module's `onFetchChunk` named export.
///
/// V1 scope — handles only chunks arriving on a chain still in
/// `parked_continuations` (first-chunk-on-cont). Subsequent chunks
/// on a chain that already transitioned cont→stream (returned
/// `stream({write})` on a prior chunk) need to wake the stream
/// chain instead; that path is a follow-up (the stream-resume
/// engine needs to grow a `.fetch_chunk` activation source). For
/// now, lookups that find the entity outside `parked_continuations`
/// fall through to the unbound `fireFetchEventActivation` path
/// with a warning.
///
/// Owns `ev` — every exit path deinits the event (mirrors
/// `fireFetchEventActivation`'s ownership contract).
pub fn resumeBoundFetchChain(
    worker: anytype,
    ent: rove.Entity,
    ev: *components_mod.UpstreamFetchEvent,
) void {
    var deinit_event = true;
    defer if (deinit_event) components_mod.UpstreamFetchEvent.deinitItem(ev, worker.allocator);

    const allocator = worker.allocator;
    const server = worker.h2;
    if (!server.reg.isInCollection(ent, &worker.parked_continuations)) {
        // V1 limitation: bound chunks arriving for a chain that's
        // already transitioned to stream aren't wired yet. Log and
        // fall through to the unbound path by handing the event
        // back to the caller's normal dispatch. We return the
        // event with the bind flag cleared so the caller routes
        // to `fireFetchEventActivation`.
        std.log.info(
            "rove-js bound-fetch: entity not in parked_continuations for fetch_id={s}; stream-chain bound resume is a follow-up. Falling back to unbound dispatch.",
            .{ev.fetch_id},
        );
        deinit_event = false;
        ev.bind = false;
        worker_mod.fireFetchEventActivation(worker, ev, null);
        return;
    }
    const desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch return;
    const chain = server.reg.get(ent, &worker.parked_continuations, components_mod.ChainContext) catch return;
    const c = desc.cont orelse return;
    const tenant_id = chain.tenant_id;
    const correlation_id = chain.correlation_id;
    const cont_path = c.path;
    const path = cont_path;
    var dep = resolveDeployment(worker, allocator, tenant_id, path) catch |err| {
        std.log.warn(
            "rove-js bound-fetch resume: resolveDeployment tenant={s} module={s}: {s}",
            .{ tenant_id, path, @errorName(err) },
        );
        return;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // Build the resume request. Target the customer's chosen
    // named export — `ev.name` if the bind specified `name:`,
    // else default `onFetchChunk`. Body is `{ctx: <ctx_json>}` —
    // handler reads `request.body` for the chunk bytes from the
    // activation_fetch_bytes slot, not from request.body.
    const ctx_src: []const u8 = if (ev.ctx_json.len > 0) ev.ctx_json else "{}";
    const body = std.fmt.allocPrint(allocator, "{{\"ctx\":{s}}}", .{ctx_src}) catch return;
    defer allocator.free(body);
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

    // Snapshot the per-chain pending-bound-fetch count BEFORE the
    // activation runs. The component lives on the entity (still
    // in parked_continuations here); the merged Row guarantees
    // it's accessible. `0` is the safe default when the
    // component read fails (corrupt entity / wrong collection —
    // both shouldn't happen but we don't want to panic on it).
    const fetches_pending: u32 = blk: {
        const cnt = server.reg.get(ent, &worker.parked_continuations, components_mod.BoundFetchCount) catch break :blk 0;
        break :blk cnt.pending;
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
        .correlation_id = correlation_id,
        .activation_source = .fetch_chunk,
        .activation_fetch_id = ev.fetch_id,
        .is_system_module = builtin_modules_mod.isBuiltinPath(path),
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

    // Read sid/sess from the entity's components BEFORE dispatch
    // so the error path can resolve the held socket cleanly.
    // resumeContinuation reads them from caller-supplied locals;
    // here we pull from the parked_continuations collection.
    const sid_ptr = server.reg.get(ent, &worker.parked_continuations, h2.StreamId) catch return;
    const sess_ptr = server.reg.get(ent, &worker.parked_continuations, h2.Session) catch return;
    const sid = sid_ptr.*;
    const sess = sess_ptr.*;

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
        resolveParked(worker, ent, sid, sess, 500, "bound-fetch handler error\n") catch {};
        return;
    };

    const wrote = ws.ops.items.len > 0;

    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            // Chain is going terminal — cancel any sibling binds
            // pointing at this entity so their in-flight chunks
            // don't tail-drop into the "mid-transition" branch.
            // Idempotent + safe for the single-bind case (the
            // dispatch wrapper's `if (final) unregisterBoundFetch`
            // would have done it anyway). Per-fetch counter (4)
            // will hook the same call path.
            worker_mod.scanAndCancelBoundFetches(worker, ent);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                resolveParked(worker, ent, sid, sess, 500, "bound-fetch handler exception\n") catch {};
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, correlation_id, .fetch_chunk, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            if (wrote) {
                const body_dup = allocator.dupe(u8, r.body) catch {
                    txn.rollback() catch {};
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "bound-fetch alloc failed\n") catch {};
                    return;
                };
                const lh: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = st,
                    .outcome = .ok,
                    .activation = .fetch_chunk,
                    .method = "POST",
                    .path = cont_path,
                    .host = "",
                    .correlation_id = correlation_id orelse "",
                };
                const console_owned = r.console;
                const exception_owned = r.exception;
                r.console = &.{};
                r.exception = &.{};
                const seq = proposeAndParkContResume(
                    worker,
                    ent,
                    sid,
                    sess,
                    &ws,
                    txn,
                    tenant_id,
                    .{ .terminal = .{ .status = st, .body = body_dup } },
                    &readset,
                    lh,
                ) catch |perr| {
                    std.log.warn("rove-js bound-fetch propose failed: {s}", .{@errorName(perr)});
                    allocator.free(body_dup);
                    txn_owned = false;
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "bound-fetch replication failed\n") catch {};
                    captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .fault, console_owned, exception_owned, .{}, correlation_id, .fetch_chunk, 0);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, st, .ok, console_owned, exception_owned, .{}, correlation_id, .fetch_chunk, seq);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeBoundFetchChain.commit(terminal_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            resolveParked(worker, ent, sid, sess, st, r.body) catch {};
            captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, correlation_id, .fetch_chunk, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |c2| {
            // Re-park: refresh the cont descriptor + deadline. The
            // chain stays awaiting the next bound-fetch chunk.
            const c2m = c2;
            const new_bound_sched_id: ?[]u8 = blk: {
                const only = worker_mod.scanLoneOwedSendId(ws.ops.items) orelse break :blk null;
                break :blk allocator.dupe(u8, only) catch null;
            };
            // Phase 1 NodeState owner registration for the new
            // bound send (same as the worker_dispatch open-hop and
            // resumeContinuation repark sites).
            if (new_bound_sched_id) |send_id| {
                _ = worker.node.registerBoundSendOwner(send_id, worker.msg_inbox_idx);
                // Phase 3 mirror.
                worker.registerBoundSendEntity(send_id, ent);
            }
            if (wrote) {
                const lh: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 0,
                    .outcome = .ok,
                    .activation = .fetch_chunk,
                    .method = "POST",
                    .path = cont_path,
                    .host = "",
                    .correlation_id = correlation_id orelse "",
                };
                const seq = proposeAndParkContResume(
                    worker,
                    ent,
                    sid,
                    sess,
                    &ws,
                    txn,
                    tenant_id,
                    .{ .repark = .{ .new_cont = c2m, .new_bound_sched_id = new_bound_sched_id } },
                    &readset,
                    lh,
                ) catch |perr| {
                    std.log.warn("rove-js bound-fetch repark: propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "bound-fetch replication failed\n") catch {};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 0, .ok, &.{}, &.{}, .{}, correlation_id, .fetch_chunk, seq);
                return;
            }
            // Read-only repark — refresh cont in place.
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeBoundFetchChain.commit(repark_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const mutable_desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch return;
            if (mutable_desc.cont) |*old_c| old_c.deinit(allocator);
            mutable_desc.cont = c2m;
            if (mutable_desc.bound_schedule_id) |old_b| {
                worker.node.unregisterBoundSendOwner(old_b);
                worker.unregisterBoundSendEntity(old_b);
                allocator.free(old_b);
            }
            mutable_desc.bound_schedule_id = new_bound_sched_id;
            mutable_desc.deadline_ns = now_ns + CONT_HOLD_DEADLINE_NS;
        },
        .stream => |*s| {
            // cont→stream transition. Parse headers, take ownership
            // of stream payload slices, route through
            // proposeAndParkContResume(.stream) on write path or
            // inline on read-only.
            const parsed_headers: []dispatcher_mod.ResponseHeader = if (s.headers) |hbuf|
                @import("worker_dispatch.zig").parseStreamHeaders(allocator, hbuf) catch &.{}
            else
                &.{};
            if (s.headers) |h| allocator.free(h);
            s.headers = null;
            const module_path_dup = allocator.dupe(u8, cont_path) catch {
                for (parsed_headers) |h| { allocator.free(h.name); allocator.free(h.value); }
                if (parsed_headers.len > 0) allocator.free(parsed_headers);
                s.deinit(allocator);
                txn.rollback() catch {};
                txn_done = true;
                resolveParked(worker, ent, sid, sess, 500, "bound-fetch stream alloc failed\n") catch {};
                return;
            };
            const stream_status = s.status;
            const stream_chunks = s.chunks;
            const stream_ctx_json = s.ctx_json;
            const stream_kv_prefixes = s.kv_prefixes;
            const stream_interval = s.interval_ms orelse 0;
            s.chunks = &.{};
            s.ctx_json = &.{};
            s.kv_prefixes = &.{};

            if (wrote) {
                const lh: log_mod.LogHeader = .{
                    .request_id = request_id,
                    .deployment_id = tc.snap.deployment_id,
                    .duration_ns = 0,
                    .status = 0,
                    .outcome = .ok,
                    .activation = .fetch_chunk,
                    .method = "POST",
                    .path = cont_path,
                    .host = "",
                    .correlation_id = correlation_id orelse "",
                };
                const seq = proposeAndParkContResume(
                    worker,
                    ent,
                    sid,
                    sess,
                    &ws,
                    txn,
                    tenant_id,
                    .{ .stream = .{
                        .status = stream_status,
                        .resp_headers = parsed_headers,
                        .chunks = stream_chunks,
                        .ctx_json = stream_ctx_json,
                        .module_path = module_path_dup,
                        .kv_prefixes = stream_kv_prefixes,
                        .interval_ms = stream_interval,
                    } },
                    &readset,
                    lh,
                ) catch |perr| {
                    std.log.warn("rove-js bound-fetch stream: propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "bound-fetch stream replication failed\n") catch {};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 0, .ok, &.{}, &.{}, .{}, correlation_id, .fetch_chunk, seq);
                return;
            }
            // Read-only stream resume. Mirror resumeContinuation's
            // inline path: commit, stamp components, move to
            // stream_response_in.
            txn.commit() catch |e| panic_mod.invariantViolated(
                "resumeBoundFetchChain.commit(stream_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            // Dupe cont_path BEFORE deinit'ing the ContDescriptor —
            // cont_path borrows into desc.cont.path; the deinit
            // below frees it, and a later captureLogWithId would
            // read freed memory. The dupe gives us a stable slice
            // for log + cleanup. Free at end of arm.
            const cont_path_for_log = allocator.dupe(u8, cont_path) catch &.{};
            defer if (cont_path_for_log.len > 0) allocator.free(cont_path_for_log);
            const stale_desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch null;
            if (stale_desc) |d| {
                if (d.cont) |*old_c| old_c.deinit(allocator);
                if (d.bound_schedule_id) |b| {
                    worker.node.unregisterBoundSendOwner(b);
                    worker.unregisterBoundSendEntity(b);
                    allocator.free(b);
                }
                d.* = .{};
            }
            const handler_resp_hdrs: h2.RespHeaders = respb.buildHandlerRespHeaders(
                allocator, null, null, &.{}, null, parsed_headers,
            ) catch {
                for (parsed_headers) |h| { allocator.free(h.name); allocator.free(h.value); }
                if (parsed_headers.len > 0) allocator.free(parsed_headers);
                allocator.free(module_path_dup);
                allocator.free(stream_ctx_json);
                for (stream_chunks) |chunk_bytes| allocator.free(chunk_bytes);
                if (stream_chunks.len > 0) allocator.free(stream_chunks);
                for (stream_kv_prefixes) |p| allocator.free(p);
                if (stream_kv_prefixes.len > 0) allocator.free(stream_kv_prefixes);
                resolveParked(worker, ent, sid, sess, 500, "bound-fetch stream header build failed\n") catch {};
                return;
            };
            for (parsed_headers) |h| { allocator.free(h.name); allocator.free(h.value); }
            if (parsed_headers.len > 0) allocator.free(parsed_headers);

            server.reg.set(ent, &worker.parked_continuations, h2.Status, .{ .code = stream_status }) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.RespHeaders, handler_resp_hdrs) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = null, .len = 0 }) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.H2IoResult, .{ .err = 0 }) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.StreamId, sid) catch {};
            server.reg.set(ent, &worker.parked_continuations, h2.Session, sess) catch {};
            server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChain, .{
                .module_path = module_path_dup,
                .ctx_json = stream_ctx_json,
                .activation_count = 1,
            }) catch {};
            var staged: components_mod.StreamChunks = .{};
            staged.queue.ensureUnusedCapacity(allocator, stream_chunks.len) catch {};
            for (stream_chunks) |chunk| staged.tryAppend(allocator, chunk) catch {};
            server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChunks, staged) catch {};
            if (stream_chunks.len > 0) allocator.free(stream_chunks);
            const next_wake_ns: i64 = if (stream_interval > 0)
                @as(i64, @intCast(std.time.nanoTimestamp())) + stream_interval * std.time.ns_per_ms
            else
                std.math.maxInt(i64);
            server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{
                .interval_ms = stream_interval,
                .next_wake_ns = next_wake_ns,
                .kv_prefixes = stream_kv_prefixes,
            }) catch {};
            // moveImmediate — same reasoning as resumeContinuation's
            // .stream arm: subsequent bound-fetch chunks arriving in
            // the same worker tick need to see the new collection.
            server.reg.moveImmediate(ent, &worker.parked_continuations, &server.stream_response_in) catch |merr|
                std.log.warn("rove-js bound-fetch stream move: {s}", .{@errorName(merr)});
            captureLogWithId(worker, tenant_id, request_id, "POST", cont_path_for_log, "", tc.snap.deployment_id, now_ns, 0, .ok, &.{}, &.{}, .{}, correlation_id, .fetch_chunk, 0);
        },
    }
}

/// §6.4 Part B: an `http.send` bound to a parked continuation
/// completed — resume the held stream with the result as the outcome
/// (the call's success/failure IS the resume input). Returns true iff
/// a parked continuation on THIS worker matched (caller then deletes
/// the `c/` receipt); false → not here (cross-worker is task #8;
/// caller falls through to the normal callback path). MUST be called
/// with no tenant batch txn open — `resumeContinuation` opens its own
/// `beginTrackedImmediate`; nesting it inside the callback batch txn
/// would double-BEGIN the same kvexp env. `allow_repark = true`: the
/// hop may re-issue `http.send` + return another continuation
/// (recipe-1 retry) — unlike the deadline path which must terminate.
pub fn resumeBoundContinuation(
    worker: anytype,
    tenant_id: []const u8,
    sched_id: []const u8,
    outcome_json: []const u8,
) bool {
    // Phase 3: O(1) map lookup via the worker-local
    // `bound_send_entities` registry, populated alongside the
    // NodeState owner map at the cont_bound_sched_id scan sites.
    // Phase 2B routing guarantees the cont is on this worker if
    // it's anywhere; the map gives the entity directly without
    // scanning every parked cont.
    //
    // Lookup miss → fall back to the linear scan over
    // `parked_continuations` as a safety net (registry stale /
    // wrong / lost). Same scan that pre-Phase-3 ran on every
    // call.
    const server = worker.h2;
    if (worker.lookupBoundSendEntity(sched_id)) |ent| {
        if (server.reg.isInCollection(ent, &worker.parked_continuations)) {
            const chain = server.reg.get(ent, &worker.parked_continuations, components_mod.ChainContext) catch null;
            const desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch null;
            if (chain != null and desc != null and std.mem.eql(u8, chain.?.tenant_id, tenant_id)) {
                const bsid = desc.?.bound_schedule_id;
                if (bsid != null and std.mem.eql(u8, bsid.?, sched_id)) {
                    const sid = server.reg.get(ent, &worker.parked_continuations, h2.StreamId) catch return false;
                    const sess = server.reg.get(ent, &worker.parked_continuations, h2.Session) catch return false;
                    resumeContinuation(worker, ent, sid.*, sess.*, outcome_json, true) catch |err| {
                        std.log.warn(
                            "rove-js cont-resume: {s}/{s}: {s}; 502",
                            .{ tenant_id, sched_id, @errorName(err) },
                        );
                        resolveParked(worker, ent, sid.*, sess.*, 502, "continuation resume failed\n") catch {};
                    };
                    return true;
                }
            }
        }
    }

    // Fallback scan. The bound_send_entities map is supposed to
    // be canonical; a hit here means the registry got out of sync
    // (component freed without unregister, double-bind collision,
    // etc.) and the scan is the safety net per the
    // cross-worker-held-state-plan §3 Phase 3 design.
    const ents = worker.parked_continuations.entitySlice();
    if (ents.len == 0) return false;
    const sids = worker.parked_continuations.column(h2.StreamId);
    const sesss = worker.parked_continuations.column(h2.Session);
    const descs = worker.parked_continuations.column(components_mod.ContDescriptor);
    const chains = worker.parked_continuations.column(components_mod.ChainContext);
    for (ents, sids, sesss, descs, chains) |ent, sid, sess, desc, chain| {
        const bsid = desc.bound_schedule_id orelse continue;
        if (!std.mem.eql(u8, chain.tenant_id, tenant_id)) continue;
        if (!std.mem.eql(u8, bsid, sched_id)) continue;
        std.log.info(
            "rove-js cont-resume: registry miss; fallback scan matched send_id={s} tenant={s}",
            .{ sched_id, tenant_id },
        );
        resumeContinuation(worker, ent, sid, sess, outcome_json, true) catch |err| {
            std.log.warn(
                "rove-js cont-resume: {s}/{s}: {s}; 502",
                .{ tenant_id, sched_id, @errorName(err) },
            );
            resolveParked(worker, ent, sid, sess, 502, "continuation resume failed\n") catch {};
        };
        return true;
    }
    return false;
}

/// Phase 5 PR-3: drain `pending_bound_resumes` — the deferred §6.4
/// held-sync resumes the baked `__system/webhook_onresult` shim
/// enqueued via `resumeIfBoundTrampoline`. Called from the worker
/// tick after `dispatchPendingMsgs`; by then the shim's batch txn
/// is committed, so `resumeBoundContinuation`'s
/// `beginTrackedImmediate` doesn't nest.
pub fn drainPendingBoundResumes(worker: anytype) void {
    if (worker.pending_bound_resumes.items.len == 0) return;
    const allocator = worker.allocator;
    // Take ownership of the current batch; new entries arriving
    // mid-drain stay queued for the next tick (avoids re-entrant
    // dispatch).
    var local = worker.pending_bound_resumes;
    worker.pending_bound_resumes = .empty;
    defer {
        for (local.items) |*p| p.deinit(allocator);
        local.deinit(allocator);
    }
    for (local.items) |p| {
        _ = resumeBoundContinuation(worker, p.tenant_id, p.send_id, p.event_json);
    }
}

/// §6.4 mandatory-timeout sweep for continuation-parked streams
/// (connection-actor 3b-ii). A stream that returned `next(...)` and
/// has no resume by its deadline gets a real 504 — before any
/// intermediary gives up. The `reg.move` out of `parked_continuations`
/// is simultaneously the resolve AND the resolve-once guard: a stream
/// leaves a collection exactly once, so a racing 3b-iii callback
/// finds it gone (expected, not an error). O(parked) per tick.
///
/// The empty-loop short-circuit is the cont-state discriminant —
/// membership in `parked_continuations` IS the parked-state probe
/// (principle #1), no separate count check needed.
pub fn sweepParkedContinuations(worker: anytype) !void {
    const ents = worker.parked_continuations.entitySlice();
    if (ents.len == 0) return;
    std.log.info("rove-js sendpath: sweepParkedContinuations tick parked={d}", .{ents.len});
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    // Collect expired first — resume/resolve mutate the collection,
    // so snapshot (ent,sid,sess) while the slice is stable.
    const Expired = struct { ent: rove.Entity, sid: h2.StreamId, sess: h2.Session };
    var expired: std.ArrayListUnmanaged(Expired) = .empty;
    defer expired.deinit(allocator);
    {
        const sids = worker.parked_continuations.column(h2.StreamId);
        const sesss = worker.parked_continuations.column(h2.Session);
        const descs = worker.parked_continuations.column(components_mod.ContDescriptor);
        for (ents, sids, sesss, descs) |ent, sid, sess, desc| {
            if (now_ns >= desc.deadline_ns)
                try expired.append(allocator, .{ .ent = ent, .sid = sid, .sess = sess });
        }
    }

    for (expired.items) |e| {
        resumeContinuation(worker, e.ent, e.sid, e.sess, "{\"ok\":false,\"reason\":\"deadline\"}", false) catch |err| {
            std.log.warn(
                "rove-js continuation: deadline resume failed ({s}); hard 504",
                .{@errorName(err)},
            );
            resolveParked(worker, e.ent, e.sid, e.sess, 504, "hold deadline exceeded\n") catch {};
        };
    }
}

/// `docs/readset-replication-plan.md` Phase 4 park-on-durability
/// drain.
///
/// Walks `worker.body_pending`, polling each parked entity's
/// submission against the process-global blob coordinator's HWM
/// (`node.blob_coordinator.durableSeq(worker_id)` — docs/streaming-model.md
/// §7). Once the seq is durable we materialize the wire `BodyRef` via
/// `coord.bodyRef()`, stamp it onto the entity's `BodyDurabilityWait`
/// (so `dispatchPending` can stamp the readset on resume), and
/// `coord.release()` the coordinator's retained copy (P6).
///
/// Best-effort: missing coord (shouldn't happen post-init) skips
/// the entity. A `reg.move` failure panics (rove invariant — the
/// entity must be in `body_pending` or the column slice is stale).
/// Result of polling the blob coordinator for one parked body
/// submission (`pollDurableBodyRef`).
const DurableBody = union(enum) {
    /// Seq still in flight — leave it parked; coordinator copy retained.
    not_yet,
    /// Terminal `coord.bodyRef` error — logged, retained copy released.
    failed,
    /// Durable in S3 — wire `BodyRef` ready, retained copy released.
    ready: bodies_mod.BodyRef,
};

/// Poll the blob coordinator's durability HWM for one parked
/// `(worker_id, seq)` body submission. Single owner of the
/// `durableSeq → bodyRef → release` (P6) gate shared by
/// `drainBodyPending` (inbound bodies) and
/// `drainFetchPendingDurability` (outbound fetch chunks) — the two
/// callers differ only in park-container bookkeeping and what they do
/// with the `.ready` ref. On both terminal outcomes (`.ready` /
/// `.failed`) the coordinator's retained RAM copy is released here;
/// `.not_yet` keeps it retained. `what` / `tenant` are log context for
/// the failure path. The returned `BodyRef` is a plain value (the wire
/// `batch_id`/`offset`/`len`), so releasing the coordinator copy before
/// the caller consumes it is safe.
fn pollDurableBodyRef(
    coord: anytype,
    worker_id: u8,
    seq: u64,
    what: []const u8,
    tenant: []const u8,
) DurableBody {
    // Count semantics: durableSeq is the exclusive HWM (lowest
    // not-yet-durable seq), so `seq < durableSeq` ⇒ resolved.
    if (seq >= coord.durableSeq(worker_id)) return .not_yet;
    const ref = coord.bodyRef(worker_id, seq) catch |err| {
        std.log.warn(
            "rove-js {s}: coord.bodyRef tenant={s} seq={d}: {s}",
            .{ what, tenant, seq, @errorName(err) },
        );
        _ = coord.release(worker_id, seq);
        return .failed;
    };
    _ = coord.release(worker_id, seq);
    return .{ .ready = .{ .batch_id = ref.batch_id, .offset = ref.offset, .len = ref.len } };
}

pub fn drainBodyPending(worker: anytype) !void {
    const server = worker.h2;
    const coord = worker.node.blob_coordinator orelse return;

    const ents = worker.body_pending.entitySlice();
    const waits = worker.body_pending.column(BodyDurabilityWait);

    // Snapshot indices first — `reg.move` mutates `body_pending`,
    // so iterate by index over the snapshotted entitySlice and
    // skip empty slots after the move.
    var i: usize = 0;
    while (i < ents.len) : (i += 1) {
        const ent = ents[i];
        const wait = &waits[i];
        // If already materialized (body_ref non-sentinel), skip —
        // we already released this entity, just waiting for the
        // dispatcher to pick it up.
        if (wait.body_ref.batch_id != bodies_mod.NO_BATCH) continue;

        // Durability gate (shared with drainFetchPendingDurability) —
        // poll the coord HWM, materialize + release on terminal.
        switch (pollDurableBodyRef(coord, wait.worker_id, wait.worker_seq, "body-gate", wait.tenant_id)) {
            .not_yet => continue,
            // Body never became durable: leave body_ref at NO_BATCH.
            // The resume path sees NO_BATCH and writes a 500.
            .failed => {},
            // Stamp the wire BodyRef. Phase 5: `batch_id` is the
            // coord's globally-unique pool batch_id; the S3 key is
            // `{key_prefix_base}_pool/{batch_id:0>20}`. The dispatcher
            // serializes it into the readset on resume.
            .ready => |ref| wait.body_ref = ref,
        }
        try server.reg.move(ent, &worker.body_pending, &server.request_out);
    }
}

/// `docs/readset-replication-plan.md` Phase 4-fetch-park drain.
///
/// Walks `worker.fetch_pending_durability` (parked outbound-fetch
/// chunk activations), polls the blob coordinator's HWM, and re-fires
/// each activation with its materialized `BodyRef` once durable (then
/// `coord.release`s the retained copy, P6). Symmetric to
/// `drainBodyPending` but for events
/// instead of entities — fetch chunks arrive via the msg_inbox
/// without an h2 entity, so the park list is a plain
/// `ArrayListUnmanaged(ParkedFetchEvent)` instead of a rove
/// collection.
///
/// Iteration uses a snapshot-then-swap-remove pattern: collect
/// indices to release first, then `swapRemove` from the back to
/// keep the list compact without invalidating indices.
/// `fireFetchEventActivation` takes ownership of the released
/// event (deinit fires via its top-level `defer` on completion).
pub fn drainFetchPendingDurability(worker: anytype) !void {
    const coord = worker.node.blob_coordinator orelse return;
    var i: usize = 0;
    while (i < worker.fetch_pending_durability.items.len) {
        const pe = &worker.fetch_pending_durability.items[i];
        // Durability gate (shared with drainBodyPending) — poll the
        // coord HWM, materialize + release on terminal. The helper
        // releases the coord copy before we swapRemove `pe`, so no
        // pre-capture of (worker_id, seq) is needed.
        switch (pollDurableBodyRef(coord, pe.worker_id, pe.worker_seq, "fetch-gate", pe.tenant_id_view)) {
            // Not durable yet — advance; the swapRemove cases below
            // stay at `i` so the swapped-in element is examined next.
            .not_yet => i += 1,
            // Drop the parked event. Better surface would be to fire
            // with a transport-error terminal, but Phase 3 keeps the
            // existing "skip on body-gate failure" posture.
            .failed => {
                var released = worker.fetch_pending_durability.swapRemove(i);
                components_mod.UpstreamFetchEvent.deinitItem(&released.event, worker.allocator);
            },
            // Re-fire with the durable ref. The event carries its
            // chunk bytes inline; replay reads the body from S3 via
            // the BodyRef. fireFetchEventActivation takes ownership of
            // the released event (deinit fires via its own defer).
            .ready => |wire_ref| {
                var released = worker.fetch_pending_durability.swapRemove(i);
                worker_mod.fireFetchEventActivation(worker, &released.event, wire_ref);
            },
        }
    }
}
