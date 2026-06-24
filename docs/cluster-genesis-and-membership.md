---
title: Cluster Genesis & Membership — bootstrap-one-then-grow
status: in progress — Phase 1 complete; Phase 2 mechanism landed (production flip gated on Phase-4 smoke). See §6.
date: 2026-06-24
---

# Cluster Genesis & Membership

How a rove cluster is *brought up from nothing* and how nodes *join* it —
and the decision to make that the **only** path, tested the way it really
runs.

## 0. Why this exists (the 2026-06-24 outage)

A wipe-requiring deploy (the format-versioning READSET 6→7 freeze) took prod
down and could not be brought back, because the path a fresh/wiped cluster
actually needs — **cold multi-node genesis** — is both **untested** and
**broken on real nodes**:

- `scripts/deploy.sh` (and the `/deploy` skill) is a **rolling upgrade**: it
  assumes data, a leader, and quorum already exist and swaps binaries one node
  at a time. It cannot bring a cluster up from empty. There is **no genesis
  tool**.
- Every smoke / test starts from an already-running cluster, a single node it
  grows, or an **explicit `campaign()`** (e.g. `bridge.zig` Phase-5c does
  `bridges[0].node.campaign(gid)`; `node.zig isSingleNode` auto-campaigns). So
  "N fresh nodes, started together, elect on their own over a real network"
  has **zero coverage**.
- On prod that path wedged: all 3 CP nodes sat as followers "awaiting
  directory replication", no campaign, no leader — despite a full ESTABLISHED
  transport mesh, present ConfState, and a pinned+ticked directory group. The
  same code elects in 16–30 ms in a single-process 3-bridge repro (sync and
  threaded), so the failure is **environment-specific and not reproducible
  locally**, and there is no `RUST_LOG`/slog lever to instrument raft-rs
  without a rebuild.
- Prod's CP directory was originally grown by an **ad-hoc, by-hand
  single-node-then-grow** that lives in no script and no test.

The conclusion (and the decision): **stop relying on cold multi-node genesis
entirely.** Adopt TiKV's model — a node is configured with *only its own
identity*; a cluster is **bootstrapped on one node and grown** by conf-change.
Make that the *only* way clusters form, and make the tests bring clusters up
*that same way* so the real path is always exercised.

## 1. The decision

1. **Bootstrap-one-then-grow is the only genesis model.** The first node of a
   cluster (CP and worker) bootstraps every raft group as a single-voter
   `{self}` group — which auto-campaigns and leads with no election race.
   Every other node **joins** an existing group as a learner via conf-change
   and is promoted to voter; it never cold-elects.
2. **A node is configured with its own identity only.** No node ever has the
   full voter set, the full peer list, or the full cluster topology in its
   static config. Membership and peer addresses are **learned** from the
   control plane.
3. **Tests bring clusters up the real way.** No smoke or unit test may
   pre-declare a multi-voter group or call `campaign()` to manufacture a
   leader. The harness bootstraps node 1 and grows.

This is aligned with TiKV: a store knows its own id + address; PD holds the
store→address registry and drives region membership; replicas are added by
conf-change, never cold-elected. It also matches rove's pre-launch stance
(`feedback_no_prelaunch_backcompat`): no external users, so we **hard-cut** —
delete the static-config path, don't dual-support it.

## 2. Current state (what's being replaced)

| Concern | Today (static, cold-multi) | Files |
|---|---|---|
| Worker node identity + members | `REWIND_NODE_ID` + `REWIND_VOTERS` (full set) + `REWIND_PEERS` (full `host:port` list) | `src/rewind/main.zig:428-490` (`parseMultiNode`) |
| CP node identity + members | `REWIND_CP_NODE_ID` + `REWIND_CP_VOTERS` + `REWIND_CP_PEERS` (+ `REWIND_CP_PEER_URLS`) | `src/cp/main.zig:101-150` (`parseCpMultiNode`) |
| Group birth membership | `voters_override` (cp-ssot, from `clusterVotersCsv(nodes.len)`) **or** `self.voters` (`REWIND_VOTERS`) → born with the **full** set → cold-multi | `src/consensus/node.zig` `createGroupCore` (~830-915); `src/cp/main.zig:616-625` |
| Transport peer address | raft id → **positional index** `node_id - 1` into the static peer array | `src/consensus/transport.zig` (peer_id = node_id-1); `src/kv/raft_net.zig` |
| Cluster topology | `REWIND_CLUSTERS=prod={all node urls}` seeds `cluster/{id}`; `/_control/cluster` updates it | `src/cp/main.zig:538-565` (`handleCluster`); `directory.zig` `addCluster` |
| Tenant-group growth | RC-6 reconciler: conf-change AddLearner→promote per placed tenant toward the cluster node set | `src/cp/main.zig:966-1000` (`reconcileMembership`), `1440-1455` (`reconcileConfChange`) |
| CP directory growth | **none** — the reconciler only does tenant groups; the directory group is born at its static `REWIND_CP_VOTERS` and never grows | — (the gap) |

Key facts learned 2026-06-24:
- A **single-node** bridge has **no transport** (`initSingleNode`); handing it
  a multi-node group → SIGSEGV. So "born `{self}`" and "single-node bridge"
  must go together, and growth requires a transport that can dial newly-added
  peers.
- The **recovery-confstate fix** (`c1f022c`) correctly stopped `initRecover`
  from reseeding membership off static voters on restart — which also removed
  the accidental "restart with a wider voter env → silently grow" path prod
  historically leaned on. Good: that path was the fork-bug vector. But it
  means growth must now be **explicit conf-change**, never config+restart.

## 3. Target model

### 3.1 Node configuration (self-only)

A node is configured with exactly:

- `REWIND_NODE_ID` — this node's own raft id (one integer). *(CP analog:
  `REWIND_CP_NODE_ID`.)*
- a **self raft transport address** — this node's own `host:port` for the
  worker raft-net and for the CP directory raft. New: `REWIND_RAFT_ADDR` /
  `REWIND_CP_RAFT_ADDR` (or derive from a bind addr + fixed port). One value,
  its own — never the peer list.
- `REWIND_CLUSTER_ID` — the cluster this node belongs to.
- `REWIND_CP_URL` — the CP endpoint(s) this node talks to (to register itself
  and to be told its membership). For a CP node, how it reaches the directory
  leader once one exists.

**Deleted:** `REWIND_VOTERS`, `REWIND_PEERS`, `REWIND_CP_VOTERS`,
`REWIND_CP_PEERS`, `REWIND_CP_PEER_URLS`, `REWIND_CLUSTERS` (as a multi-node
seed), `REWIND_PLACEMENT`, `REWIND_HOSTS` (static seeds), and the all-nodes
CLI params. Single-node `REWIND_CLUSTERS=prod=http://self` is also gone — a
fresh node is single-node by *construction* (no peers known), not by config
shape.

### 3.2 The directory as the node-address registry (SSOT)

The CP directory gains an explicit **node registry**: `node/{cluster}/{id}` →
`{raft_addr, cp_raft_addr, http_url}` (or fold into `cluster/{id}`). This is
the rove analog of PD's store-address table. The CP is the single source of
truth for raft id → transport address, for both worker tenant groups and the
CP directory group.

### 3.3 Dynamic peer-address resolution (the load-bearing change)

The raft transport stops indexing a static peer array. Instead it resolves
raft id → address through a **PeerResolver** fed by the CP membership:

- The worker learns peer addresses from the CP (pushed on attach/conf-change,
  or pulled from the directory node registry). `transport.zig` /
  `raft_net.zig` dial a peer the first time a message is addressed to an id it
  hasn't connected to yet; the address comes from the resolver, not config.
- conf-change (`/_system/v2-confchange`) and attach (`/_system/v2-attach`)
  **carry the joining node's transport address**, so existing members can dial
  it the moment it's added.
- The CP directory group uses the same resolver, fed by the CP node registry.

This is the piece that *enables* deleting the static peer lists; it must land
**before** the env vars are removed, or every grow crashes the way prod did.

### 3.4 Genesis

- **First node of a cluster**: a one-time genesis action (a `rewind-ops
  genesis` control call, or a `--genesis` first-boot flag consumed once)
  bootstraps the CP directory as `{self}` (single-voter, auto-campaign →
  leader) and registers itself in the node registry. The worker likewise
  creates tenant groups (as they're provisioned) born `{self}`.
- **`createGroupCore`** loses the "born with the full voter set" path: a
  freshly-created group is always `{self}` (the creating node), grown later.
  `voters_override` becomes "the set the CP is bootstrapping/attaching onto
  this node" for the move/attach path only.

### 3.5 Grow

Adding node K to a cluster:

1. `rewind-ops node add {cluster} {id} {raft_addr,...}` → CP writes the node
   into the directory registry (replicated).
2. The CP grows membership by conf-change AddLearner→promote — for **every
   group that should live on K**:
   - **Tenant groups**: the RC-6 reconciler already does this
     (`reconcileMembership`). It keeps working, now driven by the node
     registry instead of `REWIND_CLUSTERS`.
   - **CP directory group**: NEW — the CP self-reconciles its own directory
     membership toward the registered CP nodes (an analog of the tenant
     reconciler, but for the directory group: AddLearner the new CP node,
     replicate the directory log to it, promote). This closes the
     "grow-from-{1}" gap that blocks CP HA today.
3. K boots self-only, registers, and is brought in as a learner; it never
   campaigns. The directory leader (and each tenant leader) replicates to it.

### 3.6 What about the cold-multi-election bug?

Sidestepped by construction — we never cold-elect a multi-voter group, so the
unreproducible prod election failure can't occur. Its **root cause stays
unknown** (works in single-process repro, fails on real nodes). We accept
sidestepping over root-causing, but record it as an open item: if we ever
*need* a node to campaign without a pre-existing leader (we shouldn't), this
bites again.

## 4. Test & harness changes

The point of the whole exercise: **tests bring clusters up the real way.**

- `scripts/smoke_lib_v2.py` `V2Cluster.spawn`: today spawns N nodes with the
  full static voter/peer config (cold-multi). Change to: spawn node 1 as
  genesis (self-only + genesis action), wait for it to lead, then for each
  further node spawn it self-only and **grow** it in via the real
  `node add` + reconciler path; assert it joins as learner→voter. No node ever
  gets a voter set.
- **New `scripts/genesis_smoke_v2.py`** (the CI gate we never had):
  from-empty, multi-process, real-transport 3-node bring-up → genesis node 1 →
  grow to 3 → provision + publish a tenant → serve a 200 → kill the leader →
  a follower takes over. Run in `zig build`-gated CI and as the mandatory gate
  before any wipe-requiring deploy. If it ever fails the way prod did, we now
  have the failure in a harness we can attach to.
- Unit tests (`bridge.zig`, `node.zig`): remove the `campaign()`-to-bootstrap
  pattern from multi-node tests; a multi-node test must grow from a
  single-voter genesis. Keep `campaign()` only where it's the unit under test.
- All existing `*_smoke_v2.py` inherit the realistic bring-up via `V2Cluster`.

## 5. Deploy tooling changes

- **New `scripts/genesis.sh`** — bring up a fresh cluster: genesis node 1
  (CP + worker), then grow to N via `rewind-ops node add` + wait for the
  reconciler to converge each group. Idempotent (re-run = no-op once formed).
  Wipe-requiring deploys (format changes) go through this.
- **`scripts/deploy.sh`** — stays rolling-upgrade-only; add a precondition
  guard that **refuses** if the cluster isn't already up + healthy (it must
  never be mistaken for a genesis tool).
- **`/deploy` skill + `docs/v2-production-deploy-plan.md`** — split **genesis**
  from **rolling upgrade**; document that a wipe-requiring deploy = teardown →
  genesis, not rolling. Update the `/deploy` SKILL to detect and redirect.

## 6. Phased implementation

1. **PeerResolver + node-address registry** (§3.2, §3.3) — the enabler. Add
   the directory node registry; route the transport's peer addressing through
   a resolver fed by it; carry addrs on attach/conf-change. Keep static config
   working until this is proven, then it's dead weight.
   - **1a — DONE.** `PeerResolver` seam (`raft_net.zig`) + dynamic `Transport`
     sizing (`transport.zig`): destination buffers + the `raft_net` peer table
     size to `MAX_CLUSTER_NODES` (16); `queueOut` lazily resolves + `addPeer`s a
     node id beyond the init set; default resolver is static-over-`peers`, so
     statically-configured clusters are byte-identical (all 62 prior tests +
     real-socket 3-node node tests green). Growth branch teeth in two new
     `transport.zig` tests. (`raft_net`'s `addPeer`/`removePeer` already existed
     but had no callers — the resolver is the first driver.)
   - **1b — DONE.** Directory node-address registry (`directory.zig`):
     `node/{cluster}/{id}` → packed `{raft_addr, cp_raft_addr, http_url}`
     (version byte, tab-joined) with projection map, replay scan, `setNodeAddr` /
     `nodeAddrOwned` / `listClusterNodeAddrs`, and a leader-gated
     `POST /_control/node-address` handler (`cp/main.zig`). Full three-field
     shape stored now so Phase-2 CP-directory self-grow needs no migration.
     Unit-tested in `directory.zig`. Nothing reads the registry yet — that's 1c.
   - **1c — DONE.** Worker resolver fed from the registry + conf-change carries
     the joining node's address:
     - `PeerRegistry` (`node.zig`) — insert-only id→addr map; the `Bridge` owns
       one (`enablePeerRegistry` / `learnPeer` / `learnPeerAddr`) and injects its
       resolver via `Transport.setResolver` (a pre-pump setter, like
       `setStoreResolver`). The worker enables it and **seeds it from the static
       `REWIND_PEERS`**, so today's behavior is unchanged but addressing now runs
       through the registry — Phase 3 just drops the static seed.
     - `/_system/v2-confchange` carries an optional `raft_addr`; the worker
       `learnPeer`s it before proposing, so the leader can dial a newly-added
       node the moment the add commits. The CP reconciler (`ensureMember` →
       `reconcileConfChange`) sources it from the directory registry
       (`raftAddrFor` → `nodeAddrOwned`). Empty/absent for a still-static cluster
       → falls back to static peers.
     - Proven by a deterministic `node.zig` test: a leader replicates a committed
       write to a node it knows **only** via the resolver (omitted from its
       static peers). Added `raft_net.isPeerConnected` for the
       connection-gated, race-free election in that test.
     - **4d attach-carry — DONE.** The *attach* direction: the reconciler's
       bootstrap attach (`bootstrapMember`) now carries the existing members'
       raft addresses as `X-Rewind-Peer-Addrs: id@host:port,…`
       (`peerAddrsHeader` ← `listClusterNodeAddrs`, joiner skipped); the worker's
       `handleAttach` `learnPeerAddr`s each BEFORE the group is created, so a
       genesis-booted joiner (empty peer registry) can dial the leader to ACK its
       appends the moment the first one lands. Closes the reverse of 1c's
       conf-change `raft_addr` (leader-learns-joiner). Header omitted on a
       static-`REWIND_PEERS` cluster (registry empty → no-op).
2. **Single-voter genesis + CP-directory self-grow** (§3.4, §3.5) — groups
   born `{self}`; the CP grows its own directory group; tenant reconciler reads
   the registry. Now a cluster can genesis-1-then-grow end to end.
   - **2a/2b mechanism — DONE (additive, not yet wired into production).**
     `createGroupCore` now campaigns-to-leader at birth when this node is the
     group's SOLE voter — either a single-node node OR a multi-node node birthing
     a group as `{self}` (`born_sole_self`). A born-`{self}` group leads
     immediately with no election race; a born-multi group still elects via
     ticks (unchanged). The born-`{self}` membership itself rides the existing
     `voters_override` param (`= {self.node_id}`). Proven by a deterministic
     `node.zig` test: a multi-node node births a group `{self}`, auto-leads, then
     grows to a second node by `add_learner` conf-change and replicates a write.
     **Additive**: no production caller passes `voters_override={self}` yet
     (provision still births the full set), so production behavior is unchanged.
   - **2d provision-flip — DONE (reconciler-gated).** `handleProvision` now
     births the group as the sole voter `{1}` on the FIRST node only when a
     membership reconciler is present (`reconcile_membership`) — it auto-leads
     (no election race) and the RC-6 reconciler grows it to the full node set
     learner-first (riding 4d's attach-carry). A cluster with NO reconciler keeps
     the legacy born-multi formation (full node set on every node), so static
     clusters are unchanged. The genesis smoke (reconciler ON) validates the
     born-`{self}`+grow path end to end.
   - **REMAINING (gated on the Phase-4 genesis smoke).** Flipping production is
     the risky, behavior-changing half and — per the 2026-06-24 outage (an
     unvalidated genesis path took prod down) — must NOT land before a
     multi-process from-empty smoke can validate it:
     - **2c — CP directory self-grow.** The directory group is born via
       `ensureGroup(recover=true)` → `initRecover(self.voters)` (full
       `REWIND_CP_VOTERS`); it never grows. Genesis wants it born `{self}` on a
       fresh CP and grown toward registered CP nodes (analog of the tenant
       reconciler, on the directory group). Requires distinguishing FRESH (born
       `{self}`) from RESTART (recover the WAL confstate) in the directory init —
       new consensus code (§7), validated by the genesis smoke.
3. **Delete static config** (§3.1) — remove the voter/peer/cluster env + CLI;
   node = self-only. Hard cut (pre-launch).
4. **Harness + genesis smoke** (§4) — reshape `V2Cluster`; add
   `genesis_smoke_v2.py` as the CI gate; de-`campaign()` the unit tests.
   - **Genesis binary mode — DONE (worker).** `isSingleNode()` redefined to
     `transport == null` (was `voters.len == 1`) so a genesis node — which has a
     transport but `voters = {self}` — tracks the real leadership atomics and is
     correctly demoted to follower once a group it created grows (all 7 call
     sites are "no peers / always leader / nothing to transfer", which is exactly
     "no transport"). `raft_net` init sets up the self slot from `node_id` even
     when the static `peers` list is empty/short (self-only boot). New
     `Node.initGenesis` / `Bridge.initGenesis` (own id + raft addr, no
     voters/peers, transport + empty `PeerRegistry` resolver). Worker boots
     genesis when `REWIND_NODE_ID` + `REWIND_RAFT_ADDR` are set and
     `REWIND_VOTERS`/`REWIND_PEERS` are absent (`parseGenesis`). Verified: the
     worker boots genesis (`genesis node id=1 …` → `listening on …`); a unit test
     stands up TWO genesis nodes (self-only, registry-only addressing, no static
     peers) that form a born-`{self}` group and grow it by conf-change +
     replicate (deterministic 6/6). CP genesis mode (single-node CP already
     births its directory `{self}` via `isSingleNode`) + the smoke script remain.
5. **genesis.sh + deploy split + docs** (§5).
6. **Bring prod back** on the new path — genesis node 1, grow to 3. This is
   the first real exercise of the codified path (and validates it end to end).

Each phase is independently testable; 1 and 2 are the substance, 4 is what
makes it stick.

## 7. Risks / open questions

- **Dynamic peer addressing touches the hot raft transport.** Must not regress
  the coalesced-frame path (the deliberately-shrunk 20B record header) or
  correctness. Resolve lazily + cache; benchmark.
- **Genesis idempotency / split-brain.** The genesis action must be safe to
  run once and only once per cluster; a second genesis on an already-formed
  cluster must be a no-op, never a second single-voter group. Gate on "is the
  directory already formed?".
- **CP-directory self-grow** is new consensus code (conf-change on the CP's own
  group). It's the analog of the tenant reconciler but on the directory; needs
  the same care (learner→catch-up→promote, no premature promote).
- **Cold-multi-election root cause** stays unexplained (see §3.6). Acceptable
  because we no longer depend on it, but logged.
- **Address changes / re-IP.** The registry must support a node's address
  changing (re-register; transport re-dials). Out of scope for v1 but the
  registry shape should not preclude it.
