#!/usr/bin/env python3
"""Chunk-spool Phase 3 large-body smoke — `docs/chunk-spool-plan.md`.

What it proves: a bound fetch (`http.fetch({bind:true})`) whose
upstream delivers a body far larger than the spool's K-deep RAM
window is processed **byte-exact and in order**, while the spool's
inline RAM stays bounded at ~K chunks. Most chunks have their inline
bytes evicted on arrival and are read back from the blob coordinator
(`coord.readBody`) when the held chain finally consumes them.

Setup:
  - `ROVE_BOUND_FETCH_SPOOL_DEPTH=2` shrinks the window so even a
    modest body overflows it (forcing eviction + read-back).
  - `wb/bigbody?n=200` → a deterministic 3800-byte body (200 × 19-byte
    lines). libcurl delivers it ~at once; at the caller's 64-byte
    `max_response_chunk_bytes` that's ~60 chunks emitted near-
    simultaneously into the spool.
  - The held chain is `spoolsink`, which consumes each chunk with a kv
    read-modify-write + `__rove_next()` — the "writes-per-chunk"
    pattern. Each chunk forces a full raft round-trip (unlike a
    `__rove_stream` chain, which pipelines without moving the held
    entity), so consumption runs at raft rate while ~60 chunks land in
    the spool at once → it backs up well past K=2 and eviction fires.

Assertions:
  1. The held client reconstructs the upstream body byte-exact from
     the streamed `chunk:` frames (proves evicted bytes were read
     back correctly + in order).
  2. `bound_fetch_spool_readback_total > 0` (proves the eviction →
     coordinator read-back path actually executed — not just that the
     consumer kept up).
  3. `bound_fetch_spool_inline_bytes_peak` stays bounded (≤ a few
     chunks, and a small fraction of the body) — the K-window held.

Single worker per node so the worker-local spool metrics are
deterministic + the held entity and the metrics scrape land on the
same worker.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Shrink the spool RAM window BEFORE spawning workers (inherited via
# os.environ). K=2 → a 63-chunk body overflows by ~61 chunks.
os.environ["ROVE_BOUND_FETCH_SPOOL_DEPTH"] = "2"
SPOOL_DEPTH = 2

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

N_LINES = 200
CHUNK_BYTES = 64  # boundproxy's max_response_chunk_bytes
EXPECTED_BODY = "".join(f"bigbody-line-{i:05d}\n" for i in range(N_LINES))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="bound-fetch-large-body-smoke",
        http_base=8356,
        raft_base=40456,
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
        big_url = f"https://{WB_HOST}:{leader_port}/bigbody?n={N_LINES}"

        # 1. Upstream reachable + deterministic.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, big_url, method="GET")
            if r.status == 200 and r.body == EXPECTED_BODY:
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(
                f"FAIL wb/bigbody sanity: status={r.status} len={len(r.body)} "
                f"(want {len(EXPECTED_BODY)})"
            )
        n_chunks = (len(EXPECTED_BODY) + CHUNK_BYTES - 1) // CHUNK_BYTES
        print(
            f"ok  wb/bigbody upstream reachable; {len(EXPECTED_BODY)}-byte body "
            f"(~{n_chunks} chunks at {CHUNK_BYTES}B, K={SPOOL_DEPTH})"
        )

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. THE bound fetch against the large body. spoolsink consumes
        #    each chunk with a kv read-modify-write + next() (raft round
        #    trip per chunk), so ~60 chunks pile into the spool while the
        #    consumer drains at raft rate → eviction + coord read-back.
        #    The terminal chunk returns the reconstructed body.
        r = curl(cc, f"{acme_origin}/spoolsink?url={big_url}", method="GET", timeout=60.0)
        if r.status != 200:
            sys.exit(f"FAIL /spoolsink status={r.status} body={r.body[:200]!r}")

        rebuilt = r.body
        if rebuilt != EXPECTED_BODY:
            div = next(
                (i for i in range(min(len(rebuilt), len(EXPECTED_BODY))) if rebuilt[i] != EXPECTED_BODY[i]),
                "len",
            )
            sys.exit(
                f"FAIL reconstructed body mismatch:\n"
                f"  got  {len(rebuilt)} bytes\n"
                f"  want {len(EXPECTED_BODY)} bytes\n"
                f"  first divergence at {div}"
            )
        print(
            f"ok  large body consumed writes-per-chunk, "
            f"{len(rebuilt)} bytes reconstructed byte-exact + in order"
        )

        # 4. Metrics: prove the eviction → coord read-back path ran and
        #    the inline RAM window held.
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
        readback = None
        peak = None
        for line in rr.body.splitlines():
            if line.startswith("bound_fetch_spool_readback_total "):
                readback = int(line.split()[-1])
            elif line.startswith("bound_fetch_spool_inline_bytes_peak "):
                peak = int(line.split()[-1])
        if readback is None or peak is None:
            sys.exit("FAIL spool metrics missing from /_system/metrics")

        if readback == 0:
            sys.exit(
                "FAIL bound_fetch_spool_readback_total = 0 — the consumer kept up "
                "with the producer so the K-window never overflowed; this smoke didn't "
                "exercise eviction + coord read-back. Lower K or enlarge the body."
            )
        # Window held: peak inline must be a small multiple of the chunk
        # size (K in-window chunks + slack), and a tiny fraction of the
        # whole body — the whole point of the spool.
        peak_cap = (SPOOL_DEPTH + 2) * CHUNK_BYTES
        if peak > peak_cap:
            sys.exit(
                f"FAIL inline RAM peak {peak} > cap {peak_cap} "
                f"(K={SPOOL_DEPTH}, chunk={CHUNK_BYTES}) — eviction not bounding RAM"
            )
        if peak >= len(EXPECTED_BODY):
            sys.exit(
                f"FAIL inline RAM peak {peak} ≥ body {len(EXPECTED_BODY)} — "
                "no decoupling, the whole body was held inline"
            )
        print(
            f"ok  metrics: spool read-back={readback} chunks from coordinator, "
            f"inline RAM peak={peak}B (≤ {peak_cap}B cap, body={len(EXPECTED_BODY)}B)"
        )

    print()
    print(
        "bound-fetch large-body smoke passed (docs/chunk-spool-plan.md Phase 3: "
        "chunks beyond the K-deep RAM window evict their inline bytes + read back "
        "from the blob coordinator; peak inline RAM stays ~K chunks regardless of "
        "body size)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
