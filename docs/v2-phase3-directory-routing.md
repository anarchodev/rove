# V2 Phase 3 — directory + routing across two (single-node) clusters

> **Status (2026-06-04).** Phase 3 design + the control-plane directory
> primitive (3a) landed; the front door (3b) + two-cluster smoke (3c) are
> the remaining pieces. Companion: [`v2-build-order.md`](v2-build-order.md)
> §Phase 3 (the one-paragraph spec this elaborates), PLAN §13 (live
> process map).

## Why Phase 3 exists

Phases 1–2 proved a single V2 cluster can run the product: per-tenant raft
groups commit writes through the bridge and the reused rove-js worker
serves HTTP/2 (`rewind` binary, `rewind_smoke.py`). But the whole thesis
of V2 is **tenant mobility** — moving a tenant between clusters — and you
cannot move a tenant between clusters until there is *more than one
cluster and something that routes a tenant's traffic to the right one.*

Phase 3 stands up exactly that: two single-node clusters and a front door
that, per request, resolves the tenant and forwards to the cluster that
currently owns it. Phase 4 then makes the owning-cluster *change* (the
move). Phase 3 is the routing substrate the move flips.

## The three pieces

| Piece | Where | What |
|---|---|---|
| **3a Directory** | `src-v2/cp/directory.zig` | tenant→cluster map; the routing source of truth + the `move` seam Phase 4 flips. **Done.** |
| **3b Front door** | `src-v2/front/` | HTTP/2 terminator: resolve Host→tenant → `directory.clusterFor` → reverse-proxy to that cluster. |
| **3c Smoke** | `scripts/two_cluster_smoke.py` | two `rewind` clusters + front door; tenant A→cluster 1, tenant B→cluster 2, routed correctly. The Phase-3 exit. |

## 3a — the directory (control plane)

The routing source of truth: `clusterFor(tenant) -> ClusterRef`. Two
write seams: `assign` (initial placement) and `move` (re-placement — the
atomic flip a tenant move commits at). Seeded from static config
(`seedClusters` / `seedPlacements`) — the build-order's "dead simple
static config for the first move." In-process, mutex-guarded, **not
replicated**: a single front door owns the one authoritative copy.

Decisions baked in:

- **Static, in-process, single-owner for now.** The build-order
  explicitly permits "even static config." Replication (multiple front
  doors / CP-HA agreeing on placement, e.g. the directory in its own raft
  group or a replicated KV map) is deferred hardening behind this stable
  interface — not on the mobility-proof critical path.
- **`Placement` is a struct, not a bare cluster id.** Phase 3 ships one
  state (`active`). Phase 4 adds the move interlock as a new `State`
  variant (e.g. `moving` → front door holds the tenant's requests while
  its bundle is in flight) without changing `clusterFor`'s callers.
- **`move` ≠ `assign`.** `move` rejects an unknown tenant: a move
  presupposes an existing placement, so a missing one is a caller bug to
  surface, not silently create. `assign` is the create/idempotent path.
- **Separate from the bridge's `by_id`.** The bridge maps tenant→raft
  *group id* (data plane, within a cluster); the directory maps
  tenant→*cluster* (control plane, across clusters). Different axes.

## 3b — the front door (plan)

A small HTTP/2 server that, per request:

1. Reads `:authority` / `Host` from the request headers.
2. Resolves Host→tenant store id. **Open question (below):** the
   authoritative resolver is per-tenant data living *on* a cluster, which
   the front door does not own. For Phase 3 the front door resolves via a
   static Host→tenant map seeded alongside the placement config (the same
   "static config for the first move" tier), so the front door needs no
   cluster round-trip to route. Production replaces this with a replicated
   domain→tenant index in the control plane (same axis as the replicated
   directory — both become CP-replicated together).
3. `directory.clusterFor(tenant)` → `ClusterRef` (or 404/421 if unplaced).
4. Reverse-proxies the request to `cluster.base_url`, streaming the
   response back.

Transport: forward via the existing libcurl client primitives
(`src/blob/curl*.zig`) the worker already uses for internal HTTP, rather
than writing a new HTTP/2 client. The backend `rewind` speaks HTTP/2
prior-knowledge; the front door terminates the inbound h2 and opens a
backend connection per proxied request (connection pooling is a later
optimization). Body + header passthrough both ways; hop-by-hop headers
stripped.

Why a separate front-door process and not routing inside `rewind`: a
cluster's worker only holds the tenants placed on it; a request for a
tenant on *another* cluster has to leave the process. The front door is
the one component that sees all clusters. It is cluster-agnostic (reads
only the directory), so it ports forward to multi-node (Phase 5) unchanged
— it forwards to a cluster's address, which becomes a per-cluster leader
address once clusters are multi-node.

## 3c — the exit smoke

`two_cluster_smoke.py`: boot two `rewind` instances on distinct data dirs
+ ports (cluster 1, cluster 2) and one front door seeded with
`cluster-1=…;cluster-2=…` placement `A=cluster-1;B=cluster-2`. Provision
tenant A on cluster 1 and tenant B on cluster 2 (admin-kv write through
each backend directly). Then drive both tenants *through the front door*
and assert each write lands on the correct backend (read it back through
the front door; cross-check it is absent on the other cluster). A correct
route for both tenants is the Phase-3 exit: **"tenant A served on cluster
1, tenant B on cluster 2, requests routed correctly."**

## Open questions / deferred

- **Host→tenant resolution at the front door.** Phase 3 uses a static
  map; the real index (domain→tenant) is replicated CP state. Resolved
  together with directory replication, post-mobility-proof.
- **Directory replication + CP HA.** Deferred behind the 3a interface.
- **Connection pooling / keep-alive to backends.** Per-request connect is
  fine for the smoke; pool later if the front door is on a hot path.
- **The `moving` interlock.** Phase 4 — the directory `State` variant +
  front-door request-hold. Not in Phase 3 (a tenant is always `active`).
