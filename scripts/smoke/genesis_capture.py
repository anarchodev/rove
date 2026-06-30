#!/usr/bin/env python3
"""Capture harness for the leg-E failover flake (Finding 1 vs Finding 3).

Replays the genesis smoke's A–E flow in a loop. On a leg-E failure (no
post-failover leader / PUT never 204s) it polls EACH SURVIVOR's *local*,
non-leader-gated raft view and prints a verdict:

  * /_system/v2-confstate  → the survivor's believed voters/learners.
      If a survivor's voter set lacks an ALIVE quorum (e.g. {1,2} with 3 a
      learner, and node 1 was the killed leader) → FINDING 3 (membership
      timing: quorum mathematically impossible — no election can win).
  * /_system/v2-leader (200/421) + /_system/v2-raft-state → is anyone leading.
      Full voters {1,2,3} on the survivors but NO leader for 25s → FINDING 1
      (election stuck: lease-ignore / livelock — the TiKV force-campaign fix).

Run:  set -a; . ./.env; set +a
      zig build rewind-worker rewind-cp rewind-front
      python3 scripts/smoke/genesis_capture.py [max_runs]
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, _curl, MOVE_SECRET  # noqa: E402

TENANT = "genesistenant"
APP = "genesisapp"
KEY = "greeting"
V1 = "born-self-then-grown"
V2 = "after-leader-kill"
APP_SRC = 'export function handler() { return "genesis-served\\n"; }\n'

H = {"X-Rewind-Move-Secret": MOVE_SECRET}


def _node_get(c, node, path):
    r = _curl(f"{c.node_url(node)}{path}", timeout=5.0, headers=H)
    return r


def _confstate(c, node, tenant):
    r = _node_get(c, node, f"/_system/v2-confstate?tenant={urllib.parse.quote(tenant)}")
    if r.status != 200:
        return None, f"{r.status}"
    try:
        return json.loads(r.body), None
    except Exception:
        return None, f"badjson:{r.body!r}"


def _raftstate(c, node, tenant):
    r = _node_get(c, node, f"/_system/v2-raft-state?tenant={urllib.parse.quote(tenant)}")
    if r.status != 200:
        return None, f"{r.status}"
    try:
        return json.loads(r.body), None
    except Exception:
        return None, f"badjson:{r.body!r}"


def _leads(c, node, tenant):
    r = _node_get(c, node, f"/_system/v2-leader?tenant={urllib.parse.quote(tenant)}")
    return r.status  # 200 = leads, 421 = follower, other = ?


def diagnose(c, killed, survivors, nodes):
    """Poll the survivors' local raft view for ~25s; print a Finding verdict."""
    print(f"\n===== LEG-E FAILURE DIAGNOSIS (killed node {killed + 1}) =====")
    alive_ids = {i + 1 for i in survivors}  # raft ids are node_index+1
    deadline = time.time() + 25.0
    saw_leader = False
    last_cs = {}
    while time.time() < deadline:
        any_leader = False
        for i in survivors:
            if _leads(c, i, TENANT) == 200:
                any_leader = True
                saw_leader = True
        cs_snapshot = {}
        for i in survivors:
            cs, err = _confstate(c, i, TENANT)
            rs, _ = _raftstate(c, i, TENANT)
            cs_snapshot[i + 1] = (cs, err, rs)
            last_cs[i + 1] = (cs, err, rs)
        line = " | ".join(
            f"n{nid}: voters={cs.get('voters') if cs else err}"
            f" learners={cs.get('learners') if cs else ''}"
            f" leads={'Y' if _is_leader(rs) else '.'}"
            for nid, (cs, err, rs) in sorted(cs_snapshot.items())
        )
        print(f"  t+{25 - (deadline - time.time()):4.1f}s  leader={'Y' if any_leader else 'N'}  {line}")
        if any_leader:
            break
        time.sleep(1.0)

    print("  ---- verdict ----")
    # Inspect the final believed voter set on each survivor.
    quorum_possible = None
    for nid, (cs, err, rs) in sorted(last_cs.items()):
        if cs is None:
            print(f"  n{nid}: conf-state unreadable ({err})")
            continue
        voters = set(cs.get("voters", []))
        learners = set(cs.get("learners", []))
        alive_voters = voters & alive_ids
        need = len(voters) // 2 + 1
        ok = len(alive_voters) >= need
        print(f"  n{nid}: voters={sorted(voters)} learners={sorted(learners)} "
              f"alive_voters={sorted(alive_voters)} need={need} quorum_possible={ok}")
        quorum_possible = ok if quorum_possible is None else (quorum_possible and ok)

    if quorum_possible is False:
        print("  >>> FINDING 3 (membership/quorum): a survivor's voter set lacks an "
              "alive quorum — no election can win. TiKV force-campaign would NOT help.")
    elif saw_leader:
        print("  >>> a leader DID appear within 25s (slow recovery, not a hard wedge).")
    else:
        print("  >>> FINDING 1 (election stuck): full quorum exists but no leader for "
              "25s — lease-ignore / livelock. The TiKV force-campaign fix applies.")
    print("=====================================================\n")


def _is_leader(rs):
    return bool(rs and rs.get("leader"))


def run_once(run_idx) -> str:
    """Return 'pass', 'fail-legE' (diagnosed), or 'fail-other'."""
    nodes = 3
    with V2Cluster.spawn("genesis", nodes=nodes, genesis=True) as c:
        # A. provision
        if c.provision(TENANT).status != 204:
            return "fail-other"
        # B. grow to 3 voters
        try:
            c.wait_for_membership(TENANT, voters=nodes, timeout=60.0)
        except SystemExit as e:
            print(f"  [run {run_idx}] grow failed: {e}")
            return "fail-other"
        # C. seed write + replicate
        leader = c.leader_node(TENANT)
        if leader is None or c.admin_kv_put(TENANT, KEY, V1, node=leader).status != 204:
            return "fail-other"
        for i in range(nodes):
            deadline = time.time() + 20
            ok = False
            while time.time() < deadline:
                rr = c.admin_kv_get(TENANT, KEY, node=i)
                if rr.status == 200 and rr.body == V1:
                    ok = True
                    break
                time.sleep(0.3)
            if not ok:
                return "fail-other"
        # D. publish + serve (best-effort; not the leg under test)
        try:
            c.provision(APP)
            c.deploy_handlers(APP, {"index.mjs": rpc_wrap(APP_SRC)})
            c.wait_for_handler(APP, "/?fn=handler", want_body="genesis-served", timeout_s=30.0)
        except Exception as e:
            print(f"  [run {run_idx}] leg D wobble (ignored): {e}")
        # E. kill leader, attempt post-failover write
        leader = c.leader_node(TENANT)
        if leader is None:
            return "fail-other"
        c.kill_node(leader)
        survivors = [i for i in range(nodes) if i != leader]
        # post-failover PUT, retrying through a (re)election for 25s
        deadline = time.time() + 25.0
        ok = False
        while time.time() < deadline:
            # A read on a survivor wakes its hibernated group (wake-on-read) so
            # the pump's leaderless escalation can force-campaign — mirrors the
            # real genesis smoke's survivor-serves GET (leg E, line 142).
            for i in survivors:
                c.admin_kv_get(TENANT, KEY, node=i)
            ln = c.leader_now(TENANT, nodes=survivors)
            if ln is not None and c.admin_kv_put(TENANT, KEY, V2, node=ln).status == 204:
                ok = True
                break
            time.sleep(0.3)
        if ok:
            return "pass"
        diagnose(c, leader, survivors, nodes)
        return "fail-legE"


def main() -> int:
    max_runs = int(sys.argv[1]) if len(sys.argv) > 1 else 12
    tally = {"pass": 0, "fail-legE": 0, "fail-other": 0}
    for r in range(1, max_runs + 1):
        print(f"\n########## RUN {r}/{max_runs} ##########")
        try:
            outcome = run_once(r)
        except Exception as e:
            print(f"  [run {r}] harness exception: {e!r}")
            outcome = "fail-other"
        tally[outcome] += 1
        print(f"  [run {r}] => {outcome}   tally={tally}")
        if outcome == "fail-legE":
            print(f"\nCaptured a leg-E failure on run {r}. Stopping.")
            break
    print(f"\nFINAL tally over {sum(tally.values())} runs: {tally}")
    return 0 if tally["fail-legE"] or tally["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
