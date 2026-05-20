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
const tenant_mod = @import("rove-tenant");

const dispatcher_mod = @import("dispatcher.zig");
const continuation_mod = @import("bindings/continuation.zig");
const Continuation = continuation_mod.Continuation;
const stream_mod = @import("bindings/stream.zig");
const components_mod = @import("components.zig");
const globals = @import("globals.zig");
const apply_mod = @import("apply.zig");
const raft_propose = @import("raft_propose.zig");
const config_mirror = @import("config_mirror.zig");
const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const dispatch = @import("worker_dispatch.zig");
const panic_mod = @import("panic.zig");
const penalty_mod = @import("penalty.zig");
const limiter_mod = @import("limiter.zig");
const router_mod = @import("router.zig");
const reserved = @import("reserved.zig");
const deployment_loader_mod = @import("deployment_loader.zig");
const send_dispatch_mod = @import("send_dispatch.zig");
const send_outbox_mod = @import("send_outbox.zig");
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

/// A non-entity post-propose parked unit (divergence workstream,
/// `docs/unified-effect-gating.md` idiom-1). The H2 path parks ECS
/// entities in `raft_pending`; the non-H2 `tenant_batch` paths have
/// no entity, so they register one of these instead of releasing
/// their SSE emits at *accept*. `drainRaftPending` releases the
/// buffered emits at commit (`committedSeq >= seq`) and discards
/// them on fault/timeout/leadership-loss (the effect never escaped).
/// Purely additive — the H2 entity path is untouched.
pub const ParkedUnit = struct {
    seq: u64,
    deadline_ns: i64,
    /// Owned copy — must outlive the proposing dispatch across ticks.
    tenant_id: []u8,
    /// Option (b) 4b-ii-B: owned commit-gated send arm/resolve intents
    /// (`_send/owed/` put → arm, `_send/proof/` put / `_send/owed/`
    /// delete → resolve). Fired into the leader-local SendDispatch on
    /// commit (`firePendingSendOps`), discarded with the rest of the
    /// unit on fault/timeout/leadership-loss — the durable per-tenant
    /// `_send/owed/` + new-leader boot-scan covers a discard, so no
    /// silent loss.
    send_ops: std.ArrayListUnmanaged(send_dispatch_mod.OwnedIntent) = .empty,
    /// Streaming-handlers-plan §4.6: commit-gated kv-wake intents.
    /// Captured from the batch's writeset at propose time;
    /// `drainRaftPending` calls `node.broadcastKvWake` for each
    /// once `committedSeq >= seq` so the wakes fire AFTER the
    /// writes are durably visible to local readers (the kv.get
    /// on the wake-driven handler then returns the new state, not
    /// stale pre-write state). Discarded on fault/timeout — same
    /// posture as `send_ops`: no silent loss because the writes
    /// also didn't escape, and the §9.4 "spurious + overflow"
    /// thesis tolerates dropped wakes.
    kv_wakes: std.ArrayListUnmanaged(KvWakeOp) = .empty,
    /// Phase 4c: entity-less commit-gated `TrackedTxn` pointer
    /// when this unit represents a "forgetful writes" propose —
    /// the §4.4 disconnect activation's kv side effects. No entity
    /// in `raft_pending` waits on this seq, so the entity-loop in
    /// `drainRaftPending` would never commit it; the pending_units
    /// sweep does instead. On commit: `tracked.commit() + destroy`;
    /// on fault: `tracked.rollback() + destroy`. Null on the
    /// historical entity-backed units (`parkSendOps` from the
    /// inbound dispatch path) — the entity loop already owns those.
    txn: ?*kv_mod.KvStore.TrackedTxn = null,

    pub fn deinit(self: *ParkedUnit, allocator: std.mem.Allocator) void {
        for (self.send_ops.items) |*o| o.deinit(allocator);
        self.send_ops.deinit(allocator);
        for (self.kv_wakes.items) |*w| w.deinit(allocator);
        self.kv_wakes.deinit(allocator);
        // Phase 4c: if a forgetful-writes txn is still attached
        // (drained without commit / fault, e.g. on shutdown),
        // rollback + destroy. The pending_units sweep clears this
        // pointer when it commits or rolls back.
        if (self.txn) |t| {
            t.rollback() catch {};
            allocator.destroy(t);
            self.txn = null;
        }
        allocator.free(self.tenant_id);
    }
};

/// Owned (key, op) pair captured from a write batch's writeset at
/// propose time. Survives until `drainRaftPending` fires the wake
/// (`node.broadcastKvWake`) or the unit is discarded on
/// fault/timeout/leadership-loss.
pub const KvWakeOp = struct {
    key: []u8,
    op: u8,

    pub fn deinit(self: *KvWakeOp, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
    }
};

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

// Phase 7: `PendingKvWake` (worker.zig copy) removed — the one
// in components.zig (referenced by `StreamWakes.pending_wake`) is
// authoritative now.
pub const PendingKvWake = components_mod.PendingKvWake;

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
        return openTenantLog(worker, inst, worker.log_worker_id);
    }

    pub fn free(allocator: std.mem.Allocator, tl: *TenantLog) void {
        freeTenantLog(allocator, tl);
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
    /// `startSendDispatch`; null until then and after `deinit`.
    send_dispatch: ?*send_dispatch_mod.SendDispatch = null,

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

    pub fn init(
        allocator: std.mem.Allocator,
        tenant: *tenant_mod.Tenant,
        blob_backend_cfg: blob_mod.BackendConfig,
        raft: *kv_mod.RaftNode,
    ) NodeState {
        return .{
            .allocator = allocator,
            .tenant = tenant,
            .blob_backend_cfg = blob_backend_cfg,
            .raft = raft,
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
        // Drop the inbox registry first — workers destroy their
        // inboxes in their own deinit, so by the time NodeState
        // tears down, every inbox should already be unregistered.
        // The list itself is owned by NodeState's allocator.
        self.wake_inboxes.deinit(self.allocator);
        if (self.deployment_loader) |l| {
            l.shutdown();
            l.deinit();
            self.deployment_loader = null;
        }
        if (self.send_dispatch) |sd| {
            sd.shutdown();
            sd.deinit();
            self.send_dispatch = null;
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

    /// Spawn the single leader-local send-dispatch thread. Idempotent.
    /// Called once from `main.zig` after NodeState is wired, alongside
    /// `startDeploymentLoader`. The dedicated thread drains arm/resolve
    /// ops into the in-flight set (4b); leader-gating + boot-scan
    /// (4b-iii) and firing (4c) land on top. Inert until then.
    pub fn startSendDispatch(self: *NodeState) !void {
        if (self.send_dispatch != null) return;
        const sd = try send_dispatch_mod.SendDispatch.init(self.allocator);
        errdefer sd.deinit();
        // FORK-6 leader gating + promotion boot-scan (4b-iii-B).
        // Still inert: the set is fed (4b-ii) + reconstructed on
        // promotion, dropped on demotion — but nothing fires until
        // 4c flips the guard.
        const self_ctx = @as(?*anyopaque, @ptrCast(self));
        sd.configure(self_ctx, sendDispatchIsLeaderNode, self_ctx, sendDispatchRecoverFnNode);
        try sd.start();
        self.send_dispatch = sd;
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
/// `SendDispatch.LeaderFn` thunk — casts ctx back to `*NodeState`
/// and reports raft leadership. The leader-local in-flight set is
/// gated on this (FORK-6): promotion → boot-scan (4b-iii-B),
/// demotion → drop.
fn sendDispatchIsLeaderNode(ctx_opaque: ?*anyopaque) bool {
    const node: *NodeState = @ptrCast(@alignCast(ctx_opaque.?));
    return node.raft.isLeader();
}

/// Cap on the promotion boot-scan's instance enumeration. Far above
/// the ~50k/node architectural ceiling (3(b) / Manifest.max_stores);
/// `listInstances` allocs proportional to the actual count, not this.
/// Hitting it is the same escalation trigger as the 3(b) mitigation
/// ([[project_owed_recovery_strategy]]).
const RECOVER_MAX_TENANTS: u32 = 1 << 20;
/// Per-tenant `_send/owed/` scan page. Owed-per-tenant is normally ~0
/// (sends resolve fast); pagination rarely loops.
const RECOVER_PAGE: u32 = 1024;

/// `SendDispatch.RecoverFn` thunk (Option (b) 4b-iii-B). On raft
/// promotion, reconstruct the leader-local in-flight set from the
/// durable per-tenant `_send/owed/` (3(b) boot-scan): enumerate every
/// instance from the durable root store, scan each tenant app.db's
/// `_send/owed/`, skip ids that already have a `_send/proof/`
/// (proven done), arm the rest. Runs ON the dispatch thread (sole
/// owner of `sd.set`) — armFromParts dedups vs concurrent live-feed
/// ops the same iteration's later `drainAll` applies. Best-effort:
/// any failure drops just that send/tenant (logged); the live feed +
/// the next promotion still cover it — no silent loss for the set.
fn sendDispatchRecoverFnNode(ctx_opaque: ?*anyopaque, sd: *send_dispatch_mod.SendDispatch) void {
    const node: *NodeState = @ptrCast(@alignCast(ctx_opaque.?));
    const a = node.allocator;
    var list = node.tenant.listInstances(RECOVER_MAX_TENANTS) catch |err| {
        std.log.warn("send-dispatch recover: listInstances failed: {s} " ++
            "(no reconstruct; live feed + next promotion cover)", .{@errorName(err)});
        return;
    };
    defer list.deinit();
    if (list.ids.len == RECOVER_MAX_TENANTS) std.log.warn(
        "send-dispatch recover: hit RECOVER_MAX_TENANTS ({d}); some tenants " ++
            "unscanned — escalate per 3(b) mitigation",
        .{RECOVER_MAX_TENANTS},
    );

    var scanned: usize = 0;
    var armed: usize = 0;
    for (list.ids) |id| {
        const inst = (node.tenant.getInstance(id) catch continue) orelse continue;
        const slot = node.getOrOpenTenantSlot(inst) catch |err| {
            std.log.warn("send-dispatch recover: slot {s}: {s}", .{ id, @errorName(err) });
            continue;
        };
        scanned += 1;
        var cursor_buf: [send_outbox_mod.KEY_BUF]u8 = undefined;
        var cursor: []const u8 = "";
        while (true) {
            var rr = slot.app_kv.prefix(send_outbox_mod.OWED_PREFIX, cursor, RECOVER_PAGE) catch |err| {
                std.log.warn("send-dispatch recover: scan {s}: {s}", .{ id, @errorName(err) });
                break;
            };
            const n = rr.entries.len;
            for (rr.entries) |e| {
                if (e.key.len <= send_outbox_mod.OWED_PREFIX.len) continue;
                const sid = e.key[send_outbox_mod.OWED_PREFIX.len..];
                var pkbuf: [send_outbox_mod.KEY_BUF]u8 = undefined;
                const pk = send_outbox_mod.proofKey(&pkbuf, sid);
                if (slot.app_kv.get(pk)) |pv| {
                    a.free(pv);
                    continue; // proven done — not owed
                } else |gerr| switch (gerr) {
                    error.NotFound => {},
                    else => {
                        std.log.warn("send-dispatch recover: proof {s}: {s}", .{ sid, @errorName(gerr) });
                        continue;
                    },
                }
                sd.armFromParts(sid, slot.instance_id, e.value);
                armed += 1;
            }
            if (n < RECOVER_PAGE) {
                rr.deinit();
                break;
            }
            // start-after cursor past the last key (collectPrefix is
            // exclusive of `cursor`). Owed key ≤ 11+256 ≤ KEY_BUF.
            const last = rr.entries[n - 1].key;
            const clen = @min(last.len, cursor_buf.len);
            @memcpy(cursor_buf[0..clen], last[0..clen]);
            cursor = cursor_buf[0..clen];
            rr.deinit();
        }
    }
    std.log.info("send-dispatch recover: armed {d} owed across {d} tenants", .{ armed, scanned });
}

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
        // owned slices are freed there too. drainStreamPending just
        // moves the entity to stream_response_in on commit; no
        // side-table consume.
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
        pending_txns: std.AutoHashMapUnmanaged(u64, *kv_mod.KvStore.TrackedTxn) = .empty,
        /// Non-entity post-propose parked units (divergence
        /// workstream idiom-1). Serviced by `drainRaftPending`
        /// alongside (but independently of) the H2 `raft_pending`
        /// entity path. Single-threaded per worker.
        pending_units: std.ArrayListUnmanaged(ParkedUnit) = .empty,
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
                .parked_continuations = try StreamColl.init(allocator),
                .dispatcher = try Dispatcher.init(allocator),
                .node = config.node,
                .raft = config.raft,
                .tenant_logs = .empty,
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
            errdefer self.parked_continuations.deinit();
            errdefer self.tenant_logs.clearAllEntries(allocator);
            errdefer self.wake_inbox.deinit();

            reg.registerCollection(&self.raft_pending_response);
            reg.registerCollection(&self.raft_pending_cont);
            reg.registerCollection(&self.raft_pending_stream);
            reg.registerCollection(&self.parked_continuations);

            // Register the inbox with the node so apply.zig +
            // worker_dispatch.zig can broadcast kv-write events to
            // this worker's locally-held streams. Address is stable
            // (`self` is heap-allocated above).
            try config.node.registerWakeInbox(&self.wake_inbox);
            errdefer config.node.unregisterWakeInbox(&self.wake_inbox);

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
                self.push_thread = try std.Thread.spawn(.{}, pushLoop, .{self});
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
                _ = flushLogs(self) catch |err| {
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
            self.log_buffer.deinit();
            // Roll back any leftover pending txns. Should be empty
            // under normal shutdown; non-empty means we're exiting
            // with proposals still in-flight (process kill, fatal
            // error, etc.) — best-effort cleanup.
            var ptn_it = self.pending_txns.iterator();
            while (ptn_it.next()) |entry| {
                entry.value_ptr.*.rollback() catch |err| std.log.warn(
                    "worker.destroy: pending_txn rollback: {s}",
                    .{@errorName(err)},
                );
                allocator.destroy(entry.value_ptr.*);
            }
            self.pending_txns.deinit(allocator);
            for (self.pending_units.items) |*pu| pu.deinit(allocator);
            self.pending_units.deinit(allocator);
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
            self.parked_continuations.deinit();
            self.raft_pending_response.deinit();
            self.raft_pending_cont.deinit();
            self.raft_pending_stream.deinit();
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
// Mirrors the TenantFiles helpers above. Each tenant gets a
// per-tenant `RequestIdMinter` whose chunked-reservation counter
// persists into the tenant's app.db at `_log/next_request_seq`.
// Opened eagerly during `Worker.create`; freed during
// `Worker.destroy`.

fn openTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
    worker_id: u16,
) !*TenantLog {
    const allocator = worker.allocator;

    const id_copy = try allocator.dupe(u8, inst.id);
    errdefer allocator.free(id_copy);

    const tl = try allocator.create(TenantLog);
    errdefer allocator.destroy(tl);
    tl.* = .{
        .allocator = allocator,
        .instance_id = id_copy,
        .id_minter = undefined,
    };
    tl.id_minter = try log_mod.RequestIdMinter.init(
        allocator,
        worker_id,
        .{
            .seq_kv = inst.kv,
            .seq_key = "_log/next_request_seq",
        },
    );
    return tl;
}

fn freeTenantLog(allocator: std.mem.Allocator, tl: *TenantLog) void {
    tl.id_minter.deinit();
    allocator.free(tl.instance_id);
    allocator.destroy(tl);
}

/// Mirror of `getOrOpenTenantFiles` for the log store. Lazy-opens a
/// TenantLog for instances created at runtime so pre-minted
/// request_ids and webhook rows get matching log records.
pub fn getOrOpenTenantLog(
    worker: anytype,
    inst: *const tenant_mod.Instance,
) !*TenantLog {
    return worker.tenant_logs.getOrOpen(worker, inst);
}

/// Append a log record for a request that has finished its dispatch
/// pass. Best-effort: any internal failure is logged to stderr and
/// dropped (no propagation back to the caller — the request itself
/// must not fail because logging failed). Caller passes:
///
/// - `instance_id`: tenant id (must already exist in tenant_logs).
/// - `received_ns`: wall-clock when the worker first saw the request.
/// - `console` / `exception`: ownership is TRANSFERRED. The function
///   takes them and stores them on the LogRecord. Caller must not
///   free them after a successful return.
///
/// On any error path inside captureLog, the transferred buffers ARE
/// freed by this function so the caller doesn't have to do anything
/// special. (Caller can pass `&.{}` for a borrowed empty slice safely.)
/// Holder for the four per-request tapes the dispatcher captures. All
/// fields are owned; `deinit` frees every entry's backing storage. The
/// worker allocates a `RequestTapes` per dispatch, passes its tape
/// pointers to the dispatcher via the `Request`, then serializes +
/// uploads each non-empty tape after `run` returns.
pub const RequestTapes = struct {
    kv: tape_mod.Tape,
    date: tape_mod.Tape,
    math_random: tape_mod.Tape,
    crypto_random: tape_mod.Tape,
    module: tape_mod.Tape,

    pub fn init(allocator: std.mem.Allocator) RequestTapes {
        return .{
            .kv = tape_mod.Tape.init(allocator, .kv),
            .date = tape_mod.Tape.init(allocator, .date),
            .math_random = tape_mod.Tape.init(allocator, .math_random),
            .crypto_random = tape_mod.Tape.init(allocator, .crypto_random),
            .module = tape_mod.Tape.init(allocator, .module),
        };
    }

    pub fn deinit(self: *RequestTapes) void {
        self.kv.deinit();
        self.date.deinit();
        self.math_random.deinit();
        self.crypto_random.deinit();
        self.module.deinit();
    }
};

/// Maximum captured body length (request OR response). Anything
/// bigger gets truncated to this prefix and the corresponding
/// `*_truncated` flag set on the log record's tape payloads. Mirrors
/// PLAN §2.4's body-cap default.
pub const REQUEST_BODY_CAP: usize = 256 * 1024;

/// Serialize each non-empty tape into the request's `TapePayloads`,
/// owned by the caller's allocator. The bytes ride inline in the
/// next ndjson flush — no per-request S3 PUT, no separate blob
/// store.
///
/// Best-effort: on any serialize failure the channel is left empty
/// and a warning is logged. Tape capture failures must never kill
/// the request.
///
/// Pre-Phase-5.5(a-2) this function ('uploadTapes') issued one
/// content-addressed S3 PUT per channel per request through a
/// shared std.http.Client. The fanout — plus a stdlib keep-alive
/// bug that drops the OVH connection under concurrency — capped
/// tape capture at single-digit-thousand req/s. Inlining moves
/// the bytes onto the per-flush PUT path, which carries the whole
/// batch in a single request.
pub fn captureTapes(
    worker: anytype,
    tapes: *RequestTapes,
    request_body: []const u8,
) log_mod.TapePayloads {
    const allocator = worker.allocator;

    var payloads: log_mod.TapePayloads = .{};

    const channels = [_]struct {
        tape: *tape_mod.Tape,
        out: *[]const u8,
    }{
        .{ .tape = &tapes.kv, .out = &payloads.kv_tape_bytes },
        .{ .tape = &tapes.date, .out = &payloads.date_tape_bytes },
        .{ .tape = &tapes.math_random, .out = &payloads.math_random_tape_bytes },
        .{ .tape = &tapes.crypto_random, .out = &payloads.crypto_random_tape_bytes },
        .{ .tape = &tapes.module, .out = &payloads.module_tree_bytes },
    };

    for (channels) |ch| {
        if (ch.tape.entries.items.len == 0) continue;
        const bytes = ch.tape.serialize(allocator) catch |err| {
            std.log.warn("rove-js tape serialize failed: {s}", .{@errorName(err)});
            continue;
        };
        ch.out.* = bytes;
    }

    // Request body — captured into the log record so the replay
    // shell's `request.body` is non-empty for POST / PUT requests.
    // Bodies bigger than `REQUEST_BODY_CAP` get truncated to that
    // prefix; the truncation flag is preserved so the simulator (and
    // the replay shell) know the captured bytes are a prefix.
    //
    // Response body is intentionally NOT captured: deterministic
    // replay re-produces the response by re-running the handler with
    // the same request body + tapes, so storing the original would
    // be pure duplication on every S3 batch PUT.
    if (request_body.len > 0) {
        const captured_len = @min(request_body.len, REQUEST_BODY_CAP);
        if (allocator.dupe(u8, request_body[0..captured_len])) |captured| {
            payloads.request_body_bytes = captured;
            payloads.request_body_truncated = captured_len < request_body.len;
        } else |err| {
            std.log.warn("rove-js request-body capture failed: {s}", .{@errorName(err)});
        }
    }

    return payloads;
}

pub fn captureLog(
    worker: anytype,
    instance_id: []const u8,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
    correlation_id: ?[]const u8,
    activation: log_mod.ActivationSource,
) void {
    captureLogWithId(
        worker,
        instance_id,
        null,
        method,
        path,
        host,
        deployment_id,
        received_ns,
        status,
        outcome,
        console_owned,
        exception_owned,
        tapes,
        correlation_id,
        activation,
    );
}

/// Same as `captureLog`, but lets the caller supply a pre-minted
/// `request_id` so the log record shares its id with the webhook rows
/// a handler may have spawned via `webhook.send`. Pass `null` to mint
/// fresh.
///
/// Takes ownership of `tapes` byte allocations on success. On
/// failure they're freed alongside `console_owned` / `exception_owned`.
pub fn captureLogWithId(
    worker: anytype,
    instance_id: []const u8,
    request_id: ?u64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
    correlation_id: ?[]const u8,
    activation: log_mod.ActivationSource,
) void {
    captureLogInner(
        worker,
        instance_id,
        request_id,
        method,
        path,
        host,
        deployment_id,
        received_ns,
        status,
        outcome,
        console_owned,
        exception_owned,
        tapes,
        correlation_id,
        activation,
    ) catch |err| {
        std.log.warn("rove-js: log capture failed for {s}: {s}", .{ instance_id, @errorName(err) });
        // The transferred buffers must still be freed.
        if (console_owned.len > 0) worker.allocator.free(console_owned);
        if (exception_owned.len > 0) worker.allocator.free(exception_owned);
        var t = tapes;
        t.deinit(worker.allocator);
    };
}

fn captureLogInner(
    worker: anytype,
    instance_id: []const u8,
    request_id: ?u64,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    deployment_id: u64,
    received_ns: i64,
    status: u16,
    outcome: log_mod.Outcome,
    console_owned: []u8,
    exception_owned: []u8,
    tapes: log_mod.TapePayloads,
    correlation_id: ?[]const u8,
    activation: log_mod.ActivationSource,
) !void {
    const tl = worker.tenant_logs.get(instance_id) orelse return error.NoTenantLog;
    const allocator = worker.allocator;

    // Dupe the borrowed strings (tenant_id/method/path/host). On
    // failure the transferred buffers are freed by the outer
    // captureLog wrapper.
    const a_tenant = try allocator.dupe(u8, instance_id);
    errdefer allocator.free(a_tenant);
    const a_method = try allocator.dupe(u8, method);
    errdefer allocator.free(a_method);
    const a_path = try allocator.dupe(u8, path);
    errdefer allocator.free(a_path);
    const a_host = try allocator.dupe(u8, host);
    errdefer allocator.free(a_host);
    const a_corr: []const u8 = if (correlation_id) |c|
        if (c.len > 0) try allocator.dupe(u8, c) else ""
    else
        "";
    errdefer if (a_corr.len > 0) allocator.free(a_corr);

    const id = request_id orelse try tl.id_minter.nextRequestId();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    try worker.log_buffer.append(.{
        .tenant_id = a_tenant,
        .request_id = id,
        .deployment_id = deployment_id,
        .received_ns = received_ns,
        .duration_ns = now_ns - received_ns,
        .method = a_method,
        .path = a_path,
        .host = a_host,
        .status = status,
        .outcome = outcome,
        .console = console_owned,
        .exception = exception_owned,
        .tapes = tapes,
        .correlation_id = a_corr,
        .activation = activation,
    });
}

/// Periodically drain the worker's node-wide log buffer into a
/// single embedded-sidecar `.ndjson` object and PUT it to the
/// configured `BatchStore` (Phase 5.5 a). Runs on the leader only
/// — followers' buffer is always empty because `dispatchPending`
/// early-returns 503 on followers. Lossy on PUT failure: records
/// already left the buffer; per `docs/logs-plan.md` §1 a node-
/// failure window may drop one batch.
///
/// Phase 5.5(a-2) interleaved-per-node flush: every record carries
/// its `tenant_id`; the indexer demuxes on read. One S3 object per
/// flush window per node regardless of tenant fan-in.
pub fn flushLogs(worker: anytype) !void {
    const allocator = worker.allocator;
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    if (!worker.log_buffer.shouldFlush(now_ns)) return;

    const drained = worker.log_buffer.drainRecords(allocator) catch |err| {
        std.log.warn(
            "rove-js flushLogs: drainRecords failed: {s}",
            .{@errorName(err)},
        );
        return;
    };
    const records = drained orelse return;
    defer {
        for (records) |*r| r.deinit(allocator);
        allocator.free(records);
    }

    if (!worker.raft.isLeader()) {
        std.log.warn(
            "rove-js flushLogs: dropping {d}-record batch — lost leadership mid-tick",
            .{records.len},
        );
        return;
    }

    var node_buf: [8]u8 = undefined;
    const node_id_hex = std.fmt.bufPrint(&node_buf, "{x:0>8}", .{worker.raft.config.node_id}) catch unreachable;
    const flush_unix_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));

    const batch_key_opt = log_server_mod.flush_writer.writeBatch(
        allocator,
        worker.log_batch_store,
        node_id_hex,
        records,
        flush_unix_ms,
    ) catch |err| blk: {
        std.log.warn(
            "rove-js flushLogs: writeBatch ({d} records) failed: {s}",
            .{ records.len, @errorName(err) },
        );
        break :blk null;
    };
    const batch_key = batch_key_opt orelse return;
    defer allocator.free(batch_key);

    // Push the batch key to log-server so its indexer can GET the
    // object directly (read-after-write consistent on S3 even when
    // list-after-write isn't). Fire-and-forget — if it fails, the
    // indexer's 500ms LIST polling picks the batch up on the next
    // cycle. The push just collapses the typical worst-case
    // visibility window from ~seconds to ~tens of ms.
    pushBatchKey(worker, allocator, batch_key) catch |err| {
        std.log.warn(
            "rove-js flushLogs: pushBatchKey({s}) failed: {s}",
            .{ batch_key, @errorName(err) },
        );
    };
}

/// Tell log-server about a freshly-PUT batch so it indexes the key
/// directly. Builds `POST {log_public_base}/v1/_internal/batch-pushed`
/// with `X-Rove-Batch-Key: <key>` + a freshly-minted services JWT.
/// Fire-and-forget with a tight timeout — never blocks the worker.
/// Enqueue a freshly-PUT batch key for the push thread to ship to
/// log-server. Fast path: dupe + mutex-protected append + event set.
/// The synchronous curl POST that used to live here now happens on
/// the `pushLoop` thread, batching every key that queued up between
/// pushes into one request body.
fn pushBatchKey(
    worker: anytype,
    allocator: std.mem.Allocator,
    batch_key: []const u8,
) !void {
    if (worker.log_push_curl == null) return;
    if (worker.log_public_base) |base| {
        if (base.len == 0) return;
    } else return;
    const key_copy = try allocator.dupe(u8, batch_key);
    worker.push_queue_mutex.lock();
    defer worker.push_queue_mutex.unlock();
    worker.push_queue.append(allocator, key_copy) catch |err| {
        allocator.free(key_copy);
        return err;
    };
    worker.push_wake.set();
}

/// Cap on keys per outbound request — keeps the body bounded and
/// matches the log-server's read-buffer expectations. Above this the
/// loop sends multiple requests in sequence.
const PUSH_MAX_KEYS_PER_REQUEST: usize = 1024;

/// Background log-server push loop. Wakes on `push_wake` (set by
/// `pushBatchKey`) or every `PUSH_TICK_NS` regardless. Drains the
/// queue into a local slice, packs the keys into a newline-separated
/// body, and POSTs to `/v1/_internal/batch-pushed`. The S3 batch
/// itself was already PUT by the flusher; this thread only tells
/// log-server *that the key exists*, so failures are soft — the
/// indexer's LIST polling is the catch-up.
fn pushLoop(worker: anytype) void {
    const PUSH_TICK_NS: u64 = 50 * std.time.ns_per_ms;
    const allocator = worker.allocator;
    while (!worker.push_should_stop.load(.acquire)) {
        worker.push_wake.timedWait(PUSH_TICK_NS) catch {};
        worker.push_wake.reset();

        // Drain the queue into a local list under the mutex, then
        // release it before doing curl I/O. Workers append while we
        // POST; that's fine — they'll show up on the next tick.
        var drained: std.ArrayList([]u8) = .empty;
        worker.push_queue_mutex.lock();
        std.mem.swap(std.ArrayList([]u8), &drained, &worker.push_queue);
        worker.push_queue_mutex.unlock();
        if (drained.items.len == 0) continue;

        var sent: usize = 0;
        while (sent < drained.items.len) {
            const end = @min(sent + PUSH_MAX_KEYS_PER_REQUEST, drained.items.len);
            const chunk = drained.items[sent..end];
            sendPushChunk(worker, allocator, chunk) catch |err| {
                std.log.warn(
                    "rove-js push: send {d} keys failed: {s} (LIST polling will catch up)",
                    .{ chunk.len, @errorName(err) },
                );
            };
            sent = end;
        }
        for (drained.items) |k| allocator.free(k);
        drained.deinit(allocator);
    }
}

/// POST a single chunk of newline-separated batch keys.
fn sendPushChunk(
    worker: anytype,
    allocator: std.mem.Allocator,
    keys: []const []u8,
) !void {
    const easy = worker.log_push_curl orelse return;
    const log_base = worker.log_public_base orelse return;
    const secret = worker.services_jwt_secret orelse return;

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/_internal/batch-pushed", .{log_base});
    defer allocator.free(url);

    // JWT is minted once per chunk (60 s exp). Reusing it across
    // multiple chunks in the same tick would be cheaper, but the
    // chunk loop almost always runs just once.
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const token = try jwt_mod.mint(allocator, secret, .{ .exp_ms = now_ms + 60 * 1000 });
    defer allocator.free(token);
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_value);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    for (keys, 0..) |k, i| {
        if (i > 0) try body.append(allocator, '\n');
        try body.appendSlice(allocator, k);
    }

    const headers = [_]blob_mod.curl.Header{
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    const use_h2c = std.mem.startsWith(u8, url, "http://");
    var resp = try easy.request(allocator, .{
        .method = .POST,
        .url = url,
        .headers = &headers,
        .body = body.items,
        .timeout_ms = 2000,
        .connect_timeout_ms = 500,
        .http_version = if (use_h2c) .h2c_prior_knowledge else .auto,
        .verify_tls = !worker.internal_insecure_tls,
    });
    defer resp.deinit(allocator);
    if (resp.status != 204) {
        std.log.warn(
            "rove-js push batch: {s} ({d} keys) → {d}",
            .{ url, keys.len, resp.status },
        );
    }
}

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
    if (raft_propose.proposeWriteSet(
        .{ .allocator = allocator, .raft = raft },
        &ws,
        slot.instance_id,
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
        "rove-js: tenant {s} loaded deployment {d} ({d} handler(s), {d} static(s), {d} trigger(s))",
        .{ slot.instance_id, manifest.id, new_snap.bytecodes.count(), new_snap.statics.count(), new_snap.triggers.len },
    );
}

// ── Dispatch system ───────────────────────────────────────────────────
//
// `dispatchOnce` processes a SINGLE tenant's batch per call. The
// caller (the worker poll loop) calls it in a loop, flushing between
// iterations so the ECS removes processed entities from `request_out`.
// Each call:
//
//   1. Walks `request_out.entitySlice()` once.
//   2. Short-circuits (not-leader, `/_system/*`, unknown tenant,
//      missing deployment, router / penalty failures) finalize inline
//      — `setSimpleResponse` + move to `response_in`.
//   3. The first handler-bound entity establishes the anchor tenant;
//      opens `beginTrackedImmediate` + a `WriteSet`. Subsequent
//      handler entities are run under `SAVEPOINT h → dispatcher.run
//      → RELEASE h` (or `ROLLBACK TO h` on error) if they match the
//      anchor, and skipped this pass if they don't.
//   4. After the walk, commits once and proposes a single merged
//      writeset (if any writes). All successful entities land in
//      `raft_pending` with the shared raft seq; read-only batches
//      skip raft and land in `response_in`.
//   5. Returns the number of entities moved out of `request_out`.
//
// This amortizes WAL fsync across multiple handlers per tick — the
// dominant per-tenant bottleneck identified in the Stage 0 profile.
// Per-handler isolation is preserved: a JS exception or CPU-budget
// kill in handler #5 only rolls back its savepoint, the rest commit.
//
// Skipped entities (different tenant than this tick's anchor) stay in
// `request_out`; the caller's next `dispatchOnce` call picks a fresh
// anchor from whoever is still there. The `blocked` set keeps a
// lease-contended anchor from blocking other tenants within a tick.

/// Process one tenant's batch of requests from `request_out`. Returns
/// the number of entities moved out of `request_out` (to
/// `response_in` or `raft_pending`). Zero means the
/// collection has no work the caller can make progress on — either
/// `request_out` is empty, or all remaining handler entities target
/// tenants in `blocked`.
///
/// The caller MUST flush between calls so the next call sees a
/// drained `request_out`, and MUST clear `blocked` at the top of
/// each tick so a tenant that happened to be BUSY this tick gets a
/// fresh chance next tick.
///
/// `blocked` is any value with `.slice()` returning a slice of
/// `*const tenant_mod.Instance` and a fallible `append(*const
/// tenant_mod.Instance)` (e.g. `std.BoundedArray`). When the kvexp
/// dispatch-lease `tryAcquire` is contended (surfaced as
/// `error.Conflict` from `beginTrackedImmediate`/`ensureOpen` — a
/// non-blocking try, never a wait), the current anchor candidate is
/// appended; the linear walk then ignores that tenant's entities for
/// the rest of this call and the calls that follow within the tick.

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
/// Phase 5: response-bound raft park drain. Entity in
/// `raft_pending_response` → `response_in` on commit / fault.
fn drainResponsePending(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    committed: u64,
    faulted: u64,
    now_ns: i64,
) !void {
    const entities = worker.raft_pending_response.entitySlice();
    const waits = worker.raft_pending_response.column(RaftWait);
    const resp_bodies = worker.raft_pending_response.column(h2.RespBody);
    var i: usize = 0;
    while (i < entities.len) : (i += 1) {
        const ent = entities[i];
        const wait = waits[i];
        const resp_body = resp_bodies[i];

        if (committed >= wait.seq) {
            if (worker.pending_txns.get(wait.seq)) |tracked| {
                tracked.commit() catch |err| switch (err) {
                    error.Conflict => continue,
                    else => panic_mod.invariantViolated(
                        "drainResponsePending.commit",
                        "seq={d} err={s}",
                        .{ wait.seq, @errorName(err) },
                    ),
                };
                _ = worker.pending_txns.remove(wait.seq);
                allocator.destroy(tracked);
            }
            try server.reg.move(ent, &worker.raft_pending_response, &server.response_in);
            continue;
        }

        const is_faulted = faulted > 0 and faulted >= wait.seq;
        const is_timed_out = now_ns >= wait.deadline_ns;
        if (!is_faulted and !is_timed_out) continue;

        if (worker.pending_txns.fetchRemove(wait.seq)) |kv| {
            kv.value.rollback() catch |err| panic_mod.invariantViolated(
                "drainResponsePending.rollback",
                "seq={d} err={s}",
                .{ wait.seq, @errorName(err) },
            );
            allocator.destroy(kv.value);
        }

        const old_body_ptr: ?[*]u8 = resp_body.data;
        const old_body_len: u32 = resp_body.len;
        try respb.overwrite503InPending(worker, &worker.raft_pending_response, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);

        try server.reg.move(ent, &worker.raft_pending_response, &server.response_in);
    }
}

/// Phase 5: continuation-bound raft park drain. Entity in
/// `raft_pending_cont` → `parked_continuations` on commit; → 503
/// `response_in` on fault (with parked_meta cleanup until Phase 7
/// deletes that side store).
fn drainContPending(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    committed: u64,
    faulted: u64,
    now_ns: i64,
) !void {
    const entities = worker.raft_pending_cont.entitySlice();
    const waits = worker.raft_pending_cont.column(RaftWait);
    const resp_bodies = worker.raft_pending_cont.column(h2.RespBody);
    var i: usize = 0;
    while (i < entities.len) : (i += 1) {
        const ent = entities[i];
        const wait = waits[i];
        const resp_body = resp_bodies[i];

        if (committed >= wait.seq) {
            if (worker.pending_txns.get(wait.seq)) |tracked| {
                tracked.commit() catch |err| switch (err) {
                    error.Conflict => continue,
                    else => panic_mod.invariantViolated(
                        "drainContPending.commit",
                        "seq={d} err={s}",
                        .{ wait.seq, @errorName(err) },
                    ),
                };
                _ = worker.pending_txns.remove(wait.seq);
                allocator.destroy(tracked);
            }
            // Phase 5: the entity's collection (raft_pending_cont)
            // IS the discriminant — straight to parked_continuations,
            // no `ContDescriptor.cont != null` field check needed.
            try server.reg.move(ent, &worker.raft_pending_cont, &worker.parked_continuations);
            continue;
        }

        const is_faulted = faulted > 0 and faulted >= wait.seq;
        const is_timed_out = now_ns >= wait.deadline_ns;
        if (!is_faulted and !is_timed_out) continue;

        if (worker.pending_txns.fetchRemove(wait.seq)) |kv| {
            kv.value.rollback() catch |err| panic_mod.invariantViolated(
                "drainContPending.rollback",
                "seq={d} err={s}",
                .{ wait.seq, @errorName(err) },
            );
            allocator.destroy(kv.value);
        }

        // Trampoline: open hop's commit faulted/timed out → cannot
        // hold. The on-entity ContDescriptor deinits structurally
        // when cleanupResponses destroys the entity — no manual
        // cleanup site needed (Phase 7).

        const old_body_ptr: ?[*]u8 = resp_body.data;
        const old_body_len: u32 = resp_body.len;
        try respb.overwrite503InPending(worker, &worker.raft_pending_cont, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);

        try server.reg.move(ent, &worker.raft_pending_cont, &server.response_in);
    }
}

/// Phase 5: stream-first-hop raft park drain. Entity in
/// `raft_pending_stream` → `stream_response_in` on commit (after
/// registerStreamCell consumes pending_stream_meta); → 503
/// `response_in` on fault.
fn drainStreamPending(
    worker: anytype,
    server: anytype,
    allocator: std.mem.Allocator,
    committed: u64,
    faulted: u64,
    now_ns: i64,
) !void {
    const entities = worker.raft_pending_stream.entitySlice();
    const waits = worker.raft_pending_stream.column(RaftWait);
    const resp_bodies = worker.raft_pending_stream.column(h2.RespBody);
    var i: usize = 0;
    while (i < entities.len) : (i += 1) {
        const ent = entities[i];
        const wait = waits[i];
        const resp_body = resp_bodies[i];

        if (committed >= wait.seq) {
            if (worker.pending_txns.get(wait.seq)) |tracked| {
                tracked.commit() catch |err| switch (err) {
                    error.Conflict => continue,
                    else => panic_mod.invariantViolated(
                        "drainStreamPending.commit",
                        "seq={d} err={s}",
                        .{ wait.seq, @errorName(err) },
                    ),
                };
                _ = worker.pending_txns.remove(wait.seq);
                allocator.destroy(tracked);
            }
            // Phase 7: stream components were populated in
            // `streamRecordIfAnyAt` BEFORE the entity entered
            // raft_pending_stream — they ride the entity here via
            // merged_request_row. Just move to stream_response_in;
            // h2 picks the entity up from there.
            try server.reg.move(ent, &worker.raft_pending_stream, &server.stream_response_in);
            continue;
        }

        const is_faulted = faulted > 0 and faulted >= wait.seq;
        const is_timed_out = now_ns >= wait.deadline_ns;
        if (!is_faulted and !is_timed_out) continue;

        if (worker.pending_txns.fetchRemove(wait.seq)) |kv| {
            kv.value.rollback() catch |err| panic_mod.invariantViolated(
                "drainStreamPending.rollback",
                "seq={d} err={s}",
                .{ wait.seq, @errorName(err) },
            );
            allocator.destroy(kv.value);
        }

        // Phase 7: stream components on the entity reap structurally
        // when cleanupResponses destroys it; no side-table cleanup.

        const old_body_ptr: ?[*]u8 = resp_body.data;
        const old_body_len: u32 = resp_body.len;
        try respb.overwrite503InPending(worker, &worker.raft_pending_stream, ent, allocator);
        if (old_body_ptr) |p| allocator.free(p[0..old_body_len]);

        try server.reg.move(ent, &worker.raft_pending_stream, &server.response_in);
    }
}

pub fn drainRaftPending(worker: anytype) !void {
    const server = worker.h2;
    const allocator = worker.allocator;

    const committed = worker.raft.committedSeq();
    const faulted = worker.raft.faultedSeq();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    // Handler-cmds Phase 5: raft_pending is THREE sibling collections.
    // Each entity is parked on the sibling matching its commit
    // destination, so the dispatch in each loop is direct — no
    // `desc.cont != null` field check, no `pending_stream_meta.contains`
    // probe. Whichever loop processes a given seq first commits the
    // shared TrackedTxn; later siblings find the map empty and just
    // queue moves. Forward-iter preserves per-tenant chain order
    // (entities enter the siblings in propose-seq order from
    // finalizeBatch).
    try drainResponsePending(worker, server, allocator, committed, faulted, now_ns);
    try drainContPending(worker, server, allocator, committed, faulted, now_ns);
    try drainStreamPending(worker, server, allocator, committed, faulted, now_ns);

    // ── Additive: non-entity parked units (idiom-1 SSE-emit gating,
    //    docs/unified-effect-gating.md). The H2 entity path above is
    //    untouched — H2 behaviour is byte-identical. Release buffered
    //    emits at commit; discard on fault/timeout (the effect never
    //    escaped — same posture as the entity 503 path). Reuses the
    //    `committed`/`faulted`/`now_ns` watermarks computed above.
    var u: usize = 0;
    while (u < worker.pending_units.items.len) {
        const unit = &worker.pending_units.items[u];
        if (committed >= unit.seq) {
            // Phase 4c: forgetful-writes units carry their own
            // `TrackedTxn` (no entity in raft_pending waiting on
            // this seq — see `proposeForgetfulWrites`). Commit it
            // here; the firePending* helpers run alongside, same
            // post-commit firing order as the entity-backed path.
            if (unit.txn) |t| {
                t.commit() catch |cerr| panic_mod.invariantViolated(
                    "drainRaftPending.pending_units.commit",
                    "seq={d} tenant={s} err={s}",
                    .{ unit.seq, unit.tenant_id, @errorName(cerr) },
                );
                allocator.destroy(t);
                unit.txn = null;
            }
            firePendingSendOps(worker, unit);
            firePendingKvWakes(worker, unit);
            unit.deinit(allocator);
            _ = worker.pending_units.swapRemove(u);
            continue;
        }
        if ((faulted > 0 and faulted >= unit.seq) or now_ns >= unit.deadline_ns) {
            // Phase 4c: rollback the attached txn before discarding
            // the unit. `ParkedUnit.deinit` also does this as a
            // safety net (shutdown path), but doing it here keeps
            // the fault/timeout discard ordering symmetric with
            // commit's destroy-then-clear pattern.
            if (unit.txn) |t| {
                t.rollback() catch |rerr| std.log.warn(
                    "rove-js drainRaftPending.pending_units.rollback seq={d} tenant={s}: {s}",
                    .{ unit.seq, unit.tenant_id, @errorName(rerr) },
                );
                allocator.destroy(t);
                unit.txn = null;
            }
            unit.deinit(allocator); // discard — never committed, never escaped
            _ = worker.pending_units.swapRemove(u);
            continue;
        }
        u += 1;
    }
}

/// §6.4 mandatory-timeout sweep for continuation-parked streams
/// (connection-actor 3b-ii). A stream that returned `next(...)` and
/// has no resume by its deadline gets a real 504 — before any
/// intermediary gives up. The `reg.move` out of `parked_continuations`
/// is simultaneously the resolve AND the resolve-once guard: a stream
/// leaves a collection exactly once, so a racing 3b-iii callback
/// finds it gone (expected, not an error). O(parked) per tick, gated
/// by `parked_meta.count() == 0`.
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

fn resolveDeployment(
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
        return error.ResumeNoBytecode;
    };
    return .{ .inst = inst, .tc = tc, .bc = bc };
}

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
/// back, destroys it, and frees `meta` so the caller can degrade
/// to a defined 500.
///
/// The post-commit move depends on `next`:
///   • `.terminal` — `parked_meta` is freed, h2 response components
///     are stamped on the entity, RaftWait is set, entity moves to
///     `raft_pending`. `drainRaftPending` commits → `response_in`
///     (the normal flush path, since parked_meta is gone).
///   • `.repark` — `parked_meta` is UPDATED with the new
///     continuation + bound_schedule_id; RaftWait is set; entity
///     moves to `raft_pending`. `drainRaftPending` commits → sees
///     parked_meta → moves back to `parked_continuations` (the new
///     park, waiting for the new send / deadline).
///
/// Also parks the send / kv-wake commit gates (parkSendOps +
/// parkKvWakes) on the same seq so any `_send/owed/*` arm /
/// `_send/proof/*` resolve and any §4.6 wake fan-outs fire
/// AFTER commit, alongside the entity's state transition.
const ContResumeNext = union(enum) {
    /// Terminal flush. `body` is allocator-owned; ownership
    /// transferred into the entity's RespBody on success.
    terminal: struct { status: u16, body: []u8 },
    /// Re-park with a new continuation. `new_cont` is owned
    /// (transferred into parked_meta). `new_bound_sched_id` is
    /// allocator-owned if non-null (the lone `_send/owed/{id}`
    /// this hop wrote — same §6.4 inferred-bind rule as the
    /// inbound trampoline open hop).
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
        // `next`. Phase 7: ContDescriptor on the entity deinits
        // structurally when the entity is destroyed; no side-table
        // free here. Caller's catch path handles the 500 flush + log.
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
    try worker.pending_txns.put(allocator, seq, txn);
    // parkSendOps + parkKvWakes ride the same seq so the wakes /
    // arm-resolve fire AFTER commit. Best-effort: log and continue
    // if parking fails — same posture as the inbound write path.
    parkSendOps(worker, seq, tenant_id, writeset) catch |perr|
        std.log.warn("rove-js cont-resume parkSendOps (tenant={s}) failed: {s}", .{ tenant_id, @errorName(perr) });
    parkKvWakes(worker, seq, tenant_id, writeset) catch |perr|
        std.log.warn("rove-js cont-resume parkKvWakes (tenant={s}) failed: {s}", .{ tenant_id, @errorName(perr) });

    const deadline_ns: i64 = @intCast(std.time.nanoTimestamp() +
        @as(i128, @intCast(worker.commit_wait_timeout_ns)));

    switch (next) {
        .terminal => |t| {
            // Phase 7: clear the entity's ContDescriptor so the
            // drainContPending commit branch's "the collection IS
            // the destination" routing — wait, no, this is the
            // cont-resume WRITE path that lands the entity on
            // `raft_pending_cont`, NOT `raft_pending_response`,
            // because the resume was driven by an entity in
            // `parked_continuations`. The commit branch will route
            // back to `parked_continuations`; then the terminal
            // resolve happens (resolveParked moves it out). We
            // need ContDescriptor cleared so a later sweep doesn't
            // re-interpret this as a held cont — but actually,
            // the entity moves OUT of parked_continuations before
            // the next sweep tick (sweep checks isInCollection
            // first). So we can leave ContDescriptor populated;
            // it deinits when the entity destroys.
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
            // Cont-resume that wrote: park on the cont sibling so the
            // drain routes back to parked_continuations on commit.
            try server.reg.move(ent, &worker.parked_continuations, &worker.raft_pending_cont);
        },
        .repark => |r| {
            // Phase 7: update the entity's ContDescriptor in place —
            // replace cont, refresh bound_schedule_id, refresh
            // deadline. drainContPending sees the entity in
            // raft_pending_cont at commit and routes back to
            // parked_continuations. Ownership of r.new_cont and
            // r.new_bound_sched_id transfers directly into the
            // component (no clone — the side table is gone).
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
            // Cont-resume that wrote: park on the cont sibling so the
            // drain routes back to parked_continuations on commit.
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
///         raft_pending_cont; drainContPending re-parks on commit
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
    // Phase 2c: resolve-once guard becomes collection membership +
    // ContDescriptor presence. Cont state (path / fn_name / ctx_json /
    // tenant_id / correlation_id) read from the entity's components
    // instead of `parked_meta`. The slices borrow into the
    // component's heap allocations; they stay valid across moves
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
    var tapes = RequestTapes.init(allocator);
    defer tapes.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .kv_tape = &tapes.kv,
        .date_tape = &tapes.date,
        .math_random_tape = &tapes.math_random,
        .crypto_random_tape = &tapes.crypto_random,
        .module_tape = &tapes.module,
        .prng_seed = @bitCast(now_ns),
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
                // Phase 1b: record the resume's tape entry before
                // freeing meta. Activation source = send_callback so
                // the row shares the chain id with the inbound entry
                // and the replay UX groups them.
                captureLogWithId(worker, tenant_id, request_id, "POST", cont_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, correlation_id, .send_callback);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                // Phase 4: terminal + writes — propose the writes
                // through raft, park the entity on `raft_pending`
                // with the response components staged on it, and
                // drop the parked_meta entry so `drainRaftPending`
                // routes the committed entity to `response_in`
                // (normal flush path, not the repark).
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
                    // rolled back + destroyed inside the helper;
                    // meta was freed.
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
                // on raft_pending, and on commit `drainRaftPending`
                // sees the (updated) parked_meta entry and re-parks
                // by moving to `parked_continuations`.  The new
                // bound_schedule_id (the lone `_send/owed/` this
                // hop wrote, if exactly one) becomes the wake the
                // next callback resolves on. Same fail-fast posture
                // as the terminal+writes branch.
                const corr_id = correlation_id;
                const dep_id = tc.snap.deployment_id;
                // §6.4 binding for the repark: scan the writeset
                // for the single _send/owed/{id} put. 0 / >1 → null
                // (deadline-only resume).
                const new_bound_sched_id: ?[]u8 = blk: {
                    var only: ?[]const u8 = null;
                    var nputs: usize = 0;
                    for (ws.ops.items) |op| switch (op) {
                        .put => |p| if (std.mem.startsWith(u8, p.key, send_outbox_mod.OWED_PREFIX)) {
                            nputs += 1;
                            only = p.key[send_outbox_mod.OWED_PREFIX.len..];
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
                    // c2m + new_bound_sched_id + meta on failure;
                    // we just log + degrade.
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
            // entity stays in `parked_continuations`. Phase 7:
            // ownership of c2m transfers directly to the component;
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

/// §6.4 mandatory-timeout sweep. A past-deadline parked stream is
/// resumed with a `timeout` outcome so the handler authors the
/// response (plan §6.4: "the handler gets the last word on the
/// body"); `allow_repark = false` forces termination. If the resume
/// engine itself fails (no deployment / bytecode / txn), fall back to
/// a hard 504 so the socket never hangs past its deadline.
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
    // Phase 2c: bound_schedule_id + tenant_id read from the entity's
    // components instead of `parked_meta`. The `count() == 0` probe
    // becomes an empty-collection check — membership in
    // `parked_continuations` IS the cont-state discriminant
    // (principle #1).
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

pub fn sweepParkedContinuations(worker: anytype) !void {
    // Phase 2a: deadline read switched from `parked_meta` (side table)
    // to the entity's `ContDescriptor` component. The empty-loop
    // short-circuit replaces the `parked_meta.count() == 0` probe —
    // membership in `parked_continuations` IS the cont-state
    // discriminant (principle #1), no separate count check needed.
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

// ── Streaming-handlers Phase 2b-ii: state machine over h2's
//    stream_data_out / stream_data_in / stream_close_in pipeline ────

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
        var queue: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (queue.items) |c| allocator.free(c);
            queue.deinit(allocator);
        }
        try queue.ensureUnusedCapacity(allocator, initial_chunks.len);
        for (initial_chunks) |c| {
            const cl = try allocator.dupe(u8, c);
            queue.appendAssumeCapacity(cl);
        }
        try server.reg.set(ent, current_coll, components_mod.StreamChunks, .{ .queue = queue });
        queue = .empty; // ownership transferred — block-exit errdefer is a no-op
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
            .pending_wake = null,
        });
    }
}

/// Phase 2b-ii: install the chain cell for a `__rove_stream(...)`
/// first-hop. Caller has already stamped `h2.Status` / `h2.RespHeaders`
/// / `h2.StreamId` / `h2.Session` on the entity in `request_out` and
/// is about to move it into `h2.stream_response_in` (the streaming
/// twin of `response_in`). We own the chain-level state alone:
/// `chunks` (drained one frame at a time by `serviceParkedStreams`),
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
        // both active and draining streams.
        if (chunks_comp.queue.items.len > 0) {
            const chunk = chunks_comp.queue.orderedRemove(0);
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

        // kv-wake match? Takes priority over the timer (and over
        // the no-timer close) — a watched prefix that just changed
        // is more interesting than a heartbeat or a passive close.
        // `pending_wake` was set by `drainKvWakeInbox` above.
        if (wakes_comp.pending_wake != null) {
            if (chain_comp.activation_count >= MAX_STREAM_ACTIVATIONS) {
                std.log.warn(
                    "rove-js stream: tenant={s} corr={s} hit activation cap; closing",
                    .{ ctx_comp.tenant_id, ctx_comp.correlation_id orelse "(none)" },
                );
                try server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in);
                continue;
            }
            resumeStream(worker, p.ent, p.sid, p.sess, .kv_wake) catch |err| {
                std.log.warn(
                    "rove-js stream-resume (kv): tenant={s} corr={s}: {s}; closing",
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

        // Timer wake due?
        if (wakes_comp.interval_ms > 0 and now_ns >= wakes_comp.next_wake_ns) {
            if (chain_comp.activation_count >= MAX_STREAM_ACTIVATIONS) {
                // §9.2 strike: misbehaving handler can't run a stream
                // forever. Close cleanly.
                std.log.warn(
                    "rove-js stream: tenant={s} corr={s} hit activation cap; closing",
                    .{ ctx_comp.tenant_id, ctx_comp.correlation_id orelse "(none)" },
                );
                try server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in);
                continue;
            }
            resumeStream(worker, p.ent, p.sid, p.sess, .timer) catch |err| {
                std.log.warn(
                    "rove-js stream-resume: tenant={s} corr={s}: {s}; closing",
                    .{ ctx_comp.tenant_id, ctx_comp.correlation_id orelse "(none)", @errorName(err) },
                );
                server.reg.move(p.ent, &server.stream_data_out, &server.stream_close_in) catch {};
            };
            continue;
        }
        // No wake due yet — idle, waiting for either a kv match or
        // the timer.
    }
}

/// Drain the worker's `wake_inbox` of kv-write events. For every
/// stream entity (in one of the h2 stream-pipeline collections,
/// not draining) whose `kv_prefixes` includes a prefix of the
/// event's key, set `pending_wake = .{ key, op }`
/// (most-recent-wins per v1's §9.4 collapse posture). Events whose
/// tenant_id matches no held stream are simply dropped — the
/// per-tenant scoping § 4.6 invariant lives at REGISTRATION time
/// (a cell only registers prefixes for its own tenant), so a
/// stale event against an old tenant just doesn't match anything.
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

/// Walk events newest-first; install the freshest matching event on
/// `wakes.pending_wake`, freeing any prior pending key.
fn matchEventsToWakes(
    allocator: std.mem.Allocator,
    events: *std.ArrayListUnmanaged(KvWakeEvent),
    wakes: *components_mod.StreamWakes,
    chain_ctx: components_mod.ChainContext,
) !void {
    {
        // Walk events newest-first so "most-recent-wins" matches the
        // intuitive notion of "this stream's pending wake is the
        // latest fired write."
        var i: usize = events.items.len;
        while (i > 0) {
            i -= 1;
            const ev = events.items[i];
            if (!std.mem.eql(u8, ev.tenant_id, chain_ctx.tenant_id)) continue;
            // Prefix match against any registered prefix.
            var matched: bool = false;
            for (wakes.kv_prefixes) |pfx| {
                if (std.mem.startsWith(u8, ev.key, pfx)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
            // Replace any earlier pending_wake (the cell didn't get
            // to consume it yet — newest wake wins). The handler's
            // job is to re-read kv state holistically, so older
            // wakes are redundant.
            if (wakes.pending_wake) |*w| {
                w.deinit(allocator);
                wakes.pending_wake = null;
            }
            const key_dup = try allocator.dupe(u8, ev.key);
            wakes.pending_wake = .{ .key = key_dup, .op = ev.op };
            break;
        }
    }
}

/// Phase 2b-ii: run the next handler activation for a parked stream.
/// Structural twin of `resumeContinuation` — same dispatch surface
/// (re-enter `Dispatcher.runOutcome` with a synthesized `Request`),
/// divergent in the outcome-application tail.
///
/// Handler-cmds Phase 8 TEA-framing:
///   - **Msg**:   `(timer-tick or kv-wake, entity in stream_data_out
///                with non-empty StreamChain.module_path)`.
///   - **prep**:  read four stream components on the entity; resolve
///                deployment; build request body = `{ctx}` with
///                `.timer` or `.kv_wake` activation; for kv_wake, pop
///                `StreamWakes.pending_wake` into `activation_kv_*`.
///   - **run**:   `dispatcher.runOutcome` (chain-tail txn).
///   - **apply (Cmd-list)**: switch on outcome:
///       • terminal → append body to StreamChunks + markStreamDraining
///         (eager-fire writes via proposeForgetfulWrites if any).
///       • stream → update StreamChain.ctx_json + StreamWakes
///         (kv_prefixes / interval / next_wake) + append new chunks +
///         increment activation_count. Eager-fire writes.
///       • continuation → 501 + markStreamDraining (`__rove_next`
///         from a stream-resume hop is out of scope).
///
/// Phase 4b lifted the read-only constraint — write-path resumes
/// `proposeForgetfulWrites` the txn (no entity awaiting commit; the
/// writes + their `_send/owed/` arms + §4.6 wakes fire on commit).
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
    // pending_units `ParkedUnit.txn` if the hop wrote (Phase 4b).
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
    var tapes = RequestTapes.init(allocator);
    defer tapes.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    // kv_wake activation: pop the pending wake off the StreamWakes
    // component (single outstanding match in v1; wake-accumulator
    // §9.4 is later) and attach the key/op to the synthesized
    // request.
    var kv_wake_taken: ?components_mod.PendingKvWake = null;
    defer if (kv_wake_taken) |*w| w.deinit(allocator);
    var activation_kv_key: ?[]const u8 = null;
    var activation_kv_op: u8 = 0;
    if (activation == .kv_wake) {
        if (wakes_st.pending_wake) |_| {
            const w = wakes_st.pending_wake.?;
            wakes_st.pending_wake = null;
            kv_wake_taken = w;
            activation_kv_key = kv_wake_taken.?.key;
            activation_kv_op = kv_wake_taken.?.op;
        }
    }
    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .kv_tape = &tapes.kv,
        .date_tape = &tapes.date,
        .math_random_tape = &tapes.math_random,
        .crypto_random_tape = &tapes.crypto_random,
        .module_tape = &tapes.module,
        .prng_seed = @bitCast(now_ns),
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = chain_ctx.correlation_id,
        .activation_source = activation,
        .activation_kv_key = activation_kv_key,
        .activation_kv_op = activation_kv_op,
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
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation);
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
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, chain_ctx.correlation_id, activation);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            // Phase 4b: terminal + writes. Eager-fire: queue the
            // body as the last chunk, flag close_pending, and propose
            // the writes asynchronously via the pending_units sweep
            // (same path as the §4.4 disconnect activation's writes).
            // The chunks may ship to the client BEFORE raft commits —
            // a §7/§9.4 trade-off the plan accepts: handlers refetch
            // authoritative state on every activation, so a spurious
            // frame on a raft fault is recoverable.
            if (wrote) {
                proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id) catch |perr| {
                    std.log.warn("rove-js stream-resume (terminal + writes): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    markStreamDraining(server, ent);
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, chain_ctx.correlation_id, activation);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                if (r.body.len > 0) {
                    const owned = try allocator.dupe(u8, r.body);
                    chunks_st.queue.append(allocator, owned) catch |e| {
                        allocator.free(owned);
                        return e;
                    };
                }
                markStreamDraining(server, ent);
                chain_st.activation_count += 1;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, activation);
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
                chunks_st.queue.append(allocator, owned) catch |e| {
                    allocator.free(owned);
                    return e;
                };
            }
            markStreamDraining(server, ent);
            chain_st.activation_count += 1;
            const st: u16 = @intCast(@max(@min(r.status, 599), 100));
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, activation);
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
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 501, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation);
        },
        .stream => |*s2| {
            // Phase 4b: stream + writes. Eager-fire as in the
            // terminal+writes branch.
            if (wrote) {
                proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id) catch |perr| {
                    std.log.warn("rove-js stream-resume (stream + writes): propose failed: {s}", .{@errorName(perr)});
                    s2.deinit(allocator);
                    txn_owned = false;
                    txn_done = true;
                    markStreamDraining(server, ent);
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation);
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
            // queue. Each chunk pointer is still allocator-owned;
            // ownership moves into `chunks_st.queue.items`.
            for (s2.chunks) |c| try chunks_st.queue.append(allocator, c);
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
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, activation);
        },
    }
}

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
fn fireDisconnectActivation(worker: anytype, ent: rove.Entity) void {
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
    var tapes = RequestTapes.init(allocator);
    defer tapes.deinit();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const request_id: u64 = blk: {
        const tl = worker.tenant_logs.get(inst.id) orelse break :blk 0;
        break :blk tl.id_minter.nextRequestId() catch 0;
    };
    const request: Request = .{
        .method = "POST",
        .path = spath,
        .body = body,
        .query = null,
        .kv_tape = &tapes.kv,
        .date_tape = &tapes.date,
        .math_random_tape = &tapes.math_random,
        .crypto_random_tape = &tapes.crypto_random,
        .module_tape = &tapes.module,
        .prng_seed = @bitCast(now_ns),
        .request_id = request_id,
        .platform = inst.platform,
        .limiter = &worker.limiter,
        .instance_id = inst.id,
        .correlation_id = chain_ctx.correlation_id,
        .activation_source = .disconnect,
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
        captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
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
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .handler_error, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect);
                r.console = &.{};
                r.exception = &.{};
                return;
            }
            if (wrote) {
                proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id) catch |perr| {
                    std.log.warn("rove-js stream-disconnect: propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false; // helper destroyed it
                    txn_done = true;
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect);
                    r.console = &.{};
                    r.exception = &.{};
                    return;
                };
                txn_owned = false;
                txn_done = true;
                const st: u16 = @intCast(@max(@min(r.status, 599), 100));
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect);
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
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, st, .ok, r.console, r.exception, .{}, chain_ctx.correlation_id, .disconnect);
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
                proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id) catch |perr| {
                    std.log.warn("rove-js stream-disconnect (cont return): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
                return;
            }
            txn.rollback() catch {};
            txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
        },
        .stream => |*s2| {
            s2.deinit(allocator);
            if (wrote) {
                proposeForgetfulWrites(worker, &ws, txn, chain_ctx.tenant_id) catch |perr| {
                    std.log.warn("rove-js stream-disconnect (stream return): propose failed: {s}", .{@errorName(perr)});
                    txn_owned = false;
                    txn_done = true;
                    captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 500, .fault, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
                    return;
                };
                txn_owned = false;
                txn_done = true;
                captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
                return;
            }
            txn.commit() catch |e| panic_mod.invariantViolated(
                "fireDisconnectActivation.commit(stream)",
                "err={s}",
                .{@errorName(e)},
            );
            txn_done = true;
            captureLogWithId(worker, chain_ctx.tenant_id, request_id, "POST", chain_st.module_path, "", tc.snap.deployment_id, now_ns, 200, .ok, &.{}, &.{}, .{}, chain_ctx.correlation_id, .disconnect);
        },
    }
}

/// Phase 4c: propose a write batch that nobody is waiting on. The
/// txn rides a `ParkedUnit.txn` field that the pending_units sweep
/// in `drainRaftPending` commits at the seq — same gate as the
/// entity-backed path's `pending_txns[seq]`, just routed through
/// the unit drain so we don't need an entity in `raft_pending`.
/// On commit, the unit's `_send/owed/*` arms + §4.6 kv-wakes
/// also fire (the existing `firePendingSendOps` / `firePendingKvWakes`
/// already iterate at the same point).
///
/// Used by `fireDisconnectActivation` — the socket is gone, so
/// we can't gate the held-response on commit, but we still want
/// the writes + their side effects to land durably.
///
/// On success the helper consumes the txn pointer (moved into
/// the ParkedUnit). On failure it rolls back + destroys it, so
/// the caller's `txn_owned` flag should flip to false either way.
fn proposeForgetfulWrites(
    worker: anytype,
    writeset: *const kv_mod.WriteSet,
    txn: *kv_mod.KvStore.TrackedTxn,
    tenant_id: []const u8,
) !void {
    const allocator = worker.allocator;
    txn.releaseLease();
    const seq = raft_propose.proposeBatch(worker, writeset, tenant_id) catch |err| {
        txn.rollback() catch {};
        allocator.destroy(txn);
        return err;
    };
    // Build a ParkedUnit carrying the txn AND the send_ops /
    // kv_wakes intents extracted from the writeset. drainRaftPending's
    // pending_units sweep handles all three at commit (or
    // discards all three on fault/timeout).
    var unit_send_ops: std.ArrayListUnmanaged(send_dispatch_mod.OwnedIntent) = .empty;
    errdefer {
        for (unit_send_ops.items) |*o| o.deinit(allocator);
        unit_send_ops.deinit(allocator);
    }
    send_dispatch_mod.materialize(writeset, tenant_id, allocator, &unit_send_ops) catch |perr|
        std.log.warn("rove-js forgetful-writes materialize send_ops (tenant={s}) failed: {s}", .{ tenant_id, @errorName(perr) });

    var unit_kv_wakes: std.ArrayListUnmanaged(KvWakeOp) = .empty;
    errdefer {
        for (unit_kv_wakes.items) |*w| w.deinit(allocator);
        unit_kv_wakes.deinit(allocator);
    }
    if (writeset.ops.items.len > 0) {
        unit_kv_wakes.ensureUnusedCapacity(allocator, writeset.ops.items.len) catch |perr|
            std.log.warn("rove-js forgetful-writes kv_wakes ensureCapacity (tenant={s}) failed: {s}", .{ tenant_id, @errorName(perr) });
        for (writeset.ops.items) |op| switch (op) {
            .put => |p| {
                const k = allocator.dupe(u8, p.key) catch break;
                unit_kv_wakes.appendAssumeCapacity(.{ .key = k, .op = 'p' });
            },
            .delete => |d| {
                const k = allocator.dupe(u8, d.key) catch break;
                unit_kv_wakes.appendAssumeCapacity(.{ .key = k, .op = 'd' });
            },
        };
    }

    try worker.pending_units.ensureUnusedCapacity(allocator, 1);
    const tid = try allocator.dupe(u8, tenant_id);
    errdefer allocator.free(tid);
    worker.pending_units.appendAssumeCapacity(.{
        .seq = seq,
        .deadline_ns = @intCast(std.time.nanoTimestamp() +
            @as(i128, @intCast(worker.commit_wait_timeout_ns))),
        .tenant_id = tid,
        .send_ops = unit_send_ops,
        .kv_wakes = unit_kv_wakes,
        .txn = txn,
    });
}

/// Fire commit-gated send arm/resolve intents into the leader-local
/// SendDispatch. Gated on commit, no-op on an empty set.
/// `worker.node.send_dispatch` is null until `startSendDispatch`
/// (and never wired on a non-leader path that matters);
/// `OwnedIntent.fire` tolerates null (a dropped intent is re-derived
/// by the promotion boot-scan — no silent loss).
fn firePendingSendOps(worker: anytype, unit: *ParkedUnit) void {
    if (unit.send_ops.items.len == 0) return;
    const sd = worker.node.send_dispatch;
    std.log.info("rove-js sendpath: firePendingSendOps seq={d} n={d} sd_null={}", .{ unit.seq, unit.send_ops.items.len, sd == null });
    for (unit.send_ops.items) |*o| o.fire(sd);
}

/// streaming-handlers-plan §4.6: fire commit-gated kv-wake intents.
/// `drainRaftPending` calls us once `committedSeq >= unit.seq`,
/// guaranteeing the writes are durably visible to local readers
/// (kvexp's `TrackedTxn.commit` already ran on this node). Each
/// intent fans out via `node.broadcastKvWake` to every worker's
/// `KvWakeInbox` — `serviceParkedStreams` then picks up matched
/// cells. No-op on empty.
fn firePendingKvWakes(worker: anytype, unit: *ParkedUnit) void {
    if (unit.kv_wakes.items.len == 0) return;
    for (unit.kv_wakes.items) |w| {
        worker.node.broadcastKvWake(unit.tenant_id, w.key, w.op);
    }
}

/// Register a committed batch's `_send/*` arm/resolve intents as a
/// post-propose parked unit, keyed by the propose `seq` — the
/// `parkEmits` idiom for the Option (b) feed. Classifies + dups owned
/// intents from the live `writeset` (valid here; freed by its owner
/// after propose). No-op when the batch wrote no `_send/*` keys, so
/// it's free to call on every write-path / tenant-batch propose.
/// §6.4 resolution routes by the send-id resume-search (Part-B
/// matches `bound_schedule_id == send_id`), not a stored locator —
/// the owning worker is hash(tenant)→worker. On a pre-append error
/// the partial owned list is freed here (nothing parked, escaped).
pub fn parkSendOps(
    worker: anytype,
    seq: u64,
    tenant_id: []const u8,
    writeset: *const kv_mod.WriteSet,
) !void {
    const allocator = worker.allocator;
    var ops: std.ArrayListUnmanaged(send_dispatch_mod.OwnedIntent) = .empty;
    errdefer {
        for (ops.items) |*o| o.deinit(allocator);
        ops.deinit(allocator);
    }
    try send_dispatch_mod.materialize(writeset, tenant_id, allocator, &ops);
    if (ops.items.len == 0) {
        ops.deinit(allocator);
        return; // nothing to gate
    }
    std.log.info("rove-js sendpath: parkSendOps tenant={s} seq={d} send_ops={d}", .{ tenant_id, seq, ops.items.len });
    try worker.pending_units.ensureUnusedCapacity(allocator, 1);
    const tid = try allocator.dupe(u8, tenant_id);
    errdefer allocator.free(tid);
    worker.pending_units.appendAssumeCapacity(.{
        .seq = seq,
        .deadline_ns = @intCast(std.time.nanoTimestamp() +
            @as(i128, @intCast(worker.commit_wait_timeout_ns))),
        .tenant_id = tid,
        .send_ops = ops,
    });
}

/// Register a tenant-batch dispatch's SSE emits as a post-propose
/// parked unit (docs/unified-effect-gating.md idiom-1, step 2).
/// Moves the emit buffer + an owned copy of `tenant_id` into
/// `worker.pending_units` keyed by the propose `seq`;
/// `drainRaftPending` releases them at commit / discards on fault.
/// Empties `*emits` so the caller's defer is a no-op. On a pre-move
/// error the emits stay with the caller (its defer drops them —
/// degraded but safe: nothing escaped, no double-free).
/// streaming-handlers-plan §4.6: register a batch's kv-writes as
/// commit-gated wake intents. Extracts `(key, op)` from each put /
/// delete in the writeset (key bytes dup'd so the caller can
/// release the writeset bytes), parks them on a `ParkedUnit` keyed
/// by the propose `seq`. `drainRaftPending` fires them at commit
/// via `firePendingKvWakes` — same shape as `parkSendOps` /
/// `parkEmits`. No-op when the writeset has no ops.
pub fn parkKvWakes(
    worker: anytype,
    seq: u64,
    tenant_id: []const u8,
    writeset: *const kv_mod.WriteSet,
) !void {
    if (writeset.ops.items.len == 0) return;
    const allocator = worker.allocator;
    var wakes: std.ArrayListUnmanaged(KvWakeOp) = .empty;
    errdefer {
        for (wakes.items) |*w| w.deinit(allocator);
        wakes.deinit(allocator);
    }
    try wakes.ensureUnusedCapacity(allocator, writeset.ops.items.len);
    for (writeset.ops.items) |op| switch (op) {
        .put => |p| {
            const k = try allocator.dupe(u8, p.key);
            wakes.appendAssumeCapacity(.{ .key = k, .op = 'p' });
        },
        .delete => |d| {
            const k = try allocator.dupe(u8, d.key);
            wakes.appendAssumeCapacity(.{ .key = k, .op = 'd' });
        },
    };
    try worker.pending_units.ensureUnusedCapacity(allocator, 1);
    const tid = try allocator.dupe(u8, tenant_id);
    errdefer allocator.free(tid);
    worker.pending_units.appendAssumeCapacity(.{
        .seq = seq,
        .deadline_ns = @intCast(std.time.nanoTimestamp() +
            @as(i128, @intCast(worker.commit_wait_timeout_ns))),
        .tenant_id = tid,
        .kv_wakes = wakes,
    });
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
    // tenant we have exactly one entry.
    var ptn_it = worker.pending_txns.iterator();
    while (ptn_it.next()) |entry| {
        entry.value_ptr.*.rollback() catch |err| std.log.warn(
            "drainOnLeadershipLoss: rollback seq={d} err={s}",
            .{ entry.key_ptr.*, @errorName(err) },
        );
        allocator.destroy(entry.value_ptr.*);
    }
    worker.pending_txns.clearRetainingCapacity();

    // Discard parked units — their seqs won't commit on this now-
    // follower; the buffered emits MUST NOT fire (the new leader
    // re-fires anything that was actually durable).
    for (worker.pending_units.items) |*pu| pu.deinit(allocator);
    worker.pending_units.clearRetainingCapacity();

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
            fireDisconnectActivation(worker, ent);
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
// Embedded in the binary so a freshly-created tenant answers 200 on
// `/` the moment signup completes. Intentionally tiny — the point is
// to prove the deploy pipeline works end-to-end, not to ship a
// template. The customer replaces these as soon as they push their
// own code through the files API.

const STARTER_INDEX_MJS =
    \\// This is your Loop46 handler. It runs as a pure function of
    \\// (request, kv) — no fetch, no setTimeout, no async IO. All
    \\// outbound effects go through webhook.send / email.send. See
    \\// the docs at https://loop46.me/docs for the full story.
    \\//
    \\// The current request is available on the `request` global
    \\// (request.method, request.path, request.body, request.query).
    \\// Return a string (or an object — we'll JSON.stringify it).
    \\export default function () {
    \\  const count = parseInt(kv.get("_starter_hits") ?? "0", 10) + 1;
    \\  kv.set("_starter_hits", String(count));
    \\  return {
    \\    message: "Your Loop46 API is live",
    \\    path: request.path,
    \\    hits: count,
    \\  };
    \\}
;

const STARTER_STATIC_INDEX_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<title>Your Loop46 app</title>
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<style>
    \\  body { font: 15px system-ui, sans-serif; max-width: 640px; margin: 4rem auto; padding: 0 1rem; color: #222; }
    \\  h1 { margin-bottom: 0.25rem; }
    \\  code { background: #f1f1f1; padding: 0.1em 0.3em; border-radius: 3px; }
    \\  ul { padding-left: 1.25rem; }
    \\</style>
    \\</head>
    \\<body>
    \\<h1>Your Loop46 app is live 🎉</h1>
    \\<p>This static page came from <code>_static/index.html</code>. Everything else routes through <code>index.mjs</code>.</p>
    \\<h2>Next steps</h2>
    \\<ul>
    \\  <li>Visit your dashboard at <a href="https://app.loop46.me">app.loop46.me</a> to edit code and browse your KV</li>
    \\  <li>Edit <code>index.mjs</code> to handle routes</li>
    \\  <li>Drop static assets under <code>_static/</code> — images, CSS, SPAs, anything</li>
    \\  <li>Use <code>webhook.send</code> and <code>email.send</code> for outbound effects</li>
    \\</ul>
    \\</body>
    \\</html>
;

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

    const tl = try openTenantLog(&fake, inst, 7);
    defer freeTenantLog(allocator, tl);
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

    const tl = try openTenantLog(&fake, inst, 9);
    defer freeTenantLog(allocator, tl);
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

