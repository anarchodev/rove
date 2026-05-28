#!/usr/bin/env python3
"""Cross-worker held-state smoke (`docs/cross-worker-held-state-plan.md`).

Multi-worker variant of `bound_fetch_smoke.py`. Spawns 4 workers per
node and hammers `/boundproxy` with N concurrent requests. The
inbound TCP connections distribute across workers via SO_REUSEPORT
(kernel 4-tuple hash — independent of tenant_id); the upstream
fetch chunks route via the `bound_fetch_owners` registry now that
Phase 2A is wired.

Without Phase 2A this smoke would fail for the majority of
requests: the held entity lives on the kernel-chosen worker A, but
the chunk events used to route via `hash(tenant_id) % N` → worker
B ≠ A. With Phase 2A, chunks consult `bound_fetch_owners[fetch_id]`
and route to A directly.

The proof: every concurrent request gets all 3 chunks delivered and
the upstream body reconstructed byte-exact. A cross-worker failure
would surface as a curl timeout (~25s §6.4 deadline → 504 with no
body chunks).
"""

from __future__ import annotations

import concurrent.futures
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))

# Number of concurrent requests. 4 workers × 4 source-ports each is
# the statistical floor for hitting every worker; 20 is comfortably
# above that. Larger N makes the spread tighter but doesn't change
# correctness.
N_CONCURRENT = 20


def one_request(cc, acme_origin: str, bulk_url: str, i: int) -> tuple[int, str]:
    """Single bound-fetch request. Returns (i, error_msg_or_empty)."""
    try:
        r = curl(cc, f"{acme_origin}/boundproxy?url={bulk_url}", method="GET", timeout=30.0)
    except Exception as e:
        return (i, f"curl raised: {e}")
    if r.status != 200:
        return (i, f"status={r.status} body={r.body[:200]!r}")
    parts = r.body.split("chunk:")
    if parts and parts[0] == "":
        parts = parts[1:]
    if len(parts) < 3:
        return (
            i,
            f"got {len(parts)} chunk frame(s) (expected 3); body={r.body[:200]!r}",
        )
    rebuilt = "".join(parts)
    if rebuilt != EXPECTED_BODY:
        return (i, f"body mismatch: got {len(rebuilt)} bytes, want {len(EXPECTED_BODY)}")
    return (i, "")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="bound-fetch-multiworker-smoke",
        http_base=8360,
        raft_base=40460,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # 4 workers per node — gives SO_REUSEPORT genuine room to
        # spread connections across workers. Single-tenant traffic
        # against this config exercises the cross-worker routing
        # path on every request where kernel-pick ≠ hash(tenant_id).
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
        bulk_url = f"https://{WB_HOST}:{leader_port}/bulk"

        # 1. Sanity: upstream reachable.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, bulk_url, method="GET")
            if r.status == 200 and r.body == EXPECTED_BODY:
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL wb/bulk sanity: status={r.status} body={r.body!r}")
        print(f"ok  wb/bulk upstream reachable; {len(EXPECTED_BODY)}-byte body")

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. Warm-up: a single bound fetch (single-threaded) to
        #    confirm the basic path works in this multi-worker
        #    config before hammering with concurrent requests.
        warmup_i, warmup_err = one_request(cc, acme_origin, bulk_url, -1)
        if warmup_err:
            sys.exit(f"FAIL warm-up request: {warmup_err}")
        print("ok  warm-up bound fetch streamed correctly")

        # 4. THE concurrent test. N_CONCURRENT requests in parallel.
        #    Each opens its own TCP connection (curl spawns a fresh
        #    process per call). With 4 workers and 20 connections,
        #    SO_REUSEPORT spreads them across workers — many requests
        #    land on workers ≠ hash(tenant_id), exercising the
        #    cross-worker bound_fetch_owners routing.
        t0 = time.monotonic()
        failures: list[tuple[int, str]] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=N_CONCURRENT) as pool:
            futures = [
                pool.submit(one_request, cc, acme_origin, bulk_url, i)
                for i in range(N_CONCURRENT)
            ]
            for f in concurrent.futures.as_completed(futures):
                i, err = f.result()
                if err:
                    failures.append((i, err))
        elapsed = time.monotonic() - t0

        if failures:
            for i, err in sorted(failures):
                print(f"FAIL request {i}: {err}")
            sys.exit(
                f"{len(failures)}/{N_CONCURRENT} bound-fetch requests failed in {elapsed:.1f}s — "
                f"cross-worker held-state routing is broken (would manifest as "
                f"§6.4 deadlines if Phase 2A's bound_fetch_owners path was missing)"
            )
        print(
            f"ok  {N_CONCURRENT}/{N_CONCURRENT} concurrent bound fetches "
            f"completed in {elapsed:.1f}s with byte-exact body reconstruction"
        )

        # 5. Sanity assertion via the metrics endpoint: at least one
        #    bound fetch chunk MUST have routed cross-worker for this
        #    smoke to be meaningful. If kernel SO_REUSEPORT happened
        #    to cluster all connections on hash(tenant_id) % N, the
        #    fix path never fired and the smoke proved nothing.
        #    Aggregate the counter across all nodes — the leader's
        #    one is the only one that matters here (only leader
        #    accepts), but summing is harmless and future-proof.
        # Hit the leader's metrics endpoint with the root token.
        # Followers return 503 (metrics is leader-only); the
        # FetchEngine lives on the leader so its NodeState owns the
        # counters anyway.
        total_cross = 0
        total_same = 0
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
        for line in rr.body.splitlines():
            if line.startswith("bound_fetch_cross_worker_routes_total "):
                total_cross += int(line.split()[-1])
            elif line.startswith("bound_fetch_same_worker_routes_total "):
                total_same += int(line.split()[-1])
        print(
            f"ok  metrics: bound_fetch routing — cross_worker={total_cross}, "
            f"same_worker={total_same}"
        )
        if total_cross == 0:
            sys.exit(
                "FAIL bound_fetch_cross_worker_routes_total = 0 — kernel SO_REUSEPORT "
                "clustered all connections on hash(tenant_id), so this smoke didn't "
                "exercise the Phase 2A code path. Increase N_CONCURRENT or add tenant "
                "variety to spread the kernel-pick."
            )

    print()
    print(
        "bound-fetch multiworker smoke passed (docs/cross-worker-held-state-plan.md "
        "Phase 2A: chunks route to the held-state owner via bound_fetch_owners "
        "instead of hash(tenant_id), closing the SO_REUSEPORT vs hash(tenant_id) gap)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
