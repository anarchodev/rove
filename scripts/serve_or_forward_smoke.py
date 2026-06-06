#!/usr/bin/env python3
"""V2 Phase-7 slice (a) smoke — serve-or-forward (project_v2_zero_downtime_move
memory; docs/v2-build-order.md §Phase 7).

Proves the ROUTING-correctness half of the zero-downtime design: a DP cluster
that receives a request for a tenant it does NOT own forwards it to the owner
(discovered via the control plane's `/_cp/route`), instead of 404ing — so a
stale public route (Cloudflare) costs an extra hop, never a failure.

    CP (rewind-front) :19010   — owns host→tenant→cluster (the /_cp/route lookup)
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

Requires S3 env — `set -a; . ./.env; set +a` first.
Build:  `zig build rewind && zig build rewind-front`
"""

import os
import signal
import subprocess
import sys
import time

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")
FRONT = os.path.join(BINDIR, "rewind-front")

PCP = 19010
PA = 19011
PB = 19012
HOST = "cust.localhost"
TENANT = "custtenant"

procs = []


def spawn_rewind(name, port, data_dir, cluster_id, admin_domain):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = admin_domain
    env["REWIND_CLUSTER_ID"] = cluster_id
    env["REWIND_CP_URL"] = f"http://127.0.0.1:{PCP}"
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    _await_line(p, name, "listening on")
    return p


def spawn_front():
    env = dict(os.environ)
    env["REWIND_CLUSTERS"] = f"cluster-A=http://127.0.0.1:{PA};cluster-B=http://127.0.0.1:{PB}"
    env["REWIND_HOSTS"] = f"{HOST}={TENANT}"
    env["REWIND_PLACEMENT"] = f"{TENANT}=cluster-A"
    env["REWIND_CP_DATA_DIR"] = f"/tmp/sof-cp-{os.getpid()}"
    p = subprocess.Popen(
        [FRONT, str(PCP)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    _await_line(p, "cp", "listening on")
    return p


def _await_line(p, name, needle):
    deadline = time.time() + 15
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            if p.poll() is not None:
                raise SystemExit(f"{name} exited early: rc={p.returncode}")
            continue
        sys.stdout.write(f"  [{name}] " + line)
        if needle in line:
            return
    raise SystemExit(f"{name} did not reach '{needle}' within 15s")


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
    for b in (REWIND, FRONT):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind && zig build rewind-front`")
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

    try:
        print("boot: CP + cluster-A (owner) + cluster-B (non-owner)")
        spawn_front()
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
    finally:
        stop_all()
        for d in (da, db, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL: " + ", ".join(failures))
        sys.exit(1)
    print("\nPASS — a request to the wrong cluster is forwarded to the owner "
          "(serve-or-forward); stale routing is a hop, not a failure. (slice a)")


if __name__ == "__main__":
    main()
