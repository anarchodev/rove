#!/usr/bin/env python3
"""End-to-end smoke for the `stream.*` effect surface (handler-surface
Phase 2 slice 2b/2c).

The `streamkv` handler is the NEW-surface twin of `watch`: it produces
its SSE response with `stream.start()` / `stream.write()` effects, waits
with `on.kv("streamkv/in/")`, and holds the socket with `__rove_next` —
no `__rove_stream({write, waitFor})`. The dispatcher's `finishResponse`
bridges `(next() + stream_started)` to the same internal Stream
descriptor the old surface produced, so the h2 stream pipeline drives it
unchanged.

  client ──GET /streamkv (held, --no-buffer)──▶ acme inbound hop
     response.headers = {content-type: text/event-stream}
     stream.start() + stream.write("ready") + on.kv("streamkv/in/")
        + return __rove_next(...)
     → finishResponse bridge → RunOutcome.stream → stream pipeline
     → first frame ships; entity parks in stream_data_out, kv-armed

  client ──POST /writekv {key: streamkv/in/<id>, value}──▶ 204
     → broadcastKvWake → serviceParkedStreams (kv-due) → resumeStream
     → handler re-dispatched (wake_batch): stream.write(frame) + on.kv
        + __rove_next → finishResponse bridge → .stream re-park
     → update frame ships on the held socket

Gates:
  1. Content-Type text/event-stream set from the ambient response.* head
     (proves the bridge stamps the ambient head, not a descriptor head).
  2. The initial `ready` frame ships from `stream.write()` on the first
     (inbound) hop.
  3. Update frames carry the kv-wake payload (proves on.* re-arm +
     stream.write on resume, through the bridge, both directions).

Single-node (the park + the leader's broadcast + the sweep + resume are
all the same worker); cross-node kv-wake fan-out is covered by
streaming_kv_wake_smoke.py.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="stream-effect-smoke",
        http_base=8496,
        raft_base=40496,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
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

        # Wait for the seed deploy.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # Hold the streaming GET in the background; --no-buffer streams
        # chunks to stdout as they arrive, --max-time caps the window.
        args = cc.args() + [
            "-N",
            "--max-time", "3.0",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            f"{acme_origin}/streamkv",
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Let the inbound hop park + arm the kv prefix.
        time.sleep(0.3)

        # Three writes under the watched prefix — each fires a kv wake.
        for i, value in enumerate(["alpha", "bravo", "charlie"], start=1):
            r = curl(
                cc, f"{acme_origin}/writekv",
                method="POST",
                data=json.dumps({"key": f"streamkv/in/{i}", "value": value}),
                headers={"Content-Type": "application/json"},
            )
            if r.status != 204:
                watcher.kill()
                sys.exit(f"FAIL writekv id={i} status={r.status} body={r.body!r}")
            time.sleep(0.20)
        print("ok  three writes posted")

        try:
            stdout, stderr = watcher.communicate(timeout=4.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, stderr = watcher.communicate()
        if watcher.returncode not in (0, 28):
            sys.exit(f"FAIL watcher curl exit={watcher.returncode}")

        raw = stdout or b""
        if os.environ.get("DEBUG"):
            print(f"DEBUG raw={raw!r}")
            print(f"DEBUG stderr={(stderr or b'')[-600:]!r}")
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            sys.exit(f"FAIL no header block in watcher response: {raw!r}")
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4 :].decode(errors="replace")

        # 1. Ambient head: Content-Type came from response.headers.
        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        if "text/event-stream" not in headers.get("content-type", ""):
            sys.exit(f"FAIL Content-Type missing/wrong: {headers.get('content-type')!r}")
        print("ok  ambient head: Content-Type text/event-stream")

        # 2. First frame from stream.write() on the inbound hop.
        if "event: ready\ndata: 1\n\n" not in body:
            sys.exit(f"FAIL initial ready frame missing: body={body!r}")
        print("ok  initial stream.write() frame received")

        # 3. Update frames from on.* re-arm + stream.write() on resume.
        expected = [
            "event: update\ndata: streamkv/in/1=alpha\n\n",
            "event: update\ndata: streamkv/in/2=bravo\n\n",
            "event: update\ndata: streamkv/in/3=charlie\n\n",
        ]
        seen = sum(1 for f in expected if f in body)
        if seen < 2:
            sys.exit(
                f"FAIL kv-wake update frames: expected >= 2 of 3, got {seen}. "
                f"body={body!r}"
            )
        print(f"ok  received {seen}/3 stream.* + on.kv update frames")

    print("\nPASS stream.* effect smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
