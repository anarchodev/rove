#!/usr/bin/env python3
"""rewind customer CLI gateway flow (rewind-cli-plan Track 3).

Proves the `rewind` customer CLI's auth model end-to-end at the protocol
level — the gateway / session-bearer design (step3-auth-plan.md cap-mint
fork, resolved to gateway):

  1. device grant — the CLI POSTs __auth__ /device_authorization → a
     device_code + short user_code (RFC 8628, the headless CLI flow).
  2. human approve — the customer logs in to the IdP and approves the
     code at the login-gated /device confirm page (scripted here).
  3. token poll — the CLI polls __auth__ /token with the device_code →
     an id_token once approved.
  4. EXCHANGE — the CLI POSTs the id_token to the dashboard's
     /v1/cli/exchange; the RP verifies it against the IdP JWKS (async
     refetch the first time) and mints an RP session bound to the sid the
     platform minted on that request. The CLI captures the __Host-rove_sid
     cookie and polls /_rp/poll until authed — the SAME session a browser
     holds, no new authority surface.
  5. deploy/release — the CLI presents the session cookie to the
     ownership-gated /v1/deploy + publishRelease: deploying a tenant the
     customer OWNS → 200; a tenant they DON'T own → 403.

This exercises the SERVER side of the customer CLI (the novel, load-bearing
part). The `rewind` binary makes exactly these HTTP calls (cookie jar over
TLS); its literal end-to-end run against a TLS front is the one manual step.

Run: zig build rewind-worker rewind-cp rewind-front   (+ default build for rewind-logs)
     set -a; . ./.env; set +a
     python3 scripts/rewind_customer_smoke_v2.py
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

from smoke_lib_v2 import V2Cluster, REPO_ROOT, APPS_DIR  # noqa: E402

CUSTOMER = "dev@example.com"
CLIENT_ID = "admin-dashboard"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def _sid(r) -> str | None:
    m = re.search(r"__Host-rove_sid=[^;]+", r.headers.get("set-cookie", ""))
    return m.group(0) if m else None


def idp_session(c: V2Cluster, *, email: str, auth_base: str) -> str:
    """Magic-link login directly on the IdP; return the IdP `__Host-rove_sid`
    (a live IdP session, used to approve the device code). Dev path: no
    resend key → the magic link rides back in the /login JSON."""
    r = c.tls_curl(auth_base + "/login")
    auth_cookie = _sid(r)
    if not auth_cookie:
        raise RuntimeError(f"IdP /login minted no sid: {r.status} {r.headers}")
    r = c.tls_curl(auth_base + "/login", method="POST",
                   headers={"content-type": "application/x-www-form-urlencoded",
                            "Cookie": auth_cookie},
                   data="email=" + urllib.parse.quote(email) + "&return_to=%2F")
    if r.status != 200:
        raise RuntimeError(f"IdP /login {r.status}: {r.body[:200]}")
    magic = json.loads(r.body)["magic_link"]
    r = c.tls_curl(magic, headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"magic verify {r.status}: {r.body[:200]}")
    return auth_cookie


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    auth_src = (APPS_DIR / "auth/index.mjs").read_text()
    auth_cfg = (APPS_DIR / "auth/_config/oidc/default.json").read_text()
    admin_files = {p: (APPS_DIR / "admin" / p).read_text() for p in
                   ("index.mjs", "_middlewares/index.mjs",
                    "_rp/complete.mjs", "_rp/jwks.mjs")}

    print("=== rewind customer CLI gateway flow (Track 3) ===")
    with V2Cluster.spawn("rwcli", nodes=1, http_base=19960, raft_base=20060,
                         tls_idp=True) as c:
        app_origin = c.tls_origin("__admin__")
        auth_base = c.tls_origin("__auth__")
        c.spawn_log_server()

        # Stand up __auth__ (IdP) + web/admin (RP) — admin last (replaces the
        # baked deploy app). Same shape as oidc_rp_smoke_v2.
        c._ensure_admin_app()
        c.provision("__auth__")
        try:
            c.deploy_with_static(
                "__auth__", {"index.mjs": auth_src},
                {"_config/oidc/default.json": (auth_cfg, "application/json")})
        except RuntimeError as e:
            check("deploy web/auth → __auth__", False, str(e)); return 1
        c.admin_kv_put("__auth__", "_oidc/config/default", json.dumps({
            "clients": [{"client_id": CLIENT_ID,
                         "redirect_uris": [app_origin + "/_rp/callback"]}],
            "login_path": "/login",
        }, separators=(",", ":")))
        try:
            c.deploy_handlers("__admin__", admin_files)
        except RuntimeError as e:
            check("deploy web/admin → __admin__", False, str(e)); return 1
        c.admin_kv_put("__admin__", "_oidc/rp/default", json.dumps({
            "issuer": auth_base, "client_id": CLIENT_ID,
            "redirect_uri": app_origin + "/_rp/callback",
            "post_login": "/", "operator_prefix": "_admin/operator/",
        }, separators=(",", ":")))
        check("deployed __auth__ (IdP) + web/admin (RP)", True)

        # The customer OWNS `custapp` (provision it + seed the ownership row the
        # handler keys on — account/{sha256(sub)}/instances/{id}). They do NOT
        # own `other`.
        c.provision("custapp")
        c.provision("other")
        c.admin_kv_put("__admin__",
                       "account/" + sha256_hex(CUSTOMER) + "/instances/custapp", "")

        # Readiness.
        r = None
        for _ in range(60):
            r = c.tls_curl(app_origin + "/_rp/login?return_to=%2F")
            if r.status == 302:
                break
            time.sleep(0.4)
        check("__admin__ RP live", r and r.status == 302, f"got {r.status if r else '-'}")
        for _ in range(40):
            rr = c.tls_curl(auth_base + "/login")
            if rr.status == 200:
                break
            time.sleep(0.25)
        if failures:
            c.dump_node_log(grep=["rp", "oidc", "deploy", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1

        # ── 1. device grant: the CLI asks for codes. ──────────────────────
        r = c.tls_curl(auth_base + "/device_authorization", method="POST",
                       headers={"content-type": "application/x-www-form-urlencoded"},
                       data="client_id=" + CLIENT_ID + "&scope=openid")
        da = json.loads(r.body) if r.status == 200 else {}
        check("POST /device_authorization → device_code + user_code",
              r.status == 200 and da.get("device_code") and da.get("user_code"),
              f"got {r.status} {r.body[:160]!r}")
        if r.status != 200:
            c.dump_node_log(grep=["device", "oidc", "token", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1
        device_code, user_code = da["device_code"], da["user_code"]

        # Before approval, the token poll says authorization_pending.
        def poll_token():
            return c.tls_curl(auth_base + "/token", method="POST",
                              headers={"content-type": "application/x-www-form-urlencoded"},
                              data="grant_type=" + urllib.parse.quote(DEVICE_GRANT) +
                                   "&device_code=" + urllib.parse.quote(device_code) +
                                   "&client_id=" + CLIENT_ID)
        r = poll_token()
        pend = {}
        try: pend = json.loads(r.body)
        except Exception: pass
        check("token poll before approval → authorization_pending",
              pend.get("error") == "authorization_pending", f"got {r.status} {r.body[:120]!r}")

        # ── 2. human approve: customer logs in to the IdP + approves. ─────
        try:
            auth_cookie = idp_session(c, email=CUSTOMER, auth_base=auth_base)
        except RuntimeError as e:
            check("customer IdP login", False, str(e)[:200])
            c.dump_node_log(grep=["oidc", "login", "magic", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1
        r = c.tls_curl(auth_base + "/device", method="POST",
                       headers={"content-type": "application/x-www-form-urlencoded",
                                "Cookie": auth_cookie},
                       data="user_code=" + urllib.parse.quote(user_code) + "&action=approve")
        check("approve device at the confirm page → 200",
              r.status == 200 and "Approved" in r.body, f"got {r.status} {r.body[:120]!r}")

        # ── 3. token poll after approval → id_token. ──────────────────────
        id_token = None
        for _ in range(20):
            r = poll_token()
            if r.status == 200:
                try:
                    id_token = json.loads(r.body).get("id_token")
                except Exception:
                    pass
                if id_token:
                    break
            time.sleep(0.3)
        check("token poll after approval → id_token", bool(id_token),
              f"got {r.status} {r.body[:120]!r}")
        if not id_token:
            c.dump_node_log(grep=["device", "token", "oidc", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1

        # ── 4. EXCHANGE id_token → dashboard RP session. ──────────────────
        r = c.tls_curl(app_origin + "/v1/cli/exchange", method="POST",
                       headers={"content-type": "application/json"},
                       data=json.dumps({"id_token": id_token}), timeout=30.0)
        cli_cookie = _sid(r)
        check("POST /v1/cli/exchange → session sid + 200/202",
              r.status in (200, 202) and bool(cli_cookie),
              f"got {r.status} {r.body[:160]!r} cookie={bool(cli_cookie)}")
        if not cli_cookie:
            c.dump_node_log(grep=["exchange", "jwks", "rp", "oidc", "error", "warn"])
            print(f"\nFAILED: {failures}"); return 1
        # Poll until the (async JWKS) verify writes the session.
        authed = False
        for _ in range(60):
            r = c.tls_curl(app_origin + "/_rp/poll", headers={"Cookie": cli_cookie})
            if r.status == 200:
                try:
                    authed = bool(json.loads(r.body).get("authed"))
                except Exception:
                    pass
                if authed:
                    break
            time.sleep(0.25)
        check("CLI session established (poll → authed)", authed, f"last {r.body[:120]!r}")

        # whoami over the CLI session: customer (is_root false), owns custapp.
        r = c.tls_curl(app_origin + "/v1/session", headers={"Cookie": cli_cookie})
        who = json.loads(r.body) if r.status == 200 else {}
        check("CLI session whoami → customer + owns custapp",
              who.get("sub") == CUSTOMER and who.get("is_root") is False and
              "custapp" in (who.get("owned") or []), f"got {r.status} {who}")

        # ── 5. deploy + release via the CLI session (ownership-gated). ────
        TRIVIAL = "export default function(){ return 'from cli'; }"

        def cli_deploy(tenant):
            # Per-file workspace flow (reset → file → cut), the same the rewind
            # binary drives. The ownership gate fires on each op, so a non-owner
            # is refused at reset.
            hdrs = {"Cookie": cli_cookie, "content-type": "application/json"}

            def op(sub, body):
                return c.tls_curl(app_origin + "/v1/deploy/" + sub, method="POST",
                                  headers=hdrs, data=json.dumps(body), timeout=30.0)

            r = op("reset", {"tenant": tenant})
            if r.status != 200:
                return r  # auth failure (403/401) surfaces at the first op
            op("file", {"tenant": tenant, "kind": "handler",
                        "path": "index.mjs", "source": TRIVIAL})
            return op("cut", {"tenant": tenant})
        r = cli_deploy("custapp")
        dep_id = None
        try:
            p = json.loads(r.body)
            if r.status == 200 and p.get("ok"):
                dep_id = p.get("dep_id")
        except Exception:
            pass
        check("CLI deploy own tenant (custapp) → 200 + dep_id", bool(dep_id),
              f"got {r.status} {r.body[:160]!r}")
        if not dep_id:
            c.dump_node_log(grep=["deploy", "compile", "stamp", "auth", "error", "warn"])

        if dep_id:
            r = c.tls_curl(app_origin + "/v1/instances/custapp/release", method="POST",
                           headers={"Cookie": cli_cookie, "content-type": "application/json"},
                           data=json.dumps({"dep_id": int(dep_id, 16)}))
            check("CLI release own tenant → 202 queued", r.status == 202,
                  f"got {r.status} {r.body[:120]!r}")

        # The CLI cannot deploy a tenant the customer does not own.
        r = cli_deploy("other")
        check("CLI deploy non-owned tenant (other) → 403", r.status == 403,
              f"got {r.status} {r.body[:120]!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — rewind customer CLI gateway: device grant → approve → token "
          "→ exchange → ownership-gated deploy/release. No new authority surface.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
