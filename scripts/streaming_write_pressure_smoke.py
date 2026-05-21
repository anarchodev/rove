#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.2 §9.4 — `StreamChunks` cap + write-pressure.

Setup:
  • 3-node cluster, leader-only customer traffic.
  • `acme/big_chunks` heartbeat stream — every 100ms timer wake
    returns ~80 fat chunks (~4 KB each = ~320 KB) plus a status
    `event: pressure\\ndata: dropped=<N>\\n\\n` frame echoing
    `request.activation.write_pressure.dropped_chunks` from the
    PREVIOUS activation. The 320 KB payload exceeds
    `StreamChunks.QUEUE_BYTES_CAP` (256 KB), so each activation
    drops ~14 chunks; the next activation's pressure frame
    surfaces the count.

Gate: the smoke holds the stream for ~400ms (initial + ~3 timer
activations), then verifies the body contains at least one
`event: pressure\\ndata: dropped=<N>\\n\\n` frame with N > 0.
This is the §9.4 contract — that a handler returning more chunks
than fit gets a visible per-stream drop count, not silent loss.
"""

from __future__ import annotations

import re
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
        tag="streaming-write-pressure-smoke",
        http_base=8360,
        raft_base=40460,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.addrs.http_port(c.leader_idx)
        print(f"ok  leader=node{c.leader_idx} ({c.addrs.http[c.leader_idx]})")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL acme not reachable on leader")
        print("ok  acme reachable on leader")

        # Hold the SSE stream long enough for several activations.
        # Each activation queues ~80 chunks of ~4 KB; the queue
        # drains 1 chunk per worker tick. Bigger window gives the
        # timer multiple chances to fire after the prior queue
        # drained — the cumulative cap-overflow shows up on each
        # subsequent activation.
        url = f"{leader_origin}/big_chunks"
        args = cc.args() + [
            "-N",
            "--max-time", "3.0",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        try:
            stdout, _ = watcher.communicate(timeout=8.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        if watcher.returncode not in (0, 28):
            sys.exit(f"FAIL watcher curl exit={watcher.returncode}")

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            sys.exit(f"FAIL no header block in watcher response: {raw!r}")
        body = raw[split + 4:].decode(errors="replace")

        # Find every `event: pressure\ndata: dropped=<N>\n\n` frame.
        pressure_frames = re.findall(
            r"event: pressure\ndata: dropped=(\d+)\n\n", body
        )
        if not pressure_frames:
            sys.exit(
                f"FAIL no pressure frames received over the 600ms window. "
                f"body len={len(body)}; body head={body[:400]!r}"
            )
        counts = [int(x) for x in pressure_frames]
        print(f"ok  received {len(counts)} pressure frame(s): dropped={counts}")

        # §9.4 contract: at least one activation reports drops > 0.
        # The first frame is always dropped=0 (no prior activation);
        # subsequent ones should reflect cap overflow.
        positive = [n for n in counts if n > 0]
        if not positive:
            sys.exit(
                f"FAIL §9.4 write_pressure never surfaced > 0 drops. "
                f"counts={counts}"
            )
        print(
            f"ok  §9.4 write_pressure surfaced: max dropped_chunks="
            f"{max(positive)} across {len(positive)} activation(s)"
        )

        print(
            "\nstreaming-write-pressure smoke passed (Gap 2.2 §9.4: "
            "StreamChunks cap drops + dropped_chunks surface)"
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
