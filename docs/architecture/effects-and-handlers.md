# Effects & the handler model

> 🟢 **As-built reference.** The execution model: how a customer handler runs,
> how its external effects are reified, committed, and recovered, and how a held
> interaction survives across activations. Owns `src/js/` (the worker dispatcher,
> `src/js/effect/`, the bindings, the JS shims). For *why* these shapes were
> chosen see [decisions.md §3](../decisions.md) (effects/durability/handler
> model), §4 (handler surface), §5 (readset replication). Two companion
> references stay separate because they are the customer-facing contract:
> [`handler-shape.md`](../handler-shape.md) (the API surface) and
> [`effect-algebra.md`](../effect-algebra.md) (the four-primitive model + live
> effect audit).

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
  `onWake` (timer/kv), `onFetchChunk` (bound fetch), `onDisconnect` (client
  close), plus the connectionless origins. `activationKindForExport` maps kind →
  export name.
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
`http.fetch` + a boot/cron-scoped sweep that re-fires stale markers. The
dedicated `http.send` Zig primitive, the schedule envelopes, and the leader-local
`SendDispatch` were all **deleted** (~4.7 kLOC net, `b908953`). Owed-recovery is
a single-pass boot-scan of `_send/owed/` across tenant DBIs (decisions.md §3.4).
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
- **Auto-bind** (decisions.md §4.2): a held handler's `http.fetch` binds to the
  held chain by default (chunks resume `onFetchChunk`); `detach:true` opts out.
  Registration happens at the **handler-success seam** (`worker_dispatch.zig`),
  the only place held-vs-terminal is known. `webhook.send` is excluded from
  auto-bind so it can't steal chunks from the system result handler.

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

- **Marker-commit race — mitigated, not fully closed.** An inline fetch can
  complete before the handler's writeset commits. `Cmd.http_fetch` is now staged
  on the parked unit and released only post-commit, which closes the dangling-
  marker case; the residual first-fire latency is swept (~1 s). The proper fix is
  the commit-gated Cmd buffer (effect-reification Phase 4.1, the one remaining
  active phase). See decisions.md §3.3 gotcha 5.
- **`durable_wake` (gap 2.6) is design-in-code, not wired.** The `Msg.durable_wake`
  variant and the `scheduler.*` lib shape exist; the firing path is not built. It
  is the planned unification point for `webhook.send` / `email.send` / `retry.*` /
  durable cron / delayed jobs. See [`durable-wake-plan.md`](../durable-wake-plan.md).
- **Streaming inbound body (gap 2.4)** is design-locked (the `onChunk` export, the
  ≤1 MB-fires-once rule) but the h2 chunk-delivery wire-up is pending.
- **Inbound WebSocket dispatch (piece D)** — the transport is shipped (see
  routing-and-ingress); the worker `onMessage` seam consuming `ws_message_out` is
  the remaining piece.
- **Per-tenant kv-react backpressure has no cap** at the apply-time fan-out (the
  K=32 wake ring bounds the *holder* side only). A small cleanup, deferred until
  measured hot.
