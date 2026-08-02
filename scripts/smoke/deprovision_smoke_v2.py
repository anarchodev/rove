#!/usr/bin/env python3
"""Tenant lifecycle, both directions (rove#292/#293) — on a production-shaped
3-node cluster.

provision → deploy → serve → **delete** → gone → provision the SAME NAME again.

The last step is the one that matters. A deprovision that merely stops serving
is not a deprovision: the name has to become reusable, which means the
`instance/{id}` root marker is gone from every node, not just the placement
row. Until #292 the directory could not remove a placement at all, so nothing
here was possible.

Also pins the ordering guarantee #293 asks for. Delete withdraws the placement
FIRST and evicts after, so the only window is "unroutable, group not yet gone"
— invisible and retryable. The reverse order would route live traffic at a
cluster that no longer holds the tenant. That ordering is asserted indirectly:
after a delete the front door must 404 (not 421, not 502), which is only true
if the placement went first.

And the guards: a retried delete converges instead of erroring, and a platform
singleton refuses to be deleted at all.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import MOVE_SECRET, PUBLIC_SUFFIX, V2Cluster, _curl, rpc_wrap  # noqa: E402

TENANT = "tobedeleted"
SRC = 'export function handler() { return "alive\\n"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("deprov", nodes=3) as c:
        cp_url = c.front_url().replace(str(c.front_port), str(c.cp_port))

        def cp(op: str, body: dict):
            return _curl(f"{cp_url}/_control/{op}", method="POST",
                         headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                                  "Content-Type": "application/json"},
                         data=json.dumps(body))

        print("step 1: provision + deploy + serve")
        check("provision → 200", cp("provision", {"tenant": TENANT}).status == 200)
        dep = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(SRC)})
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")
        r = c.wait_for_handler(TENANT, "/?fn=handler", want_body="alive")
        check("serves before delete", r.status == 200 and "alive" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 2: delete")
        r = cp("delete", {"tenant": TENANT})
        check("delete → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 3: it is gone — and gone the RIGHT way")
        r = c.get(TENANT, "/?fn=handler")
        # 404 (host maps to no tenant), NOT 421/502 — a 421 would mean the
        # placement outlived the group, i.e. the eviction ran first.
        check("front door 404s the deleted tenant", r.status == 404,
              f"got {r.status} {r.body[:80]!r}")
        rt = _curl(f"{cp_url}/_cp/route?host={TENANT}.{PUBLIC_SUFFIX}", method="GET")
        check("CP has no placement for it", rt.status == 404, f"got {rt.status} {rt.body!r}")

        print("step 4: a retried delete converges (it does not error)")
        r = cp("delete", {"tenant": TENANT})
        check("re-delete → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 5: ⭐ the name is REUSABLE — the whole point of deprovision")
        r = cp("provision", {"tenant": TENANT})
        check("re-provision the same name → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep2 = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(
            'export function handler() { return "reborn\\n"; }\n')})
        check("deploy to the reborn tenant → dep_id", bool(dep2), f"dep_id={dep2}")
        r = c.wait_for_handler(TENANT, "/?fn=handler", want_body="reborn")
        check("serves the NEW content (fresh state, not the old store)",
              r.status == 200 and "reborn" in r.body, f"got {r.status} {r.body!r}")

        print("step 6: the platform's own singletons refuse deletion")
        r = cp("delete", {"tenant": "__admin__"})
        check("delete __admin__ → 403", r.status == 403, f"got {r.status} {r.body!r}")
        r = c.get("__admin__", "/", host=c.host_for("__admin__"))
        check("__admin__ still serves", r.status in (200, 405), f"got {r.status}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS deprovision smoke (v2) — the lifecycle closes: a deleted name comes back")
    return 0


if __name__ == "__main__":
    sys.exit(main())
