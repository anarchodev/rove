#!/usr/bin/env python3
"""Front-door forwarding-header hygiene smoke (plan B7+B8,
docs/architecture/front-door-hardening.md).

The front is the trust boundary: it must (a) stamp the true client
identity upstream (`x-forwarded-for` from the peer address,
`x-forwarded-proto` from the terminated scheme, a `Via` entry), (b)
strip client-spoofed forwarding headers, and (c) drop headers
nominated by the client's `Connection` value (RFC 7230 §6.1 — the
request-smuggling vector).

Topology: CP + front + an inline python h2c "reflector" upstream that
answers every request with a JSON list of the exact header pairs it
received. Ports: CP 18270, front 18271, reflector 18272.

Proof legs (one h1 raw request carrying every attack at once):
  A. x-forwarded-for == 127.0.0.1 (stamped, not the spoofed value),
     x-forwarded-proto == http (h2c front), via == "1.1 rewind-front".
  B. the spoofed x-forwarded-for/proto/x-real-ip/forwarded are GONE.
  C. `Connection: x-secret-hint` + `x-secret-hint: v` → x-secret-hint
     is GONE upstream (nominated hop-by-hop).
  D. an innocent header (x-app-thing) still passes through.
  E. an h2 downstream request gets via == "2 rewind-front".

Build first: `zig build rewind-cp rewind-front`
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
from smoke_ports import alloc_port  # noqa: E402
from v2_topology import spawn_cp, spawn_front, CP_BIN, FRONT_BIN

import h2.config
import h2.connection
import h2.events

PCP = alloc_port()
PF = alloc_port()
PREFLECT = alloc_port()

CLUSTERS = f"cluster-1=http://127.0.0.1:{PREFLECT}"
PLACEMENT = "acme=cluster-1"
HOSTS = "acme.example=acme"

procs = []
stop_reflector = threading.Event()


def reflector_thread(ready):
    """h2c server: every request → 200 with a JSON [[name, value], …]
    of the exact request headers received."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PREFLECT))
    srv.listen(4)
    srv.settimeout(0.5)
    ready.set()
    while not stop_reflector.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        try:
            hc = h2.connection.H2Connection(
                config=h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
            hc.initiate_connection()
            conn.sendall(hc.data_to_send())
            conn.settimeout(0.5)
            while not stop_reflector.is_set():
                try:
                    data = conn.recv(65535)
                except socket.timeout:
                    continue
                if not data:
                    break
                for ev in hc.receive_data(data):
                    if isinstance(ev, h2.events.RequestReceived):
                        body = json.dumps(ev.headers).encode()
                        hc.send_headers(ev.stream_id, [
                            (":status", "200"),
                            ("content-length", str(len(body))),
                        ])
                        hc.send_data(ev.stream_id, body, end_stream=True)
                out = hc.data_to_send()
                if out:
                    conn.sendall(out)
        except (ConnectionResetError, BrokenPipeError, OSError):
            pass
        finally:
            conn.close()
    srv.close()


def stop_all():
    stop_reflector.set()
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def h1_request(headers_blob):
    """Raw h1 GET through the front; returns the reflected header pairs."""
    s = socket.create_connection(("127.0.0.1", PF), timeout=10)
    s.sendall(headers_blob)
    resp = b""
    s.settimeout(10)
    try:
        while True:
            d = s.recv(65536)
            if d == b"":
                break
            resp += d
    except socket.timeout:
        pass
    s.close()
    head, _, body = resp.partition(b"\r\n\r\n")
    if b"transfer-encoding: chunked" in head.lower():
        # De-chunk: the front re-frames h1 relay bodies as chunked
        # (it owns downstream framing — content-length is dropped).
        out = b""
        rest = body
        while rest:
            line, _, rest = rest.partition(b"\r\n")
            n = int(line.split(b";")[0] or b"0", 16)
            if n == 0:
                break
            out += rest[:n]
            rest = rest[n + 2:]
        body = out
    if not body:
        raise SystemExit(f"no body in response: {resp[:300]!r}")
    return dict_pairs(json.loads(body))


def dict_pairs(pairs):
    d = {}
    for k, v in pairs:
        d.setdefault(k, []).append(v)
    return d


def main():
    for b, step in ((CP_BIN, "rewind-cp"), (FRONT_BIN, "rewind-front")):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build {step}`")

    cpd = f"/tmp/front-headers-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(label)

    try:
        print("boot: h2c header reflector + CP + front")
        ready = threading.Event()
        t = threading.Thread(target=reflector_thread, args=(ready,), daemon=True)
        t.start()
        ready.wait(5)
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS,
                 placement=PLACEMENT, cp_data_dir=cpd)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}")

        print("legs A–D: one h1 request carrying spoofed + smuggled headers")
        got = h1_request(
            b"GET /probe HTTP/1.1\r\n"
            b"Host: acme.example\r\n"
            b"X-Forwarded-For: 6.6.6.6\r\n"
            b"X-Forwarded-Proto: https\r\n"
            b"X-Real-IP: 6.6.6.6\r\n"
            b"Forwarded: for=6.6.6.6\r\n"
            b"Connection: close, x-secret-hint\r\n"
            b"X-Secret-Hint: smuggled\r\n"
            b"X-App-Thing: legit\r\n"
            b"\r\n")
        check("x-forwarded-for stamped from the peer",
              got.get("x-forwarded-for") == ["127.0.0.1"], f"got {got.get('x-forwarded-for')}")
        check("x-forwarded-proto stamped from the edge scheme (h2c → http)",
              got.get("x-forwarded-proto") == ["http"], f"got {got.get('x-forwarded-proto')}")
        check("via appended (h1 downstream)",
              got.get("via") == ["1.1 rewind-front"], f"got {got.get('via')}")
        check("spoofed x-real-ip stripped", "x-real-ip" not in got)
        check("spoofed forwarded stripped", "forwarded" not in got)
        check("Connection-nominated x-secret-hint dropped (RFC 7230 §6.1)",
              "x-secret-hint" not in got, f"got {got.get('x-secret-hint')}")
        check("connection itself not forwarded", "connection" not in got)
        check("innocent header passes", got.get("x-app-thing") == ["legit"],
              f"got {got.get('x-app-thing')}")

        print("leg E: h2 downstream → via carries the received protocol")
        out = subprocess.run(
            ["curl", "-s", "-m", "10", "--http2-prior-knowledge",
             "-H", "Host: acme.example", f"http://127.0.0.1:{PF}/probe"],
            capture_output=True, text=True,
        ).stdout
        got2 = dict_pairs(json.loads(out or "[]"))
        check("via == 2 rewind-front over h2",
              got2.get("via") == ["2 rewind-front"], f"got {got2.get('via')}")
        check("h2 path also stamps x-forwarded-for",
              got2.get("x-forwarded-for") == ["127.0.0.1"], f"got {got2.get('x-forwarded-for')}")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — forwarding identity stamped at the trust boundary; "
          "spoofed and Connection-nominated headers stripped. ✅ (plan B7+B8)")


if __name__ == "__main__":
    main()
