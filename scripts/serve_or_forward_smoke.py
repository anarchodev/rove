#!/usr/bin/env python3
"""V2 Phase-7 slice (a) smoke — serve-or-forward (project_v2_zero_downtime_move
memory; v2-build-order §Phase 7).

Proves the ROUTING-correctness half of the zero-downtime design: a DP cluster
that receives a request for a tenant it does NOT own forwards it to the owner
(discovered via the control plane's `/_cp/route`), instead of 404ing — so a
stale public route (Cloudflare) costs an extra hop, never a failure.

    CP (rewind-cp)    :19010   — owns host→tenant→cluster (the /_cp/route lookup)
    cluster-A rewind  :19011   — OWNS custtenant   (admin domain a.localhost)
    cluster-B rewind  :19012   — does NOT have it  (admin domain b.localhost)

No customer deploy needed: each cluster's "no tenant for host" 404 body names
its OWN admin_api_domain, so a request that reaches cluster-A comes back
mentioning a.localhost, and one answered locally by cluster-B mentions
b.localhost. That distinguishes a forward from a local 404.

Legs:
  A.  request to cluster-B (the WRONG cluster) with Host=cust → B can't
      resolve it locally → asks the CP → owner is cluster-A → B forwards to
      A → the 404 body mentions A's domain (a.localhost). Forward proven.
  B.  request to cluster-B with an UNKNOWN host → CP has no route → B does
      NOT forward → 404 body mentions B's own domain (b.localhost).
  C.  request to cluster-A (the OWNER) with Host=cust → A answers locally
      (it is the owner per the CP, so it does NOT re-forward — no loop) →
      404 body mentions A's domain.
  D.  (the async-forwarding win) a forward to a BLACK-HOLE owner (a TCP
      socket that accepts but never replies) parks off the worker loop;
      cluster-B's single worker still serves a concurrent local request in
      milliseconds. The prior BLOCKING forwarder would wedge that worker in
      libcurl for the whole stage timeout (~5-15s) — so this leg fails
      against the blocking implementation and passes against the async one.

Requires S3 env — `set -a; . ./.env; set +a` first.
Build:  `zig build rewind-worker && zig build rewind-cp`
"""

import os
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, await_line, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind-worker")

PCP = 19010
PA = 19011
PB = 19012
PBH = 19013  # black-hole owner: accepts the TCP connection, never replies
HOST = "cust.localhost"
TENANT = "custtenant"
SLOW_HOST = "slow.localhost"
SLOW_TENANT = "slowtenant"

procs = []


def start_blackhole():
    """A TCP server that accepts connections and holds them open without ever
    sending a byte — a forward to it parks until the engine's stage timeout.
    The blocking forwarder would wedge cluster-B's single worker here; the
    async one parks it off the loop. Daemon thread; dies with the process."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PBH))
    srv.listen(16)
    held = []

    def loop():
        while True:
            try:
                conn, _ = srv.accept()
                held.append(conn)  # keep the fd open; never read/write
            except OSError:
                return

    threading.Thread(target=loop, daemon=True).start()
    return srv


def spawn_rewind(name, port, data_dir, cluster_id, admin_domain):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = admin_domain
    env["REWIND_ROOT_TOKEN"] = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects unset/default
    env["REWIND_CLUSTER_ID"] = cluster_id
    # A LIST with a DEAD CP URL first (port 1, nothing listening) → exercises
    # the multi-CP fallthrough (Slice 2 HA): the worker skips the unreachable
    # CP node and uses the live one. A single down CP node never breaks
    # serve-or-forward.
    env["REWIND_CP_URL"] = f"http://127.0.0.1:1;http://127.0.0.1:{PCP}"
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def get(port, host):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "15", "--http2-prior-knowledge",
         f"http://127.0.0.1:{port}/", "-H", f"Host: {host}"],
        capture_output=True, text=True,
    ).stdout
    nl = out.rfind("\n")
    body, code = out[:nl], out[nl + 1:].strip()
    return (code, body)


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
    for b in (REWIND, CP_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind-worker && zig build rewind-cp`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    da = f"/tmp/sof-a-{pid}"
    db = f"/tmp/sof-b-{pid}"
    dcp = f"/tmp/sof-cp-{pid}"
    for d in (da, db, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, cond, detail=""):
        print(f"  {'ok  ' if cond else 'FAIL'} {label}  {detail}")
        if not cond:
            failures.append(label)

    bh = None
    try:
        print("boot: black-hole owner + CP + cluster-A (owner) + cluster-B (non-owner)")
        bh = start_blackhole()
        spawn_cp(
            procs, PCP,
            clusters=(
                f"cluster-A=http://127.0.0.1:{PA};cluster-B=http://127.0.0.1:{PB}"
                f";cluster-BH=http://127.0.0.1:{PBH}"
            ),
            hosts=f"{HOST}={TENANT};{SLOW_HOST}={SLOW_TENANT}",
            placement=f"{TENANT}=cluster-A;{SLOW_TENANT}=cluster-BH",
            cp_data_dir=dcp,
        )
        spawn_rewind("A", PA, da, "cluster-A", "a.localhost")
        spawn_rewind("B", PB, db, "cluster-B", "b.localhost")

        # ── A. mis-routed request to B forwards to the owner A ────────
        print("leg A: request to cluster-B (wrong) with Host=cust → forwards to A")
        code, body = get(PB, HOST)
        check("B forwarded to A (404 body names a.localhost)",
              "a.localhost" in body and "b.localhost" not in body,
              f"status={code}")

        # ── B. unknown host on B is NOT forwarded (CP has no route) ───
        print("leg B: request to cluster-B with unknown host → local 404 (b.localhost)")
        code, body = get(PB, "nope.localhost")
        check("B answered locally (404 body names b.localhost)",
              "b.localhost" in body and "a.localhost" not in body,
              f"status={code}")

        # ── C. request to the owner A is served locally, no re-forward ─
        print("leg C: request to cluster-A (owner) → local 404 (a.localhost), no loop")
        code, body = get(PA, HOST)
        check("A answered locally (404 body names a.localhost)",
              "a.localhost" in body,
              f"status={code}")

        # ── D. the async win: a parked forward doesn't wedge the worker ─
        print("leg D: forward to a black-hole owner parks; B still serves "
              "a concurrent local request (async, not blocked)")
        # Background: B forwards SLOW_HOST → cluster-BH (black hole) → the
        # engine parks it until its stage timeout. The blocking forwarder
        # would wedge B's single worker here for the whole timeout.
        bg = threading.Thread(target=lambda: get(PB, SLOW_HOST), daemon=True)
        bg.start()
        time.sleep(0.5)  # let the forward submit + park
        t0 = time.time()
        code, body = get(PB, "nope2.localhost")  # local 404, no owner
        elapsed = time.time() - t0
        check("B served a local request while a forward was parked",
              elapsed < 2.0 and "b.localhost" in body,
              f"status={code} elapsed={elapsed:.2f}s")
    finally:
        stop_all()
        if bh is not None:
            bh.close()
        for d in (da, db, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL: " + ", ".join(failures))
        sys.exit(1)
    print("\nPASS — a request to the wrong cluster is forwarded to the owner "
          "(serve-or-forward); stale routing is a hop, not a failure. (slice a)")


if __name__ == "__main__":
    main()
