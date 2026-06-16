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
//! h2.request_out  ── dispatchOnce ──▶  raft_pending (if writes)
//!                                   │
//!                                   └▶  h2.response_in (no writes)
//!
//! raft_pending    ── drainRaftPending ──▶  h2.response_in
//!                                      ── or 503 on fault/timeout ──▶
//! ```
//!
//! `dispatchOnce` runs the handler, stamps response components onto
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
//! Handler bytecode is loaded per deployment, not hard-coded: each
//! tenant's `TenantFilesSnapshot` holds a path→bytecode map backed by
//! the node-wide `BytecodeCache`, populated from the files-server's
//! deployment manifest. Routes and triggers come from that manifest;
//! `reloadDeployment` refreshes the snapshot when a new release rolls
//! out.
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
const kv_mod = @import("raft-kv");
// V2 Phase 2c: the per-tenant raft bridge replaces V1's node-wide
// `kv_mod.RaftNode` at the worker seam (v2-build-order §Phase 2).
const bridge_mod = @import("bridge");
const Bridge = bridge_mod.Bridge;
const blob_mod = @import("rove-blob");
const blob_sessions_mod = @import("blob_sessions.zig");
const blob_receive_mod = @import("blob_receive.zig");
const inbound_chunk_mod = @import("worker_inbound_chunk.zig");
const files_mod = @import("rove-files");
const log_mod = @import("rove-log");
const log_server_mod = @import("rove-log-server");
const jwt_mod = @import("rove-jwt");
const bodies_mod = @import("rove-bodies");
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const bytecode_cache_mod = @import("bytecode_cache.zig");
pub const BlobBytes = bytecode_cache_mod.BlobBytes;
pub const BytecodeCache = bytecode_cache_mod.BytecodeCache;
const continuation_mod = @import("bindings/continuation.zig");
const Continuation = continuation_mod.Continuation;
const components_mod = @import("components.zig");
const chunk_spool_mod = @import("chunk_spool.zig");
const effect_mod = @import("effect/root.zig");
const globals = @import("globals.zig");
const raft_propose = @import("raft_propose.zig");
const config_mirror = @import("config_mirror.zig");
const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const dispatch = @import("worker_dispatch.zig");
const worker_log = @import("worker_log.zig");
const worker_upload_checkpoint = @import("worker_upload_checkpoint.zig");
const worker_streaming = @import("worker_streaming.zig");
const worker_ws = @import("worker_ws.zig");
const worker_drain = @import("worker_drain.zig");
const deploy_thread_mod = @import("deploy_thread.zig");
const panic_mod = @import("panic.zig");
const penalty_mod = @import("penalty.zig");
const limiter_mod = @import("limiter.zig");
const router_mod = @import("router.zig");
const reserved = @import("reserved.zig");
const fetch_engine_mod = @import("fetch_engine.zig");
const proxy_engine_mod = @import("proxy_engine.zig");
pub const ProxyResultInbox = proxy_engine_mod.ProxyResultInbox;
const builtin_modules_mod = @import("builtin_modules.zig");
const msg_router_mod = @import("msg_router.zig");
pub const MsgRouter = msg_router_mod.MsgRouter;
const blob_coordination_mod = @import("blob_coordination.zig");
pub const BlobCoordination = blob_coordination_mod.BlobCoordination;
const deployment_cache = @import("deployment_cache.zig");
// Phase C: the per-tenant deployment cache + TenantSlot type family live
// in deployment_cache.zig now. Re-exported here so existing callers
// (worker_mod.X internally, root.zig, main.zig via rjs.X) keep working.
pub const DeploymentCache = deployment_cache.DeploymentCache;
pub const TenantSlot = deployment_cache.TenantSlot;
pub const TenantFilesSnapshot = deployment_cache.TenantFilesSnapshot;
pub const TenantFiles = deployment_cache.TenantFiles;
pub const StaticEntry = deployment_cache.StaticEntry;
pub const TriggerEntry = deployment_cache.TriggerEntry;
pub const PrefetchedManifest = deployment_cache.PrefetchedManifest;
pub const ManifestHttpConfig = deployment_cache.ManifestHttpConfig;
pub const ManifestPrefetchMap = deployment_cache.ManifestPrefetchMap;
const owed_retry = @import("owed_retry.zig");
// The `_send/owed/` marker's §6.4 held-sync binding scan (the retry
// SWEEP retired with durable-wake-plan P5(a) — deferred fires ride the
// durable scheduler as `__system/webhook_fire` wakes). Re-exported so
// worker_drain/worker_dispatch (worker_mod.X) keep working unchanged.
pub const OWED_PREFIX = owed_retry.OWED_PREFIX;
pub const scanLoneOwedSendId = owed_retry.scanLoneOwedSendId;
const subscription_sweep = @import("subscription_sweep.zig");
// Boot subscription sweep lives in subscription_sweep.zig (the cron
// half retired with durable-wake-plan P5(b) — recurrence rides the
// durable scheduler).
pub const sweepBootSubscriptions = subscription_sweep.sweepBootSubscriptions;
const starter = @import("starter.zig");
pub const sweepBlobSessions = @import("blob_sessions.zig").sweepBlobSessions;
const durable_wake = @import("durable_wake.zig");
// §2.6 durable scheduled-wake sweep lives in durable_wake.zig.
pub const sweepDurableWakes = durable_wake.sweepDurableWakes;
pub const sweepDurableWakesOnPromotion = durable_wake.sweepDurableWakesOnPromotion;

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
    /// V2 Phase 2c: the tenant's raft group id. The drain looks up this
    /// tenant's per-tenant committed/faulted watermark
    /// (`bridge.committedSeq(group_id)`) instead of V1's single global
    /// watermark — so tenant B's commit never waits on tenant A's.
    group_id: u64 = 0,
    /// Per-tenant propose seq (the bridge assigns it; monotonic per
    /// tenant). Durable when `bridge.committedSeq(group_id) >= seq`.
    seq: u64 = 0,
    deadline_ns: i64 = 0,
};

/// Per-entity park record for `/_system/deploy` (`docs/rewind-cli-plan.md`
/// §4 — files-server dissolution). The handler hands the parsed bundle
/// to the background `DeployThread`, stamps this component, and moves the
/// request entity into `compile_pending`. `drainCompilePending` polls the
/// thread's result map by `compile_id` each tick; on completion it stamps
/// the staged HTTP response and ships it, on `deadline_ns` it reaps 504.
///
/// Unlike `RaftWait`, the response is NOT staged at park time — deploy
/// doesn't know its `dep_id` until the compile/stage finishes, so the
/// drain builds the response post-completion.
pub const CompileWait = struct {
    /// Worker-monotonic id matching the enqueued `DeployThread.Job`.
    compile_id: u64 = 0,
    /// Absolute `std.time.nanoTimestamp()` reap deadline.
    deadline_ns: i64 = 0,
};

/// Per-entity park record for async serve-or-forward (`proxy_engine.zig`).
/// When `resolveRequest` can't resolve a tenant locally and a control
/// plane is configured, it stamps this component, submits a
/// `ProxyJobSpec` to the node's proxy engine, and moves the entity from
/// `request_out` to `forward_pending`. `drainForwardPending` matches the
/// engine's `ProxyResult.forward_id` back to the parked entity and
/// builds the final response (or reaps on `deadline_ns`).
pub const ForwardWait = struct {
    /// Matches `ProxyResult.forward_id` (node-monotonic; never 0).
    forward_id: u64 = 0,
    /// Hard deadline; on expiry the drain responds 504 and frees the slot.
    deadline_ns: i64 = 0,
};

/// Per-entity park record for `docs/readset-replication-plan.md`
/// Phase 4 (park-on-durability). When `dispatchPending` parks an
/// entity waiting for its inbound request body's batch to flush,
/// it sets this component with the coordinator's `(worker_id,
/// worker_seq)` durability key and the owning tenant id, then
/// `reg.move`s the entity from `request_out` to `body_pending`.
///
/// docs/streaming-model.md §7: durability is observed
/// via `node.blob_coordinator.durableSeq(worker_id) > worker_seq`.
/// `drainBodyPending` polls that atomic and, on advance, looks up
/// `coord.bodyRef(worker_id, worker_seq)` to materialize the wire
/// `BodyRef` (batch_id + offset + len) into `body_ref`. Resume
/// path in `dispatchPending`'s body-gate reads `body_ref` and
/// stamps it on the readset.
///
/// `status` is the lifecycle discriminator the dispatch body-gate
/// reads on resume — NOT `body_ref.batch_id`. A failed park leaves
/// `body_ref` at the `NO_BATCH` default, which is byte-identical to a
/// fresh (never-parked) request's default component; keying the resume
/// off `body_ref` alone silently re-submits+re-parks a permanently-
/// failing body instead of returning 503. The explicit `status` makes
/// the three states distinguishable by construction.
///
/// `tenant_id` is a borrowed slice into the per-tenant
/// `tenant_mod.Instance.id` — owned by the NodeState's tenant
/// registry, lives for the process lifetime.
pub const BodyDurabilityStatus = enum {
    /// Default: entity was never parked (a fresh request_out entity
    /// carries the component default). The dispatch body-gate runs the
    /// normal size-based inline/park/none logic.
    fresh,
    /// Park succeeded: `body_ref` is the materialized wire ref. The
    /// dispatch body-gate stamps it on the readset and proceeds.
    resolved,
    /// Park failed: the submitted body never became durable
    /// (`coord.bodyRef` errored). The dispatch body-gate returns 503;
    /// `body_ref` is meaningless (stays at the NO_BATCH default).
    failed,
};

/// §3.5.1: consult the worker's per-(deployment, module) `onHeaders`
/// export cache. `null` = unknown (first body-carrying request to
/// this module on this worker — probe and fill).
pub fn onHeadersLookup(worker: anytype, dep_id: u64, module_base: []const u8) ?bool {
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ dep_id, module_base }) catch return null;
    return worker.onheaders_cache.get(key);
}

/// Record a probe outcome. Deployments are immutable, so an entry
/// never changes; the map is bounded by a hard clear at 8192 entries
/// (only reachable through thousands of distinct deployments on one
/// worker — re-probing after a clear is just one extra dispatch).
pub fn onHeadersRemember(worker: anytype, dep_id: u64, module_base: []const u8, has_onheaders: bool) void {
    const allocator = worker.allocator;
    if (worker.onheaders_cache.count() >= 8192) {
        var it = worker.onheaders_cache.keyIterator();
        while (it.next()) |kp| allocator.free(kp.*);
        worker.onheaders_cache.clearRetainingCapacity();
    }
    const key = std.fmt.allocPrint(allocator, "{d}:{s}", .{ dep_id, module_base }) catch return;
    const gop = worker.onheaders_cache.getOrPut(allocator, key) catch {
        allocator.free(key);
        return;
    };
    if (gop.found_existing) allocator.free(key);
    gop.value_ptr.* = has_onheaders;
}

/// Gap 2.4: the `onChunk` twin of `onHeadersLookup` — same key shape,
/// same probe-and-fill discipline.
pub fn onChunkLookup(worker: anytype, dep_id: u64, module_base: []const u8) ?bool {
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ dep_id, module_base }) catch return null;
    return worker.onchunk_cache.get(key);
}

/// Gap 2.4: the `onChunk` twin of `onHeadersRemember`.
pub fn onChunkRemember(worker: anytype, dep_id: u64, module_base: []const u8, has_onchunk: bool) void {
    const allocator = worker.allocator;
    if (worker.onchunk_cache.count() >= 8192) {
        var it = worker.onchunk_cache.keyIterator();
        while (it.next()) |kp| allocator.free(kp.*);
        worker.onchunk_cache.clearRetainingCapacity();
    }
    const key = std.fmt.allocPrint(allocator, "{d}:{s}", .{ dep_id, module_base }) catch return;
    const gop = worker.onchunk_cache.getOrPut(allocator, key) catch {
        allocator.free(key);
        return;
    };
    if (gop.found_existing) allocator.free(key);
    gop.value_ptr.* = has_onchunk;
}

/// headers_first dispatch state (blob-storage-plan §3.5.1; `docs/architecture/routing-and-ingress.md`).
/// `drainRequestReceiving` moves an early-emitted request (body still
/// inbound) from h2's `request_receiving` into `request_out` with
/// `receiving = true`; `dispatchOnce` runs it as an
/// `.inbound_headers` activation (empty body, `onHeaders` export).
/// Cleared when the probe misses (classic buffering takes over — the
/// entity returns body-complete with the default-false component) or
/// when h2 attaches an already-complete body in place. The default
/// (false) is what every classic entity carries.
pub const BodyInbound = struct {
    receiving: bool = false,
};

pub const BodyDurabilityWait = struct {
    /// Coord durability key — opaque to the dispatch path.
    worker_seq: u64 = 0,
    worker_id: u8 = 0,
    /// Park outcome. `.fresh` until `drainBodyPending` resolves the
    /// coord seq to `.resolved` (with a real `body_ref`) or `.failed`.
    status: BodyDurabilityStatus = .fresh,
    /// Materialized BodyRef — meaningful only when `status == .resolved`.
    body_ref: bodies_mod.BodyRef = .{
        .batch_id = bodies_mod.NO_BATCH,
        .offset = 0,
        .len = 0,
    },
    tenant_id: []const u8 = "",
};

/// Slice 4-fetch-park: parked outbound-fetch chunk activation.
/// `UpstreamFetchEvent`s arrive via the msg_inbox and don't have
/// an h2 entity to attach a `BodyDurabilityWait` component to, so
/// the park list lives as a plain `ArrayListUnmanaged` on
/// `Worker.fetch_pending_durability` instead of a rove
/// `Collection`. `event` is owned by the list (originally arrived
/// owned by the dispatchPendingMsgs caller; ownership transferred
/// when `fireFetchEventActivation` flipped its `parked_to_durability`
/// flag).
///
/// docs/streaming-model.md §7: durability is observed
/// via the process-global coordinator. `drainFetchPendingDurability`
/// polls `coord.durableSeq(worker_id) > worker_seq` each tick. On
/// advance, it looks up `coord.bodyRef(worker_id, worker_seq)`,
/// materializes the wire `BodyRef`, and re-fires
/// `fireFetchEventActivation(_, _, body_ref)`.
pub const ParkedFetchEvent = struct {
    event: components_mod.UpstreamFetchEvent,
    /// Coord durability key.
    worker_seq: u64,
    worker_id: u8,
    /// Borrowed slice into `event.tenant_id` (or the owning
    /// `tenant_mod.Instance.id` — both are stable for the
    /// process lifetime). Cached so drain doesn't have to dereference
    /// `event.tenant_id` again.
    tenant_id_view: []const u8,
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

/// One inbound WS frame held behind its connection's input gate
/// (websocket-plan §4.5 strict reply ordering). `payload` is an owned
/// copy — the transport's `ws_message_out` entity is destroyed in the
/// same tick the frame queues.
pub const WsQueuedFrame = struct {
    opcode: u8,
    payload: []u8,
};

/// Per-WS-connection worker state (the `ws_conns` map value).
///
/// `gate_seq != 0` is the **input gate** (websocket-plan §4.5, the DO
/// input-gate analog): a writing frame's forgetful unit is awaiting
/// raft at that per-tenant seq, so newly-arriving frames queue on
/// `queue` instead of activating. `flushWsGates` re-opens the gate
/// once the seq is committed AND its parked unit has been released
/// (the unit check is what makes "this conn's prior reply frames
/// already reached `ws_send_in`" true — committedSeq alone races the
/// drain), then dispatches the queue in arrival order. This yields
/// both strict reply ordering and read-your-writes across a
/// connection's frames: frame K+1 never activates while frame K's
/// writes are un-durable. Fault/timeout of the gated seq closes the
/// connection (the discarded reply can't be re-created — honest
/// failure, mirroring the propose-fail path).
pub const WsConnState = struct {
    /// The held chain entity in `parked_continuations`.
    chain: rove.Entity,
    /// Raft seq the gate is closed on (0 = open).
    gate_seq: u64 = 0,
    /// The tenant group the seq belongs to (resolved at arm time).
    gate_gid: u64 = 0,
    /// Gate abandon deadline — mirrors the parked unit's own
    /// `commit_wait_timeout_ns` so a unit reaped by leadership loss
    /// (which never advances the fault watermark) can't wedge the
    /// connection forever.
    gate_deadline_ns: i64 = 0,
    /// Frames awaiting the gate, in arrival order.
    queue: std.ArrayListUnmanaged(WsQueuedFrame) = .empty,
};

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

/// Hold deadline for a chain whose `blob.receive` is mid-upload —
/// the client streams for the duration and NOTHING bumps the parked
/// deadline (zero chunk activations by design, §3.5). Sized for the
/// largest plan-tier body (256 MiB) on a slow uplink; the h2 idle
/// timeout reaps genuinely dead clients long before this.
pub const RECEIVE_HOLD_DEADLINE_NS: i64 = 15 * 60 * std.time.ns_per_s;

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
    /// Handler-surface Phase 1 (`on.kv`): the producer store's
    /// `KvStore.writeVersion` at the moment this write was incorporated
    /// (§8.4). `matchEventsToWakes` fires a watch only when this is
    /// strictly greater than the watch's `read_version` baseline, so a
    /// watch never wakes for state its arming handler already saw.
    /// `std.math.maxInt(u64)` is the "fire-always" sentinel a producer
    /// stamps when it couldn't read the clock (contended lease) — an
    /// over-fire is permitted (§9.4), a missed wake is not.
    write_version: u64 = 0,

    pub fn deinit(self: *KvWakeEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.key);
        self.* = undefined;
    }
};

/// Thread-safe per-worker inbox of kv-write events awaiting prefix-
/// match scan against the worker's local parked stream chains'
/// `kv_prefixes` wake conditions.
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
    pub fn push(self: *KvWakeInbox, tenant_id: []const u8, key: []const u8, op: u8, write_version: u64) !void {
        const tid = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(tid);
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.append(self.allocator, .{ .tenant_id = tid, .key = k, .op = op, .write_version = write_version });
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

/// `docs/chunk-spool-plan.md` Phase 3: default per-fetch chunk-spool
/// RAM window depth (K). At the 64KB default `max_response_chunk_bytes`
/// this caps inline RAM at ~256KB per in-flight bound fetch; chunks
/// beyond the window read their bytes back from the coordinator.
/// Override via `ROVE_BOUND_FETCH_SPOOL_DEPTH`.
pub const DEFAULT_BOUND_FETCH_SPOOL_DEPTH: usize = 4;

/// `docs/chunk-spool-plan.md` P6: a deferred `coord.release(worker_id,
/// seq)` for a consumed/dropped bound chunk whose coordinator submit
/// wasn't durable yet at consume time. Retried in `drainSpools`.
pub const CoordPendingRelease = struct { worker_id: u8, seq: u64 };

/// Read the `ROVE_BOUND_FETCH_SPOOL_DEPTH` env override, falling back
/// to `DEFAULT_BOUND_FETCH_SPOOL_DEPTH`. A 0 / unparseable value is
/// clamped to 1 (depth 0 would evict the head itself, forcing a coord
/// read on every single dispatch — never what an operator wants).
fn readBoundFetchSpoolDepth() usize {
    const raw = std.posix.getenv("ROVE_BOUND_FETCH_SPOOL_DEPTH") orelse
        return DEFAULT_BOUND_FETCH_SPOOL_DEPTH;
    const parsed = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch
        return DEFAULT_BOUND_FETCH_SPOOL_DEPTH;
    return @max(parsed, 1);
}

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

/// Lazy-open lifecycle cache: a `StringHashMapUnmanaged(*Entry)` that
/// drives entry lifecycle through `Entry.open(worker, inst)` /
/// `Entry.free(allocator, *Entry)`, with `getOrOpen` as the lazy
/// constructor and `clearAllEntries`/`deinit` as bulk teardown.
///
/// Now used only by `tenant_logs` (`TenantMap(TenantLog)`). The
/// per-tenant *slot* cache used to share this generic but no longer
/// does: opening a slot performs blob/libcurl I/O that must run without
/// holding the cache lock, which `getOrOpen` can't express — so
/// `DeploymentCache` open-codes that path and uses a plain
/// `StringHashMapUnmanaged(*TenantSlot)` instead. This generic stays
/// for the log cache, whose open is cheap and fits the convention.
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

    /// Process-wide blob backend config. Borrowed slices owned by
    /// `main.zig`/env. Consumed by the deployment cache (per-tenant
    /// backend opens) and the blob coordinator; stays on NodeState
    /// because both subsystems read it.
    blob_backend_cfg: blob_mod.BackendConfig,

    /// Process raft node (= `cluster.raft`). Borrowed; owned by
    /// `main.zig`. Also copied into `deploy` + each `TenantSlot` so
    /// `reloadDeployment` can leader-gate + propose the config mirror.
    raft: *Bridge,

    /// Per-tenant deployment cache subsystem — tenant-slot map +
    /// node-wide bytecode cache + deployment-loader thread + manifest
    /// config. Extracted into `DeploymentCache` (`deployment_cache`
    /// concern); borrows `tenant`/`raft`/`blob_backend_cfg` at init and
    /// `router` via `wireInternal`. `node.deploy.*`.
    deploy: DeploymentCache,

    /// Async-activation routing subsystem — the per-worker inbox
    /// registries (unified `effect.MsgInbox` + kv-wake `KvWakeInbox`)
    /// and the cross-worker held-state owner registries, plus every
    /// `enqueue*` / `broadcast*` / `register*` path that routes a
    /// cross-thread `effect.Msg` to the worker that should service it.
    /// Extracted from NodeState into `msg_router.zig`; depends only on
    /// `allocator`. See that file for the routing rules (hash-by-tenant
    /// default vs held-state owner override).
    router: MsgRouter,

    /// Phase 5 PR-2b: built-in `__system/*` module bytecodes,
    /// compiled once at `init` from sources baked into the binary
    /// (see `src/js/builtin_modules.zig`). Shared across every
    /// tenant context — the shim's onresult handler runs against
    /// these bytecodes, not against per-tenant deployment files.
    /// `resolveDeployment` falls through to this when `module_path`
    /// starts with `__system/`.
    builtin_modules: std.StringHashMapUnmanaged([]u8) = .empty,

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

    /// Async serve-or-forward engine (Phase 7 follow-up). One thread +
    /// one `curl_multi` handle proxies mis-routed requests to the owning
    /// cluster OFF the worker poll loop (the prior blocking
    /// `tryForwardToOwner` stalled the loop for a full cross-cluster
    /// round-trip). Lazy init via `startProxyEngine` after workers spawn.
    /// See `proxy_engine.zig`.
    proxy_engine: ?*proxy_engine_mod.ProxyEngine = null,
    /// Per-worker result inboxes the proxy engine pushes into, indexed
    /// by `worker.msg_inbox_idx`. Node-owned (allocated by
    /// `startProxyEngine`, sized to the worker count, freed in `deinit`
    /// AFTER the engine thread is joined) so a worker's own teardown can
    /// never race a pending engine push.
    proxy_result_inboxes: []ProxyResultInbox = &.{},
    /// Monotonic id stamped on each parked forward so its async result
    /// routes back to the right parked entity. Starts at 1 (0 = unset).
    next_forward_id: std.atomic.Value(u64) = .init(1),

    /// Readset-blob write subsystem — the process-global
    /// `BlobCoordinator`, the shared `_pool/` S3 backend, the
    /// raft-backed reservation context, and the borrowed `kv.Cluster`
    /// handle the reservation provider needs. Extracted from NodeState
    /// into `blob_coordination.zig`. Lazy-started via
    /// `blob_coord.start(num_workers)` after `blob_coord.setCluster`.
    /// See `docs/streaming-model.md §7` Phases 3 + 5.
    blob_coord: BlobCoordination,

    pub fn init(
        allocator: std.mem.Allocator,
        tenant: *tenant_mod.Tenant,
        blob_backend_cfg: blob_mod.BackendConfig,
        raft: *Bridge,
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
            .router = MsgRouter.init(allocator),
            .blob_coord = BlobCoordination.init(allocator, blob_backend_cfg),
            .deploy = DeploymentCache.init(allocator, tenant, raft, blob_backend_cfg),
        };
    }

    /// Wire self-referential internal handles after NodeState is at its
    /// final, stable address. `NodeState.init` returns by value, so a
    /// pointer like `&self.router` can't be captured during init — the
    /// struct still moves to its home afterward. The owner (`main.zig`)
    /// MUST call this once before opening any tenant slot so
    /// `deploy.router` (used to stamp `TenantSlot.router` for
    /// boot-subscription firing) is live.
    pub fn wireInternal(self: *NodeState) void {
        self.deploy.router = &self.router;
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
        // Proxy engine before its result inboxes: join the engine thread
        // (no more pushes) THEN free the node-owned inboxes. Any results
        // still queued at shutdown are freed via each inbox's deinit.
        if (self.proxy_engine) |pe| {
            pe.shutdown();
            pe.deinit();
            self.proxy_engine = null;
        }
        if (self.proxy_result_inboxes.len > 0) {
            for (self.proxy_result_inboxes) |*ib| ib.deinit(self.allocator);
            self.allocator.free(self.proxy_result_inboxes);
            self.proxy_result_inboxes = &.{};
        }
        // Tear down the blob-coord subsystem AFTER the fetch engine —
        // the engine's libcurl thread reaches `blob_coord.coordinator`,
        // so it must be joined first (above) before the coordinator +
        // pool backend + reservation ctx are freed here.
        self.blob_coord.deinit();
        // Drop the inbox registries + held-state owner maps. Workers
        // destroy their own inboxes in their deinit, so by the time
        // NodeState tears down every inbox should already be
        // unregistered; the registry lists + owned owner-keys are
        // freed here as the catchall for any straggler at shutdown.
        // Ordered after the fetch engine + coordinator shut down so
        // no producer thread touches the registries mid-teardown.
        self.router.deinit();
        builtin_modules_mod.deinit(&self.builtin_modules, self.allocator);
        // Phase 2 of curl-multi work: pending-fetches queue
        // moved into the FetchEngine; its shutdown above already
        // drained + freed any queued + in-flight entries.
        //
        // Deployment cache last: stops the loader thread, frees every
        // tenant slot, then the bytecode cache (after the slots, which
        // release their snapshot leases through it), then the manifest
        // prefetch map. Ordering lives inside `DeploymentCache.deinit`.
        self.deploy.deinit();
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

    /// Spawn the async serve-or-forward engine (one thread + one
    /// curl_multi handle) and allocate the per-worker result inboxes.
    /// Idempotent. Call once from `main.zig` AFTER workers have spawned
    /// + registered their msg inboxes — `num_workers` sizes the inbox
    /// array, indexed by each worker's `msg_inbox_idx`.
    pub fn startProxyEngine(self: *NodeState, num_workers: usize) !void {
        if (self.proxy_engine != null) return;
        const inboxes = try self.allocator.alloc(ProxyResultInbox, num_workers);
        errdefer self.allocator.free(inboxes);
        for (inboxes) |*ib| ib.* = .{};
        self.proxy_result_inboxes = inboxes;

        const pe = try proxy_engine_mod.ProxyEngine.init(self.allocator, self);
        errdefer pe.deinit();
        try pe.start();
        self.proxy_engine = pe;
    }
};

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
    raft: *Bridge,
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
    /// V2 Phase 4 — shared secret for the cluster-internal tenant-move
    /// surface (`/_system/v2-*`: kv seed/read, bundle dump, attach,
    /// evict). The front door (`rewind-front`) holds the same secret and
    /// presents it as `X-Rewind-Move-Secret` when orchestrating a move
    /// across clusters. Distinct from the operator root bearer (which the
    /// front door does not hold) and from the services JWT. When null the
    /// move endpoints are disabled (404/501). Borrowed; alive for the
    /// worker's lifetime. (v2-build-order §Phase 4.)
    move_secret: ?[]const u8 = null,
    /// This cluster's logical id in the control-plane directory (Phase 7
    /// serve-or-forward). When set together with `cp_urls`, a request for a
    /// tenant this cluster can't resolve locally is forwarded to the cluster
    /// the CP says owns it, instead of 404 — so a stale public route (or a
    /// request to a post-move source) costs an extra hop, never a failure.
    /// Unset → no forwarding (a local miss 404s as before). Borrowed.
    cluster_id: ?[]const u8 = null,
    /// Base URLs of the CP nodes for the route lookup
    /// (`{cp}/_cp/route?host=`). A LIST (Slice 2 HA): the CP is a 3-node
    /// cluster, and routing reads work on ANY CP node (apply-driven
    /// projection), so the worker tries each until one answers — surviving a
    /// CP node failure. Paired with `cluster_id`; empty disables serve-or-
    /// forward. Borrowed.
    cp_urls: []const []const u8 = &.{},
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
    /// `docs/readset-replication-plan.md` Phase 5b — node's data
    /// directory. The worker reads its per-worker
    /// `last_uploaded_seq` checkpoint at startup from
    /// `{data_dir}/_meta/last_uploaded_seq_w{log_worker_id:0>4}.txt`
    /// and writes after each successful `flushLogs`. Null disables
    /// the checkpoint (some unit-test fixtures that don't need
    /// readset-replication persistence).
    data_dir: ?[]const u8 = null,
};

pub const dispatchOnce = dispatch.dispatchOnce;
pub const drainRequestReceiving = dispatch.drainRequestReceiving;

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
        CompileWait,
        ForwardWait,
        BodyDurabilityWait,
        BodyInbound,
        components_mod.ChainContext,
        components_mod.ContDescriptor,
        components_mod.StreamChain,
        components_mod.StreamChunks,
        components_mod.StreamWakes,
        components_mod.StreamDraining,
        components_mod.BoundFetchCount,
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

    // blob-storage-plan P2; `docs/architecture/routing-and-ingress.md`: open blob upload sessions —
    // one entity per (tenant, chain) accumulating `blob.write`
    // bytes until `blob.seal`. Per-worker (a chain's activations
    // all run on its owning worker). Session strings + buffer
    // auto-deinit on entity destroy.
    const BlobSessionRow = rove.Row(&.{blob_sessions_mod.Session});
    const BlobSessionColl = rove.Collection(BlobSessionRow, .{});

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
        /// dispatch state, no membership field-check needed
        /// (principle #1, state-via-collection-membership).
        raft_pending_response: StreamColl,
        /// Continuation-bound raft park. Commits route to
        /// `parked_continuations`. Same Row as `raft_pending_response`.
        raft_pending_cont: StreamColl,
        /// Stream-first-hop raft park. Commits route to
        /// `stream_response_in` (after the entity's stream components
        /// are set). Same Row.
        raft_pending_stream: StreamColl,
        /// `docs/readset-replication-plan.md` Phase 4 park-on-
        /// durability. Entities `dispatchPending` parked after
        /// submitting their inbound body (> 16 KB) to the process-
        /// global blob coordinator (`coord.submit` → seq), waiting for
        /// it to land in S3. `drainBodyPending` walks this collection
        /// on each main-loop tick, polling `coord.durableSeq(worker_id)`
        /// against each entity's parked seq; once durable it stamps the
        /// materialized `BodyRef` and moves the entity back to
        /// `request_out` for re-dispatch (the handler runs against the
        /// already-durable body).
        ///
        /// Same `StreamRow` as `raft_pending_*` / `request_out` so
        /// `reg.move` preserves every component on transit (the H2
        /// request headers / body / sid / etc. ride the entity until
        /// the response is built).
        body_pending: StreamColl,
        /// Async serve-or-forward park (`proxy_engine.zig`). A request
        /// for a tenant this cluster doesn't own parks here with a
        /// `ForwardWait` while the proxy engine runs the CP route-query
        /// + forward off the worker loop; `drainForwardPending` walks
        /// this collection each tick, matching the engine's result back
        /// to the parked entity and moving it to `response_in`. Same
        /// `StreamRow` as `raft_pending_*` so `reg.move` preserves the
        /// h2 sid/session/headers the response needs.
        forward_pending: StreamColl,
        /// `/_system/deploy` park (`docs/rewind-cli-plan.md` §4). A
        /// deploy request parks here with a `CompileWait` while the
        /// background `DeployThread` compiles + stages the bundle off
        /// the poll loop; `drainCompilePending` walks this collection
        /// each tick, matching the thread's result back to the parked
        /// entity and moving it to `response_in`. Same `StreamRow` as
        /// `raft_pending_*` so `reg.move` preserves the h2 sid/session
        /// the response needs.
        compile_pending: StreamColl,
        /// Background compile+stage thread for `/_system/deploy`. Owns
        /// its own QuickJS runtime (the poll-loop `compile_fn` is used
        /// by `deployStarterTrampoline` — can't share one runtime
        /// across threads). Null until `startDeployThread`; library /
        /// test builds that never deploy leave it null.
        deploy_thread: ?*deploy_thread_mod.DeployThread = null,
        /// Worker-monotonic id stamped on each deploy job + its
        /// `CompileWait`. Poll-loop only (no lock). Starts at 0;
        /// pre-incremented so the first job is 1 (0 stays a sentinel).
        next_compile_id: u64 = 0,
        /// Slice 4-fetch-park: parked outbound-fetch chunk events
        /// (large chunks waiting on durability). Plain
        /// `ArrayListUnmanaged` rather than a rove `Collection`
        /// because `UpstreamFetchEvent`s don't have an h2 entity
        /// to host a wait component.
        ///
        /// Producer: `fireFetchEventActivation` on the park
        /// branch (worker thread, no lock needed — single
        /// producer per Worker).
        /// Consumer: `drainFetchPendingDurability` on the same
        /// worker thread, called from the main poll loop next
        /// to `drainBodyPending`.
        fetch_pending_durability: std.ArrayListUnmanaged(ParkedFetchEvent) = .empty,
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
        /// tick and matches events against the parked stream chains'
        /// `kv_prefixes`. Pointer registered with
        /// `worker.node.router.registerWakeInbox` in `Worker.create`;
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
        /// blob-storage-plan P2; `docs/architecture/routing-and-ingress.md`: open blob upload sessions
        /// (`blob.write` / `blob.seal`). TTL-swept via
        /// `blob_sessions.sweepBlobSessions` in the worker tick.
        blob_sessions: BlobSessionColl,
        /// §3.5.1: per-(deployment, module) "exports onHeaders" cache,
        /// keyed `"{dep_id}:{module_base}"` (owned keys). Filled by
        /// dispatch outcomes (a deployment's exports are immutable),
        /// consulted by the headers-first disposition so steady-state
        /// classic POSTs pay no probe. Worker-local — no locking.
        onheaders_cache: std.StringHashMapUnmanaged(bool) = .empty,
        /// Gap 2.4: per-(deployment, module) "exports onChunk" cache —
        /// same shape, fill discipline, and bound as `onheaders_cache`.
        /// Consulted after a known-no onHeaders outcome to pick the
        /// chunk-dispatch path without re-probing.
        onchunk_cache: std.StringHashMapUnmanaged(bool) = .empty,
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
        /// §2.6 durable-wake: monotonic-ns of the last
        /// `sweepDurableWakes` invocation on THIS worker. Throttles the
        /// per-tick durable-wake sweep to one pass per
        /// `WAKE_SWEEP_INTERVAL_NS`. Per-worker (not just worker 0)
        /// because the sweep is partitioned the same way the owed
        /// sweep is — `hash(tenant_id) % N_msg_inboxes == self.msg_inbox_idx`.
        last_wake_sweep_ns: i64 = 0,
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
        /// `docs/streaming-model.md` §7 item 1 + `docs/handler-shape.md`
        /// §5.5: registry for `http.fetch({bind: true})` — maps
        /// `fetch_id` to the entity that issued the fetch. Populated
        /// at the handler-success seam (`worker_dispatch`'s direct
        /// `registerBoundFetchTrampoline` call, where `bind = held and
        /// !detach` is computed — docs/auto-bind-plan.md); consulted
        /// in `dispatchPendingMsgs`'s `.fetch_chunk` arm to route
        /// upstream chunks into the held chain's `onFetchChunk`
        /// resume; cleared on terminal (`ev.final`) or on held-client
        /// disconnect.
        ///
        /// Keys are allocator-owned dupes of the fetch_id; freed
        /// when the entry is removed (or by `destroy` on shutdown).
        /// Entity handles are stable across `reg.move` per
        /// rove-library principle #8, so a chain transitioning
        /// cont→stream doesn't invalidate the map entry.
        bound_fetch_entities: std.StringHashMapUnmanaged(rove.Entity) = .empty,
        /// `docs/websocket-plan.md` §4.5/§5 (piece D): per-connection
        /// held WebSocket chain locator. Maps the h2 connection `Entity`
        /// (the `Session.entity` carried on every `ws_message_out` /
        /// `ws_send_in` entity) → that connection's worker-side state:
        /// the parked continuation entity holding its chain (in
        /// `parked_continuations`) plus the §4.5 input gate. The first
        /// inbound frame establishes the chain (resolve tenant + module,
        /// create the parked entity, insert here); subsequent frames look
        /// it up; client close / conn death tears it down + removes the
        /// entry. Keyed by `Entity` (index+generation), so a recycled
        /// conn handle never resolves a dead chain — `reg.isStale`
        /// distinguishes by generation. NOT a new collection: the chain
        /// lives in the existing `parked_continuations` (its membership
        /// IS the held lifecycle); this is only the conn→state index,
        /// the WS analog of `bound_fetch_entities`.
        ws_conns: std.AutoHashMapUnmanaged(rove.Entity, WsConnState) = .empty,
        /// Gap 2.4 (`docs/inbound-chunk-plan.md` S2): live inbound-chunk
        /// jobs, keyed by the request entity. One per body-carrying
        /// request whose module routes to `onChunk`. `dispatchOnce`
        /// stages the FIRST fire (the probe); `pumpInboundChunks` fires
        /// the rest off `parked_continuations` membership and janitors
        /// stale entries.
        inbound_chunk_jobs: std.AutoHashMapUnmanaged(rove.Entity, *inbound_chunk_mod.Job) = .empty,
        /// `docs/chunk-spool-plan.md` Phase 2: per-fetch chunk spool,
        /// keyed by `fetch_id`, sibling to `bound_fetch_entities`.
        /// Decouples bound-fetch chunk arrival from the held chain's
        /// raft commit cadence — arriving chunks push onto the spool;
        /// `worker_streaming.dispatchSpoolHead` / `drainSpools` pop
        /// the head once the held entity is back in a receivable
        /// collection. Heap-allocated `*ChunkSpool` for pointer
        /// stability across rehash. Keys are allocator-owned fetch_id
        /// dupes; freed on `dropSpool` + on shutdown (`destroy`).
        bound_fetch_spools: std.StringHashMapUnmanaged(*chunk_spool_mod.ChunkSpool) = .empty,
        /// `docs/chunk-spool-plan.md` P6: deferred coordinator releases
        /// for consumed/dropped bound chunks. The spool consumes
        /// in-window chunks from their inline bytes BEFORE their
        /// coordinator submit is durable (its ref isn't set yet), so a
        /// release-at-consume can't free them. Instead the (worker_id,
        /// seq) is queued here and `drainSpools` retries `coord.release`
        /// each tick until it succeeds (durableSeq advances). Leftovers
        /// at shutdown are dropped (lossy-on-shutdown, like the log
        /// flusher). Touched only by the worker thread.
        coord_pending_releases: std.ArrayListUnmanaged(CoordPendingRelease) = .empty,
        /// `docs/chunk-spool-plan.md` Phase 3: K, the per-fetch RAM
        /// window depth. Chunks within K of a spool's head keep their
        /// inline bytes; chunks pushed beyond K evict their inline
        /// bytes (read back from the coordinator at dispatch). Default
        /// `DEFAULT_BOUND_FETCH_SPOOL_DEPTH` (≈ K×64KB inline RAM per
        /// fetch); overridable via `ROVE_BOUND_FETCH_SPOOL_DEPTH`.
        bound_fetch_spool_depth: usize = DEFAULT_BOUND_FETCH_SPOOL_DEPTH,
        /// Peak `inlineBytes()` summed across all live spools observed
        /// on this worker. Diagnostic for the K-window RAM bound;
        /// exposed via `/_system/metrics` (`bound_fetch_spool_inline_bytes_peak`).
        /// Never reset (per the diagnostic-state-stays convention).
        bound_fetch_spool_inline_bytes_peak: usize = 0,
        /// Peak total queued entries summed across all live spools —
        /// how far the producer (upstream chunk arrival) ran ahead of
        /// the raft-rate consumer. A peak ≫ K is the decoupling
        /// evidence (`docs/chunk-spool-plan.md` Phase 5): chunks pile
        /// into the spool at upstream rate while activations drain at
        /// raft rate. Exposed as `bound_fetch_spool_depth_peak`.
        bound_fetch_spool_depth_peak: usize = 0,
        /// Count of spool-head chunks whose evicted inline bytes were
        /// read back from the coordinator (`coord.readBody`) at
        /// dispatch. Non-zero proves the Phase 3 eviction → coord
        /// read-back path actually ran (vs. the consumer keeping up so
        /// the window never overflowed). Exposed on `/_system/metrics`
        /// as `bound_fetch_spool_readback_total`. Never reset.
        bound_fetch_spool_readback_total: u64 = 0,
        /// Count of spooled-but-unconsumed chunks discarded by
        /// `dropSpool` when a bound fetch is cancelled
        /// (`http.cancelFetch`) or its held client disconnects
        /// (`scanAndCancelBoundFetches`) — `docs/chunk-spool-plan.md`
        /// Phase 4. Excludes the clean terminal drop (the spool is
        /// empty by then). Exposed as
        /// `bound_fetch_spool_dropped_total`. Never reset.
        bound_fetch_spool_dropped_total: u64 = 0,
        /// Count of per-request log records permanently dropped by
        /// `flushLogs` — the batch was drained from `log_buffer` before
        /// the S3 PUT, so a writeBatch failure or a lost-leadership
        /// mid-tick loses those records for good (lossy-on-failure by
        /// design — `docs/logs-plan.md` §1). Logged AND counted so the
        /// permanent data-loss volume is visible over time, not just a
        /// transient warn line. Exposed as `log_records_dropped_total`.
        /// Never reset.
        log_records_dropped_total: u64 = 0,
        /// `docs/cross-worker-held-state-plan.md` Phase 3: worker-
        /// local mirror of NodeState's `bound_send_owners`. Maps
        /// send_id → the parked cont entity bound to it.
        /// Populated alongside `bound_send_owners` (the
        /// cont_bound_sched_id scan sites in `worker_dispatch.zig`
        /// + `worker_drain.zig`); read in `resumeIfBoundTrampoline`
        /// + `resumeBoundContinuation` for O(1) lookup instead of
        /// scanning every entity in `parked_continuations`.
        ///
        /// Phase 2B routing guarantees: a chunk arriving here has
        /// `bound_send_owners[send_id] == this worker's idx`, so
        /// the entity IS in this worker's `parked_continuations`
        /// (modulo the brief window between unregister and entity
        /// destroy). Lookup miss falls back to the linear scan as
        /// a safety net — costs O(N parked) only on the rare
        /// stale-registry case.
        ///
        /// Keys allocator-owned; freed on remove + on shutdown.
        bound_send_entities: std.StringHashMapUnmanaged(rove.Entity) = .empty,
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
        raft: *Bridge,
        /// Per-tenant log state. NOT in NodeState because
        /// `RequestIdMinter` bakes the worker_id into the upper 16
        /// bits of every minted id — sharing the minter would alias
        /// ids across workers. Same lazy-open lifecycle as
        /// `tenant_files_map` but populated per-worker.
        tenant_logs: TenantMap(TenantLog),
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
        /// Per-instance × per-action token-bucket limits, resolved from
        /// the tenant's plan-tier caps (`rove-plan`; docs/architecture/control-plane.md).
        /// Customer-tenant traffic checks the `request`
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
        /// `docs/readset-replication-plan.md` Phase 5b — node data
        /// directory borrowed from `WorkerConfig.data_dir`. Used by
        /// the per-worker `last_uploaded_seq` checkpoint file at
        /// `{data_dir}/_meta/last_uploaded_seq_w{log_worker_id:0>4}.txt`.
        /// Null disables the checkpoint (test fixtures).
        data_dir: ?[]const u8,
        /// `docs/readset-replication-plan.md` Phase 5b — the highest
        /// raft seq this worker has covered with a successful
        /// `flushLogs`. Read at startup from the checkpoint file
        /// (0 if missing); advanced after each successful flush.
        last_uploaded_seq: u64 = 0,
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
        /// V2 Phase 4 — shared secret gating the `/_system/v2-*` tenant-
        /// move surface. See `WorkerConfig.move_secret`.
        move_secret: ?[]const u8,
        /// V2 Phase 7 — serve-or-forward. See `WorkerConfig.cluster_id` /
        /// `cp_urls`. cluster_id null or cp_urls empty → forwarding disabled.
        cluster_id: ?[]const u8,
        cp_urls: []const []const u8,
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
        // `worker.node.deploy.deployment_loader`.

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
                .forward_pending = try StreamColl.init(allocator),
                .compile_pending = try StreamColl.init(allocator),
                .parked_continuations = try StreamColl.init(allocator),
                .parked_units = try ParkedUnitColl.init(allocator),
                .blob_sessions = try BlobSessionColl.init(allocator),
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
                .bound_fetch_spool_depth = readBoundFetchSpoolDepth(),
                .tenant_logs = .empty,
                .log_buffer = log_mod.NodeLogBuffer.init(allocator),
                .penalty_box = penalty_mod.PenaltyBox.init(allocator, .{}),
                .limiter = limiter_mod.RateLimiter.init(allocator, config.rate_limit_caps),
                .commit_wait_timeout_ns = config.commit_wait_timeout_ns,
                .admin_origin = config.admin_origin,
                .admin_api_domain = config.admin_api_domain,
                .log_worker_id = config.log_worker_id orelse @intCast(config.raft.config.node_id),
                .data_dir = config.data_dir,
                .last_uploaded_seq = if (config.data_dir) |dd|
                    worker_upload_checkpoint.readCheckpoint(allocator, dd, config.log_worker_id orelse @intCast(config.raft.config.node_id))
                else
                    0,
                .compile_fn = config.compile_fn,
                .compile_ctx = config.compile_ctx,
                .log_batch_store = config.log_batch_store,
                .services_jwt_secret = config.services_jwt_secret,
                .move_secret = config.move_secret,
                .cluster_id = config.cluster_id,
                .cp_urls = config.cp_urls,
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
            errdefer self.forward_pending.deinit();
            errdefer self.compile_pending.deinit();
            errdefer self.parked_continuations.deinit();
            errdefer self.parked_units.deinit();
            errdefer self.blob_sessions.deinit();
            errdefer self.tenant_logs.clearAllEntries(allocator);
            errdefer self.wake_inbox.deinit();

            reg.registerCollection(&self.raft_pending_response);
            reg.registerCollection(&self.raft_pending_cont);
            reg.registerCollection(&self.raft_pending_stream);
            reg.registerCollection(&self.body_pending);
            reg.registerCollection(&self.forward_pending);
            reg.registerCollection(&self.compile_pending);
            reg.registerCollection(&self.parked_continuations);
            reg.registerCollection(&self.parked_units);
            reg.registerCollection(&self.blob_sessions);

            // Register the inbox with the node so apply.zig +
            // worker_dispatch.zig can broadcast kv-write events to
            // this worker's locally-held streams. Address is stable
            // (`self` is heap-allocated above).
            try config.node.router.registerWakeInbox(&self.wake_inbox);
            errdefer config.node.router.unregisterWakeInbox(&self.wake_inbox);

            // Effect-reification Phase 2E: register the unified Msg
            // inbox with the node so every cross-thread producer
            // (deployment-loader boot, cron sweeper, FetchPool
            // libcurl threads) hash-routes here via
            // `node.enqueueMsgForTenant`. The returned slot index is
            // this worker's partition key for the per-worker
            // partitioned sweeps (`sweepOwedRetries` — Phase 5 PR-3).
            self.msg_inbox_idx = try config.node.router.registerMsgInbox(&self.msg_inbox);
            errdefer config.node.router.unregisterMsgInbox(&self.msg_inbox);

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

            // docs/streaming-model.md §7: body flush is the process-
            // global BlobCoordinator's job (NodeState.blob_coordinator);
            // this per-worker flusher_thread runs only the log flush.
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
                // docs/streaming-model.md §7: body flush is now driven by
                // the process-global coordinator's own drainer + executor
                // threads — no per-tick call from the worker. The per-tick
                // log flush drains the local fast path's records and advances
                // `last_uploaded_seq`.
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
            // docs/streaming-model.md §7: the blob coordinator lives on
            // NodeState and shuts down there (not here).
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
            {
                var it = self.onheaders_cache.keyIterator();
                while (it.next()) |kp| allocator.free(kp.*);
                self.onheaders_cache.deinit(allocator);
            }
            {
                var it = self.onchunk_cache.keyIterator();
                while (it.next()) |kp| allocator.free(kp.*);
                self.onchunk_cache.deinit(allocator);
            }
            self.limiter.deinit();
            self.penalty_box.deinit();
            self.tenant_logs.deinit(allocator);
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
            self.node.router.unregisterWakeInbox(&self.wake_inbox);
            self.wake_inbox.deinit();
            // Effect-reification Phase 2E: one unified Msg inbox
            // replaces the pre-2E pair. Unregister BEFORE deinit so
            // no cross-thread producer (deployment-loader,
            // cron sweeper, FetchPool) can push after we start
            // freeing entries. `MsgInbox.deinit` walks the items
            // variant-aware via `freeOwnedMsg`.
            self.node.router.unregisterMsgInbox(&self.msg_inbox);
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
            // Free every fetch_id key in the bound-fetch registry.
            // Values are entity handles (POD), no per-value cleanup.
            // The registry never owns the underlying fetch in
            // FetchEngine — that's released through normal terminal
            // events or http.cancelFetch.
            {
                var it = self.bound_fetch_entities.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                self.bound_fetch_entities.deinit(allocator);
            }
            // websocket-plan §5 (piece D): the chain entities themselves
            // are reaped via `parked_continuations`/registry teardown on
            // shutdown; free each connection's gated-frame queue, then
            // the map's own storage.
            {
                var it = self.ws_conns.valueIterator();
                while (it.next()) |st| {
                    for (st.queue.items) |f| {
                        if (f.payload.len > 0) allocator.free(f.payload);
                    }
                    st.queue.deinit(allocator);
                }
                self.ws_conns.deinit(allocator);
            }
            // Gap 2.4: drop the worker's reference on every live
            // inbound-chunk job (h2's sink reference, if still held,
            // releases through h2's own teardown; the refcount frees
            // the job on the last drop).
            {
                var it = self.inbound_chunk_jobs.valueIterator();
                while (it.next()) |jp| {
                    jp.*.kill();
                    jp.*.unref();
                }
                self.inbound_chunk_jobs.deinit(allocator);
            }
            // `docs/chunk-spool-plan.md` Phase 2: free every spool +
            // its still-pending entries + the duped fetch_id key.
            // Best-effort drain at shutdown, same lossy posture as
            // `fetch_pending_durability` below.
            {
                var it = self.bound_fetch_spools.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.*.deinit(allocator);
                    allocator.destroy(entry.value_ptr.*);
                    allocator.free(entry.key_ptr.*);
                }
                self.bound_fetch_spools.deinit(allocator);
            }
            // P6: deferred coord releases — drop at shutdown (the coord
            // is torn down separately; lossy-on-shutdown is fine).
            self.coord_pending_releases.deinit(allocator);
            // Phase 3: same pattern for the bound_send_entities map.
            {
                var it = self.bound_send_entities.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                self.bound_send_entities.deinit(allocator);
            }
            self.parked_continuations.deinit();
            self.parked_units.deinit();
            self.blob_sessions.deinit();
            // Stop the background deploy thread before tearing down the
            // collections it can never touch (it only touches its own
            // queue/result map, but join here makes shutdown ordering
            // explicit). Any still-parked deploy entities ship nothing
            // — best-effort, same lossy-on-shutdown posture as the rest.
            if (self.deploy_thread) |dt| {
                dt.shutdown();
                dt.deinit();
                self.deploy_thread = null;
            }
            self.raft_pending_response.deinit();
            self.raft_pending_cont.deinit();
            self.raft_pending_stream.deinit();
            self.body_pending.deinit();
            self.forward_pending.deinit();
            self.compile_pending.deinit();
            // Slice 4-fetch-park: drop any still-parked fetch
            // chunks at shutdown (best-effort, same lossy posture
            // as the log flusher's final drain). Each entry owns
            // its UpstreamFetchEvent's bytes.
            for (self.fetch_pending_durability.items) |*pe|
                components_mod.UpstreamFetchEvent.deinitItem(&pe.event, allocator);
            self.fetch_pending_durability.deinit(allocator);
            self.dispatcher.deinit();
            if (self.log_push_curl) |easy| easy.deinit();
            // `manifest_easy` lives on NodeState — main.zig owns it.
            self.h2.destroy();
            allocator.destroy(self);
        }

        /// Start the background compile+stage thread that backs
        /// `/_system/deploy` (`docs/rewind-cli-plan.md` §4). Idempotent
        /// guard: a second call is a no-op. Opens the thread against the
        /// node's shared blob backend config so each job writes the
        /// target tenant's own `file-blobs/` + `deployments/` keys.
        /// Call once after `create`, before serving.
        pub fn startDeployThread(self: *Self) !void {
            if (self.deploy_thread != null) return;
            const dt = try deploy_thread_mod.DeployThread.init(
                self.allocator,
                self.node.blob_backend_cfg,
                &self.node.router,
            );
            errdefer dt.deinit();
            try dt.start();
            self.deploy_thread = dt;
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
        /// `Request.platform_caps` (the `deploy_starter` fn + shared
        /// `ctx`). The bundle lets globals.zig invoke this without
        /// depending on the generic `Worker(opts)` type — the caller
        /// passes the `*anyopaque` it received as `ctx`, we cast back
        /// to `*Self`, and run starter-deploy with envelope-0 propose
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
            const starter_dep_id = try starter.deployStarterContent(
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
            if (self.node.deploy.deployment_loader) |loader| {
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

            if (self.node.deploy.deployment_loader) |loader| {
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
            // this send-id?
            //
            // Phase 3: fast-path via the worker-local
            // `bound_send_entities` map. Phase 2B's owner routing
            // guarantees that if a parked cont exists anywhere, it
            // exists on the worker the chunk landed on — so the
            // map hit is the common case. Verify the entity is
            // still in `parked_continuations` (tenant + bsid both
            // checked indirectly: tenant matches because the
            // chunk hash-routes by tenant; bsid matches because
            // the map is keyed by send_id).
            //
            // Lookup-miss falls back to the linear scan as a
            // safety net for the registry-empty edge case (entry
            // was unregistered between the lookup and now, etc.).
            // Same `entitySlice` + column scan as pre-Phase-3.
            const server = self.h2;
            const map_hit = self.lookupBoundSendEntity(send_id);
            var matched = false;
            if (map_hit) |ent| {
                if (server.reg.isInCollection(ent, &self.parked_continuations)) {
                    // Verify the chain context matches the
                    // claimed tenant. (Defense in depth: a stale
                    // entry could conceivably point at a recycled
                    // entity from another tenant — gen check
                    // covers most of this; the tenant equality
                    // covers the residual.)
                    if (server.reg.get(ent, &self.parked_continuations, components_mod.ChainContext)) |chain| {
                        if (std.mem.eql(u8, chain.tenant_id, tenant_id)) {
                            matched = true;
                        }
                    } else |_| {}
                }
            }
            if (!matched) {
                const ents = self.parked_continuations.entitySlice();
                if (ents.len > 0) {
                    const descs = self.parked_continuations.column(components_mod.ContDescriptor);
                    const chains = self.parked_continuations.column(components_mod.ChainContext);
                    for (descs, chains) |desc, chain| {
                        const bsid = desc.bound_schedule_id orelse continue;
                        if (!std.mem.eql(u8, chain.tenant_id, tenant_id)) continue;
                        if (!std.mem.eql(u8, bsid, send_id)) continue;
                        matched = true;
                        break;
                    }
                }
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
            // `docs/chunk-spool-plan.md` Phase 4: a customer
            // `http.cancelFetch(id)` tears down the libcurl transfer
            // AND retires the held-state for the fetch — unregister the
            // bound-fetch registry entry (decrements fetchesPending,
            // drops the owner mirror) and drop any spooled-but-unconsumed
            // chunks. Both are idempotent + no-ops for an unbound fetch
            // (cancel works on unbound fetches too). `id` is the
            // customer-held fetch-id string, independent of either map
            // key, so ordering between the two is unconstrained.
            // dropSpool BEFORE unregister to mirror scanAndCancelBoundFetches.
            if (self.node.fetch_engine) |engine| engine.cancel(id);
            worker_streaming.dropSpool(self, id);
            self.unregisterBoundFetch(id);
        }

        /// §2.6 durable-wake: trampoline wired into
        /// `DispatchState.fire_wake`. The baked
        /// `__system/scheduler_tick`'s `__rove_fire_wake(...)` lands
        /// here once per due `_sched/by_time` entry; we hash-route a
        /// `durable_wake` activation to the entry's owning worker via
        /// the router. Returns false when no worker is registered (the
        /// builtin surfaces that as a thrown error so a fire is never
        /// silently dropped). All borrowed slices in `input` are dup'd
        /// by `enqueueDurableWakeForTenant`.
        pub fn fireWakeTrampoline(ctx: *anyopaque, input: globals.FireWakeInput) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.node.router.enqueueDurableWakeForTenant(input) catch |err| {
                std.log.warn(
                    "rove-js durable-wake: enqueueDurableWakeForTenant ({s} → {s}): {s}",
                    .{ input.tenant_id, input.target, @errorName(err) },
                );
                return false;
            };
            return true;
        }

        /// blob-storage-plan P2; `docs/architecture/routing-and-ingress.md`: blob upload-session
        /// trampolines, wired into `Request.trampolines` so the
        /// `_system.blob.write` / `.seal` bindings reach this
        /// worker's `blob_sessions` collection through the same
        /// type-erased seam as the other worker re-entries.
        pub fn blobWriteTrampoline(
            ctx: *anyopaque,
            tenant_id: []const u8,
            corr: []const u8,
            bytes: []const u8,
        ) blob_sessions_mod.Error!u64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return blob_sessions_mod.write(
                self.allocator,
                self.h2.reg,
                &self.blob_sessions,
                tenant_id,
                corr,
                bytes,
                @intCast(std.time.nanoTimestamp()),
            );
        }

        pub fn blobSealTrampoline(
            ctx: *anyopaque,
            tenant_id: []const u8,
            corr: []const u8,
        ) blob_sessions_mod.Error!blob_sessions_mod.Sealed {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return blob_sessions_mod.seal(
                self.allocator,
                self.h2.reg,
                &self.blob_sessions,
                tenant_id,
                corr,
            );
        }

        /// blob-storage-plan §3.5.1 slice B; `docs/architecture/routing-and-ingress.md`: arm a
        /// `blob.receive` at its commit point. The receive-door
        /// PendingFetch (intercepted before the FetchEngine by
        /// `interpretCmd`'s http_fetch arm and `finalizeBatch`'s
        /// read-only flush) names the activation entity in its URL;
        /// resolve the request's stream identity, attach the h2 body
        /// sink, and start the upload driver. Consumes `pf_in`.
        /// Every failure path still emits the `ok:false` terminal
        /// event (via the job thread) so the held chain resumes with
        /// a defined failure instead of hanging to its deadline.
        pub fn armBlobReceive(self: *Self, pf_in: globals.PendingFetch) void {
            var pf = pf_in;
            defer pf.deinit(self.allocator);

            const job = blob_receive_mod.Job.create(
                self.allocator,
                &self.node.router,
                &self.node.blob_backend_cfg,
                pf.tenant_id,
                pf.id,
                pf.name,
                null,
            ) catch {
                std.log.warn("rove-js blob.receive: job alloc failed tenant={s}", .{pf.tenant_id});
                return;
            };

            var attached = false;
            arm: {
                if (blob_receive_mod.active_jobs.load(.acquire) > blob_receive_mod.MAX_ACTIVE_JOBS) {
                    std.log.warn(
                        "rove-js blob.receive: active-job cap ({d}) reached; rejecting tenant={s}",
                        .{ blob_receive_mod.MAX_ACTIVE_JOBS, pf.tenant_id },
                    );
                    break :arm;
                }
                const ent = blob_receive_mod.entityFromReceiveUrl(pf.url) orelse break :arm;
                const ident = self.streamIdentity(ent) orelse break :arm;
                switch (self.h2.requestBodySink(ident.conn, ident.sid, job.sink())) {
                    .streaming, .eof => attached = true,
                    .gone => {},
                }
            }
            if (!attached) {
                // Stream gone / cap / bad identity: no h2 reference
                // was taken — drop it ourselves; the job thread sees
                // `aborted` and emits the failure terminal.
                job.markGone();
                job.releaseSinkRef();
            }
            job.start() catch {
                job.markGone();
                job.failNow();
            };
        }

        /// `platform.compile` submit door (`rove-cli-plan.md` §4.1). The
        /// shim issues an `on.fetch` to `rove-compile.internal`; the
        /// finalize seam binds it (connection_scoped + held); `interpretCmd`
        /// routes the URL here instead of libcurl. We parse `{scope, files}`
        /// from the fetch body, hand a `compile_batch` job to the
        /// DeployThread, and let it emit the terminal bound event that
        /// resumes the held chain. ADMIN-ONLY: only `__admin__` may compile
        /// (cross-tenant staging) — the issuing tenant is native-set on the
        /// PendingFetch, not forgeable by JS. On any rejection we route a
        /// failure event so the held chain resolves instead of hanging.
        pub fn submitCompile(self: *Self, pf_in: globals.PendingFetch) void {
            var pf = pf_in;
            defer pf.deinit(self.allocator);
            const a = self.allocator;
            const router = &self.node.router;

            const fail = struct {
                fn emit(rt: *MsgRouter, alloc: std.mem.Allocator, p: *const globals.PendingFetch, status: u16, msg: []const u8) void {
                    const cj = std.fmt.allocPrint(alloc, "{{\"ok\":false,\"status\":{d},\"error\":\"{s}\"}}", .{ status, msg }) catch return;
                    deploy_thread_mod.routeCompileEvent(rt, alloc, p.id, p.tenant_id, p.name, status, false, cj);
                }
            }.emit;

            if (!std.mem.eql(u8, pf.tenant_id, tenant_mod.ADMIN_INSTANCE_ID)) {
                std.log.warn("rove-js compile: non-admin tenant {s} attempted platform.compile; rejecting", .{pf.tenant_id});
                return fail(router, a, &pf, 403, "platform.compile is admin-only");
            }
            const dt = self.deploy_thread orelse return fail(router, a, &pf, 503, "deploy thread not started");

            var parsed = std.json.parseFromSlice(struct {
                scope: []const u8,
                files: []const struct { path: []const u8, source: []const u8 },
            }, a, pf.body, .{ .ignore_unknown_fields = true }) catch
                return fail(router, a, &pf, 400, "expected {scope, files:[{path,source}]}");
            defer parsed.deinit();
            const p = parsed.value;
            if (p.scope.len == 0) return fail(router, a, &pf, 400, "scope required");
            if (p.files.len == 0) return fail(router, a, &pf, 400, "at least one file required");
            if (p.files.len > 256) return fail(router, a, &pf, 400, "too many files (max 256)");

            // Build owned DeployInput[] (all handlers).
            const inputs = a.alloc(files_mod.DeployInput, p.files.len) catch
                return fail(router, a, &pf, 500, "out of memory");
            var built: usize = 0;
            const inputs_ok = blk: {
                for (p.files) |f| {
                    const path_owned = a.dupe(u8, f.path) catch break :blk false;
                    const src_owned = a.dupe(u8, f.source) catch {
                        a.free(path_owned);
                        break :blk false;
                    };
                    inputs[built] = .{ .path = path_owned, .kind = .handler, .content_type = "", .bytes = src_owned };
                    built += 1;
                }
                break :blk true;
            };
            const freeInputs = struct {
                fn f(alloc: std.mem.Allocator, ins: []files_mod.DeployInput, n: usize) void {
                    for (ins[0..n]) |*in| {
                        alloc.free(in.path);
                        alloc.free(in.bytes);
                    }
                    alloc.free(ins);
                }
            }.f;
            if (!inputs_ok) {
                freeInputs(a, inputs, built);
                return fail(router, a, &pf, 500, "out of memory");
            }

            // Owned routing fields (scope to stage into; chain tenant + fetch
            // id + resume export to route the completion back to the held
            // admin chain). On any dupe failure, free everything.
            const scope_owned = a.dupe(u8, p.scope) catch {
                freeInputs(a, inputs, built);
                return fail(router, a, &pf, 500, "out of memory");
            };
            const chain_owned = a.dupe(u8, pf.tenant_id) catch {
                a.free(scope_owned);
                freeInputs(a, inputs, built);
                return fail(router, a, &pf, 500, "out of memory");
            };
            const fid_owned = a.dupe(u8, pf.id) catch {
                a.free(scope_owned);
                a.free(chain_owned);
                freeInputs(a, inputs, built);
                return fail(router, a, &pf, 500, "out of memory");
            };
            const name_owned: []u8 = if (pf.name.len != 0) (a.dupe(u8, pf.name) catch {
                a.free(scope_owned);
                a.free(chain_owned);
                a.free(fid_owned);
                freeInputs(a, inputs, built);
                return fail(router, a, &pf, 500, "out of memory");
            }) else &.{};

            self.next_compile_id += 1;
            dt.enqueue(.{
                .compile_id = self.next_compile_id,
                .kind = .compile_batch,
                .tenant_id = scope_owned,
                .inputs = inputs,
                .chain_tenant = chain_owned,
                .fetch_id = fid_owned,
                .name = name_owned,
            }) catch {
                a.free(scope_owned);
                a.free(chain_owned);
                a.free(fid_owned);
                if (name_owned.len != 0) a.free(name_owned);
                freeInputs(a, inputs, built);
                return fail(router, a, &pf, 503, "deploy queue unavailable");
            };
        }

        /// Gap 2.4 (`docs/inbound-chunk-plan.md` S2): create the
        /// inbound-chunk job for a receiving request and attach it to
        /// the stream as the h2 body sink. Returns null (and leaves no
        /// references behind) if the stream is already gone. On
        /// success the job is registered in `inbound_chunk_jobs`
        /// (worker ref) and h2 holds the sink ref.
        pub fn armInboundChunkSink(
            self: *Self,
            ent: rove.Entity,
            conn_entity: rove.Entity,
            stream_id: u32,
            cap: u64,
        ) ?*inbound_chunk_mod.Job {
            const job = inbound_chunk_mod.Job.create(self.allocator, cap, REQUEST_BODY_CAP) catch return null;
            const s: h2.BodySink = .{
                .ctx = job,
                .push = &inbound_chunk_mod.Sink.push,
                .finish = &inbound_chunk_mod.Sink.finish,
                .abort = &inbound_chunk_mod.Sink.abort,
                .drained = &inbound_chunk_mod.Sink.drained,
                .release = &inbound_chunk_mod.Sink.release,
            };
            switch (self.h2.requestBodySink(conn_entity, stream_id, s)) {
                .streaming, .eof => {},
                .gone => {
                    // h2 took no reference; drop both.
                    job.unref();
                    job.unref();
                    return null;
                },
            }
            self.inbound_chunk_jobs.put(self.allocator, ent, job) catch {
                // Worker side failed; h2 still holds its ref. Dead
                // jobs drain so the closing stream can't wedge.
                job.kill();
                job.unref();
                return null;
            };
            return job;
        }

        /// Resolve a request entity's stream identity (its h2 Session
        /// conn entity + StreamId) wherever the entity currently is —
        /// `request_out` (read-only commit path), `raft_pending_cont`
        /// (write-path commit arm) or `parked_continuations` (safety).
        fn streamIdentity(self: *Self, ent: rove.Entity) ?struct { conn: rove.Entity, sid: u32 } {
            const server = self.h2;
            if (server.reg.isStale(ent)) return null;
            const colls = .{ &server.request_out, &self.raft_pending_cont, &self.parked_continuations };
            const sess = server.reg.getAny(ent, colls, h2.Session) catch return null;
            const sid = server.reg.getAny(ent, colls, h2.StreamId) catch return null;
            return .{ .conn = sess.entity, .sid = sid.id };
        }

        /// `docs/streaming-model.md` §7 item 1 + `docs/handler-shape.md`
        /// §5.5: bound-fetch registration. Called DIRECTLY at the
        /// handler-success seam (`worker_dispatch`, where `bind = held
        /// and !detach` is computed per docs/auto-bind-plan.md) — not
        /// via a Request/DispatchState fn-pointer field. We dupe
        /// `fetch_id` (the registry owns the key) and stamp the entity
        /// handle. Subsequent
        /// `dispatchPendingMsgs` `.fetch_chunk` arrivals look up
        /// `fetch_id` here to find the held entity.
        ///
        /// Returns false on allocator failure or if the fetch_id
        /// is already registered (a previous bind that wasn't
        /// drained — should be impossible in normal flow, log + drop).
        pub fn registerBoundFetchTrampoline(
            ctx: *anyopaque,
            fetch_id: []const u8,
            entity: rove.Entity,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const a = self.allocator;
            const gop = self.bound_fetch_entities.getOrPut(a, fetch_id) catch return false;
            if (gop.found_existing) {
                std.log.warn(
                    "rove-js bound-fetch: registry collision for fetch_id={s}; dropping new bind",
                    .{fetch_id},
                );
                return false;
            }
            const key_dup = a.dupe(u8, fetch_id) catch {
                _ = self.bound_fetch_entities.remove(fetch_id);
                return false;
            };
            gop.key_ptr.* = key_dup;
            gop.value_ptr.* = entity;
            // `docs/cross-worker-held-state-plan.md` Phase 1: mirror
            // the registration onto the NodeState owner map so a
            // future chunk arriving on a different worker can find
            // the owner. Failures here are non-fatal — Phase 2's
            // routing falls back to hash(tenant_id) when the
            // registry misses, which is the same behavior as today.
            _ = self.node.router.registerBoundFetchOwner(fetch_id, self.msg_inbox_idx);
            // Increment the per-chain bound-fetch counter. The
            // entity is in request_out at this point; the merged
            // Row includes BoundFetchCount so the component is
            // accessible. Surfaces as request.fetchesPending on
            // every subsequent onFetchChunk activation. Survives
            // entity moves (rove principle 8).
            if (self.h2.reg.get(entity, &self.h2.request_out, components_mod.BoundFetchCount)) |cnt| {
                cnt.pending +%= 1;
            } else |_| {
                // Entity not in request_out — set fails. This is
                // a soft failure: the count stays at 0 and the
                // customer's fetchesPending reads as 0. Functional
                // gap (the count is wrong) but the chain still
                // works.
            }
            return true;
        }

        /// Lookup a bound fetch's held entity. Returns `null` if
        /// the fetch isn't registered as bound (the chunk should
        /// fall through to `fireFetchEventActivation`'s separate-chain
        /// path) — robust against late-arriving chunks for a chain
        /// whose terminal already drained the registry.
        pub fn lookupBoundFetch(self: *Self, fetch_id: []const u8) ?rove.Entity {
            return self.bound_fetch_entities.get(fetch_id);
        }

        /// Unregister + free the registry key. Idempotent — a no-op
        /// when the id isn't present (the cleanup path runs on every
        /// terminal chunk; double-fire is benign).
        pub fn unregisterBoundFetch(self: *Self, fetch_id: []const u8) void {
            const entry = self.bound_fetch_entities.fetchRemove(fetch_id) orelse return;
            const entity = entry.value;
            self.allocator.free(entry.key);
            // Mirror the NodeState owner-map drop. Same Phase 1
            // pairing as the registration site above.
            self.node.router.unregisterBoundFetchOwner(fetch_id);
            // Decrement the per-chain pending count. Naturally
            // saturates at 0 (defensive — register/unregister
            // pairs balance in normal flow). Surfaces as
            // request.fetchesPending on subsequent activations.
            self.decrementBoundFetchCount(entity);
        }

        /// Walk every collection that can host a held chain to
        /// find this entity's BoundFetchCount component and
        /// decrement it. The entity flows
        /// request_out → parked_continuations → raft_pending_*
        /// → stream_response_in → stream_data_out → response_in
        /// → response_out across its lifecycle; the merged
        /// StreamRow carries BoundFetchCount on every one of them.
        fn decrementBoundFetchCount(self: *Self, entity: rove.Entity) void {
            const server = self.h2;
            if (server.reg.getAny(entity, .{
                &server.request_out,
                &self.parked_continuations,
                &self.raft_pending_cont,
                &self.raft_pending_stream,
                &self.raft_pending_response,
                &server.stream_response_in,
                &server.stream_data_out,
                &server.response_in,
                &server.response_out,
            }, components_mod.BoundFetchCount)) |cnt| {
                if (cnt.pending > 0) cnt.pending -= 1;
            } else |_| {}
        }

        /// Phase 3: register a `send_id → entity` mapping on this
        /// worker. Paired with `NodeState.registerBoundSendOwner`
        /// — every site that stamps the owner map also stamps
        /// this. Collision (same send_id, already present) logs +
        /// drops (send_ids are supposed to be unique within a
        /// chain). Caller's slice is duped; the registry owns the
        /// key.
        pub fn registerBoundSendEntity(self: *Self, send_id: []const u8, entity: rove.Entity) void {
            const gop = self.bound_send_entities.getOrPut(self.allocator, send_id) catch return;
            if (gop.found_existing) {
                std.log.warn(
                    "rove-js bound-send: registry collision for send_id={s}; dropping new bind",
                    .{send_id},
                );
                return;
            }
            const key_dup = self.allocator.dupe(u8, send_id) catch {
                _ = self.bound_send_entities.remove(send_id);
                return;
            };
            gop.key_ptr.* = key_dup;
            gop.value_ptr.* = entity;
        }

        /// Phase 3: O(1) lookup. Replaces the linear scan in
        /// `resumeIfBoundTrampoline` / `resumeBoundContinuation`.
        /// Returns null on miss → caller falls back to the scan
        /// (stale-registry safety net).
        pub fn lookupBoundSendEntity(self: *Self, send_id: []const u8) ?rove.Entity {
            return self.bound_send_entities.get(send_id);
        }

        /// Phase 3: remove + free the registry key. Idempotent.
        /// Paired with `NodeState.unregisterBoundSendOwner` —
        /// fires alongside the bsid free sites in
        /// `worker_drain.zig`'s repark + stream-transition arms.
        pub fn unregisterBoundSendEntity(self: *Self, send_id: []const u8) void {
            const entry = self.bound_send_entities.fetchRemove(send_id) orelse return;
            self.allocator.free(entry.key);
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

/// Lookup-or-lazy-open the process-shared TenantSlot for `inst`.
/// Wraps `worker.node.deploy.getOrOpenTenantSlot` for callers that only
/// hold a worker pointer.
pub fn getOrOpenTenantSlot(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantSlot {
    return worker.node.deploy.getOrOpenTenantSlot(inst);
}

// ── Per-tenant log loading ────────────────────────────────────────────
//
// Moved to `worker_log.zig`. Re-exported here so external callers
// (root.zig's `pub const flushLogs = worker.flushLogs;`,
// worker_dispatch.zig's `worker_mod.captureLog*` / `captureTapes*`)
// keep working without touching their import lines. Internal callers
// in this file use `worker_log.X` directly.
pub const REQUEST_BODY_CAP = worker_log.REQUEST_BODY_CAP;
pub const getOrOpenTenantLog = worker_log.getOrOpenTenantLog;
pub const captureTapes = worker_log.captureTapes;
pub const captureTapesWithActivation = worker_log.captureTapesWithActivation;
pub const captureLog = worker_log.captureLog;
pub const captureLogWithId = worker_log.captureLogWithId;
pub const flushLogs = worker_log.flushLogs;

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
pub const drainForwardPending = worker_drain.drainForwardPending;
pub const drainBodyPending = worker_drain.drainBodyPending;
pub const drainFetchPendingDurability = worker_drain.drainFetchPendingDurability;
pub const drainCompilePending = worker_drain.drainCompilePending;
pub const resolveDeployment = worker_drain.resolveDeployment;
pub const resumeBoundContinuation = worker_drain.resumeBoundContinuation;
pub const drainPendingBoundResumes = worker_drain.drainPendingBoundResumes;
pub const sweepParkedContinuations = worker_drain.sweepParkedContinuations;
pub const pumpInboundChunks = worker_drain.pumpInboundChunks;
pub const releaseInboundChunkParks = worker_drain.releaseInboundChunkParks;
pub const parkKvWakes = worker_drain.parkKvWakes;
pub const drainOnLeadershipLoss = worker_drain.drainOnLeadershipLoss;
pub const cleanupResponses = worker_drain.cleanupResponses;
pub const scanAndCancelBoundFetches = worker_drain.scanAndCancelBoundFetches;

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
pub const serviceWsMessages = worker_ws.serviceWsMessages;
pub const fireSubscriptionActivation = worker_streaming.fireSubscriptionActivation;
pub const proposeForgetfulWrites = worker_streaming.proposeForgetfulWrites;
pub const serviceSubscriptionFires = worker_streaming.serviceSubscriptionFires;
pub const dispatchPendingMsgs = worker_streaming.dispatchPendingMsgs;
pub const drainSpools = worker_streaming.drainSpools;
pub const dispatchSubscriptionFires = worker_streaming.dispatchSubscriptionFires;
pub const dispatchFetchEvents = worker_streaming.dispatchFetchEvents;
pub const serviceFetchEvents = worker_streaming.serviceFetchEvents;
pub const fireFetchEventActivation = worker_streaming.fireFetchEventActivation;

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
        if (tc.snap.bytecodes.get(mjs_key)) |bb| return bb.bytes;
        if (tc.snap.bytecodes.get(js_key)) |bb| return bb.bytes;

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
    try std.testing.expectEqualStrings("", deployment_cache.triggerPathToPrefix("_triggers/index.mjs").?);
    try std.testing.expectEqualStrings("", deployment_cache.triggerPathToPrefix("_triggers/index.js").?);
}

test "triggerPathToPrefix: single segment" {
    try std.testing.expectEqualStrings("users/", deployment_cache.triggerPathToPrefix("_triggers/users/index.mjs").?);
    try std.testing.expectEqualStrings("users/", deployment_cache.triggerPathToPrefix("_triggers/users/index.js").?);
}

test "triggerPathToPrefix: nested segments" {
    try std.testing.expectEqualStrings("users/sessions/", deployment_cache.triggerPathToPrefix("_triggers/users/sessions/index.mjs").?);
    try std.testing.expectEqualStrings("a/b/c/d/", deployment_cache.triggerPathToPrefix("_triggers/a/b/c/d/index.mjs").?);
}

test "triggerPathToPrefix: non-trigger paths return null" {
    // Not under _triggers/.
    try std.testing.expectEqual(@as(?[]const u8, null), deployment_cache.triggerPathToPrefix("index.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), deployment_cache.triggerPathToPrefix("users/index.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), deployment_cache.triggerPathToPrefix("_static/index.html"));
    // Under _triggers/ but not an index file (helper module imported by a trigger).
    try std.testing.expectEqual(@as(?[]const u8, null), deployment_cache.triggerPathToPrefix("_triggers/users/lib.mjs"));
    try std.testing.expectEqual(@as(?[]const u8, null), deployment_cache.triggerPathToPrefix("_triggers/users/sessions/util.mjs"));
    // Wrong extension.
    try std.testing.expectEqual(@as(?[]const u8, null), deployment_cache.triggerPathToPrefix("_triggers/users/index.ts"));
}

// `isReservedTriggerPrefix` tests live alongside the helper in reserved.zig.

pub const ADMIN_SESSION_COOKIE = auth.ADMIN_SESSION_COOKIE;

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
        12345,
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
    // Phase 5b: raft_seq round-trips through the buffer.
    try testing.expectEqual(@as(u64, 12345), buffered.raft_seq);
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
        0,
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
