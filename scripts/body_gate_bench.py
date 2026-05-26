#!/usr/bin/env python3
"""Body-gate bench: RPS impact of the Phase 4 body durability gate
(`docs/readset-replication-plan.md` §5) across three body sizes.

Runs against the standard demo tenants (`examples/loop46-demo-tenants.json`):
  hot.rewindjsapp.localhost      — 1 tenant, single 'k' key (max contention)
  write0..write7.rewindjsapp.localhost — 8 tenants in parallel

For each, three h2load passes:
  (a) 0 B (GET)         — baseline, no gate
  (b) 100 B (POST)      — inline path (< 16 KB threshold), no S3
  (c) 20 KB (POST)      — park path, per-body S3 PUT

Comparing (a)/(b) tells us whether the inline path is ~free as
intended. Comparing (b)/(c) shows the park-on-durability cost.

Python (not bash) so cluster teardown rides on `smoke_lib`'s atexit
+ signal handlers instead of fragile shell traps.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402

PUBLIC_SUFFIX = "rewindjsapp.localhost"
TENANTS = 8
WORKERS = int(os.environ.get("WORKERS", "4"))
REQUESTS = int(sys.argv[1]) if len(sys.argv) > 1 else 30000
CLIENTS = int(sys.argv[2]) if len(sys.argv) > 2 else 10
STREAMS = int(sys.argv[3]) if len(sys.argv) > 3 else 10


def extract_rps(out: str) -> float:
    m = re.search(r"finished in.*?,\s*([\d.]+)\s*req/s", out)
    return float(m.group(1)) if m else 0.0


def extract_status_counts(out: str) -> tuple[int, int, int, int]:
    """h2load prints: 'status codes: N 2xx, N 3xx, N 4xx, N 5xx'."""
    m = re.search(
        r"status codes:\s*(\d+)\s*2xx,\s*(\d+)\s*3xx,\s*(\d+)\s*4xx,\s*(\d+)\s*5xx",
        out,
    )
    if not m:
        return (0, 0, 0, 0)
    return tuple(int(m.group(i)) for i in (1, 2, 3, 4))  # type: ignore[return-value]


def fmt_status(counts: tuple[int, int, int, int]) -> str:
    s2, s3, s4, s5 = counts
    total = s2 + s3 + s4 + s5
    if total == 0:
        return "no-status"
    if s4 == 0 and s5 == 0:
        return f"2xx={s2}"
    return f"2xx={s2} 4xx={s4} 5xx={s5}"


# Same shape as kv_shard_wide_bench.py: h2load connects to 127.0.0.1
# (no cert verification), sends `host:` header for tenant routing.
def h2load_run(
    *, port: int, host_header: str, body_path: Path | None,
    requests: int, clients: int, streams: int,
    timeout: float = 600.0,
) -> tuple[float, str]:
    cmd = [
        "h2load",
        "-n", str(requests),
        "-c", str(clients),
        "-m", str(streams),
        f"--header=host: {host_header}",
    ]
    if body_path is not None:
        cmd += ["-d", str(body_path)]
    cmd.append(f"https://127.0.0.1:{port}/?fn=handler")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return extract_rps(r.stdout), r.stdout


def run_hot(*, label: str, port: int, body_path: Path | None) -> float:
    rps, out = h2load_run(
        port=port,
        host_header=f"hot.{PUBLIC_SUFFIX}",
        body_path=body_path,
        requests=REQUESTS,
        clients=CLIENTS,
        streams=STREAMS,
    )
    status = fmt_status(extract_status_counts(out))
    print(f"  {label:<30s} {rps:>12,.0f} req/s   [{status}]")
    return rps


def run_sharded(*, label: str, port: int, body_path: Path | None) -> int:
    procs = []
    for i in range(TENANTS):
        cmd = [
            "h2load",
            "-n", str(REQUESTS),
            "-c", str(CLIENTS),
            "-m", str(STREAMS),
            f"--header=host: write{i}.{PUBLIC_SUFFIX}",
        ]
        if body_path is not None:
            cmd += ["-d", str(body_path)]
        cmd.append(f"https://127.0.0.1:{port}/?fn=handler")
        procs.append(subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    total_rps = 0
    s2 = s4 = s5 = 0
    for p in procs:
        out, _ = p.communicate(timeout=600)
        total_rps += int(extract_rps(out))
        sc = extract_status_counts(out)
        s2 += sc[0]
        s4 += sc[2]
        s5 += sc[3]
    status = f"2xx={s2}" if s4 == 0 and s5 == 0 else f"2xx={s2} 4xx={s4} 5xx={s5}"
    print(f"  {label:<30s} {total_rps:>12,d} req/s   [{status}]")
    return total_rps


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="body-gate-bench",
        http_base=8275,
        raft_base=40375,
        public_suffix=PUBLIC_SUFFIX,
        workers_per_node=WORKERS,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=[
            "--rate-limit-request-capacity", "1000000",
            "--rate-limit-request-refill", "1000000",
        ],
    )
    with cluster as c:
        c.discover_leader()
        port = c.leader_port()

        body_dir = Path(tempfile.mkdtemp(prefix="rove-body-bench-"))
        small = body_dir / "small.bin"
        small.write_bytes(b'{"k":"' + b"x" * 91 + b'"}')  # ~100 B
        large = body_dir / "large.bin"
        large.write_bytes(os.urandom(20 * 1024))  # 20 KB

        # Wait for the deployment loader to bring every bench tenant
        # up to 200. Without this the timed runs land while
        # `hot`/`write*` are still loading and report 503
        # "no deployment for this tenant" — h2load counts the 5xx as
        # completed requests at full link speed, inflating the RPS
        # number to a meaningless ~300k. (Found by extending the
        # bench to report status-code distribution: hot was 100% 5xx
        # while write0..7 were 100% 2xx, because write*'s start
        # window happened to overlap the load completion and hot's
        # didn't.)
        bench_hosts = [f"hot.{PUBLIC_SUFFIX}"] + [
            f"write{i}.{PUBLIC_SUFFIX}" for i in range(TENANTS)
        ]
        wait_deadline = time.monotonic() + 15.0
        for host in bench_hosts:
            while time.monotonic() < wait_deadline:
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
                sys.exit(f"FAIL: {host} never returned 200")
        print(f"ok  every bench tenant returning 200")

        # Warm the hot tenant connection pool so the timed run
        # doesn't include first-touch cost.
        h2load_run(
            port=port, host_header=f"hot.{PUBLIC_SUFFIX}",
            body_path=None, requests=5000, clients=20, streams=10,
            timeout=120.0,
        )

        print()
        print("═" * 63)
        print(" body-gate benchmark (readset-replication Phase 4)")
        print(f" requests={REQUESTS}  clients={CLIENTS}  streams={STREAMS}")
        print(f" workers/node={WORKERS}  body sizes: 0 B / 100 B / 20 KB")
        print("═" * 63)

        print()
        print("── hot tenant (single 'k' key) ──")
        hot_get = run_hot(label="GET (no body, baseline)", port=port, body_path=None)
        hot_inline = run_hot(label="POST 100 B (inline path)", port=port, body_path=small)
        hot_park = run_hot(label="POST 20 KB (park path)", port=port, body_path=large)

        print()
        print(f"── sharded ({TENANTS} tenants in parallel) ──")
        sh_get = run_sharded(label="GET (no body, baseline)", port=port, body_path=None)
        sh_inline = run_sharded(label="POST 100 B (inline path)", port=port, body_path=small)
        sh_park = run_sharded(label="POST 20 KB (park path)", port=port, body_path=large)

        def pct(a: float, b: float) -> str:
            return f"{100*a/b:.0f}%" if b > 0 else "n/a"

        print()
        print("═" * 63)
        print(" body-gate cost summary")
        print("─" * 63)
        print(f" hot     GET    : {hot_get:>12,.0f} req/s   (baseline)")
        print(f" hot     POST-S : {hot_inline:>12,.0f} req/s   (inline, {pct(hot_inline, hot_get)} of GET)")
        print(f" hot     POST-L : {hot_park:>12,.0f} req/s   (park,   {pct(hot_park, hot_get)} of GET)")
        print("─" * 63)
        print(f" sharded GET    : {sh_get:>12,d} req/s   (baseline)")
        print(f" sharded POST-S : {sh_inline:>12,d} req/s   (inline, {pct(sh_inline, sh_get)} of GET)")
        print(f" sharded POST-L : {sh_park:>12,d} req/s   (park,   {pct(sh_park, sh_get)} of GET)")
        print("═" * 63)
        return 0


if __name__ == "__main__":
    sys.exit(main())
