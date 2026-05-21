# Upstream streaming — `http.send` per-chunk visibility + transparent proxy

**Status:** Planning. Implements `docs/primitive-gaps.md` §2.3
("Streaming response bytes from `http.send`"). No code yet; this
doc is the design before phasing.

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

### 2.1 Pattern (a) — per-chunk visibility via `stream_response: true`

```js
http.send({
  url: "https://api.example.com/stream",
  stream_response: true,                  // ← new flag
  on_result: "transform-chunk.mjs",
  ctx: { /* threaded forward */ },
});
```

The customer's chain receives a sequence of activations on
`transform-chunk.mjs`:

```js
export default function () {
  const a = request.activation;

  if (a.kind === "send_chunk") {
    // a.send_id, a.byte_offset, a.bytes (Uint8Array view; not
    // retained past return)
    return __rove_stream({
      write: [`event: token\ndata: ${rewrite(a.bytes)}\n\n`],
      waitFor: { ... },  // next chunk activation comes regardless
    });
  }

  if (a.kind === "send_end") {
    // a.send_id, a.ok, a.status, a.trailers (headers reachable
    // earlier via a.send_headers on first chunk)
    return { /* terminal */ };
  }
}
```

Each upstream chunk fires one `send_chunk` activation; the chain
continues until `send_end`. The handler's return Cmd
(`Response`/`__rove_next`/`__rove_stream`) is honored per chunk
— customers can interleave outbound writes, fire follow-up
`http.send`s, etc.

### 2.2 Pattern (b) — transparent proxy via `pipe_to`

```js
const a = request.activation;
if (a.kind === "inbound") {
  http.send({
    url: "https://upstream/big.mp4",
    pipe_to: "held_response",              // ← new option, no on_result
    headers_passthrough: true,             // ← optional; mirror upstream headers
  });
  return __rove_stream({
    headers: { "Cache-Control": "no-store" },
    waitFor: { send_pipe_done: "auto" },   // wake when upstream closes
  });
}
if (a.kind === "send_pipe_done") {
  return { status: a.source.ok ? 200 : 502 };
}
```

The runtime pipes upstream bytes directly into the held client's
`StreamChunks` queue — no per-chunk handler invocation. The
handler is only re-entered when the upstream connection
terminates (success or failure).

Bytes flow: libcurl writeback → SendDispatch thread → cross-
thread inbox → worker tick → `StreamChunks.tryAppend` on the
held entity → h2 ships. The `StreamChunks` cap from Gap 2.2 §9.4
naturally bounds the proxy's buffering; overflow drops newest +
surfaces via `write_pressure.dropped_chunks` on the eventual
`send_pipe_done` activation.

### 2.3 Constraint: `stream_response` vs `pipe_to` are mutually exclusive

`stream_response: true` routes bytes through the handler.
`pipe_to: 'held_response'` bypasses the handler. Setting both
errors at the `http.send` binding (one or the other; combining
them is incoherent).

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

## 4. `http.send` option-set additions

```jsonc
{
  url, method, headers, body, fire_at_ns, timeout_ms,
  max_body_bytes,                  // ignored when stream_response or pipe_to set
  on_result,                       // module + fn for send_callback / send_end
  // NEW:
  stream_response: false,          // opt into per-chunk activations
  pipe_to: null,                   // "held_response" | null
  headers_passthrough: false,      // pipe_to + this = upstream headers → response headers
  max_response_chunk_bytes: 64*1024,  // per-chunk cap; libcurl writeback chunks past this split
  max_total_response_bytes: 50*1024*1024,  // overall cap; cancels the send on exceed
}
```

`stream_response` and `pipe_to` are exclusive. Setting `pipe_to`
without an inbound chain (no held client to write to) errors at
the binding.

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

### Phase A — Wire-format & types

- Add `send_chunk`, `send_end`, `send_pipe_done` enum variants
  to `ActivationSource`.
- Define `UpstreamChunk` component (bytes + offset + seq +
  send_id + chain identity).
- Tape encoding for chunk payloads (small inline, large
  content-addressed).
- Build clean, no behavior change.

### Phase B — `http.send` options + binding validation

- Accept `stream_response`, `pipe_to`,
  `max_response_chunk_bytes`, `max_total_response_bytes`,
  `headers_passthrough` on the binding.
- Validate exclusivity (`stream_response` vs `pipe_to`).
- Persist these flags on the `_send/owed/<id>` row (OwedSend
  v2 — bump the version, keep v1 decode for replay).

### Phase C — libcurl writeback callback + cross-thread chunk inbox

- Swap `CURLOPT_WRITEFUNCTION` for streaming sends.
- Per-worker `send_chunk_inbox` (mirror of
  `SubscriptionFireInbox` shape — mutex + ArrayList of owned
  messages).
- SendDispatch fires the callback; per chunk, enqueue to the
  right worker via hash(tenant).

### Phase D — `send_chunk` / `send_end` activations (Pattern A)

- New per-worker collection `send_chunk_pending` + dispatch
  system.
- Worker tick drains the chunk inbox → collection → fires
  handler with `request.activation = { kind: "send_chunk", ... }`.
- On upstream completion, fire `send_end` with the trailing
  metadata.
- Smoke: a handler subscribes to an upstream SSE; verifies it
  receives N chunk activations + one send_end.

### Phase E — `pipe_to` Pattern B

- `http.send` records the calling chain's entity id +
  correlation_id on the send's bookkeeping.
- Chunks arrive → worker-side `pipe_chunk_pending` collection
  (or direct write to `StreamChunks` if the held entity is on
  the same worker).
- `send_pipe_done` activation on upstream close.
- Smoke: customer GET fires `http.send({pipe_to})` and returns
  `__rove_stream`; the client receives upstream bytes
  byte-for-byte.

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
