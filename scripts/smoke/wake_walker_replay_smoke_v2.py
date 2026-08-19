#!/usr/bin/env python3
"""A writing `wake_batch` hop recovered across a pre-flush leader crash still
REPLAYS as the same run (rove#199).

`log_failover_walker_smoke_v2.py` proves the promotion walker recovers the log
LINE. This one proves the recovered record is still a faithful recording: a
wake resume's inputs are its drained fired-watch bag
(`request.activation.wakes`) and the export the arm named (`{on: 'onFired'}`),
and both reach a follower only through the readset's `activation` channel —
the flushed S3 record, which is the only other place they live, is exactly what
a pre-flush crash destroys. Recovered without them, the record replays with an
empty wakes bag through the conventional export: a different handler run
wearing the same request id.

Shape (the walker smoke's failover, with a wake hop as the target):

  1. Disable time-based flushing and raise the record threshold, so records
     sit in the leader's RAM.
  2. Arm `after.kv("wk/", {on:'onFired'})` from a held request, then fire it.
     `onFired` WRITES, so the hop commits through raft — a recoverable entry.
  3. Assert no `wake_batch` record is queryable yet (self-checking: if the
     threshold guess were wrong and it flushed, this fails loudly instead of
     passing falsely).
  4. SIGKILL the tenant's raft leader; a follower is promoted and its walker
     re-derives the record from the raft log.
  5. Burst past the record threshold to force the new leader to flush.
  6. Assert the recovered record carries the wakes bag + resolved export, and
     that `rewind replay` reproduces the hop from it with no divergence.

Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs rewind
    set -a; . ./.env; set +a
    python3 scripts/smoke/wake_walker_replay_smoke_v2.py
"""
from __future__ import annotations

import concurrent.futures
import json
import os
import signal
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Hold records unflushed until the post-crash burst: never time-flush, and keep
# the threshold above what setup + the wake hop produce.
RECORD_THRESHOLD = 40
os.environ["REWIND_LOG_FLUSH_INTERVAL_MS"] = str(3_600_000)  # 1h — effectively never
os.environ["REWIND_LOG_FLUSH_RECORDS"] = str(RECORD_THRESHOLD)

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, _curl  # noqa: E402
from replay_matrix_smoke_v2 import find_record, replay  # noqa: E402

# The wake arm names a NON-conventional export, so the resolved export is part
# of the recording: replay through `onWake` would find nothing to call.
WAKE_SRC = """
export default function () {
  const q = request.query || "";
  if (q.includes("op=write")) { kv.set("wk/flag", "1"); response.status = 204; return ""; }
  if (q.includes("op=burst")) { kv.set("burst/mark", "1"); return "b"; }
  if (q.includes("op=ready")) { return "ok"; }
  kv.get("wk/flag");
  after.kv("wk/", { on: "onFired" });
  return next({ armed: true });
}
export function onFired() {
  const fired = request.activation.wakes.filter((w) => w.kind === "kv").map((w) => w.prefix).join(",");
  kv.set("observed", fired);
  response.status = 200;
  return "woke:" + fired + ":" + String(request.ctx && request.ctx.armed === true);
}
"""
FIXTURE = {"index.mjs": WAKE_SRC}
TENANT = "wakewalk"
WOKE_BODY = "woke:wk/:true"


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== walker-recovered wake hop replays with its wakes bag + export (#199) ===")
    with V2Cluster.spawn("wakewalk", nodes=3) as c:
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"{r.status} {r.body!r}")
        c.wait_for_membership(TENANT, voters=3)
        c.deploy_handlers(TENANT, FIXTURE)
        c.wait_for_handler(TENANT, "/?op=ready", want_body="ok", timeout_s=30.0)

        # ── The target: a WRITING wake resume, held in RAM ──
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(lambda: c.request(TENANT, "/?op=hold", method="POST",
                                                data="{}", timeout=40.0))
            time.sleep(1.0)  # let the inbound hop park + arm after.kv("wk/")
            c.request(TENANT, "/?op=write", method="POST", data="{}", timeout=30.0)
            live = fut.result(timeout=45.0)
        check("wake resume ran live (writes + resolves the held request)",
              live.status == 200 and live.body == WOKE_BODY,
              f"{live.status} {live.body!r}")

        # ── Self-checking: the wake record must NOT be flushed yet ──
        time.sleep(2.0)
        pre = find_record(c, TENANT, "wake_batch", tries=2)
        check("wake_batch record NOT yet in logs (held unflushed pre-crash)",
              pre is None,
              "" if pre is None else "already flushed — the threshold guess is wrong")

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
        check("found tenant leader", leader_idx is not None, f"leader_idx={leader_idx}")
        if leader_idx is None:
            c.dump_node_log(grep=["leader", "error", "warn"])
            print(f"\nFAILED: {failures}")
            return 1

        print(f"       tenant leader is node {leader_idx + 1} — SIGKILL")
        lp = c.node_procs[leader_idx]
        lp._expected_kill = True
        lp.send_signal(signal.SIGKILL)
        lp.wait()

        # ── Promote + force the new leader to flush (walker output rides along) ──
        # Requests issued inside the election window answer 503 until the new
        # leader is up, so this counts SUCCESSES rather than attempts: the
        # buffer only reaches the flush threshold on records that committed.
        burst_ok, attempts = 0, 0
        while burst_ok < RECORD_THRESHOLD and attempts < RECORD_THRESHOLD * 3:
            br = c.request(TENANT, f"/?op=burst&i={attempts}", timeout=30.0)
            attempts += 1
            if br.status == 200:
                burst_ok += 1
        check("follower promoted + burst committed on the surviving quorum",
              burst_ok >= RECORD_THRESHOLD, f"{burst_ok} ok in {attempts} attempts")

        rec = find_record(c, TENANT, "wake_batch", tries=60)
        check("walker re-derived the wake_batch record after promotion",
              rec is not None)

        tapes = (rec or {}).get("tapes", {}) or {}
        check("recovered record carries the wakes bag (activation channel → raft)",
              bool(tapes.get("activation_bytes_b64")),
              f"tape keys={sorted(tapes.keys())}")
        check("recovered record carries the resolved export (G3)",
              tapes.get("export") == "onFired", f"export={tapes.get('export')!r}")

        art = replay(rec, TENANT, "wake_batch", WAKE_SRC) if rec else None
        writes = [e for e in ((art.get("effects") if art else None) or []) if e.get("kind") == "write"]
        observed = next((w for w in writes if w.get("key") == "observed"), None)
        check("replay of the RECOVERED record reproduces wakes[] + ctx",
              art and art.get("divergence") is None and art.get("body") == WOKE_BODY
              and observed and observed.get("value") == "wk/",
              f"body={art.get('body') if art else None} writes={writes!r} "
              f"div={art.get('divergence') if art else None}")

        if failures:
            c.dump_node_log(grep=["walker", "flush", "error", "warn"])

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — a walker-recovered writing wake hop replays as the same run: "
          "its fired-watch bag and its resolved export rode the raft entry.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
