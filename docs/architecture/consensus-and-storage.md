# Consensus & storage

> 🟢 **As-built reference.** How the V2 multi-raft substrate replicates and
> stores per-tenant state. Owns: `src/consensus/` (Node, Bridge, transport,
> envelope) and the per-tenant store path. For *why* these shapes were chosen
> and the alternatives rejected, see [decisions.md §10](../decisions.md) (V2
> architecture) and §2 (write-path invariants), plus the scaling evidence in the
> appendix below. For the request path that drives
> proposes, see [routing-and-ingress.md](routing-and-ingress.md); for tenant
> move orchestration, see [control-plane.md](control-plane.md).

## The shape in one paragraph

Each tenant is its own raft group (`tenant_id == group_id`, 1:1 — never N:1).
All of a node's groups are hosted by a single **raft-rs** `Manager` (TiKV's
raft-rs behind a Zig/C wrapper, `raft-rs-zig`), share one append-only WAL with
**one fsync per pump cycle**, and exchange messages with peer nodes through a
single per-recipient-coalesced transport. Idle groups hibernate out of the tick
set, so a node hosting thousands of mostly-idle tenants costs `O(active)`, not
`O(tenants)`. A tenant is a movable unit precisely because it is a whole group:
detach → ship committed state → attach a fresh group elsewhere.

Multi-raft buys **per-tenant isolation and no-downtime migration**, not
throughput — at realistic handler costs the binding constraint is the apply
pipeline, which is independent of raft topology (see Performance below). Do not
frame V2 as a throughput win.

## Code map

| File | Role |
|---|---|
| `src/consensus/node.zig` | One `Node` per cluster node. Owns the raft-rs `Manager`, the two-pass async-append pump, the active-set/hibernation machinery, `ApplyMode`, `StoreResolver`, and the durabilize floor hook. |
| `src/consensus/bridge.zig` | Per-tenant `Bridge` — the seam between a worker and consensus. `registerTenant` (deterministic gid), propose, the entry-identity seq binding (`origin_id` + pending set), the provenance skip query, the worker-ack durabilize floor, fault plumbing. |
| `src/consensus/transport.zig` | Cross-node wire layer: per-recipient coalescing, the heartbeat-detect byte test, the woke-list that feeds hibernation, the `stepBatch` skip counter. |
| `src/consensus/envelope.zig` | The replicated entry codec: the **entry origin frame** (`[0xF7][origin u64][seq u64]` — every entry's proposer identity), type byte + payload framing, the writeset readset-frame strip on apply. |
| `src/kv/raft_net.zig`, `raft_rpc.zig` | liburing wire transport + frame codec, reused from V1 (std-only; the V1 raft *message types* are unused). |
| `src/kv/writeset.zig`, `envelope_codec.zig` | Writeset encode/decode (`applyEncodedDirect` is the consensus-apply entry point) and the `ENVELOPE_TYPE_*` constants the apply path agrees on. |
| `raft-rs-zig` (fetched dep) | The Rust raft-rs wrapper: a `Manager` of many `RawNode`s behind a C ABI, with a mailbox `poll_ready`/`release`, batched `tick_groups`/`step_batch`, the **async-append persist handshake** (`process_ready` records appends; `on_persist` acks them after the host fsync), and `create_group`/`destroy_group`/`clear_tombstone` for migration. |

## What replicates through raft (envelopes)

A raft entry is a typed byte blob (`src/consensus/envelope.zig`,
`src/kv/envelope_codec.zig`). Three type bytes are live:

| Type | Name | Target store | Producer |
|---|---|---|---|
| `0` | `writeset` | `{data_dir}/{id}/app.db` | Customer handler `kv.*` via `TrackedTxn` + writeset; `_deploy/current`; the `webhook.send`/`email.send` owed-markers (ordinary kv writes). |
| `1` | `multi` | per-inner-envelope target | Worker dispatcher — atomically bundles several writeset envelopes into one entry. |
| `2` | `root_writeset` | `{data_dir}/__root__.db` | `provisionInstance` / admin `createInstance`; ACME `cert/{host}`. |

Retired type bytes are rejected loudly by the decoder so a stale log entry
surfaces rather than mis-applying. The full evolution table is in PLAN §10.2.

**Entry origin frame (load-bearing).** Every proposed entry is wrapped in a
17-byte identity frame *before* the envelope: `[0xF7][origin u64][seq u64]`
(`envelope.EntryFrame`). `origin` is the proposing bridge's **per-boot random
id**, `seq` its per-tenant propose ticket. The apply path uses the pair to (a)
bind a committed entry to the *exact* local propose awaiting it and (b) key
the worker-overlay store skip on true provenance — see Multi-node below. The
random per-boot origin also fences a restarted node's replayed WAL entries
from colliding with the new incarnation's seq space. `origin = seq = 0` marks
a hookless propose (tests, bare nodes): it matches no bridge, so it is never
skipped and never advances a watermark. An unframed entry fails loudly
(`BadEntryFrame`).

**Writeset frame (load-bearing).** A type-0 payload is *readset-framed*:
`[u32 ws_len][ws][u32 rs_len][rs]` (from `src/js/apply.zig`). The readset rides
for the replay tape. `node.applyEntry` strips the frame
(`decodeWriteSetPayload`) before applying. Apply correctness is largely a
follower-path concern — the leader skips the store write for its own live
proposes — so follower-only smoke coverage is what historically caught frame
bugs here.

**Multi routing (per-inner id).** A `multi`'s inner writesets route by **their
own** envelope id, never by the carrying group's slot — an admin batch
(`proposeBatch`) puts cross-tenant trampoline targets and `platform.root.*`
root-writesets in one multi anchored on the admin tenant's group, and the
apply must land each inner in *its* tenant's store (`""` = the node root
store, per the `StoreResolver` contract). A target the node cannot resolve is
a loud `UnroutedApply`, not a silent mis-write.

## Write path & durability

A customer write lands in a speculative **volatile overlay** (kvexp), then a
parallel raft propose replicates it. On quorum the overlay commits
(`TrackedTxn.commit()`); on fault it rolls back. A pre-quorum crash needs no
undo log — the overlay is volatile, so the speculative write never reached
disk. The writer is **never held across the raft round-trip** (decisions.md
§2.2: holding the WAL writer for the RTT serializes a tenant to
`batch_size / raft_latency`).

Three ordering rules make "committed" mean **durable**:

- **Quorum counts only fsynced entries.** raft-rs runs the async-append flow:
  `processReady` only *records* an append (buffered into the shared WAL);
  the pump acks `onPersist` after the cycle's fsync, and only then does this
  node's entry count toward the commit quorum (and only then do its
  persistence-asserting messages — append acks, vote responses — leave the
  node). The leader's own volatile tail can never be the deciding quorum vote.
- **The commit hook fires post-fsync.** Per-entry commit notifications are
  staged during apply and fired only after `wal.flush()` succeeds — the
  watermark a worker acks clients on never runs ahead of the fsync. On a flush
  failure they are dropped: parked workers time out → 503, never a false
  durable ack.
- **503 means *unknown outcome*.** A faulted/timed-out propose may still
  commit later (it then applies via the pump path, its waiter gone), so client
  retries are at-least-once — consistent with the platform's idempotent-replay
  posture. A worker commit-wait **timeout** never rolls its txn back
  unilaterally: it *requests* a pump-side fault (`requestFault`), which the
  pump serializes against its own skip/commit decisions, and the next sweep
  resolves to commit (committed-beats-faulted) or a normal-fault rollback.

## Multi-node: replication, roles, and failover

A tenant's group spans the cluster's nodes (a cluster is a *set* of node
origins). Three mechanisms make a follower able to take over:

- **Provenance-keyed apply (`ApplyMode.worker_overlay` + `skipQuery`).** The
  pump skips the store write **iff the entry is this node's own still-pending
  propose** (origin frame matches the bridge's per-boot id *and* the seq is in
  the tenant's pending set — that worker txn IS the store write, committed on
  watermark advance). Everything else is written by the pump: a follower's
  replicated entries, a freshly-promoted leader's catch-up entries proposed
  elsewhere, restart-recovery replay (no live txns at boot), and an entry
  whose local waiter already gave up (fault/timeout → txn rolled back).
  Keying the skip on *currently-being-leader* — the earlier shape — silently
  dropped catch-up and abandoned-waiter writes from the serving store.
- **`StoreResolver` + the two-handle model (Full-HA store unification).** A
  follower must replicate into the *same* store it will serve from after
  promotion — but **never through the worker's own `KvStore` handle**: a
  handle carries per-batch txn state (`active_txn`), and a pump-thread apply
  during a worker dispatch would land inside the worker's open speculative
  txn. The resolver (`PumpStores`, `rewind/main.zig`) hands the pump its own
  sibling handles, `attachSibling`'d into the same manifest at the same store
  id — shared `TenantState` (overlay/LMDB/lease: the worker serves exactly
  what the pump applies) with pump-private txn state. The apply itself uses
  kvexp's **chain-bypassing authoritative writes**
  (`StoreLease.applyPut/applyDelete` via `writeset.applyEncodedDirect`):
  replicated state is the cluster's truth and must never sequence behind — or
  `NotChainHead`-fail on — the tenant's open speculative txn chain (sound
  because a follower's write proposes always fault, so local speculative
  writes can never commit over an applied value).
- **Entry-identity seq binding.** `propose` records its seq in a per-tenant
  `pending` set, and the pump stamps the entry with the bridge's
  `origin_id` + seq. The commit hook advances `committed_seq` **iff the
  committed entry's origin is this bridge's own and that exact seq is still
  pending** — never by FIFO position (an old-term entry resurrected by a
  re-election while a new propose sat at the FIFO front used to credit the
  wrong waiter: a false durable ack). A propose that can't commit here (not
  leader, or the per-cycle leadership-loss sweep) is **faulted** — the parked
  worker fails fast (503, *unknown outcome*) and the client retries the
  leader.

**Apply failure is fatal.** A committed entry that fails to decode/apply has
already been consumed by raft (`advance_apply`; never redelivered), so
warn-and-continue would serve a silently-diverged replica that could later win
an election. The production pump **panics** instead; a restart replays the WAL
from the last checkpoint and converges. (This posture is what surfaced the
follower-apply races the two-handle model fixed.)

**Leader gating.** Writes only commit on the group leader. The front door's
`proxyToCluster` tries nodes in order and stops at the first non-503, so a write
self-routes to the leader while a read is served by any synced node. The
immediate-commit `v2-kv` PUT endpoint is leader-gated too (it has no undo, so a
follower must reject *before* a speculative local write that would diverge).

**Deterministic gid.** `registerTenant` hashes the tenant id (Wyhash) to the
group id — every node must derive the *same* id or replication can't bind the
incarnations. (Not a local counter.)

## Hibernation (active-set)

With one group per tenant, naively ticking every group every cycle is
`O(tenants)`, and heartbeat traffic itself would keep every group's activity
timer alive — a self-feeding loop. The fix:

- A group is in `Node.active` iff it had **real** work recently. The pump ticks
  only the active set. A hibernated group still *responds* (a stepped-in message
  makes it ready via `pollReady` without a tick) — it just isn't *driven*.
- `bumpActive(gid)` refreshes a per-slot deadline (`now + hibernate_ns`, default
  2 s) on: a **propose** (bumped *before* `mgr.propose`, so even a rejected
  non-leader propose re-ticks toward election); **formation**; and a
  **non-heartbeat inbound step**.
- `sweepHibernated(now)` drops past-deadline groups once per cycle. **No
  pre-seed** — an idle group is simply never bumped, so cost is `O(active)`.
- **Heartbeats must not wake.** The transport detects heartbeat-like messages at
  the eraftpb wire-byte level (`isHeartbeatLike`: `[0x08][8|9]` =
  `MsgHeartbeat`/`MsgHeartbeatResponse`, codec-independent) and only records
  *non-heartbeat* gids into the `woke` list the pump drains. "A heartbeat means
  *don't elect me*, not *I have work*."

**Why this is safe.** Not ticking a group freezes *all* its raft timers
(leader heartbeat + follower election alike). Nodes count the hibernate deadline
from the last *real* message, which all nodes see within network jitter, so they
hibernate a group within jitter of each other — far under the election timeout,
and the leader heartbeats (resetting follower election timers) right up until it
hibernates. What matters is the *skew*, not the absolute `hibernate_ns`.
**Intended tradeoff:** a fully-idle group whose leader dies does not
auto-re-elect; the next request wakes it (propose → bump → tick → campaign).
An idle group has nothing to serve, so this costs nothing real.

Proven by the `v2-test` hibernation suite + `v2-hibernation-bench` (pump cycle
at K=10k idle tenants drops from ~1 ms tick-all to ~0). A cluster-scale
**live-traffic** hibernation macrobench is a tracked follow-up — proof at
scale, not function.

## Shared WAL & fsync (the two-pass pump)

All of a node's groups interleave into one append-only WAL; the pump fsyncs
**once per cycle** regardless of how many groups committed. Per-group fsync
collapses throughput past ~K=4. The record carries a group id
(`[tag:u8][group_id:u64][len:u32][payload][crc32]`) so the interleaved stream is
a sequence of `(group_id, record)` tuples. Because a shared file cannot be
physically rewound when raft rewrites one group's uncommitted suffix, replay
**dispatches by `group_id` and keeps the last authoritative entry per group** —
it is not a linear truncate.

The pump is **two passes around that one fsync** (the async-append handshake):

```
tick → pass 1: processReady each ready group
                 (appends BUFFERED; committed entries handed out here were
                  already durable — raft gates them on its persist watermark)
     → wal.flush()                       (the cycle's one fsync)
     → mgr.onPersist per buffered group  (entries become quorum-countable;
                                          stashed append-acks/vote-responses
                                          released to the outboxes)
     → pass 2: poll + apply the commits the acks just unlocked
                 (a single-node propose still commits within one cycle)
     → fire staged commit hooks          (everything applied is fsync-covered)
     → takeMessages + release, both passes
```

On a failed flush the persist acks are *retained, not sent*: no ack on the
wire, commits stay locked, nothing claims durability for volatile bytes.

## Durability, compaction & crash recovery

Three mechanisms keep the WAL bounded and a restart correct:

- **Durabilize tick + the worker-ack floor** (`durabilizeTick`, the V2 port of
  V1's `Cluster.tickSnapshot`). Interval-gated (`durabilize_interval_ns`), it
  folds every **dirty** group's kvexp overlay into LMDB and stamps each group's
  `lastAppliedRaftIdx` — `O(dirty)`, not `O(all groups)`. The fold target is
  `min(applied_idx, floor)`, where the **durabilize floor** (bridge hook) is
  one less than the first committed-but-not-worker-acked entry's index: a
  *skipped* entry's writes live in the worker's open `TrackedTxn` until the
  worker observes the watermark and commits, and kvexp's fold only covers the
  committed overlay — stamping/compacting past an un-acked entry would claim
  durability for data the fold cannot see. Committers ack via
  `noteWorkerCommitted` (drain arms, parked-unit txns; immediate-commit
  producers pre-ack — the bridge keeps an acked high-water so a
  fire-and-forget propose can't pin the floor). A slot whose fold could not
  reach `applied_idx` **stays dirty** and is finished by a later tick.
- **Compaction (single- and multi-node).** After durabilizing, a node truncates
  the shared WAL (`compact_wal = true`, on). Safe because the data up to the
  truncate point was folded into LMDB and the watermark stamped *before* the
  truncate; the tick flushes the WAL once before its first truncate (the
  async-append durable `HardState.commit` lags the live commit by one fsync, and
  truncating past a non-durable commit would panic `RawNode::new` at recovery).
  Single-node truncates to the durabilized index. **Multi-node** floors the
  truncate point at the cluster-wide **min match index** (`raft_manager_min_match_index`)
  — the leader keeps every entry a lagging voter still needs, so a slightly-behind
  follower catches up from the log — capped by `wal_retention_max`
  (`REWIND_WAL_RETENTION_MAX`, default `DEFAULT_WAL_RETENTION`): a voter further
  behind than the cap is compacted past and caught up by a **data-carrying
  snapshot** instead, bounding WAL growth during a follower outage. Multi-node
  compaction is gated on snapshots being enabled (`snap_stager`), so the catch-up
  net always exists. Physical segment-file GC reclaims fully-compacted segments
  via `noteCompaction`.
- **Snapshots (multi-node catch-up + the conf_change prerequisite).** When a
  follower's `next_index` falls below the leader's `first_index`, raft-rs calls
  the storage `snapshot` provider; rove dumps the tenant store read-only at
  `durabilized_idx` (fast, pump-safe) and stages the bundle in S3
  (`…/raft-snap/{idx}`) on an **off-pump** thread (`consensus/snapshot.zig`),
  reporting `SnapshotTemporarilyUnavailable` until the upload lands (raft-rs
  retries). The `MsgSnapshot` carries only a tiny descriptor — the bytes never
  ride raft. On the follower, the pump's snapshot gate (`drivePendingSnapshot`,
  via `raft_manager_pending_snapshot` — peeks the pending snapshot *without*
  consuming a ready) fetches the bundle off-pump to a local staging file and
  **defers** applying until it lands; then `process_ready` applies it
  synchronously (`loadSnapshotBundle` → store + watermark advance together to the
  snapshot index). A snapshot is installed durably before raft's `applied`
  advances (the fork marks the ready persisted via `on_persist_ready` so
  `advance_apply` doesn't outrun `persisted`). Validated by
  `snapshot_catchup_smoke_v2` (forces the path with a tiny retention cap).
- **Crash recovery.** At boot the Node opens the WAL with `SharedWal.open` (not
  `init`): it CRC-scans the segments, physically truncates only a *torn tail*,
  and buckets recovered records by `group_id`. `Bridge.recoverGroups` reads the
  per-node group list (a group's `id_str` is not recoverable from the WAL
  alone) and calls `recoverGroup` for each, replaying its tail so the pump
  writes the store itself — the new bridge has no pending proposes at boot, so
  the provenance skip naturally answers "write it" (the prior incarnation's
  origin id can never match either). Per-group compaction watermarks are
  re-baselined into each new segment header alongside hard state, so recovery
  finds a group's compaction point even after the segment that first wrote it
  is GC'd.

raft-rs supplies the in-protocol snapshot transport; the per-tenant *state*
durability above is rove's, not raft-rs's. (The former V1 snapshot doc — a
willemt-raft stamp-and-compact model — did not carry over; it is in git
history.) On commit-index durability: under the async-append flow a commit
advance surfaces as a changed `hs()` in a *subsequent* ready and rides the
normal hard-state persist, one fsync behind the live commit — safe because the
durable commit only needs to stay ≥ the compaction point, which the
pre-compact flush above guarantees. (The earlier sync-flow `compact → recover`
hard-state bug — a recovered group loading a stale `commit = 0` →
`hs.commit out of range` — was fixed by persisting the `LightReady` commit
index; the async flow retires that mechanism but keeps the regression tests.)
Compaction is verified to survive compact→recover across restart under the
full V2 smoke suite (`rewind` / `tenant_move` / `three_node` /
`cp_move_recovery` / `zero_downtime_move`).

## Shutdown ordering (pump before observer targets)

Anything the pump's apply path can call into must outlive the pump. The rewind
worker's LIFO defers once deinit'd `NodeState` *before* `bridge.deinit` joined
the pump thread, so a follower applying `_deploy/current` in that window fired
the deploy apply-observer into freed memory — `main` now calls
`bridge.stopPump()` right after the worker joins, mirroring the CP's
pump-before-observer-target ordering. The teardown smokes (`three_node` /
`zero_downtime_{move,load,forward}` / `smoke_lib_v2.shutdown`) **assert a clean
handled-SIGTERM exit 0 per process**, so a regression (panic = SIGABRT, hang =
SIGKILL escalation) fails loudly instead of vanishing into an unchecked
`p.wait()`.

## Tenant move (mechanism)

A tenant is movable because it is a whole group. The DP-level mechanism:

- **detach** → `bundle`: quiesce, await `committedSeq` *and* the worker-overlay
  drain (`workerAckedThrough` — raft commit alone only proves the apply was
  *skipped*; the skipped writes live in parked worker txns until the drain
  promotes them, and the drain runs between dispatches on the very thread the
  bundle handler blocks; the source replies **423** until the overlay covers
  the quiesce point and the CP retries the same node), then dump the tenant's
  committed KV state to a self-describing byte blob (magic + version + tenant
  + KV pairs + CRC32), `destroyGroup` on every node (which raft-rs
  **tombstones**), free pending handles.
- **attach**(`bundle`): load it, `clearTombstone` (migration is *intentional*
  id reuse — raft-rs tombstones a destroyed id to block zombie messages, so an
  explicit lift is required), `createGroupEpoch` a fresh incarnation at the
  migration epoch on every destination node, drive to leader.

The bundle ships **committed state only**; the destination starts a fresh group
(term/commit-idx reset) at a new epoch, and the epoch fences stale messages to
the old location. Quiesce (pause proposes, drain) and the directory flip that
make this a *correct, no-downtime* move are the **control plane's** job — see
[control-plane.md](control-plane.md). Blobs never move (shared backend, below).

## Blob replication (bytes don't ride raft)

Source, bytecode, and static assets live in `file-blobs/` and are **not**
carried through raft — a 1 MB asset per entry would blow the log budget. Raft
replicates the *manifest* (the `file/{path}` → `{hash, kind, content_type}`
pointer); a shared content-addressed `BlobStore` backend (process-wide
`BLOB_BACKEND=fs|s3`) serves the bytes every node references by hash. Per-tenant
scoping in S3 mirrors the on-disk layout exactly
(`{key_prefix_base}{id}/file-blobs/`) so leader and followers hit identical
keys. This is why tenant move never moves blobs.

## Performance characteristics (what to expect, and not)

- **Apply-bound, not consensus-bound.** At realistic handler costs
  (100 µs–1 ms) throughput scales with **apply-worker count**, capped near
  `W × per-request rate`, with `W = physical core count` (SMT oversubscribe
  *collapses* it). Consensus is nowhere near the bottleneck. Spend throughput
  effort on the apply path, spend multi-raft on migration/isolation.
- **Allocator is load-bearing.** Zig's default `GeneralPurposeAllocator` has a
  global mutex that becomes *the* wall under multi-threaded multi-raft. rove uses
  `c_allocator` globally — **keep it**, and the Rust shim must set a
  `#[global_allocator]` (jemalloc/mimalloc), as TiKV does. Swap the allocator
  *before* any contention deep-dive; it's a one-line probe.
- **Transport coalescing is mandatory at scale.** One envelope per *recipient*
  per cycle (not per group-message) drops sends from `O(groups)` to
  `O(cluster_size)`.
- The honest verdict: "throughput parity, architecturally cleaner; the win is
  no-downtime moves and per-tenant blast radius."

## Appendix — prototype evidence

The substrate was de-risked end-to-end by the `rewind2` / `raft-rs-zig`
prototype before V2 wrote code. Headline K=10,000-tenant Zipf result: the
engineering that makes multi-raft *viable* (heartbeat hibernation, mailbox
`poll_ready`, batched tick, per-recipient coalescing, shared-fsync WAL, non-GPA
allocator) moved a naive 5.8k r/s baseline to 540k+; setting handler work to
zero exposes a consensus ceiling far above any realistic load. Hibernation
microbench (`v2-hibernation-bench`): K=10k pump cycle 1000 µs (tick-all) → ~0
(idle), ≈31,000×. Full methodology, the decision→artifact map, and commit index
were captured from the now-removed `v2-multiraft-scaling-learnings.md` (in git
history); the transferable conclusions are in decisions.md §10.
