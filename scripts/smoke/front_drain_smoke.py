#!/usr/bin/env python3
"""Front-door graceful-drain smoke (plan C10,
docs/architecture/front-door-hardening.md).

SIGTERM used to exit the poll loop immediately, cutting every in-flight
request mid-response — every rolling deploy of the front was
client-visible errors. Now the front GOAWAYs live connections and keeps
serving until in-flight flows finish or `REWIND_FRONT_DRAIN_TIMEOUT_MS`
(default 10 s) fires.

Topology: CP + front (drain budget 8 s) + the h2-echo-server example
upstream (:8081, replies at body-complete). Ports: CP 18290, front
18291.

Proof legs:
  A. a request in flight at SIGTERM (mid-upload) COMPLETES with 200 —
     the client finishes its body during the drain window and gets the
     echo back; the front then exits 0 well inside the budget.
  B. an idle front exits promptly on SIGTERM (no pointless full-budget
     wait when nothing is in flight).

Build first: `zig build` (installs h2-echo-server) + `zig build
rewind-cp rewind-front`
"""

import os
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, spawn_front, CP_BIN, FRONT_BIN, BINDIR

ECHO_BIN = os.path.join(BINDIR, "h2-echo-server")

PCP = int(os.environ.get("CP_PORT", "18290"))
PF = int(os.environ.get("FRONT_PORT", "18291"))
PECHO = 8081  # fixed in examples/h2_echo_server.zig

CLUSTERS = f"cluster-1=http://127.0.0.1:{PECHO}"
PLACEMENT = "acme=cluster-1"
HOSTS = "acme.example=acme"

DRAIN_MS = 8000

procs = []


def stop_all():
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def boot_front():
    return spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", extra_env={
        "REWIND_FRONT_DRAIN_TIMEOUT_MS": str(DRAIN_MS),
    })


def main():
    for b, step in ((CP_BIN, "rewind-cp"), (FRONT_BIN, "rewind-front"),
                    (ECHO_BIN, "(default install)")):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build {step}`")

    cpd = f"/tmp/front-drain-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(label)

    try:
        print("boot: h2 echo upstream + CP + front (drain budget 8s)")
        echo = subprocess.Popen([ECHO_BIN], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        procs.append(echo)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if "listening" in (echo.stdout.readline() or ""):
                break
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS,
                 placement=PLACEMENT, cp_data_dir=cpd)
        front = boot_front()

        # Warm the route so the in-flight leg isn't parked on a resolve.
        subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "5",
                        "-H", "Host: acme.example", f"http://127.0.0.1:{PF}/"],
                       capture_output=True)

        print("leg A: request in flight at SIGTERM completes during drain")
        body = b"0123456789"
        s = socket.create_connection(("127.0.0.1", PF), timeout=10)
        head = ("POST / HTTP/1.1\r\n"
                "Host: acme.example\r\n"
                "Connection: close\r\n"
                f"Content-Length: {len(body)}\r\n\r\n")
        s.sendall(head.encode())
        s.sendall(body[:5])
        time.sleep(0.3)  # let the front register the flow
        front.send_signal(signal.SIGTERM)
        t_term = time.monotonic()
        time.sleep(1.0)  # front is now draining; finish the upload
        s.sendall(body[5:])
        resp = b""
        s.settimeout(10)
        try:
            while True:
                d = s.recv(65536)
                if d == b"":
                    break
                resp += d
        except (socket.timeout, ConnectionResetError):
            pass
        s.close()
        check("in-flight request answered 200 during drain",
              resp.startswith(b"HTTP/1.1 200"),
              resp.split(b"\r\n", 1)[0].decode(errors="replace") if resp else "no response")
        check("echoed body intact", body in resp)
        try:
            rc = front.wait(timeout=DRAIN_MS / 1000 + 4)
            exited = time.monotonic() - t_term
            check("front exited cleanly", rc == 0, f"rc={rc}")
            # Convergence, not just the budget backstop: the flow frees
            # once served (response ~1s in + the 500ms h1 quiet window),
            # so an exit that rides the full budget is a drain that
            # never converged.
            check("exit follows the last flow, not the full budget",
                  exited < 4, f"{exited:.1f}s")
        except subprocess.TimeoutExpired:
            check("front exited cleanly", False, "still running past budget")

        print("leg B: idle front exits promptly")
        front2 = boot_front()
        time.sleep(0.3)
        front2.send_signal(signal.SIGTERM)
        t0 = time.monotonic()
        try:
            rc = front2.wait(timeout=5)
            dur = time.monotonic() - t0
            check("idle exit rc==0", rc == 0, f"rc={rc}")
            check("idle exit <2s (no pointless drain wait)", dur < 2, f"{dur:.2f}s")
        except subprocess.TimeoutExpired:
            check("idle exit rc==0", False, "still running")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — SIGTERM drains in-flight requests to completion; "
          "idle shutdown stays prompt. ✅ (plan C10)")


if __name__ == "__main__":
    main()
