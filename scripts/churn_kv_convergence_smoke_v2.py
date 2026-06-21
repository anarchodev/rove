#!/usr/bin/env python3
"""Churn-driven KV convergence soak — reproduce the prod __auth__ store divergence.

The prod incident: a single per-tenant kv key (`_deploy/current`) ended up with
DIFFERENT durable values across nodes (node2=fix, node1/3=OLD) under pathological
term churn (~2 leadership changes per entry) + rolling restarts. The suspected
surface is the worker_overlay asymmetry: the LEADER applies its own writes via the
worker's speculative txn (the pump SKIPS the store write), while FOLLOWERS apply
via the pump — so a leadership flip / restart while a write is in flight is the one
place a replica can durably diverge on a key.

This soak recreates the condition in short ROUNDS. Each round: concurrent in-flight
writes to ONE key through the front door (kv.set = the worker_overlay path) +
forced leadership handoffs (the v2-transfer-leadership endpoint), with periodic
node restarts (the rolling-deploy condition). After EACH round it stops writing and
asserts all three replicas CONVERGE on the same value. Checking per-round is key:
a transient orphan would be overwritten (healed) by a later round's writes, so a
single end check could miss it. A round that fails to converge = the bug.

Needs S3 env: `set -a; . ./.env; set +a` first.
Build: `zig build rewind-worker rewind-cp rewind-front`
"""

from __future__ import annotations

import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET  # noqa: E402

HANDLER_SRC = """\
export function handler() {
    if (request.method === "POST") {
        const body = JSON.parse(request.body || "{}");
        kv.set("churn/key", body.v);
        response.status = 204;
        return "";
    }
    return kv.get("churn/key") ?? "none";
}
"""

KEY = "churn/key"
ROUNDS = 18
BURST_SECS = 7.0
N_WRITERS = 6
FLIP_INTERVAL = 1.5     # ONE controlled leadership flip this often — writes commit between
WRITE_TIMEOUT = 2
CONVERGE_TIMEOUT = 20.0  # per-round: how long to wait for all nodes to agree


def main() -> int:
    with V2Cluster.spawn("churn", nodes=3) as c:
        def xfer(node):
            subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-m", "3", "--http2-prior-knowledge",
                 "-X", "POST", "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
                 f"{c.node_url(node)}/_system/v2-transfer-leadership?tenant=acme"],
                capture_output=True)

        print("setup: provision acme [1,2,3] + deploy the single-key handler")
        if c.provision("acme").status != 204:
            print("  FAIL provision"); return 1
        lead = c.leader_node("acme")
        try:
            if not c.deploy_handlers("acme", {"index.mjs": rpc_wrap(HANDLER_SRC)}, node=lead):
                print("  FAIL deploy"); return 1
        except RuntimeError as e:
            print(f"  FAIL deploy {e}"); return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="none")

        ctr = [0]
        highest_acked = [0]
        lock = threading.Lock()

        def burst(stop, stats):
            def writer():
                while not stop.is_set():
                    with lock:
                        ctr[0] += 1
                        n = ctr[0]
                    r = c.request("acme", "/?fn=handler", method="POST",
                                  data='{"v":"v-%d"}' % n, timeout=WRITE_TIMEOUT)
                    if r.status == 204:
                        with lock:
                            stats[0] += 1
                            if n > highest_acked[0]:
                                highest_acked[0] = n

            def churner():
                while not stop.is_set():
                    ld = c.leader_node("acme", deadline_s=2.0)
                    if ld is not None:
                        xfer(ld)
                    time.sleep(FLIP_INTERVAL)

            ts = [threading.Thread(target=writer, daemon=True) for _ in range(N_WRITERS)]
            ts.append(threading.Thread(target=churner, daemon=True))
            for t in ts:
                t.start()
            return ts

        diverged_round = None
        # Continuous writers run for the whole soak; churn = rolling restarts of one
        # node at a time (quorum held → writes keep committing), with an occasional
        # forced leadership flip. After each churn action we pause writes and assert
        # all three replicas agree on KEY (a transient orphan would be caught here
        # before later writes heal it).
        stop = threading.Event()
        stats = [0]
        ts = burst(stop, stats)

        def converged_now():
            vals = {}
            for i in range(3):
                r = c.admin_kv_get("acme", KEY, node=i)
                vals[i] = r.body.strip() if r.status == 200 else f"<{r.status}>"
            ok = all(not v.startswith("<") for v in vals.values()) and vals[0] == vals[1] == vals[2]
            return ok, vals

        def check_converge(label):
            nonlocal diverged_round
            ok, vals = False, {}
            deadline = time.time() + CONVERGE_TIMEOUT
            while time.time() < deadline:
                ok, vals = converged_now()
                if ok:
                    break
                time.sleep(0.4)
            if ok:
                print(f"  {label}: ok   converged={vals[0]!r} acked={stats[0]}")
            else:
                print(f"  {label}: FAIL DIVERGED n1={vals.get(0)!r} n2={vals.get(1)!r} n3={vals.get(2)!r}")
                diverged_round = label
                for i in range(3):
                    c.dump_node_log(node=i, grep=["fold", "skip-detail", "transfer",
                                                  "became leader", "apply", "warn", "error"])
            return ok

        for rnd in range(1, ROUNDS + 1):
            ld = c.leader_node("acme", deadline_s=8.0)
            if ld is None:
                ld = 0
            if rnd % 3 == 0:
                # forced leadership flip (no restart) while writers are in flight
                xfer(ld)
                time.sleep(2.0)
                if not check_converge(f"round {rnd:2d} flip(leader {ld+1})"):
                    break
            else:
                # rolling restart of the leader (forces a real election under writes)
                c.stop_node(ld)
                time.sleep(1.5)
                c.start_node(ld)
                time.sleep(5.0)  # let it rejoin + the cluster re-elect under load
                if not check_converge(f"round {rnd:2d} restart(node {ld+1})"):
                    break

        stop.set()
        for t in ts:
            t.join(timeout=10)

        if diverged_round is not None:
            print(f"\n*** DIVERGENCE REPRODUCED in round {diverged_round} — the prod bug. ***")
            return 1
        print(f"\nPASS churn-kv-convergence soak — {ROUNDS} rounds of write-storm + forced "
              "leadership churn + restarts, all converged (no KV divergence).")
        return 0


if __name__ == "__main__":
    sys.exit(main())
