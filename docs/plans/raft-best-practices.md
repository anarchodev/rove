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
| **Multi-node WAL compaction (snapshot-free, lockstep)** | multi-node nodes now truncate the shared WAL (was single-node-only). The leader floors compaction at the cluster-wide **min match index** and **propagates that floor** on its outbound raft messages; a follower truncates to the same floor (`propagated_floor`). No node ever compacts past an entry a voter still needs, so a lagging/returning voter always catches up from the **log** — no in-raft snapshot, no dump on any node's hot path. WAL self-heals: a down voter pins the floor (WAL grows during the outage), advances on its return. A genuinely *new* member (conf_change learner / tenant move) bootstraps **out-of-band** (the move's follower-sourced off-pump bundle), not via raft. | fork `raft_manager_min_match_index`; `node.zig` `durabilizeTick` floor + `outboundFloor`/`applyRecvFloor`/`propagated_floor`, `transport.zig` per-record `floor` field + `drainFloors` (branch `feat/multinode-snapshot`) |
| **`propose_conf_change` / learners / `voter_progress`** | membership changes through the native conf-change path — add voters one at a time, join new nodes as learners and promote after catch-up (never shrinks the quorum). A learner bootstraps its tenant store **out-of-band** (the tenant-move bundle, off the leader's hot path), then joins raft already caught up. The FFI methods now live in `bridge.zig`; CP node-join orchestration (out-of-band bootstrap → learner-join → catch-up → promote) is tracked by `cp-membership-reconciler-plan.md`. | fork conf-change extern fns; `bridge.zig` `proposeConfChange` / `asLearner` / `voterProgress`; see `cp-membership-reconciler-plan.md` |

Read-consistency contract is now **strict-serializable leader reads** (was
eventual / read-your-writes-only-within-a-handler). The only residual gap is a
**partition-window stale read on clean read-only requests**, consciously
accepted and bounded by check_quorum — see "`read_index` — consciously not
done" below for the precise scope, the scenario, and why Safe-mode read_index
(the only thing that would close it) isn't worth its per-read cost.

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
  `read_index` method**, which is **consciously not built** (see below).
  LeaseBased also requires `check_quorum` (already on); raft `validate()`
  enforces that.

## How to size election / heartbeat timeouts in our environment

Don't inherit a number — *derive* it. The governing inequality (Raft paper) is

    broadcastTime  ≪  electionTimeout  ≪  MTBF

and both bounds are measurable on our hardware. This is the procedure and the
tooling that backs it (all shipped: tick-decoupling + metrics in `a6c74ea`, soak
in `7c6b6ae`).

### Prerequisite: the tick is a stable clock (done)

raft ticks are *logical* — `election_tick` / `heartbeat_tick` are counts of them,
so the wall-clock election timeout = `election_tick × tick_interval`. The pump
used to tick once per loop *cycle*, coupling the timeout to load (faster when
idle, slower under a write burst + fsync) — which makes "what is our election
timeout?" unanswerable. `node.tick_interval_ns` now gates the tick at a fixed
monotonic interval (env `REWIND_RAFT_TICK_MS`, default 1ms), so
`election_tick × tick_interval` is a real, stable number. Without this, nothing
below is meaningful.

Defaults today: `election_tick=10`, `heartbeat_tick=3`, tick=1ms ⇒ **election
timeout ≈ 10–20ms** (raft randomizes 1×–2×), **heartbeat ≈ 3ms**.

### The three quantities (and how to read each one here)

| Term | What it bounds | How to measure on our boxes |
|---|---|---|
| **broadcastTime** | the *floor* — heartbeat must clear it | `/_system/metrics` → `raft_heartbeat_rtt_us` (mean = `_sum/_count`). Leader↔follower round-trip incl. pump-loop latency on both ends. |
| **pause / jitter tail** | the real *low-end* — election timeout must clear the LONGEST "leader alive but heartbeat landed late" gap | fsync tail (`fio`, or instrument `wal.flush`), scheduler latency (`cyclictest`), and *empirically*: run load and watch `raft_leadership_acquisitions_total` for any rise. No GC (Zig), so fsync + scheduler preemption dominate. |
| **MTBF / failover SLO** | the *ceiling* — election timeout ≈ leaderless window on a real crash | `leader_failover_smoke_v2`'s `ELECTION_FAILOVER_S`. 3 dedicated bare-metal nodes ⇒ MTBF months ⇒ the ceiling is loose; the binding constraint is the pause tail on the low end. |

### Compose (with margin)

- `heartbeat ≈ 3–5 × p99(broadcastTime)` — a few RTTs of slack.
- `electionTimeout ≈ max( 10 × heartbeat, p999(pause tail) × 2–3 )` — it must
  satisfy **both** the industry 10:1 ratio **and** clear the measured pause tail.
- Keep raft's `[T, 2T]` randomization; make sure lockstep `tickGroups` doesn't
  collapse it (the thundering-herd note above).

Today's defaults violate both guides: the ratio is `10:3 ≈ 3.3:1` (vs the 5:1
raft-rs / 10:1 etcd norm), and ~15ms sits inside a realistic fsync/scheduler
tail. That's the case for widening — see the soak result.

### Validate empirically — the soak (`scripts/smoke/raft_soak_v2.py`)

The number is only *justified* by zero spurious elections under load. The soak is
meaningful only if three things hold (it enforces all three):

1. **WAL on real disk, not tmpfs.** `/tmp` is tmpfs (RAM) on our dev boxes, so
   the WAL fsync is a no-op and a too-tight timeout *cannot* flake — fsync stalls
   are the dominant trigger. The soak forces `V2_SMOKE_DATA_BASE` onto real disk
   and **refuses to run on tmpfs**. (This silently invalidated the first runs —
   always confirm `SOAK_WAL_FSTYPE`.)
2. **Realistic, uncapped load.** h2load through the *front door* against the real
   handler write path (front → worker → JS `kv.set` → propose → commit), with the
   tenant plan raised to effectively-unlimited so it isn't rate-throttled. (The
   single-threaded front saturates past ~64 concurrent streams → 5xx; ~32, i.e.
   `RAFT_SOAK_CLIENTS=8 RAFT_SOAK_STREAMS=4`, maximizes clean throughput.)
3. **Counts spurious elections** = `raft_leadership_acquisitions_total` delta
   beyond the one-per-group formation baseline. Correctly sized ⇒ **0**.

Run at the candidate tick, then wider, and compare:

    REWIND_RAFT_TICK_MS=10 RAFT_SOAK_SECONDS=3600 python3 scripts/smoke/raft_soak_v2.py

### Measured baseline + recommendation

Dev box (btrfs/NVMe, ~2750 req/s real writes, 90s): **broadcastTime ≈ 2ms; ZERO
spurious elections at BOTH the default ~15–20ms timeout AND
`REWIND_RAFT_TICK_MS=10` (~100–300ms), at identical throughput.** So widening to
the etcd / Raft-paper band is *free* here and buys pause-tail margin.

→ **Recommendation: set `REWIND_RAFT_TICK_MS=10` in prod** (election ≈ 100–300ms,
heartbeat ≈ 30ms — the industry band), then run a *multi-hour* soak on the actual
BHS hardware before locking it. Caveats on the dev result: single box (all 3
nodes + the load generator share one CPU = *more* scheduler contention than the
3-machine BHS cluster — so clean here is weak evidence it's clean there, but not
the real topology); 90s is short (the pause tail is a rare-event distribution —
soak hours for a production decision); throughput is front-bound, not
cluster-bound.

### Industry reference (for calibration)

| System | Heartbeat | Election timeout |
|---|---|---|
| Raft paper (Ongaro/Ousterhout) | RTT (0.5–20ms) | 150–300ms |
| etcd | 100ms | 1000ms |
| HashiCorp raft (Consul/Nomad/Vault) | 1000ms | 1000ms (+500ms leader lease) |
| TiKV (raft-rs — same engine) | ~2s | ~10s |
| MongoDB | 2s | 10s |
| **rove (today, default tick)** | **~3ms** | **~15–20ms** |

The rule every implementation encodes: **heartbeat ≈ network RTT; election ≈ 10×
heartbeat; both ≫ broadcastTime and ≪ MTBF.** rove is currently an order of
magnitude tighter than the tightest mainstream default on *both* the absolute
value and the ratio — defensible only on a dedicated sub-ms LAN, and the reason
to move toward `REWIND_RAFT_TICK_MS=10`.

## Blocked on NEW FFI methods (need extern "C" fns in the fork)

These are `RawNode` methods, not config. Each needs: a Rust
`raft_manager_*` extern fn in `raft-sys/src/lib.rs`, a Zig wrapper in
`manager.zig`, a re-pin, and usually a bridge accessor + worker/front wiring.
Listed by value. (`transfer_leader` was #1 here and is now **Done** above — it
is the worked example of the full FFI-method → re-pin → wiring path.)

1. **`read_index` — ReadIndex / LeaseBased linearizable reads. CONSCIOUSLY NOT
   DONE** (decided 2026-06-16). Keeping the analysis so nobody re-derives it.

   **The residual gap is exactly one code path.** A read-bearing activation
   resolves three ways in `worker_dispatch.zig`'s `finalizeBatch`:
   - **Handler writes** → `proposeBatch` + park; the response releases only when
     `committedSeq` passes the seq (`drainRaftPending`), 421 on fault.
     Linearized through the log.
   - **Read-only, but a read crossed an uncommitted speculative overlay**
     (`txn.sawSpeculation()`) → the **idiom-0 barrier**: an empty-writeset
     propose + park, released only on commit. Also linearized through the log.
   - **Clean read-only batch** (`saw_speculation == false`) → *"no raft hop"*:
     the txn splices out locally and the response releases from local applied
     state.

   read_index would only ever touch the **third** path — the one read that
   returns without any raft round-trip. The first two already wait for a commit;
   note the idiom-0 barrier gives *read-your-writes* (vs this node's own
   uncommitted chain), which is **orthogonal** to cross-cluster freshness — a
   stale read of another node's newer commit has no local speculation to trip
   it.

   **What the gap actually is** — a partition-window *stale* read, never a lost
   write. Partition `{A} | {B,C}`: C+B form the new majority and commit W′,
   W″…; deposed-but-not-yet-stepped-down A (still passing the local-role
   dispatch-gate) serves a clean read missing W′. The *opposite* direction — A
   returns a read of a "committed" write that then vanishes — **cannot happen**:
   raft Leader Completeness guarantees a quorum-committed entry survives every
   future election (any new leader needs a vote from a node that holds it, and
   the vote restriction forbids electing a less-complete log), and the fork
   already counts an entry toward the commit quorum only after its fsync
   (`584122a` + the `advance_append_async`/`on_persist` split). So the only
   exposure is bounded staleness on clean reads, gated by all of: an active
   partition, a client that reaches minority-side A but not the majority, and A
   still inside its pre-step-down window. `check_quorum` ends it within ~one
   election timeout (A stops hearing a quorum → steps down → dispatch-gate flips
   to 421).

   **Why not close it.** Only **Safe** mode would eliminate the window — a
   heartbeat-quorum round-trip *at read time*, so minority-side A can't confirm
   and the read becomes a re-aim instead of a stale value. That is a quorum RTT
   on the **common** clean-read path. **LeaseBased buys ~nothing**: its lease
   expires on missed heartbeat rounds, i.e. the same ~election-timeout bound
   check_quorum already gives, plus a clock-drift assumption. So the choice is
   binary — tax every clean read to close a partition-only, time-bounded,
   isolated-client staleness window, or accept the check_quorum bound. We accept
   the bound; bounded staleness on clean reads during a partition is a mild,
   conventional anomaly and not worth a per-read round-trip.

   **If the contract ever needs strict-linearizable clean reads:** build
   `RawNode::read_index(rctx)` → surface `ready.read_states()` in
   `process_ready` (a `ReadState{index, ctx}` keyed by a unique ctx) → a bridge
   confirm/poll control-cmd → wire it **only** into the third path above (the
   `saw_speculation == false` branch): request a read index, serve once
   `applied >= index`, else 421 if leadership can't be confirmed. Use **Safe**
   mode (LeaseBased is not worth the clock assumption for no real gain). Cost is
   a quorum heartbeat round per clean read (batchable across concurrent reads on
   a group).

2. **`request_snapshot` — not needed.** rove does NOT use raft's in-protocol
   snapshot transport for catch-up: existing voters catch up from the log
   (lockstep min-match compaction never truncates past a voter), and a genuinely
   new member bootstraps out-of-band (above). So neither the follower-initiated
   pull nor the leader-driven `MsgSnapshot` path is wired — by design. An earlier
   in-raft snapshot implementation was built then removed in favour of this
   simpler model (it put a store dump on the leader's serving hot path).

3. **`report_unreachable` / `report_snapshot`** — let the leader back off a
   dead/slow follower's send loop instead of spinning. Quality-of-implementation
   for degraded clusters.

4. **`leader_id` accessor** — would let a 421 carry an explicit leader hint.
   NOT needed: the front-side `LeaderCache` learns the leader from
   421→success without it. Listed only so nobody re-derives the need.

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
  (`443c592..f607513`). Any future FFI change branches
  from fork `main` and re-pins likewise.

## Open follow-ups (low priority)

### `check_quorum` self-step-down double-election on leader death

`scripts/smoke/leader_failover_smoke_v2.py` asserts a CLEAN single re-election after a
SIGKILL of the leader: exactly one survivor's `raft_leadership_acquisitions_total`
rises, by exactly 1. It is intermittently RED, and that flakiness is a deliberate
signal — **left in place, not hardened** — because it surfaces real failover
behavior. Characterized 2026-06-17 (15-run samples):

| tick (`REWIND_RAFT_TICK_MS`) | flake rate | shapes |
|---|---|---|
| 1ms (smoke default), pre-arc baseline `222ef0b` | 9/15 (60%) | both |
| 1ms, branch `feat/high-churn-learner` | 5/15 (33%) | both |
| **10ms (production-realistic)** | **2/15 (13%)** | only `(X,2.0)` |

Two distinct mechanisms; the realistic-tick run separated them:

1. **Dueling candidates** (`bumped=[(a,1),(b,1)]`, leadership bounces between the
   two survivors). Their randomized election timeouts collided. The randomization
   window is `election_tick × tick`, so a 1ms tick gives a ~10ms spread vs ~100ms
   at 10ms. **Eliminated entirely at the realistic tick** — a pure artifact of the
   smoke's compressed clock.
2. **`check_quorum` self-step-down** (`bumped=[(X,2.0)]`, one node wins, steps
   *itself* down, re-wins, the other never leads). A freshly-elected leader that
   can't confirm quorum contact within its first election-timeout window demotes
   itself; with one of three voters SIGKILL'd it hangs on the single surviving
   peer's contact, and a brief lapse trips it. **Persists at ~13% even at 10ms.**
   Hypothesis to investigate: the new leader's first quorum window fails because
   the old leader's abrupt death churns the transport (raft-net) — the surviving
   peer's contact is briefly delayed during reconnect. A longer first-heartbeat
   grace, or warming the surviving-peer link, may close it.

**Safety is never violated** — every failing run passes all data checks, including
a post-failover write committed + replicated to both survivors. This is a liveness
hiccup only (an extra ~150ms election), data-safe, and **pre-existing** (the
pre-arc baseline flakes harder than the current branch, so the snapshot-catch-up /
mechanism-A work neither caused nor worsened it). Low priority; recovery stays
fast. Do NOT "fix" by relaxing the assertion — the point is the watchdog.

## Pointers

- Strict-serializable read design + the eventual→strict reasoning: the
  `raft-config-ffi` merge commit and its 4 feature commits (`pre_vote`,
  `dispatch-gate`, `leader-hint`, `check_quorum`).
- Effect model / consistency framing: `docs/effect-algebra.md`,
  `docs/architecture/consensus-and-storage.md`.
- Locked decisions: `docs/decisions.md` §10 (V2 multi-raft).
