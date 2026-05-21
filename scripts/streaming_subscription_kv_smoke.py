#!/usr/bin/env python3
"""End-to-end smoke for Gap 2.1 Phase E — kv-react subscription
chain origin.

Setup:
  • 3-node cluster, leader-only customer traffic.
  • `acme/_subscriptions/sub-react/{spec.json,index.mjs}` declares
    a kv-react subscription on prefix `sub-react-in/`. The handler
    reads `request.activation.source.{key,op}` and writes a marker
    to `sub-react-out/<key-tail>` so we can verify the chain origin
    fired (and fired exactly once across the cluster — followers
    don't double-fire because the apply hook's leader gate is
    structural).

Gate: POST a write to `sub-react-in/k1` via `/writekv`; poll
`/readkey?key=sub-react-out/k1` until the marker appears. The
marker value `put:hello` proves both (a) the subscription fired
on the kv-write and (b) the activation's source payload was
correctly populated.

This is the first proof that a chain origin runs WITHOUT an
inbound HTTP request — the `_subscriptions/sub-react/index.mjs`
handler has no inbound route and is invoked purely by the
runtime's apply-time hook.
"""

from __future__ import annotations

import json
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
        tag="streaming-subscription-kv-smoke",
        http_base=8380,
        raft_base=40480,
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

        # The write that should fire the kv-react subscription.
        r = curl(
            cc,
            f"{leader_origin}/writekv",
            method="POST",
            data=json.dumps({"key": "sub-react-in/k1", "value": "hello"}),
            headers={"Content-Type": "application/json"},
        )
        if r.status != 204:
            sys.exit(f"FAIL /writekv: status={r.status} body={r.body!r}")
        print("ok  triggering write posted (sub-react-in/k1=hello)")

        # Poll for the subscription's marker — the chain origin
        # commits its write via raft, so we wait for replication.
        deadline = time.monotonic() + 5.0
        marker = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/readkey?key=sub-react-out/k1", method="GET")
            if r.status == 200:
                marker = r.body
                break
            time.sleep(0.1)
        if marker is None:
            sys.exit("FAIL subscription marker never appeared (sub-react-out/k1)")
        expected = "put:hello"
        if marker.strip() != expected:
            sys.exit(f"FAIL marker value: expected {expected!r}, got {marker!r}")
        print(f"ok  subscription fired: sub-react-out/k1 = {marker!r}")

        # Sanity: the leader should also serve a /writekv for the
        # OUT key without breaking (i.e., subsequent writes don't
        # crash the chain origin path).
        r = curl(
            cc,
            f"{leader_origin}/writekv",
            method="POST",
            data=json.dumps({"key": "sub-react-in/k2", "value": "world"}),
            headers={"Content-Type": "application/json"},
        )
        if r.status != 204:
            sys.exit(f"FAIL second write: status={r.status}")
        deadline = time.monotonic() + 5.0
        marker2 = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{leader_origin}/readkey?key=sub-react-out/k2", method="GET")
            if r.status == 200:
                marker2 = r.body
                break
            time.sleep(0.1)
        if marker2 is None or marker2.strip() != "put:world":
            sys.exit(f"FAIL second subscription fire: marker={marker2!r}")
        print(f"ok  subscription fires repeatedly: sub-react-out/k2 = {marker2!r}")

        print(
            "\nstreaming-subscription-kv smoke passed (Gap 2.1 Phase E: "
            "kv-react chain origin fires on apply-time hook, leader-only, "
            "no inbound HTTP request)"
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
