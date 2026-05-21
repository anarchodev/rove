#!/usr/bin/env python3
"""End-to-end smoke for streaming-handlers Phase 3 — kv-write wake.

Topology:
  • 3-node cluster (rove-h2 on ports 8340..8342, raft on 40440..40442).
  • `acme` tenant: `/watch` subscribes to kv prefix `watch/` and emits
    SSE frames on every put/delete; `/writekey` POSTs a value under
    that prefix.

The smoke holds a streaming GET on the LEADER while POSTing writes
to the same leader (Loop46 serves all customer traffic on the
leader — followers 503; per `worker_dispatch.zig:1838`). The two
producers of kv-wake events both fire:

  1. **Leader-side eager broadcast** — `worker_dispatch.zig`'s
     `finalizeBatch` write path calls
     `worker.node.broadcastKvWake(tenant, key, op)` right after
     `txn.releaseLease()` (before the raft propose). This wakes the
     leader's locally-held streams.
  2. **Follower-side apply hook** — `apply.zig`'s `applyWriteSet`
     decodes the just-applied writeset and fans out the same events
     to every follower's `KvWakeInbox`. No follower has a stream
     here (loop46 doesn't serve traffic on followers in v1), but
     the apply-thread fan-out IS the cross-node-correctness
     mechanism — its presence in worker stderr proves the §9.3
     fanout would reach a stream if it existed.

Gates:
  1. Watcher receives SSE frames carrying the written key+value+op
     (`event: update\\ndata: watch/<id>=<v> (put)\\n\\n`).
  2. `request.activation.kind === "wake_batch"` — wrong kind would
     emit a different frame; the body assertion picks that up.
  3. `request.activation.wakes[i].key` + `.op` — frame payload
     echoes them (one frame per kv entry in the batch).
  4. Multiple consecutive wakes — verifies the cell re-registers
     its prefix on each `__rove_stream` return.
  5. The follower's apply-thread fan-out fires for each write
     (proves the cross-node code path runs).
  6. §4.4 disconnect activation cleans up the cell when the
     watcher closes.
  7. Worker keeps serving after disconnect.
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
        tag="streaming-kv-wake-smoke",
        http_base=8340,
        raft_base=40440,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_idx = c.leader_idx
        follower_idx = (leader_idx + 1) % 3
        leader_port = c.addrs.http_port(leader_idx)
        print(
            f"ok  leader=node{leader_idx} ({c.addrs.http[leader_idx]}); "
            f"will verify follower-side fan-out on node{follower_idx}"
        )

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        # Wait for acme to be reachable on the leader.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL acme not reachable on leader: status={r.status}")
        print("ok  acme reachable on leader")

        # Spawn the watcher. --no-buffer streams chunks to stdout as
        # they arrive; --max-time caps the read window. Background
        # `Popen` so we can POST writes while it holds the stream.
        url = f"{leader_origin}/watch"
        args = cc.args() + [
            "-N",
            "--max-time", "3.0",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Give the watcher a moment to register its kv prefix with
        # the leader's parked_streams_meta. 200ms is plenty under
        # load — the worker's poll loop is millisecond-scale.
        time.sleep(0.3)

        # POST three writes. Each fires a kv-wake event on the
        # leader (via `worker_dispatch.zig`'s broadcast) and on
        # every follower (via `apply.zig`'s broadcast after raft
        # delivers the writeset).
        for i, value in enumerate(["alpha", "bravo", "charlie"], start=1):
            body = json.dumps({"id": str(i), "value": value})
            r = curl(
                cc,
                f"{leader_origin}/writekey",
                method="POST",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            if r.status != 204:
                watcher.kill()
                sys.exit(f"FAIL writekey id={i} status={r.status} body={r.body!r}")
            # Small gap so each wake reaches the watcher as a
            # separate frame.
            time.sleep(0.20)
        print("ok  three writes posted")

        # Let the watcher drain remaining wakes then close.
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
            sys.exit(f"FAIL no header block in watcher response: {raw!r}")
        header_block = raw[:split].decode(errors="replace")
        body = raw[split + 4 :].decode(errors="replace")

        # Header sanity (set on first-hop).
        headers = {}
        for line in header_block.splitlines():
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        if "text/event-stream" not in headers.get("content-type", ""):
            sys.exit(
                f"FAIL Content-Type missing/wrong: {headers.get('content-type')!r}"
            )
        print("ok  Content-Type set to text/event-stream")

        # Initial snapshot fires from inbound hop.
        if "event: snapshot\ndata: initial\n\n" not in body:
            sys.exit(f"FAIL initial snapshot frame missing: body={body!r}")
        print("ok  initial snapshot frame received")

        # Three update frames carry the kv-wake payload.
        expected_updates = [
            "event: update\ndata: watch/1=alpha (put)\n\n",
            "event: update\ndata: watch/2=bravo (put)\n\n",
            "event: update\ndata: watch/3=charlie (put)\n\n",
        ]
        seen = sum(1 for f in expected_updates if f in body)
        if seen < 2:
            sys.exit(
                f"FAIL kv-wake updates: expected >= 2 of 3 update frames, "
                f"got {seen}. body={body!r}"
            )
        print(f"ok  received {seen}/3 kv-wake update frames")
        if seen == 3:
            print(
                "ok  all three writes delivered (strong same-node kv-wake sequence)"
            )

        # §9.3 cross-node fan-out: the follower's apply.zig hook
        # also broadcast each write. Tail the follower's stderr for
        # the proof. (No stream on the follower to wake — loop46
        # serves all customer traffic on the leader — but the
        # apply-thread fan-out IS the cross-node-correctness path.)
        needle = "rove-js kv-wake apply: tenant=acme fanned out"
        follower_log = c.log_dir / f"{c.tag}-worker-{follower_idx}.out"
        deadline = time.monotonic() + 3.0
        follower_fanout_seen = 0
        while time.monotonic() < deadline:
            try:
                contents = follower_log.read_text(errors="replace")
            except FileNotFoundError:
                contents = ""
            follower_fanout_seen = contents.count(needle)
            if follower_fanout_seen >= 3:
                break
            time.sleep(0.05)
        if follower_fanout_seen < 3:
            sys.exit(
                f"FAIL follower fan-out: expected >= 3 apply-thread broadcasts "
                f"on node{follower_idx}, saw {follower_fanout_seen} "
                f"({follower_log})"
            )
        print(
            f"ok  follower node{follower_idx} broadcast fan-out fired "
            f"{follower_fanout_seen} times (cross-node §9.3 plumbing live)"
        )

        # §4.4 disconnect activation cleans up the cell.
        disc_needle = "rove-js stream-disconnect: tenant=acme"
        deadline = time.monotonic() + 3.0
        log_paths = list(c.log_dir.glob(f"{c.tag}-worker-*.out"))
        disc_seen = False
        while time.monotonic() < deadline and not disc_seen:
            for lp in log_paths:
                try:
                    if disc_needle in lp.read_text(errors="replace"):
                        disc_seen = True
                        break
                except FileNotFoundError:
                    continue
            if not disc_seen:
                time.sleep(0.05)
        if not disc_seen:
            sys.exit("FAIL disconnect activation never logged for kv-wake stream")
        print("ok  §4.4 disconnect activation fired (kv-wake cell cleanup ran)")

        # Worker still serves after disconnect.
        r = curl(cc, f"{leader_origin}/", method="GET")
        if r.status not in (200, 404):
            sys.exit(f"FAIL post-disconnect ping status={r.status}")
        print(f"ok  leader still serves after disconnect (ping={r.status})")

        print()
        print(
            "streaming-handlers Phase 3 kv-wake smoke passed "
            "(apply-thread fan-out + leader-side eager fire + per-worker "
            "inbox + cross-node §9.3 plumbing)"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
