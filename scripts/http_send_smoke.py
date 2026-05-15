#!/usr/bin/env python3
"""End-to-end smoke for the http.send → in-process worker phase →
schedule_complete → on_result handler pipeline.

Python port of `scripts/http_send_smoke.sh`. Covers http-send-plan §3.2
+ slice 5c (acme fires http.send to wb; wb runs in-process; httpresult
callback fires on acme; writesets ride multi-envelope atomically).
"""

from __future__ import annotations

import json
import re
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
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
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        leader_port = c.leader_port()
        acme_origin = f"https://{ACME_HOST}:{leader_port}"

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
                headers={
                    "Authorization": f"Bearer {TOKEN}",
                    "X-Rove-Scope": "acme",
                },
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

        # 5. Verify wb's writeset round-tripped.
        qs = urllib.parse.quote(json.dumps(["wb/last_tag"]))
        r = curl(
            cc, f"{admin_origin}/?fn=getKv&args={qs}",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "X-Rove-Scope": "wb",
            },
        )
        if "optimization-win" not in r.body:
            sys.exit(f"FAIL wb/last_tag missing: {r.body}")
        print("ok  wb tenant writeset round-tripped: wb/last_tag=optimization-win")

        # 6. Verify the worker phase took the in-process path.
        leader_log = Path(f"/tmp/http-send-smoke-worker-{c.leader_idx}.out")
        deadline = time.monotonic() + 5.0
        saw = False
        while time.monotonic() < deadline:
            if leader_log.exists():
                content = leader_log.read_text(errors="replace")
                if re.search(r"internal-schedules:.*dispatched in-process to wb status=200", content):
                    saw = True
                    break
            time.sleep(0.2)
        if not saw:
            tail = leader_log.read_text(errors="replace")[-2000:] if leader_log.exists() else ""
            sys.exit(f"FAIL no in-process dispatch logged:\n{tail}")
        print("ok  leader took the in-process fast path (no libcurl roundtrip)")

        # 7. Verify _callback/{id} receipt was cleared.
        qs = urllib.parse.quote(json.dumps(["_callback/", "", 100]))
        r = curl(
            cc, f"{admin_origin}/?fn=listKv&args={qs}",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "X-Rove-Scope": "acme",
            },
        )
        if '"key":"_callback/' in r.body:
            sys.exit(f"FAIL _callback/{{id}} receipt not cleared: {r.body}")
        print("ok  _callback/{id} receipt cleared")

        print()
        print("all http.send fast-path smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
