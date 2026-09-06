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
    with V2Cluster.spawn("admself", nodes=1, deploy_private_port=True) as c:
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

        # 7. /v1/sources/{t}/current: the live-pointer read is a dispatched
        #    activation too, and its finisher continues the manifest chain
        #    (readManifest -> blob reads) from the wake — the whole read
        #    door composed across a park.
        r = _curl(f"{node}/v1/sources/viadash/current", headers=auth, timeout=30.0)
        ok_src = False
        try:
            ents = _json.loads(r.body).get("entries") or []
            ok_src = any(e.get("path") == "index.mjs" and "ok" in (e.get("source") or "")
                         for e in ents)
        except Exception:
            pass
        check("sources/current resolves through the dispatched read",
              r.status == 200 and ok_src, f"got {r.status} {r.body[:160]!r}")

        # 8. No residue: every dispatched read's result row was consumed by
        #    its wake (or chain terminal). The browse below is itself a
        #    dispatched op whose own owed marker is live mid-scan, so only
        #    the RESULT rows are asserted empty.
        r = _curl(f"{node}/v1/instances/__admin__/kv?prefix=_dispatch/result/", headers=auth)
        ok_res = False
        try:
            ok_res = r.status == 200 and (_json.loads(r.body).get("entries") == [])
        except Exception:
            pass
        check("dispatch result rows are consumed (no residue)",
              ok_res, f"got {r.status} {r.body[:200]!r}")

        # 9. The export routes ride dispatched scoped kv end to end: start
        #    parks through TWO dispatches (running-check, then the lib-built
        #    marker + wake rows committed in the TARGET's log), and the
        #    engine's sched arm starts the job in the target's own group.
        r = _curl(f"{node}/v1/instances/viadash/export", method="POST", headers=auth)
        exp_id = None
        try:
            exp_id = _json.loads(r.body).get("id")
        except Exception:
            pass
        check("export start → 202 through the dispatched chain",
              r.status == 202 and bool(exp_id), f"got {r.status} {r.body[:160]!r}")
        r = _curl(f"{node}/v1/instances/viadash/export/{exp_id}", headers=auth)
        st = None
        try:
            st = _json.loads(r.body).get("state")
        except Exception:
            pass
        check("export poll sees the marker in the target",
              r.status == 200 and st in ("running", "done"),
              f"got {r.status} state={st!r}")
        r = _curl(f"{node}/v1/instances/viadash/export", headers=auth)
        check("export list carries it",
              r.status == 200 and exp_id is not None and exp_id in r.body,
              f"got {r.status} {r.body[:160]!r}")

        # 10. The engine publish door: manifest-first, content-addressed,
        #     stateless. The handshake is open; writes take the door's own
        #     gate (root ONLY on the private loopback listener); the
        #     negotiation answers 200 {dep_id} when every blob is present
        #     (viadash's index.mjs was staged content-addressed by the
        #     deploy above) and 409 {need} when one is not; a repeated
        #     post returns the SAME dep_id; validation reports EVERY
        #     violation in one round trip.
        import hashlib as _hashlib
        door = f"http://127.0.0.1:{c.deploy_private_port}/_system/deploy"
        r = _curl(f"{door}/version")
        check("door handshake is open", r.status == 200 and '"min"' in r.body,
              f"got {r.status} {r.body[:120]!r}")
        src_hash = _hashlib.sha256(TARGET_SRC.encode()).hexdigest()
        manifest = _json.dumps({"v": 1, "tenant": "viadash", "client": "smoke",
                                "files": [{"path": "index.mjs", "hash": src_hash}]})
        hdr = {"Content-Type": "application/json"}
        r = _curl(door, method="POST", headers=hdr, data=manifest)
        check("unauthenticated manifest POST is refused",
              r.status == 401, f"got {r.status} {r.body[:120]!r}")
        rooth = {**hdr, "Authorization": f"Bearer {c.root_token}"}
        r = _curl(f"{node}/_system/deploy", method="POST",
                  headers={**rooth, "Host": c.admin_host(0)}, data=manifest)
        check("root on the PUBLIC plane is refused with its own code",
              r.status == 403 and "root_credential_on_public_plane" in r.body,
              f"got {r.status} {r.body[:160]!r}")
        r = _curl(door, method="POST", headers=rooth, data=manifest)
        dep1 = None
        try:
            dep1 = _json.loads(r.body).get("dep_id")
        except Exception:
            pass
        check("a fully-present bundle answers 200 {dep_id}",
              r.status == 200 and bool(dep1), f"got {r.status} {r.body[:160]!r}")
        r = _curl(door, method="POST", headers=rooth, data=manifest)
        dep2 = None
        try:
            dep2 = _json.loads(r.body).get("dep_id")
        except Exception:
            pass
        check("a repeated post returns the same dep_id (idempotent)",
              r.status == 200 and dep2 == dep1, f"got {r.status} dep2={dep2!r}")
        missing = "0" * 64
        m2 = _json.dumps({"v": 1, "tenant": "viadash", "client": "smoke",
                          "files": [{"path": "index.mjs", "hash": src_hash},
                                    {"path": "_static/x.css", "hash": missing}]})
        r = _curl(door, method="POST", headers=rooth, data=m2)
        ok_need = False
        try:
            ok_need = _json.loads(r.body).get("need") == [missing]
        except Exception:
            pass
        check("a missing blob answers 409 naming exactly it",
              r.status == 409 and ok_need, f"got {r.status} {r.body[:160]!r}")
        bad = _json.dumps({"v": 1, "tenant": "viadash", "client": "smoke",
                           "files": [{"path": "_tests/t.mjs", "hash": src_hash},
                                     {"path": "index.mjs", "hash": "zz"},
                                     {"path": "index.mjs", "hash": src_hash}]})
        r = _curl(door, method="POST", headers=rooth, data=bad)
        ok_all = False
        try:
            codes = sorted(e["code"] for e in _json.loads(r.body)["errors"])
            ok_all = codes == ["bad_hash", "duplicate_path", "test_artifact_path"]
        except Exception:
            pass
        check("validation reports every violation in one round trip",
              r.status == 400 and ok_all, f"got {r.status} {r.body[:220]!r}")

    print()
    if failures:
        print(f"FAILURES ({len(failures)}): " + ", ".join(failures))
        return 1
    print("PASS — both deploy implementations publish a cut-compiled package")
    return 0


if __name__ == "__main__":
    sys.exit(main())
