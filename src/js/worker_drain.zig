// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Post-raft-commit reconciliation + held-continuation resume engine.
//!
//! Covers the two systems the worker tick runs after `dispatchOnce`:
//!
//!   - **`drainRaftPending`** — the reconciler. One snapshot of
//!     `(committed, faulted, now_ns)` per tick, fed into `effect.classify`
//!     on every parked unit. The three raft_pending sibling collections
//!     (`raft_pending_response` / `_cont` / `_stream`) share
//!     `drainEntityArm`; the entity-less `parked_units` sweep is the
//!     fourth arm and the commit-gated buffer release point (see
//!     `worker_streaming.fireKvReactSubscriptions` +
//!     `unit.buffered.releaseAll`).
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
//! Every function takes `worker: anytype` so the structural-typed
//! access to Worker's fields keeps working without forcing this file
//! to depend on the comptime Worker type. Same shape as
//! `worker_dispatch.zig` / `worker_log.zig` / `worker_streaming.zig`.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const kv_mod = @import("raft-kv");
const blob_mod = @import("rove-blob");
const tape_mod = @import("rove-tape");
const log_mod = @import("rove-log");
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const globals = @import("globals.zig");
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
const worker_fire = @import("worker_fire.zig");
const worker_ws = @import("worker_ws.zig");
const durable_wake = @import("durable_wake.zig");
const bodies_mod = @import("rove-bodies");
const proxy_engine_mod = @import("proxy_engine.zig");
const ProxyResult = proxy_engine_mod.ProxyResult;
const ProxyOutcome = proxy_engine_mod.ProxyOutcome;
const ParkedUnit = worker_mod.ParkedUnit;
const RaftWait = worker_mod.RaftWait;
const ForwardWait = worker_mod.ForwardWait;
const BodyDurabilityWait = worker_mod.BodyDurabilityWait;
const TenantFiles = worker_mod.TenantFiles;
const captureLogWithId = worker_mod.captureLogWithId;
const OWED_PREFIX = worker_mod.OWED_PREFIX;
const CONT_HOLD_DEADLINE_NS = worker_mod.CONT_HOLD_DEADLINE_NS;

// ── Reconciler ────────────────────────────────────────────────────────

/// Shared body of the three raft_pending_X sibling drains
/// (response / cont / stream), parameterised by the source
/// collection + a panic-label site name.
///
/// Commit arm: take the deferred TrackedTxn through the watermark;
/// the entity's commit-time move is the parked_units arm's job via
/// `interpretCmd .respond` (every path that parks an entity in
/// raft_pending_X also emits a Cmd.respond on the parked_units
/// unit — the Cmd pattern, `docs/architecture/effects-and-handlers.md`).
///
/// Fault arm: rollback the txn, overwrite the response body to 503,
/// move the entity to `server.response_in` for h2 to ship.
/// `response_in` is hard-coded for the fault destination — all three
/// arms route fault there for the 503 downgrade, a per-sibling
/// invariant of the H2 reference path.
fn drainEntityArm(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    now_ns: i64,
    source: anytype,
    comptime site_label: []const u8,
) !void {
    // The per-unit classify→dispatch loop is `effect.reconcile`; this
    // ctx supplies the H2 reference path's txn handling + on-commit /
    // on-fault actions: the commit arm only commits the shared txn (the
    // entity move is the `parked_units` arm's `Cmd.respond` job — Phase
    // 4.1.3 Option-2), and the fault arm rolls back + 503-downgrades +
    // moves to `response_in`. The nested struct captures `site_label`
    // (comptime) so the panic sites stay comptime-`site`d for
    // `panic_mod.invariantViolated`.
    const Ctx = struct {
        worker: @TypeOf(worker),
        server: @TypeOf(server),
        allocator: std.mem.Allocator,
        source: @TypeOf(source),
        now_ns: i64,
        entities: []const rove.Entity,
        waits: []RaftWait,
        resp_bodies: []h2.RespBody,

        pub fn seqAt(self: *@This(), i: usize) u64 {
            return self.waits[i].seq;
        }
        pub fn deadlineAt(self: *@This(), i: usize) i64 {
            return self.waits[i].deadline_ns;
        }
        /// Per-tenant watermark by this entity's group_id.
        pub fn watermarkAt(self: *@This(), i: usize) effect_mod.Watermarks {
            const gid = self.waits[i].group_id;
            return .{
                .committed = self.worker.raft.committedSeq(gid),
                .faulted = self.worker.raft.faultedSeq(gid),
                .now_ns = self.now_ns,
            };
        }
        pub fn commitAt(self: *@This(), i: usize) !void {
            // First entity at this seq takes the shared txn through
            // commit; later siblings see `.absent`. `.conflict`
            // (kvexp NotChainHead) retries next tick. The entity move
            // is the `parked_units` arm's job — nothing else here.
            switch (self.worker.pending_txns.commitAndTake(self.allocator, self.waits[i].group_id, self.waits[i].seq)) {
                // The txn promoted into the store's main overlay: release
                // the durabilize floor for this seq (the pump skipped the
                // entry's store write on this txn's behalf and has been
                // holding the watermark/compaction below it).
                .took => self.worker.raft.noteWorkerCommitted(self.waits[i].group_id, self.waits[i].seq),
                .absent, .conflict => {},
                .failed => |err| panic_mod.invariantViolated(
                    site_label ++ ".commit",
                    "seq={d} err={s}",
                    .{ self.waits[i].seq, @errorName(err) },
                ),
            }
        }
        /// Deadline passed, not bridge-faulted: request a pump-side
        /// fault and stay parked (see `effect.SweepClass.timeout` — a
        /// unilateral rollback here races the pump's worker-overlay
        /// skip decision for this very entry). The next tick resolves
        /// to `.commit` (it landed after all) or `.fault` (below).
        pub fn timeoutAt(self: *@This(), i: usize) void {
            self.worker.raft.requestFault(self.waits[i].group_id, self.waits[i].seq);
        }
        pub fn faultAt(self: *@This(), i: usize) !void {
            const ent = self.entities[i];
            switch (self.worker.pending_txns.rollbackAndTake(self.allocator, self.waits[i].group_id, self.waits[i].seq)) {
                .took, .absent => {},
                .failed => |err| panic_mod.invariantViolated(
                    site_label ++ ".rollback",
                    "seq={d} err={s}",
                    .{ self.waits[i].seq, @errorName(err) },
                ),
            }
            // Per-sibling on-entity cleanup (ContDescriptor / stream
            // components / etc.) deinits structurally when
            // cleanupResponses destroys the entity — no manual
            // side-table teardown.
            const old_body_ptr: ?[*]u8 = self.resp_bodies[i].data;
            const old_body_len: u32 = self.resp_bodies[i].len;
            try respb.overwrite503InPending(self.worker, self.source, ent, self.allocator);
            if (old_body_ptr) |p| self.allocator.free(p[0..old_body_len]);
            try self.server.reg.move(ent, self.source, &self.server.response_in);
        }
    };

    var ctx = Ctx{
        .worker = worker,
        .server = server,
        .allocator = allocator,
        .now_ns = now_ns,
        .source = source,
        // Snapshotted before the loop: `reg.move` (fault arm) is
        // deferred to `reg.flush`, so these slices stay valid for the
        // whole pass even as entities move out.
        .entities = source.entitySlice(),
        .waits = source.column(RaftWait),
        .resp_bodies = source.column(h2.RespBody),
    };
    try effect_mod.reconcile(&ctx, ctx.entities.len);
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

    // Per-tenant watermarks. The committed/faulted watermark is looked
    // up PER ENTITY by its `group_id` (each arm's
    // ctx `watermarkAt(i)` calls `bridge.committedSeq(gid)` /
    // `faultedSeq(gid)`), not snapshotted once node-wide — tenant logs
    // commit independently, so a single global snapshot would couple
    // their latency. We still capture `now_ns` once per tick so the
    // timeout half of `classify` is consistent across all four arms.
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    // raft_pending is THREE sibling collections.
    // Each entity is parked on the sibling matching its commit
    // destination, so the dispatch in each loop is direct — no
    // membership field-check or side-table probe. Whichever loop
    // processes a given seq first commits the
    // shared TrackedTxn; later siblings find the map empty and just
    // queue moves. Forward-iter preserves per-tenant chain order
    // (entities enter the siblings in propose-seq order from
    // finalizeBatch).
    try drainEntityArm(worker, server, allocator, now_ns, &worker.raft_pending_response, "raft_pending_response");
    try drainEntityArm(worker, server, allocator, now_ns, &worker.raft_pending_cont, "raft_pending_cont");
    try drainEntityArm(worker, server, allocator, now_ns, &worker.raft_pending_stream, "raft_pending_stream");

    // ── Non-entity parked units (idiom-1 SSE-emit gating —
    //    effect gating, docs/architecture/effects-and-handlers.md).
    //
    // Iterates a snapshot of entity ids so that re-entrant park-*
    // calls (e.g. via firePendingKvWakes → kv-react fire path) that
    // create new parked_units entities land in the deferred-create
    // queue and process next tick — no iterate-while-modify trap
    // (a flat ArrayList here would hit a general-protection fault;
    // the collection + reg.destroy deferred-create queue avoids it by
    // construction).
    {
        const slice = worker.parked_units.entitySlice();
        var buf: [256]rove.Entity = undefined;
        const n = @min(slice.len, buf.len);
        std.mem.copyForwards(rove.Entity, buf[0..n], slice[0..n]);

        // The entity-less parked_units sweep is the fourth `reconcile`
        // caller, so `classify` lives behind exactly one loop shape
        // across all four arms.
        // The ctx resolves each unit FRESH by id (`reg.get … catch` →
        // skip); a gone unit
        // returns a sentinel seq so `classify` yields `.pending` and
        // neither arm fires. The `.conflict` (kvexp NotChainHead) and
        // `pending_txns.contains` "defer to next tick" branches map to
        // an early `return` from `commitAt` — the unit stays parked,
        // not destroyed.
        const Ctx = struct {
            worker: @TypeOf(worker),
            server: @TypeOf(server),
            allocator: std.mem.Allocator,
            now_ns: i64,
            ids: []const rove.Entity,

            fn unitAt(self: *@This(), i: usize) ?*ParkedUnit {
                return self.server.reg.get(self.ids[i], &self.worker.parked_units, ParkedUnit) catch null;
            }
            pub fn seqAt(self: *@This(), i: usize) u64 {
                const u = self.unitAt(i) orelse return std.math.maxInt(u64);
                return u.seq;
            }
            pub fn deadlineAt(self: *@This(), i: usize) i64 {
                const u = self.unitAt(i) orelse return std.math.maxInt(i64);
                return u.deadline_ns;
            }
            /// Per-tenant watermark. ParkedUnits carry a
            /// `tenant_id` (not a `RaftWait`), so resolve the gid through
            /// the bridge registry (already registered when the unit
            /// proposed). A gone/unregistered unit yields committed=0 →
            /// `classify` leaves it pending (matches the sentinel-seq
            /// shape of `seqAt`/`deadlineAt`).
            pub fn watermarkAt(self: *@This(), i: usize) effect_mod.Watermarks {
                const u = self.unitAt(i) orelse
                    return .{ .committed = 0, .faulted = 0, .now_ns = self.now_ns };
                const gid = self.worker.raft.gidForTenant(u.tenant_id) orelse
                    return .{ .committed = 0, .faulted = 0, .now_ns = self.now_ns };
                return .{
                    .committed = self.worker.raft.committedSeq(gid),
                    .faulted = self.worker.raft.faultedSeq(gid),
                    .now_ns = self.now_ns,
                };
            }
            pub fn commitAt(self: *@This(), i: usize) !void {
                const unit = self.unitAt(i) orelse return;
                // Forgetful-writes units carry their own
                // `TrackedTxn` (no entity in raft_pending waiting on
                // this seq). Commit it here; null `txn` after so
                // `ParkedUnit.deinit` doesn't re-rollback on destroy.
                if (unit.txn) |t| {
                    t.commit() catch |cerr| switch (cerr) {
                        // kvexp NotChainHead: predecessor's head not
                        // committed yet. Leave the unit parked; next
                        // tick still classifies `.commit` once it
                        // lands.
                        error.Conflict => return,
                        else => panic_mod.invariantViolated(
                            "drainRaftPending.parked_units.commit",
                            "seq={d} tenant={s} err={s}",
                            .{ unit.seq, unit.tenant_id, @errorName(cerr) },
                        ),
                    };
                    self.allocator.destroy(t);
                    unit.txn = null;
                    // Txn promoted: release the durabilize floor for this
                    // seq (the pump skipped the entry's store write on
                    // this txn's behalf).
                    if (self.worker.raft.gidForTenant(unit.tenant_id)) |gid|
                        self.worker.raft.noteWorkerCommitted(gid, unit.seq);
                } else if (self.worker.pending_txns.contains(
                    self.worker.raft.gidForTenant(unit.tenant_id) orelse 0,
                    unit.seq,
                )) {
                    // Entity-backed unit (no own txn): the sibling
                    // `drainEntityArm` hasn't committed the shared txn
                    // at this seq yet (it conflicted on NotChainHead).
                    // Releasing our `Cmd.respond` now would move the
                    // entity before its writes are durable — defer to
                    // the next tick (Phase 4.1.3 Option-2 atomicity
                    // gate). The unit stays in `parked_units`.
                    return;
                }
                // The commit-arm release. fireKvReactSubscriptions
                // enqueues kv-react fires onto worker.msg_queue;
                // releaseAll interprets every Cmd in order.
                worker_streaming.fireKvReactSubscriptions(self.worker, unit);
                // §2.6 P2: commit-gated durable-wake watermark bootstrap.
                // Reads the same committed `kv_wake_broadcast` Cmds (still
                // intact — releaseAll consumes them next) and lowers
                // `next_wake_ns` for any `_sched/by_time/` put, so the
                // steady sweep fires `scheduler_tick` at the new earliest
                // time. Must precede releaseAll (which drains the Cmds).
                durable_wake.noteCommittedSchedWrites(self.worker, unit);
                // §8.4 watch baseline: the unit's txn just committed, so
                // the tenant store's write clock now reflects this batch.
                // Sample it once (per batch, not per op) and stamp every
                // `kv_wake_broadcast`; `maxInt` (tenant absent / contended
                // lease) fires-always rather than dropping an `on.kv` wake.
                const wv: u64 = blk: {
                    const slot = self.worker.node.deploy.tenant_files_map.get(unit.tenant_id) orelse
                        break :blk std.math.maxInt(u64);
                    break :blk slot.app_kv.writeVersion() orelse std.math.maxInt(u64);
                };
                unit.buffered.releaseAll(self.worker, unit.tenant_id, wv);
                self.server.reg.destroy(self.ids[i]) catch |err| std.log.warn(
                    "rove-js parked_units commit destroy: {s}",
                    .{@errorName(err)},
                );
            }
            /// Deadline passed, not bridge-faulted: request a pump-side
            /// fault and stay parked (see `effect.SweepClass.timeout`).
            /// The gid resolves the same way `watermarkAt` does; a
            /// gone/unregistered unit has nothing to fault.
            pub fn timeoutAt(self: *@This(), i: usize) void {
                const u = self.unitAt(i) orelse return;
                const gid = self.worker.raft.gidForTenant(u.tenant_id) orelse return;
                self.worker.raft.requestFault(gid, u.seq);
            }
            pub fn faultAt(self: *@This(), i: usize) !void {
                const unit = self.unitAt(i) orelse return;
                // Rollback the attached txn before
                // discarding, keeping fault/timeout discard ordering
                // symmetric with commit's destroy-then-clear pattern.
                if (unit.txn) |t| {
                    t.rollback() catch |rerr| std.log.warn(
                        "rove-js drainRaftPending.parked_units.rollback seq={d} tenant={s}: {s}",
                        .{ unit.seq, unit.tenant_id, @errorName(rerr) },
                    );
                    self.allocator.destroy(t);
                    unit.txn = null;
                }
                self.server.reg.destroy(self.ids[i]) catch |err| std.log.warn(
                    "rove-js parked_units fault destroy: {s}",
                    .{@errorName(err)},
                );
            }
        };

        var ctx = Ctx{ .worker = worker, .server = server, .allocator = allocator, .now_ns = now_ns, .ids = buf[0..n] };
        try effect_mod.reconcile(&ctx, n);
    }

    // Dispatch any subscription fires the kv-react site enqueued
    // onto `worker.msg_queue` during the parked_units loop.
    // Re-entrant fires append to the queue's tail; the current
    // tick's BATCH was already capped, so they process next tick
    // — no iterate-while-modify trap.
    worker_streaming.dispatchSubscriptionFires(worker);
}

// ── Async serve-or-forward drain ──────────────────────────────────────

/// Drain this worker's proxy-result inbox and resolve parked
/// serve-or-forward requests (`proxy_engine.zig`). For each entity in
/// `forward_pending`: if its `ForwardWait.forward_id` has a matching
/// `ProxyResult`, build the final response from the outcome and move it
/// to `response_in`; if its deadline has passed with no result, 504.
/// Otherwise the forward is still in flight — leave it parked.
///
/// Runs each worker tick next to `drainRaftPending`. The 1ms poll
/// cadence bounds result latency without an explicit wake (same posture
/// as the `MsgInbox` fetch-event path).
pub fn drainForwardPending(worker: anytype) !void {
    const allocator = worker.allocator;
    const idx = worker.msg_inbox_idx;
    const inboxes = worker.node.proxy_result_inboxes;
    if (idx >= inboxes.len) return;

    var results: std.ArrayListUnmanaged(ProxyResult) = .empty;
    defer results.deinit(allocator);
    try inboxes[idx].drainInto(allocator, &results);

    const parked = worker.forward_pending.entitySlice();
    if (results.items.len == 0 and parked.len == 0) return;

    // Track which results we apply, to free the outcomes of any that
    // find no parked entity (a reaped / raced slot).
    var consumed = try allocator.alloc(bool, results.items.len);
    defer allocator.free(consumed);
    @memset(consumed, false);

    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    // Snapshot before the loop: `reg.move` defers to flush, so the
    // entity + wait slices stay valid for the whole pass.
    const waits = worker.forward_pending.column(ForwardWait);

    var i: usize = 0;
    while (i < parked.len) : (i += 1) {
        const ent = parked[i];
        const fid = waits[i].forward_id;

        var matched: ?usize = null;
        for (results.items, 0..) |r, k| {
            if (!consumed[k] and r.forward_id == fid) {
                matched = k;
                break;
            }
        }

        if (matched) |k| {
            consumed[k] = true;
            try applyForwardOutcome(worker, ent, &results.items[k].outcome);
        } else if (waits[i].deadline_ns != 0 and now_ns >= waits[i].deadline_ns) {
            const body = try allocator.dupe(u8, "forward timeout\n");
            try finalizeForward(worker, ent, 504, body);
        }
    }

    // Outcomes whose forward_id had no parked entity: free their owned
    // allocations so they don't leak (the parked stream was already
    // reaped, or a duplicate result raced).
    for (results.items, 0..) |*r, k| {
        if (!consumed[k]) r.outcome.deinit(allocator);
    }
}

/// Build the final response for a resolved forward from its outcome,
/// then move the entity to `response_in`. The outcome's owned bytes are
/// either transferred to the h2 response (`forwarded`) or freed here
/// (`local_miss` host) — `consumed[]` in the caller prevents a second
/// free.
fn applyForwardOutcome(worker: anytype, ent: rove.Entity, outcome: *ProxyOutcome) !void {
    const allocator = worker.allocator;
    switch (outcome.*) {
        .forwarded => |f| {
            // `f.body` ownership transfers to the h2 response (no copy).
            try finalizeForward(worker, ent, f.status, f.body);
        },
        .local_miss => |m| {
            // Rebuild the diagnostic 404 the sync path produced
            // (worker_dispatch resolveRequest miss branch).
            const ad = worker.admin_api_domain orelse "(none)";
            const ps = worker.node.tenant.publicSuffix() orelse "(none)";
            const body = std.fmt.allocPrint(
                allocator,
                "no tenant for host '{s}'\n" ++
                    "  admin_api_domain={s}\n" ++
                    "  public_suffix={s}\n" ++
                    "  no domain alias registered for this host\n",
                .{ m.host, ad, ps },
            ) catch try allocator.dupe(u8, "no tenant for host\n");
            allocator.free(m.host);
            try finalizeForward(worker, ent, 404, body);
        },
        .cp_unreachable => {
            const body = try allocator.dupe(u8, "control plane unreachable\n");
            try finalizeForward(worker, ent, 503, body);
        },
        .transport_error => {
            const body = try allocator.dupe(u8, "forward failed\n");
            try finalizeForward(worker, ent, 502, body);
        },
    }
}

/// Stamp a status + (allocator-owned) body onto the parked entity in
/// `forward_pending` and move it to `response_in`. `body` ownership
/// transfers to the h2 response (freed after the stream ships). The
/// entity's h2 sid/session ride it from request ingress (preserved by
/// `reg.move`), so only the response components are set here.
fn finalizeForward(worker: anytype, ent: rove.Entity, status: u16, body: []u8) !void {
    const server = worker.h2;
    try server.reg.set(ent, &worker.forward_pending, h2.Status, .{ .code = status });
    try server.reg.set(ent, &worker.forward_pending, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &worker.forward_pending, h2.RespBody, .{ .data = body.ptr, .len = @intCast(body.len) });
    try server.reg.set(ent, &worker.forward_pending, h2.H2IoResult, .{ .err = 0 });
    try server.reg.move(ent, &worker.forward_pending, &server.response_in);
}


// ── Shared deployment-resolve ─────────────────────────────────────────

/// The deployment + bytecode resolution that every resume engine
/// shares (the only truly-shared block across `resumeContinuation` /
/// `resumeStream` / `fireDisconnectActivation`). Caller defers
/// `dep.tc.release()` on success; on error the helper releases
/// internally.
///
/// Why only this one helper: the engines' outcome-application logic
/// is intrinsically divergent (cont reparks + bound_schedule_id +
/// 6.4 deadline / stream appends chunks to a component queue +
/// marks draining / disconnect ignores output entirely). Forcing a
/// unified outcome-switch obscures rather than clarifies, so each
/// engine keeps its tail. See the doc comment on each engine for
/// the prep / run / apply phase structure.
pub const ChainDeployment = struct {
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
    const slot = worker.node.deploy.tenant_files_map.get(tenant_id) orelse return error.ResumeNoTenant;
    const snap = slot.pinCurrent() orelse return error.ResumeNoDeployment;
    var tc = TenantFiles{ .slot = slot, .snap = snap };
    errdefer tc.release();
    const inst = (worker.node.tenant.getInstance(tenant_id) catch return error.ResumeNoInstance) orelse
        return error.ResumeNoInstance;
    const bc = blk: {
        // `__system/<name>` resolves against the node-level
        // built-in registry (exact — NO walk-up, or a `__system/*` path would
        // wrongly fall back to the tenant's own `index.mjs`). Bytecode compiled
        // once at NodeState init from sources baked into the binary; shared
        // across tenants. The handler runs in the tenant's context, so it sees
        // the tenant's globals (kv, http, __rove_next).
        if (builtin_modules_mod.isBuiltinPath(module_path)) {
            const mjs = try std.fmt.allocPrint(allocator, "{s}.mjs", .{module_path});
            defer allocator.free(mjs);
            if (worker.node.builtin_modules.get(module_path)) |b| break :blk b;
            if (worker.node.builtin_modules.get(mjs)) |b| break :blk b;
            return error.ResumeNoBytecode;
        }
        // Tenant module: resolve with the SAME walk-up catch-all as inbound
        // dispatch (`worker.findBytecode`). A continuation's path is the
        // dispatch route's `module_base` (the path-derived name); when the
        // handler ran via a catch-all (a default export at `index.mjs` serving
        // an arbitrary route, e.g. `__admin__` answering `/v1/logs/...`), the
        // path-derived module doesn't exist as a file — walk up to the
        // `index.mjs` that actually ran, where `onFetchResult` lives. Without
        // this a bound `on.fetch` from such a handler resumes to
        // ResumeNoBytecode (docs/architecture/auth-consolidation.md A5).
        if (try worker_mod.findBytecode(tc, module_path, allocator)) |b| break :blk b;
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

/// Post-handler-write path for a continuation-resume hop.
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
/// seq so any §4.5 wake fan-outs fire AFTER commit, alongside the
/// entity's state transition. (`_send/owed/*` is an ordinary kv put —
/// no separate send-arm commit gate.)
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
    /// The cont→stream resume transition (the streaming substrate,
    /// `docs/architecture/routing-and-ingress.md`).
    /// The handler returned `stream({write, status?, headers?})`
    /// from a cont-parked entity (bound-fetch onFetchChunk
    /// resume that opens a streaming response). All slices owned
    /// and transferred onto the entity's stream components +
    /// h2 components. Module path is the cont's current path,
    /// unless the disposition named a cross-module target — the
    /// one `next()` semantic: an explicit target re-aims the chain.
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
        /// kv-react wake arms — each carries its own prefix + `{on}`
        /// export (per-arm routing). Spine + entries owned.
        kv_prefixes: []components_mod.KvArm,
        /// Timer-wake interval (0 = no timer wake — fetch chunks
        /// are the wake source).
        interval_ms: i64,
        /// The interval timer's own `{on}` export (null → `onWake`). Owned.
        timer_on: ?[]u8,
    },
};

/// Free everything `proposeAndParkContResume` owns when it bails at or
/// before the propose: roll back + destroy the txn and free the
/// resources the caller handed into `next`. `.terminal` keeps its body
/// on the caller (the caller's catch frees it).
fn discardContResume(
    allocator: std.mem.Allocator,
    txn: *kv_mod.KvStore.TrackedTxn,
    next: ContResumeNext,
) void {
    txn.rollback() catch {};
    allocator.destroy(txn);
    switch (next) {
        .terminal => {},
        .repark => |*r| {
            if (r.new_bound_sched_id) |b| allocator.free(b);
            var c = r.new_cont;
            c.deinit(allocator);
        },
        .stream => |*s| {
            for (s.resp_headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            if (s.resp_headers.len > 0) allocator.free(s.resp_headers);
            for (s.chunks) |c| allocator.free(c);
            if (s.chunks.len > 0) allocator.free(s.chunks);
            allocator.free(s.ctx_json);
            allocator.free(s.module_path);
            for (s.kv_prefixes) |arm| {
                allocator.free(arm.prefix);
                if (arm.on) |t| allocator.free(t);
            }
            if (s.kv_prefixes.len > 0) allocator.free(s.kv_prefixes);
            if (s.timer_on) |t| allocator.free(t);
        },
    }
}

fn proposeAndParkContResume(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    writeset: *const kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    tenant_id: []const u8,
    next: ContResumeNext,
    /// durable-wake-plan P5(a): the resume activation's accumulated
    /// `http.fetch`es. Non-connection-scoped entries (webhook.send's
    /// inline fire, blob.put's PUT) are staged as commit-gated
    /// `Cmd.http_fetch` on the parked unit — released by interpretCmd
    /// strictly after the writeset commits, the same gate the inbound
    /// path applies. Connection-scoped (`on.fetch`) entries are LEFT
    /// on the list (binding to a held entity from a writing resume is
    /// still unwired — callers warn loudly about leftovers).
    fetches_opt: ?*std.ArrayListUnmanaged(globals.PendingFetch),
    /// The cont-resume dispatch's readset, serialized
    /// onto the raft envelope's `rs_bytes` section so the resumed
    /// activation is replayable on any follower. Pointer (not value)
    /// because the readset lives in the caller's stack frame. Mutable
    /// so the unread-body elision below applies before serialization.
    readset: *tape_mod.Readset,
    /// Per-activation LogHeader stamped into the readset
    /// blob so any follower can rebuild the customer
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

    // Read-taping: drop the body reference when the handler never
    // read it (idempotent — captureTapes may have elided already,
    // but on this path the raft copy serializes here and must agree
    // with the LogRecord copy regardless of call order).
    readset.elideUnreadBody();

    // Serialize the cont-resume's readset (with the caller-supplied
    // LogHeader stamped into it) wrapped as the 1-item readset list the
    // anchor envelope expects, so the resumed activation is replayable
    // on any follower. Best-effort — any failure logs and we propose
    // with empty rs_bytes.
    const rs_bytes: []u8 = tape_mod.encodeSingleReadset(allocator, readset, log_header_opt) catch |err| blk: {
        std.log.warn(
            "rove-js cont-resume: encodeSingleReadset tenant={s}: {s}",
            .{ tenant_id, @errorName(err) },
        );
        break :blk &.{};
    };
    defer if (rs_bytes.len > 0) allocator.free(rs_bytes);
    // Reserve the move-routing Cmd's slot (1 respond + the resume's
    // non-connection-scoped fetches) BEFORE the propose. The `.respond`
    // Cmd is what routes the committed entity to its response — if its
    // alloc fails AFTER the propose commits, the commit-arm can't ship
    // the response and the client waits out the full RaftWait deadline
    // for a misleading 503, silently. Reserving here means the
    // post-propose appends can't fail; an OOM now is a clean pre-propose
    // failure the caller degrades to a defined 500.
    const respond_dest: effect_mod.cmd.RespondOut.DestColl = switch (next) {
        .terminal => .response_in,
        .repark => .parked_continuations,
        .stream => .stream_response_in,
    };
    const fetch_count: usize = if (fetches_opt) |f| f.items.len else 0;
    var cont_cmds: effect_mod.cmd.BufferedCmds = .{};
    cont_cmds.items.ensureTotalCapacityPrecise(allocator, 1 + fetch_count) catch |err| {
        discardContResume(allocator, txn, next);
        return err;
    };

    const seq = (raft_propose.proposeBatch(worker, writeset, tenant_id, rs_bytes) catch |err| {
        // On propose failure: rollback txn, destroy it, free `next`'s
        // owned resources. ContDescriptor on the entity deinits
        // structurally when the entity is destroyed. Caller's catch path
        // handles the 500 flush + log.
        cont_cmds.items.deinit(allocator);
        discardContResume(allocator, txn, next);
        return err;
    }).seq;
    // Resolve the tenant's group id (registered by the
    // propose above) for the per-tenant RaftWait the drain looks up.
    const group_id = worker.raft.gidForTenant(tenant_id) orelse 0;
    // Propose accepted. From here we own the parked-side
    // bookkeeping; if it fails the chain is in a half-state we can't
    // gracefully roll back (the raft entry is committed-pending).
    // Hand the txn to the chain by handle (cross-worker-safe commit/
    // rollback at drain); pointer fallback on the rare invalidation race.
    txn.park(seq) catch |perr|
        std.log.warn("rove-js cont-resume: park seq={d} tenant={s}: {s} (pointer fallback)", .{ seq, tenant_id, @errorName(perr) });
    try worker.pending_txns.park(allocator, group_id, seq, txn);
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
    //     multi-bind writes-per-chunk case — the chunk spool,
        //     `docs/architecture/routing-and-ingress.md`).
    //   - repark → `parked_continuations`: the chain awaits its next
    //     bound-fetch chunk / callback.
    //   - cont→stream → `stream_response_in`: h2 picks up the stream.
    cont_cmds.items.appendAssumeCapacity(.{ .respond = .{
        .entity = ent,
        .source = .raft_pending_cont,
        .dest = respond_dest,
    } });
    // P5(a): commit-gate the resume's unbound fetches. Compact the
    // connection-scoped ones (which we can't stage) to the front of
    // the caller's list; everything else transfers into the unit.
    if (fetches_opt) |fetches| {
        var keep: usize = 0;
        for (fetches.items) |pf| {
            if (pf.connection_scoped) {
                fetches.items[keep] = pf;
                keep += 1;
                continue;
            }
            // Capacity for these was reserved before the propose
            // (1 + fetch_count), so the append can't fail.
            cont_cmds.items.appendAssumeCapacity(.{ .http_fetch = pf });
        }
        fetches.items.len = keep;
    }
    parkKvWakes(worker, seq, tenant_id, writeset, cont_cmds) catch |perr|
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
                .group_id = group_id,
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
                // Held state (`docs/architecture/effects-and-handlers.md`):
                // drop the NodeState owner mirror for the OLD
                // send_id; the new one was registered above when
                // the repark scanned the writeset.
                worker.node.router.unregisterBoundSendOwner(old_b);
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
                .group_id = group_id,
                .seq = seq,
                .deadline_ns = deadline_ns,
            });
            try server.reg.move(ent, &worker.parked_continuations, &worker.raft_pending_cont);
        },
        .stream => |s| {
            // The cont→stream transition (the streaming substrate,
            // `docs/architecture/routing-and-ingress.md`). The entity moves from
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
                // NodeState cleanup — chain is no longer
                // a cont, drop the send owner.
                worker.node.router.unregisterBoundSendOwner(old_b);
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

            // Install StreamWakes (prefix strings wrap into unfired
            // arms; ownership transfers). interval_ms = 0 = no timer
            // wake; bound-fetch chunks are the wake source.
            const next_wake_ns: i64 = if (s.interval_ms > 0)
                @as(i64, @intCast(std.time.nanoTimestamp())) + s.interval_ms * std.time.ns_per_ms
            else
                std.math.maxInt(i64);
            // The arms already carry per-arm `{on}`; transfer directly.
            // errdefer covers the transfer window (the next fallible op IS
            // the StreamWakes set) — same posture as the prior
            // armsFromPrefixes path.
            const arms = s.kv_prefixes;
            errdefer {
                for (arms) |arm| {
                    allocator.free(arm.prefix);
                    if (arm.on) |t| allocator.free(t);
                }
                if (arms.len > 0) allocator.free(arms);
            }
            // reg.set overwrites in place without deiniting the prior
            // component — free the cont's old arms/exports first (the
            // parked continuation may have armed on.kv/on.timer before
            // this hop opened the stream), while carrying its pending
            // wake-batch queue across the swap.
            var carried_batches: std.ArrayListUnmanaged(components_mod.PendingWakeBatch) = .empty;
            if (server.reg.get(ent, &worker.parked_continuations, components_mod.StreamWakes)) |old| {
                for (old.kv_prefixes) |arm| {
                    allocator.free(arm.prefix);
                    if (arm.on) |t| allocator.free(t);
                }
                if (old.kv_prefixes.len > 0) allocator.free(old.kv_prefixes);
                if (old.timer_on) |t| allocator.free(t);
                carried_batches = old.pending_batches;
                old.pending_batches = .empty;
                old.* = .{};
            } else |_| {}
            try server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{
                .interval_ms = s.interval_ms,
                .next_wake_ns = next_wake_ns,
                .kv_prefixes = arms,
                .timer_on = s.timer_on,
                .pending_batches = carried_batches,
            });

            try server.reg.set(ent, &worker.parked_continuations, RaftWait, .{
                .group_id = group_id,
                .seq = seq,
                .deadline_ns = deadline_ns,
            });
            try server.reg.move(ent, &worker.parked_continuations, &worker.raft_pending_cont);
        },
    }
    return seq;
}

/// The trampoline resume engine (connection-actor 3b-iii).
///
/// TEA-framing:
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
///       • continuation re-parks re-aim the chain's module when the
///         target is explicit; a re-park with no possible resume
///         source is a defined 500 (`held with no wake source`).
///       • stream → cont→stream transition (`resumeIntoStream`).
/// Install the cont→stream transition's components on a held entity
/// (still in `parked_continuations`) and move it into the streaming
/// pipeline (`stream_response_in`). Shared read-only-path tail of both
/// stream-resume arms (`resumeContinuation` / `resumeBoundFetchChain`).
///
/// Takes ownership of every passed slice: `resp_headers` /
/// `module_path` / `ctx_json` / `kv_prefixes` transfer into the
/// entity's h2 + stream components; each of `chunks` is staged into
/// `StreamChunks` and the spine is freed. The caller logs the hop
/// afterward under its own activation kind (`.send_callback` /
/// `.fetch_chunk`).
///
/// `moveImmediate` (not deferred `move`) so subsequent fetch chunks
/// arriving in the same worker tick see the entity in
/// `stream_response_in` — chunks 0..N from one bound fetch typically
/// arrive in a single batch (Gap #1 smoke); a deferred move would leave
/// the entity in `parked_continuations` until the next flush, so chunks
/// 1+ would dispatch against stale state.
fn installStreamComponentsInline(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    resp_headers: h2.RespHeaders,
    module_path: []u8,
    ctx_json: []u8,
    chunks: [][]u8,
    kv_prefixes: []components_mod.KvArm,
    interval_ms: i64,
    timer_on: ?[]u8,
) void {
    const server = worker.h2;
    const allocator = worker.allocator;
    server.reg.set(ent, &worker.parked_continuations, h2.Status, .{ .code = status }) catch {};
    server.reg.set(ent, &worker.parked_continuations, h2.RespHeaders, resp_headers) catch {};
    server.reg.set(ent, &worker.parked_continuations, h2.RespBody, .{ .data = null, .len = 0 }) catch {};
    server.reg.set(ent, &worker.parked_continuations, h2.H2IoResult, .{ .err = 0 }) catch {};
    server.reg.set(ent, &worker.parked_continuations, h2.StreamId, sid) catch {};
    server.reg.set(ent, &worker.parked_continuations, h2.Session, sess) catch {};
    server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChain, .{
        .module_path = module_path,
        .ctx_json = ctx_json,
        .activation_count = 1,
    }) catch {};

    var staged: components_mod.StreamChunks = .{};
    staged.queue.ensureUnusedCapacity(allocator, chunks.len) catch {};
    for (chunks) |chunk| staged.tryAppend(allocator, chunk) catch {};
    server.reg.set(ent, &worker.parked_continuations, components_mod.StreamChunks, staged) catch {};
    if (chunks.len > 0) allocator.free(chunks);

    const next_wake_ns: i64 = if (interval_ms > 0)
        @as(i64, @intCast(std.time.nanoTimestamp())) + interval_ms * std.time.ns_per_ms
    else
        std.math.maxInt(i64);
    // The arms already carry per-arm `{on}`; transfer directly.
    const arms = kv_prefixes;
    // reg.set overwrites in place without deiniting the prior component —
    // free the cont's old arms/exports first (the parked continuation may
    // have armed on.kv/on.timer before the bound fetch opened the stream),
    // carrying its pending wake-batch queue across the swap.
    var carried_batches: std.ArrayListUnmanaged(components_mod.PendingWakeBatch) = .empty;
    if (server.reg.get(ent, &worker.parked_continuations, components_mod.StreamWakes)) |old| {
        for (old.kv_prefixes) |arm| {
            allocator.free(arm.prefix);
            if (arm.on) |t| allocator.free(t);
        }
        if (old.kv_prefixes.len > 0) allocator.free(old.kv_prefixes);
        if (old.timer_on) |t| allocator.free(t);
        carried_batches = old.pending_batches;
        old.pending_batches = .empty;
        old.* = .{};
    } else |_| {}
    server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{
        .interval_ms = interval_ms,
        .next_wake_ns = next_wake_ns,
        .kv_prefixes = arms,
        .timer_on = timer_on,
        .pending_batches = carried_batches,
    }) catch {};

    server.reg.moveImmediate(ent, &worker.parked_continuations, &server.stream_response_in) catch |merr|
        std.log.warn("rove-js cont→stream move: {s}", .{@errorName(merr)});
}

/// The host-function locals `resumeIntoStream` needs from its caller.
/// Concrete-typed (the generic bits — `worker` / the `.stream` payload
/// `s` — pass separately), so it bundles cleanly. `txn_owned` /
/// `txn_done` are pointers because the helper flips the caller's
/// ownership flags (their `defer`s in the caller act on the new value).
const StreamResumeCtx = struct {
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    ws: *kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    tenant_id: []const u8,
    readset: *tape_mod.Readset,
    cont_path: []const u8,
    correlation_id: ?[]const u8,
    request_id: u64,
    now_ns: i64,
    deployment_id: u64,
    wrote: bool,
    txn_owned: *bool,
    txn_done: *bool,
    /// `.send_callback` (resumeContinuation) / `.fetch_chunk`
    /// (resumeBoundFetchChain) — the ONLY semantic difference between
    /// the two callers' `.stream` arms.
    activation: log_mod.ActivationSource,
    /// P5(a): the resume hop's `http.fetch` accumulator (see
    /// `proposeAndParkContResume.fetches_opt`).
    pending_fetches: ?*std.ArrayListUnmanaged(globals.PendingFetch) = null,
    /// Pre-built tape payloads for this transition hop's log record.
    /// `resumeIntoStream` CONSUMES it: the
    /// `.ok` capture hands it to captureLogWithId; every other exit
    /// deinits it. Callers with a taped Msg (`.fetch_chunk` — the
    /// bound-fetch cont→stream transition — and `.inbound_chunk`) MUST
    /// pass this, or the record ships empty tapes and the fetch_chunk
    /// case aborts at `l3AssertMsgRecorded` (the boundproxy 502 +
    /// rc=-6: dispatchSpoolHead → resumeBoundFetchChain `.stream` arm
    /// never wired its captureFetchChunkTapes). Built by the CALLER so
    /// the Msg lands on the readset BEFORE the write path's
    /// `proposeAndParkContResume` serializes it into the propose.
    tapes: ?log_mod.TapePayloads = null,
};

/// The cont→stream transition on resume (the streaming substrate,
/// `docs/architecture/routing-and-ingress.md`), shared by `resumeContinuation` and
/// `resumeBoundFetchChain`. Parse the customer's `stream({headers})`
/// wire buffer, take ownership of the payload slices out of `s`, then
/// either propose+park via raft (write path) or commit+install
/// inline (read-only — see `installStreamComponentsInline`). The held
/// socket transitions from "cont awaiting one wake" to "stream
/// emitting chunks per wake".
///
/// Takes ownership of `s`'s slices (clears them so a later `s.deinit`
/// is a no-op). Every failure arm frees what it holds + `resolveParked`s
/// the entity to a 500 + logs the hop under its `activation`.
fn resumeIntoStream(worker: anytype, s: anytype, ctx: StreamResumeCtx) void {
    const allocator = worker.allocator;
    const server = worker.h2;

    // The hop's tape payloads (see StreamResumeCtx.tapes): consumed by
    // whichever `.ok` capture runs; freed on every other exit.
    var hop_tapes: log_mod.TapePayloads = ctx.tapes orelse .{};
    var hop_tapes_consumed = false;
    defer if (!hop_tapes_consumed) hop_tapes.deinit(allocator);

    // `next(path, {fn})` has no slot on a stream chain — the wake
    // arm's `{on}` names the resume export. Defined author error,
    // never a silent free.
    if (s.fn_name != null) {
        s.deinit(allocator);
        ctx.txn.rollback() catch {};
        ctx.txn_done.* = true;
        resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, worker_mod.NEXT_FN_UNSUPPORTED_BODY) catch {};
        captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path, "", ctx.deployment_id, ctx.now_ns, 500, .handler_error, &.{}, &.{}, .{}, ctx.correlation_id, &.{}, ctx.activation, 0);
        return;
    }

    // Parse the stream({headers}) wire-format buffer (`Key: Val\r\n…`)
    // into the typed list shape proposeAndParkContResume expects; the
    // buffer is consumed (entries copy the bytes) so free the original.
    const parsed_headers: []dispatcher_mod.ResponseHeader = if (s.headers) |hbuf|
        @import("worker_dispatch.zig").parseStreamHeaders(allocator, hbuf) catch &.{}
    else
        &.{};
    if (s.headers) |h| allocator.free(h);
    s.headers = null;

    // Module path for the chain's later resumes: the one `next()`
    // semantic — an explicit cross-module target re-aims the chain;
    // the ambient (empty) path keeps the cont's current path.
    const module_path_dup = allocator.dupe(u8, if (s.path.len > 0) s.path else ctx.cont_path) catch {
        // Alloc failure before ownership transfer: `s` still owns its
        // slices, so `s.deinit` frees them.
        for (parsed_headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (parsed_headers.len > 0) allocator.free(parsed_headers);
        s.deinit(allocator);
        ctx.txn.rollback() catch {};
        ctx.txn_done.* = true;
        resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, "stream resume alloc failed\n") catch {};
        captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path, "", ctx.deployment_id, ctx.now_ns, 500, .fault, &.{}, &.{}, .{}, ctx.correlation_id, &.{}, ctx.activation, 0);
        return;
    };

    // Transfer ownership of every slice OUT of `s` into locals; clear
    // `s`'s fields so its remaining lifetime is a no-op deinit.
    const stream_status = s.status;
    const stream_chunks = s.chunks;
    const stream_ctx_json = s.ctx_json;
    const stream_kv_prefixes = s.kv_prefixes;
    const stream_interval = s.interval_ms orelse 0;
    const stream_timer_on = s.timer_on;
    if (s.path.len > 0) allocator.free(s.path);
    s.path = &.{};
    s.chunks = &.{};
    s.ctx_json = &.{};
    s.kv_prefixes = &.{};
    s.timer_on = null;

    if (ctx.wrote) {
        // status=0: parked-hop convention (matches repark).
        const lh = worker_streaming.fireLogHeader(ctx.request_id, ctx.deployment_id, 0, ctx.activation, "POST", ctx.cont_path, "", ctx.correlation_id, ctx.now_ns);
        const stream_seq = proposeAndParkContResume(
            worker,
            ctx.ent,
            ctx.sid,
            ctx.sess,
            ctx.ws,
            ctx.txn,
            ctx.tenant_id,
            .{ .stream = .{
                .status = stream_status,
                .resp_headers = parsed_headers,
                .chunks = stream_chunks,
                .ctx_json = stream_ctx_json,
                .module_path = module_path_dup,
                .kv_prefixes = stream_kv_prefixes,
                .interval_ms = stream_interval,
                .timer_on = stream_timer_on,
            } },
            ctx.pending_fetches,
            ctx.readset,
            lh,
        ) catch |perr| {
            // proposeAndParkContResume's failure arm freed every
            // payload slice + destroyed the txn.
            std.log.warn("rove-js stream-resume: propose failed: {s}", .{@errorName(perr)});
            ctx.txn_owned.* = false;
            ctx.txn_done.* = true;
            resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, "stream resume write replication failed\n") catch {};
            captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path, "", ctx.deployment_id, ctx.now_ns, 500, .fault, &.{}, &.{}, .{}, ctx.correlation_id, &.{}, ctx.activation, 0);
            return;
        };
        ctx.txn_owned.* = false;
        ctx.txn_done.* = true;
        hop_tapes_consumed = true;
        captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path, "", ctx.deployment_id, ctx.now_ns, 0, .ok, &.{}, &.{}, hop_tapes, ctx.correlation_id, &.{}, ctx.activation, stream_seq);
        return;
    }

    // Read-only stream resume: commit inline (nothing to replicate),
    // install stream components, move parked_continuations →
    // stream_response_in directly. The §2 one-rule holds — read-only
    // commits before the chunk reaches the wire (h2 ships from
    // stream_data_out, reached only after this move).
    ctx.txn.commit() catch |e| panic_mod.invariantViolated(
        "resumeIntoStream.commit(stream_read_only)",
        "err={s}",
        .{@errorName(e)},
    );
    ctx.txn_done.* = true;

    // Dupe cont_path BEFORE clearing the ContDescriptor — cont_path
    // borrows into desc.cont.path; the deinit frees that backing
    // memory and any later read (captureLogWithId) would be UAF.
    const cont_path_for_log = allocator.dupe(u8, ctx.cont_path) catch &.{};
    defer if (cont_path_for_log.len > 0) allocator.free(cont_path_for_log);

    // Clear the stale ContDescriptor (the chain is no longer a cont).
    // ChainContext stays.
    const stale_desc = server.reg.get(ctx.ent, &worker.parked_continuations, components_mod.ContDescriptor) catch null;
    if (stale_desc) |d| {
        if (d.cont) |*old_c| old_c.deinit(allocator);
        if (d.bound_schedule_id) |b| {
            worker.node.router.unregisterBoundSendOwner(b);
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
        for (parsed_headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (parsed_headers.len > 0) allocator.free(parsed_headers);
        allocator.free(module_path_dup);
        allocator.free(stream_ctx_json);
        for (stream_chunks) |chunk_bytes| allocator.free(chunk_bytes);
        if (stream_chunks.len > 0) allocator.free(stream_chunks);
        for (stream_kv_prefixes) |arm| {
            allocator.free(arm.prefix);
            if (arm.on) |t| allocator.free(t);
        }
        if (stream_kv_prefixes.len > 0) allocator.free(stream_kv_prefixes);
        if (stream_timer_on) |t| allocator.free(t);
        resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, "stream resume header build failed\n") catch {};
        captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", cont_path_for_log, "", ctx.deployment_id, ctx.now_ns, 500, .fault, &.{}, &.{}, .{}, ctx.correlation_id, &.{}, ctx.activation, 0);
        return;
    };
    for (parsed_headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    if (parsed_headers.len > 0) allocator.free(parsed_headers);

    installStreamComponentsInline(worker, ctx.ent, ctx.sid, ctx.sess, stream_status, handler_resp_hdrs, module_path_dup, stream_ctx_json, stream_chunks, stream_kv_prefixes, stream_interval, stream_timer_on);
    // P5(a): read-only cont→stream transition committed above — flush
    // the hop's unbound fetches now. Connection-scoped binds from this
    // transition stay unwired (the entity just moved to the stream
    // collections; flushResumeFetches' parked_continuations count bump
    // soft-fails there) — they drop with a register failure.
    if (ctx.pending_fetches) |pf| worker_streaming.flushResumeFetches(worker, ctx.ent, pf, false);
    hop_tapes_consumed = true;
    captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", cont_path_for_log, "", ctx.deployment_id, ctx.now_ns, 0, .ok, &.{}, &.{}, hop_tapes, ctx.correlation_id, &.{}, ctx.activation, 0);
}

/// 503 (retriable) when this activation's failure was an invalidated txn
/// — a chain predecessor faulted and the cascade self-aborted it
/// (`Error.TxnInvalidated` via `pending_kv_error`); else 500. Lets a
/// resume hop's held caller retry rather than treat a transient
/// speculative-basis loss as a hard handler error. `last_kv_error` is
/// reset per activation at `runOutcome` entry.
fn resumeErrStatus(worker: anytype) u16 {
    if (worker.dispatcher.last_kv_error) |lke| {
        if (lke == error.TxnInvalidated) return 503;
    }
    return 500;
}

/// The deadline trigger passes `allow_repark = false`.
/// `error.Resume*` → caller falls back to a hard 504.
/// Which Msg-tape the site's log records carry (per-capture
/// materialization — the capture may append the activation's Msg to the
/// readset, and the write arms serialize the readset into the propose,
/// so materialization order is part of the wire format; keep it exactly
/// where each capture runs). `.cont` is the cont-resume site's
/// runtime-kind dispatch: wake_batch and send_callback share the site
/// (`resumeContinuation`) but tape different Msgs.
const ContTape = enum { cont, chunk, fetch };

/// Comptime per-site axes of `finishContResume` — everything else the
/// three cont-family sites do is identical. That identity is the point:
/// each family's outcome switch exists exactly once, so a fix to one arm
/// cannot drift out of a sibling copy. Keep any new per-site behavior in
/// this spec, never open-coded at a call site.
const ContFinishSpec = struct {
    /// Operator warn-log tag ("cont-resume" / "bound-fetch" / "inbound-chunk").
    site: []const u8,
    /// Client-visible noun in the defined-failure response bodies
    /// ("<noun> handler error\n", "<noun> alloc failed\n",
    /// "<noun> write replication failed\n").
    noun: []const u8,
    /// Cancel sibling bound-fetch binds when the chain goes terminal —
    /// the bound-fetch + inbound-chunk sites (their chains can hold
    /// binds); plain continuations have none.
    cancel_binds: bool,
    tape: ContTape,
};

/// Runtime context for `finishContResume` (the cont-family sibling of
/// `StreamResumeCtx`). All slices borrow the caller's locals for the
/// duration of the call.
const ContFinishCtx = struct {
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    ws: *kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    tenant_id: []const u8,
    readset: *tape_mod.Readset,
    /// The resume target module path (feeds LogHeaders + the ambient
    /// `next(ctx)` empty-path fixup). May borrow desc.cont backing
    /// memory — freed by a write-repark — hence the separate
    /// `cont_path_log` snapshot for post-mutation log records.
    cont_path: []const u8,
    cont_path_log: []const u8,
    correlation_id: ?[]const u8,
    request_id: u64,
    now_ns: i64,
    deployment_id: u64,
    wrote: bool,
    txn_owned: *bool,
    txn_done: *bool,
    /// `.send_callback` / `.wake_batch` (resumeContinuation) /
    /// `.fetch_chunk` / `.inbound_chunk`.
    act: log_mod.ActivationSource,
    /// §6.4 mandatory-timeout gate: false ⇒ a returned continuation is
    /// rejected with a defined 504 (the deadline path must terminate,
    /// not extend). Only resumeContinuation's sweep passes false.
    allow_repark: bool = true,
    pending_fetches: *std.ArrayListUnmanaged(globals.PendingFetch),
    /// This hop's `after.*` (`on.kv`/`on.timer`) registrations. A `next()`
    /// repark installs them onto the chain's `StreamWakes` via
    /// `installContWakes` BEFORE the wake-source vigilance check, so a
    /// resume that arms a fresh wake (the failure the bound-fetch /
    /// inbound-chunk / send_callback resumes used to drop into the null
    /// accumulator) both counts as a resume source and actually fires.
    pending_wakes: *std.ArrayListUnmanaged(globals.PendingWakeReg),
    /// Tape sources, read per `ContFinishSpec.tape`: `.chunk` reads
    /// `tape_bytes`; `.fetch` reads `tape_body` + `tape_ev`; `.cont`
    /// reads `tape_body` (the `{"ctx":…}` envelope — for a
    /// send_callback it carries the whole callee outcome) + `wakes`
    /// (the drained fired-watch batch, wake resumes only) +
    /// `resume_export` (the resolved resume export).
    tape_bytes: []const u8 = "",
    tape_body: []const u8 = "",
    tape_ev: ?worker_mod.FetchEvent = null,
    wakes: []const components_mod.WakeEntry = &.{},
    resume_export: []const u8 = "",
};

inline fn contTapes(worker: anytype, comptime tape: ContTape, ctx: *const ContFinishCtx) log_mod.TapePayloads {
    return switch (tape) {
        // The cont-resume site's Msg depends on the runtime kind:
        // a wake resume's Msg is the drained fired-watch batch;
        // a send_callback's Msg is the callee outcome —
        // the whole `{"ctx":…}` body envelope. Both tape
        // readset + ctx + the resolved export so the hop is replayable.
        .cont => switch (ctx.act) {
            .wake_batch => worker_mod.captureWakeBatchTapes(worker, ctx.readset, ctx.tape_body, ctx.wakes, ctx.resume_export),
            .send_callback => worker_mod.captureSendCallbackTapes(worker, ctx.readset, ctx.tape_body, ctx.resume_export),
            else => .{},
        },
        .chunk => worker_mod.captureTapes(worker, ctx.readset, ctx.tape_bytes),
        .fetch => worker_mod.captureFetchChunkTapes(worker, ctx.readset, ctx.tape_body, ctx.tape_ev.?),
    };
}

/// Install (or replace) a parked continuation's `StreamWakes` from one
/// resume hop's `on.kv`/`on.timer` registrations — the cont-family analog
/// of `worker_ws.installWsWakes` / worker_dispatch's `armContWakesIfAny`.
/// A held chain re-arms its wakes per activation (`docs/handler-shape.md`
/// §2.3: call `after.*` again to keep listening — the SSE-loop shape), so a
/// resume that armed any `after.*` REPLACES the chain's prior arms. Frees
/// the old registration's owned memory first (reg.set overwrites in place,
/// it does NOT deinit the prior component). Call only when
/// `pending.items.len > 0`: an empty hop leaves the existing arms untouched
/// so they ride the chain across resumes. Operates on the entity while it
/// is still in `parked_continuations` — for a writing repark the component
/// then rides the raft_pending_cont round-trip back into the collection.
/// OOM leaves the chain unarmed rather than leaking (the §6.4 deadline is
/// the backstop).
fn installContWakes(
    worker: anytype,
    ent: rove.Entity,
    pending: *std.ArrayListUnmanaged(globals.PendingWakeReg),
    read_version: u64,
) void {
    const allocator = worker.allocator;
    const server = worker.h2;

    // Carry the pending wake-batch queue across the re-arm — undispatched
    // export groups ride to the next sweep tick, not the freed arm slice.
    var carried: std.ArrayListUnmanaged(components_mod.PendingWakeBatch) = .empty;
    if (server.reg.get(ent, &worker.parked_continuations, components_mod.StreamWakes)) |old| {
        for (old.kv_prefixes) |arm| {
            allocator.free(arm.prefix);
            if (arm.on) |t| allocator.free(t);
        }
        if (old.kv_prefixes.len > 0) allocator.free(old.kv_prefixes);
        if (old.timer_on) |t| allocator.free(t);
        carried = old.pending_batches;
        old.pending_batches = .empty;
        old.* = .{};
    } else |_| {}

    var interval_ms: i64 = 0;
    var timer_on: ?[]u8 = null;
    var arms: std.ArrayListUnmanaged(components_mod.KvArm) = .empty;
    for (pending.items) |reg| {
        switch (reg.kind) {
            // Per-arm routing: each arm keeps its own `{on}`; last timer wins.
            .timer => {
                interval_ms = reg.interval_ms;
                if (timer_on) |old_to| allocator.free(old_to);
                timer_on = if (reg.on) |t| allocator.dupe(u8, t) catch null else null;
            },
            .kv => if (reg.prefix.len > 0) {
                const dup = allocator.dupe(u8, reg.prefix) catch continue;
                const on: ?[]u8 = if (reg.on) |t| allocator.dupe(u8, t) catch null else null;
                arms.append(allocator, .{ .prefix = dup, .on = on }) catch {
                    allocator.free(dup);
                    if (on) |t| allocator.free(t);
                };
            },
        }
    }
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const next_wake_ns: i64 = if (interval_ms > 0)
        now_ns + interval_ms * std.time.ns_per_ms
    else
        std.math.maxInt(i64);
    const kv_prefixes = arms.toOwnedSlice(allocator) catch {
        for (arms.items) |arm| {
            allocator.free(arm.prefix);
            if (arm.on) |t| allocator.free(t);
        }
        arms.deinit(allocator);
        if (timer_on) |t| allocator.free(t);
        server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{ .pending_batches = carried }) catch {};
        return; // OOM — leave the chain unarmed (but keep the queue)
    };
    server.reg.set(ent, &worker.parked_continuations, components_mod.StreamWakes, .{
        .interval_ms = interval_ms,
        .next_wake_ns = next_wake_ns,
        .kv_prefixes = kv_prefixes,
        .read_version = read_version,
        .timer_on = timer_on,
        .pending_batches = carried,
    }) catch {};
}

/// §2.2 (refactor-audit): the ONE outcome-finishing switch for the three
/// cont-family resume sites — send_callback/wake (`resumeContinuation`),
/// bound-fetch chunk (`resumeBoundFetchChain`), and the inbound-chunk
/// resume. The WS family's sibling is `finishWsResume` (worker_ws.zig);
/// the stream family's arms live in worker_streaming.zig; the
/// cont→stream transition is the already-shared `resumeIntoStream`.
///
/// Arms: terminal-with-exception → rollback + defined 500 + log;
/// terminal-with-writes → propose + park on `raft_pending_cont` (the
/// helper owns the txn on success AND failure — `txn_owned` flips false
/// either way); terminal-read-only → commit + flush fetches + resolve;
/// continuation → repark (write: propose `.repark`; read-only: in-place
/// desc swap, `bound_schedule_id` UNTOUCHED — see the component's
/// contract); stream → `resumeIntoStream`; no-export probe → defined 500.
///
/// Read-only commits panic on failure (`error.Conflict` included):
/// resumes run inside the chain lease, so a clean read-only commit
/// cannot legitimately conflict — unlike `commitReadOnlyFire`, whose
/// connectionless fires run outside the lease and tolerate it.
fn finishContResume(
    worker: anytype,
    comptime spec: ContFinishSpec,
    oc: *dispatcher_mod.RunOutcome,
    ctx: ContFinishCtx,
) void {
    const allocator = worker.allocator;
    const server = worker.h2;
    const dep_id = ctx.deployment_id;
    switch (oc.*) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (comptime spec.cancel_binds) scanAndCancelBoundFetches(worker, ctx.ent);
            // A thrown resume hop is an EXPECTED condition (author
            // error). It must be a defined 5xx, never a flushed
            // 200-empty, which would silently mask an effectful-resume
            // failure — feedback_infallibility_violations.
            if (r.exception.len > 0) {
                ctx.txn.rollback() catch {};
                ctx.txn_done.* = true;
                resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, spec.noun ++ " handler error\n") catch {};
                captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 500, .handler_error, r.console, r.exception, contTapes(worker, spec.tape, &ctx), ctx.correlation_id, r.tags, ctx.act, 0);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            if (ctx.wrote) {
                // Terminal + writes — propose through raft, park the
                // entity on `raft_pending_cont` with the response staged;
                // its drainEntityArm ships the response at commit.
                const body_dup = allocator.dupe(u8, r.body) catch {
                    ctx.txn.rollback() catch {};
                    ctx.txn_done.* = true;
                    resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, spec.noun ++ " alloc failed\n") catch {};
                    captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 500, .handler_error, r.console, r.exception, contTapes(worker, spec.tape, &ctx), ctx.correlation_id, r.tags, ctx.act, 0);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                const console_owned = r.console;
                const exception_owned = r.exception;
                r.console = &.{};
                r.exception = &.{};
                const lh = worker_streaming.fireLogHeader(ctx.request_id, dep_id, st, ctx.act, "POST", ctx.cont_path, "", ctx.correlation_id, ctx.now_ns);
                // Tapes before the propose so the input channels (ctx/Msg on
                // trigger_payload, fetch event on fetch_responses) ride the raft
                // readset for the promotion walker
                // (`docs/architecture/deployment-and-logs.md`). Consumed by
                // exactly one capture below (fault or ok).
                const tapes = contTapes(worker, spec.tape, &ctx);
                const seq = proposeAndParkContResume(
                    worker,
                    ctx.ent,
                    ctx.sid,
                    ctx.sess,
                    ctx.ws,
                    ctx.txn,
                    ctx.tenant_id,
                    .{ .terminal = .{ .status = st, .body = body_dup } },
                    ctx.pending_fetches,
                    ctx.readset,
                    lh,
                ) catch |perr| {
                    // Propose-fail / pre-park alloc failure: degrade to a
                    // defined 500 over the held socket. The helper rolled
                    // back + destroyed the txn.
                    std.log.warn("rove-js " ++ spec.site ++ ": propose failed: {s}", .{@errorName(perr)});
                    allocator.free(body_dup);
                    ctx.txn_owned.* = false;
                    ctx.txn_done.* = true;
                    resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, spec.noun ++ " write replication failed\n") catch {};
                    captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 500, .fault, console_owned, exception_owned, tapes, ctx.correlation_id, &.{}, ctx.act, 0);
                    return;
                };
                // Helper took ownership of txn (moved into pending_txns)
                // and body_dup (stamped onto the entity).
                ctx.txn_owned.* = false;
                ctx.txn_done.* = true;
                captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, st, .ok, console_owned, exception_owned, tapes, ctx.correlation_id, r.tags, ctx.act, seq);
                if (ctx.pending_fetches.items.len > 0) std.log.warn(
                    "rove-js " ++ spec.site ++ ": {d} connection-scoped fetch(es) from a WRITING resume dropped (bind-from-writing-resume not wired) tenant={s}",
                    .{ ctx.pending_fetches.items.len, ctx.tenant_id },
                );
                return;
            }
            // Clean read-only commit cannot fault (mirrors finalizeBatch's
            // read-only invariant) — panic, never soft.
            ctx.txn.commit() catch |e| panic_mod.invariantViolated(
                spec.site ++ ".commit(terminal_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            ctx.txn_done.* = true;
            // Terminal ⇒ the connection is closing: connection-scoped
            // fetches drop (scope rule), unbound ones still fire.
            worker_streaming.flushResumeFetches(worker, ctx.ent, ctx.pending_fetches, false);
            resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, st, r.body) catch {};
            captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, st, .ok, r.console, r.exception, contTapes(worker, spec.tape, &ctx), ctx.correlation_id, r.tags, ctx.act, 0);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |c2| {
            var c2m = c2;
            // An ambient `next(ctx)` repark emits
            // an empty path — resolve it to the resuming module (the chain
            // re-invokes itself). Explicit cross-module `__rove_next` keeps
            // its path. OOM: leave empty (resume resolves to a clean error).
            if (c2m.path.len == 0) {
                if (allocator.dupe(u8, ctx.cont_path)) |dup| {
                    allocator.free(c2m.path);
                    c2m.path = dup;
                } else |_| {}
            }
            if (!ctx.allow_repark) {
                // Deadline path: §6.4 mandatory timeout must terminate,
                // not extend. Reject any new cont with a defined 504.
                c2m.deinit(allocator);
                ctx.txn.rollback() catch {};
                ctx.txn_done.* = true;
                resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 504, "hold deadline exceeded\n") catch {};
                return;
            }
            // Re-arm this hop's `after.*` onto the chain's `StreamWakes`
            // BEFORE the vigilance check below reads it — a resume that
            // arms a fresh `on.kv`/`on.timer` (bound-fetch / inbound-chunk
            // / send_callback hops, whose accumulator used to be null)
            // must both count as a resume source and actually fire. An
            // empty hop leaves the prior arms untouched (they ride the
            // chain). The read-view baseline is this hop's readVersion
            // (matches `armContWakesIfAny`); the write-repark install
            // rides the raft_pending_cont round-trip back via the Row.
            if (ctx.pending_wakes.items.len > 0)
                installContWakes(worker, ctx.ent, ctx.pending_wakes, ctx.txn.readVersion());
            // Park-time vigilance (docs/handler-shape.md §2.1): the
            // re-park must leave ≥1 possible resume source — a send
            // binding (kept across read-only hops / re-scanned on a
            // writing hop), an armed `after.*` riding the chain, an
            // in-flight bound fetch, a fetch this hop issues that
            // will bind, remaining inbound body chunks, or the open
            // WS socket. An empty set can never resume: fail loud
            // now, naming the mistake, instead of the generic 504
            // when the deadline sweeps 25 s later. (Fetches from a
            // WRITING repark are dropped — bind-from-writing-resume
            // is unwired — so they do NOT count; a park whose only
            // source was those surfaces that gap here.)
            const will_have_source = blk: {
                if (ctx.wrote) {
                    if (worker_mod.scanLoneOwedSendId(ctx.ws.ops.items) != null) break :blk true;
                } else if (server.reg.get(ctx.ent, &worker.parked_continuations, components_mod.ContDescriptor)) |d| {
                    if (d.bound_schedule_id != null) break :blk true;
                } else |_| {}
                if (server.reg.get(ctx.ent, &worker.parked_continuations, components_mod.StreamWakes)) |sw| {
                    if (sw.interval_ms > 0 or sw.kv_prefixes.len > 0) break :blk true;
                } else |_| {}
                if (server.reg.get(ctx.ent, &worker.parked_continuations, components_mod.BoundFetchCount)) |cnt| {
                    if (cnt.pending > 0) break :blk true;
                } else |_| {}
                if (!ctx.wrote) {
                    for (ctx.pending_fetches.items) |pf| {
                        if (pf.connection_scoped) break :blk true;
                    }
                }
                // A live inbound-chunk job resumes the chain with its next
                // staged fire — presence alone counts (eof only means the
                // BYTES all arrived; fires may still be queued behind this
                // hop). A handler that next()s past the final fire falls to
                // the deadline backstop, like any armed-but-idle park.
                if (worker.inbound_chunk_jobs.get(ctx.ent) != null) break :blk true;
                if (worker_ws.wsConnForChain(worker, ctx.ent) != null) break :blk true;
                break :blk false;
            };
            if (!will_have_source) {
                c2m.deinit(allocator);
                ctx.txn.rollback() catch {};
                ctx.txn_done.* = true;
                resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, worker_mod.HELD_NO_WAKE_SOURCE_BODY) catch {};
                const errmsg = allocator.dupe(u8, worker_mod.HELD_NO_WAKE_SOURCE_BODY) catch @constCast("");
                captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 500, .handler_error, &.{}, errmsg, contTapes(worker, spec.tape, &ctx), ctx.correlation_id, &.{}, ctx.act, 0);
                return;
            }
            if (ctx.wrote) {
                // Repark + writes — propose, park on `raft_pending_cont`;
                // at commit the entity routes back to
                // `parked_continuations` with the in-place-updated
                // descriptor (new cont, refreshed binding + deadline).
                // §6.4 binding for the repark: scan the writeset for the
                // single `_send/owed/{id}` put. 0 / >1 → null; OOM → null
                // (a deadline-only resume beats propagating).
                const new_bound_sched_id: ?[]u8 = blk: {
                    const only = worker_mod.scanLoneOwedSendId(ctx.ws.ops.items) orelse break :blk null;
                    break :blk allocator.dupe(u8, only) catch null;
                };
                // Held state (`docs/architecture/effects-and-handlers.md`): repark
                // re-binds to a (possibly new) send_id — stamp the owner
                // (same dependency as the worker_dispatch open-hop site).
                if (new_bound_sched_id) |send_id| {
                    _ = worker.node.router.registerBoundSendOwner(send_id, worker.msg_inbox_idx);
                    // Worker-local entity mirror.
                    worker.registerBoundSendEntity(send_id, ctx.ent);
                }
                // status=0: the parked-hop convention (same shape as the
                // inbound trampoline open hop) so replay surfaces it.
                const lh = worker_streaming.fireLogHeader(ctx.request_id, dep_id, 0, ctx.act, "POST", ctx.cont_path, "", ctx.correlation_id, ctx.now_ns);
                // Tapes before the propose — input channels ride the raft
                // readset for the promotion walker (see the terminal arm above).
                const tapes = contTapes(worker, spec.tape, &ctx);
                const seq = proposeAndParkContResume(
                    worker,
                    ctx.ent,
                    ctx.sid,
                    ctx.sess,
                    ctx.ws,
                    ctx.txn,
                    ctx.tenant_id,
                    .{ .repark = .{ .new_cont = c2m, .new_bound_sched_id = new_bound_sched_id } },
                    ctx.pending_fetches,
                    ctx.readset,
                    lh,
                ) catch |perr| {
                    // Helper rolled back + destroyed txn + freed c2m +
                    // new_bound_sched_id on failure; log + degrade.
                    std.log.warn("rove-js " ++ spec.site ++ " (repark): propose failed: {s}", .{@errorName(perr)});
                    ctx.txn_owned.* = false;
                    ctx.txn_done.* = true;
                    resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, spec.noun ++ " write replication failed\n") catch {};
                    captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 500, .fault, &.{}, &.{}, tapes, ctx.correlation_id, &.{}, ctx.act, 0);
                    return;
                };
                ctx.txn_owned.* = false;
                ctx.txn_done.* = true;
                // The repark hop's tape row: status=0, parked.
                captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 0, .ok, &.{}, &.{}, tapes, ctx.correlation_id, &.{}, ctx.act, seq);
                if (ctx.pending_fetches.items.len > 0) std.log.warn(
                    "rove-js " ++ spec.site ++ ": {d} connection-scoped fetch(es) from a WRITING repark dropped (bind-from-writing-resume not wired) tenant={s}",
                    .{ ctx.pending_fetches.items.len, ctx.tenant_id },
                );
                return;
            }
            ctx.txn.commit() catch |e| panic_mod.invariantViolated(
                spec.site ++ ".commit(repark_ro)",
                "err={s}",
                .{@errorName(e)},
            );
            ctx.txn_done.* = true;
            // Re-park in place: swap the descriptor, refresh the deadline;
            // the entity stays in `parked_continuations`. Ownership of c2m
            // transfers to the component. bound_schedule_id is UNTOUCHED
            // on the read-only path: a hop that wrote nothing fired no
            // send, and clearing would strand a chain still awaiting an
            // EARLIER hop's owed send — its callback must keep resuming
            // this park. Only the write-batch repark rewrites the binding.
            const desc = server.reg.get(ctx.ent, &worker.parked_continuations, components_mod.ContDescriptor) catch return;
            if (desc.cont) |*old_c| old_c.deinit(allocator);
            desc.cont = c2m;
            desc.deadline_ns = ctx.now_ns + CONT_HOLD_DEADLINE_NS;
            // Still held (repark) + committed (read-only): bind + submit
            // any fetches this resume issued (handler-shape §5.3).
            worker_streaming.flushResumeFetches(worker, ctx.ent, ctx.pending_fetches, true);
            // A read-only repark is still a recorded activation — without
            // this record the hop is unreplayable (a ctx-only accumulating
            // handler hops read-only on EVERY chunk). Status 0 = the
            // parked-hop convention.
            captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 0, .ok, &.{}, &.{}, contTapes(worker, spec.tape, &ctx), ctx.correlation_id, &.{}, ctx.act, 0);
        },
        .stream => |*s| {
            resumeIntoStream(worker, s, .{
                .ent = ctx.ent,
                .sid = ctx.sid,
                .sess = ctx.sess,
                .ws = ctx.ws,
                .txn = ctx.txn,
                .tenant_id = ctx.tenant_id,
                .readset = ctx.readset,
                .cont_path = ctx.cont_path,
                .correlation_id = ctx.correlation_id,
                .request_id = ctx.request_id,
                .now_ns = ctx.now_ns,
                .deployment_id = dep_id,
                .wrote = ctx.wrote,
                .txn_owned = ctx.txn_owned,
                .txn_done = ctx.txn_done,
                .pending_fetches = ctx.pending_fetches,
                .activation = ctx.act,
                // The activation's Msg tape, built BEFORE the write path
                // serializes the readset into the propose (see
                // StreamResumeCtx.tapes for why that ordering matters).
                .tapes = contTapes(worker, spec.tape, &ctx),
            });
        },
        // Only `.inbound_headers` / `.inbound_chunk` activations produce
        // these; the probe ran on the FIRST fire. Defined failure.
        .no_onheaders, .no_onchunk => {
            ctx.txn.rollback() catch {};
            ctx.txn_done.* = true;
            resolveParked(worker, ctx.ent, ctx.sid, ctx.sess, 500, "export probe on a resume path\n") catch {};
            captureLogWithId(worker, ctx.tenant_id, ctx.request_id, "POST", ctx.cont_path_log, "", dep_id, ctx.now_ns, 500, .handler_error, &.{}, &.{}, contTapes(worker, spec.tape, &ctx), ctx.correlation_id, &.{}, ctx.act, 0);
        },
    }
}

fn resumeContinuation(
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    outcome_json: []const u8,
    allow_repark: bool,
    /// true ⇒ this is an `on.*` connection-wake
    /// resume (timer expiry / kv match), not a `send_callback`. Routes to
    /// the fired arm's own `{on}` export (per-arm; default `onWake`) with a
    /// body of `{fn, args:[ctx]}` (no callee outcome) and a `.wake_batch`
    /// activation. Everything downstream (terminal / continuation / write
    /// handling, re-park) is identical — and on a `next()` re-park the
    /// entity's `StreamWakes` rides along untouched, so a recurring
    /// `on.timer` keeps firing without re-arming (sweep advances
    /// `next_wake_ns` each fire), matching the stream wake path.
    wake: bool,
) !void {
    const allocator = worker.allocator;
    const server = worker.h2;
    // A wake resume's tape rows are
    // `.wake_batch` (an `on.*` connection wake), not `.send_callback`.
    // Used for every captureLog / LogHeader below so replay groups the
    // wake activation correctly under the chain's correlation_id.
    const act_src: log_mod.ActivationSource = if (wake) .wake_batch else .send_callback;
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
    // Snapshot for log records: `cont_path` borrows into desc.cont's
    // backing memory, which a write-repark (`proposeAndParkContResume`
    // `.repark` arm) or an in-place cont refresh FREES before the
    // post-propose captureLogWithId sites run — the same UAF class
    // `resumeIntoStream`'s `cont_path_for_log` snapshot guards (a
    // surfaced log record carried freed bytes as its path).
    const cont_path_log = allocator.dupe(u8, cont_path) catch &.{};
    defer if (cont_path_log.len > 0) allocator.free(cont_path_log);
    const path = cont_path;
    var dep = try resolveDeployment(worker, allocator, tenant_id, path);
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // A continuation is an internal request. Named export → the
    // target rides `Request.fn_override` with positional args
    // `[ctx]` (wake — no callee outcome) / `[ctx,outcome]`
    // (callback); default export → a plain body object
    // `{ctx,outcome}` the handler reads via `request.body`.
    // ctx_json/outcome_json are JSON text embedded verbatim. The
    // A `{fn,args}` body envelope is never synthesized
    // (decisions.md §4.5 — dispatch targeting is first-class;
    // formatting fn names into a JSON envelope is an escaping
    // hazard). A wake resume routes to the fired arm's own `{on}`
    // export (per-arm; default `onWake`) and drains that export's fired
    // arms so they don't re-fire on the next sweep.
    // The drained fired arms are surfaced on `request.activation.wakes[]`
    // as fired PREFIXES — same contract as the stream (resumeStream) and
    // WS (resumeWakeChainWs) resume paths. `onWake` stays a "go look"
    // edge wake: the entries name which watch fired; the handler re-reads
    // authoritative kv. Owned for the dispatch's lifetime; freed after
    // the JS has copied them.
    var batch_owned: []components_mod.WakeEntry = &.{};
    defer if (batch_owned.len > 0) {
        for (batch_owned) |*w| w.deinit(allocator);
        allocator.free(batch_owned);
    };
    // Per-arm routing: the wake dispatches ONE export GROUP per tick (the
    // earliest-fired), its own `{on}` export; other groups ride
    // `pending_batches` and dispatch on later ticks. Owned export string
    // freed after `resume_export_owned` dupes it.
    var wake_export: ?[]u8 = null;
    defer if (wake_export) |t| allocator.free(t);
    const resume_fn: ?[]const u8 = if (wake) blk: {
        const sw = server.reg.get(ent, &worker.parked_continuations, components_mod.StreamWakes) catch break :blk "onWake";
        // OOM → empty batch, arms stay fired and re-fire next tick
        // (safe under edge semantics).
        const wb_opt = sw.nextWakeBatch(allocator) catch null;
        if (wb_opt) |wb| {
            batch_owned = wb.entries;
            wake_export = wb.export_name;
            break :blk wb.export_name;
        }
        break :blk "onWake";
    } else cont_fn_name;
    // Owned snapshot of the resume export for the tape (G3 — replay must
    // invoke the same export): `resume_fn` borrows the drained group's
    // export `wake_export` (wake) or desc.cont.fn_name (send_callback),
    // either of which a repark arm frees before the post-repark log
    // capture runs (the same
    // UAF class `cont_path_log` guards). Empty ⇒ the default export.
    const resume_export_owned: []const u8 = if (resume_fn) |rf|
        allocator.dupe(u8, rf) catch ""
    else
        "";
    defer if (resume_export_owned.len > 0) allocator.free(resume_export_owned);
    const named: bool = wake or cont_fn_name != null;
    // Endpoint A (decisions.md): the resume's threaded ctx + (for a
    // callback) the effect outcome ride the synthesized body envelope —
    // `installRequest` lifts ctx → `request.ctx` and flattens a callback's
    // `result` → `request.body`/`.status` (+ metadata on
    // `request.activation.*`). NOT positional args. A wake has no outcome,
    // so it carries the bare `{"ctx":…}`; a callback wraps the outcome into
    // the SAME `{"ctx":{result, context}}` shape an `on_result` hop uses
    // (the held handler's threaded ctx fills the `context` slot).
    const body = if (wake)
        try worker_streaming.synthCtxBody(allocator, cont_ctx_json)
    else
        try worker_streaming.synthResultBody(allocator, outcome_json, cont_ctx_json);
    defer allocator.free(body);
    const spath = try std.fmt.allocPrint(allocator, "/{s}", .{path});
    defer allocator.free(spath);

    // Heap-allocate the txn so its pointer can be parked on
    // `pending_txns[seq]` if this hop wrote. Same stable-
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
    readset.js_engine_version = dispatcher_mod.JS_ENGINE_VERSION;
    defer readset.deinit();
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    // durable-wake-plan P5(a): accumulate this resume hop's
    // `http.fetch`es (a `webhook.send` from an onResult handler —
    // heldsync recipe-1's retry hop — issues one inline). Write arms
    // stage them as commit-gated Cmds via `proposeAndParkContResume`;
    // read-only arms flush post-commit; error arms free via the defer.
    var pending_fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (pending_fetches.items) |*pf| pf.deinit(allocator);
        pending_fetches.deinit(allocator);
    }
    // A send_callback / wake resume re-arms its `after.*` (installed onto
    // the chain's StreamWakes at the repark seam) and may open a stream
    // (`stream.write` → cont→stream transition). Both accumulators were
    // null here, so those effects silently dropped — wire them.
    var pending_wakes: std.ArrayListUnmanaged(globals.PendingWakeReg) = .empty;
    defer {
        for (pending_wakes.items) |*pw| pw.deinit(allocator);
        pending_wakes.deinit(allocator);
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
        // First-class resume target: the named export (the wake group's export /
        // cont_fn_name). Null → the default export. The threaded ctx +
        // outcome ride `body` (Endpoint A); the resume export reads
        // `request.ctx` / `request.body` — no positional args.
        .fn_override = if (named) resume_fn else null,
        // Inherit the chain id from the parking request so every tape row
        // of this chain shares one correlation_id; mark this activation as
        // a send-callback resume (streaming-handlers-plan §6) — or
        // .wake_batch (with the drained fired prefixes) for an on.* wake.
        .activation = if (wake) .{ .wake_batch = .{ .wakes = batch_owned } } else .send_callback,
        .trace = .{ .readset = &readset, .request_id = request_id, .correlation_id = correlation_id },
        .plan = .{ .limiter = &worker.limiter, .storage = inst.storage, .plan_rate = tc.slot.effectivePlan().rate, .plan_gen = tc.slot.plan_gen.load(.acquire), .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = inst.platform, .platform_caps = worker.adminPlatformCaps(inst) },
        .effects = .{
            .pending_wakes = &pending_wakes,
            .pending_stream_chunks = &stream_chunks,
            .pending_fetches = &pending_fetches,
        },
    };
    std.log.info("rove-js corr: resume corr={s} request_id={d} tenant={s}", .{ correlation_id orelse "(none)", request_id, inst.id });
    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    var oc = worker_mod.runResume(worker, inst, tc, bc, txn, &ws, request, &budget, path) catch {
        txn.rollback() catch {};
        txn_done = true;
        try resolveParked(worker, ent, sid, sess, resumeErrStatus(worker), "continuation handler error\n");
        // Log the failed hop — a resume that dies at dispatch was invisible
        // in tenant logs while every other family records a 500 here.
        captureLogWithId(worker, tenant_id, request_id, "POST", cont_path_log, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, correlation_id, &.{}, act_src, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    finishContResume(worker, .{
        .site = "cont-resume",
        .noun = "continuation",
        .cancel_binds = false,
        .tape = .cont,
    }, &oc, .{
        .ent = ent,
        .sid = sid,
        .sess = sess,
        .ws = &ws,
        .txn = txn,
        .tenant_id = tenant_id,
        .readset = &readset,
        .cont_path = cont_path,
        .cont_path_log = cont_path_log,
        .correlation_id = correlation_id,
        .request_id = request_id,
        .now_ns = now_ns,
        .deployment_id = tc.snap.deployment_id,
        .wrote = wrote,
        .txn_owned = &txn_owned,
        .txn_done = &txn_done,
        .act = act_src,
        .allow_repark = allow_repark,
        .pending_fetches = &pending_fetches,
        .pending_wakes = &pending_wakes,
        .tape_body = body,
        .wakes = batch_owned,
        .resume_export = resume_export_owned,
    });
}

/// The bound-fetch resume engine (the streaming substrate,
/// `docs/architecture/routing-and-ingress.md`; handler surface in
/// `docs/handler-shape.md` §5.5). Sibling of `resumeContinuation`:
/// an upstream chunk for a fetch issued from a held chain wakes the
/// chain via its module's `onFetchChunk` named export.
///
/// Handles only chunks arriving on a chain still in
/// `parked_continuations` (first-chunk-on-cont). Subsequent chunks
/// on a chain that already transitioned cont→stream (returned
/// `stream({write})` on a prior chunk) are not yet wired to wake the
/// stream chain (the stream-resume engine needs a `.fetch_chunk`
/// activation source); lookups that find the entity outside
/// `parked_continuations` fall through to the unbound
/// `fireFetchEventActivation` path with a warning.
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
        // Bound chunks arriving for a chain that's
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
    // Snapshot for log records: `cont_path` borrows into desc.cont's
    // backing memory, which a write-repark (`proposeAndParkContResume`
    // `.repark` arm) or an in-place cont refresh FREES before the
    // post-propose captureLogWithId sites run — the same UAF class
    // `resumeIntoStream`'s `cont_path_for_log` snapshot guards (a
    // surfaced log record carried freed bytes as its path).
    const cont_path_log = allocator.dupe(u8, cont_path) catch &.{};
    defer if (cont_path_log.len > 0) allocator.free(cont_path_log);
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
    // named export — `ev.name` if the bind specified `to:`, else the
    // conventional fetch export (onFetchResult / onFetchChunk /
    // onFetchDone, handler-shape.md §3). `request.ctx` (decisions.md §4.14) =
    // the fetch's own ctx (`ev.ctx_json`) if it carried one, else the held
    // chain's `next({ctx})` memory (`c.ctx_json`) — one rule
    // on both transports. Chunk bytes come from the activation slot.
    const ctx_src = worker_streaming.fetchResumeCtx(ev.ctx_json, c.ctx_json);
    const body = worker_streaming.synthCtxBody(allocator, ctx_src) catch return;
    defer allocator.free(body);
    // First-class resume target (decisions.md §4.5) — no synthetic
    // `?fn=` query; the path stays the real module path.
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

    // A bound-fetch chunk handler
    // (`onFetchChunk`) opens the streamed response via `stream.start()` /
    // `stream.write()` + `next()`. Wire the chunk accumulator so
    // `finishResponse`'s bridge produces the `RunOutcome.stream` that the
    // `.stream` arm (`resumeIntoStream`) turns into the cont→stream
    // transition. (The ambient head is captured by runModule when
    // `stream_started`.)
    var stream_chunks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stream_chunks.items) |ch| allocator.free(ch);
        stream_chunks.deinit(allocator);
    }

    // blob-storage-plan P2 (+ handler-shape §5.3; `docs/architecture/routing-and-ingress.md`): fetches
    // issued FROM a bound-fetch resume (`on.fetch` chained from a
    // chunk handler, `blob.seal`'s PUT).
    // Flushed by `flushResumeFetches` on the READ-ONLY success arms
    // only (post-commit, so no effect escapes early — L4); writing
    // resumes that also fetched drop them loudly until the
    // commit-gated Cmd path covers resumes too.
    var pending_fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (pending_fetches.items) |*pf| pf.deinit(allocator);
        pending_fetches.deinit(allocator);
    }
    // A chunk handler that re-arms `after.kv`/`after.ms` (e.g. an
    // `onFetchResult` that arms a timer deadline before `next()`) —
    // installed onto the chain's StreamWakes at the repark seam. Was a
    // null accumulator, so the arm silently dropped and the chain 504'd.
    var pending_wakes: std.ArrayListUnmanaged(globals.PendingWakeReg) = .empty;
    defer {
        for (pending_wakes.items) |*pw| pw.deinit(allocator);
        pending_wakes.deinit(allocator);
    }

    // The fetch result is this activation's Msg (an input — L3), so it must be
    // taped or the fetch_chunk can't be replayed. The capture sites below feed
    // this to `worker_mod.captureFetchChunkTapes` (which records it inline for
    // ≤16 KB).
    const fetch_ev: worker_mod.FetchEvent = .{
        .fetch_id = ev.fetch_id,
        .seq = ev.seq,
        .byte_offset = ev.byte_offset,
        .bytes = ev.bytes,
        .headers = ev.fetch_headers orelse "",
        .final = ev.final,
        .terminal_status = ev.terminal_status,
        .terminal_ok = ev.terminal_ok,
        .body_truncated = ev.body_truncated,
        .export_name = fn_name, // record the resolved export ({on} / onFetch*)
        .static_serve = ev.static_serve,
        .content_hash = if (ev.content_hash) |*h| h[0..] else "",
    };
    const req: Request = .{
        .arena_mode = worker_mod.arenaModeFor(worker, inst.id, tc.snap.deployment_id, cont_path),
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
        .trace = .{ .readset = &readset, .request_id = request_id, .correlation_id = correlation_id },
        .plan = .{ .limiter = &worker.limiter, .storage = inst.storage, .plan_rate = tc.slot.effectivePlan().rate, .plan_gen = tc.slot.plan_gen.load(.acquire), .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = inst.platform, .platform_caps = worker.adminPlatformCaps(inst) },
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
            .pending_wakes = &pending_wakes,
            .pending_stream_chunks = &stream_chunks,
            .pending_fetches = &pending_fetches,
        },
    };

    // Read sid/sess from the entity's components BEFORE dispatch
    // so the error path can resolve the held socket cleanly.
    // resumeContinuation reads them from caller-supplied locals;
    // here we pull from the parked_continuations collection.
    const sid_ptr = server.reg.get(ent, &worker.parked_continuations, h2.StreamId) catch return;
    const sess_ptr = server.reg.get(ent, &worker.parked_continuations, h2.Session) catch return;
    const sid = sid_ptr.*;
    const sess = sess_ptr.*;

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    var oc = worker_mod.runResume(worker, inst, tc, bc, txn, &ws, req, &budget, cont_path) catch {
        txn.rollback() catch {};
        txn_done = true;
        resolveParked(worker, ent, sid, sess, resumeErrStatus(worker), "bound-fetch handler error\n") catch {};
        captureLogWithId(worker, tenant_id, request_id, "POST", cont_path_log, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, worker_mod.captureFetchChunkTapes(worker, &readset, body, fetch_ev), correlation_id, &.{}, .fetch_chunk, 0);
        return;
    };

    const wrote = ws.ops.items.len > 0;

    finishContResume(worker, .{
        .site = "bound-fetch",
        .noun = "bound-fetch",
        .cancel_binds = true,
        .tape = .fetch,
    }, &oc, .{
        .ent = ent,
        .sid = sid,
        .sess = sess,
        .ws = &ws,
        .txn = txn,
        .tenant_id = tenant_id,
        .readset = &readset,
        .cont_path = cont_path,
        .cont_path_log = cont_path_log,
        .correlation_id = correlation_id,
        .request_id = request_id,
        .now_ns = now_ns,
        .deployment_id = tc.snap.deployment_id,
        .wrote = wrote,
        .txn_owned = &txn_owned,
        .txn_done = &txn_done,
        .act = .fetch_chunk,
        .pending_fetches = &pending_fetches,
        .pending_wakes = &pending_wakes,
        .tape_body = body,
        .tape_ev = fetch_ev,
    });
}


/// §6.4 Part B: an `http.send` bound to a parked continuation
/// completed — resume the held stream with the result as the outcome
/// (the call's success/failure IS the resume input). Returns true iff
/// a parked continuation on THIS worker matched (caller then deletes
/// the `c/` receipt); false → not here (caller falls through to the
/// normal callback path). MUST be called
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
    // O(1) map lookup via the worker-local
    // `bound_send_entities` registry, populated alongside the
    // NodeState owner map at the cont_bound_sched_id scan sites.
    // The routing model guarantees the cont is on this worker if
    // it's anywhere; the map gives the entity directly without
    // scanning every parked cont.
    //
    // Lookup miss → fall back to the linear scan over
    // `parked_continuations` as a safety net (registry stale /
    // wrong / lost).
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
                    resumeContinuation(worker, ent, sid.*, sess.*, outcome_json, true, false) catch |err| {
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
    // etc.) and the scan is the safety net for the held-state
    // design (`docs/architecture/effects-and-handlers.md`).
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
        resumeContinuation(worker, ent, sid, sess, outcome_json, true, false) catch |err| {
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

/// Drain `pending_bound_resumes` — the deferred §6.4
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

    // Collect work first — resume/resolve mutate the collection, so
    // snapshot (ent,sid,sess) while the slice is stable. Deadline takes
    // priority over a due timer (a mandatory §6.4 timeout terminates,
    // it doesn't fire onWake).
    const Pending = struct { ent: rove.Entity, sid: h2.StreamId, sess: h2.Session };
    var expired: std.ArrayListUnmanaged(Pending) = .empty;
    defer expired.deinit(allocator);
    var wake_due: std.ArrayListUnmanaged(Pending) = .empty;
    defer wake_due.deinit(allocator);
    {
        const sids = worker.parked_continuations.column(h2.StreamId);
        const sesss = worker.parked_continuations.column(h2.Session);
        const descs = worker.parked_continuations.column(components_mod.ContDescriptor);
        const wakes = worker.parked_continuations.column(components_mod.StreamWakes);
        for (ents, sids, sesss, descs, wakes) |ent, sid, sess, desc, *sw| {
            if (now_ns >= desc.deadline_ns) {
                try expired.append(allocator, .{ .ent = ent, .sid = sid, .sess = sess });
                continue;
            }
            // Two `on.*` wake sources fan into one `onWake` fire:
            //   - `on.timer`: `next_wake_ns` elapsed. Advance it
            //     (drift-on-fire, matching `serviceParkedStreams`) so it
            //     re-fires next interval, and stamp `timer_fired_ns` so
            //     the resume's drain surfaces the `{kind:"timer"}` entry;
            //     the StreamWakes component rides the `next()` re-park,
            //     so recurrence needs no re-arming.
            //   - `on.kv`: `drainKvWakeInbox` stamped a §8.4-gated arm
            //     fired; `anyFired()` is the "go look" signal
            //     (`resumeContinuation` drains it).
            // One resume per tick even if both are due — the handler's
            // `onWake` re-reads kv state regardless of the trigger.
            const timer_due = sw.interval_ms > 0 and now_ns >= sw.next_wake_ns;
            if (timer_due) {
                sw.timer_fired_ns = now_ns;
                sw.next_wake_ns = now_ns + sw.interval_ms * std.time.ns_per_ms;
            }
            if (timer_due or sw.anyFired()) {
                try wake_due.append(allocator, .{ .ent = ent, .sid = sid, .sess = sess });
            }
        }
    }

    for (expired.items) |e| {
        resumeContinuation(worker, e.ent, e.sid, e.sess, "{\"ok\":false,\"error\":\"deadline\"}", false, false) catch |err| {
            std.log.warn(
                "rove-js continuation: deadline resume failed ({s}); hard 504",
                .{@errorName(err)},
            );
            resolveParked(worker, e.ent, e.sid, e.sess, 504, "hold deadline exceeded\n") catch {};
        };
    }

    for (wake_due.items) |e| {
        // A held WS chain ships its onWake frames over the socket — route
        // to the ws-aware resume (shipWsFrames), not the HTTP resolveParked.
        if (worker_ws.wsConnForChain(worker, e.ent)) |conn_ent| {
            worker_ws.resumeWakeChainWs(worker, e.ent, conn_ent);
            continue;
        }
        // `on.*` connection wake (no callee outcome). Best-effort: on
        // failure the entity stays parked and the next tick / interval
        // retries; a thrown/erroring onWake resolves via
        // resumeContinuation's own error handling. resumeContinuation
        // drains the kv ring so a consumed match doesn't re-fire.
        resumeContinuation(worker, e.ent, e.sid, e.sess, "", true, true) catch |err| {
            std.log.warn("rove-js continuation: on.* wake resume failed ({s})", .{@errorName(err)});
        };
    }
}

/// The park-on-durability drain (readset replication,
/// `docs/architecture/effects-and-handlers.md`).
///
/// Walks `worker.body_pending`, polling each parked entity's
/// submission against the process-global blob coordinator's HWM
/// (`node.blob_coordinator.durableSeq(worker_id)` — the streaming substrate,
/// `docs/architecture/routing-and-ingress.md`). Once the seq is durable we materialize the wire `BodyRef` via
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
    queue_id: blob_mod.coordinator.QueueId,
    seq: u64,
    what: []const u8,
    tenant: []const u8,
) DurableBody {
    // Count semantics: durableSeq is the exclusive HWM (lowest
    // not-yet-durable seq), so `seq < durableSeq` ⇒ resolved.
    if (seq >= coord.durableSeq(queue_id)) return .not_yet;
    const ref = coord.bodyRef(queue_id, seq) catch |err| {
        std.log.warn(
            "rove-js {s}: coord.bodyRef tenant={s} seq={d}: {s}",
            .{ what, tenant, seq, @errorName(err) },
        );
        _ = coord.release(queue_id, seq);
        return .failed;
    };
    _ = coord.release(queue_id, seq);
    return .{ .ready = .{ .batch_id = ref.batch_id, .offset = ref.offset, .len = ref.len } };
}

pub fn drainBodyPending(worker: anytype) !void {
    const server = worker.h2;
    const coord = worker.node.blob_coord.coordinator orelse return;

    const ents = worker.body_pending.entitySlice();
    const waits = worker.body_pending.column(BodyDurabilityWait);

    // Snapshot indices first — `reg.move` mutates `body_pending`,
    // so iterate by index over the snapshotted entitySlice and
    // skip empty slots after the move.
    var i: usize = 0;
    while (i < ents.len) : (i += 1) {
        const ent = ents[i];
        const wait = &waits[i];
        // If already resolved/failed, skip — the entity's move back to
        // request_out is deferred until flush(), so a second drain pass
        // in the same tick would otherwise re-poll (and double-move).
        if (wait.status != .fresh) continue;

        // Durability gate (shared with drainFetchPendingDurability) —
        // poll the coord HWM, materialize + release on terminal.
        switch (pollDurableBodyRef(coord, wait.queue_id, wait.worker_seq, "body-gate", wait.tenant_id)) {
            .not_yet => continue,
            // Body never became durable: mark failed. The dispatch
            // body-gate sees `.failed` and returns 503 (it does NOT
            // re-submit, which keying off the NO_BATCH body_ref would).
            .failed => wait.status = .failed,
            // Stamp the wire BodyRef. `batch_id` is the
            // coord's globally-unique pool batch_id; the S3 key is
            // `{key_prefix_base}_pool/{batch_id:0>20}`. The dispatcher
            // serializes it into the readset on resume.
            .ready => |ref| {
                wait.body_ref = ref;
                wait.status = .resolved;
            },
        }
        try server.reg.move(ent, &worker.body_pending, &server.request_out);
    }
}

/// The fetch-park-on-durability drain (readset replication,
/// `docs/architecture/effects-and-handlers.md`).
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
    const coord = worker.node.blob_coord.coordinator orelse return;
    var i: usize = 0;
    while (i < worker.fetch_pending_durability.items.len) {
        const pe = &worker.fetch_pending_durability.items[i];
        // Durability gate (shared with drainBodyPending) — poll the
        // coord HWM, materialize + release on terminal. The helper
        // releases the coord copy before we swapRemove `pe`, so no
        // pre-capture of (worker_id, seq) is needed.
        switch (pollDurableBodyRef(coord, pe.queue_id, pe.worker_seq, "fetch-gate", pe.tenant_id_view)) {
            // Not durable yet — advance; the swapRemove cases below
            // stay at `i` so the swapped-in element is examined next.
            .not_yet => i += 1,
            // Drop the parked event. Better surface would be to fire
            // with a transport-error terminal; for now this keeps the
            // "skip on body-gate failure" posture.
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

/// streaming-handlers-plan §4.5: register a batch's kv-writes as
/// commit-gated wake intents. Extracts `(key, op)` from each put /
/// delete in the writeset (key bytes dup'd so the caller can
/// release the writeset bytes), parks them on a `ParkedUnit` keyed
/// by the propose `seq`. `drainRaftPending` fires them at commit
/// via `firePendingKvWakes`. No-op when the writeset has no ops.
pub fn parkKvWakes(
    worker: anytype,
    seq: u64,
    tenant_id: []const u8,
    writeset: *const kv_mod.WriteSet,
    extra_cmds: effect_mod.cmd.BufferedCmds,
) !void {
    // `extra_cmds` carries the batch's `http.fetch` Cmds (transferred
    // from the worker dispatch's `batch_pending_fetches` accumulator).
    // The Cmds ride alongside the kv_wake_broadcast Cmds on this unit;
    // `interpretCmd` submits each PendingFetch to the engine on
    // commit, so the fetch can't escape before its durable marker
    // commits. `extra_cmds`
    // is consumed unconditionally — caller MUST treat its copy as
    // moved-from after the call (set to `.{}`).
    if (writeset.ops.items.len == 0 and extra_cmds.items.items.len == 0) {
        // Nothing to park. Ensure extra_cmds is freed (already
        // empty if caller never populated it).
        var ec = extra_cmds;
        ec.deinit(worker.allocator);
        return;
    }
    const allocator = worker.allocator;
    // Take ownership of the extra_cmds as the unit's base; append
    // kv_wake_broadcast Cmds for the writeset on top.
    var cmds: effect_mod.cmd.BufferedCmds = extra_cmds;
    errdefer cmds.deinit(allocator);
    try cmds.items.ensureUnusedCapacity(allocator, writeset.ops.items.len);
    for (writeset.ops.items) |op| switch (op) {
        .put => |p| {
            const k = try allocator.dupe(u8, p.key);
            cmds.items.appendAssumeCapacity(.{
                .kv_wake_broadcast = .{ .key = k, .op = 'p' },
            });
        },
        .delete => |d| {
            const k = try allocator.dupe(u8, d.key);
            cmds.items.appendAssumeCapacity(.{
                .kv_wake_broadcast = .{ .key = k, .op = 'd' },
            });
        },
    };
    // Transfer ownership of `cmds` into the unit; clear local
    // immediately to invalidate the earlier errdefer.
    var unit: ParkedUnit = .{
        .seq = seq,
        .deadline_ns = @intCast(std.time.nanoTimestamp() +
            @as(i128, @intCast(worker.commit_wait_timeout_ns))),
        .buffered = cmds,
    };
    cmds = .{};
    errdefer ParkedUnit.deinit(allocator, (&unit)[0..1]);
    unit.tenant_id = try allocator.dupe(u8, tenant_id);
    const ent = try worker.h2.reg.create(&worker.parked_units);
    errdefer worker.h2.reg.destroy(ent) catch {};
    try worker.h2.reg.set(ent, &worker.parked_units, ParkedUnit, unit);
    unit = .{};
}

/// Leadership-loss drain. Called from the dispatch loop on a
/// leader→follower transition. Rolls back every pending TrackedTxn
/// (kvexp recipe §2) and downgrades every `raft_pending` entry to
/// 503. The follower can't honor those raft seqs — the new leader
/// will re-propose anything that was actually durable.
pub fn drainOnLeadershipLoss(worker: anytype) !void {
    const server = worker.h2;
    const allocator = worker.allocator;

    // Rollback every pending TrackedTxn. Each lives at a unique seq;
    // each is in its own per-tenant chain (kvexp dispatch lease
    // guarantees one in-flight at a time). Rollback order doesn't
    // matter — different tenants are independent chains and within a
    // tenant we have exactly one entry. SharedTxnPool's
    // drainAll wraps the rollback-loop + clear (best-effort on
    // rollback errors, matching the leadership-loss-is-recoverable
    // posture).
    worker.pending_txns.drainAll(allocator);

    // Discard parked units — their seqs won't commit on this now-
    // follower; the buffered emits MUST NOT fire (the new leader
    // re-fires anything that was actually durable). Destroy every
    // entity in the parked_units collection; `reg.destroy` (deferred)
    // fires `ParkedUnit.deinit` structurally on each — rollback any
    // attached txn, free owned slices.
    {
        const slice = worker.parked_units.entitySlice();
        // Copy to a stable buffer because destroy is deferred and
        // entitySlice reflects the current pre-flush state.
        var buf: [256]rove.Entity = undefined;
        var idx: usize = 0;
        while (idx < slice.len) {
            const n = @min(slice.len - idx, buf.len);
            std.mem.copyForwards(rove.Entity, buf[0..n], slice[idx .. idx + n]);
            for (buf[0..n]) |ent| {
                server.reg.destroy(ent) catch |err| std.log.warn(
                    "drainOnLeadershipLoss: parked_units destroy: {s}",
                    .{@errorName(err)},
                );
            }
            idx += n;
        }
    }

    // Downgrade every entry across the three raft-pending
    // siblings to 503 + move to response_in.
    try drainLeadershipLossColl(worker, server, allocator, &worker.raft_pending_response);
    try drainLeadershipLossColl(worker, server, allocator, &worker.raft_pending_cont);
    try drainLeadershipLossColl(worker, server, allocator, &worker.raft_pending_stream);
}

/// Walk one raft-pending sibling, 503 every entry, move to
/// response_in. No per-kind cleanup arg: all cont and stream
/// state lives on the entity's components and deinits structurally
/// when `cleanupResponses` destroys the entity (no side-tables to
/// free per kind).
fn drainLeadershipLossColl(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    coll: anytype,
) !void {
    const entities = coll.entitySlice();
    const resp_bodies = coll.column(h2.RespBody);
    var i: usize = entities.len;
    while (i > 0) {
        i -= 1;
        const ent = entities[i];
        const resp_body = resp_bodies[i];
        const old_body_ptr: ?[*]u8 = resp_body.data;
        const old_body_len: u32 = resp_body.len;
        try respb.overwrite503InPending(worker, coll, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);
        try server.reg.move(ent, coll, &server.response_in);
    }
}

/// Destroy entities sitting in `response_out` (h2 has finished
/// flushing them to the wire). Same pattern as the echo example's
/// `cleanupResponses`.
///
/// Also reap streaming-chain state. An entity in
/// `response_out` that still has a stream cell (in either the
/// active or draining map) is a **client-disconnect** —
/// h2's `serverStreamClose` routed it here without our normal
/// drain-to-stream_close_in path firing (which would have freed
/// the cell in `serviceParkedStreams`). Fire one last handler
/// activation (§4.4 `activation: { kind: "disconnect" }`) so the
/// customer's cleanup runs, then free the cell, then destroy the
/// entity.
pub fn cleanupResponses(worker: anytype) !void {
    const server = worker.h2;
    const entities = server.response_out.entitySlice();
    const chains = server.response_out.column(components_mod.StreamChain);
    for (entities, chains) |ent, chain| {
        // An entity in response_out with a populated
        // StreamChain.module_path is a client-disconnect on a held
        // stream — fire the disconnect activation before destroy.
        if (chain.module_path.len > 0) {
            worker_fire.fireDisconnectActivation(worker, ent);
        }
        // The streaming substrate (`docs/architecture/routing-and-ingress.md`):
        // cancel any bound fetches still associated with this entity. The held
        // client is gone; upstream chunks would land on a destroyed
        // entity. cancel_fetch is cooperative — the FetchEngine
        // tears down the libcurl handle; the unregister drops the
        // registry entry. Walk + collect first so we don't mutate
        // the map mid-iteration.
        scanAndCancelBoundFetches(worker, ent);
        try server.reg.destroy(ent);
    }
}

/// Walk the worker's `bound_fetch_entities` map, cancel + unregister
/// every entry pointing at `ent`. Called from the disconnect cleanup
/// path, from `resumeBoundFetchChain` / `resumeBoundFetchStream`'s
/// `.terminal` arms (auto-cancel siblings when the chain itself
/// terminates), and from any future "held entity destroyed" site.
/// Idempotent — repeated calls with the same entity see an empty
/// match set.
pub fn scanAndCancelBoundFetches(worker: anytype, ent: rove.Entity) void {
    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doomed.deinit(worker.allocator);
    var it = worker.spools.bound_fetch_entities.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.eql(ent)) {
            doomed.append(worker.allocator, entry.key_ptr.*) catch break;
        }
    }
    for (doomed.items) |fetch_id| {
        if (worker.node.fetch_engine) |engine| engine.cancel(fetch_id);
        // The chunk spool (`docs/architecture/routing-and-ingress.md`): drop any spooled chunks
        // for this fetch — the held client is gone (disconnect) or the
        // chain is terminating, so they'll never be consumed. Done
        // BEFORE `unregisterBoundFetch`: `fetch_id` aliases the
        // bound_fetch_entities key that `unregisterBoundFetch` frees,
        // while `dropSpool` frees the (separate) spool-map key — so
        // `fetch_id` must still be valid here.
        worker_streaming.dropSpool(worker, fetch_id);
        // Same for any relay backlog (the CAS→connection relay,
        // `docs/architecture/routing-and-ingress.md`) — the engine
        // cancel above already unsticks a window-paused transfer, so
        // no second cancel here.
        worker_streaming.dropRelayBacklog(worker, fetch_id, false);
        // unregisterBoundFetch frees the key via fetchRemove. The
        // slice in `doomed` borrows the same bytes — read fetch_id
        // BEFORE the unregister call.
        worker.unregisterBoundFetch(fetch_id);
    }
}

// ── Inbound-chunk resume engine (`docs/architecture/effects-and-handlers.md`) ──

/// Per-tick pump for streaming inbound bodies. For each live job:
/// janitor stale entities (response shipped / connection died — the
/// existing chain-teardown paths run first; this only reclaims the job),
/// repay the prior fire's flow-control window once the entity is parked
/// again, and fire the next staged chunk into the held chain. The first
/// fire (the `onChunk` probe) is `dispatchOnce`'s — the pump only ever
/// resumes `parked_continuations` entities, so ordering and
/// read-your-writes are collection membership: chunk K+1 cannot fire
/// until chunk K's activation (and, if it wrote, its raft commit)
/// returned the entity to the parked collection.
/// Release every in-flight coordinator park a job holds (kill /
/// teardown paths — nobody will poll them to completion, and the
/// coordinator retains a RAM copy per submission until released).
pub fn releaseInboundChunkParks(worker: anytype, job: anytype) void {
    const coord = worker.node.blob_coord.coordinator orelse return;
    for (job.prepared.items) |*pf| {
        if (pf.coord == .pending) {
            _ = coord.release(pf.wid, pf.seq);
            pf.coord = .failed;
        }
    }
}

/// Resolve a held chunk chain with a defined 5xx and stop feeding it —
/// the pump's failure exit (durability gate down / submit failed). The
/// entity goes through `resolveParked` (the standard parked-chain
/// resolution); the killed job is reclaimed by the janitor once the
/// entity is stale.
fn failInboundChunkChain(worker: anytype, ent: rove.Entity, job: anytype, msg: []const u8) void {
    const server = worker.h2;
    releaseInboundChunkParks(worker, job);
    job.kill();
    const sid_ptr = server.reg.get(ent, &worker.parked_continuations, h2.StreamId) catch return;
    const sess_ptr = server.reg.get(ent, &worker.parked_continuations, h2.Session) catch return;
    resolveParked(worker, ent, sid_ptr.*, sess_ptr.*, 503, msg) catch {};
}

/// Advance every prepared fire's durability park (the chunk-tape gate,
/// the resume-fire twin of the dispatch body-gate): submit every
/// `.unsubmitted` payload to the blob coordinator IMMEDIATELY — the
/// whole queue pipelines, so S3 round-trips amortize across fires
/// instead of serializing (the fetch-chunk spool posture) — and poll
/// `.pending` ones to `.resolved` (materialized wire BodyRef) or
/// `.failed`. ≤ inline-threshold payloads skip the park (`.inline_ok`:
/// the raft entry's fsync is the durability substrate). Returns false
/// if the head is terminally failed (caller fails the chain).
fn advanceInboundChunkGate(worker: anytype, job: anytype) bool {
    if (job.prepared.items.len == 0) return true;
    const coord = worker.node.blob_coord.coordinator orelse {
        // No coordinator: only inline-sized fires can proceed; a
        // > threshold head is a hard gate failure.
        const h = job.head() orelse return true;
        return h.coord == .inline_ok;
    };
    for (job.prepared.items) |*pf| {
        switch (pf.coord) {
            .unsubmitted => {
                const wid = worker.coord_queue_id;
                if (coord.submit(wid, pf.bytes)) |seq| {
                    pf.wid = wid;
                    pf.seq = seq;
                    pf.coord = .pending;
                } else |err| {
                    std.log.warn("rove-js inbound-chunk: coord.submit bytes={d}: {s}", .{ pf.bytes.len, @errorName(err) });
                    pf.coord = .failed;
                }
            },
            .pending => switch (pollDurableBodyRef(coord, pf.wid, pf.seq, "chunk-gate", "")) {
                .not_yet => {},
                .failed => pf.coord = .failed,
                .ready => |ref| {
                    pf.batch_id = ref.batch_id;
                    pf.ref_offset = ref.offset;
                    pf.ref_len = ref.len;
                    pf.coord = .resolved;
                },
            },
            .inline_ok, .resolved, .failed => {},
        }
    }
    const h = job.head() orelse return true;
    return h.coord != .failed;
}

pub fn pumpInboundChunks(worker: anytype) void {
    const server = worker.h2;
    var done: std.ArrayListUnmanaged(rove.Entity) = .empty;
    defer done.deinit(worker.allocator);
    var it = worker.inbound_chunk_jobs.iterator();
    while (it.next()) |entry| {
        const ent = entry.key_ptr.*;
        const job = entry.value_ptr.*;
        if (server.reg.isStale(ent)) {
            // The request finished (terminal shipped + cleaned) or the
            // connection died (disconnect teardown ran). Either way the
            // chain's own machinery resolved the entity; reclaim the
            // job (releasing any in-flight durability parks).
            releaseInboundChunkParks(worker, job);
            job.kill();
            done.append(worker.allocator, ent) catch {};
            continue;
        }
        if (job.dead or job.classic_fallback) continue; // 413'd / classic re-walk owns it
        // Prepare + advance durability EVERY tick regardless of the
        // entity's state — submissions pipeline while earlier fires
        // execute (including before/during the dispatchOnce first
        // fire), so the gate's S3 round-trip is off the serial path.
        _ = job.prepareFires();
        if (!advanceInboundChunkGate(worker, job)) {
            if (server.reg.isInCollection(ent, &worker.parked_continuations)) {
                failInboundChunkChain(worker, ent, job, "chunk durability gate failed\n");
            } else {
                // First fire not parked yet — let the dispatch walk
                // surface the failure; mark dead so nothing fires.
                releaseInboundChunkParks(worker, job);
                job.kill();
            }
            continue;
        }
        if (!job.first_fired) continue; // dispatchOnce owns the probe fire
        if (!server.reg.isInCollection(ent, &worker.parked_continuations)) continue; // fire in flight
        // The prior fire fully resolved (commit included) — repay its
        // window so the client can send the next stretch.
        job.repayResolved();
        if (job.final_fired) {
            // Upload complete; the chain lives on under the ordinary
            // continuation machinery (wakes, deadline). Detach early —
            // h2's sink reference releases at stream close.
            done.append(worker.allocator, ent) catch {};
            continue;
        }
        if (job.aborted) {
            // Client died mid-upload while the chain is parked. The h2
            // disconnect path fires `onDisconnect` for held chains; the
            // job just stops feeding. Reclaim on the stale sweep above.
            continue;
        }
        const h = job.head() orelse continue; // nothing prepared yet
        if (h.coord != .inline_ok and h.coord != .resolved) continue; // durability pending
        if (resumeInboundChunk(worker, ent, job)) job.fireDispatched();
    }
    for (done.items) |ent| {
        if (worker.inbound_chunk_jobs.fetchRemove(ent)) |kv| kv.value.unref();
    }
}

/// Resume a held chain with the next inbound body chunk — the
/// `.inbound_chunk` sibling of `resumeBoundFetchChain` (same shape:
/// parked entity + raw chunk bytes + named-export dispatch + the
/// `finishResponse` stream bridge). The job's head fire carries the
/// payload + its durability park; the per-fire fields come from the
/// job's dispatch-side bookkeeping.
/// Returns true iff the activation ran (the caller advances the job's
/// fire bookkeeping only then); a pre-dispatch failure — transient txn
/// conflict, deployment resolve — leaves the staged fire unconsumed
/// for the next tick's retry.
fn resumeInboundChunk(worker: anytype, ent: rove.Entity, job: anytype) bool {
    const allocator = worker.allocator;
    const server = worker.h2;
    if (!server.reg.isInCollection(ent, &worker.parked_continuations)) return false; // resolve-once
    const desc = server.reg.get(ent, &worker.parked_continuations, components_mod.ContDescriptor) catch return false;
    const chain = server.reg.get(ent, &worker.parked_continuations, components_mod.ChainContext) catch return false;
    const c = desc.cont orelse return false;
    const tenant_id = chain.tenant_id;
    const correlation_id = chain.correlation_id;
    const cont_path = c.path;
    const cont_ctx_json = c.ctx_json;
    // Snapshot for log records: `cont_path` borrows into desc.cont's
    // backing memory, which a write-repark (`proposeAndParkContResume`
    // `.repark` arm) or an in-place cont refresh FREES before the
    // post-propose captureLogWithId sites run — the same UAF class
    // `resumeIntoStream`'s `cont_path_for_log` snapshot guards (a
    // surfaced log record carried freed bytes as its path).
    const cont_path_log = allocator.dupe(u8, cont_path) catch &.{};
    defer if (cont_path_log.len > 0) allocator.free(cont_path_log);
    const path = cont_path;
    var dep = resolveDeployment(worker, allocator, tenant_id, path) catch |err| {
        std.log.warn(
            "rove-js inbound-chunk resume: resolveDeployment tenant={s} module={s}: {s}",
            .{ tenant_id, path, @errorName(err) },
        );
        return false;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    const head_fire = job.head() orelse return false;
    const chunk_bytes: []const u8 = head_fire.bytes;
    const spath = std.fmt.allocPrint(allocator, "/{s}", .{path}) catch return false;
    defer allocator.free(spath);

    const txn = allocator.create(kv_mod.KvStore.TrackedTxn) catch return false;
    var txn_owned = true;
    defer if (txn_owned) allocator.destroy(txn);
    txn.* = inst.kv.beginTrackedImmediate() catch |berr| {
        // Transient (e.g. chain-head conflict with a just-committed
        // hop): the staged fire stays unconsumed; next tick retries.
        std.log.debug("rove-js inbound-chunk: beginTracked deferred: {s}", .{@errorName(berr)});
        return false;
    };
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

    const fetches_pending: u32 = blk: {
        const cnt = server.reg.get(ent, &worker.parked_continuations, components_mod.BoundFetchCount) catch break :blk 0;
        break :blk cnt.pending;
    };

    // Chunk-tape: record this fire's input bytes on the readset's
    // trigger_payload channel — the same two-path rule as the classic
    // inbound body-gate. ≤ inline threshold: bytes ride inline (the
    // raft entry's fsync is durability). Larger: the pump already
    // parked the payload on the blob coordinator and materialized the
    // wire BodyRef (head_fire.batch_id/...); record the pointer. The
    // readset rides the raft entry (follower replay) AND serializes
    // into the LogRecord tapes below (dashboard replay).
    // The chunk payload IS this activation's Msg (L3) — its
    // trigger_payload entry is the chunk-tape record (gap 2.4), never
    // read-elided; `request.body` here is the eager Uint8Array, not
    // the recording getter, so the flag is set structurally.
    if (chunk_bytes.len > 0) readset.body_read = true;
    if (chunk_bytes.len > 0 and chunk_bytes.len <= worker_mod.REQUEST_BODY_CAP) {
        const inline_ref: bodies_mod.BodyRef = .{
            .batch_id = bodies_mod.NO_BATCH,
            .offset = 0,
            .len = @intCast(chunk_bytes.len),
        };
        readset.trigger_payload.appendTriggerPayload(inline_ref, chunk_bytes) catch |err| {
            std.log.warn("rove-js inbound-chunk: trigger_payload append (inline): {s}", .{@errorName(err)});
        };
    } else if (chunk_bytes.len > 0) {
        readset.trigger_payload.appendTriggerPayload(.{
            .batch_id = head_fire.batch_id,
            .offset = head_fire.ref_offset,
            .len = head_fire.ref_len,
        }, "") catch |err| {
            std.log.warn("rove-js inbound-chunk: trigger_payload append (ref): {s}", .{@errorName(err)});
        };
    }

    // A chunk handler may stream (`stream.start`/`stream.write` +
    // `next()` — the finishResponse bridge) and may fetch
    // (`on.fetch` per chunk, handler-shape §5.3).
    var stream_chunks: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stream_chunks.items) |ch| allocator.free(ch);
        stream_chunks.deinit(allocator);
    }
    var pending_fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (pending_fetches.items) |*pf| pf.deinit(allocator);
        pending_fetches.deinit(allocator);
    }
    // An inbound-chunk handler that re-arms `after.kv`/`after.ms` before
    // `next()` — installed onto the chain's StreamWakes at the repark
    // seam. Was a null accumulator, so the arm silently dropped.
    var pending_wakes: std.ArrayListUnmanaged(globals.PendingWakeReg) = .empty;
    defer {
        for (pending_wakes.items) |*pw| pw.deinit(allocator);
        pending_wakes.deinit(allocator);
    }

    // The inbound request's headers ride the held entity (ReqHeaders is
    // in the base Row) — every chunk activation sees the same
    // `request.headers` the first one did (handler-shape §5.3 reads
    // them per chunk).
    const req_headers: ?h2.ReqHeaders = blk: {
        const p = server.reg.get(ent, &worker.parked_continuations, h2.ReqHeaders) catch break :blk null;
        break :blk p.*;
    };

    const req: Request = .{
        .arena_mode = worker_mod.arenaModeFor(worker, inst.id, tc.snap.deployment_id, cont_path),
        .method = "POST",
        .path = spath,
        .body = chunk_bytes,
        .query = null,
        .headers = req_headers,
        .activation = .{ .inbound_chunk = .{
            .seq = job.next_seq,
            .byte_offset = job.fired_offset,
            .done = head_fire.done,
            .ctx_json = if (cont_ctx_json.len > 0) cont_ctx_json else null,
        } },
        .activation_entity = ent,
        .activation_fetches_pending = fetches_pending,
        .trace = .{ .readset = &readset, .request_id = request_id, .correlation_id = correlation_id },
        .plan = .{ .limiter = &worker.limiter, .storage = inst.storage, .plan_rate = tc.slot.effectivePlan().rate, .plan_gen = tc.slot.plan_gen.load(.acquire), .blob_cfg = &worker.node.blob_backend_cfg },
        .admin = .{ .platform = inst.platform, .platform_caps = worker.adminPlatformCaps(inst) },
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
            .pending_wakes = &pending_wakes,
            .pending_stream_chunks = &stream_chunks,
            .pending_fetches = &pending_fetches,
        },
    };

    const sid_ptr = server.reg.get(ent, &worker.parked_continuations, h2.StreamId) catch return false;
    const sess_ptr = server.reg.get(ent, &worker.parked_continuations, h2.Session) catch return false;
    const sid = sid_ptr.*;
    const sess = sess_ptr.*;

    var budget = dispatcher_mod.Budget.fromNow(dispatcher_mod.Budget.default_duration_ns);
    var oc = worker_mod.runResume(worker, inst, tc, bc, txn, &ws, req, &budget, cont_path) catch {
        txn.rollback() catch {};
        txn_done = true;
        resolveParked(worker, ent, sid, sess, resumeErrStatus(worker), "inbound-chunk handler error\n") catch {};
        captureLogWithId(worker, tenant_id, request_id, "POST", cont_path_log, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, worker_mod.captureTapes(worker, &readset, chunk_bytes), correlation_id, &.{}, .inbound_chunk, 0);
        return true;
    };

    const wrote = ws.ops.items.len > 0;

    finishContResume(worker, .{
        .site = "inbound-chunk",
        .noun = "inbound-chunk",
        .cancel_binds = true,
        .tape = .chunk,
    }, &oc, .{
        .ent = ent,
        .sid = sid,
        .sess = sess,
        .ws = &ws,
        .txn = txn,
        .tenant_id = tenant_id,
        .readset = &readset,
        .cont_path = cont_path,
        .cont_path_log = cont_path_log,
        .correlation_id = correlation_id,
        .request_id = request_id,
        .now_ns = now_ns,
        .deployment_id = tc.snap.deployment_id,
        .wrote = wrote,
        .txn_owned = &txn_owned,
        .txn_done = &txn_done,
        .act = .inbound_chunk,
        .pending_fetches = &pending_fetches,
        .pending_wakes = &pending_wakes,
        .tape_bytes = chunk_bytes,
    });
    return true;
}
