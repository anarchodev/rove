#!/usr/bin/env python3
"""End-to-end smoke for `docs/curl-multi-plan.md` Phase 3 (gap 2.5)
— held outbound subscription via `http.subscribe`.

Flow:
  1. acme/subscribe?url=wb/drip   → entry handler returns sub_id
     subscribe_oc.mjs records chunks under `sub/chunk/<id>/<seq>`
  2. Poll until at least 3 chunks have landed (proves the
     held transfer is streaming + on_chunk activations fire).
  3. acme/cancel_subscribe?id=...  → cancels the subscription
  4. Assert no `sub/done/<id>` marker (cancel doesn't fire final;
     `docs/curl-multi-plan.md` §5 invariant 3 — cooperative cancel
     doesn't synthesize a terminal event).
  5. Confirm chunk count stops growing past the cancel.

The wb/drip upstream emits one frame every ~120 ms forever (or
until the consumer FINs); the held subscription stays open until
we cancel.
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
        tag="subscription-smoke",
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
        drip_url = f"https://{WB_HOST}:{leader_port}/drip"

        # Warm BOTH acme + wb so both seed deploys are loaded
        # before we issue /subscribe (without this, libcurl hits wb
        # while it's still 503'ing on "no deployment" and the held
        # transfer closes immediately with status=503). Use wb's
        # root (finite handler) rather than wb/drip — drip is
        # infinite.
        wb_root = f"https://{WB_HOST}:{leader_port}/"
        deadline = time.monotonic() + 20.0
        acme_ok = False
        wb_ok = False
        while time.monotonic() < deadline:
            if not acme_ok and curl(cc, f"{acme_origin}/", method="GET").status in (200, 404):
                acme_ok = True
            if not wb_ok and curl(cc, wb_root, method="GET").status == 200:
                wb_ok = True
            if acme_ok and wb_ok:
                break
            time.sleep(0.2)
        if not (acme_ok and wb_ok):
            sys.exit(f"FAIL warmup timeout: acme_ok={acme_ok} wb_ok={wb_ok}")
        print("ok  acme + wb tenants both warm")

        # 1. Open the subscription.
        import urllib.parse as up
        r = curl(cc, f"{acme_origin}/subscribe?url={up.quote(drip_url)}", method="GET")
        if r.status != 200 or not r.body:
            sys.exit(f"FAIL /subscribe status={r.status} body={r.body!r}")
        sub_id = r.body.strip()
        print(f"ok  http.subscribe opened; id={sub_id[:16]}…")

        # 2. Poll until N chunks have arrived. Each chunk_count()
        #    sequentially GETs up to `cap` keys — keep `cap` small
        #    so the poll doesn't eat its own budget. wb/drip drips
        #    every ~120 ms; getting 3 chunks should take well under
        #    a second, but we allow generous slack for cold-start
        #    (TLS handshake to wb, first activation pulling the
        #    on_chunk module's bytecode, etc.).
        def chunks_up_to(cap: int) -> int:
            n = 0
            for seq in range(0, cap):
                r = curl(cc, f"{acme_origin}/readkey?key=sub/chunk/{sub_id}/{seq}", method="GET")
                if r.status != 200:
                    break
                n += 1
            return n

        target = 3
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if chunks_up_to(target) >= target:
                break
            time.sleep(0.2)
        got = chunks_up_to(target + 4)
        if got < target:
            sys.exit(f"FAIL only {got} chunks arrived in 15 s (want ≥ {target}); subscription not streaming")
        print(f"ok  {got} chunks streamed before cancel (wb/drip drips at ~120 ms)")

        # 3. Cancel.
        r = curl(cc, f"{acme_origin}/cancel_subscribe?id={sub_id}", method="GET")
        if r.status != 200:
            sys.exit(f"FAIL /cancel_subscribe status={r.status} body={r.body!r}")
        print("ok  cancellation submitted")

        # 4. Cancel is cooperative — assert no terminal event was
        #    synthesized. (sub/done/<id> would mean on_done fired,
        #    which Phase 3 §5 invariant 3 says it should not on a
        #    successful cancel; it CAN appear if the upstream
        #    happened to close on its own at the same time, but
        #    wb/drip drips forever so that won't happen in this
        #    smoke.)
        time.sleep(0.5)
        r = curl(cc, f"{acme_origin}/readkey?key=sub/done/{sub_id}", method="GET")
        if r.status == 200:
            sys.exit(f"FAIL sub/done/{sub_id} unexpectedly present: {r.body!r}; cancel synthesized a terminal")
        print("ok  no terminal event after cancel (cooperative-cancel posture)")

        # 5. Chunk count stops growing past cancel.
        time.sleep(1.0)
        post_cancel = chunks_up_to(got + 8)
        if post_cancel > got + 2:
            # Small slack: a chunk in flight when cancel ran may
            # still land. >2 extra means cancel didn't take effect.
            sys.exit(f"FAIL chunks kept arriving after cancel: pre={got} post={post_cancel}")
        print(f"ok  chunks stopped after cancel (pre={got} post={post_cancel}; ≤2 in-flight slack expected)")

    print()
    print("subscription smoke passed (curl-multi-plan Phase 3 / gap 2.5: held outbound subscription via http.subscribe; FetchEngine streams + cancel is cooperative)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
