// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `Dispatcher` — runs one JS handler against a request.
//!
//! Each `Dispatcher` owns a `qjs.Snapshot` (an arenajs dual-arena
//! runtime+context), built once at construction time with all static
//! rove-js globals installed in base (kv, console, crypto, Date.now
//! override, Math.random override). Per request, `run` calls
//! `snapshot.restore()` — one cursor-write reset of the request
//! arena (~9 ns) plus reseeding time/random — installs the
//! per-request `request`/`response` globals, and evaluates the
//! handler bytecode. Nothing allocated by the handler needs to be
//! freed; the next reset wipes the request arena. The base arena is
//! page-protected immortal: all per-request handlers on this thread
//! share it without copying.

const std = @import("std");
const reserved = @import("rove-reserved");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const tape_mod = @import("rove-tape");
const tenant_mod = @import("rove-tenant");
const h2 = @import("rove-h2");
const log_mod = @import("rove-log");
const rove = @import("rove");

const globals = @import("globals.zig");
const request_mod = @import("request.zig");
const rpc_dispatch = @import("rpc_dispatch.zig");
const response_building = @import("response_building.zig");
const module_execution = @import("module_execution.zig");
const PendingResponse = module_execution.PendingResponse;
const bytecode_cache_mod = @import("bytecode_cache.zig");
const BlobBytes = bytecode_cache_mod.BlobBytes;
const limiter_mod = @import("limiter.zig");
const continuation_mod = @import("bindings/continuation.zig");
const stream_mod = @import("bindings/stream.zig");
const components_mod = @import("components.zig");
const c = qjs.c;

/// The JS engine version every `Dispatcher`'s snapshot embodies
/// (`qjs/version.zig`). Re-exported here so dispatch/drain code stamps
/// one canonical constant into each request's readset
/// (`docs/architecture/format-versioning.md` §4) without each file importing
/// `rove-qjs` directly. One engine per binary, so this equals every
/// live `Dispatcher.snapshot.version`.
pub const JS_ENGINE_VERSION = qjs.JS_ENGINE_VERSION;

pub const DispatchError = error{
    JsException,
    /// A `kv.*` call raised an error that wasn't a plain NotFound. The
    /// underlying `KvError` is available on the dispatcher.
    KvFailed,
    OutOfMemory,
    /// qjs runtime/context construction failed.
    RuntimeCreateFailed,
    ContextCreateFailed,
    /// Handler exceeded its CPU / wall-clock budget and was interrupted
    /// via `JS_SetInterruptHandler`. Distinguished from `JsException` so
    /// the worker can feed the event into the penalty box / circuit
    /// breaker instead of treating it as a normal handler error.
    Interrupted,
};

/// Per-request execution budget. Handed to the QuickJS interrupt handler
/// via its opaque ctx pointer; the handler polls the deadline every ~256
/// bytecode ops and returns 1 when exceeded, causing qjs to throw an
/// uncatchable InternalError into the handler.
///
/// `deadline_ns` is wall-clock (monotonic), not CPU time — simpler, and
/// a runaway JS loop burns wall and CPU in lockstep anyway. Deterministic
/// tape replay may instead want a cutoff by `bytecode_op_count`; the
/// `tick_count` field below leaves room for that.
pub const Budget = struct {
    deadline_ns: i64,
    /// Incremented on every interrupt-handler tick. Reserved for
    /// deterministic tape replay to clamp on instead of the deadline,
    /// so replay cuts off at the same logical point as the original run.
    tick_count: u64 = 0,

    /// Per-request wall-clock budget for customer handlers. Fires
    /// QuickJS's interrupt handler when exceeded so a runaway handler
    /// can't pin a worker. 1s covers a few sync kv writes (each
    /// raft-replicated, ~5-50ms) plus pure-CPU work; everything past
    /// that is genuinely abusive. The penalty box (`penalty.zig`)
    /// adds back-pressure if a single instance trips this budget
    /// repeatedly inside the box's window.
    pub const default_duration_ns: i64 = 1 * std.time.ns_per_s;

    /// Larger budget for `__admin__` requests. Signup + deploy on the
    /// admin tenant blocks on S3 PUTs (compile + upload starter
    /// content); each PUT is ~100-300ms RTT and a fresh tenant
    /// uploads a handful of files. 10s gives real headroom for that
    /// path without forcing every customer request to share the same
    /// (much larger) budget.
    pub const admin_duration_ns: i64 = 10 * std.time.ns_per_s;

    pub fn fromNow(duration_ns: i64) Budget {
        return .{ .deadline_ns = @as(i64, @intCast(std.time.nanoTimestamp())) + duration_ns };
    }
};

fn interruptHandler(_: ?*c.JSRuntime, opaque_ctx: ?*anyopaque) callconv(.c) c_int {
    const budget: *Budget = @ptrCast(@alignCast(opaque_ctx.?));
    budget.tick_count += 1;
    const now: i64 = @intCast(std.time.nanoTimestamp());
    return if (now >= budget.deadline_ns) 1 else 0;
}

/// The request data model lives in `request.zig`; re-exported here so
/// every existing `dispatcher.{Request,Response,RunOutcome,...}`
/// reference keeps resolving.
pub const ActivationSource = request_mod.ActivationSource;
pub const SubscriptionFireSource = request_mod.SubscriptionFireSource;
pub const Activation = request_mod.Activation;

pub const Request = request_mod.Request;
/// Re-exported beside `Request` so a worker can name the cluster it builds.
pub const Trampolines = request_mod.Trampolines;
pub const Trace = request_mod.Trace;
pub const ResponseHeader = request_mod.ResponseHeader;
pub const Response = request_mod.Response;
pub const RunOutcome = request_mod.RunOutcome;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    /// Per-dispatcher frozen runtime+context. Built once in `init`,
    /// the base arena is page-protected immortal; each `run` resets
    /// the per-request arena via a single cursor write before
    /// evaluating the handler.
    snapshot: qjs.Snapshot,
    /// Last `kv.*` error surfaced from a JS call during the most recent
    /// `run`. Useful for tests and for the worker to log root causes.
    last_kv_error: ?anyerror = null,

    /// Arena regime the most recent `runOutcome` COMPLETED under
    /// (same read-after pattern as `last_kv_error`): `.gc` means either
    /// the worker's churny hint or a bump-OOM retry. Stamped into the
    /// LogRecord so replay re-runs under the same regime.
    last_arena_mode: qjs.snap.ReqMode = .bump,
    /// True iff the most recent `runOutcome` OOMed under bump and was
    /// re-executed under GC — the worker's churny-map trigger.
    last_arena_gc_retry: bool = false,

    fn snapshotInitFn(
        rt: *c.JSRuntime,
        ctx: *c.JSContext,
        _: ?*anyopaque,
    ) qjs.snap.Error!void {
        _ = rt;
        // Selective intrinsics keep the base arena small. With arenajs
        // there's no per-request memcpy cost (base is shared in place
        // across all requests), so the optimization is now about base
        // memory + freeze-time work, not per-request bandwidth.
        // Skipping WeakRef / DOMException / Proxy saves 20-30 KB with
        // essentially no loss — handlers that genuinely need them can
        // be added back.
        _ = c.JS_AddIntrinsicBaseObjects(ctx);
        _ = c.JS_AddIntrinsicDate(ctx);
        _ = c.JS_AddIntrinsicEval(ctx);
        _ = c.JS_AddIntrinsicRegExp(ctx);
        _ = c.JS_AddIntrinsicJSON(ctx);
        _ = c.JS_AddIntrinsicMapSet(ctx);
        _ = c.JS_AddIntrinsicTypedArrays(ctx);
        _ = c.JS_AddIntrinsicPromise(ctx);
        _ = c.JS_AddIntrinsicBigInt(ctx);
        globals.installStatic(ctx);
    }

    pub fn init(allocator: std.mem.Allocator) !Dispatcher {
        return initWithSizes(allocator, .{});
    }

    /// `init` with explicit arena sizes — tests exercising the arena
    /// OOM/retry path use a small request arena so the churny loop
    /// stays fast.
    pub fn initWithSizes(allocator: std.mem.Allocator, sizes: qjs.snap.Sizes) !Dispatcher {
        const snapshot = try qjs.Snapshot.create(sizes, snapshotInitFn, null);
        return .{
            .allocator = allocator,
            .snapshot = snapshot,
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.snapshot.deinit();
        self.* = undefined;
    }

    /// Run pre-compiled `bytecode` as a handler against `request`.
    /// Reads hit `kv` directly — the same SQLite connection the
    /// caller's `TrackedTxn` opened, so reads see the txn's own
    /// uncommitted writes. `kv.set`/`kv.delete` from the handler go
    /// through `txn` (local durability + undo) AND `writeset` (raft
    /// replication).
    ///
    /// The handler contract:
    ///   - `bytecode` MUST be an ES module. Non-module bytecode is a
    ///     hard error (500).
    ///   - The invoked export is the resume path's first-class target
    ///     (`Request.fn_override`) or the activation kind's
    ///     conventional export (`rpc_dispatch.parseDispatch`); customer
    ///     `?fn=`/`{fn,args}` shapes are opaque payload, not interpreted
    ///     as export selectors (decisions.md §4.5).
    ///   - The invoked export gets no positional arguments — resume
    ///     payloads (ctx / outcome) ride `Request.body` and the
    ///     `Request.activation` union, read through the request surface.
    ///   - The handler's **return value** becomes the response body
    ///     (strings emit as-is; everything else is `JSON.stringify`'d).
    ///   - Status / headers / cookies flow through the ambient
    ///     `response` global (`response.status = 404`, etc.). Body is
    ///     NOT settable via `response` — it always comes from return.
    ///
    /// `bytecodes` is the per-deployment map of path → bytecode lease
    /// (`*BlobBytes` from `worker.BytecodeCache`) used by the module
    /// loader to resolve `import` statements the entry module pulls
    /// in. `null` is valid if the entry has no imports.
    /// The dispatch core. `run` (returns `Response`, collapsing
    /// `.continuation`→501) wraps this; the continuation-aware worker
    /// path calls `runOutcome` directly. The split keeps every `run`
    /// call site unchanged while exposing the trampoline outcome where
    /// it's needed.
    /// One dispatch attempt under an explicit arena regime. The
    /// public `runOutcome` wraps this with the bump→GC OOM retry.
    fn runOutcomeAttempt(
        self: *Dispatcher,
        kv: *kv_mod.KvStore,
        txn: *kv_mod.TrackedTxn,
        writeset: *kv_mod.WriteSet,
        bytecode: []const u8,
        bytecodes: ?*const std.StringHashMapUnmanaged(*BlobBytes),
        source_hashes: ?*const std.StringHashMapUnmanaged([64]u8),
        resolver: ?*const module_execution.PackageResolver,
        hooks: ?*const globals.DeployHooks,
        deployment_id: u64,
        request: Request,
        budget: *Budget,
        mode: qjs.snap.ReqMode,
        side_effects: *bool,
    ) DispatchError!RunOutcome {
        self.last_kv_error = null;

        var console_buf: std.ArrayList(u8) = .empty;
        errdefer console_buf.deinit(self.allocator);

        // Per-dispatch user-tag accumulator (`tag`). Owned here
        // like `console_buf`; `finishResponse` MOVES the tags onto the
        // Response/Continuation (so they survive a `next()`), or frees
        // them on the drop paths. The errdefer covers error returns
        // before that hand-off (e.g. kv_error).
        var tags_buf: std.ArrayList(log_mod.Tag) = .empty;
        errdefer freeTagsBuf(self.allocator, &tags_buf);

        // The activation's shred identity and the slot it resolved to.
        // Owned here for the same reason `tags_buf` is: they belong to
        // one activation, and a batch's other activations may name
        // different identities (or none).
        var shred_key_cell: ?[]u8 = null;
        defer if (shred_key_cell) |k| self.allocator.free(k);
        var shred_slot_cell: ?u64 = null;
        var shred_destroys_cell: usize = 0;

        var state = globals.DispatchState{
            .allocator = self.allocator,
            .kv = kv,
            .txn = txn,
            .writeset = writeset,
            // The writesets are batch-scoped; the read-your-write tape
            // elision is activation-scoped (see `ws_base`). Captured here —
            // after a failed attempt's rollback truncates the writeset, a
            // retry recaptures the same baseline.
            .ws_base = writeset.ops.items.len,
            .deployment_id = deployment_id,
            .console = &console_buf,
            .tags = &tags_buf,
            .shred_key = &shred_key_cell,
            .shred_slot = &shred_slot_cell,
            .shred_destroys = &shred_destroys_cell,
            .shred = request.shred,
            .shred_instance_id = request.shred_instance_id,
            .readset = request.trace.readset,
            // Deterministic replay (`docs/architecture/replay-and-sim.md`): arenajs's per-request
            // xorshift64star state is the single PRNG (no Zig-side
            // PRNG); seeded by `installRequest` from
            // `state.readset.?.seed`.
            .request_id = request.trace.request_id,
            .session_id = request.session_id,
            .platform = request.admin.platform,
            .triggers = if (hooks) |h| h.triggers else null,
            .subscriptions = if (hooks) |h| h.subscriptions else &.{},
            .bytecodes = bytecodes,
            .limiter = request.plan.limiter,
            .instance_id = if (request.plan.storage) |st| st.id else "",
            .storage = request.plan.storage,
            .plan_rate = request.plan.plan_rate,
            .plan_gen = request.plan.plan_gen,
            .blob_cfg = request.plan.blob_cfg,
            .saga_id = request.trace.saga_id orelse "",
            .platform_caps = request.admin.platform_caps,
            .resume_if_bound = request.trampolines.resume_if_bound,
            .cancel_fetch = request.trampolines.cancel_fetch,
            .set_wake = request.trampolines.set_wake,
            .worker_ctx = request.trampolines.worker_ctx,
            .platform_dispatch = request.trampolines.platform_dispatch,
            .set_wake_ctx = request.trampolines.set_wake_ctx,
            .fire_wake = request.trampolines.fire_wake,
            .blob_write = request.trampolines.blob_write,
            .blob_seal = request.trampolines.blob_seal,
            .activation_entity = request.activation_entity,
            .activation_fetches_pending = request.activation_fetches_pending,
            .allow_blob_receive = request.activation == .inbound_headers,
            .pending_fetches = request.effects.pending_fetches,
            .pending_wakes = request.effects.pending_wakes,
            .pending_stream_chunks = request.effects.pending_stream_chunks,
            .pending_stream_chunk_opcodes = request.effects.pending_stream_chunk_opcodes,
            // `stream.write` means a WS frame (→ .continuation, not the
            // HTTP cont→stream transition) whenever output goes to a WS
            // socket: a `ws_message` activation, OR a bound-fetch resume on
            // a held WS chain (which wires the WS opcode accumulator —
            // `resumeBoundFetchChainWs`). HTTP fetch resumes leave the
            // opcodes null and keep the `.stream` transition.
            .ws_frame_output = request.activation == .ws_message or
                request.effects.pending_stream_chunk_opcodes != null,
            .is_system_module = request.is_system_module,
            .side_effects_flag = side_effects,
            .parent_saga = request.trace.parent_saga,
        };

        // Reset the per-request arena and reseed time/random. The base
        // arena (runtime, intrinsics, globals) is shared in place across
        // all requests on this thread — no memcpy, no relocation. The
        // regime is per-attempt: bump for speed, GC for churny handlers.
        const restored = self.snapshot.restoreMode(mode);
        var rt: qjs.Runtime = restored.runtime;
        var ctx: qjs.Context = restored.context;
        // Free any trigger-module namespaces we cached during this
        // request. The request arena reset wipes the QJS-side state;
        // Zig-side hashmap entries (key + JSValue ref counts) need
        // explicit cleanup.
        defer state.deinit(ctx.raw);

        rt.setInterruptHandler(interruptHandler, budget);

        // Install the module loader for this request. Reads bytecode
        // for any `import` the handler performs from the deployment's
        // per-path map. Reinstalled per request so each request sees
        // its own tenant's bytecodes.
        var loader_ctx = module_execution.module_loader.Ctx{
            .allocator = self.allocator,
            .bytecodes = bytecodes,
            .source_hashes = source_hashes,
            .module_tape = if (request.trace.readset) |rs| &rs.module else null,
            .resolver = resolver,
        };
        c.JS_SetModuleLoaderFunc(
            rt.raw,
            module_execution.module_loader.normalize,
            module_execution.module_loader.load,
            &loader_ctx,
        );

        const activation = globals.installRequest(ctx.raw, &state, request);
        defer c.JS_FreeValue(ctx.raw, activation);

        var pending: PendingResponse = .{};
        errdefer pending.deinit(self.allocator);

        // Optional `_middlewares/index.mjs` runs before the handler
        // in the same QJS context. Mutations it makes to globalThis
        // — most usefully `request.auth = {...}` — persist into the
        // handler's call. If the middleware returns any non-undefined
        // value, the dispatcher short-circuits with that value as the
        // body and skips the handler. Return undefined / fall off the
        // end → continue.
        //
        // `__system/` built-in modules SKIP middleware.
        // They're the platform's own bookkeeping (e.g. the baked
        // `__system/webhook_onresult` shim that runs as a fetch_chunk
        // activation in the issuing tenant). A tenant's middleware
        // can't gate the platform — e.g. `__admin__`'s OIDC-RP
        // middleware returns 401 for any path not on its PRE_AUTH
        // list, which short-circuits the shim before it can delete
        // the `_send/owed/` marker → sweep re-fires forever. System
        // modules are trusted; middleware doesn't apply.
        const mw_bytecode_opt: ?[]const u8 = blk: {
            if (request.is_system_module) break :blk null;
            // Continuations (callbacks, wakes, held-stream lifecycle) resume a
            // handler's own async work behind the gate the inbound request
            // already passed — running the auth middleware on them re-gates and
            // 401s the tenant's own callbacks (`Activation.isContinuation`).
            if (request.activation.isContinuation()) break :blk null;
            // `.mjs` only. A `.js` is not a deployable handler source anywhere
            // in the pipeline — the CLI does not ship one and the compiler
            // builds `.js` as a classic script, so `export` is a syntax error —
            // and a `.js` fallback here could only ever match bytecode no
            // supported path can produce.
            if (bytecodes) |bcs| {
                if (bcs.get("_middlewares/index.mjs")) |bb| break :blk bb.bytes;
            }
            break :blk null;
        };
        if (mw_bytecode_opt) |mw_bc| {
            const mw_fun_val = (try module_execution.loadModuleBytecode(&ctx, self.allocator, mw_bc, &pending, "_middlewares/index.mjs is not an ES module")) orelse
                return finishResponse(self, &state, &pending, &console_buf, &tags_buf);
            module_execution.runMiddleware(self, &rt, &ctx, mw_fun_val, activation, budget, &pending) catch |err| switch (err) {
                error.Interrupted => return DispatchError.Interrupted,
                error.OutOfMemory => return DispatchError.OutOfMemory,
                error.JsException => pending.short_circuit = true,
            };
        }

        if (pending.short_circuit) {
            return finishResponse(self, &state, &pending, &console_buf, &tags_buf);
        }

        const fun_val = (try module_execution.loadModuleBytecode(&ctx, self.allocator, bytecode, &pending, "handler bytecode is not an ES module (.mjs)")) orelse
            return finishResponse(self, &state, &pending, &console_buf, &tags_buf);

        module_execution.runModule(self, &rt, &ctx, fun_val, request, activation, budget, &pending) catch |err| switch (err) {
            error.Interrupted => return DispatchError.Interrupted,
            error.OutOfMemory => return DispatchError.OutOfMemory,
            error.JsException => {}, // pending.exception already populated
        };

        return finishResponse(self, &state, &pending, &console_buf, &tags_buf);
    }

    /// Run one activation, with the arena-OOM fallback: attempt under
    /// the bump regime (or GC directly when the worker's churny map
    /// says so via `request.arena_mode`); if the bump attempt exhausts
    /// the request arena, discard it wholesale — savepoint-rolled kv
    /// staging, attempt-scoped readset tapes, effect accumulators —
    /// and re-execute once under GC (ceiling = peak live set instead
    /// of cumulative allocation). Re-execution is safe because a
    /// failed attempt is pre-commit and deterministic (same seed,
    /// same pinned clock, same inputs); the ONE exception is an
    /// attempt that fired an immediate worker-side effect
    /// (blob streaming, cancel_fetch, fire_wake, resume_if_bound) —
    /// those don't retry.
    ///
    /// After return, `last_arena_mode` / `last_arena_gc_retry` say
    /// what happened (the worker's churny-map + LogRecord inputs).
    pub fn runOutcome(
        self: *Dispatcher,
        kv: *kv_mod.KvStore,
        txn: *kv_mod.TrackedTxn,
        writeset: *kv_mod.WriteSet,
        bytecode: []const u8,
        bytecodes: ?*const std.StringHashMapUnmanaged(*BlobBytes),
        source_hashes: ?*const std.StringHashMapUnmanaged([64]u8),
        resolver: ?*const module_execution.PackageResolver,
        hooks: ?*const globals.DeployHooks,
        /// The deployment whose bytecode this is — what resolves the
        /// `_config/` namespace, so a handler reads the config that shipped
        /// WITH its code (`reserved.configStorageKey`). Required rather than
        /// defaulted: zero means "authored world, no release", and a served
        /// activation that quietly passed zero would read another
        /// deployment's config and look like it worked.
        deployment_id: u64,
        request: Request,
        budget: *Budget,
    ) DispatchError!RunOutcome {
        self.last_arena_gc_retry = false;
        const first_mode: qjs.snap.ReqMode = if (request.arena_mode == .gc) .gc else .bump;
        self.last_arena_mode = first_mode;
        // The writeset is shared across a batch — a discarded attempt
        // may only drop ITS OWN contribution.
        const ws_ops_start = writeset.ops.items.len;
        const ws_owned_start = writeset.owned.items.len;

        // Savepoint so a doomed bump attempt's staged kv writes drop
        // wholesale (attempt 2 must not read attempt 1's writes — the
        // read-your-writes overlay would corrupt e.g. counters). If the
        // savepoint can't open, run single-attempt: correctness never
        // depends on the retry.
        var sp_open = true;
        txn.savepoint() catch {
            sp_open = false;
        };

        var side_effects = false;
        const first = self.runOutcomeAttempt(kv, txn, writeset, bytecode, bytecodes, source_hashes, resolver, hooks, deployment_id, request, budget, first_mode, &side_effects);

        // The arena's exhaustion record is the capacity-vs-user-error
        // discriminator; it survives until the NEXT reset, so read it
        // here, before any further restore.
        const oomed = self.snapshot.oomHit();
        if (first_mode == .bump and oomed and sp_open and !side_effects) retry: {
            const stats = self.snapshot.oomStats();
            // Roll the doomed attempt's staging back FIRST — if this
            // fails we must return the original outcome untouched.
            txn.rollbackTo() catch break :retry;
            std.log.warn(
                "rove-js arena-oom: bump attempt exhausted the request arena (requested={d} used={d} limit={d}); re-executing under GC (churny handler)",
                .{ stats.requested, stats.used, stats.limit },
            );
            // Discard everything attempt 1 produced.
            if (first) |*outcome_const| {
                var outcome = outcome_const.*;
                discardOutcome(self.allocator, &outcome);
            } else |_| {}
            if (request.trace.readset) |rs| rs.resetAttempt();
            clearAttemptEffects(self.allocator, request);
            writeset.truncateTo(ws_ops_start, ws_owned_start);

            txn.savepoint() catch {
                sp_open = false;
            };
            self.last_arena_mode = .gc;
            self.last_arena_gc_retry = true;
            var side_effects2 = false;
            const second = self.runOutcomeAttempt(kv, txn, writeset, bytecode, bytecodes, source_hashes, resolver, hooks, deployment_id, request, budget, .gc, &side_effects2);
            // Even the GC regime (ceiling = peak live set) can be too
            // small for a genuinely huge request. If it OOM'd too, the
            // outcome is a mangled/empty terminal — DON'T return it as a
            // silent success; fail loud (decisions.md §4.12 + the
            // fail-loud-on-resource-exhaustion rule).
            if (self.snapshot.oomHit()) {
                const stats2 = self.snapshot.oomStats();
                std.log.warn(
                    "rove-js arena-oom: GC re-execution ALSO exhausted the arena (requested={d} used={d} limit={d}) — failing loud (500)",
                    .{ stats2.requested, stats2.used, stats2.limit },
                );
                dropDoomedOutcome(self.allocator, second, request, writeset, ws_ops_start, ws_owned_start);
                if (sp_open) txn.release() catch {};
                self.stampArenaMode(request);
                return self.oomFailureOutcome();
            }
            if (sp_open) txn.release() catch {};
            self.stampArenaMode(request);
            return second;
        }
        if (oomed) {
            // OOM that the GC retry couldn't rescue: the bump attempt
            // fired an immediate worker-side effect (retry vetoed) or no
            // savepoint was open. Its outcome is mangled/empty — surface
            // a clean 500 rather than the silent empty body it would
            // otherwise produce (the OOM-swallowing bug).
            const stats = self.snapshot.oomStats();
            std.log.warn(
                "rove-js arena-oom: request arena exhausted (requested={d} used={d} limit={d}), not retryable (immediate side effects or no savepoint) — failing loud (500)",
                .{ stats.requested, stats.used, stats.limit },
            );
            dropDoomedOutcome(self.allocator, first, request, writeset, ws_ops_start, ws_owned_start);
            if (sp_open) txn.release() catch {};
            self.stampArenaMode(request);
            return self.oomFailureOutcome();
        }
        if (sp_open) txn.release() catch {};
        self.stampArenaMode(request);
        return first;
    }

    /// The loud terminal returned when the request arena is exhausted
    /// and neither the bump nor the GC regime could complete it. A
    /// non-empty `exception` makes every dispatch site emit a 5xx (the
    /// worker turns it into a 500) — never the silent empty 200 a
    /// mangled OOM outcome otherwise yields. Strings come from the
    /// dispatcher allocator, NOT the exhausted JS arena.
    fn oomFailureOutcome(self: *Dispatcher) DispatchError!RunOutcome {
        return .{ .terminal = .{
            .status = 500,
            .body = try self.allocator.dupe(u8, ""),
            .body_is_json = false,
            .console = try self.allocator.dupe(u8, ""),
            .exception = try self.allocator.dupe(u8, "handler exhausted the request memory arena (OOM)"),
        } };
    }

    /// Discard a doomed OOM attempt's outputs before returning a loud
    /// failure: free the mangled outcome, roll back the attempt-scoped
    /// readset/effects, and truncate the batch-shared writeset to this
    /// attempt's boundary (a wholesale clear would eat sibling
    /// handlers' ops).
    fn dropDoomedOutcome(
        allocator: std.mem.Allocator,
        outcome: DispatchError!RunOutcome,
        request: Request,
        writeset: *kv_mod.WriteSet,
        ws_ops_start: usize,
        ws_owned_start: usize,
    ) void {
        if (outcome) |*oc_const| {
            var oc = oc_const.*;
            discardOutcome(allocator, &oc);
        } else |_| {}
        if (request.trace.readset) |rs| rs.resetAttempt();
        clearAttemptEffects(allocator, request);
        writeset.truncateTo(ws_ops_start, ws_owned_start);
    }

    /// Record the regime the request COMPLETED under on the readset's
    /// engine word (`ENGINE_ARENA_GC_BIT`) — the LogRecord/bundle pick
    /// it up from there and replay re-runs under the same regime.
    fn stampArenaMode(self: *Dispatcher, request: Request) void {
        if (self.last_arena_mode != .gc) return;
        if (request.trace.readset) |rs| {
            rs.js_engine_version |= qjs.ENGINE_ARENA_GC_BIT;
        }
    }

    /// Free whatever a discarded attempt's outcome owns.
    fn discardOutcome(allocator: std.mem.Allocator, outcome: *RunOutcome) void {
        switch (outcome.*) {
            .terminal => |*r| r.deinit(allocator),
            .continuation => |*cont| cont.deinit(allocator),
            .stream => |*s| s.deinit(allocator),
            .no_onheaders, .no_onchunk => {},
        }
    }

    /// Clear the caller-owned effect accumulators a discarded attempt
    /// pushed into (the worker drains these post-outcome; a retry
    /// must not double them).
    fn clearAttemptEffects(allocator: std.mem.Allocator, request: Request) void {
        if (request.effects.pending_fetches) |pf| {
            for (pf.items) |*item| item.deinit(allocator);
            pf.clearRetainingCapacity();
        }
        if (request.effects.pending_wakes) |pw| {
            for (pw.items) |*item| item.deinit(allocator);
            pw.clearRetainingCapacity();
        }
        if (request.effects.pending_stream_chunks) |pc| {
            for (pc.items) |chunk| allocator.free(chunk);
            pc.clearRetainingCapacity();
        }
        if (request.effects.pending_stream_chunk_opcodes) |po| {
            po.clearRetainingCapacity();
        }
    }

    /// Dispatch that runs and collapses a `.continuation` to a terminal
    /// 501. A continuation arriving here is an EXPECTED condition (a
    /// customer used `next(...)` before the resume path exists), not an
    /// infallibility violation — graceful 501, never panic
    /// (`feedback_infallibility_violations`).
    pub fn run(
        self: *Dispatcher,
        kv: *kv_mod.KvStore,
        txn: *kv_mod.TrackedTxn,
        writeset: *kv_mod.WriteSet,
        bytecode: []const u8,
        bytecodes: ?*const std.StringHashMapUnmanaged(*BlobBytes),
        source_hashes: ?*const std.StringHashMapUnmanaged([64]u8),
        resolver: ?*const module_execution.PackageResolver,
        hooks: ?*const globals.DeployHooks,
        deployment_id: u64,
        request: Request,
        budget: *Budget,
    ) DispatchError!Response {
        var outcome = try self.runOutcome(kv, txn, writeset, bytecode, bytecodes, source_hashes, resolver, hooks, deployment_id, request, budget);
        switch (outcome) {
            .terminal => |r| return r,
            .continuation => |*cont| {
                cont.deinit(self.allocator);
                return .{
                    .status = 501,
                    .body = try self.allocator.dupe(u8, "continuations not yet supported on this path\n"),
                    .body_is_json = false,
                    .console = try self.allocator.dupe(u8, ""),
                    .exception = try self.allocator.dupe(u8, ""),
                    .set_cookies = &.{},
                    .headers = &.{},
                };
            },
            .stream => |*s| {
                // Paths that don't support streams on this back-compat
                // path degrade to a defined 501 — mirrors the
                // `.continuation` posture on call sites that can't
                // handle the trampoline.
                s.deinit(self.allocator);
                return .{
                    .status = 501,
                    .body = try self.allocator.dupe(u8, "streams not yet supported on this path (Phase 2b)\n"),
                    .body_is_json = false,
                    .console = try self.allocator.dupe(u8, ""),
                    .exception = try self.allocator.dupe(u8, ""),
                    .set_cookies = &.{},
                    .headers = &.{},
                };
            },
            .no_onheaders, .no_onchunk => {
                // Only `.inbound_headers` / `.inbound_chunk`
                // activations produce these, and none ride the
                // back-compat path. Defined error, not a panic — same
                // graceful posture as the arms above.
                return .{
                    .status = 500,
                    .body = try self.allocator.dupe(u8, "export probe outcome on a non-probing path\n"),
                    .body_is_json = false,
                    .console = try self.allocator.dupe(u8, ""),
                    .exception = try self.allocator.dupe(u8, ""),
                    .set_cookies = &.{},
                    .headers = &.{},
                };
            },
        }
    }
};

/// Free a per-dispatch tag accumulator: the owned key/value bytes of
/// each entry, then the buffer. Used on the drop paths (probe miss,
/// stream, error) where the tags don't move onto a Response/Continuation.
fn freeTagsBuf(allocator: std.mem.Allocator, tags_buf: *std.ArrayList(log_mod.Tag)) void {
    for (tags_buf.items) |t| {
        allocator.free(t.key);
        allocator.free(t.value);
    }
    tags_buf.deinit(allocator);
}

fn finishResponse(
    d: *Dispatcher,
    state: *globals.DispatchState,
    pending: *PendingResponse,
    console_buf: *std.ArrayList(u8),
    tags_buf: *std.ArrayList(log_mod.Tag),
) DispatchError!RunOutcome {
    // Headers-first / chunk probe miss — before everything else:
    // nothing ran, so there is no kv error / stream / continuation to
    // reconcile.
    if (pending.no_onheaders) {
        console_buf.deinit(d.allocator);
        freeTagsBuf(d.allocator, tags_buf);
        return .no_onheaders;
    }
    if (pending.no_onchunk) {
        console_buf.deinit(d.allocator);
        freeTagsBuf(d.allocator, tags_buf);
        return .no_onchunk;
    }

    if (state.pending_kv_error) |err| {
        d.last_kv_error = err;
        // Return an error → caller's `errdefer console_buf.deinit`
        // (runOutcome) handles the cleanup. Don't deinit here, or
        // we'd double-free: ArrayList.deinit sets self.* =
        // undefined, and the errdefer's second deinit call frees
        // a garbage slice. That double-free crashes multi-worker
        // concurrent heldsync where kv races into pending_kv_error —
        // the panic surfaces as a GPF inside @memset under
        // std.mem.Allocator.free.
        return DispatchError.KvFailed;
    }

    // Engine provenance: an activation whose arm crossed the durability
    // boundary rooted a NEW saga (handler-shape.md §3.2); the arming
    // saga rides its record as the reserved `_parent` tag — the
    // viewer's cross-saga jump. Stamped AFTER the handler ran so it
    // never occupies the `tag` quota (the surface guard counts
    // the live buffer, and an engine tag consuming a customer slot
    // would also be a prod-only, engine-divergent throw). Clamped to
    // the tag-value contract: `armed_by` transits customer-writable
    // `_sched/` state, so an oversized or control-char value is forged
    // or garbage — dropped, never indexed. Best-effort: a failed dupe
    // drops the tag, never the activation.
    if (state.parent_saga) |ps| stamp: {
        if (!log_mod.validParentSagaValue(ps)) break :stamp;
        const k = d.allocator.dupe(u8, log_mod.PARENT_SAGA_TAG) catch break :stamp;
        const v = d.allocator.dupe(u8, ps) catch {
            d.allocator.free(k);
            break :stamp;
        };
        tags_buf.append(d.allocator, .{ .key = k, .value = v }) catch {
            d.allocator.free(k);
            d.allocator.free(v);
        };
    }

    // Seal this activation's customer values, now that the handler has
    // returned and its ops are final. THIS is what makes late binding
    // work: the identity in force at this moment is the one the writes
    // seal under, wherever in the handler it was named.
    //
    // After the kv-error gate above, so a failed attempt's writes — which
    // roll back — are never sealed, and before the write KEYS are taped
    // below, which record keys only and are unaffected either way.
    if (state.shred_slot) |sc| {
        if (sc.*) |key_slot| {
            if (state.shred) |caps| {
                if (caps.keys_for(caps.ctx, state.shred_instance_id)) |keys| {
                    keys.sealWrites(
                        d.allocator,
                        key_slot,
                        state.txn,
                        state.writeset,
                        state.ws_base,
                    ) catch |err| {
                        // Never commit plaintext an identity was promised
                        // would be sealed. Failing the activation is the
                        // only honest outcome: the handler asked for
                        // per-identity erasure and cannot have it.
                        state.pending_kv_error = err;
                    };
                }
            }
        }
    }

    // Record the activation's kv write KEYS onto the readset — its
    // writeset slice, `ws_base..` (batch writesets are shared; the
    // slice is this activation's). Reads ride the kv tape; writes are
    // outputs and live only in this list (`Readset.kv_write_keys` —
    // the log-server's seam scan is the consumer). After the kv-error
    // gate: a failed attempt's writes roll back and must not be
    // claimed. Best-effort: a failed append leaves the list short.
    if (state.readset) |rs| {
        for (state.writeset.ops.items[state.ws_base..]) |op| {
            const key = switch (op) {
                .put => |p| p.key,
                .delete => |del| del.key,
            };
            // Recorded as STORED, the writeset's own spelling — the kv tape
            // beside this holds store-spelled keys too, and the seam scan
            // intersects the two, so both sides carry the root and the
            // intersection is exact. The seam's RENDER strips it
            // (`reserved.userNamedKey`); recording stripped here and
            // intersecting a mixed pair is the depth split that reads as
            // no-interference.
            //
            // A write outside the user root is engine bookkeeping the handler
            // did not make (the `_sub/dirty/` marker the write path injects),
            // and it has no place in a blame view of what this activation
            // touched.
            if (!std.mem.startsWith(u8, key, reserved.USER_KEY_ROOT)) continue;
            rs.appendWriteKey(key) catch break;
        }
    }

    // Handler `stream.*` effects (§2.2): a handler that called
    // `stream.start()`/`stream.write()` produces the streamed
    // response from the ambient `response.*` head + the chunk effect
    // buffer, with disposition `return next()` (keep streaming) or a
    // terminal (close). Bridge to the internal `Stream` descriptor so
    // the stream pipeline (worker `.stream` arm →
    // serviceParkedStreams → resumeStream) drives both the
    // `__rove_stream` surface and this one. The disposition
    // is preserved: `next()` ⇒ `.stream` (re-arm); a terminal ⇒ keep the
    // terminal but prepend the buffered chunks so the final frames ship
    // before END_STREAM.
    // WS frame output (`docs/architecture/websockets.md`, piece D) skips this bridge
    // entirely: the chunks stay in `pending_stream_chunks` for the worker's
    // `shipWsFrames` (→ `ws_send_in`), `next()` falls through to the plain
    // continuation below, and a terminal keeps its own body (the frames
    // ship before the Close; nothing is prepended).
    if (state.stream_started and !state.ws_frame_output) {
        if (pending.continuation) |cont| {
            var c2 = cont;
            pending.continuation = null; // take ownership
            var s = buildStreamFromEffects(d.allocator, state, pending, c2.ctx_json) catch |e| {
                c2.deinit(d.allocator);
                return e;
            };
            // One `next()` semantic on every held chain: the target +
            // fn ride the descriptor to the stream-family arms (which
            // re-aim the chain / reject the fn loudly) instead of
            // being freed unread here. Move ownership out of c2.
            s.path = c2.path;
            c2.path = &.{};
            s.fn_name = c2.fn_name;
            c2.fn_name = null;
            c2.deinit(d.allocator); // ctx_json/tags — ctx was dup'd into `s`
            console_buf.deinit(d.allocator);
            // Streams don't carry a tag set (no log record per chunk
            // write); drop what the handler set.
            freeTagsBuf(d.allocator, tags_buf);
            return .{ .stream = s };
        }
        // Terminal close: ship the buffered chunks before the final body.
        try prependStreamChunks(d.allocator, state, pending);
        // fall through to the terminal build below.
    }

    // Trampoline: the handler returned `next(...)`. Hand the
    // descriptor up; the (unused) response accumulators stay empty.
    // Move ownership out of `pending` so its deinit can't double-free.
    if (pending.continuation) |cont| {
        pending.continuation = null;
        console_buf.deinit(d.allocator);
        // Tags must survive a `next()` — move them onto the
        // continuation so the held-chain capture site records them
        // (this is the browser-agent's per-frame session tag).
        var c2 = cont;
        c2.tags = tags_buf.toOwnedSlice(d.allocator) catch {
            freeTagsBuf(d.allocator, tags_buf);
            c2.deinit(d.allocator);
            return DispatchError.OutOfMemory;
        };
        return .{ .continuation = c2 };
    }
    const console_bytes = console_buf.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    const set_cookies = pending.cookies.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    const headers_slice = pending.headers.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    // If the handler explicitly set content-type in response.headers,
    // suppress our auto-stamped JSON one so the handler's choice wins.
    var effective_body_is_json = pending.body_is_json;
    if (effective_body_is_json) {
        for (headers_slice) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                effective_body_is_json = false;
                break;
            }
        }
    }

    const tags_slice = tags_buf.toOwnedSlice(d.allocator) catch
        return DispatchError.OutOfMemory;

    // Close the interaction digest with the run's own result — the last
    // element, and the one that makes the digest a superset of the status
    // comparison the fidelity gate does today.
    //
    // A THROWN handler does not carry its result in `pending`: the throw is
    // captured into `pending.exception` while status stays at the default 200
    // and body stays empty, and the real 500 + `handler threw: …` body is
    // composed downstream in `worker_dispatch`. Folding `pending` directly
    // therefore closed every failed request with `(200, "")` — so two handlers
    // that failed differently digested identically, and a replay that faithfully
    // reproduced the 500 was reported as diverged. Derive the effective terminal
    // here instead, from the one shared formatter the serving site uses.
    if (state.readset) |rs| {
        const threw = pending.exception.len > 0;
        const eff_body: []const u8 = if (threw)
            response_building.thrownBody(d.allocator, pending.exception)
        else
            pending.body;
        defer if (threw and response_building.thrownBodyOwned(eff_body)) d.allocator.free(eff_body);
        const eff_status = if (threw) @as(@TypeOf(pending.status), 500) else pending.status;

        var dg = tape_mod.interaction_digest.Digest{ .h = if (rs.interaction_digest == 0)
            tape_mod.interaction_digest.Digest.init().h
        else
            rs.interaction_digest };
        dg.response(@intCast(@max(@min(eff_status, 599), 100)), eff_body);
        rs.interaction_digest = dg.h;
    }

    return .{ .terminal = .{
        .status = pending.status,
        .body = pending.body,
        .body_is_json = effective_body_is_json,
        .console = console_bytes,
        .exception = pending.exception,
        .set_cookies = set_cookies,
        .headers = headers_slice,
        .tags = tags_slice,
    } };
}

// ── stream.* effect → Stream descriptor ────────────────────────────

/// Build the internal `Stream` descriptor for a `next()`-disposition
/// activation that emitted `stream.*` output. Head comes from the
/// ambient `response.*` (status + headers — ignored on resume hops, set
/// on the first hop); chunks are MOVED out of the `stream.write` effect
/// buffer; kv/timer wakes come from the `on.*` accumulator (dup'd — the
/// worker's list deinit frees the originals); `ctx_json` is dup'd from
/// the `next({ctx})` descriptor. Cookies on the stream head are not
/// carried (parity with the `__rove_stream` surface).
fn buildStreamFromEffects(
    allocator: std.mem.Allocator,
    state: *globals.DispatchState,
    pending: *PendingResponse,
    ctx_json_src: []const u8,
) error{OutOfMemory}!stream_mod.Stream {
    const headers_wire: ?[]u8 = if (pending.headers.items.len > 0)
        try encodeHeadersWire(allocator, pending.headers.items)
    else
        null;
    errdefer if (headers_wire) |h| allocator.free(h);

    // Chunks: transfer ownership out of the effect buffer into a fresh
    // spine; clear the source so the worker's deinit frees an empty list.
    var chunks: [][]u8 = &.{};
    if (state.pending_stream_chunks) |list| {
        if (list.items.len > 0) {
            chunks = try allocator.alloc([]u8, list.items.len);
            @memcpy(chunks, list.items);
            list.clearRetainingCapacity();
        }
    }
    errdefer {
        for (chunks) |ch| allocator.free(ch);
        if (chunks.len > 0) allocator.free(chunks);
    }

    // Wakes: dup the on.* registrations into per-arm kv arms + the
    // interval + each arm's own `{on}` export (per-arm routing — the
    // timer and each kv prefix resume into their own export).
    var interval_ms: ?i64 = null;
    var timer_on: ?[]u8 = null;
    var arms: std.ArrayListUnmanaged(components_mod.KvArm) = .empty;
    errdefer {
        for (arms.items) |arm| {
            allocator.free(arm.prefix);
            if (arm.on) |t| allocator.free(t);
        }
        arms.deinit(allocator);
        if (timer_on) |t| allocator.free(t);
    }
    if (state.pending_wakes) |wl| {
        for (wl.items) |reg| {
            switch (reg.kind) {
                .timer => {
                    interval_ms = reg.interval_ms;
                    if (timer_on) |old| allocator.free(old);
                    timer_on = if (reg.on) |t| try allocator.dupe(u8, t) else null;
                },
                .kv => {
                    const pfx = try allocator.dupe(u8, reg.prefix);
                    errdefer allocator.free(pfx);
                    const on: ?[]u8 = if (reg.on) |t| try allocator.dupe(u8, t) else null;
                    errdefer if (on) |t| allocator.free(t);
                    try arms.append(allocator, .{ .prefix = pfx, .on = on });
                },
            }
        }
    }
    const kv_prefixes = try arms.toOwnedSlice(allocator);
    errdefer {
        for (kv_prefixes) |arm| {
            allocator.free(arm.prefix);
            if (arm.on) |t| allocator.free(t);
        }
        if (kv_prefixes.len > 0) allocator.free(kv_prefixes);
    }

    const ctx_json = try allocator.dupe(u8, ctx_json_src);

    return .{
        .status = @intCast(@max(@min(pending.status, 599), 100)),
        .headers = headers_wire,
        .chunks = chunks,
        .interval_ms = interval_ms,
        .kv_prefixes = kv_prefixes,
        .timer_on = timer_on,
        .ctx_json = ctx_json,
    };
}

/// Render `[]ResponseHeader` as wire-format `name: value\r\n` lines —
/// the inverse of `parseStreamHeaders` (worker `.stream` arm). Empty
/// input is handled by the caller (returns null instead).
fn encodeHeadersWire(
    allocator: std.mem.Allocator,
    hdrs: []const ResponseHeader,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (hdrs) |h| {
        try out.appendSlice(allocator, h.name);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, h.value);
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

/// Terminal-close path: concatenate the buffered `stream.write` chunks
/// ahead of the terminal body so the final frames ship before
/// END_STREAM, then free + clear the effect buffer. No-op when the
/// buffer is empty (a plain terminal that happened to call
/// `stream.start()` with no writes).
fn prependStreamChunks(
    allocator: std.mem.Allocator,
    state: *globals.DispatchState,
    pending: *PendingResponse,
) error{OutOfMemory}!void {
    const list = state.pending_stream_chunks orelse return;
    if (list.items.len == 0) return;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (list.items) |ch| try buf.appendSlice(allocator, ch);
    try buf.appendSlice(allocator, pending.body);
    const merged = try buf.toOwnedSlice(allocator);
    if (pending.body.len > 0) allocator.free(pending.body);
    pending.body = merged;
    for (list.items) |ch| allocator.free(ch);
    list.clearRetainingCapacity();
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// In `dispatcher_test.zig` (same module; root.zig's test block wires it
// into the build) — tests + fixtures live there so this file is the
// production dispatcher only.
