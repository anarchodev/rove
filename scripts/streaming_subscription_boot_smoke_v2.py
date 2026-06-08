#!/usr/bin/env python3
"""V2 port of `streaming_subscription_boot_smoke.py` — boot subscription
chain origin firing on deployment activation (Gap 2.1 Phase D), on the
`V2Cluster` harness.

`acme/_subscriptions/migrate-v1/{spec.json,index.mjs}` declares a boot
subscription (`{"kind":"boot"}`). On first deploy-load the deployment loader
(leader-gated; single node here is always leader) enqueues a boot fire to the
worker; the handler (`onBoot`) reads
`request.activation.source.deployment_id`, increments `boot-fire-count` and
writes `boot-fired-marker = "dep=<id> count=<n>"`. The runtime then writes
`_boot_fired/<dep_id> = "fired"` to gate re-fires.

Subscription module + handlers reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/…`).

Essential assertions kept from V1:
  1. `boot-fired-marker` appears with `count=1` (handler fired exactly once)
     and carries a `dep=` prefix.
  2. `_boot_fired/<dep_id>` gate marker == "fired" (runtime wrote the
     post-fire gate, so reloads won't re-fire).
  3. The boot stays at count=1 across follow-up requests (no re-fire).

Dropped from V1: TLS/https, 3-node leader election / discover_leader
(single-node behavior smoke). Side-effect keys are read via the worker's
move-secret-gated `admin_kv_get`.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants" / "acme"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# Subscription module + handlers reused verbatim from the V1 demo tenant.
# spec.json MUST deploy as `static` (the loader skips non-static specs).
HANDLERS = {
    "index.mjs": ("handler", _src("index.mjs")),
    "readkey/index.mjs": ("handler", _src("readkey/index.mjs")),
    "_subscriptions/migrate-v1/index.mjs":
        ("handler", _src("_subscriptions/migrate-v1/index.mjs")),
    "_subscriptions/migrate-v1/spec.json":
        ("static", _src("_subscriptions/migrate-v1/spec.json")),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("sub-boot", nodes=1) as c:
        print("step 1: provision + deploy acme (migrate-v1 boot subscription)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_manifest("acme", HANDLERS)
            check("deploy_manifest → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_manifest", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # Wait for the deployment to load + serve before asserting the fire.
        r = c.wait_for_handler("acme", "/?fn=handler", want_status=200,
                               timeout_s=25.0)
        if r.status != 200:
            check("acme reachable", False, f"got {r.status} {r.body!r}")
            c.dump_node_log(grep=["deploy", "loader", "manifest", "boot",
                                  "subscription", "resolve", "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        print("ok  acme reachable")

        # ── 1. boot-fired-marker appears with count=1. ────────────────
        marker = None
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "boot-fired-marker")
            if rr.status == 200 and rr.body.strip():
                marker = rr.body.strip()
                break
            time.sleep(0.4)
        if marker is None:
            check("boot subscription fired (boot-fired-marker present)", False,
                  "marker absent after 20s")
            c.dump_node_log(grep=["boot", "subscription", "loader", "fire",
                                  "wake", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1
        check("boot fired exactly once (count=1)", "count=1" in marker,
              f"marker={marker!r}")
        check("boot marker carries dep= prefix", "dep=" in marker,
              f"marker={marker!r}")

        dep_id_str = None
        for p in marker.split():
            if p.startswith("dep="):
                dep_id_str = p[4:]
                break
        check("boot marker has a dep= value", dep_id_str is not None,
              f"marker={marker!r}")

        # ── 2. runtime gate marker _boot_fired/<dep_id> == "fired". ────
        if dep_id_str is not None:
            gate = None
            deadline = time.monotonic() + 20.0
            while time.monotonic() < deadline:
                rr = c.admin_kv_get("acme", f"_boot_fired/{dep_id_str}")
                if rr.status == 200 and rr.body.strip():
                    gate = rr.body.strip()
                    break
                time.sleep(0.4)
            check("runtime gate marker _boot_fired/<dep_id> == 'fired'",
                  gate == "fired",
                  f"gate={gate!r}" if gate is not None else "gate absent after 20s")

        # ── 3. boot stays at count=1 across follow-up requests. ───────
        for _ in range(3):
            c.get("acme", "/?fn=handler")
        time.sleep(0.5)
        rr = c.admin_kv_get("acme", "boot-fired-marker")
        check("boot remained at count=1 (no re-fire on follow-up requests)",
              rr.status == 200 and "count=1" in rr.body,
              f"marker={rr.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS streaming-subscription-boot smoke (v2): boot chain origin "
          "fires once on deployment activation + runtime-managed gate marker")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
