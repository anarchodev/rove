#!/usr/bin/env python3
"""Generate the browser replay arena's base prelude from the engine shims.

One source: the prelude is a concatenation of engine-owned JS the worker
and the CLI sim already use — never a hand-copied second list, so the
browser arena cannot drift shim-wise (rove#227's failure mode):

  src/replay/js/textcodec_pure.js    pure-JS TextEncoder/TextDecoder (the
                                     same file the sim/replay epilogue
                                     splices; prod-byte-exact UTF-8)
  src/replay/js/system_recorders.js  the `_system.*` primitive layer,
                                     shared verbatim with the CLI sim
  src/js/globals/*.js                the public shims, in the worker's
                                     own eval order (see PIECES)

The arena gets the same two layers the CLI sim gets: the `_system.*`
primitive layer (`src/replay/js/system_recorders.js`, shared verbatim with
sim_globals.zig) and the public `globals/*.js` shims composed over it. The
effect verbs are RECORDERS — replay re-executes recorded inputs, so an
effect that already happened live is observed, never fired.

Excluded on purpose: `request.js` (the shell's epilogue owns the request
surface in the browser), `console.js` (live console output is already on
the LogRecord, so replay's console is a no-op sink), `textcodec.js` (it
needs the worker's native binding — the pure codec above stands in), and
`kv` (native, from the replay bindings).

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
import hashlib
import json
import pathlib
import re
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]

# (path, iife) — order matters and mirrors the sim base prelude
# (src/replay/sim_globals.zig PRELUDE), which in turn mirrors the worker's
# eval order (src/js/globals.zig installStatic). `iife=False` files are
# embedded bare because they are already self-wrapped upstream; wrap here
# only for a source with bare top-level bindings.
PIECES = [
    # The pure codec first (base64/urlsearchparams construct
    # TextEncoder/TextDecoder at call time, but keep the dependency above
    # its dependents). Browser-only: the worker has a native textcodec
    # binding, this arena does not.
    (ROVE / "src" / "replay" / "js" / "textcodec_pure.js", False),
    # The interaction digest's JS mirror — the replay recomputes the digest the
    # worker recorded and compares it, which is what turns "it replayed" into
    # "it replayed the same thing". Shared verbatim with the Zig implementation
    # and pinned by `zig build replay-digest-vectors`, so the two cannot drift.
    (ROVE / "src" / "tape" / "js_interaction_digest.js", False),
    # The `_system.*` primitive layer the public shims compose over —
    # recorders for the effect verbs, real crypto over the native
    # bindings. Shared verbatim with the CLI sim (sim_globals.zig embeds
    # the same file), so the two offline runtimes cannot drift.
    (ROVE / "src" / "replay" / "js" / "system_recorders.js", False),
    # The public shims, in the worker's own eval order (globals.zig
    # installStatic): each composes on `_system.*` and on the globals the
    # earlier ones install. `crypto.js` captures `_system.crypto` at eval,
    # so it must land after the recorders and before the delete below.
    (ROVE / "src" / "js" / "globals" / "crypto.js", False),
    (ROVE / "src" / "js" / "globals" / "http.js", False),
    (ROVE / "src" / "js" / "globals" / "base64.js", False),
    (ROVE / "src" / "js" / "globals" / "urlsearchparams.js", False),
    (ROVE / "src" / "js" / "globals" / "platform.js", False),
    # The connection/continuation trio — faithful recorders that do not
    # decompose.
    (ROVE / "src" / "js" / "globals" / "after.js", False),
    (ROVE / "src" / "js" / "globals" / "stream.js", False),
    (ROVE / "src" / "js" / "globals" / "next.js", False),
    # The durable verbs: `time` (shared coercion) -> `schedule` (installs
    # the private `_system.sched`) -> `webhook` (captures `_system.http`
    # and `_system.sched` at eval). `webhook.js` carries top-level `const`
    # bindings, so it is IIFE-wrapped here to keep those lexicals out of
    # the base snapshot's global lexical scope — a bare top-level binding
    # corrupts the freeze (globals-shim-iife-required).
    (ROVE / "src" / "js" / "globals" / "time.js", False),
    (ROVE / "src" / "js" / "globals" / "schedule.js", False),
    (ROVE / "src" / "js" / "globals" / "webhook.js", True),
    # `blob` composes on the base `after.fetch`, so it lands after it.
    (ROVE / "src" / "js" / "globals" / "blob.js", False),
]

# Evaled last: `_system` is the shims' private construction material, not
# customer surface. Every shim above captured what it needs in a closure.
EPILOGUE = "\n;delete globalThis._system;\n"

# The handler-facing RULES are not in this prelude any more: the arena's
# wasm links rove's compiled binding (the in-tree build, `zig build
# wasm-arena`), so the checks run in-module — identical bytes to the worker
# and the sim — and there is no JS rendering of them left to splice.
# where they bite is each engine's own business.




# Digest of the composed prelude, committed HERE in rove.
#
# The freshness problem is cross-repo: the artifact lives in rewind-apps,
# so a rove-side check would need that checkout to compare against — and
# a gate that depends on a sibling clone either does not run or is not a
# gate. But `build()` composes the expected text from rove sources
# ALONE. Recording its digest here makes the contract checkable without
# leaving the repo: change a shim, and the digest moves, and the gate
# says so at the moment of the change rather than whenever someone next
# happens to regenerate.
#
# The two halves catch different drift and both are needed:
#   - this digest      — a rove shim moved and rewind-apps has not been
#                        told. Runs on every `zig build test`.
#   - `--check`        — the committed prelude does not match the rove
#                        commit rewind-apps pins. Runs in that repo's CI.
DIGEST_FILE = ROVE / "scripts" / "ops" / "arena-prelude.sha256"


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()

BANNER = """\
// GENERATED — do not edit. scripts/ops/gen_replay_prelude.py (rove)
// composes this from the engine's own shim sources; regenerated at
// publish time by the replay tenant's manifest `generate` hook.
//
// Evaled once into the WASM arena's open base (arena_eval_base), before
// freeze, before any run, outside every drill trace — so a replayed
// handler sees the same pure compute globals a live handler does.
"""


def capability_names() -> list[str]:
    """The capability list, read from its Zig authority.

    `rove-reserved`'s `CAPABILITY_NAMES` is what the worker and the offline
    replay driver each build their activation object from. The browser
    arena's driver lives in another repo, so without this it would need a
    hand-copied fourth list — and a list that drifts silently is how one
    engine ends up able to pass a capability the others cannot. Emitting it
    into the prelude puts the arena on the same authority, and the existing
    staleness gates (`--verify` here, `--check` consumer-side) then cover
    it for free.
    """
    src = (ROVE / "src" / "reserved" / "root.zig").read_text(encoding="utf-8")
    m = re.search(r"CAPABILITY_NAMES\s*=\s*\[_\]\[\]const u8\{(.*?)\}", src, re.S)
    if not m:
        raise SystemExit(
            "gen_replay_prelude: CAPABILITY_NAMES not found in "
            "src/reserved/root.zig — the list moved; follow it."
        )
    names = re.findall(r'"([^"]+)"', m.group(1))
    if not names:
        raise SystemExit("gen_replay_prelude: CAPABILITY_NAMES is empty")
    return names


def caps_block() -> str:
    names = ", ".join(json.dumps(n) for n in capability_names())
    return (
        "\n// ── the capability names (rove-reserved CAPABILITY_NAMES) ──\n"
        ";// The activation object's members — see\n"
        ";// docs/architecture/package-isolation.md. Generated from the same\n"
        ";// Zig constant the worker and the native replay driver build from,\n"
        ";// so the browser arena cannot drift from either.\n"
        f"globalThis.__CAPS = [{names}];\n"
    )


def build() -> str:
    parts = [BANNER]
    for path, iife in PIECES:
        src = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROVE)
        parts.append(f"\n// ── {rel} ──\n;")
        parts.append(f"(function () {{\n{src}\n}})();" if iife else src)
    parts.append(caps_block())
    parts.append(EPILOGUE)
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", help="rewind-apps checkout (required to write or --check)")
    ap.add_argument(
        "--check",
        action="store_true",
        help="fail (exit 1) if the committed output is stale instead of writing",
    )
    ap.add_argument(
        "--verify",
        action="store_true",
        help="fail (exit 1) if the shim sources no longer match the recorded "
             "digest — the rove-side gate; needs no apps checkout",
    )
    ap.add_argument(
        "--record",
        action="store_true",
        help="rewrite the recorded digest; run this WITH regenerating the "
             "prelude in rewind-apps, never instead of it",
    )
    args = ap.parse_args()

    text = build()

    if args.verify:
        want = DIGEST_FILE.read_text(encoding="utf-8").split()[0] if DIGEST_FILE.exists() else ""
        have = digest(text)
        if want != have:
            print(
                f"STALE: the replay prelude's engine shim sources changed.\n"
                f"  recorded {want or '(none)'}\n"
                f"  current  {have}\n"
                f"\n"
                f"`replay/_static/arena-prelude.js` in rewind-apps is GENERATED from\n"
                f"these sources. It does not update itself, and nothing downstream\n"
                f"notices — the browser replay engine just runs older shim code than\n"
                f"the worker, silently. Propagate the change:\n"
                f"\n"
                f"  python3 scripts/ops/gen_replay_prelude.py --apps-dir <rewind-apps>\n"
                f"  python3 scripts/ops/gen_replay_prelude.py --record\n"
                f"\n"
                f"then commit the regenerated prelude in rewind-apps AND the digest\n"
                f"here. Recording without regenerating defeats the check.",
                file=sys.stderr,
            )
            return 1
        print(f"fresh: shim sources match the recorded digest ({have[:16]}…)")
        return 0

    if args.record:
        DIGEST_FILE.write_text(digest(text) + "  arena-prelude.js\n", encoding="utf-8")
        print(f"recorded {digest(text)} → {DIGEST_FILE}")
        return 0

    if not args.apps_dir:
        print("--apps-dir is required to write or --check", file=sys.stderr)
        return 2
    out = pathlib.Path(args.apps_dir).expanduser() / "replay" / "_static" / "arena-prelude.js"
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
