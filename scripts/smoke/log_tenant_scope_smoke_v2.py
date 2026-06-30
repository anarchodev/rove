#!/usr/bin/env python3
"""Log-server tenant-scope gate smoke (step3-auth-plan.md A4 / A6).

Proves the audit's open latent-critical is closed: the standalone log-server
no longer treats "any signed token" as authorized for every tenant. Read
routes (`/v1/{tenant}/...`) now require a TENANT-SCOPED `logs-read` capability
token — `jwt.verifyWithCapAndTenant` rejects an unscoped token, a token scoped
to a different tenant, and a token missing the cap.

Spawns ONLY `rewind-logs` (the auth gate fires before any S3 read, so this
needs no cp/worker/front topology and no real log data — just the binary and
the shared JWT secret). Run after sourcing S3 env (the log-server opens its
backend at boot):

    zig build rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/smoke/log_tenant_scope_smoke_v2.py

Port: 18960 (+PID nudge). No fixed-topology collision with other smokes.
"""
from __future__ import annotations

import atexit
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import (  # noqa: E402
    _curl, _free_base, mint_jwt, JWT_SECRET_HEX, LOG_SERVER,
)
from v2_topology import await_ready  # noqa: E402

TAG = "logscope"
DATA_DIR = Path(f"/tmp/v2smoke-{TAG}-log-{os.getpid()}")
LOG_FILE = f"/tmp/v2smoke-{TAG}-logsrv-{os.getpid()}.log"
PREFIX = f"v2smoke-{TAG}-{os.getpid()}/"  # throwaway S3 prefix → empty index

_procs: list[subprocess.Popen] = []


def _teardown() -> None:
    for p in _procs:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
    for p in _procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    subprocess.run(["rm", "-rf", str(DATA_DIR)])


atexit.register(_teardown)


def spawn_log_server(port: int) -> subprocess.Popen:
    if not Path(LOG_SERVER).exists():
        raise SystemExit(f"{LOG_SERVER} missing — `zig build rewind-logs`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")
    env = dict(os.environ)
    env["LOOP46_SERVICES_JWT_SECRET"] = JWT_SECRET_HEX
    env["S3_KEY_PREFIX_BASE"] = PREFIX
    env["LOG_S3_KEY_PREFIX"] = PREFIX
    subprocess.run(["rm", "-rf", str(DATA_DIR)])
    logf = open(LOG_FILE, "w+")
    p = subprocess.Popen(
        [str(LOG_SERVER),
         "--data-dir", str(DATA_DIR),
         "--listen", f"127.0.0.1:{port}",
         "--poll-interval-ms", "5000"],
        stdout=logf, stderr=subprocess.STDOUT, env=env)
    p._name = "logsrv"  # type: ignore[attr-defined]
    p._logf = logf  # type: ignore[attr-defined]
    _procs.append(p)
    await_ready(p, "logsrv", "listening on", timeout=8.0)
    return p


def tok(tenant=None, caps=("logs-read",), ttl_s=300) -> str:
    payload = {"exp": int((time.time() + ttl_s) * 1000)}
    if tenant is not None:
        payload["tenant"] = tenant
    if caps:
        payload["caps"] = list(caps)
    return mint_jwt(JWT_SECRET_HEX, payload)


def main() -> int:
    port = _free_base(18960)
    spawn_log_server(port)
    base = f"http://127.0.0.1:{port}"

    failures: list[str] = []

    def check(label: str, resp, *, expect_status=None, reject: bool):
        # `reject` asserts a 401 (auth denied). Otherwise assert the request
        # passed the gate (NOT 401) and, when given, matches expect_status.
        ok = (resp.status == 401) if reject else (resp.status != 401)
        if expect_status is not None and not reject:
            ok = ok and resp.status == expect_status
        verdict = "ok" if ok else "FAIL"
        want = "401" if reject else (str(expect_status) if expect_status else "not-401")
        print(f"  [{verdict}] {label}: status={resp.status} (want {want})")
        if not ok:
            failures.append(f"{label}: got {resp.status}, want {want} :: {resp.body[:160]!r}")

    print("== log-server tenant-scope gate ==")

    # Health is unauthenticated.
    check("health (no auth)", _curl(f"{base}/v1/health"),
          expect_status=200, reject=False)

    # No Authorization header → 401.
    check("no token", _curl(f"{base}/v1/acme/list"), reject=True)

    # Unscoped token (legacy "any tenant" shape) → 401. THE core fix.
    check("unscoped token (exp only, no tenant)",
          _curl(f"{base}/v1/acme/list",
                headers={"Authorization": f"Bearer {tok(caps=())}"}),
          reject=True)
    check("unscoped token with logs-read but no tenant",
          _curl(f"{base}/v1/acme/list",
                headers={"Authorization": f"Bearer {tok(tenant=None)}"}),
          reject=True)

    # Token scoped to acme, querying globex → 401 (wrong tenant).
    check("acme token reading globex (cross-tenant)",
          _curl(f"{base}/v1/globex/list",
                headers={"Authorization": f"Bearer {tok(tenant='acme')}"}),
          reject=True)

    # Right tenant, wrong cap → 401 (missing cap).
    check("acme token without logs-read cap",
          _curl(f"{base}/v1/acme/list",
                headers={"Authorization": f"Bearer {tok(tenant='acme', caps=('admin-kv',))}"}),
          reject=True)

    # Correctly scoped token → passes the gate (200, empty index).
    check("acme token reading acme (scoped, list)",
          _curl(f"{base}/v1/acme/list",
                headers={"Authorization": f"Bearer {tok(tenant='acme')}"}),
          expect_status=200, reject=False)
    check("acme token reading acme (scoped, count)",
          _curl(f"{base}/v1/acme/count",
                headers={"Authorization": f"Bearer {tok(tenant='acme')}"}),
          expect_status=200, reject=False)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print("  - " + f)
        return 1
    print("\nPASS — tenant-scope gate enforced (unscoped + cross-tenant + missing-cap all 401).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
