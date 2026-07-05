#!/usr/bin/env python3
"""Front-door inbound body-stall timeout smoke (plan A5,
docs/plans/front-door-hardening.md).

A client that starts a request body and stops sending held its front
flow and worker stream forever: the per-connection idle reap never
fires while any sibling stream (or a PING) keeps the connection
active. The fix is a per-stream BETWEEN-BYTES budget
(`REWIND_FRONT_BODY_STALL_TIMEOUT_MS`, nginx's `client_body_timeout`):
no inbound body byte for the budget → the stream is aborted (client
RST/close, upstream RST so the worker sees a broken stream, never a
truncated-but-complete body).

Topology: CP (routes acme.example → the h2 echo example on :8081) +
front with a 2 s budget + the h2-echo-server example as the upstream
(classic contract: replies only at body-complete — a stalled body
holds it open, which is exactly the window under test).

Ports: CP 18260, front 18261, echo upstream 8081 (fixed in the
example binary).

Proof legs:
  A. control — a complete POST echoes 200 through the front.
  B. a stalled body (headers + 10 of 100000 bytes, then silence) is
     aborted at ~the budget, not held.
  C. a SLOW-BUT-MOVING body (bytes every 1 s < the 2 s budget, total
     time > the budget) completes fine — the budget is between bytes,
     not total.

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

PCP = int(os.environ.get("CP_PORT", "18260"))
PF = int(os.environ.get("FRONT_PORT", "18261"))
PECHO = 8081  # fixed in examples/h2_echo_server.zig

CLUSTERS = f"cluster-1=http://127.0.0.1:{PECHO}"
PLACEMENT = "acme=cluster-1"
HOSTS = "acme.example=acme"

STALL_TIMEOUT_MS = 2000

procs = []


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
    for b, step in ((CP_BIN, "rewind-cp"), (FRONT_BIN, "rewind-front"),
                    (ECHO_BIN, "(default install)")):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build {step}`")

    cpd = f"/tmp/front-body-stall-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(label)

    try:
        print("boot: h2 echo upstream + CP + front (body-stall budget 2s)")
        echo = subprocess.Popen([ECHO_BIN], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        procs.append(echo)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if "listening" in (echo.stdout.readline() or ""):
                break
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS,
                 placement=PLACEMENT, cp_data_dir=cpd)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", extra_env={
            "REWIND_FRONT_BODY_STALL_TIMEOUT_MS": str(STALL_TIMEOUT_MS),
        })

        print("leg A: control — a complete POST echoes through the front")
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10",
             "-H", "Host: acme.example", "--data", "hello-echo",
             f"http://127.0.0.1:{PF}/"],
            capture_output=True, text=True,
        ).stdout.strip()
        check("POST → 200", r == "200", f"got {r}")

        print("leg B: stalled body is aborted at ~the budget")
        s = socket.create_connection(("127.0.0.1", PF), timeout=5)
        s.sendall(b"POST / HTTP/1.1\r\n"
                  b"Host: acme.example\r\n"
                  b"Content-Length: 100000\r\n"
                  b"\r\n"
                  b"0123456789")  # 10 of 100000 bytes, then silence
        t0 = time.monotonic()
        s.settimeout(STALL_TIMEOUT_MS / 1000 + 6)
        closed = None
        try:
            while True:
                if s.recv(4096) == b"":
                    closed = time.monotonic() - t0
                    break
        except (ConnectionResetError, BrokenPipeError):
            closed = time.monotonic() - t0
        except socket.timeout:
            pass
        s.close()
        budget_s = STALL_TIMEOUT_MS / 1000
        check(f"stalled stream closed in <{budget_s + 5:.0f}s", closed is not None,
              f"{closed:.2f}s" if closed is not None else "still open")
        if closed is not None:
            check("held at least ~the budget (between-bytes, not instant)",
                  closed >= budget_s * 0.5, f"{closed:.2f}s")

        print("leg C: slow-but-moving body survives (between-bytes semantics)")
        body = b"abcde"  # 5 bytes, one per second → total 5s > budget 2s
        s2 = socket.create_connection(("127.0.0.1", PF), timeout=5)
        head = ("POST / HTTP/1.1\r\n"
                "Host: acme.example\r\n"
                "Connection: close\r\n"
                f"Content-Length: {len(body)}\r\n\r\n")
        s2.sendall(head.encode())
        ok_send = True
        try:
            for ch in body:
                s2.sendall(bytes([ch]))
                time.sleep(1.0)
        except (BrokenPipeError, ConnectionResetError):
            ok_send = False
        check("all bytes accepted across 5s of 1s gaps", ok_send)
        resp = b""
        s2.settimeout(10)
        try:
            while True:
                d = s2.recv(4096)
                if d == b"":
                    break
                resp = resp + d
        except (socket.timeout, ConnectionResetError):
            pass
        s2.close()
        check("slow upload answered 200", resp.startswith(b"HTTP/1.1 200"),
              resp.split(b"\r\n", 1)[0].decode(errors="replace") if resp else "no response")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — a stalled inbound body is aborted at the between-bytes "
          "budget; slow-but-moving uploads survive. ✅ (plan A5)")


if __name__ == "__main__":
    main()
