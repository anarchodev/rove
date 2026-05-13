#!/usr/bin/env python3
"""Smoke for the replay shell + tape capture + historical-deployment surface.

Python port of `scripts/replay_smoke.sh`. Covers:
  - replay.{public_suffix}/ + app.js
  - signup → starter → /  request indexed via log-server
  - multi-file deploy (blob+manifest) compiles & runs
  - log record carries kv / date / module / req-body / resp-body tapes
  - historical deployment manifest by hex id (404 / 400 boundaries)
  - 300 KB request body → truncation flag + exactly 256 KB captured
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl, expect_status  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "loop46.localhost"
ADMIN_HOST = f"app.{PUBLIC_SUFFIX}"
ALICE_HOST = f"alice.{PUBLIC_SUFFIX}"


def main() -> int:
    import os
    # Per-run log-batch namespace so old batches from prior runs don't
    # bleed into this run's `/show` lookups.
    os.environ["LOG_S3_KEY_PREFIX"] = f"smoke-replay-{os.getpid()}-{int(time.time())}/"

    cluster = Cluster.spawn(
        tag="replay-smoke",
        http_base=8210,
        raft_base=40310,
        files_port=8214,
        log_port=8213,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        worker_extra_args=["--fresh"],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        admin_origin = c.admin_origin()
        c.spawn_files_server(cors_origin=admin_origin, leader_url=admin_origin)
        c.spawn_log_server(cors_origin=admin_origin)
        c.mint_services_token()

        cc = c.curl_ctx(ALICE_HOST, f"replay.{PUBLIC_SUFFIX}")
        replay_origin = f"https://replay.{PUBLIC_SUFFIX}:{c.leader_port()}"
        alice_origin = f"https://{ALICE_HOST}:{c.leader_port()}"
        log_origin = c.log_url()
        files_origin = c.files_url()

        if c.log_base != log_origin or c.files_base != files_origin:
            sys.exit(f"FAIL services-token URLs: log={c.log_base} files={c.files_base}")
        print(f"ok  minted services JWT (log={c.log_base} files={c.files_base})")

        # 1. Replay tenant + host alias.
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{replay_origin}/")
            if r.status == 200:
                break
            time.sleep(0.2)
        expect_status("replay.{public_suffix}/ serves shell index", 200, r)

        r = curl(cc, f"{replay_origin}/app.js", method="HEAD")
        ct = r.headers.get("content-type", "")
        if "application/javascript" not in ct.lower():
            sys.exit(f"FAIL app.js HEAD content-type: {ct}")
        print("ok  replay shell app.js served as application/javascript (HEAD)")

        # 2. Fresh tenant signup + first static request → indexed log.
        r = curl(
            cc, f"{admin_origin}/v1/signup",
            method="POST",
            headers={"Content-Type": "application/json"},
            data='{"name":"alice","email":"alice@example.com"}',
        )
        if '"ok":true' not in r.body:
            sys.exit(f"FAIL signup: {r.body}")
        mt = json.loads(r.body)["magic_link"].split("mt=")[-1]
        r = curl(cc, f"{admin_origin}/v1/auth?mt={mt}")
        if r.status != 302:
            sys.exit(f"FAIL redeem: {r.status}")

        # Wait for alice's starter snapshot to load.
        r = c.wait_for_handler("alice", "/", expected_status=200, timeout_s=15.0)
        if r.status != 200:
            sys.exit(f"FAIL fresh tenant GET /: {r.status} {r.body[:200]}")

        def wait_for_record(path_filter: str, *, timeout_s: float = 30.0) -> str:
            deadline = time.monotonic() + timeout_s
            while time.monotonic() < deadline:
                r = curl(
                    cc, f"{log_origin}/v1/alice/list?limit=20",
                    headers={"Authorization": f"Bearer {c.services_jwt}"},
                )
                try:
                    recs = json.loads(r.body).get("records", [])
                except (json.JSONDecodeError, AttributeError):
                    recs = []
                for rec in recs:
                    if rec.get("path") == path_filter:
                        return rec["request_id"]
                time.sleep(0.4)
            return ""

        rid = wait_for_record("/")
        if not rid:
            sys.exit("FAIL fresh-tenant static request not indexed within 30s")
        print("ok  fresh-tenant static request captured + indexed")

        leader_log = Path(f"/tmp/replay-smoke-worker-{c.leader_idx}.out")
        content = leader_log.read_text(errors="replace") if leader_log.exists() else ""
        if "NoTenantLog" in content or "log capture failed" in content:
            sys.exit("FAIL NoTenantLog warning — lazy-open regression")
        print("ok  no NoTenantLog warnings in worker output")

        # 3. Multi-file deploy. PUT blobs then POST /deployments.
        lib_src = 'export function greet(name) { return "hello " + name; }'
        idx_src = '''import { greet } from "./lib/util.mjs";

export default function () {
  kv.set("hits/" + Date.now(), request.body || "");
  const visits = kv.prefix("hits/", "", 100);
  response.headers = { "content-type": "application/json" };
  return JSON.stringify({
    greeting: greet(request.path),
    visit_count: visits.length,
  });
}'''
        lib_hash = hashlib.sha256(lib_src.encode()).hexdigest()
        idx_hash = hashlib.sha256(idx_src.encode()).hexdigest()

        for h, src in ((lib_hash, lib_src), (idx_hash, idx_src)):
            r = curl(
                cc, f"{files_origin}/alice/blobs/{h}",
                method="PUT",
                headers={
                    "Authorization": f"Bearer {c.services_jwt}",
                    "Content-Type": "application/octet-stream",
                },
                data=src,
            )
            if r.status not in (201, 204):
                sys.exit(f"FAIL PUT blob {h}: {r.status} {r.body}")

        # Content-addressed dep_id (truncated sha-256 over the
        # manifest entries). Omit parent_id (= no CAS check) since
        # files-server's per-tenant local store is fresh — the
        # starter deploy used a scratch kv that gets deleted.
        manifest = {
            "files": {
                "index.mjs": {"hash": idx_hash, "kind": "handler"},
                "lib/util.mjs": {"hash": lib_hash, "kind": "handler"},
            },
        }
        r = curl(
            cc, f"{files_origin}/alice/deployments",
            method="POST",
            headers={
                "Authorization": f"Bearer {c.services_jwt}",
                "Content-Type": "application/json",
            },
            data=json.dumps(manifest),
        )
        # files-server returns the new id as hex; we don't know if it's
        # 1 (no starter in files-server tree) or 2 (starter was tracked).
        # Parse and release.
        try:
            v2_id = json.loads(r.body)["id"]
        except (json.JSONDecodeError, KeyError):
            sys.exit(f"FAIL multi-file deploy response: {r.body}")
        dep_id_int = int(v2_id, 16)
        print(f"ok  multi-file deploy compiled (sibling import resolved at compile time) → id={dep_id_int}")
        c.release("alice", dep_id_int)

        # Wait for the new deployment to load. The 2-handler shape is
        # the discriminator (starter was 1 handler).
        target = f"tenant alice loaded deployment {dep_id_int} (2 handler(s)"
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if target in leader_log.read_text(errors="replace"):
                break
            time.sleep(0.1)

        r = curl(cc, f"{alice_origin}/world", method="POST", data="first-visit")
        if '"greeting":"hello /world"' not in r.body:
            sys.exit(f"FAIL handler return: {r.body}")
        print("ok  multi-module handler executed (transitive import works)")
        handler_body = r.body

        # 4. Tape capture verification.
        rid = wait_for_record("/world")
        if not rid:
            sys.exit("FAIL POST /world not in log")
        r = curl(
            cc, f"{log_origin}/v1/alice/show/{rid}",
            headers={"Authorization": f"Bearer {c.services_jwt}"},
        )
        rec = json.loads(r.body)["record"]
        tapes = rec.get("tapes", {})
        for key in ["kv_tape_b64", "date_tape_b64", "module_tree_b64", "request_body_b64", "response_body_b64"]:
            if not tapes.get(key):
                sys.exit(f"FAIL {key} missing on log record")
        if tapes.get("request_body_truncated"):
            sys.exit(f"FAIL request_body_truncated should be false: {tapes!r}")
        if tapes.get("response_body_truncated"):
            sys.exit(f"FAIL response_body_truncated should be false: {tapes!r}")
        print("ok  log record carries kv + date + module + req-body + resp-body tape payloads")

        body_text = base64.b64decode(tapes["request_body_b64"]).decode()
        if body_text != "first-visit":
            sys.exit(f"FAIL request body content: {body_text!r}")
        print("ok  request body inline content round-trips")

        resp_text = base64.b64decode(tapes["response_body_b64"]).decode()
        if resp_text != handler_body:
            sys.exit(f"FAIL response body inline: expected {handler_body!r}, got {resp_text!r}")
        print("ok  response body inline content round-trips")

        # 5. Historical deployment manifest.
        new_idx = 'export default function () { return "v3"; }'
        new_hash = hashlib.sha256(new_idx.encode()).hexdigest()
        curl(
            cc, f"{files_origin}/alice/blobs/{new_hash}",
            method="PUT",
            headers={
                "Authorization": f"Bearer {c.services_jwt}",
                "Content-Type": "application/octet-stream",
            },
            data=new_idx,
        )
        curl(
            cc, f"{files_origin}/alice/deployments",
            method="POST",
            headers={
                "Authorization": f"Bearer {c.services_jwt}",
                "Content-Type": "application/json",
            },
            data=json.dumps({
                "files": {"index.mjs": {"hash": new_hash, "kind": "handler"}},
                "parent_id": v2_id,  # CAS against the just-deployed manifest
            }),
        )
        r = curl(
            cc, f"{files_origin}/alice/deployments/{v2_id}",
            headers={"Authorization": f"Bearer {c.services_jwt}"},
        )
        v2 = json.loads(r.body)
        # deployment_id in the manifest is hex (16 chars); compare
        # against v2_id which we already have in hex form.
        if v2.get("deployment_id") != v2_id:
            sys.exit(f"FAIL v2 deployment_id: {v2!r}")
        paths = sorted(e["path"] for e in v2.get("entries", []))
        if paths != ["index.mjs", "lib/util.mjs"]:
            sys.exit(f"FAIL v2 paths: {paths}")
        print("ok  historical deployment manifest by hex id")

        r = curl(
            cc, f"{files_origin}/alice/deployments/0000000000000099",
            headers={"Authorization": f"Bearer {c.services_jwt}"},
        )
        expect_status("missing deployment → 404", 404, r)

        r = curl(
            cc, f"{files_origin}/alice/deployments/notHex",
            headers={"Authorization": f"Bearer {c.services_jwt}"},
        )
        expect_status("invalid hex deployment id → 400", 400, r)

        # 6. Request body truncation flag.
        big_body = b"x" * 300_000
        curl(
            cc, f"{alice_origin}/big",
            method="POST",
            data=big_body,
        )
        big_rid = wait_for_record("/big")
        if not big_rid:
            sys.exit("FAIL POST /big not in log")
        r = curl(
            cc, f"{log_origin}/v1/alice/show/{big_rid}",
            headers={"Authorization": f"Bearer {c.services_jwt}"},
        )
        rec = json.loads(r.body)["record"]
        if not rec["tapes"]["request_body_truncated"]:
            sys.exit(f"FAIL 300 KB body should set truncation flag")
        blob = base64.b64decode(rec["tapes"]["request_body_b64"])
        if len(blob) != 262144:
            sys.exit(f"FAIL captured body should be 256 KB, got {len(blob)}")
        print("ok  truncation flag set for >256 KB body + 256 KB captured")

        # JWT gate sanity.
        r = curl(cc, f"{log_origin}/v1/alice/list")
        expect_status("log-server /v1/* without bearer → 401", 401, r)

        print()
        print("all replay smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
