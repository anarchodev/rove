#!/usr/bin/env python3
"""The CP directory is backed up, and a rebuilt control plane can place the
tenants again (rove#964; `/_control/directory-dump` + `-restore`).

A tenant's pairs are addressed by a store id derived from its **storage
incarnation** — a random token minted at provision and recorded in the CP
directory, alongside where the tenant lives and what it is allowed to do.
Lose the CP's raft state and every restored tenant is data with no identity:
nothing says which cluster it belongs to, and nothing says what to attach it
under. Until this, the only copy of the incarnation was the one the backup
manifest happened to carry.

What the dump deliberately does NOT carry, and why it matters here:

  - `cluster/` and `node/` — topology. A rebuilt cluster has its own node
    addresses; restoring the dead ones would point the directory at hosts
    that no longer exist. They come from config, which is where the operator
    already declares them. This smoke therefore configures cluster B's
    topology and restores only the tenant rows onto it.
  - `cert/` — custom domains' PRIVATE KEYS, which the directory cannot seal.
    A certificate re-issues over ACME at the cost of rate limits; a private
    key copied into an off-provider bucket is not undoable.

Proof legs:
  A. the dump carries the tenant rows — placement, incarnation, plan, host —
     and `verify` checks the object.
  B. a REBUILT control plane that knows only its own topology restores them,
     and then resolves the tenant's host to the right cluster with the right
     incarnation. That is the whole claim: the tenant is placeable again.
  C. restoring into a control plane that already places tenants is REFUSED
     (409). Against a live CP this would overwrite the placements and
     incarnations of tenants that are serving — not a restore, an outage.
  D. a run that omits the directory must say so out loud: `run` without
     `--cp` FAILS rather than quietly producing tenant-data-only backups.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, MOVE_SECRET, BIN_DIR, _curl  # noqa: E402

BACKUP_BIN = os.path.join(BIN_DIR, "rewind-backup")
TENANT = "acme"
OTHER = "beta"
RUN_ID = f"dir{os.getpid()}"


def backup_tool(*args):
    p = subprocess.run([BACKUP_BIN, *args], capture_output=True, text=True, timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.strip().splitlines():
        if "debug: rove-blob" not in line:
            print(f"    | {line}")
    return p.returncode, out


def cp_url(c) -> str:
    return f"http://127.0.0.1:{c.cp_port}"


def cp_route(c, host: str):
    return _curl(f"{cp_url(c)}/_cp/route?host={host}")


def dump_rows(c) -> dict[str, str]:
    """The CP's backed-up directory rows, as {key: base64 value}."""
    r = _curl(f"{cp_url(c)}/_control/directory-dump", method="POST",
              headers={"X-Rewind-Move-Secret": MOVE_SECRET})
    if r.status != 200:
        return {}
    return {row["k"]: row["v"] for row in json.loads(r.body)["rows"]}


def main() -> int:
    if not os.path.exists(BACKUP_BIN):
        raise SystemExit(f"{BACKUP_BIN} not found — run `zig build rewind-backup`")
    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")

    os.environ["BACKUP_S3_ENDPOINT"] = os.environ["S3_ENDPOINT"]
    os.environ["BACKUP_S3_REGION"] = os.environ["S3_REGION"]
    os.environ["BACKUP_S3_BUCKET"] = os.environ["S3_BUCKET"]
    os.environ["BACKUP_S3_KEY_PREFIX_BASE"] = f"dirbackupsmoke-{os.getpid()}/"
    os.environ["BACKUP_S3_USE_TLS"] = os.environ.get("S3_USE_TLS", "1")
    os.environ["BACKUP_AWS_ACCESS_KEY_ID"] = os.environ["AWS_ACCESS_KEY_ID"]
    os.environ["BACKUP_AWS_SECRET_ACCESS_KEY"] = os.environ["AWS_SECRET_ACCESS_KEY"]
    os.environ["REWIND_MOVE_SECRET"] = MOVE_SECRET

    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    source_route = ""
    source_rows: dict[str, str] = {}

    with V2Cluster.spawn("dirbk", nodes=1) as a:
        print("leg A: two provisioned tenants, and the dump that records them")
        check("provision acme", a.provision(TENANT, host=f"{TENANT}.dir.localhost").status == 200)
        check("provision beta", a.provision(OTHER).status == 200)
        st, body = cp_route(a, f"{TENANT}.dir.localhost").status, cp_route(a, f"{TENANT}.dir.localhost").body
        source_route = body
        check("the source CP resolves the host", st == 200, f"{st} {body[:120]!r}")

        source_rows = dump_rows(a)
        check("the dump carries placement + incarnation + host rows",
              all(any(k.startswith(p) for k in source_rows)
                  for p in ("placement/", "incarnation/", "host/")),
              f"keys={sorted(source_rows)}")
        check("and carries NO cert or topology rows",
              not any(k.startswith(("cert/", "cluster/", "node/")) for k in source_rows),
              f"keys={sorted(source_rows)}")

        rc, _ = backup_tool("run", "--nodes", a.node_url(0),
                            "--tenants", f"{TENANT},{OTHER}", "--run-id", RUN_ID,
                            "--cp", cp_url(a))
        check("backup run with --cp", rc == 0)

        rc, out = backup_tool("verify", "--run", RUN_ID)
        check("verify covers the directory", rc == 0 and "ok directory" in out)

        rc, out = backup_tool("show", "--run", RUN_ID)
        manifest = json.loads(next(l for l in out.splitlines() if l.startswith("{")))
        check("the manifest records the directory object",
              manifest.get("directory") is not None, f"{manifest.get('directory')}")

        print("leg D: a run that omits the directory has to say so")
        rc, out = backup_tool("run", "--nodes", a.node_url(0),
                             "--tenants", TENANT, "--run-id", f"{RUN_ID}-nodir")
        check("run without --cp FAILS", rc != 0)
        check("and names the flag that opts out", "--no-directory" in out)

        print("leg C: restoring into a CP that already places tenants is refused")
        rc, out = backup_tool("restore-directory", "--run", RUN_ID, "--cp", cp_url(a))
        check("refused", rc != 0)
        check("says why", "already places tenants" in out, out[-160:].replace("\n", " "))

    print("leg B: a REBUILT control plane restores the rows and can place again")
    with V2Cluster.spawn("dirdst", nodes=1) as b:
        # A rebuilt cluster knows its own topology and nothing else: no
        # placements, no incarnations, no hosts.
        before = cp_route(b, f"{TENANT}.dir.localhost")
        check("the rebuilt CP cannot resolve the host yet", before.status == 404,
              f"got {before.status}")

        rc, _ = backup_tool("restore-directory", "--run", RUN_ID, "--cp", cp_url(b))
        check("restore-directory", rc == 0)

        r = cp_route(b, f"{TENANT}.dir.localhost")
        check("the rebuilt CP now resolves the host", r.status == 200,
              f"{r.status} {r.body[:160]!r}")
        check("it resolves to what the source said", r.body == source_route,
              f"rebuilt={r.body[:160]!r} source={source_route[:160]!r}")

        # The route answer carries tenant + cluster + nodes, but NOT the
        # incarnation — and the incarnation is the row that decides whether a
        # restored tenant's own data is reachable at all. So compare the
        # DUMPS: every row that left the source is a row the rebuilt CP now
        # holds, incarnations included.
        rebuilt = dump_rows(b)
        check("every row round-tripped", rebuilt == source_rows,
              f"{len(rebuilt)} rows vs {len(source_rows)}")
        check("including each tenant's incarnation",
              all(f"incarnation/{t}" in rebuilt for t in (TENANT, OTHER)),
              f"keys={sorted(rebuilt)}")

    if failures:
        print(f"\nFAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nbackup directory smoke: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
