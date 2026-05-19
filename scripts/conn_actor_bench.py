#!/usr/bin/env python3
"""Connection-actor in-situ throughput bench (Phase-4 freeze).

The smoke_lib port of the sharded-write h2load macrobench (the
`reference_bench_harness_direction` first port: spawns its own cluster
instead of punting "loop46 must already be running" like the bash
`kv_shard_bench.sh`). Workload = the established 8-worker sharded
write0..write7 `/?fn=handler` (apples-to-apples with the ~158k 8w
sharded baseline in `project_kvexp_rebump_metrics`).

Scope, stated honestly: the DECISIVE regression verdict for the
connection-actor work is the controlled in-process microbench A/B
(ROVE_BENCH in src/js/bindings/continuation.zig: tryExtract = 61
ns/op, ~4% of the JSON.stringify every object-returning handler
already pays, <1% of a real request) plus a zero-new-concurrency/
allocation review of the terminal hot path (a switch + null-checks +
one count()-gated usize compare). This bench is the in-situ SANITY
confirmation that nothing pathological emerges under real
concurrency+raft+h2, and the durable forward regression tool.
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402

PUBLIC_SUFFIX = "rewindjsapp.localhost"
TENANTS = 8
REQUESTS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
CLIENTS = int(sys.argv[2]) if len(sys.argv) > 2 else 10
STREAMS = int(sys.argv[3]) if len(sys.argv) > 3 else 10
BASELINE_8W = 158000  # project_kvexp_rebump_metrics, 8w sharded


def rps(out: str) -> float:
    m = re.search(r"([\d.]+)\s+req/s", out)
    return float(m.group(1)) if m else 0.0


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="conn-actor-bench",
        http_base=8492,
        raft_base=40592,
        public_suffix=PUBLIC_SUFFIX,
        workers_per_node=8,  # the baseline-comparable, regression-sensitive config
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        port = c.leader_port()
        url = f"https://127.0.0.1:{port}/?fn=handler"
        print(f"ok  leader node {c.leader_idx} :{port}  "
              f"(8 workers/node; n={REQUESTS} c={CLIENTS} m={STREAMS} per tenant)")

        # Warm one tenant (pays module compile / arena warm) so the
        # measured run isn't skewed by first-touch.
        subprocess.run(
            ["h2load", "-n", "200", "-c", "4", "-m", "4",
             "--header=host: write0.test", url],
            capture_output=True, timeout=60,
        )

        # Sharded: 8 tenants in parallel — the per-tenant lock / shared
        # raft-log shape the ~158k baseline measured.
        procs = []
        t0 = time.monotonic()
        for i in range(TENANTS):
            procs.append(subprocess.Popen(
                ["h2load", "-n", str(REQUESTS), "-c", str(CLIENTS),
                 "-m", str(STREAMS), f"--header=host: write{i}.test", url],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            ))
        per = []
        for i, p in enumerate(procs):
            out, _ = p.communicate(timeout=300)
            r = rps(out)
            per.append(r)
            if r == 0.0:
                sys.exit(f"FAIL write{i}: no req/s parsed:\n{out[-800:]}")
        wall = time.monotonic() - t0
        agg = (REQUESTS * TENANTS) / wall

        print()
        for i, r in enumerate(per):
            print(f"  write{i}.test: {r:10.0f} req/s")
        print()
        print(f"  8w sharded aggregate: {agg:10.0f} req/s "
              f"(wall={wall:.2f}s, total={REQUESTS*TENANTS} reqs)")
        print(f"  baseline (pre-connection-actor, 8w sharded): ~{BASELINE_8W} req/s")
        ratio = agg / BASELINE_8W
        print(f"  ratio vs baseline: {ratio:.2f}×")
        print()
        # Sanity gate: a real regression from the connection-actor
        # work would show as a materially lower aggregate. The
        # microbench bounds the per-request tax at ~61 ns, so anything
        # within noise of the baseline confirms in-situ. Generous
        # lower bound (env/load variance across a marathon test box is
        # wide); the point is "no pathology", not a tight SLA.
        if ratio < 0.80:
            sys.exit(
                f"FAIL 8w sharded {agg:.0f} req/s is {ratio:.2f}× the "
                f"~{BASELINE_8W} baseline — investigate (microbench said "
                "the per-request tax is ~61 ns; a >20% in-situ drop is "
                "not explained by that and warrants a stash-vs-pop A/B)"
            )
        print(f"ok  in-situ: 8w sharded within {ratio:.2f}× of baseline — "
              "no concurrency/raft-path regression (consistent with the "
              "61 ns microbench verdict)")
        print()
        print("connection-actor in-situ bench passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
