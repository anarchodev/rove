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

**Native machinery to use (stop stubbing):**
- **Leader `snapshot()`** (`storage.zig:299`): return a real snapshot —
  `{index, term, ConfState}` metadata + the data — instead of `-1`. Use raft-rs's
  **async pattern**: if a fresh-enough snapshot isn't staged yet, return
  `SnapshotTemporarilyUnavailable` and stage it **off-pump** (the two-handle
  consistent read we already use for moves); serve it on raft's retry. This is
  precisely how etcd generates snapshots lazily — no hot-path block.
- **`MsgSnapshot`** already rides our transport (`lib.rs:1534/1683`) — no new
  wire path for the *trigger/metadata*.
- **Receiver `apply_snapshot`** (`storage.zig:361`): apply the data + set
  ConfState from the metadata (the storage confstate path) — *this is what
  unlocks Phase 2*.
- **`report_snapshot`** (new FFI — not currently wrapped): wire it so the leader's
  Progress state machine tracks send success/failure natively, instead of us
  inferring catch-up.
- **`Progress::state`** (extend `voter_progress`): expose Probe/Replicate/Snapshot
  so observability matches raft's own model.

**The one scrutinized divergence — large snapshot bytes.** Our coalesced
io_uring transport can't carry an MB-scale snapshot inline, and a leader
*streaming* bytes on the serving path is the concern behind the earlier
rejection. etcd hit the identical wall and solved it **within** the native model:
metadata rides `MsgSnapshot`, the bytes stream over a **dedicated side channel**
(`/raft/snapshot`). rove's aligned equivalent: the snapshot data is a small
**S3 pointer** (we already stage tenant bundles to S3 for moves); the receiver's
`apply_snapshot` fetches the bundle from S3. So the leader **generates** the
snapshot (off-pump) but **never streams the bytes** — S3 does. That satisfies the
hot-path concern *inside* the native machinery, rather than replacing it.

> **Re-opens a prior decision.** This is leader-*generated* snapshots, which were
> previously removed (`736a718`/fork `1ad54fc`) in favor of follower-sourced
> out-of-band bootstrap. Under the new mandate that rejection is itself a
> divergence to justify. The hot-path objection is addressed by **async
> generation + S3 bytes** (etcd's own approach); the residual question is whether
> leader-side *generation* (an off-pump consistent dump) is acceptable. My read:
> yes — etcd/TiKV do exactly this, and we already do the equivalent off-pump dump
> for moves. **Follower-sourcing becomes a fallback** (the leader can name a
> caught-up voter as the S3 stager if we want generation off the leader too), not
> the primary design — it's the more divergent option and must earn its place.

**Then delete:** the `min_match_index` learner inclusion (B), the voters-only
floor *and* `propagated_floor` (compact to applied — raft snapshots laggards
now), the snapshot-free `-1` stubs, the birth-window concern, and the
`high_churn_learner` smoke's reliance on the floor.

**Residual caveats** (all of which etcd/TiKV already carry, so they're
"intended" costs, not rove-specific): snapshot generation cost (bounded by
async + retention); the append-vs-snapshot ordering gate (raft's `StateSnapshot`
handles it); S3 availability for the bytes (same dependency as moves).

## Phase 2 — membership SSOT (kill `REWIND_VOTERS`)

Once snapshots carry the real **ConfState** (Phase 1 sends it in the snapshot
metadata, and `apply_snapshot` sets it via the storage confstate path instead of
the static init), a joining node learns its membership **from the snapshot +
conf-change log** — the raft-native way. Then:

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
