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

**Staleness is the real risk.** A capture ran against whatever builds these
the deployed worker had; this ships whatever the checkout has. Nothing
detects a mismatch today — the module tape only carries a hash for modules
in the tenant's deployment (module_execution.zig records an entry only when
`source_hashes` has the name), and a builtin is not one of them. So a
replay after these sources change silently re-runs the NEW builtin against
an OLD capture. Publishing regenerates this file, which keeps prod and the
shell in step; the durable fix is a hash on the tape.

Usage:
  python3 scripts/ops/gen_replay_system_modules.py --apps-dir ~/src/rewind-apps

Writes <apps-dir>/replay/_static/arena-system-modules.js. Deterministic
output. Invoked by the replay tenant's manifest `generate` hook.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROVE = pathlib.Path(__file__).resolve().parents[2]
BUILTINS = ROVE / "src" / "js" / "builtin_modules"

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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps-dir", required=True, help="rewind-apps checkout")
    ap.add_argument(
        "--check",
        action="store_true",
        help="fail (exit 1) if the committed output is stale instead of writing",
    )
    args = ap.parse_args()

    out = (pathlib.Path(args.apps_dir).expanduser()
           / "replay" / "_static" / "arena-system-modules.js")
    text = build()
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
