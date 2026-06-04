#!/usr/bin/env python3
"""End-to-end smoke for `docs/streaming-model.md` §7 item 1 +
`docs/handler-shape.md` §5.5 — `http.fetch({bind: true})`.

What it proves:

  client ──GET /boundproxy?url=<wb/bulk>──▶ acme entry handler
     entry: http.fetch({url, bind:true, on_chunk:'boundproxy', ...})
       → registers fetch_id → entity in worker.bound_fetch_entities
       → returns __rove_next('boundproxy', {ctx}) — chain parks in
         parked_continuations, held client stays open
     FetchPool: drains, libcurl-GETs wb/bulk, builds an
       UpstreamFetchEvent with bind=true
     worker tick: dispatchPendingMsgs `.fetch_chunk` arm sees
       ev.bind, looks up the held entity, calls
       resumeBoundFetchChain — dispatches /boundproxy?fn=onFetchChunk
     handler: onFetchChunk returns JSON encoding fetchId/chunkSeq/
       done/body → terminal Response on the held socket.

The smoke asserts the held client receives the JSON, with
`done: true` (single-chunk fetch) and the upstream body bytes
visible in `body`. The whole flow rides one HTTP/2 connection.

V1 scope: stream=false on the fetch so one chunk delivers (final).
Multi-chunk stream({write}) per upstream chunk is the follow-up
(needs the stream-chain wake-on-fetch path).
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

EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="bound-fetch-smoke",
        http_base=8350,
        raft_base=40450,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # Single worker keeps this smoke focused on the bind mechanics
        # itself. The cross-worker case (chunks routed to the worker that
        # holds the entity via the `bound_fetch_owners` registry) is
        # covered + asserted by `bound_fetch_multiworker_smoke.py`
        # (workers_per_node=4); see docs/cross-worker-held-state-plan.md.
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
        bulk_url = f"https://{WB_HOST}:{leader_port}/bulk"

        # 1. Sanity: upstream reachable + deterministic body.
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

        # 3. THE bound fetch. The held socket should receive a
        #    streaming response: onFetchChunk fires per upstream
        #    chunk, each returning __rove_stream with a
        #    "chunk:<text>" frame. The terminal chunk (done=true)
        #    returns "" to close. With max_response_chunk_bytes=64
        #    on a 170-byte upstream body, libcurl re-chunks into
        #    3 events (64 + 64 + 42 bytes) + 1 terminal final event;
        #    the held client sees 3 "chunk:" frames before close.
        #
        #    This exercises BOTH bound-fetch paths:
        #      - First chunk: entity in parked_continuations →
        #        resumeBoundFetchChain → cont→stream transition.
        #      - Subsequent chunks: entity in stream_data_out →
        #        resumeBoundFetchStream (Gap #1 lift).
        r = curl(cc, f"{acme_origin}/boundproxy?url={bulk_url}", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL /boundproxy status={r.status} body={r.body!r}")

        body = r.body
        # Each frame starts with "chunk:". Split on that marker.
        # The first part is empty (body starts with "chunk:"); drop it.
        parts = body.split("chunk:")
        if parts and parts[0] == "":
            parts = parts[1:]
        if len(parts) < 3:
            sys.exit(
                f"FAIL expected >= 3 chunk frames, got {len(parts)}.\n"
                f"  body ({len(body)} bytes): {body!r}"
            )

        # Reconstruct the upstream body by concatenating frame
        # payloads in order.
        rebuilt = "".join(parts)
        if rebuilt != EXPECTED_BODY:
            sys.exit(
                f"FAIL reconstructed body mismatch:\n"
                f"  got ({len(rebuilt)} bytes):  {rebuilt!r}\n"
                f"  want ({len(EXPECTED_BODY)} bytes): {EXPECTED_BODY!r}"
            )
        print(
            f"ok  bound fetch streamed {len(parts)} chunks via onFetchChunk → __rove_stream "
            f"({len(rebuilt)} bytes reconstructed byte-exact)"
        )

    print()
    print(
        "bound-fetch smoke passed (docs/streaming-model.md §7 item 1: "
        "http.fetch({bind:true}) wakes the calling chain's onFetchChunk "
        "named export instead of firing a separate fetch-<id> chain)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
