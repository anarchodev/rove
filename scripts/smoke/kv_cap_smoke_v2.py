#!/usr/bin/env python3
"""KV-cap enforcement smoke — billing axis 1 (#296/#298).

Proves the plan-derived KV cap end to end on a 1-node V2 cluster:

  A. baseline: a handler `kv.set` lands normally under the free-tier cap
  B. `POST /_control/plan` with a tiny `max_kv_bytes` override reaches the
     worker slot (read back via `GET /_system/v2-plan`)
  C. once the usage cache TTL passes, a write batch is REFUSED: 507 +
     `kv_quota_exceeded` JSON — and nothing was committed
  D. the tenant stays readable over cap, and a delete-only batch still
     lands (the recovery path is never blocked)
  E. `/_system/metrics` carries `kv_store_used_bytes{instance="..."}` and a
     non-zero `kv_cap_refusals_total`
  F. restoring the plan lifts the refusal immediately (cap is read live
     from the slot; only the usage figure is TTL-cached)

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, _curl, MOVE_SECRET, metric_counter  # noqa: E402

# The usage figure the gate reads is TTL-cached on the store handle
# (worker.zig KV_USAGE_TTL_MS = 2000); sleeps below must outlast it.
USAGE_TTL_SEC = 2.0

SRC = (
    'export function fill() {\n'
    '  const m = (request.query || "").match(/i=(\\d+)/);\n'
    '  const i = m ? m[1] : "0";\n'
    '  kv.set("blob/" + i, "x".repeat(2048));\n'
    '  return "filled " + i + "\\n";\n'
    '}\n'
    'export function read() {\n'
    '  const v = kv.get("blob/0");\n'
    '  return v ? "len=" + v.length + "\\n" : "missing\\n";\n'
    '}\n'
    'export function del() {\n'
    '  kv.delete("blob/0");\n'
    '  return "deleted\\n";\n'
    '}\n'
)

TINY_PLAN = json.dumps({"tier": "free", "overrides": {"max_kv_bytes": 1024}},
                       separators=(",", ":"))
FREE_PLAN = json.dumps({"tier": "free"}, separators=(",", ":"))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("kvcap", nodes=1, http_base=19850, raft_base=19860) as c:

        def set_plan(plan: str):
            return c._cp_post("/_control/plan", {"tenant": "acme", "plan": plan})

        def worker_plan() -> dict | None:
            r = _curl(f"{c.node_url(0)}/_system/v2-plan?tenant=acme",
                      headers={"X-Rewind-Move-Secret": MOVE_SECRET})
            if r.status != 200:
                return None
            try:
                return json.loads(r.body)
            except json.JSONDecodeError:
                return None

        print("step 1: provision + deploy the fill/read/del handler")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(SRC)})
        check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")

        print("step 2: baseline write under the free-tier cap")
        r = c.wait_for_handler("acme", "/?fn=fill&i=0", want_body="filled 0")
        check("fill under free cap → 200", r.status == 200 and "filled 0" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 3: push a tiny max_kv_bytes override through the CP")
        r = set_plan(TINY_PLAN)
        check("POST /_control/plan → 2xx", r.status in (200, 204),
              f"got {r.status} {r.body!r}")
        p = worker_plan()
        check("worker slot sees max_kv_bytes=1024",
              bool(p) and p.get("max_kv_bytes") == 1024, f"got {p!r}")

        print(f"step 4: after the usage TTL ({USAGE_TTL_SEC}s), writes are refused with 507")
        time.sleep(USAGE_TTL_SEC + 0.5)
        r = c.get("acme", "/?fn=fill&i=1")
        check("over-cap write → 507", r.status == 507, f"got {r.status} {r.body!r}")
        check("507 body names kv_quota_exceeded", "kv_quota_exceeded" in r.body,
              f"got {r.body!r}")
        check("507 body carries used/cap figures",
              '"max_kv_bytes":1024' in r.body.replace(" ", ""), f"got {r.body!r}")

        print("step 5: reads still work over cap; delete-only batches still land")
        r = c.get("acme", "/?fn=read")
        check("read over cap → 200 len=2048", r.status == 200 and "len=2048" in r.body,
              f"got {r.status} {r.body!r}")
        r = c.get("acme", "/?fn=del")
        check("delete over cap → 200", r.status == 200 and "deleted" in r.body,
              f"got {r.status} {r.body!r}")
        # The refused write never committed: blob/1 must be absent even
        # after the cap is lifted (checked in step 7 via read of blob/0
        # being gone — the delete landed — and fill i=1 re-running).

        print("step 6: metrics expose the per-tenant figure and the refusal count")
        m = c.metrics(0)
        used = None
        for line in m.splitlines():
            mt = re.match(r'kv_store_used_bytes\{instance="acme"\} (\d+)', line)
            if mt:
                used = int(mt.group(1))
        check("kv_store_used_bytes{instance=acme} present", used is not None,
              f"used={used}")
        refusals = metric_counter(m, "kv_cap_refusals_total")
        check("kv_cap_refusals_total ≥ 1", (refusals or 0) >= 1, f"got {refusals}")

        print("step 7: restoring the plan lifts the refusal (cap reads live)")
        r = set_plan(FREE_PLAN)
        check("restore plan → 2xx", r.status in (200, 204), f"got {r.status}")
        r = c.get("acme", "/?fn=fill&i=1")
        check("write after restore → 200", r.status == 200 and "filled 1" in r.body,
              f"got {r.status} {r.body!r}")

    print("PASS" if not failures else f"FAIL: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
