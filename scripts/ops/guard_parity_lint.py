#!/usr/bin/env python3
"""Every handler-facing guard is enforced by every engine — or the gap is tracked.

Two enforcement surfaces remain. The NATIVE engines — the worker AND the
sim/native replay driver — run the checks inside the common binding
(`rove-binding`), one implementation, so they are one surface here; the
browser arena still evaluates the emitted JS its prelude composes
(`gen_replay_prelude.py`), until the in-tree wasm. Sharing rule text removes
drift between copies, but it cannot make a MISSING guard visible: the arena
went without every kv guard for as long as it did because nobody had a list
saying it should have them (rove#502). Absence has no author and shows up in
no diff.

This is that list, as a check rather than a document. Each entry names a
guard by the marker a customer would see — the error code where there is one,
otherwise a distinctive fragment of the message — and asserts it appears in
every engine's enforcement surface. A guard added to one engine and not the
others fails here, at the moment of the change.

What it deliberately does NOT do is compare behaviour; that is the
conformance corpus' job, and it is strictly better evidence. This is the
cheap half: presence, so a rule cannot be silently absent from an engine no
one was thinking about. A marker present but wrong is what conformance
catches; a marker missing entirely is what this catches, and the corpus can
only catch that with a case somebody remembered to write.

Known gaps are declared, not discovered. An engine that legitimately (or
merely currently) lacks a guard needs an entry with an issue number and a
reason, mirroring the conformance allowlist — so the inventory shows the gap
instead of hiding it, and the gap has somewhere to be argued about.

Usage:
    guard_parity_lint.py            check; non-zero on an untracked gap
    guard_parity_lint.py --table    print the inventory as markdown
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import pathlib
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]


# ── the engines, and where each one's enforcement lives ──────────────────
#
# `native` is Zig (the common binding + the worker's delegate files); the
# arena is the JS text its prelude builder
# composes. Reading the composed text rather than the source files is what
# makes the arena checkable from this repo at all — `build()` assembles it
# from rove sources alone, which is the same property the digest gate rests
# on.
def _worker_surface() -> str:
    # `src/guards/root.zig` first: the rules moved there, and a surface list
    # that lags the code reports the move as a gap. That has now happened
    # twice — once for the arena's second file, once here — which is the
    # standing weakness of defining a surface by enumerating paths.
    paths = [ROVE / "src" / "guards" / "root.zig"]
    # The common binding (`rove-binding`) is where the worker's coercion +
    # guard call live now; the globals_* files hold the worker delegate and
    # the surfaces that have not yet moved onto the binding.
    paths += [ROVE / "src" / "binding" / "root.zig"]
    paths += [ROVE / "src" / "js" / p
              for p in ("globals.zig", "globals_kv.zig", "globals_request.zig")]
    return "\n".join(p.read_text(encoding="utf-8") for p in paths)


# There is no separate sim surface any more: the sim / native replay driver
# registers the SAME common binding the worker registers (rove-binding), so
# its enforcement lives in the worker row's files. Listing it again would
# either read the generated JS it no longer evaluates (a false "yes") or
# duplicate the worker row.


def _arena_surface() -> str | None:
    """The arena's enforcement is in TWO places, and reading one of them was
    a bug in the first version of this lint.

    Its base prelude is composed from rove sources, so it is readable here.
    But the arena also has its OWN epilogue — `replay/_static/request-replay.mjs`
    in rewind-apps, which builds the `request` surface and holds guards of its
    own. Checking only the base reported six `request.tag` guards as missing
    when the arena had every one of them, and a lint that invents gaps teaches
    people to skip reading it.

    So: read both when the sibling checkout is reachable, and return None when
    it is not. None means UNVERIFIABLE, which is reported and is not a gap —
    "I could not look" and "it is not there" are different claims and only one
    of them is this lint's to make.
    """
    spec = importlib.util.spec_from_file_location(
        "gen_replay_prelude", ROVE / "scripts" / "ops" / "gen_replay_prelude.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    base = mod.build()

    apps = os.environ.get("REWIND_APPS_DIR")
    epilogue = pathlib.Path(apps).expanduser() / "replay" / "_static" / "request-replay.mjs" if apps else None
    if epilogue is None or not epilogue.is_file():
        return None
    return base + "\n" + epilogue.read_text(encoding="utf-8")


ENGINES = {
    "native": _worker_surface,
    "arena": _arena_surface,
}


# ── the inventory ────────────────────────────────────────────────────────
#
# `marker` is what a customer sees, so the check tracks the contract rather
# than an implementation detail: renaming an internal helper does not move
# it, and changing the error a handler catches does.
#
# Use the INVARIANT part of the message. A shared guard builds "…must be
# 1..32 bytes" by interpolating the cap it was generated with, so a marker
# carrying the number matches the worker's Zig literal and misses the JS that
# produces the identical string at runtime — a false gap, which is worse than
# no check because it trains people to skip the output.
GUARDS = [
    # (surface, rule, marker)
    ("kv.set / kv.delete", "key or value is not a string-coercible type",
     "must be a string (or number"),
    ("kv.set / kv.delete", "key is in a platform-reserved prefix", "reserved_key"),
    ("kv.set / kv.delete", "key exceeds the byte cap", "key_too_large"),
    ("kv.set", "value exceeds the byte cap", "value_too_large"),
    ("request.tag", "key length within the byte cap", "request.tag: key length must be 1.."),
    ("request.tag", "key may not start with '_'", "keys starting with '_' are reserved"),
    ("request.tag", "key charset is [a-z0-9_]", "key must match"),
    ("request.tag", "value length within the byte cap", "request.tag: value length must be 1.."),
    ("request.tag", "value has no control characters", "must not contain control characters"),
    ("request.tag", "at most 4 tags per request", "too many tags"),
]

# (marker, engine) -> (issue, why). A declared gap is still a gap; this only
# means someone looked at it and it has a home.
# (marker, engine) -> (issue, why). A declared gap is still a gap; this only
# means someone looked at it and it has a home. Empty today.
KNOWN_GAPS: dict[tuple[str, str], tuple[str, str]] = {}


def check() -> int:
    surfaces = {name: fn() for name, fn in ENGINES.items()}
    unreadable = [e for e, text in surfaces.items() if text is None]
    untracked: list[str] = []
    tracked: list[str] = []
    stale: list[str] = []

    for surface, rule, marker in GUARDS:
        for engine in ENGINES:
            if surfaces[engine] is None:
                continue
            present = marker in surfaces[engine]
            gap = KNOWN_GAPS.get((marker, engine))
            if present and gap:
                stale.append(
                    f"{engine}: '{rule}' is enforced now — drop its KNOWN_GAPS "
                    f"entry ({gap[0]})")
            elif not present and gap:
                tracked.append(f"{engine:7} {surface:19} {rule}  [{gap[0]}]")
            elif not present:
                untracked.append(f"{engine:7} {surface:19} {rule}   marker: {marker!r}")

    if unreadable:
        for e in unreadable:
            print(f"UNVERIFIABLE: {e} — part of its enforcement lives in the "
                  f"rewind-apps checkout; set REWIND_APPS_DIR to check it")
        print()
    if tracked:
        print("tracked gaps (declared, with an issue):")
        for t in tracked:
            print("  " + t)
        print()
    if stale:
        print("STALE KNOWN_GAPS — the guard landed and the entry outlived it:")
        for s in stale:
            print("  " + s)
        print()
    if untracked:
        print("UNTRACKED GAPS — an engine does not enforce a rule the others do:")
        for u in untracked:
            print("  " + u)
        print()
        print("Either enforce it in that engine, or add a KNOWN_GAPS entry with an")
        print("issue number. A guard missing from one engine means a handler behaves")
        print("differently there — and for replay that means a run can look")
        print("successful where the real one refused.")

    if untracked or stale:
        return 1
    checked = len(ENGINES) - len(unreadable)
    print(f"guard parity OK — {len(GUARDS)} guard(s) across {checked}/{len(ENGINES)} "
          f"engines, {len(tracked)} tracked gap(s)"
          + (f", {len(unreadable)} unverifiable" if unreadable else ""))
    return 0


def table() -> int:
    surfaces = {name: fn() for name, fn in ENGINES.items()}
    print("| surface | rule | native | arena |")
    print("|---|---|---|---|")
    for surface, rule, marker in GUARDS:
        cells = []
        for engine in ENGINES:
            if surfaces[engine] is None:
                cells.append("?")
            elif marker in surfaces[engine]:
                cells.append("yes")
            else:
                gap = KNOWN_GAPS.get((marker, engine))
                cells.append(f"no ({gap[0]})" if gap else "**NO**")
        print(f"| `{surface}` | {rule} | " + " | ".join(cells) + " |")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", action="store_true",
                    help="print the inventory as markdown instead of checking")
    args = ap.parse_args()
    return table() if args.table else check()


if __name__ == "__main__":
    sys.exit(main())
