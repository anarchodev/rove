#!/usr/bin/env python3
"""`schedule(..., "module.method")` fires the NAMED export.

Regression guard for the durable-wake target resolution: a `schedule`/`cron`
target of the form `"module.method"` must fire that export, not `default`
(the worker previously ignored the method and always ran `default`). A bare
module target still fires `default`.

Single tenant on one node:
  - `index.mjs?target=<t>` arms `schedule({in: ~1s}, <t>, {tag})` and returns
    `{id}`.
  - `jobs.mjs` records which export fired: `default` → kv `fired_default`,
    `weekly` → kv `fired_weekly` (each a running count).

Gates:
  A. `schedule(..., "jobs.mjs.weekly")` → `fired_weekly` increments,
     `fired_default` does NOT (the #9 fix).
  B. `schedule(..., "jobs.mjs")` (bare) → `fired_default` increments.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

INDEX_SRC = r"""export default function () {
    const q = new URLSearchParams(request.query || "");
    const target = q.get("target") || "jobs.mjs.weekly";
    const id = schedule({ in: 1000 }, target, { tag: q.get("tag") || "m" });
    return { id: id, target: target };
}
"""

# A target module with BOTH a default and a named `weekly` export; each
# records its own fire so the smoke can tell which one the wake hit.
# Underscore keys (no slash) so admin_kv_get's raw query read works.
JOBS_SRC = r"""function bump(which) {
    const k = "fired_" + which;
    kv.set(k, String(parseInt(kv.get(k) || "0", 10) + 1));
    kv.set("last_export", which);
}
export default function () {
    if (request.activation.kind !== "durable_wake") return { status: 200 };
    bump("default");
    return { status: 200 };
}
export function weekly() {
    if (request.activation.kind !== "durable_wake") return { status: 200 };
    bump("weekly");
    return { status: 200 };
}
"""

HANDLERS = {
    "index.mjs": INDEX_SRC,
    "jobs.mjs": JOBS_SRC,
}


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    def kv_int(c, key):
        rr = c.admin_kv_get("acme", key)
        if rr.status == 200 and rr.body.strip().lstrip("-").isdigit():
            return int(rr.body.strip())
        return None

    def kv_str(c, key):
        rr = c.admin_kv_get("acme", key)
        return rr.body.strip() if rr.status == 200 else None

    # Durable wakes are at-least-once (a target may fire more than once
    # across the re-scan), so gate on ">= 1", not "== 1".
    def wait_kv_ge(c, key, want, timeout_s=25.0):
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            v = kv_int(c, key)
            if v is not None and v >= want:
                return True
            time.sleep(0.5)
        return False

    with V2Cluster.spawn("schedmethod", nodes=1) as c:
        print("step 1: provision + deploy")
        r = c.provision("acme")
        check("provision acme → 200", r.status == 200, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", HANDLERS)
            check("deploy handlers", True)
        except RuntimeError as e:
            check("deploy handlers", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("acme", "/?target=" + up.quote("jobs.mjs.weekly"),
                               want_status=200, timeout_s=25.0)
        check("index reachable", r.status == 200, f"got {r.status} {r.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "sched", "resolve", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        # ── Gate A: module.method fires the NAMED export ──────────────
        r = c.get("acme", "/?target=" + up.quote("jobs.mjs.weekly") + "&tag=A")
        armed = r.status == 200 and json.loads(r.body).get("target") == "jobs.mjs.weekly"
        check("Gate A: armed jobs.mjs.weekly", armed, f"status={r.status} body={r.body!r}")
        if armed:
            fired = wait_kv_ge(c, "fired_weekly", 1)
            check("Gate A: `weekly` export fired (fired_weekly >= 1)", fired,
                  f"fired_weekly={kv_int(c, 'fired_weekly')}")
            check("Gate A: last export dispatched was `weekly`",
                  kv_str(c, "last_export") == "weekly",
                  f"last_export={kv_str(c, 'last_export')!r}")
            # The default export must NOT have run for a module.method target.
            check("Gate A: `default` did NOT fire (fired_default absent)",
                  kv_int(c, "fired_default") in (None, 0),
                  f"fired_default={kv_int(c, 'fired_default')}")

        # ── Gate B: bare module still fires `default` ─────────────────
        r = c.get("acme", "/?target=" + up.quote("jobs.mjs") + "&tag=B")
        armed_b = r.status == 200
        check("Gate B: armed bare jobs.mjs", armed_b, f"status={r.status} body={r.body!r}")
        if armed_b:
            fired_b = wait_kv_ge(c, "fired_default", 1)
            check("Gate B: `default` export fired (fired_default >= 1)", fired_b,
                  f"fired_default={kv_int(c, 'fired_default')}")

        if failures:
            c.dump_node_log(grep=["sched", "durable", "resolve", "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS schedule module.method smoke (v2): named export fires; bare → default")
    return 0


if __name__ == "__main__":
    sys.exit(main())
