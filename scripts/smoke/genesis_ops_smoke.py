#!/usr/bin/env python3
"""Validate `rewind-ops genesis` end to end against a real genesis cluster.

V2Cluster.spawn(genesis=True) brings the binaries up cold-multi (full static
voter set) + registers node addresses, but provisions NOTHING. This test then
drives the OPERATOR command — `rewind-ops genesis` — to bring the empty cluster
to deploy-capable, and asserts __admin__ formed with 3 voters. It exercises the
command's arg parsing (ROVE_GENESIS_NODES), JSON bodies, and the
register→provision→confirm→reset orchestration against the live primitives.

Run:  set -a; . ./.env; set +a
      zig build rewind-worker rewind-cp rewind-front rewind-ops -Doptimize=ReleaseFast
      python3 scripts/smoke/genesis_ops_smoke.py
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, ROOT_TOKEN  # noqa: E402

OPS = Path(__file__).resolve().parent.parent.parent / "zig-out" / "bin" / "rewind-ops"


def main() -> int:
    nodes = 3
    with V2Cluster.spawn("gensops", nodes=nodes, genesis=True) as c:
        # Cluster is up + node addresses registered; NO tenant provisioned yet.
        env_file = f"/tmp/gensops-{os.getpid()}.env"
        worker_urls = ",".join(c.node_url(i) for i in range(nodes))
        # id=worker_raft,cp_raft(empty: single CP),worker_http
        genesis_nodes = ";".join(
            f"{i + 1}=127.0.0.1:{c.raft_ports[i]},,{c.node_url(i)}" for i in range(nodes))
        with open(env_file, "w") as f:
            f.write(f"ROVE_CP_URL_INTERNAL=http://127.0.0.1:{c.cp_port}\n")
            f.write(f"ROVE_WORKER_URLS={worker_urls}\n")
            f.write(f"REWIND_MOVE_SECRET={MOVE_SECRET}\n")
            f.write(f"REWIND_ROOT_TOKEN={ROOT_TOKEN}\n")
            f.write("REWIND_ADMIN_DOMAIN=app.localhost\n")
            f.write(f"ROVE_CLUSTER={c.cluster_id}\n")
            f.write(f"ROVE_GENESIS_NODES={genesis_nodes}\n")

        print(f"running: rewind-ops genesis --env {env_file}\n")
        r = subprocess.run([str(OPS), "genesis", "--env", env_file],
                           capture_output=True, text=True, timeout=180)
        print(r.stdout)
        if r.returncode != 0:
            print("STDERR:\n" + r.stderr)
            print(f"\nFAIL — genesis command exited {r.returncode}")
            c.dump_node_log(grep=["reconcile", "confchange", "learner", "promote",
                                  "attach", "reset", "admin", "error", "warn"])
            return 1

        ms = c._member_status("__admin__")
        ok = ms is not None and len(ms.get("voters", [])) == nodes
        print(f"\n__admin__ member-status: {ms}")
        if ok:
            print("\nPASS — `rewind-ops genesis` brought an empty cluster to a "
                  "3-voter, deploy-capable state. ⭐")
            return 0
        print("\nFAIL — __admin__ did not reach 3 voters")
        return 1


if __name__ == "__main__":
    sys.exit(main())
