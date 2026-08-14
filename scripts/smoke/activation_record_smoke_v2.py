#!/usr/bin/env python3
"""Every activation that commits a write leaves a log record (rove#539).

The log is the replay/audit surface: a committed write with no record is
unattributable state. The hazard is the DEAD-STREAM path — a client that
resets its stream while (or just after) the handler runs races the
capture: on prod, one activation of a duplicated pair committed its
counter increment and left no record while its twin (same code path,
milliseconds apart) logged fine.

The smoke drives two request populations at a kv-incrementing handler:

  * normal requests (the control — these must always record), and
  * ABORTED requests: the client tears the connection down immediately
    after sending, so the RST races the worker's dispatch. Whether the
    handler ran is the counter's call, not ours.

Then the one invariant: the counter's total movement equals the number
of records — every increment has exactly one record, no more, no less.
Both directions matter: a missing record is rove#539, a double record
is a duplicate activation (rove#532).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TENANT = "recorded"
SRC = """
export function put() {
  const n = (parseInt(kv.get("n") || "0", 10) || 0) + 1;
  kv.set("n", String(n));
  return { n: n };
}
export function get() {
  return { n: parseInt(kv.get("n") || "0", 10) || 0 };
}
"""
NORMAL = 8
ABORTED = 16


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("actrec", nodes=1) as c:
        c.spawn_log_server(poll_interval_ms=200)

        print("step 1: provision + deploy the counting handler")
        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"got {r.status}")
        dep = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(SRC)})
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")
        c.wait_for_handler(TENANT, "/?fn=get", want_status=200)

        rr = c.request(TENANT, "/?fn=get")
        n0 = int(json.loads(rr.body)["n"])

        print(f"step 2: {NORMAL} normal writes (the control)")
        ok_normal = 0
        for _ in range(NORMAL):
            rr = c.request(TENANT, "/?fn=put", method="POST", data="{}")
            if rr.status == 200:
                ok_normal += 1
        check("control writes all succeed", ok_normal == NORMAL,
              f"{ok_normal}/{NORMAL}")

        print(f"step 3: {ABORTED} writes whose client ABORTS immediately "
              "(RST races the dispatch)")
        # curl with a timeout far below the response latency: the request
        # (headers + tiny body) goes out, then curl tears the connection
        # down. The front relays the reset upstream; whether the worker's
        # dispatch had already started is the race under test.
        for _ in range(ABORTED):
            subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-m", "0.030",
                 "-X", "POST", "--data", "{}",
                 "-H", f"Host: {c.host_for(TENANT)}",
                 f"{c.front_url()}/?fn=put"],
                capture_output=True)

        print("step 4: settle, then compare counter movement to record count")
        # Writes from aborted requests may still be committing; poll the
        # counter until it stops moving.
        last_n = -1
        deadline = time.time() + 20.0
        while time.time() < deadline:
            rr = c.request(TENANT, "/?fn=get")
            if rr.status == 200:
                n = int(json.loads(rr.body)["n"])
                if n == last_n:
                    break
                last_n = n
            time.sleep(1.0)
        moved = last_n - n0
        print(f"    counter moved {moved} (control {NORMAL}, aborted {ABORTED} raced)")
        check("every control write landed", moved >= NORMAL, f"moved {moved}")

        # The records: every fn=put activation (status whatever) must have
        # exactly one record. fn=get probes are records too — count only
        # the puts. The push path is async; poll until the count is stable.
        def put_records() -> int:
            lr = c.log_get(f"{TENANT}/list?limit=200", timeout=15.0)
            if lr.status != 200:
                return -1
            recs = json.loads(lr.body).get("records", [])
            return len([x for x in recs if "fn=put" in (x.get("path") or "")])

        stable, prev = -1, -2
        deadline = time.time() + 40.0
        while time.time() < deadline:
            stable = put_records()
            if stable == prev and stable >= 0:
                break
            prev = stable
            time.sleep(2.0)
        print(f"    put records indexed: {stable}")
        check("⭐ one record per committed increment (no unrecorded activation,"
              " no duplicate)", stable == moved,
              f"counter moved {moved}, records {stable}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {moved} increments, {stable} records: every activation is on the books")
    return 0


if __name__ == "__main__":
    sys.exit(main())
