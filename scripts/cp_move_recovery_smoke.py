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
Build first:   `zig build rewind && zig build rewind-front`
"""

import os
import signal
import socket
import subprocess
import sys
import threading
import time

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")
FRONT = os.path.join(BINDIR, "rewind-front")

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
    env["REWIND_CP_RECONCILE_SECS"] = "2"
    p = subprocess.Popen(
        [FRONT, str(http)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
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


def front_get(port):
    return _curl([
        f"http://127.0.0.1:{port}/_system/v2-kv?tenant={TENANT}&key={KEY}",
        "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
        "-H", f"Host: {HOST}",
    ])


def cp_route(port):
    return _curl([f"http://127.0.0.1:{port}/_cp/route?host={HOST}"])


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


def front_get_retry(port, want, deadline_s=25):
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        last = front_get(port)
        if last == want:
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
    for b in (REWIND, FRONT):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind && zig build rewind-front`")
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
            _await_line(cp_procs[CP_HTTP[i - 1]], f"cp{i}", "listening on")

        leader = find_leader(CP_HTTP)
        check("directory leader elected", leader is not None, True)
        if leader is None:
            raise SystemExit("no CP leader")
        followers = [p for p in CP_HTTP if p != leader]
        print(f"       leader=:{leader}  followers={[f':{p}' for p in followers]}")

        print("leg A: seed movetenant on cluster-1; CP routes → c1")
        check("PUT c1 seed", kv_put(P1, KEY, VALUE), 204)
        check("front routes → c1", front_get_retry(followers[0], (200, VALUE)), (200, VALUE))

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
        print("leg C: a FOLLOWER sees movetenant moving:true (replicated) + 503s it")
        st, body = cp_route(followers[0])
        check("follower /_cp/route status", st, 200)
        check("follower sees moving:true", '"moving":true' in body, True)
        check("follower 503s the held tenant", front_get(followers[0])[0], 503)

        # ── D. KILL -9 the leader; a survivor reconciles the stuck move ─────
        print("leg D: kill -9 the leader; a promoted survivor reconciles the "
              "stuck move back to the source")
        os.kill(cp_procs[leader].pid, signal.SIGKILL)
        cp_procs[leader].wait()
        del cp_procs[leader]
        new_leader = find_leader(followers)
        check("a survivor promoted to leader", new_leader is not None, True)
        for p in followers:
            check(f"survivor :{p} routes movetenant → c1 (recovered)",
                  front_get_retry(p, (200, VALUE)), (200, VALUE))
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
