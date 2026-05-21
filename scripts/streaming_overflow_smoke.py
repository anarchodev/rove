#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.2 §9.4 — `PendingWakes` ring overflow.

Setup:
  • 3-node cluster, leader-only customer traffic (per loop46 §13).
  • `acme/overflow_watch` subscribes SSE to kv prefix `overflow/`;
    every wake_batch activation emits one frame echoing
    `wakes.length` + `overflow.lost_oldest`.
  • `acme/overflow_burst` POST endpoint does
    `kv.set("overflow/k{i}", "v{i}")` for i in 0..count in ONE
    handler invocation — i.e., one writeset, one apply-thread
    broadcast, one drainKvWakeInbox call pushing N events into the
    ring in one batch. When N > CAP (32), the ring drops the
    oldest (N - CAP) entries + bumps `lost_oldest` accordingly.

Gate: the smoke POSTs a 50-key burst and asserts the watcher
receives a `batch` frame reporting `wakes=32 lost=18` (PENDING_WAKES_CAP=32,
50 - 32 = 18). This is the load-bearing §9.4 contract — that
high-write-rate workloads see `lost_oldest > 0` and can refetch
authoritative kv state instead of relying on per-wake fidelity.
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
        tag="streaming-overflow-smoke",
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
        leader_port = c.addrs.http_port(c.leader_idx)
        print(f"ok  leader=node{c.leader_idx} ({c.addrs.http[c.leader_idx]})")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        # Reachability gate.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL acme not reachable on leader")
        print("ok  acme reachable on leader")

        # Open the SSE watcher. --max-time gives the burst + drain
        # enough room to fire one batch frame; -N disables curl's
        # output buffering so we see frames live.
        url = f"{leader_origin}/overflow_watch"
        args = cc.args() + [
            "-N",
            "--max-time", "4.0",
            "-D", "-",
            "-o", "-",
            "-X", "GET",
            url,
        ]
        watcher = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Let the watcher's first-hop register its `overflow/` prefix
        # in the worker's stream-pipeline collections before the
        # burst arrives. 300ms is comfortable headroom.
        time.sleep(0.3)

        # The burst: 50 kv writes in ONE handler invocation → ONE
        # writeset → ONE apply broadcast → ONE drainKvWakeInbox push
        # of 50 events. Ring CAP=32; we expect 18 dropped.
        r = curl(
            cc,
            f"{leader_origin}/overflow_burst",
            method="POST",
            data='{"count":50}',
            headers={"Content-Type": "application/json"},
        )
        if r.status != 204:
            watcher.kill()
            sys.exit(f"FAIL overflow_burst status={r.status} body={r.body!r}")
        print("ok  burst posted (50 kv writes in one writeset)")

        # Drain the watcher.
        try:
            stdout, _ = watcher.communicate(timeout=5.0)
        except subprocess.TimeoutExpired:
            watcher.kill()
            stdout, _ = watcher.communicate()
        if watcher.returncode not in (0, 28):
            sys.exit(f"FAIL watcher curl exit={watcher.returncode}")

        raw = stdout or b""
        split = raw.rfind(b"\r\n\r\n")
        if split < 0:
            sys.exit(f"FAIL no header block in watcher response: {raw!r}")
        body = raw[split + 4:].decode(errors="replace")

        # Initial open frame from inbound hop.
        if "event: open\ndata: ok\n\n" not in body:
            sys.exit(f"FAIL initial open frame missing: body={body!r}")
        print("ok  initial open frame received")

        # The §9.4 contract: ring CAP=32, burst=50 → wakes=32, lost=18.
        expected = "event: batch\ndata: wakes=32 lost=18\n\n"
        if expected not in body:
            # Try to surface what we got for triage.
            batch_lines = [
                line for line in body.splitlines()
                if line.startswith("data: wakes=")
            ]
            sys.exit(
                f"FAIL §9.4 overflow contract violated. expected exactly "
                f"{expected!r} in body. batch lines: {batch_lines!r}. "
                f"full body: {body!r}"
            )
        print("ok  §9.4 ring overflow surfaced (wakes=32 lost=18)")

        print(
            "\nstreaming-overflow smoke passed (Gap 2.2 §9.4: "
            "PendingWakes ring drops oldest + reports lost_oldest)"
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
