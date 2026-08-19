#!/usr/bin/env python3
"""Sharded write throughput: N tenants driven in parallel against a V2 cluster.

The V2 successor to `scripts/bench/kv_bench_cluster.sh`'s third leg (and the
deleted `kv_shard_wide_bench.py`), both of which spawn the retired `loop46`
binary and have had no runnable replacement since the cutover.

**The V1 "8 workers" number does not port.** V1 ran N worker THREADS in one
process and scaled by raising N; `rewind-worker` runs exactly one worker
thread per process (`src/rewind/main.zig` — one `Thread.spawn`, an event-loop
node), and V2 scales horizontally by adding nodes. So the ~158k req/s 8w/8t
V1 baseline has no apples-to-apples V2 counterpart, and this script does not
pretend otherwise: it prints no ratio against it. What it establishes is a
V2 baseline of its own, on the production 3-node shape.

What it measures, and why the second number matters as much as the first:

  * aggregate req/s across `TENANTS` parallel h2load runs, 2xx-gated — a
    req/s figure that does not check status codes will happily report a
    fast 429 storm;
  * `dispatch_writeset_size_requests` — how many customer requests actually
    ride one raft entry. This is the batching the dispatch walk performs,
    and until the admission-reserve fix it was pinned at 1 for every batch
    (the reserve exceeded a whole entry, so the walk never admitted a
    second request). There has never been a production number for it.

Read the two together. If throughput is flat while mean batch occupancy
climbs, dispatch batching is not the binding layer and a bigger raft entry
would buy nothing — see `docs/decisions.md` §2.5a.1 for the partition the
occupancy is bounded by.

Run:
    zig build -Doptimize=ReleaseFast rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/smoke/bench/kv_shard_bench_v2.py [requests] [clients] [streams]

Env:
    TENANTS=8     parallel tenants (each its own raft group)
    NODES=3       cluster size; 3 is the production shape
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from smoke_lib_v2 import V2Cluster, metric_counter  # noqa: E402

TENANTS = int(os.environ.get("TENANTS", "8"))
NODES = int(os.environ.get("NODES", "3"))
REQUESTS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
CLIENTS = int(sys.argv[2]) if len(sys.argv) > 2 else 10
STREAMS = int(sys.argv[3]) if len(sys.argv) > 3 else 10

# One kv.set per request against a fixed key — the same shape the V1 sharded
# leg used, so the workload is a write path and not a router benchmark.
SRC = """
export default function () {
  kv.set("k", "v".repeat(32));
  return "w";
}
"""

# The default tier is 1000 burst / 500 rps; any real bench saturates it in the
# first second and then measures the limiter. Take it out of play rather than
# silently benchmark a 429 path.
UNCAPPED = json.dumps({"overrides": {
    "request_capacity": 1_000_000,
    "request_refill_per_sec": 1_000_000,
}})


def rps(out: str) -> float:
    m = re.search(r"([\d.]+)\s+req/s", out)
    return float(m.group(1)) if m else 0.0


def status_counts(out: str) -> tuple[int, int, int, int]:
    m = re.search(r"status codes:\s*(\d+)\s*2xx,\s*(\d+)\s*3xx,"
                  r"\s*(\d+)\s*4xx,\s*(\d+)\s*5xx", out)
    if not m:
        return (0, 0, 0, 0)
    return tuple(int(m.group(i)) for i in range(1, 5))  # type: ignore[return-value]


def batch_occupancy(c: V2Cluster) -> tuple[float, float]:
    """(observed batches, mean requests per batch) summed across nodes."""
    total_sum = total_count = 0.0
    for i in range(NODES):
        text = c.metrics(i)
        if not text:
            continue
        s = metric_counter(text, "dispatch_writeset_size_requests_sum")
        n = metric_counter(text, "dispatch_writeset_size_requests_count")
        if s is not None and n is not None:
            total_sum += s
            total_count += n
    return total_count, (total_sum / total_count if total_count else 0.0)


def main() -> int:
    print(f"=== sharded write throughput: {TENANTS} tenants × {NODES} nodes ===")
    print(f"    n={REQUESTS} c={CLIENTS} m={STREAMS} per tenant, through the front door")
    tenants = [f"write{i}" for i in range(TENANTS)]

    with V2Cluster.spawn("kvshard", nodes=NODES) as c:
        for t in tenants:
            c.provision(t)
            if NODES > 1:
                c.wait_for_membership(t, voters=NODES)
            c._cp_post("/_control/plan", {"tenant": t, "plan": UNCAPPED})
            c.deploy_handlers(t, {"index.mjs": SRC})
            c.wait_for_handler(t, "/", want_body="w", timeout_s=60.0)
        print(f"ok  {TENANTS} tenants provisioned, deployed and warm")

        url = f"{c.front_url()}/"
        before_n, _ = batch_occupancy(c)

        procs = []
        t0 = time.monotonic()
        for t in tenants:
            procs.append(subprocess.Popen(
                ["h2load", "-n", str(REQUESTS), "-c", str(CLIENTS),
                 "-m", str(STREAMS), f"--header=host: {c.host_for(t)}", url],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            ))
        per, s2, s3, s4, s5 = [], 0, 0, 0, 0
        for t, p in zip(tenants, procs):
            out, _ = p.communicate(timeout=900)
            r = rps(out)
            if r == 0.0:
                print(f"FAIL {t}: no req/s parsed:\n{out[-800:]}")
                return 1
            per.append((t, r))
            a, b, cc, d = status_counts(out)
            s2, s3, s4, s5 = s2 + a, s3 + b, s4 + cc, s5 + d
        wall = time.monotonic() - t0
        after_n, mean_occ = batch_occupancy(c)

        attempted = REQUESTS * TENANTS
        print()
        for t, r in per:
            print(f"  {t:>8}: {r:10.0f} req/s")
        print()
        print(f"  aggregate:        {attempted / wall:10.0f} req/s "
              f"(wall={wall:.2f}s, {attempted} reqs)")
        print(f"  2xx-only:         {s2 / wall:10.0f} req/s "
              f"({100.0 * s2 / attempted:.1f}% of attempted)")
        print(f"  status codes:     {s2} 2xx, {s3} 3xx, {s4} 4xx, {s5} 5xx")
        print()
        print(f"  raft batches observed:      {after_n - before_n:.0f}")
        print(f"  mean requests per batch:    {mean_occ:.2f}")
        print("  (1.00 means the dispatch walk never coalesced — the state "
              "before the admission-reserve fix)")

        # A req/s number with a wall of non-2xx behind it is worse than no
        # number: it reads as throughput and measures a refusal path.
        if s2 != attempted:
            print(f"\nFAIL — {attempted - s2} non-2xx responses; the number above "
                  "is not a throughput measurement")
            return 1
        print("\nPASS — all responses 2xx")
        return 0


if __name__ == "__main__":
    sys.exit(main())
