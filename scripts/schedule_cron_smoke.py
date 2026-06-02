#!/usr/bin/env python3
"""End-to-end smoke for the handler-surface Phase 5 connectionless
scheduling verbs — `schedule` (one-shot) and `cron` (recurring) — built
over the gap-2.6 scheduler.

  acme/schedverb  — schedule({ in: ms }, "schedtarget", { tag })
  acme/cronverb   — cron(spec, "schedtarget", { tag }) → returns the key
  acme/schedtarget — the target; records per-tag fire counts to kv
  acme/readkey    — reads a kv key (existing demo helper)

Gates:
  A. `schedule` — a 2 s one-shot fires the target with its tag.
  B. `cron` registration — cron("* * * * *", …) writes a durable
     `_sched/by_id/{key}` entry aimed at the baked `__system/cron_tick`,
     at a future minute boundary.
  C. `cron` recurrence — the target fires (its tag appears) AND the
     registration re-arms to a LATER occurrence (the cron_tick self-
     reschedule). NOTE: crontab granularity is 1 minute, so this gate
     waits up to ~80 s for the first minute boundary.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc5sc501"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def _readkey(cc, origin: str, key: str):
    return curl(cc, f"{origin}/readkey?key={urllib.parse.quote(key)}", method="GET")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="schedule-cron-smoke",
        http_base=8540,
        raft_base=40640,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        origin = f"https://{ACME_HOST}:{c.leader_port()}"
        cc = c.curl_ctx(ACME_HOST)
        print(f"ok  leader=node{c.leader_idx}")

        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            try:
                if curl(cc, f"{origin}/", method="GET").status in (200, 404):
                    break
            except (RuntimeError, subprocess.TimeoutExpired):
                pass  # transient RST during startup
            time.sleep(0.2)
        else:
            sys.exit("FAIL acme not reachable on leader")
        print("ok  acme reachable on leader")

        # ── Gate A: schedule (one-shot) ───────────────────────────────
        r = curl(cc, f"{origin}/schedverb?in=2000&tag=sched", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL schedverb: status={r.status} body={r.body}")
        sched_id = json.loads(r.body)["id"]
        print(f"ok  schedule({{in:2000}}) → id={sched_id}")

        deadline = time.monotonic() + 12.0
        while time.monotonic() < deadline:
            rr = _readkey(cc, origin, "sched-tag/sched")
            if rr.status == 200 and int(rr.body.strip()) >= 1:
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL schedule one-shot never fired (sched-tag/sched still 0 after 12s)")
        print("ok  schedule one-shot fired the target")

        # ── Gate B: cron registration ─────────────────────────────────
        spec = "* * * * *"  # every minute
        r = curl(cc, f"{origin}/cronverb?spec={urllib.parse.quote(spec)}&tag=cron", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL cronverb: status={r.status} body={r.body}")
        cron_key = json.loads(r.body)["key"]
        print(f"ok  cron({spec!r}) → key={cron_key}")

        rr = _readkey(cc, origin, f"_sched/by_id/{cron_key}")
        if rr.status != 200:
            sys.exit(f"FAIL cron registration absent (_sched/by_id/{cron_key}): {rr.status}")
        reg = json.loads(rr.body)
        if reg.get("target") != "__system/cron_tick":
            sys.exit(f"FAIL cron target != __system/cron_tick: {reg!r}")
        first_when = int(reg["when_ns"])
        now_ns = int(time.time() * 1e9)
        if first_when <= now_ns:
            sys.exit(f"FAIL cron first occurrence not in the future: {first_when} <= {now_ns}")
        if first_when - now_ns > 65 * 1_000_000_000:
            sys.exit(f"FAIL cron first occurrence > 65s out (not a minute boundary?): {first_when}")
        print(f"ok  cron registered a durable entry at the next minute ({(first_when - now_ns)/1e9:.0f}s out)")

        # ── Gate C: cron recurrence (slow — 1-minute granularity) ─────
        print("waiting up to 80s for the first cron fire + re-arm (minute boundary)…")
        deadline = time.monotonic() + 80.0
        fired = False
        while time.monotonic() < deadline:
            rr = _readkey(cc, origin, "sched-tag/cron")
            if rr.status == 200 and int(rr.body.strip()) >= 1:
                fired = True
                break
            time.sleep(1.0)
        if not fired:
            sys.exit("FAIL cron target never fired within 80s")
        print("ok  cron fired the target")

        # Re-arm: the registration's when_ns advanced to a later occurrence.
        deadline = time.monotonic() + 10.0
        rearmed = False
        while time.monotonic() < deadline:
            rr = _readkey(cc, origin, f"_sched/by_id/{cron_key}")
            if rr.status == 200:
                w = int(json.loads(rr.body)["when_ns"])
                if w > first_when:
                    rearmed = True
                    break
            time.sleep(0.5)
        if not rearmed:
            sys.exit("FAIL cron did not re-arm to a later occurrence (cron_tick self-reschedule broken)")
        print("ok  cron re-armed to the next occurrence (durable recurrence)")

        print("\nschedule/cron smoke passed (Phase 5: one-shot schedule + "
              "recurring durable cron over the gap-2.6 scheduler)")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
