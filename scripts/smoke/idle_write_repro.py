#!/usr/bin/env python3
"""rove#353 repro — the first WRITE to an idle tenant 502s (write-ambiguous).

Field shape (prod front-door access log): after an idle gap of tens of
minutes, one `POST /device_authorization` answered
`502 ... reason=write-ambiguous attempts=1 nodes_tried=3` in 0-3ms, the next
identical request succeeded. Reads over the same window never failed.

This drives the same shape deliberately: warm the tenant, idle past each of
the interesting timeouts, then issue ONE write and record the outcome. Reads
are issued alongside so an asymmetry between the two shows up directly.

The idle steps straddle the timeouts that could explain it:
  5s   the front's upstream (front->worker) leg idle reap
  10s  the worker's server-side h2 idle reap
  2s   the raft hibernation window (leader stops being ticked)

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# A write on POST, a read on GET — same handler, so an asymmetry between the
# two is about the method's replay-safety, not about different code paths.
SRC = """\
export function handler() {
    if (request.method === "POST") {
        kv.set("probe", "v");
        response.status = 204;
        return "";
    }
    return "value:" + (kv.get("probe") ?? "none");
}
"""

# The default steps straddle every timeout the header names — 2s hibernation,
# 5s front leg, 10s worker h2 — and nothing else. Each step sleeps TWICE (once
# before the write, once before the read), so the list IS this smoke's runtime.
#
# It used to run [3, 6, 12, 30, 60]: 222s of sleeping, of which the 30 and 60
# steps were 180s spent probing gaps far past every timeout in the tree. Those
# were EXPLORATORY — rove#353's field report was a ~40-minute gap, so the long
# steps were hunting a mechanism none of the known timeouts explained. #353 is
# closed and the mechanism is known, and a 60s step never approached 40 minutes
# anyway. What remains is the regression guard, and the guard only needs the
# steps that cross the timeouts.
#
# Pass seconds on the command line to probe a longer gap by hand.
IDLE_STEPS = [3.0, 6.0, 12.0]
if len(sys.argv) > 1:
    IDLE_STEPS = [float(a) for a in sys.argv[1:]]


def main() -> int:
    failures = []
    rounds = []

    with V2Cluster.spawn("idlewrite", nodes=3) as c:
        print("setup: provision + deploy")
        r = c.provision("acme")
        if r.status != 200:
            print(f"  FAIL provision → {r.status} {r.body!r}")
            return 1
        # Deploy on the group leader (a follower 421s the release write).
        lead = c.leader_node("acme")
        print(f"  leader = node {lead}")
        c.deploy_handlers("acme", {"index.mjs": rpc_wrap(SRC)}, node=lead or 0)
        served = c.wait_for_handler("acme", "/?fn=handler")
        if served.status != 200:
            print(f"  FAIL handler never served → {served.status} {served.body!r}")
            c.dump_log("front", grep=["front-access"], tail=10)
            return 1

        # Warm: one write so the group has a leader and the front has a
        # pooled leg to the node that served it.
        w = c.request("acme", "/?fn=handler", method="POST", data=b"x")
        print(f"  warm write → {w.status}")

        for idle in IDLE_STEPS:
            print(f"\n=== idle {idle}s, then ONE write ===")
            time.sleep(idle)
            t0 = time.time()
            w = c.request("acme", "/?fn=handler", method="POST", data=b"x")
            dt = (time.time() - t0) * 1000
            print(f"  write after {idle}s idle → {w.status} in {dt:.0f}ms  {w.body[:60]!r}")
            rounds.append((idle, "POST", w.status))
            if w.status != 204 and w.status != 200:
                failures.append(f"write after {idle}s idle → {w.status}")

            # An immediate retry: the field report says the NEXT one works.
            w2 = c.request("acme", "/?fn=handler", method="POST", data=b"x")
            print(f"  immediate retry     → {w2.status}")

            # Same gap, but a read — the field report says reads never failed.
            time.sleep(idle)
            t0 = time.time()
            g = c.request("acme", "/?fn=handler", method="GET")
            dt = (time.time() - t0) * 1000
            print(f"  read  after {idle}s idle → {g.status} in {dt:.0f}ms")
            rounds.append((idle, "GET", g.status))
            if g.status != 200:
                failures.append(f"read after {idle}s idle → {g.status}")

        print("\n--- front access log (writes + 502s) ---")
        c.dump_log("front", grep=["front-access"], tail=60)
        print("\n--- front log (warnings) ---")
        c.dump_log("front", grep=["warn", "error"], tail=30)

    print("\n=== summary ===")
    for idle, method, status in rounds:
        print(f"  idle={idle:>5}s {method:<4} → {status}")
    if failures:
        print(f"\nREPRODUCED — {len(failures)} failure(s):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nNOT reproduced — every first-after-idle request succeeded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
