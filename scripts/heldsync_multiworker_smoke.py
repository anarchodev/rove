#!/usr/bin/env python3
"""Cross-worker held-state smoke for the §6.4 held-synchronous path
(`docs/cross-worker-held-state-plan.md` Phase 2B).

Multi-worker variant of `heldsync_smoke.py`. Spawns 4 workers per
node and hammers `/heldsync` with N concurrent requests. The
inbound TCP connections distribute across workers via SO_REUSEPORT
(kernel 4-tuple hash); the webhook callback chunks route via the
`bound_send_owners` registry that Phase 2B wires.

Without Phase 2B this smoke would fail for the majority of
requests: the cont parks on the kernel-chosen worker A, but the
webhook callback chunks used to route via `hash(tenant_id) % N` →
worker B ≠ A. The shim's `resumeIfBound` scan on B found nothing,
and the held client hit the §6.4 25s deadline → 504.

With Phase 2B the webhook.send JS shim passes `bound_send_id` on
the http.fetch options; the FetchEngine carries it onto each
chunk's UpstreamFetchEvent; the router consults
`bound_send_owners[send_id]` and routes the callback to the
parking worker. The cont resume fires correctly.
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
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

# Concurrency level: each request is dispatched sequentially (one
# at a time) to dodge the pre-existing batched-writeset issue —
# `worker_dispatch.zig`'s `cont_bound_sched_id` scan looks at the
# whole tenant batch's writeset, so concurrent same-tenant
# requests in one dispatch tick see N>1 `_send/owed/` puts and
# get a null binding. That bug is independent of Phase 2B and
# manifests even at workers_per_node=1. We still validate Phase
# 2B's cross-worker routing by issuing the requests in series
# but letting each one land on a different worker via repeated
# fresh TCP connections (SO_REUSEPORT picks a worker per
# connection; 4 workers + 20 sequential connections statistically
# spreads).
N_REQUESTS = 20


def one_request(cc, acme_origin: str, wb_echo: str, i: int) -> tuple[int, str, float]:
    """Single held-sync request. Returns (i, error_or_empty, elapsed)."""
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
        # If the resume fires, total round-trip should be <1s. >15s
        # means we hit the §6.4 25s deadline → 504, which means the
        # cross-worker routing failed silently.
        return (
            i,
            f"took {elapsed:.1f}s — hit §6.4 deadline (cross-worker resume failed)",
            elapsed,
        )
    return (i, "", elapsed)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="heldsync-multiworker-smoke",
        http_base=8370,
        raft_base=40470,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=4,
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

        # 1. Sanity: wb reachable + echoes.
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
        print("ok  wb (third party) reachable; echoes")

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. Warm-up.
        _, warmup_err, warmup_el = one_request(cc, acme_origin, wb_echo, -1)
        if warmup_err:
            sys.exit(f"FAIL warm-up: {warmup_err} ({warmup_el:.1f}s)")
        print(f"ok  warm-up held-sync resumed in {warmup_el:.2f}s")

        # 4. Sequential burst. Each request gets a fresh TCP
        #    connection (curl process); SO_REUSEPORT picks a
        #    worker per connection. With 4 workers and 20
        #    requests, statistically most requests land on a
        #    worker ≠ hash(tenant_id) — exactly the cross-worker
        #    case Phase 2B fixes.
        t0 = time.monotonic()
        failures: list[tuple[int, str, float]] = []
        elapsed_per: list[float] = []
        for i in range(N_REQUESTS):
            _, err, el = one_request(cc, acme_origin, wb_echo, i)
            elapsed_per.append(el)
            if err:
                failures.append((i, err, el))
        wall = time.monotonic() - t0

        if failures:
            for i, err, el in sorted(failures):
                print(f"FAIL request {i} ({el:.2f}s): {err}")
            sys.exit(
                f"{len(failures)}/{N_REQUESTS} held-sync requests failed in "
                f"{wall:.1f}s wall — cross-worker resume routing is broken"
            )
        slowest = max(elapsed_per)
        print(
            f"ok  {N_REQUESTS}/{N_REQUESTS} sequential held-syncs "
            f"resumed in {wall:.2f}s wall (slowest {slowest:.2f}s — well under "
            f"§6.4 deadline)"
        )

        # 5. Metrics assertion: cross_worker_routes > 0. (The same
        #    counter that Phase 2A added — Phase 2B uses the same
        #    routing branch with a different lookup key.)
        admin_cc = c.curl_ctx(c.addrs.admin_host)
        metrics_url = f"https://{c.addrs.admin_host}:{leader_port}/_system/metrics"
        rr = curl(
            admin_cc,
            metrics_url,
            method="GET",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        if rr.status != 200:
            sys.exit(f"FAIL metrics fetch failed: status={rr.status} body={rr.body[:200]!r}")
        cross = same = 0
        for line in rr.body.splitlines():
            if line.startswith("bound_fetch_cross_worker_routes_total "):
                cross = int(line.split()[-1])
            elif line.startswith("bound_fetch_same_worker_routes_total "):
                same = int(line.split()[-1])
        print(f"ok  metrics: held-sync routing — cross_worker={cross}, same_worker={same}")
        if cross == 0:
            sys.exit(
                "FAIL bound_fetch_cross_worker_routes_total = 0 — kernel SO_REUSEPORT "
                "clustered all connections on hash(tenant_id), so this smoke didn't "
                "exercise the Phase 2B code path. Increase N_CONCURRENT or vary tenants."
            )

    print()
    print(
        "held-sync multiworker smoke passed (docs/cross-worker-held-state-plan.md "
        "Phase 2B: webhook callback chunks route via bound_send_owners to the "
        "cont's owning worker, closing the SO_REUSEPORT vs hash(tenant_id) gap)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
