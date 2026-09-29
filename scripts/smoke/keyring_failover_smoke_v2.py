#!/usr/bin/env python3
"""A sealed value survives a leader failover (rove#666).

A value written under a `shredKey` identity is sealed with a key the leader
mints and pushes to its peers as sealed shards. Those shards land on each
peer's DISK. The question this smoke asks is whether the node that takes
over can actually open the value — or whether it answers as if the key had
been destroyed, which a reader cannot tell apart from an erasure.

The precondition that makes it bite is ordinary: every replica opens the
tenant's slot when the tenant is placed on it (plan delivery at attach), and
that is BEFORE the tenant has minted anything. The smoke makes that explicit
rather than relying on it — it opens the slot on every node first.

Then: seal a value under an identity on the leader, read it back (the
control: the leader opens its own value), SIGKILL the leader, and read it
through the node that takes over. The only acceptable answers are the
plaintext, or a refusal that says this node cannot vouch for its keys.
Anything that reads as "no such value" is live data reported as erased.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import hashlib
import signal
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, _curl  # noqa: E402

TENANT = "kfail"
MARKER = "herring-failover-3b17"

SRC = (
    'export default function ({ kv, shredKey }) {\n'
    '  const fn = ((request.query || "").match(/fn=([^&]+)/) || [])[1];\n'
    '  if (fn === "seal") { shredKey("u_fail"); kv.set("card", "' + MARKER + '"); return "sealed"; }\n'
    '  if (fn === "read") { shredKey("u_fail"); return "read:" + kv.get("card"); }\n'
    '  if (fn === "ready") return "ready";\n'
    '  response.status = 404;\n'
    '  return "no such fn";\n'
    '}\n'
)


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== a sealed value survives a leader failover (rove#666) ===")
    with V2Cluster.spawn("kfail", nodes=3) as c:
        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"{r.status} {r.body!r}")
        c.wait_for_membership(TENANT, voters=3)
        c.deploy_handlers(TENANT, {"index.mjs": SRC})
        c.wait_for_handler(TENANT, "/?fn=ready", want_body="ready", timeout_s=45.0)

        print("step 1: every replica opens the tenant's slot, before anything is minted")
        opened = 0
        for i in range(len(c.node_ports)):
            pr = _curl(f"{c.node_url(i)}/_system/v2-plan?tenant={urllib.parse.quote(TENANT)}",
                       timeout=10.0, headers={"X-Rewind-Move-Secret": MOVE_SECRET})
            opened += pr.status == 200
        check("slot opened on all three nodes", opened == 3, f"{opened}/3")

        print("step 2: seal a value under an identity, and read it back on the leader")
        deadline = time.time() + 60.0
        while True:
            r = c.request(TENANT, "/?fn=seal", timeout=30.0)
            # The first bind after provisioning can find the pool not yet
            # filled; the hot path never waits for it.
            if r.status == 200 or time.time() > deadline or "PoolEmpty" not in r.body:
                break
            time.sleep(1.0)
        check("sealed write → 200", r.status == 200 and r.body == "sealed", f"{r.status} {r.body!r}")
        r = c.request(TENANT, "/?fn=read", timeout=30.0)
        check("CONTROL: the leader reads its own sealed value",
              r.status == 200 and r.body == "read:" + MARKER, f"{r.status} {r.body!r}")

        print("step 3: SIGKILL the tenant's leader")
        leader_idx = None
        deadline = time.time() + 20.0
        while time.time() < deadline and leader_idx is None:
            for i in range(len(c.node_ports)):
                lr = _curl(f"{c.node_url(i)}/_system/v2-member-status?tenant={urllib.parse.quote(TENANT)}",
                           timeout=5.0, headers={"X-Rewind-Move-Secret": MOVE_SECRET})
                if lr.status == 200:
                    leader_idx = i
                    break
            if leader_idx is None:
                time.sleep(0.3)
        check("found the tenant leader", leader_idx is not None, f"leader_idx={leader_idx}")
        if leader_idx is None:
            print(f"\nFAILED ({len(failures)}): {failures}")
            return 1
        # The push reached the other replicas' DISKS: every shard file the
        # leader holds for THIS tenant, each of them holds too — so whatever
        # the new leader answers, the key material is there to answer from.
        # (The keyring directory is the first 16 bytes of sha256(tenant), hex.)
        tenant_dir = hashlib.sha256(TENANT.encode()).hexdigest()[:32]

        def shard_files(i):
            d = c.data_dirs[i] / "keyrings" / tenant_dir
            return {p.name for p in d.glob("*.kr") if p.name != "tenant.kr"} if d.exists() else set()
        leader_shards = shard_files(leader_idx)
        check("the leader holds shard files", bool(leader_shards), f"{sorted(leader_shards)}")
        for i in range(len(c.node_ports)):
            if i == leader_idx:
                continue
            missing = leader_shards - shard_files(i)
            check(f"node {i + 1} holds every shard file the leader does",
                  not missing, f"missing {sorted(missing)}")

        lp = c.node_procs[leader_idx]
        lp._expected_kill = True
        lp.send_signal(signal.SIGKILL)
        lp.wait()

        print("step 4: read the value through the node that takes over")
        deadline = time.time() + 60.0
        r = None
        while time.time() < deadline:
            r = c.request(TENANT, "/?fn=read", timeout=30.0)
            if r.status == 200:
                break
            time.sleep(0.5)
        check("the new leader answers", r is not None and r.status == 200,
              f"{r.status if r else None} {r.body[:120] if r else ''!r}")
        body = r.body if r else ""
        check("the new leader does NOT report the live value as erased",
              body != "read:null",
              "read:null — the key is on this node's disk (checked above), and its "
              "keyring answered as if it had been destroyed")
        check("the new leader opens the value",
              body == "read:" + MARKER, f"{body[:120]!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a sealed value reads back through the node that took over.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
