#!/usr/bin/env python3
"""Self-serve provisioning shape (rove#291) — a tenant provisioned the way the
customer dashboard provisions one is REACHABLE, on a production-shaped 3-node
cluster.

The dashboard cannot name a cluster and cannot map a host; it knows a name and
an account. So this drives `/_control/provision` with neither `cluster` nor
`host` and then asks the front door for `{tenant}.{PUBLIC_SUFFIX}`:

  - the CP defaults to the sole configured cluster,
  - placement makes the tenant routable — no `host/{host}` row is written,
  - `/_cp/route` derives the tenant from the wildcard host, and the worker
    derives the same tenant from the same host on the other side of the proxy.

That last pair is the point. Both hops read `rove-instance-id`, so an id the CP
accepts is an id the worker can resolve; before the wildcard existed in the CP,
a provision with no host produced a placed tenant that the front door 404'd.

Also pins the refusals, because the dashboard shows the reason verbatim: a
reserved platform label and a non-DNS name each come back 400 with a sentence
naming the rule, and an unprovisioned wildcard host stays a 404 (the wildcard
resolves NAMES, it does not conjure tenants).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import (  # noqa: E402
    MOVE_SECRET,
    PUBLIC_SUFFIX,
    V2Cluster,
    _curl,
    rpc_wrap,
)

TENANT = "shopdemo"
SRC = 'export function handler() { return "self-serve ok\\n"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("selfserve", nodes=3) as c:
        cp_url = c.front_url().replace(str(c.front_port), str(c.cp_port))

        def cp_provision(body: dict):
            return _curl(f"{cp_url}/_control/provision", method="POST",
                         headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                                  "Content-Type": "application/json"},
                         data=json.dumps(body))

        print("step 1: provision with neither cluster nor host (the dashboard's shape)")
        r = cp_provision({"tenant": TENANT})
        check("provision {tenant} only → 200", r.status == 200, f"got {r.status} {r.body!r}")
        # The reply names the URL. The dashboard has no other way to learn it —
        # it carries no copy of the platform's zone — so this field is the
        # contract, not a convenience.
        placed = json.loads(r.body) if r.status == 200 else {}
        check("reply reports the wildcard host",
              placed.get("host") == f"{TENANT}.{PUBLIC_SUFFIX}", f"got {placed!r}")
        check("reply names the defaulted cluster",
              placed.get("cluster") == c.cluster_id, f"got {placed!r}")

        print("step 2: deploy a handler")
        try:
            dep_id = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(SRC)})
            check("deploy → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy", False, str(e))
            dep_id = None

        if dep_id:
            print(f"step 3: GET {TENANT}.{PUBLIC_SUFFIX}/ through the front door")
            r = c.wait_for_handler(TENANT, "/?fn=handler", want_body="self-serve ok")
            check("wildcard host serves the tenant", r.status == 200 and "self-serve ok" in r.body,
                  f"got {r.status} {r.body!r}")
            if r.status != 200:
                c.dump_node_log(grep=["route", "placement", "404", "resolve", "error", "warn"])

        print("step 4: a name the worker could not resolve is refused, with the reason")
        r = cp_provision({"tenant": "auth"})
        check("reserved label → 400", r.status == 400, f"got {r.status}")
        check("reserved label names the rule", "reserved" in r.body.lower(), f"got {r.body!r}")

        r = cp_provision({"tenant": "My_App"})
        check("non-DNS name → 400", r.status == 400, f"got {r.status}")
        check("non-DNS name names the rule",
              "lowercase" in r.body.lower(), f"got {r.body!r}")

        r = cp_provision({"tenant": TENANT})
        check("re-provision → 409", r.status == 409, f"got {r.status} {r.body!r}")

        print("step 5: the wildcard resolves names, it does not conjure tenants")
        r = c.get("neverprovisioned", "/")
        check("unplaced wildcard host → 404", r.status == 404, f"got {r.status} {r.body[:80]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS self-serve provision smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
