#!/usr/bin/env python3
"""Sharded write throughput: N tenants driven in parallel against a V2 cluster.

The V2 successor to `scripts/bench/kv_bench_cluster.sh`'s third leg (and the
deleted `kv_shard_wide_bench.py`), both of which spawn the retired `loop46`
binary and have had no runnable replacement since the cutover.

`REWIND_WORKERS` sets the worker-thread count and is echoed in the header,
because a throughput number that does not say how many threads produced it
is not comparable to anything.

**Two drive modes, and the difference is not cosmetic.** By default the load
goes through the FRONT door, which is the production path — and the front
pools at most `proxy.MAX_LEGS` (4) upstream connections per node. Those
connections are what `SO_REUSEPORT` hashes across workers, so a front-driven
run can never occupy more than 4 workers per node no matter how high
`REWIND_WORKERS` goes. `DIRECT=1` points h2load at the node ports instead —
each tenant at the node leading its group — one connection per client, which
is what isolates the worker-count variable and keeps a multi-node run from
measuring the forwarding path.
Read a front-mode number as "what the current edge delivers" and a direct
number as "what the node can do".

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
    REWIND_SMOKE_NO_BUILD=1 python3 scripts/smoke/bench/kv_shard_bench_v2.py [requests] [clients] [streams]

`REWIND_SMOKE_NO_BUILD=1` is load-bearing: without it the harness's
freshness pass rebuilds `smoke-bins` DEBUG over the ReleaseFast install,
and the run silently reads ~10x low (the Debug tell: ~110 MB worker
binary vs ~33 MB).

Env:
    TENANTS=8         parallel tenants (each its own raft group)
    NODES=3           cluster size; 3 is the production shape
    REWIND_WORKERS=1  worker threads per node (read by the worker itself)
    DIRECT=0          1 = drive the node ports directly (each tenant at its
                      group's leader), bypassing the front's 4-leg upstream
                      pool (see above)
    BALANCE=0         1 = rebalance group leadership across nodes before the
                      load starts (DIRECT multi-node only) — provisioning
                      births every group on one node, and an unbalanced run
                      is that node's number wearing a cluster topology
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

from smoke_lib_v2 import V2Cluster, metric_counter, _curl, MOVE_SECRET  # noqa: E402

TENANTS = int(os.environ.get("TENANTS", "8"))
NODES = int(os.environ.get("NODES", "3"))
WORKERS = int(os.environ.get("REWIND_WORKERS", "1"))
DIRECT = os.environ.get("DIRECT", "0") not in ("", "0")
# Multi-node direct only: rebalance group leadership before the load starts.
# Provisioning births every group on the same node, so an untouched cluster
# leads almost everything there and the "cluster" number is one node's. A
# transfer hands off to the most caught-up follower (not a chosen node), so
# balance is reached by repeatedly shedding one group from the most-loaded
# node until no node leads more than ceil(TENANTS/NODES).
BALANCE = os.environ.get("BALANCE", "0") not in ("", "0")
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
    print(f"=== sharded write throughput: {TENANTS} tenants × {NODES} nodes "
          f"× {WORKERS} worker(s) ===")
    print(f"    n={REQUESTS} c={CLIENTS} m={STREAMS} per tenant, "
          + ("DIRECT to the node port (front's 4-leg pool bypassed)"
             if DIRECT else "through the front door (≤4 upstream legs per node)"))
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

        # Direct mode aims each tenant at the node LEADING its raft group —
        # aiming everything at node 0 would measure serve-or-forward (fast
        # 421s for tenants led elsewhere) as much as it measures workers.
        # Resolved before the clock starts; a leader that moves mid-run
        # surfaces as non-2xx and fails the gate below. The mapping is
        # printed because the aggregate is only a cluster number when the
        # groups actually spread — 8 leaders on one node is a one-node run
        # wearing a cluster topology.
        if DIRECT:
            def resolve() -> dict | None:
                m = {}
                for t in tenants:
                    n = c.leader_node(t)
                    if n is None:
                        print(f"FAIL {t}: no node answers as leader")
                        return None
                    m[t] = n
                return m

            target = resolve()
            if target is None:
                return 1
            if BALANCE and NODES > 1:
                cap = -(-TENANTS // NODES)  # ceil
                for rnd in range(4 * TENANTS):
                    loads = {n: sum(1 for v in target.values() if v == n)
                             for n in range(NODES)}
                    heavy = max(loads, key=lambda n: loads[n])
                    if loads[heavy] <= cap:
                        break
                    # Rotate the shed pick across rounds: the handoff target
                    # is raft's choice (most caught-up follower), so shedding
                    # the same group every round can ping-pong between two
                    # loaded nodes and never touch the light one. A different
                    # group re-rolls that choice.
                    on_heavy = [t for t in tenants if target[t] == heavy]
                    shed = on_heavy[rnd % len(on_heavy)]
                    print(f"    balance round {rnd}: loads="
                          f"{[loads[n] for n in range(NODES)]} "
                          f"shed {shed} off n{heavy}")
                    _curl(f"{c.node_url(heavy)}/_system/v2-transfer-leadership"
                          f"?tenant={shed}", method="POST",
                          headers={"X-Rewind-Move-Secret": MOVE_SECRET})
                    deadline = time.monotonic() + 10.0
                    while time.monotonic() < deadline:
                        n = c.leader_node(shed)
                        if n is not None and n != heavy:
                            break
                        time.sleep(0.2)
                    target = resolve()
                    if target is None:
                        return 1
                else:
                    print("FAIL leader balancing did not converge")
                    return 1
            spread = ", ".join(f"n{n}:{sum(1 for v in target.values() if v == n)}"
                               for n in sorted(set(target.values())))
            print(f"ok  leader spread: {spread}")

        def url_for(t: str) -> str:
            return f"{c.node_url(target[t])}/" if DIRECT else f"{c.front_url()}/"

        before_n, _ = batch_occupancy(c)

        procs = []
        t0 = time.monotonic()
        for t in tenants:
            procs.append(subprocess.Popen(
                ["h2load", "-n", str(REQUESTS), "-c", str(CLIENTS),
                 "-m", str(STREAMS), f"--header=host: {c.host_for(t)}", url_for(t)],
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
        # Occupancy is the number to read against the worker count. The
        # dispatch walk coalesces the requests ONE worker sees in one tick
        # into one raft entry, so splitting a fixed arrival rate across N
        # workers divides occupancy by roughly N and multiplies the entry
        # count by roughly N. If throughput is flat while occupancy falls
        # like 1/N, the binding layer is the entry pipeline, not worker CPU,
        # and adding workers is moving the same work into more, smaller
        # entries.
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
