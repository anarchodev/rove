#!/usr/bin/env python3
"""V2 Phase-7 slice (c) smoke — zero-downtime move (project_v2_zero_downtime_move
memory; docs/v2-build-order.md §Phase 7).

Proves the cutover keeps the source serving (no quiesce) and loses no write:

    front door :19020   (move-live orchestrator + directory)
    cluster-A  :19021   (source)
    cluster-B  :19022   (destination)

Leg 1 — insert-if-absent correctness (the heart of the gap-free design),
driven step by step so a write can land AFTER the snapshot:
  A. seed key_cold=v1, key_hot=OLD on A.
  B. empty-attach B (form group + instance, no data) + await its leader.
  C. forward-begin on A (→ B); SNAPSHOT A (captures key_hot=OLD).
  D. write key_hot=NEW on A → forwarded synchronously → B has key_hot=NEW.
  E. load-merge the snapshot into B insert-if-absent → key_hot stays NEW
     (the older snapshot value is dropped), key_cold is filled (v1).
  F. A still serves key_hot=NEW throughout (no quiesce).

Leg 2 — the move-live orchestration end to end:
  one `POST /_control/move-live` moves a tenant A→B with the source serving
  the whole time; afterward B serves the data and A is evicted.

Requires S3 env — `set -a; . ./.env; set +a` first.
Build:  `zig build rewind && zig build rewind-front`
"""

import os
import signal
import subprocess
import sys
import time

BINDIR = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind")
FRONT = os.path.join(BINDIR, "rewind-front")

PF = 19020
PA = 19021
PB = 19022
SECRET = "rewindmovesecretpadding0123456789abcdef0"
A_URL = f"http://127.0.0.1:{PA}"
B_URL = f"http://127.0.0.1:{PB}"

procs = []


def spawn_rewind(name, port, data_dir, admin_domain):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = admin_domain
    env["REWIND_MOVE_SECRET"] = SECRET
    p = subprocess.Popen([REWIND, data_dir, str(port)], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, env=env)
    procs.append(p)
    _await(p, name, "listening on")
    return p


def spawn_front():
    env = dict(os.environ)
    env["REWIND_CLUSTERS"] = f"cluster-A={A_URL};cluster-B={B_URL}"
    env["REWIND_HOSTS"] = "live.localhost=livetenant"
    env["REWIND_PLACEMENT"] = "livetenant=cluster-A"
    env["REWIND_MOVE_SECRET"] = SECRET
    env["REWIND_CP_DATA_DIR"] = f"/tmp/zdm-cp-{os.getpid()}"
    p = subprocess.Popen([FRONT, str(PF)], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, env=env)
    procs.append(p)
    _await(p, "front", "listening on")
    return p


def _await(p, name, needle):
    deadline = time.time() + 15
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            if p.poll() is not None:
                raise SystemExit(f"{name} exited early rc={p.returncode}")
            continue
        sys.stdout.write(f"  [{name}] " + line)
        if needle in line:
            return
    raise SystemExit(f"{name} never reached '{needle}'")


def hdr():
    return ["-H", f"X-Rewind-Move-Secret: {SECRET}"]


def kv_put(port, tenant, key, value):
    return _curl(["-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}'])[0]


def kv_get(port, tenant, key):
    return _curl([f"http://127.0.0.1:{port}/_system/v2-kv?tenant={tenant}&key={key}", *hdr()])


def post(port, suffix, payload, tenant_hdr=None):
    args = ["-X", "POST", f"http://127.0.0.1:{port}/_system/{suffix}", *hdr(),
            "-H", "Content-Type: application/json", "--data", payload]
    if tenant_hdr:
        args += ["-H", f"X-Rewind-Tenant: {tenant_hdr}"]
    return _curl(args)


def _curl(args):
    out = subprocess.run(["curl", "-s", "-w", "\n%{http_code}", "-m", "15",
                          "--http2-prior-knowledge"] + args, capture_output=True, text=True).stdout
    nl = out.rfind("\n")
    return (int(out[nl + 1:].strip() or 0), out[:nl])


def empty_attach(port, tenant):
    return subprocess.run(["curl", "-s", "-w", "%{http_code}", "-m", "15",
                           "--http2-prior-knowledge", "-X", "POST",
                           f"http://127.0.0.1:{port}/_system/v2-attach", *hdr(),
                           "-H", f"X-Rewind-Tenant: {tenant}", "--data", ""],
                          capture_output=True, text=True).stdout.strip()


def snapshot(port, tenant, path):
    code = subprocess.run(["curl", "-s", "-o", path, "-w", "%{http_code}", "-m", "15",
                           "--http2-prior-knowledge", "-X", "POST",
                           f"http://127.0.0.1:{port}/_system/v2-snapshot", *hdr(),
                           "-H", "Content-Type: application/json",
                           "--data", f'{{"tenant":"{tenant}"}}'],
                          capture_output=True, text=True).stdout.strip()
    return code


def load_merge(port, tenant, path):
    return subprocess.run(["curl", "-s", "-w", "%{http_code}", "-m", "15",
                           "--http2-prior-knowledge", "-X", "POST",
                           f"http://127.0.0.1:{port}/_system/v2-load-merge", *hdr(),
                           "-H", f"X-Rewind-Tenant: {tenant}", "--data-binary", f"@{path}"],
                          capture_output=True, text=True).stdout.strip()


def await_leader(port, tenant, deadline_s=10):
    end = time.time() + deadline_s
    while time.time() < end:
        if _curl([f"http://127.0.0.1:{port}/_system/v2-leader?tenant={tenant}", *hdr()])[0] == 200:
            return True
        time.sleep(0.2)
    return False


def move_live(dest):
    return _curl(["-X", "POST", f"http://127.0.0.1:{PF}/_control/move-live", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"livetenant","dest":"{dest}"}}'])


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()


def main():
    for b in (REWIND, FRONT):
        if not os.path.exists(b):
            raise SystemExit(f"{b} missing — `zig build rewind && zig build rewind-front`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    da, db = f"/tmp/zdm-a-{pid}", f"/tmp/zdm-b-{pid}"
    dcp = f"/tmp/zdm-cp-{pid}"
    bpath = os.path.join(os.environ.get("CLAUDE_JOB_DIR", "/tmp"), f"zdm-snap-{pid}.bin")
    for d in (da, db, dcp):
        subprocess.run(["rm", "-rf", d])

    fails = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            fails.append(label)

    try:
        print("boot: front + cluster-A (source) + cluster-B (dest)")
        spawn_front()
        spawn_rewind("A", PA, da, "a.localhost")
        spawn_rewind("B", PB, db, "b.localhost")

        T = "ift"  # leg-1 tenant
        print("leg 1: insert-if-absent — a forward newer than the snapshot is not clobbered")
        check("A seed key_cold", kv_put(PA, T, "key_cold", "v1"), 204)
        check("A seed key_hot=OLD", kv_put(PA, T, "key_hot", "OLD"), 204)
        # confirm visible before snapshot (avoid the immediate-after-write read race)
        check("A read key_hot", kv_get(PA, T, "key_hot"), (200, "OLD"))
        check("empty-attach B", empty_attach(PB, T), "204")
        check("B leader elected", await_leader(PB, T), True)
        check("forward-begin A→B", post(PA, "v2-forward-begin", f'{{"tenant":"{T}","dest":"{B_URL}"}}')[0], 204)
        check("snapshot A (has key_hot=OLD)", snapshot(PA, T, bpath), "200")
        # a write AFTER the snapshot → forwarded synchronously → B has NEW
        check("A write key_hot=NEW (forwarded)", kv_put(PA, T, "key_hot", "NEW"), 204)
        check("B got forwarded key_hot=NEW", kv_get(PB, T, "key_hot"), (200, "NEW"))
        # load-merge the (older) snapshot insert-if-absent
        check("load-merge snapshot into B", load_merge(PB, T, bpath), "204")
        check("B key_hot still NEW (not regressed)", kv_get(PB, T, "key_hot"), (200, "NEW"))
        check("B key_cold filled from snapshot", kv_get(PB, T, "key_cold"), (200, "v1"))
        check("A still serves key_hot=NEW (no quiesce)", kv_get(PA, T, "key_hot"), (200, "NEW"))

        print("leg 2: move-live orchestration end to end (source serves throughout)")
        check("A seed livetenant", kv_put(PA, "livetenant", "g", "hello"), 204)
        check("A read-back", kv_get(PA, "livetenant", "g"), (200, "hello"))
        st, msg = move_live("cluster-B")
        check("POST /_control/move-live", st, 200)
        print(f"       {msg.strip()!r}")
        check("B serves livetenant after move", kv_get(PB, "livetenant", "g"), (200, "hello"))
        check("A evicted livetenant", kv_get(PA, "livetenant", "g")[0] in (404, 409), True)
    finally:
        stop_all()
        for d in (da, db, dcp):
            subprocess.run(["rm", "-rf", d])
        try:
            os.remove(bpath)
        except OSError:
            pass

    if fails:
        print("\nFAIL: " + ", ".join(fails))
        sys.exit(1)
    print("\nPASS — zero-downtime move: source served throughout, a write made "
          "after the snapshot survived (insert-if-absent), dest serves after the "
          "flip. (slice c)")


if __name__ == "__main__":
    main()
