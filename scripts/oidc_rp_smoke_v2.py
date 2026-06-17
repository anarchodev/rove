#!/usr/bin/env python3
"""Dashboard RP login over OIDC against __auth__ (step3-auth-plan.md B2).

Stands up __auth__ (IdP) + web/admin (relying party) on a V2 cluster with a
TLS-terminating front, then drives the full browser-shaped OIDC handshake:
app /_rp/login → IdP /authorize → magic-link → /_rp/callback → poll → session.
Proves an operator (in the `_admin/operator/*` allowlist) logs in to
is_root:true, and a non-operator logs in to is_root:false.

Why TLS: the RP completes login via a SERVER-SIDE token exchange (webhook.send
to the IdP /token + JWKS), and the IdP signs an `https://{host}` issuer (§0).
So the worker→IdP hop must ride real TLS with a consistent host:port. The
harness runs a second, TLS-terminating front (V2Cluster.spawn(tls_idp=True));
the tenant door pins the worker→IdP fetch to it; the h2c front still serves
deploys. verify is off everywhere (self-signed cert; unsafe_outbound).

Run: zig build rewind-worker rewind-cp rewind-front
     set -a; . ./.env; set +a
     python3 scripts/oidc_rp_smoke_v2.py
Ports: http_base 19900 (PID-nudged); TLS front at base+54.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, REPO_ROOT  # noqa: E402

OPERATOR = "operator@example.com"
CUSTOMER = "customer@example.com"


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def _sid(r) -> str | None:
    m = re.search(r"__Host-rove_sid=[^;]+", r.headers.get("set-cookie", ""))
    return m.group(0) if m else None


def idp_login(c: V2Cluster, *, email: str, app_origin: str, auth_base: str) -> str:
    """Drive the OIDC RP handshake as `email` over the TLS front; return the app
    `__Host-rove_sid` cookie. is_root is decided server-side by the allowlist —
    the flow is identical either way. Mirrors smoke_lib.idp_login (V1)."""
    def absll(base, loc):
        return loc if loc.startswith("http") else base + loc

    # 1. app /_rp/login → 302 to the IdP /authorize (mints the app sid).
    r = c.tls_curl(app_origin + "/_rp/login?return_to=" + urllib.parse.quote("/"))
    if r.status != 302:
        raise RuntimeError(f"/_rp/login {r.status}: {r.body[:200]}")
    app_cookie = _sid(r)
    authorize = r.headers.get("location", "")
    if not app_cookie:
        raise RuntimeError(f"/_rp/login minted no app sid: {r.headers}")

    # 2. IdP /authorize, no IdP session → 302 to /login (mints the auth sid).
    r = c.tls_curl(authorize)
    if r.status != 302:
        raise RuntimeError(f"/authorize#1 {r.status}: {r.body[:200]} (url={authorize})")
    auth_cookie = _sid(r)
    login_loc = absll(auth_base, r.headers.get("location", ""))
    return_to = urllib.parse.parse_qs(urllib.parse.urlparse(login_loc).query)["return_to"][0]

    # 3. POST IdP /login (dev: no resend key → magic_link in JSON).
    r = c.tls_curl(auth_base + "/login", method="POST",
                   headers={"content-type": "application/x-www-form-urlencoded",
                            "Cookie": auth_cookie},
                   data="email=" + urllib.parse.quote(email) +
                        "&return_to=" + urllib.parse.quote(return_to))
    if r.status != 200:
        raise RuntimeError(f"/login {r.status}: {r.body[:200]}")
    magic = json.loads(r.body)["magic_link"]

    # 4. Follow the magic link (auth sid) → binds the IdP session, 302 to authorize.
    r = c.tls_curl(magic, headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"/login/verify {r.status}: {r.body[:200]}")

    # 5. /authorize again (authenticated) → 302 to app /_rp/callback?code.
    r = c.tls_curl(absll(auth_base, r.headers.get("location", "")),
                   headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"/authorize#2 {r.status}: {r.body[:200]}")
    callback = r.headers.get("location", "")

    # 6. app /_rp/callback (app sid) → 202 poll page; fires the async token
    #    exchange + JWKS verify (the server-side hops that need TLS).
    r = c.tls_curl(callback, headers={"Cookie": app_cookie})
    if r.status != 202:
        raise RuntimeError(f"/_rp/callback {r.status}: {r.body[:200]}")

    # 7. Poll until the background completion writes _rp/sess/{sid}.
    last = ""
    for _ in range(200):
        r = c.tls_curl(app_origin + "/_rp/poll", headers={"Cookie": app_cookie})
        last = r.body
        if r.status == 200:
            try:
                if json.loads(r.body).get("authed"):
                    return app_cookie
            except Exception:
                pass
        time.sleep(0.25)
    raise RuntimeError(f"RP login never completed for {email}: {last[:200]}")


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    auth_src = (REPO_ROOT / "web/auth/index.mjs").read_text()
    auth_cfg = (REPO_ROOT / "web/auth/_config/oidc/default.json").read_text()
    admin_files = {p: (REPO_ROOT / "web/admin" / p).read_text() for p in
                   ("index.mjs", "_middlewares/index.mjs",
                    "_rp/complete.mjs", "_rp/jwks.mjs")}

    print("=== dashboard RP login over OIDC (B2) ===")
    with V2Cluster.spawn("oidcrp", nodes=1, http_base=19900, raft_base=20000,
                         tls_idp=True) as c:
        app_origin = c.tls_origin("__admin__")    # https://__admin__.localhost:{tls}
        auth_base = c.tls_origin("__auth__")       # https://__auth__.localhost:{tls}

        # Deploy app up, then __auth__ (IdP), then web/admin (RP) — the admin
        # deploy is LAST (it replaces the baked deploy app).
        c._ensure_admin_app()
        r = c.provision("__auth__")
        check("provision __auth__ → 204/409", r.status in (204, 409), f"got {r.status}")
        try:
            c.deploy_with_static(
                "__auth__", {"index.mjs": auth_src},
                {"_config/oidc/default.json": (auth_cfg, "application/json")})
        except RuntimeError as e:
            check("deploy web/auth → __auth__", False, str(e))
            return 1
        # __auth__ client: override the ${ISSUER_PARENT} template so the
        # admin-dashboard client redirects to OUR __admin__ host:port.
        c.admin_kv_put("__auth__", "_oidc/config/default", json.dumps({
            "clients": [{"client_id": "admin-dashboard",
                         "redirect_uris": [app_origin + "/_rp/callback"]}],
            "login_path": "/login",
        }, separators=(",", ":")))
        try:
            c.deploy_handlers("__admin__", admin_files)
        except RuntimeError as e:
            check("deploy web/admin → __admin__", False, str(e))
            return 1
        check("deployed __auth__ (IdP) + web/admin (RP)", True)

        # RP config + operator allowlist (the move-secret v2-kv seam).
        c.admin_kv_put("__admin__", "_oidc/rp/default", json.dumps({
            "issuer": auth_base, "client_id": "admin-dashboard",
            "redirect_uri": app_origin + "/_rp/callback",
            "post_login": "/", "operator_prefix": "_admin/operator/",
        }, separators=(",", ":")))
        c.admin_kv_put("__admin__", "_admin/operator/" + sha256_hex(OPERATOR), "")

        # Readiness (over TLS): RP /_rp/login → 302, IdP /login → 200.
        r = None
        for _ in range(60):
            r = c.tls_curl(app_origin + "/_rp/login?return_to=%2F")
            if r.status == 302:
                break
            time.sleep(0.4)
        check("__admin__ RP live (/_rp/login → 302)", r and r.status == 302,
              f"got {r.status if r else '-'} {r.body[:120] if r else ''!r}")
        rr = None
        for _ in range(40):
            rr = c.tls_curl(auth_base + "/login")
            if rr.status == 200:
                break
            time.sleep(0.25)
        check("__auth__ live over TLS (/login → 200)", rr and rr.status == 200,
              f"got {rr.status if rr else '-'}")
        if failures:
            c.dump_node_log(grep=["rp", "oidc", "deploy", "loader", "error", "warn"])
            print(f"\nFAILED: {failures}")
            return 1

        # Operator login → is_root:true.
        try:
            op_cookie = idp_login(c, email=OPERATOR, app_origin=app_origin,
                                  auth_base=auth_base)
            check("operator completed the OIDC RP handshake", True)
        except RuntimeError as e:
            check("operator completed the OIDC RP handshake", False, str(e)[:240])
            c.dump_node_log(grep=["rp", "oidc", "token", "jwks", "send", "fetch",
                                  "door", "error", "warn"])
            print(f"\nFAILED: {failures}")
            return 1
        r = c.tls_curl(app_origin + "/v1/session", headers={"Cookie": op_cookie})
        who = json.loads(r.body) if r.status == 200 else {}
        check("operator session is_root=true (sub=operator)",
              r.status == 200 and who.get("is_root") is True and who.get("sub") == OPERATOR,
              f"got {r.status} {who}")

        # Non-operator login → is_root:false.
        try:
            cust_cookie = idp_login(c, email=CUSTOMER, app_origin=app_origin,
                                    auth_base=auth_base)
            r = c.tls_curl(app_origin + "/v1/session", headers={"Cookie": cust_cookie})
            who = json.loads(r.body) if r.status == 200 else {}
            check("non-operator session is_root=false",
                  r.status == 200 and who.get("is_root") is False,
                  f"got {r.status} {who}")
        except RuntimeError as e:
            check("non-operator completed the OIDC RP handshake", False, str(e)[:240])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — operator (is_root) + non-operator completed OIDC RP login "
          "against __auth__ over TLS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
