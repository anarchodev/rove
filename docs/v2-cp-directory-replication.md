# V2 — control-plane directory raft-replication (design)

> **Status: Slices 1 + 2 SHIPPED (2026-06-05), Slice 3 (optional) remains.**
> The plan for turning the front door's in-process static `Directory` into a
> replicated, strongly-consistent, HA control plane backed by our own
> `bridge`/`Node` raft substrate. Companion:
> [`project_v2_zero_downtime_move`] memory (the locked Cloudflare+CP+dual-write
> architecture), `docs/v2-build-order.md` §Phase 7, `src-v2/cp/directory.zig`
> (the interface this sits behind), `src-v2/kv/bridge.zig` (the substrate).
>
> **Slice 1 (single-node durable directory) — done + green:** `directory.zig`
> is store-backed over a single-node CP `bridge` (one `__directory__` raft
> group, `apply_on_commit`); the front door requires `REWIND_CP_DATA_DIR` and
> seeds static config only into an empty store. The Slice-1 exit is proven by
> `scripts/cp_restart_smoke.py` (a committed move survives a front-door restart
> — the directory replays instead of re-seeding) + two unit restart tests.
>
> **Slice 2 (multi-node CP HA) — done + green:** the directory raft group
> spans 3 CP nodes (`REWIND_CP_NODE_ID`/`VOTERS`/`PEERS`). (2A) an apply
> observer (`Node.apply_observer`) materializes the in-memory projection from
> REPLICATED applies on the leader AND every follower, so a follower (no local
> proposer) resolves placement too. (2B) leader-gated seeding — only the
> directory leader seeds static config; followers fill via replication. (2C)
> leader-aware writes — `/_cp/leader` reports leadership and a follower
> forwards `/_control/*` to the CP leader (via `REWIND_CP_PEER_URLS`), so an
> operator can target any CP node. v2-test 49/49 (incl. a 3-node directory
> unit test); the Slice-2 exit is proven by `scripts/cp_ha_smoke.py` (seed
> replicates to all 3 nodes; a move issued at a follower commits via forward;
> KILL the leader → a survivor still reads + a fresh move commits on quorum).
>
> See "Implementation decisions" below for two deviations from the original
> sketch.
>
> ## Implementation decisions (Slice 1, as built)
>
> 1. **Reads use an in-memory projection, not `node.get` per request.** Risks
>    #1 (`ClusterRef` ownership) and #2 (cross-thread store reads) below are
>    both resolved by materializing the committed log into the existing
>    pointer-stable `clusters`/`placements` maps: each mutating op proposes a
>    writeset, awaits commit, then updates the map under the mutex; the store
>    is read only once, at boot (single-threaded, pre-pump), to rebuild the
>    projection. So the hot read path stays zero-alloc + pointer-stable
>    (front-door consumers unchanged) and never touches the pump thread's
>    store. **Slice 2A** made this projection update *apply-driven* (not
>    post-commit): an `apply_observer` fires on the leader AND every follower,
>    so a follower with no local proposer stays in sync. That also forced the
>    write path to RELEASE the directory mutex before awaiting commit (the
>    observer takes that mutex on the pump thread, so holding it while awaiting
>    the watermark — which only advances after the observer runs — would
>    deadlock); read-your-write still holds because the observer fires inside
>    `applyCb`, before the commit hook advances the awaited watermark. The
>    replicated `Directory` is therefore heap-allocated (`initReplicated` →
>    `*Directory`, freed by `destroy`) so the observer can capture a stable
>    `self`; teardown stops the pump before freeing it.
> 2. **`REWIND_CP_DATA_DIR` is required (fail loud).** A CP without durable
>    storage loses every committed move on restart, so the front door refuses
>    to start without it rather than defaulting to an ephemeral path that
>    silently re-seeds. Every front-door smoke now sets a fresh per-run path.

## Why

Today `src-v2/cp/directory.zig` is an in-process map seeded from static env
config (`REWIND_CLUSTERS` / `REWIND_PLACEMENT` / `REWIND_HOSTS`), with one
authoritative copy in a single front-door process. Phase 7 made it
**request-critical**: every DP cluster's serve-or-forward reads it
(`GET /_cp/route?host=`) and the move's atomic flip writes it. So the CP must
become **HA** (survive a node failure) and **strongly consistent** (multiple
CP nodes / front doors agree on placement) — a single static copy can't be the
launch CP.

This is the "replicated CP directory" deferred behind the `Directory`
interface since Phase 3, now pulled forward.

## Architecture (locked)

The CP is a **small dedicated cluster** (separate blast radius from the DP
`rewind` clusters), a **separate binary = `rewind-front` evolved**, with
**storage on our own `bridge`/`Node` multi-raft substrate** — dogfood the
exact consensus engine the DP uses (proven through Phases 5–7).

Each CP node runs the CP binary with a **bridge hosting ONE "directory" raft
group** (a fixed gid, e.g. `hashStoreId("__directory__")`), in
`apply_on_commit` mode (NO worker overlay — the CP has no rove-js worker, so
the pump writes the directory store directly on every node, leader included).

### State model (the directory group's kvexp store)

- `cluster/{id}` → comma-joined node origins (e.g. `http://a:1,http://a:2`)
- `placement/{tenant}` → `{state}:{cluster_id}` (`active:cluster-1` /
  `moving:cluster-1`)
- (host→tenant: keep as static `REWIND_HOSTS` for now, or add
  `host/{host}` → tenant later — the domain index is a separate axis.)

### Writes (propose → commit)

`addCluster` / `assign` / `move` / `beginMove` / `abortMove` each encode a
writeset (a `cluster/*` or `placement/*` put) and **propose it through the
directory group**, awaiting commit (`bridge.propose` + `committedSeq`). The
move's directory flip is therefore **one committed raft write** — the same
atomic-commit point the move already treats as authoritative. On commit the
pump applies the writeset to the store on every CP node.

### Reads (local replicated store)

`resolve` / `clusterFor` / `clusterById` read the directory group's store
(`node.get(dir_gid, "placement/{tenant}")` then `cluster/{cluster}`). The
store is kept in sync on all CP nodes by raft, so any node can serve reads
(the leader is strongly consistent; a follower is at most one apply behind —
acceptable for routing, and serve-or-forward + the epoch fence make a slightly
stale read safe).

## Decomposition (build in this order)

### Slice 1 — single-node raft-backed `Directory` (durability + replay) ✅ DONE

Rework `cp/directory.zig` to be **store-backed behind the same interface**, and
give the CP binary a single-node bridge + directory group.
- Replace the in-memory `clusters`/`placements` maps with reads/writes against
  the directory group's store.
- Writes propose + await commit; reads `node.get` + parse.
- Boot: seed `REWIND_CLUSTERS`/`REWIND_PLACEMENT` into the store (propose) if
  empty.
- **Exit:** a directory write (a `move`) survives a CP restart — the raft WAL
  replays the placement writesets and the new owner is still recorded. A
  single-node CP restart smoke.

### Slice 2 — multi-node CP (HA) ✅ DONE

The directory group spans 3 CP nodes (`bridge.initMultiNode`, like `rewind`'s
`REWIND_NODE_ID`/`VOTERS`/`PEERS` → `REWIND_CP_NODE_ID`/`VOTERS`/`PEERS`).
- **Reads from any CP node** — resolved here NOT by `node.get` per request but
  by the apply-driven in-memory projection (2A): `Node.apply_observer` fires
  per committed PUT on the leader AND every follower, so a follower (which
  never proposed) still materializes placement. This is the load-bearing
  change vs. Slice 1 (whose post-commit projection update only ran on the
  proposing/leader node).
- **Writes go to the CP leader.** `directory.isLeader()` + `/_cp/leader` report
  leadership; a follower receiving `/_control/*` forwards the whole request to
  the leader (discovered via `/_cp/leader` across `REWIND_CP_PEER_URLS`) and
  relays the response — so an operator can target any CP node. (A `move`
  proposed locally on a follower would fault; the forward avoids that.)
- **Seeding is leader-gated** — every multi-node CP node boots empty, so only
  the directory leader seeds static config; followers fill via the leader's
  replicated seed (bounded wait for election/replication to settle).
- **Exit (met):** a directory write replicates to all 3 CP nodes; a move
  issued at a follower commits (forward → leader); the CP survives a leader
  kill (a survivor is promoted, still reads, a fresh move commits on quorum).
  `scripts/cp_ha_smoke.py`.

### Slice 3 — DP-side owner cache + invalidation (optimization)

serve-or-forward queries the CP per *miss* today (no hot-path cost). Optionally
cache the owner per tenant on the DP with invalidation on a move, so even the
miss path avoids a CP round-trip. A stale cache stays safe because the
relinquish state + epoch fence are enforced cluster-side, not just by the
directory. (Low priority — the per-miss query already works.)

## Key risks / decisions to resolve during implementation

> Slice 1 resolved #1 + #2 together via the in-memory projection (see
> "Implementation decisions" up top): reads never allocate or touch the store,
> so neither `ClusterRef` ownership nor cross-thread `node.get` ever arises.
> #3 was taken as written (seed only if empty). #1/#2 below are kept for the
> Slice-2 follower-apply path, where the projection must update from applies.

1. **`ClusterRef` ownership.** Today `ClusterRef.nodes` is a borrowed,
   pointer-stable slice into the in-memory `OwnedCluster`. A store-backed
   `resolve` would allocate the node list per call → the consumers
   (`handleCp`, `handleMove`, `handleMoveLive`, `proxyToCluster`) must free it
   (or `resolve` returns an owned `Resolution` with a `deinit`). Touches every
   `resolution.cluster.nodes` site in `src-v2/front/main.zig`. Decide:
   owned-Resolution-with-deinit vs. a short-lived arena per request.
2. **Cross-thread store reads.** The HTTP poll loop calls `resolve` (→
   `node.get`) while the pump thread applies committed writes to the same
   store. For a STABLE directory group (created once) the slot is fixed and
   kvexp reads are MVCC-safe against the pump's write txn — but the bridge's
   stated invariant is "worker threads never touch the Node/Manager." Confirm
   `node.get` is safe to call off the pump thread for a stable group, or route
   reads through a thread-safe seam (a read lease, or an in-memory cache the
   apply hook updates under a mutex).
3. **Seeding + idempotency.** Seeding static config via proposes at every CP
   boot must be idempotent (don't double-apply on restart — the WAL already
   has them). Seed only if the store is empty, or make seeds idempotent puts.
4. **The CP binary still proxies (pre-Cloudflare).** Keep the public
   reverse-proxy in the CP binary for testing without Cloudflare; the locked
   design has Cloudflare replace it later.

## What's reused

- `bridge`/`Node` substrate (single + multi-node, apply_on_commit) — no
  changes expected; the CP is a `rewind`-shaped host with one group and no
  worker.
- The `Directory` *interface* (`resolve`/`move`/`assign`/`beginMove`/
  `abortMove`/`clusterById`) — consumers in `front/main.zig` stay the same
  modulo the `ClusterRef` ownership decision (#1).
- The writeset/envelope codec (`src-v2/kv/envelope.zig`) for the directory
  writesets.
