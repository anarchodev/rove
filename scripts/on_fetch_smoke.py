#!/usr/bin/env python3
"""End-to-end smoke for the `on.fetch` surface (handler-surface Phase 3
slice 3a).

`on.fetch(url, opts, {to})` is the NEW connection-scoped outbound: it
binds the fetch to the held chain — each upstream chunk wakes the `{to}`
export ("onUpstream") while the chain holds the socket. The `onfetch`
handler accumulates each chunk in kv and returns the reconstructed body
on the terminal chunk, so this proves the bind + `{to}` export override
+ chunk resume WITHOUT needing stream.* output (bound-fetch stream.* is
slice 3d).

  client ──GET /onfetch?url=<wb/bulk>──▶ acme inbound hop
     kv.set acc=""; on.fetch(url, {stream}, {to:onUpstream}); return next()
       → connection-scoped fetch BINDS to the held chain
     per upstream chunk → wakes onUpstream (the {to} export) →
        acc += chunk; return next()
     terminal chunk → onUpstream returns kv.get(acc) to the held client
  ◀── 200 with the byte-exact reconstructed upstream body

A non-held on.fetch is inert (dropped at the success seam) — not
exercised here; that's the connection-only model (webhook.send is the
connectionless twin).

Single worker so the bound chunks land on the worker holding the chain.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"

EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="on-fetch-smoke",
        http_base=8498,
        raft_base=40498,
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
        bulk_url = f"https://{WB_HOST}:{leader_port}/bulk"

        # 1. Upstream reachable + deterministic body.
        deadline = time.monotonic() + 20.0
        ok = False
        while time.monotonic() < deadline:
            r = curl(cc, bulk_url, method="GET")
            if r.status == 200 and r.body == EXPECTED_BODY:
                ok = True
                break
            time.sleep(0.2)
        if not ok:
            sys.exit(f"FAIL wb/bulk sanity: status={r.status} body={r.body!r}")
        print(f"ok  wb/bulk upstream reachable; {len(EXPECTED_BODY)}-byte body")

        # 2. acme reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                break
            time.sleep(0.2)

        # 3. THE on.fetch. The held chain binds the fetch; each chunk
        #    wakes onUpstream (the {to} export) and accumulates; the
        #    terminal chunk returns the reconstructed body.
        r = curl(cc, f"{acme_origin}/onfetch?url={bulk_url}", method="GET", timeout=30.0)
        if r.status != 200:
            sys.exit(f"FAIL /onfetch status={r.status} body={r.body!r}")
        if r.body != EXPECTED_BODY:
            sys.exit(
                f"FAIL on.fetch reconstructed body mismatch.\n"
                f"  want ({len(EXPECTED_BODY)}b): {EXPECTED_BODY!r}\n"
                f"  got  ({len(r.body)}b): {r.body!r}"
            )
        print(f"ok  on.fetch bound + {{to:onUpstream}} resumed; "
              f"reconstructed {len(r.body)}-byte upstream body byte-exact")

        # 4. Non-streaming on.fetch (no stream:true, no {to}) → the whole
        #    upstream body arrives in ONE terminal event dispatched to
        #    the conventional onFetchResult export (handler-shape.md §3).
        r = curl(cc, f"{acme_origin}/onfetchbuf?url={bulk_url}", method="GET", timeout=30.0)
        if r.status != 200:
            sys.exit(f"FAIL /onfetchbuf status={r.status} body={r.body!r}")
        if r.body != EXPECTED_BODY:
            sys.exit(
                f"FAIL onFetchResult body mismatch.\n"
                f"  want ({len(EXPECTED_BODY)}b): {EXPECTED_BODY!r}\n"
                f"  got  ({len(r.body)}b): {r.body!r}"
            )
        print(f"ok  non-streaming on.fetch → onFetchResult delivered "
              f"{len(r.body)}-byte whole body byte-exact")

    print("\nPASS on.fetch smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
