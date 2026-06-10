#!/usr/bin/env python3
"""Successor to `streaming_subscription_cron_smoke_v2.py` — sub-minute
interval recurrence on the durable scheduler (durable-wake-plan P5(b)).

The manifest `kind=cron` subscription (a non-durable in-memory interval
clock, `CronState` + `sweepCronSubscriptions`) is RETIRED. This smoke
proves the migration recipe gives the same behavior, durably:

  - a `kind=boot` subscription's `onBoot` seeds
    `scheduler.after(1000, "heartbeat", null, {key: "heartbeat"})`;
  - the `heartbeat` target increments `hb-fire-count`, stamps
    `hb-last-fired-at-ns`, and RE-ARMS itself with the same key
    ("recurring = a one-shot that re-arms itself").

Assertions kept from the retired cron smoke (interval-recurrence parity):
  1. `hb-fire-count` reaches >= 2 within a short window.
  2. `hb-last-fired-at-ns` is a recent ns timestamp.
  3. The count keeps advancing on a longer wait (re-arm chain isn't stuck).

Plus the retirement itself:
  4. Deploying a `kind=cron` spec.json FAILS the deploy loudly (the
     tenant's release never goes live; the node log carries the
     "kind=cron is retired" migration error).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# onBoot seed: registers the first heartbeat wake. The idempotency key
# makes redeploys harmless (same key ⇒ same id ⇒ last-write-wins).
BOOT_SEED_SRC = r'''export function onBoot() {
    scheduler.after(1000, "heartbeat", { n: 0 }, { key: "heartbeat" });
    kv.set("hb-seeded", "1");
    return { status: 200 };
}'''

# The recurring target: count + stamp + re-arm. `request.activation`
# carries {kind:"durable_wake", id, key, scheduled_at_ns, msg}.
HEARTBEAT_SRC = r'''export default function () {
    const a = request.activation;
    if (a.kind !== "durable_wake") return { status: 200 };
    const count = parseInt(kv.get("hb-fire-count") ?? "0", 10) + 1;
    kv.set("hb-fire-count", String(count));
    kv.set("hb-last-fired-at-ns", String(BigInt(Date.now()) * 1_000_000n));
    // Re-arm for the next interval — same key keeps it one entry.
    scheduler.after(1000, "heartbeat", { n: count }, { key: a.key });
    return { status: 200 };
}'''

INDEX_SRC = r'''export default function () { return { status: 200, body: "ok" }; }'''

HANDLERS = {
    "index.mjs": ("handler", INDEX_SRC),
    "heartbeat.mjs": ("handler", HEARTBEAT_SRC),
    "_subscriptions/boot-seed/index.mjs": ("handler", BOOT_SEED_SRC),
    "_subscriptions/boot-seed/spec.json": ("static", '{"kind":"boot"}'),
}

# The retired surface — must fail the deploy loudly.
CRON_SPEC_HANDLERS = {
    "index.mjs": ("handler", INDEX_SRC),
    "_subscriptions/old-cron/index.mjs": ("handler", INDEX_SRC),
    "_subscriptions/old-cron/spec.json": ("static", '{"kind":"cron","interval_ms":1000}'),
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

    with V2Cluster.spawn("sched-hb", nodes=1) as c:
        print("step 1: provision + deploy acme (boot-seeded scheduler heartbeat)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_manifest("acme", HANDLERS)
            check("deploy_manifest → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_manifest", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("acme", "/", want_status=200, timeout_s=25.0)
        if r.status != 200:
            check("acme reachable", False, f"got {r.status} {r.body!r}")
            c.dump_node_log(grep=["deploy", "loader", "subscription", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  acme reachable")

        # ── 1. heartbeat fires >= 2 times (seed → fire → re-arm → fire). ──
        # First fire ~1-2s after the boot seed commits (1s interval rounded
        # up to the 1s tick + 1Hz sweep); each re-arm adds ~1-2s.
        print("waiting up to 25s for the heartbeat to fire 2+ times…")
        count = None
        deadline = time.monotonic() + 25.0
        while time.monotonic() < deadline:
            n = _read_int(c, "acme", "hb-fire-count")
            if n is not None and n >= 2:
                count = n
                break
            time.sleep(0.5)
        check("heartbeat fired >= 2 times", count is not None and count >= 2,
              f"hb-fire-count={count}")
        if count is None or count < 2:
            c.dump_node_log(grep=["sched", "wake", "boot", "fire", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print(f"ok  heartbeat fired {count} time(s)")

        # ── 2. last-fired stamp is a recent ns timestamp. ─────────────
        last = _read_int(c, "acme", "hb-last-fired-at-ns")
        if last is None:
            check("hb-last-fired-at-ns present", False, "absent")
        else:
            age_s = (int(time.time() * 1e9) - last) / 1e9
            check("heartbeat stamp is recent (within 10s)",
                  -10.0 < age_s < 10.0, f"{age_s:.2f}s old")

        # ── 3. count keeps advancing (re-arm chain isn't stuck). ──────
        time.sleep(4.0)
        count2 = _read_int(c, "acme", "hb-fire-count")
        check("heartbeat count advances over time",
              count2 is not None and count2 > count,
              f"{count} → {count2}")

        # ── 4. kind=cron spec.json fails the deploy loudly. ───────────
        print("step 2: kind=cron spec.json is rejected at deploy")
        r = c.provision("legacy")
        check("provision legacy → 204", r.status == 204, f"got {r.status}")
        try:
            c.deploy_manifest("legacy", CRON_SPEC_HANDLERS)
        except RuntimeError as e:
            # Upload/release-stage rejection also counts as loud.
            print(f"ok  deploy rejected at release: {e}")
        # The spec parse happens at deployment LOAD — the release flips
        # but the loader refuses the snapshot, so the tenant never
        # serves, and the log carries the migration error.
        r = c.wait_for_handler("legacy", "/", want_status=200, timeout_s=8.0)
        check("legacy tenant did NOT go live", r.status != 200,
              f"got {r.status} (kind=cron should fail the deploy)")
        log_text = ""
        for name, path in c.log_paths.items():
            if name.startswith("n"):
                log_text += Path(path).read_text(errors="replace")
        check("node log carries the kind=cron retirement error",
              "kind=cron is retired" in log_text,
              "migration error line absent from node logs")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS scheduler-heartbeat smoke (v2): boot-seeded self-re-arming "
          "scheduler.after interval recurrence + loud kind=cron retirement")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
