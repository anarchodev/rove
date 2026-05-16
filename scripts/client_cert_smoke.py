#!/usr/bin/env python3
"""Phase 2d gate: operator mTLS (--require-client-cert-ca, §3.5).

Behaviour contract:
  - no client cert        → TLS handshake fails (no HTTP)
  - cert from a wrong CA  → TLS handshake fails (no HTTP)
  - cert from the CA      → handshake completes, an HTTP status comes
                            back (TLS+client-cert accepted before any
                            handler runs)

"flag unset → plain TLS as before" needs no dedicated case here —
every other smoke runs without the flag and stays green.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import shutil
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402


def _sh(*args: str) -> None:
    subprocess.run(args, check=True, capture_output=True, timeout=30)


def _mint_ca(d: Path, name: str) -> tuple[Path, Path]:
    key, crt = d / f"{name}.key", d / f"{name}.pem"
    _sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(crt), "-days", "1",
        "-subj", f"/CN={name}")
    return crt, key


def _mint_client(d: Path, name: str, ca_crt: Path, ca_key: Path) -> tuple[Path, Path]:
    key, csr, crt = d / f"{name}.key", d / f"{name}.csr", d / f"{name}.pem"
    _sh("openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(csr), "-subj", f"/CN={name}")
    _sh("openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca_crt),
        "-CAkey", str(ca_key), "-CAcreateserial", "-out", str(crt), "-days", "1")
    return crt, key


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="rove-mtls-"))
    try:
        ca_crt, ca_key = _mint_ca(tmp, "required-ca")
        cli_crt, cli_key = _mint_client(tmp, "good-client", ca_crt, ca_key)
        rogue_ca_crt, rogue_ca_key = _mint_ca(tmp, "rogue-ca")
        rogue_crt, rogue_key = _mint_client(tmp, "rogue-client",
                                            rogue_ca_crt, rogue_ca_key)

        cluster = Cluster.spawn(
            tag="mtls-smoke",
            http_base=8285,
            raft_base=40385,
            files_port=8289,
            log_port=8290,
            with_log_files_bases=False,
            worker_extra_args=["--require-client-cert-ca", str(ca_crt)],
        )
        with cluster as c:
            # Can't use discover_leader: it probes over TLS with no
            # client cert, which mTLS (correctly) refuses. mTLS is
            # enforced identically on every node regardless of
            # leadership, so any node proves the contract — probe
            # node 0 directly.
            host = c.addrs.admin_host
            port = c.addrs.http_port(0)

            def probe(*extra: str) -> tuple[int, str]:
                p = subprocess.run(
                    ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                     "--resolve", f"{host}:{port}:127.0.0.1",
                     "--cacert", str(c.tls.cacert), *extra,
                     f"https://{host}:{port}/"],
                    capture_output=True, timeout=20)
                return p.returncode, p.stdout.decode().strip()

            # Readiness + case 3: poll with the valid client cert
            # until TLS completes and an HTTP status comes back.
            deadline = time.monotonic() + 30
            rc, code = 1, "000"
            while time.monotonic() < deadline:
                rc, code = probe("--cert", str(cli_crt), "--key", str(cli_key))
                if rc == 0 and code != "000":
                    break
                time.sleep(0.5)
            assert rc == 0 and code != "000", \
                f"valid client cert should complete TLS, got rc={rc} code={code}"
            print(f"ok  client cert from required CA → TLS ok (HTTP {code})")

            rc, code = probe()
            assert rc != 0 and code == "000", \
                f"no-cert should fail TLS, got rc={rc} code={code}"
            print("ok  no client cert → TLS handshake refused")

            rc, code = probe("--cert", str(rogue_crt), "--key", str(rogue_key))
            assert rc != 0 and code == "000", \
                f"rogue-CA cert should fail TLS, got rc={rc} code={code}"
            print("ok  client cert from wrong CA → TLS handshake refused")

        print("\nall operator-mTLS smoke checks passed")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
