# V2 Phase 6 — scale: hibernation / active-set (K = thousands of tenants)

> **Status (2026-06-04). Core DONE.** The active-set hibernation machinery
> is in `src-v2/kv/node.zig` + `src-v2/kv/transport.zig`, green under
> `v2-test` (46/46). An idle group drops out of the tick set and costs the
> pump nothing; it wakes on the next propose / non-heartbeat step. Proven by
> three tests: single-node hibernate→wake, a K-group idle drain, and the
> load-bearing one — a 3-node group hibernates with **no spurious leader
> change** and a propose wakes it + replicates. The full K=10k macrobench is
> a noted follow-up (needs a cluster bench harness; the unit tests prove the
> mechanism + the multi-node correctness).
> Spec: [`v2-build-order.md`](v2-build-order.md) §Phase 6;
> [`v2-multiraft-scaling-learnings.md`](v2-multiraft-scaling-learnings.md)
> §3.1 (the finding this implements).

## Why Phase 6

With one raft group per tenant, every group exchanges heartbeats at tick
rate to stay live. Naively ticking **every** created group every pump cycle
is O(all tenants) per cycle — and the heartbeat traffic itself keeps every
group's "active" timer alive, a self-feeding loop. At K = thousands of
mostly-idle tenants that buries the pump (learnings §3.1 measured the pre-V2
prototype at 4 cycles/sec, 238 ms/cycle, ~68% of routed messages
heartbeats). The fix is hibernation: tick only a small **active set**, and
do not let a group's own keep-alive traffic keep it there.

`tickAll` is fine at K ≤ ~1k, but V2's target *is* thousands, so it is built
in now.

## The mechanism

A group is in the **active set** (`Node.active`) iff it has had real work
recently. The pump ticks only the active set; `pollReady`/`processReady`
still serve any group that has pending work (a stepped-in message makes a
group ready without a tick), so a hibernated group still *responds* — it
just isn't *driven*.

- **`bumpActive(gid)`** (`node.zig`) refreshes a per-slot wall-clock
  deadline (`active_until_ns = now + hibernate_ns`) and adds the group to
  the active set if absent. Called on:
  - **a propose** (`node.propose`) — bump *before* `mgr.propose` so even a
    propose raft-rs rejects (non-leader) re-ticks the group toward an
    election;
  - **formation** (`createGroupCore`) — a fresh group must tick to elect
    (multi-node) / campaign-to-leader (single-node);
  - **a non-heartbeat inbound step** — see the transport below.
- **`sweepHibernated(now)`** runs once per pump cycle and drops every group
  past its deadline. Not pre-seeded: an idle group is simply never bumped,
  so it ages out and the pump cost is **O(active)**, not O(all groups).
- **`hibernate_ns`** defaults to 2 s (`DEFAULT_HIBERNATE_NS`); tests set a
  short value to observe the transitions fast.

### Heartbeats must not wake — the load-bearing rule

The transport (`transport.zig`) detects heartbeat-like messages at the
eraftpb wire-byte level (`isHeartbeatLike`: `msg_type` is field 1, a varint,
so `[0x08][8|9]` = `MsgHeartbeat` / `MsgHeartbeatResponse`; codec-independent
under protobuf or prost). In `onRecv` it records the gids that received a
**non-heartbeat** message into a `woke` list; the pump drains it each cycle
(`drainWoke`) and `bumpActive`s each. So real raft traffic (votes,
AppendEntries, proposes) wakes a group, but a quiet group's own heartbeats
do not — "a heartbeat means *don't elect me*, not *I have work*."

## Why hibernation does not break consensus (the correctness argument)

Stopping ticking a group freezes **all** its raft timers — the leader's
heartbeat timer and the followers' election timers alike. The only risk is a
follower whose election timer fires in the window between the leader going
silent and the follower hibernating. That window stays closed because:

1. Every node counts a group's hibernate deadline from the last **real**
   message (an AppendEntries / vote), which all nodes see within network
   jitter — so they hibernate the group within jitter of each other, far
   under the election timeout.
2. The leader keeps heartbeating right up until **it** hibernates, and each
   heartbeat resets the followers' raft election timers — so at the moment a
   follower stops ticking, its election timer has a full election-timeout of
   runway and is then frozen.

What matters is the *skew* between nodes hibernating the same group
(≈ jitter), **not** the absolute `hibernate_ns` — so a generous window is
safe; it just avoids re-waking a barely-idle group. A propose or a
non-heartbeat step wakes the group cluster-wide; the leader's term was
frozen, not lost, so no re-election is needed on wake.

**Tradeoff (intended):** a fully-idle group whose leader dies does **not**
auto-re-elect — there is no traffic to notice. The next request wakes the
group (the front door's leader-aware retry sends a propose, which bumps the
group active → it ticks → campaigns) and recovery proceeds, exactly the
"faulted + retried" posture the rest of V2 already uses. An idle group has
nothing to serve, so this costs nothing real.

## Tests (`node.zig`)

- **single-node hibernate→wake:** a written group is active; after idling
  past `hibernate_ns` it leaves the active set (pump stops ticking it); a
  new propose re-wakes it and commits (still leader — the term was frozen).
- **K-group drain:** 80 tenants each take a write; after an idle window the
  active set drains to **0** while all 80 groups still exist + read back —
  the O(active) property at scale. (No peak-count assertion: the earliest
  groups already age out before the last is created — that *is* the
  mechanism.)
- **3-node no-disruption (load-bearing):** a formed + elected group idles
  past the window on all three nodes; the active sets empty, **leadership is
  unchanged** (the original leader still leads, no one else campaigned), and
  a propose then wakes the group + replicates to every node with no
  re-election.

## Follow-ups (not Phase-6-core blockers)

- **K=10k macrobench.** The build-order exit calls for "thousands of
  mostly-idle tenants do not burn the pump (cycle time stays low); a
  K-tenant bench." The unit tests prove the mechanism + multi-node
  correctness; a cluster-scale `h2load`/`smoke_lib` macrobench over
  thousands of tenants (per
  [`reference_bench_harness_direction`]) quantifies the cycle-time win and
  belongs with the other cluster macrobenches.
- **Hibernation deadline as a config knob.** `hibernate_ns` is a per-`Node`
  field today (env-overridable wiring in `rewind` if operations ever needs
  it); left at the 2 s default.
