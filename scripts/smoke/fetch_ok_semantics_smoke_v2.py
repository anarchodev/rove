#!/usr/bin/env python3
"""`request.status` is the single fetch-result signal — no `request.ok`
(handler-shape.md §7).

Regression guard for the fetch/callback result surface: the handler must
derive success from `request.status` (`200 ≤ status < 300`), and there must be
NO `request.ok` field (it was removed — redundant with status, drifted into
three definitions). An upstream 500 or a 3xx is not success; a hard transport
failure surfaces as `status === 0`.

Two tenants on a single node:
  - `up` serves `/ok` (200), `/err` (500), `/redir` (302) — a controllable
    upstream returning an exact status.
  - `cli` `/probe?url=` does a buffered `after.fetch(url)` holding the client
    until `onFetchResult`, which echoes `{status, ok2xx, hasOk}` as JSON
    (`hasOk` proves `request.ok` is absent).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

# Upstream: return an exact status per path. `response.status = N; return body`.
UP_ROOT = 'export function handler() { return "up-ready"; }\n'
UP_OK = 'export default function () { response.status = 200; return "OK"; }\n'
UP_ERR = 'export default function () { response.status = 500; return "boom"; }\n'
UP_REDIR = ('export default function () { response.status = 302; '
            'response.headers = { location: "/ok" }; return ""; }\n')

# Client: buffered on.fetch, echo the flattened result surface.
CLI_ROOT = 'export function handler() { return "cli-ready"; }\n'
PROBE_SRC = r"""export default function () {
    const url = new URLSearchParams(request.query || "").get("url");
    after.fetch(url);
    return next();
}

export function onFetchResult() {
    response.status = 200;
    const s = request.status;
    return JSON.stringify({
        status: s,
        ok2xx: s >= 200 && s < 300,          // the handler-derived success
        hasOk: ("ok" in request),            // must be false — request.ok is gone
    });
}
"""

UP_HANDLERS = {
    "index.mjs": rpc_wrap(UP_ROOT),
    "ok/index.mjs": UP_OK,
    "err/index.mjs": UP_ERR,
    "redir/index.mjs": UP_REDIR,
}
CLI_HANDLERS = {
    "index.mjs": rpc_wrap(CLI_ROOT),
    "probe/index.mjs": PROBE_SRC,
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("fetchok", nodes=1) as c:
        print("step 1: provision + deploy up (upstream) and cli (probe)")
        for t in ("up", "cli"):
            r = c.provision(t)
            check(f"provision {t} → 200", r.status == 200, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("up", UP_HANDLERS)
            c.deploy_handlers("cli", CLI_HANDLERS)
            check("deploy up + cli", True)
        except RuntimeError as e:
            check("deploy up + cli", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        # Upstream reachable + returns the exact statuses.
        r = c.wait_for_handler("up", "/ok", want_status=200, timeout_s=25.0)
        check("up/ok → 200", r.status == 200, f"got {r.status}")
        r = c.wait_for_handler("up", "/err", want_status=500, timeout_s=25.0)
        check("up/err → 500", r.status == 500, f"got {r.status}")
        r = c.wait_for_handler("cli", "/?fn=handler", want_status=200,
                               want_body="cli-ready", timeout_s=25.0)
        check("cli reachable", r.status == 200, f"got {r.status}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        def probe(path):
            url = f"http://up.{PUBLIC_SUFFIX}:{c.front_port}{path}"
            r = c.get("cli", f"/probe?url={up.quote(url)}", timeout=30.0)
            if r.status != 200:
                return None, f"probe transport status={r.status} body={r.body!r}"
            try:
                return json.loads(r.body), ""
            except Exception as e:  # noqa: BLE001
                return None, f"bad json {r.body!r}: {e}"

        # 2xx → status 200, handler-derived success, and NO request.ok field.
        res, err = probe("/ok")
        check("fetch 200 → status:200 ok2xx:true, request.ok absent",
              res == {"status": 200, "ok2xx": True, "hasOk": False},
              err or f"got {res}")

        # 500 → not 2xx (was ok:true under the old transport-only semantics).
        res, err = probe("/err")
        check("fetch 500 → status:500 ok2xx:false, request.ok absent",
              res == {"status": 500, "ok2xx": False, "hasOk": False},
              err or f"got {res}")

        # 3xx → not 2xx (a redirect is not success).
        res, err = probe("/redir")
        check("fetch 302 → status:302 ok2xx:false, request.ok absent",
              res == {"status": 302, "ok2xx": False, "hasOk": False},
              err or f"got {res}")

        if failures:
            c.dump_node_log(grep=["probe", "fetch", "result", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS fetch ok-semantics smoke (v2): request.status is the single "
          "result signal; no request.ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
