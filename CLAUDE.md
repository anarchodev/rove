# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is rove

Rove is a Zig systems library for building distributed serverless worker infrastructure. It provides content-addressed code deployment, a QuickJS-based JS runtime, an HTTP/2 server, and a distributed KV store with Raft consensus. All C dependencies are vendored — no network access or package managers needed.

## Product direction

`rove` is the engine for **Loop46**, a purely-functional serverless product. Locked architecture and phased build plan live in [`docs/PLAN.md`](docs/PLAN.md). Read it before making decisions that could contradict existing direction (domain layout, pure-function execution model, transactional outbox for all external effects, page-level encryption at rest, etc.). Section 7 of that doc lists decisions that were explicitly considered and rejected — do not re-propose those without new information.

## Build commands

```bash
zig build              # Build all modules and examples
zig build test         # Run all unit tests (inline Zig tests across all modules)
zig build js-worker    # Run the full rove-js worker smoke server
zig build echo-server  # Run the TCP echo server example
zig build h2-echo-server  # Run the HTTP/2 echo server example
```

Requires Zig 0.15.0+. System libraries needed: nghttp2, OpenSSL (ssl + crypto), SQLite3.

## Smoke tests

Shell scripts in `scripts/` drive end-to-end tests against running binaries:

```bash
scripts/files_server_smoke.sh  # files-server compile/upload/deploy/fetch
scripts/ctl_smoke.sh           # /_system/* control surface
scripts/penalty_smoke.sh       # penalty box system
scripts/proxy_smoke.sh         # proxy/forwarding
```

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
rove-qjs (QuickJS-ng wrapper) ─────────┤          │
                                       ↓          │
                              rove-js (worker dispatcher) ──┘
                              rove-files-server (compile/deploy HTTP surface)
                              rove-log-server (log query HTTP surface)
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

Each JS request gets a fresh QuickJS context. Snapshot/restore (memcpy of a pre-seeded arena) is the fast path for per-request context creation instead of full `JS_NewRuntime`.

### Data durability model

Local KV writes commit immediately (releasing the lock fast), then a parallel Raft propose handles replication. On fault/timeout, a compensating rollback via undo log fires.

### What replicates through raft

Envelopes are typed byte blobs (`src/js/apply.zig`):

| Type | Target store | Producer |
|---|---|---|
| `0` writeset | `{data_dir}/{id}/app.db` | Customer handler `kv.*` via `TrackedTxn` + writeset |
| `1` log_batch | `{data_dir}/{id}/log.db` | Worker `flushLogs` |
| `2` root_writeset | `{data_dir}/__root__.db` | Signup's `tenant.createInstance`; admin JS `platform.root.*` |
| `3` files_writeset | `{data_dir}/{id}/files.db` | Signup's `deployStarterContent`; files-server `putFileAndDeploy` |

### Blob replication (multi-node)

Blob bytes (source, bytecode, static assets) live in `{data_dir}/{id}/file-blobs/` and are **not** carried through raft envelopes — a 1MB static blob per envelope would blow the raft log size/latency budget. Single-node: `FilesystemBlobStore` works as-is. **Multi-node requires a shared `BlobStore` backend** — all nodes read the same content-addressed store. Two options:

1. **Shared filesystem mount** (NFS, EFS, Ceph) at `{data_dir}` on every node. Zero new code — `FilesystemBlobStore` treats the mount point like any other directory.
2. **S3 / object store** — a future `S3BlobStore` impl in `rove-blob` (not yet written). Cleaner ops story, more setup.

Raft replicates the manifest (the `file/{path}` key → `{hash, kind, content_type}` pointer); the shared backend serves the bytes referenced by those hashes. Followers apply the manifest ops; readers fetch the blob bytes from whichever backend `rove-blob` is configured with.

### Vendored C code

See `vendor/README.md` for upstream revisions, patches, and maintenance procedures:
- **quickjs-ng** (v0.13.0) — patched for deterministic `JS_NewContext` (zeroed volatile slots)
- **willemt/raft** — consensus library, unmodified

## Conventions

- Tests are inline Zig tests (`test "description" { ... }`) co-located with the code they cover.
- Module public API is exported through each module's `root.zig`.
- No async/await — concurrency uses collection-based polling + phase-based dispatch.
- Comments reference a "Phase" numbering system (0–6) tracking the incremental delivery plan.
