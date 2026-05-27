# Blob coordinator — plan

> **Status**: planned, not started — 2026-05-26.
> **Prerequisite reading**: `docs/readset-replication-plan.md` Phase 2
> (per-tenant `BodyBuffer`, `BodyRef`, the park-on-durability gate),
> `docs/logs-plan.md` (worker `LogBuffer` → S3 batch shape),
> [[project-s3-throughput-ceiling]] (the K × S sweep against OVH:
> 117 MB/s wire from this server, ~135 req/s small-object cap, knee
> at K=32–64 for 1–4 MB objects), [[project-inputs-durable-outputs-derivable]]
> (raft inputs, BlobStore as input-cache vs output-cache).
> **Hard prerequisite**: none. The fan-out work shipped
> (`body-flush: per-worker pool` 2026-05-26) is the cheap predecessor;
> this plan is what comes after, when the per-tenant lane structure
> stops being the right surface.

## 1. Goal

One per-process write coordinator for **body bytes** (inbound request
bodies > 16 KB, outbound fetch chunks > 16 KB). Submitters hand it
in-RAM byte buffers and receive back a `BodyRef = {object_key, offset,
len}` once the bytes are durable in object storage. The coordinator:

- Coalesces body submissions into shared pool objects (multiple bodies
  inside one S3 object, demuxed via `BodyRef.(offset, len)`).
- Owns the **PUT parallelism budget for body PUTs** — one K, one place
  to tune against the link, one place to handle 503 SLOWDOWN backoff.
- Returns location receipts that callers store on the readset wire.

After this work, throughput against the S3 link is bounded by the link
and the executor pool size, **not by how customer tenants happen to
hash across leader workers**.

**Scope sharpened 2026-05-27 (Phase 4 descoped):** the coordinator is
for body submissions specifically. Log flush stays on its direct
`BatchStore.put` path because the log read model (indexer LISTs
`_logs/{node_hex}/` and parses each object's self-describing sidecar)
is incompatible with coord's coalescing — see §6 Phase 4 + §10.3.

**Scope revised 2026-05-27 (cross-tenant pool):** Phase 3 shipped
per-(tenant, worker) keys as a transitional shape; Phase 5 collapses
all body submissions into a single flat pool (`_pool/{batch_id:0>20}`)
with `batch_id` made globally unique via raft reservation (§3.5b). The
forcing function is zipf — most tenants are small, and per-tenant
lanes produce too many tiny S3 objects vs the per-account request-rate
cap (~135 req/s small-objects per [[project-s3-throughput-ceiling]]).
Encryption-at-rest for cross-tenant pools is its own phase, deferred.

## 2. Why now — what the per-tenant lane model can't reach

The body-flush fan-out shipped 2026-05-26 (commit `c8a864d`) parallelizes
across tenants ready to flush within a single worker. Bench measured
against OVH from this server (see `scripts/body_throughput_probe.py`):

| Workload | Pre-fan-out | Post-fan-out | Δ |
|---|---|---|---|
| 8 tenants × 32 workers × 1 MB | 22.4 MB/s | 36.2 MB/s | +62% |
| 2 tenants × 80 workers × 1 MB | 49.0 MB/s | 52.0 MB/s | +6% |

The fan-out moves the floor but **cannot lift the ceiling past the
per-tenant lane structure**. Each tenant is hash-routed to one leader
worker; in-flight PUTs node-wide ≈ Σ over workers of (tenants ready
on that worker per tick). With 4 leader workers and typical tenant
distribution, this peaks around K=8. Bench shows K=8 at 1 MB =
~34 MB/s — exactly what we measured.

To push K higher under the current design we'd need either more
leader workers (cost: dispatch fan-out + EasyPool contention) or more
ready-tenants-per-worker (cost: customer traffic shape, not ours to
control). Neither moves the architecture in a useful direction.

Three structural limits the fan-out left intact, in order:

1. **K is structurally bounded by hash distribution.** Two hot tenants
   on the same worker serialize through that worker's flusher even if
   six other workers are idle. The bench's 2-tenant case (K=2 forced)
   shows the floor: with the link able to carry K=32 at 4 MB, we leave
   ~50% of wire unused whenever customer load concentrates.
2. **503 SLOWDOWN is unhandled.** Every `BlobStore.put` site (body
   flush, log flush, files-server upload, ACME cert publish, deployment
   manifest) translates a non-2xx into `Error.Io` and drops the bytes.
   Per OVH docs (`docs/blob-coordinator-plan.md` §10.2) 503s are
   expected during bucket sharding events. Today they're silent data
   loss. The fix is the same code at every call site — exactly what
   "centralize in one place" exists for.
3. **Per-source duplication (body side).** Body flush has its own
   BodyBuffer + thresholds + per-worker pool. The body-side flush /
   batching / parallelism / retry was incompletely implemented and
   re-collapses into the coordinator.

   *Update 2026-05-27:* log flush also had its own batching layer but
   it can't fold in — coord's coalescing breaks the log read model
   (§10.3, §6 Phase 4). Logs keep their own path.

## 3. Target shape

### 3.1 API — submit returns a sequence; durability is observed via HWM

```zig
pub const BlobCoordinator = struct {
    /// Worker hands one Msg-worth of bytes (see §3.7 — the submission
    /// boundary aligns with the handler activation boundary). Returns
    /// the submission's monotonic sequence number on the worker's own
    /// queue. Ownership of `bytes` transfers to the coordinator;
    /// `tenant_id` is duped internally.
    pub fn submit(
        self: *BlobCoordinator,
        worker_id: u8,
        tenant_id: []const u8,
        bytes: []u8,
    ) !u64;  // submission_seq

    /// Per-worker high water mark — every submission on `worker_id`'s
    /// queue with seq <= return value is durable in S3 and has a
    /// BodyRef ready. Atomic load, no lock; called from the worker's
    /// existing readiness check loop.
    pub fn durableSeq(self: *BlobCoordinator, worker_id: u8) u64;

    /// Lookup the BodyRef for a durable submission. Must only be
    /// called after observing `seq <= durableSeq(worker_id)`. Returns
    /// error.PutFailed if the batch carrying this seq terminally
    /// failed (rare — see §3.6 for retry policy).
    pub fn bodyRef(
        self: *BlobCoordinator,
        worker_id: u8,
        seq: u64,
    ) !BodyRef;
};

pub const BodyRef = struct {
    object_key: []const u8,    // pool-allocated, valid for the BodyRef's lifetime
    offset: u64,
    len: u32,
};
```

No `await`, no token-keyed condvars. The model mirrors raft's
`commit_index` exactly: per-worker `submission_seq` is the analog of
`log_index`; per-worker `durable_seq` is the analog of `commit_index`;
"is my submission durable?" is `seq <= durable_seq`. The worker's
existing readiness loop polls `durableSeq` (cheap atomic load) and
walks its parked-Msg list when the HWM advances. One condvar per
worker (signalled by executor on advance), batched wakeup, no
per-submission metadata to manage.

This is also what makes the park-on-durability gate fall out for free
(§3.7): the gate IS the HWM check, and firing the handler callback IS
the unpark loop. No separate "block on token, then re-deliver Msg"
shape.

### 3.2 Internal architecture — raft-thread pattern

```
worker thread  ──push──▶  per-worker MPSC queue  ◀──drain──┐
   (existing)              (1 producer / 1 consumer,        │
                            entry: {seq, tenant, bytes,     │
                            ↑                  parked_msg}) │
                            │                               │
   wait on per-worker       └─signal on push (eventfd)──────┤
   durable_seq advance                                      │
   (existing readiness loop)                                ▼
                                                  ┌────────────────┐
                                                  │ batch builder  │
                                                  │ (SINGLE thread,│
                                                  │  raft-pattern: │
                                                  │  wait on any   │
                                                  │  worker's      │
                                                  │  eventfd, drain│
                                                  │  all queues    │
                                                  │  round-robin,  │
                                                  │  seal batches  │
                                                  │  on executor   │
                                                  │  slack — §3.4) │
                                                  └────────┬───────┘
                                                           ▼
                                                  ┌────────────────┐
                                                  │ executor pool  │
                                                  │ (K=32 threads, │
                                                  │  each does     │
                                                  │  S3 PUT with   │
                                                  │  503 retry —   │
                                                  │  §3.6)         │
                                                  └────────┬───────┘
                                                           │
            ┌──────────────────────────────────────────────┘
            │ on batch commit: per worker represented in batch,
            │ advance worker's durable_seq (contiguous-prefix
            │ rule — see §5), signal worker's condvar
            ▼
   worker readiness loop wakes, walks parked-Msg list,
   fires handler callbacks for Msgs whose seq <= durable_seq
```

Three thread classes:

- **Worker threads** (existing, N≈4 per node): receive H2 / curl_multi
  events, assemble Msgs, push submissions, park Msgs locally, walk
  parked list on HWM advance.
- **Batch builder** (new, 1 per node): single drainer thread, exactly
  the raft-proposer pattern. Waits on a single eventfd; on wake,
  round-robin drains every worker's queue, hands sealed batches to
  executor.
- **Executor** (new, K=32 per node): pool of threads each doing one
  PUT at a time.

Total new threads: 1 drainer + 32 executors = 33 per node.

Why this shape:
- **No global pending-queue mutex contention.** Each per-worker queue
  has one producer (the worker) and one consumer (the drainer); MPSC
  is well-understood.
- **Matches existing convention.** Raft proposer and fetch engine
  both follow this pattern; new contributors recognize it.
- **Worker thread never touches the executor or any cross-process
  lock.** Push is a brief per-queue mutex hold; the slow paths
  (drainer wake, executor PUTs) run elsewhere.
- **Tape capture stays exactly where it is.** Handler callbacks fire
  on the worker thread, same as today; the only change is that they
  fire on HWM advance instead of on synchronous flush return.

### 3.3 Object key shape

```
_pool/{batch_id:0>20}            — cross-tenant pool object
```

**Revised 2026-05-27.** Phase 3 shipped per-(tenant, worker) prefix
(`{tenant}/readset-blobs/w{worker_id}/{batch_id:0>20}`) as a
transitional shape so the wire format could stay
`{batch_id, offset, len}` against the existing readset wire. Phase 5
moves to a single flat pool: one S3 object holds bytes from many
tenants, demuxed by `BodyRef.(offset, len)`. The forcing function is
zipf-distributed tenant traffic — most tenants are small, so the
per-tenant lane keeps producing tiny objects whose count overruns the
~135 req/s small-object cap (per [[project-s3-throughput-ceiling]])
well before bytes/sec is the bottleneck.

`batch_id` is globally unique by construction via raft reservation
(§3.5b), so no node_id or per-tenant scoping is needed in the path.
The flat prefix means OVH's per-account request-rate cap is the
relevant ceiling, not per-prefix sharding (which is what
tenant-leftmost would have given us — moot once we're not per-tenant).

**Encryption-at-rest** for cross-tenant pools is its own design
(deferred to a later phase). For now, callers submit plaintext bytes;
when an encryption-at-submitter scheme lands, the same wire format
holds — encryption is a transparent layer between caller and coord.

### 3.5b Batch-id reservation via raft

The single globally unique `batch_id` counter lives in cluster state.
Adding a raft round-trip per body PUT would be unacceptable latency;
instead the leader **reserves a block** of N ids in one raft propose
and mints from it locally:

```
1. At startup (and as block runs low), coord proposes a
   root-writeset envelope advancing _system/coord_next_pool_batch
   by N. On commit, coord owns [base, base + N).
2. Each coord.submit mints batch_id = next++ from the local block.
3. Low-watermark trigger: when next >= base + 0.8 × N, coord
   asynchronously proposes the next reservation in the background.
   By the time the current block exhausts, the next is already
   committed — no submit ever waits on raft.
4. On leadership change / process restart, the new leader reads
   _system/coord_next_pool_batch and reserves a fresh block strictly
   above all previously-reserved blocks. Old block's unused ids are
   orphaned (gap), which is harmless — no key collisions because
   the new base is monotonically higher.
```

- Default N = 10000. Default low-watermark = 0.8 (= 8000). At sustained
  100 batches/sec the prefetch fires every ~80 s.
- Followers' coord never reserves (only the leader writes bodies; the
  raft propose path is leader-gated anyway).
- The "reservation block lost on leadership change" gap is the only
  permanent waste — at N = 10000 and one election per day, that's
  ≤10000 batch_ids/day of sparse keys in S3. Bucket lifecycle reaps
  unreferenced objects.

### 3.4 Batching policy — executor-driven, not threshold-driven

The body-flush bench data (commit `c8a864d`, this conversation) showed
that fixed size/time thresholds barely matter at high arrival rates,
because the implicit batch is **everything that arrived while the
previous PUT was in flight**. The 1 MB → 4 MB size-bump moved the
needle by only +6% in the bursty case for exactly this reason.

The coordinator's batch builder instead seals on **executor backpressure**:

```
loop {
    wait until executor has a free slot
    drain all currently-pending submissions into a batch
    seal + hand to executor
}
```

Pros:
- Self-tuning. Under heavy load, batches naturally grow (more arrivals
  per executor cycle); under light load, batches naturally shrink
  (one submission gets PUT immediately).
- No threshold to misjudge across workloads.
- Latency-optimal at the floor: a single submission with no contention
  goes out immediately.
- Throughput-optimal at the ceiling: when the pipe is full, the next
  batch carries every byte that piled up.

Cons:
- One bound still needed: per-batch byte cap (~16 MB) so a single
  batch doesn't pin too much RAM or exceed a per-PUT timeout budget.
  This is a safety cap, not a tuning knob.

This is the design's most interesting departure from "build per-source
thresholds and hope." We have measurement that says the threshold
approach doesn't work; the data motivates the policy.

### 3.5 K — executor pool size

K=32 by default; env override `ROVE_BLOB_COORDINATOR_K`. Per OVH sweep:

- K=32 at 4 MB = 117 MB/s (100% of wire, no errors)
- K=64 at 4 MB = 117 MB/s (saturates wire, ~7 timeouts/2000)
- K=128 at 4 MB = 116 MB/s (~5% timeout rate — past the knee)

K=32 is the sweet spot: full wire utilization without timeout risk.
Higher K only buys headroom in the request-rate-bound regime
(small objects ≤ 256 KB), where the limit is per-account anyway.

### 3.6 503 SLOWDOWN retry — centralized

Executor wraps `BlobStore.put` with bounded exponential backoff:

```
attempts: 5
initial backoff: 100 ms
max backoff: 5 s
jitter: ±20%
```

503 + 429 → retry (per OVH docs). Other non-2xx → terminal fail.
Terminal failure does NOT advance `durable_seq` past the failed
submission's seq; the worker observes seq sticking and surfaces the
error via `bodyRef(seq)` returning `error.PutFailed`. (The parked-Msg
list semantics: a Msg whose seq sticks is dropped + the request fails
loudly. Same posture as today's per-call-site warn-and-drop, but
visible to the request path.)

One place. Tested once. Every existing BlobStore caller can keep its
own direct put path; only sources that go through the coordinator
get retry behavior. As they migrate, retry coverage expands.

### 3.7 Submission boundary = handler activation boundary

The worker pushes **one queue entry per Msg the handler would
otherwise receive directly**. Concretely:

| Source | Submission boundary | Notes |
|---|---|---|
| Inbound request body (>16 KB) | Whole body, after H2 stream END_STREAM | One Msg, one submission |
| Outbound fetch chunk (on_chunk) | Each chunk, as `curl_multi` delivers it | Many Msgs per fetch, many submissions |
| Outbound fetch pipe_to | n/a — bypasses coordinator | Per [[project-pipe-to-untaped]]: pipe_to bytes don't enter handler, no submission |
| Inline path (≤16 KB body) | n/a — bypasses coordinator | Bytes ride in raft entry directly |
| Log batch flush | n/a — bypasses coordinator | Phase 4 descoped (§6, §10.3); log indexer's discovery model is incompatible with coalescing |

Sub-Msg submissions (e.g. one per H2 DATA frame within a body) are
forbidden — they don't correspond to anything the handler sees and
they'd thrash the drainer with tiny entries. Super-Msg submissions
(e.g. accumulating across multiple chunks before pushing) are also
forbidden — they delay the natural delivery boundary and break the
HWM-advance unpark mechanism (the gate would need a different
predicate).

This makes the unpark loop trivially correct: when worker W's
`durable_seq` advances to N, every parked Msg on W with `seq <= N`
becomes deliverable. Walk the list, fire the callback for each.
No additional metadata to consult. This is the load-bearing
invariant that makes the rest of the architecture work.

## 4. Current state — what bespoke transport bits collapse

The migration retires (or thins to skeletons):

| Today | Becomes |
|---|---|
| `src/bodies/root.zig` BodyBuffer per-tenant per-worker | Deleted. Worker pushes one queue entry per Msg directly (§3.7). |
| `src/js/worker_bodies.zig` BodyFlushPool | Deleted; coordinator owns parallelism. |
| `src/js/worker_bodies.zig` flushBodiesTick | Deleted; HWM advance drives the unpark loop directly. |
| `src/log/root.zig` LogBuffer batching | Thin submitter wrapper. |
| `src/js/worker_log.zig` flushLogs | Becomes "drain LogBuffer into coordinator.submit". |
| Worker `flusher_thread` (does bodies + logs) | Deleted. Bodies push from worker thread directly; logs push from worker_log on its existing cadence. |
| `BodyRef = {batch_id, offset, len}` (in readset-replication) | Extended to `{object_key, offset, len}` (Phase 5). |
| `last_flushed_batch_id` per-buffer | Per-worker `durable_seq` exposed via `coordinator.durableSeq(worker_id)`. |
| 503 silently drops bytes at every put site | Centralized retry in coordinator executor. |

`BlobStore` interface unchanged. `S3BlobStore` / `FilesystemBlobStore`
unchanged. The coordinator sits **above** them as a higher-level write
aggregator.

`EasyPool` (default 64) keeps existing non-coordinator callers
(files-server uploads, ACME, deployment manifests). Coordinator's K=32
plus those = within 64-slot budget.

## 5. Invariants — hold at every step

1. **Per-worker `durable_seq` is monotonic non-decreasing.** Never
   regresses, even under out-of-order batch completion. Implementation:
   tracker keeps an `in_flight: SortedSet(u64)` per worker; on each
   batch commit, remove its seqs from in_flight, advance `durable_seq`
   to `min(in_flight) - 1` (or `max_assigned_seq` if in_flight empty).
   This is the analog of raft's "commit_index only advances when there's
   a contiguous quorum'd prefix." Same shape as the max-only guard
   added to `last_flushed_batch_id` in commit `c8a864d` — but enforced
   by the data structure, not a defensive check.
2. **Submission boundary = handler activation boundary (§3.7).** One
   queue entry per Msg the handler would see. Sub-Msg or super-Msg
   submissions are forbidden. This is what makes the unpark loop
   (walk parked-Msg list on HWM advance, fire callbacks for seq ≤ HWM)
   trivially correct.
3. **BodyRef once issued is stable.** The bytes at `(object_key, offset,
   offset+len)` are immutable for the lifetime of the BodyRef. Pool
   objects are never overwritten in place. (Compaction may move them
   — see §9.)
4. **Within-worker ordering preserved.** If a worker pushes A then B,
   A's seq is less than B's, and `durable_seq` reaches A before B.
   (Across workers: no ordering guarantee — each worker has its own
   queue and HWM.)
5. **Globally unique batch_id.** Reserved via raft (§3.5b); the
   leader cannot mint a batch_id below any previously-committed
   reservation. Same-node restart skips the old block (gap is fine);
   different-leader-after-election starts strictly higher. Eliminates
   the silent-overwrite hazard the per-(tenant, worker) scoping
   covered transitionally in Phase 3.
6. **PUT failure surfaces visibly.** A batch that terminally fails
   does NOT advance `durable_seq` past its seqs. The worker's
   `bodyRef(seq)` lookup returns `error.PutFailed`. The parked Msg
   is dropped and the request fails loudly — not silently as today.
7. **No threshold-based latency floor.** A single submission in a
   quiet system gets PUT immediately, not held for a 100 ms time
   window. Bench needs to confirm this (see §8).
8. **EasyPool budget respected.** Coordinator's K + non-coordinator
   callers' steady-state usage ≤ EasyPool size. Bench measures.

## 6. Phases — each independently shippable

### Phase 0 — this doc + decisions

Lock §7 open decisions. No code yet.

### Phase 1 — `BlobCoordinator` skeleton + tests

`src/blob/coordinator.zig`. Submit / per-worker durable_seq /
batch builder (drainer thread) / executor pool. Backend is a
`BlobStore` (testable against `MemoryBlobStore` fixture). 503 retry
not yet wired (tests pass / fail on first-shot backend behavior).
No production consumers.

**Exit criteria:**
- Submit from N worker threads with assertion that per-worker
  `durable_seq` reaches the expected value after all batches commit.
- HWM monotonicity under out-of-order batch completion (test
  fixture: backend with controllable per-PUT delay; submit batches
  whose seqs interleave, complete in reverse order, verify
  `durable_seq` advances only as contiguous prefix and never
  regresses).
- Pool sizing knob works.
- Empty submit, oversized submit (>16 MB safety cap),
  submit-after-coordinator-deinit (rejects), terminal failure causes
  `bodyRef(seq)` to return `error.PutFailed` AND `durable_seq`
  doesn't advance past the failed seq.

### Phase 2 — 503 retry + real S3 tests

503 retry policy. S3BlobStore wired. Replays an artificially-throttled
backend (fixture that returns 503 on first N attempts) to validate
retry math.

**Exit criteria:** retry verified against a stub backend; no
regression against `s3-blob-smoke`.

### Phase 3 — migrate body flush

Body flusher becomes a submitter. `BodyBuffer.flush` is gone;
worker_bodies.zig's `flushBodiesTick` becomes a thin "drain ready
tenants → coordinator.submit". The fan-out pool (commit `c8a864d`)
deletes.

Bench against the same `body_throughput_probe.py` cells. **Target:
≥80 MB/s on the 8t × 32w × 1 MB cell (vs today's 36 MB/s).** If we
don't see ≥1.5× over the fan-out shipped, the design didn't deliver
what we expected; pause and re-examine before continuing.

**Shipped 2026-05-27.** Bench:

| Cell | Pre-coord | Post-coord | Δ |
|---|---|---|---|
| 8t × 32w × 1 MB | 36 MB/s | 69.5 MB/s | +93% |
| 2t × 80w × 1 MB | 52 MB/s | 81.5 MB/s | +57% |

Both cleared the 1.5× exit gate; 2-tenant cell hit the 80 MB/s
aspiration. 641/643 tests pass.

### Phase 4 — ~~migrate log flush~~ DESCOPED 2026-05-27

Original plan: route log flush through the coordinator alongside
bodies; cross-source coalescing engages on the shared K=32 pool.

Why descoped: **coord's value is coalescing**, and the log read
model can't accept coalesced objects.

- Body read path is **pointer-based** — the readset records
  `(object_key, offset, len)`; replay does `getRange`. Multiple bodies
  inside one S3 object are demuxed by the BodyRef. Coalescing is
  invisible to the reader.
- Log read path is **discovery-based** — the indexer LISTs
  `_logs/{node_hex}/` and parses each object's self-describing
  sidecar (`src/log_server/flush_writer.zig:152-171`). The sidecar
  format binds records into one monolithic object with byte offsets
  into a deflated frames region. Coord coalescing would silently
  break the indexer.

Forcing prebatched submissions with caller-supplied keys (one log
batch = one S3 object, no merging) reduces coord to a thin pass-
through over `BlobStore.put` + retry — no coalescing benefit. The
PUT parallelism wasn't a bottleneck anyway: one PUT/sec/worker × 8
workers is well under K=32.

**Decision:** logs keep their direct `BatchStore.put` path. The
`Error.SlowDown` variant on rove-blob (Phase 2) is already plumbed;
a thin retry wrapper around the log PUT site is a separate small
task if metrics show 503s in production.

The coordinator's purpose is now **body coalescing specifically**.

### Phase 5 — cross-tenant pool + raft-reserved batch_id

**Revised 2026-05-27.** Originally framed as "BodyRef format change
to `{object_key, offset, len}`." Refined after the zipf-distribution
discussion (most tenants are small, per-tenant lanes produce too many
tiny S3 objects) and the realization that node_id / object_key
strings aren't needed if `batch_id` is globally unique by raft
reservation (§3.5b). Net wire change is just a `READSET_VERSION` bump
and a key-template switch on the reader side.

Concrete scope:

1. **Add `_system/coord_next_pool_batch` to apply.zig** — a root-
   writeset-replicated u64. Coord proposes increments via the
   existing type-2 envelope path (same machinery as ACME
   `cert/{host}`).
2. **Coord refactor:**
   - Open one shared backend with prefix `_pool/`. Drop
     `BackendKind.per_tenant`, `PerTenantConfig`, `getOrOpenSlot`,
     `TenantWorkerSlot`, the per-(tenant, worker) `next_batch_id`
     map, and `sealByTenant`'s tenant bucketing.
   - Add `BatchIdReservation { base, next, end }` block state +
     low-watermark prefetch (§3.5b).
   - `submit(worker_id, bytes) → seq` (drop `tenant_id` — coord no
     longer routes on it).
   - Drainer seals one batch per cycle across all submissions.
   - `BodyRef` drops `wire_batch_id` (it's just `batch_id` now).
3. **Tape wire format:**
   - `READSET_VERSION = 5`.
   - Parser branches: v4 = old per-tenant template
     (`{tenant}/readset-blobs/w{worker_id}/{id:0>20}`), v5 = pool
     template (`_pool/{id:0>20}`).
   - BodyRef wire shape unchanged: `{u64 id, u64 offset, u32 len}`.
4. **Worker call sites:** `coord.submit(worker_id, bytes)` (no
   tenant_id); drain materializes wire BodyRef as before.
5. **Upload walker:** v5 entries → walk `_pool/` and cross-reference
   batch_ids. v4 entries → keep the existing per-tenant walk path
   for as long as v4 entries exist in the raft log.

Encryption-at-submitter is **deferred** to a later phase (callers
submit plaintext; once an encryption layer lands, it slots between
caller and `coord.submit` with no wire change).

**Shipped 2026-05-27.** Cross-tenant pool live; `_system/coord_next_pool_batch`
replicated via envelope-2 root-writeset (mirrors `acme.zig`'s local-put-
then-propose pattern). Reservation block size 10 000 with 80% low-water-
mark prefetch on a background refill thread; drainer never blocks on
raft. `READSET_VERSION = 5` (parser accepts v4 + v5; v4 path retained for
existing raft-log entries). All 644+ unit tests green; `ctl_smoke`,
`files_server_smoke`, `leader_failover_smoke` (critical for cross-leader
uniqueness via `proposeAndWait`), `penalty_smoke`, `body_throughput_probe`,
`fetch_chunk_smoke` all PASS against S3 backend.

### Phase 6 — cleanup

Delete dead per-source batching / threshold code. Remove
`ROVE_BODY_FLUSH_POOL_SIZE` env. Update PLAN.md / readset-replication-plan
/ logs-plan to reflect the consolidation.

## 7. Open decisions — to lock in Phase 0

### A. v1 batching scope — within-tenant or cross-tenant?

- **A1**: v1 batches contain only one tenant's submissions. Object
  key is `{tenant}/_pool/{batch_id}`. Cross-tenant coalescing is v2,
  requires encryption-at-submitter to preserve isolation invariants
  (PLAN's page-level encryption at rest assumes object boundaries
  align with tenant boundaries).
- **A2**: v1 batches mix tenants. Encryption-at-submitter required
  upfront. Cleaner end state, slower to ship.

**Initial recommendation: A1** (Phase 3 shipped under this).

**Revised 2026-05-27: A2** (Phase 5 ships this). The "many-low-volume-
tenant workloads which we don't have at launch" reasoning was wrong:
launch *is* the zipf tail. Per-(tenant, worker) lanes produce one tiny
S3 object per low-traffic tenant per flush window, overrunning the
~135 req/s small-object cap before bytes/sec is the bottleneck.

Encryption-at-submitter is **deferred** — callers submit plaintext for
now; an encryption layer slots between caller and coord later with no
wire-format change.

### B. Batching policy — executor-driven or threshold-driven?

- **B1**: Executor-driven (§3.4). Seal on backpressure. One safety
  cap (16 MB / batch). No tuning knobs.
- **B2**: Size/time thresholds like today (matches what callers
  currently expect).
- **Recommendation: B1.** Bench data from the fan-out work says
  thresholds barely matter at any realistic arrival rate; the
  implicit "while-PUT-in-flight" buffering does the batching for
  you. B1 collapses tuning surface, matches the data.

### C. Completion observation — token-keyed condvar vs HWM

- **C1**: `submit` → `Token`; `await(token)` blocks until done.
  Each submission gets its own condvar; executor signals per token.
- **C2**: `submit` → `seq`; per-worker `durable_seq` atomic +
  per-worker condvar. Worker's existing readiness loop walks parked
  Msgs on advance. Mirrors raft's commit_index / applied_index.
- **Recommendation: C2.** C1 was the original choice in this plan
  but is wrong for three reasons: (1) per-token metadata grows
  O(in-flight submissions) and never amortizes; (2) batched wakeup
  is free with HWM (one signal advances seq, all interested waiters
  proceed) and N-condvar with token-keyed; (3) the unpark loop for
  park-on-durability already wants to walk parked Msgs on a
  per-worker signal — the HWM IS that signal, no separate condvar
  ladder needed. The submission-boundary = Msg-boundary invariant
  (§3.7) is what makes C2 trivially correct. Updated 2026-05-26.

### D. BodyRef migration — version byte or coordinated cutover?

- **D1**: Version byte in serialized form. Both readers handle both
  shapes. Older entries stay readable forever.
- **D2**: Coordinated cutover. New code reads both, old code errors
  on new shape. Migration is atomic deploy.
- **Recommendation: D1.** Raft log entries are immutable; any
  pre-coordinator entries with old BodyRefs need to remain readable
  for tape replay forever. D2 isn't really an option for that
  reason.

### E. Executor concurrency model — thread pool or curl_multi?

- **E1**: K thread pool, each calling synchronous `BlobStore.put`.
  Matches today's blob-side model. Predictable, simple.
- **E2**: One executor thread driving `curl_multi` with K transfers.
  Matches the eventual unified transport story
  (`docs/curl-multi-plan.md`).
- **Recommendation: E1.** `curl-multi-plan.md` §7.B explicitly
  rejected multi-migration for blob ("S3 PUTs are bulk-blocking,
  many cores each pushing one big body fits the workload"). The
  coordinator doesn't change that calculus — same workload, same
  per-PUT shape. E1 also means we don't block on curl_multi work
  shipping first.

### F. Where the coordinator lives — process-global or per-worker?

- **F1**: One coordinator per process (rove node). Implementation:
  per-worker MPSC queues (one producer = worker, one consumer =
  drainer), single drainer thread (raft-pattern), single executor
  pool. Workers compose into one global throughput pool without
  contention because each queue has a single consumer.
- **F2**: One per worker, like today's flush pool.
- **Recommendation: F1.** F2 brings back exactly the lane-cap
  problem this plan exists to solve. F1 was originally framed in
  this doc as "shared MPMC pending queue with one mutex" — that
  framing is wrong; per-worker MPSC queues + single drainer
  (matching the raft proposer thread shape) avoids the shared-mutex
  contention while still pooling throughput globally. Updated
  2026-05-26.

### G. EasyPool sizing under coordinator

Default EasyPool is 64. Coordinator at K=32 plus files-server
uploads (steady ~4–8) plus ACME (~1) plus deployment manifests (~1)
≤ 64 comfortably. But heavy `rove-files-server` upload bursts could
contend. Open question: do we (a) bump default EasyPool to 128 when
the coordinator is enabled, (b) give the coordinator its own
dedicated EasyPool, (c) trust the 64 + occasional acquire-wait?

Lock during Phase 1 — needs measurement under realistic mixed load.

## 8. Test & perf strategy

### Unit (Phase 1)

- Submit / await round trip with MemoryBlobStore.
- N-thread concurrent submit with assertion on completion + token
  uniqueness.
- Backpressure: queue submit-faster-than-PUT, verify no deadlock,
  no token leak.
- Terminal-fail propagation: backend returns Error.Io permanently,
  every contained `await` returns the error.

### Integration (Phase 2)

- `s3-coordinator-smoke`: cluster spawn + coordinator + actual S3
  round-trips. Mirrors `s3-blob-smoke` shape.
- 503 retry: stub backend that returns 503 N times then 200; verify
  `await` succeeds and total elapsed matches expected backoff.

### Perf — the load-bearing measurement (Phase 3)

`scripts/body_throughput_probe.py` is the existing harness. Run the
same three cells as today:

| Cell | Pre-coordinator | Target |
|---|---|---|
| 8t × 32w × 1 MB | 36 MB/s | ≥80 MB/s (~70% wire) |
| 2t × 80w × 1 MB | 52 MB/s | ≥80 MB/s |
| 8t × 128w × 64 KB | 11.6 MB/s | ≥30 MB/s (request-rate bound but should improve via coalescing) |

If Phase 3 doesn't deliver, **stop and re-examine before Phase 5**.
The plan is wrong about something and adding more consumers won't
fix it. *(Phase 4 was descoped 2026-05-27; see §6.)*

### Perf — tail latency (Phase 3)

`body_throughput_probe`'s p50/p99 numbers must not regress. The
threshold-less batching policy is theoretically latency-optimal at
the floor (single submission goes out immediately) but the data
needs to confirm. Specific risk: a tenant submitting one batch
that gets sealed into a giant cross-source pool object pays the
big-PUT latency for one small request. Bench at low load to verify.

## 9. Out of scope — locked rejections (do not re-propose)

- ~~**Cross-tenant coalescing in v1.**~~ Reversed 2026-05-27 — now
  the Phase 5 target (§7.A revised). Encryption-at-submitter is
  deferred (callers submit plaintext until an encryption layer slots
  in between caller and coord).
- **Compaction of pool objects.** Pool objects are immutable.
  Lifecycle rule on the bucket expires them after retention period.
  Compaction-with-reference-rewrite is the killer problem we
  discussed; if it becomes load-bearing, that's its own plan
  (which probably requires the logical-id-indirection layer we
  also discussed, which is essentially "rebuild CAS for pool
  objects" — out of scope here).
- **MPU (multipart upload).** OVH recommends MPU for objects > 100 MB.
  Our 16 MB safety cap means we'll never produce a single object
  big enough to benefit. If a future workload changes that, MPU
  goes here as a new section in this plan.
- **Encryption-at-submitter.** Its own plan. References this one
  for the pool object substrate.
- **Multi-node coordinator coordination.** Each rove process has
  its own coordinator. Per [[project-s3-throughput-ceiling]] the
  117 MB/s ceiling is per-server; multi-node aggregation happens
  via the obvious "each node uses its own wire" pattern.
- **curl_multi migration for blob.** Per `curl-multi-plan.md` §7.B,
  explicitly rejected; this plan inherits that rejection.

## 10. Interaction with adjacent plans

### 10.1 `docs/effect-algebra.md`

Body bytes are tape inputs (the readset's `fetch_responses` and
`request_bodies` channels). The coordinator is the storage
substrate; effect-algebra is unchanged. No new effects introduced.

The §3.7 invariant (submission boundary = handler activation
boundary) is what keeps the abstraction clean from effect-algebra's
side. Each Msg the handler receives still corresponds to exactly one
recorded thing in the tape; the coordinator just changes *when* the
Msg fires (on HWM advance instead of synchronous flush). The
determinism boundary stays at the Msg/activation level — the
coordinator can't violate it because it doesn't sit inside
activations, only between them.

### 10.2 `docs/readset-replication-plan.md`

Phase 2's `BodyBuffer` becomes a thin submitter. BodyRef shape change
(§7.D, Phase 5 of this plan) is the integration point — the
readset's pointer-into-S3 record changes from
`{batch_id, offset, len}` to `{object_key, offset, len}`. Readset
serialization needs the version byte.

### 10.3 `docs/logs-plan.md`

**No integration — logs stay separate (2026-05-27).** The original
Phase 4 plan to route LogBuffer through the coordinator was descoped
(see §6 Phase 4). Log objects are self-describing (sidecar header +
deflated frames region); the indexer discovers them by LIST and
parses each as a standalone batch. Coord's coalescing model can't
preserve that shape without redesigning both the log object format
and the indexer's read path.

`log_server/batch_store_s3.zig` keeps owning log PUTs.

If 503 retries become a measured concern, the small fix is a retry
wrapper around `flush_writer.writeBatch`'s `store.put(obj_key, obj)`
using the `Error.SlowDown` variant rove-blob already emits (Phase 2);
no coord dependency.

### 10.4 `docs/curl-multi-plan.md`

§7.B locked out blob migration to curl_multi. This plan inherits
that. The coordinator drives the existing `Easy` pool, same as
today's flusher.

### 10.5 [[project-inputs-durable-outputs-derivable]]

Pool objects are **input-cache** for the system — they hold bytes
the system depends on for replay. They are NOT outputs (handler
results, derived data). The compaction story for input-cache is
"keep forever" or "lifecycle-policy-expire after replay window";
both are consistent with this plan's "no compaction in v1" choice.

### 10.6 [[project-s3-throughput-ceiling]]

The 117 MB/s ceiling stands. The coordinator's job is to reach
that ceiling more consistently across workload shapes, not to
exceed it. To exceed it: more nodes, each with their own NIC.

## 11. Appendix — back-of-envelope for the target

The 80 MB/s Phase 3 target is derived from:

- Sweep: K=32 at 4 MB = 117 MB/s
- Coordinator's implicit batches at high load = 4–8 MB (per the
  "bytes pile up while PUT in flight" finding from
  `c8a864d` discussion)
- K=32 at 4 MB sustained = ~25 batches/sec
- Each batch carries however many submissions arrived during the
  ~200 ms PUT cycle; at 8t × 32w × 1 MB offered (~256 MB/s
  aggregate offered) per batch carries ~5 MB of submissions
- 25 × 5 MB = 125 MB/s = wire-cap (so we asymptote at ~117 MB/s)
- Realistic discount for queue contention, partial batches at the
  start/end of bursts, occasional 503 retry: 70% = 82 MB/s

This is a *prediction*, not a guarantee. Phase 3 verifies it.
If reality lands at 60 MB/s we don't ship the migration as-is;
we figure out why and either fix or back out.
