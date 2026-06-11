#!/usr/bin/env python3
"""End-to-end smoke for the `webhook.send` JS-shim — V2 port on the
`V2Cluster` harness (branch `v2`).

`webhook.send` (globals/webhook.js) composes durable at-least-once outbound
HTTP on top of the four reified primitives: a durable `_send/owed/{id}` kv
marker, `http.fetch` transport, the baked `__system/webhook_onresult` shim
(classify + retry + chain), and the per-worker retry sweep. On terminal
success the shim `kv.delete`s the marker and chains to the customer
`on_result` module.

This smoke fires acme's `cbfire` handler (verbatim demo-tenant JS), which
calls `webhook.send({ on_result: "cbresult", ... })` against the `wb` echo
tenant, then verifies:
  - the webhook REACHED the `wb` echo target (wb records receipt + the
    platform-stamped X-Rove-Schedule-Id / X-Rove-Schedule-Version headers)
  - the `cbresult` on_result callback ran + wrote `cb/result/{id}` to acme kv
  - the durable `_send/owed/{id}` marker LIFECYCLE: present mid-flight is
    racy to catch, but cleared after terminal success (asserted absent)

V2 specifics (vs the V1 original):
  - Plaintext h2c; no TLS / leader-direct / 503 / OIDC operator session.
  - Delivery target is the `wb` echo TENANT at its hostname:port
    (`http://wb.localhost:<node_port>/echo`), not a loopback Python server —
    V2 binds 0.0.0.0 + does not SSRF-block outbound, so no
    `--dev-webhook-unsafe`. The wb handler self-records what it received so
    the headers + body can be asserted via `admin_kv_get("wb", ...)`.
  - Tenant kv reads go through the worker's move-secret-gated `/_system/v2-kv`
    (`c.admin_kv_get`), replacing the V1 admin listKv API.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

# acme's webhook-firing handler + on_result callback, verbatim from the demo
# tenant (examples/loop46-demo-tenants/acme/cbfire/index.mjs + cbresult.mjs).
CBFIRE_SRC = '''export function fire(url, tag) {
    const id = webhook.send({
        url: url,
        method: "POST",
        body: "ping",
        headers: { "content-type": "text/plain" },
        on_result: "cbresult",
        context: { tag: tag },
        max_attempts: 2,
    });
    kv.set("cb/last_fire", id);
    return { id: id };
}'''

CBRESULT_SRC = '''export default function () {
    const wrap = JSON.parse(request.body);
    const result = (wrap && wrap.ctx && wrap.ctx.result) || {};
    const context = (wrap && wrap.ctx && wrap.ctx.context) || null;
    const record = {
        ok: result.ok,
        status: result.status,
        body: result.body,
        context: context,
        error: result.error || null,
    };
    kv.set("cb/result/" + result.id, JSON.stringify(record));
}'''

ACME_INDEX_SRC = 'export function handler() { return "acme-ready"; }\n'

# wb echo tenant — records receipt (path + the platform-stamped schedule
# headers) to its own kv so the smoke can assert delivery + header stamping,
# then echoes `echo:<body>` so cbresult sees a known body.
WB_SRC = r"""export default function () {
    const id = request.headers["x-rove-schedule-id"] || "<none>";
    const ver = request.headers["x-rove-schedule-version"] || "<none>";
    const body = request.body || "";
    kv.set("recv/last", JSON.stringify({ path: request.path, id: id, ver: ver, body: body }));
    response.status = 200;
    response.headers["content-type"] = "text/plain";
    return "echo:" + body;
}
"""


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("webhook", nodes=1) as c:
        print("step 1: provision tenants 'acme' + 'wb' via the CP")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy wb (echo+record) + acme (cbfire + cbresult)")
        try:
            c.deploy_handlers("wb", {"index.mjs": WB_SRC, "hook/index.mjs": WB_SRC})
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(ACME_INDEX_SRC),
                "cbfire/index.mjs": rpc_wrap(CBFIRE_SRC),
                "cbresult.mjs": CBRESULT_SRC,
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
        # wb echoes (POST) — poll directly so the first webhook fire isn't
        # racing the wb cold-start deploy.
        deadline = time.monotonic() + 25.0
        wb_ok = False
        w = None
        while time.monotonic() < deadline:
            w = c.node_request("/hook", method="POST", host=f"wb.{PUBLIC_SUFFIX}",
                               headers={"content-type": "text/plain"}, data="warm")
            if w.status == 200 and w.body == "echo:warm":
                wb_ok = True
                break
            time.sleep(0.4)
        check("wb (third party) reachable; echoes", wb_ok,
              f"got {w.status if w else '-'} {w.body if w else '-'!r}")
        if not (ready.status == 200 and wb_ok):
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: fire the webhook through acme's cbfire handler")
        wb_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/hook"
        import urllib.parse
        args = urllib.parse.quote(json.dumps([wb_url, "smoke1"]))
        send_id = ""
        deadline = time.monotonic() + 20.0
        r = None
        while time.monotonic() < deadline:
            r = c.request("acme", f"/cbfire?fn=fire&args={args}")
            if r.status == 200:
                try:
                    send_id = json.loads(r.body)["id"]
                    if send_id:
                        break
                except (json.JSONDecodeError, KeyError):
                    pass
            time.sleep(0.2)
        check("cbfire returned a send id", bool(send_id),
              f"got {r.status if r else '-'} {r.body if r else '-'!r}")
        if not send_id:
            c.dump_node_log(grep=["webhook", "send", "owed", "fetch", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        print(f"  ok  handler fired webhook, id={send_id}")

        print("step 5: webhook delivered to wb echo target (+ stamped headers)")
        deadline = time.monotonic() + 8.0
        recv = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("wb", "recv/last")
            if rr.status == 200:
                try:
                    cand = json.loads(rr.body)
                    if cand.get("id") == send_id:
                        recv = cand
                        break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.2)
        check("webhook reached wb echo target", recv is not None,
              "no recv/last row with the send id")
        if recv:
            check("wb saw POST /hook with body 'ping'",
                  recv.get("path") == "/hook" and recv.get("body") == "ping",
                  f"got {recv!r}")
            check("X-Rove-Schedule-Id stamped == send id",
                  recv.get("id") == send_id, f"got id={recv.get('id')!r}")
            check("X-Rove-Schedule-Version stamped == 1",
                  recv.get("ver") == "1", f"got ver={recv.get('ver')!r}")

        print("step 6: cbresult on_result wrote cb/result/{id} to acme kv")
        deadline = time.monotonic() + 8.0
        record = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "cb/result/" + send_id)
            if rr.status == 200 and rr.body:
                try:
                    record = json.loads(rr.body)
                    break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.2)
        check("cb/result/{id} row present", record is not None,
              "no cb/result/{id} row")
        if record:
            check("callback ok == true", record.get("ok") is True, f"got {record!r}")
            check("callback status == 200", record.get("status") == 200, f"got {record!r}")
            check("callback body == 'echo:ping'", record.get("body") == "echo:ping",
                  f"got {record.get('body')!r}")
            check("callback context.tag == smoke1",
                  (record.get("context") or {}).get("tag") == "smoke1",
                  f"got {record.get('context')!r}")

        print("step 7: durable _send/owed/{id} marker cleared after success")
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
    print("\nPASS webhook smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
