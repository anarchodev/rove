#!/usr/bin/env python3
"""V2 port of `streaming_overflow_smoke.py` — Gap 2.2 §9.4 `PendingWakes`
ring overflow, on the `V2Cluster` harness.

`/overflow_watch` arms `on.kv("overflow/")`; on every wake_batch activation
it emits ONE status frame echoing `request.activation.wakes.length` +
`request.activation.overflow.lost_oldest`, then re-arms.
`/overflow_burst` POSTs `{count}` and does `kv.set("overflow/k{i}", ...)`
for i in 0..count in ONE handler invocation — one writeset → one apply
broadcast → one drain pushing N events into the ring. With N > CAP (32)
the ring drops the oldest (N - CAP) entries and bumps `lost_oldest`.

Essential assertion kept from V1 (the load-bearing §9.4 contract): a
50-key burst yields a `batch` frame reporting `wakes=32 lost=18`
(PENDING_WAKES_CAP=32, 50 - 32 = 18).

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader/discover_leader.

Streaming addressing (same as streaming_kv_wake_smoke_v2): the held SSE
GET and the burst POST both go DIRECT to the node — the front buffers
open-ended SSE (0 bytes in-window) and head-of-lines a same-conn trigger.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# Handler JS verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/{overflow_watch,overflow_burst}/index.mjs).
OVERFLOW_WATCH_SRC = """\
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: open\\ndata: ok\\n\\n");
    on.kv("overflow/");
    return next();
}

export function onWake() {
    const a = request.activation;
    stream.start();
    stream.write(`event: batch\\ndata: wakes=${a.wakes.length} lost=${a.overflow.lost_oldest}\\n\\n`);
    on.kv("overflow/");
    return next();
}
"""

OVERFLOW_BURST_SRC = """\
export default function () {
    const body = JSON.parse(request.body || "{}");
    const count = body.count ?? 50;
    for (let i = 0; i < count; i++) {
        kv.set("overflow/k" + i, "v" + i);
    }
    response.status = 204;
    return "";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def _stream_watch(c: V2Cluster, path: str, max_time: float) -> "subprocess.Popen":
    """Held SSE GET DIRECT to the node (the front buffers open-ended SSE)."""
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

    with V2Cluster.spawn("stream-overflow", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy overflow_watch + overflow_burst (+ readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "overflow_watch/index.mjs": OVERFLOW_WATCH_SRC,
                "overflow_burst/index.mjs": OVERFLOW_BURST_SRC,
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

        print("step 4: hold SSE GET /overflow_watch, POST a 50-key burst")
        watcher = _stream_watch(c, "/overflow_watch", max_time=4.0)
        time.sleep(0.5)  # let the inbound hop arm on.kv("overflow/")

        # The burst: 50 kv writes in ONE handler invocation → ONE writeset
        # → ONE apply broadcast → ONE drain of 50 events into the ring.
        # CAP=32; expect 18 dropped. DIRECT to the node (separate conn).
        burst = c.node_request("/overflow_burst", method="POST",
                               host=c.host_for("acme"),
                               headers={"Content-Type": "application/json"},
                               data='{"count":50}')
        if burst.status != 204:
            watcher.kill()
            check("overflow_burst → 204", False, f"got {burst.status} {burst.body!r}")
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        check("burst posted (50 kv writes in one writeset)", True)

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
        body = raw[split + 4:].decode(errors="replace")

        check("initial open frame received",
              "event: open\ndata: ok\n\n" in body, f"body={body!r}")

        # The §9.4 contract: ring CAP=32, burst=50 → wakes=32, lost=18.
        expected = "event: batch\ndata: wakes=32 lost=18\n\n"
        ok = expected in body
        batch_lines = [ln for ln in body.splitlines() if ln.startswith("data: wakes=")]
        check("§9.4 ring overflow surfaced (wakes=32 lost=18)", ok,
              f"batch lines: {batch_lines!r}; full body: {body!r}")
        if not ok:
            c.dump_node_log(grep=["overflow", "stream", "wake", "kv",
                                  "resolve", "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming overflow smoke (v2)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
