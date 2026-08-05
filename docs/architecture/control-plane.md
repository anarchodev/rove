# Control plane

> 🟢 **As-built reference.** The authoritative tenant directory, how it
> replicates, how a tenant moves between clusters, and where per-tenant
> operational state (plan/limits) lives. Owns `src/cp/` (`rewind-cp`) and the
> move surfaces in `src/front/main.zig` + `src/js/v2_move.zig`. For the data-
> plane mechanics a move drives (bundle/attach/epoch) see
> [`consensus-and-storage.md`](consensus-and-storage.md); for the routing that
> reads the directory see [`routing-and-ingress.md`](routing-and-ingress.md).
> Why: [decisions.md §10.1](../decisions.md) (CP/DP split), §10.6 (move), §10.5
> (faulted-not-lost).


## Operator control ops go through the `__admin__` chokepoint

Every `/_control/*` op is reachable two ways, and only one of them leaves a
trace:

- **Through `__admin__`** (the default for both the dashboard and
  `rewind-ops`): the handler issues a bound `after.fetch` at the
  `rewind-cp.internal` door, which the worker opens **only** for `__admin__` and
  where it attaches the move-secret itself. The operator shell therefore needs
  only `REWIND_ROOT_TOKEN`, and — because a handler ran — the action is an
  ordinary admin activation: logged, taped, digested, replayable.
- **Directly at the CP** (`rewind-ops --direct`): needs `REWIND_MOVE_SECRET` on
  the shell and runs no handler, so it produces **no record at all**.

The direct path is not merely discouraged, it is structurally required in two
cases, which is why it still exists:

1. **bootstrap / genesis** — the op being run *is* `provision __admin__`, so
   there is no admin app to route through yet;
2. **break-glass** — the admin app is down or mis-deployed and a tenant still
   has to be moved or deleted.

The chokepoint lives in the **deployed dashboard**, not the baked genesis app.
On a freshly-genesis'd cluster `rewind-ops` fails loud with the two ways forward
(deploy the dashboard, or `--direct`) rather than silently falling back — a
silent fallback would put the move-secret back on the shell and drop the record,
which is the whole thing this arrangement exists to prevent.

Authority at the door is `is_root`, **not** a session. The M2M root-token grant
is deliberately `{sub: null, is_root: true}`, so gating on `sub` rejects exactly
the operator this path serves.

## The shape in one paragraph

The control plane is a small dedicated raft cluster (`rewind-cp`, 3–5 voters)
holding one replicated `__directory__` group — the authoritative `Host →
cluster` placement plus per-tenant plan and cert state. The front door reads it
as a cached replica; it is **not** on the request hot path. A tenant move is a
synchronous orchestration whose **commit point is a single directory write**
(`placement/{tenant}` flipped to the destination): hold → quiesce+bundle the
source → attach the destination at a fresh epoch → flip → evict the source.

## Code map

| File | Role |
|---|---|
| `src/cp/directory.zig` | The `Directory`: `ClusterRef {id, nodes}`, `Placement {state: active\|moving, cluster}`, `Resolution {cluster, moving}`. Methods `assign` / `move` / `beginMove` / `abortMove` / `clusterFor` / `resolve`. Backed by the replicated `__directory__` store; an apply-observer rebuilds the in-memory projection on every node. |
| `src/cp/main.zig` | `rewind-cp`: hosts the directory's bridge; `handleMove` (the 5-step orchestration), `handleMoveLive` (Phase-7 variant); the `/_control/*` command surface and the `/_cp/route` · `/_cp/leader` · `/_cp/cert` read surface; `reconcileStuckMoves`. |
| `src/cp/acme.zig` | Leader-gated ACME issuance + `cert/{host}` replication (see `auth-and-domains.md`). |
| `src/front/main.zig` | The move orchestrator's caller + leader-aware proxy (routing-and-ingress). |
| `src/js/v2_move.zig` | The worker-side move surface (`REWIND_MOVE_SECRET`-gated): `v2-bundle` / `v2-attach` / `v2-evict` / `v2-resume` / `v2-kv`. |

## The directory & routing authority

- **One replicated `__directory__` group** on every CP node (gid =
  `hash("__directory__")`), pinned active so it never hibernates (a follower must
  re-elect on leader death).
- **Keys** (kvexp): `cluster/{id}` → node origins; `placement/{tenant}` →
  `{state}:{cluster}`; `plan/{tenant}` → opaque tier+overrides; `host/{host}` →
  tenant; `cert/{host}` → packed cert+key.
- **Hot-path reads are zero-alloc**: the in-memory projection (`clusters`,
  `placements`, `plans`, `hosts`, `certs`) is rebuilt by the apply-observer on
  every committed write, on leader and followers alike. `clusterFor(tenant)` and
  `resolve(tenant)` are map lookups; `ClusterRef.nodes` slices are pointer-stable
  past the directory lock.

## CP directory replication

- **Apply-observer projection**: `Node.apply_observer` fires on every node for
  every committed directory PUT, so a follower's projection stays current with no
  local proposer (the one place rove decodes a writeset twice — worth it only for
  the tiny directory writes).
- **Leader-gated seeding**: only the directory leader seeds static config at boot;
  followers fill by replication.
- **Write forwarding**: a `/_control/*` request that lands on a follower is
  forwarded to the leader (discovered via `/_cp/leader`), so an operator can
  target any CP node.
- **Crash reconcile**: `reconcileStuckMoves` (CP leader, periodic) aborts a
  tenant stuck `moving` and reverts it to active on the source.
- **Status**: single-node and multi-node HA (3–5 voters) shipped, proven by
  `scripts/smoke/cp_ha_smoke.py` (seed replicates, a follower-forwarded move commits,
  kill the leader → a survivor promotes and a fresh move commits on quorum).

## Tenant move orchestration

The atomic commit is `directory.move(tenant, dest)` — one replicated write
flipping `placement/{tenant}`. `rewind-cp`'s `handleMove` sequences it:

1. **Hold** — `beginMove(tenant)`: the router 503s the tenant's requests;
   placement is still the source (abort is a clean revert). `active → moving`.
2. **Quiesce + bundle (source)** — `POST src/_system/v2-bundle` (leader-gated):
   the worker refuses new proposes, drains in-flight to `applied == committed`,
   and dumps the tenant's committed kvexp state to a self-describing bundle.
3. **Attach (every destination node)** — `POST dest/_system/v2-attach` with the
   bundle (and the plan blob): each node loads it and `createGroupEpoch`s its
   incarnation at the migration epoch, so the group forms across the cluster. All
   must 204; any failure evicts the partial set and resumes the source.
4. **Flip (CP directory)** — `directory.move`: **the commit point**. Traffic
   resumes on the destination.
5. **Evict (source)** — `POST src/_system/v2-evict` (best-effort): destroy the
   group, reclaim its WAL, drop the instance. The move is already durable;
   eviction is cleanup.

A failure **before** step 4 → `abortMove` + `v2-resume` (a no-op move). **After**
step 4 it is durable. The destination is born at the migration epoch, which
fences stale messages to the old location. Blobs never move (shared backend).

## Tenant provisioning (new tenant, no move)

`POST /_control/provision {tenant, cluster, host?}` (`handleProvision`,
move-secret gated + CP-leader-forwarded) stands up a brand-new tenant in one
call: an **empty-attach** (`attachToAll(nodes, "", …)` — the move's attach step
minus the bundle) to every node of `cluster` forms the raft group across the
whole cluster and `ensureInstance`s the blank per-tenant store; await the
group's election; then `directory.assign` writes the placement (the routable
commit point) + optional `setHost`. Create-only (409 if already placed —
relocate via `/_control/move`); a formation failure evicts the half-formed
groups, so a failed provision is a no-op. No root/instance marker write is
needed — the CP directory (placement + host axis) plus the empty instance is
exactly the state a move-in destination ends with. Proven on a real 3-node
cluster: `scripts/smoke/cp_provision_smoke.py` (provision → group forms on all 3
nodes → a write commits + replicates everywhere → the front routes the host →
re-provision 409 / unknown-cluster 400).

## Operational state (plan / limits)

- **Lives in the CP directory** (`plan/{tenant}`), a sibling axis to placement —
  **not** in a per-cluster store and **not** known to the engine. This keeps
  plan/limits orthogonal to consensus.
- **Authority**: the admin app (an ordinary DP tenant holding a capability token)
  writes plans via the CP's capability-gated `/_control/plan`; accounts/orgs/
  billing are product-layer, above the CP (see
  [`platform-accounts-model.md`](../strategy/platform-accounts-model.md)).
- **Delivery**: a plan rides the `v2-attach` handshake at cold-start/move
  (`X-Rewind-Plan`); a live tier change is a single-target push to the tenant's
  current cluster (`POST /_system/v2-plan`, a plan-generation bump). Proven by
  `scripts/smoke/cp_plan_smoke.py` + `cp_plan_delivery_smoke.py`.
- **The tier model**: a tenant's plan is `{tier, overrides}` stored verbatim
  (dumb CP); the effective value of any limit is
  `override ?? TIER_TABLE[tier].field`, resolved at **read-time** — changing
  what "Pro" means never touches customer records, and per-field overrides
  cover enterprise custom deals without schema churn. The tier table is a
  comptime table in the shared **`rove-plan`** leaf (`src/plan/root.zig`,
  hoisted so the worker and the log-server import one table without a cycle).
  The resolved `PlanLimits` is cached on the tenant's `TenantSlot` with a
  **plan generation** counter, so dispatch reads a field, never a store (the
  no-`O(N_tenants)`-on-dispatch invariant).
- **Enforcement (DP-local, four levers, all off `slot.effectivePlan()`)**:
  - **Lever 1 — rate** (`src/js/limiter.zig`): per-`(instance, action)` token buckets
    sourced per-instance from the cached tier; **generation-refresh** re-inits
    a stale bucket's caps at `getOrCreate`, so a paying customer's raise lands
    instantly, no restart. Per-worker `N×` overshoot explicitly accepted at
    launch scale. The `email` action gives email-rate differentiation free.
  - **Lever 2 — body size**: an incremental `413` gate in the body path — fails when the
    accumulated length crosses `max_body_bytes`, and up front from a declared
    `content-length`; read fresh per request, so tier changes are immediate.
  - **Lever 3 — retention**: a **server-side read-path clamp** — the log/tape list +
    query surface returns only the last `retention_days` (`rove-log-server`
    resolves the plan from `{cp_url}/_cp/plan`, cached, and clamps
    list/show/count). Tapes persist on S3 unbounded; upgrade *reveals*,
    downgrade *hides, never deletes*. The clamp is a **billing boundary, not a
    UI nicety** — it must hold server-side, or a direct query bypasses it.
    Real compacting GC is deferred until the storage cost matters.
  - **Lever 4 — KV cap** (billing axis 1, `docs/strategy/pricing-model.md`):
    a **batch-level write-path gate** (`worker.zig kvCapRefusal`, run from
    `finalizeBatch` and the fire/stream propose) — when the scope tenant's
    conservative usage figure (durable LMDB pages + committed overlay, kvexp
    `storeUsage`, TTL-cached per store handle) exceeds `max_kv_bytes` and the
    batch's writeset contains a put, the txn rolls back before the propose and
    the response is replaced with a **non-retriable `507`** + a
    `kv_quota_exceeded` JSON body naming used/cap. Hard cap with
    throttle-to-upgrade semantics: never elastic billing, never eviction.
    Deliberate carve-outs: **reads untouched, delete-only writesets pass**
    (the recovery path out of over-cap is never blocked), admin batches
    exempt, and the check is batch-level — never a mid-handler throw — so a
    handler outcome stays a pure function of its taped reads (replay
    determinism). Fails open on lookup errors; the node-safety backstop is
    the shared env's `CLUSTER_MAP_SIZE` headroom, not this gate. Observability:
    `kv_store_used_bytes{instance}` / `kv_store_durable_entries{instance}`
    gauges, `kv_cap_refusals_total`, and `platform.instances.usage(name)` for
    the dashboard — all reading the same figure the gate enforces.

## The suspension axis — the reversible kill switch

The abuse response that is not `/_control/delete`: **`suspend/{tenant}`**, a
replicated directory axis whose *presence is the state* (value =
`{"reason","at_ms"}` JSON — who/why/when survives in the raft log).
Deliberately a **sibling axis to `plan/`, never a plan value**: a billing push
(Stripe → `/_control/plan`) can never silently un-suspend an abuse response,
and `/_control/unsuspend` is an axis delete that restores serving exactly —
data, placement, plan, deployment all untouched. The platform singletons
(`__admin__` et al.) refuse suspension.

Enforcement is layered so no serving path survives it:

- **Front door**: `/_cp/route` carries `"suspended":true` on the route (the
  tenant still *resolves* — that is what makes suspension reversible), and the
  front answers a cached, honest **403** — never the terminal 404 of a routing
  miss — for both HTTP flows and WS upgrades. Cached at the positive route
  TTL, so un-suspend propagates like a move.
- **Worker admission**: the dispatch walk 403s a suspended tenant's own
  handlers *before* the rate check. Keyed on the **handler** tenant, so an
  admin-handler request scoped to a suspended customer still works — the
  operator can inspect, export, and unsuspend; suspension must never become a
  data hostage.
- **Wake-driven paths**: `proposeForgetfulWrites` (fires / stream resumes /
  WS batches) drops a suspended tenant's writes before the propose, and
  `enqueuePendingFetches` — the single engine-bound funnel — drops its
  outbound fetches, so parked timers can't keep writing or spamming after the
  inbound door closes.

Delivery mirrors the plan push: `/_control/suspend` live-pushes
`/_system/v2-suspend {tenant, suspended}` to the serving cluster's slots, and
the reconciler **re-pushes every suspended tenant each pass** (O(suspended),
not O(tenants)) so a worker restart — which loses the in-memory flag —
re-learns the state within one reconcile interval. The directory row stays
the durable truth; `GET /_system/v2-suspend?tenant=` is the diagnostic
read-back.

## Abuse gates at the doors

Mechanisms behind the acceptable-use surface, each at the narrowest door that
cannot be bypassed:

- **Host claims** (`hostClaimViolation`, shared by `/_control/host` and
  provision's custom-host path — `Directory.setHost` stays the dumb
  primitive, the doors carry the policy): **first-claim-wins** across tenants
  (cross-tenant re-claim → 409; release is the delete path; operator
  `force` resolves disputes), and the **platform zone is identity-bound** —
  `{label}.{public_suffix}` is claimable only by the tenant named `label`
  (403 otherwise), so no tenant can aim a platform-looking or
  sibling-tenant-shaped host at itself on our own zone.
- **Log-byte ingest** (the ingest-rate guardrail,
  `docs/strategy/pricing-model.md`): a **lagging post-exec** `log_bytes`
  bucket denominated in raw bytes — `captureLogInner` charges
  `actual + k` per record (bodies and tapes included) unconditionally, the
  bucket may run negative, and the *next* admission pays with a 429 until
  the debt refills off. Uniform caps for now (the tier field comes with the
  plan-table reshape); `log_ingest_limited_total` counts refusals.
- **Sustained outbound** (the spam bound): a second, day-scale
  `outbound_sustained` bucket over the same frozen-native funnel as the
  burst bucket — capacity is a 10%-duty-cycle day of the plan's sustained
  rate, so the free tier's "10/s forever ≈ 864k/day" collapses to ~86k/day.
  Saturating it is an **incident signal, not a sales lead**: distinct error
  code (`outbound_sustained_limited`) + `outbound_sustained_trips_total`.
- **Creation velocity** (`/_control/provision`): one coarse CP-side token
  bucket (burst 10, ~2/min sustained) behind whatever identity the caller
  presents — ten tenants in a minute and ten in a year are different events,
  and each tenant costs a raft group ×3 nodes, an LMDB env, a placement and
  an S3 prefix. Refusals answer 429 + `cp_provision_limited_total`.
  Per-identity allowances (instances per account, accounts per identity)
  are the dashboard's plan-derived half.

## Zero-downtime move (the only move)

> **Convergence (raft-native-alignment):** the brief-pause move (quiesce +
> bundle dump described above) was **retired** — there is now ONE move, the
> zero-downtime one. `/_control/move` routes to it. The bundle transfer is
> **streamed** source→dest (Phase 2.5, `docs/architecture/raft-native-alignment.md`), not
> buffered through the CP. The brief-pause-specific machinery (`v2-bundle` /
> `v2-resume` / bridge quiesce, and the now-dead `moving`-hold +
> stuck-move reconciliation) is being removed; the section above is historical.

The zero-downtime move keeps the source online throughout:

- **Serve-or-forward** — a DP node that doesn't own a tenant asks the CP and
  forwards to the owner (the owner never re-forwards; loop-safe).
- **Dual-write forwarding** — the source stays online while the destination
  attaches; the source synchronously forwards every committed write to the
  destination, which catches up in real time.
- **Cutover** — the destination loads the snapshot insert-if-absent (never
  clobbering a forwarded write); because forwarding is synchronous it has every
  acked write, so the flip loses nothing. `handleMoveLive` orchestrates this.

Proven under load: `scripts/smoke/zero_downtime_load_smoke.py` moves a tenant under
**continuous load** (a CP-following concurrent writer) with zero failed
requests and zero lost writes; `multi_dest_forward_smoke.py` proves the
`_move/forward` marker's full dest-node list (leader-first CSV) re-aims the
dual-write past a 421 when the destination leader changes mid-overlap. A write
in flight at the instant of a leader change is still faulted + retried, not
lost (decisions.md §10.5).

## Known limitations (as-built)

- **Move orchestration is synchronous** on the CP (one move at a time); parallel
  per-tenant moves are deferred.
- **DP-side directory cache** (Slice 3) is optional and not built — the per-miss
  CP query is sufficient today.
- **ACME renewal** (timer-driven, expiry-aware reissue) is the tracked follow-up
  in `auth-and-domains.md` (leader-elected issuance itself is shipped).
- **Plan-enforcement test follow-ups** (non-blocking; the deployed-handler e2e
  and 429 halves are closed by `scripts/smoke/ctl_smoke_v2.py` +
  `rate_limit_smoke_v2.py`): a `413` body-gate e2e smoke, and wiring the smoke
  topology's log-server `cp_url` so the retention clamp is exercised
  end-to-end.
