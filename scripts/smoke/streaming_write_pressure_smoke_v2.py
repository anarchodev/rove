#!/usr/bin/env python3
"""`stream.write` is LOSSLESS — the two halves of that contract, on the wire.

`StreamChunks` (src/js/components.zig) has two caps and they mean opposite
things, which is exactly what an earlier version of this smoke got wrong:

  - SOFT cap (256 KB) is BACK-PRESSURE. A burst past it is absorbed and
    delivered in FULL; the producer is throttled, never clipped. This smoke
    streams ~317 KB per activation and asserts every byte arrives.
  - HARD cap (4 MB in ONE activation) THROWS. The runtime never silently
    drops, so an activation handed more than it can buffer fails loudly
    rather than shipping a short stream. `?overrun=1` drives that and
    asserts the throw is what the client sees.

There is no `write_pressure.dropped_chunks` surface: nothing drops, so
there is no drop count to report (src/js/globals_request.zig says so at the
site where it used to be populated). This smoke asserted that retired
surface for months and reported the ABSENCE of drops as a failure.

CRITICAL (V2 streaming addressing): the held SSE GET goes DIRECT to the node
(the front buffers a response before relaying it, so an open-ended SSE stream
yields 0 bytes within the read window).

The handler JS lives in `examples/loop46-demo-tenants/acme/big_chunks/`.

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
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")

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

        print("step 4: SOFT cap — hold the stream; ~317 KB/activation must arrive INTACT")
        # ~100 ms timer wakes; hold ~3 s so the initial + several timer
        # activations each push past the soft cap.
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

        seq_frames = re.findall(r"event: burst\ndata: start\n\n", body)
        check("≥2 activations streamed (initial + timer wake)", len(seq_frames) >= 2,
              f"markers={len(seq_frames)} body len={len(body)}")
        if not seq_frames:
            c.dump_node_log(grep=["stream", "chunk", "cap", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        # Lossless means the byte count matches the frames sent: each
        # activation is one seq frame + 80 fat chunks, and nothing in between
        # may be missing. Count fat chunks and compare to activations.
        fat = body.count("data: " + "X" * 3950)
        expected = 80 * len(seq_frames)
        # The LAST activation may be cut mid-flight when curl's --max-time
        # fires, so allow the tail to be short — but every EARLIER one must be
        # whole, which is what truncation would break.
        floor = 80 * (len(seq_frames) - 1)
        check("⭐ soft-cap burst delivered losslessly (no silent truncation)",
              fat >= floor,
              f"{fat} fat chunks for {len(seq_frames)} activation(s); "
              f"want ≥{floor} (all but the interrupted tail), full={expected}")

        print("step 5: ⭐ HARD cap — one activation past 4 MB must THROW, not truncate")
        over = c.get("acme", "/big_chunks?overrun=1", timeout=20.0)
        body_over = over.body if isinstance(over.body, str) else over.body.decode(errors="replace")
        check("hard-cap overrun surfaces the throw (never a short 200 stream)",
              "too many bytes buffered" in body_over,
              f"got {over.status} {body_over[:200]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming-write-pressure smoke (v2): the soft cap back-pressures "
          "losslessly and the hard cap throws — stream.write never truncates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
