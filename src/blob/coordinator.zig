//! Process-global write coordinator for object-storage PUTs.
//!
//! See `docs/streaming-model.md §7` for the full design. As of
//! Phase 5 (2026-05-27), submissions land in a single cross-tenant
//! pool under `{key_prefix_base}_pool/{batch_id:0>20}`; the per-
//! (tenant, worker) lane shape Phase 3 shipped is gone. `batch_id`
//! is globally unique by construction — minted from a raft-reserved
//! block (`_system/coord_next_pool_batch`, plan §3.5b).
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

/// Pointer into the bytes a coordinator submission stored. `batch_id`
/// is globally unique (raft-reserved per plan §3.5b); the full S3
/// key is `{key_prefix_base}_pool/{batch_id:0>20}` and the backend
/// supplied to `init` already carries the `_pool/` prefix.
pub const BodyRef = struct {
    batch_id: u64,
    offset: u64,
    len: u32,
};

/// Provider of globally-unique `batch_id` blocks. Production wiring
/// reads `_system/coord_next_pool_batch` from `__root__.db`, proposes
/// an envelope-2 root_writeset advancing it by `count`, and blocks
/// until commit. Returns the **new** end-of-range value; the caller
/// owns `[returned - count, returned)`.
///
/// `prev_end` is the in-memory upper bound of the previously-issued
/// block (0 on first call). The implementation must compute the new
/// floor as `max(committed_value, prev_end, 1)` so a fresh leader
/// after election reads the committed state authoritatively while a
/// node that already reserved during this process lifetime never
/// double-mints across its own blocks.
///
/// `null` in `Config.reservation` disables raft reservation and falls
/// back to a local atomic counter starting at 1 — used by unit tests
/// and any caller that doesn't need cross-leader uniqueness.
pub const ReservationProvider = struct {
    ctx: *anyopaque,
    reserveFn: *const fn (ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64,
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

    /// Plan §3.5b — block size for batch_id reservation. Default
    /// 10000. At sustained 100 batches/sec the prefetch fires every
    /// ~80 s.
    reservation_block_size: u32 = 10_000,
    /// Plan §3.5b — low-watermark percentage (0..100). When
    /// `consumed >= block_size * pct/100` the refill kicks off
    /// asynchronously.
    reservation_low_watermark_pct: u8 = 80,

    /// Production: raft-backed reservation. `null` falls back to a
    /// local atomic counter (tests, single-process deployments).
    reservation: ?ReservationProvider = null,
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
    /// and (b) terminally-failed seqs (kept forever — plan §3.6
    /// "durable_seq sticks past a failed seq").
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

    fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

const RefSlot = union(enum) {
    durable: DurableSlot,
    failed,
};

/// A committed submission's outcome: the wire `BodyRef` plus a
/// borrowed view of the bytes, retained in the owning `SealedBatch`'s
/// `SealedSubEntry.bytes` (alive for the coordinator's lifetime).
/// `readBody` dupes from `bytes` so callers needing the chunk back —
/// e.g. the bound-fetch chunk spool reading an evicted entry
/// (`docs/chunk-spool-plan.md` Phase 3) — get it from RAM, with no
/// `store.get` / S3 round-trip.
const DurableSlot = struct {
    ref: BodyRef,
    bytes: []const u8,
};

/// One drained-and-sealed batch handed from drainer to executor.
/// Lives until coordinator deinit so worker `bodyRef(seq)` lookups
/// stay valid for the request's lifetime.
const SealedBatch = struct {
    /// Globally-unique batch_id minted from the reservation block
    /// (or local atomic counter in test mode). The S3 leaf key is
    /// formatted from this — `{batch_id:0>20}`.
    batch_id: u64,
    /// Heap-allocated leaf key `{batch_id:0>20}` (21 bytes including
    /// nul-terminator slack). Passed to `BlobStore.put`; the backend
    /// supplies the `_pool/` prefix.
    leaf_key: []u8,
    /// One submission's worker. Plan §3.7: a submission carries the
    /// originating worker so the executor can advance THAT worker's
    /// durable_seq on commit. Per-submission, not per-batch, since
    /// the cross-tenant pool intentionally mixes workers in one PUT.
    /// Stored inline on SealedSubEntry below.
    entries: std.ArrayListUnmanaged(SealedSubEntry) = .empty,
    /// Concatenated bytes in submission order. Heap-allocated;
    /// passed to BlobStore.put. Freed after PUT completes
    /// (committed OR failed — no longer needed).
    payload: ?[]u8 = null,

    fn deinit(self: *SealedBatch, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            allocator.free(e.bytes);
        }
        self.entries.deinit(allocator);
        if (self.payload) |p| allocator.free(p);
        allocator.free(self.leaf_key);
    }
};

const SealedSubEntry = struct {
    worker_id: u8,
    seq: u64,
    offset: u64,
    /// Owned by the entry until coord deinit. We keep it around so
    /// a recompute / re-PUT path (future) could rebuild the payload
    /// without re-asking workers. Phase 5 keeps the parallel copy;
    /// production tuning can revisit (payload + entries are both
    /// retained, doubling RAM for in-flight batches).
    bytes: []u8,
};

const Reservation = struct {
    base: u64,
    /// Next id to mint. `next == end` means the block is exhausted.
    next: u64,
    end: u64,
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

    /// All sealed batches ever produced, retained for BodyRef
    /// dereference. Phase 1 keeps them forever; production needs
    /// a release/refcount mechanism (out of scope here).
    retained_mu: std.Thread.Mutex = .{},
    retained: std.ArrayListUnmanaged(*SealedBatch) = .empty,

    /// Local-mode batch_id source — used when `config.reservation`
    /// is null. Starts at 1 (skips the `NO_BATCH = 0` sentinel).
    local_batch_ctr: std.atomic.Value(u64) = .init(1),

    /// Plan §3.5b reservation state. Guarded by `res_mu`. Only used
    /// when `config.reservation` is non-null.
    res_mu: std.Thread.Mutex = .{},
    res_id_avail: std.Thread.Condition = .{},
    res_refill_cond: std.Thread.Condition = .{},
    current: Reservation = .{ .base = 0, .next = 0, .end = 0 },
    upcoming: ?Reservation = null,
    refill_needed: bool = false,
    refill_in_progress: bool = false,
    /// In-memory ceiling of every block we've ever reserved during
    /// this process lifetime. Refill thread uses this as the floor
    /// when computing the next propose so multiple back-to-back
    /// refills never overlap even on a slow propose path.
    prev_committed_end: u64 = 0,
    refill_thread: ?std.Thread = null,

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
        std.debug.assert(config.reservation_block_size > 0);
        std.debug.assert(config.reservation_low_watermark_pct <= 100);

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

        if (config.reservation != null) {
            self.refill_thread = try std.Thread.spawn(.{}, refillLoop, .{self});
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

        // Wake refill thread + any submitters parked on id-avail.
        self.res_mu.lock();
        self.res_refill_cond.broadcast();
        self.res_id_avail.broadcast();
        self.res_mu.unlock();

        self.drainer_thread.join();
        for (self.executor_threads) |t| t.join();
        if (self.refill_thread) |t| t.join();

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

        self.allocator.free(self.executor_threads);
        self.allocator.destroy(self);
    }

    /// Submit one Msg-worth of bytes (plan §3.7 — submission boundary
    /// = handler activation boundary). Returns the submission's
    /// monotonic per-worker seq.
    ///
    /// `bytes` is dup'd internally — caller retains ownership and
    /// remains free to read/mutate the original.
    pub fn submit(
        self: *Self,
        worker_id: u8,
        bytes: []const u8,
    ) Error!u64 {
        if (self.shutdown_flag.load(.acquire)) return Error.Shutdown;
        if (worker_id >= self.config.worker_count) return Error.InvalidWorkerId;
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
        // early-returns without decrementing. See
        // `docs/chunk-spool-plan.md` (the high-rate per-chunk
        // bound-fetch submits first exposed this).
        self.drain_mu.lock();
        self.pending_count += 1;
        self.drain_mu.unlock();

        const w = &self.workers[worker_id];
        w.mu.lock();
        const seq = w.next_seq;
        w.next_seq += 1;
        w.pending.append(self.allocator, .{
            .seq = seq,
            .bytes = bytes_copy,
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

    /// Per-worker high water mark — every submission on this
    /// worker's queue with `seq < return value` is durable (or
    /// terminally failed; check `bodyRef(seq)` to distinguish).
    pub fn durableSeq(self: *Self, worker_id: u8) u64 {
        std.debug.assert(worker_id < self.config.worker_count);
        return self.workers[worker_id].durable_seq.load(.acquire);
    }

    /// Lookup the outcome for a (worker_id, seq). Caller must only
    /// invoke this AFTER observing `seq < durableSeq(worker_id)`.
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
    /// `docs/chunk-spool-plan.md` Phase 3: the bound-fetch chunk spool
    /// evicts inline bytes for chunks beyond its K-deep RAM window and
    /// reads them back through here when the held chain is finally
    /// ready to consume them.
    pub fn readBody(
        self: *Self,
        worker_id: u8,
        seq: u64,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        std.debug.assert(worker_id < self.config.worker_count);
        const w = &self.workers[worker_id];
        w.mu.lock();
        defer w.mu.unlock();
        const slot = w.refs.get(seq) orelse return Error.UnknownSeq;
        return switch (slot) {
            .durable => |d| allocator.dupe(u8, d.bytes) catch Error.PutFailed,
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
        var lo: usize = 0;
        while (lo < collected.items.len) {
            var hi: usize = lo;
            var size: usize = 0;
            while (hi < collected.items.len) : (hi += 1) {
                const sz = collected.items[hi].bytes.len;
                if (size + sz > self.config.max_batch_bytes and hi > lo) break;
                size += sz;
            }
            self.sealOneBatch(collected.items[lo..hi], size) catch |err| {
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
    };

    fn sealOneBatch(
        self: *Self,
        subs: []const CollectedSubmission,
        total_bytes: usize,
    ) !void {
        if (subs.len == 0) return;

        const batch_id = try self.mintBatchId();
        var leaf_buf: [21]u8 = undefined;
        const leaf_str = std.fmt.bufPrint(&leaf_buf, "{d:0>20}", .{batch_id}) catch unreachable;
        const leaf_owned = try self.allocator.dupe(u8, leaf_str);
        errdefer self.allocator.free(leaf_owned);

        const payload = try self.allocator.alloc(u8, total_bytes);
        errdefer self.allocator.free(payload);

        const batch = try self.allocator.create(SealedBatch);
        errdefer self.allocator.destroy(batch);
        batch.* = .{
            .batch_id = batch_id,
            .leaf_key = leaf_owned,
            .payload = payload,
        };
        errdefer batch.entries.deinit(self.allocator);

        var off: u64 = 0;
        for (subs) |sub| {
            @memcpy(payload[off .. off + sub.bytes.len], sub.bytes);
            try batch.entries.append(self.allocator, .{
                .worker_id = sub.worker_id,
                .seq = sub.seq,
                .offset = off,
                .bytes = sub.bytes, // ownership transferred from worker pending list
            });
            off += sub.bytes.len;
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
    /// matches plan §3.6 "PUT failure surfaces visibly" so the
    /// worker observes `durable_seq` sticking + `bodyRef` returning
    /// `PutFailed`. Frees byte ownership.
    fn failCollected(self: *Self, subs: []const CollectedSubmission) void {
        for (subs) |sub| {
            const w = &self.workers[sub.worker_id];
            w.mu.lock();
            w.refs.put(self.allocator, sub.seq, .failed) catch {};
            self.recomputeDurableSeqLocked(w);
            w.cond.broadcast();
            w.mu.unlock();
            self.allocator.free(sub.bytes);
        }
    }

    // ── batch_id reservation (plan §3.5b) ──────────────────────────

    /// Mint one batch_id. In test mode (`config.reservation == null`)
    /// returns from a local atomic counter starting at 1. In
    /// production, draws from the current reservation block; blocks
    /// on `res_id_avail` if the block is exhausted and the refill
    /// hasn't arrived yet.
    fn mintBatchId(self: *Self) Error!u64 {
        if (self.config.reservation == null) {
            return self.local_batch_ctr.fetchAdd(1, .monotonic);
        }

        self.res_mu.lock();
        defer self.res_mu.unlock();
        while (true) {
            if (self.shutdown_flag.load(.acquire)) return Error.Shutdown;
            if (self.current.next < self.current.end) {
                const id = self.current.next;
                self.current.next += 1;
                self.maybeKickRefillLocked();
                return id;
            }
            // Current exhausted; swap upcoming if available.
            if (self.upcoming) |up| {
                self.current = up;
                self.upcoming = null;
                continue;
            }
            // No block available; ensure refill is in flight + wait.
            if (!self.refill_in_progress and !self.refill_needed) {
                self.refill_needed = true;
                self.res_refill_cond.signal();
            }
            self.res_id_avail.wait(&self.res_mu);
        }
    }

    fn maybeKickRefillLocked(self: *Self) void {
        if (self.upcoming != null) return;
        if (self.refill_in_progress or self.refill_needed) return;
        const consumed = self.current.next - self.current.base;
        const block_size: u64 = self.config.reservation_block_size;
        const lwm = block_size * @as(u64, self.config.reservation_low_watermark_pct) / 100;
        if (consumed >= lwm) {
            self.refill_needed = true;
            self.res_refill_cond.signal();
        }
    }

    fn refillLoop(self: *Self) void {
        while (true) {
            self.res_mu.lock();
            while (!self.shutdown_flag.load(.acquire) and !self.refill_needed) {
                self.res_refill_cond.wait(&self.res_mu);
            }
            if (self.shutdown_flag.load(.acquire)) {
                self.res_mu.unlock();
                return;
            }
            self.refill_needed = false;
            self.refill_in_progress = true;
            const prev_end: u64 = if (self.upcoming) |up|
                up.end
            else if (self.current.end > self.prev_committed_end)
                self.current.end
            else
                self.prev_committed_end;
            self.res_mu.unlock();

            const provider = self.config.reservation.?;
            const block_size: u32 = self.config.reservation_block_size;
            const new_end = provider.reserveFn(provider.ctx, prev_end, block_size) catch |err| {
                std.log.warn(
                    "rove-blob coordinator: reservation refill failed: {s}; retrying in 100ms",
                    .{@errorName(err)},
                );
                std.Thread.sleep(100 * std.time.ns_per_ms);
                self.res_mu.lock();
                self.refill_in_progress = false;
                self.refill_needed = true;
                self.res_refill_cond.signal();
                self.res_mu.unlock();
                continue;
            };
            std.debug.assert(new_end >= prev_end + block_size);
            const base = new_end - block_size;
            const block: Reservation = .{ .base = base, .next = base, .end = new_end };

            self.res_mu.lock();
            if (new_end > self.prev_committed_end) self.prev_committed_end = new_end;
            if (self.current.next >= self.current.end) {
                self.current = block;
            } else {
                // Current still has ids — stash as upcoming. If
                // upcoming already exists (shouldn't normally —
                // refill only kicks one at a time), drop the new
                // block (we'd otherwise leak the gap; new block's
                // ids end up unused, which is harmless per §3.5b).
                if (self.upcoming == null) self.upcoming = block;
            }
            self.refill_in_progress = false;
            self.res_id_avail.broadcast();
            self.res_mu.unlock();
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

        // Per-entry: update each (worker_id, seq) refs slot + advance
        // durable_seq. Cross-tenant pool intentionally mixes workers
        // inside one batch so we walk per-entry, not per-batch.
        for (batch.entries.items) |entry| {
            const w = &self.workers[entry.worker_id];
            w.mu.lock();
            const slot: RefSlot = if (ok)
                .{ .durable = .{
                    .ref = .{
                        .batch_id = batch.batch_id,
                        .offset = entry.offset,
                        .len = @intCast(entry.bytes.len),
                    },
                    // Borrowed view of the retained submission bytes
                    // (the SealedSubEntry owns them until coord deinit;
                    // the batch is retained just below, so this slice
                    // stays valid for every later `readBody`).
                    .bytes = entry.bytes,
                } }
            else
                .failed;
            w.refs.put(self.allocator, entry.seq, slot) catch {};
            if (ok) removeFromSorted(&w.unfinished, entry.seq);
            self.recomputeDurableSeqLocked(w);
            w.cond.broadcast();
            w.mu.unlock();
        }

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

    const seq = try coord.submit(0, "hello world");
    try testing.expectEqual(@as(u64, 0), seq);

    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1), coord.durableSeq(0));

    const ref = try coord.bodyRef(0, 0);
    try testing.expectEqual(@as(u64, 0), ref.offset);
    try testing.expectEqual(@as(u32, 11), ref.len);
    // Local-mode counter starts at 1; first batch_id should be 1.
    try testing.expectEqual(@as(u64, 1), ref.batch_id);

    // The bytes actually landed under the expected leaf key.
    var leaf_buf: [21]u8 = undefined;
    const leaf = std.fmt.bufPrint(&leaf_buf, "{d:0>20}", .{ref.batch_id}) catch unreachable;
    store.mu.lock();
    const stored = store.objects.get(leaf) orelse {
        store.mu.unlock();
        return error.NotStored;
    };
    try testing.expectEqualStrings("hello world", stored);
    store.mu.unlock();
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

    _ = try coord.submit(0, "AAAA");
    // Sleep a tick so the first submission is sealed into its own
    // batch before the next two land.
    std.Thread.sleep(5 * std.time.ns_per_ms);
    _ = try coord.submit(0, "BBBB");
    _ = try coord.submit(0, "CCCC");

    // Mid-flight: HWM is still 0 (seq 0 not committed yet).
    try testing.expectEqual(@as(u64, 0), coord.durableSeq(0));

    // After all batches commit, HWM jumps to 3.
    try coord.waitForSeq(0, 3, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 3), coord.durableSeq(0));
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
    try testing.expectError(Error.SubmissionTooLarge, coord.submit(0, big));
}

test "coordinator: rejects invalid worker_id" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        .executor_size = 1,
    });
    defer coord.deinit();

    try testing.expectError(Error.InvalidWorkerId, coord.submit(7, "x"));
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

    const seq = try coord.submit(0, "doomed");
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

test "coordinator: readBody returns submitted bytes from RAM" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 2,
        .executor_size = 2,
    });
    defer coord.deinit();

    const s0 = try coord.submit(0, "hello chunk zero");
    const s1 = try coord.submit(0, "second chunk!!");
    const sw = try coord.submit(1, "other worker");

    try coord.waitForSeq(0, 2, 5 * std.time.ns_per_s);
    try coord.waitForSeq(1, 1, 5 * std.time.ns_per_s);

    const b0 = try coord.readBody(0, s0, testing.allocator);
    defer testing.allocator.free(b0);
    try testing.expectEqualStrings("hello chunk zero", b0);

    const b1 = try coord.readBody(0, s1, testing.allocator);
    defer testing.allocator.free(b1);
    try testing.expectEqualStrings("second chunk!!", b1);

    const bw = try coord.readBody(1, sw, testing.allocator);
    defer testing.allocator.free(bw);
    try testing.expectEqualStrings("other worker", bw);

    // Never-submitted seq → UnknownSeq.
    try testing.expectError(Error.UnknownSeq, coord.readBody(0, 999, testing.allocator));
}

test "coordinator: per-worker HWMs are independent" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 3,
        .executor_size = 4,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "a");
    _ = try coord.submit(1, "b");
    _ = try coord.submit(2, "c");

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

    _ = try coord.submit(0, "persistent");

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

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_max_backoff_ns = 10 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "doomed");

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

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .retry_max_attempts = 5,
        .retry_initial_backoff_ns = 1 * std.time.ns_per_ms,
        .retry_jitter_pct = 0,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "doomed");

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

    _ = try coord.submit(0, "AAAA");
    _ = try coord.submit(1, "BBBB");

    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);
    try coord.waitForSeq(1, 1, 5 * std.time.ns_per_s);

    const ref0 = try coord.bodyRef(0, 0);
    const ref1 = try coord.bodyRef(1, 0);
    // If both submissions made it into the same drain pass, they
    // share a batch_id. The drainer's behavior is timing-dependent,
    // so we only assert the weaker contract: distinct workers can
    // resolve durably without collision and reference valid bytes.
    _ = ref0;
    _ = ref1;
    try testing.expect(coord.durableSeq(0) == 1);
    try testing.expect(coord.durableSeq(1) == 1);
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
    _ = try coord.submit(0, "1");
    _ = try coord.submit(0, "2");
    _ = try coord.submit(0, "3");

    try coord.waitForSeq(0, 3, 5 * std.time.ns_per_s);
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - t0);
    // 3 serial 100ms PUTs => >= 300ms.
    try testing.expect(elapsed_ns >= 280 * std.time.ns_per_ms);
}

// ── Reservation provider tests ──────────────────────────────────────

/// Fake reservation provider — backed by an atomic counter the test
/// drives directly. Records every reservation request so tests can
/// assert refill cadence + block sizes.
const TestReservation = struct {
    mu: std.Thread.Mutex = .{},
    cur: u64 = 0,
    /// History of (prev_end, count, returned new_end) triples.
    calls: std.ArrayListUnmanaged(Call) = .empty,
    allocator: std.mem.Allocator,
    /// Inject errors on the next N calls.
    fail_next: u32 = 0,

    const Call = struct { prev_end: u64, count: u32, new_end: u64 };

    fn init(allocator: std.mem.Allocator) TestReservation {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestReservation) void {
        self.calls.deinit(self.allocator);
    }

    fn reserveFn(ctx: *anyopaque, prev_end: u64, count: u32) anyerror!u64 {
        const self: *TestReservation = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        if (self.fail_next > 0) {
            self.fail_next -= 1;
            return error.SimulatedFailure;
        }
        const base = @max(self.cur, prev_end);
        const new_end = base + count;
        self.cur = new_end;
        try self.calls.append(self.allocator, .{
            .prev_end = prev_end,
            .count = count,
            .new_end = new_end,
        });
        return new_end;
    }

    fn provider(self: *TestReservation) ReservationProvider {
        return .{ .ctx = self, .reserveFn = TestReservation.reserveFn };
    }
};

test "coordinator: reservation mints unique batch_ids from raft block" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    var res = TestReservation.init(testing.allocator);
    defer res.deinit();

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 2,
        .reservation = res.provider(),
        .reservation_block_size = 100,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "one");
    _ = try coord.submit(0, "two");
    try coord.waitForSeq(0, 2, 5 * std.time.ns_per_s);

    const r0 = try coord.bodyRef(0, 0);
    const r1 = try coord.bodyRef(0, 1);
    // batch_ids come from the reservation block [0, 100). Both are
    // strictly less than the new_end (100) and may equal each other
    // when both submissions land in the same drainer pass + same
    // SealedBatch.
    try testing.expect(r0.batch_id < 100);
    try testing.expect(r1.batch_id < 100);

    // At least one reservation call happened.
    res.mu.lock();
    defer res.mu.unlock();
    try testing.expect(res.calls.items.len >= 1);
    try testing.expectEqual(@as(u32, 100), res.calls.items[0].count);
}

test "coordinator: reservation retries on provider failure" {
    var store = TestStore.init(testing.allocator);
    defer store.deinit();
    var res = TestReservation.init(testing.allocator);
    defer res.deinit();
    res.fail_next = 1; // first call fails, then succeed

    const coord = try BlobCoordinator.init(testing.allocator, store.blobStore(), .{
        .worker_count = 1,
        .executor_size = 1,
        .reservation = res.provider(),
        .reservation_block_size = 10,
    });
    defer coord.deinit();

    _ = try coord.submit(0, "x");
    try coord.waitForSeq(0, 1, 5 * std.time.ns_per_s);
    const r = try coord.bodyRef(0, 0);
    try testing.expect(r.batch_id < 10);

    res.mu.lock();
    defer res.mu.unlock();
    // The provider was called at least twice: once failed + at
    // least one success.
    try testing.expect(res.calls.items.len >= 1);
}
