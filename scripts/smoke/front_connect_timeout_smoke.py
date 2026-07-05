#!/usr/bin/env python3
"""Front-door upstream connect timeout smoke (plan A1,
docs/plans/front-door-hardening.md).

A backend that blackholes SYNs (node down hard, partition, firewall
drop) used to pin every flow aimed at it for the kernel SYN-retry
budget (~2 min): the io connect op has no timeout and no proxy deadline
covered the waiting-on-connect window. The fix sweeps `.connecting`
pool entries past `REWIND_FRONT_CONNECT_TIMEOUT_MS` (default 1000) and
fails their waiters over.

Topology: a real single-node CP whose cluster points at a BLACKHOLE
node IP (10.255.255.1 — RFC 1918, unrouted from dev boxes, SYNs drop
silently), and a front resolving against it. No workers, no S3.

Proof legs:
  A. GET through the front for a placed host → 502 (all nodes
     unreachable) in ~connect-timeout, NOT minutes. The pre-fix
     behavior hangs until curl's own -m fires (status 0).
  B. an immediate second request also answers fast (the timed-out node
     is marked down with a backoff stamp — no fresh full-length hang).
  C. an unknown host → 404 fast, twice (the second served from the
     negative route cache — plan A6 — though this leg only asserts the
     status + bound, not cache internals).

Build first: `zig build rewind-cp rewind-front`
"""

import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, spawn_front, CP_BIN, FRONT_BIN

PCP = int(os.environ.get("CP_PORT", "18240"))
PF = int(os.environ.get("FRONT_PORT", "18241"))

# The blackhole: SYNs to this RFC 1918 address are dropped, not RST.
CLUSTERS = "cluster-1=http://10.255.255.1:18999"
PLACEMENT = "acme=cluster-1"
HOSTS = "acme.example=acme"

CONNECT_TIMEOUT_MS = 1000

procs = []


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


def timed_get(host):
    """GET / through the front with `host`. Returns (status, seconds).
    curl -m 30 is the failure detector: pre-fix, the flow hangs on the
    blackholed connect and curl itself gives up (status 0, ~30 s)."""
    t0 = time.monotonic()
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "30",
         "-H", f"Host: {host}", f"http://127.0.0.1:{PF}/"],
        capture_output=True, text=True,
    ).stdout
    dur = time.monotonic() - t0
    try:
        return (int(out.strip() or 0), dur)
    except ValueError:
        return (0, dur)


def main():
    for b, step in ((CP_BIN, "rewind-cp"), (FRONT_BIN, "rewind-front")):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build {step}`")

    cpd = f"/tmp/front-connect-timeout-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(label)

    try:
        print("boot: single-node CP (blackhole cluster) + front")
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS,
                 placement=PLACEMENT, cp_data_dir=cpd)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", extra_env={
            "REWIND_FRONT_CONNECT_TIMEOUT_MS": str(CONNECT_TIMEOUT_MS),
        })

        # The generous bound: route resolve + connect timeout + sweep
        # cadence + curl overhead. The pre-fix hang is ~30 s (curl -m).
        bound_s = 6.0

        print("leg A: placed host on a blackholed node → fast 502")
        st, dur = timed_get("acme.example")
        check("status is 502 (all nodes unreachable)", st == 502, f"got {st}")
        check(f"answered in <{bound_s}s (connect timeout, not kernel budget)",
              dur < bound_s, f"{dur:.2f}s")
        check(f"answered in ≥ connect timeout (it actually dialed)",
              dur >= CONNECT_TIMEOUT_MS / 1000 * 0.5, f"{dur:.2f}s")

        print("leg B: immediate retry also answers fast (backoff, no re-hang)")
        st, dur = timed_get("acme.example")
        check("status is 502", st == 502, f"got {st}")
        check(f"answered in <{bound_s}s", dur < bound_s, f"{dur:.2f}s")

        print("leg C: unknown host → fast 404, twice (negative cache)")
        for i in (1, 2):
            st, dur = timed_get("ghost.example")
            check(f"404 #{i}", st == 404, f"got {st}")
            check(f"404 #{i} in <{bound_s}s", dur < bound_s, f"{dur:.2f}s")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — a blackholed backend fails over in ~the connect timeout, "
          "never the kernel SYN budget. ✅ (plan A1)")


if __name__ == "__main__":
    main()
