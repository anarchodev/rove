# PM — compile caching vs baked import resolution (decision)

Status: **decided, 2026-07-09.** Supersedes the earlier proposal in this
file, whose premise — "the deploy path content-addresses compiled handler
bytecode by source" — turned out to describe the **retired files-server
path**, not the live one. Re-grounded against the code; the conclusion
flips from "fix the cache key" to "keep no source-keyed compile cache."

## 1. The finding (unchanged, still load-bearing)

**quickjs resolves module imports at compile time and bakes the resolved
module name into the bytecode.** Verified by the P1 fixture smoke: package
modules had to be compiled under their `/pkg/<hash>/…` filenames, with the
loader live, for their imports to normalize. So for a handler that does
`import { p } from "@rewind/oidc"`:

> Same handler source + different pinned `@rewind/oidc` version →
> **different bytecode.** Source → bytecode is NOT deterministic once
> packages exist; it is a function of *source + resolution*.

Any cache keyed by source alone is therefore unsound for
package-importing handlers.

## 2. Ground truth: where compile caching actually lives

Three layers, checked against the tree:

- **The live deploy path has NO compile cache.** `/_system/deploy` →
  `DeployThread` → `compileAndStage` (`src/files/root.zig`) recompiles
  every handler on every deploy, hashes the output, and
  `putBlobIfMissingTo` dedups the blob PUT by *bytecode* hash. There is no
  source-keyed memoization to go stale. The `bytecode/{source_sha256}` kv
  cache exists only in `FileStore.putSource` → `ensureBytecode` — the old
  files-server flow, whose sole live caller is `starter.zig` (the baked
  starter/genesis deploy: package-free by construction, and each run
  targets a brand-new files.db, so the cache is cold anyway).
- **The runtime `BytecodeCache`** (`src/js/bytecode_cache.zig`) is keyed
  by `sha256(bytecode)` — sound under packages by construction (different
  resolution ⇒ different bytecode ⇒ different key), and it gives package
  bytecode cross-tenant in-memory dedup for free.
- **Package bytecode is compiled once at publish (P-CLI)** with internal
  imports resolved + baked to content-addressed `/pkg/<dep_hash>/` names,
  then frozen. The engine never recompiles a package — caching in its
  strongest form. Because the module *name* contains the content hash,
  even a shared long-lived compiler context can never conflate versions.

## 3. Decision: keep NO source-keyed compile cache

Recompiling every handler on every deploy is **correct by construction** —
resolution is baked fresh each time, so the stale-bytecode hazard class
vanishes instead of being keyed around. The cost is negligible: deploys
are infrequent, capped at 256 files, quickjs compile is milliseconds per
file, and the expensive part (blob writes) already dedups
content-addressed.

**Invariant (the teeth):** never add source-keyed compile memoization to
the deploy path, and never feed `FileStore.ensureBytecode` a
package-importing source (currently guaranteed — only the starter uses
it, and starter/genesis handlers import no packages).

**Perf fallback, if deploy-thread compile CPU ever measurably matters:**
key a compile cache by `hash(source_bytes ++ canonical(resolution))`,
where `resolution` is the `{specifier → pkg_hash}` bindings the handler
compiles against — whole-deployment `app_imports` to start (over-keys
no-package handlers, but they recompile to identical bytecode and dedup at
the blob layer), per-handler imports only if warranted. This is a
performance decision for later, not a correctness prerequisite for
anything.

## 4. Rejected alternative: bake specifiers + alias in the map

Tempting: compile handlers so they bake the **specifier** (`@rewind/oidc`,
source-pure → a source-hash cache would stay sound), and populate the
tenant map with alias keys `@rewind/oidc → oidc bytecode` (from
`app_imports`). Then compile output is a pure function of source again.

**Rejected — it breaks module identity / dedup.** quickjs keys a module
*instance* by its normalized name. If the app reaches oidc as
`@rewind/oidc` and a package reaches the *same* oidc version as
`/pkg/<hash>/index.mjs`, those are **two names → two instances** → oidc's
top-level runs twice and its module-level state is duplicated. Fine for
pure utility packages, a subtle bug for any package with module state (a
cache, a config singleton, a connection holder). The resolver approach
(canonical `/pkg/<hash>/` names for *both* app and package importers)
gives **one instance per version** — the correct npm/pnpm semantics.

## 5. What P1-deploy still owes the finding

With the cache-key work dropped, the finding's remaining consequence is
**ordering/wiring**, not caching: the deploy thread's compiler context
must be able to resolve `@rewind/oidc` at handler-compile time. Per job:
fetch the manifest's package bytecodes, register them in the compiler's
module map at their `/pkg/<pkg_hash>/<path>` names, install the job's
resolver, *then* compile handlers. Forgetting this fails loudly (compile
can't resolve the import), not silently.

Housekeeping note: the shared deploy-thread compiler context will
accumulate loaded `/pkg/` modules across jobs. Harmless for correctness
(content-addressed names), but a slow memory growth to watch; a periodic
context reset is the remedy if it ever matters.

Verification stays the planned deploy smoke — a bundle whose handler
imports a package, deployed + hit, then a **second deploy with a
different pin** proving the right version runs. It now verifies the whole
chain has no staleness (dep_id includes package data → new snapshot →
fresh compile) rather than a specific cache key.
