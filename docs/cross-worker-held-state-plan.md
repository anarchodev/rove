# Cross-worker held state — routing async wakes to the owning worker

> **Status:** Plan (2026-05-27). Not yet built. Motivated by the
> `http.fetch({bind: true})` refit landing in multi-worker production
> with a latent correctness gap (Gap #2 from the bind:true follow-up
> list); same gap covers `webhook.send` held-sync.

## 1. The mismatch

Two routing layers don't align:

- **Inbound HTTP**: `SO_REUSEPORT`. Kernel hashes by `(src_ip,
  src_port, dst_ip, dst_port)`. No tenant awareness. PLAN §13.1
  line 1702: *"All bind the same h2 listen port via SO_REUSEPORT.
  Any worker handles any tenant — there is no tenant pinning."*
  Whichever worker accepts handles the request; tenant is
  resolved post-accept from `:authority` (`worker_dispatch.zig`
  `resolveDomain`).
- **Async wake events** (`enqueueMsgForTenant` at `worker.zig:1468`):
  `std.hash.Wyhash.hash(0, tenant_id) % N_workers`. Deterministic
  worker per tenant.
- **Held state** (`parked_continuations`, `bound_fetch_entities`,
  the cont desc + chain ctx components): lives on whatever worker
  accepted the inbound. Per-worker collections, NO cross-worker
  visibility.

Concretely: inbound for tenant T lands on worker A (kernel pick);
handler registers held state on A; async event for T (a fetch
chunk, a webhook callback, a kv-react wake) routes via
`hash(T) % N → worker B`; if `A != B`, B's scan/lookup misses.
The held client sits parked until the §6.4 25s deadline → 504.
The customer never saw a useful response.

**Affected primitives**:

- `webhook.send` + `next()` held-sync resume.
  `resumeIfBoundTrampoline` (`worker.zig:2925`) scans the
  receiving worker's `parked_continuations` only.
- `http.fetch({bind: true})` + `onFetchChunk` resume.
  `lookupBoundFetch` only sees this worker's map.
- Any future held-state primitive that follows the same shape.

**Why hasn't it bitten?** Every relevant smoke pins
`workers_per_node=1`. The penalty smoke comment gives it away:
*"penalty-box is per-worker; SO_REUSEPORT spread dilutes."* With
`N=1`, `hash % 1 == 0` always picks that worker, so the
cross-worker case never triggers.

User confirmed (2026-05-27) multi-worker WILL be production. So
this needs fixing.

## 2. Resolution direction

Two architectural shapes:

### 2.1 Continuation-affinity routing (recommended)

Route async wake events to the worker that holds the matching
held state, via a NodeState-level registry consulted at routing
time. Inbound stays SO_REUSEPORT — no change to the accept path.

The pattern that already exists in `project_callback_execution_model`
as the target model: stamp a locator `(worker_idx, slot, gen)` on
the originating effect; consult it when routing the wake; if the
held state has moved or is gone, fall back gracefully (deadline
catches it, same as today).

For `http.fetch({bind: true})`:

- At binding time, `registerBoundFetchTrampoline` already records
  `fetch_id → entity` on a worker-local map. Mirror it at the
  NodeState level: `bound_fetch_owners: HashMap(fetch_id,
  worker_idx)`. The owner worker is `worker.msg_inbox_idx` (the
  registering worker's slot).
- `FetchEngine.routeEvent` (currently
  `enqueueFetchEventForTenant(tenant_id, ev)` → hash by tenant)
  becomes: if `bound_fetch_owners[fetch_id]` exists, push to that
  specific worker's inbox; else fall back to `hash(tenant_id)`
  (Pattern A unbound path).
- On final chunk (or held-client disconnect), remove the
  NodeState entry alongside the worker-local one.

For `webhook.send` held-sync:

- Same shape. `webhook.send.js` (or the kv envelope-0 apply of
  `_send/owed/{send_id}`) registers `send_id → worker_idx` in a
  `bound_send_owners` map at NodeState. The
  `__system/webhook_onresult` dispatch consults the map; if
  present, route the resume directly; if absent, fall back to
  today's per-worker scan (covers the recovery path where the
  registering worker died and the entity is gone).
- This subsumes the current `resumeIfBoundTrampoline` scan in the
  common case — the receiving worker doesn't need to scan its own
  collections looking for `bound_schedule_id == send_id`; the
  registry tells it directly whether it owns the cont.

**What's NOT in scope:** subscription fires (cron / kv-react /
boot) keep `hash(tenant_id)` routing — these have no held state;
the routing is just for tenant lock-locality. Inbound HTTP keeps
SO_REUSEPORT.

**Cross-node:** out of scope for this plan. The locator stays
`(worker_idx, slot, gen)` within the current node. If multi-node
holding lands later, extend to `(node_idx, worker_idx, slot, gen)`
with cross-node routing via the existing inter-node message path.
Today held state is always single-node by construction (the
holding entity lives in one process's rove registry).

### 2.2 Tenant-affinity inbound routing (rejected, recorded for completeness)

The `tenant-affinity` branch (see `[[project_tenant_affinity_branch]]`)
tried this: kernel-misrouted inbound forwards to `hash(tenant_id)`
worker via a cross-worker request inbox. Phases 1–5 shipped on a
branch; phase-6 measurements showed `-9%` (1 tenant) to `-33%`
(256 tenants) vs SO_REUSEPORT baseline. Rejected on perf grounds
2026-05-11 — the per-cross-worker-hop overhead (~50µs) was bigger
than the WAL shm contention savings at realistic tenant counts.

The cross-worker-held-state gap was NOT in the cost calculation
at the time (the smokes use `workers_per_node=1` so the gap was
invisible). Re-running the measurement with this gap in scope is
possible, but a focused continuation-affinity fix (§2.1) is
narrower than restructuring all inbound routing. Defer §2.2
unless §2.1 turns out insufficient.

## 3. Implementation phases

### Phase 1 — NodeState-level held-state registries

- Add `NodeState.bound_fetch_owners: StringHashMapUnmanaged(WorkerIdx)`
  (key = fetch_id, value = worker_idx that holds the entity).
  Mutex-guarded, same shape as `msg_inboxes`.
- Add `NodeState.bound_send_owners: StringHashMapUnmanaged(WorkerIdx)`
  (key = send_id, value = worker_idx that holds the cont).
- Register from the existing trampolines:
  - `registerBoundFetchTrampoline` writes both worker-local AND
    NodeState entries.
  - The `webhook.send` `_send/owed/{id}` write site adds a
    NodeState `bound_send_owners` entry stamped with the issuing
    worker's idx.
- Unregister on terminal-chunk / disconnect / cont resume completes.

### Phase 2 — Route async wakes via the registries

- `enqueueFetchEventForTenant`: if `ev.bind == true` AND
  `bound_fetch_owners[ev.fetch_id]` is present, push to that
  worker's inbox directly instead of `hash(tenant_id)`.
- The `__system/webhook_onresult` shim (or whatever fires the
  webhook callback) routes via `bound_send_owners[send_id]`
  when present.
- Unbound fetches + subscription fires + cron + kv-react keep
  `hash(tenant_id)` routing.

### Phase 3 — Drop the per-worker scans

- `resumeIfBoundTrampoline` (`worker.zig:2925`) becomes a
  consultation of the worker's local `bound_fetch_entities` only
  (the routing guarantees we're on the right worker). Same for
  `resumeBoundContinuation`'s scan in `worker_drain.zig:1261`.
- The scans stay as a safety-net fallback for the case where the
  NodeState registry entry was lost (registering worker died
  before unregistering, etc.) — log + accept the deadline.

### Phase 4 — Tests

- Multi-worker smoke variant: `bound_fetch_multiworker_smoke.py`
  with `workers_per_node=4`. Hammers `/boundproxy` with N
  concurrent requests; asserts every chain gets its chunks
  (no §6.4 deadline 504s).
- Same shape for `heldsync_multiworker_smoke.py`.
- The existing single-worker smokes stay green (the registry
  fast-path subsumes them).

## 4. Known gotchas

- **Worker death.** If worker A holds a cont and dies, the
  NodeState entry points at a dead worker. Routing pushes the
  wake to A's inbox; A is gone; the wake never fires. Today's
  same behavior — §6.4 deadline catches it, customer gets 504.
  The registry doesn't make it worse; doesn't fix it either
  (recovery is a separate concern, covered by the
  `_send/owed/` rebuild path on next tenant activity, see
  `[[project_owed_recovery_strategy]]`).
- **Inbox saturation.** The owner worker's inbox could be full
  when a wake arrives. Same behavior as today (overflow → drop +
  count). No new failure mode.
- **Concurrent register/unregister.** The registry mutex is held
  briefly. The unregister-on-terminal path runs on the owning
  worker AFTER the wake fires — no race with concurrent
  registration of the same id (id is unique per outbound
  effect).
- **Locator staleness across reg.move.** Per rove-library
  principle 8, entity handles survive collection moves. The
  registry holds `worker_idx`, NOT `Entity` directly — the
  Entity lookup happens on the owner worker in its own
  collections.
- **`hash(tenant_id)` still useful as fallback.** Subscription
  fires and unbound activations keep the existing routing. The
  registry only intercepts the held-state cases.

## 5. Out of scope

- Multi-node held state. The `(worker_idx)` locator is
  single-node. If multi-node held state lands, extend to
  `(node_idx, worker_idx)` with the existing inter-node bridge.
- Tenant-affinity inbound routing (§2.2). Rejected, recorded.
- The §6.4 mandatory deadline. Stays as the universal safety net.
- Recovery semantics on registering-worker death. Covered by
  `_send/owed/` rebuild on next tenant activity
  (`[[project_owed_recovery_strategy]]`); same for bound fetches
  (the fetch dies with the worker, no recovery needed —
  `http.fetch` is best-effort transient per
  `docs/effect-algebra.md`).

## 6. Verification

End-to-end:

- `bound_fetch_multiworker_smoke.py` — 4 workers, 16 concurrent
  bind-fetches, assert no §6.4 deadlines, every chain delivers
  its chunks. Run with `--seed-jitter` so SO_REUSEPORT spreads
  connections; verify by log that some chains land on `A != hash(T)`
  workers.
- `heldsync_multiworker_smoke.py` — same shape for `webhook.send`
  + `next()`.

Existing smokes:

- All single-worker smokes stay green (registry fast-path is
  strictly more general than the worker-local lookup).
- `scripts/penalty_smoke.py` etc. can drop the
  `workers_per_node=1` constraint where it was only there to
  hide this gap (penalty-box itself is unaffected; the comment
  conflated two issues).

## 7. Relation to other plans

- `[[project_callback_execution_model]]` — describes the target
  execution model (continuation-affinity, stamped locator). This
  plan is the concrete implementation path for the bind:true +
  webhook.send slice of that model. Doesn't change the design;
  builds the routing infrastructure it assumes.
- `[[project_tenant_affinity_branch]]` — rejected alternative.
  Recorded in §2.2.
- `docs/connection-actor-plan.md` §6.2 — the connection-actor
  model assumes wakes route to the held entity. This plan makes
  that routing real.
- `docs/handler-shape.md` §5.4 (webhook.send + resume) + §5.5
  (LLM proxy) — the worked examples that don't currently work
  in multi-worker production. After this plan, they do.
