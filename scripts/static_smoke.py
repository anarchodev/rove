#!/usr/bin/env python3
"""Smoke for the static-file serving path (HTML, ETag, Cache-Control,
If-None-Match 304, .html / dir-index fallback, trailing-slash redirect,
convention 404, PUT prefix/traversal/uppercase validation).

Python port of `scripts/static_smoke.sh`.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
API_HOST = f"app.{SYSTEM_SUFFIX}"
CUSTOMER_HOST = f"demo.{PUBLIC_SUFFIX}"
OPERATOR_EMAIL = "operator@example.com"


def main() -> int:
    cluster = Cluster.spawn(
        tag="static-smoke",
        http_base=8202,
        raft_base=40302,
        files_port=8221,
        log_port=8220,
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

        admin_origin = c.admin_origin()
        # Admin is a pure OIDC relying party (Fork B, auth-domain-plan
        # §4.7): the createInstance/assignDomain RPCs below need a real
        # is_root operator session, not a Bearer token. Seed the RP
        # config + operator allowlist via --bootstrap-kv.
        c.spawn_files_server(
            cors_origin=admin_origin,
            leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(CUSTOMER_HOST, f"auth.{SYSTEM_SUFFIX}")
        port = c.leader_port()
        customer = f"https://{CUSTOMER_HOST}:{port}"
        leader_log = Path(f"/tmp/static-smoke-worker-{c.leader_idx}.out")

        # Wait for the bootstrap-kv push (`_oidc/rp/default`) + the
        # __admin__ deploy to settle (RP middleware 500s "no RP config"
        # until then → clean 401 is the readiness signal), then the IdP
        # /login surface, then authenticate as the is_root operator.
        deadline = time.monotonic() + 20.0
        r = curl(cc, f"{admin_origin}/?fn=listInstance", headers={"Origin": admin_origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{admin_origin}/?fn=listInstance", headers={"Origin": admin_origin})
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        auth = {
            "Cookie": c.oidc_login(cc, OPERATOR_EMAIL),
            "Origin": admin_origin,
        }
        print("ok  operator authenticated via OIDC RP")

        # Create the demo customer instance.
        r = curl(
            cc, f"{admin_origin}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data='{"fn":"createInstance","args":["demo"]}',
        )
        expect_status("createInstance demo", 201, r)
        r = curl(
            cc, f"{admin_origin}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data=f'{{"fn":"assignDomain","args":["{CUSTOMER_HOST}","demo"]}}',
        )
        expect_status(f"assignDomain {CUSTOMER_HOST} → demo", 201, r)

        def put_static(path: str, content_type: str, body: str) -> str:
            """Returns the new dep_id (decimal string)."""
            r = curl(
                cc, f"{c.files_url()}/demo/file/{path}",
                method="PUT",
                headers={
                    "Authorization": f"Bearer {c.services_jwt}",
                    "Content-Type": content_type,
                },
                data=body,
            )
            if r.status != 201:
                sys.exit(f"FAIL PUT {path}: {r.status} {r.body}")
            dep = r.body.strip()
            c.release("demo", dep)
            return dep

        def wait_loaded(dep: str, *, statics: int, handlers: int = 0) -> None:
            target = f"tenant demo loaded deployment {dep} ({handlers} handler(s), {statics} static(s)"
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                if target in leader_log.read_text(errors="replace"):
                    return
                time.sleep(0.1)
            sys.exit(f"FAIL waiting for {target!r}")

        # 1. PUT _static/index.html.
        dep = put_static("_static/index.html", "text/html", "<!doctype html><h1>home</h1>")
        wait_loaded(dep, statics=1)
        print("ok  PUT _static/index.html → 201")

        # 2. GET / → 200 + html + ETag + Cache-Control.
        r = curl(cc, f"{customer}/")
        expect_status("GET / status", 200, r)
        ct = r.headers.get("content-type", "")
        if not ct.startswith("text/html"):
            sys.exit(f"FAIL content-type: {ct}")
        etag = r.headers.get("etag", "")
        if not etag:
            sys.exit(f"FAIL etag missing: {r.headers}")
        if "public" not in r.headers.get("cache-control", ""):
            sys.exit(f"FAIL cache-control: {r.headers}")
        if "<h1>home</h1>" not in r.body:
            sys.exit(f"FAIL body: {r.body}")
        print("ok  GET / returns index.html with ETag + Cache-Control")

        # 2b. HEAD / matches GET headers, no body.
        r = curl(cc, f"{customer}/", method="HEAD")
        expect_status("HEAD / status", 200, r)
        if "etag" not in r.headers:
            sys.exit(f"FAIL HEAD / etag missing: {r.headers}")
        if r.body:
            sys.exit(f"FAIL HEAD / returned body of {len(r.body)} bytes")
        print("ok  HEAD / matches GET headers but omits body")

        # 3. If-None-Match matching → 304.
        r = curl(cc, f"{customer}/", headers={"If-None-Match": etag})
        expect_status("If-None-Match match → 304", 304, r)

        # 4. If-None-Match mismatch → 200.
        r = curl(cc, f"{customer}/", headers={"If-None-Match": '"different"'})
        expect_status("If-None-Match mismatch → 200", 200, r)

        # 5. .html fallback.
        dep = put_static("_static/about.html", "text/html", "<p>about</p>")
        wait_loaded(dep, statics=2)
        r = curl(cc, f"{customer}/about")
        if "<p>about</p>" not in r.body:
            sys.exit(f"FAIL .html fallback body: {r.body}")
        print("ok  .html fallback: /about → _static/about.html")

        # 6. Dir-index fallback.
        dep = put_static("_static/blog/index.html", "text/html", "<p>blog</p>")
        wait_loaded(dep, statics=3)
        r = curl(cc, f"{customer}/blog")
        if "<p>blog</p>" not in r.body:
            sys.exit(f"FAIL dir index body: {r.body}")
        print("ok  dir-index fallback: /blog → _static/blog/index.html")

        # 7. Trailing slash → 301.
        r = curl(cc, f"{customer}/blog/")
        expect_status("trailing slash → 301", 301, r)
        if r.headers.get("location") != "/blog":
            sys.exit(f"FAIL redirect location: {r.headers}")

        # 8. Convention 404.
        dep = put_static("_static/_404.html", "text/html", "<h1>nope</h1>")
        wait_loaded(dep, statics=4)
        r = curl(cc, f"{customer}/nonexistent")
        expect_status("convention 404", 404, r)
        if "<h1>nope</h1>" not in r.body:
            sys.exit(f"FAIL 404 body: {r.body}")
        if not r.headers.get("content-type", "").startswith("text/html"):
            sys.exit(f"FAIL 404 content-type: {r.headers}")
        print("ok  convention 404 served from _static/_404.html")

        # 9-11. Bad prefix / traversal / uppercase → 400.
        for bad_path, label in [
            ("evil/foo.html", "PUT outside _static → 400"),
            ("_static/../escape", "PUT with .. → 400"),
            ("_static/Index.html", "PUT with uppercase → 400"),
        ]:
            r = curl(
                cc, f"{c.files_url()}/demo/file/{bad_path}",
                method="PUT",
                headers={
                    "Authorization": f"Bearer {c.services_jwt}",
                    "Content-Type": "text/html",
                },
                data="x",
            )
            expect_status(label, 400, r)

        # 12. Identical re-upload keeps the same ETag.
        dep = put_static("_static/index.html", "text/html", "<!doctype html><h1>home</h1>")
        # Same file content; dep_id bumps but the file-blob hash is stable.
        wait_loaded(dep, statics=4)
        r = curl(cc, f"{customer}/")
        new_etag = r.headers.get("etag", "")
        if new_etag != etag:
            sys.exit(f"FAIL etag changed on identical re-upload: {etag} vs {new_etag}")
        print("ok  identical re-upload keeps the same ETag")

        print()
        print("all static smoke tests passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
