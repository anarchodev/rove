#!/usr/bin/env python3
"""Every engine source file carries an SPDX header (rove#343).

A file lifted out of the tree carries no license unless it says so itself,
which matters for a repo whose pitch is "read it, fork it". The root
`LICENSE` conveys the AGPL; these headers say which files it covers.

Run with `--fix` to stamp anything missing; with no arguments it lints and
exits non-zero if any file lacks a header. Standalone, like its siblings
`doc_pointer_lint.py` and `test_reachability_lint.py` — there is no general
lint CI, so `zig build test` runs this with its siblings in
`scripts/ops/*_lint.py`.

Two trees are deliberately EXCLUDED, and the exclusions are the interesting
part of this file:

  * `src/js/starter/` — genesis starter content. These files are handed to a
    customer as *their* application, and stamping the engine's license on
    code we give away as a starting point would assert something false about
    who owns it and under what terms.

  * `src/replay/testdata/` — replay fixtures. Tiny throwaway handler modules
    that exist to be executed by a test, never distributed as source. Stamping
    ~150 of them buys nothing and makes every fixture diff noisier.

Anything else under `src/` is engine source and gets a header, including the
`@rewind/*` packages: they ship inside the binary and run in our engine, so
they are covered by the engine's license. Importing one from a handler does
not put the handler under the AGPL — that is the ordinary use of a program,
not a derivative work of it.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SRC = REPO / "src"

COPYRIGHT = "SPDX-FileCopyrightText: 2026 Loop46, Inc."
LICENSE_ID = "SPDX-License-Identifier: AGPL-3.0-or-later"
HEADER = f"// {COPYRIGHT}\n// {LICENSE_ID}\n"

SUFFIXES = {".zig", ".mjs", ".js"}

# Relative to src/. See the module docstring for why each is out.
EXCLUDED = ("js/starter/", "replay/testdata/")


def targets() -> list[Path]:
    out = []
    for p in sorted(SRC.rglob("*")):
        if not p.is_file() or p.suffix not in SUFFIXES:
            continue
        rel = p.relative_to(SRC).as_posix()
        if any(rel.startswith(x) for x in EXCLUDED):
            continue
        out.append(p)
    return out


def has_header(text: str) -> bool:
    # Only the first few lines count — an SPDX line buried mid-file is not a
    # header, and a scan of the whole text would false-pass on this very file.
    return LICENSE_ID in "".join(text.splitlines(keepends=True)[:5])


def main() -> int:
    fix = "--fix" in sys.argv[1:]
    missing = [p for p in targets() if not has_header(p.read_text(encoding="utf-8"))]

    if not missing:
        print(f"spdx lint OK — {len(targets())} engine source files carry a header.")
        return 0

    if not fix:
        for p in missing[:20]:
            print(f"missing SPDX header: {p.relative_to(REPO)}", file=sys.stderr)
        if len(missing) > 20:
            print(f"… and {len(missing) - 20} more", file=sys.stderr)
        print(
            f"\n{len(missing)} file(s) without an SPDX header. "
            f"Run: python3 scripts/ops/spdx_lint.py --fix",
            file=sys.stderr,
        )
        return 1

    for p in missing:
        p.write_text(HEADER + p.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"stamped {len(missing)} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
