#!/usr/bin/env python3
"""V2 deploy-flow smoke — the V2 port of `ctl_smoke.py`, on the `V2Cluster`
harness (`smoke_lib_v2`). Proves the harness end to end:

  - provision a tenant via the CP
  - deploy two routes (root + /api) via files-server-v2
  - GET each through the front door (Host→cluster routing)
  - a wrong-secret JWT is rejected by the files-server (401)

Dropped from the V1 ctl_smoke (don't map to V2): TLS/https (V2 is h2c),
3-node follower-503 (V2 is serve-or-forward via the front door, not
leader-direct addressing). Multi-node behavior is covered by the cp_*/
three_node smokes.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import mint_jwt  # noqa: E402
from smoke_lib_v2 import V2Cluster  # noqa: E402

ROOT_SRC = 'export function handler() { return "ctl-root\\n"; }\n'
API_SRC = 'export function handler() { return "ctl-api\\n"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("ctl", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy two routes (root + /api)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": ROOT_SRC,
                "api/index.mjs": API_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if dep_id:
            print("step 3: GET each route through the front door")
            r = c.wait_for_handler("acme", "/?fn=handler", want_body="ctl-root")
            check("GET /?fn=handler → ctl-root", r.status == 200 and "ctl-root" in r.body,
                  f"got {r.status} {r.body!r}")
            if r.status != 200:
                c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                      "404", "error", "warn"])
            r = c.get("acme", "/api?fn=handler")
            check("GET /api?fn=handler → ctl-api", r.status == 200 and "ctl-api" in r.body,
                  f"got {r.status} {r.body!r}")

        print("step 4: wrong-secret JWT is rejected by the files-server (401)")
        wrong = mint_jwt("00" * 32, {"exp": int((time.time() + 300) * 1000)})
        from smoke_lib_v2 import _curl
        r = _curl(f"{c.files_origin()}/acme/upload", method="POST",
                  headers={"Authorization": f"Bearer {wrong}", "X-Rove-Path": "index.mjs"},
                  data=ROOT_SRC)
        check("upload with wrong JWT → 401", r.status == 401, f"got {r.status}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS ctl smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
