#!/usr/bin/env python3
"""Create an isolated rove workspace: a local clone with its apps submodule.

Several Claude sessions and humans work this repo at once. Each needs its own
checkout, its own branch, and its own `web/` (the first-party app bundles the
smokes deploy) — and needs them to be RIGHT without anyone remembering a
ritual, because an unenforced setup convention decays quietly and the symptom
surfaces far away as confusing smoke failures.

    scripts/ops/workspace.py <topic> [--base main] [--branch <name>] [--dir D]

Creates `../rove-<topic>`, branches off `origin/<base>`, materialises the `web`
submodule at the pinned commit, and prints what to export. Idempotent: pointed
at an existing workspace it re-syncs the submodule and reports, rather than
failing.

## Why clones and not worktrees

Worktrees share the object store — about 39 MB here. A workspace's real cost is
its Zig build cache, 1-5 GB, which worktrees do NOT share. So the saving is
under a percent, and it is paid for three times over:

  - `git worktree` + submodules is disclaimed by git itself ("It is NOT
    recommended to make multiple checkouts of a superproject" — git-worktree(1)
    BUGS), and `web/` is a submodule.
  - The stash stack is shared across worktrees, so one session can pop
    another's.
  - A branch can be checked out in only one worktree, which turns "look at what
    that other session did" into a dance.

A local clone hardlinks the object files, so it costs the working tree (~12 MB)
and nothing else, and has none of those problems.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve()
REPO = HERE.parent.parent.parent
ORIGIN = "git@github.com:anarchodev/rove.git"


def run(args: list[str], cwd: pathlib.Path | None = None, check: bool = True,
        quiet: bool = False) -> subprocess.CompletedProcess:
    p = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if check and p.returncode != 0:
        sys.exit(f"$ {' '.join(args)}\n{p.stdout}{p.stderr}")
    if not quiet and p.stdout.strip():
        print("  " + p.stdout.strip().replace("\n", "\n  "))
    return p


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("topic", help="short name; the workspace becomes rove-<topic>")
    ap.add_argument("--base", default="main", help="branch to start from (default: main)")
    ap.add_argument("--branch", help="branch to create (default: <topic>)")
    ap.add_argument("--dir", help="explicit destination path")
    args = ap.parse_args()

    dest = pathlib.Path(args.dir) if args.dir else REPO.parent / f"rove-{args.topic}"
    branch = args.branch or args.topic

    if not dest.exists():
        print(f"▶ cloning {REPO} → {dest}")
        # Clone from the LOCAL repo: git hardlinks the object files, so this is
        # instant and costs ~nothing. Then point origin at GitHub so pushes and
        # fetches go to the real remote rather than a sibling working copy.
        run(["git", "clone", "--quiet", str(REPO), str(dest)], quiet=True)
        run(["git", "remote", "set-url", "origin", ORIGIN], cwd=dest, quiet=True)
        run(["git", "fetch", "--quiet", "origin"], cwd=dest, quiet=True)
        print(f"▶ branch {branch} off origin/{args.base}")
        run(["git", "checkout", "--quiet", "-B", branch, f"origin/{args.base}"],
            cwd=dest, quiet=True)
    else:
        print(f"▶ {dest} exists — re-syncing")

    # The submodule is the whole point: `web/` is where the smokes read the
    # first-party bundles from, and an empty one is 15 smokes failing for a
    # reason that reads like a product bug.
    rove_head = run(["git", "rev-parse", "--short", "HEAD"], cwd=dest, quiet=True).stdout.strip()
    apps = dest / "web"
    if (dest / ".gitmodules").exists():
        print("▶ web submodule")
        run(["git", "submodule", "update", "--init", "--recursive"], cwd=dest, quiet=True)
        head = run(["git", "rev-parse", "--short", "HEAD"], cwd=apps, quiet=True).stdout.strip()
        print(f"  web @ {head} (pinned)")
    else:
        # A base that predates the submodule — an older branch, or `--base v2`.
        # Say so plainly: silently producing a workspace whose 15 apps-reading
        # smokes will fail is the failure mode this script exists to remove.
        print(f"▶ no web submodule at origin/{args.base} — that base predates it")
        print("  set REWIND_APPS_DIR at a rewind-apps checkout for the apps-reading smokes")

    env = dest / ".env"
    if not env.exists() and (REPO / ".env").exists():
        env.write_bytes((REPO / ".env").read_bytes())
        print("▶ copied .env (S3 credentials the smokes need)")

    print(f"\nworkspace ready: {dest}   rove @ {rove_head}, branch {branch}")
    print("\n  cd " + str(dest))
    print("  set -a; . ./.env; set +a       # S3 creds")
    print("  zig build test                 # the gate")
    if apps.exists():
        print("\n`web/` is the pinned apps checkout — REWIND_APPS_DIR is only needed to")
        print("point somewhere else, e.g. a branch of rewind-apps you are also editing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
