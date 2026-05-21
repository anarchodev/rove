#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.1 Phase D — boot subscription chain
origin firing on snapshot activation.

Setup:
  • 3-node cluster, leader-only customer traffic.
  • `acme/_subscriptions/migrate-v1/{spec.json,index.mjs}`
    declares a boot subscription. On first deploy-load the
    deployment_loader thread (leader-only) enqueues the boot fire
    to the node-wide subscription-fire inbox; a worker drains the
    inbox and dispatches via the normal `subscription_fire_pending`
    collection + `dispatchSubscriptionFires` system. The handler
    writes `boot-fired-marker = "dep=<id> count=<n>"` so the
    smoke can verify both that the fire happened and the source
    payload (deployment_id) is correct.

Gate:
  1. After cluster startup, poll `/readkey?key=boot-fired-marker`;
     the marker appears with `count=1` (proves the handler
     fired exactly once on the leader).
  2. Poll `/readkey?key=_boot_fired/<deployment_id>`; the runtime-
     written gate marker appears with value `fired` (proves the
     marker raft-propose + commit cycle ran, so subsequent
     reloads / failovers will not re-fire).

This is the first proof of a chain origin firing from a
non-worker thread (the deployment_loader) — the cross-thread
inbox + hash-routed enqueue is the load-bearing piece.
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="streaming-subscription-boot-smoke",
        http_base=8390,
        raft_base=40490,
        public_suffix=PUBLIC_SUFFIX,
        root_token=TOKEN,
        workers_per_node=1,
        with_log_files_bases=False,
        seed_manifest=repo_root / "examples" / "loop46-demo-tenants.json",
    )
    with cluster as c:
        c.discover_leader()
        leader_port = c.addrs.http_port(c.leader_idx)
        print(f"ok  leader=node{c.leader_idx} ({c.addrs.http[c.leader_idx]})")

        cc = c.curl_ctx(ACME_HOST)
        leader_origin = f"https://{ACME_HOST}:{leader_port}"

        # Reachability gate.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/", method="GET")
            if r.status in (200, 404):
                break
            time.sleep(0.2)
        else:
            sys.exit("FAIL acme not reachable on leader")
        print("ok  acme reachable on leader")

        # Poll for the customer's marker — proves the handler ran.
        # The deployment_loader thread enqueues to the worker
        # inbox during snapshot activation; the worker tick (which
        # also serves /readkey requests) drains the inbox + fires.
        deadline = time.monotonic() + 5.0
        marker = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/readkey?key=boot-fired-marker", method="GET")
            if r.status == 200:
                marker = r.body
                break
            time.sleep(0.1)
        if marker is None:
            sys.exit("FAIL boot-fired-marker never appeared (boot subscription didn't fire)")
        marker = marker.strip()
        if "count=1" not in marker:
            sys.exit(
                f"FAIL boot fired more than once or count missing: {marker!r}"
            )
        if "dep=" not in marker:
            sys.exit(f"FAIL boot marker missing dep= prefix: {marker!r}")
        # Extract deployment_id from the marker (for the gate check below).
        parts = marker.split()
        dep_id_str = None
        for p in parts:
            if p.startswith("dep="):
                dep_id_str = p[4:]
                break
        if dep_id_str is None:
            sys.exit(f"FAIL boot marker has no dep= part: {marker!r}")
        print(f"ok  boot handler fired exactly once (marker={marker!r})")

        # Verify the runtime-written gate marker.
        # `_boot_fired/<dep_id>` should be present with value `fired`.
        deadline = time.monotonic() + 5.0
        gate = None
        while time.monotonic() < deadline:
            r = curl(
                cc,
                f"{leader_origin}/readkey?key=_boot_fired/{dep_id_str}",
                method="GET",
            )
            if r.status == 200:
                gate = r.body
                break
            time.sleep(0.1)
        if gate is None:
            sys.exit(
                f"FAIL _boot_fired/{dep_id_str} gate marker never appeared "
                "(runtime didn't write the gate post-fire)"
            )
        if gate.strip() != "fired":
            sys.exit(f"FAIL gate marker value: expected 'fired', got {gate!r}")
        print(f"ok  runtime gate marker written: _boot_fired/{dep_id_str} = 'fired'")

        # Sanity: hammering /readkey doesn't accidentally re-fire
        # the boot. The boot subscription should remain at count=1
        # forever for this deployment.
        for _ in range(3):
            r = curl(cc, f"{leader_origin}/readkey?key=boot-fired-marker", method="GET")
            if r.status != 200 or "count=1" not in r.body:
                sys.exit(
                    f"FAIL boot re-fired after subsequent requests "
                    f"(marker={r.body!r})"
                )
        print("ok  boot remained at count=1 across follow-up requests (no re-fire)")

        print(
            "\nstreaming-subscription-boot smoke passed (Gap 2.1 Phase D: "
            "cross-thread inbox + hash-routed enqueue + runtime-managed "
            "boot-fired gate marker)"
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
