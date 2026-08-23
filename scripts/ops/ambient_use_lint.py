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

  1. **A locally-bound name is already migrated — but only in scope.**
     `({ request, kv })` on a function means uses INSIDE that function
     receive the capability. Scope matters: a file whose default export
     destructures `kv` may still have a module-scope helper reaching the
     ambient one, and that helper is exactly what breaks at the cutover.
     An earlier file-scoped version of this check hid those.
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


def _strip_literals(src: str) -> str:
    """Blank out comments and string bodies, preserving line structure.

    Without this the count is dominated by text that never executes. The
    `_tests/` scenario files pin the exact wording of engine errors —
    `row("msZero", "TypeError", "after.ms(ms): ms must be > 0")` — and a
    plain scan reads every one of those as an ambient `after` use. Those
    files need no migration at all, so counting them would make the
    ratchet unreachable and point a codemod at the wrong files.

    Template literals keep their `${...}` interpolations, which are real
    code; only the literal text between them is dropped. Regex literals
    are left alone — a capability name inside one is vanishingly rare and
    distinguishing `/` division from a regex needs a real parser.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif ch == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(c if c == "\n" else " " for c in src[i:j]))
            i = j
        elif ch in "\"'":
            j = i + 1
            while j < n and src[j] != ch:
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append("".join(c if c == "\n" else " " for c in src[i:j]))
            i = j
        elif ch == "`":
            j = i + 1
            buf = [" "]
            while j < n and src[j] != "`":
                if src[j] == "\\":
                    buf.append("  ")
                    j += 2
                    continue
                if src[j] == "$" and j + 1 < n and src[j + 1] == "{":
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if src[k] == "{":
                            depth += 1
                        elif src[k] == "}":
                            depth -= 1
                        k += 1
                    buf.append("  " + src[j + 2 : k])  # keep the interpolation
                    j = k
                    continue
                buf.append("\n" if src[j] == "\n" else " ")
                j += 1
            buf.append(" ")
            out.append("".join(buf))
            i = min(j + 1, n)
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _binding_spans(src: str, name: str) -> list[tuple[int, int]]:
    """Body extents of every function that destructures `name` in its
    parameter list, plus the rest of the block after a destructuring
    declaration. A use inside one of these is receiving the capability.
    """
    out: list[tuple[int, int]] = []
    # A parameter list naming `name` — destructured (`({ kv })`) or plain
    # (`function hold(next, ctx)`, the shape a module-scope helper takes once
    # its caller threads the capability in). Requiring a block body right
    # after the `)` is what keeps a CALL like `hold(next, { … })` from
    # reading as a binding.
    pat = re.compile(
        r"\(([^()]{0,400}?\b" + re.escape(name) + r"\b[^()]{0,400}?)\)\s*(?:=>\s*)?\{"
    )
    for m in pat.finditer(src):
        i = m.end() - 1
        depth, j = 0, i
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((i, j))
    # `const { kv } = …` binds for the remainder of its enclosing block;
    # approximating that as "to end of file" is the safe direction here —
    # it under-counts rather than inventing work.
    decl = re.compile(
        r"(?:const|let|var)\s*\{[^{}]{0,400}?\b" + re.escape(name) + r"\b[^{}]{0,400}?\}\s*="
    )
    for m in decl.finditer(src):
        out.append((m.end(), len(src)))
    return out


def _locally_bound(src: str, name: str) -> bool:
    """Kept for callers that only need "does this file bind it anywhere"."""
    return bool(_binding_spans(src, name))


def _count_file(path: Path) -> dict[str, int]:
    try:
        src = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    src = _strip_literals(src)
    out: dict[str, int] = {}
    for name in CAPABILITIES:
        bound = _binding_spans(src, name)
        # A free-variable use: not preceded by `.` or an identifier char.
        pat = re.compile(r"(?<![\w.$])" + re.escape(name) + r"\s*[.(]")
        n = sum(
            1
            for m in pat.finditer(src)
            if not any(a <= m.start() <= b for a, b in bound)
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
