#!/usr/bin/env python3
"""Smoke for V2 unified streaming static serving
(docs/static-asset-serving.md; project_static_stream_serve):

  - EVERY static (HTML/JS/CSS/…) serves inline at its stable FRIENDLY path
    (200, NOT a 302 to /_assets) with ETag + revalidate cache-control — so an
    SPA's relative ES-module imports (`./api.js`) resolve same-origin instead
    of rebasing onto /_assets and 401-ing;
  - an LRU hit serves inline natively; an LRU miss (or LRU disabled) streams
    the blob from file-blobs via the `__system/static` builtin (the
    rove-static.internal door);
  - If-None-Match → 304.

Two clusters: default (LRU on → inline) and REWIND_STATIC_CACHE_MB=0 (LRU off
→ everything streams; the CF-only / stream-everything mode).

Needs S3 creds in the environment (`set -a; . ./.env; set +a`).
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# An SPA whose module graph uses RELATIVE imports — the exact shape that the
# old 302-to-/_assets broke (app.js loaded from /_assets/<hash> would resolve
# `./api.js` to /_assets/api.js → 401).
HTML = ('<!doctype html><html><head>'
        '<link rel=stylesheet href=./app.css>'
        '<script type=module src=./app.js></script></head>'
        '<body><h1>hi</h1></body></html>')
APP_JS = 'import { ping } from "./api.js";\nexport const x = ping();\n'
API_JS = 'export function ping() { return 42; }\n'
CSS = 'body{color:red}'

JS_CT = "text/javascript; charset=utf-8"
STATICS = {
    "_static/index.html": (HTML, "text/html; charset=utf-8"),
    "_static/app.js": (APP_JS, JS_CT),
    "_static/api.js": (API_JS, JS_CT),
    "_static/app.css": (CSS, "text/css"),
}
TRIVIAL = {"index.mjs": "export default function () { return 'ok'; }"}

failures: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} — {detail}")
        failures.append(name)


def deploy_and_wait(c: V2Cluster, tenant: str) -> None:
    r = c.provision(tenant)
    if r.status not in (200, 204):
        sys.exit(f"provision {tenant}: {r.status} {r.body[:200]}")
    c.deploy_with_static(tenant, TRIVIAL, STATICS)
    for _ in range(80):
        if c.get(tenant, "/").status == 200:
            return
        time.sleep(0.25)
    sys.exit(f"{tenant}: deployment never became live")


def assert_friendly(c: V2Cluster, tenant: str, label: str) -> None:
    # The whole graph serves 200 at its friendly path — no 302 anywhere, so a
    # browser's relative imports resolve to these same-origin paths.
    r = c.get(tenant, "/")
    check(f"{label}: GET / → 200 html inline (no redirect)",
          r.status == 200 and r.body == HTML
          and "text/html" in r.headers.get("content-type", ""),
          f"{r.status} ct={r.headers.get('content-type')!r}")

    r = c.get(tenant, "/app.js")
    check(f"{label}: GET /app.js → 200 inline (NOT 302), correct bytes + ct",
          r.status == 200 and r.body == APP_JS
          and "javascript" in r.headers.get("content-type", ""),
          f"{r.status} ct={r.headers.get('content-type')!r} body={r.body[:60]!r}")

    # The relative-import target — the path that the old redirect rebased to a
    # 401. It must serve 200 at its friendly path.
    r = c.get(tenant, "/api.js")
    check(f"{label}: GET /api.js (relative import target) → 200, correct bytes",
          r.status == 200 and r.body == API_JS,
          f"{r.status} body={r.body[:60]!r}")

    r = c.get(tenant, "/app.css")
    check(f"{label}: GET /app.css → 200 inline, correct bytes",
          r.status == 200 and r.body == CSS
          and "text/css" in r.headers.get("content-type", ""),
          f"{r.status} ct={r.headers.get('content-type')!r}")


def main() -> int:
    # ── Cluster A: default (LRU on → inline serve from the prewarmed LRU). ──
    with V2Cluster.spawn("static-v2", nodes=1) as c:
        deploy_and_wait(c, "demo")
        assert_friendly(c, "demo", "lru")

        # ETag present + If-None-Match → 304 (cheap revalidation; CF rides this).
        r = c.get("demo", "/app.js")
        etag = r.headers.get("etag", "")
        check("lru: /app.js carries a strong ETag + revalidate cache-control",
              etag.startswith('"') and "must-revalidate" in r.headers.get("cache-control", ""),
              f"etag={etag!r} cc={r.headers.get('cache-control')!r}")
        if etag:
            r = c.get("demo", "/app.js", headers={"If-None-Match": etag})
            check("lru: /app.js If-None-Match → 304", r.status == 304,
                  f"got {r.status}")

    # ── Cluster B: LRU disabled → everything streams via __system/static. ───
    # Proves the door + builtin + stream relay end-to-end AND the CF-only mode.
    prev = os.environ.get("REWIND_STATIC_CACHE_MB")
    os.environ["REWIND_STATIC_CACHE_MB"] = "0"
    try:
        with V2Cluster.spawn("static-v2-nolru", nodes=1) as c:
            deploy_and_wait(c, "demo")
            assert_friendly(c, "demo", "stream")
    finally:
        if prev is None:
            del os.environ["REWIND_STATIC_CACHE_MB"]
        else:
            os.environ["REWIND_STATIC_CACHE_MB"] = prev

    if failures:
        print(f"\nstatic_smoke_v2: FAILED ({len(failures)}): {failures}")
        return 1
    print("\nstatic_smoke_v2: PASS — unified friendly-path serve "
          "(LRU inline + __system/static stream); relative imports resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
