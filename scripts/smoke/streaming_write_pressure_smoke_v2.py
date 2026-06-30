#!/usr/bin/env python3
"""V2 port of `streaming_write_pressure_smoke.py` — Gap 2.2 §9.4
`StreamChunks` cap + write-pressure surfacing, on the `V2Cluster` harness.

The `acme/big_chunks` heartbeat stream writes ~80 fat chunks (~4 KB each =
~320 KB) per activation — over `StreamChunks.QUEUE_BYTES_CAP` (256 KB) — so
each activation drops chunks; the NEXT activation emits an
`event: pressure\\ndata: dropped=<N>\\n\\n` frame echoing
`request.activation.write_pressure.dropped_chunks` from the prior run. The
smoke holds the stream for several timer activations and asserts at least one
pressure frame reports N > 0 — the §9.4 contract that a handler returning
more chunks than fit gets a visible per-stream drop count, not silent loss.

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader election /
discover_leader, seed_manifest (V2 provisions + deploys explicitly). The
handler JS is reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/big_chunks/index.mjs`).

CRITICAL (V2 streaming addressing): the held SSE GET goes DIRECT to the node
(the front buffers a response before relaying it, so an open-ended SSE stream
yields 0 bytes within the read window).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


READY_SRC = 'export function handler() { return "ready"; }\n'


def _stream(c: V2Cluster, path: str, max_time: float) -> "subprocess.Popen":
    """Open a held SSE GET DIRECT to the node, streaming the body to a PIPE."""
    url = f"{c.node_url()}{path}"
    args = [
        "curl", "-sS", "--http2-prior-knowledge", "-N",
        "-H", f"Host: {c.host_for('acme')}",
        "--max-time", str(max_time),
        "-D", "-", "-o", "-", "-X", "GET",
        url,
    ]
    return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("strm-wp", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy big_chunks (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "big_chunks/index.mjs": _src("acme/big_chunks/index.mjs"),
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load (GET / → 'ready')")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: hold the big_chunks stream for several activations")
        # ~100 ms timer wakes; hold ~3 s so the initial + multiple timer
        # activations each flood the cap and the next surfaces a drop count.
        watcher = _stream(c, "/big_chunks", max_time=3.0)
        try:
            stdout, _ = watcher.communicate(timeout=8.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        if watcher.returncode not in (0, 28):
            check("watcher curl clean exit (0/28)", False,
                  f"exit={watcher.returncode}")

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            check("watcher response had a header block", False, f"{raw!r}")
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        body = raw[split + 4:].decode(errors="replace")

        # §9.4: find every `event: pressure\ndata: dropped=<N>\n\n` frame.
        pressure_frames = re.findall(
            r"event: pressure\ndata: dropped=(\d+)\n\n", body)
        check("≥1 pressure frame received", bool(pressure_frames),
              f"body len={len(body)}; head={body[:300]!r}")
        if not pressure_frames:
            c.dump_node_log(grep=["pressure", "stream", "chunk", "drop",
                                  "cap", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        counts = [int(x) for x in pressure_frames]
        print(f"  ok  received {len(counts)} pressure frame(s): dropped={counts}")

        # The first frame is always dropped=0 (no prior activation); a later
        # one must reflect cap overflow.
        positive = [n for n in counts if n > 0]
        check("§9.4 write_pressure surfaced > 0 drops",
              bool(positive),
              f"counts={counts}")
        if positive:
            print(f"  ok  max dropped_chunks={max(positive)} across "
                  f"{len(positive)} activation(s)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming-write-pressure smoke (v2): Gap 2.2 §9.4 "
          "StreamChunks cap drops + dropped_chunks surface on the wire")
    return 0


if __name__ == "__main__":
    sys.exit(main())
