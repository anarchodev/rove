#!/usr/bin/env python3
"""Gap 2.3 streaming-transport smoke — proves the FetchPool's
libcurl path delivers chunks INCREMENTALLY (CURLOPT_WRITEFUNCTION),
not buffered-then-bursted.

The upstream `wb/drip` is an infinite SSE-style stream: one frame
every ~120 ms, forever, until the client disconnects. The handler
fetches it with a short `timeout_ms` (2 s). With the streaming
transport, ~a dozen `fetch_chunk` activations land before the
timeout fires. With the OLD buffered transport (`Easy.request`),
`curl_easy_perform` would block the full 2 s and return on timeout
with the whole body discarded — ZERO chunks delivered.

So the binary proof is simply: chunks arrived before a timeout
terminal. The assertion floor (>= 3) is far below the ~16 a
streaming transport actually produces and far above the 0 a
buffered one would.

Single-worker scope: one worker per node — the held drip stream,
its timer wakes, and the fetch's chunk events all share it.
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


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="fetch-streaming-smoke",
        http_base=8350,
        raft_base=40450,
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

        # 1. Sanity: the wb tenant is deployed. We probe `wb/` (the
        #    finite echo handler) — NOT `wb/drip`, whose infinite
        #    stream would hang the curl helper. The fetch in step 3
        #    is the real exercise of the drip upstream.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"https://{WB_HOST}:{leader_port}/", method="GET").status == 200:
                break
            time.sleep(0.2)
        print("ok  wb tenant deployed")

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. THE fetch — against the infinite drip, timeout 2 s.
        r = curl(
            cc,
            f"{acme_origin}/fetchchunks?url={drip_url}&timeout_ms=2000",
            method="GET",
        )
        if r.status != 200 or not r.body:
            sys.exit(f"FAIL /fetchchunks status={r.status} body={r.body!r}")
        fetch_id = r.body.strip()
        print(f"ok  http.fetch issued against the drip; id={fetch_id[:16]}…")

        # 4. Wait for the terminal. The fetch times out ~2 s in;
        #    fetch_done lands with ok=false (the upstream never
        #    closed cleanly — libcurl hit `timeout_ms`).
        done = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            rr = curl(cc, f"{acme_origin}/readkey?key=fetch/done", method="GET")
            if rr.status == 200:
                done = json.loads(rr.body)
                break
            time.sleep(0.2)
        if done is None:
            sys.exit("FAIL fetch_done never landed")
        if done.get("ok") is not False:
            sys.exit(f"FAIL drip fetch_done should be ok=false (timeout): {done!r}")
        print(f"ok  fetch_done fired ok=false (upstream timed out, as designed)")

        # 5. THE proof: count the fetch_chunk activations that landed
        #    BEFORE the timeout. Streaming → many; buffered → zero.
        n = 0
        for seq in range(0, 256):
            rr = curl(cc, f"{acme_origin}/readkey?key=fetch/chunk/{seq}", method="GET")
            if rr.status == 404:
                break
            if rr.status != 200:
                sys.exit(f"FAIL reading fetch/chunk/{seq}: status={rr.status}")
            n += 1
        if n < 3:
            sys.exit(
                f"FAIL only {n} chunk(s) arrived before the timeout — the "
                f"transport buffered instead of streaming (expected many)"
            )
        print(
            f"ok  {n} fetch_chunk activations arrived incrementally before the "
            f"2 s timeout — a buffered transport would have delivered 0"
        )

    print()
    print(
        "fetch-streaming smoke passed (Gap 2.3 — Easy.requestStreaming / "
        "CURLOPT_WRITEFUNCTION delivers upstream chunks as they arrive, "
        "not buffered until the connection closes)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
