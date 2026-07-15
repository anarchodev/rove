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
| In-flight | **GitHub issues** | Active work. `gh issue list` / the tracker issues below. |
| Product / strategy | `strategy/` | Not engine mechanics. |
| Guides | `guides/` | Tutorials. |

**Lifecycle:** in-flight work lives in GitHub issues (a tracker issue per
arc, leaf issues per discrete item — the pattern the sim-parity audit
established). Before an issue closes, its durable residue graduates into
the repo: the *why* into `decisions.md`, the *mechanics* into the owning
`architecture/` doc. Long-form design content an issue was distilled from
survives at a SHA-pinned permalink in the issue body. (The former
`docs/plans/` folder was migrated to issues 2026-07-14; before that, ~20
finished plans had already been folded into `architecture/` and deleted.)

## Architecture (as-built references)

The maintained set. Subsystem-owned, kept current with the code.

- **[overview.md](architecture/overview.md)** — processes, request flow, module graph
- **[consensus-and-storage.md](architecture/consensus-and-storage.md)** — multi-raft, the Bridge/Node, per-tenant store, hibernation, tenant-move mechanism, durability/recovery
- **[effects-and-handlers.md](architecture/effects-and-handlers.md)** — the TEA handler model, the four reified primitives, durability-as-JS-shim, readset replication, held state
- **[routing-and-ingress.md](architecture/routing-and-ingress.md)** — front door, TLS/ACME, HTTP/1.1+H2+WebSocket ingress, the streaming substrate, blob coordinator
- **[websockets.md](architecture/websockets.md)** — inbound WS as-built: the DO-shaped tenant model, point-to-point vs broadcast fan-out, per-frame durability + the input gate, the `onMessage`/`onDisconnect` handler surface, front Extended CONNECT (RFC 8441)
- **[control-plane.md](architecture/control-plane.md)** — the directory, replication, tenant-move orchestration, plan/limits
- **[deployment-and-logs.md](architecture/deployment-and-logs.md)** — deploy publish, content-addressed assets, BlobStore, log-server
- **[replay-and-sim.md](architecture/replay-and-sim.md)** — the `run(world, code, on-miss)` model behind `rewind replay`/`sim`: a world = one activation's recorded inputs, a request = `foldl` of per-activation worlds, the five tape channels, and the as-built driver gaps. Read before sim/replay work
- **[configuration-and-network.md](architecture/configuration-and-network.md)** — per-binary env/port config map, the public/private firewall boundary + its security note, two-tier TLS architecture
- **[auth-and-domains.md](architecture/auth-and-domains.md)** — OIDC, custom domains, ACME, service/admin authz
- **[observability.md](architecture/observability.md)** — operator telemetry (Grafana Cloud)

> Design-rationale reference (not a primary subsystem doc, but cited by ~10 source files): [raft-native-alignment.md](architecture/raft-native-alignment.md) — how membership + catch-up were re-aligned onto raft-rs's native model (all phases landed; Phase 3 in `decisions.md` §10.12).
>
> Cross-cutting reference (cited by ~17 source files via its `§`-anchors): [format-versioning.md](architecture/format-versioning.md) — the as-built wire/on-disk/key-schema version scheme, the JS-engine-version tag, and the pre-launch freeze rules (shipped; the locked rules are also in `decisions.md` §14).
>
> Design-of-record references (graduated from `plans/`; cited by source + smoke scripts via their `§`/label anchors):
> - [cli-and-deploy.md](architecture/cli-and-deploy.md) — the `rewind-ops`/`rewind` CLIs + the deploy/publish split + the in-tenant `/_system/deploy` seam (shipped).
> - [auth-consolidation.md](architecture/auth-consolidation.md) — the two auth planes + the `rewind-logs.internal`/`rewind-cp.internal` trusted doors + tenant-scoped caps (shipped; cited by `A*`/`B*` labels). Subsystem doc is `auth-and-domains.md`.
> - [raft-best-practices.md](architecture/raft-best-practices.md) — election/heartbeat sizing (the `configuration-and-network.md` sizing authority) + the RawNode-FFI hardening backlog.
> - [consensus-robustness.md](architecture/consensus-robustness.md) — the error-classification + pin-coordination conventions, the fold-gate invariant, the shipped-proof record; open backlog = tracker #128.
> - [front-door-hardening.md](architecture/front-door-hardening.md) — the reverse-proxy protection set (all shipped; cited by the `front_*` teeth smokes).
> - [cp-membership-reconciler.md](architecture/cp-membership-reconciler.md) — the additive-only learner-first membership reconciler (shipped, live; follow-ons #125).
> - [package-resolution.md](architecture/package-resolution.md) + [package-compile-caching.md](architecture/package-compile-caching.md) — the `@scope/pkg` seam, manifest v2, and the no-compile-cache decision (shipped; PM tracker #130).
> - [builtin-libs.md](architecture/builtin-libs.md) + [privileged-surface.md](architecture/privileged-surface.md) — the `_system.*`/`globals/` shim model and the `__rove.*` privileged-ops surface (shipped; docs phases #87–#89, ratelimit #120).
> - [blob-write-recipes.md](architecture/blob-write-recipes.md) — the blob recipe substrate + `blob.seal` completion contract (phases A–C shipped; D–F = #93/#96/#97).

### Customer-facing contracts (kept alongside)

- **[effect-algebra.md](effect-algebra.md)** — the four-primitive effect model + the trigger-scope axes
- **[handler-shape.md](handler-shape.md)** — the customer handler API surface

## In-flight work (GitHub issues)

Active work on the current (V2) line lives in GitHub issues: a **tracker
issue per arc** holding a checklist of **leaf issues per discrete item**
(`gh issue list`; long-form design text survives at SHA-pinned permalinks
in the issue bodies). Before an issue closes, durable residue graduates
into `decisions.md` / `architecture/` (see Lifecycle above). The current
tracker map:

- **#126** — AI agent surface: `--json` audit, `rewind doctor`, scoped tokens, skill file (PLAN §10.10; leaves #79–#82)
- **#127** — fixture lifecycle + worker dry-run (PLAN §10.9 + §10.11; leaves #83–#86)
- **#128** — consensus robustness backlog (leaves #99–#108; conventions in [architecture/consensus-robustness.md](architecture/consensus-robustness.md))
- **#129** — refactor audit 2026-07, wave 4 (leaves #109–#118; waves 1–3 landed)
- **#130** — package manager: P-Wake/P-Rate/P-Reg/P-CLI/P-Lift/P-Nest (leaves #119–#124 + #4; engine shipped through P2)
- **#13–#19** — sim↔prod parity audit trackers (`sim-parity` label)
- `design`-labeled issues — north-stars / unscheduled designs: CP desired-state #90, retention & GC #91, staging/preview releases #92, blob phase-D redesign #93, the consensus scrutiny pair #107/#108
- singles: outbound WebSocket #94, users-lib #95, blob phases E/F #96/#97, reconciler follow-ons #125

- _The operator deploy plan (this operator's topology, hardware spec, DNS/TLS distribution, rollout history) lives in the private `rewind-infra` repo. The operator-neutral binary/port/firewall/TLS reference is [architecture/configuration-and-network.md](architecture/configuration-and-network.md). The WASM replay UI plan lives in the private rewind-apps repo (`replay/replay-wasm-plan.md`), alongside the porcelain it describes._

## Product & strategy

- [pricing-model.md](strategy/pricing-model.md) — pricing model (tier *enforcement* shipped — `architecture/control-plane.md` "Operational state")
- [platform-accounts-model.md](strategy/platform-accounts-model.md) — accounts/orgs/users (product layer, not the engine)
- [saas-in-a-box.md](strategy/saas-in-a-box.md) — the author-platform shape: per-end-customer tenants + the first-party library suite (users/billing/jobs/webhooks/flags/…)
- [dashboard-design-brief.md](strategy/dashboard-design-brief.md) — dashboard/replay UI brief
- users-lib — B2C passwordless auth library (issue #95)

## Guides

- [self-host.md](guides/self-host.md) — run the V2 stack on your own hosts: build, env, example systemd units, cluster bring-up
- [activitypub-tutorial.md](guides/activitypub-tutorial.md) — ActivityPub bot in ~30 lines
- [testing.md](guides/testing.md) — test handlers offline with `rewind test`: the `_tests/*.mjs` saga surface (`scenario`/`expect`, held-resume folds, WS, snapshots)
