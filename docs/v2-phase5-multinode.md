# V2 Phase 5 — multi-node clusters (HA + durability)

> **Status (2026-06-04). DONE — the Phase-5 exit is proven.**
> Slices 5a (cross-node transport, `945962a`) + 5b (multi-node Node:
> election + replication + failover, `945962a`) + 5c (multi-node bridge:
> FIFO seq binding + role-aware apply, `fb79732`) + 5d (move fan-out to all
> destination nodes) + 5e (rewind multi-node config + leader-aware
> front-door routing + Full-HA store unification + the 3-node smoke) are
> DONE, green under `v2-test` (40/40). `scripts/three_node_smoke.py` moves a
> live tenant onto a 3-node destination cluster (attach fans out to every
> node, forming the group across the cluster), serves it through the front
> door's leader-aware routing, **kills the destination LEADER**, and a
> promoted follower serves the data it replicated — then a fresh write
> commits on the surviving 2-node quorum. The single-node milestone smokes
> (`tenant_move` / `two_cluster` / `rewind`) still pass.
> Companion: [`v2-build-order.md`](v2-build-order.md)
> §Phase 5 (the spec), [`v2-multiraft-scaling-learnings.md`](v2-multiraft-scaling-learnings.md)
> §3.2–3.4 (the transport/fsync/mailbox constraints this implements).

## Why Phase 5

Phase 4 proved mobility (the milestone) on single-node clusters; mobility
does not need quorum, but HA + durability do. Phase 5 makes each tenant's
raft group span 3 nodes so a node failure loses neither availability nor
data. It is launch-required hardening, not a new capability.

## 5a — cross-node transport (`src/consensus/transport.zig`) — DONE

Reuses the V1 liburing wire layer (`src/kv/raft_net.zig` + its frame codec
`raft_rpc.zig`, both std-only; the V1 raft message types are unused) and
adds **per-recipient coalescing** (multiraft-scaling-learnings §3.3): each
pump cycle, a node's groups produce outbound messages addressed to peer
nodes (`Manager.takeMessages` → `(to, bytes)`); the transport buffers them
per destination and flushes **one envelope per peer** carrying every
group's messages to that peer, each stamped with its group's migration
epoch. The receiver decodes the envelope and `stepBatch`es the lot into its
Manager in one FFI call — O(peers) syscalls/steps, not O(groups).

Wire format (the payload `raft_net` frames + CRC-checks for us):

    [count:u32 LE]  then count × [group_id:u64 LE][epoch:u64 LE][len:u32 LE][bytes]

Node-id mapping: raft-rs ids are 1-based (etcd/raft reserves 0); raft_net
peer ids are 0-based array indices. The transport owns the single
`peer_id = node_id - 1` conversion at the send boundary.

## 5b — multi-node Node (`src/consensus/node.zig`) — DONE

- `initMultiNode(node_id, voters, listen_addr, peers)` stands up the Node
  with the transport bound to `&self.mgr`. `initSingleNode` unchanged.
- `createGroupCore` skips the campaign-to-leader for multi-node (it would
  race peers that have not yet created the group); election fires via
  `tickGroups` election timeouts, or an explicit `campaign(gid)` for a
  fast/deterministic bootstrap. `isLeader(gid)` exposes per-group
  leadership.
- `pump()` drains each ready group's outbox into the transport (stamping
  the group's epoch via `sendMsgCb`), flushes the coalesced sends, and
  drives a **non-blocking** `transport.tick` every cycle — so
  heartbeats/elections flow and inbound messages step even on an idle
  node. The single-fsync-per-cycle WAL flush is unchanged.

Threading: the transport's `queueOut`/`flush`/`tick` and its `onRecv`
(which `stepBatch`es inbound) all run on the pump thread — the only
Manager toucher — so inbound stepping is on-thread and lock-free.

**Proof (v2-test):** a 3-node test stands up three Nodes on loopback,
creates one tenant group on all three, elects node 1, replicates a write
to all three stores, then **kills the leader** and asserts the two
survivors re-elect, commit a fresh write (quorum = 2), and still hold the
pre-failover value. (Fixed peer ports with a PID-strided, bind-retry
allocator so the node + bridge test binaries — bridge imports node.zig —
run in parallel without colliding.)

## 5c — multi-node bridge (`src/consensus/bridge.zig`) — DONE

- **Deterministic gid.** `registerTenant` hashes the tenant id (Wyhash) to
  the raft group id instead of a local counter — a group spans all nodes,
  so every node must derive the SAME id or replication can't bind the
  incarnations together.
- **Role-aware apply** (`ApplyMode.worker_overlay`): the pump skips the
  store write on the **leader** (the worker's `TrackedTxn.commit` is the
  durable write) but writes it on a **follower** (no worker there). That is
  how followers stay in sync and how a tenant's data is present on the
  survivors after a leader failure.
- **Explicit per-entry FIFO seq binding** replacing Phase-2 counting.
  Counting is wrong multi-node: (a) a propose can fail (not leader) so its
  seq never commits, and (b) a follower applies entries replicated from
  another leader, with no local proposer. `propose` pushes its seq onto a
  per-tenant `pending` FIFO; the commit hook pops the front **only when
  this node leads**; a propose that can't commit here is **faulted** (at
  submit when `node.propose` rejects, or by a per-cycle leadership-loss
  sweep over the in-flight set) so the parked worker fails fast (503) and
  the client retries the leader. A write in flight at the instant of a
  leader change is faulted + retried, not lost — live re-fencing under
  continuous load is Phase 7.

**Proof (v2-test):** a 3-bridge cluster asserts gid agreement across nodes,
leader replication to every store, the exact FIFO watermark, and a
follower-propose fault.

## 5d — move fans out to all destination nodes — DONE

The Phase-4 move targeted single-node clusters. A cluster is now a **set of
node origins** (`cp/directory.zig`: `ClusterRef.nodes`, config
`id=url1,url2,url3`). The front-door move orchestrator (`front/main.zig`)
fans out:

- **bundle** from the source LEADER. `v2-bundle` is now leader-gated (a
  follower 421s), so the orchestrator tries each source node until one
  returns the bundle — the leader is the only node taking live writes, so
  quiescing it is what makes the snapshot consistent.
- **attach** on **every** destination node (`attachToAll`): each loads the
  bundle into its own `inst.kv` and `createGroupEpoch`s its incarnation at
  the migration epoch, so the group forms across the whole destination
  cluster. All must 204; on any failure the partially-attached set is
  evicted and the source resumed.
- **await election**: poll each destination node's new `v2-leader` probe
  until one reports leadership, so post-move traffic finds a leader
  immediately instead of cycling 503s through an un-elected group.
- **flip** the directory (the commit point), then **evict** on every source
  node (`evictAll`).

### 5e — rewind multi-node config + leader-aware routing + Full HA — DONE

**Config (`rewind/main.zig`).** `REWIND_NODE_ID` / `REWIND_VOTERS` /
`REWIND_PEERS` (comma-separated raft transport `host:port`s, indexed by
raft id − 1, DISTINCT from the HTTP port) select `Bridge.initMultiNode`;
unset → single-node. `parseMultiNode` resolves the listen address from
`peers[node_id − 1]`.

**Leader-aware front-door routing.** A multi-node cluster has N node origins
but only the tenant's group leader takes writes. `proxyToCluster` tries
nodes in order and stops at the first non-503 — a follower 503s a write
(the bridge faults a non-leader propose), so a write self-routes to the
leader; a read is served by any node (the follower stores are synced). The
worker leader-gates `v2-kv` PUT too (registers + `isLeaderOf`), so a
follower rejects fast WITHOUT a speculative local write that would diverge
(this immediate-commit endpoint, unlike the parked customer path, has no
undo).

**Full-HA store unification (the load-bearing fix).** The bridge node kept
a per-tenant store at `{data_dir}/{gid}/app.db`, but the worker serves from
`{data_dir}/{id_str}/app.db` (`inst.kv`). On a leader, `worker_overlay`
skips the node-store write (the worker's `TrackedTxn.commit` is durable),
so the node store sat unused; on a follower the pump wrote the *node* store
— a file the worker never reads. A follower promoted to leader would serve
an **empty** `inst.kv`. Fixed with a **`StoreResolver`** (`node.zig`): in
`worker_overlay` mode a follower's apply resolves the worker's own
`inst.kv` (provisioned on demand via the node tenant, wired in
`rewind/main.zig` before `startPump`), so a follower replicates into the
SAME store it will serve from after promotion. `isLeaderOf(gid)` is
published as a per-group atomic refreshed each pump cycle (the worker must
never touch the non-thread-safe Manager).

**Envelope frame fix (latent since Phase 1).** The worker proposes a
readset-framed type-0 payload (`[u32 ws_len][ws][u32 rs_len][rs]`, from
`src/js/apply.zig`), but the V2 node applied `env.payload` as raw writeset
bytes. A single-node leader skips apply, so the mismatch never surfaced —
until a real follower applied a worker entry. `envelope.zig` now owns the
byte-identical `WriteSetPayload` codec and `node.applyEntry` strips the
frame (`decodeWriteSetPayload`) before `writeset.applyEncoded`; the readset
rides for the tape.

**Exit smoke.** `scripts/three_node_smoke.py` — see the status block above.

## Known follow-ups (not Phase-5 blockers)

- **Zero-downtime / live re-fencing (Phase 7).** A write in flight at the
  instant of a leader change is faulted + retried (503), not lost; moving a
  tenant under continuous load with zero failed requests is Phase 7.
- **Initial multi-node placement without a move.** A tenant's group forms
  on a multi-node cluster via the attach fan-out (a move-in). Placing a
  brand-new tenant directly on a multi-node cluster (no move) would need an
  explicit formation step; today the smoke forms the group by moving onto
  it. `v2-kv` PUT leader-gating depends on the group already existing.
- **Replicated control-plane directory.** The front door still holds the
  one authoritative `Directory` from static env config; a replicated CP
  directory (so multiple front doors agree on placement) is later
  hardening behind the same interface.
