#!/usr/bin/env python3
"""Retention: keep a window, and refuse to be the reason there is nothing left
(rove#966; `rewind-backup prune` / `tenants`).

Point-in-time is the reason a backup is not just a mirror: corruption and bad
deletes are discovered late, so the newest copy may be a faithful copy of the
damage. Keeping a window of runs is what makes recovery from those possible —
and the window is a promise in two directions, because an old backup also
holds keys a crypto-shred has since destroyed. It bounds how far back you can
recover AND how long an erasure is only mostly true.

Deleting backups is the one operation here that cannot be undone, so the
guards matter more than the policy:

  A. `tenants` asks the CP which tenants exist, so a scheduled run covers a
     tenant provisioned today without anyone remembering to add it.
  B. a dry run lists what would go and removes NOTHING without `--yes`.
  C. the window is honoured: the newest N runs survive, older ones do not,
     and the objects of a removed run are actually gone.
  D. a retention that would empty the store is REFUSED, not obeyed. A
     misconfigured `--keep-daily 0` is a configuration error, not an
     instruction to delete every backup.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, BIN_DIR  # noqa: E402

BACKUP_BIN = os.path.join(BIN_DIR, "rewind-backup")
TENANT = "acme"
OTHER = "beta"


def backup_tool(*args):
    p = subprocess.run([BACKUP_BIN, *args], capture_output=True, text=True, timeout=300)
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
    os.environ["BACKUP_S3_KEY_PREFIX_BASE"] = f"retentionsmoke-{os.getpid()}/"
    os.environ["BACKUP_S3_USE_TLS"] = os.environ.get("S3_USE_TLS", "1")
    os.environ["BACKUP_AWS_ACCESS_KEY_ID"] = os.environ["AWS_ACCESS_KEY_ID"]
    os.environ["BACKUP_AWS_SECRET_ACCESS_KEY"] = os.environ["AWS_SECRET_ACCESS_KEY"]
    os.environ["REWIND_MOVE_SECRET"] = MOVE_SECRET

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("reten", nodes=1) as c:
        cp = f"http://127.0.0.1:{c.cp_port}"
        check("provision acme", c.provision(TENANT).status == 200)
        check("provision beta", c.provision(OTHER).status == 200)

        print("leg A: the tenant list comes from the CP, not from a list somewhere")
        rc, out = backup_tool("tenants", "--cp", cp)
        listed = sorted(next(l for l in out.splitlines()
                             if TENANT in l and "debug" not in l).strip().split(","))
        check("tenants", rc == 0)
        check("names every placed tenant", listed == sorted([TENANT, OTHER]), f"{listed}")

        # Four runs with explicit ids, oldest first. Real ids are
        # `YYYYMMDDTHHMMSSZ` and sort lexically; these keep that shape so the
        # ordering under test is the one production gets.
        ids = [f"2026010{n}T000000Z" for n in (1, 2, 3, 4)]
        for rid in ids:
            rc, _ = backup_tool("run", "--nodes", c.node_url(0), "--tenants",
                                f"{TENANT},{OTHER}", "--run-id", rid, "--cp", cp)
            check(f"run {rid}", rc == 0)

        rc, out = backup_tool("list")
        check("list shows four runs", all(i in out for i in ids))

        print("leg B: a dry run removes nothing")
        rc, out = backup_tool("prune", "--keep-daily", "2", "--keep-weekly", "0")
        check("dry run exits nonzero (nothing done)", rc == 2)
        check("it names what would go", ids[0] in out and ids[1] in out, out[-200:])
        rc, out = backup_tool("list")
        check("all four runs still there", all(i in out for i in ids))

        print("leg C: --yes honours the window")
        rc, out = backup_tool("prune", "--keep-daily", "2", "--keep-weekly", "0", "--yes")
        check("prune", rc == 0)
        rc, out = backup_tool("list")
        check("the two newest survive", ids[2] in out and ids[3] in out, out[-200:])
        check("the two oldest are gone", ids[0] not in out and ids[1] not in out, out[-200:])
        # Gone means the objects are gone, not just the manifest: a prune that
        # removed the manifest alone would leave the store growing forever
        # while `list` claimed it was pruned.
        rc, out = backup_tool("verify", "--run", ids[0])
        check("a pruned run cannot be verified", rc != 0)

        print("leg D: a retention that would empty the store is refused")
        rc, out = backup_tool("prune", "--keep-daily", "0", "--keep-weekly", "0", "--yes")
        check("refused", rc == 1, f"rc={rc}")
        check("says why", "delete every run" in out, out[-160:])
        rc, out = backup_tool("list")
        check("the store still has its runs", ids[2] in out and ids[3] in out)

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nbackup retention smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
