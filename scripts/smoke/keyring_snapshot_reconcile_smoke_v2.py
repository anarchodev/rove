#!/usr/bin/env python3
"""A node that catches up by snapshot drops the keys destroyed while it was away.

An identity's key is destroyed by a raft entry: `_keys/dead/{slot}` commits,
and every node applying it evicts the key and rewrites its shard without it.
A node that was DOWN for the destroy, and returns past the leader's
compaction floor, never applies that entry — it installs a snapshot whose
store already holds the tombstone. Its keyring must still reconcile against
it, or the destroyed key survives on that node, in memory and on disk, and
anything that resolves a slot directly (the logs door opening a sealed
payload) opens what was erased.

  1. seal a value under an identity; every node holds its key;
  2. stop a follower, destroy the identity, then write well past the
     snapshot grace so the leader compacts beyond the follower's log;
  3. CONTROL: the destroy removed the key on the nodes that stayed up;
  4. restart the follower; it catches up (by snapshot — asserted), and must
     converge to the leader's key count, destroyed key gone.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

# Small grace: the leader compacts past a stopped follower quickly, so its
# return is a snapshot install rather than a log replay.
os.environ["REWIND_SNAPSHOT_GRACE"] = "20"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, _curl  # noqa: E402

TENANT = "ksnap"

SRC = (
    'export default function ({ kv, shredKey }) {\n'
    '  const q = request.query || "";\n'
    '  const fn = (q.match(/fn=([^&]+)/) || [])[1];\n'
    '  if (fn === "seal") { shredKey("u_gone"); kv.set("card", "sprat-snapshot-7c4e"); return "sealed"; }\n'
    '  if (fn === "erase") { shredKey.destroy("u_gone"); return "erased"; }\n'
    '  if (fn === "fill") { const n = (q.match(/n=([0-9]+)/) || [])[1]; kv.set("fill/" + n, "x"); return "ok"; }\n'
    '  if (fn === "ready") return "ready";\n'
    '  response.status = 404;\n'
    '  return "no such fn";\n'
    '}\n'
)


def system_get(c, i, route):
    return _curl(f"{c.node_url(i)}/_system/{route}?tenant={urllib.parse.quote(TENANT)}",
                 timeout=10.0, headers={"X-Rewind-Move-Secret": MOVE_SECRET})


def status(c, i):
    r = system_get(c, i, "v2-keyring-status")
    try:
        return json.loads(r.body) if r.status == 200 else None
    except json.JSONDecodeError:
        return None


def keys(c, i):
    st = status(c, i)
    return st["keys"] if st else None


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== a node caught up by snapshot drops the keys destroyed while it was away ===")
    with V2Cluster.spawn("ksnap", nodes=3) as c:
        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"{r.status} {r.body!r}")
        c.wait_for_membership(TENANT, voters=3)
        c.deploy_handlers(TENANT, {"index.mjs": SRC})
        c.wait_for_handler(TENANT, "/?fn=ready", want_body="ready", timeout_s=45.0)
        for i in range(3):
            system_get(c, i, "v2-plan")  # open the slot, as attach does

        print("step 1: seal a value under an identity")
        deadline = time.time() + 60.0
        while True:
            r = c.request(TENANT, "/?fn=seal", timeout=30.0)
            if r.status == 200 or time.time() > deadline or "PoolEmpty" not in r.body:
                break
            time.sleep(1.0)
        check("sealed write → 200", r.status == 200 and r.body == "sealed", f"{r.status} {r.body!r}")
        time.sleep(2.0)
        before = [keys(c, i) for i in range(3)]
        check("every node holds the same keys", len(set(before)) == 1 and before[0], f"{before}")

        leader = c.leader_node(TENANT)
        check("found the tenant leader", leader is not None, f"{leader}")
        if leader is None:
            print(f"\nFAILED ({len(failures)}): {failures}")
            return 1
        away = next(i for i in range(3) if i != leader)
        stayed = next(i for i in range(3) if i not in (leader, away))

        print(f"step 2: stop node {away + 1}, destroy the identity, write past the grace")
        c.stop_node(away)
        r = c.request_retry(TENANT, "/?fn=erase", want_status=200, deadline_s=30.0)
        check("destroy → 200", r.status == 200 and r.body == "erased", f"{r.status} {r.body!r}")
        for n in range(120):
            c.request_retry(TENANT, f"/?fn=fill&n={n}", want_status=200, deadline_s=15.0)

        print("step 3: CONTROL — the nodes that stayed up dropped the key")
        time.sleep(2.0)
        lead_keys, stayed_keys = keys(c, leader), keys(c, stayed)
        check("the leader holds one key fewer", lead_keys == before[0] - 1, f"{before[0]} → {lead_keys}")
        check("the follower that stayed holds one key fewer", stayed_keys == lead_keys,
              f"{stayed_keys} vs leader {lead_keys}")

        print(f"step 4: restart node {away + 1} — it catches up by snapshot")
        c.start_node(away)
        c.wait_for_membership(TENANT, voters=3)
        deadline = time.time() + 60.0
        caught = False
        while time.time() < deadline:
            r = c.node_kv_get(TENANT, "fill/119", node=away)
            if r.status == 200:
                caught = True
                break
            time.sleep(0.5)
        check("the returning node caught up", caught)
        # A leader logs each streamed catch-up it completes, by peer id —
        # whichever node leads by then, so read them all.
        streamed = False
        for i in range(3):
            if i == away:
                continue
            with open(c.log_paths[f"n{i + 1}"]) as f:
                streamed = streamed or f"peer={away + 1}: streamed catch-up" in f.read()
        check("it caught up by SNAPSHOT, not log replay (the case under test)", streamed,
              "no leader streamed it a snapshot — raise the fill count")

        deadline = time.time() + 30.0
        got = None
        while time.time() < deadline:
            got = keys(c, away)
            if got == lead_keys:
                break
            time.sleep(1.0)
        check("⭐ the returning node dropped the destroyed key", got == lead_keys,
              f"node={got} leader={lead_keys} — it still holds a key a destroy removed")
        if got != lead_keys:
            c.dump_node_log(away, grep=["keyring", "snapshot", TENANT])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a node that missed a destroy while away drops the key once it catches up.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
