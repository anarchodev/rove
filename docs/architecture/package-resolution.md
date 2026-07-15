# Packages — the `@scope/pkg` resolution seam + manifest v2

> **Shipped** (graduated from `plans/`; the P0 seam and the P1 deploy-time
> population are built — `scripts/smoke/pm_deploy_smoke.py` proves the
> flat-surface / encapsulated-internals model end to end). Design-of-record
> for how the module loader resolves `@scope/pkg` imports against a
> manifest-declared package set, and for the manifest-v2 schema. The
> compile/bytecode-caching half is
> [`package-compile-caching.md`](package-compile-caching.md); the arc
> tracker for the remaining package-manager work is issue #130. **No
> behavior change for package-less deployments.**

## 0. Scope — the seam only

P0 makes the engine *able* to resolve package imports; it does NOT stage
or produce them.

| In P0 | NOT in P0 |
|---|---|
| `resolveSpecifier`/`normalize` extension for `@scope/pkg` (per-importer) | Fetching package bytecode from the shared `packages/` prefix + populating the tenant map (**P1**) |
| The per-importer `PackageResolver` + its home in the Ctx / snapshot | Producing the manifest's package set — the client resolver (**P-CLI**) |
| `manifest_json.zig` v2 schema (parse/encode/dep-id) | The registry app (**P-Reg**), the static capability gate (**P2**) |

**Deliverable:** given a hand-authored resolver + bytecode map, an app
handler's `import { x } from "@rewind/oidc"` resolves and runs, and
`@rewind/oidc`'s own `import "@rewind/jwt"` resolves to a *different*
pinned version — proving the flat-surface / encapsulated-internals model
(the resolution model's encapsulation guarantee). A deployment with no
packages behaves byte-identically to today.

## 1. The package path scheme

A resolved package version's modules live in the tenant's existing
`bytecodes` map (`StringHashMapUnmanaged(*BlobBytes)`,
`module_execution.zig:406`), under a **package-virtual directory** keyed
by the package's identity hash `<pkg_hash>`:

```
/pkg/<pkg_hash>/index.mjs        # the entry module (convention)
/pkg/<pkg_hash>/lib/token.mjs    # a multi-file package's helper
/pkg/<pkg_hash>/…                # any file the package ships
```

- **`<pkg_hash>`** = the package *version's* identity (a content hash over
  its whole file set + declared imports; the manifest carries it, the
  client computes it — the engine treats it as an opaque content-address).
  Two versions of a package = two distinct `/pkg/…/` dirs, coexisting in
  one tenant (the §4 mechanic).
- **Leading `/`** marks it a package-virtual path — customer deployment
  paths are relative (`index.mjs`, `_triggers/…`, `_static/…`), never
  `/`-rooted, so there is no collision.
- **Multi-file is free.** A package's internal relative imports
  (`./util.mjs`, `../lib/x.mjs`) resolve within its own `/pkg/<pkg_hash>/`
  dir via the *existing* relative logic in `resolveSpecifier`
  (`module_execution.zig:483`) — no new code. Only *cross-package*
  (`@scope/pkg`) imports hit the new resolver. The entry module is
  `index.mjs` by convention (a future `main` field could override it).

## 2. Per-importer resolution (flat surface / encapsulated internals)

Resolution is keyed on **who is importing** (the `base` module path):

| Importer (`base`) | Import map consulted |
|---|---|
| app handler (base NOT under `/pkg/`) | **`app_imports`** — the app's flat surface |
| a package (base under `/pkg/<hash>/`) | **that package's own `imports`** — its encapsulated, frozen-at-publish deps |

So `@rewind/jwt` resolves to the app's pinned jwt when the *app* imports
it, and to oidc's privately-pinned jwt when *oidc* imports it — same
specifier, different target key. That is the whole encapsulation
guarantee, and it falls out of keying on `base`.

**The `resolveSpecifier` change is minimal.** Today bare/absolute
specifiers pass through unchanged (`module_execution.zig:484-489`). New
rule, applied in `normalize` *before* the relative-path logic:

```
normalize(base, name, opaque):
    self = @ptrCast(opaque)          # the loader Ctx (already passed; today ignored)
    if name is not relative ("./"/"../") and self.resolver != null:
        if key = self.resolver.resolve(base, name):   # per-importer lookup (§2 table)
            return key
    return resolveSpecifier(base, name)   # unchanged: relative resolution + passthrough
```

Everything not in an import map still passes through untouched — so
`__system/*` builtin specifiers and relative imports are unaffected.
`load` (`module_execution.zig:438`) is **unchanged**: it just
`map.get(resolvedKey)`.

## 3. `PackageResolver` + where it lives

A resolver table, owned by the tenant snapshot (alongside `bytecodes` in
`TenantFilesSnapshot`, `deployment_cache.zig`), pointed at per-request by
the loader `Ctx`:

```zig
// module_execution.zig — new
pub const PackageResolver = struct {
    /// bare specifier → package-virtual key, for app-context importers.
    app_imports: std.StringHashMapUnmanaged([]const u8),
    /// package-virtual key (e.g. "/pkg/<hash>/index.mjs") → that
    /// package's own {specifier → key} map. Consulted when the importer
    /// (base) is itself under `/pkg/`.
    pkg_imports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),

    /// Returns the resolved package-virtual key, or null to pass through.
    pub fn resolve(self: *const PackageResolver, base: []const u8, specifier: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, base, "/pkg/")) {
            // package importer → its own encapsulated imports
            const pkg_key = packageDirOf(base); // "/pkg/<hash>/"
            if (self.pkg_imports.getPtr(pkg_key)) |m| return m.get(specifier);
            return null;
        }
        return self.app_imports.get(specifier); // app importer → flat surface
    }
};

// module_loader.Ctx gains:
resolver: ?*const PackageResolver = null,   // null ⇒ no packages ⇒ today's behavior
```

`resolver == null` (every current deployment) ⇒ `normalize` skips the new
branch ⇒ **byte-identical to today.**

## 4. Manifest v2 (`manifest_json.zig`)

Extend the v1 shape (`{v, deployment_id, entries:[…]}`) with two optional
sections. `entries` (handlers/statics) is unchanged.

```json
{
  "v": 2,
  "deployment_id": "…",
  "entries": [ /* unchanged */ ],
  "packages": [
    {"spec":"@rewind/oidc","version":"2.3.1","pkg_hash":"<oidc-hex>",
     "files":[
       {"path":"index.mjs","bytecode_hash":"<hex>","source_hash":"<hex>"},
       {"path":"lib/token.mjs","bytecode_hash":"<hex>","source_hash":"<hex>"}
     ],
     "imports":{"@rewind/jwt":"<jwt-1.4-pkg_hash>"},
     "capabilities":["kv","crypto","webhook"]},
    {"spec":"@rewind/jwt","version":"1.9.0","pkg_hash":"<jwt-1.9-hex>",
     "files":[{"path":"index.mjs","bytecode_hash":"<hex>","source_hash":"<hex>"}],
     "imports":{},"capabilities":["crypto"]},
    {"spec":"@rewind/jwt","version":"1.4.0","pkg_hash":"<jwt-1.4-hex>",
     "files":[{"path":"index.mjs","bytecode_hash":"<hex>","source_hash":"<hex>"}],
     "imports":{},"capabilities":["crypto"],"private":true}
  ],
  "app_imports":{"@rewind/oidc":"<oidc-pkg_hash>","@rewind/jwt":"<jwt-1.9-pkg_hash>"}
}
```

- `pkg_hash` is the package version's identity + its `/pkg/<pkg_hash>/`
  dir. `imports` / `app_imports` values are the *dep's* `pkg_hash` (the
  resolver expands each to the entry key `/pkg/<pkg_hash>/index.mjs`).
- `files[]` lists every module the package ships (path within the
  package + its bytecode/source hash) — the P1 populator stages each at
  `/pkg/<pkg_hash>/<path>`.

New Zig structs:
```zig
pub const PkgFile = struct {
    path: []const u8,
    bytecode_hex: [root.HASH_HEX_LEN]u8,
    source_hex: [root.HASH_HEX_LEN]u8,
};
pub const ImportEntry = struct {           // one {specifier → dep pkg_hash} pair
    specifier: []const u8,
    pkg_hash_hex: [root.HASH_HEX_LEN]u8,
};
pub const Package = struct {
    spec: []const u8, version: []const u8,
    pkg_hash_hex: [root.HASH_HEX_LEN]u8,
    files: []PkgFile,
    imports: []ImportEntry,
    capabilities: [][]const u8,
    private: bool,
};
// Manifest gains: packages: []Package, app_imports: []ImportEntry
```

**Version handling (non-disruptive).** Bump `VERSION = 2`, but `decode`
**tolerates v1** (a v1 manifest = a v2 with empty `packages`/`app_imports`)
— existing S3 manifests keep loading, no forced wipe. `encode` always
emits v2; omits `packages`/`app_imports` when empty (so a package-less
deploy's bytes/dep-id don't churn). `capabilities` is parsed + stored but
NOT enforced in P0 (that's P2's static gate).

**`computeDeploymentId` (zero churn).** Extend the canonical hash to
append package data — **only when `packages` is non-empty**. A
package-less deployment hashes exactly as today → same dep_id → no
re-deploy churn across the whole fleet. When packages exist, they're
appended sorted-by-(spec,version): `spec|version|bytecode_hex|source_hex`
+ each `imports` pair, plus `app_imports` sorted by specifier — so a
package/version/resolution change yields a new dep_id.

## 5. Test plan (all inline Zig / unit — no S3, no deploy)

- **manifest_json:** v2 encode↔decode round-trip with packages +
  app_imports; a v1 manifest decodes to empty packages; `encode` of a
  package-less manifest is byte-identical to the v1 encoder + same dep_id
  (the zero-churn assertion); malformed package entry rejected;
  `capabilities` parsed.
- **resolveSpecifier / PackageResolver:** app importer → `app_imports`;
  package importer (`/pkg/<h>/index.mjs`) → its own `imports`; the
  *encapsulation* case — app and oidc resolve `@rewind/jwt` to different
  keys; an undeclared specifier passes through (so `__system/*` +
  relatives unaffected); `resolver == null` ⇒ passthrough (regression
  guard).
- **integration (hand-authored, no deploy):** build a `bytecodes` map +
  `PackageResolver` by hand for `app → @rewind/oidc@2 → @rewind/jwt@1.4`
  while the app also imports `@rewind/jwt@1.9`; compile 3 tiny package
  modules to bytecode, install the loader with the resolver, run a
  handler that imports oidc, assert the chain resolves and the two jwt
  versions are the two distinct blobs actually loaded. This is the P0
  proof; P1 replaces the hand-authoring with real deploy-time population.

## 6. Open questions

1. **Interning the package-virtual keys.** `resolve` returns a slice that
   must outlive the call (quickjs copies it in `normalize`), so the keys
   live in the snapshot's arena alongside the maps — confirm lifetime
   during impl (same lifetime as `bytecodes` keys today).
2. **`app_imports` vs a package's `imports` for the SAME version** —
   dedupe to one `/pkg/<pkg_hash>/` dir (same `pkg_hash` ⇒ same keys; the
   resolver just points both at it). Free from content-addressing; note
   it in the P1 populator.
3. **Package entry override** — `index.mjs` is the entry by convention; a
   future `main` field in the Package could override it. Not needed for
   the first-party set.
