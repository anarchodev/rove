#!/usr/bin/env python3
"""Leader-failover smoke — production.md §7.

Python port of `scripts/leader_failover_smoke.sh`. Verifies the at-least-
once + version-counter dedup contract across a forced leadership change:
schedule a delayed http.send, kill the leader, new leader fires it, the
callback hits acme's httpresult, the on_result kv write survives.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"
DELAY_MS = 4000
KILL_AFTER_S = 1.0
WAIT_FOR_RESULT_S = 15.0


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="leader-failover",
        http_base=8470,
        raft_base=40470,
        files_port=8472,
        log_port=8473,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        workers_per_node=1,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe", "--snapshot-interval-ms", "500"],
    )
    with cluster as c:
        time.sleep(2)
        c.discover_leader()
        orig_leader = c.leader_idx
        orig_port = c.addrs.http_port(orig_leader)
        # Pick a node we WON'T kill — its port stays alive across the
        # failover so the delayed http.send the new leader fires can
        # actually reach wb. Hardcoding `orig_port` (as before) meant
        # the curl hit the dead port and reported CurlCallFailed.
        survivor_node = (orig_leader + 1) % 3
        survivor_port = c.addrs.http_port(survivor_node)
        print(f"ok  initial leader: node {orig_leader} at {c.addrs.http[orig_leader]}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)

        # Fire delayed http.send. Wait for acme's handler first.
        # Schedule fires the curl from the NEW leader (post-failover) —
        # target the survivor port so libcurl reaches a live listener.
        wb_url = f"https://{WB_HOST}:{survivor_port}/"
        acme_origin = f"https://{ACME_HOST}:{orig_port}"

        deadline = time.monotonic() + 20.0
        sched_id = ""
        while time.monotonic() < deadline:
            args_json = json.dumps([wb_url, "failover", DELAY_MS])
            args_enc = urllib.parse.quote(args_json)
            r = curl(cc, f"{acme_origin}/httpfire?fn=fireDelayed&args={args_enc}")
            if r.status == 200:
                try:
                    sched_id = json.loads(r.body).get("id", "")
                    if sched_id:
                        break
                except (json.JSONDecodeError, KeyError):
                    pass
            time.sleep(0.2)
        if not sched_id:
            sys.exit(f"FAIL fireDelayed: {r.status} {r.body}")
        print(f"ok  scheduled delayed http.send (id={sched_id}, delay={DELAY_MS}ms)")

        time.sleep(2)
        print("ok  waited for schedule replication")

        time.sleep(KILL_AFTER_S)
        print(f"killing original leader node {orig_leader}…")
        c.stop_node(orig_leader)

        # Wait for new leader.
        new_leader = None
        new_leader_port = 0
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline and new_leader is None:
            for i in range(3):
                if i == orig_leader:
                    continue
                p = c.addrs.http_port(i)
                try:
                    r = curl(
                        cc, f"https://{ADMIN_HOST}:{p}/_system/leader",
                        headers={"Authorization": f"Bearer {TOKEN}"},
                        timeout=2.0,
                    )
                except (subprocess.TimeoutExpired, RuntimeError):
                    continue
                if r.status == 200:
                    new_leader = i
                    new_leader_port = p
                    break
            time.sleep(0.5)
        if new_leader is None:
            sys.exit("FAIL no new leader elected within 20s")
        print(f"ok  new leader: node {new_leader} (port {new_leader_port})")

        print(f"waiting {WAIT_FOR_RESULT_S}s for on_result kv write to land…")
        time.sleep(WAIT_FOR_RESULT_S)

        # Shut everything down so kv-get can read cluster.kv.
        for idx in range(3):
            if c.workers[idx].poll() is None:
                c.stop_node(idx)

    # Cluster shutdown happened via __exit__ already (we left the with block).
    # Verify via offline kv-get.
    result_key = f"http/result/{sched_id}"
    bin_loop46 = BIN_DIR / "loop46"
    rc = subprocess.run(
        [str(bin_loop46), "kv-get",
         "--data-dir", str(c.addrs.data_dirs[new_leader]),
         "--store", "acme",
         "--key", result_key],
        capture_output=True, text=True,
    )
    result = rc.stdout.strip()
    if not result or '"ok"' not in result:
        sys.exit(f"FAIL on_result kv write missing: {rc.stdout!r} {rc.stderr!r}")
    print(f"ok  on_result kv write landed on acme via new leader")
    print(f"    result: {result}")

    parsed = json.loads(result)
    if not parsed.get("ok"):
        sys.exit(f"FAIL result.ok != true: {parsed}")
    print("ok  result.ok == true — http.send completed successfully across failover")

    print()
    print("PASS leader-failover smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
