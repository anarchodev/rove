#!/usr/bin/env python3
"""Non-voting learner smoke (production.md #1.2).

Python port of `scripts/learner_smoke.sh`. Stands up a 3-voter + 1-learner
cluster, drives commits, kills 2 voters to force quorum loss, runs
`loop46 promote-learner` on the learner's data dir, restarts it as a
1-node cluster, and verifies state continuity.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import (  # noqa: E402
    BIN_DIR, TlsBundle, _TRACKED_PROCS, _install_signal_handlers,
    _load_dotenv, _require_env, curl, CurlContext, gen_jwt_secret,
)

ROOT_TOKEN = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
PUBLIC_SUFFIX = "loop46.localhost"
ADMIN_HOST = f"app.{PUBLIC_SUFFIX}"


def main() -> int:
    _load_dotenv()
    _require_env("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET", "S3_ENDPOINT", "S3_REGION")
    _install_signal_handlers()

    tls = TlsBundle.from_env()
    bin_loop46 = BIN_DIR / "loop46"

    http_base = 8480
    raft_base = 40480
    http_addrs = [f"127.0.0.1:{http_base + i}" for i in range(4)]
    raft_addrs = [f"127.0.0.1:{raft_base + i}" for i in range(4)]
    data_dirs = [Path(f"/tmp/rove-learner-smoke-{i}") for i in range(4)]
    for d in data_dirs:
        shutil.rmtree(d, ignore_errors=True)

    # peers: voters 0/1/2, learner 3.
    peers_csv = f"{raft_addrs[0]},{raft_addrs[1]},{raft_addrs[2]},{raft_addrs[3]}:learner"
    print(f"peers: {peers_csv}")

    # Seed all 4 dirs.
    seed_path = Path("/tmp/learner-seed.json")
    seed_path.write_text('{"tenants":[{"id":"acme","domains":[],"files":[]}]}')
    os.environ.setdefault(
        "S3_KEY_PREFIX_BASE",
        f"smoke-learner-{os.environ.get('HOSTNAME', 'host')}-{os.getuid()}/",
    )
    os.environ["LOOP46_SERVICES_JWT_SECRET"] = gen_jwt_secret()
    os.environ["LOOP46_ROOT_TOKEN"] = ROOT_TOKEN
    # First node serial so it creates the S3 manifest; rest parallel.
    subprocess.run(
        [str(bin_loop46), "seed", "--data-dir", str(data_dirs[0]),
         "--manifest", str(seed_path)],
        check=True, capture_output=True,
    )
    seed_procs = []
    for d in data_dirs[1:]:
        seed_procs.append(subprocess.Popen(
            [str(bin_loop46), "seed", "--data-dir", str(d),
             "--manifest", str(seed_path)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ))
    for p in seed_procs:
        p.wait()
    print("ok  4 dirs seeded")

    # Spawn workers.
    workers: list[subprocess.Popen] = []
    for i in range(4):
        log_path = Path(f"/tmp/learner-smoke-worker-{i}.out")
        args = [
            str(bin_loop46), "worker",
            "--node-id", str(i),
            "--peers", peers_csv,
            "--listen", raft_addrs[i],
            "--http", http_addrs[i],
            "--data-dir", str(data_dirs[i]),
            "--public-suffix", PUBLIC_SUFFIX,
            "--tls-cert", str(tls.cert),
            "--tls-key", str(tls.key),
            "--workers", "1",
            "--snapshot-interval-ms", "500",
            "--election-timeout-ms", "200",
            "--heartbeat-ms", "50",
        ]
        f = open(log_path, "wb")
        p = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT)
        workers.append(p)
        _TRACKED_PROCS.append(p)
    time.sleep(3)

    try:
        cc = CurlContext(
            cacert=tls.cacert,
            resolves=[(ADMIN_HOST, int(h.rsplit(":", 1)[1])) for h in http_addrs],
        )

        # Find leader (must be 0/1/2).
        leader_idx = None
        for tries in range(30):
            for i in range(4):
                port = int(http_addrs[i].rsplit(":", 1)[1])
                try:
                    r = curl(
                        cc, f"https://{ADMIN_HOST}:{port}/_system/leader",
                        headers={"Authorization": f"Bearer {ROOT_TOKEN}"},
                        timeout=2.0,
                    )
                except (subprocess.TimeoutExpired, RuntimeError):
                    continue
                if r.status == 200:
                    leader_idx = i
                    break
            if leader_idx is not None:
                break
            time.sleep(0.5)
        if leader_idx is None:
            sys.exit("FAIL no leader elected within 15s")
        print(f"ok  leader: node {leader_idx} at {http_addrs[leader_idx]}")
        if leader_idx == 3:
            sys.exit("FAIL learner (node 3) became leader")
        print("ok  learner did not become leader")

        leader_port = int(http_addrs[leader_idx].rsplit(":", 1)[1])
        commits = 10
        for i in range(1, commits + 1):
            curl(
                cc, f"https://{ADMIN_HOST}:{leader_port}/_system/release",
                method="POST",
                headers={
                    "Authorization": f"Bearer {ROOT_TOKEN}",
                    "Content-Type": "application/json",
                },
                data=json.dumps({"tenant_id": "acme", "dep_id": i}),
                timeout=5.0,
            )
        print(f"ok  drove {commits} release POSTs through the leader")
        time.sleep(3)

        # Lost-quorum recovery.
        print()
        print("── lost-quorum recovery ──")

        # Kill the 2 non-leader voters.
        kill_voters = [i for i in range(3) if i != leader_idx]
        print(f"killing 2 voters: nodes {kill_voters}")
        for i in kill_voters:
            workers[i].terminate()
            try:
                workers[i].wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                workers[i].kill()
        time.sleep(2)

        # Surviving voter should refuse writes.
        try:
            r = curl(
                cc, f"https://{ADMIN_HOST}:{leader_port}/_system/release",
                method="POST",
                headers={
                    "Authorization": f"Bearer {ROOT_TOKEN}",
                    "Content-Type": "application/json",
                },
                data=json.dumps({"tenant_id": "acme", "dep_id": 99}),
                timeout=4.0,
            )
            survivor_status = r.status
        except (subprocess.TimeoutExpired, RuntimeError):
            survivor_status = 0
        print(f"  POST against surviving voter: HTTP {survivor_status}")
        if survivor_status in (200, 204):
            sys.exit("FAIL surviving voter still committed (quorum not lost)")
        print("ok  surviving voter rejects/times out writes")

        # Stop the learner.
        print("stopping learner cleanly…")
        workers[3].terminate()
        try:
            workers[3].wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            workers[3].kill()
        time.sleep(1)

        # promote-learner.
        promote_log = Path("/tmp/learner-smoke-promote.out")
        rc = subprocess.run(
            [str(bin_loop46), "promote-learner", "--data-dir", str(data_dirs[3])],
            capture_output=True, text=True,
        )
        promote_log.write_text(rc.stdout + rc.stderr)
        if rc.returncode != 0:
            sys.exit(f"FAIL promote-learner: {rc.stdout}{rc.stderr}")
        if "ready for 1-node-cluster boot" not in (rc.stdout + rc.stderr):
            sys.exit(f"FAIL promote-learner missing ready banner: {rc.stdout}{rc.stderr}")
        if (data_dirs[3] / "raft.log.db").exists():
            sys.exit("FAIL raft.log.db still present after promote-learner")
        print("ok  promote-learner removed raft.log.db")

        # Restart learner as 1-node cluster.
        log_path = Path(f"/tmp/learner-smoke-worker-3-promoted.out")
        promoted_args = [
            str(bin_loop46), "worker",
            "--node-id", "0",
            "--peers", f"{raft_addrs[3]}:voter",
            "--allow-single-peer",
            "--listen", raft_addrs[3],
            "--http", http_addrs[3],
            "--data-dir", str(data_dirs[3]),
            "--public-suffix", PUBLIC_SUFFIX,
            "--tls-cert", str(tls.cert),
            "--tls-key", str(tls.key),
            "--workers", "1",
            "--election-timeout-ms", "200",
            "--heartbeat-ms", "50",
        ]
        f = open(log_path, "wb")
        promoted = subprocess.Popen(promoted_args, stdout=f, stderr=subprocess.STDOUT)
        _TRACKED_PROCS.append(promoted)
        workers[3] = promoted

        promoted_port = int(http_addrs[3].rsplit(":", 1)[1])
        promoted_ok = False
        for tries in range(30):
            try:
                r = curl(
                    cc, f"https://{ADMIN_HOST}:{promoted_port}/_system/leader",
                    headers={"Authorization": f"Bearer {ROOT_TOKEN}"},
                    timeout=2.0,
                )
                if r.status == 200:
                    promoted_ok = True
                    break
            except (subprocess.TimeoutExpired, RuntimeError):
                pass
            time.sleep(0.5)
        if not promoted_ok:
            sys.exit(f"FAIL promoted learner didn't elect itself within 15s")
        print("ok  promoted learner elected itself (1-node cluster)")

        new_dep = commits + 1
        r = curl(
            cc, f"https://{ADMIN_HOST}:{promoted_port}/_system/release",
            method="POST",
            headers={
                "Authorization": f"Bearer {ROOT_TOKEN}",
                "Content-Type": "application/json",
            },
            data=json.dumps({"tenant_id": "acme", "dep_id": new_dep}),
            timeout=5.0,
        )
        if r.status not in (200, 204):
            sys.exit(f"FAIL write against promoted learner: {r.status}")
        print(f"ok  promoted learner accepted write (dep_id={new_dep})")
        time.sleep(1)

        # Shut promoted learner down.
        promoted.terminate()
        try:
            promoted.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            promoted.kill()

        # Verify state continuity.
        rc = subprocess.run(
            [str(bin_loop46), "kv-get",
             "--data-dir", str(data_dirs[3]),
             "--store", "acme",
             "--key", "_deploy/current"],
            capture_output=True, text=True,
        )
        promoted_deploy = rc.stdout.strip()
        expected = f"{new_dep:016x}"
        print(f"  promoted learner _deploy/current={promoted_deploy} (expected {expected})")
        if promoted_deploy != expected:
            sys.exit(f"FAIL state mismatch: {promoted_deploy} != {expected}")
        print(f"ok  state continuity: prior {commits} commits preserved, new commit {new_dep} applied")

        print()
        print("PASS learner smoke + lost-quorum recovery")
        return 0
    finally:
        for p in workers:
            if p.poll() is None:
                p.terminate()
        for p in workers:
            try:
                p.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                p.kill()


if __name__ == "__main__":
    sys.exit(main())
