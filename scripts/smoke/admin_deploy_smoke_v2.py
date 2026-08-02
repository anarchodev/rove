#!/usr/bin/env python3
"""e2e smoke for the STANDING __admin__ deploy app
(docs/architecture/cli-and-deploy.md §4.1 (f)) — the request-driven composed
deployer every customer deploy goes through, with no Zig route in the customer
path.

Flow:
  1. bootstrap the deploy app onto __admin__ (POST /_system/reset);
  2. stage a real bundle (a handler + a static) for tenant `target` through the
     per-file workspace protocol — reset the workspace, upload each file, cut a
     release. Per-file because the old single mega-POST base64-buffered the whole
     bundle in the deploy app's JS heap and OOM'd on any real bundle;
  3. the app composes the deploy (platform.compile + cross-tenant blob write +
     the stampManifest barrier) and cut returns {ok, dep_id};
  4. release the dep_id + GET target through the front → served.

Also a wrong-token deploy → 401.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, _curl  # noqa: E402

TARGET = "target"
TARGET_HANDLER = "export default function(){ return 'served-by-standing-app\\n'; }\n"
TARGET_STATIC = "static-by-standing-app\n"


def deploy_post(c, sub, body, *, token):
    """One step of the per-file workspace protocol, as the deploy app serves it:
    POST /v1/deploy/{reset,file,cut} on __admin__ with a root bearer."""
    return _curl(f"{c.front_url()}/v1/deploy/{sub}", method="POST",
                 host=c.host_for("__admin__"),
                 headers={"Authorization": f"Bearer {token}",
                          "Content-Type": "application/json"},
                 data=json.dumps(body), timeout=30.0)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("admindeploy", nodes=1) as c:
        print("step 1: bootstrap the baked deploy app via POST /_system/reset")
        c._ensure_admin_app()  # provision __admin__ + POST /_system/reset + wait 405
        r = c.provision(TARGET)
        check("provision target → 200", r.status == 200, f"got {r.status} {r.body!r}")
        # /_system/reset (root, no body) deployed the BAKED deploy app
        # (docs/architecture/cli-and-deploy.md §4). The app answers on "/" — a GET → 405 POST-only
        # confirms it's live.
        r = c.wait_for_handler("__admin__", "/", want_status=405, timeout_s=30.0)
        check("reset deploy app live (GET / → 405 POST-only)", r.status == 405, f"got {r.status} {r.body!r}")
        if r.status != 405:
            c.dump_node_log(grep=["reset", "deploy", "admin", "loader", "error", "warn"])

        print("step 2: stage a bundle for `target` (workspace reset → file → cut)")
        dep_hex = None
        r = deploy_post(c, "reset", {"tenant": TARGET}, token=c.root_token)
        check("workspace reset → 200", r.status == 200, f"got {r.status} {r.body[:200]!r}")
        r = deploy_post(c, "file", {"tenant": TARGET, "path": "index.mjs",
                                    "kind": "handler", "source": TARGET_HANDLER},
                        token=c.root_token)
        check("stage handler → 200", r.status == 200, f"got {r.status} {r.body[:200]!r}")
        # Statics stream as raw bytes to PUT /v1/upload — no base64 through JS.
        qs = urllib.parse.urlencode({"tenant": TARGET, "path": "_static/hi.txt",
                                     "content_type": "text/plain; charset=utf-8"})
        r = _curl(f"{c.front_url()}/v1/upload?{qs}", method="PUT",
                  host=c.host_for("__admin__"),
                  headers={"Authorization": f"Bearer {c.root_token}"},
                  data=TARGET_STATIC, timeout=60.0)
        check("stream static → 200", r.status == 200, f"got {r.status} {r.body[:200]!r}")
        r = deploy_post(c, "cut", {"tenant": TARGET}, token=c.root_token)
        ok = r.status == 200
        if ok:
            try:
                payload = json.loads(r.body)
                ok = payload.get("ok") is True
                dep_hex = payload.get("dep_id")
            except Exception:
                ok = False
        check("cut → {ok, dep_id}", ok and bool(dep_hex), f"got {r.status} {r.body[:200]!r}")
        if not ok:
            c.dump_node_log(grep=["compile", "blob", "manifest", "stamp", "deploy", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        print("step 3: release the staged dep_id + serve target through the front")
        rel = c.release(TARGET, int(dep_hex, 16))
        check("release target → 204", rel.status == 204, f"got {rel.status} {rel.body!r}")
        r = c.wait_for_handler(TARGET, "/", want_body="served-by-standing-app", timeout_s=30.0)
        check("target serves the app-staged handler",
              r.status == 200 and "served-by-standing-app" in r.body, f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["loader", "manifest", "deploy", "resolve", "404", "error", "warn"])
        r = c.get(TARGET, "/hi.txt")
        served = (r.status == 200 and "static-by-standing-app" in r.body) or (
            r.status == 302 and bool(r.headers.get("location")))
        check("target serves the app-staged static", served,
              f"got {r.status} loc={r.headers.get('location')!r}")

        print("step 5: a bundle whose modules import each other (rove#344)")
        # Compilation resolves imports eagerly, so this only works because the
        # bundle compiles at CUT, where every sibling is present. Upload the
        # importer FIRST to prove order doesn't matter.
        r = deploy_post(c, "reset", {"tenant": TARGET}, token=c.root_token)
        check("reset for the multi-file bundle → 200", r.status == 200, f"got {r.status}")
        r = deploy_post(c, "file", {"tenant": TARGET, "path": "index.mjs", "kind": "handler",
                                    "source": 'import { hi } from "./lib.mjs";\n'
                                              "export default function(){ return hi(); }\n"},
                        token=c.root_token)
        check("stage the importer first → 200", r.status == 200, f"got {r.status} {r.body[:160]!r}")
        r = deploy_post(c, "file", {"tenant": TARGET, "path": "lib.mjs", "kind": "handler",
                                    "source": 'export function hi(){ return "multi-file ok\\n"; }\n'},
                        token=c.root_token)
        check("stage the sibling → 200", r.status == 200, f"got {r.status} {r.body[:160]!r}")
        r = deploy_post(c, "cut", {"tenant": TARGET}, token=c.root_token)
        multi_dep = None
        if r.status == 200:
            try:
                multi_dep = json.loads(r.body).get("dep_id")
            except Exception:
                pass
        check("cut compiles the bundle → dep_id", bool(multi_dep), f"got {r.status} {r.body[:200]!r}")
        if multi_dep:
            rel = c.release(TARGET, int(multi_dep, 16))
            check("release the multi-file bundle → 204", rel.status == 204, f"got {rel.status}")
            r = c.wait_for_handler(TARGET, "/", want_body="multi-file ok", timeout_s=30.0)
            check("the imported module actually ran", r.status == 200 and "multi-file ok" in r.body,
                  f"got {r.status} {r.body!r}")

        print("step 6: an import that resolves to nothing still fails the DEPLOY")
        # The reason cut compiles rather than skipping resolution: a typo must
        # not deploy clean and 500 on the first request.
        r = deploy_post(c, "reset", {"tenant": TARGET}, token=c.root_token)
        r = deploy_post(c, "file", {"tenant": TARGET, "path": "index.mjs", "kind": "handler",
                                    "source": 'import { hi } from "./nope.mjs";\n'
                                              "export default function(){ return hi(); }\n"},
                        token=c.root_token)
        check("staging a bad import is fine (staging does not link) → 200",
              r.status == 200, f"got {r.status} {r.body[:160]!r}")
        r = deploy_post(c, "cut", {"tenant": TARGET}, token=c.root_token)
        check("cut refuses the unresolvable import", r.status >= 400, f"got {r.status}")
        check("and names the module", "nope.mjs" in r.body, f"got {r.body[:200]!r}")

        print("step 7: a wrong-token deploy → 401")
        r = deploy_post(c, "reset", {"tenant": TARGET}, token="not-the-root-token")
        check("wrong token → 401", r.status == 401, f"got {r.status} {r.body[:120]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS admin-deploy smoke (v2): standing __admin__ deploy app, "
          "request-driven composed deploy served from target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
