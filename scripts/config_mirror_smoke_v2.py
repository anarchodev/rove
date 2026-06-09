#!/usr/bin/env python3
"""V2 port of `config_mirror_smoke.py` — the `_config/` → kv config surface
on the `V2Cluster` harness (branch `v2`).

WHAT THIS COVERS vs THE V1 SMOKE — read this before extending.

The V1 smoke exercised the *deploy-time* `_config/` → kv MIRROR
(`src/js/config_mirror.zig`, wired into the release POST): a seed deploy
carried `_config/oauth/google.json` as a **static** manifest entry, and
the worker mirrored its bytes into kv at `_config/oauth/google` on every
node. The mirror itself still runs at V2 release time (it's in the shared
`src/js`, called from `worker_dispatch.handleRelease`), so it is NOT a
V1-files-server-only mechanism.

This smoke drives the REAL deploy-time mirror. Producing a *static*
`_config/*.json` manifest entry needs the files-server-v2 presign manifest
flow (`PUT blobs/{hash}` → `POST /deployments` with `kind:"static"`); the
plain `/upload`+`/deploy` contract always compiles sources as `.handler`.
`V2Cluster.deploy_with_static` wraps that flow. The smoke deploys
`_config/oauth/google.json` as a static entry, the loader's
`reloadDeployment` runs `config_mirror.mirrorConfigToKv` (fetch the blob +
PROPOSE the `_config/oauth/google` row through raft), and we assert the
verbatim V1 `/cfg` handler then serves the mirrored row AND a direct
`/_system/v2-kv` GET reads the committed bytes back. The 404-before /
200-after transition proves the mirror (not a manual seed) populated kv.

Dropped from V1 (V2-irrelevant): TLS/https, leader-direct addressing /
discover_leader, seed_manifest, admin_origin_per_node, the offline
`loop46 kv-get` per-node reader (the V1 binary is retired; the v2-kv GET
reads the live store instead).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# The `_config/oauth/google.json` payload verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/_config/oauth/google.json).
CONFIG_JSON = json.dumps({
    "client_id": "smoke-google-client.apps.googleusercontent.com",
    "redirect_uri": "https://acme.test/oauth/google/callback",
    "scopes": ["openid", "email"],
    "marker": "from-config-mirror-smoke",
}, separators=(",", ":"))

CONFIG_KEY = "_config/oauth/google"

# The `/cfg` probe handler, verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/cfg/index.mjs).
CFG_SRC = r"""export default function () {
  const raw = kv.get("_config/oauth/google");
  if (raw == null) {
    response.status = 404;
    return "no _config/oauth/google row";
  }
  response.status = 200;
  response.headers = { "content-type": "application/json" };
  return raw;
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("config-mirror", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy the /cfg probe handler (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "cfg/index.mjs": CFG_SRC,
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

        # Before the config deploy, /cfg should 404 (no row yet) — proves the
        # handler actually reads kv rather than returning a static value.
        print("step 4: /cfg before the config deploy → 404 (no _config row yet)")
        r = c.get("acme", "/cfg")
        check("/cfg before config → 404", r.status == 404, f"got {r.status} {r.body!r}")

        # ── The real deploy-time mirror: re-deploy carrying the config as a
        # STATIC `_config/oauth/google.json` manifest entry. The loader's
        # `reloadDeployment` runs `config_mirror.mirrorConfigToKv`, which
        # fetches the static blob and PROPOSES the `_config/oauth/google` row
        # into the tenant's kv through raft — no manual seed.
        print("step 5: re-deploy with a STATIC _config/oauth/google.json entry "
              "(drives the deploy-time blob→kv mirror)")
        try:
            dep2 = c.deploy_with_static(
                "acme",
                {"index.mjs": READY_SRC, "cfg/index.mjs": CFG_SRC},
                {"_config/oauth/google.json": (CONFIG_JSON, "application/json")})
            check("deploy_with_static → dep_id", bool(dep2), f"dep_id={dep2}")
        except RuntimeError as e:
            check("deploy_with_static", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 6: ⭐ the mirror populated kv → /cfg serves the config")
        # The mirror runs on the loader thread (blob fetch + raft propose), so
        # poll until the row lands.
        got = None
        ok_cfg = False
        deadline = time.time() + 25.0
        while time.time() < deadline:
            r = c.get("acme", "/cfg")
            if r.status == 200:
                try:
                    if json.loads(r.body) == json.loads(CONFIG_JSON):
                        got = json.loads(r.body)
                        ok_cfg = True
                        break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.5)
        check("⭐ /cfg → 200 JSON matching the deployed config (mirror ran)",
              ok_cfg, f"got {r.status} {r.body!r}")
        if not ok_cfg:
            c.dump_node_log(grep=["config", "mirror", "kv", "cfg", "resolve",
                                  "404", "error", "warn"])

        print("step 7: direct /_system/v2-kv GET reads back the mirrored bytes")
        r = c.admin_kv_get("acme", CONFIG_KEY)
        check("v2-kv GET → 200 round-trip (mirror committed to kv)",
              r.status == 200 and json.loads(r.body) == json.loads(CONFIG_JSON),
              f"got {r.status} {r.body!r}")

        if got is not None:
            check("marker field round-tripped",
                  got.get("marker") == "from-config-mirror-smoke",
                  f"marker={got.get('marker')!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS config-mirror smoke (v2) — deploy-time blob→kv mirror drove "
          "the _config/oauth/google row; /cfg served it + v2-kv round-tripped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
