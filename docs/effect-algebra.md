# The effect algebra

> **Status**: principles — the effect model every shipped or proposed
> effect must fit. Distilled 2026-05-22 from a full effect-system audit;
> the audit tables and worklist that used to live here (old §5–§7) are
> retired — every finding shipped (`decisions.md` §3.2/§3.3 record the
> outcomes; the tables live in git history). This is the cross-cutting
> frame that the as-built `architecture/effects-and-handlers.md` +
> `architecture/routing-and-ingress.md` are each a facet of — see §7. It
> is the ground truth for the question "does this new effect fit the
> model?"
>
> The customer-facing handler surface (named exports per Msg kind, the
> `stream.*` / `on.*` effects, the `next()` disposition) is specified in
> [`handler-shape.md`](handler-shape.md); this doc uses the customer
> spellings except where it names an engine internal explicitly.

## 1. The model in one paragraph

A customer handler is a pure function — The Elm Architecture (TEA):

```
update : (Msg, Ctx) -> (Writeset, Cmd Msg)
```

Inside an activation the code is imperative, but deterministic — arenajs
captures every non-deterministic read. arenajs makes one activation
replayable. *This doc is about everything between activations.* The
Cmd/Msg boundary is not Elm aesthetics: it is the determinism boundary,
and determinism is non-negotiable because of replay (the tape, the
simulator). The exact invariant:

> An effect may return data to a handler **only as a recorded Msg.**

Everything below either obeys that or is consciously outside the handler.

## 2. The four primitives

The whole engine, minus the handlers, is four primitives — **two
singletons and two open families.** Every named effect is a composition
of them (§3). Each primitive has exactly one law.

### 2.1 The Model — singleton

KV. The only effect that is *bidirectional* — a handler both reads it
and writes it. That read-write duality is the entire reason KV needs the
kvexp overlay: concurrent activations that read-then-write shared state
need snapshot isolation (the read view) and conflict ordering (the
per-tenant write chain). An output-only effect never needs that — you
cannot conflict on something you only append to.

> **L1 — Durability has exactly one home.** Every durable fact is a key
> in the Model. There is no second durable store.

Proven, not aspirational: `schedules.db` and envelope types 8/9/10/11
were retired (2026-05-19, `http.send` Option-(b)) precisely because a
second durable store was always redundant. A send's durable intent is
now `_send/owed/{id}` keys in the tenant's own `app.db`, riding the
ordinary envelope-0 writeset. Two replicated stores remain — `app.db`
(per-tenant) and `__root__.db` (root) — and they are the same primitive
at two scopes, not two primitives.

### 2.2 The Continuation — singleton

A parked handler activation that correlates an emitted Cmd to the future
Msg that answers it. Mechanically: park an entity → subscribe it to a
wake source → resume it when the Msg arrives. `webhook.send`'s result
callback, `on.fetch`'s chunks, a held stream's wakes, a held
connection's frames — all the same structure.

> **L2 — A Continuation is always ephemeral.** It must be reconstructible
> from the Model, or safe to abandon — and it is safe to abandon iff no
> externally-observable effect has escaped.

`webhook.send` is the only Continuation that *reconstructs* (the sweep
of `_send/owed/` re-arms it) — because it is bound to a durable Cmd that
promised delivery. Every other Continuation *abandons* on loss: a
dropped stream/fetch/connection becomes a failed request, and that is
correct because nothing was promised. The reconstruct-vs-abandon choice
is determined entirely by whether the bound Cmd is durable. §6.1 names
the root of that distinction.

### 2.3 Msg origins — open family

Everything that produces a Msg into a handler: inbound HTTP, cron, boot,
kv-react, send-callback, fetch-chunk, inbound connection frame, inbound
body chunk. New origins are expected — this family is where the algebra
is *allowed* to grow.

> **L3 — Every Msg is a recorded (taped) input.** No information may
> enter a handler except through a recorded Msg or a Model snapshot read.

This is the engine-side half of determinism. arenajs handles
within-activation; L3 handles between. Tape volume is bounded by per-tenant
retention, not a per-chain cap (`tape-minimization.md` §1) — recorded, not
recorded *forever*.

The inbound request surface satisfies L3 by **read-recording** (the
`request_reads` tape channel; `decisions.md` §4): header names are
recorded unconditionally per activation, while header values, the
cookie header, the body, and the ip surfaces are recorded on first
access — the tape holds exactly the subset of the Msg the handler
observed. A body the handler never read carries no log-side reference
at all (`Readset.elideUnreadBody`); its durability gating is
unchanged. On replay, an unrecorded read is a loud divergence error.

The newest member of this family is the **durable scheduled wake**
(shipped in full; `decisions.md` §3.7 + `architecture/effects-and-handlers.md`
"Durable scheduled wake"): a one-shot, absolute-time,
at-least-once `durable_wake` Msg whose fire-time is itself a Model key.
It generalizes the one place L2 reconstruction was hardcoded —
the webhook sweep of `_send/owed/` (§2.2) — into a primitive, so
`webhook.send`, durable cron, and delayed jobs become §3 compositions
over it rather than features leaning on a webhook-specific sweep.

### 2.4 Cmd runtimes — open family

Everything that carries out a Cmd: kv-write, http-out, stream-write
(`Cmd.stream_chunk` — also the WS frame path), response-write. Also an
open family.

> **L4 — Every Cmd is a recorded output, and is commit-gated** — released
> only after the Model write of the same activation has committed
> (`committedSeq() >= seq`).

L4 is the commit-gate invariant: no externally-observable effect may be
released until `committedSeq() >= seq`. A Cmd is durable only by
*being, or writing, a Model key* — there is no other route to durability
(corollary of L1). kv-write is the degenerate Cmd runtime whose target
*is* the Model.

### 2.5 Corollary — inputs are durable, outputs are derivable

L1–L4 plus the determinism property of handler activations (each is a
pure function of its `(Msg, Model snapshot, bytecode)`) imply a stronger
storage discipline than any single law states. *Inputs* must be recorded
durably — L3 covers the Msg, the readset captures the Model snapshot
(`architecture/effects-and-handlers.md` §4), the `.module` channel pins the
bytecode by hash. *Outputs the handler synthesized* (writeset,
handler-generated Cmd-runtime bytes, wire-shipped bytes) are then a
deterministic function of those inputs and therefore need not carry
independent durability — they are derivable on demand.

The distinction matters because *bytes the handler observed from
outside the system* (request bodies, fetch response bodies) are
**inputs**, not outputs — they came from elsewhere, the handler did
not synthesize them, and re-execution cannot reconstruct them. They
must be durable in their own right. BlobStore consequently plays two
roles depending on what's stored:

| Substrate / role | What lives there | Loss semantics |
|---|---|---|
| Raft (env-0) — durable inputs | Tape Msg (inline) + readset structural metadata + BodyRef pointers to large input bytes; also cached writesets | Permanent loss = system invariant broken |
| BlobStore — **input-bytes home** | Request bodies, fetch response bodies, inbound chunks (referenced from readset BodyRefs at `{tenant}/readset-blobs/{batch_id}`) | Permanent loss = lost input; **unrecoverable** — these bytes came from outside, can't be re-derived |
| BlobStore — **output-bytes cache** | Handler-synthesized bytes (e.g. content-addressed `blob.put` payloads at `{tenant}/blobs/{hash}`) | Transient loss = re-derivable by re-executing the source activation against its readset |
| Wire | Bytes shipped to a client (`response.write`) | Ephemeral — not retained anywhere |

The two BlobStore roles share a backend and addressing but have
opposite recovery stories. **Input bytes** have no other home — they
entered the system from outside and the BlobStore copy is the only
record. They must be durable *before* any handler observes them
(`architecture/effects-and-handlers.md` §5 callback-gating is exactly this
gate). **Output bytes** (a `blob.put` payload) are a pure function of
inputs — recovery re-executes the source activation against the
recorded readset, finds the matching `blob.put` call, re-issues the
PUT (idempotent via content-addressing). They may be **transiently
unavailable** between commit and recovery without breaking any
invariant.

The writeset rides in the raft entry alongside the readset, but only as
an *optimization* — followers apply it directly rather than re-execute
QuickJS. If lost, it's reconstructible by replay. Same shape: cached
output, source-of-truth elsewhere.

This is what makes §5's durability rule ("durability stays in one home —
and that home is JS") actually work for arbitrary-sized handler
payloads: a JS shim's durability marker need not contain the bytes being
made durable, only a pointer to the activation that can re-derive them.
For input bytes the marker pattern doesn't apply at all — they're routed
through the body-buffer-then-blob mechanism, durable by construction at
the point a handler can observe them.

## 3. Every effect is a composition

No effect is primitive. Each is `Msg-origin(s) ⊕ Cmd-runtime(s) ⊕
Continuation? ⊕ Model?`:

| Effect | Msg origin | Cmd runtime(s) | Continuation | Note |
|---|---|---|---|---|
| KV read | — | — (Model query) | no | synchronous snapshot read, not a Cmd |
| KV write | — | kv-write | no | the Cmd runtime whose target is the Model |
| `on.fetch` — whole result | fetch result (`onFetchResult`) | http-out | yes | the single outbound primitive, connection-scoped spelling |
| `on.fetch` — streamed | fetch chunk (`onFetchChunk` / `onFetchDone`) | http-out | yes | streaming response — chunks fire activations |
| `webhook.send` / `email.send` (JS shims) | the shim's result activation | kv-write ⊕ http-out | yes | durable-intent is a *composition* — kv marker + outbound HTTP + retry-cron + boot-subscription, none of them new primitives |
| `blob.put` (JS shim) | result activation (from the PUT) | kv-write ⊕ http-out | yes | content-addressed marker `_blob/owed/{hash}` (pointer to source activation, NOT the bytes) + idempotent PUT against the signed internal origin; recovery re-executes the source activation to re-derive bytes — §2.5 |
| `blob.get` (JS shim) | result (or chunks if streamed) | http-out | yes | a fetch against the signed internal origin; no marker, no durability — failed read = client retries |
| subscriptions (cron/boot/kv-react) | cron / boot / kv-react | — | no | Msg origin alone; boot composes a kv-write marker for idempotency |
| streaming response (`stream.*` + `on.*`) | wake (`onWake`) / disconnect | stream-write | yes | the Continuation *is* the held stream |
| connection-actor (WebSocket) | inbound frame (`onMessage`) | stream-write (→ WS frame) | yes | duplex: a Msg origin and a Cmd runtime on one Continuation |

Compositions worth calling out because they *carry* the principles
rather than merely obeying them:

- **A composition with no Msg origin is structurally untaped — a
  theorem, not a carve-out.** The tape records Msg origins (L3); a pure
  Cmd ⊕ Cmd pipe gives it nothing to record. The retired `pipe_to`
  disposition was the canonical instance; any future bytes-never-enter-
  a-handler pipe inherits the property by derivation, and must be
  justified the same way (the bytes are derivable or deliberately
  unobserved).
- **Outbound HTTP is one runtime, not two named effects.** Earlier
  drafts split it as `http.send` (durable) vs `http.fetch` (transient).
  The reification deleted the split (2026-05-24, decisions.md §3.3):
  there is one outbound HTTP Cmd (`_system.http.fetch`, the curl_multi
  engine) parameterized by response-disposition; durability is *not* a
  parameter and not a verb-level choice. The customer spellings are
  `on.fetch` (connection) and `webhook.send` (durable connectionless) —
  decisions.md §4.2.
- **`webhook.send` / `email.send` are JS shims, not Zig primitives.**
  They compose `kv.set("_send/owed/{id}", ...)` (rides envelope-0
  atomic with the handler's writes) + the outbound HTTP primitive + a
  durable scheduled wake (the `scheduler` lib; re-arm = `scheduler.at`
  with the same key). The original "durable-intent" framing (a
  baked-in Zig primitive) was a premature optimization: every piece
  composes from primitives that exist. The composition is **visible
  JavaScript in the standard library** — the platform dogfoods its own
  primitives, and customers can read / fork the retry policy. A
  paid-tier fast path (pattern-match the shim, dispatch native) is a
  post-launch optimization that does not change the customer-facing
  API. (decisions.md §3.3.)
- **`blob.*` proved the pattern holds under demand.** The blob surface
  was first specced, then deferred for lack of a concrete use case, and
  shipped 2026-06-10 (P1–P4; `decisions.md` §3.8 +
  `architecture/routing-and-ingress.md`) as exactly this
  composition class: JS shims over the one fetch primitive against a
  signed internal origin, with the §2.5 input/output asymmetry as the
  recovery model. The deferral and its exit condition are the
  compose-from-primitives discipline working as intended.

## 4. The contract — six questions every effect answers

Any effect, shipped or proposed, must answer these six identically.
Where two effects answer differently, the algebra is incoherent there.

1. **Cmd shape** — what the handler emits to invoke it.
2. **Msg shape** — what re-enters a handler, as what Msg; or "outside
   the handler" (the no-Msg-origin case, §3 — and *only* that case).
3. **Durability class** — ephemeral / replicated-mutation /
   durable-intent (= a Cmd composed with a Model marker write).
4. **Replay** — how the result becomes a recorded Msg (L3). Or why it
   needs none (no Msg origin).
5. **Backpressure** — bounded buffers, lossy or blocking, when effect
   and handler run at different speeds.
6. **Failure** — delivery semantics (at-most / at-least / exactly-once)
   and what a node crash does to in-flight instances.

**The two-places rule.** Every piece of an effect's in-flight state
lives in exactly one of: (a) a rove ECS collection — ephemeral, and
therefore provably safe to lose; or (b) a replicated store — durable. No
side tables, no plain hashmaps standing in for state, no ephemeral
globals. An effect that needs a third option is the substrate needing to
grow — a real architectural event, not a feature.

## 5. The minimal set

The 2026-05-22 audit scored every effect against §4 and found seven
incoherences with one root cause: **the four primitives were not
factored out.** Each effect hand-rolled its own slice of Continuation,
of taping, of backpressure — and the hand-rolled copies drifted. The
reification (`decisions.md` §3.2) factored them; the audit's findings
all closed.

The shape of the minimal set: **two singletons that must never be
duplicated (the Model, the Continuation), and two open families whose
every member must plug into those singletons** (gate on the
Continuation, tape via the Msg-origin / Cmd-runtime contract). The
families may grow forever; the singletons may not fork. A proposed
effect that cannot be expressed this way is the signal that the
substrate itself must change — rare, and worth stopping for.

And the standing **durability rule** (decisions.md §3.3): a
durable-intent effect is *always* the JS composition
`kv.set("_<verb>/owed/{key}", ...)` (rides envelope-0 atomic with the
handler's writes) + outbound HTTP + a durable scheduled wake under an
idempotency key (fire / retry re-arm / crash-recovery watchdog — the
generic L2 reconstruction, durable-wake P5). No new store, no new
envelope type, no new Zig primitive, no per-feature sweep.

## 6. Trigger scope — connection vs tenant

Deepens L2 (§2.2): it names *why* a Continuation
reconstructs-or-abandons, and the two orthogonal axes that classify
every trigger feeding a Continuation. The customer surface this implies
is specified in [`handler-shape.md`](handler-shape.md); here it is the
model justification for that surface's shape.

### 6.1 A Continuation's durability is forced by its scope

§2.2's L2 says a Continuation reconstructs iff its bound Cmd is durable.
This section names *why*, and it is not a policy choice — it is
physics. A Continuation resumes one of two things:

- A **connection-scoped** Continuation resumes a write to a specific
  socket fd on a specific node — a held HTTP/2 stream, a WebSocket
  frame. That resource is non-replicable. If the leader moves or the
  worker crashes, the socket is gone; there is nothing on the new node
  to resume *to*. Durability is not merely unguaranteed — it is
  **meaningless**: you could persist the registration through raft and
  on recovery have nowhere to deliver it.
- A **tenant-scoped** Continuation resumes pure logical work — "run
  this module, produce these effects (kv writes, outbound sends)."
  Those effects can be produced on any node. Durability is both
  achievable and wanted.

> **L2, sharpened.** A Continuation is durable iff it is tenant-scoped.
> Connection-scoped Continuations are ephemeral *by construction* —
> the resource they resume, a socket fd pinned to one node, is the one
> piece of state consensus cannot move.

This subsumes §2.2's reconstruct-vs-abandon: "bound to a durable Cmd"
⟺ "tenant-scoped." `webhook.send`'s owed Continuation reconstructs
because it is tenant-scoped (its work is logical: process the result,
write kv). Every stream / fetch / held connection abandons because it
is connection-scoped. Same rule, named at its root.

### 6.2 Two axes — scope × delivery

Scope is one of two orthogonal axes that classify every Msg origin
(§2.3) feeding a Continuation. The second is **delivery**: whether the
trigger is *edge* (idempotent "something changed, go look" —
coalescable) or *value* (carries a unique payload that must arrive
exactly once — not coalescable). The two are independent; every trigger
is a cell in a 2×2:

| | edge (coalescable) | value (exactly-once) |
|---|---|---|
| **connection-scoped** — ephemeral, node-local, connection-affine, cancelled on close | `on.kv` wake; disconnect; `on.timer` | held `on.fetch` chunk / result |
| **tenant-scoped** — durable (env-0), tenant-routed, lifecycle independent of any connection | cron; kv-react subscription | `webhook.send` result; durable scheduled wake (`durable_wake`) |

Every property the §4 contract tracks per-effect is derivable from the
cell rather than chosen per-effect:

- **Durability** (§4 q3) and **routing** come from the *row* —
  connection-scoped resumes route to the worker holding the socket
  (continuation-affinity); tenant-scoped resumes route by tenant or are
  picked up from the durable Model + boot-scan.
- **Coalescing** and **failure** semantics (§4 q5/q6) come from the
  *column* — edge triggers fold (the K=32 wake ring); value triggers
  must be delivered exactly once.
- **Cancellation:** terminating a chain (a terminal return) cancels
  exactly the connection row — node-local, no distributed cancel. The
  tenant row was never connection-owned, so it is untouched. This is
  why a close-cancel race does not exist.

Scope is a property of the **registration** (the waiter), not the
event. The same kv write fans out to a connection-scoped `on.kv` wait
*and* a tenant-scoped kv-react subscription; each waiter's own row
decides its durability.

### 6.3 `bind` was the conflated row-selector

The retired `bind` flag — superseded first by auto-bind + `detach`,
then by `on.fetch`'s connection-scoped-by-construction shape
(decisions.md §4.2) — was the API-level operator that chose a
Continuation's row: "does this result resume the held socket?" Because
the row *is* the durability class (§6.1), `bind` was a durability
selector wearing a routing-flag costume, which is why it was
load-bearing and confusing.

The clean decomposition keeps two registrations the flag fused:

- **Durability** is intrinsic to the **primitive**, never a flag.
  `webhook.send` is tenant-row, always (it writes `_send/owed/{id}`,
  §3). `on.fetch` is connection-row, always (no marker, nothing
  promised — and inert if no connection is held).
- **Connection-resume** is *derived from held context* and is
  **additive** — it adds a connection-row resume on top of whatever
  the primitive already is. It can never move a primitive between
  rows: a `webhook.send` whose socket is gone is still durable; you
  merely forgo the socket-resume.

The proof the old flag conflated the two is the carve-out it needed:
`webhook.send`'s internal fetch had to be **excluded** from auto-binding
(decisions.md §4.2 gotchas). Under clean separation there is nothing to
exclude — webhook registers tenant-row because it is durable, and takes
its connection-row resume like anything else in held context. The
exclusion existed *only* because one flag did two jobs.

This is why `webhook.send`'s two-layer shape (§2.2, §3) is exactly the
principle instantiated: a durable tenant-row owed-marker (always)
**plus** an ephemeral connection-row held-sync resume
(`__rove_resume_if_bound`, taken only if the originating socket is
still on this worker). One logical operation registering in both rows —
the held-sync resume is an invisible optimization, never a customer
concept.

### 6.4 Registration ordering — watch before write

The dominant tenant↔connection composition is "respond by streaming,
but the data is produced by a tenant-row effect": a held handler kicks
off durable work and waits on the kv key that work will write (the
decomposed `bind` case). This carries a lost-wakeup hazard — the watch
must be armed before the write it waits for.

The grammar makes this the runtime's invariant, not the author's
burden. Effects are commit-gated (L4): calling `webhook.send` during
the body only *buffers* a Cmd; the activation produces
`(Writeset, Cmd Msg)` atomically. At end-of-activation the runtime
sequences: **arm the activation's connection triggers → commit →
then dispatch the buffered effects.** The author writes the effect
before the `return` in source order and it is still safe, because
neither happens until the activation ends.

It is robust to the *external*-writer race too because **the kv-watch
is anchored to the activation's read view** (`on.kv`'s shipped
semantics, via `beginReadView` / the write-version clock): the watch
fires on any write to its prefix *since the version the handler read
at*. Then —

- the effect's write lands at a version strictly after the read view,
  so it always fires the watch regardless of arm-instant timing;
- a write by another request between "handler read" and "watch armed"
  still fires it — no TOCTOU gap, because the baseline is the read
  view, not wall-clock;
- a key already in terminal state when the handler runs is caught by
  read-on-(re)invoke: the handler reads at the top, sees done, and
  terminates without arming a watch at all.

The user-facing semantic this yields — a kv wait means *"wake me on
any change since the state I just read"* — is exactly how an author
already reasons ("I looked, it wasn't ready; tell me when it changes"),
which is why the ordering rule stays invisible.

### 6.5 The surface that falls out — grammar position = scope

The split reaches customers as **where in the handler you write a
thing**, never a durability flag (full surface spec:
`handler-shape.md`):

- **"What happens to THIS request"** → the **connection-scoped
  surface**: ambient `response.*`, the `stream.*` output effects, the
  `on.*` triggers, and the return (`next()` / a terminal body —
  handler-shape §2). Connection-row: ephemeral, dies with the socket,
  never touches raft.
- **"Work that becomes A NEW request"** → an **effect you call**
  (`webhook.send`, durable `schedule`, `cron` — §3 compositions).
  Tenant-row: durable, runs as a fresh activation whether or not
  anyone is connected, and its result handler is itself a plain
  named-export handler (handler-shape §5).

The author's litmus test is the physics of §6.1, stated for humans:

> **If the caller closed their laptop right now, should this still
> happen?** No → connection surface (this request). Yes → effect call
> (a new request).

Because durable work is "just a new request," it borrows zero concepts
from streaming: simple to start (a call) and simple to handle (a normal
export). Streaming — the genuinely harder model (re-invocation, kv/timer
waits, read-on-reinvoke, the terminal close) — is reached only via the
explicit `stream.*` / `on.*` calls, strictly opt-in and orthogonal to
durability. The two complexities are additive with no cliff: adding a
durable effect never changes your return; adding streaming never
changes your effects. Preserving that gradient is a hard constraint —
the moment `schedule` / `webhook.send` take wait-shaped options or
share types with `stream.*`, the floor inherits streaming vocabulary
and the gradient flattens. Substrate shared, surfaces separate.

## 7. Relation to existing docs

This doc does not replace any of these — it is the frame they are facets
of.

- **`architecture/effects-and-handlers.md`** — the as-built realization:
  the one Continuation runtime (`effect.reconcile`), the L4 commit-gate,
  the four reified primitives under `src/js/effect/`, the durable-input
  substrate §2.5 depends on (body-buffer-then-blob, callback-gating on
  `durable_offset`, the readset in the raft entry), and the auto-bind
  seam §6.3 analyzes.
- **`architecture/routing-and-ingress.md`** — the stream-write Cmd
  runtime + the wake / disconnect Msg origins, as one instantiation
  (commit-then-flush, coalescing, the blob coordinator).
- **`tape-minimization.md`** — L3's tape reduced to four record kinds
  (minimal read set, timestamp, seed, CAS extent); §2 is the
  tape-by-reference design for streamed bytes. The retired
  `primitive-gaps.md` §4 rejections now live in `decisions.md` §12.
- **`handler-shape.md`** — the customer surface §6.5 implies: the
  connection-scoped `stream.*` / `on.*` / `next()` surface is the
  "this request" row; the effect calls are the tenant-row "a new
  request."
- **`decisions.md`** §3 (effects/durability — incl. §3.2 reification,
  §3.3 durability-as-JS-shim) + §4 (handler surface) — the locked
  decisions and rejected alternatives behind §3, §5, and §6.
- **`docs/PLAN.md` §13** — the live process / surface map.
