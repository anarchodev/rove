# arenajs vendor snapshot

`anarchodev/arenajs` — a fork of `quickjs-ng` tuned for one-shot
per-request server execution. The runtime is initialized once into a
frozen base snapshot; per-request reset collapses to a single bump-
cursor write (~9 ns) instead of a memcpy of the whole image.

## Snapshot

- Upstream: <https://github.com/anarchodev/arenajs>
- Branch: `master`
- Commit: `10b1beb5cf85af2ea8d643d6b6a98660465b9693`
- License: MIT (see `LICENSE`)

## What changed vs upstream quickjs-ng

- Dual bump arena (base + request) replaces system malloc + GC.
  Allocations beyond capacity return NULL → propagated as JS OOM.
- `JS_FreezeRuntime` flips the allocator into request mode and
  page-protects base; subsequent JS execution is verified
  base-clean (full test262 corpus, see upstream `make test-arena`).
- Per-request reset is `JS_ResetRequestArena(rt)` — one cursor write
  to the request arena, no memcpy.
- `Math.random()`, `performance.timeOrigin`, `Date.now()` are
  deterministic by default; seed via `JS_SetRandomSeed` and
  `JS_SetTimeOrigin` per request.

## Replaces

- The shift-js-style memcpy-restore machinery previously in
  `src/qjs/snap.zig` (memcpy + bitmap relocation).
- The deterministic-init patch (`rove-kv-deterministic-init.patch.md`
  in the old `vendor/quickjs-ng/`) — equivalent fixes are baked
  into the fork.

## Constraints

- Multiple arena runtimes per thread are supported, and an arena
  runtime can coexist with vanilla `JS_NewRuntime` runtimes on the
  same thread (commit 8a31ff6 in arenajs).
- Single context per runtime.
- No `JS_FreeRuntime` after `JS_FreezeRuntime`; teardown is
  `js_dual_arena_free` (typically at thread exit).
- Fixed buffer sizes — sized at `JS_NewRuntimeArena` and never grow.
- Weak refs / FinalizationRegistry on base targets become
  strong-ref-equivalent (collections still work; finalizers don't
  fire). Loop46 spec divergence.

## Updating

To bump to a newer arenajs commit, fetch the upstream files listed
in arenajs's README "Migrating from a memcpy-restore vendor"
section, copy them into this directory, and update the commit SHA
above.
