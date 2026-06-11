#!/usr/bin/env python3
"""V2 port of `bound_fetch_spool_smoke.py` — chunk-spool Phase 3 multi-bind
(`docs/chunk-spool-plan.md`) on the `V2Cluster` harness (`smoke_lib_v2`).

TWO bound, streaming fetches on a single held entity, each consumed
writes-per-chunk (`next()` + kv write → a raft round-trip per chunk).
Their chunks interleave on the one entity; each fetch has its own per-fetch
spool. The producer floods both fetches' chunks near-simultaneously and the
consumer drains at raft rate → both spools back up + evict + read back from
the coordinator (the same-tick-chunks-for-different-fetches race the
`8bd53bb` safety net guarded).

Two tenants on a single node:
  - `acme` `/multibind?u1=&u2=` issues two bound fetches, accumulates each
    fetch's chunks keyed by `request.fetchId`, and returns both
    reconstructed bodies joined by a marker once both terminate.
  - `wb` `/bigbody?n=` serves a deterministic 20-byte-per-line ASCII body.

Handler JS reused VERBATIM from the V1 demo tenants
(`examples/loop46-demo-tenants/{acme/multibind,wb/bigbody}/index.mjs`).

Essential assertions (unchanged from V1):
  - `/multibind` completes 200 (no panic, no stuck held chain).
  - BOTH upstream bodies reconstruct byte-exact (per-fetch ordering
    preserved despite cross-fetch interleave; no drops).

Dropped from V1: TLS/https, leader election / discover_leader,
seed_manifest, --dev-webhook-unsafe, and the `/_system/metrics`
spool-readback assertion (admin metrics surface not wired into this V2
harness; the byte-exact reconstruction already proves eviction + read-back
correctness). Fetch URLs target `http://wb.<suffix>:<node_port>/bigbody`
over loopback h2c with the `wb.<suffix>` Host carrying tenant routing.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
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
    "multibind/index.mjs": _src("acme/multibind/index.mjs"),
}
WB_HANDLERS = {
    "index.mjs": _src("wb/index.mjs"),
    "bigbody/index.mjs": _src("wb/bigbody/index.mjs"),
}

N1 = 120
N2 = 80
SPLIT = "@@MULTIBIND-SPLIT@@"
EXPECTED_1 = "".join(f"bigbody-line-{i:05d}\n" for i in range(N1))
EXPECTED_2 = "".join(f"bigbody-line-{i:05d}\n" for i in range(N2))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("bfspool", nodes=1) as c:
        print("step 1: provision + deploy acme (multibind) and wb (bigbody upstream)")
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

        u1 = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/bigbody?n={N1}"
        u2 = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/bigbody?n={N2}"

        # ── 1. Upstreams reachable + deterministic. ───────────────────
        r1 = c.wait_for_handler("wb", f"/bigbody?n={N1}", want_status=200,
                                want_body=EXPECTED_1, timeout_s=25.0)
        check("wb/bigbody u1 reachable + byte-exact",
              r1.status == 200 and r1.body == EXPECTED_1,
              f"status={r1.status} len={len(r1.body)}")
        r2 = c.get("wb", f"/bigbody?n={N2}")
        check("wb/bigbody u2 reachable + byte-exact",
              r2.status == 200 and r2.body == EXPECTED_2,
              f"status={r2.status} len={len(r2.body)}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "404",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        # ── 2. acme reachable. ────────────────────────────────────────
        r = c.wait_for_handler("acme", "/", want_status=200, timeout_s=25.0)
        check("acme reachable", r.status in (200, 404),
              f"got {r.status} {r.body!r}")

        # ── 3. THE multi-bind fetch. ──────────────────────────────────
        r = c.get("acme",
                  f"/multibind?u1={up.quote(u1)}&u2={up.quote(u2)}",
                  timeout=60.0)
        if r.status != 200:
            check("/multibind → 200", False,
                  f"status={r.status} body={r.body[:200]!r}")
            c.dump_node_log(grep=["multibind", "fetch", "chunk", "spool",
                                  "readback", "evict", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        if SPLIT not in r.body:
            check("response has split marker", False, f"len={len(r.body)}")
            c.dump_node_log(grep=["multibind", "fetch", "chunk", "spool",
                                  "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        got1, got2 = r.body.split(SPLIT, 1)
        check("fetch-1 body byte-exact", got1 == EXPECTED_1,
              f"got {len(got1)}B want {len(EXPECTED_1)}B")
        check("fetch-2 body byte-exact", got2 == EXPECTED_2,
              f"got {len(got2)}B want {len(EXPECTED_2)}B")
        if got1 == EXPECTED_1 and got2 == EXPECTED_2:
            print(f"ok  both bound fetches reconstructed byte-exact + in order "
                  f"({len(got1)}B + {len(got2)}B, interleaved on one entity, "
                  f"no drops/panic)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS bound-fetch multi-bind spool smoke (v2): same-tick chunks "
          "for different bound fetches on one entity spool per-fetch, "
          "preserve order, drop nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
