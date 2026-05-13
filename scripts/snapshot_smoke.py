#!/usr/bin/env python3
"""End-to-end smoke for the snapshot capture + restore round-trip.

Python port of `scripts/snapshot_smoke.sh`. Covers:
  1. `loop46 snapshot` captures + `restore-from-snapshot` installs
  2. Periodic raft-thread capture via worker process (--snapshot-interval-ms)
  3. raft.log.db compaction is bounded (rows + file size)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, _load_dotenv, _require_env, curl  # noqa: E402

PERIODIC_TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "loop46.localhost"
ADMIN_HOST = f"app.{PUBLIC_SUFFIX}"


def main() -> int:
    bin_loop46 = BIN_DIR / "loop46"
    data_dir = Path("/tmp/rove-snapshot-smoke")
    restore_dir = Path("/tmp/rove-snapshot-restored")

    _load_dotenv()
    _require_env("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET", "S3_ENDPOINT", "S3_REGION")
    os.environ.setdefault(
        "S3_KEY_PREFIX_BASE",
        f"smoke-snapshot-{os.environ.get('HOSTNAME', 'host')}-{os.getuid()}/",
    )

    shutil.rmtree(data_dir, ignore_errors=True)
    shutil.rmtree(restore_dir, ignore_errors=True)

    # ── 1. Seed a tenant + plant kv state ────────────────────────────
    seed_manifest = Path("/tmp/snapshot-seed.json")
    seed_manifest.write_text(json.dumps({
        "tenants": [{
            "id": "acme", "domains": [], "files": [],
            "seed_kv": {"greeting": "hello-from-smoke", "counter": "42"},
        }]
    }))
    subprocess.run(
        [str(bin_loop46), "seed", "--data-dir", str(data_dir),
         "--manifest", str(seed_manifest)],
        check=True,
    )

    # ── 2. Capture via `loop46 snapshot` ─────────────────────────────
    rc = subprocess.run(
        [str(bin_loop46), "snapshot", "--data-dir", str(data_dir),
         "--apply-position", "100", "--willemt-term", "7"],
        capture_output=True, text=True,
    )
    if rc.returncode != 0:
        sys.exit(f"FAIL snapshot: {rc.stderr}")
    snap_id = ""
    # Output goes to stderr (info: ...) so combine both.
    for line in (rc.stdout + rc.stderr).splitlines():
        m = re.match(r"^captured snapshot (\S+)", line)
        if m:
            snap_id = m.group(1)
            break
    if not snap_id:
        sys.exit(f"FAIL no snap_id in output: stdout={rc.stdout!r} stderr={rc.stderr!r}")
    print(f"ok  loop46 snapshot captured snap_id={snap_id}")

    # ── 3. Restore into a fresh data dir ─────────────────────────────
    rc = subprocess.run(
        [str(bin_loop46), "restore-from-snapshot",
         "--snap-id", snap_id, "--data-dir", str(restore_dir)],
        capture_output=True, text=True,
    )
    if rc.returncode != 0:
        sys.exit(f"FAIL restore: {rc.stderr}")

    # ── 4. Verify restored state ─────────────────────────────────────
    def kv_get(dd: Path, store: str, *, key: str | None = None, apply_idx: bool = False) -> str:
        args = [str(bin_loop46), "kv-get", "--data-dir", str(dd), "--store", store]
        if apply_idx:
            args.append("--apply-idx")
        else:
            args += ["--key", key]
        rc = subprocess.run(args, capture_output=True, text=True)
        if rc.returncode != 0:
            sys.exit(f"FAIL kv-get {store}/{key or '<apply-idx>'}: {rc.stderr}")
        return rc.stdout.strip()

    if kv_get(restore_dir, "acme", key="greeting") != "hello-from-smoke":
        sys.exit("FAIL greeting mismatch")
    if kv_get(restore_dir, "acme", key="counter") != "42":
        sys.exit("FAIL counter mismatch")
    if kv_get(restore_dir, "acme", apply_idx=True) != "100":
        sys.exit("FAIL apply-idx mismatch")
    print("ok  greeting + counter + apply-idx round-tripped")
    print()
    print("ok  capture + restore round-trip (operator CLI)")

    # ── 5. Periodic capture via worker --snapshot-interval-ms ────────
    cluster = Cluster.spawn(
        tag="snapshot-smoke",
        http_base=8460,
        raft_base=40460,
        files_port=8462,
        log_port=8463,
        public_suffix=PUBLIC_SUFFIX,
        root_token=PERIODIC_TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest={"tenants": [
            {"id": "acme", "domains": [], "files": []},
            {"id": "quiet", "domains": [], "files": []},
        ]},
        worker_extra_args=["--snapshot-interval-ms", "500"],
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  periodic-loop leader: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")
        leader_dir = c.addrs.data_dirs[c.leader_idx]
        leader_port = c.leader_port()

        cc = c.curl_ctx()
        admin_origin = c.admin_origin()

        def release(tenant: str, dep_id: int) -> None:
            curl(
                cc, f"{admin_origin}/_system/release",
                method="POST",
                headers={
                    "Authorization": f"Bearer {PERIODIC_TOKEN}",
                    "Content-Type": "application/json",
                },
                data=json.dumps({"tenant_id": tenant, "dep_id": dep_id}),
                timeout=5.0,
            )

        release("quiet", 1)
        pre_burst = 20
        for i in range(1, pre_burst + 1):
            release("acme", i)
        time.sleep(3)

        leader_log = Path(f"/tmp/snapshot-smoke-worker-{c.leader_idx}.out")
        content = leader_log.read_text(errors="replace")
        ticks = re.findall(r"snapshot tick apply_position=(\d+).*?duration_ms=(\d+)", content)
        if not ticks:
            sys.exit(f"FAIL no 'snapshot tick' lines:\n{content[-1500:]}")
        print(f"ok  worker logged {len(ticks)} tick(s) after burst-1")

        max_duration = max(int(d) for _, d in ticks)
        if max_duration > 1000:
            sys.exit(f"FAIL snapshot tick duration {max_duration} ms > 1000")
        print(f"ok  max snapshot tick duration: {max_duration}ms")

        # ── 6. raft.log.db compaction (rows + file size) ─────────────
        raft_log = leader_dir / "raft.log.db"
        if not raft_log.exists():
            sys.exit(f"FAIL {raft_log} missing")

        def db_rows(p: Path) -> int:
            conn = sqlite3.connect(str(p))
            try:
                return conn.execute("SELECT COUNT(*) FROM raft_log").fetchone()[0]
            finally:
                conn.close()

        rows_baseline = db_rows(raft_log)
        size_baseline = raft_log.stat().st_size
        print(f"ok  baseline after burst-1: rows={rows_baseline} size={size_baseline} bytes")

        post_burst = 100
        for i in range(pre_burst + 1, pre_burst + post_burst + 1):
            release("acme", i)
        time.sleep(4)

        rows_after = db_rows(raft_log)
        size_after = raft_log.stat().st_size
        print(f"ok  after burst-2 (+{post_burst} commits): rows={rows_after} size={size_after} bytes")

        if rows_after > pre_burst:
            sys.exit(f"FAIL raft_log row count ({rows_after}) > {pre_burst}")
        print(f"ok  raft_log row count bounded after compaction ({rows_after} <= {pre_burst})")

        size_ceiling = size_baseline * 3
        if size_after > size_ceiling:
            sys.exit(f"FAIL raft.log.db size ({size_after}) > {size_ceiling}")
        print(f"ok  raft.log.db file size bounded after compaction ({size_after} <= {size_ceiling})")

        conn = sqlite3.connect(str(raft_log))
        av = conn.execute("PRAGMA auto_vacuum").fetchone()[0]
        conn.close()
        if av != 2:
            sys.exit(f"FAIL auto_vacuum={av} (want 2)")
        print("ok  raft.log.db auto_vacuum=INCREMENTAL")

        # ── 7. Durable raft idx in cluster.kv ────────────────────────
        latest_apply = max(int(p) for p, _ in re.findall(
            r"snapshot tick apply_position=(\d+).*?duration_ms=(\d+)",
            leader_log.read_text(errors="replace"),
        ))
        if latest_apply == 0:
            sys.exit("FAIL no apply_position in tick logs")
        print(f"ok  latest snapshot tick apply_position={latest_apply}")

    # Cluster shutdown happened via __exit__. Now read via kv-get.
    durable = kv_get(c.addrs.data_dirs[c.leader_idx], "__root__", apply_idx=True)
    print(f"  cluster.kv durable raft idx = {durable}")
    grace = 1
    if int(durable) + grace < latest_apply:
        sys.exit(f"FAIL durable ({durable}) < apply_position ({latest_apply})")
    print(f"ok  durable raft idx ({durable}) >= latest tick apply_position ({latest_apply} - {grace})")

    print()
    print("PASS snapshot smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
