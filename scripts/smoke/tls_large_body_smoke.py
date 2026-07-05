#!/usr/bin/env python3
"""TLS h2 large-body integrity smoke (anarchodev/rove#2).

Reproduces + guards the front's large-HTTP/2-response corruption: a
static asset > the TLS record / socket-buffer threshold, fetched over
**TLS h2** through the front, used to fail `SSL_read: bad record mac`
and truncate (the front emitted the response's ciphertext batches as
multiple unordered io_uring sends → out-of-order TLS records → the
peer's MAC desynced). `curl --http1.1` always worked. The fix
serializes egress per connection (one write in flight + FIFO queue).

This spawns a TLS-terminating front (`tls_idp=True`) over a worker
serving 200 KB / 1 MB / 5 MB statics, and fetches each over TLS with
h2 AND h1, byte-exact (sha256), sequential + concurrent. Any
`bad record mac` / truncation / hash mismatch fails the smoke.

Needs S3 creds (`set -a; . ./.env; set +a`).
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_lib_v2 import V2Cluster  # noqa: E402

SIZES = {"a200k.bin": 200_000, "a1m.bin": 1_000_000, "a5m.bin": 5_000_000}


def body(name: str, size: int) -> str:
    line = f"{name} 0123456789abcdefghijklmnopqrstuvwxyz\n"
    return (line * (size // len(line) + 1))[:size]


BODIES = {n: body(n, s) for n, s in SIZES.items()}
HASHES = {n: hashlib.sha256(b.encode()).hexdigest() for n, b in BODIES.items()}
TRIVIAL = {"index.mjs": "export default function () { return 'ok'; }"}
STATICS = {"_static/index.html": ("<html>tls</html>", "text/html")}
for _n, _b in BODIES.items():
    STATICS[f"_static/{_n}"] = (_b, "application/octet-stream")

failures: list[str] = []


def fetch(origin: str, host: str, name: str, proto: str, tag: str,
          limit_rate: str = "") -> str | None:
    """One TLS fetch through the front (curl -k). None on success.
    `limit_rate` (e.g. "300k") slow-reads the response so the front's
    socket send buffer FILLS — the condition that makes concurrent
    io_uring sends block + reorder. Loopback buffers are huge, so
    without this the corruption never triggers locally."""
    exp = SIZES[name]
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        p = tf.name
    try:
        args = ["curl", "-sk", "-o", p, "-w", "%{http_code}|%{errormsg}",
                "-m", "120", "-H", f"Host: {host}", f"{origin}/{name}"]
        if limit_rate:
            args += ["--limit-rate", limit_rate]
        args.insert(1, "--http2-prior-knowledge" if proto == "h2" else "--http1.1")
        r = subprocess.run(args, capture_output=True, text=True)
        code, _, errmsg = r.stdout.partition("|")
        got = os.path.getsize(p)
        if r.returncode != 0 or code != "200" or got != exp:
            return (f"{tag} {name}[{proto}]: rc={r.returncode} http={code} "
                    f"bytes={got}/{exp} err={errmsg!r}")
        if hashlib.sha256(open(p, "rb").read()).hexdigest() != HASHES[name]:
            return f"{tag} {name}[{proto}]: hash mismatch (bytes={got})"
        return None
    finally:
        os.unlink(p)


def main() -> int:
    with V2Cluster.spawn("tls-largebody", nodes=1, tls_idp=True) as c:
        r = c.provision("demo")
        if r.status not in (200, 204):
            print(f"provision failed: {r.status}")
            return 1
        c.deploy_with_static("demo", TRIVIAL, STATICS)
        for _ in range(120):
            if c.get("demo", "/index.html").status == 200:
                break
            time.sleep(0.25)
        else:
            print("deploy never live")
            return 1

        # TLS origin on the tls front; Host routes the tenant.
        origin = f"https://127.0.0.1:{c.tls_front_port}"
        host = c.host_for("demo")

        print(f"TLS front {origin} host={host}")
        # Sequential: every size, both protocols.
        for name in SIZES:
            for proto in ("h2", "h1"):
                for i in range(8):
                    f = fetch(origin, host, name, proto, f"seq#{i}")
                    if f:
                        failures.append(f)
                        print("  FAIL", f)
                print(f"  seq {name}[{proto}] x8 done")

        # Concurrent h2 bursts on the big one (the failing shape).
        for rnd in range(4):
            with concurrent.futures.ThreadPoolExecutor(8) as ex:
                futs = [ex.submit(fetch, origin, host, "a5m.bin", "h2", f"par{rnd}.{j}")
                        for j in range(8)]
                for fu in futs:
                    f = fu.result()
                    if f:
                        failures.append(f)
                        print("  FAIL", f)
        print("  concurrent 5M h2 bursts done")

        # SLOW-READ concurrent bursts — this is what actually reproduces
        # the reorder on loopback (a fast reader drains the buffer before
        # it can fill). Each client reads at 300k/s so the front's socket
        # send buffer backs up, forcing io_uring sends to block + race.
        for rnd in range(3):
            with concurrent.futures.ThreadPoolExecutor(6) as ex:
                futs = [ex.submit(fetch, origin, host, "a5m.bin", "h2",
                                  f"slow{rnd}.{j}", "300k")
                        for j in range(6)]
                for fu in futs:
                    f = fu.result()
                    if f:
                        failures.append(f)
                        print("  FAIL", f)
        print("  slow-read 5M h2 bursts done")

    if failures:
        print(f"\ntls_large_body_smoke: FAILED ({len(failures)})")
        return 1
    print("\ntls_large_body_smoke: PASS — large TLS h2 bodies transfer "
          "byte-exact, no bad record mac. ✅ (rove#2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
