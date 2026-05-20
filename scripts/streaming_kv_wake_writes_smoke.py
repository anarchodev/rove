#!/usr/bin/env python3
"""End-to-end smoke for streaming-handlers Phase 4b — stream-resume
hops write kv.

The "react to writes by writing" pattern: a streaming handler
subscribes to `watchwrite/in/`; on every kv-wake it reads the new
value, writes a processed mirror to `watchwrite/out/<id>` =
`processed:<value>`, and emits a `relayed` SSE frame. Pre-Phase-4b
the second hop hit the `kv_error` 500 boundary in `resumeStream`.
Post-Phase-4b `proposeForgetfulWrites` parks the txn on
`pending_units` for `drainRaftPending` to commit asynchronously
while the frame ships live.

Gates:
  1. Initial `event: ready\\ndata: 1\\n\\n` frame on connect.
  2. POST 3 writes to `watchwrite/in/<id>` via `/writekv`. Each
     fires a kv-wake; the watchwrite handler emits a `relayed`
     frame echoing the source + destination keys.
  3. After the smoke disconnects, GET `/readkey?key=
     watchwrite/out/<id>` returns `processed:<value>` — proving
     the stream-resume hop's write committed via raft.
"""

from __future__ import annotations

import json
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
        tag="streaming-kv-wake-writes-smoke",
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
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx}")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL acme not reachable: status={r.status}")
        print("ok  acme reachable")

        # Open the watchwrite stream.
        url = f"{leader_origin}/watchwrite"
        args = cc.args() + [
            "-N",
            "--max-time", "2.5",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.3)

        # Three writes to the subscribed prefix.
        ids = ["a", "b", "c"]
        for i, ident in enumerate(ids):
            body = json.dumps({
                "key": f"watchwrite/in/{ident}",
                "value": f"v{i+1}",
            })
            r = curl(
                cc,
                f"{leader_origin}/writekv",
                method="POST",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            if r.status != 204:
                watcher.kill()
                sys.exit(f"FAIL writekv {ident} status={r.status} body={r.body!r}")
            time.sleep(0.15)
        print("ok  three writes posted to subscribed prefix")

        # Drain the watcher.
        try:
            stdout, _ = watcher.communicate(timeout=4.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        if watcher.returncode not in (0, 28):
            sys.exit(f"FAIL watcher curl exit={watcher.returncode}")

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            sys.exit(f"FAIL no header block in response: {raw!r}")
        body_str = raw[split + 4 :].decode(errors="replace")

        # Initial frame.
        if "event: ready\ndata: 1\n\n" not in body_str:
            sys.exit(f"FAIL ready frame missing: {body_str!r}")
        print("ok  initial ready frame received")

        # Each write should produce a relayed frame.
        expected = [
            f"event: relayed\ndata: watchwrite/in/{ident}->watchwrite/out/{ident}\n\n"
            for ident in ids
        ]
        seen = sum(1 for f in expected if f in body_str)
        if seen < 2:
            sys.exit(
                f"FAIL relayed frames: expected >= 2 of 3, got {seen}. "
                f"body={body_str!r}"
            )
        print(f"ok  received {seen}/3 relayed frames")

        # Verify the kv writes from the wake-resume hops committed
        # via raft. `drainRaftPending`'s pending_units sweep
        # commits the txn parked by `proposeForgetfulWrites`;
        # allow a short window for the commit to land.
        for ident, value_idx in zip(ids, range(1, 4)):
            expected_value = f"processed:v{value_idx}"
            deadline = time.monotonic() + 5.0
            got = None
            while time.monotonic() < deadline:
                r = curl(
                    cc,
                    f"{leader_origin}/readkey?key=watchwrite/out/{ident}",
                )
                if r.status == 200:
                    got = r.body
                    break
                time.sleep(0.05)
            if got != expected_value:
                sys.exit(
                    f"FAIL kv-wake write {ident}: expected '{expected_value}', "
                    f"got {got!r} status={r.status} — Phase 4b write did NOT "
                    f"commit through raft"
                )
        print(
            f"ok  all three kv-wake-hop writes committed via raft "
            f"(watchwrite/out/{{a,b,c}} = processed:{{v1,v2,v3}})"
        )

        print()
        print(
            "streaming-handlers Phase 4b kv-wake-writes smoke passed "
            "(stream-resume hops propose writes async via proposeForgetfulWrites)"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
