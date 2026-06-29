# rove / rewind.js — documentation map

`rove` is the Zig engine; **rewind.js** is the product built on it. Code is the
ground truth for *mechanics*; these docs explain *why* and *how the pieces fit*.

## Start here

- **[PLAN.md](PLAN.md)** — product architecture + phased roadmap (source of truth
  for direction). Read §7 (considered-and-rejected) and §13 (live process map)
  before proposing anything structural.
- **[decisions.md](decisions.md)** — locked decisions + rejected alternatives
  (the *why*). Check here before re-litigating a settled call.
- **[architecture/overview.md](architecture/overview.md)** — the orientation map:
  processes, request flow, module graph, and where to go next.
- **[../CLAUDE.md](../CLAUDE.md)** — repo orientation, build/test commands.

## How this folder is organized

Three durable layers, plus working docs:

| Layer | Where | What |
|---|---|---|
| **Why** | `decisions.md` | Locked decisions + rejected paths. |
| **What / roadmap** | `PLAN.md` | Product direction, phases. |
| **How it works (as-built)** | `architecture/` | One doc per subsystem, kept current. |
| Customer contracts | `effect-algebra.md`, `handler-shape.md` | The effect model + handler API surface. |
| In-flight | the `*-plan.md` / `v2-*.md` below | Active work; folds into `architecture/` on ship, then deleted. |
| Product / strategy | `pricing-model.md`, etc. | Not engine mechanics. |
| Guides | `activitypub-tutorial.md` | Tutorials. |

**Lifecycle:** a plan, once shipped, has its *why* harvested into `decisions.md`
and its *mechanics* folded into the owning `architecture/` doc — then the plan is
deleted (it survives in git history). That is what keeps this folder from
re-accumulating. ~20 finished plans were folded and removed in the first pass.

## Architecture (as-built references)

The maintained set. Subsystem-owned, kept current with the code.

- **[overview.md](architecture/overview.md)** — processes, request flow, module graph
- **[consensus-and-storage.md](architecture/consensus-and-storage.md)** — multi-raft, the Bridge/Node, per-tenant store, hibernation, tenant-move mechanism, durability/recovery
- **[effects-and-handlers.md](architecture/effects-and-handlers.md)** — the TEA handler model, the four reified primitives, durability-as-JS-shim, readset replication, held state
- **[routing-and-ingress.md](architecture/routing-and-ingress.md)** — front door, TLS/ACME, HTTP/1.1+H2+WebSocket ingress, the streaming substrate, blob coordinator
- **[websockets.md](architecture/websockets.md)** — inbound WS as-built: the DO-shaped tenant model, point-to-point vs broadcast fan-out, per-frame durability + the input gate, the `onMessage`/`onDisconnect` handler surface, front Extended CONNECT (RFC 8441)
- **[control-plane.md](architecture/control-plane.md)** — the directory, replication, tenant-move orchestration, plan/limits
- **[deployment-and-logs.md](architecture/deployment-and-logs.md)** — deploy publish, content-addressed assets, BlobStore, log-server
- **[auth-and-domains.md](architecture/auth-and-domains.md)** — OIDC, custom domains, ACME, service/admin authz
- **[observability.md](architecture/observability.md)** — operator telemetry (Grafana Cloud)

### Customer-facing contracts (kept alongside)

- **[effect-algebra.md](effect-algebra.md)** — the four-primitive effect model + the trigger-scope axes
- **[handler-shape.md](handler-shape.md)** — the customer handler API surface

## In-flight plans

Active work on the current (V2) line. Each folds into `architecture/` on ship.
(Folded + deleted 2026-06-10, all shipped: `v2-build-order`,
`v2-cutover-checklist`, `durable-wake-plan`, `blob-storage-plan`,
`plan-tiers` — they survive in git history. `inbound-chunk-plan` joined
them 2026-06-29: its as-built mechanism folded into
`architecture/effects-and-handlers.md`, "Streaming inbound body".)

- [v2-production-deploy-plan.md](v2-production-deploy-plan.md) — first production topology (not yet built)
- [step3-auth-plan.md](step3-auth-plan.md) — Step 3 auth consolidation: sequenced execution plan (OIDC machinery is written; remaining = wire + deploy + close the log-server tenant-scoping gap). Design rationale in `rewind-cli-plan.md` §7
- [cp-desired-state-target.md](cp-desired-state-target.md) — north-star (not yet built): CP owns all per-tenant desired-state incl. release; workers reconcile; one S2S key (move-secret); root token retires. The arc B3/B4 point at
- [websocket-plan.md](websocket-plan.md) — **outbound** WS only (a handler as client of an upstream WS server — atproto firehose / Pub/Sub; unbuilt, ~1–2 weeks). Inbound WS shipped → `architecture/websockets.md`
- [retention-and-gc.md](retention-and-gc.md) — the one compacting GC across log-blobs / kv pages / `_pool` bodies / tape blobs; capacity-based retention; the input-home pinning obligation (unbuilt). The minimal-tape four-record-kinds synthesis now lives in `decisions.md` §3.9
- [builtin-libs-docs-plan.md](builtin-libs-docs-plan.md) — `_system.*` + JS shim docs
- [replay-wasm-plan.md](replay-wasm-plan.md) — WASM replay UI (§8.6+ deferred)
- [sim-test-framework.md](sim-test-framework.md) · [fixture-lifecycle.md](fixture-lifecycle.md) · [agent-surface.md](agent-surface.md) — replay/sim/agent surface (Phase 12–14)

## Product & strategy

- [pricing-model.md](pricing-model.md) — pricing model (tier *enforcement* shipped — `architecture/control-plane.md` "Operational state")
- [platform-accounts-model.md](platform-accounts-model.md) — accounts/orgs/users (product layer, not the engine)
- [saas-in-a-box.md](saas-in-a-box.md) — the author-platform shape: per-end-customer tenants + the first-party library suite (users/billing/jobs/webhooks/flags/…)
- [dashboard-design-brief.md](dashboard-design-brief.md) — dashboard/replay UI brief
- [users-lib-plan.md](users-lib-plan.md) — B2C passwordless auth library

## Guides

- [activitypub-tutorial.md](activitypub-tutorial.md) — ActivityPub bot in ~30 lines
