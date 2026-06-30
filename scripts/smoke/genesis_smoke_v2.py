#!/usr/bin/env python3
"""Genesis smoke ⭐ — bring up a 3-node cluster FROM EMPTY (cold-multi).

This is the CI gate the 2026-06-24 prod outage demanded (project_prod_genesis
_gap / docs/architecture/consensus-and-storage.md, "Cluster genesis &
membership"): we had NO test for clean-slate
multi-node bring-up. The ratified architecture is cold-multi — small FIXED
clusters where every raft group is born with the full static voter set {1..N}
and elects on its own (scale by adding clusters + tenant moves, not by growing).
This smoke spins a REAL multi-process cluster from empty on the cold-multi env
and asserts the first-deploy / post-wipe path end to end.

Topology (genesis mode — `V2Cluster.spawn(..., genesis=True)`):

    rewind-cp     single node, reconciler OFF (cold-multi needs no grow)
    rewind-front  stateless proxy
    rewind nodes  ×3, each booted cold-multi (static REWIND_VOTERS/REWIND_PEERS)
                  — every group born {1,2,3}

Legs:
  A.  provision a tenant → the CP births its group with the full voter set
      {1,2,3}; the group elects on its own (cold-multi, no grow).
  B.  confirm the group formed with all 3 voters (≈instant — born, not grown).
  C.  write through the leader; the value replicates to all 3 nodes.
  D.  publish a handler bundle + serve it through the front door (exercises
      __admin__ genesis + the real publish path: elect → bootstrap → serve).
  E.  ⭐ kill the leader; a survivor serves the replicated data and accepts a
      fresh write on the surviving quorum.

Needs S3 env (no fs blob backend): `set -a; . ./.env; set +a` first.
Build first: `zig build rewind-worker rewind-cp rewind-front`
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TENANT = "genesistenant"
APP = "genesisapp"
KEY = "greeting"
V1 = "cold-multi-formed"
V2 = "after-leader-kill"
APP_SRC = 'export function handler() { return "genesis-served\\n"; }\n'


def main() -> int:
    nodes = 3
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    def kv_get_retry(c, tenant, key, node, want, deadline_s=20.0):
        deadline = time.time() + deadline_s
        last = None
        while time.time() < deadline:
            last = c.admin_kv_get(tenant, key, node=node)
            if last.status == 200 and last.body == want:
                return last
            time.sleep(0.3)
        return last

    def kv_put_retry(c, tenant, key, value, node_fn, deadline_s=25.0):
        """PUT to the current leader, retrying through a (re)election."""
        deadline = time.time() + deadline_s
        last = None
        while time.time() < deadline:
            leader = node_fn()
            if leader is not None:
                last = c.admin_kv_put(tenant, key, value, node=leader)
                if last.status == 204:
                    return last
            time.sleep(0.3)
        return last

    with V2Cluster.spawn("genesis", nodes=nodes, genesis=True) as c:
        # ── A. provision births the group {1,2,3} cold-multi ──────────
        print("leg A: provision (births the group with the full voter set {1,2,3})")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        # ── B. confirm formed at 3 voters (born, not grown) ───────────
        print("leg B: confirm the group formed with all 3 voters (cold-multi)")
        try:
            ms = c.wait_for_membership(TENANT, voters=nodes, timeout=60.0)
            check("formed at 3 voters", len(ms.get("voters", [])) == nodes,
                  f"voters={ms.get('voters')}")
        except SystemExit as e:
            check("formed at 3 voters", False, str(e))
            c.dump_node_log(grep=["confchange", "elect", "leader", "vote",
                                  "peer", "error", "warn"])

        # ── C. write replicates to every node ─────────────────────────
        print("leg C: write via the leader, read back on every node (replicated)")
        leader = c.leader_node(TENANT)
        check("found a leader", leader is not None, f"node {leader}")
        if leader is not None:
            r = c.admin_kv_put(TENANT, KEY, V1, node=leader)
            check("PUT seed via leader → 204", r.status == 204, f"got {r.status}")
            for i in range(nodes):
                rr = kv_get_retry(c, TENANT, KEY, i, V1)
                check(f"GET n{i + 1} replicated value",
                      rr is not None and rr.status == 200 and rr.body == V1,
                      f"got {rr.status if rr else '?'} {rr.body if rr else ''!r}")

        # ── D. publish a handler + serve through the front ────────────
        print("leg D: publish a handler bundle + serve through the front door")
        try:
            r = c.provision(APP)
            check("provision app → 204/409", r.status in (204, 409), f"got {r.status}")
            dep_id = c.deploy_handlers(APP, {"index.mjs": rpc_wrap(APP_SRC)})
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
            r = c.wait_for_handler(APP, "/?fn=handler", want_body="genesis-served",
                                   timeout_s=30.0)
            check("GET via front → genesis-served",
                  r.status == 200 and "genesis-served" in r.body,
                  f"got {r.status} {r.body!r}")
        except RuntimeError as e:
            check("publish + serve", False, str(e))
            c.dump_node_log(grep=["deploy", "loader", "manifest", "reset",
                                  "admin", "error", "warn"])

        # ── E. ⭐ kill the leader; a survivor serves + accepts a write ─
        print("leg E: ⭐ kill the TENANT leader; a survivor serves")
        leader = c.leader_node(TENANT)
        check("found leader to kill", leader is not None, f"node {leader}")
        if leader is not None:
            c.kill_node(leader)
            survivors = [i for i in range(nodes) if i != leader]
            # a survivor still serves the replicated value
            rr = None
            for i in survivors:
                rr = kv_get_retry(c, TENANT, KEY, i, V1, deadline_s=25.0)
                if rr is not None and rr.status == 200 and rr.body == V1:
                    break
            check("survivor serves replicated value",
                  rr is not None and rr.status == 200 and rr.body == V1,
                  f"got {rr.status if rr else '?'} {rr.body if rr else ''!r}")
            # a fresh write commits on the surviving 2-node quorum
            r = kv_put_retry(c, TENANT, KEY, V2,
                             lambda: c.leader_now(TENANT, nodes=survivors),
                             deadline_s=25.0)
            check("PUT post-failover → 204", r is not None and r.status == 204,
                  f"got {r.status if r else '?'}")
            rr = None
            for i in survivors:
                rr = kv_get_retry(c, TENANT, KEY, i, V2, deadline_s=20.0)
                if rr is not None and rr.status == 200 and rr.body == V2:
                    break
            check("survivor serves post-failover value",
                  rr is not None and rr.status == 200 and rr.body == V2,
                  f"got {rr.status if rr else '?'} {rr.body if rr else ''!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS — genesis: a 3-node cluster formed FROM EMPTY (cold-multi),"
          " replicated, served a publish, and survived a leader kill. ⭐")
    return 0


if __name__ == "__main__":
    sys.exit(main())
