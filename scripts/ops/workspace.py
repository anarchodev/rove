#!/usr/bin/env python3
"""Create an isolated rove workspace: a local clone with its apps submodule.

Several Claude sessions and humans work this repo at once. Each needs its own
checkout, its own branch, and its own `web/` (the first-party app bundles the
smokes deploy) — and needs them to be RIGHT without anyone remembering a
ritual, because an unenforced setup convention decays quietly and the symptom
surfaces far away as confusing smoke failures.

    scripts/ops/workspace.py <topic> [--base main] [--branch <name>] [--dir D]
    scripts/ops/workspace.py --list            # what exists, and what is reclaimable
    scripts/ops/workspace.py --gc [--yes]      # delete the ones that hold nothing
    scripts/ops/workspace.py --trim [--yes]    # keep the tree, drop the build cache

Creates `../rove-<topic>`, branches off `origin/<base>`, materialises the `web`
submodule at the pinned commit, and prints what to export. Idempotent: pointed
at an existing workspace it re-syncs the submodule and reports, rather than
failing.

## Reclaim

Creating a workspace is one command; retiring one was a remembered `rm -rf`,
and a remembered step is one nobody takes. Workspaces therefore accumulate
long after their branch merges — dozens of gigabytes, because a working tree is
~12 MB but its Zig build cache is 1-5 GB. `--gc` makes retirement derivable
instead of remembered.

A workspace is reclaimable only when git can prove it holds nothing the rest of
the world lacks: clean tree, no stash, no untracked files, and every local
branch tip contained in this repo's `origin/main`. Anything short of that is
kept and the reason printed. That proof is deliberately the WHOLE test — in
particular it does not consult who is "using" the workspace, because there is
no trustworthy signal for that (a session working in a clone still reports the
main checkout as its cwd, and `~/.claude/workspaces/` is hand-maintained and
drifts). If the proof holds, the worst a delete can cost a live session is a
rebuilt cache; if it does not hold, no liveness signal would have made deleting
safe anyway.

Containment is checked against THIS repo's `origin/main`, not each clone's,
whose remote-tracking ref went stale the moment its branch merged. A stale
reference here only under-reports — an unfetched merge reads as "not
contained", which keeps a workspace that could have gone.

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
import shutil
import subprocess
import sys
import time

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


def git(args: list[str], cwd: pathlib.Path) -> str:
    """Read-only git: the empty string on any failure, never a raised exception.

    Every caller here is surveying a workspace that may be half-broken — a
    detached HEAD, a branch with no upstream, an interrupted clone. A survey
    that dies on the first odd repo reports nothing about the other twelve.
    """
    p = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    return p.stdout.strip() if p.returncode == 0 else ""


def dir_bytes(path: pathlib.Path) -> int:
    p = subprocess.run(["du", "-sb", str(path)], text=True, capture_output=True)
    if p.returncode != 0 or not p.stdout.strip():
        return 0
    return int(p.stdout.split()[0])


def human(n: int) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return str(n)


CACHE_DIRS = (".zig-cache", "zig-out", "zig-cache", "target")


class Workspace:
    """One sibling clone, surveyed for whether it still holds anything."""

    def __init__(self, path: pathlib.Path, main_ref: str | None):
        self.path = path
        self.branch = git(["rev-parse", "--abbrev-ref", "HEAD"], path) or "?"
        self.head = git(["rev-parse", "HEAD"], path)
        self.keeps: list[str] = []
        self.spared = False

        if git(["status", "--porcelain", "--untracked-files=no"], path):
            self.keeps.append("uncommitted changes")
        untracked = git(["ls-files", "--others", "--exclude-standard"], path)
        if untracked:
            n = len(untracked.splitlines())
            self.keeps.append(f"{n} untracked file{'s' if n > 1 else ''}")
        stashes = git(["stash", "list"], path)
        if stashes:
            self.keeps.append(f"{len(stashes.splitlines())} stash entries")

        # Containment: every local branch tip, plus HEAD itself when detached,
        # must already be reachable from the reference repo's origin/main. The
        # question is about COMMITS, not branch names — a branch whose PR merged
        # is reclaimable under whatever name it carried, and a branch that was
        # never pushed is not, however tidy its name looks.
        tips = {self.head} if self.head else set()
        for line in git(["for-each-ref", "--format=%(objectname)", "refs/heads"], path).splitlines():
            tips.add(line.strip())
        self.unmerged = contained(path, {t for t in tips if t}, main_ref)
        if self.unmerged:
            n = len(self.unmerged)
            self.keeps.append(f"{n} branch tip(s) with commits not on main")

        self.total = dir_bytes(path)
        self.cache = sum(dir_bytes(path / d) for d in CACHE_DIRS if (path / d).exists())
        self.running = running_from(path)
        if self.running:
            self.keeps.append(f"{self.running} process(es) running from it")
        elif building(path):
            self.running = 1
            self.keeps.append("build cache written in the last 15 min")

    @property
    def reclaimable(self) -> bool:
        return not self.keeps

    @property
    def trimmable(self) -> bool:
        """Idle enough that dropping its build cache costs only a rebuild.

        Being reclaimable does not disqualify a workspace: you reclaim what you
        no longer want, but a clone kept ON PURPOSE — spared, or simply not
        swept — is exactly the one whose cache is worth dropping, and a cache
        is not the work. `--except` still wins, because it means leave this
        alone, and someone living in a clone may not want to pay the rebuild.
        """
        return not self.running and not self.spared


def contained(path: pathlib.Path, tips: set[str], main_ref: str | None) -> list[str]:
    """Which of `tips` is work that origin/main does NOT already have?

    Equivalence is by PATCH, not by sha, because a branch is routinely rebased
    before it merges: its commits land on main carrying the same diffs under
    new hashes, and an ancestry test would call that work missing and hoard the
    workspace forever. `git cherry` marks a commit `-` when main holds an
    equivalent patch and `+` when it is genuinely unique.

    It runs inside the workspace, with this repo's object store as an alternate
    so both sides of the comparison are readable: the clone's own origin/main
    froze when it was created, and main's current tip lives only here.
    """
    if not main_ref or not tips:
        return sorted(tips) if not main_ref else []
    env = dict(os.environ, GIT_ALTERNATE_OBJECT_DIRECTORIES=str(REPO / ".git" / "objects"))
    unique = []
    for tip in sorted(tips):
        p = subprocess.run(["git", "cherry", main_ref, tip],
                           cwd=path, env=env, text=True, capture_output=True)
        # A failure here means the comparison could not be made at all, which
        # is not evidence the work is safe — keep, and say so.
        if p.returncode != 0:
            unique.append(tip)
            continue
        if any(line.startswith("+") for line in p.stdout.splitlines()):
            unique.append(tip)
    return unique


def reference_main() -> str | None:
    """This repo's origin/main, refreshed if the network cooperates.

    The fetch is best-effort and time-boxed: pushes here go over ssh, which can
    hang for minutes on a stale agent forward, and a reclaim sweep that hangs
    is one that gets ctrl-C'd and never run again. A stale ref only makes the
    sweep more conservative, so proceeding on one is honest, not risky.
    """
    try:
        subprocess.run(["git", "fetch", "--quiet", "origin", "main"],
                       cwd=REPO, capture_output=True, timeout=45)
    except subprocess.TimeoutExpired:
        print("  (fetch timed out — surveying against the origin/main already here,")
        print("   so a recently-merged branch may still read as unmerged)")
    ref = git(["rev-parse", "--verify", "--quiet", "origin/main"], REPO)
    return ref or None


BUILD_QUIET_SECONDS = 15 * 60


def building(path: pathlib.Path) -> bool:
    """Has something written this workspace's build cache very recently?

    `running_from` catches a live cluster, but not a live BUILD: the Zig
    compiler executes from the toolchain, not from the clone, so a `zig build`
    in progress leaves no process pointing here — only a build cache being
    written. Deleting under it is the same class of confusing failure, so a
    freshly-touched cache counts as occupied.
    """
    for name in CACHE_DIRS:
        cache = path / name
        try:
            age = time.time() - cache.stat().st_mtime
        except OSError:
            continue
        if age < BUILD_QUIET_SECONDS:
            return True
    return False


def running_from(path: pathlib.Path) -> int:
    """How many live processes are executing a binary out of this workspace?

    The one trustworthy occupancy signal, because the kernel reports it rather
    than a person maintaining it: a smoke's cluster runs `<clone>/zig-out/bin/
    rewind-worker`, so its /proc/<pid>/exe points inside the clone. Reclaiming
    underneath it fails the run as a missing binary — a symptom that reads like
    a product bug from far away.

    Note what this does NOT detect: a session merely editing files there. That
    is fine. Occupancy governs the build cache, which a live run needs; whether
    anything would be LOST is a separate question, answered by git.
    """
    prefix = str(path.resolve()) + "/"
    seen = 0
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            exe = os.readlink(entry / "exe")
        except OSError:
            continue  # gone, or another user's — either way not ours to judge
        if exe.startswith(prefix):
            seen += 1
    return seen


def survey(reference: str | None) -> list[Workspace]:
    found = []
    for path in sorted(REPO.parent.glob("rove-*")):
        if path.resolve() == REPO or not (path / ".git").exists():
            continue
        found.append(Workspace(path, reference))
    return found


def report(spaces: list[Workspace]) -> None:
    if not spaces:
        print("no sibling workspaces")
        return
    width = max(len(w.path.name) for w in spaces)
    for w in spaces:
        mark = "reclaim" if w.reclaimable else "KEEP"
        why = "branch merged, tree clean" if w.reclaimable else "; ".join(w.keeps)
        print(f"  {w.path.name:<{width}}  {human(w.total):>7}  {mark:<7}  {w.branch}")
        print(f"  {'':<{width}}  {'':>7}           {why}")
    free = sum(w.total for w in spaces if w.reclaimable)
    held = sum(w.cache for w in spaces if w.trimmable)
    print(f"\n  {human(free)} in reclaimable workspaces, "
          f"{human(held)} of build cache inside the ones being kept (--trim)")


def remove(paths: list[pathlib.Path], yes: bool, label: str, past: str) -> int:
    if not paths:
        print(f"\nnothing to {label}")
        return 0
    total = sum(dir_bytes(p) for p in paths)
    print(f"\n{label}: {len(paths)} path(s), {human(total)}")
    for path in paths:
        print(f"  {path}")
    if not yes:
        print("\n(dry run — pass --yes to actually delete)")
        return 0
    for path in paths:
        shutil.rmtree(path, ignore_errors=True)
    print(f"\n{past} {len(paths)} path(s), {human(total)} freed")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("topic", nargs="?", help="short name; the workspace becomes rove-<topic>")
    ap.add_argument("--base", default="main", help="branch to start from (default: main)")
    ap.add_argument("--branch", help="branch to create (default: <topic>)")
    ap.add_argument("--dir", help="explicit destination path")
    ap.add_argument("--list", action="store_true",
                    help="survey sibling workspaces and say which hold nothing")
    ap.add_argument("--gc", action="store_true",
                    help="delete every workspace git can prove holds nothing")
    ap.add_argument("--trim", action="store_true",
                    help="delete the build caches of the workspaces --gc keeps")
    ap.add_argument("--yes", action="store_true",
                    help="actually delete; without it --gc/--trim only report")
    ap.add_argument("--except", dest="spare", action="append", default=[], metavar="NAME",
                    help="spare this workspace even if reclaimable (repeatable)")
    args = ap.parse_args()

    if args.list or args.gc or args.trim:
        spaces = survey(reference_main())
        # A spared workspace is one someone is sitting in. That is a courtesy,
        # not a safety property — the git proof already says nothing would be
        # lost — so it is a flag the caller passes, never a signal this script
        # goes looking for. See the module docstring on why no such signal is
        # trustworthy enough to consult.
        spare = {n.rstrip("/").split("/")[-1] for n in args.spare}
        unknown = spare - {w.path.name for w in spaces}
        if unknown:
            sys.exit(f"--except names no such workspace: {', '.join(sorted(unknown))}")
        for w in spaces:
            if w.path.name in spare:
                w.spared = True
                w.keeps.append("spared by --except")
        report(spaces)
        if args.gc:
            return remove([w.path for w in spaces if w.reclaimable], args.yes,
                          "remove", "removed")
        if args.trim:
            # Trim targets the workspaces --gc keeps, which are by definition
            # the ones still in use — so the exclusions matter more here, not
            # less. A spared or occupied workspace keeps its cache: deleting
            # zig-out from under a running smoke fails the suite as a missing
            # binary, which reads as a product bug rather than as this sweep.
            caches = [w.path / d for w in spaces if w.trimmable
                      for d in CACHE_DIRS if (w.path / d).exists()]
            return remove(caches, args.yes, "trim", "trimmed")
        return 0

    if not args.topic:
        ap.error("give a topic to create a workspace, or --list / --gc / --trim")

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
