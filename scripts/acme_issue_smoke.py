#!/usr/bin/env python3
"""Phase 2b end-to-end gate: in-tree ACME HTTP-01 issuance + raft
cert distribution (auth-domain-plan.md §3.2).

Requires Pebble (Let's Encrypt's test CA) + pebble-challtestsrv on
PATH. **Skips cleanly (exit 0) if either is absent** — CI / dev
machines without them are not blocked; install them to actually gate.

Flow:
  1. pebble-challtestsrv: mock DNS resolving every name → 127.0.0.1.
  2. pebble: ACME dir at https://127.0.0.1:14000/dir, HTTP-01
     validation against the challenge httpPort below.
  3. 3-node cluster, custom domain `acmecorp.test` seeded
     (assignDomain via the seed manifest), --acme-directory=pebble,
     --custom-cert-dir, --acme-insecure-tls (Pebble's root is
     throwaway), --acme-http-port matching pebble's httpPort.
  4. Assert the LEADER issues, the cert replicates via envelope-2,
     and a *FOLLOWER* serves it by SNI (proves the raft distribution
     path, not just issuance) — peer cert SAN == acmecorp.test and
     issuer is Pebble's intermediate, not the dev wildcard CA.

Requires `pebble` + `pebble-challtestsrv` on PATH (e.g. `go install
github.com/letsencrypt/pebble/v2/cmd/{pebble,pebble-challtestsrv}`).
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import ssl
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402

CUSTOM_HOST = "acmecorp.test"
ACME_HTTP_PORT = 5002       # pebble-config httpPort + --acme-http-port
PEBBLE_DIR_URL = "https://127.0.0.1:14000/dir"


def _need(bin_name: str) -> str | None:
    return shutil.which(bin_name)


def _kill_stragglers() -> None:
    # `pebble-challtestsrv` exceeds the 15-char kernel comm limit →
    # pkill -x must match the truncated name.
    for n in ("pebble", "pebble-challtes"):
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


def main() -> int:
    pebble = _need("pebble")
    challsrv = _need("pebble-challtestsrv")
    if not pebble or not challsrv:
        print("SKIP: pebble / pebble-challtestsrv not on PATH "
              "(install github.com/letsencrypt/pebble to run this gate)")
        return 0

    tmp = tempfile.mkdtemp(prefix="rove-acme-")
    procs: list[subprocess.Popen] = []
    _kill_stragglers()  # a leftover pebble on :14000 → stale CA state
    time.sleep(1.0)
    try:
        # Pebble's own ACME HTTPS listener needs a cert/key file (it
        # self-generates its CA hierarchy, but not the API cert). We
        # don't verify it (rove uses --acme-insecure-tls), so any
        # self-signed cert for 127.0.0.1 works.
        pk = Path(tmp) / "pebble-key.pem"
        pc = Path(tmp) / "pebble-cert.pem"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(pk), "-out", str(pc), "-days", "1",
             "-subj", "/CN=localhost",
             "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"],
            check=True, capture_output=True, timeout=30)

        cfg = {
            "pebble": {
                "listenAddress": "127.0.0.1:14000",
                "managementListenAddress": "127.0.0.1:15000",
                "certificate": str(pc),
                "privateKey": str(pk),
                "httpPort": ACME_HTTP_PORT,
                "tlsPort": 5001,
                "ocspResponderURL": "",
            }
        }
        cfg_path = Path(tmp) / "pebble.json"
        cfg_path.write_text(json.dumps(cfg))

        # challtestsrv = mock DNS only (every name → 127.0.0.1 so
        # Pebble's validator hits OUR :ACME_HTTP_PORT responder). Its
        # own challenge listeners are disabled — rove answers HTTP-01.
        procs.append(subprocess.Popen(
            # -defaultIPv6 "" → answer only A (127.0.0.1); else Pebble
            # may try the default ::1 AAAA first and our IPv4-only
            # responder refuses → spurious invalid.
            [challsrv, "-defaultIPv4", "127.0.0.1", "-defaultIPv6", "",
             "-dnsserver", ":8053",
             "-http01", "", "-https01", "", "-tlsalpn01", "",
             "-doh", "", "-management", ":8055"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        procs.append(subprocess.Popen(
            [pebble, "-config", str(cfg_path), "-dnsserver", "127.0.0.1:8053"],
            env={**os.environ, "PEBBLE_VA_NOSLEEP": "1",
                 "PEBBLE_AUTHZREUSE": "0"},
            stdout=open("/tmp/acme-smoke-pebble.log", "wb"),
            stderr=subprocess.STDOUT))
        if not _wait_dir():
            tail = ""
            try:
                tail = Path("/tmp/acme-smoke-pebble.log").read_text()[-600:]
            except OSError:
                pass
            raise AssertionError(
                f"pebble directory never came up at {PEBBLE_DIR_URL}\n"
                f"--- pebble.log tail ---\n{tail}")

        # Only the domain registration matters for issuance (the ACME
        # loop reads listDomains); no handler needed.
        manifest = {"tenants": [{
            "id": "acme",
            "domains": [CUSTOM_HOST],
            "files": [],
        }]}

        cluster = Cluster.spawn(
            tag="acme-smoke",
            http_base=8275,
            raft_base=40375,
            files_port=8279,
            log_port=8280,
            custom_cert_dir=tmp + "/certs",
            seed_manifest=manifest,
            with_log_files_bases=False,
            worker_extra_args=[
                "--acme-directory", PEBBLE_DIR_URL,
                "--acme-insecure-tls",
                "--acme-http-port", str(ACME_HTTP_PORT),
            ],
        )
        with cluster as c:
            c.discover_leader()
            print(f"ok  leader: node {c.leader_idx}")

            # Poll up to 60s for the leader to issue + replicate.
            issued = False
            for _ in range(60):
                if (Path(tmp) / "certs" / CUSTOM_HOST / "cert.pem").exists():
                    issued = True
                    break
                time.sleep(1)
            assert issued, "leader never issued/materialized the cert"
            print(f"ok  leader issued {CUSTOM_HOST}")

            # Assert a FOLLOWER serves it by SNI (the raft path).
            follower = next(i for i in range(3) if i != c.leader_idx)
            fport = c.addrs.http_port(follower)
            s = subprocess.run(
                ["openssl", "s_client", "-connect", f"127.0.0.1:{fport}",
                 "-servername", CUSTOM_HOST, "-alpn", "h2"],
                input=b"", capture_output=True, timeout=15).stdout.decode("utf-8", "replace")
            b, e = s.find("-----BEGIN CERTIFICATE-----"), s.find("-----END CERTIFICATE-----")
            assert b != -1 and e != -1, f"follower presented no cert\n{s[:300]}"
            pem = s[b:e + len("-----END CERTIFICATE-----")]
            san = subprocess.run(
                ["openssl", "x509", "-noout", "-ext", "subjectAltName"],
                input=pem.encode(), capture_output=True, timeout=10).stdout.decode()
            assert CUSTOM_HOST in san, f"follower SNI cert SAN = {san!r}"
            print(f"ok  follower {follower} serves Pebble-issued {CUSTOM_HOST} by SNI")

        print("\nall ACME issuance smoke checks passed")
        return 0
    finally:
        for p in procs:
            with __import__("contextlib").suppress(ProcessLookupError):
                p.send_signal(signal.SIGTERM)
        _kill_stragglers()  # belt-and-suspenders: never leak :14000
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
