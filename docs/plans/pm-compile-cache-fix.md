# PM — compile-cache soundness for package-importing handlers (design)

Status: **proposal, 2026-07-09.** No code yet. Designs the fix for the
finding from the P1 fixture smoke: **quickjs resolves module imports at
compile time and bakes the resolved module name into the bytecode**, which
makes the deploy compile-cache unsound for handlers that import packages.
This is a P1-deploy concern (it bites only once the deploy path compiles a
package-importing handler); designing it now because it shapes that path.

## 1. Root cause

The deploy path content-addresses compiled handler bytecode by **source**:
`bytecode/{source_sha256} → bytecode_hash` (rove-files `putSource`,
per-tenant in `files.db`). That assumes *source → bytecode* is
deterministic.

It isn't, for a handler that imports a package. `import { p } from
"@rewind/oidc"` compiles to bytecode with the **resolved** module name
baked in (e.g. `/pkg/<oidc_pkg_hash>/index.mjs` — verified: the fixture
smoke's package modules had to be compiled under their `/pkg/…` filenames
for their imports to normalize). So:

> Same handler source + different pinned `@rewind/oidc` version →
> different bytecode. But `bytecode/{source_hash}` keys by source alone →
> the second deploy is served the first deploy's baked resolution. **Wrong
> package version silently executes.**

(The runtime `BytecodeCache`, keyed by *bytecode*_hash, is fine — different
bytecode ⇒ different hash ⇒ different blob. Only the source-keyed *compile*
cache collides.)

## 2. The fix: key the compile-cache by source + resolution

`bytecode/{ hash(source_bytes ++ canonical(resolution)) } → bytecode_hash`,
where `resolution` is the `{specifier → resolved pkg_hash}` bindings the
handler compiles against.

- **Precise:** only the packages *this* handler imports (scan its imports).
  Best dedup; more work.
- **Simple (recommended to start):** the whole deployment's `app_imports`
  (sorted `specifier|pkg_hash`). All handlers in a deploy key by
  `source + app_imports`. A no-package handler over-keys (its key moves
  when `app_imports` changes) but recompiles to *identical* bytecode →
  the output blob still dedupes by `bytecode_hash`; only redundant compile
  work, no correctness or storage cost.
- **Trivial fallback:** skip the compile-cache entirely for
  package-importing handlers (recompile each deploy). Deploys are
  infrequent + compile is fast; loses only cross-deploy dedup for those
  handlers. Fine as a first cut.

## 3. Rejected alternative: bake specifiers + alias in the map

Tempting: compile handlers so they bake the **specifier** (`@rewind/oidc`,
source-pure → the source-hash cache stays sound), and populate the tenant
map with alias keys `@rewind/oidc → oidc bytecode` (from `app_imports`).
Then no cache change is needed.

**Rejected — it breaks module identity / dedup.** quickjs keys a module
*instance* by its normalized name. If the app reaches oidc as
`@rewind/oidc` and a package reaches the *same* oidc version as
`/pkg/<hash>/index.mjs`, those are **two names → two instances** → oidc's
top-level runs twice and its module-level state is duplicated. Fine for
pure utility packages, a subtle bug for any package with module state (a
cache, a config singleton, a connection holder). The resolver approach
(canonical `/pkg/<hash>/` names for *both* app and package importers) gives
**one instance per version** — the correct npm/pnpm semantics — so we keep
it and pay the compile-cache key instead.

## 4. Consequence — the model stands, the cache key changes

- **P0's runtime resolver stays** (canonical `/pkg/<hash>/` paths →
  correct per-version module identity; encapsulation via per-importer
  resolution). Verified by the fixture smoke.
- **The deploy compile path** (engine-side, `deploy_thread` / rove-files)
  must: (a) stage package bytecode + build the resolver *before* compiling
  handlers (so their imports resolve at compile), and (b) key the
  compile-cache by `source + resolution` (§2).
- **Packages are compiled once at publish (P-CLI)** with their internal
  imports resolved + baked to `/pkg/<dep_hash>/` (frozen). The engine never
  recompiles a package; it recompiles *handlers* per deploy against the
  resolved package set.

## 5. Where this lands

This is **P1-deploy**, not P1-core (which is done + verified). It ships
with the deploy-side populator + compile ordering, and the first real
end-to-end verification is the deploy smoke (a bundle whose handler imports
a package, deployed + hit, asserting the right version runs — and a second
deploy with a different pin proving the cache doesn't serve the stale
bytecode).

Open: precise-vs-simple key (§2) — start simple (whole `app_imports`), move
to per-handler only if compile time on large deploys warrants it.
