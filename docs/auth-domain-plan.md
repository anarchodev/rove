# Auth + domain layout plan

**Status:** §5 decisions accepted 2026-05-15 (Phase 0 complete; Phase 1
unblocked and may start). Not yet reflected in `PLAN.md` §7/§13 or
`deployment.md` — those edits are deliberately parked as Phase 4 until
Phases 1–3 land (see §6, §7).

This sub-plan elaborates the auth and domain-layout shift discussed
2026-05-15: a two-registrable-domain split, full OIDC shipped as a
dogfooded customer library, and in-tree (no-proprietary-backend) cert
provisioning. It supersedes the cert-provisioning shape implied by
`PLAN.md` Phase 10 ("per-custom-domain Let's Encrypt", which was
unspecified as to mechanism) and adds a superseding entry candidate
for `PLAN.md` §7.

The customer-facing product is `rewind.js`; the engine library stays
`rove`; in-tree identifiers (`loop46` binary, `LOOP46_*` env vars,
`docs/PLAN.md` text) remain unchanged until the separately-tracked
rename cutover. This doc uses the in-tree names for code/config and
`rewind.js` only for customer-facing copy.

---

## 0. The one invariant

**Host-relative everything. No platform-domain literal anywhere in the
auth or host-resolution path.**

Every other decision below is a consequence of this one rule. It is
what lets a single code path serve three things at once:

1. The platform's own control plane on `rewindjs.com`.
2. A customer's app on a `*.rewindjs.app` subdomain.
3. A customer running their *own* OIDC provider on their *own* custom
   domain (`auth.acme.com`).

Concretely: the OIDC `iss`, the JWKS URL, the `authorize`/`token`
endpoints, and the cookie scope are all derived from the request's
`Host`, never from a compiled-in constant. If any of these is a
literal, all three use cases break and the dogfooding claim is false.
This invariant is the acceptance test for every PR in this plan.

---

## 1. Domain layout

Two registrable domains, both operator-owned (acquired 2026-05-15):

| Domain | Purpose | Cert | Resolution |
|---|---|---|---|
| `*.rewindjs.app` | Customer tenants (`{id}.rewindjs.app`) | wildcard, DNS-01 (operator zone) | `{id}.{public_suffix}` fallback in `resolveDomain` |
| `rewindjs.com` | System surfaces (`app.`, `replay.`, `auth.`, `logs.`, `files.`, `sse.`) | wildcard, DNS-01 (operator zone) | explicit `domain/{host}` map entries on system tenants |
| customer custom domains (`acme.com`) | Customer-brought specific FQDNs | per-FQDN, HTTP-01 (in-tree) | explicit `domain/{host}` map entries |

The split is a **security boundary**, not cosmetics: customer JS runs
under a different eTLD+1 (`rewindjs.app`) from the control plane
(`rewindjs.com`), so cookie scope, `document.domain`, and storage
partitioning are isolated by construction. This is the structural fix
for the `PLAN.md` §7 Safari-ITP / third-party-cookie worry — better
than the bearer-token fallback, because a customer on their own custom
domain is same-site with their own API.

System surfaces stop being reserved wildcard labels and become custom
domains on system tenants (`assignDomain("auth.rewindjs.com",
"__auth__")`, etc.). Consequence: **the reserved-label /
`__admin__`-blocklist hack is deleted** — namespace collision becomes
structurally impossible, and the control plane onboards through the
exact mechanism a customer uses for `acme.com` (maximum dogfooding;
you cannot ship a broken custom-domain flow without breaking your own
control plane).

---

## 2. Host → tenant resolution (mostly already done)

`resolveDomain` (`src/tenant/root.zig:384`) already does the right
thing in the right order:

1. Explicit `domain/{host}` → instance lookup in the root KV store.
2. Wildcard fallback: `{id}.{public_suffix}` → instance `{id}`.

`assignDomain` writes the `domain/{host}` map. Sub-plans already assume
"`acme.{suffix}` or `acme.com` — same flow either way." So this layer
needs **no new routing logic**. What changes is configuration + seeding:

- `public_suffix` flips from `loop46.me` → `rewindjs.app`.
- System surfaces are seeded as explicit `domain/{host}` entries on
  system tenants (`__admin__`, a new `__auth__`, plus the existing
  replay/logs/files/sse surfaces keyed by `*.rewindjs.com` hosts).
- The reserved-label validation path is removed.

This is the cheap, high-signal Phase 1 below — fully testable with a
smoke before any OIDC or cert code exists.

---

## 3. Cert provisioning (in-tree, no proprietary backend)

Design principle: a self-hoster must get a fully-formed product with
**zero proprietary backend requirement** (no Cloudflare-for-SaaS, no
provider-specific DNS API). The only hard ACME fact that constrains the
design: **HTTP-01 cannot issue wildcards** (CA policy); wildcards
require DNS-01. The two needs are disjoint, so the design splits
cleanly **by who owns the zone**:

### 3.1 Operator-owned wildcards — unchanged

`*.rewindjs.app` and `*.rewindjs.com` are wildcard certs on zones the
operator controls. These keep the existing
`scripts/rove-lego-renew.sh` (lego, DNS-01, `rove-cert-renew.timer`)
flow **unchanged**. DNS-01 here is not the lock-in we're avoiding — it
is the operator pointing lego at their *own* DNS once at deploy, not a
per-customer provider dependency.

### 3.2 Customer custom domains — HTTP-01 via a dedicated :80 responder

Customer-brought domains are *specific FQDNs* (`acme.com`,
`www.acme.com`), never wildcards, so HTTP-01's no-wildcard restriction
is irrelevant to the one path that must be proprietary-free.

- A dedicated blocking HTTP/1.1 accept loop on `:80`, separate from the
  h2 stack. Reads the request line; if `GET
  /.well-known/acme-challenge/<token>`, returns the key authorization
  from an in-memory `token → keyauth` map; else 404. No nghttp2, no
  TLS, no OpenSSL on this listener (~150–200 lines, isolated,
  auditable).
- An in-process ACME client populates the map before requesting CA
  validation and clears it after. State is purely ephemeral
  per-issuance — no raft, no kv, no S3.
- Issued cert + key are written to a per-domain path under
  `~/.rove/tls/custom/{host}/`. Renewal is the same path on a timer.
- Trigger: the custom-domain onboarding flow is "customer adds CNAME →
  we detect it resolves to us → we issue." HTTP-01 inherently requires
  DNS-points-at-us-first; that ordering is the onboarding contract, not
  a defect.

Edge-proxy note: rove-h2 is HTTP/2-only and `deployment.md` already
mandates an L7 proxy for h1↔h2 translation. That proxy can be plain
nginx/HAProxy (OSS). The proprietary seam was *cert issuance*, not the
existence of a proxy. Self-hoster with no proxy → the :80 responder
binds directly. Behind nginx/HAProxy → one documented line routes
`/.well-known/acme-challenge/*` on :80 to it. Only if an operator
chooses Cloudflare do they use Cloudflare's certs and skip in-tree
ACME — their opt-in, never required.

### 3.3 SNI cert selection in rove-h2 — separate workstream (serving)

§3.2 solves *issuance*. *Serving* a custom-domain cert requires the
:443 listener to pick the right cert by SNI. Today this is **hard**:
`src/h2/tls.zig:179-217` builds **one static `SSL_CTX`** with one
cert/key pair, no `SSL_CTX_set_tlsext_servername_callback`;
`reloadIfChanged` (`tls.zig:94-122`) swaps the *entire* context.

Required change (independent of challenge type, so tracked as its own
workstream):

- An SNI `servername` callback on the server `SSL_CTX` that selects a
  per-host `SSL_CTX` (or per-host cert via `SSL_use_certificate` on the
  connection's `SSL`).
- A cert store keyed by SNI host: the wildcard ctx for
  `*.rewindjs.{app,com}` plus a map of custom-domain hosts →
  ctx/cert, populated from `~/.rove/tls/custom/` and refreshed when the
  ACME client writes a new cert (extend the existing mtime-poll, now
  per-entry instead of whole-context).
- ALPN callback stays h2-only (no `acme-tls/1` — we chose HTTP-01).

### 3.4 Customer wildcard custom domains — deferred

A customer wanting `*.acme.com` served by us would need DNS-01 against
the *customer's* provider. The proprietary-free forward path is
`_acme-challenge` **CNAME delegation**: the customer adds a one-time
CNAME pointing `_acme-challenge.acme.com` at a record on a zone *we*
own, and we answer DNS-01 there — no customer-provider creds, same
shape as the apex CNAME they already add. **v1 supports specific-FQDN
custom domains only (HTTP-01); customer wildcards are an explicit
deferral with the delegation pattern documented as the forward path.**

### 3.5 Client cert verification — operator-level mTLS (serving)

Independent of cert *issuance* (§3.1–3.2), the serving path can also
*verify* a presented client cert against a configured CA — TLS-layer
access control before any application code runs. v1 lands as an
operator-level knob piggybacked on the §3.3 SNI refactor; per-host /
per-tenant config is a forward path the §3.3 cert-store map already
accommodates.

**Why land it now (alongside §3.3):**

- **Staging-on-real-domain access control.** Operators dogfooding on
  the real `*.rewindjs.{com,app}` domains during development want
  "only my browser can reach this cluster" without a Cloudflare /
  nginx dependency.
- **Customer primitive for B2B mTLS.** Customers building partner
  APIs (or running a private staging on a custom domain) get mTLS as
  a platform feature instead of "you have to put nginx in front."
  Composes with the JS handler model rather than replacing it
  (handler still runs after TLS auth passes; JS-side auth layers on
  top for finer-grained per-route policy).
- **Phase-2c collision otherwise.** Bolting verify-config onto the
  one-static-`SSL_CTX` shape, then refactoring to per-host stores,
  duplicates work. Doing both in one refactor is the same code
  motion in less aggregate.

**v1 surface — operator-level only:**

```
loop46 worker \
  --require-client-cert-ca /path/to/ca.pem \
  ...
```

Off by default (production behavior unchanged). When set, applies to
every per-host `SSL_CTX` built by §3.3. Env-var equivalent
`LOOP46_REQUIRE_CLIENT_CERT_CA` follows the existing `LOOP46_*`
convention.

**Mechanism (OpenSSL):**

For each per-host `SSL_CTX` in the §3.3 cert store:

```c
SSL_CTX_load_verify_locations(ctx, ca_path, NULL);
SSL_CTX_set_verify(ctx,
    SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
    NULL /* default verify chain — no custom callback */);
```

A connection that presents no client cert, or one not signed by the
configured CA, fails the TLS handshake with a `bad_certificate` /
`unknown_ca` alert. No application-layer involvement, no log noise
beyond the existing TLS error path. Rejected connections never see
a `Request` object.

**Cert refresh:** the same mtime-poll machinery §3.3 introduces for
per-host server certs covers CA cert reloads too. Operator drops a
new CA file at the same path; on next poll the per-host `SSL_CTX`es
rebuild with the new verify roots.

**Behavior contract (smoke):**

- `--require-client-cert-ca` unset → server accepts plain TLS
  connections as today (production behavior unchanged).
- Flag set, client presents no cert → TLS handshake fails; curl
  returns `SSL_ERROR_*` / browser shows "cert required" prompt.
- Flag set, client presents cert NOT signed by configured CA →
  handshake fails with `unknown_ca`.
- Flag set, client presents cert signed by CA → handshake completes;
  the existing h2 / HTTP handlers fire normally.

Implementation in `scripts/client_cert_smoke.py`: spawn loop46 with
the flag, mint a CA + client cert via `openssl`, hit `/_system/health`
(or equivalent) with and without `--cert`/`--key`, assert each
status / error matches the contract above. New smoke; not part of
`replay_shell_smoke.mjs` (different layer).

**Out of v1 — explicit deferrals:**

- **Per-host / per-tenant CA.** Each `domain/{host}` map entry gains
  an optional `client_cert_ca` byte slot. SNI servername callback
  reads it when selecting the per-host `SSL_CTX` and configures
  `SSL_VERIFY_PEER` only on contexts that have it. Natural follow-up
  the §3.3 store already accommodates — see §9.
- **JS APIs for tenants to add / rotate CAs.** Stays out until
  concrete customer demand. Operator-level alone unblocks the
  staging case and the dogfooded mTLS-for-B2B preview.
- **CRL / OCSP / cert pinning beyond the CA chain.** Standard verify
  chain only; adding revocation is a separate workstream when a
  customer needs it.

**Implementation touch points** (for the agent picking this up):

- `src/h2/tls.zig` (the per-host `SSL_CTX` builder introduced by
  §3.3). Adds the two `SSL_CTX_*` calls above, gated on the CA-path
  field being non-null.
- `src/loop46/main.zig` (CLI flag plumbing). Parses
  `--require-client-cert-ca`, reads the env-var fallback, plumbs the
  path into the h2 server config struct. Resolves to absolute,
  validates the file exists at startup (fail-loud on missing).
- `scripts/client_cert_smoke.py` (new). Follows the canonical
  `scripts/smoke_lib.py` shape; spawns its own single-node cluster
  with the flag set, mints CA + client cert via `openssl` into a
  tempdir, asserts the four behaviors above.
- `docs/deployment.md` (Phase 4 docs sweep). One section on minting
  a CA, generating a client cert, installing the P12 into a
  browser, and the `--require-client-cert-ca` flag.

---

## 4. OIDC

### 4.1 What it replaces — and what it does NOT

OIDC replaces the magic-link-cookie + `/_system/services-token`-refresh
dance **for the human dashboard path only**. It does **not** replace
magic-link: magic-link/email stays as the *authentication* primitive
that establishes human identity; OIDC is the *token-issuance / SSO*
layer wrapping it. This is "add OIDC on top of existing magic-link,"
not "rip out magic-link."

Worker→standalone (files/logs/sse) auth is **unchanged**: HS256 shared
secret (`LOOP46_SERVICES_JWT_SECRET`, minted at
`/_system/services-token`, `src/js/worker_dispatch.zig:521-558`).
Machine-to-machine gains nothing from OIDC's delegation/consent/redirect
ceremony. The `scoped_token`/caps model (`docs/agent-surface.md`)
stays the agent-surface primitive.

### 4.2 Shipped as a dogfooded customer library

Full OIDC authorization server, shipped as a customer-facing JS library
(`oidc.provider(...)`, the issuance analog of the existing
`oauth.fromConfig(...)` client helper). Customers can run their own
OIDC provider on their own domain. The platform's own dashboards
authenticate as relying parties of an instance of this same library
running on the `__auth__` system tenant — dogfooded in both
directions. If the customer-facing library is broken, platform login is
broken; there is no privileged platform-only auth code path.

### 4.3 Issuer / keys / state model (host-relative)

- `iss` = `https://{request Host}` (the §0 invariant). JWKS,
  `authorize`, `token`, and discovery
  (`/.well-known/openid-configuration`) URLs are all derived from the
  request host.
- Signing keypair, registered clients, auth-code→claims, and refresh
  tokens live in the **owning tenant's kv** (the dogfooding answer; the
  existing `oauth.fromConfig` library already writes
  `state/oauth/...`). For the platform IdP that is `__auth__`'s
  app.db; for a customer IdP it is their own app.db.
- The subtle part is **per-issuer signing keypair + JWKS published per
  request host**, with key rotation (publish next key in JWKS before
  signing with it; retire after max token lifetime). This is the
  trickiest correctness surface — call it out for review.

### 4.4 Platform dashboards as relying parties

admin / replay / logs dashboards become OIDC relying parties of
`auth.rewindjs.com`. Because system surfaces share the `rewindjs.com`
eTLD+1, the SSO session cookie works across them without third-party-
cookie problems. Existing session cookie: `__Host-rove_sid`
(`src/js/session.zig:41`, 64-hex CSPRNG, `HttpOnly; Secure;
SameSite=Lax; Path=/`, 1y). Decision needed on cookie scope (§5).

### 4.5 v1 scope cut

Full OIDC is large. Proposed v1 = the minimal coherent set; everything
else explicitly deferred. **Decision in §5.**

| In v1 | Deferred |
|---|---|
| Discovery (`/.well-known/openid-configuration`) | Dynamic client registration (RFC 7591) |
| JWKS endpoint + key rotation | Consent screens (trusted first-party clients only in v1) |
| Authorization-code + PKCE | Token revocation endpoint (RFC 7009) |
| `id_token` + `access_token` + refresh | `userinfo` beyond core claims |
| HS-not-used: RS256/ES256 asymmetric signing | Front/back-channel logout |

---

## 5. Decisions (accepted 2026-05-15)

All four accepted as recommended.

1. **OIDC v1 scope** — the §4.5 cut as-is. Deferred items stay
   deferred until concrete demand.
2. **Signing algorithm** — RS256 for v1 (broadest RP compatibility);
   ES256 is an opt-in later, not v1.
3. **Dashboard cookie scope** — host-only cookie per surface with
   silent token refresh (keeps the `__Host-` prefix + tighter blast
   radius; SSO UX comes from the IdP session, not a shared-domain
   cookie). No `Domain=.rewindjs.com` cookie.
4. **Magic-link framing** — OIDC wraps, does not replace, magic-link
   (§4.1). Magic-link/email stays the authentication primitive.

---

## 6. Phased delivery

```
Phase 0  This sub-plan + §5 decisions ............ blocks all
Phase 1  Two-domain split (no OIDC, no certs) .... blocks 3c
Phase 2  Edge/DNS/TLS + in-tree ACME ............. parallel w/ 1, 3ab
Phase 3  OIDC build ............................... 3c needs 1 + 2 + 3ab
Phase 4  Cutover + PLAN/deployment.md docs ....... after 3
```

**Phase 1 — two-domain split (cheap, high-signal).** Flip
`public_suffix` → `rewindjs.app`; seed system surfaces as explicit
`domain/{host}` entries on system tenants; delete the reserved-label
hack. Smoke: `foo.rewindjs.app` → tenant `foo`; `app.rewindjs.com` →
admin tenant; reserved-label path gone. No OIDC, no cert code.

**Phase 2 — edge/DNS/TLS + in-tree ACME.**
(a) `*.rewindjs.app` + `*.rewindjs.com` wildcard via existing lego flow
(unchanged). (b) :80 HTTP-01 responder + in-process ACME client (§3.2).
(c) SNI cert store + servername callback in rove-h2 (§3.3) — the only
hard part; gated by a per-host TLS smoke.
(d) Operator-level mTLS via `--require-client-cert-ca` — bolted onto
every per-host `SSL_CTX` built in (c) (§3.5). Off-by-default; gated by
`scripts/client_cert_smoke.py`. Lands as part of the same refactor as
(c) — the verify config attaches to the same context objects, so doing
them together is strictly less code motion than sequencing them.

**Phase 3 — OIDC.** (a) discovery + JWKS (smallest; unblocks RP
testing). (b) authorization-code + PKCE, state in `__auth__` kv.
(c) wire dashboards as RPs, admin first; retire human-path
services-token dance. (d) ship as the `oidc.provider(...)` customer
library. 3a/3b can build concurrently with Phases 1–2; 3c needs Phase
1 (cookie domains) + Phase 2 (TLS for `auth.rewindjs.com`) + 3ab.

**Phase 4 — cutover + docs.** `deployment.md` (two cert flows, :80
responder, edge note), `PLAN.md` §7 superseding entry (so the OIDC
`auth.` origin is not pattern-matched to the rejected
`admin.loop46.com`), `PLAN.md` §13 process/surface map, `CLAUDE.md`
sub-plan index. Hold until Phases 1–3 land.

---

## 7. Why this is not the §7-rejected designs

`PLAN.md` §7 must not be re-litigated, so the distinctions are explicit:

- **`admin.loop46.com` + bearer tokens** (rejected: didn't dogfood the
  customer auth path). This plan's `auth.rewindjs.com` is *itself a
  tenant running the customer OIDC library* — it satisfies the
  dogfooding principle instead of violating it. The §4 framing is the
  inverse of the rejected one.
- **`{name}.api.loop46.com` + PSL (two-label-deep within one
  registrable domain)** (rejected: PSL propagation is a launch blocker;
  two-label wildcard TLS is ops pain). This plan uses *two separate
  registrable domains*, each with its own single-label wildcard. No
  PSL dependency, no two-label-deep wildcard. The §7 objection does not
  apply. (PSL submission for cookie defense-in-depth, `PLAN.md` Phase
  10, is orthogonal and unaffected.)
- **Cookie-based auth for third-party-host C2 calls** (rejected for
  Safari ITP). The domain split makes a customer same-site with their
  own API on their own custom domain — this plan is the structural fix
  the §7 entry wanted, not a re-proposal of the rejected default.

---

## 8. Rejected / considered alternatives

- **Cloudflare-for-SaaS custom-hostname TLS.** Considered; rejected as
  the default — a proprietary backend requirement in an otherwise
  self-contained product. Stays available as an operator opt-in, never
  required.
- **TLS-ALPN-01 challenge.** Considered; rejected vs HTTP-01 — it
  entangles issuance with the OpenSSL/nghttp2 SNI+ALPN internals,
  harder to audit/isolate. HTTP-01 in a separate tiny server keeps
  issuance fully decoupled from the h2 stack.
- **DNS-01 for customer custom domains.** Rejected — needs
  customer-provider DNS API creds (the lock-in we're avoiding).
  Retained only for operator-owned wildcards (operator's own zone) and
  as the documented `_acme-challenge` CNAME-delegation forward path for
  customer wildcards (§3.4).
- **OIDC replacing magic-link.** Rejected — magic-link is the
  authentication primitive; OIDC wraps it for issuance/SSO (§4.1).
- **OIDC for worker→standalone.** Rejected — machine-to-machine gains
  nothing from delegation/consent/redirect; HS256 shared secret stays.
- **Reverse proxy (nginx / Cloudflare Access) for client-cert mTLS
  instead of rove-native verification (§3.5).** Considered; rejected as
  the default — customers would need to ship their own copy of the
  same pattern (proprietary edge dependency or one more process to
  babysit), and operator staging gets locked into the same. Stays
  available as an operator opt-in (someone already running nginx for
  h1↔h2 translation can add `ssl_verify_client` there); never required.

---

## 9. Open questions

- Key rotation cadence + JWKS publish/retire window (§4.3) — the
  highest-risk correctness surface; wants its own design pass before
  Phase 3b.
- Custom-domain onboarding UX: how the dashboard surfaces "add this
  CNAME → status: verifying → issued" (ties into `PLAN.md` Phase 10
  domain-assignment UI + per-account custom-domain caps).
- ACME rate limits at signup surges (`PLAN.md` Phase 10 already flags
  this). Note: each customer brings their *own* registered domain, so
  the per-registered-domain limit is per-customer, not pooled against
  us; pooled risk is only the operator's own `rewindjs.*` wildcards,
  which are DNS-01 and rarely reissued.
- Whether `__auth__` is a distinct system tenant or `platform.*`
  capability on `__admin__` (`PLAN.md` §10.1 made `__admin__` a real
  tenant — `__auth__` should follow that pattern).
- Per-host client-cert CA storage shape (§3.5 v2). The `domain/{host}`
  map entry growing an optional `client_cert_ca` byte slot is the
  natural extension. Whether that byte slot lives inline alongside the
  existing instance pointer or in a sibling `domain_tls/{host}` row is
  a decision for the v2 pass. Open until a customer needs per-host
  mTLS.
