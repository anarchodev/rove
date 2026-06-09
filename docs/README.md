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
| Guides | `activitypub-tutorial.md`, `flows/` | Tutorials. |

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
- **[control-plane.md](architecture/control-plane.md)** — the directory, replication, tenant-move orchestration, plan/limits
- **[deployment-and-logs.md](architecture/deployment-and-logs.md)** — deploy publish, content-addressed assets, BlobStore, log-server
- **[auth-and-domains.md](architecture/auth-and-domains.md)** — OIDC, custom domains, ACME, service/admin authz
- **[observability.md](architecture/observability.md)** — operator telemetry (Grafana Cloud)

### Customer-facing contracts (kept alongside)

- **[effect-algebra.md](effect-algebra.md)** — the four-primitive effect model + live effect audit
- **[handler-shape.md](handler-shape.md)** — the customer handler API surface

## In-flight plans

Active work on the current (V2) line. Each folds into `architecture/` on ship.

- [v2-build-order.md](v2-build-order.md) — Phase sequencing (Phase 7 in progress)
- [v2-cutover-checklist.md](v2-cutover-checklist.md) — living V1-deletion parity audit
- [v2-production-deploy-plan.md](v2-production-deploy-plan.md) — first production topology (not yet built)
- [handler-surface-impl-plan.md](handler-surface-impl-plan.md) — handler-surface Phase 2
- [durable-wake-plan.md](durable-wake-plan.md) — scheduler primitive (gap #6; P5+ pending)
- [websocket-plan.md](websocket-plan.md) — inbound WS (transport shipped, worker seam pending)
- [tape-minimization.md](tape-minimization.md) — the minimal replay tape (4 record kinds) + tape-by-reference design
- [plan-tiers.md](plan-tiers.md) — per-tenant tier enforcement
- [builtin-libs-docs-plan.md](builtin-libs-docs-plan.md) — `_system.*` + JS shim docs
- [replay-wasm-plan.md](replay-wasm-plan.md) — WASM replay UI (§8.6+ deferred)
- [sim-test-framework.md](sim-test-framework.md) · [fixture-lifecycle.md](fixture-lifecycle.md) · [agent-surface.md](agent-surface.md) — replay/sim/agent surface (Phase 12–14)

## Product & strategy

- [pricing-model.md](pricing-model.md) · [plan-tiers.md](plan-tiers.md) — pricing + tiers
- [platform-accounts-model.md](platform-accounts-model.md) — accounts/orgs/users (product layer, not the engine)
- [dashboard-design-brief.md](dashboard-design-brief.md) — dashboard/replay UI brief
- [users-lib-plan.md](users-lib-plan.md) — B2C passwordless auth library

## Guides

- [activitypub-tutorial.md](activitypub-tutorial.md) — ActivityPub bot in ~30 lines
- [flows/signup.md](flows/signup.md) — end-to-end signup walkthrough
