# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is rove

Rove is a Zig systems library for building distributed serverless worker infrastructure. It provides content-addressed code deployment, a QuickJS-based JS runtime, an HTTP/2 server, and a distributed KV store with Raft consensus. Third-party dependencies are **pinned and fetched at build time** — Zig/C packages (`arenajs`, `kvexp`, and the V2 engine `raft-rs-zig`) via `build.zig.zon`; the V2 raft engine's Rust crates via Cargo. The first build needs network. This replaced the former vendor-everything / offline-build mandate when the V2 raft-rs Rust closure proved too large to vendor (see `docs/decisions.md` §10.11). **The V1→V2 cutover is done — `main` is the V2 line:** the V1 product binary `loop46`, the willemt-raft engine (`vendor/raft/` + `src/kv/{cluster,raft_node,raft_log,…}.zig`), and the sqlite raft log are all retired. The V2 worker is `rewind-worker` (`src/rewind/main.zig`); per-tenant consensus is the `Bridge` (`src/consensus/bridge.zig`) + raft-rs. There are no vendored deps left.

## Product direction

`rove` is the engine for **rewind.js**, a purely-functional serverless product. Locked architecture and phased build plan live in [`docs/PLAN.md`](docs/PLAN.md). Read it before making decisions that could contradict existing direction (domain layout, pure-function execution model, Cmd-pattern external effects via **one outbound HTTP primitive** with `webhook.send` / `email.send` / `retry.*` as **JS-shim libraries that compose durability on top of it** — see `effect-algebra.md` §5 (the durability rule) + `decisions.md` §3.3; page-level encryption at rest; etc.). Section 7 of that doc lists decisions that were explicitly considered and rejected — do not re-propose those without new information. **`docs/README.md` is the documentation map.** As-built architecture references live in `docs/architecture/` (`overview`, `consensus-and-storage`, `effects-and-handlers`, `routing-and-ingress`, `websockets`, `control-plane`, `deployment-and-logs`, `auth-and-domains`, `observability`); locked decisions + rejected alternatives in `docs/decisions.md`; **in-flight plans live in GitHub issues** (a tracker issue per arc + leaf issues per item; trackers carry the `epic` label — `gh issue list --label epic`; durable residue graduates into `architecture/`/`decisions.md` before an issue closes), product/strategy docs in `docs/strategy/`, tutorials in `docs/guides/` (per the README map). `docs/effect-algebra.md` (the cross-cutting four-primitive model + trigger-scope axes) and `docs/handler-shape.md` (the customer handler surface) are the customer-facing contracts. PLAN §13 is the live process / surface map.

## Build commands

```bash
zig build              # Build all modules and examples
zig build test         # THE gate: every unit test (inline Zig tests across all
                       # modules, incl. the raft substrate + directory) AND a
                       # compile of every shipped binary
zig build rewind-worker # Build the V2 worker binary (src/rewind/main.zig)
zig build rewind-cp    # Build the V2 control plane (directory + provisioning)
zig build rewind-front # Build the V2 stateless front door (Host→cluster proxy)
zig build smoke-bins   # Install EVERYTHING the smoke suite executes — run_all.py
                       # and the smoke harness build this themselves; `test`
                       # compiles binaries but installs NONE of them
zig build v2-test      # Focused SUBSET of `test`: the raft substrate alone
zig build conformance  # Behavior conformance — one corpus on every engine
                       # (cheap lane: no cluster). Folded into `test`.
zig build echo-server  # Run the TCP echo server example
zig build h2-echo-server  # Run the HTTP/2 echo server example
```

Requires Zig 0.15.0+ and a Rust toolchain (pinned by `rust-toolchain.toml`) for
the consensus-linked steps — anything that pulls in the bridge (`rewind-worker`,
`rewind-cp`, `v2-test`, and `test`, which links it via rove-js and compiles
every binary) builds raft-rs-zig's Rust FFI via cargo; the bare `zig build`
install step does not. System libraries: nghttp2, OpenSSL (ssl + crypto),
libcurl, liblmdb (via kvexp), zlib, SQLite3 (`rewind-logs` + the log-server
tests, both of which `test` covers). `test` also shells out to **node** (the
interaction-digest mirror gate) and **python3** (the conformance runner).

## Behavior conformance

`scripts/conformance/` is the executable spec: one corpus of behavior cases run
against every engine that executes customer handlers — the offline sim, the prod
worker, and the browser WASM replay arena — failing when two of them disagree.
It replaces the pattern where a sim fixture and a prod smoke assert the same
hand-copied literal in two languages and nothing detects drift (`build.zig`'s
`↔ <smoke>` comments are that pairing today; nothing executes them). Read
`scripts/conformance/README.md` before adding a case. Tracker: rove#195.

## Smoke tests

Python scripts in `scripts/` drive end-to-end tests against running binaries.
Each one spawns its own topology and tears it down via `atexit` / signal
handlers (no `pkill -f` fragility). V2 smokes need S3 credentials in the
environment first (`set -a; . ./.env; set +a`) — V2 has no fs blob backend.

```bash
scripts/smoke/run_all.py --jobs 8            # THE suite — ~14m parallel (pool + serial tail); --filter to narrow
python3 scripts/smoke/rewind_smoke.py        # single-node rewind write path (propose → commit → 204)
python3 scripts/smoke/ctl_smoke_v2.py        # provision → deploy → serve through the front door
python3 scripts/smoke/three_node_smoke.py    # ⭐ multi-node HA: move onto a 3-node cluster, kill the leader
python3 scripts/smoke/tenant_move_smoke.py   # live tenant move cluster-1 → cluster-2
```

**Run the suite after anything touching the deploy protocol, a global/shim
surface, the front door, or the harness.** Nothing ran it for months and it
rotted silently — smokes broke one at a time as unrelated changes landed
(`scripts/smoke/README.md` has the table). Use
`--json now.json --baseline scripts/smoke/smoke-baseline.json`: it fails only on
a NEWLY broken smoke, which is the question that matters.

`scripts/smoke/smoke_lib_v2.py` is the V2 harness — `V2Cluster.spawn` brings up
rewind-cp + front door + rewind node(s) and exposes `provision` /
`deploy_handlers` / `wait_for_handler` (deploys go through the standing
`__admin__` app's `/v1/deploy/*` routes + `PUT /v1/upload`, which reach the
worker's `DeployThread` via the `platform.*` primitives — files-server
dissolved, `docs/architecture/cli-and-deploy.md` §4.2);
`scripts/smoke/v2_topology.py`
holds the per-binary spawn primitives. The functional smokes are the
`*_smoke_v2.py` set; the original un-suffixed versions spawned the retired
`loop46` binary via `smoke_lib.py` and were **deleted** (60 scripts) once the V2
ports superseded them — `smoke_lib.py` survives only for helper imports
(`mint_jwt`, `HttpResponse`, `BIN_DIR`, `_load_dotenv`) that `smoke_lib_v2.py`
and a couple of V2 smokes still use. New smokes should follow `ctl_smoke_v2.py`
for the canonical shape.

## Architecture

### Module dependency graph

```
rove (core ECS) ←── rove-io (io_uring) ←── rove-h2 (HTTP/2 + h1 + WS, nghttp2)

raft-kv (kvexp KV facade — no consensus) ─┐
rove-blob (S3 blob storage, libcurl) ─────┤   leaves: rove-plan (tier table),
rove-files (content-addressed files) ─────┤           rove-jwt (HS256),
rove-log (per-tenant request logs) ───────┤           rove-ssrf (blocklist)
rove-bodies (body-batch S3 buffer) ───────┤
rove-tape (deterministic replay) ─────────┤
rove-tenant (account/domain metadata) ────┤
rove-qjs (arenajs JS engine wrapper) ─────┤
rove-acme (ACME HTTP-01 client) ──────────┤
                                          ↓
                  rove-js (worker dispatcher; imports bridge + the above;
                           compiles + stages deploys on the DeployThread)
                  rove-log-server (log query HTTP surface)

consensus (src/consensus/, V2): node.zig (per-tenant raft-rs groups, pump,
           hibernating active-set) + bridge.zig (worker-facing propose +
           commit-watermark surface) + transport.zig (coalesced cross-node
           wire over raft-net, a direct liburing wrapper)
cp-directory (src/cp/directory.zig): tenant→cluster routing, backed by a
           directory raft group via the bridge

binaries:  rewind-worker (src/rewind/)  the worker — rove-js on the bridge
           rewind-cp     (src/cp/)      replicated directory + provisioning + moves
           rewind-front  (src/front/)   stateless Host→cluster proxy — no raft state
           rewind-logs   (src/log_server/main.zig)  log query surface
           (deploy/publish is the __admin__ app's /v1/deploy/* → the worker's
            DeployThread; no separate files-server binary, and no
            /_system/deploy route — docs/architecture/cli-and-deploy.md §4.2.
            The engine door that would replace it is designed but unbuilt:
            rove#556)
```

**`raft-kv` is the spine-free KV facade** (`src/kv/kvlimbs.zig`) — the
kvexp-backed limbs (`KvStore` / `TrackedTxn` / writesets), metrics, and the
envelope codec, with NO consensus engine inside. Consensus lives in
`src/consensus/` behind the `Bridge`; the cross-node wire layer (`raft-net`,
`src/kv/raft_net.zig`) uses io_uring directly via liburing, bypassing the
rove-io abstraction.

### Core ECS pattern (rove module)

The foundational abstraction used throughout — the fat-entity model:
- **Entity** — lightweight handle (index + generation) for safe identity tracking
- **Row** — compile-time type composition naming the components a collection materializes
- **Collection** — SoA (Structure-of-Arrays) storage with alignment; pure storage, no lifecycle hooks
- **World** — the declared component/collection tables (`rove.World(.{ .parts = ... })`, one `Part` per layer, declared by the module that instantiates); its `Reg` owns every collection's storage, and its flattened table is the one id namespace (`CollId`)
- **FatRegistry** — the storage model under the world: every entity conceptually carries the whole component universe (AoS shadow table + per-entity `{gen, written}` header); collections are the dense SoA views systems iterate; moves are total and lossless (components the destination lacks park in the shadow); membership axes — one total lifecycle axis, partial state axes with `enter`/`leave`, identity sets exempt from quiescing; `getFat`/`getRow` are the universal reads

Release is a TRANSITION owned by a system, never a destructor: buffers free in phases (`write_done`, `conn_dead`, the `_stream_dead` reaper) and endings go through funnel verbs (`closeConn`, `destroyEntity`, the `moveOnly`/`evictOnly` quiesce family — deferred `evict` is entity-keyed and never refuses a moving entity). Systems are pure functions called between `poll()` and `reg.flush()`, not methods on the registry.

### Request lifecycle (rove-js worker)

```
h2.request_out → dispatchOnce → [drainRaftPending if writes] → h2.response_in → h2.response_out
```

`dispatchOnce` invokes the handler via `Dispatcher.runOutcome` (`src/js/dispatcher.zig`) — the single re-entry point for every activation (inbound, send_callback, fetch_chunk, kv_wake, disconnect, subscription_fire). See `docs/architecture/effects-and-handlers.md` for the Continuation primitive that backs the parked Msg queue.

Each JS request gets a fresh JS context via arenajs's dual-arena reset (one cursor write per request — see the README in the fetched `arenajs` package, `anarchodev/arenajs`). The base arena is built once at worker startup and shared across all requests on the thread; the per-request arena is reset between handler invocations.

### Data durability model

Local KV writes land in a speculative volatile overlay (kvexp), then a parallel Raft propose handles replication. On quorum the overlay commits (`TrackedTxn.commit()`); on fault/timeout it rolls back (`TrackedTxn.rollback()`). A pre-quorum crash needs no undo log — the overlay is volatile, so it never reached disk.

### What replicates through raft

Envelopes are typed byte blobs (`src/js/apply.zig`). Only three types are live (post-Phase-5.5, post-`http.send` Option-(b) re-platform 2026-05-19):

| Type | Target store | Producer |
|---|---|---|
| `0` writeset | `{data_dir}/{id}/app.db` | Customer handler `kv.*` via `TrackedTxn` + writeset; `_deploy/current` release marker; the `webhook.send` / `email.send` JS-shim's `_send/owed/{id}` markers and the durable `scheduler` lib's `_sched/*` wake entries ride here too (ordinary kv writes — no apply-time special-case; `decisions.md` §3.3 + §3.7) |
| `1` multi | per-inner-envelope target | Worker dispatcher — atomically bundles multiple writeset envelopes into one raft entry |
| `2` root_writeset | `{data_dir}/__root__.db` | `provisionInstance` / admin `createInstance`'s `tenant.createInstance`; admin JS `platform.root.*`. Holds `instance/{id}` + `domain/{host}` only — a host's certificate is an axis of the CP directory group, not a root write (`docs/architecture/auth-and-domains.md`, the cert-state-and-replication rule) |

Retired type bytes — the decoder rejects each loudly, so any stale raft-log entry surfaces instead of silently mis-applying: `log_batch` (originally type 1) and `files_writeset` (3) in Phase 5.5 (a) / (e) — log batches go S3-direct and per-tenant deployment manifests live in a `deployments/` BlobBackend per `docs/architecture/deployment-and-logs.md`; the dedicated webhook envelopes (4/5/6) on 2026-05-09; and `schedule_upsert/complete/cancel/demote` (8/9/10/11) on 2026-05-19 in the `http.send` Option-(b) re-platform — there is no `schedules.db` and no schedule-server thread. The per-node leader-local `SendDispatch` that Option-(b) introduced was itself retired on 2026-05-24 per the durability-as-JS-shim decision (`decisions.md` §3.3, commit `b908953`); the `_send/owed/{id}` markers are now written by `webhook.send.js` / `email.send.js` as ordinary envelope-0 kv keys and the apply-time special-cases are gone. `multi` was renumbered from type 7 to type 1 to match `ENVELOPE_TYPE_MULTI` (`src/kv/envelope_codec.zig`). See `docs/effect-algebra.md` for how envelopes fit the effect model, PLAN.md §10.2 for the full evolution table, and §13 for the live process map.

### Blob storage (S3-only)

Blob bytes (source, bytecode, static assets, log/tape batches) are **not** carried through raft envelopes — a 1MB static blob per envelope would blow the raft log size/latency budget. They live in S3-shaped object storage: `S3BlobStore` in `rove-blob` (path-style, SigV4-signed; tested against OVH, works against AWS / MinIO / R2 / B2). There is no filesystem backend — production is multi-node and every node must read the same content-addressed store, so S3 is mandatory even single-node (smokes source `.env` first).

Config is env-driven via `rove-blob`'s `env.zig` (`S3_ENDPOINT` / `S3_REGION` / `S3_BUCKET` / `S3_KEY_PREFIX_BASE` / `S3_USE_TLS` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`), read identically by `rewind-worker`, `rewind-cp`, and the log-server so every per-tenant backend opens against the same store. Per-tenant scoping is the key prefix `{key_prefix_base}{instance_id}/{file-blobs|log-blobs}/`, so leader and followers hit identical keys.

Raft replicates the manifest (the `file/{path}` key → `{hash, kind, content_type}` pointer); the shared backend serves the bytes referenced by those hashes. Followers apply the manifest ops; readers fetch the blob bytes from S3.

### Dependencies (pinned-and-fetched)

Pins live in `build.zig.zon` (Zig/C packages) and each Rust crate's `Cargo.lock`. The first `zig build` fetches; subsequent builds use the Zig package cache. To bump a dep, re-run `zig fetch --save=<name> git+https://…#<commit>`.
- **arenajs** (`anarchodev/arenajs`) — fork of quickjs-ng with a dual bump arena (base + per-request); per-request reset is one cursor write instead of memcpy. Replaces the previously-vendored quickjs-ng + deterministic-init patch. Its own `build.zig` compiles the quickjs/arena C sources into a static lib; rove links it.
- **kvexp** (`anarchodev/kvexp`) — first-party pure-Zig multi-tenant embedded KV (LMDB-backed) used as the per-tenant state engine under `TrackedTxn`'s speculative overlay.
- **raft-rs-zig** (`anarchodev/raft-rs-zig`) — V2 multi-raft engine (TiKV raft-rs, one group per tenant) behind a Zig wrapper; its `build.zig` runs `cargo build` for the Rust FFI. Linked by every consensus-shaped step (`rewind-worker`, `rewind-cp`, `v2-test`, `js-v2`, the aggregate `test` via rove-js's bridge import); the bare `zig build` install step never invokes cargo.
- ~~**willemt/raft**~~ — V1 consensus library, **deleted at the V2 cutover** (along with `vendor/` entirely). V2 consensus is `raft-rs-zig` (fetched).

## Conventions

- Tests are inline Zig tests (`test "description" { ... }`) co-located with the code they cover.
- **`zig build test` is the whole gate** — every test artifact hangs off it, and every shipped binary compiles under it. The narrower steps (`v2-test`, `rewind-cp-test`, `h1-test`, …) are focused subsets for iterating, never an additional gate to remember. A test artifact that only a narrow step runs is a regression nobody sees. Binaries compile there because a test build never analyses `main` (Zig analyses function bodies lazily), so a type error in a `main.zig` passes both `test` and that binary's own `*-test` step.
- Module public API is exported through each module's `root.zig`.
- No async/await — concurrency uses collection-based polling + phase-based dispatch.
- Write comments in the timeless present: explain the current code — keep rationale, invariants, and cross-references (including `docs/` pointers). Don't narrate the change that produced it (no "was X / now Y", issue-# tags, or bare Phase-N history — that belongs in git + the PR, where it stays accurate as the code moves on). When a past pitfall matters, encode it as a present-tense constraint, not a changelog line. The phased delivery plan itself lives in `docs/PLAN.md` (§3 for phase content, §10.16 for launch sequencing) — reference it by doc-pointer rather than tagging a comment with a phase number.
- A doc-pointer comment must satisfy three conditions (so it doesn't rot into a dangling reference — the failure mode the plans→issues migration mass-produced): **(1)** the invariant is stated *inline* and the comment survives the doc's deletion — the `docs/` pointer is the *why*-expansion, never the load-bearing content; **(2)** it targets a durable reference doc only — `docs/architecture/…` or a customer contract (`effect-algebra.md`, `handler-shape.md`, `decisions.md`) — never a plan/audit doc, an issue number, or any temporal target; **(3)** it cites the *concept name* (`the fold-gate invariant (consensus-robustness.md)`), not a bare `§` number that rots silently on a doc restructure — a `§` is acceptable only as a supplement beside the concept. `scripts/ops/doc_pointer_lint.py` enforces condition 2's path half (every `docs/…` path cited in a comment must resolve); conditions 1 and 3 are the human's to keep.

## Working with multiple agents (one clone per workspace)

This repo is frequently worked on by several Claude sessions at once. Each session gets its **own local clone** on its own branch, created by one script:

```bash
scripts/ops/workspace.py <topic>            # → ../rove-<topic>, branched off origin/main
scripts/ops/workspace.py <topic> --base v2  # start somewhere else
scripts/ops/workspace.py --list             # what exists, and what is reclaimable
scripts/ops/workspace.py --gc --yes         # delete every workspace that holds nothing
scripts/ops/workspace.py --trim --yes       # keep every clone, drop the idle ones' build caches
```

The script clones, points `origin` at GitHub, creates the branch, materialises the `web` submodule at its pinned commit, and copies `.env`. Run it rather than assembling a workspace by hand — an unenforced setup ritual works for a month and then quietly doesn't, and the symptom surfaces far away as confusing smoke failures.

**Retire workspaces with `--gc`, not `rm -rf`.** The same argument applies at the other end: teardown used to be a remembered `rm -rf`, so it never happened, and merged workspaces piled up tens of gigabytes — a working tree is ~12 MB, but its Zig build cache is 1-5 GB. `--gc` deletes only what git can prove holds nothing unique: clean tree, no stash, no untracked files, and every branch tip already on `origin/main` **by patch**, not by sha, since branches are routinely rebased before they merge. Everything else is kept with the reason printed. `--trim` is the separate lever: it drops the build cache of any workspace nothing is running in, keeping the clone and the work — a cache is not the work, and a rebuild costs minutes. `--except NAME` means leave this one alone, and governs both. Both report and do nothing until passed `--yes`.

Deliberately absent from that proof is any check of who is "using" a workspace, because no signal for that is trustworthy — a session working in a clone still reports the main checkout as its cwd. The git proof stands alone: if it holds, the worst a delete costs a live session is a rebuilt cache; if it does not hold, the workspace is kept regardless.

**`web/` is the `rewind-apps` submodule** — the first-party app bundles the smokes deploy, pinned by each rove commit. That pin is what makes a cross-repo change reviewable: a rove commit says which apps commit it expects, so a paired wire-format change (tape ↔ `rtap.mjs`) can't half-land. `git submodule update --init` populates it; `REWIND_APPS_DIR` overrides it when you are editing a branch of rewind-apps alongside this one — push that branch and bump the pin in the same PR (push-then-pin).

Rules:
- The main checkout (`/home/user/src/rove`) is load-bearing — it is what the script clones from; don't delete or move it.
- Never run `git add -u` / `git commit` in a clone another session is using. Unexplained working-tree WIP is probably a sibling's — examine it, stage only your own files, and never commit another window's work without confirmation.
- Smoke ports come from `scripts/smoke/smoke_ports.py` (each smoke process owns a disjoint slot), so concurrent smokes/suites don't collide on ports. The remaining reason not to run two full suites at once is CPU: a saturated box trips raft election timeouts, which reads as spurious failovers.

**Why clones and not `git worktree`.** Worktrees share the object store — about 39 MB here — while a workspace's real cost is its Zig build cache at 1-5 GB, which worktrees do *not* share. So the saving is under a percent, and it buys three problems: `git worktree` plus submodules is disclaimed by git itself (*"It is NOT recommended to make multiple checkouts of a superproject"* — git-worktree(1) BUGS), the stash stack is shared so one session can pop another's, and a branch can live in only one worktree. A local clone hardlinks the object files, so it costs the ~12 MB working tree and has none of that.
