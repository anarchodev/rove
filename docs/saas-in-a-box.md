# SaaS in a box — the author-platform product shape

> **Status: design (2026-06-10). Not built.** Defines the B2B product shape
> for authors who run their *own* SaaS on rewind.js: per-end-customer
> tenants ("Workers for Platforms", but stateful) plus a first-party
> library suite (users, billing, jobs, webhooks, flags, …) that replaces
> the standard SaaS vendor stack. Companions:
> [`platform-accounts-model.md`](platform-accounts-model.md) (accounts/orgs;
> the dashboard-app pattern this productizes),
> [`users-lib-plan.md`](users-lib-plan.md) (the auth library; already
> planned, P1a–P5), [`pricing-model.md`](pricing-model.md) +
> [`architecture/control-plane.md`](architecture/control-plane.md) "Operational state" (per-tenant caps/enforcement),
> `architecture/auth-and-domains.md` §4.2 (dogfooded customer libraries —
> the delivery model for everything here), and
> [`effect-algebra.md`](effect-algebra.md) / [`handler-shape.md`](handler-shape.md)
> (the primitives all of this composes over).

## The product in one paragraph

An author builds their SaaS as pure handlers and gets, from one platform:
end-user auth (**users-lib**), subscriptions and entitlements
(**billing-lib**), durable background jobs, customer-facing webhooks,
feature flags, rate limiting, audit logs, realtime channels — each a
first-party JS library over the four reified primitives — and **every one
of their customers runs in an isolated stateful tenant** (own `app.db`,
own raft group, own blobs, own capability boundary). The competitive
frame: Clerk + Clerk Billing + Stripe glue + Cloudflare Workers for
Platforms + Inngest + Svix collapse into one substrate with one bill.
Clerk shipping Clerk Billing is market validation that auth + billing
want to be one bundle; we extend the bundle to "and we host the app and
own the state model."

## §1 — Why this category is winnable from here

Four properties competitors cannot retrofit:

1. **Truth lives in the tenant's own `app.db`.** Clerk's chronic
   operational pain is that user truth lives in Clerk and the customer's
   database holds a webhook-synced copy (ordering bugs, missed events,
   drift). Same for Stripe entitlement mirrors. Here, users-lib rows and
   subscription/entitlement state are ordinary kv keys written by the
   same raft-serialized handlers as product data: one source of truth,
   no sync layer anywhere in the stack.
2. **Billing logic is replayable.** Every lib is a shim over taped
   primitives, so "why was this customer charged / entitled / flagged
   into that variant" is a tape you can step through. No vendor in this
   bundle can make that claim.
3. **Per-end-customer stateful isolation.** Cloudflare WfP gives the
   author isolates per customer but a weak per-customer *state* story.
   The polymorphic-tenant frame extends naturally: WfP shell ⇒ tenant =
   *the author's end-customer*. Per-tenant raft groups with the
   hibernating active set were built precisely for "thousands of tiny,
   mostly-idle tenants" — this is the designed-for workload, and
   "each of your customers gets a fully isolated stateful instance" is
   a differentiated pitch (and a feature the author can resell).
4. **Capability grants + readset audit.** What an app (or a customer
   instance) read and sent is enforced and inspectable — the compliance
   story arrives with the platform instead of being bolted on.

## §2 — The shell: tenant = the author's end-customer

The control plane for this **already exists as a pattern**: the
first-party dashboard app (see `platform-accounts-model.md`) owns
account → tenants, writes per-tenant plan blobs through the
capability-gated CP control API, and materializes business policy into
per-tenant limits. The WfP shell is that pattern **productized for
authors**: the author's "platform app" provisions a tenant per
end-customer and manages it exactly the way our dashboard manages
tenants.

What this reuses as-is:

- **Provisioning** — `tenant.createInstance` under the author's account;
  the CP control-write is already a capability grant, not a hardcoded
  tenant id.
- **Plans/limits** — Fork 2 (per-tenant × N, no pooling) fits this shape
  with zero change; the author's *pricing tiers* map directly onto
  per-tenant resource plans, so metered/seat billing falls out of
  machinery that exists.
- **Custom domains** — per-tenant domains + ACME are shipped
  (`architecture/auth-and-domains.md`), so `customer-x.author.com` or
  the customer's own domain per instance works today.

Economics align by construction: we bill the author per tenant
(per-tenant × N), the author bills their customer through billing-lib,
and the author's margin is their price minus our per-tenant cost. Our
revenue scales with the author's customer count.

## §3 — The library suite

Delivery model is `auth-and-domains.md` §4.2 unchanged: dogfooded JS
libraries over the primitives (`globals/*.js`, IIFE-wrapped), vendor
specifics inside the wrapper (the `email.send` / vendor-neutral
`webhook.send` rule), recipes documented, no new engine surface unless a
gap is proven.

Selection filter: *vendors a SaaS founder pays $50–500/mo for, where the
primitives make the shim **better** (replayable, no sync layer,
durability inherited from commit-gated effects), not merely cheaper.*

### Core pair

| Lib | Replaces | Composition | Notes |
|---|---|---|---|
| `users` | Clerk (auth) | per `users-lib-plan.md` | Already planned (B2C, passwordless, TOTP MFA). **Orgs/teams/RBAC promoted from "deferred" to users-lib v2** — see below. |
| `billing` | Clerk Billing / Stripe glue | checkout sessions over `http.fetch`; inbound webhook signature verify via `crypto.hmacSha256` (shipped, `src/js/bindings/crypto.zig`); entitlements = kv keys; Stripe specifics stay in the shim | **Unblocked today** — no missing primitive. |

Orgs/teams/RBAC: the users-lib deferral was B2C scoping, which is the
wrong weight for this product — "Clerk for B2B" *is* orgs. It is pure kv
data modeling (`Org` / `Membership` / `Role` rows), invites via
`email.send`, seat-billing tie-in via billing-lib; zero engine work.
Scope guard: **roles-as-data** (owner/admin/member + custom roles), not
a policy-language engine.

### Tier 1 — primitives give an unfair version

| Lib | Replaces | Composition | The unfair part |
|---|---|---|---|
| `jobs` | Inngest / Trigger.dev | durable continuations + commit-gated effects + durable wake (`scheduler`) | Their whole product — durable step functions — already ships as primitives; failure debugging = replay the tape. The marquee lib. |
| `webhooks` | Svix | `webhook.send` + retry lib + kv endpoint registry + delivery-status keys | "Let *your* customers register webhook endpoints" — an entire company as a library. |
| `flags` | LaunchDarkly | kv keys + a small evaluation function | Flag evaluations land in the readset ⇒ "why did this user see that variant" is replayable. |
| `ratelimit` | Upstash | kv token bucket | ~20 lines; instant docs win. |
| `audit` | WorkOS audit logs | query/export surface over the tape/readset | The engine already records ground truth; no competitor's audit log is backed by deterministic replay. |

### Tier 2 — composite, all pieces exist

| Lib | Replaces | Composition |
|---|---|---|
| `channels` | Pusher / Ably | inbound WS + kv-wake broadcast recipe (rooms, presence). Outbound-WS gap blocks *consuming* external feeds only, not serving. |
| `notify` | Knock / Courier | `email.send` + `webhook.send` + in-app inbox (kv + WS push) + scheduler digests, with per-user preferences |
| `usage` | metered-billing glue | kv counters + scheduled rollups → billing-lib metered prices |
| `uploads` | Uploadthing | presigned flows over shipped `blob.*` |

### Integration libs — wrap a vendor, don't build the engine

| Lib | Wraps | Shape |
|---|---|---|
| `search` | Meilisearch / Typesense / Algolia | index updates ride commit-gated effects (or `jobs` for batching); queries are ordinary fetches in the readset. The capability grant makes the data egress *visible* — and a self-hoster can point the same app at their own index. Build the recipe, not an index. |
| `images` | Cloudinary / imgix / wsrv-style | `blob.*` upload + the shipped 302-to-presigned pattern with a transform service in front. No worker compute. |

## §4 — Identity: embedded library vs identity tenant

Two deployment modes for users-lib, both falling out of the same
library because it is a *library over kv*, not a service:

- **Embedded (default, v1):** users-lib runs inside the author's app;
  sessions are in-process kv reads; one tape covers auth + product
  logic. Right for single-app SaaS — the "Rails devise" stage.
- **Identity tenant:** the users-lib reference app deployed as its
  *own tenant* in the author's account; product apps are OIDC relying
  parties. This is the `__auth__` pattern (the platform's own IdP is a
  tenant running `oidc.provider` from `globals/oidc.js`, with dashboards
  as RPs via `oidc.rp`) **productized for authors** — their own
  self-custody Clerk: one user store across their whole portfolio, SSO
  between their apps, exportable `app.db`, on infrastructure they
  control. "App #2" means installing an app, not a migration project.

The honest trade: the identity tenant reintroduces a sync boundary —
entitlements/identity now cross tenants via short-TTL token claims and
local verification (`oauth.verifyIdToken` against cached JWKS, no
per-request hop) rather than living in the product app's own `app.db`.
But it is the *principled*, stateless version of sync; Clerk's drift
problem comes from webhook-mirroring user *records*, which the RP
pattern never does. Authors choose: one app ⇒ embed; many apps ⇒ accept
the OIDC boundary they would have needed anyway.

The identity app is itself an installable app — the suite dogfoods the
app-distribution story, and "Auth" is a natural first-party launch app.

## §5 — Engine deltas (deliberately tiny)

Verified against the tree (2026-06-10): the JS crypto surface already
ships `sha256`, `hmacSha256` (RFC 4231-tested, deterministic/no-tape),
`getRandomValues` / `randomUUID` / `randomBytes`, RSA + ECDSA verify,
full ECDSA keygen/sign/verify, and OIDC signing. Consequences:

- **billing-lib needs nothing** — Stripe webhook verification is
  `hmacSha256` + a comparison.
- The true crypto gaps are three thin additions to the existing binding:
  - `crypto.timingSafeEqual` — comparing HMAC hex with `===` is not
    constant-time; ~10 lines of hygiene every signature-verifying lib
    should use.
  - `crypto.hmacSha1` — only if TOTP ships (RFC 6238 defaults to SHA-1;
    authenticator apps expect it). Already pre-proposed as users-lib
    P1b.
  - `Ed25519` sign/verify — not needed by this product, but the same
    binding file closes the known ActivityPub gap; do it in the same
    pass.
- The WfP shell needs **no engine work**: provisioning, plans, domains,
  and the capability-gated control write all exist. What's new is
  product-layer — a provisioning API surface for the author's platform
  app, and account-level roll-up/billing in the dashboard app.

Everything else in §3 is JS shims + docs. Per the freeze workflow, the
libs are experimental until frozen; per the no-half-refactors rule, each
lib ships whole or not at all.

## §6 — Sequencing: three rungs, each sellable alone

1. **Rung 1 — the libs on the current product.** users-lib (planned) +
   billing-lib (unblocked) + ratelimit/flags (days each) + jobs (the
   marquee) + webhooks + audit. Raises the existing dev product's value
   for self-selling authors with zero engine work. Build order within
   the rung: ratelimit + flags first (instant docs-page wins), then
   jobs, then webhooks; audit rides whatever tape-export surface replay
   already needs.
2. **Rung 2 — the WfP shell.** Productize the dashboard-app pattern:
   author-facing provisioning API, per-end-customer tenants, account
   roll-up. Product-layer work; proven demand category (Cloudflare WfP,
   Shopify Functions); bills at real infrastructure prices.
3. **Rung 3 — app distribution.** The same bundles, installable by
   non-author users (separate direction, own doc when it firms up). The
   suite is rung-3-ready by construction: an app built on users+billing
   runs single-owner with billing stripped, and each lib doubles as a
   declarable capability in the app manifest.

The flywheel property to preserve at every step: **one bundle serves all
three rungs** — never fork an app's shape per rung.

## §7 — Scope guards (rejected up front)

- **No Clerk parity.** v1 auth scope stays `users-lib-plan.md`'s locked
  scope. The pitch is "users and billing without a vendor and without a
  sync layer," not feature-matrix parity.
- **No policy-language RBAC engine.** Roles-as-data only, until a
  customer proves the need.
- **No first-party search index, no image compute in the worker.**
  Integration libs only (§3).
- **No per-app billing surface for end-customer apps beyond
  billing-lib.** One billing model per rung; option-multiplication is
  the enemy (simplicity/safety over ergonomics, pre-launch).

## §8 — Open questions

- WfP pricing: per-tenant price for *author-owned fleets* (likely below
  the retail per-tenant price; the hibernating active set makes idle
  customer tenants cheap — price should reflect that).
- The provisioning API surface for the author's platform app (which
  capability grants, what the quota story is for runaway provisioning).
- Orgs data model details for users-lib v2 (invites, role set, seat
  counting for billing-lib).
- Whether `audit` exposes the raw tape/readset or a curated event
  schema (compliance buyers may want the latter).
