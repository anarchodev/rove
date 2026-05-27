# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is rove

Rove is a Zig systems library for building distributed serverless worker infrastructure. It provides content-addressed code deployment, a QuickJS-based JS runtime, an HTTP/2 server, and a distributed KV store with Raft consensus. All C dependencies are vendored — no network access or package managers needed.

## Product direction

`rove` is the engine for **rewind.js**, a purely-functional serverless product. Locked architecture and phased build plan live in [`docs/PLAN.md`](docs/PLAN.md). Read it before making decisions that could contradict existing direction (domain layout, pure-function execution model, Cmd-pattern external effects via **one outbound HTTP primitive** with `webhook.send` / `email.send` / `retry.*` as **JS-shim libraries that compose durability on top of it** — see `effect-algebra.md` §6 rule 4 + `effect-reification-plan.md` Phase 5; page-level encryption at rest; etc.). Section 7 of that doc lists decisions that were explicitly considered and rejected — do not re-propose those without new information. Sub-plans in `docs/` (`files-server-plan.md`, `logs-plan.md`, `snapshot-plan.md`, `http-send-plan.md`, `sim-test-framework.md`, `fixture-lifecycle.md`, `agent-surface.md`, `observability-plan.md`, `replay-wasm-plan.md`, `dashboard-design-brief.md`, `auth-domain-plan.md`, `builtin-libs-docs-plan.md`, `users-lib-plan.md`, `connection-actor-plan.md`, `effect-algebra.md`, `curl-multi-plan.md`) elaborate specific PLAN sections. `docs/effect-algebra.md` is the cross-cutting model — the four-primitive frame every external effect fits, plus the live effect audit. PLAN §13 is the live process / surface map.

## Build commands

```bash
zig build              # Build all modules and examples
zig build test         # Run all unit tests (inline Zig tests across all modules)
zig build loop46       # Build/run the loop46 product binary
                       # (subcommands: `loop46 dev` for local quickstart,
                       # `loop46 worker` for production)
zig build echo-server  # Run the TCP echo server example
zig build h2-echo-server  # Run the HTTP/2 echo server example
```

Requires Zig 0.15.0+. System libraries needed: nghttp2, OpenSSL (ssl + crypto), SQLite3.

## Smoke tests

Python scripts in `scripts/` drive end-to-end tests against running binaries.
Each one spawns its own cluster + standalones and tears them down via
`atexit` / signal handlers (no `pkill -f` fragility).

```bash
python3 scripts/ctl_smoke.py            # /_system/* control surface
python3 scripts/files_server_smoke.py   # files-server compile/upload/deploy/fetch
python3 scripts/penalty_smoke.py        # penalty box system
python3 scripts/leader_failover_smoke.py  # raft leader change preserves http.send
```

`scripts/smoke_lib.py` is the shared harness — `Cluster.spawn` /
`discover_leader` / `spawn_files_server` / `mint_services_token` /
process-tracking + cleanup primitives. New smokes should follow the
existing tier-1 ones (e.g. `cookie_auth_smoke.py`) for the canonical
shape. The Python harness replaced the bash `_smoke_helpers.sh` flow
in commits 431722b → 95e53f3.

## Architecture

### Module dependency graph

```
rove (core ECS)  ←── rove-io (io_uring) ←── rove-h2 (HTTP/2 + nghttp2)
                                                  ↑
rove-kv (KV + Raft + SQLite) ──────────┐          │
rove-blob (fs/s3 blob storage) ────────┤          │
rove-files (content-addressed files) ──┤          │
rove-log (per-tenant request logs) ────┤          │
rove-tape (deterministic replay) ──────┤          │
rove-tenant (account/domain metadata) ─┤          │
rove-qjs (arenajs JS engine wrapper) ──┤          │
                                       ↓          │
                              rove-js (worker dispatcher) ──┘
                              rove-files-server (compile/deploy HTTP surface)
                              rove-log-server (log query HTTP surface)
                              rove-sse-server (SSE notifications — runs as a
                                               loop46 thread, single-node;
                                               imported by loop46 + rove-js)
```

**rove-kv is a standalone leaf module** — it does NOT depend on rove or rove-io. Its raft networking (`raft_net`) uses io_uring directly via liburing, bypassing the rove-io abstraction.

### Core ECS pattern (rove module)

The foundational abstraction used throughout:
- **Entity** — lightweight handle (index + generation) for safe identity tracking
- **Row** — compile-time type composition defining an entity's component shape
- **Collection** — SoA (Structure-of-Arrays) storage with alignment + component lifecycle
- **Registry** — manages multiple collections; handles entity creation, destruction, and moves

Systems are pure functions called between `poll()` and `reg.flush()`, not methods on the registry.

### Request lifecycle (rove-js worker)

```
h2.request_out → dispatchPending → [drainRaftPending if writes] → h2.response_in → h2.response_out
```

Each JS request gets a fresh JS context via arenajs's dual-arena reset (one cursor write per request — see `vendor/arenajs/README.md`). The base arena is built once at worker startup and shared across all requests on the thread; the per-request arena is reset between handler invocations.

### Data durability model

Local KV writes land in a speculative volatile overlay (kvexp), then a parallel Raft propose handles replication. On quorum the overlay commits (`TrackedTxn.commit()`); on fault/timeout it rolls back (`TrackedTxn.rollback()`). A pre-quorum crash needs no undo log — the overlay is volatile, so it never reached disk.

### What replicates through raft

Envelopes are typed byte blobs (`src/js/apply.zig`). Only three types are live (post-Phase-5.5, post-`http.send` Option-(b) re-platform 2026-05-19):

| Type | Target store | Producer |
|---|---|---|
| `0` writeset | `{data_dir}/{id}/app.db` | Customer handler `kv.*` via `TrackedTxn` + writeset; `_deploy/current` release marker; the `webhook.send` / `email.send` JS-shim's `_send/owed/{id}` markers ride here too (ordinary kv writes — no apply-time special-case post `effect-reification-plan.md` Phase 5) |
| `1` multi | per-inner-envelope target | Worker dispatcher — atomically bundles multiple writeset envelopes into one raft entry |
| `2` root_writeset | `{data_dir}/__root__.db` | `provisionInstance` / admin `createInstance`'s `tenant.createInstance`; admin JS `platform.root.*`; ACME `cert/{host}` (auth-domain-plan §3.2) |

Retired type bytes — the decoder rejects each loudly, so any stale raft-log entry surfaces instead of silently mis-applying: `log_batch` (originally type 1) and `files_writeset` (3) in Phase 5.5 (a) / (e) — log batches go S3-direct per `docs/logs-plan.md`, per-tenant deployment manifests live in a `deployments/` BlobBackend per `docs/files-server-plan.md`; the dedicated webhook envelopes (4/5/6) on 2026-05-09; and `schedule_upsert/complete/cancel/demote` (8/9/10/11) on 2026-05-19 in the `http.send` Option-(b) re-platform — there is no `schedules.db` and no schedule-server thread. The per-node leader-local `SendDispatch` that Option-(b) introduced was itself retired on 2026-05-24 per the durability-as-JS-shim decision (`effect-reification-plan.md` Phase 5 PR-3, commit `b908953`); the `_send/owed/{id}` markers are now written by `webhook.send.js` / `email.send.js` as ordinary envelope-0 kv keys and the apply-time special-cases are gone. `multi` was renumbered from type 7 to type 1 to match `kv.cluster.ENVELOPE_TYPE_MULTI`. See `docs/effect-algebra.md` for how envelopes fit the effect model, PLAN.md §10.2 for the full evolution table, and §13 for the live process map.

### Blob replication (multi-node)

Blob bytes (source, bytecode, static assets) live in `{data_dir}/{id}/file-blobs/` and are **not** carried through raft envelopes — a 1MB static blob per envelope would blow the raft log size/latency budget. Single-node: `FilesystemBlobStore` works as-is. **Multi-node requires a shared `BlobStore` backend** — all nodes read the same content-addressed store. Two options:

1. **Shared filesystem mount** (NFS, EFS, Ceph) at `{data_dir}` on every node. Zero new code — `FilesystemBlobStore` treats the mount point like any other directory.
2. **S3 / object store** — `S3BlobStore` in `rove-blob` (path-style, SigV4-signed; tested against OVH but works against AWS / MinIO / R2 / B2). Cleaner ops story, more setup.

Backend pick is process-wide via `BLOB_BACKEND=fs|s3` (+ `S3_ENDPOINT` / `S3_REGION` / `S3_BUCKET` / `S3_KEY_PREFIX_BASE` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `S3_USE_TLS`) read by the `loop46` binary at startup. The chosen `blob_mod.BackendConfig` threads through `WorkerConfig.blob_backend`, `ApplyCtx.blob_backend_cfg`, and the files-server / log-server `spawn` so every per-tenant backend on the node opens against the same store. Per-tenant scoping in S3 is the key prefix `{key_prefix_base}{instance_id}/{file-blobs|log-blobs}/`, mirroring the on-disk layout exactly so leader and followers hit identical keys.

Raft replicates the manifest (the `file/{path}` key → `{hash, kind, content_type}` pointer); the shared backend serves the bytes referenced by those hashes. Followers apply the manifest ops; readers fetch the blob bytes from whichever backend `rove-blob` is configured with.

### Vendored C code

See `vendor/README.md` for upstream revisions, patches, and maintenance procedures:
- **arenajs** — fork of quickjs-ng with a dual bump arena (base + per-request); per-request reset is one cursor write instead of memcpy. Replaces the previously-vendored quickjs-ng + deterministic-init patch. See `vendor/arenajs/README.md` for the pinned commit and inherited constraints.
- **willemt/raft** — consensus library, unmodified

## Conventions

- Tests are inline Zig tests (`test "description" { ... }`) co-located with the code they cover.
- Module public API is exported through each module's `root.zig`.
- No async/await — concurrency uses collection-based polling + phase-based dispatch.
- Comments reference a "Phase" numbering system tracking the incremental delivery plan; phases run 0 through 14 (with 5.5 as the storage-scalability bucket). See `docs/PLAN.md` §3 for current phase content and §10.16 for the beta / 1.0 / post-1.0 launch sequencing.
