# Production readiness — what's left

> **2026-05-09 punch list.** What's left to ship a multi-node loop46
> cluster running the four binaries (`loop46`, `files-server-standalone`,
> `log-server-standalone`, `sse-server-standalone`) under sustained
> production traffic with full raft. Ordered by "actually blocks
> prod" vs "nice to have."
>
> Read alongside [`PLAN.md`](PLAN.md) §13 (live process map) and
> [`phase-5.5-rollout.md`](phase-5.5-rollout.md) (Phase 5.5 status).

## Hard blockers — without these, the cluster won't survive sustained traffic

### 1. Phase 5.5(c) finish: raft log compaction wiring — **done 2026-05-09**

> **Follow-up surfaced 2026-05-10**: see #1.1 below — the capture
> pass blocks willemt heartbeats and triggers leadership flapping
> at any scale where the pass takes longer than the election
> timeout. Filed as a separate item; the compaction wiring itself
> is done.



The willemt `raft_begin_snapshot` / `raft_end_snapshot` bracket was
already wired around `tickRaftCapture` (so willemt's `cbLogPoll`
chain DELETEs compacted log entries). What was missing: the
SQLite-level `auto_vacuum=INCREMENTAL` setting + a periodic
`PRAGMA incremental_vacuum` call to actually return the freed pages
to the filesystem. Without those, the row count was bounded but the
file size grew forever.

Shipped:
- `pinAutoVacuum` enforces `auto_vacuum=INCREMENTAL` at
  `RaftLog.open` time, before any other PRAGMA that allocates a
  page. Pre-existing databases with `auto_vacuum=NONE` surface
  `Error.AutoVacuumMode` so operators run a one-shot `VACUUM` to
  migrate (rather than a silent multi-second VACUUM at startup).
- `RaftLog.compactPages(max_pages)` wraps `PRAGMA incremental_vacuum`.
- `RaftNode.compactLogPages()` calls it from the raft thread.
- `tickRaftCapture` calls `compactLogPages()` after each successful
  `endSnapshotOpaque()`.
- `scripts/snapshot_smoke.sh` asserts `raft_log` row count + file
  size are bounded after 120 commits + 4 snapshot passes (was
  unbounded before).

### 1.1 Move snapshot capture off the raft thread — **NEW, surfaced 2026-05-10**

The per-tenant VACUUM INTO + S3 PUT + manifest serialize work
in `tickRaftCapture` runs synchronously on the raft thread.
For any non-trivial cluster (≥10 active tenants on commodity
S3, or much more under faster local-fs backends) the pass
takes longer than the willemt election timeout (default
250ms). During that window willemt's heartbeat tick can't
fire, followers time out, and the leader steps down mid-
capture. The new leader takes over, captures once, loses
leadership again — a self-reinforcing flap.

Symptom: `scripts/snapshot_scalability_bench.sh` at
`N_total=100, N_active=100` shows each node capturing exactly
once with `reused=0` (cold-start cache always discarded by the
safety guard because the prior leader's `floor` is past where
the new leader has applied to). Steady-state never reached.

Detail in `docs/snapshot-bench-results.md`.

Fix shape: dedicated snapshot thread that takes a "begin
snapshot" handoff from the raft thread, does VACUUM + S3 work
independently, signals "end snapshot" back to the raft thread
which then drives `endSnapshotOpaque()` + log compaction.
Pattern: same separation we already use for `flushLogs` (it
runs on a dedicated `flusherLoop` thread inside `Worker.create`
specifically because S3 PUTs would block the dispatch hot path).

Cost: ~1-2 days of work. Risk: medium — the raft thread already
hands off through atomics for the apply-side wakeup, so adding
one more channel is well-trodden ground; but the begin/end
bracket invariants need careful preservation.

**Blocks production at any density above ~5 active tenants per
snapshot interval** with default raft timing flags + S3 latency.

### 2. By-reference manifest reuse for unchanged tenants — **done 2026-05-09 (with leader-snapshot fix)**

Naive per-pass capture re-VACUUMed every tenant regardless of
activity, paying full CPU + S3 PUT cost proportional to *total*
tenants rather than *active* tenants. The
always-refresh-all-tenants trick (`docs/snapshot-plan.md` §2.2)
fixes both halves of that — keeps the willemt compaction floor
advancing every pass while making the per-pass work proportional
to recent activity.

Shipped:
- `TenantSource.last_applied_idx` (optional) lets capture compare
  the current high-water mark against the prior snapshot's
  `snapshot_idx`. When `last_applied_idx <= prev.snapshot_idx`,
  capture reuses the prior `db_key` / `db_sha256` / `db_size`
  by reference (just bumping `snapshot_idx` to the current
  `apply_position`). The bytes are byte-identical because no
  apply touched the tenant, so referencing the same S3 object
  is correct.
- Same property for `__root__.db` via `root_last_applied`.
- `tenantSourcesFromApplyCtx` populates `last_applied_idx` from
  `ApplyCtx.tenantLastApplied` so the periodic capture loop
  picks up the reuse path automatically.
- `RaftCaptureState.last_manifest` caches the most-recent
  successful capture's manifest; threaded as `prev_manifest`
  into the next tick.
- `loadLatestPriorManifest` cold-start path lists the snapshot
  store on the first tick after worker boot so the in-memory
  cache primes from S3 even before the leader has captured
  anything itself. **Safety guarded** by checking
  `prev.willemt_compaction_floor <= apply_position` — refuses
  manifests from later cluster lifetimes (operator wiped
  data_dir, partial replay) so reuse can't silently substitute
  stale tenant bytes for an empty fresh state.
- Operator CLI (`loop46 snapshot --data-dir ...`) keeps the
  always-re-VACUUM path; one-shot DR captures don't have an
  in-memory `tenant_apply_idx` to compare against.
- Two inline tests cover the contract: (a) two consecutive
  captures with one tenant changed → only that tenant gets a
  fresh `db_key`, the other reuses; (b) prev_manifest with a
  different tenant set → new tenant captured fresh, old entry
  not carried forward.
- `scripts/snapshot_smoke.sh` adds a `quiet` tenant that's
  written once and then never again; subsequent captures
  exercise the reuse path. The S3-listing assertion (filtered
  to **this run's** snap_ids so accumulated history doesn't
  pollute the count) verifies exactly one fresh `quiet/app.db`
  is uploaded across all capture passes — the rest reuse it
  by reference.

**Leader-snapshot bug fixed in the same change.** The
pre-existing `applyWriteSet` leader-skip returned before
populating `apply_ctx.kv_stores` or `tenant_apply_idx`, so the
leader (which is the only node that runs the periodic capture
loop) produced empty manifests every pass. Smoke passed
historically because it only counted "snapshot captured" log
lines, not manifest contents. Fix: the leader path now records
`(tenant_id, idx)` in memory via a new `markTenantApplied`
helper (no SQLite I/O — keeps a second writer off the same
app.db file, preserving worker throughput). The on-disk
`_apply_state` stamp + the kv_store open are deferred to
`tickRaftCapture`, paid once per snapshot pass instead of
per-apply.

**Cold-start path also restructured.** `loadLatestPriorManifest`
LISTs the snapshot store + GETs the most recent manifest to
seed the reuse cache at worker boot. Originally fired inside
`tickRaftCapture` from the raft thread — but the multi-second
LIST against a populated bucket starved willemt of tick time
and triggered heartbeat timeouts (one capture per smoke run
instead of five). Moved to `primeFromSnapshotStore`, called
from `main.zig` before the raft thread spawns. Safety guard
(refuse manifests with `floor > current apply_position`)
stays in `tickRaftCapture` as a cheap u64 compare against
the cached state.

### 3. Far-behind-follower auto-restore

`loop46 restore-from-snapshot` exists as an operator CLI. The
willemt `needs_snapshot` callback currently just logs. Wiring
auto-fetch + atomic-rename when a follower is too far behind is
needed for nodes added after first capture and for crash recovery
without operator hand-holding.

## Operational gaps

### 4. Operator deployment story for the four binaries

`scripts/rove-loop46-serve.sh` + `scripts/systemd/` exist for the
loop46 binary. Production also needs systemd units (or equivalent)
for `files-server-standalone`, `log-server-standalone`,
`sse-server-standalone`, with the right env wiring
(`LOOP46_SERVICES_JWT_SECRET`, `SSE_INTERNAL_TOKEN`,
`BLOB_BACKEND`, S3 creds). Today this is implicit —
`scripts/dev_serve.sh` fork-execs them for dev; production needs
documented unit files + a deployment doc.

### 5. TLS reload across all four processes

`loop46` reloads cert/key on mtime change every second. The
standalones need the same, since the wildcard cert covers
`files.` / `logs.` / `sse.` subdomains and they each terminate
their own TLS. Worth confirming each standalone reloads.

### 6. Edge proxy requirement documented + verified

Per [`http-send-plan.md`](http-send-plan.md) §3.1, production needs an
edge proxy (Cloudflare / ALB / nginx) handling HTTP/1.x ↔ h2 —
rove-h2 is h2-only and 426s plain HTTP/1.x. Need a deployment doc
+ a startup warning when no proxy is detected (today there's no
warning).

### 7. Multi-node smoke covering leader failover

`scripts/snapshot_smoke.sh` covers capture/restore. The
notification + cluster smokes are close but don't specifically
exercise leader flip during in-flight schedule fires. Need a smoke
that exercises:

- Leader change with `http.send` rows in flight (validates the
  at-least-once + version-counter dedup contract in
  [`http-send-plan.md`](http-send-plan.md) §7).
- New leader picking up `schedules.db` rows the old leader was
  firing.
- sse-server failover triggering `rove:resync` correctly.

### 8. Backup automation

Snapshot CLI exists; no cron-driven invocation, no retention
policy enforcement, no operator runbook for "S3 snapshot directory
got too big" or "I need to restore from yesterday's snapshot to a
fresh cluster."

## Quality-of-life / risk tightening

### 9. Raft-replicated `inflight_until_ns` lease on schedule rows

Today it's in-memory per leader; double-fire window during leader
change is wider than necessary.
[`http-send-plan.md`](http-send-plan.md) §7 lists this as a v2
candidate (~5-15ms extra propose per fire — batched amortization
makes it cheaper). Not a blocker since at-least-once is the
contract, but tightens the duplicate-delivery rate.

### 10. Cross-process metrics + health

sse-server has `/v1/health`. Workers, files-server, log-server,
schedule-server thread don't. `analytics.track` / `metrics.*` are
deferred per PLAN §10.15, but operational metrics (worker tick
latency, raft lag, schedule queue depth, S3 PUT error rate) want a
Prometheus-shaped surface for alerting.

### 11. Phase 9 encryption at rest

Locked in PLAN but conditioned on "if B2B compliance demand
surfaces" per §10.16. Not technically a prerequisite for
"production running" — depends on the compliance bar of the first
production customer. The vendored AES-GCM SQLite VFS vs SQLCipher
decision (PLAN §5) is still open.

### 12. Plan-tier branching in rate limits

Single tier today, operator-tunable via CLI. Per-tenant tiering
(Phase 10) lands when paid tiers do; for a free-tier-only beta
this is fine, but multi-customer prod with mixed tiers needs it.

## Already done

- All four binaries split out as separate processes
- JWT-handoff auth between worker and standalones
  (`LOOP46_SERVICES_JWT_SECRET`)
- S3 as the cross-process coupling for files manifests + log
  batches + blobs
- `http.send` / `schedules.db` / leader-pinned schedule-server
  thread
- Multi-node tested end-to-end via existing cluster smokes
  (`notifications_smoke.sh`, `kv_bench_cluster.sh`)
- Snapshot capture + restore CLIs against real S3
  (`scripts/snapshot_smoke.sh`)

## Suggested order of attack

1. ~~**#1 raft log compaction.**~~ Done 2026-05-09.
2. ~~**#2 by-reference reuse.**~~ Done 2026-05-09.
3. **#1.1 snapshot off the raft thread.** Surfaced 2026-05-10
   by the scalability bench. Without this, periodic snapshots
   are limited to ~5 active tenants per interval before
   leadership flaps. Blocks production at the density Loop46 is
   designed for.
4. **#7 leader-failover smoke.** Validates the at-least-once
   contract you've already designed.
4. **#4 deployment doc + systemd units.** Afternoon's work; turns
   "I know how to start this" into "an operator can start this."
5. **#4 deployment doc + systemd units.** Afternoon's work; turns
   "I know how to start this" into "an operator can start this."
6. **#5 / #6 / #8.** Each an afternoon.
7. **#9 / #10 / #11 / #12.** Real work but slot after launch
   unless a specific customer requirement surfaces.
