#!/usr/bin/env python3
"""Phase 5.5(a) end-to-end smoke against real S3.

Python port of `scripts/log_backend_s3_smoke.sh`. Workers write log batches
to S3; standalone log-server's indexer polls + serves /v1/{tenant}/list +
/show. Validates the full worker → S3 → indexer → query round-trip.
"""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import BIN_DIR, Cluster, curl, mint_jwt  # noqa: E402

TOKEN = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
PUBLIC_SUFFIX = "loop46.localhost"
ADMIN_HOST = f"app.{PUBLIC_SUFFIX}"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent

    # Unique S3 prefix per run.
    rand = secrets.token_hex(4)
    smoke_prefix = f"smoke/{int(time.time() * 1000)}-{rand}/"
    os.environ["LOG_S3_KEY_PREFIX"] = smoke_prefix
    os.environ["BLOB_BACKEND"] = "s3"
    os.environ["S3_KEY_PREFIX_BASE"] = smoke_prefix

    index_db = Path(f"/tmp/rove-logbackend-index-{rand}.db")
    for suffix in ("", "-shm", "-wal"):
        Path(f"{index_db}{suffix}").unlink(missing_ok=True)

    cluster = Cluster.spawn(
        tag="lbs-smoke",
        http_base=8255,
        raft_base=40355,
        files_port=8257,
        log_port=0,  # will be picked up after log-server binds
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        admin_origin_per_node=True,
        admin_api_domain=ADMIN_HOST,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )

    # Manually spawn log-server pointing at our log_port=0 (auto-bind).
    bin_ls = BIN_DIR / "log-server-standalone"
    ls_log = Path("/tmp/lbs-server.out")
    ls_log.write_text("")
    ls_proc = subprocess.Popen(
        [str(bin_ls),
         "--data-dir", str(cluster.addrs.data_dirs[0]),
         "--index-db", str(index_db),
         "--listen", "127.0.0.1:0",
         "--poll-interval-ms", "500"],
        stdout=open(ls_log, "wb"), stderr=subprocess.STDOUT,
    )
    cluster.log_server = ls_proc
    from smoke_lib import _TRACKED_PROCS
    _TRACKED_PROCS.append(ls_proc)

    try:
        with cluster as c:
            # Wait for log-server to bind.
            ls_port = 0
            for _ in range(50):
                content = ls_log.read_text(errors="replace")
                if "listening on" in content and "(port " in content:
                    import re
                    m = re.search(r"port (\d+)", content)
                    if m:
                        ls_port = int(m.group(1))
                        break
                time.sleep(0.1)
            if not ls_port:
                sys.exit("FAIL log-server didn't bind")

            # The workers were already spawned WITHOUT a log-public-base
            # since we passed with_log_files_bases=False and log_port=0
            # at Cluster.spawn time. The workers must use S3 for log
            # batching — verify from the log.
            saw_s3 = False
            for _ in range(50):
                worker_log = Path("/tmp/lbs-smoke-worker-0.out")
                if worker_log.exists() and "log backend: s3" in worker_log.read_text(errors="replace"):
                    saw_s3 = True
                    break
                time.sleep(0.1)
            if not saw_s3:
                sys.exit("FAIL worker didn't report 's3' backend")
            print(f"ok  workers started with S3 backend → prefix={smoke_prefix}")

            c.discover_leader()
            print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

            cc = c.curl_ctx(ACME_HOST)
            acme_origin = f"https://{ACME_HOST}:{c.leader_port()}"

            # Wait for acme to be loaded.
            c.wait_for_handler("acme", "/api?fn=handler", expected_status=200, timeout_s=20.0)
            for n in range(1, 4):
                r = curl(cc, f"{acme_origin}/api?fn=handler")
                if r.status != 200:
                    sys.exit(f"FAIL request {n}: {r.status}")
            print("ok  drove 3 acme requests, all 200")

            jwt = mint_jwt(
                c.services_jwt_secret,
                {"exp": int(time.time() * 1000) + 5 * 60 * 1000},
            )

            # Wait for 3 /api records to surface via indexer.
            from smoke_lib import CurlContext
            ls_cc = CurlContext(cacert=Path("/dev/null"))

            def ls_call(url: str) -> str:
                args = ["curl", "-sS", "--http2-prior-knowledge", "--max-time", "10",
                        "-H", f"Authorization: Bearer {jwt}", url]
                return subprocess.run(args, capture_output=True, timeout=15.0).stdout.decode()

            api_records = []
            list_body = ""
            for _ in range(60):
                list_body = ls_call(f"http://127.0.0.1:{ls_port}/v1/acme/list?limit=100")
                try:
                    d = json.loads(list_body)
                    api_records = [r for r in d.get("records", []) if r.get("path", "").startswith("/api")]
                except (json.JSONDecodeError, AttributeError):
                    api_records = []
                if len(api_records) >= 3:
                    break
                time.sleep(0.5)
            if len(api_records) < 3:
                sys.exit(f"FAIL want >=3 /api records, got {len(api_records)}: {list_body[:500]}")
            for r in api_records[:3]:
                if r["method"] != "GET":
                    sys.exit(f"FAIL method: {r}")
                if r["host"] != ACME_HOST:
                    sys.exit(f"FAIL host: {r}")
                if r["status"] != 200:
                    sys.exit(f"FAIL status: {r}")
                if r["outcome"] != "ok":
                    sys.exit(f"FAIL outcome: {r}")
            print("ok  worker → S3 → indexer → /list shows all 3 acme records")

            count_body = ls_call(f"http://127.0.0.1:{ls_port}/v1/acme/count").strip()
            try:
                count = int(count_body)
            except ValueError:
                sys.exit(f"FAIL count: {count_body!r}")
            if count < 3:
                sys.exit(f"FAIL count: expected >=3, got {count}")
            print(f"ok  count: GET /v1/acme/count → {count} (>=3)")

            # /show round-trip.
            first_id = api_records[0]["request_id"]
            show_body = ls_call(f"http://127.0.0.1:{ls_port}/v1/acme/show/{first_id}")
            show = json.loads(show_body)["record"]
            for field, want in [("status", 200), ("method", "GET")]:
                if show.get(field) != want:
                    sys.exit(f"FAIL show {field}: {show}")
            if not show["path"].startswith("/api"):
                sys.exit(f"FAIL show path: {show}")
            print("ok  show: S3 range-read returned the worker-emitted record")

            tapes = show.get("tapes") or {}
            tape_payload = None
            for k in ("kv_tape_b64", "date_tape_b64", "request_body_b64"):
                if tapes.get(k):
                    tape_payload = k
                    break
            if not tape_payload:
                sys.exit("FAIL no inline tape payload")
            print(f"ok  show record carries inline tape payload ({tape_payload})")

            print()
            print("all log-backend=s3 smoke checks passed")
            print(f"(left ~10 objects under s3://{os.environ.get('S3_BUCKET')}/{smoke_prefix})")
            return 0
    finally:
        for suffix in ("", "-shm", "-wal"):
            Path(f"{index_db}{suffix}").unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())
