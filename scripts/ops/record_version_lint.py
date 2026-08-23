#!/usr/bin/env python3
"""Every shim-owned record in the reserved `_` keyspace carries a version.

`docs/architecture/format-versioning.md` §1f classifies each `_`-prefixed
namespace. The ones written by platform JS — the durability markers, the
scheduler queue, the OIDC/RP state, the segment index — carry a `"v"` in
their JSON, checked by every reader.

They cannot share a constant. A baked `__system/*` module runs post-harden
and cannot reach a shim's closure, a package ships in the tenant's
deployment, and a global ships in the prelude; there is no import path
between the three. So the version is declared per file, and this lint is
what keeps the copies honest.

The failure mode it exists for is real and recent: the `_sched/by_id/`
record is written from SIX near-identical `schedArm` copies, two of which
landed the same afternoon someone grepped for them. A seventh copy added
without stamping the record writes rows every reader then rejects — and
the symptom is a scheduled wake that silently never fires, discovered
whenever the customer notices.

Rule per namespace:
  1. every file listed as touching it declares the version constant;
  2. no file OUTSIDE that list writes into the namespace.

(2) is the half that catches the new writer. Adding one means adding the
file here, which is the moment to notice the record needs stamping.

Usage: python3 scripts/ops/record_version_lint.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1].parent

# namespace key prefix → (version constant, files that read or write it)
NAMESPACES = {
    "_sched/by_id/": ("SCHED_REC_V", [
        "src/js/globals/schedule.js",
        "src/js/packages/@rewind/schedule/index.mjs",
        "src/js/packages/@rewind/export/index.mjs",
        "src/js/builtin_modules/scheduler_tick.mjs",
        "src/js/builtin_modules/webhook_fire.mjs",
        "src/js/builtin_modules/webhook_onresult.mjs",
        "src/js/builtin_modules/dispatch_fire.mjs",
        "src/js/builtin_modules/dispatch_result.mjs",
        "src/js/builtin_modules/cron_tick.mjs",
        "src/js/builtin_modules/export_run.mjs",
    ]),
    "_send/owed/": ("SEND_OWED_V", [
        "src/js/globals/webhook.js",
        "src/js/builtin_modules/webhook_fire.mjs",
        "src/js/builtin_modules/webhook_onresult.mjs",
    ]),
    "_blob/owed/": ("BLOB_OWED_V", [
        "src/js/globals/blob.js",
        "src/js/builtin_modules/blob_onresult.mjs",
    ]),
    # `dispatch_result.mjs` is deliberately absent: it resolves by
    # DELETING the marker and never parses it, so it has no version to
    # keep in step. That is a property worth stating — a reader keyed on
    # presence is immune to the record's shape, which is why deleting an
    # absent marker stays a safe no-op.
    "_dispatch/owed/": ("DISPATCH_OWED_V", [
        "src/js/globals/platform.js",
        "src/js/builtin_modules/dispatch_fire.mjs",
    ]),
    "_export/": ("EXPORT_REC_V", [
        "src/js/packages/@rewind/export/index.mjs",
        "src/js/builtin_modules/export_run.mjs",
    ]),
    "_seg/": ("SEG_IDX_V", [
        "src/js/packages/@rewind/segments/index.mjs",
        "src/js/builtin_modules/segments_onsealed.mjs",
    ]),
    # `_oidc/`/`_rp/` are one module's business, and it declares REC_V once
    # for the whole namespace — see the note beside `_rec` there.
    "_oidc/": ("REC_V", ["src/js/packages/@rewind/oidc/index.mjs"]),
    "_rp/": ("REC_V", ["src/js/packages/@rewind/oidc/index.mjs"]),
}

# Where platform JS lives. A writer outside these is not a shim.
SOURCE_GLOBS = [
    "src/js/globals/*.js",
    "src/js/builtin_modules/*.mjs",
    "src/js/packages/@rewind/*/index.mjs",
    "src/js/starter/*.mjs",
]

# `kv.set("_ns/…` / `kvh.set("_ns/…` — a literal write into the namespace.
# Deliberately literal-only: a computed key cannot be attributed to a
# namespace by grep, and a lint that guesses is worse than one that is
# explicit about what it covers.
WRITE = re.compile(r'\bkvh?\.set\(\s*"(_[a-z]+/)')


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", ln) for ln in text.split("\n"))


def main() -> int:
    bad = []
    for prefix, (const, files) in NAMESPACES.items():
        for rel in files:
            p = ROOT / rel
            if not p.exists():
                bad.append(f"{rel}: listed for {prefix} but does not exist "
                           f"(moved? update NAMESPACES)")
                continue
            if not re.search(rf"const {const} = ", p.read_text()):
                bad.append(f"{rel}: touches {prefix} but does not declare "
                           f"`const {const}` — the record needs a version")

    listed = {rel for _, files in NAMESPACES.values() for rel in files}
    for glob in SOURCE_GLOBS:
        for p in sorted(ROOT.glob(glob)):
            rel = str(p.relative_to(ROOT))
            if rel in listed:
                continue
            body = strip_comments(p.read_text())
            for m in WRITE.finditer(body):
                ns = m.group(1)
                for prefix, (const, _files) in NAMESPACES.items():
                    if prefix.startswith(ns) or ns.startswith(prefix.split("/")[0] + "/"):
                        bad.append(
                            f"{rel}: writes {ns} but is not listed for it. "
                            f"Stamp the record with `{const}` and add this "
                            f"file to NAMESPACES in {pathlib.Path(__file__).name}.")
                        break

    if bad:
        print("record-version lint FAILED:\n", file=sys.stderr)
        for b in sorted(set(bad)):
            print(f"  {b}", file=sys.stderr)
        print("\ndocs/architecture/format-versioning.md §1f is the inventory "
              "these versions belong to.", file=sys.stderr)
        return 1
    n = sum(len(f) for _, f in NAMESPACES.values())
    print(f"record-version lint OK — {len(NAMESPACES)} shim-owned namespaces, "
          f"{n} declaring sites.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
