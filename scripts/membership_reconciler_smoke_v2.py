#!/usr/bin/env python3
"""V2 membership-reconciler smoke — a wiped node AUTO-HEALS, no manual ops.

GREEN. Previously surfaced the attach→apply-snapshot WINDOW bug: the reconciler
created the group (last_index 0) then installed the baseline in a SEPARATE op, and
a leader heartbeat carrying commit > 0 could reach the empty group first → raft-rs
commit_to fatal! ("to_commit out of range [last_index 0]"). Fixed by making attach
install the baseline ATOMICALLY (X-Rewind-Baseline-* → createGroupAtBaseline, one
pump op): the fresh group is never observable at last_index 0. The baseline = the
leader's current applied index, which is ≥ the wiped node's stale Progress.match,
so the leader's heartbeat commit = min(match, committed) can never exceed the
node's new last_index. fresh_voter_join (manual, separate apply-snapshot) won the
race by quiescent+fast pacing; the reconciler lost it deterministically.

The end-to-end gate for docs/cp-membership-reconciler-plan.md (Phases 3+4). With
REWIND_CP_RECONCILE_MEMBERSHIP=1, the CP's additive, learner-first reconciler
converges DP group membership to the cluster's node set on its own.

Reproduces the bhs-3 phantom-voter, then does NOTHING but wait: provision a
tenant on a 3-node cluster, seed data, then WIPE node 3's data dir + restart it
(a configured voter with no group instance, matched=0). The reconciler must, with
no operator action, walk it back to a caught-up voter via the learner-first path:
  voter-but-stuck → DEMOTE to learner (so it can't disrupt elections)
  learner, not hosted → bootstrap (snapshot + attach + apply-snapshot)
  learner, caught up → PROMOTE to voter
Then a FRESH write must replicate to it — proving it's a productive voter again,
entirely hands-off. (Contrast fresh_voter_join_smoke, which drives the same
sequence BY HAND.)

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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const b = JSON.parse(request.body || "{}");
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
        check("provision → 204", c.provision("acme").status == 204)
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False); return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        for i in range(30):
            c.request_retry("acme", "/?fn=handler", method="POST", data=f'{{"value":"v-{i}"}}', want_status=204, deadline_s=10)
        latest = "v-29"
        cs = confstate(c, lead0)
        check("3 voters at start", cs is not None and len(cs["voters"]) == 3, f"cs={cs}")

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        print(f"       leader=node {lead + 1}; will WIPE node {vnid}")

        print(f"step 2: STOP node {vnid}, WIPE its data → fresh voter with no group (phantom)")
        check("victim holds data pre-wipe", latest in c.admin_kv_get("acme", KEY, node=victim).body)
        c.stop_node(victim)
        subprocess.run(["rm", "-rf", str(c.data_dirs[victim])])
        c.start_node(victim)

        print(f"step 3: ⭐ WAIT — the reconciler must auto-heal node {vnid} (NO manual ops)")
        healed = False
        deadline = time.time() + 90.0
        while time.time() < deadline:
            rg = c.admin_kv_get("acme", KEY, node=victim)
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
                if "after-reconcile" in c.admin_kv_get("acme", KEY, node=victim).body:
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
