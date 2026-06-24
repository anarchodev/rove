#!/usr/bin/env python3
"""End-to-end logs round-trip against real S3 — exercises the indexer's
per-node start-after cursor + the split reader connection with REAL batches.

Unlike `logs_door_smoke_v2.py` (which reads an empty index to prove the
door/auth), this generates actual request-log records and reads them back:

    traffic → worker flushes batch to S3 → log-server POLLS S3 (no push
    wiring in this harness) → `listNodePrefixes` + per-node cursor index
    it → `/v1/{t}/list` + `/show` serve it through the READER connection.

A non-empty `/list` here means the poll cursor found the node prefix and
walked it; a 200 `/show` means the stored (ndjson_key, offset, length)
pointer round-tripped through a range-GET + raw-deflate decode.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/logs_roundtrip_smoke_v2.py
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

READY_SRC = 'export function handler() { return "ready"; }\n'
FIXTURE = {"index.mjs": rpc_wrap(READY_SRC)}

N_REQUESTS = 8


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== logs round-trip (poll cursor + reader connection, real S3) ===")
    with V2Cluster.spawn("logsrt", nodes=1, http_base=19800,
                         raft_base=19900) as c:
        # 200ms poll → indexing here is the POLL path (no worker push wiring).
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision("globex")
        check("provision globex → 204/409", r.status in (204, 409),
              f"got {r.status} {r.body!r}")
        c.deploy_handlers("globex", FIXTURE)
        c.wait_for_handler("globex", "/?fn=handler", want_body="ready", timeout_s=30.0)

        # Generate N logged activations.
        ok_n = 0
        for i in range(N_REQUESTS):
            rr = c.request("globex", f"/?fn=handler&i={i}", timeout=30.0)
            if rr.status == 200 and rr.body == "ready":
                ok_n += 1
        check(f"generated {N_REQUESTS} globex requests", ok_n == N_REQUESTS,
              f"{ok_n}/{N_REQUESTS} returned 200 'ready'")

        # Wait for the worker's 1s flush + a few poll intervals, with retries
        # to absorb S3 LIST read-after-write lag. The POLL cursor must pick up
        # globex's `_logs/{node}/` prefix and index the batch.
        records = []
        deadline = time.time() + 30.0
        last_body = ""
        while time.time() < deadline:
            resp = c.log_get("globex/list?limit=50", timeout=15.0)
            last_body = resp.body
            if resp.status == 200:
                try:
                    records = json.loads(resp.body).get("records", [])
                except json.JSONDecodeError:
                    records = []
                if records:
                    break
            time.sleep(1.0)

        check("poll cursor indexed globex logs (/list non-empty)",
              len(records) > 0,
              f"got {len(records)} records; last body={last_body[:200]!r}")

        # /count should agree that there is at least one record.
        cnt_resp = c.log_get("globex/count", timeout=15.0)
        cnt_ok = False
        cnt_val = None
        if cnt_resp.status == 200:
            try:
                parsed = json.loads(cnt_resp.body)
                # `/count` returns a bare integer (e.g. `10`); tolerate a
                # `{"count": N}` shape too in case that ever changes.
                cnt_val = parsed if isinstance(parsed, int) else parsed.get("count")
                cnt_ok = isinstance(cnt_val, int) and cnt_val >= 1
            except (json.JSONDecodeError, AttributeError):
                pass
        check("count >= 1", cnt_ok, f"status={cnt_resp.status} count={cnt_val}")

        # /show the first record by its opaque req_ id — proves the stored
        # (ndjson_key, offset, length) pointer + range-GET + deflate decode.
        if records:
            rid = records[0].get("request_id")
            show_resp = c.log_get(f"globex/show/{rid}", timeout=15.0)
            show_ok = show_resp.status == 200 and '"record"' in show_resp.body
            check("show first record → 200 with payload", show_ok,
                  f"id={rid} status={show_resp.status} body={show_resp.body[:160]!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {len(records)} globex records indexed via the poll cursor "
          "and served through the reader connection (list + count + show).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
