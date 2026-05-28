#!/usr/bin/env python3
"""Concurrent same-tenant heldsync smoke — regression guard for the
`cont_bound_sched_id` scan fix.

Pre-fix, `worker_dispatch.zig`'s scan over `writeset.ops.items`
looked at the WHOLE batch's writeset. When N concurrent same-tenant
heldsync requests landed in one per-tenant dispatch tick (per the
kv-batched-dispatch design), each request's scan saw N
`_send/owed/{id}` puts and returned `null` ("ambiguous → null"
branch). All N conts then deadlined to 504 because no `_send/owed/`
binding was registered.

Post-fix, the scan is scoped to `writeset.ops.items[ws_pre_len..]`
— ops THIS handler appended after the per-handler savepoint
opened. Each concurrent request sees only its own `_send/owed/{id}`
put → exactly one match → cont binds correctly → resume fires.

Single-worker so all N concurrent requests pile into one batch
(the exact case the scan fix targets). Multi-worker + concurrent
is a separate (kv-conflict) issue tracked independently.
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
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

N_CONCURRENT = 20


def one_request(cc, acme_origin: str, wb_echo: str, i: int) -> tuple[int, str, float]:
    t0 = time.monotonic()
    try:
        r = curl(
            cc,
            f"{acme_origin}/heldsync",
            method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"target": wb_echo, "tag": f"v{i}"}),
            timeout=30.0,
        )
    except Exception as e:
        return (i, f"curl raised: {e}", time.monotonic() - t0)
    elapsed = time.monotonic() - t0
    if r.status != 200:
        return (i, f"status={r.status} body={r.body[:200]!r}", elapsed)
    want = f"heldsync:v{i}:echoed:v{i}"
    if r.body != want:
        return (i, f"body={r.body!r} want={want!r}", elapsed)
    if elapsed >= 15.0:
        return (
            i,
            f"took {elapsed:.1f}s — hit §6.4 deadline (scan-fix regressed)",
            elapsed,
        )
    return (i, "", elapsed)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="heldsync-concurrent-smoke",
        http_base=8380,
        raft_base=40480,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # Single worker per node — pile all N concurrent requests
        # into ONE batch so the cont_bound_sched_id scan would see
        # multiple `_send/owed/` puts pre-fix.
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
        wb_echo = f"https://{WB_HOST}:{leader_port}/echo"

        # 1. Sanity: wb reachable.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(
                cc, f"https://{WB_HOST}:{leader_port}/",
                method="POST",
                headers={"content-type": "application/json"},
                data='{"tag":"sanity"}',
            )
            if r.status == 200 and r.body == "echoed:sanity":
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL wb sanity: {r.status} {r.body!r}")
        print("ok  wb (third party) reachable")

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. Warm-up.
        _, warmup_err, _ = one_request(cc, acme_origin, wb_echo, -1)
        if warmup_err:
            sys.exit(f"FAIL warm-up: {warmup_err}")
        print("ok  warm-up held-sync resumed")

        # 4. THE concurrent burst. N_CONCURRENT requests in parallel
        #    to one single-worker cluster — they pile into the same
        #    per-tenant dispatch batch. Pre-fix: all N stuck at the
        #    §6.4 25s deadline. Post-fix: every cont binds and
        #    resumes correctly.
        t0 = time.monotonic()
        failures: list[tuple[int, str, float]] = []
        elapsed_per: list[float] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=N_CONCURRENT) as pool:
            futures = [
                pool.submit(one_request, cc, acme_origin, wb_echo, i)
                for i in range(N_CONCURRENT)
            ]
            for f in concurrent.futures.as_completed(futures):
                i, err, el = f.result()
                elapsed_per.append(el)
                if err:
                    failures.append((i, err, el))
        wall = time.monotonic() - t0

        if failures:
            for i, err, el in sorted(failures):
                print(f"FAIL request {i} ({el:.2f}s): {err}")
            sys.exit(
                f"{len(failures)}/{N_CONCURRENT} concurrent heldsyncs failed in "
                f"{wall:.1f}s — cont_bound_sched_id scan-fix regressed"
            )
        slowest = max(elapsed_per)
        print(
            f"ok  {N_CONCURRENT}/{N_CONCURRENT} concurrent heldsyncs resumed "
            f"in {wall:.2f}s wall (slowest {slowest:.2f}s)"
        )

    print()
    print(
        "heldsync concurrent smoke passed (cont_bound_sched_id scan now scoped "
        "to this request's writeset contribution, not the whole batch)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
