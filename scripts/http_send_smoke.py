#!/usr/bin/env python3
"""End-to-end smoke for the webhook.send JS-shim path.

Exercises `acme/httpfire?fn=fire`: customer calls `webhook.send(...)`,
the JS-shim writes a `_send/owed/{id}` marker (envelope-0 kv put),
issues the inline `http.fetch`, the `__system/webhook_onresult` baked
on_chunk classifies the terminal outcome + fires the customer's
`on_result` chain on the SAME tenant the marker lives on. The
observable contract: the customer's `on_result` module ran exactly
once with `{ok, status, body}` matching the upstream response.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
OPERATOR_EMAIL = "operator@example.com"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="http-send-smoke",
        http_base=8275,
        raft_base=40375,
        files_port=8279,
        log_port=8280,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        admin_origin = c.admin_origin()
        # Admin is a pure OIDC relying party (Fork B, auth-domain-plan
        # §4.7): no Bearer human path. Seed the RP config + operator
        # allowlist via --bootstrap-kv and authenticate the admin
        # listKv/getKv calls below with a real operator session.
        c.spawn_files_server(
            cors_origin=admin_origin,
            leader_url=admin_origin,
            extra_args=c.admin_oidc_kv(OPERATOR_EMAIL),
        )

        cc = c.curl_ctx(ACME_HOST, WB_HOST, f"auth.{SYSTEM_SUFFIX}")
        leader_port = c.leader_port()
        acme_origin = f"https://{ACME_HOST}:{leader_port}"

        # Wait for the bootstrap-kv push (`_oidc/rp/default`) + the
        # __admin__ deploy to settle — the RP middleware 500s
        # "no RP config" until then, so an unauthenticated call
        # reaching a clean 401 is the readiness signal. Then wait for
        # the IdP /login surface and authenticate as the operator.
        deadline = time.monotonic() + 20.0
        r = curl(cc, f"{admin_origin}/?fn=listKv", headers={"Origin": admin_origin})
        while time.monotonic() < deadline and r.status != 401:
            time.sleep(0.25)
            r = curl(cc, f"{admin_origin}/?fn=listKv", headers={"Origin": admin_origin})
        for _ in range(80):
            if curl(cc, c.auth_base() + "/login").status == 200:
                break
            time.sleep(0.25)
        admin_auth = {
            "Cookie": c.oidc_login(cc, OPERATOR_EMAIL),
            "Origin": admin_origin,
        }
        print("ok  operator authenticated via OIDC RP")

        # 1. Sanity: wb tenant is reachable. Poll because acme/wb load
        # async after seed.
        deadline = time.monotonic() + 20.0
        body = ""
        while time.monotonic() < deadline:
            r = curl(
                cc, f"https://{WB_HOST}:{leader_port}/",
                method="POST",
                headers={"content-type": "application/json"},
                data='{"tag":"sanity"}',
            )
            if r.status == 200 and r.body == "echoed:sanity":
                body = r.body
                break
            time.sleep(0.2)
        if body != "echoed:sanity":
            sys.exit(f"FAIL wb sanity returned: {body}")
        print("ok  wb tenant reachable; index.mjs returns echoed:<tag>")

        # 2. Fire http.send through acme.
        target = f"https://{WB_HOST}:{leader_port}/echo"
        args = urllib.parse.quote(json.dumps([target, "optimization-win"]))
        r = curl(cc, f"{acme_origin}/httpfire?fn=fire&args={args}")
        if r.status != 200:
            sys.exit(f"FAIL fire: {r.status} {r.body}")
        send_id = json.loads(r.body).get("id")
        if not send_id:
            sys.exit(f"FAIL fire didn't return id: {r.body}")
        print(f"ok  handler called http.send, id={send_id} ({len(send_id)} chars)")

        # 3. Wait for on_result callback to write http/result/{id} via
        # acme's _callback dispatch + httpresult.mjs.
        qs = urllib.parse.quote(json.dumps(["http/result/", "", 100]))
        result_body = ""
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            r = curl(
                cc, f"{admin_origin}/?fn=listKv&args={qs}",
                headers={**admin_auth, "X-Rove-Scope": "acme"},
            )
            if '"key":"http/result/' in r.body:
                result_body = r.body
                break
            time.sleep(0.1)
        if not result_body:
            sys.exit(f"FAIL no http/result/* row: {r.body}")
        print("ok  httpresult.mjs ran on acme's tenant; http/result/{id} written")

        # 4. Verify event shape.
        doc = json.loads(result_body)
        match = None
        for e in doc.get("entries", []):
            if e["key"] == "http/result/" + send_id:
                match = json.loads(e["value"])
                break
        if match is None:
            sys.exit(f"FAIL no entry for http/result/{send_id}: {result_body}")
        for field, want in [
            ("id", send_id),
            ("ok", True),
            ("status", 200),
            ("version", 1),
            ("body", "echoed:optimization-win"),
        ]:
            if match.get(field) != want:
                sys.exit(f"FAIL {field}: {match.get(field)!r} != {want!r}")
        if match.get("context", {}).get("tag") != "optimization-win":
            sys.exit(f"FAIL context: {match.get('context')!r}")
        print(f"ok  event shape: id={send_id}, ok=true, status=200, version=1, body='echoed:optimization-win'")

        # 5. Verify the `_send/owed/{id}` marker was cleared on
        #    terminal success. The JS-shim writes the marker on
        #    `webhook.send`, the on_chunk classifies the response,
        #    and on a 2xx terminal the shim issues `kv.delete` of
        #    the same key. A surviving row means the cleanup hop
        #    didn't run.
        qs = urllib.parse.quote(json.dumps(["_send/owed/", "", 100]))
        r = curl(
            cc, f"{admin_origin}/?fn=listKv&args={qs}",
            headers={**admin_auth, "X-Rove-Scope": "acme"},
        )
        if '"key":"_send/owed/' in r.body:
            sys.exit(f"FAIL _send/owed/{{id}} marker not cleared: {r.body}")
        print("ok  _send/owed/{id} marker cleared on terminal success")

        print()
        print("all webhook.send JS-shim smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
