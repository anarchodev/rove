#!/usr/bin/env python3
"""V2 port of `streaming_smoke.py` — single-shot `stream.*` exerciser
(handler-surface Phase 2) on the `V2Cluster` harness (`smoke_lib_v2`).

The `acme/stream` handler writes three SSE frames via `stream.write()` and
closes with a terminal `return ""`. The three buffered chunks ship as one
concatenated body (terminal-close prepends the chunks to the terminal body).
The smoke verifies all three chunks land in the body verbatim and that the
declared `Content-Type` / `Cache-Control` headers reach the wire.

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader election /
discover_leader, seed_manifest (V2 provisions + deploys explicitly). The
handler JS is reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/stream/index.mjs`).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# A trivial root readiness probe (acme's real index.mjs exports `handler`,
# served via /?fn=handler — but /stream is the path under test).
READY_SRC = 'export function handler() { return "ready"; }\n'

EXPECTED_BODY = (
    "event: tick\ndata: alpha\n\n"
    "event: tick\ndata: bravo\n\n"
    "event: tick\ndata: charlie\n\n"
)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("strm", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy stream handler (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "stream/index.mjs": _src("acme/stream/index.mjs"),
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load (GET / → 'ready')")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: GET /stream — the single-shot stream handler")
        r = c.get("acme", "/stream")
        check("GET /stream → 200", r.status == 200, f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "stream", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        # Body: the three SSE frames, concatenated verbatim.
        check("body == three concatenated `event: tick` frames",
              r.body == EXPECTED_BODY,
              f"expected {EXPECTED_BODY!r} got {r.body!r}")

        # Headers from stream.headers reached the wire.
        ct = r.headers.get("content-type", "")
        check("Content-Type == text/event-stream", "text/event-stream" in ct,
              f"got {ct!r}")
        cc_hdr = r.headers.get("cache-control", "")
        check("Cache-Control == no-cache", "no-cache" in cc_hdr,
              f"got {cc_hdr!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming smoke (v2): single-shot stream.* JS shape "
          "reaches the wire (three frames concatenated + headers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
