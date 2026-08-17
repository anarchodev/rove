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
    python3 scripts/smoke/logs_roundtrip_smoke_v2.py
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
    with V2Cluster.spawn("logsrt", nodes=1) as c:
        # 200ms poll → indexing here is the POLL path (no worker push wiring).
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision("globex")
        check("provision globex → 200/409", r.status in (200, 409),
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
                # Hold out for the executed requests, not just the first
                # indexed record (an early 503 probe can land in an
                # earlier batch) — the stamp assertions below need them.
                if sum(1 for r in records if r.get("status") == 200) >= N_REQUESTS:
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
            # The record JSON carries the execution-sequence stamp as a
            # decimal string (never a bare number — stamps exceed 2^53).
            if show_ok:
                rec = json.loads(show_resp.body).get("record", {})
                seq_str = rec.get("exec_seq")
                check("show record carries a string exec_seq",
                      isinstance(seq_str, str) and seq_str.isdigit(),
                      f"exec_seq={seq_str!r}")

        # Every EXECUTED activation is stamped: nonzero, distinct exec_seq
        # on each 200 row (the stamp is the tenant's tape position). A
        # pre-dispatch reject (an early probe 503ing before the deploy
        # landed) is legitimately unstamped — it never entered execution
        # and has no place on the tape.
        executed = [r for r in records if r.get("status") == 200]
        seqs = [int(r.get("exec_seq", "0")) for r in executed]
        check("every executed (200) record carries a nonzero exec_seq",
              bool(seqs) and all(s > 0 for s in seqs),
              f"seqs={seqs}")
        check("exec_seq values are distinct", len(set(seqs)) == len(seqs),
              f"seqs={seqs}")

        # The tape view: /window walks exactly the STAMPED records,
        # ASCENDING by stamp; unstamped rows never appear on the tape.
        stamped = sorted(int(r.get("exec_seq", "0")) for r in records
                         if int(r.get("exec_seq", "0")) > 0)
        win_resp = c.log_get("globex/window?limit=50", timeout=15.0)
        win_rows = []
        if win_resp.status == 200:
            try:
                win_rows = json.loads(win_resp.body).get("records", [])
            except json.JSONDecodeError:
                pass
        win_seqs = [int(r.get("exec_seq", "0")) for r in win_rows]
        check("window returns the stamped records in ascending tape order",
              win_seqs == stamped,
              f"status={win_resp.status} win={win_seqs} want={stamped}")
        if win_seqs:
            after = win_seqs[0]
            page2 = c.log_get(f"globex/window?after_seq={after}&limit=50",
                              timeout=15.0)
            p2_rows = []
            if page2.status == 200:
                try:
                    p2_rows = json.loads(page2.body).get("records", [])
                except json.JSONDecodeError:
                    pass
            p2_seqs = [int(r.get("exec_seq", "0")) for r in p2_rows]
            check("window keyset cursor resumes strictly after the stamp",
                  p2_seqs == win_seqs[1:],
                  f"page2={p2_seqs} want={win_seqs[1:]}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {len(records)} globex records indexed via the poll cursor "
          "and served through the reader connection (list + count + show).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
