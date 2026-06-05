# V2 Phase 5 — multi-node clusters (HA + durability)

> **Status (2026-06-04). IN PROGRESS — the consensus core is proven.**
> Slices 5a (cross-node transport) + 5b (multi-node Node: election +
> replication + failover) are DONE + committed (`945962a`), green under
> `v2-test`. A 3-node cluster elects a per-tenant leader, replicates
> committed writes to every node, and survives a leader kill (re-elect +
> keep committing + durability) — over real loopback TCP. Remaining: 5c
> (multi-node bridge), 5d (move fan-out), 5e (rewind multi-node config +
> 3-node smoke). Companion: [`v2-build-order.md`](v2-build-order.md)
> §Phase 5 (the spec), [`v2-multiraft-scaling-learnings.md`](v2-multiraft-scaling-learnings.md)
> §3.2–3.4 (the transport/fsync/mailbox constraints this implements).

## Why Phase 5

Phase 4 proved mobility (the milestone) on single-node clusters; mobility
does not need quorum, but HA + durability do. Phase 5 makes each tenant's
raft group span 3 nodes so a node failure loses neither availability nor
data. It is launch-required hardening, not a new capability.

## 5a — cross-node transport (`src-v2/kv/transport.zig`) — DONE

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

## 5b — multi-node Node (`src-v2/kv/node.zig`) — DONE

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

## Remaining

### 5c — multi-node bridge

- **Seq ↔ commit binding under leadership change.** The single-node bridge
  counts (Nth commit = seq N) because every propose commits in order. Multi-
  node breaks that: a propose can fail (not leader) or leadership can change
  mid-flight. Replace counting with an explicit per-entry seq (a pending-seq
  FIFO per tenant, or a framed seq prefix) so the watermark stays exact.
- **Per-group leadership.** `isLeader()` becomes `isLeader(gid)`; a propose
  to a follower must surface "not leader" so the worker/front-door can
  retry against the leader node. Routing inbound writes to a tenant's
  current leader node is the front-door's job (leader-aware placement).

### 5d — move fans out to all destination nodes

`v2-attach` must `createGroupEpoch` on **all** destination nodes (the
group is formed across the destination cluster), and evict destroys it on
all source nodes. The front door fans the attach/evict out to each node
(or the destination leader coordinates).

### 5e — rewind multi-node config + 3-node smoke

`rewind` gains multi-node config (this node's id, the peer list, per-node
data dirs). `scripts/three_node_smoke.py`: form a 3-node cluster, serve a
request, kill a node and survive (failover), move a tenant onto a 3-node
destination. The Phase-5 exit.
