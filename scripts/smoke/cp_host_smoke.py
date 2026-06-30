#!/usr/bin/env python3
"""CP replicated domain index smoke (gap #2; docs/v2-cp-directory-replication.md,
V2 cutover gap #2 — the host axis, docs/architecture/control-plane.md).

The host→tenant index used to be a static `REWIND_HOSTS` env map. Gap #2 makes
it a replicated axis in the CP `__directory__` group (`host/{host}` → tenant,
sibling to `cluster/*` / `placement/*` / `plan/*`): durable across a CP restart,
spanning the HA nodes, and accepting runtime custom-domain provisioning via the
`POST /_control/host` control write. Routing (`/_cp/route?host=H`) resolves
host→tenant from this replicated index, then tenant→cluster from placement.

The CP needs no DP workers and no S3 — `/_cp/route` returns the cluster's node
list from the in-memory projection without contacting the nodes.

Proof legs:
  A. an unmapped host → 404 (no route).
  A2. a host seeded from static REWIND_HOSTS resolves (the env map is now
      written INTO the replicated directory).
  B. POST /_control/host {host, tenant} (move-secret gated) → 200; the host now
     routes to the tenant's cluster.
  C. re-point the host to a tenant on a DIFFERENT cluster → routing follows.
  D. POST /_control/host WITHOUT the secret → 401 (admin-gated write); the
     mapping is unchanged.
  E. durability — kill -9 the CP, restart over the same REWIND_CP_DATA_DIR, the
     domain index REPLAYS (runtime mapping + static seed both survive).

Build first:  `zig build rewind-cp`
"""

import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, CP_BIN

PCP = int(os.environ.get("CP_PORT", "18220"))
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"

# Two clusters + two placed tenants; the workers don't have to exist — the route
# lookup returns the projection's node list without contacting them.
CLUSTERS = "cluster-1=http://127.0.0.1:18221;cluster-2=http://127.0.0.1:18222"
PLACEMENT = "acme=cluster-1;globex=cluster-2"
# Static seed → written INTO the directory (leg A2 + survives restart).
HOSTS = "seeded.example=acme"

procs = []


def _curl(args):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "10", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True,
    ).stdout
    nl = out.rfind("\n")
    if nl < 0:
        return (0, out)
    try:
        return (int(out[nl + 1:].strip() or 0), out[:nl])
    except ValueError:
        return (0, out[:nl])


def set_host(host, tenant, secret=MOVE_SECRET):
    body = json.dumps({"host": host, "tenant": tenant}, separators=(",", ":"))
    args = ["-X", "POST", f"http://127.0.0.1:{PCP}/_control/host",
            "-H", "Content-Type: application/json", "--data", body]
    if secret is not None:
        args += ["-H", f"X-Rewind-Move-Secret: {secret}"]
    return _curl(args)


def route(host):
    """GET /_cp/route?host=H → (status, {cluster, tenant} | None)."""
    st, body = _curl([f"http://127.0.0.1:{PCP}/_cp/route?host={host}"])
    if st != 200:
        return (st, None)
    try:
        return (st, json.loads(body))
    except json.JSONDecodeError:
        return (st, None)


def spawn(want_needle, cpd):
    return spawn_cp(
        procs, PCP,
        clusters=CLUSTERS, hosts=HOSTS, placement=PLACEMENT,
        cp_data_dir=cpd, move_secret=MOVE_SECRET, want_needle=want_needle,
    )


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
    if not os.path.exists(CP_BIN):
        raise SystemExit(f"{CP_BIN} not found — run `zig build rewind-cp`")

    cpd = f"/tmp/cp-host-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: single-node CP (domain index)")
        spawn("seeded directory from static config", cpd)

        # ── A. unmapped host → 404 ────────────────────────────────────
        print("leg A: an unmapped host has no route")
        st, _ = route("acme.com")
        check("GET /_cp/route unmapped → 404", st, 404)

        # ── A2. static REWIND_HOSTS seeded into the directory ─────────
        print("leg A2: a statically-seeded host resolves")
        st, r = route("seeded.example")
        check("GET /_cp/route seeded → 200", st, 200)
        check("seeded host → cluster-1", (r or {}).get("cluster"), "cluster-1")
        check("seeded host → tenant acme", (r or {}).get("tenant"), "acme")

        # ── B. runtime custom-domain provisioning ────────────────────
        print("leg B: map acme.com → acme via /_control/host")
        st, _ = set_host("acme.com", "acme")
        check("POST /_control/host → 200", st, 200)
        st, r = route("acme.com")
        check("GET /_cp/route acme.com → 200", st, 200)
        check("acme.com → cluster-1", (r or {}).get("cluster"), "cluster-1")

        # ── C. re-point to a tenant on another cluster ───────────────
        print("leg C: re-point acme.com → globex (on cluster-2)")
        st, _ = set_host("acme.com", "globex")
        check("POST /_control/host re-point → 200", st, 200)
        st, r = route("acme.com")
        check("acme.com now → cluster-2", (r or {}).get("cluster"), "cluster-2")
        check("acme.com now → tenant globex", (r or {}).get("tenant"), "globex")

        # ── D. unauthenticated write rejected ────────────────────────
        print("leg D: a host write without the move secret is rejected")
        st, _ = set_host("acme.com", "acme", secret=None)
        check("POST /_control/host no-secret → 401", st, 401)
        st, r = route("acme.com")
        check("mapping unchanged (still globex/cluster-2)", (r or {}).get("cluster"), "cluster-2")

        # ── E. durability across a CP restart ────────────────────────
        print("leg E: kill -9 the CP; the domain index replays")
        procs[0].send_signal(signal.SIGKILL)
        procs[0].wait()
        procs.clear()
        spawn("skipping static seed", cpd)
        st, r = route("acme.com")
        check("runtime mapping survived restart → cluster-2", (r or {}).get("cluster"), "cluster-2")
        st, r = route("seeded.example")
        check("static seed survived restart → cluster-1", (r or {}).get("cluster"), "cluster-1")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — the CP serves a replicated host→tenant domain index "
          "(admin-gated write, runtime provisioning, durable across restart). ✅ (gap #2)")


if __name__ == "__main__":
    main()
