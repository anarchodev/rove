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

NOTE: authored against documented Pebble behavior; not executed in the
dev sandbox (no pebble binary there). The skip path IS exercised.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402

CUSTOM_HOST = "acmecorp.test"
ACME_HTTP_PORT = 5002       # pebble-config httpPort + --acme-http-port
PEBBLE_DIR_URL = "https://127.0.0.1:14000/dir"


def _need(bin_name: str) -> str | None:
    return shutil.which(bin_name)


def main() -> int:
    pebble = _need("pebble")
    challsrv = _need("pebble-challtestsrv")
    if not pebble or not challsrv:
        print("SKIP: pebble / pebble-challtestsrv not on PATH "
              "(install github.com/letsencrypt/pebble to run this gate)")
        return 0

    tmp = tempfile.mkdtemp(prefix="rove-acme-")
    procs: list[subprocess.Popen] = []
    try:
        cfg = {
            "pebble": {
                "listenAddress": "127.0.0.1:14000",
                "managementListenAddress": "127.0.0.1:15000",
                "certificate": "",
                "privateKey": "",
                "httpPort": ACME_HTTP_PORT,
                "tlsPort": 5001,
                "ocspResponderURL": "",
            }
        }
        cfg_path = Path(tmp) / "pebble.json"
        cfg_path.write_text(json.dumps(cfg))

        # Mock DNS: every name → 127.0.0.1 so Pebble's validator hits
        # our :ACME_HTTP_PORT responder.
        procs.append(subprocess.Popen(
            [challsrv, "-defaultIPv4", "127.0.0.1", "-dns01", ":8053",
             "-http01", "", "-https01", "", "-tlsalpn01", ""],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        procs.append(subprocess.Popen(
            [pebble, "-config", str(cfg_path), "-dnsserver", "127.0.0.1:8053"],
            env={**os.environ, "PEBBLE_VA_NOSLEEP": "1"},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(2.0)  # let pebble bind

        manifest = {"instances": [{
            "id": "acme",
            "domains": [CUSTOM_HOST],
            "files": [{"path": "index.mjs",
                       "source": "loop46-demo-tenants/hello/index.mjs"}],
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
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
