# Packages — compile caching vs module resolution (decision, verified)

> **Shipped** (graduated from `plans/`; decided + built with P1-deploy).
> Design-of-record for why the deploy path keeps NO source-keyed compile
> cache and how quickjs resolution interacts with bytecode. Sibling:
> [`package-resolution.md`](package-resolution.md); arc tracker issue #130.

The model went through three states as it got re-grounded; only this
version is current. Superseded along the way:

1. The original proposal assumed the deploy path had a source-keyed
   compile cache that would serve stale package resolutions → "key it by
   `hash(source + resolution)`". Wrong premise: the live deploy path has
   no compile cache at all (see §2).
2. The first correction still claimed quickjs "bakes the resolved module
   name into the bytecode". Also wrong — refuted by reading quickjs-ng
   serialization and by a test (see §1).

## 1. The verified model (source-read + test-enforced)

For an ES module, quickjs's `JS_Eval(COMPILE_ONLY)`:

- **Resolves AND loads every import at compile** — `js_resolve_module`
  runs before the compile-only return, calling the host normalize +
  loader for each specifier. **Compile fails if an import can't
  resolve/load.** Compile is therefore the deploy's import-validation
  gate, and the loader (resolver + package bytecode map) must be live —
  with dependencies staged, leaves first — before compiling anything
  that imports a package.
- **Serializes only the as-written specifiers + the module's OWN
  filename** (`JS_WriteModule` writes `m->module_name` and each
  requested specifier atom; resolved targets are pointers, never
  written). **`JS_ReadModule` re-resolves every import through the live
  loader at every load**, with base = the module's baked own name.

So **bytecode = f(source, filename)** — the pin lives in the snapshot's
`PackageResolver`, never in the handler bytes. Enforced by the test
`"PM: compile validates resolution but does NOT bake it"`
(`src/js/module_execution.zig`): same source + filename compiled under
two different pins → byte-identical output.

The baked own-filename is load-bearing twice: it is the module's
*identity* (a loaded module registers under it — so a package MUST
compile under its `/pkg/<pkg_hash>/<path>` virtual name, or importers
resolving to that key would re-read the blob into duplicate instances),
and it is the *base* its own imports re-resolve against at runtime
(`packageDirOf(base)` → the package's encapsulated imports; an app path
→ `app_imports`). That per-importer re-resolution is what the P1
fixture smoke verified end to end.

## 2. Ground truth: where compile/bytecode caching lives

- **The deploy path has NO compile cache — by decision, not omission.**
  `/v1/deploy/*` → `platform.compile` → `DeployThread` → `compileAndStage` recompiles
  every handler each deploy and dedups blob PUTs by *bytecode* hash
  (`putBlobIfMissingTo`). The old `bytecode/{source_sha256}` kv cache
  died with `FileStore` (deleted; its last caller, the starter deploy,
  now rides `compileAndStage` too).
- **The runtime `BytecodeCache`** is keyed by `sha256(bytecode)` —
  sound by construction, shares package bytecode across tenants.
- **Packages compile once at publish** (P-CLI later; today the deploy
  app's `/v1/deploy/pkgfile` route), content-addressed and frozen; the
  engine fetches, never recompiles them.

## 3. Decision: keep NO source-keyed compile cache

Recompile-per-deploy is cheap (≤256 files, ms per file, blob writes
dedup) and correct by construction. A `source → bytecode` memo would
not serve a wrong *pin* (bytes are resolution-independent) — but it
would (a) **skip the per-deploy import-validation gate**, deferring a
broken import from a deploy-time 400 to a first-request 500, and (b)
**conflate same-source files compiled under different filenames**
(a package copy vs an app copy of the same source are different
bytecode). If compile CPU ever matters, the sound key is
`hash(source ++ filename)` *plus* an explicit revalidation step — a
perf decision for later, not a correctness prerequisite.

**Invariant:** no source-keyed compile memoization in the deploy path.
Recorded in `src/files/root.zig`'s module header, where anyone adding
one would read it.

## 4. Deploy-side compile hygiene (shipped with P1-deploy)

- The deploy thread uses a **fresh quickjs Context per compile job**:
  compiled/loaded modules register in the context's module table, so a
  long-lived context would let one tenant's `lib.mjs` satisfy another
  tenant's import resolution (and grow unboundedly). The runtime stays
  thread-lifetime; contexts are cheap off the hot path.
- A compile job carries the deploy's `{packages, app_imports}`
  resolution; referenced package bytecodes are fetched into a job-local
  loader map so validation sees exactly the deploy's package set.

## 5. Verification

`scripts/smoke/pm_deploy_smoke.py` — a real deploy of a
package-importing handler (app pins jwt@1.9 while oidc's encapsulated
dep pins jwt@1.4), served through the front door; an undeclared import
failing at deploy time; and a second deploy repinning the app to
jwt@1.4 proving the whole dep_id → snapshot → compile chain serves the
new pin with no staleness.
