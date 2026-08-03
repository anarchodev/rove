#!/usr/bin/env python3
"""Storage-quota enforcement smoke — billing axis 3 (#347/#349).

Proves the plan-derived object-storage quota end to end on a 1-node V2
cluster. The two halves only work together, and this is the only place that
shows it: enforcement compares the plan's `max_stored_bytes` against a total
SUMMED FROM THE ACCOUNTING ROWS, so a refusal can only happen if the writers
actually recorded what the tenant stored.

  A. baseline: `blob.put` under the (unmetered) default stores, and its
     durable `_blob/owed/{hash}` marker clears — the platform saw the PUT land
  B. `POST /_control/plan` with a tiny `max_stored_bytes` override reaches the
     worker slot (read back via `GET /_system/v2-plan`)
  C. once the usage cache TTL passes, a further `blob.put` is REFUSED: the
     owed marker persists stamped `failed: true, last_status: 507` — the
     existing contract for a store that did not happen
  D. READS STILL WORK over cap — `blob.url` on the already-stored object still
     mints a presigned URL, so a tenant at their ceiling can export their way
     out rather than being locked in
  E. restoring the plan lifts the refusal immediately (the cap is read live
     from the slot; only the usage figure is TTL-cached)

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, _curl, MOVE_SECRET  # noqa: E402

# The stored-bytes figure the gate reads is TTL-cached (usage.STORED_TTL_MS =
# 2000); sleeps below must outlast it.
USAGE_TTL_SEC = 2.0

# How long to wait for an async blob PUT to settle its owed marker.
SETTLE_TIMEOUT_SEC = 20.0

SRC = (
    'function key() {\n'
    '  const m = (request.query || "").match(/k=([a-z]+)/);\n'
    '  return m ? m[1] : "x";\n'
    '}\n'
    '// Payload varies BY KEY so each step stores a distinct object. Identical\n'
    '// bytes would content-address to one hash, and dedup would hide whether\n'
    '// a step stored anything at all.\n'
    'export function store() {\n'
    '  const hash = blob.put(key().repeat(512));\n'
    '  kv.set("h/" + key(), hash);\n'
    '  return hash + "\\n";\n'
    '}\n'
    '// The owed marker IS the platform\'s record of whether the PUT landed:\n'
    '// cleared on success, kept + stamped on failure.\n'
    'export function marker() {\n'
    '  const h = kv.get("h/" + key());\n'
    '  if (!h) return "no-hash\\n";\n'
    '  const m = kv.get("_blob/owed/" + h);\n'
    '  return (m === null ? "cleared" : "owed " + m) + "\\n";\n'
    '}\n'
    'export function url() {\n'
    '  const h = kv.get("h/" + key());\n'
    '  if (!h) return "no-hash\\n";\n'
    '  return blob.url(h, { ttl: 60 }).startsWith("http") ? "signed\\n" : "bad\\n";\n'
    '}\n'
)

# 1 byte: the deploy alone already stores more than this in file-blobs, so any
# further object put is over the line. Deliberately not a round number that
# could accidentally match a real figure.
TINY_PLAN = json.dumps({"tier": "free", "overrides": {"max_stored_bytes": 1}},
                       separators=(",", ":"))
FREE_PLAN = json.dumps({"tier": "free"}, separators=(",", ":"))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("storagecap", nodes=1) as c:

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

        def settle(k: str) -> str:
            """Poll the owed marker until the async PUT resolves it."""
            deadline = time.monotonic() + SETTLE_TIMEOUT_SEC
            last = ""
            while time.monotonic() < deadline:
                r = c.get("acme", f"/?fn=marker&k={k}")
                last = r.body.strip()
                # "cleared" = stored; "owed {json}" with failed:true = refused.
                if last == "cleared" or '"failed":true' in last.replace(" ", ""):
                    return last
                time.sleep(0.3)
            return last

        print("step 1: provision + deploy the store/marker/url handler")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(SRC)})
        check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")

        print("step 2: baseline blob.put under the unmetered default")
        r = c.wait_for_handler("acme", "/?fn=store&k=a")
        check("store under default → 200", r.status == 200, f"got {r.status} {r.body!r}")
        settled = settle("a")
        check("owed marker cleared → the PUT landed", settled == "cleared",
              f"got {settled!r}")

        print("step 3: push a tiny max_stored_bytes override through the CP")
        r = set_plan(TINY_PLAN)
        check("POST /_control/plan → 2xx", r.status in (200, 204),
              f"got {r.status} {r.body!r}")
        p = worker_plan()
        check("worker slot sees max_stored_bytes=1",
              bool(p) and p.get("max_stored_bytes") == 1, f"got {p!r}")

        print(f"step 4: after the usage TTL ({USAGE_TTL_SEC}s), a blob.put is refused")
        time.sleep(USAGE_TTL_SEC + 0.5)
        r = c.get("acme", "/?fn=store&k=b")
        # The handler still succeeds — blob.put returns the hash synchronously
        # and the refusal lands on the async PUT, exactly as a storage failure
        # would.
        check("store call itself → 200", r.status == 200, f"got {r.status} {r.body!r}")
        settled = settle("b")
        flat = settled.replace(" ", "")
        check("over-quota PUT refused → marker kept, failed:true",
              '"failed":true' in flat, f"got {settled!r}")
        check("refusal carries last_status 507", '"last_status":507' in flat,
              f"got {settled!r}")

        print("step 5: reads still work over cap — the export path stays open")
        r = c.get("acme", "/?fn=url&k=a")
        check("blob.url over cap → 200 signed", r.status == 200 and "signed" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 6: restoring the plan lifts the refusal (cap reads live)")
        r = set_plan(FREE_PLAN)
        check("restore plan → 2xx", r.status in (200, 204), f"got {r.status}")
        r = c.get("acme", "/?fn=store&k=c")
        check("store after restore → 200", r.status == 200, f"got {r.status} {r.body!r}")
        settled = settle("c")
        check("owed marker cleared again", settled == "cleared", f"got {settled!r}")

    print("PASS" if not failures else f"FAIL: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
