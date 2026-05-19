//! http.send Option (b) increment 4b-i — the dedicated send-dispatch
//! component (docs/http-send-plan.md §15; task #8, FORK-5/FORK-6).
//!
//! ## Why a dedicated thread (not the worker tick)
//!
//! The per-worker request tick must never block on outbound libcurl
//! (`timeout_ms`, default 30s). 4c will fire due sends through a
//! dedicated `EasyPool`; the bookkeeping that decides *what* is due
//! lives here, on this one thread, off every request hot path. This
//! is the same shape as `deployment_loader.zig` — cheap mutex'd
//! enqueue from workers, one dedicated thread does the work — and the
//! schedule-server thread it supersedes.
//!
//! ## Leader-local, ephemeral (FORK-6, ratified 2026-05-18)
//!
//! The `InflightSet` is NOT a central/replicated/durable store — that
//! was the central `schedules.db`'s measured defect, eliminated by
//! the per-tenant `_send/owed/` markers (increments 1-3, the ~158k
//! write-isolation win, independent of this file). This set is an
//! in-memory index *derived* from those per-tenant durable markers:
//! one per node, populated/used only while this node is raft leader,
//! reconstructed on promotion via the boot-scan 3(b) settled
//! ([[project_owed_recovery_strategy]]). Followers keep nothing.
//! There is no node-wide replicated structure anywhere — only the
//! per-tenant `_send/owed/` (the durable truth) and this leader-local
//! cache rebuilt from it.
//!
//! ## This increment (4b-i): plumbing only, fully inert
//!
//! The component + its op queue + the dedicated thread that drains
//! arm/resolve ops into the `InflightSet`. Mirrors how
//! `send_inflight.zig` / `send_outbox.zig` were their phase's
//! additive increment 1. NOT here: the leader-gate + promotion
//! boot-scan (4b-iii), the worker commit-seam enqueue wiring (4b-ii),
//! the per-worker `EasyPool` fire + resolve (4c). Nothing fires.
//!
//! ## Concurrency
//!
//! Workers (many, at commit) call `enqueueArm`/`enqueueResolve` —
//! cheap: dupe + mutex'd append + wake, exactly `deployment_loader`'s
//! enqueue cost. The dedicated thread is the *sole* owner of the
//! `InflightSet` (drain applies ops; 4c's fire runs on this same
//! thread), so the set itself needs no lock — only the small handoff
//! queue does. That single leader-local queue mutex is the entire
//! shared-state surface (cf. the FORK-6 discussion).

const std = @import("std");
const kv_mod = @import("rove-kv");
const send_inflight = @import("send_inflight.zig");
const send_outbox = @import("send_outbox.zig");
const blob_curl = @import("rove-blob").curl;
const sched_thread = @import("rove-schedule-server").thread;

const InflightSet = send_inflight.InflightSet;
const Entry = send_inflight.Entry;
const FireOutcome = send_inflight.FireOutcome;
const OwedSend = send_outbox.OwedSend;

/// Fire-thread-pool size = outbound concurrency (FORK-5). The
/// dedicated `EasyPool` is sized to match so every fire thread
/// always `acquire()`s a handle uncontended. Vs the old
/// leader-pinned schedule-server (1 thread / 1 handle = strictly
/// sequential), this is the throughput unlock. Const for now; a
/// config knob is a later refinement, not this increment.
const FIRE_POOL_SIZE: u16 = 8;

/// An owned fire job handed SendDispatch-thread → a fire thread. It
/// copies the fire inputs out of the (then-stable) `Entry.owed` so
/// the fire thread never touches the set/Entry (which the dispatch
/// thread may rehome on demotion while the call is outstanding). The
/// result comes back by `id` only; `markCompleted(id,…)` no-ops if
/// the entry moved meanwhile. on_result/context are NOT copied —
/// they live on the still-`completed` Entry for 4c-iii.
const FireJob = struct {
    id: []u8,
    url: []u8,
    method: []u8,
    headers_json: []u8,
    body: []u8,
    timeout_ms: u32,
    max_body_bytes: u32,

    fn deinit(self: *FireJob, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.url);
        a.free(self.method);
        a.free(self.headers_json);
        a.free(self.body);
    }
};

/// Fire result handed a fire thread → SendDispatch thread. `outcome`
/// is owned (dup'd from `thread.FireResult`, incl. the otherwise-
/// static `err`, for uniform ownership). `markCompleted` takes the
/// `outcome`; `id` is freed by the result drain.
const FireResultMsg = struct {
    id: []u8,
    outcome: FireOutcome,
};

/// 4c-iii-A: a resolution work item handed SendDispatch-thread →
/// leader worker (7-A: the dissolved schedule.db's work-queue role).
/// `receipt` is the env-9-schema JSON `runOneCallback` already parses
/// (input re-sourced from the in-flight set, not schedules.db `c/`).
/// All owned; the worker drain (4c-iii-B) frees after running it.
pub const Completion = struct {
    tenant_id: []u8,
    callback_id: []u8,
    receipt: []u8,

    pub fn deinit(self: *Completion, a: std.mem.Allocator) void {
        a.free(self.tenant_id);
        a.free(self.callback_id);
        a.free(self.receipt);
    }
};

/// JSON string-escape, byte-identical to `apply.zig`'s private
/// `writeJsonString` (the receipt MUST parse the same in
/// `runOneCallback`). Duplicated, not shared: it's a frozen 8-line
/// primitive and `apply.zig` already imports `send_dispatch` (4b-iv)
/// — reusing it the other way would be an import cycle for nothing.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
}

/// Build the env-9-schema callback receipt
/// (`{id,on_result,on_result_fn?,on_result_args?,ok,status,version,
/// context,body,error}`) from a completed send's `OwedSend` +
/// outcome — byte-for-byte the shape `apply.zig.buildScheduleCallbackJson`
/// produced, so the EXISTING `callback_dispatch.runOneCallback`
/// parses it unchanged (7-A: reuse the runner, re-source its input).
/// `on_result` is `null` for fire-and-forget — 4c-iii-B branches on
/// that (proof-only, no handler) since `runOneCallback` drops a
/// null-on_result receipt. `version` is a constant passthrough: an
/// Option (b) `OwedSend` is immutable per id (no re-upsert / staleness
/// like schedules.db), so there is no version-bump to carry — see the
/// resolve-once note in #8 (the schedule path's `version_at_fire`
/// staleness check has no analogue here; proof-presence + 4a id-dedup
/// IS resolve-once).
pub fn buildReceiptJson(
    a: std.mem.Allocator,
    id: []const u8,
    owed: *const OwedSend,
    ok: bool,
    status: u16,
    body: []const u8,
    err: []const u8,
) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(a);
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &list);
    const w = &aw.writer;

    try w.writeAll("{\"id\":\"");
    try writeJsonString(w, id);
    try w.writeAll("\",\"on_result\":");
    if (owed.on_result_module.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeByte('"');
        try writeJsonString(w, owed.on_result_module);
        try w.writeByte('"');
    }
    if (owed.on_result_fn.len > 0) {
        try w.writeAll(",\"on_result_fn\":\"");
        try writeJsonString(w, owed.on_result_fn);
        try w.writeByte('"');
    }
    if (owed.on_result_args_json.len > 0) {
        try w.writeAll(",\"on_result_args\":");
        try w.writeAll(owed.on_result_args_json);
    }
    try w.print(",\"ok\":{},\"status\":{d},\"version\":{d},\"context\":", .{ ok, status, @as(u32, 1) });
    if (owed.context_json.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll(owed.context_json);
    }
    try w.writeAll(",\"body\":\"");
    try writeJsonString(w, body);
    try w.writeAll("\",\"error\":");
    if (err.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeByte('"');
        try writeJsonString(w, err);
        try w.writeByte('"');
    }
    try w.writeByte('}');
    return aw.toOwnedSlice();
}

/// What a committed writeset implies for the leader-local set. All
/// slices BORROW into the source `WriteSet` — valid only for the
/// classify call site; `enqueueArm`/`enqueueResolve` dupe what they
/// keep. Pure analysis, no allocation of payload, no hot-path
/// coupling: 4b-ii-B walks these at the commit-gated seam.
pub const SendIntent = union(enum) {
    /// `_send/owed/{id}` put — a send the leader now owes. `owed` is
    /// the put value (encoded `OwedSend`). The owning worker is
    /// hash(tenant)→worker; §6.4 resolution routes by the send-id
    /// resume-search, so there is no per-send routing handle.
    arm: struct { id: []const u8, owed: []const u8 },
    /// `_send/proof/{id}` put (resolved) or `_send/owed/{id}` delete
    /// (cancelled) — either way the leader no longer owes `id`.
    resolve: []const u8,
};

/// The single per-op `_send/` rule, shared by the leader-side
/// `classify(*WriteSet)` (4b-ii) and the follower-side
/// `classifyPayload(payload)` (4b-iv / FORK-6'). `null` for non-
/// `_send/` ops. Order preservation is the caller's loop.
fn intentForOp(op: kv_mod.WriteSetOp) ?SendIntent {
    const OWED = send_outbox.OWED_PREFIX;
    const PROOF = send_outbox.PROOF_PREFIX;
    return switch (op) {
        .put => |p| if (std.mem.startsWith(u8, p.key, OWED))
            SendIntent{ .arm = .{ .id = p.key[OWED.len..], .owed = p.value } }
        else if (std.mem.startsWith(u8, p.key, PROOF))
            SendIntent{ .resolve = p.key[PROOF.len..] }
        else
            null,
        .delete => |d| if (std.mem.startsWith(u8, d.key, OWED))
            SendIntent{ .resolve = d.key[OWED.len..] }
        else
            null,
    };
}

fn classifyOps(
    ops: []const kv_mod.WriteSetOp,
    a: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(SendIntent),
) !void {
    for (ops) |op| if (intentForOp(op)) |it| try out.append(a, it);
}

/// Classify a committed live `WriteSet` into ordered `SendIntent`s.
/// Order is preserved so a same-hop send-then-cancel
/// (`_send/owed/{id}` put then delete) drains arm-then-resolve =
/// net-removed, matching `InflightSet` semantics. Borrows key/value
/// slices from `ws` (caller dupes via enqueue). Leader path (4b-ii).
pub fn classify(
    ws: *const kv_mod.WriteSet,
    a: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(SendIntent),
) !void {
    try classifyOps(ws.ops.items, a, out);
}

/// FORK-6' / 4b-iv: same classification over an ENCODED writeset
/// payload (what `applyWriteSet` has on followers — `env.payload`,
/// not a live `WriteSet`). `kv.decodeWriteSetOps` does the proven
/// zero-copy walk; borrowed slices point into `payload` (valid for
/// the call). Truncation/bad-type after a partial decode is treated
/// best-effort (the apply path already rejected malformed payloads
/// loudly upstream) — classify what decoded, drop the rest.
pub fn classifyPayload(
    payload: []const u8,
    a: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(SendIntent),
) !void {
    var ops: std.ArrayListUnmanaged(kv_mod.WriteSetOp) = .empty;
    defer ops.deinit(a);
    kv_mod.decodeWriteSetOps(payload, a, &ops) catch {}; // best-effort: classify the prefix that decoded
    try classifyOps(ops.items, a, out);
}

/// An owned, commit-gated intent. 4b-ii-B parks these on the worker's
/// `ParkedUnit` keyed by the propose seq: `drainRaftPending` calls
/// `fire` once the seq commits, or `deinit` discards on
/// fault/timeout/leadership-loss (the FORK-6 "leader-side at commit"
/// guarantee — a node that loses leadership before firing discards;
/// the new leader's promotion boot-scan re-derives from the durable
/// per-tenant `_send/owed/`, so no silent loss). All slices are
/// allocator-owned by the parked unit.
pub const OwnedIntent = union(enum) {
    arm: struct { id: []u8, tenant_id: []u8, owed: []u8 },
    resolve: []u8,

    pub fn deinit(self: *OwnedIntent, a: std.mem.Allocator) void {
        switch (self.*) {
            .arm => |*v| {
                a.free(v.id);
                a.free(v.tenant_id);
                a.free(v.owed);
            },
            .resolve => |id| a.free(id),
        }
    }

    /// Hand to the leader-local dispatch on commit. `sd` may be null
    /// only in tests / before `startSendDispatch` — a dropped intent
    /// then is recovered by the promotion boot-scan, so this is
    /// non-fatal (warn, not panic).
    pub fn fire(self: *const OwnedIntent, sd: ?*SendDispatch) void {
        const d = sd orelse return;
        switch (self.*) {
            .arm => |v| d.enqueueArm(v.id, v.tenant_id, v.owed) catch |e|
                std.log.warn("send-dispatch: arm enqueue {s}: {s}", .{ v.id, @errorName(e) }),
            .resolve => |id| d.enqueueResolve(id) catch |e|
                std.log.warn("send-dispatch: resolve enqueue {s}: {s}", .{ id, @errorName(e) }),
        }
    }
};

/// Classify a committed `ws` and materialize OWNED intents into
/// `out`. `tenant_id` stamps every arm (the classifier can't see
/// it). Borrowed→owned dup happens here, off the request hot path is
/// irrelevant — this runs at the commit-gated park site, once per
/// batch, bounded by `_send/*` ops in the batch (tiny). On any alloc
/// failure the partial `out` is the caller's to free (parked-unit
/// deinit handles it).
pub fn materialize(
    ws: *const kv_mod.WriteSet,
    tenant_id: []const u8,
    a: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(OwnedIntent),
) !void {
    var intents: std.ArrayListUnmanaged(SendIntent) = .empty;
    defer intents.deinit(a);
    try classify(ws, a, &intents);
    for (intents.items) |it| switch (it) {
        .arm => |v| {
            const id = try a.dupe(u8, v.id);
            errdefer a.free(id);
            const tid = try a.dupe(u8, tenant_id);
            errdefer a.free(tid);
            const owed = try a.dupe(u8, v.owed);
            errdefer a.free(owed);
            try out.append(a, .{ .arm = .{ .id = id, .tenant_id = tid, .owed = owed } });
        },
        .resolve => |id_b| {
            const id = try a.dupe(u8, id_b);
            errdefer a.free(id);
            try out.append(a, .{ .resolve = id });
        },
    };
}

/// A unit of work handed from a committing worker to the dispatch
/// thread. All slices are allocator-owned by the queue until the
/// drain consumes them.
const Op = union(enum) {
    /// A hop that wrote `_send/owed/{id}` committed on the leader.
    /// `owed_bytes` is the encoded `OwedSend` exactly as written to
    /// kv — decoded off the hot path, here. Owning worker =
    /// hash(tenant)→worker; resolution routes by the send-id
    /// resume-search, not a stored handle.
    arm: struct {
        id: []u8,
        tenant_id: []u8,
        owed_bytes: []u8,
    },
    /// `_send/proof/{id}` committed (resolved) or the send was
    /// cancelled (`_send/owed/{id}` deleted). Idempotent downstream.
    resolve: []u8,
    /// 4c-iii-B-2: a leader worker's resolution of `id` was `.kept`/
    /// `.dropped` (transient — handler threw / deploy mid-flight /
    /// kv error). Move it `resolving → completed` on the SendDispatch
    /// thread so the resolution-drain re-pushes it (the at-least-once
    /// retry the old dispatchCallbacks gave via its un-cancel-dropped
    /// `c/` row). Cross-thread by id, like `.resolve` — the worker is
    /// not the set's sole-owner thread (FORK-2 class).
    requeue: []u8,

    fn freeOwned(self: *Op, a: std.mem.Allocator) void {
        switch (self.*) {
            .arm => |*v| {
                a.free(v.id);
                a.free(v.tenant_id);
                a.free(v.owed_bytes);
            },
            .resolve => |id| a.free(id),
            .requeue => |id| a.free(id),
        }
    }
};

/// Returns whether this node is the raft leader. Production wires
/// `NodeState.raft.isLeader()`; tests pass a trivial fn over an
/// atomic. Null ⇒ never gated (the 4b-i unit-test posture).
pub const LeaderFn = *const fn (ctx: ?*anyopaque) bool;

/// Promotion boot-scan (4b-iii-B): reconstruct the leader-local set
/// from the durable per-tenant `_send/owed/` by arming directly into
/// `sd.set` (called ON the dispatch thread — sole owner, no queue).
/// Null in 4b-iii-A and in unit tests; wired in 4b-iii-B.
pub const RecoverFn = *const fn (ctx: ?*anyopaque, sd: *SendDispatch) void;

/// Leadership-edge re-check cadence. The loop also wakes on enqueue;
/// this bounds promotion/demotion detection latency when idle. Inert
/// increment — not perf-sensitive.
const POLL_INTERVAL_NS: u64 = 100 * std.time.ns_per_ms;

pub const SendDispatch = struct {
    allocator: std.mem.Allocator,

    /// Sole owner: the dispatch thread (drain here; boot-scan arms
    /// here; 4c fire later). No lock — single-owner by construction.
    set: InflightSet,

    /// FIFO handoff. The only shared-state surface; workers append
    /// under `ops_mutex`, the thread drains under it.
    ops: std.ArrayListUnmanaged(Op),
    ops_mutex: std.Thread.Mutex,

    wake: std.Thread.ResetEvent,
    stop: std.atomic.Value(bool),
    thread: ?std.Thread,

    // ── 4c-ii-B fire executor (FORK-5) ─────────────────────────────
    /// Dedicated libcurl handle pool (≠ S3's defaultPool — isolated
    /// saturation domains). Sized = fire-thread count so every fire
    /// thread `acquire()`s uncontended. Null until `start`.
    easy_pool: ?*blob_curl.EasyPool = null,
    /// The fire-thread-pool: M threads each doing a blocking
    /// `fireOnce`. M = outbound concurrency. Allocated/spawned in
    /// `start`, joined in `shutdown`.
    fire_threads: []std.Thread = &.{},
    /// SendDispatch-thread → fire-pool. FIFO; `jobs_wake` signals
    /// idle fire threads.
    jobs: std.ArrayListUnmanaged(FireJob) = .empty,
    jobs_mutex: std.Thread.Mutex = .{},
    jobs_wake: std.Thread.ResetEvent = .{},
    /// fire-pool → SendDispatch-thread. Drained on the dispatch
    /// thread (`markCompleted`); fire threads `wake.set()` after a
    /// push so the drain is prompt.
    results: std.ArrayListUnmanaged(FireResultMsg) = .empty,
    results_mutex: std.Thread.Mutex = .{},
    /// 4c-iii: SendDispatch-thread → leader worker. Resolution work
    /// (run on_result / write fire-and-forget proof). Drained by the
    /// 4c-iii-B worker phase; the `_send/proof/` it commits flows
    /// back via the 4b-ii feed → `enqueueResolve` (idempotent).
    completions: std.ArrayListUnmanaged(Completion) = .empty,
    completions_mutex: std.Thread.Mutex = .{},

    /// FORK-6 leader-gating. `leader_fn` null ⇒ never leader (unit
    /// tests): no recover/demote-drop, drain still runs (ops only
    /// ever arrive on the leader under single-raft, so draining
    /// unconditionally is correct and keeps 4b-i tests valid).
    leader_ctx: ?*anyopaque = null,
    leader_fn: ?LeaderFn = null,
    recover_ctx: ?*anyopaque = null,
    recover_fn: ?RecoverFn = null,
    /// Edge state. Promotion: FORK-6' keeps the follower-maintained
    /// `armed` set warm, so the cold-start boot-scan (`recover_fn`)
    /// runs only on the FIRST promotion of the process lifetime — the
    /// safety-net for owed sends that predate this process / arrived
    /// via snapshot install (never seen through the live follower
    /// feed). Subsequent promotions fire straight from the warm set
    /// (the 0.9–2.2 s/10k reconstruction we're avoiding). Demotion
    /// collapses firing phases back to `armed` (set retained).
    was_leader: bool = false,
    cold_recovered: bool = false,


    /// Monotonic count of fires that reached `completed` (result
    /// applied via `markCompleted`). Operator signal + the
    /// thread-safe completion edge tests wait on (the set itself is
    /// dispatch-thread-sole-owned — never polled cross-thread).
    completed_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Monotonic count of resolutions handed to a leader worker
    /// (`completed → resolving` + Completion enqueued). Operator
    /// signal + the thread-safe edge tests wait on.
    resolution_pushed_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator) !*SendDispatch {
        const self = try allocator.create(SendDispatch);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .set = .{},
            .ops = .empty,
            .ops_mutex = .{},
            .wake = .{},
            .stop = std.atomic.Value(bool).init(false),
            .thread = null,
        };
        return self;
    }

    /// Wire leadership gating + the promotion boot-scan. Call BEFORE
    /// `start` (the thread reads these unsynchronized). `recover_fn`
    /// may be null in 4b-iii-A (gating live, reconstruction lands in
    /// 4b-iii-B).
    pub fn configure(
        self: *SendDispatch,
        leader_ctx: ?*anyopaque,
        leader_fn: ?LeaderFn,
        recover_ctx: ?*anyopaque,
        recover_fn: ?RecoverFn,
    ) void {
        std.debug.assert(self.thread == null);
        self.leader_ctx = leader_ctx;
        self.leader_fn = leader_fn;
        self.recover_ctx = recover_ctx;
        self.recover_fn = recover_fn;
    }


    pub fn start(self: *SendDispatch) !void {
        std.debug.assert(self.thread == null);
        // Dedicated pool first (FORK-5). On any spawn failure below,
        // unwind in reverse so we never leave half a pool running.
        self.easy_pool = try blob_curl.EasyPool.init(self.allocator, FIRE_POOL_SIZE);
        errdefer {
            self.easy_pool.?.deinit();
            self.easy_pool = null;
        }
        self.fire_threads = try self.allocator.alloc(std.Thread, FIRE_POOL_SIZE);
        errdefer self.allocator.free(self.fire_threads);
        var spawned: usize = 0;
        errdefer {
            // Tell already-spawned fire threads to exit and join them.
            self.stop.store(true, .release);
            self.jobs_wake.set();
            for (self.fire_threads[0..spawned]) |t| t.join();
            self.stop.store(false, .release);
        }
        while (spawned < FIRE_POOL_SIZE) : (spawned += 1) {
            self.fire_threads[spawned] = try std.Thread.spawn(.{}, fireThreadMain, .{self});
        }
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn shutdown(self: *SendDispatch) void {
        self.stop.store(true, .release);
        self.wake.set();
        self.jobs_wake.set(); // release idle fire threads
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        for (self.fire_threads) |t| t.join();
        if (self.fire_threads.len > 0) {
            self.allocator.free(self.fire_threads);
            self.fire_threads = &.{};
        }
    }

    pub fn deinit(self: *SendDispatch) void {
        // Caller must have shut all threads down by here. Free any
        // ops/jobs/results the drains never reached (unfired jobs ⇒
        // those sends stay owed-without-proof ⇒ re-fired on a later
        // promotion; at-least-once — no silent loss), then the pool
        // + set.
        for (self.ops.items) |*op| op.freeOwned(self.allocator);
        self.ops.deinit(self.allocator);
        for (self.jobs.items) |*j| j.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        for (self.results.items) |*r| {
            self.allocator.free(r.id);
            r.outcome.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);
        for (self.completions.items) |*c| c.deinit(self.allocator);
        self.completions.deinit(self.allocator);
        if (self.easy_pool) |p| p.deinit();
        self.set.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Enqueue an arm. Cheap (dupe + mutex append + wake) — called
    /// by a worker at commit on the leader. `owed_bytes` is the
    /// encoded `OwedSend` the hop wrote to `_send/owed/{id}`; it is
    /// decoded by the drain thread, never here.
    pub fn enqueueArm(
        self: *SendDispatch,
        id: []const u8,
        tenant_id: []const u8,
        owed_bytes: []const u8,
    ) !void {
        const id_c = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_c);
        const tid_c = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(tid_c);
        const ob_c = try self.allocator.dupe(u8, owed_bytes);
        errdefer self.allocator.free(ob_c);

        self.ops_mutex.lock();
        defer self.ops_mutex.unlock();
        try self.ops.append(self.allocator, .{ .arm = .{
            .id = id_c,
            .tenant_id = tid_c,
            .owed_bytes = ob_c,
        } });
        self.wake.set();
    }

    /// Enqueue a resolve (proof committed / cancelled). Idempotent
    /// downstream — a resolve for an unknown id is a no-op.
    pub fn enqueueResolve(self: *SendDispatch, id: []const u8) !void {
        const id_c = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_c);

        self.ops_mutex.lock();
        defer self.ops_mutex.unlock();
        try self.ops.append(self.allocator, .{ .resolve = id_c });
        self.wake.set();
    }

    /// 4c-iii-B-2: a leader worker hit `.kept`/`.dropped` resolving
    /// `id` — request `resolving → completed` (re-push next tick).
    /// Cross-thread (worker → SendDispatch thread); same cheap
    /// dupe+mutex+wake as `enqueueResolve`. Idempotent: a requeue for
    /// an id not in `resolving` is a no-op.
    pub fn enqueueRequeue(self: *SendDispatch, id: []const u8) !void {
        const id_c = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_c);

        self.ops_mutex.lock();
        defer self.ops_mutex.unlock();
        try self.ops.append(self.allocator, .{ .requeue = id_c });
        self.wake.set();
    }

    /// 4c-iii: stage a resolution work item (SendDispatch thread →
    /// leader worker). Dupes inputs; cheap mutex append. The
    /// 4c-iii-B threadMain resolution-drain calls this for each
    /// `completed` entry; the worker phase calls `drainCompletion`.
    pub fn enqueueCompletion(
        self: *SendDispatch,
        tenant_id: []const u8,
        callback_id: []const u8,
        receipt: []const u8,
    ) !void {
        const t = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(t);
        const c = try self.allocator.dupe(u8, callback_id);
        errdefer self.allocator.free(c);
        const r = try self.allocator.dupe(u8, receipt);
        errdefer self.allocator.free(r);
        self.completions_mutex.lock();
        defer self.completions_mutex.unlock();
        try self.completions.append(self.allocator, .{ .tenant_id = t, .callback_id = c, .receipt = r });
    }

    /// 4c-iii-B leader-worker drain: pop one resolution item (FIFO),
    /// ownership transferred to the caller (free with `Completion.
    /// deinit` after running it). `null` when empty.
    pub fn drainCompletion(self: *SendDispatch) ?Completion {
        self.completions_mutex.lock();
        defer self.completions_mutex.unlock();
        if (self.completions.items.len == 0) return null;
        return self.completions.orderedRemove(0);
    }

    /// Test-only: drain synchronously on the calling thread. Not
    /// safe while the dispatch thread runs.
    pub fn drainSyncForTesting(self: *SendDispatch) void {
        std.debug.assert(self.thread == null);
        self.drainAll();
    }

    fn isLeader(self: *SendDispatch) bool {
        const f = self.leader_fn orelse return false;
        return f(self.leader_ctx);
    }

    /// FORK-6' demotion: do NOT drop the set — a now-follower keeps
    /// `armed` warm (maintained by the applyWriteSet follower feed,
    /// 4b-iv) so a fast re-promotion fires immediately. Only collapse
    /// the leader-local firing phases back to `armed` (in-flight →
    /// re-fireable; at-least-once). The op queue is NOT cleared: its
    /// arm/resolve are derived from committed writesets, valid
    /// regardless of leadership, and the drain is ungated.
    fn onDemotion(self: *SendDispatch) void {
        self.set.demoteToArmed(self.allocator);
    }

    fn threadMain(self: *SendDispatch) void {
        while (!self.stop.load(.acquire)) {
            // Wake on enqueue; also re-check leadership every
            // POLL_INTERVAL so a promotion/demotion with no pending
            // op is still observed (schedule-server thread pattern).
            self.wake.timedWait(POLL_INTERVAL_NS) catch {};
            self.wake.reset();
            if (self.stop.load(.acquire)) break;

            const leader = self.isLeader();
            if (leader and !self.was_leader) {
                // Promotion. FORK-6': the follower feed keeps `armed`
                // warm, so the cold-start boot-scan runs only ONCE
                // (first promotion this process) — the safety-net for
                // owed sends that predate this process or arrived via
                // snapshot install (never seen through the live
                // feed). Idempotent: armFromParts dedups vs any
                // already-warm entries. Later promotions: fire
                // straight from the warm set (no reconstruction).
                if (!self.cold_recovered) {
                    if (self.recover_fn) |rf| rf(self.recover_ctx, self);
                    self.cold_recovered = true;
                }
            } else if (!leader and self.was_leader) {
                self.onDemotion();
            }
            self.was_leader = leader;

            // Drain unconditionally: under single-raft, arm/resolve
            // ops are only enqueued by a committing leader, so this
            // is a no-op off-leader anyway — and keeps the gating
            // orthogonal to the queue (4b-i tests have no leader_fn).
            self.drainAll();

            // 4c-ii-B fire (guard-dormant until inc 5). Gated on
            // leader AND the runtime fire guard. Only cheap
            // bookkeeping here — markFiring + push job; the blocking
            // libcurl is on the fire-thread-pool (FORK-5: this thread
            // never `easy.request`s). Result drain is UNgated: a
            // result may arrive after demotion (markCompleted no-ops
            // if the entry left `inflight`), and after `stop` (final
            // drain below).
            // 5b-1 go-live: fire whenever leader (the fire_enabled
            // guard is retired — Option (b) is now the only path; no
            // schedule-server to double-fire against).
            if (leader) self.scanAndDispatchDue();
            self.drainResults();
            // 4c-iii-B resolution-drain (leader-gated): hand
            // `completed` receipts to a leader worker, push-once
            // (`completed→resolving`).
            if (leader) self.drainCompletedForResolution();
        }
        // Final drains so an op/result in flight at `stop` is still
        // applied (mirrors deployment_loader). Unfired jobs are NOT
        // drained — those sends stay owed-without-proof and re-fire
        // on a later promotion (at-least-once).
        self.drainAll();
        self.drainResults();
    }

    /// SendDispatch thread: pick `armed` entries whose `fire_at_ns ≤
    /// now`, move them `armed→inflight` (`markFiring` — the double-
    /// fire guard), and hand an owned `FireJob` to the fire-pool.
    /// Two-pass: collect due ids first (can't `markFiring` while
    /// iterating `armed`, that mutates the map). Per-job alloc
    /// failure just skips that send this pass — it stays `armed`,
    /// re-picked next tick (no loss).
    fn scanAndDispatchDue(self: *SendDispatch) void {
        const a = self.allocator;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        var due: std.ArrayListUnmanaged([]const u8) = .empty;
        defer due.deinit(a);
        {
            var it = self.set.armedIterator();
            while (it.next()) |ep| {
                if (ep.*.dueAt(now)) due.append(a, ep.*.id) catch break;
            }
        }
        for (due.items) |id| {
            const e = (self.set.markFiring(a, id) catch null) orelse continue;
            const job = buildJob(a, e) catch continue; // stays inflight; result-less entry re-armed on demote/restart
            self.jobs_mutex.lock();
            self.jobs.append(a, job) catch {
                self.jobs_mutex.unlock();
                var j = job;
                j.deinit(a);
                continue;
            };
            self.jobs_mutex.unlock();
            self.jobs_wake.set();
            std.log.info("rove-js sendpath: scanAndDispatchDue fired id={s}", .{id});
        }
    }

    /// SendDispatch thread: hand each `completed` send's receipt to a
    /// leader worker (7-A). Push-ONCE: build the env-9-schema receipt
    /// from `owed`+`result`, `enqueueCompletion`, then
    /// `completed→resolving` so it is NOT re-pushed while its proof
    /// commits over raft (the 4b-ii feed → `resolve` removes it; a
    /// worker `.kept` moves it back to `completed` for retry). Two-
    /// pass (markResolving mutates `completed`, can't run mid-iterate).
    /// A build/enqueue failure leaves the entry in `completed` (NOT
    /// markResolving'd) → retried next tick (no loss).
    fn drainCompletedForResolution(self: *SendDispatch) void {
        const a = self.allocator;
        var ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer ids.deinit(a);
        {
            var it = self.set.completedIterator();
            while (it.next()) |ep| ids.append(a, ep.*.id) catch break;
        }
        for (ids.items) |id| {
            const e = self.set.getById(id) orelse continue;
            const r = e.result orelse continue; // defensive: completed ⇒ result set
            const receipt = buildReceiptJson(a, e.id, &e.owed, r.ok, r.status, r.body, r.err) catch |err| {
                std.log.warn("send-dispatch: receipt build {s}: {s}", .{ id, @errorName(err) });
                continue; // stays completed → retried next tick
            };
            defer a.free(receipt);
            self.enqueueCompletion(e.tenant_id, e.id, receipt) catch |err| {
                std.log.warn("send-dispatch: enqueueCompletion {s}: {s}", .{ id, @errorName(err) });
                continue; // stays completed → retried next tick
            };
            if (self.set.markResolving(a, id)) { // push-once
                _ = self.resolution_pushed_total.fetchAdd(1, .monotonic);
                std.log.info("rove-js sendpath: resolution-push id={s}", .{id});
            }
        }
    }

    pub fn resolutionPushedTotal(self: *const SendDispatch) u64 {
        return self.resolution_pushed_total.load(.monotonic);
    }

    fn buildJob(a: std.mem.Allocator, e: *const Entry) !FireJob {
        var j: FireJob = .{
            .id = try a.dupe(u8, e.id),
            .url = undefined,
            .method = undefined,
            .headers_json = undefined,
            .body = undefined,
            .timeout_ms = e.owed.timeout_ms,
            .max_body_bytes = e.owed.max_body_bytes,
        };
        errdefer a.free(j.id);
        j.url = try a.dupe(u8, e.owed.url);
        errdefer a.free(j.url);
        j.method = try a.dupe(u8, e.owed.method);
        errdefer a.free(j.method);
        j.headers_json = try a.dupe(u8, e.owed.headers_json);
        errdefer a.free(j.headers_json);
        j.body = try a.dupe(u8, e.owed.body);
        return j;
    }

    /// A fire-pool thread: pop a job, acquire a dedicated `Easy`, do
    /// the BLOCKING `fireOnce`, release, hand the owned outcome back
    /// by id. Never touches the set (the dispatch thread may rehome
    /// the entry on demotion while this call is outstanding — the
    /// result reconciles by id via `markCompleted`).
    fn fireThreadMain(self: *SendDispatch) void {
        const a = self.allocator;
        while (!self.stop.load(.acquire)) {
            self.jobs_wake.timedWait(POLL_INTERVAL_NS) catch {};
            // Don't reset() here: many fire threads share one event;
            // reset would race a concurrent producer's set(). The
            // mutex'd queue is the real condition; the event is just
            // a wakeup hint (timedWait bounds the miss to one poll).
            if (self.stop.load(.acquire)) break;
            while (true) {
                self.jobs_mutex.lock();
                if (self.jobs.items.len == 0) {
                    self.jobs_mutex.unlock();
                    break;
                }
                var job = self.jobs.orderedRemove(0);
                self.jobs_mutex.unlock();

                const pool = self.easy_pool orelse {
                    job.deinit(a);
                    continue;
                };
                const easy = pool.acquire();
                var r = sched_thread.fireOnce(a, easy, .{
                    .url = job.url,
                    .method = job.method,
                    .headers_json = job.headers_json,
                    .body = job.body,
                    .timeout_ms = job.timeout_ms,
                    .max_body_bytes = job.max_body_bytes,
                    .id = job.id,
                    // version_str: resolve-once version-counter is
                    // 4c-iii's; a stable placeholder header value
                    // here. Revisited at the cutover.
                    .version_str = "1",
                });
                pool.release(easy);

                // FireResult → OWNED FireOutcome. Capture scalars and
                // dup both buffers BEFORE `r.deinit` frees `r.body`
                // (no read-after-free). On any dup OOM: free the
                // partial, drop (job stays owed-without-proof →
                // re-fired later; at-least-once). No `""`-as-owned
                // (freeing a static would be UB).
                const ok = r.outcome == .delivered;
                const status = r.status;
                std.log.info("rove-js sendpath: fireThread fired id={s} ok={} status={d}", .{ job.id, ok, status });
                const body_c: ?[]u8 = a.dupe(u8, r.bodyOr("")) catch null;
                const err_c: ?[]u8 = if (body_c != null) (a.dupe(u8, r.err) catch null) else null;
                r.deinit(a);
                if (body_c == null or err_c == null) {
                    if (body_c) |b| a.free(b);
                    job.deinit(a); // nothing moved out; frees id too
                    continue;
                }
                const outcome: FireOutcome = .{
                    .ok = ok,
                    .status = status,
                    .body = body_c.?,
                    .err = err_c.?,
                };
                self.results_mutex.lock();
                self.results.append(a, .{ .id = job.id, .outcome = outcome }) catch {
                    self.results_mutex.unlock();
                    a.free(body_c.?);
                    a.free(err_c.?);
                    job.deinit(a); // id not moved (append failed)
                    continue;
                };
                self.results_mutex.unlock();
                // `job.id` ownership moved into the result; free the
                // rest of the job (NOT `job.deinit` — that frees id).
                a.free(job.url);
                a.free(job.method);
                a.free(job.headers_json);
                a.free(job.body);
                self.wake.set(); // prompt the dispatch thread's drainResults
            }
        }
    }

    /// SendDispatch thread: apply fire outcomes. `markCompleted`
    /// moves `inflight→completed` + attaches the outcome, or no-ops
    /// + frees it if the entry left `inflight` (resolved/cancelled/
    /// demoted while the fire was outstanding — dedup).
    fn drainResults(self: *SendDispatch) void {
        const a = self.allocator;
        while (true) {
            self.results_mutex.lock();
            if (self.results.items.len == 0) {
                self.results_mutex.unlock();
                break;
            }
            const msg = self.results.orderedRemove(0);
            self.results_mutex.unlock();
            std.log.info("rove-js sendpath: drainResults markCompleted id={s}", .{msg.id});
            self.set.markCompleted(a, msg.id, msg.outcome);
            a.free(msg.id);
            _ = self.completed_total.fetchAdd(1, .monotonic);
        }
    }

    pub fn completedTotal(self: *const SendDispatch) u64 {
        return self.completed_total.load(.monotonic);
    }

    /// 4b-iii-B: arm one reconstructed owed send from BORROWED parts
    /// (the promotion boot-scan's RangeResult slices). Dupes id +
    /// tenant, decodes owed, builds the Entry, `set.arm` (dedup: an
    /// existing entry — e.g. a concurrent live-feed op already
    /// drained, or a re-scan — wins, this copy is freed). MUST be
    /// called on the dispatch thread (sole owner of `set`) — i.e.
    /// only from a `RecoverFn`. Best-effort: a decode/OOM failure
    /// drops just this send (logged); the live feed + the next
    /// promotion still cover it (no silent loss for the set as a
    /// whole). Same arm logic as `applyOp` but over borrowed input.
    pub fn armFromParts(
        self: *SendDispatch,
        id: []const u8,
        tenant_id: []const u8,
        owed_bytes: []const u8,
    ) void {
        const a = self.allocator;
        var owed = OwedSend.decode(a, owed_bytes) catch |err| {
            std.log.warn("send-dispatch: recover drop {s}: owed decode {s}", .{ id, @errorName(err) });
            return;
        };
        const id_c = a.dupe(u8, id) catch {
            owed.deinitOwned(a);
            return;
        };
        const tid_c = a.dupe(u8, tenant_id) catch {
            owed.deinitOwned(a);
            a.free(id_c);
            return;
        };
        const e = a.create(Entry) catch {
            owed.deinitOwned(a);
            a.free(id_c);
            a.free(tid_c);
            return;
        };
        e.* = .{ .id = id_c, .tenant_id = tid_c, .owed = owed };
        const armed = self.set.arm(a, e) catch false;
        if (!armed) {
            e.deinit(a);
            a.destroy(e);
        }
    }

    fn drainAll(self: *SendDispatch) void {
        while (self.popOne()) |op_const| {
            var op = op_const;
            self.applyOp(&op);
        }
    }

    fn popOne(self: *SendDispatch) ?Op {
        self.ops_mutex.lock();
        defer self.ops_mutex.unlock();
        if (self.ops.items.len == 0) return null;
        return self.ops.orderedRemove(0);
    }

    /// Apply one op to the set. Consumes `op`'s owned slices: an
    /// armed entry takes ownership of id/tenant/decoded-owed; a
    /// rejected-as-dup arm or a resolve frees them. `owed_bytes` is
    /// always freed here (decode copies what it keeps).
    fn applyOp(self: *SendDispatch, op: *Op) void {
        const a = self.allocator;
        switch (op.*) {
            .arm => |*v| {
                defer a.free(v.owed_bytes);
                var owed = OwedSend.decode(a, v.owed_bytes) catch |err| {
                    std.log.warn(
                        "send-dispatch: drop arm {s}: owed decode {s}",
                        .{ v.id, @errorName(err) },
                    );
                    a.free(v.id);
                    a.free(v.tenant_id);
                    return;
                };
                const e = a.create(Entry) catch {
                    owed.deinitOwned(a);
                    a.free(v.id);
                    a.free(v.tenant_id);
                    return;
                };
                e.* = .{
                    .id = v.id, // ownership moves into the entry
                    .tenant_id = v.tenant_id,
                    .owed = owed,
                };
                const armed = self.set.arm(a, e) catch false;
                std.log.info("rove-js sendpath: applyOp arm id={s} armed={}", .{ v.id, armed });
                if (!armed) {
                    // Dedup: existing entry wins (boot-scan ∪ live
                    // feed re-feed / a slow delivery re-armed).
                    e.deinit(a);
                    a.destroy(e);
                }
            },
            .resolve => |id| {
                defer a.free(id);
                _ = self.set.resolve(a, id);
            },
            .requeue => |id| {
                defer a.free(id);
                _ = self.set.requeueResolution(a, id);
            },
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn encOwed(a: std.mem.Allocator, fire_at_ns: i64) ![]u8 {
    const src = OwedSend{
        .url = "https://wb.test/x",
        .method = "POST",
        .headers_json = "{}",
        .body = "b",
        .context_json = "null",
        .on_result_module = "m",
        .on_result_fn = "",
        .on_result_args_json = "",
        .timeout_ms = 30_000,
        .max_body_bytes = 1_048_576,
        .fire_at_ns = fire_at_ns,
    };
    return src.encode(a);
}

fn encOwedUrl(a: std.mem.Allocator, url: []const u8, fire_at_ns: i64) ![]u8 {
    const src = OwedSend{
        .url = url,
        .method = "POST",
        .headers_json = "{}",
        .body = "b",
        .context_json = "null",
        .on_result_module = "m",
        .on_result_fn = "",
        .on_result_args_json = "",
        .timeout_ms = 30_000,
        .max_body_bytes = 1_048_576,
        .fire_at_ns = fire_at_ns,
    };
    return src.encode(a);
}

test "classify maps owed-put→arm, proof-put→resolve, owed-delete→resolve, in order" {
    const a = testing.allocator;
    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("users/alice", "data"); // ignored (not _send/)
    try ws.addPut("_send/owed/s1", "owedbytes1");
    try ws.addPut("_send/proof/s0", "proofbytes");
    try ws.addPut("_send/owed/s2", "owedbytes2");
    try ws.addDelete("_send/owed/s2"); // same-hop send-then-cancel
    try ws.addDelete("orders/7"); // ignored

    var out: std.ArrayListUnmanaged(SendIntent) = .empty;
    defer out.deinit(a);
    try classify(&ws, a, &out);

    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("s1", out.items[0].arm.id);
    try testing.expectEqualStrings("owedbytes1", out.items[0].arm.owed);
    try testing.expectEqualStrings("s0", out.items[1].resolve);
    try testing.expectEqualStrings("s2", out.items[2].arm.id);
    // order preserved: s2 arm precedes s2 resolve → net-removed downstream
    try testing.expectEqualStrings("s2", out.items[3].resolve);
}

test "classifyPayload over encoded bytes == classify over the live WriteSet" {
    const a = testing.allocator;
    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("users/alice", "data");
    try ws.addPut("_send/owed/s1", "owedbytes1");
    try ws.addPut("_send/proof/s0", "proofbytes");
    try ws.addPut("_send/owed/s2", "owedbytes2");
    try ws.addDelete("_send/owed/s2");
    try ws.addDelete("orders/7");

    const payload = try ws.encode(a);
    defer a.free(payload);

    var out: std.ArrayListUnmanaged(SendIntent) = .empty;
    defer out.deinit(a);
    try classifyPayload(payload, a, &out);

    // Identical to the live-WriteSet `classify` result (same rule,
    // same order) — the FORK-6' follower feed mirrors 4b-ii's leader
    // feed bit-for-bit.
    try testing.expectEqual(@as(usize, 4), out.items.len);
    try testing.expectEqualStrings("s1", out.items[0].arm.id);
    try testing.expectEqualStrings("owedbytes1", out.items[0].arm.owed);
    try testing.expectEqualStrings("s0", out.items[1].resolve);
    try testing.expectEqualStrings("s2", out.items[2].arm.id);
    try testing.expectEqualStrings("s2", out.items[3].resolve);
}

test "classifyPayload tolerates truncation best-effort (decodes the prefix)" {
    const a = testing.allocator;
    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("_send/owed/keep", "v");
    try ws.addPut("_send/owed/lost", "v2");
    const payload = try ws.encode(a);
    defer a.free(payload);

    var out: std.ArrayListUnmanaged(SendIntent) = .empty;
    defer out.deinit(a);
    // Chop mid-second-op: first op still decodes, classify what we got.
    try classifyPayload(payload[0 .. payload.len - 3], a, &out);
    try testing.expect(out.items.len >= 1);
    try testing.expectEqualStrings("keep", out.items[0].arm.id);
}

fn decodedOwed(a: std.mem.Allocator, src: OwedSend) !OwedSend {
    const enc = try src.encode(a);
    defer a.free(enc);
    return OwedSend.decode(a, enc);
}

test "4c-iii-A: buildReceiptJson — on_result shape parses like runOneCallback" {
    const a = testing.allocator;
    var owed = try decodedOwed(a, .{
        .url = "https://x/", .method = "POST", .headers_json = "{}",
        .body = "req", .context_json = "{\"k\":1}", .on_result_module = "stripe_done",
        .on_result_fn = "handleCharge", .on_result_args_json = "[42]",
        .timeout_ms = 1, .max_body_bytes = 1, .fire_at_ns = 0,
    });
    defer owed.deinitOwned(a);
    const j = try buildReceiptJson(a, "snd-1", &owed, true, 200, "resp\"body", "");
    defer a.free(j);

    var p = try std.json.parseFromSlice(std.json.Value, a, j, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("snd-1", o.get("id").?.string);
    try testing.expectEqualStrings("stripe_done", o.get("on_result").?.string);
    try testing.expectEqualStrings("handleCharge", o.get("on_result_fn").?.string);
    try testing.expectEqual(@as(i64, 42), o.get("on_result_args").?.array.items[0].integer);
    try testing.expectEqual(true, o.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 200), o.get("status").?.integer);
    try testing.expectEqualStrings("resp\"body", o.get("body").?.string); // escaping round-trips
    try testing.expectEqual(@as(i64, 1), o.get("context").?.object.get("k").?.integer);
    try testing.expect(o.get("error").? == .null);
}

test "4c-iii-A: buildReceiptJson — fire-and-forget ⇒ on_result null, error set" {
    const a = testing.allocator;
    var owed = try decodedOwed(a, .{
        .url = "https://x/", .method = "GET", .headers_json = "{}", .body = "",
        .context_json = "", .on_result_module = "", .on_result_fn = "",
        .on_result_args_json = "", .timeout_ms = 1, .max_body_bytes = 1, .fire_at_ns = 0,
    });
    defer owed.deinitOwned(a);
    const j = try buildReceiptJson(a, "ff-1", &owed, false, 0, "", "invalid url");
    defer a.free(j);
    var p = try std.json.parseFromSlice(std.json.Value, a, j, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    const o = p.value.object;
    try testing.expect(o.get("on_result").? == .null); // fire-and-forget
    try testing.expect(o.get("on_result_fn") == null); // omitted when empty
    try testing.expect(o.get("context").? == .null); // empty ⇒ null
    try testing.expectEqual(false, o.get("ok").?.bool);
    try testing.expectEqualStrings("invalid url", o.get("error").?.string);
}

test "4c-iii-A: enqueue/drainCompletion FIFO + ownership; deinit frees remaining" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit(); // must free the undrained 2nd item — leak-checked

    try testing.expect(sd.drainCompletion() == null);
    try sd.enqueueCompletion("t1", "c1", "{\"id\":\"c1\"}");
    try sd.enqueueCompletion("t2", "c2", "{\"id\":\"c2\"}");

    var first = sd.drainCompletion().?;
    try testing.expectEqualStrings("t1", first.tenant_id);
    try testing.expectEqualStrings("c1", first.callback_id);
    try testing.expectEqualStrings("{\"id\":\"c1\"}", first.receipt);
    first.deinit(a); // caller owns after drain
    // 2nd left in the queue on purpose → deinit must free it.
}

test "4c-iii-B-2a: enqueueRequeue op → resolving→completed via drain" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    // Build a `resolving` entry: arm→markFiring→markCompleted→markResolving.
    const ob = try encOwed(a, 0);
    defer a.free(ob);
    try sd.enqueueArm("rq", "t", ob);
    sd.drainSyncForTesting();
    _ = (try sd.set.markFiring(a, "rq")).?;
    sd.set.markCompleted(a, "rq", .{
        .ok = false,
        .status = 0,
        .body = try a.dupe(u8, ""),
        .err = try a.dupe(u8, "x"),
    });
    try testing.expect(sd.set.markResolving(a, "rq"));
    try testing.expectEqual(@as(usize, 1), sd.set.resolvingCount());

    // Worker `.kept` → enqueueRequeue (cross-thread by id) → drain
    // moves it resolving→completed (re-pushed next resolution tick).
    try sd.enqueueRequeue("rq");
    try sd.enqueueRequeue("ghost"); // idempotent: not resolving → no-op
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 0), sd.set.resolvingCount());
    try testing.expectEqual(@as(usize, 1), sd.set.completedCount());
}

test "4c-iii-B-1: drainCompletedForResolution — receipt enqueued, push-once" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    // Build a `completed` entry directly (no threads → safe to touch
    // the set). encOwed sets on_result_module="m".
    const ob = try encOwed(a, 0);
    defer a.free(ob);
    try sd.enqueueArm("e1", "tnt", ob);
    sd.drainSyncForTesting(); // → armed
    _ = (try sd.set.markFiring(a, "e1")).?; // → inflight
    sd.set.markCompleted(a, "e1", .{
        .ok = true,
        .status = 200,
        .body = try a.dupe(u8, "resp"),
        .err = try a.dupe(u8, ""),
    }); // → completed

    sd.drainCompletedForResolution();

    // Receipt handed off + entry moved completed→resolving (push-once).
    try testing.expectEqual(@as(usize, 0), sd.set.completedCount());
    try testing.expectEqual(@as(usize, 1), sd.set.resolvingCount());
    var comp = sd.drainCompletion().?;
    defer comp.deinit(a);
    try testing.expectEqualStrings("tnt", comp.tenant_id);
    try testing.expectEqualStrings("e1", comp.callback_id);
    var p = try std.json.parseFromSlice(std.json.Value, a, comp.receipt, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    try testing.expectEqualStrings("e1", p.value.object.get("id").?.string);
    try testing.expectEqualStrings("m", p.value.object.get("on_result").?.string);
    try testing.expectEqual(true, p.value.object.get("ok").?.bool);

    // push-once: a 2nd drain does NOT re-enqueue (it's in resolving,
    // not completed — no storm while the proof commits).
    sd.drainCompletedForResolution();
    try testing.expect(sd.drainCompletion() == null);

    // worker `.kept` → requeue → re-pushed next drain.
    try testing.expect(sd.set.requeueResolution(a, "e1"));
    sd.drainCompletedForResolution();
    var again = sd.drainCompletion().?;
    again.deinit(a);
    try testing.expectEqual(@as(usize, 1), sd.set.resolvingCount());
}

test "materialize: owned intents survive the source writeset, deinit frees" {
    const a = testing.allocator;
    var ws = kv_mod.WriteSet.init(a);
    try ws.addPut("_send/owed/s1", "ob");
    try ws.addPut("_send/proof/s0", "pb");
    var out: std.ArrayListUnmanaged(OwnedIntent) = .empty;
    defer {
        for (out.items) |*i| i.deinit(a);
        out.deinit(a);
    }
    try materialize(&ws, "tenant-9", a, &out);
    ws.deinit(); // source gone — owned copies must stand alone
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("s1", out.items[0].arm.id);
    try testing.expectEqualStrings("tenant-9", out.items[0].arm.tenant_id);
    try testing.expectEqualStrings("ob", out.items[0].arm.owed);
    try testing.expectEqualStrings("s0", out.items[1].resolve);
}

test "classify on a writeset with no _send ops yields nothing" {
    const a = testing.allocator;
    var ws = kv_mod.WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("k", "v");
    try ws.addDelete("k2");
    var out: std.ArrayListUnmanaged(SendIntent) = .empty;
    defer out.deinit(a);
    try classify(&ws, a, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "arm then resolve via sync drain" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    const ob = try encOwed(a, 0);
    defer a.free(ob);
    try sd.enqueueArm("id-1", "tenant-1", ob);
    try sd.enqueueArm("id-2", "tenant-1", ob);
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 2), sd.set.armedCount());
    try testing.expect(sd.set.getById("id-1") != null);

    try sd.enqueueResolve("id-1");
    try sd.enqueueResolve("ghost"); // idempotent: unknown id no-ops
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 1), sd.set.armedCount());
    try testing.expect(sd.set.getById("id-1") == null);
    try testing.expect(sd.set.getById("id-2") != null);
}

test "duplicate arm id is deduped (existing wins), no leak" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    const ob = try encOwed(a, 0);
    defer a.free(ob);
    try sd.enqueueArm("dup", "t", ob);
    try sd.enqueueArm("dup", "t", ob);
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 1), sd.set.armedCount());
}

test "malformed owed bytes are dropped, not fatal, no leak" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    try sd.enqueueArm("bad", "t", "not-a-valid-owed-encoding");
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 0), sd.set.armedCount());
}

const LeaderFlag = struct {
    v: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn read(ctx: ?*anyopaque) bool {
        const self: *LeaderFlag = @ptrCast(@alignCast(ctx.?));
        return self.v.load(.acquire);
    }
};

test "4b-iv (FORK-6'): demotion KEEPS armed (collapse firing phases), queue untouched" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    var flag: LeaderFlag = .{};
    sd.configure(&flag, LeaderFlag.read, null, null);

    const ob = try encOwed(a, 0);
    defer a.free(ob);

    // Not leader: drain still applies (ops only ever arrive on the
    // leader under single-raft; ungated drain keeps 4b-i valid +
    // is exactly the follower-feed path in FORK-6').
    try sd.enqueueArm("n1", "t", ob);
    try sd.enqueueArm("n2", "t", ob);
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 2), sd.set.armedCount());
    _ = try sd.set.markFiring(a, "n2"); // n2 inflight (we were leader)
    try testing.expectEqual(@as(usize, 1), sd.set.inflightCount());

    // Demotion edge: FORK-6' KEEPS the set — inflight collapses back
    // to armed (re-fireable on re-promotion; at-least-once), nothing
    // freed, queue NOT cleared.
    sd.was_leader = true;
    flag.v.store(false, .release);
    if (!sd.isLeader() and sd.was_leader) sd.onDemotion();
    sd.was_leader = false;
    try testing.expectEqual(@as(usize, 2), sd.set.armedCount()); // n1 + n2 (rehomed)
    try testing.expectEqual(@as(usize, 0), sd.set.inflightCount());
    try testing.expect(sd.set.getById("n1") != null);
    try testing.expect(sd.set.getById("n2") != null);

    // A pending queued op survives demotion (drain is ungated).
    try sd.enqueueArm("n3", "t", ob);
    sd.was_leader = true;
    if (!sd.isLeader() and sd.was_leader) sd.onDemotion();
    sd.ops_mutex.lock();
    const qlen = sd.ops.items.len;
    sd.ops_mutex.unlock();
    try testing.expectEqual(@as(usize, 1), qlen); // NOT cleared
    sd.drainSyncForTesting();
    try testing.expectEqual(@as(usize, 3), sd.set.armedCount());
}

// (4c-ii-A fire-guard test removed at 5b-1 — the guard is retired;
//  Option (b) fires unconditionally on leader.)

test "4b-iv: cold-start boot-scan runs only on first promotion" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    const Rec = struct {
        n: usize = 0,
        fn cb(ctx: ?*anyopaque, _: *SendDispatch) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.n += 1;
        }
    };
    var rec: Rec = .{};
    var flag: LeaderFlag = .{};
    sd.configure(&flag, LeaderFlag.read, &rec, Rec.cb);

    // Drive promotion/demotion edges by hand (threadMain's logic).
    const step = struct {
        fn run(s: *SendDispatch) void {
            const leader = s.isLeader();
            if (leader and !s.was_leader) {
                if (!s.cold_recovered) {
                    if (s.recover_fn) |rf| rf(s.recover_ctx, s);
                    s.cold_recovered = true;
                }
            } else if (!leader and s.was_leader) s.onDemotion();
            s.was_leader = leader;
        }
    }.run;

    flag.v.store(true, .release);
    step(sd); // first promotion → recover
    try testing.expectEqual(@as(usize, 1), rec.n);
    flag.v.store(false, .release);
    step(sd); // demote
    flag.v.store(true, .release);
    step(sd); // re-promote → warm, NO recover
    flag.v.store(false, .release);
    step(sd);
    flag.v.store(true, .release);
    step(sd); // again → still no recover
    try testing.expectEqual(@as(usize, 1), rec.n); // only the first
}

test "4b-iii-B: armFromParts arms from borrowed input, dedups, drops malformed" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    const ob = try encOwed(a, 0);
    defer a.free(ob);

    sd.armFromParts("r1", "tenant-x", ob);
    try testing.expectEqual(@as(usize, 1), sd.set.armedCount());
    const e = sd.set.getById("r1").?;
    try testing.expectEqualStrings("tenant-x", e.tenant_id);

    // dedup: a re-scan / concurrent live-feed of the same id — first
    // wins, the second copy is freed (no leak under testing.allocator).
    sd.armFromParts("r1", "tenant-x", ob);
    try testing.expectEqual(@as(usize, 1), sd.set.armedCount());

    // malformed owed bytes: dropped, non-fatal, no leak.
    sd.armFromParts("r2", "tenant-x", "garbage");
    try testing.expectEqual(@as(usize, 1), sd.set.armedCount());
}

test "background thread drains + responds to shutdown; deinit frees unprocessed" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    try sd.start();
    const ob = try encOwed(a, 0);
    defer a.free(ob);
    try sd.enqueueArm("bg-1", "t", ob);
    try sd.enqueueArm("bg-2", "t", ob);

    var spins: u32 = 0;
    while (spins < 200) : (spins += 1) {
        sd.ops_mutex.lock();
        const drained = sd.ops.items.len == 0;
        sd.ops_mutex.unlock();
        if (drained) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    sd.shutdown(); // thread joined → safe to read `set`
    try testing.expectEqual(@as(usize, 2), sd.set.armedCount());
}

test "4c-ii-B/iii-B-1: end-to-end (offline) — armed→inflight→completed→resolving + receipt" {
    const a = testing.allocator;
    const sd = try SendDispatch.init(a);
    defer sd.deinit();

    var flag: LeaderFlag = .{};
    flag.v.store(true, .release); // leader
    sd.configure(&flag, LeaderFlag.read, null, null);
    // 5b-1: guard retired — fires on leader (flag=true) unconditionally.

    try sd.start();
    // "not a url" → fireOnce fails in checkSsrf BEFORE any network
    // (deterministic, offline): exercises the whole pipeline —
    // scan→markFiring→fire-pool→fireOnce→drainResults→markCompleted
    // →drainCompletedForResolution→markResolving + Completion.
    const ob = try encOwedUrl(a, "not a url", 0);
    defer a.free(ob);
    try sd.enqueueArm("e1", "tnt", ob);

    // resolution_pushed is the terminal thread-safe edge (it strictly
    // follows completed_total): wait on it to avoid the
    // completed→resolving race a completed_total-only wait had.
    var spins: u32 = 0;
    while (sd.resolutionPushedTotal() < 1 and spins < 2000) : (spins += 1)
        std.Thread.sleep(1 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 1), sd.completedTotal());
    try testing.expectEqual(@as(u64, 1), sd.resolutionPushedTotal());

    sd.shutdown(); // all threads joined → safe to read `set`
    // End state: pushed once for resolution (NOT left in completed —
    // 4c-iii-B-1 push-once), the entry awaiting its proof in
    // `resolving`, and a receipt handed to the (would-be) worker.
    try testing.expectEqual(@as(usize, 0), sd.set.completedCount());
    try testing.expectEqual(@as(usize, 1), sd.set.resolvingCount());
    try testing.expectEqual(@as(usize, 0), sd.set.armedCount());
    const e = sd.set.getById("e1").?;
    try testing.expect(e.result != null);
    try testing.expectEqual(false, e.result.?.ok);
    try testing.expectEqual(@as(u16, 0), e.result.?.status);
    try testing.expectEqualStrings("invalid url", e.result.?.err);
    var comp = sd.drainCompletion().?;
    defer comp.deinit(a);
    try testing.expectEqualStrings("tnt", comp.tenant_id);
    try testing.expectEqualStrings("e1", comp.callback_id);
    var p = try std.json.parseFromSlice(std.json.Value, a, comp.receipt, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    try testing.expectEqual(false, p.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("invalid url", p.value.object.get("error").?.string);
}
