#!/usr/bin/env python3
"""`rewind-logs.internal` fetch-engine door integration smoke (step3-auth-plan
A2/A3). Proves the worker chokepoint end to end:

  - An `__admin__` handler fetching `http://rewind-logs.internal/v1/{t}/list`
    gets a worker-minted, TENANT-SCOPED `logs-read` token and reads {t}'s logs
    (200 — empty index is fine; a 200 proves mint + rewrite + attach and that
    the log-server's `verifyWithCapAndTenant` accepted the token).
  - A NON-admin tenant fetching the same host is REFUSED at the routing gate
    (`pf.tenant_id != "__admin__"` → `error.LogsDoorForbidden` → the outbound
    fails → the held chain resolves `outcome.ok == false`).

Needs the full topology + S3 (the worker mints; the log-server verifies). Run:
    zig build rewind-worker rewind-cp rewind-front
    set -a; . ./.env; set +a
    python3 scripts/smoke/logs_door_smoke_v2.py

Ports: http_base 19500 (PID-nudged). Companion to log_tenant_scope_smoke_v2.py
(which tests the log-server gate in isolation); this tests the worker door.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

# Probe handler: a buffered `on.fetch` GET of the door for tenant `?t=`, which
# holds the client response until the upstream result arrives in `onFetchResult`
# (handler-shape.md §3 — the on.fetch buffered convention, mirrors the
# acme/onfetchbuf example). The door's setup errors (e.g. LogsDoorForbidden for
# a non-admin tenant) surface as a terminal `request.ok == false` event.
PROBE_SRC = r"""export default function () {
    const t = new URLSearchParams(request.query || "").get("t") || "acme";
    on.fetch("http://rewind-logs.internal/v1/" + t + "/list?limit=5");
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

READY_SRC = 'export function handler() { return "ready"; }\n'

FIXTURE = {
    "index.mjs": rpc_wrap(READY_SRC),
    "probe/index.mjs": PROBE_SRC,
}


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== rewind-logs.internal door ===")
    with V2Cluster.spawn("logsdoor", nodes=1, http_base=19500,
                         raft_base=19600) as c:
        c.spawn_log_server()
        c._ensure_admin_app()

        # ── Negative: a NON-admin tenant cannot use the door. ──────────────
        r = c.provision("globex")
        check("provision globex → 204/409", r.status in (204, 409),
              f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("globex", FIXTURE)
        except RuntimeError as e:
            check("deploy globex", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        c.wait_for_handler("globex", "/?fn=handler", want_body="ready", timeout_s=30.0)
        r = c.request("globex", "/probe?t=acme", timeout=30.0)
        check("non-admin door fetch → refused (fail:)",
              r.status == 502 and r.body.startswith("fail:"),
              f"got {r.status} {r.body!r}")

        # ── Positive: __admin__ reads any tenant's logs through the door. ──
        # Deploy the probe INTO __admin__ (replaces the baked deploy app — done
        # last; no further deploys needed). `acme` need not exist: the gate is
        # tenant-scope, and an empty index returns 200.
        try:
            c.deploy_handlers("__admin__", FIXTURE)
        except RuntimeError as e:
            check("deploy __admin__", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        c.wait_for_handler("__admin__", "/?fn=handler", want_body="ready", timeout_s=30.0)
        r = c.request("__admin__", "/probe?t=acme", timeout=30.0)
        check("admin door fetch → 200 logs (ok:200:)",
              r.status == 200 and r.body.startswith("ok:200:"),
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — door minted a tenant-scoped token for __admin__ and refused "
          "a non-admin tenant.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
