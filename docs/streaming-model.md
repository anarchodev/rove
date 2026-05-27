# The streaming model — the chain processes streams

**Status:** Canonical streaming reference (model + as-built). Hosts
the design for both directions. Inbound (§3): design locked,
implementation pending (gap 2.4). Outbound (§4 + §4.A): shipped
2026-05-21 as `http.fetch` (gap 2.3); §4.A absorbs the former
`upstream-streaming-plan.md` as the as-built option-set + Msg shape +
caps reference. Gap 2.5 (`http.subscribe`) shipped 2026-05-24 — see §6.

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

## 3. Inbound: the coalesce budget + the handler's three-way choice

The runtime accumulates the request body up to a **coalesce
budget**, then dispatches the chain's first `inbound` step.

> **The 64 KiB guarantee.** A request body of **64 KiB or smaller
> is always delivered in a single `inbound` activation** with
> `request.body_complete === true`. This is the stable contract a
> customer designs against: keep bodies under 64 KiB and the
> three-way choice below never concerns you — you are
> unconditionally in the one-step world. The runtime's coalesce
> budget may in practice be higher, but 64 KiB is the floor that
> will not regress. (64 KiB also matches the outbound per-chunk
> default, `max_response_chunk_bytes` — one number, both
> directions.)

Two outcomes:

- **Body fit the budget** → `request.body` is the whole body,
  `request.body_complete === true`. The overwhelmingly common case,
  and *guaranteed* whenever the body is ≤ 64 KiB.
  Nothing below applies; the handler returns a `Response` and the
  one-step chain ends. **Identical to today.**
- **Body exceeded the budget** → `request.body` is the prefix
  received so far, `request.body_complete === false`. The handler
  is dispatched anyway — with the prefix and the flag — and
  **decides at runtime** what its relationship to the rest of the
  body is. Three replies:

```js
export default function () {
  if (request.body_complete) return process(request.body);  // common case

  // body exceeded the coalesce budget — request.body is a prefix.
  if (!authorized(request.headers)) return { status: 401 };  // (a)
  if (wantWholeThing())             return __rove_next();     // (b)
  return __rove_stream({ accept_body: true });                // (c)
}
```

- **(a) Respond now.** The handler returns a terminal `Response`.
  It has decided it does not need the rest — an auth reject, a
  content-type reject, a handler that only needed the headers. The
  runtime drains and discards the unread body (or `RST_STREAM`s).
- **(b) "Call me back with the whole body."** The handler returns
  `__rove_next`. The runtime keeps coalescing — up to a higher
  **hard ceiling** — and re-dispatches the chain when the body is
  complete, now with `body_complete === true` and the full
  `request.body`. The handler that hit the soft budget but is
  willing to wait for (and can hold) the whole body upgrades to it
  with one line. Beyond the hard ceiling it is a real `413`.
- **(c) Stream me the rest.** The handler returns `__rove_stream`.
  Coalescing for the inbound direction is now **off**: each body
  `DATA` frame is an `inbound_chunk` Msg, an `inbound_end` Msg
  closes it. No whole-body buffering; body size is unbounded.

This is the resolution of the opt-in chicken-and-egg that sank
`inbound-streaming-plan.md`'s static `streaming_body` manifest
flag: **the handler does not need to declare anything.** It is
dispatched with a partial body and a flag, and chooses. Most
handlers never see `body_complete === false` and never think about
any of this.

`__rove_next` here is the *same* `__rove_next` as §6.4's: "park,
await one named resolution, resume." The resolution it awaits is
just "the body is complete" instead of "a bound `http.send`
returned." The Cmd surface stays at three.

A streaming upload is then the one-handler shape:

```js
export default function () {
  const a = request.activation;
  if (a.kind === "inbound")       return __rove_stream({ accept_body: true });
  if (a.kind === "inbound_chunk") { blob.append(a.bytes); return __rove_stream({ accept_body: true }); }
  if (a.kind === "inbound_end")   return { status: 201, body: blob.finish() };
}
```

---

## 4. Outbound: a fetch is a stream the chain consumes

Symmetric to the inbound side. An `http.fetch` started by a chain
is an outbound byte-stream, and it too is coalesce-budgeted:

- **Bound to the chain.** `http.fetch({ url, bind: true })` — the
  fetch's chunks become `Msg`s *on the calling chain*
  (`correlation_id` shared), not a disconnected module. This is the
  fix for the shipped Pattern A: today `on_chunk: "module"` fires a
  separate chain with no held socket, so the LLM-proxy use case
  (transform each chunk **and** forward it to the held client)
  falls between Pattern A and Pattern B — A sees chunks but can't
  reach the client, B reaches the client but can't see chunks.
  Binding closes the gap:

```js
export default function () {
  const a = request.activation;
  if (a.kind === "inbound") {
    http.fetch({ url: LLM_URL, body: a.body, bind: true });
    return __rove_stream({ status: 200 });            // hold the client
  }
  if (a.kind === "fetch_chunk") return __rove_stream({ write: [transform(a.bytes)] });
  if (a.kind === "fetch_done")  return "";            // close
}
```

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

**Cmd — three, unchanged.**

| Cmd | Meaning |
|---|---|
| `Response` | terminal — emit a final chunk (or the coalesced whole), close |
| `__rove_stream` | stay held; coalescing off for the directions in play; emit `write` chunks, declare `waitFor` |
| `__rove_next` | park, await one named resolution (a `send_callback`, or "body complete"), resume |

**Msg — every entry is a taped input; bytes content-addressed when large.**

| Msg | The stream it is a step of |
|---|---|
| `inbound` | the request — `body` coalesced to the budget, `body_complete` flag |
| `inbound_chunk` / `inbound_end` | the request body, coalescing off (chose (c)) |
| `fetch_result` | a bound fetch's response, coalesced |
| `fetch_chunk` / `fetch_done` | a bound fetch's response, coalescing off |
| `send_callback` | a durable `http.send` result (a coalesced outbound) |
| `wake_batch` | kv-write + timer fan-in (§9.4) |
| `disconnect` | the held connection closed |

`fetch_pipe_done` (shipped) is the terminal of the `pipe_to` fast
path. `subscription_fire` (Gap 2.1) is a chain *origin*, not a
stream step — orthogonal to this model.

---

## 6. Gap 2.5 falls out

A held outbound subscription (atproto firehose, Pub/Sub consumer —
`primitive-gaps.md` §2.5) is, in this model, **a bound outbound
stream that never ends.** Same `bind: true`, same `fetch_chunk`
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

1. `http.fetch({ bind: true })` — fetch chunks wake the calling
   chain (`fetch_chunk` as a real `__rove_stream` wake source).
   Retrofit of the shipped Pattern A; `pipe_to` + transport +
   transient/durable split all untouched.
2. `request.body_complete` + the coalesce budget producing a
   partial first `inbound` dispatch instead of a `413`.
3. The (b) path — `__rove_next` from an incomplete-body `inbound`
   re-dispatches the chain on body-complete.
4. The (c) path — `inbound_chunk` / `inbound_end` Msgs; inbound
   coalescing off; h2 `DATA`-frame → cross-thread chunk inbox
   (reuses Gap 2.3's shape).
5. Inbound backpressure — h2 `WINDOW_UPDATE` gating (real flow
   control); `RST_STREAM` a non-conformant client.
6. Gap 2.5 — bound outbound with no terminal + reconnect policy.

No step changes a shipped buffered handler, a shipped
`__rove_stream` handler, or `http.fetch` Pattern B.

---

## 8. Open questions

- **Coalesce budget above the 64 KiB floor.** The 64 KiB
  single-activation guarantee (§3) is fixed. The *budget* — the
  point past which a body is dispatched partial — may sit higher;
  v1 keeps one budget and `REQUEST_BODY_CAP` is the candidate. A
  handler wanting body chunk #1 with *zero* buffering needs budget
  0 (dispatch on headers); defer that per-route knob. v1's fixed
  budget means "first budget-worth buffered, rest streamed," fine
  for uploads and adequate for proxies.
- **Duplex.** A chain receiving `inbound_chunk`s *and* emitting
  `write` chunks concurrently is expressible in the model (both are
  just steps). v1 may still restrict to "receive fully, then
  respond" by convention — the mechanism does not forbid duplex, so
  lifting the restriction later costs nothing. Decide before the
  (c)-path response wiring.
- **`fetch_result` vs keeping `http.fetch` streaming-only.** The
  model says a coalesced fetch is natural; whether to actually
  surface `fetch_result` or tell customers "use `http.send` for
  coalesced, `http.fetch` for streamed" is an ergonomics call, not
  a model question.
- **The flag's name.** `request.body_complete` (bool, `true` in
  the common case so `if (!request.body_complete)` reads right) —
  vs `body_chunked` / a richer `request.body` object. Naming only.
