#!/usr/bin/env python3
"""`/_system/admin-kv` is an ACTIVATION, not a door (rove#717 / rove#843).

The route used to open a `TrackedTxn` on `__admin__`, build a writeset by
hand, propose it and park on the commit. The order was right — it proposed
into `__admin__`'s own group — but nothing in the tenant's log said anything
had changed it, which is the account the log is supposed to be.

Now the route authenticates the operator and resolves to an ordinary
activation of baked `__system/admin_kv_install.mjs` in `__admin__`'s scope.
The writeset, the propose, the park, the record and the tape are all the
ordinary path's.

Legs:
  A. the write still answers 204 only once durable, and the value reads back
     through `/_system/v2-kv`.
  B. `__admin__`'s log now carries a record for it. This is the whole point
     of the change, and the only leg that moves: A, C and D pass on either
     side of it. Verified against the pre-change build — B is the single
     failure there.
  C. a malformed batch is refused with no partial write — validation happens
     before the first `kv.set`.
  D. a tenant with NO deployment still 503s on an ordinary route. #843 lets a
     forced BAKED module run without a deployment; it must not turn "not
     deployed" into "ran something else" for customer traffic.

`rewind_smoke.py` covers the case this smoke cannot: a wiped data dir where
`__admin__` has no deployment at all, which is the bootstrap chicken-and-egg
the door existed to dodge.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, _curl, ROOT_TOKEN, MOVE_SECRET  # noqa: E402

ADMIN = "__admin__"


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("adminkvact", nodes=1) as c:
        # `spawn` alone does not stand `__admin__` up — its raft group is not
        # formed and the tenant is "not active on this node" until something
        # provisions it. Every deploy smoke does this implicitly; this one
        # writes to `__admin__` directly, so it has to say so.
        c._ensure_admin_app()
        c.spawn_log_server()
        node = c.node_url(0)
        auth = {"Authorization": f"Bearer {ROOT_TOKEN}", "Content-Type": "application/json"}

        def admin_kv(pairs, *, timeout_s: float = 20.0):
            """POST, retrying a 421. A freshly-registered raft group has not
            elected yet, and the leader gate is a lookup — so the first write
            after provisioning can legitimately be told to re-aim. That is the
            documented contract for this family (`/_system/leader` exists to
            find the node that will accept it); the retry is the client half
            of it, not a workaround."""
            deadline = time.time() + timeout_s
            while True:
                r = _curl(f"{node}/_system/admin-kv", method="POST", headers=auth,
                          data=json.dumps({"pairs": pairs}))
                if r.status != 421 or time.time() >= deadline:
                    return r
                time.sleep(0.3)

        print("step 1 (leg A): the write answers 204 and is durable")
        key = "smoke/admin-kv-activation"
        r = admin_kv([{"key": key, "value": "v1"}])
        check("admin-kv POST → 204", r.status == 204, f"got {r.status} {r.body[:160]!r}")

        r = _curl(f"{node}/_system/v2-kv?tenant={ADMIN}&key={key}", method="GET",
                  headers={"X-Rewind-Move-Secret": MOVE_SECRET})
        check("value reads back", r.status == 200 and "v1" in r.body,
              f"got {r.status} {r.body[:160]!r}")

        print("step 2 (leg B): __admin__'s log carries a record for it")
        # The record is captured on the response path; give the log-server
        # poll a beat to pick it up rather than racing it.
        found = None
        deadline = time.time() + 20.0
        while time.time() < deadline:
            lr = c.log_get(f"{ADMIN}/list")
            if lr.status == 200 and "admin-kv" in lr.body:
                found = lr
                break
            time.sleep(0.5)
        check("a record naming /_system/admin-kv is in __admin__'s log",
              found is not None,
              "present" if found is not None
              else "absent after 20s — the write left no account of itself")

        print("step 3 (leg C): a malformed batch writes nothing")
        r = admin_kv([{"key": "smoke/good", "value": "yes"}, {"key": "", "value": "x"}])
        check("empty key → 400", r.status == 400, f"got {r.status} {r.body[:160]!r}")
        r = _curl(f"{node}/_system/v2-kv?tenant={ADMIN}&key=smoke/good", method="GET",
                  headers={"X-Rewind-Move-Secret": MOVE_SECRET})
        check("the valid pair in the same batch was NOT written",
              r.status == 404, f"got {r.status} {r.body[:160]!r}")

        print("step 4 (leg D): an ordinary route still 503s with no deployment")
        r = c.provision("nodeploy")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body[:120]!r}")
        r = c.get("nodeploy", "/")
        check("GET a never-released tenant → 503 no-deployment",
              r.status == 503 and "no deployment" in r.body,
              f"got {r.status} {r.body[:160]!r}")

        print("step 5 (leg E): the release flip is an activation too (rove#719)")
        # deploy_handlers releases through /_system/release; the flip now
        # dispatches __system/release_flip against the tenant, so the
        # tenant's log must carry a record for its own deployment — the one
        # change a customer most expects to find in it. Deploy AFTER leg D's
        # provision so "nodeploy" gains its first release here.
        dep = c.deploy_handlers("nodeploy", {"index.mjs": "export default function () { return 'up'; }\n"})
        check("deploy → released", bool(dep), f"dep_id={dep!r}")
        r = c.wait_for_handler("nodeploy", "/", want_body="up")
        check("released tenant serves", r.status == 200, f"got {r.status} {r.body[:120]!r}")
        found = None
        deadline = time.time() + 20.0
        while time.time() < deadline:
            lr = c.log_get("nodeploy/list")
            if lr.status == 200 and "/_system/release" in lr.body:
                found = lr
                break
            time.sleep(0.5)
        check("a record for the release flip is in the tenant's log",
              found is not None,
              "present" if found is not None
              else "absent after 20s — the flip left no account of itself")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS admin-kv activation smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
