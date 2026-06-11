#!/usr/bin/env python3
"""V2 Phase-3 exit smoke (v2-build-order §Phase 3,
v2 Phase-3 directory routing; docs/architecture/control-plane.md).

Stands up TWO single-node `rewind` clusters + one `rewind-front` front
door and proves the front door routes each tenant's request to the cluster
that owns it:

    front door :18090
      ├─ Host c1.localhost → tenant c1tenant → cluster-1 → rewind :18091
      └─ Host c2.localhost → tenant c2tenant → cluster-2 → rewind :18092

Routing proof without provisioning customer tenants: each backend runs
with a DISTINCT admin domain (`REWIND_ADMIN_DOMAIN`) + root token. The
built-in `/_system/admin-kv` write returns 204 iff the request's Host
matches the backend's admin domain. So:

  - directly hitting a backend with ITS host+token → 204; with the OTHER
    cluster's host+token → non-204. (Establishes the hosts are genuinely
    cluster-specific — a 204 means the request reached that exact cluster.)
  - through the FRONT DOOR, Host c1 → 204 and Host c2 → 204. Each 204 can
    only have come from the cluster whose admin domain matches that host,
    so both 204s together prove the front door routed each to the right
    cluster. A broken router (both to one cluster) would 204 one host and
    non-204 the other.

Requires S3 env (there is no fs BlobBackend) — source the repo `.env`
first:  `set -a; . ./.env; set +a; python3 scripts/two_cluster_smoke.py`.

Build first:  `zig build rewind && zig build rewind-front`
"""

import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, spawn_front, await_line, CP_BIN, FRONT_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")

PF = int(os.environ.get("FRONT_PORT", "18090"))
PCP = int(os.environ.get("CP_PORT", "18093"))
P1 = int(os.environ.get("C1_PORT", "18091"))
P2 = int(os.environ.get("C2_PORT", "18092"))

C1_HOST, C1_TOKEN = "c1.localhost", "c1roottokenpadding0123456789abcdefghij01"
C2_HOST, C2_TOKEN = "c2.localhost", "c2roottokenpadding0123456789abcdefghij02"

procs = []


def spawn_rewind(name, port, data_dir, admin_domain, token):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = admin_domain
    env["REWIND_ROOT_TOKEN"] = token
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def admin_kv(port, host, token, key, value):
    """POST /_system/admin-kv (HTTP/2 prior knowledge). Returns status."""
    out = subprocess.run(
        [
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10",
            "--http2-prior-knowledge", "-X", "POST",
            f"http://127.0.0.1:{port}/_system/admin-kv",
            "-H", f"Host: {host}",
            "-H", f"Authorization: Bearer {token}",
            "-H", "Content-Type: application/json",
            "--data", json.dumps({"pairs": [{"key": key, "value": value}]}),
        ],
        capture_output=True, text=True,
    )
    return out.stdout.strip()


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def main():
    for b in (REWIND, CP_BIN, FRONT_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind && zig build rewind-cp && zig build rewind-front`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    d1 = f"/tmp/two-cluster-c1-{os.getpid()}"
    d2 = f"/tmp/two-cluster-c2-{os.getpid()}"
    dcp = f"/tmp/two-cluster-cp-{os.getpid()}"
    for d in (d1, d2, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []
    try:
        print("boot: two rewind clusters + CP + front door")
        spawn_rewind("c1", P1, d1, C1_HOST, C1_TOKEN)
        spawn_rewind("c2", P2, d2, C2_HOST, C2_TOKEN)
        spawn_cp(
            procs, PCP,
            clusters=f"cluster-1=http://127.0.0.1:{P1};cluster-2=http://127.0.0.1:{P2}",
            hosts=f"{C1_HOST}=c1tenant;{C2_HOST}=c2tenant",
            placement="c1tenant=cluster-1;c2tenant=cluster-2",
            cp_data_dir=dcp,
        )
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}")

        def check(label, got, want, predicate="eq"):
            ok = (got == want) if predicate == "eq" else (got != want)
            sign = "==" if predicate == "eq" else "!="
            print(f"  {'ok ' if ok else 'FAIL'} {label}: HTTP {got} ({sign} {want})")
            if not ok:
                failures.append(f"{label}: got {got}")

        # ── Direct: establish each host is cluster-specific ───────────
        print("leg 1: direct backend hits prove hosts are cluster-specific")
        check("direct c1 ← c1 host/token", admin_kv(P1, C1_HOST, C1_TOKEN, "k/d1", "v"), "204")
        check("direct c2 ← c2 host/token", admin_kv(P2, C2_HOST, C2_TOKEN, "k/d2", "v"), "204")
        check("direct c1 ← c2 host/token (foreign)", admin_kv(P1, C2_HOST, C2_TOKEN, "k/x", "v"), "204", "ne")
        check("direct c2 ← c1 host/token (foreign)", admin_kv(P2, C1_HOST, C1_TOKEN, "k/x", "v"), "204", "ne")

        # ── Through the front door: the routing proof ─────────────────
        print("leg 2: front-door routing — each host must reach its own cluster")
        check("front Host c1 → cluster-1", admin_kv(PF, C1_HOST, C1_TOKEN, "k/f1", "v"), "204")
        check("front Host c2 → cluster-2", admin_kv(PF, C2_HOST, C2_TOKEN, "k/f2", "v"), "204")

        # ── Unknown host → front door 404 (no placement) ─────────────
        print("leg 3: front-door rejects an unmapped host")
        check("front Host unknown → 404", admin_kv(PF, "nope.localhost", C1_TOKEN, "k/n", "v"), "404")
    finally:
        stop_all()
        for d in (d1, d2, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — front door routes each tenant to its owning cluster.")


if __name__ == "__main__":
    main()
