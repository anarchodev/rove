//! `rove-js` worker — HTTP/2 server that runs a JS handler per request.
//!
//! `Worker(Options)` is a comptime-parameterized type that composes
//! `rove-h2` with a user-supplied `request_row` fragment. The fragment
//! is merged into h2's internal `StreamBaseRow` plus rove-js's own
//! `RaftWait` component, so per-request application state (session,
//! auth context, tape handles, ...) travels with the entity through
//! `request_out → raft_pending → response_in → response_out` without
//! rove-js or rove-h2 needing to know about user components. Library
//! composition follows the rove-library principle: never reach into
//! the inner library's collections, always thread user fragments
//! through the outer library's options.
//!
//! ## Request lifecycle
//!
//! ```
//! h2.request_out  ── dispatchPending ──▶  raft_pending (if writes)
//!                                     │
//!                                     └▶  h2.response_in (no writes)
//!
//! raft_pending    ── drainRaftPending ──▶  h2.response_in
//!                                      ── or 503 on fault/timeout ──▶
//! ```
//!
//! `dispatchPending` runs the handler, stamps response components onto
//! the entity, and either (a) moves it directly to `response_in` if no
//! writes were captured, or (b) sets `RaftWait{seq, deadline}` + kicks
//! off a raft propose + moves to `raft_pending`. `drainRaftPending`
//! polls each parked entity's seq against `raft.committedSeq()` and
//! `raft.faultedSeq()`, moving committed entities onward; this is the
//! shift-js "pending" collection pattern, replacing the synchronous
//! spin-wait that session 4 shipped as a placeholder.
//!
//! Parking means multiple requests can be in-flight through raft
//! simultaneously — the h2 poll loop no longer blocks waiting for a
//! commit. Concurrent requests are the whole reason this collection
//! exists.
//!
//! M1 scope: one hard-coded handler source per worker. Reading the
//! source from a files-server, route tables, and per-route bytecode
//! caching land once the worker's code-client is designed alongside
//! the files-server's HTTP/2 surface.
//!
//! The dispatch systems are plain functions, not methods — they take
//! `*Worker(...)` and are called by the user's poll loop between
//! `worker.poll(...)` and `reg.flush()`. Keeping systems outside the
//! Worker type mirrors shift-js's linear dispatch-is-a-phase pattern
//! and matches the rove-library "systems are pure" principle.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const qjs = @import("rove-qjs");
const kv_mod = @import("rove-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const log_mod = @import("rove-log");
const log_server_mod = @import("rove-log-server");
const jwt_mod = @import("rove-jwt");
const tape_mod = @import("rove-tape");
const bodies_mod = @import("rove-bodies");
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const continuation_mod = @import("bindings/continuation.zig");
const Continuation = continuation_mod.Continuation;
const stream_mod = @import("bindings/stream.zig");
const components_mod = @import("components.zig");
const effect_mod = @import("effect/root.zig");
const globals = @import("globals.zig");
const apply_mod = @import("apply.zig");
const raft_propose = @import("raft_propose.zig");
const config_mirror = @import("config_mirror.zig");
const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const dispatch = @import("worker_dispatch.zig");
const worker_log = @import("worker_log.zig");
const worker_bodies = @import("worker_bodies.zig");
const worker_streaming = @import("worker_streaming.zig");
const worker_drain = @import("worker_drain.zig");
const panic_mod = @import("panic.zig");
const penalty_mod = @import("penalty.zig");
const limiter_mod = @import("limiter.zig");
const router_mod = @import("router.zig");
const reserved = @import("reserved.zig");
const deployment_loader_mod = @import("deployment_loader.zig");
const fetch_engine_mod = @import("fetch_engine.zig");
const builtin_modules_mod = @import("builtin_modules.zig");

/// `_send/owed/` kv prefix — the durable marker key the JS-shim
/// `webhook.send` writes (Phase 5 PR-3). Inlined here (and in
/// `worker_dispatch.zig`) after the `send_outbox.zig` module
/// retired with the SendDispatch kernel; the prefix itself stays
/// because the marker key shape didn't change — only the producer
/// (Zig → JS) and the consumer (SendDispatch → `sweepOwedRetries`).
pub const OWED_PREFIX: []const u8 = "_send/owed/";

/// Phase 5 PR-3: deferred §6.4 held-sync resume entry. The baked
/// `__system/webhook_onresult` shim calls
/// `_system.continuation.resumeIfBound`; the trampoline appends
/// this row + the worker drains it post-dispatch (see
/// `drainPendingBoundResumes`). All slices owned by the worker
/// allocator.
pub const PendingBoundResume = struct {
    tenant_id: []u8,
    send_id: []u8,
    event_json: []u8,

    pub fn deinit(self: *PendingBoundResume, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.send_id);
        allocator.free(self.event_json);
        self.* = undefined;
    }
};
const Dispatcher = dispatcher_mod.Dispatcher;
const Request = dispatcher_mod.Request;

/// Per-request raft-wait state. Stamped onto the entity before it
/// parks in `raft_pending`, read by `drainRaftPending` each tick to
/// decide whether the request has committed, faulted, or timed out.
///
/// ## Flow
///
/// The dispatcher does a kvexp speculative `TrackedTxn.commit()` on
/// the local tenant store BEFORE parking and releases the dispatch
/// lease, so other concurrent requests on the same tenant can
/// proceed while raft consenses in parallel. kvexp's commit is a
/// *volatile overlay* — it persists to LMDB only at raft-apply, so
/// a crash/truncation before quorum loses it (no on-disk
/// divergence). `drainRaftPending` finalises each parked txn by its
/// raft `seq`: on commit it runs `TrackedTxn.commit()` (chain-head
/// detach, retried on `Conflict`); on fault/timeout it runs
/// `TrackedTxn.rollback()` on the pointer held in
/// `worker.pending_txns[seq]`. (The legacy `KvStore.undoTxn` /
/// `commitTxn` / `kv_undo`-log path was pre-kvexp SQLite machinery,
/// since deleted; rollback is `TrackedTxn.rollback()` + kvexp
/// volatility, not an undo-log walk.)
///
/// Fields:
/// - `seq`: raft-side sequence from `raft.highWatermark()+1`, tracked
///   by `committedSeq()` / `faultedSeq()`; the key into
///   `worker.pending_txns` that owns the parked `TrackedTxn`.
/// - `deadline_ns`: absolute `std.time.nanoTimestamp()` deadline.
pub const RaftWait = struct {
    seq: u64 = 0,
    deadline_ns: i64 = 0,
};

/// Per-entity park record for `docs/readset-replication-plan.md`
/// Phase 4 (park-on-durability). When `dispatchPending` parks an
/// entity waiting for its inbound request body's batch to flush,
/// it sets this component with the body's `BodyRef` and the owning
/// tenant id, then `reg.move`s the entity from `request_out` to
/// `body_pending`.
///
/// Sentinel: `body_ref.batch_id == bodies_mod.NO_BATCH` (the
/// default) means "not parked". `drainBodyPending` releases
/// entities whose `body_ref.batch_id <= last_flushed_batch_id` on
/// their tenant's `TenantBodies.buffer` back to `request_out`;
/// `dispatchPending`'s body-gate detects the non-sentinel component
/// on resume and uses the saved `body_ref` directly instead of
/// re-appending (which would mint a new batch and re-park).
///
/// `tenant_id` is a borrowed slice into the per-tenant
/// `tenant_mod.Instance.id` — owned by the NodeState's tenant
/// registry, lives for the process lifetime.
pub const BodyDurabilityWait = struct {
    body_ref: bodies_mod.BodyRef = .{
        .batch_id = bodies_mod.NO_BATCH,
        .offset = 0,
        .len = 0,
    },
    tenant_id: []const u8 = "",
};

/// Effect-reification Phase 4.1: the typed Cmd buffer a `ParkedUnit`
/// carries — commit-gated `kv_wake_broadcast` Cmds (was
/// `BufferedSendKvOps.kv_wakes`), `stream_chunk` Cmds (was
/// `staged_chunks` + `stream_entity`), `stream_close` Cmd (was
/// `mark_draining`), and `http_fetch` Cmds (the new commit-gated
/// staging for webhook.send's inline fetch — closes the
/// marker-commit race the Phase-5-PR-3 close-out documented).
/// Defined in `effect/cmd.zig`; aliased here for the
/// `ParkedUnit = Continuation(BufferedSendKvOps, ...)` declaration
/// below to keep the historical name in worker-internal contexts.
///
/// Released by `drainRaftPending` on `committedSeq >= seq` (via
/// `BufferedCmds.releaseAll` → `interpretCmd` per Cmd); discarded
/// on fault/timeout/leadership-loss (`BufferedCmds.deinit` walks
/// each Cmd's per-variant deinit). The §9.4 "spurious + overflow"
/// thesis tolerates dropped kv_wakes; `streaming-model.md` §2's
/// "a chunk reaches the wire only after the activation that
/// produced it has committed" makes a fault-arm chunk-discard the
/// rule, not the exception.
pub const BufferedSendKvOps = effect_mod.cmd.BufferedCmds;

/// A post-propose parked unit (divergence workstream,
/// `docs/unified-effect-gating.md` idiom-1) — the parked-unit half
/// of the Cmd-buffer commit gate. The H2 entity path parks ECS
/// entities in `raft_pending_X` and emits a `Cmd.respond` on the
/// matching unit; non-entity paths (the streaming kv-wake gate in
/// `worker_streaming.parkKvWakesForStreaming`, the cont-resume +
/// barrier paths in `worker.parkKvWakes`) just register a unit
/// directly. `drainRaftPending` releases the buffered Cmds at
/// commit (`committedSeq >= seq`) through `interpretCmd` and
/// discards them on fault/timeout/leadership-loss (the effect
/// never escaped).
///
/// Effect-reification Phase 3.1: `ParkedUnit` is now the first
/// concrete instantiation of `effect.Continuation`. Same fields
/// (seq, deadline_ns, tenant_id, txn) and same rove-compatible
/// `deinit(allocator, items)` signature — the migration is
/// structural. The pre-3.1 `send_ops` + `kv_wakes` fields live
/// under `unit.buffered.send_ops` / `unit.buffered.kv_wakes` now;
/// the inner shape `BufferedSendKvOps` is defined above. The new
/// `wake_key` slot is present but unused at this site
/// (entity-less parked units don't need wake routing — the
/// drainRaftPending sweep walks the collection directly). Phase
/// 3.2+ uses `wake_key` when the H2 entity path migrates.
pub const ParkedUnit = effect_mod.Continuation(BufferedSendKvOps, *kv_mod.KvStore.TrackedTxn);

/// Owned (key, op) pair captured from a write batch's writeset at
/// propose time. Aliased to `effect.cmd.KvWakeOp` (the
/// `kv_wake_broadcast` Cmd's payload type) so the propose-side
/// builders can drop the records into a `BufferedCmds` list
/// without translation.
pub const KvWakeOp = effect_mod.cmd.KvWakeOp;

/// DATA side-store value for a continuation-parked stream
/// (connection-actor §6.1/§6.4). The *lifecycle* discriminant is
/// membership in the worker's `parked_continuations` collection, NOT
/// this struct (`feedback_state_is_collection`); this is the
/// principle-compliant data that rides alongside: the trampoline
/// descriptor + the §6.4 mandatory-timeout deadline. `sid`/`sess`
/// are NOT here — they are read back from the parked entity's own
/// h2 components at resolve time.
/// §6.4 mandatory-timeout for a continuation-parked stream — a real
/// 504 must go out before any browser/LB/CDN intermediary gives up.
/// Fixed for 3b-ii (config knob is a later refinement); mirrors the
/// connection-holder's `default_hold_deadline_ms` (25 s).
pub const CONT_HOLD_DEADLINE_NS: i64 = 25 * std.time.ns_per_s;

// Phase 7: `ParkedCont` struct removed — cont state lives on the
// entity's `ContDescriptor` + `ChainContext` components, which
// deinit structurally on entity destroy.

// Phase 7: `StreamCell` removed — stream state lives on the entity's
// `ChainContext` + `StreamChain` + `StreamChunks` + `StreamWakes`
// components (defined in components.zig); each has its own
// component-style deinit that rove `Collection.deinit` invokes
// structurally on every entity in the collection on shutdown.

/// One kv-write event that crossed the apply boundary (either via
/// `applyWriteSet` on a follower or via the leader-side eager fire
/// in `worker_dispatch.zig`). `tenant_id` + `key` are allocator-
/// owned dup's because the source bytes (the writeset payload or
/// the in-flight `WriteSet.ops` buffer) don't outlive the producer
/// site. `op` is a single byte: `'p'` for put, `'d'` for delete.
pub const KvWakeEvent = struct {
    tenant_id: []u8,
    key: []u8,
    op: u8,

    pub fn deinit(self: *KvWakeEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.key);
        self.* = undefined;
    }
};

/// Thread-safe per-worker inbox of kv-write events awaiting prefix-
/// match scan against the worker's local `parked_streams_meta`.
/// Producers (apply thread + leader-side worker_dispatch) call
/// `push`; the owning worker drains at the start of every
/// `serviceParkedStreams` tick. Mutex held only during enqueue /
/// drain — the worker's per-tick scan runs on local snapshots.
pub const KvWakeInbox = struct {
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayListUnmanaged(KvWakeEvent) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KvWakeInbox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KvWakeInbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.events.items) |*e| e.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    /// Enqueue one event. Dups `tenant_id` + `key` so the caller
    /// can free the source bytes immediately. Errors propagate to
    /// the caller (apply-thread path logs and continues — losing a
    /// wake is preferable to crashing the apply loop; the §9.4
    /// "spurious + overflow" thesis allows this).
    pub fn push(self: *KvWakeInbox, tenant_id: []const u8, key: []const u8, op: u8) !void {
        const tid = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(tid);
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.append(self.allocator, .{ .tenant_id = tid, .key = k, .op = op });
    }

    /// Move all queued events into the caller's local list (the
    /// caller now owns each event's slices). Inbox is empty after
    /// the call. Mutex held briefly.
    pub fn drainInto(self: *KvWakeInbox, out: *std.ArrayListUnmanaged(KvWakeEvent)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return;
        try out.appendSlice(self.allocator, self.events.items);
        self.events.clearRetainingCapacity();
    }
};

/// Phase 2b-ii: per-stream caps (hard, no operator config yet). A
/// misbehaving handler can't run a stream forever; once these hit,
/// `serviceParkedStreams` forces `close_pending` and the entity
/// shuts down cleanly. Configurable per-tenant lands in Phase 2c.
pub const MAX_STREAM_ACTIVATIONS: u32 = 1000;

/// `docs/primitive-gaps.md` §6 — per-chain tape byte cap. Once a
/// chain (correlation_id) accumulates this many tape bytes across
/// its activations, subsequent activations flush their log records
/// without the tape payloads (replay degrades to summary-only past
/// the cap). 10 MB is generous for normal chains (the LLM-proxy
/// case stays under 1 MB even for ~3000 chunks); pathological
/// streams hit the cap and bound the long-term cost.
///
/// Operator-tunable per tenant lands in v2 — v1 ships one global
/// constant. Capture-mode (`tape_mode = on_exception` etc.) is
/// the v2 storage-cost knob (catalog §6); the cap is the v1
/// correctness/safety knob.
pub const TAPE_CAP_BYTES_PER_CHAIN: u64 = 10 * 1024 * 1024;

/// LRU eviction trigger for the tape-state map(s). The total
/// capacity is `TAPE_STATE_LRU_CAP`; each shard caps at
/// `TAPE_STATE_LRU_CAP / TAPE_STATE_SHARDS` entries. The chains
/// dropped may re-enter at zero used-bytes (rare in practice —
/// chains usually terminate well before eviction).
pub const TAPE_STATE_LRU_CAP: u32 = 10_000;

/// Shard count for the per-chain tape-budget tracker. The tape
/// cap is consulted on the inbound dispatch hot path (4 sites in
/// `dispatchOnce`), so a single global mutex serialized every
/// worker through one critical section — measured as a ~4× drop
/// in 8w/8t sharded-write throughput when the cap was added (see
/// commit `c547784`'s regression). Picking `correlation_id`'s
/// hash mod `TAPE_STATE_SHARDS` partitions the contention domain;
/// uniform-tenant load sees ~1/N residual contention.
///
/// Power of 2 so the modulo lowers to a mask. 16 is plenty for
/// 8 workers; bump if worker counts grow into the hundreds.
pub const TAPE_STATE_SHARDS: usize = 16;
const TAPE_STATE_LRU_CAP_PER_SHARD: u32 = TAPE_STATE_LRU_CAP / @as(u32, @intCast(TAPE_STATE_SHARDS));

pub const TapeStateShard = struct {
    mutex: std.Thread.Mutex = .{},
    map: std.StringHashMapUnmanaged(ChainTapeState) = .empty,
};

/// `tape_state_shards[*].map` value — per-chain tape accounting.
/// Tiny (~32 bytes). Cross-worker; contention is bounded by the
/// shard fanout (`TAPE_STATE_SHARDS`).
pub const ChainTapeState = struct {
    bytes_used: u64 = 0,
    /// Set the first time the chain crosses the cap. Once set,
    /// `captureTapes` returns empty payloads + emits a one-shot
    /// log-line warning (the marker on the activation that
    /// tripped it).
    capped: bool = false,
    /// Monotonic counter for LRU eviction — bumped on every
    /// `captureTapes` touch.
    last_touch_seq: u64 = 0,
};

// Effect-reification Phase 2E: SubscriptionFireInbox + FetchChunkInbox
// + PendingFireMessage retired. The unified `effect.MsgInbox` carries
// Msgs (variant-typed) across the thread boundary; producers build the
// Msg variant before push (no inbox-side adapter type needed). See
// `effect/queue.zig` for the inbox + drain shape.

/// One cross-tenant target's accumulated writeset within a batch.
/// `id` is an owned dup of the target instance id.
const TargetWrite = struct {
    id: []u8,
    ws: kv_mod.WriteSet,
};

/// Per-dispatch-tick accumulator for the *side* effects an admin
/// handler triggers beyond its own anchor app.db writeset:
/// `platform.root.*` (→ `root_ws`, a type-2 root writeset) and the
/// cross-tenant trampolines `platform.scope(id).kv.*` /
/// `platform.releases.publish` / signup→`deployStarter` (→ a
/// per-target type-0 writeset). Option-A (docs/proposer-audit.md
/// Addendum 3): these ride the **same atomic raft entry** as the
/// batch and the caller is parked on that one seq, instead of
/// fire-and-forget proposes the caller never gated on. Lives on the
/// worker (single-threaded per tick, like `pending_txns`); reset at
/// `dispatchOnce` entry and at `finalizeBatch` exit. WriteSet copies
/// bytes in, so accumulation is safe and `reset` frees everything.
pub const BatchSideEffects = struct {
    root_ws: ?kv_mod.WriteSet = null,
    targets: std.ArrayListUnmanaged(TargetWrite) = .empty,

    /// Stable pointer to the batch root writeset, lazily created.
    /// Called once per tick when the anchor is an admin handler so
    /// `Request.root_writeset` has a stable address for the walk.
    pub fn rootWs(self: *BatchSideEffects, allocator: std.mem.Allocator) *kv_mod.WriteSet {
        if (self.root_ws == null) self.root_ws = kv_mod.WriteSet.init(allocator);
        return &self.root_ws.?;
    }

    /// Find-or-create the accumulator for `target_id` (writes to the
    /// same target across a batch merge into one inner). `target_id`
    /// is duped on first sight.
    pub fn targetWs(
        self: *BatchSideEffects,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) !*kv_mod.WriteSet {
        for (self.targets.items) |*t| {
            if (std.mem.eql(u8, t.id, target_id)) return &t.ws;
        }
        const id_dup = try allocator.dupe(u8, target_id);
        errdefer allocator.free(id_dup);
        try self.targets.append(allocator, .{
            .id = id_dup,
            .ws = kv_mod.WriteSet.init(allocator),
        });
        return &self.targets.items[self.targets.items.len - 1].ws;
    }

    /// True iff nothing was accumulated this tick (so `finalizeBatch`
    /// may still take the read-only fast path).
    pub fn isEmpty(self: *const BatchSideEffects) bool {
        if (self.root_ws) |rw| if (rw.ops.items.len > 0) return false;
        for (self.targets.items) |t| if (t.ws.ops.items.len > 0) return false;
        return true;
    }

    pub fn reset(self: *BatchSideEffects, allocator: std.mem.Allocator) void {
        if (self.root_ws) |*rw| rw.deinit();
        self.root_ws = null;
        for (self.targets.items) |*t| {
            t.ws.deinit();
            allocator.free(t.id);
        }
        self.targets.clearRetainingCapacity();
    }
};

/// Default handler entry path. Each tenant's deployment must have a
/// file at this path — it's the script the worker runs per request.
/// Name of the single handler file the old single-bytecode path
/// expected, kept as a constant for the smoke-test bootstrap that
/// publishes one `index.js` per tenant. The request router now picks
/// any file in the deployment (see `router.zig`), so this constant is
/// only a convenience for tools that want to know where the root entry
/// point lives by default.
pub const DEFAULT_HANDLER_PATH = "index.js";

/// Tick-local scratch list of tenants whose kvexp dispatch lease
/// `tryAcquire` returned contended (surfaced as `error.Conflict`)
/// during the current tick — the kvexp successor of the pre-cutover
/// `SQLITE_BUSY`-on-`BEGIN IMMEDIATE` skip. Owned by the caller
/// (the worker main loop), cleared at the top of each tick, passed
/// by-pointer into `dispatchOnce` so a blocked tenant doesn't get
/// picked as anchor again until the tick ends and the list is
/// cleared.
///
/// Bounded at 32 — far above the realistic handful-of-tenants-per-
/// tick workloads we've measured. `append` returns `error.Overflow`
/// if the cap is exceeded; `dispatchOnce` treats that as "stop for
/// now, try again next tick".
pub const BlockedTenants = struct {
    items: [32]*const tenant_mod.Instance = undefined,
    len: usize = 0,

    pub fn clear(self: *BlockedTenants) void {
        self.len = 0;
    }

    pub fn slice(self: *const BlockedTenants) []const *const tenant_mod.Instance {
        return self.items[0..self.len];
    }

    pub fn append(self: *BlockedTenants, inst: *const tenant_mod.Instance) !void {
        if (self.len >= self.items.len) return error.Overflow;
        self.items[self.len] = inst;
        self.len += 1;
    }
};


/// Metadata about a static file in the active deployment. Bytes are
/// not cached — the dispatcher fetches them from the blob store on hit.
/// `hash_hex` is both the content address and the strong ETag.
pub const StaticEntry = struct {
    content_type: []u8, // owned, may be empty
    hash_hex: [files_mod.HASH_HEX_LEN]u8,
};

/// Per-tenant code state held by the worker. Owns its own KvStore,
/// BlobStore, and cached bytecode for the tenant's active handler.
/// `TriggerEntry` is defined in globals.zig (lives next to the
/// dispatch state that consumes it during kv.set / kv.delete fire).
/// Re-exported here for convenience — `worker.TriggerEntry` reads
/// naturally next to `worker.TenantFiles`.
pub const TriggerEntry = globals.TriggerEntry;

/// Returns the kv key prefix this manifest path registers as a trigger
/// for, or null if the path isn't a trigger module entry. The path IS
/// the prefix (PLAN §2.5):
///   `_triggers/index.mjs`               → `""`        (catch-all)
///   `_triggers/users/index.mjs`         → `"users/"`
///   `_triggers/users/sessions/index.mjs` → `"users/sessions/"`
/// `.js` is accepted alongside `.mjs` for symmetry with handler routing.
fn triggerPathToPrefix(path: []const u8) ?[]const u8 {
    const TR = "_triggers/";
    if (!std.mem.startsWith(u8, path, TR)) return null;
    const rest = path[TR.len..];

    // `_triggers/index.mjs` / `_triggers/index.js` → catch-all.
    if (std.mem.eql(u8, rest, "index.mjs")) return "";
    if (std.mem.eql(u8, rest, "index.js")) return "";

    // `<prefix>/index.mjs` → `<prefix>/`.
    if (std.mem.endsWith(u8, rest, "/index.mjs")) {
        return rest[0 .. rest.len - "index.mjs".len];
    }
    if (std.mem.endsWith(u8, rest, "/index.js")) {
        return rest[0 .. rest.len - "index.js".len];
    }
    // Anything else under `_triggers/` (helper modules, non-index files)
    // isn't itself a trigger entry point — it's just bytecode the
    // trigger module may import.
    return null;
}

/// Re-export so callers reading worker.zig find the trigger guard
/// without leaving the file. See `reserved.zig` for the prefix list
/// and the customer-write guard counterpart.
const isReservedTriggerPrefix = reserved.isReservedTriggerPrefix;

/// Parse a `_subscriptions/<name>/<file>` deployment path into its
/// name + file-kind. Mirror of `triggerPathToPrefix` for Gap 2.1:
///
///   `_subscriptions/cleanup/index.mjs`  → `{name: "cleanup", kind: .handler}`
///   `_subscriptions/cleanup/index.js`   → `{name: "cleanup", kind: .handler}`
///   `_subscriptions/cleanup/spec.json`  → `{name: "cleanup", kind: .spec}`
///   `_subscriptions/cleanup/helper.mjs` → null (non-index helper modules are not subscriptions themselves)
///   anything else                        → null
///
/// Returned `name` slice borrows from `path`; valid as long as the
/// caller holds `path`. Subscription names must match
/// `[A-Za-z0-9_-]+` and be 1–64 chars; out-of-range returns null
/// so a misnamed file is treated as "not a subscription entry."
fn subscriptionPathParts(path: []const u8) ?struct {
    name: []const u8,
    kind: SubscriptionFileKind,
} {
    const PREFIX = "_subscriptions/";
    if (!std.mem.startsWith(u8, path, PREFIX)) return null;
    const rest = path[PREFIX.len..];

    // Split on the first `/` to get the name segment.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const name = rest[0..slash];
    const tail = rest[slash + 1 ..];

    if (name.len == 0 or name.len > 64) return null;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_';
        if (!ok) return null;
    }

    if (std.mem.eql(u8, tail, "index.mjs") or std.mem.eql(u8, tail, "index.js"))
        return .{ .name = name, .kind = .handler };
    if (std.mem.eql(u8, tail, "spec.json"))
        return .{ .name = name, .kind = .spec };
    return null;
}

const SubscriptionFileKind = enum { handler, spec };

/// JSON shape of `_subscriptions/<name>/spec.json`. Parsed flat
/// then dispatched on `kind` to populate the typed
/// `SubscriptionEntry.Spec`. Unknown kinds + missing required
/// fields fail the deploy.
const SubscriptionSpecJson = struct {
    kind: []const u8,
    /// Required for kind=cron. Milliseconds between fires. Must be
    /// >= 1000 (one second). For complex schedules (e.g. "daily at
    /// 3am"), customers compose via
    /// `http.send({fire_at_ns: cron.next(...)})`.
    interval_ms: ?i64 = null,
    /// Required for kind=kv.
    prefix: ?[]const u8 = null,
};

/// Build the deployment's subscription registry from the manifest.
/// Walks once to collect handler + spec.json paths under
/// `_subscriptions/<name>/`, then pairs them: every spec.json must
/// have a matching handler (else `error.SubscriptionMissingHandler`);
/// missing spec.json on a handler is allowed (the handler is a
/// regular module under that path — the index.mjs convention is
/// what makes it a *subscription*).
///
/// Spec JSON is fetched fresh from the blob store on each reload —
/// this is deploy-time work; the fetch cost is bounded by the
/// number of subscriptions per tenant (small) and amortizes against
/// the per-deploy snapshot rebuild.
fn discoverSubscriptions(
    allocator: std.mem.Allocator,
    manifest: files_mod.manifest_json.Manifest,
    bs: anytype,
) ![]globals.SubscriptionEntry {
    var handler_paths: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer handler_paths.deinit(allocator);
    var spec_hashes: std.StringHashMapUnmanaged([files_mod.HASH_HEX_LEN]u8) = .empty;
    defer spec_hashes.deinit(allocator);

    for (manifest.entries) |entry| {
        const parts = subscriptionPathParts(entry.path) orelse continue;
        switch (parts.kind) {
            .handler => {
                if (entry.kind != .handler) {
                    std.log.warn(
                        "rove-js: subscription path `{s}` is not a handler entry — skipping",
                        .{entry.path},
                    );
                    continue;
                }
                try handler_paths.put(allocator, parts.name, entry.path);
            },
            .spec => {
                if (entry.kind != .static) {
                    std.log.warn(
                        "rove-js: subscription spec `{s}` must be a static file — skipping",
                        .{entry.path},
                    );
                    continue;
                }
                try spec_hashes.put(allocator, parts.name, entry.source_hex);
            },
        }
    }

    if (spec_hashes.count() == 0) return &.{};

    var out: std.ArrayList(globals.SubscriptionEntry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit(allocator);
    }

    var it = spec_hashes.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const hash = e.value_ptr.*;

        const handler_path = handler_paths.get(name) orelse {
            std.log.err(
                "rove-js: subscription `{s}` has spec.json but no index.mjs/index.js handler",
                .{name},
            );
            return error.SubscriptionMissingHandler;
        };

        const spec_bytes = bs.get(&hash, allocator) catch |err| {
            std.log.err(
                "rove-js: subscription `{s}` spec.json fetch failed: {s}",
                .{ name, @errorName(err) },
            );
            return error.SubscriptionSpecFetch;
        };
        defer allocator.free(spec_bytes);

        const parsed = std.json.parseFromSlice(
            SubscriptionSpecJson,
            allocator,
            spec_bytes,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.err(
                "rove-js: subscription `{s}` spec.json parse failed: {s}",
                .{ name, @errorName(err) },
            );
            return error.SubscriptionSpecInvalidJson;
        };
        defer parsed.deinit();

        const spec_typed = try translateSpec(allocator, name, parsed.value);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const module_path_copy = try allocator.dupe(u8, handler_path);
        errdefer allocator.free(module_path_copy);

        try out.append(allocator, .{
            .name = name_copy,
            .module_path = module_path_copy,
            .spec = spec_typed,
        });
    }

    return out.toOwnedSlice(allocator);
}

/// Convert the JSON-shape spec into the typed tagged-union. The
/// returned `Spec` owns any inner allocations (allocator-duped
/// strings); caller must `deinit` on error paths.
fn translateSpec(
    allocator: std.mem.Allocator,
    name: []const u8,
    raw: SubscriptionSpecJson,
) !globals.SubscriptionEntry.Spec {
    if (std.mem.eql(u8, raw.kind, "cron")) {
        const interval_ms = raw.interval_ms orelse {
            std.log.err("rove-js: subscription `{s}` kind=cron missing `interval_ms` field", .{name});
            return error.SubscriptionSpecMissingField;
        };
        if (interval_ms < 1000) {
            std.log.err(
                "rove-js: subscription `{s}` kind=cron has sub-second interval_ms={d} (minimum 1000)",
                .{ name, interval_ms },
            );
            return error.SubscriptionSpecMissingField;
        }
        return .{ .cron = .{ .interval_ms = interval_ms } };
    }
    if (std.mem.eql(u8, raw.kind, "kv")) {
        const prefix = raw.prefix orelse {
            std.log.err("rove-js: subscription `{s}` kind=kv missing `prefix` field", .{name});
            return error.SubscriptionSpecMissingField;
        };
        if (prefix.len == 0) {
            std.log.err("rove-js: subscription `{s}` kind=kv has empty prefix", .{name});
            return error.SubscriptionSpecMissingField;
        }
        return .{ .kv = .{ .prefix = try allocator.dupe(u8, prefix) } };
    }
    if (std.mem.eql(u8, raw.kind, "boot")) {
        return .boot;
    }
    std.log.err("rove-js: subscription `{s}` has unknown kind `{s}`", .{ name, raw.kind });
    return error.SubscriptionSpecUnknownKind;
}

test "subscriptionPathParts: handler + spec + rejects" {
    {
        const r = subscriptionPathParts("_subscriptions/cleanup/index.mjs").?;
        try std.testing.expectEqualStrings("cleanup", r.name);
        try std.testing.expectEqual(SubscriptionFileKind.handler, r.kind);
    }
    {
        const r = subscriptionPathParts("_subscriptions/jobs-q/spec.json").?;
        try std.testing.expectEqualStrings("jobs-q", r.name);
        try std.testing.expectEqual(SubscriptionFileKind.spec, r.kind);
    }
    {
        const r = subscriptionPathParts("_subscriptions/foo/index.js").?;
        try std.testing.expectEqualStrings("foo", r.name);
        try std.testing.expectEqual(SubscriptionFileKind.handler, r.kind);
    }
    // Non-index helper module: not a subscription entry-point.
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts("_subscriptions/foo/helper.mjs"));
    // Bad name characters.
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts("_subscriptions/has space/index.mjs"));
    // Not under _subscriptions/.
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts("foo/bar/index.mjs"));
    // Too-long name.
    var buf: [200]u8 = undefined;
    @memset(&buf, 'x');
    const long_name = buf[0..70];
    const long_path = try std.fmt.allocPrint(std.testing.allocator, "_subscriptions/{s}/index.mjs", .{long_name});
    defer std.testing.allocator.free(long_path);
    try std.testing.expectEqual(@as(@TypeOf(subscriptionPathParts("")), null), subscriptionPathParts(long_path));
}

/// Reloaded by the background `DeploymentLoader` thread whenever a
/// release lands (operator path: __admin__'s `publishRelease` RPC;
/// platform-bootstrap path: `/_system/release`). The proposing
/// trampoline enqueues the loader inline on the leader; followers
/// pick up the enqueue from `apply.zig`'s `_deploy/current` detector.
/// Immutable per-deployment-version snapshot. Refcounted; freed when
/// the last reference drops (slot reload + any in-flight request).
///
/// Phase 2 of `docs/deployment-snapshots-plan.md`: snapshot pinning
/// guarantees a request sees one deployment version completely or
/// another completely, never a mid-reload mix.
pub const TenantFilesSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Deployment id this snapshot represents. Equal to the
    /// `_deploy/current` hex value at the moment the loader built it.
    deployment_id: u64,
    /// All handler bytecodes from this deployment, keyed by full
    /// deployment path. Keys and values are allocator-owned.
    bytecodes: std.StringHashMapUnmanaged([]u8),
    /// Source-blob hash hex (64 chars) per handler path. Parallel to
    /// `bytecodes`. Read by the QuickJS module loader for per-request
    /// module-resolution tapes.
    source_hashes: std.StringHashMapUnmanaged([64]u8),
    /// Static files keyed by stored path; bytes fetched on demand
    /// from the slot's `blob_backend`.
    statics: std.StringHashMapUnmanaged(StaticEntry),
    /// Trigger registry. Sorted descending by prefix length so a
    /// forward scan visits innermost (most-specific) triggers first.
    triggers: []TriggerEntry,
    /// Subscription registry (Gap 2.1) — chain origins that fire
    /// without an inbound request. Built from
    /// `_subscriptions/<name>/{spec.json,index.mjs}` manifest pairs.
    /// Default empty for snapshots that pre-date subscription
    /// discovery; only the deploy-loader populates it.
    subscriptions: []globals.SubscriptionEntry = &.{},
    /// Raw manifest bytes for this deployment. Re-released callers
    /// re-decode locally on dep_id match, skipping a fetch.
    manifest_bytes: []u8,
    /// References to this snapshot. Starts at 1 (slot's reference).
    /// Per-request retain++ at dispatch entry; release-- on response.
    /// Reload swaps the slot pointer and drops the slot's reference.
    refcount: std.atomic.Value(u32),

    pub fn retain(self: *TenantFilesSnapshot) void {
        _ = self.refcount.fetchAdd(1, .acquire);
    }

    pub fn release(self: *TenantFilesSnapshot) void {
        if (self.refcount.fetchSub(1, .release) == 1) {
            self.deinit();
        }
    }

    fn deinit(self: *TenantFilesSnapshot) void {
        const allocator = self.allocator;
        var bc_it = self.bytecodes.iterator();
        while (bc_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.bytecodes.deinit(allocator);
        var sh_it = self.source_hashes.iterator();
        while (sh_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.source_hashes.deinit(allocator);
        var st_it = self.statics.iterator();
        while (st_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.content_type);
        }
        self.statics.deinit(allocator);
        for (self.triggers) |t| {
            allocator.free(t.prefix);
            allocator.free(t.module_path);
        }
        allocator.free(self.triggers);
        for (self.subscriptions) |*s| {
            // Cast away const for the deinit call; the slice is
            // allocator-owned at this point (no aliases reach this
            // path — Phase B's snapshot-build hands ownership to
            // the snapshot, the swap drops the old, and `deinit`
            // is the sole site that frees).
            const mut: *globals.SubscriptionEntry = @constCast(s);
            mut.deinit(allocator);
        }
        if (self.subscriptions.len > 0) allocator.free(self.subscriptions);
        allocator.free(self.manifest_bytes);
        allocator.destroy(self);
    }
};

/// Per-tenant slot. Persists across deployments; lifetime = tenant
/// lifetime. Owns the per-tenant blob backends and points at the
/// current `*TenantFilesSnapshot` via an atomic pointer.
///
/// Reload semantics: the loader builds a new snapshot fully, then
/// `atomicStore`s onto `current` (release ordering), then drops the
/// old snapshot's lease. In-flight requests that pinned the old
/// snapshot keep it alive until they release.
pub const TenantSlot = struct {
    allocator: std.mem.Allocator,
    /// Owned copy of the instance id; key in NodeState's slot map.
    instance_id: []u8,
    /// Borrowed pointer to the tenant's app.db (for `_deploy/current`
    /// reads and customer kv ops).
    app_kv: *kv_mod.KvStore,
    /// Borrowed process raft node. The loader's `reloadDeployment`
    /// uses it to leader-gate + propose the `_config/**.json` mirror
    /// (auth-domain-plan §9: the release/loader path must mirror
    /// per-deploy config to kv — fixes the `7eb70ed` regression).
    /// Optional/`null` only in unit-test slot literals — a slot with
    /// no raft handle just skips the config mirror.
    raft: ?*kv_mod.RaftNode = null,
    /// Borrowed back-pointer to the owning NodeState. Set by
    /// `openTenantSlotNode`. Used by the deployment loader for
    /// cross-thread enqueues (Gap 2.1 Phase D boot firing →
    /// `node.enqueueSubscriptionFireForTenant`). Optional only in
    /// unit-test slot literals.
    node: ?*NodeState = null,
    /// Owned blob backend for file-blobs (source + bytecode bytes).
    blob_backend: blob_mod.BlobBackend,
    /// Owned blob backend for per-deployment manifest JSON.
    manifest_backend: blob_mod.BlobBackend,
    /// One-shot prefetched manifest from the cold-start batch fetch.
    /// Drained on the first reload that matches its dep_id.
    prefetched_manifest: ?PrefetchedManifest,
    /// Atomic pointer to the current snapshot. Null until first load.
    current: std.atomic.Value(?*TenantFilesSnapshot),
    /// Serializes `pinCurrent` (load + retain) against `reloadDeployment`
    /// (swap + release-old). Without this, a dispatcher could load
    /// the old pointer, the loader could swap-and-release it to
    /// refcount 0, and the dispatcher's retain would touch freed
    /// memory. Held only across the two-instruction critical sections
    /// — reload's manifest fetch / decode / fetch-bytecodes still
    /// runs unlocked.
    pin_lock: std.Thread.Mutex = .{},

    pub fn open(node: *NodeState, inst: *const tenant_mod.Instance) !*TenantSlot {
        return openTenantSlotNode(node, inst);
    }

    pub fn free(allocator: std.mem.Allocator, slot: *TenantSlot) void {
        freeTenantSlot(allocator, slot);
    }

    /// Try to pin the current snapshot for a request. Returns null
    /// if no deployment has loaded yet. Caller MUST `snap.release()`
    /// when done (typically at response time, after the raft drain
    /// for write requests).
    pub fn pinCurrent(self: *TenantSlot) ?*TenantFilesSnapshot {
        self.pin_lock.lock();
        defer self.pin_lock.unlock();
        const snap = self.current.load(.acquire) orelse return null;
        snap.retain();
        return snap;
    }

    /// Current snapshot's `deployment_id`, or 0 if no snapshot is
    /// loaded. Lock-free single-load; doesn't retain. Use for log
    /// records / metrics where we just want the value, not access.
    pub fn currentDeploymentId(self: *TenantSlot) u64 {
        const snap = self.current.load(.acquire) orelse return 0;
        return snap.deployment_id;
    }
};

/// Per-request view: slot pointer plus a pinned snapshot. Captured
/// at dispatch entry (`slot.pinCurrent()`), released after the
/// response moves to `response_in` (post-raft-drain for writes).
/// Field accesses pass through: `tc.slot.X` for tenant-lifetime
/// fields (app_kv, blob_backend, etc.); `tc.snap.X` for deployment-
/// version fields (bytecodes, statics, triggers).
pub const TenantFiles = struct {
    slot: *TenantSlot,
    snap: *TenantFilesSnapshot,

    pub fn release(self: TenantFiles) void {
        self.snap.release();
    }

    /// Open is no longer a thing — slots are opened, snapshots are
    /// loaded by the deployment loader. Kept as a compile error to
    /// surface old call sites that need updating.
    pub fn open(_: anytype, _: anytype) noreturn {
        @compileError("TenantFiles is a view; use `slot.pinCurrent()` to construct one");
    }

    pub fn free(_: std.mem.Allocator, _: *TenantFiles) noreturn {
        @compileError("TenantFiles is a view; release via `tc.release()`");
    }
};

/// Worker never uploads code, so the `CompileFn` it passes into
/// `FileStore.init` just errors out — making accidental put-source
/// calls impossible to ignore.
fn stubCompile(
    _: ?*anyopaque,
    _: []const u8,
    _: [:0]const u8,
    _: std.mem.Allocator,
) anyerror![]u8 {
    return error.CompileNotSupportedOnWorker;
}

/// Per-tenant log state held by the worker — currently just the
/// per-tenant `RequestIdMinter`. Opened eagerly in `Worker.create`,
/// closed in `Worker.destroy`.
///
/// The in-memory record buffer that used to live here has moved to
/// the worker-wide `log_buffer: NodeLogBuffer` (one buffer per node,
/// not per tenant), since every flush combines all tenants' records
/// into one batch anyway. See `docs/logs-plan.md` §3.1 / §6.9.
pub const TenantLog = struct {
    allocator: std.mem.Allocator,
    instance_id: []u8,
    id_minter: log_mod.RequestIdMinter,

    pub fn open(worker: anytype, inst: *const tenant_mod.Instance) !*TenantLog {
        return worker_log.openTenantLog(worker, inst, worker.log_worker_id);
    }

    pub fn free(allocator: std.mem.Allocator, tl: *TenantLog) void {
        worker_log.freeTenantLog(allocator, tl);
    }
};

/// Per-tenant body-buffer state held by the worker
/// (`docs/readset-replication-plan.md` Phase 2b). Owns the
/// `readset-blobs` BlobBackend opened against the node's shared
/// `blob_backend_cfg` plus a single-tenant `bodies_mod.BodyBuffer`
/// that accepts streaming appends from the H2 / curl_multi paths
/// and periodically flushes to S3.
///
/// Lazy-opened on first body via `getOrOpenTenantBodies` —
/// tenants that never receive a body pay no per-tenant RAM /
/// backend-handle cost. Closed in `Worker.destroy` via the
/// `TenantMap` deinit walk.
pub const TenantBodies = struct {
    allocator: std.mem.Allocator,
    instance_id: []u8,
    backend: blob_mod.BlobBackend,
    buffer: bodies_mod.BodyBuffer,

    pub fn open(worker: anytype, inst: *const tenant_mod.Instance) !*TenantBodies {
        return worker_bodies.openTenantBodies(worker, inst);
    }

    pub fn free(allocator: std.mem.Allocator, tb: *TenantBodies) void {
        worker_bodies.freeTenantBodies(allocator, tb);
    }
};

/// Cache wrapper around `StringHashMapUnmanaged(*Entry)` that drives
/// the lifecycle through `Entry.open(worker, inst)` and `Entry.free(
/// allocator, *Entry)`. `TenantFiles` and `TenantLog` had eight
/// near-identical helpers (open / free / destroyAll / getOrOpen × 2);
/// only open and free are domain-specific, so this generic absorbs
/// destroyAll and getOrOpen.
fn TenantMap(comptime Entry: type) type {
    return struct {
        const Self = @This();

        map: std.StringHashMapUnmanaged(*Entry) = .empty,

        pub const empty: Self = .{};

        /// Free every entry and the map's internal storage.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.clearAllEntries(allocator);
            self.map.deinit(allocator);
        }

        /// Free every entry but keep the map's internal capacity. Used
        /// by `Worker.create`'s errdefer path so a failure mid-eager-
        /// open clears the entries it created without preempting the
        /// final `deinit` that fires from `Worker.destroy`.
        pub fn clearAllEntries(self: *Self, allocator: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |entry| Entry.free(allocator, entry.value_ptr.*);
            self.map.clearRetainingCapacity();
        }

        /// Eagerly insert an already-opened entry. Worker.create uses
        /// this to prefill the map; the entry's owned `instance_id`
        /// becomes the map key (its lifetime matches the entry's).
        pub fn put(self: *Self, allocator: std.mem.Allocator, entry: *Entry) !void {
            try self.map.put(allocator, entry.instance_id, entry);
        }

        /// Lookup-or-lazy-open: if the map already has an entry for
        /// `inst`, return it. Otherwise open via `Entry.open`, cache,
        /// and return. On a failed `put`, frees the just-opened entry.
        pub fn getOrOpen(
            self: *Self,
            worker: anytype,
            inst: *const tenant_mod.Instance,
        ) !*Entry {
            if (self.map.get(inst.id)) |e| return e;
            const opened = try Entry.open(worker, inst);
            self.map.put(worker.allocator, opened.instance_id, opened) catch |err| {
                Entry.free(worker.allocator, opened);
                return err;
            };
            return opened;
        }

        pub fn get(self: *const Self, id: []const u8) ?*Entry {
            return self.map.get(id);
        }

        pub fn iterator(self: *Self) std.StringHashMapUnmanaged(*Entry).Iterator {
            return self.map.iterator();
        }
    };
}

pub const Options = struct {
    /// Application-specific components to attach to every request entity.
    /// Merged into h2's `StreamBaseRow` alongside rove-js's own
    /// `RaftWait` component. User fragments survive the whole lifecycle
    /// because every h2 stream collection (and rove-js's `raft_pending`)
    /// uses the merged row.
    request_row: type = rove.Row(&.{}),
    /// Application-specific components on h2 connections. Pass-through
    /// to `rove-h2`.
    connection_row: type = rove.Row(&.{}),
};

/// One pre-fetched manifest from the cold-start bulk fetch.
/// Owned bytes; freed by the worker after consumption (or at
/// shutdown if never consumed).
pub const PrefetchedManifest = struct {
    dep_id: u64,
    bytes: []u8,
};

/// Configuration for routing manifest reads through a files-server
/// cluster over HTTP/2 instead of fetching from S3 directly. Set
/// on `WorkerConfig.manifest_http` to opt in. See production.md
/// #1.4 step 4.
pub const ManifestHttpConfig = struct {
    /// Origin like `https://files.loop46.localhost:9090`. Borrowed;
    /// HttpBlobStore dupes internally so the caller can free
    /// after `Worker.create` returns.
    base_url: []const u8,
    /// Per-fetch JWT minter. Loop46 typically wires this to a
    /// closure over its `services_jwt_secret`. Borrowed.
    mint_jwt: blob_mod.http_blob.MintJwtFn,
    mint_ctx: ?*anyopaque = null,
    /// Optional CA bundle path for self-signed dev certs. Borrowed.
    ca_bundle_path: ?[]const u8 = null,
    /// Production: true. Dev / smoke against self-signed cert: false.
    verify_tls: bool = true,
};

/// Manifest-prefetch slot map. Keys + value bytes are allocator-owned;
/// consumed at TenantFiles.open time (`fetchRemove` transfers ownership
/// out). Kept on NodeState so cold-start prefetch persists across the
/// transition from "main spawns workers" to "each worker boots".
pub const ManifestPrefetchMap = std.StringHashMapUnmanaged(PrefetchedManifest);

/// Process-wide state shared across every worker on a node.
/// Owned by `main.zig`; workers borrow `*NodeState`.
///
/// Hoisting per-worker fields here fixes three latent bugs the kvexp
/// cutover surfaced (see `docs/deployment-snapshots-plan.md`):
///
///   1. Per-worker bytecode duplication. The deployment cache is
///      pure read-only bytes between releases; one copy per process
///      is sufficient.
///   2. Fan-out race. A `/_system/release` POST goes to one worker
///      via SO_REUSEPORT; with per-worker `tenant_files_map` only
///      that worker reloads. Sharing the map means one reload reaches
///      every dispatcher on the node.
///   3. Cold-start duplication. Each worker walked `tenant.instances`
///      and opened its own TenantFiles + libcurl Easies. One process-
///      wide eager-open replaces N.
///
/// Phase 1 of the rollout — sharing the map + single loader fix
/// (1) and (2). Phase 2 layers in refcounted snapshots so the in-place
/// reload race goes away too. `tenant_logs` stays per-worker because
/// `RequestIdMinter` bakes the worker_id into the request id's upper
/// 16 bits — sharing the minter would alias request ids across
/// workers.
pub const NodeState = struct {
    allocator: std.mem.Allocator,

    /// Shared tenant resolver (instances + domain → instance map).
    /// Borrowed; owned by `main.zig`.
    tenant: *tenant_mod.Tenant,

    /// Per-tenant slot cache. `tenant_files_lock` guards `getOrOpen`
    /// puts; the TenantSlot entries' deployment-version content is
    /// served via an atomic-pointer-swapped `TenantFilesSnapshot`
    /// (phase 2 of `docs/deployment-snapshots-plan.md`), so reload
    /// no longer races with the dispatcher.
    tenant_files_map: TenantMap(TenantSlot) = .empty,
    tenant_files_lock: std.Thread.Mutex = .{},

    /// Single deployment loader thread for the whole process.
    /// `_deploy/current` changes from any worker / apply path enqueue
    /// here; one reload reaches every worker. Replaces the per-worker
    /// loader + `deployment_loader_publish` atomic plumbing in
    /// `main.zig`. Allocated in `NodeState.init`; the load function
    /// thunk is `deploymentLoadFnNode`.
    deployment_loader: ?*deployment_loader_mod.DeploymentLoader = null,

    /// Single leader-local http.send dispatch component for the whole
    /// process (Option (b), FORK-6). Owns the in-memory in-flight set
    /// fed worker-side at commit (4b-ii) and reconstructed via
    /// boot-scan on raft promotion (4b-iii); the dedicated thread
    /// fires due owed sends (4c). NOT replicated/durable — the
    /// durable truth is the per-tenant `_send/owed/` kv. Allocated in
    // Phase 5 PR-3: the per-node `SendDispatch` slot retired with
    // the kernel. Outbound durability lives in the JS shim now
    // (`globals/webhook.js`) — see `sweepOwedRetries` for the
    // leader-side fire mechanism.

    /// Process-wide config consumed by TenantFiles.open. Shared
    /// pointers (libcurl Easy, prefetch map) live for the lifetime
    /// of NodeState.
    blob_backend_cfg: blob_mod.BackendConfig,
    manifest_http: ?ManifestHttpConfig = null,
    manifest_easy: ?*blob_mod.curl.Easy = null,
    manifest_prefetch: ?ManifestPrefetchMap = null,

    /// Process raft node (= `cluster.raft`). Borrowed; owned by
    /// `main.zig`. Copied into each `TenantSlot` so the loader's
    /// `reloadDeployment` can leader-gate + propose the config mirror.
    raft: *kv_mod.RaftNode,

    /// streaming-handlers-plan §4.6: registry of per-worker kv-wake
    /// inboxes. Workers register their inbox at startup; producers
    /// (apply.zig writeset apply on followers + worker_dispatch.zig
    /// leader-side eager fire) call `broadcastKvWake` to fan out.
    /// Per-worker (not node-wide) so each worker only scans cells it
    /// owns — matches plan §4.1's "registry is per-worker" rule. The
    /// `mutex` guards the registry vector itself (registration races
    /// at worker startup); individual inboxes have their own mutex.
    wake_inboxes_mutex: std.Thread.Mutex = .{},
    wake_inboxes: std.ArrayListUnmanaged(*KvWakeInbox) = .empty,

    /// Effect-reification Phase 2E: unified per-worker Msg inbox
    /// registry. Replaces the pre-2E pair (`sub_fire_inboxes` +
    /// `fetch_chunk_inboxes`) — one registry, one push path,
    /// `hash(tenant_id) % N_inboxes` for hash-by-tenant stickiness.
    /// Producers from non-worker threads (`deployment_loader` for
    /// boot, the cron sweeper, the `FetchPool` libcurl threads) call
    /// `enqueueMsgForTenant`; the typed wrappers
    /// `enqueueSubscriptionFireForTenant` /
    /// `enqueueFetchEventForTenant` build the matching `effect.Msg`
    /// variant and route through it.
    msg_inboxes_mutex: std.Thread.Mutex = .{},
    msg_inboxes: std.ArrayListUnmanaged(*effect_mod.MsgInbox) = .empty,

    /// Gap 2.1 Phase F: in-memory `next_fire_at_ns` per cron
    /// subscription. Keyed by `<tenant_id>|<sub_name>`. NOT raft-
    /// replicated — leader change resets the cron clock; the next
    /// fire happens roughly `interval_ms` after leadership is
    /// gained on the new leader (rebuilt by the sweep's first
    /// pass). Trade-off: long-interval crons may pause up to an
    /// interval after failover. Acceptable for v1; customer
    /// idempotency / missed-tick tolerance per
    /// `docs/subscriptions-plan.md` §7. Owned by NodeState.
    cron_state_mutex: std.Thread.Mutex = .{},
    cron_state: std.StringHashMapUnmanaged(i64) = .empty,

    /// Phase 5 PR-2b: built-in `__system/*` module bytecodes,
    /// compiled once at `init` from sources baked into the binary
    /// (see `src/js/builtin_modules.zig`). Shared across every
    /// tenant context — the shim's onresult handler runs against
    /// these bytecodes, not against per-tenant deployment files.
    /// `resolveDeployment` falls through to this when `module_path`
    /// starts with `__system/`.
    builtin_modules: std.StringHashMapUnmanaged([]u8) = .empty,

    /// Per-chain tape budget tracker (`docs/primitive-gaps.md` §6).
    /// Keyed by `correlation_id` (string-owned). Each chain
    /// accumulates `bytes_used` across all its activations; hitting
    /// `TAPE_CAP_BYTES_PER_CHAIN` flips `capped = true` and
    /// `captureTapes` returns empty payloads for subsequent
    /// activations of that chain. Sharded by `hash(correlation_id)
    /// & (TAPE_STATE_SHARDS - 1)` because the cap probe + charge
    /// run on every inbound activation (4 sites in `dispatchOnce`)
    /// — a single global mutex measured as a ~4× regression.
    tape_state_shards: [TAPE_STATE_SHARDS]TapeStateShard = [_]TapeStateShard{.{}} ** TAPE_STATE_SHARDS,

    /// Worker-side propose-pipeline observability. Observed at
    /// `finalizeBatch` exit with the number of handler-bound
    /// requests in this writeset envelope. Combined with the
    /// leader-side `RaftNode.proposal_batch_size`, answers "how
    /// many customer requests ride one raft log entry".
    dispatch_writeset_size: kv_mod.CountHistogram = .{},

    // Effect-reification Phase 2E: `fetch_chunk_inboxes` collapsed
    // into the unified `msg_inboxes` registry above. `FetchEngine`
    // calls `enqueueFetchEventForTenant` which builds the appropriate
    // `effect.Msg` and routes through the same hash-by-tenant
    // registry as subscriptions and (future) inbound HTTP.

    /// `docs/curl-multi-plan.md` Phase 2: the outbound-fetch engine.
    /// One thread + one `curl_multi` handle drives many concurrent
    /// transfers (replaces the prior 8-thread FetchPool ceiling).
    /// Lazy init via `startFetchEngine` after NodeState is wired +
    /// workers spawned. Producers (worker batch-finalize) call
    /// `enqueuePendingFetches` which routes to `engine.submit`; the
    /// engine drains its internal queue + fires libcurl + chunks
    /// the response + calls `enqueueFetchEventForTenant`.
    fetch_engine: ?*fetch_engine_mod.FetchEngine = null,

    pub fn init(
        allocator: std.mem.Allocator,
        tenant: *tenant_mod.Tenant,
        blob_backend_cfg: blob_mod.BackendConfig,
        raft: *kv_mod.RaftNode,
    ) !NodeState {
        // Phase 5 PR-2b: compile every `__system/*` built-in module
        // at startup. Bake them once; share across tenants via
        // `resolveDeployment`'s fallback. Failure here is fatal —
        // a baked module that won't compile is a build-time bug.
        var builtins = try builtin_modules_mod.init(allocator);
        errdefer builtin_modules_mod.deinit(&builtins, allocator);

        return .{
            .allocator = allocator,
            .tenant = tenant,
            .blob_backend_cfg = blob_backend_cfg,
            .raft = raft,
            .builtin_modules = builtins,
        };
    }

    /// Register a worker's wake inbox at worker startup. Worker
    /// keeps the inbox; this registry just borrows the pointer so
    /// producers can fan out. The pointer must outlive every
    /// `broadcastKvWake` call — workers must `unregisterWakeInbox`
    /// from their destroy path before tearing down.
    pub fn registerWakeInbox(self: *NodeState, inbox: *KvWakeInbox) !void {
        self.wake_inboxes_mutex.lock();
        defer self.wake_inboxes_mutex.unlock();
        try self.wake_inboxes.append(self.allocator, inbox);
    }

    pub fn unregisterWakeInbox(self: *NodeState, inbox: *KvWakeInbox) void {
        self.wake_inboxes_mutex.lock();
        defer self.wake_inboxes_mutex.unlock();
        var i: usize = 0;
        while (i < self.wake_inboxes.items.len) : (i += 1) {
            if (self.wake_inboxes.items[i] == inbox) {
                _ = self.wake_inboxes.swapRemove(i);
                return;
            }
        }
    }

    /// Gap 2.1 Phase D: register a worker's subscription-fire
    /// inbox. Same lifecycle as `registerWakeInbox` — worker keeps
    /// the inbox; this registry borrows the pointer for hash-routed
    /// fire enqueues.
    /// Effect-reification Phase 2E: register a worker's unified Msg
    /// inbox. The producer-side enqueueXxxForTenant functions
    /// hash-route to one of these by `hash(tenant_id) % N`. Returns
    /// the inbox's slot index in `msg_inboxes` — workers store it so
    /// the per-worker partitioned sweeps (Phase 5 PR-3:
    /// `sweepOwedRetries`) can match the same `hash(tenant_id) % N`
    /// that `enqueueMsgForTenant` would route to.
    pub fn registerMsgInbox(self: *NodeState, inbox: *effect_mod.MsgInbox) !usize {
        self.msg_inboxes_mutex.lock();
        defer self.msg_inboxes_mutex.unlock();
        const idx = self.msg_inboxes.items.len;
        try self.msg_inboxes.append(self.allocator, inbox);
        return idx;
    }

    pub fn unregisterMsgInbox(self: *NodeState, inbox: *effect_mod.MsgInbox) void {
        self.msg_inboxes_mutex.lock();
        defer self.msg_inboxes_mutex.unlock();
        var i: usize = 0;
        while (i < self.msg_inboxes.items.len) : (i += 1) {
            if (self.msg_inboxes.items[i] == inbox) {
                _ = self.msg_inboxes.swapRemove(i);
                return;
            }
        }
    }

    /// Hash-route `msg` onto the destination worker's `MsgInbox` by
    /// `hash(tenant_id) % N`. The typed wrappers
    /// (`enqueueSubscriptionFireForTenant`, `enqueueFetchEventForTenant`)
    /// build the variant + call this. On success ownership of `msg`'s
    /// owned bytes transfers to the inbox; on error.NoWorkers the
    /// caller retains and MUST `effect.freeOwnedMsg` to free.
    pub fn enqueueMsgForTenant(
        self: *NodeState,
        tenant_id: []const u8,
        msg: effect_mod.Msg,
    ) !void {
        self.msg_inboxes_mutex.lock();
        const n = self.msg_inboxes.items.len;
        if (n == 0) {
            self.msg_inboxes_mutex.unlock();
            return error.NoWorkers;
        }
        const inbox_idx = std.hash.Wyhash.hash(0, tenant_id) % n;
        const inbox = self.msg_inboxes.items[inbox_idx];
        self.msg_inboxes_mutex.unlock();
        try inbox.push(msg);
    }

    /// `docs/curl-multi-plan.md` Phase 2: hand each PendingFetch to
    /// `FetchEngine.submit`. The handler accumulated these into a
    /// caller-owned list during its run; the worker calls this at
    /// batch-finalize time (handler completed without throwing).
    /// Ownership of every slice transfers from the caller's list
    /// into the engine; the caller MUST clear its source list after
    /// this returns so its defer doesn't double-free.
    ///
    /// If `fetch_engine` is null (not yet started, or already shut
    /// down) the entries are silently dropped — same posture as
    /// the previous "queued in fetch_pending; freed at deinit"
    /// (the customer's chain never fires; nothing to recover at
    /// shutdown). A warning logs once via the engine's own
    /// no-inbox latch.
    pub fn enqueuePendingFetches(
        self: *NodeState,
        items: []const globals.PendingFetch,
    ) !void {
        if (items.len == 0) return;
        const engine = self.fetch_engine orelse {
            // Engine not running. Free the items the caller passed
            // (they were going to be freed by the caller's defer on
            // the empty-after-flush path; we own them now since the
            // caller clears the list expecting we took ownership).
            for (items) |pf_const| {
                var pf = pf_const;
                pf.deinit(self.allocator);
            }
            return;
        };
        for (items) |pf| try engine.submit(pf);
    }

    /// Gap 2.3 Phase C2 + effect-reification Phase 2E: hash-route a
    /// fetch event (chunk / end / pipe_done) to the destination
    /// worker's unified `MsgInbox` as the matching `effect.Msg`
    /// variant. Caller-side ownership of every owned slice in `ev`
    /// transfers in on success; on `error.NoWorkers` the caller
    /// retains and is responsible for `UpstreamFetchEvent.deinitItem`.
    pub fn enqueueFetchEventForTenant(
        self: *NodeState,
        tenant_id: []const u8,
        ev: components_mod.UpstreamFetchEvent,
    ) !void {
        // Phase 5 PR-1: single `fetch_chunk` Msg variant; the
        // event's `final` flag distinguishes streaming intermediates
        // from the terminal.
        const msg: effect_mod.Msg = .{ .fetch_chunk = ev };
        try self.enqueueMsgForTenant(tenant_id, msg);
    }

    /// Gap 2.1 Phase D + effect-reification Phase 2E: hash-route a
    /// subscription fire (cron / kv-react / boot) to the destination
    /// worker's unified `MsgInbox` as a `SubscriptionFire` variant.
    /// Producer (loader / sweeper) owns the input slices borrowed;
    /// this fn dupes onto the payload before pushing.
    /// Returns `error.NoWorkers` if no inbox is registered yet
    /// (cold start before any worker spawned).
    pub fn enqueueSubscriptionFireForTenant(
        self: *NodeState,
        in: SubscriptionFireQueueInput,
    ) !void {
        const allocator = self.allocator;
        const tid = try allocator.dupe(u8, in.tenant_id);
        errdefer allocator.free(tid);
        const name = try allocator.dupe(u8, in.subscription_name);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, in.module_path);
        errdefer allocator.free(path);

        const source: effect_mod.msg.SubscriptionFire.Source = switch (in.source) {
            .cron => |c| .{ .cron = .{ .fired_at_ns = c.fired_at_ns } },
            .kv => |k| blk: {
                const key_dup = try allocator.dupe(u8, k.key);
                break :blk .{ .kv = .{ .key = key_dup, .op = k.op } };
            },
            .boot => |b| .{ .boot = .{ .deployment_id = b.deployment_id } },
        };
        errdefer switch (source) {
            .kv => |kv| allocator.free(kv.key),
            else => {},
        };

        const payload: effect_mod.msg.SubscriptionFire = .{
            .tenant_id = tid,
            .subscription_name = name,
            .module_path = path,
            .source = source,
        };
        try self.enqueueMsgForTenant(in.tenant_id, .{ .subscription_fire = payload });
    }

    /// Phase 5 PR-2: hash-route a chained dispatch — a `__rove_next`
    /// returned from a `fetch_chunk` handler — to the destination
    /// worker's MsgInbox as a `SendCallback` variant. The customer's
    /// next-hop handler runs there with `request.activation.kind ==
    /// "send_callback"` and the cont's ctx wrapped as
    /// `request.body = {"ctx": <ctx>}`. Producer-owned slices are
    /// dup'd onto the payload; on `error.NoWorkers` the caller
    /// retains and frees them.
    pub fn enqueueChainedDispatchForTenant(
        self: *NodeState,
        tenant_id: []const u8,
        module_path: []const u8,
        ctx_json: []const u8,
        fn_name: ?[]const u8,
        correlation_id: ?[]const u8,
    ) !void {
        const allocator = self.allocator;
        const tid = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tid);
        const mod = try allocator.dupe(u8, module_path);
        errdefer allocator.free(mod);
        const ctx = try allocator.dupe(u8, ctx_json);
        errdefer allocator.free(ctx);
        const fn_dup: ?[]u8 = if (fn_name) |f| try allocator.dupe(u8, f) else null;
        errdefer if (fn_dup) |f| allocator.free(f);
        const corr_dup: ?[]u8 = if (correlation_id) |c| try allocator.dupe(u8, c) else null;
        errdefer if (corr_dup) |c| allocator.free(c);

        const payload: effect_mod.msg.SendCallback = .{
            .tenant_id = tid,
            .module_path = mod,
            .ctx_json = ctx,
            .fn_name = fn_dup,
            .correlation_id = corr_dup,
        };
        try self.enqueueMsgForTenant(tenant_id, .{ .send_callback = payload });
    }

    /// Fan out one kv-write event to every registered worker
    /// inbox. Called from `apply.zig` (follower path) and
    /// `worker_dispatch.zig` (leader path) so a write on any node
    /// reaches every locally-held stream regardless of which node
    /// + worker hosts it. A per-inbox push failure is logged and
    /// swallowed — the §9.4 "spurious + overflow" thesis lets us
    /// drop a wake; the worker that lost it will refetch authoritative
    /// state on its next activation anyway.
    pub fn broadcastKvWake(
        self: *NodeState,
        tenant_id: []const u8,
        key: []const u8,
        op: u8,
    ) void {
        self.wake_inboxes_mutex.lock();
        defer self.wake_inboxes_mutex.unlock();
        for (self.wake_inboxes.items) |inbox| {
            inbox.push(tenant_id, key, op) catch |err| {
                std.log.warn(
                    "rove-js kv-wake broadcast: push tenant={s} key={s}: {s}",
                    .{ tenant_id, key, @errorName(err) },
                );
            };
        }
    }

    pub fn deinit(self: *NodeState) void {
        // Gap 2.3 Phase C2: stop + join the fetch pool BEFORE any
        // other tear-down so its threads don't observe half-freed
        // state. Workers already deinit'd their fetch-chunk
        // inboxes in their own destroy path; we drained those
        // back the registry below.
        if (self.fetch_engine) |fe| {
            fe.shutdown();
            fe.deinit();
            self.fetch_engine = null;
        }
        // Drop the inbox registry first — workers destroy their
        // inboxes in their own deinit, so by the time NodeState
        // tears down, every inbox should already be unregistered.
        // The list itself is owned by NodeState's allocator.
        self.wake_inboxes.deinit(self.allocator);
        self.msg_inboxes.deinit(self.allocator);
        builtin_modules_mod.deinit(&self.builtin_modules, self.allocator);
        {
            var cs_it = self.cron_state.iterator();
            while (cs_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.cron_state.deinit(self.allocator);
        }
        for (&self.tape_state_shards) |*shard| {
            var ts_it = shard.map.iterator();
            while (ts_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            shard.map.deinit(self.allocator);
        }
        // `docs/curl-multi-plan.md` Phase 2: pending-fetches queue
        // moved into the FetchEngine; its shutdown above already
        // drained + freed any queued + in-flight entries.
        if (self.deployment_loader) |l| {
            l.shutdown();
            l.deinit();
            self.deployment_loader = null;
        }
        self.tenant_files_map.deinit(self.allocator);
        if (self.manifest_prefetch) |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*.bytes);
            }
            map.deinit(self.allocator);
            self.manifest_prefetch = null;
        }
    }

    /// Spawn the single deployment loader thread. Idempotent.
    /// Called once from `main.zig` after NodeState is fully wired
    /// (tenant + blob backends in place); the loader's thunk casts
    /// `ctx_opaque` back to `*NodeState`.
    pub fn startDeploymentLoader(self: *NodeState) !void {
        if (self.deployment_loader != null) return;
        const loader = try deployment_loader_mod.DeploymentLoader.init(
            self.allocator,
            @as(?*anyopaque, @ptrCast(self)),
            deploymentLoadFnNode,
        );
        errdefer loader.deinit();
        try loader.start();
        self.deployment_loader = loader;
    }

    /// `docs/curl-multi-plan.md` Phase 2: spawn the outbound
    /// `http.fetch` engine (one thread + one curl_multi handle).
    /// Idempotent. Called once from `main.zig` after NodeState is
    /// wired + workers have spawned (so their fetch-chunk inboxes
    /// are registered before the first chunk hash-routes through).
    pub fn startFetchEngine(self: *NodeState) !void {
        if (self.fetch_engine != null) return;
        const fe = try fetch_engine_mod.FetchEngine.init(self.allocator, self);
        errdefer fe.deinit();
        try fe.start();
        self.fetch_engine = fe;
    }

    /// Lookup-or-lazy-open under `tenant_files_lock`.
    /// Idempotent: concurrent callers may race on `openTenantSlotNode`
    /// (slow, runs unlocked); the loser frees its in-flight slot and
    /// returns the winner's.
    pub fn getOrOpenTenantSlot(
        self: *NodeState,
        inst: *const tenant_mod.Instance,
    ) !*TenantSlot {
        // Fast path: already cached.
        self.tenant_files_lock.lock();
        if (self.tenant_files_map.get(inst.id)) |existing| {
            self.tenant_files_lock.unlock();
            return existing;
        }
        self.tenant_files_lock.unlock();

        // Slow path: open without holding the lock (libcurl + blob
        // backend init may do I/O). Re-check under the lock before
        // inserting — another worker may have raced ahead.
        const opened = try openTenantSlotNode(self, inst);
        errdefer freeTenantSlot(self.allocator, opened);

        self.tenant_files_lock.lock();
        defer self.tenant_files_lock.unlock();
        if (self.tenant_files_map.get(inst.id)) |winner| {
            // Lost the race; drop our duplicate and use the winner.
            freeTenantSlot(self.allocator, opened);
            return winner;
        }
        try self.tenant_files_map.put(self.allocator, opened);
        return opened;
    }

    /// Cold-start eager-open: walk every known tenant, populate the
    /// map, enqueue the loader to fetch every deployment in
    /// parallel. Called once from `main.zig` after the loader is
    /// up. Returns the count of tenants opened.
    pub fn eagerOpenTenants(self: *NodeState) !usize {
        var count: usize = 0;
        var it = self.tenant.instances.iterator();
        while (it.next()) |entry| {
            const inst = entry.value_ptr.*;
            const slot = try self.getOrOpenTenantSlot(inst);
            count += 1;
            // Enqueue a deployment load for any tenant whose
            // `_deploy/current` is set — mirrors the old Worker.create
            // cold-start loop.
            if (self.deployment_loader) |l| {
                const cur_bytes = slot.app_kv.get("_deploy/current") catch continue;
                defer self.allocator.free(cur_bytes);
                const dep_id = std.fmt.parseInt(u64, cur_bytes, 16) catch continue;
                if (dep_id == 0) continue;
                l.enqueue(slot.instance_id, dep_id) catch |err| {
                    std.log.warn(
                        "rove-js: cold-start enqueue {s}/{d} failed: {s}",
                        .{ slot.instance_id, dep_id, @errorName(err) },
                    );
                };
            }
        }
        return count;
    }
};

/// Loader thunk for the single per-process loader. `ctx_opaque` is a
/// `*NodeState`. Looks up the tenant's TenantSlot (skip if absent),
/// short-circuits when the current snapshot already has this dep_id
/// (content-addressed: same id ⇒ same content), and calls
/// `reloadDeployment` otherwise. Phase 2: readers either see the old
/// snapshot or the new one, never a half-written mix.
fn deploymentLoadFnNode(
    ctx_opaque: ?*anyopaque,
    tenant_id: []const u8,
    dep_id: u64,
) anyerror!void {
    const node: *NodeState = @ptrCast(@alignCast(ctx_opaque.?));
    node.tenant_files_lock.lock();
    const slot_opt = node.tenant_files_map.get(tenant_id);
    node.tenant_files_lock.unlock();
    const slot = slot_opt orelse blk: {
        // Runtime-created tenant (signup, admin createInstance):
        // the apply.zig enqueue fires before any request has
        // lazy-opened the slot. Open it here so the snapshot
        // lands; otherwise the first request to the new tenant
        // 503s until the next reload event.
        const inst_opt = node.tenant.getInstance(tenant_id) catch null;
        const inst = inst_opt orelse return; // tenant not on this node
        break :blk node.getOrOpenTenantSlot(inst) catch |err| {
            std.log.warn(
                "rove-js: lazy slot-open for runtime tenant {s} failed: {s}",
                .{ tenant_id, @errorName(err) },
            );
            return;
        };
    };
    // Content-addressed dep_ids: same id ⇒ same content. Skip the
    // re-fetch + snapshot rebuild when the current snapshot already
    // matches.
    if (slot.currentDeploymentId() == dep_id) return;
    try reloadDeployment(slot, dep_id);
}

pub const WorkerConfig = struct {
    /// Node-wide shared state (tenant resolver, tenant_files_map,
    /// deployment_loader, blob_backend_cfg, ...). Borrowed; owned by
    /// `main.zig`. Workers reach shared state via `worker.node`.
    node: *NodeState,
    /// Raft node for write replication. All writes captured during a
    /// handler are proposed through this node; the worker blocks until
    /// the proposal commits or faults before sending the response.
    /// Owned by the caller — the worker does NOT drive `run()` on it,
    /// the caller spawns the raft thread. In M1 this is a single-node
    /// cluster (auto-leader). Multi-node arrives later.
    raft: *kv_mod.RaftNode,
    /// Listen address passed through to rove-io.
    addr: std.net.Address,
    /// rove-io options (ring size, buffer pool). Defaults are sensible.
    io_opts: rio.IoOptions = .{},
    /// rove-h2 options (window sizes, limits).
    h2_opts: h2.H2Options = .{},
    /// Upper bound on how long a parked raft proposal can wait before
    /// we compensate-rollback and return 503. See `RaftWait` docs.
    commit_wait_timeout_ns: u64 = 2 * std.time.ns_per_s,
    /// Phase 5.5(a) Step B / Phase 5.5(e) Step F1 — HMAC-SHA256
    /// secret used to sign JWTs minted at `/_system/services-token`.
    /// The standalone log-server + files-server (separate threads /
    /// processes, addressable at `log_public_base` + `files_public_base`)
    /// verify the same JWT on every request. Borrowed; the caller
    /// keeps the bytes alive for the worker's lifetime. When null,
    /// `/_system/services-token` returns 503.
    services_jwt_secret: ?[]const u8 = null,
    /// Public origin the dashboard uses to reach the log-server.
    /// Returned in the `/_system/services-token` response. Borrowed.
    log_public_base: ?[]const u8 = null,
    /// Public origin the dashboard / CLI uses to reach files-server.
    /// Returned in the `/_system/services-token` response. Borrowed.
    files_public_base: ?[]const u8 = null,
    /// Skip TLS peer verification on the worker's **internal-service**
    /// POSTs. Currently gates only the log-server push path
    /// (`sendPushChunk`). Set true in dev / smoke clusters with
    /// self-signed internal certs; production must leave this false.
    internal_insecure_tls: bool = false,
    /// Origin allowed to call `/_system/*` with CORS. When set, the
    /// worker answers browser preflight (OPTIONS) requests from this
    /// origin and stamps `Access-Control-Allow-*` headers onto every
    /// `/_system/*` response. Unset disables CORS entirely — admin UI
    /// callers must then be same-origin. The string is borrowed; the
    /// caller keeps it alive for the worker's lifetime.
    admin_origin: ?[]const u8 = null,
    /// Base domain for the per-tenant admin API. When set, any
    /// request whose Host is `admin_api_domain` exactly (scope =
    /// `__admin__`) or `{id}.{admin_api_domain}` (scope = `{id}`)
    /// runs the `__admin__` tenant's deployed handler with `kv`
    /// rebound to the scope's store. Root bearer token required.
    /// Borrowed; caller keeps it alive for the worker's lifetime.
    admin_api_domain: ?[]const u8 = null,
    /// Upper 16 bits of every `request_id` this worker's tenants
    /// mint. Must be unique per Worker instance within one process
    /// — if two workers on the same node both use the same id,
    /// their captured log records will collide on `nextRequestId`.
    /// When null, falls back to `raft.config.node_id`, which is
    /// correct for the single-worker-per-process case but wrong for
    /// multi-worker.
    log_worker_id: ?u16 = null,
    /// Per-(instance, action) rate limit caps. v1 uses a single
    /// tier — operator can tune via CLI flags before launch.
    /// Phase 10 will branch on instance plan tier.
    rate_limit_caps: limiter_mod.RateLimitCaps = .{},
    /// JS → bytecode compiler used by the signup path to deploy
    /// starter content for a freshly-created instance. When null,
    /// signup still creates the instance but skips the deploy, so
    /// the tenant's `{id}.loop46.me` returns 503 until the customer
    /// pushes their own code. The embedding binary is expected to
    /// wire a real QuickJS compiler through here in production.
    compile_fn: ?files_mod.CompileFn = null,
    /// Opaque pointer handed back to `compile_fn`. Per-thread —
    /// each worker thread typically gets its own compiler instance
    /// because QuickJS runtimes aren't shareable across threads.
    compile_ctx: ?*anyopaque = null,
    // Process-wide deployment config (blob_backend, manifest_http,
    // manifest_easy, manifest_prefetch) lives on `NodeState`. Reach
    // it via `worker.node`.

    /// Phase 5.5 (a) — `BatchStore` the worker flushes log batches
    /// into. loop46 always supplies one — S3 if env wired, in-memory
    /// otherwise. Required because `flushLogs` shouldn't have to
    /// reason about a missing observability backend.
    log_batch_store: log_server_mod.batch_store.BatchStore,
};

pub const dispatchOnce = dispatch.dispatchOnce;

pub fn Worker(comptime opts: Options) type {
    // rove-js contributes `RaftWait` to every request entity so we can
    // park entities in `raft_pending` without allocating side state.
    // No proxy components anymore — Phase 5.5 retired all `/_system/*`
    // proxies (logs Step B, files Step F1) in favor of standalone
    // services on their own subdomains.
    //
    // Phase 1 of the handler-cmds refactor
    // (`docs/handler-cmds-refactor-plan.md`): cont + stream state
    // components ride on every h2 stream collection + worker
    // `parked_continuations` + worker `raft_pending`. Non-cont /
    // non-stream entities carry default-empty instances; the SoA
    // cost is the per-entity overhead the open question in the plan
    // doc bounded at ~324 bytes (≈3 MB at 10k concurrent). Phase 2-4
    // flips readers from the side stores to these components; Phase
    // 5 splits raft_pending into siblings + Phase 7 deletes the side
    // stores.
    const merged_request_row = rove.Row(&.{
        RaftWait,
        BodyDurabilityWait,
        components_mod.ChainContext,
        components_mod.ContDescriptor,
        components_mod.StreamChain,
        components_mod.StreamChunks,
        components_mod.StreamWakes,
        components_mod.StreamDraining,
    }).merge(opts.request_row);

    const H2Type = h2.H2(.{
        .request_row = merged_request_row,
        .connection_row = opts.connection_row,
        .client = true,
    });

    const StreamRow = H2Type.StreamRow;
    const StreamColl = rove.Collection(StreamRow, .{});

    // Effect-reification Phase 2C: the `subscription_fire_pending`
    // collection that lived here is gone. Every producer (cron + boot
    // via `drainSubFireInbox`, kv-react via `fireKvReactSubscriptions`)
    // now routes through `effect.enqueueMsg` onto `Worker.msg_queue`;
    // `dispatchSubscriptionFires` drains the queue. The cross-thread
    // `SubscriptionFireInbox` stays as the boundary for non-worker
    // producers.

    // Worker-only collection for entity-less post-propose parked
    // units (`parkSendOps` / `parkKvWakes` / `proposeForgetfulWrites`).
    // The flat `ArrayList<ParkedUnit>` predecessor required manual
    // iterate-then-swapRemove inside drainRaftPending, which bit us
    // with the iterate-while-modify GPE during Gap 2.1 Phase E.
    // Collection-as-state gives deferred-destroy re-entrancy safety
    // by construction (rove principle #1) + structural deinit
    // (principle #2: data lifetime through components).
    const ParkedUnitRow = rove.Row(&.{ParkedUnit});
    const ParkedUnitColl = rove.Collection(ParkedUnitRow, .{});

    // Effect-reification Phase 2D: the `fetch_event_pending`
    // collection that lived here is gone. Inbox messages drain
    // directly onto `Worker.msg_queue` (the unified ingress);
    // `dispatchPendingMsgs` fires them per tick. Twin of the
    // 2C `subscription_fire_pending` retirement.

    return struct {
        const Self = @This();

        pub const H2 = H2Type;
        pub const RequestRow = StreamRow;

        allocator: std.mem.Allocator,
        reg: *rove.Registry,
        h2: *H2Type,
        /// Entities waiting on raft commit, destined for `response_in`
        /// (terminal response, no cont/stream chain). Stored on the
        /// Worker (not inside h2) because this is rove-js state, not
        /// h2 state. Uses the same row as every other h2 stream
        /// collection so moves in and out preserve every component.
        ///
        /// Handler-cmds Phase 5: `raft_pending` was split into three
        /// siblings (`raft_pending_response` / `raft_pending_cont` /
        /// `raft_pending_stream`) — the entity's collection IS the
        /// dispatch state, no `desc.cont != null` or
        /// `pending_stream_meta.contains` field-check needed
        /// (principle #1, state-via-collection-membership).
        raft_pending_response: StreamColl,
        /// Continuation-bound raft park. Commits route to
        /// `parked_continuations`. Same Row as `raft_pending_response`.
        raft_pending_cont: StreamColl,
        /// Stream-first-hop raft park. Commits route to
        /// `stream_response_in` (after registerStreamCell). Same Row.
        raft_pending_stream: StreamColl,
        /// `docs/readset-replication-plan.md` Phase 4 park-on-
        /// durability. Entities `dispatchPending` parked after
        /// appending their inbound body to the per-tenant
        /// `BodyBuffer`, waiting for the buffer's batch holding
        /// their body to flush to S3. `drainBodyPending` walks this
        /// collection on each main-loop tick, checking each entity's
        /// `BodyDurabilityWait.body_ref.batch_id` against the tenant
        /// buffer's `last_flushed_batch_id`; matches move back to
        /// `request_out` for re-dispatch (handler runs against the
        /// already-durable body).
        ///
        /// Same `StreamRow` as `raft_pending_*` / `request_out` so
        /// `reg.move` preserves every component on transit (the H2
        /// request headers / body / sid / etc. ride the entity until
        /// the response is built).
        body_pending: StreamColl,
        /// Continuation-trampoline parked streams (connection-actor
        /// §6.1/§6.4). A handler that returned `next(...)` parks here
        /// instead of `response_in`; collection membership IS the
        /// "held" lifecycle (`feedback_state_is_collection`), and
        /// `reg.move` out is both the resolve AND the resolve-once
        /// guard (a stream can leave a collection only once — a
        /// double-delivered outcome / deadline race finds it gone).
        /// Worker-owned sibling, same StreamRow as every h2
        /// collection so moves preserve all components — mirrors
        /// `raft_pending` exactly.
        parked_continuations: StreamColl,
        /// Streaming-handlers Phase 2b-ii: per-entity DATA side-store
        /// for active `__rove_stream(...)` chains. The entity lives
        /// in the h2 module's `stream_data_out` collection (h2 owns
        /// its in-flight state); this map holds the chain-level
        /// state the worker's tick loop needs (chunks queue, next
        /// wake time, activation count, ctx-for-resume, etc.).
        /// Lifecycle: the entity's `stream_data_out` membership IS
        /// alive; on close (handler returns `Response` or cap hits),
        /// the entity moves to `stream_close_in` (h2 sends END_STREAM)
        /// and the map entry is removed.
        // Phase 7: `parked_streams_active` + `parked_streams_draining`
        // side tables removed. Stream state lives on the entity's
        // `ChainContext` / `StreamChain` / `StreamChunks` /
        // `StreamWakes` components; the "drain-and-close" flag lives
        // on `StreamDraining.is_draining`.
        // Phase 7: `pending_stream_meta` removed — stream components
        // are populated in `streamRecordIfAnyAt` (Phase 4a) before
        // the entity moves into `raft_pending_stream`; the meta's
        // owned slices are freed there too. The raft_pending_stream
        // drainEntityArm just moves the entity to stream_response_in
        // on commit; no side-table consume.
        /// Per-worker kv-wake inbox (streaming-handlers-plan §4.6).
        /// Producers (apply.zig + leader-side worker_dispatch) push
        /// events here via `worker.node.broadcastKvWake`;
        /// `serviceParkedStreams` drains it at the start of each
        /// tick and matches events against `parked_streams_meta`
        /// cells' `kv_prefixes`. Pointer registered with
        /// `worker.node.registerWakeInbox` in `Worker.create`;
        /// unregistered + deinit'd in `Worker.destroy`.
        wake_inbox: KvWakeInbox,
        /// Deferred TrackedTxn commits keyed by raft seq. Per kvexp
        /// README §1 (speculative apply): `txn.commit` runs after raft
        /// confirms the batch's seq, not before propose. On propose
        /// failure or raft fault, the txn is `rollback`'d instead.
        /// Single-threaded per worker (the dispatch loop owns it).
        ///
        /// Effect-reification Phase 3.2.c: encapsulated as
        /// `effect.SharedTxnPool` (was: bare `AutoHashMapUnmanaged`).
        /// The pool exposes `park` / `commitAndTake` / `rollbackAndTake`
        /// + `CommitOutcome` / `RollbackOutcome` so producer + consumer
        /// sites consult ONE typed surface instead of poking at the
        /// hashmap directly. The architectural fact (multiple
        /// entities per seq) is documented on the pool — see
        /// `effect/continuation.zig`'s `SharedTxnPool` doc.
        pending_txns: effect_mod.SharedTxnPool(*kv_mod.KvStore.TrackedTxn) = .{},
        /// Non-entity post-propose parked units (divergence
        /// workstream idiom-1). Serviced by `drainRaftPending`
        /// alongside (but independently of) the H2 `raft_pending`
        /// entity path. Each unit is a fresh entity in the
        /// collection with a `ParkedUnit` component; `reg.destroy`
        /// (deferred to `reg.flush`) removes it on commit/fault.
        /// State-as-membership: presence in the collection IS the
        /// "awaiting raft commit" state.
        parked_units: ParkedUnitColl,
        /// Effect-reification Phase 2 ingress
        /// (`docs/effect-algebra.md` §2.3; `effect-reification-plan.md`
        /// Phase 2). One bounded queue per worker; every migrated
        /// origin routes into it via `effect.enqueueMsg`. Phase 2B
        /// routes cron + boot; 2C routes kv-react; 2D routes outbound
        /// HTTP (fetch chunk / done / pipe_done); 2E (this phase)
        /// collapses the cross-thread inbox layer (see `msg_inbox`
        /// below). Inbound-HTTP dispatch stays entity-driven through
        /// h2 — Phase 3's reconciler scope.
        msg_queue: effect_mod.MsgQueue = undefined,
        /// Effect-reification Phase 2E: unified cross-thread Msg
        /// inbox. Replaces the pre-2E pair (`sub_fire_inbox` +
        /// `fetch_chunk_inbox`). Producers from non-worker threads
        /// (deployment-loader boot, cron sweep, FetchPool libcurl
        /// threads) `node.enqueueMsgForTenant`-hash-route here;
        /// `drainMsgInbox` (once per tick from `serviceSubscriptionFires`
        /// / `serviceFetchEvents`) moves Msgs onto `msg_queue`.
        msg_inbox: effect_mod.MsgInbox = undefined,
        /// Gap 2.1 Phase F: monotonic-ns of the last
        /// `sweepCronSubscriptions` invocation. Used to throttle
        /// the per-tick cron sweep to at most one pass per
        /// `CRON_SWEEP_INTERVAL_NS`. Worker-local because the
        /// sweep runs on worker 0 only.
        last_cron_sweep_ns: i64 = 0,
        /// Phase 5 PR-3: monotonic-ns of the last
        /// `sweepOwedRetries` invocation on THIS worker. Throttles
        /// the per-tick retry sweep to one pass per
        /// `SEND_SWEEP_INTERVAL_NS`. Per-worker (not just worker
        /// 0) because the sweep is partitioned —
        /// `hash(tenant_id) % N_msg_inboxes == self.msg_inbox_idx`.
        last_send_sweep_ns: i64 = 0,
        /// Phase 5 PR-3: deferred held-sync resumes. The baked
        /// `__system/webhook_onresult` shim calls
        /// `_system.continuation.resumeIfBound` on terminal; that
        /// trampoline appends `(tenant_id, send_id, event_json)`
        /// here instead of dispatching inline (the shim's batch txn
        /// is open; nesting `resumeBoundContinuation`'s
        /// `beginTrackedImmediate` would double-BEGIN). The worker
        /// tick drains this after `dispatchPendingMsgs` — by then
        /// the shim's txn is committed.
        pending_bound_resumes: std.ArrayListUnmanaged(PendingBoundResume) = .empty,
        /// Phase 5 PR-3: this worker's slot index in
        /// `node.msg_inboxes`. Set from `registerMsgInbox`'s
        /// return value at `create`. The per-worker partitioned
        /// retry sweep uses this to match the
        /// `hash(tenant_id) % N` routing that
        /// `enqueueMsgForTenant` would pick, so the entire retry
        /// chain (sweep → fetch → onresult → kv ops) stays on one
        /// worker per tenant.
        msg_inbox_idx: usize = 0,
        /// Per-tick accumulator for admin-handler side effects
        /// (`platform.root.*` + cross-tenant trampolines). Folded
        /// into the batch's single raft entry by `finalizeBatch`
        /// (Option-A, docs/proposer-audit.md Addendum 3). Reset at
        /// `dispatchOnce` entry and `finalizeBatch` exit.
        batch_side: BatchSideEffects = .{},
        /// Last-tick leader state. A true→false transition triggers
        /// the leadership-loss drain: every pending txn rolls back
        /// (kvexp recipe §2) and every `raft_pending` entry gets
        /// downgraded to 503.
        was_leader: bool = false,
        dispatcher: Dispatcher,
        /// Borrowed pointer to the process-wide shared state. Holds
        /// the tenant resolver, the single `tenant_files_map` (shared
        /// across all workers — fan-out gone), the single deployment
        /// loader, and the process-wide deployment config (blob
        /// backend, manifest_http / manifest_easy / manifest_prefetch).
        /// Owned by `main.zig`; outlives every worker.
        node: *NodeState,
        raft: *kv_mod.RaftNode,
        /// Per-tenant log state. NOT in NodeState because
        /// `RequestIdMinter` bakes the worker_id into the upper 16
        /// bits of every minted id — sharing the minter would alias
        /// ids across workers. Same lazy-open lifecycle as
        /// `tenant_files_map` but populated per-worker.
        tenant_logs: TenantMap(TenantLog),
        /// Per-tenant body-buffer state
        /// (`docs/readset-replication-plan.md` Phase 2b). Per-worker
        /// (not NodeState) because bodies arrive on the worker thread
        /// that owns H2 frame delivery + curl_multi events;
        /// kv-affinity hashing pins each tenant to one worker, so
        /// per-worker matches the natural data ownership. Lazy-opened
        /// on first body via `worker_bodies.getOrOpenTenantBodies`.
        tenant_bodies: TenantMap(TenantBodies),
        /// Guards `tenant_bodies` map structure: the worker main
        /// thread inserts via `getOrOpenTenantBodies` (Phase 2c
        /// append site), and the log-flusher thread iterates via
        /// `flushBodiesTick`. Each `TenantBodies.buffer` has its
        /// own internal mutex; this one protects the map itself.
        tenant_bodies_mu: std.Thread.Mutex = .{},
        /// Per-node in-memory `LogRecord` buffer. Every tenant's
        /// dispatch tick appends here; `flushLogs` drains the whole
        /// buffer into one combined batch per flush window. Replaces
        /// the per-tenant `LogStore.buffer` from before Phase 5.5(a-2).
        log_buffer: log_mod.NodeLogBuffer,
        /// Circuit breaker for handlers that blow past their CPU
        /// budget. A tenant with `kill_threshold` interrupts inside a
        /// single `window_ns` gets bounced with 503 for
        /// `open_duration_ns` — protecting the shared h2 thread from a
        /// runaway stored procedure. Auto-releases on redeploy.
        penalty_box: penalty_mod.PenaltyBox,
        /// Per-instance × per-action token-bucket limits. Single tier
        /// in v1 (`limiter_mod.defaultCaps()`); Phase 10 will branch
        /// on plan. Customer-tenant traffic checks the `request`
        /// bucket before dispatch and gets 429 + Retry-After when
        /// exhausted; admin requests bypass the check entirely.
        /// `email.send` from a handler checks the `email` bucket and
        /// throws a catchable JS Error{code:"rate_limited"} when
        /// exhausted.
        limiter: limiter_mod.RateLimiter,
        commit_wait_timeout_ns: u64,
        /// Borrowed from `WorkerConfig.admin_origin`. See the config
        /// field for semantics. Null when CORS is disabled.
        admin_origin: ?[]const u8,
        /// Borrowed from `WorkerConfig.admin_api_domain`. Hostname
        /// that hosts the admin API + dashboard. Null disables admin
        /// routing entirely. Cross-tenant scoping uses the
        /// `X-Rove-Scope: <id>` header on this host.
        admin_api_domain: ?[]const u8,
        /// Upper 16 bits every `RequestIdMinter.nextRequestId()`
        /// minted by this worker stamps onto ids so they don't
        /// collide with other workers' ids. Copied from
        /// `WorkerConfig.log_worker_id` (or the raft node id as a
        /// fallback).
        log_worker_id: u16,
        /// Compile callback used by signup to deploy starter content.
        /// Borrowed from `WorkerConfig.compile_fn` / `compile_ctx`.
        compile_fn: ?files_mod.CompileFn,
        compile_ctx: ?*anyopaque,
        // Process-wide deployment config (blob_backend_cfg,
        // manifest_http, manifest_easy, manifest_prefetch) lives on
        // `node`. Reach via `worker.node.blob_backend_cfg`, etc.

        /// Phase 5.5 (a) — store the worker flushes log batches into.
        /// Lives for the worker's full lifetime; loop46 picks S3 vs
        /// in-memory at startup.
        log_batch_store: log_server_mod.batch_store.BatchStore,
        /// Phase 5.5(a) Step B / Phase 5.5(e) Step F1 — JWT secret +
        /// public origins for the standalone services. Returned to the
        /// dashboard via `/_system/services-token`.
        services_jwt_secret: ?[]const u8,
        log_public_base: ?[]const u8,
        files_public_base: ?[]const u8,
        /// Internal-service POST insecure-TLS toggle (now log-push
        /// only — see the worker struct field doc).
        internal_insecure_tls: bool,
        /// libcurl handle for log-server push (`POST /v1/_internal/
        /// batch-pushed`). Lazily created when `log_public_base` is
        /// set. Null disables the push path; the indexer's 500ms
        /// LIST polling is the catch-up.
        log_push_curl: ?*blob_mod.curl.Easy,

        /// Background log flusher — owns its own thread, sleeps on
        /// `flusher_wake` between ticks, drains the worker's
        /// `log_buffer` via `flushLogs`, and PUTs each batch into
        /// `log_batch_store`. Decouples request latency from S3 RTT:
        /// the dispatch path's `captureLog` is now a mutex-protected
        /// ArrayList.append, with the multi-millisecond S3 round-
        /// trip happening asynchronously on this thread. `null` when
        /// the worker is configured without a log backend.
        flusher_thread: ?std.Thread = null,
        flusher_should_stop: std.atomic.Value(bool) = .init(false),
        flusher_wake: std.Thread.ResetEvent = .{},

        /// Async batched log-server push. Flushers append the S3 batch
        /// key they just PUT to `push_queue`; the `push_thread` drains
        /// the queue and POSTs all queued keys as one body to
        /// `/v1/_internal/batch-pushed`. Decouples the synchronous-
        /// curl cost from the flusher so a slow / unreachable
        /// log-server stops back-pressuring the dispatch path.
        /// `push_queue` owns each `[]u8` (allocator-duped from the
        /// flusher's local key).
        push_queue: std.ArrayList([]u8) = .empty,
        push_queue_mutex: std.Thread.Mutex = .{},
        push_wake: std.Thread.ResetEvent = .{},
        push_should_stop: std.atomic.Value(bool) = .init(false),
        push_thread: ?std.Thread = null,

        // Background deployment loader lives on `node` (single per
        // process, shared across workers). Reach via
        // `worker.node.deployment_loader`.

        /// Heap-allocate a worker, construct the inner `H2` (which in
        /// turn constructs its own `Io`), and eagerly open a
        /// `TenantFiles` for every instance currently registered with
        /// the tenant. Tenants that have no deployment yet get a
        /// `TenantFiles` with `handler_bytecode = null` — requests
        /// hitting them return 503 until a deploy lands.
        ///
        /// All tenants must exist BEFORE the raft thread starts, so
        /// create the worker after the tenant bootstrap but before
        /// spawning the raft thread. Dynamic tenant creation
        /// (lazy-open from the dispatch path) is a future session.
        pub fn create(
            allocator: std.mem.Allocator,
            reg: *rove.Registry,
            config: WorkerConfig,
        ) !*Self {
            const server = try H2Type.create(
                reg,
                allocator,
                config.addr,
                config.io_opts,
                config.h2_opts,
            );
            errdefer server.destroy();

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .reg = reg,
                .h2 = server,
                .raft_pending_response = try StreamColl.init(allocator),
                .raft_pending_cont = try StreamColl.init(allocator),
                .raft_pending_stream = try StreamColl.init(allocator),
                .body_pending = try StreamColl.init(allocator),
                .parked_continuations = try StreamColl.init(allocator),
                .parked_units = try ParkedUnitColl.init(allocator),
                .msg_inbox = effect_mod.MsgInbox.init(allocator),
                // Effect-reification Phase 2 ingress. Cap chosen
                // well above the typical per-tick fire rate (cron
                // ≤ 1 Hz × N tenants; boot drains once per deploy);
                // overflow surfaces `error.Full` + bumps
                // `overflow_count` for the per-origin caller to
                // log + drop (re-fire on next sweep).
                .msg_queue = effect_mod.MsgQueue.init(allocator, 4096),
                .dispatcher = try Dispatcher.init(allocator),
                .node = config.node,
                .raft = config.raft,
                .tenant_logs = .empty,
                .tenant_bodies = .empty,
                .log_buffer = log_mod.NodeLogBuffer.init(allocator),
                .penalty_box = penalty_mod.PenaltyBox.init(allocator, .{}),
                .limiter = limiter_mod.RateLimiter.init(allocator, config.rate_limit_caps),
                .commit_wait_timeout_ns = config.commit_wait_timeout_ns,
                .admin_origin = config.admin_origin,
                .admin_api_domain = config.admin_api_domain,
                .log_worker_id = config.log_worker_id orelse @intCast(config.raft.config.node_id),
                .compile_fn = config.compile_fn,
                .compile_ctx = config.compile_ctx,
                .log_batch_store = config.log_batch_store,
                .services_jwt_secret = config.services_jwt_secret,
                .log_public_base = config.log_public_base,
                .files_public_base = config.files_public_base,
                .internal_insecure_tls = config.internal_insecure_tls,
                .log_push_curl = blk: {
                    if (config.log_public_base == null) break :blk null;
                    break :blk blob_mod.curl.Easy.init(allocator) catch |err| {
                        std.log.warn("rove-js: log-push libcurl init failed: {s}; batch push disabled", .{@errorName(err)});
                        break :blk null;
                    };
                },
                .wake_inbox = KvWakeInbox.init(allocator),
            };
            errdefer self.raft_pending_response.deinit();
            errdefer self.raft_pending_cont.deinit();
            errdefer self.raft_pending_stream.deinit();
            errdefer self.body_pending.deinit();
            errdefer self.parked_continuations.deinit();
            errdefer self.parked_units.deinit();
            errdefer self.tenant_logs.clearAllEntries(allocator);
            errdefer self.tenant_bodies.clearAllEntries(allocator);
            errdefer self.wake_inbox.deinit();

            reg.registerCollection(&self.raft_pending_response);
            reg.registerCollection(&self.raft_pending_cont);
            reg.registerCollection(&self.raft_pending_stream);
            reg.registerCollection(&self.body_pending);
            reg.registerCollection(&self.parked_continuations);
            reg.registerCollection(&self.parked_units);

            // Register the inbox with the node so apply.zig +
            // worker_dispatch.zig can broadcast kv-write events to
            // this worker's locally-held streams. Address is stable
            // (`self` is heap-allocated above).
            try config.node.registerWakeInbox(&self.wake_inbox);
            errdefer config.node.unregisterWakeInbox(&self.wake_inbox);

            // Effect-reification Phase 2E: register the unified Msg
            // inbox with the node so every cross-thread producer
            // (deployment-loader boot, cron sweeper, FetchPool
            // libcurl threads) hash-routes here via
            // `node.enqueueMsgForTenant`. The returned slot index is
            // this worker's partition key for the per-worker
            // partitioned sweeps (`sweepOwedRetries` — Phase 5 PR-3).
            self.msg_inbox_idx = try config.node.registerMsgInbox(&self.msg_inbox);
            errdefer config.node.unregisterMsgInbox(&self.msg_inbox);

            // Eagerly open per-worker tenant_logs (request_id minters
            // bake the worker_id into the upper 16 bits; can't share).
            // TenantFiles + deployment loader are populated by main.zig
            // once in NodeState before workers spawn — no per-worker
            // duplication and no fan-out race.
            var it = config.node.tenant.instances.iterator();
            while (it.next()) |entry| {
                const inst = entry.value_ptr.*;
                try self.tenant_logs.put(allocator, try TenantLog.open(self, inst));
            }

            self.flusher_thread = try std.Thread.spawn(.{}, flusherLoop, .{self});

            // Spawn the push thread only if a libcurl handle was
            // built (i.e. `log_public_base` is set). Without it
            // pushBatchKey would short-circuit anyway; the thread
            // would just spin.
            if (self.log_push_curl != null) {
                self.push_thread = try std.Thread.spawn(.{}, worker_log.pushLoop, .{self});
            }

            return self;
        }

        /// Background log-flusher loop. Wakes every
        /// `FLUSHER_TICK_NS` (50 ms — matches the existing periodic
        /// scheduler default) OR immediately when `flusher_wake` is
        /// signalled. Calls `flushLogs(self)` which checks the node-
        /// wide `log_buffer` against its thresholds (count / bytes /
        /// time) and, when crossed, drains + PUTs through
        /// `log_batch_store`. The S3 RTT happens entirely on this
        /// thread — the dispatch path stays free of synchronous
        /// network I/O.
        ///
        /// Exits when `flusher_should_stop` flips true. We deliberately
        /// do NOT do a final blocking drain on shutdown — the last
        /// partial batch is best-effort, and a graceful stop must not
        /// block the worker process on a multi-second S3 PUT (which
        /// would in turn block whatever supervisor is waiting on the
        /// child). This matches the stated lossy-on-node-failure
        /// semantics in `docs/logs-plan.md`: in-flight log records
        /// can be lost on shutdown.
        fn flusherLoop(self: *Self) void {
            const FLUSHER_TICK_NS: u64 = 50 * std.time.ns_per_ms;
            while (!self.flusher_should_stop.load(.acquire)) {
                // Phase 4 park-on-durability: bodies flush FIRST.
                // `dispatchPending`'s priority-flush wake is the
                // dominant `flusher_wake.set()` caller now, and
                // every parked entity blocks until its body's
                // batch lands in S3. Running flushLogs ahead of
                // flushBodiesTick added that PUT's RTT (~30–100 ms)
                // to every parked dispatch's handler-run latency.
                // Reordered so bodies PUT unblocks parked
                // entities while logs continue piggy-backing the
                // 50 ms tick (slice 4-park-2).
                worker_bodies.flushBodiesTick(self);
                _ = worker_log.flushLogs(self) catch |err| {
                    std.log.warn("rove-js flusher: flushLogs failed: {s}", .{@errorName(err)});
                };
                self.flusher_wake.timedWait(FLUSHER_TICK_NS) catch {};
                self.flusher_wake.reset();
            }
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            // NodeState owns the deployment loader + tenant_files_map
            // + manifest_prefetch. Tenant-files cleanup runs from
            // `NodeState.deinit`, not here.
            // Signal the flusher thread to stop, wake it, and join.
            // The flusher's only blocking call is libcurl's
            // `curl_easy_perform`, which is bounded by `Easy`'s
            // 15 s `CURLOPT_TIMEOUT_MS` — so join can never wait
            // longer than one in-flight PUT plus the libcurl
            // ceiling. No detach / leak path needed.
            if (self.flusher_thread) |t| {
                self.flusher_should_stop.store(true, .release);
                self.flusher_wake.set();
                t.join();
                self.flusher_thread = null;
            }
            // Stop the push thread AFTER the flusher: the flusher
            // enqueues to push_queue, so stopping push first would
            // leak whatever the flusher emitted on its final tick.
            if (self.push_thread) |t| {
                self.push_should_stop.store(true, .release);
                self.push_wake.set();
                t.join();
                self.push_thread = null;
            }
            // Free any keys still queued at shutdown. Same
            // best-effort posture as flushLogs's final partial batch:
            // log-server will pick them up on its LIST poll.
            self.push_queue_mutex.lock();
            for (self.push_queue.items) |k| allocator.free(k);
            self.push_queue.deinit(allocator);
            self.push_queue_mutex.unlock();
            self.limiter.deinit();
            self.penalty_box.deinit();
            self.tenant_logs.deinit(allocator);
            self.tenant_bodies.deinit(allocator);
            self.log_buffer.deinit();
            // Phase 3.2.c: SharedTxnPool.deinit walks any leftover
            // txns (best-effort rollback) before freeing the
            // hashmap. Non-empty means we're exiting with
            // proposals still in flight (process kill / fatal
            // error); clean shutdown drains to empty first.
            self.pending_txns.deinit(allocator);
            // parked_units is a rove Collection; its deinit fires
            // each entity's `ParkedUnit.deinit` component-style,
            // then drops the collection.
            self.batch_side.reset(allocator);
            self.batch_side.targets.deinit(allocator);
            // Phase 7: side tables (parked_meta, parked_streams_active,
            // parked_streams_draining, pending_stream_meta) are gone.
            // All stream/cont state lives on the entities themselves;
            // rove `Collection.deinit` invokes each component's deinit
            // on shutdown (parked_continuations + the three
            // raft_pending_* siblings walked below).
            // Unregister + tear down the kv-wake inbox. Order
            // matters: unregister FIRST so no producer can still
            // be pushing into it while we walk + free the queue.
            self.node.unregisterWakeInbox(&self.wake_inbox);
            self.wake_inbox.deinit();
            // Effect-reification Phase 2E: one unified Msg inbox
            // replaces the pre-2E pair. Unregister BEFORE deinit so
            // no cross-thread producer (deployment-loader,
            // cron sweeper, FetchPool) can push after we start
            // freeing entries. `MsgInbox.deinit` walks the items
            // variant-aware via `freeOwnedMsg`.
            self.node.unregisterMsgInbox(&self.msg_inbox);
            self.msg_inbox.deinit();
            // MsgQueue.deinit walks variants (subscription_fire +
            // fetch_chunk / fetch_done / fetch_pipe_done) to free
            // in-flight Msg payloads at shutdown.
            self.msg_queue.deinit();
            // Phase 5 PR-3: any pending bound-resumes left at shutdown
            // — the leader change drain would have surfaced these, but
            // be defensive.
            for (self.pending_bound_resumes.items) |*p| p.deinit(allocator);
            self.pending_bound_resumes.deinit(allocator);
            self.parked_continuations.deinit();
            self.parked_units.deinit();
            self.raft_pending_response.deinit();
            self.raft_pending_cont.deinit();
            self.raft_pending_stream.deinit();
            self.body_pending.deinit();
            self.dispatcher.deinit();
            if (self.log_push_curl) |easy| easy.deinit();
            // `manifest_easy` lives on NodeState — main.zig owns it.
            self.h2.destroy();
            allocator.destroy(self);
        }

        /// Forward to the h2 poll loop. Exposed so callers don't have to
        /// reach into `worker.h2` for the common case.
        pub fn poll(self: *Self, min_complete: u32) !void {
            try self.h2.poll(min_complete);
        }

        /// Forward to h2's bounded-wait poll. Use this when there's
        /// external state needing periodic attention (parked entities
        /// in `raft_pending`, deployment refresh deadlines, etc.) so
        /// the loop neither blocks indefinitely nor spins at 100% CPU.
        pub fn pollWithTimeout(self: *Self, timeout_ns: u64) !void {
            try self.h2.pollWithTimeout(timeout_ns);
        }

        /// Trampoline for `platform.instances.deployStarter(name)`.
        /// Wired into the admin-handler request via
        /// `Request.deploy_starter` + `.deploy_starter_ctx`. The
        /// pair lets globals.zig invoke this without depending on
        /// the generic `Worker(opts)` type — the caller passes the
        /// `*anyopaque` it received as `ctx`, we cast back to
        /// `*Self`, and run starter-deploy with envelope-0 propose
        /// for the `_deploy/current` release pointer.
        ///
        /// Option-A shared tail for the 3 cross-tenant trampolines:
        /// apply `ws` to `inst`'s app.db as a one-shot kvexp
        /// speculative commit (read-your-writes + leader pre-apply
        /// visibility), then fold the same ops into the batch's
        /// per-target side writeset so `proposeBatch` replicates
        /// them in the batch's single atomic raft entry and
        /// `finalizeBatch` parks the calling admin request on that
        /// seq. Behavior-identical to the three inlined copies it
        /// replaced (docs/proposer-audit.md Addendum 3).
        fn applyTargetWrite(
            self: *Self,
            allocator: std.mem.Allocator,
            inst: *const tenant_mod.Instance,
            target_id: []const u8,
            ws: *const kv_mod.WriteSet,
        ) !void {
            var txn = try inst.kv.beginTrackedImmediate();
            errdefer txn.rollback() catch {};
            for (ws.ops.items) |op| switch (op) {
                .put => |p| try txn.put(p.key, p.value),
                .delete => |d| try txn.delete(d.key),
            };
            try txn.commit();

            const batch_ws = try self.batch_side.targetWs(allocator, target_id);
            for (ws.ops.items) |op| switch (op) {
                .put => |p| try batch_ws.addPut(p.key, p.value),
                .delete => |d| try batch_ws.addDelete(d.key),
            };
        }

        /// Returns `error.InstanceNotFound` if `target_id` doesn't
        /// resolve, `error.CompileFnUnavailable` if this worker has
        /// no compile callback wired (library mode). Other errors
        /// propagate from `deployStarterContent`.
        pub fn deployStarterTrampoline(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            target_id: []const u8,
        ) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const inst_opt = self.node.tenant.getInstance(target_id) catch
                return error.InstanceNotFound;
            const inst = inst_opt orelse return error.InstanceNotFound;
            const compile_fn = self.compile_fn orelse
                return error.CompileFnUnavailable;

            // `deployStarterContent` writes the manifest JSON to the
            // tenant's `deployments/` BlobBackend on disk, then
            // stages `_deploy/current = 1` into `release_ws`. We
            // commit that write locally + propose envelope 0 so
            // followers see the release pointer too.
            var release_ws = kv_mod.WriteSet.init(allocator);
            defer release_ws.deinit();
            const starter_dep_id = try deployStarterContent(
                allocator,
                inst.dir,
                inst.id,
                self.node.blob_backend_cfg,
                compile_fn,
                self.compile_ctx,
                &release_ws,
            );
            std.log.info("deployStarter: {s} dep_id={x:0>16} writeset built ({d} ops)", .{ target_id, starter_dep_id, release_ws.ops.items.len });

            try self.applyTargetWrite(allocator, inst, target_id, &release_ws);
            std.log.info("deployStarter: {s} speculative-committed + folded into batch entry", .{target_id});

            // Eagerly enqueue the deployment loader so the runtime-created
            // tenant's snapshot lands without waiting for the next reload
            // event. apply.zig also enqueues on the envelope-0 _deploy/current
            // observation, but that runs on a different thread and may race
            // the first customer request to this fresh tenant. Belt-and-
            // braces: the loader's enqueue is per-tenant dedup'd, so double-
            // enqueue is harmless.
            if (self.node.deployment_loader) |loader| {
                loader.enqueue(target_id, starter_dep_id) catch |err| std.log.warn(
                    "deployStarter: loader.enqueue {s}/{x:0>16} failed: {s}",
                    .{ target_id, starter_dep_id, @errorName(err) },
                );
            }
        }

        /// Trampoline for `platform.releases.publish(tenant_id,
        /// dep_id)`. Stamps `_deploy/current = hex(dep_id)` on the
        /// target tenant's app.db (one-shot kvexp speculative
        /// commit) and folds that writeset into the batch's single
        /// atomic raft entry (Option-A, docs/proposer-audit.md
        /// Addendum 3), then enqueues the deployment loader.
        ///
        /// Returns `error.InstanceNotFound` if the target doesn't
        /// resolve. The caller's response is **gated on commit**:
        /// `finalizeBatch` parks the calling admin request on the
        /// batch seq, so the 2xx releases only once the
        /// `_deploy/current` write reaches quorum (a pre-quorum
        /// fault → 503, no escaped effect). No fire-and-forget; the
        /// old "logged but not compensated" divergence note is
        /// obsolete (kvexp volatility + the Option-A gate).
        pub fn releasePublishTrampoline(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            target_id: []const u8,
            dep_id: u64,
        ) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const inst_opt = self.node.tenant.getInstance(target_id) catch
                return error.InstanceNotFound;
            const inst = inst_opt orelse return error.InstanceNotFound;

            var hex_buf: [16]u8 = undefined;
            const hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{dep_id}) catch unreachable;

            // Idempotent fast path: if `_deploy/current` is already
            // exactly `dep_id`, do nothing. No raft propose, no commit,
            // no loader enqueue. This is what the 10k snapshot bench's
            // warmup phase needs — `loop46 seed --deploy-id 1` pre-
            // stamps `_deploy/current = 1` on every tenant, then
            // warmup calls publishRelease(tenant, 1) on each one,
            // every call asking us to activate the dep we just stamped.
            // Without this fast path, that's 10k raft proposals doing
            // exactly no work.
            //
            // We intentionally do NOT fast-path on `current > dep_id`
            // — that's a customer-requested rollback to an older
            // version, semantically a real write. Only exact-match
            // is a no-op.
            if (inst.kv.get("_deploy/current")) |current_hex| {
                defer allocator.free(current_hex);
                const current_id = std.fmt.parseInt(u64, current_hex, 16) catch 0;
                if (current_id == dep_id) return;
            } else |_| {}

            var release_ws = kv_mod.WriteSet.init(allocator);
            defer release_ws.deinit();
            try release_ws.addPut("_deploy/current", hex);
            try self.applyTargetWrite(allocator, inst, target_id, &release_ws);

            if (self.node.deployment_loader) |loader| {
                loader.enqueue(target_id, dep_id) catch |err| {
                    std.log.warn(
                        "releases.publish: enqueue loader for {s}/{d} failed: {s}",
                        .{ target_id, dep_id, @errorName(err) },
                    );
                };
            }
        }

        /// Trampoline for `platform.scope(id).kv.{set,delete}`. A
        /// cross-tenant write to `target_id`'s app.db: one-shot kvexp
        /// speculative commit, then folded into the batch's single
        /// atomic raft entry (Option-A) so the calling admin
        /// request's response is gated on the write committing.
        /// Deliberately its own txn (NOT the dispatch batch
        /// txn) so the admin handler's home-`__admin__` dispatch and a
        /// cross-tenant write never hold two open txns at once
        /// (auth-domain-plan §4.7 "Primitive-fix pivot").
        pub fn scopeKvWriteTrampoline(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            target_id: []const u8,
            op: globals.ScopeKvOp,
            key: []const u8,
            value: []const u8,
        ) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const inst_opt = self.node.tenant.getInstance(target_id) catch
                return error.InstanceNotFound;
            const inst = inst_opt orelse return error.InstanceNotFound;

            var ws = kv_mod.WriteSet.init(allocator);
            defer ws.deinit();

            switch (op) {
                .put => try ws.addPut(key, value),
                // TrackedTxn.delete is idempotent (discards the
                // presence bool); the writeset entry still
                // replicates the delete so followers converge.
                .delete => try ws.addDelete(key),
            }
            try self.applyTargetWrite(allocator, inst, target_id, &ws);
        }

        /// Phase 5 PR-3: `_system.continuation.resumeIfBound`
        /// trampoline. Returns true when a parked continuation on
        /// this worker is bound to `send_id` and the tenant
        /// matches — but does NOT dispatch the resume inline. The
        /// caller (`__system/webhook_onresult`) runs inside a
        /// batch txn; `resumeBoundContinuation` opens its own
        /// `beginTrackedImmediate` and nesting them would
        /// double-BEGIN the same kvexp env. Instead we APPEND
        /// `(tenant_id, send_id, event_json)` to
        /// `pending_bound_resumes`; the worker tick drains it
        /// after dispatch completes (see
        /// `drainPendingBoundResumes`). Returns true iff we found
        /// a matching parked cont (so the shim can skip
        /// `__rove_next` on the customer `on_result` — held-sync
        /// already received the event via the deferred resume).
        pub fn resumeIfBoundTrampoline(
            ctx: *anyopaque,
            tenant_id: []const u8,
            send_id: []const u8,
            event_json: []const u8,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Probe: does the worker hold a parked cont bound to
            // this send-id? `entitySlice` + the column scan
            // mirrors `resumeBoundContinuation`'s lookup but
            // read-only — no txn opened, no mutation.
            const ents = self.parked_continuations.entitySlice();
            if (ents.len == 0) return false;
            const descs = self.parked_continuations.column(components_mod.ContDescriptor);
            const chains = self.parked_continuations.column(components_mod.ChainContext);
            var matched = false;
            for (descs, chains) |desc, chain| {
                const bsid = desc.bound_schedule_id orelse continue;
                if (!std.mem.eql(u8, chain.tenant_id, tenant_id)) continue;
                if (!std.mem.eql(u8, bsid, send_id)) continue;
                matched = true;
                break;
            }
            if (!matched) return false;

            const a = self.allocator;
            const tid = a.dupe(u8, tenant_id) catch return false;
            errdefer a.free(tid);
            const sid_dup = a.dupe(u8, send_id) catch return false;
            errdefer a.free(sid_dup);
            const ev = a.dupe(u8, event_json) catch return false;
            errdefer a.free(ev);
            self.pending_bound_resumes.append(a, .{
                .tenant_id = tid,
                .send_id = sid_dup,
                .event_json = ev,
            }) catch return false;
            return true;
        }

        /// `docs/curl-multi-plan.md` Phase 2: trampoline wired into
        /// `DispatchState.cancel_fetch`. The JS binding's
        /// `http.cancelFetch({id})` lands here; we forward to the
        /// node's `FetchEngine.cancel`. Silently no-ops when the
        /// engine isn't running (test paths) or the id doesn't
        /// match an in-flight transfer (already complete).
        pub fn cancelFetchTrampoline(ctx: *anyopaque, id: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const engine = self.node.fetch_engine orelse return;
            engine.cancel(id);
        }

    };
}

// ── Per-tenant code loading ───────────────────────────────────────────
//
// These helpers open a tenant's blob backends (`{inst.dir}/file-blobs/`
// for source + bytecode bytes, `{inst.dir}/deployments/` for manifest
// JSON) and load the active deployment from the tenant's app.db
// `_deploy/current` pointer. Called eagerly during `Worker.create` for
// every registered instance, and by the background `DeploymentLoader`
// thread whenever a release lands (leader-side trampoline enqueue or
// follower-side apply detector).

/// Open (or re-use) a tenant code state. Allocates a `*TenantFiles`
/// and attempts to load the current deployment's handler bytecode.
/// If the tenant has no deployment yet, the `handler_bytecode` stays
/// `null` and requests against this tenant return 503.
///
/// (No startup orphan sweep: kvexp has no `kv_undo` table — a
/// pre-quorum crash loses the volatile speculative overlay, so
/// there are no orphan rows to recover. The pre-kvexp SQLite sweep
/// was removed.)
fn openTenantSlotNode(node: *NodeState, inst: *const tenant_mod.Instance) !*TenantSlot {
    const allocator = node.allocator;

    // (No startup orphan sweep: kvexp has no kv_undo table — a
    // pre-quorum crash loses the volatile speculative overlay, so
    // there are no orphan rows to recover. The pre-kvexp SQLite
    // sweep was removed.)

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        node.blob_backend_cfg,
        inst.id,
        "file-blobs",
    );
    errdefer blob_backend.deinit();

    // Production.md #1.4 step 4 — when manifest_http is wired, open
    // an HTTP-backed manifest_backend that fetches manifests from a
    // colocated files-server cluster (where they live in raft-
    // replicated KV). Otherwise fall back to S3-direct, which still
    // works as long as files-server's bootstrap path keeps the dual
    // S3 PUT alive. The S3 PUT goes away once every loop46 worker
    // in the deployment uses the HTTP backend.
    var manifest_backend = if (node.manifest_http) |mh|
        try blob_mod.BlobBackend.openHttp(allocator, .{
            .base_url = mh.base_url,
            .instance_id = inst.id,
            .mint_jwt = mh.mint_jwt,
            .mint_ctx = mh.mint_ctx,
            // Shared Easy across all per-tenant manifest backends
            // on this node — see `NodeState.manifest_easy`. Falls
            // back to per-tenant Easy when shared init failed.
            .easy = node.manifest_easy,
            .ca_bundle_path = mh.ca_bundle_path,
            .verify_tls = mh.verify_tls,
        })
    else
        try blob_mod.BlobBackend.openPerTenant(
            allocator,
            node.blob_backend_cfg,
            inst.id,
            "deployments",
        );
    errdefer manifest_backend.deinit();

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const slot = try allocator.create(TenantSlot);
    errdefer allocator.destroy(slot);
    // Pull this tenant's prefetched manifest (if any) — transfer
    // ownership of the bytes from the worker's prefetch map to
    // `slot`. fetchRemove returns the entry's key + value pair;
    // we own the value bytes from here and free the key (the
    // map's key was a copy of the tenant id, not the same alloc
    // as `id_copy` above).
    var prefetched: ?PrefetchedManifest = null;
    if (node.manifest_prefetch) |*map| {
        if (map.fetchRemove(inst.id)) |kv| {
            allocator.free(kv.key);
            prefetched = kv.value;
        }
    }
    errdefer if (prefetched) |p| allocator.free(p.bytes);

    slot.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .app_kv = inst.kv,
        .raft = node.raft,
        .node = node,
        .blob_backend = blob_backend,
        .manifest_backend = manifest_backend,
        .prefetched_manifest = prefetched,
        .current = .{ .raw = null },
    };

    // Best-effort initial load. Read `_deploy/current` from the
    // tenant's app.db (set by release POST + replicated via raft);
    // load that manifest from manifest_backend. If absent or
    // unreachable, log and leave `bytecodes` empty — requests get
    // 503 until either the dashboard pushes a release or the
    // periodic reload retry succeeds.
    //
    // Cold-start "implicit deploy" semantics: the synchronous
    // reload that used to run here is gone. Each tenant's
    // initial deployment load now goes through the same
    // background `DeploymentLoader` path runtime releases use
    // (`Worker.create` enqueues every tenant after the open
    // loop). The hot request path stays free of network I/O at
    // cold-start, just like everywhere else.
    //
    // Until the loader catches up, the tenant has no snapshot;
    // requests against it return 503. The customer observes
    // "loading" via SSE (future) or by polling. For tenants with
    // no `_deploy/current` set, the loader skips and the tenant
    // stays at 503 forever (until a real release POST sets the
    // pointer).
    return slot;
}

fn freeTenantSlot(allocator: std.mem.Allocator, slot: *TenantSlot) void {
    // Drop the slot's reference to the current snapshot (if any).
    // In-flight pinned references keep the old snapshot alive until
    // they release.
    if (slot.current.load(.acquire)) |snap| {
        // Atomically clear so nobody else can pin after teardown.
        slot.current.store(null, .release);
        snap.release();
    }
    slot.manifest_backend.deinit();
    slot.blob_backend.deinit();
    if (slot.prefetched_manifest) |p| allocator.free(p.bytes);
    allocator.free(slot.instance_id);
    allocator.destroy(slot);
}

/// Lookup-or-lazy-open the process-shared TenantSlot for `inst`.
/// Wraps `worker.node.getOrOpenTenantSlot` for callers that only
/// hold a worker pointer.
pub fn getOrOpenTenantSlot(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantSlot {
    return worker.node.getOrOpenTenantSlot(inst);
}

// ── Per-tenant log loading ────────────────────────────────────────────
//
// Moved to `worker_log.zig`. Re-exported here so external callers
// (root.zig's `pub const flushLogs = worker.flushLogs;`,
// worker_dispatch.zig's `worker_mod.captureLog*` /
// `captureTapesForChain*`) keep working without touching their import
// lines. Internal callers in this file use `worker_log.X` directly.
pub const REQUEST_BODY_CAP = worker_log.REQUEST_BODY_CAP;
pub const getOrOpenTenantLog = worker_log.getOrOpenTenantLog;
pub const getOrOpenTenantBodies = worker_bodies.getOrOpenTenantBodies;
pub const captureTapes = worker_log.captureTapes;
pub const captureTapesForChain = worker_log.captureTapesForChain;
pub const captureTapesForChainWithActivation = worker_log.captureTapesForChainWithActivation;
pub const captureLog = worker_log.captureLog;
pub const captureLogWithId = worker_log.captureLogWithId;
pub const flushLogs = worker_log.flushLogs;

/// Read the tenant's current deployment manifest, fetch every handler
/// entry's bytecode blob, stage every static entry's metadata, and
/// build + swap an immutable snapshot onto `slot.current`. Returns
/// `error.NoDeployment` when no deploy has been made yet — soft
/// failure the caller treats as "leave the slot snapshotless".
fn reloadAllBytecodes(slot: *TenantSlot) !void {
    // Read the release pointer from the tenant's app.db. Set by
    // /_system/release (replicated through raft envelope 0); absent
    // for tenants that haven't been released yet.
    const cur_bytes = slot.app_kv.get("_deploy/current") catch |err| switch (err) {
        error.NotFound => return error.NoDeployment,
        else => return err,
    };
    defer slot.allocator.free(cur_bytes);
    const dep_id = std.fmt.parseInt(u64, cur_bytes, 16) catch return error.NoDeployment;
    return reloadDeployment(slot, dep_id);
}

/// Stage the manifest's `_config/**.json` into the tenant's app.db
/// (local commit) and propose it as an envelope-0 writeset so
/// followers replicate. Skips the raft entry when nothing changed
/// (the common case — most tenants ship no `_config/`). Caller
/// leader-gates this; see the call site in `reloadDeployment`.
fn mirrorDeployConfig(
    allocator: std.mem.Allocator,
    slot: *TenantSlot,
    raft: *kv_mod.RaftNode,
    manifest: files_mod.manifest_json.Manifest,
    file_blobs: blob_mod.BlobStore,
) !void {
    var txn = try slot.app_kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();
    const stats = try config_mirror.mirrorConfigToKv(
        allocator,
        manifest,
        file_blobs,
        slot.app_kv,
        &txn,
        &ws,
    );
    if (stats.put_count == 0 and stats.delete_count == 0) {
        txn.rollback() catch {};
        return; // no `_config/*` churn → don't burn a raft entry
    }
    try txn.commit();
    // config-mirror is a non-handler producer (cold-start /
    // deployment-loader thread); no dispatched-handler readset to
    // attach.
    if (raft_propose.proposeWriteSet(
        .{ .allocator = allocator, .raft = raft },
        &ws,
        slot.instance_id,
        "",
    )) |_| {} else |err| {
        // Local commit is already durable on the leader; followers
        // re-derive on their next reload. Log, don't fail the deploy.
        std.log.warn(
            "config mirror: propose {s} failed: {s}",
            .{ slot.instance_id, @errorName(err) },
        );
    }
}

/// Pull a specific deployment manifest from the per-tenant
/// `deployments/` BlobBackend, fetch every referenced bytecode, and
/// build a new `TenantFilesSnapshot` that we atomic-swap onto
/// `slot.current`. The old snapshot's slot-reference drops, but
/// pinned in-flight readers keep it alive until they release. Used
/// by `reloadAllBytecodes` (cold start / restart) and by the
/// background `DeploymentLoader` thread (a release landed).
fn reloadDeployment(slot: *TenantSlot, dep_id: u64) !void {
    const allocator = slot.allocator;
    // Two-tier source for the manifest bytes:
    //   1. One-shot prefetch from cold-start. Transfer ownership
    //      out of the prefetch slot when the dep_id matches.
    //   2. Per-tenant HTTP / S3 fetch via manifest_backend.
    //
    // dep_ids are content-addressed (truncated sha-256, see
    // `files_mod.manifest_json.computeDeploymentId`), so reaching
    // this function with `dep_id == slot.currentDeploymentId()` is
    // already filtered out in `deploymentLoadFnNode`. No in-function
    // cached-bytes short-circuit needed.
    var json_bytes: []u8 = undefined;
    var owned_by_prefetch = false;
    if (slot.prefetched_manifest) |p| {
        slot.prefetched_manifest = null;
        if (p.dep_id == dep_id) {
            json_bytes = p.bytes;
            owned_by_prefetch = true;
        } else {
            allocator.free(p.bytes);
        }
    }
    if (!owned_by_prefetch) {
        var key_buf: [25]u8 = undefined;
        const key = files_mod.manifest_json.manifestKey(&key_buf, dep_id);
        json_bytes = slot.manifest_backend.blobStore().get(key, allocator) catch |err| switch (err) {
            error.NotFound => return error.NoDeployment,
            else => return err,
        };
    }
    var json_bytes_consumed = false;
    errdefer if (!json_bytes_consumed) allocator.free(json_bytes);

    var manifest = files_mod.manifest_json.decode(allocator, json_bytes) catch
        return error.InvalidManifest;
    defer manifest.deinit();

    const bs = slot.blob_backend.blobStore();

    // Mirror `_config/**.json` → tenant kv (auth-domain-plan §9: the
    // release/loader path MUST mirror per-deploy user config; fixes
    // the `7eb70ed` regression where this promise was made but never
    // wired). Leader-gated + proposed exactly like `_deploy/current`:
    // the leader writes locally + proposes an envelope-0 writeset
    // (leader-skip on apply), so followers receive `_config/*` purely
    // via that raft apply and their own (non-leader) reloadDeployment
    // correctly skips it. Best-effort — a failure logs and still lets
    // the deployment load (missing config is visible + self-heals on
    // the next reload).
    if (slot.raft) |raft| {
        if (raft.isLeader()) {
            mirrorDeployConfig(allocator, slot, raft, manifest, bs) catch |err|
                std.log.warn(
                    "reloadDeployment: config mirror {s}/{d} failed: {s}",
                    .{ slot.instance_id, dep_id, @errorName(err) },
                );
        }
    }

    // Build the new maps in locals before installing, so if any fetch
    // fails mid-way the slot keeps serving the old deployment.
    var next_bc: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer {
        var it = next_bc.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        next_bc.deinit(allocator);
    }

    var next_source_hashes: std.StringHashMapUnmanaged([64]u8) = .empty;
    errdefer {
        var it = next_source_hashes.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        next_source_hashes.deinit(allocator);
    }

    var next_statics: std.StringHashMapUnmanaged(StaticEntry) = .empty;
    errdefer {
        var it = next_statics.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*.content_type);
        }
        next_statics.deinit(allocator);
    }

    var next_triggers: std.ArrayList(TriggerEntry) = .empty;
    errdefer {
        for (next_triggers.items) |*e| {
            allocator.free(e.prefix);
            allocator.free(e.module_path);
        }
        next_triggers.deinit(allocator);
    }

    for (manifest.entries) |entry| {
        const path_copy = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path_copy);
        switch (entry.kind) {
            .handler => {
                const bytecode = try bs.get(&entry.bytecode_hex, allocator);
                errdefer allocator.free(bytecode);
                try next_bc.put(allocator, path_copy, bytecode);

                // Mirror the path → source-hash mapping so the per-
                // request module loader can stamp `appendModule(name,
                // source_hash)` on each successful import. Owns its
                // own key copy.
                const sh_key = try allocator.dupe(u8, entry.path);
                errdefer allocator.free(sh_key);
                try next_source_hashes.put(allocator, sh_key, entry.source_hex);

                // If this handler also matches the trigger path
                // convention (`_triggers/<.../>index.{mjs,js}`), index
                // it in the trigger registry. The bytecode lookup at
                // fire time uses the same path key in `bytecodes`.
                if (triggerPathToPrefix(entry.path)) |derived_prefix| {
                    if (isReservedTriggerPrefix(derived_prefix)) {
                        std.log.warn(
                            "rove-js: tenant {s} trigger {s} rejected — prefix '{s}' overlaps a platform namespace",
                            .{ slot.instance_id, entry.path, derived_prefix },
                        );
                        return error.ReservedTriggerPrefix;
                    }
                    const prefix_copy = try allocator.dupe(u8, derived_prefix);
                    errdefer allocator.free(prefix_copy);
                    const module_copy = try allocator.dupe(u8, entry.path);
                    errdefer allocator.free(module_copy);
                    try next_triggers.append(allocator, .{
                        .prefix = prefix_copy,
                        .module_path = module_copy,
                    });
                }
            },
            .static => {
                const ct_copy = try allocator.dupe(u8, entry.content_type);
                errdefer allocator.free(ct_copy);
                try next_statics.put(allocator, path_copy, .{
                    .content_type = ct_copy,
                    .hash_hex = entry.source_hex,
                });
            },
        }
    }

    // Sort triggers by prefix length descending (longest/innermost
    // first). AFTER chain iterates forward; BEFORE chain iterates
    // reverse. See TenantFilesSnapshot.triggers.
    const triggers_slice = try next_triggers.toOwnedSlice(allocator);
    errdefer {
        for (triggers_slice) |*e| {
            allocator.free(e.prefix);
            allocator.free(e.module_path);
        }
        allocator.free(triggers_slice);
    }
    std.mem.sort(TriggerEntry, triggers_slice, {}, struct {
        fn lessThan(_: void, a: TriggerEntry, b: TriggerEntry) bool {
            return a.prefix.len > b.prefix.len;
        }
    }.lessThan);

    // Gap 2.1 Phase B: discover subscription chain origins from
    // `_subscriptions/<name>/{index.mjs,spec.json}` manifest pairs.
    // Failures abort the deploy (consistent with the trigger
    // discovery posture above — a misconfigured subscription is a
    // load-time error, not a silent skip).
    const subscriptions_slice = try discoverSubscriptions(allocator, manifest, bs);
    errdefer {
        for (subscriptions_slice) |*s| {
            const mut: *globals.SubscriptionEntry = @constCast(s);
            mut.deinit(allocator);
        }
        if (subscriptions_slice.len > 0) allocator.free(subscriptions_slice);
    }

    // Build the new immutable snapshot. Refcount starts at 1 (the
    // slot's reference).
    const new_snap = try allocator.create(TenantFilesSnapshot);
    errdefer allocator.destroy(new_snap);
    new_snap.* = .{
        .allocator = allocator,
        .deployment_id = manifest.id,
        .bytecodes = next_bc,
        .source_hashes = next_source_hashes,
        .statics = next_statics,
        .triggers = triggers_slice,
        .subscriptions = subscriptions_slice,
        .manifest_bytes = json_bytes,
        .refcount = .{ .raw = 1 },
    };
    json_bytes_consumed = true;

    // Atomic swap under `pin_lock` so any concurrent `pinCurrent`
    // either retains the OLD snapshot before swap (refcount goes
    // 1→2→1 across loader's release) or sees the NEW pointer
    // entirely. Without the lock, a load + retain pair could
    // straddle the swap+release and touch freed memory.
    slot.pin_lock.lock();
    const old_snap = slot.current.swap(new_snap, .acq_rel);
    slot.pin_lock.unlock();
    // Release-after-unlock is safe: the OLD pointer is no longer
    // reachable via `slot.current`, so no new pin can find it.
    // Pre-swap pins already retained.
    if (old_snap) |old| old.release();

    std.log.info(
        "rove-js: tenant {s} loaded deployment {d} ({d} handler(s), {d} static(s), {d} trigger(s), {d} subscription(s))",
        .{ slot.instance_id, manifest.id, new_snap.bytecodes.count(), new_snap.statics.count(), new_snap.triggers.len, new_snap.subscriptions.len },
    );

    // Gap 2.1 Phase D: enqueue boot subscriptions that haven't
    // yet fired against THIS deployment_id. Leader-only — boot
    // is "once per deployment activation across the cluster," not
    // "once per node." Followers see the `_boot_fired/<dep_id>`
    // marker via the leader's raft propose and skip on their own
    // reload.
    if (slot.raft) |raft| {
        if (raft.isLeader()) {
            enqueueBootSubscriptions(slot, new_snap) catch |err|
                std.log.warn(
                    "rove-js: tenant {s} boot enqueue: {s}",
                    .{ slot.instance_id, @errorName(err) },
                );
        }
    }
}

/// Gap 2.1 Phase D: on `false→true` leadership transition, walk
/// every loaded tenant slot and (re-)enqueue any boot
/// subscriptions whose marker is absent. Covers the cold-start
/// race where slots loaded BEFORE raft elected a leader, so
/// `reloadDeployment`'s leader-gated enqueue saw `isLeader() ==
/// false` and skipped. Gated to worker 0 to avoid duplicate
/// enqueues across the leader's local workers.
pub fn sweepBootSubscriptions(worker: anytype) void {
    var it = worker.node.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const snap = slot.pinCurrent() orelse continue;
        defer snap.release();
        enqueueBootSubscriptions(slot, snap) catch |err| std.log.warn(
            "rove-js boot sweep ({s}): {s}",
            .{ slot.instance_id, @errorName(err) },
        );
    }
}

/// Gap 2.1 Phase F: throttled cron sweep — runs at most once per
/// `CRON_SWEEP_INTERVAL_NS` from worker 0 when leader. Walks every
/// loaded tenant slot's cron subscriptions and fires any that are
/// due (or initializes the next-fire time on first sight).
/// In-memory state in `NodeState.cron_state` keyed by
/// `<tenant>|<name>`; not raft-replicated, so leader change resets
/// the cron clock (next fire = now + interval_ms on the new
/// leader). For long-interval crons this can pause up to one
/// interval after failover; customer-side missed-tick tolerance
/// is the documented contract.
pub const CRON_SWEEP_INTERVAL_NS: i64 = 1 * std.time.ns_per_s;

pub fn sweepCronSubscriptions(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - worker.last_cron_sweep_ns < CRON_SWEEP_INTERVAL_NS) return;
    worker.last_cron_sweep_ns = now_ns;

    var it = worker.node.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const snap = slot.pinCurrent() orelse continue;
        defer snap.release();
        if (snap.subscriptions.len == 0) continue;
        sweepTenantCron(worker.node, slot, snap, now_ns);
    }
}

/// Walk one tenant's cron subscriptions; for each that's due,
/// enqueue a fire and advance the in-memory `next_fire_at_ns`.
/// First-sight initializes to `now_ns + interval_ms_ns`
/// (interval-delay before the FIRST fire — keeps cron behavior
/// natural across deploy + restart).
fn sweepTenantCron(
    node: *NodeState,
    slot: *TenantSlot,
    snap: *TenantFilesSnapshot,
    now_ns: i64,
) void {
    const allocator = node.allocator;
    for (snap.subscriptions) |sub| {
        const interval_ms: i64 = switch (sub.spec) {
            .cron => |c| c.interval_ms,
            else => continue,
        };
        const interval_ns: i64 = interval_ms * std.time.ns_per_ms;

        // Key = "<tenant>|<sub_name>". Owned by cron_state on
        // first insert; reused on subsequent lookups.
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ slot.instance_id, sub.name }) catch continue;

        node.cron_state_mutex.lock();
        const gop = node.cron_state.getOrPut(allocator, key) catch {
            node.cron_state_mutex.unlock();
            continue;
        };
        if (!gop.found_existing) {
            // First sight: initialize the next-fire time and don't
            // fire this round. The customer sees the first fire
            // roughly `interval_ms` after this sweep.
            gop.key_ptr.* = allocator.dupe(u8, key) catch {
                _ = node.cron_state.remove(key);
                node.cron_state_mutex.unlock();
                continue;
            };
            gop.value_ptr.* = now_ns + interval_ns;
            node.cron_state_mutex.unlock();
            continue;
        }
        const next_fire_at_ns = gop.value_ptr.*;
        if (now_ns < next_fire_at_ns) {
            node.cron_state_mutex.unlock();
            continue;
        }
        // Advance to next interval. Use cumulative drift
        // (`next + interval`) when within an interval of now;
        // otherwise (long pause / failover) reset to `now +
        // interval` to avoid pile-up.
        gop.value_ptr.* = if (next_fire_at_ns + interval_ns > now_ns)
            next_fire_at_ns + interval_ns
        else
            now_ns + interval_ns;
        node.cron_state_mutex.unlock();

        node.enqueueSubscriptionFireForTenant(.{
            .tenant_id = slot.instance_id,
            .subscription_name = sub.name,
            .module_path = sub.module_path,
            .source = .{ .cron = .{ .fired_at_ns = now_ns } },
        }) catch |err| std.log.warn(
            "rove-js cron sweep enqueue ({s}/{s}): {s}",
            .{ slot.instance_id, sub.name, @errorName(err) },
        );
    }
}

/// Gap 2.1 Phase D: leader-side scan of new snapshot's `.boot`
/// subscriptions; enqueue each one that hasn't fired yet (no
/// `_boot_fired/<dep_id>` marker in tenant kv). The actual firing
/// runs on a worker that drains the cross-thread inbox; that
/// worker writes the marker post-fire via `writeBootFiredMarker`.
///
/// Idempotency contract: marker is written AFTER the activation;
/// a crash between fire + marker leaves "fired-but-not-marked"
/// state and the next reload refires. Customers' boot handlers
/// must be idempotent (treat double-fire as benign).
fn enqueueBootSubscriptions(slot: *TenantSlot, snap: *TenantFilesSnapshot) !void {
    const node = slot.node orelse return; // unit-test slot: no node, no enqueue
    for (snap.subscriptions) |sub| {
        if (sub.spec != .boot) continue;

        var key_buf: [64]u8 = undefined;
        const marker_key = try std.fmt.bufPrint(&key_buf, "_boot_fired/{d}", .{snap.deployment_id});
        const existing = slot.app_kv.get(marker_key) catch |err| switch (err) {
            error.NotFound => null,
            else => {
                std.log.warn(
                    "rove-js boot ({s}/{s}): marker check failed: {s}",
                    .{ slot.instance_id, sub.name, @errorName(err) },
                );
                continue;
            },
        };
        if (existing) |e| {
            slot.allocator.free(e);
            continue; // already fired for this deployment
        }

        std.log.info(
            "rove-js boot enqueue: tenant={s} subscription={s} deployment={d}",
            .{ slot.instance_id, sub.name, snap.deployment_id },
        );

        // Push to the node-wide inbox; hash-routed to one of the
        // local workers. The worker's `drainSubFireInbox` moves the
        // message onto an `effect.SubscriptionFire` payload (via
        // `effect.enqueueMsg`) and `dispatchSubscriptionFires` fires
        // it on the next tick.
        node.enqueueSubscriptionFireForTenant(.{
            .tenant_id = slot.instance_id,
            .subscription_name = sub.name,
            .module_path = sub.module_path,
            .source = .{ .boot = .{ .deployment_id = snap.deployment_id } },
        }) catch |err| {
            std.log.warn(
                "rove-js boot enqueue ({s}/{s}): {s}",
                .{ slot.instance_id, sub.name, @errorName(err) },
            );
        };
    }
}

// ── _send/owed retry sweep (Phase 5 PR-3 — webhook.send durability moves to JS shim) ───

/// Phase 5 PR-3: per-worker `_send/owed/` retry sweep cadence. Each
/// leader-side worker walks its partition of loaded tenants at most
/// once per this interval; the boot variant (`sweepOwedRetriesOnPromotion`)
/// is unthrottled. The interval matches `CRON_SWEEP_INTERVAL_NS` —
/// retries are second-resolution against `next_at_ns`, which the
/// JS shim's onresult sets with exponential backoff (1s, 2s, 4s, …
/// capped at 60s); a 1Hz sweep wakes due retries within one window
/// of their target time.
pub const SEND_SWEEP_INTERVAL_NS: i64 = 1 * std.time.ns_per_s;

/// Phase 5 PR-3: per-worker partitioned retry sweep — the leader-
/// side mechanism that replaces SendDispatch's leader-thread fire.
///
/// Each leader worker, at most once per `SEND_SWEEP_INTERVAL_NS`,
/// walks every loaded tenant whose `hash(tenant_id) % N_msg_inboxes`
/// matches THIS worker's `msg_inbox_idx`. For each tenant it scans
/// the `_send/owed/` kv prefix and, for entries whose `next_at_ns`
/// has fallen due, constructs a `PendingFetch` with
/// `on_chunk = "__system/webhook_onresult"` (the shim's built-in
/// onresult handler — PR-2b's first baked module) and pushes it
/// onto the node's `fetch_pending` queue.
///
/// The partition matches `enqueueMsgForTenant`'s
/// `hash(tenant_id) % N` routing so the entire retry chain (sweep →
/// fetch → onresult activation → kv ops on the marker) stays on one
/// worker per tenant — no cross-worker coordination, parallel
/// enumeration across the leader's workers.
///
/// Inert until the JS shim flip lands (PR-3 step 2): without the
/// shim, no `_send/owed/{id}` marker is ever written by anything
/// other than legacy `http.send` (which apply.zig still classifies
/// into SendDispatch), so the sweep finds an empty prefix every
/// tick. This is the shape that lets PR-3 step 1 land first as a
/// safety net for the atomic flip in steps 2-4.
pub fn sweepOwedRetries(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - worker.last_send_sweep_ns < SEND_SWEEP_INTERVAL_NS) return;
    worker.last_send_sweep_ns = now_ns;
    sweepOwedRetriesAllPartitioned(worker, now_ns);
}

/// Phase 5 PR-3: unthrottled variant for false→true leadership
/// transition. Runs ONCE across all partitioned tenants for orphan
/// recovery — picks up `_send/owed/{id}` markers a previous leader
/// wrote but never fired (or whose retry window expired during the
/// failover gap). Equivalent to SendDispatch.recover()'s boot-scan,
/// rebuilt as the JS-shim path's recovery primitive.
pub fn sweepOwedRetriesOnPromotion(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    // Bump the throttle baseline so the regular sweep doesn't
    // immediately re-walk the same prefix on the next tick.
    worker.last_send_sweep_ns = now_ns;
    sweepOwedRetriesAllPartitioned(worker, now_ns);
}

fn sweepOwedRetriesAllPartitioned(worker: anytype, now_ns: i64) void {
    const n_inboxes = blk: {
        worker.node.msg_inboxes_mutex.lock();
        defer worker.node.msg_inboxes_mutex.unlock();
        break :blk worker.node.msg_inboxes.items.len;
    };
    if (n_inboxes == 0) return; // pre-registration cold start

    var it = worker.node.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const inbox_idx = std.hash.Wyhash.hash(0, slot.instance_id) % n_inboxes;
        if (inbox_idx != worker.msg_inbox_idx) continue;
        sweepTenantOwed(worker, slot, now_ns);
    }
}

/// Walk one tenant's `_send/owed/` prefix; for each entry that's
/// due, build a `PendingFetch` aimed at `__system/webhook_onresult`
/// and accumulate it. Pages through the prefix 64 keys at a time so
/// a tenant with thousands of in-flight markers doesn't hold the
/// LMDB txn open for an entire pass — the kvexp prefix cursor is
/// closed between pages.
///
/// PendingFetch construction mirrors the customer-side `http.fetch`
/// path (`bindings/http.zig:buildFetchRow`) but with platform-
/// stamped headers: `X-Rove-Schedule-Id: {owed_id}` for idempotency
/// continuity with the legacy SendDispatch path, and
/// `X-Rove-Schedule-Version: {attempts+1}` so the upstream can
/// distinguish retries of the same logical send.
fn sweepTenantOwed(worker: anytype, slot: *TenantSlot, now_ns: i64) void {
    const a = worker.node.allocator;
    var fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        // Anything that didn't transfer ownership into the node's
        // queue (every item on early-return paths) must be freed.
        for (fetches.items) |*pf| pf.deinit(a);
        fetches.deinit(a);
    }

    const PREFIX = "_send/owed/";
    var cursor_owned: ?[]u8 = null;
    defer if (cursor_owned) |c| a.free(c);

    while (true) {
        const cursor: []const u8 = cursor_owned orelse "";
        var page = slot.app_kv.prefix(PREFIX, cursor, 64) catch |err| {
            std.log.warn(
                "rove-js send sweep ({s}): prefix scan failed: {s}",
                .{ slot.instance_id, @errorName(err) },
            );
            return;
        };
        defer page.deinit();
        if (page.entries.len == 0) break;

        for (page.entries) |entry| {
            // Key shape: "_send/owed/<owed_id>".
            if (entry.key.len <= PREFIX.len) continue;
            const owed_id = entry.key[PREFIX.len..];

            buildRetryFetch(a, slot.instance_id, owed_id, entry.value, now_ns, &fetches) catch |err| switch (err) {
                error.NotDue, error.MalformedMarker => continue, // log inside on Malformed
                else => {
                    std.log.warn(
                        "rove-js send sweep ({s}/{s}): build fetch failed: {s}",
                        .{ slot.instance_id, owed_id, @errorName(err) },
                    );
                    continue;
                },
            };
        }

        if (page.entries.len < 64) break;

        // Advance the cursor to the last key returned. The key
        // bytes are owned by the RangeResult's allocator and freed
        // at `page.deinit` — dup so we keep them across the
        // boundary.
        const last_key = page.entries[page.entries.len - 1].key;
        if (cursor_owned) |c| a.free(c);
        cursor_owned = a.dupe(u8, last_key) catch return;
    }

    if (fetches.items.len == 0) return;
    worker.node.enqueuePendingFetches(fetches.items) catch |err| {
        std.log.warn(
            "rove-js send sweep ({s}): enqueuePendingFetches failed: {s}",
            .{ slot.instance_id, @errorName(err) },
        );
        return; // caller's defer frees the partial list
    };
    // Ownership transferred to the node queue. The defer above
    // walks an empty list (no double-free).
    fetches.clearRetainingCapacity();
}

const RetryFetchError = error{
    NotDue,
    MalformedMarker,
    OutOfMemory,
    WriteFailed,
};

/// Parse one `_send/owed/{id}` marker; if due, append a
/// `PendingFetch` aimed at `__system/webhook_onresult` to `out`. On
/// `NotDue` the entry is silently skipped (the sweep will revisit
/// next pass). On `MalformedMarker` we log + skip — the marker is
/// owned by the JS shim, and a customer-corrupted marker is
/// recoverable only by the shim itself rewriting it.
fn buildRetryFetch(
    a: std.mem.Allocator,
    tenant_id: []const u8,
    owed_id: []const u8,
    marker_json: []const u8,
    now_ns: i64,
    out: *std.ArrayListUnmanaged(globals.PendingFetch),
) RetryFetchError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, a, marker_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        std.log.warn(
            "rove-js send sweep ({s}/{s}): _send/owed/ JSON parse failed; skipping",
            .{ tenant_id, owed_id },
        );
        return error.MalformedMarker;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.log.warn(
                "rove-js send sweep ({s}/{s}): _send/owed/ not a JSON object; skipping",
                .{ tenant_id, owed_id },
            );
            return error.MalformedMarker;
        },
    };

    // `next_at_ns` rides as a BigInt-as-string (the shim's
    // `computeNextAtNs` returns `String(BigInt(...))`). Parse to i64
    // — Date.now()*1e6 fits comfortably until the year 2262, well
    // past the platform's relevance horizon. Treat missing/0 as
    // "due now" (first-attempt fire path; the shim writes the
    // marker, then http.fetch fires immediately, with next_at_ns
    // unset until the first retry).
    const next_at_ns: i64 = switch (obj.get("next_at_ns") orelse std.json.Value{ .null = {} }) {
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        .integer => |n| n,
        else => 0,
    };
    if (next_at_ns > now_ns) return error.NotDue;

    const url = jsonStringField(obj, "url") orelse {
        std.log.warn(
            "rove-js send sweep ({s}/{s}): _send/owed/ missing `url`; skipping",
            .{ tenant_id, owed_id },
        );
        return error.MalformedMarker;
    };
    const method = jsonStringField(obj, "method") orelse "POST";
    const body = jsonStringField(obj, "body") orelse "";
    const attempts: u32 = switch (obj.get("attempts") orelse std.json.Value{ .integer = 0 }) {
        .integer => |n| if (n < 0) 0 else @intCast(@min(n, std.math.maxInt(u32))),
        .float => |f| if (f < 0) 0 else @intFromFloat(@min(f, @as(f64, @floatFromInt(std.math.maxInt(u32))))),
        else => 0,
    };

    // Stamp platform headers onto whatever the shim handed us.
    // Stable shape across the legacy SendDispatch + new JS-shim
    // path so upstream services that key on `X-Rove-Schedule-Id`
    // for idempotency keep working.
    const headers_in_json = headersJsonFromMarker(a, obj) catch return error.OutOfMemory;
    defer a.free(headers_in_json);
    const headers_json = try stampPlatformHeaders(a, headers_in_json, owed_id, attempts + 1);
    errdefer a.free(headers_json);

    // ctx for webhook_onresult.mjs: `{id, on_result, context}`.
    // `on_result` is optional (customer didn't pass one →
    // null in the marker). `context` is the customer-supplied
    // payload, opaque to the platform.
    const ctx_json = try buildOnresultCtxJson(a, owed_id, obj);
    errdefer a.free(ctx_json);

    // Fetch id: a stable hex tag per (tenant, owed_id, attempt)
    // so two retries don't collide. Uses sha256 of "RETRY|" +
    // tenant + "|" + owed + "|" + attempts (decimal). 64 hex
    // chars, matches the deterministic-id shape used elsewhere.
    const fetch_id = try retryFetchIdHex(a, tenant_id, owed_id, attempts);
    errdefer a.free(fetch_id);

    const url_dup = try a.dupe(u8, url);
    errdefer a.free(url_dup);
    const method_dup = try a.dupe(u8, method);
    errdefer a.free(method_dup);
    const body_dup = try a.dupe(u8, body);
    errdefer a.free(body_dup);
    const on_chunk_dup = try a.dupe(u8, "__system/webhook_onresult");
    errdefer a.free(on_chunk_dup);
    const tenant_dup = try a.dupe(u8, tenant_id);
    errdefer a.free(tenant_dup);

    try out.ensureUnusedCapacity(a, 1);
    out.appendAssumeCapacity(.{
        .tenant_id = tenant_dup,
        .id = fetch_id,
        .url = url_dup,
        .method = method_dup,
        .headers_json = headers_json,
        .body = body_dup,
        .timeout_ms = 30_000,
        .on_chunk_module = on_chunk_dup,
        .ctx_json = ctx_json,
        .stream = false,
        .max_response_chunk_bytes = 256 * 1024,
        .max_total_response_bytes = 50 * 1024 * 1024,
    });
}

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Serialize the marker's `headers` object back to a JSON string
/// (the wire format `FetchPool` consumes). Missing/non-object
/// `headers` → `"{}"` — the platform always stamps `X-Rove-*`
/// headers on top in `stampPlatformHeaders`.
fn headersJsonFromMarker(a: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const hv = obj.get("headers") orelse return a.dupe(u8, "{}");
    if (hv != .object) return a.dupe(u8, "{}");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
        defer buf = aw.toArrayList();
        try std.json.Stringify.value(hv, .{}, &aw.writer);
    }
    return try buf.toOwnedSlice(a);
}

/// Append `X-Rove-Schedule-Id` + `X-Rove-Schedule-Version` to
/// `headers_in_json`. Tolerates a leading whitespace/closing-brace
/// shape — the marker's `headers` round-trip through `std.json` so
/// the output is always `{...}` or `{}`.
fn stampPlatformHeaders(
    a: std.mem.Allocator,
    headers_in_json: []const u8,
    schedule_id: []const u8,
    version: u32,
) ![]u8 {
    // Strip trailing `}`, splice in the platform fields, re-close.
    var trimmed = std.mem.trim(u8, headers_in_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        // Malformed — fall back to a fresh object with only the
        // platform stamps.
        return std.fmt.allocPrint(
            a,
            "{{\"X-Rove-Schedule-Id\":\"{s}\",\"X-Rove-Schedule-Version\":\"{d}\"}}",
            .{ schedule_id, version },
        );
    }
    // `{...}` → inner = `...`. If inner is empty, no leading comma.
    const inner = trimmed[1 .. trimmed.len - 1];
    const inner_trimmed = std.mem.trim(u8, inner, " \t\r\n");
    const sep: []const u8 = if (inner_trimmed.len == 0) "" else ",";
    return std.fmt.allocPrint(
        a,
        "{{{s}{s}\"X-Rove-Schedule-Id\":\"{s}\",\"X-Rove-Schedule-Version\":\"{d}\"}}",
        .{ inner, sep, schedule_id, version },
    );
}

/// Build the ctx JSON passed to `__system/webhook_onresult` — the
/// shape it expects (`webhook_onresult.mjs`): `{id, on_result,
/// context}`. `on_result` defaults to the JSON literal `null` when
/// the marker omits it; `context` defaults to `null` likewise.
fn buildOnresultCtxJson(
    a: std.mem.Allocator,
    owed_id: []const u8,
    marker: std.json.ObjectMap,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
        defer buf = aw.toArrayList();
        const w = &aw.writer;

        try w.writeAll("{\"id\":");
        try writeJsonString(w, owed_id);
        try w.writeAll(",\"on_result\":");
        const on_result_v = marker.get("on_result") orelse std.json.Value{ .null = {} };
        try std.json.Stringify.value(on_result_v, .{}, w);
        try w.writeAll(",\"context\":");
        const context_v = marker.get("context") orelse std.json.Value{ .null = {} };
        try std.json.Stringify.value(context_v, .{}, w);
        try w.writeAll("}");
    }
    return try buf.toOwnedSlice(a);
}

/// JSON string-escape (RFC 8259 minimal). Mirrors apply.zig's
/// private helper but inlined here so the sweep doesn't reach
/// across modules for a five-line escape routine.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{b}),
        else => try writer.writeByte(b),
    };
    try writer.writeByte('"');
}

/// Deterministic id-per-attempt: sha256("RETRY|" || tenant || "|"
/// || owed_id || "|" || attempts-decimal). 64 lowercase hex.
/// The sweep doesn't need replay-stability across runs (it's not
/// taped — only the resulting onresult handler activation is) but
/// per-attempt determinism keeps log lines greppable and inflight-
/// set collisions impossible.
fn retryFetchIdHex(
    a: std.mem.Allocator,
    tenant_id: []const u8,
    owed_id: []const u8,
    attempts: u32,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("RETRY|");
    hasher.update(tenant_id);
    hasher.update("|");
    hasher.update(owed_id);
    hasher.update("|");
    var att_buf: [11]u8 = undefined;
    const att_str = std.fmt.bufPrint(&att_buf, "{d}", .{attempts}) catch unreachable;
    hasher.update(att_str);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}

// ── Dispatch system ───────────────────────────────────────────────────
//
// Moved to `worker_drain.zig`: drainRaftPending + the three
// raft_pending_* siblings via drainEntityArm + parked_units arm,
// resolveDeployment, resolveParked, the held-cont resume engine
// (resumeContinuation + resumeBoundContinuation + drainPendingBoundResumes
// + sweepParkedContinuations + proposeAndParkContResume). Re-exported
// here so external callers — `root.zig`'s `drainRaftPending` /
// `drainPendingBoundResumes` / `sweepParkedContinuations`, plus
// `worker_streaming.zig`'s `resolveDeployment` import — keep working
// without touching their import lines.
//
// Phase 7 fold (2026-05-24): the `parked_meta` / `parked_streams_*` /
// `pending_stream_meta` side tables don't exist as fields anywhere;
// the migration shipped earlier. What remained — stale comments
// narrating the side-table world — was rewritten in place during
// the move. No behavior change.
pub const drainRaftPending = worker_drain.drainRaftPending;
pub const drainBodyPending = worker_drain.drainBodyPending;
pub const resolveDeployment = worker_drain.resolveDeployment;
pub const resumeBoundContinuation = worker_drain.resumeBoundContinuation;
pub const drainPendingBoundResumes = worker_drain.drainPendingBoundResumes;
pub const sweepParkedContinuations = worker_drain.sweepParkedContinuations;

// ── Streaming-handlers Phase 2b-ii ────────────────────────────────────
//
// Moved to `worker_streaming.zig`. Re-exported here so external
// callers — `root.zig`'s `serviceParkedStreams` / `serviceSubscriptionFires`
// and `worker_dispatch.zig`'s `setStreamComponents` — keep working
// without touching their import lines. Internal callers in this file
// use `worker_streaming.X` directly.
//
// The moved file covers more than streaming proper: the original
// section had absorbed every fire*Activation entry point + the
// Msg-queue dispatch. See `worker_streaming.zig`'s module doc for the
// full scope.
pub const SubscriptionFireSource = worker_streaming.SubscriptionFireSource;
pub const SubscriptionFireQueueInput = worker_streaming.SubscriptionFireQueueInput;
pub const StreamResumeStage = worker_streaming.StreamResumeStage;
pub const setStreamComponents = worker_streaming.setStreamComponents;
pub const serviceParkedStreams = worker_streaming.serviceParkedStreams;
pub const fireSubscriptionActivation = worker_streaming.fireSubscriptionActivation;
pub const proposeForgetfulWrites = worker_streaming.proposeForgetfulWrites;
pub const serviceSubscriptionFires = worker_streaming.serviceSubscriptionFires;
pub const dispatchPendingMsgs = worker_streaming.dispatchPendingMsgs;
pub const dispatchSubscriptionFires = worker_streaming.dispatchSubscriptionFires;
pub const dispatchFetchEvents = worker_streaming.dispatchFetchEvents;

// ── Gap 2.3 Phase D — http.fetch chunk/done activations ──────────

/// Effect-reification Phase 2E: backward-compat alias of
/// `serviceSubscriptionFires` — both now drain the unified
/// `msg_inbox` and dispatch the queue. The second-to-call sees an
/// empty inbox + queue and is a cheap no-op. main.zig + the
/// parked_units call site keep their existing call shape.
pub fn serviceFetchEvents(worker: anytype) void {
    worker_streaming.drainMsgInbox(worker);
    worker_streaming.dispatchPendingMsgs(worker);
}

/// Dispatch one upstream fetch event as a chain activation.
/// Structural twin of `fireSubscriptionActivation` — no held socket,
/// writes commit forgetfully — but the activation source + payload
/// differ.
///
/// **TEA framing (Phase 5 PR-1):**
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
pub fn fireFetchEventActivation(
    worker: anytype,
    event: *const components_mod.UpstreamFetchEvent,
) void {
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

    var dep = resolveDeployment(worker, allocator, tenant_id, module_path) catch |err| {
        std.log.warn(
            "rove-js fetch-event: tenant={s} module={s} resolveDeployment failed: {s}; skipping",
            .{ tenant_id, module_path, @errorName(err) },
        );
        return;
    };
    defer dep.tc.release();
    const inst = dep.inst;
    const tc = dep.tc;
    const bc = dep.bc;

    // Body `{ctx: <ctx_json>}`. `ctx_json` is the chain ctx the
    // originating `http.fetch` call passed; empty → `{}`.
    const ctx_src: []const u8 = if (event.ctx_json.len > 0) event.ctx_json else "{}";
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

    // Correlation: all activations of one fetch share `fetch-<id>`
    // so the replay UX groups the chunk chain with its terminal.
    var corr_buf: [80]u8 = undefined;
    const id_len: usize = @min(event.fetch_id.len, 64);
    const corr_full = std.fmt.bufPrint(
        &corr_buf,
        "fetch-{s}",
        .{event.fetch_id[0..id_len]},
    ) catch corr_buf[0..0];

    const act_source: log_mod.ActivationSource = .fetch_chunk;

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
        .activation_source = act_source,
        .activation_fetch_id = event.fetch_id,
        .is_system_module = builtin_modules_mod.isBuiltinPath(module_path),
        // Phase 5 PR-3: §6.4 held-sync resume hook. The baked
        // `__system/webhook_onresult` shim calls `__rove_resume_if_bound`
        // on terminal to wake any parked cont bound to this send-id.
        // Set on every fetch-event activation (the H2 path sets it
        // too, in `worker_dispatch.zig`); without this the JS builtin
        // sees a null trampoline + returns false, leaving the cont
        // parked until its 25s deadline.
        .resume_if_bound = &@TypeOf(worker.*).resumeIfBoundTrampoline,
        .resume_if_bound_ctx = @ptrCast(worker),
        .cancel_fetch = &@TypeOf(worker.*).cancelFetchTrampoline,
        .cancel_fetch_ctx = @ptrCast(worker),
    };
    req.activation_fetch_seq = event.seq;
    req.activation_fetch_byte_offset = event.byte_offset;
    req.activation_fetch_bytes = event.bytes;
    req.activation_fetch_headers = event.fetch_headers;
    req.activation_fetch_final = event.final;
    if (event.final) {
        req.activation_fetch_terminal_status = event.terminal_status;
        req.activation_fetch_terminal_ok = event.terminal_ok;
        req.activation_fetch_body_truncated = event.body_truncated;
    }

    // Phase 4-fetch-inline: small fetch chunks ride inline in
    // the readset's `fetch_responses.inline_bytes` field — no
    // buffer append, no S3 PUT, handler runs immediately. The
    // raft entry's fsync IS the durability substrate (every
    // replica sees the bytes when the entry replicates).
    // Discriminator: `body_ref.batch_id == NO_BATCH` ⇒ inline.
    //
    // Larger chunks still go through the BodyBuffer (slice 2c-1
    // path); the resulting BodyRef rides the entry instead.
    // Slice 4-fetch-park will gate those on durability —
    // currently they fire immediately, leaving the
    // unreplayability gap §5.1 documents for outbound bodies.
    //
    // The bytes still ride alongside on `activation_fetch_bytes`
    // for the handler's `request.activation.bytes` view; the
    // tape's `activation_bytes` still captures them too. Both
    // coexist during the Phase 2 → Phase 3 transition; the
    // inline bytes drop out when the raft entry adopts the
    // BodyRef in Phase 3.
    //
    // Terminal-only events (final=true with no body bytes) still
    // capture a tape entry so the chain has the closing seq +
    // terminal status / ok / body_truncated for replay; both
    // body_ref and inline_bytes are empty.
    const FETCH_INLINE_THRESHOLD: usize = 16 * 1024;
    var body_ref: bodies_mod.BodyRef = .{ .batch_id = bodies_mod.NO_BATCH, .offset = 0, .len = 0 };
    var inline_bytes_for_tape: []const u8 = "";
    if (event.bytes.len > 0 and event.bytes.len <= FETCH_INLINE_THRESHOLD) {
        // Inline fast path — no buffer append, the chunk bytes
        // ride on the tape entry directly.
        body_ref = .{
            .batch_id = bodies_mod.NO_BATCH,
            .offset = 0,
            .len = @intCast(event.bytes.len),
        };
        inline_bytes_for_tape = event.bytes;
    } else if (event.bytes.len > 0) {
        // Larger-than-threshold chunk — BodyRef path. Append to
        // the per-tenant BodyBuffer; the flusher tick publishes
        // to S3 asynchronously.
        const tb = worker_bodies.getOrOpenTenantBodies(worker, inst) catch |err| blk: {
            std.log.warn(
                "rove-js fetch-event: getOrOpenTenantBodies tenant={s}: {s}",
                .{ tenant_id, @errorName(err) },
            );
            break :blk null;
        };
        if (tb) |t| {
            body_ref = t.buffer.append(event.bytes) catch |err| blk: {
                std.log.warn(
                    "rove-js fetch-event: body-buffer append tenant={s} bytes={d}: {s}",
                    .{ tenant_id, event.bytes.len, @errorName(err) },
                );
                break :blk .{ .batch_id = bodies_mod.NO_BATCH, .offset = 0, .len = 0 };
            };
        }
    }
    readset.fetch_responses.appendFetchResponse(
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
        // posture as `captureTapesForChain`'s per-channel serialize
        // errors: log + skip.
        std.log.warn(
            "rove-js fetch-event: readset.fetch_responses append tenant={s} fetch_id={s}: {s}",
            .{ tenant_id, event.fetch_id, @errorName(err) },
        );
    };

    // Phase 2D: the activation's input bytes (the upstream chunk
    // payload) get taped on `TapePayloads.activation_bytes`.
    // Closes algebra §7 worklist #1 — replay reconstitutes the same
    // handler invocation from the same captured bytes.
    const activation_bytes_for_tape: []const u8 = event.bytes;

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
        const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
        captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, tape_payloads, corr_full, act_source);
        return;
    };

    const wrote = ws.ops.items.len > 0;
    var oc = run_oc;
    // Fetch chains have no held socket — terminal commits/proposes;
    // continuation/stream returns are deinit'd + recorded with a
    // warning. Identical posture to `fireSubscriptionActivation`.
    switch (oc) {
        .terminal => |*r| {
            defer r.deinit(allocator);
            if (r.exception.len > 0) {
                txn.rollback() catch {};
                txn_done = true;
                const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, tape_payloads, corr_full, act_source);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                worker_streaming.proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset) catch |perr| {
                    std.log.warn("rove-js fetch-event ({s}): propose failed: {s}", .{ module_path, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, tape_payloads, corr_full, act_source);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, tape_payloads, corr_full, act_source);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireFetchEventActivation.commit(terminal)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, tape_payloads, corr_full, act_source);
            r.console = &.{};
            r.exception = &.{};
        },
        .continuation => |*cval| {
            // Phase 5 PR-2: lift the cont arm to actually dispatch
            // the named module. The fetch handler returned
            // `__rove_next(path, {fn, ctx})` — enqueue a SendCallback
            // Msg so the named handler runs as a fire-and-forget
            // chain hop on the next worker tick. Inherits the
            // current chain's correlation_id so replay UX groups
            // the whole flow (inbound → fetch → chained hop) under
            // one umbrella.
            defer cval.deinit(allocator);
            const enqueue_err = worker.node.enqueueChainedDispatchForTenant(
                tenant_id,
                cval.path,
                cval.ctx_json,
                cval.fn_name,
                corr_full,
            );
            if (enqueue_err) |_| {} else |err| std.log.warn(
                "rove-js fetch-event ({s}): chained dispatch enqueue failed: {s}",
                .{ module_path, @errorName(err) },
            );
            if (wrote) {
                worker_streaming.proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset) catch |perr| {
                    std.log.warn("rove-js fetch-event ({s}) cont-return propose failed: {s}", .{ module_path, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, tape_payloads, corr_full, act_source);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, tape_payloads, corr_full, act_source);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireFetchEventActivation.commit(cont)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, tape_payloads, corr_full, act_source);
        },
        .stream => |*s2| {
            s2.deinit(allocator);
            std.log.warn(
                "rove-js fetch-event ({s}): __rove_stream from a fetch activation is a no-op (v1)",
                .{module_path},
            );
            if (wrote) {
                worker_streaming.proposeForgetfulWrites(worker, &ws, txn, tenant_id, null, &readset) catch |perr| {
                    std.log.warn("rove-js fetch-event ({s}) stream-return propose failed: {s}", .{ module_path, @errorName(perr) });
                    txn_owned = false;
                    txn_done = true;
                    const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                    captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, tape_payloads, corr_full, act_source);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
                captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, tape_payloads, corr_full, act_source);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireFetchEventActivation.commit(stream)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            const tape_payloads = captureTapesForChainWithActivation(worker, &readset, body, corr_full, activation_bytes_for_tape);
            captureLogWithId(worker, tenant_id, request_id, "POST", module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, tape_payloads, corr_full, act_source);
        },
    }
}

/// streaming-handlers-plan §4.6: register a batch's kv-writes as
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
    // Effect-reification Phase 4.1.2: `extra_cmds` carries the
    // batch's `http.fetch` Cmds (transferred from the worker
    // dispatch's `batch_pending_fetches` accumulator). The Cmds
    // ride alongside the kv_wake_broadcast Cmds on this unit;
    // `interpretCmd` submits each PendingFetch to the engine on
    // commit, closing the marker-commit race
    // `webhook.send`'s sweep-only path papered over. `extra_cmds`
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
    // tenant we have exactly one entry. Phase 3.2.c: SharedTxnPool's
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

    // Phase 5: downgrade every entry across the three raft-pending
    // siblings to 503 + move to response_in.
    try drainLeadershipLossColl(worker, server, allocator, &worker.raft_pending_response, .response);
    try drainLeadershipLossColl(worker, server, allocator, &worker.raft_pending_cont, .cont);
    try drainLeadershipLossColl(worker, server, allocator, &worker.raft_pending_stream, .stream);
}

/// Phase 5 helper: walk one raft-pending sibling, 503 every entry,
/// move to response_in. `kind` tells us which side-table to clean —
/// cont needs `parked_meta`, stream needs `pending_stream_meta`;
/// response has no side store to free.
fn drainLeadershipLossColl(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    coll: anytype,
    kind: enum { response, cont, stream },
) !void {
    const entities = coll.entitySlice();
    const resp_bodies = coll.column(h2.RespBody);
    var i: usize = entities.len;
    while (i > 0) {
        i -= 1;
        const ent = entities[i];
        const resp_body = resp_bodies[i];
        // Phase 7: no per-kind side-table cleanup — all cont and
        // stream state lives on the entity's components and deinits
        // structurally when cleanupResponses destroys the entity.
        _ = kind;
        const old_body_ptr: ?[*]u8 = resp_body.data;
        const old_body_len: u32 = resp_body.len;
        try respb.overwrite503InPending(worker, coll, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);
        try server.reg.move(ent, coll, &server.response_in);
    }
}

// (proposeWriteSet/proposeRootWriteSet re-exports removed
// 2026-05-17 — unused; callers use raft_propose.* directly and
// proposeRootWriteSet itself is gone post-Option-A.)


/// Destroy entities sitting in `response_out` (h2 has finished
/// flushing them to the wire). Same pattern as the echo example's
/// `cleanupResponses`.
///
/// Phase 2b-ii: also reap streaming-chain state. An entity in
/// `response_out` that still has a stream cell (in either the
/// active or draining map, Phase 6) is a **client-disconnect** —
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
        // Phase 7: an entity in response_out with a populated
        // StreamChain.module_path is a client-disconnect on a held
        // stream — fire the disconnect activation before destroy.
        if (chain.module_path.len > 0) {
            worker_streaming.fireDisconnectActivation(worker, ent);
        }
        try server.reg.destroy(ent);
    }
}

// ── Helpers ────────────────────────────────────────────────────────────

pub fn hostOnly(authority: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    return authority[0..colon];
}

/// Look up handler bytecode for `module_base`, walking up the module
/// tree if the exact path isn't deployed. So `tenant/instance/acme/index`
/// falls back through `tenant/instance/index` → `tenant/index` →
/// `index`, whichever exists first. This lets a single deployed file
/// (`index.js` or `tenant/index.mjs`) catch every sub-path below it,
/// which is exactly what the admin handler needs — one JS module
/// does its own path-based dispatch.
pub fn findBytecode(
    tc: TenantFiles,
    module_base: []const u8,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var cur: []const u8 = module_base;
    var cur_owned: ?[]u8 = null;
    defer if (cur_owned) |o| allocator.free(o);

    while (true) {
        const mjs_key = try std.fmt.allocPrint(allocator, "{s}.mjs", .{cur});
        defer allocator.free(mjs_key);
        const js_key = try std.fmt.allocPrint(allocator, "{s}.js", .{cur});
        defer allocator.free(js_key);
        if (tc.snap.bytecodes.get(mjs_key)) |bc| return bc;
        if (tc.snap.bytecodes.get(js_key)) |bc| return bc;

        // At the root? Done — nothing matched.
        if (std.mem.eql(u8, cur, "index")) return null;

        // Walk up. cur is always of the form ".../X/index". Drop "X"
        // to get the parent's index: ".../index".
        const trailing_idx = std.mem.lastIndexOfScalar(u8, cur, '/') orelse return null;
        const before_segment = std.mem.lastIndexOfScalar(u8, cur[0..trailing_idx], '/');
        const new_cur = if (before_segment) |ps|
            try std.fmt.allocPrint(allocator, "{s}/index", .{cur[0..ps]})
        else
            try allocator.dupe(u8, "index");
        if (cur_owned) |o| allocator.free(o);
        cur_owned = new_cur;
        cur = new_cur;
    }
}

test "triggerPathToPrefix: catch-all" {
    try std.testing.expectEqualStrings("", triggerPathToPrefix("_triggers/index.mjs").?);
    try std.testing.expectEqualStrings("", triggerPathToPrefix("_triggers/index.js").?);
}

test "triggerPathToPrefix: single segment" {
    try std.testing.expectEqualStrings("users/", triggerPathToPrefix("_triggers/users/index.mjs").?);
    try std.testing.expectEqualStrings("users/", triggerPathToPrefix("_triggers/users/index.js").?);
}

test "triggerPathToPrefix: nested segments" {
    try std.testing.expectEqualStrings("users/sessions/", triggerPathToPrefix("_triggers/users/sessions/index.mjs").?);
    try std.testing.expectEqualStrings("a/b/c/d/", triggerPathToPrefix("_triggers/a/b/c/d/index.mjs").?);
}

test "triggerPathToPrefix: non-trigger paths return null" {
    // Not under _triggers/.
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("index.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("users/index.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_static/index.html"));
    // Under _triggers/ but not an index file (helper module imported by a trigger).
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_triggers/users/lib.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_triggers/users/sessions/util.mjs"));
    // Wrong extension.
    try std.testing.expectEqual(@as(?[]const u8, null), triggerPathToPrefix("_triggers/users/index.ts"));
}

// `isReservedTriggerPrefix` tests live alongside the helper in reserved.zig.

pub const ADMIN_SESSION_COOKIE = auth.ADMIN_SESSION_COOKIE;

// ── Starter content ────────────────────────────────────────────────
//
// Baked into the binary so a freshly-created tenant answers 200 on
// `/` the moment signup completes. Intentionally tiny — the point is
// to prove the deploy pipeline works end-to-end, not to ship a
// template. The customer replaces these as soon as they push their
// own code through the files API.
//
// Edited as plain files under `src/js/starter/` (registered in
// build.zig's `js_runtime_files`). Trailing newlines from the source
// files ride into the manifest — that is part of the content-addressed
// dep_id and is fine: starter content is byte-identical across every
// tenant, so the resulting dep_id is too.

const STARTER_INDEX_MJS = @embedFile("starter_index_mjs");
const STARTER_STATIC_INDEX_HTML = @embedFile("starter_static_index_html");

/// Write the initial deployment for a freshly-created instance. Opens
/// its own short-lived kv + blob-store connections, pushes the two
/// starter files through FileStore (which compiles + blob-addresses
/// them), and commits a deployment row. Closes everything on the way
/// out — the main worker and files-server lazy-open their own
/// connections later, so we're not holding onto any state that would
/// conflict.
/// Drop the starter content into the freshly-created tenant's
/// working tree, encode the resulting manifest as JSON, write it to
/// the per-tenant `deployments/` BlobBackend, and stage a `_deploy/
/// current = 1` write into `release_ws` so the caller can propose
/// it through raft alongside the rest of the signup writeset.
/// Phase 5.5(e) F2-storage retired the per-tenant files writeset
/// (envelope 3); the runtime release pointer rides envelope 0 with
/// the rest of the customer kv writes.
fn deployStarterContent(
    allocator: std.mem.Allocator,
    inst_dir: []const u8,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    release_ws: *kv_mod.WriteSet,
) !u64 {
    // Same scratch-only role as bootstrap.zig's
    // `.bootstrap-scratch.kv` — `files_mod.FileStore.init` demands
    // a KvStore but nothing persists here (the manifest goes to
    // S3). Use a per-call tmp kvexp file that gets deleted on
    // return.
    const files_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.starter-scratch.kv",
        .{inst_dir},
        0,
    );
    defer {
        std.fs.cwd().deleteFile(files_db_path) catch {};
        allocator.free(files_db_path);
    }
    std.fs.cwd().deleteFile(files_db_path) catch {};

    const files_kv = try kv_mod.KvStore.open(allocator, files_db_path);
    defer files_kv.close();

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "file-blobs",
    );
    defer blob_backend.deinit();

    var store = files_mod.FileStore.init(
        allocator,
        files_kv,
        blob_backend.blobStore(),
        compile_fn,
        compile_ctx,
    );

    try store.putSource("index.mjs", STARTER_INDEX_MJS);
    try store.putStatic("_static/index.html", STARTER_STATIC_INDEX_HTML, "text/html; charset=utf-8");

    const entries = try store.assembleManifest();
    defer store.freeEntries(entries);

    // Content-addressed dep_id (truncated sha-256). The starter content
    // is byte-identical across every tenant, so every starter deploy
    // mints the same id — and the per-tenant S3 prefix scopes the
    // manifest so cross-tenant collisions don't matter at all (each
    // tenant has its own `{inst_id}/deployments/` namespace).
    const next_id = files_mod.manifest_json.computeDeploymentId(entries);

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries);
    defer allocator.free(json_bytes);

    var manifest_be = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "deployments",
    );
    defer manifest_be.deinit();

    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, next_id);
    try manifest_be.blobStore().put(key, json_bytes);

    try store.setCurrentDeploymentId(next_id);

    // Stage `_deploy/current = next_id` so the caller's raft propose
    // sees it. Followers' apply path commits it into their copies of
    // the tenant's app.db; the worker's TenantFiles eager-open then
    // reads it on first request and loads the manifest from
    // manifest_backend (shared via fs/s3 between leader + followers).
    var hex_buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{next_id}) catch unreachable;
    try release_ws.addPut("_deploy/current", hex);
    return next_id;
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// Worker-level integration tests that don't need the full h2 stack.
// Anything that requires opening a listening socket lives in the
// binary's smoke test instead — these tests cover the lifecycle hooks
// that don't depend on h2.

const testing = std.testing;

// Pre-cutover this file held two tests:
//   - "openTenantFiles runs the orphan sweep on startup"
//   - "commitTxn drops the undo row so the next sweep is a no-op"
// Both exercised the SQLite-era `kv_undo` table + the recoverOrphans
// sweep. Under kvexp with deferred-durabilize the orphan scenario is
// structurally impossible: writes mutate the in-memory page cache
// only, durabilize is gated on the raft thread's tick, and a crash
// before durabilize loses the in-memory state entirely. The in-flight
// rollback case (raft rejects a still-pending proposal) is covered by
// `TrackedTxn.rollback`'s root-pointer revert — see kvstore.zig's
// "tracked txn rollback reverts pre_root" test.
//
// Tests intentionally removed rather than kept as skipped — they were
// asserting an invariant that no longer exists, and a "this test is
// disabled" comment with dead code is misleading.

test "captureLog appends a record to the worker's node-wide buffer" {
    // Verifies the captureLog helper end to end: build a fake worker
    // with a real TenantLog open against a temp dir, call captureLog,
    // then read the record back out of the worker's log_buffer.
    // Mirrors the dispatchPending capture path without spinning up
    // h2 or raft.
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-logcap-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);
    const root_kv = try kv_mod.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
    defer tenant.destroy();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
        log_buffer: log_mod.NodeLogBuffer,
    };
    var fake = FakeWorker{
        .allocator = allocator,
        .tenant_logs = .empty,
        .log_buffer = log_mod.NodeLogBuffer.init(allocator),
    };
    defer fake.tenant_logs.deinit(allocator);
    defer fake.log_buffer.deinit();

    const tl = try worker_log.openTenantLog(&fake, inst, 7);
    defer worker_log.freeTenantLog(allocator, tl);
    try fake.tenant_logs.put(allocator, tl.instance_id, tl);

    // Capture a single log record (the worker would do this from
    // dispatchPending). Empty owned slices for console + exception.
    const empty: []u8 = &.{};
    captureLog(
        &fake,
        "acme",
        "GET",
        "/test",
        "acme.test",
        42,
        1_000_000_000,
        200,
        .ok,
        empty,
        empty,
        .{},
        "test-correlation-id",
        .inbound,
    );

    try testing.expectEqual(@as(usize, 1), fake.log_buffer.buffer.items.len);
    const buffered = &fake.log_buffer.buffer.items[0];
    try testing.expectEqual(@as(u64, 200), @as(u64, buffered.status));
    try testing.expectEqualStrings("/test", buffered.path);
    try testing.expectEqual(@as(u64, 42), buffered.deployment_id);
    try testing.expectEqual(log_mod.Outcome.ok, buffered.outcome);
    // Phase 1b: the new tape fields make the round-trip.
    try testing.expectEqualStrings("test-correlation-id", buffered.correlation_id);
    try testing.expectEqual(log_mod.ActivationSource.inbound, buffered.activation);
}

test "captureLog records correlation_id + send_callback activation (Phase 1b)" {
    // Same fixture as the test above, asserting the new tape fields
    // round-trip when the activation source is a §6.4 resume.
    const allocator = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/rove-js-logcap-rsm-{x}", .{seed});
    defer allocator.free(tmp_dir);
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const root_path = try std.fmt.allocPrintSentinel(allocator, "{s}/__root__.db", .{tmp_dir}, 0);
    defer allocator.free(root_path);
    const root_kv = try kv_mod.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, tmp_dir);
    defer tenant.destroy();

    try tenant.createInstance("acme");
    const inst = tenant.instances.get("acme").?;

    const FakeWorker = struct {
        allocator: std.mem.Allocator,
        tenant_logs: std.StringHashMapUnmanaged(*TenantLog),
        log_buffer: log_mod.NodeLogBuffer,
    };
    var fake = FakeWorker{
        .allocator = allocator,
        .tenant_logs = .empty,
        .log_buffer = log_mod.NodeLogBuffer.init(allocator),
    };
    defer fake.tenant_logs.deinit(allocator);
    defer fake.log_buffer.deinit();

    const tl = try worker_log.openTenantLog(&fake, inst, 9);
    defer worker_log.freeTenantLog(allocator, tl);
    try fake.tenant_logs.put(allocator, tl.instance_id, tl);

    const empty: []u8 = &.{};
    captureLog(
        &fake,
        "acme",
        "POST",
        "handlers/resume",
        "",
        42,
        1_000_000_000,
        200,
        .ok,
        empty,
        empty,
        .{},
        "chain-abc-123",
        .send_callback,
    );

    try testing.expectEqual(@as(usize, 1), fake.log_buffer.buffer.items.len);
    const buffered = &fake.log_buffer.buffer.items[0];
    try testing.expectEqualStrings("chain-abc-123", buffered.correlation_id);
    try testing.expectEqual(log_mod.ActivationSource.send_callback, buffered.activation);
}

// Phase 7: ParkedCont deinit tests removed — ContDescriptor +
// ChainContext components have their own deinit tests in
// components.zig.

// ── Phase 5 PR-3: retry sweep — buildRetryFetch focused tests ─────────
//
// The sweep proper exercises through `webhook_recovery_smoke.py` (PR-3
// step 6). The unit tests here cover the JSON-marker parsing arms +
// stamped-header / ctx shapes that the smoke can't easily inspect
// without a tape harness — the bits most likely to drift on the next
// shim-side change.

test "buildRetryFetch: due marker → PendingFetch with stamped headers + ctx" {
    const a = testing.allocator;
    const marker =
        \\{"url":"https://hooks.example.com/webhook","method":"POST",
        \\"body":"{\"event\":\"order.paid\"}","headers":{"Content-Type":"application/json"},
        \\"attempts":0,"next_at_ns":"0","on_result":"hooks/onResult","context":{"tag":"ord-1"}}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (out.items) |*pf| pf.deinit(a);
        out.deinit(a);
    }
    try buildRetryFetch(a, "tenant-acme", "wh-deadbeef", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    const pf = &out.items[0];
    try testing.expectEqualStrings("tenant-acme", pf.tenant_id);
    try testing.expectEqualStrings("https://hooks.example.com/webhook", pf.url);
    try testing.expectEqualStrings("POST", pf.method);
    try testing.expectEqualStrings("__system/webhook_onresult", pf.on_chunk_module);
    try testing.expectEqual(false, pf.stream);
    // Stamped headers — both X-Rove-* fields and the original
    // Content-Type round-trip through.
    try testing.expect(std.mem.indexOf(u8, pf.headers_json, "\"X-Rove-Schedule-Id\":\"wh-deadbeef\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.headers_json, "\"X-Rove-Schedule-Version\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.headers_json, "\"Content-Type\":\"application/json\"") != null);
    // ctx shape: {id, on_result, context} — webhook_onresult.mjs reads
    // these three keys.
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"id\":\"wh-deadbeef\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"on_result\":\"hooks/onResult\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"context\":") != null);
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"tag\":\"ord-1\"") != null);
}

test "buildRetryFetch: not-due marker → error.NotDue, no entry appended" {
    const a = testing.allocator;
    const marker =
        \\{"url":"https://x.test/","method":"POST","body":"","headers":{},
        \\"attempts":2,"next_at_ns":"2000000000000000000"}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer out.deinit(a);
    const err = buildRetryFetch(a, "t", "wh", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectError(error.NotDue, err);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "buildRetryFetch: malformed JSON → error.MalformedMarker" {
    const a = testing.allocator;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer out.deinit(a);
    const err = buildRetryFetch(a, "t", "wh", "not-json{{{", 1_000_000_000_000_000_000, &out);
    try testing.expectError(error.MalformedMarker, err);
}

test "buildRetryFetch: missing url field → error.MalformedMarker" {
    const a = testing.allocator;
    const marker =
        \\{"method":"POST","body":"","attempts":0,"next_at_ns":"0"}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer out.deinit(a);
    const err = buildRetryFetch(a, "t", "wh", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectError(error.MalformedMarker, err);
}

test "buildRetryFetch: attempts increment bumps X-Rove-Schedule-Version" {
    const a = testing.allocator;
    const marker =
        \\{"url":"https://x.test/","method":"POST","body":"","headers":{},
        \\"attempts":3,"next_at_ns":"0"}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (out.items) |*pf| pf.deinit(a);
        out.deinit(a);
    }
    try buildRetryFetch(a, "t", "wh-id", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // attempts=3 in marker → fire stamps version=attempts+1=4.
    try testing.expect(std.mem.indexOf(u8, out.items[0].headers_json, "\"X-Rove-Schedule-Version\":\"4\"") != null);
}

test "retryFetchIdHex: stable per attempt, distinct across attempts" {
    const a = testing.allocator;
    const id_a = try retryFetchIdHex(a, "tenant-x", "wh-1", 0);
    defer a.free(id_a);
    const id_a_again = try retryFetchIdHex(a, "tenant-x", "wh-1", 0);
    defer a.free(id_a_again);
    const id_b = try retryFetchIdHex(a, "tenant-x", "wh-1", 1);
    defer a.free(id_b);
    const id_c = try retryFetchIdHex(a, "tenant-x", "wh-2", 0);
    defer a.free(id_c);
    try testing.expectEqualStrings(id_a, id_a_again); // determinism
    try testing.expect(!std.mem.eql(u8, id_a, id_b)); // attempts differ
    try testing.expect(!std.mem.eql(u8, id_a, id_c)); // owed-id differs
    try testing.expectEqual(@as(usize, 64), id_a.len); // sha256 hex
}

