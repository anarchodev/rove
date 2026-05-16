# Auth + domain layout plan

**Status:** Phase 0 complete. **Phases 1, 2 fully landed +
smoke-verified (2026-05-15/16).** Phase 1 + 2c (§6/§3.3); 2a (lego
wildcard, unchanged); 2b in-tree ACME end-to-end verified against
Pebble (`fd3c53c`/`927fd88`/`38147f9`/`c39ab26`, §3.2 "Landed"); 2d
operator mTLS verified (`779e482`, §3.5 "Landed"). §5 decisions
accepted 2026-05-15; key-rotation design pass §4.6. **Phase 3 (OIDC): §4.7
design + forks A/B accepted. Implementation in progress —
3-1/3-2 RSA-RS256 crypto + JS bindings (`eb0f823`, unit-tested),
3-3 `oidc.js` provider (`1e32329`),
3-4 `__auth__` IdP tenant + web/auth (`d144977`), 3-5 §4.6 rotation
(`cfa4014`), 3-6 OIDC conformance gate (`2e6faa3`). **The OIDC chain
(3-1→3-5) is conformance-verified end-to-end — `scripts/oidc_smoke.py`
passes twice non-flaky incl. pure-Python RS256-vs-JWKS, §0, §4.6
rotation (see §4.7 "Landed").** Remaining: 3-6 part 2 — the Fork-B
dashboard→RP migration (admin last); now safe since the IdP is
proven. Phase-2 follow-up tracked: ACME renewal /
expiry-driven reissue (§3.2). Not yet reflected in `PLAN.md` §7/§13 or
`deployment.md` — those edits are deliberately parked as Phase 4 until
Phases 1–3 land (see §6, §7).

> **2026-05-15 ground-truth corrigendum** (Phase 1 code grounding).
> Three premises in the original draft were wrong against the
> codebase and are corrected in §1, §2, §6: (a) there is **no**
> reserved-label / `__admin__`-blocklist "hack" anywhere —
> `validateInstanceId` (src/tenant/root.zig:805) only checks charset,
> and a 2026-05-15 sweep of `src/tenant`, `src/js`, `web/` found only
> reserved *kv-key* logic (`src/js/reserved.zig`), no tenant-name
> guard; collision-safety is a *free consequence* of the domain
> split, nothing to delete; (b)
> `public_suffix` is a **required CLI flag** with no hardcoded default,
> so "flipping" it is deployment config, not code; (c) the real Phase
> 1 code change is **decoupling worker-hosted system surfaces
> (`__admin__`/`__replay__`/future `__auth__`) from the customer
> `public_suffix`** — today `replay.{public_suffix}` is hardcoded in
> bootstrap and `admin_api_domain` defaults to `app.{public_suffix}`,
> conflating the two domains the split exists to separate.

This sub-plan elaborates the auth and domain-layout shift discussed
2026-05-15: a two-registrable-domain split, full OIDC shipped as a
dogfooded customer library, and in-tree (no-proprietary-backend) cert
provisioning. It supersedes the cert-provisioning shape implied by
`PLAN.md` Phase 10 ("per-custom-domain Let's Encrypt", which was
unspecified as to mechanism) and adds a superseding entry candidate
for `PLAN.md` §7.

The customer-facing product is `rewind.js`; the engine library stays
`rove`; in-tree code identifiers (`loop46` binary, `LOOP46_*` env
vars, `src/loop46/`, `loop46.json`) remain unchanged until the
separately-tracked rename cutover. Doc prose (including `docs/PLAN.md`)
has been swept to `rewind.js` + `rewindjs.app`/`rewindjs.com` as of
2026-05-15; this doc uses the in-tree names only for code/config and
`rewind.js` for everything else.

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
| `rewindjs.com` (apex + `*.rewindjs.com`) | Marketing landing on apex (`__marketing__`) + system surfaces on subdomains (`app.`, `replay.`, `auth.`, `logs.`, `files.`, `sse.`) | apex + wildcard SAN, DNS-01 (operator zone) — `rove-lego-renew.sh` already co-issues both | explicit `domain/{host}` map entries on system tenants (including the apex) |
| customer custom domains (`acme.com`) | Customer-brought specific FQDNs | per-FQDN, HTTP-01 (in-tree) | explicit `domain/{host}` map entries |

The split is a **security boundary**, not cosmetics: customer JS runs
under a different eTLD+1 (`rewindjs.app`) from the control plane
(`rewindjs.com`), so cookie scope, `document.domain`, and storage
partitioning are isolated by construction. This is the structural fix
for the `PLAN.md` §7 Safari-ITP / third-party-cookie worry — better
than the bearer-token fallback, because a customer on their own custom
domain is same-site with their own API.

System surfaces stop being keyed off the customer `public_suffix` and
become explicit `domain/{host}` entries on system tenants
(`assignDomain("auth.rewindjs.com", "__auth__")`, etc.). Consequence:
**namespace collision becomes structurally impossible without any
blocklist** — there was never a reserved-name guard (a customer can
register `__admin__` today; it is simply unguarded), and the split
makes a guard unnecessary because system surfaces resolve via explicit
map entries on `rewindjs.com` while customers only ever land on the
`*.rewindjs.app` wildcard. The control plane onboards through the
exact mechanism a customer uses for `acme.com` (maximum dogfooding;
you cannot ship a broken custom-domain flow without breaking your own
control plane).

**Apex `rewindjs.com` (marketing).** Same mechanism, one extra
detail: the wildcard fallback structurally cannot reach the apex
(`wildcardInstanceId` at `src/tenant/root.zig:438` requires
`host.len > suffix.len + 1`), so `assignDomain("rewindjs.com",
"__marketing__")` is the only resolution path — explicit map entry on
a dedicated `__marketing__` system tenant serving the static landing
site. Kept on its own tenant rather than folded into `__admin__` so
the "no auth, no API, no cookies" posture from `PLAN.md` §2.1 is
structural rather than aspirational: the marketing tenant deploys no
handler that reads sessions or sets `Set-Cookie`, and the cookie
scoping decided in §5 (host-only `__Host-` cookies per surface) means
nothing on `app.`/`replay.`/`auth.` ever leaks to the apex regardless.

---

## 2. Host → tenant resolution (mostly already done)

`resolveDomain` (`src/tenant/root.zig:384`) already does the right
thing in the right order:

1. Explicit `domain/{host}` → instance lookup in the root KV store.
2. Wildcard fallback: `{id}.{public_suffix}` → instance `{id}`.

`assignDomain` writes the `domain/{host}` map. Sub-plans already assume
"`acme.{suffix}` or `acme.com` — same flow either way." So this layer
needs **no new routing logic**. What changes is configuration + seeding:

- `public_suffix` (the **customer** wildcard) is set to `rewindjs.app`
  at deploy via the existing required `--public-suffix` flag — config,
  not code.
- A **separate system domain** is introduced (it must not be the
  customer `public_suffix`; that conflation is the bug). Worker-hosted
  system surfaces — `__admin__` (`app.`), `__replay__` (`replay.`),
  and the future `__auth__` (`auth.`) — are seeded as explicit
  `domain/{host}` entries under it via `assignDomain`. Today bootstrap
  hardcodes `replay.{public_suffix}` and `admin_api_domain` defaults
  to `app.{public_suffix}`; both must derive from the system domain
  instead. (The files/log/sse standalones are separate binaries with
  their own listeners — not the worker's `resolveDomain`, out of
  scope here.)
- No reserved-label validation path exists or is added — collision
  safety is the free consequence above.

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

**Apex SAN, no script change.** Wildcards match exactly one label, so
`*.rewindjs.com` does **not** cover the bare apex `rewindjs.com` —
relevant because the apex hosts the marketing landing (§1).
`rove-lego-renew.sh:89-90` already requests `$BASE_DOMAIN` and
`*.$BASE_DOMAIN` as SANs on a single cert (the script header comment
names this explicitly), so the operator simply runs it twice — once
per registered domain — with `BASE_DOMAIN=rewindjs.app` (customer
wildcard; no public apex content) and `BASE_DOMAIN=rewindjs.com`
(system wildcard **plus** the marketing apex). The two resulting
certs land under distinct `LEGO_PATH/certificates/` files; the §3.3
SNI store picks each by SNI (apex hits the `rewindjs.com` cert, all
`*.rewindjs.com` subdomains hit the same cert via the wildcard SAN,
customer subdomains hit the `rewindjs.app` cert).

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

**Concrete design (grounded against the code 2026-05-15.)**

*Reuse (no reinvention):* `src/blob/curl.zig` — a libcurl `Easy`
+ process-wide `EasyPool` (`defaultPool()`), synchronous
`request(alloc, .{method,url,headers,body,timeout}) → {status, body}`,
TLS-verified, the same client S3 uses. Zig-stdlib `Sha256` +
`std.base64.url_safe_no_pad` (jwt/sigv4 already use them) + the
hand-rolled `base64urlDecode` (crypto.zig). OpenSSL via the existing
`@cImport`. `std.net.Address.listen()` + `server.accept()` for the
:80 loop; `std.Thread.spawn` + the shared `stop_flag` for its
lifecycle (slots in next to `runReloadPoll` in `loop46/main.zig`).
`Tenant.listDomains(max)` (root.zig:516) already enumerates every
`domain/{host}` entry → the issuance worklist; no new enumerator.
The Phase-2c seam is exact: ACME writes `{custom_cert_dir}/{host}/
{cert,key}.pem`; `reloadCustomCerts` picks it up within ≤1 s. No new
wiring between issuance and serving.

*Must build:* EC P-256 keygen + `PEM_write_bio_PrivateKey` (only
`PEM_read` exists today); ES256 `EVP_DigestSign*` (only verify
exists); `X509_REQ` CSR build+sign (absent); RFC 7638 JWK thumbprint
(compose Sha256 + b64url); the :80 responder + in-mem `token→keyauth`
map; the RFC 8555 state machine (directory → newNonce → newAccount →
newOrder → authz → http-01 → finalize → download).

*Gap found:* `curl.zig`'s `Response` is `{status, body}` only — it
**drops response headers**. ACME is header-driven (`Replay-Nonce` on
every POST, `Location` for the account/order URLs). Phase 2b must
extend `curl.zig` with a `CURLOPT_HEADERFUNCTION` capture (additive —
S3 ignores it). Small, contained, but a prerequisite, not optional.

*Architectural fork the original §3.2 glossed (decision needed, §5):*
HTTP-01 in a **multi-node** cluster. The CA fetches
`http://{host}/.well-known/acme-challenge/{tok}` via the customer's
DNS → the edge → **one** origin; the duplicate-cert rate limit
(5/exact-cert/week) punishes N nodes racing the same order. So
issuance must be **leader-pinned** — the exact pattern PLAN §6 /
http-send-plan §7 already use for the scheduler/webhook subsystems
(`if (raft.isLeader())`). That yields the real question: the issued
cert must end up on **every** node that terminates TLS for `{host}`,
but `--custom-cert-dir` is a node-local path.

**v1 (decided 2026-05-15): replicate the issued cert through raft.**
The leader issues, then writes `cert/{host} → {cert_pem,key_pem}`
into `__root__.db` via the **existing envelope 2 (root_writeset)** —
right next to the `domain/{host}` registry that already lives there.
No new envelope type, no new store, no external dependency. Every
follower applies it; a small materializer task writes
`{custom_cert_dir}/{host}/{cert,key}.pem` to that node's local disk,
and the Phase-2c poll then serves it by SNI within ≤1 s. Single-node
is a raft-of-1 — identical path, trivially correct. This is *more*
self-contained than a shared-FS mount (which would be exactly the
kind of external/proprietary-ish dependency the rest of this plan
rejects — cf. Cloudflare-for-SaaS) and survives follower restarts /
new-node joins via log replay + snapshot like all other raft state.

Sizing / precedent: a cert chain + key is ~2–8 KB, reissued every
~60–90 days per host — negligible raft traffic. **This is not the
size-based "blobs don't go through raft" decision in CLAUDE.md** (that
bans ~1 MB per-request static blobs from the log budget); certs are
three orders of magnitude smaller and rare. Called out so a future
reader doesn't pattern-match it to the rejected case.

Caveat (named, not fatal): this puts TLS **private keys into the raft
log history + snapshots + any log backup**. The keys are on every
node's disk *anyway* (inherent to multi-node TLS — true for any
distribution scheme); the delta raft adds is key *history* +
snapshots + backups. Bounded by: raft compaction dropping superseded
`cert/{host}` writes, and encrypting the envelope-2 cert payload at
rest (decide alongside whether `__root__.db` pages are encrypted —
implementation detail, tracked in §9). The :80 responder runs on
every node but the `token→keyauth` map is leader-only; the edge must
route `/.well-known/acme-challenge/*` to the leader (a documented
deploy constraint — same shape as "edge speaks h2 to origin").

Deferred: S3/blob-backed distribution is unnecessary given the above
— dropped, not merely postponed.

*Account key:* one long-lived EC account key (RFC 8555 best practice
— re-registering hits new-account limits) at
`{data_dir}/acme/account.key` (PEM, leader-owned, alongside the other
cluster-owned state). Order/nonce state stays purely ephemeral
per-issuance as the original §3.2 said — only the *account key*
persists.

*Test gate (decided 2026-05-15): Pebble.* No public DNS / external CA
in a hermetic localhost smoke, so the gate runs **Pebble** (Let's
Encrypt's official test CA — single binary, localhost, its own test
root): drives a real RFC 8555 flow against the :80 responder, asserts
the leader issues, the cert replicates via envelope 2, and a
*follower's* 2c store then serves it by SNI (proves the raft
distribution path, not just issuance). Pebble is a new test-only
dependency a contributor installs — same posture as the already-
required `mkcert`. Production readiness additionally gated by a manual
run against LE *staging* before prod-endpoint cutover (mirrors
`rove-lego-renew.sh`'s `ACME_STAGING` switch).

**Landed + end-to-end verified against Pebble 2026-05-16.** Commits
`fd3c53c` (curl header capture + `src/acme/{crypto,responder,client}`),
`927fd88` (`src/loop46/acme.zig` leader-gated issuance + every-node
materializer + envelope-2 replication + CLI), `38147f9`
(`scripts/acme_issue_smoke.py`), `c39ab26` (the fixes the gate
surfaced). `scripts/acme_issue_smoke.py` ran to completion **twice
(non-flaky)**: the leader issues via real RFC 8555, the cert
replicates via envelope-2, and a **follower** serves the
Pebble-issued cert by SNI (the raft distribution path proven, not
just issuance). Full `zig build test` + cli/crypto/responder unit
tests green; inert unless `--acme-directory` + `--custom-cert-dir`
both set. Bugs the gate caught + fixed (`c39ab26`): missing
User-Agent (CAs 400 a UA-less request — was a latent bug for *all*
HTTP), no `badNonce` retry (RFC 8555 §6.5; Pebble rejects ~5% of
nonces deliberately), responder bound on every node (collided on a
single host) → now leader-only + lazily bound. **Remaining
follow-up:** renewal / expiry-driven reissue (v1 issues only when
`cert/{host}` is absent).

### 3.3 SNI cert selection in rove-h2 — separate workstream (serving)

§3.2 solves *issuance*. *Serving* a custom-domain cert requires the
:443 listener to pick the right cert by SNI. Today this is **hard**:
`src/h2/tls.zig:179-217` builds **one static `SSL_CTX`** with one
cert/key pair, no `SSL_CTX_set_tlsext_servername_callback`;
`reloadIfChanged` (`tls.zig:94-122`) swaps the *entire* context.

**Concrete design (grounded against the code 2026-05-15).** Current
shape (`src/h2/tls.zig`): `TlsConfig` holds one `*SSL_CTX`, shared
process-wide across all worker threads; one `mu` mutex serializes
`newSsl()` (per-connection `SSL_new`, refcount-bumped) against
`reloadIfChanged()` (rebuilds the whole ctx, atomically swaps the
pointer, frees the old ctx — in-flight `SSL`s keep it alive via their
own ref). Per-connection `SSL` is created in `TlsConn.create`
(`tls.zig:261`), memory-BIO + `SSL_set_accept_state`; handshake driven
in `TlsConn.feed` (`SSL_do_handshake`) on the **worker thread**. ALPN
cb is ctx-level; no servername cb today.

Chosen approach — **per-host `SSL_CTX` store + ctx-level servername
callback doing `SSL_set_SSL_CTX`** (the standard nginx-shaped pattern;
rejected the per-`SSL` `SSL_use_certificate` swap as fiddlier — chain
+ key + options must all be re-applied per connection):

- The existing `--tls-cert`/`--tls-key` wildcard ctx stays the
  **default/fallback** ctx — unchanged behavior for no-SNI or
  unknown-SNI connections (Phase 1's single cert with both wildcard
  SANs keeps working untouched). The store is purely *additive*.
- A store: `host → *SSL_CTX`, each built via the existing `buildSslCtx`
  (so every per-host ctx inherits the ALPN-h2 cb + TLS1.2-min — no
  ALPN regression; `acme-tls/1` still not offered, we chose HTTP-01).
- `SSL_CTX_set_tlsext_servername_callback` on the **default** ctx: on
  ClientHello, `SSL_get_servername` → store lookup → on hit,
  `SSL_set_SSL_CTX(ssl, host_ctx)`; on miss, leave the default ctx
  (serves the wildcard). Runs on the worker thread inside the existing
  handshake path — no new thread, no handoff.
- Concurrency: the store is read on **every** handshake (worker
  threads, hot path) and written rarely (main-thread reload poll /
  ACME issue). An `RwLock` (many readers, rare writer); the
  servername cb takes the read lock for the pointer lookup only — the
  `*SSL_CTX` itself is refcount-stable for the connection's life
  exactly like `newSsl` does today (`SSL_CTX_up_ref` in the cb before
  `SSL_set_SSL_CTX`, drop our ref after the handshake — mirror the
  existing `newSsl` discipline so a concurrent per-host reload can't
  free a ctx out from under an in-flight handshake).
- Reload: the single `cached_{cert,key}_mtime` pair generalizes to
  per-host mtimes; the existing 1 s poll additionally scans
  `~/.rove/tls/custom/` (one `{cert,key}.pem` pair per host dir),
  rebuilding only the changed host's ctx and swapping that store
  entry (same atomic-swap-then-free-old pattern as today, per entry).
- Composes with §3.5: each per-host ctx is a `buildSslCtx` product, so
  the `--require-client-cert-ca` `SSL_CTX_set_verify` applies to every
  store entry + the default ctx uniformly (one code path).

First increment + gate: the store + servername cb + default-fallback,
loadable from `~/.rove/tls/custom/`, with a **per-host TLS smoke**
(extend `gen-dev-cert.sh` to mint a second cert for a non-wildcard
host; assert SNI to that host serves cert A and SNI elsewhere serves
the wildcard). ACME (§3.2) writes into the same dir later — store is
agnostic to who wrote the files.

**Landed 2026-05-15.** `src/h2/tls.zig`: `host_store`
(`StringHashMapUnmanaged` under `RwLock`), `installServernameCb` (via
`SSL_CTX_callback_ctrl`/`SSL_CTX_ctrl` — the `_set_tlsext_servername_*`
setters are macros translate-c can't see; cmd nums 53/54 hardcoded
with a note), `servernameCb` does `SSL_get_servername` → store lookup
→ `SSL_set_SSL_CTX` under the read lock (that call up-refs, mirroring
`newSsl`'s refcount discipline so a concurrent rescan can't free a ctx
mid-switch). Default `--tls-cert` ctx untouched as fallback; cb
re-installed on the rebuilt default ctx in `reloadIfChanged`.
`reloadCustomCerts` scans `{dir}/{host}/{cert,key}.pem` on the
existing 1 s poll (per-host mtime; build off-lock, swap under write
lock, sweep vanished hosts). CLI `--custom-cert-dir` (inert when
unset → pre-2c behavior exactly). Gate: `scripts/custom_domain_tls_smoke.py`
(SNI=custom→per-host cert, SNI=wildcard→default, SNI=miss→default) +
`cookie_auth_smoke` regression green (servername cb on every conn
doesn't perturb the wildcard path). 2b (ACME :80) / 2d (mTLS) bolt
onto this next.

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

**Landed + smoke-verified 2026-05-16** (`779e482`). `buildSslCtx`
applies `SSL_CTX_load_verify_locations` + `SSL_CTX_set_verify(PEER |
FAIL_IF_NO_PEER_CERT)` when `client_ca_path` is set, threaded through
`createFromFiles`/`reloadIfChanged`/`reloadCustomCertsImpl` so it
covers the default ctx and every per-host SNI ctx via the one code
path. `--require-client-cert-ca` + env `LOOP46_REQUIRE_CLIENT_CERT_CA`.
Off by default — `zig build test` + cookie_auth + custom_domain_tls
green, no regression. `scripts/client_cert_smoke.py` proves the
contract (valid CA cert → TLS ok / no cert → refused / wrong CA →
refused). Out-of-v1 deferrals (per-host CA, JS APIs, CRL/OCSP)
unchanged.

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
- Key rotation is the trickiest correctness surface — fully designed
  in **§4.6** (this resolves the §9 highest-risk item).

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

### 4.6 Key rotation (design pass 2026-05-15)

Resolves the §9 highest-risk item. RS256 (§5.2); rotation is library
code that runs purely-functionally in the owning tenant (platform
`__auth__` or a customer), so it must work with **no background
thread**.

**Issuer is one configured host per tenant** — not "every host that
routes here." The library reads the issuer host from `_config/oidc/...`
(default: the tenant's primary domain); `iss` is that host, JWKS is
served only when the request host equals it. This stays §0-compliant
(the host comes from tenant config, never a *platform* literal) while
avoiding per-host keyset sprawl, and matches how real IdPs expose a
single issuer URL.

**Keyset state machine.** One keyset row per issuer in the owning
tenant's app.db (page-encrypted at rest like all kv — no separate
secret store; consistent with the §7-rejected write-only-env
decision). Each key carries a thumbprint `kid` (RFC 7638 JWK
thumbprint — deterministic, collision-free across regenerations) and
is in exactly one phase:

| Phase | In JWKS? | Signs? | Min dwell |
|---|---|---|---|
| `next` | yes | no | T_publish = JWKS `max-age` + raft apply lag + schedule jitter + skew |
| `current` | yes | yes (exactly one) | rotation period |
| `retiring` | yes | no | T_retire = max access-token TTL + skew |
| `retired` | no | no | — (row deleted) |

JWKS publishes the public half of every `next`/`current`/`retiring`
key; RPs match by `kid` and never need to know which is `current`.

**Scheduled rotation drives all keyset mutation** (verified against
`docs/http-send-plan.md` 2026-05-15). One serialized path: a
self-rescheduling timer using the §10.4-cron / §10.5-order-timeout
cookbook pattern — `http.send({ handle: "oidc-rot-<issuer>", url:
"https://<issuer-host>/_oidc/rotate", fire_at_ns: <next deadline>
})`. The issuer host resolves cluster-local, so apply stamps
`is_internal` and `dispatchInternalSchedules` runs the rotate handler
**in-process** at fire time — no outbound HTTP (http.send-plan §3.2).
The stable `handle` makes re-arming an idempotent overwrite
(http.send-plan §1.1); arming the next timer rides the rotate
handler's own writeset and commits atomically with the new keyset in
one type-7 multi-envelope (http.send-plan §6). Envelope numbering:
schedule_upsert / schedule_complete are **8/9** per PLAN §10.2
(http.send-plan §4.2 shows the *pre-migration* 4/5 — use the current
8/9/10/11).

`advance(keyset, now)` is deadline-gated and reads the keyset fresh,
so a *sequential* double-fire self-heals: the second fire sees the
state the first already advanced and the next deadline not yet
reached, and no-ops.

> **Grounded correction (2026-05-16, step 3-5).** The original
> design above made a *concurrent* (leadership-change) double-fire
> safe via a schedule-`version`-keyed `_processed/oidc-rot/<version>`
> marker, citing http-send-plan §7. Grounding the implementation
> showed `X-Rove-Schedule-Id`/`-Version` are stamped **only on the
> libcurl/external path** — the internal-routed in-process fire
> (`internal_schedules.zig`) synthesizes a Request with **no headers
> at all**, so the version is not observable by the rotate handler.
> The `_processed` marker is therefore unimplementable as designed —
> **and also unnecessary.** Concurrent-double-fire safety actually
> comes for free from three properties: (1) the keyset is a *single*
> kv key, so raft serializes the two writesets last-write-wins — no
> split-brain, exactly one keyset persists; (2) we only ever *sign*
> with the `current` key, never `next`, so a briefly-published-then-
> overwritten `next` is harmless (no token is ever signed by it);
> (3) the re-arm uses a stable `http.send` `handle`, whose
> overwrite/version semantics collapse two concurrent re-arms into
> one row. So the rotate handler needs no header and no `_processed`
> marker: deadline-gated `advance` + single-key last-write-wins
> keyset + sign-only-`current` + handle-overwrite re-arm is
> dedup-safe. (No platform change to add internal-path headers — not
> needed for rotation; left as a possible future consistency fix for
> other internal-routed consumers.)
>
> Second grounding fact folded in: on internal-routed dispatch
> `request.host` is **empty**, so the rotate handler can't derive
> `iss`/the self-URL from it. The issuer host is captured into the
> keyset at **genesis** (which always runs on a real wire request
> where `request.host` is populated) and read from there by the
> rotate re-arm — consistent with §4.6's "one configured issuer host
> per tenant".

Emergency rotation (below) skips the publish window and bumps
`min_iat`; with the single-key keyset it likewise just last-write-wins
against any concurrent scheduled fire.

Scheduled-rotation sequence:

1. Generate K_new → `next`. JWKS now serves current + next.
2. Dwell T_publish. Every well-behaved RP refetches JWKS and learns
   K_new *before* it is ever used to sign.
3. Promote: K_old `current`→`retiring`, K_new `next`→`current`.
   Signing now uses K_new; JWKS still serves K_old.
4. Dwell T_retire. The longest-lived token signed by K_old at step 3
   expires.
5. Retire K_old: drop from JWKS, delete the row.

**Refresh tokens are opaque, kv-stored, never JWTs.** A design rule,
not an accident: it bounds T_retire by the *access*-token TTL (short)
instead of the much longer refresh lifetime, and it makes hard
revocation possible (you cannot revoke a stateless JWT). Access/id
tokens are RS256 JWTs; refresh tokens are random kv rows validated
server-side.

**Lazy backstop (read-only).** Keyset/JWKS reads happen on every OIDC
request anyway. If a request observes a transition deadline already
passed (schedule lost — shouldn't happen, `schedules.db` is
raft-replicated, but defense in depth), it does **not** mutate the
keyset; it idempotently re-arms the rotation schedule to fire now.
This preserves the single-writer invariant while self-healing a
dropped schedule and covering cold-start of a long-dormant issuer.

**Genesis.** First request to a fresh issuer: create one `current` key
(no `next`/`retiring`), serve JWKS, arm the first rotation at
now + period. Signing immediately with the genesis key is safe — there
is no prior key and therefore no stale RP cache to contradict.

**Emergency rotation (compromise) — a deliberately different policy.**
An admin action enqueues an immediate-fire rotate callback that
(a) generates K_new straight to `current`, (b) moves the compromised
key directly to `retired` (dropped from JWKS — *not* via `retiring`),
and (c) bumps a per-issuer `min_iat`: refresh tokens/sessions older
than now are rejected (possible *only* because refresh tokens are
opaque). This intentionally accepts that access tokens signed by the
compromised key stop verifying immediately — brief RP disruption is
the correct trade vs. letting an attacker keep minting. The normal
sign-before-publish safety is intentionally skipped; that asymmetry is
the whole point of a separate emergency path.

**Parameter defaults (all per-issuer configurable, none compiled-in
constants — §0):** rotation period 90d; JWKS `Cache-Control: max-age`
10m; T_publish default 24h (tolerates misbehaving RP caches — the
platform's *own* dashboards are controlled RPs that implement
unknown-`kid` refetch and can run a far tighter cadence); access/id
token TTL ≤15m (align with the existing 5-min services-token order of
magnitude); T_retire = token TTL + 5m skew. Conservative defaults
ship; operators/customers tune down when their RP population allows.

### 4.7 Concrete design (grounded against the code 2026-05-16)

*Reuse (no reinvention):* the request/response handler surface
(`src/js/dispatcher.zig` Request: `method/path/host/query/body/
headers/cookies/session`; `response.status/headers/cookies`;
`src/js/globals.zig`), per-tenant `kv.*`, the embedded-JS-library
shipping path (`evalSnippet` of `src/js/bindings/*.js` into every QJS
context — `oidc.js` ships exactly like `oauth.js`/`retry.js`), the
per-request opaque sid (`__Host-rove_sid`, `src/js/session.zig` —
*the* documented "bind the sid to your user in your own kv" model),
`http.send` with a stable `handle` + `on_result` module for the §4.6
rotation callback, `request.host` for the §0 host-relative
derivation, and `src/acme/crypto.zig`'s OpenSSL patterns
(keygen/PEM/JWK-thumbprint) as the template for the RSA equivalents.

*Shape — the IdP is the `__auth__` system tenant.* `oidc.provider(cfg)`
mirrors `oauth.fromConfig` (config from `_config/oidc/{name}`, state
under `state/oidc/...`); the IdP is a bootstrapped system tenant
(`createInstance("__auth__")` + `assignDomain("auth.{system_suffix}",
"__auth__")` — the exact Phase-1 `__replay__` pattern) whose
`web/auth/index.mjs` deployment routes `/.well-known/openid-
configuration`, `/.well-known/jwks.json`, `/authorize`, `/token` by
`request.path`. `iss` + every endpoint derive from `request.host`
(§0). Dashboards (admin/replay/logs) stop doing their own auth and
become pure relying parties: redirect unauthenticated users to
`auth.{system_suffix}/authorize`, exchange the code, establish their
**own host-only session** (§5.3) bound to the `id_token`.

*Clarification the grounding forced — cookies are host-only, so the
IdP runs its own magic-link.* `__Host-rove_sid` has no `Domain=` and
the §5.3 decision keeps it host-only, so the dashboard's cookie on
`app.{sys}` is **not** sent to `auth.{sys}`. That is the *correct*
OIDC shape: the human authenticates **to the IdP** at
`auth.{system_suffix}`. So magic-link (email OTP → bind the
per-request sid to a user in **`__auth__`'s** kv via the standard
`session.zig` model) is the IdP's authN step — "magic-link stays the
authN primitive, OIDC wraps it" (§4.1) is satisfied with the
magic-link logic *living in the `__auth__` IdP*, not `__admin__`.
`authenticateSession` (admin-app.db-specific) is **not** what OIDC
uses; the IdP manages its own `session/{sid}` rows in `__auth__` kv —
fully dogfooded, no platform change to `session.zig`.

*Must-build:* an **RS256 signer + RSA keygen + RSA JWK/JWKS + RFC 7638
RSA thumbprint in Zig** — `crypto.zig` exposes RSA *verify* only
(signing a private key from customer JS is the thing we won't do);
`jwt/root.zig` is HS256-only. Port `src/acme/crypto.zig`'s OpenSSL
approach (RSA via `evp.h`/`rsa.h`/`bn.h`, already in that cImport).
Plus the `web/auth/` deployment + the `oidc.js` library + the
discovery/JWKS/authorize/token route logic + PKCE + the §4.6 rotation
wiring.

*Decisions (accepted 2026-05-16):*

- **A — RS256 key custody: HYBRID.** Generation + signing are Zig
  bindings; the keyset is stored in `__auth__` kv as **opaque blobs
  the JS never parses** (so it replicates via the normal writeset and
  the §4.6 rotation state-machine works unchanged — dogfooded storage
  + rotation), while RSA private bytes stay inside Zig. JS calls a
  `crypto.oidcSign(kid, signing_input)`-style binding; never holds the
  key.
- **B — admin/replay/logs become pure RPs: YES.** authN moves to the
  `__auth__` IdP; the existing magic-link/session JS is *relocated*
  into the IdP tenant (customer-equivalent JS), each dashboard gets a
  thin RP shim (redirect→authorize→code→own host-only session). This
  is a behavior change to today's admin login and the largest
  blast-radius item — sequence it carefully (see roadmap).
- **C — RS256 signer placement:** extend the `src/acme/crypto.zig`
  OpenSSL approach (RSA via the `rsa.h`/`bn.h` already in scope) — a
  sibling of the EC code — not the HS256 `jwt` module.

First increment + gate: discovery + JWKS + the RSA keygen/sign Zig
binding, behind a Pebble-style **OIDC conformance smoke** — a scripted
RP that runs the full authorization-code + PKCE flow against the
`__auth__` IdP and validates the `id_token` signature against the
published JWKS (proves host-relative `iss`, RS256, and the
magic-link→code→token chain end-to-end), then a follower/second-host
check that the same `iss`/JWKS works there (host-relative invariant).

**Landed + conformance-verified 2026-05-16** (`scripts/oidc_smoke.py`,
commits `eb0f823` 3-1/3-2 · `1e32329` 3-3 · `d144977` 3-4 · `cfa4014`
3-5 · `2e6faa3` 3-6 gate). The smoke passes **twice, non-flaky**:
discovery → magic-link → `/authorize`(PKCE) → `/token` → `id_token`
**cryptographically RS256-verified (pure-Python) against the published
JWKS** → refresh grant → §0 (2nd host ⇒ `iss` reflects it) → §4.6
rotation (`next`→promoted; a pre-rotation token still verifies against
the retiring key). This is the behavioral proof of the whole 3-1→3-5
chain.

Two grounded corrections the gate forced:
- **Client registry lives at `_oidc/config/{name}`, not
  `_config/oidc/*`.** `_config/` is a platform-reserved prefix
  (handlers/admin can't write it; `reserved.zig`), and its only
  writer — `config_mirror` via `loop46 seed` — is **not wired into
  the files-server release/loader path** (the loader's doc claims it;
  the code doesn't). This is a *pre-existing platform gap that also
  affects `oauth.js`'s `_config/oauth/*`* — flagged as a separate
  follow-up, not OIDC's to fix. The IdP's registry is operational
  data (operators add/remove RP clients without a redeploy), so a
  normal admin-managed kv key is the more correct model anyway.
- The `__auth__` IdP's own state (`_oidc/keyset|session|code|magic`)
  is under the **non-reserved** `_oidc/` prefix — verified against
  `reserved.zig`'s `PLATFORM_KV_PREFIXES` — so the handler writes are
  allowed.

**Remaining (3-6 part 2):** the Fork-B dashboard→RP migration
(relocate admin's magic-link into `__auth__`; replay/logs/admin become
RPs; **admin last** — the live-auth-regression risk). Sequenced after
the gate deliberately: it is now *safe* because the IdP is proven.

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

**Phase 1 — two-domain split (cheap, high-signal).** Introduce the
system-domain config; decouple `__admin__`/`__replay__`(/future
`__auth__`) bootstrap seeding + `admin_api_domain` default from the
customer `public_suffix`; seed them as explicit `domain/{host}`
entries under the system domain. No reserved-label code (none exists).
Smoke: with distinct customer + system suffixes, `foo.{customer}` →
tenant `foo` (wildcard) and `app.{system}` / `replay.{system}` →
system tenants (explicit map); the two suffixes do not cross-resolve.
No OIDC, no cert code.

**Landed 2026-05-15.** `--system-suffix` (required, must differ from
`--public-suffix`); `finalizeCli` enforces both + derives
`admin_api_domain` = `app.{system_suffix}`; replay bootstrap seeds
`replay.{system_suffix}`. 4 inline `finalizeCli` tests. Test domains
mirror prod: `rewindjsapp.localhost` (customer) / `rewindjscom.localhost`
(system); `loop46.localhost` retired repo-wide in `scripts/`. New
committed `scripts/gen-dev-cert.sh` (one cert, both wildcard SANs —
rove-h2 is single-`SSL_CTX` until §3.3). Verified end-to-end:
`zig build` + 4 cli tests green; `cookie_auth_smoke` (admin on
`app.rewindjscom.localhost`), `signup_smoke` (customer tenants on
`rewindjsapp.localhost`), `ctl_smoke` (3-node `/_system/*`) all pass.
`deployment.md` has no literal worker invocation, so its prose stays
Phase 4; the actual invocation scripts (`rove-loop46-serve.sh`,
`systemd/rove-loop46.service`) carry the new required flag.

**Pending follow-up (apex marketing).** Seed a `__marketing__` system
tenant + `assignDomain("rewindjs.com", "__marketing__")` for the apex
landing site (§1). Trivial extension of the bootstrap that already
seeds `__admin__`/`__replay__`; not blocking — slots in alongside the
marketing content + a second invocation of `rove-lego-renew.sh` with
`BASE_DOMAIN=rewindjs.com` (§3.1). Test: explicit-map entry for the
apex coexists with the wildcard subdomain entries on the same system
domain; `curl https://rewindjs.com/` hits the marketing tenant,
`curl https://app.rewindjs.com/` still hits `__admin__`.

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

**Phase 3 — OIDC.** (a) discovery + JWKS serving `next`/`current`/
`retiring` (smallest; unblocks RP testing). (b) authorization-code +
PKCE, state in `__auth__` kv; implements the §4.6 keyset state machine
+ scheduled-rotation callback + opaque refresh tokens.
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

- Key rotation: **resolved in §4.6**. Self-scheduling **verified
  against `docs/http-send-plan.md` 2026-05-15** — it is the §10.4-cron
  / §10.5-order-timeout cookbook pattern (stable handle +
  internal-routed self-`url` + future `fire_at_ns`; arm atomic with
  the keyset writeset per §6). One correctness finding folded into
  §4.6: "duplicate fire is a no-op" only holds with a §7-style
  `version`-keyed `_processed` dedupe marker, because a
  leadership-change concurrent double-fire would otherwise mint two
  RSA keys. No remaining blocker for Phase 3b.
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
- §3.2 cert-at-rest: whether `__root__.db` pages are encrypted, and if
  not, whether the `cert/{host}` private-key payload gets its own
  encryption before the envelope-2 write. Bounds the "private keys in
  raft log/snapshots/backups" caveat. Decide during 2b implementation;
  does not block the architecture.
- **Pre-existing platform gap (found during 3-6):** `config_mirror`
  (`_config/**.json` → kv) is only called by `loop46 seed`; the
  files-server release/loader path does **not** invoke it, though
  `deployment_loader.zig`'s doc-comment claims it does. So
  `_config/*` from a files-server-deployed bundle never reaches kv.
  This affects `oauth.js`'s `_config/oauth/*` (customer OAuth config
  via the normal deploy path), not just OIDC — OIDC sidestepped it by
  using the admin-managed `_oidc/config/*` key. Either wire
  `mirrorConfigToKv` into the loader (matching its doc) or update the
  doc + define the supported config-provisioning path. Not OIDC's to
  fix; tracked here so it isn't lost.
