#!/usr/bin/env python3
"""End-to-end smoke for streaming-handlers Phase 2b-i.

The customer's `acme/stream/index.mjs` returns `__rove_stream({...})`
with three SSE-formatted chunks. Phase 2b-i wires the worker to
*recognize* the new return shape, concatenate the chunks into a
single response body, apply the headers, and ship as one DATA frame
(single-activation, no timer wakes, no real chunked write yet —
those land in Phase 2b-ii together with the heartbeat smoke). This
smoke asserts that the JS shape reaches the wire correctly: the
client sees the three chunks (concatenated) in the body and the
declared `Content-Type` on the response.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"

EXPECTED_BODY = (
    "event: tick\ndata: alpha\n\n"
    "event: tick\ndata: bravo\n\n"
    "event: tick\ndata: charlie\n\n"
)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="streaming-smoke",
        http_base=8310,
        raft_base=40410,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # Single worker per node so the request and any state we
        # inspect land on the same worker. (Phase 2b-i has no
        # parked-stream state across ticks, but keeps the smoke
        # behaviour identical to the §6.4 / held-sync smoke for
        # consistency.)
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

        # Poll until acme is reachable (seed deploy is async).
        import time
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, f"{acme_origin}/", method="GET")
            if r.status in (200, 404):
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL acme not reachable: status={r.status}")
        print("ok  acme reachable")

        # GET /stream — the streaming handler returns __rove_stream(...).
        r = curl(cc, f"{acme_origin}/stream", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL /stream status={r.status} body={r.body!r}")
        print(f"ok  /stream returned 200")

        # Body assertion: concatenated chunks. Phase 2b-i ships as one
        # DATA frame; Phase 2b-ii makes it truly chunked. Either way
        # the customer's three chunks must be in the body verbatim.
        if r.body != EXPECTED_BODY:
            sys.exit(
                "FAIL body mismatch:\n"
                f"  expected: {EXPECTED_BODY!r}\n"
                f"  got:      {r.body!r}"
            )
        print(f"ok  body matches concatenated chunks ({len(r.body)} bytes, "
              f"three `event: tick` frames)")

        # Header assertion: Content-Type from stream.headers reached
        # the wire. (curl's response_headers is a dict of
        # lower-cased keys → string values, joined when repeated.)
        ct = r.headers.get("content-type", "")
        if "text/event-stream" not in ct:
            sys.exit(f"FAIL Content-Type missing or wrong: {ct!r}")
        print(f"ok  Content-Type header set to text/event-stream")
        cc_hdr = r.headers.get("cache-control", "")
        if "no-cache" not in cc_hdr:
            sys.exit(f"FAIL Cache-Control missing or wrong: {cc_hdr!r}")
        print(f"ok  Cache-Control header set to no-cache")

        print()
        print("streaming-handlers Phase 2b-i smoke passed "
              "(JS shape end-to-end; chunked-DATA + timer wakes are Phase 2b-ii)")
        return 0


if __name__ == "__main__":
    sys.exit(main())
