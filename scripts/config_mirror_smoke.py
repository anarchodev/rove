#!/usr/bin/env python3
"""Smoke for the deploy-time `_config/` → kv mirror (config_mirror.zig).

Python port of `scripts/config_mirror_smoke.sh`. Verifies that seed
mirrors `_config/oauth/google.json` from the file tree into kv on every
node — both via a handler GET /cfg and via direct kv-get on each node's
cluster.kv after shutting down.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, curl  # noqa: E402

TOKEN = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PUBLIC_SUFFIX = "loop46.localhost"
ADMIN_HOST = f"app.{PUBLIC_SUFFIX}"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="config-mirror-smoke",
        http_base=8316,
        raft_base=40416,
        files_port=8318,
        log_port=8319,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        expected = json.loads(
            (repo_root / "examples" / "loop46-demo-tenants" / "acme"
             / "_config" / "oauth" / "google.json").read_text()
        )

        cc = c.curl_ctx(ACME_HOST)
        acme_origin = f"https://{ACME_HOST}:{c.leader_port()}"

        # Wait for acme to be loaded. The cfg/index.mjs handler is part
        # of the demo manifest so it lands with the cold-start deploy.
        r = c.wait_for_handler("acme", "/cfg", expected_status=200, timeout_s=20.0)
        got = json.loads(r.body)
        if got != expected:
            sys.exit(f"FAIL leader /cfg: {got!r} != {expected!r}")
        print("ok  leader has _config/oauth/google row mirrored from the file tree")

        # Shut every node down so the offline kv-get reader can open
        # the LMDB env (MDB_NOLOCK = single-process).
        for p in c.workers:
            if p.poll() is None:
                p.terminate()
        for p in c.workers:
            try:
                p.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                p.kill()

        # Verify each node's cluster.kv directly via `loop46 kv-get`.
        bin_loop46 = BIN_DIR / "loop46"
        for idx in range(3):
            rc = subprocess.run(
                [
                    str(bin_loop46), "kv-get",
                    "--data-dir", str(c.addrs.data_dirs[idx]),
                    "--store", "acme",
                    "--key", "_config/oauth/google",
                ],
                capture_output=True, text=True,
            )
            if rc.returncode != 0:
                sys.exit(f"FAIL node {idx} kv-get: {rc.stderr}")
            got = json.loads(rc.stdout)
            if got != expected:
                sys.exit(f"FAIL node {idx} cluster.kv: {got!r}")
            print(f"ok  node {idx} cluster.kv has matching _config/oauth/google row")

        if expected.get("marker") != "from-config-mirror-smoke":
            sys.exit(f"FAIL marker: {expected.get('marker')}")
        print(f"ok  marker field round-tripped: from-config-mirror-smoke")

        print()
        print("all config-mirror smoke checks passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
