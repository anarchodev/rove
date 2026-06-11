#!/usr/bin/env python3
"""V2 port of `streaming_kv_wake_writes_smoke.py` — stream-resume hops
write kv, on the `V2Cluster` harness.

The "react to writes by writing" pattern: `/watchwrite` arms
`on.kv("watchwrite/in/")`; on every kv-wake it reads the new value,
writes a processed mirror to `watchwrite/out/<id>` = `processed:<value>`,
emits a `relayed` SSE frame, and re-arms. The stream-resume hop's writes
propose asynchronously while the frame ships live.

Essential assertions kept from V1:
  1. Initial `event: ready\\ndata: 1\\n\\n` frame on connect.
  2. Each of three writes to `watchwrite/in/<id>` produces a `relayed`
     frame echoing source -> destination key.
  3. `watchwrite/out/<id>` = `processed:v<n>` durably committed — proving
     the wake-resume hop's kv write landed (verified via admin_kv_get
     instead of V1's /readkey round-trip).

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader/discover_leader.

Streaming addressing (same as streaming_kv_wake_smoke_v2): the held SSE
GET and the trigger writes both go DIRECT to the node — the front buffers
open-ended SSE (0 bytes in-window) and head-of-lines a same-conn trigger.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# Handler JS verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/{watchwrite,writekv}/index.mjs).
WATCHWRITE_SRC = """\
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: ready\\ndata: 1\\n\\n");
    on.kv("watchwrite/in/");
    return next();
}

export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        const value = kv.get(w.key) ?? "(absent)";
        const out_key = "watchwrite/out/" + w.key.slice("watchwrite/in/".length);
        kv.set(out_key, "processed:" + value);
        stream.write(`event: relayed\\ndata: ${w.key}->${out_key}\\n\\n`);
    }
    on.kv("watchwrite/in/");
    return next();
}
"""

WRITEKV_SRC = """\
export default function () {
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

    with V2Cluster.spawn("stream-kvwrites", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy watchwrite + writekv (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "watchwrite/index.mjs": WATCHWRITE_SRC,
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

        print("step 4: hold SSE GET /watchwrite, POST three writes ~0.15s apart")
        watcher = _stream_watch(c, "/watchwrite", max_time=3.0)
        time.sleep(0.5)  # let the inbound hop arm on.kv("watchwrite/in/")

        ids = ["a", "b", "c"]
        for i, ident in enumerate(ids):
            body = json.dumps({"key": f"watchwrite/in/{ident}", "value": f"v{i+1}"})
            # DIRECT to the node (separate h2 connection from the watcher).
            w = c.node_request("/writekv", method="POST",
                               host=c.host_for("acme"),
                               headers={"Content-Type": "application/json"},
                               data=body)
            if w.status != 204:
                watcher.kill()
                check(f"writekv {ident} → 204", False, f"got {w.status} {w.body!r}")
                print(f"\nFAILURES ({len(failures)}): {failures}")
                return 1
            time.sleep(0.15)
        check("three writes posted (204)", True)

        try:
            stdout, _ = watcher.communicate(timeout=5.0)
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
        body_str = raw[split + 4:].decode(errors="replace")

        check("initial ready frame received",
              "event: ready\ndata: 1\n\n" in body_str, f"body={body_str!r}")

        expected = [
            f"event: relayed\ndata: watchwrite/in/{ident}->watchwrite/out/{ident}\n\n"
            for ident in ids
        ]
        seen = sum(1 for f in expected if f in body_str)
        check("≥2 of 3 relayed frames", seen >= 2,
              f"got {seen}/3; body={body_str!r}")
        if seen < 2:
            c.dump_node_log(grep=["watchwrite", "stream", "wake", "kv",
                                  "resolve", "404", "error", "warn"])

        print("step 5: verify the wake-resume hop writes committed durably")
        # admin_kv_get reads tenant KV via /_system/v2-kv. Allow a short
        # window for the async propose (drainRaftPending) to commit.
        for ident, n in zip(ids, range(1, 4)):
            want = f"processed:v{n}"
            deadline = time.monotonic() + 8.0
            got = None
            while time.monotonic() < deadline:
                rr = c.admin_kv_get("acme", f"watchwrite/out/{ident}")
                if rr.status == 200 and rr.body.strip():
                    got = rr.body.strip()
                    if got == want:
                        break
                time.sleep(0.2)
            check(f"watchwrite/out/{ident} == {want!r}", got == want,
                  f"got {got!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming kv-wake-writes smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
