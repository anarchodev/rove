#!/usr/bin/env python3
"""Continuation-chain A/B workload for the internal-schedule path.

Kicks `CHAIN_COUNT` chains of depth `CHAIN_DEPTH` against the
`chainbench` tenant and measures wall time to drain them.

Instrument discipline: the measured window must not contend on the
tenant being measured. So the bench makes exactly ONE H2 request to
start all chains (`?fn=start`), then polls ONE aggregate counter
(`?fn=status`) on a slow interval — ~1 GET/s, vs the old ~N GETs/50ms
per-chain poll that swamped chainbench's per-tenant txn lock against
the internal-schedule writer and made the number meaningless.

Run the SAME script against the fusion build and a baseline build
(scripts/chain_fusion_ab.sh) and diff the `METRIC` lines.

Env: CHAIN_DEPTH (64), CHAIN_COUNT (24), CHAIN_TIMEOUT_S (300),
     CHAIN_POLL_S (1.0), CHAIN_TAG (label).
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

PUBLIC_SUFFIX = "rewindjsapp.localhost"
HOST = f"chainbench.{PUBLIC_SUFFIX}"

DEPTH = int(os.environ.get("CHAIN_DEPTH", "64"))
COUNT = int(os.environ.get("CHAIN_COUNT", "24"))
TIMEOUT_S = float(os.environ.get("CHAIN_TIMEOUT_S", "300"))
POLL_S = float(os.environ.get("CHAIN_POLL_S", "1.0"))
TAG = os.environ.get("CHAIN_TAG", "run")


def discover_leader(c: Cluster, *, timeout_s: float = 20.0) -> int:
    """Leader-only public surface (§6c): leader's handler returns 200
    JSON `{"count":N}`; followers have no public listener / 503."""
    cc = c.curl_ctx(HOST)
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        for i in range(3):
            port = c.addrs.http_port(i)
            try:
                r = curl(cc, f"https://{HOST}:{port}/?fn=status", timeout=2.0)
            except RuntimeError:
                continue
            if r.status == 200 and '"count"' in r.body:
                c.leader_idx = i
                return i
        time.sleep(0.2)
    raise RuntimeError(f"no leader status-200 within {timeout_s}s")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="chain-fusion-bench",
        http_base=8392,
        raft_base=40492,
        files_port=8394,
        log_port=8395,
        public_suffix=PUBLIC_SUFFIX,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "chain-bench-tenant.json",
        workers_per_node=1,
    )
    with cluster as c:
        discover_leader(c)
        cc = c.curl_ctx(HOST)
        port = c.leader_port()
        base = f"https://{HOST}:{port}"
        self_url = f"{base}/"
        print(f"ok  leader node {c.leader_idx} at :{port}; "
              f"depth={DEPTH} count={COUNT} tag={TAG}")

        def status_count() -> int:
            r = curl(cc, f"{base}/?fn=status", timeout=5.0)
            if r.status != 200:
                return -1
            try:
                return int(json.loads(r.body).get("count", -1))
            except Exception:
                return -1

        def start(n: int, depth: int) -> None:
            args = urllib.parse.quote(json.dumps([n, depth, self_url]))
            r = curl(cc, f"{base}/?fn=start&args={args}", timeout=10.0)
            if r.status != 200:
                sys.exit(f"FAIL start: {r.status} {r.body}")

        # Warmup (pays one-time module compile / arena warm). The
        # counter is cumulative, so snapshot it after warmup and
        # target baseline + COUNT for the measured run.
        start(4, 4)
        wdl = time.monotonic() + 30.0
        while time.monotonic() < wdl and status_count() < 4:
            time.sleep(0.25)
        base_count = status_count()
        if base_count < 4:
            print(f"FAIL warmup never drained (count={base_count})")
            return 1
        print(f"ok  warmup drained (counter baseline={base_count})")

        # Measured run.
        target = base_count + COUNT
        run_t0 = time.monotonic()
        start(COUNT, DEPTH)
        deadline = time.monotonic() + TIMEOUT_S
        done = base_count
        while done < target and time.monotonic() < deadline:
            time.sleep(POLL_S)
            done = status_count()
        run_wall = time.monotonic() - run_t0

        if done < target:
            print(f"FAIL  {target - done}/{COUNT} chains unfinished "
                  f"after {TIMEOUT_S}s (tag={TAG})")
            return 1

        # `METRIC` is the A/B contract — keep keys stable + greppable.
        print(f"METRIC tag={TAG} depth={DEPTH} count={COUNT} "
              f"wall_s={run_wall:.3f} "
              f"chains_per_s={COUNT / run_wall:.2f}")
        print("ok  all chains completed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
