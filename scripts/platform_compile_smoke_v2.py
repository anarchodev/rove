#!/usr/bin/env python3
"""e2e smoke for the `platform.compile` primitive (rewind-cli-plan.md §4.1) —
the bound-respond shape.

`platform.compile(files, {scope, name})` is the admin-only, off-hot-path,
deterministic compile primitive that makes customer deploys composable
rewind.js. It rides the bound-fetch machinery: the handler issues it + returns
`next()` (binding to the held chain); the worker's background DeployThread
compiles + content-addresses the bytecode into the SCOPE tenant's blobs, then
emits a terminal bound event that RESUMES THE HELD CONNECTION at the `name`
export with `request.ctx = {ok, results:[{path, source_hex, bytecode_hex}]}`.

This proves the whole arc end to end:
  1. an __admin__ handler calls platform.compile(scope=acme) + next() → parks;
  2. the compile runs off the poll loop + stages bytecode into acme's blobs;
  3. the held connection resumes + answers with the per-file hashes.
Plus the admin gate: a NON-admin tenant calling platform.compile is rejected
(the held chain resumes with {ok:false, status:403}).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

HEX64 = re.compile(r"^[0-9a-f]{64}$")

# A handler that issues platform.compile against `scope` + parks, and
# returns the resume ctx (the per-file hashes) verbatim on resume. Deployed
# to __admin__ for the success path and to a non-admin tenant for the gate.
def handler_src(scope: str) -> str:
    return (
        "export default function () {\n"
        "  platform.compile(\n"
        '    [{ path: "hello.mjs", source: "export default () => \'hi\';\\n" }],\n'
        f'    {{ scope: {json.dumps(scope)}, name: "onCompiled" }}\n'
        "  );\n"
        "  return next();\n"
        "}\n"
        "export function onCompiled() {\n"
        "  response.status = 200;\n"
        "  return JSON.stringify(request.ctx);\n"
        "}\n"
    )


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("platcompile", nodes=1) as c:
        print("step 1: provision scope tenant 'acme' + the admin tenant '__admin__'")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("__admin__")
        # __admin__ may be auto-bootstrapped → 204 (created) or 409 (exists).
        check("provision __admin__ → 204/409", r.status in (204, 409), f"got {r.status} {r.body!r}")

        print("step 2: deploy the compile-test handler to __admin__")
        try:
            dep = c.deploy_handlers("__admin__", {"index.mjs": handler_src("acme")})
            check("deploy __admin__ handler → dep_id", bool(dep), f"dep_id={dep}")
        except RuntimeError as e:
            check("deploy __admin__ handler", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        print("step 3: GET __admin__/ → issues platform.compile + parks; held connection resumes with hashes")
        r = c.wait_for_handler("__admin__", "/", want_status=200, timeout_s=30.0)
        ok = r.status == 200
        payload = None
        if ok:
            try:
                payload = json.loads(r.body)
            except Exception:
                ok = False
        check("GET __admin__/ → 200 JSON", ok, f"got {r.status} {r.body[:200]!r}")
        if r.status != 200:
            c.dump_node_log(grep=["compile", "rove-compile", "fetch", "ssrf", "resume", "bound", "submit", "error", "warn"])

        if payload is not None:
            results = payload.get("results") or []
            check("compile resumed the held chain with ok:true",
                  payload.get("ok") is True, f"payload={payload}")
            check("one compiled result for hello.mjs",
                  len(results) == 1 and results[0].get("path") == "hello.mjs",
                  f"results={results}")
            if results:
                e0 = results[0]
                check("source_hex + bytecode_hex are sha256 hashes",
                      bool(HEX64.match(e0.get("source_hex", ""))) and
                      bool(HEX64.match(e0.get("bytecode_hex", ""))),
                      f"src={e0.get('source_hex')!r} bc={e0.get('bytecode_hex')!r}")
                check("bytecode hash differs from source hash (compiled, not echoed)",
                      e0.get("source_hex") != e0.get("bytecode_hex"))

        print("step 4: a NON-admin tenant calling platform.compile is rejected (403 via the held chain)")
        c.provision("cust")
        try:
            c.deploy_handlers("cust", {"index.mjs": handler_src("acme")})
            deploy_ok = True
        except RuntimeError as e:
            check("deploy cust handler", False, str(e))
            deploy_ok = False
        if deploy_ok:
            r = c.wait_for_handler("cust", "/", want_status=200, timeout_s=30.0)
            gate = None
            if r.status == 200:
                try:
                    gate = json.loads(r.body)
                except Exception:
                    pass
            check("non-admin compile → ok:false status:403",
                  gate is not None and gate.get("ok") is False and gate.get("status") == 403,
                  f"got {r.status} {r.body[:200]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS platform.compile smoke (v2): bound-respond compile + admin gate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
