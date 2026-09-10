#!/usr/bin/env python3
"""The provenance stamp for the browser replay arena's wasm artifact.

`qjs_arena_wasm.{js,wasm}` is committed in rewind-apps but BUILT from this
repo: six rove Zig modules plus the pinned arenajs C sources, linked by
`build_wasm_arena.sh` through arenajs's `ROVE_ARENA` seam. `zig build
wasm-arena` is an explicit step that needs emsdk and is deliberately not part
of `test` — so the workflow is "rebuild here, copy there, republish", and
nothing used to check that it happened.

That silence is the whole problem. The arena is a separate engine running
compiled copies of the worker's checks, so when its inputs move and the
artifact does not, it enforces rules the other two engines have dropped (or
drops rules they enforce) and every replay of an affected record reports as
diverged. It has happened twice, and both times the divergence was legible
only after checking provenance by hand — `strings` on the wasm, `git log` on
the submodule path — which read as "the corpus pins deleted behaviour" and
nearly got a real signal written off (rove#865).

So the artifact carries a stamp: a digest over its inputs, written beside it
and committed with it. The conformance replay adapter compares the stamp to
the sources in the checkout it is running from, and refuses with one sentence
instead of N unexplained divergences.

## Why the stamp travels with the ARTIFACT, not with the sources

It records a property of the *pair* — "this artifact was built from those
sources" — so it has to live next to the artifact in rewind-apps. A digest
recorded in rove (the shape `arena-prelude.js` uses) would compare rove
against rove: check out an older apps pin with a newer rove and it passes,
which is exactly the combination that is broken.

## Why only a build can establish a true stamp

`--write` is invoked by `build_wasm_arena.sh` after a successful link, so the
stamp and the artifact come out of one run. There is deliberately no
convenience flag for stamping without building: `gen_replay_prelude.py`'s
`--record` can be run on its own, and its own error text has to warn that
"recording without regenerating defeats the check". Here the build IS the
recording step, so that gap does not exist.

`--established asserted` is the one exception, for adopting a baseline on an
artifact that was built before stamps existed. It claims only that the
artifact's provenance was established some other way; the verifier repeats
that caveat when such a baseline fails, because an asserted stamp cannot rule
out that the artifact was already stale when it was adopted.

Usage:
  python3 scripts/ops/arena_wasm_inputs.py                      # print the digest
  python3 scripts/ops/arena_wasm_inputs.py --write <dir>        # stamp a build output
  python3 scripts/ops/arena_wasm_inputs.py --check <apps-dir>   # the gate
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]

# The rove half of the arena's module graph, exactly as
# `build_wasm_arena.sh` assembles it. Each is a single-file module that
# imports no sibling, so this list is the complete transitive set rather
# than a set of roots — verified by there being no `@import("….zig")` in
# any of them. If one ever gains a sibling import, this list must grow
# with it, or the digest under-covers and the gate reports fresh on a
# changed input, which is worse than no gate.
SOURCES = (
    "src/arena/root.zig",
    "src/binding/root.zig",
    "src/guards/root.zig",
    "src/tape/interaction_digest.zig",
    "src/sizing/root.zig",
    "src/reserved/root.zig",
)

# `build_wasm_arena.sh` is deliberately NOT in that list, even though the link
# flags and the module graph live there and editing them does change the
# artifact. Every false positive here costs an emsdk rebuild, which most
# contributors cannot do — and a rule whose violations cannot be cleared gets
# worked around, in this case by hand-editing the very stamp that is supposed
# to be unforgeable. A comment added to the recipe must not be able to report
# the artifact stale. The uncovered case (someone edits the flags and does not
# rebuild) is narrow by construction: you edit the recipe in order to run it,
# and running it re-stamps.

SIDECAR_NAME = "qjs_arena_wasm.inputs"
REL_SIDECAR = pathlib.PurePosixPath("replay/_static") / SIDECAR_NAME


def arenajs_pin() -> str:
    """The pinned arenajs package hash — the C half of the artifact.

    Read from `build.zig.zon` rather than passed in, so a pin bump moves the
    digest on its own. The hash is the right field: it covers the package
    contents, where the URL's commit is only a name for them.
    """
    zon = (ROVE / "build.zig.zon").read_text(encoding="utf-8")
    m = re.search(r"\.arenajs\s*=\s*\.\{.*?\.hash\s*=\s*\"([^\"]+)\"", zon, re.S)
    if not m:
        raise SystemExit(
            "arena_wasm_inputs: the arenajs pin's .hash was not found in "
            "build.zig.zon — the pin moved or was renamed; follow it."
        )
    return m.group(1)


def digest() -> str:
    h = hashlib.sha256()
    # Name-then-bytes, with lengths, so neither a rename nor a shift of
    # content across a file boundary can collide with the original.
    h.update(arenajs_pin().encode("utf-8"))
    for rel in SOURCES:
        p = ROVE / rel
        if not p.exists():
            raise SystemExit(
                f"arena_wasm_inputs: {rel} is missing — the arena's module "
                "graph moved; update SOURCES to follow it."
            )
        b = p.read_bytes()
        h.update(f"\0{rel}\0{len(b)}\0".encode("utf-8"))
        h.update(b)
    return h.hexdigest()


def parse_sidecar(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition(" ")
        out[k.strip()] = v.strip()
    return out


def write(out_dir: pathlib.Path, established: str) -> int:
    d = digest()
    body = (
        "# GENERATED — the provenance stamp for qjs_arena_wasm.{js,wasm}.\n"
        "# Written by scripts/ops/build_wasm_arena.sh (rove) and committed\n"
        "# beside the artifact it describes. Do not hand-edit: a stamp that\n"
        "# does not come from the build it claims is worse than no stamp.\n"
        "# Verified by scripts/conformance/adapters.py before the replay\n"
        "# engine runs. See scripts/ops/arena_wasm_inputs.py.\n"
        f"digest {d}\n"
        f"established {established}\n"
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / SIDECAR_NAME).write_text(body, encoding="utf-8")
    print(f"stamped {out_dir / SIDECAR_NAME} ({established}, {d[:16]}…)")
    return 0


def check(apps_dir: pathlib.Path) -> int:
    """Compare the committed stamp to this checkout's sources.

    Returns 0 fresh, 1 stale/unstamped. Prints the reason and the fix on
    stderr, in the shape the conformance adapter surfaces verbatim.
    """
    side = apps_dir / REL_SIDECAR
    want = digest()
    fix = (
        "    fix: zig build wasm-arena   (needs emsdk)\n"
        f"         cp zig-out/wasm-arena/qjs_arena_wasm.{{js,wasm}} {apps_dir}/replay/_static/\n"
        f"         cp zig-out/wasm-arena/{SIDECAR_NAME} {apps_dir}/replay/_static/\n"
        "    then commit the artifact AND its stamp in rewind-apps."
    )
    if not side.exists():
        print(
            f"UNSTAMPED: {side} is missing, so the committed wasm arena's\n"
            "provenance is unknown — it may have been built from any revision\n"
            "of its inputs. The artifact is a compiled copy of the worker's\n"
            "checks, so a wrong one does not fail, it silently answers\n"
            f"differently.\n{fix}",
            file=sys.stderr,
        )
        return 1
    got = parse_sidecar(side.read_text(encoding="utf-8"))
    have = got.get("digest", "")
    if have == want:
        return 0
    caveat = ""
    if got.get("established") == "asserted":
        caveat = (
            "\n  NOTE: the previous stamp was `asserted` — adopted for an\n"
            "  artifact built before stamps existed, on evidence rather than\n"
            "  from a build. It could not rule out that the artifact was\n"
            "  already stale, so this mismatch may predate the stamp."
        )
    print(
        "STALE: the wasm arena was built from different inputs than this\n"
        "checkout has. It is a compiled copy of the engine's own checks, so it\n"
        "now enforces rules the sim and the worker do not (or drops rules they\n"
        "keep), and every replay of an affected record reports as diverged\n"
        "rather than as one legible failure.\n"
        f"  stamped  {have or '(no digest line)'}\n"
        f"  sources  {want}"
        f"{caveat}\n"
        f"{fix}",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--write", metavar="DIR",
                   help="write the stamp into DIR (the build's output dir)")
    g.add_argument("--check", metavar="APPS_DIR",
                   help="compare the stamp committed in APPS_DIR to this checkout")
    ap.add_argument(
        "--established",
        choices=("build", "asserted"),
        default="build",
        help="how the stamp was established; `asserted` only for adopting a "
             "baseline on an artifact built before stamps existed",
    )
    args = ap.parse_args()

    if args.write:
        return write(pathlib.Path(args.write).expanduser(), args.established)
    if args.check:
        return check(pathlib.Path(args.check).expanduser())
    print(digest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
