#!/usr/bin/env python3
"""files-server own raft group smoke (production.md #1.4 step 1).

Python port of `scripts/files_server_raft_smoke.sh`. Stands up a 3-node
files-server-standalone cluster (independent from loop46 worker raft),
verifies leader election, propose-replicate-read via cluster-put / cluster-get,
manifest.bin GET + PUT, and POST /_system/manifests/batch binary protocol.
"""

from __future__ import annotations

import os
import socket
import sqlite3
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import (  # noqa: E402
    BIN_DIR, TlsBundle, _TRACKED_PROCS, _install_signal_handlers,
    _load_dotenv, _require_env, CurlContext, curl, gen_jwt_secret, mint_jwt,
)


def main() -> int:
    _load_dotenv()
    _require_env("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET", "S3_ENDPOINT", "S3_REGION")
    _install_signal_handlers()

    tls = TlsBundle.from_env()
    bin_path = BIN_DIR / "files-server-standalone"
    if not bin_path.exists():
        sys.exit(f"error: {bin_path} missing")

    http_base = 9090
    raft_base = 41090
    http_addrs = [f"127.0.0.1:{http_base + i}" for i in range(3)]
    raft_addrs = [f"127.0.0.1:{raft_base + i}" for i in range(3)]
    data_dirs = [Path(f"/tmp/rove-fs-raft-smoke-{i}") for i in range(3)]
    for d in data_dirs:
        if d.exists():
            import shutil
            shutil.rmtree(d)

    peers_csv = ",".join(raft_addrs)
    print(f"peers: {peers_csv}")

    os.environ.setdefault(
        "S3_KEY_PREFIX_BASE",
        f"smoke-fs-raft-{os.environ.get('HOSTNAME', 'host')}-{os.getuid()}/",
    )
    jwt_secret = gen_jwt_secret()
    os.environ["LOOP46_SERVICES_JWT_SECRET"] = jwt_secret

    workers = []
    for i in range(3):
        log_path = Path(f"/tmp/fs-raft-smoke-worker-{i}.out")
        args = [
            str(bin_path),
            "--data-dir", str(data_dirs[i]),
            "--listen", http_addrs[i],
            "--tls-cert", str(tls.cert),
            "--tls-key", str(tls.key),
            "--cors-origin", "https://app.rewindjscom.localhost",
            "--raft-node-id", str(i),
            "--raft-peers", peers_csv,
            "--raft-listen", raft_addrs[i],
            "--raft-election-timeout-ms", "200",
            "--raft-heartbeat-ms", "50",
        ]
        f = open(log_path, "wb")
        p = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT)
        workers.append(p)
        _TRACKED_PROCS.append(p)
    time.sleep(3)

    try:
        # 1. Verify processes alive + raft.log.db exists.
        for i in range(3):
            if workers[i].poll() is not None:
                sys.exit(f"FAIL node {i} exited; see /tmp/fs-raft-smoke-worker-{i}.out")
            if not (data_dirs[i] / "raft.log.db").exists():
                sys.exit(f"FAIL node {i} has no raft.log.db")
        print("ok  3 files-server-standalone processes alive + raft.log.db files exist")

        # 2. Verify raft.log.db pragmas.
        for i in range(3):
            db = data_dirs[i] / "raft.log.db"
            conn = sqlite3.connect(str(db))
            try:
                av = conn.execute("PRAGMA auto_vacuum").fetchone()[0]
                jm = conn.execute("PRAGMA journal_mode").fetchone()[0]
            finally:
                conn.close()
            if av != 2:
                sys.exit(f"FAIL node {i} auto_vacuum={av}")
            if jm.lower() != "wal":
                sys.exit(f"FAIL node {i} journal_mode={jm}")
        print("ok  3 raft.log.db files in WAL + INCREMENTAL auto_vacuum")

        # 3. Verify raft TCP listeners are open.
        for i in range(3):
            host, port = raft_addrs[i].split(":")
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(2.0)
                try:
                    s.connect((host, int(port)))
                except OSError as e:
                    sys.exit(f"FAIL node {i} raft listener at {raft_addrs[i]}: {e}")
        print("ok  3 raft TCP listeners accepting connections")

        # Mint JWT.
        jwt = mint_jwt(jwt_secret, {"exp": int(time.time() * 1000) + 5 * 60 * 1000})

        cc = CurlContext(cacert=tls.cacert)

        # 4. Leader election.
        leader_idx = None
        leader_count = 0
        for tries in range(30):
            leader_count = 0
            follower_count = 0
            tmp_leader = None
            for i in range(3):
                port = int(http_addrs[i].rsplit(":", 1)[1])
                r = curl(
                    cc, f"https://127.0.0.1:{port}/_system/leader",
                    headers={"Authorization": f"Bearer {jwt}"},
                    timeout=2.0,
                )
                if r.status == 200:
                    tmp_leader = i
                    leader_count += 1
                elif r.status == 503:
                    follower_count += 1
            if leader_count == 1 and follower_count == 2:
                leader_idx = tmp_leader
                break
            time.sleep(0.3)
        if leader_idx is None:
            sys.exit(f"FAIL leader election: leaders={leader_count}")
        print(f"ok  raft elected node {leader_idx} as leader")

        leader_port = int(http_addrs[leader_idx].rsplit(":", 1)[1])

        # 5. cluster-put + cluster-get replication.
        import time as _t
        test_key = f"hello-{int(_t.time_ns())}"
        test_value = f"raft-replicated-{socket.gethostname()}"
        put_body = f'{{"store":"acme","key":"{test_key}","value":"{test_value}"}}'
        r = curl(
            cc, f"https://127.0.0.1:{leader_port}/_system/cluster-put",
            method="POST",
            headers={
                "Authorization": f"Bearer {jwt}",
                "Content-Type": "application/json",
            },
            data=put_body, timeout=10.0,
        )
        if "committed at seq=" not in r.body:
            sys.exit(f"FAIL cluster-put: {r.body}")
        print(f"ok  leader: {r.body.strip()}")

        for try_ in range(20):
            all_match = True
            for i in range(3):
                port = int(http_addrs[i].rsplit(":", 1)[1])
                r = curl(
                    cc, f"https://127.0.0.1:{port}/_system/cluster-get/acme/{test_key}",
                    headers={"Authorization": f"Bearer {jwt}"},
                    timeout=2.0,
                )
                if r.body != test_value:
                    all_match = False
                    break
            if all_match:
                break
            time.sleep(0.2)
        if not all_match:
            sys.exit("FAIL not all nodes replicated key")
        print(f"ok  all 3 nodes replicated {test_key}")

        # 6. Followers reject writes.
        for i in range(3):
            if i == leader_idx:
                continue
            port = int(http_addrs[i].rsplit(":", 1)[1])
            r = curl(
                cc, f"https://127.0.0.1:{port}/_system/cluster-put",
                method="POST",
                headers={
                    "Authorization": f"Bearer {jwt}",
                    "Content-Type": "application/json",
                },
                data=put_body, timeout=2.0,
            )
            if r.status != 503:
                sys.exit(f"FAIL follower {i} accepted cluster-put: {r.status}")
        print("ok  followers reject /_system/cluster-put with 503")

        # 7. Manifest fetch via /v1/{tenant}/deployments/{N:hex}/manifest.bin.
        manifest_tenant = f"manifest-test-{int(_t.time())}"
        manifest_dep_id = 42
        manifest_key = f"deployment/{manifest_dep_id:020x}/manifest"
        manifest_body = f"manifest-body-bytes-{int(_t.time_ns())}"
        put_body = f'{{"store":"{manifest_tenant}","key":"{manifest_key}","value":"{manifest_body}"}}'
        r = curl(
            cc, f"https://127.0.0.1:{leader_port}/_system/cluster-put",
            method="POST",
            headers={
                "Authorization": f"Bearer {jwt}",
                "Content-Type": "application/json",
            },
            data=put_body, timeout=10.0,
        )
        if "committed at seq=" not in r.body:
            sys.exit(f"FAIL manifest cluster-put: {r.body}")

        manifest_hex = f"{manifest_dep_id:x}"
        for try_ in range(20):
            all_match = True
            for i in range(3):
                port = int(http_addrs[i].rsplit(":", 1)[1])
                r = curl(
                    cc, f"https://127.0.0.1:{port}/{manifest_tenant}/deployments/{manifest_hex}/manifest.bin",
                    headers={"Authorization": f"Bearer {jwt}"},
                    timeout=2.0,
                )
                if r.body != manifest_body:
                    all_match = False
                    break
            if all_match:
                break
            time.sleep(0.2)
        if not all_match:
            sys.exit("FAIL not all nodes serve manifest.bin")
        print("ok  all 3 nodes serve raft-replicated manifest via manifest.bin")

        # 404 sanity.
        r = curl(
            cc, f"https://127.0.0.1:{leader_port}/{manifest_tenant}/deployments/deadbeef/manifest.bin",
            headers={"Authorization": f"Bearer {jwt}"},
            timeout=2.0,
        )
        if r.status != 404:
            sys.exit(f"FAIL missing-deployment 404: got {r.status}")
        print("ok  manifest.bin 404s on unknown deployment id")

        # 8. PUT manifest.bin (real-shaped).
        put_tenant = f"put-manifest-test-{int(_t.time())}"
        put_dep_id = 7
        put_hex = f"{put_dep_id:x}"
        put_body_str = '{"version":1,"entries":[{"path":"hello.js","kind":"handler","content_type":"application/javascript","hash":"abc123"}]}'
        r = curl(
            cc, f"https://127.0.0.1:{leader_port}/{put_tenant}/deployments/{put_hex}/manifest.bin",
            method="PUT",
            headers={
                "Authorization": f"Bearer {jwt}",
                "Content-Type": "application/octet-stream",
            },
            data=put_body_str, timeout=10.0,
        )
        if "committed at seq=" not in r.body:
            sys.exit(f"FAIL PUT manifest.bin: {r.body}")
        print(f"ok  PUT manifest.bin: {r.body.strip()}")

        for try_ in range(20):
            all_match = True
            for i in range(3):
                port = int(http_addrs[i].rsplit(":", 1)[1])
                r = curl(
                    cc, f"https://127.0.0.1:{port}/{put_tenant}/deployments/{put_hex}/manifest.bin",
                    headers={"Authorization": f"Bearer {jwt}"},
                    timeout=2.0,
                )
                if r.body != put_body_str:
                    all_match = False
                    break
            if all_match:
                break
            time.sleep(0.2)
        if not all_match:
            sys.exit("FAIL PUT manifest didn't replicate")
        print("ok  PUT-then-GET manifest round-trips byte-for-byte")

        for i in range(3):
            if i == leader_idx:
                continue
            port = int(http_addrs[i].rsplit(":", 1)[1])
            r = curl(
                cc, f"https://127.0.0.1:{port}/{put_tenant}/deployments/{put_hex}/manifest.bin",
                method="PUT",
                headers={"Authorization": f"Bearer {jwt}"},
                data=put_body_str, timeout=2.0,
            )
            if r.status != 503:
                sys.exit(f"FAIL follower {i} accepted PUT: {r.status}")
        print("ok  followers reject PUT manifest.bin with 503")

        # 9. POST /_system/manifests/batch.
        print("batch manifest fetch test:")
        tenants = [
            (manifest_tenant, manifest_dep_id, True),
            (put_tenant, put_dep_id, True),
            ("nonexistent-tenant", 99, False),
        ]
        batch_req = struct.pack("<I", len(tenants))
        for tid, dep_id, _ in tenants:
            batch_req += struct.pack("<H", len(tid))
            batch_req += tid.encode()
            batch_req += struct.pack("<Q", dep_id)
        # The curl helper takes data; for binary data, write to temp file.
        batch_req_path = Path("/tmp/fs-raft-batch-req.bin")
        batch_req_path.write_bytes(batch_req)
        r = subprocess.run(
            ["curl", "-sS", "--cacert", str(tls.cacert), "--max-time", "10",
             "-X", "POST",
             "-H", f"Authorization: Bearer {jwt}",
             "-H", "Content-Type: application/octet-stream",
             "--data-binary", f"@{batch_req_path}",
             "-o", "/tmp/fs-raft-batch-resp.bin",
             "-w", "%{http_code}",
             f"https://127.0.0.1:{leader_port}/_system/manifests/batch"],
            capture_output=True, timeout=15.0,
        )
        code = r.stdout.decode().strip()
        if code != "200":
            sys.exit(f"FAIL batch endpoint returned {code}")
        data = Path("/tmp/fs-raft-batch-resp.bin").read_bytes()
        pos = 0
        (count,) = struct.unpack_from("<I", data, pos); pos += 4
        if count != 3:
            sys.exit(f"FAIL expected 3 entries, got {count}")
        expected = {
            manifest_tenant: manifest_body,
            put_tenant: put_body_str,
            "nonexistent-tenant": None,
        }
        seen = {}
        for _ in range(count):
            (id_len,) = struct.unpack_from("<H", data, pos); pos += 2
            tid = data[pos:pos + id_len].decode(); pos += id_len
            (mf_len,) = struct.unpack_from("<I", data, pos); pos += 4
            if mf_len == 0:
                seen[tid] = None
            else:
                seen[tid] = data[pos:pos + mf_len].decode(); pos += mf_len
        for tid, want in expected.items():
            got = seen.get(tid, "MISSING")
            if want is None and got is not None:
                sys.exit(f"FAIL {tid} expected absent, got {got!r}")
            if want is not None and got != want:
                sys.exit(f"FAIL {tid} expected {want!r}, got {got!r}")
        print(f"  parsed {count} entries; 2 manifests + 1 absent verified")
        batch_req_path.unlink()
        Path("/tmp/fs-raft-batch-resp.bin").unlink()
        print("ok  POST /_system/manifests/batch returns binary-packed manifests")

        print()
        print("PASS files-server raft smoke")
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
