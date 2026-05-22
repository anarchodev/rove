#!/usr/bin/env python3
"""Wide-fanout sharded-write throughput probe: 16 workers × 64 tenants.

Forked from `scripts/conn_actor_bench.py` to probe behavior past the
established 8-worker / 8-tenant sharded baseline (~158k req/s,
`project_kvexp_rebump_metrics`). Same workload shape — h2load against
write{i}.test `/?fn=handler` in parallel — but with workers_per_node=16
and TENANTS=64. The motivating question is whether throughput keeps
scaling past 8 tenants or whether the single shared raft-log fsync is
already the ceiling.

This is *not* an apples-to-apples comparison with the 158k baseline.
The cluster topology, worker count, and tenant fan-out are all
different. The 158000 number is printed for orientation only — there
is no exit-fail gate, this is an exploration probe, not a regression
test.
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402

import os

PUBLIC_SUFFIX = "rewindjsapp.localhost"
TENANTS = int(os.environ.get("TENANTS", "64"))
WORKERS = int(os.environ.get("WORKERS", "16"))
REQUESTS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
CLIENTS = int(sys.argv[2]) if len(sys.argv) > 2 else 10
STREAMS = int(sys.argv[3]) if len(sys.argv) > 3 else 10
BASELINE_REF_8W = 158000  # 8w/8t reference (informational only)


def rps(out: str) -> float:
    m = re.search(r"([\d.]+)\s+req/s", out)
    return float(m.group(1)) if m else 0.0


def status_counts(out: str) -> tuple[int, int, int, int]:
    # h2load prints: "status codes: N 2xx, N 3xx, N 4xx, N 5xx"
    m = re.search(r"status codes:\s*(\d+)\s*2xx,\s*(\d+)\s*3xx,"
                  r"\s*(\d+)\s*4xx,\s*(\d+)\s*5xx", out)
    if not m:
        return (0, 0, 0, 0)
    return (int(m.group(1)), int(m.group(2)),
            int(m.group(3)), int(m.group(4)))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="kv-shard-wide",
        http_base=8592,
        raft_base=40692,
        public_suffix=PUBLIC_SUFFIX,
        workers_per_node=WORKERS,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        # Default per-tenant request limiter is 100 burst / 50 rps refill —
        # any real bench saturates it instantly. Match the bash macrobenches
        # (kv_bench_cluster.sh etc.): set both to 1M to take it out of play.
        worker_extra_args=[
            "--rate-limit-request-capacity", "1000000",
            "--rate-limit-request-refill", "1000000",
        ],
    )
    with cluster as c:
        c.discover_leader()
        port = c.leader_port()
        url = f"https://127.0.0.1:{port}/?fn=handler"
        print(f"ok  leader node {c.leader_idx} :{port}  "
              f"({WORKERS} workers/node, {TENANTS} tenants; "
              f"n={REQUESTS} c={CLIENTS} m={STREAMS} per tenant)")

        # Warm write0 only (parity with conn_actor_bench). First-touch
        # cost across the remaining 63 tenants is small relative to
        # 20000-req runs.
        subprocess.run(
            ["h2load", "-n", "200", "-c", "4", "-m", "4",
             "--header=host: write0.test", url],
            capture_output=True, timeout=60,
        )

        procs = []
        t0 = time.monotonic()
        for i in range(TENANTS):
            procs.append(subprocess.Popen(
                ["h2load", "-n", str(REQUESTS), "-c", str(CLIENTS),
                 "-m", str(STREAMS), f"--header=host: write{i}.test", url],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            ))
        per = []
        s2 = s3 = s4 = s5 = 0
        for i, p in enumerate(procs):
            out, _ = p.communicate(timeout=600)
            r = rps(out)
            per.append(r)
            if r == 0.0:
                sys.exit(f"FAIL write{i}: no req/s parsed:\n{out[-800:]}")
            a, b, c, d = status_counts(out)
            s2 += a
            s3 += b
            s4 += c
            s5 += d
        wall = time.monotonic() - t0
        total_attempted = REQUESTS * TENANTS
        ok_rps = s2 / wall
        agg = total_attempted / wall

        print()
        for i, r in enumerate(per):
            print(f"  write{i:02d}.test: {r:10.0f} req/s")
        print()
        print(f"  {WORKERS}w / {TENANTS}t aggregate: {agg:10.0f} req/s "
              f"(wall={wall:.2f}s, total={total_attempted} reqs)")
        print(f"  status codes: {s2} 2xx, {s3} 3xx, {s4} 4xx, {s5} 5xx")
        print(f"  2xx-only rate: {ok_rps:10.0f} req/s "
              f"({100.0 * s2 / total_attempted:.1f}% success)")
        print(f"  reference (8w/8t sharded): ~{BASELINE_REF_8W} req/s")
        ratio = agg / BASELINE_REF_8W
        print(f"  ratio vs 8w/8t reference: {ratio:.2f}× (informational; "
              "different topology — not a regression gate)")
        print()
        print("kv-shard-wide probe done")
        return 0


if __name__ == "__main__":
    sys.exit(main())
