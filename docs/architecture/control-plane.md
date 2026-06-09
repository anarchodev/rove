# Control plane

> 🟢 **As-built reference.** The authoritative tenant directory, how it
> replicates, how a tenant moves between clusters, and where per-tenant
> operational state (plan/limits) lives. Owns `src/cp/` (`rewind-cp`) and the
> move surfaces in `src/front/main.zig` + `src/js/v2_move.zig`. For the data-
> plane mechanics a move drives (bundle/attach/epoch) see
> [`consensus-and-storage.md`](consensus-and-storage.md); for the routing that
> reads the directory see [`routing-and-ingress.md`](routing-and-ingress.md).
> Why: [decisions.md §10.1](../decisions.md) (CP/DP split), §10.6 (move), §10.5
> (faulted-not-lost).

## The shape in one paragraph

The control plane is a small dedicated raft cluster (`rewind-cp`, 3–5 voters)
holding one replicated `__directory__` group — the authoritative `Host →
cluster` placement plus per-tenant plan and cert state. The front door reads it
as a cached replica; it is **not** on the request hot path. A tenant move is a
synchronous orchestration whose **commit point is a single directory write**
(`placement/{tenant}` flipped to the destination): hold → quiesce+bundle the
source → attach the destination at a fresh epoch → flip → evict the source.

## Code map

| File | Role |
|---|---|
| `src/cp/directory.zig` | The `Directory`: `ClusterRef {id, nodes}`, `Placement {state: active\|moving, cluster}`, `Resolution {cluster, moving}`. Methods `assign` / `move` / `beginMove` / `abortMove` / `clusterFor` / `resolve`. Backed by the replicated `__directory__` store; an apply-observer rebuilds the in-memory projection on every node. |
| `src/cp/main.zig` | `rewind-cp`: hosts the directory's bridge; `handleMove` (the 5-step orchestration), `handleMoveLive` (Phase-7 variant); the `/_control/*` command surface and the `/_cp/route` · `/_cp/leader` · `/_cp/cert` read surface; `reconcileStuckMoves`. |
| `src/cp/acme.zig` | Leader-gated ACME issuance + `cert/{host}` replication (see `auth-and-domains.md`). |
| `src/front/main.zig` | The move orchestrator's caller + leader-aware proxy (routing-and-ingress). |
| `src/js/v2_move.zig` | The worker-side move surface (`REWIND_MOVE_SECRET`-gated): `v2-bundle` / `v2-attach` / `v2-evict` / `v2-resume` / `v2-kv`. |

## The directory & routing authority

- **One replicated `__directory__` group** on every CP node (gid =
  `hash("__directory__")`), pinned active so it never hibernates (a follower must
  re-elect on leader death).
- **Keys** (kvexp): `cluster/{id}` → node origins; `placement/{tenant}` →
  `{state}:{cluster}`; `plan/{tenant}` → opaque tier+overrides; `host/{host}` →
  tenant; `cert/{host}` → packed cert+key.
- **Hot-path reads are zero-alloc**: the in-memory projection (`clusters`,
  `placements`, `plans`, `hosts`, `certs`) is rebuilt by the apply-observer on
  every committed write, on leader and followers alike. `clusterFor(tenant)` and
  `resolve(tenant)` are map lookups; `ClusterRef.nodes` slices are pointer-stable
  past the directory lock.

## CP directory replication

- **Apply-observer projection**: `Node.apply_observer` fires on every node for
  every committed directory PUT, so a follower's projection stays current with no
  local proposer (the one place rove decodes a writeset twice — worth it only for
  the tiny directory writes).
- **Leader-gated seeding**: only the directory leader seeds static config at boot;
  followers fill by replication.
- **Write forwarding**: a `/_control/*` request that lands on a follower is
  forwarded to the leader (discovered via `/_cp/leader`), so an operator can
  target any CP node.
- **Crash reconcile**: `reconcileStuckMoves` (CP leader, periodic) aborts a
  tenant stuck `moving` and reverts it to active on the source.
- **Status**: single-node and multi-node HA (3–5 voters) shipped, proven by
  `scripts/cp_ha_smoke.py` (seed replicates, a follower-forwarded move commits,
  kill the leader → a survivor promotes and a fresh move commits on quorum).

## Tenant move orchestration

The atomic commit is `directory.move(tenant, dest)` — one replicated write
flipping `placement/{tenant}`. `rewind-cp`'s `handleMove` sequences it:

1. **Hold** — `beginMove(tenant)`: the router 503s the tenant's requests;
   placement is still the source (abort is a clean revert). `active → moving`.
2. **Quiesce + bundle (source)** — `POST src/_system/v2-bundle` (leader-gated):
   the worker refuses new proposes, drains in-flight to `applied == committed`,
   and dumps the tenant's committed kvexp state to a self-describing bundle.
3. **Attach (every destination node)** — `POST dest/_system/v2-attach` with the
   bundle (and the plan blob): each node loads it and `createGroupEpoch`s its
   incarnation at the migration epoch, so the group forms across the cluster. All
   must 204; any failure evicts the partial set and resumes the source.
4. **Flip (CP directory)** — `directory.move`: **the commit point**. Traffic
   resumes on the destination.
5. **Evict (source)** — `POST src/_system/v2-evict` (best-effort): destroy the
   group, reclaim its WAL, drop the instance. The move is already durable;
   eviction is cleanup.

A failure **before** step 4 → `abortMove` + `v2-resume` (a no-op move). **After**
step 4 it is durable. The destination is born at the migration epoch, which
fences stale messages to the old location. Blobs never move (shared backend).

## Operational state (plan / limits)

- **Lives in the CP directory** (`plan/{tenant}`), a sibling axis to placement —
  **not** in a per-cluster store and **not** known to the engine. This keeps
  plan/limits orthogonal to consensus.
- **Authority**: the admin app (an ordinary DP tenant holding a capability token)
  writes plans via the CP's capability-gated `/_control/plan`; accounts/orgs/
  billing are product-layer, above the CP (see
  [`platform-accounts-model.md`](../platform-accounts-model.md)).
- **Delivery**: a plan rides the `v2-attach` handshake at cold-start/move; a live
  tier change is a single-target push to the tenant's current cluster (a plan-
  generation bump). Enforcement is DP-local; the front door enforces body-size at
  the edge from its cached read.

## Zero-downtime move (Phase 7)

The Phase-4 brief-pause move (above) is shipped and proven
(`scripts/tenant_move_smoke.py`). Phase 7 removes the pause:

- **Serve-or-forward** — a DP node that doesn't own a tenant asks the CP and
  forwards to the owner (the owner never re-forwards; loop-safe).
- **Dual-write forwarding** — the source stays online while the destination
  attaches; the source synchronously forwards every committed write to the
  destination, which catches up in real time.
- **Cutover** — the destination loads the snapshot insert-if-absent (never
  clobbering a forwarded write); because forwarding is synchronous it has every
  acked write, so the flip loses nothing. `handleMoveLive` orchestrates this.

The mechanism is in place; **live re-fencing under continuous load with zero
failed requests, and per-tenant move concurrency, are the remaining work** (a
write in flight at the instant of a leader change is still faulted + retried, not
lost — decisions.md §10.5).

## Known limitations (as-built)

- **Move orchestration is synchronous** on the CP (one move at a time); parallel
  per-tenant moves are deferred.
- **DP-side directory cache** (Slice 3) is optional and not built — the per-miss
  CP query is sufficient today.
- **ACME issuer coordination** (leader-elected issuance + renewal) is the tracked
  follow-up in `auth-and-domains.md`.
