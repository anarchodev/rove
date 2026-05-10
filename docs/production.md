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

### 2. By-reference manifest reuse for unchanged tenants

Today's snapshot pass VACUUMs every tenant regardless. With many
dormant tenants per node that's wasted disk + S3 cost on every
interval. Plan calls for the "always-refresh-all-tenants" trick
(manifest-bookkeeping refresh, no re-VACUUM for unchanged) — needed
before periodic snapshots are practical at density. Same sub-plan.

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
2. **#2 by-reference reuse.** Makes the snapshot pass cheap at
   density (avoids re-VACUUMing dormant tenants every interval).
3. **#7 leader-failover smoke.** Validates the at-least-once
   contract you've already designed.
4. **#4 deployment doc + systemd units.** Afternoon's work; turns
   "I know how to start this" into "an operator can start this."
5. **#5 / #6 / #8.** Each an afternoon.
6. **#9 / #10 / #11 / #12.** Real work but slot after launch
   unless a specific customer requirement surfaces.
