#!/usr/bin/env python3
"""Smoke for the `rewind` operator CLI (docs/rewind-cli-plan.md §2–§3) — the
Zig binary (zig-out/bin/rewind) driven against a live V2Cluster with the DIRECT
transport (no ROVE_PUBLISH_SSH). Proves the three commands end to end:

  - `rewind bootstrap`  → provision __admin__ via the CP + POST /_system/reset;
                          the baked deploy app goes live (GET __admin__/ → 405)
  - `rewind deploy acme <bundle> --release` → classify the bundle, POST it to the
                          standing app, stage a dep_id, flip the release
  - GET acme/ + acme/hi.txt through the front door → served
  - `rewind reset`      → idempotent re-deploy of the baked app (break-glass)

Needs S3 env: `set -a; . ./.env; set +a` first; and `zig build rewind`.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET  # noqa: E402

REWIND = Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "rewind"
HANDLER = "export default function(){ return 'cli-served\\n'; }\n"
STATIC = "cli-static\n"


def main() -> int:
    if not REWIND.exists():
        print(f"FAIL: {REWIND} missing — run `zig build rewind` first")
        return 1

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("rewindcli", nodes=1) as c, \
            tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as ef:
        # The CLI reads an operator env file; isolate this run from the real
        # ~/.config/rove/prod.env (which carries ROVE_PUBLISH_SSH → would ssh to
        # prod) by writing a local one and passing --env. No ROVE_PUBLISH_SSH →
        # direct curl transport.
        ef.write(f"REWIND_ROOT_TOKEN={c.root_token}\n")
        ef.write(f"REWIND_ADMIN_DOMAIN={c.host_for('__admin__')}\n")
        ef.write(f"ROVE_WORKER_URLS={c.node_url(0)}\n")
        ef.write(f"ROVE_CP_URL_INTERNAL=http://127.0.0.1:{c.cp_port}\n")
        ef.write(f"REWIND_MOVE_SECRET={MOVE_SECRET}\n")
        ef.write(f"ROVE_CLUSTER={c.cluster_id}\n")
        ef.flush()
        env_file = ef.name
        # Also blank ROVE_PUBLISH_SSH in the OS env so nothing leaks an ssh hop.
        cli_env = dict(os.environ)
        cli_env["ROVE_PUBLISH_SSH"] = ""

        def rewind(*args, timeout=120):
            r = subprocess.run([str(REWIND), *args, "--env", env_file], env=cli_env,
                               capture_output=True, text=True, timeout=timeout)
            out = (r.stdout or "") + (r.stderr or "")
            return r.returncode, out

        print("step 1: rewind bootstrap (provision __admin__ + reset)")
        rc, out = rewind("bootstrap")
        check("bootstrap → rc 0", rc == 0, f"rc={rc} {out.strip()[:200]!r}")
        if rc != 0:
            c.dump_node_log(grep=["reset", "deploy", "admin", "leader", "error", "warn"])
            print(out)
            return 1
        r = c.wait_for_handler("__admin__", "/", want_status=405, timeout_s=30.0)
        check("deploy app live (GET __admin__/ → 405)", r.status == 405, f"got {r.status}")

        print("step 2: rewind deploy acme <bundle> --release")
        c.provision("acme")
        with tempfile.TemporaryDirectory() as d:
            bundle = Path(d)
            (bundle / "index.mjs").write_text(HANDLER)
            (bundle / "_static").mkdir()
            (bundle / "_static" / "hi.txt").write_text(STATIC)
            rc, out = rewind("deploy", "acme", str(bundle), "--release")
        check("deploy --release → rc 0", rc == 0, f"rc={rc} {out.strip()[:240]!r}")
        if rc != 0:
            c.dump_node_log(grep=["compile", "blob", "manifest", "release", "error", "warn"])
            print(out)
            return 1
        check("deploy printed a staged dep_id", "deployment staged:" in out)
        check("deploy printed released", "released acme" in out)

        print("step 3: serve acme through the front door")
        r = c.wait_for_handler("acme", "/", want_body="cli-served", timeout_s=30.0)
        check("GET acme/ → cli-served", r.status == 200 and "cli-served" in r.body,
              f"got {r.status} {r.body!r}")
        r = c.get("acme", "/hi.txt")
        served = (r.status == 200 and "cli-static" in r.body) or (
            r.status == 302 and bool(r.headers.get("location")))
        check("GET acme/hi.txt → static (200 inline or 302→storage)", served,
              f"got {r.status} loc={r.headers.get('location')!r}")

        print("step 4: rewind reset (idempotent break-glass)")
        rc, out = rewind("reset")
        check("reset → rc 0", rc == 0, f"rc={rc} {out.strip()[:200]!r}")
        check("reset printed deploy app live", "deploy app live" in out)

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS rewind-cli smoke (v2): bootstrap + deploy --release + reset "
          "drive a live cluster via the operator CLI")
    return 0


if __name__ == "__main__":
    sys.exit(main())
