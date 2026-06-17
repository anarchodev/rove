#!/usr/bin/env python3
"""Smoke for the worker `POST /_system/reset` endpoint — bootstrap +
break-glass (docs/rewind-cli-plan.md §4). reset is the ONLY native deploy
surface: root-token gated, NO body, it (re)deploys the BAKED `__admin__`
deploy app and stamps `_deploy/current`. Every ARBITRARY deploy (the full
admin, customers) goes THROUGH that deployed app — there is no arbitrary-bundle
Zig route anymore.

Proves:
  - provision __admin__ + POST /_system/reset → 200 {"ok":true,"dep_id":"<016x>"}
  - the deploy app is live afterward (GET __admin__/ → 405 POST-only)
  - reset is idempotent / re-runnable (the break-glass property): re-POST →
    SAME dep_id (the baked bundle is content-addressed) and the app stays live
  - a wrong bearer → 401 (root-gated, no cap alternative)
  - GET /_system/reset → 405 (POST only)

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, _curl  # noqa: E402


def post_reset(c, *, token, node=0):
    return _curl(f"{c.node_url(node)}/_system/reset", method="POST",
                 host=c.admin_host(node),
                 headers={"Authorization": f"Bearer {token}"}, timeout=30.0)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("reset-ep", nodes=1) as c:
        print("step 1: provision __admin__ + POST /_system/reset (bootstrap)")
        c.provision("__admin__")
        r = post_reset(c, token=c.root_token)
        dep_hex = None
        ok = r.status == 200
        if ok:
            try:
                payload = json.loads(r.body)
                ok = payload.get("ok") is True
                dep_hex = payload.get("dep_id")
            except Exception:
                ok = False
        check("/_system/reset → 200 {ok, dep_id}", ok and bool(dep_hex),
              f"got {r.status} {r.body[:200]!r}")
        if not ok:
            c.dump_node_log(grep=["reset", "deploy", "admin", "leader", "loader",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("__admin__", "/", want_status=405, timeout_s=30.0)
        check("deploy app live (GET __admin__/ → 405 POST-only)",
              r.status == 405, f"got {r.status} {r.body!r}")

        print("step 2: idempotent / re-runnable (break-glass) — same dep_id")
        r2 = post_reset(c, token=c.root_token)
        same = (r2.status == 200 and dep_hex is not None
                and json.loads(r2.body).get("dep_id") == dep_hex)
        check("re-reset → same dep_id (content-addressed baked bundle)", same,
              f"got {r2.status} {r2.body[:200]!r}")
        r = c.wait_for_handler("__admin__", "/", want_status=405, timeout_s=10.0)
        check("deploy app still live after re-reset", r.status == 405,
              f"got {r.status} {r.body!r}")

        print("step 3: a wrong bearer → 401")
        r = post_reset(c, token="not-the-root-token")
        check("wrong token → 401", r.status == 401, f"got {r.status} {r.body[:120]!r}")

        print("step 4: GET /_system/reset → 405 (POST only)")
        r = _curl(f"{c.node_url(0)}/_system/reset", method="GET",
                  host=c.admin_host(0),
                  headers={"Authorization": f"Bearer {c.root_token}"})
        check("GET → 405", r.status == 405, f"got {r.status} {r.body[:120]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS reset-endpoint smoke (v2): bootstrap + break-glass via "
          "/_system/reset, deploy app deployed from the baked bundle")
    return 0


if __name__ == "__main__":
    sys.exit(main())
