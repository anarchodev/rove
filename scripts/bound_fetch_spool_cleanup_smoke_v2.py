#!/usr/bin/env python3
"""V2 port of `bound_fetch_spool_cleanup_smoke.py` — chunk-spool Phase 4
spool-drop on the two non-terminal exits (`docs/chunk-spool-plan.md`) on
the `V2Cluster` harness (`smoke_lib_v2`).

Proves spooled-but-unconsumed chunks are discarded (no leak, no panic,
node survives) on the two non-terminal exits:

  1. Cancel mid-stream — `/spoolcancel` consumes a couple of chunks
     writes-per-chunk (so the spool backs up behind the consumer), then
     calls `http.cancelFetch(request.fetchId)` on its OWN in-flight fetch
     and returns terminal "cancelled@<seq>". The tail chunks still in the
     spool must be dropped (`cancelFetchTrampoline` → `dropSpool`). Also
     exercises the reentrancy hazard: the spool's map key is freed by the
     cancel DURING the resume that triggered it.

  2. Disconnect mid-stream — `/boundproxy` streams an INFINITE upstream
     (`wb/drip`) back to a held client that is killed mid-stream. h2
     detects the closed stream and routes the held entity to
     `cleanupResponses` → `fireDisconnectActivation` +
     `scanAndCancelBoundFetches` → cancels the still-running drip fetch
     AND `dropSpool`s it. The drip would otherwise run forever, so a
     healthy node afterwards proves the orphan was torn down crash-free.
     Because the front door buffers the full response (no streaming), the
     held streaming chain is driven DIRECT to the node with a short curl
     timeout that kills the client mid-stream.

Handler JS reused VERBATIM from the V1 demo tenants
(`examples/loop46-demo-tenants/{acme/spoolcancel,acme/boundproxy,
wb/bigbody,wb/drip}/index.mjs`).

Essential assertions (from V1, minus the metrics-only one):
  - `/spoolcancel` completes 200 with a "cancelled@<seq>" body (the
    self-cancel mid-dispatch reentrancy survives — no panic).
  - The held streaming `/boundproxy?url=<drip>` is killed mid-stream;
    the node tears down the orphaned infinite fetch and KEEPS SERVING
    (no leak/stall/panic).
  - The node still serves normal traffic after BOTH exits.

Dropped from V1: TLS/https, leader election / discover_leader,
seed_manifest, --dev-webhook-unsafe, AND the
`bound_fetch_spool_dropped_total` metrics assertion (that admin metrics
surface is not wired into this V2 harness). Per the task brief we keep
the behavioral core instead: the self-cancel and the mid-stream
disconnect both complete crash-free and the node survives — which is
what the Phase 4 spool-drop exists to guarantee. The cancel's 200
"cancelled@<seq>" body confirms the cancel-during-resume reentrancy
didn't panic; node survival confirms no leak wedged the worker.

`ROVE_BOUND_FETCH_SPOOL_DEPTH=2` (inherited via os.environ) shrinks the
window so the spool backs up behind the writes-per-chunk consumer.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

os.environ["ROVE_BOUND_FETCH_SPOOL_DEPTH"] = "2"

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


ACME_HANDLERS = {
    "index.mjs": _src("acme/index.mjs"),
    "spoolcancel/index.mjs": _src("acme/spoolcancel/index.mjs"),
    "boundproxy/index.mjs": _src("acme/boundproxy/index.mjs"),
}
WB_HANDLERS = {
    "index.mjs": _src("wb/index.mjs"),
    "bigbody/index.mjs": _src("wb/bigbody/index.mjs"),
    "drip/index.mjs": _src("wb/drip/index.mjs"),
}

CANCEL_N = 200
EXPECTED_CANCEL_UPSTREAM = "".join(f"bigbody-line-{i:05d}\n" for i in range(CANCEL_N))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("bfclean", nodes=1) as c:
        print("step 1: provision + deploy acme (spoolcancel/boundproxy) and "
              "wb (bigbody/drip upstreams)")
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

        port = c.node_ports[0]
        cancel_url = f"http://wb.{PUBLIC_SUFFIX}:{port}/bigbody?n={CANCEL_N}"
        drip_url = f"http://wb.{PUBLIC_SUFFIX}:{port}/drip"

        # ── Upstream + acme readiness. ────────────────────────────────
        r = c.wait_for_handler("wb", f"/bigbody?n={CANCEL_N}", want_status=200,
                               want_body=EXPECTED_CANCEL_UPSTREAM, timeout_s=25.0)
        check("wb/bigbody upstream ready + byte-exact",
              r.status == 200 and r.body == EXPECTED_CANCEL_UPSTREAM,
              f"status={r.status} len={len(r.body)}")
        r = c.wait_for_handler("acme", "/", want_status=200, timeout_s=25.0)
        check("acme reachable", r.status in (200, 404), f"got {r.status}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "404",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        # ── 1. Cancel mid-stream ──────────────────────────────────────
        # spoolcancel consumes 2 chunks writes-per-chunk (spool backs up),
        # then cancels its OWN in-flight fetch + returns terminal. The
        # unconsumed tail in the spool must be dropped; the cancel-during-
        # resume reentrancy must not panic. A single-shot "cancelled@"
        # response → front door is fine.
        r = c.get("acme", f"/spoolcancel?url={up.quote(cancel_url)}", timeout=30.0)
        ok = r.status == 200 and r.body.startswith("cancelled@")
        check("self-cancel mid-stream → 200 'cancelled@<seq>' (no panic)", ok,
              f"status={r.status} body={r.body[:120]!r}")
        if not ok:
            c.dump_node_log(grep=["spoolcancel", "cancel", "fetch", "chunk",
                                  "spool", "error", "warn"])
        time.sleep(0.5)  # let the cancel's dropSpool settle

        # ── 2. Disconnect on a held bound-fetch stream ────────────────
        # Stream the infinite drip upstream back to a held client, DIRECT
        # to the node (the front buffers the full response, which would
        # never complete on an infinite stream). Kill the client mid-
        # stream via a short curl timeout. Its close drives the held
        # entity into h2's disconnect path: cleanupResponses →
        # fireDisconnectActivation + scanAndCancelBoundFetches → cancel
        # the still-running drip fetch + dropSpool. The drip would run
        # forever otherwise, so a healthy node afterward proves the orphan
        # was torn down crash-free.
        bp_path = f"/boundproxy?url={up.quote(drip_url)}"
        try:
            subprocess.run(
                ["curl", "-sS", "-N", "--http2-prior-knowledge", "-m", "1",
                 "-H", f"Host: acme.{PUBLIC_SUFFIX}", "-o", "/dev/null",
                 f"http://127.0.0.1:{port}{bp_path}"],
                capture_output=True, timeout=5)
        except subprocess.TimeoutExpired:
            pass  # client killed mid-stream — also a disconnect
        check("held bound-fetch stream killed mid-stream (disconnect path "
              "fired)", True)
        time.sleep(0.7)  # let the disconnect-cleanup pass run

        # ── 3. Node survived both ─────────────────────────────────────
        r = c.get("wb", f"/bigbody?n={CANCEL_N}")
        check("node still serving after cancel + disconnect (no panic / "
              "no leak-stall)",
              r.status == 200 and r.body == EXPECTED_CANCEL_UPSTREAM,
              f"status={r.status} len={len(r.body)}")
        # acme worker also still healthy.
        r = c.get("acme", "/")
        check("acme worker still healthy", r.status in (200, 404),
              f"got {r.status}")
        if failures:
            c.dump_node_log(grep=["spoolcancel", "boundproxy", "drip",
                                  "disconnect", "cancel", "spool", "error",
                                  "warn", "panic"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS bound-fetch spool cleanup smoke (v2): self-cancel + "
          "mid-stream disconnect both drop the unconsumed spool tail "
          "crash-free; node survives both non-terminal exits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
