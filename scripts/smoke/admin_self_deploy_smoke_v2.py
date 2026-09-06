#!/usr/bin/env python3
"""The deploy doors are exercised on the implementation PRODUCTION runs.

Every other deploy smoke bootstraps with `/_system/reset` and then deploys
through the BAKED `__admin__` app (`src/js/starter/genesis_admin.mjs`). Nothing
deployed through the *released dashboard* (`admin/index.mjs` in rewind-apps),
which is what every real publish goes through — so the two transcriptions of the
deploy protocol could disagree with the suite green. They did: the dashboard's
`buildResolution` dropped the `done` map, a package compiled during the cut
reached `stampManifest` with no `bytecode_hash`, and every package-importing
tenant became unpublishable (rove#554, `decisions.md` §11.5).

This smoke runs the SAME deploy twice — once through the baked app, once through
the dashboard after publishing it — so a divergence between them fails here
instead of at a production publish, where recovery costs a `/_system/reset` and
the operator UI with it.

The payload is chosen to force the path that broke: `@rewind/oidc` imports
`@rewind/jwt`, so it cannot be try-compiled when its file is staged and MUST be
compiled during the cut — which is exactly when a package's bytecode lives only
in `done`.

Needs a rewind-apps checkout (`REWIND_APPS_DIR`) for the real dashboard bundle,
and S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import APPS_DIR, V2Cluster, require_apps_dir  # noqa: E402

# Fail here, naming the setup step, rather than on a missing fixture file
# deep in main() — an unpopulated `web/` submodule is the default state of a
# clone made without --recursive.
require_apps_dir()

ADMIN_DIR = APPS_DIR / "admin"
if not (ADMIN_DIR / "index.mjs").exists():
    print(f"SKIP — no rewind-apps checkout at {APPS_DIR} (set REWIND_APPS_DIR)")
    raise SystemExit(77)  # run_all.SKIP_RC — reported "skip", never "pass"

# The dashboard's handler set (statics are irrelevant to the deploy doors).
ADMIN_FILES = {p: (ADMIN_DIR / p).read_text() for p in (
    "index.mjs", "_middlewares/index.mjs",
    "_rp/complete.mjs", "_rp/jwks.mjs", "v1/upload/index.mjs")}

# The target handler imports a package that imports another package, so the
# deploy cannot succeed without the cut-compile chain.
TARGET_SRC = """
import oidc from "@rewind/oidc";
export default function () {
  // Proves the package LINKED — a resolution that lost a package's bytecode
  // never gets here; the deploy refuses first.
  return { ok: typeof oidc.provider === "function" };
}
"""


def main() -> int:
    failures: list[str] = []

    def check(label: str, ok: bool, detail: str = "") -> None:
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{('  — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== deploy doors: baked app vs the released dashboard ===")
    with V2Cluster.spawn("admself", nodes=1) as c:
        # 1. Bootstrap: the BAKED deploy app becomes __admin__'s released bundle.
        c._ensure_admin_app()
        pkgs, imports = c.firstparty_packages(["@rewind/oidc"])

        # 2. CONTROL — a package-importing deploy through the baked app. This is
        #    the coverage every other deploy smoke already has.
        r = c.provision("viabaked")
        check("provision viabaked", r.status in (200, 409), f"got {r.status}")
        try:
            c.deploy_with_packages("viabaked", {"index.mjs": TARGET_SRC}, pkgs, imports)
            check("deploy through the BAKED app", True)
        except RuntimeError as e:
            check("deploy through the BAKED app", False, str(e))
            return 1  # the control failing means the harness, not the dashboard
        # Release is async — the loader fetches the manifest + bytecode and
        # swaps the snapshot after the marker lands.
        got = c.wait_for_handler("viabaked", want_body='"ok":true')
        check("baked-app deployment serves", got.status == 200 and '"ok":true' in got.body,
              f"{got.status} {got.body[:120]!r}")

        # 3. Publish the REAL dashboard onto __admin__. From here the deploy
        #    doors are served by admin/index.mjs — the production implementation.
        try:
            # Derived from admin/manifest.json, never hand-listed — see
            # `firstparty_packages_for_app`.
            c.deploy_with_packages("__admin__", ADMIN_FILES,
                                   *c.firstparty_packages_for_app(APPS_DIR / "admin"))
            check("publish the real dashboard onto __admin__", True)
        except RuntimeError as e:
            check("publish the real dashboard onto __admin__", False, str(e))
            return 1

        # 4. THE INVARIANT — the same deploy, now through the dashboard's doors.
        #    A divergence between the two transcriptions fails HERE.
        r = c.provision("viadash")
        check("provision viadash", r.status in (200, 409), f"got {r.status}")
        try:
            c.deploy_with_packages("viadash", {"index.mjs": TARGET_SRC}, pkgs, imports)
            check("deploy through the RELEASED DASHBOARD", True)
        except RuntimeError as e:
            check("deploy through the RELEASED DASHBOARD", False, str(e))
        got = c.wait_for_handler("viadash", want_body='"ok":true')
        check("dashboard-app deployment serves", got.status == 200 and '"ok":true' in got.body,
              f"{got.status} {got.body[:120]!r}")

        # 5. Admin root writes are dispatched activations: the raw
        #    operator createInstance and the domain assign each dispatch
        #    __system/root_kv_install against __root__ and PARK on the owed
        #    marker's resolution — the 201 is released only once the root
        #    write committed, and __root__'s log carries the activation.
        import json as _json
        import time as _time
        from smoke_lib_v2 import _curl
        node = c.node_url(0)
        auth = {"Authorization": f"Bearer {c.root_token}", "Host": c.admin_host(0)}
        r = _curl(f"{node}/v1/instances/rootwrite-probe", method="PUT", headers=auth)
        check("raw createInstance → 201 (parked on the root activation)",
              r.status == 201, f"got {r.status} {r.body[:160]!r}")
        r = _curl(f"{node}/v1/domains/rootwrite.example", method="PUT",
                  headers={**auth, "Content-Type": "application/json"},
                  data=_json.dumps({"instance_id": "rootwrite-probe"}))
        check("assignDomain → 201", r.status == 201, f"got {r.status} {r.body[:160]!r}")
        c.spawn_log_server()
        found = None
        deadline = _time.time() + 20.0
        while _time.time() < deadline:
            lr = c.log_get("__root__/list")
            if lr.status == 200 and "root_kv_install" in lr.body:
                found = lr
                break
            _time.sleep(0.5)
        check("the root writes landed as activations in __root__'s log",
              found is not None,
              "present" if found is not None
              else "absent after 20s — the writes left no account of themselves")

        # 6. Scoped kv is a dispatched activation too: the browse routes
        #    dispatch __system/scope_kv against the TARGET and park; the
        #    response is released from the engine-carried result. The write
        #    must land where the target's own handler reads it, the read
        #    must come back in the named spelling, and the target's log —
        #    not the admin's — carries the op. The target must be a
        #    PROVISIONED tenant (group + placement): a registry-row-only
        #    tenant (rootwrite-probe above) has no raft group, so a fire
        #    there is refused rather than run with evaporating writes.
        r = _curl(f"{node}/v1/instances/viadash/kv", method="PUT",
                  headers={**auth, "Content-Type": "application/json"},
                  data=_json.dumps({"key": "greet", "value": "hi"}))
        check("scoped kv PUT → 200 (parked on the target activation)",
              r.status == 200 and '"greet"' in r.body,
              f"got {r.status} {r.body[:160]!r}")
        r = _curl(f"{node}/v1/instances/viadash/kv?key=greet", headers=auth)
        check("scoped kv GET reads the row back", r.status == 200 and r.body == "hi",
              f"got {r.status} {r.body[:160]!r}")
        r = _curl(f"{node}/v1/instances/viadash/kv?prefix=", headers=auth)
        check("scoped kv LIST pages the named view",
              r.status == 200 and '"key":"greet"' in r.body and "_user/" not in r.body,
              f"got {r.status} {r.body[:200]!r}")
        found_kv = None
        deadline = _time.time() + 20.0
        while _time.time() < deadline:
            lr = c.log_get("viadash/list")
            if lr.status == 200 and "scope_kv" in lr.body:
                found_kv = lr
                break
            _time.sleep(0.5)
        check("the scoped ops landed as activations in the TARGET's log",
              found_kv is not None,
              "present" if found_kv is not None
              else "absent after 20s — the ops left no account of themselves")

    print()
    if failures:
        print(f"FAILURES ({len(failures)}): " + ", ".join(failures))
        return 1
    print("PASS — both deploy implementations publish a cut-compiled package")
    return 0


if __name__ == "__main__":
    sys.exit(main())
