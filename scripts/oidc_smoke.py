#!/usr/bin/env python3
"""Phase 3 conformance gate — the only behavioral proof of the whole
OIDC chain (auth-domain-plan.md §4).

A scripted relying party drives the real flow against the deployed
`__auth__` IdP:

  /.well-known/openid-configuration  → host-relative iss
  POST /login (no resend key → magic_link in JSON)
  GET  /login/verify?mt=…            → binds the per-request sid
  GET  /authorize (PKCE S256)        → 302 ?code=
  POST /token (code + verifier)      → id_token (RS256)
  GET  /.well-known/jwks.json        → verify the id_token signature

then: refresh-token grant, the §0 host-relative invariant (iss reflects
a *different* Host), and the §4.6 rotation state machine (next →
current → retiring, id_token still verifies across a promotion).

The RS256 signature is verified with a self-contained pure-Python
RSASSA-PKCS1-v1_5 check (no `cryptography` dependency) — that
verification IS the gate: it proves crypto.oidcSign + the JWKS + the
whole assembly are correct end-to-end.
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

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
CLIENT = "smoke-rp"
REDIRECT = "https://rp.smoke.test/cb"


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64url_dec(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


# SHA-256 DigestInfo prefix (RFC 8017 §9.2).
_SHA256_DI = bytes.fromhex("3031300d060960864801650304020105000420")


def verify_rs256(jwk: dict, signing_input: bytes, sig: bytes) -> bool:
    """Pure-Python RSASSA-PKCS1-v1_5 verify — no external dep. This is
    the gate: a real RS256 check against the published JWK."""
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


def loc(r) -> str:
    return r.headers.get("location", "")


def main() -> int:
    cluster = Cluster.spawn(
        tag="oidc-smoke",
        http_base=8295,
        raft_base=40395,
        files_port=8299,
        log_port=8300,
        root_token=TOKEN,
    )
    with cluster as c:
        c.discover_leader()
        origin = c.admin_origin()
        c.spawn_files_server(leader_url=origin)  # deploys web/{admin,replay,auth}

        sys_sfx = c.addrs.system_suffix
        port = c.leader_port()
        auth_host = f"auth.{sys_sfx}"
        auth = f"https://{auth_host}:{port}"
        cc = c.curl_ctx(auth_host, f"auth2.{sys_sfx}")

        # Readiness: poll GET /login — it renders the login form
        # WITHOUT touching oidc.provider()/_config, so it's 200 as
        # soon as the __auth__ bundle is deployed (discovery would
        # 500 until the config exists). __auth__ deploy lands a moment
        # after __replay__.
        for _ in range(80):
            r = curl(cc, auth + "/login")
            if r.status == 200:
                break
            time.sleep(0.25)
        expect_status("__auth__ deployed (GET /login)", 200, r)

        # Register the conformance client + shrunk rotation windows
        # at `_oidc/config/default` (a normal kv key — the IdP client
        # registry is operational data, admin-managed, NOT the
        # reserved `_config/` prefix; see oidc.js provider()). This is
        # exactly how a production operator registers RP clients.
        cfg = {
            "clients": [{"client_id": CLIENT, "redirect_uris": [REDIRECT]}],
            "login_path": "/login",
            "rotation_period_ms": 1500,
            "publish_window_ms": 1500,
            "retire_window_ms": 60000,
        }
        admin_h = {"Authorization": f"Bearer {TOKEN}", "X-Rove-Scope": "__auth__"}
        args = urllib.parse.quote(json.dumps(
            ["_oidc/config/default", json.dumps(cfg)]))
        r = curl(cc, f"{origin}/?fn=setKv&args={args}", headers=admin_h)
        expect_status("register client (admin setKv → __auth__)", 200, r)

        # Now discovery resolves (config present).
        r = curl(cc, auth + "/.well-known/openid-configuration")
        expect_status("discovery 200", 200, r)
        disc = json.loads(r.body)
        assert disc["issuer"] == auth, f"iss not host-relative: {disc['issuer']}"
        assert disc["id_token_signing_alg_values_supported"] == ["RS256"]
        assert disc["code_challenge_methods_supported"] == ["S256"]
        print(f"ok  discovery: host-relative iss={disc['issuer']}, RS256+S256")

        # PKCE
        verifier = b64url(os.urandom(32))
        challenge = b64url(hashlib.sha256(verifier.encode()).digest())
        state, nonce = "st-" + b64url(os.urandom(6)), "no-" + b64url(os.urandom(6))
        authorize = auth + "/authorize?" + urllib.parse.urlencode({
            "client_id": CLIENT, "redirect_uri": REDIRECT,
            "response_type": "code", "scope": "openid", "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256",
            "nonce": nonce,
        })

        # /login → magic_link (dev path: no resend key) + the sid cookie.
        r = curl(cc, auth + "/login", method="POST",
                 headers={"content-type": "application/x-www-form-urlencoded"},
                 data="email=alice@example.com&return_to=" +
                      urllib.parse.quote(authorize))
        expect_status("POST /login", 200, r)
        magic_link = json.loads(r.body)["magic_link"]
        sc = r.headers.get("set-cookie", "")
        m = re.search(r"__Host-rove_sid=[^;]+", sc)
        assert m, f"no __Host-rove_sid minted: {sc!r}"
        cookie = m.group(0)
        print("ok  POST /login → magic_link + sid cookie")

        # Follow the magic link (carry the sid) → binds session, 302s
        # back to /authorize.
        r = curl(cc, magic_link, headers={"Cookie": cookie})
        expect_status("GET /login/verify → 302", 302, r)
        assert loc(r) == authorize, f"verify didn't return to authorize: {loc(r)}"
        print("ok  magic-link verify binds sid, returns to /authorize")

        # /authorize (logged in) → 302 ?code=&state=
        r = curl(cc, authorize, headers={"Cookie": cookie})
        expect_status("GET /authorize → 302", 302, r)
        cb = urllib.parse.urlparse(loc(r))
        qs = urllib.parse.parse_qs(cb.query)
        assert loc(r).startswith(REDIRECT), f"bad redirect: {loc(r)}"
        assert qs.get("state") == [state], f"state mismatch: {qs}"
        code = qs["code"][0]
        print("ok  /authorize → code (state echoed)")

        def token_grant(form: dict, label: str):
            r = curl(cc, auth + "/token", method="POST",
                     headers={"content-type": "application/x-www-form-urlencoded"},
                     data=urllib.parse.urlencode(form))
            expect_status(label, 200, r)
            return json.loads(r.body)

        tok = token_grant({
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": REDIRECT, "client_id": CLIENT,
            "code_verifier": verifier,
        }, "POST /token (auth code + PKCE)")
        assert tok["token_type"] == "Bearer" and tok["id_token"] and \
            tok["refresh_token"], f"token resp shape: {tok}"

        def jwks():
            jr = curl(cc, auth + "/.well-known/jwks.json")
            expect_status("GET jwks", 200, jr)
            return {k["kid"]: k for k in json.loads(jr.body)["keys"]}

        def check_idtoken(id_token, label):
            hdr, claims, sig, si = parse_jwt(id_token)
            assert hdr["alg"] == "RS256", hdr
            keys = jwks()
            assert hdr["kid"] in keys, f"{label}: kid not in JWKS"
            assert verify_rs256(keys[hdr["kid"]], si, sig), \
                f"{label}: RS256 signature INVALID"
            assert claims["iss"] == auth, f"{label}: iss {claims['iss']}"
            assert claims["aud"] == CLIENT, f"{label}: aud {claims['aud']}"
            assert claims["nonce"] == nonce, f"{label}: nonce"
            assert claims["sub"] == "alice@example.com", f"{label}: sub"
            assert claims["exp"] > time.time(), f"{label}: expired"
            return hdr["kid"]

        kid0 = check_idtoken(tok["id_token"], "auth-code id_token")
        print(f"ok  id_token RS256-verifies against JWKS (kid={kid0[:12]}…)")

        # Refresh-token grant.
        tok2 = token_grant({
            "grant_type": "refresh_token",
            "refresh_token": tok["refresh_token"], "client_id": CLIENT,
        }, "POST /token (refresh)")
        check_idtoken(tok2["id_token"], "refreshed id_token")
        print("ok  refresh_token grant → fresh id_token verifies")

        # §0 host-relative: same IdP on a DIFFERENT host → iss reflects
        # it (no compiled-in domain).
        a2 = urllib.parse.quote(json.dumps([f"auth2.{sys_sfx}", "__auth__"]))
        r = curl(cc, f"{origin}/?fn=assignDomain&args={a2}", headers=admin_h)
        assert r.status in (200, 201), \
            f"assignDomain auth2 → __auth__: {r.status} {r.body[:200]}"
        print("ok  assignDomain auth2 → __auth__")
        r = curl(cc, f"https://auth2.{sys_sfx}:{port}"
                     "/.well-known/openid-configuration")
        expect_status("discovery on 2nd host", 200, r)
        iss2 = json.loads(r.body)["issuer"]
        assert iss2 == f"https://auth2.{sys_sfx}:{port}", \
            f"§0 violated — iss not host-relative: {iss2}"
        print(f"ok  §0 host-relative: 2nd host → iss={iss2}")

        # §4.6 rotation: deadline-gated _advance via a direct rotate
        # POST (benign + deterministic — same handler the scheduler
        # fires). period=1500ms: after it, a `next` appears; after the
        # publish window, it's promoted and the old key goes retiring
        # (still in JWKS → pre-rotation tokens still verify).
        def rotate():
            curl(cc, auth + "/_oidc/rotate", method="POST", data="")

        assert len(jwks()) == 1, "genesis should have 1 key"
        time.sleep(2.0)
        rotate()
        assert len(jwks()) == 2, "rotation should introduce a `next` key"
        print("ok  §4.6: `next` key introduced after rotation_period")
        time.sleep(2.0)
        rotate()
        keys_after = jwks()
        assert kid0 in keys_after, "old key must stay (retiring) for live tokens"
        # A fresh login→token now signs with the promoted current key.
        # (Reuse: quickest path is the refresh grant — it signs with
        # whatever is current now.)
        tok3 = token_grant({
            "grant_type": "refresh_token",
            "refresh_token": tok2["refresh_token"], "client_id": CLIENT,
        }, "POST /token (post-rotation refresh)")
        kid_new = check_idtoken(tok3["id_token"], "post-rotation id_token")
        assert kid_new != kid0, f"signing key didn't rotate ({kid_new})"
        # The OLD id_token still verifies (its kid is still published).
        check_idtoken(tok["id_token"], "pre-rotation id_token (retiring key)")
        print(f"ok  §4.6: promoted (kid {kid0[:8]}…→{kid_new[:8]}…); "
              "old token still verifies")

        print("\nall OIDC conformance checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
