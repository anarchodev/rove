# Streaming inbound body — the `onChunk` export (gap 2.4)

> **Status:** in-flight, 2026-06-10. Implements the locked contract in
> [`handler-shape.md`](handler-shape.md) §3 (activation table row), §4
> (the 1 MB ceiling), §5.3 (worked example), §7 (`request` fields).
> Design constraint: ride the shipped `blob.receive` transport
> (`BodyMode.sink` + drained-repay flow control, `src/h2/root.zig`) —
> **no new h2 surface.**

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

## Slices

- **S1 — vocabulary + probe + single-fire.** `inbound_chunk` variant +
  exhaustive sites; `onChunk` probe cache + `no_onchunk` fallback;
  END_STREAM-≤cap bodies single-fire `onChunk(done=true)`; `request.done`
  / `request.chunkSeq` JS fields. Classic + onHeaders paths untouched.
- **S2 — the chunked path.** Worker `BodySink` + `InboundChunkState`;
  accumulate→chunked switch at the cap; parked-continuation chunk pump;
  drained-on-release backpressure; eof/abort/early-terminal edges.
- **S3 — smoke.** Direct-to-worker (front-door streaming proxy is a
  separate gap): single-fire small body; multi-chunk 5 MB upload with
  per-chunk kv writes proving order + read-your-writes; early-terminal
  reject; mid-upload client abort.
- **S4 — docs.** handler-shape.md drop the "wired as that path is
  reshaped" pend note; effects-and-handlers.md close the gap-2.4 known
  limitation; this plan folds-and-deletes.
