# Raft-native alignment — getting into raft-rs's intended-use space

## Thesis

rove repeatedly routes **membership** and **catch-up** *around* raft's replicated
state (the log + ConfState + snapshot), substituting out-of-band orchestration or
static config. Each such bypass has cost us a class of bugs and a pile of bespoke
machinery. This plan re-integrates: let membership and catch-up flow through
raft's own state, the way etcd/TiKV (whose `raft-rs` we pin) intend.

The deviations are facets of one root pattern, and they collapse onto **two**
native primitives — **conf-change** and **snapshot** — when re-aligned.

## Operating principle

raft-rs/TiKV/etcd represent years of hard-won correctness work (membership
safety, snapshot flow control, joint consensus, async storage, hibernation).
**Default to their mechanisms; treat every divergence as a defect until proven
otherwise.** A divergence is only acceptable with a *concrete, written
justification* — and even then we prefer to solve the problem *inside* the native
model (as etcd did for large snapshots via a side channel) rather than replacing
it. Every item below carries a verdict: **align** (adopt the native path),
**justified divergence** (keep, with the reason), or **open** (scrutinize before
deciding).

## Topology: rove is disjoint clusters, not a homogeneous pool

This is the lens that decides *which* of raft-rs/TiKV's mechanisms rove actually
needs — and it explains several divergences before we get to them.

**TiKV** scales one **homogeneous pool of stores** (dozens–hundreds). Its unit is
the **Region** (a key-range shard) keeping ~3 replicas on **3 of the N stores**,
and the **Placement Driver continuously rebalances** — add a replica on store X
(conf-change + snapshot), drop it from store Y — for load, failure domains, and
draining. Regions split/merge. So a Region's membership is an *ever-changing
3-of-N subset of the pool* and **cannot** be static config: it must be replicated
state driven by conf-change, with a snapshot to seed each freshly-placed replica.
**Most of TiKV's membership machinery exists because groups float across the
pool** — dynamic per-group membership, single-voter birth then grow, snapshot-on-
placement, PD rebalancing.

**rove is not a pool.** A **cluster is a small fixed node set** (today 3:
bhs-1/2/3), and **every tenant group lives on *all* nodes of its cluster** —
all-of-N, not 3-of-N. There is no per-tenant placement and no within-cluster
rebalancing; the initial voter set of every tenant is identical ("this cluster's
nodes"). rove **scales by adding clusters, not by growing one** — a tenant that
must move lands on a *different* cluster via the cross-cluster move, and clusters
are deliberately **disjoint transport meshes**. The cluster *is* the placement
unit; tenants move between clusters rather than replicas rebalancing within a pool.

**What this means for the arc:**

- **The machinery rove genuinely needs** is for **cluster-topology change** — a
  node joining/leaving the *cluster* (bhs-3 coming up, a dead node replaced, a
  wiped node recovering). Those affect **every tenant uniformly** (all groups
  add/remove the same node) and the new node has no data → snapshot. That is
  exactly **Phase 1 + Phase 2** (snapshot carries ConfState; joiner learns from
  it), and it is correctly raft-rs-aligned.
- **The machinery rove does NOT need** is TiKV's per-group placement: single-voter
  birth + grow, PD-style rebalancing, 3-of-N selection. Those serve a pool
  elasticity rove doesn't have. (This kills the "single-voter genesis + grow"
  option for Phase 2 — see there.)
- **It reframes membership as a CLUSTER-LEVEL fact**, not a per-tenant one: there
  is one authoritative node set per cluster, shared by every tenant. A topology
  change is a *cluster-wide* fan-out (conf-change + snapshot to every tenant
  group), not a per-tenant decision.
- **It retroactively justifies the Phase 3 divergence.** rove's bespoke
  cross-cluster move looks un-TiKV-like, but it's the right shape *because rove is
  disjoint clusters, not one mesh* — TiKV's conf-change rebalancing assumes a
  single pool, which rove deliberately does not have.

**Caveat (keep honest):** this holds only while rove stays **cluster-granular**.
If rove ever wanted within-cluster scaling (place tenants on subsets of a large
node set), it *would* pull in TiKV's placement machinery — but that is a different
product than the disjoint-3-node-clusters model the docs commit to. The
locked direction is **moving tenants between clusters, not a homogeneous node
pool.**

## The deviations (grounded)

| # | Deviation | Where | Raft-native equivalent | What re-aligning deletes |
|---|---|---|---|---|
| 1 | **Snapshot path stubbed** — `snapshotCb` returns `-1` (Unavailable); a peer below the compaction floor strands forever | `storage.zig:299`, delegated by `file_storage.zig:240` / `grouped_file_storage.zig:1097` | Leader serves a snapshot to a `StateSnapshot` peer (etcd/TiKV) | the strand; the loud-fail backstop becomes a real path |
| 2 | **Lockstep min-match floor** — never compact past a voter so it can always catch up from the log (the snapshot-free workaround) | `min_match_index` (fork `lib.rs:851`), `propagated_floor` wire field (`transport.zig`), `durabilizeTick` floor | Compact freely; snapshot laggards | the whole floor apparatus + the `propagated_floor` wire field + the learner-floor (B) + the birth-window race |
| 3 | **Membership from static `REWIND_VOTERS`** — each node seeds its group ConfState from an env var, not replicated state | `REWIND_VOTERS`, `initWithLearners` born-learner hack | Membership lives in the log + ConfState; a joiner learns it **from the snapshot** | the static voter set, the born-learner hack, the phantom-voter class, most of the reconciler |
| 4 | **Cross-cluster move = fresh group + forward-stream + directory-flip + epoch fence** | `cp/main.zig` move paths, `v2-forward-begin`, epoch in `v2-attach` | conf-change member replacement (add new nodes as learners → snapshot → promote → remove old), à la TiKV region move | (if viable) the epoch/forward/flip apparatus |

### Verdicts

- **#1 snapshot stub → ALIGN ✅ DONE (Phase 1).** Native trigger
  (`matched+1<first_index`) + out-of-band catch-up; mechanism-A compaction.
- **#2 lockstep floor → DELETED ✅ (Phase 2f, `198481a`).** The whole apparatus
  (min-match floor, `propagated_floor`, the wire field) is gone; compaction is
  per-node + snapshot laggards, as raft intends.
- **#3 static `REWIND_VOTERS` → ALIGN ✅ DONE for tenants (Phase 2c/2d/2e).**
  Membership now lives in the replicated state: a joiner learns it from the
  snapshot's ConfState (2c/2d), and fresh formation uses the CP-owned cluster
  node-set SSOT (2e). `REWIND_VOTERS` remains only as the irreducible genesis
  bootstrap (the topology lens: genesis keeps a static config like etcd's
  `--initial-cluster`).
- **#4 bespoke move → CLOSED (justified divergence).** Evaluated as Phase 3 and
  kept: the disjoint raft transport meshes make move-via-conf-change
  architecturally incompatible (it needs cross-cluster raft connectivity), so the
  bespoke move stays. Recorded in `decisions.md` §10.12 (2026-06-19).
- **Prior "follower-sourced / no leader snapshot" decision → RE-OPENED.** It is
  itself a divergence from the native (leader-generated) path. The hot-path
  reason is addressable inside the native model (async generation + S3 bytes), so
  the divergence is no longer clearly justified — see Phase 1.
- **Speculative overlay (apply-before-commit + rollback) → OPEN.** raft applies
  *after* commit; we apply speculatively. Scrutinize: is the latency win worth the
  rollback path and the divergence? Not obviously harmful, but on the ledger now.
- **Leader-only reads (dispatch-gate) vs `read_index` → OPEN.** `read_index` /
  lease-read is raft's native linearizable-read + follower-read mechanism; we
  diverged. Justified *only* while we don't need read scaling — re-scrutinize if
  we do (`docs/plans/raft-best-practices.md` item 2 has the analysis).
- **Epoch fencing on the transport → tied to #4.** raft has no epochs; ours
  exists for cross-cluster moves. If #4 goes conf-change-native, this may
  disappear; otherwise it's a justified divergence for the move feature.

Verdicts marked OPEN are the scrutiny backlog; ALIGN items are the phased plan
below.

## Why the snapshot is the keystone

The agent map confirmed the mechanics:

- **Send (leader):** `FfiStorage::snapshot(request_index, _to)` (`lib.rs:283-315`)
  calls our `snapshotCb`; rc≠0 → `SnapshotTemporarilyUnavailable` → raft retries.
  The outbound `MsgSnapshot` rides the **same** `outbox` → transport path as any
  message (`lib.rs:1534`, `1683`). **So the trigger already fires and the peer id
  (`_to`) is already known** — it's just dropped before the Zig cb and answered
  with `-1`.
- **Receive (follower):** inbound `MsgSnapshot` → `step` → raft `restore` →
  `apply_snapshot(data, meta_index, meta_term)` callback. Our `applySnapshotCb`
  is **data-free** — it resets the log baseline and ignores `data`
  (`storage.zig:361`, `grouped_file_storage.zig:1155` → `applyLocalSnapshot`).
- **Out-of-band install exists:** `raft_manager_apply_local_snapshot`
  (`lib.rs:1135`) installs a data-free baseline at `{index, term}` carrying the
  group's **current ConfState** (`lib.rs:1162-1173`) — membership-neutral. This
  is exactly the receiver half we need.
- **Gaps:** the cb doesn't forward `to`; `report_snapshot` is not wrapped;
  `Progress::state` (Probe/Replicate/Snapshot) is not exposed (only
  `matched`/`recent_active` via `raft_manager_voter_progress`, `lib.rs:1039`).

Re-enabling the snapshot path makes the floor-pin (#2) unnecessary (compact
freely, snapshot laggards) AND lets snapshots carry ConfState, which unlocks
killing the static voter set (#3). So **#1 → #2 → #3** is one arc.

## Phase 1 — re-enable raft-rs's native snapshot path

Under "leverage raft-rs maximally," the default is the **native** path: let
raft-rs drive the whole snapshot lifecycle, exactly as etcd/TiKV do, and have
rove supply only the bytes transport. We diverge **only** where a concrete,
scrutinized constraint forces it.

**Settled shape: leader-side trigger, out-of-band data, leader-push.** We keep
rove's out-of-band data delivery (which is what avoids the hard part —
receiver-side async apply) and detect the behind-peer ourselves on the leader.
Concretely:

- **`snapshotCb` stays `Unavailable`** (`storage.zig:299`) — rove never delivers
  data via `MsgSnapshot`, so the leader's storage never produces one.
- **Trigger on `matched + 1 < first_index`** (the one FFI, `snapshot_pending_peers`):
  the peer's next-needed entry is below the leader's compacted first index, gated
  on `recent_active`. This is exactly the condition raft itself uses internally to
  decide a snapshot is needed; we read it from `Progress` rather than wait for a
  `ProgressState::Snapshot` that our model never produces (see the **CORRECTION**
  below).
- **Auto-orchestrate a leader-push** on detection (pump `snapshotTriggerTick` →
  worker `SnapshotCatchupThread`): the leader dumps its store (consistent
  read-txn cursor via a sibling handle, **direct peer→peer over
  `REWIND_PEER_URLS` — no S3**) → `POST v2-load-replace` **on the peer (its worker,
  off-pump)** → `POST v2-apply-snapshot {index, term}` **on the peer (its pump,
  fast, data-free)**. The peer's `match` advances past `first_index` → it is no
  longer below the floor → the leader replicates the tail.

> **CORRECTION (2026-06-17) — the "native `StateSnapshot` trigger" was a mistake.**
> A peer enters `ProgressState::Snapshot` ONLY when `prepare_send_snapshot`
> actually obtains a snapshot from storage (`raft.rs:716` `become_snapshot`). With
> rove's `snapshotCb` permanently `Unavailable`, `prepare_send_snapshot` returns
> early at `raft.rs:689` BEFORE `become_snapshot`, so the peer sits in `Probe`
> forever and NEVER enters `Snapshot`. The earlier "verified-safe back-off, raft
> parks the peer in StateSnapshot" claim was wrong (confirmed against raft-0.7.0
> source + the reference `MemStorage`, which returns Unavailable only *once* while
> "generating", then a real snapshot). So `snapshot_pending_peers` filters on
> `matched + 1 < first_index`, not progress state.
>
> **What TiKV/etcd do (and how we relate).** Both — TiKV on this exact crate —
> confirm the OUT-OF-BAND DATA half: `snapshot()` returns Unavailable only while
> async-generating, then returns a **metadata-only** snapshot; the bulk ships on a
> side channel (TiKV's Snap Worker over gRPC streams; etcd's `snap.Message`
> `ReadCloser`), and the receiver applies it **asynchronously, off the raft
> thread** ("its large size would block the thread"). rove's split — heavy
> `v2-load-replace` on the worker, fast data-free `apply_local_snapshot` on the
> pump — is the same principle, so the data design is *validated*, not divergent.
> The one **justified divergence**: TiKV eventually returns a real metadata
> snapshot so the peer enters `Snapshot` and raft **pauses replication to it**
> (flow control); we keep `Unavailable` and detect-and-push from the leader. Cost
> of the divergence: one cheap failed `snapshot()` call per heartbeat per lagging
> peer (an error return, no data). Benefit: no receiver-side `MsgSnapshot`
> interception and no raft async-storage machinery. Evaluated + accepted; the
> fully-native flow-control variant is a possible later refinement.

**Why not bytes-in-`MsgSnapshot` (the etcd-native data path):** raft-rs applies a
received snapshot on the *pump* (`restore` → `apply_snapshot` during the Ready).
A large load there blocks **every tenant** on that node (shared multi-raft pump).
The out-of-band split — heavy load on the worker, only the fast baseline install
on the pump — is exactly how `promote_back` already sidesteps that. So we reuse it
rather than building a TiKV-style async apply worker. The data is a logical
key/value stream (cursor under a read txn), so the receiver applies it **in
place** (replace for a snapshot, insert-if-absent for a move) — **no env swap**,
and **one mechanism for both snapshot and move**. The baseline reflects the
durable apply watermark read in the same txn; the committed tail flows via normal
replication.

> **Re-opens a prior decision — and lands close to it.** Leader-generated
> data-carrying `MsgSnapshot` was removed before (`736a718`) in favor of
> out-of-band follower-sourced bootstrap. Re-examined under the mandate: the
> *native trigger* (StateSnapshot) is the part worth adopting (it replaces the
> snapshot-free strand + the floor-pin); the *data path* stays out-of-band,
> because that's what keeps the heavy work off the shared pump. So we leverage
> raft-rs's catch-up state machine without taking its on-pump data apply.

**Earlier detour (reverted):** a first cut added a GFS "staging slot" so
`snapshotCb` could *serve* bytes. That assumed bytes-in-`MsgSnapshot`; with the
out-of-band data path it's unused — reverted. The conf_state-in-`MsgSnapshot`
vtable plumbing is likewise unused (conf_state rides the out-of-band baseline
instead, which Phase 2 needs anyway).

### I4 compaction — DECIDED: fixed catch-up buffer (mechanism **A**)

`durabilizeTick` compacts to `max(0, durable_apply_watermark − grace_count)`,
**per node, independently**. A peer within `grace_count` of the cap catches up
from the log; anyone further back triggers `StateSnapshot` → the out-of-band
catch-up above. Chosen over the peer-aware min-match floor (B-mechanism) for
simplicity: it **deletes the coordination** — no `min_match_index` for the
compaction decision, no `propagated_floor` wire field, no lockstep, no
recent_active filter (B). The fixed buffer is the bound, so a dead/stuck peer
can't pin the WAL (it falls out of the buffer and snapshots). One knob
(`grace_count`, etcd's ~5000), with a **global cap** escape hatch if the
multi-tenant shared-WAL footprint (`Σ grace_count` across hot groups) gets
uncomfortable. Trade-off + the rejected alternative (B, tighter WAL but
coordinated + more snapshots) are in the commit history of this doc.

**Then delete (I4):** `min_match_index`-for-compaction, the voters-only floor +
`propagated_floor`, the recent_active learner-floor (B from the prior branch),
the birth-window concern, the snapshot-free `-1` strand semantics, and the
`high_churn_learner` smoke's reliance on the floor (it becomes a
snapshot-catch-up smoke).

**Residual caveats:** the source holds a read txn for the transfer (LMDB page
pinning → temporary env growth; mitigated by fast LAN transfer, or
materialize-to-local-temp); the append-vs-baseline ordering (the out-of-band
load completes before `apply_local_snapshot` advances `match`, so the tail never
applies onto an unloaded store).

## Phase 2 — membership SSOT (kill `REWIND_VOTERS`)

Once the out-of-band baseline carries the real **ConfState** (the source's
membership, passed through `v2-apply-snapshot` → `apply_local_snapshot`, instead
of the membership-neutral "keep current prs" it does today), a joining node
learns its membership **from the baseline + the replicated conf-change log** —
not the static env. Then:

- Retire `REWIND_VOTERS`; group ConfState is whatever the replicated state says.
- Delete the `initWithLearners` born-learner hack (a joiner is a learner because
  the *ConfState* says so, not because an env flag forced it).
- The phantom-voter class disappears (no second "which nodes" list to drift).
- Most of the reconciler collapses (membership convergence is conf-change +
  snapshot, not bespoke orchestration).

Blocked by Phase 1 (snapshots must carry ConfState first).

### raft-rs / TiKV cross-check (2026-06-17) — the mechanism + a hard constraint

Verified against the raft-0.7.0 source (the crate TiKV uses), not memory:
- **Validated direction.** `Raft::restore` rebuilds membership from the snapshot's
  ConfState — `confchange::restore(&mut self.prs, last_index, cs)` (`raft.rs:2629`).
  A node learning membership from a snapshot IS the native mechanism (it is how
  TiKV peers learn their region membership); the static `REWIND_VOTERS` is the
  divergence we remove.
- **Hard constraint (`raft.rs:2581-2598`).** `restore` THROWS AWAY a snapshot whose
  ConfState does not contain the recipient ("attempted to restore snapshot but it
  is not in the ConfState"). So the membership a baseline carries **must already
  include the joining node** ⇒ the join sequence is **conf-change-add the node on
  the leader FIRST, then install its baseline** — exactly TiKV's add-peer-then-
  snapshot ordering. The fork FFI now enforces this up front (`-6`
  `SelfNotInConfState`) instead of letting `restore` silently drop the baseline.
- **Consistency requirement.** The ConfState a baseline carries must match the
  membership AS OF the baseline's index. TiKV generates snapshot metadata at one
  point; rove reads the index (`v2-applied-baseline`) and the ConfState
  (`v2-confstate`) via SEPARATE endpoints — a TOCTOU if membership changes between
  them. Phase 2d MUST read `{index, term, conf_state}` from ONE consistent read
  (extend `v2-applied-baseline` to also return the ConfState), not two calls.

### Decomposition (steps)

- **2c — ConfState-carrying baseline (foundation) ✅ landed.** Optional `(voters,
  learners)` threaded through `apply_local_snapshot` (fork FFI as primitive u64
  arrays — sidesteps the 2a cross-`@cImport` struct landmine). Null = keep current
  prs (membership-neutral, unchanged); all current callers pass null, so it is
  behavior-neutral (full apply_local_snapshot suite green). `-6` guard enforces the
  self-in-ConfState constraint above.
- **2d-1 + 2d-2 — worker-side capability ✅ landed (`7ae9695`).**
  `v2-applied-baseline` returns the leader's ConfState alongside `{index,term,epoch}`
  in one consistent read; `v2-attach` accepts `X-Rewind-Voters`/`X-Rewind-Learners`
  → threaded to `apply_local_snapshot`, so a baseline carries the source membership
  and the joiner adopts it. Validated by `membership_from_snapshot_smoke_v2`
  (the `-6`/409 self-omit guard is the distinguisher). Absent headers →
  membership-neutral (unchanged).
- **2d-3 — reconciler integration ✅ LANDED via augmented ConfState (`678b885`).**
  `bootstrapMember` reads the leader's CURRENT ConfState and bootstraps the joiner
  with that set PLUS itself as a learner (the augmented set, carried by the
  baseline). This satisfies raft.rs:2581 (recipient is in the ConfState) WITHOUT
  reordering, so the panic-safe **bootstrap-THEN-add** order is preserved — the
  leader doesn't track/commit to the node until the AddLearner that FOLLOWS the
  bootstrap. (The FIRST attempt reordered to add-FIRST and hit `raft_log.rs:292`
  `to_commit out of range`: the leader committed to the node before its group
  existed at a consistent baseline. The augmented approach changes only the
  ConfState CONTENT, not the order.) Validated: membership_reconciler **6/6, ZERO
  crashes** (vs the reorder's 1/3 abort) + the join-path suite green. Runtime proof
  the augmentation is correct: a self-omitting ConfState 409s via the `-6` guard,
  so 6/6 heals succeeding ⇒ the node was correctly in the augmented set. Delete the
  `initWithLearners` hack is still open (the born set is overwritten by the
  baseline ConfState, so the hack is now inert for the reconciler path).
- **2e — cluster node-set SSOT ✅ LANDED (`8830341`).** A fresh tenant group is born
  with the **CP-supplied cluster node set** (`createGroupCore` `voters_override`,
  threaded via `v2-attach`'s `X-Rewind-Voters`; CP `handleProvision` passes
  `1..nodes.len`), not each node's `REWIND_VOTERS`. Verified `source=cp-ssot`
  end-to-end (1- and 3-node). `REWIND_VOTERS` stays the irreducible genesis/lazy
  fallback. Additive (CP set == env set today, so behavior-identical; the SOURCE
  changes). Scoped to provision; moves still pass null. Rationale (per the topology
  lens above): the "initial voter set" is NOT a per-tenant fact — it is
  ONE cluster-level fact ("this cluster's node set"), shared by every tenant. So
  2e is **"promote the cluster node set to a CP-owned SSOT,"** not "decide each
  tenant's voters." The **single-voter-birth-then-grow** option (TiKV's per-Region
  model) is **REJECTED** — it serves pool elasticity rove doesn't have and adds a
  per-tenant grow cost for no benefit. The model: CP owns the authoritative node
  list (it already has `REWIND_CLUSTERS`); every tenant group is born from it, and
  a cluster topology change (add/remove a node) fans out as a conf-change +
  snapshot to every tenant group. Genesis groups (CP directory, `__admin__`) keep
  an irreducible static bootstrap — like etcd's `--initial-cluster`; that floor
  cannot be snapshot-driven (nothing to snapshot from yet) and is correct.
  `REWIND_VOTERS` (the per-node env) is retired for tenants in favor of the
  CP-passed set (the `cp/main.zig:527` "explicit-id model is the SSOT cleanup"
  direction). Open sub-question: pass the set at provision time vs. derive it from
  a replicated cluster-membership record.
- **2f — delete the floor apparatus ✅ LANDED (`198481a`).** Removes ledger
  deviation #2 (the lockstep WAL-compaction floor), already neutered by mechanism-A
  in 2b. Deleted: the per-record `floor` wire field (transport header 28→20 bytes),
  `recv_floors`, `drainFloors`, `SendCtx.floor`, `applyRecvFloor`,
  `propagated_floor`. Wire-format change, gated on the FULL raft suite (15/15,
  0 panics, 0 undecodable msgs) + v2-test. **Retained** (NOT deleted): the
  `createGroupCore` born-learner hack — `as_learner` can pair with baseline index 0
  (no baseline to overwrite the born set), so it stays a safety net. The reconciler
  itself stays — its job is genuine (cluster-topology convergence per the topology
  lens), not bespoke-to-collapse. Dead fork `min_match_index` FFI left for a later
  fork cleanup. **This closes out Phase 2 (membership SSOT).**

## Phase 2.5 — chunked-streaming snapshot transfer (multi-GB) — BUILT 2026-06-18

**Status: built + smoke-verified** (catch-up path; the move path's buffered
endpoints are retained and un-regressed). The design below is as-built; a couple
of choices diverged from the original plan and are flagged inline.

**Why before Phase 3.** The out-of-band catch-up (Phase 1) and the cross-cluster
move shared ONE primitive — the single-shot `dumpTenantBundle` — which does not
scale past ~hundreds of MB. Phase 3 (move-via-conf-change) is moot for large
tenants until this lands.

### The wall (the retired single-shot path)

`KvStore.dumpTenantBundle` → `kvexp.dumpTenantBundle`: `durabilize(0)`,
`openSnapshot`, write **every pair into one `ArrayList(u8)`**. That buffer was
shipped as **one HTTP body** and loaded on the dest in **one atomic kvexp txn**.
At multi-GB that's a multi-GB allocation on source AND dest, one unbounded HTTP
body, a giant single write txn, and a read txn pinning pages for the whole
transfer. The catch-up driver inherited all of it (plus the
`durabilize(0)`-contends-with-the-write-loop issue from Phase 1).

### As built

Both the catch-up driver AND the move now stream. (The move CONVERGED to one
path: the brief-pause/quiesce move was retired — see "Move convergence" below —
so `/_control/move` is the zero-downtime, streamed move.)

- **Codec — `src/kv/snapshot_stream.zig` (pure Zig, round-trip tested).** Two
  halves over the existing pair framing, but with its OWN magic (`STREAM_MAGIC`,
  distinct from `BUNDLE_MAGIC`) and **no `n_pairs`** (single-pass source; the
  stream ends at body EOF):
  - `StreamDumper` — PULL-model source. `openSnapshot` once (NO `durabilize` —
    overlay capture sees committed pairs, so no leader-poll-loop fsync
    contention), a held `SnapshotPrefixCursor`, staging exactly ONE pair at a time
    into a caller buffer. Memory bounded to one pair.
  - `StreamLoader` — PUSH-model dest. Parses frames split across ANY chunk
    boundary; applies in **bounded kvexp txns** (commit per `batch_max_*`).
    REPLACE clears the store in the first batch. The lease is held only for the
    duration of a single `feed()` call (never across calls) so the worker thread
    can't deadlock re-acquiring the tenant's non-reentrant lease.
- **Transport — libcurl producer-pull upload (NOT a streaming response).** The
  *leader pushes* (Phase 1's leader-detect trigger is leader-side, and etcd/TiKV
  push out-of-band snapshot data), so the source issues a chunked upload via
  `curl.Easy.requestUpload` (`CURLOPT_READFUNCTION` pulls from the `StreamDumper`
  only as the wire drains — true backpressure, bytes never leave Zig). This is the
  plan's one real divergence: pull-via-streaming-response would have put the dest
  hook on the JS-coupled `StreamChain`/`serviceParkedStreams` path; push keeps the
  one new server-side hook on the simpler inbound side.
- **Endpoint — one call.** `POST /_system/v2-snapshot-stream`: body is the pure
  pair stream; the data-free baseline `{tenant, index, term}` rides in headers —
  collapsing the retired two-call `v2-load-replace` + `v2-apply-snapshot`.
- **Dest wiring — rove-native, no S3.** Customer `onChunk` streaming round-trips
  >cap chunks through the S3 chunk-tape durability gate — WRONG for an internal
  snapshot. So `v2-snapshot-stream` is intercepted before the `/_system`
  buffer-flip and gets a dedicated `h2.BodySink` (`src/js/snapshot_sink.zig`) that
  feeds the `StreamLoader` directly. State is rove-native: a heap `Box` (the stable
  `BodySink` ctx) owned by a `SnapshotStream` *component* on the request entity
  (refcounted with the sink — NO side map); the entity parks via collection
  membership (`request_out → snapshot_streams → response_in`). On END_STREAM,
  `drainSnapshotStreams` finalizes: `StreamLoader.finish()` → `durabilize(0)` →
  `applyLocalSnapshot {index,term}` → 204.

### Zero-downtime move — source push (CP-triggered)

The move reuses the same primitives, source-pushing direct to each dest (the CP
no longer buffers a bundle):

- **Dest — `merge` mode.** `v2-snapshot-stream?mode=merge` (header) drives
  `StreamLoader.skip_existing` (insert-if-absent — a live-forwarded newer key is
  kept), with NO baseline install and NO leadership check (applies on every dest
  node, like the retired `v2-load-merge`); on finish it drops the inherited
  `_move/forward` marker + `durabilize`s. `Box.Mode` carries replace-vs-merge.
- **Source — `POST /_system/v2-snapshot-push`.** CP-triggered, leader-gated. Parks
  the request in a `snapshot_pushes` collection (membership = "push in flight"; no
  per-entity component — the job params live in the off-loop driver's `Job`) and
  enqueues a move-push on the shared `SnapshotCatchupThread` (it now serves both
  internal catch-up and CP-triggered pushes). A multi-GB stream must not block the
  worker loop, so the reply is **deferred**: the driver streams off-loop, posts
  `{Entity, status}` to a mutex-guarded completion inbox (the `proxy_engine`
  `ProxyResultInbox` seam — the one cross-thread channel; the thread never touches
  rove state), and `drainSnapshotPushes` matches the Entity handle back to its
  parked request → `response_in`.
- **CP — `streamMergeToAll`.** Per dest node, trigger the source leader to stream
  in merge mode (`snapshotPushToLeader`, generous timeout — the source's own
  page-pinning deadline aborts first). Replaces `snapshotFromLeader` (dump→CP) +
  `loadMergeToAll` (CP→dest); the CP never holds the bundle.

### Move convergence — one move, no brief-pause

Once the move streamed (above), the **brief-pause move was retired** — there is
ONE move now. The brief-pause path (quiesce the source, dump a bundle, ship it,
flip) only ever existed as the simple/fast variant for small tenants where a
momentary pause is fine; it bought nothing a real stakeholder values (operators
don't care about a few seconds on a rare admin op; tenants want no downtime) and
cost a second code path + a footgun default (a large brief-pause move would
balloon CP memory). `/_control/move` and `/_control/move-live` both route to the
zero-downtime move; `rewind-ops move` is always-live.

Removed with it: `v2-bundle` / `v2-resume`, the bridge **quiesce** machinery
(`quiesce`/`unquiesce`/`Quiesced` + the propose-path check). Also removed: the
`moving`-hold + stuck-move reconciliation (`reconcileStuckMoves`/`abortStuckMove`/
`collectMoving`, directory `beginMove`/`abortMove`/`moving`-state, front-door
`.moving → 503`) — the zero-downtime move never sets `moving` (a `moving`-503
would BE downtime), so a move can't get stuck `moving`; the obsolete
`cp_move_recovery_smoke` was deleted with it.

### Consistency + the baseline

Unchanged from Phase 1: the baseline is the leader's apply point; a half-loaded
store is never authoritative because the dest installs the raft baseline only on
clean END_STREAM, and a mid-stream abort retries (REPLACE re-clears, idempotent).

### Page-pinning bound

The held read txn pins LMDB pages for the transfer's lifetime → the leader's env
can grow by write_rate × transfer_time. Bounded by `REWIND_SNAPSHOT_XFER_MAX_MS`
(default 10 min): the source aborts + logs loudly past the deadline and retries
next trigger tick from a fresh snapshot, rather than ballooning the leader. (A
materialize-to-temp alternative for pathologically-hot tenants stays open.)

### Verified

`scripts/snapshot_stream_large_smoke_v2.py` — a ~50 MiB store (server-generated
256 KiB values) streamed to a peer stranded past the compaction buffer, recovered
to the leader's `last_index`, sampled big values read back byte-exact across
multiple dest batches. `snapshot_trigger_smoke_v2` passes via the new path;
`zero_downtime_move_smoke.py` Leg 2 (`move-live`) now drives the streamed merge
push end-to-end (source serves throughout, dest serves after the flip);
`promote_back_smoke_v2` (the retained buffered path) un-regressed; unit 635/636.
(~50 MiB is a proxy for multi-GB — true multi-GB is impractical in a quick smoke;
the bounded-memory property is architectural + unit-tested. RSS sampling was
dropped as mmap-confounded in favor of byte-exact-at-scale.) Worker-side state is
rove-native throughout (collections + components, Entity-handle cross-refs, no
side maps for entity state) and fail-fast (no `catch {}` on the new paths).

## Phase 3 — evaluate move-via-conf-change → CLOSED (keep bespoke)

**Decided 2026-06-19 — `decisions.md` §10.12.** Evaluated after P1/P2/P2.5: the
bespoke move stays; move-via-conf-change is a rejected alternative (justified
divergence). The arc's machinery (ConfState-carrying snapshots, streamed transfer,
learner→promote) removed every *mechanical* objection, leaving one *topological*
one that is decisive — see below. The original question and reasoning are kept
for the record.

The question was: could a cross-cluster move be
`addLearner(new nodes) → snapshot → promote → removeNode(old)` (TiKV region
move), with the directory routing following the membership — collapsing the
fresh-group + forward + flip + epoch apparatus into conf-change + snapshot?

**Verdict: justified divergence (keep the bespoke move) — per the topology lens.**
TiKV's conf-change move works *because all stores are one homogeneous pool with
cross-store raft connectivity*; a Region replica can be added on any store via
conf-change because every store can talk raft to every other. **rove's clusters
are deliberately disjoint transport meshes** (the whole scaling model is "move
tenants between clusters," not "grow one pool" — see the topology section). A
single raft group spanning two clusters would need cross-cluster raft
connectivity, breaking the disjoint-mesh property on purpose introduced for
isolation/blast-radius. And "who serves during the membership overlap" is a real
routing question the directory-flip answers atomically. So the move-via-conf-change
is likely *not* the rove-native path; the bespoke move (fresh group on the
destination cluster + forward stream + atomic directory flip + epoch fence) is the
justified divergence — it is the cross-*cluster* analog of TiKV's within-pool
rebalance, at the granularity rove actually scales by. Confirm with evidence, but
the topology framing makes "keep it" the expected verdict, not "align it away."

## Cross-cutting

- **Apply accounting:** verify rove's `slot.applied_idx`/`durabilized_idx`
  bookkeeping tracks raft-rs's commit/apply rather than drifting (we saw
  `applied=52` vs committed/last `66` on a prod leader). Load-bearing now that the
  baseline reads `slot.applied_idx`.
- **Speculative overlay** (apply-before-commit + rollback): non-canonical latency
  optimization. Confirm it earns its complexity vs. applying on commit. Low
  priority; not obviously causing harm.

## In-flight branch reconciliation (`feat/high-churn-learner`)

- **Keep:** the **epoch fix** (group identity fencing — orthogonal to the
  snapshot arc, and a prerequisite for the tail-replication after a bootstrap);
  **A** (`v2-applied-baseline` returns live `slot.applied_idx` — the in-log
  baseline, aligns with the snapshot source); **C** (loud `snapshotCb`) —
  **C's detection point becomes Phase 1's trigger**.
- **Superseded by Phase 1:** **B** (the `recent_active` learner-floor) and the
  `high_churn_learner` smoke. B is deployed (prod, inert with no learners); leave
  it until Phase 1 removes the floor approach wholesale, to avoid churn.

## Risk + gating

This is the consensus engine. Every phase:
- gated on the full raft smoke suite (`confchange`, `auto_demote`, `promote_back`,
  `learner_add`, `fresh_voter_join`, `three_node`, `membership_reconciler`,
  `leader_failover`, `graceful_transfer`, `snap_catchup`, `dispatch_gate`) +
  `v2-test` + `test`, plus a soak on real disk;
- coordinated fork↔rove via the pin protocol (`docs/plans/raft-correctness-plan.md`):
  land fork FFI + push, then bump the rove pin with the caller change together;
- reverts a prior decision (snapshot-free) deliberately — the new path is
  follower-sourced (leader off the data path), which was the stated preference.

## Sequencing

1. **Phase 1** (follower-sourced snapshots) — keystone; unblocks the rest. ✅ landed
   (step 2b, `d09744a`), with the trigger CORRECTION (`matched+1<first_index`).
2. **Phase 2** (membership SSOT) — unlocked by P1's ConfState-carrying snapshots.
3. **Phase 2.5** (chunked-streaming snapshot transfer) — makes the snapshot/move
   primitive scale to multi-GB tenants; prerequisite for large-tenant moves, so it
   precedes Phase 3.
4. **Phase 3** (move-via-conf-change) — evaluated, CLOSED: keep the bespoke move
   (justified divergence, `decisions.md` §10.12). No code.

Then: redeploy, and the `__admin__` 3-voter re-add (and any future under-load
backfill) is a non-event — a laggard just gets a snapshot.
