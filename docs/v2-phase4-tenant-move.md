# V2 Phase 4 — quiesce + brief-pause tenant move ⭐ THE MILESTONE

> **Status (2026-06-04).** Phase 4 COMPLETE: the data-plane move
> primitives (bridge/node group attach-at-epoch + destroy-and-reclaim +
> quiesce), the `KvStore` tenant-bundle dump/load, the worker
> `/_system/v2-*` move surface, the front-door `/_control/move`
> orchestration + `moving` directory state, and the exit smoke
> (`tenant_move_smoke.py`) all landed and green. The Phase-4 exit — "move
> a live tenant from cluster 1 to cluster 2 with a brief pause; a request
> to the tenant is served by the new cluster afterward; the data is
> intact" — is **proven**. This is the one capability the whole V2 rewrite
> exists to deliver. Companion: [`v2-build-order.md`](v2-build-order.md)
> §Phase 4 (the spec this elaborates), [`v2-phase3-directory-routing.md`](v2-phase3-directory-routing.md)
> (the routing substrate this flips), PLAN §13 (live process map).
> Next: Phase 5 (multi-node HA), the first hardening step past the proof.

## Why Phase 4 is the milestone

V1's raft is cluster-wide: a tenant's consensus position is cluster-scoped
and does not travel with its state. V2 gives each tenant its own raft
group (`tenant_id == group_id`) over a shared WAL, so moving a tenant is
"detach the committed state, reattach it elsewhere." Phase 4 is that move,
end to end, over the finished substrate. Everything before it (Phases 0–3)
was building toward this; everything after it (Phases 5–7) is hardening.

The first move is between two **single-node** clusters. That exercises the
whole mobility path — quiesce → bundle → ship → attach → reroute → evict —
without needing multi-node quorum. Mobility does not need quorum; HA does
(Phase 5).

## What actually moves

Two things live in two different places, and the move handles each
distinctly:

| Thing | Where it lives | How it moves |
|---|---|---|
| **Tenant KV state** | the worker's single `cluster.kv` manifest, one `store_id` per tenant (via `attachSibling`) | dumped as a **migration bundle** (`kvexp.dumpTenantBundle`) on the source, shipped over internal HTTP, loaded into the destination's `cluster.kv` (`kvexp.loadTenantBundle`). Both clusters hash the tenant id to the same `store_id`, so the store reconstructs at the matching id. |
| **Consensus position** | the bridge's per-tenant raft group over the shared WAL | NOT shipped. The destination stands up a **fresh group at the migration epoch** (`createGroupEpoch`, birth 0 + 1); the source group is **destroyed + its WAL reclaimed** (`destroyGroup` + `noteGroupDestroyed`). The materialized KV state is the ground truth; the new group starts a fresh index sequence over it. |
| **Executable blobs** (source, bytecode, statics) | the shared content-addressed store (S3) | not moved at all — both clusters read the same `BlobStore`. The bundle ships KV state only. This is why Phase 4 assumes a shared blob backend. |

## The pieces

| Piece | Where | What |
|---|---|---|
| **Bridge/Node move primitives** | `src-v2/kv/node.zig`, `src-v2/kv/bridge.zig` | `createGroupAtEpoch` / `destroyGroupAndReclaim` on the node; a pump-thread control queue (`createGroupEpoch` / `destroyGroup`) + `quiesce` / `unquiesce` on the bridge. The `Manager` is not thread-safe, so group lifecycle runs on the pump thread, enqueued + waited from the worker thread. |
| **KvStore bundle dump/load** | `src/kv/kvstore.zig` | `dumpTenantBundle(allocator) []u8` / `loadTenantBundle(bytes)` — the minimal shippable form of one tenant store, over `kvexp.dumpTenantBundle` / `loadTenantBundle`. |
| **Worker move surface** | `src/js/v2_move.zig` (wired into `tryHandleSystem`) | `/_system/v2-kv` (seed/read through the real propose path), `v2-bundle` (quiesce + dump), `v2-attach` (load + group-at-epoch), `v2-evict` (destroy group + drop instance), `v2-resume` (abort). Gated by a shared `move_secret` (`X-Rewind-Move-Secret`), no CORS, no root bearer. |
| **Front-door orchestration** | `src-v2/front/main.zig`, `src-v2/cp/directory.zig` | `POST /_control/move {tenant,dest}` drives the whole move; `Directory` gains a `moving` placement state (router 503s a moving tenant) + `beginMove` / `abortMove` / `clusterById`. |
| **Exit smoke** | `scripts/tenant_move_smoke.py` | two `rewind` clusters + front door; write → move → read-back; data intact + new cluster serves + source evicted + routing flipped. **Green.** |

## The move sequence (the orchestration)

`POST /_control/move {tenant, dest}` on the front door — the one component
that sees all clusters and owns the directory — runs:

1. **Hold** — `directory.beginMove(tenant)`: the router now 503s the
   tenant's requests (the brief pause). Placement still points at the
   source, so an abort is a clean revert.
2. **Quiesce + dump (source)** — `POST src/_system/v2-bundle`: the worker
   `quiesce`s the tenant's group (refuse new proposes), waits for
   in-flight to drain to `applied == committed`, then dumps the tenant
   bundle. Returns the bytes.
3. **Attach (destination)** — `POST dest/_system/v2-attach` with the bundle
   bytes: create the instance, `loadTenantBundle` into its `cluster.kv`,
   then `createGroupEpoch(gid, 1)` — a fresh raft group at the migration
   epoch over the loaded state.
4. **Flip** — `directory.move(tenant, dest)`: **the atomic commit point.**
   The tenant is now `active` on the destination; traffic resumes there.
5. **Evict (source)** — `POST src/_system/v2-evict`: `destroyGroup` +
   `noteGroupDestroyed` (reclaim WAL) + drop the instance. Best-effort —
   the move already committed.

Any failure before step 4 reverts the directory (`abortMove`) and resumes
the source (`v2-resume` lifts the quiesce), so a failed move is a no-op the
tenant survives. After step 4 the move is durable; eviction failure only
leaves a stale source group that never serves traffic again.

## Deliberate Phase-4 scope (carried forward, not over-built)

- **Brief pause, not zero-downtime.** The tenant is held (quiesced +
  routed-503) for the bundle round-trip. Zero-downtime — keep serving on
  the source while the destination catches up, atomic flip under live load
  — is the Phase-7 `relinquish`/`acquire` handshake. The epoch fence the
  destination attaches at is moot single-node here; it earns its keep in
  Phase 7. Phase 4 stamps `epoch = 1` so the seam is real, not retrofitted.
- **Synchronous orchestration.** The front door drives the move inline in
  its single-threaded poll loop, so all traffic pauses during a move (not
  just the moving tenant's). Fine for the sequential exit smoke;
  per-tenant concurrency rides on the front door's concurrency work
  (Phase-3 deferral) and the `moving` interlock that is already in place.
- **Internal move surface for seed/verify.** `/_system/v2-kv` writes
  through the real propose→commit path and reads the kvexp store — an
  internal operational surface (sibling to `admin-kv`), gated by the move
  secret. It is how the smoke seeds + verifies; it is not a customer API.
- **Bounded wait, not the `RaftWait` park.** The move endpoints block the
  worker briefly on `bridge.committedSeq` rather than parking entities.
  They are low-rate internal ops; the data is already durable in kvexp
  after the immediate commit, so the wait only confirms replication.

## The exit (proven)

`scripts/tenant_move_smoke.py` (needs S3 env: `set -a; . ./.env; set +a`):

```
boot: two rewind clusters + front door (move control enabled)
leg A : seed movetenant on cluster-1 + read it back          → value
leg A2: front door routes movetenant → cluster-1 (pre-move)  → value
leg B : POST /_control/move {tenant, dest:cluster-2}         → 200
leg C : read-back on cluster-2 (data intact, c2 serves)      → SAME value
leg D : read on cluster-1 (source evicted)                   → 404
leg E : front door routes movetenant → cluster-2 (post-move) → value
PASS — moved a live tenant across clusters; data intact, new cluster serves it. ⭐
```

That is the goal the whole engine half was built toward.
