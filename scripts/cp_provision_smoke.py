#!/usr/bin/env python3
"""V2 cutover gates #4 + #5: provision a BRAND-NEW tenant onto a multi-node
cluster with no move.

  rewind-cp :18205   (directory + provisioning orchestrator)
    └─ cluster-1 → rewind :18201,:18202,:18203  (3-node, no tenant placed)
  rewind-front :18200

Until now a tenant's raft group only formed via the attach fan-out of a
MOVE-in; a brand-new tenant had no create+place+form path. `POST
/_control/provision {tenant, cluster, host}` closes that: it empty-attaches
(no bundle) to EVERY node of `cluster` — forming the group across the whole
cluster (gap #4) — awaits the group's election, then writes the placement
(the commit point) and the host mapping (gap #5).

Checks:
  A. route for an unprovisioned host → 404 (nothing there yet).
  B. provision {freshtenant, cluster-1, fresh.localhost} → 204.
  C. /_cp/route resolves the host → cluster-1 with all 3 nodes.
  D. the formed group SERVES: a v2-kv PUT commits + reads back on every node
     (proves the group formed across the cluster and replicates).
  E. the front routes the host to the cluster (a write through the front).
  F. re-provisioning the same tenant → 409 (create-only); an unknown
     cluster → 400.

Build first:  zig build rewind && zig build rewind-cp && zig build rewind-front
Needs S3 env (the worker's blob backend): `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v2_topology import spawn_cp, spawn_front, await_line, CP_BIN, FRONT_BIN  # noqa: E402

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")

PF = int(os.environ.get("FRONT_PORT", "18200"))
PCP = int(os.environ.get("CP_PORT", "18205"))
P = [18201, 18202, 18203]   # cluster-1 HTTP ports
RP = [18211, 18212, 18213]  # cluster-1 raft peer ports

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "freshtenant"
HOST = "fresh.localhost"
KEY = "hello"
VALUE = "provisioned-and-served"

procs = []


def spawn_rewind(name, port, data_dir, multinode):
    node_id, voters, peers = multinode
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_NODE_ID"] = str(node_id)
    env["REWIND_VOTERS"] = voters
    env["REWIND_PEERS"] = peers
    p = subprocess.Popen([REWIND, data_dir, str(port)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    p._name = name
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def _curl(args):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "15", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True)
    text = out.stdout
    nl = text.rfind("\n")
    if nl < 0:
        return (0, text)
    body, code = text[:nl], text[nl + 1:].strip()
    try:
        return (int(code), body)
    except ValueError:
        return (0, body)


def provision(cp_port, tenant, cluster, host=None):
    data = {"tenant": tenant, "cluster": cluster}
    if host:
        data["host"] = host
    import json
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{cp_port}/_control/provision",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", json.dumps(data),
    ])


def cp_route(cp_port, host):
    return _curl([f"http://127.0.0.1:{cp_port}/_cp/route?host={host}"])


def kv_put(port, tenant, key, value):
    return _curl([
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}',
    ])[0]


def kv_get(port, tenant, key, host=None):
    args = [f"http://127.0.0.1:{port}/_system/v2-kv?tenant={tenant}&key={key}",
            "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}"]
    if host:
        args += ["-H", f"Host: {host}"]
    return _curl(args)


def put_leader_retry(tenant, key, value, deadline_s=20):
    """A v2-kv PUT is leader-gated (a follower 421s); try each node until one
    commits (204), within a deadline (the freshly-formed group needs to elect)."""
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        for port in P:
            if kv_put(port, tenant, key, value) == 204:
                return True
        time.sleep(0.3)
    return False


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

    pid = os.getpid()
    dnodes = [f"/tmp/cp-provision-n{i}-{pid}" for i in range(3)]
    dcp = f"/tmp/cp-provision-cp-{pid}"
    for d in (*dnodes, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    peers_csv = ",".join(f"127.0.0.1:{rp}" for rp in RP)
    try:
        print("boot: 3-node cluster-1 (NO tenant placed) + CP + front door")
        for i in range(3):
            spawn_rewind(f"n{i+1}", P[i], dnodes[i], multinode=(i + 1, "1,2,3", peers_csv))
        nodes_csv = ",".join(f"http://127.0.0.1:{p}" for p in P)
        # The CP knows the cluster's node set but has NO placement/host for the
        # fresh tenant — provisioning creates both.
        spawn_cp(procs, PCP,
                 clusters=f"cluster-1={nodes_csv}",
                 hosts="", placement="",
                 cp_data_dir=dcp, move_secret=MOVE_SECRET)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", route_cache_ms=0)

        # ── A. nothing there yet ──────────────────────────────────────
        print("leg A: route for the unprovisioned host → 404")
        st, _ = cp_route(PCP, HOST)
        check("route before provision", st, 404)

        # ── B. provision the brand-new tenant onto the 3-node cluster ─
        print("leg B: POST /_control/provision (form group on 3 nodes + place)")
        st, body = provision(PCP, TENANT, "cluster-1", host=HOST)
        check("provision status", st, 204)

        # ── C. now routable to all 3 nodes ────────────────────────────
        print("leg C: /_cp/route resolves the host → cluster-1 (3 nodes)")
        st, body = cp_route(PCP, HOST)
        check("route after provision", st, 200)
        check("route names all 3 nodes", body.count("http://127.0.0.1:1820"), 3)

        # ── D. the formed group SERVES + replicates ───────────────────
        print("leg D: the freshly-formed group serves a v2-kv write")
        check("PUT to the formed group's leader", put_leader_retry(TENANT, KEY, VALUE), True)
        for i, port in enumerate(P):
            st, body = kv_get(port, TENANT, KEY)
            check(f"GET n{i+1} (replicated)", (st, body), (200, VALUE))

        # ── E. the front routes the host to the cluster ───────────────
        print("leg E: the front door routes the provisioned host")
        st, body = kv_get(PF, TENANT, KEY, host=HOST)
        check("GET via front (→cluster-1)", (st, body), (200, VALUE))

        # ── F. create-only + validation ───────────────────────────────
        print("leg F: re-provision → 409; unknown cluster → 400")
        st, _ = provision(PCP, TENANT, "cluster-1", host=HOST)
        check("re-provision existing tenant", st, 409)
        st, _ = provision(PCP, "othertenant", "no-such-cluster")
        check("provision unknown cluster", st, 400)

        if failures:
            print(f"\nFAILURES ({len(failures)}):")
            for f in failures:
                print(f"  - {f}")
            return 1
        print("\nall provisioning smoke checks passed (gaps #4 + #5)")
        return 0
    finally:
        stop_all()
        for d in (*dnodes, dcp):
            subprocess.run(["rm", "-rf", d])


if __name__ == "__main__":
    sys.exit(main())
