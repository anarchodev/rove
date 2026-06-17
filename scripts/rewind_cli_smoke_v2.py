#!/usr/bin/env python3
"""Smoke for the `rewind-ops` operator CLI (docs/rewind-cli-plan.md §2–§3) — the
Zig binary (zig-out/bin/rewind-ops) driven against a live V2Cluster with the
DIRECT transport (no ROVE_PUBLISH_SSH). Exercises the verb set audited against
the live server primitives:

  - `bootstrap`              provision __admin__ via the CP + POST /_system/reset
  - `provision acme --host`  create+place a customer tenant (CP)
  - `deploy acme <bundle> --release`   classify + POST to the standing app + flip
  - serve acme/ + acme/hi.txt through the front door
  - `status acme.localhost`  resolve host → tenant/cluster (CP read)
  - `plan set acme <blob>`   set the tenant's plan/limits blob (CP)
  - `move acme … ` (no --yes) refuses (the risk guard)
  - `reset`                  idempotent re-deploy of the baked app

Not exercised here: `host add` — its second write hits /ops/assign-domain, which
lives in the FULL admin (web/admin_interim), not the baked deploy app, so it
needs the full admin deployed first. `move` (real) needs a second cluster.

Needs S3 env: `set -a; . ./.env; set +a` first; and `zig build rewind-ops`.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET  # noqa: E402

OPS = Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "rewind-ops"
HANDLER = "export default function(){ return 'cli-served\\n'; }\n"
STATIC = "cli-static\n"


def main() -> int:
    if not OPS.exists():
        print(f"FAIL: {OPS} missing — run `zig build rewind-ops` first")
        return 1

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("rewindops", nodes=1) as cl, \
            tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as ef:
        # Isolate from the real ~/.config/rove/prod.env (which carries
        # ROVE_PUBLISH_SSH → would ssh to prod) via a local --env file.
        ef.write(f"REWIND_ROOT_TOKEN={cl.root_token}\n")
        ef.write(f"REWIND_ADMIN_DOMAIN={cl.host_for('__admin__')}\n")
        ef.write(f"ROVE_WORKER_URLS={cl.node_url(0)}\n")
        ef.write(f"ROVE_CP_URL_INTERNAL=http://127.0.0.1:{cl.cp_port}\n")
        ef.write(f"REWIND_MOVE_SECRET={MOVE_SECRET}\n")
        ef.write(f"ROVE_CLUSTER={cl.cluster_id}\n")
        ef.flush()
        env_file = ef.name
        cli_env = dict(os.environ)
        cli_env["ROVE_PUBLISH_SSH"] = ""

        def ops(*args, timeout=120):
            r = subprocess.run([str(OPS), *args, "--env", env_file], env=cli_env,
                               capture_output=True, text=True, timeout=timeout)
            return r.returncode, (r.stdout or "") + (r.stderr or "")

        print("step 1: rewind-ops bootstrap")
        rc, out = ops("bootstrap")
        check("bootstrap → rc 0", rc == 0, f"rc={rc} {out.strip()[:200]!r}")
        if rc != 0:
            cl.dump_node_log(grep=["reset", "deploy", "admin", "leader", "error", "warn"])
            print(out); return 1
        r = cl.wait_for_handler("__admin__", "/", want_status=405, timeout_s=30.0)
        check("deploy app live (GET __admin__/ → 405)", r.status == 405, f"got {r.status}")

        print("step 2: rewind-ops provision acme --host acme.localhost")
        rc, out = ops("provision", "acme", "--host", cl.host_for("acme"))
        check("provision → rc 0", rc == 0, f"rc={rc} {out.strip()[:160]!r}")
        check("provision reported placed", "provisioned acme" in out or "already placed" in out)

        print("step 3: rewind-ops deploy acme <bundle> --release")
        with tempfile.TemporaryDirectory() as d:
            bundle = Path(d)
            (bundle / "index.mjs").write_text(HANDLER)
            (bundle / "_static").mkdir()
            (bundle / "_static" / "hi.txt").write_text(STATIC)
            rc, out = ops("deploy", "acme", str(bundle), "--release")
        check("deploy --release → rc 0", rc == 0, f"rc={rc} {out.strip()[:240]!r}")
        if rc != 0:
            cl.dump_node_log(grep=["compile", "blob", "manifest", "release", "error", "warn"])
            print(out); return 1
        check("deploy printed released", "released acme" in out)

        print("step 4: serve acme through the front door")
        r = cl.wait_for_handler("acme", "/", want_body="cli-served", timeout_s=30.0)
        check("GET acme/ → cli-served", r.status == 200 and "cli-served" in r.body,
              f"got {r.status} {r.body!r}")
        r = cl.get("acme", "/hi.txt")
        served = (r.status == 200 and "cli-static" in r.body) or (
            r.status == 302 and bool(r.headers.get("location")))
        check("GET acme/hi.txt → static", served, f"got {r.status}")

        print("step 5: rewind-ops status acme.localhost (CP read)")
        rc, out = ops("status", cl.host_for("acme"))
        check("status → rc 0", rc == 0, f"rc={rc} {out.strip()[:160]!r}")
        check("status resolved tenant=acme", "tenant:  acme" in out, out.strip()[:200])
        check("status resolved cluster", f"cluster: {cl.cluster_id}" in out, out.strip()[:200])

        print("step 6: rewind-ops plan set acme <blob> (CP)")
        rc, out = ops("plan", "set", "acme", '{"tier":"pro"}')
        check("plan set → rc 0", rc == 0, f"rc={rc} {out.strip()[:160]!r}")

        print("step 7: move without --yes is refused (risk guard)")
        rc, out = ops("move", "acme", "cluster-2")
        check("move (no --yes) → rc 1 + confirm prompt",
              rc == 1 and "--yes" in out, f"rc={rc} {out.strip()[:160]!r}")

        print("step 8: rewind-ops reset (idempotent break-glass)")
        rc, out = ops("reset")
        check("reset → rc 0", rc == 0, f"rc={rc} {out.strip()[:160]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS rewind-ops smoke (v2): bootstrap / provision / deploy / status / "
          "plan / move-guard / reset drive a live cluster across both planes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
