#!/usr/bin/env python3
"""V2 Phase-4 exit smoke ⭐ THE MILESTONE (v2-build-order §Phase 4,
docs/v2-phase4-tenant-move.md).

Moves a live tenant from one single-node cluster to another (zero-downtime —
the source serves throughout) and proves the data survives + the new cluster
serves it:

    rewind-cp :18093    (move orchestrator + routing directory)
    front door :18090   (stateless proxy; resolves placement from the CP)
      ├─ cluster-1 → rewind :18091   (movetenant starts here)
      └─ cluster-2 → rewind :18092   (movetenant ends here)

    write → move → read-back

The tenant store is seeded + read through the cluster-internal move
surface (`/_system/v2-kv`, gated by REWIND_MOVE_SECRET): a PUT writes
through the real propose→commit path; a GET reads the kvexp store. The
move itself is one call to the CP's `POST /_control/move` (the zero-downtime
move — the brief-pause/quiesce variant was retired): empty-attach the dest,
forward live writes, STREAM the snapshot source→dest (insert-if-absent), flip
the routing directory (the commit point), and evict the source.

Proof legs:
  A. seed on c1 (direct) + read-back on c1 → value is there.
  A2. read through the FRONT DOOR (Host=mover) → routed to c1 → value.
  B. POST front /_control/move {tenant, dest:cluster-2} → 200.
  C. read-back on c2 (direct) → SAME value (data intact, c2 now serves).
  D. read on c1 (direct) → 404 (source evicted: group destroyed + instance
     dropped).
  E. read through the FRONT DOOR (Host=mover) → now routed to c2 → value
     (the directory flip changed routing).

Requires S3 env (there is no fs BlobBackend) — source the repo `.env`
first:  `set -a; . ./.env; set +a; python3 scripts/smoke/tenant_move_smoke.py`.

Build first:  `zig build rewind-worker && zig build rewind-front`
"""

import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, spawn_front, await_line, CP_BIN, FRONT_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind-worker")

PF = int(os.environ.get("FRONT_PORT", "18090"))
PCP = int(os.environ.get("CP_PORT", "18093"))
P1 = int(os.environ.get("C1_PORT", "18091"))
P2 = int(os.environ.get("C2_PORT", "18092"))

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "movetenant"
HOST = "mover.localhost"
KEY = "greeting"
VALUE = "hello-from-c1"

procs = []


def spawn_rewind(name, port, data_dir):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_ROOT_TOKEN"] = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects unset/default
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def _curl(args):
    """Run curl, return (status:int, body:str)."""
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "15", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True,
    )
    text = out.stdout
    nl = text.rfind("\n")
    if nl < 0:
        return (0, text)
    body, code = text[:nl], text[nl + 1:].strip()
    try:
        return (int(code), body)
    except ValueError:
        return (0, body)


def kv_put(port, tenant, key, value, host=None):
    args = [
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}',
    ]
    if host:
        args += ["-H", f"Host: {host}"]
    return _curl(args)[0]


def kv_get(port, tenant, key, host=None):
    args = [
        f"http://127.0.0.1:{port}/_system/v2-kv?tenant={tenant}&key={key}",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
    ]
    if host:
        args += ["-H", f"Host: {host}"]
    return _curl(args)


def move(cp_port, tenant, dest):
    args = [
        "-X", "POST", f"http://127.0.0.1:{cp_port}/_control/move",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","dest":"{dest}"}}',
    ]
    return _curl(args)


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

    d1 = f"/tmp/tenant-move-c1-{os.getpid()}"
    d2 = f"/tmp/tenant-move-c2-{os.getpid()}"
    dcp = f"/tmp/tenant-move-cp-{os.getpid()}"
    for d in (d1, d2, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: two rewind clusters + CP (move control) + front door")
        spawn_rewind("c1", P1, d1)
        spawn_rewind("c2", P2, d2)
        spawn_cp(
            procs, PCP,
            clusters=f"cluster-1=http://127.0.0.1:{P1};cluster-2=http://127.0.0.1:{P2}",
            hosts=f"{HOST}={TENANT}",
            placement=f"{TENANT}=cluster-1",
            cp_data_dir=dcp,
            move_secret=MOVE_SECRET,
        )
        # route_cache_ms=0 → the front re-resolves placement every request, so
        # the post-move read (leg E) sees the directory flip immediately. The
        # move-surface `/_system/v2-kv` probe is not a serve-or-forward path, so
        # a stale cached route would hit the evicted source; always-fresh avoids
        # that. (Customer traffic tolerates a stale hop via serve-or-forward —
        # see serve_or_forward_smoke.)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", route_cache_ms=0)

        # ── A. seed on c1, read it back two ways ──────────────────────
        print("leg A: seed movetenant on cluster-1")
        check("PUT c1 seed", kv_put(P1, TENANT, KEY, VALUE), 204)
        st, body = kv_get(P1, TENANT, KEY)
        check("GET c1 read-back status", st, 200)
        check("GET c1 read-back value", body, VALUE)

        print("leg A2: front door routes movetenant → cluster-1 (pre-move)")
        st, body = kv_get(PF, TENANT, KEY, host=HOST)
        check("GET via front (→c1) status", st, 200)
        check("GET via front (→c1) value", body, VALUE)

        # ── B. the move ──────────────────────────────────────────────
        print("leg B: move movetenant cluster-1 → cluster-2 (brief pause)")
        st, body = move(PCP, TENANT, "cluster-2")
        check("POST /_control/move status", st, 200)
        print(f"       move says: {body.strip()!r}")

        # ── C. read-back on the NEW cluster ──────────────────────────
        print("leg C: data is intact + served by cluster-2")
        st, body = kv_get(P2, TENANT, KEY)
        check("GET c2 read-back status", st, 200)
        check("GET c2 read-back value", body, VALUE)

        # ── D. source released ───────────────────────────────────────
        print("leg D: source cluster-1 released the tenant")
        st, _ = kv_get(P1, TENANT, KEY)
        check("GET c1 after move (evicted)", st, 404)

        # ── E. front door now routes to the new cluster ──────────────
        print("leg E: front door routes movetenant → cluster-2 (post-move)")
        st, body = kv_get(PF, TENANT, KEY, host=HOST)
        check("GET via front (→c2) status", st, 200)
        check("GET via front (→c2) value", body, VALUE)
    finally:
        stop_all()
        for d in (d1, d2, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — moved a live tenant across clusters; data intact, new cluster serves it. ⭐")


if __name__ == "__main__":
    main()
