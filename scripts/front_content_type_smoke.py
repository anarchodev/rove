#!/usr/bin/env python3
"""V2 cutover gate: the front door relays the backend's response headers
(content-type et al.) — not just status + body.

  rewind-cp :18305   (directory)
    └─ cluster-1 → rewind :18301   (single node)
  rewind-front :18300

The DP's `/_system/v2-kv` GET responds `content-type: text/plain`
(`v2_move.zig`). Before the passthrough fix the front dropped all response
headers; now `proxyToCluster` relays them (lowercased for h2, minus hop-by-hop
+ framing headers). The gate: a GET routed THROUGH the front carries the
backend's `content-type`, and the body is intact.

Build first:  zig build rewind-worker && zig build rewind-cp && zig build rewind-front
Needs S3 env (the worker's blob backend): `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v2_topology import spawn_cp, spawn_front, await_line, CP_BIN, FRONT_BIN  # noqa: E402

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind-worker")

PF = int(os.environ.get("FRONT_PORT", "18300"))
PCP = int(os.environ.get("CP_PORT", "18305"))
P1 = int(os.environ.get("C1_PORT", "18301"))

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "cttenant"
HOST = "ct.localhost"
KEY = "doc"
VALUE = "content-type-relayed"

procs = []


def spawn_rewind(name, port, data_dir):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_ROOT_TOKEN"] = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects unset/default
    p = subprocess.Popen([REWIND, data_dir, str(port)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def kv_put(port, tenant, key, value):
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "15",
         "--http2-prior-knowledge", "-X", "PUT",
         f"http://127.0.0.1:{port}/_system/v2-kv",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         "-H", "Content-Type: application/json",
         "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}'],
        capture_output=True, text=True)
    return out.stdout.strip()


def front_get_headers(tenant, key, host):
    """GET through the front with -i; return (status:int, headers:str, body:str)."""
    out = subprocess.run(
        ["curl", "-s", "-i", "-m", "15", "--http2-prior-knowledge",
         f"http://127.0.0.1:{PF}/_system/v2-kv?tenant={tenant}&key={key}",
         "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
         "-H", f"Host: {host}"],
        capture_output=True, text=True).stdout
    # Split headers / body on the blank line.
    sep = out.find("\r\n\r\n")
    if sep < 0:
        sep = out.find("\n\n")
        head, body = (out[:sep], out[sep + 2:]) if sep >= 0 else (out, "")
    else:
        head, body = out[:sep], out[sep + 4:]
    status = 0
    first = head.splitlines()[0] if head else ""
    for tok in first.split():
        if tok.isdigit():
            status = int(tok)
            break
    return status, head, body


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
            raise SystemExit(f"{b} not found — run `zig build rewind-worker && zig build rewind-cp && zig build rewind-front`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    d1 = f"/tmp/front-ct-c1-{pid}"
    dcp = f"/tmp/front-ct-cp-{pid}"
    for d in (d1, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: single-node cluster-1 + CP + front door")
        spawn_rewind("c1", P1, d1)
        spawn_cp(procs, PCP,
                 clusters=f"cluster-1=http://127.0.0.1:{P1}",
                 hosts=f"{HOST}={TENANT}",
                 placement=f"{TENANT}=cluster-1",
                 cp_data_dir=dcp, move_secret=MOVE_SECRET)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", route_cache_ms=0)

        print("seed: PUT a value directly on the node")
        check("PUT v2-kv", kv_put(P1, TENANT, KEY, VALUE), "204")

        print("gate: GET through the front relays the backend's content-type")
        status, head, body = front_get_headers(TENANT, KEY, HOST)
        check("GET via front status", status, 200)
        check("body intact", body, VALUE)
        # The DP's v2-kv GET sets content-type: text/plain — it must survive the
        # proxy hop now (was dropped before the passthrough fix).
        has_ct = "content-type: text/plain" in head.lower()
        check("content-type relayed", has_ct, True)
        if not has_ct:
            print("  --- response headers ---")
            print("  " + head.replace("\n", "\n  "))

        if failures:
            print(f"\nFAILURES ({len(failures)}):")
            for f in failures:
                print(f"  - {f}")
            return 1
        print("\nall content-type passthrough checks passed")
        return 0
    finally:
        stop_all()
        for d in (d1, dcp):
            subprocess.run(["rm", "-rf", d])


if __name__ == "__main__":
    sys.exit(main())
