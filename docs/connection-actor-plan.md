# Connection-actor — one primitive under SSE, WebSockets, held-synchronous calls, and the firehose

**Status:** **Implemented (Phases 1–3c, 2026-05-18) with locked
refinements — see the Freeze Addendum at the end of this doc.** §1–§11
below are the original *design exploration*; the addendum is the
authoritative record of what shipped and where it deliberately
diverged (the unified trampoline+trigger model superseded the §4
copyable-handle fan-in; the holder collapsed *into* the worker rather
than the §9 standalone sibling; single-tenant + node-local). The
shipped sse-service (`docs/sse-plan.md`, PLAN §13) is unchanged by
this doc. Relationship to the three PLAN-locked decisions this
touches — §7-rejected durable SSE storage, the v2 WebSocket deferral (PLAN
"Why SSE not WebSockets"), and the Cmd-model "external result inline is
impossible" bet — is reconciled explicitly in §10. Nothing here re-proposes
**or reconsiders** a §7 rejection: durable SSE stays rejected as a platform
capability (§10.1) and the Cmd bet is preserved *verbatim internally* (§10.3)
— the only thing that is new is what an external caller observes.

> **Framing principle.** *One external shape is not one internal unit. The
> internal unit is always the replayable request; the external shape is
> whatever the held connection handle projects.* From the outside an
> interaction is "an SSE stream" / "a WebSocket" / "a synchronous call"; on
> the inside it is several replayable requests stitched by a held handle. The
> ordinary handler that returns an immediate response is the degenerate case
> where the chain length is one and the handle is never held past the
> response.

This document specifies the primitive that makes that principle concrete, then
shows SSE, WebSockets, held-synchronous third-party calls, the atproto
firehose, and the normal request/response all as projections of it.

---

## 1. The primitive

A **connection-actor** is a long-lived endpoint identity owned by a
connection-holding subsystem (a sibling of sse-service / files-server /
log-server — §9), driven by a sequence of short, pure handler invocations
called **wakes**. The actor owns a socket; the handler never does. Each wake
is an ordinary replayable request with two extra affordances:

- **An inbound frontier**, snapshotted at wake start and read lazily. The
  handler may consume zero or more pending inbound messages; a *read* is what
  tapes the bytes and advances the per-connection consumed cursor. Messages
  arriving during the handler's execution belong to a later wake — the
  snapshot is frozen for the duration of the pure execution.
- **A handle it can pend writes to**, flushed to the socket only after the
  wake's raft propose applies — exactly like the kv writeset, `http.send`,
  and `events.emit` (sse-plan §3.2). The handle is a serializable id, so a
  *different* future wake (e.g. an `http.send` callback) can pend writes to
  the same connection.

```
                       connection-holder subsystem
                       (owns socket, zero handler state)
   client  ──socket──▶  ┌───────────────────────────────┐
                        │  inbound queue → frontier      │
                        │  pending-write buffer          │
                        │  timers / wake scheduler       │
                        └───────────────┬───────────────┘
                                        │ wake (reason, frozen snapshot)
                                        ▼
                              ┌──────────────────┐
                              │  handler (pure)  │   ← ordinary replayable
                              │  reads frontier  │     request invocation
                              │  pends writes    │
                              └────────┬─────────┘
                                       │ writeset + pended frames
                                       ▼
                               raft propose / apply
                                       │ on commit
                                       ▼
                        holder flushes frames to socket, in order
```

The connection-actor introduces **no new replay machinery**. Inbound is a
taped input (same class as the request body, `Date.now`, a `kv.get` read).
Outbound is a post-commit effect (same class as the writeset / `http.send` /
`events.emit`). A wake is an invocation source (joining HTTP request, schedule
callback, trigger, cron). It is the *existing* determinism discipline applied
to a held socket.

The mental model: **a connection is an actor whose taped event log is a
deterministic sequence of `(wake-reason, input-snapshot) → (writeset,
pended-frames)` tuples.** This is the per-request "fresh context, pure system
between poll() and flush()" model, lifted to span a connection.

---

## 2. Determinism model

| Element | Class | Precedent |
|---|---|---|
| Inbound message read | Taped input | request body, `Date.now`, `kv.get` |
| Wake reason + wall-clock | Taped input | `Date.now`, request metadata |
| Pended write | Post-commit effect | kv writeset, `http.send`, `events.emit` |
| Assigned sequence/seq | Stamped at apply | raft commit order |

Replay reuses the hook PLAN line 690 / sse-plan §8.2 already established for
`?__draft=` and tape step-through: side-effecting bindings switch to
"capture, don't fire". On replay a connection-actor:

- does not hold a real socket;
- replays the taped wake sequence and per-wake frozen snapshots;
- re-runs each handler invocation, producing identical writesets and frames;
- the flush is a no-op (captured for the replay UI, never sent).

The seq a frame gets is stamped by the deterministic apply order of committed
envelopes, **not** read back inside the pure execution — a handler may not
observe its own assigned seq, the current subscriber set, or socket liveness
during a wake. If a use case needs the seq, it returns via a subsequent wake
(the `http.send` `on_result` pattern), never synchronously. This invariant —
nothing connection-stateful leaks into the pure execution — is what preserves
replay; it is the same rule that governs `http.send`.

---

## 3. Wake model

Wakes are **edge-triggered and coalesced**. A burst of 50 inbound messages is
*one* wake whose snapshot contains 50, not 50 wakes. At most one wake is
outstanding per connection; the handler drains what it chooses; leaving
messages unread re-arms the wake. This bounds invocation rate and makes
per-wake batching the natural unit.

Wake reasons:

- **`message`** — ≥1 unconsumed inbound message (level-triggered readiness;
  coalesced).
- **`timeout`** — a deadline the handler armed (reuses the schedule
  machinery; the connection handle is the schedule target instead of an
  `http.fetch` URL).
- **`signal`** — an external nudge (a callback addressed at the handle, a
  durable-topic advance, an operator signal).
- **`open`** — the initial wake (carries the upgrade/connect request).
- **`close`** — terminal wake (peer closed / evicted / deadline with no
  resolution); the handler's last chance to pend a final frame / persist
  state.

The readiness set is **collection membership** ("connections with unconsumed
input / due timers"), drained by the dispatcher — never an O(N-connections)
per-tick scan. This is the rove ECS "state is collection membership" rule and
the no-O(N)-on-the-hot-path constraint; it is mandatory, not an optimization.

---

## 4. Ordering — chain vs fan-in

Ordering is a property of how the handle is shared, not a separate config:

- **Affine / move handle ⇒ serialized chain.** Exactly one holder; the handle
  is *moved* on handoff. Single-writer-at-a-time holds by construction →
  total order for free, no sequencer. A single connection driven by a
  sequential wake chain *is* this case: its outbound is serialized because
  the chain is the happens-before relation.
- **Shared / copyable handle ⇒ fan-in.** Many wakes from many sources append
  to the same connection id. No global order; replay needs only each handler
  individually deterministic.
- **Fan-in *and* totally ordered** needs an external sequencer (apply order).
  This is the firehose; §6.5 shows it decomposes into the two cases above.

The primitive **guarantees** per-connection, per-wake-chain in-commit-order
flush (the chain case, free). Cross-source fan-in ordering to one socket is
the handler's problem (or the sequencer's, §6.5). The primitive does not, and
should not, solve fan-in ordering implicitly.

---

## 5. Connection bookkeeping & failover — the part you cannot punt

The primitive is deliberately neutral on *application* durability and
ordering: "durable" means the handler persisted it (kv / a durable topic);
"ephemeral" means it did not. That neutrality is the point and it is what
keeps this from re-proposing durable SSE (§10.1).

But the **consumed frontier, the pending-write buffer, and the armed timers
are primitive-level state**, and their failover contract must be *stated*, not
left undefined:

> **Failover contract (v1):** the connection-holder is single-process per
> cluster (mirroring sse-plan §4.6 / PLAN §13). On holder restart the socket
> dies; the client reconnects (WS/SSE) or retries (one-shot HTTP); in-flight
> inbound, the consumed frontier, pending unflushed frames, and timers are
> lost. The handler rebuilds from whatever **it** chose to persist. Durable
> application state is composed by the handler; connection bookkeeping is
> best-effort by design.

This is the same bet sse-plan made and PLAN §7 ratified for SSE: held
connection state is best-effort; durability is the customer's composition.
The connection-actor changes none of that — it only generalizes the surface
it applies to.

---

## 6. Projections

### 6.1 Immediate response (degenerate case)

Chain length one; the handle is never held past the wake. `open` wake carries
the request; handler pends the response as its writeset's post-commit flush;
connection closes. This is today's ordinary handler — it is a connection-actor
with the held duration collapsed to zero. Stating it this way is not a rewrite
of the request path; it is the observation that the request path is the
primitive's base case, which is why the primitive composes rather than bolts
on.

### 6.2 SSE (unidirectional, ephemeral projection)

> **Update (2026-05-19, streaming-handlers Phase 5).** §6.2 is now
> **implemented** — the platform-managed sse-service has been
> dissolved (§12.4 retirement notice) and replaced by
> customer-arbitrary SSE on `__rove_stream` + the §4.6 kv-write
> wake. The §6.2 projection contract (empty inbound frontier,
> ephemeral durability, reconnect→refetch) carries forward
> verbatim — only the implementation venue moved, from a platform
> bus to a customer-JS layer over `__rove_stream`. See
> `docs/streaming-handlers-plan.md` §7 for the worked example and
> §8 for the dissolution.

A connection-actor with an empty inbound frontier (server→client only) and
ephemeral application durability (handler persists nothing; reconnect → the
client refetches authoritative state). **This is exactly the shipped
sse-service contract** (sse-plan, PLAN §2.12). This doc does **not** migrate
SSE onto the primitive and does **not** reopen the §7-rejected durable
`_events/` store (§10.1). **Durable SSE remains rejected.** The primitive
provides *no* SSE durability; the only durability available is what a handler
composes by persisting to durable storage it already controls (kv / a durable
topic) — and a handler choosing to do that is not the platform providing
durable SSE, exactly as a handler writing an audit row is not the platform
providing an audit log. The §7 rejection is of a *platform* `_events/` store +
retention sweep + raft replication; it has never forbidden customers from
persisting their own stream if they want one. The relationship is conceptual: SSE *is* the
ephemeral-unidirectional projection; whether sse-service is ever re-expressed
on a shared connection-holder is an explicitly deferred, separate question
(§11). sse-service as built stays as built.

### 6.3 WebSocket (full bidirectional actor)

The complete primitive: inbound frontier + pended frames + wakes. Chat,
presence, collaborative editing. Large binary frames take the §8
content-addressed path. **See [`docs/websocket-plan.md`](websocket-plan.md)
for transport choices + sequencing.** The connection-actor projection
specified here is the execution/determinism model WS rides when
transport lands; the v2 transport-stack cost (RFC 6455 / RFC 8441 /
Cloudflare-downgrade / parallel-HTTP/1.1) lives in that plan.

### 6.4 Held-synchronous third-party call (parked one-shot HTTP)

The `open` wake validates and fires `http.send(third_party,
on_result: moduleB)` but does **not** complete the HTTP response — it pends
nothing and the handle stays held. The callback is a later wake (`signal`)
whose handler computes the response and pends it to the held handle. From the
caller: one synchronous request. Internally: two replayable requests bridged
by the handle. **Internally, getting the API result inline stays impossible —
exactly as PLAN line 79 states, with zero erosion.** The projection changes
only what the *caller* observes; it is an external mask over an internal
reality that is unchanged. This closes the loop on the conversation's original
objection (an ActivityPub inbox needs a key-fetch to make a decision
mid-request) — the pure model can now *present as* caller-synchronous while
staying internally-async, with **no blocking primitive introduced**.

Load-bearing constraints (not optional — this projection silently
reintroduces the synchronous-proxy resource model the architecture spent
effort eliminating):

- **Dedicated holder, hard cap.** Runs in the connection-holder subsystem,
  never the worker; a hard parked-connection cap + the sse-plan §4.3
  strike/eviction posture. Ease of use is the footgun.
- **Bounded deadline < minimum intermediary timeout.** A parked one-shot
  request is on a wall clock you do not control (browser / LB / CDN, often
  <60s). A mandatory `timeout` wake must produce a real 504-class response
  before any intermediary gives up. "Hold until the callback" is incomplete
  without "…or the deadline, whichever first".
- **Resolve-once.** `webhook.send` is at-least-once (see
  `effect-reification-plan.md` Phase 5); callbacks can double-deliver
  and leadership change can re-fire. First resolution wins; the rest
  are dropped because the connection is already completed — hooked
  into the existing version-counter defense, not a parallel invention.
- **The synchrony is cosmetic.** Failover/at-least-once/ambiguity caveats of
  the underlying Cmd remain, now surfaced to an HTTP client that may not
  expect them. Safe only for retry/idempotency-aware callers or idempotent
  targets.
- **Not the default.** Where a protocol sanctions async-accept (ActivityPub
  inbox: 202-accept-then-process), that is *more* robust — it decouples you
  from the *remote's* connection timeout, which you do not control.
  Held-synchrony is for endpoints whose external contract is *genuinely*
  synchronous (OAuth token exchange, payment authorization, a partner's
  synchronous verification API).

### 6.5 atproto firehose (durable, ordered, fan-in projection)

`com.atproto.sync.subscribeRepos`: server→client, binary, sequenced,
cursor-resumable. Decomposes via §4:

- Each repo's commit history is **already a chain** — `prev`/`rev` is the
  affine-handle handoff; ordered by construction, no sequencer.
- The per-PDS firehose is a **fan-in merge** of per-repo chains into one
  monotonic `seq`. Consumers require only *a* stable resumable total order
  (repos are independent — no cross-repo causal constraint), so the merge
  stamps `seq` by deterministic apply order. That is the *only* place a
  sequencer is paid.

Durability is composed by the handler over a **dedicated segmented append log,
not raft envelopes** — the `log_batch`-retired / S3-direct precedent
(`docs/logs-plan.md`, PLAN §10.2) is binding here: a firehose that doubled
every commit into the main raft log repeats exactly the mistake that history
records. The retention window gives atproto's `OutdatedCursor` semantics for
free — the backing is a bounded ring over the log, not an unbounded archive.

---

## 7. Backpressure (bidirectional)

Outbound reuses sse-plan §4.3 unchanged: skip-with-strikes, close after
5 strikes / 30s, client reconnects. Inbound is the new dimension: a client
flooding faster than handlers drain must hit a bounded unconsumed-buffer cap
(drop/close, same philosophy). "Snapshot at wake start" does not bound the
buffer; the cap does.

---

## 8. Large frames / payload

Small control frames tape inline. Large frames (binary WS, multi-MB) take the
**content-addressed path**: the frame is stored content-addressed, the tape
records the handle/hash, the bytes live out-of-band, and the handler reads
them via a VM-bypassing path. This is the blob-sink treatment, and it is
mandatory: taping large frame bytes into the connection tape reproduces the
REQUEST_BODY_CAP truncation failure (worker.zig) → silently broken replay past
the cap. Egress of large frames is likewise a VM-bypass stream from the
content-addressed store (PLAN line 1035 "streaming response bodies" is the
related deferred item).

---

## 9. Subsystem placement

The connection-holder is a new subsystem mirroring the
`src/sse_server/` / `src/files_server/` / `src/log_server/` shape: own
listener, own connection table, zero handler-side connection state — the
sse-plan isolation discipline preserved verbatim. The worker pends
writes/reads handles; it never owns a socket. Placement in the PLAN §13
surface map, and whether it shares a process with sse-service or stays
distinct, is a deferred decision (§11) — v1 assumes a distinct sibling
subsystem and the sse-plan §4.6 single-process failover model.

---

## 10. Reconciliation with locked PLAN decisions

### 10.1 Durable SSE storage (§7-rejected) — not re-proposed

PLAN line 700 / §7 rejected the `_events/{sid}/{seq}` raft-replicated SSE
store. The connection-actor is durability-**neutral**: SSE rides it as the
ephemeral projection (§6.2) with the handler persisting nothing — which *is*
the post-rejection model. Nothing here restores `_events/`, the retention
sweep, or raft-replicated SSE state. The durable *topic* (firehose, §6.5) is a
**different consumer contract** — a server-to-server log with no authoritative
app.db to refetch from — not "SSE made durable". The §7 rejection's own thesis
(notification ≠ state store; refetch beats replay) is the argument for keeping
them separate primitives, which this doc does.

### 10.2 WebSockets (deferred-to-v2) — see websocket-plan.md

PLAN "Why SSE not WebSockets" defers WS on a transport-stack rationale;
the consolidated WS plan now lives at
[`docs/websocket-plan.md`](websocket-plan.md) (transport choices for
both directions + sequencing + use cases). The connection-actor is the
*execution and determinism model*, not a transport — it delivers value
*now* through projections that need no WS transport at all (SSE, the
held-synchronous calls of §6.4, the firehose backing of §6.5 modulo
WS framing). When WS transport ships, it rides this primitive
unchanged.

### 10.3 "External result inline is impossible" (Cmd bet) — preserved verbatim internally

PLAN line 79 records the locked bet that "call an external API and use the
result inline" is impossible, so customers rewrite as fire → accept →
callback → poll/SSE, and explicitly frames this as a *calculated cost*. **This
doc does not reconsider that bet, because internally nothing changes.**
Internally, getting the result inline stays exactly as impossible as line 79
states — no blocking primitive, the handler stays pure, the Cmd model and all
its at-least-once/ambiguity caveats are intact and unmodified. The
held-synchronous projection (§6.4) adds *only* an external mask: from the
caller it looks synchronous; on the inside it is the unchanged, still-impossible
two-request Cmd. So the bet is neither reversed nor narrowed — its internal
reality is preserved verbatim, and what is new is purely the caller's view,
which the §2 bet never made promises about. (Consequently true-async stays
preferred wherever the protocol is async-tolerant — §6.4 "not the default" —
since internally that is all there ever is.)

### 10.4 What this is NOT

- Not a blocking primitive. Handlers never block; recv-loop handlers stay
  forbidden. A connection is wake-driven, not loop-driven.
- Not durable SSE (§10.1). Not a cheaper WebSocket transport (§10.2).
- Not implicit fan-in ordering — the primitive guarantees only the
  per-connection chain (§4).
- Not a way to put large payloads through raft or the tape (§8).

---

## 11. Open questions / deferred

- **sse-service convergence.** ~~Whether the shipped sse-service is ever
  re-expressed on a shared connection-holder, or the two subsystems coexist
  permanently. v1: coexist; sse-service untouched.~~ **RESOLVED 2026-05-19
  by collapse, not stacking (task #10)** — sse-service is now a loop46
  in-process thread, single-node v1, cross-node dropped. See §12.4.
- **PLAN §13 / §7 wiring.** This doc should get a PLAN §13 surface-map entry
  and a §7/§4 cross-reference once the primitive is accepted — not done here
  (a judgment-heavy PLAN edit, flagged for follow-up).
- **Holder process model.** Single-process (sse-plan §4.6) vs the multiraft /
  multi-process horizon; deferred with the rest of that horizon.
- **Affine-handle enforcement.** Whether the move/affine discipline (§4) is
  enforced by the runtime (capability that invalidates on handoff) or is a
  documented convention. The firehose decomposition (§6.5) works either way;
  the held-synchronous case (§6.4) wants resolve-once enforced regardless.
- **Wake fairness.** Scheduling policy when many connections are
  simultaneously ready (per-connection fairness vs throughput) — a
  dispatcher-tuning question, not a model question.

---

## 12. Freeze Addendum (2026-05-18) — what shipped, and the locked deltas

§1–§11 are the design exploration. This section is authoritative for
the implemented primitive (Phases 1, 2a, 2b, 3a, 3b-i/ii/iii, 3c).

### 12.1 What shipped

The §6.1 degenerate case and the §6.4 held-synchronous third-party
call. A handler returns `__rove_next(path, {fn?, ctx?})` instead of a
response value → its h2 **stream entity** moves `request_out →
worker.parked_continuations` (held; no response stamped). A hop that
fired exactly one `http.send` is bound to that schedule (Part A
stamps the schedule's `on_result` = the continuation so `apply.zig`
emits the `c/` callback row); on completion `dispatchCallbacks`
partitions the bound row out *before* the per-tenant batch txn opens
and the resume engine re-enters dispatch with `{ctx, outcome}`,
flushing the terminal return to the still-open socket — one
synchronous request from the caller. The §6.4 mandatory timeout is a
deadline sweep that resumes the hop with a `{ok:false,
reason:"deadline"}` outcome so the **handler authors** the timeout
response. Resolve-once falls out of `reg.move` happening once.
End-to-end validated by `scripts/heldsync_smoke.py` (happy / failure
/ effectful-resume-boundary); in-situ non-regression by
`scripts/conn_actor_bench.py` (8w sharded ≈187k vs the ~158k
baseline) and the `ROVE_BENCH` microbench (per-request tax ≈61 ns).

### 12.2 Locked deltas from §1–§11 (these supersede the design above)

- **No exposed handle, anywhere (supersedes §1's "serializable id"
  and §4's copyable-handle fan-in).** The unified model is the
  *return-as-continuation trampoline* + a coalesced multi-source
  trigger; fan-in lives on the trigger and the state store, never on
  the connection writer (always single-owner/affine). Consequently
  security layers 1 (unguessable handle) and 5 (no foreign-id JS
  surface) are **mooted by construction** — there is no customer-
  visible connection reference to attack. The §4 "shared/copyable
  handle ⇒ fan-in + external sequencer" branch is dissolved.
- **The holder collapsed INTO the worker (supersedes §9's standalone
  sibling).** There is **no new process** — no `connection-holder-
  standalone`, no `/v1/_internal/*` route, no internal bearer for it.
  The parked connection *is* the worker's own h2 stream entity sitting
  in the `parked_continuations` sibling collection; "park" is a
  `reg.move`. (The Phase-1/2 standalone `src/connection_holder/` was
  the experimental scaffold; the shipped path is worker-internal.)
- **Single-tenant + node-local.** Everything that can touch a
  connection-actor belongs to its tenant; the actor + its triggers
  are node-local (the socket is node-local by physics anyway). Push
  projections delegate cross-node fan-out to the existing sse-service
  bus rather than reinventing it (resolves §11 "sse-service
  convergence": they *stack*, not merge).
- **Affine enforcement = by construction** (resolves the §11 open
  question): you can't copy a continuation you returned, so the
  move/affine discipline is structural, not a convention.
- **`http.send` stays at-least-once *here*.** As originally written,
  §6.4 rode the envelope-8/9 schedule machinery. That re-platform
  (task #8, the **Option (b)** N-way migration) **shipped 2026-05-19**:
  §6.4 now binds the parked continuation to the send's
  `_send/owed/{id}` marker (envelope-0); the leader-local per-node
  `SendDispatch` fires it; `dispatchSendCompletions`' Part-B peel
  resumes the continuation by matching `bound_schedule_id == send_id`
  (a resume-search, not a routed handle). The at-least-once guarantee
  is unchanged; only the machinery moved. Cross-worker §6.4 (callback
  on the leader, continuation on another worker) requeues until the
  owning worker resolves it; single-worker is the unit-tested
  functional scope.
- **Read-only resume hops only (3b-iii scope).** A resume hop that
  writes kv, or re-issues `http.send` (recipe-1 real retry / re-park),
  is an *effectful resume hop* — explicitly deferred (task #9); it
  yields a defined 5xx, never silent corruption (the freeze caught +
  fixed a false-200-on-thrown-hop bug). The §6.4 core value (held
  3rd-party call → handler-authored response; failure-outcome →
  handler error) is fully shipped without it.
- **§6.2 SSE / §6.3 WS / §6.5 firehose** are *not* shipped here — the
  trampoline+trigger model covers them (per §6/the unified design)
  but only §6.1/§6.4 are implemented. WS transport remains the
  PLAN-documented v2 cost (§10.2, unchanged).

### 12.3 §7 / locked-decision reconciliation (unchanged stance)

No §7 rejection is reopened. Durable SSE stays rejected (§10.1); the
Cmd "external result inline is impossible" bet is preserved verbatim
internally (§10.3) — §6.4 is purely an external mask over the
unchanged two-request Cmd. The unified trigger model *strengthens*
the §7/§10.1 "notify, don't store; refetch, don't replay" thesis by
making it the universal mechanism. PLAN §13 surface-map note added
(the connection-actor adds no process). Memory of record:
`project_connection_actor_unified_trigger`,
`project_callback_execution_model`, `project_connection_holder_security`.

### 12.4 SSE dissolved entirely (2026-05-19) — supersedes 12.4-prior-revision

**Status update.** The task #10 collapse described in this section
(in-process SSE thread, single-node only) is **itself retired** by
streaming-handlers Phase 5 (also 2026-05-19, same day, second
move). The platform-managed SSE pipe no longer exists — no
`events.emit`, no `_session/sse-token`, no `--sse-listen`, no
`Handle.enqueueEmit`, no `src/sse_server/`. The streaming-handlers
§7 worked example shows what replaces it: customers write their
own SSE endpoint, emit events by writing to their own kv under a
watched prefix, and the §4.6 kv-write wake fires the wake-driven
handler to render frames. Cross-node correctness rides raft (every
node's apply sees the writeset → fires its locally-held streams).
The single-node restriction this section imposed is lifted with
the dissolution.

The §6.2 projection contract (notification ≠ state store;
ephemeral; reconnect → state-refetch) carries forward unchanged
into streaming-handlers-plan §10.3. Everything below this notice
is the pre-dissolution design-of-record; the supersession is
authoritative.

#### 12.4 pre-dissolution (archival) — SSE collapsed in-process (2026-05-19)

**§12.2's "Push projections delegate cross-node fan-out to the
existing sse-service bus … they *stack*, not merge" lock is
consciously reversed by task #10 (Phases 1–5, 2026-05-19).** The
new lock:

- **sse-service is no longer a separate process.** `loop46` now
  hosts the SSE thread (`src/sse_server/`, `Handle.spawn`, sibling
  to the raft thread, gated on `--sse-listen`). The
  `sse-server-standalone` binary is deleted; so is the
  worker→sse-server HTTP `POST /v1/emit` route, the
  `SSE_INTERNAL_TOKEN` shared bearer, the `sse_dispatch.fireBatch`
  curl POST, and the `--sse-public-base` operator wiring.

- **Worker→SSE handoff is in-process.** `events.emit` batches reach
  the SSE thread via `Handle.enqueueEmit` (an MPSC queue — workers
  produce, the SSE thread drains each poll tick, deep-copies once,
  applies via the shared `applyEmitBatch` core). No HTTP, no
  internal bearer, no curl handle. `parkEmits`/commit-gating is
  unchanged: emits still fire post-commit, just via the queue.

- **Cross-node fan-out is dropped.** **Single-node only for v1.**
  The single-node guard (`--peers > 1` + `--sse-listen` → hard
  fail-fast at startup) makes the model strictly correct rather
  than knowingly-lossy: with one node the EventSource and any
  emitting worker both live in the same process, so an in-process
  queue is the entire delivery path. Multi-node SSE is explicitly
  out of scope — a later phase, not yet scoped.

- **§6.2 "ephemeral, no durability" stays.** Nothing here restores
  `_events/` storage; the §7/§10.1 durable-SSE rejection is
  untouched. The collapse is purely about *who runs the bus*, not
  *what it remembers*. SSE remains best-effort; `enqueueEmit` drops
  on OOM and the reconnect → state-refetch model covers loss.

- **`/_session/sse-token` mint is unchanged.** Worker-served,
  stateless, reads `_rove_sess` cookie, mints the EventSource JWT
  the SSE thread verifies on connect. The token's
  `notifications_url` is derived from `--public-suffix` as
  `https://sse.{public_suffix}`, gated on `--sse-listen`.

- **The collapse mirrors §12.2's own precedent.** §12.2 collapsed
  the §9 "standalone connection-holder sibling" INTO the worker
  ("no new process"). This is the same move for SSE — same
  rationale (the standalone added nothing the in-process thread
  doesn't cover, and the cross-process boundary was paying
  coordination overhead for capability we don't actually need
  yet).

What this is NOT: durable SSE (§10.1, still rejected). A v2
multi-node SSE story (deferred). A blocking primitive. A change to
the §6.2 *projection* itself — only its *implementation venue*.

§6.2 and §11's "sse-service convergence" deferral above should be
read with this in mind: **task #10 resolved the convergence by
collapse, not by stacking**, with the cross-node capability
explicitly dropped. The two earlier framings ("stay separate" /
"v1: coexist") are the pre-collapse design record; this section is
authoritative for current behavior.
