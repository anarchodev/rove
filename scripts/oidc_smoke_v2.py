#!/usr/bin/env python3
"""Stand up the `__auth__` OIDC IdP on a V2 cluster and verify the IdP
conformance end to end (step3-auth-plan.md B1). V2 port of the IdP-conformance
half of the (V1, retired) scripts/oidc_smoke.py.

What it proves:
  - the real `web/auth` app deploys to a provisioned `__auth__` tenant and its
    `_config/oidc/default.json` template config-mirrors into kv on release;
  - OIDC discovery is served and host-relative (`iss == https://{host}`, RS256,
    S256);
  - the magic-link login binds the platform session, and the full PKCE
    authorization-code flow yields an id_token whose RS256 signature verifies
    against the published JWKS (a pure-Python check — that verify IS the gate);
  - the refresh_token grant yields a fresh, verifying id_token.

The RP-gate half (admin dashboard logging in against __auth__) belongs to
Track B's dashboard bring-up (B2), not here — this stands up the IdP itself.

Run (full topology + S3):
    zig build rewind-worker rewind-cp rewind-front
    set -a; . ./.env; set +a
    python3 scripts/oidc_smoke_v2.py

Ports: http_base 19700 (PID-nudged).
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, REPO_ROOT  # noqa: E402

AUTH_HOST = f"__auth__.{PUBLIC_SUFFIX}"          # wildcard-routed to __auth__
ISS = f"https://{AUTH_HOST}"                      # host-relative issuer
CLIENT = "smoke-rp"
REDIRECT = "https://rp.smoke.test/cb"
LOGIN_EMAIL = "alice@example.com"


# ── pure-Python RS256 verify (no `cryptography` dep — the verify IS the gate) ─
def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64url_dec(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


_SHA256_DI = bytes.fromhex("3031300d060960864801650304020105000420")


def verify_rs256(jwk: dict, signing_input: bytes, sig: bytes) -> bool:
    n = int.from_bytes(b64url_dec(jwk["n"]), "big")
    e = int.from_bytes(b64url_dec(jwk["e"]), "big")
    k = (n.bit_length() + 7) // 8
    m = pow(int.from_bytes(sig, "big"), e, n)
    em = m.to_bytes(k, "big")
    h = hashlib.sha256(signing_input).digest()
    expected = b"\x00\x01" + b"\xff" * (k - len(_SHA256_DI) - len(h) - 3) + \
        b"\x00" + _SHA256_DI + h
    return em == expected


def parse_jwt(tok: str):
    h_b, p_b, s_b = tok.split(".")
    return (json.loads(b64url_dec(h_b)), json.loads(b64url_dec(p_b)),
            b64url_dec(s_b), (h_b + "." + p_b).encode())


def path_of(url: str) -> str:
    """The path+query of an absolute IdP URL — to re-issue it through the front
    door with an explicit Host header (the smoke reaches the IdP at the front's
    loopback port, not its advertised https host)."""
    u = urllib.parse.urlparse(url)
    return u.path + (("?" + u.query) if u.query else "")


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    auth_src = (REPO_ROOT / "web/auth/index.mjs").read_text()
    auth_cfg = (REPO_ROOT / "web/auth/_config/oidc/default.json").read_text()

    print("=== stand up __auth__ + OIDC conformance ===")
    with V2Cluster.spawn("oidc", nodes=1, http_base=19700, raft_base=19800) as c:
        # Reach the IdP through the front door with an explicit Host header.
        def idp(path, **kw):
            return c.request("__auth__", path, host=AUTH_HOST, **kw)

        # 1. Provision + deploy the real web/auth app (handler + config static).
        r = c.provision("__auth__")
        check("provision __auth__ → 204/409", r.status in (204, 409),
              f"got {r.status} {r.body!r}")
        try:
            c.deploy_with_static(
                "__auth__",
                {"index.mjs": auth_src},
                {"_config/oidc/default.json": (auth_cfg, "application/json")})
        except RuntimeError as e:
            check("deploy web/auth → __auth__", False, str(e))
            print(f"\nFAILURES: {failures}")
            return 1
        check("deploy web/auth → __auth__", True)

        # Readiness: GET /login renders without touching oidc.provider().
        # host_for("__auth__") == AUTH_HOST, so the poller hits the IdP directly.
        ready = c.wait_for_handler("__auth__", "/login", want_status=200,
                                   timeout_s=30.0)
        check("__auth__ live (GET /login → 200)", ready.status == 200,
              f"got {ready.status} {ready.body[:120]!r}")

        # Register a conformance client + shrink nothing (no rotation here) via
        # the move-secret-gated v2-kv seam — `_oidc/config/default` wins over the
        # mirrored `_config/oidc/default` template. Keep admin-dashboard so the
        # template path stays exercised.
        cfg = json.dumps({
            "clients": [
                {"client_id": "admin-dashboard",
                 "redirect_uris": ["https://app.${ISSUER_PARENT}/_rp/callback"]},
                {"client_id": CLIENT, "redirect_uris": [REDIRECT]},
            ],
            "login_path": "/login",
        }, separators=(",", ":"))
        r = c.admin_kv_put("__auth__", "_oidc/config/default", cfg)
        check("seed _oidc/config/default (v2-kv) → 204", r.status == 204,
              f"got {r.status} {r.body!r}")

        # 2. Discovery — host-relative issuer, RS256 + S256.
        r = idp("/.well-known/openid-configuration")
        ok = r.status == 200
        disc = json.loads(r.body) if ok else {}
        check("discovery → 200, host-relative iss, RS256+S256",
              ok and disc.get("issuer") == ISS and
              disc.get("id_token_signing_alg_values_supported") == ["RS256"] and
              disc.get("code_challenge_methods_supported") == ["S256"],
              f"got {r.status} iss={disc.get('issuer')!r}")

        # 3. PKCE authorization-code flow.
        verifier = b64url(os.urandom(32))
        challenge = b64url(hashlib.sha256(verifier.encode()).digest())
        state = "st-" + b64url(os.urandom(6))
        nonce = "no-" + b64url(os.urandom(6))
        authorize = "/authorize?" + urllib.parse.urlencode({
            "client_id": CLIENT, "redirect_uri": REDIRECT,
            "response_type": "code", "scope": "openid", "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256",
            "nonce": nonce,
        })

        # POST /login → magic link + the platform session cookie.
        r = idp("/login", method="POST",
                headers={"content-type": "application/x-www-form-urlencoded"},
                data="email=" + LOGIN_EMAIL + "&return_to=" +
                     urllib.parse.quote(ISS + authorize))
        magic_link = json.loads(r.body).get("magic_link", "") if r.status == 200 else ""
        m = re.search(r"__Host-rove_sid=[^;]+", r.headers.get("set-cookie", ""))
        check("POST /login → magic_link + sid cookie",
              r.status == 200 and bool(magic_link) and bool(m),
              f"got {r.status} cookie={bool(m)}")
        if not (magic_link and m):
            print(f"\nFAILURES: {failures}")
            return 1
        cookie = m.group(0)

        # GET /login/verify → 302 back to /authorize (sid now bound to alice).
        r = idp(path_of(magic_link), headers={"Cookie": cookie})
        check("magic-link verify → 302 back to /authorize",
              r.status == 302 and path_of(r.headers.get("location", "")) ==
              path_of(ISS + authorize),
              f"got {r.status} loc={r.headers.get('location','')!r}")

        # GET /authorize (session) → 302 to redirect_uri?code=…&state=…
        r = idp(authorize, headers={"Cookie": cookie})
        locn = r.headers.get("location", "")
        cbq = urllib.parse.parse_qs(urllib.parse.urlparse(locn).query)
        code = cbq.get("code", [""])[0]
        check("/authorize → 302 code (state echoed)",
              r.status == 302 and locn.startswith(REDIRECT) and
              cbq.get("state") == [state] and bool(code),
              f"got {r.status} loc={locn!r}")
        if not code:
            print(f"\nFAILURES: {failures}")
            return 1

        # POST /token (auth code + PKCE) → id_token.
        def token_grant(form):
            return idp("/token", method="POST",
                       headers={"content-type": "application/x-www-form-urlencoded"},
                       data=urllib.parse.urlencode(form))

        tr = token_grant({
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": REDIRECT, "client_id": CLIENT,
            "code_verifier": verifier,
        })
        tok = json.loads(tr.body) if tr.status == 200 else {}
        check("POST /token (code+PKCE) → id_token + refresh_token",
              tr.status == 200 and tok.get("id_token") and tok.get("refresh_token"),
              f"got {tr.status} {tr.body[:160]!r}")
        if tr.status != 200:
            print(f"\nFAILURES: {failures}")
            return 1

        def jwks():
            jr = idp("/.well-known/jwks.json")
            return {k["kid"]: k for k in json.loads(jr.body)["keys"]}

        def verify_idtoken(id_token, label):
            hdr, claims, sig, si = parse_jwt(id_token)
            keys = jwks()
            ok = (hdr["alg"] == "RS256" and hdr["kid"] in keys and
                  verify_rs256(keys[hdr["kid"]], si, sig) and
                  claims["iss"] == ISS and claims["aud"] == CLIENT and
                  claims["nonce"] == nonce and claims["sub"] == LOGIN_EMAIL and
                  claims["exp"] > time.time())
            check(label, ok,
                  f"alg={hdr.get('alg')} iss={claims.get('iss')!r} sub={claims.get('sub')!r}")
            return hdr["kid"]

        verify_idtoken(tok["id_token"], "id_token RS256-verifies against JWKS")

        # 4. refresh_token grant → fresh, verifying id_token.
        tr2 = token_grant({
            "grant_type": "refresh_token",
            "refresh_token": tok["refresh_token"], "client_id": CLIENT,
        })
        tok2 = json.loads(tr2.body) if tr2.status == 200 else {}
        if tr2.status == 200 and tok2.get("id_token"):
            verify_idtoken(tok2["id_token"], "refresh grant → fresh id_token verifies")
        else:
            check("refresh grant → fresh id_token verifies", False,
                  f"got {tr2.status} {tr2.body[:160]!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — __auth__ IdP stood up: discovery + magic-link + PKCE "
          "authorization-code + refresh, id_token RS256-verified against JWKS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
