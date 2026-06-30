#!/usr/bin/env python3
"""Regression: `provision --host` must wire the WORKER host->tenant alias, not
just the CP directory route.

The bug (2026-06-25 prod genesis): `POST /_control/provision {tenant, cluster,
host}` wrote the CP directory route (so the FRONT resolves host->cluster via
/_cp/route 200) but did NOT push the worker-side `__root__/domain/{host}`
alias. So the front routed a CUSTOM host to a worker, but the WORKER couldn't
map Host->tenant and 404'd -- every first-party PRIMARY host was unreachable
until a manual `rewind-ops host add`. Fix: provision now mirrors
/_control/host's pushDomainToServingCluster.

This smoke provisions a tenant with a CUSTOM (non-wildcard) host, deploys a
handler, and asserts the request RESOLVED VIA THAT HOST serves 200 -- with NO
separate `host add`. A wildcard host ({tenant}.{suffix}) would resolve by
suffix-extraction and miss the bug, so the custom host is load-bearing: it can
ONLY resolve through the worker domain alias that provision must push.

Run:  set -a; . ./.env; set +a
      zig build rewind-worker rewind-cp rewind-front -Doptimize=ReleaseFast
      python3 scripts/smoke/provision_host_alias_smoke_v2.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

CUSTOM_HOST = "alias-test.example"
HANDLER = 'export function handler() { return "alias-ok\\n"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' - ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("alias", nodes=1) as c:
        # Match a real cluster: __admin__/__root__ exist BEFORE any tenant is
        # provisioned (genesis stands them up first). The worker alias is a
        # __root__ write, so __root__ must be live + led for provision's push to
        # land. Without this the smoke provisions before __root__ exists.
        print("step 0: ensure __admin__/__root__ are up (as after genesis)")
        c._ensure_admin_app()

        print(f"step 1: provision 'aliasten' WITH custom host {CUSTOM_HOST}")
        r = c.provision("aliasten", host=CUSTOM_HOST)
        check("provision --host -> 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy a root handler")
        try:
            dep_id = c.deploy_handlers("aliasten", {"index.mjs": rpc_wrap(HANDLER)})
            check("deploy -> dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy", False, str(e))
            dep_id = None

        if dep_id:
            # THE REGRESSION ASSERTION: serve via the CUSTOM host (provisioned
            # with `--host`, NOT a wildcard {tenant}.{suffix} that would resolve
            # by suffix-extraction without an alias). The worker can ONLY map this
            # host through the `__root__/domain/{host}` alias that provision must
            # push. Pre-fix this 404s forever (alias never landed — resolve race);
            # post-fix it serves with NO manual `host add`. Poll because the deploy
            # loads async after release.
            print(f"step 3: GET via CUSTOM host {CUSTOM_HOST} (worker alias path)")
            import time as _t
            deadline = _t.time() + 25.0
            r = c.get("aliasten", "/?fn=handler", host=CUSTOM_HOST)
            while _t.time() < deadline and not (r.status == 200 and "alias-ok" in r.body):
                _t.sleep(0.4)
                r = c.get("aliasten", "/?fn=handler", host=CUSTOM_HOST)
            check("custom-host serve -> 200 alias-ok (no manual host add)",
                  r.status == 200 and "alias-ok" in r.body, f"got {r.status} {r.body!r}")
            if r.status != 200:
                c.dump_node_log(grep=["domain", "alias", "resolve", "host", "404", "tenant"])
                cp_log = c.log_paths.get("cp")
                if cp_log:
                    import os as _os
                    print(f"  --- CP log ({cp_log}) — provision/domain lines ---")
                    if _os.path.exists(cp_log):
                        for ln in open(cp_log).read().splitlines():
                            if any(k in ln.lower() for k in ("provision", "domain", "push", "sethost", "alias", "pushed")):
                                print(f"    | {ln}")
                    else:
                        print("    (cp log file not found)")

    if failures:
        print(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nprovision --host writes the worker alias OK "
          "(custom host serves with no host add)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
