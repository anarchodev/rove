#!/usr/bin/env python3
"""V2 Phase-5 exit smoke ⭐ (docs/v2-build-order.md §Phase 5,
docs/v2-phase5-multinode.md §5d/5e).

Proves multi-node HA + the move fan-out end to end:

    rewind-cp  :18105   (move orchestrator + routing directory)
    front door :18100   (stateless proxy; leader-aware forward to a cluster)
      ├─ cluster-1 → rewind :18101            (single-node source)
      └─ cluster-2 → rewind :18102/03/04      (3-node HA destination)
                       raft peers :18112/13/14

Legs:
  A.  seed movetenant on the single-node cluster-1, read it back.
  B.  move cluster-1 → cluster-2: the front door dumps the source leader,
      fans `v2-attach` to ALL THREE destination nodes (forming the group
      across the cluster), waits for the new group to elect a leader, flips
      the routing directory, and evicts the source.
  C.  read-back via the front door (→ cluster-2, leader-aware) → value intact.
  D.  source cluster-1 released the tenant (404 direct).
  E.  WRITE a new value through the front door → routed to the cluster-2
      leader (a follower 503s, the front door retries) → 204; read it back.
  F.  ⭐ FULL-HA failover: find + KILL the cluster-2 LEADER. A surviving
      follower is promoted and serves the data it replicated (the unified
      follower-apply store): read-back still returns the latest value, and a
      fresh write commits on the surviving 2-node quorum.

The tenant store is seeded/read/written through the cluster-internal move
surface (`/_system/v2-kv`, gated by REWIND_MOVE_SECRET): a PUT writes
through the leader's propose→commit path, a GET reads the kvexp store.

Requires S3 env (there is no fs BlobBackend) — source the repo `.env` first:
  `set -a; . ./.env; set +a; python3 scripts/three_node_smoke.py`

Build first:  `zig build rewind && zig build rewind-cp && zig build rewind-front`
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

PF = int(os.environ.get("FRONT_PORT", "18100"))
PCP = int(os.environ.get("CP_PORT", "18105"))          # single-node CP
P1 = int(os.environ.get("C1_PORT", "18101"))           # cluster-1 (source)
P2 = [18102, 18103, 18104]                             # cluster-2 HTTP ports
RP2 = [18112, 18113, 18114]                            # cluster-2 raft peer ports

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "movetenant"
HOST = "mover.localhost"
KEY = "greeting"
VALUE = "hello-from-c1"
VALUE2 = "written-on-3node"
VALUE3 = "after-leader-kill"

procs = []


def spawn_rewind(name, port, data_dir, multinode=None):
    """multinode = (node_id, voters_csv, peers_csv) or None for single-node."""
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    if multinode:
        node_id, voters, peers = multinode
        env["REWIND_NODE_ID"] = str(node_id)
        env["REWIND_VOTERS"] = voters
        env["REWIND_PEERS"] = peers
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    p._name = name
    procs.append(p)
    await_line(p, name, "listening on")
    return p


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


def kv_put(port, key, value, host=None):
    args = [
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{TENANT}","key":"{key}","value":"{value}"}}',
    ]
    if host:
        args += ["-H", f"Host: {host}"]
    return _curl(args)[0]


def kv_get(port, key, host=None):
    args = [
        f"http://127.0.0.1:{port}/_system/v2-kv?tenant={TENANT}&key={key}",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
    ]
    if host:
        args += ["-H", f"Host: {host}"]
    return _curl(args)


def v2_leader(port):
    """200 if this node leads movetenant's group, 503 follower, 404 absent."""
    return _curl([
        f"http://127.0.0.1:{port}/_system/v2-leader?tenant={TENANT}",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
    ])[0]


def move(cp_port, dest):
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{cp_port}/_control/move",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{TENANT}","dest":"{dest}"}}',
    ])


def front_put_retry(key, value, deadline_s=15):
    """PUT via the front door, retrying while the cluster (re)elects a leader
    (a write to a follower 503s; an unreachable killed node also surfaces as
    non-204)."""
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        last = kv_put(PF, key, value, host=HOST)
        if last == 204:
            return 204
        time.sleep(0.3)
    return last


def front_get_retry(key, want, deadline_s=15):
    deadline = time.time() + deadline_s
    last = (0, "")
    while time.time() < deadline:
        last = kv_get(PF, key, host=HOST)
        if last[0] == 200 and last[1] == want:
            return last
        time.sleep(0.3)
    return last


def find_leader_port(deadline_s=15):
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        for p in P2:
            if v2_leader(p) == 200:
                return p
        time.sleep(0.3)
    return None


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p._hung_on_sigterm = True
            p.kill()
            p.wait()
    # A handled SIGTERM exits 0; anything else (SIGABRT = a Zig panic,
    # SIGSEGV, a hang escalated to SIGKILL) is a teardown bug — surface it.
    for p in procs:
        if getattr(p, "_hung_on_sigterm", False):
            print(f"TEARDOWN: pid {p.pid} HUNG on SIGTERM (10s) — killed")
        if p.returncode != 0 and not getattr(p, "_expected_kill", False):
            tail = p.stdout.read() if p.stdout else ""
            print(f"TEARDOWN: pid {p.pid} exited rc={p.returncode}")
            print("\n".join("  | " + l for l in tail.splitlines()[-40:]))


def main():
    for b in (REWIND, CP_BIN, FRONT_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind && zig build rewind-cp && zig build rewind-front`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    d1 = f"/tmp/three-node-c1-{pid}"
    dnodes = [f"/tmp/three-node-c2n{i}-{pid}" for i in range(3)]
    dcp = f"/tmp/three-node-cp-{pid}"
    for d in (d1, *dnodes, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    peers_csv = ",".join(f"127.0.0.1:{rp}" for rp in RP2)
    leader_port = None
    try:
        print("boot: single-node cluster-1 + 3-node cluster-2 + CP + front door")
        spawn_rewind("c1", P1, d1)  # single-node source
        for i in range(3):
            spawn_rewind(f"c2n{i+1}", P2[i], dnodes[i],
                         multinode=(i + 1, "1,2,3", peers_csv))
        c2_nodes = ",".join(f"http://127.0.0.1:{p}" for p in P2)
        spawn_cp(
            procs, PCP,
            clusters=f"cluster-1=http://127.0.0.1:{P1};cluster-2={c2_nodes}",
            hosts=f"{HOST}={TENANT}",
            placement=f"{TENANT}=cluster-1",
            cp_data_dir=dcp,
            move_secret=MOVE_SECRET,
        )
        # route_cache_ms=0: the /_system/v2-kv reads through the front are not a
        # serve-or-forward path, so re-resolve every request (post-move flip +
        # post-leader-kill node set are then seen immediately).
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", route_cache_ms=0)

        # ── A. seed on the single-node source ─────────────────────────
        print("leg A: seed movetenant on cluster-1 (single node)")
        check("PUT c1 seed", kv_put(P1, KEY, VALUE), 204)
        st, body = kv_get(P1, KEY)
        check("GET c1 read-back status", st, 200)
        check("GET c1 read-back value", body, VALUE)
        st, body = kv_get(PF, KEY, host=HOST)
        check("GET via front (→c1)", body, VALUE)

        # ── B. move onto the 3-node destination ───────────────────────
        print("leg B: move cluster-1 → cluster-2 (3-node dest, attach fan-out)")
        st, body = move(PCP, "cluster-2")
        check("POST /_control/move status", st, 200)
        print(f"       move says: {body.strip()!r}")

        # ── C. served by the 3-node cluster, data intact ──────────────
        print("leg C: cluster-2 serves the tenant (leader-aware via front)")
        st, body = front_get_retry(KEY, VALUE)
        check("GET via front (→c2)", (st, body), (200, VALUE))

        # all three nodes hold the replicated seed (follower stores synced)
        for i, p in enumerate(P2):
            st, body = kv_get(p, KEY)
            check(f"GET c2n{i+1} direct (replicated)", (st, body), (200, VALUE))

        # ── D. source released ────────────────────────────────────────
        print("leg D: source cluster-1 released the tenant")
        st, _ = kv_get(P1, KEY)
        check("GET c1 after move (evicted)", st, 404)

        # ── E. write a new value through the 3-node cluster ───────────
        print("leg E: write via front door → routed to the cluster-2 leader")
        check("PUT via front (→c2 leader)", front_put_retry(KEY, VALUE2), 204)
        st, body = front_get_retry(KEY, VALUE2)
        check("GET via front (new value)", (st, body), (200, VALUE2))

        # ── F. ⭐ FULL-HA: kill the leader, a follower promotes + serves ─
        print("leg F: ⭐ kill the cluster-2 LEADER; a follower promotes + serves")
        leader_port = find_leader_port()
        check("found a cluster-2 leader", leader_port is not None, True)
        if leader_port is not None:
            print(f"       leader is :{leader_port} — killing it")
            for p in procs:
                if getattr(p, "_name", "").startswith("c2") and p.args[2] == str(leader_port):
                    p._expected_kill = True
                    p.send_signal(signal.SIGKILL)
                    p.wait()
            # data survived: a promoted survivor serves the latest value
            st, body = front_get_retry(KEY, VALUE2, deadline_s=20)
            check("GET via front after leader kill", (st, body), (200, VALUE2))
            # a fresh write commits on the surviving 2-node quorum
            check("PUT via front post-failover", front_put_retry(KEY, VALUE3, deadline_s=20), 204)
            st, body = front_get_retry(KEY, VALUE3, deadline_s=20)
            check("GET via front (post-failover value)", (st, body), (200, VALUE3))
    finally:
        stop_all()
        for d in (d1, *dnodes, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — 3-node HA: move fan-out formed the group, leader-aware "
          "routing served it, and a promoted follower survived a leader kill "
          "with data intact. ⭐")


if __name__ == "__main__":
    main()
