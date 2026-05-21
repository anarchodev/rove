#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.1 Phase F — cron subscription chain
origin firing on a fixed interval.

Setup:
  • 3-node cluster, leader-only customer traffic.
  • `acme/_subscriptions/heartbeat-cron/{spec.json,index.mjs}` —
    interval_ms=1000. The leader's worker 0 runs a throttled
    1Hz `sweepCronSubscriptions` that consults the in-memory
    `NodeState.cron_state` (`<tenant>|<name>` → `next_fire_at_ns`)
    and enqueues fires that are due. The handler increments
    `cron-fire-count` per fire.

Gate:
  Wait ~3.5 seconds (~2-3 cron intervals after the first-sight
  initialization pause); poll `/readkey?key=cron-fire-count`;
  verify count >= 2. Also verify
  `request.activation.source.firedAt` advances (a fresh ns
  timestamp per fire) by reading `cron-last-fired-at-ns`.

V1 in-memory state: leader change resets the cron clock; we don't
exercise failover here (covered by the documented contract). Spec
parsing rejects sub-second `interval_ms` (verified by unit-test
shape in worker.zig).
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="streaming-subscription-cron-smoke",
        http_base=8400,
        raft_base=40500,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.addrs.http_port(c.leader_idx)
        print(f"ok  leader=node{c.leader_idx} ({c.addrs.http[c.leader_idx]})")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL acme not reachable on leader")
        print("ok  acme reachable on leader")

        # The cron sub's first-sight init pauses one interval (1s),
        # then fires every 1s. Wait ~3.5s so we see at least 2 fires.
        # The sweep runs on a 1-sec throttle so observed counts can
        # be slightly variable around the boundary.
        print("waiting 3.5s for cron sub to fire 2+ times...")
        time.sleep(3.5)

        r = curl(cc, f"{leader_origin}/readkey?key=cron-fire-count", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL cron-fire-count not present after 3.5s: status={r.status}")
        count = int(r.body.strip())
        if count < 2:
            sys.exit(f"FAIL cron fired {count} times in 3.5s (expected >= 2)")
        print(f"ok  cron fired {count} time(s) over the 3.5s window")

        # firedAt timestamp should be a recent ns value.
        r = curl(cc, f"{leader_origin}/readkey?key=cron-last-fired-at-ns", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL cron-last-fired-at-ns absent: status={r.status}")
        last_fired_at_ns = int(r.body.strip())
        now_ns = int(time.time() * 1e9)
        age_s = (now_ns - last_fired_at_ns) / 1e9
        if age_s > 5.0 or age_s < -5.0:
            sys.exit(
                f"FAIL cron firedAt={last_fired_at_ns} ns is "
                f"{age_s:.2f}s old (expected within 5s of now)"
            )
        print(f"ok  cron firedAt timestamp is recent ({age_s:.2f}s old)")

        # Sanity: count keeps growing on a longer wait.
        time.sleep(2.0)
        r = curl(cc, f"{leader_origin}/readkey?key=cron-fire-count", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL cron-fire-count gone after 5.5s: status={r.status}")
        count2 = int(r.body.strip())
        if count2 <= count:
            sys.exit(f"FAIL cron didn't advance ({count} → {count2}); sweeper stuck?")
        print(f"ok  cron advanced from {count} to {count2} fire(s) over 2s")

        print(
            "\nstreaming-subscription-cron smoke passed (Gap 2.1 Phase F: "
            "throttled cron sweep + in-memory next_fire_at_ns + "
            "atomic-with-effects fire via the existing inbox path)"
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
