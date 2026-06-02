#!/usr/bin/env python3
"""Phase 3.2 perf gate — `raft_pending_response` write-commit hot path.

Measures sustained req/s of a pure single-key write handler through
the full propose → park-in-`raft_pending_response` → commit → respond
cycle, on the smoke_lib 3-node TLS cluster (the real raft path the
migration rewrites). Drives load with h2load (the project's standard,
same tool as `kv_write_bench.sh`).

Workflow for the Phase 3.2 migration:

  1. On the CURRENT tree (ReleaseFast build), record the baseline:
         zig build -Doptimize=ReleaseFast install
         python3 scripts/raft_pending_perf_bench.py --record
  2. Do the migration.
  3. Gate: `--check` fails if req/s regressed > THRESHOLD below baseline.
         python3 scripts/raft_pending_perf_bench.py --check

Baseline lives at scripts/.raft_pending_perf_baseline.json (gitignored
via .git/info/exclude — it's machine-specific; record it on the same
box you check on).

IMPORTANT (see memory `reference_benchmarking`): build ReleaseFast or
the number is meaningless; the absolute value is machine-specific, so
only the SAME-box pre/post ratio is the gate. This measures the
single-tenant hot path only — the sharded ceiling is gated separately
by `scripts/kv_shard_bench.sh` (called out in `scripts/phase32_gate.sh`
so the coverage gap is explicit, not silent).

Env: REQUESTS (200000), CLIENTS (16), STREAMS (32), THRESHOLD (0.10),
     WARMUP (20000), WORKERS (1).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "be57be57be57be57be57be57be57be57be57be57be57be57be57be57be57be57"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
TENANT = "rpperf"
OPERATOR_EMAIL = "operator@example.com"

REQUESTS = int(os.environ.get("REQUESTS", "200000"))
CLIENTS = int(os.environ.get("CLIENTS", "16"))
STREAMS = int(os.environ.get("STREAMS", "32"))
WARMUP = int(os.environ.get("WARMUP", "20000"))
WORKERS = int(os.environ.get("WORKERS", "1"))
THRESHOLD = float(os.environ.get("THRESHOLD", "0.10"))

BASELINE = Path(__file__).resolve().parent / ".raft_pending_perf_baseline.json"

# Pure single-key write — the dominant raft_pending_response shape.
HANDLER_SRC = '''
export function hot() { kv.set("k", "v"); return "ok"; }
export default function () { return "ok"; }
'''

_OP: dict = {}


def q(args: list) -> str:
    return urllib.parse.quote(json.dumps(args))


def provision(c: Cluster, cc, name: str) -> None:
    r = curl(cc, f"{c.admin_origin()}/?fn=createInstance&args={q([name])}",
             headers={"Cookie": _OP["cookie"]})
    if r.status not in (200, 201):
        sys.exit(f"FAIL createInstance {name}: {r.status} {r.body}")


def run_h2load(url: str, n: int, c: int, m: int) -> float:
    """Run h2load; return req/s parsed from its summary line."""
    proc = subprocess.run(
        ["h2load", "-n", str(n), "-c", str(c), "-m", str(m), url],
        capture_output=True, text=True, timeout=600,
    )
    out = proc.stdout + proc.stderr
    # h2load prints: "finished in 1.23s, 81234.56 req/s, 12.34MB/s"
    mt = re.search(r"([\d.]+)\s*req/s", out)
    if not mt:
        sys.exit(f"FAIL: could not parse h2load req/s from:\n{out}")
    # Guard against fast-fail inflating req/s (memory:
    # `feedback_bench_must_verify_2xx`). h2load prints e.g.
    # "status codes: 200000 2xx, 0 3xx, 0 4xx, 0 5xx". A throttled run
    # would show 4xx (429 rate-limit) or 5xx; those responses are
    # cheap, so the rate would be a lie. Require EVERY response 2xx —
    # a single non-2xx fails the run rather than silently averaging in.
    def code_count(klass: str) -> int:
        m = re.search(rf"(\d+)\s*{klass}", out)
        return int(m.group(1)) if m else 0

    if "status codes:" not in out:
        sys.exit(f"FAIL: h2load printed no status-code breakdown:\n{out}")
    twoxx = code_count("2xx")
    n3, n4, n5 = code_count("3xx"), code_count("4xx"), code_count("5xx")
    # h2load also reports a `failed`/`errored` tally for transport drops.
    fm = re.search(r"requests:\s*\d+ total,.*?(\d+)\s*failed,\s*(\d+)\s*errored", out)
    failed = int(fm.group(1)) if fm else 0
    errored = int(fm.group(2)) if fm else 0
    print(f"    status: {twoxx} 2xx, {n3} 3xx, {n4} 4xx, {n5} 5xx; "
          f"{failed} failed, {errored} errored")
    if n4 or n5 or failed or errored:
        sys.exit(
            "FAIL: non-2xx / failed responses — req/s would be a "
            f"fast-fail lie (4xx={n4} 5xx={n5} failed={failed} "
            f"errored={errored}). Check rate limits / SSRF gate:\n{out}"
        )
    if twoxx == 0:
        sys.exit(f"FAIL: zero 2xx responses:\n{out}")
    return float(mt.group(1))


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "--print"
    if mode not in ("--record", "--check", "--print"):
        sys.exit(f"usage: {sys.argv[0]} [--record|--check|--print]")
    if not shutil.which("h2load"):
        sys.exit("FAIL: h2load not found (install the nghttp2 package)")

    cluster = Cluster.spawn(
        tag="raft-pending-perf-bench",
        http_base=8420,
        raft_base=40424,
        files_port=8424,
        log_port=8423,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        workers_per_node=WORKERS,
        worker_extra_args=[
            "--dev-webhook-unsafe",
            # Don't let the token bucket cap throughput.
            "--rate-limit-request-capacity", "100000000",
            "--rate-limit-request-refill", "100000000",
        ],
    )
    with cluster as c:
        c.discover_leader()
        admin_origin = c.admin_origin()
        c.spawn_files_server(
            cors_origin=admin_origin, leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(f"auth.{SYSTEM_SUFFIX}", f"{TENANT}.{PUBLIC_SUFFIX}")

        leader_log = Path(f"/tmp/raft-pending-perf-bench-worker-{c.leader_idx}.out")
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists() and \
               "tenant __admin__ loaded deployment" in leader_log.read_text(errors="replace"):
                break
            time.sleep(0.1)

        deadline = time.monotonic() + 20.0
        r = curl(cc, f"{admin_origin}/?fn=listInstance", headers={"Origin": admin_origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{admin_origin}/?fn=listInstance", headers={"Origin": admin_origin})
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        _OP["cookie"] = c.oidc_login(cc, OPERATOR_EMAIL)
        provision(c, cc, TENANT)

        dep_id = c.put_file(TENANT, "index.mjs", HANDLER_SRC)
        c.release(TENANT, dep_id)
        c.wait_for_handler(TENANT, "/?fn=hot", expected_body_prefix="ok", timeout_s=10.0)
        print(f"ok  deployed {TENANT} (workers_per_node={WORKERS})")

        # h2load needs a plain host:port URL; it does SNI to the
        # *.localhost name (nss-myhostname → loopback) and negotiates
        # h2 over TLS. The leader's public listener serves the write.
        url = f"https://{TENANT}.{PUBLIC_SUFFIX}:{c.leader_port()}/?fn=hot"

        if WARMUP > 0:
            run_h2load(url, WARMUP, CLIENTS, STREAMS)  # pay compile / arena warm
        req_s = run_h2load(url, REQUESTS, CLIENTS, STREAMS)
        print(f"METRIC raft_pending_hot_write_req_s={req_s:.1f} "
              f"(n={REQUESTS} c={CLIENTS} m={STREAMS} workers={WORKERS})")

        if mode == "--record":
            BASELINE.write_text(json.dumps({
                "hot_write_req_s": req_s,
                "requests": REQUESTS, "clients": CLIENTS,
                "streams": STREAMS, "workers": WORKERS,
            }, indent=2))
            print(f"ok  recorded baseline → {BASELINE}")
            return 0

        if mode == "--check":
            if not BASELINE.exists():
                sys.exit(f"FAIL --check: no baseline at {BASELINE} "
                         f"(run --record on the current tree first)")
            base = json.loads(BASELINE.read_text())["hot_write_req_s"]
            floor = base * (1.0 - THRESHOLD)
            ratio = req_s / base if base else 0.0
            print(f"baseline={base:.1f} req/s  current={req_s:.1f} req/s  "
                  f"ratio={ratio:.3f}  floor={floor:.1f} (−{THRESHOLD:.0%})")
            if req_s < floor:
                sys.exit(f"FAIL: regression — {req_s:.1f} < floor {floor:.1f} req/s")
            print("PASS raft_pending_perf_bench (no regression)")
            return 0

        return 0


if __name__ == "__main__":
    sys.exit(main())
