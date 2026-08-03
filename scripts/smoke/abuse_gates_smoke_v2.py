#!/usr/bin/env python3
"""Abuse-gates smoke — lane 4 of the #321 fan-out (#335/#337/#338).

Proves the signup-gating abuse mechanisms end to end on a 1-node V2 cluster:

  A. #335 suspend: `POST /_control/suspend` stops serving with an honest 403
     (worker admission), reads back on the worker (`GET /_system/v2-suspend`),
     and `unsuspend` restores serving exactly — data and deployment untouched.
     The platform singletons refuse suspension.
  B. #337 host claims: first-claim-wins (cross-tenant re-claim → 409, operator
     `force` overrides), and the platform zone is identity-bound
     (`{label}.{suffix}` claimable only by tenant `label` → 403 otherwise).
  C. #338 provision velocity: bulk tenant creation trips the CP's
     creation-velocity guard (429) within the burst budget.

The #303 log-byte bucket and #336 sustained-outbound ceiling are unit-tested
in `limiter.zig` (their windows are day-scale — not smokeable).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, _curl, MOVE_SECRET  # noqa: E402

SRC = 'export function hello() { return "hi\\n"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("abuse", nodes=1) as c:

        def control(op: str, body: dict):
            return c._cp_post(f"/_control/{op}", body)

        def worker_suspended(tenant: str):
            r = _curl(f"{c.node_url(0)}/_system/v2-suspend?tenant={tenant}",
                      headers={"X-Rewind-Move-Secret": MOVE_SECRET})
            if r.status != 200:
                return None
            try:
                return json.loads(r.body).get("suspended")
            except json.JSONDecodeError:
                return None

        print("step 1: provision acme + deploy + baseline serve")
        r = c.provision("acme")
        check("provision acme → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(SRC)})
        check("deploy → dep_id", bool(dep_id))
        r = c.wait_for_handler("acme", "/?fn=hello", want_body="hi")
        check("baseline GET → 200", r.status == 200 and "hi" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 2: #335 suspend stops serving with 403; data survives; unsuspend restores")
        r = control("suspend", {"tenant": "acme", "reason": "smoke: abuse report"})
        check("POST /_control/suspend → 200", r.status == 200, f"got {r.status} {r.body!r}")
        check("worker slot sees suspended=true", worker_suspended("acme") is True)
        # The 403 may come from either layer: the worker admission gate
        # (body: "this tenant is suspended") or the front's suspended route
        # cache (status-only, like every front-authored refusal). The status
        # is the contract; the body depends on which layer answered first.
        r = c.get("acme", "/?fn=hello")
        check("suspended GET → 403", r.status == 403, f"got {r.status} {r.body!r}")
        r = control("suspend", {"tenant": "__admin__", "reason": "nope"})
        check("suspend __admin__ refused → 403", r.status == 403, f"got {r.status}")

        r = control("unsuspend", {"tenant": "acme"})
        check("POST /_control/unsuspend → 200", r.status == 200, f"got {r.status}")
        check("worker slot sees suspended=false", worker_suspended("acme") is False)
        r = c.get("acme", "/?fn=hello")
        check("unsuspended GET → 200 again (nothing destroyed)",
              r.status == 200 and "hi" in r.body, f"got {r.status} {r.body!r}")

        print("step 3: #337 host claims — first-claim-wins + identity-bound platform zone")
        r = control("host", {"host": "custom-a.example.com", "tenant": "acme"})
        check("first claim → 200", r.status == 200, f"got {r.status} {r.body!r}")
        r = control("host", {"host": "custom-a.example.com", "tenant": "acme"})
        check("same-tenant re-claim (idempotent) → 200", r.status == 200, f"got {r.status}")

        r = c.provision("beta")
        check("provision beta → 200", r.status == 200, f"got {r.status}")
        r = control("host", {"host": "custom-a.example.com", "tenant": "beta"})
        check("cross-tenant re-claim → 409", r.status == 409, f"got {r.status} {r.body!r}")
        r = control("host", {"host": "custom-a.example.com", "tenant": "beta", "force": True})
        check("operator force → 200", r.status == 200, f"got {r.status} {r.body!r}")

        r = control("host", {"host": "beta.localhost", "tenant": "acme"})
        check("platform-zone label ≠ tenant → 403", r.status == 403, f"got {r.status} {r.body!r}")
        r = control("host", {"host": "login.localhost", "tenant": "acme"})
        check("platform-zone reserved-shaped label → 403", r.status == 403, f"got {r.status}")

        print("step 4: #338 bulk tenant creation trips the velocity guard (429)")
        tripped_at = None
        for i in range(3, 16):
            r = c.provision(f"bulk{i:02d}")
            if r.status == 429:
                tripped_at = i
                break
            if r.status != 200:
                check(f"provision bulk{i:02d} unexpected status", False, f"got {r.status} {r.body!r}")
                break
        check("velocity guard tripped within the burst budget",
              tripped_at is not None and tripped_at <= 12, f"tripped_at={tripped_at}")

    print("PASS" if not failures else f"FAIL: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
