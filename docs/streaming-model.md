# The streaming model — the chain processes streams

**Status:** Engine substrate + as-built reference. Hosts the model
rules (§1–§2), outbound as-built (§4 + §4.A), gap 2.5 lifecycle
note (§6), the implementation honesty / phasing detail (§7), and
the blob coordinator substrate (§7.X).
**Customer-facing handler API moved to
[`handler-shape.md`](handler-shape.md)** — that doc supersedes §3's
three-way-choice surface, §4's per-chunk return shape, and §5's
`__rove_*` Msg/Cmd naming. Sections kept here for engine context;
where surface details are referenced they're cross-linked to
`handler-shape.md`.
Inbound (§3): substrate design locked, implementation pending (gap
2.4); customer surface fixed in handler-shape.md. Outbound (§4 +
§4.A): shipped 2026-05-21 as `http.fetch` (gap 2.3); §4.A absorbs
the former `upstream-streaming-plan.md` as the as-built option-set
+ Msg shape + caps reference. Gap 2.5 (`http.subscribe`) shipped
2026-05-24 — see §6.

---

## 1. The frame

The handler is `update : (Msg, Ctx) → (Effects, Cmd)`. The unit it
runs inside is the **chain** — a sequence of `update` steps sharing
one `correlation_id` and `ctx`.

> **A chain processes a stream of `Msg`s and emits a stream of
> `Cmd`s. Bytes — request body, response body, the body of any
> fetch it starts — ride those Msgs and Cmds as chunks.**

There is no "buffered engine" and "streaming engine." There is one
engine and **one knob: coalesce, or don't.**

- A **normal request** is a chain the runtime *coalesced*: it
  folded the inbound byte-stream into a single `inbound` Msg
  (`request.body`) and folded the handler's single `Cmd` into the
  outbound byte-stream (`return "hello"`). One step. Done.
- A **streaming handler** is the *same chain* with coalescing off
  for one or both directions. The steps aren't folded; the handler
  sees the chunks.

`request.body` is sugar — the coalesced view of the inbound
stream. `return "hello"` is sugar — "emit one chunk, close."
Streaming is not a feature bolted on top of buffered; **buffered is
the feature** — the runtime coalescing by default so the simple
case stays a one-liner. Streaming is asking it not to.

---

## 2. The one rule

Everything about commit ordering and error handling reduces to a
single rule:

> **A chunk reaches the wire only after the activation that
> produced it has committed.**

Apply it to a **one-step chain** (a normal request): the single
activation commits, then its single response chunk flushes. You get
— for free —

- a **clean 500** when the handler throws (nothing was on the wire
  when it threw), and
- **effects durable before the response** (the one commit precedes
  the one flush).

Apply it to an **N-step chain** (streaming): each chunk flushes
after *its own* step commits → you get *per-chunk* guarantees, and
you lose the end-to-end clean-500 because you *chose* to flush
early.

Same rule both times. The buffered handler's "guarantees" are not
separate machinery — they are the degenerate-case **corollary** of
the one rule. That is the proof this model is real and not
cosmetic: there is one rule, and buffering is what it looks like
with one step.

> **Implementation status (2026-05-22).** The rule holds end-to-end.
> First-hop chunks: entities in `raft_pending_*` enforce it
> structurally (the entity moves to `stream_response_in` only on
> commit, then h2 ships). Resume-hop chunks (terminal + writes,
> stream + writes): `effect-reification-plan.md` Phase 4.0.b stages
> them on `BufferedSendKvOps.staged_chunks` (`worker.zig`) and
> transfers them onto the entity's `StreamChunks` in the
> `parked_units` commit arm via `transferStagedChunks`; the fault
> arm discards via `BufferedSendKvOps.deinit`. A raft fault during
> a resume-hop writeset now drops the chunk silently — no customer-
> observable wire byte until the activation that produced it
> committed. Gated by `scripts/streaming_resume_fault_inj_smoke.py`.

---

## 3. Inbound: substrate — coalesce budget + size ceilings

> **Customer-facing handler shape lives in
> [`handler-shape.md`](handler-shape.md).** This section covers the
> engine substrate: the coalesce budget, the buffered/streaming
> ceiling, and how the runtime decides which named export to
> dispatch.

The runtime accumulates the request body up to a **coalesce
budget** before invoking the handler.

> **The 1 MB buffered ceiling.** A request body of **1 MB or
> smaller is delivered in a single `default` activation** with
> `request.body` containing the full bytes. This is the customer-
> facing hard guarantee a `default` handler designs against: keep
> bodies under 1 MB and you are unconditionally in the one-step
> world.
>
> Above 1 MB, two paths:
> - If the module exports `onChunk`, the body is dispatched per
>   chunk (internal coalesce budget per chunk: 64 KiB).
> - If the module does NOT export `onChunk`, the runtime returns
>   `413 Payload Too Large` before invoking the handler.
>
> `onChunk` is strictly more general than `default` — it handles
> the small-body case as "one chunk that happens to be the whole
> body" (`request.done = true` on the first fire). `default` is
> the optimization for handlers that opt out of the chunk
> machinery entirely. Full surface in
> [`handler-shape.md` §4](handler-shape.md).

The internal 64 KiB per-chunk coalesce budget matches the
outbound per-chunk default (`max_response_chunk_bytes` in §4.A) —
one number, both directions, never customer-visible for `default`
handlers.

The runtime decides which export to dispatch by introspecting
`module.exports` at load time:

- inbound HTTP → `default` if body fits the 1 MB ceiling and
  `default` exists; else `onChunk` if exported; else 413.
- chunk arrivals → `onChunk`.
- I/O resume → `onSendCallback` / `onFetchResult` / `onFetchChunk`
  / `onFetchDone` depending on the Effect that parked the chain.
- chain origins (cron, kv-react, boot, subscription) → `onCron` /
  `onKvWake` / `onBoot` / `onSubscription`.

See [`handler-shape.md` §3](handler-shape.md) for the full
activation-kind → export-name table and `request` shape per kind.

### What this section used to specify

Before [`handler-shape.md`](handler-shape.md), this section
proposed the customer surface — a soft 64 KiB coalesce budget
with the handler returning one of several options when the body
exceeded it. That surface (and its `__rove_next` / `__rove_stream`
/ `request.activation.kind` plumbing) is superseded by the
two-shape (`default` or `onChunk`) named-export design with a
hard 1 MB ceiling on `default`. The underlying engine — body
accumulation through the readset blob substrate, per-chunk
dispatch, the one-rule commit semantics — is unchanged; only the
customer-visible API changed.

---

## 4. Outbound: a fetch is a stream the chain consumes

Symmetric to the inbound side. An `http.fetch` started by a chain
is an outbound byte-stream, and it too is coalesce-budgeted:

- **Bound to the chain (the default for a held handler).** A
  `http.fetch` issued from a handler that returns `next()`/`stream()`
  auto-binds (`docs/auto-bind-plan.md`) — the fetch's chunks become
  `Msg`s *on the calling chain* (`correlation_id` shared), resuming
  `onFetchChunk`, not a disconnected module. This is the fix for the
  shipped Pattern A: `on_chunk: "module"` (now the `detach: true`
  path) fires a separate chain with no held socket, so the LLM-proxy
  use case (transform each chunk **and** forward it to the held
  client) falls between Pattern A and Pattern B — A sees chunks but
  can't reach the client, B reaches the client but can't see chunks.
  Binding closes the gap, and is now the default:

```js
import { stream, next } from 'rove';

export default function () {
  http.fetch({ url: LLM_URL, body: request.body });   // auto-binds
  return next();                                       // hold the client
}

export function onFetchChunk() {
  if (request.done) return "";                         // close held response
  return stream({ write: transform(request.body) });
}
```

(Surface shape — `default` / `onFetchChunk` named exports,
`stream()` / `next()` Cmds — defined in
[`handler-shape.md`](handler-shape.md). The substrate below is
unchanged.)

- **Coalesced fetch.** A fetch the handler does *not* need
  streamed delivers a single coalesced `fetch_result` Msg with the
  whole response body — the same shape `http.send`'s
  `send_callback` already is. Streamed vs coalesced is the same one
  knob, applied outbound.
- **`pipe_to` is the identity-transform fast path.** "Bind the
  fetch's output stream straight onto the chain's response output
  stream, transform = identity" — the runtime shortcuts the
  per-chunk handler activation entirely (and so, structurally,
  tapes nothing — `project_pipe_to_untaped`). It is not a separate
  concept; it is the degenerate transform of §4's first example.

The durable-vs-transient axis (`webhook.send` vs `http.fetch`) is
**orthogonal** to the coalesce axis. The model does not force those
two to merge; it observes they sit on one matrix:

|              | coalesced result | streamed result |
|--------------|------------------|-----------------|
| **durable**  | `webhook.send` + `send_callback` (JS shim over `http.fetch` + kv markers) | — |
| **transient**| `http.fetch` (coalesced) | `http.fetch` (`on_chunk` / `pipe_to`) |

### 4.A `http.fetch` — the as-built reference

Shipped 2026-05-21. Customer-facing surface for outbound HTTP.
Transient + best-effort: no `_send/owed/<id>` row, no retry on
worker crash, fires immediately. The durable composition
(`webhook.send`, `email.send`) is a JS shim that layers a
`_send/owed/{id}` marker, retry, and on_result chain hop on top of
`http.fetch` — see `effect-reification-plan.md` Phase 5.

**Option set** (`http.fetch(opts) → fetch_id`):

```jsonc
{
  url, method, headers, body, timeout_ms,
  on_chunk: "module/path.mjs",            // Pattern A: fires fetch_chunk per chunk
  on_done:  "module/path.mjs",            // both patterns: fires fetch_done / fetch_pipe_done terminal
  pipe_to:  "held_response" | null,       // Pattern B: bypasses handler, pipes upstream → held client
  headers_passthrough: false,             // pipe_to + this = upstream headers → response headers
  max_response_chunk_bytes: 64*1024,      // per-chunk cap; libcurl writeback chunks past this split
  max_total_response_bytes: 50*1024*1024, // overall cap; cancels the fetch on exceed
  ctx: {...},                             // threaded forward to each activation as request.ctx
}
```

`on_chunk` and `pipe_to` are mutually exclusive — combining them
errors at the binding. Setting `pipe_to` without a held client (no
held entity to write to) also errors. Returns a `fetch_id` for
`http.cancelFetch({id})`.

**Activation Msg shape:**

- **`fetch_chunk`** — `{ fetch_id, seq, byte_offset, bytes, ctx,
  fetch_headers? }`. `bytes` is a `Uint8Array` view; runtime owns
  the buffer; handler must copy to retain past return.
  `fetch_headers` (status + flat header object) on `seq == 0` only.
- **`fetch_done`** — `{ fetch_id, ok, status, trailers, ctx }`.
  Pattern A terminal; no `body` (the body arrived in chunks).
- **`fetch_pipe_done`** — `{ fetch_id, ok, status, bytes_piped,
  dropped_chunks }`. Pattern B terminal (handler isn't invoked
  per-chunk in this path); see `project_pipe_to_untaped`.

**Cancellation:**

- `http.cancelFetch({id})` — cooperative; cancels the libcurl
  handle, fires the terminal activation with `ok: false`.
- `max_total_response_bytes` exceeded — auto-cancels.
- Held entity (pipe target) disconnected — auto-cancels; pipe
  terminates silently, `fetch_pipe_done` fires with `ok: false`.

**Backpressure:**

- `StreamChunks` cap on the held entity (Gap 2.2). The `pipe_to`
  path drives chunks into this same queue; overflow drops + counts
  via `dropped_chunks` on `fetch_pipe_done`.
- `max_response_chunk_bytes` re-chunks libcurl writeback (no drop —
  just smaller activations); `max_total_response_bytes` cancels.
- The per-worker `fetch_chunk_inbox` has its own soft cap;
  overflow drops oldest with a `dropped_chunks` counter on the
  chain.

**Out of scope (v1):**

- **Backpressure to upstream (TCP-level).** v1 buffers in-flight
  chunks at the inbox; doesn't pace libcurl reads. Pace-back via
  `CURLOPT_READFUNCTION` returning `CURL_READFUNC_PAUSE` is a
  follow-up if real customer pull appears.
- **Bidirectional streaming** (handler sends body chunks AND
  receives response chunks) — requires inbound streaming (§3) +
  outbound streaming together + a different binding shape.
- **Multiplexed sends** (one handler tracking N concurrent
  streaming sends with cross-send coordination) — the shape allows
  it (each send has its own `fetch_id`), the ergonomics aren't
  specified.

Implementation lives in `src/js/fetch_pool.zig` (libcurl writeback +
re-chunking), `src/js/worker.zig` (`fireFetchEventActivation`),
`src/js/bindings/http.zig` (the binding). See
`project_gap_2_3_http_fetch` for the shipped-state narrative.

---

## 5. The Msg / Cmd vocabulary under the model

> Customer-visible names live in
> [`handler-shape.md` §2 (Cmds) and §3 (activation kinds)](handler-shape.md).
> The table below is the engine vocabulary — the Msg union the
> dispatcher pattern-matches over and the Cmd values handlers
> return. Renames in the customer surface (`__rove_stream` →
> `stream()`, `__rove_next` → `next()`, no `request.activation.kind`
> switch) are surface-only; the engine's discriminator tags are
> unchanged.

**Cmd — three.**

| Engine Cmd tag | Customer surface | Meaning |
|---|---|---|
| `Response` | string / `{status?, body?, headers?}` return | terminal — emit a final chunk (or the coalesced whole), close |
| `stream` | `stream()` / `stream({write})` | stay held; coalescing off for the directions in play; emit `write` chunks |
| `next` | `next()` | park, await one named resolution (a resume Msg), reinvoke matching `on…` export |

**Msg — every entry is a taped input; bytes content-addressed when large.**

| Engine Msg tag | Dispatched to export | The stream it is a step of |
|---|---|---|
| `inbound` (≤ 1 MB) | `default` (or `onChunk` once) | the request — full `body`, no chunk machinery |
| `inbound_chunk` / `inbound_end` | `onChunk` | the request body, per-chunk delivery (any size when `onChunk` is exported; > 1 MB when `default` is also exported) |
| `fetch_result` | `onFetchResult` | a non-bound fetch's response, coalesced |
| `fetch_chunk` / `fetch_done` | `onFetchChunk` / `onFetchDone` | a bound fetch's response, coalescing off |
| `send_callback` | `onSendCallback` | a durable `webhook.send` result (a coalesced outbound) |
| `wake_batch` | `onKvWake` | kv-write + timer fan-in (§9.4) |
| `disconnect` | `onDisconnect` | the held connection closed |

`fetch_pipe_done` (shipped) is the terminal of the `pipe_to` fast
path. `subscription_fire` (Gap 2.1) dispatches to `onSubscription`
/ `onCron` / `onBoot` depending on origin — chain *origins*, not
stream steps, orthogonal to this model.

---

## 6. Gap 2.5 falls out

A held outbound subscription (atproto firehose, Pub/Sub consumer —
`primitive-gaps.md` §2.5) is, in this model, **a bound outbound
stream that never ends.** Same auto-bind, same `fetch_chunk`
Msgs on the chain; it simply has no `fetch_done`. Reconnect/cursor
policy is the remaining real design (the customer records progress
in their own kv) — but it is no longer a *new primitive*, it is a
lifecycle variant of the bound outbound stream §4 already defines.

---

## 7. Implementation honesty

**The buffered fast-path stays.** A bare `GET` must not pay the
multi-tick held-chain machinery. But it is now *explicitly* derived
as "the coalescing specialization that short-circuits" — the
runtime coalesced both directions, ran one step, shipped. The
discipline: **design and build the streaming case first, let
buffered fall out as `coalesce → invoke once → ship`.** One model;
in code, one model with a fast-path that is provably its one-step
specialization — never a parallel universe.

**Prior art.** `handler-cmds` Phase 8 found "intrinsic divergence"
merging the *resume engines* (`resumeContinuation` /
`resumeStream` / `fireDisconnectActivation`). That was the
continuation-vs-stream-vs-disconnect axis. This model is narrower:
it says only that *the inbound request is a stream and buffered is
its coalesced one-step case*, and that *a bound fetch is a stream
the same chain consumes*. It does not require merging `__rove_next`
(the discrete-await sibling). The model is adopted in full; the
impl keeps the fast-path. Both statements are true at once.

**What is genuinely new work, smallest-first:**

1. auto-bound `http.fetch` (`docs/auto-bind-plan.md`) — fetch chunks
   wake the calling chain (`fetch_chunk` as a real `__rove_stream`
   wake source). Retrofit of the shipped Pattern A; `pipe_to` + transport +
   transient/durable split all untouched.
2. The 1 MB buffered ceiling — coalesce the request body up to the
   ceiling; > 1 MB without `onChunk` exported → 413 from the
   runtime before any handler invocation.
3. The `onChunk` path — `inbound_chunk` / `inbound_end` engine
   Msgs dispatched to the module's `onChunk` export; inbound
   coalescing off; h2 `DATA`-frame → cross-thread chunk inbox
   (reuses Gap 2.3's shape). Small bodies (≤ 1 MB) with no
   `default` export fire `onChunk` once with the whole body and
   `request.done = true`.
4. Inbound backpressure — h2 `WINDOW_UPDATE` gating (real flow
   control); `RST_STREAM` a non-conformant client.
5. Gap 2.5 — bound outbound with no terminal + reconnect policy.

No step changes a shipped buffered handler, a shipped
`__rove_stream` handler, or `http.fetch` Pattern B.

---

## 7.X Substrate — the blob coordinator

The blob coordinator is **the deterministic streaming-bytes substrate
for handler activations**. Its job is to make the bytes a handler sees
addressable + durable so replay can reconstruct them. Storage
efficiency (coalescing, S3 batching) is the means to that end.

Every handler-visible byte stream goes through it: inbound bodies
(>16 KB whole-body or per-chunk streaming), outbound `http.fetch`
chunks (`on_chunk`). The inline path (≤16 KB bodies riding in the
raft entry) and `pipe_to` (bytes flow runtime-to-wire without entering
a handler activation) deliberately bypass — they don't need the
substrate's services.

### 7.1 API

```zig
pub const BlobCoordinator = struct {
    /// One queue entry per Msg the handler would otherwise receive
    /// directly (§7.5). Returns the submission's monotonic sequence
    /// number on the worker's own queue. Ownership of `bytes`
    /// transfers to the coordinator.
    pub fn submit(self: *BlobCoordinator, worker_id: u8, bytes: []u8) !u64;

    /// Per-worker high water mark — every submission on `worker_id`'s
    /// queue with seq <= return value is durable in S3. Atomic load.
    pub fn durableSeq(self: *BlobCoordinator, worker_id: u8) u64;

    /// Lookup the BodyRef for a durable submission. Only valid after
    /// observing seq <= durableSeq(worker_id). PutFailed on terminal
    /// batch failure.
    pub fn bodyRef(self: *BlobCoordinator, worker_id: u8, seq: u64) !BodyRef;
};

pub const BodyRef = struct {
    batch_id: u64,   // globally unique via raft reservation (§7.3)
    offset: u64,
    len: u32,
};
```

The model mirrors raft's `commit_index` exactly: per-worker
`submission_seq` is the analog of `log_index`; per-worker
`durable_seq` is the analog of `commit_index`. The worker's existing
readiness loop polls `durableSeq` (cheap atomic) and walks its
parked-Msg list when the HWM advances. One condvar per worker,
batched wakeup, no per-submission metadata. The park-on-durability
gate IS the HWM check.

### 7.2 Architecture — raft-thread pattern

Three thread classes per node:

- **Worker threads** (N≈4): receive H2 / curl_multi events, assemble
  Msgs, push submissions, park Msgs locally, walk parked list on HWM
  advance.
- **Batch builder** (1, the drainer): single thread, raft-proposer
  pattern. Waits on a single eventfd; on wake, round-robin drains
  every worker's MPSC queue and hands sealed batches to the executor.
- **Executor pool** (K=32 default): one PUT per thread; bounded
  exponential backoff for 503/429 (`Error.SlowDown`); terminal failure
  surfaces via `bodyRef(seq)` returning `PutFailed`.

Total new threads: 1 drainer + 32 executors = 33 per node. K is tuned
to OVH's 117 MB/s wire ceiling (K=32 saturates without timeouts; K=64
saturates with ~7 timeouts/2000; K=128 past the knee). Env override
`ROVE_BLOB_COORDINATOR_K`.

Why this shape:
- No global pending-queue mutex contention (one producer + one
  consumer per queue).
- Matches the existing raft-proposer / fetch-engine convention.
- Worker thread never touches the executor or any cross-process lock.

### 7.3 Object key + batch-id reservation

```
_pool/{batch_id:0>20}     — cross-tenant pool object
```

`batch_id` is globally unique via raft reservation. The leader
reserves a block of N=10000 ids in one raft propose
(`_system/coord_next_pool_batch`), mints from the local block, and
asynchronously prefetches the next block when the current hits 80%
low-watermark. Submit never waits on raft. On leadership change, the
new leader reads the committed counter and reserves strictly above —
old block's unused ids are orphaned gaps (harmless; bucket lifecycle
reaps unreferenced objects).

Cross-tenant pool keys are zipf-tail-friendly: most tenants are small;
per-tenant lanes overrun OVH's ~135 req/s small-object request cap
well before bytes/sec is the bottleneck. The flat prefix surfaces the
per-account request-rate cap instead.

Encryption-at-rest for cross-tenant pools is a deferred design;
callers submit plaintext until an encryption-at-submitter layer slots
between caller and coord.

### 7.4 Batching policy — executor-driven

Body-flush bench data showed fixed size/time thresholds barely matter
at high arrival rates: the implicit batch is "everything that arrived
while the previous PUT was in flight." Threshold approaches misjudge
across workloads.

The coordinator seals on **executor backpressure**:

```
loop {
    wait until executor has a free slot
    drain all currently-pending submissions into a batch
    seal + hand to executor
}
```

Self-tuning: under load, batches naturally grow (more arrivals per
executor cycle); under light load, batches shrink (a single
submission gets PUT immediately). The only bound: per-batch byte cap
(~16 MB) so a single batch doesn't pin too much RAM or exceed a
per-PUT timeout budget. Safety cap, not a tuning knob.

### 7.5 Submission boundary = handler activation boundary

One queue entry per Msg the handler would otherwise receive directly:

| Source | Submission boundary | Notes |
|---|---|---|
| Inbound body (>16 KB, buffered) | Whole body, after H2 END_STREAM | One Msg, one submission |
| Inbound body (streaming, §3) | Each chunk, as H2 DATA frames arrive | Per-chunk activation after durability |
| Outbound `on_chunk` | Each chunk, as curl_multi delivers it | Many Msgs per fetch |
| Outbound `pipe_to` | n/a — bypasses coordinator | Bytes don't enter handler (`project_pipe_to_untaped`) |
| Inline path (≤16 KB body) | n/a — bypasses coordinator | Bytes ride in raft entry directly |

Sub-Msg submissions (one per H2 DATA frame within a buffered body) are
forbidden — they don't correspond to anything the handler sees.
Super-Msg submissions (accumulating across multiple chunks) are also
forbidden — they delay the natural delivery boundary and break the
HWM-advance unpark mechanism.

This is the load-bearing invariant: when worker W's `durable_seq`
advances to N, every parked Msg on W with `seq <= N` becomes
deliverable. Walk the list, fire the callback. No additional metadata
to consult. Replay tape determinism follows: each handler activation
corresponds to exactly one taped Msg, regardless of how coord chose
to batch the underlying bytes.

### 7.6 Invariants

1. **Per-worker `durable_seq` is monotonic non-decreasing.** The
   in_flight tracker uses a sorted set; on batch commit, remove
   completed seqs and advance to `min(in_flight) - 1`. Analog of
   raft's "commit_index only advances over contiguous quorum'd prefix."
2. **BodyRef once issued is stable.** Bytes at
   `(batch_id, offset, offset+len)` are immutable for the BodyRef's
   lifetime. Pool objects never overwritten in place.
3. **Within-worker ordering preserved.** A < B in push order ⇒
   A's seq < B's seq, and `durable_seq` reaches A before B. Across
   workers: no ordering guarantee.
4. **Globally unique batch_id.** Reserved via raft. New-leader-after-
   election starts strictly higher than any prior reservation.
5. **PUT failure surfaces visibly.** Terminal failure does NOT advance
   `durable_seq` past the failed seq; `bodyRef(seq)` returns
   `PutFailed`; the request fails loudly.

### 7.7 Locked rejections (do not re-propose)

- **Compaction of pool objects.** Pool objects are immutable.
  Lifecycle rules expire them after the retention period.
  Compaction-with-reference-rewrite requires a logical-id-indirection
  layer (essentially "rebuild CAS for pool objects") — its own plan.
- **MPU (multipart upload).** Our 16 MB safety cap means we'll never
  produce a single object big enough to benefit. If a future workload
  changes that, MPU goes here as a new subsection.
- **curl_multi migration for blob.** S3 PUTs are bulk-blocking; the
  thread-per-PUT model fits the workload (decided 2026-05-24).
- **Multi-node coordinator coordination.** Each rove process has its
  own coordinator. The 117 MB/s ceiling is per-server; multi-node
  aggregation happens via the obvious "each node uses its own wire"
  pattern.
- **Log batches through the coordinator** (descoped 2026-05-27). Log
  objects are self-describing (sidecar header + deflated frames); the
  indexer discovers them by LIST and parses each as a standalone batch.
  Coord's coalescing model can't preserve that shape without
  redesigning both formats. `log_server/batch_store_s3.zig` keeps
  owning log PUTs.

### 7.8 Open work

**Phase 6 cleanup** (pending): delete dead per-source batching /
threshold code; remove the `ROVE_BODY_FLUSH_POOL_SIZE` env var;
sweep stale comments in worker.zig / worker_dispatch.zig /
worker_drain.zig that still describe the pre-coord per-tenant
BodyBuffer flow.

History: per-tenant lanes (Phases 0-3 shipped 2026-05-27) →
cross-tenant `_pool/` + raft-reserved batch_id (Phase 5 shipped
2026-05-27); see `project_blob_coordinator_state` memory entry.

---

## 8. Open questions

- **`onChunk` per-chunk coalesce sizing.** The 64 KiB per-chunk
  default for `onChunk` matches outbound `max_response_chunk_bytes`
  and is a reasonable starting point; a per-route knob for "small
  chunks for low-latency proxies" vs "large chunks for throughput"
  may be useful later. Defer until a customer needs it.
- **Duplex.** A chain receiving `inbound_chunk`s *and* emitting
  `write` chunks concurrently is expressible in the model (both
  are just steps). v1 may still restrict to "receive fully, then
  respond" by convention — the mechanism does not forbid duplex,
  so lifting the restriction later costs nothing. Decide before
  the `onChunk` response wiring.
- **`fetch_result` vs keeping `http.fetch` streaming-only.** The
  model says a coalesced fetch is natural; whether to actually
  surface `fetch_result` or tell customers "use `http.send` for
  coalesced, `http.fetch` for streamed" is an ergonomics call,
  not a model question.
