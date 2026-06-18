#!/usr/bin/env python3
"""Replay-context + user-tag end-to-end smoke (decisions.md §4.10).

Proves the full `browser.getReplay` substrate without the WebSocket agent —
just the engine machinery it rides on:

  1. `request.tag("session","S1")` in a normal inbound handler is captured into
     the request's log record (the SuccessRec terminal path), flushed to S3,
     and indexed into `log_tags`.
  2. The SELF-TENANT logs door (decisions.md §4.10, Option A): a NON-admin
     tenant fetching `http://rewind-logs.internal/v1/{ITS-OWN-id}/session/S1`
     is allowed (the engine pins the minted token to the caller's own tenant)
     and gets back exactly its session-S1 activations — the `/session/{id}`
     route is sugar for `tag.session`.
  3. Cross-tenant is still refused: the same tenant naming ANOTHER tenant in
     the URL is rejected at the door (LogsDoorForbidden → outcome.ok == false).

Needs the full topology + S3 (worker mints, log-server verifies). Run:
    zig build rewind-worker rewind-cp rewind-front rewind-logs
    set -a; . ./.env; set +a
    python3 scripts/replay_tags_smoke_v2.py

Ports: http_base 19700 (PID-nudged). Companion to logs_door_smoke_v2.py
(admin cross-tenant door) and log_tenant_scope_smoke_v2.py (log-server gate).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# A handler that tags its own request, plus self-tenant + cross-tenant replay
# probes. Routing is by module dir: /tag → tag/index.mjs, etc.
TAG_SRC = r"""export default function () {
    request.tag("session", "S1");
    request.tag("flow", "smoke");
    return "tagged";
}
"""

# Self-tenant replay: fetch THIS tenant's own session-S1 activations. The door
# pins the token to request.tenant; the URL names the same id, so it's allowed.
REPLAY_SELF_SRC = r"""export default function () {
    on.fetch("http://rewind-logs.internal/v1/" + request.tenant +
             "/session/S1?limit=20");
    return next();
}
export function onFetchResult() {
    if (request.ok) {
        response.status = 200;
        return "ok:" + request.status + ":" +
            new TextDecoder().decode(request.body || new Uint8Array());
    }
    response.status = 502;
    return "fail:" + (request.error || request.reason || request.status || "?");
}
"""

# Cross-tenant replay: name a DIFFERENT tenant — must be refused at the door.
REPLAY_OTHER_SRC = r"""export default function () {
    on.fetch("http://rewind-logs.internal/v1/__admin__/session/S1?limit=20");
    return next();
}
export function onFetchResult() {
    if (request.ok) { response.status = 200; return "ok:" + request.status; }
    response.status = 502;
    return "fail:" + (request.error || request.reason || request.status || "?");
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'

FIXTURE = {
    "index.mjs": rpc_wrap(READY_SRC),
    "tag/index.mjs": TAG_SRC,
    "replay/index.mjs": REPLAY_SELF_SRC,
    "xreplay/index.mjs": REPLAY_OTHER_SRC,
}


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== replay-context + user tags (self-tenant door) ===")
    with V2Cluster.spawn("replaytags", nodes=1, http_base=19700,
                         raft_base=19800) as c:
        c.spawn_log_server()
        c._ensure_admin_app()

        r = c.provision("acme")
        check("provision acme → 204/409", r.status in (204, 409),
              f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", FIXTURE)
        except RuntimeError as e:
            check("deploy acme", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        c.wait_for_handler("acme", "/?fn=handler", want_body="ready", timeout_s=30.0)

        # 1. Produce a few tagged records.
        for _ in range(3):
            r = c.request("acme", "/tag", timeout=30.0)
            check("hit /tag → tagged", r.status == 200 and r.body == "tagged",
                  f"got {r.status} {r.body!r}")

        # 2. Self-tenant replay: poll until the flush+index makes the tagged
        #    records visible through the door (logs flush on an interval, then
        #    push to the log-server; allow generous time).
        deadline = time.time() + 45.0
        body = ""
        status = 0
        while time.time() < deadline:
            r = c.request("acme", "/replay", timeout=30.0)
            status, body = r.status, r.body
            if status == 200 and '"path":"/tag"' in body:
                break
            time.sleep(1.0)
        check("self-tenant door → 200 (grant)", status == 200,
              f"got {status} {body!r}")
        check("session/S1 returns the tagged /tag records",
              '"path":"/tag"' in body, f"body={body!r}")
        # The /replay request itself isn't session-tagged, so it must not leak in.
        check("untagged /replay record excluded from session query",
              '"path":"/replay"' not in body, f"body={body!r}")

        # 3. Cross-tenant is still refused at the door.
        r = c.request("acme", "/xreplay", timeout=30.0)
        check("cross-tenant door → refused (fail:)",
              r.status == 502 and r.body.startswith("fail:"),
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — tags captured + indexed; self-tenant getReplay returned the "
          "session's activations; cross-tenant refused.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
