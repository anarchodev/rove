#!/usr/bin/env python3
"""V2 port of `streaming_first_hop_writes_smoke.py` — stream-first-hop
writes kv (handler-surface Phase 2 `stream.*`) on the `V2Cluster` harness.

The "open a session" pattern: `acme/sessions_sse` registers the connection
in kv (`kv.set("sessions/<id>", "online")`) as part of the initial hop AND
streams live SSE events. The first-hop writeset proposes through raft; on
commit the entity routes into `stream_response_in` and the chain streams.
On client disconnect the `onDisconnect` handler flips the value to
"offline".

Gates (unchanged from V1):
  1. Preflight: `sessions/alice` absent (readkey → 404).
  2. Open held SSE with `id=alice`; the `event: hello\\ndata: alice` frame
     carries the session id, Content-Type is text/event-stream.
  3. While held: `readkey?key=sessions/alice` → "online" — proves the
     first-hop write committed through raft.
  4. After disconnect: `sessions/alice` flips to "offline" (the
     `onDisconnect` cleanup write committed).

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader election /
discover_leader, seed_manifest (V2 provisions + deploys explicitly). The
handler JS is reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/{sessions_sse,readkey}/index.mjs`).

The held SSE request + the concurrent `readkey` probes go DIRECT to the
node: the V2 front door buffers the whole backend response (single
`RespBody` relay, src-v2/front/main.zig), so a never-terminating SSE
stream through it never flushes a chunk, AND a side request multiplexed on
the same upstream conn would queue head-of-line behind the held stream.
Direct-to-node uses one h2 connection per curl, so the probes don't HOL.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

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

    with V2Cluster.spawn("fhw", nodes=1) as c:
        host = c.host_for("acme")

        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy sessions_sse + readkey (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "sessions_sse/index.mjs": _src("acme/sessions_sse/index.mjs"),
                "readkey/index.mjs": _src("acme/readkey/index.mjs"),
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

        # Direct-to-node readkey probe (one h2 conn per curl → no HOL behind
        # the held SSE stream; the front door would also buffer it).
        def readkey(key: str):
            return c.node_request(f"/readkey?key={key}", host=host)

        print("step 4: preflight — sessions/alice absent")
        r = readkey("sessions/alice")
        check("sessions/alice absent (404) before stream open", r.status == 404,
              f"got {r.status} {r.body!r}")

        print("step 5: open held SSE /sessions_sse?id=alice (direct to node)")
        # `--max-time 1.5` holds the stream open ~1.5s, then curl exits — that
        # exit is the client disconnect that fires the onDisconnect cleanup.
        url = f"{c.node_url(0)}/sessions_sse?id=alice"
        args = ["curl", "-sS", "--http2-prior-knowledge", "-N",
                "--max-time", "1.5", "-H", f"Host: {host}",
                "-D", "-", "-o", "-", "-X", "GET", url]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        # Give the first-hop write time to propose + commit through raft.
        time.sleep(0.5)

        print("step 6: while held — sessions/alice == 'online' (first-hop write committed)")
        r = readkey("sessions/alice")
        check("first-hop write committed while held: 'online'",
              r.status == 200 and r.body == "online",
              f"got {r.status} {r.body!r}")

        # Drain the watcher to capture the SSE frames.
        try:
            stdout, _ = watcher.communicate(timeout=4.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        if watcher.returncode not in (0, 28):
            check("held SSE curl exit 0/28", False,
                  f"exit={watcher.returncode}")

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            check("response has a header block", False, f"raw={raw!r}")
        else:
            header_block = raw[:split].decode(errors="replace")
            body = raw[split + 4:].decode(errors="replace")
            headers = {}
            for line in header_block.splitlines():
                if ":" in line and not line.startswith("HTTP/"):
                    k, _, v = line.partition(":")
                    headers[k.strip().lower()] = v.strip()
            ct = headers.get("content-type", "")
            check("Content-Type == text/event-stream", "text/event-stream" in ct,
                  f"got {ct!r}")
            check("hello frame carries session id",
                  "event: hello\ndata: alice\n\n" in body, f"body={body!r}")

        print("step 7: after disconnect — sessions/alice flips to 'offline'")
        # The onDisconnect handler's kv.set flips the value; allow the
        # disconnect activation + its write to commit.
        got = None
        deadline = time.monotonic() + 6.0
        while time.monotonic() < deadline:
            r = readkey("sessions/alice")
            if r.status == 200 and r.body == "offline":
                got = r.body
                break
            time.sleep(0.1)
        check("onDisconnect wrote 'offline' after disconnect", got == "offline",
              f"got {r.status} {r.body!r}")
        if got != "offline":
            c.dump_node_log(grep=["stream", "disconnect", "session", "kv",
                                  "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming first-hop-writes smoke (v2): first-hop writeset "
          "proposes + commits; entity routes to stream_response_in; "
          "onDisconnect cleanup write commits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
