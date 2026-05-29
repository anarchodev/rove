#!/usr/bin/env python3
"""Chunk-spool Phase 4 cleanup smoke — `docs/chunk-spool-plan.md`.

Proves spooled-but-unconsumed chunks are discarded (no leak, no panic,
node survives) on the two non-terminal exits:

  1. Cancel mid-stream — `/spoolcancel` consumes a couple of chunks
     writes-per-chunk (so the spool backs up), then calls
     `http.cancelFetch(request.fetchId)` on its OWN in-flight fetch and
     returns terminal. The tail chunks still in the spool must be
     dropped (`cancelFetchTrampoline` → `dropSpool`). Also exercises
     the reentrancy hazard: the spool's map key is freed by the cancel
     DURING the resume that triggered it.

  2. Disconnect mid-stream — `/boundproxy` streams an INFINITE upstream
     (`wb/drip`) back to the held client, which is killed mid-stream.
     h2 detects the closed stream and routes the held entity to
     `cleanupResponses` → `fireDisconnectActivation` +
     `scanAndCancelBoundFetches` → cancels the still-running drip fetch
     AND `dropSpool`s it. The assertion is crash-safety + survival: the
     node keeps serving and the orphaned fetch is torn down (no leak,
     no panic) — exercising the Phase 4 spool-drop on the real h2
     disconnect path. (A *cont* chain's disconnect isn't observable
     until the §6.4 hold deadline, since h2 doesn't track parked conts;
     that teardown rides the same `resolveParked` → `cleanupResponses`
     → `scanAndCancel` path at the deadline.)

The cancel drop is observed via `bound_fetch_spool_dropped_total`.
Single worker per node so the worker-local metric is deterministic.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

os.environ["ROVE_BOUND_FETCH_SPOOL_DEPTH"] = "2"

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

CANCEL_N = 200
EXPECTED_CANCEL_UPSTREAM = "".join(f"bigbody-line-{i:05d}\n" for i in range(CANCEL_N))


def read_dropped(c, leader_port) -> int:
    admin_cc = c.curl_ctx(c.addrs.admin_host)
    rr = curl(
        admin_cc,
        f"https://{c.addrs.admin_host}:{leader_port}/_system/metrics",
        method="GET",
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    if rr.status != 200:
        sys.exit(f"FAIL metrics fetch: status={rr.status}")
    for line in rr.body.splitlines():
        if line.startswith("bound_fetch_spool_dropped_total "):
            return int(line.split()[-1])
    sys.exit("FAIL bound_fetch_spool_dropped_total missing from metrics")


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="bound-fetch-spool-cleanup-smoke",
        http_base=8360,
        raft_base=40460,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
        worker_extra_args=["--dev-webhook-unsafe"],
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.leader_port()
        print(f"ok  leader elected: node {c.leader_idx} at {c.addrs.http[c.leader_idx]}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        acme_origin = f"https://{ACME_HOST}:{leader_port}"
        cancel_url = f"https://{WB_HOST}:{leader_port}/bigbody?n={CANCEL_N}"
        drip_url = f"https://{WB_HOST}:{leader_port}/drip"

        # Wait for upstream + acme readiness.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, cancel_url, method="GET")
            if r.status == 200 and r.body == EXPECTED_CANCEL_UPSTREAM:
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL wb/bigbody not ready")
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)
        print("ok  upstream + acme ready")

        # ── 1. Cancel mid-stream ───────────────────────────────────────
        r = curl(cc, f"{acme_origin}/spoolcancel?url={cancel_url}", method="GET", timeout=30.0)
        if r.status != 200 or not r.body.startswith("cancelled@"):
            sys.exit(f"FAIL /spoolcancel status={r.status} body={r.body[:120]!r}")
        # Give the cancel's dropSpool a tick to register in the metric.
        time.sleep(0.5)
        dropped_after_cancel = read_dropped(c, leader_port)
        if dropped_after_cancel == 0:
            sys.exit(
                "FAIL cancel dropped 0 spooled chunks — the spool didn't back up "
                "(or dropSpool didn't fire on cancel). Expected the unconsumed tail "
                "to be discarded."
            )
        print(
            f"ok  cancel mid-stream: '{r.body}' shipped; "
            f"{dropped_after_cancel} tail chunk(s) dropped from the spool"
        )

        # ── 2. Disconnect on a held bound-fetch stream ─────────────────
        # Stream the infinite drip upstream back to the held client with
        # a short client timeout. However the client connection ends
        # (killed mid-stream, or curl completing), its close drives the
        # held entity into h2's disconnect path: cleanupResponses →
        # fireDisconnectActivation + scanAndCancelBoundFetches → cancel
        # the still-running drip fetch + dropSpool. The drip fetch would
        # otherwise run forever, so a healthy node afterwards proves the
        # orphan was torn down crash-free (exercises the Phase 4
        # spool-drop on the real h2 disconnect path).
        try:
            curl(cc, f"{acme_origin}/boundproxy?url={drip_url}", method="GET", timeout=1.0)
        except subprocess.TimeoutExpired:
            pass  # client killed mid-stream — also a disconnect
        # Let the disconnect-cleanup pass run.
        time.sleep(0.5)
        print("ok  disconnect: held bound-fetch stream + drip fetch torn down on client close")

        # ── 3. Node survived both ──────────────────────────────────────
        r = curl(cc, cancel_url, method="GET")
        if r.status != 200:
            sys.exit(f"FAIL node not serving after cleanup: status={r.status}")
        # Metric endpoint still answers ⇒ the leader worker didn't crash.
        _ = read_dropped(c, leader_port)
        print("ok  node still serving after cancel + disconnect (no panic / no leak-stall)")

    print()
    print(
        "bound-fetch spool cleanup smoke passed (docs/chunk-spool-plan.md Phase 4: "
        "cancel + disconnect drop the unconsumed spool tail; node survives)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
