#!/usr/bin/env python3
"""`rewind-ops deploy` publishes a bundle that IMPORTS a package (rove#477).

The operator CLI had no consumer-side package resolution: it staged handlers and
statics, then cut — so any bundle with a bare `@rewind/*` import failed at cut
with `could not load module '@rewind/…'`. Only the customer `rewind` CLI
(`pm_cli_smoke`) and the smoke harness could publish one, which meant the
operator path could not republish `admin` or `auth` — both of which import
`@rewind/oidc`. It was found the hard way: a platform deploy left production's
dashboard on the baked app because the republish could not run.

The engine side was already complete — `/v1/deploy/pkgfile` and cut's
`resolution` have existed since rove#344. Only the driver was missing.

This is the end-to-end guard for that path, through the REAL binaries:

  1. stand up the real registry app and `rewind-ops seed-packages` into it;
  2. `rewind-ops deploy` a bundle whose handler imports a seeded package;
  3. assert the tenant SERVES the imported package's behaviour — not merely
     that the deploy returned 0, because a resolution that staged nothing would
     still cut cleanly if the import happened to be unused.

Needs S3 env: `set -a; . ./.env; set +a` first, and a rewind-apps checkout for
the registry app.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, ROOT_TOKEN, BIN_DIR  # noqa: E402
from pm_genesis_seed_smoke import _load_registry_app  # noqa: E402

TENANT = "pkgconsumer"

# Imports a seeded first-party package by BARE specifier — the thing that could
# not be deployed. `@rewind/jwt` is a leaf (no intra-set dependency), so a
# failure here is about resolution, not about dependency ordering.
HANDLER = """
import { decode } from "@rewind/jwt";

export default function () {
  // Proves the package's CODE is present and callable, not merely that the
  // specifier resolved at compile time. `decode` is pure (no keys, no clock),
  // so the assertion is about the import working, nothing else.
  const t = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJvayJ9.sig";
  const out = decode(t);
  response.status = 200;
  return "sub=" + String(out && out.payload && out.payload.sub);
}
"""

BUNDLE_MANIFEST = """{
  "name": "pkgconsumer",
  "version": "1.0.0",
  "dependencies": { "@rewind/jwt": "^1.0.0" }
}
"""


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    handlers, statics = _load_registry_app()

    with V2Cluster.spawn("pmopsdeploy", nodes=1) as c:
        reg_host = c.host_for("registry")
        c.provision("registry", host=reg_host)
        c.deploy_with_static("registry", handlers, statics)
        r = c.wait_for_handler("registry", "/v1/packages")
        check("registry app serving /v1/packages", r.status == 200,
              "" if r.status == 200 else f"{r.status} {r.body!r}")

        env_file = f"/tmp/pmopsdeploy-{os.getpid()}.env"
        with open(env_file, "w") as f:
            f.write(f"ROVE_WORKER_URLS={c.node_url(0)}\n")
            f.write(f"REWIND_MOVE_SECRET={MOVE_SECRET}\n")
            f.write(f"REWIND_ROOT_TOKEN={ROOT_TOKEN}\n")
            f.write(f"REWIND_ADMIN_DOMAIN={c.host_for('__admin__')}\n")
            f.write(f"REWIND_REGISTRY_DOMAIN={reg_host}\n")
            f.write(f"ROVE_CLUSTER={c.cluster_id}\n")

        def ops(*args, timeout=600):
            return subprocess.run([str(BIN_DIR / "rewind-ops"), *args, "--env", env_file],
                                  capture_output=True, text=True, timeout=timeout)

        r = ops("seed-packages")
        check("seed-packages published the first-party set", r.returncode == 0,
              "" if r.returncode == 0 else (r.stdout + r.stderr)[-400:])

        c._ensure_admin_app()
        c.provision(TENANT)

        with tempfile.TemporaryDirectory() as td:
            bundle = Path(td)
            (bundle / "index.mjs").write_text(HANDLER)
            (bundle / "manifest.json").write_text(BUNDLE_MANIFEST)

            r = ops("deploy", TENANT, str(bundle), "--release")
            out = r.stdout + r.stderr
            check("rewind-ops deploy of a package-importing bundle succeeded",
                  r.returncode == 0, "" if r.returncode == 0 else out[-500:])
            # The staging line is the specific evidence that resolution ran; a
            # deploy that silently staged nothing would otherwise look identical
            # right up until the import is used.
            check("...and reported resolving + staging the package",
                  "packages: 1 resolved" in out and "file(s) staged" in out,
                  "" if "packages: 1 resolved" in out else out[-300:])

        served = c.wait_for_handler(TENANT, "/", want_status=200, timeout_s=45.0)
        check("the tenant serves, running the IMPORTED package's code",
              served.status == 200 and served.body.strip() == "sub=ok",
              f"{served.status} {served.body!r}")

    if failures:
        print(f"\nFAIL pm-ops-deploy smoke (v2): {len(failures)} check(s)")
        return 1
    print("\nPASS pm-ops-deploy smoke (v2): the operator CLI resolves, stages and "
          "publishes a package-importing bundle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
