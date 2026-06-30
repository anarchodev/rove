# Built-in JS libraries — reference docs plan

Elaborates PLAN §13 (surface map) and complements
`architecture/auth-and-domains.md` (the customer-facing JS surface). Goal: reference
documentation for every built-in JS library, generated from a single
source of truth, hosted on rewindjs itself.

## Problem

The built-in surface is heterogeneous and has no machine-readable
source of truth:

- **Native Zig bindings** — `kv.*`, `http.*`, `events.*`, `crypto.*`,
  `console`, `platform.*`, `Date.now`/`Math.random` — registered in
  `src/js/globals.zig` (`STATIC_NAMESPACES` / `INTRINSIC_EXTENSIONS` /
  `GLOBAL_BUILTINS`). Args are parsed manually in C-callable
  functions; no introspectable signature.
- **Pure-JS wrappers** — `retry`, `webhook`, `email`, `cron`,
  `sessions`, `jwt`, `oauth`, `oidc`, `base64`, `urlsearchparams`,
  `textcodec` — `@embedFile`'d, registered in `build.zig` (~430-440).
  Informal comments, no enforced doc convention.

There is no customer-facing API reference today. Hand-authoring a
manifest would be a workaround that rots. Fix the structure instead.

## Model

- **All Zig-provided native hooks move under one undocumented
  `_system.*` namespace.** It is the internal ABI: unstable, free to
  change, never referenced by customer code.
- **Every public API is JS in a `globals/` folder** — a thin shim
  over `_system.*` where backed by a native hook, carrying full
  JSDoc + `@example`. The existing `src/js/bindings/*.js` wrappers
  move here and repoint to `_system.*` (or sibling shims). This is
  the documentation source of truth.
- **Customer-facing top-level names are unchanged** (`kv.set(...)`
  still works; it's just defined by `globals/kv.js` now). Pure
  internal rewiring — no tenant / test / smoke breakage.

Empirically validated 2026-05-16: the extra JS frame per call costs
**0.00%** even in the worst case (read-only, 200 `kv.get`/req,
hot primitive, full TLS+raft cluster). Shim everything; do **not**
dual-expose hot primitives. Harness:
`scripts/bench/kv_shim_overhead_bench.sh` + `kvdirect`/`kvshim` tenants.

### Two documented exceptions (not shims)

1. `Date.now` / `Math.random` — intrinsic determinism overrides,
   can't be namespaced under `_system` without breaking callers.
   Documented as "standard JS, replay-deterministic semantics."
2. Per-request `request` / `response` / `session` — data shapes
   injected by `installRequest`, not callables. Documented as
   shapes, hand-authored, outside the JSDoc-extraction path.

## Phases

**A — `_system` + `globals/` refactor.** Move native registrations
under `_system.*`; create `globals/*.js` public shims with JSDoc +
`@example`; move + repoint `src/js/bindings/*.js`. CI lint: customer
code never references `_system`; every `globals/*.js` export has a
doc comment; every name in `STATIC_NAMESPACES` / `GLOBAL_BUILTINS` /
the `build.zig` embed list has a `globals/` entry (catches
undocumented bindings — can't validate signatures, but catches
*missing* ones). Reviewable without UI.

**B — Doctests.** Each `@example` becomes a fixture in the
sim-test / fixture-lifecycle framework; CI fails if a documented
example's behavior changes. Docs true-by-construction.

**C — Docs worker app (the dogfood).** A rewindjs deployment: pure
handler renders the extracted JSDoc → HTML; assets content-addressed;
deployed through the same `_deploy/current` flow customers use.

**D — Replay links + agent endpoint.** Each Phase-B fixture run
produces a tape; the docs page links the example to the replay shell
(`web/replay/_static/`) on that tape — read a doc, scrub its
execution. Same JSDoc source served as JSON for CLI/MCP/agents
(aligns with the v1 "MCP + CLI ship together" decision).

Phase A is the bulk of the work and deletes the drift problem at the
root; B/C/D are cleaner once the corpus exists and examples live next
to the code they document.

## Out of scope

A separate pre-existing perf bug (LMDB read txn opened per `kv.get`,
`mdb_txn_begin` memset = 31% CPU) was surfaced while benchmarking the
shim cost. It does not block or interact with this work. Tracked
independently; fix = reuse the read txn via `mdb_txn_reset`/`renew`.
