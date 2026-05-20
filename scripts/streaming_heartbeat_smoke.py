#!/usr/bin/env python3
"""End-to-end smoke for streaming-handlers Phase 2b-ii.

The customer's `acme/heartbeat/index.mjs` returns `__rove_stream({...})`
with one initial `:heartbeat\\n\\n` chunk and `waitFor.timer.intervalMs
= 200`. Phase 2b-ii drives the chunked-DATA + timer-wake state
machine:
  1. First-hop: dispatch returns `.stream`; worker stamps response
     headers + status, registers a `StreamCell` in
     `parked_streams_meta`, moves the entity to `stream_response_in`.
  2. Tick loop: `serviceParkedStreams` pops the queued chunk → frame
     out via `stream_data_in`. With chunks drained + an interval set,
     the next tick after `next_wake_ns` calls `resumeStream` — the
     handler re-runs with `request.activation.kind === "timer"`,
     returns another chunk, the loop iterates.
  3. Client disconnect: `serverStreamClose` routes the entity to
     `response_out`; `cleanupResponses` frees the orphaned cell.

The smoke opens an SSE-shaped request, holds it open for ~700ms (long
enough to receive multiple chunks), then disconnects and asserts the
chunk count + framing.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="streaming-heartbeat-smoke",
        http_base=8330,
        raft_base=40430,
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

        # Wait for acme to be reachable (seed deploy is async).
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

        # Open the streaming endpoint with --max-time, then disconnect.
        # 0.7 s window @ 200 ms cadence ⇒ initial chunk + ~3 timer wakes.
        # `-N` disables curl's output buffering so chunks land on stdout
        # as they arrive. `--max-time` forces curl to exit cleanly after
        # the window; that exit IS the client disconnect that drives the
        # cell-cleanup path on the worker.
        url = f"{acme_origin}/heartbeat"
        args = cc.args() + [
            "-N",
            "--max-time", "0.7",
            "-D", "-",     # response headers to stdout
            "-o", "-",     # body to stdout
            "-X", "GET",
            url,
        ]
        proc = subprocess.run(args, capture_output=True, timeout=10)
        # curl exits 28 on --max-time hit; that's expected here.
        if proc.returncode not in (0, 28):
            sys.exit(f"FAIL curl exit={proc.returncode}: {proc.stderr.decode(errors='replace')}")

        raw = proc.stdout
        # Split headers/body. With --max-time the response may be
        # partial; the header block is always complete since curl
        # received it on stream open.
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            sys.exit(f"FAIL no header block in response: {raw!r}")
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4 :].decode(errors="replace")

        # Header assertions (set on the first hop, sent before chunks).
        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        ct = headers.get("content-type", "")
        if "text/event-stream" not in ct:
            sys.exit(f"FAIL Content-Type missing/wrong: {ct!r}\nheaders={header_block!r}")
        print(f"ok  Content-Type set to text/event-stream")

        # Chunk count assertion. Each `:heartbeat\n\n` is one frame; we
        # expect >= 2 (initial + at least one timer wake) for a 0.7s
        # window @ 200ms cadence with allowance for scheduling jitter.
        count = body.count(":heartbeat\n\n")
        if count < 2:
            sys.exit(
                f"FAIL too few heartbeats received: count={count} body={body!r}"
            )
        print(f"ok  received {count} :heartbeat frames over the 0.7s window")

        # Body shape: nothing but `:heartbeat\n\n` repeated. (If the
        # framing were broken we'd see partial chunks here.)
        if body.replace(":heartbeat\n\n", "") != "":
            sys.exit(f"FAIL body has unexpected content: {body!r}")
        print("ok  body is pure :heartbeat\\n\\n frames (no partial / extra bytes)")

        # Sanity: after the client disconnected, the worker keeps
        # serving — drive any inbound request and verify the worker
        # still routes. (acme/index.mjs has no default export, so
        # `/` returns 404; that's still a complete request/response
        # cycle proving the dispatch loop didn't wedge.)
        r = curl(cc, f"{acme_origin}/", method="GET")
        if r.status not in (200, 404):
            sys.exit(f"FAIL post-disconnect ping status={r.status}")
        print(f"ok  worker still serves after disconnect (cell cleanup ran; ping={r.status})")

        # The §4.4 disconnect activation runs in `cleanupResponses`
        # when h2's `serverStreamClose` routes the entity to
        # `response_out` without our `close_pending` path firing.
        # `fireDisconnectActivation` logs the tenant + correlation
        # at info level on entry — tail every worker's stderr for
        # that line. We loop because the cleanup tick after the
        # disconnect may not have flushed by the time the post-
        # disconnect ping completed.
        needle = "rove-js stream-disconnect: tenant=acme"
        seen = False
        deadline = time.monotonic() + 3.0
        log_dir = c.log_dir
        log_paths = list(log_dir.glob(f"{c.tag}-worker-*.out"))
        while time.monotonic() < deadline and not seen:
            for lp in log_paths:
                try:
                    if needle in lp.read_text(errors="replace"):
                        seen = True
                        break
                except FileNotFoundError:
                    continue
            if not seen:
                time.sleep(0.05)
        if not seen:
            for lp in log_paths:
                try:
                    contents = lp.read_text(errors="replace")
                except FileNotFoundError:
                    continue
                tail = "\n".join(contents.splitlines()[-40:])
                sys.stderr.write(f"--- tail {lp} ---\n{tail}\n")
            sys.exit(
                f"FAIL §4.4 disconnect activation never logged "
                f"({needle!r} not in any worker stderr within 3s)"
            )
        print("ok  §4.4 disconnect activation fired (cleanup hook ran)")

        print()
        print("streaming-handlers Phase 2b-ii heartbeat smoke passed "
              "(chunked DATA frames + timer-wake re-activation + cell cleanup)")
        return 0


if __name__ == "__main__":
    sys.exit(main())
