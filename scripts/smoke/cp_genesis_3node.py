#!/usr/bin/env python3
"""3-CP cold-multi genesis test: does the CP directory group elect FROM EMPTY?

The 2026-06-24 outage was "cold N-node genesis doesn't elect on real nodes
(works in single-process repro)" — 3 nodes born with the full voter set sat as
followers, no campaign, no leader. This spins up THREE REAL rewind-cp processes
configured as a static 3-node CP cluster (REWIND_CP_VOTERS=1,2,3) and asks: with
the leaderless-escalation force-campaign fix in place, does the __directory__
group now elect a leader?

The directory group is pinned-active (always ticked), a voter set {1,2,3}, and
on cold start leaderId==0 — exactly the shape escalateLeaderless force-campaigns.

Probe: GET /_cp/leader on each node → 200 iff that node leads the directory
group. Classify:
  * a node returns 200 within the budget  → ELECTS (cold-multi CP works now)
  * no leader for the whole budget         → WEDGED (escalation didn't reach it
                                              or a different cold-multi bug)

Run:  set -a; . ./.env; set +a
      zig build rewind-cp -Doptimize=ReleaseFast
      python3 scripts/smoke/cp_genesis_3node.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import _curl, MOVE_SECRET  # noqa: E402
from v2_topology import spawn_cp  # noqa: E402

HTTP = [19090, 19091, 19092]
RAFT = [19101, 19102, 19103]
# Raft-transport bind IP per node. Default all-loopback (same-IP, distinct port).
# Set CP_RAFT_HOSTS=127.0.0.1,127.0.0.2,127.0.0.3 to bind DISTINCT IPs — exercises
# the connect-to-a-specific-peer-IP path that same-IP loopback short-circuits (one
# cross-host failure class). HTTP stays on 127.0.0.1:<port> for polling.
RAFT_HOSTS = os.environ.get("CP_RAFT_HOSTS", "127.0.0.1,127.0.0.1,127.0.0.1").split(",")
PEERS = ",".join(f"{RAFT_HOSTS[i]}:{RAFT[i]}" for i in range(3))
PEER_URLS = ",".join(f"http://127.0.0.1:{p}" for p in HTTP)
CLUSTERS = "cluster-1=" + ",".join(f"http://127.0.0.1:{18300 + i}" for i in range(3))


def leader_status(http_port):
    r = _curl(f"http://127.0.0.1:{http_port}/_cp/leader", timeout=3.0)
    return r.status


def main() -> int:
    pid = os.getpid()
    log_dir = f"/tmp/cp3-{pid}-log"
    subprocess.run(["mkdir", "-p", log_dir])
    data_dirs = [f"/tmp/cp3-{pid}-n{i + 1}" for i in range(3)]
    for d in data_dirs:
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)

    procs = []
    try:
        # CP_SPAWN_DELAY mimics the real-host ssh launch latency (~1s between
        # node starts). A simultaneous start gives a full dial mesh; a staggered
        # start may reproduce the cross-host single-connection-per-pair topology.
        delay = float(os.environ.get("CP_SPAWN_DELAY", "0"))
        print(f"spawning 3 CP nodes (cold-multi, voters=1,2,3, stagger={delay}s); logs in {log_dir}")
        for i in range(3):
            spawn_cp(
                procs, HTTP[i],
                clusters=CLUSTERS, hosts="", placement="",
                cp_data_dir=data_dirs[i],
                move_secret=MOVE_SECRET,
                node_id=i + 1, voters="1,2,3", peers=PEERS, peer_urls=PEER_URLS,
                name=f"cp{i + 1}", wait=False, log_dir=log_dir,
            )
            if delay > 0 and i < 2:
                time.sleep(delay)

        # Poll for a directory-group leader.
        deadline = time.time() + 25.0
        elected_at = None
        leader_node = None
        while time.time() < deadline:
            for i in range(3):
                try:
                    if leader_status(HTTP[i]) == 200:
                        leader_node = i + 1
                        elected_at = time.time()
                        break
                except Exception:
                    pass
            if leader_node is not None:
                break
            time.sleep(0.3)

        t0 = deadline - 25.0
        if leader_node is not None:
            print(f"\nELECTS ✓ — node {leader_node} leads the __directory__ group "
                  f"after {elected_at - t0:.1f}s")
            print(">>> cold-multi CP genesis WORKS with the fix → full 3-CP HA "
                  "is achievable (etcd/PD model).")
            return 0

        # Wedged — classify from the logs.
        print("\nWEDGED ✗ — no CP node led the __directory__ group within 25s")
        for i in range(3):
            log = os.path.join(log_dir, f"cp{i + 1}-{pid}.log")
            print(f"\n--- cp{i + 1} log tail (election lines) ---")
            try:
                with open(log) as f:
                    lines = f.readlines()
                hits = [ln.rstrip() for ln in lines
                        if any(k in ln.lower() for k in
                               ("leader", "campaign", "vote", "elect", "multi-node",
                                "listening", "directory", "error", "warn", "force"))]
                for ln in hits[-15:]:
                    print("  " + ln)
            except FileNotFoundError:
                print("  (no log)")
        print("\n>>> cold-multi CP does NOT elect → fall back to single-CP interim, "
              "or diagnose the cold-multi bug.")
        return 1
    finally:
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass
        for p in procs:
            try:
                p.wait(timeout=5)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass


if __name__ == "__main__":
    sys.exit(main())
