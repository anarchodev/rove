#!/usr/bin/env python3
"""Teams: shared account ownership + email invites on the standing __admin__ app.

Stands up __auth__ (IdP) + the teams-enabled __admin__ app on a TLS V2 cluster,
logs in three customer emails via the dev magic-link seam, and proves the teams
backend end-to-end through the REAL dispatch + _middlewares OIDC guard + raft:

  - personal provision + the new whoami account shape
  - createAccount + the per-user team cap (MAX_TEAM_ACCOUNTS)
  - inviteMember (dev accept_url seam) → acceptInvite (email-bound, single-use)
  - a member provisions into the SHARED account (per-account plan limit)
  - cross-account security denials (delete / scoped + unscoped kv)
  - role transfer (setMemberRole) + leaveAccount (last-owner / personal guards)
  - a durable membership row read back via /_system/v2-kv (raft replication)

Run:
  zig build rewind-worker rewind-cp rewind-front
  set -a; . ./.env; set +a
  REWIND_APPS_DIR=/home/user/src/rewind-apps/.claude/worktrees/teams \
    python3 <this file>
Ports: http_base 19400 (PID-nudged); TLS front at base+54.
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

from smoke_lib_v2 import V2Cluster, APPS_DIR  # noqa: E402

ALICE = "alice@example.com"
BOB = "bob@example.com"
CAROL = "carol@example.com"


def user_hash(email: str) -> str:
    return hashlib.sha256(email.strip().lower().encode()).hexdigest()


def _sid(r) -> str | None:
    m = re.search(r"__Host-rove_sid=[^;]+", r.headers.get("set-cookie", ""))
    return m.group(0) if m else None


def idp_login(c: V2Cluster, *, email: str, app_origin: str, auth_base: str) -> str:
    """Drive the full OIDC RP handshake as `email` over the TLS front; return the
    app `__Host-rove_sid` cookie. (Lifted from oidc_rp_smoke_v2.py.)"""
    def absll(base, loc):
        return loc if loc.startswith("http") else base + loc

    r = c.tls_curl(app_origin + "/_rp/login?return_to=" + urllib.parse.quote("/"))
    if r.status != 302:
        raise RuntimeError(f"/_rp/login {r.status}: {r.body[:200]}")
    app_cookie = _sid(r)
    authorize = r.headers.get("location", "")
    if not app_cookie:
        raise RuntimeError(f"/_rp/login minted no app sid: {r.headers}")

    r = c.tls_curl(authorize)
    if r.status != 302:
        raise RuntimeError(f"/authorize#1 {r.status}: {r.body[:200]}")
    auth_cookie = _sid(r)
    login_loc = absll(auth_base, r.headers.get("location", ""))
    return_to = urllib.parse.parse_qs(urllib.parse.urlparse(login_loc).query)["return_to"][0]

    r = c.tls_curl(auth_base + "/login", method="POST",
                   headers={"content-type": "application/x-www-form-urlencoded",
                            "Cookie": auth_cookie},
                   data="email=" + urllib.parse.quote(email) +
                        "&return_to=" + urllib.parse.quote(return_to))
    if r.status != 200:
        raise RuntimeError(f"/login {r.status}: {r.body[:200]}")
    magic = json.loads(r.body)["magic_link"]

    r = c.tls_curl(magic, headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"/login/verify {r.status}: {r.body[:200]}")

    r = c.tls_curl(absll(auth_base, r.headers.get("location", "")),
                   headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"/authorize#2 {r.status}: {r.body[:200]}")
    callback = r.headers.get("location", "")

    r = c.tls_curl(callback, headers={"Cookie": app_cookie})
    if r.status != 202:
        raise RuntimeError(f"/_rp/callback {r.status}: {r.body[:200]}")

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

    auth_src = (APPS_DIR / "auth/index.mjs").read_text()
    auth_cfg = (APPS_DIR / "auth/_config/oidc/default.json").read_text()
    admin_files = {p: (APPS_DIR / "admin" / p).read_text() for p in
                   ("index.mjs", "_middlewares/index.mjs",
                    "_rp/complete.mjs", "_rp/jwks.mjs", "v1/upload/index.mjs")}

    print("=== teams: shared ownership + invites on __admin__ ===")
    with V2Cluster.spawn("teams", nodes=1, http_base=19400, raft_base=19500,
                         tls_idp=True) as c:
        app_origin = c.tls_origin("__admin__")
        auth_base = c.tls_origin("__auth__")

        c._ensure_admin_app()
        c.provision("__auth__")
        c.deploy_with_static(
            "__auth__", {"index.mjs": auth_src},
            {"_config/oidc/default.json": (auth_cfg, "application/json")})
        c.admin_kv_put("__auth__", "_oidc/config/default", json.dumps({
            "clients": [{"client_id": "admin-dashboard",
                         "redirect_uris": [app_origin + "/_rp/callback"]}],
            "login_path": "/login"}, separators=(",", ":")))
        c.deploy_handlers("__admin__", admin_files)
        c.admin_kv_put("__admin__", "_oidc/rp/default", json.dumps({
            "issuer": auth_base, "client_id": "admin-dashboard",
            "redirect_uri": app_origin + "/_rp/callback",
            "post_login": "/", "operator_prefix": "_admin/operator/"},
            separators=(",", ":")))

        # Readiness over TLS.
        r = None
        for _ in range(60):
            r = c.tls_curl(app_origin + "/_rp/login?return_to=%2F")
            if r.status == 302:
                break
            time.sleep(0.4)
        check("__admin__ RP live (/_rp/login → 302)", r and r.status == 302,
              f"got {r.status if r else '-'}")
        rr = None
        for _ in range(40):
            rr = c.tls_curl(auth_base + "/login")
            if rr.status == 200:
                break
            time.sleep(0.25)
        check("__auth__ live (/login → 200)", rr and rr.status == 200,
              f"got {rr.status if rr else '-'}")
        if failures:
            c.dump_node_log(grep=["rp", "oidc", "deploy", "loader", "error", "warn"])
            print(f"\nFAILED: {failures}")
            return 1

        # REST helper bound to this cluster.
        def req(cookie, method, path, payload=None):
            h = {"Cookie": cookie}
            data = None
            if payload is not None:
                h["content-type"] = "application/json"
                data = json.dumps(payload)
            return c.tls_curl(app_origin + path, method=method, headers=h,
                              data=data, timeout=30.0)

        def body(r):
            try:
                return json.loads(r.body)
            except Exception:
                return {}

        # Log in three distinct customer emails.
        try:
            alice = idp_login(c, email=ALICE, app_origin=app_origin, auth_base=auth_base)
            bob = idp_login(c, email=BOB, app_origin=app_origin, auth_base=auth_base)
            carol = idp_login(c, email=CAROL, app_origin=app_origin, auth_base=auth_base)
            check("three customers completed OIDC login", True)
        except RuntimeError as e:
            check("OIDC login", False, str(e)[:240])
            c.dump_node_log(grep=["rp", "oidc", "token", "jwks", "send", "fetch", "error"])
            print(f"\nFAILED: {failures}")
            return 1

        # ── whoami account shape + personal provision ──────────────────────
        who = body(req(alice, "GET", "/v1/session"))
        personal = who.get("active_account")
        check("alice whoami: sub + accounts + active_account",
              who.get("sub") == ALICE and who.get("is_root") is False and
              isinstance(who.get("accounts"), list) and bool(personal),
              f"{who}")
        check("alice personal account present",
              any(a.get("is_personal") and a.get("aid") == personal
                  for a in who.get("accounts", [])))
        check("POST /v1/instances (personal) → 201",
              req(alice, "POST", "/v1/instances", {"name": "t1"}).status == 201)

        # ── createAccount + team cap ───────────────────────────────────────
        r = req(alice, "POST", "/v1/accounts", {"name": "Acme"})
        acme = body(r).get("aid")
        check("POST /v1/accounts (Acme) → 201 + aid", r.status == 201 and bool(acme),
              f"got {r.status} {r.body[:120]!r}")
        check("2nd account → 201", req(alice, "POST", "/v1/accounts", {"name": "Two"}).status == 201)
        r = req(alice, "POST", "/v1/accounts", {"name": "Three"})
        check("past cap → 403 team_limit_reached",
              r.status == 403 and body(r).get("error") == "team_limit_reached",
              f"got {r.status} {r.body[:120]!r}")

        # ── invite + accept (email-bound, single-use) ──────────────────────
        r = req(alice, "POST", f"/v1/accounts/{acme}/invites", {"email": "BOB@example.com"})
        accept_url = body(r).get("accept_url")
        check("POST invites → 200 + dev accept_url", r.status == 200 and bool(accept_url),
              f"got {r.status} {r.body[:160]!r}")
        token = accept_url.split("/#/invite/")[1] if accept_url else ""
        check("carol cannot accept bob's invite → 403",
              req(carol, "POST", "/v1/invites/accept", {"token": token}).status == 403)
        check("bob accepts invite → 200",
              req(bob, "POST", "/v1/invites/accept", {"token": token}).status == 200)
        check("reused invite token → 404",
              req(bob, "POST", "/v1/invites/accept", {"token": token}).status == 404)
        # durable membership row replicated (read back via the move-secret kv door)
        kr = c.admin_kv_get("__admin__", f"account/{acme}/members/{user_hash(BOB)}")
        check("bob's member row durable in __admin__ kv",
              kr.status == 200 and "member" in kr.body, f"got {kr.status} {kr.body[:80]!r}")
        whob = body(req(bob, "GET", "/v1/session"))
        check("bob whoami shows acme membership (role=member)",
              any(a.get("aid") == acme and a.get("role") == "member"
                  for a in whob.get("accounts", [])), f"{whob.get('accounts')}")

        # ── member provisions into the shared account + plan limit ─────────
        r = req(bob, "POST", "/v1/instances", {"name": "tacme", "account": acme})
        check("member provisions into shared account → 201", r.status == 201,
              f"got {r.status} {r.body[:120]!r}")
        r = req(bob, "POST", "/v1/instances", {"name": "tacme2", "account": acme})
        check("2nd provision into acme → 403 (free plan limit)",
              r.status == 403 and body(r).get("error") == "account_limit_reached",
              f"got {r.status}")

        # ── cross-account security denials ─────────────────────────────────
        check("member (bob) GET instance → not 4xx",
              req(bob, "GET", "/v1/instances/tacme").status not in (401, 403, 404))
        check("non-member (carol) DELETE shared tenant → 403",
              req(carol, "DELETE", "/v1/instances/tacme").status == 403)
        check("non-member (carol) scoped kv → 403",
              req(carol, "GET", "/v1/instances/tacme/kv?key=k").status == 403)
        check("member (bob) scoped kv → not 403",
              req(bob, "GET", "/v1/instances/tacme/kv?key=k").status != 403)
        check("non-root browsing __admin__ kv → 403",
              req(carol, "GET", "/v1/instances/__admin__/kv?key=secret").status == 403)

        # ── owner-only gates + already-member ──────────────────────────────
        check("non-member (carol) GET members → 403",
              req(carol, "GET", f"/v1/accounts/{acme}/members").status == 403)
        members = body(req(alice, "GET", f"/v1/accounts/{acme}/members")).get("members", [])
        check("GET members shows alice(owner)+bob(member)",
              any(m.get("role") == "owner" for m in members) and
              any(m.get("role") == "member" for m in members), f"{members}")
        check("re-invite existing member → 409 already_member",
              req(alice, "POST", f"/v1/accounts/{acme}/invites", {"email": BOB}).status == 409)

        # ── role transfer + leave guards ───────────────────────────────────
        check("sole owner cannot leave → 409",
              req(alice, "POST", f"/v1/accounts/{acme}/leave").status == 409)
        check("promote bob to owner → 200",
              req(alice, "PUT", f"/v1/accounts/{acme}/members/{user_hash(BOB)}",
                  {"role": "owner"}).status == 200)
        check("alice leaves after transfer → 204",
              req(alice, "POST", f"/v1/accounts/{acme}/leave").status == 204)
        check("cannot demote last owner → 409",
              req(bob, "PUT", f"/v1/accounts/{acme}/members/{user_hash(BOB)}",
                  {"role": "member"}).status == 409)
        check("cannot leave personal account → 400",
              req(alice, "POST", f"/v1/accounts/{personal}/leave").status == 400)

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — teams: shared ownership, tokened email invites (email-bound, "
          "single-use), member provisioning into a shared account, cross-account "
          "denials, role transfer + last-owner/personal guards — all through the "
          "real OIDC dispatch + raft.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
