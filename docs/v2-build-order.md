# V2 build order — path to moving tenants between clusters

> **Status / framing (2026-05-29).** This is the implementation order for
> V2, sequenced as the shortest path to the one capability that motivates
> the rewrite: **moving a tenant from one cluster to another.** It assumes
> the strategic frame settled in conversation on 2026-05-29 (see
> "Decision" below) and builds on the substrate already prototyped and
> partially landed. Companion docs: [`v2-vendoring-spike.md`](v2-vendoring-spike.md)
> (how raft-rs lives under `vendor/` + the FFI shape) and
> [`v2-multiraft-scaling-learnings.md`](v2-multiraft-scaling-learnings.md)
> (measured findings from the rewind2 / raft-rs-zig prototype). PLAN §13
> is the live process/surface map.

## Why this rewrite exists

The goal is **tenant mobility**: pick up a tenant and move it to a
different cluster. This is not a feature that bolts onto V1 — it is the
entire thesis of the per-tenant-raft + control-plane/data-plane split.

V1's raft is **cluster-wide**: one log per cluster, every tenant's writes
interleaved into it, so the consensus index is *cluster-scoped*. A
tenant's state (`kvexp` `durableRaftIdx`) and its consensus position
therefore do not travel together. Moving a tenant off a shared log needs
a bespoke dual-write/fence protocol (forward the tenant's writes to the
destination, catch up, fence on the source, flip) that is error-prone at
the fence, does not generalize, and fights the architecture.

V2 gives each tenant its **own raft group** (`tenant_id == group_id`) with
its own index sequence. Moving a tenant becomes: detach the group's
committed state and reattach it on the destination — state and consensus
position move as one unit. That is the clean primitive, and it is what the
whole engine half has been built toward.

## Decision (2026-05-29)

Settled in conversation, refining the locked 2026-05-16 direction:

- **Pre-release, no production data.** There is nothing to migrate at
  cutover and no downtime cost. This collapses the migration problem the
  2026-05-16 plan was designed around.
- **Therefore: freeze V1, build V2 as its replacement on a branch, merge
  and delete V1 when V2 can serve + move tenants.** The earlier
  "parallel `src-v2/` directory + in-place dual-mode" plan was answering a
  *live-migration* question (V1 launches first, V2 comes later). With no
  data and no release, dual-mode — two raft engines coexisting in one
  binary — is never needed, which deletes the single hardest piece of the
  old plan. A branch is clean because frozen V1 means main stops moving,
  so there is no rebase tax.
- **"Clean slate" means clean-slate the spine, reuse the limbs.** The
  cluster-agnostic upper stack (`h2/`, `blob/`, `log_server/`, the
  arenajs/qjs JS dispatcher, `tape/`, `tenant/`, files-server) ports as
  imports. The rebuild is concentrated in the consensus/storage spine
  (`src/kv/`, ~8.5k LOC of willemt) plus a control plane and the
  propose/apply seam in the worker dispatcher.
- **Velocity bet, not a technical risk.** Freezing V1 pauses product work
  on the demoable system while V2 reaches parity. The branch keeps V1
  demoable on main until cutover.

## What is already built (the substrate)

Engine-side primitives the data plane and move orchestration call into —
already landed this session, outside the rove repo:

| Repo | Where | What |
|---|---|---|
| `raft-rs-zig` | branch `v2-cp-substrate` | per-group **epoch fence** (cross-incarnation fencing for moves), group **lifecycle** (`createGroupEpoch` / `destroyGroup` / `clearTombstone`), **WAL crash recovery**, **compaction + segment GC** (bounded WAL), the **Manager** pump surface (`poll_ready` / `processReady` / `release` / `tickGroups` / `step` / `stepBatch` / `takeMessages`), `noteCompaction` / `noteGroupDestroyed` |
| `kvexp` | `main` (`9319d1b`) | per-tenant **migration bundle** — `dumpTenantBundle` / `peekTenantBundle` / `loadTenantBundle` (one store's key-space as a shippable blob) |

The **reference implementation** of the data plane is `~/src/rewind2`
(`multi_dispatcher.zig` ≈ 3.2k LOC: the multi-group pump + per-recipient
transport coalescing + apply pipeline; plus `apply_queue.zig`,
`dispatcher.zig`, `migration.zig`, `snapshot.zig`). It is a working
prototype over the exact three dependencies (kvexp + raft-rs-zig). Caveat:
rewind2 has no HTTP/2, JS, or blob layer — it is the raft + apply half
only — and its `aria_*` (optimistic-concurrency drain) experiment is dead;
do not port it.

## The de-risking move: single-node clusters first

The **first** cross-cluster move can be between two *single-node*
"clusters." That exercises the entire mobility path — bundle → ship →
attach → reroute — without needing multi-node quorum. Multi-node consensus
(HA + durability) then becomes hardening *after* the capability is proven,
not a prerequisite for it. Mobility does not need quorum; HA does.

---

## Build order

Legend: **Reuse** = imports unchanged · **New** = write on the v2 branch ·
**Done** = primitive already built (see table above).

### Path to the milestone

#### Phase 0 — Branch + build integration

- **New:** branch `v2` off main (V1 now frozen). Vendor `raft-rs-zig`
  under `vendor/` and `cargo vendor` its Rust dependency tree (rove's
  offline-build mandate — raft-rs-zig currently fetches from crates.io).
  `build.zig`: a cargo step + a `raft_rs_zig` module/artifact, gated
  behind v2-only build steps (`zig build loop46-v2`, `v2-test`) so the
  default `zig build` and V1 contributors are untouched.
- **Reuse:** the existing `rust-ffi-smoke` example is the literal wiring
  template (it already proves `cargo build` → `linkSystemLibrary` end to
  end on main, with the exact system-lib list). `vendor/kvexp` already in
  place.
- **Exit:** `zig build v2-test` green; a trivial test creates a Manager +
  group from inside rove.
- **~1–2 days.** The cargo-vendor step is the only fiddly part.

#### Phase 1 — Data-plane core: the per-tenant pump (single node)

This is the heart of the rewrite.

- **New:** `src-v2/kv/`: a `Node` owning a `SharedWal` + a `Manager`, and
  a pump that ticks the active set → drains `poll_ready` → runs
  `processReady` (decode a committed entry → apply it to the tenant's
  kvexp store) → drains `takeMessages` → `release`. Per-tenant
  `GroupedFileStorage` created on demand.
- **Reuse:** kvexp (state engine), `writeset.zig` + the `apply.zig`
  envelope format (the apply payload is unchanged), the TrackedTxn
  speculative-overlay commit/rollback. rewind2's `multi_dispatcher.zig` is
  the structural reference.
- **Done:** the Manager pump surface, `SharedWal` / `GroupedFileStorage`,
  `createGroupEpoch`.
- **Exit:** unit test — propose a writeset to a tenant group on one node,
  it commits (single voter), applies to that tenant's kvexp, a read sees
  it. No HTTP yet.
- **~1–2 weeks.**

#### Phase 2 — Vertical slice: one tenant served over HTTP on V2

- **New:** swap the V1 cluster-raft propose/apply at the worker-dispatch
  seam for "propose to *this tenant's* group → await commit → apply." A
  v2 worker binary.
- **Reuse:** `h2/`, the arenajs/qjs JS dispatcher, the TEA Cmd-list
  handler model, `blob/`, `tenant/`, files-server compile/deploy
  (`_deploy/current` just rides the same per-tenant propose path).
- **Done:** the Phase-1 data plane.
- **Exit:** deploy a handler + serve a request end to end on V2, single
  node. Adapt one tier-1 smoke. This is "V2 can run the product."
- **~1–2 weeks.**

#### Phase 3 — Directory + routing across two (single-node) clusters

- **New:** a minimal control plane — the tenant→cluster directory — and
  front-door routing that sends a tenant's requests to its current
  cluster. Two single-node clusters. The directory can start dead simple
  (a tiny replicated KV map, or even static config for the first move).
- **Reuse:** the worker→standalone shared-secret auth; existing inter-node
  plumbing.
- **Exit:** tenant A served on cluster 1, tenant B on cluster 2, requests
  routed correctly.
- **~1–2 weeks.**

#### Phase 4 — Quiesce + brief-pause move ⭐ MILESTONE

> **DONE + green (2026-06-04).** Move orchestration shipped: bridge/node
> group attach-at-epoch + destroy-and-reclaim + quiesce
> (`src-v2/kv/{node,bridge}.zig`), `KvStore` tenant-bundle dump/load
> (`src/kv/kvstore.zig`), the worker `/_system/v2-*` move surface
> (`src/js/v2_move.zig`), the front-door `POST /_control/move`
> orchestration + `moving` directory state (`src-v2/front/main.zig`,
> `src-v2/cp/directory.zig`). Exit smoke `scripts/tenant_move_smoke.py` is
> green: write → move → read-back, data intact, new cluster serves,
> source evicted, routing flipped. Details: [`v2-phase4-tenant-move.md`](v2-phase4-tenant-move.md).
> **The milestone is proven.** Phase 5 (multi-node HA) is now DONE too.

- **New:** the move orchestration. Quiesce the tenant (directory marks it
  "moving" → router holds its writes; drain in-flight to
  `applied == committed`) → `dumpTenantBundle` on source → ship the bytes
  (internal HTTP or blob) → `loadTenantBundle` on destination →
  `createGroupEpoch(tenant, epoch+1)` on destination → flip the directory
  → resume → `destroyGroup` + `noteGroupDestroyed` on source (reclaim its
  WAL segments).
- **Reuse:** internal transport for shipping the bundle; the Phase-3
  directory.
- **Done:** almost the whole phase — `dumpTenantBundle` /
  `loadTenantBundle`, `createGroupEpoch` / `destroyGroup` /
  `clearTombstone` + epoch, `noteGroupDestroyed`. Phase 4 is mostly
  orchestration glue over finished primitives.
- **Exit:** **move a live tenant from cluster 1 to cluster 2 with a brief
  pause; a request to the tenant is served by the new cluster afterward;
  the data is intact.** Smoke: write → move → read-back. *The goal.*
- **~1 week.**
- **Dependency:** cross-cluster moves assume a **shared blob backend**
  (`S3BlobStore`) so the destination reads the tenant's executable blobs
  without copying them. The bundle ships KV state only; the blobs in
  `file-blobs/` are served from the shared, content-addressed store. If a
  cluster were on local-only fs, blobs would have to ship alongside the
  bundle.

**To here ≈ 6–9 weeks.** Everything below makes it production-real.

### Hardening after the milestone

#### Phase 5 — Multi-node clusters (HA + durability) — launch-required

> **DONE (2026-06-04).** 5a (coalesced transport) + 5b (multi-node Node
> election/replication/failover) `945962a` + 5c (multi-node bridge:
> deterministic gid, role-aware apply, FIFO seq binding + fault) `fb79732`
> + 5d (move fan-out to all dest nodes) + 5e (rewind multi-node config,
> leader-aware front-door routing, Full-HA follower-apply store
> unification, readset-frame apply fix, the 3-node smoke) — green under
> `v2-test` (40/40). `scripts/three_node_smoke.py` moves a tenant onto a
> 3-node destination, serves it leader-aware, kills the LEADER, and a
> promoted follower serves the replicated data; a post-failover write
> commits on the surviving quorum. Single-node milestone smokes still pass.
> Details: [`v2-phase5-multinode.md`](v2-phase5-multinode.md).

- **New:** cross-node transport; form per-tenant groups across 3 nodes;
  per-group election/failover; moves create the destination group on all
  destination nodes.
- **Reuse:** rove's `raft_net.zig` io_uring transport as the wire layer,
  adapted to per-recipient **coalesced** envelopes carrying many groups'
  messages plus epoch stamps (learnings §3.3); shared blob backend.
- **Done:** `step_fenced` / `stepBatch` (epoch enforced on the coalesced
  fast path), `takeMessages`.
- **Exit (met):** 3-node cluster; a tenant survives a node failure
  (leader kill → promoted follower serves the replicated data via the
  unified follower-apply store); a move targets a 3-node destination.
  `scripts/three_node_smoke.py`.
- **~2–3 weeks.**

#### Phase 6 — Scale: hibernation / active-set (K = thousands of tenants)

> **DONE (2026-06-04).** Active-set hibernation in `node.zig` +
> `transport.zig`: `bumpActive` on propose / formation / non-heartbeat
> step, tick only the active set, `sweepHibernated` per cycle, no pre-seed;
> heartbeats deliberately do NOT wake (eraftpb wire-byte detection). Green
> under `v2-test` (46/46) — single-node hibernate→wake, K-group idle drain,
> and a 3-node group that hibernates with NO spurious leader change then
> wakes + replicates on a propose. The K-tenant exit bench
> (`v2-hibernation-bench`) shows pump cycle time at K=10k drop from
> 1000 µs/cycle (tick-all) to ~0 when the tenants are idle (~31,000×). A
> cluster-scale live-traffic macrobench is a separate follow-up. Details:
> [`v2-phase6-hibernation.md`](v2-phase6-hibernation.md).

- **New:** the active-set machinery above the FFI — bump on propose and on
  non-heartbeat step only, tick only the active set, do not pre-seed at
  init (learnings §3.1 + §3.4).
- **Reuse:** the Phase-1 pump.
- **Exit (met):** thousands of mostly-idle tenants do not burn the pump
  (cycle time stays low); a K-tenant bench. `v2-hibernation-bench` shows the
  pump cycle at K=10k idle tenants drops to ~0 (vs 1 ms/cycle tick-all). A
  cluster-scale live-traffic macrobench is a separate follow-up.
- **~1–2 weeks.**

#### Phase 7 — Zero-downtime move (the upgrade)

> **IN PROGRESS (2026-06-05).** Architecture locked (see the
> `project_v2_zero_downtime_move` memory): public routing = Cloudflare as a
> best-effort hint (NOT the cutover authority); cutover authority = our
> replicated CP directory; every DP cluster serve-or-forwards (stale proxy
> = an extra hop, never a failure); data overlap = dual-write forwarding +
> the epoch fence. CP = a dedicated cluster, a separate binary (`rewind-front`
> evolved), storage on our own `bridge`/`Node` raft. **Slice (b) — dual-write
> forwarding — DONE:** `v2-apply` (dest) + `v2-forward-begin`/`-end` (source
> `_move/forward` marker) + `handleKv` dual-write; `scripts/zero_downtime_forward_smoke.py`
> proves the source keeps serving while every committed write reaches the
> dest. Remaining: (a) serve-or-forward + the replicated CP directory, (c)
> the relinquish/acquire epoch-fenced cutover. **Blocker found:** a
> pre-existing `v2-bundle` empty-snapshot race (a write dumped instantly
> after commit can be missing) must be fixed before (c).

- **New:** the `relinquish` / `acquire` handshake — keep serving on the
  source while the destination catches up, with an epoch-fenced overlap
  window so stale source traffic to the destination rejects; drain
  in-flight; atomic routing flip with no dropped request.
- **Reuse / Done:** refines the Phase-4 path; the epoch fence finally
  earns its keep under live concurrent traffic; `setEpoch` for live
  re-fencing.
- **Exit:** move a tenant under continuous load with zero failed requests.
- **~2–4 weeks.**

#### Cutover

Delete `src/` (V1), rename `src-v2/ → src/`, once V2 is at parity and the
control plane is robust. No data to migrate, so cutover is a code
operation, not a runbook.

---

## Notes on shape

- **Critical path is Phases 1–2** (the data plane + the request-seam
  swap). Phase 4 is glue over finished primitives; Phases 5–7 are
  hardening.
- **Single-node-cluster-first** is what puts the milestone weeks away: it
  defers all of multi-node consensus (Phase 5) past the mobility proof.
- **Value-first ordering:** prove the one capability that motivates the
  whole effort (Phase 4) before investing in HA and scale, so a shift in
  priorities still leaves the differentiator working.
- **Freeze discipline:** from Phase 0, main stays on demoable V1; all V2
  work on the branch; no V1 feature work until cutover. Per the
  experimental → freeze → TDD-on-modify workflow, each phase's exit
  smoke/test materializes when that phase freezes.
- **Not on the milestone path (deliberately):** dual-mode (gone entirely),
  readset replication into the V2 entries (a V1 feature V2 will want
  eventually, but not for the first slices), and the full
  `relinquish`/`acquire` zero-downtime handshake (Phase 7). The brief-
  pause move (Phase 4) delivers the capability; zero-downtime is an
  upgrade to the same path.
