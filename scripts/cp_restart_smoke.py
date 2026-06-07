#!/usr/bin/env python3
"""CP directory durability across a front-door restart (Slice 1 exit;
docs/v2-cp-directory-replication.md).

The front door's routing directory is now durable — backed by a single-node
CP `bridge` (one "directory" raft group, store at REWIND_CP_DATA_DIR). A
committed move (the directory flip) must survive a control-plane restart:
the recovered front door replays the store and keeps routing to the new
owner, rather than re-seeding back to the static REWIND_PLACEMENT.

  topology:
    rewind-cp  :18093   (move orchestrator + DURABLE routing directory; restarted)
    front door :18090   (stateless proxy; resolves placement from the CP)
      ├─ cluster-1 → rewind :18091   (movetenant starts here)
      └─ cluster-2 → rewind :18092   (movetenant ends here)

  A. seed movetenant on cluster-1; front routes Host=mover → c1.
  B. POST CP /_control/move {tenant, dest:cluster-2} → 200 (directory
     flip is one committed raft write).
  C. front routes Host=mover → c2 (post-move).
  D. KILL -9 the CP (hard crash, no graceful close → recovery is via WAL
     replay); restart it over the SAME REWIND_CP_DATA_DIR (the rewind
     clusters + the front door keep running). REWIND_PLACEMENT still says
     cluster-1 in the env.
  E. the recovered CP still routes Host=mover → c2 — the committed move
     replayed from the durable directory store; static seeding was skipped.
     (A re-seed bug would route to c1, which evicted the tenant → 404.)

Run S3-first:  `set -a; . ./.env; set +a; python3 scripts/cp_restart_smoke.py`
Build first:   `zig build rewind && zig build rewind-cp && zig build rewind-front`
"""

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

CLUSTERS = f"cluster-1=http://127.0.0.1:{P1};cluster-2=http://127.0.0.1:{P2}"

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
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def spawn_cp_node(cpd, want_needle):
    """Spawn (or restart) the durable CP over the `cpd` store, asserting the
    seed-vs-replay boot decision via `want_needle`. The CP holds the directory
    raft group; this is the process the smoke kills + restarts."""
    return spawn_cp(
        procs, PCP,
        clusters=CLUSTERS,
        hosts=f"{HOST}={TENANT}",
        placement=f"{TENANT}=cluster-1",
        cp_data_dir=cpd,
        move_secret=MOVE_SECRET,
        want_needle=want_needle,
    )


def _curl(args):
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


def kv_put(port, tenant, key, value):
    args = [
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}',
    ]
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


def stop_proc(p):
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()


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

    d1 = f"/tmp/cp-restart-c1-{os.getpid()}"
    d2 = f"/tmp/cp-restart-c2-{os.getpid()}"
    cpd = f"/tmp/cp-restart-cpdata-{os.getpid()}"
    for d in (d1, d2, cpd):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: two rewind clusters + CP (durable directory) + front door")
        spawn_rewind("c1", P1, d1)
        spawn_rewind("c2", P2, d2)
        # First boot: fresh CP store → the CP seeds from static config.
        cp = spawn_cp_node(cpd, want_needle="seeded directory")
        # Stateless front door pointed at the CP; route_cache_ms=0 so the
        # post-move + post-restart reads re-resolve placement every request
        # (the /_system/v2-kv read path is not serve-or-forwarded).
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", route_cache_ms=0)

        # ── A. seed on c1; front routes there pre-move ────────────────
        print("leg A: seed movetenant on cluster-1; front routes → c1")
        check("PUT c1 seed", kv_put(P1, TENANT, KEY, VALUE), 204)
        st, body = kv_get(PF, TENANT, KEY, host=HOST)
        check("GET via front (→c1) status", st, 200)
        check("GET via front (→c1) value", body, VALUE)

        # ── B. the move (directory flip = one committed raft write) ───
        print("leg B: move movetenant cluster-1 → cluster-2")
        st, body = move(PCP, TENANT, "cluster-2")
        check("POST /_control/move status", st, 200)
        print(f"       move says: {body.strip()!r}")

        # ── C. front routes to the new cluster ────────────────────────
        print("leg C: front routes movetenant → cluster-2 (post-move)")
        st, body = kv_get(PF, TENANT, KEY, host=HOST)
        check("GET via front (→c2) status", st, 200)
        check("GET via front (→c2) value", body, VALUE)

        # ── D. HARD-CRASH (kill -9) the front door over the same CP dir ─
        print("leg D: kill -9 the CP (HARD crash — no graceful close,"
              " so recovery is via WAL replay, not durabilize-on-close)")
        os.kill(cp.pid, signal.SIGKILL)
        cp.wait()
        procs.remove(cp)
        # Second boot: the committed move replays from the durable WAL →
        # replay, NOT re-seed (even though REWIND_PLACEMENT still says
        # cluster-1, and the store was never gracefully durabilized).
        spawn_cp_node(cpd, want_needle="skipping static seed")

        # ── E. the recovered front still routes to cluster-2 ──────────
        print("leg E: recovered front STILL routes movetenant → cluster-2")
        st, body = kv_get(PF, TENANT, KEY, host=HOST)
        check("GET via front after restart status", st, 200)
        check("GET via front after restart value", body, VALUE)
    finally:
        stop_all()
        for d in (d1, d2, cpd):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — the committed move survived a front-door restart; the durable "
          "directory replayed instead of re-seeding. ⭐")


if __name__ == "__main__":
    main()
