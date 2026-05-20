#!/usr/bin/env python3
"""End-to-end smoke for streaming-handlers Phase 4d — stream-first-hop
writes kv.

The "open a session" pattern: a customer's SSE endpoint wants to
register the connection in kv as part of the initial hop (so other
endpoints can see who's online) AND stream live events. Pre-Phase-4d
this would have been rejected with a defined 500 by the
`ws_pre_len` guard. Post-Phase-4d:

  1. The first-hop writeset gets proposed through raft via the
     existing write-batch path.
  2. `streamRecordIfAnyAt` parks the `StreamFirstHopMeta` on
     `worker.pending_stream_meta` keyed by entity.
  3. `drainRaftPending`'s entity loop sees the entry on commit,
     calls `registerStreamCell` + moves the entity into
     `stream_response_in` (not the usual `response_in`).
  4. `serviceParkedStreams` drives the chain as normal — drains
     the initial chunk + timer wakes + disconnect cleanup.

Gates:
  1. Stream returns 200 with the `event: hello` frame carrying the
     session id passed in the query string.
  2. `GET /readkey?key=sessions/<id>` returns "online" while the
     stream is held — proves the first-hop write committed.
  3. After disconnect, the disconnect handler's `kv.set` flips
     the value to "offline" (Phase 4c path, exercised here too).
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
        tag="streaming-first-hop-writes-smoke",
        http_base=8370,
        raft_base=40470,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx}")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL acme not reachable: status={r.status}")
        print("ok  acme reachable")

        # Sanity: session key shouldn't exist yet.
        r = curl(cc, f"{leader_origin}/readkey?key=sessions/alice")
        if r.status != 404:
            sys.exit(
                f"FAIL preflight: sessions/alice already set "
                f"(status={r.status} body={r.body!r})"
            )
        print("ok  session key absent before stream open")

        # Open the stream — first-hop will kv.set("sessions/alice",
        # "online") AND return __rove_stream. Pre-Phase-4d this
        # would have been rejected with 500 by the ws_pre_len guard;
        # post-Phase-4d the writeset proposes through raft and the
        # entity moves to stream_response_in on commit.
        url = f"{leader_origin}/sessions_sse?id=alice"
        args = cc.args() + [
            "-N",
            "--max-time", "1.5",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Give the first-hop write time to propose + commit through
        # raft.
        time.sleep(0.5)

        # While the stream is still held, the session key should be
        # "online" — proves the first-hop write made it through raft
        # and committed.
        r = curl(cc, f"{leader_origin}/readkey?key=sessions/alice")
        if r.status != 200 or r.body != "online":
            watcher.kill()
            sys.exit(
                f"FAIL Phase 4d gate: sessions/alice expected 'online' while "
                f"stream held, got status={r.status} body={r.body!r}"
            )
        print("ok  first-hop write committed while stream is held: 'online'")

        # Drain the watcher to capture the frames.
        try:
            stdout, _ = watcher.communicate(timeout=3.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        if watcher.returncode not in (0, 28):
            sys.exit(f"FAIL watcher curl exit={watcher.returncode}")

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            sys.exit(f"FAIL no header block in response: {raw!r}")
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4 :].decode(errors="replace")

        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        if "text/event-stream" not in headers.get("content-type", ""):
            sys.exit(
                f"FAIL Content-Type missing/wrong: {headers.get('content-type')!r}"
            )
        print("ok  Content-Type set to text/event-stream")

        if "event: hello\ndata: alice\n\n" not in body:
            sys.exit(f"FAIL hello frame missing: body={body!r}")
        print("ok  hello frame carrying session id received")

        # The disconnect handler (Phase 4c) flips the value to
        # "offline". Allow time for the disconnect activation to
        # fire + the kv write to commit.
        deadline = time.monotonic() + 5.0
        got = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/readkey?key=sessions/alice")
            if r.status == 200 and r.body == "offline":
                got = r.body
                break
            time.sleep(0.05)
        if got != "offline":
            sys.exit(
                f"FAIL sessions/alice expected 'offline' after disconnect, "
                f"got status={r.status} body={r.body!r}"
            )
        print(
            "ok  disconnect handler wrote 'offline' (Phase 4c cleanup, "
            "combined with the Phase 4d open)"
        )

        print()
        print(
            "streaming-handlers Phase 4d first-hop-writes smoke passed "
            "(stream-first-hop writes propose + commit; entity routes to "
            "stream_response_in on commit)"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
