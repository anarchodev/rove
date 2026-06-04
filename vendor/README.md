# vendor/

Third-party source that rove still builds in-tree. As of the move to a
pin-and-fetch dependency model (see `docs/v2-build-order.md` and the
top-level `CLAUDE.md`), this is down to a **single** library:

- **`raft/`** — willemt's C consensus library (V1's raft engine).

Everything else that used to live here — `arenajs` and `kvexp` — is now a
pinned `build.zig.zon` package fetched on build; `raft-rs-zig` (the V2
engine) is fetched the same way. `vendor/raft/` is the lone exception
because it is V1-only and gets deleted at V2 cutover, so re-platforming it
to a fetched package would be wasted effort.

## raft (willemt)

- **Upstream:** <https://github.com/willemt/raft>
- **Base:** willemt's consensus library, pre-patch (commit TBD)
- **License:** BSD 3-Clause (see `raft/LICENSE`)
- **Local changes:** none. Recorded here so that if a patch lands later it
  has an obvious home and `rove-kv` has a single place to document it.
- **Build flags:** `-std=c99`, `-Wno-pointer-sign`,
  `-Wno-unused-parameter`. Four source files: `raft_server.c`,
  `raft_server_properties.c`, `raft_node.c`, `raft_log.c`. Headers under
  `raft/include`.

## Notes for maintainers

- Don't reformat vendored source. Any local edit should be a minimal diff
  we could theoretically upstream.
- rove-kv's Maelstrom tests are the canary for any raft vendor bump:
  willemt's library changes subtle behavior across versions, and
  Maelstrom's linearizability checker catches it faster than any
  hand-written smoke test.
