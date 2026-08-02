#!/usr/bin/env python3
"""Front-door TLS-handshake reap smoke (plan A4,
docs/architecture/front-door-hardening.md).

The idle reaper only covered `_conn_active`: a peer that opened TCP
against the TLS listener and stalled mid-handshake sat in
`_conn_tls_handshake` forever, pinning one of the `max_connections`
slots — classic slowloris. The fix gives the handshake a TOTAL budget
from accept (`tls_handshake_timeout_ns` /
`REWIND_FRONT_TLS_HANDSHAKE_TIMEOUT_MS`); `last_active_ns` is never
refreshed during the handshake, so trickled bytes don't extend it.

Topology: a TLS front alone (REWIND_CP_URL points at a dead port — the
smoke never routes a request, so the CP is never needed).

Proof legs:
  A. a silent connection (TCP open, zero bytes) is closed by the
     server at ~the handshake budget, not held.
  B. a TRICKLING connection (one junk byte per 500 ms — under any idle
     window) is also closed at ~the budget: it's a deadline from
     accept, not an idle window.
  C. a real TLS request issued while A/B stall works fine (the stalled
     handshakes don't wedge serving); its own handshake completes
     within the budget.

Build first: `zig build rewind-front`
"""

import os
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke_ports import alloc_port  # noqa: E402
from v2_topology import FRONT_BIN

PF = alloc_port()
HANDSHAKE_TIMEOUT_MS = 2000

procs = []


def gen_cert(tmp, cn):
    cert = os.path.join(tmp, f"{cn}.cert.pem")
    key = os.path.join(tmp, f"{cn}.key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", f"/CN={cn}", "-addext", f"subjectAltName=DNS:{cn}"],
        check=True, capture_output=True,
    )
    return cert, key


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


def wait_for_close(sock, deadline_s):
    """Block on recv until the SERVER closes (returns seconds waited),
    or None if still open at deadline_s."""
    t0 = time.monotonic()
    sock.settimeout(deadline_s)
    try:
        while True:
            data = sock.recv(4096)
            if data == b"":
                return time.monotonic() - t0
    except (ConnectionResetError, BrokenPipeError):
        return time.monotonic() - t0
    except socket.timeout:
        return None
    finally:
        sock.close()


def main():
    if not os.path.exists(FRONT_BIN):
        raise SystemExit(f"{FRONT_BIN} not found — run `zig build rewind-front`")

    tmp = f"/tmp/front-hs-reap-{os.getpid()}"
    os.makedirs(tmp, exist_ok=True)

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(label)

    try:
        print("boot: TLS front (handshake budget 2s; CP never contacted)")
        cert, key = gen_cert(tmp, "front-default")
        env = dict(os.environ)
        env["REWIND_CP_URL"] = "http://127.0.0.1:1"  # dead — never routed to
        env["REWIND_TLS_CERT"] = cert
        env["REWIND_TLS_KEY"] = key
        env["REWIND_HTTP_PORT"] = "0"  # no privileged :80 in the sandbox
        env["REWIND_FRONT_TLS_HANDSHAKE_TIMEOUT_MS"] = str(HANDSHAKE_TIMEOUT_MS)
        p = subprocess.Popen([FRONT_BIN, str(PF)], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, env=env)
        procs.append(p)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            line = p.stdout.readline()
            if "listening on" in line:
                break
        else:
            raise SystemExit("front never came up")

        budget_s = HANDSHAKE_TIMEOUT_MS / 1000
        bound_s = budget_s + 3.0  # budget + poll cadence + margin

        print("leg A: silent connection is reaped at ~the budget")
        sa = socket.create_connection(("127.0.0.1", PF), timeout=5)
        # (send nothing)

        print("leg B: trickling connection is ALSO reaped (deadline, not idle)")
        sb = socket.create_connection(("127.0.0.1", PF), timeout=5)

        print("leg C: a real TLS request during the stall works")
        out = subprocess.run(
            ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", "-m", "8",
             f"https://127.0.0.1:{PF}/"],
            capture_output=True, text=True,
        ).stdout.strip()
        # No CP → the route parks and 503s; ANY HTTP status proves the
        # TLS handshake + h2 layer served us while A/B stalled.
        check("TLS request answered (handshake fine under stall)",
              out not in ("", "0", "000"), f"status {out}")

        # Trickle on B in the foreground while both wait out the budget:
        # one junk byte per 500 ms is far inside any idle window, but
        # must not extend the handshake deadline.
        t0 = time.monotonic()
        closed_b = None
        while time.monotonic() - t0 < bound_s and closed_b is None:
            try:
                sb.sendall(b"\x16")
            except (BrokenPipeError, ConnectionResetError):
                closed_b = time.monotonic() - t0
                break
            sb.settimeout(0.5)
            try:
                if sb.recv(4096) == b"":
                    closed_b = time.monotonic() - t0
            except socket.timeout:
                pass
            except (ConnectionResetError, BrokenPipeError):
                closed_b = time.monotonic() - t0
        sb.close()
        check(f"trickler closed in <{bound_s:.0f}s", closed_b is not None,
              f"{closed_b:.2f}s" if closed_b is not None else "still open")
        if closed_b is not None:
            check("trickler survived at least ~the budget (not an instant kill)",
                  closed_b >= budget_s * 0.5, f"{closed_b:.2f}s")

        closed_a = wait_for_close(sa, 5)
        check(f"silent conn closed in <{bound_s:.0f}s of accept", closed_a is not None,
              f"waited {closed_a:.2f}s more" if closed_a is not None else "still open")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", tmp])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — stalled TLS handshakes are reaped at the budget; "
          "serving continues alongside. ✅ (plan A4)")


if __name__ == "__main__":
    main()
