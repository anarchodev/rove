#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.3 Phase D — http.fetch Pattern A
(per-chunk `on_chunk` activations + a terminal `fetch_done`).

The whole pipeline, end to end:

  client ──GET /fetchchunks?url=<wb/bulk>──▶ acme entry handler
     entry: http.fetch({url, on_chunk, on_done, max_response_chunk_bytes:64})
        → C1 accumulates the PendingFetch, flushes to NodeState.fetch_pending
        → returns the fetch id immediately (200, body = id)
     FetchPool (C2): a pool thread drains fetch_pending, libcurl GETs
        wb/bulk (170-byte body), re-chunks to 64 bytes → 3 chunks,
        hash-routes 3 UpstreamFetchEvent{.chunk} + 1 {.end} to the
        acme-owning worker's fetch_chunk_inbox
     worker tick (D): serviceFetchEvents drains the inbox into the
        fetch_event_pending collection, dispatchFetchEvents fires
        fetchchunk.mjs once per chunk + fetchdone.mjs once

  Each on_chunk activation writes `fetch/chunk/<seq>`; on_done writes
  `fetch/done`. The smoke reads them back via acme's /readkey and
  asserts: 3 chunks in seq order, byte-exact reconstruction of the
  upstream body, headers on seq 0 only, ctx round-trip, and a clean
  `fetch_done` terminal (ok=true, status=200).

Single-worker scope: one worker per node so the fetch's hash-routed
chunk events and the entry request land on the same worker.
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
        tag="fetch-chunk-smoke",
        http_base=8330,
        raft_base=40430,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # One worker per node: the fetch's chunk events hash-route by
        # tenant; with a single worker they land where the entry
        # request ran — no cross-worker timing in scope here.
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        # http.fetch's FetchPool reads the same --dev-webhook-unsafe
        # flag http.send does — flips libcurl's verify_tls off so the
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

        # 1. Sanity: the wb/bulk upstream is reachable + returns the
        #    deterministic body we expect to re-chunk.
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

        # 3. THE fetch. GET /fetchchunks → entry handler issues
        #    http.fetch + returns the fetch id immediately.
        r = curl(cc, f"{acme_origin}/fetchchunks?url={bulk_url}", method="GET")
        if r.status != 200 or not r.body:
            sys.exit(f"FAIL /fetchchunks status={r.status} body={r.body!r}")
        fetch_id = r.body.strip()
        print(f"ok  http.fetch issued; id={fetch_id[:16]}…")

        # 4. Poll for the terminal `fetch/done` marker — its presence
        #    means the whole chain (pool → inbox → dispatch) closed.
        done = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{acme_origin}/readkey?key=fetch/done", method="GET")
            if r.status == 200:
                done = json.loads(r.body)
                break
            time.sleep(0.2)
        if done is None:
            sys.exit("FAIL fetch_done never landed (chain did not complete)")
        if done.get("ok") is not True or done.get("status") != 200:
            sys.exit(f"FAIL fetch_done bad terminal: {done!r}")
        if done.get("fetch_id") != fetch_id:
            sys.exit(
                f"FAIL fetch_done.fetch_id={done.get('fetch_id')!r} != issued id {fetch_id!r}"
            )
        print(f"ok  fetch_done fired: ok={done['ok']} status={done['status']}")

        # 5. Read back every chunk marker. 170 bytes / 64-byte cap =
        #    3 chunks (64, 64, 42).
        chunks = []
        for seq in range(0, 16):
            r = curl(cc, f"{acme_origin}/readkey?key=fetch/chunk/{seq}", method="GET")
            if r.status == 404:
                break
            if r.status != 200:
                sys.exit(f"FAIL reading fetch/chunk/{seq}: status={r.status}")
            chunks.append(json.loads(r.body))

        if len(chunks) != 3:
            sys.exit(f"FAIL expected 3 chunk activations, got {len(chunks)}: {chunks!r}")
        print(f"ok  {len(chunks)} fetch_chunk activations fired")

        # 6. Per-chunk assertions: seq order, byte offsets, ctx, headers.
        for seq, ch in enumerate(chunks):
            if ch["seq"] != seq:
                sys.exit(f"FAIL chunk {seq}: seq field is {ch['seq']}")
            if ch["fetch_id"] != fetch_id:
                sys.exit(f"FAIL chunk {seq}: fetch_id mismatch {ch['fetch_id']!r}")
            if ch["tag"] != "fetchsmoke":
                sys.exit(f"FAIL chunk {seq}: ctx tag did not round-trip ({ch['tag']!r})")
        # byte_offset is cumulative bytes BEFORE the chunk.
        if chunks[0]["byteOffset"] != 0:
            sys.exit(f"FAIL chunk 0 byteOffset={chunks[0]['byteOffset']} (want 0)")
        if chunks[1]["byteOffset"] != chunks[0]["len"]:
            sys.exit("FAIL chunk 1 byteOffset != chunk 0 length")
        if chunks[2]["byteOffset"] != chunks[0]["len"] + chunks[1]["len"]:
            sys.exit("FAIL chunk 2 byteOffset != sum of prior lengths")
        print("ok  chunk seq + byteOffset + ctx round-trip correct")

        # 7. Headers ride seq 0 only (not re-shipped per chunk).
        if not chunks[0]["has_headers"]:
            sys.exit("FAIL chunk 0 missing upstream headers")
        if chunks[1]["has_headers"] or chunks[2]["has_headers"]:
            sys.exit("FAIL upstream headers re-shipped on a non-zero chunk")
        ct = chunks[0]["content_type"] or ""
        if "text/plain" not in ct:
            sys.exit(f"FAIL chunk 0 content-type={ct!r} (want text/plain)")
        print(f"ok  upstream headers on seq 0 only; content-type={ct!r}")

        # 8. Byte-exact reconstruction of the upstream body from the
        #    chunk payloads, in seq order.
        rebuilt = "".join(ch["text"] for ch in chunks)
        if rebuilt != EXPECTED_BODY:
            sys.exit(
                f"FAIL reconstructed body mismatch:\n  got:  {rebuilt!r}\n  want: {EXPECTED_BODY!r}"
            )
        print(f"ok  {len(rebuilt)} bytes reconstructed byte-exact from chunk payloads")

    print()
    print(
        "fetch-chunk smoke passed (Gap 2.3 Phase D: http.fetch Pattern A — "
        "FetchPool libcurl → hash-routed chunk inbox → fetch_event_pending "
        "collection → on_chunk/on_done activations)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
