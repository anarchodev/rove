#!/usr/bin/env python3
"""V2 snapshot/log catchup smoke (port of `scripts/snap_catchup_smoke.py`).

The V1 smoke drove the out-of-band snapshot-catchup machinery for a far-behind
follower and asserted the internal cycle stage → exit → install →
raft_load_snapshot → cleanup. On V2 the OBSERVABLE essence is: a follower that
was DOWN while the log advanced REJOINS and CATCHES UP to the replicated state
(serves/reads values written in its absence). This port drops the V1
raft-internal + snapshot-file + TLS + leader-direct infra and asserts catchup
purely through served reads (`admin_kv_get`).

BOOT-TIME GROUP RECOVERY (the engine path this asserts):
  A V2 node's per-tenant raft groups are created by a runtime provision /
  `v2-attach`, but a restarted node must ALSO re-stand-up the groups it already
  had. The node persists each group in a node-local manifest
  (`{data_dir}/__groups__`, id_str → epoch — gid is a non-invertible hash of
  id_str, so the id_str must be stored); at boot `Bridge.recoverGroups`
  (before `startPump`, like the CP directory's boot `ensureGroup`) reads it and
  calls `node.recoverGroup` per tenant, which replays the durable WAL into a
  fresh group at the recorded epoch. The rejoined node is already a voter in
  the group's persisted confstate, so once the pump starts the leader
  replicates the missing tail (no conf-change needed) and it catches up. See
  `src/consensus/{node,bridge}.zig` + `src/rewind/main.zig`.

  This smoke proves the full arc: provision+deploy across 3 nodes, seed
  replicates to all 3, a follower stops, the log advances 30 writes on the
  surviving quorum, both survivors hold the latest value, the stopped node
  RESTARTS, rejoins its `acme` group, and catches up to the post-kill value.

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind-worker rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# POST {value} writes kv["catchup/value"]; GET reads it back.
HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("catchup/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("catchup/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "catchup/value"
SEED = "seed-0"
ADVANCE_WRITES = 30  # advance the log while the follower is down


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("snapcatch", nodes=3) as c:
        print("step 1: provision 'acme' across the 3-node cluster")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the kv handler (release on the current leader)")
        lead = c.leader_node("acme")
        check("leader present pre-deploy", lead is not None, f"lead={lead}")
        try:
            dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                                       node=lead if lead is not None else 0)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print(f"step 3: seed {SEED!r} through the front; confirm all 3 nodes hold it")
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        check("handler serves (value:none)", r.status == 200, f"got {r.status} {r.body!r}")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"%s"}' % SEED, want_status=204)
        check("seed write → 204", r.status == 204, f"got {r.status} {r.body!r}")
        for i in range(3):
            ok_read = False
            rg = None
            deadline = time.time() + 10.0
            while time.time() < deadline:
                rg = c.admin_kv_get("acme", KEY, node=i)
                if rg.status == 200 and SEED in rg.body:
                    ok_read = True
                    break
                time.sleep(0.3)
            check(f"node {i + 1} holds seed", ok_read, f"got {rg.status} {rg.body!r}")

        print("step 4: STOP a follower (not the current leader)")
        lead = c.leader_node("acme")
        check("leader present", lead is not None, f"lead={lead}")
        if lead is None:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        follower = next(i for i in range(3) if i != lead)
        print(f"       leader=node {lead + 1}; stopping follower node {follower + 1}")
        c.stop_node(follower)
        survivors = [i for i in range(3) if i != follower]

        print(f"step 5: advance the log — {ADVANCE_WRITES} writes through the leader")
        latest = SEED
        r = None
        for n in range(ADVANCE_WRITES):
            latest = f"advance-{n}"
            r = c.admin_kv_put("acme", KEY, latest, node=lead)
            if r.status not in (200, 204):
                # leader may have changed; re-resolve among survivors
                nl = c.leader_node("acme", deadline_s=10.0)
                if nl is not None and nl in survivors:
                    lead = nl
                    r = c.admin_kv_put("acme", KEY, latest, node=lead)
        check("final advance write committed", r is not None and r.status in (200, 204),
              f"got {r.status if r else '-'} latest={latest!r}")

        print("step 6: surviving nodes hold the latest value (replicated)")
        for i in survivors:
            ok_read = False
            rg = None
            deadline = time.time() + 10.0
            while time.time() < deadline:
                rg = c.admin_kv_get("acme", KEY, node=i)
                if rg.status == 200 and latest in rg.body:
                    ok_read = True
                    break
                time.sleep(0.3)
            check(f"survivor node {i + 1} holds latest {latest!r}",
                  ok_read, f"got {rg.status} {rg.body!r}")

        print("step 7: RESTART the stopped follower")
        c.start_node(follower)
        # The rejoined node comes back up and serves its own persisted store.
        rg = None
        deadline = time.time() + 15.0
        while time.time() < deadline:
            rg = c.admin_kv_get("acme", KEY, node=follower)
            if rg.status == 200:
                break
            time.sleep(0.4)
        check("rejoined node serves its persisted store",
              rg is not None and rg.status == 200,
              f"got {rg.status if rg else '-'} {rg.body if rg else ''!r}")

        # ⭐ The catchup assertion: does the rejoined node converge to the
        # post-kill latest value? Drive one more write so it would have a fresh
        # apply to follow, then poll.
        print("step 8: ⭐ rejoined node catches up to the post-kill latest value")
        latest2 = "after-rejoin"
        ok_catchup = False
        rg = None
        deadline = time.time() + 40.0
        while time.time() < deadline:
            ld = c.leader_node("acme", deadline_s=5.0)
            if ld is not None:
                c.admin_kv_put("acme", KEY, latest2, node=ld)
            rg = c.admin_kv_get("acme", KEY, node=follower)
            if rg.status == 200 and latest2 in rg.body:
                ok_catchup = True
                break
            time.sleep(0.5)
        # Boot-time group recovery (the node-local manifest + `recoverGroups`,
        # `src/consensus/{node,bridge}.zig`): the rejoined node re-stands-up its
        # `acme` raft group from the persisted WAL, rejoins as the voter it
        # already is, and the leader replicates the missing tail → it catches
        # up to the post-kill value. A hard assertion now, not a SKIP.
        check(f"⭐ rejoined node {follower + 1} caught up to {latest2!r}", ok_catchup,
              f"got {rg.status} {rg.body!r}, expected {latest2!r} within 40s")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS snap-catchup smoke (v2) — a follower that was down while the "
          "log advanced rejoined and caught up to the replicated latest value.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
