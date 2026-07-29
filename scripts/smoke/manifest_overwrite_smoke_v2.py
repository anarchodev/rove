#!/usr/bin/env python3
"""The manifest_put overwrite invariant: a stale-format
object at the manifest's content-addressed key must be REPLACED by a
re-deploy of identical content (a manifest schema bump changes the serialized bytes under an unchanged
content-addressed key — an if-missing PUT would pin the relic forever and
every release of that content would fail InvalidManifest).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""
from __future__ import annotations

import os
import subprocess
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

HTML = "<!doctype html><title>ow</title><h1>overwrite-me</h1>\n"


def s3_curl(method: str, key: str, data: bytes | None = None) -> tuple[int, bytes]:
    url = f"{os.environ['S3_ENDPOINT'].rstrip('/')}/{os.environ['S3_BUCKET']}/{key}"
    cmd = ["curl", "-sS", "-X", method,
           "--aws-sigv4", f"aws:amz:{os.environ['S3_REGION']}:s3",
           "--user",
           f"{os.environ['AWS_ACCESS_KEY_ID']}:{os.environ['AWS_SECRET_ACCESS_KEY']}",
           "-o", "-", "-w", "\n%{http_code}", url]
    if data is not None:
        cmd += ["--data-binary", "@-"]
    r = subprocess.run(cmd, input=data or b"", capture_output=True)
    body, _, code = r.stdout.rpartition(b"\n")
    return int(code), body


def main() -> int:
    with V2Cluster.spawn("manifow", nodes=1) as c:
        assert c.provision("manifow").status == 204
        statics = {"_static/index.html": (HTML, "text/html; charset=utf-8")}

        print("deploy #1…")
        dep = c.deploy_with_static("manifow", {}, statics)
        key = f"{c.s3_prefix}manifow/deployments/{int(dep):020d}.json"
        code, body = s3_curl("GET", key)
        assert code == 200 and b'"v":2' in body, (code, body[:100])
        print(f"  manifest at {key}: v2, {len(body)}B")

        print("corrupt the object to a stale v:1 relic…")
        relic = body.replace(b'"v":2', b'"v":1')
        code, _ = s3_curl("PUT", key, relic)
        assert code == 200, code
        code, body = s3_curl("GET", key)
        assert b'"v":1' in body, body[:100]

        print("deploy #2 (identical content → same dep_id, same key)…")
        dep2 = c.deploy_with_static("manifow", {}, statics)
        assert dep2 == dep, (dep, dep2)
        code, body = s3_curl("GET", key)
        v2_restored = b'"v":2' in body
        print(f"  object after redeploy: {'v2 RESTORED' if v2_restored else 'STILL v1 RELIC'}")

        r = c.get("manifow", "/")
        print(f"  GET / -> {r.status}")
        ok = v2_restored and r.status == 200
        print("PASS" if ok else "FAIL")
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
