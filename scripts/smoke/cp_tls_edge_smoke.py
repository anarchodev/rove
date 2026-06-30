#!/usr/bin/env python3
"""Front-door TLS termination + CP cert pull smoke (gap #3 slice 2;
docs/v2-front-door-architecture.md "TLS termination is ours").

The front door used to be h2c (TLS terminated upstream). Slice 2 makes it
terminate public TLS and SNI-select a per-host cert pulled from the CP
cert-state axis (slice 1): the default ctx is the platform wildcard
(REWIND_TLS_CERT/KEY), and custom-domain certs are synced proactively from
`/_cp/certs` + `/_cp/cert` into the TLS host store (the SNI handshake callback
can't block on a fetch, so the sync is on a timer). This proves the new
behavior with `openssl s_client` — no DP/S3 needed, since the SNI cert
selection is the slice's new code (the proxy path is unchanged + already
covered by tenant_move_smoke).

Proof legs:
  A. SNI = acme.localhost → the front serves the PER-HOST cert pulled from the
     CP (subject CN = acme.localhost), proving cert sync + SNI selection.
  B. SNI = unknown.host → the front falls back to the default wildcard cert
     (CN = front-default).
  C. a cert uploaded to the CP AFTER the front booted is picked up within a
     sync interval (runtime custom-domain provisioning end to end).

Build first:  `zig build rewind-cp && zig build rewind-front`
"""

import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_topology import spawn_cp, FRONT_BIN, CP_BIN

BINDIR = os.path.join(os.path.dirname(__file__), "..", "..", "zig-out", "bin")

PCP = int(os.environ.get("CP_PORT", "18240"))
PF = int(os.environ.get("FRONT_PORT", "18241"))
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"

HOST = "acme.localhost"
LATE_HOST = "beta.localhost"
TENANT = "acme"

# No real DP needed; routing just has to resolve so the front accepts the host.
CLUSTERS = "cluster-1=http://127.0.0.1:18242"
HOSTS = f"{HOST}={TENANT};{LATE_HOST}={TENANT}"
PLACEMENT = f"{TENANT}=cluster-1"

procs = []


def gen_cert(tmp, cn):
    """Self-signed cert+key with subject CN; returns (cert_path, key_path)."""
    cert = os.path.join(tmp, f"{cn}.cert.pem")
    key = os.path.join(tmp, f"{cn}.key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", f"/CN={cn}", "-addext", f"subjectAltName=DNS:{cn}"],
        check=True, capture_output=True,
    )
    return cert, key


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


def upload_cert(host, cert_path, key_path):
    cert = open(cert_path).read()
    key = open(key_path).read()
    import json
    body = json.dumps({"host": host, "cert": cert, "key": key}, separators=(",", ":"))
    return _curl_text(["-X", "POST", f"http://127.0.0.1:{PCP}/_control/cert",
                       "-H", f"X-Rewind-Move-Secret: {MOVE_SECRET}",
                       "-H", "Content-Type: application/json", "--data", body])


def served_cn(sni):
    """openssl s_client with SNI → the served leaf cert's subject CN, or ''."""
    p = subprocess.run(
        ["openssl", "s_client", "-connect", f"127.0.0.1:{PF}",
         "-servername", sni, "-alpn", "h2"],
        input="", capture_output=True, text=True, timeout=10,
    )
    # Parse the peer cert subject from the handshake dump.
    for line in p.stdout.splitlines():
        s = line.strip()
        if s.startswith("subject="):
            # e.g. "subject=CN=acme.localhost" or "subject=CN = acme.localhost"
            cn = s.split("CN", 1)[-1].lstrip(" =")
            return cn.strip()
    return ""


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
    for b in (CP_BIN, FRONT_BIN):
        if not os.path.exists(b):
            raise SystemExit(f"{b} not found — run `zig build rewind-cp && zig build rewind-front`")

    tmp = f"/tmp/tls-edge-{os.getpid()}"
    os.makedirs(tmp, exist_ok=True)
    cpd = f"{tmp}/cp"

    failures = []

    def check(label, got, want):
        ok = got == want
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: {got!r} (== {want!r})")
        if not ok:
            failures.append(f"{label}: got {got!r}")

    try:
        print("setup: generate default (wildcard) + per-host certs")
        def_cert, def_key = gen_cert(tmp, "front-default")
        host_cert, host_key = gen_cert(tmp, HOST)
        late_cert, late_key = gen_cert(tmp, LATE_HOST)

        print("boot: CP + (upload acme cert) + TLS front door")
        spawn_cp(procs, PCP, clusters=CLUSTERS, hosts=HOSTS, placement=PLACEMENT,
                 cp_data_dir=cpd, move_secret=MOVE_SECRET)
        check("upload acme cert → 200", upload_cert(HOST, host_cert, host_key)[0], 200)

        env = dict(os.environ)
        env["REWIND_CP_URL"] = f"http://127.0.0.1:{PCP}"
        env["REWIND_TLS_CERT"] = def_cert
        env["REWIND_TLS_KEY"] = def_key
        # Disable the :80 ACME-HTTP-01 / HTTP→HTTPS listener: with TLS on the
        # front otherwise defaults to binding privileged :80, which needs root.
        # This smoke only exercises TLS termination + SNI cert selection on the
        # TLS port, never the :80 redirect, so 0 (off) keeps it runnable
        # unprivileged (CI / sandbox) without changing what it tests.
        env["REWIND_HTTP_PORT"] = "0"
        env["REWIND_CERT_SYNC_MS"] = "400"
        env["REWIND_ROUTE_CACHE_MS"] = "0"
        fp = subprocess.Popen([FRONT_BIN, str(PF)], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, env=env)
        procs.append(fp)
        # Wait for "listening on" (and confirm TLS is on).
        deadline = time.time() + 15
        tls_on = False
        while time.time() < deadline:
            line = fp.stdout.readline()
            if not line:
                if fp.poll() is not None:
                    raise SystemExit("front exited early")
                continue
            sys.stdout.write("  [front] " + line)
            if "tls on" in line:
                tls_on = True
            if "listening on" in line:
                break
        check("front booted with TLS on", tls_on, True)
        time.sleep(1.0)  # let the first cert sync pull acme's cert

        # ── A. SNI = acme.localhost → per-host cert from the CP ───────
        print("leg A: SNI acme.localhost → CP-pulled per-host cert")
        check("served CN for acme.localhost", served_cn(HOST), HOST)

        # ── B. SNI = unknown → default wildcard fallback ─────────────
        print("leg B: SNI unknown.host → default wildcard cert")
        check("served CN for unknown.host", served_cn("unknown.host"), "front-default")

        # ── C. runtime provisioning: upload AFTER boot, picked up ────
        print("leg C: upload beta cert after boot → synced within an interval")
        check("upload beta cert → 200", upload_cert(LATE_HOST, late_cert, late_key)[0], 200)
        got = ""
        deadline = time.time() + 5
        while time.time() < deadline:
            got = served_cn(LATE_HOST)
            if got == LATE_HOST:
                break
            time.sleep(0.3)
        check("served CN for beta.localhost (post-boot upload)", got, LATE_HOST)
    finally:
        stop_all()
        subprocess.run(["rm", "-rf", tmp])

    if failures:
        print("\nFAIL:")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("\nPASS — the front door terminates TLS and SNI-serves per-host certs "
          "pulled from the CP, with a wildcard fallback + runtime provisioning. ✅ (gap #3 slice 2)")


if __name__ == "__main__":
    main()
