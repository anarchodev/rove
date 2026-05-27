#!/usr/bin/env python3
"""Body-throughput probe: drive POST <body> across N tenants and measure
aggregate request rate + total body bytes/sec landing in S3.

Designed to validate the body-flush fan-out + size-bump change. Unlike
`body_gate_bench.py` (which has pre-existing sharded + park-path issues
that we haven't fixed), this script:

1. Spawns the standard demo cluster.
2. Probes ONE POST to ONE tenant via curl --resolve to confirm the
   park-path responds at all.
3. Launches K concurrent worker threads, each in a tight loop POSTing
   `body_kb` KB to a tenant (round-robin across `tenants` tenants).
4. Reports aggregate req/s and MB/s of body bytes landed.

Defaults are intentionally modest; bump from the CLI:
  body_throughput_probe.py [tenants=8] [workers=32] [duration_s=20] [body_kb=20]

Use BLOB_BACKEND=s3 + S3_* env to run against OVH; default fs backend
isolates the per-process measurement from the network.
"""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib import Cluster  # noqa: E402

PUBLIC_SUFFIX = "rewindjsapp.localhost"
TENANTS = int(sys.argv[1]) if len(sys.argv) > 1 else 8
WORKERS = int(sys.argv[2]) if len(sys.argv) > 2 else 32
DURATION_S = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0
BODY_KB = int(sys.argv[4]) if len(sys.argv) > 4 else 20

BODY = os.urandom(BODY_KB * 1024)


def post_once(port: int, tenant: int, timeout: float = 30.0) -> tuple[int, float]:
    """Single POST via curl --resolve. Returns (status, elapsed_s)."""
    host = f"write{tenant}.{PUBLIC_SUFFIX}"
    t0 = time.monotonic()
    r = subprocess.run(
        ["curl", "-k", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "--resolve", f"{host}:{port}:127.0.0.1",
         "-X", "POST", "--data-binary", "@-",
         f"https://{host}:{port}/?fn=handler"],
        input=BODY, capture_output=True, timeout=timeout,
    )
    elapsed = time.monotonic() - t0
    code = int(r.stdout.decode("utf-8", errors="replace").strip() or "0")
    return code, elapsed


def main() -> int:
    cluster = Cluster.spawn(
        tag="body-throughput-probe",
        http_base=8285,
        raft_base=40395,
        public_suffix=PUBLIC_SUFFIX,
        workers_per_node=4,
        with_log_files_bases=False,
        seed_manifest=Path(__file__).resolve().parent.parent / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=[
            "--rate-limit-request-capacity", "1000000",
            "--rate-limit-request-refill", "1000000",
        ],
    )
    with cluster as c:
        c.discover_leader()
        port = c.leader_port()

        # Wait every bench tenant up to 200 on a GET (same readiness
        # check body_gate_bench uses).
        deadline = time.monotonic() + 30.0
        for i in range(TENANTS):
            host = f"write{i}.{PUBLIC_SUFFIX}"
            while time.monotonic() < deadline:
                r = subprocess.run(
                    ["curl", "-k", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                     "--resolve", f"{host}:{port}:127.0.0.1",
                     f"https://{host}:{port}/?fn=handler"],
                    capture_output=True, text=True, timeout=5.0,
                )
                if r.stdout.strip() == "200":
                    break
                time.sleep(0.2)
            else:
                sys.exit(f"FAIL: write{i} never returned 200")
        print(f"ok  {TENANTS} bench tenants returning 200")

        # Single-shot probe: does POST 20KB park-path work at all?
        code, elapsed = post_once(port, 0)
        if code != 200:
            sys.exit(f"FAIL: probe POST write0 returned {code} ({elapsed*1000:.0f}ms)")
        print(f"ok  probe POST {BODY_KB}KB → {code} in {elapsed*1000:.0f}ms")
        if BODY_KB <= 16:
            print(f"note: BODY_KB={BODY_KB} ≤ 16 — inline path, NOT park")

        # Steady-state probe: K workers each loop POSTs round-robin
        # across TENANTS tenants for DURATION_S seconds.
        stop_at = time.monotonic() + DURATION_S
        total_ok = [0] * WORKERS
        total_fail = [0] * WORKERS
        lats: list[list[float]] = [[] for _ in range(WORKERS)]

        def worker(idx: int) -> None:
            t = idx % TENANTS
            ok = 0
            fail = 0
            ll = lats[idx]
            while time.monotonic() < stop_at:
                code, elapsed = post_once(port, t, timeout=60.0)
                if code == 200:
                    ok += 1
                    ll.append(elapsed)
                else:
                    fail += 1
                t = (t + 1) % TENANTS
            total_ok[idx] = ok
            total_fail[idx] = fail

        print(f"running {WORKERS} workers × {TENANTS} tenants for {DURATION_S:.0f}s, "
              f"body={BODY_KB}KB ({'park-path' if BODY_KB > 16 else 'inline'})…")
        t_start = time.monotonic()
        threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(WORKERS)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        wall = time.monotonic() - t_start

        ok = sum(total_ok)
        fail = sum(total_fail)
        flat_lats = sorted(x for sub in lats for x in sub)
        bytes_total = ok * BODY_KB * 1024
        rps = ok / wall
        mbs = bytes_total / wall / 1e6

        def pct(p: float) -> float:
            if not flat_lats:
                return 0
            return flat_lats[min(len(flat_lats) - 1, int(len(flat_lats) * p))] * 1000

        print()
        print("═" * 63)
        print(f" body-throughput-probe — body={BODY_KB}KB workers={WORKERS} tenants={TENANTS}")
        print(f"   backend={os.environ.get('BLOB_BACKEND', 'fs')}  duration={wall:.2f}s")
        print("─" * 63)
        print(f"   ok={ok}  fail={fail}  rps={rps:,.1f}  MB/s={mbs:,.2f}")
        print(f"   per-POST latency  p50={pct(0.5):.0f}ms  p90={pct(0.9):.0f}ms  "
              f"p99={pct(0.99):.0f}ms  max={pct(1.0):.0f}ms")
        print("═" * 63)
        return 0 if fail == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
