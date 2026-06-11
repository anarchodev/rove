# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is rove

Rove is a Zig systems library for building distributed serverless worker infrastructure. It provides content-addressed code deployment, a QuickJS-based JS runtime, an HTTP/2 server, and a distributed KV store with Raft consensus. Third-party dependencies are **pinned and fetched at build time** — Zig/C packages (`arenajs`, `kvexp`, and the V2 engine `raft-rs-zig`) via `build.zig.zon`; the V2 raft engine's Rust crates via Cargo. The first build needs network. This replaced the former vendor-everything / offline-build mandate when the V2 raft-rs Rust closure proved too large to vendor (see `docs/decisions.md` §10.11). **The V1→V2 cutover is done (branch `v2`):** the V1 product binary `loop46`, the willemt-raft engine (`vendor/raft/` + `src/kv/{cluster,raft_node,raft_log,…}.zig`), and the sqlite raft log are all retired. The V2 worker is `rewind` (`src/rewind/main.zig`); per-tenant consensus is the `Bridge` (`src/consensus/bridge.zig`) + raft-rs. There are no vendored deps left.

## Product direction

`rove` is the engine for **rewind.js**, a purely-functional serverless product. Locked architecture and phased build plan live in [`docs/PLAN.md`](docs/PLAN.md). Read it before making decisions that could contradict existing direction (domain layout, pure-function execution model, Cmd-pattern external effects via **one outbound HTTP primitive** with `webhook.send` / `email.send` / `retry.*` as **JS-shim libraries that compose durability on top of it** — see `effect-algebra.md` §5 (the durability rule) + `decisions.md` §3.3; page-level encryption at rest; etc.). Section 7 of that doc lists decisions that were explicitly considered and rejected — do not re-propose those without new information. **`docs/README.md` is the documentation map.** As-built architecture references live in `docs/architecture/` (`overview`, `consensus-and-storage`, `effects-and-handlers`, `routing-and-ingress`, `control-plane`, `deployment-and-logs`, `auth-and-domains`, `observability`); locked decisions + rejected alternatives in `docs/decisions.md`; in-flight plans + product/strategy docs in `docs/` (per the README map). `docs/effect-algebra.md` (the cross-cutting four-primitive model + trigger-scope axes) and `docs/handler-shape.md` (the customer handler surface) are the customer-facing contracts. PLAN §13 is the live process / surface map.

## Build commands

```bash
zig build              # Build all modules and examples
zig build test         # Run all unit tests (inline Zig tests across all modules)
                       # — fixed at the V1 cutover (was broken by frozen V1 modules)
zig build rewind       # Build the V2 worker binary (src/rewind/main.zig)
zig build rewind-cp    # Build the V2 control plane (directory + provisioning)
zig build rewind-front # Build the V2 stateless front door (Host→cluster proxy)
zig build files-server-v2  # Build the cluster-free V2 deploy publisher
zig build v2-test      # V2 raft substrate tests
zig build echo-server  # Run the TCP echo server example
zig build h2-echo-server  # Run the HTTP/2 echo server example
```

Requires Zig 0.15.0+ and a Rust toolchain (pinned by `rust-toolchain.toml`) for
the consensus-linked steps — anything that pulls in the bridge (`rewind`,
`rewind-cp`, `v2-test`, `js-v2`, the aggregate `test` via rove-js) builds
raft-rs-zig's Rust FFI via cargo; the bare `zig build` install step does not.
System libraries: nghttp2, OpenSSL (ssl + crypto), libcurl, liblmdb (via
kvexp), zlib; SQLite3 only for the log-server standalone binary and its
`log-server-test` step.

## Smoke tests

Python scripts in `scripts/` drive end-to-end tests against running binaries.
Each one spawns its own topology and tears it down via `atexit` / signal
handlers (no `pkill -f` fragility). V2 smokes need S3 credentials in the
environment first (`set -a; . ./.env; set +a`) — V2 has no fs blob backend.

```bash
python3 scripts/rewind_smoke.py        # single-node rewind write path (propose → commit → 204)
python3 scripts/ctl_smoke_v2.py        # provision → deploy → serve through the front door
python3 scripts/three_node_smoke.py    # ⭐ multi-node HA: move onto a 3-node cluster, kill the leader
python3 scripts/tenant_move_smoke.py   # live tenant move cluster-1 → cluster-2
```

`scripts/smoke_lib_v2.py` is the V2 harness — `V2Cluster.spawn` brings up
rewind-cp + front door + rewind node(s) + files-server-v2 and exposes
`provision` / `deploy_handlers` / `wait_for_handler`; `scripts/v2_topology.py`
holds the per-binary spawn primitives. The functional smokes were ported as
`*_smoke_v2.py` (~40 of them); the original un-suffixed versions spawn the
retired `loop46` binary via `smoke_lib.py` and are dead — `smoke_lib.py`
survives only for helper imports (`mint_jwt`, `HttpResponse`). New smokes
should follow `ctl_smoke_v2.py` for the canonical shape.

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
                  rove-js (worker dispatcher; imports bridge + the above)
                  rove-files-server (compile/deploy HTTP surface)
                  rove-log-server (log query HTTP surface)

consensus (src/consensus/, V2): node.zig (per-tenant raft-rs groups, pump,
           hibernating active-set) + bridge.zig (worker-facing propose +
           commit-watermark surface) + transport.zig (coalesced cross-node
           wire over raft-net, a direct liburing wrapper)
cp-directory (src/cp/directory.zig): tenant→cluster routing, backed by a
           directory raft group via the bridge

binaries:  rewind        (src/rewind/)  the worker — rove-js on the bridge
           rewind-cp     (src/cp/)      replicated directory + provisioning + moves
           rewind-front  (src/front/)   stateless Host→cluster proxy — no raft state
           files-server-v2, log-server-standalone  (examples/ wrappers)
```

**`raft-kv` is the spine-free KV facade** (`src/kv/kvlimbs.zig`) — the
kvexp-backed limbs (`KvStore` / `TrackedTxn` / writesets), metrics, and the
envelope codec, with NO consensus engine inside. Consensus lives in
`src/consensus/` behind the `Bridge`; the cross-node wire layer (`raft-net`,
`src/kv/raft_net.zig`) uses io_uring directly via liburing, bypassing the
rove-io abstraction.

### Core ECS pattern (rove module)

The foundational abstraction used throughout:
- **Entity** — lightweight handle (index + generation) for safe identity tracking
- **Row** — compile-time type composition defining an entity's component shape
- **Collection** — SoA (Structure-of-Arrays) storage with alignment + component lifecycle
- **Registry** — manages multiple collections; handles entity creation, destruction, and moves

Systems are pure functions called between `poll()` and `reg.flush()`, not methods on the registry.

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
| `2` root_writeset | `{data_dir}/__root__.db` | `provisionInstance` / admin `createInstance`'s `tenant.createInstance`; admin JS `platform.root.*`; ACME `cert/{host}` (see `docs/architecture/auth-and-domains.md`) |

Retired type bytes — the decoder rejects each loudly, so any stale raft-log entry surfaces instead of silently mis-applying: `log_batch` (originally type 1) and `files_writeset` (3) in Phase 5.5 (a) / (e) — log batches go S3-direct and per-tenant deployment manifests live in a `deployments/` BlobBackend per `docs/architecture/deployment-and-logs.md`; the dedicated webhook envelopes (4/5/6) on 2026-05-09; and `schedule_upsert/complete/cancel/demote` (8/9/10/11) on 2026-05-19 in the `http.send` Option-(b) re-platform — there is no `schedules.db` and no schedule-server thread. The per-node leader-local `SendDispatch` that Option-(b) introduced was itself retired on 2026-05-24 per the durability-as-JS-shim decision (`decisions.md` §3.3, commit `b908953`); the `_send/owed/{id}` markers are now written by `webhook.send.js` / `email.send.js` as ordinary envelope-0 kv keys and the apply-time special-cases are gone. `multi` was renumbered from type 7 to type 1 to match `ENVELOPE_TYPE_MULTI` (`src/kv/envelope_codec.zig`). See `docs/effect-algebra.md` for how envelopes fit the effect model, PLAN.md §10.2 for the full evolution table, and §13 for the live process map.

### Blob storage (S3-only)

Blob bytes (source, bytecode, static assets, log/tape batches) are **not** carried through raft envelopes — a 1MB static blob per envelope would blow the raft log size/latency budget. They live in S3-shaped object storage: `S3BlobStore` in `rove-blob` (path-style, SigV4-signed; tested against OVH, works against AWS / MinIO / R2 / B2). There is no filesystem backend — production is multi-node and every node must read the same content-addressed store, so S3 is mandatory even single-node (smokes source `.env` first).

Config is env-driven via `rove-blob`'s `env.zig` (`S3_ENDPOINT` / `S3_REGION` / `S3_BUCKET` / `S3_KEY_PREFIX_BASE` / `S3_USE_TLS` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`), read identically by `rewind`, `rewind-cp`, and the log-server so every per-tenant backend opens against the same store. Per-tenant scoping is the key prefix `{key_prefix_base}{instance_id}/{file-blobs|log-blobs}/`, so leader and followers hit identical keys.

Raft replicates the manifest (the `file/{path}` key → `{hash, kind, content_type}` pointer); the shared backend serves the bytes referenced by those hashes. Followers apply the manifest ops; readers fetch the blob bytes from S3.

### Dependencies (pinned-and-fetched)

Pins live in `build.zig.zon` (Zig/C packages) and each Rust crate's `Cargo.lock`. The first `zig build` fetches; subsequent builds use the Zig package cache. To bump a dep, re-run `zig fetch --save=<name> git+https://…#<commit>`.
- **arenajs** (`anarchodev/arenajs`) — fork of quickjs-ng with a dual bump arena (base + per-request); per-request reset is one cursor write instead of memcpy. Replaces the previously-vendored quickjs-ng + deterministic-init patch. Its own `build.zig` compiles the quickjs/arena C sources into a static lib; rove links it.
- **kvexp** (`anarchodev/kvexp`) — first-party pure-Zig multi-tenant embedded KV (LMDB-backed) used as the per-tenant state engine under `TrackedTxn`'s speculative overlay.
- **raft-rs-zig** (`anarchodev/raft-rs-zig`) — V2 multi-raft engine (TiKV raft-rs, one group per tenant) behind a Zig wrapper; its `build.zig` runs `cargo build` for the Rust FFI. Linked by every consensus-shaped step (`rewind`, `rewind-cp`, `v2-test`, `js-v2`, the aggregate `test` via rove-js's bridge import); the bare `zig build` install step never invokes cargo.
- ~~**willemt/raft**~~ — V1 consensus library, **deleted at the V2 cutover** (along with `vendor/` entirely). V2 consensus is `raft-rs-zig` (fetched).

## Conventions

- Tests are inline Zig tests (`test "description" { ... }`) co-located with the code they cover.
- Module public API is exported through each module's `root.zig`.
- No async/await — concurrency uses collection-based polling + phase-based dispatch.
- Comments reference a "Phase" numbering system tracking the incremental delivery plan; phases run 0 through 14 (with 5.5 as the storage-scalability bucket). See `docs/PLAN.md` §3 for current phase content and §10.16 for the beta / 1.0 / post-1.0 launch sequencing.

## Working with multiple agents (git worktrees)

This repo is frequently worked on by several Claude sessions at once. To keep sessions from colliding in one working tree — where one window's uncommitted edits get swept into another's commit — **each session runs in its own git worktree on its own branch**, all sharing the one `.git` object store (no bare repo needed; worktrees attach to the regular checkout):

```bash
git worktree add ../rove-<topic> -b <branch> <base>   # e.g. ../rove-docs -b docs/restructure v2
git worktree list
git worktree remove ../rove-<topic>                   # when merged/abandoned; `git worktree prune` clears dead entries
```

Rules for the shared repo:
- The main checkout (`/home/user/src/rove`) is load-bearing — it holds the real `.git`; don't delete or move it.
- A branch can be checked out in only one worktree (git enforces this) — one branch per session by construction.
- Never switch the branch of, or run `git add -u` / `git commit` in, a checkout another session is using. Unexplained working-tree WIP is probably a sibling session's — examine it, stage only your own files, and never commit another window's work without confirmation.
- Smoke tests bind fixed ports (see the per-smoke port table in the scripts); don't run two smoke suites across worktrees simultaneously or they collide (`EADDRINUSE`).
