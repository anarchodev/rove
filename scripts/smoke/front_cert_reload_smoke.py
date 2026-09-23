#!/usr/bin/env python3
"""Front-door platform-wildcard hot-reload smoke (rove#544;
docs/architecture/auth-and-domains.md — the platform wildcard).

The wildcard covers every first-party and tenant host, so its expiry is a
total outage for all of them, and it is distributed to three nodes by a
renewal hook. The front used to build its default TLS context once at boot
and never re-read the files: a renewed certificate had no effect until the
process restarted, which is how one prod node served a retired certificate
for two days while the other two served the renewal. The expiry gauge had
the same shape — observed once at boot, so the alert would keep firing on a
certificate that had already been replaced.

The reload runs on the cert-sync tick (`CertSync.reloadDefault`), BEFORE the
CP pull and independent of it: the wildcard lives on local disk, so an
unreachable CP must not hold it back. This smoke therefore points the front
at a dead CP port and never routes a request — every leg is a handshake.

Proof legs:
  A. the front serves the wildcard it booted with, and the gauge carries
     that certificate's notAfter.
  B. a certificate replaced on disk is served within a sync tick, by the
     SAME process — no restart — and the gauge moves to the new notAfter.
  C. a cert replaced ahead of its key (the torn-distribution window) is
     REFUSED: the front keeps serving the previous pair instead of swapping
     in a context it cannot complete a handshake with.
  D. landing the matching key converges on the new pair — the failed
     attempt did not latch the mtime cache and give up.

Build first: `zig build rewind-front`
"""

import os
import shutil
import ssl
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smoke_ports import alloc_port  # noqa: E402
from v2_topology import spawn_front, FRONT_BIN, read_log_text  # noqa: E402

PF = alloc_port()
PM = alloc_port()
DEAD_CP = alloc_port()  # never bound — the reload must not depend on the CP

SYNC_MS = 400

procs = []


def gen_cert(tmp, cn, days):
    """Self-signed cert+key with subject CN and a distinct notAfter."""
    cert = os.path.join(tmp, f"{cn}.cert.pem")
    key = os.path.join(tmp, f"{cn}.key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", str(days),
         "-subj", f"/CN={cn}", "-addext", f"subjectAltName=DNS:{cn}"],
        check=True, capture_output=True,
    )
    return cert, key


def not_after(cert_path):
    """The certificate's notAfter as unix seconds — what the gauge reports."""
    out = subprocess.run(["openssl", "x509", "-noout", "-enddate", "-in", cert_path],
                         check=True, capture_output=True, text=True).stdout
    return int(ssl.cert_time_to_seconds(out.split("=", 1)[1].strip()))


def install(cert_src, key_src, cert_dst, key_dst):
    """Replace the live pair the way the renewal hook does: write beside the
    target, then rename. An in-place copy is what makes a torn read possible,
    and the reload's retry is leg C/D — not an excuse to write torn files."""
    for src, dst in ((cert_src, cert_dst), (key_src, key_dst)):
        if src is None:
            continue
        shutil.copyfile(src, dst + ".new")
        os.replace(dst + ".new", dst)


def served_cn():
    """openssl s_client → the served leaf certificate's subject CN, or ''."""
    p = subprocess.run(
        ["openssl", "s_client", "-connect", f"127.0.0.1:{PF}",
         "-servername", "unknown.host", "-alpn", "h2"],
        input="", capture_output=True, text=True, timeout=10,
    )
    for line in p.stdout.splitlines():
        s = line.strip()
        if s.startswith("subject="):
            return s.split("CN", 1)[-1].lstrip(" =").strip()
    return ""


def gauge_not_after():
    """`front_tls_cert_expiry_seconds{host="<default>"}` from /metrics."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PM}/metrics", timeout=5) as r:
            for line in r.read().decode().splitlines():
                if line.startswith('front_tls_cert_expiry_seconds{host="<default>"}'):
                    return int(line.rsplit(" ", 1)[1])
    except Exception:
        pass
    return None


def await_cn(want, timeout=15):
    """The served CN, polled until it is `want` or the deadline passes."""
    deadline = time.time() + timeout
    got = ""
    while time.time() < deadline:
        got = served_cn()
        if got == want:
            return got
        time.sleep(0.3)
    return got


def await_gauge(want, timeout=20):
    """The gauge is re-rendered on the :443 loop's own cadence (~2s), so it
    trails the swap by a tick; poll rather than sample once."""
    deadline = time.time() + timeout
    got = None
    while time.time() < deadline:
        got = gauge_not_after()
        if got == want:
            return got
        time.sleep(0.5)
    return got


def main():
    if not os.path.exists(FRONT_BIN):
        raise SystemExit(f"{FRONT_BIN} not found — run `zig build rewind-front`")

    tmp = f"/tmp/front-cert-reload-{os.getpid()}"
    os.makedirs(tmp, exist_ok=True)
    live_cert = os.path.join(tmp, "platform.crt")
    live_key = os.path.join(tmp, "platform.key")

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    try:
        print("setup: three wildcards with distinct subjects and expiries")
        v1_cert, v1_key = gen_cert(tmp, "wildcard-v1", 5)
        v2_cert, v2_key = gen_cert(tmp, "wildcard-v2", 20)
        v3_cert, v3_key = gen_cert(tmp, "wildcard-v3", 40)
        install(v1_cert, v1_key, live_cert, live_key)

        print(f"boot: TLS front on :{PF} (CP :{DEAD_CP} is never bound)")
        fp = spawn_front(
            procs, PF, f"http://127.0.0.1:{DEAD_CP}", log_dir=tmp,
            extra_env={
                "REWIND_TLS_CERT": live_cert,
                "REWIND_TLS_KEY": live_key,
                # TLS on ⇒ the front would otherwise bind privileged :80.
                "REWIND_HTTP_PORT": "0",
                "REWIND_CERT_SYNC_MS": str(SYNC_MS),
                "REWIND_FRONT_METRICS_PORT": str(PM),
            },
        )
        pid = fp.pid

        # ── A. the booted certificate is the one served + reported ────
        print("leg A: the front serves (and reports) the cert it booted with")
        check("served CN at boot", await_cn("wildcard-v1"), "wildcard-v1")
        check("gauge notAfter at boot", await_gauge(not_after(v1_cert)), not_after(v1_cert))

        # ── B. renewal on disk, no restart ────────────────────────────
        print("leg B: replace the pair on disk → served without a restart")
        install(v2_cert, v2_key, live_cert, live_key)
        check("served CN after renewal", await_cn("wildcard-v2"), "wildcard-v2")
        check("gauge notAfter after renewal",
              await_gauge(not_after(v2_cert)), not_after(v2_cert))
        check("same process (no restart)", fp.poll() is None and fp.pid == pid, True)

        # ── C. a cert ahead of its key is refused, not served ─────────
        print("leg C: cert replaced ahead of its key → the old pair keeps serving")
        install(v3_cert, None, live_cert, live_key)
        time.sleep(SYNC_MS / 1000.0 * 5)
        check("served CN with a mismatched pair on disk", served_cn(), "wildcard-v2")
        check("gauge unchanged by the refused pair",
              gauge_not_after(), not_after(v2_cert))
        check("the refusal is logged",
              "default TLS cert reload failed" in read_log_text(fp._logf), True)

        # ── D. the retry converges once the key lands ─────────────────
        print("leg D: land the matching key → the retry converges")
        install(None, v3_key, live_cert, live_key)
        check("served CN once the pair matches", await_cn("wildcard-v3"), "wildcard-v3")
        check("gauge notAfter once the pair matches",
              await_gauge(not_after(v3_cert)), not_after(v3_cert))
        check("still the same process", fp.poll() is None and fp.pid == pid, True)
    finally:
        for p in procs:
            if p.poll() is None:
                p.terminate()
        for p in procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nfront cert reload smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
