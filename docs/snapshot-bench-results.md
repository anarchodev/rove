# Snapshot scalability — bench results

> Run via `scripts/snapshot_scalability_bench.sh` against a 3-node
> loop46 cluster with `BLOB_BACKEND=s3` (OVH us-west-or). Two
> distinct architecture states recorded here: the pre-#1.1 byte-
> capture model and the post-#1.1 stamp-and-compact model.

## Pre-#1.1: byte-capture model (2026-05-10, before redesign)

The original `tickRaftCapture` did per-tenant `VACUUM INTO` + sha256
+ S3 PUT + manifest serialize on every snapshot interval, on the
raft thread. For any non-trivial cluster the pass took longer than
the willemt election timeout (~250ms default), starving heartbeats
and triggering leadership flap.

`N_total=100, N_active=10`:

```
avg vacuumed/pass        8 (across 4 steady passes)
avg reused/pass          92
avg pass duration        1592ms (max 2059ms)
steady-state apply tput  4/s
raft.log.db              4096 bytes (0 rows)
```

`N_total=100, N_active=100` (every tenant active):

```
each node captured exactly once before losing leadership
all captures showed reused=0 (cold-start cache always discarded
by safety guard — prior leader's floor past new leader's apply)
duration_ms 8-13 seconds per pass
steady-state never reached
```

By-reference reuse worked when the leader was stable long enough
to land multiple captures (the 100/10 case), but the operational
ceiling was ~5 active tenants per pass before heartbeats started
timing out. Documented as production.md #1.1 (heartbeat
starvation).

## Post-#1.1: stamp-and-compact model (2026-05-10, current)

`tickRaftCapture` now does only `_apply_state[T] = commit_idx` for
every tenant T plus willemt begin/end + incremental_vacuum. No S3,
no VACUUM INTO, no manifest. Pass duration scales with tenant
count at ~30µs per tenant (one prepared-statement step per tenant
in WAL mode + auto-commit fsync).

`N_total=100, N_active=10`:

```
avg stamped tenants/tick    100 (across 11 steady ticks)
avg tick duration           2ms (max 3ms)
steady-state apply tput     2/s
raft.log.db                 4096 bytes (0 rows)
dormant _apply_state        141 (refreshed every tick; always-refresh-all)
```

`N_total=100, N_active=100`:

```
avg stamped tenants/tick    100 (across 11 steady ticks)
avg tick duration           3ms (max 3ms)
raft.log.db                 4096 bytes (0 rows)
dormant _apply_state        152
```

`N_total=1000, N_active=100`:

```
avg stamped tenants/tick    1000 (across 5 steady ticks)
avg tick duration           29ms (max 40ms)
raft.log.db                 24576 bytes (1 row)
dormant _apply_state        1013 (refreshed even though never written)
```

## Observations

- **Heartbeat starvation eliminated.** Even at 1000 tenants the
  pass takes ~30ms — well under the willemt election timeout
  (~250ms default). The cluster never sees the leader pause long
  enough to trigger an election. Scaling headroom: at the
  observed ~30µs/tenant rate, ~5000 tenants fits in 200ms before
  approaching heartbeat budget.
- **Always-refresh-all property holds.** Dormant tenants
  (warmed up once, never touched again) get their `_apply_state`
  bumped every tick. Bench checks `t<N_total-1>` (the
  furthest-from-active tenant) and confirms its stamp advances
  past the most recent tick's `apply_position`.
- **Compaction is bounded.** raft.log.db stays at 4-24 KB
  (a couple of pages) regardless of commit volume. willemt's
  `cbLogPoll` chain runs after every successful end_snapshot;
  `incremental_vacuum` returns freed pages to the filesystem.
- **Throughput unchanged.** The bench's release-POST workload is
  bottlenecked by S3-fetch-on-failed-deployment-reload (each
  release POST tries to fetch a manifest that doesn't exist),
  not by snapshot work. ~2/s commit rate is a property of the
  bench, not of the snapshot path.

## What about reuse / S3 / DR backups?

Per `docs/production.md` #1.1: **none of these are in the
periodic loop anymore.**

- The `capture()` function (full VACUUM-INTO + S3 PUT + manifest
  with by-reference reuse) is still shipped — used by the
  operator-on-demand `loop46 snapshot` CLI. The bench doesn't
  exercise that path.
- DR is handled by `#1.2` (non-voting learner replica), not by
  periodic S3 backups. There is no periodic S3 backup loop in
  the new architecture.

## How to reproduce

```bash
zig build install

# 100 tenants, 10 active, 20s steady. Verifies the basic
# stamp-and-compact contract.
STEADY_S=20 N_TOTAL=100 N_ACTIVE=10 SNAPSHOT_INTERVAL_MS=2000 \
  bash scripts/snapshot_scalability_bench.sh

# 1000 tenants. Confirms tick duration scales linearly with
# tenant count and stays under heartbeat budget.
STEADY_S=30 N_TOTAL=1000 N_ACTIVE=100 SNAPSHOT_INTERVAL_MS=3000 \
  POST_WARMUP_SETTLE_S=10 \
  bash scripts/snapshot_scalability_bench.sh
```

`.env` (repo root) must carry the `AWS_*` / `S3_*` env vars for
the cluster to boot — they're used by the standalones' BlobBackend
even though the snapshot path itself no longer touches S3.
