#!/usr/bin/env python3
"""V2 port of `streaming_disconnect_writes_smoke.py` — disconnect activation
writes kv, on the `V2Cluster` harness (`smoke_lib_v2`).

The `acme/disc_writer` handler streams `:hb` heartbeats on a fast timer and,
on the §4.4 disconnect activation (`onDisconnect`), writes
`disc_marker/<id>` = "fired". The smoke holds the SSE stream briefly then
kills the curl subprocess (= client disconnect), and asserts the marker key
read back "fired" — i.e. the disconnect-time write proposed + committed
through raft AFTER the socket closed.

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader election /
discover_leader, seed_manifest (V2 provisions + deploys explicitly), and the
worker-stderr `stream-disconnect:` log scrape (the durable kv read-back is
the real gate; the log line is an implementation detail). The handler JS is
reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/{disc_writer,readkey}/index.mjs`).

CRITICAL (V2 streaming addressing): the held SSE GET goes DIRECT to the node
(the front buffers a response before relaying, so an open-ended stream yields
0 bytes and never reaches the worker as a held request). We kill the curl
subprocess mid-stream to simulate the client disconnect. The marker is read
back via `admin_kv_get` (worker `/_system/v2-kv`).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


READY_SRC = 'export function handler() { return "ready"; }\n'


def _open_stream(c: V2Cluster, path: str) -> "subprocess.Popen":
    """Open a held SSE GET DIRECT to the node, streaming to a PIPE. We kill
    this process mid-stream to simulate a client disconnect."""
    url = f"{c.node_url()}{path}"
    args = [
        "curl", "-sS", "--http2-prior-knowledge", "-N",
        "-H", f"Host: {c.host_for('acme')}",
        "--max-time", "10",
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

    with V2Cluster.spawn("strm-disc", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy disc_writer + readkey (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "disc_writer/index.mjs": _src("acme/disc_writer/index.mjs"),
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

        print("step 4: preflight — disc_marker/1 must be absent before stream")
        pre = c.admin_kv_get("acme", "disc_marker/1")
        check("marker key absent before stream open", pre.status != 200,
              f"got {pre.status} {pre.body!r}")

        print("step 5: hold the disc_writer stream briefly, then KILL it "
              "(client disconnect)")
        proc = _open_stream(c, "/disc_writer")
        # Let the inbound hop arm + a couple heartbeats flow so the held
        # stream is firmly established before we sever it.
        time.sleep(0.8)
        proc.kill()
        try:
            proc.communicate(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
        check("disc_writer stream opened + killed", True)

        print("step 6: read back disc_marker/1 — the disconnect-activation write")
        # Phase 4c committed the write async via drainRaftPending after the
        # socket closed; poll for it to land.
        deadline = time.monotonic() + 8.0
        got = None
        last = None
        while time.monotonic() < deadline:
            r = c.admin_kv_get("acme", "disc_marker/1")
            last = r
            if r.status == 200 and r.body.strip() == "fired":
                got = r.body.strip()
                break
            time.sleep(0.2)
        _ls = last.status if last else "-"
        _lb = repr(last.body) if last else ""
        check("disc_marker/1 == 'fired' (disconnect write committed via raft)",
              got == "fired", f"got {_ls} {_lb}")
        if got != "fired":
            c.dump_node_log(grep=["disconnect", "stream", "disc", "wake",
                                  "kv", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming-disconnect-writes smoke (v2): the §4.4 disconnect "
          "activation's kv write proposes + commits asynchronously after the "
          "client severs the socket")
    return 0


if __name__ == "__main__":
    sys.exit(main())
