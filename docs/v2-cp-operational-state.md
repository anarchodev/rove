# V2 — operational state in the CP, authored by an admin app (design)

> **Status: design (2026-06-05). Not built.** Establishes where per-tenant
> *operational* state (limits/plan, and the other admin-set axes) lives in V2,
> and who is allowed to mutate it. Supersedes the **storage** decision in
> [`plan-tiers.md`](plan-tiers.md) (which is V1-framed — `__root__.db`,
> envelope type `2`); the **enforcement** half of that doc is unchanged.
> Companions: [`v2-cp-directory-replication.md`](v2-cp-directory-replication.md)
> (the replicated directory this extends), `src/cp/directory.zig` (the
> interface), [`effect-algebra.md`](effect-algebra.md) (a CP write is a `Cmd`),
> [`project_v2_zero_downtime_move`] memory (CP = dedicated cluster/binary).

## The decision in one paragraph

Per-tenant **operational state** — request/body/retention limits today, and
the other admin-set, placement-independent axes (domain index, ACME certs)
later — lives in the **CP**, alongside placement, in the `__directory__` raft
group. The CP is the *source of truth*; it holds **what** the limits are and
has no opinion on **why**. The thing that *mutates* that state is a **normal
rewind.js admin app** pinned to a DP cluster — it holds the business logic
(Stripe webhook, "Pro costs $X," provisioning, upgrade/downgrade) and emits CP
writes through a narrow, capability-gated control API. This separates the
*source of truth* (CP, dumb, replicated) from the *authority that mutates it*
(an app, where business logic belongs) — a split V1's `root_writeset` path
conflated.

```
admin app (DP tenant)  ──control write──▶  CP (plan/{tenant})  ──push──▶  serving DP cluster ──▶ TenantSlot cache ──▶ enforce
   business logic            (a Cmd/effect)    source of truth     (attach + single-target push)   (plan-tiers.md, unchanged)
```

## Why the CP is the home

The criterion is **not** "it determines limits" (limits are *enforced* in the
DP, next to dispatch). It is the pair of properties that already put
**placement** in the CP directory:

1. **Admin-authored, never customer-writable.** Set by the product layer
   (Stripe → admin), exactly as placement is set by the move orchestrator.
   Customer handler `kv.*` must never reach it.
2. **Placement-independent.** This is the V2-specific one `plan-tiers.md`
   predates. A tenant **moves between clusters**; `__root__.db` is a
   *per-cluster* store. Tie the plan to it and every move must migrate the
   plan with the bundle, and you keep N per-cluster copies of state that is
   logically one-per-tenant. The CP is the one place that is both the single
   per-tenant control record and independent of which DP cluster serves the
   tenant.

Plan/limits shares placement's lifecycle exactly, so it shares placement's
home. Mechanically it's a sibling key prefix in the **same** `__directory__`
group — `plan/{tenant}` → `{tier, overrides}` JSON, beside `cluster/*` and
`placement/*`. `applyDirKv` already ignores unknown prefixes
forward-compatibly (`directory.zig:391`), so the existing
replay-and-projection machinery absorbs it with no new plumbing.

This is also the concrete V2 home for `plan-tiers.md`'s own assertion: *"rove
only enforces tiers… setting a tenant's tier lives in the product layer, not
in this codebase. rove never knows what a dollar is."* The admin-app-on-DP
**is** "the product layer."

## Why an admin app, not a control binary

The CP binary stays a replicated directory + control-write API with **zero
business logic** — a small, auditable CP trust boundary. All policy ("Pro
costs $X," when to upgrade, provisioning rules) lives in a **normal tenant
app**, deployed and iterated like any other — no infra redeploy to change what
"Pro" means. This dogfoods the spine the plan already commits to: the
admin/agent surface is a first-class client of the same tenant surface, and
"tenant" = installed app in the marketplace framing.

## The control-write seam (DP → CP)

The DP→CP write is the **same seam the front door already uses for moves**
(`/_control/move`, move-secret gated) — extended with a `plan` verb and a
different caller identity. No new channel.

From the admin app's point of view, "set acme's plan" is an **outbound
command**, the same category as `webhook.send` — so it slots into the effect
algebra as a `Cmd`, reified/durable like any other external effect. The app's
own `app.db` holds the idempotency/audit record ("upgraded acme at T"); the
*effect* is the CP write. No new durability story — it rides the one we have.

### The sharp edge: confused deputy

The admin app writes **other tenants'** control state — precisely the
privilege-escalation shape the connection-holder security model already
worries about ([`project_connection_holder_security`]). So:

- The CP control API authenticates the caller as the platform-admin identity
  (internal-secret / capability, **not** a customer-reachable route).
- It scopes what the caller may write: `plan/*`, provisioning, placement —
  never arbitrary CP keys. A customer app holds **no** CP-write capability by
  construction.
- Express it as a **capability grant**, not a hardcoded tenant id. Today
  exactly one tenant holds it; the self-host/marketplace direction wants
  delegated admin (a self-hoster managing sub-tenants' limits), and a grant
  future-proofs that without a runtime special-case.

## Delivery to the DP (enforcement stays local)

The enforcement half of `plan-tiers.md` is **unchanged**: resolve
`effective(tier, overrides)` once, cache the resolved `PlanLimits` on the
hot-path `TenantSlot`, dispatch reads `slot.plan.*` as a field load, a
plan-generation counter drives refresh. The only question is how the worker
**learns** its plan, since the worker reads the DP store, not the CP directory
(the front door reads the CP). Two paths, both reusing existing machinery:

- **Cold start / move:** the plan rides the **attach handshake**. The move
  path already ships a bundle and fans `attach` out to the destination's
  nodes — piggyback the resolved plan. The worker caches it at instance-open.
- **Live tier change (rare, billing-driven):** a CP write; the CP knows the
  tenant's current placement, so it pushes to the **one** serving cluster,
  which bumps the plan generation. One target, not a broadcast.

So plan propagation = placement propagation: the same lifecycle, the same
channel. The single counter-argument for keeping plan in `__root__.db` (it
sits in the store the worker already watches, so changes ride the existing
apply path for free) dissolves once you see that tier changes and moves are
both rare and both already touch this channel.

### Edge-enforcement bonus

Since the front door already reads the CP on every request, it can enforce
**body-size `413` at the edge** for free — rejecting doomed uploads before
they cross into a DP cluster. Keep rate (`429`) and the retention clamp in the
DP: rate wants the token-bucket state, and front-door HA fan-out gives the
same `N×` overshoot you'd get per-worker, so there's no accuracy win in moving
it.

## What belongs in the CP (the filter)

Admin-authored **and** not tied to a cluster's storage:

| State                          | CP? | Why |
|--------------------------------|-----|-----|
| placement                      | ✅ already there | the definition of CP |
| plan / limits                  | ✅ | admin-set, placement-independent, survives moves |
| domain → tenant index          | ✅ candidate | admin-set host routing; `directory.zig` flags it as "a separate axis (later)" |
| ACME `cert/{host}`             | ✅ candidate | placement-independent host state; today a `root_writeset` |
| `instance/{id}` provisioning   | ⚠️ maybe | admin-set, but creation is coupled to *where* the store is made — needs thought |
| customer `app.db` / KV         | ❌ | DP, customer-writable, moves with the bundle |

The clean statement: **the CP is the home for every per-tenant axis that is
admin-authored and not tied to a cluster's storage; the admin app is the sole
authority that authors them.** Plan/limits is the first such axis after
placement, not a special case.

## Bootstrap + availability

- **Bootstrap floor.** The admin app runs on a DP cluster the CP itself
  placed, so it can't provision its own existence. Keep the static seed
  (`seedClusters` / `seedPlacements`, `directory.zig:599`) as the bottom for
  *platform* infra; the admin app manages *customer* tenants on top.
- **Availability decoupling (the right shape).** Control **reads** (routing,
  cached limits) never depend on the admin app being up — only control
  **writes** (rare, off the hot path) do. If the admin app's cluster is down,
  every customer keeps serving at their current limits; you just can't change
  a plan until it's back.

## Build order (when this is picked up)

1. `plan/{tenant}` key in the `__directory__` group + projection field on the
   directory (sibling to `placement/*`); CP control API gains a `plan` verb
   (capability-gated, admin identity).
2. Delivery: thread the resolved plan into the attach handshake; single-target
   push on live change → DP plan-generation bump.
3. DP enforcement per `plan-tiers.md` (unchanged): `TenantSlot` cache, rate
   wire-up, `413` body gate, retention clamp.
4. The admin app itself (product layer): Stripe webhook → CP `plan` write,
   with `app.db` idempotency/audit.

Steps 1–2 are the new V2 work; step 3 is `plan-tiers.md` verbatim; step 4 is a
tenant app, not `rove` code.
