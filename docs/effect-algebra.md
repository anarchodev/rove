# The effect algebra

> **Status**: synthesis, 2026-05-22. Built from the effect-system audit
> in §5. This is the cross-cutting frame that `unified-effect-gating.md`,
> `primitive-gaps.md` §5, `streaming-model.md`, and
> `connection-actor-plan.md` are each a facet of — see §8. It is the
> ground truth for the question "does this new effect fit the model?"

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

### 2.4 Cmd runtimes — open family

Everything that carries out a Cmd: kv-write, http-out (send + fetch),
connection-write, response-write, `events.emit`. Also an open family.

> **L4 — Every Cmd is a recorded output, and is commit-gated** — released
> only after the Model write of the same activation has committed
> (`committedSeq() >= seq`).

L4 is the `unified-effect-gating.md` invariant. A Cmd is durable only by
*being, or writing, a Model key* — there is no other route to durability
(corollary of L1). kv-write is the degenerate Cmd runtime whose target
*is* the Model.

## 3. Every effect is a composition

No effect is primitive. Each is `Msg-origin(s) ⊕ Cmd-runtime(s) ⊕
Continuation? ⊕ Model?`:

| Effect | Msg origin | Cmd runtime(s) | Continuation | Note |
|---|---|---|---|---|
| KV read | — | — (Model query) | no | synchronous snapshot read, not a Cmd |
| KV write | — | kv-write | no | the Cmd runtime whose target is the Model |
| `http.send` / `cancel` | send-callback | http-out ⊕ kv-write (`_send/owed` marker) | yes | "durable-intent" = http-out composed with a marker write |
| `http.fetch` A (`on_chunk`) | fetch-chunk / fetch-done | http-out | yes | identical to `http.send` minus the marker |
| `http.fetch` B (`pipe_to`) | **none** | http-out ⊕ connection-write | no | Cmd ⊕ Cmd, no Msg → structurally untaped *by derivation* |
| subscriptions (cron/boot/kv-react) | cron / boot / kv-react | — | no | Msg origin alone; boot composes a kv-write marker for idempotency |
| streaming response (`__rove_stream`) | wake / disconnect | response-write | yes | the Continuation *is* the held stream |
| connection-actor | inbound frame | connection-write | yes | duplex: a Msg origin and a Cmd runtime on one Continuation |
| `events.emit` | (consumer's Msg) | events-emit | no | a commit-gated Cmd (gate is a live worklist item — §7) |

Two compositions are worth calling out because they *explain* audit
findings rather than excusing them:

- **`pipe_to` is the one composition with no Msg origin.** The tape
  records Msg origins (L3); with no origin there is nothing to record.
  "Structurally untaped" is a theorem, not a carve-out.
- **`http.send` and `http.fetch` are one outbound-HTTP runtime**
  parameterized by `durable?` and response-disposition
  (single / streamed / piped). They are two named effects today only
  because the runtime was not factored.

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
| `http.send` / `cancel` | `_send/owed/{id}` key in writeset | `send_callback` activation / continuation resume | durable-intent = marker key in env-0 KV |
| `http.fetch` A | `PendingFetch` in per-request list | `fetch_chunk` / `fetch_done` | ephemeral |
| `http.fetch` B (`pipe_to`) | same + `pipe_to` | outside the handler (one `fetch_pipe_done`) | ephemeral |
| subscriptions | deploy-time spec file — no runtime Cmd | `subscription_fire` activation | ephemeral (boot: marker rides writeset) |
| streaming out | `__rove_stream({write, waitFor})` | `wake_batch` / `disconnect` | ephemeral entity; per-activation writes replicated |
| streaming in (body) | — | — | **NOT BUILT** (gap 2.4) |
| conn-actor out (held-sync §6.4) | `__rove_next` / stream chunks | `send_callback` resume | ephemeral entity |
| conn-actor in (WS frames) | — | — | **NOT BUILT** (gap 2.5 / §6.3) |

### Runtime contract

| Effect | Replay | Backpressure | Failure | State home |
|---|---|---|---|---|
| KV read | taped ✓ | none (in-mem) | at-most-once; no durable effect | read-view on `Txn` (worker-local map) |
| KV write | taped ✓ | overlay cap ✓; `WriteSet` itself unbounded ✗ | at-most-once client / at-least-once raft | overlay + `WriteSet` + `pending_txns` map + `raft_pending_*` collection |
| `http.send` | marker taped, no re-fire on replay ✓ | NOT BUILT — only fire-pool=8 ✗ | at-least-once; boot-scan recovery; resolve-once dedup ✓ | `_send/owed`+`proof` in `app.db` ✓ + `InflightSet` (ephemeral) |
| `http.fetch` A | ✗ chunk bytes NOT taped | `fetch_pending` unbounded ✗; per-fetch caps ✓ | at-most-once; no recovery; cancel NOT BUILT | `fetch_pending` list + `fetch_event_pending` collection |
| `http.fetch` B | untaped *by design* ✓ (no Msg origin) | `StreamChunks` 256 KB ✓ | at-most-once | `StreamChunks`+`PipeState` on entity ✓ |
| subscriptions | taped per fire ✓ | cron 1 Hz ✓; kv-react no limit ✗; per-tenant cap maybe NOT BUILT | at-most-once; boot double-fire UNCLEAR | `subscription_fire_pending` collection ✓; `cron_state` plain hashmap ✗ |
| streaming out | taped per activation ✓ (cap 10 MB / 50k) | wake ring K=32 + `StreamChunks` 256 KB — lossy, surfaced ✓ | at-most-once stream; chunks may ship pre-commit ✗ | stream collections ✓ |
| conn-actor out | taped per activation ✓ | `StreamChunks` 256 KB ✓ | at-most-once flush; cross-worker resume = linear scan + requeue ✗ | `parked_continuations` collection ✓ |

The model holds: nine of ten effects fill the template consistently.
The audit caught exactly one breach of the §1 invariant — `http.fetch`
Pattern A returns chunk bytes to the handler without taping them. That
the framework finds exactly one violation, and that the violation is a
*missing instance of a general rule* (L3), is the framework earning its
keep.

## 6. Toward the minimal set

Every divergent cell in §5 has one root cause: **the four primitives are
not factored out.** Each effect hand-rolls its own slice of Continuation,
of taping, of backpressure — and the hand-rolled copies drift. The
minimal-set work is therefore not cosmetic; it is the single fix for
every incoherence the audit found.

What the algebra predicts, each collapsing N runtimes to 1:

1. **One Continuation runtime.** Today: `raft_pending_response` /
   `_cont` / `_stream`, `parked_continuations`, `stream_data_out` /
   `stream_response_in`, `fetch_event_pending` — roughly seven
   collections, park/wake/resume hand-rolled in each. The destination
   is `unified-effect-gating.md` §4 **Option A**: one parametric
   Continuation, instantiated per resume-behavior (the *collections*
   stay — distinct behavior is distinct state, which is ECS-idiomatic;
   the *code* is shared). This auto-fixes backpressure unevenness (the
   wake ring becomes universal) and the cross-worker scan (the primitive
   owns a wake-correlation index, so resume is O(1), not O(workers ×
   parked)).

2. **One outbound-HTTP runtime.** `http.send` + `http.fetch` A + B = one
   runtime parameterized by `durable?` and response-disposition. Today:
   `SendDispatch` and `FetchPool`, two pools, two code paths.

3. **One Msg-origin runtime, taping built in.** cron / boot / kv-react /
   inbound-HTTP / send-callback / fetch-chunk / frame are instances of
   "trigger → recorded Msg." When taping is a property of the primitive,
   the `http.fetch` Pattern A replay bug becomes *unconstructible* — you
   cannot instantiate a Msg origin without the tape hook.

4. **Durability stays in one home.** Already proven by the `schedules.db`
   retirement. The standing rule: a future durable-intent effect is
   *always* "a marker key in KV + an ephemeral runtime + boot-scan
   recovery" — never a new store, never a new envelope type.

The shape of the minimal set: **two singletons that must never be
duplicated (the Model, the Continuation), and two open families whose
every member must plug into those singletons** (gate on the
Continuation, tape via the Msg-origin / Cmd-runtime contract). The
families may grow forever; the singletons may not fork. A proposed
effect that cannot be expressed this way is the signal that the
substrate itself must change — rare, and worth stopping for.

## 7. Worklist

Ranked; the first two are correctness, not cleanup. Reifying the four
primitives (`docs/effect-reification-plan.md`) makes items 1, 3, 4, 5
structurally impossible and forces 2 and 7 into one decision point —
that plan is the systematic way to clear this list.

1. **Tape `http.fetch` Pattern A chunk bytes** — replay-correctness bug;
   `fireFetchEventActivation` passes empty `TapePayloads`. Content-address
   past a threshold (`primitive-gaps.md` §6, also NOT BUILT).
2. **Resolve the streaming pre-commit invariant** — `streaming-model.md`
   §2 bills "a chunk ships only after its activation commits" as *the one
   rule*, but §7/§9.4 and the resume path (`proposeForgetfulWrites`) ship
   chunks pre-commit. Fix the code or rewrite §2; it is not "one rule"
   with an exception.
3. **Adopt the streaming backpressure template** across `http.send`,
   `http.fetch` (`fetch_pending`), the `WriteSet`, and kv-react —
   four unbounded queues.
4. **Cross-worker Continuation resume is a scan, not a route** — no
   durable/indexed locator; falls out of refactor #1.
5. **`cron_state` lives in a plain `StringHashMap`** — right durability
   class, wrong home; the one clear two-places drift. Move to a
   collection.
6. **Boot subscription double-fire is UNCLEAR** — crash between
   marker-write and propose may re-fire and partially duplicate
   non-marker writes. Needs a definite answer.
7. **`events.emit` commit-gating** — one of the Class-B premature-release
   proposers in `unified-effect-gating.md` (idiom-1). L4 not yet enforced
   for it.

Known catalog gaps, *not* incoherence: streaming inbound body (gap 2.4),
connection-actor inbound / WebSocket (gap 2.5 / §6.3), `http.cancelFetch`
transport. Also: `src/connection_holder/` is superseded dead code
carrying a parallel connection model — delete or clearly mark v2-WIP.

## 8. Relation to existing docs

This doc does not replace any of these — it is the frame they are facets
of.

- **`unified-effect-gating.md`** — the Continuation singleton (Option A)
  and the L4 commit-gate (the `ParkedUnit` reconciler). Option B
  (mechanism) shipped; Option A (the one-request-lifecycle collapse) is
  the open destination this doc calls "one Continuation runtime."
- **`primitive-gaps.md` §5** — four of the laws stated as per-gap
  disciplines (affine, commit-gated, replayability, bounded tape). §6
  is the bound on L3's tape.
- **`streaming-model.md`** — the response-write Cmd runtime + the
  wake / disconnect Msg origins, as one instantiation.
- **`connection-actor-plan.md`** — the duplex connection effect:
  connection-write Cmd runtime + frame Msg origin on one Continuation.
- **`docs/PLAN.md` §13** — the live process / surface map.
