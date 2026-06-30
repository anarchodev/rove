#!/usr/bin/env python3
"""V2 group-recovery smoke — a HARD-crashed node recovers its tenant raft groups.

Regression test for the node-local `groups_manifest` durability fix. A tenant
group is recorded in the per-node `__groups__` manifest when the node creates it
(`recordGroup`). That manifest is a kvexp store whose `put` lands in the VOLATILE
overlay — so before the fix a SIGKILL lost the record, and on restart
`recoverGroups` read an empty manifest: the node only re-stood-up the genesis
`__admin__` group and silently DROPPED every other tenant's raft messages
("unknown group"), never rejoining those groups. The fix durabilizes the manifest
(folds the overlay into LMDB) on each record.

Sequence:
  1. provision acme [1,2,3], deploy, seed — all three hold the group.
  2. HARD-kill a follower (SIGKILL — no graceful flush; quorum 2/3 survives).
  3. write more while it is down.
  4. restart it.
  5. ⭐ it RECOVERS the acme group from its durable manifest (last_index > 0) and
     replicates the writes it missed (serves the post-downtime value).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set(body.key ?? "cc/value", body.value ?? "");
        response.status = 204;
        return "";
    }
    return "value:" + (kv.get("cc/value") ?? "none");
}
"""

SECRET = ["-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]


def _last_index(node_url, tenant="acme"):
    args = ["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
            "--http2-prior-knowledge", *SECRET,
            f"{node_url}/_system/v2-last-index?tenant={tenant}"]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    if (out[nl + 1:].strip() or "0") != "200":
        return 0
    try:
        return json.loads(out[:nl]).get("last_index", 0)
    except Exception:
        return 0


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("grouprec", nodes=3) as c:
        print("step 1: provision acme [1,2,3] + deploy + seed")
        check("provision → 204", c.provision("acme").status == 204)
        lead0 = c.leader_node("acme")
        if lead0 is None:
            check("leader present", False); return 1
        try:
            check("deploy → dep_id", bool(c.deploy_handlers(
                "acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead0)))
        except RuntimeError as e:
            check("deploy", False, str(e)); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="value:none")
        for i in range(20):
            c.request("acme", "/?fn=handler", method="POST",
                      data=f'{{"value":"seed-{i}"}}', timeout=10)
        time.sleep(1.5)  # let followers apply + (importantly) record the group

        lead = c.leader_node("acme")
        victim = next(i for i in range(3) if i != lead)
        vnid = victim + 1
        pre = _last_index(c.node_url(victim))
        check(f"follower node {vnid} holds the acme group before the kill",
              pre > 0, f"last_index={pre}")

        print(f"step 2: HARD-kill node {vnid} (SIGKILL — no graceful flush)")
        c.kill_node(victim)
        check(f"node {vnid} killed", c.node_procs.get(victim).poll() is not None)

        print(f"step 3: write while node {vnid} is down")
        w = c.request_retry("acme", "/?fn=handler", method="POST",
                            data='{"key":"during/down","value":"written-while-down"}',
                            want_status=204, deadline_s=15)
        check("write during downtime accepted (204)", w.status == 204, f"got {w.status}")

        print(f"step 4: restart node {vnid}")
        c.start_node(victim)

        print(f"step 5: ⭐ node {vnid} RECOVERS the acme group from its durable manifest")
        rec, vlast = False, 0
        t_end = time.time() + 20.0
        while time.time() < t_end:
            vlast = _last_index(c.node_url(victim))
            if vlast > 0:
                rec = True
                break
            time.sleep(0.5)
        check(f"⭐ node {vnid} recovered the acme group (lost it before the fix)",
              rec, f"victim last_index={vlast}")

        # And it replicates the write it missed (proves it rejoined, not just
        # re-created an empty group).
        repl, seen = False, ""
        for _ in range(40):
            seen = c.admin_kv_get("acme", "during/down", node=victim).body
            if "written-while-down" in seen:
                repl = True; break
            time.sleep(0.5)
        check(f"⭐ node {vnid} caught up the write it missed while down", repl,
              f"node{vnid} saw {seen!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS group-recovery smoke (v2) — a SIGKILL'd follower recovered its "
          "tenant raft group from the durabilized node-local manifest and caught "
          "up the writes it missed. ⭐")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
