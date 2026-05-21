# Upstream streaming — `http.fetch` (a new non-durable primitive)

**Status:** Phase A shipped (types + enum variants) under the
reframe. Implements `docs/primitive-gaps.md` §2.3.

**Reframe note (2026-05-20):** the original framing extended
`http.send` with streaming options. That's the wrong host —
`http.send` is durable + at-least-once (raft-replicated
`_send/owed/<id>` row, retry-on-crash). The streaming use cases
(LLM proxy, large-file proxy) want **transient + best-effort**:
double-fire is bad (double-LLM-cost / wasted bandwidth), durable
persistence of an in-flight token stream is bizarre. So
streaming becomes a separate primitive: **`http.fetch`** — runs
on its own thread pool, no `_send/owed/` row, no retry, fires
immediately. `http.send` stays unchanged for the
"deliver-this-webhook-reliably" pattern.

Capped tape (catalog §6) handles replay determinism for both
fetch and held-subscription cases — chunks accumulate against
the chain's tape budget; pathological streams hit the cap and
degrade to summary-only. No per-primitive replay carve-out.

---

## 1. The shape

Today `http.send` delivers a single buffered response in the
`send_callback` Msg, capped by `max_body_bytes`. Two use cases
are unrepresentable:

- **(a) Per-chunk transformation.** Handler wants to see each
  upstream chunk: decide what to forward / aggregate / transform,
  emit a frame on its held client. Example: proxying an LLM's
  SSE token stream and rewriting frames.
- **(b) Transparent proxy.** Handler wants upstream bytes piped
  to the held client with zero per-chunk handler invocation —
  fire once, return, let the runtime plumb upstream → outbound.
  Example: piping a binary download or an SSE stream where the
  customer doesn't need to inspect frames.

The framework's Msg/Cmd vocabulary already accommodates both with
minimal additions, per the §2.3 recommendation in
`docs/primitive-gaps.md`.

---

## 2. Customer surface

### 2.1 Pattern (a) — per-chunk visibility via `on_chunk`

```js
http.fetch({
  url: "https://api.example.com/stream",
  on_chunk: "transform-chunk.mjs",        // module path; receives fetch_chunk activations
  on_done:  "finalize.mjs",                // optional; receives fetch_done activation
  ctx: { /* threaded forward */ },
});
```

The customer's chain receives a sequence of activations on
`transform-chunk.mjs`:

```js
export default function () {
  const a = request.activation;

  if (a.kind === "fetch_chunk") {
    // a.fetch_id, a.byte_offset, a.bytes (Uint8Array view; not
    // retained past return)
    return __rove_stream({
      write: [`event: token\ndata: ${rewrite(a.bytes)}\n\n`],
      waitFor: { ... },  // next chunk activation comes regardless
    });
  }

  if (a.kind === "fetch_done") {
    // a.fetch_id, a.ok, a.status, a.trailers (headers reachable
    // earlier via a.fetch_headers on first chunk)
    return { /* terminal */ };
  }
}
```

Each upstream chunk fires one `fetch_chunk` activation; the chain
continues until `fetch_done`. The handler's return Cmd
(`Response`/`__rove_next`/`__rove_stream`) is honored per chunk
— customers can interleave outbound writes, fire follow-up
`http.fetch`s or `http.send`s, etc.

### 2.2 Pattern (b) — transparent proxy via `pipe_to`

```js
const a = request.activation;
if (a.kind === "inbound") {
  http.fetch({
    url: "https://upstream/big.mp4",
    pipe_to: "held_response",              // ← bypasses handler; pipes bytes through
    headers_passthrough: true,             // ← optional; mirror upstream headers
    on_done: "finalize.mjs",               // optional; pipe terminal handler
  });
  return __rove_stream({
    headers: { "Cache-Control": "no-store" },
    waitFor: { fetch_pipe_done: "auto" },  // wake when upstream closes
  });
}
if (a.kind === "fetch_pipe_done") {
  return { status: a.source.ok ? 200 : 502 };
}
```

The runtime pipes upstream bytes directly into the held client's
`StreamChunks` queue — no per-chunk handler invocation. The
handler is only re-entered when the upstream connection
terminates (success or failure).

Bytes flow: libcurl writeback → fetch-pool thread → cross-
thread inbox → worker tick → `StreamChunks.tryAppend` on the
held entity → h2 ships. The `StreamChunks` cap from Gap 2.2 §9.4
naturally bounds the proxy's buffering; overflow drops newest +
surfaces via `write_pressure.dropped_chunks` on the eventual
`fetch_pipe_done` activation.

### 2.3 Constraint: `on_chunk` vs `pipe_to` are mutually exclusive

`on_chunk` routes bytes through the handler. `pipe_to:
'held_response'` bypasses the handler. Setting both errors at
the `http.fetch` binding (one or the other; combining them is
incoherent).

### 2.4 Why a separate primitive (not `http.send` extended)

`http.send` is durable: every send writes a `_send/owed/<id>`
row through raft; if the worker dies before delivery, the next
leader's recovery scan re-fires. That's right for "deliver this
webhook reliably" — even at the cost of at-least-once
double-fires.

For LLM proxy: double-fire = double-LLM-cost (~$0.01-$0.10 per
duplicate). For large-file proxy: double-fire wastes bandwidth.
Neither use case wants durable + at-least-once. They want
transient + best-effort.

`http.fetch` is the transient sibling:
- No `_send/owed/<id>` row; no raft involvement.
- No retry on worker crash. (Customer composes retry-with-jitter
  via `retry.js` on top, same as today.)
- Fires immediately — no commit gate. The fetch leaves the
  customer's process within microseconds of the binding call,
  bypassing the propose-then-fire dance that `http.send` does.
- Runs on its own thread pool (`NodeState.fetch_pool`), separate
  from `SendDispatch`. Different saturation domain — a slow
  upstream LLM won't backpressure scheduled-send delivery.

---

## 3. Activation Msg shape

Two new variants on top of the existing five:

```
send_chunk     — { send_id, seq, byte_offset, bytes, ctx, send_headers? }
send_end       — { send_id, ok, status, trailers, ctx }
send_pipe_done — { send_id, ok, status, bytes_piped, dropped_chunks }
```

`send_chunk`:
- `send_id` — the `http.send`-returned id.
- `seq` — monotonic per-send chunk index (0-based).
- `byte_offset` — cumulative bytes received before this chunk.
- `bytes` — the chunk payload (Uint8Array view; runtime owns the
  buffer; valid only during the activation — handler must copy
  if it needs to retain).
- `send_headers` — on `seq == 0` only, the upstream response
  headers (status + flat header object). Null on later chunks
  to avoid re-shipping the same map.
- `ctx` — threaded forward via the chain's existing ctx model.

`send_end`:
- `send_id`, `ok`, `status`, `trailers` — same shape as
  `send_callback` today, but no `body` field (the body arrived
  in chunks).

`send_pipe_done` (`pipe_to` path only):
- `send_id`, `ok`, `status` — terminal upstream state.
- `bytes_piped` — total bytes actually written to the held
  client (after `StreamChunks` cap drops).
- `dropped_chunks` — count from `StreamChunks`. Zero in the
  common case.

---

## 4. `http.fetch` option-set

```jsonc
{
  url, method, headers, body, timeout_ms,
  on_chunk: "module/path.mjs",          // pattern A; fires fetch_chunk per chunk
  on_done:  "module/path.mjs",          // both patterns; fires fetch_done / fetch_pipe_done terminal
  pipe_to:  "held_response" | null,     // pattern B; bypasses handler, pipes upstream → held client
  headers_passthrough: false,           // pipe_to + this = upstream headers → response headers
  max_response_chunk_bytes: 64*1024,    // per-chunk cap; libcurl writeback chunks past this split
  max_total_response_bytes: 50*1024*1024, // overall cap; cancels the fetch on exceed
  ctx: {...},                           // threaded forward to each activation as request.ctx
}
```

`on_chunk` and `pipe_to` are exclusive. Setting `pipe_to`
without an inbound chain (no held client to write to) errors at
the binding. Returns a `fetch_id` string the customer can pass
to `http.cancelFetch({id})`.

---

## 5. Wire-up — where the work lands

### 5.1 libcurl writeback in chunks (SendDispatch thread)

The existing send fires use libcurl `easy_perform` which buffers
the entire response into a memory buffer (`max_body_bytes`). For
streaming, swap in a `CURLOPT_WRITEFUNCTION` callback that:

- For `stream_response: true`: enqueue each chunk into a
  cross-thread "send-chunk inbox" (per-worker, hash(tenant)
  routed — same shape as the Phase D subscription-fire inbox).
- For `pipe_to: "held_response"`: enqueue the chunk into a
  worker-side "pipe inbox" that addresses a specific held entity
  by its tenant + correlation_id.
- For neither: buffer as today.

The chunk size is `min(libcurl chunk, max_response_chunk_bytes)`
— libcurl can deliver multi-MB writeback in one callback; we
re-chunk to keep activations bounded.

### 5.2 Worker-side dispatch

Per-tick drain of the send-chunk + pipe inboxes (the
`serviceSubscriptionFires` analog):

- **`send_chunk` path:** translate inbox → entity in a new
  `send_chunk_pending` collection with components carrying
  `send_id`, `seq`, `byte_offset`, `bytes`, `ctx`. The
  dispatcher fires the bound chain's handler with the activation
  payload (same `fireSubscriptionActivation` shape — chain
  origin without inbound HTTP but with a continuation context
  threading).
- **`pipe_to` path:** look up the held entity by send_id (the
  send was bound at `http.send` time); call
  `StreamChunks.tryAppend` on its chunk queue. No handler
  invocation per chunk.

### 5.3 Held-entity routing for `pipe_to`

`http.send({pipe_to: "held_response"})` requires knowing which
held entity to write to. At `http.send` time, the binding
captures the calling chain's entity id (the one in
`stream_data_out`/`parked_continuations`) and records it on the
send's bookkeeping (alongside `bound_schedule_id`). When the
chunks arrive on the SendDispatch thread, they carry the
recorded entity id; the worker that owns the entity (hash-routed
on tenant) finds it in its h2 collections and `tryAppend`s.

If the held entity has died between `http.send` issue and chunk
arrival (client disconnect, deadline), the pipe terminates
silently; the eventual `send_pipe_done` activation fires with
`ok: false`.

---

## 6. Cancellation paths

Two new cancellation triggers:

- **`max_total_response_bytes` exceeded.** The SendDispatch
  thread cancels the libcurl handle, fires `send_end` (for
  `stream_response`) or `send_pipe_done` (for `pipe_to`) with
  `ok: false, status: 0, reason: "max_total_response_bytes"`.
- **Held entity (pipe target) disconnected.** SendDispatch
  receives a "target dead" signal from the worker (worker's
  disconnect handler tells SendDispatch the pipe is dead),
  cancels libcurl, fires `send_pipe_done` with
  `ok: false, reason: "target_disconnected"`.

The existing `http.cancel({id})` works for both — cancels the
libcurl handle + fires the terminal activation with
`reason: "cancelled"`.

---

## 7. Replay determinism

Each upstream chunk is a **taped input** — same class as a kv
read or an inbound request body byte slice. The tape entry per
`send_chunk` activation records:

- `send_id`, `seq`, `byte_offset`
- The bytes (content-addressed past a threshold — see §8)

Replay re-fires `send_chunk` activations from the tape in order;
the handler runs deterministically. `send_pipe_done`'s
`bytes_piped` is recorded too so a replayed-but-no-real-pipe run
produces an identical activation.

The `pipe_to` path's per-chunk write is NOT recorded as a
handler tape entry (the handler isn't invoked). Instead, the
runtime records a single `pipe_segment` tape entry per
`send_pipe_done` summarizing total bytes + dropped count; replay
of the held-stream chain sees the same `StreamChunks` state it
saw live.

---

## 8. Large chunks — content-addressed path

Per `connection-actor-plan.md` §8: small chunks tape inline;
large chunks (default threshold: 8 KB) go content-addressed.
The tape records the chunk's `hash + size`; the bytes live in
the blob backend. Same treatment as request bodies past
`REQUEST_BODY_CAP` (today the buffered cap; here it becomes an
opt-in for streaming).

Customer-visible: `request.activation.bytes` is a `Uint8Array`
view backed by content-addressed storage; the runtime fetches
lazily on first access from JS. For replay, the WASM arenajs
build resolves the same hash from a local cache or rejects with
"missing replay data."

---

## 9. Backpressure

Two pressure points:

1. **`StreamChunks` cap on the held entity.** Already exists
   (Gap 2.2). The `pipe_to` path drives chunks into the same
   queue; cap-overflow drops + counts via `dropped_chunks`.
   Surfaces on `send_pipe_done`.
2. **`max_response_chunk_bytes` and `max_total_response_bytes`.**
   Bound libcurl-side. Total-cap excess cancels the send; per-
   chunk cap re-chunks (no drop — just smaller activations).

The send-chunk inbox itself has a soft cap (default 1024 pending
chunks per worker); overflow drops oldest with a `dropped_chunks`
counter on the chain. Surfaces on the next `send_chunk`
activation.

---

## 10. Phased build

Each phase keeps build + all 13 streaming/heldsync/ctl smokes green.

### Phase A — Wire-format & types — **SHIPPED**

- 3 new `ActivationSource` variants: `fetch_chunk`, `fetch_done`,
  `fetch_pipe_done`.
- `UpstreamFetchEvent` component (bytes + offset + seq +
  fetch_id + fetch_headers + ctx + variant-specific terminal
  fields).
- Build clean, no behavior change yet.

(Tape encoding for chunk payloads stays as Phase G work, paired
with the §6 tape cap that already covers replay determinism for
both fetch and held-subscription cases.)

### Phase B — `http.fetch` JS binding — **next**

- New `globals.zig` binding: `jsHttpFetch(ctx, opts) -> fetch_id`.
- Option extraction + validation: `on_chunk` vs `pipe_to`
  exclusivity, `pipe_to == "held_response"` only, defaults for
  `max_response_chunk_bytes` / `max_total_response_bytes`.
- `BuiltFetch` carrier struct (separate from `BuiltSend` —
  `http.fetch` is non-durable, so no `_send/owed/` write).
- Returns a `fetch_id` (sha256 of request_id + http_fetch_index,
  deterministic for replay).
- Binding queues the fetch into `NodeState.fetch_pending`
  (a transient list — no kv, no raft). Phase C drains it.
- `http.cancelFetch({id})` binding for cancellation.

### Phase C — Fetch-pool thread + cross-thread chunk inbox — SHIPPED

C1 (`f69fd57`) — producer: `http.fetch` binding → `PendingFetch`
carrier → per-`DispatchState` accumulator → flushed to
`NodeState.fetch_pending` at handler success.

C2 (`3e71cde`) — consumer: `NodeState.fetch_pool` — 8 dedicated
threads (separate `EasyPool` from `SendDispatch`, separate
saturation domain). Each drains `fetch_pending`, fires libcurl,
re-chunks the response into `max_response_chunk_bytes` units,
hash-routes one `UpstreamFetchEvent` per chunk + a terminal to a
per-worker `fetch_chunk_inbox` (mirrors `SubscriptionFireInbox`).

**v1 caveat:** the libcurl call is `Easy.request` (buffered) — the
full upstream body lands in memory before re-chunking, so SSE /
long-lived streams time out at libcurl's per-call deadline. The
`CURLOPT_WRITEFUNCTION` streaming upgrade swaps only that one
call site; the rest of the pipeline is identical.

### Phase D — `fetch_chunk` / `fetch_done` activations (Pattern A) — SHIPPED

- New per-worker rove collection `fetch_event_pending`
  (`UpstreamFetchEvent` component) + `serviceFetchEvents` =
  `drainFetchChunkInbox` (inbox → collection, slices MOVE, no
  re-dup) + `dispatchFetchEvents` (stable-snapshot, `BATCH=64`).
- `fireFetchEventActivation` — twin of `fireSubscriptionActivation`
  (no held socket, forgetful writes); resolves `on_chunk` /
  `on_done` module by kind, correlation_id `fetch-<id>`,
  `request.activation = { kind, fetch_id, seq, byteOffset, bytes
  (Uint8Array), headers? }` (chunk) or `{ kind, fetch_id, ok,
  status }` (terminal).
- `UpstreamFetchEvent` carries `tenant_id` + `on_chunk_module` +
  `on_done_module` so each event is self-describing (no fetch_id
  → module registry).
- Smoke (`scripts/fetch_chunk_smoke.py`): customer GET fires
  `http.fetch({url, on_chunk, on_done})` against a 170-byte
  upstream with a 64-byte chunk cap; verifies 3 `fetch_chunk`
  activations (seq order, byteOffset, ctx round-trip, headers on
  seq 0 only) + one `fetch_done` + byte-exact body reconstruction.

### Phase E — `pipe_to` Pattern B — SHIPPED

- `http.fetch({pipe_to:"held_response"})` stamps the issuing
  chain's `correlation_id` onto the `PendingFetch`; the
  `FetchPool` carries it + a `pipe_to_held` flag onto every
  `UpstreamFetchEvent`. The pipe terminal uses `kind = .pipe_done`.
- New `PipeState` component on the StreamRow: `awaiting_pipe`
  (set by a `__rove_stream({waitFor:{fetch_pipe_done}})` return —
  keeps `serviceParkedStreams` from closing the stream while the
  upstream still feeds it), `bytes_piped`, `done` + terminal
  fields.
- `dispatchFetchEvents` routes `pipe_to_held` events:
  `.chunk` → `pipeAppendChunk` finds the held stream by
  `correlation_id` (scans the 5 h2 stream collections +
  `raft_pending_stream`) and `StreamChunks.tryAppend`s the bytes
  — **no handler activation, no tape** ([[project_pipe_to_untaped]]);
  `.pipe_done` → `pipeMarkDone` stamps `PipeState`.
- `serviceParkedStreams`: once a pipe stream's chunks have
  shipped and `PipeState.done`, fires the single
  `fetch_pipe_done` activation (`resumeStream`); `awaiting_pipe`
  cleared first so it is one-shot.
- `request.activation` for `fetch_pipe_done`: `{ kind, ok,
  status, bytes_piped, dropped_chunks }`.
- Smoke (`scripts/pipe_smoke.py`): customer GET →
  `http.fetch({url, pipe_to})` + `__rove_stream` → the client
  receives the upstream's 170 bytes byte-for-byte; `fetch_pipe_done`
  fires once with `ok=true, status=200, bytes_piped=170,
  dropped_chunks=0`.

**The pipe path is structurally untaped:** piped bytes never
enter a handler `runOutcome`, so there is no activation for the
replay tape to record. The §6 per-chain tape cap is therefore an
`on_chunk` (Pattern A) concern only.

### Phase F — caps + backpressure

- `max_response_chunk_bytes` / `max_total_response_bytes`
  enforced libcurl-side; cancellation path on exceed.
- Send-chunk inbox cap + `dropped_chunks` counter on the chain.
- Smoke: huge upstream response → `dropped_chunks > 0` surfaces
  on `send_pipe_done`.

### Phase G — Replay determinism

- Tape per-chunk entries (small inline, large content-addressed).
- Replay shell consumes them in order.
- Smoke: capture a tape, replay it, byte-identical chunks.

### Phase H — Docs + framing

- Update `streaming-handlers-plan.md` §6 / §4 to reference
  upstream-chunk wakes.
- Update `primitive-gaps.md` §2.3 row to DONE.
- Memory pointer.

---

## 11. Out of scope (v1)

- **Streaming inbound request body (Gap 2.4).** Symmetric
  but covered by its own gap; shares chunk dispatch
  infrastructure once it lands.
- **Backpressure to upstream (TCP-level).** v1 buffers
  in-flight chunks at the inbox; doesn't pace libcurl reads.
  Pace-back via libcurl `CURLOPT_READFUNCTION` returning
  `CURL_READFUNC_PAUSE` lands in a follow-up when real
  customer pull appears.
- **Bidirectional streaming.** Customer sends body chunks +
  receives response chunks. Requires both Gap 2.3 + Gap 2.4
  + a different binding shape; out of scope.
- **Multiplexed sends.** One handler tracks N concurrent
  streaming sends. The current shape allows it (each send
  has its own send_id) but the handler-side ergonomics for
  cross-send coordination aren't specified in v1.
