#!/usr/bin/env python3
"""Phase A lint (a): customer/app JS must never reference the internal
`_system.*` ABI (docs/plans/builtin-libs-docs-plan.md).

The public surface is the doc-commented shims in `src/js/globals/*.js`
— those are the ONLY legitimate referrers of `_system` and are not
scanned. Everything a tenant/app deploys (examples/loop46-demo-tenants,
web/) must call the public top-level names (`kv`, `crypto`, …) instead.

Lints (b) "every globals/*.js export is documented" and (c) "every
native binding has a globals/ shim" are hermetic and enforced by
`zig build test` (inline tests in src/js/globals.zig); only (a) is a
repo-tree scan, which is why it lives here rather than as a unit test.

Heuristic, with two deliberate exclusions (a plain substring match
false-positives on both):

  1. `/_system/...` is the unrelated root-token HTTP surface (a URL
     path), not the `_system.*` JS namespace. A `_system` immediately
     preceded by `/` is skipped.
  2. The `kvshim` / `kvdirect` benchmark tenants intentionally declare
     a LOCAL `const _system = {...}` stand-in to measure shim cost
     (scripts/kv_shim_overhead_bench.sh). A file that declares its own
     `_system` is using a local, not the platform global — skipped.
  3. Comments don't execute — a `//`-comment or ` *` JSDoc line that
     merely mentions `_system` is not a reference.

Exit 0 = clean, 1 = violation(s) found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Trees that hold tenant/app handler code (deployed JS). src/ is the
# engine (src/js/globals/*.js legitimately defines the shims over
# _system) and is intentionally NOT scanned.
SCAN_ROOTS = [
    REPO / "examples" / "loop46-demo-tenants",
    REPO / "web",
]
SKIP_DIR_PARTS = {"node_modules", ".git"}

# `_system` used as a namespace member access (`_system.kv`), not
# preceded by `/` (HTTP path) or a word char (e.g. `my_system`).
REF_RE = re.compile(r"(?<![\w/])_system\s*\.")
# File declares its own local `_system` (the bench stand-in pattern).
LOCAL_DECL_RE = re.compile(r"\b(?:const|let|var)\s+_system\b|{\s*_system\s*}")


def _is_comment(line: str) -> bool:
    s = line.lstrip()
    return s.startswith("//") or s.startswith("*") or s.startswith("/*")


def main() -> int:
    violations: list[str] = []
    for root in SCAN_ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.suffix not in (".js", ".mjs"):
                continue
            if any(part in SKIP_DIR_PARTS for part in path.parts):
                continue
            text = path.read_text(errors="replace")
            if LOCAL_DECL_RE.search(text):
                continue  # local `_system` stand-in (bench tenants)
            rel = path.relative_to(REPO)
            for n, line in enumerate(text.splitlines(), 1):
                if _is_comment(line):
                    continue
                if REF_RE.search(line):
                    violations.append(f"{rel}:{n}: {line.strip()}")

    if violations:
        print("Phase A lint(a) FAILED — customer/app JS references the "
              "internal `_system.*` ABI. Use the public top-level name "
              "(it is a shim over _system):\n")
        for v in violations:
            print("  " + v)
        print(f"\n{len(violations)} violation(s).")
        return 1

    print("Phase A lint(a) OK — no customer/app `_system.*` references "
          "(lints b/c run under `zig build test`).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
