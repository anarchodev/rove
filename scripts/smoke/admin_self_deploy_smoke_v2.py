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

from smoke_lib_v2 import APPS_DIR, V2Cluster  # noqa: E402

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
            c.deploy_with_packages("__admin__", ADMIN_FILES, *c.firstparty_packages(
                ["@rewind/oidc", "@rewind/email"]))
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

    print()
    if failures:
        print(f"FAILURES ({len(failures)}): " + ", ".join(failures))
        return 1
    print("PASS — both deploy implementations publish a cut-compiled package")
    return 0


if __name__ == "__main__":
    sys.exit(main())
