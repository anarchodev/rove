#!/usr/bin/env python3
"""The object store is mirrored off-provider (rove#965; `rewind-backup mirror`).

The KV backup restores a tenant's rows. Its deployed code, static assets,
exports, deployment manifests, request-log batches and spilled request bodies
are not rows — they are objects, and they survive a cluster wipe only because
they live in the object store. That store is one provider account, which is
one of the three scenarios rove#341 exists for: a compromise, a billing
dispute, an operator mistake with broad reach.

Copy-if-absent is exactly right here rather than a shortcut: every family is
immutable once written — content-addressed blobs by construction, and the
id-keyed families because ids are never reused within a storage generation.
So a key already in the backup holds the same bytes, and a re-run resumes.

The per-tenant prefixes come from the NODE, verbatim, because they depend on
the storage incarnation — deriving them a second time in the tool is how a
writer and a reader end up at different depths (rove#355/#357).

Proof legs:
  A. a tenant with a deployed handler has objects; the manifest carries the
     prefixes the node reported, at the incarnation-keyed depth.
  B. `mirror` copies them into the backup store, and the count is real —
     the objects are readable there afterwards.
  C. a second `mirror` copies NOTHING and skips everything: the pass is
     incremental, so a re-run after an interruption resumes rather than
     re-uploading a terabyte.
  D. `verify` distinguishes a run WITH an object mirror from one without,
     rather than reporting the same "verified" for both.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, BIN_DIR  # noqa: E402

BACKUP_BIN = os.path.join(BIN_DIR, "rewind-backup")
TENANT = "acme"
RUN_ID = f"mir{os.getpid()}"

SRC = (
    'export default function () {\n'
    '  return "mirrored\\n";\n'
    '}\n'
)


def backup_tool(*args):
    p = subprocess.run([BACKUP_BIN, *args], capture_output=True, text=True, timeout=600)
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.strip().splitlines():
        if "debug: rove-blob" not in line:
            print(f"    | {line}")
    return p.returncode, out


def main() -> int:
    if not os.path.exists(BACKUP_BIN):
        raise SystemExit(f"{BACKUP_BIN} not found — run `zig build rewind-backup`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    os.environ["BACKUP_S3_ENDPOINT"] = os.environ["S3_ENDPOINT"]
    os.environ["BACKUP_S3_REGION"] = os.environ["S3_REGION"]
    os.environ["BACKUP_S3_BUCKET"] = os.environ["S3_BUCKET"]
    os.environ["BACKUP_S3_KEY_PREFIX_BASE"] = f"mirrorsmoke-{os.getpid()}/"
    os.environ["BACKUP_S3_USE_TLS"] = os.environ.get("S3_USE_TLS", "1")
    os.environ["BACKUP_AWS_ACCESS_KEY_ID"] = os.environ["AWS_ACCESS_KEY_ID"]
    os.environ["BACKUP_AWS_SECRET_ACCESS_KEY"] = os.environ["AWS_SECRET_ACCESS_KEY"]
    os.environ["REWIND_MOVE_SECRET"] = MOVE_SECRET

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("mirbk", nodes=1) as c:
        print("leg A: a deployed tenant, and the prefixes the node reports")
        check("provision", c.provision(TENANT).status == 200)
        c.deploy_handlers(TENANT, {"index.mjs": SRC})
        r = c.wait_for_handler(TENANT, "/")
        check("the handler serves", "mirrored" in r.body, f"{r.status} {r.body[:80]!r}")

        rc, _ = backup_tool("run", "--nodes", c.node_url(0), "--tenants", TENANT,
                            "--run-id", RUN_ID, "--cp", f"http://127.0.0.1:{c.cp_port}")
        check("backup run", rc == 0)

        rc, out = backup_tool("show", "--run", RUN_ID)
        manifest = json.loads(next(l for l in out.splitlines() if l.startswith("{")))
        entry = manifest["tenants"][0]
        prefixes = entry.get("object_prefixes", [])
        print(f"  prefixes: {prefixes}")
        check("the manifest carries the tenant's object prefixes", len(prefixes) > 0)
        # Incarnation-keyed depth: `{base}{tenant}/{incarnation}/{subdir}/`.
        # A prefix missing the incarnation segment would list nothing and the
        # mirror would report a cheerful zero.
        inc = entry["incarnation"]
        check("at the incarnation-keyed depth",
              all(f"/{inc}/" in p for p in prefixes) if inc != "legacy" else True,
              f"inc={inc} prefixes={prefixes}")

        # The shared families hang off the same base as the tenant's prefixes.
        # Composing them in the tool from its own env walked `1/_logs/` — a
        # prefix the cluster does not write to — and reported a cheerful zero,
        # which is why this assertion exists rather than "copied > 0" alone.
        shared = entry.get("shared_prefixes", [])
        base = prefixes[0].split(TENANT + "/")[0] if prefixes else ""
        check("the manifest carries the shared families", len(shared) == 2, f"{shared}")
        check("at the SAME base as the tenant's objects",
              all(p.startswith(base) for p in shared), f"base={base!r} shared={shared}")

        print("leg B: mirror copies the objects into the backup store")
        rc, out = backup_tool("mirror", "--run", RUN_ID)
        check("mirror", rc == 0)
        copied = 0
        for line in out.splitlines():
            if "object(s) copied" in line:
                copied = int(line.split(":")[1].strip().split()[0])
        check("it copied something", copied > 0, f"copied={copied}")
        check("and walked the shared families",
              all(any(p in line for line in out.splitlines()) for p in shared), f"{shared}")

        print("leg C: a second pass copies nothing — the mirror is incremental")
        rc, out = backup_tool("mirror", "--run", RUN_ID)
        check("second mirror", rc == 0)
        again = None
        for line in out.splitlines():
            if "object(s) copied" in line:
                again = line
        check("nothing re-copied", again is not None and "0 object(s) copied" in again,
              f"{again}")

        print("leg D: verify distinguishes a mirrored run from an unmirrored one")
        rc, out = backup_tool("verify", "--run", RUN_ID)
        check("verify", rc == 0)
        check("and says the objects were mirrored", "objects mirrored" in out)

        rc, out = backup_tool("run", "--nodes", c.node_url(0), "--tenants", TENANT,
                              "--run-id", f"{RUN_ID}-nomirror",
                              "--cp", f"http://127.0.0.1:{c.cp_port}")
        check("a second run, not mirrored", rc == 0)
        rc, out = backup_tool("verify", "--run", f"{RUN_ID}-nomirror")
        check("verify still passes", rc == 0)
        check("but says there is no object mirror", "no object mirror" in out)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nbackup mirror smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
