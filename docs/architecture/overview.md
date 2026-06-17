# Architecture overview

> 🟢 **As-built reference.** The orientation map: what the processes are, how a
> request flows between them, and which `architecture/` doc owns each subsystem.
> Start here, then follow the pointer into the subsystem you care about. For
> product direction and roadmap see [PLAN.md](../PLAN.md); for *why* the
> structural calls were made see [decisions.md](../decisions.md).

## rove vs rewind.js

`rove` is the Zig systems library — the engine. **rewind.js** is the product
built on it: a purely-functional serverless platform where each customer tenant
is an isolated, replicated, replayable unit. (The internal name `Loop46`
persists in some code; the V1 product binary `loop46` and its willemt-raft
engine are retired — V2 is the live line.)

## The processes (V2)

Five binaries, each a `zig build` step:

| Binary | Build step | Role | Owns doc |
|---|---|---|---|
| **rewind-worker** | `zig build rewind-worker` | The **worker / data-plane node**. Runs the QuickJS (arenajs) handler runtime, hosts a per-tenant `Bridge` over the multi-raft `Node`, serves HTTP/2. One per cluster node. | [consensus-and-storage](consensus-and-storage.md), [effects-and-handlers](effects-and-handlers.md) |
| **rewind-front** | `zig build rewind-front` | The **front door**. Stateless edge: terminates TLS (own ACME), routes `Host → cluster` via the directory, proxies leader-aware, orchestrates tenant moves. | [routing-and-ingress](routing-and-ingress.md) |
| **rewind-cp** | `zig build rewind-cp` | The **control plane**. The authoritative tenant directory + provisioning; per-tenant operational state (plan/limits). | [control-plane](control-plane.md) |
| **files-server-v2** | `zig build files-server-v2` | The **deploy publisher**. Cluster-free: compiles/uploads a deployment, writes the S3 manifest, signals the release. | [deployment-and-logs](deployment-and-logs.md) |
| **log-server** | (standalone) | Per-tenant request-log query surface over the S3 batch store. | [deployment-and-logs](deployment-and-logs.md) |

## Request flow (inbound HTTP)

```
client
  │  TLS, Host header
  ▼
rewind-front ──(Host → cluster, via CP directory)──▶ pick cluster
  │  leader-aware proxy (retry-on-503 self-routes writes to the group leader)
  ▼
rewind (worker node)
  │  dispatchOnce → JS handler activation (arenajs per-request arena)
  │  kv.* writes → speculative kvexp overlay + parallel raft propose
  ▼
Bridge → Node (raft-rs group for this tenant) ──▶ quorum ──▶ commit overlay
  │  blob bytes (source/assets) served from the shared content-addressed store
  ▼
response ──▶ front ──▶ client
```

Read-only requests commit locally and **never** propose to raft (the read fast
path — decisions.md §2.5). Held connections (SSE / WebSocket / streaming) and
connectionless effects (`webhook.send` / `cron` / `schedule`) layer on top of
this — see [effects-and-handlers](effects-and-handlers.md).

## Module dependency graph (core)

```
rove (core ECS)  ←── rove-io (io_uring) ←── rove-h2 (HTTP/2 + nghttp2)
                                                  ↑
rove-blob (fs/s3 blob storage) ────────┐          │
rove-files (content-addressed files) ──┤          │
rove-log (per-tenant request logs) ────┤          │
rove-tape (deterministic replay) ──────┤          │
rove-tenant (account/domain metadata) ─┤          │
rove-qjs (arenajs JS engine wrapper) ──┤          │
src/consensus (Bridge + Node, raft-rs) ┤          │
                                       ↓          │
                              rove-js (worker dispatcher) ──┘
```

Core ECS pattern (the `rove` module): **Entity** (index+generation handle),
**Row** (compile-time component shape), **Collection** (Structure-of-Arrays
storage), **Registry** (creates/destroys/moves entities). Systems are pure
functions run between `poll()` and `reg.flush()`. State is **collection
membership**, not flags — this is load-bearing across the codebase
(decisions.md §3.1).

## Dependencies (pinned-and-fetched)

Third-party deps are pinned in `build.zig.zon` (Zig/C) and Cargo (Rust), fetched
at first build (the first build needs network). The keepers: **arenajs** (the
dual-arena QuickJS-ng fork), **kvexp** (the per-tenant LMDB-backed KV under the
speculative overlay), **raft-rs-zig** (the V2 multi-raft engine). There are no
vendored deps left. See [decisions.md §10.7](../decisions.md) for the codec/
vendoring call.

## Where to go next

- Replication, the per-tenant store, hibernation, tenant move → [consensus-and-storage](consensus-and-storage.md)
- The handler model, effects, durability, streaming → [effects-and-handlers](effects-and-handlers.md)
- Front door, TLS/ACME, HTTP/1.1+H2+WS ingress, held connections → [routing-and-ingress](routing-and-ingress.md)
- The directory, tenant move orchestration, plan/limits → [control-plane](control-plane.md)
- Deploy publish, content-addressed assets, logs → [deployment-and-logs](deployment-and-logs.md)
- OIDC + custom domains → [auth-and-domains](auth-and-domains.md)
- Operator telemetry → [observability](observability.md)
