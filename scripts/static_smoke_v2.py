#!/usr/bin/env python3
"""Smoke for V2 non-blocking, immutable static serving
(docs/static-asset-serving.md):

  - HTML documents serve inline same-origin (200, NOT a redirect), so an
    SPA's relative asset paths keep working;
  - non-HTML statics 302 to the immutable, content-addressed same-origin
    URL `/_assets/{hash}`;
  - `/_assets/{hash}` serves from the in-memory LRU with immutable
    caching, honors If-None-Match (304), and 404s an unknown hash.

Needs S3 creds in the environment (`set -a; . ./.env; set +a`).
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

HTML = ("<!doctype html><html><head>"
        "<link rel=stylesheet href=./app.css></head>"
        "<body><h1>hi</h1></body></html>")
CSS = "body{color:red}"


def main() -> int:
    with V2Cluster.spawn("static-v2", nodes=1) as c:
        r = c.provision("demo")
        if r.status not in (200, 204):
            sys.exit(f"provision demo: {r.status} {r.body[:200]}")
        # deploy_with_static carries explicit content-types (the inline
        # path keys off text/html). The trivial handler just satisfies the
        # compile step; GET / serves the static index.html, which wins.
        c.deploy_with_static(
            "demo",
            {"index.mjs": "export default function () { return 'ok'; }"},
            {
                "_static/index.html": (HTML, "text/html; charset=utf-8"),
                "_static/app.css": (CSS, "text/css"),
            },
        )
        # Wait for the deployment (and its prewarm) to load.
        for _ in range(80):
            if c.get("demo", "/").status == 200:
                break
            time.sleep(0.25)

        # 1. HTML doc inline (200, same-origin) — not a redirect.
        r = c.get("demo", "/")
        assert r.status == 200, f"GET / status {r.status}: {r.body[:200]}"
        assert "text/html" in r.headers.get("content-type", ""), r.headers
        assert r.body == HTML, f"GET / body mismatch: {r.body[:120]!r}"
        assert "must-revalidate" in r.headers.get("cache-control", ""), r.headers
        print("ok  HTML served inline 200 (no redirect), revalidate cache-control")

        # 2. non-HTML → 302 to /_assets/{hash}.
        r = c.get("demo", "/app.css")
        assert r.status == 302, f"GET /app.css status {r.status}: {r.body[:120]}"
        loc = r.headers.get("location", "")
        m = re.match(r"^/_assets/([0-9a-f]{64})$", loc)
        assert m, f"bad asset Location: {loc!r}"
        h = m.group(1)
        print(f"ok  /app.css → 302 /_assets/{h[:12]}…")

        # 3. /_assets/{hash} → 200 immutable from the LRU, correct bytes.
        r = c.get("demo", f"/_assets/{h}")
        assert r.status == 200, f"/_assets status {r.status}: {r.body[:120]}"
        assert "text/css" in r.headers.get("content-type", ""), r.headers
        assert r.body == CSS, f"asset body mismatch: {r.body!r}"
        assert "immutable" in r.headers.get("cache-control", ""), r.headers
        print("ok  /_assets/{hash} → 200 immutable from LRU, correct bytes")

        # 4. If-None-Match → 304.
        r = c.get("demo", f"/_assets/{h}", headers={"If-None-Match": f'"{h}"'})
        assert r.status == 304, f"revalidation status {r.status}: {r.body[:120]}"
        print("ok  /_assets/{hash} If-None-Match → 304")

        # 5. well-formed but unknown hash → 404 (not in this deployment).
        r = c.get("demo", "/_assets/" + ("0" * 64))
        assert r.status == 404, f"unknown hash status {r.status}: {r.body[:120]}"
        print("ok  /_assets/{unknown} → 404")

    print("\nstatic_smoke_v2: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
