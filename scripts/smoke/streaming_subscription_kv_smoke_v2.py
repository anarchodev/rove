#!/usr/bin/env python3
"""V2 port of `streaming_subscription_kv_smoke.py` — kv-react subscription
chain origin (Gap 2.1 Phase E), on the `V2Cluster` harness.

`acme/_subscriptions/sub-react/{spec.json,index.mjs}` declares a kv-react
subscription on prefix `sub-react-in/`. On a write under that prefix the
runtime's apply-time hook fires the subscription handler (`onSubscription`),
which reads `request.activation.source = {kind:"kv",key,op}` and writes a
marker to `sub-react-out/<key-tail>`. No inbound HTTP request drives it —
the chain origin runs purely from the apply-time hook (leader-gated; single
node here is always leader).

Subscription module + writekv/readkey JS reused VERBATIM from the V1 demo
tenant (`examples/loop46-demo-tenants/acme/…`).

Essential assertions kept from V1:
  1. POST sub-react-in/k1=hello via /writekv → subscription fires →
     `sub-react-out/k1` == "put:hello" (chain origin fired + source payload
     correctly populated).
  2. A second write fires the subscription again (sub-react-out/k2 ==
     "put:world") — proves the apply-time hook re-fires.

Dropped from V1: TLS/https, 3-node leader/follower addressing (single-node
behavior smoke). The trigger write goes DIRECT to the node (`node_request`)
to dodge front-door head-of-line; side-effect keys are read via the worker's
move-secret-gated `admin_kv_get`.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants" / "acme"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# Subscription module + handlers reused verbatim from the V1 demo tenant.
# spec.json MUST deploy as `static` (the loader skips non-static specs) — so
# this is a content-addressed manifest deploy with explicit per-file kinds.
HANDLERS = {
    "index.mjs": ("handler", rpc_wrap(_src("index.mjs"))),
    "writekv/index.mjs": ("handler", _src("writekv/index.mjs")),
    "readkey/index.mjs": ("handler", _src("readkey/index.mjs")),
    "_subscriptions/sub-react/index.mjs":
        ("handler", _src("_subscriptions/sub-react/index.mjs")),
    "_subscriptions/sub-react/spec.json":
        ("static", _src("_subscriptions/sub-react/spec.json")),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("sub-kv", nodes=1) as c:
        print("step 1: provision + deploy acme (sub-react kv subscription)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_manifest("acme", HANDLERS)
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # Wait for the deployment to load + serve.
        r = c.wait_for_handler("acme", "/?fn=handler", want_status=200,
                               timeout_s=25.0)
        if r.status != 200:
            check("acme reachable", False, f"got {r.status} {r.body!r}")
            c.dump_node_log(grep=["deploy", "loader", "manifest", "subscription",
                                  "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  acme reachable")

        # ── 1. Trigger write → subscription fires. ────────────────────
        # DIRECT to the node so the apply-time hook fires on this node and
        # the write doesn't queue behind anything at the front door.
        r = c.node_request("/writekv", method="POST", host=c.host_for("acme"),
                           headers={"Content-Type": "application/json"},
                           data=json.dumps({"key": "sub-react-in/k1",
                                            "value": "hello"}))
        check("triggering write posted (sub-react-in/k1=hello)",
              r.status == 204, f"got {r.status} {r.body!r}")

        marker = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "sub-react-out/k1")
            if rr.status == 200 and rr.body.strip():
                marker = rr.body.strip()
                break
            time.sleep(0.4)
        check("kv subscription fired (sub-react-out/k1 == put:hello)",
              marker == "put:hello",
              f"marker={marker!r}" if marker is not None else "marker absent after 20s")
        if marker != "put:hello":
            c.dump_node_log(grep=["subscription", "kv", "wake", "apply",
                                  "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        # ── 2. Second write fires the subscription again. ─────────────
        r = c.node_request("/writekv", method="POST", host=c.host_for("acme"),
                           headers={"Content-Type": "application/json"},
                           data=json.dumps({"key": "sub-react-in/k2",
                                            "value": "world"}))
        check("second write posted (sub-react-in/k2=world)",
              r.status == 204, f"got {r.status} {r.body!r}")

        marker2 = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "sub-react-out/k2")
            if rr.status == 200 and rr.body.strip():
                marker2 = rr.body.strip()
                break
            time.sleep(0.4)
        check("kv subscription re-fires (sub-react-out/k2 == put:world)",
              marker2 == "put:world",
              f"marker={marker2!r}" if marker2 is not None else "marker absent after 20s")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming-subscription-kv smoke (v2): kv-react chain origin "
          "fires on apply-time hook, no inbound HTTP request")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
