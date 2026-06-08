#!/usr/bin/env python3
"""V2 end-to-end gate: leader-elected CP ACME HTTP-01 issuance (gap #3 slice 3).

The V2 shape (vs the V1 `acme_issue_smoke.py`):
  - the issuer is a thread on `rewind-cp` (not the worker); it writes the
    issued cert to the CP cert axis (`directory.setCert`), which replicates.
  - the HTTP-01 `:80` challenge is answered by `rewind-front`'s plaintext
    listener (gap #6 phase 5), which forwards `/.well-known/acme-challenge/*`
    to the CP's `GET /_cp/acme-challenge?token=` endpoint.
  - the front pulls the issued cert into its SNI store via `CertSync`
    (`/_cp/certs`), so it terminates TLS for the custom domain.

Flow:
  1. pebble-challtestsrv: mock DNS, every name → 127.0.0.1 (so Pebble's
     validator hits OUR front `:80` listener).
  2. pebble: ACME dir at https://127.0.0.1:14000/dir.
  3. rewind-cp with REWIND_ACME_DIRECTORY=pebble, a host mapped
     (acmecorp.test=acme) but no cert → the issuer's work-list.
  4. rewind-front terminating TLS (default self-signed ctx) with its `:80`
     listener on Pebble's httpPort and a fast CertSync.
  5. Assert the front ends up serving `acmecorp.test` over TLS with the
     PEBBLE-issued cert (SAN == acmecorp.test) — proving issue → cert axis →
     replicate → CertSync → SNI end to end.

**Skips cleanly (exit 0)** if pebble / pebble-challtestsrv aren't found (PATH
or ~/go/bin) — install them to actually gate:
  go install github.com/letsencrypt/pebble/v2/cmd/{pebble,pebble-challtestsrv}@latest
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import v2_topology as topo  # noqa: E402

CUSTOM_HOST = "acmecorp.test"
ACME_HTTP_PORT = 5002          # pebble httpPort == front :80 listener port
CP_PORT = 9390
FRONT_TLS_PORT = 9443
PEBBLE_DIR_URL = "https://127.0.0.1:14000/dir"


def _need(bin_name: str) -> str | None:
    found = shutil.which(bin_name)
    if found:
        return found
    cand = Path.home() / "go" / "bin" / bin_name
    return str(cand) if cand.exists() else None


def _kill_stragglers() -> None:
    for n in ("pebble", "pebble-challtes"):  # comm truncated to 15 chars
        subprocess.run(["pkill", "-x", n], capture_output=True)


def _wait_dir(timeout_s: float = 20.0) -> bool:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(PEBBLE_DIR_URL, context=ctx, timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(0.3)
    return False


def _self_signed(tmp: str, name: str, cn: str, san: str) -> tuple[str, str]:
    key = str(Path(tmp) / f"{name}-key.pem")
    crt = str(Path(tmp) / f"{name}-cert.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", crt, "-days", "1", "-subj", f"/CN={cn}",
         "-addext", f"subjectAltName={san}"],
        check=True, capture_output=True, timeout=30)
    return crt, key


def _served_cert_san(port: int, servername: str) -> str:
    """openssl s_client → the leaf cert's SAN extension (or '')."""
    s = subprocess.run(
        ["openssl", "s_client", "-connect", f"127.0.0.1:{port}",
         "-servername", servername, "-alpn", "h2"],
        input=b"", capture_output=True, timeout=15).stdout.decode("utf-8", "replace")
    b = s.find("-----BEGIN CERTIFICATE-----")
    e = s.find("-----END CERTIFICATE-----")
    if b == -1 or e == -1:
        return ""
    pem = s[b:e + len("-----END CERTIFICATE-----")]
    return subprocess.run(
        ["openssl", "x509", "-noout", "-ext", "subjectAltName"],
        input=pem.encode(), capture_output=True, timeout=10).stdout.decode()


def main() -> int:
    pebble = _need("pebble")
    challsrv = _need("pebble-challtestsrv")
    if not pebble or not challsrv:
        print("SKIP: pebble / pebble-challtestsrv not found (PATH or ~/go/bin); "
              "install github.com/letsencrypt/pebble to run this gate")
        return 0

    tmp = tempfile.mkdtemp(prefix="rove-cp-acme-")
    log_dir = Path(tmp) / "logs"
    log_dir.mkdir()
    procs: list[subprocess.Popen] = []
    _kill_stragglers()
    time.sleep(1.0)
    try:
        # Pebble's own ACME-API HTTPS cert (self-signed; we use insecure TLS).
        pc, pk = _self_signed(tmp, "pebble", "localhost",
                              "IP:127.0.0.1,DNS:localhost")
        # The front's default SNI ctx (any cert; the custom-domain cert arrives
        # via CertSync). SAN deliberately NOT the custom host so the assertion
        # can't pass on the fallback cert.
        fc, fk = _self_signed(tmp, "front", "default.local", "DNS:default.local")

        cfg = {"pebble": {
            "listenAddress": "127.0.0.1:14000",
            "managementListenAddress": "127.0.0.1:15000",
            "certificate": pc, "privateKey": pk,
            "httpPort": ACME_HTTP_PORT, "tlsPort": 5001, "ocspResponderURL": "",
        }}
        cfg_path = Path(tmp) / "pebble.json"
        cfg_path.write_text(json.dumps(cfg))

        procs.append(subprocess.Popen(
            [challsrv, "-defaultIPv4", "127.0.0.1", "-defaultIPv6", "",
             "-dnsserver", ":8053", "-http01", "", "-https01", "",
             "-tlsalpn01", "", "-doh", "", "-management", ":8055"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        procs.append(subprocess.Popen(
            [pebble, "-config", str(cfg_path), "-dnsserver", "127.0.0.1:8053"],
            env={**os.environ, "PEBBLE_VA_NOSLEEP": "1", "PEBBLE_AUTHZREUSE": "0"},
            stdout=open(str(log_dir / "pebble.log"), "wb"), stderr=subprocess.STDOUT))
        if not _wait_dir():
            tail = ""
            with contextlib.suppress(OSError):
                tail = (log_dir / "pebble.log").read_text()[-600:]
            raise AssertionError(f"pebble dir never came up\n--- log ---\n{tail}")
        print("ok  pebble + challtestsrv up")

        # CP with the issuer enabled; host mapped but no cert → work-list.
        topo.spawn_cp(
            procs, CP_PORT,
            clusters="c1=http://127.0.0.1:7001",
            hosts=f"{CUSTOM_HOST}=acme",
            placement="acme=c1",
            cp_data_dir=str(Path(tmp) / "cp-data"),
            name="cp", log_dir=str(log_dir),
            extra_env={
                "REWIND_ACME_DIRECTORY": PEBBLE_DIR_URL,
                "REWIND_ACME_INSECURE_TLS": "1",
            },
        )
        print("ok  cp up (ACME issuer enabled)")

        # Front: terminates TLS (default ctx) + :80 listener on Pebble's httpPort
        # + fast CertSync so the issued cert lands in the SNI store quickly.
        topo.spawn_front(
            procs, FRONT_TLS_PORT, f"http://127.0.0.1:{CP_PORT}",
            route_cache_ms=0, name="front", log_dir=str(log_dir),
            extra_env={
                "REWIND_TLS_CERT": fc, "REWIND_TLS_KEY": fk,
                "REWIND_HTTP_PORT": str(ACME_HTTP_PORT),
                "REWIND_CERT_SYNC_MS": "500",
            },
        )
        print(f"ok  front up (TLS :{FRONT_TLS_PORT}, :80 listener :{ACME_HTTP_PORT})")

        # Poll up to 90s for issue → cert axis → CertSync → SNI.
        san = ""
        for _ in range(90):
            san = _served_cert_san(FRONT_TLS_PORT, CUSTOM_HOST)
            if CUSTOM_HOST in san:
                break
            time.sleep(1)
        assert CUSTOM_HOST in san, (
            f"front never served the Pebble cert for {CUSTOM_HOST}; "
            f"last SAN={san!r}\n--- cp log ---\n"
            + (log_dir / f"cp-{os.getpid()}.log").read_text()[-1500:])
        print(f"ok  front serves Pebble-issued {CUSTOM_HOST} by SNI (SAN={san.strip()})")

        print("\nall CP ACME issuance smoke checks passed")
        return 0
    finally:
        for p in procs:
            with contextlib.suppress(ProcessLookupError):
                p.send_signal(signal.SIGTERM)
        _kill_stragglers()
        subprocess.run(["pkill", "-x", "rewind-cp"], capture_output=True)
        subprocess.run(["pkill", "-x", "rewind-front"], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
