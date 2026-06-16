#!/usr/bin/env python3
"""CP move-crash recovery via failover (docs/v2-cp-directory-replication.md
Slice 2).

The `moving` hold is durable AND replicated, so if the CP leader crashes
BETWEEN `beginMove` and the terminal `move`/`abortMove`, the tenant is stuck
`moving` on the survivors (which replicated the hold). The newly-promoted
leader reconciles it on a timer: a still-`moving` placement means the flip
never committed, so the SOURCE is authoritative → abort the move (revert to
active) + resume the source.

This uses the realistic HA path — the stuck state survives via raft
REPLICATION to the followers (not disk), so it's independent of single-node
crash durability.

  Induce a real stuck move: point the move's DEST at a BLACK HOLE (a socket
  that accepts but never replies). Issued at the leader, the brief-pause
  orchestration commits `beginMove` (durable + replicated), takes the source
  bundle, then HANGS in the dest attach — blocking ONLY the leader's poll loop.
    - a FOLLOWER reports movetenant `moving:true` (replicated) and 503s it →
      PROVES the stuck state exists + replicated.
    - KILL -9 the leader → a follower is promoted and reconciles the stuck
      move back to the source → survivors route movetenant → cluster-1 (200).

  topology:
    CP node 1 :19040 ┐
    CP node 2 :19043 ├─ directory raft group (consensus :19140/:19141/:19142)
    CP node 3 :19044 ┘
      ├─ cluster-1   → rewind :19041   (source, real)
      └─ cluster-bh  → :19042           (black hole — makes the dest attach hang)

Run S3-first:  `set -a; . ./.env; set +a; python3 scripts/cp_move_recovery_smoke.py`
Build first:   `zig build rewind-worker && zig build rewind-cp`
"""

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, await_ready, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind-worker")

P1 = 19041            # cluster-1 (source, real)
PBH = 19042           # cluster-bh (dest) — black hole
CP_HTTP = [19040, 19043, 19044]
CP_RAFT = [19140, 19141, 19142]

MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
TENANT = "movetenant"
HOST = "mover.localhost"
KEY = "greeting"
VALUE = "hello-from-c1"

CLUSTERS = f"cluster-1=http://127.0.0.1:{P1};cluster-bh=http://127.0.0.1:{PBH}"
PEERS = ",".join(f"127.0.0.1:{p}" for p in CP_RAFT)
PEER_URLS = ";".join(f"http://127.0.0.1:{p}" for p in CP_HTTP)

procs = []
cp_procs = {}  # http_port -> Popen
_bh_sock = None
_bh_conns = []


def black_hole(port):
    global _bh_sock
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)
    _bh_sock = s

    def loop():
        while True:
            try:
                c, _ = s.accept()
                _bh_conns.append(c)
            except OSError:
                return
    threading.Thread(target=loop, daemon=True).start()


# Per-process stdout → FILE, never a PIPE: an un-drained pipe fills (~64KB)
# and BLOCKS the process on its next log write mid-move (the classic
# multi-process-smoke flake). Readiness reads the file.
LOGDIR = os.environ.get("CLAUDE_JOB_DIR", "/tmp")


def _spawn(name, argv, env):
    logf = open(os.path.join(LOGDIR, f"cprec-{name}-{os.getpid()}.log"), "w+")
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
        reconcile_secs=2,
        name=f"cp{node_id}",
        wait=False,
        log_dir=LOGDIR,
    )
    p._http = http
    cp_procs[http] = p
    return p


def _curl(args, timeout=15):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", str(timeout), "--http2-prior-knowledge"] + args,
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


def kv_put(port, key, value):
    return _curl([
        "-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", "Content-Type: application/json",
        "--data", f'{{"tenant":"{TENANT}","key":"{key}","value":"{value}"}}',
    ])[0]


def cp_route(port):
    return _curl([f"http://127.0.0.1:{port}/_cp/route?host={HOST}"])


def cp_cluster(port):
    """Parse a CP node's /_cp/route into (reachable, cluster, moving) — how we
    read a node's replicated projection now that the CP doesn't proxy customer
    traffic."""
    st, body = cp_route(port)
    if st != 200:
        return (False, None, None)
    try:
        d = json.loads(body)
        return (True, d.get("cluster"), d.get("moving"))
    except (ValueError, AttributeError):
        return (False, None, None)


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


def cp_cluster_retry(port, want_cluster, want_moving=False, deadline_s=25):
    """Retry a CP node's /_cp/route until it resolves to `want_cluster` with the
    expected `moving` state (reconciliation takes a couple of timer ticks)."""
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        ok, cl, mv = cp_cluster(port)
        last = (cl, mv)
        if ok and cl == want_cluster and mv == want_moving:
            return last
        time.sleep(0.3)
    return last


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGKILL)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    if _bh_sock:
        try:
            _bh_sock.close()
        except OSError:
            pass


def main():
    for b in (REWIND, CP_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind-worker && zig build rewind-cp`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    d1 = f"/tmp/cp-rec-c1-{pid}"
    cpd = [f"/tmp/cp-rec-cp{i}-{pid}" for i in (1, 2, 3)]
    for d in (d1, *cpd):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: source cluster-1 + black-hole dest + 3-node CP")
        black_hole(PBH)
        spawn_rewind("c1", P1, d1)
        for i in (1, 2, 3):
            launch_cp(i, cpd[i - 1])
        for i in (1, 2, 3):
            await_ready(cp_procs[CP_HTTP[i - 1]], f"cp{i}", "listening on")

        leader = find_leader(CP_HTTP)
        check("directory leader elected", leader is not None, True)
        if leader is None:
            raise SystemExit("no CP leader")
        followers = [p for p in CP_HTTP if p != leader]
        print(f"       leader=:{leader}  followers={[f':{p}' for p in followers]}")

        print("leg A: seed movetenant on cluster-1; CP follower routes → c1")
        check("PUT c1 seed", kv_put(P1, KEY, VALUE), 204)
        check("CP follower routes → cluster-1",
              cp_cluster_retry(followers[0], "cluster-1"), ("cluster-1", False))

        # ── B. start a move to the black hole via the LEADER; it hangs ──────
        print("leg B: move to the black-hole dest via the leader — beginMove "
              "commits + replicates, then the orchestration hangs in dest attach")

        def fire_move():
            _curl([
                "-X", "POST", f"http://127.0.0.1:{leader}/_control/move",
                "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
                "-H", "Content-Type: application/json",
                "--data", f'{{"tenant":"{TENANT}","dest":"cluster-bh"}}',
            ], timeout=40)
        threading.Thread(target=fire_move, daemon=True).start()
        time.sleep(4)  # let beginMove commit + replicate, then hang in attach

        # ── C. a FOLLOWER reports the stuck (replicated) moving state ───────
        print("leg C: a FOLLOWER sees movetenant moving:true (replicated stuck state)")
        ok, cl, mv = cp_cluster(followers[0])
        check("follower /_cp/route reachable", ok, True)
        check("follower sees moving:true", mv, True)

        # ── D. KILL -9 the leader; a survivor reconciles the stuck move ─────
        print("leg D: kill -9 the leader; a promoted survivor reconciles the "
              "stuck move back to the source")
        os.kill(cp_procs[leader].pid, signal.SIGKILL)
        cp_procs[leader].wait()
        del cp_procs[leader]
        new_leader = find_leader(followers)
        check("a survivor promoted to leader", new_leader is not None, True)
        for p in followers:
            check(f"survivor :{p} routes movetenant → cluster-1 (recovered)",
                  cp_cluster_retry(p, "cluster-1"), ("cluster-1", False))
    finally:
        stop_all()
        for d in (d1, *cpd):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — a leader crash mid-move leaves a replicated stuck `moving`; "
          "the promoted leader reconciles it back to the source. ⭐")


if __name__ == "__main__":
    main()
