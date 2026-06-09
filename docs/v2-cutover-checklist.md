# V2 cutover checklist — V1 → V2 parity audit

> **Status: living checklist (2026-06-07).** The hard list of what must be true
> before `src/` (V1) is deleted and `src-v2/ → src/`. Cutover gate
> (`docs/v2-build-order.md` §Cutover): *delete `src/`, rename `src-v2/ → src/`,
> once V2 is at parity and the control plane is robust. No data to migrate, so
> cutover is a code operation.* Companions: `docs/v2-build-order.md`,
> [`architecture/routing-and-ingress.md`](architecture/routing-and-ingress.md) (the
> committed CF-free edge — supersedes gap #3 below),
> [`v2-cp-operational-state.md`](v2-cp-operational-state.md) (gap #1),
> [`architecture/consensus-and-storage.md`](architecture/consensus-and-storage.md),
> [`architecture/consensus-and-storage.md`](architecture/consensus-and-storage.md).

## Orientation

The V2 worker (`src/rewind/main.zig`) **reuses the V1 modules wholesale**
(`rove-js`, `rove-files`, `rove-blob`, `rove-log-server`, `rove-tenant`,
`rove-qjs`), so the entire request/dispatch/effect/KV-durability core carries
over. The engine work (Phases 0–7) has landed. The remaining gaps are
concentrated at the **edge** (front door) and in **operational state**
(plan/limits/domains/certs) — both CP-shaped.

## ✅ At parity (reused V1 modules, wired in `src/rewind/main.zig`)

| Subsystem | Evidence |
|---|---|
| JS dispatch + effect reification (parked continuations, durable wakes, cron, owed retries) | `src/js/dispatcher.zig`, `worker_dispatch.zig` (reused) |
| Per-tenant KV durability (TrackedTxn overlay → raft → commit) | `src/consensus/bridge.zig` + `node.zig` (multi-raft) |
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

**2. Domain → tenant routing is a static env map.** ✅ **RESOLVED (gap #2).**
The host→tenant index is now a replicated axis in the CP `__directory__` group
(`directory.zig` `hosts` projection + `host/{host}` keys, sibling to
`cluster/*` / `placement/*` / `plan/*`): durable across a CP restart, spans the
HA nodes, and accepts runtime custom-domain provisioning via `POST
/_control/host` (move-secret gated, follower-forwards to the leader).
`/_cp/route` resolves host→tenant from the index, then tenant→cluster from
placement; `REWIND_HOSTS` is now seeded INTO the directory (replacing the static
front-door map). Proof: `cp_host_smoke` (unmapped 404, static-seed resolve,
runtime map, re-point across clusters, auth, restart-durability) + `v2-test`
host axis test; `tenant_move_smoke` confirms the front-door routing path.

**3. Edge TLS + ACME for custom domains — own it, no Cloudflare.**
*Per [`architecture/routing-and-ingress.md`](architecture/routing-and-ingress.md).*
   - ✅ **Slice 1 — cert state in the CP** `__directory__` group (`cert/{host}`,
     placement-independent), `GET /_cp/cert(s)` + `POST /_control/cert`,
     `cp_cert_smoke`. Replaces V1's per-cluster `__root__.db`.
   - ✅ **Slice 2 — front door terminates public h2-over-TLS** with SNI cert
     selection, certs synced from the CP (`h2/tls.zig` `putHostCertInMemory` +
     front `CertSync`); front-door → DP stays private h2c. `cp_tls_edge_smoke`.
   - ✅ **Slice 3 — leader-elected ACME issuer** (HTTP-01). `src/cp/acme.zig`
     — a leader-gated thread on `rewind-cp` (evolved from `loop46/acme.zig`,
     reusing `rove-acme`'s RFC 8555 `Client`). Each tick the directory leader
     computes the work-list (`collectUncertedHosts` — mapped hosts lacking
     `cert/{host}`, filtered by `REWIND_PUBLIC_SUFFIX`/`REWIND_SYSTEM_SUFFIX`),
     runs the client, and writes `directory.setCert` → replicates → front
     `CertSync` → SNI. The HTTP-01 challenge is served by `rewind-front`'s `:80`
     listener (gap #6 phase 5) forwarding to the CP's `GET
     /_cp/acme-challenge?token=` endpoint, which reads the issuer's in-memory
     challenge store. Inert unless `REWIND_ACME_DIRECTORY` set. The blocking
     `issue()` runs off the request loop (else it self-deadlocks the validation
     it depends on); `setCert` proposes through the mutex-guarded bridge whose
     pump advances on its own thread. Proven end-to-end against Pebble:
     `scripts/cp_acme_issue_smoke.py` (issue → cert axis → replicate → CertSync
     → the front serves the Pebble-issued cert for `acmecorp.test` by SNI).
   - ⏸ **Slice 4 — DNS-01 wildcard** deferred (provider-specific; wildcard via
     manual `/_control/cert` for now).
   - V1 ACME (`src/acme/` Client + Responder + crypto) is **evolved + re-homed,
     not deleted.**

**4 + 5. Brand-new-tenant provisioning + multi-node formation without a move.**
✅ **RESOLVED.** `POST /_control/provision {tenant, cluster, host?}`
(`cp/main.zig` `handleProvision`, move-secret gated + CP-leader-forward) stands
up a brand-new tenant in one call: empty-attach (`attachToAll(nodes, "", …)` —
the move's attach step minus the bundle) to EVERY node of `cluster` forms the
raft group across the whole cluster (gap #4 — no move needed; the empty-attach
also `ensureInstance`s the blank per-tenant store, gap #5's create), await the
group's election, then `directory.assign` writes the placement (the routable
commit point) + optional `setHost`. Create-only (409 if already placed —
relocate via `/_control/move`); a formation failure evicts the half-formed
groups so a failed provision is a no-op. No `__root__`/`instance/{id}` write is
needed — the CP directory (placement + host axis) + the empty instance suffice,
exactly the state a move-in destination ends with. Proven end-to-end on a real
3-node cluster: `scripts/cp_provision_smoke.py` (provision → group forms across
all 3 nodes → a v2-kv write commits + replicates to every node → the front
routes the host → re-provision 409 / unknown-cluster 400).

## ✅ Front-door tier split (architectural, was blocking the edge gaps) — SHIPPED

Per [`architecture/routing-and-ingress.md`](architecture/routing-and-ingress.md), the
prototype welded the CP raft directory to the request-path proxy, so every
front-door replica was a CP voter (`REWIND_CP_NODE_ID/VOTERS/PEERS`) →
front-door count == voter count (inverted scaling). **Done:**
   - **CP is its own binary + raft cluster** — `src/cp/main.zig` (`rewind-cp`):
     directory raft + move orchestration (`/_control/move[-live]`) + `/_cp/route`
     + `/_cp/leader` + reconciliation + CP-HA forwarding.
   - **Front door is a stateless proxy** — `src/front/main.zig`: resolves
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
| Front-door response headers dropped (incl. content-type) | ✅ **RESOLVED** — `proxyToCluster` relays the backend's response headers (`packRespHeaders`: lowercased for h2, minus hop-by-hop + framing). Proven by `scripts/front_content_type_smoke.py` (a GET through the front carries the backend's `content-type`). |
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
3. ~~**Replicated domain index** (gap #2) — same directory group, sibling axis.~~
   ✅ **SHIPPED** — `host/{host}` axis + `/_control/host` + `cp_host_smoke`.
4. **Edge TLS termination + cert-state-in-CP + single ACME issuer** (gap #3) —
   per `architecture/routing-and-ingress.md`. Slices 1 (CP cert axis) + 2 (front-door
   TLS termination + CP cert pull) + 3 (leader-elected HTTP-01 issuer,
   `src/cp/acme.zig`, Pebble-proven) ✅ SHIPPED; DNS-01 wildcard (slice 4)
   deferred.
5. ~~**Tenant provisioning + multi-node formation** (gaps #4, #5) — the
   create-a-new-tenant path end to end.~~ ✅ **SHIPPED** — `POST
   /_control/provision` (`cp_provision_smoke.py`, 3-node).
6. ~~**Front-door content-type passthrough** (🟡 but mandatory).~~ ✅ **SHIPPED**
   — `proxyToCluster` relays response headers (`front_content_type_smoke.py`).
7. Then the `src-v2 → src` code-move cutover; fix `zig build test`; run hardening
   benches.

The headline: **the engine, the differentiator, AND the front-door/CP split are
done; the remaining work is operational-state (plan/domains/certs/provisioning)
— and almost all of it lands in the CP directory whose replication machinery is
already built.**
