# arenajs vendor snapshot

`anarchodev/arenajs` — a fork of `quickjs-ng` tuned for one-shot
per-request server execution. The runtime is initialized once into a
frozen base snapshot; per-request reset collapses to a single bump-
cursor write (~9 ns) instead of a memcpy of the whole image.

## Snapshot

- Upstream: <https://github.com/anarchodev/arenajs>
- Tag:      `v0.1.0` (2026-05-15)
- Commit:   `0c464ea` (`arena: seed-not-draws`) — post-v0.1.0 §9 bump
- License:  MIT (see `LICENSE`)

### Post-v0.1.0 — seed-not-draws (`docs/primitive-gaps.md` §9)

`JS_FillRandomBytes` is now a public quickjs API; the rove server's
`crypto.*` bindings route through it, so a single per-context
xorshift64star is the source of all randomness.
`arena_set_random_seed(lo, hi)` is a new reactor export (WASM-side
only — the server path calls `JS_SetRandomSeed` directly) used by
the replay shell + replay-WASM smoke. Replay reseeds the PRNG with
the captured request's `seed` scalar before running the handler —
no per-draw tape entries needed.

### v0.1.0 highlights

First tracked version of arenajs's embedder contract. Two engine
additions land in this bump:

- **⚠ Contract — `arena_run` / `arena_run_module` return-code split.**
  Previously any failure returned `-1`. Now: `0` success or clean
  host-requested stop, `-1` JS exception (user error), `-2` request
  arena exhausted (capacity — result is void). Safe consumer pattern
  is unchanged (`rc !== 0` still means "didn't complete cleanly");
  rove-qjs can now distinguish OOM from user-thrown at the boundary
  if it wants.
- **`arena_snapshot_here()`** — a reactor export that walks the live
  stack and ships inspection JSON via `_arena_host_state` WITHOUT
  raising the stop sentinel. Callable synchronously from a
  `host_trace` callback. Unlocks variable snapshots during a single
  replay pass.
- **`arena_oom_hit/requested/used/limit()`** — query whether the
  request arena was exhausted and the numbers to act on it.

The WASM-only sources (`qjs-arena-trace.c`,
`qjs-arena-replay-bindings.c`, `qjs-arena-reactor.c`) live in the
upstream tree and are compiled into
`web/replay/_static/qjs_arena_wasm.{js,wasm}` outside rove's
`build.zig` — they don't ship as part of this vendor list. Updating
those is a separate step (rebuild in arenajs's tree, copy the
emscripten output into `web/replay/_static/`).

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

To bump to a newer arenajs version: clone the upstream repo, check
out the desired tag, copy the files listed in arenajs's README
"Migrating from a memcpy-restore vendor" section into this
directory, and update the snapshot block above with the new tag +
commit SHA. Run `zig build` and `zig build test`; if the WASM
shell needs the bump, also rebuild
`web/replay/_static/qjs_arena_wasm.{js,wasm}` from the same
upstream tree (out-of-scope for `build.zig` — emscripten target,
driven from arenajs's own `Makefile`).
