#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.3 Phase E — http.fetch Pattern B
(`pipe_to: "held_response"`): a transparent upstream→client proxy.

  client ──GET /pipe?url=<wb/bulk>──▶ acme entry handler
     inbound: http.fetch({url, pipe_to:"held_response"})
              + return __rove_stream({waitFor:{fetch_pipe_done}})
        → the held response parks; PipeState.awaiting_pipe = true
     FetchPool (C2): pool thread libcurl-GETs wb/bulk (170-byte
        body), re-chunks, hash-routes UpstreamFetchEvent{.chunk}×N
        + {.pipe_done} to the acme worker's fetch_chunk_inbox
     worker tick (E): dispatchFetchEvents routes the pipe events —
        each .chunk → StreamChunks.tryAppend on the held entity
        (NO handler activation, NO tape), the .pipe_done → PipeState
     serviceParkedStreams ships the queued chunks to the client as
        DATA frames, then fires the single fetch_pipe_done activation
  ◀── 200 text/plain, body = the upstream's 170 bytes byte-for-byte

The handler is re-entered exactly once (fetch_pipe_done); it records
the terminal accounting to kv. The smoke asserts: the client got
the upstream body byte-exact, and fetch_pipe_done fired with
ok=true, status=200, bytes_piped=170, dropped_chunks=0.

Single-worker scope: one worker per node so the fetch's hash-routed
pipe events and the held stream land on the same worker.
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

# Mirror of examples/loop46-demo-tenants/wb/bulk/index.mjs — 10 lines
# of "bulk-line-NN-zzz\n" (17 bytes each = 170 bytes total).
EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="pipe-smoke",
        http_base=8340,
        raft_base=40440,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # One worker per node: the fetch's pipe events hash-route by
        # tenant; with a single worker they land on the worker that
        # holds the parked held stream.
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        # http.fetch's FetchPool reads the same --dev-webhook-unsafe
        # flag http.send does — drops libcurl verify_tls so the
        # on-box wb upstream's self-signed cert is accepted.
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        acme_origin = f"https://{ACME_HOST}:{leader_port}"
        bulk_url = f"https://{WB_HOST}:{leader_port}/bulk"

        # 1. Sanity: the wb/bulk upstream returns the body we expect
        #    the pipe to relay verbatim.
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

        # 2. acme reachable (seed deploy is async).
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. THE pipe. One GET; the response streams the upstream
        #    bytes through the held client. The whole proxy chain
        #    (fetch-pool → pipe inbox → StreamChunks → h2) must
        #    complete and END_STREAM before curl returns.
        t0 = time.monotonic()
        r = curl(cc, f"{acme_origin}/pipe?url={bulk_url}", method="GET", timeout=30.0)
        elapsed = time.monotonic() - t0
        if r.status != 200:
            sys.exit(f"FAIL /pipe status={r.status} body={r.body!r} ({elapsed:.1f}s)")
        if r.body != EXPECTED_BODY:
            sys.exit(
                f"FAIL piped body mismatch ({elapsed:.1f}s):\n"
                f"  got:  {r.body!r}\n  want: {EXPECTED_BODY!r}"
            )
        print(
            f"ok  pipe relayed {len(r.body)} upstream bytes to the client "
            f"byte-for-byte in {elapsed:.2f}s"
        )

        # 4. The held stream was re-entered once for fetch_pipe_done;
        #    it recorded the terminal accounting to kv.
        done = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            rr = curl(cc, f"{acme_origin}/readkey?key=pipe/done", method="GET")
            if rr.status == 200:
                done = json.loads(rr.body)
                break
            time.sleep(0.2)
        if done is None:
            sys.exit("FAIL fetch_pipe_done never fired (pipe terminal missing)")
        if done.get("ok") is not True or done.get("status") != 200:
            sys.exit(f"FAIL fetch_pipe_done bad terminal: {done!r}")
        if done.get("bytes_piped") != len(EXPECTED_BODY):
            sys.exit(
                f"FAIL bytes_piped={done.get('bytes_piped')} (want {len(EXPECTED_BODY)})"
            )
        if done.get("dropped_chunks") != 0:
            sys.exit(f"FAIL dropped_chunks={done.get('dropped_chunks')} (want 0)")
        print(
            f"ok  fetch_pipe_done fired once: ok={done['ok']} status={done['status']} "
            f"bytes_piped={done['bytes_piped']} dropped_chunks={done['dropped_chunks']}"
        )

    print()
    print(
        "pipe smoke passed (Gap 2.3 Phase E: http.fetch Pattern B — "
        "upstream bytes piped through the held client bypassing the "
        "handler (untaped), one fetch_pipe_done terminal)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
