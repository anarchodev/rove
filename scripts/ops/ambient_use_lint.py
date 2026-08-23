#!/usr/bin/env python3
"""Ratchet for the received-not-ambient migration (tracker #753).

Counts places where customer-shaped JS still reaches a **capability** as
an ambient global rather than receiving it from the activation object
(`docs/architecture/package-isolation.md`). The count is the size of the
remaining migration, and it may only ever go DOWN — a rising number means
new code was written in the idiom being retired.

Why a ratchet and not a hard ban: the migration is a dual-support window
across two repos, three engines and ~200 corpus artifacts, and a corpus
that size cannot flip atomically. The window's known failure mode is that
it never closes and both idioms ship forever, so the tail has to be a
number in the gate rather than a vibe. `--update` re-records the ceiling;
**a ceiling change is a claim about progress and belongs in the PR that
earned it**, never as drive-by maintenance in an unrelated one.

A capability is a name that reaches outside the module (the §3.1
classification rule). The authority for the set is `CAPABILITY_NAMES` in
`src/reserved/root.zig`, which every engine builds its activation object
from; this script reads it rather than holding a copy.

Heuristics, each a deliberate under-count rather than a false alarm:

  1. **A locally-bound name is already migrated.** `({ request, kv })`
     in a signature, or `const { kv } = ...`, means the file receives the
     capability — every later `kv.foo()` in it is the NEW idiom, so the
     name is skipped for that whole file. This is what makes the number
     mean "unmigrated" rather than "mentions a capability".
  2. **Comments don't execute.** `//` and ` *` lines are skipped.
  3. **Member access isn't a free variable.** `foo.kv.get()` is a
     property chain, not the global.
  4. Node-side scripts (`web/e2e/`) never run in a handler engine, and
     `_static/` is browser assets. Neither is customer handler code.

Exit 0 = at or under the ceiling, 1 = over it (or `--update` wrote a new
one).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent

def _capabilities() -> tuple[str, ...]:
    """Read the list from its Zig authority rather than holding a copy.

    `rove-reserved`'s `CAPABILITY_NAMES` is what the worker, the replay
    driver and the browser arena all build their activation object from.
    A second copy here would drift, and the drift would be invisible: a
    name dropped from it simply stops being counted, so the ratchet would
    report progress that never happened.
    """
    src = (REPO / "src" / "reserved" / "root.zig").read_text(encoding="utf-8")
    m = re.search(r"CAPABILITY_NAMES\s*=\s*\[_\]\[[^\]]*\]const u8\s*\{(.*?)\}", src, re.S)
    if not m:
        raise SystemExit(
            "ambient-use lint: CAPABILITY_NAMES not found in "
            "src/reserved/root.zig — the list moved; follow it."
        )
    names = tuple(re.findall(r'"([^"]+)"', m.group(1)))
    if not names:
        raise SystemExit("ambient-use lint: CAPABILITY_NAMES is empty")
    return names


CAPABILITIES = _capabilities()

# Trees holding customer-shaped handler JS — code that runs in an engine
# and will have to receive its effects.
TREES = (
    "web",
    "src/replay/testdata",
    "src/js/surface_tests",
)

SKIP_PARTS = ("_static", "node_modules", ".git")
SKIP_DIRS = ("web/e2e",)

CEILING_FILE = REPO / "scripts" / "ops" / "ambient_use_ceiling.txt"


def _is_comment(line: str) -> bool:
    t = line.lstrip()
    return t.startswith("//") or t.startswith("*") or t.startswith("/*")


def _locally_bound(src: str, name: str) -> bool:
    """True if the file destructures `name` — i.e. already migrated.

    Matches the two shapes that matter: a destructuring declaration
    (`const { kv } = …`) and a destructured parameter
    (`({ request, kv }) =>`, `function h({ kv })`). Braces are matched
    non-greedily and without nesting, which is enough for a signature or
    a declaration and avoids swallowing a whole function body.
    """
    pat = re.compile(r"[\(,=]\s*\{[^{}]{0,300}\b" + re.escape(name) + r"\b[^{}]{0,300}\}")
    return bool(pat.search(src))


def _count_file(path: Path) -> dict[str, int]:
    try:
        src = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    out: dict[str, int] = {}
    for name in CAPABILITIES:
        if _locally_bound(src, name):
            continue  # migrated: it receives this capability
        # A free-variable use: not preceded by `.` or an identifier char.
        pat = re.compile(r"(?<![\w.$])" + re.escape(name) + r"\s*[.(]")
        n = sum(
            len(pat.findall(line))
            for line in src.splitlines()
            if not _is_comment(line)
        )
        if n:
            out[name] = n
    return out


def scan() -> tuple[int, dict[str, dict[str, int]]]:
    per_tree: dict[str, dict[str, int]] = {}
    total = 0
    for tree in TREES:
        root = REPO / tree
        if not root.exists():
            continue
        acc: dict[str, int] = {}
        for path in sorted(root.rglob("*")):
            if path.suffix not in (".js", ".mjs") or not path.is_file():
                continue
            rel = path.relative_to(REPO).as_posix()
            if any(p in path.parts for p in SKIP_PARTS):
                continue
            if any(rel.startswith(d + "/") for d in SKIP_DIRS):
                continue
            for name, n in _count_file(path).items():
                acc[name] = acc.get(name, 0) + n
                total += n
        if acc:
            per_tree[tree] = acc
    return total, per_tree


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--update",
        action="store_true",
        help="re-record the ceiling (only in the PR that earned the drop)",
    )
    args = ap.parse_args()

    total, per_tree = scan()

    for tree, acc in per_tree.items():
        detail = ", ".join(f"{k}={v}" for k, v in sorted(acc.items()))
        print(f"  {tree}: {sum(acc.values())}  ({detail})")
    print(f"ambient capability uses: {total}")

    if args.update:
        CEILING_FILE.write_text(f"{total}\n", encoding="utf-8")
        print(f"ceiling re-recorded at {total} — explain the drop in the PR")
        return 1  # never silently green on a write

    if not CEILING_FILE.exists():
        print(f"no ceiling recorded; run with --update", file=sys.stderr)
        return 1

    ceiling = int(CEILING_FILE.read_text().strip())
    if total > ceiling:
        print(
            f"\nambient-use lint: {total} > ceiling {ceiling}.\n"
            f"New code reached a capability as an ambient global. Receive it "
            f"from the activation object instead — see\n"
            f"docs/architecture/package-isolation.md §3.2 (tracker #753).",
            file=sys.stderr,
        )
        return 1
    if total < ceiling:
        print(
            f"\nambient-use lint: {total} < ceiling {ceiling} — migration "
            f"progressed. Re-record it in THIS pr:\n"
            f"  python3 scripts/ops/ambient_use_lint.py --update",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
