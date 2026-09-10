#!/usr/bin/env python3
"""Ship the engine's baked `__system/*` handler modules to the replay shell.

A `send_callback` activation — every durable `webhook.send` / `email.send`
result hop, every scheduler or cron tick — runs a module that lives in the
WORKER BINARY, not in any tenant's deployment (src/js/builtin_modules.zig).
The replay bundle is composed from a tenant's deployed sources, so it can
never carry them, and those records were unreplayable (rove#236).

They are engine-owned and identical for every tenant, so they ship with the
shell, generated from the same sources the worker embeds — the
`arena-prelude.js` precedent (rove#227). The alternative, a per-bundle
fetch, buys nothing: there is no per-tenant variation to fetch.

Keyed by the path the module resolver registers (`__system/<name>.mjs`),
which is the specifier the capture's module tape recorded, so the shell can
drop them straight into its module-source map.

**Staleness is the real risk**, in two separate directions.

*Against the checkout.* The generated file lives in another repo and does not
update itself, so a module edited here leaves the arena running the older
copy — silently, because the arena is a different engine and nobody is
comparing. `--verify` is the gate for that half: it hashes the sources this
generator reads and compares them to the digest recorded beside it, so
editing a baked module turns the gate red at the moment of the change rather
than surfacing later as a conformance divergence indistinguishable from a
real behaviour difference. The `arena-prelude.js` gate works the same way and
for the same reason (rove#865). `--check` is the other half, used where the
apps checkout IS available: it compares the committed file byte-for-byte.

It is not hypothetical. The mirror sat stale on `main` through the received-
capabilities cutover: it was missing `admin_kv_install.mjs` entirely and
still carried pre-cutover module signatures (`function ()` reading
`__rove.rootKv*` where the worker had moved to `function ({ __system })` and
`__system.rootKv`). Two generators mirror into the arena; only one was gated.

*Against the capture.* A capture ran against whatever builds these the
deployed worker had; this ships whatever the checkout has. The module tape
carries a hash only for modules in the tenant's deployment
(`module_execution.zig` records an entry only when `source_hashes` has the
name), and a builtin is not one of them — so a replay after these sources
change re-runs the NEW builtin against an OLD capture. Publishing regenerates
this file, which keeps prod and the shell in step; the durable fix for that
half is a hash on the tape.

Usage:
  python3 scripts/ops/gen_replay_system_modules.py --apps-dir ~/src/rewind-apps
  python3 scripts/ops/gen_replay_system_modules.py --record   # with the above
  python3 scripts/ops/gen_replay_system_modules.py --verify   # the gate

Writes <apps-dir>/replay/_static/arena-system-modules.js. Deterministic
output. Invoked by the replay tenant's manifest `generate` hook.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]
BUILTINS = ROVE / "src" / "js" / "builtin_modules"
DIGEST_FILE = ROVE / "scripts" / "ops" / "arena-system-modules.sha256"

BANNER = """\
// GENERATED — do not edit. scripts/ops/gen_replay_system_modules.py (rove)
// ships the engine's baked `__system/*` handler modules, which live in the
// worker binary and therefore appear in no tenant's replay bundle.
//
// The shell merges these into its module-source map, so a send_callback
// record (a durable webhook/email result hop, a scheduler or cron tick)
// can compile the module that actually ran.
"""


def build() -> str:
    mods = {}
    for path in sorted(BUILTINS.glob("*.mjs")):
        mods[f"__system/{path.name}"] = path.read_text(encoding="utf-8")
    body = json.dumps(mods, indent=2, sort_keys=True, ensure_ascii=False)
    return f"{BANNER}\nexport const SYSTEM_MODULES = {body};\n"


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


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
        help="fail (exit 1) if the baked module sources no longer match the "
             "recorded digest; needs no apps checkout, so the gate can run "
             "anywhere",
    )
    ap.add_argument(
        "--record",
        action="store_true",
        help="rewrite the recorded digest; run this WITH regenerating the "
             "mirror in rewind-apps, never instead of it",
    )
    args = ap.parse_args()

    text = build()

    if args.verify:
        want = DIGEST_FILE.read_text(encoding="utf-8").split()[0] if DIGEST_FILE.exists() else ""
        have = digest(text)
        if want != have:
            print(
                f"STALE: the baked `__system/*` module sources changed.\n"
                f"  recorded {want or '(none)'}\n"
                f"  current  {have}\n"
                f"\n"
                f"`replay/_static/arena-system-modules.js` in rewind-apps is\n"
                f"GENERATED from src/js/builtin_modules/. It does not update itself,\n"
                f"and nothing downstream notices — the browser replay engine just\n"
                f"runs older baked modules than the worker, and the conformance\n"
                f"corpus reports that as a divergence indistinguishable from a real\n"
                f"behaviour difference. Propagate the change:\n"
                f"\n"
                f"  python3 scripts/ops/gen_replay_system_modules.py --apps-dir <rewind-apps>\n"
                f"  python3 scripts/ops/gen_replay_system_modules.py --record\n"
                f"\n"
                f"then commit the regenerated mirror in rewind-apps AND the digest\n"
                f"here. Recording without regenerating defeats the check.",
                file=sys.stderr,
            )
            return 1
        print(f"fresh: baked module sources match the recorded digest ({have[:16]}…)")
        return 0

    if args.record:
        DIGEST_FILE.write_text(digest(text) + "  arena-system-modules.js\n", encoding="utf-8")
        print(f"recorded {digest(text)} → {DIGEST_FILE}")
        return 0

    if not args.apps_dir:
        print("--apps-dir is required to write or --check", file=sys.stderr)
        return 2

    out = (pathlib.Path(args.apps_dir).expanduser()
           / "replay" / "_static" / "arena-system-modules.js")
    if args.check:
        if not out.exists() or out.read_text(encoding="utf-8") != text:
            print(f"STALE: {out} does not match src/js/builtin_modules/ — "
                  "rerun scripts/ops/gen_replay_system_modules.py", file=sys.stderr)
            return 1
        print(f"fresh: {out}")
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    n = len(list(BUILTINS.glob("*.mjs")))
    print(f"wrote {out} ({n} modules, {len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
