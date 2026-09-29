#!/usr/bin/env python3
"""A node that missed the keyring pushes repairs itself from its peers (rove#666).

A key reaches the tenant's replicas by PUSH: the leader offers each shard to
the voters that are up when it is written, and never offers it again. A node
that is down while keys are minted therefore comes back short of them — and
can only ever answer `unverified` for a value sealed under one, unless it
asks. This is the multi-node test the issue names:

  1. mint under a leader while one replica is DOWN;
  2. bring it back, and assert it converges to `complete` holding every key
     the leader holds (`/_system/v2-keyring-status`), with the shards on its
     own disk — which only a pull can have put there;
  3. make it the leader, and read a value sealed under a key its keyring did
     not hold when it came back.

Step 3 has no leader-transfer control, so it kills the current leader until
the repaired node wins an election, restarting the killed one each round.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, _curl  # noqa: E402

TENANT = "krepair"
MARKER = "mackerel-repair-91c2"

SRC = (
    'export default function ({ kv, shredKey }) {\n'
    '  const fn = ((request.query || "").match(/fn=([^&]+)/) || [])[1];\n'
    '  if (fn === "seal") { shredKey("u_rep"); kv.set("card", "' + MARKER + '"); return "sealed"; }\n'
    '  if (fn === "read") { shredKey("u_rep"); return "read:" + kv.get("card"); }\n'
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


# The keyring directory is named for the tenant, hashed (`Keyring.init`: the
# first 16 bytes of sha256(tenant id), hex) — so every assertion below is
# about THIS tenant's keys, never another tenant's on the same node.
TENANT_DIR = hashlib.sha256(TENANT.encode()).hexdigest()[:32]


def shard_files(c, i):
    d = c.data_dirs[i] / "keyrings" / TENANT_DIR
    return {p.name for p in d.glob("*.kr") if p.name != "tenant.kr"} if d.exists() else set()


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    def bail():
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1

    print("=== a replica that missed the keyring pushes repairs itself (rove#666) ===")
    with V2Cluster.spawn("krepair", nodes=3) as c:
        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"{r.status} {r.body!r}")
        c.wait_for_membership(TENANT, voters=3)
        c.deploy_handlers(TENANT, {"index.mjs": SRC})
        c.wait_for_handler(TENANT, "/?fn=ready", want_body="ready", timeout_s=45.0)
        for i in range(3):
            system_get(c, i, "v2-plan")  # open the slot, as attach does

        leader = c.leader_node(TENANT)
        check("found the tenant leader", leader is not None, f"{leader}")
        if leader is None:
            return bail()
        down = next(i for i in range(3) if i != leader)

        print(f"step 1: stop node {down + 1}, then mint under the leader")
        c.stop_node(down)
        deadline = time.time() + 60.0
        while True:
            r = c.request(TENANT, "/?fn=seal", timeout=30.0)
            if r.status == 200 or time.time() > deadline or "PoolEmpty" not in r.body:
                break
            time.sleep(1.0)
        check("sealed write → 200 with a replica down", r.status == 200 and r.body == "sealed",
              f"{r.status} {r.body!r}")
        lead_status = status(c, leader)
        check("the leader holds its keys and vouches for them",
              bool(lead_status and lead_status["complete"] and lead_status["keys"] > 0), f"{lead_status}")
        lead_shards = shard_files(c, leader)
        check("CONTROL: the down node's disk lacks the leader's shards",
              bool(lead_shards - shard_files(c, down)),
              "it already has them — nothing here would need a pull")

        print(f"step 2: bring node {down + 1} back — it must repair itself")
        c.start_node(down)
        deadline = time.time() + 90.0
        st = None
        while time.time() < deadline:
            st = status(c, down)
            if st and st["complete"] and st["keys"] == lead_status["keys"]:
                break
            time.sleep(1.0)
        check("the returning node converges to complete, holding every key",
              bool(st and st["complete"] and st["keys"] == lead_status["keys"]),
              f"node={st} leader={lead_status}")
        missing = lead_shards - shard_files(c, down)
        check("the shards it missed are on its own disk now", not missing, f"missing {sorted(missing)}")

        print(f"step 3: make node {down + 1} the leader, and read through it")
        body = None
        for attempt in range(8):
            cur = c.leader_node(TENANT)
            if cur == down:
                r = c.request_retry(TENANT, "/?fn=read", want_status=200, deadline_s=30.0)
                body = r.body
                break
            if cur is None:
                time.sleep(1.0)
                continue
            c.kill_node(cur)
            time.sleep(0.5)
            nxt = c.leader_node(TENANT, deadline_s=30.0)
            if nxt != down:
                # Not this time: bring the killed node back and try again.
                c.start_node(cur)
                c.wait_for_membership(TENANT, voters=3)
                time.sleep(2.0)
        # Every node back up before step 4: the loop's last kill is never
        # restarted inside it.
        for i in range(3):
            if i not in c.alive_nodes():
                c.start_node(i)
        c.wait_for_membership(TENANT, voters=3)
        check("the repaired node became the leader", body is not None, "never won an election in 8 rounds")
        if body is not None:
            check("the repaired node opens a value sealed while it was down",
                  body == "read:" + MARKER, f"{body[:120]!r}")

        print("step 4: a replica with NO keyring at all — secret included — adopts one")
        # A move destination, or a voter added after birth, takes a tenant up
        # with no secret: the CP hands one out only at birth. The minimal
        # reproduction: take a replica's keyring for this tenant away whole.
        leader = c.leader_node(TENANT, deadline_s=30.0)
        bare = next((i for i in c.alive_nodes() if i != leader), None)
        check("a non-leader replica to strip", bare is not None and leader is not None, f"leader={leader}")
        if bare is not None and leader is not None:
            c.stop_node(bare)
            import shutil
            kdir = c.data_dirs[bare] / "keyrings" / TENANT_DIR
            check("the replica held this tenant's keyring before it was taken",
                  (kdir / "tenant.kr").exists(), f"{kdir}")
            shutil.rmtree(kdir)
            c.start_node(bare)
            want = status(c, leader)
            deadline = time.time() + 90.0
            st = None
            while time.time() < deadline:
                st = status(c, bare)
                if st and st["keyring"] and st["complete"] and want and st["keys"] == want["keys"]:
                    break
                time.sleep(1.0)
            check("the bare replica adopts the tenant's keyring from its peers",
                  bool(st and st["keyring"] and st["complete"] and want and st["keys"] == want["keys"]),
                  f"node={st} leader={want}")
            if not (st and st["keyring"] and st["complete"]):
                c.dump_node_log(bare, grep=["keyring", "pull", TENANT])
            check("its secret file is back on disk",
                  (c.data_dirs[bare] / "keyrings" / TENANT_DIR / "tenant.kr").exists())

    if failures:
        return bail()
    print("\nPASS — a replica that missed every push pulled its keyring and serves the sealed value.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
