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

## The deviations (grounded)

| # | Deviation | Where | Raft-native equivalent | What re-aligning deletes |
|---|---|---|---|---|
| 1 | **Snapshot path stubbed** — `snapshotCb` returns `-1` (Unavailable); a peer below the compaction floor strands forever | `storage.zig:299`, delegated by `file_storage.zig:240` / `grouped_file_storage.zig:1097` | Leader serves a snapshot to a `StateSnapshot` peer (etcd/TiKV) | the strand; the loud-fail backstop becomes a real path |
| 2 | **Lockstep min-match floor** — never compact past a voter so it can always catch up from the log (the snapshot-free workaround) | `min_match_index` (fork `lib.rs:851`), `propagated_floor` wire field (`transport.zig`), `durabilizeTick` floor | Compact freely; snapshot laggards | the whole floor apparatus + the `propagated_floor` wire field + the learner-floor (B) + the birth-window race |
| 3 | **Membership from static `REWIND_VOTERS`** — each node seeds its group ConfState from an env var, not replicated state | `REWIND_VOTERS`, `initWithLearners` born-learner hack | Membership lives in the log + ConfState; a joiner learns it **from the snapshot** | the static voter set, the born-learner hack, the phantom-voter class, most of the reconciler |
| 4 | **Cross-cluster move = fresh group + forward-stream + directory-flip + epoch fence** | `cp/main.zig` move paths, `v2-forward-begin`, epoch in `v2-attach` | conf-change member replacement (add new nodes as learners → snapshot → promote → remove old), à la TiKV region move | (if viable) the epoch/forward/flip apparatus |

### Verdicts

- **#1 snapshot stub → ALIGN.** Pure workaround for a disabled primitive. Adopt
  raft-rs's native snapshot path (Phase 1).
- **#2 lockstep floor → ALIGN (delete).** Exists only to compensate for #1. Once
  snapshots work, compact freely and snapshot laggards, as raft intends.
- **#3 static `REWIND_VOTERS` → ALIGN (delete).** Membership belongs in the
  replicated state; a joiner learns it from the snapshot's ConfState (Phase 2).
- **#4 bespoke move → OPEN.** TiKV moves replicas via conf-change; evaluate
  whether ours can too (Phase 3). May be a *justified divergence* (disjoint
  cluster meshes + routing-during-overlap) — decide with evidence.
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
  we do (`docs/raft-best-practices.md` item 2 has the analysis).
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

**Settled shape: native *trigger*, out-of-band *data*.** We use raft-rs's
snapshot *signaling* (the `StateSnapshot` catch-up state machine) but keep rove's
out-of-band data delivery — which is what avoids the one hard part (receiver-side
async apply). Concretely:

- **`snapshotCb` stays `Unavailable`** (`storage.zig:299`) — it is the "this peer
  is behind" *signal*. raft holds the peer in `StateSnapshot` and retries
  (verified-safe back-off); it never strands silently and never blocks.
- **Detect `StateSnapshot`** on the leader — the one new FFI: extend
  `voter_progress` to expose `Progress::state` (Probe/Replicate/Snapshot). This is
  the trigger.
- **Auto-orchestrate the existing `promote_back` sequence** on detection: the
  behind peer pulls the bundle (consistent read-txn cursor, streamed in chunks,
  **direct peer→peer over `v2-snapshot` — no S3**) → `v2-load-replace` **on its
  worker (off-pump)** → `apply_local_snapshot {index, term, conf_state}` **on its
  pump (fast, data-free)**. Its `match` advances → `StateSnapshot` clears → the
  leader replicates the tail.

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

## Phase 3 — evaluate move-via-conf-change

Open question, decided after P1/P2. Can a cross-cluster move be
`addLearner(new nodes) → snapshot → promote → removeNode(old)` (TiKV region
move), with the directory routing following the membership — collapsing the
fresh-group + forward + flip + epoch apparatus into conf-change + snapshot?

**Caveats that may block it:** clusters are likely disjoint transport meshes (a
group spanning both clusters needs cross-cluster raft connectivity); and
"who serves during the membership overlap" is a real routing question the
directory-flip currently answers atomically. May not be viable — evaluate, don't
assume.

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
- coordinated fork↔rove via the pin protocol (`docs/raft-correctness-plan.md`):
  land fork FFI + push, then bump the rove pin with the caller change together;
- reverts a prior decision (snapshot-free) deliberately — the new path is
  follower-sourced (leader off the data path), which was the stated preference.

## Sequencing

1. **Phase 1** (follower-sourced snapshots) — keystone; unblocks the rest.
2. **Phase 2** (membership SSOT) — unlocked by P1's ConfState-carrying snapshots.
3. **Phase 3** (move-via-conf-change) — evaluate; may or may not land.

Then: redeploy, and the `__admin__` 3-voter re-add (and any future under-load
backfill) is a non-event — a laggard just gets a snapshot.
