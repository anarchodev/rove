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

### 1.1 Decouple log compaction from byte capture — **steps 1+2 done 2026-05-10; step 3 (send_snapshot) pending**

`scripts/snapshot_scalability_bench.sh` surfaced that the
per-tenant VACUUM INTO + S3 PUT + manifest serialize work in
`tickRaftCapture` runs synchronously on the raft thread. For any
non-trivial cluster (≥10 active tenants on commodity S3) the
pass takes longer than the willemt election timeout (default
250ms). During that window willemt's heartbeat tick can't fire,
followers time out, the leader steps down mid-capture, the new
leader takes over, captures once, loses leadership again — a
self-reinforcing flap. Each node captures exactly once with
`reused=0` (cold-start cache discarded by the safety guard
because the prior leader's `floor` is past where the new leader
has applied to). Steady-state never reached. Detail in
`docs/snapshot-bench-results.md`.

The first instinct was "move the byte capture to a dedicated
thread." A subsequent design pass concluded: **the byte capture
shouldn't be coupled to log compaction at all.** They're two
different concerns conflated into one S3 upload:

- **Log compaction** wants to advance willemt's
  `snapshot_last_idx` so old log entries can be deleted. It only
  needs an assertion that "this node's tenant state is consistent
  through idx N." That assertion is *the on-disk app.db files plus
  their `_apply_state.last_applied_raft_idx` stamp* — no separate
  byte copy required.
- **Catchup** wants to bring a fall-behind follower (or a fresh
  node) current. willemt's `send_snapshot` callback fires when a
  follower's `next_idx` is below the leader's snapshot floor;
  the right answer is peer-to-peer streaming of live app.db
  files via SQLite's online backup API. No S3 involved.

The cleaner architecture splits them:

```
steady-state log compaction (every N seconds, on raft thread):
  1. Stamp _apply_state[T] = current commit_idx for every T on
     this node (always-refresh-all so dormant tenants don't
     pin retention).
  2. raft_begin_snapshot + raft_end_snapshot at commit_idx.
  3. willemt drives cbLogPoll → truncateBefore +
     incremental_vacuum.
  Total cost: N small SQLite writes + log compaction.
  ~100ms for 100 tenants, ~1s for 10000. No S3, no manifest.

far-behind follower / new node (on demand, off raft thread):
  willemt's send_snapshot callback fires → peer streams its
  app.dbs via the SQLite backup API. New node atomic-renames
  into data_dir + tells willemt to load_snapshot at the
  source's _apply_state idx.
```

There is **no periodic S3 backup loop** in the new design. See
#1.2 — DR is handled by a non-voting learner replica, not by
periodic snapshots in S3. The `loop46 snapshot` operator CLI
stays available for on-demand "freeze a point in time" use, but
nothing automated runs it.

**The leader's compaction never needs cluster-wide aggregation.**
Each node manages its own log + apply state independently.
willemt's `send_snapshot` callback handles the "follower fell
behind" case via state transfer instead of log replay — which is
what makes "compact past my own apply_idx" safe.

**Why the `_apply_state` stamp is enough** for the snapshot bytes:
on each tenant T, `_apply_state[T] = N` plus the kv rows in the
file together assert "this file is the result of applying entries
1..N as they pertain to T." For dormant T (no entries between
T's last write and N targeted T), the bytes are byte-identical to
T's state at any prior idx ≤ N — so stamping `_apply_state[T] = N`
is correct without re-VACUUMing.

Implementation order:

1. **Done 2026-05-10**. Lazy `_apply_state` stamp at compaction
   time, with always-refresh-all over every tenant in
   `tenant_apply_idx`. `tickRaftCapture` now stamps every
   tenant + root + calls willemt begin/end + `compactLogPages`
   — no VACUUM INTO, no S3 PUT, no manifest. Returns a
   `TickResult` with `apply_position` / `stamped_tenants` /
   `stamped_root` / `duration_ms`.
2. **Done 2026-05-10**. Periodic VACUUM-INTO-to-S3 path
   removed. `RaftCaptureState` simplified (no manifest cache,
   no cold-start prime). `main.zig`'s snapshot setup
   correspondingly simpler — just `interval_ns`, no S3 store
   handle. The `capture()` function + `loop46 snapshot` /
   `loop46 restore-from-snapshot` CLIs are kept untouched for
   on-demand operator use. Verified via
   `scripts/snapshot_smoke.sh` (max tick 18ms) and
   `scripts/snapshot_scalability_bench.sh` (`N_total=1000`:
   29ms avg, 40ms max — see
   `docs/snapshot-bench-results.md`).
3. **Pending**. Wire willemt's `send_snapshot` callback to
   trigger peer-to-peer app.db streaming via SQLite's online
   backup API instead of just logging a warning. Receiving
   side stages files in `tmp_dir/{snap_id}/`, atomic-renames
   into `data_dir/`, calls `raft_load_snapshot`. (~2 days,
   includes a multi-node smoke that kills + re-adds a follower
   far behind the leader's snapshot floor.)

Net for steps 1+2 (delivered): heartbeat starvation eliminated
structurally (3000× faster pass at 1000 tenants), always-refresh-
all property verified, no S3 work in the periodic path. Step 3
(send_snapshot) remains for follower-catchup automation —
without it, far-behind followers still need operator
intervention via `loop46 restore-from-snapshot`.

**Blocks production at any density above ~5 active tenants per
snapshot interval** under the current code with default raft
timing flags + S3 latency.

### 1.2 Non-voting learner replica is the entire DR story — **NEW, design landed 2026-05-10**

When >half the voting cluster fails simultaneously (2 of 3, 3
of 5), raft loses quorum permanently. Recovering from that
case from a snapshot in S3 means losing every write between
the last snapshot and the failure — minutes-to-hours of
customer state, gone. Making S3 honestly cover this case
would require streaming the raft log to S3 on every commit
(continuous log shipping), which adds ~50ms p50 latency to
every customer write or accepts a loss window that defeats
the strong-DR claim anyway.

The cleaner answer is **a non-voting raft follower (a learner)**,
deployed in a different region from the voting cluster. willemt
already supports it via `raft_add_non_voting_node`:

- Same wire protocol as a voting follower; receives every
  committed entry within one heartbeat.
- Same apply path; `_apply_state` and on-disk state stay
  current.
- Doesn't count toward quorum. Adding/removing one doesn't
  change election thresholds. Latency to the learner doesn't
  gate commits.
- Can be geographically remote. Voters in one region (low-
  latency quorum), learner in another region (latency
  irrelevant for non-quorum).
- On regional failure: promote the learner via
  `raft_become_voter` (or rebuild a new voting cluster around
  the learner's data_dir) → seconds-of-loss recovery instead
  of minutes-or-more.
- Bonus: the learner can serve read traffic — dashboard,
  log queries, anything read-only — reducing voter load.

**The bet this codifies:** simultaneous loss of >half the
voters in *one* region is a meaningfully-rare event in
modern cloud infrastructure (correlated AZ failures are most
of the risk; cross-AZ deploys within a region handle them).
Region-scale loss IS a real concern, and the learner's
geographic separation handles it.

**S3 is NOT a Loop46 DR mechanism**, periodic or otherwise.
Loop46 doesn't promise customer-visible point-in-time
recovery (different shape from tape replay, which the
platform does provide). The remaining "would S3 backups be
useful for" cases all dissolve under inspection:

- *Compliance / N-day historical state retention* — not a
  platform commitment in PLAN.md. Customer-tier feature if
  ever needed.
- *"Oops, customer deleted their data" recovery* — Loop46
  doesn't promise customer-undo. Customers who need it write
  their own audit-log pattern in their own kv prefix.
- *Spawn a staging clone from prod state* — solved by
  spinning up a new learner pointing at prod, letting it
  catch up, then disconnecting. Same primitive as live DR;
  no new machinery.
- *Cluster-wide bad-write rollback* — a "bad write" reaching
  kv is by construction a customer handler bug (kv writes go
  through customer-validated handler code). Fixable by
  deploying a new handler version, not by rolling the
  cluster back hours and discarding every other tenant's
  intervening work.

The `loop46 snapshot` / `loop46 restore-from-snapshot`
operator CLIs stay shipped — they're useful for "freeze a
known-good point in time before this risky migration" /
"clone state to a fresh data_dir for debugging" — but
nothing automated invokes them.

What needs to ship:

1. CLI: `--peer-mode=voter|learner` per-peer entry, plumbed
   through to `raft_add_node` vs `raft_add_non_voting_node`.
   Default voter when unspecified for backward-compatibility.
   (~1 day)
2. Confirm willemt's quorum math correctly excludes learners
   from votes / commits — there are unit tests in willemt
   already, but our wrapper needs a test that verifies
   `RaftNode.committedSeq` doesn't move waiting on a learner
   ack. (~half day)
3. Promotion path: `raft_become_voter(learner_id)` exposed via
   an admin endpoint or operator CLI for the failover
   scenario. (~half day)
4. Multi-node smoke: 3 voters + 1 learner; drive load; kill 2
   voters; promote the learner; verify state continuity +
   cluster health post-promotion. (~1 day)

Total: ~3 days. Independently shippable from #1.1; can be
done before, after, or alongside.

**The combined story after #1.1 + #1.2**: each cluster node
manages its own log independently (compaction, catchup via
`send_snapshot`). DR is handled by live geographic redundancy
via the learner — promote on regional loss for
seconds-of-window recovery. S3 holds tenant blobs, log
batches, and bytecodes (the things it's already good at) but
is not a DR mechanism. The "halfway S3 DR" architecture is
gone entirely.

### 1.3 Files-server: stop writing per-tenant S3 manifests at bootstrap — **NEW, surfaced 2026-05-10 by 10k bench**

Same insight as #1.1, applied to files-server. The 10k-tenant
scalability bench's seed phase took **1012s** for 10,000
tenants on node 0 alone (then ~5min more for nodes 1+2 in
parallel via the S3-fast-path). Almost all of that time was
`bootstrapTenant` doing one S3 PUT per tenant for an
essentially-empty deployment manifest. 10,000 nearly byte-
identical S3 objects.

The waste shape: **per-entity work where most entities are
equivalent**, just like the raft snapshot story.
`bootstrapTenant` (`src/files_server/bootstrap.zig:153`)
unconditionally PUTs `tenants/{id}/deployments/0001.json` for
every newly-bootstrapped tenant, even when `files = []`. The
worker uses `_deploy/current` (in the local app.db, not S3)
to know "there's been a deploy here," so the S3 manifest
isn't load-bearing for the empty case.

Three solution shapes, in order of scope:

**Shape A: skip S3 for empty bootstraps.** ~1 day. When
`bootstrapTenant` is called with `files = []`, write
`_deploy/current = 0` locally as a sentinel "no real deploy
yet" marker and skip the S3 manifest entirely. First customer
deploy creates manifest 1 + flips `_deploy/current = 1`.
Worker bytecode-cache miss path learns to treat 0 as "no
deployment, return 503 like today's NoDeployment case."
Drops 10k-tenant seed from 17min to ~30s.

**Shape B: content-address the manifest itself.** ~2 days.
Instead of `tenants/{id}/deployments/{N}.json` (per-tenant
key, byte-duplicated when content matches across tenants),
store at `manifests/{sha256}.json` (content-addressed,
shared) with the per-tenant deploy pointer becoming a hash
reference. 10k empty bootstraps share one S3 object;
customer-deployed manifests dedupe across tenants when
content collides (rare, but free). Cleaner architecturally
than Shape A; covers more cases (non-empty default
bundles like the embedded admin/replay deploys also dedupe).

**Shape C: files-server local SQLite is the source of truth;
S3 holds only content-addressed bytecodes.** ~1 week. Same
parallel as #1.1 — the local `files.db` is the deployment
record; S3 is a blob store, not a manifest store. Manifests
are served by files-server-standalone via its HTTP API
(workers fetch on `_deploy/current` flips, one HTTP RT
instead of one S3 GET). Eliminates the per-tenant S3
manifest entirely. Biggest payoff but a real refactor.

Recommendation: **Shape A first** (small, immediate; fixes
the bench pain). Shape B/C come later if the bootstrap
shape stays load-bearing.

The bench-seed cost is also operationally meaningful: at
realistic per-tenant cost ~80-100ms, an operator
provisioning a fresh 10k-tenant cluster pays ~17 minutes
just on tenant init. Shape A drops that to seconds. New
nodes joining an existing cluster (which hit the S3
fast-path because manifests already exist) stay fast as
they are today.

### 2. By-reference manifest reuse for unchanged tenants — **done 2026-05-09, then made vestigial 2026-05-10**

> **Scope dissolved by #1.1 + #1.2 (2026-05-10):** the design
> conversation that produced #1.1 and #1.2 dropped both the
> steady-state byte capture (replaced by stamp-and-compact)
> AND the periodic S3 DR backup loop (replaced by the
> learner). The reuse logic in `capture()` is now exercised
> only by the operator-on-demand `loop46 snapshot` CLI —
> still useful, no longer load-bearing. Implementation
> stays; the periodic consumer is gone.


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
2. ~~**#2 by-reference reuse.**~~ Done 2026-05-09; made
   vestigial 2026-05-10 (still works, no longer on a
   periodic path).
3. **#1.1 decouple log compaction from byte capture.** Steps
   1+2 done 2026-05-10 (heartbeat starvation eliminated
   structurally; bench-verified at 1000 tenants with 40ms max
   tick). Step 3 (`send_snapshot` peer-to-peer streaming for
   follower catchup) is pending — without it, far-behind
   followers still need operator intervention via
   `loop46 restore-from-snapshot`. ~2 days remaining.
4. **#1.2 non-voting learner replica = the entire DR story.**
   Step 1 (CLI plumbing + raft_add_node branch) done
   2026-05-10. Promotion endpoint + multi-node smoke pending,
   ~2 days remaining. Live geographic redundancy. S3 is not a
   DR mechanism.
5. **#1.3 files-server: stop writing per-tenant S3 manifests
   at empty bootstraps.** Same insight as #1.1, applied to
   files-server. Surfaced 2026-05-10 by the 10k-tenant
   scalability bench (17min seed phase, mostly empty manifest
   PUTs). Shape A (~1 day) is the small surgical fix; Shape
   C (~1 week) is the architectural cleanup. Operationally
   meaningful for fresh-cluster provisioning.
6. **#7 leader-failover smoke.** Validates the at-least-once
   contract for `http.send` already designed.
7. **#4 deployment doc + systemd units.** Afternoon's work; turns
   "I know how to start this" into "an operator can start this."
   Covers the learner-mode peer config (#1.2).
8. **#3 / #5 / #6 / #8.** Each an afternoon.
9. **#9 / #10 / #11 / #12.** Real work but slot after launch
   unless a specific customer requirement surfaces.
