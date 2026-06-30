#!/usr/bin/env python3
"""End-to-end smoke for the `http.send` / `webhook.send` JS-shim path —
V2 port on the `V2Cluster` harness (branch `v2`).

`acme/httpfire?fn=fire` calls `webhook.send(...)`: the JS-shim writes a
durable `_send/owed/{id}` marker (envelope-0 kv put), issues the inline
`http.fetch` transport, the baked `__system/webhook_onresult` on_chunk
classifies the terminal outcome, and fires the customer's `httpresult`
`on_result` chain on the SAME tenant the marker lives on. On terminal 2xx
success the shim `kv.delete`s the marker and the callback writes
`http/result/{id}`.

Observable contract asserted (the essential V1 coverage):
  - the `httpresult` on_result callback ran exactly once with the upstream
    event shape `{id, ok, status, body, context}` matching the `wb` echo
    target's response (`echoed:<tag>`)
  - the durable `_send/owed/{id}` marker is CLEARED on terminal success
    (a surviving row means the cleanup hop didn't run)

V2 specifics (vs the V1 original):
  - Plaintext h2c; no TLS / leader-direct / 503 / OIDC operator session /
    seed_manifest / --dev-webhook-unsafe (V2 doesn't SSRF-block outbound).
  - Delivery target is the `wb` echo TENANT at its hostname:port
    (`http://wb.localhost:<node_port>/echo`), not a loopback Python server.
  - Tenant kv reads go through the worker's move-secret-gated
    `/_system/v2-kv` (`c.admin_kv_get`), replacing the V1 admin listKv API.

Handler JS reused VERBATIM from the V1 demo tenant
(`examples/loop46-demo-tenants/acme/httpfire/index.mjs` +
`httpresult.mjs`, `wb/index.mjs`).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


# Verbatim from the demo tenant.
HTTPFIRE_SRC = _src("acme/httpfire/index.mjs")
HTTPRESULT_SRC = _src("acme/httpresult.mjs")
WB_SRC = _src("wb/index.mjs")
ACME_INDEX_SRC = 'export function handler() { return "acme-ready"; }\n'

TAG = "optimization-win"


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("http-send", nodes=1) as c:
        print("step 1: provision tenants 'acme' + 'wb' via the CP")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy wb (echo) + acme (httpfire + httpresult)")
        try:
            c.deploy_handlers("wb", {"index.mjs": WB_SRC})
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(ACME_INDEX_SRC),
                "httpfire/index.mjs": rpc_wrap(HTTPFIRE_SRC),
                "httpresult.mjs": HTTPRESULT_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for both deployments to load")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="acme-ready")
        check("acme loaded", ready.status == 200 and "acme-ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        # wb echoes (POST {tag}) — poll directly so the first webhook fire
        # isn't racing the wb cold-start deploy.
        deadline = time.monotonic() + 25.0
        wb_ok = False
        w = None
        while time.monotonic() < deadline:
            w = c.node_request("/echo", method="POST", host=f"wb.{PUBLIC_SUFFIX}",
                               headers={"content-type": "application/json"},
                               data='{"tag":"warm"}')
            if w.status == 200 and w.body == "echoed:warm":
                wb_ok = True
                break
            time.sleep(0.4)
        check("wb (third party) reachable; echoes echoed:<tag>", wb_ok,
              f"got {w.status if w else '-'} {w.body if w else '-'!r}")
        if not (ready.status == 200 and wb_ok):
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: fire http.send through acme's httpfire handler")
        target = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/echo"
        args = urllib.parse.quote(json.dumps([target, TAG]))
        send_id = ""
        deadline = time.monotonic() + 20.0
        r = None
        while time.monotonic() < deadline:
            r = c.request("acme", f"/httpfire?fn=fire&args={args}")
            if r.status == 200:
                try:
                    send_id = json.loads(r.body)["id"]
                    if send_id:
                        break
                except (json.JSONDecodeError, KeyError):
                    pass
            time.sleep(0.2)
        check("httpfire returned a send id", bool(send_id),
              f"got {r.status if r else '-'} {r.body if r else '-'!r}")
        if not send_id:
            c.dump_node_log(grep=["webhook", "send", "owed", "fetch", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        print(f"  ok  handler called http.send, id={send_id} ({len(send_id)} chars)")

        print("step 5: httpresult on_result wrote http/result/{id} to acme kv")
        deadline = time.monotonic() + 10.0
        record = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "http/result/" + send_id)
            if rr.status == 200 and rr.body:
                try:
                    record = json.loads(rr.body)
                    break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.2)
        check("http/result/{id} row present", record is not None,
              "no http/result/{id} row")
        if record:
            check("callback id == send id", record.get("id") == send_id,
                  f"got {record!r}")
            check("callback ok == true", record.get("ok") is True, f"got {record!r}")
            check("callback status == 200", record.get("status") == 200, f"got {record!r}")
            check(f"callback body == 'echoed:{TAG}'",
                  record.get("body") == f"echoed:{TAG}", f"got {record.get('body')!r}")
            check(f"callback context.tag == {TAG}",
                  (record.get("context") or {}).get("tag") == TAG,
                  f"got {record.get('context')!r}")

        print("step 6: durable _send/owed/{id} marker cleared after success")
        deadline = time.monotonic() + 8.0
        owed_gone = False
        last_owed = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "_send/owed/" + send_id)
            last_owed = rr
            # 404 (or empty 200) == marker deleted on terminal success.
            if rr.status == 404 or (rr.status == 200 and not rr.body):
                owed_gone = True
                break
            time.sleep(0.2)
        check("_send/owed/{id} marker cleared on terminal success", owed_gone,
              f"still present: {last_owed.status if last_owed else '-'} "
              f"{last_owed.body if last_owed else '-'!r}")

        if failures:
            c.dump_node_log(grep=["webhook", "send", "owed", "fetch", "callback",
                                  "result", "resolve", "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS http.send smoke (v2): JS-shim delivers to the echo target, the "
          "on_result callback writes the event, and the durable owed-marker "
          "clears on terminal success")
    return 0


if __name__ == "__main__":
    sys.exit(main())
