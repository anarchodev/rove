#!/usr/bin/env python3
"""End-to-end smoke for `on.timer` connection wakes (handler-surface
Phase 1 Task 3 — the timer slice).

The `ontimer` handler arms `on.timer(ms)` and HOLDS the socket via
`__rove_next` with NO webhook.send — so the only thing that can resume
the parked continuation is the timer wake. One blocking client POST:

  client ──POST /ontimer {ms,tag}──▶ acme inbound hop
     on.timer(ms) + return __rove_next(...onWake)
        → StreamWakes armed (interval=ms) on the held continuation
        → entity parks in worker.parked_continuations (held; no response)
     ~ms later: sweepParkedContinuations sees now >= next_wake_ns →
        resumeContinuation(wake) runs onWake(ctx) → terminal →
        resolveParked flushes to the STILL-OPEN socket
  ◀── 200 "woke:<tag>"  (resumed by the timer, ~ms after the request)

A fast-but-not-instant return proves the path: instant (<~ms) would mean
the cont never held; ~25s would mean the §6.4 deadline fired instead of
the timer. Single worker so the park + the leader's sweep are the same
worker (cross-worker is orthogonal — covered by the heldsync smokes).
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="on-timer-smoke",
        http_base=8490,
        raft_base=40490,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(ACME_HOST)
        acme_origin = f"https://{ACME_HOST}:{leader_port}"

        # Wait for the seed deploy to land.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # THE held request: one blocking POST resumed by the timer wake.
        ms = 250
        t0 = time.monotonic()
        r = curl(
            cc, f"{acme_origin}/ontimer",
            method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"ms": ms, "tag": "x"}),
            timeout=30.0,  # > 25s §6.4 deadline so a deadline-504 still returns
        )
        elapsed = time.monotonic() - t0

        if r.status != 200:
            sys.exit(f"FAIL on.timer status={r.status} body={r.body!r} ({elapsed:.2f}s)")
        if r.body != "woke:x":
            sys.exit(f"FAIL on.timer body={r.body!r} (want 'woke:x') ({elapsed:.2f}s)")
        # Fast-but-not-instant: it held for ~the timer, then resumed.
        if elapsed < (ms / 1000.0) * 0.5:
            sys.exit(
                f"FAIL on.timer returned in {elapsed:.3f}s — too fast; the "
                "continuation didn't hold for the timer (instant resolve?)"
            )
        if elapsed >= 15.0:
            sys.exit(
                f"FAIL on.timer returned correct body but in {elapsed:.1f}s — "
                "that's the §6.4 deadline-504 path, not the timer wake"
            )
        print(
            f"ok  on.timer wake resumed: one POST → '{r.body}' in "
            f"{elapsed:.3f}s (timer ~{ms}ms, not instant, not deadline)"
        )

        # Second request, different tag + interval — proves the path
        # isn't a one-off and onWake sees the right ctx each time.
        t0 = time.monotonic()
        r2 = curl(
            cc, f"{acme_origin}/ontimer",
            method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"ms": 120, "tag": "y"}),
            timeout=30.0,
        )
        el2 = time.monotonic() - t0
        if r2.status != 200 or r2.body != "woke:y":
            sys.exit(f"FAIL on.timer (2nd) status={r2.status} body={r2.body!r} ({el2:.2f}s)")
        if el2 < 0.05 or el2 >= 15.0:
            sys.exit(f"FAIL on.timer (2nd) timing {el2:.3f}s out of range")
        print(f"ok  second on.timer wake resumed: '{r2.body}' in {el2:.3f}s")

    print("\nPASS on.timer smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
