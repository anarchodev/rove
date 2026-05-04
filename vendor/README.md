# vendor/

Third-party C libraries that rove builds from source. Everything here
is committed into the repo so `zig build` works from a fresh clone
with no extra setup — no submodules, no fetch-on-build scripts, no
network access required.

Each subdirectory documents the upstream revision it was taken from
and any local patches applied on top. When you want to update one,
re-vendor from the noted base and re-apply the patches (or bring the
local changes forward manually and update the note).

## arenajs

- **Upstream:** <https://github.com/anarchodev/arenajs>
- **Base:** see `arenajs/README.md` for the pinned commit.
- **License:** MIT (see `arenajs/LICENSE`)
- **What it is:** a fork of quickjs-ng tuned for one-shot
  per-request server execution. The runtime is initialized once
  into a frozen base snapshot; per-request reset collapses to a
  single bump-cursor write (~9 ns) instead of the memcpy of the
  whole image that the previous shift-js-style snapshot path used.

  Replaces the previously-vendored quickjs-ng plus its
  `rove-kv-deterministic-init.patch.md` (the deterministic-init
  fixes are baked into the fork). See `arenajs/README.md` for the
  upgrade procedure and the constraints inherited from the fork
  (single context per runtime, no `JS_FreeRuntime` after freeze,
  fixed buffer sizes, weak-ref behaviour on base targets).

- **Build flags:** see `build.zig` — `-D_GNU_SOURCE`,
  `-DQUICKJS_NG_BUILD`, no libc module, no CLI. Five source files:
  `quickjs.c`, `qjs-arena.c` (new in the fork), `libregexp.c`,
  `libunicode.c`, `dtoa.c`.

## raft

- **Upstream:** <https://github.com/willemt/raft>
- **Base:** willemt's consensus library, pre-patch (commit TBD)
- **License:** BSD 3-Clause (see `raft/LICENSE`)
- **Local changes:** none as of this writing. Recorded here so that
  if a patch does land later it has an obvious home and rove-kv has
  a single place to document it.
- **Build flags:** `-std=c99`, `-Wno-pointer-sign`,
  `-Wno-unused-parameter`. Four source files:
  `raft_server.c`, `raft_server_properties.c`, `raft_node.c`,
  `raft_log.c`. Headers under `raft/include`.

## Notes for maintainers

- Don't reformat vendored source. Any local edit should be a
  minimal diff we could theoretically upstream.
- arenajs has no in-tree rove patches today — the determinism +
  arena-mode changes that used to live as a `.patch.md` are now
  part of the fork itself. To re-vendor a newer arenajs commit,
  follow the procedure in `arenajs/README.md`.
- rove-kv's Maelstrom tests are the canary for any raft vendor bump:
  willemt's library changes subtle behavior across versions, and
  Maelstrom's linearizability checker catches it faster than any
  hand-written smoke test.
