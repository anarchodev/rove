#!/usr/bin/env python3
"""V2 `webhook.send` deferred-delivery contract — the durable-wake path
(durable-wake-plan P5(a)), on the `V2Cluster` harness.

`webhook.send({ fire_at_ns: now+Δ })` writes a durable `_send/owed/{id}` kv
marker AND a durable scheduler entry under key `_send/{id}` aimed at the baked
`__system/webhook_fire`; because the fire time is in the FUTURE, no inline
`http.fetch` happens — the durable wake is the sole fire mechanism for the
scheduled case (the per-feature Zig owed sweep is deleted). The same wake
entry doubles as the crash-recovery watchdog: it is replicated kv, so a
freshly-promoted leader reconstructs its watermark (`sweepDurableWakesOnPromotion`)
and the send survives leader change — proven cross-feature by
`durable_wake_smoke_v2.py` Gate B (a wake scheduled before a 3-node leader
kill fires on the new leader).

This smoke asserts the deferred-delivery LIFECYCLE on a single node, where it
is deterministic:

  1. Fire a DELAYED `webhook.send` (fire_at_ns ≈ now+Δ) at the `wb` echo
     tenant. The marker lands in kv; nothing fires yet (verified: the marker
     is present BEFORE the fire time and wb has NOT received anything).
  2. Once the fire time falls due, the wake fires `__system/webhook_fire` —
     wb receives the POST, the `cbresult` on_result writes `cb/result/{id}`
     to acme kv, and the `_send/owed/{id}` marker + the scheduler entry are
     CLEARED on terminal success.

V2 specifics: plaintext h2c (no TLS / leader-direct / `--dev-webhook-unsafe`);
the delivery target is the `wb` echo TENANT at its hostname:port (V2 binds
0.0.0.0 + doesn't SSRF-block outbound); kv reads go through the worker's
move-secret-gated `/_system/v2-kv` (`c.admin_kv_get`).

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

# acme's delayed-webhook handler + on_result callback. Shaped after the V1
# demo tenant's httpfire.fireDelayed / httpresult, adapted to the V2
# webhook.js shim (fire_at_ns sweep-only path).
CBFIRE_SRC = r'''export function fireDelayed(url, tag, delay_ms) {
    const now_ms = Date.now();
    const fire_at_ns = BigInt(now_ms) * 1_000_000n + BigInt(delay_ms) * 1_000_000n;
    const id = webhook.send({
        url: url,
        method: "POST",
        body: "ping",
        headers: { "content-type": "text/plain" },
        on_result: "cbresult",
        context: { tag: tag },
        fire_at_ns: fire_at_ns,
        max_attempts: 5,
    });
    kv.set("cb/last_fire", id);
    return { id: id, fire_at_ns: String(fire_at_ns), now_ms: now_ms };
}'''

CBRESULT_SRC = r'''export default function () {
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

# wb echo tenant — records receipt to its own kv + echoes `echo:<body>`.
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

DELAY_MS = 5000


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("wbrecov", nodes=1) as c:
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
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for both deployments to load + serve")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="acme-ready")
        check("acme loaded", ready.status == 200 and "acme-ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        deadline = time.monotonic() + 25.0
        wb_ok = False
        w = None
        while time.monotonic() < deadline:
            w = c.request("wb", "/hook", method="POST",
                          headers={"content-type": "text/plain"}, data="warm")
            if w.status == 200 and w.body == "echo:warm":
                wb_ok = True
                break
            time.sleep(0.4)
        check("wb (delivery target) reachable; echoes", wb_ok,
              f"got {w.status if w else '-'} {w.body if w else '-'!r}")
        if not (ready.status == 200 and wb_ok):
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        wb_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/hook"
        print(f"step 4: fire a DELAYED webhook.send (delay={DELAY_MS}ms) through acme")
        args = urllib.parse.quote(json.dumps([wb_url, "recov1", DELAY_MS]))
        send_id = ""
        deadline = time.monotonic() + 20.0
        r = None
        while time.monotonic() < deadline:
            r = c.request("acme", f"/cbfire?fn=fireDelayed&args={args}")
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
        print(f"  ok  scheduled delayed webhook.send id={send_id}")

        print("step 5: BEFORE the fire time — the marker is durable + NOT yet fired")
        # Read quickly (well within the delay window): the owed marker must be
        # present and the sweep must NOT have fired yet (sweep-only scheduling).
        rr = c.admin_kv_get("acme", "_send/owed/" + send_id)
        check("durable _send/owed/{id} marker present pre-fire",
              rr.status == 200 and bool(rr.body.strip()),
              f"got {rr.status} {rr.body!r}")
        rr = c.admin_kv_get("wb", "recv/last")
        not_yet = True
        if rr.status == 200 and rr.body.strip():
            try:
                not_yet = json.loads(rr.body).get("id") != send_id
            except json.JSONDecodeError:
                pass
        check("wb has NOT received the delayed send yet (sweep-only)", not_yet,
              "wb already saw the send id before the fire time")

        print("step 6: AFTER the fire time — the durable wake delivers to wb")
        deadline = time.monotonic() + 40.0
        recv = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("wb", "recv/last")
            if rr.status == 200 and rr.body.strip():
                try:
                    cand = json.loads(rr.body)
                    if cand.get("id") == send_id:
                        recv = cand
                        break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.5)
        check("durable wake delivered the webhook to wb", recv is not None,
              "no recv/last row with the send id within 40s")
        if recv:
            check("wb saw POST /hook with body 'ping'",
                  recv.get("path") == "/hook" and recv.get("body") == "ping",
                  f"got {recv!r}")
            check("X-Rove-Schedule-Id stamped == send id",
                  recv.get("id") == send_id, f"got id={recv.get('id')!r}")

        print("step 7: cbresult on_result wrote cb/result/{id} to acme kv")
        deadline = time.monotonic() + 15.0
        record = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "cb/result/" + send_id)
            if rr.status == 200 and rr.body:
                try:
                    record = json.loads(rr.body)
                    break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.5)
        check("cb/result/{id} row present", record is not None,
              "no cb/result/{id} row")
        if record:
            check("callback ok == true", record.get("ok") is True, f"got {record!r}")
            check("callback status == 200", record.get("status") == 200, f"got {record!r}")
            check("callback body == 'echo:ping'", record.get("body") == "echo:ping",
                  f"got {record.get('body')!r}")
            check("callback context.tag == recov1",
                  (record.get("context") or {}).get("tag") == "recov1",
                  f"got {record.get('context')!r}")

        print("step 8: durable _send/owed/{id} marker CLEARED on terminal success")
        deadline = time.monotonic() + 15.0
        owed_gone = False
        last_owed = None
        while time.monotonic() < deadline:
            rr = c.admin_kv_get("acme", "_send/owed/" + send_id)
            last_owed = rr
            if rr.status == 404 or (rr.status == 200 and not rr.body):
                owed_gone = True
                break
            time.sleep(0.5)
        check("_send/owed/{id} marker cleared after wake delivery", owed_gone,
              f"still present: {last_owed.status if last_owed else '-'} "
              f"{last_owed.body if last_owed else '-'!r}")

        if failures:
            c.dump_node_log(grep=["webhook", "send", "owed", "fetch", "sweep",
                                  "callback", "result", "resolve", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS webhook-recovery smoke (v2): delayed webhook.send wrote a "
          "durable owed marker + scheduler entry, the durable wake drove "
          "delivery, and the marker cleared on terminal success (leader-kill "
          "survival is durable_wake_smoke_v2 Gate B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
