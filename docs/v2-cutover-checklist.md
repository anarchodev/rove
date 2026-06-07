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

**1. Plan / limits enforcement — designed, not built.** V2 worker runs
`rate_limit_caps = .{}` (empty defaults, `main.zig:141`) — no per-tenant plan
resolution, no body-size `413`, no retention clamp. V1 wires `--rate-limit-*` +
`limiter.zig` + plan lookups. This is the entire
[`v2-cp-operational-state.md`](v2-cp-operational-state.md) build (steps 1–3,
"Not built"): `plan/{tenant}` in the CP directory, delivery via attach handshake
+ single-target push, DP enforcement on `TenantSlot`. **Biggest single gap.**

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

## 🟢 Front-door tier split (architectural, blocks the edge gaps above)

Per [`v2-front-door-architecture.md`](v2-front-door-architecture.md): today
`src-v2/front/main.zig` welds the CP raft directory to the request-path proxy, so
every front-door replica is a CP voter (`REWIND_CP_NODE_ID/VOTERS/PEERS`) →
front-door count == voter count (inverted scaling). Before/with the edge work:
   - **Split the CP into its own binary + fixed raft cluster.**
   - **Front door becomes a stateless CP read-replica**, not a voter; terminates
     TLS; scales horizontally behind an L4 (TCP+ALPN passthrough) ingress.
   - Reference deployment: OVH IP LB (TCP+ALPN) + transparent VAC DDoS; nothing
     vendor-specific — the same contract runs on any host.

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

1. **Split the CP out** + front door becomes a stateless read-replica (the
   🟢 item — unblocks the edge gaps).
2. **Plan/limits in CP + DP enforcement** (gap #1) — `v2-cp-operational-state.md`
   steps 1–3.
3. **Replicated domain index** (gap #2) — same directory group, sibling axis.
4. **Edge TLS termination + cert-state-in-CP + single ACME issuer** (gap #3) —
   per `v2-front-door-architecture.md`.
5. **Tenant provisioning + multi-node formation** (gaps #4, #5) — the
   create-a-new-tenant path end to end.
6. **Front-door content-type passthrough** (🟡 but mandatory).
7. Then the `src-v2 → src` code-move cutover; fix `zig build test`; run hardening
   benches.

The headline: **the engine and the differentiator are done; the remaining work
is operational-state (plan/domains/certs/provisioning) + the front-door/CP split
— and almost all of it lands in the CP directory whose replication machinery is
already built.**
