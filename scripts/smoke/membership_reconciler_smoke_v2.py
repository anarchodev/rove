#!/usr/bin/env python3
"""V2 membership-reconciler smoke — a wiped node AUTO-HEALS, no manual ops.

The end-to-end gate for docs/architecture/cp-membership-reconciler.md. With
REWIND_CP_RECONCILE_MEMBERSHIP=1, the CP's additive, learner-first reconciler
converges DP group membership to the cluster's node set on its own.

Reproduces the bhs-3 phantom-voter, then does NOTHING but wait: provision a
tenant on a 3-node cluster, seed data, then WIPE a follower's data dir +
restart it (a configured voter with no group instance, stale-high
Progress.match). The reconciler must, with no operator action, walk it back to
a caught-up voter via the raft-native member re-add:
  voter/learner, confirmed-absent → REMOVE (drops the stale-high Progress —
      the commit_to-out-of-range class needs a stale match, so tear it out)
  absent from config, not hosted  → attach EMPTY (born learner, the leader's
      augmented ConfState + epoch + incarnation; NO data through the CP),
      then AddLearner (fresh match=0)
  data arrives raft-natively: the log tail replicates, or — forced here via a
      LOW REWIND_SNAPSHOT_GRACE, so the leader has compacted past the reborn
      node's empty log — the auto-catchup STREAMS the store with the baseline
      + ConfState in headers onto the group born empty
  learner, caught up → PROMOTE to voter
Then a FRESH write must replicate to it — proving it's a productive voter
again, entirely hands-off. The grow phase (sole-voter birth → 3 voters) covers
the young-log replication flavor of the same add; the wipe leg covers the
compacted/streamed flavor.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Enable the reconciler + run it often, BEFORE the lib spawns the CP (env-inherited).
os.environ["REWIND_CP_RECONCILE_MEMBERSHIP"] = "1"
os.environ["REWIND_CP_RECONCILE_SECS"] = "2"
# RC-6 demote hysteresis: a demote now requires SUSTAINED inactivity past a grace
# window (default 60s, to ride out a rolling restart). Shrink it here so the smoke
# still demotes a permanently-stuck voter promptly — it stays inactive across the
# window, so a small grace proves the path without a 60s wait. (Also exercises the
# new "never demote on the first observation" property: the demote lands a pass
# later, not on first sight.)
os.environ["REWIND_CP_DEMOTE_GRACE_MS"] = "1000"
# Force mechanism-A compaction PAST the seeded writes (floor = durabilized −
# grace), so the wiped node's heal CANNOT replay the log from entry 1 and must
# take the streamed snapshot catch-up onto the group born EMPTY — the
# reconciler-bootstrap × auto-catchup composition this smoke gates.
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const b = JSON.parse(request.text || "{}");
        kv.set(b.key ?? "cc/value", b.value ?? "");
        response.status = 204; return "";
    }
    return "value:" + (kv.get("cc/value") ?? "none");
}
"""
KEY = "cc/value"


def confstate(c, node):
    r = subprocess.run(["curl", "-s", "--http2-prior-knowledge", "-m", "10",
                        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
                        f"{c.node_url(node)}/_system/v2-confstate?tenant=acme"],
                       capture_output=True, text=True).stdout.strip()
    try:
        return json.loads(r)
    except Exception:
        return None


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("reconciler", nodes=3) as c:
        print("step 1: provision + deploy + seed a log tail (forms on all 3, all caught up)")
        check("provision → 200", c.provision("acme").status == 200)
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False); return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        # WELL past REWIND_SNAPSHOT_GRACE, so the leader's compaction floor
        # (durabilized − grace) sits far above entry 1 by the wipe below — the
        # heal is then forced through the streamed catch-up, never a log replay.
        for i in range(120):
            c.request_retry("acme", "/?fn=handler", method="POST", data=f'{{"value":"v-{i}"}}', want_status=204, deadline_s=10)
        latest = "v-119"

        # With a reconciler present the CP births a tenant as the SOLE voter {1}
        # and the reconciler GROWS it to the full node set learner-first (the
        # CP's two-births rule) — so "3 voters" is something to WAIT for, not
        # something true at provision. Waiting is also the cheapest assertion
        # that the grow half of the reconciler works before the heal half is
        # exercised below.
        cs = None
        deadline = time.time() + 90.0
        while time.time() < deadline:
            cs = confstate(c, c.leader_node("acme") if c.leader_node("acme") is not None else lead0)
            if cs is not None and len(cs.get("voters", [])) == 3:
                break
            time.sleep(1.0)
        check("⭐ reconciler GREW the group to 3 voters", cs is not None and len(cs["voters"]) == 3, f"cs={cs}")

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; will WIPE node {vnid}")

        print(f"step 2: STOP node {vnid}, WIPE its data → fresh voter with no group (phantom)")
        # The grown voter has to be CAUGHT UP before the wipe means anything —
        # otherwise step 3 could "heal" a node that never held the data.
        held = False
        deadline = time.time() + 60.0
        while time.time() < deadline:
            if latest in c.node_kv_get("acme", KEY, node=victim).body:
                held = True
                break
            time.sleep(1.0)
        check("victim holds data pre-wipe", held)
        c.stop_node(victim)
        subprocess.run(["rm", "-rf", str(c.data_dirs[victim])])
        c.start_node(victim)

        print(f"step 3: ⭐ WAIT — the reconciler must auto-heal node {vnid} (NO manual ops)")
        healed = False
        deadline = time.time() + 90.0
        while time.time() < deadline:
            rg = c.node_kv_get("acme", KEY, node=victim)
            cs = confstate(c, lead if c.leader_node('acme') is None else c.leader_node('acme'))
            voter = cs is not None and vnid in cs.get("voters", [])
            if rg.status == 200 and latest in rg.body and voter:
                healed = True
                break
            time.sleep(2)
        check(f"⭐ node {vnid} auto-healed to a caught-up VOTER (no manual ops)", healed,
              f"last kv={rg.status}/{rg.body!r} cs={cs}")
        if not healed:
            print(f"       node {vnid} alive? {c.node_procs[victim].poll()} (None=running)")
            log = c.log_paths.get(f"n{vnid}")
            if log and os.path.exists(log):
                print(f"       --- node {vnid} full log tail (40) ---")
                for ln in open(log).read().splitlines()[-40:]:
                    print("       | " + ln)

        if healed:
            print(f"step 4: ⭐ a FRESH write replicates to the auto-rejoined node {vnid}")
            newlead = c.leader_node("acme")
            c.request_retry("acme", "/?fn=handler", method="POST", data='{"value":"after-reconcile"}',
                            want_status=204, deadline_s=15)
            repl = False
            for _ in range(40):
                if "after-reconcile" in c.node_kv_get("acme", KEY, node=victim).body:
                    repl = True; break
                time.sleep(0.5)
            check(f"⭐ fresh write replicated to node {vnid}", repl)
            _ = newlead

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS membership-reconciler smoke (v2) — a wiped configured-voter was "
          "auto-healed to a caught-up voter by the CP reconciler (learner-first, "
          "hands-off) and took a fresh write. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
