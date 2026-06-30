#!/usr/bin/env python3
"""V2 port of `on_fetch_smoke.py` — the `on.fetch` surface (handler-surface
Phase 3 slice 3a) on the `V2Cluster` harness (`smoke_lib_v2`).

`on.fetch(url, opts, {to})` is the connection-scoped outbound: it binds the
fetch to the held chain — each upstream chunk wakes the `{to}` export while
the chain holds the socket. Proves bind + `{to}` export override + chunk
resume WITHOUT stream.* output (the handler accumulates each chunk in kv and
returns the reconstructed body on the terminal chunk).

Two tenants on a single node:
  - `acme` `/onfetch?url=` binds a streaming on.fetch with `{to:onUpstream}`;
    each chunk appends to kv; the terminal chunk returns the reconstructed
    body. `/onfetchbuf?url=` does a non-streaming on.fetch (no `{to}`) whose
    whole body arrives in one `onFetchResult` activation.
  - `wb` `/bulk` serves a deterministic 170-byte ASCII body.

Handler JS reused VERBATIM from the V1 demo tenants
(`examples/loop46-demo-tenants/{acme/onfetch,acme/onfetchbuf,wb/bulk}/index.mjs`).

Essential assertions (unchanged from V1):
  - `/onfetch` → 200 with the upstream body reconstructed byte-exact
    (streaming bind + {to} export + per-chunk resume).
  - `/onfetchbuf` → 200 with the whole body byte-exact (non-streaming →
    conventional `onFetchResult` export).

Dropped from V1: TLS/https, leader election / discover_leader,
seed_manifest, --dev-webhook-unsafe. Fetch URLs target
`http://wb.<suffix>:<node_port>/bulk` over loopback h2c with the
`wb.<suffix>` Host carrying tenant routing.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


ACME_HANDLERS = {
    "index.mjs": _src("acme/index.mjs"),
    "onfetch/index.mjs": _src("acme/onfetch/index.mjs"),
    "onfetchbuf/index.mjs": _src("acme/onfetchbuf/index.mjs"),
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

    with V2Cluster.spawn("onfetch", nodes=1) as c:
        print("step 1: provision + deploy acme (on.fetch) and wb (bulk upstream)")
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

        bulk_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/bulk"

        # ── 3. THE on.fetch (streaming + {to:onUpstream}). ────────────
        r = c.get("acme", f"/onfetch?url={up.quote(bulk_url)}", timeout=30.0)
        if r.status != 200:
            check("/onfetch → 200", False, f"status={r.status} body={r.body!r}")
            c.dump_node_log(grep=["onfetch", "fetch", "chunk", "resolve",
                                  "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        check("on.fetch streaming bind reconstructs body byte-exact",
              r.body == EXPECTED_BODY,
              f"got {len(r.body)}B want {len(EXPECTED_BODY)}B" if r.body != EXPECTED_BODY
              else f"{len(r.body)}B")

        # ── 4. Non-streaming on.fetch → onFetchResult. ────────────────
        r = c.get("acme", f"/onfetchbuf?url={up.quote(bulk_url)}", timeout=30.0)
        if r.status != 200:
            check("/onfetchbuf → 200", False, f"status={r.status} body={r.body!r}")
            c.dump_node_log(grep=["onfetchbuf", "fetch", "result", "404",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        check("non-streaming on.fetch → onFetchResult whole body byte-exact",
              r.body == EXPECTED_BODY,
              f"got {len(r.body)}B want {len(EXPECTED_BODY)}B" if r.body != EXPECTED_BODY
              else f"{len(r.body)}B")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS on.fetch smoke (v2): streaming bind + {to} export resume; "
          "non-streaming → onFetchResult")
    return 0


if __name__ == "__main__":
    sys.exit(main())
