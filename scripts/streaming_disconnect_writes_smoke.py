#!/usr/bin/env python3
"""End-to-end smoke for streaming-handlers Phase 4c — disconnect
activation writes kv.

The §7 worked example's "release resources / log session ended"
cleanup pattern requires the disconnect hop to write kv. Phase 4c
lifted the read-only-resume restriction on the disconnect path:
when h2's `serverStreamClose` routes the entity to `response_out`
without our `close_pending` path firing (= client disconnect),
`fireDisconnectActivation` now PROPOSES the writes through raft
(no entity to gate on — `proposeForgetfulWrites` parks the txn on
`pending_txns[seq]` so `drainRaftPending` commits asynchronously).

Topology + fixtures:
  • `acme/disc_writer/index.mjs` — streams 100 ms heartbeats; on
    disconnect activation, writes `disc_marker/<id>` = "fired".
  • `acme/readkey/index.mjs` — `GET /readkey?key=<k>` → kv.get(k).

Gates:
  1. Watcher opens the stream and immediately closes.
  2. `disconnect activation fired` log line appears (Phase 2b-ii
     gate still holds).
  3. `disc_marker/1` reads back "fired" — the write committed via
     `drainRaftPending` AFTER the client closed the socket.
  4. Pre-Phase-4 the same test would have failed because the
     write was rejected with a 500 outcome on the tape and never
     reached raft.
"""

from __future__ import annotations

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
        tag="streaming-disc-writes-smoke",
        http_base=8350,
        raft_base=40450,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        # Reachability.
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

        # Sanity: the marker key shouldn't exist yet.
        r = curl(cc, f"{leader_origin}/readkey?key=disc_marker/1")
        if r.status != 404:
            sys.exit(
                f"FAIL preflight: disc_marker/1 already set "
                f"(status={r.status} body={r.body!r})"
            )
        print("ok  marker key absent before stream open")

        # Open the disc_writer stream briefly and close. The disconnect
        # activation writes disc_marker/1 = "fired" — Phase 4c is what
        # makes this actually commit.
        url = f"{leader_origin}/disc_writer"
        args = cc.args() + [
            "-N",
            "--max-time", "0.3",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        proc = subprocess.run(args, capture_output=True, timeout=10)
        if proc.returncode not in (0, 28):
            sys.exit(f"FAIL stream curl exit={proc.returncode}")
        print("ok  disc_writer stream opened + closed")

        # Wait for the disconnect activation to fire + commit. The
        # raft commit deadline-ns is ~3s by default; allow some
        # margin.
        needle = "rove-js stream-disconnect: tenant=acme"
        deadline = time.monotonic() + 5.0
        disc_seen = False
        log_paths = list(c.log_dir.glob(f"{c.tag}-worker-*.out"))
        while time.monotonic() < deadline and not disc_seen:
            for lp in log_paths:
                try:
                    if needle in lp.read_text(errors="replace"):
                        disc_seen = True
                        break
                except FileNotFoundError:
                    continue
            if not disc_seen:
                time.sleep(0.05)
        if not disc_seen:
            sys.exit("FAIL disconnect activation log never appeared")
        print("ok  §4.4 disconnect activation fired")

        # Read back the marker key. Phase 4c committed the write
        # async; allow a short window for drainRaftPending to land
        # the commit.
        deadline = time.monotonic() + 5.0
        got = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/readkey?key=disc_marker/1")
            if r.status == 200:
                got = r.body
                break
            time.sleep(0.05)
        if got != "fired":
            sys.exit(
                f"FAIL Phase 4c gate: disc_marker/1 expected 'fired', "
                f"got status={r.status} body={r.body!r} — disconnect-time "
                f"writes did NOT commit"
            )
        print(f"ok  disc_marker/1 = 'fired' (Phase 4c write committed via raft)")

        print()
        print(
            "streaming-handlers Phase 4c smoke passed "
            "(disconnect-activation writes propose + commit asynchronously)"
        )
        return 0


if __name__ == "__main__":
    sys.exit(main())
