#!/usr/bin/env python3
"""The tape format's JS mirror must move with the Zig one.

`src/rewind/version.zig` states the rule — the tape version "must lockstep
with rtap.mjs / wasm-app.mjs" — and until this lint nothing enforced it. The
node gate in `build.zig` covers the interaction DIGEST only, and the
`RTAP_VERSION` assertion lives in rewind-apps' own e2e suite, which rove's
gate does not run. So a wire-format bump in rove could land green against a
stale decoder in the submodule it pins.

That failure is expensive precisely because it is remote from its cause: the
browser replay arena decodes a tape it half-understands and reports a
DIVERGENCE, which reads as a handler or engine bug rather than as a decoder
one version behind. `src/tape/root.zig`'s own version notes say the guard
exists so "a stale reader rejects loudly rather than misreads" — this lint is
that guard for the reader rove cannot compile.

Checks:
  * `tape.VERSION` (src/tape/root.zig) == `RTAP_VERSION` (web's rtap.mjs)
  * the offline decoder's copy stays in lockstep too, since the comment beside
    it promises exactly that

`web/` is the pinned rewind-apps submodule. Its absence is a hard failure
rather than a skip: a lint that quietly passes when it cannot see its subject
is indistinguishable from one that works, which is how the lints this file
sits beside had all rotted (see `build.zig`'s standalone-lint note).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

ZIG_TAPE = ROOT / "src" / "tape" / "root.zig"
ZIG_DECODE = ROOT / "src" / "replay" / "tape_decode.zig"
JS_MIRROR = ROOT / "web" / "replay" / "_static" / "rtap.mjs"

ZIG_RE = re.compile(r"^pub const VERSION: u16 = (\d+);", re.M)
JS_RE = re.compile(r"^export const RTAP_VERSION = (\d+);", re.M)


def read_one(path: Path, pattern: re.Pattern[str], what: str) -> int | None:
    if not path.exists():
        print(f"tape-mirror-lint: {path.relative_to(ROOT)} is missing", file=sys.stderr)
        if path == JS_MIRROR:
            print(
                "  the `web` submodule is not materialized — run "
                "`git submodule update --init` (or use scripts/ops/workspace.py, "
                "which does it for you).",
                file=sys.stderr,
            )
        return None
    m = pattern.search(path.read_text())
    if not m:
        print(
            f"tape-mirror-lint: could not find {what} in "
            f"{path.relative_to(ROOT)} — has it been renamed? This lint is the "
            "only thing keeping the two halves in step, so a silent miss here "
            "is worse than a false alarm.",
            file=sys.stderr,
        )
        return None
    return int(m.group(1))


def main() -> int:
    zig = read_one(ZIG_TAPE, ZIG_RE, "`pub const VERSION`")
    dec = read_one(ZIG_DECODE, ZIG_RE, "`pub const VERSION`")
    js = read_one(JS_MIRROR, JS_RE, "`export const RTAP_VERSION`")
    if zig is None or dec is None or js is None:
        return 1

    failed = False
    if zig != dec:
        print(
            f"tape-mirror-lint: src/tape/root.zig says v{zig} but "
            f"src/replay/tape_decode.zig says v{dec}. These are asserted in "
            "lockstep at comptime too; fix both.",
            file=sys.stderr,
        )
        failed = True
    if zig != js:
        print(
            f"tape-mirror-lint: the tape format is v{zig} but the JS mirror "
            f"(web/replay/_static/rtap.mjs) decodes v{js}.\n"
            "  A tape version bump is a CROSS-REPO change: update rtap.mjs in "
            "rewind-apps, push that branch, and bump the `web` pin in the same "
            "PR (push-then-pin). Without it the browser replay arena reports a "
            "divergence instead of a version mismatch.",
            file=sys.stderr,
        )
        failed = True

    if failed:
        return 1
    print(f"tape-mirror-lint: ok (tape v{zig} == rtap v{js})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
