#!/usr/bin/env python3
"""V2 port of `bound_fetch_smoke.py` — `http.fetch`/`on.fetch` auto-bind
streaming (docs/streaming-model.md §7 item 1 + docs/handler-shape.md §5.5)
on the `V2Cluster` harness (`smoke_lib_v2`).

Two tenants on a single node:
  - `acme` opens a held `on.fetch(url, {stream, max_response_chunk_bytes:64})`
    that auto-binds to the held chain; each upstream chunk fires
    `onFetchChunk`, which streams a "chunk:<text>" frame back to the held
    socket via `stream.write`. Terminal closes the stream.
  - `wb` serves `/bulk` — a deterministic 170-byte ASCII body.

Handler JS reused VERBATIM from the V1 demo tenants
(`examples/loop46-demo-tenants/{acme/boundproxy,wb/bulk}/index.mjs`).
The handler reads the upstream URL from `?url=`, so Python injects the
tenant-host:node_port URL.

Essential assertions (unchanged from V1):
  - The held client receives a 200 with ≥3 "chunk:" frames (170-byte body
    re-chunked at 64-byte granularity → 64+64+42).
  - Concatenating the frame payloads reconstructs the upstream body
    byte-exact.

Dropped from V1: TLS/https, leader election / discover_leader,
seed_manifest, --dev-webhook-unsafe (single-node V2; provision+deploy via
the harness). The bound fetch targets `http://wb.<suffix>:<node_port>/bulk`
— the worker binds 0.0.0.0 so on-box libcurl reaches the same node over
loopback, and the `wb.<suffix>` Host carries the tenant routing (a bare
127.0.0.1 URL would 404). Outbound is not SSRF-blocked on V2.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


ACME_HANDLERS = {
    "index.mjs": _src("acme/index.mjs"),
    "boundproxy/index.mjs": _src("acme/boundproxy/index.mjs"),
}
WB_HANDLERS = {
    "index.mjs": _src("wb/index.mjs"),
    "bulk/index.mjs": _src("wb/bulk/index.mjs"),
}

EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("bfetch", nodes=1) as c:
        print("step 1: provision + deploy acme (proxy) and wb (bulk upstream)")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", ACME_HANDLERS)
            c.deploy_handlers("wb", WB_HANDLERS)
            check("deploy acme + wb", True)
        except RuntimeError as e:
            check("deploy acme + wb", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # ── 1. Upstream reachable + deterministic body. ───────────────
        r = c.wait_for_handler("wb", "/bulk", want_status=200,
                               want_body=EXPECTED_BODY, timeout_s=25.0)
        check("wb/bulk upstream reachable + byte-exact",
              r.status == 200 and r.body == EXPECTED_BODY,
              f"status={r.status} len={len(r.body)}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "404",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        # ── 2. acme reachable. ────────────────────────────────────────
        r = c.wait_for_handler("acme", "/", want_status=200, timeout_s=25.0)
        check("acme reachable", r.status in (200, 404),
              f"got {r.status} {r.body!r}")

        # ── 3. THE bound fetch. ───────────────────────────────────────
        # acme fetches wb/bulk over loopback h2c; the wb.<suffix> Host
        # carries the tenant routing (bare 127.0.0.1 → 404).
        bulk_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/bulk"
        r = c.get("acme", f"/boundproxy?url={up.quote(bulk_url)}", timeout=30.0)
        if r.status != 200:
            check("/boundproxy → 200", False, f"status={r.status} body={r.body!r}")
            c.dump_node_log(grep=["boundproxy", "fetch", "chunk", "spool",
                                  "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        body = r.body
        parts = body.split("chunk:")
        if parts and parts[0] == "":
            parts = parts[1:]
        check("held client got ≥3 chunk frames", len(parts) >= 3,
              f"got {len(parts)} frames; body={body!r}" if len(parts) < 3 else
              f"{len(parts)} frames")

        rebuilt = "".join(parts)
        check("reconstructed body byte-exact", rebuilt == EXPECTED_BODY,
              f"got {len(rebuilt)}B want {len(EXPECTED_BODY)}B" if rebuilt != EXPECTED_BODY
              else f"{len(rebuilt)}B")
        if rebuilt != EXPECTED_BODY or len(parts) < 3:
            c.dump_node_log(grep=["boundproxy", "fetch", "chunk", "spool",
                                  "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS bound-fetch smoke (v2): on.fetch auto-binds; onFetchChunk "
          "streams each upstream chunk back to the held client")
    return 0


if __name__ == "__main__":
    sys.exit(main())
