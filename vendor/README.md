# vendor/

Third-party C libraries that rove builds from source. Everything here
is committed into the repo so `zig build` works from a fresh clone
with no extra setup — no submodules, no fetch-on-build scripts, no
network access required.

Each subdirectory documents the upstream revision it was taken from
and any local patches applied on top. When you want to update one,
re-vendor from the noted base and re-apply the patches (or bring the
local changes forward manually and update the note).

## quickjs-ng

- **Upstream:** <https://github.com/quickjs-ng/quickjs>
- **Base:** v0.13.0 (commit `71a3c54`)
- **License:** MIT (see `quickjs-ng/LICENSE`)
- **Local changes:** one patch, documented inline at
  `quickjs-ng/rove-kv-deterministic-init.patch.md`.

  The patch makes `JS_NewContext` byte-for-byte deterministic so
  rove-qjs's memcpy-restore-per-request path (the feature that
  justifies using quickjs at all) produces identical arena contents
  on back-to-back restores. Without it, three volatile slots
  (`random_state`, `time_origin`, and `performance.timeOrigin`) would
  diverge between passes and force semantic-type-aware re-seeding in
  the restore code. The patch zeros them at construction; rove-qjs
  seeds them explicitly in `newContext` / `Snapshot.restore` instead.

  Applied directly to `quickjs.c` — there is no separate `.patch`
  file because the diff is small and maintaining a two-step
  "vendor + apply" workflow buys nothing when we already own the
  vendored copy.

- **Build flags:** see `build.zig` — `-D_GNU_SOURCE`,
  `-DQUICKJS_NG_BUILD`, no libc module, no CLI. The four source
  files we compile are `quickjs.c`, `libregexp.c`, `libunicode.c`,
  `dtoa.c`.

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
- If you patch quickjs-ng, append a paragraph to
  `rove-kv-deterministic-init.patch.md` (or add a sibling `.md` if
  the new patch is unrelated to determinism) explaining the "why"
  and "how to re-apply." Future you will thank you.
- rove-kv's Maelstrom tests are the canary for any raft vendor bump:
  willemt's library changes subtle behavior across versions, and
  Maelstrom's linearizability checker catches it faster than any
  hand-written smoke test.
