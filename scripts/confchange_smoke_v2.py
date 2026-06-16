#!/usr/bin/env python3
"""V2 conf_change Phase-1 smoke — manual demote / promote a voter.

The membership-change engine: an operator demotes a voter to a LEARNER (it
leaves the voters-only WAL-compaction floor, so a far-behind node stops pinning
the log) and promotes it back. This smoke exercises the engine on ONE tenant
group, demoting an UP follower (deterministic; the down-node use case + the
auto-policy are Phase 2):

  provision 'acme' across 3 nodes; deploy a kv handler; seed a value → all 3 hold
  POST /_system/v2-confchange {op:demote, node_id:3} on the leader
  ⭐ /_system/v2-confstate shows node 3 a LEARNER, voters = the other two
  a fresh write still commits on the 2-voter quorum
  RESTART node 3 (the learner — the 2 voters keep quorum) → it recovers with
    itself still a learner (membership persisted via the .confstate WAL record)
  ⭐ POST {op:promote, node_id:3} → node 3 is a voter again

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET, _curl  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("cc/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    const v = kv.get("cc/value");
    return "value:" + (v ?? "none");
}
"""

KEY = "cc/value"
SECRET_HDR = {"X-Rewind-Move-Secret": MOVE_SECRET}
JSON_HDR = {**SECRET_HDR, "Content-Type": "application/json"}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    def confchange(node, node_id, op):
        return _curl(f"{c.node_url(node)}/_system/v2-confchange", method="POST",
                     headers=JSON_HDR,
                     data=json.dumps({"tenant": "acme", "node_id": node_id, "op": op}))

    def confstate(node):
        r = _curl(f"{c.node_url(node)}/_system/v2-confstate?tenant=acme", headers=SECRET_HDR)
        if r.status != 200:
            return None
        try:
            return json.loads(r.body)
        except Exception:
            return None

    def wait_membership(node, node_id, *, learner, deadline_s=20.0):
        """Poll confstate(node) until node_id is in learners (learner=True) or
        voters (learner=False). Returns the final confstate dict or None."""
        deadline = time.time() + deadline_s
        last = None
        while time.time() < deadline:
            last = confstate(node)
            if last is not None:
                where = last["learners"] if learner else last["voters"]
                if node_id in where:
                    return last
            time.sleep(0.4)
        return last

    with V2Cluster.spawn("confchange", nodes=3) as c:
        print("step 1: provision 'acme' + deploy the kv handler")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        lead0 = c.leader_node("acme")
        check("leader present", lead0 is not None, f"lead={lead0}")
        if lead0 is None:
            return 1
        try:
            dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)
            check("deploy → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy", False, str(e))
            return 1

        print("step 2: seed a value; confirm all 3 nodes hold it")
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"seed"}', want_status=204)
        check("seed write → 204", r.status == 204, f"got {r.status}")
        for i in range(3):
            rg = c.admin_kv_get("acme", KEY, node=i)
            check(f"node {i + 1} holds seed", rg.status == 200 and "seed" in rg.body,
                  f"got {rg.status} {rg.body!r}")

        print("step 3: demote a follower (node 3 if it's a follower) → learner")
        lead = c.leader_node("acme")
        # Pick a follower to demote (node index 2 = raft id 3 by default; fall
        # back to any non-leader if node 3 happens to be the leader).
        follower = 2 if lead != 2 else next(i for i in range(3) if i != lead)
        fnid = follower + 1
        print(f"       leader=node {lead + 1}; demoting follower node {fnid}")
        r = confchange(lead, fnid, "demote")
        check("demote → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 4: ⭐ confstate shows the node as a LEARNER")
        cs = wait_membership(lead, fnid, learner=True)
        check(f"node {fnid} is a learner", cs is not None and fnid in cs["learners"],
              f"confstate={cs}")
        check(f"node {fnid} not a voter", cs is not None and fnid not in cs["voters"],
              f"confstate={cs}")

        print("step 5: a fresh write still commits on the 2-voter quorum")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"after-demote"}', want_status=204, deadline_s=15)
        check("write post-demote → 204", r.status == 204, f"got {r.status}")
        r = c.request_retry("acme", "/?fn=handler", want_body="value:after-demote")
        check("read-back post-demote", r.status == 200 and "after-demote" in r.body,
              f"got {r.status} {r.body!r}")

        print(f"step 6: RESTART node {fnid} (the learner) — voters keep quorum")
        c.stop_node(follower)
        time.sleep(1.0)
        c.start_node(follower)

        print("step 7: ⭐ membership persisted — recovered node is still a learner")
        cs = wait_membership(follower, fnid, learner=True, deadline_s=30.0)
        check(f"node {fnid} recovered as a learner", cs is not None and fnid in cs["learners"],
              f"confstate={cs}")

        print("step 8: ⭐ promote the node back to voter")
        lead2 = c.leader_node("acme")
        check("leader present for promote", lead2 is not None, f"lead={lead2}")
        if lead2 is not None:
            r = confchange(lead2, fnid, "promote")
            check("promote → 204", r.status == 204, f"got {r.status} {r.body!r}")
            cs = wait_membership(lead2, fnid, learner=False)
            check(f"node {fnid} is a voter again", cs is not None and fnid in cs["voters"],
                  f"confstate={cs}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS conf_change smoke (v2) — a voter was demoted to a learner, the "
          "cluster kept serving on the surviving quorum, the membership survived "
          "a restart, and the node was promoted back to a voter. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
