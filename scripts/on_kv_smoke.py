#!/usr/bin/env python3
"""End-to-end smoke for `on.kv` connection wakes (handler-surface
Phase 1 Task 3 — the kv half, sibling of `on_timer_smoke.py`).

The `onkv` handler reads `<prefix>flag` (baselining the §8.4
read_version AFTER the read), arms `on.kv(prefix)`, and HOLDS the socket
via `__rove_next` with NO webhook.send — so the ONLY thing that can
resume the parked continuation is a kv write under the watched prefix
landing at a write_version strictly greater than the baseline.

  client A ──POST /onkv {prefix}──▶ acme inbound hop          (HELD)
     kv.get(prefix+flag) + on.kv(prefix) + return __rove_next(...onWake)
        → StreamWakes{read_version, kv_prefixes} on the held continuation
        → entity parks in worker.parked_continuations (no response yet)

  ...~0.5s later...

  client B ──POST /writekv {key:prefix+flag,value}──▶ 204     (the trigger)
     leader commit arm → broadcastKvWake(write_version)
        → matchEventsToWakes: write_version > read_version → pending_wakes
        → sweepParkedContinuations (kv-due) → resumeContinuation(wake)
        → onWake re-reads kv → terminal → resolveParked

  client A ◀── 200 "woke:<value>"   (resumed by the kv write, ~0.5s)

Timing proves the path: the held POST must return SHORTLY AFTER the
write (not instantly — that would mean it never held; not at ~25s —
that's the §6.4 deadline, meaning the wake never fired). Single worker
so the park + the leader's commit-arm broadcast + the sweep are all the
same worker (cross-worker wake routing is orthogonal — heldsync smokes
cover it).
"""

from __future__ import annotations

import concurrent.futures
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"

PREFIX = "onkv/"
WRITE_DELAY_S = 0.5


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="on-kv-smoke",
        http_base=8494,
        raft_base=40494,
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

        # THE held request: one blocking POST resumed by a kv write that a
        # SECOND request makes ~WRITE_DELAY_S later. Run the held POST on a
        # background thread so the main thread can fire the trigger write.
        def held() -> tuple[int, str, float]:
            t0 = time.monotonic()
            r = curl(
                cc, f"{acme_origin}/onkv",
                method="POST",
                headers={"content-type": "application/json"},
                data=json.dumps({"prefix": PREFIX}),
                timeout=30.0,  # > 25s §6.4 deadline so a deadline-504 still returns
            )
            return r.status, r.body, time.monotonic() - t0

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(held)
            # Let the inbound hop park the continuation before we write.
            time.sleep(WRITE_DELAY_S)
            w = curl(
                cc, f"{acme_origin}/writekv",
                method="POST",
                headers={"content-type": "application/json"},
                data=json.dumps({"key": PREFIX + "flag", "value": "hello"}),
                timeout=10.0,
            )
            if w.status != 204:
                sys.exit(f"FAIL trigger writekv status={w.status} body={w.body!r}")
            print(f"ok  trigger write landed: {PREFIX}flag=hello (204)")

            status, body, elapsed = fut.result(timeout=35.0)

        if status != 200:
            sys.exit(f"FAIL on.kv status={status} body={body!r} ({elapsed:.2f}s)")
        if body != "woke:hello":
            sys.exit(f"FAIL on.kv body={body!r} (want 'woke:hello') ({elapsed:.2f}s)")
        # Held until the write, then resumed: not instant (it would have
        # had to ignore the hold), not the deadline (the wake never fired).
        if elapsed < WRITE_DELAY_S * 0.5:
            sys.exit(
                f"FAIL on.kv returned in {elapsed:.3f}s — too fast; the "
                "continuation didn't hold for the kv write (instant resolve?)"
            )
        if elapsed >= 15.0:
            sys.exit(
                f"FAIL on.kv returned correct body but in {elapsed:.1f}s — "
                "that's the §6.4 deadline-504 path, not the kv wake"
            )
        print(
            f"ok  on.kv wake resumed: held POST → '{body}' in {elapsed:.3f}s "
            f"(woke ~{WRITE_DELAY_S}s after the write, not instant, not deadline)"
        )

    print("\nPASS on.kv smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
