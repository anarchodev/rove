#!/usr/bin/env python3
"""End-to-end smoke test for cookie-based admin login on the prod-shape
origin (UI + API served from the same subdomain).

Python port of `scripts/cookie_auth_smoke.sh`. Covers:
  - Public GET of the admin UI bundle without auth
  - POST /v1/login good/bad token → cookie / 401
  - Authed admin RPC via cookie (no Authorization header)
  - Unauthed admin RPC → 401
  - Logout clears the server-side session + expires the cookie
  - Bearer token still works side-by-side
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
API_HOST = f"app.{SYSTEM_SUFFIX}"


def main() -> int:
    cluster = Cluster.spawn(
        tag="cookie-smoke",
        http_base=8235,
        raft_base=40335,
        files_port=8239,
        log_port=8240,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=API_HOST,
        with_log_files_bases=False,
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        origin = c.admin_origin()

        # files-server bootstraps the admin tenant deploy via
        # /_system/release. Without it, every admin-routed request
        # 503s on "no deployment yet".
        c.spawn_files_server(cors_origin=origin, leader_url=origin)

        cc = c.curl_ctx()

        # 1. UI bundle public. Poll because admin's snapshot loads
        # async via the loader thread after files-server's bootstrap.
        import time as _t
        deadline = _t.monotonic() + 15.0
        r = curl(cc, f"{origin}/")
        while _t.monotonic() < deadline and r.status == 503:
            _t.sleep(0.2)
            r = curl(cc, f"{origin}/")
        expect_status("GET / serves the UI bundle without auth", 200, r)
        if "<!doctype html>" not in r.body.lower():
            sys.exit(f"FAIL GET / body not HTML: {r.body[:200]}")

        r = curl(cc, f"{origin}/app.js")
        expect_status("GET /app.js serves without auth", 200, r)

        # 2. Unauthed admin RPC → 401.
        r = curl(cc, f"{origin}/?fn=listInstance")
        expect_status("unauthed admin RPC → 401", 401, r)

        # 3. Bad token → 401, no rove_session cookie.
        r = curl(
            cc,
            f"{origin}/v1/login",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"token":"0000000000000000000000000000000000000000000000000000000000000000"}',
        )
        expect_status("POST /v1/login with bad token → 401", 401, r)
        if "rove_session" in r.headers.get("set-cookie", ""):
            sys.exit("FAIL bad-token login emitted rove_session cookie")
        print("ok  bad-token login emits no rove_session cookie")

        # 4. Good token → 200 + Secure/HttpOnly/SameSite=Lax cookie.
        r = curl(
            cc,
            f"{origin}/v1/login",
            method="POST",
            headers={"Content-Type": "application/json"},
            data=f'{{"token":"{TOKEN}"}}',
        )
        expect_status("POST /v1/login → 200", 200, r)
        sc = r.headers.get("set-cookie", "")
        if "rove_session=" not in sc:
            sys.exit(f"FAIL login missing Set-Cookie: {sc}")
        for attr in ("httponly", "samesite=lax", "secure"):
            if attr not in sc.lower():
                sys.exit(f"FAIL login cookie missing {attr}: {sc}")
        if '"ok":true' not in r.body:
            sys.exit(f"FAIL login body not ok: {r.body}")
        # Extract just the rove_session=<value> pair for replay.
        m = re.search(r"rove_session=[^;]+", sc)
        if not m:
            sys.exit(f"FAIL couldn't parse rove_session from {sc}")
        cookie = m.group(0)
        print("ok  POST /v1/login → 200 + HttpOnly+Secure+SameSite=Lax cookie")

        # 5. Authed admin RPC via cookie.
        r = curl(cc, f"{origin}/?fn=listInstance", headers={"Cookie": cookie})
        if '"id":"__admin__"' not in r.body:
            sys.exit(f"FAIL authed RPC missing __admin__: {r.body}")
        print("ok  authed admin RPC via cookie → 200")

        # 6. /v1/session returns is_root.
        r = curl(cc, f"{origin}/v1/session", headers={"Cookie": cookie})
        if '"is_root":true' not in r.body:
            sys.exit(f"FAIL session body: {r.body}")
        print("ok  GET /v1/session → {is_root:true}")

        # 7. Logout: 200 + cookie expired.
        r = curl(
            cc, f"{origin}/v1/logout", method="POST", headers={"Cookie": cookie}
        )
        expect_status("POST /v1/logout → 200", 200, r)
        sc = r.headers.get("set-cookie", "")
        if "rove_session=;" not in sc:
            sys.exit(f"FAIL logout didn't clear cookie: {sc}")
        if "max-age=0" not in sc.lower():
            sys.exit(f"FAIL logout cookie missing Max-Age=0: {sc}")

        r = curl(cc, f"{origin}/?fn=listInstance", headers={"Cookie": cookie})
        expect_status(
            "POST /v1/logout revokes session (post-logout cookie → 401)",
            401, r,
        )

        # 8. Bearer fallback still works.
        r = curl(
            cc,
            f"{origin}/?fn=listInstance",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Origin": origin,
            },
        )
        if '"id":"__admin__"' not in r.body:
            sys.exit(f"FAIL bearer fallback body: {r.body}")
        print("ok  Authorization: Bearer still works alongside cookies")

        # 9. /v1/session without auth → 401.
        r = curl(cc, f"{origin}/v1/session")
        expect_status("unauthed /v1/session → 401", 401, r)

        print()
        print("all cookie auth smoke tests passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
