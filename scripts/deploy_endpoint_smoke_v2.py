#!/usr/bin/env python3
"""Smoke for the worker `/_system/deploy` endpoint — the files-server
dissolution (docs/rewind-cli-plan.md §4). Proves the build/stage half now
lives INSIDE the worker (compile off the poll loop on the DeployThread,
write the tenant's own content-addressed blobs, stamp a manifest), with no
files-server in the path:

  - provision a tenant
  - POST a bundle (handler + static, base64) to /_system/deploy
        → 200 {"dep_id":"<016x>"}
  - re-POST the identical bundle → SAME dep_id (content-addressed)
  - release the dep_id, then serve the handler + the static through the
    front door
  - a bad bundle (unknown kind) → 400

The whole point: this never touches files-server — the compile + S3 PUTs
run on the worker's own background DeployThread.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, _curl  # noqa: E402

ROOT_SRC = 'export function handler() { return "deploy-root\\n"; }\n'
STATIC_BODY = "hello-static\n"


def deploy_bundle(c, tenant, files, *, node=0):
    """POST a bundle to {node}/_system/deploy. `files` is a list of
    (path, kind, content_type, content) tuples. Returns the HttpResponse."""
    payload = {
        "tenant_id": tenant,
        "files": [
            {
                "path": p,
                "kind": k,
                "content_type": ct,
                "b64": base64.b64encode(b if isinstance(b, bytes) else b.encode()).decode(),
            }
            for (p, k, ct, b) in files
        ],
    }
    return _curl(
        f"{c.node_url(node)}/_system/deploy",
        method="POST",
        host=c.admin_host(node),
        headers={
            "Authorization": f"Bearer {c.root_token}",
            "Content-Type": "application/json",
        },
        data=json.dumps(payload),
    )


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("deploy-ep", nodes=1) as c:
        print("step 1: provision tenant 'acme'")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        bundle = [
            ("index.mjs", "handler", "", rpc_wrap(ROOT_SRC)),
            ("_static/hi.txt", "static", "text/plain; charset=utf-8", STATIC_BODY),
        ]

        print("step 2: POST bundle to /_system/deploy")
        r = deploy_bundle(c, "acme", bundle)
        dep_hex = None
        ok = r.status == 200
        if ok:
            try:
                dep_hex = json.loads(r.body)["dep_id"]
            except Exception:
                ok = False
        check("/_system/deploy → 200 {dep_id}", ok, f"got {r.status} {r.body!r}")

        print("step 3: idempotent — identical bundle yields the same dep_id")
        r2 = deploy_bundle(c, "acme", bundle)
        same = (
            r2.status == 200
            and dep_hex is not None
            and json.loads(r2.body).get("dep_id") == dep_hex
        )
        check("re-deploy → same dep_id", same, f"got {r2.status} {r2.body!r}")

        if dep_hex:
            print("step 4: release + serve handler + static through the front door")
            rel = c.release("acme", int(dep_hex, 16))
            check("release → 204", rel.status == 204, f"got {rel.status} {rel.body!r}")

            r = c.wait_for_handler("acme", "/?fn=handler", want_body="deploy-root")
            check(
                "GET /?fn=handler → deploy-root",
                r.status == 200 and "deploy-root" in r.body,
                f"got {r.status} {r.body!r}",
            )
            if r.status != 200:
                c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                      "404", "error", "warn"])

            # Static assets are content-addressed: the worker serves them
            # by redirecting to the blob store (302 + Location → presigned
            # blob URL), rather than buffering MB-sized payloads in worker
            # RAM. A 302 with a Location proves the manifest's static entry
            # resolved; an inline 200 (small-asset path) is equally fine.
            r = c.get("acme", "/hi.txt")
            served = (r.status == 200 and "hello-static" in r.body) or (
                r.status == 302 and bool(r.headers.get("location"))
            )
            check(
                "GET /hi.txt → static (200 inline or 302→storage)",
                served,
                f"got {r.status} loc={r.headers.get('location')!r} body={r.body!r}",
            )

        print("step 5: a bad bundle (unknown kind) → 400")
        r = deploy_bundle(c, "acme", [("x.mjs", "bogus", "", "noop")])
        check("bad kind → 400", r.status == 400, f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS deploy-endpoint smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
