#!/usr/bin/env python3
"""V2 port of `schedule_cron_smoke.py` — the handler-surface Phase 5
connectionless scheduling verbs (`schedule` one-shot + `cron` recurring),
on the `V2Cluster` harness (`smoke_lib_v2`).

Handler JS is reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/{schedverb,cronverb,schedtarget,readkey}`)
— only the deploy/serve plumbing changed for V2 (no seed_manifest; tenant
is `provision()`-ed then handlers uploaded/deployed/released).

Gates (essential behavior, unchanged from V1):
  A. `schedule` — a 2 s one-shot fires the target with its tag.
  B. `cron` registration — cron("* * * * *", …) writes a durable
     `_sched/by_id/{key}` entry aimed at the baked `__system/cron_tick`,
     at a future minute boundary.
  C. `cron` recurrence — the target fires (its tag appears) AND the
     registration re-arms to a LATER occurrence (the cron_tick self-
     reschedule). crontab granularity is 1 minute → waits up to ~80 s.

Dropped from V1 (don't map to V2): TLS/https, 3-node leader election /
discover_leader (single-node behavior smoke; the front door is
serve-or-forward, not leader-direct).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants" / "acme"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# Handler JS reused verbatim from the V1 demo tenant.
HANDLERS = {
    "schedverb/index.mjs": _src("schedverb/index.mjs"),
    "cronverb/index.mjs": _src("cronverb/index.mjs"),
    "schedtarget.mjs": _src("schedtarget.mjs"),
    "readkey/index.mjs": _src("readkey/index.mjs"),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("schedcron", nodes=1) as c:
        print("step 1: provision + deploy the scheduling handlers")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_handlers("acme", HANDLERS)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # Wait for the deployment to load + serve before exercising verbs.
        r = c.wait_for_handler("acme", "/schedverb?in=0&tag=__warm",
                               want_status=200, timeout_s=25.0)
        if r.status != 200:
            check("schedverb reachable", False, f"got {r.status} {r.body!r}")
            c.dump_node_log(grep=["deploy", "loader", "manifest", "sched",
                                  "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  scheduling handlers reachable")

        # ── Gate A: schedule (one-shot) ───────────────────────────────
        r = c.get("acme", "/schedverb?in=2000&tag=sched")
        if r.status != 200:
            check("Gate A: schedverb", False, f"status={r.status} body={r.body!r}")
        else:
            try:
                sched_id = json.loads(r.body)["id"]
                print(f"ok  schedule({{in:2000}}) → id={sched_id}")
            except Exception as e:
                sched_id = None
                check("Gate A: schedverb JSON", False, f"{e} body={r.body!r}")

            # Poll the side-effect key (tag counter) via the tenant KV.
            fired = False
            deadline = time.monotonic() + 20.0
            while time.monotonic() < deadline:
                rr = c.admin_kv_get("acme", "sched-tag/sched")
                if rr.status == 200 and rr.body.strip().isdigit() and int(rr.body.strip()) >= 1:
                    fired = True
                    break
                time.sleep(0.4)
            check("Gate A: one-shot schedule fired the target", fired,
                  "sched-tag/sched still 0 after 20s" if not fired else "")
            if not fired:
                c.dump_node_log(grep=["sched", "wake", "durable", "error", "warn"])

        # ── Gate B: cron registration ─────────────────────────────────
        spec = "* * * * *"  # every minute
        r = c.get("acme", f"/cronverb?spec={urllib.parse.quote(spec)}&tag=cron")
        cron_key = None
        first_when = None
        if r.status != 200:
            check("Gate B: cronverb", False, f"status={r.status} body={r.body!r}")
        else:
            try:
                cron_key = json.loads(r.body)["key"]
                print(f"ok  cron({spec!r}) → key={cron_key}")
            except Exception as e:
                check("Gate B: cronverb JSON", False, f"{e} body={r.body!r}")

        if cron_key:
            # Registration is a durable KV entry under _sched/by_id/{key}.
            reg = None
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                rr = c.admin_kv_get("acme", f"_sched/by_id/{cron_key}")
                if rr.status == 200 and rr.body.strip():
                    try:
                        reg = json.loads(rr.body)
                        break
                    except Exception:
                        pass
                time.sleep(0.4)
            check("Gate B: cron registration durable (_sched/by_id)", reg is not None,
                  f"absent for key {cron_key}" if reg is None else "")
            if reg is not None:
                check("Gate B: cron target == __system/cron_tick",
                      reg.get("target") == "__system/cron_tick", f"{reg!r}")
                first_when = int(reg["when_ns"])
                now_ns = int(time.time() * 1e9)
                check("Gate B: cron first occurrence in the future",
                      first_when > now_ns, f"{first_when} <= {now_ns}")
                check("Gate B: cron first occurrence at next minute boundary (≤65s)",
                      first_when - now_ns <= 65 * 1_000_000_000,
                      f"{(first_when - now_ns)/1e9:.0f}s out")
                print(f"ok  cron registered durable entry "
                      f"({(first_when - now_ns)/1e9:.0f}s out)")

        # ── Gate C: cron recurrence (slow — 1-minute granularity) ─────
        if cron_key and first_when is not None:
            print("waiting up to 80s for the first cron fire + re-arm (minute boundary)…")
            fired = False
            deadline = time.monotonic() + 80.0
            while time.monotonic() < deadline:
                rr = c.admin_kv_get("acme", "sched-tag/cron")
                if rr.status == 200 and rr.body.strip().isdigit() and int(rr.body.strip()) >= 1:
                    fired = True
                    break
                time.sleep(1.0)
            check("Gate C: cron fired the target", fired,
                  "sched-tag/cron never reached 1 within 80s" if not fired else "")

            # Re-arm: the registration's when_ns advanced to a later occurrence.
            rearmed = False
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                rr = c.admin_kv_get("acme", f"_sched/by_id/{cron_key}")
                if rr.status == 200 and rr.body.strip():
                    try:
                        w = int(json.loads(rr.body)["when_ns"])
                        if w > first_when:
                            rearmed = True
                            break
                    except Exception:
                        pass
                time.sleep(0.5)
            check("Gate C: cron re-armed to a later occurrence", rearmed,
                  "cron_tick self-reschedule did not advance when_ns" if not rearmed else "")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS schedule/cron smoke (v2): one-shot schedule + recurring "
          "durable cron over the gap-2.6 scheduler")
    return 0


if __name__ == "__main__":
    sys.exit(main())
