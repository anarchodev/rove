# V2 cutover checklist — V1 → V2 parity audit

> **Status: living checklist (2026-06-07).** The hard list of what must be true
> before `src/` (V1) is deleted and `src-v2/ → src/`. Cutover gate
> (`docs/v2-build-order.md` §Cutover): *delete `src/`, rename `src-v2/ → src/`,
> once V2 is at parity and the control plane is robust. No data to migrate, so
> cutover is a code operation.* Companions: `docs/v2-build-order.md`,
> [`v2-front-door-architecture.md`](v2-front-door-architecture.md) (the
> committed CF-free edge — supersedes gap #3 below),
> [`v2-cp-operational-state.md`](v2-cp-operational-state.md) (gap #1),
> [`v2-phase5-multinode.md`](v2-phase5-multinode.md),
> [`v2-phase6-hibernation.md`](v2-phase6-hibernation.md).

## Orientation

The V2 worker (`src-v2/rewind/main.zig`) **reuses the V1 modules wholesale**
(`rove-js`, `rove-files`, `rove-blob`, `rove-log-server`, `rove-tenant`,
`rove-qjs`), so the entire request/dispatch/effect/KV-durability core carries
over. The engine work (Phases 0–7) has landed. The remaining gaps are
concentrated at the **edge** (front door) and in **operational state**
(plan/limits/domains/certs) — both CP-shaped.

## ✅ At parity (reused V1 modules, wired in `src-v2/rewind/main.zig`)

| Subsystem | Evidence |
|---|---|
| JS dispatch + effect reification (parked continuations, durable wakes, cron, owed retries) | `src/js/dispatcher.zig`, `worker_dispatch.zig` (reused) |
| Per-tenant KV durability (TrackedTxn overlay → raft → commit) | `src-v2/kv/bridge.zig` + `node.zig` (multi-raft) |
| `http.fetch` engine, proxy/serve-or-forward, blob coordination | `main.zig:387,389,390` |
| Deployment loader + bytecode cache | `main.zig:386` |
| Blob backend (fs/S3) + log batch store | `main.zig:337-338,377-379` |
| `/_system/*` worker control routes (health, leader, metrics, services-token, release, admin-kv, raft-snapshot) | `worker_dispatch.zig:1066-1163` (same code as V1) |
| `/_system/v2-*` move surface | `src/js/v2_move.zig:67-119` |
| Static-asset serving, message router, built-in `__system/*` modules | reused |
| CP directory replication / HA / crash recovery | done — Phase 7 (`dc34df3`→`f80f9f0`, `2a7c1d9`) |

## 🔴 Real parity gaps — block cutover

**1. Plan / limits — CP foundation SHIPPED; DP delivery + enforcement remain.**
The [`v2-cp-operational-state.md`](v2-cp-operational-state.md) build, in 3 steps:
   - **Step 1 (CP-side) — ✅ SHIPPED** (`2ddb662`). `plan/{tenant}` is a sibling
     axis in the CP `__directory__` group: `directory.zig` `plans` projection +
     `setPlan`/`planForOwned`; `POST /_control/plan` (admin-gated write) + `GET
     /_cp/plan?tenant=` (DP read); replicated via the apply observer + durable
     across restart. Proven by `scripts/cp_plan_smoke.py` + an inline unit test.
     The CP stores the `{tier, overrides}` blob verbatim (dumb CP).
   - **Step 2 (delivery) — TODO.** The worker learns its plan: cold-start/move →
     plan rides the attach handshake (`v2_move.zig`); live change → CP
     single-target push to the serving cluster → DP plan-generation bump.
   - **Step 3 (enforcement) — TODO** (`plan-tiers.md` verbatim). V2 worker still
     runs `rate_limit_caps = .{}` (`rewind/main.zig:141`). New `src/js/plan.zig`
     (`Tier` table + `effective`); cache `PlanLimits` on `TenantSlot`; wire
     `limiter.zig` per-instance caps + generation-refresh; incremental `413` body
     gate; server-side retention clamp on log/tape queries.

**2. Domain → tenant routing is a static env map.** Front door resolves host via
`HostMap` seeded from `REWIND_HOSTS` (`front/main.zig:165,1273`). V1 has a
dynamic replicated domain index (`__root__.db`). Cutover needs the replicated
domain index in the CP directory (deferred at `directory.zig:56-57`). Without it
there's no runtime custom-domain provisioning.

**3. Edge TLS + ACME for custom domains — own it, no Cloudflare.**
*Superseded by [`v2-front-door-architecture.md`](v2-front-door-architecture.md)
(Branch 2, committed 2026-06-07).* The front door is bare h2c
(`front/main.zig`) and the worker is `tls_config = null` (`main.zig:137`); V1
terminated TLS + ran a leader-pinned ACME issuer (`loop46/acme.zig`,
`src/acme/`). The decision is **not** to outsource to Cloudflare (CF can't proxy
h2c, and its only unique value was custom-hostname automation — not DDoS/WAF,
which the host provides). Instead:
   - Front door **terminates public h2-over-TLS** (reuse rove-h2 TLS path), SNI
     cert selection; front-door → DP is private h2c.
   - **Cert state moves into the CP** `__directory__` group (placement-
     independent), replacing V1's per-cluster `__root__.db` `cert/{host}`.
   - **One leader-elected ACME issuer**, evolved from `loop46/acme.zig` —
     wildcard via DNS-01, custom hosts via HTTP-01 / TLS-ALPN-01.
   - V1 ACME is **evolved + re-homed, not deleted.**
   This is a contained CP-shaped build, not a vendor outsource.

**4. Direct multi-node placement without a move.** A tenant's raft group only
forms via the attach fan-out of a move-in
([`v2-phase5-multinode.md`](v2-phase5-multinode.md) follow-ups). Normal
provisioning of a brand-new tenant onto a multi-node cluster needs an explicit
formation step; `v2-kv` PUT leader-gating depends on the group already existing.

**5. Tenant provisioning / `createInstance` path.** V1 has `seed`,
`provisionInstance`, admin `createInstance` (envelope-2 `root_writeset` →
`__root__.db`). In V2 `__root__.db` is per-cluster and placement lives in the CP.
No V2 brand-new-tenant create+place flow has been confirmed beyond the move path;
`v2-cp-operational-state.md` marks `instance/{id}` provisioning as "⚠️ maybe /
needs thought." Confirm or build the create-a-new-tenant path end to end.

## ✅ Front-door tier split (architectural, was blocking the edge gaps) — SHIPPED

Per [`v2-front-door-architecture.md`](v2-front-door-architecture.md), the
prototype welded the CP raft directory to the request-path proxy, so every
front-door replica was a CP voter (`REWIND_CP_NODE_ID/VOTERS/PEERS`) →
front-door count == voter count (inverted scaling). **Done:**
   - **CP is its own binary + raft cluster** — `src-v2/cp/main.zig` (`rewind-cp`):
     directory raft + move orchestration (`/_control/move[-live]`) + `/_cp/route`
     + `/_cp/leader` + reconciliation + CP-HA forwarding.
   - **Front door is a stateless proxy** — `src-v2/front/main.zig`: resolves
     placement via the CP's `/_cp/route` (short-TTL cache, `REWIND_CP_URL`),
     leader-aware forward; no `bridge`/`cp-directory` (15M vs the CP's 113M). The
     read-replica seam is cached-query (serve-or-forward is the staleness
     backstop), not a raft learner at the edge.
   - All nine v2 edge smokes run on the two-process topology via
     `scripts/v2_topology.py` (`spawn_cp`/`spawn_front`) and pass (commits
     `91ad279`→ the smoke-fan-out series).

   **Still open on the edge** (the gaps above): TLS termination at the front door
   (gap #3), the L4 (TCP+ALPN passthrough) reference deployment, and the cache's
   `REWIND_ROUTE_CACHE_MS=0` (always-fresh) is what the move smokes use since
   `/_system/v2-kv` is not a serve-or-forward path.

## 🟡 By-design / hardening — confirm, not hard blockers

| Item | Status |
|---|---|
| No TLS/auth/413/429 **at the L4 ingress** | By design — ingress is L4 passthrough; the front door terminates TLS, the DP enforces rate/413 (gap #1 must land). |
| Front-door response headers dropped (incl. content-type) | Explicit Phase-3 deferral (`front/main.zig:26-28`) — **mandatory before cutover** (content-type passthrough is not optional). |
| Front-door connection pooling (one curl/request, sequential) | Explicit deferral (`front/main.zig:24-25`) — perf hardening. |
| Cluster-scale live-traffic hibernation macrobench | Phase 6 follow-up — proof, not function. |
| Shared-WAL segment GC + per-group compaction | `compact_wal=true` landed (`e0326cf`); segment GC still open. |
| `zig build test` broken on `v2` (frozen V1 SQLite modules) | Test hygiene — after the `src-v2 → src` rename the default test step should be green again. |

## Suggested cutover order

1. ~~**Split the CP out** + front door becomes a stateless read-replica.~~ ✅
   **SHIPPED** — `rewind-cp` + slimmed `rewind-front`, all 9 edge smokes green.
2. **Plan/limits** (gap #1) — ✅ **all three steps shipped.** Step 1 (CP axis)
   `2ddb662`; step 2 (DP delivery via attach handshake + live push:
   `rove-plan` tier table + `effective()`; `TenantSlot.plan`/`plan_gen` cache;
   `v2-attach` carries `X-Rewind-Plan` + `POST /_system/v2-plan` live push;
   `cp_plan_delivery_smoke` green); step 3 (DP enforcement — all three levers of
   `plan-tiers.md`): Lever 1 rate caps + generation-refresh, Lever 2 413 body
   gate (both in `worker_dispatch` off `slot.effectivePlan()`), Lever 3
   retention read-clamp in the log-query surface (`rove-log-server` resolves the
   window from the CP `/_cp/plan`, cached, and clamps list/show/count).
   The tier table was hoisted into a shared **`rove-plan`** leaf so both the
   worker and the log-server import the one table without a cycle.
   Follow-ups (non-blocking): a deployed-handler 429/413 e2e smoke (move smokes
   exercise only raw `v2-kv`, not deployed handlers); standing the V2 log-query
   surface into the topology + wiring its `cp_url`.
3. **Replicated domain index** (gap #2) — same directory group, sibling axis.
4. **Edge TLS termination + cert-state-in-CP + single ACME issuer** (gap #3) —
   per `v2-front-door-architecture.md`.
5. **Tenant provisioning + multi-node formation** (gaps #4, #5) — the
   create-a-new-tenant path end to end.
6. **Front-door content-type passthrough** (🟡 but mandatory).
7. Then the `src-v2 → src` code-move cutover; fix `zig build test`; run hardening
   benches.

The headline: **the engine, the differentiator, AND the front-door/CP split are
done; the remaining work is operational-state (plan/domains/certs/provisioning)
— and almost all of it lands in the CP directory whose replication machinery is
already built.**
