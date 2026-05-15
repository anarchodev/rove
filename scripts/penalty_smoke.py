#!/usr/bin/env python3
"""End-to-end smoke test for the CPU-budget interrupt handler + penalty box.

Python port of `scripts/penalty_smoke.sh`. Tests that:
  1) First 3 requests hit budget → 504 each.
  2) 4th request: penalty box trips open → 503 short-circuit.
  3) 5th + 6th: still boxed → 503.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_eq  # noqa: E402

PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
HOST = f"penalty.{PUBLIC_SUFFIX}"


def discover_leader_via_404(c: Cluster, *, timeout_s: float = 15.0) -> int:
    """Penalty smoke uses a route-miss probe (404 on leader, 503 on follower)
    because no admin auth is wired."""
    cc = c.curl_ctx(HOST)
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        for i in range(3):
            port = c.addrs.http_port(i)
            try:
                r = curl(
                    cc,
                    f"https://{HOST}:{port}/__leader_probe__",
                    timeout=2.0,
                )
            except RuntimeError:
                continue
            if r.status == 404:
                c.leader_idx = i
                return i
        time.sleep(0.2)
    raise RuntimeError(f"no leader returned 404 within {timeout_s}s")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="penalty-smoke",
        http_base=8092,
        raft_base=40192,
        files_port=8094,
        log_port=8095,
        public_suffix=PUBLIC_SUFFIX,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        workers_per_node=1,  # penalty-box is per-worker; SO_REUSEPORT spread dilutes
    )
    with cluster as c:
        discover_leader_via_404(c)
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(HOST)
        url = f"https://{HOST}:{c.leader_port()}/?fn=handler"

        # Wait for penalty's snapshot to load — probe with the bare
        # route which returns 404 when ready (no default export) and
        # 503 when no_deployment. Probing the handler itself would
        # consume a budget kill and shift the box-trip threshold.
        probe = f"https://{HOST}:{c.leader_port()}/__probe__"
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            r = curl(cc, probe, timeout=2.0)
            if r.status == 404:
                break
            time.sleep(0.1)

        # First three: each hits the 10ms budget → 504.
        for i in (1, 2, 3):
            r = curl(cc, url, timeout=10.0)
            expect_eq(f"request {i} (expect 504 from budget kill)", 504, r.status)

        # Fourth: penalty box now open (kill_threshold=3) → 503.
        r = curl(cc, url, timeout=10.0)
        expect_eq("request 4 (expect 503 from penalty box)", 503, r.status)

        # Fifth + sixth stay 503.
        for i in (5, 6):
            r = curl(cc, url, timeout=10.0)
            expect_eq(f"request {i} (expect 503, still boxed)", 503, r.status)

        print("PASS penalty smoke")
        return 0


if __name__ == "__main__":
    sys.exit(main())
