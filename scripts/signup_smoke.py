#!/usr/bin/env python3
"""provisionInstance edge-case gate (Fork B, auth-domain-plan §4.7).

Self-serve signup is gone: authentication is the __auth__ IdP, and a
signed-in account creates its first instance via the authenticated
`?fn=provisionInstance` admin RPC (identity = the OIDC-verified
id_token `sub`, not a client-supplied field). `oidc_smoke.py` proves
the happy path; this gate covers the edge cases it doesn't:

  - duplicate name        → 409
  - reserved name         → 409
  - invalid name          → 400
  - per-account limit      → 403 (free tier max_instances=1)
  - the provisioned tenant serves starter content (deployStarter ran)

Driven by a NON-operator OIDC RP session (the customer path): the
seeded `_oidc/rp/default` lets the RP middleware resolve, but the
customer email is deliberately NOT in the operator allowlist, so the
session is not is_root and is subject to the free-tier cap.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
CUSTOMER_EMAIL = "customer@example.com"


def fn(origin: str, name: str, *args) -> str:
    a = urllib.parse.quote(json.dumps(list(args)))
    return f"{origin}/?fn={name}&args={a}"


def main() -> int:
    cluster = Cluster.spawn(
        tag="signup-smoke",
        http_base=8230,
        raft_base=40330,
        files_port=8259,
        log_port=8258,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        # OIDC token-exchange + JWKS hops http.send to loopback IdP;
        # bypass SSRF gate.
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        origin = c.admin_origin()
        c.spawn_files_server(
            cors_origin=origin, leader_url=origin,
            extra_args=c.admin_oidc_kv(),  # RP config only; no operator
        )
        c.mint_services_token()

        cc = c.curl_ctx(
            f"auth.{SYSTEM_SUFFIX}",
            f"alice.{PUBLIC_SUFFIX}",
        )
        alice_origin = f"https://alice.{PUBLIC_SUFFIX}:{c.leader_port()}"

        # Readiness: unauthenticated admin RPC 401s once the admin
        # deploy is loaded AND `_oidc/rp/default` is seeded (the RP
        # middleware 500s "no RP config" until the bootstrap-kv lands).
        deadline = time.monotonic() + 20.0
        r = curl(cc, f"{origin}/?fn=listInstance", headers={"Origin": origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{origin}/?fn=listInstance", headers={"Origin": origin})
        expect_status("unauthenticated admin RPC → 401", 401, r)

        # __auth__ readiness, then the customer RP handshake (NOT an
        # operator → not is_root, subject to the free-tier cap).
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        cust = {"Cookie": c.oidc_login(cc, CUSTOMER_EMAIL)}
        print("ok  non-operator authenticated via OIDC RP")

        r = curl(cc, f"{origin}/v1/session", headers=cust)
        who = json.loads(r.body)
        if who.get("is_root") is not False or who.get("owned") != []:
            sys.exit(f"FAIL customer session shape: {who}")
        print("ok  customer session is_root=false, owns nothing")

        # 1. Fresh provision → 201.
        r = curl(cc, fn(origin, "provisionInstance", "alice"), headers=cust)
        if r.status not in (200, 201):
            sys.exit(f"FAIL provisionInstance(alice): {r.status} {r.body}")
        if '"name":"alice"' not in r.body:
            sys.exit(f"FAIL provision body: {r.body}")
        print("ok  provisionInstance(alice) → 201")

        # 2. Duplicate name → 409.
        r = curl(cc, fn(origin, "provisionInstance", "alice"), headers=cust)
        expect_status("duplicate name → 409", 409, r)
        if '"error":"name unavailable"' not in r.body:
            sys.exit(f"FAIL dup body: {r.body}")

        # 3. Reserved name → 409.
        r = curl(cc, fn(origin, "provisionInstance", "admin"), headers=cust)
        expect_status("reserved name → 409", 409, r)
        if '"error":"name unavailable"' not in r.body:
            sys.exit(f"FAIL reserved body: {r.body}")

        # 4. Invalid name → 400.
        r = curl(cc, fn(origin, "provisionInstance", "bad name!"), headers=cust)
        expect_status("invalid name → 400", 400, r)

        # 5. Per-account limit (free tier max_instances=1; already owns
        #    alice) → 403 on a *fresh* name.
        r = curl(cc, fn(origin, "provisionInstance", "alice2"), headers=cust)
        expect_status("account limit → 403", 403, r)
        if '"error":"account_limit_reached"' not in r.body:
            sys.exit(f"FAIL limit body: {r.body}")
        print("ok  dup/reserved/invalid/limit edge cases enforced")

        # 6. whoami reflects the one owned instance.
        who = json.loads(curl(cc, f"{origin}/v1/session", headers=cust).body)
        if who.get("owned") != ["alice"]:
            sys.exit(f"FAIL owned after provision: {who}")
        print("ok  /v1/session owned=[alice]")

        # 7. Downstream: provisionInstance ran deployStarter, so the
        #    new tenant serves starter content.
        r = c.wait_for_handler("alice", "/", expected_status=200, timeout_s=15.0)
        if "live" not in r.body.lower():
            sys.exit(f"FAIL starter HTML: {r.body[:200]}")
        print(f"ok  starter content: GET {alice_origin}/ → 200")

        print()
        print("all provisionInstance edge-case checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
