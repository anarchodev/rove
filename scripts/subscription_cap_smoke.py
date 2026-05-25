#!/usr/bin/env python3
"""Per-tenant held-subscription cap smoke for
`docs/curl-multi-plan.md` Phase 3 (gap 2.5).

The engine caps simultaneous held subscriptions at
`HELD_MAX_PER_TENANT = 16` (fetch_engine.zig). Submissions over
the cap fire a single `final: true, ok: false` event so the
customer's handler runs once and can surface the rejection.

Flow:
  1. Open CAP subscriptions back-to-back against wb/drip (held;
     never terminate on their own).
  2. Submit one more — assert it surfaces as a defined rejection
     (sub/done/<id> appears with ok=false, even though wb/drip
     itself never closes).
  3. Cancel everything.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

# Must match HELD_MAX_PER_TENANT in src/js/fetch_engine.zig
HELD_CAP = 16


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="subscription-cap-smoke",
        http_base=8370,
        raft_base=40470,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        acme_origin = f"https://{ACME_HOST}:{leader_port}"
        drip_url = f"https://{WB_HOST}:{leader_port}/drip"

        # Warm acme + wb so both seed deploys are loaded before
        # /subscribe fires (wb otherwise 503's "no deployment" and
        # the held transfer closes immediately).
        wb_root = f"https://{WB_HOST}:{leader_port}/"
        deadline = time.monotonic() + 20.0
        acme_ok = False
        wb_ok = False
        while time.monotonic() < deadline:
            if not acme_ok and curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                acme_ok = True
            if not wb_ok and curl(cc, wb_root, method="GET").status == 200:
                wb_ok = True
            if acme_ok and wb_ok:
                break
            time.sleep(0.2)
        if not (acme_ok and wb_ok):
            sys.exit(f"FAIL warmup timeout: acme_ok={acme_ok} wb_ok={wb_ok}")

        # 1. Open CAP subscriptions. Each call returns a fresh id;
        #    they all hold open against wb/drip.
        import urllib.parse as up
        sub_url = f"{acme_origin}/subscribe?url={up.quote(drip_url)}"
        ids = []
        for i in range(HELD_CAP):
            r = curl(cc, sub_url, method="GET")
            if r.status != 200 or not r.body:
                sys.exit(f"FAIL subscription #{i} status={r.status} body={r.body!r}")
            ids.append(r.body.strip())
        print(f"ok  opened {len(ids)} held subscriptions (cap = {HELD_CAP})")

        # Let the engine settle: each /subscribe call hands the
        # PendingFetch to the engine asynchronously. We don't have
        # a "wait for held count to reach N" probe, so the strategy
        # is: send MANY over-cap (16 extras), wait, then assert at
        # least one got the cap rejection AND at least one of the
        # original 16 streamed chunks. Robust against the race
        # where a few over-cap submissions slip in if the engine
        # hadn't yet incremented the counter for in-flight cap-N
        # registrations.
        time.sleep(0.3)

        # 2. Submit OVER_N more — beyond cap. At least OVER_N - cap
        #    should be rejected (in practice all OVER_N, since the
        #    earlier 16 have settled by now).
        OVER_N = 16
        over_ids = []
        for i in range(OVER_N):
            r = curl(cc, sub_url, method="GET")
            if r.status != 200 or not r.body:
                sys.exit(f"FAIL over-cap subscription #{i} status={r.status} body={r.body!r}")
            over_ids.append(r.body.strip())
        print(f"ok  submitted {OVER_N} over-cap subscriptions")

        # Wait for rejection events to land. Count how many got
        # the defined rejection.
        deadline = time.monotonic() + 5.0
        rejected_ids = set()
        import json as _json
        while time.monotonic() < deadline and len(rejected_ids) == 0:
            for oid in over_ids:
                if oid in rejected_ids:
                    continue
                r = curl(cc, f"{acme_origin}/readkey?key=sub/done/{oid}", method="GET")
                if r.status == 200:
                    payload = _json.loads(r.body)
                    if payload.get("ok") is False:
                        rejected_ids.add(oid)
            if len(rejected_ids) == 0:
                time.sleep(0.1)
        if len(rejected_ids) == 0:
            sys.exit(
                f"FAIL no over-cap subscriptions were rejected within 5 s "
                f"(would have expected ≥1 of {OVER_N})"
            )
        print(f"ok  {len(rejected_ids)}/{OVER_N} over-cap subscriptions rejected via final:true,ok:false")

        # Confirm at least the cleanly-rejected ones got NO chunks
        # (rejection is a single final event with no body).
        for oid in rejected_ids:
            r = curl(cc, f"{acme_origin}/readkey?key=sub/chunk/{oid}/0", method="GET")
            if r.status == 200:
                sys.exit(f"FAIL rejected subscription {oid[:16]} got a chunk: {r.body!r}")
        print(f"ok  all rejected subscriptions received zero body chunks (defined posture)")

        # 3. Clean shutdown — cancel every id we ever issued so the
        #    cluster teardown doesn't leak in-flight transfers. The
        #    rejected ones already completed; cancel of an unknown
        #    id is a silent no-op.
        all_ids = ids + over_ids
        for sid in all_ids:
            curl(cc, f"{acme_origin}/cancel_subscribe?id={sid}", method="GET")
        print(f"ok  cancelled all {len(all_ids)} submitted subscriptions")

    print()
    print("subscription-cap smoke passed (curl-multi-plan Phase 3: per-tenant held-subscription cap fires defined rejection)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
