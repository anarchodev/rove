#!/usr/bin/env python3
"""Dashboard OIDC RP login + log chokepoint + CP chokepoint (step3 B2 + A5 + B4).

Stands up __auth__ (IdP) + web/admin (relying party) on a V2 cluster with a
TLS-terminating front, then drives the full browser-shaped OIDC handshake:
app /_rp/login → IdP /authorize → magic-link → /_rp/callback → poll → session.
Proves an operator (in the `_admin/operator/*` allowlist) logs in to
is_root:true, and a non-operator logs in to is_root:false.

Then A5: the dashboard reads tenant logs THROUGH the admin app (GET
/v1/logs/{tenant}/list), which issues the `rewind-logs.internal` door fetch —
no services token in the browser. Operator → 200 (the worker minted a
tenant-scoped logs-read cap; the log-server verified it); unauthed → 401;
non-operator → 403.

Then B4: the operator drives a CP control op through the dashboard (POST
/v1/cp/provision), which issues the `rewind-cp.internal` door fetch — the worker
attaches the move-secret, so no CP secret on the operator shell. Verified placed
via a move-secret re-provision (→ 409); non-operator → 403.

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
        c.spawn_log_server()                       # A5: the door target

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
        cust_cookie = None
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

        # ── A5: log query through the admin chokepoint (the door). ─────────
        # Operator reads acme's logs via /v1/logs/{tenant}/list — the admin
        # issues the rewind-logs.internal door fetch (no browser token). Empty
        # index is fine: a 200 with a records envelope proves door → scoped
        # cap → log-server verify → relay.
        r = c.tls_curl(app_origin + "/v1/logs/acme/list?limit=5",
                       headers={"Cookie": op_cookie}, timeout=30.0)
        check("operator log query via chokepoint → 200 + records",
              r.status == 200 and '"records"' in r.body,
              f"got {r.status} {r.body[:160]!r}")
        if r.status != 200:
            c.dump_node_log(grep=["door", "logs", "onfetch", "fetch", "middlew",
                                  "auth", "guard", "502", "error", "warn"])
        # Unauthenticated → 401 at the middleware guard (never reaches the door).
        r = c.tls_curl(app_origin + "/v1/logs/acme/list")
        check("unauthenticated log query → 401", r.status == 401, f"got {r.status}")
        # Non-operator (authed, not is_root) → 403 (cross-tenant read is op-only).
        if cust_cookie:
            r = c.tls_curl(app_origin + "/v1/logs/acme/list",
                           headers={"Cookie": cust_cookie})
            check("non-operator log query → 403", r.status == 403,
                  f"got {r.status} {r.body[:120]!r}")

        # ── B4: CP control op through the dashboard chokepoint (the door). ─
        # Operator provisions a NEW tenant via /v1/cp/provision — the admin
        # issues the rewind-cp.internal door fetch (the worker attaches the
        # move-secret); the operator holds NO CP secret. Then verify it really
        # placed: a move-secret re-provision returns 409 (already exists).
        prov_body = json.dumps({"tenant": "viaui", "cluster": c.cluster_id,
                                "host": c.host_for("viaui")})
        r = c.tls_curl(app_origin + "/v1/cp/provision", method="POST",
                       headers={"Cookie": op_cookie, "content-type": "application/json"},
                       data=prov_body, timeout=30.0)
        check("operator CP provision via chokepoint → 204", r.status == 204,
              f"got {r.status} {r.body[:160]!r}")
        if r.status != 204:
            c.dump_node_log(grep=["cp door", "cpdoor", "provision", "fetch",
                                  "502", "error", "warn"])
        r2 = c.provision("viaui")  # move-secret re-provision (harness verify)
        check("dashboard-provisioned tenant is placed in the CP (re-provision → 409)",
              r2.status == 409, f"got {r2.status} {r2.body!r}")
        # Non-operator → 403 (operator-only).
        if cust_cookie:
            r = c.tls_curl(app_origin + "/v1/cp/provision", method="POST",
                           headers={"Cookie": cust_cookie, "content-type": "application/json"},
                           data=json.dumps({"tenant": "nope", "cluster": c.cluster_id}))
            check("non-operator CP provision → 403", r.status == 403, f"got {r.status}")

        # CP read surface for the #/cluster operator page: GET /v1/cp/route?host=
        # → placement JSON via the door. (Track 2 — the GUI twin of `rewind-ops
        # status`.) Operator → 200 with a route; non-operator → 403.
        r = c.tls_curl(app_origin + "/v1/cp/route?host=" +
                       urllib.parse.quote(c.host_for("viaui")),
                       headers={"Cookie": op_cookie}, timeout=30.0)
        check("operator cluster-status read (/v1/cp/route) → 200 + route",
              r.status == 200 and '"tenant"' in r.body,
              f"got {r.status} {r.body[:160]!r}")
        if cust_cookie:
            r = c.tls_curl(app_origin + "/v1/cp/route?host=x",
                           headers={"Cookie": cust_cookie})
            check("non-operator cluster-status read → 403", r.status == 403,
                  f"got {r.status}")

        # ── B5: publishRelease ownership gate (step3-auth-plan.md B5). ─────
        # Same call, different principal: an operator (is_root) bypasses
        # ownership and falls through to the not-found check (404); a
        # non-operator who doesn't own the tenant is blocked at the gate (403,
        # and the gate fires BEFORE the existence check so it doesn't leak).
        def rpc(cookie, fn, args):
            return c.tls_curl(app_origin + "/", method="POST",
                              headers={"Cookie": cookie, "content-type": "application/json"},
                              data=json.dumps({"fn": fn, "args": args}))
        r = rpc(op_cookie, "publishRelease", ["not-mine", 1])
        check("operator (is_root) bypasses ownership → 404 not-found",
              r.status == 404, f"got {r.status} {r.body[:120]!r}")
        if cust_cookie:
            r = rpc(cust_cookie, "publishRelease", ["not-mine", 1])
            check("non-owner publishRelease → 403 (blocked before existence)",
                  r.status == 403, f"got {r.status} {r.body[:120]!r}")

        # ── Track 0: deploy through the STANDING dashboard app (/v1/deploy). ─
        # The keystone. web/admin replaced the baked genesis app on __admin__,
        # so deploys must still work — they now ride web/admin's /v1/deploy,
        # gated by root-token (M2M operator/bootstrap) OR session-ownership.
        TRIVIAL = "export default function(){ return 'hi'; }"

        def deploy_via(cookie, tenant, *, root=False):
            # Per-file workspace flow: reset → file(handler) → cut. The auth
            # gate fires on each op, so a non-owner is refused at reset.
            hdrs = {"content-type": "application/json"}
            if root:
                hdrs["Authorization"] = "Bearer " + c.root_token
            elif cookie:
                hdrs["Cookie"] = cookie

            def op(sub, body):
                return c.tls_curl(app_origin + "/v1/deploy/" + sub, method="POST",
                                  headers=hdrs, data=json.dumps(body), timeout=30.0)

            r = op("reset", {"tenant": tenant})
            if r.status != 200:
                return r  # auth failure (403/401) surfaces at the first op
            op("file", {"tenant": tenant, "kind": "handler",
                        "path": "index.mjs", "source": TRIVIAL})
            return op("cut", {"tenant": tenant})

        # (a) operator root-token deploy to a provisioned tenant → 200 + dep_id.
        c.provision("dep0")
        r = deploy_via(None, "dep0", root=True)
        ok = False
        dep0_dep = None
        try:
            p = json.loads(r.body)
            ok = r.status == 200 and p.get("ok") is True and bool(p.get("dep_id"))
            dep0_dep = p.get("dep_id")
        except Exception:
            ok = False
        check("root-token deploy via standing app /v1/deploy → 200 + dep_id", ok,
              f"got {r.status} {r.body[:160]!r}")
        if not ok:
            c.dump_node_log(grep=["deploy", "compile", "stamp", "blob",
                                  "middlew", "auth", "error", "warn"])

        # (c) a customer provisions THEIR OWN instance, then deploys to it → 200.
        owned = None
        if cust_cookie:
            r = rpc(cust_cookie, "provisionInstance", ["custapp"])
            check("customer provisions own instance → 201", r.status == 201,
                  f"got {r.status} {r.body[:120]!r}")
            if r.status == 201:
                owned = "custapp"
        cust_dep = None
        if owned:
            r = deploy_via(cust_cookie, owned)
            check("owner-session deploy own tenant via /v1/deploy → 200",
                  r.status == 200, f"got {r.status} {r.body[:160]!r}")
            try: cust_dep = json.loads(r.body).get("dep_id")
            except Exception: pass
            # (b) the same customer deploying a tenant they DON'T own → 403.
            r = deploy_via(cust_cookie, "dep0")
            check("non-owner deploy via /v1/deploy → 403", r.status == 403,
                  f"got {r.status} {r.body[:120]!r}")

        # ── Read door: read deployed sources cross-tenant (/v1/sources). ────
        # The general cross-tenant read door (platform.scope(t).blob.get +
        # deploy.readManifest) composed in the admin app. Operator reads any
        # tenant's deployed handler source back; the source round-trips exactly.
        # Owner reads their own; a non-owner is refused.
        def read_sources(cookie, tenant, dep):
            return c.tls_curl(app_origin + "/v1/sources/" + tenant + "/" + dep,
                              headers={"Cookie": cookie}, timeout=30.0)
        if dep0_dep:
            r = read_sources(op_cookie, "dep0", dep0_dep)
            src = None
            try:
                body = json.loads(r.body)
                ents = body.get("entries") or []
                src = next((e.get("source") for e in ents if e.get("path") == "index.mjs"), None)
            except Exception:
                pass
            check("operator reads dep0 source via read door → 200 + exact source",
                  r.status == 200 and src == TRIVIAL,
                  f"got {r.status} src={src!r}")
            if r.status != 200 or src != TRIVIAL:
                c.dump_node_log(grep=["blob-read", "blobread", "read door", "manifest",
                                      "sources", "onManifest", "sigv4", "error", "warn"])
            # Non-owner customer cannot read dep0's sources.
            if cust_cookie:
                r = read_sources(cust_cookie, "dep0", dep0_dep)
                check("non-owner read dep0 sources → 403", r.status == 403,
                      f"got {r.status} {r.body[:120]!r}")
        # Owner reads their OWN tenant's source (current pointer → after deploy
        # the customer can also release; here we read by explicit dep_id).
        if cust_cookie and cust_dep:
            r = read_sources(cust_cookie, "custapp", cust_dep)
            check("owner reads own tenant source via read door → 200",
                  r.status == 200 and '"entries"' in r.body,
                  f"got {r.status} {r.body[:120]!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — OIDC RP login + log chokepoint (A5) + CP control chokepoint "
          "(B4) + deploy chokepoint (Track 0: /v1/deploy on the standing app, "
          "root-token + ownership-gated) + source read door (cross-tenant "
          "scope(t).blob.get + readManifest, composed in JS) through the dashboard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
