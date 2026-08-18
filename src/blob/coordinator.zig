// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Process-global write coordinator for object-storage PUTs.
//!
//! See the blob coordinator / chunk spool in
//! `docs/architecture/routing-and-ingress.md` for the full design.
//! Submissions land in a single cross-tenant pool under
//! `{key_prefix_base}_pool/…` — there are no per-(tenant, worker)
//! lanes; workers freely mix in one pool object.
//!
//! A batch's key is **derived from its own bytes** (`pool_object`), so
//! uniqueness across nodes is a property of the name rather than a
//! coordination problem: different content cannot collide, and identical
//! content collides onto an identical object. There is no id to reserve,
//! no counter to replay after a restart, and nothing to get wrong at
//! genesis. The seal stamp is taken once, here, so a PUT that timed out
//! after landing retries onto the same key instead of duplicating.
//!
//! Architecture:
//!
//!   worker N ──push──▶ per-worker queue ──┐
//!                                         ▼
//!                                  drainer thread
//!                                  (round-robin drain,
//!                                   seal on executor slack)
//!                                         │
//!                                         ▼
//!                                  K=32 executor pool
//!                                  (one synchronous PUT each)
//!                                         │
//!                                         ▼
//!                                  advance per-worker durable_seq
//!                                  (contiguous-prefix rule)
//!
//! API mirrors raft's commit_index:
//!   - `submit` → monotonic per-worker `seq` starting at 0
//!   - `durableSeq(worker)` → count of resolved-as-durable seqs in
//!     the contiguous prefix from 0. Caller checks
//!     `my_seq < durableSeq(worker)` to determine durability.
//!   - `bodyRef(worker, seq)` → BodyRef once `seq < durableSeq`
//!
//! Count semantics (vs a "seq <= hwm" framing) avoids the
//! sentinel-or-underflow problem when seq 0 is in flight or
//! terminally failed. `durableSeq() == 0` means "nothing durable
//! yet"; `== 1` means "seq 0 is durable"; etc.
//!
//! No tokens, no per-submission condvars. The unpark loop is the
//! caller's existing readiness check; we wake the per-worker
//! condition variable on HWM advance.

const std = @import("std");
const root = @import("root.zig");
const pool_object = @import("pool_object.zig");

/// Pointer into the bytes a coordinator submission stored — the seal
/// stamp and digest that name the object, plus the extent inside it.
/// The backend supplied to `init` already carries the `_pool/` prefix,
/// so `BodyRef.key` is the leaf a reader GETs.
pub const BodyRef = pool_object.Ref;

/// Tenant hash for a submission whose owner is genuinely not known at
/// the call site. The object still holds the bytes and still ages out at
/// the sweep horizon; it just cannot be dropped early on the "every
/// tenant in here is deprovisioned" rule. Never a stand-in for a tenant
/// the caller could have looked up — an object mis-attributed to nobody
/// outlives the tenant it actually belongs to.
pub const TENANT_UNATTRIBUTED: u64 = 0;

/// A worker's queue id in the coordinator — a DISTINCT TYPE, not a bare
/// integer, so it cannot be confused with any other worker identity. The
/// request-id minter identity in particular is a packed
/// `(node_id << 8) | worker_idx` whose smallest legal value is 256; three
/// call sites once narrowed it into this queue space with `@intCast` and
/// panicked the worker thread on every inbound body on every node
/// (docs/defect-patterns.md class 1). A conversion into this type now has
/// to be written on purpose and is greppable.
///
/// The one legitimate source is the worker's registered msg-inbox slot —
/// the same identity the router's bound-fetch owner table hands out — via
/// `fromInboxIdx`.
pub const QueueId = enum(u8) {
    _,

    /// The single constructor: a registered msg-inbox slot index. Null when
    /// the slot exceeds the queue space (the worker registration path turns
    /// that into `error.TooManyWorkers`).
    pub fn fromInboxIdx(idx: usize) ?QueueId {
        return @enumFromInt(std.math.cast(u8, idx) orelse return null);
    }

    /// The queue's array index.
    pub fn index(self: QueueId) usize {
        return @intFromEnum(self);
    }
};

pub const Config = struct {
    /// Number of distinct worker threads that will call `submit`.
    /// Each worker's `worker_id` must be in `[0, worker_count)`.
    worker_count: u8,

    /// K — number of concurrent PUTs in flight.
    executor_size: u8 = 32,

    /// Per-batch byte cap (safety cap). A single
    /// submission larger than this is rejected with
    /// error.SubmissionTooLarge.
    max_batch_bytes: usize = 16 * 1024 * 1024,

    /// Bounded exponential backoff on transient
    /// `Error.SlowDown` (503 / 429). Total attempts including the
    /// first one; once exhausted, the batch terminally fails.
    retry_max_attempts: u8 = 5,
    retry_initial_backoff_ns: u64 = 100 * std.time.ns_per_ms,
    retry_max_backoff_ns: u64 = 5 * std.time.ns_per_s,
    /// Jitter fraction × initial backoff, applied per attempt.
    /// ±20% per the plan. Set to 0 in tests for deterministic
    /// timing.
    retry_jitter_pct: u8 = 20,

    /// Wall-clock source for the seal stamp, in milliseconds. Injectable
    /// so a test can seal two batches at a known instant and assert that
    /// only their CONTENT separates them.
    now_unix_ms: *const fn () u64 = defaultNowUnixMs,
};

fn defaultNowUnixMs() u64 {
    return @intCast(@max(0, std.time.milliTimestamp()));
}

pub const Error = error{
    SubmissionTooLarge,
    PutFailed,
    InvalidWorkerId,
    UnknownSeq,
    Shutdown,
};

/// Per-worker durability state. Each worker has exactly one queue
/// (MPSC: producer = worker thread, consumer = drainer thread) and
/// one durability HWM observed via `durable_seq`.
const WorkerState = struct {
    /// Guards `pending`, `next_seq`, `unfinished`, `refs`. The HWM
    /// `durable_seq` is itself atomic; this mutex also serializes
    /// wakeup signalling on `cond`.
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    /// Submissions accepted by `submit` but not yet drained.
    pending: std.ArrayListUnmanaged(Submission) = .empty,

    /// Next seq to assign on `submit`.
    next_seq: u64 = 0,

    /// Sorted ascending set of seqs that block durable_seq advance.
    /// Includes (a) in-flight seqs (submitted, not yet committed)
    /// and (b) terminally-failed seqs (kept forever, so
    /// durable_seq sticks past a failed seq).
    ///
    /// durable_seq = min(unfinished) if non-empty, else next_seq.
    unfinished: std.ArrayListUnmanaged(u64) = .empty,

    /// Per-seq outcome table. Populated by the executor on batch
    /// commit (with .durable BodyRef) or terminal fail (.failed).
    /// Lookups via `bodyRef(worker, seq)`.
    refs: std.AutoHashMapUnmanaged(u64, RefSlot) = .empty,

    /// HWM observed by the worker's existing readiness loop. Atomic
    /// load is cheap, no lock required for reads. Writes happen
    /// under `mu`. Count semantics: 0 = nothing durable, k = seqs
    /// 0..k-1 are durable. See file header.
    durable_seq: std.atomic.Value(u64) = .init(0),

    fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        for (self.pending.items) |*sub| sub.deinit(allocator);
        self.pending.deinit(allocator);
        self.unfinished.deinit(allocator);
        self.refs.deinit(allocator);
    }
};

const Submission = struct {
    seq: u64,
    /// Owned, transferred from caller at submit time.
    bytes: []u8,
    /// Owning tenant, `hashStoreId`-shaped. Rides into the object's
    /// header so a sweep learns membership without reading bodies.
    tenant: u64,

    fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

const RefSlot = union(enum) {
    durable: DurableSlot,
    /// Terminal PUT failure. Carries the owning `SealedBatch.retain_id`
    /// (or 0 for a `failCollected` submission that never reached a
    /// batch) so `release` can still find + refcount-free the batch.
    failed: u64,
};

/// A committed submission's outcome: the wire `BodyRef` plus a
/// borrowed view of the bytes, retained in the owning `SealedBatch`'s
/// `SealedSubEntry.bytes` (alive for the coordinator's lifetime).
/// `readBody` dupes from `bytes` so callers needing the chunk back —
/// e.g. the bound-fetch chunk spool reading an evicted entry
/// (`docs/architecture/routing-and-ingress.md`) — get it from RAM, with no
/// `store.get` / S3 round-trip.
const DurableSlot = struct {
    ref: BodyRef,
    bytes: []const u8,
    /// Owning `SealedBatch.retain_id`, so `release` finds the batch to
    /// refcount. Carried beside the ref rather than read out of it: the
    /// ref names an OBJECT, and two retained batches can legitimately
    /// share one name.
    retain_id: u64,
};

/// One drained-and-sealed batch handed from drainer to executor.
/// Lives until coordinator deinit so worker `bodyRef(seq)` lookups
/// stay valid for the request's lifetime.
const SealedBatch = struct {
    /// This batch's handle in the retained index — a PROCESS-LOCAL
    /// counter, never an object name and never on any wire. It exists
    /// only so `release` can find the batch a submission belongs to in
    /// O(1). Two batches with identical content share a key by design
    /// (that is what makes a retried PUT idempotent) but are still two
    /// distinct in-RAM retentions, so the index cannot be keyed by the
    /// digest.
    retain_id: u64,
    /// Heap-allocated leaf key `{written_unix_ms:0>13}-{digest_hex}` —
    /// the name WITHOUT the `_pool/` prefix, because the store handed to
    /// `init` already carries it.
    leaf_key: []u8,
    /// One submission's worker: a submission carries the
    /// originating worker so the executor can advance THAT worker's
    /// durable_seq on commit. Per-submission, not per-batch, since
    /// the cross-tenant pool intentionally mixes workers in one PUT.
    /// Stored inline on SealedSubEntry below.
    entries: std.ArrayListUnmanaged(SealedSubEntry) = .empty,
    /// Concatenated bytes in submission order. Heap-allocated;
    /// passed to BlobStore.put. Freed after PUT completes
    /// (committed OR failed — no longer needed).
    payload: ?[]u8 = null,
    /// Coordinator retained-RAM cleanup (the chunk spool,
    /// `docs/architecture/routing-and-ingress.md`): count of entries not yet `release`d by their
    /// consumer. Initialized to `entries.len` at retain; each
    /// `release` decrements it and frees that entry's bytes; when it
    /// hits 0 the whole batch is freed. Guarded by `retained_mu`.
    live: usize = 0,

    fn deinit(self: *SealedBatch, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            // `release` frees consumed entries' bytes + clears them to
            // empty, so only free what's left.
            if (e.bytes.len > 0) allocator.free(e.bytes);
        }
        self.entries.deinit(allocator);
        if (self.payload) |p| allocator.free(p);
        allocator.free(self.leaf_key);
    }
};

const SealedSubEntry = struct {
    worker_id: u8,
    seq: u64,
    /// The wire ref for this submission, computed at SEAL — the object
    /// is content-addressed, so its name is not known until its bytes
    /// are laid out. The offset is into the sealed object, past the
    /// header, and is what `pool_object.resolve` matches against the
    /// object's own entry table.
    ref: BodyRef,
    /// Owned by the entry until coord deinit. Kept around so a
    /// recompute / re-PUT path (future) could rebuild the payload
    /// without re-asking workers. The parallel copy is retained
    /// (payload + entries both, doubling RAM for in-flight batches);
    /// production tuning can revisit.
    bytes: []u8,
};


pub const BlobCoordinator = struct {
    allocator: std.mem.Allocator,
    store: root.BlobStore,
    config: Config,

    workers: []WorkerState,

    /// Drainer wakeup. Workers signal `drain_cond` on push; drainer
    /// also signalled on shutdown. The drainer wakes on either
    /// "something to drain" or "executor freed a slot."
    drain_mu: std.Thread.Mutex = .{},
    drain_cond: std.Thread.Condition = .{},
    /// Total submissions across all worker queues. Drainer wakes
    /// when this is > 0 AND an executor slot is available.
    pending_count: usize = 0,

    /// Executor queue. Sealed batches awaiting an idle executor.
    exec_mu: std.Thread.Mutex = .{},
    exec_cond: std.Thread.Condition = .{},
    /// Sealed batches FIFO. Sized at most `executor_size` because
    /// the drainer waits for a free slot before sealing.
    exec_queue: std.ArrayListUnmanaged(*SealedBatch) = .empty,
    /// in_flight_batches = queued + currently-executing. Drainer
    /// blocks while >= executor_size. Bumped by drainer at seal,
    /// decremented by executor at PUT completion.
    in_flight_batches: u32 = 0,
    /// Signalled by executor when in_flight_batches drops below
    /// executor_size, waking the drainer to seal another batch.
    exec_slack_cond: std.Thread.Condition = .{},

    /// Sealed batches awaiting consumption, retained for `bodyRef` /
    /// `readBody` dereference. The chunk spool
    /// (`docs/architecture/routing-and-ingress.md`): each
    /// batch is refcounted by its un-`release`d entries (`SealedBatch
    /// .live`) and freed when fully consumed.
    /// `retained_by_batch` is the O(1) `retain_id → *SealedBatch` index
    /// `release` uses (the `retained` list is the iteration/shutdown
    /// set). Both guarded by `retained_mu`.
    retained_mu: std.Thread.Mutex = .{},
    retained: std.ArrayListUnmanaged(*SealedBatch) = .empty,
    retained_by_batch: std.AutoHashMapUnmanaged(u64, *SealedBatch) = .empty,

    /// Source of `SealedBatch.retain_id`. Process-local and never
    /// durable — it names an in-RAM retention, not an object, so
    /// restarting at 1 is correct rather than a collision. Starts at 1
    /// so 0 stays the `RefSlot.failed` "never reached a batch" marker.
    next_retain_id: std.atomic.Value(u64) = .init(1),

    shutdown_flag: std.atomic.Value(bool) = .init(false),

    drainer_thread: std.Thread,
    executor_threads: []std.Thread,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        store: root.BlobStore,
        config: Config,
    ) !*Self {
        std.debug.assert(config.worker_count > 0);
        std.debug.assert(config.executor_size > 0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const workers = try allocator.alloc(WorkerState, config.worker_count);
        errdefer allocator.free(workers);
        for (workers) |*w| w.* = .{};

        const executors = try allocator.alloc(std.Thread, config.executor_size);
        errdefer allocator.free(executors);

        self.* = .{
            .allocator = allocator,
            .store = store,
            .config = config,
            .workers = workers,
            .executor_threads = executors,
            .drainer_thread = undefined,
        };

        // Spawn executors first, then drainer + refill. errdefer joins
        // any that did spawn if a later spawn fails.
        var execs_spawned: usize = 0;
        errdefer {
            self.shutdown_flag.store(true, .release);
            self.exec_mu.lock();
            self.exec_cond.broadcast();
            self.exec_mu.unlock();
            for (executors[0..execs_spawned]) |t| t.join();
        }
        for (executors) |*t| {
            t.* = try std.Thread.spawn(.{}, executorLoop, .{self});
            execs_spawned += 1;
        }

        self.drainer_thread = try std.Thread.spawn(.{}, drainerLoop, .{self});
        errdefer {
            self.shutdown_flag.store(true, .release);
            self.drain_mu.lock();
            self.drain_cond.broadcast();
            self.drain_mu.unlock();
            self.drainer_thread.join();
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown to all threads.
        self.shutdown_flag.store(true, .release);

        // Wake drainer.
        self.drain_mu.lock();
        self.drain_cond.broadcast();
        self.drain_mu.unlock();

        // Wake executors.
        self.exec_mu.lock();
        self.exec_cond.broadcast();
        self.exec_slack_cond.broadcast();
        self.exec_mu.unlock();

        self.drainer_thread.join();
        for (self.executor_threads) |t| t.join();

        for (self.workers) |*w| w.deinit(self.allocator);
        self.allocator.free(self.workers);

        // Free any batches still in the executor queue (never picked
        // up before shutdown).
        for (self.exec_queue.items) |b| {
            b.deinit(self.allocator);
            self.allocator.destroy(b);
        }
        self.exec_queue.deinit(self.allocator);

        // Free any still-retained (un-consumed) batches + the index.
        for (self.retained.items) |b| {
            b.deinit(self.allocator);
            self.allocator.destroy(b);
        }
        self.retained.deinit(self.allocator);
        self.retained_by_batch.deinit(self.allocator);

        self.allocator.free(self.executor_threads);
        self.allocator.destroy(self);
    }

    /// Submit one Msg-worth of bytes (submission boundary
    /// = handler activation boundary). Returns the submission's
    /// monotonic per-worker seq.
    ///
    /// `tenant` is the owning tenant's `hashStoreId`. It is recorded in
    /// the object's header — a HASH, never the name, because the pool is
    /// cross-tenant by construction and a plaintext tenant list would put
    /// customer identity in an object every tenant's bytes share. A
    /// sweep reads it to decide whether every tenant in an object is
    /// deprovisioned; a caller with genuinely no tenant to attribute
    /// passes `TENANT_UNATTRIBUTED`, which only costs that object its
    /// early-drop eligibility.
    ///
    /// `bytes` is dup'd internally — caller retains ownership and
    /// remains free to read/mutate the original.
    pub fn submit(
        self: *Self,
        queue: QueueId,
        tenant: u64,
        bytes: []const u8,
    ) Error!u64 {
        if (self.shutdown_flag.load(.acquire)) return Error.Shutdown;
        if (queue.index() >= self.config.worker_count) return Error.InvalidWorkerId;
        if (bytes.len > self.config.max_batch_bytes) return Error.SubmissionTooLarge;

        const bytes_copy = self.allocator.dupe(u8, bytes) catch return error.PutFailed;
        errdefer self.allocator.free(bytes_copy);

        // Count the submission BEFORE it becomes collectable (appended
        // to `w.pending`). The drainer collects from `w.pending` under
        // `w.mu` and decrements `pending_count` by the count collected;
        // if the count were bumped AFTER the append, the drainer could
        // collect a submission before it was counted and underflow
        // `pending_count` (a fatal `integer overflow` panic in
        // `drainRoundRobin`). Bumping first keeps the invariant
        // `pending_count >= (collectable submissions)`. `pending_count`
        // is only a wake hint — a transient over-count (incremented but
        // not yet appended) just risks one empty drain pass, which
        // early-returns without decrementing. The chunk spool's
        // high-rate per-chunk bound-fetch submit path stresses this
        // (`docs/architecture/routing-and-ingress.md`).
        self.drain_mu.lock();
        self.pending_count += 1;
        self.drain_mu.unlock();

        const w = &self.workers[queue.index()];
        w.mu.lock();
        const seq = w.next_seq;
        w.next_seq += 1;
        w.pending.append(self.allocator, .{
            .seq = seq,
            .bytes = bytes_copy,
            .tenant = tenant,
        }) catch {
            w.mu.unlock();
            self.undoPendingCount();
            return error.PutFailed;
        };
        // Insert into `unfinished` in sorted order (always at the
        // end, since seqs are monotonic per worker).
        w.unfinished.append(self.allocator, seq) catch {
            // Roll back the pending append so `w.pending` doesn't carry
            // a submission `unfinished` never tracked.
            _ = w.pending.pop();
            w.mu.unlock();
            self.undoPendingCount();
            return error.PutFailed;
        };
        w.mu.unlock();

        // Wake the drainer now that the submission is collectable.
        self.drain_mu.lock();
        self.drain_cond.signal();
        self.drain_mu.unlock();

        return seq;
    }

    /// Roll back a speculative `pending_count` bump when the submission
    /// it counted failed to append. Saturating — a concurrent drainer
    /// pass may already have decremented for other collected
    /// submissions; never wrap below zero.
    fn undoPendingCount(self: *Self) void {
        self.drain_mu.lock();
        if (self.pending_count > 0) self.pending_count -= 1;
        self.drain_mu.unlock();
    }

    /// Count of retained (sealed-but-not-fully-consumed) batches —
    /// the chunk spool RAM diagnostic
    /// (`docs/architecture/routing-and-ingress.md`). With refcount
    /// release this stays at the live submitted-but-unconsumed
    /// backlog. Exposed on `/_system/metrics` as
    /// `coord_retained_batches`.
    pub fn retainedBatchCount(self: *Self) usize {
        self.retained_mu.lock();
        defer self.retained_mu.unlock();
        return self.retained.items.len;
    }

    /// Per-worker high water mark — every submission on this
    /// worker's queue with `seq < return value` is durable (or
    /// terminally failed; check `bodyRef(seq)` to distinguish).
    pub fn durableSeq(self: *Self, queue: QueueId) u64 {
        std.debug.assert(queue.index() < self.config.worker_count);
        return self.workers[queue.index()].durable_seq.load(.acquire);
    }

    /// Lookup the outcome for a (worker_id, seq). Caller must only
    /// invoke this AFTER observing `seq < durableSeq(worker_id)`.
    /// Returns the BodyRef on success, error.PutFailed if the seq
    /// terminally failed, error.UnknownSeq if the seq was never
    /// submitted (caller bug — either misuse or seq out of range).
    pub fn bodyRef(self: *Self, queue: QueueId, seq: u64) Error!BodyRef {
        std.debug.assert(queue.index() < self.config.worker_count);
        const w = &self.workers[queue.index()];
        w.mu.lock();
        defer w.mu.unlock();
        const slot = w.refs.get(seq) orelse return Error.UnknownSeq;
        return switch (slot) {
            .durable => |d| d.ref,
            .failed => Error.PutFailed,
        };
    }

    /// Return an owned copy of the bytes a submission stored, read
    /// from the coordinator's retained in-RAM batch — no `store.get`
    /// / S3 round-trip. Caller frees with `allocator.free`. Caller
    /// must only invoke this AFTER observing `seq < durableSeq(worker_id)`
    /// (same contract as `bodyRef`); the durability HWM guarantees the
    /// slot is populated. `Error.PutFailed` if the seq terminally
    /// failed, `Error.UnknownSeq` if it was never submitted.
    ///
    /// The bound-fetch chunk spool (`docs/architecture/routing-and-ingress.md`)
    /// evicts inline bytes for chunks beyond its K-deep RAM window and
    /// reads them back through here when the held chain is finally
    /// ready to consume them.
    pub fn readBody(
        self: *Self,
        queue: QueueId,
        seq: u64,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        std.debug.assert(queue.index() < self.config.worker_count);
        const w = &self.workers[queue.index()];
        w.mu.lock();
        defer w.mu.unlock();
        const slot = w.refs.get(seq) orelse return Error.UnknownSeq;
        return switch (slot) {
            .durable => |d| allocator.dupe(u8, d.bytes) catch Error.PutFailed,
            .failed => Error.PutFailed,
        };
    }

    /// The chunk spool (`docs/architecture/routing-and-ingress.md`): a consumer is DONE with a
    /// submission — it has called `bodyRef`/`readBody` for the last
    /// time. Drop the `refs` entry, free the submission's retained
    /// bytes, and free the whole `SealedBatch` once all its entries are
    /// released. This is the retained-RAM bound: coordinator memory
    /// stays at the live submitted-but-unconsumed backlog instead of
    /// growing forever.
    ///
    /// Returns `true` if the submission's ref was found + freed;
    /// `false` if its ref isn't set yet (the batch hasn't been PUT, so
    /// `durableSeq` hasn't passed `seq`) — the caller must RETRY later
    /// (e.g. the spool consumes in-window chunks from their inline
    /// bytes *before* their coordinator submit is durable; it defers
    /// the release and retries once durable). A `false` return is NOT a
    /// no-op-forever: durableSeq always advances, so a retry eventually
    /// succeeds.
    ///
    /// MUST be called at most once-to-success per submission, by its
    /// consumer. The durable copy lives in S3, so releasing never
    /// affects replay.
    pub fn release(self: *Self, queue: QueueId, seq: u64) bool {
        if (queue.index() >= self.config.worker_count) return true;
        const w = &self.workers[queue.index()];

        // Drop the ref first (no future bodyRef/readBody can read the
        // soon-to-be-freed bytes), capturing the owning retain_id.
        w.mu.lock();
        const removed = w.refs.fetchRemove(seq);
        w.mu.unlock();
        // Ref not set yet ⇒ not durable ⇒ caller should retry. (An
        // already-released seq also lands here, by contract — see the
        // "already-released / unknown seq returns false" test. The
        // double-QUEUE regression that would make a caller retry such
        // a false forever is caught worker-side in `queueCoordRelease`,
        // not here, so this stays a pure value query.)
        const kv = removed orelse return false;
        const retain_id: u64 = switch (kv.value) {
            .durable => |d| d.retain_id,
            .failed => |rid| rid, // 0 ⇒ no batch (failCollected)
        };
        if (retain_id == 0) return true;

        // Free this submission's bytes; free the batch when fully
        // consumed.
        self.retained_mu.lock();
        defer self.retained_mu.unlock();
        // Ref existed but batch already gone (shouldn't happen — the
        // ref is dropped only here) — treat as released.
        const batch = self.retained_by_batch.get(retain_id) orelse return true;
        for (batch.entries.items) |*e| {
            if (e.worker_id == queue.index() and e.seq == seq) {
                if (e.bytes.len > 0) self.allocator.free(e.bytes);
                e.bytes = &.{};
                break;
            }
        }
        if (batch.live > 0) batch.live -= 1;
        if (batch.live == 0) {
            _ = self.retained_by_batch.remove(retain_id);
            for (self.retained.items, 0..) |b, i| {
                if (b == batch) {
                    _ = self.retained.swapRemove(i);
                    break;
                }
            }
            batch.deinit(self.allocator);
            self.allocator.destroy(batch);
        }
        return true;
    }

    /// Test helper: block until seqs `0..target_exclusive` are all
    /// resolved durably (i.e., `durableSeq(worker) >= target_exclusive`)
    /// or `timeout_ns` elapses. Returns error.Timeout on timeout.
    /// In production the worker's existing readiness loop polls
    /// the atomic; this helper exists for synchronous tests.
    ///
    /// To wait for "seq N is durable", call with `target_exclusive = N + 1`.
    pub fn waitForSeq(
        self: *Self,
        queue: QueueId,
        target_exclusive: u64,
        timeout_ns: u64,
    ) !void {
        std.debug.assert(queue.index() < self.config.worker_count);
        const w = &self.workers[queue.index()];
        const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ns));
        w.mu.lock();
        defer w.mu.unlock();
        while (w.durable_seq.load(.acquire) < target_exclusive) {
            const now = std.time.nanoTimestamp();
            if (now >= deadline) return error.Timeout;
            const remaining: u64 = @intCast(deadline - now);
            w.cond.timedWait(&w.mu, remaining) catch {};
        }
    }

    // ── Drainer thread ──────────────────────────────────────────────

    fn drainerLoop(self: *Self) void {
        while (true) {
            // Wait for (a) something pending AND (b) executor slack,
            // OR shutdown.
            self.drain_mu.lock();
            while (!self.shutdown_flag.load(.acquire) and self.pending_count == 0) {
                self.drain_cond.wait(&self.drain_mu);
            }
            const shutdown_after_wait = self.shutdown_flag.load(.acquire);
            self.drain_mu.unlock();
            if (shutdown_after_wait) return;

            // Wait for at least one executor slot. Bounded — at most
            // executor_size in flight, so we always make progress.
            self.exec_mu.lock();
            while (!self.shutdown_flag.load(.acquire) and
                self.in_flight_batches >= self.config.executor_size)
            {
                self.exec_slack_cond.wait(&self.exec_mu);
            }
            const shutdown_after_slot = self.shutdown_flag.load(.acquire);
            self.exec_mu.unlock();
            if (shutdown_after_slot) return;

            // Drain one round-robin pass, sealing across workers.
            self.drainRoundRobin();
        }
    }

    /// Collect every worker's pending submissions and seal them into
    /// one or more SealedBatches (one normally; multiple if the total
    /// exceeds `max_batch_bytes`). Cross-tenant pool: workers' bytes
    /// freely mix in one S3 object, demuxed at read time by the
    /// BodyRef's `(offset, len)`.
    fn drainRoundRobin(self: *Self) void {
        // Snapshot each worker's pending under its lock, then release.
        // Accumulate into a single per-pass list across workers.
        var collected: std.ArrayListUnmanaged(CollectedSubmission) = .empty;
        defer collected.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.workers.len) : (i += 1) {
            const w = &self.workers[i];
            w.mu.lock();
            const taken_count = w.pending.items.len;
            if (taken_count == 0) {
                w.mu.unlock();
                continue;
            }
            for (w.pending.items) |sub| {
                collected.append(self.allocator, .{
                    .worker_id = @intCast(i),
                    .seq = sub.seq,
                    .bytes = sub.bytes,
                    .tenant = sub.tenant,
                }) catch {
                    // OOM in the collected list: leave this worker's
                    // pending untouched and exit the drain pass; next
                    // pass will retry.
                    w.mu.unlock();
                    self.failCollected(collected.items);
                    return;
                };
            }
            // Submissions' byte ownership transfers into `collected`.
            // Clear pending without freeing bytes (those move).
            w.pending.clearRetainingCapacity();
            w.mu.unlock();
        }

        if (collected.items.len == 0) return;

        // Decrement pending_count by the total taken.
        self.drain_mu.lock();
        self.pending_count -= collected.items.len;
        self.drain_mu.unlock();

        // Slice into <= max_batch_bytes chunks (typically one chunk).
        // The object's own framing counts against the cap: the header and
        // one table entry per submission ride in the same PUT, so summing
        // payload alone would let a full batch exceed the cap it is
        // supposed to enforce by up to `MAX_ENTRIES * ENTRY_LEN`.
        var lo: usize = 0;
        while (lo < collected.items.len) {
            var hi: usize = lo;
            var size: usize = pool_object.HEADER_LEN;
            while (hi < collected.items.len) : (hi += 1) {
                const sz = collected.items[hi].bytes.len + pool_object.ENTRY_LEN;
                if (size + sz > self.config.max_batch_bytes and hi > lo) break;
                size += sz;
            }
            self.sealOneBatch(collected.items[lo..hi]) catch |err| {
                std.log.warn(
                    "rove-blob coordinator: sealOneBatch failed: {s}",
                    .{@errorName(err)},
                );
                self.failCollected(collected.items[lo..hi]);
            };
            lo = hi;
        }
    }

    const CollectedSubmission = struct {
        worker_id: u8,
        seq: u64,
        bytes: []u8,
        tenant: u64,
    };

    /// Lay `subs` out as one `pool_object`, name it from the result, and
    /// hand it to an executor.
    ///
    /// The order here is forced by content addressing: the object's name
    /// is a function of its bytes, so it cannot be minted before the
    /// layout exists. The stamp is read ONCE, here, and the whole object
    /// — header, entry table, and payload — is built from it, which is
    /// what makes a retried PUT land on the same key rather than
    /// producing a second object.
    fn sealOneBatch(self: *Self, subs: []const CollectedSubmission) !void {
        if (subs.len == 0) return;

        const pool_subs = try self.allocator.alloc(pool_object.Submission, subs.len);
        defer self.allocator.free(pool_subs);
        for (subs, pool_subs) |sub, *ps| {
            ps.* = .{ .tenant = sub.tenant, .bytes = sub.bytes };
        }

        var sealed = try pool_object.sealWithRefs(
            self.allocator,
            pool_subs,
            self.config.now_unix_ms(),
        );
        defer sealed.deinit(self.allocator);

        // The LEAF, not the full key: this coordinator's store handle is
        // already scoped to `{key_prefix_base}_pool/`, so the prefixed
        // form would write `_pool/_pool/…` and every ref to that object
        // would resolve to a miss at the door, which reads from the
        // content base. `putsUnderPoolPrefix` pins this.
        var leaf_buf: [pool_object.LEAF_LEN]u8 = undefined;
        const leaf_owned = try self.allocator.dupe(u8, sealed.leaf(&leaf_buf));
        errdefer self.allocator.free(leaf_owned);

        const batch = try self.allocator.create(SealedBatch);
        errdefer self.allocator.destroy(batch);
        batch.* = .{
            .retain_id = self.next_retain_id.fetchAdd(1, .monotonic),
            .leaf_key = leaf_owned,
            // Ownership moves off `sealed` — `deinit` above frees only
            // what is left, and `refs` is copied into the entries below.
            .payload = sealed.bytes,
        };
        sealed.bytes = &.{};
        errdefer batch.entries.deinit(self.allocator);

        for (subs, sealed.refs) |sub, ref| {
            try batch.entries.append(self.allocator, .{
                .worker_id = sub.worker_id,
                .seq = sub.seq,
                .ref = ref,
                .bytes = sub.bytes, // ownership transferred from worker pending list
            });
        }

        // Hand to executor.
        self.exec_mu.lock();
        defer self.exec_mu.unlock();
        try self.exec_queue.append(self.allocator, batch);
        self.in_flight_batches += 1;
        self.exec_cond.signal();
    }

    /// Mark every submission in the slice as failed on its worker.
    /// Used when the drain pass can't proceed (OOM, seal failure) —
    /// PUT failure surfaces visibly so the
    /// worker observes `durable_seq` sticking + `bodyRef` returning
    /// `PutFailed`. Frees byte ownership.
    fn failCollected(self: *Self, subs: []const CollectedSubmission) void {
        for (subs) |sub| {
            const w = &self.workers[sub.worker_id];
            w.mu.lock();
            // retain_id 0: this submission never reached a SealedBatch
            // (failed at drain/seal), and its bytes are freed right
            // below — `release` finds no batch to refcount.
            w.refs.put(self.allocator, sub.seq, .{ .failed = 0 }) catch {};
            self.recomputeDurableSeqLocked(w);
            w.cond.broadcast();
            w.mu.unlock();
            self.allocator.free(sub.bytes);
        }
    }


    // ── Executor threads ────────────────────────────────────────────

    fn executorLoop(self: *Self) void {
        while (true) {
            self.exec_mu.lock();
            while (!self.shutdown_flag.load(.acquire) and
                self.exec_queue.items.len == 0)
            {
                self.exec_cond.wait(&self.exec_mu);
            }
            if (self.shutdown_flag.load(.acquire) and
                self.exec_queue.items.len == 0)
            {
                self.exec_mu.unlock();
                return;
            }
            const batch = self.exec_queue.orderedRemove(0);
            self.exec_mu.unlock();

            self.executeBatch(batch);
        }
    }

    fn executeBatch(self: *Self, batch: *SealedBatch) void {
        const payload = batch.payload orelse unreachable;
        const ok = self.putWithRetry(self.store, batch.leaf_key, payload);

        // Free the payload — no longer needed (success or failure).
        self.allocator.free(payload);
        batch.payload = null;

        // Ordering: retain + index the batch BEFORE advancing any
        // worker's `durable_seq` below. A consumer that observes the
        // HWM advance may call `release` immediately; if the batch
        // weren't indexed yet, that release would miss it and `live`
        // would never reach 0 (a leak). Retaining first closes that
        // race — the batch is always findable by the time its seqs
        // are durable.
        batch.live = batch.entries.items.len;
        self.retained_mu.lock();
        self.retained.append(self.allocator, batch) catch
            std.log.warn("rove-blob coordinator: retained.append OOM", .{});
        self.retained_by_batch.put(self.allocator, batch.retain_id, batch) catch
            std.log.warn("rove-blob coordinator: retained_by_batch.put OOM", .{});
        self.retained_mu.unlock();

        // Per-entry: update each (worker_id, seq) refs slot + advance
        // durable_seq. Cross-tenant pool intentionally mixes workers
        // inside one batch so we walk per-entry, not per-batch.
        for (batch.entries.items) |entry| {
            const w = &self.workers[entry.worker_id];
            w.mu.lock();
            const slot: RefSlot = if (ok)
                .{ .durable = .{
                    // Minted at seal, not here: the object is named by
                    // its content, so the ref exists as soon as the
                    // layout does.
                    .ref = entry.ref,
                    // Borrowed view of the retained submission bytes.
                    // The SealedSubEntry owns them until the entry is
                    // `release`d (or coord deinit); the batch was
                    // retained just above, so this slice is valid for
                    // every `readBody` until release.
                    .bytes = entry.bytes,
                    .retain_id = batch.retain_id,
                } }
            else
                .{ .failed = batch.retain_id };
            w.refs.put(self.allocator, entry.seq, slot) catch {};
            if (ok) removeFromSorted(&w.unfinished, entry.seq);
            self.recomputeDurableSeqLocked(w);
            w.cond.broadcast();
            w.mu.unlock();
        }

        // Free an executor slot — wake drainer if waiting.
        self.exec_mu.lock();
        self.in_flight_batches -= 1;
        self.exec_slack_cond.signal();
        self.exec_mu.unlock();
    }

    /// Bounded exponential backoff on `Error.SlowDown`. Returns
    /// true on commit, false on terminal fail (any non-SlowDown
    /// error OR SlowDown after `retry_max_attempts`).
    fn putWithRetry(self: *Self, store: root.BlobStore, key: []const u8, bytes: []const u8) bool {
        var attempt: u8 = 0;
        var backoff_ns: u64 = self.config.retry_initial_backoff_ns;
        while (true) : (attempt += 1) {
            store.put(key, bytes) catch |err| {
                if (err != root.Error.SlowDown or attempt + 1 >= self.config.retry_max_attempts) {
                    std.log.warn(
                        "rove-blob coordinator: put {s} terminal after {d} attempt(s): {s}",
                        .{ key, attempt + 1, @errorName(err) },
                    );
                    return false;
                }
                const sleep_ns = jitter(backoff_ns, self.config.retry_jitter_pct);
                std.log.warn(
                    "rove-blob coordinator: put {s} SlowDown (attempt {d}/{d}), sleeping {d}ms",
                    .{ key, attempt + 1, self.config.retry_max_attempts, sleep_ns / std.time.ns_per_ms },
                );
                if (self.shutdown_flag.load(.acquire)) return false;
                std.Thread.sleep(sleep_ns);
                backoff_ns = @min(backoff_ns * 2, self.config.retry_max_backoff_ns);
                continue;
            };
            return true;
        }
    }

    fn recomputeDurableSeqLocked(self: *Self, w: *WorkerState) void {
        _ = self;
        // Count semantics: durable_seq = (count of contiguous
        // resolved-as-durable seqs starting from 0). Equivalently,
        // the smallest seq that is NOT durable — which is
        // `min(unfinished)` if any unfinished, else `next_seq`
        // (everything ever submitted has resolved durably).
        const new_hwm: u64 = if (w.unfinished.items.len == 0)
            w.next_seq
        else
            w.unfinished.items[0];
        // Monotonic clamp — must never regress. The contiguous-
        // prefix rule guarantees this; assert to catch logic bugs.
        const prev = w.durable_seq.load(.acquire);
        std.debug.assert(new_hwm >= prev);
        w.durable_seq.store(new_hwm, .release);
    }
};

/// Apply ±pct jitter (e.g. pct=20 → result in [base*0.8, base*1.2]).
/// pct=0 returns base exactly (deterministic in tests).
fn jitter(base_ns: u64, pct: u8) u64 {
    if (pct == 0) return base_ns;
    const span: i64 = @intCast((base_ns * pct) / 100);
    const seed: u64 = @intCast(@as(i64, @truncate(std.time.nanoTimestamp())) & std.math.maxInt(i64));
    var prng = std.Random.DefaultPrng.init(seed);
    const delta = prng.random().intRangeAtMost(i64, -span, span);
    const result: i64 = @as(i64, @intCast(base_ns)) + delta;
    return if (result < 0) 0 else @intCast(result);
}

fn removeFromSorted(list: *std.ArrayListUnmanaged(u64), seq: u64) void {
    // Binary search would be O(log N) but the list is small in
    // practice (bounded by in-flight submissions per worker).
    // Linear scan is fine.
    for (list.items, 0..) |s, i| {
        if (s == seq) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// Test shorthand for a queue id literal.
fn qid(n: u8) QueueId {
    return @enumFromInt(n);
}

/// Two tenant hashes, for tests where the pool's cross-tenant mixing is
/// the thing under test rather than an incidental detail.
const T_A: u64 = 0xA11CE;
const T_B: u64 = 0xB0B;

/// In-memory blob store fixture for tests. Mirrors the MemBlobStore
/// pattern in `src/bodies/root.zig`. Optional per-key-prefix delay
/// + "always fail" mode lets us drive out-of-order completion and
/// terminal-failure tests without standing up real S3.
const TestStore = struct {
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    objects: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Per-PUT delay in nanoseconds. Applied to every PUT
    /// indiscriminately (the cross-tenant pool means we can't
    /// route delays by tenant prefix anymore). Tests requiring
    /// asymmetric delays use multiple coordinators.
    put_delay_ns: u64 = 0,
    always_fail: bool = false,
    /// When > 0, the next PUT returns Error.SlowDown and this counter
    /// decrements. Subsequent PUTs succeed normally (unless
    /// `always_fail` is set).
    slowdown_count: u32 = 0,
    /// Total PUT attempts observed (including those that errored).
    /// Used by retry tests to confirm the executor actually retried.
    put_attempts: std.atomic.Value(u32) = .init(0),

    fn init(allocator: std.mem.Allocator) TestStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestStore) void {
        self.mu.lock();
        var obj_it = self.objects.iterator();
        while (obj_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.objects.deinit(self.allocator);
        self.mu.unlock();
    }

    fn putImpl(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *TestStore = @ptrCast(@alignCast(ptr));
        _ = self.put_attempts.fetchAdd(1, .monotonic);
        if (self.put_delay_ns > 0) std.Thread.sleep(self.put_delay_ns);
        if (self.always_fail) return root.Error.Io;

        self.mu.lock();
        if (self.slowdown_count > 0) {
            self.slowdown_count -= 1;
            self.mu.unlock();
            return root.Error.SlowDown;
        }
        defer self.mu.unlock();
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const bytes_copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(bytes_copy);
        const gop = try self.objects.getOrPut(self.allocator, key_copy);
        if (gop.found_existing) {
            self.allocator.free(key_copy);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = bytes_copy;
    }

    fn getImpl(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *TestStore = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        const v = self.objects.get(key) orelse return root.Error.NotFound;
        return try allocator.dupe(u8, v);
    }

    fn existsImpl(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *TestStore = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        return self.objects.contains(key);
    }

    fn deleteImpl(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *TestStore = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        if (self.objects.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    const vtable: root.BlobStore.VTable = .{
        .put = putImpl,
        .get = getImpl,
        .exists = existsImpl,
        .delete = deleteImpl,
    };

    fn blobStore(self: *TestStore) root.BlobStore {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "coordinator: submit advances durable_seq when batch commits" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 2,
    });
    defer coord.deinit();

    const seq = try coord.submit(qid(0), T_A, "hello world");
    try testing.expectEqual(@as(u64, 0), seq);

    try coord.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(qid(0)));

    const ref = try coord.bodyRef(qid(0), 0);
    try testing.expectEqual(@as(u32, 11), ref.len);
    // Past the header + entry table — the payload does not start at 0.
    try testing.expect(ref.offset >= pool_object.HEADER_LEN);
    try testing.expect(!ref.isNone());

    // The bytes landed under the key the REF names — the ref carries the
    // stamp and digest, so a reader rebuilds the key with no lookup.
    var leaf_buf: [pool_object.LEAF_LEN]u8 = undefined;
    const leaf = ref.leaf(&leaf_buf);
    store.mu.lock();
    const stored = store.objects.get(leaf) orelse {
        store.mu.unlock();
        return error.NotStored;
    };
    store.mu.unlock();

    // The object names itself: its digest is the one the ref carries.
    try testing.expectEqualSlices(u8, &ref.digest, &pool_object.digestOf(stored));
    // And the ref resolves through the object's own entry table, not by
    // slicing at face value.
    try testing.expectEqualStrings("hello world", (try pool_object.resolve(stored, ref)).?);
}

test "coordinator: the key is content-derived, so two nodes cannot collide" {
    // The failure this replaces: two coordinators on different nodes mint
    // the same counter id, the second PUT overwrites the first, and the
    // loser's ref resolves to the other's bytes. Same store, same seal
    // instant, different content — the names must still differ.
    const fixedStamp = struct {
        fn f() u64 {
            return 1_700_000_000_000;
        }
    }.f;

    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    const cfg: Config = .{ .worker_count = 1, .executor_size = 1, .now_unix_ms = fixedStamp };
    const node_a = try BlobCoordinator.init(testing.allocator, store.blobStore(), cfg);
    defer node_a.deinit();
    const node_b = try BlobCoordinator.init(testing.allocator, store.blobStore(), cfg);
    defer node_b.deinit();

    _ = try node_a.submit(qid(0), T_A, "tenant a's body");
    _ = try node_b.submit(qid(0), T_B, "tenant b's body");
    try node_a.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    try node_b.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);

    const ref_a = try node_a.bodyRef(qid(0), 0);
    const ref_b = try node_b.bodyRef(qid(0), 0);
    try testing.expect(!std.mem.eql(u8, &ref_a.digest, &ref_b.digest));

    // Both objects survive, and each ref reads back its OWN bytes.
    store.mu.lock();
    defer store.mu.unlock();
    var buf_a: [pool_object.LEAF_LEN]u8 = undefined;
    var buf_b: [pool_object.LEAF_LEN]u8 = undefined;
    const obj_a = store.objects.get(ref_a.leaf(&buf_a)) orelse return error.NotStored;
    const obj_b = store.objects.get(ref_b.leaf(&buf_b)) orelse return error.NotStored;
    try testing.expectEqualStrings("tenant a's body", (try pool_object.resolve(obj_a, ref_a)).?);
    try testing.expectEqualStrings("tenant b's body", (try pool_object.resolve(obj_b, ref_b)).?);
}

test "coordinator: the sealed object carries a valid GC header" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        // One executor: the drain pass coalesces both submissions into
        // one object, which is the cross-tenant case the header exists
        // to describe.
        .executor_size = 1,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "alpha");
    _ = try coord.submit(qid(1), T_B, "bravo");
    try coord.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(qid(1), 1, 5 * std.time.ns_per_s);

    const ref = try coord.bodyRef(qid(0), 0);
    var leaf_buf: [pool_object.LEAF_LEN]u8 = undefined;
    store.mu.lock();
    defer store.mu.unlock();
    const obj = store.objects.get(ref.leaf(&leaf_buf)) orelse return error.NotStored;

    // Every object the coordinator writes is structurally sound: the
    // entry table describes exactly the payload that follows it.
    const h = try pool_object.validate(obj);
    try testing.expectEqual(ref.written_unix_ms, h.written_unix_ms);
    try testing.expect(h.count >= 1);

    // A sweep learns membership from the head alone. When both landed in
    // one object, both tenants are named there.
    var saw_a = false;
    var i: u32 = 0;
    while (i < h.count) : (i += 1) {
        const e = try pool_object.decodeEntry(obj, i);
        if (e.tenant == T_A) saw_a = true;
        // Tenants appear as the hash they were submitted under — never a
        // name, in an object many tenants share.
        try testing.expect(e.tenant == T_A or e.tenant == T_B);
    }
    try testing.expect(saw_a);
}

test "coordinator: HWM is monotonic across in-flight + queued seqs" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // Slow every PUT so multiple submits queue before the first
    // completes; the drainer normally coalesces them into a single
    // batch but with executor_size=1 the second batch waits.
    store.put_delay_ns = 50 * std.time.ns_per_ms;

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "AAAA");
    // Sleep a tick so the first submission is sealed into its own
    // batch before the next two land.
    std.Thread.sleep(5 * std.time.ns_per_ms);
    _ = try coord.submit(qid(0), T_A, "BBBB");
    _ = try coord.submit(qid(0), T_A, "CCCC");

    // Mid-flight: HWM is still 0 (seq 0 not committed yet).
    try testing.expectEqual(@as(u64, 0), coord.durableSeq(qid(0)));

    // After all batches commit, HWM jumps to 3.
    try coord.waitForSeq(qid(0), 3, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 3), coord.durableSeq(qid(0)));
}

test "coordinator: rejects oversized submit" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .max_batch_bytes = 1024,
    });
    defer coord.deinit();

    const big = try testing.allocator.alloc(u8, 2048);
    defer testing.allocator.free(big);
    try testing.expectError(Error.SubmissionTooLarge, coord.submit(qid(0), T_A, big));
}

test "coordinator: rejects invalid worker_id" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        .executor_size = 1,
    });
    defer coord.deinit();

    try testing.expectError(Error.InvalidWorkerId, coord.submit(qid(7), T_A, "x"));
}

test "coordinator: terminal failure stalls durable_seq + bodyRef returns PutFailed" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    store.always_fail = true;

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
    });
    defer coord.deinit();

    const seq = try coord.submit(qid(0), T_A, "doomed");
    try testing.expectEqual(@as(u64, 0), seq);

    // Poll until the executor has marked the seq as failed in refs.
    // durable_seq sticks at 0 forever (seq 0 unfinished + failed).
    const deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (coord.bodyRef(qid(0), 0)) |_| unreachable else |err| {
            if (err == Error.PutFailed) break;
            if (err != Error.UnknownSeq) return err;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    } else return error.TestTimeout;

    try testing.expectEqual(@as(u64, 0), coord.durableSeq(qid(0)));
    try testing.expectError(Error.PutFailed, coord.bodyRef(qid(0), 0));
}

test "coordinator: readBody returns submitted bytes from RAM" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        .executor_size = 2,
    });
    defer coord.deinit();

    const s0 = try coord.submit(qid(0), T_A, "hello chunk zero");
    const s1 = try coord.submit(qid(0), T_A, "second chunk!!");
    const sw = try coord.submit(qid(1), T_A, "other worker");

    try coord.waitForSeq(qid(0), 2, 5 * std.time.ns_per_s);
    try coord.waitForSeq(qid(1), 1, 5 * std.time.ns_per_s);

    const b0 = try coord.readBody(qid(0), s0, testing.allocator);
    defer testing.allocator.free(b0);
    try testing.expectEqualStrings("hello chunk zero", b0);

    const b1 = try coord.readBody(qid(0), s1, testing.allocator);
    defer testing.allocator.free(b1);
    try testing.expectEqualStrings("second chunk!!", b1);

    const bw = try coord.readBody(qid(1), sw, testing.allocator);
    defer testing.allocator.free(bw);
    try testing.expectEqualStrings("other worker", bw);

    // Never-submitted seq → UnknownSeq.
    try testing.expectError(Error.UnknownSeq, coord.readBody(qid(0), 999, testing.allocator));
}

test "coordinator: release frees retained batch when fully consumed" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        .executor_size = 1, // one executor → both submits seal into one batch
    });
    defer coord.deinit();

    const s0 = try coord.submit(qid(0), T_A, "alpha");
    const s1 = try coord.submit(qid(0), T_A, "bravo");
    const sw = try coord.submit(qid(1), T_A, "charlie");
    try coord.waitForSeq(qid(0), 2, 5 * std.time.ns_per_s);
    try coord.waitForSeq(qid(1), 1, 5 * std.time.ns_per_s);

    // All readable before release; some batch(es) retained. (Whether
    // the three submits seal into one or several batches is timing-
    // dependent, so don't assert an exact count here.)
    const b0 = try coord.readBody(qid(0), s0, testing.allocator);
    testing.allocator.free(b0);
    coord.retained_mu.lock();
    try testing.expect(coord.retained.items.len >= 1);
    coord.retained_mu.unlock();

    // Releasing a durable seq succeeds + drops its ref (readBody →
    // UnknownSeq) but leaves the others consumable.
    try testing.expect(coord.release(qid(0), s0));
    try testing.expectError(Error.UnknownSeq, coord.readBody(qid(0), s0, testing.allocator));
    const b1 = try coord.readBody(qid(0), s1, testing.allocator);
    testing.allocator.free(b1);

    // Releasing EVERY submitted seq frees all retained state — the
    // invariant: no batch outlives consumption (regardless of how they
    // were batched).
    try testing.expect(coord.release(qid(0), s1));
    try testing.expect(coord.release(qid(1), sw));
    coord.retained_mu.lock();
    try testing.expectEqual(@as(usize, 0), coord.retained.items.len);
    try testing.expectEqual(@as(usize, 0), coord.retained_by_batch.count());
    coord.retained_mu.unlock();
    try testing.expectError(Error.UnknownSeq, coord.readBody(qid(0), s1, testing.allocator));

    // Releasing an already-released / unknown seq returns false (the
    // "retry later" signal — here it's terminal, but the caller treats
    // false as "not yet").
    try testing.expect(!coord.release(qid(0), s0));
    try testing.expect(!coord.release(qid(1), 12345));

    // A never-durable seq: release returns false (retry later), and a
    // later retry after it becomes durable succeeds.
    const s2 = try coord.submit(qid(0), T_A, "delta");
    // Before durability the ref isn't set → release defers.
    if (coord.durableSeq(qid(0)) <= s2) try testing.expect(!coord.release(qid(0), s2));
    try coord.waitForSeq(qid(0), s2 + 1, 5 * std.time.ns_per_s);
    try testing.expect(coord.release(qid(0), s2));
}

test "coordinator: per-worker HWMs are independent" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 3,
        .executor_size = 4,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "a");
    _ = try coord.submit(qid(1), T_A, "b");
    _ = try coord.submit(qid(2), T_A, "c");

    try coord.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(qid(1), 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(qid(2), 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(qid(0)));
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(qid(1)));
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(qid(2)));
}

test "coordinator: retries SlowDown then succeeds" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // First 3 attempts return SlowDown; 4th succeeds.
    store.slowdown_count = 3;

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        // Tight retry timing so the test runs quickly.
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_max_backoff_ns = 10 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "persistent");

    try coord.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(qid(0)));
    _ = try coord.bodyRef(qid(0), 0); // .durable, no error
    try testing.expectEqual(@as(u32, 4), store.put_attempts.load(.monotonic));
}

test "coordinator: retry budget exhausted → terminal PutFailed" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // 100 SlowDowns; budget is 5 attempts. After 5, terminal fail.
    store.slowdown_count = 100;

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_max_backoff_ns = 10 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "doomed");

    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (coord.bodyRef(qid(0), 0)) |_| unreachable else |err| {
            if (err == Error.PutFailed) break;
            if (err != Error.UnknownSeq) return err;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    } else return error.TestTimeout;

    try testing.expectEqual(@as(u64, 0), coord.durableSeq(qid(0)));
    try testing.expectEqual(@as(u32, 5), store.put_attempts.load(.monotonic));
}

test "coordinator: non-SlowDown error is terminal on first attempt" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    store.always_fail = true; // returns Error.Io, not SlowDown

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "doomed");

    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (coord.bodyRef(qid(0), 0)) |_| unreachable else |err| {
            if (err == Error.PutFailed) break;
            if (err != Error.UnknownSeq) return err;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    } else return error.TestTimeout;

    // Exactly one PUT attempt — no retries for non-SlowDown errors.
    try testing.expectEqual(@as(u32, 1), store.put_attempts.load(.monotonic));
}

test "coordinator: cross-tenant pool — different workers share one batch" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // Hold the first PUT long enough that both submits land before
    // the drainer picks them up. With executor_size=1 the drainer
    // waits, accumulating both into one drain pass and (since both
    // fit under max_batch_bytes) one SealedBatch / one S3 object.
    store.put_delay_ns = 0; // no delay; rely on the drainer's natural batching

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        .executor_size = 4,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "AAAA");
    _ = try coord.submit(qid(1), T_A, "BBBB");

    try coord.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(qid(1), 1, 5 * std.time.ns_per_s);

    const ref0 = try coord.bodyRef(qid(0), 0);
    const ref1 = try coord.bodyRef(qid(1), 0);
    // If both submissions made it into the same drain pass, they
    // share a batch_id. The drainer's behavior is timing-dependent,
    // so we only assert the weaker contract: distinct workers can
    // resolve durably without collision and reference valid bytes.
    _ = ref0;
    _ = ref1;
    try testing.expect(coord.durableSeq(qid(0)) == 1);
    try testing.expect(coord.durableSeq(qid(1)) == 1);
}

test "coordinator: executor_size knob bounds concurrency" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // Every PUT takes 100ms. Cross-tenant pool default behavior is
    // to coalesce all pending submits into one batch; setting
    // max_batch_bytes=1 forces one batch per submit so executor_size
    // is the actual concurrency lever.
    store.put_delay_ns = 100 * std.time.ns_per_ms;

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .max_batch_bytes = 1,
    });
    defer coord.deinit();

    const t0 = std.time.nanoTimestamp();
    _ = try coord.submit(qid(0), T_A, "1");
    _ = try coord.submit(qid(0), T_A, "2");
    _ = try coord.submit(qid(0), T_A, "3");

    try coord.waitForSeq(qid(0), 3, 5 * std.time.ns_per_s);
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - t0);
    // 3 serial 100ms PUTs => >= 300ms.
    try testing.expect(elapsed_ns >= 280 * std.time.ns_per_ms);
}

test "coordinator: PUTs the LEAF — its store is already scoped to the pool" {
    // The seam a no-prefix fixture cannot see. In production this
    // coordinator's `BlobStore` is opened at `{key_prefix_base}_pool/`,
    // while the body door reads from the content base and rebuilds
    // `_pool/{stamp}-{digest}` from the ref. If the writer PUT the
    // prefixed form the object would land at `_pool/_pool/…` and every
    // reference to it would resolve to a 410 — which is exactly what the
    // door smokes reported when this was wrong.
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
    });
    defer coord.deinit();

    _ = try coord.submit(qid(0), T_A, "body");
    try coord.waitForSeq(qid(0), 1, 5 * std.time.ns_per_s);
    const ref = try coord.bodyRef(qid(0), 0);

    store.mu.lock();
    defer store.mu.unlock();
    var it = store.objects.keyIterator();
    const stored_key = it.next().?.*;
    try testing.expect(!std.mem.startsWith(u8, stored_key, pool_object.PREFIX));

    // And the two forms agree: the leaf is what the door's key is, minus
    // the prefix its own handle does not supply.
    var key_buf: [pool_object.KEY_LEN]u8 = undefined;
    const door_key = ref.key(&key_buf);
    try testing.expectEqualStrings(door_key[pool_object.PREFIX.len..], stored_key);
}
