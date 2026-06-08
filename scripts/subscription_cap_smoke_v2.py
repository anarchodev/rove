#!/usr/bin/env python3
"""V2 port of `subscription_cap_smoke.py` — per-tenant held-subscription cap
(`docs/curl-multi-plan.md` Phase 3 / gap 2.5), on the `V2Cluster` harness.

The engine caps simultaneous held subscriptions at `HELD_MAX_PER_TENANT = 16`
(src/js/fetch_engine.zig). Submissions over the cap fire a single
`final: true, ok: false` event so the customer's handler runs once and can
surface the rejection (`sub/done/<id>` with ok=false), even though the
upstream (`wb/drip`) never closes on its own.

Flow / essential assertions (unchanged from V1):
  1. Open CAP held subscriptions against wb/drip (each returns a sub_id).
  2. Submit OVER_N more — beyond cap — and assert ≥1 surfaces as a defined
     rejection (`sub/done/<id>` present, ok=false).
  3. Assert rejected subscriptions got zero body chunks.
  4. Cancel everything for a clean teardown.

Handler JS reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/{acme,wb}/…`).

Dropped from V1 (V2-irrelevant): TLS/https, 3-node leader election /
discover_leader, and the `--dev-webhook-unsafe` worker flag (V2's fetch path
doesn't enforce the loopback/plaintext block — same as `subscription_smoke_v2`).

V2 addressing: /subscribe + /cancel_subscribe + /readkey are single-shot
(terminating) requests, so they ride the FRONT door. The held subscription's
upstream is `http://wb.<suffix>:<node_port>/drip`, fetched by acme's worker
over loopback h2c (the `wb.<suffix>` Host carries the tenant routing).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"

# Must match HELD_MAX_PER_TENANT in src/js/fetch_engine.zig
HELD_CAP = 16
OVER_N = 16


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


ACME_HANDLERS = {
    "index.mjs": _src("acme/index.mjs"),
    "subscribe/index.mjs": _src("acme/subscribe/index.mjs"),
    "subscribe_oc.mjs": _src("acme/subscribe_oc.mjs"),
    "cancel_subscribe/index.mjs": _src("acme/cancel_subscribe/index.mjs"),
    "readkey/index.mjs": _src("acme/readkey/index.mjs"),
}
WB_HANDLERS = {
    "index.mjs": _src("wb/index.mjs"),
    "drip/index.mjs": _src("wb/drip/index.mjs"),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("subcap", nodes=1) as c:
        print("step 1: provision + deploy acme (subscriber) and wb (drip upstream)")
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
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        # Warm BOTH tenants so wb/drip is loaded before acme subscribes.
        r = c.wait_for_handler("wb", "/", want_status=200, timeout_s=25.0)
        check("wb reachable", r.status == 200, f"got {r.status} {r.body!r}")
        r = c.wait_for_handler("acme", "/readkey?key=__warm", want_status=404,
                               timeout_s=25.0)
        check("acme reachable", r.status in (200, 404),
              f"got {r.status} {r.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "404",
                                  "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        print("ok  acme + wb both warm")

        # acme's worker fetches wb's drip over loopback; the `wb.<suffix>`
        # Host carries the tenant routing.
        drip_url = f"http://wb.{PUBLIC_SUFFIX}:{c.node_ports[0]}/drip"
        sub_path = f"/subscribe?url={up.quote(drip_url)}"

        # ── 1. Open CAP held subscriptions. ──────────────────────────────
        ids = []
        for i in range(HELD_CAP):
            r = c.get("acme", sub_path)
            if r.status != 200 or not r.body.strip():
                check(f"subscription #{i} → sub_id", False,
                      f"status={r.status} body={r.body!r}")
                c.dump_node_log(grep=["subscribe", "fetch", "held", "cap",
                                      "error", "warn"])
                print(f"\nFAILURES ({len(failures)}): {failures}")
                return 1
            ids.append(r.body.strip())
        check(f"opened {HELD_CAP} held subscriptions", len(ids) == HELD_CAP,
              f"got {len(ids)}")

        # Let the engine settle (each /subscribe hands the PendingFetch to the
        # engine asynchronously and bumps the held counter).
        time.sleep(0.5)

        # ── 2. Submit OVER_N more — beyond cap. ──────────────────────────
        over_ids = []
        for i in range(OVER_N):
            r = c.get("acme", sub_path)
            if r.status != 200 or not r.body.strip():
                check(f"over-cap subscription #{i} → sub_id", False,
                      f"status={r.status} body={r.body!r}")
                print(f"\nFAILURES ({len(failures)}): {failures}")
                return 1
            over_ids.append(r.body.strip())
        print(f"ok  submitted {OVER_N} over-cap subscriptions")

        # Wait for the defined rejections to land (sub/done/<id> ok=false).
        deadline = time.monotonic() + 6.0
        rejected_ids = set()
        while time.monotonic() < deadline and not rejected_ids:
            for oid in over_ids:
                if oid in rejected_ids:
                    continue
                rr = c.admin_kv_get("acme", f"sub/done/{oid}")
                if rr.status == 200 and rr.body.strip():
                    try:
                        if json.loads(rr.body).get("ok") is False:
                            rejected_ids.add(oid)
                    except (ValueError, TypeError):
                        pass
            if not rejected_ids:
                time.sleep(0.2)
        check("≥1 over-cap subscription rejected (final:true, ok:false)",
              bool(rejected_ids),
              f"{len(rejected_ids)}/{OVER_N} rejected")
        if not rejected_ids:
            c.dump_node_log(grep=["subscribe", "fetch", "held", "cap",
                                  "reject", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        print(f"ok  {len(rejected_ids)}/{OVER_N} over-cap subscriptions rejected")

        # ── 3. Rejected subscriptions got zero body chunks. ──────────────
        leaked = []
        for oid in rejected_ids:
            rr = c.admin_kv_get("acme", f"sub/chunk/{oid}/0")
            if rr.status == 200 and rr.body.strip():
                leaked.append(oid)
        check("rejected subscriptions received zero body chunks",
              not leaked,
              f"leaked chunks for {[x[:12] for x in leaked]}")

        # ── 4. Clean teardown — cancel every id issued. ──────────────────
        for sid in ids + over_ids:
            c.request("acme", f"/cancel_subscribe?id={sid}", method="POST")
        print(f"ok  cancelled all {len(ids) + len(over_ids)} submitted subscriptions")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS subscription-cap smoke (v2): per-tenant held-subscription "
          "cap (HELD_MAX_PER_TENANT) fires a defined rejection beyond N")
    return 0


if __name__ == "__main__":
    sys.exit(main())
