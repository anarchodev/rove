#!/usr/bin/env python3
"""Only an opted-in baked module is dispatchable by tenant-supplied data.

Two of the three routes into the baked `__system/` registry (rove#639, #643);
the third — a durable wake naming its target in a `_sched/` record — is
`wake_target_smoke_v2.py`. All three grant `is_system_module` from the module
PATH, so any target a tenant can name is a target a tenant can run privileged,
on a ctx it chose.

The `on_chunk` target of an outbound fetch is a module path, and the engine
grants `is_system_module` from that PATH. `http.subscribe` passes its public
`on` straight through to `on_chunk` (its sibling `after.fetch` takes an export
name and validates it), so before this gate one `http.subscribe` call ran ANY
baked module, as a system module, on a ctx the tenant chose — the wake route's
hole (rove#495) reopened at the second door.

## Route: a fetch result (`on_chunk`)

The three things that have to hold together:

  1. a fetch issued from customer context cannot name a non-result-targetable
     baked module — refused at the ISSUING call, not silently dropped later;
  2. the refusal is not cosmetic: the export door (`exportDoorRefused` denies
     it to handler code) stays out of reach through a forged `_export/` record,
     which is the capability that made this more than a dispatch curiosity;
  3. the shims still work — `webhook.send` and `blob.put` name baked result
     handlers from customer context on every call, so a gate that broke them
     would be worse than the hole.

## Route: a continuation hop (`blob.put`'s `on`)

The `on` rides the effect ctx and is dispatched later by the baked result
handler's `next(on_result, …)`. The issuer at that point is itself a baked
module, so only a TARGET list can gate it — `@rewind/segments` names
`__system/segments_onsealed` there and must keep working, while
`__system/webhook_onresult` must not become a lever a tenant can pull on its
own `_send/owed/` state.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

TENANT = "acme"

# `segments_onsealed` is the probe target: it has no activation-kind guard and
# writes `_seg/{log}/s/{first_seq:020}` straight from its ctx, so a row under
# that prefix can only mean the BAKED module ran (it is in no tenant's
# deployment). `export_run` is the capability target.
HANDLER_SRC = r'''
export function handler() { return "ready"; }

// (4) the continuation route. `on` is dispatched by `blob_onresult`'s next().
export function putTo(target, log) {
    const h = blob.put(new TextEncoder().encode("x-" + Date.now() + "-" + log), {
        on: target,
        ctx: { log: log, first_seq: 0, last_seq: 0, count: 1, id: "probe" },
    });
    return "put:" + h;
}

// A hop into `webhook_onresult` would advance this tenant's own send state
// machine out of band: it reads `_send/owed/{ctx.id}` and either drops the
// marker or re-arms a `_sched/` retry. Untouched ⇒ the hop never landed.
export function armOwed() {
    kv.set("_send/owed/probe", JSON.stringify({
        url: "http://127.0.0.1:1/never", method: "POST", body: "", attempts: 0,
    }));
    return "armed";
}

export function owedRow() { return kv.get("_send/owed/probe") === null ? "gone" : "present"; }

export function schedRows() {
    return JSON.stringify((kv.prefix("_sched/", "", 20) || []).map(r => r.key));
}

// (1) the gate, at the issuing call.
export function sub(url, target) {
    try {
        const id = http.subscribe({
            url: url,
            on: target,
            ctx: { log: "probe", first_seq: 0, last_seq: 0, count: 7 },
        });
        return "ISSUED:" + id;
    } catch (e) {
        return "refused: " + (e && e.message ? e.message : String(e));
    }
}

// Did the baked module run? Any row here is a dispatch that should not exist.
export function seg() {
    return JSON.stringify((kv.prefix("_seg/", "", 50) || []).map(r => r.key));
}

// (2) the capability. `_export/` is customer-writable by design, so the record
// is forgeable; what must not be reachable is the door that acts on it.
export function armExport(id) {
    kv.set("data/one", "hello");
    kv.set("_export/" + id, JSON.stringify({
        state: "running", cursor: "", parts: [], bytes: 0, entries: 0,
        started_at: Date.now(),
    }));
    return "armed";
}

export function exportRow(id) { return kv.get("_export/" + id) || "none"; }

export function doorDirect() {
    try {
        after.fetch("http://rove-kvexport.internal/", { on: "onNothing" });
        return "ALLOWED";
    } catch (e) { return "refused: " + (e && e.message ? e.message : String(e)); }
}

// (3) the shims, which name baked result handlers from customer context.
export function send(url) {
    webhook.send(url, { method: "POST", body: "shim-still-works" });
    return "sent";
}

export function put() {
    const hash = blob.put(new TextEncoder().encode("blob-bytes-" + Date.now()));
    kv.set("probe/hash", hash);
    return hash;
}

// The owed marker is deleted by `__system/blob_onresult` — its disappearance
// IS the proof the allowlisted result target still fires.
export function putSettled() {
    const hash = kv.get("probe/hash");
    if (!hash) return "no-hash";
    return kv.get("_blob/owed/" + hash) === null ? "settled" : "owed";
}
'''


class Sink(BaseHTTPRequestHandler):
    received: list[str] = []
    lock = threading.Lock()

    def _ok(self, body: bytes = b"ok"):
        self.send_response(200)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        self._ok()

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        with Sink.lock:
            Sink.received.append(body)
        self._ok()

    def log_message(self, *_a):
        pass


def _args(*vals) -> str:
    return urllib.parse.quote(json.dumps(list(vals)))


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    httpd = HTTPServer(("127.0.0.1", 0), Sink)
    sink = f"http://127.0.0.1:{httpd.server_address[1]}/up"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    with V2Cluster.spawn("restgt", nodes=1) as c:
        r = c.provision(TENANT)
        check("provision → 200", r.status == 200, f"got {r.status}")
        # The shims need outbound, which the free tier does not grant (#336) —
        # this smoke is about dispatch targets, not about the quota.
        c.set_plan(TENANT, json.dumps({"tier": "pro"}))
        try:
            c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(HANDLER_SRC)})
        except RuntimeError as e:
            check("deploy", False, str(e))
            print(f"FAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status}")

        print("\nstep 1: a non-result-targetable baked module is refused at the call")
        for target in ["__system/segments_onsealed", "__system/scheduler_tick",
                       "__system/blob_compose", "__system/static",
                       "__system/export_run",
                       # No named-export smuggling of a target that IS allowed.
                       "__system/webhook_onresult.mjs.someExport"]:
            r = c.get(TENANT, f"/?fn=sub&args={_args(sink, target)}")
            check(f"{target} refused", "refused:" in r.body,
                  f"got {r.body[:120]!r}")
        # Several seconds of upstream chatter would have produced a row by now.
        time.sleep(3.0)
        r = c.get(TENANT, "/?fn=seg")
        check("no baked module ran", r.body.strip() in ('"[]"', "[]"),
              f"_seg/ rows: {r.body[:160]!r}")

        print("\nstep 2: a customer module is unaffected — the gate is about "
              "__system/, not about subscribe")
        r = c.get(TENANT, f"/?fn=sub&args={_args(sink, 'index.mjs')}")
        check("own module still issues", "ISSUED:ftch_" in r.body, f"got {r.body[:120]!r}")

        print("\nstep 3: the export door stays out of reach")
        r = c.get(TENANT, "/?fn=doorDirect")
        check("handler code refused at the door directly", "refused:" in r.body,
              f"got {r.body[:120]!r}")
        c.get(TENANT, f"/?fn=armExport&args={_args('probe-job')}")
        c.get(TENANT, f"/?fn=sub&args={_args(sink, '__system/export_run')}")
        time.sleep(3.0)
        row = c.get(TENANT, f"/?fn=exportRow&args={_args('probe-job')}").body
        check("forged export job produced no parts", '"parts":[]' in row.replace(" ", ""),
              f"_export/probe-job: {row[:200]!r}")

        print("\nstep 4: the continuation route — a hop target a tenant chose")
        c.get(TENANT, "/?fn=armOwed")
        r = c.get(TENANT, f"/?fn=putTo&args={_args('__system/webhook_onresult', 'probeE')}")
        check("blob.put issued with a baked `on`", "put:" in r.body, f"got {r.body[:120]!r}")
        time.sleep(4.0)
        r = c.get(TENANT, "/?fn=owedRow")
        check("hop refused — the send marker is untouched", "present" in r.body,
              f"_send/owed/probe is {r.body[:40]!r}")
        # THE discriminating assertion: without the gate the hop lands and
        # `webhook_onresult` arms a `_sched/` retry against the marker above.
        r = c.get(TENANT, "/?fn=schedRows")
        check("hop refused — no retry armed", r.body.strip() in ('"[]"', "[]"),
              f"_sched/ rows: {r.body[:160]!r}")

        # And the hop that IS on the list still lands: `@rewind/segments` names
        # segments_onsealed from customer-context package JS on every seal, so
        # a gate that refused it would break sealing outright.
        r = c.get(TENANT, f"/?fn=putTo&args={_args('__system/segments_onsealed', 'probeE')}")
        check("allowed hop issued", "put:" in r.body, f"got {r.body[:120]!r}")
        landed = False
        deadline = time.time() + 25
        while time.time() < deadline:
            if "probeE" in c.get(TENANT, "/?fn=seg").body:
                landed = True
                break
            time.sleep(0.5)
        check("segments_onsealed still reachable by a hop", landed)

        print("\nstep 5: the shims that legitimately name baked result handlers")
        r = c.get(TENANT, f"/?fn=send&args={_args(sink)}")
        check("webhook.send issued", "sent" in r.body, f"got {r.body[:120]!r}")
        delivered = False
        deadline = time.time() + 25
        while time.time() < deadline:
            with Sink.lock:
                delivered = "shim-still-works" in Sink.received
            if delivered:
                break
            time.sleep(0.5)
        check("webhook.send delivered (__system/webhook_onresult reachable)", delivered)

        r = c.get(TENANT, "/?fn=put")
        check("blob.put issued", r.status == 200 and len(r.body.strip()) >= 64,
              f"got {r.body[:120]!r}")
        settled = False
        deadline = time.time() + 25
        while time.time() < deadline:
            if "settled" in c.get(TENANT, "/?fn=putSettled").body:
                settled = True
                break
            time.sleep(0.5)
        check("blob.put marker settled (__system/blob_onresult reachable)", settled)
        if not settled or not delivered:
            c.dump_node_log(grep=["on_chunk", "result target", "blob_onresult",
                                  "webhook_onresult"])

    print()
    if failures:
        print(f"FAILURES ({len(failures)}): {failures}")
        return 1
    print("PASS — only opted-in baked modules are reachable by a fetch result "
          "or a continuation hop, the export door stays shut, and the shims "
          "still work")
    return 0


if __name__ == "__main__":
    sys.exit(main())
