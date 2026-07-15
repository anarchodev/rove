#!/usr/bin/env python3
"""Front-door upstream connection pool smoke (plan A3,
docs/architecture/front-door-hardening.md).

One pooled h2c conn per backend node meant one congestion window for
every tenant, one conn death failing everything in flight, and
unbounded invisible queueing in nghttp2 past the peer's stream limit.
Now each node gets up to REWIND_FRONT_UPSTREAM_CONNS legs; submits pick
the least-loaded live leg; a saturated pool SHEDS a retryable 503
instead of queueing.

Topology: CP + front (2 legs, per-leg stream cap 4 for testability) +
an inline threaded h2c upstream that DELAYS responses ~1.5s (so
concurrent requests pile up in flight) and counts distinct connections
accepted. Ports: CP 18300, front 18301, upstream 18302.

Proof legs:
  A. 10 concurrent requests against capacity 2×4=8: at least 8 answer
     200; every non-200 is a shed 503; nothing hangs.
  B. the upstream saw MORE THAN ONE connection (the pool actually
     scaled out) and at most 2 (the configured leg count).
  C. after the burst drains, a fresh request serves 200 (pool healthy).
  D. per-client cap (plan C13): a second front with
     REWIND_FRONT_MAX_FLOWS_PER_IP=3 answers a 6-wide burst from one
     IP with exactly 3 in flight — the rest 429.

Build first: `zig build rewind-cp rewind-front`
"""

import os
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, spawn_front, CP_BIN, FRONT_BIN

import h2.config
import h2.connection
import h2.events

PCP = int(os.environ.get("CP_PORT", "18300"))
PF = int(os.environ.get("FRONT_PORT", "18301"))
PUP = int(os.environ.get("UPSTREAM_PORT", "18302"))

CLUSTERS = f"cluster-1=http://127.0.0.1:{PUP}"
PLACEMENT = "acme=cluster-1"
HOSTS = "acme.example=acme"

RESPONSE_DELAY_S = 1.5

procs = []
stop_upstream = threading.Event()
conn_count = [0]
conn_count_mu = threading.Lock()


def upstream_conn_thread(conn):
    """One accepted h2c conn: batch RequestReceived events, respond to
    all pending once the oldest has waited RESPONSE_DELAY_S."""
    try:
        hc = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=False))
        hc.initiate_connection()
        conn.sendall(hc.data_to_send())
        conn.settimeout(0.1)
        pending = {}  # stream_id -> arrival time
        while not stop_upstream.is_set():
            try:
                data = conn.recv(65535)
                if not data:
                    break
                for ev in hc.receive_data(data):
                    if isinstance(ev, h2.events.RequestReceived):
                        pending[ev.stream_id] = time.monotonic()
            except socket.timeout:
                pass
            now = time.monotonic()
            due = [sid for sid, t in pending.items() if now - t >= RESPONSE_DELAY_S]
            for sid in due:
                del pending[sid]
                body = b"slow-ok"
                try:
                    hc.send_headers(sid, [(":status", "200"),
                                          ("content-length", str(len(body)))])
                    hc.send_data(sid, body, end_stream=True)
                except Exception:
                    pass
            out = hc.data_to_send()
            if out:
                conn.sendall(out)
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        conn.close()


def upstream_main(ready):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PUP))
    srv.listen(8)
    srv.settimeout(0.5)
    ready.set()
    while not stop_upstream.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        with conn_count_mu:
            conn_count[0] += 1
        threading.Thread(target=upstream_conn_thread, args=(conn,), daemon=True).start()
    srv.close()


def stop_all():
    stop_upstream.set()
    for p in procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in procs:
        try:
            p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


def timed_get(results, idx, port=None):
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "15",
         "-H", "Host: acme.example", f"http://127.0.0.1:{port or PF}/burst/{idx}"],
        capture_output=True, text=True,
    ).stdout.strip()
    try:
        results[idx] = int(out or 0)
    except ValueError:
        results[idx] = 0


def main():
    for b, step in ((CP_BIN, "rewind-cp"), (FRONT_BIN, "rewind-front")):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build {step}`")

    cpd = f"/tmp/front-pool-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(label)

    try:
        print("boot: slow h2c upstream + CP + front (2 legs × cap 4)")
        ready = threading.Event()
        threading.Thread(target=upstream_main, args=(ready,), daemon=True).start()
        ready.wait(5)
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS,
                 placement=PLACEMENT, cp_data_dir=cpd)
        spawn_front(procs, PF, f"http://127.0.0.1:{PCP}", extra_env={
            "REWIND_FRONT_UPSTREAM_CONNS": "2",
            "REWIND_FRONT_UPSTREAM_STREAM_CAP": "4",
        })

        print("leg A: 10 concurrent requests vs capacity 8 (2 legs × cap 4)")
        n = 10
        results = [0] * n
        threads = [threading.Thread(target=timed_get, args=(results, i)) for i in range(n)]
        for t in threads:
            t.start()
            time.sleep(0.03)  # slight stagger: deterministic leg fill
        for t in threads:
            t.join()
        n200 = sum(1 for r in results if r == 200)
        n503 = sum(1 for r in results if r == 503)
        check("≥8 served 200 (both legs used to cap)", n200 >= 8, f"{n200}×200")
        check("every non-200 is a shed 503 (nothing hung/errored)",
              n200 + n503 == n, f"results={results}")

        print("leg B: the pool actually scaled out")
        with conn_count_mu:
            conns = conn_count[0]
        check("upstream saw 2 connections (scaled out, bounded by leg count)",
              conns == 2, f"{conns} conns")

        print("leg C: post-burst request serves fine")
        r = [0]
        timed_get(r, 0)
        check("fresh request → 200", r[0] == 200, f"got {r[0]}")

        print("leg D: per-client-IP cap (plan C13) — cap 3, burst 6")
        pf2 = int(os.environ.get("FRONT2_PORT", "18303"))
        spawn_front(procs, pf2, f"http://127.0.0.1:{PCP}", extra_env={
            "REWIND_FRONT_MAX_FLOWS_PER_IP": "3",
            "REWIND_FRONT_METRICS_PORT": "0",  # first front holds 9112
        })
        m = 6
        results2 = [0] * m
        threads2 = [threading.Thread(target=timed_get, args=(results2, i, pf2)) for i in range(m)]
        for t in threads2:
            t.start()
            time.sleep(0.05)
        for t in threads2:
            t.join()
        n200d = sum(1 for x in results2 if x == 200)
        n429d = sum(1 for x in results2 if x == 429)
        check("exactly 3 in flight served 200", n200d == 3, f"results={results2}")
        check("the rest 429'd at the cap", n429d == m - 3, f"results={results2}")
        # The cap releases with the flows: a follow-up request serves.
        r2 = [0]
        timed_get(r2, 0, pf2)
        check("post-burst request under the cap → 200", r2[0] == 200, f"got {r2[0]}")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — least-loaded legs, background scale-out, and visible "
          "shed at saturation. ✅ (plan A3)")


if __name__ == "__main__":
    main()
