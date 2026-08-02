#!/usr/bin/env python3
"""Tenant-prefix lint: per-tenant S3 paths must come from `TenantStorage`,
never from a format string at a call site.

The rot this catches (docs/defect-patterns.md class 2): a per-tenant storage
path is derived from `(id, incarnation)` in exactly one place —
`src/tenant/storage.zig`'s `TenantStorage` (`keyPrefix` / `s3ObjectPath` /
`openBackend`). Before that handle existed, seven call sites re-derived the
prefix by hand with `allocPrint(cfg.key_prefix_base, tenant, ...)`; when the
derivation rule gained the incarnation segment (#357), each hand-rolled copy
kept the old rule and silently addressed the previous tenant lifetime's
objects. Both sides stayed internally consistent, so nothing errored.

Two tripwires, both on `allocPrint`/`bufPrint`-family calls only (log lines
and doc comments naming the layout are fine):

  1. a format string containing a per-tenant subdir (`app-blobs/`,
     `file-blobs/`, `deployments/`, `log-blobs/`) — building a tenant object
     path by hand;
  2. `key_prefix_base` used as a format argument — building any keyspace path
     by hand.

Allow-listed files are the ones that legitimately own a derivation:
`src/tenant/storage.zig` (the constructor), `src/blob/` (config home +
cluster-scoped `_namespace`/`_pool` keys), and the three cluster-scoped
key builders (`_pool`, `_certs`, the offline namespace tool). Adding a new
file to the allow-list is a design decision — the intended fix for a new hit
is `TenantStorage.s3ObjectPath`/`keyPrefix`, or a new method on the handle.

Exit 0 = clean, 1 = hand-built prefix found.

Sibling to `test_reachability_lint.py`; run standalone (there is no general
CI workflow yet — only `release-rewind.yml`).
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

ALLOW = (
    "src/tenant/storage.zig",  # THE constructor
    "src/blob/",  # BackendConfig home; cluster-scoped _namespace/_pool keys
    "src/js/blob_coordination.zig",  # {base}_pool/ (cross-tenant pool, node-wide)
    "src/cp/cert_mirror.zig",  # {base}_certs/ (cluster-scoped)
    "src/cli/storage_namespace.zig",  # offline namespace tool (node scope)
)

SUBDIR_RE = re.compile(r'"[^"]*(?:app-blobs|file-blobs|deployments|log-blobs)/[^"]*"')
PRINT_RE = re.compile(r"\b(?:allocPrint|allocPrintZ|bufPrint|bufPrintZ)\b")
PREFIX_RE = re.compile(r"\bkey_prefix_base\b")


def strip_comments(line: str) -> str:
    # Good enough for lint purposes: Zig has no /* */ comments.
    return line.split("//", 1)[0]


def main() -> int:
    hits: list[str] = []
    for path in sorted((ROOT / "src").rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        if any(rel.startswith(a) for a in ALLOW):
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, raw in enumerate(lines, 1):
            line = strip_comments(raw)
            if not PRINT_RE.search(line):
                # A *Print call may span lines; look back a few lines for the
                # call these format args belong to (lines[i-1] is this line).
                ctx = " ".join(strip_comments(l) for l in lines[max(0, i - 5) : i - 1])
                if not PRINT_RE.search(ctx):
                    continue
            if SUBDIR_RE.search(line):
                hits.append(f"{rel}:{i}: hand-built per-tenant object path: {raw.strip()}")
            elif PREFIX_RE.search(line):
                hits.append(f"{rel}:{i}: key_prefix_base in a format call: {raw.strip()}")
    if not hits:
        print(
            "tenant-prefix lint OK — every per-tenant path derives from "
            "TenantStorage."
        )
        return 0
    print(
        "tenant-prefix lint FAILED — per-tenant paths built by hand "
        "(use TenantStorage.s3ObjectPath/keyPrefix/openBackend; "
        "docs/defect-patterns.md class 2):\n",
        file=sys.stderr,
    )
    for h in hits:
        print(f"  {h}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
