#!/usr/bin/env python3
"""Doc-pointer lint: every `docs/…` path referenced in a tracked source
file must resolve to a file (or directory) that exists in the tree.

The rot this catches: a comment cites `docs/streaming-model.md`, the doc
is later deleted or renamed (e.g. the plans→issues migration folded ~30
plan docs into `docs/architecture/`), and the citation silently dangles —
nothing ever complains, so hundreds accumulate. This asserts the path
half of the doc-pointer convention (docs/architecture/… + the customer
contracts are the durable citation targets). It does NOT check `§`/anchor
validity inside a doc — that rot is why the convention prefers a concept
name over a bare section number, which no lint can verify.

Scans comment text only — the `//`/`///`/`/* */`/JSDoc `*` forms in
Zig/JS and `#` line comments in Python/shell. String literals and Python
triple-quoted docstrings are deliberately NOT scanned: `docs/` shows up
there as kv keys / tenant paths (`kv.set("docs/d1", …)`) and as other
repos' output dirs (`<apps-dir>/docs/_static/…`), neither a citation of
this tree's docs.

Exit 0 = every referenced path resolves, 1 = dangling reference(s) found.

Sibling to `globals_lint.py`; run by `zig build test` (there is no general CI
workflow yet — only `release-rewind.yml`).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent

# Source trees whose comments/strings cite docs. src/ is the engine,
# scripts/ the ops+smoke drivers, build.zig the build graph — the three
# the issue-#132 audit swept.
SCAN_ROOTS = [REPO / "src", REPO / "scripts"]
EXTRA_FILES = [REPO / "build.zig"]
SCAN_SUFFIXES = {".zig", ".js", ".mjs", ".py", ".sh", ".example"}
SKIP_DIR_PARTS = {"node_modules", ".git", ".claude", "zig-out", ".zig-cache"}

# A `docs/…` path token: `docs/` then path chars. Trailing sentence
# punctuation / backticks / a `§…` suffix are trimmed off before the
# existence check.
DOCS_REF_RE = re.compile(r"docs/[A-Za-z0-9_./-]+")
# `//` starting a line comment, but not the `//` inside a `://` URL.
_INLINE_SLASH = re.compile(r"(?<![:/])//")
# Only treat a token as a concrete file/dir pointer if it names a file
# (has a suffix) or ends in `/` (an explicit directory). A bare
# `docs/architecture` with no trailing slash is still checked as a dir.
_TRIM = "`'\").,;:*"


def _iter_files():
    for root in SCAN_ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            # Match skip-dirs against the path RELATIVE to the repo: the
            # repo root itself may sit under a `.claude/worktrees/…`
            # worktree, and that prefix must not disqualify every file.
            if any(part in SKIP_DIR_PARTS for part in path.relative_to(REPO).parts):
                continue
            if path.suffix in SCAN_SUFFIXES or path.name.endswith(".env.example"):
                yield path
    for path in EXTRA_FILES:
        if path.is_file():
            yield path


def _resolves(ref: str) -> bool:
    # ref is repo-relative, e.g. "docs/architecture/overview.md" or
    # "docs/architecture/". Accept a hit as a file OR a directory.
    p = (REPO / ref)
    return p.exists()


def _comment_text(path: Path, line: str) -> str:
    """Return the comment portion of `line`, or "" if the line is not (or
    does not contain) a comment. String literals and Python docstrings are
    not comments and yield ""."""
    stripped = line.lstrip()
    if path.suffix in (".zig", ".js", ".mjs"):
        # Zig `\\`-multiline-string lines are string content, never comments.
        if stripped.startswith("\\\\"):
            return ""
        if stripped.startswith(("//", "/*", "*")):
            return line
        m = _INLINE_SLASH.search(line)
        return line[m.start():] if m else ""
    # Python / shell / env: `#` line or inline comment. A shebang and any
    # docstring/string content (no leading/inline `#`) yield "".
    if stripped.startswith("#!"):
        return ""
    idx = line.find("#")
    return line[idx:] if idx != -1 else ""


def main() -> int:
    violations: list[str] = []
    for path in _iter_files():
        rel = path.relative_to(REPO)
        if rel == Path("scripts/ops/doc_pointer_lint.py"):
            continue  # this file's own docstring names example paths
        text = path.read_text(errors="replace")
        for n, line in enumerate(text.splitlines(), 1):
            comment = _comment_text(path, line)
            if not comment:
                continue
            for m in DOCS_REF_RE.finditer(comment):
                ref = m.group(0).rstrip(_TRIM)
                # A token with no dot and no trailing slash could be a
                # bare dir ("docs/architecture") — still checked. Skip
                # only the empty/degenerate "docs/" itself.
                if ref in ("docs", "docs/"):
                    continue
                if not _resolves(ref):
                    violations.append(f"{rel}:{n}: {ref}")

    if violations:
        # de-dup identical (file:line:ref) tuples while preserving order
        seen = set()
        uniq = [v for v in violations if not (v in seen or seen.add(v))]
        print("doc-pointer lint FAILED — source cites docs/ paths that do "
              "not exist. Repoint to the surviving reference doc "
              "(docs/architecture/… or a customer contract), by concept:\n")
        for v in uniq:
            print("  " + v)
        print(f"\n{len(uniq)} dangling doc reference(s).")
        return 1

    print("doc-pointer lint OK — every docs/ path cited in src/, scripts/, "
          "and build.zig resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
