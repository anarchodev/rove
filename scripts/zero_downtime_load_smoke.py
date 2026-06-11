#!/usr/bin/env python3
"""V2 Phase-7 EXIT smoke ⭐ — move under continuous load, zero failed requests
(v2-build-order §Phase 7; project_v2_zero_downtime_move memory).

A concurrent writer hammers a tenant with distinct keys while the tenant is
moved A→B with a single `/_control/move-live`. The writer FOLLOWS the tenant:
each write asks the control plane (`/_cp/route?host=`) who currently owns the
host and writes to that cluster, retrying transients (a brief 409 in the
flip→evict window). The exit criteria:

  * ZERO failed requests — every write eventually 204s (retries allowed).
  * ZERO lost writes — after the move, EVERY key the writer wrote is present
    on the NEW owner (B) with its exact value, because a write landed on the
    eventual owner via one of: the snapshot (pre-forward-begin), a synchronous
    forward (during the overlap), or a direct write (post-flip).

    rewind-cp  :19030   (move-live orchestrator + CP directory)
    cluster-A  :19031   (source)
    cluster-B  :19032   (destination)

Requires S3 env — `set -a; . ./.env; set +a` first.
Build:  `zig build rewind && zig build rewind-cp`
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")

PCP, PA, PB = 19030, 19031, 19032
SECRET = "rewindmovesecretpadding0123456789abcdef0"
A_URL, B_URL = f"http://127.0.0.1:{PA}", f"http://127.0.0.1:{PB}"
HOST = "load.localhost"
TENANT = "loadtenant"

procs = []


LOGDIR = os.environ.get("CLAUDE_JOB_DIR", "/tmp")


def _spawn(name, argv, env):
    logf = open(os.path.join(LOGDIR, f"zdl-{name}-{os.getpid()}.log"), "w+")
    p = subprocess.Popen(argv, stdout=logf, stderr=subprocess.STDOUT, env=env)
    p._logf = logf
    procs.append(p)
    _await(name, logf, "listening on")
    return p


def spawn_rewind(name, port, data_dir, admin_domain):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = admin_domain
    env["REWIND_MOVE_SECRET"] = SECRET
    return _spawn(name, [REWIND, data_dir, str(port)], env)


def _await(name, logf, needle):
    deadline = time.time() + 15
    while time.time() < deadline:
        logf.seek(0)
        if needle in logf.read():
            return
        time.sleep(0.1)
    raise SystemExit(f"{name} never reached '{needle}'")


def _curl(args):
    out = subprocess.run(["curl", "-s", "-w", "\n%{http_code}", "-m", "6",
                          "--http2-prior-knowledge"] + args, capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    if nl < 0:
        return (0, out)
    try:
        return (int(out[nl + 1:].strip() or 0), out[:nl])
    except ValueError:
        return (0, out[:nl])


def hdr():
    return ["-H", f"X-Rewind-Move-Secret: {SECRET}"]


def cp_owner_port():
    """Ask the CP who owns HOST; return the (single-node) owner's port, or None."""
    code, body = _curl([f"http://127.0.0.1:{PCP}/_cp/route?host={HOST}", *hdr()])
    if code != 200:
        return None
    try:
        node0 = json.loads(body)["nodes"][0]          # http://127.0.0.1:PORT
        return int(node0.rsplit(":", 1)[1])
    except (ValueError, KeyError, IndexError):
        return None


def kv_put(port, key, value):
    return _curl(["-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"{TENANT}","key":"{key}","value":"{value}"}}'])[0]


def kv_get(port, key):
    return _curl([f"http://127.0.0.1:{port}/_system/v2-kv?tenant={TENANT}&key={key}", *hdr()])


def move_live(dest):
    return _curl(["-X", "POST", f"http://127.0.0.1:{PCP}/_control/move-live", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"{TENANT}","dest":"{dest}"}}'])


def writer_loop(stop_evt, written, failures):
    """Write distinct keys, following the CP owner, retrying transients."""
    i = 0
    while not stop_evt.is_set():
        key, val = f"k{i}", f"v{i}"
        ok = False
        for _ in range(40):                       # retry transients (flip→evict window)
            port = cp_owner_port()
            if port is None:
                time.sleep(0.01)
                continue
            if kv_put(port, key, val) == 204:
                ok = True
                break
            time.sleep(0.01)
        if ok:
            written[key] = val
        else:
            failures.append(key)
        i += 1
        if i % 20 == 0:
            sys.stderr.write(f"    [writer] {i} writes ({len(failures)} failed)\n")
        time.sleep(0.03)
    return


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()
    # A handled SIGTERM exits 0; anything else (SIGABRT = a Zig panic,
    # SIGSEGV, nonzero) is a teardown bug — drain and surface it.
    for p in procs:
        if p.returncode != 0:
            tail = p.stdout.read() if p.stdout else ""
            print(f"TEARDOWN: pid {p.pid} exited rc={p.returncode}")
            print("\n".join("  | " + l for l in tail.splitlines()[-40:]))


def main():
    for b in (REWIND, CP_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} missing — `zig build rewind && zig build rewind-cp`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    da, db = f"/tmp/zdl-a-{pid}", f"/tmp/zdl-b-{pid}"
    dcp = f"/tmp/zdl-cp-{pid}"
    for d in (da, db, dcp):
        subprocess.run(["rm", "-rf", d])

    fails = []

    def check(label, cond, detail=""):
        print(f"  {'ok  ' if cond else 'FAIL'} {label}  {detail}")
        if not cond:
            fails.append(label)

    try:
        print("boot: CP + cluster-A (source) + cluster-B (dest)")
        spawn_cp(
            procs, PCP,
            clusters=f"cluster-A={A_URL};cluster-B={B_URL}",
            hosts=f"{HOST}={TENANT}",
            placement=f"{TENANT}=cluster-A",
            cp_data_dir=dcp,
            move_secret=SECRET,
            log_dir=LOGDIR,
        )
        spawn_rewind("A", PA, da, "a.localhost")
        spawn_rewind("B", PB, db, "b.localhost")

        # Seed so the tenant is active on A before the writer + move.
        check("seed write to A", kv_put(PA, "seed", "seedval") == 204, True)

        print("starting concurrent writer (follows the CP owner, retries transients)")
        stop_evt = threading.Event()
        written, w_failures = {}, []
        th = threading.Thread(target=writer_loop, args=(stop_evt, written, w_failures))
        th.start()

        time.sleep(1.0)                            # writer hammers A
        print("MOVE under load: POST /_control/move-live A → B")
        _t0 = time.time()
        st, msg = move_live("cluster-B")
        print(f"       move-live status={st} in {time.time()-_t0:.1f}s: {msg.strip()!r}")
        time.sleep(1.0)                            # writer hammers B

        stop_evt.set()
        th.join()
        print(f"writer issued {len(written) + len(w_failures)} writes "
              f"({len(written)} ok, {len(w_failures)} failed)")

        # ── exit checks ───────────────────────────────────────────────
        check("move-live succeeded", st == 200, f"status={st}")
        check("ZERO failed requests", len(w_failures) == 0,
              f"failed={w_failures[:5]}")
        check("writer made progress (>20 writes)", len(written) > 20,
              f"n={len(written)}")

        # every acknowledged write is present on the NEW owner with its value
        owner = cp_owner_port()
        check("owner is now cluster-B", owner == PB, f"owner_port={owner}")
        lost, bad = [], []
        for key, val in {"seed": "seedval", **written}.items():
            code, body = kv_get(PB, key)
            if code != 200:
                lost.append(key)
            elif body != val:
                bad.append((key, body, val))
        check("ZERO lost writes on the new owner", not lost, f"lost={lost[:5]}")
        check("no value mismatches", not bad, f"bad={bad[:5]}")
        check("source A evicted", kv_get(PA, "seed")[0] in (404, 409), True)
    finally:
        stop_all()
        for d in (da, db, dcp):
            subprocess.run(["rm", "-rf", d])

    if fails:
        print("\nFAIL: " + ", ".join(fails))
        sys.exit(1)
    print("\nPASS ⭐ — moved a tenant under continuous load with ZERO failed "
          "requests and ZERO lost writes; the source served throughout. "
          "(Phase 7 exit)")


if __name__ == "__main__":
    main()
