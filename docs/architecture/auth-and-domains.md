# Auth & custom domains

> 🟢 **As-built reference.** OIDC (dogfooded as a customer library), custom-
> domain TLS via in-tree ACME, and the service/admin authorization model. Owns
> `src/acme/`, `src/cp/acme.zig`, the TLS/SNI path in `src/h2/tls.zig`, the
> crypto seam in `src/js/bindings/crypto.zig`, and the `globals/oidc.js` shim.
> Why: [decisions.md §6](../decisions.md) (verified accurate against the code).
> Custom-domain *cert serving* is part of [routing-and-ingress.md](routing-and-ingress.md);
> *issuance* lives here and in the control plane.

## The shape in one paragraph

Two registrable domains split the surfaces (customer wildcard `*.rewindjs.app`;
system surfaces on `rewindjs.com`), and **nothing in the code names them** —
every issuer/redirect/route is derived from `request.host`. The OpenID Connect
identity provider is the `__auth__` system tenant running the *same* `oidc.js`
library customers use; RS256 signing is a hybrid (keys generated and signed in
Zig/OpenSSL, opaque bytes in JS). Custom-domain certs are issued in-tree by a
leader-elected ACME HTTP-01 issuer on the control plane and replicated through
the CP directory's `cert/{host}` axis, so any front door can terminate TLS for
any host.

## Code map

| File | Role |
|---|---|
| `src/tenant/root.zig` | `resolveDomain(host)` / `assignDomain(host, instance)` — explicit `domain/{host}` map + wildcard fallback; the `__auth__` tenant constant. No platform-domain literals. |
| `src/acme/crypto.zig` | ACME EC P-256 keygen, JWK + RFC 7638 thumbprint, PEM I/O (OpenSSL). |
| `src/acme/client.zig` | RFC 8555 state machine (newAccount/newOrder/authz/finalize) over libcurl, with nonce retry. |
| `src/acme/responder.zig` | The `:80` HTTP/1.1 challenge responder (token → key-auth), isolated from the h2 stack. |
| `src/cp/acme.zig` | Leader-gated issuer thread on `rewind-cp`; `directory.setCert` writes the `cert/{host}` CP-directory axis. |
| `src/h2/tls.zig` | SNI `host_store` + per-host `SSL_CTX`, `reloadCustomCerts` mtime poll, optional mTLS. |
| `src/js/bindings/crypto.zig` | RSA keygen + `crypto.oidcSign(priv_pem, signing_input)` + JWK export (the hybrid seam). |
| `src/js/globals/oidc.js` | `oidc.provider(config)` (IdP) + `oidc.rp(config)` (relying-party helper). |
| `src/js/globals.zig` | `platform.scope(id).kv.*` — the explicit cross-tenant accessor (replaced `X-Rove-Scope`). |
| `src/js/worker_dispatch.zig` | HS256 services-token mint; `is_root` plumbing; `/_system/*` root-token gate. |

## OIDC IdP (`__auth__` tenant)

- The IdP is the `__auth__` system tenant running `oidc.provider(config)` — the
  same library a customer would call. It serves discovery
  (`.well-known/openid-configuration`), JWKS, `/authorize` (PKCE S256 mandatory),
  and `/token`, all **host-relative** off `request.host`. Magic-link auth is its
  own, binding a `__Host-` session cookie to `_oidc/session/{sid}`.
- Clients are registered at `_oidc/config/{name}` (runtime-mutable, with a
  deploy-mirrored `_config/oidc/{name}` fallback). `redirect_uris` may use
  placeholders — `${ISSUER_ORIGIN}`, `${ISSUER_HOST}`, `${ISSUER_PARENT}` —
  resolved at token-exchange from the IdP's own host, so a sibling dashboard on a
  parent domain needs no compiled-in literal.
- v1 scope cuts (explicit): dynamic client registration, consent screens, token
  revocation, `userinfo` beyond core claims, front/back-channel logout.

## RS256 crypto seam (hybrid)

Keygen and signing are in Zig/OpenSSL; JS calls `crypto.oidcSign(priv_pem,
signing_input)` and receives a base64url signature — **key bytes never live in
JS**. The keyset is stored as opaque blobs in the tenant KV and rotated by a
dogfooded state machine (`next` → `current` → `retiring` → `retired`; JWKS
publishes all signing-eligible phases, only `current` signs). Rotation is driven
by `webhook.send` with a stable handle and internal-routed back to the IdP — note
that internal dispatch carries no schedule-id header, so dedup is single-key
last-write-wins + sign-only-`current`, not a `_processed` marker.

## Custom domains & ACME

- **Two-domain split**: customer wildcard `*.rewindjs.app` (DNS-01 via the
  external lego script, unchanged); system `rewindjs.com` (+ wildcard); customer
  **custom** FQDNs (HTTP-01, in-tree). `--public-suffix` and `--system-suffix`
  are required CLI flags (must differ) — the only place a domain enters config,
  and it seeds explicit `domain/{host}` entries for the system tenants at boot.
- **HTTP-01 issuance**: a **leader-elected issuer thread** on `rewind-cp`
  (`src/cp/acme.zig`; `client.zig` drives the RFC 8555 order with one
  long-lived EC account key under `{data_dir}/acme/`). Each tick the directory
  leader computes the work-list (`collectUncertedHosts` — mapped hosts lacking
  `cert/{host}`, filtered by the public/system suffixes), runs the client, and
  writes `directory.setCert`. The challenge is served by `rewind-front`'s `:80`
  listener forwarding to the CP's `GET /_cp/acme-challenge?token=` (the
  issuer's in-memory challenge store). Inert unless `REWIND_ACME_DIRECTORY` is
  set. Two deadlock guards: the blocking `issue()` runs off the request loop
  (else it self-deadlocks the validation it depends on), and `setCert` proposes
  through the mutex-guarded bridge whose pump advances on its own thread.
- **Cert state & replication**: `cert/{host}` is an axis in the CP
  `__directory__` group (placement-independent), written via
  `directory.setCert` / `POST /_control/cert`, read via `GET /_cp/cert(s)` —
  this **replaced V1's per-cluster envelope-2 `__root__.db` path**. The front
  door's `CertSync` pulls issued certs into SNI (`putHostCertInMemory`).
  **The CP leader issues; every front serves.** Proven end-to-end against
  Pebble: `scripts/smoke/cp_acme_issue_smoke.py` (issue → cert axis → replicate →
  CertSync → the front serves the issued cert by SNI); the cert axis and edge
  TLS also by `cp_cert_smoke` / `cp_tls_edge_smoke`.
- **DNS-01 for customer custom-domain wildcards is deferred**
  (provider-specific); wildcards via manual `POST /_control/cert` for now.
- **mTLS** (`--require-client-cert-ca`) plumbs verification into every per-host
  `SSL_CTX` (operator-level in v1).

## Host-relative invariant

No platform-domain literal appears in the auth/domain code path. The OIDC issuer
is `https://{request.host}`; JWKS / authorize / token / discovery all derive from
it; `request.host` is carried on outbound calls and `internal_routing` resolves
the system domain for self-calls. This is an enforced invariant — treat any
hard-coded domain in this path as a bug.

## Service & admin authorization

- **Service-to-service** (worker → standalone files/logs): a shared-secret HS256
  JWT (`LOOP46_SERVICES_JWT_SECRET`), minted at `/_system/services-token` (5-min
  TTL), with scoped `caps`. Machine-to-machine — deliberately **not** OIDC
  (decisions.md §6).
- **Admin / root**: `is_root` is an OIDC `sub` in the `_admin/operator/*`
  allowlist (seeded from `LOOP46_OPERATOR_EMAILS`). Admin app paths require an
  operator OIDC session; `/_system/*` accepts a separate root **token**
  (`LOOP46_ROOT_TOKEN`) as an independent operator-recovery surface.
- **Cross-tenant access** is the explicit `platform.scope(id).kv.*` accessor, not
  a global rebind. `X-Rove-Scope` was **deleted** — do not reintroduce it
  (decisions.md §6). (The `LOOP46_*` env names persist because the internal
  `loop46` rename is deferred — decisions.md §1.1.)

## Known limitations (as-built)

- **ACME renewal / expiry-driven reissue is the sole tracked follow-up** — the
  issuer only fires when `cert/{host}` is absent; timer-driven renewal is not
  built.
- **Third-party-RP `id_token` signature verification** (`oauth.verifyIdToken`) —
  the chain exists in `oidc.rp` but isn't exposed.
- **Per-host / per-tenant mTLS CA** is deferred (operator-level only in v1).
