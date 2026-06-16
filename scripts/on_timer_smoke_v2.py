#!/usr/bin/env python3
"""V2 port of `on_timer_smoke.py` — `on.timer` connection wakes
(handler-surface Phase 1 Task 3, timer slice) on the `V2Cluster` harness.

The `ontimer` handler arms `on.timer(ms)` and HOLDS the socket via `next()`
with NO webhook.send — so the only thing that can resume the parked
continuation is the timer wake. One blocking client POST:

  client ──POST /ontimer {ms,tag}──▶ acme inbound hop
     on.timer(ms) + return next(...onWake)
        → StreamWakes armed (interval=ms) on the held continuation
        → entity parks in worker.parked_continuations (held; no response)
     ~ms later: sweepParkedContinuations sees now >= next_wake_ns →
        resumeContinuation(wake) runs onWake(ctx) → terminal →
        resolveParked flushes to the STILL-OPEN socket
  ◀── 200 "woke:<tag>"  (resumed by the timer, ~ms after the request)

A fast-but-not-instant return proves the path: instant (<~ms) would mean
the cont never held; ~25s would mean the §6.4 deadline fired instead of
the timer. Single node/worker so the park + the leader's sweep are the
same worker (cross-worker is orthogonal).

Dropped from V1 (V2-irrelevant): TLS/https, leader-direct addressing /
discover_leader, seed_manifest (V2 provisions+deploys explicitly).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# The `ontimer` handler — verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/ontimer/index.mjs).
ONTIMER_SRC = """\
export default function () {
    const req = request.body ? JSON.parse(request.body) : {};
    on.timer(req.ms || 150);
    return next({ tag: req.tag || "t" });
}

export function onWake() {
    const ctx = request.ctx || {};
    return "woke:" + ctx.tag;
}
"""

# A trivial root route, deployed alongside, so `wait_for_handler` can poll a
# non-holding GET to confirm the deployment loaded (the ontimer route HOLDS,
# so it can't be used as a readiness probe).
READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("on-timer", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the ontimer handler (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "ontimer/index.mjs": ONTIMER_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load (GET / → 'ready')")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])

        # THE held request: one blocking POST resumed by the timer wake.
        ms = 250
        print(f"step 4: held POST /ontimer {{ms:{ms},tag:'x'}} — resumed by the timer")
        t0 = time.monotonic()
        r = c.request("acme", "/ontimer", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"ms": ms, "tag": "x"}),
                      timeout=30.0)  # > 25s §6.4 deadline so a 504 still returns
        elapsed = time.monotonic() - t0

        check("on.timer → 200", r.status == 200, f"got {r.status} {r.body!r} ({elapsed:.2f}s)")
        check("on.timer body == 'woke:x'", r.body == "woke:x",
              f"got {r.body!r} ({elapsed:.2f}s)")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn", "timer", "wake", "park"])
        # Fast-but-not-instant: held for ~the timer, then resumed.
        check("on.timer held (not instant)", elapsed >= (ms / 1000.0) * 0.5,
              f"returned in {elapsed:.3f}s — too fast; continuation didn't hold")
        check("on.timer not deadline-504 path", elapsed < 15.0,
              f"returned correct body but in {elapsed:.1f}s — that's the §6.4 deadline")
        if r.status == 200 and r.body == "woke:x":
            print(f"  ok  on.timer wake resumed: '{r.body}' in {elapsed:.3f}s "
                  f"(timer ~{ms}ms, not instant, not deadline)")

        # Second request, different tag + interval — proves the path isn't a
        # one-off and onWake sees the right ctx each time.
        print("step 5: second held POST {ms:120,tag:'y'} — proves it's not a one-off")
        t0 = time.monotonic()
        r2 = c.request("acme", "/ontimer", method="POST",
                       headers={"content-type": "application/json"},
                       data=json.dumps({"ms": 120, "tag": "y"}),
                       timeout=30.0)
        el2 = time.monotonic() - t0
        check("2nd on.timer → 200 'woke:y'", r2.status == 200 and r2.body == "woke:y",
              f"got {r2.status} {r2.body!r} ({el2:.2f}s)")
        check("2nd on.timer timing in range", 0.05 <= el2 < 15.0,
              f"timing {el2:.3f}s out of range")
        if r2.status == 200 and r2.body == "woke:y":
            print(f"  ok  second on.timer wake resumed: '{r2.body}' in {el2:.3f}s")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS on.timer smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
