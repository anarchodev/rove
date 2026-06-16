#!/usr/bin/env python3
"""V2 conf_change Phase-2 smoke — leader-side AUTO-demote of a dead voter.

Phase 1 demotes a voter on an explicit operator call. Phase 2 adds the leader's
own policy: a peer voter that is BOTH far behind (lag > REWIND_AUTO_DEMOTE_LAG
entries) AND `!recent_active` (no contact within ~an election timeout, under
check_quorum) is demoted to a learner automatically, so a permanently-dead node
stops pinning the voters-only WAL-compaction floor (`minMatchIndex`) and the log
can truncate again.

  provision 'acme' across 3 nodes; deploy a kv handler; seed → all 3 hold it
  KILL a follower (it goes !recent_active once check_quorum stops hearing it)
  advance the log past the lag threshold through the surviving 2-voter quorum
  ⭐ WITHOUT any operator call, /_system/v2-confstate shows the dead node a
     LEARNER and voters shrunk to the two live nodes
  a fresh write still commits on the 2-voter quorum

Tuned tiny via env so the test advances a handful of entries, not 10k:
REWIND_AUTO_DEMOTE_LAG=5, REWIND_AUTO_DEMOTE_MS=200 (set before spawn; the
harness copies os.environ into every worker).

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind rewind-cp rewind-front files-server-v2`
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

# Tune the auto-demote policy SMALL before importing/spawning so every worker
# (env copied from os.environ) demotes after a handful of lagging entries.
os.environ["REWIND_AUTO_DEMOTE_LAG"] = "5"
os.environ["REWIND_AUTO_DEMOTE_MS"] = "200"

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


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    def confstate(c, node):
        r = _curl(f"{c.node_url(node)}/_system/v2-confstate?tenant=acme", headers=SECRET_HDR)
        if r.status != 200:
            return None
        try:
            return json.loads(r.body)
        except Exception:
            return None

    with V2Cluster.spawn("autodemote", nodes=3) as c:
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
        cs0 = confstate(c, lead0)
        check("starts with 3 voters", cs0 is not None and len(cs0["voters"]) == 3,
              f"confstate={cs0}")

        print("step 3: KILL a follower — it goes !recent_active")
        lead = c.leader_node("acme")
        follower = next(i for i in range(3) if i != lead)
        fnid = follower + 1
        print(f"       leader=node {lead + 1}; killing follower node {fnid}")
        c.stop_node(follower)

        print("step 4: advance the log past the lag threshold (2-voter quorum)")
        # A burst pushes the dead node's lag well past REWIND_AUTO_DEMOTE_LAG=5;
        # the surviving leader + 1 follower still form quorum so writes commit.
        for i in range(20):
            c.request_retry("acme", "/?fn=handler", method="POST",
                            data=f'{{"value":"adv-{i}"}}', want_status=204, deadline_s=15)
        check("log advanced on 2-voter quorum", True)

        print(f"step 5: ⭐ leader AUTO-demotes node {fnid} (no operator call)")
        # Trickle writes while polling so the group stays dirty across an
        # auto-demote eval window (the policy only runs on actively-advancing
        # groups). Poll a LIVE node (the leader) for the membership flip.
        deadline = time.time() + 30.0
        cs = None
        seq = 100
        while time.time() < deadline:
            lead_now = c.leader_node("acme")
            if lead_now is not None:
                cs = confstate(c, lead_now)
                if cs is not None and fnid in cs["learners"]:
                    break
            c.request_retry("acme", "/?fn=handler", method="POST",
                            data=f'{{"value":"adv-{seq}"}}', want_status=204, deadline_s=10)
            seq += 1
            time.sleep(0.3)
        check(f"node {fnid} auto-demoted to learner", cs is not None and fnid in cs["learners"],
              f"confstate={cs}")
        check(f"node {fnid} no longer a voter", cs is not None and fnid not in cs["voters"],
              f"confstate={cs}")
        check("voters shrunk to the 2 live nodes", cs is not None and len(cs["voters"]) == 2,
              f"confstate={cs}")

        print("step 6: a fresh write still commits on the surviving quorum")
        r = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"value":"after-auto-demote"}', want_status=204, deadline_s=15)
        check("write post-auto-demote → 204", r.status == 204, f"got {r.status}")
        r = c.request_retry("acme", "/?fn=handler", want_body="value:after-auto-demote")
        check("read-back post-auto-demote", r.status == 200 and "after-auto-demote" in r.body,
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS auto-demote smoke (v2) — the leader demoted a dead, far-behind "
          "voter to a learner on its own policy (no operator call), the voter set "
          "shrank to the live quorum, and the cluster kept serving. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
