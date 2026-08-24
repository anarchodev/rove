#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Loop46, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Raw memory must be initialized by struct literal, never field-by-field.

The class this guards (rove#574): `allocator.create(T)` returns RAW memory —
struct field DEFAULTS never apply — and `var x: T = undefined` is the same
thing on the stack. An init that then assigns fields piecemeal silently skips
any field it doesn't name. Zig's Debug 0xAA undefined-fill can accidentally
mask the skipped field (KvStore's stored-bytes TTL cache read 0xAA as a
never-refreshed timestamp and recomputed correctly for weeks), while
ReleaseFast heap residue surfaces it as garbage — the worst kind of
divergence: every Debug run green, production refusing deploys.

The rule: the FIRST touch of a created/undefined struct value must be a
whole-value assignment —

    x.* = .{ ... };        // create()  — defaults apply, missing fields error
    x = SomeType.init(..); // or a value-returning initializer
    x.init(...);           // or a member init that fills self.* (kvexp shape)

— never `x.field = ...`. A site that genuinely cannot use a literal (e.g. a
comptime-generated field set) carries its own compile-time completeness
guard and an allowlist entry HERE naming that guard.

Run by `zig build test`, with its siblings in `scripts/ops/*_lint.py`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent

# path substring -> reason. Keep every entry justified by a stronger guard at
# the site itself, or by being a test that deliberately partial-fills a value
# and reads only what it set.
ALLOW: dict[tuple[str, str], str] = {
    ("src/h2/root.zig", "self"): (
        "Server.create: collection fields are initialized by the COLLECTIONS "
        "inline-for; the adjacent comptime CREATE_INITIALIZES check walks the "
        "real field list and refuses to compile on any uncovered field."
    ),
    ("src/consensus/node_core.zig", "n"): (
        "test-only: setTickInterval unit test partial-fills a Node and reads "
        "only the two fields it set."
    ),
    ("src/js/worker.zig", "snap"): (
        "test-only: findBytecode test partial-fills a TenantFilesSnapshot and "
        "the callee reads only .bytecodes."
    ),
}

CREATE_RE = re.compile(
    r"(?:const|var)\s+(\w+)(?:\s*:\s*[^=]+)?\s*=\s*(?:try\s+)?[\w.]+\.create\(([\w.@\"]+)\)"
)
UNDEF_RE = re.compile(r"var\s+(\w+)\s*:\s*([A-Za-z_][\w.]*)\s*=\s*undefined;")
# Types where `= undefined` + later fill is the normal out-parameter shape.
OUT_PARAM_TYPES = re.compile(
    r"(sockaddr|Address|HeaderField)$"
)

WINDOW = 150


def first_touch(lines: list[str], start: int, var: str) -> tuple[str, int] | None:
    """(kind, lineno) of the first init-ish touch of `var` after `start`."""
    whole = re.compile(rf"\b{re.escape(var)}\.\*\s*=")
    whole_val = re.compile(rf"\b{re.escape(var)}\s*=\s*")  # x = expr (undefined-var case)
    member_init = re.compile(rf"\b{re.escape(var)}\.(?:init|initRecover)\(")
    field = re.compile(rf"(\b{re.escape(var)}\.\w+\s*=[^=])|(@memcpy\(&{re.escape(var)}\.)")
    for i in range(start, min(start + WINDOW, len(lines))):
        w = lines[i]
        if whole.search(w) or member_init.search(w):
            return ("whole", i + 1)
        if whole_val.search(w):
            return ("whole", i + 1)
        if field.search(w):
            return ("field", i + 1)
    return None


def main() -> int:
    bad: list[str] = []
    for path in sorted((REPO / "src").rglob("*.zig")):
        rel = str(path.relative_to(REPO))
        lines = path.read_text().splitlines()
        for lno, line in enumerate(lines, 1):
            hits = []
            m = CREATE_RE.search(line)
            if m:
                hits.append((m.group(1), "create"))
            mu = UNDEF_RE.search(line)
            if mu and not OUT_PARAM_TYPES.search(mu.group(2)):
                hits.append((mu.group(1), "undefined-var"))
            for var, kind in hits:
                ft = first_touch(lines, lno, var)
                if ft is None or ft[0] != "field":
                    continue
                if (rel, var) in ALLOW:
                    continue
                bad.append(
                    f"{rel}:{lno}: `{var}` ({kind}) is first touched by a FIELD "
                    f"assignment at line {ft[1]} — raw memory takes no field "
                    f"defaults; init it with a struct literal (`{var}.* = .{{...}}`)"
                )
    if bad:
        print("create-init lint FAILED — piecemeal init of raw memory (rove#574 class):\n")
        for b in bad:
            print("  " + b)
        print(f"\n{len(bad)} site(s). Fix with a struct literal, or add a stronger"
              " in-code guard + an ALLOW entry naming it.")
        return 1
    print("create-init lint OK — every raw-memory struct init is whole-value.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
