# Plan tiers — build plan

> **V2 storage note.** The **storage** decisions below are V1-framed
> (`__root__.db`, `root_writeset` envelope type `2`). For V2 the tier/limits
> source of truth moves to the **CP directory**, authored by an admin app —
> see [`v2-cp-operational-state.md`](v2-cp-operational-state.md). The
> **enforcement** half of this doc (levers 1–3, the `TenantSlot` cache, plan
> generation) is unchanged by that move.

**Design home:** this doc. Surface anchors: rate limiter
`src/js/limiter.zig` (already tier-shaped — see its header comment),
tenant metadata `src/tenant/root.zig` (`Instance`, `resolveDomain`),
deployment hot-path cache `src/js/deployment_cache.zig` (`TenantSlot`),
inbound body path `src/h2/root.zig` (`ReqBody` / `bodyAppend`), retention
`docs/logs-plan.md` §6.8, rate-limiter primitive `docs/PLAN.md` §2.10.

**Goal.** Let paying customers buy bigger numbers on three axes —
**request rate**, **max body size**, **tape retention window** — without
building a billing system into `rove`. Everything keys off one new piece
of per-tenant control-plane state (the *tier*); the three levers are then
a one-line wire-up, one new gate, and one read-path clamp respectively.

`rove` only *enforces* tiers. Setting a tenant's tier (Stripe webhook →
admin → `root_writeset`) lives in the **product layer** (a rewind.js admin
handler), not in this codebase. `rove` never knows what a dollar is.

## The shape in one paragraph

A tenant's tier is `{tier: enum, overrides: {...}}` stored in
`__root__.db` (control plane, admin-set via `root_writeset` — envelope
type `2`), **not** in the customer-writable `app.db`. The effective value
of any limit is `override ?? TIER_TABLE[tier].field` — named tiers are a
table baked in code, per-tenant overrides cover enterprise custom deals
without schema churn, and resolving at read-time (not set-time) means
changing what "Pro" means never requires touching every customer record.
The resolved limits are cached on the tenant's hot-path slot so the
dispatch path pays zero extra store reads (the
no-`O(N_tenants)`-on-dispatch invariant).

## Foundation — tier plumbing (the only genuinely new state)

This is the prerequisite for all three levers; build it first.

- **Storage.** New key in `__root__.db`: `plan/{instance_id}` →
  `{tier, overrides}` JSON, written only via `root_writeset` (envelope
  type `2`, admin plane — same path as `instance/{id}` markers and ACME
  `cert/{host}`). Absent key ⇒ the `free` tier. Customer handler `kv.*`
  can never reach `__root__.db`, so tier is tamper-proof from inside the
  worker by construction.

- **Tier table (baked).** A comptime table in a new `src/js/plan.zig`:

  ```
  pub const Tier = enum(u8) { free, pro, enterprise };

  pub const PlanLimits = struct {
      rate: limiter.RateLimitCaps,   // reuses the existing caps struct
      max_body_bytes: u32,
      retention_days: u32,
  };

  pub fn table(t: Tier) PlanLimits { ... }   // free/pro/enterprise rows
  ```

  `overrides` is a sparse version of `PlanLimits` (all-optional fields);
  `effective(tier, overrides)` folds `override ?? table(tier).field`
  per field. Keep the *table* in code; keep *overrides* in `root.db`.

- **Hot-path cache.** Resolve `effective(...)` once at instance-open
  (the same moment `resolveDomain` lazily opens the `Instance` and reads
  its `instance/{id}` marker — `src/tenant/root.zig:391`) and stash the
  resolved `PlanLimits` on the `Instance` (or the `TenantSlot` in
  `deployment_cache.zig:426`, whichever the dispatch path reaches first).
  Add a **plan generation** counter alongside it (see staleness, below).
  Dispatch reads `slot.plan.*` — a field load, no store hit.

- **Refresh on tier change.** When a `root_writeset` carrying a
  `plan/{id}` change applies, bump that instance's plan generation so the
  next request re-resolves `effective(...)`. Body-size and retention read
  the cached `PlanLimits` fresh each request, so they pick up the change
  immediately. Rate is the one exception — see below.

## Lever 1 — request rate (already built; one wire-up)

`src/js/limiter.zig` is a complete per-`(instance, action)` token-bucket
limiter: per-worker, lazily-created buckets, `429` + `Retry-After`
(`retryAfterSeconds`), per-worker `N×` overshoot explicitly accepted at
launch scale. Its header already names this work: *"Single plan tier in
v1 — `defaultCaps()` returns the same numbers for every instance. Phase 10
will branch on the instance's plan."* Free customers are therefore
**already** throttled at a sane global default (request `1000` burst /
`500·s⁻¹`); "raise it for payers" is purely feeding bigger caps in.

- **The swap point.** Today every instance's buckets are built from the
  one shared `RateLimiter.caps` (`defaultCaps()`, `limiter.zig:50`) inside
  `getOrCreate` (`limiter.zig:196`). The entire tier change is: source
  `RateLimitCaps` **per-instance from the cached tier** at bucket-creation
  time instead of from `self.caps`. Pass the instance's resolved
  `plan.rate` into the `check`/`checkN` call (the dispatch path already
  holds the cached slot), and have `getOrCreate` use it for first-time
  bucket init.

- **Snapshot-staleness — the one real decision here.** Buckets are
  created once per instance and never evicted, so a bucket snapshots its
  caps at creation. A tier change won't take effect until the bucket is
  recreated (worker restart) unless we act. Two options:

  - **(a) Generation-refresh (recommended).** Store the plan generation
    on the `InstanceBuckets`; when `getOrCreate` finds an existing entry
    whose generation is stale, re-init its caps (preserving current token
    counts, or resetting — reset is simpler and harmless). Small, bounded
    code. Matters because the painful direction is a *paying* customer not
    getting their higher limit until restart — that must be instant.
  - **(b) Stale-until-restart (zero code).** Accept that limit changes
    land on next worker cycle. Rejected as the default: bad UX precisely
    for the customers who just paid.

  Resolve toward (a). It's the only non-trivial code in the rate lever.

- **Free second lever.** The limiter already has an `email` action
  (`email.send` budget). Tiers get email-rate differentiation for free by
  putting `email` caps in `PlanLimits.rate`. The `Action` enum is also the
  extension point for the deferred `deploy` / `kv_write` /
  `webhook_attempt` budgets (PLAN §2.10 / §1189) if ever wanted.

## Lever 2 — max body size (the one genuinely new gate)

The limiter counts requests and emails, not bytes — body size is a
separate, new gate. Today inbound body size is capped only *implicitly* at
`u32`/4 GB because `ReqBody.len` is a `u32` (`src/h2/root.zig:51`), with
`bodyAppend` (`:258`) growing on demand and no explicit ceiling. That's a
DoS vector worth closing regardless of tiers.

- **The gate.** Reject with `413 Payload Too Large` keyed off
  `EFFECTIVE(max_body_bytes)`, **before** buffering the whole body —
  enforce incrementally in `bodyAppend` (fail once accumulated `len`
  crosses the cap) and, when a `content-length` header is present, fail
  the request up front before reading any DATA frames. The cap is read
  fresh from the cached `PlanLimits` per request, so tier changes are
  immediate with no extra machinery.

- **Default.** `free` gets a generous-but-finite cap (e.g. a few MB);
  paid tiers raise it. Pick the free number against the streaming
  `QUEUE_BYTES_CAP` (256 KB, `components.zig`) so the two back-pressure
  ceilings are coherent.

## Lever 3 — tape retention (read-path window clamp; no GC at launch)

Full compacting GC is specced in `logs-plan.md` §6.8 but **unbuilt**.
We do **not** build it for launch. Instead we *fake* retention as a
read-path clamp: tapes/logs physically persist on S3 unbounded, but the
list/query surface only returns the last `EFFECTIVE(retention_days)`.

- **The clamp.** Every tape/log **list and query handler** filters to
  `received_ns >= now − retention_days`. This is the whole feature.

- **The one correctness rule.** The clamp is a **billing boundary, not a
  UI nicety** — it must be enforced server-side in the query/list handler.
  If only the replay UI hides old tapes, a customer queries the older
  window directly and bypasses it. No client-side-only filtering.

- **Why faking it is strictly better short-term.** Up/downgrade become
  instant and reversible: upgrade immediately *reveals* older tapes that
  were always on S3 (a clean demo); downgrade *hides, never deletes*, so
  re-upgrade restores them. This sidesteps the "downgrade retroactively
  deletes data" hazard that real GC-based retention carries. The only cost
  is unbounded S3 storage until GC ships — an operator cost we explicitly
  accept at launch scale.

## Launch cut vs. later

**Launch:**

1. Tier plumbing (foundation) — `plan/{id}` in `root.db`, baked tier
   table, resolved-and-cached `PlanLimits` on the slot, plan generation.
2. Rate — wire `getOrCreate` to per-instance caps; generation-refresh.
3. Body size — incremental `413` gate off `max_body_bytes`.
4. Retention — server-side list/query clamp off `retention_days`.

**Later:**

- Real retention GC (`logs-plan.md` §6.8) to reclaim S3 storage once the
  faked window's storage cost matters.
- Define the concrete `pro` / `enterprise` rows + the billing-webhook →
  admin → `root_writeset` flow (product layer).
- Tier the deferred limiter actions (`deploy` / `kv_write` /
  `webhook_attempt`) only on real demand.

## Open decisions

- **Rate snapshot-staleness:** generation-refresh (a) vs.
  stale-until-restart (b). Plan recommends (a).
- **Free-tier numbers:** the actual `max_body_bytes`, `retention_days`,
  and whether `free` keeps today's `500·s⁻¹` request rate or a different
  figure. Needs a product call, not an engineering one.
- **Overrides granularity:** per-field overrides (flexible, recommended)
  vs. whole-`PlanLimits` override (simpler). Per-field chosen above.
