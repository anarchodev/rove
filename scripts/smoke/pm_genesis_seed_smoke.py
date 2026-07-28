#!/usr/bin/env python3
"""P-Lift genesis seed (rove#123) end to end: `rewind-ops seed-packages`
publishes the 12 first-party @rewind/* packages into the REAL registry app.

This proves the package-registry bootstrap: the first-party set must exist in
the `registry` tenant before any consumer deploys (the
auth→oidc→registry-package→registry-needs-publishing cycle). The seed drives the
registry's own /v1/publish with an operator token — so the registry hashes +
writes each package with its OWN code (one canonical pkg_hash, zero divergence).

Flow (single node, front-routed reads):
  1. spawn a cluster + provision the `registry` tenant.
  2. deploy the REAL rewind-apps/registry app (handlers + _config OIDC mirror).
  3. `rewind-ops seed-packages` → kv-put sha256(root_token) as the operator-token
     hash, then POST each package SOURCE leaves-first (jwt before oauth/oidc).
  4. assert all 12 list via GET /v1/packages.
  5. assert POST /v1/resolve freezes @rewind/oidc's dep to the seeded jwt — the
     leaves-first ordering + dep-encapsulation actually worked.

Run:  set -a; . ./.env; set +a
      zig build rewind-worker rewind-cp rewind-front rewind-ops -Doptimize=ReleaseFast
      python3 scripts/smoke/pm_genesis_seed_smoke.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, ROOT_TOKEN  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
OPS = REPO_ROOT / "zig-out" / "bin" / "rewind-ops"


def _find_registry_dir() -> Path:
    """Locate rewind-apps/registry. Works from the main checkout or a
    `.claude/worktrees/<name>` worktree (rewind-apps is a sibling of the real
    rove root, not of the worktree). REWIND_APPS_DIR overrides."""
    override = os.environ.get("REWIND_APPS_DIR")
    cands = []
    if override:
        cands.append(Path(override) / "registry")
    # walk up from here; at each level try a sibling rewind-apps/registry.
    for p in Path(__file__).resolve().parents:
        cands.append(p.parent / "rewind-apps" / "registry")
    for cand in cands:
        if cand.is_dir():
            return cand
    raise SystemExit("registry app not found — need a rewind-apps checkout "
                     "beside the rove root (or set REWIND_APPS_DIR)")


REGISTRY_DIR = _find_registry_dir()

# The 12 first-party packages the seed publishes (must match ops.zig
# SEED_PACKAGES). Listed here only to assert the registry ends up serving them.
EXPECT_SPECS = [
    "@rewind/jwt", "@rewind/cron", "@rewind/email", "@rewind/sessions",
    "@rewind/retry", "@rewind/activitypub", "@rewind/users", "@rewind/segments",
    "@rewind/schedule", "@rewind/browser", "@rewind/oauth", "@rewind/oidc",
]


def _load_registry_app() -> tuple[dict, dict]:
    """Read the real registry bundle from rewind-apps → (handlers, statics)."""
    if not REGISTRY_DIR.is_dir():
        raise SystemExit(f"registry app not found at {REGISTRY_DIR} — need the "
                         "rewind-apps checkout beside rove")
    handlers = {
        "index.mjs": (REGISTRY_DIR / "index.mjs").read_text(),
        "_middlewares/index.mjs": (REGISTRY_DIR / "_middlewares/index.mjs").read_text(),
    }
    # _config/oidc/rp/default.json config-mirrors to the kv key the middleware's
    # oidc.rp("default") reads (mirror strips the .json).
    rp_cfg = (REGISTRY_DIR / "_config/oidc/rp/default.json").read_text()
    statics = {"_config/oidc/rp/default.json": (rp_cfg, "application/json")}
    return handlers, statics


def main() -> int:
    handlers, statics = _load_registry_app()

    with V2Cluster.spawn("pmseed", nodes=1, http_base=18700, raft_base=18800) as c:
        reg_host = c.host_for("registry")  # registry.localhost

        # ── stand up the real registry app ──
        c.provision("registry", host=reg_host)
        c.deploy_with_static("registry", handlers, statics)
        # release apply + S3 manifest/bytecode fetch is async → poll.
        r = c.wait_for_handler("registry", "/v1/packages")
        assert r.status == 200, f"registry /v1/packages not live: {r.status} {r.body!r}"
        print("  ok   real registry app deployed + serving /v1/packages")

        # ── drive the operator seed (P2 binary) ──
        env_file = f"/tmp/pmseed-{os.getpid()}.env"
        worker_urls = ",".join(c.node_url(i) for i in range(1))
        with open(env_file, "w") as f:
            f.write(f"ROVE_WORKER_URLS={worker_urls}\n")
            f.write(f"REWIND_MOVE_SECRET={MOVE_SECRET}\n")
            f.write(f"REWIND_ROOT_TOKEN={ROOT_TOKEN}\n")
            f.write("REWIND_ADMIN_DOMAIN=n1.localhost\n")
            f.write(f"REWIND_REGISTRY_DOMAIN={reg_host}\n")
            f.write(f"ROVE_CLUSTER={c.cluster_id}\n")

        print(f"\nrunning: rewind-ops seed-packages --env {env_file}\n")
        p = subprocess.run([str(OPS), "seed-packages", "--env", env_file],
                           capture_output=True, text=True, timeout=180)
        out = p.stdout + p.stderr  # rewind-ops logs via std.debug.print (stderr)
        print(out)
        if p.returncode != 0:
            print(f"\nFAIL — seed-packages exited {p.returncode}")
            return 1
        assert "genesis package seed complete" in out, "seed did not report completion"

        # ── assert all 12 are published + discoverable ──
        listing = c.get("registry", "/v1/packages")
        assert listing.status == 200, f"list: {listing.status} {listing.body!r}"
        missing = [s for s in EXPECT_SPECS if s not in listing.body]
        assert not missing, f"registry missing seeded packages: {missing}\n{listing.body}"
        print(f"  ok   all {len(EXPECT_SPECS)} first-party packages listed")

        # ── assert dep-freezing: oidc resolves WITH its frozen jwt dependency ──
        res = c.request("registry", "/v1/resolve", method="POST",
                        data=json.dumps({"dependencies": {"@rewind/oidc": "^1.0"}}))
        assert res.status == 200, f"resolve: {res.status} {res.body!r}"
        body = res.body
        assert "@rewind/oidc" in body and "@rewind/jwt" in body, (
            f"resolve did not return oidc + its frozen jwt dep (leaves-first "
            f"ordering broken?):\n{body}")
        print("  ok   @rewind/oidc resolves with its frozen @rewind/jwt dependency")

        print("\nPASS — `rewind-ops seed-packages` seeded the 12 first-party "
              "packages into the real registry; all resolve. ⭐")
        return 0


if __name__ == "__main__":
    sys.exit(main())
