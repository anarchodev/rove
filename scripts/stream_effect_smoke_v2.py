#!/usr/bin/env python3
"""V2 port of `stream_effect_smoke.py` — the `stream.*` effect surface
(handler-surface Phase 2 slice 2b/2c) on the `V2Cluster` harness (branch
`v2`).

The `streamkv` handler produces its SSE response with `stream.start()` /
`stream.write()` effects, waits with `on.kv("streamkv/in/")`, and holds
the socket with `next()`. The dispatcher's `finishResponse` bridges
`(next() + stream_started)` to the same internal Stream descriptor, so the
h2 stream pipeline drives it.

  client ──GET /streamkv (held, -N)──▶ acme inbound hop
     response.headers = {content-type: text/event-stream}
     stream.start() + stream.write("ready") + on.kv("streamkv/in/") + next()
     → first frame ships; entity parks, kv-armed

  client ──POST /writekv {key: streamkv/in/<id>, value}──▶ 204  (DIRECT to node)
     → broadcastKvWake → resumeStream → onWake re-dispatched:
        stream.write(frame) + on.kv + next() → update frame ships

BOTH the held streaming GET and the trigger writes go DIRECT to the node,
not through the front door. The held GET is direct because the front door
does not pass an open SSE stream through (an held `text/event-stream` GET
via the front returns 0 bytes until the upstream closes — a front-door
streaming-passthrough gap, orthogonal to the `stream.*`/`on.kv` primitive
under test; verified: the SAME request DIRECT to the node streams all
frames live). The trigger writes are direct to dodge front-door
head-of-line behind a held stream. This mirrors the V1 smoke, which hit
the leader port directly (V1 had no front door).

Gates (same as V1):
  1. Content-Type text/event-stream from the ambient response.* head.
  2. The initial `ready` frame ships from `stream.write()` on the first hop.
  3. Update frames carry the kv-wake payload (on.* re-arm + stream.write on
     resume, through the bridge).

Single-node (park + broadcast + sweep + resume all the same worker).
Dropped from V1: TLS/https, leader-direct addressing / discover_leader,
seed_manifest, workers_per_node.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

# Handlers verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/{streamkv,writekv}/index.mjs).
STREAMKV_SRC = r"""export default function () {
    response.status = 200;
    response.headers = {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
    };
    stream.start();
    stream.write("event: ready\ndata: 1\n\n");
    on.kv("streamkv/in/");
    return next();
}

export function onWake() {
    stream.start();
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        const v = kv.get(w.key) ?? "(absent)";
        stream.write("event: update\ndata: " + w.key + "=" + v + "\n\n");
    }
    on.kv("streamkv/in/");
    return next();
}
"""

WRITEKV_SRC = r"""export default function () {
    const body = JSON.parse(request.body || "{}");
    if (!body.key || typeof body.key !== "string") {
        response.status = 400;
        return "missing key";
    }
    kv.set(body.key, body.value ?? "");
    response.status = 204;
    return "";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("stream-effect", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy streamkv + writekv (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "streamkv/index.mjs": STREAMKV_SRC,
                "writekv/index.mjs": WRITEKV_SRC,
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

        print("step 4: hold the streaming GET (direct to node), drive 3 kv writes")
        # The held streaming GET goes DIRECT to the node (the front door does
        # not pass an open SSE stream through — see the module docstring). -N
        # streams chunks as they arrive, --max-time caps the window (the held
        # stream never ends naturally, so curl exits 28 on the cap).
        args = ["curl", "-sS", "--http2-prior-knowledge", "-N",
                "--max-time", "6.0", "-D", "-", "-o", "-", "-X", "GET",
                "-H", f"Host: {c.host_for('acme')}",
                f"{c.node_url(0)}/streamkv"]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Let the inbound hop park + arm the kv prefix.
        time.sleep(0.6)

        # Three writes under the watched prefix — each fires a kv wake. DIRECT
        # to the node (not the front) to dodge head-of-line behind the held
        # stream.
        for i, value in enumerate(["alpha", "bravo", "charlie"], start=1):
            w = c.node_request("/writekv", method="POST", host=c.host_for("acme"),
                               headers={"content-type": "application/json"},
                               data=json.dumps({"key": f"streamkv/in/{i}", "value": value}))
            if w.status != 204:
                check(f"writekv id={i} → 204", False, f"got {w.status} {w.body!r}")
            time.sleep(0.25)
        if not failures:
            print("  ok  three writes posted (direct to node)")

        try:
            stdout, stderr = watcher.communicate(timeout=8.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, stderr = watcher.communicate()
        # 28 == curl --max-time expiry (the held stream never naturally ends).
        if watcher.returncode not in (0, 28):
            check("watcher curl exit ∈ {0,28}", False, f"exit={watcher.returncode}")

        raw = stdout or b""
        if os.environ.get("DEBUG"):
            print(f"DEBUG raw={raw!r}")
            print(f"DEBUG stderr={(stderr or b'')[-600:]!r}")
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            check("watcher produced a header block", False, f"raw={raw!r}")
            c.dump_node_log(grep=["stream", "kv", "wake", "park", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4:].decode(errors="replace")

        # 1. Ambient head: Content-Type came from response.headers.
        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        check("ambient head: Content-Type text/event-stream",
              "text/event-stream" in headers.get("content-type", ""),
              f"content-type={headers.get('content-type')!r}")

        # 2. First frame from stream.write() on the inbound hop.
        check("initial stream.write() 'ready' frame received",
              "event: ready\ndata: 1\n\n" in body, f"body={body!r}")

        # 3. Update frames from on.* re-arm + stream.write() on resume.
        expected = [
            "event: update\ndata: streamkv/in/1=alpha\n\n",
            "event: update\ndata: streamkv/in/2=bravo\n\n",
            "event: update\ndata: streamkv/in/3=charlie\n\n",
        ]
        seen = sum(1 for f in expected if f in body)
        check("kv-wake update frames (>= 2 of 3)", seen >= 2,
              f"got {seen}/3 — body={body!r}")
        if seen >= 2:
            print(f"  ok  received {seen}/3 stream.* + on.kv update frames")
        if seen < 2:
            c.dump_node_log(grep=["stream", "kv", "wake", "park", "resolve",
                                  "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS stream.* effect smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
