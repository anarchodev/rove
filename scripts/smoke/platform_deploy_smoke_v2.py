#!/usr/bin/env python3
"""e2e smoke for a deploy COMPOSED IN JS on the __admin__ tenant
(docs/architecture/cli-and-deploy.md §4.1 (e)) — the capstone of the dissolution: a customer
deploy assembled from the three privileged primitives, no Zig deploy route.

An __admin__ handler:
  1. platform.compile(handlers, {scope: TARGET}) + next()  → bytecode hashes
     (held connection resumes at onCompiled);
  2. platform.scope(TARGET).deploy.stampManifest(entries)  → dep_id
     (the app composes the entries; the engine owns the manifest format + id);
  3. returns the dep_id.

The smoke then releases that dep_id (canonical path) and GETs TARGET through
the front door — which serves the handler the ADMIN tenant staged cross-tenant
into it. Proves the whole composed deploy works as JS on __admin__ using only
platform.* primitives.

Handlers only: cross-tenant statics have no sync `put` — they STREAM through
`scope(t).blob.receive`, which needs an inbound body to pipe and so belongs
with the upload door (`admin_deploy_smoke_v2` covers that path end to end).

stampManifest is the async STAGING BARRIER: it's the last FIFO job on the
worker's single DeployThread, so its completion proves every prior bytecode +
static PUT is durable. The held chain resumes (onStamped) only then, so the
release never races staging — no sleep. (Per-static PUT *failure* detection is
still a follow-up — the barrier guarantees ordering, not per-blob success.)

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TARGET = "target"

# The handler the admin app deploys INTO `target` (default export → served at
# "/"). Kept as a one-liner string the admin JS embeds.
TARGET_HANDLER_SRC = "export default function(){ return 'deployed-by-admin\\n'; }\n"

# The __admin__ app composes the deploy: compile handlers (→ onCompiled) and
# stamp the manifest cross-tenant into TARGET; stampManifest
# is the async STAGING BARRIER, so onStamped fires only once the whole deploy
# is durable, and returns the dep_id (no race, no sleep).
ADMIN_SRC = (
    'const TARGET = "%s";\n' % TARGET
    + "export default function () {\n"
    + "  platform.compile(\n"
    + "    [{ path: \"index.mjs\", source: %s }],\n" % json.dumps(TARGET_HANDLER_SRC)
    + '    { scope: TARGET, on: "onCompiled" }\n'
    + "  );\n"
    + "  return next();\n"
    + "}\n"
    + "export function onCompiled() {\n"
    + "  try {\n"
    + "  const ctx = request.ctx;\n"
    + "  if (!ctx || !ctx.ok) { response.status = 500; return JSON.stringify({ stage: \"compile\", ctx: ctx || null }); }\n"
    + "  const entries = ctx.results.map(function (r) {\n"
    + "    return { path: r.path, kind: \"handler\", source_hex: r.source_hex, bytecode_hex: r.bytecode_hex };\n"
    + "  });\n"
    + "  platform.scope(TARGET).deploy.stampManifest(entries, { on: \"onStamped\" });\n"
    + "  return next();\n"
    + "  } catch (e) { response.status = 200; return JSON.stringify({ ok: false, error: String(e), stack: (e && e.stack) || null }); }\n"
    + "}\n"
    + "export function onStamped() {\n"
    + "  // request.ctx = {ok, dep_id} — the staging barrier: every bytecode +\n"
    + "  // static + the manifest PUT is durable by the time this fires.\n"
    + "  response.status = 200;\n"
    + "  return JSON.stringify(request.ctx);\n"
    + "}\n"
)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("platdeploy", nodes=1) as c:
        print("step 1: provision __admin__ + the target tenant")
        r = c.provision("__admin__")
        check("provision __admin__ → 200/409", r.status in (200, 409), f"got {r.status} {r.body!r}")
        r = c.provision(TARGET)
        check("provision target → 200", r.status == 200, f"got {r.status} {r.body!r}")

        print("step 2: deploy the composed-deploy admin app to __admin__")
        try:
            c.deploy_handlers("__admin__", {"index.mjs": ADMIN_SRC})
            check("deploy admin app", True)
        except RuntimeError as e:
            check("deploy admin app", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        print("step 3: GET __admin__/ → it compiles + stages + stamps a manifest INTO target")
        r = c.wait_for_handler("__admin__", "/", want_status=200, timeout_s=30.0)
        dep_hex = None
        ok = r.status == 200
        if ok:
            try:
                payload = json.loads(r.body)
                ok = payload.get("ok") is True
                dep_hex = payload.get("dep_id")
            except Exception:
                ok = False
        check("admin app staged target → {ok, dep_id}", ok and bool(dep_hex),
              f"got {r.status} {r.body[:200]!r}")
        if not ok:
            c.dump_node_log(grep=["compile", "blob", "manifest", "stamp", "deploy", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        print("step 4: release the staged dep_id (no sleep — onStamped fired AFTER staging was durable)")
        rel = c.release(TARGET, int(dep_hex, 16))
        check("release target → 204", rel.status == 204, f"got {rel.status} {rel.body!r}")

        print("step 5: GET target through the front → serves the admin-staged handler")
        r = c.wait_for_handler(TARGET, "/", want_body="deployed-by-admin", timeout_s=30.0)
        check("target serves the cross-tenant-staged handler",
              r.status == 200 and "deployed-by-admin" in r.body,
              f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["loader", "manifest", "deploy", "resolve", "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS platform-deploy smoke (v2): a deploy composed in JS on __admin__ "
          "(compile + stampManifest) served from target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
