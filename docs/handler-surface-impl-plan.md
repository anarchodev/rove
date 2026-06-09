# Handler-surface implementation plan

> **Status:** Plan, 2026-06-02 (rev 2 — `stream.*` model). Implements the
> surface in [`handler-shape.md`](handler-shape.md) over the model in
> [`effect-algebra.md`](effect-algebra.md) §8. Pre-launch — no
> back-compat; old paths are deleted in the same change that replaces
> them ([[feedback_no_prelaunch_backcompat]]).

## 0. The final model

**The verb is the scope; output is a commit-gated effect; the return is
pure disposition.**

| Role | Surface | Notes |
|---|---|---|
| **Model** | `kv.get` / `kv.set` / `kv.delete` | read-your-writes; the Model half of `(Model, Cmd)` |
| **Connection output** | `stream.start()` / `stream.write(chunk)` | ambient namespace; commit-gated **effects** (NOT a return verb). Head is ambient `response.*`. |
| **Connection triggers** | `on.timer(ms)` / `on.kv(prefix,{to?})` / `on.fetch(url,opts?,{to?})` | body builders; ephemeral; resume the held connection |
| **Connectionless triggers** | `webhook.send` / `schedule` / `cron` | durable; create a new request |
| **Disposition (return)** | `next({ctx?})` (park) · terminal body / `""` (close) | the only return shapes |

Key consequences vs the prior revision:
- **`stream` moves from a return verb to an effect namespace.** You no
  longer `return stream(...)`; you call `stream.start()` / `stream.write()`
  (commit-gated, like every effect) and `return next()` / a terminal.
- **`RunOutcome` drops the `.stream` arm** → `{ terminal, continuation }`.
  Streaming is an effect-driven property of a parked entity, not a
  disposition.
- The head (status/headers/cookies) is **ambient `response.*`**, committed
  by `stream.start()` / `stream.write()` / a terminal response.
- `detach` retired; `on.fetch` (not `http.fetch`); `subscribe.kv` deferred.

This is the endpoint of the conversation's principle: the only thing
that was still output-in-the-return (`stream`'s `write`) becomes a
commit-gated effect, leaving the return as pure disposition. The earlier
"emit-as-effect is unsafe" objection is resolved by commit-gating —
`stream.write()` buffers and the chunk reaches the wire only after the
activation's writes commit (the `Cmd.stream_chunk` gate already exists,
`architecture/effects-and-handlers.md` §6).

## 1. Current → target gap

| Capability | Current | Target | Verdict |
|---|---|---|---|
| Terminal head | ambient `response.*` (dispatcher.zig `extractResponseMetadata`) | same | **exists** |
| Stream head | descriptor `stream({status,headers})` (stream.zig; worker_drain.zig:733,922-949) | ambient `response.*`, committed by `stream.start`/`stream.write` | **engine change** |
| Streamed output | `stream({write})` **return** verb (`__rove_stream`) → `RunOutcome.stream` | `stream.write()` commit-gated **effect** over the existing pipeline (`Cmd.stream_chunk`) | **engine change** (move return→effect) |
| Stream begin | implicit on first `stream()` return | `stream.start()` effect — commits head, enters pipeline (the move `RunOutcome.stream` did) | **new** effect, reuses pipeline |
| Disposition arms | `RunOutcome.{terminal, continuation, stream}` | `{terminal, continuation}` — drop `.stream` | **engine simplification** |
| Connection wakes | `waitFor:{kv,timer}` on the stream descriptor (stream.zig kv_prefixes/interval_ms → worker_drain.zig:1066) | `on.timer`/`on.kv` body builders; wakes generalized onto held continuations | **new** + collection-machine change |
| Wake target (`{to}`) | continuation `path`+`fn_name` (continuation.zig:58-65) | `{to:"m.f"}` on `on.*` | reuse continuation target |
| Outbound (connection) | `http.fetch` + auto-bind + `detach` (http.zig:312,386,403) | `on.fetch` (auto-bound by construction); `detach` deleted | rename + delete detach |
| Outbound (durable) | `webhook.send` JS shim (shipped) | same | **exists** |
| Export dispatch | resume via continuation `fn_name`; inbound `?fn`/`default`; in-handler `request.activation.kind` switch | runtime maps kind → conventional export (`onChunk`/`onFetchResult`/`onSendCallback`/`onCron`/`onBoot`/`onDisconnect`/**`onWake`**), `{to}` overrides | **new** routing convention + retire kind-switch |
| `cron` / `schedule` | cron via subscription_fire/deploy-spec (gap 2.1) | runtime `cron`/`schedule` verbs (durable, new request) | **depends on gap 2.6** |
| `subscribe.kv` | deploy-time kv-react (gap 2.1) | **deferred** — not built now; `on.kv` covers the connection case | out of scope |
| `import` surface | `__rove_*` natives + `globals/` shims | `stream`/`on` ambient namespaces; `next` return ctor | JS shim layer |

## 2. Phases

Smallest-risk-first; each independently shippable + testable. Each adds
its `globals/` JS shim alongside the native change (globals/_system
split — [[project_globals_system_split]]).

### Phase 1 — `on.*` triggers + wake generalization

The collection-machine phase. Add `on.timer`/`on.kv` as during-body
accumulation on `DispatchState` (same shape as fetch-pending). **Lift
the wake registration + servicing off the stream-only path onto held
continuations too:** `StreamWakes` (kv_prefixes/interval/pending_wakes)
becomes a shared `Wakes` component carried by both `parked_continuations`
and `stream_data_out`; the kv/timer match logic in `serviceParkedStreams`
and the `sweepParkedContinuations` tick are shared. Migrate the stream
descriptor's `waitFor` → `on.*` (remove `waitFor` from the descriptor).
`{to:"m.f"}` reuses the continuation `path`/`fn_name` target; default
target is `onWake` (Phase 4 wires the kind→export map).

- Files: `globals.zig` (+ `bindings/on.zig`), `dispatcher.zig`
  (DispatchState accumulation + drain), `worker.zig` (lift `Wakes` onto
  `parked_continuations`'s Row), `worker_streaming.zig`
  (`serviceParkedStreams` match → shared), `worker_drain.zig`
  (`sweepParkedContinuations` services wakes), `bindings/stream.zig`
  (drop `waitFor`).
- Guards: a held `next()` woken by `on.kv` and by `on.timer`; the §8.4
  read-view-anchored wake (fires for a write since the read view,
  including one a same-activation effect makes); existing streaming
  smokes rewritten to `on.*`.
- Hardest part: the watch-before-effects ordering (§8.4) — arm `on.*`
  wakes before dispatching connectionless effects of the same activation.

### Phase 2 — `stream.*` output effects; drop the `stream` return verb

Add `stream.start()` / `stream.write(chunk)` as commit-gated effects
(buffered during the body, released post-commit) lowering onto the
existing stream pipeline: `stream.start()` commits the ambient head and
moves the entity into `stream_response_in` (the transition the
`stream()` return used to make); `stream.write()` appends via the
existing `Cmd.stream_chunk`. **Delete `__rove_stream`, the `stream`
return verb, and `RunOutcome.stream`.** Streaming handlers now:
`stream.start()` + `stream.write()` + `on.*` + `return next()` /
terminal. Head reads from ambient `response.*` (descriptor head gone).
Fold `raft_pending_stream` into `raft_pending_cont` (the disposition is
always continuation/next now).

- Files: `globals.zig` (+ `bindings/stream.zig` → effect, not
  descriptor), `dispatcher.zig` (`RunOutcome` drops `.stream`),
  `worker_dispatch.zig` (`streamParkIfAny` removed; `stream.start`
  effect drives the pipeline-entry), `worker_drain.zig` /
  `worker_streaming.zig` (consume the effect; head from ambient).
- Guards: SSE smoke (start → write loop → close) on the new surface; the
  §5.8 join unchanged; "chunk ships only after commit" (streaming-model
  §2) preserved; `raft_pending_stream` removal leaves all stream tests
  green.
- Removes shipped behavior: the `stream` return verb, `RunOutcome.stream`,
  `raft_pending_stream`, descriptor head.

### Phase 3 — `on.fetch` + retire `detach`

Reshape the connection-bound `http.fetch` into `on.fetch` (connection-
scoped by construction → auto-bind implicit, no flag). Result export via
`{to}` (default `onFetchResult`/`onFetchChunk`). **Delete `detach`**
(http.zig:312/386/403 + the auto-bind branch in worker_dispatch.zig);
connectionless outbound is `webhook.send` only.

- Files: `bindings/http.zig`, `worker_dispatch.zig`, `globals.zig`.
- Guards: fetch + auto-bind smokes rewritten; connection-drop abandons
  in-flight `on.fetch` while `webhook.send` survives.
- Removes shipped behavior: `detach`, the `http.fetch` spelling.

### Phase 4 — Named-export dispatch by activation kind

Map `activation_source` → a conventional export when no `{to}` override:
`onChunk`, `onFetchResult`/`onFetchChunk`/`onFetchDone`, `onSendCallback`,
`onCron`, `onBoot`, `onDisconnect`, and **`onWake`** for `on.kv`/`on.timer`
(edge wakes — one "go look" handler). Inbound stays `default`. Builds on
existing `fn_name` resolution (dispatcher.zig:935). Retire the
`request.activation.kind`-switch surface (globals.zig:1855-1866). Add §6
deploy-time export-coverage validation.

- Files: `dispatcher.zig` (kind→export in `DispatchCall`), `globals.zig`
  (drop/demote `request.activation.kind`), loader validation.
- Guards: dispatch smoke (each kind lands in its export); validation lint
  (missing resume export → deploy warning).
- Removes shipped behavior: the `request.activation.kind` switch as the
  primary surface.

### Phase 5 — `schedule` / `cron` connectionless verbs (gap 2.6)

Runtime `cron(spec,"m.f")` and `schedule({at|in},"m.f",ctx)` create
connectionless durable requests. Both are durable registrations that
must re-arm on leader change → both ride the gap-2.6 durable-registration
substrate (`durable-wake-plan.md`). `webhook.send` already exists. **This
is the only phase gated on new substrate;** Phases 1–4 are connection-side
and need none.

- Files: `globals.zig` (`schedule`/`cron` shims), durable-wake (gap 2.6)
  registration + boot re-arm.
- Guards: durable-wake smokes (fires after leader change).

### Phase 6 — Polish

Finalize the `rove` module surface (`stream`/`on` ambient namespaces;
`import { next } from 'rove'`); harden the §6 validation lint; **rewrite
`handler-shape.md` to the `stream.*` model** (it still shows `stream` as a
return verb); sweep examples to compile against the shipped surface.

## 3. Collection-model impact

The change touches the state machine in `architecture/effects-and-handlers.md` —
in the **simplifying** direction (your worry was right that it touches
it; it removes structure rather than adding it):

- **`RunOutcome` loses `.stream`.** The return is `terminal` or
  `continuation` (`next`) only. The "one park primitive" is now literal —
  `next` is the sole park. (No `next`-vs-`stream` arm to reconcile; the
  prior plan's "park-unify" phase is *gone* — there's nothing to
  collapse.)
- **`stream.start()` is the transition into the pipeline** that the
  `stream()` return edge used to be. In §3/§4 of the map, the `stream(...)`
  edge relabels to "`stream.start()` effect (commit-gated) →
  `stream_response_in`." Collections + topology unchanged; the trigger
  relabels from a disposition arm to an effect. `stream.write()` is the
  existing `Cmd.stream_chunk`.
- **`raft_pending_stream` folds into `raft_pending_cont`.** With no stream
  disposition, a writing hop always takes the cont raft-wait; the
  `stream.start()` pipeline-entry rides its effect at commit. One fewer
  `raft_pending_*` variant.
- **Wakes generalize (Phase 1).** `StreamWakes` → a shared `Wakes`
  component on both `parked_continuations` and `stream_data_out`; the
  kv/timer servicing is shared. The map's §1 "four kinds of wait":
  **held-continuation and stream-wake converge on their wake SOURCES**
  (both woken by {kv, timer, callback, disconnect, deadline}); the two
  stay distinct *collections* (uncommitted vs committed — that's the
  head-commit boundary), per `feedback_state_is_collection`.
- **Orthogonal to "3b"** (the map's §8 raft-reconcile two-arm→one-arm).
  This plan touches output/disposition + wakes; 3b touches raft-reconcile.
  Different edges — but the continuation loop is the shared blast radius,
  so sequence carefully if 3b is in flight on another branch.

`architecture/effects-and-handlers.md` itself needs updating (§1 four-waits → the
convergence; §3/§4 `stream()` edges → `stream.start()` effect; drop
`raft_pending_stream`) — not done here (not this plan's file).

## 4. Decisions (2026-06-02)

1. **Q1 — `on.fetch`.** `http.fetch` retired; `webhook.send` is the
   connectionless twin (one internal outbound runtime, two scoped
   surfaces — effect-algebra §6 #2).
2. **Q2 — default `onWake`.** `on.kv`/`on.timer` default to one `onWake`
   connection-wake export (edge wakes are "go look"); `on.fetch` keeps
   `onFetchResult`/`onFetchChunk` (value wakes); `{to}` overrides. A
   default is possible *because* a connection wake resumes the current
   continuation; connectionless triggers spawn a new request with no
   current context, so they always name an explicit target — which is
   why this is connection-only and nothing collides.
3. **Q3 — `subscribe.kv` deferred.** `on.kv` covers the connection case;
   no runtime durable kv-react now. `cron`/`schedule` are runtime durable
   verbs gated on gap 2.6 (Phase 5).
4. **`stream` is an effect namespace, not a return verb.**
   `stream.start()` / `stream.write()`; never `return stream(...)`.

## 5. Risk notes

- **Riskiest: Phase 2 (stream return→effect, drop `.stream`) and Phase 4
  (export routing).** Phase 2 rewires the stream entry path and removes a
  `RunOutcome` arm + a `raft_pending_*` collection; Phase 4 changes how
  every resume picks its JS entry. Land both with the full streaming +
  continuation smoke suite green at each step.
- **Phase 1's watch-before-effects ordering** (§8.4) is the one new
  correctness invariant. Test the "wait on a key, write it from a
  connectionless callback" race explicitly.
- **Engine is mostly there.** The Continuation runtime is unified
  (effect-algebra §6 #1), resumes already route to a named export, `next`
  already carries a target, the head is ambient for terminals, the
  stream pipeline + `Cmd.stream_chunk` gate exist. The work is (a) moving
  output to `stream.*` effects + wakes to `on.*`, (b) the kind→export
  convention, and (c) generalizing wakes onto held continuations. The
  only genuinely *new* substrate is gap 2.6 (Phase 5).

## 6. App-manifest seam (reserve now, consume post-launch)

Distributable (marketplace) apps — apps written for the hosted product
that a self-hoster installs on a personal rewind install
(`project_self_host_marketplace`) — need a per-deployment **app
manifest**: install-time **config schema** + listing **metadata**
(author-declared) and the **capability set** (the effect verbs the
deployment uses — *derived*, the install-time grant prompt is built from
it). The marketplace itself is post-launch; the only thing that must be
done *while the surface is being built* is leaving the seam, because the
capability set is a byproduct of code that exists only during this
redesign. The two halves map onto two seams that already exist:

**Half 1 — config schema + metadata (author-declared data).** Rides the
existing `_config/` deploy-mirror pattern: `config_mirror.zig`
(`mirrorConfigToKv`) already walks a release's manifest for
`_config/*.json` and stages it into app.db in the **same `TrackedTxn`
that flips `_deploy/current`**, wired at `worker_dispatch.zig`
`handleRelease` (~:1671). A reserved `_app/manifest.json` bundle file
mirrors the same way to the `_app/manifest` key — a sibling walker
(`manifest_app.zig`) at the same seam. No new deploy machinery; it rides
the atomic release commit. (`_app/` is reserved in `reserved.zig`.)

**Half 2 — capability set (derived, NOT author-declared).** Phase 4's §6
export-coverage validator (`handler-shape.md` §6;
`dispatcher.zig` + loader) **must already enumerate the effect verbs each
handler uses** to check resume-export coverage. That enumeration *is* the
capability manifest. The precedent is `deployment_cache.zig`'s
`buildSubscriptionRegistry` (~:140), which already derives structured
runtime data from the manifest at deploy. Record the used-effect set into
the deployment record beside it.

**The one non-deferrable action — do it in Phase 4:**

> When the §6 validator walks exports and computes the used-effect set for
> coverage validation, **also persist that set into the deployment
> record** (`deployment_cache.zig`, alongside the subscription registry).

The effect-enumeration code is written exactly once — here, in Phase 4.
Retrofitting an effect-enumeration pass after the surface ships is the
expensive part this seam avoids. It is a few lines on a pass already
being written, nothing consumes the output yet, and every app deployed
from that point carries a derived capability manifest.

Cheap companions (anytime, not gated on Phase 4): the `handleRelease`
walk can accept-and-store `_app/manifest.json` so authors declare
metadata/config-schema today.

**Out of scope now (post-launch):** the install/grant UI, the registry,
bundle signing/provenance (the shipped ECDSA primitive), the update flow.
Grant *enforcement* needs almost nothing new — the effect algebra already
enforces least privilege at runtime, so a "grant" is a deploy-time
allow-list diffed against the derived capability set, not new isolation
machinery.

## 7. Relation

- `handler-shape.md` — target surface (needs the `stream.*` rewrite,
  Phase 6).
- `effect-algebra.md` §8 — scope model; §8.4 watch-before-write (Phase 1);
  §6 #1 the unified Continuation runtime Phases 1–2 build on.
- `architecture/effects-and-handlers.md` — the state machine §3 maps onto; needs
  the deltas above.
- `architecture/effects-and-handlers.md` — the `detach` mechanism Phase 3 retires.
- `durable-wake-plan.md` — gap 2.6, the `schedule`/`cron` dependency
  (Phase 5).
- `primitive-gaps.md` §2.1 — the subscription machinery `cron` reuses.
