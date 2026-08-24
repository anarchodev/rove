#!/usr/bin/env python3
"""Test-reachability lint: every `src/**/*.zig` that declares tests must be
reachable from a test root, or its tests never compile and never run.

The rot this catches: Zig only includes tests from files it pulls into a test
build. Importing a file for its declarations — `const x = @import("x.zig");` —
does NOT bring its tests along; a module root has to reference it from inside a
`test { }` block (or `refAllDecls`). Miss that line and the tests still look
right, still get written, still get maintained, and never execute. A green
suite says nothing about them.

That failure is invisible from every direction that normally protects you: the
file has tests, the build passes, the test count goes up. The only way to
notice is to deliberately break an assertion and watch the suite stay green —
which nobody does by habit. So the build has to say it instead.

Exit 0 = every test file is reachable, 1 = orphaned test file(s) found.

Run by `zig build test`, with its siblings in `scripts/ops/*_lint.py`.
"""
from __future__ import annotations

import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def module_roots(build_zig: str) -> set[str]:
    """The root source files handed to `addTest` — where test compilation starts."""
    mods: dict[str, str] = {}
    for pat in (
        r'(\w+)\s*=\s*b\.addModule\("[^"]+",\s*\.\{\s*\.root_source_file\s*=\s*b\.path\("([^"]+)"\)',
        r'(\w+)\s*=\s*b\.createModule\(\.\{\s*\.root_source_file\s*=\s*b\.path\("([^"]+)"\)',
    ):
        mods.update(dict(re.findall(pat, build_zig)))

    roots = {mods[m] for m in re.findall(r"addTest\(\.\{\s*\.root_module\s*=\s*(\w+)", build_zig) if m in mods}
    # Targets given a path directly rather than a module.
    roots |= set(re.findall(r'addTest\(\.\{[^}]*\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', build_zig))
    return roots


def pulled_into_tests(text: str, path: str) -> set[str]:
    """Files `path` drags into test compilation."""
    targets: set[str] = set()
    if "refAllDecls" in text:
        targets |= {m[1] for m in re.findall(r'@import\("(\./)?([\w/.\-]+\.zig)"\)', text)}
    for block in re.findall(r"\ntest\s*\{(.*?)\n\}", text, re.S):
        targets |= set(re.findall(r'_\s*=\s*@import\("([^"]+\.zig)"\)', block))
        # `_ = alias;` where `const alias = @import("…")` above.
        for alias in re.findall(r"_\s*=\s*(\w+)\s*;", block):
            m = re.search(r"const\s+" + re.escape(alias) + r'\s*=\s*@import\("([^"]+\.zig)"\)', text)
            if m:
                targets.add(m.group(1))

    base = (ROOT / path).parent
    out: set[str] = set()
    for t in targets:
        cand = (base / t).resolve()
        if cand.exists() and str(cand).startswith(str(ROOT)):
            out.add(str(cand.relative_to(ROOT)))
    return out


def main() -> int:
    build_zig = (ROOT / "build.zig").read_text()
    roots = module_roots(build_zig)
    if not roots:
        print("test-reachability lint: found no test roots in build.zig — the lint cannot work; fix the parser", file=sys.stderr)
        return 1

    reachable: set[str] = set()
    queue = collections.deque(roots)
    while queue:
        cur = queue.popleft()
        if cur in reachable:
            continue
        reachable.add(cur)
        f = ROOT / cur
        if f.exists():
            queue.extend(nxt for nxt in pulled_into_tests(f.read_text(), cur) if nxt not in reachable)

    orphans: dict[str, int] = {}
    total = 0
    for f in sorted((ROOT / "src").rglob("*.zig")):
        n = len(re.findall(r'^test\s+"', f.read_text(), re.M))
        if not n:
            continue
        total += n
        rel = str(f.relative_to(ROOT))
        if rel not in reachable:
            orphans[rel] = n

    if not orphans:
        print(f"test-reachability lint OK — all {total} tests in src/ are reachable from a test root.")
        return 0

    print(f"test-reachability lint FAILED — {sum(orphans.values())} of {total} tests never compile:\n")
    for rel, n in sorted(orphans.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n:>3} test(s)  {rel}")
    print(
        "\nEach file above declares tests that no test build includes. Reference it from its\n"
        "module's root inside a `test { }` block:\n"
        '\n    test {\n        _ = @import("thatfile.zig");\n    }\n'
        "\n(or `_ = alias;` when the root already imports it). Verify by breaking an assertion\n"
        "in the file and confirming the suite goes red — a test you have not seen fail is a\n"
        "test you have not seen run."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
