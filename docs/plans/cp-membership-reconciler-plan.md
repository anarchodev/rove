# CP membership reconciler — plan

A CP-side, leader-gated, **additive-only** reconciler that converges each tenant's
DP raft-group membership to the directory's desired state (`cluster.nodes`), via
**learner-first** joins — so growing a cluster + backfilling a new node becomes a
non-event, and the `REWIND_VOTERS` / `REWIND_CLUSTERS` drift class disappears.

Status: design locked (this doc), not yet built. Substrate it builds on
(conf_change, snapshot/baseline bootstrap, `voter_progress`) is **already
shipped** — see `docs/plans/raft-best-practices.md` and the promote-back work
(`27beb49`, `b1367ee`).

## Why

A 3rd node (`bhs-3`) was brought up fresh on a cluster that had been running 2
nodes. The per-tenant groups report ConfState `voters:[1,2,3]` — so node 3 is
nominally a voter — yet node 3 holds zero group instances and receives no raft
traffic: a **phantom voter**. Root cause is two independent "which nodes" lists
that drifted:

- **Raft voter set** (`REWIND_VOTERS=1,2,3`) → every group's initial ConfState is
  `voters:[1,2,3]`.
- **CP cluster node list** (`REWIND_CLUSTERS=prod=node1,node2`) → `attachToAll`
  only ever formed groups on **2** nodes.

The CP has no operation to reconcile this — `provision` is create-only and forms
groups on the *current* cluster node list; its reconcile loop only recovers stuck
moves. So a node added after tenants exist is never backfilled. This is the
"fresh voter joins existing groups" gap; it is distinct from the conf_change
*promote-back* (which re-promotes a previously-demoted member that already had the
group).

## Model: the CP is a reconciler

The CP mediates two states:

- **Desired** = the replicated directory: clusters (and their nodes), placements
  (tenant→cluster), host→tenant, plan, cert. Pure replicated KV.
- **Actual** = the DP reality: which per-tenant raft groups exist on which nodes,
  each node's role (learner/voter), and catch-up.

Today's operations conflate the two: `provision` = "declare placed" + "form the
groups now"; `move` = "re-place" + "snapshot/load/flip/evict". That conflation is
why every new scenario (grow, backfill, deprovision) needs a brand-new compound.

The minimal orthogonal set separates them:

- **Directory desired-state CRUD** — `cluster.set(id, nodes)`,
  `tenant.place/unplace`, `host.set/unset`, `plan.set/unset`, `cert.set/unset`.
  Trivially safe, idempotent, replicated.
- **Per-node group membership** — `addMember(tenant, node)` (learner-first:
  bootstrap → join as learner → catch up → promote), `removeMember`,
  `snapshot(tenant)`. Most of this substrate already exists.

Then every operation collapses to "write desired state, reconcile membership":
`provision` = place + addMember∀node; `move` = re-place + addMember(new) +
removeMember(old); **grow/backfill** = `cluster.set(+node)` + addMember∀tenant;
`deprovision` = unplace + removeMember∀node.

The current DP-lifecycle verbs are `attachToAll` / `evictAll` — **all-nodes**
granularity. The missing primitive is **per-node** membership; that's the whole
gap, and it generalizes far beyond bhs-3.

## Narrow declarative: where the reconciler lives + what it does

**Where:** in `rewind-cp`, gated to the directory-raft **leader**, as an extension
of the loop that already runs `reconcileStuckMoves`. Forced by the architecture:
it needs the authoritative desired state (the directory, read locally); it must be
a single writer (one orchestrator issuing conf-changes per group, or two race);
and it fails over with leadership. Same interval (`REWIND_CP_RECONCILE_SECS`) plus
an event-kick on `cluster.set`/`place`.

**Invariant — additive-only:** every action increases replication/availability.
The reconciler **never** removes, shrinks, migrates, destroys, or invents. That
single bound is what makes a continuous unattended actor safe: it can't lose data
or quorum (worst case is a wasted/retried pass), it can't flap (additive is
monotone → converges then no-ops), and even a *buggy* observation can only cause a
redundant no-op, never harm. Everything destructive or data-moving stays an
explicit, operator/orchestrator-driven action.

It defers to in-flight explicit ops: a `moving`-flagged tenant is skipped entirely
(as `reconcileStuckMoves` already does). `provision`/`move` stay imperative —
operators need a synchronous success/failure answer and atomic rollback that a
lazy reconciler can't give. The reconciler is the always-on *healer* of drift, not
a replacement for the compounds; both share the same primitives.

## The reconcile pass

```zig
// rewind-cp, directory-leader-gated. Runs next to reconcileStuckMoves, on the
// same interval + event-kicked on cluster.set/place. ADDITIVE-ONLY.
fn reconcileMembership(self: *Router) void {
    if (!self.directory.isLeader()) return;                 // single writer
    for (self.directory.placements()) |tenant| {            // desired state
        const res = self.directory.resolve(tenant) orelse continue;
        if (res.moving) continue;                           // defer to in-flight move
        const cluster = res.cluster;                        // desired membership = cluster.nodes
        const leader_url = self.findDestLeaderUrl(cluster.nodes, tenant) orelse continue;
        for (cluster.nodes) |node| {                        // one node per group per pass
            const st = self.memberStatus(node, tenant, leader_url); // OBSERVE actual
            if (st.caught_up_voter) continue;               // already good → no-op
            self.advanceMember(tenant, node, cluster, leader_url, st) catch |e|
                std.log.warn("reconcile {s}@{s}: {s} (backoff)", .{ tenant, node, @errorName(e) });
            break;                                          // re-observe next pass
        }
    }
}

// One (tenant,node): absent → learner(catching up) → voter. One step per call.
fn advanceMember(self, tenant, node, cluster, leader_url, st) !void {
    if (!st.hosted) {
        const bundle   = try self.snapshotFromLeader(leader_url, tenant);    // GET v2-snapshot          [built]
        const baseline = try self.appliedBaseline(leader_url, tenant);       // GET v2-applied-baseline   [built]
        try self.attach(node, tenant, bundle);                               // POST v2-attach            [built]
        try self.applySnapshot(node, tenant, baseline.index, baseline.term); // POST v2-apply-snapshot    [built]
        if (st.role == .none) try self.confChange(leader_url, tenant, node.id, .add); // AddLearner       [built]
        return; // let raft replicate the tail; next pass promotes
    }
    if (st.role == .learner) {
        if (st.caught_up) try self.confChange(leader_url, tenant, node.id, .promote); // AddNode          [built]
        return;
    }
    // role == .voter but !caught_up → already a member; raft is replicating. Wait.
    // (This is today's bhs-3 phantom-voter case once the group exists locally.)
}
```

`memberStatus` is the **one observation primitive that needs building**:
`hosted` = node has a local group instance (`GET v2-confstate` 200 vs 404);
`role` from the leader's ConfState; **`caught_up` from the leader's PER-PEER
progress** (`matched ≈ last_index && recent_active`) — *not* ConfState, which
lies (bhs-3 is in `voters` with `matched=0`). The engine layer exists
(`voterProgress`, used by auto-demote); it just isn't on the wire.

## Phases

### Phase 1 — observation endpoint (DP)
`GET /_system/v2-member-status?tenant=T` in `src/js/v2_move.zig` (move-secret,
leader-only). Compose `voterProgress()` + `confState()` → per-peer
`{id, role, matched, recent_active}` + `leader`/`last_index`. **Size: small** —
pure read, engine support already shipped. Useful immediately as a bhs-3
diagnostic even before the reconciler.

### Phase 2 — directory primitives
- `directory.placements()` iterator in `src/cp/directory.zig` (today only
  `resolve(one)`/`collectMoving`).
- `POST /_control/cluster {id, nodes:[{id,url}]}` in `cp/main.zig` — the **grow**
  primitive; wire the already-replicated `directory.addCluster`; same
  move-secret + leader-forward as other `/_control/*`.
- Cluster node model carries the explicit raft `id` (`{id,url}`), so conf-change
  has the id without fragile positional `nodes[i]→voter i+1` inference.

**Size: small–medium.** Additive; no behavior change.

### Phase 3 — `ensureMember` primitive (compose) — riskiest
The per-node state machine, composed in `cp/main.zig` from existing endpoints
(`v2-snapshot`, `v2-applied-baseline`, `v2-attach`, `v2-apply-snapshot`,
`v2-confchange`). **The risk:** `v2-attach`/`createGroupEpoch` was written for
*moving a tenant to a new cluster at a new epoch*, not *adding a replica to an
existing same-cluster group* — epoch/membership semantics must be verified
(wrong epoch → fenced → split-brain).

**HARD GATE before Phase 4:** provision a throwaway tenant on a 2-node cluster,
run the `ensureMember` sequence to add the 3rd node by hand, assert it becomes a
**caught-up voter** *and a fresh write replicates to all 3*. Only then build the
loop. (This is also the verification owed before touching real prod tenants.)

### Phase 4 — the reconcile loop
`reconcileMembership` wired next to `reconcileStuckMoves` (leader-gated, interval
+ event-kick). **Ship OFF by default** behind `REWIND_CP_RECONCILE_MEMBERSHIP=1`
— a continuous unattended actor on prod must be opt-in until proven; flip it on
per-cluster after the smoke + throwaway verification.

### Phase 5 — smoke + failure modes
`scripts/grow_backfill_smoke_v2.py`: provision on 2 nodes → `POST
/_control/cluster` adding a 3rd → with the flag on, assert the reconciler
backfills node 3 to a caught-up voter (via `v2-member-status`) + a fresh write
replicates to all 3; then kill a node, confirm 2-of-3 holds. Inject: node down
during backfill (retries, no corruption), CP-leader flip mid-`ensureMember`
(idempotent resume), `cluster.set` racing a `move` (skipped via `moving`).

### Phase 6 — follow-on (not blocking)
Single-source-of-truth completion: derive raft membership from `cluster.nodes`,
retire `REWIND_VOTERS`; runtime transport peer add/remove for a *truly new* host
not in the static peer set (the bigger "Path A" — CP voter add/retire + runtime
transport peer add/remove, sharing the raft-rs-zig conf-change FFI with the DR
learner); the explicit **destructive** ops (`removeMember`/shrink/deprovision) as
operator-driven — never the reconciler.

## Sequencing, rollout, payoff

1. Phases 1→2→3 land; the **throwaway-tenant gate** passes (proves `ensureMember`
   is safe).
2. Phases 4+5 land; reconciler stays `OFF` in prod config.
3. Deploy the new CP/worker build.
4. Fix prod bhs-3: `POST /_control/cluster` adding it to the prod cluster's
   `nodes`, flip `REWIND_CP_RECONCILE_MEMBERSHIP=1`, watch the reconciler backfill
   bhs-3's groups via `v2-member-status`. The phantom voter resolves itself.

## Risk register

- **Phase 3 epoch/attach correctness** — highest; mitigated by the
  throwaway-tenant hard gate.
- **Continuous actor on prod** — mitigated by the opt-in flag + additive-only
  invariant (worst case = wasted pass).
- **Chicken-and-egg** — the reconciler that fixes bhs-3 ships in a build that
  itself needs deploying onto the still-2-of-3 cluster; sequence the deploy before
  enabling the flag.
- **`memberStatus` mis-observation** — safe by construction (additive-only → at
  worst a redundant no-op bootstrap).

## Effort

~2–4 focused days. The hard substrate (conf_change, snapshot/baseline bootstrap,
`voter_progress`) is **already shipped** — this is one read endpoint, the directory
primitives, the composition, the loop, and (the real work) *proving* the compose
is safe on a throwaway tenant.
