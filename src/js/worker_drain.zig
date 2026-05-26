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
const kv_mod = @import("rove-kv");
const tape_mod = @import("rove-tape");
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
const ParkedUnit = worker_mod.ParkedUnit;
const RaftWait = worker_mod.RaftWait;
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
                        t.commit() catch |cerr| panic_mod.invariantViolated(
                            "drainRaftPending.parked_units.commit",
                            "seq={d} tenant={s} err={s}",
                            .{ unit.seq, unit.tenant_id, @errorName(cerr) },
                        );
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
        if (tc.snap.bytecodes.get(module_path)) |b| break :blk b;
        const mjs = try std.fmt.allocPrint(allocator, "{s}.mjs", .{module_path});
        defer allocator.free(mjs);
        if (tc.snap.bytecodes.get(mjs)) |b| break :blk b;
        const js = try std.fmt.allocPrint(allocator, "{s}.js", .{module_path});
        defer allocator.free(js);
        if (tc.snap.bytecodes.get(js)) |b| break :blk b;
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
) !void {
    const allocator = worker.allocator;
    const server = worker.h2;

    // Release the dispatch lease BEFORE proposing — same posture as
    // worker_dispatch.zig's write path. The chain orders commits;
    // the next per-tenant batch's open lease isn't blocked on raft
    // here.
    txn.releaseLease();

    const seq = raft_propose.proposeBatch(worker, writeset, tenant_id) catch |err| {
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
    // commit-arm move (raft_pending_cont → parked_continuations)
    // routes through `interpretCmd` instead of `drainEntityArm`'s
    // inline move. Same `source` / `dest` for both switch arms
    // below (terminal + repark both land in raft_pending_cont
    // and commit back to parked_continuations).
    var cont_cmds: effect_mod.cmd.BufferedCmds = .{};
    cont_cmds.items.append(allocator, .{ .respond = .{
        .entity = ent,
        .source = .raft_pending_cont,
        .dest = .parked_continuations,
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
            if (desc.bound_schedule_id) |old_b| allocator.free(old_b);
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
    }
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
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, correlation_id, .send_callback);
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
                proposeAndParkContResume(
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
                ) catch |perr| {
                    // Propose-fail / pre-park alloc failure: degrade
                    // to a 500 over the held socket. The txn was
                    // rolled back + destroyed inside the helper.
                    std.log.warn("rove-js cont-resume: propose failed: {s}", .{@errorName(perr)});
                    allocator.free(body_dup);
                    txn_owned = false; // helper destroyed it
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "continuation write replication failed\n") catch {};
                    captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, 500, .fault, console_owned, exception_owned, .{}, corr_id, .send_callback);
                    return;
                };
                // proposeAndParkContResume took ownership of txn (moved
                // into pending_txns) and body_dup (stamped onto entity).
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, st, .ok, console_owned, exception_owned, .{}, corr_id, .send_callback);
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
            captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, correlation_id, .send_callback);
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
                    var only: ?[]const u8 = null;
                    var nputs: usize = 0;
                    for (ws.ops.items) |op| switch (op) {
                        .put => |p| if (std.mem.startsWith(u8, p.key, OWED_PREFIX)) {
                            nputs += 1;
                            only = p.key[OWED_PREFIX.len..];
                        },
                        .delete => {},
                    };
                    if (nputs != 1) break :blk null;
                    break :blk try allocator.dupe(u8, only.?);
                };
                proposeAndParkContResume(
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
                ) catch |perr| {
                    // Helper rolled back + destroyed txn + freed
                    // c2m + new_bound_sched_id on failure; we just
                    // log + degrade.
                    std.log.warn("rove-js cont-resume (repark): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    resolveParked(worker, ent, sid, sess, 500, "continuation write replication failed\n") catch {};
                    captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, 500, .fault, &.{}, &.{}, .{}, corr_id, .send_callback);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                // Log the repark hop's tape row. status=0 (parked,
                // same as the inbound trampoline open hop's
                // captureSuccess shape).
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", dep_id, now_ns, 0, .ok, &.{}, &.{}, .{}, corr_id, .send_callback);
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
            // Phase 2a: a resume hop returning `__rove_stream(...)` is
            // not yet wired — Phase 2b lands chunked-write resume.
            // Treat as a defined 501 so the held socket releases
            // cleanly rather than hanging.
            s.deinit(allocator);
            txn.rollback() catch {};
            txn_done = true;
            try resolveParked(worker, ent, sid, sess, 501, "streams not yet wired in the resume path (Phase 2b)\n");
            captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 501, .handler_error, &.{}, &.{}, .{}, correlation_id, .send_callback);
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
    // bound_schedule_id + tenant_id read from the entity's
    // ContDescriptor + ChainContext components. The empty-collection
    // check is the cont-state discriminant — membership in
    // `parked_continuations` IS the gate (principle #1), no separate
    // count check needed.
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
        // Matched. resumeContinuation either flushes+drops (terminal)
        // or re-parks (keeps the entity) — either way we return
        // immediately, so iterating the now-possibly-mutated slice is
        // not a hazard. Infra failure → 502 + drop (the call result
        // is lost, but the held socket must not hang).
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
