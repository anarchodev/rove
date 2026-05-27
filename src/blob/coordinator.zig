//! Process-global write coordinator for object-storage PUTs.
//!
//! See `docs/blob-coordinator-plan.md` for the full design. This file
//! ships Phase 1 of that plan: skeleton + per-worker MPSC queues +
//! single drainer thread + K=32 executor pool. 503 retry lands in
//! Phase 2; production wiring (body flush / log flush) in Phases 3–4.
//!
//! Architecture (plan §3.2):
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
//!                                  (contiguous-prefix rule, §5.1)
//!
//! API (plan §3.1) mirrors raft's commit_index:
//!   - `submit` → monotonic per-worker `seq` starting at 0
//!   - `durableSeq(worker)` → count of resolved-as-durable seqs in
//!     the contiguous prefix from 0. Caller checks
//!     `my_seq < durableSeq(worker)` to determine durability.
//!   - `bodyRef(worker, seq)` → BodyRef once `seq < durableSeq`
//!
//! Count semantics (vs plan's "seq <= hwm" framing) avoids the
//! sentinel-or-underflow problem when seq 0 is in flight or
//! terminally failed. `durableSeq() == 0` means "nothing durable
//! yet"; `== 1` means "seq 0 is durable"; etc.
//!
//! No tokens, no per-submission condvars. The unpark loop is the
//! caller's existing readiness check; we wake the per-worker
//! condition variable on HWM advance.

const std = @import("std");
const root = @import("root.zig");
const backend_mod = @import("backend.zig");

/// Pointer into the bytes a coordinator submission stored.
///
/// `object_key` is the full key under which the bytes were PUT —
/// callers can `BlobStore.get(object_key)` directly. The slice is
/// owned by the coordinator and remains valid until coordinator
/// deinit (Phase 1 retains forever; production needs a release path).
///
/// `wire_batch_id` is the Phase 3 transitional field for the readset
/// wire format which still serializes `{batch_id, offset, len}`. Per-
/// (tenant, worker) it is locally unique and matches the leaf of
/// `object_key` (`{tenant}/readset-blobs/w{worker_id}/{wire_batch_id:0>20}`).
/// Phase 5 drops `wire_batch_id` once the readset format takes
/// `object_key` directly.
pub const BodyRef = struct {
    object_key: []const u8,
    wire_batch_id: u64,
    offset: u64,
    len: u32,
};

/// Backend wiring. `.single` is the test/fixture path: one BlobStore,
/// keys formed as `{tenant}_pool_{batch_id}` (underscores because
/// validateKey rejects path separators on raw stores).
///
/// `.per_tenant` is the production path: the coordinator lazy-opens a
/// `BlobBackend` per `(tenant_id, worker_id)` with the prefix
/// `{key_prefix_base}{tenant_id}/{subdir}/w{worker_id}/`, mirroring
/// the existing `worker_bodies.openTenantBodies` shape so replay /
/// upload-walker code keeps working unchanged.
pub const BackendKind = union(enum) {
    single: root.BlobStore,
    per_tenant: PerTenantConfig,
};

pub const PerTenantConfig = struct {
    cfg: backend_mod.BackendConfig,
    /// e.g. `"readset-blobs"`. The final S3 prefix per
    /// (tenant, worker) becomes
    /// `{key_prefix_base}{tenant}/{subdir}/w{worker_id}/`.
    subdir: []const u8,
};

pub const Config = struct {
    /// Number of distinct worker threads that will call `submit`.
    /// Each worker's `worker_id` must be in `[0, worker_count)`.
    worker_count: u8,

    /// K — number of concurrent PUTs in flight (plan §3.5).
    executor_size: u8 = 32,

    /// Per-batch byte cap (plan §3.4 safety cap). A single
    /// submission larger than this is rejected with
    /// error.SubmissionTooLarge.
    max_batch_bytes: usize = 16 * 1024 * 1024,

    /// Plan §3.6 — bounded exponential backoff on transient
    /// `Error.SlowDown` (503 / 429). Total attempts including the
    /// first one; once exhausted, the batch terminally fails.
    retry_max_attempts: u8 = 5,
    retry_initial_backoff_ns: u64 = 100 * std.time.ns_per_ms,
    retry_max_backoff_ns: u64 = 5 * std.time.ns_per_s,
    /// Jitter fraction × initial backoff, applied per attempt.
    /// ±20% per the plan. Set to 0 in tests for deterministic
    /// timing.
    retry_jitter_pct: u8 = 20,
};

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
    /// Guards `pending`, `next_seq`, `max_assigned`, `unfinished`,
    /// `refs`. The HWM `durable_seq` is itself atomic; this mutex
    /// also serializes wakeup signalling on `cond`.
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    /// Submissions accepted by `submit` but not yet drained.
    pending: std.ArrayListUnmanaged(Submission) = .empty,

    /// Next seq to assign on `submit`.
    next_seq: u64 = 0,

    // (Was `max_assigned`; redundant with `next_seq`, which equals
    // "count of submits ever".)

    /// Sorted ascending set of seqs that block durable_seq advance.
    /// Includes (a) in-flight seqs (submitted, not yet committed)
    /// and (b) terminally-failed seqs (kept forever — plan §3.6
    /// "durable_seq sticks past a failed seq").
    ///
    /// durable_seq = (min(unfinished) - 1) if non-empty, else
    /// max_assigned. Recomputed on every removal.
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
    /// Owned, dup'd into coordinator's allocator at submit time.
    tenant_id: []u8,
    /// Owned, transferred from caller at submit time.
    bytes: []u8,

    fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.bytes);
    }
};

const RefSlot = union(enum) {
    durable: BodyRef,
    failed,
};

/// One drained-and-sealed batch handed from drainer to executor.
/// Lives until coordinator deinit (BodyRefs borrow `object_key`).
const SealedBatch = struct {
    /// Wire batch_id (per-(tenant, worker) in per_tenant mode;
    /// coord-global in single mode). Used as the BodyRef.wire_batch_id
    /// for Phase 3 wire compat.
    wire_batch_id: u64,
    /// Heap-allocated full object key. In per_tenant mode this is
    /// `{key_prefix_base}{tenant}/{subdir}/w{worker_id}/{wire:0>20}`;
    /// in single mode it is `{tenant}_pool_{wire_batch_id}`. Owned
    /// by the coordinator until deinit. Borrowed by BodyRefs.
    object_key: []u8,
    /// The leaf key the BlobStore.put receives — in per_tenant mode
    /// this is just the `{wire:0>20}` portion (the backend prefix
    /// supplies the rest). In single mode it equals object_key.
    /// Owned alongside `object_key` (single mode: same slice as
    /// object_key; per_tenant: separate small heap alloc).
    leaf_key: []u8,
    /// Source worker — every submission in the batch came from this
    /// worker (single-tenant batches with tenant→worker affinity
    /// guarantee this trivially).
    worker_id: u8,
    /// Source tenant — every submission shares this (one tenant per
    /// batch in v1 per plan §7.A). Borrowed from the first
    /// submission's `tenant_id`, valid as long as the batch is.
    tenant_id: []const u8,
    /// Submissions sealed into this batch. Ownership transferred
    /// from the worker's pending list. Freed at coordinator deinit
    /// (NOT on commit — workers may still query bodyRef).
    submissions: std.ArrayListUnmanaged(Submission) = .empty,
    /// Concatenated bytes in submission order. Heap-allocated;
    /// passed to BlobStore.put. Freed after PUT completes
    /// (committed OR failed — no longer needed).
    payload: ?[]u8 = null,

    fn deinit(self: *SealedBatch, allocator: std.mem.Allocator) void {
        for (self.submissions.items) |*sub| sub.deinit(allocator);
        self.submissions.deinit(allocator);
        if (self.payload) |p| allocator.free(p);
        // leaf_key and object_key may be the same slice in single
        // mode — free leaf_key only when it's separately allocated.
        if (self.leaf_key.ptr != self.object_key.ptr) allocator.free(self.leaf_key);
        allocator.free(self.object_key);
    }
};

/// Per-(tenant, worker_id) state held in production mode. Lazy-opened
/// on first submit for that (tenant, worker_id) pair.
const TenantWorkerSlot = struct {
    backend: backend_mod.BlobBackend,
    /// Cached BlobStore handle — repeated `backend.blobStore()`
    /// calls return the same vtable, but stash it once so the
    /// executor hot path avoids the union switch.
    store: root.BlobStore,
    /// Wire batch_id counter, local to this (tenant, worker_id).
    /// Matches today's per-(tenant, worker) batch_id semantics so
    /// the wire format is unchanged through Phase 3.
    next_batch_id: u64 = 1,
    /// Cached `key_prefix_base + tenant + "/" + subdir + "/w" + worker_id + "/"`
    /// — owned heap slice, used to build BodyRef.object_key.
    full_prefix: []u8,

    fn deinit(self: *TenantWorkerSlot, allocator: std.mem.Allocator) void {
        self.backend.deinit();
        allocator.free(self.full_prefix);
    }
};

pub const BlobCoordinator = struct {
    allocator: std.mem.Allocator,
    backend_kind: BackendKind,
    config: Config,

    /// Production-mode: tenant_id → per-worker array of slots
    /// (length `config.worker_count`). Lazy-populated.
    /// Single-mode: unused.
    tw_mu: std.Thread.Mutex = .{},
    tw_slots: std.StringHashMapUnmanaged([]?*TenantWorkerSlot) = .empty,

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

    /// All sealed batches ever produced, retained for BodyRef
    /// dereference. Phase 1 keeps them forever; production needs
    /// a release/refcount mechanism (out of scope here).
    retained_mu: std.Thread.Mutex = .{},
    retained: std.ArrayListUnmanaged(*SealedBatch) = .empty,

    batch_id_ctr: std.atomic.Value(u64) = .init(0),
    shutdown_flag: std.atomic.Value(bool) = .init(false),

    drainer_thread: std.Thread,
    executor_threads: []std.Thread,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        backend_kind: BackendKind,
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
            .backend_kind = backend_kind,
            .config = config,
            .workers = workers,
            .executor_threads = executors,
            .drainer_thread = undefined,
        };

        // Spawn executors first, then drainer. errdefer joins any
        // that did spawn if a later spawn fails.
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

        // Drain any still-pending submissions (lost on shutdown —
        // matches the lossy posture of the existing flusher).
        for (self.workers) |*w| w.deinit(self.allocator);
        self.allocator.free(self.workers);

        // Free any batches still in the executor queue (never picked
        // up before shutdown).
        for (self.exec_queue.items) |b| {
            b.deinit(self.allocator);
            self.allocator.destroy(b);
        }
        self.exec_queue.deinit(self.allocator);

        // Free retained batches (BodyRef storage).
        for (self.retained.items) |b| {
            b.deinit(self.allocator);
            self.allocator.destroy(b);
        }
        self.retained.deinit(self.allocator);

        // Tear down per-tenant slot cache (production mode).
        {
            self.tw_mu.lock();
            defer self.tw_mu.unlock();
            var it = self.tw_slots.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                for (e.value_ptr.*) |maybe_slot| if (maybe_slot) |s| {
                    s.deinit(self.allocator);
                    self.allocator.destroy(s);
                };
                self.allocator.free(e.value_ptr.*);
            }
            self.tw_slots.deinit(self.allocator);
        }

        self.allocator.free(self.executor_threads);
        self.allocator.destroy(self);
    }

    /// Submit one Msg-worth of bytes (plan §3.7 — submission boundary
    /// = handler activation boundary). Returns the submission's
    /// monotonic per-worker seq.
    ///
    /// `bytes` is dup'd internally — caller retains ownership and
    /// remains free to read/mutate the original. `tenant_id` is
    /// likewise dup'd.
    pub fn submit(
        self: *Self,
        worker_id: u8,
        tenant_id: []const u8,
        bytes: []const u8,
    ) Error!u64 {
        if (self.shutdown_flag.load(.acquire)) return Error.Shutdown;
        if (worker_id >= self.config.worker_count) return Error.InvalidWorkerId;
        if (bytes.len > self.config.max_batch_bytes) return Error.SubmissionTooLarge;

        const tenant_copy = self.allocator.dupe(u8, tenant_id) catch return error.PutFailed;
        errdefer self.allocator.free(tenant_copy);

        const bytes_copy = self.allocator.dupe(u8, bytes) catch return error.PutFailed;
        errdefer self.allocator.free(bytes_copy);

        const w = &self.workers[worker_id];
        w.mu.lock();
        const seq = w.next_seq;
        w.next_seq += 1;
        w.pending.append(self.allocator, .{
            .seq = seq,
            .tenant_id = tenant_copy,
            .bytes = bytes_copy,
        }) catch {
            w.mu.unlock();
            return error.PutFailed;
        };
        // Insert into `unfinished` in sorted order (always at the
        // end, since seqs are monotonic per worker).
        w.unfinished.append(self.allocator, seq) catch {
            w.mu.unlock();
            return error.PutFailed;
        };
        w.mu.unlock();

        // Wake drainer.
        self.drain_mu.lock();
        self.pending_count += 1;
        self.drain_cond.signal();
        self.drain_mu.unlock();

        return seq;
    }

    /// Per-worker high water mark — every submission on this
    /// worker's queue with `seq <= return value` is durable (or
    /// terminally failed; check `bodyRef(seq)` to distinguish).
    pub fn durableSeq(self: *Self, worker_id: u8) u64 {
        std.debug.assert(worker_id < self.config.worker_count);
        return self.workers[worker_id].durable_seq.load(.acquire);
    }

    /// Lookup the outcome for a (worker_id, seq). Caller must only
    /// invoke this AFTER observing `seq <= durableSeq(worker_id)`.
    /// Returns the BodyRef on success, error.PutFailed if the seq
    /// terminally failed, error.UnknownSeq if the seq was never
    /// submitted (caller bug — either misuse or seq out of range).
    pub fn bodyRef(self: *Self, worker_id: u8, seq: u64) Error!BodyRef {
        std.debug.assert(worker_id < self.config.worker_count);
        const w = &self.workers[worker_id];
        w.mu.lock();
        defer w.mu.unlock();
        const slot = w.refs.get(seq) orelse return Error.UnknownSeq;
        return switch (slot) {
            .durable => |ref| ref,
            .failed => Error.PutFailed,
        };
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
        worker_id: u8,
        target_exclusive: u64,
        timeout_ns: u64,
    ) !void {
        std.debug.assert(worker_id < self.config.worker_count);
        const w = &self.workers[worker_id];
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

            // Drain one round-robin pass, sealing per-tenant batches.
            self.drainRoundRobin();
        }
    }

    fn drainRoundRobin(self: *Self) void {
        // Move every worker's pending submissions out under the
        // worker's lock, then bucketize by tenant_id and seal one
        // batch per tenant (subject to executor slack + size cap).
        var i: usize = 0;
        while (i < self.workers.len) : (i += 1) {
            const w = &self.workers[i];
            w.mu.lock();
            if (w.pending.items.len == 0) {
                w.mu.unlock();
                continue;
            }
            var taken = w.pending;
            w.pending = .empty;
            w.mu.unlock();
            defer taken.deinit(self.allocator);

            // Decrement pending_count under drain_mu.
            self.drain_mu.lock();
            self.pending_count -= taken.items.len;
            self.drain_mu.unlock();

            self.sealByTenant(@intCast(i), taken.items) catch |err| {
                std.log.warn(
                    "rove-blob coordinator: sealByTenant worker={d}: {s}",
                    .{ i, @errorName(err) },
                );
                // On seal failure, mark every submission failed so
                // durable_seq sticks visibly rather than silently
                // dropping bytes.
                self.markBatchFailed(@intCast(i), taken.items);
                for (taken.items) |*sub| sub.deinit(self.allocator);
                taken.items.len = 0;
            };
        }
    }

    /// Bucketize one worker's drained submissions by tenant_id and
    /// seal a SealedBatch per tenant. Honors the max_batch_bytes
    /// safety cap by splitting a tenant's submissions across batches
    /// if their total exceeds it.
    fn sealByTenant(
        self: *Self,
        worker_id: u8,
        subs: []Submission,
    ) !void {
        // Group by tenant_id. Preserves within-tenant ordering
        // because we walk in input order (which IS seq order, since
        // workers push in seq order).
        var groups = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)).empty;
        defer {
            var it = groups.valueIterator();
            while (it.next()) |v| v.deinit(self.allocator);
            groups.deinit(self.allocator);
        }

        for (subs, 0..) |sub, idx| {
            const gop = try groups.getOrPut(self.allocator, sub.tenant_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, idx);
        }

        var git = groups.iterator();
        while (git.next()) |g| {
            const tenant = g.key_ptr.*;
            const indices = g.value_ptr.items;
            // Slice the tenant's submissions into <= max_batch_bytes
            // chunks (one or more SealedBatches per tenant).
            var lo: usize = 0;
            while (lo < indices.len) {
                var hi: usize = lo;
                var total: usize = 0;
                while (hi < indices.len) : (hi += 1) {
                    const sz = subs[indices[hi]].bytes.len;
                    if (total + sz > self.config.max_batch_bytes and hi > lo) break;
                    total += sz;
                }
                try self.sealOneBatch(worker_id, tenant, subs, indices[lo..hi], total);
                lo = hi;
            }
        }

        // After sealing, `subs` ownership has transferred into the
        // SealedBatch(es). Clear the source so the caller's defer
        // doesn't double-free.
        for (subs) |*sub| {
            sub.* = .{ .seq = 0, .tenant_id = &.{}, .bytes = &.{} };
        }
    }

    fn sealOneBatch(
        self: *Self,
        worker_id: u8,
        tenant: []const u8,
        all_subs: []Submission,
        indices: []const usize,
        total_bytes: usize,
    ) !void {
        // Wire batch_id assignment + key shape depend on backend
        // kind. In per_tenant mode we mint a per-(tenant, worker)
        // wire_batch_id and the slot owns the full prefix; in
        // single mode we use the coord-global counter with the
        // tenant-leftmost underscore shape (Phase 1 tests).
        const KeyPair = struct { wire: u64, object_key: []u8, leaf_key: []u8 };
        const key_pair: KeyPair = switch (self.backend_kind) {
            .single => blk: {
                const wire = self.batch_id_ctr.fetchAdd(1, .monotonic);
                const full = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}_pool_{d}",
                    .{ tenant, wire },
                );
                break :blk .{ .wire = wire, .object_key = full, .leaf_key = full };
            },
            .per_tenant => blk: {
                const slot = try self.getOrOpenSlot(tenant, worker_id);
                self.tw_mu.lock();
                const wire = slot.next_batch_id;
                slot.next_batch_id += 1;
                self.tw_mu.unlock();
                var leaf_buf: [21]u8 = undefined;
                const leaf_str = std.fmt.bufPrint(&leaf_buf, "{d:0>20}", .{wire}) catch unreachable;
                const leaf_owned = try self.allocator.dupe(u8, leaf_str);
                errdefer self.allocator.free(leaf_owned);
                const full = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s}",
                    .{ slot.full_prefix, leaf_owned },
                );
                break :blk .{ .wire = wire, .object_key = full, .leaf_key = leaf_owned };
            },
        };
        errdefer self.allocator.free(key_pair.object_key);
        errdefer if (key_pair.leaf_key.ptr != key_pair.object_key.ptr) self.allocator.free(key_pair.leaf_key);

        const payload = try self.allocator.alloc(u8, total_bytes);
        errdefer self.allocator.free(payload);

        const batch = try self.allocator.create(SealedBatch);
        errdefer self.allocator.destroy(batch);
        batch.* = .{
            .wire_batch_id = key_pair.wire,
            .object_key = key_pair.object_key,
            .leaf_key = key_pair.leaf_key,
            .worker_id = worker_id,
            .tenant_id = all_subs[indices[0]].tenant_id,
            .payload = payload,
        };
        errdefer batch.submissions.deinit(self.allocator);

        // Move submissions into the batch + concatenate bytes.
        var off: usize = 0;
        for (indices) |idx| {
            const sub = &all_subs[idx];
            @memcpy(payload[off .. off + sub.bytes.len], sub.bytes);
            // Record per-submission offset on the SealedBatch via
            // a parallel offsets array? Simpler: rebuild the
            // (seq → offset, len) map at commit time from the
            // submissions list. Submissions are appended in
            // `indices` order, which equals the offset order.
            try batch.submissions.append(self.allocator, .{
                .seq = sub.seq,
                .tenant_id = sub.tenant_id,
                .bytes = sub.bytes,
            });
            // Null out the source so caller's defer doesn't free.
            sub.tenant_id = &.{};
            sub.bytes = &.{};
            off += batch.submissions.items[batch.submissions.items.len - 1].bytes.len;
        }

        // Hand to executor.
        self.exec_mu.lock();
        defer self.exec_mu.unlock();
        try self.exec_queue.append(self.allocator, batch);
        self.in_flight_batches += 1;
        self.exec_cond.signal();
    }

    /// Used by drainer on seal failure — mark every submission in
    /// the batch failed so durable_seq sticks rather than silently
    /// advancing. (Plan §3.6: PUT failure must surface visibly.)
    fn markBatchFailed(self: *Self, worker_id: u8, subs: []Submission) void {
        const w = &self.workers[worker_id];
        w.mu.lock();
        defer w.mu.unlock();
        for (subs) |sub| {
            w.refs.put(self.allocator, sub.seq, .failed) catch continue;
        }
        self.recomputeDurableSeqLocked(w);
        w.cond.broadcast();
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
        const store = self.storeForBatch(batch);
        const ok = self.putWithRetry(store, batch.leaf_key, payload);

        // Free the payload — no longer needed (success or failure).
        self.allocator.free(payload);
        batch.payload = null;

        const w = &self.workers[batch.worker_id];
        w.mu.lock();
        var off: u64 = 0;
        for (batch.submissions.items) |sub| {
            const slot: RefSlot = if (ok)
                .{ .durable = .{
                    .object_key = batch.object_key,
                    .wire_batch_id = batch.wire_batch_id,
                    .offset = off,
                    .len = @intCast(sub.bytes.len),
                } }
            else
                .failed;
            w.refs.put(self.allocator, sub.seq, slot) catch {};
            off += sub.bytes.len;
        }

        if (ok) {
            // Remove sealed seqs from `unfinished` (committed →
            // contributes to durable_seq advance). On fail, the
            // seqs stay (sticks past failure — §3.6).
            for (batch.submissions.items) |sub| {
                removeFromSorted(&w.unfinished, sub.seq);
            }
        }
        self.recomputeDurableSeqLocked(w);
        w.cond.broadcast();
        w.mu.unlock();

        // Retain the batch for BodyRef dereference.
        self.retained_mu.lock();
        self.retained.append(self.allocator, batch) catch {
            // OOM appending: drop the batch on the floor. BodyRefs
            // now dangle. Rare — log loudly.
            std.log.warn("rove-blob coordinator: retained.append OOM", .{});
        };
        self.retained_mu.unlock();

        // Free an executor slot — wake drainer if waiting.
        self.exec_mu.lock();
        self.in_flight_batches -= 1;
        self.exec_slack_cond.signal();
        self.exec_mu.unlock();
    }

    /// Open (or fetch from cache) a per-(tenant, worker) backend
    /// slot. Production mode only — panics if backend_kind isn't
    /// `.per_tenant`. The slot is allocated on first access for
    /// that (tenant, worker) pair and lives until coord deinit.
    fn getOrOpenSlot(self: *Self, tenant: []const u8, worker_id: u8) !*TenantWorkerSlot {
        const pt = switch (self.backend_kind) {
            .per_tenant => |p| p,
            .single => unreachable,
        };

        self.tw_mu.lock();
        defer self.tw_mu.unlock();

        const gop = try self.tw_slots.getOrPut(self.allocator, tenant);
        if (!gop.found_existing) {
            // Allocate the per-worker slot array.
            const dup_key = try self.allocator.dupe(u8, tenant);
            errdefer self.allocator.free(dup_key);
            const slots = try self.allocator.alloc(?*TenantWorkerSlot, self.config.worker_count);
            for (slots) |*s| s.* = null;
            // Replace the inserted key with the owned copy.
            // (getOrPut inserted the caller-borrowed slice; swap it.)
            gop.key_ptr.* = dup_key;
            gop.value_ptr.* = slots;
        }

        const slots = gop.value_ptr.*;
        if (slots[worker_id]) |s| return s;

        // Lazy-open the slot.
        const full_prefix = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}/{s}/w{d}/",
            .{ pt.cfg.key_prefix_base, tenant, pt.subdir, worker_id },
        );
        errdefer self.allocator.free(full_prefix);

        // openPerTenant builds `{key_prefix_base}{instance_id}/{subdir}/`.
        // We want `{key_prefix_base}{tenant}/{subdir}/w{worker_id}/`,
        // which is `{instance_id}={tenant}` + `{subdir}={subdir}/w{worker_id}`.
        var subdir_with_worker_buf: [128]u8 = undefined;
        const subdir_with_worker = std.fmt.bufPrint(
            &subdir_with_worker_buf,
            "{s}/w{d}",
            .{ pt.subdir, worker_id },
        ) catch return error.PutFailed;
        var backend = try backend_mod.BlobBackend.openPerTenant(
            self.allocator,
            pt.cfg,
            tenant,
            subdir_with_worker,
        );
        errdefer backend.deinit();

        const slot = try self.allocator.create(TenantWorkerSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{
            .backend = backend,
            .store = undefined, // set after move
            .full_prefix = full_prefix,
        };
        slot.store = slot.backend.blobStore();
        slots[worker_id] = slot;
        return slot;
    }

    /// Resolve the BlobStore for one batch's PUT. Side effect-free
    /// in single mode; in per_tenant mode reads the cached slot
    /// (already opened during sealOneBatch).
    fn storeForBatch(self: *Self, batch: *SealedBatch) root.BlobStore {
        return switch (self.backend_kind) {
            .single => |s| s,
            .per_tenant => blk: {
                self.tw_mu.lock();
                defer self.tw_mu.unlock();
                const slots = self.tw_slots.get(batch.tenant_id) orelse unreachable;
                break :blk slots[batch.worker_id].?.store;
            },
        };
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
    // Linear scan is fine for Phase 1.
    for (list.items, 0..) |s, i| {
        if (s == seq) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// In-memory blob store fixture for tests. Mirrors the MemBlobStore
/// pattern in `src/bodies/root.zig`. Optional per-key-prefix delay
/// + "always fail" mode lets us drive out-of-order completion and
/// terminal-failure tests without standing up real S3.
const TestStore = struct {
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    objects: std.StringHashMapUnmanaged([]u8) = .empty,
    delays: std.StringHashMapUnmanaged(u64) = .empty, // tenant-prefix → ns
    always_fail: bool = false,
    /// When > 0, the next PUT returns Error.SlowDown and this counter
    /// decrements. Subsequent PUTs succeed normally (unless
    /// `always_fail` is set). Counts total attempts (across all
    /// keys) — tests typically issue one key so this is keyed to
    /// "the next N PUT attempts".
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
        var delay_it = self.delays.iterator();
        while (delay_it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.delays.deinit(self.allocator);
        self.mu.unlock();
    }

    /// Set a per-tenant-prefix delay (applied to any key whose
    /// formatted name starts with `prefix`). Coordinator's object
    /// keys are `{tenant}_pool_{batch_id}`, so a prefix of
    /// `"tenant-fast"` matches everything for that tenant.
    fn setDelay(self: *TestStore, prefix: []const u8, ns: u64) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const dup = try self.allocator.dupe(u8, prefix);
        const gop = try self.delays.getOrPut(self.allocator, dup);
        if (gop.found_existing) self.allocator.free(dup);
        gop.value_ptr.* = ns;
    }

    fn lookupDelay(self: *TestStore, key: []const u8) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.delays.iterator();
        while (it.next()) |e| {
            if (std.mem.startsWith(u8, key, e.key_ptr.*)) return e.value_ptr.*;
        }
        return 0;
    }

    fn putImpl(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *TestStore = @ptrCast(@alignCast(ptr));
        _ = self.put_attempts.fetchAdd(1, .monotonic);
        const delay = self.lookupDelay(key);
        if (delay > 0) std.Thread.sleep(delay);
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

    /// TestStore uses tenant-prefixed pool keys like
    /// `tenant-a_pool_0` which `validateKey` rejects (no `/` is
    /// fine, but the validator also blocks leading `.` and length
    /// limits — our keys pass). Wire via vtable directly.
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

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 2,
    });
    defer coord.deinit();

    const seq = try coord.submit(0, "tenant-a", "hello world");
    try testing.expectEqual(@as(u64, 0), seq);

    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(0));

    const ref = try coord.bodyRef(0, 0);
    try testing.expectEqual(@as(u64, 0), ref.offset);
    try testing.expectEqual(@as(u32, 11), ref.len);

    // The bytes actually landed under the expected key shape.
    store.mu.lock();
    const stored = store.objects.get(ref.object_key) orelse {
        store.mu.unlock();
        return error.NotStored;
    };
    try testing.expectEqualStrings("hello world", stored);
    store.mu.unlock();
}

test "coordinator: HWM is monotonic under out-of-order completion" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // Each tenant's batch gets its own delay. Three tenants → three
    // batches → three executor threads → completions in delay order
    // (50ms, 100ms, 200ms) while submit order is (slow, medium, fast).
    try store.setDelay("tenant-slow", 200 * std.time.ns_per_ms);
    try store.setDelay("tenant-medium", 100 * std.time.ns_per_ms);
    try store.setDelay("tenant-fast", 50 * std.time.ns_per_ms);

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 4,
    });
    defer coord.deinit();

    const seq0 = try coord.submit(0, "tenant-slow", "AAAA");
    const seq1 = try coord.submit(0, "tenant-medium", "BBBB");
    const seq2 = try coord.submit(0, "tenant-fast", "CCCC");
    try testing.expectEqual(@as(u64, 0), seq0);
    try testing.expectEqual(@as(u64, 1), seq1);
    try testing.expectEqual(@as(u64, 2), seq2);

    // After ~75ms, the fast tenant (seq 2) has completed but the
    // contiguous-prefix rule keeps HWM at 0 because seq 0 is still
    // in flight.
    std.Thread.sleep(75 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 0), coord.durableSeq(0));

    // After ~150ms total, medium (seq 1) has also completed. HWM
    // still 0.
    std.Thread.sleep(75 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u64, 0), coord.durableSeq(0));

    // Wait for slow (seq 0) to land. Once it does, HWM jumps to 3
    // (all three resolved durably).
    try coord.waitForSeq(0, 3, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 3), coord.durableSeq(0));
}

test "coordinator: rejects oversized submit" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
        .max_batch_bytes = 1024,
    });
    defer coord.deinit();

    const big = try testing.allocator.alloc(u8, 2048);
    defer testing.allocator.free(big);
    try testing.expectError(Error.SubmissionTooLarge, coord.submit(0, "t", big));
}

test "coordinator: rejects invalid worker_id" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 2,
        .executor_size = 1,
    });
    defer coord.deinit();

    try testing.expectError(Error.InvalidWorkerId, coord.submit(7, "t", "x"));
}

test "coordinator: terminal failure stalls durable_seq + bodyRef returns PutFailed" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    store.always_fail = true;

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
    });
    defer coord.deinit();

    const seq = try coord.submit(0, "tenant-a", "doomed");
    try testing.expectEqual(@as(u64, 0), seq);

    // Poll until the executor has marked the seq as failed in refs.
    // durable_seq sticks at 0 forever (seq 0 unfinished + failed).
    const deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (coord.bodyRef(0, 0)) |_| unreachable else |err| {
            if (err == Error.PutFailed) break;
            if (err != Error.UnknownSeq) return err;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    } else return error.TestTimeout;

    try testing.expectEqual(@as(u64, 0), coord.durableSeq(0));
    try testing.expectError(Error.PutFailed, coord.bodyRef(0, 0));
}

test "coordinator: per-worker HWMs are independent" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 3,
        .executor_size = 4,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "tenant-a", "a");
    _ = try coord.submit(1, "tenant-b", "b");
    _ = try coord.submit(2, "tenant-c", "c");

    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(1, 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(2, 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(0));
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(1));
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(2));
}

test "coordinator: retries SlowDown then succeeds" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // First 3 attempts return SlowDown; 4th succeeds.
    store.slowdown_count = 3;

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
        // Tight retry timing so the test runs quickly.
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_max_backoff_ns = 10 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "tenant-a", "persistent");

    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(0));
    _ = try coord.bodyRef(0, 0); // .durable, no error
    try testing.expectEqual(@as(u32, 4), store.put_attempts.load(.monotonic));
}

test "coordinator: retry budget exhausted → terminal PutFailed" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // 100 SlowDowns; budget is 5 attempts. After 5, terminal fail.
    store.slowdown_count = 100;

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_max_backoff_ns = 10 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "tenant-a", "doomed");

    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (coord.bodyRef(0, 0)) |_| unreachable else |err| {
            if (err == Error.PutFailed) break;
            if (err != Error.UnknownSeq) return err;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    } else return error.TestTimeout;

    try testing.expectEqual(@as(u64, 0), coord.durableSeq(0));
    try testing.expectEqual(@as(u32, 5), store.put_attempts.load(.monotonic));
}

test "coordinator: non-SlowDown error is terminal on first attempt" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    store.always_fail = true; // returns Error.Io, not SlowDown

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "tenant-a", "doomed");

    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (coord.bodyRef(0, 0)) |_| unreachable else |err| {
            if (err == Error.PutFailed) break;
            if (err != Error.UnknownSeq) return err;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    } else return error.TestTimeout;

    // Exactly one PUT attempt — no retries for non-SlowDown errors.
    try testing.expectEqual(@as(u32, 1), store.put_attempts.load(.monotonic));
}

test "coordinator: BodyRef carries wire_batch_id matching the object_key leaf" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 2,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "tenant-a", "first");
    _ = try coord.submit(0, "tenant-b", "second");

    try coord.waitForSeq(0, 2, 5 * std.time.ns_per_s);
    const ref0 = try coord.bodyRef(0, 0);
    const ref1 = try coord.bodyRef(0, 1);

    // Single mode: coord-global counter — wire_batch_ids monotonic.
    try testing.expect(ref0.wire_batch_id != ref1.wire_batch_id);
    // Object key carries the wire_batch_id as the trailing number.
    try testing.expect(std.mem.endsWith(u8, ref0.object_key, "_pool_0") or
        std.mem.endsWith(u8, ref0.object_key, "_pool_1"));
}

test "coordinator: wire_batch_id stable across SlowDown retries" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    store.slowdown_count = 3;

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "tenant-x", "data");
    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);

    const ref = try coord.bodyRef(0, 0);
    // The key under which bytes actually landed equals the BodyRef's
    // object_key — retries did not mint a new key.
    store.mu.lock();
    defer store.mu.unlock();
    try testing.expect(store.objects.contains(ref.object_key));
}

test "coordinator: executor_size knob bounds concurrency" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    // Every PUT takes 100ms. With executor_size=1, three submissions
    // serialize → wall time >= 300ms. With executor_size=4, they
    // overlap → wall time <= 200ms (room for scheduling jitter).
    try store.setDelay("tenant-", 100 * std.time.ns_per_ms);

    const coord = try BlobCoordinator.init(testing.allocator, .{ .single = store.blobStore() }, .{
        .worker_count = 1,
        .executor_size = 1,
    });
    defer coord.deinit();

    const t0 = std.time.nanoTimestamp();
    _ = try coord.submit(0, "tenant-x", "1");
    _ = try coord.submit(0, "tenant-y", "2");
    _ = try coord.submit(0, "tenant-z", "3");

    try coord.waitForSeq(0, 3, 5 * std.time.ns_per_s);
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - t0);
    try testing.expect(elapsed_ns >= 300 * std.time.ns_per_ms);
}
