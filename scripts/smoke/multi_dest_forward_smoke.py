#!/usr/bin/env python3
"""Phase-7 hardening: multi-node-dest forward RE-TARGETING.

The zero-downtime overlap's `_move/forward` marker now holds the FULL dest
node list (comma-separated, leader first) instead of one URL, and the source's
dual-write walks it, re-aiming past 421s (non-leader dest nodes). This proves:

  A. WORST-CASE ORDERING — forward-begin with the dest leader listed LAST:
     every forwarded write 421s through both followers first, then lands on
     the leader. An acked source write is still on the dest.
  B. CP INTEGRATION — `/_control/move-live` onto a 3-node dest cluster end to
     end (the CP now writes the leader-first CSV target).
  C. DEST LEADER DEATH MID-OVERLAP — kill the dest leader while the overlap
     is open; the next source write re-aims to the promoted survivor and
     still acks 204 (the re-targeting this slice exists for).

  topology:
    rewind-cp :19515
      ├─ cluster-1 → rewind :19510                 (single-node source)
      └─ cluster-2 → rewind :19511/12/13           (3-node dest)
                       raft peers :19521/22/23

Run S3-first:  `set -a; . ./.env; set +a; python3 scripts/smoke/multi_dest_forward_smoke.py`
Build first:   `zig build rewind-worker && zig build rewind-cp`
"""

import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, await_line, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "..", "zig-out", "bin")
REWIND = os.path.join(BINDIR, "rewind-worker")

PA = 19510                       # cluster-1 (source)
P2 = [19511, 19512, 19513]       # cluster-2 HTTP ports
RP2 = [19521, 19522, 19523]      # cluster-2 raft peer ports
PCP = 19515

SECRET = "rewindmovesecretpadding0123456789abcdef0"

procs = []


def spawn_rewind(name, port, data_dir, multinode=None):
    env = dict(os.environ)
    env["REWIND_ADMIN_DOMAIN"] = f"{name}.localhost"
    env["REWIND_MOVE_SECRET"] = SECRET
    env["REWIND_ROOT_TOKEN"] = "smoke-nonprod-root-token-0123456789abcdef"  # non-default: rewind rejects unset/default
    if multinode:
        node_id, voters, peers = multinode
        env["REWIND_NODE_ID"] = str(node_id)
        env["REWIND_VOTERS"] = voters
        env["REWIND_PEERS"] = peers
    p = subprocess.Popen([REWIND, data_dir, str(port)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, env=env)
    p._name = name
    procs.append(p)
    await_line(p, name, "listening on")
    return p


def _curl(args, timeout=15):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", str(timeout),
         "--http2-prior-knowledge"] + args,
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


def hdr():
    return ["-H", f"X-Rewind-Move-Secret: {SECRET}"]


def kv_put(port, tenant, key, value):
    return _curl(["-X", "PUT", f"http://127.0.0.1:{port}/_system/v2-kv", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"{tenant}","key":"{key}","value":"{value}"}}'])[0]


def kv_get(port, tenant, key):
    return _curl([f"http://127.0.0.1:{port}/_system/v2-kv?tenant={tenant}&key={key}", *hdr()])


def v2_leader(port, tenant):
    return _curl([f"http://127.0.0.1:{port}/_system/v2-leader?tenant={tenant}", *hdr()])[0]


def attach(port, tenant):
    return _curl(["-X", "POST", f"http://127.0.0.1:{port}/_system/v2-attach", *hdr(),
                  "-H", f"X-Rewind-Tenant: {tenant}", "--data", ""])[0]


def forward_begin(port, tenant, dest_csv):
    return _curl(["-X", "POST", f"http://127.0.0.1:{port}/_system/v2-forward-begin", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"{tenant}","dest":"{dest_csv}"}}'])[0]


def forward_end(port, tenant):
    return _curl(["-X", "POST", f"http://127.0.0.1:{port}/_system/v2-forward-end", *hdr(),
                  "-H", "Content-Type: application/json",
                  "--data", f'{{"tenant":"{tenant}"}}'])[0]


def find_leader(tenant, deadline_s=20):
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        for i, port in enumerate(P2):
            if procs_alive_port(port) and v2_leader(port, tenant) == 200:
                return i
        time.sleep(0.3)
    return None


def procs_alive_port(port):
    for p in procs:
        if getattr(p, "_port", None) == port:
            return p.poll() is None
    return True


def put_retry(port, tenant, key, value, deadline_s=20):
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        last = kv_put(port, tenant, key, value)
        if last == 204:
            return 204
        time.sleep(0.3)
    return last


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
    for b in (REWIND, CP_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} missing — `zig build rewind-worker && zig build rewind-cp`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    pid = os.getpid()
    da = f"/tmp/mdf-a-{pid}"
    dnodes = [f"/tmp/mdf-n{i}-{pid}" for i in range(3)]
    dcp = f"/tmp/mdf-cp-{pid}"
    for d in (da, *dnodes, dcp):
        subprocess.run(["rm", "-rf", d])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(label)

    peers_csv = ",".join(f"127.0.0.1:{rp}" for rp in RP2)
    try:
        print("boot: CP + single-node source + 3-node dest")
        spawn_rewind("A", PA, da)
        for i in range(3):
            p = spawn_rewind(f"n{i+1}", P2[i], dnodes[i],
                             multinode=(i + 1, "1,2,3", peers_csv))
            p._port = P2[i]
        c2 = ",".join(f"http://127.0.0.1:{p}" for p in P2)
        spawn_cp(procs, PCP,
                 clusters=f"cluster-1=http://127.0.0.1:{PA};cluster-2={c2}",
                 hosts="mdf2.localhost=fwd2",
                 placement="fwd2=cluster-1",
                 cp_data_dir=dcp, move_secret=SECRET)

        # ── A. worst-case ordering: leader LAST in the forward CSV ────
        print("leg A: forward re-aims past two followers (leader last in CSV)")
        check("A seed fwd1", kv_put(PA, "fwd1", "seed", "v0"), 204)
        for i in range(3):
            check(f"empty-attach n{i+1}", attach(P2[i], "fwd1"), 204)
        li = find_leader("fwd1")
        check("dest leader elected", li is not None, True)
        worst = [f"http://127.0.0.1:{P2[i]}" for i in range(3) if i != li] + \
                [f"http://127.0.0.1:{P2[li]}"]
        check("forward-begin (leader last)", forward_begin(PA, "fwd1", ",".join(worst)), 204)
        check("A write k1 (forwarded via re-aim)", kv_put(PA, "fwd1", "k1", "x1"), 204)
        st, body = kv_get(P2[li], "fwd1", "k1")
        check("dest leader has k1", (st, body), (200, "x1"))

        # ── B. CP move-live onto the live 3-node dest (CSV end to end) ─
        print("leg B: /_control/move-live onto the multi-node dest (CP writes leader-first CSV)")
        check("A seed fwd2", kv_put(PA, "fwd2", "greet", "hello"), 204)
        st, _ = _curl(["-X", "POST", f"http://127.0.0.1:{PCP}/_control/move-live", *hdr(),
                       "-H", "Content-Type: application/json",
                       "--data", '{"tenant":"fwd2","dest":"cluster-2"}'])
        check("move-live status", st, 200)
        ok_get = False
        for i in range(3):
            st2, body2 = kv_get(P2[i], "fwd2", "greet")
            if (st2, body2) == (200, "hello"):
                ok_get = True
        check("dest serves fwd2 post-move", ok_get, True)

        # ── C. dest leader dies mid-overlap; the next write re-aims ───
        print("leg C: kill the dest leader mid-overlap; write re-aims to the promoted survivor")
        for p in procs:
            if getattr(p, "_port", None) == P2[li]:
                p._expected_kill = True
                p.send_signal(signal.SIGKILL)
                p.wait()
        check("A write k2 after dest-leader kill", put_retry(PA, "fwd1", "k2", "x2"), 204)
        li2 = find_leader("fwd1")
        check("a survivor promoted", li2 is not None and li2 != li, True)
        st, body = kv_get(P2[li2], "fwd1", "k2")
        check("promoted survivor has k2", (st, body), (200, "x2"))
        check("forward-end", forward_end(PA, "fwd1"), 204)

    finally:
        stop_all()
        for d in (da, *dnodes, dcp):
            subprocess.run(["rm", "-rf", d])

    if failures:
        print("\nFAIL:", ", ".join(failures))
        sys.exit(1)
    print("\nPASS — forward re-targeting: worst-case CSV order lands via 421 re-aim, "
          "and a dest-leader death mid-overlap degrades to a retry hop, not a failed write.")


if __name__ == "__main__":
    main()
