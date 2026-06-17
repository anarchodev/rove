# Step 3 — auth consolidation: execution plan

`rewind-cli-plan.md` §7 is the *design* (the two-planes target, the
tenant-scoped capability token, the log-server-as-chokepoint rationale,
the rejected alternatives). This doc is the *execution* plan: what is
already built, what is left, and the order to do it in.

**The headline:** Step 3 is much closer to done than "finish OIDC"
implies. The OIDC machinery is *written* — the provider+RP library, the
`__auth__` IdP app, the admin dashboard's RP guard, and the
tenant-scoped JWT mint/verify primitives all exist in the tree. What
remains is **wiring three written pieces together, deploying one tenant,
and closing one security gap** — not designing or building OIDC from
scratch.

Locked decisions live in `architecture/auth-and-domains.md` (the
two-planes model, `platform.scope` cross-tenant grant, no `X-Rove-Scope`)
and `decisions.md`. Don't re-litigate those here.

## What already exists (the ledger)

| Piece | Where | State |
|---|---|---|
| Tenant-scoped JWT mint (`{exp, caps, tenant}`) | `src/jwt/root.zig:80-173` (`MintOptions.tenant`) | ✅ built + tested |
| Tenant-scoped verify | `src/jwt/root.zig:200-208` (`verifyWithCapAndTenant`) | ✅ built + tested — rejects unscoped tokens, wrong-tenant tokens |
| Capability enum (`release`/`admin-kv`/`raft-snapshot`) | `src/jwt/root.zig:55-72` (`Cap`) | ✅ built — **missing `logs-read`** |
| Services-token mint endpoint | `src/js/worker_dispatch.zig:1266` (`handleServicesTokenMint`) | ⚠️ mints **unscoped** (`{.exp_ms}` only, line 1290) |
| OIDC provider + RP library (dogfooded) | `src/js/globals/oidc.js` (~40k, `oidc.provider`/`oidc.rp`) | ✅ written |
| `__auth__` IdP tenant app (magic-link + provider) | `web/auth/index.mjs` + `web/auth/_config/oidc/default.json` | ✅ written — **not deployed** |
| `__auth__` instance-id constant | `src/tenant/root.zig:109` (`AUTH_INSTANCE_ID`) | ✅ built |
| Admin dashboard RP guard | `web/admin/_middlewares/index.mjs:33` (`oidc.rp("default").guard()`) | ✅ written |
| Admin RP token exchange | `web/admin/_rp/complete.mjs` | ✅ written |
| Session/RP plumbing | `src/js/session.zig` | ✅ built |
| Interim admin (bearer `ADMIN_OPS_SECRET`) | `web/admin_interim/index.mjs` | ⚠️ interim — dies with the dashboard |
| Log-server JWT gate | `src/log_server/standalone.zig:389-416` | ❌ uses `jwt.verify` (no tenant scope) — the audit's open latent-critical |
| `rewind-ops` operator CLI | `src/cli/ops.zig` | ✅ built (raw-secret auth) |
| `rewind` customer CLI | — | ❌ not built (deferred — needs OIDC) |

So the substrate exists. The work is connective.

## Two tracks

The work splits into two tracks with **different gating dependencies**:

- **Track A — close the log-server gap.** Tenant-scope the caps and
  route logs through `__admin__`. Closes the audit's latent-critical.
  **Has no OIDC dependency** — it rides entirely on the JWT primitives
  that already exist, and can land before the IdP is deployed.
- **Track B — stand up the operator OIDC plane.** Deploy `__auth__`,
  light up the dashboard, retire the raw-secret/browser-token surfaces,
  then build the customer CLI. **Gated on one deploy** (`__auth__`), but
  the app code is already written.

They share the tenant-scoped token (the §7 "single high-leverage
change"), but A doesn't *wait* on B.

---

## Track A — log-server gap (no OIDC dependency)

Dependency order. A1→A2→A4 is the critical path; A3 and A5 can land in
parallel once A1 is in.

> **Status (2026-06-16): Track A COMPLETE (A1–A6) + runtime-verified.** The
> enforcement boundary is closed (`scripts/log_tenant_scope_smoke_v2.py`:
> unscoped / cross-tenant / missing-cap → 401, scoped → 200), the worker minter
> (the `rewind-logs.internal` door) is proven (`scripts/logs_door_smoke_v2.py`),
> and the admin chokepoint + browser-token removal (A5) is verified on the B2
> OIDC harness (`scripts/oidc_rp_smoke_v2.py`: operator log query → 200,
> unauth → 401, non-operator → 403). A5 required a platform dispatch fix
> (continuations skip middleware; resume walk-up — commit `452cf6a`).
>
> **Discovery that reorders the rest:** the §7 design cites the worker→
> log-server S2S path as "already exists" (`worker_log.zig`), but in the
> **`rewind-worker` binary it is not wired** — `WorkerCtx` (`main.zig:706`)
> sets neither `services_jwt_secret` nor `log_public_base`, and nothing reads
> a log-base env. The worker-mediated log path is vestigial from Phase 5.5;
> today the log-server is reached **directly** (smoke client; would-be
> dashboard). So A2/A3 are genuinely **new wiring** (NodeState fields + env +
> a fetch-engine door), not the trivial mint-tweak the size estimate implied.
> A4 was therefore landed first as the standalone enforcement fix: the
> log-server now *rejects* any non-tenant-scoped read token regardless of who
> mints it, which is the actual security property. A2/A3/A5 make the worker
> the prod minter on top.

### A1. Add the `logs-read` capability — *XS*
`src/jwt/root.zig:55-72`. Add `pub const LOGS_READ = "logs-read";` to
`Cap`, plus a mint/verify test. Already named in the module doc comment
(line 13) — just not declared. No dependencies.

### A2. Mint tenant-scoped tokens for log queries — *S*
`src/js/worker_dispatch.zig:1266`. `handleServicesTokenMint` currently
mints `{.exp_ms}` only (line 1290). The log-read path needs a token
carrying `{exp, caps:[logs-read], tenant}`. The cleanest shape is a
dedicated internal mint the admin chokepoint uses (the browser path goes
away in A5/B), not a widening of the public dashboard token. Depends on
A1.

### A3. Cross-tenant `rewind-logs.internal` fetch target — *M*
The one genuinely new mechanism. Mirror the proven `blob.internal`
host-rewrite (`fetch_engine.zig:708`, SigV4 attach at `:567`) but:
- privileged: only `__admin__` may form the host;
- **cross-tenant**: admin → *any* tenant's logs, vs `blob.internal`'s
  own-tenant scope — analogous to `platform.scope`'s admin cross-tenant
  kv grant (§7, `rewind-cli-plan.md:540`);
- the worker attaches the A2 tenant-scoped `logs-read` token; the
  handler JS never touches key material.
Independent of A2's exact mint shape; can be built in parallel.

### A4. Enforce tenant scope in the log-server — *XS*
`src/log_server/standalone.zig:401`. Swap
`jwt.verify(secret, token, now_ms)` →
`jwt.verifyWithCapAndTenant(secret, token, now_ms, Cap.LOGS_READ, route.tenant_id)`.
**This is the literal line that closes the audit finding.** The error
mapping already handles `WrongTenant`/`MissingCap` (lines 405-407) — the
machinery is waiting for the call. Delete the stale comment at
lines 389-393. Note `route` is parsed *after* the gate today (line 427);
the tenant must be in hand before verify, so the route parse moves above
the JWT gate. Depends on A1 (the cap) + A2 (scoped tokens in flight).

### A5. Admin chokepoint + drop the browser-held token — *M* — ✅ done/verified
`web/admin/index.mjs` exposes `GET /v1/logs/{tenant}/(list|count|show/{id})`,
which issues the A3 door fetch (`on.fetch("http://rewind-logs.internal/v1/…")`)
operator-gated and relays the log-server JSON; `api.js`'s `logFetch` now calls
that same-origin chokepoint (RP session cookie) instead of cross-origin to the
log-server with a browser-held services token. **Verified** by
`scripts/oidc_rp_smoke_v2.py` (operator → 200 records, unauth → 401,
non-operator → 403).

> **Required a platform fix (commit `452cf6a`):** routing the log read through
> `__admin__`'s default-export-routed, middleware'd handler exposed two
> dispatch bugs, both fixed: (1) `_middlewares` ran on the `onFetchResult`
> *continuation* and 401'd it — the auth gate belongs at the inbound trust
> boundary, so continuations now skip middleware (`Activation.isContinuation`);
> (2) the bound-fetch resume resolved the module by the path-derived name and
> hit `ResumeNoBytecode` — it now uses inbound's `findBytecode` walk-up to find
> the `index.mjs` that actually ran. `__system/*` modules were already
> special-cased for the *same* footgun; this generalizes the fix.
>
> The dead `filesFetch`/services-token path (dissolved files-server) is flagged
> in `api.js` for the separate files reckoning — logs no longer touch it.

**Track A exit (reached):** the log-server rejects every non-tenant-scoped read
token (A4); the worker mints tenant-scoped tokens only for `__admin__` via the
door (A2/A3); the dashboard reads logs through the operator-gated admin
chokepoint with no browser-held token (A5). **None of A1–A5 needed OIDC** (A5's
verification rides the B2 OIDC harness, but the mechanism is OIDC-independent).

---

## Track B — operator OIDC plane (gated on `__auth__` deploy)

> **Status (2026-06-16):** **B1 + B2 done at the local/cluster level + verified.**
> `scripts/oidc_smoke_v2.py` stands up `__auth__` end-to-end (discovery,
> magic-link, PKCE auth-code, `/token`, **id_token RS256-verified vs JWKS**,
> refresh — 10/10). `scripts/oidc_rp_smoke_v2.py` then lights up the **dashboard
> RP**: `__auth__` (IdP) + `web/admin` (RP) with the full handshake — `/_rp/login`
> → IdP `/authorize` → magic-link → `/_rp/callback` → poll → session — operator
> → **is_root:true**, non-operator → **is_root:false**. Required new harness
> support: a second, TLS-terminating front (`spawn(tls_idp=True)`) because the
> RP token exchange is server-side and the IdP signs `https` issuers (§0); the
> worker tenant door pins RP→IdP to it. What remains for B1/B2 is the
> **production publish** of `__auth__` + `web/admin` (a `/publish` to the real
> TLS cluster — billed, gated) + prod config (resend key, operator allowlist).
> B3–B5 then fall out, and **A5** (route admin logs through the door) is now
> testable on the B2 harness.

### B1. Deploy the `__auth__` IdP tenant — *S (deploy, not build)* — ✅ local/verified
The app is written (`web/auth/index.mjs`): magic-link authN + dogfooded
`oidc.provider()`. Deployed like any tenant — provision `__auth__`, deploy
the bundle (handler + `_config/oidc/default.json`, which config-mirrors to
kv on release); reachable via the wildcard host (`__auth__.{suffix}`) or an
explicit `auth.{suffix}` alias. **Verified locally** by
`scripts/oidc_smoke_v2.py`. **This is the single unblock** for everything
else in B. The chicken-and-egg the customer CLI waits on dissolves here.

> **Discovery:** unlike the log-server door, `__auth__`'s plumbing was fully
> wired — the only gaps were operator data-seeding (config/clients via the
> move-secret `v2-kv` seam; no `__admin__`/files-server bootstrap needed) and
> the actual prod publish. The V1 `scripts/oidc_smoke.py` (retired loop46) is
> superseded by `oidc_smoke_v2.py`.

### B2. Light up the admin dashboard end-to-end — *S* — ✅ local/verified
The RP guard (`_middlewares/index.mjs`) and token exchange (`_rp/complete.mjs`,
`_rp/jwks.mjs`) are written. **Verified locally** by
`scripts/oidc_rp_smoke_v2.py`: deploy `web/admin` to `__admin__`, seed the RP
config + operator allowlist (via the `v2-kv` seam), and drive the full OIDC
login → session-cookie → guarded `/v1/session` loop (operator is_root, customer
not). Needed the **TLS-front smoke harness** (the RP→IdP token exchange is
server-side and the IdP signs `https` issuers, so the hop must ride real TLS;
the door pins it to a second TLS front). Note: only the `web/admin` *handler*
files were exercised; the browser SPA (`_static/api.js`) is still stale vs the
dissolved files-server — its cleanup + the **A5** log-chokepoint wiring both
ride this same admin-app surface and harness next.

### B3. Retire `ADMIN_OPS_SECRET` — *S*
Fold `web/admin_interim/`'s `/ops/assign-domain` + `/ops/resolve-domain`
into the full admin app behind the OIDC session. Drop the bearer secret
(`rewind-cli-plan.md:565`). Depends on B2.

### B4. Move operator secrets off the shell — *S (delivery, not code)*
Operator day-to-day becomes the dashboard login; behind it the admin
mints short-lived scoped caps per op. `REWIND_MOVE_SECRET` becomes
cp↔worker S2S only; `REWIND_ROOT_TOKEN` stays break-glass; `rewind-ops`
keeps only the break-glass path. Per §7 "After: the standing secrets" —
move-secret is *moved, not eliminated* (its own quiet high-privilege key,
deliberately not folded into the busy services-HMAC). Depends on B2.

### B5. Build the `rewind` customer CLI — *M*
Shares `src/cli/common.zig` with `rewind-ops` (bundle classifier + mint),
but authenticates via OIDC (device/redirect login → session) instead of
raw secrets. Verbs: `deploy` / `release` / `logs <tenant>`, each
obtaining a tenant-scoped cap after one login. Depends on B1.

**Track B exit:** an operator holds **one** thing day-to-day — their
dashboard login. One internal HMAC signs every short-lived scoped token;
move-secret + S3 creds sit in platform config; root token is break-glass;
customer auth is the separate `__auth__` plane.

---

## Recommended sequence

```
A1 ─┬─ A2 ──┐
    └─ A3 ──┴─ A4 ── A5        (Track A — closes the security gap, no OIDC)
B1 ─┬─ B2 ── B3 / B4           (Track B — operator plane)
    └─ B5                       (customer CLI)
```

1. **Track A first** — it closes the standing security risk and depends
   on nothing in B. Smallest, highest-value, unblocked today.
2. **B1 (`__auth__` deploy) next** — the one true unblock; the app is
   already written, so this is bring-up + config, not engineering.
3. **B2–B5 fall out** once B1 is live and verified.

The temptation is to read "finish OIDC" as a big build. It isn't. The
critical path to *closing the audit finding* is A1+A4 (two near-trivial
edits) plus A2/A3/A5 to route through the chokepoint. The critical path
to *the operator plane* is a single deploy (B1) of already-written code.

## Verification

- **Track A:** a smoke that mints a token scoped to tenant X and proves
  it (a) reads X's logs and (b) is rejected for tenant Y — plus that the
  log-server has no reachable public route. Extends the
  `ctl_smoke_v2.py` shape; the negative case is the point.
- **Track B:** an OIDC login smoke against a deployed `__auth__` —
  magic-link → session → guarded admin RPC succeeds; unauthenticated RPC
  is rejected.

## Out of scope (per §7)

Binary deploys (`/deploy`), runtime cluster management (no `addCluster`
endpoint — separate gap), and live log *tail* (`/_system/logs/stream` —
a separate future feature, not a reason the indexed surface changes).
