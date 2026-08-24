#!/usr/bin/env python3
"""Reserved-header lint: a platform-reserved header NAME is spelled once,
in the registry, and referenced everywhere else.

The rot this catches (docs/defect-patterns.md class 3, the same class
`src/wire/root.zig` was created for): `x-rewind-move-secret` was typed out
in six files across four binaries, `x-rewind-snapshot-{index,term,mode}` in
both halves of the streamed catch-up, and `x-rewind-leader` on both sides
of the worker→front 421 hint. Two costs, and the second is the one that
bites:

  1. A pair that disagrees on a spelling fails at the far end as a MISSING
     header — absent-vs-malformed, decided by the receiver, far from the
     edit.
  2. The reservation is only worth what its enumerability is worth. The
     inbound strip, the response gate, and the replay mirror all reason
     about "a reserved header", and rove#836 adds a verifier that must
     reason about the whole set at once. A name that exists only as a
     literal inside one call site is invisible to every one of them.

The rule: inside a Zig string literal, `x-rewind-<name>` /
`x-rove-internal-<name>` may appear only in the two files that own the
vocabulary. A BARE prefix (`"x-rewind-"`) and prose (`x-rewind-*`) are
fine anywhere — those are the prefix rule, not a name. A name embedded in
a longer token (`"my-x-rewind-thing"` — a lint fixture proving the prefix
does NOT match mid-name) is fine too: the match must not be preceded by a
name character. A `test "..."` TITLE is prose in the same sense a comment
is — nothing reads it, so it cannot disagree with the registry, and
keeping the real name there is what makes the test greppable by header
name.

The intended fix for a hit is to add the name to `src/wire/headers.zig` and
reference the constant — including in a user-facing message, where
`"missing " ++ wire.TENANT ++ "\\n"` keeps the message and the wire in
agreement.

Not covered, deliberately: the Python smokes (`scripts/smoke/`), which are
out-of-process clients of the same wire and mirror it the way
`smoke_lib_v2.attach_join` mirrors `encodeAttach` — a Zig constant is not
reachable from them, and what keeps them honest is that they drive the
real endpoints.

Exit 0 = clean, 1 = a name spelled outside the registry.

Run by `zig build test`, with its siblings in `scripts/ops/*_lint.py`.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# The two files that own the vocabulary. Everything else references them.
ALLOW = (
    # THE registry: one `pub const` per name on the internal wire.
    # (`src/wire/root.zig` re-exports it by ALIAS, so it holds no literal
    # and needs no exemption — which is the property being enforced.)
    "src/wire/headers.zig",
    # The prefix authority — what makes a name reserved at all. Its own
    # tests must be able to write example names (including ones no
    # constant exists for) to prove the predicate's edges.
    "src/js/reserved_headers.zig",
)

# A reserved name: a reserved prefix followed by at least one name
# character. The lookbehind keeps `my-x-rewind-thing` out (a name char
# before the prefix means this is a longer token, not a header name) and
# keeps prose out too, since `x-rewind-*` has no name character after the
# prefix.
NAME_RE = re.compile(r"(?<![-A-Za-z0-9])x-(?:rewind|rove-internal)-[A-Za-z0-9]", re.IGNORECASE)

# Zig string literals on a line: "..." (escapes respected) and the `\\`
# multiline form, whose whole remainder is literal text.
QUOTED_RE = re.compile(r'"(?:[^"\\\n]|\\.)*"')
MULTILINE_RE = re.compile(r"\\\\(.*)$")
# `test "…" {` — a title, not a wire spelling.
TEST_TITLE_RE = re.compile(r'^\s*test\s+"')


def literals(line: str) -> list[str]:
    """Every string-literal payload on `line`, comments excluded."""
    ml = MULTILINE_RE.search(line)
    if ml:
        return [ml.group(1)]
    # Zig has no /* */ comments; a `//` outside a literal starts one.
    code, out, i, in_str = [], [], 0, False
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "/" and line[i : i + 2] == "//":
            break
        code.append(ch)
        i += 1
    for m in QUOTED_RE.finditer("".join(code)):
        out.append(m.group(0)[1:-1])
    return out


def main() -> int:
    hits: list[str] = []
    for path in sorted((ROOT / "src").rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in ALLOW:
            continue
        for i, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if TEST_TITLE_RE.match(raw):
                continue
            for lit in literals(raw):
                m = NAME_RE.search(lit)
                if m:
                    hits.append(f"{rel}:{i}: reserved header name {m.group(0)}… spelled here — use the registry constant (`wire.…`)")

    if hits:
        print("reserved-header lint: FAIL\n")
        for h in hits:
            print("  " + h)
        print(
            f"\n{len(hits)} literal(s). A platform-reserved header name belongs in\n"
            "src/wire/headers.zig once; reference the constant here (a message can\n"
            'concatenate it: `"missing " ++ wire.TENANT ++ "\\n"`).'
        )
        return 1

    print("reserved-header lint: clean — every reserved name comes from the registry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
