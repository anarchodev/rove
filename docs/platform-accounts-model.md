# Platform accounts model — users, orgs, billing, tenant ownership

> **Status: design (2026-06-07). Not built.** Establishes the
> identity/billing model for the **hosted** rewind.js service — who pays, who
> logs in, and which tenants they can touch — and, crucially, **where that
> state lives**. Companions: [`v2-cp-operational-state.md`](v2-cp-operational-state.md)
> (per-tenant plan/limits in the CP, authored by the admin app),
> [`plan-tiers.md`](plan-tiers.md) (DP enforcement), `auth-domain-plan.md`
> (the `__auth__` OIDC IdP + OIDC-RP dashboards + `platform.scope`),
> [`users-lib-plan.md`](users-lib-plan.md) (the *customer's* end-user auth —
> a different plane; see §2), `pricing-model.md` (per-tenant caps),
> [`project_self_host_marketplace`] + [`project_pricing_model`] memories.

## The decision in one paragraph

Billing accounts, organizations, platform users, and "a user can manage many
tenants" are all **product-layer state** — they live in the **dashboard
app's own `app.db`** (a normal rewind.js tenant), **not** in `rove` core, the
CP directory, or the DP. The DP enforces limits **per tenant**, next to
dispatch, and never learns about anything coarser than a tenant. The CP stores
an opaque **per-tenant** `{tier, overrides}` blob. The dashboard app is the
only place that knows "Account X is on Pro, so each of X's tenants gets Pro
limits," and it *materializes* that knowledge by writing one per-tenant plan
blob to the CP per affected tenant. This is why the identity/billing model is
**orthogonal** to the plan/limits DP work — and why none of it needs to touch
that work.

```
dashboard app (a tenant)                         CP                    DP
┌──────────────────────────────┐   /_control/plan   ┌──────────┐  push  ┌───────────┐
│ User / Membership / Account   │ ─ per tenant ─────▶│ plan/{t} │ ─────▶ │ TenantSlot│ enforce
│ tenant→account ownership      │   (a capability-    │ (opaque) │ attach │  .plan    │ (per tenant)
│ Stripe, tier, provisioning    │    gated Cmd)        └──────────┘        └───────────┘
└──────────────────────────────┘
        business logic                source of truth (dumb)        enforcement (dumb)
```

## §1 — Why this stays out of the engine

The criterion `v2-cp-operational-state.md` already established for "what goes
in the CP" is **admin-authored AND placement-independent** — that is what put
`plan/{tenant}` there. Accounts/orgs/users fail a *different* test that keeps
them out of even the CP: they are **business policy**, and the locked
architecture says business policy lives in a **normal admin app**, never in
the CP binary (a small, auditable trust boundary) and never in `rove` core
("rove never knows what a dollar is", `plan-tiers.md`).

Concretely:

- **The DP must stay per-tenant.** Enforcement runs next to dispatch on the
  serving cluster, keyed by the tenant's raft group / store. Introducing an
  account axis on the hot path would violate the no-`O(N_tenants)`,
  no-extra-store-read invariant ([`feedback_no_n_tenants_hot_path`]). The DP
  reads `slot.plan.*` — a field load — and nothing else.
- **The CP stays dumb + per-tenant.** It stores the materialized
  `{tier, overrides}` blob per tenant. It does **not** learn the account
  graph. The account→tenants mapping is the dashboard app's job.
- **The control-write seam is already account-shaped.** The CP control API
  authorizes the caller via a **capability grant, not a hardcoded tenant id**
  (`v2-cp-operational-state.md` §"The sharp edge"). "An org manages its
  tenants" is the *same shape* as the already-anticipated "a self-hoster
  manages sub-tenants' limits." No CP change is needed to support accounts —
  the dashboard app simply holds the grant.

## §2 — Two auth planes — do not conflate them

There are two completely separate authentication planes; accounts/orgs live in
the **platform** plane only:

| Plane | Who authenticates | Where it lives | Org concept |
|---|---|---|---|
| **Platform / dashboard** | a *developer/operator* logging in to manage their tenants + billing | `__auth__` OIDC IdP + OIDC-RP dashboard app (`auth-domain-plan.md` Ph3, PLAN §13.1/§13.2); membership/account data in the dashboard app's `app.db` | **this doc** |
| **End-user (customer app)** | the *customer's own users* of *their* deployed app | `users-lib` inside the customer's tenant (`users-lib-plan.md`) | **deliberately deferred** — B2C-only, "Orgs/B2B: Out" |

The user's "a user can access multiple tenants" is the **platform plane**. It
is *not* `users-lib` (that's a customer building their own Clerk for their own
app's consumers, and it explicitly excludes orgs). Keeping these planes
distinct is load-bearing: the platform plane already shipped its IdP +
`platform.scope` primitive; this doc only adds the data model on top.

## §3 — The data model (in the dashboard app's `app.db`)

```
User        ── id, identity (OIDC subject / email), …
Membership  ── (user_id, account_id, role)          ── many-to-many
Account     ── id, stripe_customer_id, tier, …       ── = org = billing entity (for now)
Tenant      ── owner = account_id                     ── exactly ONE owning account
```

- **User ↔ Account is many-to-many** via `Membership` (a user in several
  accounts; an account with several members). `role` gates what a member may
  do (e.g. `owner` / `admin` / `member` — billing changes vs. read-only).
- **Tenant → Account is a single owning edge.** A tenant has exactly one
  owning account (its payer). **Access is derived**, not stored per-tenant: a
  user may touch a tenant iff they are a member of that tenant's owning account
  (plus a role check). Cross-account tenant *sharing* (a user from account B
  granted access to account A's tenant) is a later `Grant` table — **not built
  now**.
- **`Account.tier` is the billing truth.** The per-tenant CP blob is the
  *materialized enforcement record*. The dashboard writes one
  `POST /_control/plan {tenant, plan}` per affected tenant whenever the tier
  changes, a tenant is created, or a tenant moves. The CP/DP never aggregate
  back to the account.

This is consistent with the marketplace framing ("tenant = installed app" → an
account installs apps; [`project_self_host_marketplace`]) and the pricing model
(per-tenant hard caps; [`project_pricing_model`]).

## §4 — Two forks, and the chosen defaults

### Fork 1 — org vs billing account: **one entity, splittable later**

Model `Account` as a single entity that is simultaneously the member-group,
the Stripe customer, and the tier holder. Keep `tenant.owner` a single id
reference so a later split (introduce a distinct `billing_account_id` on the
account) needs no rework of tenant ownership. The split only earns its keep
for agencies/resellers — one biller across many orgs, or many billers under
one org — which is the self-host/agency direction. **Defer until there is
concrete demand** ([`feedback_compose_from_primitives`]).

### Fork 2 — per-tenant limits vs pooled account quotas: **per-tenant**

If billing ever meant "your account gets 100 GB / 1 M requests *pooled* across
all your tenants," per-tenant DP enforcement could not express it without
cross-cluster aggregation (an account's tenants live on different clusters).
**Stay per-tenant**: each tenant on a Pro account gets the Pro *per-tenant*
limits; the account-level figure is "per-tenant × N tenants," not a shared
pool. This keeps the DP untouched and matches `pricing-model.md`'s per-tenant
hard caps. Pooled quotas would be a **metering service** in the product layer
reading per-tenant usage counters — deferred, and even then it lives above
`rove`, not inside it.

## §5 — What this means for the plan/limits DP work

**Nothing changes.** DP delivery (the plan riding the attach handshake +
single-target push on live change) and DP enforcement (rate / 413 / retention)
are keyed per tenant and are unaffected by the account graph above. The
account model is purely the *source* the dashboard app uses to compute each
tenant's plan blob.

One optional, forward-looking nicety (not a blocker, not built now): stamping
an `account_id` into usage/log records would make the product layer's billing
rollups cheap (group-by-account without a tenant→account join at query time).
Defer until a metering/billing layer actually needs it; it is an optimization,
not part of enforcement.

## §5.1 — Self-hosting is just a different admin tenant

Because the dashboard is a normal tenant app, the **self-hosting dashboard is
simply a *different* admin tenant** with a UI tuned for self-hosting — not a
separate binary, a build flag, or a fork of the engine. Both the hosted
dashboard and the self-host dashboard are tenants that hold the (capability-
gated) CP-write grant and talk to the same control-write seam; they differ only
in their UI and which slice of policy they expose:

- **Hosted dashboard** — multi-account SaaS UI: signup, Stripe billing, the
  account/membership model above, support for many customers' accounts.
- **Self-host dashboard** — an operator-flavored UI for one deployment: manage
  *your own* tenants + their limits, no Stripe/multi-account billing surface,
  possibly delegated sub-tenant admin (the grant already supports it).

This keeps the engine and CP identical across hosted and self-host — the only
thing that varies is which admin tenant you deploy. It also matches the
no-dev-only-features rule ([`feedback_avoid_dev_only_features`]): self-hosting
is a real tenant on the production path, not a stripped-down mode.

## §6 — Build order (when the dashboard app is picked up)

This is **product-layer (tenant app) work**, not `rove` code:

1. `User` + `Membership` + `Account` tables in the dashboard app's `app.db`;
   platform login via the `__auth__` OIDC RP (already shipped).
2. Tenant ownership edge (`tenant.owner = account_id`) + derived-access checks
   (member-of-owning-account + role) on every dashboard tenant action.
3. Stripe webhook → set `Account.tier` → materialize: write
   `/_control/plan` for each of the account's tenants (idempotency/audit in
   the app's own `app.db`, the effect being the CP write — same durability
   story as any `Cmd`, `v2-cp-operational-state.md` §"The control-write seam").
4. (Later, on demand) cross-account `Grant` sharing; billing/org split;
   pooled-quota metering service.
