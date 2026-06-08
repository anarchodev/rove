#!/usr/bin/env python3
"""V2 port of `streaming_kv_wake_smoke.py` — streaming-handlers kv-write
wake, on the `V2Cluster` harness.

The `/watch` handler arms `on.kv("watch/")` + emits a `snapshot` frame on
the inbound hop, then one `update` frame per kv entry in each wake batch,
re-arming `on.kv("watch/")` on every `next()` so it keeps streaming. The
smoke holds an SSE GET on `/watch` (via the front door) while a SECOND
client POSTs three writes under `watch/` (DIRECT to the node — see below).

Essential assertions kept from V1:
  1. Content-Type is text/event-stream.
  2. Initial `snapshot` frame fires on the inbound hop.
  3. The three writes arrive as `update` frames carrying key=value (op)
     — proving the wake_batch activation reads `request.activation.wakes`
     and the cell re-registers its prefix on every `next()`.

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader/follower
addressing + the follower apply-thread fan-out log assertion (single
node here; cross-node fan-out is covered by the three_node smokes), the
disconnect-log assertion (worker-stderr scrape — orthogonal to the
kv-wake primitive under test).

CRITICAL (V2 streaming addressing): both the held SSE GET and the trigger
writes go DIRECT to the node, NOT the front door. The front buffers a
response before relaying it, so an open-ended SSE stream yields 0 bytes
within the read window; and the front multiplexes a tenant onto one
upstream h2 connection, so a trigger sent through it would queue behind
the held stream (head-of-line). Two independent curl processes hitting
the node are separate h2 connections, so the watcher and the trigger
don't collide.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# Handler JS verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/{watch,writekey}/index.mjs).
WATCH_SRC = """\
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: snapshot\\ndata: initial\\n\\n");
    on.kv("watch/");
    return next();
}

export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        const value = kv.get(w.key) ?? "(deleted)";
        stream.write(`event: update\\ndata: ${w.key}=${value} (${w.op})\\n\\n`);
    }
    on.kv("watch/");
    return next();
}
"""

WRITEKEY_SRC = """\
export default function () {
    const body = JSON.parse(request.body || "{}");
    const id = body.id ?? "x";
    const value = body.value ?? "";
    kv.set("watch/" + id, value);
    response.status = 204;
    return "";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def _stream_watch(c: V2Cluster, path: str, max_time: float) -> "subprocess.Popen":
    """Open a held SSE GET DIRECT to the node (the front buffers, so an
    open-ended SSE stream would yield 0 bytes), streaming the body to a
    PIPE so we can read frames as they arrive. Mirrors the V1 watcher: raw
    curl with -N (no buffering), --max-time (read window), -D - (headers)."""
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

    with V2Cluster.spawn("stream-kvwake", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy watch + writekey (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "watch/index.mjs": WATCH_SRC,
                "writekey/index.mjs": WRITEKEY_SRC,
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

        print("step 4: hold SSE GET /watch, POST three writes ~0.2s apart")
        watcher = _stream_watch(c, "/watch", max_time=4.0)
        # Give the inbound hop time to arm on.kv("watch/") before writing.
        time.sleep(0.5)

        for i, value in enumerate(["alpha", "bravo", "charlie"], start=1):
            body = json.dumps({"id": str(i), "value": value})
            # DIRECT to the node — a write through the front would queue
            # behind the held SSE stream (head-of-line).
            # DIRECT to the node (separate h2 connection from the watcher).
            w = c.node_request("/writekey", method="POST",
                               host=c.host_for("acme"),
                               headers={"Content-Type": "application/json"},
                               data=body)
            if w.status != 204:
                watcher.kill()
                check(f"writekey id={i} → 204", False, f"got {w.status} {w.body!r}")
                print(f"\nFAILURES ({len(failures)}): {failures}")
                return 1
            time.sleep(0.20)
        check("three writes posted (204)", True)

        # Drain the watcher.
        try:
            stdout, _ = watcher.communicate(timeout=6.0)
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
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4:].decode(errors="replace")

        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        check("Content-Type is text/event-stream",
              "text/event-stream" in headers.get("content-type", ""),
              f"got {headers.get('content-type')!r}")

        check("initial snapshot frame received",
              "event: snapshot\ndata: initial\n\n" in body,
              f"body={body!r}")

        expected_updates = [
            "event: update\ndata: watch/1=alpha (put)\n\n",
            "event: update\ndata: watch/2=bravo (put)\n\n",
            "event: update\ndata: watch/3=charlie (put)\n\n",
        ]
        seen = sum(1 for f in expected_updates if f in body)
        check("≥2 of 3 kv-wake update frames", seen >= 2,
              f"got {seen}/3; body={body!r}")
        if seen == 3:
            print("  ok  all three writes delivered (strong kv-wake sequence)")
        if seen < 2:
            c.dump_node_log(grep=["deploy", "loader", "stream", "wake",
                                  "kv", "resolve", "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming kv-wake smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
