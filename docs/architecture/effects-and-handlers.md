# Effects & the handler model

> 🟢 **As-built reference.** The execution model: how a customer handler runs,
> how its external effects are reified, committed, and recovered, and how a held
> interaction survives across activations. Owns `src/js/` (the worker dispatcher,
> `src/js/effect/`, the bindings, the JS shims). For *why* these shapes were
> chosen see [decisions.md §3](../decisions.md) (effects/durability/handler
> model), §4 (handler surface), §5 (readset replication). Two companion
> references stay separate because they are the customer-facing contract:
> [`handler-shape.md`](../handler-shape.md) (the API surface) and
> [`effect-algebra.md`](../effect-algebra.md) (the four-primitive model + the
> trigger-scope axes).

## The shape in one paragraph

A handler is the Elm-style `update : (Msg, Ctx) -> (Effects, Cmd Msg)`. Each
activation is a **pure function** of a recorded `Msg` and a pinned KV read
snapshot; it accumulates a KV writeset and declares `Cmd`s. The writeset
replicates through raft; **every `Cmd` is released only after its writeset
commits** (commit-gated). Every `Msg` is a recorded (taped) input, so a handler
run is deterministically replayable. Durability is **composed in JavaScript**
over a single `http.fetch` primitive, not baked into Zig. State that outlives an
activation (a held connection, a parked write) is **collection membership**, not
a flag.

## The four reified primitives (`src/js/effect/`)

Every external effect is a declaration over four reified primitives — not a
hand-rolled subsystem (decisions.md §3.2). `Cmd` and `Msg` are compiler-enforced
tagged unions: `interpretCmd` is an exhaustive switch, so the build refuses until
every variant is handled in the release path.

| Primitive | File | What it is |
|---|---|---|
| **Model** | (the per-tenant KV) | The only durable store. kvexp speculative overlay + `app.db`; reads pinned per-activation for determinism. |
| **Continuation** | `effect/continuation.zig` | A parked unit: `{seq, txn, buffered Cmds, wake, deadline}`. `reconcile` is the *one* system that resumes all parks — commit ≥ seq → `txn.commit()` + interpret buffered Cmds + resume; **fault** (bridge-declared) → `txn.rollback()` + discard; **timeout** (deadline, not faulted) → *request* a pump-side fault (`bridge.requestFault`) and stay parked — a unilateral worker-thread rollback would race the pump's provenance skip for this very entry; the next sweep resolves to commit (committed-beats-faulted) or a normal fault. Affine: no handle is exposed to JS; the chain *is* the connection by construction. |
| **Msg** | `effect/msg.zig` | The activation origin (tagged union over `ActivationSource`): `inbound`, `send_callback`, `timer`, `disconnect`, `kv_wake`, `wake_batch`, `subscription_fire`, `fetch_chunk`, `durable_wake`, `ws_message`. `enqueueMsg` (`effect/queue.zig`) is the single tape-emitting ingress. |
| **Cmd** | `effect/cmd.zig` | The commit-gated runtime effect: `kv_wake_broadcast`, `stream_chunk`, `stream_close`, `http_fetch`, `respond`. Released only when `committedSeq() >= seq`. |

`src/js/effect/msg.zig` / `cmd.zig` are the source of truth for the live variant
sets — both are open families (a new origin/runtime adds a variant + its dispatch
arm).

## The handler model

- **Dispatch by activation kind → named export** (`src/js/dispatcher.zig`,
  `runOutcome` is the single re-entry point). `default` (inbound HTTP),
  `onWake` (timer/kv), `onFetchResult` / `onFetchChunk` / `onFetchDone` (bound
  fetch, by event shape), `onDisconnect` (client close), plus the connectionless
  origins (`onBoot` / `onSubscription`; the manifest cron subscription and its
  `onCron` export retired with durable-wake P5(b) — recurrence is the `cron()`
  verb); `{to}` / `?fn=` overrides.
  `activationKindForExport` maps kind → export name.
- **Return is a disposition**: a terminal body closes the interaction;
  `next({ctx?})` parks it for the next wake. The response head is the ambient
  `response` global, not a return argument (decisions.md §4.1).
- **Scope encodes durability**: `on.*` / `stream.*` are *current-connection*
  effects (ephemeral, node-local); `webhook.send` / `schedule` / `cron` are
  *connectionless* (durable, survive a leader change). The verb is the scope.
- **Fresh JS context per request** via arenajs's dual-arena reset (one cursor
  write per request); the base arena is built once at worker startup.

## Durability is composed in JavaScript shims

There is **one** outbound HTTP primitive, `http.fetch`. `webhook.send` /
`email.send` / `retry.*` are JS standard-library shims that compose durability on
top of it (decisions.md §3.3): a `kv.set("_send/owed/{id}", …)` owed-marker
(an ordinary envelope-0 write that rides the handler's batch atomically) + the
`http.fetch` + a **durable scheduled wake** under the idempotency key
`_send/{id}` aimed at the baked `__system/webhook_fire` (durable-wake P5(a)):
scheduled fires, retry re-arms (`webhook_onresult` moves the wake to the
backoff time), and the crash-recovery watchdog are one `scheduler` entry. The
dedicated `http.send` Zig primitive, the schedule envelopes, the leader-local
`SendDispatch`, and later the per-feature owed sweep (`sweepOwedRetries*`)
were all **deleted** (`b908953`; P5(a)). Owed-recovery is the generic
durable-wake promotion pass — no `_send/owed/`-specific scan remains.
The rule: small bounded payload (a webhook body) → bytes-in-marker; arbitrary
size (blob bytes) → pointer-in-marker + re-execution.

## Readset replication

A raft entry carries the **writeset and the readset**
(`[u32 ws_len][ws][u32 rs_len][rs]`, framed in `src/js/apply.zig`; the V2 node
strips the frame before `applyEncoded`). The readset records foreign KV reads,
fetch responses (as `BodyRef` `{batch_id, offset, len}`), the trigger payload,
module hashes, and the seed — everything a replay needs. Durability is
**callback-gated, not propose-gated**: the handler only reads body bytes after
they are durable, so a downstream write can't depend on a non-durable read
(decisions.md §5.1). **Inline ≤ 16 KB** rides the raft fsync directly; **> 16 KB**
parks on the blob coordinator (`body_pending` / `BodyDurabilityWait`) until the
S3 PUT lands. A body-durability `.failed` returns 503 and does **not** re-submit
(decisions.md §5.2).

## Streaming & auto-bind

- **One held chain** carries one h2 entity through multiple activations via
  `ctx`. Three components ride the entity: `StreamChain` (path + ctx),
  `StreamChunks` (256 KB soft cap, drop-newest + `dropped_chunks`), `StreamWakes`
  (a K=32 wake-accumulator ring, drop-oldest + `lost_oldest`).
- **The one rule**: a chunk reaches the wire only *after* the activation that
  produced it commits (`Cmd.stream_chunk`). See
  [`routing-and-ingress.md`](routing-and-ingress.md) for the streaming substrate
  (commit-then-flush, coalescing, the blob coordinator).
- **The `finishResponse` bridge** (`src/js/dispatcher.zig`) is the one
  classification point: an activation that called `stream.start()`/`stream.write()`
  and returned `next()` is converted to the internal `Stream` descriptor (head
  from ambient `response.*`, chunks moved out of the effect buffer, wakes from
  the `on.*` accumulator) and re-parks in the stream pipeline; a terminal with
  buffered chunks prepends them before END_STREAM. Every entry point — inbound,
  `resumeStream`, the bound-fetch resumes — funnels through it, which is why the
  downstream pipeline (`stream_response_in` → `stream_data_out`,
  `serviceParkedStreams`/`resumeStream`) survived the surface redesign unchanged.
  WS frame output bypasses the bridge (`ws_frame_output`; chunks lower to
  `ws_send_in` instead).
- **Auto-bind** (decisions.md §4.2): `on.fetch` is **connection-scoped by
  construction** — a held handler's `on.fetch` binds to the held chain (no
  opt-out flag; a non-held `on.fetch` is dropped inert). Results dispatch by
  event shape when no `{to}` is given: whole body → `onFetchResult`, streaming
  chunk → `onFetchChunk`, streaming terminal → `onFetchDone`
  (`UpstreamFetchEvent.resolvedExport`, `src/js/components.zig`). Registration
  happens at the **handler-success seam** (`worker_dispatch.zig`), the only
  place held-vs-terminal is known. The internal `_system.http.fetch` (used by
  `webhook.send` / `http.subscribe`) never auto-binds, so it can't steal chunks
  from the system result handler.

## Collection lifecycle & held state

State is **collection membership** (decisions.md §3.1). Four orthogonal wait
kinds, each its own marker, each released by its own signal:

| Wait | Collection | Released by |
|---|---|---|
| Raft-commit | `raft_pending_response` / `_cont` / `_stream` (+ `SharedTxnPool`, keyed **(group, seq)** — V2 seqs are per-tenant, so a bare-seq key collides across tenants) | `committedSeq() >= seq`, or fault/deadline |
| Body-durability | `body_pending` | blob coordinator HWM passes the body's seq |
| Held-continuation | `parked_continuations` | callback arrives, or deadline → 504 |
| Stream-wake | stream-data-out | kv-write match, timer fire, or disconnect |

The three `raft_pending_*` siblings are reconciled by **one** `effect.reconcile`
system, driven once per tick by `drainRaftPending` (`src/js/worker_drain.zig`) —
not three parallel engines (decisions.md §3.1).

**Cross-worker held state.** Inbound connections land on any worker
(SO_REUSEPORT); async wakes hash to `hash(tenant) % N`. When the held state lives
on a *different* worker than the wake lands on, `MsgRouter` (`src/js/msg_router.zig`)
resolves it: `bound_fetch_owners[fetch_id]` / `bound_send_owners[send_id]` route
the wake to the owning worker, falling back to `hash(tenant)` on a registry miss.
(Continuation-affinity, shipped 2026-06-04 — a pointer, not a hash.)

## Known limitations (as-built)

- ~~**Marker-commit race**~~ — closed by the commit-gated Cmd buffer
  (effect-reification Phase 4.1.2, shipped 2026-05-24): `Cmd.http_fetch` is
  staged on the parked unit and submitted to the FetchEngine only after the
  batch commits, so an inline fetch can no longer complete before its
  handler's writeset is durable. Crash recovery is the send's durable-wake
  watchdog (`__system/webhook_fire`, +40 s) — the owed sweep is deleted.
  See decisions.md §3.3 gotcha 5.
- ~~**`durable_wake` (gap 2.6) is design-in-code, not wired**~~ — shipped: the
  firing path is built (`durable_wake.sweepDurableWakes` → `fireSchedulerTick`;
  `Msg.durable_wake` → `fireDurableWakeActivation` with atomically-committed
  `_sched/` cleanup deletes), proven by `scripts/durable_wake_smoke_v2.py`
  (incl. 3-node failover survival). The unification SHIPPED (P5, 2026-06-10):
  `webhook.send` / `email.send` / `retry.*` deferred fires ride a wake aimed at
  `__system/webhook_fire`; durable cron is the `cron()` verb over
  `__system/cron_tick`; the per-feature Zig sweeps (`sweepOwedRetries*`,
  `CronState` + `sweepCronSubscriptions`) are deleted. See
  [`durable-wake-plan.md`](../durable-wake-plan.md).
- ~~**Streaming inbound body (gap 2.4)**~~ — shipped 2026-06-10
  (`docs/inbound-chunk-plan.md`): a module exporting `onChunk` receives
  any-size bodies per-chunk over the `blob.receive` transport seam (a
  worker-side `BodySink`; window repay rides each fire's resolution, so
  the client throttles to the handler's commit rate). Chunk K+1 fires
  only when K's activation committed and re-parked — ordering and
  read-your-writes are collection membership. Proven by
  `scripts/inbound_chunk_smoke_v2.py`. Two follow-ups remain (the
  plan's remaining-work list): chunk payloads aren't yet taped on
  resume fires (multi-chunk replay gap), and chunked uploads are
  direct-to-worker until the front-door streaming proxy lands.
- ~~**Inbound WebSocket dispatch (piece D)**~~ — shipped 2026-06-09: the worker
  `onMessage`/`onDisconnect` seam (`serviceWsMessages`, `src/js/worker_ws.zig`)
  consumes `ws_message_out` and lowers `stream.write` to `ws_send_in`
  (commit-gated for writing frames). Proven by `scripts/ws_worker_smoke_v2.py`.
- **Per-tenant kv-react backpressure has no cap** at the apply-time fan-out (the
  K=32 wake ring bounds the *holder* side only). A small cleanup, deferred until
  measured hot.
