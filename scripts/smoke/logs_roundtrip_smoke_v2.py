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

READY_SRC = (
    # `schedule` is the `@rewind/schedule` package, not an ambient global.
    'import schedule from "@rewind/schedule";\n'
    'export function handler() { return "ready"; }\n'
    # Arms a durable wake targeting the second module's named export.
    # The fired activation ROOTS ITS OWN saga (the durability boundary);
    # the arming saga rides its record as the reserved `_parent` tag.
    'export function arm() {\n'
    '  schedule({ in: 1000 }, "wakes.mjs.fired", { note: "hi" }, { key: "smoke-parent" });\n'
    '  return "armed";\n'
    '}\n'
    # kv-touching probe for the seam assertions: ?w= writes a key,
    # ?r= reads one — the ops land on the record's kv tape / write-key
    # list, which is what /seam intersects.
    'export function touch() {\n'
    '  const q = new URLSearchParams(request.query || "");\n'
    '  const w = q.get("w"); if (w) kv.set(w, "1");\n'
    '  const r = q.get("r"); kv.get(r || "never/set");\n'
    '  return "touched";\n'
    '}\n'
)
WAKES_SRC = 'export function fired() { return "fired"; }\n'
FIXTURE = {"index.mjs": rpc_wrap(READY_SRC), "wakes.mjs": WAKES_SRC}

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
        # `@rewind/schedule` rides as a first-party package (the saga
        # provenance section arms a durable wake through it).
        pkgs, imports = c.firstparty_packages(["@rewind/schedule"])
        c.deploy_with_packages("globex", FIXTURE, pkgs, imports)
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

        # The tape view: /window walks stamped records ASCENDING by stamp;
        # unstamped rows never appear. Set-INCLUSION against the /list
        # snapshot, not equality — the two calls are separate reads of a
        # continuously-indexing store, so a batch (e.g. the probe's) can
        # land between them and legitimately appear only in the window.
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
        check("window is strictly ascending, nonzero, and covers the listed stamps",
              all(s > 0 for s in win_seqs)
              and win_seqs == sorted(set(win_seqs))
              and set(stamped) <= set(win_seqs),
              f"status={win_resp.status} win={win_seqs} listed={stamped}")
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

        # ── The saga window: a multi-hop saga via the correlation header,
        # interleaved with foreign requests. Serial per-tenant execution
        # makes the stamps consecutive, so the seam counts are exact:
        # S f f S f S → gaps of 2 and 1.
        saga_hdr = {"X-Rove-Correlation-Id": "saga-e2e"}
        plan = [saga_hdr, None, None, saga_hdr, None, saga_hdr]
        saga_ok = 0
        for i, hdr in enumerate(plan):
            rr = c.request("globex", f"/?fn=handler&s={i}", headers=hdr,
                           timeout=30.0)
            if rr.status == 200 and rr.body == "ready":
                saga_ok += 1
        check("generated the interleaved saga traffic", saga_ok == len(plan),
              f"{saga_ok}/{len(plan)} returned 200 'ready'")

        # Wait for the saga's hops to be indexed, then hold the response.
        saga_body = ""
        saga = {}
        deadline = time.time() + 30.0
        while time.time() < deadline:
            resp = c.log_get("globex/saga/saga-e2e", timeout=15.0)
            saga_body = resp.body
            if resp.status == 200:
                try:
                    saga = json.loads(resp.body)
                except json.JSONDecodeError:
                    saga = {}
                if len(saga.get("hops", [])) >= 3:
                    break
            time.sleep(1.0)

        hops = saga.get("hops", [])
        hop_seqs = [int(h.get("exec_seq", "0")) for h in hops]
        check("saga window returns 3 hops in ascending tape order",
              len(hops) == 3 and hop_seqs == sorted(hop_seqs)
              and all(s > 0 for s in hop_seqs),
              f"hops={hop_seqs} body={saga_body[:200]!r}")
        check("saga roll-up names the saga and counts its activations",
              saga.get("saga", {}).get("saga_id") == "saga-e2e"
              and saga.get("saga", {}).get("activation_count") == 3,
              f"saga={saga.get('saga')!r}")
        gaps = saga.get("gaps", [])
        check("gap summaries count the interleaved foreign activations",
              [g.get("count") for g in gaps] == [2, 1]
              and not any(g.get("truncated") for g in gaps),
              f"gaps={gaps!r}")
        if len(hop_seqs) == 3:
            p2 = c.log_get(f"globex/saga/saga-e2e?after_seq={hop_seqs[0]}",
                           timeout=15.0)
            p2_hops = []
            if p2.status == 200:
                try:
                    p2_hops = [int(h.get("exec_seq", "0"))
                               for h in json.loads(p2.body).get("hops", [])]
                except json.JSONDecodeError:
                    pass
            check("saga cursor resumes strictly after a hop",
                  p2_hops == hop_seqs[1:], f"page2={p2_hops}")
        unknown = c.log_get("globex/saga/never-seen", timeout=15.0)
        check("unknown saga is a 404", unknown.status == 404,
              f"status={unknown.status}")

        # ── Saga identity across the durability boundary: an armed wake
        # fires as its OWN saga, carrying the arming saga as `_parent`.
        arm = c.request("globex", "/?fn=arm",
                        headers={"X-Rove-Correlation-Id": "parent-e2e"},
                        timeout=30.0)
        check("armed a durable wake from saga parent-e2e",
              arm.status == 200 and arm.body == "armed",
              f"status={arm.status} body={arm.body!r}")

        # The wake fires ~1s later; poll for its record via the parent tag.
        fired = []
        deadline = time.time() + 45.0
        last = ""
        while time.time() < deadline:
            resp = c.log_get("globex/list?tag._parent=parent-e2e", timeout=15.0)
            last = resp.body
            if resp.status == 200:
                try:
                    fired = json.loads(resp.body).get("records", [])
                except json.JSONDecodeError:
                    fired = []
                if fired:
                    break
            time.sleep(1.0)
        check("the fired wake's record carries _parent=parent-e2e",
              len(fired) == 1 and fired[0].get("activation") == "durable_wake",
              f"records={len(fired)} last={last[:200]!r}")

        # The fired activation roots a FRESH saga — never the armer's.
        if fired:
            rid = fired[0].get("request_id")
            shown = c.log_get(f"globex/show/{rid}", timeout=15.0)
            wake_saga = ""
            if shown.status == 200:
                try:
                    wake_saga = json.loads(shown.body).get("record", {}).get("saga_id", "")
                except json.JSONDecodeError:
                    pass
            check("the fired wake rooted its own saga (wake-*)",
                  wake_saga.startswith("wake-") and wake_saga != "parent-e2e",
                  f"saga_id={wake_saga!r}")
        # ── Seam interference. Serial execution pins the tape order:
        #   S: touch?w=cart/1      (hop 1 — writes cart/1)
        #   F1: touch?w=shared/k   (foreign — writes what hop 2 reads)
        #   F2: touch?r=cart/1     (foreign — reads what hop 1 wrote)
        #   S: touch?r=shared/k    (hop 2 — reads shared/k)
        # /seam over (hop1, hop2) must return F2 then F1 (newest-first)
        # with the exact matched keys.
        seam_hdr = {"X-Rove-Correlation-Id": "seam-e2e"}
        plan2 = [("/?fn=touch&w=cart/1", seam_hdr),
                 ("/?fn=touch&w=shared/k", None),
                 ("/?fn=touch&r=cart/1", None),
                 ("/?fn=touch&r=shared/k", seam_hdr)]
        touched = 0
        for path2, hdr in plan2:
            rr = c.request("globex", path2, headers=hdr, timeout=30.0)
            if rr.status == 200 and rr.body == "touched":
                touched += 1
        check("generated the seam traffic", touched == len(plan2),
              f"{touched}/{len(plan2)} returned 200 'touched'")

        seam_hops = []
        deadline = time.time() + 30.0
        while time.time() < deadline:
            resp = c.log_get("globex/saga/seam-e2e", timeout=15.0)
            if resp.status == 200:
                try:
                    seam_hops = json.loads(resp.body).get("hops", [])
                except json.JSONDecodeError:
                    seam_hops = []
                if len(seam_hops) >= 2:
                    break
            time.sleep(1.0)
        check("seam saga indexed with 2 hops", len(seam_hops) == 2,
              f"hops={len(seam_hops)}")

        if len(seam_hops) == 2:
            a_seq = seam_hops[0]["exec_seq"]
            b_seq = seam_hops[1]["exec_seq"]
            sresp = c.log_get(
                f"globex/seam?after_seq={a_seq}&before_seq={b_seq}",
                timeout=30.0)
            seam = {}
            if sresp.status == 200:
                try:
                    seam = json.loads(sresp.body)
                except json.JSONDecodeError:
                    pass
            inter = seam.get("interacting", [])
            check("seam scan finds both interacting foreigners, newest-first",
                  len(inter) == 2
                  and inter[0].get("read") == ["cart/1"] and inter[0].get("wrote") == []
                  and inter[1].get("wrote") == ["shared/k"] and inter[1].get("read") == [],
                  f"status={sresp.status} interacting={inter!r} body={sresp.body[:300]!r}")
            # `skipped_no_tape` is REPORTED, not asserted at 0: an
            # unrelated kv-free activation (a scheduler tick, a wake)
            # can legitimately land in this seam and be unprobeable.
            check("seam probe is honest about its inputs",
                  seam.get("probe", {}).get("reads") == 1
                  and seam.get("probe", {}).get("writes") == 1
                  and not seam.get("scan_truncated"),
                  f"probe={seam.get('probe')!r} skipped={seam.get('skipped_no_tape')!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {len(records)} globex records indexed via the poll cursor "
          "and served through the reader connection (list + count + show).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
