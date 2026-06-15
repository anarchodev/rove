# Raft best practices — done, reachable, and blocked

Status of raft hardening for the V2 multi-raft engine (raft-rs 0.7 via the
`raft_rs_zig` fork). Written after the strict-serializable-read work landed
(merge `raft-config-ffi`). Read this before picking up "the other raft best
practices" — the key framing is **config knobs vs. RawNode methods**: opening
the `Config` FFI unblocked the election/quorum-tuning family, but the
highest-value remaining items are *RawNode methods*, which need NEW `extern
"C"` functions in the fork, not just a config field.

## Done (shipped on `main`)

| Practice | What | Where |
|---|---|---|
| Widened `Config` FFI | `RaftGroupConfig` mirrors the full tunable `raft::Config` across the FFI; NULL = historical defaults, non-NULL validated by `RawNode::new` | fork `feat/config-ffi` @ `f6075137`; Zig `defaultGroupConfig()` |
| **pre_vote** | a partitioned / hibernated-then-woken node probes before bumping its term — can't disrupt a healthy leader or ratchet terms in a mass-wake | `node.zig` `group_raft_config` |
| **check_quorum** | a leader that stops hearing from a quorum steps down within ~one election timeout — bounds the deposed-leader stale-read window | `node.zig` `group_raft_config` |
| Dispatch-gate (strict-serializable reads) | only the tenant group's leader runs the handler; a non-leader 421s BEFORE executing, so reads can't serve from a lagging follower. One gate for reads and writes | `worker_dispatch.zig`; `bridge.isSingleNode` |
| Leader-hint cache | the front learns the leader from a 421→success re-aim and routes there directly — removes the per-read redirect tax; self-correcting on leadership change / dead leader | `front/proxy.zig` `LeaderCache` |
| **transfer_leader** (graceful shutdown) | on SIGTERM the outgoing node hands every group it leads to the most caught-up *voter* before stopping the pump, so a rolling restart (`/deploy`) costs ~one heartbeat per group instead of a full election timeout | fork `raft_manager_transfer_leadership_away` (NEW extern fn, fork `feat/transfer-leader`) → `manager.transferLeadershipAway`; `node.zig` / `bridge.transferAllLeadership` (pump-thread control cmd); `rewind/main.zig` shutdown call + bounded drain |

Read-consistency contract is now **strict-serializable leader reads** (was
eventual / read-your-writes-only-within-a-handler). The only residual gap is
the deposed-leader window, now *bounded* by check_quorum (see `read_index`
below to eliminate it).

Validation: `dispatch_gate_smoke_v2` (gate + idle/hibernation), plus
`rewind_smoke`, `three_node_smoke`, `leader_failover_smoke_v2`; `LeaderCache`
unit tests in `proxy.zig`. `graceful_transfer_smoke_v2` covers the SIGTERM
handoff: the dead leader's log shows "handed off leadership of N group(s)" and
a survivor re-leads in ~0.2s (no election-timeout gap) with a fresh write
committing on the new leader.

## Reachable now — config only, no further FFI (just set the field)

These are fields on `RaftGroupConfig` / `defaultGroupConfig()`, settable in
`node.zig`'s `group_raft_config`. No fork work needed.

- **Randomized / staggered election window** (`min_election_tick` /
  `max_election_tick`). raft-rs already randomizes per group by default; the
  thundering-herd risk in rove is that the pump ticks all active groups in
  lockstep (`tickGroups(active)`), collapsing that jitter. If a mass-wake
  election storm shows up, widen/jitter here (or jitter the tick), not in the
  FFI. Validate with a many-group wake test.
- **priority** — leadership-election preference. Useful as a soft companion
  to leadership transfer (prefer specific nodes as leader). Inert without a
  reason to bias; harmless to set.
- **Flow control / snapshot-send sizing** — `max_size_per_msg`,
  `max_inflight_msgs`. Tune if a lagging follower's catch-up floods the wire.
- `applied` (restart applied-index), `batch_append`, `skip_bcast_commit`,
  `max_uncommitted_size`, `max_committed_size_per_ready` — situational.
- `read_only_option` (Safe / LeaseBased) — settable, but **inert without the
  `read_index` method** (below). LeaseBased also requires `check_quorum`
  (already on); raft `validate()` enforces that.

## Blocked on NEW FFI methods (need extern "C" fns in the fork)

These are `RawNode` methods, not config. Each needs: a Rust
`raft_manager_*` extern fn in `raft-sys/src/lib.rs`, a Zig wrapper in
`manager.zig`, a re-pin, and usually a bridge accessor + worker/front wiring.
Listed by value. (`transfer_leader` was #1 here and is now **Done** above — it
is the worked example of the full FFI-method → re-pin → wiring path.)

1. **`read_index` — ReadIndex / LeaseBased linearizable reads.**
   Eliminates the deposed-leader window entirely (check_quorum only *bounds*
   it). The `read_only_option` config is already settable but does nothing
   until this method exists and the read path calls it. Cost: a heartbeat
   round per read (batchable). Only needed if the check_quorum bound isn't
   tight enough for the contract. (`RawNode::read_index(rctx)`.)

2. **`propose_conf_change` / `apply_conf_change` — membership changes /
   learners.** Add/remove voters one at a time; join new nodes as learners
   and promote after catch-up (avoids shrinking the quorum). Bigger than the
   other items: the storage vtable has **no `set_conf_state` callback** today
   (ConfState is only read at `initial_state` / written via snapshot
   metadata), so durable membership needs a new storage callback + the
   pump apply-path calling `apply_conf_change` on each committed conf-change
   entry + CP node-join orchestration (learner-join → catch-up → promote).
   The GPF that blocked the early spike is fixed on fork `main` (`5092bc6`,
   the opt-level build fix; see `docs/BUG-…confchange-gpf.md`). Needed for
   runtime cluster growth (no `addCluster` runtime endpoint today — see the
   OVH prod notes).

3. **`request_snapshot`** — follower-initiated snapshot when its log was
   truncated past its index. Leader-side compaction is storage-trait driven
   (below), but the follower-pull path is blocked.

4. **`report_unreachable` / `report_snapshot`** — let the leader back off a
   dead/slow follower's send loop instead of spinning. Quality-of-implementation
   for degraded clusters.

5. **`leader_id` accessor** — would let a 421 carry an explicit leader hint.
   NOT needed: the front-side `LeaderCache` learns the leader from
   421→success without it. Listed only so nobody re-derives the need.

## Not FFI-method-blocked, but unaddressed

- **Per-group snapshotting + log compaction.** At K=10k groups, uncompacted
  per-group logs are a real disk/replay cost. This is driven via the storage
  trait / app side (the grouped-file storage), not a RawNode method — so it's
  a rove-side design task, not a fork FFI gap. Check how/when rove snapshots
  and whether snapshotting blocks the pump.

## Things to keep in mind

- **Hibernation interactions.** A hibernated group isn't ticked, so it never
  evaluates check_quorum and can't spuriously step down; an active leader's
  heartbeats are still answered by hibernated followers because a stepped
  heartbeat sets `has_ready` → notifies the pump's `poll_ready` queue →
  response sent independent of the active set. Any new tick-driven behavior
  (e.g. lease reads) must be re-checked against this.
- **Uniform config cluster-wide.** All nodes run the same binary, so
  pre_vote/check_quorum are uniform; a rolling deploy has a transient
  mixed-config window (acceptable pre-launch — dev clusters are wiped).
- **Fork pin durability.** rove now pins fork `06df085` (the transfer_leader
  commit, on branch `feat/transfer-leader`). It branches from `f607513` (= old
  `main`). For durability the fork `main` should be fast-forwarded onto
  `06df085` so the pin is reachable from mainline and survives the feature
  branch being deleted — same practice as the `f6075137` re-pin
  (`443c592..f607513`). The next FFI change (read_index / conf_change) branches
  from fork `main` and re-pins likewise.

## Pointers

- Strict-serializable read design + the eventual→strict reasoning: the
  `raft-config-ffi` merge commit and its 4 feature commits (`pre_vote`,
  `dispatch-gate`, `leader-hint`, `check_quorum`).
- Effect model / consistency framing: `docs/effect-algebra.md`,
  `docs/architecture/consensus-and-storage.md`.
- Locked decisions: `docs/decisions.md` §10 (V2 multi-raft).
