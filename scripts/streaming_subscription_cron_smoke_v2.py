#!/usr/bin/env python3
"""V2 port of `streaming_subscription_cron_smoke.py` — cron subscription
chain origin firing on a fixed interval (Gap 2.1 Phase F), on the
`V2Cluster` harness.

`acme/_subscriptions/heartbeat-cron/{spec.json,index.mjs}` declares a cron
subscription with `interval_ms=1000`. The leader's worker runs a throttled
1Hz `sweepCronSubscriptions` over in-memory `next_fire_at_ns` state and
enqueues fires that are due (leader-gated; single node here is always
leader). The handler (`onCron`) increments `cron-fire-count` and stamps
`cron-last-fired-at-ns` from `request.activation.source.firedAt`.

NOTE: this is the SUBSCRIPTION cron (a fast interval_ms sweep), distinct
from the crontab `cron("* * * * *")` scheduler exercised by
`schedule_cron_smoke_v2.py` (which fires on minute boundaries). This one
fires ~every second, so the smoke only needs a few-second window.

Subscription module + handlers reused VERBATIM from the V1 demo tenant.

Essential assertions kept from V1:
  1. `cron-fire-count` reaches >= 2 within a short window (sweep fires the
     target repeatedly).
  2. `cron-last-fired-at-ns` is a recent ns timestamp (firedAt is fresh
     per fire).
  3. The count keeps advancing on a longer wait (sweeper isn't stuck).

Dropped from V1: TLS/https, 3-node leader election / discover_leader
(single-node behavior smoke). Side-effect keys read via the worker's
move-secret-gated `admin_kv_get`.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants" / "acme"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# Subscription module + handlers reused verbatim from the V1 demo tenant.
# spec.json MUST deploy as `static` (the loader skips non-static specs).
HANDLERS = {
    "index.mjs": ("handler", _src("index.mjs")),
    "readkey/index.mjs": ("handler", _src("readkey/index.mjs")),
    "_subscriptions/heartbeat-cron/index.mjs":
        ("handler", _src("_subscriptions/heartbeat-cron/index.mjs")),
    "_subscriptions/heartbeat-cron/spec.json":
        ("static", _src("_subscriptions/heartbeat-cron/spec.json")),
}


def _read_int(c, tenant, key):
    rr = c.admin_kv_get(tenant, key)
    if rr.status == 200 and rr.body.strip().lstrip("-").isdigit():
        return int(rr.body.strip())
    return None


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("sub-cron", nodes=1) as c:
        print("step 1: provision + deploy acme (heartbeat-cron subscription)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_manifest("acme", HANDLERS)
            check("deploy_manifest → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_manifest", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("acme", "/?fn=handler", want_status=200,
                               timeout_s=25.0)
        if r.status != 200:
            check("acme reachable", False, f"got {r.status} {r.body!r}")
            c.dump_node_log(grep=["deploy", "loader", "manifest", "cron",
                                  "subscription", "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  acme reachable")

        # ── 1. cron fires >= 2 times. ─────────────────────────────────
        # The cron sub's first-sight init pauses one interval (1s), then
        # fires every 1s on the throttled sweep. Give a generous window.
        print("waiting up to 20s for the cron sub to fire 2+ times…")
        count = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            n = _read_int(c, "acme", "cron-fire-count")
            if n is not None and n >= 2:
                count = n
                break
            time.sleep(0.5)
        check("cron subscription fired >= 2 times", count is not None and count >= 2,
              f"cron-fire-count={count}")
        if count is None or count < 2:
            c.dump_node_log(grep=["cron", "sweep", "subscription", "fire",
                                  "wake", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print(f"ok  cron fired {count} time(s)")

        # ── 2. firedAt is a recent ns timestamp. ──────────────────────
        last = _read_int(c, "acme", "cron-last-fired-at-ns")
        if last is None:
            check("cron-last-fired-at-ns present", False, "absent")
        else:
            now_ns = int(time.time() * 1e9)
            age_s = (now_ns - last) / 1e9
            check("cron firedAt timestamp is recent (within 10s)",
                  -10.0 < age_s < 10.0, f"{age_s:.2f}s old")

        # ── 3. count keeps advancing (sweeper not stuck). ─────────────
        time.sleep(3.0)
        count2 = _read_int(c, "acme", "cron-fire-count")
        check("cron count advances over time",
              count2 is not None and count2 > count,
              f"{count} → {count2}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming-subscription-cron smoke (v2): throttled cron sweep "
          "+ in-memory next_fire_at_ns fires the subscription on its interval")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
