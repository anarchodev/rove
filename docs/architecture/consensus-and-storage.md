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
| `src/consensus/node.zig` | One `Node` per cluster node. Owns the raft-rs `Manager`, the pump loop, the active-set/hibernation machinery, `ApplyMode`, and `StoreResolver`. |
| `src/consensus/bridge.zig` | Per-tenant `Bridge` — the seam between a worker and consensus. `registerTenant` (deterministic gid), propose, the per-tenant FIFO seq binding, role-aware apply wiring. |
| `src/consensus/transport.zig` | Cross-node wire layer: per-recipient coalescing, the heartbeat-detect byte test, the woke-list that feeds hibernation. |
| `src/consensus/envelope.zig` | The replicated entry codec: type byte + payload framing; the writeset readset-frame strip on apply. |
| `src/kv/raft_net.zig`, `raft_rpc.zig` | liburing wire transport + frame codec, reused from V1 (std-only; the V1 raft *message types* are unused). |
| `src/kv/writeset.zig`, `envelope_codec.zig` | Writeset encode/decode and the `ENVELOPE_TYPE_*` constants the apply path agrees on. |
| `raft-rs-zig` (fetched dep) | The Rust raft-rs wrapper: a `Manager` of many `RawNode`s behind a C ABI, with a mailbox `poll_ready`/`release`, batched `tick_groups`/`step_batch`, and `create_group`/`destroy_group`/`clear_tombstone` for migration. |

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

**Writeset frame (load-bearing).** A type-0 payload is *readset-framed*:
`[u32 ws_len][ws][u32 rs_len][rs]` (from `src/js/apply.zig`). The readset rides
for the replay tape. `node.applyEntry` strips the frame
(`decodeWriteSetPayload`) before `writeset.applyEncoded`. A single-node leader
**skips apply** (its `TrackedTxn.commit` already wrote durably), so this frame
mismatch was invisible until a real follower applied a worker entry — apply
correctness is a follower-path concern.

## Write path & durability

A customer write lands in a speculative **volatile overlay** (kvexp), then a
parallel raft propose replicates it. On quorum the overlay commits
(`TrackedTxn.commit()`); on fault/timeout it rolls back. A pre-quorum crash
needs no undo log — the overlay is volatile, so the speculative write never
reached disk. The writer is **never held across the raft round-trip**
(decisions.md §2.2: holding the WAL writer for the RTT serializes a tenant to
`batch_size / raft_latency`).

## Multi-node: replication, roles, and failover

A tenant's group spans the cluster's nodes (a cluster is a *set* of node
origins). Three mechanisms make a follower able to take over:

- **Role-aware apply (`ApplyMode.worker_overlay`).** On the **leader** the pump
  *skips* the store write — the worker's `TrackedTxn.commit` is the durable
  write. On a **follower** (no worker) the pump *writes* the store, so followers
  stay in sync.
- **`StoreResolver` (Full-HA store unification).** A follower must replicate
  into the *same* store it will serve from after promotion. The resolver
  (`node.zig`, set by the bridge via `setStoreResolver`) points follower apply
  at the worker's own `inst.kv` (`{data_dir}/{id}/app.db`), not an unused
  node-local store. Without this a promoted follower would serve an empty DB.
- **Explicit per-entry FIFO seq binding.** `propose` pushes its seq onto a
  per-tenant `pending` FIFO; the commit hook pops the front **only when this
  node leads**. A propose that can't commit here (not leader, or a per-cycle
  leadership-loss sweep) is **faulted** — the parked worker fails fast (503) and
  the client retries the leader. A write in flight at a leader change is
  faulted + retried, **not lost**. (Counting seqs is wrong multi-node: proposes
  can fail, and followers apply entries with no local proposer.)

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

## Shared WAL & fsync

All of a node's groups interleave into one append-only WAL; the pump calls
`flush()` **once per pump cycle** regardless of how many groups committed. Per-
group fsync collapses throughput past ~K=4. The record carries a group id
(`[tag:u8][group_id:u64][len:u32][payload][crc32]`) so the interleaved stream is
a sequence of `(group_id, record)` tuples. Because a shared file cannot be
physically rewound when raft rewrites one group's uncommitted suffix, replay
**dispatches by `group_id` and keeps the last authoritative entry per group** —
it is not a linear truncate.

## Durability, compaction & crash recovery

Three mechanisms keep the WAL bounded and a restart correct:

- **Durabilize tick** (`durabilizeTick`, the V2 port of V1's
  `Cluster.tickSnapshot`). Interval-gated (`durabilize_interval_ns`), it folds
  every **dirty** group's kvexp overlay into LMDB and stamps each group's
  `lastAppliedRaftIdx` — `O(dirty)`, not `O(all groups)`. The fold is one fsync
  amortized over many commits. A committed write is already durable in the
  fsync'd raft WAL the instant it commits; this checkpoint just bounds how much
  WAL a restart must replay.
- **Compaction (single-node).** After durabilizing, a single-node node truncates
  the shared WAL up to the durabilized index (`compact_wal = true`, on). Safe
  because the data up to that point was folded into LMDB and the watermark
  stamped *before* the truncate, so it survives independent of the WAL —
  recovery reloads from LMDB and replays only the post-compaction tail.
  Multi-node nodes durabilize (bounding replay) but do **not** truncate:
  truncating safely needs a follower-match-index floor, and a lagging follower
  would then need a data-carrying snapshot, which is not wired. **This is the one
  known limitation in the storage layer** — it bounds nothing worse than WAL
  growth on a long-lived multi-node group; correctness holds.
- **Crash recovery.** At boot the Node opens the WAL with `SharedWal.open` (not
  `init`): it CRC-scans the segments, physically truncates only a *torn tail*,
  and buckets recovered records by `group_id`. `Bridge.recoverGroups` reads the
  per-node group list (a group's `id_str` is not recoverable from the WAL
  alone) and calls `recoverGroup` for each, replaying its tail with
  `recovering = true` so the pump writes the store itself — at restart there is
  no worker to own the speculative write, exactly as a follower does. Per-group
  compaction watermarks are re-baselined into each new segment header alongside
  hard state, so recovery finds a group's compaction point even after the
  segment that first wrote it is GC'd.

raft-rs supplies the in-protocol snapshot transport; the per-tenant *state*
durability above is rove's, not raft-rs's. (The former V1 snapshot doc — a
willemt-raft stamp-and-compact model — did not carry over; it is in git
history.) The earlier raft-rs-zig `compact → recover` hard-state bug (a recovered
group loaded a stale `commit = 0` → `hs.commit out of range`) is fixed upstream
by persisting the `LightReady` commit index (pinned at raft-rs-zig `5092bc6`);
compaction is verified to survive compact→recover across restart under the full
V2 smoke suite (`rewind` / `tenant_move` / `three_node` / `cp_move_recovery` /
`zero_downtime_move`).

## Tenant move (mechanism)

A tenant is movable because it is a whole group. The DP-level mechanism:

- **detach** → `bundle`: dump the tenant's committed KV state to a
  self-describing byte blob (magic + version + tenant + KV pairs + CRC32),
  `destroyGroup` on every node (which raft-rs **tombstones**), free pending
  handles.
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
