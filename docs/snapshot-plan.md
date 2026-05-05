# Raft snapshot plan — per-tenant indices, S3 transport, no global pause

This document expands `docs/PLAN.md` Phase 5.5 item 3 ("Raft snapshot
+ log compaction") into an implementable plan. It supersedes the
delta-row snapshot wire protocol that exists in
`src/kv/raft_snapshot.zig` today (which only fires meaningfully in
`.kv` apply mode; loop46 uses `.opaque_bytes` mode where snapshots
currently capture no application state).

The motivating framing is the worker-kv-path north star: keep the
worker fast, consistent, and uninterrupted. A snapshot strategy
that requires global write-pauses, even briefly, contradicts that
goal. So does a strategy where one dormant tenant pins the cluster's
raft log retention for days. The design below avoids both.

Stated semantics:

- **No global write-pause during snapshot.** The apply loop and
  worker proposes continue while snapshots are captured.
- **Compaction floor advances every snapshot pass**, regardless of
  per-tenant activity. One dormant tenant cannot pin retention.
- **Per-tenant snapshot indices** track each tenant's "consistent
  through this raft index" point independently.
- **Snapshots transport via S3**, not over the raft RPC channel.
  Multi-follower parallelism, durable artifacts for disaster
  recovery, no GB-of-data through raft messages.
- **Snapshot bytes are SQLite database files**, captured via SQLite's
  Online Backup API or `VACUUM INTO`. Replaces the current row-level
  delta protocol.
- **`.opaque_bytes` apply mode is the target.** The existing `.kv`
  mode delta protocol is left in place but is irrelevant for loop46.

---

## 1. Architecture

```
Leader, periodic snapshot pass:
┌────────────────────────────┐
│ for each tenant T:         │
│   capture snapshot_idx[T]  │      ┌──────────────────────────────────┐
│   if T's db unchanged:     │─────▶│  S3 bucket                       │
│     reuse previous file ref│      │   cluster/snapshots/{snap_id}/   │
│   else:                    │      │     manifest.json                │
│     VACUUM INTO new file   │      │     {tenant}/app.db              │
│     PUT to S3 (content-    │      │     ...                          │
│     addressed key)         │      └──────────────────────────────────┘
│ PUT manifest.json          │              ▲
│ raft_begin/end_snapshot at │              │ download in parallel
│ min(snapshot_idx[T])       │              │
└────────────────────────────┘              │
                                  ┌─────────┴──────────────────┐
                                  │  Far-behind follower       │
                                  │   - downloads manifest     │
                                  │   - downloads each tenant  │
                                  │     db file in parallel    │
                                  │   - atomic-renames into    │
                                  │     local data_dir         │
                                  │   - writes per-tenant      │
                                  │     last_applied to local  │
                                  │     _apply_state table     │
                                  │   - calls raft_begin/end_  │
                                  │     load_snapshot          │
                                  │   - resumes apply loop     │
                                  │     from next raft entry   │
                                  └────────────────────────────┘
```

S3 is the only transport. Workers don't participate in snapshots
at all — the raft thread on the leader does the captures; the raft
thread on a far-behind follower does the downloads and applies.
Worker dispatch continues uninterrupted on the leader; the follower
isn't serving traffic during catch-up anyway.

---

## 2. Why this shape

### 2.1 Why per-tenant indices

In `.opaque_bytes` mode each raft envelope targets one tenant
(envelope type 0 carries `instance_id`). Tenant A's `app.db` reflects
only entries that targeted A. So at any moment, A's "consistent
through" raft index is the index of the last entry that targeted A
that the apply loop has processed.

Two tenants snapshotted at different wall-clock times have different
"consistent through" indices because the apply loop has processed
different numbers of entries between their captures. Either:

- **Pause-and-snapshot** to make all captures land at the same index
  — global write-pause for the duration of every VACUUM pass. Rejected
  per the north star.
- **Per-tenant indices** to allow non-aligned captures — no pause,
  but requires per-tenant high-water tracking on followers.

This plan picks per-tenant.

### 2.2 Why always-refresh-all-tenants

Naive per-tenant snapshotting only re-captures tenants whose db
changed since the last snapshot. With many tenants per node (the
common case — see PLAN context), most are dormant at any given
moment. Their snapshot index stays at their last-write index forever.

Willemt's compaction floor is `min(snapshot_idx[T])` over all tenants
— the raft log must retain every entry any tenant might still need.
One dormant tenant pins the floor; the raft log grows unbounded.

The fix: on every snapshot pass, **refresh** every tenant's
snapshot_idx to the current global apply position, even if its db
hasn't changed. For an unchanged db the "refresh" is essentially
free — the file is byte-identical to the previous snapshot's, so the
new manifest entry references the previous file by content hash.
Manifest updates; bytes stay put.

The reasoning: if no entry has targeted T since T's last snapshot,
T's state at the current apply position is *identical* to T's state
at the previous snapshot — the entries between then and now didn't
touch T. Declaring `snapshot_idx[T] = current` is just acknowledging
"vacuously consistent."

### 2.3 Why S3 transport

The wire protocol in the existing `raft_snapshot.zig`
(SNAP_OFFER/SNAP_REQ/SNAP_DATA) ships row-level deltas over the raft
RPC channel — fine in `.kv` mode where rows have seqs and the kv
store can compute deltas. In `.opaque_bytes` mode there's nothing to
delta against. The application state lives in many separate SQLite
files spread across `data_dir/{tenant}/...`.

Shipping whole db files via raft RPC would put GB of data through
the same channel that carries small commit RPCs — head-of-line
blocking, congestion, latency spikes. S3 is already the durability
fabric for blobs / manifests / logs; adding snapshots to it is
consistent and cheap.

Bonus: snapshots on S3 are durable artifacts. A cluster-wide failure
becomes "spin up new cluster, point at the latest snapshot." Disaster
recovery for free.

---

## 3. Storage layout (S3)

```
cluster/snapshots/{snap_id}/manifest.json        ← per-snapshot manifest
cluster/snapshots/{snap_id}/{tenant_id}/app.db   ← per-tenant db file
cluster/snapshots/{snap_id}/__root__.db          ← root db (singleton)
```

`snap_id` is `{ulid}` — sortable by creation time. Manifest carries
both the snapshot's wall-clock and its raft-index range, so listing
the prefix gives chronological history.

### 3.1 Manifest shape

```json
{
  "v": 1,
  "snap_id": "01HM5...",
  "captured_at_ms": 1730764800000,
  "willemt_compaction_floor": 100,
  "willemt_term": 7,
  "tenants": {
    "acme": {
      "db_key": "cluster/snapshots/01HM5.../acme/app.db",
      "db_sha256": "abc...",
      "db_size": 524288,
      "snapshot_idx": 105
    },
    "beta": {
      "db_key": "cluster/snapshots/01HM4.../beta/app.db",
      "db_sha256": "def...",
      "db_size": 131072,
      "snapshot_idx": 105
    },
    ...
  },
  "root_db": {
    "db_key": "cluster/snapshots/01HM5.../__root__.db",
    "db_sha256": "ghi...",
    "db_size": 16384,
    "snapshot_idx": 105
  }
}
```

Notes:

- `db_key` for tenant `beta` references a *previous* snapshot's
  `01HM4...` file — beta was unchanged since that snapshot, so its
  bytes are reused by reference. Storage-efficient; no duplication.
- Every tenant in the manifest has the same `snapshot_idx` value
  (current apply position at the moment of the snapshot pass) —
  that's the always-refresh-all property. Only the `db_key` and hash
  differ between active and dormant tenants.
- `willemt_compaction_floor` = `min(snapshot_idx)` across all
  tenants. Since they all share the same value (always-refresh), this
  equals every tenant's `snapshot_idx`.

### 3.2 Db file format

Standard SQLite WAL-mode databases, captured via `VACUUM INTO` (atomic,
brief lock on writers) or Online Backup API (concurrent-safe, no
lock). For tenant app.db files at typical sizes (KB to low-MB),
`VACUUM INTO` is the simpler choice; per-tenant lock is microseconds.

VACUUM INTO produces a compact, defragmented file — smaller than
the live db. Good for transport and for the follower's load.

### 3.3 Snapshot retention on S3

Operator-tunable. Default: keep last 24h of snapshots at full per-pass
granularity, then daily for 30 days, then weekly forever (or until
operator prunes). Long-tail snapshots support point-in-time recovery
for "we noticed corruption on Tuesday, roll back to Monday morning."

Bytes cost is dominated by active tenants' changing dbs. Dormant
tenants' files are referenced by content hash across many manifests
without duplication (S3 GET on the same key always returns the same
bytes; a future janitor pass garbage-collects unreferenced files).

---

## 4. Leader: snapshot capture

### 4.1 Trigger

Periodic, e.g., every 10 minutes (configurable). The current
`raft_snapshot.zig` has a 500ms interval — far too aggressive for
file-shipping. 5-15 minutes is the right ballpark for the storage /
recovery-time tradeoff.

Also triggered on-demand via an admin endpoint for "I want to take a
snapshot right now before this risky deploy."

### 4.2 Capture loop

```
on snapshot pass:
  snap_id = ulid()
  apply_position = current global willemt apply index
  willemt_term = current term

  for each tenant T in registry:
    last_change_idx = T.last_apply_idx (read from in-memory tracking)
    prev_manifest = (most recent prior snapshot manifest if exists)

    if prev_manifest exists AND last_change_idx <= prev_manifest[T].snapshot_idx:
      # T's db hasn't changed since prev snapshot — reuse file
      manifest[T] = {
        db_key: prev_manifest[T].db_key,
        db_sha256: prev_manifest[T].db_sha256,
        db_size: prev_manifest[T].db_size,
        snapshot_idx: apply_position,    # <-- the always-refresh trick
      }
    else:
      # T has changed; capture fresh
      VACUUM INTO /tmp/{snap_id}/{T}/app.db
      sha = sha256(file)
      PUT cluster/snapshots/{snap_id}/{T}/app.db
      manifest[T] = { db_key, db_sha256, db_size, snapshot_idx: apply_position }

  # __root__.db is a singleton; same logic
  if root_changed_since_prev:
    VACUUM INTO + PUT
  else:
    reuse prev reference
  manifest.root_db = ...

  manifest.willemt_compaction_floor = apply_position
  PUT cluster/snapshots/{snap_id}/manifest.json

  # Tell willemt to compact past apply_position
  raft_begin_snapshot(NONBLOCKING_APPLY)
  raft_end_snapshot()
```

Key properties:

- **No global pause.** Each tenant's VACUUM INTO is a brief
  per-tenant write lock (microseconds for small dbs). Across 1000
  tenants done sequentially, total wall-clock is seconds — but the
  pause per tenant is sub-millisecond, and concurrent writes to
  *other* tenants are unaffected.
- **Bounded work per active tenant.** Only tenants whose
  `last_apply_idx` advanced past their previous snapshot's
  `snapshot_idx` get re-VACUUMed. Dormant tenants are pure
  manifest-bookkeeping.
- **Always-refresh advances compaction floor every pass.** The
  willemt log gets compacted past `apply_position` regardless of
  per-tenant activity distribution.

### 4.3 Capturing `last_apply_idx` per tenant

The apply loop already runs through `applyOne` in `apply.zig`. Add a
per-tenant `last_apply_idx` map in `ApplyCtx`:

```zig
const ApplyCtx = struct {
    ...
    /// Per-tenant high-water mark: the highest raft entry idx that
    /// has been applied to this tenant's app.db. Updated atomically
    /// with each apply. Used by the snapshot pass to decide whether
    /// a tenant's db needs re-VACUUM.
    tenant_apply_idx: std.StringHashMap(u64),
};
```

Updated inside the apply transaction so a crash mid-apply rolls back
both the customer writeset and the index update. The map itself
lives in memory; persisted into the per-tenant `_apply_state` table
(see §5) so a leader restart picks up where it left off.

### 4.4 What about envelopes that don't target a single tenant?

- `type 2 root_writeset` targets `__root__.db` — tracked separately
  as `root_apply_idx`.
- `type 0 writeset` targets a specific tenant — tracked per-tenant.
- `type 1 log_batch` and `type 3 files_writeset` go away per
  `logs-plan.md` and `files-server-plan.md`. After their migration,
  only types 0 and 2 remain.

So the per-tenant tracking is straightforward: every active envelope
type maps to one specific store.

---

## 5. Follower: snapshot load + per-tenant catch-up

### 5.1 Apply state table

Each tenant's `app.db` (and `__root__.db`) gains a small bookkeeping
table:

```sql
CREATE TABLE _apply_state (
    k TEXT PRIMARY KEY,
    v INTEGER NOT NULL
);
-- Single row: k = 'last_applied_raft_idx', v = the index
```

Read on apply-loop startup. Updated inside every apply transaction
(same SQLite tx as the customer writeset). The follower uses this to
filter applies: "only apply entry I to tenant T if I > T.last_applied".

### 5.2 Snapshot load flow

```
follower receives a SNAP_OFFER with snap_id (S3 path) from the leader:

  1. Stop the apply loop (drain in-flight applies; new entries queue).
  2. GET cluster/snapshots/{snap_id}/manifest.json
  3. Verify willemt_term against current state.
  4. For each tenant in manifest, in parallel (e.g., 16-way):
       GET manifest.tenants[T].db_key → /tmp/staging/{T}/app.db
       Verify sha256 matches manifest.tenants[T].db_sha256
       Atomic-rename /tmp/staging/{T}/app.db → data_dir/{T}/app.db
       Open the new app.db, INSERT INTO _apply_state
         (k='last_applied_raft_idx', v=manifest.tenants[T].snapshot_idx)
  5. Same for __root__.db.
  6. raft_begin_load_snapshot(willemt_term, willemt_compaction_floor)
     raft_end_load_snapshot()
  7. Resume the apply loop from (willemt_compaction_floor + 1).
```

### 5.3 Apply rule (post-snapshot or steady-state)

```
on raft entry at idx I targeting tenant T:
  T_last = SELECT v FROM T.app.db._apply_state WHERE k='last_applied_raft_idx'
  if I <= T_last:
    skip (already in this tenant's snapshot or was already applied)
  else:
    BEGIN TRANSACTION on T.app.db
      apply customer writeset operations
      UPDATE _apply_state SET v=I WHERE k='last_applied_raft_idx'
    COMMIT
```

The `_apply_state` row update is *part of the writeset transaction* —
atomicity guaranteed. A crash between writeset apply and index bump
is impossible because they commit together.

For the leader, the same rule applies (it just so happens that a
freshly-promoted leader also goes through this code path). The
filter `I <= T_last` is a no-op on the leader during normal
operation because applies arrive monotonically; it's the safety net
for snapshot recovery / replay scenarios.

### 5.4 Multi-tenant catch-up after snapshot load

Concrete example:

- Snapshot at willemt_compaction_floor = 100, all tenants'
  snapshot_idx = 100 (always-refresh).
- Raft entries 101..200 target various tenants (some entries to A,
  some to B, some to C).
- Follower resumes from idx 101.
- Each entry's apply checks the target tenant's `_apply_state.v`.
  Since all are at 100 from the snapshot, every entry I where
  I > 100 is applied to its target tenant.
- After processing entry 200, every tenant's `_apply_state.v` reflects
  the last entry that targeted it (could be 198 for A, 200 for B,
  175 for C).

No double-applies; no missed entries; no synchronization needed
between tenants.

---

## 6. Cold start / disaster recovery

### 6.1 Fresh follower joining

Same flow as far-behind follower (§5.2): leader sends SNAP_OFFER,
follower downloads + installs the snapshot, resumes from
compaction_floor + 1. No special "first time" handling needed.

### 6.2 Cluster-wide rebuild from S3

If every node loses its local data (catastrophic disk failure,
operator error, restoring to a new region):

```
1. Pick the most recent snapshot in cluster/snapshots/.
2. New cluster comes up empty.
3. First node to join becomes leader (single-node bootstrap).
4. Operator runs `loop46 restore-from-snapshot --snap-id 01HM5...`:
   - Downloads manifest.json
   - For each tenant: downloads db file, places in data_dir/{T}/app.db,
     populates _apply_state with snapshot_idx
   - Same for __root__.db
   - Initializes willemt's raft state to the snapshot's term + floor
5. Cluster is online at the snapshot's state.
6. Subsequent followers join via normal SNAP_OFFER flow.
```

The on-disk state of any node IS recoverable from the most recent
S3 snapshot plus any raft entries past the floor that haven't been
ingested. With raft entries past floor lost (cluster-wide failure),
the cluster is at the snapshot's point. Customers' kv state is
"last snapshot." Webhook outbox rows in app.db are present (they
ride the snapshot); the webhook-server safety-net drainer
re-delivers any that hadn't completed.

### 6.3 Point-in-time recovery

Operator: "we noticed corruption / bad deploy on Tuesday at 3pm.
Roll back to Monday 11pm."

```
loop46 restore-from-snapshot --snap-id <01HMx... matching Monday 11pm>
```

Picks an older snapshot from S3. Same flow as §6.2. Any raft state
past the snapshot's floor is discarded (operator confirms).

---

## 7. What gets removed

After this lands:

- The current `raft_snapshot.zig` delta-row protocol
  (`buildSnapData` / `applySnapData` / `kv.delta()`) becomes
  irrelevant for `.opaque_bytes` mode (the only mode loop46 uses).
  It can stay in place for any future `.kv`-mode user, but it's not
  exercised by loop46.
- The 500ms `SNAPSHOT_INTERVAL_NS` in `raft_snapshot.zig:31` —
  replaced by a longer interval (5-15 min) appropriate for file
  shipping.
- The `kv_store.checkpoint()` call in `doSnapshot` — replaced by the
  per-tenant VACUUM INTO captures.

What's added:

- `tenant_apply_idx` tracking in `ApplyCtx` (in-memory + persisted to
  `_apply_state` per tenant).
- The capture loop (above), running on the leader's raft thread on
  the snapshot interval.
- The S3 bucket layout for snapshots.
- The follower's `applySnapData` replacement that downloads + atomic-
  renames db files instead of installing rows.
- The per-entry filter `if I <= T_last: skip` in the apply path.
- A `loop46 restore-from-snapshot` admin CLI subcommand.

---

## 8. Migration order

Each step independently shippable + testable.

1. **Add `_apply_state` table to KvStore schema** + the per-entry
   filter in `applyOne`. Default behavior unchanged because the table
   starts empty and `last_applied = 0` means everything applies.
2. **Add `tenant_apply_idx` tracking to ApplyCtx.** Updated on every
   apply; persisted to `_apply_state` in the same writeset
   transaction.
3. **Build the S3 snapshot capture loop** behind a feature flag
   (`raft.snapshot_backend = none | s3`). Default `none` (current
   delta protocol stays). Smoke: trigger snapshot, verify S3 layout
   + manifest correctness.
4. **Build the follower load path** for S3 snapshots — feature-flagged
   to match the capture side. Smoke: hand-craft a snapshot in S3,
   point a fresh follower at it, verify catch-up.
5. **Switch the snapshot backend default to `s3`.** Validate in dev
   that periodic snapshots happen, S3 grows correctly, manifest
   references are stable across passes.
6. **Bump snapshot interval from 500ms to 10min.** Validates that
   the 500ms cadence isn't relied on anywhere else.
7. **Build `loop46 restore-from-snapshot` CLI subcommand.** Smoke:
   wipe a node's data, restore, verify it joins a running cluster.
8. **Mark the existing delta protocol as `.kv`-mode-only** in the
   doc comment; no code removal (it remains for any future `.kv`
   mode use).

---

## 9. Open questions / deferred

### 9.1 Snapshot capture concurrency

Sequential vs parallel VACUUM INTO across tenants. Sequential is
simpler; parallel is faster but contends on disk I/O. With many
tenants per node, parallel is probably worth it (e.g., 4-8 way
concurrent VACUUM). Defer measurement.

### 9.2 Snapshot retention policy

Default sketched in §3.3 but operator-tunable. Likely needs a
`loop46 admin snapshots prune` CLI subcommand for manual cleanup.

### 9.3 Janitor pass for unreferenced db files

After enough retention pruning, some `cluster/snapshots/{old_snap_id}/{T}/app.db`
files may no longer be referenced by any retained manifest. A janitor
walks S3, builds a referenced-set from all retained manifests, and
deletes unreferenced files. Run weekly; bounded; not on the hot
path.

### 9.4 Encryption-at-rest interaction

PLAN §2.7 (page-level encryption) encrypts customer kv pages.
Snapshot db files inherit the encryption — encrypted bytes go to S3
just like plaintext. Restore decrypts on read via the same page-
encryption layer. No design change here; flagged for the encryption
phase.

### 9.5 Cross-region snapshots

If snapshots live in one region's S3 and customers fail over to
another, the snapshot bucket needs to be replicated (S3 cross-region
replication, or a custom replicator). Operator concern; not in v1
scope.

### 9.6 Trim window: how long after compaction floor advances?

When the floor advances to N, willemt drops entries 0..N from its
log. But a follower currently catching up via raft log replay
between two snapshots may need entries below N. Mitigation: don't
compact past `min(floor, oldest_active_follower_pos)`. The existing
willemt logic should handle this; verify during implementation.
