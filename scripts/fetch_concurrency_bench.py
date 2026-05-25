#!/usr/bin/env python3
"""curl-multi-plan Phase 0 baseline: N=100 concurrent http.fetch
fan-out against a co-located echo. Measures per-fetch round-trip
(submit → terminal `final:true` event lands in kv) + wall time +
effective concurrency.

Today's FetchPool throttles completion to FETCH_POOL_SIZE=8
workers; the bench captures this baseline so the Phase 2 migration
to `FetchEngine` (curl-multi-plan §6) has a regression bar.

Each fetch:
  client ──GET /benchfetch?url=<wb/bulk>──▶ acme entry handler
     entry: http.fetch({url, on_chunk:"benchfetch_oc", stream:true})
        → returns fetch_id immediately (200)
     FetchPool: thread drains, libcurl GETs wb/bulk (170 B), emits
        chunks → benchfetch_oc writes `bench/done/<id>` on terminal

The bench timestamps each /benchfetch return + each `bench/done/<id>`
appearance, derives per-fetch latency, and reports the percentiles
and a wall-time-derived effective concurrency floor.

Env:
  BENCH_N (default 100)        — fetches to issue
  BENCH_POLL_S (default 0.05)  — kv poll interval
  BENCH_TIMEOUT_S (default 60) — total wall-clock cap
  BENCH_TAG                    — label prefix on METRIC lines
"""

from __future__ import annotations

import concurrent.futures as cf
import os
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

N = int(os.environ.get("BENCH_N", "100"))
POLL_S = float(os.environ.get("BENCH_POLL_S", "0.05"))
TIMEOUT_S = float(os.environ.get("BENCH_TIMEOUT_S", "60"))
TAG = os.environ.get("BENCH_TAG", "phase0")


def issue_one(cc, acme_origin: str, bulk_url: str) -> tuple[str, float]:
    """Issue one /benchfetch; return (fetch_id, submitted_at_monotonic)."""
    t0 = time.monotonic()
    import urllib.parse as up
    r = curl(cc, f"{acme_origin}/benchfetch?url={up.quote(bulk_url)}", method="GET")
    if r.status != 200 or not r.body:
        raise RuntimeError(f"submit failed: status={r.status} body={r.body!r}")
    return r.body.strip(), t0


def pct(samples: list[float], p: float) -> float:
    if not samples:
        return float("nan")
    s = sorted(samples)
    k = (len(s) - 1) * p
    f, c = int(k), int(k) + 1
    if c >= len(s):
        return s[-1]
    return s[f] + (s[c] - s[f]) * (k - f)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="fetch-concurrency-bench",
        http_base=8340,
        raft_base=40440,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,  # match fetch_chunk_smoke
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

        # Sanity: warm both endpoints + assert wb echoes.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, bulk_url, method="GET").status == 200:
                break
            time.sleep(0.2)
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)
        print(f"ok  warmup complete; issuing N={N} concurrent fetches")

        # Issue N concurrent /benchfetch calls. Each Python thread has
        # its own curl_ctx implicitly (curl is reentrant per-handle
        # in smoke_lib's Easy wrapper); we serialize through one cc
        # with a thread pool — the bottleneck the bench measures is
        # SERVER-SIDE FetchPool throttling, not client-side curl.
        wall_start = time.monotonic()
        # ThreadPoolExecutor with workers >> FETCH_POOL_SIZE so all
        # submits land before any completions matter.
        submit_results: dict[str, float] = {}  # fetch_id → submit_t
        submit_errors: list[str] = []
        with cf.ThreadPoolExecutor(max_workers=min(N, 64)) as ex:
            futures = [ex.submit(issue_one, cc, acme_origin, bulk_url) for _ in range(N)]
            for fut in cf.as_completed(futures, timeout=TIMEOUT_S):
                try:
                    fid, t0 = fut.result()
                    submit_results[fid] = t0
                except Exception as e:
                    submit_errors.append(str(e))
        submit_wall = time.monotonic() - wall_start
        if submit_errors:
            print(f"WARN {len(submit_errors)} submit failures; first: {submit_errors[0]}")
        ids = list(submit_results.keys())
        if len(set(ids)) != len(ids):
            print(f"WARN duplicate fetch_ids! {len(ids)} submitted, {len(set(ids))} unique")
        print(
            f"ok  submitted {len(ids)}/{N} fetches in {submit_wall*1000:.1f}ms "
            f"(submit p95={pct([t-wall_start for t in submit_results.values()],0.95)*1000:.1f}ms)"
        )

        # Poll bench/done/<id> for each fetch in parallel. Use the
        # same thread pool — server has spare h2 capacity since
        # FetchPool is busy not h2 dispatch.
        complete_t: dict[str, float] = {}
        remaining = set(ids)
        deadline = wall_start + TIMEOUT_S
        last_progress = time.monotonic()
        while remaining and time.monotonic() < deadline:
            # Sample a few at a time to amortize per-tick overhead.
            batch = list(remaining)[:32]
            with cf.ThreadPoolExecutor(max_workers=min(len(batch), 16)) as ex:
                futs = {
                    ex.submit(
                        curl, cc, f"{acme_origin}/readkey?key=bench/done/{fid}",
                        method="GET",
                    ): fid
                    for fid in batch
                }
                for fut in cf.as_completed(futs):
                    fid = futs[fut]
                    try:
                        r = fut.result()
                    except Exception:
                        continue
                    if r.status == 200:
                        complete_t[fid] = time.monotonic()
                        remaining.discard(fid)
            if complete_t and complete_t.get(batch[-1]) is not None:
                last_progress = time.monotonic()
            if remaining:
                if time.monotonic() - last_progress > 10.0:
                    print(f"WARN no progress for 10s; {len(remaining)}/{N} still pending")
                    last_progress = time.monotonic()
                time.sleep(POLL_S)
        wall_total = time.monotonic() - wall_start

        if remaining:
            print(f"FAIL {len(remaining)}/{N} fetches did not complete in {TIMEOUT_S}s")

        # Per-fetch latency = completion_t − submit_t. The
        # submit_t was captured inside the worker thread BEFORE
        # /benchfetch's response landed, so the latency includes
        # dispatch + fetch + raft-commit of the done marker.
        latencies = [
            (complete_t[fid] - submit_results[fid]) * 1000.0
            for fid in complete_t
        ]
        if not latencies:
            print("FAIL no completions; nothing to measure")
            return 1
        latencies.sort()
        mean = statistics.mean(latencies)
        p50 = pct(latencies, 0.50)
        p95 = pct(latencies, 0.95)
        p99 = pct(latencies, 0.99)
        mn, mx = latencies[0], latencies[-1]
        # Implied effective concurrency: if every fetch took mean
        # latency and N fetches finished in wall_total, then the
        # average number of in-flight fetches was N*mean/wall_total.
        # With FetchPool=8 this should saturate near 8.
        effective_conc = (len(latencies) * mean / 1000.0) / wall_total

        print()
        print(f"METRIC tag={TAG} N={N} completed={len(latencies)}")
        print(f"METRIC tag={TAG} wall_total_ms={wall_total*1000:.1f}")
        print(f"METRIC tag={TAG} submit_wall_ms={submit_wall*1000:.1f}")
        print(f"METRIC tag={TAG} per_fetch_min_ms={mn:.1f}")
        print(f"METRIC tag={TAG} per_fetch_mean_ms={mean:.1f}")
        print(f"METRIC tag={TAG} per_fetch_p50_ms={p50:.1f}")
        print(f"METRIC tag={TAG} per_fetch_p95_ms={p95:.1f}")
        print(f"METRIC tag={TAG} per_fetch_p99_ms={p99:.1f}")
        print(f"METRIC tag={TAG} per_fetch_max_ms={mx:.1f}")
        print(f"METRIC tag={TAG} effective_concurrency={effective_conc:.2f}")
        print()
        print(f"fetch-concurrency bench complete (tag={TAG})")
        return 0 if not remaining else 2


if __name__ == "__main__":
    sys.exit(main())
