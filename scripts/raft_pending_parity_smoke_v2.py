#!/usr/bin/env python3
"""V2 port of `raft_pending_parity_smoke.py` — concurrent-write commit
consistency on the `V2Cluster` harness (branch `v2`).

The V1 smoke was a *pre-migration parity gate* for collapsing the H2
reference path off the willemt `raft_pending_response` arm onto
`effect.Continuation` + `reconcile()`. That willemt-specific commit-arm
pipeline has NO V2 analog: on V2 the per-tenant raft is the `Bridge`
(`src-v2/kv/bridge.zig`) + raft-rs, and a single voter leader-skips apply
entirely (worker owns the speculative overlay). So the *mechanism* the V1
gate poked (`raft_pending` collections, willemt commit ordering) is gone.

What survives the port is the V1 smoke's three OBSERVABLE invariants —
the behavior any commit machinery must preserve, restated against the V2
Bridge commit path:

  A. Read-your-writes within one activation — a write is visible to a
     later `kv.get` in the same handler call (TrackedTxn speculative
     overlay).
  B. Commit-before-response (sequential durability) — once a write
     request returns 200, the value is durably readable by the NEXT
     request (propose → quorum → overlay commit happens before the
     response leaves).
  C. Concurrent same-tenant writes, zero dropped writesets — N
     concurrent distinct-key writes all commit and read back. Distinct
     keys (not RMW) so the assertion depends only on the commit
     machinery not dropping a parked writeset, not on serializable RMW.

Handler JS is reused verbatim from the V1 smoke. Driven through the V2
front door with `?fn=<export>` routing.

Dropped from V1 (no V2 analog): the willemt `raft_pending_response`
commit-arm internals, OIDC operator login + files/log sidecars (V2 uses
the CP provision + files-server-v2 deploy contract), TLS, 3-node
follower-503 / leader-direct addressing (V2 is serve-or-forward via the
front door). WORKERS knob is dropped — a V2 `rewind` node runs a single
worker thread; cross-worker concurrency is a multi-node concern covered by
the cp_*/three_node smokes.

Env: CONCURRENCY (64), SEQ_WRITES (16).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TENANT = "rpparity"
CONCURRENCY = int(os.environ.get("CONCURRENCY", "64"))
SEQ_WRITES = int(os.environ.get("SEQ_WRITES", "16"))

# index.mjs — verbatim from the V1 smoke. `put`/`get` use distinct
# per-index keys so the concurrency test depends only on the commit
# machinery, not on serializable read-modify-write.
HANDLER_SRC = '''
export function ryw(n) {
  // Read-your-writes inside one activation (speculative overlay).
  kv.set("val", String(n));
  return kv.get("val");
}
export function put(i) {
  kv.set("k/" + i, String(i));
  return "ok";
}
export function get(i) {
  return kv.get("k/" + i) || "";
}
export default function () { return "ok"; }
'''


def q(args: list) -> str:
    return urllib.parse.quote(json.dumps(args))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("rpparity", nodes=1) as c:
        print("step 1: provision tenant via the CP")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy index.mjs")
        try:
            dep_id = c.deploy_handlers(TENANT, {"index.mjs": HANDLER_SRC})
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load (GET /?fn=get → 200)")
        ready = c.wait_for_handler(TENANT, "/?fn=get&args=" + q([0]))
        check("handler reachable", ready.status == 200, f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        # ── A. Read-your-writes within one activation. ───────────────────
        print("step A: read-your-writes within one activation")
        r = c.get(TENANT, f"/?fn=ryw&args={q([7])}")
        check("A.ryw status 200", r.status == 200, f"got {r.status}")
        check("A.ryw read-your-writes == '7'", r.body == "7", f"got {r.body!r}")

        # ── B. Commit-before-response (sequential durability). ───────────
        print(f"step B: commit-before-response across {SEQ_WRITES} seq writes")
        b_ok = True
        for i in range(1, SEQ_WRITES + 1):
            w = c.get(TENANT, f"/?fn=put&args={q([i])}")
            if w.status != 200:
                check(f"B.put[{i}] status 200", False, f"got {w.status}")
                b_ok = False
                break
            rd = c.get(TENANT, f"/?fn=get&args={q([i])}")
            if rd.status != 200 or rd.body != str(i):
                check(f"B.durability[{i}]", False,
                      f"acked write not readable next request (got {rd.body!r})")
                b_ok = False
                break
        check(f"B.commit-before-response durable across {SEQ_WRITES} seq writes", b_ok)

        # ── C. Concurrent same-tenant writes, zero dropped writesets. ────
        print(f"step C: {CONCURRENCY} concurrent distinct-key writes all commit")
        keys = list(range(1000, 1000 + CONCURRENCY))

        def do_put(i: int):
            return i, c.get(TENANT, f"/?fn=put&args={q([i])}")

        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as ex:
            results = list(ex.map(do_put, keys))
        bad = [i for i, resp in results if resp.status != 200]
        check(f"C.{CONCURRENCY} concurrent puts all 200", not bad,
              f"{len(bad)} non-200 (first few: {bad[:5]})")

        # Read every key back — any missing key is a dropped writeset.
        missing = []
        for i in keys:
            rd = c.get(TENANT, f"/?fn=get&args={q([i])}")
            if rd.status != 200 or rd.body != str(i):
                missing.append((i, rd.status, rd.body))
        check(f"C.all {CONCURRENCY} concurrent writes durable (no dropped writeset)",
              not missing, f"{len(missing)}/{CONCURRENCY} dropped (first few: {missing[:5]})")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS raft_pending_parity smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
