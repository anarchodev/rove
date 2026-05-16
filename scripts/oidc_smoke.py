#!/usr/bin/env python3
"""Phase 3 gate — the behavioral proof of the whole OIDC chain AND the
Fork-B relying-party cutover (auth-domain-plan.md §4.7 "3-6 part 2").

Two halves, one spawned cluster:

1. RP gate. Admin is a pure OIDC relying party (no rove_session
   cookie, no Bearer human path). `smoke_lib.idp_login` drives the
   real browser-shaped handshake: app /_rp/login → IdP /authorize →
   magic-link → /_rp/callback → poll. An operator email (seeded into
   the `_admin/operator/*` allowlist via --bootstrap-kv) ⇒
   is_root:true; a non-operator email ⇒ is_root:false, owns nothing,
   and provisionInstance creates its first instance. The IdP
   `admin-dashboard` client is the config-mirrored
   web/auth/_config/oidc/default.json template with the §0
   `${ISSUER_PARENT}` redirect — NO hand-registration (proves the
   prod path).

2. OIDC conformance. With an operator RP session we register a
   `smoke-rp` client + shrunk rotation windows into __auth__'s
   `_oidc/config/default` and drive discovery → /authorize(PKCE) →
   /token → id_token, verifying the RS256 signature with a
   self-contained pure-Python RSASSA-PKCS1-v1_5 check (no
   `cryptography` dep — that verify IS the gate), plus refresh, the
   §0 host-relative invariant, and the §4.6 rotation state machine.
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

from smoke_lib import Cluster, curl, expect_status, idp_login  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
OPERATOR_EMAIL = "operator@example.com"
CUSTOMER_EMAIL = "customer@example.com"
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


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


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
        origin = c.admin_origin()                 # https://app.<sfx>:<port>
        sys_sfx = c.addrs.system_suffix
        port = c.leader_port()
        auth_host = f"auth.{sys_sfx}"
        auth = f"https://{auth_host}:{port}"       # IdP base

        # Seed the admin RP config + operator allowlist into __admin__
        # via the established --bootstrap-kv → postAdminKv → raft seam
        # (the same channel rove-loop46-serve.sh uses in prod). The
        # IdP `admin-dashboard` client itself comes from the
        # config-mirrored web/auth/_config/oidc/default.json — NOT
        # seeded here (that's the point: the prod path).
        rp_cfg = json.dumps({
            "issuer": auth,
            "client_id": "admin-dashboard",
            "redirect_uri": f"{origin}/_rp/callback",
            "post_login": "/",
            "operator_prefix": "_admin/operator/",
        }, separators=(",", ":"))
        c.spawn_files_server(leader_url=origin, extra_args=[
            "--bootstrap-kv", "_oidc/rp/default=" + rp_cfg,
            "--bootstrap-kv", f"_admin/operator/{sha256_hex(OPERATOR_EMAIL)}=",
        ])

        cc = c.curl_ctx(auth_host, f"auth2.{sys_sfx}")

        # Readiness: GET /login renders without touching
        # oidc.provider()/_config, so it's 200 as soon as __auth__ is
        # deployed (a moment after __replay__).
        for _ in range(80):
            r = curl(cc, auth + "/login")
            if r.status == 200:
                break
            time.sleep(0.25)
        expect_status("__auth__ deployed (GET /login)", 200, r)

        # DEBUG: discovery iss (shows the IdP's request.host incl port)
        # + the RP redirect we seeded, so a redirect mismatch is legible.
        dr = curl(cc, auth + "/.well-known/openid-configuration")
        print(f"DEBUG discovery {dr.status} iss="
              f"{json.loads(dr.body).get('issuer') if dr.status==200 else dr.body[:200]}")
        print(f"DEBUG seeded rp redirect_uri={origin}/_rp/callback")

        # ── 1. RP GATE ────────────────────────────────────────────────

        # Operator: in the allowlist ⇒ is_root. No Bearer, no
        # hand-registered client — the mirrored template's
        # admin-dashboard client (§0 ${ISSUER_PARENT} redirect) must
        # resolve to THIS deployment's app host.
        op_cookie = idp_login(cc, email=OPERATOR_EMAIL,
                              app_origin=origin, auth_base=auth)
        print("ok  operator completed the OIDC RP handshake (no Bearer)")
        op_h = {"Cookie": op_cookie}

        r = curl(cc, f"{origin}/v1/session", headers=op_h)
        expect_status("operator GET /v1/session", 200, r)
        who = json.loads(r.body)
        assert who["is_root"] is True, f"operator not is_root: {who}"
        assert who["sub"] == OPERATOR_EMAIL, f"sub: {who}"
        print(f"ok  operator session is_root=true (sub={who['sub']})")

        # Non-operator: same flow, NOT in the allowlist ⇒ no root,
        # owns nothing → must provision.
        cust_cookie = idp_login(cc, email=CUSTOMER_EMAIL,
                                app_origin=origin, auth_base=auth)
        cust_h = {"Cookie": cust_cookie}
        r = curl(cc, f"{origin}/v1/session", headers=cust_h)
        expect_status("customer GET /v1/session", 200, r)
        who = json.loads(r.body)
        assert who["is_root"] is False, f"customer must NOT be root: {who}"
        assert who["owned"] == [], f"customer should own nothing yet: {who}"
        print("ok  non-operator session is_root=false, owns nothing")

        prov = urllib.parse.quote(json.dumps(["custacme"]))
        r = curl(cc, f"{origin}/?fn=provisionInstance&args={prov}",
                 headers=cust_h)
        assert r.status in (200, 201), \
            f"provisionInstance: {r.status} {r.body[:200]}"
        r = curl(cc, f"{origin}/v1/session", headers=cust_h)
        who = json.loads(r.body)
        assert who["owned"] == ["custacme"], \
            f"owned should reflect the new instance: {who}"
        assert who["is_root"] is False, "provisioning must not grant root"
        print("ok  non-operator provisioned its first instance (still not root)")

        # ── §9 regression: deploy-time config mirror on the RELEASE
        # path (the 7eb70ed bug). The mirrored _config/oidc/default
        # now carries the §0 ${ISSUER_PARENT} template (NOT a
        # hardcoded prod literal). Read it back via the operator
        # session (admin getKv, X-Rove-Scope __auth__ → platform.scope
        # post-3a). Reserved prefix is a *write* guard; reads allowed.
        gk = urllib.parse.quote(json.dumps(["_config/oidc/default"]))
        r = curl(cc, f"{origin}/?fn=getKv&args={gk}",
                 headers={**op_h, "X-Rove-Scope": "__auth__"})
        expect_status("getKv _config/oidc/default (release-mirrored)", 200, r)
        assert "admin-dashboard" in r.body and "${ISSUER_PARENT}" in r.body, \
            f"§9/§0: mirror missing or not host-relative: {r.body[:300]}"
        print("ok  §9+§0: web/auth/_config/oidc/default.json mirrored "
              "with the host-relative ${ISSUER_PARENT} redirect")

        # ── 2. OIDC CONFORMANCE ───────────────────────────────────────
        # Reconfigure _oidc/config/default via the operator session:
        # add the conformance client + shrink rotation windows, KEEP
        # admin-dashboard (templated) so the RP keeps working.
        cfg = {
            "clients": [
                {"client_id": "admin-dashboard",
                 "redirect_uris": ["https://app.${ISSUER_PARENT}/_rp/callback"]},
                {"client_id": CLIENT, "redirect_uris": [REDIRECT]},
            ],
            "login_path": "/login",
            "rotation_period_ms": 1500,
            "publish_window_ms": 1500,
            "retire_window_ms": 60000,
        }
        args = urllib.parse.quote(json.dumps(
            ["_oidc/config/default", json.dumps(cfg)]))
        r = curl(cc, f"{origin}/?fn=setKv&args={args}",
                 headers={**op_h, "X-Rove-Scope": "__auth__"})
        expect_status("reconfigure _oidc/config/default (operator session)",
                      200, r)

        r = curl(cc, auth + "/.well-known/openid-configuration")
        expect_status("discovery 200", 200, r)
        disc = json.loads(r.body)
        assert disc["issuer"] == auth, f"iss not host-relative: {disc['issuer']}"
        assert disc["id_token_signing_alg_values_supported"] == ["RS256"]
        assert disc["code_challenge_methods_supported"] == ["S256"]
        print(f"ok  discovery: host-relative iss={disc['issuer']}, RS256+S256")

        verifier = b64url(os.urandom(32))
        challenge = b64url(hashlib.sha256(verifier.encode()).digest())
        state = "st-" + b64url(os.urandom(6))
        nonce = "no-" + b64url(os.urandom(6))
        authorize = auth + "/authorize?" + urllib.parse.urlencode({
            "client_id": CLIENT, "redirect_uri": REDIRECT,
            "response_type": "code", "scope": "openid", "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256",
            "nonce": nonce,
        })

        r = curl(cc, auth + "/login", method="POST",
                 headers={"content-type": "application/x-www-form-urlencoded"},
                 data="email=alice@example.com&return_to="
                      + urllib.parse.quote(authorize))
        expect_status("POST /login", 200, r)
        magic_link = json.loads(r.body)["magic_link"]
        sc = r.headers.get("set-cookie", "")
        m = re.search(r"__Host-rove_sid=[^;]+", sc)
        assert m, f"no __Host-rove_sid minted: {sc!r}"
        cookie = m.group(0)
        print("ok  POST /login → magic_link + sid cookie")

        r = curl(cc, magic_link, headers={"Cookie": cookie})
        expect_status("GET /login/verify → 302", 302, r)
        assert loc(r) == authorize, f"verify didn't return to authorize: {loc(r)}"
        print("ok  magic-link verify binds sid, returns to /authorize")

        r = curl(cc, authorize, headers={"Cookie": cookie})
        expect_status("GET /authorize → 302", 302, r)
        cbq = urllib.parse.parse_qs(urllib.parse.urlparse(loc(r)).query)
        assert loc(r).startswith(REDIRECT), f"bad redirect: {loc(r)}"
        assert cbq.get("state") == [state], f"state mismatch: {cbq}"
        code = cbq["code"][0]
        print("ok  /authorize → code (state echoed)")

        def token_grant(form: dict, label: str):
            tr = curl(cc, auth + "/token", method="POST",
                      headers={"content-type":
                               "application/x-www-form-urlencoded"},
                      data=urllib.parse.urlencode(form))
            expect_status(label, 200, tr)
            return json.loads(tr.body)

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

        tok2 = token_grant({
            "grant_type": "refresh_token",
            "refresh_token": tok["refresh_token"], "client_id": CLIENT,
        }, "POST /token (refresh)")
        check_idtoken(tok2["id_token"], "refreshed id_token")
        print("ok  refresh_token grant → fresh id_token verifies")

        # §0: same IdP on a DIFFERENT host → iss reflects it.
        a2 = urllib.parse.quote(json.dumps([f"auth2.{sys_sfx}", "__auth__"]))
        r = curl(cc, f"{origin}/?fn=assignDomain&args={a2}", headers=op_h)
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
        # POST (same handler the scheduler fires; period=1500ms).
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
        tok3 = token_grant({
            "grant_type": "refresh_token",
            "refresh_token": tok2["refresh_token"], "client_id": CLIENT,
        }, "POST /token (post-rotation refresh)")
        kid_new = check_idtoken(tok3["id_token"], "post-rotation id_token")
        assert kid_new != kid0, f"signing key didn't rotate ({kid_new})"
        check_idtoken(tok["id_token"], "pre-rotation id_token (retiring key)")
        print(f"ok  §4.6: promoted (kid {kid0[:8]}…→{kid_new[:8]}…); "
              "old token still verifies")

        print("\nall OIDC RP + conformance checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
