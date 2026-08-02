#!/usr/bin/env python3
"""Promotion-time LogRecord walker (rove #77) — a writing request's log
survives a leader crash that happens BEFORE the record is flushed.

The leader's `flushLogs` is best-effort early visibility: buffered
LogRecords ride RAM until a threshold trips, then PUT to S3 unordered
against raft commit. A leader that dies between propose and flush loses
those records — but the raft entries survive on the followers. On
promotion the new leader's walker re-derives the missing records from its
group's live log and appends them to the normal flush path
(`docs/architecture/deployment-and-logs.md`).

Proving the WALKER (not the original flush) surfaced the record requires
the original flush to NOT have happened. This smoke pins that
deterministically:

  1. Disable the time-based flush (`REWIND_LOG_FLUSH_INTERVAL_MS` huge) and
     raise the record threshold, so a lone request sits UNflushed.
  2. Deploy a WRITING handler; drive one target write (`/wtmarker`). It
     commits through raft (→ a recoverable entry) but does NOT flush.
  3. Assert `/list` has no `wtmarker` record yet — self-checking proof the
     record is still only in the leader's RAM (if the threshold guess were
     wrong and it flushed, THIS fails loudly rather than passing falsely).
  4. SIGKILL the tenant's raft leader.
  5. A follower is promoted; its walker re-derives the target record.
  6. Drive a burst past the record threshold to force the new leader to
     flush (carrying the recovered record).
  7. Assert `/list` now contains the `wtmarker` record → walker recovery.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/smoke/log_failover_walker_smoke_v2.py
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Hold records unflushed until we choose to force a flush: never time-flush,
# and don't hit the record threshold with setup + the single target write.
# The post-failover burst (RECORD_THRESHOLD writes) is what trips the flush.
RECORD_THRESHOLD = 25
os.environ["REWIND_LOG_FLUSH_INTERVAL_MS"] = str(3_600_000)  # 1h — effectively never
os.environ["REWIND_LOG_FLUSH_RECORDS"] = str(RECORD_THRESHOLD)

from smoke_lib_v2 import V2Cluster, rpc_wrap, MOVE_SECRET, _curl  # noqa: E402

HANDLER_SRC = """
export function ready() { return "ok"; }
export function walk(request) {
  kv.set("walker/mark", "1");
  console.log("walker-target-hit");
  return "written";
}
"""
FIXTURE = {"index.mjs": rpc_wrap(HANDLER_SRC)}

TENANT = "walkerco"
TARGET_MARK = "wtmarker"


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== promotion-time LogRecord walker: pre-flush leader crash (#77) ===")
    with V2Cluster.spawn("logwalk", nodes=3) as c:
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"{r.status} {r.body!r}")
        c.wait_for_membership(TENANT, voters=3)
        c.deploy_handlers(TENANT, FIXTURE)
        c.wait_for_handler(TENANT, "/?fn=ready", want_body="ok", timeout_s=30.0)

        # ── Drive the TARGET writing request (commits via raft, held in RAM) ──
        tr = c.request(TENANT, f"/{TARGET_MARK}?fn=walk", timeout=30.0)
        check("target write committed → 200 'written'",
              tr.status == 200 and tr.body == "written",
              f"{tr.status} {tr.body!r}")

        def list_records():
            resp = c.log_get(f"{TENANT}/list?limit=200", timeout=15.0)
            if resp.status != 200:
                return None, resp
            try:
                return json.loads(resp.body).get("records", []), resp
            except json.JSONDecodeError:
                return [], resp

        def has_target(records):
            return any(TARGET_MARK in (rec.get("path") or "") for rec in (records or []))

        # ── Self-checking: the target must NOT be flushed yet ──
        # Give the log-server a few poll cycles; if anything flushed the target
        # already, this fails LOUDLY (the whole test would otherwise be moot).
        time.sleep(2.0)
        pre_records, pre_resp = list_records()
        check("target NOT yet in logs (held unflushed pre-crash)",
              not has_target(pre_records),
              f"list status={pre_resp.status} n={len(pre_records or [])}")

        # ── Find + SIGKILL the tenant's raft leader ──
        leader_idx = None
        deadline = time.time() + 20.0
        while time.time() < deadline and leader_idx is None:
            for i in range(len(c.node_ports)):
                lr = _curl(f"{c.node_url(i)}/_system/v2-member-status?tenant="
                           f"{urllib.parse.quote(TENANT)}", timeout=5.0,
                           headers={"X-Rewind-Move-Secret": MOVE_SECRET})
                if lr.status == 200:
                    leader_idx = i
                    break
            if leader_idx is None:
                time.sleep(0.3)
        check("found tenant leader", leader_idx is not None,
              f"leader_idx={leader_idx}")
        if leader_idx is None:
            c.dump_node_log(grep=["leader", "error", "warn"])
            print(f"\nFAILED: {failures}")
            return 1

        print(f"       tenant leader is node {leader_idx + 1} — SIGKILL")
        lp = c.node_procs[leader_idx]
        lp._expected_kill = True
        lp.send_signal(signal.SIGKILL)
        lp.wait()

        # ── A follower is promoted + forced to flush ──
        # The burst is the functional promotion signal: each write is routed
        # through the front (leader-aware, retries a 503/421 until the new
        # leader answers), so a burst that commits proves a follower took over.
        # It also pushes the new leader's buffer — recovered records + the burst
        # — past the record threshold, tripping `shouldFlush`. The walker runs
        # each poll tick on the new leader, so it has re-derived the target by
        # the time these commit.
        burst_ok = 0
        for i in range(RECORD_THRESHOLD + 5):
            br = c.request(TENANT, f"/burst?fn=walk&i={i}", timeout=30.0)
            if br.status == 200:
                burst_ok += 1
        check("follower promoted + burst committed on the surviving quorum",
              burst_ok >= RECORD_THRESHOLD,
              f"{burst_ok}/{RECORD_THRESHOLD + 5} ok")

        # ── The recovered target must now surface via the log query ──
        found = False
        deadline = time.time() + 40.0
        last_n = 0
        while time.time() < deadline:
            recs, resp = list_records()
            last_n = len(recs or [])
            if has_target(recs):
                found = True
                break
            time.sleep(1.0)
        check("walker re-derived the target record after promotion",
              found, f"{last_n} records listed; none matched '{TARGET_MARK}'"
              if not found else "")

        if not found:
            c.dump_node_log(grep=["log-walker", "walker", "flush", "error", "warn"])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a writing request's log survived a pre-flush leader crash: "
          "the promoted leader's walker re-derived it from the raft log.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
