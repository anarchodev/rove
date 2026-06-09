# Primitive gaps — proposals for systematic removal

**Status:** Original five gaps DONE or design-locked (2026-05-20 →
2026-05-27). **One new gap open: §2.6 durable scheduled wake (proposed
2026-06-01, unbuilt).** Streaming gaps (2.3 / 2.4 / 2.5) consolidated
under `docs/architecture/routing-and-ingress.md`. Tape-minimization arc: §6 considered-and-
removed; §7 design-only (unbuilt — gated on customer LLM-stream demand);
§7.4 cancelled with effect-reification Phase 7; §8 + §9 shipped
2026-05-26; §10 summarizes. The load-bearing value is §2.6 (the open
proposal), §4 (do-not-re-propose), §5 (cross-cutting constraint), §7 (the
design for streamed-byte capture when LLM-replay matters), and §10 (the
four-kind minimal tape).

---

## 1. The primitive surface today (vocabulary recap)

Handler is `update : (Msg, Ctx) → (Effects, Cmd Msg)` (the TEA
shape — the runtime IS the Elm runtime).

| Slot | Variants today | Where defined |
|---|---|---|
| **Msg** (wake source) | `inbound_request`, `send_callback`, `timer` (in-memory cron — non-durable clock), `kv_wake`, `disconnect` | `architecture/effects-and-handlers.md` §2 + §4 |
| **Cmd** (return shape) | `Response`, `__rove_next`, `__rove_stream` | `architecture/effects-and-handlers.md` §3 |
| **Effects** (accumulated in batch) | kv writeset (env-0), `webhook.send` (env-0 `_send/owed/{id}` marker via JS shim) | `src/js/bindings/webhook.send.js`, `architecture/effects-and-handlers.md` Phase 5 |
| **Inline-synchronous side primitive** | kv triggers (BEFORE/AFTER prefix hooks) | `src/js/trigger_dispatch.zig` |
| **Chain identity** | `correlation_id`, `ctx` | `architecture/effects-and-handlers.md` §5–§6 |

Every gap below either adds a row to this table or reshapes a row so
the gap is a parametric case.

---

## 2. The gaps

### 2.1 Chain origins without an inbound request — **DONE 2026-05-20**

Three chain-origin kinds shipped:

- **kv-react** — apply-time hook fires on the worker that committed
  the writeset; leader-only by construction.
- **boot** — `NodeState` cross-thread inbox + leadership-gained sweep;
  `_boot_fired/<dep_id>` marker injected into handler's writeset for
  atomicity (single-fire even across leader change).
- **cron** — throttled 1Hz in-memory sweep on worker 0 + leader;
  `next_fire_at_ns` lives on a `CronState` rove collection
  (effect-reification Phase 6); not raft-replicated, leader change
  resets the clock by design (missed-tick tolerance over false fidelity).

All three share one collection (`subscription_fire_pending`) + one
fire path (`fireSubscriptionActivation`). Smokes:
`streaming_subscription_{boot,kv,cron}_smoke.py`. **Composability
unlocked:** customer-built cron, queues, inboxes, workflows,
reconcilers, deploy-time migrations.

---

### 2.2 Backpressure surfaces — **DONE 2026-05-20**

`PendingWakes` ring (K=32) + `lost_oldest` counter on `StreamWakes`;
`StreamChunks` 256 KB byte cap + `dropped_chunks` counter. The
activation Msg surface unified `kv|timer` wakes into a single
`wake_batch` carrying `wakes: [...]` + `overflow.lost_oldest`; every
wake-driven activation also surfaces `write_pressure.dropped_chunks`.
Legacy single-slot `PendingKvWake` deleted. Smokes:
`streaming_overflow_smoke.py` + `streaming_write_pressure_smoke.py`.
See `project_gap_2_2_backpressure` memory for the commit map.

**Composability unlocked:** customers distinguish "rate limited" from
"client slow" from "everything fine" without guessing.

---

### 2.3 / 2.4 / 2.5 — streaming surface, both directions

**See [`docs/architecture/routing-and-ingress.md`](architecture/routing-and-ingress.md) — it is the
unifying model for all three.** The held chain processes a stream of
Msgs and emits a stream of Cmds; bytes ride as chunks; "buffered" is
the runtime coalescing that stream by default. Each individual gap
below is a case of that model rather than a standalone design.

- **2.3 Streaming response bytes from outbound HTTP** — **DONE
  2026-05-21**. Reframed to `http.fetch` (transient + best-effort
  sibling of the durable `webhook.send`); Pattern A (`on_chunk`) +
  Pattern B (`pipe_to`) + `CURLOPT_WRITEFUNCTION` streaming transport
  all shipped. See architecture/routing-and-ingress.md §4 + §4.A (model + as-built
  `http.fetch` reference).
- **2.4 Streaming request body in** — **DESIGN LOCKED, IMPLEMENTATION
  PENDING.** Customer surface in `handler-shape.md`: a module exports
  `default` (buffered, ≤ 1 MB hard ceiling) and/or `onChunk` (per-chunk
  delivery, any size, the small-body case fires once with the whole
  body and `request.done = true`). Bodies > 1 MB without `onChunk`
  exported → 413 from the runtime before the handler runs. The
  superseded "park-until-body-complete" middle tier is gone — there's
  no buffered-but-bigger path; you either fit in 1 MB or stream.
  Implementation is h2-wire + activation-Msg + per-chunk coord submit;
  the blob coordinator is the substrate. See `architecture/routing-and-ingress.md` §3
  for substrate detail and `handler-shape.md` for the surface.
- **2.5 Held outbound subscription (external-push wake)** — **DONE
  2026-05-24**. `http.subscribe` binding + `FetchEngine` curl_multi
  transport in `src/js/fetch_engine.zig`; per-tenant cap
  `HELD_MAX_PER_TENANT=16`; cooperative `http.cancelSubscription`.
  Smokes: `scripts/subscription_smoke.py` + `subscription_cap_smoke.py`.
  Federation transport prereq (atproto firehose CONSUMER) satisfied
  modulo WS framing — see [`docs/websocket-plan.md`](websocket-plan.md).

---

### 2.6 Durable scheduled wake — **PROPOSED 2026-06-01, unbuilt**

**The gap.** `webhook.send` is supposed to be a §3 *composition* of
primitives — a JS shim over `kv.set` + `http.fetch`
([[project_durability_as_js_shim]]). It isn't, quite. It has a
**privileged tail** a customer cannot reproduce: the retry/boot sweep
(`worker.zig` `sweepOwedRetries` / `sweepOwedRetriesOnPromotion`) is
hardcoded to scan the reserved `_send/owed/` prefix and fire the baked
`__system/webhook_onresult` module. A customer can write the marker and
the `http.fetch`, but they **cannot express "re-arm me at time T,
surviving leader change"** — so they cannot build `webhook.send`, or any
durable-timer feature, out of the primitives they have. That asymmetry is
the smell: a feature (§3) leaning on machinery no other §3 composition can
reach.

**This is not a missing law — it is a hardcoded instance of L2.**
`effect-algebra.md` §2.2 (L2) already says the owed Continuation is the
*one* Continuation that **reconstructs** rather than abandons, precisely
because it is bound to a durable Cmd that promised delivery; the boot-scan
is that reconstruction. The defect is only that reconstruction is wired to
*webhook's* prefix and handler instead of being a primitive. And
`effect-algebra.md` §2.3 already blesses the fix: **Msg origins are the
open family "where the algebra is allowed to grow."** `cron` and `boot`
live there today. A durable wake is the missing sibling.

**The primitive.** A **one-shot, absolute-time, at-least-once durable
wake**: `Cmd.scheduleWake(at_ns, msg)` — a Cmd runtime whose target is the
Model (it writes an ordinary env-0 key `{at_ns, handler, msg}`) — plus a
`durable_wake` Msg origin that fires when `at_ns` falls due. The generic
sweep scans durable-wake keys and emits the Msg; **it is webhook-agnostic.**
`_send/owed/` collapses to *the webhook library's private kv namespace*
with no special sweep or apply-time semantics; `webhook_onresult` stops
being baked and becomes ordinary library JS.

**One-shot absolute, not interval-cron.** The temptation is "durable
cron." Resist it — an interval is strictly *less* expressive:

- Webhook retry needs **irregular** fire times (exp backoff 1s, 2s, 4s…),
  which an interval cannot express. This is exactly why the owed marker
  stores `next_at_ns` (an absolute timestamp), not a period.
- **Recurrence = a one-shot that re-arms itself** (the self-rescheduling
  pattern). Interval-cron is then *sugar* over the absolute primitive,
  not the primitive.
- It **unifies the two timers that exist today** — the §2.1 cron sweep
  (interval, non-durable clock, resets on failover) and the owed sweep
  (absolute, durable) — into one durable-absolute-wake, with interval-cron
  as a library on top.

**What it collapses.** `webhook.send`, `email.send`, `retry.*`, durable
cron, delayed/scheduled jobs, debounce, lease/TTL expiry, saga timeouts —
all become libraries over one Msg origin. The boot-scan becomes the
primitive's implementation, not per-feature magic. This is the durable-
execution timer (Temporal timers, Cloudflare Durable Object alarms, Step
Functions wait-states all reduce to it).

**Consistent with L1 — not a second store.** The wake records are
ordinary env-0 Model keys, so this does **not** reintroduce the
`schedules.db` / envelope-8-11 second store deleted 2026-05-19
(`effect-algebra.md` §2.1). Durability stays in the one Model; only the
*Msg origin* is new, and §2.3 sanctions new Msg origins.

**The residue you cannot banish.** Reconstruction cannot move into pure
user JS: user JS only runs in response to a Msg, and *something* with two
powers user code structurally lacks must produce the first one — (1) fire
when no request is in flight, (2) re-scan durable state on leadership
promotion. That something is privileged by necessity. The win is it is
**one primitive's runtime serving all user code, not a special-case bolted
onto webhooks.** And the line stays honest: **at-least-once *firing* ≠
exactly-once *effect*.** The wake guarantees the handler runs (possibly
twice — boot re-fire + normal fire); idempotency of the external effect
stays the handler/library's job (the `kv.get(marker) == null → no-op`
guard in `webhook_onresult` is exactly that, content-addressing is its
`blob.put` analog). The primitive gives durable *scheduling*, not durable
*dedup*.

**The locus fork — two naive options** (both superseded; resolution
below). The granularity / queue-locus choice shapes the implementation:

- **One raw durable alarm per tenant** (Cloudflare DO's exact API shape).
  Dodges the index problem — next-fire lives on the tenant slot,
  O(tenants) max — but exposes a single mutable slot, which forces
  independent libraries (cron, webhook, email, retry) to **share and
  clobber** it: webhook sets its retry at T+2s, cron overwrites to T+60s,
  the retry silently never fires. That is the silent-failure /
  hidden-coupling class this whole effort exists to kill.
- **Engine owns the per-tenant ordered queue.** Closes the clobber — the
  engine merges everyone's timers onto one cached next-fire — but puts the
  queue + ordering + min-heap in **Zig**: a time-ordered due-index
  (`_wake/due/{ts}/{id}`) popped **O(due)**, with the steady-state tick
  kept off the O(N_tenants) path ([[feedback_no_n_tenants_hot_path]],
  [[project_owed_recovery_strategy]]).

**RESOLVED: a canonical JS `scheduler` lib over a capability-scoped
minimal primitive.** Both naive options miss the project's grain. The
clobber hazard is a property of *exposing the raw slot*, not of the
one-next-fire-per-tenant efficiency — so don't conflate them. And the
ordering/queue logic is a *composition*, which by the durability-as-JS-shim
direction ([[project_durability_as_js_shim]]) and the "compose from
primitives / new Zig is a smell" priors ([[feedback_compose_from_primitives]],
[[feedback_stop_before_zig]]) belongs in JS, not the engine. Three layers:

- **Engine** — one durable next-fire per tenant (a single timestamp; fire
  one `durable_wake` Msg when due — almost exactly today's owed-sweep
  mechanism, generalized + feature-agnostic) plus the resource caps. The
  raw single-slot primitive is a **scoped capability**, reachable only by
  the `scheduler` baked lib (the `__system/` privilege), never by ordinary
  customer handler code — so customers *cannot* clobber the slot.
- **One canonical `scheduler` JS lib** — owns the per-tenant queue,
  ordering, and fan-out (ordinary kv; taped + replayed like any handler
  state). Exposes the public `scheduler.at(at_ns, msg)`; everyone — stdlib
  and customers — composes timer features on it. cron / webhook / email
  *do* cooperate, but only by sharing this one dependency, encapsulated so
  the feature authors never think about it.
- **Feature libs** (cron, email, webhook, retry) — policy only, composed
  on `scheduler.at()`.

This gets the **composability** of the engine-owned-queue (everyone
composes on `scheduler.at()`; the clobber footgun closed by
capability-scoping the raw slot, not by the engine owning the queue) with
the **minimal-engine** posture of the JS-shim direction (queue, ordering,
backoff are inspectable, replaceable JS).

**Replaceability — opt-in, deferred.** Because the feature libs hard-depend
on `scheduler`, a customer cannot swap the low-level slot without breaking
them. Default = the shared canonical `scheduler`. If a customer genuinely
needs different low-level behavior, provide an override seam ("bring your
own scheduler satisfying interface X; you now own the single-slot
invariant") — a sharp escape hatch, opt-in, **not built until a customer
asks** ([[feedback_compose_from_primitives]],
[[feedback_model_simplicity_safety]]).

**Honest residual.** This is not zero-privileged-code — it is **one generic
privileged JS lib instead of N feature-specific Zig sweeps**. `scheduler`
becomes a shared critical-path dependency, so a bug in it breaks every
timer feature at once; the trade is the usual centralization one (one
well-tested lib over N hand-rolled copies) and it stays fully replayable.
A large win over today's per-feature Zig, not a free one.

**The contract fork — firing vs completion — RESOLVED: firing.** The
second axis is what the wake *guarantees*, and it decides whether
`_send/owed/` survives at all:

- **At-least-once firing** (weaker): the wake guarantees the handler
  *runs* (possibly twice); the handler/library owns the retry loop and
  the dedup. The obligation record (`_send/owed/`) survives as ordinary
  library kv — de-privileged, but present.
- **At-least-once completion** (stronger, the Cloudflare DO `alarm()`
  model): the wake persists until the handler returns terminal-success;
  the *engine* re-arms on throw/retry and clears the wake on success. The
  wake record IS the obligation, so the separate marker **collapses** —
  no `_send/owed/` at all. Cost: retry/backoff policy moves into the
  engine (Zig), a bigger privileged surface.

**Resolve in favor of firing.** The apparent dilemma — "engine-owned
retry lets us rate-limit; customer-owned retry is flexible + less special
code" — is false, because retry **policy** and retry **budget** separate
cleanly across layers:

- **Policy** (attempts, backoff curve, give-up) is a *composition* —
  lives in JS. Customer picks it; the library
  (`globals/webhook.js` + `webhook_onresult`) ships a safe default
  (`max_attempts=5`, 1→60s backoff) so safe-by-default needs no engine
  retry.
- **Budget** (how fast wakes fire, how much outbound a tenant gets) is a
  *resource bound* — lives in the engine **regardless of who owns the
  policy.** Every wake flows through the engine's wake dispatcher and
  every attempt through `http.fetch`; both are strike-bound Cmd runtimes
  (§5). A pathological "re-arm every 1ms forever" policy is just wake
  records the dispatcher fires at *its* budgeted pace under *its*
  per-tenant `http.fetch` cap.

So you keep all three properties at once: **you** control the rate (the
caps below), **customers** decide the policy (JS), and there's **less
special engine code** (no retry kernel — retry stays in the shim).

The tiebreaker: **completion walks back the durability-as-JS-shim
decision** ([[project_durability_as_js_shim]], `b908953`) that deleted
~4.7 kLOC of Zig (`SendDispatch` + the send retry kernel) precisely to
move the retry loop into JS. Firing is continuous with that direction and
with the "compose from primitives / new Zig is a smell" priors
([[feedback_compose_from_primitives]], [[feedback_stop_before_zig]]);
completion re-absorbs a composition into the engine.

Consequence for the original question: **`_send/owed/` does not
disappear — it is de-privileged.** The marker was never the problem; the
*privileged sweep* was. Under firing it survives as ordinary
library-owned kv with no reserved-prefix / apply-time / baked-handler
semantics.

The two structural caps firing requires (wanted anyway — a runaway engine
retry loop or a million single-retry tenants needs an aggregate bound
either way):

1. a **per-tenant wake-dispatch budget** (rate + max outstanding wakes —
   sibling of `HELD_MAX_PER_TENANT=16`), bounding queued wake activations
   so one tenant's retry storm can't starve others or run O(N) on a tick
   ([[feedback_no_n_tenants_hot_path]]); and
2. the **per-tenant `http.fetch` resource bound** already required.

Cap #1 is real strike-posture work, not free — but it *is* the control
surface, not a tax paid for the firing contract.

**Preserves all of §5.** Commit-gated (the wake Cmd writes a Model key,
released post-commit per L4); replayable (the `durable_wake` Msg is a
taped input per L3; `at_ns` is a recorded scalar); affine + strike posture
untouched (no held handle, resource/deadline bound). It is an additive Msg
origin, not a relaxation.

### 2.6.1 Interface and caps — concrete spec

**The capability-scoped engine primitive.** One global builtin, callable
only from baked scheduler code (gated on `is_system_module`, the same
posture as the other `__rove_*` builtins that survive `_harden.js`'s
`_system` deletion — [[project_durability_as_js_shim]] bug #1):

```
__rove_set_wake(when_ns: bigint)   // set THIS tenant's single next-fire;
                                   // 0n ⇒ none. Idempotent overwrite.
```

The engine keeps one `next_wake_ns` per tenant on the tenant slot, in a
per-worker-partitioned min-structure (`hash(tenant) % n_inboxes`, matching
the owed sweep's routing) so the 1 Hz tick is **O(tenants-due)**, not
O(tenants-with-any-timer). When `now ≥ next_wake_ns` it fires the baked
`__system/scheduler_tick` module in that tenant's context. On leadership
gain it fires `scheduler_tick` once per partitioned tenant to reconstruct
(generalizes `sweepOwedRetriesOnPromotion`). `scheduler_tick` is the only
caller of `__rove_set_wake`; customer handlers never reach it — that
scoping is what closes the clobber footgun.

**The public `scheduler` JS lib** (`globals/scheduler.js`, a documented
shim per [[project_globals_system_split]]). cron / webhook / email / retry
all compose on it:

```js
// Invoke `target` with `msg` at absolute `whenNs`. At-least-once FIRING;
// target owns dedup + retry (the firing contract). Returns a stable id.
scheduler.at(whenNs: bigint, target: string, msg?: any,
             opts?: { key?: string }) => string

// Convenience: `delayMs` from now (rounded up to the next tick).
scheduler.after(delayMs: number, target: string, msg?: any,
                opts?: { key?: string }) => string

scheduler.cancel(id: string) => boolean             // true iff removed
scheduler.get(id: string) => { id, whenNs, target, key } | null
```

- `target` — a module specifier, same shape as `__rove_next` / webhook
  `on_result`.
- `msg` — JSON-serializable; delivered as the activation Msg (below).
- `opts.key` — idempotency. `id = base64url(sha256(key))` (43 chars,
  mirrors webhook's `handle`); same key ⇒ same id ⇒ last-write-wins (moves
  `when` / `target` / `msg`). No key ⇒ `crypto.randomUUID()`. **Re-arming =
  `at()` again with the same key.**
- **No recurrence here** — a one-shot that re-arms itself (the
  absolute-one-shot decision); the `cron` lib is the recurring sugar over
  `scheduler.after()`.

**Storage** (ordinary tenant kv, owned by the lib — no reserved
semantics):

```
_sched/by_id/{id}                     -> {when_ns, target, msg, key?}
_sched/by_time/{when_ns_padded}/{id}  -> ""      // time-ordered index
```

`scheduler_tick` range-scans `by_time` from the front for due entries (up
to the per-tick cap), dispatches each `target`, and **deletes the fired
entry's two keys in the same writeset as the dispatched activation's
effects** — so the normal path fires exactly once; at-least-once arises
only from a crash between fire and commit (a boot re-fire), exactly the
`_send/owed/` semantics. A target needing strict-once dedups on `id`
(webhook's `kv.get(marker)==null` guard is this). After draining,
`scheduler_tick` recomputes the min and calls `__rove_set_wake(new_min)`.

**Dispatched activation:**

```
request.activation = { kind: "durable_wake", id, key, scheduled_at_ns, msg }
```

**Per-tenant caps** — concrete values for the firing-contract wake-dispatch
budget (caps #1/#2 above); all fail-loud
([[feedback_fail_loud_resource_exhaustion]]), operator-tunable:

| Cap | Default | Rationale |
|---|---|---|
| `SCHED_MAX_OUTSTANDING` | 10,000 | depth ceiling; `at()` past it throws. Governs boot-recovery scan cost (~1–2 s / 10k, [[project_owed_recovery_strategy]]); raisable, cost scales linearly — paged/lazy recovery is the lever beyond that |
| `SCHED_MAX_FIRES_PER_TICK` | 256 | thundering-herd bound when many wakes share a due-time; remainder carries to the next tick; ~matches per-chain commit-bound throughput (§6). Spread load with `key`-jitter, not a higher cap |
| `SCHED_TICK_RESOLUTION` | 1 s | matches existing 1 Hz sweeps + cron's ≥1000 ms floor (`worker.zig` `interval_ms` min); `whenNs` rounds up to the next tick; sub-second unsupported |
| `SCHED_MAX_MSG_BYTES` | 16 KiB | `msg` is durable + taped; mirrors the 16 KiB readset inline threshold (`FETCH_INLINE_THRESHOLD`). Bigger ⇒ store in your own kv, pass a `key` in `msg` |
| per-tenant `http.fetch` cap | (existing) | retry attempts ride `http.fetch`; bounded there, not re-specified here |

`SCHED_MAX_OUTSTANDING` + `SCHED_MAX_FIRES_PER_TICK` together are cap #1
(depth + rate); the `http.fetch` bound is cap #2.

---

## 3. Sequencing

The original five are DONE or design-locked; §2.6 is a new open
proposal. Status snapshot:

| # | Gap | Status |
|---|---|---|
| 1 | 2.2 backpressure | **DONE 2026-05-20** |
| 2 | 2.1 chain origins | **DONE 2026-05-20** (kv-react + boot + cron) |
| 3 | 2.3 streaming outbound (`http.fetch`) | **DONE 2026-05-21** |
| 4 | 2.4 streaming inbound body | design locked in `architecture/routing-and-ingress.md` §3; implementation pending |
| 5 | 2.5 held outbound subscription | **DONE 2026-05-24** |
| 6 | 2.6 durable scheduled wake | **PROPOSED 2026-06-01** — unbuilt; both forks resolved + interface/caps specced (§2.6.1); ready to build |

---

## 4. Out of scope (locked rejections — do not re-propose)

For completeness, these are NOT gaps; they're rejected primitives.
Don't fold them into proposals above.

- **Durable SSE replay log.** `PLAN.md` §7 / `architecture/effects-and-handlers.md`
  §10.1 / `architecture/effects-and-handlers.md` §10.3. Customer composes
  via own kv prefix.
- **Cross-tenant kv subscriptions.** Tenant boundary; route
  cross-tenant via `platform.scope(id).kv` or http.send.
- **Predicate-function kv-wakes.** Would run customer JS on the
  raft apply thread (`architecture/effects-and-handlers.md` §4.6).
- **Blocking inline external call.** PLAN line 79 Cmd bet
  preserved verbatim internally (`architecture/effects-and-handlers.md`
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
  per `architecture/effects-and-handlers.md` §8).
- The **strike posture** (resource-bound, deadline-bound,
  fail-fast on abuse — `connection_holder_security` /
  `architecture/effects-and-handlers.md` §9.2).

Any future proposal that violates one of these is by definition not
in this list; it's a §7/§10.1-style locked decision that has to be
relitigated explicitly.

---

## 6. Bounded tape per chain — **CONSIDERED AND REMOVED 2026-05-26**

The original framing was: streaming primitives can produce
unbounded per-`correlation_id` tape (LLM proxies, held outbound
subscriptions); without a per-chain byte budget those classes
either drown the replay store in cost or force "non-replayable"
carve-outs. The mechanism shipped briefly: a sharded
`NodeState.tape_state_shards` map (correlation_id →
`{bytes_used, capped, last_touch_seq}`), 10 MB default, sharded
16-way after a ~4× regression on 8w sharded writes when a single
global mutex was tried.

**Why removed.** Per-chain activation throughput is bounded by
sequential commit latency (~ms per activation, i.e. low hundreds
to ~1k activations/sec). Aggregate normal traffic across many
independent chains outpaces any single chain by 2–3 orders of
magnitude, so the dominant driver of replay-store cost is total
tenant volume, not pathological chains. The cap was solving a
narrow worst-case (one chain hours-long enough to accumulate
hundreds of thousands of small activations) at the price of a
node-wide map + mutex traffic on the dispatch hot path. The
benefit was real but small; the storage-cost lever lives one
level up.

**What replaces it.** Per-tenant retention / sampling
(originally specced as v2's `tape_mode` knob: `always` |
`on_exception` | `sampled` | `never`). That knob addresses the
actual cost driver — *total* tape stored per tenant — and
composes cleanly with a plan-level retention cap. It is **not
shipped yet** and is the right place to add cost control when
storage bills earn the optionality.

**What remains.** Content-addressed-large-bytes is still the
right pattern (`architecture/effects-and-handlers.md` §8): chunk bytes go to
blob, tape carries the hash. This was independent of the cap;
§7 below builds on it directly.

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

### 7.1 The LLM stream case — Tier 3, opt-in, not built

Proxying an LLM token stream is the worst Tier-3 case and the most
valuable at once. **Non-reproducible by re-execution** — re-calling
the API on replay costs money and returns different tokens (even
provider `seed` parameters are best-effort + void on model-version
change). For an LLM stream, the tape is the *only* path to faithful
replay. Without it the chain isn't expensive to replay, it's
unreplayable.

LLM-stream tape capture is an **opt-in, plausibly billed** primitive
when it ships — Tier 3 adds a CAS write to the streaming hot path,
a real cost the customer elects for replay fidelity available no
other way. Persist-before-observe at chunk grain; local hash + async
PUT keeps first-token latency intact. Pattern A also needs a
boundary-offset list since activation sequence depends on network
chunking; Pattern B is a single whole-body extent.

The retention coupling — a blob referenced by a live tape must be
pinned against GC — is the only new infrastructure obligation, and
`rove-files`'s `TenantFilesSnapshot` already does refcount-pinned
snapshots; this is a refcount edge, not new machinery.

**Status: design-only, unbuilt.** Trigger to ship: customer with
real LLM-stream replay demand. Tier 1 (zero-copy extents for
CAS-sourced `pipe_to`) is a cheap incidental that closes the
static-serve replay gap if anyone wants it. Tier 2 (Pattern A
against remote upstream, copy chunk to blob + tape the hash) needs
no new work — falls out of the per-chunk capture once Tier 3 ships.

### 7.2 ~~Customer-facing blob primitives~~ — canceled with effect-reification Phase 7

Originally specced as `blob.put` / `blob.get` JS shims giving customer
handlers direct access to the BlobBackend, with bytes-as-derivable-output
recovery via re-execution. Canceled 2026-05-27 alongside
effect-reification Phase 7 (files-server-standalone stays as a separate
binary, doesn't fold into JS-shim composition). No customer demand
established; defer until a concrete use case forces it.

**The input/output asymmetry the cancelation rests on still holds.** It's
the cross-cutting principle behind gap 2.4's design: inbound bytes are
recorded inputs (durable home, persist-before-observe); outbound bytes
are derived outputs (ephemeral, re-derivable from inputs).
Readset-replication's per-tenant buffer + callback-gate IS the inbound
primitive — gap 2.4 ships as "wire readset-replication into the inbound
path," not as a separate effect. See `effect-algebra.md` §2.5 for the
"inputs durable / outputs derivable" frame.

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

The principle the change rests on: replay re-runs the handler, so the
tape only needs inputs re-execution *cannot* reproduce. Writes (`.set` /
`.delete`) are outputs — re-issued by re-running. Own-reads (a `.get`
of a key in the same activation's writeset) read a value the activation
itself produced. What remains is the **minimal read set**: gets +
prefix scans resolving to state committed before the activation began,
plus date/random/crypto/module channels.

Divergence detection is preserved: a diverging write can only be the
symptom of a diverging read or bytecode mismatch — both caught by the
remaining input-channel coverage.

`kv.prefix` is unminimized in v1 (the merge of committed rows +
in-range overlay writes is fiddly). `KvOp.set` / `.delete` wire
variants stay readable for old tapes but stop being written.

---

## 9. Generative channels — record the seed, not the draws

§7.2 split taped inputs into *generative* (a seed the runtime
re-runs to recompute the input) and *referential* (a pointer
resolved against a store). `math_random` is generative — but only
if the PRNG is **bit-identical between the capture engine and the
replay engine**. That precondition is now met.

The principle: `Math.random` is a rove override drawing from a
rove-owned PRNG seeded per request. Record the **seed**, not the
draws — replay re-seeds identically and re-runs; every draw
reproduces bit-for-bit. Same argument as §8's writes: given pinned
bytecode and faithful other channels, control flow is identical, so
the PRNG is called the same number of times in the same order. The
unlock: the WASM replay engine runs rove's *own* JS host compiled to
WASM (arenajs + globals.zig overrides), so the same PRNG executes
on replay — value-recording's engine-drift safety isn't lost,
because both sides ship in lockstep.

Cross-version replay needs an engine/PRNG-version pin on the tape
header (sibling to `.module` source-hash). PRNG-algorithm change =
tape-format version bump.

`crypto.*` follows the same shape via the seed entry; secret-in-tape
exposure is unchanged from the prior value-recording (page-encryption
at rest remains the mitigation). `Date.now` is unaffected — a clock
read is genuinely external, not generative; stays value-recorded as
the `timestamp_ns` scalar.

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
| `date` | — (deleted) | pinned `timestamp_ns` scalar | timestamp | §9 fold-in ✅ |
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
the WASM build) — no per-draw entries, no host callouts.

§9 fold-in (same day): `date` was retired as a tape channel too.
`Date.now()` and `new Date()` (no args) are pinned per-request via
arenajs's new `JS_SetDateNow` API — every call within one request
returns `@divTrunc(readset.timestamp_ns, ns_per_ms)`. Same posture
as Cloudflare Workers / Lambda SnapStart. Replay pins via the WASM
reactor's `arena_set_date_now` export. The remaining wire
channels are `kv` + `module` + `fetch_responses` +
`trigger_payload` (4 channels, READSET_VERSION 4).

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
  extent (`architecture/effects-and-handlers.md` §8). Same input — the
  threshold picks the form. The four kinds are not disjoint;
  "extent" is what any oversized value-record becomes.

The activation's own triggering Msg is recorded the same way — a
direct value when small, an extent when large — so it is not a
fifth kind.

That is the whole tape. A minimal read set, timestamps, seeds,
and CAS extents are the entire non-deterministic frontier;
everything else a handler does — every write, every own-read,
every computed value — is recomputed on replay.
