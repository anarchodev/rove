#!/usr/bin/env python3
"""Chunk-spool Phase 3 multi-bind smoke — `docs/chunk-spool-plan.md`.

The case the `8bd53bb` safety-net commit guarded and the spool fixes:
TWO bound fetches on a single held entity, each consumed
writes-per-chunk (`__rove_next()` + kv write → a raft round-trip per
chunk). Their chunks interleave on the one entity; each fetch has its
own per-fetch spool. With the producer flooding both fetches' chunks
near-simultaneously and the consumer draining at raft rate, both
spools back up — the exact "same-tick chunks for different fetches on
one entity" race that used to risk a `PendingMove` panic.

Asserts:
  - The request completes 200 (no panic, no stuck held chain).
  - BOTH upstream bodies are reconstructed byte-exact (no drops,
    per-fetch ordering preserved despite cross-fetch interleave).

Runs with the default spool depth (K=4); the writes-per-chunk
back-pressure still overflows it, so eviction + coord read-back also
get exercised under multi-bind. Single worker per node so both
fetches' held entity + spools live on one worker.
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

N1 = 120
N2 = 80
SPLIT = "@@MULTIBIND-SPLIT@@"
EXPECTED_1 = "".join(f"bigbody-line-{i:05d}\n" for i in range(N1))
EXPECTED_2 = "".join(f"bigbody-line-{i:05d}\n" for i in range(N2))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="bound-fetch-spool-smoke",
        http_base=8358,
        raft_base=40458,
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
        u1 = f"https://{WB_HOST}:{leader_port}/bigbody?n={N1}"
        u2 = f"https://{WB_HOST}:{leader_port}/bigbody?n={N2}"

        # 1. Upstreams reachable + deterministic.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r1 = curl(cc, u1, method="GET")
            r2 = curl(cc, u2, method="GET")
            if r1.status == 200 and r1.body == EXPECTED_1 and r2.status == 200 and r2.body == EXPECTED_2:
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit("FAIL wb/bigbody sanity (u1/u2)")
        print(f"ok  upstreams reachable; bodies {len(EXPECTED_1)}B + {len(EXPECTED_2)}B")

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. THE multi-bind fetch. Two bound fetches on one held entity,
        #    both consumed writes-per-chunk. Their chunks interleave;
        #    each per-fetch spool must preserve order + drop nothing.
        r = curl(
            cc,
            f"{acme_origin}/multibind?u1={u1}&u2={u2}",
            method="GET",
            timeout=60.0,
        )
        if r.status != 200:
            sys.exit(f"FAIL /multibind status={r.status} body={r.body[:200]!r}")

        if SPLIT not in r.body:
            sys.exit(f"FAIL response missing split marker; len={len(r.body)}")
        got1, got2 = r.body.split(SPLIT, 1)
        if got1 != EXPECTED_1:
            sys.exit(
                f"FAIL fetch-1 body mismatch: got {len(got1)}B want {len(EXPECTED_1)}B"
            )
        if got2 != EXPECTED_2:
            sys.exit(
                f"FAIL fetch-2 body mismatch: got {len(got2)}B want {len(EXPECTED_2)}B"
            )
        print(
            f"ok  both bound fetches reconstructed byte-exact + in order "
            f"({len(got1)}B + {len(got2)}B, interleaved on one entity, no drops/panic)"
        )

        # 4. Confirm eviction + coord read-back fired under multi-bind.
        admin_cc = c.curl_ctx(c.addrs.admin_host)
        metrics_url = f"https://{c.addrs.admin_host}:{leader_port}/_system/metrics"
        rr = curl(
            admin_cc, metrics_url, method="GET",
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        readback = None
        for line in rr.body.splitlines() if rr.status == 200 else []:
            if line.startswith("bound_fetch_spool_readback_total "):
                readback = int(line.split()[-1])
        if readback is not None:
            print(f"ok  metrics: spool read-back={readback} chunks from coordinator")

    print()
    print(
        "bound-fetch multi-bind spool smoke passed (docs/chunk-spool-plan.md "
        "Phase 3: same-tick chunks for different bound fetches on one entity "
        "spool per-fetch, preserve order, drop nothing — no PendingMove panic)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
