#!/usr/bin/env python3
"""The retention purge against real S3: request-log batches (`_logs/`) and
spilled bodies (`_pool/`) older than the retention period are DELETED from
the store, younger ones are kept, and nothing happens with the purge off.

Both families lead their keys with time, and the purge decides by that
stamp, so planting objects whose keys say "a year and a day ago" is exactly
what a year-old object looks like to it.

    1. Start `rewind-logs` once (purge OFF) to learn the store prefix it
       resolved (storage namespace included), then stop it.
    2. Plant two year-old batches + one fresh batch under `_logs/{node}/`,
       and one year-old + one fresh object under `_pool/`. The fresh batch
       is what moves the indexer's (lagged) cursor past the old ones: the
       purge never deletes a batch above that cursor.
    3. Restart with the purge OFF: after indexing, every object is still
       there.
    4. Restart with `REWIND_LOG_PURGE=1`: the old objects are gone, the
       fresh ones are not, and the log reports what the pass did.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/smoke/log_purge_smoke_v2.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

DAY_NS = 86_400 * 10**9


def s3_curl(method: str, key: str, data: bytes | None = None) -> tuple[int, bytes]:
    url = f"{os.environ['S3_ENDPOINT'].rstrip('/')}/{os.environ['S3_BUCKET']}/{key}"
    cmd = ["curl", "-sS", "-X", method,
           "--aws-sigv4", f"aws:amz:{os.environ['S3_REGION']}:s3",
           "--user",
           f"{os.environ['AWS_ACCESS_KEY_ID']}:{os.environ['AWS_SECRET_ACCESS_KEY']}",
           "-o", "-", "-w", "\n%{http_code}", url]
    if data is not None:
        cmd += ["--data-binary", "@-"]
    r = subprocess.run(cmd, input=data or b"", capture_output=True)
    body, _, code = r.stdout.rpartition(b"\n")
    return int(code), body


def exists(key: str) -> bool:
    # A real HEAD (`-I`): `-X HEAD` would wait for a body a 404 announces
    # but never sends.
    url = f"{os.environ['S3_ENDPOINT'].rstrip('/')}/{os.environ['S3_BUCKET']}/{key}"
    r = subprocess.run(["curl", "-sS", "-I", "--max-time", "20",
                        "--aws-sigv4", f"aws:amz:{os.environ['S3_REGION']}:s3",
                        "--user", f"{os.environ['AWS_ACCESS_KEY_ID']}:{os.environ['AWS_SECRET_ACCESS_KEY']}",
                        "-o", "/dev/null", "-w", "%{http_code}", url],
                       capture_output=True, text=True)
    return r.stdout.strip() == "200"


def stop(c: V2Cluster, p) -> None:
    p.terminate()
    p.wait(timeout=10)
    c.procs.remove(p)


def wait_for(pred, what: str, timeout_s: float = 15.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


def main() -> int:
    with V2Cluster.spawn("logpurge", nodes=1) as c:
        # 1. The log store's resolved prefix, straight from the binary.
        p = c.spawn_log_server(poll_interval_ms=100)
        log_path = c.log_paths["logsrv"]
        wait_for(lambda: "key_prefix='" in open(log_path).read(), "the batch-backend line")
        m = re.search(r"key_prefix='([^']*)'", open(log_path).read())
        assert m, "log-server did not report its key prefix"
        log_prefix = m.group(1)
        stop(c, p)
        # `_pool/` lives under the content prefix: S3_KEY_PREFIX_BASE plus
        # the same storage-namespace segment the log prefix carries.
        ns_segment = log_prefix[len(c.s3_prefix):]
        pool_prefix = c.s3_prefix + ns_segment
        print(f"log prefix {log_prefix!r}, pool prefix {pool_prefix!r}")

        # 2. Plant objects. The node segment is 8 hex digits; batch keys are
        #    `{flush_ns:020}-{first_req:020}.ndjson`, pool keys
        #    `{written_ms:0>13}-{digest}`.
        now_ns = time.time_ns()
        old1 = now_ns - 400 * DAY_NS
        old2 = now_ns - 366 * DAY_NS
        node = "_logs/0000beef/"
        logs_old = [f"{log_prefix}{node}{t:020d}-{i:020d}.ndjson" for i, t in ((1, old1), (2, old2))]
        logs_new = f"{log_prefix}{node}{now_ns:020d}-{3:020d}.ndjson"
        pool_old = f"{pool_prefix}_pool/{(now_ns - 370 * DAY_NS) // 10**6:013d}-00aa"
        pool_new = f"{pool_prefix}_pool/{now_ns // 10**6:013d}-00bb"
        for k in [*logs_old, logs_new, pool_old, pool_new]:
            code, body = s3_curl("PUT", k, b"x")
            assert code == 200, f"PUT {k}: {code} {body[:200]!r}"

        # 3. Purge OFF: indexing alone deletes nothing.
        os.environ.pop("REWIND_LOG_PURGE", None)
        p = c.spawn_log_server(poll_interval_ms=100)
        time.sleep(2.0)
        stop(c, p)
        for k in [*logs_old, logs_new, pool_old, pool_new]:
            assert exists(k), f"purge OFF but {k} is gone"
        print("purge off: every object kept")

        # 4. Purge ON.
        os.environ["REWIND_LOG_PURGE"] = "1"
        try:
            p = c.spawn_log_server(poll_interval_ms=100)
            wait_for(lambda: "log-purge:" in open(c.log_paths["logsrv"]).read(), "a purge pass")
            line = [ln for ln in open(c.log_paths["logsrv"]).read().splitlines() if "log-purge:" in ln][-1]
            print(line)
            stop(c, p)
        finally:
            os.environ.pop("REWIND_LOG_PURGE", None)
        for k in [*logs_old, pool_old]:
            assert not exists(k), f"purge ON but year-old {k} is still there"
        for k in [logs_new, pool_new]:
            assert exists(k), f"purge ON deleted fresh {k}"
        assert "deleted 2 batch(es), 1 pool object(s)" in line, line
        print("purge on: year-old batches and bodies deleted, fresh ones kept")

        for k in [logs_new, pool_new]:
            s3_curl("DELETE", k)
    print("OK — log purge")
    return 0


if __name__ == "__main__":
    sys.exit(main())
