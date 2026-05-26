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

### 2.1 Chain origins without an inbound request — **DONE 2026-05-20**

**Shipped.** See `docs/subscriptions-plan.md` §10 for the per-phase
status + load-bearing details. Three chain-origin kinds:

- **kv-react** — apply-time hook fires on the worker that
  committed the writeset; leader-only by construction.
- **boot** — `NodeState` cross-thread inbox + leadership-gained
  sweep; marker injected into handler's writeset for atomicity.
- **cron** — throttled 1Hz in-memory sweep on worker 0 + leader;
  `next_fire_at_ns` per `<tenant>|<name>` is NOT raft-replicated
  (leader change resets the clock by design — missed-tick
  tolerance over false-fidelity).

All three share one collection (`subscription_fire_pending`) +
one fire path (`fireSubscriptionActivation` via the worker's own
dispatcher). The 3 smokes (`streaming_subscription_{boot,kv,cron}_smoke.py`)
gate each path. 12 streaming smokes + heldsync green.

Original motivation + recommendation below for the record.

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

### 2.3 Streaming response bytes from `http.send` — **DONE 2026-05-21**

**Shipped as a new primitive, not an `http.send` extension.** The
durable / at-least-once semantics of `http.send` are wrong for
streaming (a re-fire on crash = a duplicated LLM bill); the gap was
reframed to **`http.fetch`** — a transient, best-effort outbound
sibling. Pattern A (`on_chunk`) + Pattern B (`pipe_to`) + a
`CURLOPT_WRITEFUNCTION` streaming transport all shipped. See
`docs/upstream-streaming-plan.md` (all phases SHIPPED) and
[[project_gap_2_3_http_fetch]]. Original motivation/options below
kept for the record.

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

### 2.5 Held outbound subscription (external-push wake) — **DONE 2026-05-24**

**Shipped via `docs/curl-multi-plan.md` Phase 3.** Distinct surface
from the option-B "decompose into `__rove_stream` with direction
parameter" recommendation below: the JS binding is `http.subscribe`
(a thin shim sibling of `http.fetch`) wrapping a `held: bool` flag
on the existing `PendingFetch` shape. The unified-Cmd refactor is
deferred to the eventual reification Phase 4.X where the Cmd union's
`held_subscribe` variant gets the direction-parameter treatment.

Engine machinery: `FetchEngine` (Phase 2's curl_multi-driven
transport) treats `held=true` PendingFetches with no timeout,
counted against a per-tenant cap (`HELD_MAX_PER_TENANT=16` in
`src/js/fetch_engine.zig`). Cap rejection fires a defined
`final: true, ok: false` event so the customer's `on_chunk`
handler runs once and can surface the condition.

Cancellation via `http.cancelSubscription({id})` — cooperative, per
`curl-multi-plan.md` §5 invariant 3.

Smokes: `scripts/subscription_smoke.py` +
`scripts/subscription_cap_smoke.py`.

Federation prerequisites (atproto firehose CONSUMER) now satisfied
on the transport side; the WS server / framing pieces remain in
separate plans.



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
| 2 | 2.1 chain origins | M | high | crons, inboxes, reconcilers | **DONE 2026-05-20** — kv-react + boot + cron all shipped (see `docs/subscriptions-plan.md` §10) |
| 3 | 2.3 streaming outbound (`http.fetch`) | L | high | LLM proxy, log tail | **DONE 2026-05-21** — reframed to `http.fetch`; see `docs/upstream-streaming-plan.md` |
| 4 | 2.4 streaming inbound body | L | medium | uploads, duplex | pending — unified under `docs/streaming-model.md` |
| 5 | 2.5 held outbound subscription | XL | high (federation) | atproto, WS-origin | pending — unified under `docs/streaming-model.md` |

> **2.3 / 2.4 / 2.5 are one primitive.** The held chain processes a
> stream of Msgs and emits a stream of Cmds; bytes ride as chunks;
> "buffered" is the runtime coalescing that stream by default.
> `docs/streaming-model.md` is the unifying model — 2.3 (shipped) is
> a case of it, 2.4 / 2.5 are derived from it rather than designed
> standalone.

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
- The **bounded tape per chain** discipline (see §6 below).

Any future proposal that violates one of these is by definition not
in this list; it's a §7/§10.1-style locked decision that has to be
relitigated explicitly.

---

## 6. Bounded tape per chain

Replay determinism is a property of inputs being *recorded*, not of
inputs being recordable *forever*. Some primitives produce
unbounded per-chain tape (a streaming upstream fetch's per-chunk
activations; a held outbound subscription's perpetual frames; a
runaway handler in a long-lived chain). Without a bound, those
classes either drown the replay store in cost or force special-
case "this primitive is non-replayable" carve-outs that erode the
"deterministic where it can be" stance.

The bound: **per-chain tape budget** (bytes + entry count), shared
across all activations of one `correlation_id`. Default
~10 MB / ~50k entries; operator-tunable per tenant. Implementation
on `NodeState` (cross-worker map keyed by correlation_id; mutex-
protected) with LRU GC of stale chain entries.

**When the cap fires:**
- A one-shot `tape_cap_reached` marker on the activation that hit
  it (records seq + cause).
- Subsequent activations of the same chain flush log records
  *without* tape payloads (the log record itself still records:
  request metadata, status, console, exceptions — just no
  reproducible-inputs).
- Replay shell shows the chain as **fully replayable up to seq
  N**, **summary-only after**. Per-activation handlers past the
  cap don't re-run during replay — the shell marks them
  "execution past cap — input unavailable" with a path for the
  customer to re-fetch from blob (if bytes were content-
  addressed) or supply a synthetic stub.

**What this unblocks:**
- Streaming primitives (Gap 2.3, 2.5) stop being special-cased.
  LLM proxy chains stay under the cap (~30 KB tape per
  ~3000-chunk fetch); firehose consumers hit the cap quickly and
  degrade gracefully. Both replay-strategies converge on "same
  cap, same overflow marker, same summary fallback."
- The `connection-actor-plan.md` §8 content-addressed-large-bytes
  pattern remains: chunk bytes go to blob; tape carries the hash.
  The cap counts hash-bytes (~50 each), not chunk bodies, so blob
  cost is separate from tape cost — each scales independently.

**Capture mode (deferred to v2).** When concrete storage-cost
feedback arrives, the catalog grows a per-tenant `tape_mode` knob
(`always` | `on_exception` | `sampled` | `never`) that decides
*whether* to persist the scratch tape post-activation, not *how
much* to record. The cap addresses runaway recording (correctness/
safety); capture mode addresses long-term storage cost
(observability/coverage tradeoff). They compose orthogonally —
cap operates during the activation; capture mode operates at
activation boundary. v1 ships the cap; v2 adds capture mode when
the storage bill earns the optionality.

---

## 7. Tape-by-reference for streamed bytes

**The gap.** §6 records chunk bytes by sending them to blob and
keeping the hash in the tape (~50 bytes/chunk). That works for
Pattern A (`on_chunk`) — the bytes cross a handler activation, so
there is an activation to hang a tape entry on. Pattern B
(`pipe_to`) has no activation: upstream bytes are plumbed straight
to the held client by the transport, the handler JS never sees
them, and the chain is **structurally untaped** past the `pipe_to`
Cmd ([[project_pipe_to_untaped]]). A replay reconstructs
everything except the one thing the chain existed to do.

**The mechanism.** Record a stream as a list of **extents** —
`{hash, offset, length}` — instead of inline bytes; the tape holds
the pointer, the bytes live in a content-addressed store, replay
resolves the extents back. Crucially the recording happens at the
**transport layer**, so `pipe_to` gets a tape without the handler
touching a byte. This is §6's pattern lifted from per-activation
to per-transport. The only real variable is *where the bytes
already live*:

- **Tier 1 — source is already a CAS (zero-copy).** A `pipe_to`
  of a static asset out of `file-blobs/` streams bytes that are
  already content-addressed and immutable. The tape records
  `{existing-hash, range}` and copies nothing — the CAS doubles
  as the tape's byte store. Genuinely free; closes the `pipe_to`
  gap outright for static serves.
- **Tier 2 — remote source, bytes cross an activation.** Pattern
  A against a remote upstream. §6 already specs it (copy chunk to
  blob, tape the hash). Unchanged.
- **Tier 3 — remote source, no activation, or full-fidelity
  demand.** The bytes exist nowhere durable; the tape cannot
  reference them until we *make* them content-addressed
  (hash-on-ingest). Not free — it relocates bytes from nowhere
  into CAS. CAS is a defensible home (dedup across replays, the
  page-encryption story, content-addressed-everything), but this
  is relocation, not elimination.

### 7.1 LLM stream tapes (Tier 3, opt-in)

Proxying an LLM token stream is the worst Tier-3 case and the most
valuable one at once. Worst: remote, large, long-lived SSE,
nothing content-addressed at source. Most valuable: an LLM
response is **non-reproducible by re-execution** — re-calling the
API on replay costs money and returns different tokens (even
providers that expose a `seed` parameter document it as
best-effort and void it on any model-version change — there is
no seed we could store and re-run). For a static asset you could
re-fetch; for an LLM stream the tape is the
*only* path to a faithful replay. Without it the chain is not
expensive to replay, it is unreplayable.

That asymmetry is the product argument: LLM-stream tapes are an
**opt-in, plausibly billed** primitive — Tier 3 adds a CAS write
to the streaming hot path, a real cost the customer elects for
replay fidelity available no other way.

**"Write to S3 before calling the handler" — per chunk, not per
stream.** Buffering the whole response before the first activation
destroys streaming: first-token latency becomes last-token
latency, defeating the point of streaming an LLM. The faithful
shape is **persist-before-observe at chunk grain** — each chunk
lands in CAS before its `on_chunk` activation (Pattern A) or
before it is forwarded to the held client (Pattern B).

The hot-path cost is contained by computing the hash **locally**
the instant the chunk is buffered (the tape records the hash at
once) while the S3 PUT runs **async** in the background — the
activation is never gated on the PUT. This mirrors rove's
durability model: local KV commit is fast, raft replication is
the async tail. Tape durability is gated on the flush completing,
the way a write's durability is gated on raft commit.

### 7.2 Caveats

**Self-containment — losing it is not a regression.** The tape
records each non-deterministic boundary input in its minimal
reproducible form, and two forms exist:

- *Generative* — a seed the runtime re-runs to recompute the
  input (arenajs's deterministic PRNG init; a captured clock
  read is the degenerate case). The bytes are stored nowhere,
  the tape stays fully self-contained, total storage shrinks.
- *Referential* — a `{hash, offset, length}` extent the runtime
  *resolves* against a content-addressed store. The hash
  addresses the bytes; it does not generate them, so they must
  persist in CAS.

An extent is referential. A tape carrying extents replays only
while those blobs survive — self-containment is genuinely lost.
But it is lost only for inputs that were never generative to
begin with (an LLM stream, a remote fetch body): there is no
self-contained option for non-reproducible external bytes. The
choice is *inline in the tape* vs *in CAS + hash in tape*, and
the latter is strictly better — dedup, plus retention as an axis
separate from tape size. This is picking the better of two
non-self-contained options, not regressing from a self-contained
one.

The one real obligation is the retention coupling: a blob
referenced by a live tape must be pinned against GC. `rove-files`
already does refcount-pinned snapshots (`TenantFilesSnapshot`),
so this is a refcount edge, not new infrastructure. §6's
per-chain budget bounds *pointer* bytes; blob retention is the
separate axis §6 already named.

**Chunk-boundary determinism splits by pattern.** Boundaries are
network-timing-non-deterministic.

- **Pattern B (`pipe_to`):** the handler never observes
  boundaries, so a single whole-body `{hash, offset, length}`
  extent replays faithfully however the network chunked it. The
  cleanest tape is for the case that has none today.
- **Pattern A (`on_chunk`):** the handler gets a Msg per chunk,
  so the activation sequence depends on the boundaries. The tape
  must also record the **boundary offset list** — still tiny (a
  list of ints), but more than one extent.

### 7.3 Recommendation, blast radius

**Recommendation.** Adopt tape-by-reference as the recording
shape for all streamed bytes; it subsumes §6's per-chunk blob
pattern. Ship **Tier 1 first** (zero-copy extents for CAS-sourced
`pipe_to` — closes the static-serve gap for no copy cost, pure
transport-layer change), then **Tier 3 / LLM** behind a per-call
opt-in flag with the local-hash / async-flush shape above. Tier 2
needs no new work.

**Blast radius.** Extent tape-entry type (`{hash, offset,
length}` + optional boundary-offset list for Pattern A);
transport-layer recording hook in the `pipe_to` path (no
activation); refcount edge from live tape → blob; per-call opt-in
flag + local-hash-then-async-flush staging buffer for Tier 3. The
replay shell's "re-fetch from blob" affordance (§6) generalizes
to "resolve extent from CAS." No Msg/Cmd surface change; no
customer JS surface change beyond the Tier-3 flag.

**Composability unlocked:** replayable `pipe_to` proxies,
replayable static-asset streaming, and full-fidelity LLM-stream
replay as an opt-in premium — the one streaming case where the
tape is the sole path to determinism.

### 7.4 Customer-facing blob primitives — `blob.put` / `blob.get` as JS shims

The §7 mechanism (bytes in CAS, references in tape) also surfaces as a
customer-facing API. Originally specced in `effect-reification-plan.md`
Phase 7 as a Zig `Cmd.blob_put` primitive, revised 2026-05-25 to ship
as JS shims following the `webhook.send` / `email.send` composition
discipline (`effect-algebra.md` §6 rule 4).

**Customer code:**

```js
const hash = await sha256(bytes);             // pure compute, sync
kv.set("manifest/foo", hash);                 // optional: link from manifest atomically
const r = await blob.put(hash, bytes);        // → http_done Msg; bytes land in BlobBackend
const got = await blob.get(hash);             // → http_done Msg; returns bytes
```

Both verbs resolve via callback Msg (same shape as `http.fetch`). The
read is async because the BlobBackend is either S3 (network) or a
shared fs mount (still I/O) — sync access would break the
request-throughput model regardless of backend choice.

**Implementation — both are JS shims composing existing primitives:**

- **`blob.put.js`**: `kv.set("_blob/owed/{hash}", marker)` (rides
  envelope-0 atomic with the handler's other writes) +
  `http.fetch(blob_url(hash), {method: PUT, body: bytes})`. The marker
  carries `{correlation_id, seq, call_index, dest_key}` — **not the
  bytes** (potentially MB-scale, can't fit in kv).
- **`blob.get.js`**: direct `http.fetch(blob_url(hash))` with all
  outbound-HTTP dispositions (whole / `on_chunk` / `pipe_to`). No
  marker, no durability — a failed read surfaces a 503; caller
  retries. Local-BlobBackend fast-path is a shim-internal
  optimization (skip the http round-trip, read from fs directly);
  doesn't change the algebra.

**Recovery for `blob.put` uses re-execution** (`effect-algebra.md` §2.5).
The retry-cron / boot-sub finds stale markers, re-runs the source
activation against its recorded readset, finds the matching `blob.put`
call by `call_index`, extracts the bytes, re-issues the PUT (idempotent
via content-addressing). This works because handler activations are
deterministic functions of `(Msg, Model snapshot, bytecode)` — every
byte a `blob.put` is given is a derivable output of inputs the tape
already preserves.

**Three sharp edges:**

1. **Recovery depends on readset-replication.** Without the readset in
   raft entries (`readset-replication-plan.md`), re-execution can't
   resolve foreign reads (foreign fetches, foreign trigger payloads).
   For v1 (pre-readset-replication), `blob.put.js` ships with
   at-most-once-with-transient-retry semantics — worker crash mid-PUT =
   customer must re-issue. Customer-visible delivery class matches
   Phase 7's pre-revision Cmd-primitive exactly; the cleaner recovery
   story turns on later.
2. **The marker is small even for huge blobs.** Structural benefit
   over a "marker holds the body" pattern (which works for
   `webhook.send` because bodies are small but doesn't scale to MB
   payloads). The trade is a more complex retry path (re-execution
   rather than re-read-from-marker) — same retry-cron + boot-sub
   plumbing, just a fancier "extract bytes" step.
3. **Output bytes are a cache; input bytes are durable.** A
   `blob.put` payload IS a derivable output (`effect-algebra.md` §2.5);
   transient loss is OK because re-derivation works. An incoming
   request body or fetch response body is a durable *input*; loss is
   unrecoverable. Both kinds of bytes share the same BlobBackend and
   are addressed similarly, but their loss-semantics are opposite.
   Customer code doesn't distinguish (both look like "bytes at hash H");
   the engine does, via path namespacing
   (`{tenant}/blobs/{hash}` for outputs, `{tenant}/readset-blobs/{batch_id}`
   for input-buffer batches).

**Inbound streaming bodies (gap 2.4) flow through the same substrate
on the input side.** Bytes go to BlobStore via readset-replication's
per-tenant buffer; `BodyRef` rides the tape; the activation fires only
after `durable_offset` advances past the body's range
(`readset-replication-plan.md` §5). There's no separate "inbound spill
primitive" — the buffer + callback-gate IS the primitive, on the
input-side dual of `blob.put`'s output-side composition. Gap 2.4
becomes "ship readset-replication" rather than designing a new effect.

**The asymmetry that justifies all of this:**

| Direction | Bytes are… | Storage role | Loss semantics |
|---|---|---|---|
| Inbound body chunk / fetch response chunk | recorded **input** | Durable home (no other copy) | Unrecoverable; engine must persist-before-observe |
| Outbound `response.write` chunk | derived **output** | Wire only | Ephemeral; re-derivable |
| Customer `blob.put` payload | derived **output** | Cache (re-derivable) | Transiently unavailable, recoverable from inputs |
| `pipe_to` upstream → wire | neither input nor output of handler | Neither (transit) | Structurally untaped per design |

This is the same asymmetry §6 + §7 carry at the tape layer, surfaced
as a customer-facing API. The rule "only inputs need to be stored
durably; outputs are derivable" makes the engine cheap (no need to
durably store handler outputs except as caches) and the recovery story
unified (re-execute, don't restore-from-redundant-copy).

---

## 8. Minimal read set — drop writes and own-reads from the tape

**SHIPPED 2026-05-26.** RTAP wire bumped 1 → 2. Capture-side:
`globals.zig`'s `jsKvGet` skips the tape append when `state.writeset.containsKey(key)`
(own-read); `jsKvSet` and `jsKvDelete` no longer append at all
(writes are outputs, replay re-issues them). Replay-side: the WASM
host callbacks (`_arena_host_kv_get/set/delete` in
`web/replay/_static/qjs_arena_wasm.js`) now maintain a
`Module._kvOverlay` Map per replay session; `kv.set`/`delete`
write to the overlay, `kv.get` checks the overlay first and falls
through to the tape only on miss (foreign-read path).
`cursor.mjs:_installReplay` resets the overlay between replays.
`kv.prefix` is unchanged — the merge of committed rows + in-range
overlay writes is fiddly enough that the v1 minimization stops at
`.get`. Old §8 write-up below.

---

Where §7 minimizes the *bytes* of a taped input, §8 minimizes
*which operations* are taped at all. The goal: the tape carries
exactly the minimal read set needed to replay the handler.

**Current state.** The `.kv` tape channel records every `kv.get`,
`kv.set`, `kv.delete`, and `kv.prefix` (`src/tape/root.zig`
`KvOp`; the `appendKv` call sites in `src/js/globals.zig`).
Writes carry the written value inline; a `kv.get` of a key the
same activation just wrote is recorded as a full `.get` entry.
The tape is a complete linear transcript, not a minimal one —
inherited from shift-js, where the extra entries fed a
mutation-history view.

**The principle.** Replay re-runs the handler; the tape only
needs the inputs re-execution *cannot* reproduce. Two classes on
the `.kv` channel are reproducible, hence redundant:

- **Writes.** `kv.set` / `kv.delete` are *outputs*. Replay
  re-issues them by re-running the handler; their values are a
  pure function of the recorded reads + the pinned bytecode (the
  `.module` channel's source hash). Nothing about a write is a
  replay input.
- **Own-reads.** A `kv.get(k)` where `k` is in the activation's
  own writeset reads a value the activation itself produced —
  reproducible the same way the write is, not a foreign input.

What remains is the **minimal read set**: gets and prefix scans
resolving to state *committed before the activation began*. That,
plus the date / random / crypto / module channels, is the
complete non-deterministic frontier.

**Capture side.** The activation already accumulates its writeset
for the raft envelope-0 (`TrackedTxn` + writeset). Gate the
`.get` tape append on `key ∉ writeset`; drop the `.set` /
`.delete` appends entirely. One predicate plus two deletions.

**Replay side — the real cost.** Today replay walks the tape
linearly: each `kv.get` consumes the next `.get` entry. With
own-reads dropped, replay must model the writeset overlay
*symmetrically* — re-run the handler, route its `kv.set` /
`kv.delete` into a scratch overlay, resolve each `kv.get` against
the overlay first and fall through to the next tape entry only
when the key is absent. The smarts move from a dumb linear tape
into the replay engine. Consistent with the model (replay already
re-runs the handler), but this is the part that is not free.

**The objection it survives — divergence detection.** Writes on
the tape today let replay diff "did the handler write the same
value?" That check is redundant: with the `.module` source hash
pinned and every *read* channel diffable, a write can only
diverge if a read diverged (caught) or the bytecode differs
(caught). A diverging write is always a symptom of an upstream
input or code mismatch — the real guarantee is complete
input-channel coverage, not a stored output to compare against.

**Wrinkle — `kv.prefix`.** A prefix scan's result is a merge of
committed rows and the activation's own in-range writes. Truly
minimal would record only the committed rows and let replay
re-merge the overlay; that merge logic is fiddly. v1 minimizes
`.get` only and keeps `.prefix` recording the full result list —
follow-up, not v1 scope.

**Blast radius.** Capture: one writeset-membership check on the
`.get` path, remove `.set` / `.delete` appends. Replay: a
writeset overlay in the replay engine + get-resolution order.
Tape size drops — and §6's per-chain budget now counts a
genuinely minimal set. The `KvOp.set` / `.delete` wire variants
stay readable for old tapes but stop being written. No customer
surface change.

---

## 9. Generative channels — record the seed, not the draws

§7.2 split taped inputs into *generative* (a seed the runtime
re-runs to recompute the input) and *referential* (a pointer
resolved against a store). `math_random` is generative — but only
if the PRNG is **bit-identical between the capture engine and the
replay engine**. That precondition is now met.

**Current state.** `Math.random` is already a rove override
(`jsMathRandom`, `src/js/globals.zig`), not qjs's stock random.
It draws from `state.prng` — a rove-owned `std.Random` PRNG
seeded per request — and records *every draw* to the
`math_random` channel as raw f64 bits (one `MathRandomEntry` per
call). The seed and the PRNG already exist; the per-call
recording is the redundant part.

**The unlock.** The client replay engine runs rove's JS *host*
compiled to WASM — arenajs plus the `globals.zig` overrides — so
the same `jsMathRandom` and the same `state.prng` execute on
replay. This matters precisely because `Math.random` is a rove
override: a stock-arenajs replay would run a different PRNG and
not match. `std.Random` PRNGs are pure integer arithmetic, and
WASM's integer semantics are bit-identical to native; the
integer→float scaling is strict IEEE-754 binary64, which WASM
also mandates. So a draw is reproducible from the per-request
seed alone.

**The change.** Collapse `math_random` from O(draws) entries to
**one** — the per-request `state.prng` seed. Replay re-seeds
`state.prng` identically and re-runs; every draw reproduces
bit-for-bit. §7.2's generative form, precondition satisfied.

**Why it is safe.** Same argument as §8's writes: given pinned
bytecode (`.module` source hash) and faithful other channels,
control flow is identical, so `Math.random` is called the same
number of times in the same order and the seed reproduces the
exact sequence. A draw can only diverge if control flow diverged
— which an upstream channel already catches. Per-draw recording
buys no divergence coverage the seed does not.

**The caveat — engine coupling.** Value-recording was robust
against engine drift: a recorded value is the value regardless of
who replays it. Seed-only is not — it assumes the PRNG algorithm
is identical on both sides. Two things contain this: the PRNG is
rove's *own* code, not a third-party black box, so rove controls
whether it ever changes; and capture and replay ship in lockstep
(server vX, client vX), so same-version is the normal path.
Cross-version replay needs an engine/PRNG-version pin on the tape
header (sibling to the `.module` source-hash pin) — replay warns
or refuses on mismatch. A PRNG-algorithm change becomes a
tape-format version bump.

**`crypto.*` — same shape, check the security framing.**
`crypto.getRandomValues` / `randomUUID` can move to seed-only on
the same reasoning *if* rove's crypto RNG is a rove-controlled
deterministic PRNG. The recorded seed then regenerates the
"secure" bytes — but the `crypto_random` channel already stores
those bytes directly, so the secret-in-tape exposure is unchanged
and page-encryption-at-rest stays the mitigation. Follow-up,
gated on confirming the crypto path is rove-owned and
deterministic; `Math.random` is the v1 case.

**Blast radius.** Capture: one seed entry at request start
instead of per-draw appends. Replay: seed `state.prng` from the
tape before running. Tape: `math_random` goes O(draws) → O(1);
the per-draw `MathRandomEntry` wire variant stays readable for
old tapes. Engine/PRNG-version field on the tape header.
`Date.now` is unaffected — a clock read is genuinely external,
not generative, and stays value-recorded.

---

## 10. The complete minimal tape

§7–§9 converge on a closed result: every taped input is one of
**four record kinds** — a minimal read set, a timestamp, a random
seed, or (where bytes live in a content-addressed store) a
`{address, offset, length}` extent. The five channels collapse
onto them:

| Channel | Today | Minimal form | Kind | Section |
|---|---|---|---|---|
| `kv` | foreign gets/prefixes only | foreign gets/prefixes only | read set | §8 ✅ |
| `date` | every `Date.now` | timestamp value (i64) | timestamp | — |
| `math_random` | — (deleted) | one per-request seed | seed | §9 ✅ |
| `crypto_random` | — (deleted) | one seed | seed | §9 ✅ |
| `module` | specifier → bytecode hash | unchanged — already a hash | CAS extent | §7 |

§9 shipped 2026-05-26: `math_random` + `crypto_random` were
retired as dedicated tape channels. arenajs's per-context
xorshift64star is seeded once per request via
`JS_SetRandomSeed(ctx, readset.seed)` in `globals.installRequest`;
`crypto.getRandomValues` / `randomUUID` / `randomBytes` draw from
the same state via `JS_FillRandomBytes`. Replay reseeds with the
captured request's seed via `arena_set_random_seed` (cwrapped from
the WASM build) — no per-draw entries, no host callouts. The
remaining wire channels are `kv` + `date` + `module` +
`fetch_responses` + `trigger_payload` (5 channels, READSET_VERSION
3).

By the §7.2 mechanism axis: the read set and the timestamp are
**direct values** — recorded inline, irreducibly; a clock read is
neither generative nor referential, just a small external number.
The seed is **generative** (re-run to recompute). The extent is
**referential** (resolved against a store).

Two consistencies close the loop:

- **`module` was always a CAS reference.** It records a bytecode
  *hash*, not the bytecode — an address with an implicit
  whole-blob extent. §7 does not invent the CAS-reference pattern
  for the tape; it generalizes the one the module channel has
  used all along.
- **Read set and CAS extent meet at the size threshold.** A small
  kv read is recorded inline; a large one is recorded as an
  extent (`connection-actor-plan.md` §8). Same input — the
  threshold picks the form. The four kinds are not disjoint;
  "extent" is what any oversized value-record becomes.

The activation's own triggering Msg is recorded the same way — a
direct value when small, an extent when large — so it is not a
fifth kind.

That is the whole tape. A minimal read set, timestamps, seeds,
and CAS extents are the entire non-deterministic frontier;
everything else a handler does — every write, every own-read,
every computed value — is recomputed on replay.
