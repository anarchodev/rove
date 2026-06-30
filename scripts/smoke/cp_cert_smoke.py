#!/usr/bin/env python3
"""CP cert-state axis smoke (gap #3 slice 1; docs/v2-front-door-architecture.md
"Certs: issuance + state").

TLS certs are admin-authored + placement-independent, so cert state is a sibling
axis in the CP `__directory__` group (`cert/{host}` → packed `[4B cert_len]
[cert_pem][key_pem]`), not per-cluster `__root__.db` like V1. The leader-elected
ACME issuer writes it (slice 3); operators upload via `/_control/cert`; every
stateless front-door pulls it via `/_cp/cert` for SNI termination (slice 2).
This proves the axis: write → read-back the exact packed frame → auth → durable.

The CP needs no DP workers and no S3.

Proof legs:
  A. GET /_cp/cert?host=acme.com → 404 (no cert yet).
  B. POST /_control/cert {host, cert, key} (move-secret gated) → 200; GET
     /_cp/cert returns the packed frame [4B len][cert][key], byte-exact.
  C. renew (re-upload) → the new cert replaces the old.
  D. POST /_control/cert WITHOUT the secret → 401; cert unchanged.
  E. durability — kill -9 the CP, restart over the same data dir, the cert
     REPLAYS from the durable directory store.

Build first:  `zig build rewind-cp`
"""

import json
import os
import signal
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, CP_BIN

PCP = int(os.environ.get("CP_PORT", "18230"))
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
HOST = "acme.com"

CLUSTERS = "cluster-1=http://127.0.0.1:18231"
HOSTS = f"{HOST}=acme"
PLACEMENT = "acme=cluster-1"

procs = []


def _curl_text(args):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{http_code}", "-m", "10", "--http2-prior-knowledge"] + args,
        capture_output=True, text=True,
    ).stdout
    nl = out.rfind("\n")
    if nl < 0:
        return (0, out)
    try:
        return (int(out[nl + 1:].strip() or 0), out[:nl])
    except ValueError:
        return (0, out[:nl])


def _curl_bytes(url):
    """GET returning (status:int, body:bytes) — the packed cert frame is binary."""
    out = subprocess.run(
        ["curl", "-s", "-o", "-", "-w", "\n%{http_code}", "-m", "10",
         "--http2-prior-knowledge", url],
        capture_output=True,
    ).stdout
    nl = out.rfind(b"\n")
    if nl < 0:
        return (0, out)
    try:
        return (int(out[nl + 1:].strip() or b"0"), out[:nl])
    except ValueError:
        return (0, out[:nl])


def set_cert(host, cert, key, secret=MOVE_SECRET):
    body = json.dumps({"host": host, "cert": cert, "key": key}, separators=(",", ":"))
    args = ["-X", "POST", f"http://127.0.0.1:{PCP}/_control/cert",
            "-H", "Content-Type: application/json", "--data", body]
    if secret is not None:
        args += ["-H", f"X-Rewind-Move-Secret: {secret}"]
    return _curl_text(args)


def get_cert(host=HOST):
    return _curl_bytes(f"http://127.0.0.1:{PCP}/_cp/cert?host={host}")


def unpack(frame: bytes):
    """[4B BE cert_len][cert][key] → (cert:bytes, key:bytes) or None."""
    if len(frame) < 4:
        return None
    clen = struct.unpack(">I", frame[:4])[0]
    if 4 + clen > len(frame):
        return None
    return (frame[4:4 + clen], frame[4 + clen:])


def spawn(want_needle, cpd):
    return spawn_cp(
        procs, PCP,
        clusters=CLUSTERS, hosts=HOSTS, placement=PLACEMENT,
        cp_data_dir=cpd, move_secret=MOVE_SECRET, want_needle=want_needle,
    )


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
    if not os.path.exists(CP_BIN):
        raise SystemExit(f"{CP_BIN} not found — run `zig build rewind-cp`")

    cpd = f"/tmp/cp-cert-{os.getpid()}"
    subprocess.run(["rm", "-rf", cpd])

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("boot: single-node CP (cert axis)")
        spawn("seeded directory from static config", cpd)

        # ── A. no cert yet ───────────────────────────────────────────
        print("leg A: no cert for the host yet")
        st, _ = get_cert()
        check("GET /_cp/cert unset → 404", st, 404)

        # ── B. upload + read back the exact frame ────────────────────
        print("leg B: upload a cert, read back the packed frame")
        st, _ = set_cert(HOST, "CERTPEM-v1", "KEYPEM-v1")
        check("POST /_control/cert → 200", st, 200)
        st, frame = get_cert()
        check("GET /_cp/cert → 200", st, 200)
        u = unpack(frame)
        check("unpacked cert", None if u is None else u[0], b"CERTPEM-v1")
        check("unpacked key", None if u is None else u[1], b"KEYPEM-v1")

        # ── C. renewal replaces ──────────────────────────────────────
        print("leg C: re-upload (renewal) replaces the cert")
        st, _ = set_cert(HOST, "CERTPEM-v2", "KEYPEM-v2")
        check("POST /_control/cert renew → 200", st, 200)
        _, frame = get_cert()
        u = unpack(frame)
        check("renewed cert", None if u is None else u[0], b"CERTPEM-v2")

        # ── D. unauthenticated write rejected ────────────────────────
        print("leg D: a cert write without the move secret is rejected")
        st, _ = set_cert(HOST, "EVIL", "EVIL", secret=None)
        check("POST /_control/cert no-secret → 401", st, 401)
        _, frame = get_cert()
        u = unpack(frame)
        check("cert unchanged (still v2)", None if u is None else u[0], b"CERTPEM-v2")

        # ── E. durability across a CP restart ────────────────────────
        print("leg E: kill -9 the CP; the cert replays")
        procs[0].send_signal(signal.SIGKILL)
        procs[0].wait()
        procs.clear()
        spawn("skipping static seed", cpd)
        st, frame = get_cert()
        check("cert survived restart → 200", st, 200)
        u = unpack(frame)
        check("cert survived restart → v2", None if u is None else u[0], b"CERTPEM-v2")
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", cpd])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — the CP serves a replicated cert-state axis "
          "(admin-gated write, byte-exact frame, durable across restart). ✅ (gap #3 slice 1)")


if __name__ == "__main__":
    main()
