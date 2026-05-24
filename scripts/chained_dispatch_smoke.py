#!/usr/bin/env python3
"""Effect-reification Phase 5 PR-2a regression gate — `__rove_next`
returned from a fetch `on_chunk` handler dispatches the next module.

Pre-PR-2 the `.continuation` arm of `fireFetchEventActivation`
warn-and-dropped (`"__rove_next from a fetch activation is a no-op
(v1)"`). PR-2a lifted it: the cont's `path` / `fn` / `ctx` enqueue
a `SendCallback` Msg routed to the tenant's hash-routed worker,
which then runs `fireChainedActivation` against the named module
with `request.activation.kind === "send_callback"` + the cont's
ctx wrapped as `request.body = {"ctx": <ctx>}` (same shape as
fireSubscriptionActivation so customers' parse pattern is uniform).

The exerciser:

  GET /chainfetch?url=<wb/bulk>
    entry: http.fetch({on_chunk: "chainfetchstep1"})
    chainfetchstep1.mjs on the final event: return __rove_next(
      "chainresult", {ctx: {seen_status, seen_ok, ...}})
    chainresult.mjs (PR-2a's new dispatch path): writes
      kv["chain/result"] = JSON of the threaded ctx

The smoke asserts the kv marker reflects the round-trip:
seen_status=200, seen_ok=true, originating_tag="chainfetch", plus
activation kind = "send_callback".
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import Cluster, curl  # noqa: E402

TOKEN = "ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddff"
PUBLIC_SUFFIX = "rewindjsapp.localhost"
ACME_HOST = f"acme.{PUBLIC_SUFFIX}"
WB_HOST = f"wb.{PUBLIC_SUFFIX}"


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    cluster = Cluster.spawn(
        tag="chained-dispatch-smoke",
        http_base=8340,
        raft_base=40440,
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
        print(f"ok  leader elected: node {c.leader_idx}")

        cc = c.curl_ctx(ACME_HOST, WB_HOST)
        acme_origin = f"https://{ACME_HOST}:{leader_port}"
        bulk_url = f"https://{WB_HOST}:{leader_port}/bulk"

        # Sanity: wb/bulk reachable.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            r = curl(cc, bulk_url, method="GET")
            if r.status == 200:
                break
            time.sleep(0.2)
        else:
            sys.exit(f"FAIL wb/bulk sanity: {r.status}")
        print("ok  wb/bulk reachable")

        # Fire the chain.
        deadline = time.monotonic() + 20.0
        fetch_id = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{acme_origin}/chainfetch?url={bulk_url}", method="GET")
            if r.status == 200 and r.body:
                fetch_id = r.body.strip()
                break
            time.sleep(0.2)
        if not fetch_id:
            sys.exit(f"FAIL /chainfetch: {r.status} {r.body!r}")
        print(f"ok  /chainfetch issued; fetch_id={fetch_id[:16]}…")

        # Poll for the chained-dispatch marker.
        deadline = time.monotonic() + 15.0
        marker = None
        while time.monotonic() < deadline:
            r = curl(cc, f"{acme_origin}/readkey?key=chain/result", method="GET")
            if r.status == 200:
                marker = json.loads(r.body)
                break
            time.sleep(0.2)
        if marker is None:
            sys.exit("FAIL chain/result marker never landed — chained dispatch did not run")
        print(f"ok  chain/result marker landed: {marker!r}")

        # Assertions.
        if marker["kind"] != "send_callback":
            sys.exit(
                f"FAIL activation.kind={marker['kind']!r} (want 'send_callback')"
            )
        if marker["seen_status"] != 200:
            sys.exit(f"FAIL seen_status={marker['seen_status']} (want 200)")
        if marker["seen_ok"] is not True:
            sys.exit(f"FAIL seen_ok={marker['seen_ok']} (want true)")
        if marker["seen_bytes_len"] not in (0, 170):
            # Single-chunk final event may carry 0-byte payload (the
            # canonical final-empty) OR the full body — both are
            # acceptable depending on cap interactions.
            sys.exit(f"FAIL seen_bytes_len={marker['seen_bytes_len']!r} (want 0 or 170)")
        if marker["originating_tag"] != "chainfetch":
            sys.exit(
                f"FAIL originating_tag={marker['originating_tag']!r} did NOT round-trip"
            )
        if marker["fetch_id"] != fetch_id:
            sys.exit(
                f"FAIL fetch_id={marker['fetch_id']!r} != {fetch_id!r}"
            )
        print("ok  every chained-ctx field round-tripped correctly")

    print()
    print(
        "chained-dispatch smoke passed (Phase 5 PR-2a: `__rove_next` "
        "from a fetch `on_chunk` handler dispatches the named module "
        "via SendCallback Msg + fireChainedActivation; customer-facing "
        "shape is `request.activation.kind === 'send_callback'` and "
        "`request.body = {\"ctx\": <cont's ctx>}`)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
