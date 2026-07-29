#!/usr/bin/env python3
"""Generate the browser replay arena's base prelude from the engine shims.

One source: the prelude is a concatenation of engine-owned JS the worker
and the CLI sim already use — never a hand-copied second list, so the
browser arena cannot drift shim-wise (rove#227's failure mode):

  src/replay/js/textcodec_pure.js   pure-JS TextEncoder/TextDecoder (the
                                    same file the sim/replay epilogue
                                    splices; prod-byte-exact UTF-8)
  src/js/globals/base64.js          atob/btoa + base64url + hex
  src/js/globals/urlsearchparams.js URLSearchParams
  src/js/globals/time.js            time coercion helpers

Only the PURE compute shims belong here: the effect surfaces (kv, http,
request, ...) are tape-driven in the replay arena and installed per-run by
the shell's epilogue (rewind-apps request-replay.mjs). The shims that
bottom out on `_system.*` natives (crypto.js, textcodec.js, ...) are
excluded — the arena has no worker natives; textcodec is covered by the
pure codec above, and `globalThis.crypto` comes native from arenajs's
replay bindings.

The shell evals the output into the arena BASE (arena_init_open ->
arena_eval_base -> arena_freeze), before any run and outside every drill
trace, mirroring how the CLI sim evals its prelude via
arena_reactor_eval_base.

Usage:
  python3 scripts/ops/gen_replay_prelude.py --apps-dir ~/src/rewind-apps

Writes <apps-dir>/replay/_static/arena-prelude.js. Deterministic output.
Invoked automatically by publish_firstparty.py via the replay tenant's
manifest `generate` hook.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]

# (path, iife) — order matters: the codec first (base64/urlsearchparams
# construct TextEncoder/TextDecoder at call time, but keep the dependency
# above its dependents anyway), then the compute shims in the worker's
# eval order (src/js/globals.zig installStatic). `iife=False` files are
# embedded bare, exactly as the sim base prelude embeds them
# (src/replay/sim_globals.zig PRELUDE); wrapping is upstream in the
# already-IIFE'd sources.
PIECES = [
    (ROVE / "src" / "replay" / "js" / "textcodec_pure.js", False),
    (ROVE / "src" / "js" / "globals" / "base64.js", False),
    (ROVE / "src" / "js" / "globals" / "urlsearchparams.js", False),
    (ROVE / "src" / "js" / "globals" / "time.js", False),
]

BANNER = """\
// GENERATED — do not edit. scripts/ops/gen_replay_prelude.py (rove)
// composes this from the engine's own shim sources; regenerated at
// publish time by the replay tenant's manifest `generate` hook.
//
// Evaled once into the WASM arena's open base (arena_eval_base), before
// freeze, before any run, outside every drill trace — so a replayed
// handler sees the same pure compute globals a live handler does.
"""


def build() -> str:
    parts = [BANNER]
    for path, iife in PIECES:
        src = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROVE)
        parts.append(f"\n// ── {rel} ──\n;")
        parts.append(f"(function () {{\n{src}\n}})();" if iife else src)
    parts.append("\n")
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", required=True, help="rewind-apps checkout")
    ap.add_argument(
        "--check",
        action="store_true",
        help="fail (exit 1) if the committed output is stale instead of writing",
    )
    args = ap.parse_args()

    out = pathlib.Path(args.apps_dir).expanduser() / "replay" / "_static" / "arena-prelude.js"
    text = build()
    if args.check:
        if not out.exists() or out.read_text(encoding="utf-8") != text:
            print(f"STALE: {out} does not match the engine shim sources — "
                  "rerun scripts/ops/gen_replay_prelude.py", file=sys.stderr)
            return 1
        print(f"fresh: {out}")
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
