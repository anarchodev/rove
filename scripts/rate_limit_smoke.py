#!/usr/bin/env python3
"""Smoke for the per-tenant rate limiter (request + email buckets).

Python port of `scripts/rate_limit_smoke.sh`. Signs up two tenants, hits
rl1's bucket to exhaustion → 429, confirms rl2 is independent, and
exercises the email bucket's catchable rate_limited Error.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
OPERATOR_EMAIL = "operator@example.com"
# Per-instance request-bucket capacity. Sized for headroom: the
# operator OIDC handshake (Fork B — admin is a pure RP, no Bearer) is
# ~15-20 __admin__/__auth__ requests incl. the poll loop, and admin is
# NOT limiter-exempt anymore (worker_dispatch.zig: "size the bucket,
# not bypass it"). rl1's bucket is per-instance + independent, so the
# exhaustion test just sends REQ_CAP then one more → 429.
REQ_CAP = 40


def provision(c: Cluster, cc, op_cookie: str, name: str) -> None:
    """Create a test tenant via the operator OIDC session (Fork B)."""
    args = urllib.parse.quote(json.dumps([name]))
    r = curl(cc, f"{c.admin_origin()}/?fn=createInstance&args={args}",
             headers={"Cookie": op_cookie})
    if r.status not in (200, 201):
        sys.exit(f"FAIL createInstance {name}: {r.status} {r.body}")


def main() -> int:
    cluster = Cluster.spawn(
        tag="rate-limit-smoke",
        http_base=8205,
        raft_base=40305,
        files_port=8223,
        log_port=8222,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        workers_per_node=1,  # buckets are per-worker; one worker keeps the count predictable
        worker_extra_args=[
            "--rate-limit-request-capacity", str(REQ_CAP),
            "--rate-limit-request-refill", "0",
            "--rate-limit-email-capacity", "2",
            "--rate-limit-email-refill", "0",
            # OIDC token-exchange + JWKS hops http.send to loopback IdP;
            # bypass SSRF gate.
            "--dev-webhook-unsafe",
        ],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        admin_origin = c.admin_origin()
        c.spawn_files_server(
            cors_origin=admin_origin, leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(
            f"auth.{SYSTEM_SUFFIX}",
            f"rl1.{PUBLIC_SUFFIX}",
            f"rl2.{PUBLIC_SUFFIX}",
        )

        # Wait for admin tenant to be loaded — via log tail, not HTTP,
        # to keep rl1's bucket pristine for the exhaustion test (the
        # operator OIDC handshake below hits __admin__/__auth__, NOT
        # rl1, so rl1's per-instance bucket stays untouched).
        leader_log = Path(f"/tmp/rate-limit-smoke-worker-{c.leader_idx}.out")
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists():
                content = leader_log.read_text(errors="replace")
                if "tenant __admin__ loaded deployment" in content:
                    break
            time.sleep(0.1)

        # __auth__ readiness, then create rl1 + rl2 via the operator
        # OIDC session and deploy a trivial 200 handler to each
        # (createInstance only sets the routing marker — unlike the
        # retired signup it does NOT deployStarter, so the bucket test
        # gets an explicit handler instead of relying on starter HTML).
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        op = c.oidc_login(cc, OPERATOR_EMAIL)
        H = 'export default function () { return { ok: true }; }'
        for t in ("rl1", "rl2"):
            provision(c, cc, op, t)
            c.release(t, c.put_file(t, "index.mjs", H))
        print("ok  provisioned + deployed rl1 + rl2 (operator OIDC session)")

        # 2. Per-instance request bucket. Wait for rl1's deploy by
        # tailing the leader's worker log — probing via HTTP would
        # consume a token from the bucket we're about to test.
        rl1 = f"https://rl1.{PUBLIC_SUFFIX}:{c.leader_port()}"
        rl2 = f"https://rl2.{PUBLIC_SUFFIX}:{c.leader_port()}"
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists():
                content = leader_log.read_text(errors="replace")
                if "tenant rl1 loaded deployment" in content:
                    break
            time.sleep(0.1)

        # Hit rl1 REQ_CAP times (within capacity).
        for i in range(1, REQ_CAP + 1):
            r = curl(cc, f"{rl1}/")
            expect_status(f"request {i} (within capacity)", 200, r)

        # Next one: bucket exhausted.
        r = curl(cc, f"{rl1}/")
        expect_status(f"request {REQ_CAP + 1} → 429 (bucket exhausted)", 429, r)
        if "retry-after" not in r.headers:
            sys.exit(f"FAIL Retry-After header missing: {r.headers}")
        if "rate limit exceeded" not in r.body:
            sys.exit(f"FAIL 429 body: {r.body}")
        print("ok  Retry-After header present on 429")
        print("ok  429 body explains the limit")

        # 3. rl2 independent. Wait for rl2's starter via log tail.
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if leader_log.exists():
                content = leader_log.read_text(errors="replace")
                if "tenant rl2 loaded deployment" in content:
                    break
            time.sleep(0.1)
        r = curl(cc, f"{rl2}/")
        expect_status("rl2 not affected by rl1's exhaustion", 200, r)

        # (The retired "admin bypasses the limit" step tested behavior
        # that no longer exists — admin is bucketed like any tenant
        # now; see worker_dispatch.zig "size the bucket, not bypass
        # it". The per-instance independence above is the real
        # coverage.)

        # 5. Email bucket: catchable rate_limited.
        email_handler = '''export default function () {
  try {
    email.send({
      key: "re_test",
      from: "test@example.com",
      to: "user@example.com",
      subject: "hi",
      text: "test",
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, code: e.code, message: e.message };
  }
}'''
        dep_id = c.put_file("rl2", "email/index.mjs", email_handler)
        c.release("rl2", dep_id)

        # Wait for the new email handler to load. files-server's deploy
        # path mints a fresh dep_id, but it might collide numerically
        # with the starter dep (both can be 1 when files-server's local
        # store starts fresh). Discriminate by the static-count: starter
        # had 1 static, the email-only deploy has 0.
        deadline = time.monotonic() + 10.0
        target = f"tenant rl2 loaded deployment {dep_id} (1 handler(s), 0 static(s)"
        while time.monotonic() < deadline:
            if leader_log.exists():
                content = leader_log.read_text(errors="replace")
                if target in content:
                    break
            time.sleep(0.1)
        for i in (1, 2):
            r = curl(cc, f"{rl2}/email")
            if '"ok":true' not in r.body:
                sys.exit(f"FAIL email call {i}: {r.body}")
        print("ok  email.send 1-2 succeed (within email bucket capacity)")

        r = curl(cc, f"{rl2}/email")
        if '"code":"rate_limited"' not in r.body:
            sys.exit(f"FAIL email call 3: expected code=rate_limited, got {r.body}")
        if "email rate limit exceeded" not in r.body:
            sys.exit(f"FAIL email call 3: missing message: {r.body}")
        print("ok  email.send 3 → catchable Error{code:'rate_limited'}")

        print()
        print("all rate limit smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
