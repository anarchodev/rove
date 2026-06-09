# The effect algebra

> **Status**: synthesis, 2026-05-22. Built from the effect-system audit
> in §5. This is the cross-cutting frame that `primitive-gaps.md` §5 and the
> as-built `architecture/effects-and-handlers.md` + `architecture/routing-and-ingress.md`
> are each a facet of — see §9. It is the ground truth for the question "does this new
> effect fit the model?"
>
> The customer-facing handler surface (named exports per Msg kind,
> `stream()` / `next()` Cmd verbs) is specified in
> [`handler-shape.md`](handler-shape.md). The Cmd / Msg tables
> below use the engine's internal names (`__rove_stream` /
> `__rove_next` / `request.activation.kind`); the customer-typed
> surface renames these without changing the engine semantics.

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
second durable store was always redundant. `http.send`'s durable intent
is now `_send/owed/{id}` keys in the tenant's own `app.db`, riding the
ordinary envelope-0 writeset. Two replicated stores remain — `app.db`
(per-tenant) and `__root__.db` (root) — and they are the same primitive
at two scopes, not two primitives.

### 2.2 The Continuation — singleton

A parked handler activation that correlates an emitted Cmd to the future
Msg that answers it. Mechanically: park an entity → subscribe it to a
wake source → resume it when the Msg arrives. `http.send`'s callback,
`http.fetch`'s chunks, a held stream's wakes, a held connection's
frames — all the same structure.

> **L2 — A Continuation is always ephemeral.** It must be reconstructible
> from the Model, or safe to abandon — and it is safe to abandon iff no
> externally-observable effect has escaped.

`http.send` is the only Continuation that *reconstructs* (boot-scan of
`_send/owed/` re-arms it) — because it is bound to a durable Cmd that
promised delivery. Every other Continuation *abandons* on loss: a
dropped stream/fetch/connection becomes a failed request, and that is
correct because nothing was promised. The reconstruct-vs-abandon choice
is determined entirely by whether the bound Cmd is durable.

### 2.3 Msg origins — open family

Everything that produces a Msg into a handler: inbound HTTP, cron, boot,
kv-react, send-callback, fetch-chunk, inbound connection frame, inbound
body chunk. New origins are expected — this family is where the algebra
is *allowed* to grow.

> **L3 — Every Msg is a recorded (taped) input.** No information may
> enter a handler except through a recorded Msg or a Model snapshot read.

This is the engine-side half of determinism. arenajs handles
within-activation; L3 handles between. The tape is bounded per chain
(`primitive-gaps.md` §6) — recorded, not recorded *forever*.

The next origin proposed for this family is a **durable scheduled wake**
(`primitive-gaps.md` §2.6, unbuilt): a one-shot, absolute-time,
at-least-once `durable_wake` Msg whose fire-time is itself a Model key.
It generalizes the one place L2 reconstruction is currently hardcoded —
the webhook boot-scan of `_send/owed/` (§2.2) — into a primitive, so
`webhook.send`, durable cron, and delayed jobs become §3 compositions
over it rather than features leaning on a webhook-specific sweep.

### 2.4 Cmd runtimes — open family

Everything that carries out a Cmd: kv-write, http-out (send + fetch),
connection-write, response-write, `events.emit`. Also an open family.

> **L4 — Every Cmd is a recorded output, and is commit-gated** — released
> only after the Model write of the same activation has committed
> (`committedSeq() >= seq`).

L4 is the commit-gate invariant: no externally-observable effect may be released until `committedSeq() >= seq`. A Cmd is durable only by
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

This is what makes §6 rule 4 ("durability stays in one home — and that
home is JS") actually work for arbitrary-sized handler payloads: a JS
shim's durability marker need not contain the bytes being made durable,
only a pointer to the activation that can re-derive them. For input
bytes the marker pattern doesn't apply at all — they're routed through
effects-and-handlers's body-buffer-then-blob mechanism, durable by
construction at the point a handler can observe them.

## 3. Every effect is a composition

No effect is primitive. Each is `Msg-origin(s) ⊕ Cmd-runtime(s) ⊕
Continuation? ⊕ Model?`:

| Effect | Msg origin | Cmd runtime(s) | Continuation | Note |
|---|---|---|---|---|
| KV read | — | — (Model query) | no | synchronous snapshot read, not a Cmd |
| KV write | — | kv-write | no | the Cmd runtime whose target is the Model |
| outbound HTTP — whole response | http-done | http-out | yes | the single outbound primitive |
| outbound HTTP — `on_chunk` (Pattern A) | http-chunk / http-done | http-out | yes | streaming response — chunks fire activations |
| outbound HTTP — `pipe_to` (Pattern B) | **none** | http-out ⊕ connection-write | no | Cmd ⊕ Cmd, no Msg → structurally untaped *by derivation* |
| `webhook.send` / `email.send` (JS shims) | (the shim's `on_result`) | kv-write ⊕ http-out | yes | durable-intent is a *composition* — kv marker + outbound HTTP + retry-cron + boot-subscription, none of them new primitives |
| `blob.put` (JS shim) | http_done from PUT | kv-write ⊕ http-out | yes | content-addressed marker `_blob/owed/{hash}` (pointer to source activation, NOT the bytes) + idempotent PUT; recovery re-executes the source activation to re-derive bytes — bytes too large to fit in marker, but inputs are durable so they're derivable; §2.5 |
| `blob.get` (JS shim) | http_done (or http_chunk if streamed) | http-out | yes | direct `http.fetch(blob_url(hash))` with all three dispositions; local-BlobBackend fast-path is a JS-shim choice, not a primitive distinction; no marker, no durability — failed read = client retries |
| subscriptions (cron/boot/kv-react) | cron / boot / kv-react | — | no | Msg origin alone; boot composes a kv-write marker for idempotency |
| streaming response (`__rove_stream`) | wake / disconnect | response-write | yes | the Continuation *is* the held stream |
| connection-actor | inbound frame | connection-write | yes | duplex: a Msg origin and a Cmd runtime on one Continuation |

Three compositions are worth calling out because they *explain* audit
findings rather than excusing them:

- **`pipe_to` is the one composition with no Msg origin.** The tape
  records Msg origins (L3); with no origin there is nothing to record.
  "Structurally untaped" is a theorem, not a carve-out.
- **Outbound HTTP is one runtime, not two named effects.** Earlier
  drafts split it as `http.send` (durable) vs `http.fetch` (transient).
  `architecture/effects-and-handlers.md` Phase 5 (revised 2026-05-22) deletes
  the split: there is one outbound HTTP Cmd parameterized by
  response-disposition (whole / chunk / pipe); durability is *not* a
  parameter and not a verb-level choice.
- **`webhook.send` / `email.send` retire as Zig primitives.** They
  become standard-library JS shims that compose `kv.set("_send/owed/
  {id}", ...)` (rides envelope-0 atomic with the handler's writes) +
  the outbound HTTP primitive + a `_subscriptions/send-retry/` cron
  subscription that re-fires stale markers + a boot subscription on
  leader-promotion. The original "durable-intent" framing (a baked-in
  Zig primitive) was a premature optimization: every piece composes
  from primitives that now exist (kv writes, cron, boot, and the
  outbound HTTP runtime). The composition is **visible JavaScript in
  the standard library** — the platform dogfoods its own primitives,
  and customers can read / fork the retry policy. A paid-tier fast
  path (pattern-match the shim, dispatch native) is a post-launch
  optimization that does not change the customer-facing API.
  See `architecture/effects-and-handlers.md` Phase 5 for the migration steps.
- **`blob.put` / `blob.get` deferred.** Customer-facing blob primitives
  were specced and then canceled 2026-05-27 alongside
  `architecture/effects-and-handlers.md` Phase 7 (files-server-standalone stays
  separate; the JS-shim composition pattern doesn't get exercised on
  this surface). No customer demand established; defer until concrete
  use case forces it. The input/output asymmetry the design rested on
  still holds — see `primitive-gaps.md` §7.4.

## 4. The contract — six questions every effect answers

Any effect, shipped or proposed, must answer these six identically.
Where two effects answer differently, the algebra is incoherent there.

1. **Cmd shape** — what the handler emits to invoke it.
2. **Msg shape** — what re-enters a handler, as what Msg; or "outside
   the handler" (the `pipe_to` case — and *only* that case).
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

## 5. The audit — 2026-05-22

Ten effect-shapes scored against §4. `✓` conforms, `✗` diverges.

### Handler-facing shape

| Effect | Cmd | Msg | Durability |
|---|---|---|---|
| KV read | sync call — no Cmd | sync return — no Msg | ephemeral (snapshot-pinned) |
| KV write | writeset op | none | replicated-mutation (env-0) |
| outbound HTTP — whole | `PendingFetch` in per-request list | `http_done` (a chain activation) | ephemeral |
| outbound HTTP — A (`on_chunk`) | same | `http_chunk` / `http_done` | ephemeral |
| outbound HTTP — B (`pipe_to`) | same + `pipe_to` | outside the handler (one `http_pipe_done`) | ephemeral |
| `webhook.send` / `email.send` (JS shims) | `_send/owed/{id}` kv write + a `PendingFetch` | the shim's `on_result` (a chain activation triggered by `http_done`) | durable-intent = composition (kv write rides env-0 atomic with handler) |
| `blob.put` (JS shim) | `_blob/owed/{hash}` kv write (pointer to source activation, no bytes) + `PendingFetch` PUT to BlobBackend URL | the shim's `on_result` (a chain activation triggered by `http_done`) | durable-intent = composition; recovery via re-execution per §2.5; requires effects-and-handlers for full semantics |
| `blob.get` (JS shim) | `PendingFetch` GET against BlobBackend URL | `http_done` (or `http_chunk` if streamed) | ephemeral; no marker (failed read = client retries) |
| subscriptions | deploy-time spec file — no runtime Cmd | `subscription_fire` activation | ephemeral (boot: marker rides writeset) |
| streaming out | `__rove_stream({write, waitFor})` | `wake_batch` / `disconnect` | ephemeral entity; per-activation writes replicated |
| streaming in (body) | — | `inbound_chunk` Msg with `BodyRef` payload (per effects-and-handlers §4.4) | input bytes durable in BlobStore via `{tenant}/readset-blobs/{batch_id}`; callback gated on `durable_offset` advance; **NOT BUILT** (gap 2.4 — design in effects-and-handlers §4 + primitive-gaps §7) |
| conn-actor out (held-sync §6.4) | `__rove_next` / stream chunks | `send_callback` resume | ephemeral entity |
| conn-actor in (WS frames) | — | — | **NOT BUILT** (gap 2.5 / §6.3) |

### Runtime contract

| Effect | Replay | Backpressure | Failure | State home |
|---|---|---|---|---|
| KV read | taped ✓ | none (in-mem) | at-most-once; no durable effect | read-view on `Txn` (worker-local map) |
| KV write | taped ✓ | overlay cap ✓; `WriteSet` itself unbounded ✗ | at-most-once client / at-least-once raft | overlay + `WriteSet` + `pending_txns` map + `raft_pending_*` collection |
| outbound HTTP — whole / A / B | taped at the http-done / http-chunk Msg ingress (Phase 2D wires the hook; closes worklist #1) | `fetch_pending` unbounded ✗; per-fetch caps ✓ | at-most-once; B untaped *by design* (no Msg origin); whole + A at-most-once with no kernel-level recovery | `fetch_pending` list + `fetch_event_pending` collection (both retire in Phase 2D) + `StreamChunks` / `PipeState` on entity for B |
| `webhook.send` / `email.send` (JS shims) | marker taped via the ordinary env-0 writeset; the shim's `on_result` activation is taped like every other chain hop ✓ | retry-cron rate ✓ ; first-attempt rides handler dispatch; subsequent attempts ride the cron sweep ✓ | at-least-once at the *attempt* level (M1) via marker-write/clear; **NOT** retry-to-success — that is the shim's policy choice | `_send/owed/{id}` kv (durable, replicated) + the shim's per-attempt scratch state |
| `blob.put` (JS shim) | marker taped via env-0 writeset ✓; PUT request itself rides http-out's taping; `on_result` is taped like any chain hop ✓ | retry-cron rate ✓; bytes ride the activation's QJS arena until first PUT completes (not held across retries — recovery re-derives) | transient-loss-tolerant; **eventually recoverable** from inputs via re-execution per §2.5 — content-addressing makes retry idempotent; effects-and-handlers is the recovery prerequisite | `_blob/owed/{hash}` kv (durable, replicated) carries only `{correlation_id, seq, call_index, dest_key}`; bytes themselves live in BlobStore at `{tenant}/blobs/{hash}` (cache; transiently absent OK) |
| `blob.get` (JS shim) | http-out taping applies ✓ | http-out's `fetch_pending` cap ✓ | at-most-once read; transient backend miss surfaces as 503 — caller retries; no recovery, no marker | none |
| subscriptions | taped per fire ✓ | cron 1 Hz ✓; kv-react no limit ✗; per-tenant cap maybe NOT BUILT | boot: single-fire via writeset-bundled `_boot_fired/<dep_id>` marker (`worker_streaming.zig:1105`) ✓; cron + kv-react: at-most-once | `subscription_fire_pending` collection ✓; `cron_state` collection ✓ (worker-0 owned) |
| streaming out | taped per activation ✓ (cap 10 MB / 50k) | wake ring K=32 + `StreamChunks` 256 KB — lossy, surfaced ✓ | at-most-once stream; chunks may ship pre-commit ✗ | stream collections ✓ |
| conn-actor out | taped per activation ✓ | `StreamChunks` 256 KB ✓ | at-most-once flush; cross-worker resume = linear scan + requeue ✗ | `parked_continuations` collection ✓ |

The model holds: every effect that remains a Zig primitive fills the
template consistently. The audit caught exactly one breach of the §1
invariant — Pattern-A outbound HTTP returns chunk bytes to the handler
without taping them. That the framework finds exactly one violation,
and that the violation is a *missing instance of a general rule* (L3),
is the framework earning its keep. (Phase 2D of
`architecture/effects-and-handlers.md` closes it.)

Note: this revision (2026-05-22) collapses `http.send` + `http.fetch`
into one row — they are one outbound HTTP runtime. `webhook.send` /
`email.send` are JS-shim *compositions* on top, not primitives. The
old "durable-intent primitive" row retired because every piece of its
composition (kv markers, retry cron, boot subscription, outbound HTTP)
is already a primitive.

## 6. Toward the minimal set

Every divergent cell in §5 had one root cause: **the four primitives
were not factored out.** Each effect hand-rolled its own slice of
Continuation, of taping, of backpressure — and the hand-rolled copies
drifted. The reification work in `docs/architecture/effects-and-handlers.md`
landed the consolidation (Phases 0–5 SHIPPED 2026-05-24, `b908953`).

The four predictions the algebra made, against current state:

1. **One Continuation runtime — SHIPPED.** The seven hand-rolled park
   collections (`raft_pending_response` / `_cont` / `_stream`,
   `parked_continuations`, `stream_data_out` / `stream_response_in`,
   `fetch_event_pending`) now share one parametric Continuation
   primitive (`effect.Continuation`), with per-resume-behavior
   collections retaining distinct state but sharing the park/wake/
   resume code. Cross-worker resume is O(1) via the wake-correlation
   index. The wake ring is universal.

2. **One outbound-HTTP runtime — SHIPPED.** `http.send` retired as a
   primitive (Phase 5, 2026-05-24). The only outbound HTTP runtime
   is `fetch_pool` (now `fetch_engine`, the curl_multi engine)
   parameterized by response-disposition (whole / `on_chunk` /
   `pipe_to`). `SendDispatch` + `InflightSet` + `send_outbox` + the
   apply-time special-cases for `_send/owed` / `_send/proof` all
   deleted. Durability reconstitutes as JS-shim composition (rule 4).

3. **One Msg-origin runtime, taping built in — SHIPPED.** Phase 2D
   wired the tape hook into the Msg-origin primitive; the Pattern A
   chunk-tape bug is *unconstructible* — you can't instantiate a Msg
   origin without the tape hook.

4. **Durability stays in one home — and that home is JS — SHIPPED.**
   Proven by the `schedules.db` retirement (2026-05-19) + the
   `http.send` → JS-shim cutover (2026-05-24). The standing rule: a
   durable-intent effect is *always* the JS composition `kv.set(
   "_<verb>/owed/{key}", ...)` (rides envelope-0 atomic with the
   handler's writes) + outbound HTTP + a retry cron subscription + a
   boot subscription on leader-promotion. No new store, no new
   envelope type, no new Zig primitive. The composition is part of
   the standard library (`webhook.send.js`, `email.send.js`) — the
   platform dogfoods its own primitives, and customers can read or
   fork the policy.

   A paid-tier fast path that pattern-matches a shim and dispatches
   native is a post-launch optimization, not part of the model.

The shape of the minimal set: **two singletons that must never be
duplicated (the Model, the Continuation), and two open families whose
every member must plug into those singletons** (gate on the
Continuation, tape via the Msg-origin / Cmd-runtime contract). The
families may grow forever; the singletons may not fork. A proposed
effect that cannot be expressed this way is the signal that the
substrate itself must change — rare, and worth stopping for.

## 7. Worklist

Substantially cleared by `docs/architecture/effects-and-handlers.md` Phases 0–5
(SHIPPED 2026-05-24, `b908953`).

1. ~~**Tape outbound-HTTP Pattern A chunk bytes**~~ — **DONE** via
   reification Phase 2D (`fireFetchEventActivation` now passes
   populated `TapePayloads`; chunks content-addressed past a threshold).
2. ~~**Resolve the streaming pre-commit invariant**~~ — **DONE** via
   Phase 4.0.b. The pre-commit-ship path in `proposeForgetfulWrites`
   is removed; resume-hop chunks stage on the entity until commit, then
   move into `StreamChunks`. Per [[feedback_model_simplicity_safety]]
   ship-one-safe-semantic; `__rove_stream({eager_ship: true})` reserved
   for customer demand.
3. **Backpressure template across remaining unbounded queues** —
   `StreamChunks` cap shipped (Gap 2.2); `fetch_pending` + `WriteSet`
   + kv-react remain unbounded. Smaller cleanup item; ship when a
   real overflow shows up.
4. ~~**Cross-worker Continuation resume scan**~~ — **DONE** via the
   continuation-affinity routing per `project_callback_execution_model`
   (callbacks route to the worker holding the continuation via a
   pointer, not via hash(tenant)); no scan.
5. ~~**`cron_state` lives in a plain `StringHashMap`**~~ — **DONE
   2026-05-27** via `architecture/effects-and-handlers.md` Phase 6 step 2.
   Moved to a `CronState` component on a `cron_state` collection on
   every worker (only worker 0 populates it; the sweep was already
   worker-0 + leader gated at the caller). `node.cron_state` +
   mutex deleted.
6. ~~**Boot subscription double-fire is UNCLEAR**~~ — **RESOLVED.**
   The `_boot_fired/<dep_id>` marker rides the handler's writeset
   (`worker_streaming.zig:1105`) — marker + handler effects commit
   atomically. No "fired-but-not-marked" window; single-fire
   semantics. The earlier "marker written AFTER" concern reflected a
   pre-2026-05 implementation; current code is safe.
7. ~~**Retire `http.send` as a Zig primitive**~~ — **DONE 2026-05-24**
   via Phase 5 + the durability-as-JS-shim flip. ~4.7 kLOC of Zig
   deleted; `webhook.send.js` / `email.send.js` compose durability
   over kv markers + outbound HTTP + retry cron + boot subscription.
8. ~~**Delete `src/connection_holder/` dead scaffold**~~ — **DONE
   2026-05-27** via `architecture/effects-and-handlers.md` Phase 6 step 1.

Known catalog gaps, *not* incoherence: streaming inbound body
(gap 2.4 — design locked; implementation pending, see
`architecture/routing-and-ingress.md`), connection-actor inbound / WebSocket (see
`docs/websocket-plan.md`), `http.cancelFetch` transport.

## 8. Trigger scope — connection vs tenant

> **Status**: synthesis, 2026-06-02. Deepens L2 (§2.2): it names *why*
> a Continuation reconstructs-or-abandons, and the two orthogonal axes
> that classify every trigger feeding a Continuation. The customer
> surface this implies is specified in [`handler-shape.md`](handler-shape.md);
> here it is the model justification for that surface's shape.

### 8.1 A Continuation's durability is forced by its scope

§2.2's L2 says a Continuation reconstructs iff its bound Cmd is durable.
The 2026-06 design names *why*, and it is not a policy choice — it is
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

### 8.2 Two axes — scope × delivery

Scope is one of two orthogonal axes that classify every Msg origin
(§2.3) feeding a Continuation. The second is **delivery**: whether the
trigger is *edge* (idempotent "something changed, go look" —
coalescable) or *value* (carries a unique payload that must arrive
exactly once — not coalescable). The two are independent; every trigger
is a cell in a 2×2:

| | edge (coalescable) | value (exactly-once) |
|---|---|---|
| **connection-scoped** — ephemeral, node-local, connection-affine, cancelled on close | held-stream kv-prefix wake; disconnect; timer | held `http.fetch` chunk / result |
| **tenant-scoped** — durable (env-0), tenant-routed, lifecycle independent of any connection | cron; kv-react subscription | `webhook.send` result; durable scheduled wake (gap 2.6) |

Every property the audit (§5) tracks per-effect is derivable from the
cell rather than chosen per-effect:

- **Durability** (§4 q3) and **routing** come from the *row* —
  connection-scoped resumes route to the worker holding the socket
  (continuation-affinity, §6 prediction 1 + worklist #4); tenant-scoped
  resumes route by tenant or are picked up from the durable Model +
  boot-scan.
- **Coalescing** and **failure** semantics (§4 q5/q6) come from the
  *column* — edge triggers fold (the wake-ring, Gap 2.2); value
  triggers must be delivered exactly once.
- **Cancellation:** terminating a chain (`close` / response value)
  cancels exactly the connection row — node-local, no distributed
  cancel. The tenant row was never connection-owned, so it is
  untouched. This is why a close-cancel race does not exist.

Scope is a property of the **registration** (the waiter), not the
event. The same kv write fans out to a connection-scoped held-stream
wait *and* a tenant-scoped kv-react subscription; each waiter's own row
decides its durability.

### 8.3 `bind` was the conflated row-selector

The retired `bind` flag (now auto-bind + `detach`, see
`architecture/effects-and-handlers.md`) was the API-level operator that chose a
Continuation's row — "does this result resume the held socket?" Because
the row *is* the durability class (§8.1), `bind` was a durability
selector wearing a routing-flag costume, which is why it was
load-bearing and confusing.

The clean decomposition keeps two registrations that `bind` fused:

- **Durability** is intrinsic to the **primitive**, never a flag.
  `webhook.send` is tenant-row, always (it writes `_send/owed/{id}`,
  §3). `http.fetch` is connection-row, always (no marker, nothing
  promised).
- **Connection-resume** is *derived from held context* (auto-bind) and
  is **additive** — it adds a connection-row resume on top of whatever
  the primitive already is; `detach` removes it. It can never move a
  primitive between rows: detach a `webhook.send` and it is still
  durable; you merely forgo the socket-resume.

The proof the old flag conflated the two is the auto-bind carve-out
that **excludes `webhook.send`'s `bound_send_id`** from auto-binding
([[project_auto_bind_reshape]]). Under clean separation there is
nothing to exclude — webhook registers tenant-row because it is
durable, and auto-binds its connection-row resume like anything else in
held context. The exclusion exists *only* because one flag did two
jobs.

This is why `webhook.send`'s two-layer shape (§2.2, §3) is exactly the
principle instantiated: a durable tenant-row owed-marker (always)
**plus** an ephemeral connection-row held-sync resume
(`__rove_resume_if_bound`, the held-sync resume in `architecture/effects-and-handlers.md`, taken
only if the originating socket is still on this worker). One logical
operation registering in both rows — the held-sync resume is an
invisible optimization, never a customer concept.

### 8.4 Registration ordering — watch before write

The dominant tenant↔connection composition is "respond by streaming,
but the data is produced by a tenant-row effect": a held handler kicks
off durable work and waits on the kv key that work will write (the
decomposed `bind` case). This carries a lost-wakeup hazard — the watch
must be armed before the write it waits for.

The grammar makes this the runtime's invariant, not the author's
burden. Effects are commit-gated (L4): calling `webhook.send` during
the body only *buffers* a Cmd; the activation produces
`(Writeset, Cmd Msg)` atomically. At end-of-activation the runtime
sequences: **arm the return-value's connection triggers → commit →
then dispatch the buffered effects.** The author writes the effect
before the `return` in source order and it is still safe, because
neither happens until the activation ends.

Make it robust to the *external*-writer race too by **anchoring the
kv-watch to the activation's read view** (reuse `beginReadView` /
`READSET_VERSION`): the watch fires on any write to its prefix *since
the version the handler read at*. Then —

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

### 8.5 The surface that falls out — grammar position = scope

The split reaches customers as **where in the handler you write a
thing**, never a durability flag (full surface spec:
`handler-shape.md`):

- **"What happens to THIS request"** → the **return value**
  (`response` / `stream` / `next`, handler-shape §2). Connection-row:
  ephemeral, dies with the socket, never touches raft.
- **"Work that becomes A NEW request"** → an **effect you call**
  (`webhook.send`, durable `schedule`, cron — §3 compositions).
  Tenant-row: durable, runs as a fresh activation whether or not
  anyone is connected, and its result handler is itself a plain
  `(req) → response` export (handler-shape §5.4 / §5.6).

The author's litmus test is the physics of §8.1, stated for humans:

> **If the caller closed their laptop right now, should this still
> happen?** No → return value (this request). Yes → effect call (a new
> request).

Because durable work is "just a new request," it borrows zero concepts
from streaming: simple to start (a call) and simple to handle (a normal
export). Streaming — the genuinely harder model (re-invocation, kv/timer
waits, read-on-reinvoke, `close`) — is reached only via the explicit
return verbs, strictly opt-in and orthogonal to durability. The two
complexities are additive with no cliff: adding a durable effect never
changes your return; adding streaming never changes your effects.
Preserving that gradient is a hard constraint — the moment `schedule` /
`webhook.send` take wait-shaped options or share types with `stream`,
the floor inherits streaming vocabulary and the gradient flattens.
Substrate shared, surfaces separate.

## 9. Relation to existing docs

This doc does not replace any of these — it is the frame they are facets
of.

- **`architecture/effects-and-handlers.md`** — the realization of "one Continuation
  runtime" (the Option-A one-request-lifecycle convergence) and the L4
  commit-gate as a generalized `ParkedUnit` reconciler. Option-B
  mechanism shipped; the Option-A collapse is the active phasing.
- **`primitive-gaps.md` §5** — four of the laws stated as per-gap
  disciplines (affine, commit-gated, replayability, bounded tape). §6
  is the bound on L3's tape; §7 is the customer-facing surface
  (`blob.put` / `blob.get` shims, inbound-body persist-before-observe)
  for the §2.5 substrate distinction this doc names.
- **`architecture/effects-and-handlers.md`** — the durable-input substrate
  this doc's §2.5 corollary depends on: every "body" routes through
  a per-tenant BlobStore buffer with callback-gating on
  `durable_offset`; the readset in the raft entry makes
  re-execution (and therefore `blob.put` recovery, §6 rule 4) work
  without navigating Model history.
- **`architecture/routing-and-ingress.md`** — the response-write Cmd runtime +
  the wake / disconnect Msg origins, as one instantiation.
- **`architecture/effects-and-handlers.md`** — the duplex connection effect:
  connection-write Cmd runtime + frame Msg origin on one Continuation; the
  held-sync resume is the connection-row half of §8.3.
- **`handler-shape.md`** — the customer surface §8.5 implies: the
  three return verbs (`response` / `stream` / `next`) are the
  connection-row "this request"; the effect calls are the tenant-row
  "a new request."
- **`architecture/effects-and-handlers.md`** — the `bind` → auto-bind + `detach`
  reshape §8.3 analyzes; the connection-resume registration as a
  context-derived additive, not a durability knob.
- **`docs/PLAN.md` §13** — the live process / surface map.
