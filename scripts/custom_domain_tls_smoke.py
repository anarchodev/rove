#!/usr/bin/env python3
"""Phase 2c gate: SNI-based per-host cert selection (auth-domain-plan §3.3).

Spawns a cluster with --custom-cert-dir pointing at a dir holding a cert
for a host OUTSIDE both wildcard SANs, then asserts the worker presents:

  - SNI = the custom host          → the custom per-host cert
  - SNI = a wildcard system host   → the default (--tls-cert) wildcard
  - SNI = an unknown host          → the default wildcard (miss → fallback)

The custom host (`acmecorp.test`) is deliberately not under
*.rewindjsapp.localhost or *.rewindjscom.localhost, so a pass proves the
servername callback selected the store entry — not a wildcard match.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster  # noqa: E402

CUSTOM_HOST = "acmecorp.test"
SYSTEM_HOST = "app.rewindjscom.localhost"   # covered by the wildcard dev cert
UNKNOWN_HOST = "nope.test"                  # not in store, not a wildcard


def presented_san(port: int, sni: str) -> str:
    """SAN extension of the leaf cert the worker presents for `sni`."""
    s = subprocess.run(
        ["openssl", "s_client", "-connect", f"127.0.0.1:{port}",
         "-servername", sni, "-alpn", "h2"],
        input=b"", capture_output=True, timeout=15,
    ).stdout.decode("utf-8", "replace")
    begin = s.find("-----BEGIN CERTIFICATE-----")
    end = s.find("-----END CERTIFICATE-----")
    if begin == -1 or end == -1:
        raise AssertionError(f"no cert presented for SNI={sni}\n{s[:400]}")
    pem = s[begin:end + len("-----END CERTIFICATE-----")]
    x = subprocess.run(
        ["openssl", "x509", "-noout", "-ext", "subjectAltName"],
        input=pem.encode(), capture_output=True, timeout=10,
    ).stdout.decode("utf-8", "replace")
    return x


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="rove-customtls-")
    try:
        host_dir = Path(tmp) / CUSTOM_HOST
        host_dir.mkdir(parents=True)
        subprocess.run(
            ["mkcert", "-cert-file", str(host_dir / "cert.pem"),
             "-key-file", str(host_dir / "key.pem"), CUSTOM_HOST],
            check=True, capture_output=True, timeout=30,
        )

        cluster = Cluster.spawn(
            tag="customtls-smoke",
            http_base=8255,
            raft_base=40355,
            files_port=8259,
            log_port=8260,
            custom_cert_dir=tmp,
            with_log_files_bases=False,
        )
        with cluster as c:
            c.discover_leader()
            port = c.leader_port()
            print(f"ok  leader elected: node {c.leader_idx} (port {port})")

            custom = presented_san(port, CUSTOM_HOST)
            assert CUSTOM_HOST in custom, f"SNI={CUSTOM_HOST} → {custom!r}"
            assert "rewindjs" not in custom, f"SNI={CUSTOM_HOST} → {custom!r}"
            print(f"ok  SNI {CUSTOM_HOST} → per-host cert (SAN {custom.strip()})")

            system = presented_san(port, SYSTEM_HOST)
            assert "rewindjscom.localhost" in system, f"SNI={SYSTEM_HOST} → {system!r}"
            assert CUSTOM_HOST not in system, f"SNI={SYSTEM_HOST} → {system!r}"
            print(f"ok  SNI {SYSTEM_HOST} → default wildcard cert")

            unknown = presented_san(port, UNKNOWN_HOST)
            assert CUSTOM_HOST not in unknown, f"SNI={UNKNOWN_HOST} → {unknown!r}"
            assert "rewindjs" in unknown, f"SNI={UNKNOWN_HOST} → {unknown!r}"
            print(f"ok  SNI {UNKNOWN_HOST} (miss) → default wildcard cert")

        print("\nall custom-domain TLS smoke checks passed")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
