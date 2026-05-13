#!/usr/bin/env python3
"""End-to-end smoke test for the admin RPC API.

Python port of `scripts/admin_smoke.sh`. Every call is a named export
on the `__admin__` handler — GET ?fn=<name>&args=<url-encoded-JSON> or
POST {"fn":"<name>","args":[...]}.
"""

from __future__ import annotations

import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PUBLIC_SUFFIX = "loop46.localhost"
API_HOST = f"app.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="admin-smoke",
        http_base=8240,
        raft_base=40340,
        files_port=8244,
        log_port=8245,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        origin = c.admin_origin()
        c.spawn_files_server(cors_origin=origin, leader_url=origin)

        # Pre-resolve every tenant subdomain the smoke uses.
        extra = ["acme", "randwrite"]
        cc = c.curl_ctx(*(f"{t}.{PUBLIC_SUFFIX}" for t in extra))
        api = f"{origin}"
        auth = {"Authorization": f"Bearer {TOKEN}", "Origin": origin}

        # 1. CORS preflight (allowed origin).
        r = curl(
            cc, f"{api}/?fn=listInstance",
            method="OPTIONS",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization, content-type",
            },
        )
        expect_status("preflight returns 204", 204, r)
        if r.headers.get("access-control-allow-origin", "") != origin:
            sys.exit(f"FAIL preflight allow-origin: {r.headers}")
        if "access-control-allow-methods" not in r.headers:
            sys.exit("FAIL preflight allow-methods")
        print("ok  preflight CORS headers present")

        # 2. Preflight wrong origin → 403.
        r = curl(
            cc, f"{api}/?fn=listInstance",
            method="OPTIONS",
            headers={"Origin": "http://evil.example.com"},
        )
        expect_status("preflight rejects wrong origin", 403, r)

        # 3. Missing bearer → 401. Poll until admin's deployment snapshot
        # is loaded (deployment loader is async after files-server's
        # bootstrap release POST).
        import time as _t
        deadline = _t.monotonic() + 10.0
        r = curl(cc, f"{api}/?fn=listInstance", headers={"Origin": origin})
        while _t.monotonic() < deadline and r.status == 503:
            _t.sleep(0.1)
            r = curl(cc, f"{api}/?fn=listInstance", headers={"Origin": origin})
        expect_status("missing bearer token returns 401", 401, r)

        # 4. Bad bearer → 401.
        bad = "0" * 64
        r = curl(
            cc, f"{api}/?fn=listInstance",
            headers={"Origin": origin, "Authorization": f"Bearer {bad}"},
        )
        expect_status("bad bearer token returns 401", 401, r)

        # 5. listInstance includes acme + __admin__. Poll because the
        # admin tenant deploy lands async via the leader's bootstrap.
        body = ""
        for _ in range(50):
            r = curl(cc, f"{api}/?fn=listInstance", headers=auth)
            body = r.body
            if r.status == 200 and '"id":"acme"' in body and '"id":"__admin__"' in body:
                break
            import time as _t
            _t.sleep(0.1)
        if '"id":"acme"' not in body or '"id":"__admin__"' not in body:
            sys.exit(f"FAIL listInstance: {body}")
        print("ok  GET ?fn=listInstance returns the tenant list")

        # 6. POST createInstance.
        r = curl(
            cc, f"{api}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data='{"fn":"createInstance","args":["admintest"]}',
        )
        expect_status("POST createInstance creates new instance", 201, r)
        if '"id":"admintest"' not in r.body:
            sys.exit(f"FAIL create response body: {r.body}")

        # 7. Malformed RPC envelope → 400.
        r = curl(
            cc, f"{api}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data='{"fn":42}',
        )
        expect_status("POST malformed RPC envelope returns 400", 400, r)

        # 8/9. getInstance existing / unknown.
        r = curl(
            cc, f"{api}/?fn=getInstance&args=%5B%22admintest%22%5D",
            headers=auth,
        )
        expect_status("GET getInstance returns 200 for existing", 200, r)
        r = curl(
            cc, f"{api}/?fn=getInstance&args=%5B%22neverexisted%22%5D",
            headers=auth,
        )
        expect_status("GET getInstance returns 404 for unknown", 404, r)

        # 10. assignDomain.
        r = curl(
            cc, f"{api}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data='{"fn":"assignDomain","args":["admintest.example.com","admintest"]}',
        )
        expect_status("POST assignDomain assigns host", 201, r)

        # 11. assignDomain unknown instance → 404.
        r = curl(
            cc, f"{api}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data='{"fn":"assignDomain","args":["dangling.test","does-not-exist"]}',
        )
        expect_status("POST assignDomain rejects unknown instance", 404, r)

        # 12. listDomain includes the new assignment.
        r = curl(cc, f"{api}/?fn=listDomain", headers=auth)
        if '"host":"admintest.example.com"' not in r.body:
            sys.exit(f"FAIL domain listing missing host: {r.body}")
        if '"instance_id":"admintest"' not in r.body:
            sys.exit(f"FAIL domain listing missing instance_id: {r.body}")
        print("ok  GET listDomain lists assignment")

        # 13. deleteInstance.
        r = curl(
            cc, f"{api}/",
            method="POST",
            headers={**auth, "Content-Type": "application/json"},
            data='{"fn":"deleteInstance","args":["admintest"]}',
        )
        expect_status("POST deleteInstance returns 204", 204, r)

        # 14. After delete: 404 + dangling domains swept.
        r = curl(
            cc, f"{api}/?fn=getInstance&args=%5B%22admintest%22%5D",
            headers=auth,
        )
        expect_status("deleted instance returns 404", 404, r)
        r = curl(cc, f"{api}/?fn=listDomain", headers=auth)
        if "admintest.example.com" in r.body:
            sys.exit("FAIL dangling domain survived delete")
        print("ok  deleteInstance sweeps dangling domains")

        # 15. CORS on real response.
        r = curl(cc, f"{api}/?fn=listInstance", headers=auth)
        if r.headers.get("access-control-allow-origin", "") != origin:
            sys.exit(f"FAIL CORS header missing: {r.headers}")
        print("ok  real response carries CORS headers")

        # 16. Seed acme via its named export — but acme's handler may
        # not be loaded yet. Use wait_for_handler to poll; that's the
        # 1st successful hit. Two more = 3 total.
        c.wait_for_handler("acme", "/?fn=handler", expected_status=200, timeout_s=10.0)
        acme_url = f"https://acme.{PUBLIC_SUFFIX}:{c.leader_port()}"
        for _ in range(2):
            curl(cc, f"{acme_url}/?fn=handler")
        print("ok  seeded acme KV via 3 handler requests")

        # 17. listKv with X-Rove-Scope: acme.
        scope_acme = {**auth, "X-Rove-Scope": "acme"}
        r = curl(cc, f"{api}/?fn=listKv", headers=scope_acme)
        if '"key":"hits"' not in r.body:
            sys.exit(f"FAIL listKv missing hits: {r.body}")
        if '"value":"3"' not in r.body:
            sys.exit(f"FAIL listKv value mismatch (want 3): {r.body}")
        print("ok  GET ?fn=listKv with X-Rove-Scope: acme returns tenant KV")

        # 18. getKv returns the value as-is.
        r = curl(
            cc, f"{api}/?fn=getKv&args=%5B%22hits%22%5D", headers=scope_acme,
        )
        if r.body != "3":
            sys.exit(f"FAIL getKv: expected '3', got '{r.body}'")
        print("ok  GET getKv returns the raw string value")

        # 19. getKv unknown key → 404.
        r = curl(
            cc, f"{api}/?fn=getKv&args=%5B%22neverset%22%5D", headers=scope_acme,
        )
        expect_status("getKv unknown key → 404", 404, r)

        # 20. listKv prefix filter.
        r = curl(
            cc, f"{api}/?fn=listKv&args=%5B%22hi%22%5D", headers=scope_acme,
        )
        if '"key":"hits"' not in r.body:
            sys.exit(f"FAIL prefix=hi missing hits: {r.body}")
        r = curl(
            cc, f"{api}/?fn=listKv&args=%5B%22zz%22%5D", headers=scope_acme,
        )
        if '"entries":[]' not in r.body:
            sys.exit(f"FAIL prefix=zz should be empty: {r.body}")
        print("ok  listKv prefix filter")

        # 21. listKv cursor pagination over randwrite.
        c.wait_for_handler("randwrite", "/?fn=handler", expected_status=200, timeout_s=10.0)
        rw_url = f"https://randwrite.{PUBLIC_SUFFIX}:{c.leader_port()}"
        for _ in range(5):
            curl(cc, f"{rw_url}/?fn=handler")
        scope_rw = {**auth, "X-Rove-Scope": "randwrite"}
        r = curl(
            cc, f'{api}/?fn=listKv&args={urllib.parse.quote("[\"\",\"\",2]")}',
            headers=scope_rw,
        )
        if r.body.count('"key":') != 2:
            sys.exit(f"FAIL page1 should have 2 entries: {r.body}")
        if '"next_cursor":' not in r.body:
            sys.exit(f"FAIL page1 missing next_cursor: {r.body}")
        # Pull next_cursor.
        import re
        m = re.search(r'"next_cursor":"([^"]+)"', r.body)
        if not m:
            sys.exit(f"FAIL extracting next_cursor: {r.body}")
        cursor = m.group(1)
        args_page2 = urllib.parse.quote(f'["","{cursor}",2]')
        r = curl(
            cc, f"{api}/?fn=listKv&args={args_page2}", headers=scope_rw,
        )
        if r.body.count('"key":') != 2:
            sys.exit(f"FAIL page2 should have 2 entries: {r.body}")
        if f'"key":"{cursor}"' in r.body:
            sys.exit("FAIL cursor echoed in page2")
        print("ok  listKv cursor pagination advances past prior page's last key")

        # 22. Unknown scope → 404.
        r = curl(
            cc, f"{api}/?fn=listKv",
            headers={**auth, "X-Rove-Scope": "ghost"},
        )
        expect_status("X-Rove-Scope: <unknown> → 404", 404, r)

        print()
        print("all admin smoke tests passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
