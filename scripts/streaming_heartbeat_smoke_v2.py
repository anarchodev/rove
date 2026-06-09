#!/usr/bin/env python3
"""V2 port of `streaming_heartbeat_smoke.py` — multi-frame timer-wake
exerciser (handler-surface Phase 2 `stream.*`) on the `V2Cluster` harness.

The `acme/heartbeat` handler opens an SSE stream with one `:heartbeat\\n\\n`
frame and arms `on.timer(200)`; every 200ms `onWake` emits another
`:heartbeat\\n\\n`. The smoke opens the SSE request, holds it open ~0.7s
(long enough for multiple chunks), disconnects (curl `--max-time`), and
asserts the chunk count + framing + that the §4.4 disconnect activation
fired (cleanup hook ran).

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader election /
discover_leader, seed_manifest (V2 provisions + deploys explicitly). The
handler JS is reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/heartbeat/index.mjs`).

The held SSE request goes DIRECT to the node, NOT the front door: the V2
front door buffers the full backend response (single `RespBody` relay,
src/front/main.zig) — it does not relay chunked DATA frames — so a
never-terminating SSE stream through it never flushes a chunk before the
client gives up. The node's h2 server streams `stream_data_in` DATA frames
straight to the held client, which is the lifecycle under test. The
disconnect (curl exits on --max-time) drives the worker's cell-cleanup
path; we then assert the §4.4 disconnect activation logged on the node.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("hb", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy heartbeat handler (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "heartbeat/index.mjs": _src("acme/heartbeat/index.mjs"),
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

        print("step 4: open /heartbeat (held ~0.7s @ 200ms cadence), then disconnect")
        # The held SSE request goes DIRECT to the node (the front door buffers
        # the whole response, never relaying chunked DATA frames). `-N`
        # disables curl output buffering; `--max-time 0.7` forces a clean exit
        # after the window — that exit IS the client disconnect that drives the
        # worker's cell-cleanup path.
        url = f"{c.node_url(0)}/heartbeat"
        args = ["curl", "-sS", "--http2-prior-knowledge", "-N",
                "--max-time", "0.7", "-H", f"Host: {c.host_for('acme')}",
                "-D", "-", "-o", "-", "-X", "GET", url]
        proc = subprocess.run(args, capture_output=True, timeout=10)
        # curl exits 28 on --max-time hit; expected here.
        if proc.returncode not in (0, 28):
            check("held SSE curl exit 0/28", False,
                  f"exit={proc.returncode}: {proc.stderr.decode(errors='replace')}")
            c.dump_node_log(grep=["deploy", "loader", "stream", "heartbeat",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        raw = proc.stdout
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            check("response has a header block", False, f"raw={raw!r}")
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4:].decode(errors="replace")

        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        ct = headers.get("content-type", "")
        check("Content-Type == text/event-stream", "text/event-stream" in ct,
              f"got {ct!r}\nheaders={header_block!r}")

        # Chunk count: each `:heartbeat\n\n` is one frame; expect >= 2
        # (initial + at least one timer wake) over a 0.7s @ 200ms window.
        count = body.count(":heartbeat\n\n")
        check("received >= 2 :heartbeat frames", count >= 2,
              f"count={count} body={body!r}")

        # Body shape: nothing but `:heartbeat\n\n` repeated (broken framing
        # would leave partial chunks).
        check("body is pure :heartbeat frames (no partial/extra bytes)",
              body.replace(":heartbeat\n\n", "") == "", f"body={body!r}")
        if count >= 2:
            print(f"  ok   {count} heartbeat frames over the ~0.7s window")

        print("step 5: worker still serves after disconnect")
        r = c.get("acme", "/?fn=handler")
        check("post-disconnect ping serves", r.status == 200 and "ready" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 6: §4.4 disconnect activation fired (cleanup hook logged)")
        # fireDisconnectActivation logs `rove-js stream-disconnect: tenant=acme`
        # at info on entry. Tail the node log; loop because the cleanup tick
        # may not have flushed by the time the ping returned.
        needle = "rove-js stream-disconnect: tenant=acme"
        log = c.log_paths.get("n1")
        seen = False
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline and not seen:
            if log and os.path.exists(log):
                with open(log, errors="replace") as f:
                    if needle in f.read():
                        seen = True
                        break
            time.sleep(0.05)
        check("§4.4 disconnect activation logged", seen,
              "" if seen else f"{needle!r} not in node log within 4s")
        if not seen:
            c.dump_node_log(grep=["stream", "disconnect", "cleanup", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming heartbeat smoke (v2): chunked DATA frames + "
          "timer-wake re-activation + §4.4 disconnect cleanup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
