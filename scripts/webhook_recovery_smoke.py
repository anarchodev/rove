#!/usr/bin/env python3
"""Webhook recovery smoke — Phase 5 PR-3.

Verifies the JS-shim webhook recovery mechanism: when a delayed
`webhook.send` rides through a leader failover, the new leader's
`sweepOwedRetriesOnPromotion` picks up the orphan `_send/owed/{id}`
marker and fires the delayed request. This is the JS-shim sibling of
`leader_failover_smoke.py` — replaces what `SendDispatch.recover()`
used to guarantee.

Pattern:
  1. Fire a webhook.send with `fire_at_ns ≈ now+4s` (the marker
     lands in raft but the http.fetch doesn't fire until then).
  2. Kill the original leader inside the delay window.
  3. New leader's promotion sweep walks `_send/owed/` and fires.
  4. Verify the on_result kv write landed (assertable via offline
     `loop46 kv-get` after cluster shutdown).
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
WAIT_FOR_RESULT_S = 20.0


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="webhook-recovery",
        http_base=8480,
        raft_base=40480,
        files_port=8482,
        log_port=8483,
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
        # failover so the delayed webhook the new leader's sweep
        # fires can actually reach wb on the survivor.
        survivor_node = (orig_leader + 1) % 3
        survivor_port = c.addrs.http_port(survivor_node)
        print(f"ok  initial leader: node {orig_leader} at {c.addrs.http[orig_leader]}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)

        wb_url = f"https://{WB_HOST}:{survivor_port}/"
        acme_origin = f"https://{ACME_HOST}:{orig_port}"

        # Fire delayed webhook.send (acme/httpfire.fireDelayed → JS-shim
        # writes the marker but does NOT call http.fetch — `fire_at_ns
        # > now` makes the shim sweep-only). Replicates the marker
        # through raft, then we kill the leader before the sweep window.
        deadline = time.monotonic() + 20.0
        sched_id = ""
        last_resp = None
        while time.monotonic() < deadline:
            args_json = json.dumps([wb_url, "recovery", DELAY_MS])
            args_enc = urllib.parse.quote(args_json)
            r = curl(cc, f"{acme_origin}/httpfire?fn=fireDelayed&args={args_enc}")
            last_resp = r
            if r.status == 200:
                try:
                    sched_id = json.loads(r.body).get("id", "")
                    if sched_id:
                        break
                except (json.JSONDecodeError, KeyError):
                    pass
            time.sleep(0.2)
        if not sched_id:
            sys.exit(f"FAIL fireDelayed: {last_resp.status if last_resp else '?'} "
                     f"{last_resp.body if last_resp else ''}")
        print(f"ok  scheduled delayed webhook.send (id={sched_id}, delay={DELAY_MS}ms)")

        time.sleep(2)
        print("ok  waited for marker replication through raft")

        time.sleep(KILL_AFTER_S)
        print(f"killing original leader node {orig_leader} (inside the delay window)…")
        c.stop_node(orig_leader)

        # Wait for new leader. The promotion fires
        # `sweepOwedRetriesOnPromotion` on every worker; the partitioned
        # walk picks up the orphan `_send/owed/{id}` marker on the
        # worker hash(tenant_id) maps to.
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

        print(f"waiting {WAIT_FOR_RESULT_S}s for the recovery sweep + on_result kv write…")
        time.sleep(WAIT_FOR_RESULT_S)

        # Shut everything down so kv-get can read cluster.kv.
        for idx in range(3):
            if c.workers[idx].poll() is None:
                c.stop_node(idx)

    # Cluster shutdown happened via __exit__ already.
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
    print("ok  result.ok == true — recovery sweep fired the orphan marker")

    print()
    print("PASS webhook-recovery smoke (JS-shim sibling of SendDispatch.recover)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
