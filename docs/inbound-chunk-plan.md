# Streaming inbound body — the `onChunk` export (gap 2.4)

> **Status:** S1–S3 SHIPPED 2026-06-10 (`scripts/inbound_chunk_smoke_v2.py`
> green, cache-cold and cache-warm; regression smokes + `zig build test`
> green). Implements the locked contract in
> [`handler-shape.md`](handler-shape.md) §3 (activation table row), §4
> (the 1 MB ceiling), §5.3 (worked example), §7 (`request` fields).
> Design constraint held: rides the shipped `blob.receive` transport
> (`BodyMode.sink` + drained-repay flow control, `src/h2/root.zig`) —
> **zero new h2 surface.** See "Remaining work" below for what keeps
> this plan in-flight.

## The contract being wired (from handler-shape.md)

- Module exports `onChunk` → any-size inbound body dispatches per-chunk:
  `request.body` = THIS chunk, `request.done` flags the last,
  `request.chunkSeq` counts from 0. `next()` awaits the next chunk; a
  terminal responds.
- A body that completes ≤ the cap fires `onChunk` **once** with the
  whole body and `done = true`. Chunk size above the cap is
  implementation detail.
- `default` only: > cap → 413 (today's behavior, unchanged).
- Both exported: ≤ cap body takes the `default` fast path (one buffered
  activation); > cap streams to `onChunk`. (`onChunk` is strictly more
  general; `default` is the small-body optimization.)
- `onHeaders` takes precedence at dispatch (it decides *before* body
  bytes are accepted); `onChunk`-after-`onHeaders` composition is out of
  scope for this slice.

## Design

**Dispatch decision** (worker_dispatch, the `body_inbound.receiving`
branch): onHeaders known-no → consult a second per-(deployment, module)
probe cache, `onChunkLookup`/`onChunkRemember` (mirrors
`onHeadersLookup`). Cached-no → classic buffering (today's path).
Cached-yes or unknown → the chunk path.

**Transport**: attach a worker-owned `BodySink` to the held stream
(`requestBodySink`, same seam `armBlobReceive` uses). Callbacks run on
the worker's own poll thread — no locks. The sink accumulates into a
per-entity `InboundChunkState`:

- **Accumulate phase** (< cap): bytes append to a buffer; `drained()`
  reports them immediately, so the window stays open. Memory is bounded
  by the cap (plan `max_body_bytes`).
- END_STREAM while accumulating → **single fire**: one `.inbound_chunk`
  activation, `body` = whole buffer, `done = true`. (This is the probe
  activation when the cache is unknown.)
- Buffer crosses the cap → **chunked mode**: fire the buffer as chunk 0,
  then per-arrival chunks. From here `drained()` reports bytes only
  after the chunk's activation completes — client send rate throttles to
  handler commit rate (the blob.receive backpressure story, reused).

**Probe**: the first `.inbound_chunk` dispatch probes like
`.inbound_headers` does — `runModule` finds no `onChunk` export →
`RunOutcome.no_onchunk` → roll back the savepoint, cache false, and fall
back: eof'd ≤ cap → re-dispatch the buffered body as classic
`.inbound`; > cap mid-stream → 413.

**Ordering + read-your-writes**: chunk K+1 dispatches only after chunk
K's activation fully resolves (commit + unit release + re-park in
`parked_continuations`) — the WS input-gate property, but expressed as
collection membership instead of a gate flag: the chunk pump only fires
for entities **in `parked_continuations`** with queued chunks. First
chunk dispatches through the normal `dispatchOnce` block; `next()` parks
the entity; the pump resumes it per queued chunk via
`resumeContinuation` with `fn = onChunk`.

**Activation vocabulary**: new `ActivationSource.inbound_chunk` (= 11) +
`Msg` arm (entity-driven like `inbound`/`ws_message` — chunks ride the
entity's component, not the cross-thread queue). Tape: chunk bytes ride
`TapePayloads.activation_bytes` per fire (same as fetch chunks).

**Caps**: with `onChunk` present the per-request body cap does not
apply (the contract: any size); resource bounds come from backpressure +
per-chunk commit. A streaming-total plan knob is future work
(plan-tiers).

**Failure**: client abort mid-stream → sink `abort` → tear down the
held entity (the existing receiving-stream death path); the parked
continuation faults like any disconnected stream. Early terminal while
body inbound → respond + `flipInboundBodyToDiscard` (exists).

## Slices (as-built)

- **S1 — vocabulary + probe + single-fire — DONE** (`d6b9cda`).
  `inbound_chunk` variant + exhaustive sites; `onChunk` probe cache +
  `no_onchunk` fallback; ≤cap bodies single-fire `onChunk(done=true)`;
  `request.done` / `request.chunkSeq` JS fields.
- **S2 — the chunked path — DONE** (`7f5f68c`).
  `src/js/worker_inbound_chunk.zig` Job (the worker-side sink) +
  `worker_drain.zig` `resumeInboundChunk`/`pumpInboundChunks` +
  the dispatch-decision sink arm. As designed, plus: per-fire payloads
  slice at 256 KB (the `.hold` handover arrives as ONE giant push).
- **S3 — smoke — DONE** (`8cbd886`), and it caught three real bugs:
  (1) silent chunk drop when a staged fire was skipped or its resume
  transiently failed — fixed with `staged_consumed` (never stage past
  an undispatched fire; advance bookkeeping only when the activation
  ran); (2) cache-cold whole-body buffering — the `no_onheaders`
  fallback now leaves `receiving` set so the next walk runs the full
  decision; (3) `request.headers` missing on chunk 1+ — `ReqHeaders`
  rides the held entity and the resume threads it.
- **S4 — docs — DONE.** handler-shape pend note dropped;
  effects-and-handlers gap-2.4 limitation closed.
- **S5 — chunk tape — DONE (2026-06-10).** Every chunk fire is a
  recorded, durable-gated activation: the readset's `trigger_payload`
  carries the payload (≤16 KB inline; >16 KB as a blob-coordinator
  BodyRef), real TapePayloads ride every log record, and read-only
  reparks emit the parked-hop record they were missing. The Job became
  a prepared-fires queue so coordinator submissions PIPELINE (the
  serialized first cut cost an S3 RTT per fire). Found + fixed along
  the way: waiting sink entities were re-charging the rate limiter
  every walk (429 mid-upload), and a pre-existing cont_path UAF in the
  post-repark log sites of ALL THREE resume engines (cont-resume,
  bound-fetch, inbound-chunk) — log records carried freed bytes as
  their path. Smoke step 7 asserts 50+ chunk records queryable via
  log-server with both tape forms present.

## Remaining work (keeps this plan in-flight)

- **Front door.** Chunked uploads work direct-to-worker; the front
  door's streaming proxy (a separate known gap) buffers, so the edge
  path inherits its limits until that lands.
- **h1 bodies** arrive complete (no early emission), so an onChunk
  module gets them as one ≤16 MB single fire — fine semantically, but
  the h1 path never streams.
- **Client-abort smoke.** Mid-upload disconnect exercises the
  sink-abort + held-chain disconnect teardown; covered by code paths
  shared with WS/streaming but not yet asserted end-to-end.
- When these close, fold-and-delete per the docs lifecycle
  (mechanics → `architecture/effects-and-handlers.md`, why →
  `decisions.md`).
