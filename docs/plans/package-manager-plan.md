# Package manager — engine support for deploying packages

Status: **proposal, 2026-07-09.** No code yet. Converged in a design
conversation; this doc is the design + phased build plan. Supersedes the
direction sketch in memory `project_globals_to_packages` and the
`$.*`-namespace idea (both explicitly rejected below, §12).

Related: `docs/strategy/saas-in-a-box.md` §6 (the three rungs — this is
the machinery under Rung 3), `docs/decisions.md` §3.3 (durability as
JS-shim — this finishes it, doesn't contradict it),
`src/files/app_manifest.zig` (the reserved-inert bundle manifest this
plan makes the deploy path *consume*), `docs/plans/rewind-cli-plan.md`
(the deploy/publish client that becomes the resolver bridge).

---

## 0. What this is, and the scope boundary

Rewind ships a curated first-party JS standard library today as
**ambient globals baked into the worker binary** — 26 files in
`src/js/globals/*.js`, eval'd into the shared QuickJS base snapshot at
`globals.installStatic` (`src/js/globals.zig:1957`), then hardened with
`delete globalThis._system`. This is the *pre-registry form of
packages*: a frozen, platform-versioned set every tenant shares.

The goal is a best-of-class package manager. The scope of **this**
change (in `rove`) is deliberately narrow:

| | In scope — `rove` engine | Out of scope — `rewind-apps` |
|---|---|---|
| What | **Engine support for *deploying* packages**: consume a manifest's `dependencies`, bake a hash-pinned resolved graph into a tenant's deployment, route `@scope/pkg` specifiers through the module loader, gate capabilities. Plus the **two durability chores** (§1.C) that make the wrapper libs packageable. | **The package store / registry**: naming → versions → hashes, publish API, discovery, storage-of-record. A rewind-app (a tenant that serves packages), dogfooded like docs/auth/admin. |
| Talks to a registry? | **No.** The engine consumes a hermetic, hash-locked bundle — content-addressed, exactly like handler bytecode today. | Yes — it *is* the registry. |

The **CLI/deploy client is the bridge** (`docs/plans/rewind-cli-plan.md`):
it resolves specifiers against the registry app, writes the lockfile, and
hands the engine a self-contained, hash-locked deployment. **Resolution
is client/app-side; the engine only does deterministic baking +
linking.** (Model: `deno vendor` / Go's module cache — by deploy time
everything is resolved and content-addressed.)

---

## 1. Locked decisions

**A. Surface & mechanism.**
1. **Explicit ES imports over `@scope/pkg` specifiers** are the author
   surface — `import { provider } from "@rewind/oidc"`. Not ambient
   globals; not a `$.*` namespace (§12 for why both were rejected).
2. **First-party scope = `@rewind/*`** (product-facing; `rove` is the
   engine, invisible to customers). Reserved in the registry app.
3. **Deploy-time resolution, baked — not per-request.** The tenant's
   lockfile is resolved once at deploy and recorded in the manifest;
   each deploy bakes *that tenant's* pinned versions. Zero runtime
   resolution cost. Adding/bumping a package rides a redeploy.
4. **Flat app surface, encapsulated package internals** (§4).
5. **Content-addressed, hash-locked** — multiple versions coexist as
   distinct blobs at distinct hashes; the loader resolves hash-qualified
   specifiers with no ambiguity (§4).
6. **Compile validates resolution; runtime re-resolves per load**
   (RE-CORRECTED 2026-07-09, verified — supersedes both the original
   "compile ⟂ resolution" claim AND the interim "resolved names bake
   into bytecode" correction; full model in `pm-compile-cache-fix.md`).
   quickjs resolves + LOADS every import at *compile* — compile is the
   deploy's import-validation gate, so packages must be staged (leaves
   first) with the resolver live before handlers compile. But the
   serialized bytecode carries only the as-written specifiers plus the
   module's OWN filename; every load re-resolves through the live
   loader with that filename as base. So `bytecode = f(source,
   filename)` — version pins live in the snapshot's resolver, and a
   package compiles under its `/pkg/<pkg_hash>/…` name (its module
   identity + its imports' resolution base). Consequence: the deploy
   path keeps NO source-keyed compile cache (it would skip validation
   and conflate filename contexts), and recompile-per-deploy is correct
   by construction. Enforced by a byte-equality test + the PM deploy
   smoke's repin leg.

**B. The tiering rule (primitives vs wrappers).**
7. **Ambient iff it's a *primitive*** (privileged capability surface *or*
   pure stdlib). **Package iff it *composes*** over the public surface.
   This replaces the old fuzzy "durability stack is frozen" carve-out:
   `webhook` + `wake` are durability *primitives* (frozen); `retry` /
   `schedule` / `email` are durability *wrappers* (packages).
8. **`webhook` + `wake` stay ambient/frozen by *policy*, not just
   mechanics** — the at-least-once delivery + durable-timer contracts are
   security-critical infra the platform must own; a tenant must not pin
   its own delivery guarantee. `overrides` (§4) cannot retarget them.

**C. Chores first (do before lifting the libs).** Two prerequisites make
the wrapper tier genuinely "compose over the public surface" — landed
*first* so the tier split ships clean from day one (no interim tiering):
9. **Public `wake` capability primitive (frozen-queue design).** The
   mechanism already exists as privileged natives (`__rove_set_wake` /
   `__rove_fire_wake`, `globals.zig:3465`) + the baked
   `__system/scheduler_tick`. Wrap them in a frozen public `wake` global
   (`wake.at`/`cancel`/`get`) — the webhook shape — and drop
   `SCHED_BY_TIME_PREFIX` from `durable_wake.zig` (the engine stops
   knowing the kv layout; the arm signal becomes a commit-gated `wake.at`
   Cmd). The durable-timer **queue stays a frozen primitive** (one
   watermark, hibernating active-set, baked fan-out — not tenant-pinnable,
   like webhook's at-least-once); only the `{in}`/`{at}` ergonomics slims
   into `@rewind/schedule`. `wake` fills a real primitive gap (the
   detached durable timer, sibling to `after`'s held family). Full spec:
   `docs/plans/wake-primitive-spec.md`.
10. **Remove `__rove_check_email_rate` → generic rate limiting.** Full
    spec: **`docs/plans/privileged-surface-and-ratelimit-spec.md` §3.**
    The native is actually per-worker *plan-quota* enforcement (reads
    `state.plan_rate`), not customer rate-limiting. Untangle: platform
    plan-quota moves to the **frozen outbound boundary**
    (`webhook.send`/`http` — a pinnable email package can't self-enforce a
    platform quota); generic customer rate-limiting = a **kv token-bucket
    recipe** (correct under contention via kv readset conflict — no new
    native), shipped as `@rewind/ratelimit`; a per-worker in-memory
    primitive is deferred. Folds into the **principled `_system`/`__rove_*`
    surface cleanup** (same spec, §1–2): keep two surfaces by a mechanical
    rule (no gated getter — the dangerous ops already self-gate), collapse
    the 6 bare `__rove_*` globals into one `__rove.*` holder.

**D. Confirmed details.**
11. **`jwt` is a package, not stdlib** — it's an opinionated security lib
    (excludes HS256 for alg-confusion reasons), *not* a web standard, and
    `@rewind/oidc` must be able to freeze the exact jwt its verification
    path was tested against (§4 encapsulation). `base64url`/`hex` stay
    bare stdlib (genuine primitives; never change).
12. **Auto-pin lockfile, asymmetric** (client/P-CLI concern; the engine
    stays policy-free): an undeclared `@rewind/*` import is auto-added to
    `manifest.json` at the current major and written into the generated
    lockfile; an undeclared *third-party* import is an **error**. Always
    emit the full resolved lockfile — no ceremony for the common case, a
    real+inspectable dep set always.
13. **Shared read-only `packages/{hash}` prefix** — every tenant reads by
    hash (public code; the *manifest* is the gate, not the prefix — a
    tenant only resolves hashes its own lockfile lists). Registry +
    genesis are the only writers. Future private/paid packages need
    per-tenant copies or real ACLs, *not* the shared prefix (a hash isn't
    a secret) — out of scope now.

---

## 2. Tier assignment for the 26 current globals (+1 new primitive)

Rule (§1.B): **ambient iff primitive; package iff it composes.**

| Tier | Members | Count |
|---|---|---|
| **Capability surface + durability primitives** (ambient, frozen) | kv, crypto, http, platform, request, after, stream, blob, next, **webhook**, **wake** *(new)* | 11 |
| **Stdlib primitives** (ambient, discretionary) | base64 (atob/btoa/base64url/hex), urlsearchparams (URLSearchParams), textcodec (TextEncoder/TextDecoder), console | 4 |
| **Packages** (imported, tenant-pinnable, `@rewind/*`) | jwt, oauth, oidc, sessions, cron, segments, browser, users, activitypub, **retry**, **schedule**, **email** | 12 |

Of the original 26: **14 ambient, 12 packages**, plus **1 net-new
primitive (`wake`)**. Ambient is now *only* genuine primitives —
privileged (capture `_system.*`/`__rove_*` before `delete`, or the
platform-owned durability contracts) or pure (web-standard-shaped,
RFC-stable). Everything that *composes* over them is a package.

Why the durability wrappers are packages: post-chores, `retry` composes
over public `webhook.send`; `schedule` over public `wake` + `kv`;
`email` over `webhook` + `kv` + `crypto`. None touch `_system`/`__rove_*`
— they pass the package rule, and being tenant-pinnable is *correct* for
customer-facing policy/convenience.

---

## 3. The import surface

Authors write standard ES imports against scoped specifiers:

```js
// web/auth/index.mjs
import { provider } from "@rewind/oidc";
export default () => provider().handle();
```

- **`@scope/pkg` coordinate** — `@rewind/*` reserved first-party;
  third-party publishers get their own scope, so names never collide.
- **Module-scoped binding** solves the shadowing footgun that motivated
  moving off ambient globals: an `import` binding is module-scoped and
  immutable (reassigning throws), so it can't be *accidentally* collided
  the way a global `users`/`sessions` can.
- **Statically analyzable** — the dependency graph + capability set are a
  lexical grep over `import` statements; the SBOM/capability audit (§7)
  falls out of source.
- **Engine change is an extension, not a rewrite.** The QuickJS module
  loader already resolves specifiers against the per-deployment
  `path → bytecode` map (`module_execution.zig:400`; `resolveSpecifier`
  at `:483` — bare specifiers currently pass through unchanged). Teach
  `resolveSpecifier` to map `@scope/pkg` → the deploy-resolved
  **hash-qualified** path. The loader, linker, and caching are reused.

Optional future sugar (deferred): an import map could alias a curated
default set to bare names — additive, opt-in, costs nothing here.

---

## 4. Resolution model — flat surface, encapsulated internals

**The app surface is flat; the graph beneath it is not.**

- **App surface (flat):** importing `@rewind/jwt` gives *exactly one*
  jwt — the version the app's own lockfile pinned.
- **Package internals (encapsulated, frozen at publish):** `@rewind/oidc`
  depends on jwt too; that internal jwt was resolved and frozen *when
  oidc was published* — invisible to the app, doesn't track what the app
  pins.

**Worked example** — two jwt versions coexisting in one tenant:

```
App lockfile:                    app pins jwt@1.9.0, oidc@2.3.1
  @rewind/jwt   → jwt@1.9.0      ← what the app imports & calls
  @rewind/oidc  → oidc@2.3.1

oidc@2.3.1 (published earlier, frozen):
  internally imports jwt@1.4.0   ← sealed inside oidc; not on the app surface
```

Guarantee: **installing/bumping a package can never break another
package, and never silently changes one.** For a security lib verifying
tokens *through* jwt, "runs against the exact jwt it was tested with" is
the correctness contract — which is exactly why `jwt` must be a package
(§1.D): a bare-ambient jwt would deny oidc that guarantee.

**Mechanic (content-addressing).** The tenant's baked bytecode map is
keyed by **hash-qualified** paths, so two versions are two blobs — no
name collision:

```
/pkg/jwt@sha256-19f0…/index.mjs    (jwt 1.9.0 — app's)
/pkg/jwt@sha256-14a0…/index.mjs    (jwt 1.4.0 — oidc's private copy)
/pkg/oidc@sha256-23b1…/index.mjs
```

- **Publish time (rewind-apps):** each package's internal
  `import "@rewind/jwt"` is resolved + recorded as its hash-qualified
  specifier. A package ships with its import graph already hash-pinned.
- **Deploy time (client → engine):** the resolver unions every resolved
  blob (incl. multiple versions) into the manifest; the engine bakes them
  into the bytecode map; a generated shim maps the app's bare
  `@rewind/jwt` import to the app-level chosen hash.
- **Runtime (engine):** `resolveSpecifier` resolves hash-qualified
  specifiers — deterministic, pure hash lookup. The node-wide
  `BytecodeCache` dedups identical blobs across tenants
  (`deployment_cache.zig:1346`).

**Dedup by default, nest only on real incompatibility** — if oidc wants
`jwt@^1.4` and the app pins `jwt@1.9.0` (semver-compatible), collapse to
one copy; you only pay duplication across a *breaking* boundary (pnpm's
behavior). **`overrides`** in the app lockfile forces one version
everywhere (rare, explicit, opt-in) — but cannot retarget the frozen
primitives `webhook`/`wake` (§1.B.8).

**Encapsulated to the human, transparent to the platform** — the author
reasons only about packages they named at versions they pinned; the
manifest still records the *full* resolved graph (every version, every
hash) → a reproducible SBOM for the capability audit (§7).

**Launch cost ≈ zero** — the 12 libs are lifted out of one frozen set, so
each `@rewind/x@1.0.0` pins the *current* siblings; the suite ships as one
mutually-consistent set; every tenant resolves to the same hashes. The
nested machinery sits latent until jwt@2 lands and tenants diverge.

---

## 5. Manifest + lockfile format

Extend the reserved-inert bundle manifest (`src/files/app_manifest.zig`,
already `name`/`version`/`config`/`effects`/`metadata`, unknown fields
accepted) with **`dependencies`** — and make the deploy path *consume* it
(today it only structurally validates).

**Author-written (`manifest.json`, bundle root):**
```json
{
  "name": "my-idp",
  "version": "1.0.0",
  "dependencies": { "@rewind/oidc": "^2.3", "@rewind/jwt": "^1.9" },
  "overrides": { "@rewind/jwt": "1.9.0" }
}
```
(Per §1.D.12, the CLI auto-adds undeclared `@rewind/*` imports here at the
current major; undeclared third-party imports error.)

**Machine-written lockfile** — the client resolver produces the full
resolved graph; the engine stores + bakes from it. Extends
`manifest_json.zig` (per-deployment manifest at S3
`tenants/{id}/deployments/{dep:020d}.json`) with a `packages` section:

```json
{
  "v": 2,
  "deployment_id": 42,
  "entries": [ /* handler/static entries, unchanged */ ],
  "packages": [
    {"spec": "@rewind/oidc", "version": "2.3.1", "bytecode_hash": "23b1…",
     "source_hash": "…", "imports": {"@rewind/jwt": "14a0…"},
     "capabilities": ["kv", "crypto", "webhook", "wake"]},
    {"spec": "@rewind/jwt", "version": "1.9.0", "bytecode_hash": "19f0…",
     "source_hash": "…", "imports": {}, "capabilities": ["crypto"]},
    {"spec": "@rewind/jwt", "version": "1.4.0", "bytecode_hash": "14a0…",
     "source_hash": "…", "imports": {}, "capabilities": ["crypto"],
     "private": true}
  ],
  "app_imports": {"@rewind/oidc": "23b1…", "@rewind/jwt": "19f0…"}
}
```

`app_imports` is the flat app surface (§4); `packages[].imports` are the
encapsulated internals. Both are just hashes into the shared store.

---

## 6. Where the package bytes live (engine-side storage)

Package bytecode is content-addressed like handler bytecode.

1. **Shared read-only prefix `packages/{hash}`** (§1.D.13). Tenant blobs
   are prefixed `{key_prefix_base}{instance_id}/file-blobs/`; first-party
   packages instead go in a shared prefix every tenant reads by hash —
   one copy node-wide, deduped by the `BytecodeCache`. Writers: registry
   app + genesis seed only. The *manifest* gates access (a tenant only
   ever resolves hashes its own lockfile lists), so a shared prefix leaks
   nothing for public code.
2. **Bundle carries hashes, not bytes.** The deployment manifest lists
   package hashes; bytes are fetched from the shared store on cache miss
   (same path as handler bytecode). The client uploads any *missing*
   package bytes at deploy (content-addressed PUT is a no-op if present)
   — hermetic bundle without re-shipping the suite every deploy.

---

## 7. Capability model (the security spine)

The rule (memory `project_globals_to_packages`), enforced at the package
boundary: **a package may only compose over the public surface — never
`_system.*` / `__rove_*`.**

**`_system.*` and `__rove_*` are one privileged ABI, split only by
lifecycle** — `_system.*` is captured by the ambient base shims at
base-eval then deleted (hygiene); `__rove_*` is *persistent* because the
baked `__system/*.mjs` modules need natives at request time (after the
delete) and can't close over base-eval `_system`. So the package rule
forbids *both* as one surface.

**The runtime self-gate is the boundary; the static reject is
defense-in-depth.** Every privileged native self-gates (`is_system_module`
/ trust-context check and throws for customer code) — the memory notes the
`delete _system` is "API hygiene, NOT a privilege boundary." So:

- **Runtime self-gate (load-bearing):** a package that reaches a native by
  any means — including computed access like `globalThis['__rove_'+'x']`
  that a source grep would miss — still gets refused at call time. This is
  the actual security boundary.
- **Static gate (hygiene + clear error):** reject any package whose source
  names `_system` or a privileged `__rove_*` native — at publish
  (registry) *and* deploy (engine). Best-effort (JS static analysis is
  evadable), so it backstops, not replaces, the self-gate. Post-chores it
  also catches `email`/`retry`/`schedule` if they regress toward a native.
- **Declared capability set** = which platform primitives a package
  references (grep of imports/free identifiers), recorded per package in
  the lockfile (`capabilities`). A deployment's total capability surface
  is then a manifest read — the compliance/SBOM story from saas-in-a-box
  §6.4 arrives with the mechanism.
- **Frozen primitives are un-overridable** — `overrides` cannot retarget
  `@rewind/webhook`/`@rewind/wake`; the resolver rejects it.
- **LOCKED (2026-07-09): the platform never accepts bytecode — only
  source.** quickjs's bytecode reader (`JS_ReadObject`) is not hardened
  against adversarial input; crafted bytecode is a sandbox-escape
  primitive, so bytecode is trusted-input-only by construction:
  - Every ingestion wire takes SOURCE and compiles engine-side
    (`platform.compile` / `/v1/deploy/pkgfile`) — true today; keep it
    that way. P-Reg accepts source only; publish-time compilation runs
    on the platform, never the author's machine. A lockfile/manifest
    `bytecode_hash` is a *reference to platform-compiled output*, never
    an upload.
  - **Known gap (hash-laundering), to close with the `bc/` prefix
    split:** uploads (statics via `blob.receive`) and compiled bytecode
    both land content-addressed in the same per-tenant `file-blobs`
    namespace, so a manifest that references an uploaded blob's hash as
    `bytecode_hash` would get attacker bytes into `JS_ReadObject`.
    Today this is gated by trust (manifest stamping is admin-door-only
    and the deploy apps only stamp engine-returned hashes) — vigilance,
    not teeth. The fix: engine-produced bytecode PUTs under a `bc/`
    key prefix that no upload path can write, and every bytecode fetch
    (loader, deploy thread, snapshot populator) reads ONLY `bc/{hash}`
    — then "referenced bytecode is compiler output" holds by
    construction. Storage-layout change: pre-launch, no back-compat —
    wipe + re-genesis dev clusters, coordinate the prod re-genesis.

---

## 8. Lifting the libs to `@rewind/*` — and the genesis seed

For each of the 12 libs: move `src/js/globals/<x>.js` → a package in
rewind-apps (`packages/@rewind/<x>/`), converting ambient
`globalThis.<x> = {…}` to ES module exports; internal references to
*other packages* become `import`s; references to ambient primitives
(`kv`, `crypto`, `webhook`, `wake`, `base64url`) stay bare. Publish as a
mutually-consistent `1.0.0` set (§4). Then remove the 12 from rove's
embed list (`build.zig:515`), embed consts (`globals.zig:2285+`), and
eval order (`globals.zig:1995+`).

**The genesis seed *is* the bootstrap registry.** The real first-party
apps (`auth`/`admin`/`docs`) live in rewind-apps and are *published
through* a baked minimal bootstrap — `src/js/starter/genesis_admin.mjs`,
"baked so a virgin cluster self-bootstraps deploy capability with no
external push" (`build.zig:583`). `__auth__` uses `oidc.provider()`
today. So lifting oidc to a registry package is circular at cold-genesis
(publishing auth needs oidc; oidc lives in the registry; the registry is
an app that needs publishing) — **unless first-party package
availability is decoupled from the registry app being live.**

Resolution, mirroring `genesis_admin.mjs`: **genesis PUTs the fixed
first-party package set (hashes known at build time) into the shared
`packages/{hash}` prefix, plus a tiny seeded index (spec→version→hash),
*before* any app that imports them is published.** That seeded set is a
minimal read-only registry; the rewind-apps registry adds discovery UX +
third-party publish *on top of* it and is never on the critical path for
first-party resolution. (Parallels `__admin__` born-at-genesis —
`project_cluster_genesis`.)

**This is a genesis-*ordering* problem, not a live migration** — it's
pre-customer, so we re-genesis the dev cluster (no back-compat window;
`feedback_no_prelaunch_backcompat`). The one hard constraint is the order
within the lift phase (§9 P-Lift): **seed → publish packages → republish
every first-party consumer that imported the ambient global → remove
globals → re-genesis test → POST-probe the auth flow** (not GET —
`feedback_surface_removal_republish`: deployed bundles pin old surfaces;
GET-only 200s once hid a broken login for ~50 min).

---

## 9. Phased build plan

Chores first (§1.C), then the PM engine, then store+client, then the
lift. rove and rewind-apps phases interleave.

- **P-Wake — Public `wake` primitive (rove).** Full spec:
  **`docs/plans/wake-primitive-spec.md`.** **Frozen-queue design:** a new
  frozen `wake` global (`wake.at`/`cancel`/`get`, capability-surface tier)
  over the existing `__rove_set_wake`/`fire_wake` natives — the webhook
  shape (frozen shim over privileged natives; no privileged verbs in the
  public surface). The baked `__system/scheduler_tick` + the natives stay
  privileged and unchanged. Only engine change: drop `SCHED_BY_TIME_PREFIX`
  from `durable_wake.zig` — replace the kv-prefix commit-sniff with a
  commit-gated `wake.at` arm Cmd; the layout moves from Zig into the
  frozen `wake` shim + baked tick. The durable-timer queue is thus **frozen
  infra, not tenant-pinnable**; `@rewind/schedule` slims to the `{in}`/
  `{at}` ergonomic wrapper over public `wake.at`. Small engine diff;
  independently valuable (primitive-gap fill). Inline Zig tests + ported
  schedule smokes.
- **P-Rate — email ratelimit recipe (rove/JS).** Replace
  `__rove_check_email_rate` with a kv token-bucket recipe; remove the
  native. `email` now composes over public surface only. After P-Wake +
  P-Rate, all 12 libs are uniformly "compose over the public surface."
- **P0 — Specifier resolution seam (rove).** Extend `resolveSpecifier`
  to accept hash-qualified `@scope/pkg` paths against the deployment
  bytecode map; extend `manifest_json.zig` with `packages`/`app_imports`
  (`v:2`). No behavior change yet — bundles gain the *ability* to carry
  packages.
- **P1 — Bake resolved packages into a deployment (rove).** DeployThread
  (`deploy_thread.zig`) stages package bytecode into `packages/{hash}`
  (content-addressed PUT, no-op if present), wires the generated
  app-import shim, populates the tenant `bytecodes` map with
  hash-qualified paths (`deployment_cache.zig`). Smoke: deploy a "app +
  one hand-placed package" bundle, hit it.
- **P2 — Static capability gate (rove). SHIPPED 2026-07-09 (engine
  half).** The deploy-time static gate rejects any package whose source
  names `_system` / `__rove` (`referencesPrivilegedSurface`,
  `deploy_thread.zig` — identifier-boundary lexical scan, deliberately
  blunt: comments/strings too); per-package `capabilities` ride the
  manifest v2 sections (parsed since P0, enforcement deferred to real
  demand — the natives' self-gate is the boundary); author feedback on
  undeclared deps = the compile validation gate now surfaces the quickjs
  exception, naming the unresolvable module. Verified by
  `pm_deploy_smoke.py`. MOVED OUT: "consume `app_manifest.dependencies`"
  belongs to **P-CLI** — loose ranges are the *resolver's* input; the
  engine consumes the resolved lockfile (`resolution` wire, shipped in
  P1-deploy). Registry-side publish gating lands with P-Reg.
- **P-Reg — Registry app (rewind-apps).** Publish API, naming →
  versions → hashes index, discovery. A rewind-app; reserved `@rewind`
  scope. Where the "best of class" UX lives — but out of *engine* scope.
- **P-CLI — Resolver bridge (rewind CLI).** Resolve `manifest.json`
  deps against the registry, write the hash-locked lockfile, upload
  missing package bytes, hand the engine a hermetic deployment.
  Dedup-by-default + `overrides` + the asymmetric auto-pin (§1.D.12).
- **P-Lift — Seed + lift the 12 libs (rove + rewind-apps).** Seed the
  first-party set at genesis (§8); publish the 12 as `@rewind/*@1.0.0`;
  convert `auth`/`admin`/`docs` to import them; **republish all first-
  party consumers**; remove the 12 from rove's embed/eval lists;
  re-genesis + POST-probe (§8 ordering is load-bearing).
- **P-Nest — Multi-version / encapsulated internals (rove).** Prove two
  versions of one package coexisting in one tenant (§4) with the
  dedup-vs-nest resolver rule. Mostly latent from P1's hash-qualified
  paths; likely trails real divergence demand.

Value order: P-Wake/P-Rate clean up the durability tier (and ship a real
primitive); P0–P2 make the engine *able* to deploy packages; P-Reg/P-CLI
make the store+client real; **P-Lift is the payoff** (dogfood + shed 14
globals); P-Nest is future-proofing that's mostly already latent.

---

## 10. Open questions (remaining)

Most confirms are now locked (§1.D). Still open:
1. **jwt/base64url boundary** — `jwt` is a package (§1.D.11); `base64url`/
   `hex` stay bare stdlib. Revisit only if a bare-stdlib helper turns out
   to want pinning.
2. **`wake` public API shape** — decide during P-Wake (the primitive
   deserves its own careful design; don't rush it as a PM dependency).
3. **Registry UX scope** — deferred to rewind-apps / P-Reg.

---

## 11. What we explicitly rejected (don't re-propose without new info)

- **Keep them as ambient globals.** Fine for primitives, fatal for a
  package: an ambient global is baked into the *one shared base snapshot*
  (built once at startup, shared across all tenants —
  `dispatcher.zig:161`/`:172`), so it's the same version for everyone and
  changes only by shipping a platform binary. Ambient ⇒ platform-
  versioned ⇒ always-included ⇒ outside the PM (not pinnable, not in the
  lockfile/SBOM). Correct for runtime primitives, wrong for evolving
  libs. Incompatible with per-tenant pinning and third-party packages.
- **A reserved `$.*` namespace** (Android-`R`-style; `@rewind/email` →
  `$.rewind.email`). Attractive (no ceremony, unshadowable) but rejected:
  (a) it's a **facade that reimplements loader infra** — packages are
  still modules needing resolve/link/instantiate, so `$` adds a bespoke
  namespace-assembly layer *on top of* the loader instead of reusing it;
  (b) it muddies **compile ⟂ resolution** — a runtime `$` object keeps
  the compile cache but the dep graph is dynamic `$[x]` access (defeats
  static capability analysis + tree-shaking), while a source-rewrite `$`
  kills the shared `bytecode/{source}` cache. Explicit ES imports get
  **both** — static *and* compile-cacheable — and solve the shadowing
  footgun via module scoping anyway. `$` demoted to optional future
  import-map sugar, not the mechanism.
