# Readset replication plan

> **Status**: Phases 1–6 SHIPPED 2026-05-25/26/27. Substantively done;
> only `5d-deferred` (operator-side S3 GC) remains, recommended as a
> bucket-lifecycle rule pre-launch (no code work). The design
> conversation explicitly considered and rejected two adjacent shapes
> (intents-only eager re-execution; intents-only lazy with
> on-promotion re-exec) — see §7 for the discarded alternatives and
> why. The 2026-05-24 revision that removed the inline-body path for
> simplicity was walked back in 4-inline once measured (see §9). The
> §11 open questions are defer-until-observed items, not blocking work.
> §1–§8 are the load-bearing reference for the readset wire format,
> callback-gating semantics, and failure modes.

## 1. The problem in one sentence

The customer-facing replay product (rewind.js) loses the replay of any
request the leader served between its last S3 tape-batch flush and its
crash, because the tape is generated only on the leader and only the
writeset survives to followers.

## 2. Current state

Per CLAUDE.md "What replicates through raft": the raft log carries
writesets (envelope type 0) and a couple of administrative variants.
Followers apply writesets to their local kvexp/LMDB and converge to
identical state.

The **tape** — the per-request artifact that drives replay/simulation —
is a separate pipeline:

- Generated **only on the leader** during handler execution.
- Captures the readset (kv reads, fetch responses, trigger payload,
  module hashes, seed, timestamp).
- Batched and uploaded to S3 asynchronously by the leader.

Followers never see the readset. They have writesets, so they have
state, but they have no way to reproduce the tape for any request.

## 3. The gap

Sequence of events that produces unreplayable requests:

1. Leader serves request R, generates writeset W and tape T.
2. Raft replicates W, followers apply, request commits.
3. Tape T sits in the leader's pre-flush batch buffer.
4. Leader crashes before the batch flushes to S3.
5. Follower takes over, has W applied (state intact), but has no T —
   T existed only in the dead leader's memory.

R's writes are durable. R is permanently unreplayable. For a product
named *rewind*, "the request that crashed the worker is exactly the one
you can't replay" is the wrong failure mode.

The flush window is typically seconds, but leader crashes are
correlated with hot tenants (OOM, deploys, network partitions) — the
exact times you most want the tape.

## 4. Proposal

Add the readset to the raft entry alongside the writeset. All
"body"-shaped payloads (fetch response bodies, inbound request
bodies, individual streamed chunks above a Msg-sized threshold,
trigger payloads) stream into a per-tenant batched blob in S3 as the
bytes arrive from the network; the raft entry carries the pointer
`(address, offset, len)`, never the bytes. One safe semantic — no
inline body path, no two-mode routing.

This is **transport-layer body streaming**, distinct from the
content-addressed commit-gated `blob.put` Cmd (see
`effect-reification-plan.md` Phase 7). Both sit on the same
`BlobBackend`, but they have orthogonal lifecycles: §10 itemizes
the distinction.

### 4.1 Raft entry shape

Today (envelope type 0):

```
writeset = [(key, value, op), ...]
```

Proposed:

```
entry = {
  writeset:  [(key, value, op), ...],
  readset:   {
    kv_reads:        [(key, value, mvcc_version), ...],
    fetch_responses: [{status, headers, body: BodyRef}, ...],
    trigger_payload: {headers, body: BodyRef},
    module_hashes:   [hash, ...],
    seed:            u64,
    timestamp_ns:    u64,
  },
}

BodyRef = { batch_id, offset, len }
```

The readset is structural — typed fields, not opaque bytes. Every
"body" position is a `BodyRef`, always a pointer into a per-tenant
streaming-batched blob (§4.3). Bytes never ride in the raft entry.

### 4.2 Why readset, not "intents"

An earlier draft of this design (§7.1) replaced writesets entirely with
"intents" — the inputs the handler observed, with followers
re-executing to derive state. That has two killing problems: CPU
multiplies by N nodes, and the kvexp local-snapshot invariant is
violated (without writesets, followers have no state to snapshot).

Readset replication is a smaller change that gets the same
tape-durability win without touching either invariant. Writesets remain
the state-convergence path; readsets are purely a tape source. The
engine's apply path is unchanged.

### 4.3 Per-tenant streaming buffer

Each tenant has a single in-memory buffer that accepts streaming
writes from all in-flight bodies (fetch responses, chunked outbound
responses, inbound request bodies — all append to the same buffer).
The buffer carries a **`durable_offset`** — the largest byte position
known durable in stable storage. Writes append past `durable_offset`;
periodic flushes advance it.

This is out-of-band of raft: bytes flow from the network engine
(curl_multi for outbound, H2 frames for inbound) directly into the
buffer; the resulting `BodyRef` is what crosses the wire when the
handler's writeset commits. The raft path never carries body bytes.

Granularity:

- Per-tenant buffer (consistent with logs and file blobs).
- Flush triggers: 100ms time window, 1MB accumulated unflushed bytes,
  or **priority flush** (§5.2) when a callback is blocked and the
  buffer has unflushed bytes.
- `batch_id` is monotonic per tenant; S3 key derived deterministically.
- Per-tenant path: `{tenant_id}/readset-blobs/{batch_id}`.
- Backend is the existing `BlobBackend` (FilesystemBlobStore on shared
  mount, or S3BlobStore — same one source code and log blobs use).

Cost shape:

- S3 PUT count: bounded by flush frequency × tenant count. Idle
  tenants pay nothing — the buffer never gets used. Hot tenants pay
  one PUT per flush interval regardless of how many bodies batched
  together.
- Object size: small batches for low-traffic tenants (acceptable, same
  tradeoff log-batches make), full 1MB+ batches for hot tenants.
- GET path on tape reproduce: one S3 GET per referenced batch,
  amortized across all readset items pointing into it.

The buffer also holds the bytes in RAM for **live read** during the
handler activation that consumes them. Sequence: bytes arrive →
append to buffer → flush schedules S3 PUT → on flush ack,
`durable_offset` advances → callback Msg fires carrying
`{batch_id, offset, len}` → handler activation reads the bytes via
that pointer (still in RAM at this point) → activation completes →
writeset commits → bytes drop from RAM (durable in S3, replayable
via GET). RAM cost is bounded by `flush_interval × peak_arrival_rate`
per tenant.

### 4.4 Inbound/outbound symmetry, chunk granularity

Outbound (fetch response) and inbound (request body from a client
or webhook caller) bodies are the same kind of thing for the tape —
both are external bytes the handler observed. They flow through the
same buffer, the same `durable_offset`, the same wake source. No
direction-specific routing.

Chunk semantics:

- **Full-body delivery** (single-shot inbound request body,
  `http.fetch` with `stream: false`): the complete body is buffered
  as one contiguous range and produces one `BodyRef` covering it.
  One callback Msg fires when `durable_offset` advances past the
  range's end.
- **Streaming delivery** (`http.fetch` Pattern A `on_chunk`, chunked
  inbound bodies): each chunk arrival appends to the buffer and
  produces a separate `BodyRef` covering just that chunk; one
  callback Msg fires per chunk. Chunks share batch objects with all
  other in-flight bodies on the same tenant.

`pipe_to` Pattern B bytes remain structurally untaped per memory
entry `project_pipe_to_untaped` — they never enter a handler
activation, so there's no readset to gate. Unchanged.

## 5. Durability policy — callback gating

The invariant: **a handler may not read bytes that aren't in stable
storage.** Once a handler observes a fetch response (or chunk), every
downstream decision is causally dependent on those bytes, and the
tape is unreproducible if they vanish. The gate therefore lives at
the *callback boundary*, not at the propose boundary.

### 5.1 Mechanism

Every body is gated: the chunk/response Msg doesn't fire until
`durable_offset` has advanced past the body's `(offset, len)`
range. The activation that consumes the body runs only against
already-durable bytes; whatever it derives is structurally
reproducible.

The Cmd resolution sequence for a fetch response:

1. Handler returns `Cmd(http.fetch, url)`.
2. Engine performs the fetch; response bytes stream into the
   per-tenant buffer (§4.3), assigned a `(batch_id, offset, len)`
   range. The handler is suspended on a "durable past offset X"
   wake source.
3. Buffer flush completes → `durable_offset` advances → all parked
   continuations whose ranges now satisfy `end_offset ≤ durable_offset`
   are resumed in one pass.
4. Resumed activation runs; its writeset + readset (carrying the
   `BodyRef`s pointing into the already-durable batches) get proposed
   normally.

Inbound bodies follow the same logic: the inbound activation is
parked until `durable_offset` has advanced past the body's range,
then fires.

Because every `BodyRef` in any committed readset is durable-before-
callback by construction, propose-time gating is automatic: an entry
can't be ready to propose until all of its callbacks fired, and they
couldn't have fired without their bytes being durable.

Streaming (Pattern A): each chunk Msg is gated on its own range
independently. One flush typically releases many chunks at once (the
buffer's `durable_offset` jumps past multiple chunk ends in one
advance).

### 5.2 Priority flush for blocked handlers

A sequential `fetch → callback → fetch → callback` chain pays
per-fetch latency: each callback must wait for its bytes to flush
before the next Cmd can issue. Without intervention, the floor per
fetch is `batch_interval + S3_PUT_RTT` (e.g., 100ms + 50ms = 150ms).

Mitigation: when the buffer has unflushed bytes and ≥1 callback is
parked waiting for them, trigger an early flush regardless of the
interval/size threshold. Floor drops to `S3_PUT_RTT` (~30–100ms
typical). Idle and fully-parallel workloads pay nothing extra; only
blocked sequential chains trigger the extra PUTs.

### 5.3 No best-effort opt-in

An earlier draft of §5 paired strict with a best-effort opt-in that
proposed before flushing. With callback-gating, best-effort means
*the handler runs further on bytes that may never become durable*,
producing kv writes derived from unreproducible reads. Customer
sees `x = 42` in kv; we cannot answer "why" via replay. State and
tape diverge.

That's a position the platform can't recover from once shipped, so
best-effort is not offered. Per
`feedback_model_simplicity_safety`, one safe semantic; opt-ins wait
for concrete customer demand and aren't this opt-in.

## 6. Failure modes

### 6.1 Orphan blobs

Leader writes batch to S3 → crashes before raft-proposing the entries
that reference it. The batch sits in S3 with no readset pointing to it.

**Handling**: GC by readset reachability. A periodic sweep walks
recent raft entries, collects referenced (batch_id, offset, len)
tuples, and deletes any batch with no incoming references older than
some watermark (e.g., 1h). Same shape as the existing manifest-pointer
GC story for files. Bounded cost.

### 6.2 Backend availability

If S3 (or the shared filesystem) is unavailable, callback-gating
blocks new resumes on fetch-using handlers — the buffer can't flush,
so `durable_offset` doesn't advance, so parked continuations stay
parked. Non-fetch handlers commit normally (no batch to flush).
Partial outage shape, not a full cluster wedge.

Per-tenant `durable_offset` is observable as an operational signal —
sustained stalls in advancement on otherwise-active tenants indicate
backend trouble.

## 7. Discarded alternatives

### 7.1 Intents-only, eager follower re-execution

Replace writesets entirely. Raft log carries inputs (request, seed,
timestamp, fetch_responses, trigger_payloads). Every follower
re-executes the handler to derive state.

**Killed by**: CPU multiplies by N nodes per tenant. Today's sharded
~160k req/s ceiling assumes the leader runs all JS; with N=3,
per-tenant ceiling drops because each node has to keep up with cluster
write rate in JS execution.

### 7.2 Intents-only, lazy on promotion

Same raft log shape, but followers don't re-execute eagerly. They
store inputs and only re-execute when promoted.

**Killed by**: violates the kvexp local-snapshot invariant. The kvexp
LMDB *is* the snapshot (memory: `project_kvexp_rebump_metrics`); without
writesets, followers have no state to snapshot. Promotion has nothing
to base re-execution off of. Adding distributed snapshot transfer
fixes this but is a multi-week refactor and ships gigabyte-scale
snapshot traffic.

### 7.3 Snapshot-gated-on-S3 (original proposal)

Couple raft log compaction to S3 batch upload progress — don't
truncate past entries whose readsets aren't fully durable in S3.

**Killed by**: ties consensus liveness to S3 availability. S3 outage →
log compaction stalls → log grows unbounded → eventual cluster wedge.
The readset replication approach makes this unnecessary because the
raft log itself is the durability boundary for the readset structure;
the blob batches are *publication*, not durability.

## 8. Performance impact

### 8.1 Raft entry size

Adds: kv_reads (typically <1KB per request), fetch response metadata
(status + headers + pointer per fetch, ~200B each), module hashes
(32B each), trigger pointer (~20B), seed/timestamp (16B).

For a typical handler doing 1–5 kv reads, 0–2 fetches, 1–3 modules:
~500B–2KB of additional bytes per entry. Within the fsync budget that
today's raft entries already use (writesets are often 500B–10KB).

### 8.2 Callback latency

Every body pays a per-tenant batched S3 PUT before its callback
fires. The cost is amortized across all concurrent bodies on the
same tenant within the flush window.

- **Parallel workload** (many in-flight bodies, no waiting-for-result
  sequence): flushes happen on the 100ms / 1MB interval; latency
  floor for the typical body ≈ `flush_interval / 2 + S3_PUT_RTT`,
  shared with all other bodies in the same flush window. The S3
  PUT cost amortizes to ≈ `S3_PUT_RTT × flushes / N_bodies_per_flush`.
- **Sequential chains** (handler waits on callback before issuing the
  next Cmd): priority flush (§5.2) kicks in; latency floor per body
  ≈ `S3_PUT_RTT` (~30–100ms typical). The chain length × that floor
  is the customer-visible latency for sequential `fetch → callback →
  fetch → callback` patterns.
- **Streaming `pipe_to`** (Pattern B): structurally untaped per memory
  entry `project_pipe_to_untaped`, no callback gating cost. No
  buffer interaction.
- **Streaming `on_chunk`** (Pattern A): chunks share the buffer with
  the rest of the tenant's in-flight bodies; one flush releases many
  chunks' callbacks at once. Per-chunk cost ≈
  `flush_interval / chunks_per_flush` in the parallel case;
  `S3_PUT_RTT` per chunk in the strictly-sequential case (priority
  flush per chunk).
- **Non-body-touching handlers**: unchanged. The buffer is only
  exercised when a handler sees a body.

The customer-facing latency story: "external bytes are eventually
durable before your handler reads them; in practice that costs you
one batched S3 PUT per flush interval." That's an honest cost for the
property delivered (no unreproducible reads).

### 8.3 Steady-state throughput

Raft entries grow only by readset metadata (kv_reads + per-fetch
`{status, headers, BodyRef}` + module hashes + trigger pointer +
seed/timestamp; see §8.1). No body bytes cross the raft wire, so
the existing fsync budget that today's ~160k req/s sharded ceiling
depends on (per `project_perf_push_2026_05_21`) is preserved.

The new serialization point is at the callback boundary: every body
pays one batched S3 PUT before its activation runs. Throughput
impact is on handlers with large-body sequential chains (priority
flush per body), and is bounded by the flush interval for parallel
workloads.

### 8.4 Tape reproduce throughput

New cost: tape upload pipeline now reads blob batches from S3 to
hydrate fetch bodies. One GET per referenced batch, amortized across
all requests pointing into it. Roughly the same I/O shape as today's
direct S3 upload, just via an intermediate batch object.

## 9. Phase history (all shipped or resolved)

| Phase | What | Status |
|---|---|---|
| **1** | Readset capture on leader — structural lift (single `*tape_mod.Readset` on dispatch state) + scalar inputs (timestamp_ns, seed) folded in | SHIPPED — `Readset.init(allocator, timestamp_ns, seed)` |
| **2** | Per-tenant streaming buffer + S3 batched flush — `rove-bodies` module, `BodyBuffer`, channels 5 (`fetch_responses`) + 6 (`trigger_payload`) on tape | SHIPPED — bytes flow through BlobBackend; tape carries BodyRefs |
| **3** | Readset bytes (`rs_bytes`) in raft entry — type-0 envelope payload `[u32 ws_len][ws][u32 rs_len][rs]`; multi-readset aggregation via `tape_mod.encodeReadsetList` for batched dispatches | SHIPPED — apply-side validates each readset via `parseReadset` |
| **4-inline** | Bodies ≤ 16 KB ride inline in readset (raft fsync IS durability); discriminator `batch_id == NO_BATCH`. Heldsync per-request 0.16s → 0.01s. | SHIPPED — walks back the pre-2026-05-24 "no inline path" simplification once measured |
| **4-park** | Bodies > 16 KB use park-on-durability — `BodyDurabilityWait` component, `body_pending` collection, `drainBodyPending`. Worker thread no longer stalls during S3 PUTs. | SHIPPED |
| **4-fetch-inline + 4-fetch-park** | Same inline/park split for outbound `http.fetch` chunks via `proposeForgetfulWrites` | SHIPPED |
| **4.x** | Priority-flush coalescing + cross-tenant batching | RESOLVED via blob-coordinator Phase 5 — body-flush path migrated through process-global coord (`streaming-model.md` §7); cross-tenant `_pool/` layout coalesces across tenants; executor-driven batching makes priority-flush wake mechanism unnecessary |
| **5a** | `LogHeader` on readset wire (request_id, deployment_id, duration_ns, status, outcome, method, path, host, correlation_id); `READSET_VERSION = 2` | SHIPPED |
| **5b** (base + 5b-1) | Per-worker `last_uploaded_seq` checkpoint + idempotent push; cont-resume / streaming / fetch_chunk paths all stamp real `raft_seq` | SHIPPED |
| **5c** | Promotion-time tape upload walker on `log_worker_id == 0`; hydrates LogRecords from raft entries via `parseReadset`; WALKER_BATCH_CAP=256 bounds latency during catchup | SHIPPED — body-bytes hydration *not* needed; `captureTapes` only inlines ≤16 KB in normal operation either (2026-05-27); large bodies live in BlobBackend via BodyRef, dashboard/replay fetches on demand |
| **5d-base** | `collectReferencedBatchesIntoList` — extracts every live `(tenant_id, batch_id)` BodyRef from the raft log (the algorithmic core of GC) | SHIPPED |
| **5d-deferred** | Operator-side S3 LIST + DELETE | DEFERRED pre-launch — bucket lifecycle expiration rule on `*/readset-blobs/*` is the recommended setup. In-code sweeper ships when: backend doesn't support lifecycle rules, customer needs sub-day GC latency, or tenant-eviction needs synchronous cleanup. None hold today. |
| **6** | Verification — `leader_failover_smoke.py` extended to assert log records appear post-failover (proves walker recovery + indexer idempotency work end-to-end) | SHIPPED, 5/5 on the new assertion |

Per-phase commits on the readset-replication branch have the
implementation detail. The 2026-05-24 plan revision that briefly
removed the inline-body path is reflected in 4-inline above (walked
back once measured — both inline-in-raft and inline-in-S3 deliver the
same "handler runs against durable bytes" guarantee, and the latency
win was worth the bounded wire complexity).

---

### Historical note — Phase 2 incidentally

The original Phase 2 introduced a per-tenant `BodyBuffer` at
`{tenant_id}/readset-blobs/{batch_id}` (per-tenant S3 prefix). The
blob coordinator's Phase 5 (2026-05-27) generalized the substrate to
a cross-tenant `_pool/{batch_id}` layout with raft-reserved unique
batch_ids. The BodyRef wire shape is unchanged (`{u64 batch_id, u64
offset, u32 len}`); the readset's `READSET_VERSION` tracks which
key template to resolve against (v4 = per-tenant lane, v5 =
`_pool/`). See `streaming-model.md` §7 for the substrate.

## 10. Relation to other plans

- **`effect-algebra.md`** — readset capture is a property of the
  Continuation primitive (§2.2): the parked activation records what
  it observed. This is the cross-activation persistence of that
  recording.
- **`effect-reification-plan.md` Phase 4.1** — the commit-gated Cmd
  buffer is the natural scaffolding for §4 propose gating; the
  gating predicate just becomes "batches flushed past the BodyRef
  ranges."
- **`replay-wasm-plan.md`** — readset format here should match what
  the WASM replay engine consumes. Phase 1 of this plan should align
  the in-memory readset type with the replay engine's input type, so
  no translation layer is needed.
- **`logs-plan.md`** — blob batching shape (per-tenant, time/size
  flush, monotonic batch_id) mirrors the log-batch design exactly.
  Implementation can share the batcher abstraction.
- **V2 multi-raft direction** (memory:
  `project_v2_multiraft_direction`) — per-tenant raft groups make
  readset replication per-tenant naturally. This design works
  identically under v1 single-raft and v2 multi-raft; no rework on
  the v1→v2 migration.

## 11. Open questions

1. **kv_reads — values or pointers?** Followers have the LMDB state and
   could derive read values from `(key, mvcc_version)` if MVCC retention
   covers the readset window. Storing values is bigger but unambiguous.
   v1: values. Revisit if entry size becomes a problem.

2. **Trigger payload encoding for cross-entry triggers.** If a
   subscription fire was caused by an earlier raft entry's writeset, the
   trigger payload is reproducible from that entry. Storing a reference
   to the source entry would save bytes, but couples readsets to raft
   entry IDs. v1: stream the trigger payload through the per-tenant
   buffer like any other body, ignore the dedupe opportunity.

3. **Backend ordering guarantees.** S3 PUTs are read-after-write
   consistent in modern S3, but if the deployed backend isn't, the
   flush-then-advance-`durable_offset` sequence needs explicit
   verification (read back the bytes, confirm match) before
   advancing. Cost: one extra GET per flush. Defer until we know
   the deployed backend's guarantees.

4. **GC watermark.** How long to retain orphan blobs before GC. Should
   match raft log retention so orphan recovery from a delayed propose
   (network partition + late commit) doesn't false-positive into GC.

5. **Per-tenant submission rate ceiling.** Post-coord, the concern
   shifts from "per-tenant PUT rate" to "one tenant filling the
   K=32 executor pool and starving others." A per-tenant submission
   rate cap or fair-queueing layer in coord would address it. Defer
   until observed; the cross-tenant `_pool/` layout makes single-
   tenant burst less impactful than the pre-coord per-tenant
   model would have suggested.

6. **RAM cost ceiling per tenant.** §4.3's "bytes live in RAM
   between arrival and writeset commit" gives a bound of
   `flush_interval × peak_arrival_rate`. Under sustained backend
   slowness, `flush_interval` stretches and RAM grows. A hard cap is
   needed (e.g., per-tenant 64MB), above which the engine 503s
   inbound and refuses to start new outbound fetches, with the
   backpressure surfaced on the customer's response. Same template
   as gap-2.2 streaming backpressure
   (memory: `project_gap_2_2_backpressure`).

7. **Buffer placement.** Per-worker, owned by the worker's allocator
   (NOT the per-request QJS arena — which resets between requests —
   and NOT the QJS base arena, which never resets). The buffer needs
   its own scope with explicit lifetime: bytes enter on network
   arrival, drop after the writeset commits the entry referencing
   the `BodyRef`. Probably a dedicated `BodyBuffer` struct held on
   the `Worker`, with per-tenant sub-buffers keyed by tenant id +
   the same hash routing the worker uses for kv affinity. The
   per-tenant cap in #6 above lives here. Resolved direction
   2026-05-24; concrete layout decided when Phase 2 starts.
