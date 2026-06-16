#!/usr/bin/env python3
"""3-node control-plane HA (docs/v2-cp-directory-replication.md Slice 2).

The control plane is now a 3-node cluster: the routing directory is one raft
group spanning three `rewind-cp` nodes. This proves the Slice-2 exit:

  - a directory write replicates to all 3 CP nodes (every node — leader AND
    follower — resolves the placement from its own apply-driven projection);
  - an operator can target ANY CP node for a move: a follower forwards the
    `/_control/move` to the directory leader, which commits the flip;
  - the CP survives a node failure: kill the directory leader, a survivor is
    promoted, and the directory still reads (and a fresh move still commits).

  topology:
    CP node 1 :19090  ┐
    CP node 2 :19093  ├─ directory raft group (consensus :19190/:19191/:19192)
    CP node 3 :19094  ┘
      ├─ cluster-1 → rewind :19091   (movetenant starts here)
      └─ cluster-2 → rewind :19092   (movetenant ends here)

Run S3-first:  `set -a; . ./.env; set +a; python3 scripts/cp_ha_smoke.py`
Build first:   `zig build rewind-worker && zig build rewind-cp`
"""

import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, await_ready, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind-worker")

# DP cluster HTTP ports.
P1 = int(os.environ.get("C1_PORT", "19091"))
P2 = int(os.environ.get("C2_PORT", "19092"))
# CP node HTTP ports + consensus ports (distinct from HTTP).
CP_HTTP = [19090, 19093, 19094]
CP_RAFT = [19190, 19191, 19192]

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "movetenant"
HOST = "mover.localhost"
KEY = "greeting"
VALUE = "hello-from-c1"

CLUSTERS = f"cluster-1=http://127.0.0.1:{P1};cluster-2=http://127.0.0.1:{P2}"
PEERS = ",".join(f"127.0.0.1:{p}" for p in CP_RAFT)
PEER_URLS = ";".join(f"http://127.0.0.1:{p}" for p in CP_HTTP)

procs = []
cp_procs = {}  # http_port -> Popen


# Per-process stdout goes to a FILE, never a PIPE: these processes log
# steadily (move steps, election, reconcile), and an un-drained pipe fills
# (~64KB) and BLOCKS the process on its next log write mid-move — the classic
# multi-process-smoke flake (project_v2_zero_downtime_move memory). Readiness
# reads the file.
LOGDIR = os.environ.get("CLAUDE_JOB_DIR", "/tmp")


def _spawn(name, argv, env):
    logf = open(os.path.join(LOGDIR, f"cpha-{name}-{os.getpid()}.log"), "w+")
    p = subprocess.Popen(argv, stdout=logf, stderr=subprocess.STDOUT, env=env)
    p._logf = logf
    p._name = name
    procs.append(p)
    return p


def spawn_rewind(name, port, data_dir):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_ROOT_TOKEN"] = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects unset/default
    p = _spawn(name, [REWIND, data_dir, str(port)], env)
    await_ready(p, name, "listening on")
    return p


def launch_cp(node_id, data_dir):
    """Launch a CP node (do NOT await — all 3 must be up before any can elect /
    seed). File-logged via the shared helper's `log_dir` transport."""
    http = CP_HTTP[node_id - 1]
    p = spawn_cp(
        procs, http,
        clusters=CLUSTERS,
        hosts=f"{HOST}={TENANT}",
        placement=f"{TENANT}=cluster-1",
        cp_data_dir=data_dir,
        move_secret=MOVE_SECRET,
        node_id=node_id,
        voters="1,2,3",
        peers=PEERS,
        peer_urls=PEER_URLS,
        name=f"cp{node_id}",
        wait=False,
        log_dir=LOGDIR,
    )
    p._http = http
    cp_procs[http] = p
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


def kv_put(port, tenant, key, value):
    """Seed a tenant store on a DP worker (creates the group/instance) so the
    move legs have a real tenant to bundle/migrate."""
    return _curl([
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}',
    ])[0]


def cp_route(port, host=HOST):
    """Resolve `host` through a CP node's /_cp/route → the cluster id it
    currently maps to (per THAT node's replicated directory projection), or
    None on non-200 / unparseable. This is how we read a CP node's projection
    now that the CP no longer proxies customer traffic."""
    st, body = _curl([f"http://127.0.0.1:{port}/_cp/route?host={host}"])
    if st != 200:
        return None
    try:
        return json.loads(body).get("cluster")
    except (ValueError, AttributeError):
        return None


def cp_is_leader(port):
    return _curl([f"http://127.0.0.1:{port}/_cp/leader"])[0] == 200


def find_leader(ports, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for p in ports:
            if cp_is_leader(p):
                return p
        time.sleep(0.3)
    return None


def move(front_port, dest):
    return _curl([
        "-X", "POST", f"http://127.0.0.1:{front_port}/_control/move",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{TENANT}","dest":"{dest}"}}',
    ])


def cp_route_retry(port, want_cluster, deadline_s=20):
    """A CP node's projection can momentarily lag mid-move / mid-election;
    retry /_cp/route until it resolves to `want_cluster` or the deadline."""
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        last = cp_route(port)
        if last == want_cluster:
            return last
        time.sleep(0.3)
    return last


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
    for b in (REWIND, CP_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind-worker && zig build rewind-cp`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    d1 = f"/tmp/cp-ha-c1-{pid}"
    d2 = f"/tmp/cp-ha-c2-{pid}"
    cpd = [f"/tmp/cp-ha-cp{i}-{pid}" for i in (1, 2, 3)]
    for d in (d1, d2, *cpd):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want, predicate="eq"):
        ok = (got == want) if predicate == "eq" else (got != want)
        sign = "==" if predicate == "eq" else "!="
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} ({sign} {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: 2 DP clusters + 3-node CP (directory raft group)")
        spawn_rewind("c1", P1, d1)
        spawn_rewind("c2", P2, d2)
        # Launch all 3 CP nodes, THEN await — they must all be up to elect.
        for i in (1, 2, 3):
            launch_cp(i, cpd[i - 1])
        for i in (1, 2, 3):
            await_ready(cp_procs[CP_HTTP[i - 1]], f"cp{i}", "listening on")

        # ── A. directory leader elected ──────────────────────────────
        print("leg A: the directory group elects a leader")
        leader = find_leader(CP_HTTP)
        check("a CP node leads the directory", leader is not None, True)
        if leader is None:
            raise SystemExit("no CP leader elected")
        followers = [p for p in CP_HTTP if p != leader]
        print(f"       leader=:{leader}  followers={[f':{p}' for p in followers]}")

        # ── B. seed the tenant on c1; EVERY CP node resolves it ──────
        print("leg B: seed movetenant on cluster-1; every CP node resolves → cluster-1")
        check("PUT c1 seed", kv_put(P1, TENANT, KEY, VALUE), 204)
        for p in CP_HTTP:
            check(f"CP :{p} routes → cluster-1 (replicated projection)",
                  cp_route_retry(p, "cluster-1"), "cluster-1")

        # ── C. move via a FOLLOWER (forwarded to the leader) ─────────
        print("leg C: move c1 → c2 via a FOLLOWER CP node (forwarded to leader)")
        st, body = move(followers[0], "cluster-2")
        check("POST /_control/move via follower status", st, 200)
        print(f"       move says: {body.strip()!r}")

        # ── D. every CP node now routes to c2 ────────────────────────
        print("leg D: every CP node routes movetenant → cluster-2 (post-move)")
        for p in CP_HTTP:
            check(f"CP :{p} routes → cluster-2", cp_route_retry(p, "cluster-2"), "cluster-2")

        # ── E. kill the leader; CP survives + still routes ───────────
        print("leg E: KILL the directory leader; a survivor still serves the directory")
        stop_proc(cp_procs[leader])
        del cp_procs[leader]
        survivors = [p for p in CP_HTTP if p != leader]
        new_leader = find_leader(survivors)
        check("a survivor was promoted to directory leader", new_leader is not None, True)
        for p in survivors:
            check(f"survivor CP :{p} still routes → cluster-2 (HA)",
                  cp_route_retry(p, "cluster-2"), "cluster-2")

        # ── F. a fresh move still commits on the surviving quorum ────
        print("leg F: a move BACK to c1 still commits on the surviving CP quorum")
        st, body = move(survivors[0], "cluster-1")
        check("post-failover move status", st, 200)
        for p in survivors:
            check(f"survivor CP :{p} routes → cluster-1 after re-move",
                  cp_route_retry(p, "cluster-1"), "cluster-1")
    finally:
        stop_all()
        for d in (d1, d2, *cpd):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — 3-node CP: directory replicates to every node, any node accepts "
          "a move (follower→leader forward), and the directory survives a leader "
          "failure. ⭐")


if __name__ == "__main__":
    main()
