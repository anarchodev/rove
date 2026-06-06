#!/usr/bin/env python3
"""3-node control-plane HA (docs/v2-cp-directory-replication.md Slice 2).

The control plane is now a 3-node cluster: the routing directory is one raft
group spanning three `rewind-front` nodes. This proves the Slice-2 exit:

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
Build first:   `zig build rewind && zig build rewind-front`
"""

import os
import signal
import subprocess
import sys
import time

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")
FRONT = os.path.join(BINDIR, "rewind-front")

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


def spawn_rewind(name, port, data_dir):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    p = subprocess.Popen(
        [REWIND, data_dir, str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    procs.append(p)
    _await_line(p, name, "listening on")
    return p


def launch_cp(node_id, data_dir):
    """Launch a CP front-door node (do NOT await — all 3 must be up before any
    can elect / seed)."""
    http = CP_HTTP[node_id - 1]
    env = dict(os.environ)
    env["REWIND_CLUSTERS"] = CLUSTERS
    env["REWIND_HOSTS"] = f"{HOST}={TENANT}"
    env["REWIND_PLACEMENT"] = f"{TENANT}=cluster-1"
    env["REWIND_MOVE_SECRET"] = MOVE_SECRET
    env["REWIND_CP_DATA_DIR"] = data_dir
    env["REWIND_CP_NODE_ID"] = str(node_id)
    env["REWIND_CP_VOTERS"] = "1,2,3"
    env["REWIND_CP_PEERS"] = PEERS
    env["REWIND_CP_PEER_URLS"] = PEER_URLS
    p = subprocess.Popen(
        [FRONT, str(http)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    p._name = f"cp{node_id}"
    p._http = http
    procs.append(p)
    cp_procs[http] = p
    return p


def _await_line(p, name, needle, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            if p.poll() is not None:
                raise SystemExit(f"{name} exited early: rc={p.returncode}")
            continue
        sys.stdout.write(f"  [{name}] " + line)
        if needle in line:
            return
    raise SystemExit(f"{name} did not reach '{needle}' within {timeout}s")


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
    return _curl([
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}',
    ])[0]


def front_get(port, host=HOST):
    return _curl([
        f"http://127.0.0.1:{port}/_system/v2-kv?tenant={TENANT}&key={KEY}",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", f"Host: {host}",
    ])


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


def front_get_retry(port, want_status, want_body, deadline_s=20):
    """Reads through the front door can momentarily 503 mid-move / mid-election;
    retry until the expected (status, body) or the deadline."""
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        last = front_get(port)
        if last == (want_status, want_body):
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
    for b in (REWIND, FRONT):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind && zig build rewind-front`")
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
            _await_line(cp_procs[CP_HTTP[i - 1]], f"cp{i}", "listening on")

        # ── A. directory leader elected ──────────────────────────────
        print("leg A: the directory group elects a leader")
        leader = find_leader(CP_HTTP)
        check("a CP node leads the directory", leader is not None, True)
        if leader is None:
            raise SystemExit("no CP leader elected")
        followers = [p for p in CP_HTTP if p != leader]
        print(f"       leader=:{leader}  followers={[f':{p}' for p in followers]}")

        # ── B. seed on cluster-1; EVERY CP node resolves it ──────────
        print("leg B: seed movetenant on cluster-1; every CP node routes → c1")
        check("PUT c1 seed", kv_put(P1, TENANT, KEY, VALUE), 204)
        for p in CP_HTTP:
            st, body = front_get_retry(p, 200, VALUE)
            check(f"CP :{p} routes → c1 (replicated projection)", (st, body), (200, VALUE))

        # ── C. move via a FOLLOWER (forwarded to the leader) ─────────
        print("leg C: move c1 → c2 via a FOLLOWER CP node (forwarded to leader)")
        st, body = move(followers[0], "cluster-2")
        check("POST /_control/move via follower status", st, 200)
        print(f"       move says: {body.strip()!r}")

        # ── D. every CP node now routes to c2 ────────────────────────
        print("leg D: every CP node routes movetenant → cluster-2 (post-move)")
        for p in CP_HTTP:
            st, body = front_get_retry(p, 200, VALUE)
            check(f"CP :{p} routes → c2", (st, body), (200, VALUE))

        # ── E. kill the leader; CP survives + still routes ───────────
        print("leg E: KILL the directory leader; a survivor still serves the directory")
        stop_proc(cp_procs[leader])
        del cp_procs[leader]
        survivors = [p for p in CP_HTTP if p != leader]
        new_leader = find_leader(survivors)
        check("a survivor was promoted to directory leader", new_leader is not None, True)
        for p in survivors:
            st, body = front_get_retry(p, 200, VALUE)
            check(f"survivor CP :{p} still routes → c2 (HA)", (st, body), (200, VALUE))

        # ── F. a fresh move still commits on the surviving quorum ────
        print("leg F: a move BACK to c1 still commits on the surviving CP quorum")
        st, body = move(survivors[0], "cluster-1")
        check("post-failover move status", st, 200)
        for p in survivors:
            st, body = front_get_retry(p, 200, VALUE)
            check(f"survivor CP :{p} routes → c1 after re-move", (st, body), (200, VALUE))
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
