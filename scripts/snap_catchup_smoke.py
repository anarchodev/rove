#!/usr/bin/env python3
"""End-to-end smoke for production.md #1.1 step 3 — out-of-band snapshot
catchup for a far-behind follower.

Python port of `scripts/snap_catchup_smoke.sh`. Verifies the full cycle:
  stage → exit → install → raft_load_snapshot → cleanup.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
SYSTEM_SUFFIX = "rewindjscom.localhost"
ADMIN_HOST = f"app.{SYSTEM_SUFFIX}"
WRITE_BURSTS = 30
TICK_INTERVAL_MS = 500


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="snap-catchup",
        http_base=8480,
        raft_base=40480,
        files_port=8482,
        log_port=8483,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=[
            "--snapshot-interval-ms", str(TICK_INTERVAL_MS),
            "--election-timeout-ms", "1000",
            "--heartbeat-ms", "100",
        ],
    )
    with cluster as c:
        time.sleep(3)
        c.discover_leader()
        leader_idx = c.leader_idx
        print(f"initial leader: node {leader_idx} at {c.addrs.http[leader_idx]}")

        # Pick a follower to stop.
        follower_idx = next(j for j in range(3) if j != leader_idx)
        follower_data = c.addrs.data_dirs[follower_idx]
        print(f"stopping follower: node {follower_idx}")
        c.stop_node(follower_idx)

        cc = c.curl_ctx(f"spread.{PUBLIC_SUFFIX}")
        leader_port = c.leader_port()
        spread_url = f"https://spread.{PUBLIC_SUFFIX}:{leader_port}/?fn=handler"

        print(f"driving {WRITE_BURSTS} write bursts of 50 reqs each…")
        for burst in range(WRITE_BURSTS):
            # 50 parallel requests via xargs+curl would be ideal, but
            # we don't need real parallelism — serial 50 still
            # advances the raft log enough.
            for _ in range(50):
                try:
                    curl(cc, spread_url, timeout=3.0)
                except (subprocess.TimeoutExpired, RuntimeError):
                    pass
            time.sleep(0.1)
        time.sleep(2)

        leader_log = Path(f"/tmp/snap-catchup-worker-{leader_idx}.out")
        snap_idx_match = re.findall(
            r"snapshot tick apply_position=(\d+)",
            leader_log.read_text(errors="replace"),
        )
        snap_idx = snap_idx_match[-1] if snap_idx_match else "unknown"
        print(f"leader snapshot_last_idx after burst: {snap_idx}")

        # First respawn: receiver fetches + stages + exits cleanly.
        print("restarting follower (1st time — stages bundle, then exits)…")
        follower_log = Path(f"/tmp/snap-catchup-worker-{follower_idx}.out")
        offset_1 = follower_log.stat().st_size if follower_log.exists() else 0

        c.start_node(follower_idx, extra_args=[
            "--snapshot-interval-ms", str(TICK_INTERVAL_MS),
            "--election-timeout-ms", "1000",
            "--heartbeat-ms", "100",
        ])

        # Wait for follower to exit (it does std.process.exit(0) after stage).
        stage_ok = False
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            if c.workers[follower_idx].poll() is not None:
                # Exited.
                with follower_log.open("rb") as f:
                    f.seek(offset_1)
                    chunk = f.read().decode(errors="replace")
                if re.search(r"raft: snap fetch.*staged.*files", chunk):
                    stage_ok = True
                break
            time.sleep(0.5)

        # Confirm staged dir exists with _install_meta.json.
        staged_dirs = list(follower_data.glob(".snap-in-*"))
        meta_found = bool(staged_dirs and (staged_dirs[0] / "_install_meta.json").exists())

        # Second respawn: boot-time install picks up the staged dir.
        print("restarting follower (2nd time — boot-time install)…")
        offset_2 = follower_log.stat().st_size if follower_log.exists() else 0
        c.start_node(follower_idx, extra_args=[
            "--snapshot-interval-ms", str(TICK_INTERVAL_MS),
            "--election-timeout-ms", "1000",
            "--heartbeat-ms", "100",
        ])

        install_ok = False
        load_ok = False
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            with follower_log.open("rb") as f:
                f.seek(offset_2)
                chunk = f.read().decode(errors="replace")
            if "loop46: installing staged snapshot from" in chunk:
                install_ok = True
            if "staged snapshot installed and raft_load_snapshot called" in chunk:
                load_ok = True
                break
            time.sleep(0.5)

        # Cleanup of staged dir.
        cleanup_ok = not list(follower_data.glob(".snap-in-*"))

        print()
        print("── results ──")
        print(f"checks: stage={int(stage_ok)} meta_file={int(meta_found)} install={int(install_ok)} load={int(load_ok)} cleanup={int(cleanup_ok)}")

        if stage_ok and meta_found and install_ok and load_ok and cleanup_ok:
            print()
            print("PASS — full catchup cycle: stage → exit → install → raft_load_snapshot → cleanup.")
            return 0
        else:
            print()
            print("FAIL — one or more checks did not pass within 30s")
            with follower_log.open("r", errors="replace") as f:
                print(f.read()[-3000:], file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main())
