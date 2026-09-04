#!/usr/bin/env python3
"""Handler-path throughput where the JS allocator is the variable.

Two read-only handlers on ONE tenant, driven at the node port (`DIRECT`
semantics of `kv_shard_bench_v2.py` — the front's 4-leg pool is not what is
being measured), 2xx-gated:

  * `/alloc` — builds and stringifies a modest object graph: many small
    short-lived allocations, the shape where a bump cursor and a malloc
    differ most;
  * `/read` — one `kv.get` + a small response: the common "hello, kv" request,
    where dispatch overhead dominates and the allocator should barely show.

No writes, so raft is off the path and the number is the worker's JS
dispatch rate. Compare runs only against each other on the same box,
ReleaseFast, nothing else running.

Run:
    zig build -Doptimize=ReleaseFast rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    REWIND_SMOKE_NO_BUILD=1 python3 scripts/smoke/bench/arena_alloc_bench.py [requests] [clients] [streams]

Env:
    REWIND_WORKERS=1  worker threads (echoed; a number without it is not comparable)
    ROUNDS=3          repetitions per leg — one trial is not a rate
"""
from __future__ import annotations

import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from smoke_lib_v2 import V2Cluster  # noqa: E402

WORKERS = int(os.environ.get("REWIND_WORKERS", "1"))
ROUNDS = int(os.environ.get("ROUNDS", "3"))
REQUESTS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
CLIENTS = int(sys.argv[2]) if len(sys.argv) > 2 else 10
STREAMS = int(sys.argv[3]) if len(sys.argv) > 3 else 10

SRC = """
export default function () {
  if (request.path === "/read") {
    const v = kv.get("greeting");   // a miss is fine: the read path is what runs
    return { greeting: v ?? null, n: 1 };
  }
  // /alloc: ~2k small objects + strings per request, all garbage by return.
  const rows = [];
  for (let i = 0; i < 500; i++) {
    rows.push({ id: i, name: "row-" + i, tags: ["a" + i, "b" + i], nested: { x: i * 2, y: String(i) } });
  }
  const s = JSON.stringify(rows);
  const back = JSON.parse(s);
  return { len: s.length, count: back.length };
}
"""

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


def main() -> int:
    print(f"=== arena alloc bench: 1 tenant × 1 node × {WORKERS} worker(s), "
          f"n={REQUESTS} c={CLIENTS} m={STREAMS}, {ROUNDS} rounds/leg, node port direct ===")
    ok = True
    with V2Cluster.spawn("arenaalloc", nodes=1) as c:
        t = "alloc"
        c.provision(t)
        c._cp_post("/_control/plan", {"tenant": t, "plan": UNCAPPED})
        c.deploy_handlers(t, {"index.mjs": SRC})
        c.wait_for_handler(t, "/alloc", want_body='"count":500', timeout_s=60.0)
        host = c.host_for(t)
        for leg in ("/alloc", "/read"):
            url = f"{c.node_url(0)}{leg}"
            # warm
            subprocess.run(["h2load", "-n", "2000", "-c", "4", "-m", "4",
                            f"--header=host: {host}", url],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            rates = []
            for r in range(ROUNDS):
                out = subprocess.run(
                    ["h2load", "-n", str(REQUESTS), "-c", str(CLIENTS),
                     "-m", str(STREAMS), f"--header=host: {host}", url],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                    timeout=900).stdout
                rate = rps(out)
                s2, s3, s4, s5 = status_counts(out)
                if rate == 0.0 or s2 != REQUESTS:
                    print(f"FAIL {leg} round {r}: rps={rate} status={s2}/{s3}/{s4}/{s5}\n{out[-600:]}")
                    ok = False
                    break
                rates.append(rate)
                print(f"  {leg:7} round {r}: {rate:10.0f} req/s  (2xx={s2})")
            if rates:
                print(f"  {leg:7} median {statistics.median(rates):10.0f} req/s  "
                      f"min {min(rates):.0f}  max {max(rates):.0f}")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
