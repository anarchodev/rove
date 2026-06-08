#!/usr/bin/env python3
"""V2 port of `penalty_smoke.py` — CPU-budget interrupt handler + penalty
box (`src/js/penalty.zig`, `PLAN §2.10`) on the `V2Cluster` harness
(`smoke_lib_v2`).

The `penalty` tenant's handler is an infinite `while (true) {}` loop, so
every activation blows the per-handler CPU budget → the interrupt fires
→ `DispatchError.Interrupted` → 504 + `penalty_box.recordKill`. After
`kill_threshold` (default 3) kills within the window the penalty box
flips OPEN and the worker short-circuits subsequent requests to 503
(`isBoxed` → "tenant temporarily disabled (cpu budget)").

Asserts (unchanged from V1):
  1. First 3 requests hit the budget → 504 each.
  2. 4th request: box trips open (kill_threshold=3) → 503 short-circuit.
  3. 5th + 6th: still boxed → 503.

Handler JS reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/penalty/index.mjs`) — `export function
handler()` invoked via `?fn=handler`.

Single node, single worker (the V2Cluster default) — the penalty box is
per-worker, so a single worker makes the kill-count → box-trip threshold
deterministic.

Dropped from V1: TLS/https, leader election / discover_leader (the V1
`discover_leader_via_404` probe), seed_manifest. Readiness is probed via
a bare `/` GET, which returns 404 once the deployment loads (the handler
is a named export, no `default`) — NOT via the handler path, since
probing `?fn=handler` would consume a budget kill and shift the box-trip
threshold.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


PENALTY_HANDLERS = {
    "index.mjs": _src("penalty/index.mjs"),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("penalty", nodes=1) as c:
        print("step 1: provision + deploy penalty (runaway while(true) handler)")
        r = c.provision("penalty")
        check("provision penalty → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("penalty", PENALTY_HANDLERS)
            check("deploy penalty", True)
        except RuntimeError as e:
            check("deploy penalty", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # Wait for the deployment to load — probe the BARE route (no
        # default export → 404 when ready, 503 when no_deployment).
        # Probing the handler itself would consume a budget kill and shift
        # the box-trip threshold.
        deadline = time.time() + 25.0
        ready = False
        while time.time() < deadline:
            r = c.get("penalty", "/", timeout=3.0)
            if r.status == 404:
                ready = True
                break
            time.sleep(0.3)
        check("deployment loaded (bare route → 404)", ready,
              f"last status {r.status}")
        if not ready:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "penalty",
                                  "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        url = "/?fn=handler"

        # First three: each hits the CPU budget → 504 (interrupt kill).
        for i in (1, 2, 3):
            r = c.request("penalty", url, timeout=10.0)
            check(f"request {i} (expect 504 from budget kill)",
                  r.status == 504, f"got {r.status}")

        # Fourth: penalty box now open (kill_threshold=3) → 503.
        r = c.request("penalty", url, timeout=10.0)
        check("request 4 (expect 503 from penalty box)",
              r.status == 503, f"got {r.status}")

        # Fifth + sixth stay 503.
        for i in (5, 6):
            r = c.request("penalty", url, timeout=10.0)
            check(f"request {i} (expect 503, still boxed)",
                  r.status == 503, f"got {r.status}")

        if failures:
            c.dump_node_log(grep=["penalty", "budget", "504", "503",
                                  "interrupt", "box", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS penalty smoke (v2): 3 CPU-budget kills (504) trip the "
          "penalty box open; subsequent requests short-circuit to 503")
    return 0


if __name__ == "__main__":
    sys.exit(main())
