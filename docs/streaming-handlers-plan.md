# Streaming handlers — `__rove_stream`, wake-driven activations, customer-arbitrary SSE

**Status:** Design exploration (pre-freeze). The shipped primitive is the
one-shot §6.4 trampoline (`__rove_next` + http.send-completion wake + deadline);
this doc describes the **iterative generalization + wake-source extension**
that lets customer-arbitrary SSE endpoints — and more — be expressible as
ordinary handlers. Conceptually, it is the implementation of
`docs/connection-actor-plan.md` **§6.2 (SSE projection)**, which §12 deferred.

The previous "platform SSE" subsystem (`src/sse_server/`, collapsed in-process
by task #10 Phases 1–5 — see connection-actor-plan §12.4) is downstream:
once this lands, the platform-managed SSE pipe dissolves into a JS layer over
the new primitive (§8).

---

## 1. Summary

Today, a customer handler is initiated by exactly two things — an inbound HTTP
request, or an `http.send` completion callback — and is fundamentally
**one-shot**: it runs once, returns a value, and is done. The single
exception (§6.4) lets a handler park its h2 stream and be resumed *once* on
the bound send's completion or the §6.4 deadline. The connection-actor model
(`docs/connection-actor-plan.md` §4) frames this more generally as a wake-
driven primitive with a coalesced multi-source trigger and a long-lived
chain of activations, but only the one-shot, single-wake projection
(§6.1 + §6.4) has been built.

This plan lifts that one restriction at a time:

1. A third handler return shape, **`__rove_stream`**, lets a handler write
   zero or more chunks to its still-open response stream and park awaiting
   the next wake — iteratively, for the lifetime of the held connection.
2. **`__rove_next` works at any activation point**, chained. A send-callback
   hop can return `__rove_next` and fire another send; a kv-write wake can
   return `__rove_stream`; any hop can mix and match. (This subsumes task
   #9 — the 3b-iii read-only-resume restriction is dropped.)
3. **The trigger registry grows three new wake sources**: kv-write match,
   client disconnect, and timer — joining http.send-completion.
4. **The tape records one entry per activation**, all linked by a chain-
   level **`correlation_id`**. Replay groups by chain.

These four pieces compose into "customer writes a handler at `/feed`; it
streams events to an EventSource for as long as the client is connected,
reacting to whatever events the customer wires up." The platform's
sse-service becomes a thin JS layer on top, then disappears (§8).

---

## 2. The unified activation model

The right framing is: **every handler run is a recorded "request,"
regardless of what caused it**. Inbound HTTP, http.send completion,
kv-write match, timer fire, client disconnect — they are all *activation
sources*. They differ in what input they hand to the handler; they don't
differ in how the handler is invoked or how its return value is treated.

```
                    activation source             input to handler
                    -----------------             ----------------
inbound request   ──▶ HTTP method/path/body  ──┐
http.send done    ──▶ {ok, status, body, …}  ──┤
kv-write          ──▶ {key, prefix, …}       ──┼──▶  handler(ctx, event)  ──▶  Response | __rove_next | __rove_stream
timer             ──▶ {firedAt}              ──┤
client disconnect ──▶ {disconnect: true}     ──┘
```

The handler's signature is the same in every case; the activation source
is one field in the request shape (`request.activation` — see §3.3 for the
exact API). What's recorded on the tape and replayed back is the same in
every case.

This is also the model task #9 (effectful resume hops) was reaching for:
a "resume hop" is just *another activation*, and there's no principled
reason it should have a different return contract than the entry hop.
Dropping the 3b-iii read-only-resume restriction (which currently 500s a
send-callback that writes kv or fires `http.send`) falls out of getting
the model right rather than as a separate fix.

---

## 3. The three handler return shapes

### 3.1 `Response` — terminal

What you have today. The handler returns `{ status, headers?, body }`;
the runtime flushes it to the response stream (held or fresh) and closes.
If the chain held a socket from a prior `__rove_next` / `__rove_stream`,
this is what flushes and ends the stream.

### 3.2 `__rove_next` — one-shot resume, **shipped, generalized**

`return __rove_next({ path, fn?, ctx?, waitFor? })`

Today only the §6.4 form exists: omit `waitFor` and the runtime binds the
hop to the single `http.send` this hop just fired, with the §6.4 mandatory
deadline. Under this plan:

- `waitFor` becomes a first-class field, defaulting to the §6.4 inferred
  bind for backwards-compat with already-deployed handlers, but accepting
  any condition from §4.
- A `__rove_next` returned from *any* activation (not just an inbound-
  request hop) is honored — send-callback hops, kv-write wake hops, etc.
  Drops the 3b-iii read-only restriction.

The shape stays "single resume to a terminal value": exactly one more
activation runs after this; if *that* one wants another non-terminal hop,
it returns another `__rove_next` or a `__rove_stream`.

### 3.3 `__rove_stream` — iterative, **new**

```js
return __rove_stream({
  headers?,           // first-hop only: response headers (status, content-type, etc.)
                      // ignored on subsequent hops — the stream is already going
  write?: Chunk[],    // zero or more chunks to flush before parking
                      // (bytes for raw streams; SSE-formatted text for SSE)
  waitFor: Wake[],    // one or more wake conditions; wake on any match
  ctx?,               // threaded forward to the next activation
});
```

Semantics:

- **First-hop** (inbound request returning `__rove_stream`): the runtime
  sends response headers (200 by default; `Content-Type: text/event-stream`
  if the customer set it) and the `write` chunks, then parks the stream
  awaiting any of `waitFor`.
- **Subsequent hops** (wake-driven activations): the handler runs with
  `request.activation` describing the wake event(s) — note "events,"
  plural, because wakes accumulate (§9.4). The handler returns another
  `__rove_stream` (more chunks, more wait) or a `Response` (terminal —
  flush and close).
- **Affine handle, chain-owned.** The held h2 stream entity moves through
  chain-owned cells; one `reg.move` per park; the terminal `Response`
  moves it into the response-out path. Same discipline as §6.4 today,
  longer-lived.
- **Client disconnect** is implicit: every held stream is implicitly
  watching for FIN/RST. When the client closes, the handler runs one
  final time with `{ activation: { disconnect: true } }` so it can do
  cleanup; its return is recorded but no flush happens.

The shape composes: a handler can return `__rove_stream` from an inbound
hop, then `__rove_next` from a wake hop (e.g., "fire an http.send and
wait for it before writing the next chunk"), then `__rove_stream` again,
then a terminal `Response`. The chain carries one held socket through
the whole sequence.

### 3.4 The Cmd-shaped return value (framing)

The three return shapes ARE the customer's Cmd vocabulary. The
handler is `update : (Msg, Ctx) → (Effects, Cmd Msg)` (the Elm
Architecture's central type), where:

- **Msg** = the activation. Five variants today:
  `.inbound_request`, `.send_callback`, `.timer`, `.kv_wake`,
  `.disconnect`. Each carries the relevant payload (request body,
  http.send outcome, the matched kv key, etc.).
- **Ctx** = the chain-level state threaded across activations.
  Customer-visible: their `ctx` JSON from the parent return,
  `request.correlation_id`, the activation-specific
  `request.activation` payload. Runtime-internal but customer-
  observable through replay: the `bound_schedule_id`, the
  deployment, the cell's lifecycle.
- **Effects** = the writeset accumulated via `kv.set` (committed
  through raft for write batches; immediate for read-only chains)
  + the `_send/owed/` arms for `http.send` (commit-gated;
  schedule-server fires after the txn lands).
- **Cmd Msg** = the **return value**:
  - **`Response`** — `Cmd.terminate(response)`. Flush + close.
  - **`__rove_next(...)`** — `Cmd.continuation(next-Msg-source)`.
    The bound condition (default: the `http.send` this hop fired;
    or `waitFor: send.byId(...)` / explicit) IS the next Msg's
    source. One activation will fire when the condition is met.
  - **`__rove_stream(...)`** — `Cmd.stream(initial chunks, wake
    conditions)`. The `write` chunks ship now; the `waitFor` list
    enumerates the wake sources that will produce subsequent
    Msgs. Each wake → one re-entry of the handler.

The runtime IS the Elm runtime. It pumps Msgs through, applies the
Effects (kv + raft + http.send), and routes the Cmd to its
downstream state (response/cont-park/stream-park/disconnect-cleanup).

**Why this framing matters here.** It explains the §4 wake-source
proliferation without ad-hoc-ery: each wake source is "another
Msg variant the runtime can deliver." Adding a new one (e.g., a
SSE-from-upstream subscription) is structural — define the Msg
shape, define how the runtime detects the trigger, route to the
handler — not a new return-value variant. Adding a new return
shape (which we don't anticipate) would be a new Cmd — those are
the customer-facing surface and are deliberately capped at three.

The handler-cmds structural refactor (shipped 2026-05-20,
`streaming-handlers-foundation` `f231a8e`→`6c3f60a`) made this framing
the literal architecture:
chain-level state lives on the entity's components (no side
tables), the entity's collection IS the dispatch state (no enum
flags), and the runtime's three resume engines (`resumeContinuation`
/ `resumeStream` / `fireDisconnectActivation`) each have the same
prep / run / apply phases — they differ only in how they apply the
Cmd, which is intrinsic to the activation type.

---

## 4. Wake sources

### 4.1 The trigger registry

Conceptually the §4 design from connection-actor-plan: a coalesced multi-
source trigger driving activations. Today's implementation has one source
wired (`SendDispatch.Completion` → `dispatchSendCompletions` Part-B peel
→ `resumeBoundContinuation`) plus a deadline sweep. This plan adds three.

A wake source has three responsibilities:

1. **Register interest at park time.** Handler returns a `waitFor`; the
   runtime tells the relevant subsystem "fire on these conditions."
2. **Match at fire time.** When the subsystem observes its event, look up
   the parked continuations whose `waitFor` matches.
3. **Activate the holder.** Hand the matched continuation back to its
   owning worker thread (the affinity model from §6.4 — the holder *is*
   a worker-local entity; the activation must run on that worker).

The registry is per-worker (matching the per-worker `parked_continuations`
collection). Cross-worker matches don't exist — the holding worker owns
the entity, so all matching is local. Cross-*node* matches matter only
for kv-write (see §4.6 + §9.3).

### 4.2 `http.send` completion — shipped

`{ httpSend: { id?: string } }` — wake when the named send completes; if
`id` is omitted, the hop binds to the single send this hop fired (the
existing §6.4 inferred-bind behavior).

### 4.3 §6.4 deadline — shipped

`{ deadline: { absMs: number } }` — wake at absolute wall-clock ms; on
fire the handler runs with `{ activation: { timer: { firedAt: ... } } }`.
Today's `cont_deadline_ns` generalizes to this. The §6.4 hard
< intermediary-timeout cap stays a property of the **§6.4 projection**
(short held-sync HTTP), not of the deadline wake itself — a long-lived
SSE stream can have a deadline a week out if it wants.

### 4.4 Client disconnect — new

**Implicit on every held stream.** Not customer-specified. When the
runtime observes FIN/RST on the held h2 entity, the holding worker
activates the chain's handler once with `{ activation: { disconnect: true } }`.
The handler can write a final chunk (futile — socket is closed, but the
write is recorded on the tape for replay), do cleanup (kv writes,
http.send to an external "session ended" hook), and returns either:

- `Response` — terminal; nothing more.
- `__rove_next` / `__rove_stream` — error (a closed socket can't be
  written or parked further); the runtime logs and treats it as `Response`.

### 4.5 Timer — new

`{ timer: { absMs?: number, intervalMs?: number } }` — wake at an absolute
time, or repeatedly every `intervalMs`. Interval is convenience for the
common SSE heartbeat pattern (`{ timer: { intervalMs: 30_000 } }` →
"wake every 30s so I can emit a `:heartbeat`").

### 4.6 kv-write match — new, **the load-bearing addition**

`{ kv: { prefix: string } }` — wake when *any* key matching `prefix` is
written (`put` or `delete`) by *any* request on this tenant. The handler
runs with `{ activation: { kv: { key, op: 'put' | 'delete' } } }`; it can
then `kv.get`/`kv.list` to read the new state and decide what to do.

**Why prefix-only in v1.** A filter-function variant ("wake only if the
new value satisfies predicate p") would require invoking customer JS at
apply time, on the raft thread, against every committed write — a
correctness/perf hazard out of scope here. Prefix-match is purely a
string comparison at apply time; the wake fires, the handler reads the
new state with normal kv reads, the handler decides relevance. This is
the "notify, don't carry the value" form of the §7 thesis.

**No durable storage of subscriptions.** The wake registration lives in
the per-worker registry alongside the parked continuation. If the worker
dies, the chain dies (its socket dies with it) — same lifecycle as the
held entity. No raft-replicated subscription state; no §7/§10.1
durable-SSE reopening.

---

## 5. Chains and held sockets

A **chain** is one logical interaction: the sequence of activations
beginning with a single origin event and continuing through every
`__rove_next` / `__rove_stream` return until a terminal `Response` (or
client disconnect, or unrecoverable error).

A chain carries:

- **`correlation_id`** — minted by the runtime when the chain begins
  (per §6). Threaded through every activation. The replay UX groups by
  it (§9.1).
- **`ctx`** — customer-supplied opaque JSON, threaded forward by each
  hop's return. The runtime never inspects it.
- **The held h2 entity** — present iff the chain's origin was an inbound
  request and the first hop returned `__rove_next` / `__rove_stream`
  rather than `Response`. Lives in a chain-owned cell; moved on each
  park; flushed-and-closed by the terminal hop.

Chain origins that are NOT inbound requests (a kv-write wake firing a
customer-registered handler with no inbound counterpart; a cron tick)
have **no held entity**. They can still `__rove_next` / `__rove_stream`
to chain further activations — the chain just has no socket to flush to;
`Response` and `write` are recorded but not transmitted. (This is the
shape of "fire-and-forget multi-step state machines" — a different use
case, addressed below.)

Cross-chain interactions (chain A writes kv K; chain B's kv-write-K
wake fires) stay as **two distinct chains**, each with its own
`correlation_id`. Replay UX *can* show "A fired B" as a cross-chain edge
(it's recoverable from the tape via "B's first activation is a kv-write
of a key A's writeset wrote"), but they remain independently replayable.

---

## 6. Tape: one entry per activation; `correlation_id` chains them

Every handler run produces one tape entry. The existing per-request tape
(date/random/kv-read/module-load tapes + console + exception) extends
with two new fields, both filled by the runtime:

- **`correlation_id: string`** — per-chain. Either inherited from the
  parent activation's return, or freshly minted at chain origin.
- **`activation: ActivationSource`** — discriminated union; one of the
  five variants (§2 + §4).

That's the entire schema change. The activation source's payload (the
http.send outcome, the kv-write key, the timer's `firedAt`, etc.) is
the new tape entry's "request body" analogue. The existing dispatcher
records kv reads / date / random consumed during the run; replay
restores them as today.

**Per-activation determinism falls out for free.** Replay any tape
entry: restore `ctx`, `correlation_id`, the activation event, the
recorded kv reads + clock + RNG; the handler runs deterministically.
There is **no separate "wake sequence" to record** — the activations
themselves *are* the recording, and the chain's progression is the
sequence of `correlation_id`-grouped entries in tape order.

**On `correlation_id` minting + propagation.** Inbound request hops
either accept a customer-supplied `X-Rove-Correlation-Id` header
(per-tenant uniqueness + length-cap check) or mint one server-side
(uuid-ish; deterministic-under-replay seeded by request_id). Non-inbound
chain origins (kv-write / timer firing a registered handler with no
upstream chain) mint server-side. Every `__rove_next` / `__rove_stream`
return inherits the parent's id; the customer can't override it. The
handler sees it as `request.correlation_id`.

The existing `request_id` stays per-activation. So one tape row : one
`request_id` : one parent `correlation_id` (one-to-many in the obvious
direction).

---

## 7. Customer-arbitrary SSE — the worked example

A complete user-order-feed endpoint, illustrating the primitive end-to-
end. Customer's tenant has handler at `feed.mjs`:

```js
// feed.mjs — server-sent events of order updates for the logged-in user.
//
// First hop: inbound HTTP request. Authenticate, set up the SSE response,
// emit the initial snapshot, park awaiting changes or a heartbeat tick.
export default function () {
  const activation = request.activation;

  if (activation.kind === "inbound") {
    // First hop. Auth + open the stream.
    const userId = sessions.uid();
    if (!userId) return { status: 401, body: "auth required\n" };

    const initial = JSON.stringify(kv.list(`orders/${userId}/`));
    return __rove_stream({
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
      },
      write: [
        `event: snapshot\ndata: ${initial}\n\n`,
      ],
      waitFor: [
        { kv:    { prefix: `orders/${userId}/` } },
        { timer: { intervalMs: 30_000 } },          // heartbeat
      ],
      ctx: { userId, n: 0 },
    });
  }

  if (activation.kind === "wake_batch") {
    // One or more kv and/or timer events fired; the §9.4
    // accumulator drained them in temporal order. Emit one frame
    // per kv update; a timer-only batch becomes a heartbeat.
    // `activation.overflow.lost_oldest > 0` means the ring filled
    // while the handler was running — re-snapshot kv state and
    // resync clients (the §7 "notify, refetch" thesis).
    const ctx = request.ctx;
    if (activation.overflow.lost_oldest > 0) {
      // Lost wakes — refetch the authoritative snapshot.
      const snapshot = JSON.stringify(kv.list(`orders/${ctx.userId}/`));
      return __rove_stream({
        write: [`event: resync\ndata: ${snapshot}\n\n`],
        waitFor: [
          { kv:    { prefix: `orders/${ctx.userId}/` } },
          { timer: { intervalMs: 30_000 } },
        ],
        ctx: { ...ctx, n: (ctx.n ?? 0) + 1 },
      });
    }
    const frames = [];
    let seq = ctx.n ?? 0;
    for (const w of activation.wakes) {
      if (w.kind === "kv") {
        const order = kv.get(w.key) ?? { deleted: true, key: w.key };
        seq += 1;
        frames.push(`id: ${seq}\nevent: order_update\ndata: ${JSON.stringify(order)}\n\n`);
      } else if (w.kind === "timer") {
        frames.push(":heartbeat\n\n");
      }
    }
    return __rove_stream({
      write: frames,
      waitFor: [
        { kv:    { prefix: `orders/${ctx.userId}/` } },
        { timer: { intervalMs: 30_000 } },
      ],
      ctx: { ...ctx, n: seq },
    });
  }

  if (activation.kind === "disconnect") {
    // Client closed. Nothing to flush; just record the close.
    return { status: 200 };
  }
}
```

**What the customer didn't have to do:**

- No `events.emit()` — there is no platform-managed event bus to push to.
- No JWT token mint endpoint — this endpoint is the customer's own
  surface on their own subdomain, with their own auth.
- No `sid` / `target_sids` routing — the connection IS the routing;
  who's connected is who gets updates.
- No `Last-Event-ID` resume tape — the snapshot at connect time is
  authoritative; the customer's `kv` IS the durable state.
- No ring cache — there's no replay; reconnect re-runs the snapshot.

**What replay shows.** The tape has one row per activation. The replay
UX groups by `correlation_id`: one timeline per connected client,
showing snapshot → kv-wake update → heartbeat → kv-wake update → … →
disconnect. Each row is independently re-runnable (e.g., to debug "why
did this update render incorrectly?" — replay just that activation
against its recorded kv reads).

The same primitive shape covers other long-poll / streaming patterns:
- WebSocket-shaped handlers, modulo the deferred-to-v2 WS transport
  (`connection-actor-plan.md` §6.3 / §10.2 — this plan does not change
  that deferral; when WS lands, it rides this).
- Long-poll endpoints (a degenerate single-wake `__rove_stream`).
- The atproto firehose *consumer* (§6.5 — a different connection-actor
  projection; uses the same trigger registry).

---

## 8. Dissolution of the platform SSE service

Phase 2/3 of task #10 collapsed `sse-server-standalone` into a loop46
in-process thread (connection-actor-plan §12.4). Once `__rove_stream` +
the kv-write wake ship, that thread is the *one specific shape* of an
SSE endpoint that any customer could now write themselves — only
platform-implemented (in Zig) instead of in customer JS.

**The dissolution path (clean break, no back-compat):**

1. **`events.emit` is removed.** No JS shim, no auto-translation to a
   reserved kv prefix. Customers who want SSE write their own
   endpoint (the §7 example shape) and emit by writing to their own
   kv under whatever prefix they choose. Their handler watches that
   prefix and renders frames. The platform never decides what an
   "event" is or where it lives — the customer's kv is the event
   log they choose to maintain.
2. **No system-tenant "platform SSE pipe."** The platform doesn't
   ship a turnkey SSE endpoint at all; the primitive is the surface.
   `__admin__` / `__replay__` / customer tenants that want SSE write
   their own handlers; SSE is no more "platform-managed" than HTTP
   routing is. (If a community library / example deploy materializes,
   fine — but it's not core.)
3. **Delete `src/sse_server/`** entirely (~1100 LOC). The token mint
   route at `/_session/sse-token` is also retired — customer SSE
   endpoints live on customer subdomains with customer auth, so the
   platform-managed-JWT-for-platform-SSE story is moot.

This is downstream of `__rove_stream` + kv-write landing — we don't
schedule it now, but the trajectory is "primitive shipped → platform
SSE service removed wholesale, no compat shim, no migration period."
Consistent with the repo's established clean-break stance (see the
http.send 5b-2 cutover, the schedule-server retirement, task #10's
phase 3 sse-server-standalone deletion).

Note: the platform SSE service is **single-node** after Phase 2 (task
#10). Customer-arbitrary SSE built on this plan is **cross-node-correct
by construction** — kv-write wakes ride raft envelope-0, which applies
on every node; each node's worker fires wakes for its locally-held
streams; no rendezvous needed. So the dissolution path simultaneously
restores cross-node SSE that we explicitly dropped in task #10. (§9.3.)

---

## 9. Cross-cutting concerns

### 9.1 Replay determinism

Already covered in §6 — every activation is a recorded "request," replay
is per-activation, chain navigation is by `correlation_id`. The
elaboration:

- **The tape grows linearly with chain lifetime.** A stream open for an
  hour with 1000 wakes = 1000 tape rows. This is the same per-row size
  as a normal request, so cost scales with *activation* count, not
  open-connection time. A heartbeat-only stream is cheap. A
  high-frequency kv-driven stream is proportionally expensive.
- **Each row is independently replayable.** Picking one row to debug
  doesn't require replaying the whole chain. Customer's local
  development workflow (replay shell, `web/replay/_static/`) presents
  the chain as a navigable timeline; clicking any row restores its
  state in the deterministic-JS sandbox.
- **The tape is the wake log.** There's no separate subscription /
  registration state to record. The kv-write that fired the wake is
  recorded in some *other* chain's tape entry (the chain that did the
  write); the cross-chain edge is recoverable but not separately stored.

### 9.2 Resource caps and strike posture

A held stream is potentially long-lived; without caps, customers can
exhaust workers' `parked_continuations` collections. Borrowing the
§6.4 / `connection_holder_security` memory's strike model:

- **Per-tenant cap on simultaneous held streams** (default in the
  thousand range, configurable in the operator config tier). Hitting
  the cap = 503 on new connection attempts to streaming endpoints.
- **Per-stream max lifetime** (default ~1 hour; configurable). Forces
  a wake at the lifetime ceiling so the handler can choose to terminate
  cleanly (and the client can reconnect to renew).
- **Per-stream activation budget**. A misbehaving handler that fires
  100k kv-wakes/sec by writing to its own watched prefix is contained
  by a counter-budget per stream-lifetime.
- **Strike posture on slow consumers.** If a client's h2 send buffer
  stays full for some threshold, the runtime closes the stream — same
  as the existing SSE thread does today.

Caps land alongside the primitive — not a follow-on. The whole point of
the strike model is that "open a connection that lasts forever" must
have a hard backstop visible to the operator.

### 9.3 Cross-node correctness

The standout architectural property. Wake sources split into two classes:

- **Raft-replicated wakes:** `kv-write match`. Every node's apply sees
  the writeset; each node's worker matches against its own locally-held
  streams. **No cross-node bus needed** — the raft log IS the bus.
  Fan-out is automatic and node-local; cross-node correctness is
  achieved without reinventing the cross-process rendezvous that
  task #10 retired.
- **Node-local wakes:** `http.send completion` (leader-local in Option
  (b)), timers (local), disconnect (local). These remain local-to-the-
  holding-worker by definition; their semantics don't require fan-out.

Net effect: **customer-arbitrary SSE works correctly across nodes**,
which the post-task-#10 platform sse-service doesn't. This is the
property that makes the dissolution (§8) a net gain rather than a
parity move. Calling it out so we don't lose sight of it.

The single-node restriction from task #10 (`--sse-listen` + multi-node
`--peers` = hard fail) was needed precisely because the platform
sse-service uses a node-local emit queue with no cross-node story.
Customer-arbitrary SSE on this plan doesn't have that restriction;
when §8 dissolves the platform service, the single-node guard goes
with it.

### 9.4 Wake accumulation + write-pressure (the rate-limit model)

The runtime never silently drops, never platform-decides a policy.
Instead, **both wake-side and write-side pressure are made visible to
the handler in the next activation**, and the handler chooses what to
do. The model has two coupled pieces:

**Wake accumulator (debounce by construction).** Each parked stream
has a bounded **wake accumulator** (ring buffer, cap K — initial v1
target K=32). While the handler is running its current activation, or
is queued to run, incoming wakes append to its accumulator instead of
launching a new activation. When the runtime is ready for the next
activation, it hands the entire accumulator to the handler in one go:

```js
request.activation = {
  kind: 'wake_batch',
  wakes: [                 // most-recent K, oldest first
    { kind: 'kv',    key: 'orders/u/12', op: 'put' },
    { kind: 'kv',    key: 'orders/u/13', op: 'put' },
    { kind: 'kv',    key: 'orders/u/12', op: 'put' },  // dup OK
    { kind: 'timer', firedAt: 1730764800000 },
    // … up to K
  ],
  overflow: { lost_oldest: 968 },   // wakes that fell off the ring
                                    // before this activation could read them;
                                    // 0 in the common case
};
```

The bounded ring **is the rate limit**: a stream getting 10k kv-writes/sec
across its watched prefix can't burn 10k activations/sec — at most
~1 activation per handler run, each draining up-to-K wakes. Behavior
under load is deterministic and visible: the handler sees `lost_oldest`
> 0 in its next activation and knows it should re-read kv state from
scratch (per §7 — refetch, don't try to replay).

**Inbound / disconnect / send-callback activations are NOT batched.**
The accumulator only applies to "the runtime fires my handler because
some wake matched" — the originating inbound request is a single
event, disconnect is a single terminal event, an http.send completion
is a single bound event. Only the high-frequency-potentially wake
sources (kv-write, timer) accumulate.

**Write-pressure (same shape, write side).** Each stream has a
bounded **chunk queue** between the handler's `write` return and the
h2 socket. If the handler returns more chunks than the queue can
hold, or the socket can't drain fast enough and the queue overflows,
the runtime drops the excess (newest-first — preserves the start of
stream; oldest content is what the customer already chose to send) and
increments a per-stream counter. The next activation sees:

```js
request.activation.write_pressure = { dropped_chunks: 7 };
```

The handler decides: terminate the stream with a `Response`, emit a
"resync to current state" frame (the natural §7 response), throttle
back, summarize, ignore. Platform doesn't policy-decide; it surfaces.

**Tape:** the wake accumulator + write-pressure metadata land on the
tape entry alongside the activation; replay reproduces the same
inputs (`wakes`, `overflow.lost_oldest`, `write_pressure`) — so a
debugging session against a high-load stream sees exactly the
rate-limited inputs the production run saw.

**Composition note.** The wake-accumulator model means "rate limited"
and "client is slow" surface in the same place (the next activation's
metadata) with the same handler-side response option (emit a fresh
snapshot from kv). Two failure modes, one user-visible API. The §7
"notify, refetch" thesis is what makes this work — the platform never
has to carry a value forward through the pressure, because the
authoritative value is in kv.

### 9.5 Security model

Per the `connection_holder_security` memory + `connection-actor-plan.md`
§12.2: the "no exposed handle, anywhere" property is what makes the
held-connection security model work. This plan preserves it:

- The chain's held entity is not referenceable from customer JS — there
  is no opaque "connection handle" the customer holds; the connection
  is *implicit* in the chain (you got an activation; you return a value;
  the runtime knows which entity to write to).
- `ctx` is just JSON; it can't carry pointers to entities, foreign
  chains, other tenants' state, or anything privileged.
- Cross-chain coupling happens via kv (the customer's own kv writes
  fire other chains' kv-wakes). No JS surface for "wake chain X
  directly." Customers compose by writing state; the runtime composes
  by watching state.
- `waitFor` conditions are inspected at registration time; the runtime
  refuses kv-write subscriptions that would cross tenant boundaries.

The §6.4 strike posture (resource-bound, deadline-bound, fail-fast on
abuse) extends to streaming-handler endpoints without modification.

---

## 10. Reconciliation with locked decisions

### 10.1 connection-actor-plan §6.2 — finally implemented

§6.2 described "SSE projection" as "a connection-actor with an empty
inbound frontier and ephemeral application durability" but deferred its
implementation. This plan IS that implementation. The projection
contract (no durability, no platform state store, reconnect →
state-refetch) is preserved exactly; only the implementation venue
moves from "the platform sse-service holds it" to "customer JS holds
it via `__rove_stream`."

### 10.2 connection-actor-plan §12.4 — completed by dissolution

§12.4 (added in task #10 Phase 4) recorded the collapse of the
sse-service into a loop46 thread, single-node only, cross-node fan-out
explicitly dropped. This plan completes the picture: §8's dissolution
removes the thread entirely; cross-node fan-out comes back via the
raft-replicated kv-write wake (§9.3). The single-node restriction is
correspondingly lifted when the dissolution lands.

### 10.3 §7 / §10.1 durable-SSE rejection — unchanged

`PLAN.md` §7 / `connection-actor-plan.md` §10.1: the `_events/{sid}/{seq}`
raft-replicated SSE store is rejected, durable SSE is not a platform
primitive. **Unchanged by this plan.** kv-write wakes are a *notification*
mechanism on the customer's already-durable kv — the customer's app.db
remains the source of truth, the handler refetches authoritative state
on each wake, the platform stores no SSE-specific durable data. Same
"notify, don't store; refetch, don't replay" thesis.

The temptation when sketching streaming handlers is to grow them into
"replay-on-reconnect from a platform-managed log." We're not doing that.
A customer who wants replay implements it themselves by writing events
to their own kv and reading them on reconnect — same shape as the
worked example's "initial snapshot."

### 10.4 task #9 (effectful resume hops) — subsumed

Task #9 was scoped as "lift the 3b-iii read-only-resume restriction so
a send-callback handler can write kv and re-issue `http.send`." That's
exactly what §2's "every activation can return any of the three shapes"
delivers — but framed correctly (the asymmetry was the bug, not the
restriction). Task #9 closes when this plan's Phase 3 (§12) lands; no
separate work.

### 10.5 PLAN §13 process map

No new process. The wake registry, kv-write apply-time scan, timer
sweep, and disconnect detection all live in the existing worker thread
that already owns `parked_continuations`. PLAN §13 gets one bullet in
the loop46 row (a wake-registry alongside SendDispatch / the connection
trampoline), nothing more.

### 10.6 Phase 2 client-side determ-SDK / replay shell

`web/replay/_static/`'s rendering already groups by `request_id`; the
`correlation_id` extension is one new field threaded through and one
new grouping axis in the timeline UI. The arenajs WASM build replays
each activation deterministically as today. No new Zig in the replay
shell.

---

## 11. Open questions

These are real design choices the implementation must make. None
block the overall plan, but each affects the API customers see.

**Resolved (folded into the design above), kept here for the record:**

- *Backpressure policy* — surface to handler via accumulator overflow
  + `write_pressure.dropped_chunks`; no platform-imposed drop/park
  policy. §9.4.
- *Wake debounce* — per-stream bounded accumulator coalesces wakes
  while the handler is running or queued; one activation drains the
  batch. §9.4.
- *`events.emit` migration* — removed wholesale, no back-compat shim;
  customers BYO SSE via their own kv prefix. §8.
- *`waitFor` ergonomics* — array of conditions, wake on any match.
  §3.3 + §4.

**Still open:**

### 11.1 kv-write wake granularity beyond `prefix`

`{ kv: { prefix } }` is the minimum + `op: 'put' | 'delete' | 'any'`
filter is the only no-cost add (apply-time string + tag check). Past
that: exact-key match is trivial; per-tenant-prefix-debounce is
subsumed by the wake-accumulator (§9.4 — debounce-by-default at the
stream level handles it without per-subscription state). Predicate
functions remain out of scope (§4.6 — would run customer JS at apply
time on the raft thread).

### 11.2 Disconnect-during-flush ordering

Edge case: the runtime starts flushing the chunks returned by a hop,
the client closes mid-write, the disconnect wake fires. Two activations
"in flight" for the same chain. Resolution: the flush and the
disconnect-activation are serialized on the holding worker (worker
owns the chain); the activation completes, then the disconnect runs.
Tape order matches execution order. Should be confirmed at smoke time.

### 11.3 Per-activation budget

Today's request budget (Budget.default_duration_ns ~ 10 s) is per-
request. For wake-driven activations on a long-lived stream, does each
wake get a full fresh budget, or a smaller one to bound cumulative
cost? Default fresh-per-activation; the per-stream activation budget
(§9.2) handles the cumulative case. Confirm at implementation time.

### 11.4 Accumulator ring size K

§9.4 picks K=32 as a starting target. Too small = `lost_oldest > 0`
frequently on real load and customers see surprise re-snapshots; too
big = each activation pays a per-wake processing cost over a wide
batch. Pick at smoke time once we see real wake rates; the per-stream
configurability hook is cheap to leave in.

---

## 12. Phased build

Mirroring the stepped-phase cadence from tasks #1–#10. Each phase is
independently shippable, builds + tests green at the end. Phases land
in order; later phases depend on earlier ones.

### Phase 1 — Tape: correlation_id + activation source

Smallest, foundational. **No new primitive yet.**

- Add `correlation_id: ?[]const u8` to `dispatcher.Request` (request
  shape) + the tape entry header.
- Add `activation: ActivationSource` (tagged union) to the tape entry.
  v1 variants: `inbound`, `send_callback` (existing send-callback path
  becomes the first non-inbound activation source — already implicitly
  this, just label it explicitly on the tape).
- Mint `correlation_id` server-side at inbound entry; inherit on
  `__rove_next` (the existing trampoline already threads ctx — same
  threading point).
- Accept `X-Rove-Correlation-Id` inbound header (length/charset
  validation), honor when present.
- Replay shell: add a `correlation_id` column / grouping axis.

Gate: full unit + smoke suite green; `heldsync_smoke` shows the same
`correlation_id` on both the entry and the send-callback resume tape
entries.

### Phase 2 — `__rove_stream` skeleton (timer + disconnect)

The minimum viable primitive. **No kv-write wake yet.**

- New return shape `__rove_stream` in the dispatcher.
- Chain-owned held entity (move the held h2 entity into a chain cell
  on `__rove_stream` return; flush chunks; park).
- Timer wake source (generalize `cont_deadline_ns` to a `timer_wakes`
  sibling collection with absolute fire times; sweep promotes them
  to ready activations).
- Disconnect detection (FIN/RST → wake with `disconnect: true` →
  one final activation, then chain cleanup).
- Per-activation request shape: `request.activation = { kind: 'timer'
  | 'disconnect' | 'inbound', ... }`.
- Per-stream caps (max-lifetime, max-activations, per-tenant
  simultaneous).

Gate: smoke — a customer handler streams `:heartbeat\n\n` every 30s,
the test client receives N heartbeats, then disconnects, the
disconnect activation fires.

### Phase 3 — kv-write wake

The load-bearing addition. After this, real customer SSE works.

- Apply-time hook: scan the just-applied writeset for matches against
  the per-worker wake registry (prefix index keyed by tenant + prefix).
- Wake fire: hand the matched continuation back to its holding worker
  (the worker is identified at park time — it's the worker that owns
  the chain).
- Per-tenant scoping (a tenant's `waitFor` can only match its own
  writes — apply-time enforced).
- Activation shape: `request.activation = { kind: 'kv', key, op }`.
- Cross-node correctness: every node's apply sees the writeset →
  every node fires its local wakes (§9.3 — falls out of apply being
  per-node anyway).

Gate: smoke — multi-node cluster; customer SSE handler subscribed on
node A; client of *the same tenant* writes to the watched prefix on
node B; node A's stream receives a frame; tape on node A records the
kv-write activation with the originating chain's `correlation_id`
recoverable as a cross-chain edge.

### Phase 4 — Drop the 3b-iii read-only-resume restriction

**Subsumes task #9.** With Phases 1–3 in place, the restriction is
genuinely an asymmetry, not a safety property. Lift it:

- Send-callback handlers can return `__rove_next` / `__rove_stream` /
  `Response` like any other activation.
- kv-write / timer / disconnect handlers can do the same.
- Re-issuing `http.send` from a callback (recipe-1 real-retry — the
  task #9 use case) just works.
- The "defined 500 — 3b-iii read-only-resume" branch is deleted.

Gate: `heldsync_smoke`'s recipe-1 boundary test inverts — what was a
defined 500 now succeeds (the resume hop fires another http.send,
chains a wake on its completion, eventually flushes a 200). The full
unit + smoke suite passes.

### Phase 5 — Dissolution: delete `src/sse_server/` + `events.emit` — **DONE 2026-05-19**

The final dissolution (§8 — clean break, no back-compat). Shipped
as a single phase with no JS-shim intermediary.

Shipped:
- `events.emit(...)` removed from the globals JS surface entirely.
  Customer code using it breaks at the deploy boundary
  (pre-release; no migration period).
- `src/sse_server/` deleted (in-process thread, ring cache,
  connection table, JWT verify, h2 listener).
- `--sse-listen` flag + spawn block in `loop46/main.zig` removed.
- `/_session/sse-token` worker route + `src/js/sse_token.zig`
  deleted (no platform SSE pipe to mint tokens for).
- `src/js/bindings/events.zig` (the native binding),
  `src/js/globals/events.js` (the JS shim), `src/js/sse_dispatch.zig`
  (the EmitEntry / Handle types), `src/js/events.zig` (SSE caps
  config) all deleted.
- `events_emit` / `events_connect` / `events_bytes_out` enum
  variants + bucket caps in `src/js/limiter.zig` removed.
- `ParkedUnit.emits` field + `parkEmits` + `firePendingEmits`
  removed from worker.zig + tenant_batch.zig + callback_dispatch.zig
  + worker_dispatch.zig.
- Stale smokes deleted: `sse_server_smoke.py`,
  `notifications_smoke.py`, `notifications_browser_smoke.py`,
  `divergence_faultinj_smoke.py`. Stale fixture deleted:
  `examples/divtest-tenant.json` +
  `examples/loop46-demo-tenants/divtest/`.
- Single-node restriction from task #10 lifted (kv-write wakes
  ride raft → multi-node correctness via §9.3, no rendezvous
  needed; `loop46` no longer rejects multi-node + SSE at startup
  because the multi-node + SSE combination no longer goes through
  loop46 in the first place — it goes through the customer's own
  `__rove_stream` handler).
- `docs/sse-plan.md` → pure historical record with retirement
  banner at the top.
- `docs/PLAN.md` §2.12 / §13 reconciled (§2.12 archival banner;
  §13 process map drops sse-server row; §13.3 JS surface drops
  `events.emit`, adds `__rove_stream`).
- `docs/connection-actor-plan.md` §6.2 / §12.4 reconciled (§12.4
  gains a retirement-supersession banner above the task #10
  collapse archival content; §6.2 now points at this plan as the
  implementation venue rather than at the deleted sse-service).

Gates (all green): `zig build` clean; `zig build test` 0 failures;
the seven streaming-handlers + heldsync smokes (`streaming_smoke`,
`streaming_heartbeat_smoke`, `streaming_kv_wake_smoke`,
`streaming_disconnect_writes_smoke`, `streaming_kv_wake_writes_smoke`,
`streaming_first_hop_writes_smoke`, `heldsync_smoke`) pass; the
~3950-LOC net deletion (~1100 of which is `src/sse_server/`) shows
in the diff; no `sse_server`/`events.emit` references remain in
`src/` (the one residual ref in `loop46/main.zig` is a historical
"what was retired" comment, not active code).

---

## 13. Out of scope (explicitly)

- **WebSocket transport (§6.3 / connection-actor-plan §10.2).** When
  WS transport finally lands, WS-shaped handlers ride this plan's
  primitives. WS *transport* (RFC 6455 / 8441 / Cloudflare-downgrade
  stack) stays the deferred-to-v2 cost PLAN already documents.
- **Durable SSE / `_events/`-style platform replay log (§10.1).**
  Rejected, stays rejected. Customers who want replay write events
  to their own kv (worked example §7 — "initial snapshot from
  `kv.list`").
- **Multi-tenant kv-write subscriptions.** A tenant subscribes only
  to its own kv. Cross-tenant signaling goes through explicit
  `platform.scope(id).kv` (admin) or via http.send between tenants.
- **Filter-function kv-write wakes.** "Wake only when value
  satisfies p" — invoking customer JS at apply time on the raft
  thread is a hazard out of scope here. Customer filters in the
  handler post-wake.
- **Sticky-session SSE routing.** §9.3's free cross-node correctness
  removes the need; the LB picks any node, kv-write wakes find the
  right stream wherever it lives.
- **Per-stream prioritization / QoS.** All streams are equal; fairness
  is dispatcher-tuning, not API.
