#!/usr/bin/env python3
"""e2e smoke for the STANDING __admin__ deploy app (rewind-cli-plan §4.1 (f)) —
the request-driven composed deployer that publish_tenant + the smoke harness
will POST bundles to (replacing the Zig /_system/deploy for customer tenants).

Flow:
  1. bootstrap the deploy app onto __admin__ (via the Zig /_system/deploy —
     the bootstrap path that survives the migration);
  2. POST a real bundle (handlers + a static) for tenant `target` to the
     standing app through the front door (Bearer root token);
  3. the app composes the deploy (platform.compile + cross-tenant blob.put +
     stampManifest barrier) and returns {ok, dep_id};
  4. release the dep_id + GET target through the front → served.

Proves the deploy logic runs as JS on __admin__, request-driven, cross-tenant,
with no Zig route in the customer path. Also a wrong-token POST → 401.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, _curl  # noqa: E402

TARGET = "target"
TARGET_HANDLER = "export default function(){ return 'served-by-standing-app\\n'; }\n"
TARGET_STATIC = "static-by-standing-app\n"


def post_bundle(c, *, token, tenant, handlers, statics):
    body = json.dumps({
        "tenant": tenant,
        "handlers": [{"path": p, "source": s} for p, s in handlers.items()],
        "statics": [
            {"path": p, "content_type": ct,
             "b64": base64.b64encode(v.encode() if isinstance(v, str) else v).decode()}
            for p, (v, ct) in statics.items()
        ],
    })
    return _curl(f"{c.front_url()}/", method="POST", host=c.host_for("__admin__"),
                 headers={"Authorization": f"Bearer {token}",
                          "Content-Type": "application/json"},
                 data=body, timeout=30.0)


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
        check("provision target → 204", r.status == 204, f"got {r.status} {r.body!r}")
        # /_system/reset (root, no body) deployed the BAKED deploy app
        # (rewind-cli-plan §4). The app answers on "/" — a GET → 405 POST-only
        # confirms it's live.
        r = c.wait_for_handler("__admin__", "/", want_status=405, timeout_s=30.0)
        check("reset deploy app live (GET / → 405 POST-only)", r.status == 405, f"got {r.status} {r.body!r}")
        if r.status != 405:
            c.dump_node_log(grep=["reset", "deploy", "admin", "loader", "error", "warn"])

        print("step 2: POST a bundle for `target` to the standing app")
        r = post_bundle(c, token=c.root_token, tenant=TARGET,
                        handlers={"index.mjs": TARGET_HANDLER},
                        statics={"_static/hi.txt": (TARGET_STATIC, "text/plain; charset=utf-8")})
        dep_hex = None
        ok = r.status == 200
        if ok:
            try:
                payload = json.loads(r.body)
                ok = payload.get("ok") is True
                dep_hex = payload.get("dep_id")
            except Exception:
                ok = False
        check("POST bundle → {ok, dep_id}", ok and bool(dep_hex), f"got {r.status} {r.body[:200]!r}")
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

        print("step 4: a wrong-token POST → 401")
        r = post_bundle(c, token="not-the-root-token", tenant=TARGET,
                        handlers={"index.mjs": TARGET_HANDLER}, statics={})
        check("wrong token → 401", r.status == 401, f"got {r.status} {r.body[:120]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS admin-deploy smoke (v2): standing __admin__ deploy app, "
          "request-driven composed deploy served from target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
