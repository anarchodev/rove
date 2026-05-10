# Snapshot scalability — initial bench results

> **2026-05-10 first pass.** Run via `scripts/snapshot_scalability_bench.sh`
> against a 3-node loop46 cluster with `BLOB_BACKEND=s3` (OVH us-west-or,
> ~30-100ms RTT). Findings below split into "design works as intended"
> and "operational issues that surface at scale."

## What works (100 tenant cluster, modest activity)

`N_total=100, N_active=10, STEADY_S=20, SNAPSHOT_INTERVAL_MS=3000`:

```
avg vacuumed/pass        8 (across 4 steady passes)
avg reused/pass          92
avg pass duration        1592ms (max 2059ms)
steady-state apply tput  88 commits (4/s)
raft.log.db steady-state 4096 bytes (0 rows)
```

Reuse rate matches the design exactly: `vacuumed ≈ N_active`,
`reused ≈ N_total - N_active`. Always-refresh-all property holds
(both vacuumed + reused entries get `snapshot_idx = current
apply_position`). Pass duration is dominated by S3 PUTs for the
fresh tenants; reused entries are pure manifest bookkeeping
in-memory.

`N_total=100, N_active=100` (every tenant active):

```
avg vacuumed/pass        30 (single pass observed)
avg reused/pass          71
duration_ms              6406ms
```

`vacuumed=30` < `N_active=100` because in 20s of bench load with
~4 commits/s only ~80 commits land, distributed across the 100
tenants — so only ~30 tenants actually advanced past the prior
snapshot's idx between captures. Behavior is correct: any tenant
not touched between two captures is reused.

## What breaks at scale (≥100 active tenants OR slow S3)

**The snapshot capture pass runs on the raft thread.** While
the pass is in flight (5-10s wall-clock for 100 tenants × S3
PUTs at ~50ms each), willemt's heartbeat tick doesn't fire.
Followers see no heartbeats for 5-10s, time out their election
window (~200-500ms), and start elections. The current leader
steps down on the next tick. New leader takes over, fires its
own capture (with cold-start cache discarded as a different
cluster-lifetime), captures once, loses leadership again. The
result is a captures-per-node count of 1 across runs — the
cluster never reaches steady-state under the bench load.

Worker logs (from a 100-tenant run with no warmup acceleration):

```
node 0: snapshot captured ... vacuumed=46 reused=0 duration_ms=8732
node 1: snapshot captured ... vacuumed=46 reused=0 duration_ms=12875
node 2: snapshot captured ... vacuumed=47 reused=0 duration_ms=10399
```

Each node captured exactly once. `reused=0` because each new
leader's primed cache was discarded by the safety guard
(`prev.willemt_compaction_floor > current apply_position`) —
the prior leader's snapshot floor was past where this leader had
applied to, so reuse couldn't be safe.

**Two coupled issues** show up here:

1. **Capture pass blocks heartbeats.** The fix is to move the
   capture to a dedicated thread (or batch it across multiple
   raft thread ticks with explicit yield points). Same shape as
   how the cold-start LIST got moved out of the raft thread in
   the previous session — but for the capture itself.

2. **Cold-start safety guard rejects mid-leadership-change
   manifests.** When leadership flaps at the rate of one capture
   per leader tenure, the cache always points at the prior
   leader's last manifest, whose `floor` is past where the new
   leader has applied to. Guard discards → no reuse → next
   capture is full-cost again → blocks heartbeats again →
   leader changes again. Self-reinforcing.

The fix for (1) also fixes (2): with capture off the raft
thread, leadership doesn't flap, the same leader produces many
captures, prev_manifest stays valid, reuse fires. Steady-state
cost drops to `O(N_active × S3_PUT)` as designed.

## Operational ceiling on the current code

For a cluster with average S3 RTT R ms and per-tenant capture
work T ms (VACUUM INTO + sha + PUT ≈ 50ms baseline):

```
max_safe_active_tenants ≈ election_timeout_ms / (R + T)
                       ≈ 200ms / 50ms
                       ≈ 4 active tenants per pass
```

With `R + T = 100ms` and `election_timeout = 250ms` (the
bench's `RAFT_TIMING_FLAGS`), the safe ceiling is **2-3
fresh-VACUUM tenants per capture pass before leadership flaps**.

By-reference reuse pushes the cost per pass from `O(N_total ×
50ms)` to `O(N_active × 50ms)` — for the operational ceiling
to be useful, we still need `N_active < ~5` per pass on
default election timeouts.

## What this means for #2's checkmark

The by-reference reuse design + implementation are correct
(verified at 100/10 scale where reuse fires cleanly). But the
**operational ceiling for periodic snapshots is bounded by the
heartbeat starvation problem**, not the manifest cost. Unblocking
real-world density (1000s of tenants, 100s active) requires
moving the capture off the raft thread.

Filed as a new item in `docs/production.md` (#1.1 snapshot
thread).

## How to reproduce

```bash
zig build install

# Confirms the "reuse works" property at small scale.
STEADY_S=30 N_TOTAL=100 N_ACTIVE=10 \
  bash scripts/snapshot_scalability_bench.sh

# Demonstrates the heartbeat starvation problem:
#   each capture takes ≥5s, leadership flaps, 1 capture per node.
STEADY_S=60 N_TOTAL=1000 N_ACTIVE=100 \
  SNAPSHOT_INTERVAL_MS=10000 POST_WARMUP_SETTLE_S=30 \
  bash scripts/snapshot_scalability_bench.sh
```

`.env` must carry `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
/ `S3_BUCKET` / `S3_ENDPOINT` / `S3_REGION` for the snapshot
store and the standalones' BlobBackend.
