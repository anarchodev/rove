#!/usr/bin/env python3
"""End-to-end smoke for the §6.4 held-synchronous third-party call —
the first real exercise of the whole connection-actor trampoline
(Phases 3b-i/ii/iii + 3c, which have no unit coverage by design).

ONE synchronous client request to acme's `/heldsync`:

  client ──POST /heldsync {target,tag}──▶ acme open hop
     open: http.send(target) + return __rove_next(heldsync/onresult#onResult)
        → Part A stamps the schedule's on_result = the continuation
        → entity parks in worker.parked_continuations (held; no response)
     schedule (env-8) commits with the hop's batch → schedule-server
        fires libcurl → wb echoes → schedule_complete (env-9)
     dispatchCallbacks (leader) → Part B partition →
        resumeBoundContinuation → resumeContinuation runs onResult →
        terminal → resolveParked flushes to the STILL-OPEN socket
  ◀── 200 "heldsync:v:echoed:v"  (the one request returns, resumed)

Single-worker functional scope (cross-worker = task #8): spawn with
`workers_per_node=1` and target the leader so the open hop parks on
the leader's sole worker and `dispatchCallbacks` (a leader duty) runs
on that same worker.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="heldsync-smoke",
        http_base=8290,
        raft_base=40390,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        # §6.4 functional scope: one worker per node so the open-hop
        # park and the leader's dispatchCallbacks are the SAME worker
        # (cross-worker node-affinity is task #8).
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        # Allow http.send to the localhost wb target (test-harness
        # flag, same as http_send_smoke).
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        acme_origin = f"https://{ACME_HOST}:{leader_port}"
        wb_echo = f"https://{WB_HOST}:{leader_port}/echo"

        # 1. Sanity: wb (the third party) is reachable + echoes.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(
                cc, f"https://{WB_HOST}:{leader_port}/",
                method="POST",
                headers={"content-type": "application/json"},
                data='{"tag":"sanity"}',
            )
            if r.status == 200 and r.body == "echoed:sanity":
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL wb sanity: {r.status} {r.body!r}")
        print("ok  wb (third party) reachable; echoes")

        # 2. Also poll acme reachable (seed deploy is async).
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. THE held-synchronous request. One blocking POST; it must
        #    return the RESUMED body, fast (well under the 25s §6.4
        #    hold deadline — fast return proves it was the resume, not
        #    the deadline-504 fallback).
        t0 = time.monotonic()
        r = curl(
            cc, f"{acme_origin}/heldsync",
            method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"target": wb_echo, "tag": "v"}),
            timeout=30.0,  # > 25s hold deadline so even a 504 fallback returns (not a curl timeout)
        )
        elapsed = time.monotonic() - t0

        if r.status != 200:
            sys.exit(f"FAIL heldsync status={r.status} body={r.body!r} ({elapsed:.1f}s)")
        if r.body != "heldsync:v:echoed:v":
            sys.exit(f"FAIL heldsync body={r.body!r} (want 'heldsync:v:echoed:v') ({elapsed:.1f}s)")
        if elapsed >= 15.0:
            sys.exit(
                f"FAIL heldsync returned correct body but in {elapsed:.1f}s — "
                "that's the deadline-504 path, not the http.send resume"
            )
        print(
            f"ok  held-synchronous call resumed: one POST → "
            f"'{r.body}' in {elapsed:.2f}s (resume, not deadline)"
        )

        # 4. Failure-outcome variant: http.send to a dead port →
        #    Part B resumes with ok=false → the resume hop authors a
        #    502. Proves failure delivery + handler-authored error
        #    response (the SAME onResult(!ok) branch the §6.4 deadline
        #    path takes — {ok:false,reason:"deadline"}).
        dead = "https://127.0.0.1:9/"  # nothing listens → fast conn-refused
        t0 = time.monotonic()
        r = curl(
            cc, f"{acme_origin}/heldsync",
            method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"target": dead, "tag": "vf"}),
            timeout=30.0,
        )
        el = time.monotonic() - t0
        if r.status != 502 or not r.body.startswith("heldsync upstream failed:"):
            sys.exit(f"FAIL failure-variant status={r.status} body={r.body!r} ({el:.1f}s)")
        if el >= 15.0:
            sys.exit(f"FAIL failure-variant took {el:.1f}s — not the fast failure path")
        print(f"ok  failure outcome → handler-authored 502 in {el:.2f}s: '{r.body}'")

        # 5. Recipe-1 real-retry — effectful resume hop. The resume
        #    hop fires another http.send (to a working target) and
        #    re-parks via `__rove_next`. Phase 4 of
        #    docs/streaming-handlers-plan.md lifted the read-only-
        #    resume restriction (formerly "3b-iii read-only"); the
        #    pattern composes end-to-end:
        #      1. Open hop fires to dead → resume with failure.
        #      2. Resume fires to working target → repark.
        #      3. Resume fires with success → terminal flush
        #         carrying the working target's echo body.
        #
        #    The new contract: status=200, body echoes the retry
        #    target's response. Pre-Phase-4 this was a defined 500
        #    ("3b-iii read-only") — that boundary is gone.
        t0 = time.monotonic()
        r = curl(
            cc, f"{acme_origin}/heldsync",
            method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"target": dead, "tag": "vr", "retry_to": wb_echo}),
            timeout=30.0,
        )
        el = time.monotonic() - t0
        if r.status != 200 or r.body != "heldsync:vr:echoed:vr":
            sys.exit(
                f"FAIL recipe-1 real-retry status={r.status} body={r.body!r} "
                f"({el:.1f}s) — Phase 4 should chain dead→retry_to and flush "
                f"'heldsync:vr:echoed:vr' from the working target"
            )
        if el >= 15.0:
            sys.exit(f"FAIL recipe-1 real-retry took {el:.1f}s — not the fast path")
        print(
            f"ok  recipe-1 real-retry: chained dead→retry_to, terminal 200 in "
            f"{el:.2f}s — body='{r.body}' (Phase 4 effectful-resume lift live)"
        )

        print()
        print("held-synchronous (§6.4) smoke passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
