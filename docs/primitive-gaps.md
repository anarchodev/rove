# Primitive gaps — proposals for systematic removal

**Status:** Catalog. No code yet. Each gap below is paired with an
additive option (a new Msg/Cmd/Effect variant grafted onto the
existing model) and a decomposition option (reshape an existing
primitive so the gap becomes a parametric case of it). The
recommendation column picks one per gap; the sequencing section
proposes an order.

This doc is upstream of the sub-plans that will be written when each
gap is picked up (`docs/upstream-streaming-plan.md`,
`docs/subscriptions-plan.md`, etc.). Nothing here ships until that
per-gap plan exists.

---

## 1. The primitive surface today (vocabulary recap)

Handler is `update : (Msg, Ctx) → (Effects, Cmd Msg)` (the TEA
shape — `docs/handler-cmds-refactor-plan.md` Outcome; the
runtime IS the Elm runtime).

| Slot | Variants today | Where defined |
|---|---|---|
| **Msg** (wake source) | `inbound_request`, `send_callback`, `timer`, `kv_wake`, `disconnect` | `streaming-handlers-plan.md` §2 + §4 |
| **Cmd** (return shape) | `Response`, `__rove_next`, `__rove_stream` | `streaming-handlers-plan.md` §3 |
| **Effects** (accumulated in batch) | kv writeset (env-0), `http.send` / `http.cancel` (env-0 `_send/owed/{id}` + leader-local SendDispatch) | `http-send-plan.md`, `apply.zig` |
| **Inline-synchronous side primitive** | kv triggers (BEFORE/AFTER prefix hooks) | `src/js/trigger_dispatch.zig` |
| **Chain identity** | `correlation_id`, `ctx` | `streaming-handlers-plan.md` §5–§6 |

Every gap below either adds a row to this table or reshapes a row so
the gap is a parametric case.

---

## 2. The gaps

### 2.1 Chain origins without an inbound request

**Motivation.** Today every chain begins with an `inbound_request`
Msg — even cron runs (`http.send({url:self, fire_at_ns})` is an
`inbound_request` to your own endpoint) and kv-wake reactivity
(only fires against an *already-parked* stream that was opened by
an inbound request). The "fire-and-forget multi-step state
machine" use case — react to a kv write with no client connected;
run a background reconciler on a timer; consume jobs from an inbox
prefix — has no first-class shape. Streaming-handlers-plan §5
documents this as designed and §5/§6 of the unified activation
model anticipates it, but only inbound-rooted chains are built.

**Sub-shapes:**

- `cron` — fire module M at schedule S (one-shot or recurring).
- `kv-react` — fire module M when any key under prefix P is
  put/deleted (matches the §4.6 wake but originating, not resuming).
- `boot` — fire module M once on deployment activation (run-once
  migrations, index rebuilds).

**Additive (option A).** Add an `activation_source` to the inbound
dispatcher: a per-tenant manifest at `_subscriptions/{name}` →
`{wake: WakeSpec, module: Path}`. Apply-time matches the same way
parked-stream wakes do (`src/js/worker_dispatch.zig` kv-wake
fan-out scan) but instead of resuming a parked chain, it spawns a
fresh chain with no held entity. Msg variants stay the five;
chain origin is just one more entry in the activation-source
union.

**Decomposition (option B).** Realize that a parked stream watching
prefix P with no chunks ever flushed IS the registration. Lift
`_subscriptions/{name}` to be a synthetic "permanently-parked
stream" the runtime owns — registration writes a stream entity to
`parked_streams_active` directly (not via inbound). The §3.3
`__rove_stream` first-hop becomes the registration mechanism: a
deploy hook calls `subscribe(prefix, module)` which writes the
entity. Same code path as customer-arbitrary SSE, just with no
client socket.

**Recommendation: A.** Decomposition (B) tangles deploy-time
registration into the per-request dispatcher in a way that obscures
both ("why is there a parked stream with no socket?"). A is the
honest framing — a chain origin is a different category from a
chain resume; making it explicit costs a small registration
manifest and clarifies the lifecycle (no socket, no disconnect Msg,
no `__rove_next` because there's nothing to flush).

**Blast radius.** New per-tenant manifest, new apply-time
registration scan (folds into the existing kv-wake fan-out scan,
keyed differently). One new Msg sub-variant or `activation.kind`
value (`subscription_fire`). No customer JS surface change
(handlers see `request.activation.kind = "kv" | "timer" | "boot"`
as today). `__rove_next` / `__rove_stream` from a no-socket
origin record but don't flush — already specced in §5.

**Composability unlocked:** customer-built cron, customer-built
queues / inboxes / workflows, customer-built reconcilers,
deploy-time migrations.

---

### 2.2 Backpressure surfaces — implement what's documented — **DONE 2026-05-20**

**Motivation.** `streaming-handlers-plan.md` §9.4 specifies the
wake accumulator (cap-K ring, `overflow.lost_oldest`) and
`write_pressure.dropped_chunks` as the rate-limit surface — both
are the "notify, refetch" thesis applied to pressure. The shipped
implementation was "most-recent-wins" (`PendingKvWake` single slot)
and there was no `write_pressure` field. High-write-rate tenants
got silently aliased wakes.

This was purely a follow-through, not a design question.

**Shipped (Phases A–J, single session).** `PendingWakes` ring
(K=32) + `lost_oldest` counter on `StreamWakes`; `StreamChunks`
gained a 256 KB byte cap + `dropped_chunks` counter; the activation
Msg surface for held streams collapsed from `kv|timer` into a
unified `wake_batch` carrying `wakes: [{kind:"kv"|"timer", …}]` +
`overflow.lost_oldest`; every wake-driven activation also surfaces
`write_pressure.dropped_chunks`. Legacy single-slot `PendingKvWake`
deleted. Two new smokes (`streaming_overflow_smoke.py`,
`streaming_write_pressure_smoke.py`) plus the seven existing
streaming smokes all green. See `project_gap_2_2_backpressure`
memory for the per-phase commit map.

**Additive (option A).** Replace `PendingKvWake` with `PendingWakes`:
ring buffer of K (default 32) wake events + a `lost_oldest`
counter. The activation Msg's `request.activation` grows from `{kv:
{key, op}}` to `{kind: "wake_batch", wakes: [...], overflow: {...}}`
when K>1. Existing single-event consumers stay forward-compatible
because K=1 looks identical (one wake, no overflow).

Chunk queue gets its own bound + `write_pressure.dropped_chunks`
counter exposed on the next activation's request.

**Decomposition.** N/A — this is implementation.

**Recommendation: A.** Direct port of §9.4.

**Blast radius.** `PendingKvWake` → `PendingWakes` component;
serviceParkedStreams accumulation logic; smoke test verifying a
high-write-rate burst surfaces `lost_oldest > 0`. Tape entry
schema grows the wake-batch shape (replay determinism preserved
because the batch IS recorded). ~200–300 LOC.

**Composability unlocked:** customers can tell "rate limited" from
"client slow" from "everything fine" without guessing; refetch
patterns become unambiguous.

---

### 2.3 Streaming response bytes from `http.send`

**Motivation.** Today `http.send` delivers a single buffered
response in the `send_callback` Msg (bounded by `max_body_bytes`).
Use cases that need per-chunk visibility — proxying an LLM's SSE
token stream to a held client, consuming a long-poll feed,
tailing logs from upstream — are unrepresentable. Two sub-patterns:

- **(a) Per-chunk transformation.** Handler wants to see each
  upstream chunk, decide what to forward / aggregate / transform,
  emit a frame on its held client.
- **(b) Transparent proxy.** Handler wants upstream bytes piped to
  the held client with zero per-chunk Msg invocation — fire once,
  return, let the runtime plumb upstream → outbound.

**Additive (option A).** Two new Msg variants:

- `upstream_chunk` — fires per upstream chunk. Carries `{ chunks:
  [bytes], byte_offset, send_id }`. The handler's return is the
  same Cmd vocabulary (`Response` / `__rove_next` / `__rove_stream`).
- `upstream_end` — fires when the upstream connection closes
  (success or error). Carries `{ ok, status, trailers, send_id }`.

Opted into via `http.send({ ..., stream_response: true })`. Without
the flag, today's `send_callback` shape is unchanged.

For pattern (b), the pipe is an **`http.send` option, not a new
Cmd** — `http.send({ url, pipe_to: 'held_response', headers? })`.
The handler then returns `__rove_stream` (no chunks; the upstream
pipe IS the chunks) or `__rove_next` (wait for `upstream_end`
before flushing a terminal `Response`). Keeps the Cmd cap at three
(`streaming-handlers-plan.md` §3.4 — "deliberately capped"); the
pipe is an effect parameter, like `fire_at_ns` or `on_result`.

**Decomposition (option B).** Recognize that an upstream connection
is the *symmetric* shape of an inbound connection — both are a
stream of chunks + an end. Generalize the inbound dispatcher's
body-handling to be the universal "stream of chunks" machinery,
parameterized by direction. `http.send` with `stream_response`
returns an "upstream chain" that is itself a wake-driven chain
(with its own correlation_id), and the per-chunk handler is just
another chain projection. The "pipe" pattern is then "two chains
sharing a chunk queue."

**Recommendation: A.** The pure decomposition (B) is principled
but reshapes a lot of existing code; the additive shape (A) adds
two Msg variants (`upstream_chunk`, `upstream_end`) and one
`http.send` option (`pipe_to`) without disturbing the Cmd cap or
the per-chain identity model. Pattern-(b) — the more common
customer demand (LLM proxy, log tail) — ships as the `pipe_to`
effect; pattern-(a) ships behind the `stream_response` flag.

**Blast radius.** New tape entries for upstream chunks (replay
records the bytes; deterministic). h2 client-side chunk-watch in
the http.send dispatcher. New cap (`max_response_chunk_bytes`,
`max_total_response_bytes`). Bytes go content-addressed past a
threshold to avoid `REQUEST_BODY_CAP`-style truncation
(connection-actor-plan §8). ~1500–2000 LOC est.

**Composability unlocked:** LLM SSE proxy, log tailing,
streaming-API consumption, large-response handling without
`max_body_bytes` blowups.

---

### 2.4 Streaming request body in

**Motivation.** Inbound request body is buffered up to
`REQUEST_BODY_CAP`. Large multipart uploads, duplex protocols,
chunked progress reporting — all unrepresentable from a customer
handler. The files-server multipart endpoint exists as a platform
shortcut but customers can't write their own equivalent.

**Symmetric to 2.3.** Same shape, inbound direction.

**Additive (option A).** New Msg variant `inbound_chunk` carrying
`{ chunks: [bytes], byte_offset }`. Opted into via response header
on the first activation, or by the handler returning `__rove_stream`
from an `inbound` Msg before the body has fully arrived. The
default buffered-body shape is preserved when the handler doesn't
opt in.

**Decomposition (option B).** Same as 2.3 — generalize the chunk
machinery and treat inbound body as one direction of it.

**Recommendation: A, paired with 2.3.** The two gaps share an
implementation (chunked-bytes dispatch through h2) and probably
ship together. If 2.3 picks the decomposition (B), 2.4 must too.

**Blast radius.** h2 inbound chunk demux; `REQUEST_BODY_CAP` becomes
an opt-out for streaming-mode handlers; tape per-chunk recording.
~1000–1500 LOC est. (smaller than 2.3 because outbound chunk
plumbing has more knobs).

**Composability unlocked:** customer multipart, customer
duplex-shaped endpoints, large-payload ingest without the platform
files-server.

---

### 2.5 Held outbound subscription (external-push wake)

**Motivation.** Five Msg variants, only one comes from outside our
control plane (`send_callback`, the completion of *our* outbound
send). Real-time push from third parties — atproto firehose
CONSUMER (`connection-actor-plan.md` §6.5), Pub/Sub long-poll
consumer, AMQP/Kafka bridge, OAuth-provider webhooks where the
provider holds the connection — has no expression. The customer
would need to hold an outbound socket whose lifecycle is
independent of any client connection.

This is the *symmetric* projection of `__rove_stream` — instead of
holding a downstream client socket, hold an upstream provider
socket.

**Additive (option A).** New Cmd variant `__rove_subscribe({ url,
headers?, reconnect?, on_chunk? })` opens a long-lived outbound
connection bound to the chain. Each upstream chunk fires an
`upstream_event` Msg (analogous to `kv_wake` but with the upstream
bytes). Reconnect / catch-up / cursor management is the customer's
problem — they record progress in their own kv.

**Decomposition (option B).** Recognize that `__rove_subscribe` is
just `__rove_stream` with the connection direction flipped:
held-outbound instead of held-inbound. Unify both into one Cmd
parametrized by direction. The runtime's connection-holder owns
both kinds of sockets; the handler's Cmd vocabulary doesn't
distinguish.

**Recommendation: B (decomposition).** The framework principle
that motivated `__rove_stream` is "every held connection is the
same primitive, the direction is a parameter." `__rove_subscribe`
as a separate Cmd repeats the connection-actor-plan §4
copyable-handle mistake (treating projections as distinct
primitives). Same wake-source machinery (the new `upstream_event`
Msg is just `chunk_arrived` with a direction tag), same chunk
queue model, same backpressure surfaces. The Cmd surface stays at
three (Response / next / stream), with `stream` gaining a
direction parameter.

**Blast radius.** Largest of the five. Outbound long-lived socket
infrastructure (libcurl async-mode or a dedicated holder), upstream
auth threading, reconnect/backoff bookkeeping, cap model (per-tenant
simultaneous upstream subscriptions, per-subscription max lifetime
— mirror §9.2). Tape determinism: upstream chunks are taped inputs
the same way inbound message bytes are (`connection-actor-plan.md`
§2). Likely the only gap that justifies a new persistent process
or a major rove-h2 surface change.

This gap is the v1 hard-question for *both* WS transport and
inbound HTTP/1.1 origin — once the upstream-socket machinery exists,
the WS transport cost is "RFC 6455 framing on top of an existing
outbound socket type" rather than "build outbound-socket
machinery + WS framing simultaneously." That's not justification to
do them together; it IS justification to design with the join in
mind. **Federation (`project_fediverse_libs`) is the most likely
forcing function** — atproto consumer + inbound-WS-origin are both
gated on this primitive.

**Composability unlocked:** atproto firehose consumer, Pub/Sub
consumer, third-party webhook receivers where the provider holds
the socket, federation inbound (paired with the WS-transport v2
cost).

---

## 3. Sequencing

Recommended order, smallest-design-debt first:

| # | Gap | Effort | Customer pull | Blocks | Status |
|---|---|---|---|---|---|
| 1 | 2.2 backpressure | S | medium | clean §9.4 story | **DONE 2026-05-20** |
| 2 | 2.1 chain origins | M | high | crons, inboxes, reconcilers | **partial 2026-05-20** — kv-react shipped; boot stubbed; cron deferred (see `docs/subscriptions-plan.md` §10) |
| 3 | 2.3 streaming http.send response | L | high | LLM proxy, log tail | pending |
| 4 | 2.4 streaming inbound body | L | medium | uploads, duplex | pending |
| 5 | 2.5 held outbound subscription | XL | high (federation) | atproto, WS-origin | pending |

**Rationale for the order:**

- **2.2 first** because it's the smallest, finishes a
  documented-but-incomplete surface, and any gap downstream that
  adds Msg variants benefits from the wake-batch + write-pressure
  shape being already settled.
- **2.1 next** because it unblocks the largest set of customer
  patterns (cron, inboxes, reconcilers) for the smallest impl
  footprint after 2.2. It also de-risks the manifest shape that
  2.5 will reuse.
- **2.3 and 2.4 together** as a single project — the
  chunk-dispatch machinery is shared; doing one without the other
  is wasted scaffolding.
- **2.5 last** because it's the largest impl lift, the spec
  questions (reconnect policy, cursor model) are the deepest, and
  it benefits from every prior gap landing first (2.2's
  backpressure surfaces, 2.1's manifest shape, 2.3/2.4's chunk
  machinery).

---

## 4. Out of scope (locked rejections — do not re-propose)

For completeness, these are NOT gaps; they're rejected primitives.
Don't fold them into proposals above.

- **Durable SSE replay log.** `PLAN.md` §7 / `connection-actor-plan.md`
  §10.1 / `streaming-handlers-plan.md` §10.3. Customer composes
  via own kv prefix.
- **Cross-tenant kv subscriptions.** Tenant boundary; route
  cross-tenant via `platform.scope(id).kv` or http.send.
- **Predicate-function kv-wakes.** Would run customer JS on the
  raft apply thread (`streaming-handlers-plan.md` §4.6).
- **Blocking inline external call.** PLAN line 79 Cmd bet
  preserved verbatim internally (`connection-actor-plan.md`
  §10.3); §6.4 held-sync is a *projection*, not a relaxation.
- **Multi-tenant atomic writeset.** Each tenant's app.db is its
  own raft target.
- **WebSocket transport.** PLAN v2 cost; the execution model
  rides this proposal's 2.5 when it lands.

---

## 5. The constraint that holds across all five gaps

Every additive proposal preserves:

- The **affine** discipline (no exposed connection handle in any
  JS surface; the chain IS the connection by construction —
  `project_connection_actor_unified_trigger`).
- The **commit-gated effect** discipline (effects accumulate
  per-batch, fire post-commit; no inline external call).
- The **replayability** invariant (every Msg is a taped input;
  every Cmd is a taped output; large bytes go content-addressed
  per `connection-actor-plan.md` §8).
- The **strike posture** (resource-bound, deadline-bound,
  fail-fast on abuse — `connection_holder_security` /
  `streaming-handlers-plan.md` §9.2).

Any future proposal that violates one of these is by definition not
in this list; it's a §7/§10.1-style locked decision that has to be
relitigated explicitly.
