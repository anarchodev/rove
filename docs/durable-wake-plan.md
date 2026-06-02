# Durable scheduled wake — build plan

**Design home:** `primitive-gaps.md` §2.6 (the gap + both resolved forks)
and §2.6.1 (interface + caps). Effect-model anchor: `effect-algebra.md`
§2.2 (L2 reconstruct-vs-abandon — this generalizes the one place
reconstruction is hardcoded) and §2.3 (Msg origins — the open family this
adds to). Read those first; this doc is only the build order.

**Goal.** Turn webhook's privileged `_send/owed/` boot-scan into a
primitive: a one-shot, absolute-time, at-least-once **firing** durable
wake, fronted by one canonical JS `scheduler` lib, with cron / webhook /
email / retry re-platformed on top. Net effect: delete the per-feature Zig
sweeps; durable cron becomes possible; one generic privileged JS lib
replaces N feature-specific sweeps.

## Status

**P0–P4 SHIPPED (compiles, `zig build test` green; runtime smokes are
P6, not yet run).** The primitive is usable end-to-end: a customer
handler can `scheduler.at(...)` / `after` / `cancel` / `get`, and due
wakes fire their `target` as a `durable_wake` activation. **P5
(re-platform webhook/cron onto `scheduler`, delete the per-feature Zig
sweeps) and P6/P7 (smokes + cleanup) are NOT done** — the owed +
cron sweeps still run in parallel, untouched.

Where the P0–P4 code lives:
- `durable_wake` activation kind + `DurableWake` Msg: `src/log/root.zig`,
  `src/js/effect/msg.zig`, `src/js/effect/queue.zig`,
  `src/log_server/flush_writer.zig`, JS surface in `src/js/globals.zig`.
- Engine watermark: `TenantSlot.next_wake_ns` (atomic) +
  `lowerWake`/`setWakeTrampoline` in `src/js/deployment_cache.zig`.
- Builtins `__rove_set_wake` / `__rove_fire_wake`:
  `src/js/bindings/scheduler.zig` (+ `GLOBAL_BUILTINS` /
  `builtin_exceptions` in `globals.zig`); trampolines on `Request`/
  `DispatchState`; `fireWakeTrampoline` on the worker.
- Sweep + promotion + P2 bootstrap: `src/js/durable_wake.zig`
  (`sweepDurableWakes`, `sweepDurableWakesOnPromotion`,
  `noteCommittedSchedWrites`), wired in `src/loop46/main.zig` and the
  `worker_drain.zig` commit arm.
- Fire paths: `fireSchedulerTick` + `fireDurableWakeActivation` +
  the `.durable_wake` drain arm in `src/js/worker_streaming.zig`.
- Baked `__system/scheduler_tick.mjs` + public `globals/scheduler.js`
  (registered in `builtin_modules.zig` / `globals.zig` / `build.zig`).

Two design points settled during the build (differ slightly from the
sketch below):
- **Fan-out via a second capability-scoped builtin** `__rove_fire_wake`
  (not a `scheduler_tick` return value) — keeps the dispatch uniform
  with `__rove_stream`'s emit posture. So the engine surface is two
  builtins, not one.
- **P2 bootstrap is a direct watermark-lower in the commit arm**, not a
  kv-react→`scheduler_tick` fire. `noteCommittedSchedWrites` reads the
  committed `kv_wake_broadcast` Cmds (same post-commit chokepoint
  kv-react uses) and `lowerWake`s `next_wake_ns` from committed state.
  Equivalent commit-gated guarantee, no implicit baked subscription.
- **`scheduler_tick` watermark = `now` whenever it fired ≥1 entry** (the
  owed-sweep "re-fire while work remains" model), so a target that
  throws — rolling back its own cleanup-delete — is retried on the next
  sweep instead of stranded until the next promotion.

## Phases

Land-inert-first (mirrors `effect-reification-plan.md` Phase 5 PR-3 step 1:
the owed sweep shipped inert as a safety net before the atomic flip).

- **P0 — engine primitive (inert).** `__rove_set_wake(when_ns)` global
  builtin, **capability-scoped to `is_system_module`** (same posture as the
  `__rove_*` builtins that survive `_harden.js`). Per-tenant `next_wake_ns`
  on the tenant slot, held in a per-worker-partitioned min-structure
  (`hash(tenant) % n_inboxes`, matching the owed-sweep routing) so the tick
  is O(tenants-due). 1 Hz tick fires `__system/scheduler_tick` in the
  owning tenant's context when due; a leadership-gain pass fires it once
  per partitioned tenant (generalizes `sweepOwedRetriesOnPromotion`).
  Lands inert — no `_sched/` writers exist yet, so `scheduler_tick` finds
  an empty prefix and sets no wake.

- **P1 — baked `__system/scheduler_tick`.** Range-scan `_sched/by_time`
  from the front for due entries (≤ `SCHED_MAX_FIRES_PER_TICK`), dispatch
  each `target`, **delete the fired entry's two keys in the same writeset
  as the dispatched activation's effects**, recompute the min, call
  `__rove_set_wake(new_min)`. Register in `builtin_modules.zig` `MODULES`
  + `build.zig` `js_runtime_files` (sibling of `webhook_onresult`).

- **P2 — commit-gated bootstrap (the race fix).** A freshly-scheduled
  wake's `next_wake_ns` must be set from **committed** state, never from
  the handler that called `at()` (its `_sched` write is uncommitted at
  return — this is exactly the marker-commit race of
  `effect-reification-plan.md` Phase 4.1 / durability-as-JS-shim bug #5).
  Mechanism: a **kv-react** subscription (Gap 2.1) on the `_sched/by_time/`
  prefix fires `scheduler_tick` post-commit on the committing leader
  worker, which reads the now-committed entry and sets the wake. No
  volatile set-on-call. Debounce (coalesce bursts) is an optimization, not
  required for correctness.

- **P3 — public `globals/scheduler.js`.** `at` / `after` / `cancel` /
  `get` per §2.6.1. `id = base64url(sha256(key))` when `opts.key` given,
  else `crypto.randomUUID()`. Writes `_sched/by_id/{id}` +
  `_sched/by_time/{when_ns_padded}/{id}`. Round `whenNs` up to the next
  tick. Documented shim (JSDoc-extracted per the globals/_system split).

- **P4 — caps, fail-loud.** `SCHED_MAX_OUTSTANDING` (count check in `at()`,
  throws past it), `SCHED_MAX_FIRES_PER_TICK` (in `scheduler_tick`),
  `SCHED_MAX_MSG_BYTES` (in `at()`), tick rounding. All loud
  (`feedback_fail_loud_resource_exhaustion`), operator-tunable. Cap smokes
  in P6.

- **P5 — re-platform features (atomic flip, one feature at a time).**
  - **(a) webhook.send / email.send.** `webhook.send` →
    `scheduler.at(fire_at, "__system/webhook_onresult", {...})`; retry
    re-arm = `scheduler.at` with the same `key`. Delete `sweepOwedRetries`
    + `sweepOwedRetriesOnPromotion` + the `OWED_PREFIX` special handling.
    `_send/owed/` becomes ordinary library kv (already is post-`b908953`;
    now also loses the privileged sweep).
  - **(b) cron.** Durable cron = a `scheduler.after` that re-arms itself
    each fire. Delete the `CronState` collection + `sweepCronSubscriptions`
    (the non-durable in-memory clock retires). **Cron now survives leader
    switch** — the §2.1 "missed-tick tolerance" caveat goes away for
    customers who want durability.

- **P6 — smokes.** `durable_wake_smoke` (schedule + fire); failover-
  survival (schedule, kill leader, assert fire on the new leader — the
  property that motivated the gap); cap smokes (outstanding + fires-per-
  tick); webhook-on-scheduler + cron-on-scheduler regression against the
  existing webhook/cron smokes.

- **P7 — cleanup + docs.** Delete the dead sweeps / `CronState` /
  `OWED_PREFIX` branches. Update CLAUDE.md (the §"Request lifecycle" +
  durability tables) and PLAN.md §13 process map: the per-feature sweeps
  are gone, replaced by the scheduler tick + `scheduler_tick` baked module.

## Key risks (and where they're handled)

- **Marker-commit race** → P2 (kv-react bootstrap; the Phase-4.1 lesson).
  This is the single highest-risk detail — get it wrong and a scheduled
  wake silently never fires until the next reconstruction.
- **O(N_tenants) on the tick** → P0 partitioned min-structure; tick is
  O(tenants-due). Boot reconstruction is O(tenants) once on promotion
  (acceptable — equals today's promotion sweep cost).
- **Replay / determinism** → the `durable_wake` Msg is a taped input (L3);
  `scheduled_at_ns` recorded; the WASM replay host needs a `durable_wake`
  activation kind. `id` is deterministic (sha256(key)) or rides the
  seeded PRNG (`randomUUID`, already taped per primitive-gaps §9/§10).
- **Recovery scan cost** → bounded by `SCHED_MAX_OUTSTANDING`; paged/lazy
  recovery is the lever beyond 10k (`project_owed_recovery_strategy`).

## Not in this plan

- The opt-in **scheduler override** seam (bring-your-own under
  `scheduler`) — deferred until a customer asks (§2.6).
- **Many-timer engine index** — explicitly rejected; the queue lives in
  the `scheduler` JS lib, the engine keeps one next-fire per tenant.
