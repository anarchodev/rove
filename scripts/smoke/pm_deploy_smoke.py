#!/usr/bin/env python3
"""PM P1 deploy smoke — packages through the REAL deploy path.

Proves the package-manager P1 vertical end to end (docs/architecture/
package-resolution.md + package-compile-caching.md):

  - stage two versions of @rewind/jwt + an @rewind/oidc that PINS jwt@1.4,
    while the app pins jwt@1.9 → multi-version coexistence + encapsulation
    served through a real deploy (manifest v2 packages/app_imports →
    reloadDeployment stages /pkg/<hash>/ bytecode + builds the snapshot
    resolver → the dispatcher's module loader resolves per-importer);
  - a handler importing an UNDECLARED package fails AT DEPLOY (compile is
    the import-validation gate), with the module NAMED in the error (P2
    author feedback), not at first request;
  - a package whose source names the privileged surface (_system/__rove)
    is rejected by the P2 deploy-time static gate;
  - a second deploy that REPINS the app's @rewind/jwt to 1.4 serves the
    new pin immediately — the whole chain (dep_id → snapshot → compile)
    has no stale-resolution path.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

JWT19_HASH = "b" * 64
JWT14_HASH = "c" * 64
OIDC_HASH = "a" * 64

JWT19_SRC = 'export const v = "jwt19";\n'
JWT14_SRC = 'export const v = "jwt14";\n'
# oidc pins ITS OWN jwt@1.4 — the encapsulated dep.
OIDC_SRC = 'import { v } from "@rewind/jwt";\nexport const jwtv = v;\n'

HANDLER_SRC = (
    'import { jwtv } from "@rewind/oidc";\n'
    'import { v } from "@rewind/jwt";\n'
    'export function handler() { return "app=" + v + " oidc=" + jwtv + "\\n"; }\n'
)

BAD_HANDLER_SRC = (
    'import { x } from "@rewind/undeclared";\n'
    'export function handler() { return String(x); }\n'
)

# PM P2: a package whose source names the privileged surface must be
# rejected by the deploy-time static gate (even in a comment — blunt on
# purpose; distributed code has no business naming it).
EVIL_PKG_SRC = 'export const h = _system.http;\n'


def packages(app_jwt_hash: str) -> list[dict]:
    """The lockfile-shaped package set, dependency order (leaves first)."""
    return [
        {"spec": "@rewind/jwt", "version": "1.9.0", "pkg_hash": JWT19_HASH,
         "files": {"index.mjs": JWT19_SRC}, "imports": {}},
        {"spec": "@rewind/jwt", "version": "1.4.0", "pkg_hash": JWT14_HASH,
         "files": {"index.mjs": JWT14_SRC}, "imports": {}},
        {"spec": "@rewind/oidc", "version": "2.0.0", "pkg_hash": OIDC_HASH,
         "files": {"index.mjs": OIDC_SRC},
         "imports": {"@rewind/jwt": JWT14_HASH}},
    ]


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("pm", nodes=1) as c:
        print("step 1: provision tenant 'pkgacme'")
        r = c.provision("pkgacme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")

        print("step 2: deploy handler + packages (app pins jwt@1.9, oidc pins jwt@1.4)")
        dep1 = None
        try:
            dep1 = c.deploy_with_packages(
                "pkgacme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                packages(JWT19_HASH),
                {"@rewind/oidc": OIDC_HASH, "@rewind/jwt": JWT19_HASH})
            check("package deploy → dep_id", bool(dep1), f"dep_id={dep1}")
        except RuntimeError as e:
            check("package deploy", False, str(e))

        if dep1:
            print("step 3: multi-version + encapsulation through a real serve")
            r = c.wait_for_handler("pkgacme", "/?fn=handler",
                                   want_body="app=jwt19 oidc=jwt14")
            check("GET → app=jwt19 oidc=jwt14",
                  r.status == 200 and "app=jwt19 oidc=jwt14" in r.body,
                  f"got {r.status} {r.body!r}")

        print("step 4: undeclared package import fails AT DEPLOY, naming the module")
        try:
            c.deploy_with_packages(
                "pkgacme", {"index.mjs": rpc_wrap(BAD_HANDLER_SRC)},
                packages(JWT19_HASH),
                {"@rewind/oidc": OIDC_HASH, "@rewind/jwt": JWT19_HASH})
            check("undeclared import rejected", False, "deploy unexpectedly succeeded")
        except RuntimeError as e:
            # P2 author feedback: the error must NAME the unresolvable
            # module, not just say "compile failed".
            # The bundle compiles at cut (rove#344), so the refusal arrives
            # there — and must still name BOTH the unresolvable module and the
            # file that imports it, which is what the author has to fix.
            check("undeclared import rejected, module + file named",
                  "@rewind/undeclared" in str(e) and "index.mjs" in str(e),
                  str(e)[:200])

        print("step 5: package naming the privileged surface is rejected (P2 static gate)")
        try:
            c.deploy_with_packages(
                "pkgacme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                packages(JWT19_HASH) + [
                    {"spec": "@evil/sys", "version": "1.0.0", "pkg_hash": "e" * 64,
                     "files": {"index.mjs": EVIL_PKG_SRC}, "imports": {}}],
                {"@rewind/oidc": OIDC_HASH, "@rewind/jwt": JWT19_HASH,
                 "@evil/sys": "e" * 64})
            check("privileged-surface package rejected", False,
                  "deploy unexpectedly succeeded")
        except RuntimeError as e:
            check("privileged-surface package rejected",
                  "privileged surface" in str(e), str(e)[:160])

        if dep1:
            print("step 6: REPIN app's @rewind/jwt → 1.4 (same handler source) and redeploy")
            try:
                dep2 = c.deploy_with_packages(
                    "pkgacme", {"index.mjs": rpc_wrap(HANDLER_SRC)},
                    packages(JWT14_HASH),
                    {"@rewind/oidc": OIDC_HASH, "@rewind/jwt": JWT14_HASH})
                check("repin deploy → new dep_id", bool(dep2) and dep2 != dep1,
                      f"dep1={dep1} dep2={dep2}")
                r = c.wait_for_handler("pkgacme", "/?fn=handler",
                                       want_body="app=jwt14 oidc=jwt14")
                check("GET after repin → app=jwt14 (no stale resolution)",
                      r.status == 200 and "app=jwt14 oidc=jwt14" in r.body,
                      f"got {r.status} {r.body!r}")
            except RuntimeError as e:
                check("repin deploy", False, str(e))

    if failures:
        print(f"\nFAIL pm deploy smoke ({len(failures)}): {failures}")
        return 1
    print("\nPASS pm deploy smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
